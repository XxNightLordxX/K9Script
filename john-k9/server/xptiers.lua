--[[
    john-k9/server/xptiers.lua

    OWNER-DIRECTED FEATURE, the other half of this pass's own quote:
    "...or even add or remove permissions, set experience level for each
    rank up etc." ("add or remove permissions" is a SEPARATE, concurrent
    pass -- migration 0013, k9_permission_keys -- this file owns only
    "set experience level for each rank up".)

    ======================================================================
    WHAT THIS FILE OWNS
    ======================================================================

    A DB-BACKED OVERLAY over `Config.XPTiers` (config.lua), following the
    SAME "config = shipped defaults; DB rows override" shape
    server/certtiers.lua already established for `Config.CertificationTiers`
    -- with one deliberate IMPLEMENTATION difference, chosen for THIS data
    shape specifically (see "WHY IN-PLACE MUTATION, NOT A SEPARATE MERGED
    CATALOG" below): instead of building a second, parallel data structure
    that every reader would need to be taught to consult, this file mutates
    the LIVE `Config.XPTiers[ordinal]` table objects IN PLACE, in memory,
    once at boot (layering persisted `k9_xp_tiers` rows on top of
    config.lua's shipped defaults) and again after every successful tablet
    edit. server/progression.lua's ResolveTier/GetXPTier/GetXPTierMedkitCooldownMs
    -- and every other file that has ever read `Config.XPTiers` directly
    (server/exports.lua's own base-tier fallback) -- already read exactly
    that table, unmodified, with ZERO changes needed to any of them for this
    pass. This is verified, not assumed: grepped every real (non-comment)
    executable reference to `Config.XPTiers` in this codebase before writing
    this file -- every single one lives in server/progression.lua (ResolveTier's
    own walk, plus its onResourceStart shape-guard asserts) or in
    server/exports.lua's one-line `CopyTier(Config.XPTiers[1])` fallback;
    nothing else, client or server, reads the array directly.

    ======================================================================
    WHY IN-PLACE MUTATION, NOT A SEPARATE MERGED CATALOG
    ======================================================================

    server/certtiers.lua builds `TierByKey`/`TierOrder` as an entirely
    separate structure and deliberately never writes back into
    `Config.CertificationTiers` itself -- correct for that file's own shape
    (an OPEN-ENDED, addable/removable/reorderable KEYED catalog, where "the
    key doesn't exist yet" is a real, common state a separate structure must
    represent). `Config.XPTiers` is a different shape entirely: a SMALL,
    FIXED-CARDINALITY, POSITION-ORDERED ladder (this pass does not add or
    remove ranks -- see "SCOPE DECISION" below) where "rank N" always means
    "index N of this exact array", every session, forever. Given that, the
    overlay reduces to "does rank N's stored field win over config.lua's
    shipped value for that same field" -- a question this file can answer by
    directly overwriting `Config.XPTiers[N].xp`/`.label`/etc. in place, with
    three concrete benefits a parallel structure would not have bought:

      1. ZERO FOOTPRINT ON server/progression.lua. That file's ResolveTier/
         GetXPTier/GetXPTierMedkitCooldownMs and its own onResourceStart
         shape-guard asserts are UNCHANGED, BYTE FOR BYTE, by this pass --
         not merely "unaffected in practice", genuinely never edited. Six
         existing spec files load the real server/progression.lua directly
         (tests/progression_spec.lua, tests/xptierunlocks_spec.lua,
         tests/coopsearchbonus_spec.lua, tests/search_spec.lua x2,
         tests/tabletserver_spec.lua) and NONE of them provide a `lib` stub
         in their sandbox env, because that file has never needed one. Had
         this pass added `lib.callback.register(...)` calls to
         server/progression.lua itself (the more obvious "put it next to
         the thing it edits" instinct, matching where server/certtiers.lua
         sits beside server/certifications/), every one of those five
         other specs would have failed to even LOAD that file in their
         sandbox ("attempt to index a nil value 'lib'") the instant this
         pass landed -- a real, verified regression risk (not a guess:
         grepped all five files for `lib` before deciding this), avoided
         entirely by keeping every new callback/mutex/validator in this
         BRAND NEW file instead, which none of those five specs load.
      2. tests/xptierunlocks_spec.lua's OWN established test technique --
         mutating `Config.XPTiers[3].medkitCooldownMultiplier` directly
         between assertions and expecting the very next
         GetXPTierMedkitCooldownMs call to see it -- keeps working
         completely unmodified. A parallel merged-catalog cache (rebuilt
         only at explicit refresh points, the way server/certtiers.lua's
         own `TierByKey` is) would have broken that exact test technique,
         since a direct field mutation on `Config.XPTiers[3]` would no
         longer reach whatever separate cached copy ResolveTier had started
         reading from instead.
      3. AwardXP/AwardXPDirect's own `newTier ~= oldTier` REFERENCE-EQUALITY
         tier-crossing detection (server/progression.lua, CopyTier's own doc
         comment explains why it matters) is naturally preserved: this file
         never REPLACES a `Config.XPTiers[N]` table object, only ever
         mutates its fields, so the same table object remains `==` itself
         across an edit. Re-verified this cannot interleave WITHIN a single
         AwardXP/AwardXPDirect call before relying on it: neither function
         has an `await`/yield point between its own `oldTier`/`newTier`
         reads (the DB write happens in a separately spawned CreateThread,
         confirmed by reading both functions in full) -- FXServer's Lua VM
         is single-threaded/cooperatively scheduled, so a concurrent edit
         from THIS file can only ever land BETWEEN two separate AwardXP
         calls, never inside one, which is exactly as safe as an edit made
         to config.lua itself and a `/restart` between two award calls
         already was, long before this pass existed.

    ======================================================================
    SCOPE DECISION -- EDIT EXISTING RANKS ONLY, NEVER ADD/REMOVE/REORDER
    ======================================================================

    Stated once, plainly, so it is a decision and not a silent omission.
    This pass's own owner quote is "set experience level for each rank UP"
    -- editing existing thresholds -- not "add tiers, rename them" (that is
    the OTHER, concurrently-landing pass's own quote, for the permission-key
    catalog, migration 0013). Three independent reasons this file does not
    generalize to an open-ended add/remove/reorder surface the way
    server/certtiers.lua does for certification tiers:

      1. THE FIXED-0-BASELINE INVARIANT. server/progression.lua's own
         onResourceStart shape guard requires `Config.XPTiers[1].xp == 0`
         exactly, unconditionally, and ResolveTier's own walk requires the
         array to already be in strictly-ascending order BY ARRAY POSITION
         (no `break`, no re-sort -- see that file's own comments). Adding or
         removing a rank would mean renumbering every ordinal after the
         change point, which is a fundamentally bigger, riskier operation
         than "rank N keeps being rank N, only its stored values change" --
         and the owner's own words for this task do not ask for it.
      2. NO PERSISTED PER-CITIZENID TIER IDENTITY TO MIGRATE. Unlike
         `k9_certifications.tier` (a real, stored VARCHAR column,
         migration 0006), NO citizenid anywhere in this schema ever stores
         "my current XP tier" as a value -- GetXPTier/ResolveTier always
         RECOMPUTE it live, on every call, from the citizenid's raw
         accumulated XP total against whatever thresholds are CURRENTLY
         live (see "THE ALREADY-PROMOTED PLAYER" below for the full
         consequence of that design). Deleting a certification tier needs a
         real migration story for existing `k9_certifications` rows
         pointing at it (server/certtiers.lua's own HAZARD 2); deleting an
         XP rank has no equivalent stored reference to migrate at all --
         there is nothing pointing at "rank 3" for a delete to leave
         dangling. This makes add/remove a much smaller technical problem
         for XP tiers than for certification tiers, but the owner did not
         ask for it here, and the fixed-cardinality invariant above (point
         1) is real cost with no corresponding ask to justify paying it.
      3. NO "the same race" TO CLOSE FOR ADD/REMOVE, BECAUSE THERE IS NO
         ADD/REMOVE. The task brief that produced this file explicitly
         raised "the delete/edit race" server/certtiers.lua's own
         TierEditMutex closes (a concurrent DeleteTier vs SetCertificationTier
         interleaving across their own MySQL.await yield points) and asked
         this file to close the equivalent hazard IF ranks can be added or
         removed. They cannot be, by this file's own design (this section),
         so that specific race does not exist here to close. The race this
         file DOES have to close -- and does, via `XPTierEditMutex` below --
         is a narrower one: two CONCURRENT EDITS (not an edit racing a
         delete) interleaving across their own MySQL.await yield points,
         each independently re-validating the whole ladder against a
         SNAPSHOT that is stale by the time it writes. See "THE WALK-INTO-
         INVALID-STATE HAZARD" below for the concrete two-edit sequence this
         closes.

    ======================================================================
    THE ALREADY-PROMOTED PLAYER -- DECIDED DELIBERATELY, NOT DISCOVERED IN
    PRODUCTION
    ======================================================================

    THE QUESTION: high command raises Elite's threshold from 9000 to 15000.
    A citizenid sitting at 10000 XP, who a moment ago resolved to Elite,
    now resolves to whatever rank's threshold is <= 10000 instead (Veteran,
    per the shipped defaults). What happens to them?

    DECISION: THEY ARE RE-RANKED IMMEDIATELY, LIKE EVERY OTHER CITIZENID,
    WITH NO GRANDFATHERING, AND THIS FILE MAKES THAT VISIBLE RATHER THAN
    LETTING IT HAPPEN SILENTLY. This is not a new hazard this pass
    introduces -- it is the SAME thing that already happens today, with
    ZERO code in this file, the instant an operator hand-edits
    `Config.XPTiers` in config.lua and runs `/restart john-k9`: every
    online citizenid's tier is recomputed from scratch the next time
    anything reads it, because tier has NEVER been a stored grant for XP
    (see "SCOPE DECISION" point 2 above) -- it is always a live function of
    "this citizenid's raw XP total" against "whatever thresholds are
    current right now". A persisted, grandfathered "you keep the rank you
    already reached" concept does not exist anywhere in this resource's XP
    design today, and inventing one here -- effectively a SECOND, tier-like
    stored value alongside the real XP total, needing its own migration,
    its own resolution order against the live thresholds, and its own
    answer to "what happens when the grandfathered floor ITSELF becomes
    unreachable after a future re-tune" -- would be a materially larger,
    undiscussed change to how XP has always worked in this resource, for a
    problem the owner's own ask ("set experience level for each rank") does
    not raise.

    What THIS pass changes is narrower and purely about VISIBILITY: before
    this file existed, that same re-ranking could only ever happen at a
    `/restart` (config.lua is a shared_script, re-read fresh only at
    resource start) -- players are, practically, always offline for that
    moment. This file makes the identical mechanic reachable WHILE PLAYERS
    ARE ONLINE, from a live tablet edit, which makes it a live, visible,
    mid-session event for the first time. Two things this file does about
    that, neither of which existed before this pass because there was
    nothing to react to before this pass:
      1. EVERY successful edit immediately pushes a fresh, authoritative
         `john-k9:client:xpTierChanged` snapshot to every CURRENTLY
         CONNECTED citizenid whose resolved tier this edit could plausibly
         have touched (PushRefreshedSnapshotsAfterEdit below) -- so nobody
         keeps a stale, now-incorrect speedMultiplier/scentRangeMultiplier
         until their next AwardXP call happens to cross a bracket again
         (which could otherwise be hours away, or never, if they are
         already at the top of whatever bracket they are stuck in).
         client/progression.lua's own existing xpTierChanged handler
         already only shows a "you leveled up" toast on a genuine LABEL
         change (never on a same-tier refresh), so this refresh is silent
         for anyone whose bracket did not move, and correctly surfaces a
         notification for anyone whose bracket did -- ZERO client-side
         changes needed for this file's own push to behave correctly.
      2. The edit's own response includes a non-optional `warning` string,
         SURFACED IN THE ACTUAL SERVER RESPONSE (not merely printed to
         console) whenever this edit demoted at least one currently-online
         citizenid, stating plainly how many, mirroring
         server/certtiers.lua's own ReorderTiers "every citizenid already
         holding one of the reordered tiers is now ranked at its NEW
         position immediately" disclosure convention exactly. High command
         sees the blast radius of their own edit at the moment they make
         it, not the first time an officer complains their dog got slower.
      3. SELF-SERVICE VISIBILITY (economy red-team follow-up, coder-security
         pass -- the ONE gap the original version of this section did not
         close): the demotion-only accounting above has an asymmetry a
         high-command account can exploit. LOWERING a threshold never
         demotes anyone -- it can only PROMOTE currently-online citizenids
         who now clear a lower bar, including the acting officer themselves
         or an ally, with zero additional XP earned. Under the ORIGINAL
         demoted-only counting, that edit produced `demotedCount == 0`, so
         NO warning was shown and the audit line carried no trace of who
         gained a rank -- exactly the "quietly self-grant, then quietly
         revert" shape this pass exists to close. Silence was never a
         deliberate design choice here; it was an oversight in which
         direction of re-ranking got counted. FIXED:
         PushRefreshedSnapshotsAfterEdit now counts and NAMES (by citizenid)
         BOTH directions -- promoted and demoted -- and the audit line
         records both counts and both citizenid lists whenever either is
         non-zero, so a revert (which demotes exactly whoever the original
         edit promoted) is exactly as visible in the log as the promotion
         it undoes. Promotions get LOUDER treatment than demotions, not
         merely equal treatment: the response `warning` for a promotion
         states plainly that the named citizenid(s) gained a rank's
         speed/scent bonuses with NO additional XP earned, and separately
         calls out when the ACTING OFFICER'S OWN citizenid is among those
         promoted (a `SELF-PROMOTION` marker, both in the audit `detail` and
         in the response `warning`) -- reliably detectable because the
         officer is, by construction, online and authenticated at the exact
         moment they submit the edit that reaches this code, so their own
         citizenid is always present in `beforeOnlineSnapshot` alongside
         everyone else's. This is disclosure, not a new gate: the edit
         still completes in one action, exactly as before -- high command
         can still self-promote if the config genuinely allows it (nothing
         here is a privilege-escalation surface -- see the file-top
         "CAPABILITY_CATALOG-equivalent" note), it just can no longer do so
         invisibly.
      4. What this file deliberately does NOT do, per HAZARD "NO UNBOUNDED
         TRAP" below (mirroring server/certtiers.lua's own HAZARD 5): it
         never force-ends or interrupts an in-progress action because a
         threshold edit changed someone's tier mid-use -- only the request-
         time speedMultiplier/scentRangeMultiplier/medkitCooldownMultiplier
         going forward are affected, exactly like every other tier crossing
         this resource has ever produced.

    ======================================================================
    THE WALK-INTO-INVALID-STATE HAZARD -- DECIDED: WHOLE-LADDER ATOMIC
    VALIDATION, NOT PER-EDIT NEIGHBOR-ONLY VALIDATION
    ======================================================================

    Both are provably sufficient IF implemented correctly (a strictly-
    ascending array stays strictly ascending after one element changes IFF
    the edited element's two immediate neighbors are re-checked against its
    NEW value) -- but "implemented correctly" is exactly the part a future
    edit to this file could get wrong in one specific, realistic way: a
    validator that compares the SUBMITTED value against `Config.XPTiers`'
    STATIC, CONFIG-AUTHORED neighbor values instead of the LIVE, currently-
    in-effect ones (which may already carry an earlier tablet edit this
    same boot). Concretely, with shipped defaults [0, 1250, 4000, 9000]:
      Edit 1: rank 3 (Veteran) 4000 -> 8990. Valid: 1250 < 8990 < 9000.
              Live ladder is now [0, 1250, 8990, 9000].
      Edit 2: rank 4 (Elite) 9000 -> 5000. A validator comparing against
              rank 3's STATIC CONFIG value (4000, not the live 8990) sees
              5000 > 4000 and wrongly ALLOWS it -- producing a live ladder
              of [0, 1250, 8990, 5000], INVERTED, even though each edit was
              individually checked against *something*.
    Neither edit above is invalid by itself against the CORRECT (live)
    comparison; the bug is entirely in comparing against stale data. This
    file closes that class of bug structurally rather than by promising to
    remember it: `xpTiersUpsert` below builds the FULL TENTATIVE 1..N
    threshold ARRAY -- the live value for every rank EXCEPT the one being
    edited, substituted with the new value -- and re-verifies STRICT
    ascending order across the ENTIRE array, from scratch, on every single
    edit (BuildTentativeThresholds/IsStrictlyAscending below), rather than
    hand-checking just the two neighbors. This costs four comparisons
    (this ladder is never larger than a handful of ranks) in exchange for
    removing an entire class of "did I remember to read the LIVE neighbor,
    not the config default" bug from ever being possible to introduce,
    today or in a future edit to this file. The persisted-row BOOT LOADER
    (ApplyPersistedXPTierOverrides below) applies the identical discipline
    for the same reason, one level up: it validates every individual row's
    OWN fields first (clamp-and-warn, per-field), then re-verifies the
    RESULTING FULL LADDER (every rank's field-validated value, config
    defaults for any rank with no persisted row at all) is strictly
    ascending BEFORE applying anything -- an all-or-nothing gate, refusing
    to apply ANY persisted override at all (falling back entirely to
    config.lua's shipped, already-known-valid ladder) rather than risk
    applying a broken combination that could only arise from a hand-edited
    database, since no two rows can ever conflict this way through this
    file's own `xpTiersUpsert`, which already re-validates the whole ladder
    on every single write it makes.

    Concurrency for the SAME hazard: two high-command sessions submitting
    an edit at the same instant each read a "live" snapshot before their
    own `K9Store.XPTier_Upsert` await point, and could each independently
    validate against a snapshot the other is about to invalidate. Closed by
    `XPTierEditMutex` below -- a SINGLE, LADDER-WIDE mutex (not one keyed
    per-rank the way server/certtiers.lua's `TierEditMutex` is keyed per
    tier_key), because THIS file's own validation is never local to one
    rank -- it always depends on the CURRENT value of every other rank, so
    two edits to two DIFFERENT ranks still need to serialize against each
    other for the whole-ladder check above to mean anything. Coarse, and
    deliberately so: edits here are a rare, high-command-gated
    administrative action (server/certtiers.lua's own tier-audit tables
    accept the identical "not ordinary gameplay volume" tradeoff), not a
    hot path, so serializing ALL of them behind one lock costs nothing a
    real operator would ever notice.

    NOT THE SAME MUTEX AS server/certtiers.lua's `TierEditMutex`, AND NEVER
    ACQUIRED TOGETHER WITH IT, IN EITHER ORDER, BY ANY CODE PATH IN THIS
    RESOURCE -- confirmed by reading every call site of both: `TierEditMutex`
    guards `k9_certification_tiers`/`k9_certifications.tier` writes only
    (server/certtiers.lua, server/certifications/'s SetCertificationTier);
    `XPTierEditMutex` guards `Config.XPTiers`/`k9_xp_tiers` writes only,
    entirely within this one file. Two disjoint lock domains that never
    nest inside one another cannot deadlock against each other.

    ======================================================================
    HAZARD -- NO UNBOUNDED TRAP
    ======================================================================

    Mirrors server/certtiers.lua's own HAZARD 5 exactly, restated for this
    file's own surface: nothing here gates, force-ends, or interrupts any
    termination/cleanup path (EndActiveEffectForHolder, a leash detach,
    Recall, a partnership break, or anything else that UNDOES an
    already-open effect). A tier edit only ever changes what a FUTURE
    speedMultiplier/scentRangeMultiplier/medkitCooldownMultiplier lookup
    returns; it never reaches into an action already in progress. This file
    adds no new gate of any kind (it is a display-and-arithmetic
    modifier, not an authorization surface -- reaching a rank has never
    granted a permission or bypassed one, and this pass does not change
    that), so there is no unbounded-trap shape to build here in the first
    place, independent of the "no interruption" property stated above.

    ======================================================================
    ZERO-THRESHOLD / NON-POSITIVE-VALUE FOOTGUN
    ======================================================================

    This resource has already been bitten once by a non-positive value
    being read as "permanently on" rather than "off"
    (server/cooldowns.lua's own `IsOnCooldown`, see that file's own
    `ResolveConfiguredThresholdMs` doc comment for the incident writeup).
    Two concrete places this file must not repeat that shape, both
    defended against explicitly rather than assumed safe:
      * `medkitCooldownMultiplier`, if this file ever let a non-positive
        value through, would flow straight into
        GetXPTierMedkitCooldownMs -- but that function ALREADY independently
        clamps-and-ignores any multiplier outside `(0, 1]` (its own doc
        comment: "a multiplier that is missing, non-numeric, NaN, <= 0, or
        > 1 returns baseCooldownMs UNCHANGED"), so a bad value written here
        could never actually reach server/cooldowns.lua's IsOnCooldown as a
        non-positive threshold even if this file's own validation had a
        bug. This file's OWN `IsValidMultiplier` below still independently
        rejects anything outside `(0, 1]` for this specific field at WRITE
        time -- belt AND suspenders, not reliance on the downstream clamp
        alone, so a rejected edit gets an honest `invalid_medkit_cooldown_multiplier`
        reason instead of a silent no-op discovered later.
      * `xp` (the threshold itself): NEVER validated as "non-zero" in
        isolation -- rank 1 is REQUIRED to be exactly 0 (the mandatory
        baseline ResolveTier's own onResourceStart guard enforces), and
        every other rank's `xp` is already forced to be a POSITIVE, whole
        number strictly greater than the rank below it by the whole-ladder
        ascending check above (rank 1 = 0 is the floor every other rank
        must clear). There is no comparison anywhere in this file of the
        shape "is this threshold falsy/zero, therefore treat the rank as
        off/unlimited" -- ranks are not features that can be "off"; a
        threshold is just a number XP is compared against with plain `>=`,
        exactly as server/progression.lua's own ResolveTier already does.

    ======================================================================
    AUTHORIZATION -- identical posture to server/certtiers.lua's own HAZARD
    4, restated briefly rather than re-argued: `CanManageXPTiers(source)`
    below re-resolves `IsHighCommand(source)` FRESH, server-side, on every
    single call, against `source`'s CURRENT PlayerData/job/grade -- no
    caching, no trusting a client-supplied flag, no delegation via
    server/permissions.lua's HasPermission (same disclosed, deliberate
    scope decision server/certtiers.lua's own CanManageCertTiers documents
    for the identical reason: the owner's own words name "high command"
    specifically, a plain rank check).
    ======================================================================
]]

-- ======================================================================
-- CAPABILITY_CATALOG-equivalent: there is none here. Every editable field
-- on a rank (xp/label/speedMultiplier/scentRangeMultiplier/
-- medkitCooldownMultiplier/badge) is a plain, bounded number or a filtered
-- display string -- there is no closed-vocabulary "capability" concept for
-- XP tiers the way server/certtiers.lua's CAPABILITY_CATALOG exists for
-- certification tiers, so there is no privilege-escalation surface of that
-- shape to defend here: nothing this file lets an operator write can ever
-- grant a permission, become high command, or bypass IsHighCommand --
-- these six fields feed movement speed, scent range, a medkit cooldown
-- multiplier (itself independently re-clamped downstream -- see header),
-- and cosmetic display text, never an authorization decision.
-- ======================================================================

-- OWNER-EDITABLE CEILING (this pass, coder-backend) -- owner's own words:
-- "Keep the speed and stamina editing where i can edit it to as high as i
-- want." Was a hardcoded 3.0; now read fresh from config.lua's
-- `Config.MaxSpeedScentMultiplier` at this file's own load time, via the
-- local resolver immediately below. Config.MaxSpeedScentMultiplier's own
-- comment in config.lua carries the plain-English "this does not raise
-- client/movement.lua's separate 2.0x visible-speed clamp" disclosure --
-- not repeated here.
--- Owner-editable ceiling for speedMultiplier/scentRangeMultiplier, read
--- fresh from config.lua at this file's own load time. CLAMPS AND WARNS,
--- never asserts -- a bare top-level `assert` on a value an OPERATOR can
--- reach (a mistyped config.lua) would silently abort every registration
--- in THIS FILE from that point on, for the rest of this resource's
--- uptime (see server/cooldowns.lua's own ResolveConfiguredThresholdMs doc
--- comment for the incident this mirrors, and this file's own header
--- "SANITIZATION -- CLAMP AND WARN, NOT ASSERT" for the identical posture
--- already established here for persisted rows). Falls back to 10.0
--- (config.lua's own shipped default) for anything that is not a real,
--- positive, finite number: missing, non-numeric, NaN, infinity, zero, or
--- negative. Duplicated in server/k9profiles.lua and
--- server/runtimecontrol.lua rather than shared -- this resource's
--- established "no cross-file `local` import mechanism" convention (see
--- server/k9profiles.lua's own header, "BOUNDS -- REUSED, NOT REINVENTED").
--- @return number
local function ResolveMaxSpeedScentMultiplier()
    local fallback = 10.0
    local raw = Config and Config.MaxSpeedScentMultiplier
    local value = tonumber(raw)
    if value == nil or value ~= value or value == math.huge or value == -math.huge or value <= 0 then
        print(('[John-K9] xptiers: Config.MaxSpeedScentMultiplier is missing or not a valid positive number (found: %s). Using the built-in fallback of %s instead -- find Config.MaxSpeedScentMultiplier in config.lua and set it to a positive number.'):format(tostring(raw), tostring(fallback)))
        return fallback
    end
    return value
end

local MAX_SPEED_SCENT_MULTIPLIER = ResolveMaxSpeedScentMultiplier()

-- Matches GetXPTierMedkitCooldownMs's OWN downstream `(0, 1]` contract
-- exactly (server/progression.lua) -- a value this file accepted outside
-- that range would simply be silently ignored by that function later,
-- which is a worse operator experience than an honest rejection now.
local MAX_MEDKIT_COOLDOWN_MULTIPLIER = 1.0

local XP_TIER_ACTION_COOLDOWN_MS = 1000

--- @param value any
--- @return boolean
local function IsFiniteNumber(value)
    return type(value) == 'number' and value == value and value ~= math.huge and value ~= -math.huge
end

--- Non-negative WHOLE number -- matches every shipped Config.XPTiers `xp`
--- value's own shape (XP totals are integer accumulations, per
--- server/progression.lua's AwardXP). Rank-1's own additional "must be
--- exactly 0" rule is enforced by the CALLER (this file's own
--- onResourceStart loader and xpTiersUpsert below), not here -- this
--- predicate alone answers "is this a plausible XP threshold at all",
--- independent of which rank it is for.
--- @param value any
--- @return boolean
local function IsValidXpThreshold(value)
    return IsFiniteNumber(value) and value >= 0 and value == math.floor(value)
end

--- Character filter mirroring server/certtiers.lua's own IsValidTierLabel
--- (itself mirroring server/runtimecontrol.lua's IsSafeHeaderTitle) --
--- duplicated here rather than shared, since this file has no import
--- mechanism to reach either one, same "duplicated, not shared" precedent
--- server/progression.lua's own CopyTier doc comment states for its
--- relationship to server/exports.lua's ShallowCopyTier.
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

--- @param value any
--- @return boolean
local function IsValidLabel(value)
    return IsSafeShortString(value, 60) -- matches k9_xp_tiers.label VARCHAR(60)
end

--- @param value any
--- @return boolean
local function IsValidBadge(value)
    return IsSafeShortString(value, 30) -- matches k9_xp_tiers.badge VARCHAR(30)
end

--- @param value any
--- @param maxAllowed number
--- @return boolean
local function IsValidMultiplier(value, maxAllowed)
    return IsFiniteNumber(value) and value > 0 and value <= maxAllowed
end

--- Copies a Config.XPTiers-shaped entry into a fresh table before it ever
--- leaves this file over the network -- identical purpose and identical
--- duplication decision as server/progression.lua's own CopyTier (see that
--- function's doc comment for why handing out the live
--- `Config.XPTiers[n]` reference itself would be unsafe: an external
--- resource's event handler could mutate `tier.speedMultiplier` in place
--- and corrupt movement speed for every K9 in that bracket, resource-wide).
--- @param tier table
--- @return table copy
local function CopyXPTier(tier)
    local copy = {}
    for key, value in pairs(tier) do copy[key] = value end
    return copy
end

--- @return number n -- #Config.XPTiers, read live every call (never cached)
--- so this file always agrees with whatever config.lua's own shipped
--- ladder length currently is, including a future dev adding a 5th rank
--- with no code change needed here.
local function RankCount()
    return type(Config.XPTiers) == 'table' and #Config.XPTiers or 0
end

--- @param ordinal any
--- @return boolean
local function IsValidOrdinal(ordinal)
    local n = RankCount()
    return type(ordinal) == 'number' and ordinal == math.floor(ordinal) and ordinal >= 1 and ordinal <= n
end

--- Builds the full 1..N tentative threshold array -- every rank's CURRENT
--- LIVE `Config.XPTiers[i].xp`, except `ordinal`, which is substituted with
--- `newXp`. See header "THE WALK-INTO-INVALID-STATE HAZARD" for exactly
--- why this reads LIVE values (never a cached/stale/config-only snapshot)
--- and substitutes only the one rank actually being edited.
--- @param ordinal number
--- @param newXp number
--- @return number[] thresholds
local function BuildTentativeThresholds(ordinal, newXp)
    local n = RankCount()
    local thresholds = {}
    for i = 1, n do
        thresholds[i] = (i == ordinal) and newXp or Config.XPTiers[i].xp
    end
    return thresholds
end

--- @param thresholds number[]
--- @return boolean ok, number? badIndex -- badIndex is the LOWER of the two offending ranks (1-based)
local function IsStrictlyAscending(thresholds)
    for i = 2, #thresholds do
        if not (type(thresholds[i]) == 'number' and type(thresholds[i - 1]) == 'number' and thresholds[i] > thresholds[i - 1]) then
            return false, i - 1
        end
    end
    return true
end

--- @return table[] -- { { ordinal, xp, label, speedMultiplier, scentRangeMultiplier, medkitCooldownMultiplier?, badge?, xpLocked }, ... }
local function ListXPTiersSnapshot()
    local list = {}
    for i = 1, RankCount() do
        local copy = CopyXPTier(Config.XPTiers[i])
        copy.ordinal = i
        -- Rank 1's threshold can never be edited through this surface --
        -- see header "SCOPE DECISION" point 1 (server/progression.lua's own
        -- mandatory `Config.XPTiers[1].xp == 0` baseline). Surfaced to the
        -- tablet so it can render that one field read-only rather than
        -- accepting an edit this file will always refuse anyway.
        copy.xpLocked = (i == 1)
        list[#list + 1] = copy
    end
    return list
end

-- ======================================================================
-- AUTHORIZATION -- see header. Re-verified on EVERY call, never cached.
-- ======================================================================

--- @param source number
--- @return string? citizenid
local function ResolveCitizenId(source)
    local Player = exports.qbx_core:GetPlayer(source)
    local citizenid = Player and Player.PlayerData and Player.PlayerData.citizenid
    if type(citizenid) == 'string' and citizenid ~= '' then return citizenid end
    return nil
end

--- @param source number
--- @return boolean authorized, string? citizenid
local function CanManageXPTiers(source)
    local citizenid = ResolveCitizenId(source)
    if type(IsHighCommand) == 'function' and IsHighCommand(source) then
        return true, citizenid
    end
    return false, citizenid
end

-- Single, ladder-wide mutex -- see header "THE WALK-INTO-INVALID-STATE
-- HAZARD" for why this is ONE lock (not one per rank) and why it can never
-- deadlock against server/certtiers.lua's own, entirely separate,
-- TierEditMutex. Held for a fixed, constant key -- there is only ever one
-- ladder in this resource, never one per job/citizenid/anything else.
local XPTierEditMutex = NewMutex()
local XPTIER_LADDER_LOCK_KEY = 'xp_tier_ladder'

-- Anti-fat-finger/double-submit rate limit, keyed by the ACTING officer's
-- own source -- mirrors server/certtiers.lua's CertTierActionCooldown
-- exactly. Every caller reaching this point is already confirmed high
-- command by CanManageXPTiers above; this guards against a held key or a
-- double-submitted click, not abuse.
local XPTierActionCooldown = NewCooldown(XP_TIER_ACTION_COOLDOWN_MS)
XPTierActionCooldown.RegisterPlayerDropped()

-- ======================================================================
-- PERSISTENCE -- CLAMP AND WARN, NEVER A TOP-LEVEL ASSERT. See header
-- "ZERO-THRESHOLD / NON-POSITIVE-VALUE FOOTGUN" and this codebase's own
-- server/cooldowns.lua ResolveConfiguredThresholdMs doc comment for the
-- incident behind that rule: a bare top-level `assert` on a value an
-- OPERATOR can reach (here: a hand-edited `k9_xp_tiers` row, or -- in
-- principle, though this file's own xpTiersUpsert never produces one -- a
-- malformed persisted row from some future bug) would silently abort every
-- registration in THIS FILE from that point on, for the rest of this
-- resource's uptime, over a value nobody but this file's own code ever
-- reads. Every function below degrades a bad ROW to "ignore it, fall back
-- to config.lua's own already-known-good default for that rank" and prints
-- loudly instead.
-- ======================================================================

--- Validates and normalizes ONE persisted `k9_xp_tiers` row against the
--- CURRENT `Config.XPTiers` shape, falling back to that rank's own
--- config.lua default for any individually-invalid field rather than
--- discarding the whole row over one bad field -- EXCEPT `ordinal`/`xp`,
--- which invalidate the WHOLE row if unusable (there is no safe partial
--- fallback for "which rank is this row even for", and a bad threshold
--- cannot be silently replaced with a fallback here without also
--- re-deriving whether the fallback itself would still keep the ladder
--- ascending, which is the caller's own job -- see
--- ApplyPersistedXPTierOverrides below).
--- @param row table -- raw DB row: ordinal, xp_threshold, label, speed_multiplier, scent_range_multiplier, medkit_cooldown_multiplier, badge
--- @return boolean ok, number? ordinal, table? fields
local function SanitizeLoadedRow(row)
    local ordinal = tonumber(row.ordinal)
    if not IsValidOrdinal(ordinal) then
        print(('[John-K9] xptiers: ignoring persisted k9_xp_tiers row with out-of-range ordinal %s (this ladder currently has %d rank(s)) -- that rank keeps its config.lua default'):format(tostring(row.ordinal), RankCount()))
        return false
    end

    local fallback = Config.XPTiers[ordinal]
    local xp = tonumber(row.xp_threshold)

    if ordinal == 1 then
        -- MANDATORY BASELINE -- see header "SCOPE DECISION" point 1. A
        -- hand-edited row attempting to move rank 1 off 0 is CLAMPED, not
        -- merely rejected outright, because the rest of the row (label,
        -- multipliers) may still be perfectly legitimate and worth keeping.
        if xp ~= 0 then
            print(('[John-K9] xptiers: ignoring persisted xp_threshold=%s for rank 1 -- rank 1 must always be exactly 0 XP (server/progression.lua\'s own mandatory baseline) -- forcing 0 for this rank; every other field in this row is still applied if individually valid'):format(tostring(row.xp_threshold)))
        end
        xp = 0
    elseif not IsValidXpThreshold(xp) then
        print(('[John-K9] xptiers: ignoring persisted k9_xp_tiers row for rank %d entirely -- invalid xp_threshold %s -- falling back to config.lua\'s default (%s XP) for this rank'):format(ordinal, tostring(row.xp_threshold), tostring(fallback.xp)))
        return false
    end

    local fields = { xp = xp }

    if IsValidLabel(row.label) then
        fields.label = row.label
    else
        print(('[John-K9] xptiers: ignoring invalid persisted label for rank %d -- falling back to config.lua\'s default (%q)'):format(ordinal, fallback.label))
        fields.label = fallback.label
    end

    if IsValidMultiplier(row.speed_multiplier, MAX_SPEED_SCENT_MULTIPLIER) then
        fields.speedMultiplier = row.speed_multiplier
    else
        print(('[John-K9] xptiers: ignoring invalid persisted speed_multiplier %s for rank %d -- falling back to config.lua\'s default (%s)'):format(tostring(row.speed_multiplier), ordinal, tostring(fallback.speedMultiplier)))
        fields.speedMultiplier = fallback.speedMultiplier
    end

    if IsValidMultiplier(row.scent_range_multiplier, MAX_SPEED_SCENT_MULTIPLIER) then
        fields.scentRangeMultiplier = row.scent_range_multiplier
    else
        print(('[John-K9] xptiers: ignoring invalid persisted scent_range_multiplier %s for rank %d -- falling back to config.lua\'s default (%s)'):format(tostring(row.scent_range_multiplier), ordinal, tostring(fallback.scentRangeMultiplier)))
        fields.scentRangeMultiplier = fallback.scentRangeMultiplier
    end

    -- Both OPTIONAL fields -- `nil`/absent is a perfectly valid state
    -- (server/progression.lua's own GetXPTierMedkitCooldownMs/HUD-badge
    -- consumers already treat a missing field as "not configured", never
    -- an error). A present-but-INVALID value falls back to config.lua's own
    -- default for that field (which may itself be nil), never to some
    -- invented value.
    if row.medkit_cooldown_multiplier == nil then
        fields.medkitCooldownMultiplier = fallback.medkitCooldownMultiplier
    elseif IsValidMultiplier(row.medkit_cooldown_multiplier, MAX_MEDKIT_COOLDOWN_MULTIPLIER) then
        fields.medkitCooldownMultiplier = row.medkit_cooldown_multiplier
    else
        print(('[John-K9] xptiers: ignoring invalid persisted medkit_cooldown_multiplier %s for rank %d -- falling back to config.lua\'s default (%s)'):format(tostring(row.medkit_cooldown_multiplier), ordinal, tostring(fallback.medkitCooldownMultiplier)))
        fields.medkitCooldownMultiplier = fallback.medkitCooldownMultiplier
    end

    if row.badge == nil then
        fields.badge = fallback.badge
    elseif IsValidBadge(row.badge) then
        fields.badge = row.badge
    else
        print(('[John-K9] xptiers: ignoring invalid persisted badge %s for rank %d -- falling back to config.lua\'s default (%s)'):format(tostring(row.badge), ordinal, tostring(fallback.badge)))
        fields.badge = fallback.badge
    end

    return true, ordinal, fields
end

--- @param ordinal number
--- @param fields table
local function ApplyFieldsToConfigXPTier(ordinal, fields)
    local tier = Config.XPTiers[ordinal]
    tier.xp = fields.xp
    tier.label = fields.label
    tier.speedMultiplier = fields.speedMultiplier
    tier.scentRangeMultiplier = fields.scentRangeMultiplier
    tier.medkitCooldownMultiplier = fields.medkitCooldownMultiplier -- assigning nil removes the key, matching an unset config field exactly
    tier.badge = fields.badge
end

--- Layers every persisted `k9_xp_tiers` row on top of config.lua's shipped
--- defaults, ALL-OR-NOTHING for the whole-ladder ascending property -- see
--- header "THE WALK-INTO-INVALID-STATE HAZARD" for why a partial apply is
--- never attempted once any row's threshold has been sanitized: two
--- individually-sane rows can still combine into a non-ascending ladder,
--- and this file's own `xpTiersUpsert` already prevents that from ever
--- happening through this file's own writes -- reaching that state here
--- can only mean the database was edited outside this resource's own code
--- path (documented, not assumed unreachable).
local function ApplyPersistedXPTierOverrides()
    local rowsOk, rows = pcall(K9Store.XPTier_GetAllRows)
    if not rowsOk then
        print(('[John-K9] xptiers: could not read persisted k9_xp_tiers rows (%s) -- every rank is using its config.lua default for this session'):format(tostring(rows)))
        return
    end
    if type(rows) ~= 'table' or #rows == 0 then return end

    local n = RankCount()
    local fieldsByOrdinal = {}
    for _, row in ipairs(rows) do
        local ok, ordinal, fields = SanitizeLoadedRow(row)
        if ok then fieldsByOrdinal[ordinal] = fields end
    end

    if next(fieldsByOrdinal) == nil then return end

    local thresholds = {}
    for i = 1, n do
        local fields = fieldsByOrdinal[i]
        thresholds[i] = fields and fields.xp or Config.XPTiers[i].xp
    end

    local ok, badIndex = IsStrictlyAscending(thresholds)
    if not ok then
        print(('[John-K9] xptiers: REFUSING to apply ANY persisted k9_xp_tiers override this boot -- the resulting ladder would not be strictly ascending (rank %d = %s XP, rank %d = %s XP). This should be UNREACHABLE through this file\'s own xpTiersUpsert (which re-validates the whole ladder before every write) -- seeing this means k9_xp_tiers was edited outside this resource\'s own code path. Every rank is using its config.lua default for this session; fix or clear the offending row(s) in k9_xp_tiers and restart.'):format(
            badIndex, tostring(thresholds[badIndex]), badIndex + 1, tostring(thresholds[badIndex + 1])))
        return
    end

    local applied = 0
    for ordinal, fields in pairs(fieldsByOrdinal) do
        ApplyFieldsToConfigXPTier(ordinal, fields)
        applied = applied + 1
    end
    print(('[John-K9] xptiers: applied %d persisted rank override(s) from k9_xp_tiers on top of config.lua\'s shipped defaults.'):format(applied))
end

-- ======================================================================
-- ONLINE-REFRESH ON EDIT -- see header "THE ALREADY-PROMOTED PLAYER".
-- ======================================================================

--- @return table<string, {src: number, xp: number}>
local function SnapshotOnlineCitizenXpForRefresh()
    local snapshot = {}
    if type(GetXPTier) ~= 'function' then return snapshot end
    if not (type(Config.Features) == 'table' and Config.Features.XPProgression) then return snapshot end

    for _, playerIdStr in ipairs(GetPlayers()) do
        local src = tonumber(playerIdStr)
        if src then
            local Player = exports.qbx_core:GetPlayer(src)
            local citizenid = Player and Player.PlayerData and Player.PlayerData.citizenid
            if type(citizenid) == 'string' and citizenid ~= '' then
                snapshot[citizenid] = { src = src, xp = GetXPTier(citizenid).xp }
            end
        end
    end
    return snapshot
end

--- Composes a per-citizenid individual override (server/k9profiles.lua's
--- GetK9EffectiveMultipliers) onto a plain CopyXPTier(tier) snapshot before
--- it ever goes out over TriggerClientEvent -- CLOSES A REAL GAP (this pass):
--- PushRefreshedSnapshotsAfterEdit below used to push CopyXPTier(afterTier)
--- DIRECTLY, so a live tablet edit to a WHOLE RANK silently overwrote, on an
--- already-online citizenid's own client, any INDIVIDUAL override that
--- citizenid was already holding -- worse than never composing at all, since
--- it was a value that visibly, silently REVERTED rather than one that was
--- merely never applied, until something else (a reconnect, a real tier
--- crossing, or server/k9profiles.lua's own next k9ProfileUpsert/
--- k9ProfileReset call) happened to re-resolve and re-push the correct,
--- override-composed value.
---
--- NEVER duplicates GetK9EffectiveMultipliers' own resolution order (GLOBAL
--- DEFAULT -> XP TIER -> INDIVIDUAL OVERRIDE) and never reorders it -- calls
--- it, exactly once, with the SAME soft-dependency (`type(...) ==
--- 'function'`, pcall-wrapped) convention server/progression.lua's own
--- BuildEffectiveTierSnapshot already establishes for the IDENTICAL
--- composition. This file cannot call that function directly (it is `local`
--- to server/progression.lua, and this file's own
--- PushRefreshedSnapshotsAfterEdit is a genuinely separate channel from
--- server/progression.lua's PushTierSnapshot -- see this file's header for
--- that disclosure), so the CONTRACT is copied byte-for-byte instead of
--- reinvented: the same three fields, the same guard shape, the same
--- "absent/throwing server/k9profiles.lua degrades to a plain, uncomposed
--- copy" fallback (byte-for-byte this function's own pre-fix behavior). A
--- citizenid with no live individual override is completely unaffected
--- either way -- GetK9EffectiveMultipliers itself already returns the plain
--- tier-derived values for that case, so this is a strict widening, never a
--- narrowing, of what any citizenid without an override ever saw pushed
--- before this fix.
--- @param citizenid string
--- @param tier table
--- @return table snapshot
local function ComposeEffectiveXPTierSnapshot(citizenid, tier)
    local snapshot = CopyXPTier(tier)
    if type(citizenid) == 'string' and citizenid ~= '' and type(GetK9EffectiveMultipliers) == 'function' then
        local ok, effective = pcall(GetK9EffectiveMultipliers, citizenid)
        if ok and type(effective) == 'table' then
            if type(effective.speedMultiplier) == 'number' then snapshot.speedMultiplier = effective.speedMultiplier end
            if type(effective.scentRangeMultiplier) == 'number' then snapshot.scentRangeMultiplier = effective.scentRangeMultiplier end
            if type(effective.medkitCooldownMultiplier) == 'number' then snapshot.medkitCooldownMultiplier = effective.medkitCooldownMultiplier end
        end
    end
    return snapshot
end

--- Pushes a fresh, authoritative tier snapshot to every citizenid captured
--- by `beforeSnapshot`, and counts + NAMES (by citizenid) everyone who just
--- moved to a STRICTLY LOWER threshold (demoted) or a STRICTLY HIGHER one
--- (promoted) as a direct result of this edit (their real XP total is
--- unchanged -- only which rank it now qualifies for). Silent no-op for
--- anyone whose bracket did not move, by construction of
--- client/progression.lua's own existing "notify only on a real label
--- change" rule -- no server-side diffing needed to decide who gets a
--- toast, only who gets counted/named in the warning below.
---
--- SELF-SERVICE VISIBILITY (see header "THE ALREADY-PROMOTED PLAYER" point
--- 3): promotions are tracked here with EXACTLY the same rigor as
--- demotions, not merely as an afterthought -- LOWERING a threshold never
--- demotes anyone, so a self-promoting (or ally-promoting) edit produced
--- `demotedCount == 0` under the original demoted-only accounting, which is
--- precisely the silence this pass closes. `citizenid` lists (not just
--- counts) are returned specifically so the audit trail and the caller's
--- own response can name who gained a rank, not merely how many did.
--- @param beforeSnapshot table<string, {src: number, xp: number}>
--- @return table effect -- { demotedCount, promotedCount, demotedCitizenIds: string[], promotedCitizenIds: string[] }
local function PushRefreshedSnapshotsAfterEdit(beforeSnapshot)
    local effect = { demotedCount = 0, promotedCount = 0, demotedCitizenIds = {}, promotedCitizenIds = {} }
    if type(GetXPTier) ~= 'function' then return effect end

    for citizenid, before in pairs(beforeSnapshot) do
        local afterTier = GetXPTier(citizenid)
        -- COMPOSED, not a plain CopyXPTier -- see ComposeEffectiveXPTierSnapshot's
        -- own doc comment immediately above for the gap this closes. The
        -- demotion/promotion comparison just below still compares
        -- `afterTier.xp` (the plain, un-composed tier threshold) against
        -- `before.xp` -- an individual override never touches `xp`
        -- (server/k9profiles.lua's own file-top "SCOPE" section: only
        -- speedMultiplier/scentRangeMultiplier/medkitCooldownMultiplier are
        -- overridable), so re-ranking detection is completely unaffected by
        -- this fix either way.
        TriggerClientEvent('john-k9:client:xpTierChanged', before.src, ComposeEffectiveXPTierSnapshot(citizenid, afterTier))
        if afterTier.xp < before.xp then
            effect.demotedCount = effect.demotedCount + 1
            effect.demotedCitizenIds[#effect.demotedCitizenIds + 1] = citizenid
        elseif afterTier.xp > before.xp then
            effect.promotedCount = effect.promotedCount + 1
            effect.promotedCitizenIds[#effect.promotedCitizenIds + 1] = citizenid
        end
    end
    return effect
end

-- ======================================================================
-- CALLBACKS -- both re-verify CanManageXPTiers(source) as their own first
-- action (see header "AUTHORIZATION"). Response shape mirrors
-- server/certtiers.lua's own `{ ok, reason, ... }` convention exactly, for
-- consistency across this resource's tablet-facing surfaces.
-- ======================================================================

lib.callback.register('john-k9:server:xpTiersList', function(source)
    local authorized = CanManageXPTiers(source)
    if not authorized then return { ok = false, reason = 'denied' } end
    return { ok = true, tiers = ListXPTiersSnapshot() }
end)

lib.callback.register('john-k9:server:xpTiersUpsert', function(source, payload)
    local authorized, citizenid = CanManageXPTiers(source)
    if not authorized then return { ok = false, reason = 'denied' } end

    if not XPTierActionCooldown.Consume(source, XP_TIER_ACTION_COOLDOWN_MS) then
        return { ok = false, reason = 'rate_limited' }
    end

    if type(payload) ~= 'table' then
        return { ok = false, reason = 'invalid_payload' }
    end

    local ordinal = tonumber(payload.ordinal)
    if not IsValidOrdinal(ordinal) then
        return { ok = false, reason = 'invalid_ordinal' }
    end

    local xp = tonumber(payload.xp)
    if ordinal == 1 then
        -- MANDATORY BASELINE -- see header "SCOPE DECISION" point 1. A
        -- forged/buggy payload attempting to move rank 1 off 0 is REJECTED
        -- outright here (unlike the boot loader's own clamp-and-warn for a
        -- hand-edited DB row) -- this is a live, interactive edit with a
        -- real human on the other end who should be told plainly that this
        -- one field is fixed, not have it silently overridden.
        if xp ~= 0 then
            return { ok = false, reason = 'base_tier_xp_fixed' }
        end
    elseif not IsValidXpThreshold(xp) then
        return { ok = false, reason = 'invalid_xp' }
    end

    if not IsValidLabel(payload.label) then
        return { ok = false, reason = 'invalid_label' }
    end

    -- Coerced via tonumber, same defensive posture as `ordinal`/`xp` above --
    -- treat every inbound payload field as adversarial/untyped, never assume
    -- the NUI already sent a real Lua number for a form field. `nil` stays
    -- `nil` through tonumber(nil), which is exactly what the two OPTIONAL
    -- fields below need (payload.medkitCooldownMultiplier/badge omitted
    -- entirely is valid; a present-but-wrong-shaped value is not).
    local speedMultiplier = tonumber(payload.speedMultiplier)
    local scentRangeMultiplier = tonumber(payload.scentRangeMultiplier)
    local medkitCooldownMultiplier = payload.medkitCooldownMultiplier ~= nil and tonumber(payload.medkitCooldownMultiplier) or nil
    local badge = payload.badge

    if not IsValidMultiplier(speedMultiplier, MAX_SPEED_SCENT_MULTIPLIER) then
        return { ok = false, reason = 'invalid_speed_multiplier' }
    end
    if not IsValidMultiplier(scentRangeMultiplier, MAX_SPEED_SCENT_MULTIPLIER) then
        return { ok = false, reason = 'invalid_scent_range_multiplier' }
    end
    if payload.medkitCooldownMultiplier ~= nil and not IsValidMultiplier(medkitCooldownMultiplier, MAX_MEDKIT_COOLDOWN_MULTIPLIER) then
        return { ok = false, reason = 'invalid_medkit_cooldown_multiplier' }
    end
    if badge ~= nil and not IsValidBadge(badge) then
        return { ok = false, reason = 'invalid_badge' }
    end

    if not XPTierEditMutex.TryAcquire(XPTIER_LADDER_LOCK_KEY) then
        return { ok = false, reason = 'busy' }
    end

    -- THE WALK-INTO-INVALID-STATE HAZARD -- see header. Built and checked
    -- INSIDE the critical section (after acquiring the mutex, not before)
    -- so nothing else can have mutated the live ladder between this read
    -- and this file's own write below.
    local thresholds = BuildTentativeThresholds(ordinal, xp)
    local orderOk = IsStrictlyAscending(thresholds)
    if not orderOk then
        XPTierEditMutex.Release(XPTIER_LADDER_LOCK_KEY)
        return { ok = false, reason = 'invalid_order' }
    end

    local before = Config.XPTiers[ordinal]
    local oldXp, oldLabel = before.xp, before.label
    local oldSpeed, oldScent = before.speedMultiplier, before.scentRangeMultiplier
    local oldMedkit, oldBadge = before.medkitCooldownMultiplier, before.badge

    -- THE ALREADY-PROMOTED PLAYER -- captured BEFORE this write, still
    -- inside the critical section, so the "before" picture cannot itself
    -- be stale against a second, concurrent edit (impossible anyway while
    -- this mutex is held, but captured here for the same "no gap between
    -- read and the write it justifies" discipline the rest of this
    -- callback already follows).
    local beforeOnlineSnapshot = SnapshotOnlineCitizenXpForRefresh()

    local wrote = K9Store.XPTier_Upsert(
        ordinal, xp, payload.label, speedMultiplier, scentRangeMultiplier,
        medkitCooldownMultiplier, badge, citizenid or 'unknown'
    )
    if not wrote then
        XPTierEditMutex.Release(XPTIER_LADDER_LOCK_KEY)
        return { ok = false, reason = 'db_error' }
    end

    ApplyFieldsToConfigXPTier(ordinal, {
        xp = xp, label = payload.label, speedMultiplier = speedMultiplier,
        scentRangeMultiplier = scentRangeMultiplier,
        medkitCooldownMultiplier = medkitCooldownMultiplier, badge = badge,
    })

    XPTierEditMutex.Release(XPTIER_LADDER_LOCK_KEY)

    local changes = {}
    if oldXp ~= xp then changes[#changes + 1] = ('xp: %s -> %s'):format(tostring(oldXp), tostring(xp)) end
    if oldLabel ~= payload.label then changes[#changes + 1] = ('label: %q -> %q'):format(tostring(oldLabel), tostring(payload.label)) end
    if oldSpeed ~= speedMultiplier then changes[#changes + 1] = ('speedMultiplier: %s -> %s'):format(tostring(oldSpeed), tostring(speedMultiplier)) end
    if oldScent ~= scentRangeMultiplier then changes[#changes + 1] = ('scentRangeMultiplier: %s -> %s'):format(tostring(oldScent), tostring(scentRangeMultiplier)) end
    if oldMedkit ~= medkitCooldownMultiplier then changes[#changes + 1] = ('medkitCooldownMultiplier: %s -> %s'):format(tostring(oldMedkit), tostring(medkitCooldownMultiplier)) end
    if oldBadge ~= badge then changes[#changes + 1] = ('badge: %s -> %s'):format(tostring(oldBadge), tostring(badge)) end

    -- SELF-SERVICE VISIBILITY -- see header "THE ALREADY-PROMOTED PLAYER"
    -- point 3 and PushRefreshedSnapshotsAfterEdit's own doc comment.
    -- `effect` names BOTH directions of re-ranking, never just demotions.
    local effect = PushRefreshedSnapshotsAfterEdit(beforeOnlineSnapshot)

    -- Reliable self-promotion detection: the acting officer is, by
    -- construction, online and authenticated at the exact moment this
    -- callback runs (they just called it), so if THEIR OWN citizenid is
    -- among those promoted, it is because THIS edit put them there -- never
    -- a false positive from an unrelated concurrent promotion, since
    -- XPTierEditMutex has already serialized every edit to this ladder by
    -- the time `effect` is computed above.
    local isSelfPromotion = false
    if citizenid then
        for _, promotedId in ipairs(effect.promotedCitizenIds) do
            if promotedId == citizenid then
                isSelfPromotion = true
                break
            end
        end
    end

    -- Audit detail records BOTH directions, by citizenid, in the SAME line
    -- as the field-level before/after values above -- a revert (which
    -- demotes exactly whoever the original edit promoted) is therefore
    -- exactly as visible in the log as the promotion it undoes, and neither
    -- direction can be omitted just because the OTHER direction happened to
    -- be zero.
    local reRankParts = {}
    if effect.promotedCount > 0 then
        reRankParts[#reRankParts + 1] = (' -- %d currently-connected K9(s) re-ranked HIGHER by this edit with NO additional XP earned (citizenid(s): %s)%s'):format(
            effect.promotedCount, table.concat(effect.promotedCitizenIds, ', '), isSelfPromotion and ' [SELF-PROMOTION: includes the acting officer]' or '')
    end
    if effect.demotedCount > 0 then
        reRankParts[#reRankParts + 1] = (' -- %d currently-connected K9(s) re-ranked LOWER by this edit (citizenid(s): %s)'):format(
            effect.demotedCount, table.concat(effect.demotedCitizenIds, ', '))
    end

    -- AUDIT-SWALLOW FIX (this pass): XPTierAudit_Append's own boolean
    -- return used to be discarded here -- the primary write
    -- (K9Store.XPTier_Upsert above) already succeeded and was checked
    -- before this point, so this edit genuinely happened and this
    -- callback's own `ok = true` response remains correct either way --
    -- but a failed audit-trail insert must not vanish without a trace
    -- tying it to this specific rank/ordinal. Mirrors
    -- server/runtimecontrol.lua's own identical "AUDIT-SWALLOW FIX (this
    -- pass)" comment/shape exactly.
    if not K9Store.XPTierAudit_Append(
        ordinal,
        ('rank %d (%s): %s%s'):format(ordinal, tostring(payload.label), table.concat(changes, ', '), table.concat(reRankParts, '')),
        citizenid or 'unknown'
    ) then
        print(('[John-K9] xptiers.lua: audit-trail write failed for ordinal=%s (the edit itself still succeeded and was persisted).'):format(tostring(ordinal)))
    end

    -- LOUDER TREATMENT FOR A PROMOTION THAN A DEMOTION -- decided, not
    -- merely defaulted to equal wording: a threshold edit that instantly
    -- HANDS OUT a rank's bonuses with zero additional XP earned is the
    -- shape a high-command account could actually exploit for personal or
    -- ally gain; a demotion only ever takes away something re-ranking
    -- already justified, never grants anything. Both are still disclosed in
    -- the SAME response (never one silencing the other), but the promotion
    -- warning is built first, is more specific (names who, states the
    -- zero-additional-XP fact explicitly), and gets its own SELF-PROMOTION
    -- callout when it applies. Never a gate -- the edit has already
    -- completed by the time this warning is built; this is disclosure, not
    -- a confirmation dialog.
    local warningParts = {}
    if effect.promotedCount > 0 then
        warningParts[#warningParts + 1] = ('%d currently-connected K9(s) just gained a HIGHER rank\'s speed/scent bonuses as a direct result of this edit, with NO additional XP earned (citizenid(s): %s).%s'):format(
            effect.promotedCount, table.concat(effect.promotedCitizenIds, ', '),
            isSelfPromotion and ' SELF-PROMOTION: the acting officer\'s own citizenid is among those promoted by this edit.' or '')
    end
    if effect.demotedCount > 0 then
        warningParts[#warningParts + 1] = ('%d currently-connected K9(s) just moved to a LOWER rank as a direct result of this edit ' ..
            '(their real accumulated XP did not change -- only which rank it currently qualifies for did).'):format(effect.demotedCount)
    end

    local warning
    if #warningParts > 0 then
        warning = ('This change immediately RE-RANKS every currently-connected K9 against the new thresholds. %s ' ..
            'This is not automatically reversible; edit the threshold back if that was not intended -- doing so is logged with the same visibility as this change.'):format(table.concat(warningParts, ' '))
    end

    return { ok = true, tiers = ListXPTiersSnapshot(), warning = warning }
end)

-- ======================================================================
-- BOOT -- layer persisted DB overrides on top of config.lua's own shipped
-- defaults. Deferred to onResourceStart (not raw top-level -- MySQL/
-- oxmysql readiness is not guaranteed at raw server_scripts load-time),
-- mirroring server/certtiers.lua's own identical "config-only defaults at
-- file-load [here: at every other file's own file-load, since this file
-- makes no changes at its OWN file-load beyond registering callbacks], DB
-- layered on top at onResourceStart" pattern exactly.
--
-- WAITS FOR THE SCHEMA-COLLISION PROBE TO SETTLE FIRST (db-schema
-- boot-order fix, this pass): server/datastore.lua loads before this file
-- and registers its own onResourceStart handler first, but that handler's
-- own MySQL.query.await yields -- and a yielding handler does not block
-- FXServer's event dispatch from moving straight on to THIS handler while
-- the probe is still in flight. Without this wait,
-- K9Store.XPTier_GetAllRows() below would run its own SELECT (a different
-- column set than k9_xp_tiers is checked against -- it includes
-- medkit_cooldown_multiplier/badge, which the probe does not check, and
-- omits updated_by/updated_at, which the probe does) against whatever
-- `k9_xp_tiers` currently is, before the probe has had a chance to say
-- whether that table is even really ours -- a foreign table the full
-- probe would correctly reject could still satisfy this different one
-- during that window. K9Store.WaitForSchemaCheckToSettle()
-- (server/datastore.lua) blocks THIS coroutine only, with a bounded
-- timeout, until that determination is final -- see its own header for
-- the full contract. On a `false` return (the probe genuinely had not
-- settled within the wait budget -- database unreachable/slow, or off by
-- config, which settles instantly instead of waiting at all), this file
-- boots every rank to its config.lua default for this session, exactly
-- like `Config.Database.enabled == false` -- simply skipping
-- ApplyPersistedXPTierOverrides() leaves Config.XPTiers exactly as shipped
-- (nothing above this point ever mutates it except that function), so no
-- separate fallback path is needed. The next successful xpTiersUpsert
-- call (or a resource restart, by which point the probe will certainly
-- have settled) re-reads the real state as normal.
-- ======================================================================
AddEventHandler('onResourceStart', function(resourceName)
    if GetCurrentResourceName() ~= resourceName then return end
    if not K9Store.WaitForSchemaCheckToSettle() then
        print('[John-K9] xptiers: the schema-collision check had not finished within its wait budget -- every rank is using its config.lua default for this session (no database read attempted, exactly like Config.Database.enabled = false) rather than trust a database state that is not yet confirmed safe. The next successful XP-tier edit (or a restart once the check has had time to finish) will pick up any real persisted state.')
        return
    end
    ApplyPersistedXPTierOverrides()
end)
