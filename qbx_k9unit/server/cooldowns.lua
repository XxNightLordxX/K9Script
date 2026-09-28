--[[
    qbx_k9unit/server/cooldowns.lua

    DEVELOPER_REFERENCE.md item 1 ("Extract the shared cooldown/TTL/mutex
    helper now — retroactively, not preemptively"). Pure structural
    extraction, not a redesign: every one of the 11 independent hand-rolled
    cooldown/mutex tables in this resource is migrated onto the constructors
    below with its exact existing threshold, keying, and cleanup timing
    preserved — see each call site's own comment (server/main.lua,
    server/certifications/, server/tracking.lua, server/search.lua) for
    the "migrated from X, behavior unchanged" note.

    Loaded FIRST in fxmanifest.lua's server_scripts (before main.lua,
    certifications.lua, tracking.lua, search.lua) since it exposes
    resource-global (no `local`) constructor functions those four files
    call at their own file-load time to build their own private tracker
    instances — same "global helper, private per-file state" shape
    HasK9Access/IsConfiguredK9Model already established in
    server/certifications/, just for the cooldown/mutex pattern instead
    of the access-check pattern.

    WHY A NEW FILE, NOT FOLDED INTO server/certifications/ OR
    server/main.lua: this resource's existing convention (per both of
    those files' own headers) is that a shared file should be scoped to ONE
    responsibility so it doesn't balloon into an everything-file as later
    call sites accumulate — certifications.lua is scoped to
    grant/revoke/check, main.lua to small gated actions + the leash
    subsystem. A generic timing/mutex primitive used by all four
    server files (plus whatever future combat/agility cooldown comes next)
    is exactly the kind of cross-cutting mechanism that belongs in its own
    file rather than attached to one of the four call sites as if it were
    that file's private concern.

    THREE CONSTRUCTORS, not one over-generalized function — because the 11
    real call sites genuinely split into three different shapes, confirmed
    by reading all four files' actual implementations before writing this:

    1. NewCooldown(defaultThresholdMs?) — a flat `key -> lastTouchedAtMs`
       tracker. Covers every single-level cooldown in this resource:
       lastBarkAt, lastLeashRequestAt, lastDoorScratchAt (all three keyed by
       player source), lastDoorScratchAtByDoor (keyed by doorNetId, NOT a
       player source), lastCertifyActionAt (keyed by the certifier's
       source), lastDamageRelayAt, lastWeaponFireRelayAt (both keyed by
       source), lastSearchAt (keyed by source), lastTargetSearchAt (keyed by
       a resolved 'vehicle:<plate>' | 'person:<citizenid>' string, NOT a
       player source). That's 9 of the 11 tables — despite the very
       different key domains (source vs. doorNetId vs. resolved-identity
       string), the read/check/stamp/evict MECHANICS are identical in every
       one of them; only the key type and the cleanup hook differ, both of
       which this constructor already takes as call-site-supplied values
       rather than baking in an assumption that the key is a player source.

    2. NewNestedCooldown(defaultThresholdMs?) — a two-level
       `primaryKey -> { secondaryKey -> lastTouchedAtMs }` tracker. Exactly
       one real call site needs this shape:
       server/tracking.lua's LastTrackQueryAt[source][trackType]. Kept as
       its own constructor rather than forcing callers to compose a single
       string key (e.g. `source .. ':' .. trackType`) into NewCooldown,
       because the ORIGINAL table's playerDropped cleanup clears every
       trackType for a disconnecting source in one shot
       (`LastTrackQueryAt[src] = nil`) — a composite-string-keyed flat
       table cannot replicate that without an extra linear scan-and-match
       pass, which would be a behavior-preserving but needlessly more
       expensive migration than just keeping the two-level shape the
       original code already chose for exactly this reason.

    3. NewMutex() — a flat `key -> true|nil` held-flag, no timestamp/
       threshold at all. Exactly one real call site needs this shape:
       server/search.lua's SearchInFlight. Deliberately NOT modeled as
       "NewCooldown with threshold = infinity" — a mutex is
       acquire/release, not check/consume-after-elapsed-time, and giving it
       its own tiny constructor makes the call site
       (`if not SearchMutex.TryAcquire(source) then ... end` /
       `SearchMutex.Release(source)`) read as what it actually is instead of
       a cooldown pretending to have no expiry.

    CLEANUP: two mechanisms, matching the two that already existed —
    neither is "better," they're for genuinely different key domains:
      - :RegisterPlayerDropped() — for any tracker keyed by player source.
        Registers its own `AddEventHandler('playerDropped', ...)` closure
        that clears that source's entry. Multiple trackers each calling
        this independently is fine — FXServer dispatches every registered
        handler for a given `playerDropped` invocation with the same
        `source` value.
      - :StartSweep(intervalMs, isStaleFn) — for a tracker keyed by
        something with no per-connection hook (a door's netId, a resolved
        plate/citizenid identity that outlives any one connection). Runs
        its own `CreateThread` loop, exactly mirroring the shape every
        existing sweep thread in this resource already used (a `pairs`
        traversal with in-place `nil` removal, safe in Lua since clearing
        the CURRENT key mid-traversal is well-defined) — just parameterized
        by the caller's own staleness predicate and interval instead of
        each file hand-writing the loop.

    DELIBERATELY NOT MIGRATED, OUT OF SCOPE FOR THIS FILE:
    server/tracking.lua's `TrackableLog` (the blood/gunpowder event log) and
    its `PruneTrackableLogs` sweep thread are NOT one of the 11 cooldown/
    mutex tables and are NOT touched here. They're a different shape
    entirely — an append-only ARRAY of `{coords, loggedAt}` entries pruned
    by age and separately scanned-by-distance at query time, not a
    `key -> lastTouchedAtMs` map at all -- which is visible directly in
    server/tracking.lua and needs no external authority to confirm.
    (Corrected 2026-08-31: this paragraph used to rest the point on
    "DEVELOPER_REFERENCE.md's own inventory table and its item-1 tally of
    exactly 11 tables". No such table is in that document -- it was most
    likely in one of the fifteen files folded in on 2026-08-25 and cut as
    superseded decision history. The argument stands on its own without it,
    so the dead prop is removed rather than replaced with another number
    that would rot the same way.) Forcing it onto NewCooldown/
    NewNestedCooldown here would be exactly the kind of over-generalized
    function this extraction is meant to avoid.

    API surface below intentionally mirrors the exact read/check/stamp
    ORDER every migrated call site already used, so migrating a call site is
    a mechanical swap, not a reordering:
      :IsOnCooldown(key, thresholdMs?, now?) -> boolean   -- check only, never mutates
      :Touch(key, now?)                                    -- stamp only, never checks
      :Consume(key, thresholdMs?, now?) -> boolean allowed -- check, and stamp iff allowed (false = still on cooldown, nothing stamped)
      :Clear(key)                                          -- evict one entry
      :RegisterPlayerDropped()                             -- see above
      :StartSweep(intervalMs, isStaleFn)                    -- see above
    NewNestedCooldown's methods take (primaryKey, secondaryKey, ...) in
    place of a single `key`, except :Clear(primaryKey), which — matching the
    original LastTrackQueryAt[src] = nil shape — drops every secondaryKey
    under that primaryKey in one call, not one specific secondaryKey.
    NewMutex only exposes :TryAcquire(key), :Release(key), :IsHeld(key), and
    :RegisterPlayerDropped() — no threshold-based methods, per the "not a
    cooldown pretending to have no expiry" reasoning above.

    ======================================================================
    FAIL-CLOSED THRESHOLD HANDLING (the live consequence of this was found
    in server/fetch.lua's releaseFetchBall, fixed separately in that file):
    IsOnCooldown/Consume on BOTH constructors below have always treated a
    missing/non-positive threshold as "permanently on cooldown" (fail
    closed), never as "no cooldown" — correct for this file's own stated
    goal (never let a bad threshold turn into unlimited spam), but entirely
    SILENT, which is exactly how server/fetch.lua's bug went unnoticed: a
    `Config.X = 0` intended by an operator/author to mean "no throttle" reads
    as truthy in Lua (`0 or 500` evaluates to `0`, not `500`), so it reaches
    this file as a real, accepted, wrong default with no signal anything was
    off until a player got permanently stuck.

    Two independent backstops now close that silence, matching what each
    call SHAPE actually allows this file to catch:
      1. CONSTRUCTOR TIME (AssertValidDefaultThreshold, used by both
         NewCooldown and NewNestedCooldown): a non-nil defaultThresholdMs
         that isn't a valid threshold now ERRORS immediately, at resource
         start, before any player ever reaches the guarded action — this is
         the majority call shape in this resource (a Config value captured
         once as the constructor's own default, e.g.
         `NewCooldown(Config.FetchMechanic.pickupCooldownMs or 500)`), and
         turns a fetch.lua-shaped mistake into a startup crash naming the
         exact constructor, not a report filed weeks later. Verified against
         EVERY current NewCooldown/NewNestedCooldown call site in this
         resource before landing this (grep of every call site + every
         corresponding config.lua default) — every shipped default is
         already a positive number, so this is a new backstop against
         FUTURE misconfiguration, not a behavior change for anything
         currently deployed.
      2. CALL TIME (inside :IsOnCooldown itself, both constructors): a
         per-call `thresholdMs` override read fresh from Config on every
         invocation (the OTHER real shape in this resource — e.g.
         server/wellbeing.lua's `IsOnCooldown(src,
         Config.Tracking.Blood.relayCooldownMs)`, never captured as a
         constructor default) cannot be validated at construction time at
         all, since the constructor never sees it. The RETURN VALUE here is
         UNCHANGED (still fails closed, still `true`) — every existing
         caller and this file's own tests keep working exactly as before —
         but the first time any given tracker instance hits this branch, it
         now prints one unmissable console line naming the key and the bad
         threshold, instead of failing silently forever. Printed once per
         tracker instance (not once per call) so an already-broken config
         under real traffic produces one line, not a flood.
    Neither backstop changes IsValidThreshold's actual verdict (still
    rejects nil/non-number/zero/negative) — NaN is now also explicitly
    rejected (`value == value` is Lua's standard NaN test; `value <= 0`
    alone does NOT catch NaN, since every comparison against NaN is false,
    which would otherwise slip through as "looks positive" and then make
    every later `elapsed < threshold` comparison ALSO always false —
    fail OPEN, unlimited spam — the one outcome this whole file exists to
    prevent). See IsValidThreshold's own doc comment below for the full
    reasoning.

    NOT CHANGED, DELIBERATELY: the GetGameTimer() wraparound caveat
    documented on both IsOnCooldown implementations below is a SEPARATE,
    already-disclosed issue (a ~24.85-day int32 wrap, not a
    threshold-validity question) and still needs a coordinated fix across
    every call-time consumer — not folded in here.
    ======================================================================

    ADDENDUM: backstop 1 above (constructor-time hard error) was written on
    the assumption that "crash at resource start naming the bad value" is
    strictly better than "silently permanent fail-closed" — true in
    isolation, but that assumption did not account for a worse consequence.
    `error()` thrown from the middle of a file's own top-level chunk — e.g.
    `local X = NewCooldown(Config.Y.zMs)` sitting between other top-level
    statements, which is exactly the shape every real call site in this
    resource uses — aborts execution of THAT ENTIRE FILE from that line
    onward: every function definition, RegisterNetEvent, AddEventHandler,
    and resource-global assignment textually BELOW the failing line in the
    SAME file silently never happens, for the rest of that resource's
    uptime, with nothing but one script-error line at boot to explain why.
    Reproduced concretely (loaded the real server/cooldowns.lua then
    server/combat.lua in a sandbox with only
    Config.Combat.BiteAndHold.cooldownMs set to 0, every other default left
    at its shipped value): server/combat.lua throws at its own
    `BiteHoldCooldown = NewCooldown(...)` line and takes
    EndActiveEffectForHolder down with it — the termination primitive
    several other files depend on, and this
    codebase's own documented "never let this become unreachable" guarantee
    — along with every BiteAndHold/NonLethalTakedown/PropDragging net event
    in that file. A single mis-set Config number must never be able to
    reach into an unrelated termination/cleanup path in the same file —
    this resource forbids the unbounded-trap class outright, and a config
    typo creating one is exactly that class, just approached from a
    direction backstop 1 didn't originally consider.

    RESOLUTION: `ResolveConfiguredThresholdMs` below — CLAMP AND WARN
    (print, not error) — for exactly the shape that made this reachable: a
    RAW, operator-editable Config field read straight into NewCooldown/
    NewNestedCooldown as the constructor default. Applied at the following
    re-derived 11 call sites: server/combat.lua (x4: BiteHoldCooldown,
    TakedownCooldown, TakedownTargetCooldown, BiteHoldTargetCooldown),
    server/fetch.lua (x2: ThrowCooldown, PickupCooldown — the latter's old
    `Config.FetchMechanic.pickupCooldownMs or 500` idiom is REPLACED here,
    not layered under, since `0 or 500` evaluates to `0` in Lua and never
    actually guarded the one value an operator is most likely to set — this
    was a real, live gap, not a hypothetical), server/kennel.lua (x1:
    DeployCooldown), server/partnership.lua (x1: PartnerRequestCooldown),
    and server/pursuitsprint.lua (x1: PursuitSprintCooldown — that file's
    own PRE-EXISTING `assert` ahead of its NewCooldown call, which
    independently hard-errored on the same input, is replaced by the same
    call-site pattern for the same reason, not left in place beside it).
    Grep for `ResolveConfiguredThresholdMs` across server/*.lua to keep this
    list honest as new call sites are added.

    AssertValidDefaultThreshold's constructor-time hard error is
    DELIBERATELY UNCHANGED and remains the correct behavior for the OTHER
    real shape in this resource: a hardcoded LOCAL CONSTANT handed to
    NewCooldown (e.g. `NewCooldown(CERTIFY_ACTION_COOLDOWN_MS)`, itself a
    `local X = <literal>` a few lines above in the same file, per
    server/certifications//server/main.lua/server/admin.lua and every
    other call site NOT listed above). A bad value there is a PROGRAMMER
    typo in a literal no operator config.lua edit can ever reach — there is
    no config-typo pathway to be proportionate about, and crashing loudly
    at development time (long before any server ships) is the correct,
    standard response, not a bug this addendum is fixing. THE TEST THAT
    DECIDES WHICH SHAPE A GIVEN CALL SITE IS: does an operator's config.lua
    edit alone, with no code change, reach this value? If yes, wrap it in
    ResolveConfiguredThresholdMs before handing it to NewCooldown/
    NewNestedCooldown. If no (a hand-picked literal, only a code change
    could ever alter it), passing it straight through and letting
    AssertValidDefaultThreshold catch a dev typo remains the right call —
    do not blanket-apply ResolveConfiguredThresholdMs to every call site
    "to be safe"; that would silently swallow a real future programmer bug
    in a hardcoded constant behind a fallback instead of catching it at
    development time where it belongs.
    ======================================================================
]]

--- Shared validity test for any threshold this file ever compares elapsed
--- time against — a threshold is valid iff it is a finite, positive Lua
--- number. Centralized so NewCooldown/NewNestedCooldown's constructor guard
--- and their :IsOnCooldown call-time guard can never drift apart on what
--- counts as "bad". Rejects, in one pass:
---   - nil / non-number (the "no threshold supplied at all" case),
---   - 0 or negative (see FOOTGUN below — never a valid "disabled" signal),
---   - NaN (`t ~= t` is Lua's standard NaN test — `t <= 0` alone does NOT
---     catch this, since EVERY comparison against NaN is false; an
---     uncaught NaN would silently fall through as "looks positive" and
---     then make every later `elapsed < threshold` comparison ALSO false
---     forever, i.e. fail OPEN — unlimited spam — the one direction this
---     whole file exists to prevent).
---
--- FOOTGUN THIS EXISTS TO CATCH (found for real in server/fetch.lua's
--- releaseFetchBall, a path documented as "always let go"): an operator
--- setting a cooldown Config field to `0` meaning "no throttle" instead
--- silently got "blocked forever", because `0 or 500`-style fallback
--- idioms treat 0 as present (0 is truthy in Lua) and this file's own
--- :IsOnCooldown then fails closed on it. The since-removed recall feature hit
--- this independently and worked around it in its own file (falling back to
--- a built-in constant and printing a warning rather than trusting a raw
--- non-positive config read) — this constructor-time guard
--- below makes that same class of mistake loud AT RESOURCE START for the
--- common "NewCooldown(Config.X.cooldownMs)" shape (verified: every
--- current NewCooldown/NewNestedCooldown call site's shipped config.lua
--- default is a positive number, so this is a new backstop, not a
--- behavior change for any currently-shipped config), and :IsOnCooldown's
--- own call-time branch below now prints a one-time loud warning (never
--- silent) for the remaining shape this can't catch at construction: a
--- per-call threshold read fresh from Config on every invocation rather
--- than captured as a constructor default.
--- @param value any
--- @return boolean
local function IsValidThreshold(value)
    return type(value) == 'number' and value == value and value > 0
end

--- ======================================================================
--- MINIMUM CONFIGURED INTERVAL (performance audit at 128 players, this
--- pass). IsValidThreshold above only ever checked "is this a usable
--- positive number at all" -- true for a sane `5000` and exactly as true
--- for a hand-edited `1`. That gap is invisible for a normal per-action
--- COOLDOWN (its cost scales with how often the guarded action actually
--- fires, which a cooldown itself already throttles) but genuinely
--- dangerous for the different shape ResolveConfiguredThresholdMs below
--- ALSO resolves: a Config-sourced INTERVAL read once into a background
--- thread's own `Wait(...)` argument, independent of any per-key cooldown
--- gate. Config.Wellbeing.tickIntervalMs is the worst real example:
--- resolved through this exact function into server/wellbeing.lua's
--- TICK_INTERVAL_MS, then used as `Wait(TICK_INTERVAL_MS)` in a loop that
--- reads every connected player's own ped position on every pass -- and, if
--- FatigueSystem's rest-source scan is also on, calls
--- GetAllObjects()/GetAllVehicles() (a full world-entity scan) on every
--- pass too. A hand-edited `Config.Wellbeing.tickIntervalMs = 1` passes
--- IsValidThreshold's `> 0` check without a flicker, and turns that loop
--- into roughly 1,000 passes/second instead of one every 5 seconds -- on
--- the order of 128,000 GetPlayerPed calls/sec at 128 players, plus up to
--- 1,000 full world-entity scans/sec if FatigueSystem is on, easily enough
--- to pin a single FXServer core and stall the one Lua VM every other
--- script on the server also shares. The tablet
--- (server/runtimecontrol.lua) cannot reach this field at all -- by design,
--- since it is resolved once at THIS file-load time, never re-read live --
--- so a direct config.lua hand-edit is the ONLY way to reach this value,
--- and this floor is the only thing that can catch it.
---
--- 250ms, deliberately, over the other number on the table (100ms). Every
--- field ResolveConfiguredThresholdMs currently protects that ships with a
--- small default already sits comfortably above this line -- the smallest
--- is Config.Combat.NonComplianceDetection.positionSampleWindowMs's own
--- 500ms default -- so 250ms leaves every current shipped default
--- untouched, with real headroom to spare, while still meaningfully
--- bounding the worst case this exists for: even every interval this
--- function protects pinned to the floor AT ONCE caps the single most
--- expensive path named above (Wellbeing's optional world-object scan) at 4
--- full sweeps/second rather than up to 1,000, comfortably inside a single
--- Lua VM's per-tick budget at 128 players. 100ms would still have closed
--- the `1`/`5`/`10`ms typo cases this exists for, but 250ms buys a
--- materially bigger safety margin against that specific worst-blast-radius
--- consequence (a population-and-world-scanning tick, not a lightweight
--- per-source rate limit) for a cost of essentially zero real tuning room --
--- nothing in this resource is documented as ever wanting sub-250ms
--- granularity for a population-wide scan interval.
---
--- SCOPE, DELIBERATE: this floor is enforced inside ResolveConfiguredThresholdMs
--- below, on the `configuredValue` it validates -- it is NOT folded into
--- IsValidThreshold itself. IsValidThreshold is also the call-time gate
--- NewCooldown/NewNestedCooldown's own :IsOnCooldown uses for a PER-CALL
--- threshold read fresh from Config on every invocation (e.g.
--- Config.Tracking.Gunpowder.relayCooldownMs, 300ms shipped, passed
--- straight into .Consume() rather than pre-resolved through this
--- function) -- a genuinely different risk shape: a small per-SOURCE rate
--- limit's cost scales with how often that ONE source actually acts, never
--- with total population or a world-entity scan, so a deliberately tight
--- value there is not the failure mode this floor exists to catch. Folding
--- this floor into IsValidThreshold instead would have silently turned a
--- legitimate, already-shipped 300ms relayCooldownMs -- or any operator's
--- own deliberate sub-250ms rate-limit choice on a field like it -- into a
--- PERMANENTLY-STUCK cooldown (IsOnCooldown's own fail-closed branch), a
--- real regression this gap's own brief never asked for and has nothing to
--- do with the population/world-scan blast radius this constant targets.
---
--- NOT applied to `fallbackMs` either, deliberately: that argument is "a
--- positive, hardcoded call-site literal... never itself read from Config"
--- (see ResolveConfiguredThresholdMs's own parameter doc below) -- a
--- PROGRAMMER's choice, not the operator hand-edit this gap is about, and
--- every real fallbackMs literal in this resource today already ships at
--- 500ms or higher regardless.
--- ======================================================================
local MIN_CONFIGURED_INTERVAL_MS = 250

--- Fails loudly (error, not a silent accept) if `defaultThresholdMs` was
--- supplied (non-nil) and is not a valid threshold per IsValidThreshold
--- above. A nil default is always fine — it just means every call to this
--- tracker must supply its own per-call override (several real call sites
--- in this resource construct exactly this way, e.g. AuditCooldown in
--- server/admin.lua). Only a NON-nil-but-invalid default is a caller bug,
--- and this is the one shape this file CAN catch at resource-start time,
--- before any player ever reaches the guarded action — see IsValidThreshold
--- above for why this matters and what it can't catch (per-call-only
--- thresholds, guarded separately at call time below).
---
--- NOT the right guard for a value read directly from an operator-editable
--- Config field, though — this file's own header ADDENDUM explains why an
--- error thrown from here aborts the CALLER's entire file from that line
--- onward, and points call sites with that shape at ResolveConfiguredThresholdMs
--- below instead, which resolves such a value to something always valid
--- before it ever reaches this function.
--- @param defaultThresholdMs any
--- @param constructorName string
local function AssertValidDefaultThreshold(defaultThresholdMs, constructorName)
    if defaultThresholdMs ~= nil and not IsValidThreshold(defaultThresholdMs) then
        error(
            ('[qbx_k9unit] %s called with a non-positive/invalid defaultThresholdMs (%s). ' ..
             '0 or a negative number here does NOT mean "no cooldown" -- this file\'s ' ..
             'IsOnCooldown fails CLOSED on a non-positive threshold (permanently blocks the ' ..
             'guarded action instead), which is almost never the intent. Pass nil instead if ' ..
             'no default is wanted, or fix the Config value this was read from.')
                :format(constructorName, tostring(defaultThresholdMs)),
            3 -- blame the constructor call site, not this line
        )
    end
end

--- Resolves a value read directly from Config into a threshold safe to hand
--- to NewCooldown/NewNestedCooldown as a constructor default — CLAMP AND
--- WARN (print), never error-and-abort — for exactly the "raw,
--- operator-editable Config value passed straight through as a constructor
--- default" call shape. See this file's header ADDENDUM section for the
--- incident this responds to, the full list of call sites it is applied
--- at, and — just as importantly — why AssertValidDefaultThreshold itself
--- is deliberately NOT changed to do this for every caller.
---
--- Call this BEFORE NewCooldown/NewNestedCooldown, at the call site, for
--- any constructor default sourced directly from a Config field an
--- operator can edit. Do not use it for a hardcoded local constant default
--- (e.g. `NewCooldown(SOME_LOCAL_COOLDOWN_MS)`) — that shape has no
--- config-typo pathway and should keep failing loudly via
--- AssertValidDefaultThreshold instead; see this file's header ADDENDUM
--- for the exact test that decides which shape a given call site is.
--- @param configuredValue any -- the raw value read from Config, completely unvalidated (may be nil, a string, NaN, 0, negative, ...)
--- @param fallbackMs number -- a positive, hardcoded call-site literal (never itself read from Config) used only when configuredValue is invalid — typically the same value config.lua ships as this field's own default. An invalid fallbackMs is treated as the CALL SITE's own bug, not an operator's, and still errors (see below).
--- @param configKeyName string -- the exact dotted Config path this value was read from (e.g. "Config.Combat.BiteAndHold.cooldownMs"), used ONLY in the printed warning below — must be precise enough that an operator can find the one field to fix in a multi-thousand-line config.lua without guessing. The printed warning names this key, the value found, and what was substituted — "invalid cooldown" helps nobody find it.
--- @return number resolvedMs -- configuredValue unchanged if valid, otherwise fallbackMs
function ResolveConfiguredThresholdMs(configuredValue, fallbackMs, configKeyName)
    -- A bad fallback is THIS CALL SITE's own bug (a typo'd literal), never
    -- an operator's — same "crash loudly, no config-typo pathway" standard
    -- AssertValidDefaultThreshold applies to a hardcoded constant default,
    -- applied here to the fallback argument specifically so a broken
    -- fallback can never silently reintroduce the permanent fail-closed
    -- footgun one level down (a caller passing e.g. fallbackMs = 0 would
    -- otherwise "successfully" resolve every invalid Config read to
    -- another invalid value, defeating this whole function's purpose).
    if not IsValidThreshold(fallbackMs) then
        error(
            ('[qbx_k9unit] ResolveConfiguredThresholdMs called with an invalid fallbackMs (%s) for %s -- ' ..
             'the fallback is a hardcoded call-site literal, not an operator-editable value, so this is a ' ..
             'programmer bug at the call site, not a Config problem. Fix the fallback argument -- it must ' ..
             'be a positive number.')
                :format(tostring(fallbackMs), tostring(configKeyName)),
            2 -- blame the call site, not this line
        )
    end

    if IsValidThreshold(configuredValue) and configuredValue >= MIN_CONFIGURED_INTERVAL_MS then
        return configuredValue
    end

    -- LOUD, but never fatal: names the exact key, the value found, and
    -- what was substituted -- "invalid cooldown" helps nobody find one bad
    -- field in a 2,000+ line config. Two distinct bad shapes land here now
    -- (see MIN_CONFIGURED_INTERVAL_MS's own declaration comment above for
    -- the full reasoning behind the second one, added this pass):
    --   1. not a valid threshold at all (missing/non-number/non-positive/NaN) --
    --      the original case this warning always covered.
    --   2. a valid, POSITIVE number that is simply too small to be safe for
    --      this kind of setting (e.g. a hand-edited `1`) -- NEW this pass.
    -- Both produce the exact same "falls back, keeps working, one clear
    -- warning" outcome; the message below names whichever is true so an
    -- operator isn't left guessing which rule their value tripped.
    if IsValidThreshold(configuredValue) then
        -- Case 2: a valid, positive number, just below the floor.
        print(
            ('[qbx_k9unit] cooldowns.lua: %s (%s) is below the %dms minimum this resource enforces for a ' ..
             'setting of this kind -- a small POSITIVE number here is not a "no cooldown" mistake (see ' ..
             'IsValidThreshold above for that separate footgun), it is a value too tight to be safe at real ' ..
             'player counts for a population/world-scanning interval. Using the built-in fallback of %dms for ' ..
             '%s instead so this feature keeps working while the config is fixed -- find %s in config.lua and ' ..
             'set it to at least %dms.')
                :format(configKeyName, tostring(configuredValue), MIN_CONFIGURED_INTERVAL_MS, fallbackMs, configKeyName, configKeyName, MIN_CONFIGURED_INTERVAL_MS)
        )
    else
        -- Case 1: not a valid threshold at all (original wording, unchanged).
        print(
            ('[qbx_k9unit] cooldowns.lua: %s is missing or not a positive number (found: %s). 0/negative/nil/NaN ' ..
             'here does NOT mean "no cooldown" in this resource\'s cooldown API -- it would otherwise permanently ' ..
             'block the guarded action instead (this file\'s own documented FAIL-CLOSED behavior; see ' ..
             'IsValidThreshold above). Using the built-in fallback of %dms for %s instead so this feature keeps ' ..
             'working while the config is fixed -- find %s in config.lua and set it to a positive number of ' ..
             'milliseconds.')
                :format(configKeyName, tostring(configuredValue), fallbackMs, configKeyName, configKeyName)
        )
    end
    return fallbackMs
end

--- Flat, single-level `key -> lastTouchedAtMs` cooldown tracker. See this
--- file's header for the full list of the 9 real call sites this covers.
--- @param defaultThresholdMs number? -- used by :IsOnCooldown/:Consume when no per-call override is given; several call sites (e.g. door-scratch, per-target search) read a Config value that could differ per invocation, so this is a convenience default, not a hard requirement. Validated by AssertValidDefaultThreshold above when non-nil — see that function's doc comment.
--- @return table tracker
function NewCooldown(defaultThresholdMs)
    AssertValidDefaultThreshold(defaultThresholdMs, 'NewCooldown')

    local store = {}
    local tracker = {}
    local warnedBadCallTimeThreshold = false

    --- Check-only — never stamps/mutates anything. Mirrors every existing
    --- call site's own `if store[key] and (now - store[key]) < threshold`
    --- read.
    --- @param key any
    --- @param thresholdMs number?
    --- @param now number? -- override GetGameTimer(); pass the SAME timestamp already captured earlier in a call site that needs to compare multiple cooldowns against one consistent instant (mirrors the original code's own single-`now`-variable pattern).
    --- How much longer this key is on cooldown, in milliseconds; 0 when it
    --- is not. Same key/threshold/now contract as IsOnCooldown below, and
    --- deliberately reads the SAME `store` and threshold resolution rather
    --- than keeping a second copy of either.
    ---
    --- WHY THIS EXISTS: a refusal that says only "you must wait" gives the
    --- player nothing to act on, so they mash the key -- which is exactly
    --- what a cooldown is meant to stop. Callers pass the number into their
    --- refusal message so it can say how long.
    ---
    --- Never negative, and never larger than the threshold: a clock that
    --- jumped backwards would otherwise report a wait longer than the
    --- cooldown itself.
    --- @param key any @param thresholdMs number|nil @param now number|nil
    --- @return number -- whole milliseconds remaining, 0 if not on cooldown
    function tracker.RemainingMs(key, thresholdMs, now)
        local lastAt = store[key]
        if not lastAt then return 0 end
        local threshold = thresholdMs or defaultThresholdMs
        if not IsValidThreshold(threshold) then return 0 end
        local elapsed = (now or GetGameTimer()) - lastAt
        if elapsed < 0 then return threshold end
        local left = threshold - elapsed
        if left <= 0 then return 0 end
        return math.floor(left)
    end

    --- @return boolean
    function tracker.IsOnCooldown(key, thresholdMs, now)
        local lastAt = store[key]
        if not lastAt then return false end
        local threshold = thresholdMs or defaultThresholdMs
        if not IsValidThreshold(threshold) then
            -- FAIL CLOSED: an absent (no per-call override AND no
            -- constructor default) or non-positive/NaN (0/negative/NaN)
            -- threshold is always a caller bug (nil arithmetic, a
            -- misconfigured Config value, a future call site forgetting its
            -- override) — `elapsed < 0` is never true, so treating it as a
            -- normal threshold would silently and permanently disable this
            -- cooldown for every already-touched key instead of erroring
            -- loudly. Never let a bad threshold turn into unlimited spam.
            --
            -- NOT SILENT ANYMORE: a non-nil `thresholdMs` override reaching
            -- this branch could not be caught by AssertValidDefaultThreshold
            -- above (that only validates the CONSTRUCTOR's default) — this
            -- is the per-call-Config-read shape (e.g. a file calling
            -- `.IsOnCooldown(key, Config.X.cooldownMs)` fresh every
            -- invocation). Printed once per tracker instance, not once per
            -- call, so a live server under normal call volume against an
            -- already-broken config gets exactly one unmissable line
            -- instead of a flood.
            if not warnedBadCallTimeThreshold then
                warnedBadCallTimeThreshold = true
                print(
                    ('[qbx_k9unit] cooldowns.lua: IsOnCooldown/Consume called with a missing or ' ..
                     'non-positive/invalid threshold (key=%s, thresholdMs=%s, constructor default=%s). ' ..
                     'This key is now PERMANENTLY on cooldown (fail-closed) until this resource ' ..
                     'restarts with a fixed config -- 0/negative/nil never means "no cooldown" in ' ..
                     'this API. Find the Config field this threshold was read from and set it to a ' ..
                     'positive number.')
                        :format(tostring(key), tostring(thresholdMs), tostring(defaultThresholdMs))
                )
            end
            return true
        end
        -- CAVEAT, not fixed here (documentation only): GetGameTimer() is
        -- FXServer's process-uptime millisecond counter, reported to have
        -- gone negative on some long-uptime servers (consistent with the
        -- underlying native being a 32-bit signed counter that wraps after
        -- ~24.85 days of continuous uptime, well within a real server's
        -- lifetime between restarts). This naive `now - lastAt` subtraction
        -- is NOT wraparound-safe: a `key` touched shortly before a wrap
        -- would read as still on cooldown (elapsed appears deeply negative,
        -- and negative < any positive threshold is true) until enough real
        -- wall-clock time passes for `now` to numerically catch back up —
        -- up to ~24.85 days, not just until the configured threshold
        -- elapses. Every call site in this resource already tolerates
        -- "cooldown briefly stuck on" as a fail-safe direction (never
        -- "cooldown silently disabled"), so this is flagged as a known
        -- caveat for a resource restarted well under monthly, not silently
        -- patched — a wraparound-safe rewrite of this subtraction changes
        -- observable timing behavior across every one of this file's 16
        -- call-time consumers and needs a coordinated pass, not a quiet fix
        -- buried in an audit.
        return ((now or GetGameTimer()) - lastAt) < threshold
    end

    --- Stamp-only — never checks anything.
    --- @param key any
    --- @param now number?
    function tracker.Touch(key, now)
        store[key] = now or GetGameTimer()
    end

    --- Check-and-consume: true (and `key` is stamped to `now`/GetGameTimer())
    --- if `key` is NOT currently on cooldown; false (and NOTHING is
    --- stamped) if it is. This is the single most common shape among the
    --- 9 flat tables this constructor covers — "stamp BEFORE the guarded
    --- work" falls out naturally since the stamp happens synchronously
    --- inside this call, before the caller does anything else.
    --- @param key any
    --- @param thresholdMs number?
    --- @param now number?
    --- @return boolean allowed
    function tracker.Consume(key, thresholdMs, now)
        if tracker.IsOnCooldown(key, thresholdMs, now) then
            return false
        end
        tracker.Touch(key, now)
        return true
    end

    --- Drops `key`'s entry entirely.
    --- @param key any
    function tracker.Clear(key)
        store[key] = nil
    end

    --- For a tracker keyed by player source ONLY. Registers a dedicated
    --- `playerDropped` handler that clears the disconnecting source's own
    --- entry. Do NOT call this for a tracker keyed by anything else
    --- (doorNetId, a resolved plate/citizenid string) — use :StartSweep
    --- instead, since a non-player key has no per-connection hook to clean
    --- up on.
    function tracker.RegisterPlayerDropped()
        AddEventHandler('playerDropped', function()
            tracker.Clear(source)
        end)
    end

    --- For a tracker with no natural per-connection cleanup hook. Starts a
    --- periodic sweep thread evicting any entry `isStaleFn(now, loggedAt)`
    --- reports as stale. Exactly mirrors the shape every existing sweep
    --- thread in this resource already used before this extraction.
    ---
    --- THROWING PREDICATE (performance audit at 128 players, this pass): a
    --- tracker built via :StartSweep is, by definition, keyed by something
    --- with NO playerDropped hook (a door's netId, a resolved plate/
    --- citizenid identity, a target's own netId) — this sweep is the ONLY
    --- thing that ever bounds that table's size. Every isStaleFn call site
    --- in this resource today is simple arithmetic against a handful of
    --- static Config numbers (see server/combat.lua's
    --- TakedownTargetCooldown/BiteHoldTargetCooldown/DragTargetCooldown for
    --- the three real examples), but if a Config field one of them
    --- multiplies against ever goes missing or changes type, an UNGUARDED
    --- isStaleFn throwing here would kill this CreateThread outright —
    --- silently, permanently, for the rest of this resource's uptime, with
    --- nothing but one script-error line at the moment it happens (easy to
    --- miss, impossible to notice later). The table this sweep exists to
    --- bound would then grow without limit for the rest of the server's
    --- life. That failure mode — "the memory bound quietly stops existing
    --- and nothing says so" — is exactly the class of bug this file's other
    --- backstops (IsValidThreshold's NaN check, ResolveConfiguredThresholdMs,
    --- AssertValidDefaultThreshold) all exist to make loud instead of
    --- silent, so this sweep gets the same treatment.
    ---
    --- FIX: pcall around every isStaleFn call. A throw is treated as STALE
    --- (the entry is evicted), deliberately NOT as "not stale" (the entry is
    --- kept) — a choice between two imperfect options, picked on purpose:
    ---   - "not stale" (keep) looks safer for any ONE key's correctness, but
    ---     a throwing predicate is a Config-shaped bug that applies
    ---     IDENTICALLY to every key this sweep ever evaluates (same closure,
    ---     same broken Config field, every single pass) — so "keep" here
    ---     would mean NOTHING is ever evicted again once the bug is
    ---     triggered, silently disabling the exact memory ceiling this
    ---     mechanism exists to enforce for as long as the resource keeps
    ---     running. That is the one outcome this whole file cannot allow.
    ---   - "stale" (evict) bounds memory unconditionally. Worst case, a
    ---     still-legitimately-active entry is evicted early, handing
    ---     whoever it was gating one extra, earlier-than-intended action —
    ---     a bounded, self-healing, one-time-per-key correctness nuisance
    ---     (the entry is simply re-created next time it's touched), never
    ---     an unbounded resource leak. That is the strictly less dangerous
    ---     of the two failure directions for a MAINTENANCE sweep — contrast
    ---     with :IsOnCooldown's own fail-CLOSED choice elsewhere in this
    ---     file, which is right for a GATE deciding whether to allow an
    ---     action, but is the wrong model here: this is a sweep deciding
    ---     whether to keep old bookkeeping around, not a gate gone wrong.
    --- Never silent either way: the first throw on a given tracker prints
    --- one line naming the offending key and the exact error the predicate
    --- raised, so a broken isStaleFn becomes a loud, findable bug report
    --- instead of a table that just quietly stops shrinking. Printed once
    --- per TRACKER INSTANCE (not once per key, not once per pass) — same
    --- "loud once, not a flood" convention as :IsOnCooldown's own bad-
    --- call-time-threshold warning above — since a real Config bug here
    --- throws for EVERY key on EVERY pass, and a print-per-occurrence would
    --- flood the console instead of informing it.
    --- @param intervalMs number
    --- @param isStaleFn fun(now: number, loggedAt: number): boolean
    function tracker.StartSweep(intervalMs, isStaleFn)
        local warnedPredicateThrew = false
        CreateThread(function()
            while true do
                Wait(intervalMs)
                local now = GetGameTimer()
                for key, loggedAt in pairs(store) do
                    local ok, staleOrErr = pcall(isStaleFn, now, loggedAt)
                    if not ok then
                        -- Threw: evict (treat as stale) — see this function's
                        -- own doc comment above for why eviction, not
                        -- retention, is the safe direction here.
                        if not warnedPredicateThrew then
                            warnedPredicateThrew = true
                            print(
                                ('[qbx_k9unit] cooldowns.lua: StartSweep isStaleFn threw (%s) while checking key=%s -- ' ..
                                 'evicting this entry rather than leaving this tracker\'s memory ceiling silently ' ..
                                 'disabled (see :StartSweep\'s own doc comment for the full reasoning). This predicate ' ..
                                 'is now broken for EVERY entry it is ever asked about again -- the same closure/Config ' ..
                                 'bug applies to all of them, not just this one -- find and fix whatever Config field ' ..
                                 'this sweep\'s staleness check reads.')
                                    :format(tostring(staleOrErr), tostring(key))
                            )
                        end
                        store[key] = nil
                    elseif staleOrErr then
                        store[key] = nil
                    end
                end
            end
        end)
    end

    return tracker
end

--- Two-level `primaryKey -> { secondaryKey -> lastTouchedAtMs }` cooldown
--- tracker. Exactly one real call site needs this shape — see this file's
--- header for why it's a separate constructor rather than a composite
--- string key into NewCooldown.
--- @param defaultThresholdMs number? -- validated by AssertValidDefaultThreshold when non-nil, same as NewCooldown.
--- @return table tracker
function NewNestedCooldown(defaultThresholdMs)
    AssertValidDefaultThreshold(defaultThresholdMs, 'NewNestedCooldown')

    local store = {}
    local tracker = {}
    local warnedBadCallTimeThreshold = false

    --- @param primaryKey any
    --- @param secondaryKey any
    --- @param thresholdMs number?
    --- @param now number?
    --- @return boolean
    function tracker.IsOnCooldown(primaryKey, secondaryKey, thresholdMs, now)
        local bucket = store[primaryKey]
        local lastAt = bucket and bucket[secondaryKey]
        if not lastAt then return false end
        local threshold = thresholdMs or defaultThresholdMs
        if not IsValidThreshold(threshold) then
            -- FAIL CLOSED — see NewCooldown's IsOnCooldown for the full
            -- reasoning: a bad/missing threshold must never silently
            -- disable this cooldown. NOT SILENT ANYMORE — same one-time-
            -- per-tracker loud warning as NewCooldown's IsOnCooldown above,
            -- for the same reason (a per-call threshold read fresh from
            -- Config can't be caught by AssertValidDefaultThreshold at
            -- construction time).
            if not warnedBadCallTimeThreshold then
                warnedBadCallTimeThreshold = true
                print(
                    ('[qbx_k9unit] cooldowns.lua: NewNestedCooldown IsOnCooldown/Consume called with a ' ..
                     'missing or non-positive/invalid threshold (primaryKey=%s, secondaryKey=%s, ' ..
                     'thresholdMs=%s, constructor default=%s). This (primaryKey, secondaryKey) pair is ' ..
                     'now PERMANENTLY on cooldown (fail-closed) until this resource restarts with a ' ..
                     'fixed config -- 0/negative/nil never means "no cooldown" in this API.')
                        :format(tostring(primaryKey), tostring(secondaryKey), tostring(thresholdMs), tostring(defaultThresholdMs))
                )
            end
            return true
        end
        -- Same GetGameTimer() wraparound caveat as NewCooldown's
        -- IsOnCooldown above (see its doc comment for the full writeup) —
        -- this subtraction is not wraparound-safe either.
        return ((now or GetGameTimer()) - lastAt) < threshold
    end

    --- @param primaryKey any
    --- @param secondaryKey any
    --- @param now number?
    function tracker.Touch(primaryKey, secondaryKey, now)
        store[primaryKey] = store[primaryKey] or {}
        store[primaryKey][secondaryKey] = now or GetGameTimer()
    end

    --- @param primaryKey any
    --- @param secondaryKey any
    --- @param thresholdMs number?
    --- @param now number?
    --- @return boolean allowed
    function tracker.Consume(primaryKey, secondaryKey, thresholdMs, now)
        if tracker.IsOnCooldown(primaryKey, secondaryKey, thresholdMs, now) then
            return false
        end
        tracker.Touch(primaryKey, secondaryKey, now)
        return true
    end

    --- Clears EVERY secondaryKey entry under `primaryKey` in one call —
    --- matches the original flat `store[primaryKey] = nil` playerDropped
    --- cleanup shape (e.g. LastTrackQueryAt[src] = nil dropping
    --- scent/blood/gunpowder all at once for that source).
    --- @param primaryKey any
    function tracker.Clear(primaryKey)
        store[primaryKey] = nil
    end

    --- For a tracker whose primaryKey is a player source. See NewCooldown's
    --- :RegisterPlayerDropped doc comment — same reasoning, applied to the
    --- primaryKey level here.
    function tracker.RegisterPlayerDropped()
        AddEventHandler('playerDropped', function()
            tracker.Clear(source)
        end)
    end

    --- Two-level counterpart to NewCooldown's own :StartSweep -- added
    --- because a nested tracker keyed by something DURABLE (a citizenid
    --- pair, a plate, a netId) has no `playerDropped` moment to clean up
    --- on, exactly like the flat case that constructor's own doc comment
    --- describes. Without this, the only bounded option for a nested
    --- tracker was :RegisterPlayerDropped(), which forces the key to be a
    --- connection `source` -- and a source-keyed cooldown is not a
    --- cooldown, because a reconnect mints a fresh source and the entry
    --- that was throttling that player is dropped on the way out.
    ---
    --- Prunes at BOTH levels: a stale secondary entry is removed, and a
    --- primary bucket left empty by that removal is removed too. Without
    --- the second half the outer table would keep one empty sub-table per
    --- primary key it had ever seen, which is a slower leak rather than no
    --- leak.
    ---
    --- isStaleFn/eviction semantics, and the loud-once-per-tracker warning
    --- when the predicate throws, are deliberately identical to the flat
    --- version's -- see that function's own doc comment for the full
    --- reasoning on why a throwing predicate evicts rather than retains.
    --- @param intervalMs number
    --- @param isStaleFn fun(now: number, loggedAt: number): boolean
    function tracker.StartSweep(intervalMs, isStaleFn)
        local warnedPredicateThrew = false
        CreateThread(function()
            while true do
                Wait(intervalMs)
                local now = GetGameTimer()
                for primaryKey, bucket in pairs(store) do
                    local remaining = 0
                    for secondaryKey, loggedAt in pairs(bucket) do
                        local ok, staleOrErr = pcall(isStaleFn, now, loggedAt)
                        if not ok then
                            if not warnedPredicateThrew then
                                warnedPredicateThrew = true
                                print(
                                    ('[qbx_k9unit] cooldowns.lua: nested StartSweep isStaleFn threw (%s) while checking ' ..
                                     'key=%s/%s -- evicting this entry rather than leaving this tracker\'s memory ceiling ' ..
                                     'silently disabled (see :StartSweep\'s own doc comment for the full reasoning). This ' ..
                                     'predicate is now broken for EVERY entry it is ever asked about again -- the same ' ..
                                     'closure/Config bug applies to all of them, not just this one -- find and fix ' ..
                                     'whatever Config field this sweep\'s staleness check reads.')
                                        :format(tostring(staleOrErr), tostring(primaryKey), tostring(secondaryKey))
                                )
                            end
                            bucket[secondaryKey] = nil
                        elseif staleOrErr then
                            bucket[secondaryKey] = nil
                        else
                            remaining = remaining + 1
                        end
                    end
                    if remaining == 0 then
                        store[primaryKey] = nil
                    end
                end
            end
        end)
    end

    return tracker
end

--- Per-key mutex (boolean held-flag, no timestamp/threshold at all). See
--- this file's header for why this is a separate constructor from
--- NewCooldown rather than a cooldown with an infinite threshold.
---
--- DEADLOCK VERDICT (audited): TryAcquire/Release themselves cannot
--- deadlock — both are single synchronous table operations with no
--- internal Wait/await, and FXServer's Lua execution is cooperative
--- (never preempted between two non-yielding statements), so there is no
--- window where two callers can interleave inside TryAcquire itself. This
--- mutex also has NO built-in timeout/expiry — a `key` that is TryAcquire'd
--- and never Release'd stays held FOREVER (silently disabling whatever it
--- guards for that key, with no error), by design, matching every other
--- primitive in this file: a mutex "expiring" would defeat the point of a
--- mutex. That makes "is a mutex ever left held with no way to release it"
--- entirely a caller-discipline question, not something this constructor
--- can enforce. Grouped by release discipline, not by age, since the two
--- groups genuinely differ:
---
--- GROUP A — the original 5, released via pcall (server/search.lua
--- SearchMutex, server/combat.lua TakedownMutex, server/inventory.lua
--- K9InventoryOpenMutex, server/medkit.lua MedkitMutex,
--- server/partnership.lua PartnershipEstablishMutex): every one wraps its
--- entire critical section (including any yielding `await` calls inside
--- it) in `pcall(...)` and unconditionally calls `:Release(key)` on the
--- very next line after the pcall returns, regardless of success/failure —
--- so a thrown error mid-critical-section is already covered by every
--- existing caller. `:RegisterPlayerDropped()` is a second, independent
--- backstop for the subset of these keyed by player source (SearchMutex,
--- TakedownMutex, K9InventoryOpenMutex — all `RegisterPlayerDropped()`ed at
--- their own declaration) so a source that disconnects mid-critical-section
--- (rather than erroring) still gets its held key cleared; the two callers
--- keyed by something else (MedkitMutex by targetCitizenid,
--- PartnershipEstablishMutex by a fixed constant key) do NOT call
--- RegisterPlayerDropped, correctly, since neither key is a player source —
--- their sole release path is the pcall-guaranteed one, which does not
--- depend on any player staying connected.
---
--- GROUP B — landed after this comment was first written (server/
--- certtiers.lua TierEditMutex, server/equipmentshop.lua ShopItemEditMutex,
--- server/permissionkeycatalog.lua PermissionKeyEditMutex, server/
--- xptiers.lua XPTierEditMutex, server/k9profiles.lua K9ProfileEditMutex):
--- NONE of these wrap their critical section in `pcall` at all — instead,
--- every one releases explicitly, in-line, immediately before EVERY early
--- `return` inside the critical section (confirmed by direct read of all
--- five, not assumed from the pattern above), and every DB write inside
--- that section is a `K9Store.*` call under this resource's own SafeWrite
--- contract (a thrown DB error degrades to a returned `false`, never an
--- uncaught error — see server/datastore.lua) rather than an unguarded
--- MySQL call that could itself throw. That combination (nothing in the
--- critical section can throw + every explicit return path releases first)
--- reaches the same guarantee GROUP A's pcall gets structurally, by a
--- different route — not a weaker one, but genuinely a different one, so
--- it is recorded here rather than silently folded into GROUP A's
--- description. All five are keyed by something other than a player source
--- (a tier_key, an item key, a permission key, XPTierEditMutex's own fixed
--- ladder-wide lock constant, and a citizenid, respectively) and correctly
--- do NOT call RegisterPlayerDropped, same reasoning as MedkitMutex/
--- PartnershipEstablishMutex above.
---
--- CORRECTION: this comment used to say "audited across all 5 current call
--- sites", then later "the count is 9 today" — both went stale the moment
--- the NEXT NewMutex() landed and nobody re-measured this comment at the
--- same time. Rather than restate another number here for the next
--- constructor to make stale, re-derive the real count yourself, right
--- now, before trusting anything below: `grep -c 'NewMutex()' server/*.lua`
--- (excluding this constructor's own definition and every prose mention in
--- a comment, i.e. only real `local X = NewMutex()` construction sites)
--- MUST equal the number of mutexes named across GROUP A + GROUP B above —
--- if it doesn't, one of these two lists is missing an entry and needs a
--- new GROUP B-shaped paragraph like this one, not a one-line addition to
--- an existing list; do not let this
--- correction itself calcify into the next stale claim.
--- @return table mutex
function NewMutex()
    local held = {}
    local mutex = {}

    --- Atomically checks-and-sets in one call — true (and `key` becomes
    --- held) if `key` was NOT already held; false (and nothing changes) if
    --- it was. Preserves the original SearchInFlight call site's exact
    --- "reject outright, never queue/race a concurrent call from the same
    --- source" behavior.
    --- @param key any
    --- @return boolean acquired
    function mutex.TryAcquire(key)
        if held[key] then return false end
        held[key] = true
        return true
    end

    --- Releases `key`. Safe to call even if `key` was never held (matches
    --- the original `SearchInFlight[source] = nil` unconditional-clear
    --- shape used on every exit path).
    --- @param key any
    function mutex.Release(key)
        held[key] = nil
    end

    --- @param key any
    --- @return boolean
    function mutex.IsHeld(key)
        return held[key] == true
    end

    --- For a mutex keyed by player source. Same reasoning as NewCooldown's
    --- :RegisterPlayerDropped.
    function mutex.RegisterPlayerDropped()
        AddEventHandler('playerDropped', function()
            mutex.Release(source)
        end)
    end

    return mutex
end
