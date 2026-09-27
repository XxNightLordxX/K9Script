--[[
    qbx_k9unit/server/highcommand.lua

    Config.Features.HighCommand. Project owner's own words for this feature
    request: "Allow High command in pd to give xp via a command to a k9 or
    handler, allow high command in pd to be able to run any command and make
    it super op." Two parts, both gated on the SAME per-department threshold
    (Config.Departments[job.name].highCommandGrade, config.lua):

    PART 1 -- IsHighCommand(source): a single senior-rank predicate, exposed
    as a resource-global (no `local`) so every OTHER gate in this resource
    can consult it. Mirrors server/admin.lua's IsAuthorizedAdmin shape
    EXACTLY (read that function before touching this one) -- same
    Config.Departments[job.name] membership requirement, same job.isboss
    unconditional bypass, same explicit `type(job.grade.level) == 'number'`
    guard before ever comparing it, applied against a NEW, separate
    threshold (highCommandGrade, not auditGrade/certifierGrade). FAILS
    CLOSED on every path where a job cannot be fully resolved -- see the
    function's own doc comment below for the exhaustive list. A nil
    highCommandGrade means "this department has no such tier", NEVER
    "everyone qualifies" -- config.lua's own comment on this field says the
    same thing; this file enforces it.

    Additionally, and unlike IsAuthorizedAdmin, this function ALSO re-checks
    Config.Features.HighCommand itself, internally, on every call --
    defensive-no-op-if-disabled, the same posture server/progression.lua's
    AwardXP documents for Config.Features.XPProgression ("callers are not
    required to gate this themselves"). This matters here specifically
    because, unlike IsAuthorizedAdmin/IsAuthorizedBoneSweepDevTool (both only
    ever reachable through a command whose OWN registration already checked
    their feature flag), IsHighCommand is consulted from inside
    ALWAYS-LIVE gates (HasK9Access, IsEligibleCertifier) that have no
    registration step of their own to hide behind -- so flipping
    Config.Features.HighCommand off must genuinely turn every one of those
    bypasses back off too, immediately, with no restart required, exactly
    like every access check elsewhere in this resource that reads a feature
    flag at the point of use rather than only at startup.

    CONSULTED FROM (every OTHER rank/grade gate in this resource, found by
    grepping every `job.isboss` / `job.grade.level` / `IsPlayerAceAllowed`
    call site in server/*.lua and independently re-reading each one before
    relying on it):
      - server/certifications/'s IsEligibleCertifier (certifierGrade).
        High command can certify/revoke/decertify-offline for any
        configured department, same as a boss.
      - server/certifications/'s HasK9Access (the certification
        requirement itself). High command gets K9 feature access (bark
        relay, leash, search, tracking, medkit, inventory, combat, fetch,
        kennel, propattachment -- every one of those files gates on THIS
        single function, per its own "SINGLE SOURCE OF TRUTH" doc comment,
        so bypassing it here is sufficient; none of those downstream files
        needed their own edit) WITHOUT holding an active certification.
      - server/admin.lua's IsAuthorizedAdmin (auditGrade). High command can
        run every /k9audit* command against any department.
      - server/bonetool.lua's IsAuthorizedBoneSweepDevTool (isboss-only).
        NOTE: this is LAYER 2 only -- LAYER 1 (the
        `Config.Features.BoneSweepDevTool` flag AND the
        `qbx_k9unit_enable_bone_dev_tool` convar, both required before
        '/k9bonetool' is even RegisterCommand'd at all) is a
        server-OPERATOR opt-in, not a rank gate, and is deliberately left
        untouched -- an in-game promotion must never be able to switch on a
        dev-only prop-spawning tool an operator never opted into at the
        process level. High command bypasses the RANK check only, exactly
        like it bypasses auditGrade/certifierGrade and no more.
      - server/combat.lua's IsAuthorizedForNonComplianceAlert
        (nonComplianceAlertGrade) now includes a High Command bypass too
        (verified by reading that file directly): `if type(IsHighCommand)
        == 'function' and IsHighCommand(playerId) then return true end`,
        inserted the same place every other bypass in this list was,
        immediately after the `job.isboss` check and before the
        `dept.nonComplianceAlertGrade` type guard. This used to be a known
        gap in the rollout, not an intentional exclusion; it has since been
        closed.
      - Every `RegisterCommand` in this resource was independently
        enumerated (server/admin.lua x5, server/bonetool.lua x1,
        server/certifications/ x3) and cross-checked against the four
        gates above -- all nine already route through one of them, so "high
        command can run any command [registered by this resource]" needs no
        further per-command edit once those four gates carry the bypass.
      - server/wellbeing.lua was read and deliberately has NO bypass added:
        it gates on IsOwnModelK9 (a PED-MODEL check -- "are you currently
        playing a K9-modeled character"), never on HasK9Access or any
        rank/grade comparison at all (that file's own header says so
        explicitly). A rank bypass has nothing to attach to there, and
        should not: high command being senior does not make their CURRENT
        PED a K9 model.

    SCOPE, RESTATED FROM config.lua's OWN Config.HighCommand comment BECAUSE
    THIS IS THE FILE THAT COULD MOST EASILY BE MIS-EXTENDED INTO VIOLATING
    IT: "super op" here means every command and every gated action THIS
    RESOURCE ITSELF exposes, and stops at this resource's own boundary. This
    file contains NO `ExecuteCommand` call, no passthrough of a
    caller-supplied string to any server-command-execution native, and no
    mechanism that could reach ACE/permissions/another resource's own
    command surface. A generic "run literally anything" passthrough would
    convert an in-game job-rank promotion into full, irreversible server
    control (txAdmin/ACE-equivalent) the instant one account is
    compromised or one promotion is a mistake -- config.lua's own
    Config.HighCommand header already makes this call for the project
    owner; this file stays consistent with it by construction, not by
    restraint that could later be "relaxed".

    ======================================================================
    PART 2 -- '/k9givexp [server id] [amount]', high command only. Grants a
    caller-CHOSEN amount of XP -- the one thing server/progression.lua's
    AwardXP is deliberately built to never allow ("actionKey selects a flat,
    config-owned amount; there is no path for a caller to specify an
    arbitrary amount" -- that file's own doc comment on AwardXP). This
    command does NOT call AwardXP, and does NOT weaken it: AwardXP's
    invariant ("no caller-specified amount, ever") stays true for every one
    of its existing callers (server/search.lua, server/tracking.lua,
    server/tenure.lua, eventually server/combat.lua) exactly as before. This
    command needs a genuinely different, explicitly-labelled entry point --
    see AwardXPDirect below.

    AwardXPDirect(citizenid, amount, reason) -- LANDED (verified by reading
    server/progression.lua directly: a real, complete function with that
    exact signature). This comment used to say it was REQUESTED but not
    yet added to server/progression.lua; it has since been added there.
    Called here through the SAME `type(...) == 'function'` soft-dependency
    guard every other cross-file call in this resource already uses for a
    forward/optional reference -- that guard is kept even though the
    function is now confirmed present, so if a future removal ever drops
    it again, '/k9givexp' still fails CLOSED with a clear, player-facing
    "XP system currently unavailable" message and an audited
    'xp_unavailable' outcome, rather than either (a) silently no-opping
    (indistinguishable from a bug) or (b) reaching around progression.lua's
    own private K9XP cache/UPSERT logic with a parallel, hand-rolled SQL
    write here, which would correctly update `k9_progression` but leave the
    in-memory K9XP cache (and therefore
    GetXPTier's live speedMultiplier/scentRangeMultiplier effect, and the
    xpTierChanged client push) stale until that citizenid's next
    PlayerLoaded/resource-restart backfill -- a real, silent-until-reported
    correctness gap this file refuses to introduce.

    TARGET RESOLUTION -- K9 vs. handler, the genuine design question here:
    '/k9givexp [server id] [amount]' takes a CONNECTED PLAYER's server id
    (per DEVELOPER_REFERENCE.md, a K9 is a player's own persistent
    character, not an NPC -- so both "the K9" and "the handler" are real,
    separately-controlled connected players, each with their own
    citizenid). Given that server id resolves to `directCitizenid`:
      1. If `directCitizenid` has NO active partnership (server/
         partnership.lua's GetActivePartnerCitizenId returns nil, including
         when Config.Features.HandlerPartnership is off entirely, or that
         file has not loaded for any reason -- soft-guarded the same way),
         OR is itself the K9-role party of one: credit `directCitizenid`
         directly. This is the unambiguous case -- either there is nothing
         to redirect through, or the target IS the K9 whose tier this XP is
         meant to move.
      2. If `directCitizenid` is the HANDLER-role party of an active
         partnership: redirect the grant to their K9 partner's citizenid.
         REASONING: `k9_progression`/K9XP is fundamentally a property of
         the K9 CHARACTER -- GetXPTier's speedMultiplier/scentRangeMultiplier
         only ever apply to whichever citizenid is currently controlling a
         K9-modeled ped (client/progression.lua), and a handler character
         is, by definition, never that ped. Crediting a handler's OWN
         citizenid with "K9 progression" would silently mint a K9XP row
         that no code path in this resource ever reads for any gameplay
         effect -- a real player-facing "my chief said they gave my dog XP
         and nothing changed" bug, not a cosmetic inconsistency. Since
         "allow high command to give xp to a k9 OR a handler" was the
         owner's own explicit ask, honoring the intent behind targeting a
         handler (rewarding a working K9 TEAM) means routing the actual
         mechanical effect to the party it can affect, not the party whose
         server id happened to be typed. This is deliberately NOT the
         reverse (a K9-role target redirecting to their handler) -- there
         is no "handler progression" system in this resource for that
         redirection to land in; only the K9-role citizenid has a
         `k9_progression` row that means anything.
    Both the granter and the ONLINE party actually named by `[server id]`
    (the handler, in the redirect case -- not their possibly-offline K9
    partner, who has no live client to notify regardless) get a
    notification; the handler's own notification text is worded to make the
    redirection explicit ("your K9 partner was granted...") rather than
    implying their OWN citizenid changed.

    SELF-GRANT (Config.HighCommand.allowSelfGrant, DEFAULT TRUE this pass --
    OWNER DECISION: "High command can grant anything they want to
    themselves -- xp promotions permissions etc", widened from the previous
    default-false; see config.lua's own comment on this flag for the full
    writeup and HighCommandSelfGrantAllowed below for the exact read):
    blocked ONLY when the flag has been explicitly set to `false` AND
    EITHER `directCitizenid` (the literal server id targeted) OR the final
    redirected recipient equals the granter's own citizenid. Checking both,
    not just the final recipient, closes the one loophole the redirection
    above would otherwise open: a high-command officer who is ALSO the
    handler-role half of an active partnership could target their OWN
    server id, have the grant silently redirect to their K9 partner (a
    different citizenid), and see it pass an equality check against only
    the final recipient -- self-dealing one hop removed, which is exactly
    the kind of transaction config.lua's own comment on this flag says
    should never look like it "has no second person in the audit trail" --
    that loophole-closing logic is UNCHANGED by the default flip; only
    which value blocks vs. permits changed. Every successful self-grant
    (the flag's own default, now) is still audited with an explicit
    `self_grant=true` field (see GrantHighCommandXp's own AUDIT comment) --
    self-service is the owner's decision, not an invisible one.

    VALIDATION -- amount: a positive integer, finite, not NaN, at or below
    Config.HighCommand.maxXpPerGrant. THE FOOTGUN THIS CODEBASE KEEPS
    HITTING (server/cooldowns.lua's non-positive-threshold-means-"disabled"-
    never-"unlimited" writeup; server/progression.lua's identical framing
    for its own XP_MINT_BUDGET_CAP_XP): a non-positive, nil, NaN, or
    infinite `Config.HighCommand.maxXpPerGrant` MUST disable '/k9givexp'
    entirely, never be silently read as "no cap" the way a naive
    `amount <= (maxXpPerGrant or math.huge)` would. Checked once, at
    registration time (onResourceStart, below) -- an invalid cap means the
    command is never RegisterCommand'd at all, with a loud console warning,
    matching this resource's established "WARNING at start for an
    operator-tunable value, not a hard assert crash, but never a silent
    unlimited fallback either" posture (server/bonetool.lua's convar-not-set
    path is the closest precedent for "opted into the feature but the
    second gate isn't satisfied yet -> warn and stay inert, don't crash
    resource start").

    COOLDOWN -- Config.HighCommand.grantCooldownMs, via server/cooldowns.lua's
    NewCooldown, keyed by the GRANTER's own source (mirrors
    server/admin.lua's AuditCooldown / server/certifications/'s
    CertifyActionCooldown shape: one shared instance, per-call threshold
    read fresh from Config, not a constructor default). READ
    server/cooldowns.lua's own header FIRST: IsOnCooldown/Consume treat a
    missing/non-positive/NaN threshold as PERMANENTLY ON, never "no
    cooldown" -- this file does NOT work around that (the correct behavior
    for a misconfigured cooldown IS "fails closed after the first grant",
    never "unlimited grants"), it only makes sure `Config.HighCommand.
    grantCooldownMs` is passed straight into `.Consume()` with no `or`-
    fallback idiom that could reinterpret a `0` as anything other than what
    cooldowns.lua itself already, correctly, treats it as. A startup warning
    (not a block on registration -- unlike maxXpPerGrant, a bad cooldown
    fails SAFE on its own, just confusingly, so this is disclosure, not a
    correctness requirement) is printed if the configured value would not
    validate as a real threshold.

    AUDIT -- every invocation (denied / rate-limited / invalid args / target
    unresolvable / self-grant blocked / XP system unavailable / ok) is
    printed via LogAuditInvocation below, mirroring server/admin.lua's own
    "%s ran %s(%s) -> %s" audit-line shape exactly. The 'ok' line names the
    granter citizenid (via the shared whoLabel), the RECIPIENT citizenid
    (post-redirection), the amount, and the resulting total in one line --
    this mints economy value, so it must be traceable, matching or
    exceeding the traceability server/admin.lua's purely READ-ONLY audit
    surface already provides for a WRITE path. ALSO carries an explicit
    `self_grant=true|false` field (this pass), computed the same way the
    SELF-GRANT check itself is (directCitizenid or recipientCitizenid
    equal to the granter's own citizenid) -- now that self-grant is
    permitted by default (see SELF-GRANT above), the 'ok' line naming the
    SAME citizenid as both granter (`whoLabel`) and recipient
    (`target_citizenid`) is provably a self-grant from the line itself,
    never something a reader has to notice unaided.

    ======================================================================
    FILE-TO-FILE CONTRACT:
    - THIS FILE exposes ONE resource-global (no `local`) function:
        IsHighCommand(source) -> boolean
      Consulted by server/certifications/, server/admin.lua,
      server/bonetool.lua, and now also server/combat.lua (see the
      once-known, now-closed gap noted above), each behind a
      `type(IsHighCommand) == 'function'` guard -- this resource's
      established soft-dependency convention -- so each of those files
      still works exactly as before if this file is ever removed or
      Config.Features.HighCommand is false.
    - THIS FILE calls `NewCooldown()` (server/cooldowns.lua) at this file's
      own file-load time -- MUST load after server/cooldowns.lua.
    - THIS FILE calls `NotifyPlayer` (server/notify.lua) at command-handler
      RUN time only (never at file-load time) -- placed after
      server/notify.lua in fxmanifest.lua purely so this call site needs no
      `type(...) == 'function'` guard of its own (every consumer loaded
      after server/notify.lua needs no runtime existence guard), not
      because run-time placement is actually load-bearing.
    - THIS FILE calls `GetActivePartnerCitizenId` (server/partnership.lua)
      and `AwardXPDirect` (server/progression.lua -- LANDED, verified by
      reading that file directly; this used to say "requested, not yet
      present") at command-handler RUN time, both behind a
      `type(...) == 'function'` guard -- genuine soft/forward dependencies,
      no load-order requirement either way (both files may load before or
      after this one; by the time '/k9givexp' can actually be invoked,
      every server_scripts file has already finished loading regardless of
      manifest order, per this resource's own established reasoning for
      every other soft cross-file dependency).
    - THIS FILE is consulted BY server/certifications/, server/admin.lua,
      and server/bonetool.lua (see above) -- this file does NOT call INTO
      any of those three itself, so there is no load-order cycle: those
      three each independently guard their own call to IsHighCommand, so
      this file may load before, after, or interleaved with any of them.
    - THIS FILE does NOT expose AwardXPDirect (that lives in
      server/progression.lua, per its own file's "THIS FILE owns K9XP"
      contract -- this file must never write K9XP directly, see PART 2's
      own "genuinely different entry point" reasoning above for why).

    CONFIG THIS FILE ASSUMES EXISTS (documented here for completeness):
      Config.Features.HighCommand         : boolean
      Config.Departments[job].highCommandGrade : number | nil (per department)
      Config.HighCommand.maxXpPerGrant    : number (validated at registration; see VALIDATION above)
      Config.HighCommand.grantCooldownMs  : number (passed straight to NewCooldown's per-call threshold; see COOLDOWN above)
      Config.HighCommand.allowSelfGrant   : boolean (default true, this pass -- read as `~= false`)

    LOCALE KEYS THIS FILE NEEDS (not invented inline; every locale() call
    below uses one of these eight NEW keys or one of two EXISTING `common.*`
    keys reused as-is, matching this resource's own "no duplicate
    near-identical string" convention):
      highcommand.not_authorized             = "You are not authorized to use High Command commands."
      highcommand.usage_givexp               = "Usage: /k9givexp [server id] [amount]"
      highcommand.invalid_amount             = "Amount must be a whole number from 1 to %d."
      highcommand.self_grant_disabled        = "You cannot grant XP to yourself."
      highcommand.xp_system_unavailable      = "The XP system is currently unavailable -- no XP was granted."
      highcommand.grant_success_granter      = "Granted %d XP to citizenid %s. New total: %d XP."
      highcommand.grant_success_target       = "You were granted %d XP by High Command. New total: %d XP."
      highcommand.grant_success_target_partner = "Your K9 partner was granted %d XP by High Command on your behalf. New total: %d XP."
      (reused, already present) common.unable_to_resolve_citizenid
      (reused, already present) common.target_no_longer_online

    FXMANIFEST.LUA PLACEMENT: 'server/highcommand.lua' is loaded in
    server_scripts after server/cooldowns.lua (the one HARD load-order
    requirement, for NewCooldown at this file's own file-load time) and
    after server/notify.lua (a soft-but-tidy placement, so this file's own
    NotifyPlayer calls need no existence guard either), and before every
    one of its consumers (server/certifications/, server/admin.lua,
    server/bonetool.lua) -- though per the FILE-TO-FILE CONTRACT above,
    none of those three actually depend on that ordering, since each guards
    its own call with `type(IsHighCommand) == 'function'`.
]]

-- ADMIN CHAT COMMANDS ARE OFF BY DEFAULT (owner: "k9certify should only
-- be done through the tablet", and all other admin work with it). They are
-- only registered when Config.CommandTablet.adminChatCommands is true --
-- the tablet does every one of these. The handlers below are kept (and
-- tested) so an owner who wants console access can switch them back on.
local function RegisterAdminCommand(name, handler, restricted)
    if type(Config.CommandTablet) == 'table' and Config.CommandTablet.adminChatCommands == true then
        RegisterCommand(name, handler, restricted)
    end
end


-- ======================================================================
-- CONFIG-SAFETY GUARD -- deferred into onResourceStart (NOT run at this
-- file's own load time): IsHighCommand below is a resource-global that
-- must exist and behave correctly regardless of whether
-- Config.Features.HighCommand is true (see PART 1's own "defensive
-- no-op-if-disabled" reasoning), so nothing here can gate the FUNCTION
-- DEFINITION itself on the flag -- only the extra config-shape asserts
-- below and '/k9givexp's own registration are gated on it, mirroring
-- server/admin.lua's/server/bonetool.lua's identical "only assert once the
-- operator has actually opted in" posture.
-- ======================================================================

--- Shared numeric-sanity test -- same NaN/finite/positive battery every
--- footgun-prone numeric config value in this resource is independently
--- checked against (server/cooldowns.lua's own IsValidThreshold,
--- server/progression.lua's IsValidBudgetParam) -- duplicated here rather
--- than imported, matching this resource's own established pattern of each
--- file keeping its own tiny copy of this exact three/four-line test rather
--- than adding a new resource-global purely for it.
--- @param value any
--- @return boolean
local function IsValidPositiveFiniteNumber(value)
    return type(value) == 'number' and value == value and value > 0 and value < math.huge
end

--- @param value any -- a caller-supplied /k9givexp amount argument, already tonumber()'d (or nil)
--- @param maxXp number -- Config.HighCommand.maxXpPerGrant, already confirmed valid by the onResourceStart guard below before '/k9givexp' is ever registered
--- @return boolean
local function IsValidGrantAmount(value, maxXp)
    return IsValidPositiveFiniteNumber(value) and value == math.floor(value) and value <= maxXp
end

--- @param value any -- a caller-supplied /k9givexp server-id argument, already tonumber()'d (or nil)
--- @return boolean
local function IsValidServerIdArg(value)
    return IsValidPositiveFiniteNumber(value) and value == math.floor(value)
end

--- Server-authoritative check: is `source` currently a High Command
--- officer? See this file's header PART 1 for the full contract. Mirrors
--- server/admin.lua's IsAuthorizedAdmin shape EXACTLY for every
--- resolvable-shape check: fails CLOSED (returns false, never throws) on
--- ALL of the following, none of which ever reach the final `>=`
--- comparison:
---   - Config.Features.HighCommand is not `true` (checked FIRST, unlike
---     IsAuthorizedAdmin -- see header PART 1 for why this function alone
---     among this resource's rank gates must re-check its own feature flag
---     on every call rather than relying on a registration-time gate),
---   - no resolvable Player / PlayerData for `source`,
---   - no `job` table on PlayerData,
---   - `job.name` is not a configured `Config.Departments` key,
---   - `Config.Departments` itself is not a table (defensive; every other
---     file in this resource that reads it already asserts its shape at
---     load/start time, but this function must never assume that assert
---     ran before it did),
---   - `Config.Departments[job.name].highCommandGrade` is nil (deliberately
---     -- "no such tier in this department", never "everyone qualifies";
---     see config.lua's own comment on this field) or any other non-number
---     value,
---   - `job.grade` is nil, or `job.grade.level` is not a number.
--- `job.isboss` is the ONLY path that returns true without ever consulting
--- `job.grade` or `highCommandGrade` at all -- same unconditional-boss-
--- bypass rule as every other rank gate in this resource.
--- @param source number
--- @return boolean
function IsHighCommand(source)
    if not (Config.Features and Config.Features.HighCommand == true) then return false end

    local Player = exports.qbx_core:GetPlayer(source)
    if not Player or not Player.PlayerData then return false end

    local job = Player.PlayerData.job
    if not job or type(Config.Departments) ~= 'table' or not Config.Departments[job.name] then return false end

    -- job.isboss always qualifies regardless of the configured numeric
    -- threshold -- same rule, same reasoning, as every other rank gate in
    -- this resource (server/admin.lua's IsAuthorizedAdmin,
    -- server/certifications/'s IsEligibleCertifier).
    if job.isboss then return true end

    local dept = Config.Departments[job.name]

    -- FAILS CLOSED on a nil OR malformed highCommandGrade -- nil means "no
    -- High Command tier configured for this department at all", never
    -- "everyone qualifies". Never a pcall around the comparison below: an
    -- explicit type guard here means a job object shaped differently than
    -- qbx_core's documented `{ name, level: number }` schema fails closed
    -- (deny) rather than throwing an uncaught "attempt to compare number
    -- with <type>" error on this authorization path -- the exact class of
    -- bug this resource's other rank gates were each independently
    -- hardened against.
    if type(dept.highCommandGrade) ~= 'number' then return false end

    return job.grade ~= nil and type(job.grade.level) == 'number' and job.grade.level >= dept.highCommandGrade
end

-- ======================================================================
-- PART 2 -- '/k9givexp [server id] [amount]'. See this file's header for
-- the full design writeup (target resolution, self-grant, validation,
-- cooldown, audit).
-- ======================================================================

-- Shared constructor, not a hand-rolled table. One instance, keyed by the
-- GRANTER's own source, mirroring server/admin.lua's AuditCooldown /
-- server/certifications/'s CertifyActionCooldown shape (no constructor
-- default -- the threshold is supplied explicitly at every .Consume() call
-- from Config.HighCommand.grantCooldownMs, per that constructor's own
-- "several call sites read a Config value that could differ per
-- invocation" convention).
local HighCommandGrantCooldown = NewCooldown()
HighCommandGrantCooldown.RegisterPlayerDropped()

--- Console log line for EVERY invocation of '/k9givexp' (and the K9
--- Command Tablet's own tabletGiveXp callback, which is a genuinely
--- different entry point to the SAME underlying grant -- see
--- GrantHighCommandXp below) -- denied, rate-limited, invalid args, target
--- unresolvable, self-grant blocked, XP system unavailable, or ok. Mirrors
--- server/admin.lua's own LogAuditInvocation "%s ran %s(%s) -> %s" shape
--- exactly -- this command mints economy value, so it gets at least the
--- same traceability as that file's purely read-only audit surface.
--- The 'ok' outcome's own `detail` string is built by the caller to already
--- contain the target citizenid, amount, and resulting total in one place,
--- so a single line captures granter (via `whoLabel`), target, amount, and
--- total together. The literal `k9givexp(...)` action-name text is kept
--- UNCHANGED even for a tablet-originated grant -- from the audit trail's
--- own perspective this is the exact same mechanism a typed command would
--- hit (mirrors client/tablet.lua's own "a tablet-triggered command is,
--- from the server's perspective, LITERALLY THE SAME EVENT" framing for
--- its command bridge), not a second, differently-named grant path.
--- @param source number
--- @param detail string
--- @param outcome string -- 'ok' | 'denied' | 'rate_limited' | 'invalid_args' | 'target_unresolvable' | 'self_grant_blocked' | 'xp_unavailable'
local function LogAuditInvocation(source, detail, outcome)
    local granterPlayer = exports.qbx_core:GetPlayer(source)
    local citizenid = granterPlayer and granterPlayer.PlayerData and granterPlayer.PlayerData.citizenid
    local whoLabel = citizenid and ('citizenid=' .. citizenid) or ('unresolved-source=' .. tostring(source))
    print(('[qbx_k9unit] AUDIT: %s ran k9givexp(%s) -> %s'):format(whoLabel, detail, outcome))
end

--- Shared authorization PREDICATE for both '/k9givexp' and the tablet's own
--- tabletGiveXp callback -- factored out so a future change to how this
--- resolves (a third grant path, a new bypass) is made once, not twice.
--- Two independent routes, matching the resolution order config.lua's
--- Config.Permissions block documents: an explicit 'k9.givexp' grant, OR
--- high command rank. Both guarded with `type(fn) == 'function'` so this
--- still works with either feature disabled -- with both off, nobody
--- qualifies and it fails closed, which is correct. Pure predicate, no
--- side effects (no audit line, no cooldown consumption) -- each call site
--- still owns its own audit/cooldown sequencing exactly as before, so
--- extracting this changes no observable ordering for '/k9givexp'.
--- @param source number
--- @return boolean
local function IsAuthorizedForXpGrant(source)
    -- AN EXPLICIT BLOCK BEATS RANK, AND IS CHECKED FIRST (verification-pass
    -- finding). This used to return true on IsHighCommand alone, before
    -- consulting anything else, so 'block.k9.givexp' could never restrain a
    -- high command officer -- and since nothing else in the resource read
    -- that key either, it could not restrain anybody at all.
    --
    -- That was an asymmetry rather than a decision: server/admin.lua's
    -- IsAuthorizedAdmin already checks 'block.k9.audit' BEFORE every one of
    -- its own bypasses, job.isboss included, with a comment saying outright
    -- that a block must beat even that. The same reasoning applies here with
    -- MORE force, not less. Pulling an audit record reads history; granting
    -- XP mints economy value out of nothing -- config.lua's own comment on
    -- highCommandGrade calls it the one threshold that "grants WRITE power
    -- over the economy". An owner could restrain one specific officer from
    -- reading records but not from minting XP, which is exactly backwards.
    --
    -- Reached through the same `type(fn) == 'function'` guard as everything
    -- else here, so a server running without the permissions system behaves
    -- exactly as it did before. A caller whose citizenid cannot be resolved
    -- is NOT treated as blocked: that case already falls through to the
    -- `return false` at the end, so it fails closed without this branch
    -- having to guess at it.
    local callerPlayer = exports.qbx_core:GetPlayer(source)
    local callerCitizenid = callerPlayer and callerPlayer.PlayerData and callerPlayer.PlayerData.citizenid
    local hasResolvedCitizenid = type(callerCitizenid) == 'string' and callerCitizenid ~= ''

    if hasResolvedCitizenid and type(HasPermission) == 'function'
        and HasPermission(callerCitizenid, 'block.k9.givexp') == true then
        return false
    end

    if type(IsHighCommand) == 'function' and IsHighCommand(source) then return true end

    if hasResolvedCitizenid and type(HasPermission) == 'function' then
        return HasPermission(callerCitizenid, 'k9.givexp') == true
    end

    return false
end

--- OWNER DECISION (this pass) -- see PART 2's own "SELF-GRANT" writeup at
--- GrantHighCommandXp's own call site below. Reads
--- Config.HighCommand.allowSelfGrant, defaulting to `true` (config.lua's
--- own new default, this pass) when the value is anything other than an
--- explicit `false` -- covers both a genuinely absent key (a config table
--- written before this field existed at all) and an explicit `false`
--- (a deliberate operator opt-out back to the stricter, pre-owner-decision
--- behaviour) correctly, unlike `x or default` which cannot tell "absent"
--- apart from an explicit `false` either way but happens to only matter
--- here because both read as boolean, not a number where `0` would break
--- it -- checked explicitly anyway, matching this resource's own
--- established convention (server/permissions.lua's identical
--- HighCommandSelfGrantAllowed) for every other boolean switch of this
--- shape. Defensive `type(...) == 'table'` guard even though
--- Config.HighCommand is already asserted to be a table before '/k9givexp'
--- is ever registered (this file's own onResourceStart guard) -- this
--- function makes no assumption about when it might be called from in the
--- future.
--- @return boolean
local function HighCommandSelfGrantAllowed()
    if type(Config.HighCommand) ~= 'table' then return true end
    return Config.HighCommand.allowSelfGrant ~= false
end

--- Shared CORE grant mechanics for both '/k9givexp' and tabletGiveXp --
--- everything from "who actually receives the XP" onward, once
--- authorization/cooldown/amount have ALREADY been independently checked by
--- the caller (each caller's own arg-shape/online-target requirements
--- differ too much to fold in here -- see each call site). Takes
--- `directCitizenid` directly (a citizenid the CALLER has already
--- resolved) instead of re-resolving it from a server id -- this is what
--- lets tabletGiveXp reuse it for a citizenid that may be OFFLINE (XP is a
--- DB-backed, always-offline-capable value; AwardXPDirect itself does not
--- require a live session, see server/progression.lua), unlike
--- '/k9givexp' itself, which can only ever name a currently-connected
--- player. See this file's header PART 2 for the full target-resolution /
--- self-grant / audit writeup this implements unchanged.
--- @param granterSrc number
--- @param granterCitizenid string
--- @param directCitizenid string
--- @param amount number -- already validated by the caller (IsValidGrantAmount)
--- @return boolean ok
--- @return string outcome -- 'self_grant_blocked' | 'xp_unavailable' | 'ok'
--- @return string? recipientCitizenid -- meaningful only when ok == true
--- @return number? newTotal -- meaningful only when ok == true
--- @return boolean? redirectedToPartner -- meaningful only when ok == true
local function GrantHighCommandXp(granterSrc, granterCitizenid, directCitizenid, amount)
    -- TARGET RESOLUTION -- K9 vs. handler. See header PART 2 for the
    -- full writeup. Soft-guarded: a nil
    -- GetActivePartnerCitizenId result (no partnership.lua loaded, the
    -- feature is off, or genuinely no active partnership) leaves
    -- `recipientCitizenid` as `directCitizenid` -- the unambiguous
    -- fallback.
    local recipientCitizenid = directCitizenid
    local redirectedToPartner = false
    if type(GetActivePartnerCitizenId) == 'function' then
        local partnerCitizenid, isK9 = GetActivePartnerCitizenId(directCitizenid)
        if partnerCitizenid and not isK9 then
            -- directCitizenid is the HANDLER-role party -- redirect the
            -- mechanical XP effect to their K9 partner (see header for why).
            recipientCitizenid = partnerCitizenid
            redirectedToPartner = true
        end
    end

    -- SELF-GRANT -- OWNER DECISION (this pass): "High command can grant
    -- anything they want to themselves -- xp promotions permissions etc",
    -- so Config.HighCommand.allowSelfGrant now DEFAULTS TRUE (config.lua's
    -- own comment on that field has the full writeup) -- widened from the
    -- previous default-false, matching config.lua's
    -- Config.FeatureControl.allowHighCommandSelfGrant (server/permissions.lua),
    -- which this same pass widened to every permission namespace. Checked
    -- against BOTH the literal target and the final (possibly redirected)
    -- recipient -- see header PART 2's own "SELF-GRANT" section for why
    -- both, not just the final recipient; that reasoning is unaffected by
    -- the default flip. Read as `~= false`, never `x or default` (which
    -- would be indistinguishable from an explicit `false` and would also
    -- fail to fall back correctly for a config table written before this
    -- field existed at all -- see HighCommandSelfGrantAllowed below), so a
    -- deliberate operator opt-out (Config.HighCommand.allowSelfGrant =
    -- false, restoring the stricter pre-owner-decision behaviour) is the
    -- ONLY thing that ever blocks this.
    local isSelfGrant = directCitizenid == granterCitizenid or recipientCitizenid == granterCitizenid
    if not HighCommandSelfGrantAllowed() and isSelfGrant then
        LogAuditInvocation(granterSrc, ('target_citizenid=%s self_grant=%s'):format(recipientCitizenid, tostring(isSelfGrant)), 'self_grant_blocked')
        return false, 'self_grant_blocked'
    end

    if type(AwardXPDirect) ~= 'function' then
        LogAuditInvocation(granterSrc, ('target_citizenid=%s amount=%d self_grant=%s'):format(recipientCitizenid, amount, tostring(isSelfGrant)), 'xp_unavailable')
        return false, 'xp_unavailable'
    end

    local newTotal = AwardXPDirect(recipientCitizenid, amount, 'high_command_grant')

    -- AUDIT, MADE EXPLICIT (this pass): `self_grant=true` here -- rather
    -- than leaving a reader to notice `whoLabel`'s own citizenid matches
    -- `target_citizenid` by eye -- is what makes a SUCCESSFUL XP self-grant
    -- (the exact case the OWNER DECISION above now permits by default)
    -- unconditionally distinguishable from an ordinary grant to someone
    -- else, in the log itself, never a manual diff. Self-service is the
    -- owner's decision; invisible self-service is not something this file
    -- ships quietly, even though it is now permitted by default.
    LogAuditInvocation(
        granterSrc,
        ('target_citizenid=%s amount=%d new_total=%s self_grant=%s'):format(recipientCitizenid, amount, tostring(newTotal), tostring(isSelfGrant)),
        'ok'
    )

    return true, 'ok', recipientCitizenid, newTotal, redirectedToPartner
end

AddEventHandler('onResourceStart', function(resourceName)
    if GetCurrentResourceName() ~= resourceName then return end

    if not (Config.Features and Config.Features.HighCommand == true) then
        return -- feature disabled -- IsHighCommand above still exists and correctly
               -- returns false for everyone (it re-checks this same flag itself);
               -- '/k9givexp' below is simply never registered.
    end

    assert(
        type(Config.Departments) == 'table',
        '[qbx_k9unit] Config.Features.HighCommand is true but Config.Departments is missing -- ' ..
        'IsHighCommand requires it to resolve the caller\'s own department threshold.'
    )
    -- CLAMP-AND-WARN, DELIBERATELY NEVER THROW -- this used to be a bare
    -- `assert` here, which meant one plausible owner typo (a quoted "6"
    -- instead of a number 6, in ANY configured department) aborted this
    -- ENTIRE onResourceStart handler on the spot, silently skipping
    -- everything still to run below it for the rest of this resource's
    -- uptime -- including RegisterCommand('k9givexp') itself, further down
    -- in this SAME handler (see this file's header PART 2). That is the
    -- exact "one bad config value silently deletes an unrelated feature"
    -- incident class this codebase has already found and fixed once (see
    -- commit "Stop one bad config value silently deleting the ambient audio
    -- feature") -- worse here, because config.lua explicitly invites an
    -- owner who is not a developer to tune Config.Departments per
    -- department. Mirrors the maxXpPerGrant/grantCooldownMs clamp-and-warn
    -- guards twenty lines below (same file, same handler) -- that pattern
    -- was simply never applied up here.
    --
    -- Per-department field reset (never drops the whole department, unlike
    -- server/certifications/'s certifierGrade guard): nil is ALREADY the
    -- documented safe value for this field ("no High Command tier in this
    -- department" -- see this file's header and IsHighCommand's own doc
    -- comment above), so a malformed highCommandGrade is corrected by
    -- forcing it to that same safe nil, exactly like
    -- server/certifications/'s gentler autoAccessGrade treatment --
    -- certifierGrade/auditGrade/label and every other field on this
    -- department are left completely untouched. IsHighCommand itself
    -- (line ~408) already fails closed on a non-number highCommandGrade at
    -- read time regardless -- this guard exists to make that failure LOUD,
    -- once, at start, instead of silent, and to stop it from being able to
    -- take '/k9givexp' down with it.
    if type(Config.Departments) == 'table' then
        for jobName, dept in pairs(Config.Departments) do
            if type(dept) ~= 'table' then
                print(
                    ('[qbx_k9unit] WARNING: Config.Departments[%s] is not a table (found: %s) -- IsHighCommand ' ..
                     'cannot resolve a highCommandGrade for this department and will fail closed (deny High ' ..
                     'Command) for every officer in it, exactly as if no High Command tier were configured. ' ..
                     'Fix Config.Departments[%s] in config.lua to restore it.'):format(
                        tostring(jobName), tostring(dept), tostring(jobName)
                    )
                )
            elseif dept.highCommandGrade ~= nil and type(dept.highCommandGrade) ~= 'number' then
                print(
                    ('[qbx_k9unit] WARNING: Config.Departments[%s].highCommandGrade must be nil or a number ' ..
                     '(found: %s) -- IsHighCommand compares job.grade.level >= dept.highCommandGrade for every ' ..
                     'non-boss officer in that department. nil correctly means "no High Command tier in this ' ..
                     'department" (IsHighCommand fails closed on it, by design) -- FORCING it to nil for this ' ..
                     'session instead of aborting resource start, since nil is the exact same safe fail-closed ' ..
                     'value IsHighCommand already falls back to for a malformed grade at read time. Every other ' ..
                     'field on this department (certifierGrade, auditGrade, label, ...) is unaffected. Find ' ..
                     'Config.Departments[%s].highCommandGrade in config.lua and fix it to restore the intended ' ..
                     'High Command tier.'):format(tostring(jobName), tostring(dept.highCommandGrade), tostring(jobName))
                )
                dept.highCommandGrade = nil
            end
        end
    end

    assert(type(Config.HighCommand) == 'table', '[qbx_k9unit] Config.Features.HighCommand is true but Config.HighCommand is missing.')

    -- THE FOOTGUN THIS CODEBASE KEEPS HITTING -- see this file's header
    -- VALIDATION section for the full writeup. A non-positive/nil/NaN/
    -- infinite maxXpPerGrant DISABLES '/k9givexp' (never registered, loud
    -- console warning), it is never silently read as "no cap".
    local maxXp = Config.HighCommand.maxXpPerGrant
    if not IsValidPositiveFiniteNumber(maxXp) then
        print(
            ('[qbx_k9unit] WARNING: Config.HighCommand.maxXpPerGrant (%s) is not a valid positive, finite number -- ' ..
             '/k9givexp will NOT be registered this session. A non-positive/nil/NaN/infinite value here means ' ..
             '"disabled", never "unlimited" (this resource\'s established fail-closed convention -- see ' ..
             'server/cooldowns.lua/server/progression.lua for the identical footgun on their own numeric caps). ' ..
             'Fix Config.HighCommand.maxXpPerGrant and restart this resource to enable /k9givexp.'):format(tostring(maxXp))
        )
        return
    end

    -- DISCLOSURE, NOT A BLOCK (unlike maxXpPerGrant above): an invalid
    -- grantCooldownMs fails SAFE on its own (server/cooldowns.lua's
    -- IsOnCooldown treats it as "permanently on cooldown after the first
    -- grant", never "unlimited") -- see this file's header COOLDOWN
    -- section. Warned here so an operator sees this at start rather than
    -- only discovering it the second time high command ever runs this
    -- command, but the command is still registered either way.
    if not IsValidPositiveFiniteNumber(Config.HighCommand.grantCooldownMs) then
        print(
            ('[qbx_k9unit] WARNING: Config.HighCommand.grantCooldownMs (%s) is not a valid positive, finite number -- ' ..
             '/k9givexp will still be registered, but server/cooldowns.lua\'s own fail-closed IsOnCooldown means ' ..
             'each officer will only be able to use it ONCE before being PERMANENTLY on cooldown until this ' ..
             'resource restarts with a fixed value. Fix Config.HighCommand.grantCooldownMs.'):format(tostring(Config.HighCommand.grantCooldownMs))
        )
    end

    --- '/k9givexp [server id] [amount]' -- see this file's header for the
    --- full design writeup.
    RegisterAdminCommand('k9givexp', function(source, args)
        -- Authorization checked BEFORE argument shape, mirroring
        -- server/admin.lua's own k9audit* ordering ("an unauthorized
        -- caller learns nothing about argument validity") -- appropriate
        -- here for an even stronger reason than admin.lua's read-only
        -- audit surface: this command mints economy value. Uses the SAME
        -- IsAuthorizedForXpGrant predicate tabletGiveXp calls below --
        -- see that function's own doc comment.
        if not IsAuthorizedForXpGrant(source) then
            LogAuditInvocation(source, 'n/a', 'denied')
            NotifyPlayer(source, locale('highcommand.not_authorized'), 'error')
            return
        end

        -- Anti-fat-finger cooldown -- see header COOLDOWN section. Silent
        -- no-op on trip, matching this resource's bark/leash-request/
        -- certify-action convention (still audited below, unlike those,
        -- since this path mints economy value). SAME HighCommandGrantCooldown
        -- instance tabletGiveXp consumes from below -- one shared per-officer
        -- bucket regardless of which interface (command or tablet) is used,
        -- which is the correct anti-fat-finger behavior, not a bug: the
        -- point of this cooldown is bounding how often ONE officer can issue
        -- ANY grant, independent of which button they pressed.
        if not HighCommandGrantCooldown.Consume(source, Config.HighCommand.grantCooldownMs) then
            LogAuditInvocation(source, 'n/a', 'rate_limited')
            return
        end

        local rawTargetServerId = tonumber(args[1])
        local rawAmount = tonumber(args[2])
        if not IsValidServerIdArg(rawTargetServerId) or not IsValidGrantAmount(rawAmount, Config.HighCommand.maxXpPerGrant) then
            LogAuditInvocation(source, 'n/a', 'invalid_args')
            if not IsValidServerIdArg(rawTargetServerId) then
                NotifyPlayer(source, locale('highcommand.usage_givexp'), 'error')
            else
                NotifyPlayer(source, locale('highcommand.invalid_amount', Config.HighCommand.maxXpPerGrant), 'error')
            end
            return
        end
        local targetServerId = rawTargetServerId
        local amount = rawAmount

        local granterPlayer = exports.qbx_core:GetPlayer(source)
        local granterCitizenid = granterPlayer and granterPlayer.PlayerData and granterPlayer.PlayerData.citizenid
        if not granterCitizenid then
            LogAuditInvocation(source, 'n/a', 'invalid_args')
            NotifyPlayer(source, locale('common.unable_to_resolve_citizenid'), 'error')
            return
        end

        -- '/k9givexp' takes a SERVER id and therefore can only ever name a
        -- currently-connected player -- this online-resolution step is NOT
        -- shared with tabletGiveXp below, which is citizenid-keyed and
        -- offline-capable by design (see GrantHighCommandXp's own doc
        -- comment for why that asymmetry is fine here, unlike the
        -- certification grant's model-check asymmetry: XP has no live-ped
        -- precondition to lose by going offline-capable).
        local targetPlayer = exports.qbx_core:GetPlayer(targetServerId)
        local directCitizenid = targetPlayer and targetPlayer.PlayerData and targetPlayer.PlayerData.citizenid
        if not directCitizenid then
            LogAuditInvocation(source, 'n/a', 'target_unresolvable')
            NotifyPlayer(source, locale('common.target_no_longer_online'), 'error')
            return
        end

        local ok, outcome, recipientCitizenid, newTotal, redirectedToPartner = GrantHighCommandXp(source, granterCitizenid, directCitizenid, amount)
        if not ok then
            if outcome == 'self_grant_blocked' then
                NotifyPlayer(source, locale('highcommand.self_grant_disabled'), 'error')
            elseif outcome == 'xp_unavailable' then
                NotifyPlayer(source, locale('highcommand.xp_system_unavailable'), 'error')
            end
            return
        end

        NotifyPlayer(source, locale('highcommand.grant_success_granter', amount, recipientCitizenid, newTotal or amount), 'success')

        if redirectedToPartner then
            -- directCitizenid (the handler actually targeted) is the one
            -- online party we can notify -- their possibly-offline K9
            -- partner (recipientCitizenid) has no live client to notify
            -- regardless. Worded to make the redirection explicit.
            NotifyPlayer(targetServerId, locale('highcommand.grant_success_target_partner', amount, newTotal or amount), 'success')
        else
            NotifyPlayer(targetServerId, locale('highcommand.grant_success_target', amount, newTotal or amount), 'success')
        end
    end, false)

    -- ==================================================================
    -- TABLET CALLBACK -- qbx_k9unit:server:tabletGiveXp. Same
    -- IsAuthorizedForXpGrant/HighCommandGrantCooldown/IsValidGrantAmount/
    -- GrantHighCommandXp core as '/k9givexp' immediately above -- see each
    -- one's own doc comment. citizenid-keyed and offline-capable (unlike
    -- the command): AwardXPDirect itself has no live-session requirement,
    -- so there is no equivalent of the certification grant's "cannot
    -- verify a live ped model for an offline target" asymmetry here (see
    -- server/certifications/'s GrantCertificationForTablet doc comment
    -- for that DIFFERENT case, where the answer came out the other way).
    -- Gated on Config.Features.CommandTablet, mirroring
    -- server/permissions.lua's identical "TABLET CALLBACKS" gate --
    -- registered here, inside onResourceStart, specifically because it
    -- needs HighCommandGrantCooldown/Config.HighCommand.maxXpPerGrant to
    -- already be confirmed valid by the guards above -- exactly the same
    -- reason '/k9givexp' itself is only ever registered from inside this
    -- same block. `source` is ox_lib's own callback dispatch value
    -- (server-verified, never client-supplied) and is passed straight
    -- through as `granterSrc` -- never trust `targetCitizenid` as the
    -- CALLER's own identity.
    -- ==================================================================
    if Config.Features and Config.Features.CommandTablet == true then
        lib.callback.register('qbx_k9unit:server:tabletGiveXp', function(source, targetCitizenid, amount)
            if type(targetCitizenid) ~= 'string' or targetCitizenid == '' then
                return { ok = false, error = 'invalid_args' }
            end

            if not IsAuthorizedForXpGrant(source) then
                LogAuditInvocation(source, 'n/a', 'denied')
                return { ok = false, error = 'denied', message = locale('highcommand.not_authorized') }
            end

            if not HighCommandGrantCooldown.Consume(source, Config.HighCommand.grantCooldownMs) then
                LogAuditInvocation(source, 'n/a', 'rate_limited')
                return { ok = false, error = 'rate_limited' }
            end

            if not IsValidGrantAmount(amount, Config.HighCommand.maxXpPerGrant) then
                LogAuditInvocation(source, 'n/a', 'invalid_args')
                return { ok = false, error = 'invalid_amount', message = locale('highcommand.invalid_amount', Config.HighCommand.maxXpPerGrant) }
            end

            local granterPlayer = exports.qbx_core:GetPlayer(source)
            local granterCitizenid = granterPlayer and granterPlayer.PlayerData and granterPlayer.PlayerData.citizenid
            if not granterCitizenid then
                LogAuditInvocation(source, 'n/a', 'invalid_args')
                return { ok = false, error = 'invalid_granter', message = locale('common.unable_to_resolve_citizenid') }
            end

            local ok, outcome, recipientCitizenid, newTotal = GrantHighCommandXp(source, granterCitizenid, targetCitizenid, amount)
            if not ok then
                if outcome == 'self_grant_blocked' then
                    return { ok = false, error = outcome, message = locale('highcommand.self_grant_disabled') }
                elseif outcome == 'xp_unavailable' then
                    return { ok = false, error = outcome, message = locale('highcommand.xp_system_unavailable') }
                end
                return { ok = false, error = outcome }
            end

            return { ok = true, message = locale('highcommand.grant_success_granter', amount, recipientCitizenid, newTotal or amount) }
        end)
    end

    print('[qbx_k9unit] highcommand.lua: /k9givexp registered.')
end)
