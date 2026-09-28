--[[
    qbx_k9unit/client/wellbeing.lua

    Client-side half of Config.Features.FatigueSystem. Receives the server's
    pushed wellbeing snapshots, sets the shared `K9MoveRateModifiers.fatigue`
    entry and calls `RecomputeK9MoveRate()` (client/movement.lua).

    IT USED TO CARRY FOUR MORE. Mood, fear/stress, distraction and injury
    were all handled here too -- the injury sprint/jump input block, the
    meat-bait/whistle/calm-down self-actions, and the merged "Care for K9"
    ox_target interaction. All were removed on 2026-09-02 at the owner's
    request. Prose further down that still counts "five flags" is describing
    what was true when it was written; read it as a dated account rather
    than an inventory of this file today.

    The fatigue flag is checked at the point of use
    below, not just declared: see "LIVE FEATURE FLAGS" below. Every check
    reads `LiveFeatureFlags.<Name>` — the server's CURRENT flag state, kept
    fresh by every `wellbeingUpdate` push/`getWellbeingSnapshot` fetch —
    rather than this client's own static `Config.Features.<Name>` copy,
    fixed at this client's own resource start and never updated by a
    runtime tablet toggle (server/runtimecontrol.lua). Registration
    (CreateThread/RegisterCommand/ox_target option registration) always
    happens regardless of that static value too — a live-OFF flag is
    enforced at the point each ability ACTS, never by skipping registration
    entirely, matching client/featureblocks.lua's own established rule for
    this exact class of check ("check at the point it acts, never merely at
    registration") — see each section's own "ALWAYS STARTS/REGISTERS"
    comment for the specific gap this closes. The one remaining exception,
    left as a disclosed, genuinely bounded staleness rather than a
    correctness bug: the on-demand "just became K9-modeled" snapshot-fetch
    thread below still only starts if this client's OWN static config had
    at least one flag true at boot — a client that shipped fully
    wellbeing-disabled misses that one optimization and instead waits for
    the server's own periodic tick push (bounded to
    `Config.Wellbeing.tickIntervalMs`).

    RESOLVED (server-side fix landed this pass, coder-backend — see
    server/wellbeing.lua's own header and its CreateThread call's resolution
    comment for the full writeup): that periodic tick used to carry the
    IDENTICAL one-time boot-flag gate server-side, and this paragraph used
    to say so, naming an earlier reverted attempt to fix it and warning that
    a deployment where BOTH the server and this client booted with every
    wellbeing flag false could go genuinely unbounded, not merely one tick
    interval, before either side noticed a later runtime toggle-ON. That is
    no longer true. server/wellbeing.lua's shared tick thread now ALWAYS
    starts at that file's own load time, re-checking all five
    Config.Features flags fresh inside the loop before ever calling
    TickWellbeing — a server booted with every flag off and later flipped
    live from the tablet is picked up by that already-running thread within
    one `Config.Wellbeing.tickIntervalMs`, never "until this resource
    restarts." The one gap left is the narrower one stated in the paragraph
    above (this client's own on-demand-fetch optimization, not the server's
    periodic push), and it is genuinely bounded on its own: even a client
    that shipped fully wellbeing-disabled still receives the server's own
    periodic push once the server-side flag is live, within one
    `tickIntervalMs`. This file's "bounded" framing above now holds
    unconditionally — it no longer depends on a flag having already been
    true at boot on the server.

    NOTHING BELOW IS A SECURITY BOUNDARY. Every mutating action is
    re-validated server-side in server/wellbeing.lua regardless of what
    this file's own UI/gating thinks — the standard "client hides the
    option, server is the real gate" split this codebase applies everywhere
    (DEVELOPER_REFERENCE.md §4.1).

    WHAT IS LEFT HERE. Fatigue and the move-rate/stamina effects it drives,
    plus the periodic snapshot the server pushes. The pet, feed, calm-down
    and distraction actions this header used to describe — along with the
    `RequestK9CalmDown()` resource-global and the `/k9calmdown` command it
    named — went with the mood, fear/stress, distraction and injury
    subsystems when those were removed at the owner's request on
    2026-09-02. Nothing defines or registers them any more; see the
    "Commands (RegisterCommand): none" note further down, which is the same
    fact stated from the other direction.

    ======================================================================
    OX_TARGET API — same `addGlobalPlayer` shape already confirmed HIGH
    confidence against real ox_target source by client/medkit.lua (see that
    file's header) — not re-verified independently here, reused unchanged.

    EVENT/CALLBACK CONTRACT — see server/wellbeing.lua's header for the full
    contract; this file is the client side of every entry listed there.

    Commands (RegisterCommand): none. This file registered three until
    2026-09-02, all belonging to subsystems removed at the owner's request.

    FILE-TO-FILE CONTRACT:
    - Reads/writes `K9MoveRateModifiers` and calls `RecomputeK9MoveRate()`,
      both resource-globals from client/movement.lua (DEVELOPER_REFERENCE.md §13.0
      Decision 2) — never calls `SetPedMoveRateOverride` directly.
    - Calls `IsOwnModelK9()`/`CanShowK9UI()`/`DenyK9UIAccess()`/
      `IsEntityModelK9(entity)`/`ResolvePlayerServerIdFromPed(entity)`,
      resource-globals from client/main.lua — reused, never re-derived.
      `IsEntityModelK9` (DEVELOPER_REFERENCE.md item 3) replaces this file's
      own former local `K9ModelHashes` set (used to mirror
      client/medkit.lua's own precomputation exactly — a client-side
      display filter only, server/wellbeing.lua re-derives every target's
      real model server-side regardless). `ResolvePlayerServerIdFromPed`
      (DEVELOPER_REFERENCE.md item 2b) replaces this file's own former local
      copy of the same function (used to mirror client/medkit.lua's own
      copy exactly).
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
-- Local mirror of the server's last-pushed snapshot. Safe defaults (fully
-- healthy/calm) so that, before the first real push ever arrives, nothing
-- below throttles or notifies anything — matches every other "disabled/
-- not-yet-known state must be a no-op" default in this codebase.
local lastStats = {
    fatigue = 100,
}

-- ======================================================================
-- LIVE FEATURE FLAGS -- closes a real, confirmed gap: every check below
-- USED TO read `Config.Features.<Name>` directly -- this CLIENT's own copy
-- of config.lua, fixed at THIS client's own resource start and never
-- updated by a runtime tablet toggle (server/runtimecontrol.lua's
-- runtimeSetFeature/runtimeResetFeature only ever mutate the SERVER's own
-- in-memory Config table; that file discloses it does not push a live
-- Config update to already-connected clients, since doing so is a
-- client-side decision it does not own). Concretely, that meant: an
-- operator switching e.g. FatigueSystem off mid-session via the tablet
-- left every already-connected, already-penalized K9 stuck at its
-- last-applied K9MoveRateModifiers.fatigue penalty FOREVER --
-- server/wellbeing.lua's own TickWellbeing stops decaying/regenerating
-- that stat the instant its flag is false, so nothing was ever going to
-- carry lastStats.fatigue back across the threshold that would have
-- cleared the modifier, and this file had no way to learn the flag had
-- changed at all. A control that reports "done" to the operator while
-- silently doing nothing for an already-connected player -- worse than one
-- that honestly requires a restart.
--
-- THE FIX: server/wellbeing.lua's SnapshotOf (see that file's own header
-- comment on this exact change) piggybacks a `featureFlags` table onto the
-- ALREADY-EXISTING `wellbeingUpdate` push / `getWellbeingSnapshot`
-- on-demand fetch -- no new event, no new poll, reusing the exact channel
-- this file already listens to every tick. `ApplyWellbeingSnapshot` below
-- copies any recognised boolean field from that table into this mirror;
-- every check in this file that used to read `Config.Features.<Name>`
-- directly now reads `LiveFeatureFlags.<Name>` instead.
--
-- DEFAULT VALUE, DELIBERATE: seeded from this client's own
-- `Config.Features.<Name>` copy -- i.e. IDENTICAL behaviour to before this
-- fix -- until the very first snapshot arrives (the on-demand fetch on
-- becoming K9-modeled, or the first automatic tick push, whichever comes
-- first). Safe to default this way because NOTHING in this file is a
-- security boundary (this file's own header, restated at every call site
-- below) -- unlike client/featureblocks.lua's per-person blocks (which must
-- fail OPEN on unknown state to avoid falsely freezing an ability that was
-- never actually blocked), a briefly-stale-toward-the-shipped-config value
-- here has no access-control consequence either way, only a cosmetic/
-- gameplay one bounded to at most one wellbeing tick interval.
-- ======================================================================
local LiveFeatureFlags = {
    FatigueSystem = Config.Features.FatigueSystem == true,
    -- HUNGER/THIRST (this pass, coder-backend) -- same live-flag mechanism,
    -- same reasoning, as the five siblings above.
}

-- ======================================================================
-- LIVE WELLBEING TUNABLES -- originally "make the speed boost and stamina
-- numbers genuinely editable," extended by the owner to every K9 stat.
-- SAME MECHANISM, SAME CHANNEL AS "LIVE FEATURE FLAGS" ABOVE, NOT A
-- SECOND ONE -- server/wellbeing.lua's SnapshotOf piggybacks a SECOND
-- table, `wellbeingTunables`, onto the identical `wellbeingUpdate` push /
-- `getWellbeingSnapshot` fetch this section's own comment already
-- describes in full; read that comment first, it is not repeated here.
--
-- WHAT THIS REPLACES: every one of the seven fields below used to be read
-- directly off THIS CLIENT's own static `Config.Wellbeing.<Stat>.<Field>`
-- copy at the exact point of use (`ApplyMoveRateModifiers`, and the
-- injury sprint/jump thread that used to sit further down until that
-- subsystem was removed) -- fixed at THIS client's own
-- resource start, never updated by a runtime tablet edit
-- (server/runtimecontrol.lua's runtimeSetTunable/runtimeResetTunable only
-- ever mutate the SERVER's own in-memory Config table). server/wellbeing.lua
-- used to document this exact gap as the reason those seven fields were
-- EXCLUDED from TUNABLE_REGISTRY outright -- "a live dial this file cannot
-- even confirm reaches the client" (that exclusion comment's own words).
-- That gap is now closed the same way LiveFeatureFlags closed it for the
-- five boolean flags: mirror the server's CURRENT value here, read FRESH by
-- every call site below, kept fresh by every wellbeingUpdate push.
--
-- MID-EFFECT DECISION, STATED PLAINLY (deliberately DIFFERENT from
-- server/pursuitsprint.lua's "a running burst keeps its granted value"
-- choice -- not an inconsistency, a different value class): a live tablet
-- edit to any of these seven fields takes effect on THIS K9's very next
-- `ApplyMoveRateModifiers()` recompute (within one
-- `Config.Wellbeing.tickIntervalMs` of the edit for an already-connected K9)
-- -- including retroactively re-judging a PENALTY/BLOCK ALREADY IN EFFECT
-- right now against the new threshold/multiplier. This is the right choice
-- for THIS class of value, for a reason PursuitSprint's grant does not
-- share: these are not one-shot grants with a natural start/end a client
-- privately owns -- they are CONTINUOUS, per-tick judgments
-- (`lastStats.<stat> < threshold`) that server/wellbeing.lua's own tick loop
-- already re-evaluates from scratch every single tick regardless of this
-- fix. Freezing a stale threshold for the remainder of "whatever effect was
-- already applied" has no natural boundary to freeze it UNTIL (unlike a
-- bounded few-second sprint burst) -- it would mean an operator's edit
-- never reaches a K9 who happened to already be penalized at the moment of
-- the edit, for as long as they stay penalized, which could be indefinite.
-- Updating immediately is also what makes the "no unbounded trap" rule
-- actually hold for this fix: a threshold raised (or a multiplier
-- loosened) so an already-blocked/penalized K9 no longer qualifies must
-- lift that block/penalty on the very next recompute, not merely stop it
-- from being reapplied at whatever number it started under -- exactly
-- ApplyMoveRateModifiers' own existing "LIVE FEATURE FLAGS" precedent for a
-- flag switched off mid-effect, applied here to a threshold/multiplier
-- edited mid-effect instead.
--
-- DEFAULT VALUE, DELIBERATE: seeded from this client's own
-- `Config.Wellbeing.<Stat>.<Field>` copy -- i.e. IDENTICAL behaviour to
-- before this fix -- until the very first snapshot arrives, same reasoning
-- and same safety argument as LiveFeatureFlags' own default-value comment
-- above (nothing here is a security boundary either).
-- ======================================================================
local LiveWellbeingTunables = {
    fatigueSpeedPenaltyThreshold     = Config.Wellbeing.Fatigue.speedPenaltyThreshold,
    fatigueSpeedPenaltyMultiplier    = Config.Wellbeing.Fatigue.speedPenaltyMultiplier,
    -- NATIVE SPRINT STAMINA ASSIST -- see the "NATIVE SPRINT STAMINA ASSIST"
    -- section further below for the consumer of this field. (It used to be
    -- located by "right after the Injury sprint/jump block"; that block
    -- went with the injury subsystem, so the section is now simply the
    -- last one in this file.) Same ingest/default-value rules as the
    -- seven fields above -- read fresh by that section every check, seeded
    -- from this client's own static config copy until the first snapshot
    -- arrives, same safety argument (nothing here is a security boundary).
    fatigueNativeStaminaRestorePercent = Config.Wellbeing.Fatigue.nativeStaminaRestorePercent,
    -- CONFIG-DEFENSIVE seeding (see server/wellbeing.lua's header for the
    -- full reasoning): a sub-table this client reads may not exist in a
    -- given server's config.lua at all (this file does not own that file),
    -- so this seed is guarded the same way server/wellbeing.lua's SnapshotOf
    -- guards its own. The hunger and thirst systems this paragraph was
    -- originally written for were removed on 2026-09-02; the guarding
    -- pattern it describes is still how every other sub-table is read
    -- equivalent read -- a client that boots against an old config.lua
    -- simply seeds these two at a safe default instead of erroring out of
    -- this entire file's load (which would take every OTHER wellbeing
    -- feature's client-side half down with it).
}

--- Recomputes this file's three owned `K9MoveRateModifiers` slots from
--- `lastStats` and asks client/movement.lua's composer to recompute the
--- single real `SetPedMoveRateOverride` call. A stat whose OWNING flag is
--- currently OFF (per `LiveFeatureFlags`, not the static `Config.Features`
--- copy -- see "LIVE FEATURE FLAGS" above) has its slot explicitly RESET to
--- 1.0 every call, never merely left at whatever it already was: leaving a
--- modifier untouched is exactly what would let a flag switched off
--- mid-effect leave that modifier frozen forever, since nothing else in
--- this file would ever move it back to neutral on its own.
local function ApplyMoveRateModifiers()
    -- Every branch below now gates on `LiveFeatureFlags.<Name>` (the
    -- server's CURRENT flag state, kept fresh by ApplyWellbeingSnapshot
    -- below) rather than the static `Config.Features.<Name>` this client
    -- shipped with. Each `else` explicitly RESETS its own modifier to 1.0
    -- rather than leaving it untouched -- see this file's header, "LIVE
    -- FEATURE FLAGS", for the confirmed "unbounded trap" this closes: a
    -- flag switched off mid-effect must REMOVE that effect, not merely stop
    -- re-applying it (server/wellbeing.lua stops updating the underlying
    -- stat the instant its own flag is false, so nothing else was ever
    -- going to clear this on its own).
    if LiveFeatureFlags.FatigueSystem then
        if lastStats.fatigue < LiveWellbeingTunables.fatigueSpeedPenaltyThreshold then
            K9MoveRateModifiers.fatigue = LiveWellbeingTunables.fatigueSpeedPenaltyMultiplier
        else
            K9MoveRateModifiers.fatigue = 1.0
        end
    else
        K9MoveRateModifiers.fatigue = 1.0
    end




    RecomputeK9MoveRate()
end

--- Applies a freshly-received stats table to `lastStats`, recomputes move
--- rate, and fires cosmetic notifications on state transitions only (never
--- spammed every tick). Shared by both the pushed event handler and the
--- one-shot on-demand snapshot fetch below.
--- @param stats table
local function ApplyWellbeingSnapshot(stats)
    if type(stats) ~= 'table' then return end

    -- LIVE FEATURE FLAG INGEST -- see this file's header "LIVE FEATURE
    -- FLAGS". Done BEFORE anything below reads LiveFeatureFlags, and before
    -- lastStats itself is updated, so ApplyMoveRateModifiers() always acts
    -- on the freshest known flag state for THIS same snapshot. Every entry
    -- is type-checked individually and only overwrites a name this table
    -- already tracks -- a malformed/missing `featureFlags` field (an older
    -- server, or a snapshot from before the very first push) leaves every
    -- flag at its current (or shipped-default) value, never errors, and
    -- never invents a new key.
    if type(stats.featureFlags) == 'table' then
        for flagName in pairs(LiveFeatureFlags) do
            local incoming = stats.featureFlags[flagName]
            if type(incoming) == 'boolean' then
                LiveFeatureFlags[flagName] = incoming
            end
        end
    end

    -- LIVE WELLBEING TUNABLE INGEST -- see this file's header "LIVE
    -- WELLBEING TUNABLES". Same defensive shape as the featureFlags ingest
    -- immediately above: every entry is type-checked individually (a real
    -- number, never NaN -- `incoming == incoming` is Lua's standard NaN
    -- test, matching every other numeric-payload guard in this codebase)
    -- and only overwrites a name this table already tracks -- a malformed/
    -- missing `wellbeingTunables` field (an older server, or a snapshot from
    -- before the very first push) leaves every tunable at its current (or
    -- shipped-default) value, never errors, and never invents a new key.
    if type(stats.wellbeingTunables) == 'table' then
        for tunableName in pairs(LiveWellbeingTunables) do
            local incoming = stats.wellbeingTunables[tunableName]
            if type(incoming) == 'number' and incoming == incoming then
                LiveWellbeingTunables[tunableName] = incoming
            end
        end
    end

    lastStats.fatigue = tonumber(stats.fatigue) or lastStats.fatigue

    ApplyMoveRateModifiers()
end

--- DEVELOPER_REFERENCE.md §13.4.3.1. Pure tick-driven consumer — server/wellbeing.lua's
--- header EVENT/CALLBACK CONTRACT item 8.
--- @param stats table
RegisterNetEvent('qbx_k9unit:client:wellbeingUpdate', function(stats)
    -- SOURCE-ORIGIN GUARD (see client/combat.lua's "SOURCE-ORIGIN GUARD"
    -- header block and DEVELOPER_REFERENCE.md#trust-boundary for the full
    -- writeup; not re-derived here). Without this, a forged local
    -- `TriggerEvent('qbx_k9unit:client:wellbeingUpdate', { fatigue = 999,
    -- ... })` would feed straight into ApplyWellbeingSnapshot() ->
    -- ApplyMoveRateModifiers()'s move-rate composer with zero server
    -- contact. Confidence: MEDIUM-HIGH, the official documented pattern
    -- for distinguishing a genuine server-sent event from a local
    -- self-trigger, not independently verified in-engine.
    if source ~= 65535 then return end

    ApplyWellbeingSnapshot(stats)
end)

-- On-demand snapshot fetch on the moment this client's OWN ped becomes
-- K9-modeled — avoids up to Config.Wellbeing.tickIntervalMs of stale
-- defaults before the server's next automatic tick push. Cheap idle poll
-- otherwise; only runs at all if at least one wellbeing flag is enabled.
if Config.Features.FatigueSystem then
    CreateThread(function()
        local wasK9 = false
        while true do
            local isK9 = IsOwnModelK9()
            if isK9 and not wasK9 then
                -- FAIL-CLOSED GUARD: `lib.callback.await` throws on a
                -- timeout/unregistered-callback rejection rather than
                -- returning nil (see client/main.lua's HasK9Access() doc
                -- comment for the full citation against ox_lib's/FiveM's
                -- real source). This is a `while true do` thread -- an
                -- uncaught throw here would kill this entire loop
                -- permanently (until a resource restart), silently ending
                -- the on-demand snapshot fetch feature for the rest of this
                -- client's session. pcall it; `type(snapshot) == 'table'`
                -- below already treats a nil snapshot as "nothing to
                -- apply."
                local ok, snapshot = pcall(lib.callback.await, 'qbx_k9unit:server:getWellbeingSnapshot', K9_CALLBACK_TIMEOUT_MS)
                if not ok then snapshot = nil end
                if type(snapshot) == 'table' then
                    ApplyWellbeingSnapshot(snapshot)
                end
            end
            wasK9 = isK9
            Wait(2000)
        end
    end)
end

-- ======================================================================
-- NATIVE SPRINT STAMINA ASSIST (owner directive, this pass: "make sure high
-- command can edit the ability to make stamina last longer or even
-- permanently"). DELIBERATELY SEPARATE from this file's own Fatigue
-- move-rate modifier above -- see config.lua's own comment on
-- Config.Wellbeing.Fatigue.nativeStaminaRestorePercent for the full "two
-- different things called stamina" writeup. This section is the client-side
-- half of the SECOND one: GTA/FiveM's own built-in player sprint-stamina
-- limit (the same value client/hud.lua's "Stamina" HUD row displays via
-- GetPlayerSprintStaminaRemaining), a real engine limit this resource
-- previously never touched at all -- confirmed by reading client/hud.lua in
-- full: that file only ever READS the native, never restores it.
--
-- MECHANISM: PLAYER::RESTORE_PLAYER_STAMINA(player, percentage) -- confirmed
-- against FiveM's own natives.json (runtime.fivem.net/doc/natives.json),
-- documented as "Adds a percentage to a players stamina", `percentage`
-- documented as "a percentage that ranges from 0.0 to 1.0 (1.0 being
-- 100%)", with an OFFICIAL example that calls it on a plain repeating timer
-- for exactly this "keep it topped up" purpose
-- (`RestorePlayerStamina(PlayerId(), 0.3)` every 15s). Same `Player`-typed
-- first argument client/hud.lua's own GetPlayerSprintStaminaRemaining(PlayerId())
-- already calls unguarded a few files up this exact same call chain --
-- CONFIDENCE: MEDIUM-HIGH that this is the correct, working native for this
-- purpose (an official, documented example matching this exact use case,
-- not merely community folklore); MEDIUM, honestly, on "restoring on a
-- 1-second cadence reads as literally, continuously full rather than a
-- very-fast-but-still-real sawtooth" -- this codebase has no live FiveM
-- client available to verify the exact depletion-vs-restore timing against,
-- and unlike this file's own Fatigue decay (a plain server-side number this
-- resource fully owns and can subtract exactly zero from), the underlying
-- engine's own depletion rate is not something this file controls or has
-- documented numbers for. At the tunable's max (1.0), this section
-- unconditionally restores to 100% every single check -- the strongest,
-- most frequent assist this native's own contract allows -- which is the
-- honest, provable claim tests/clientwellbeing_spec.lua makes for this
-- section: "every check calls RestorePlayerStamina with exactly the
-- configured percentage", not "the HUD bar visually never moves in a live
-- game" (untestable here).
--
-- GATE: CanShowK9UI() (client/main.lua's own IsOwnModelK9() AND
-- HasK9Access() combinator) -- the standard self-only-ability gate used
-- across this resource, reused rather than inventing a second one. It used
-- to be described as "the same gate this file already uses for
-- RequestK9CalmDown above"; that action, and the Injury block that set the
-- "cheap local flag first" precedent named below, both went with the
-- subsystems removed on 2026-09-02. LiveFeatureFlags.FatigueSystem is
-- still checked FIRST, cheap and local, before CanShowK9UI()'s own native
-- calls.
-- FatigueSystem off means this resource makes NO claim about managing a
-- K9's stamina at all (this file's own established "read at the point of
-- activation" discipline, applied here to a second stamina system, not just
-- the first) -- vanilla behaviour, unmodified, exactly as if this section
-- did not exist.
--
-- ZERO IS THE SAFE, INTENDED DEFAULT, NOT A FOOTGUN: at
-- LiveWellbeingTunables.fatigueNativeStaminaRestorePercent == 0 (the shipped
-- config.lua default), this loop never calls RestorePlayerStamina at all --
-- a server that never raises this tunable sees byte-identical vanilla
-- stamina behaviour to before this pass, no regression by default.
--
-- ALWAYS STARTS, regardless of Config.Features.FatigueSystem's boot-time
-- value -- same "gate at the point it acts, never merely at registration"
-- rule this file's header states for every other section, so a live
-- tablet toggle-ON reaches an already-connected client with no restart.
-- ======================================================================
CreateThread(function()
    while true do
        if LiveFeatureFlags.FatigueSystem
            and LiveWellbeingTunables.fatigueNativeStaminaRestorePercent > 0
            and CanShowK9UI() then
            RestorePlayerStamina(PlayerId(), LiveWellbeingTunables.fatigueNativeStaminaRestorePercent)
        end
        Wait(1000) -- coarse, cheap cadence -- see this section's own header for why 1s is frequent enough for this native's own documented purpose
    end
end)
