--[[
    john-k9/server/permissions.lua

    Config.Features.PermissionGrants / Config.Permissions. The grantable-
    permissions layer the project owner asked for: PD high command grants a
    NAMED capability (a Config.Permissions key -- 'k9.access', 'k9.certify',
    'k9.audit', 'k9.givexp') to one specific citizenid -- a handler OR a K9,
    since both are just citizenids to this resource -- and can revoke it
    later. See config.lua's own Config.Permissions block for the capability
    catalog and for the resolution order this file implements exactly.

    ======================================================================
    RESOLUTION ORDER (config.lua's own words, copied here so this file's
    behavior and its own documentation of that behavior cannot drift apart).
    FIRST MATCH WINS:
      1. an active, explicitly granted permission for that citizenid  -> ALLOW
      2. the caller is high command (server/highcommand.lua's IsHighCommand) -> ALLOW
      3. the caller meets the legacy rank gate (certifierGrade/auditGrade/etc.) -> ALLOW
      4. otherwise                                                     -> DENY
    PURELY ADDITIVE. Nothing gated on rank today may stop working -- a grant
    only ever WIDENS access, never narrows it.

    HOW STEP 1 IS WIRED IN, PER CAPABILITY (this task's own "prefer adding a
    permission check alongside the existing one over rewriting it"): each
    consuming gate already implements steps 2+3 itself (server/certifications/'s
    HasK9Access/IsEligibleCertifier, server/admin.lua's IsAuthorizedAdmin, and
    server/highcommand.lua's '/k9givexp' handler). This file's OWN job is
    step 1 alone -- HasPermission(citizenid, key) below -- inserted at each of
    those four call sites, guarded by `type(HasPermission) == 'function'`
    (this resource's established soft-dependency convention), BEFORE their
    existing high-command/rank checks so step 1 is genuinely evaluated first,
    even though for a plain boolean OR the evaluation order does not change
    the final answer -- it is kept in this order anyway so the documented
    "first match wins" story matches the code's own physical layout, not just
    its truth table. Three of those four edits are in THIS pass (certifications.lua
    x2, admin.lua x1, both files explicitly UNOWNED for this task); the
    fourth (highcommand.lua's '/k9givexp') is REPORTED, not edited, because
    that file has a live owner this pass -- see this file's own hand-off
    report for the exact snippet.

    ======================================================================
    THE "REVOKED BUT STILL HAS IT BY RANK" CASE -- the single most likely
    place this feature could mislead an officer, and the reason
    RevokePermission below never just returns a bare boolean. Revoking a
    grant from a citizenid who ALSO independently qualifies via high command
    or the legacy rank gate for that SAME capability does NOT remove their
    access -- step 3 (or step 2) still allows them. RevokePermission's own
    reconciliation, once the revoke UPDATE itself is confirmed to have
    committed, is:
      - if the target citizenid is CURRENTLY ONLINE: re-check, using their
        own LIVE job, whether they would still pass steps 2/3 for this exact
        capability RIGHT NOW (see LegacyOrHighCommandStillQualifies below --
        this reuses the already-global HasK9Access for 'k9.access', a small
        internal duplicate of the certifierGrade/auditGrade comparison shape
        for 'k9.certify'/'k9.audit' -- deliberately NOT achieved by exporting
        certifications.lua's IsEligibleCertifier / admin.lua's
        IsAuthorizedAdmin as new resource-globals purely for this one
        reconciliation read, which would have required a .luacheckrc globals
        entry this file cannot add for itself -- and IsHighCommand directly
        for 'k9.givexp', which has no legacy tier below high command at all).
        Because RefreshPermissionCache has ALREADY run by this point (see
        CACHING below), step 1 correctly reads as false for the
        just-revoked grant, so calling the real gate function here answers
        exactly "steps 2+3, and 2+3 alone" -- no double-counting risk.
      - if the target citizenid is currently OFFLINE: their live job cannot
        be read at all (every rank/high-command check in this resource
        requires a connected Player object -- there is no secondary source
        of truth this file queries for an offline citizenid's current job).
        This is reported as a THIRD, HONEST outcome
        ('unknown_target_offline'), never silently folded into either
        "fully revoked" or "still has it" -- claiming either one without
        being able to check it would be exactly the kind of lie this task
        warned against, just aimed the other direction.
    RevokePermission's return is therefore a 3-way `stillHasAccess` result
    (nil | 'rank_or_high_command' | 'unknown_target_offline'), meaningful
    only when the revoke itself succeeded (`ok == true`) -- see that
    function's own doc comment below for the exact contract. The tablet is
    expected to render THREE distinct messages, not two.

    ======================================================================
    CACHING -- read before changing anything below.

    PermissionCache[citizenid] = { [permissionKey] = true, ... } -- presence
    of a key means "this citizenid currently holds an ACTIVE grant of this
    permission", absence means either "no grant" or "not currently cached at
    all" (see scope below); there is no separate boolean, a missing key IS
    the false case.

    SCOPE, DELIBERATELY NARROWER than server/certifications/'s own
    Certifications cache: this table is populated ONLY for citizenids that
    are (or very recently were) ONLINE -- warmed on
    'QBCore:Server:PlayerLoaded', on this file's own 'onResourceStart'
    backfill loop for players already connected across a resource restart
    (mirrors server/main.lua's identical backfill for
    RefreshCertificationCache), and refreshed by GrantPermission/
    RevokePermission immediately after their own DB write commits -- but,
    UNLIKE certifications.lua's cache, ONLY when the target citizenid is
    confirmed online AT THAT MOMENT (RefreshPermissionCacheIfOnline below).
    Granting/revoking a permission for a citizenid who is offline right now
    deliberately does NOT create a cache entry for them -- there is nothing
    to keep in sync for a citizenid with no live session, and populating one
    anyway would grow this table forever for every citizenid ever granted a
    permission, whether or not they ever log in again this session (the
    exact unbounded-growth class server/certifications/'s own Certifications
    table was found to have, and fixed reactively, for cert grants). Cleared
    entirely on 'playerDropped'.

    Every consumer (HasPermission) additionally re-checks
    `Config.Features.PermissionGrants` on every single call, mirroring
    server/highcommand.lua's IsHighCommand: this bypass is consulted from
    ALWAYS-LIVE gates with no registration step of their own to hide behind,
    so turning the feature off must genuinely disable it immediately, with
    no restart required -- caching "is the feature on" would defeat that.

    STALENESS WINDOW, STATED EXACTLY (this task's own explicit requirement):
      - For a grant/revoke made THROUGH this file's own GrantPermission/
        RevokePermission: at most the width of one MySQL round trip --
        specifically, the coroutine-yield gap between the INSERT/UPDATE
        itself committing and RefreshPermissionCache's own follow-up SELECT
        returning. HasPermission can theoretically observe a stale answer
        for a citizenid whose OWN action is what changed their own grant
        (vanishingly rare in practice, since a player is never the one
        calling GrantPermission/RevokePermission about themselves -- only
        high command can call these, and self-grant is blocked outright, see
        SELF-GRANT below) -- this is the SAME narrow, previously-disclosed
        window server/certifications/'s own Certifications cache has
        always had relative to RefreshCertificationCache; not a new class of
        risk this file introduces.
      - For a grant/revoke made by ANY OTHER means (a hand-run SQL
        statement against k9_permissions, a different resource, a restored
        backup): NOT observed until that citizenid's next
        'QBCore:Server:PlayerLoaded' (reconnect) or this resource's next
        restart (onResourceStart backfill). This file has no polling or
        pub/sub mechanism watching the table for external writes -- matching
        every other cache in this resource (Certifications, K9XP, etc).
      - A citizenid who is offline right now has NO cache entry at all
        (see SCOPE above) -- there is nothing to be stale, by construction;
        the correct, current answer is computed fresh from the DB the moment
        they next connect.

    ======================================================================
    SELF-GRANT -- OWNER DECISION (this pass). The project owner's own
    words: "High command can grant anything they want to themselves -- xp
    promotions permissions etc." GrantPermission below still special-cases
    `targetCitizenid == granterCitizenid` as its own branch (a self-grant is
    never silently indistinguishable from a normal grant -- see AUDIT
    below), but the branch's OUTCOME is now governed by ONE switch for
    EVERY permission namespace this file validates: the four named
    capabilities (k9.access/k9.certify/k9.audit/k9.givexp), 'block.<Name>',
    and 'feature.<Name>' alike all read config.lua's
    Config.FeatureControl.allowHighCommandSelfGrant (default true, WIDENED
    this pass from 'feature.<Name>' only -- see HighCommandSelfGrantAllowed
    below, the ONLY place that reads it). Checked against the GRANTER'S OWN
    server-resolved citizenid (exports.qbx_core:GetPlayer(granterSrc).
    PlayerData.citizenid), never a client claim.

    NOT A WEAKENING OF WHO COUNTS AS HIGH COMMAND: IsHighCommand(granterSrc)
    is still checked, unconditionally, earlier in this same function, before
    this branch can ever be reached -- this pass only widens what an
    ALREADY-VERIFIED high-command officer may do to their own citizenid,
    never who qualifies as high command in the first place.

    HISTORY, FOR CONTEXT: an earlier pass exempted ONLY 'feature.<Name>'
    from an unconditional self-grant block, to close a genuine day-one
    deadlock -- Config.FeatureControl.RequireGrant.AdminAuditCommands ships
    `true` by default, server/admin.lua's IsAuthorizedAdmin does not exempt
    high command from that RequireGrant check, only high command can call
    GrantPermission at all, and self-grant was blocked outright, so a SOLO
    high-command officer (the owner, on day one, before a second officer is
    ever promoted) had no path, ever, to grant themselves
    'feature.AdminAuditCommands', permanently. The same 4-step resolution,
    with no high-command exemption at its own step 3, applies to the OTHER
    eight RequireGrant entries too (server/combat.lua's
    IsCombatFeaturePermittedForCitizenId, server/pursuitsprint.lua's
    IsPursuitSprintPermittedForCitizenId) -- the same deadlock, one ability
    at a time rather than a whole tablet tab. The four named capabilities
    and 'block.<Name>' were deliberately left blocked at that time, on the
    reasoning that a high-command officer already bypasses every one of
    those checks directly via IsHighCommand (HasK9Access/IsEligibleCertifier/
    IsAuthorizedAdmin/'/k9givexp' all check IsHighCommand(source) BEFORE
    ever consulting a 'k9.*' grant), so self-granting one of those four
    changed nothing about their own access and fixed no deadlock. That
    reasoning is still true; it is simply no longer the deciding factor --
    the owner asked for self-service across the board as a matter of what
    his server should allow, not because a second deadlock was found, and
    this pass implements that request directly rather than reading it out
    of a bug report.

    THE ESCAPE HATCH STAYS AVAILABLE: an operator who wants the stricter,
    pre-widening behavior back -- a second high-command officer's own
    action required on every grant, even to another high-command officer,
    even for a capability IsHighCommand already grants them directly --
    sets Config.FeatureControl.allowHighCommandSelfGrant = false and gets
    it, uniformly, across every namespace this file validates. Read as
    `~= false`, never `x or default`, so an explicit `false` is never
    misread as "not set" -- see HighCommandSelfGrantAllowed below.

    AUDIT, MADE EXPLICIT: a self-grant used to be provable only by comparing
    the audit line's own granter (`whoLabel`) and target fields by eye --
    both were always present, but neither line ever said "this is a
    self-grant" outright. Every GrantPermission audit line from the point
    `granterCitizenid` is resolved onward now carries an explicit
    `self=true|false` field (see GrantPermission's own `isSelfGrant` local
    and its doc comment there for the exact mechanics), so a self-grant is
    unconditionally distinguishable from a normal grant in the log itself,
    never a manual diff. Self-service is the owner's decision; invisible
    self-service is not something this file ships quietly, even though it
    is now permitted by default.

    DELIBERATELY NOT extended to RevokePermission: a high-command officer
    revoking a grant they hold (self-granted per this section, or granted
    to them by another high-command officer) is removing standing access,
    not adding it -- there is no "no second person in the audit trail"
    concern in that direction. RevokePermission already allows self-revoke
    unconditionally, unaffected by this pass.

    ======================================================================
    DB ERRORS THROW, NOT NIL -- every MySQL.*.await call below is
    pcall-guarded, matching server/certifications/'s own established
    discipline. GrantPermission's INSERT mirrors GrantCertification's
    GrantInFlight in-memory TOCTOU lock (keyed `citizenid .. ':' .. permission`)
    plus IsDuplicateKeyError handling for the DB's own
    `uq_one_active_permission_per_citizen` unique-key backstop (a race two
    concurrent grants can hit is NOT a real failure, it means another
    request already won -- same as certifications.lua's own documented
    reasoning, and the exact instruction the db-schema agent's own report
    on this table repeats). RevokePermission's UPDATE mirrors
    RevokeCertification's reconciliation-on-throw: a thrown UPDATE is NEVER
    reported as a success or a failure by guesswork -- an independent,
    fresh read (IsPermissionRowConfirmedActive below) decides which one
    actually happened before anything else (cache refresh, notifications,
    the "still has it by rank" reconciliation) runs.

    ======================================================================
    COOLDOWN -- PERMISSION_ACTION_COOLDOWN_MS below, via server/cooldowns.lua's
    NewCooldown, ONE shared instance covering both GrantPermission and
    RevokePermission, keyed by the GRANTER'S own source (mirrors
    server/certifications/'s CertifyActionCooldown / server/admin.lua's
    AuditCooldown / server/highcommand.lua's HighCommandGrantCooldown shape
    exactly -- one instance per related-action group, not one per action).
    A plain positive LITERAL (1500ms, matching CERTIFY_ACTION_COOLDOWN_MS's
    own value), NOT a new Config field -- this file is told not to edit
    config.lua, and certifications.lua's own CERTIFY_ACTION_COOLDOWN_MS
    already establishes "a hardcoded local constant, not a Config value, is
    fine for an anti-fat-finger throttle on an already-trusted actor" as
    this resource's own precedent for exactly this situation.

    THE NewCooldown FOOTGUN, EXPLICITLY TESTED (this task's own instruction):
    server/cooldowns.lua's IsOnCooldown treats a non-positive/nil/NaN
    threshold as PERMANENTLY ON, never "no cooldown" -- 1500 is a plain
    positive literal here, never a Config read that could be 0/negative/nil,
    so AssertValidDefaultThreshold's constructor-time guard passes and this
    footgun cannot manifest for this file's own cooldown. Covered anyway by
    tests/permissions_spec.lua ("cooldown: a second grant/revoke from the
    same source inside the window is rejected, recovers once elapsed").

    ======================================================================
    AUDIT -- every GrantPermission/RevokePermission invocation (denied,
    rate-limited, invalid args, self-grant blocked, already-granted,
    not-granted, db error, or ok) is printed via LogAuditInvocation below,
    matching server/admin.lua's own "%s ran %s(%s) -> %s" print format
    EXACTLY (this task's explicit instruction) -- granter citizenid (via
    `whoLabel`, same resolution as admin.lua's own), action name, and a
    `detail` string packing the permission key and target citizenid
    together, then the outcome.

    ======================================================================
    NOTIFICATIONS -- deliberately narrow. This file sends an ox_lib toast to
    the TARGET only (if currently online), and only when the action ACTUALLY
    changed something for them:
      - grant success: always notified (a grant is always a real change,
        even if they already had equivalent access via rank -- it persists
        independently of any future rank change).
      - revoke success: notified ONLY when `stillHasAccess == nil` (fully
        removed). Deliberately SUPPRESSED when `stillHasAccess ==
        'rank_or_high_command'` -- telling a player "a capability you held
        has been revoked" when nothing actually changed for them would be
        exactly the kind of misleading message this task warned against,
        just aimed at the target instead of the admin. (The
        'unknown_target_offline' case has no online client to notify at
        all, by definition.)
    The GRANTER is deliberately NOT sent a toast by this file -- GrantPermission/
    RevokePermission return a structured `(ok, outcome, stillHasAccess)`
    synchronously to their caller (the tablet's own server-side glue,
    per the FILE-TO-FILE CONTRACT below), which is expected to render its
    own inline UI feedback rather than depend on an ox_lib toast the tablet
    might not even be the right place to show. This is a disclosed,
    deliberate asymmetry, not an oversight -- flagged for coder-ui/coder-frontend
    to confirm or override once the tablet's own UX is designed.

    LOCALE KEYS THIS FILE NEEDS -- only TWO new keys, kept deliberately
    minimal per the "no granter-facing toast" decision above; ALREADY
    LANDED in locales/en.json (confirmed by direct read, not assumed) with
    this exact English text -- documented here for reference, not as an
    open request:
      permissions.grant_notify_target  = "High command granted you: %s"
      permissions.revoke_notify_target = "High command revoked: %s"
      (reused, already present) common.unable_to_resolve_citizenid
      (reused, already present) common.target_no_longer_online -- NOT currently reachable by any path in this file (GrantPermission/RevokePermission take a citizenid, never a server id, so there is no "target must be online" failure mode to report) -- listed only because ListActivePermissionsForCitizenId/ListPermissionRoster's callers may want it for their own UI; this file itself never calls locale() with it.

    ======================================================================
    FILE-TO-FILE CONTRACT:
    - THIS FILE exposes FIVE resource-global (no `local`) functions -- see
      each one's own doc comment below for the exact signature/outcome
      strings:
        HasPermission(citizenid, permissionKey) -> boolean
        GrantPermission(granterSrc, targetCitizenid, permissionKey) -> ok, outcome
        RevokePermission(granterSrc, targetCitizenid, permissionKey) -> ok, outcome, stillHasAccess
        ListActivePermissionsForCitizenId(callerSrc, targetCitizenid) -> ok, rowsOrOutcome
        ListPermissionRoster(callerSrc, permissionKey) -> ok, rowsOrOutcome
      HasPermission is consulted by server/certifications/ (HasK9Access,
      IsEligibleCertifier), server/admin.lua (IsAuthorizedAdmin), and
      server/highcommand.lua's '/k9givexp'/tabletGiveXp handler
      (IsAuthorizedForXpGrant, checking the 'k9.givexp' key -- WIRED as of a
      later pass than the one that wrote "reported, not yet wired" here;
      confirmed live by direct read of that function), each behind a
      `type(HasPermission) == 'function'` guard. The other four are for
      the tablet's own server-side glue (coder-ui/coder-frontend) to call
      directly from THEIR OWN event/callback handler, using THAT handler's
      own real `source` -- never a client-supplied one -- for `granterSrc`/
      `callerSrc`. GrantPermission/RevokePermission/ListActivePermissionsForCitizenId/
      ListPermissionRoster all independently re-verify high-command
      authorization THEMSELVES (never trust a caller to have already
      checked it) -- see each one's own doc comment.
    - THIS FILE calls `NewCooldown` (server/cooldowns.lua) at this file's own
      file-load time -- MUST load after server/cooldowns.lua.
    - THIS FILE calls `NotifyPlayer` (server/notify.lua) at run time only.
    - THIS FILE calls `IsHighCommand` (server/highcommand.lua) and
      `HasK9Access` (server/certifications/) at run time only, both
      behind `type(...) == 'function'` guards -- genuine soft dependencies,
      no load-order requirement either way.
    - THIS FILE calls `ForceDetachLeashForSource` (server/main.lua),
      `EndActiveEffectForHolder` (server/combat.lua), and
      `ForceBreakPartnershipForCitizenId` (server/partnership.lua) at run
      time only, from RevokePermission's own 'k9.access'-fully-revoked
      teardown (see that function's own doc comment for the full "de-assign
      button" writeup) -- all three behind `type(...) == 'function'` guards.
      Genuinely required here, not just defensive style: all three load
      AFTER this file in fxmanifest.lua's server_scripts list, so none can
      be assumed present by load order the way server/certifications/
      (loaded even later than all three) can assume server/main.lua's
      ForceDetachLeashForSource.
    - THIS FILE is consulted BY server/certifications/ and
      server/admin.lua (see above) -- this file does NOT call into either of
      those two, so there is no load-order cycle.
    - THIS FILE does NOT edit server/highcommand.lua, server/kennel.lua,
      server/fetch.lua, server/propattachment.lua, server/entities.lua,
      server/progression.lua, or server/wellbeing.lua -- all have live
      owners this pass. The one integration those files would otherwise
      need (highcommand.lua's '/k9givexp') is reported, not performed.
    - OWNER-DIRECTED EXTENSION (later pass, "add or remove permissions"):
      IsValidPermissionKey/PermissionLabelFor now consult
      server/permissionkeycatalog.lua's own IsKnownPermissionCatalogKey/
      GetPermissionCatalogLabel, both behind `type(...) == 'function'`
      guards -- a genuine soft dependency, no load-order requirement either
      way, falling back to this file's original Config.Permissions-only
      behavior if that file is absent. GrantPermission additionally
      acquires that file's own PermissionKeyEditMutex (a bare global,
      `type(...) == 'table'` guarded) around its own write, mirroring
      server/certifications/'s SetCertificationTier / TierEditMutex
      pairing exactly -- see server/permissionkeycatalog.lua's own header
      "THE DELETE-VS-GRANT RACE" for the full writeup. THIS FILE does not
      call into that file for anything else, and that file's own three
      tablet callbacks are registered entirely on its own, independent of
      this file's own tabletGrantPermission/tabletRevokePermission pair
      below.

    CONFIG THIS FILE ASSUMES EXISTS (already added by the config owner):
      Config.Features.PermissionGrants : boolean
      Config.Permissions : table<string, { label: string, description: string? }>
      -- asserted in full at THIS FILE'S OWN LOAD TIME, unconditionally (not
      -- deferred to onResourceStart, and not gated on the feature flag) --
      -- same "authorization-root file, fail loudly on a genuine
      -- misconfiguration instantly rather than only as an inexplicable
      -- 'nobody can ever get any permission'" reasoning
      -- server/certifications/'s own HasK9Access config-safety guard
      -- already documents for itself, applied here because HasPermission is
      -- consulted from those same always-live gates regardless of whether
      -- PermissionGrants is on.

    ======================================================================
    TABLET NETWORK CONTRACT -- client/tablet.lua (coder-frontend) already
    proposed and built against these exact two callback names (confirmed by
    direct read of that file, not re-negotiated from scratch):
      lib.callback 'john-k9:server:tabletGrantPermission'
          (targetCitizenid: string, permissionKey: string) -> { ok: boolean, reason: string? }
      lib.callback 'john-k9:server:tabletRevokePermission'
          (targetCitizenid: string, permissionKey: string) -> { ok: boolean, reason: string? }
    Both are thin wrappers over GrantPermission/RevokePermission, registered
    ONLY when Config.Features.CommandTablet is true (checked at this file's
    own load time, matching client/tablet.lua's own "gate at registration,
    not just inside the handler" convention -- config.lua is a
    shared_script, already loaded in full by the time this file's own
    server_scripts entry runs). `source` comes from ox_lib's own callback
    dispatch (server-verified, never a client-supplied value) and is passed
    straight through as `granterSrc`/`callerSrc` -- these two functions
    already independently re-verify high-command authorization from that
    source's own live job, so this wrapper adds no authorization logic of
    its own, only the return-shape translation:
      - grant success            -> { ok = true }
      - grant/revoke failure     -> { ok = false, reason = <outcome string> }
      - revoke success, fully removed          -> { ok = true }
      - revoke success, target still qualifies -> { ok = true, reason = 'rank_or_high_command' }
      - revoke success, target offline         -> { ok = true, reason = 'unknown_target_offline' }
    The last two are successes (the revoke itself committed) carrying a
    `reason` anyway -- this is deliberate, not a misuse of the field: it is
    the ONLY channel available in a plain `{ ok, reason }` shape to keep the
    "revoked, but they still have this by rank" case from reading as a
    silent, unqualified success. client/tablet.lua forwards `reason`
    opaque/unmodified to the NUI in every case (its own header: "coder-ui
    owns NUI-side copy") -- no locale key is needed for either of these
    reason strings on the SERVER side either, since neither ever reaches
    locale() -- they are internal outcome tags, not player-facing text.

    RESOLVED, DIFFERENTLY THAN EITHER OPTION THIS PARAGRAPH ORIGINALLY
    FLOATED (issue-closer sweep, 2026-08-26): this used to say
    `john-k9:server:tabletListRoster` was "NOT IMPLEMENTED HERE, AND
    DELIBERATELY SO" and left the three-way aggregation (certifications/
    XP/permissions) as an open cross-file architecture question for
    coder-frontend/coder-ui/coder-architect to decide. Verified directly:
    that literal callback name was never built, and no file anywhere calls
    this file's own ListActivePermissionsForCitizenId/ListPermissionRoster
    for that purpose -- but the underlying need WAS answered, by
    server/tablet.lua, with a two-callback split rather than one
    aggregating call:
      - `john-k9:server:tabletRequestRoster` -- lists MANY people
        (bounded per department) with certification + XP/tier fields only,
        no permissions column per row.
      - `john-k9:server:tabletRequestPersonSummary` -- the drill-down for
        ONE citizenid, which DOES merge all three: certifications, XP/tier,
        AND permissions (via that file's own QueryActivePermissionSet, a
        direct k9_permissions read it maintains itself, structurally
        parallel to but independent of this file's
        ListActivePermissionsForCitizenId rather than calling it).
    So "browse the roster, drill into a person for the full picture"
    is the shape that shipped, not "every roster row already shows
    permissions" -- a real, load-bearing distinction for anyone consuming
    this comment, not merely a naming difference from the original ask.
    This file's own two roster-shaped exports
    (ListActivePermissionsForCitizenId, ListPermissionRoster) remain
    unused by server/tablet.lua's aggregation and are still available for
    any future consumer that wants this file's own row shape instead of
    tablet.lua's independent read.
    ======================================================================

    FEATURE-BLOCK PUSH (this pass) -- closes a drift-guard finding: client/
    featureblocks.lua registers RegisterNetEvent('john-k9:client:
    featureBlocksSync', ...) but, until now, no server file ever fired it,
    so the twelve purely client-rendered features that file exists to gate
    per-person could never actually learn they were blocked -- the tablet
    would report a successful `block.<Name>` grant that silently did
    nothing. See this file's own "FEATURE-BLOCK PUSH" code section
    (immediately after RefreshPermissionCacheIfOnline below) for the full
    per-function writeup; summarized here for a header-only reader:
      - PUSHES (TriggerClientEvent('john-k9:client:featureBlocksSync',
        targetSrc, blockedFeatureNames)) fire from FOUR points: this file's
        own 'QBCore:Server:PlayerLoaded' handler (join/reconnect), this
        file's own 'onResourceStart' backfill loop (a restart while already
        online), and the tails of GrantPermission/RevokePermission
        themselves, scoped to the `block.<Name>` permission namespace only
        and ONLY when the target is currently online. Every push targets
        that ONE citizenid's own resolved server id -- never `-1`/broadcast.
      - PULLS: a new RegisterNetEvent('john-k9:server:
        requestFeatureBlocksSync', ...), registered near the bottom of this
        file, lets client/featureblocks.lua re-request its own set on demand
        (a client-side script restart mid-session, or simply as a defensive
        belt-and-suspenders call at that file's own load) -- see that
        registration's own doc comment for the full ordering writeup.
      - THE CLIENT IS NOT A SECURITY BOUNDARY, and this push does not change
        that: every one of the twelve features this closes the gap for is
        confirmed, by grep across server/*.lua (client/featureblocks.lua's
        own header states this plainly), to have NO server-side effect at
        all -- this push is a UX affordance a modified client could always
        ignore, exactly like every other client-side check this resource
        already ships. It is NOT extended to, and must never be extended to,
        anything with a server-side consequence -- those 29 OTHER features
        already enforce `block.<Name>` for real, inside their OWN
        server-side handler, via this file's pre-existing HasPermission --
        this push adds nothing to that path and does not touch it.
      - FAILS OPEN, both directions: GetActiveBlockedFeatureNames (below)
        returns an empty array on any unresolvable state (feature flag off,
        no cache entry yet), and PushFeatureBlocksToSource silently no-ops
        rather than throwing when it has no valid target -- a push that
        never arrives at all (dropped packet, client not yet loaded, feature
        flag off) leaves client/featureblocks.lua's own ClientFeatureBlocks
        at its documented empty-table default, which that file's own header
        states plainly means "nothing is blocked". A networking hiccup
        degrades to every ability WORKING, never to one being incorrectly
        frozen.
    ======================================================================

    FXMANIFEST.LUA PLACEMENT REQUESTED (server_scripts, not edited here):
    insert `'server/permissions.lua',` immediately after
    `'server/highcommand.lua',` and before `'server/main.lua',` -- satisfies
    the one hard load-order requirement (after server/cooldowns.lua) and
    groups this file with the other authority-tier file it most directly
    complements, though (per the FILE-TO-FILE CONTRACT above) nothing here
    actually requires that exact position -- every cross-file call in either
    direction is guarded by `type(...) == 'function'`.

    SQL / MIGRATION: `k9_permissions` (columns, indexes, and all three query
    shapes this file uses) already landed -- sql/install.sql's own header
    comment on that table, and sql/migrations/0005_create_k9_permissions.sql
    for an existing database. This file was written directly against that
    real, final schema, not a placeholder guess.
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
-- CONFIG-SAFETY GUARD -- run UNCONDITIONALLY, at this file's own LOAD
-- time, same reasoning as server/certifications/'s own guard for
-- Config.Departments/Config.Peds: HasPermission below is consulted from
-- always-live gates regardless of Config.Features.PermissionGrants'
-- current value.
--
-- CLAMP AND WARN, NOT ASSERT (this pass -- see server/cooldowns.lua's
-- header ADDENDUM: "does an operator's config.lua edit alone... reach this
-- value? If yes it must be clamped and warned about, never asserted and
-- aborted"). This used to be a hard `assert` per entry -- correctly
-- diagnosing a real risk, but with the wrong remedy: an uncaught error
-- thrown from THIS FILE's own top-level chunk (this guard runs
-- unconditionally, with no deferring onResourceStart/RegisterNetEvent
-- wrapper, and with no Config.Features gate to make it opt-in) aborts
-- server/permissions.lua's load from that line onward -- taking
-- HasPermission/GrantPermission/RevokePermission (and every other gate in
-- this resource that consults them) down with it, for the rest of that
-- server's uptime, over one operator typo while adding a fifth capability.
-- A malformed entry is dropped (not fatal) instead: PermissionLabelFor
-- already falls back to the raw key when `.label` is missing (see below),
-- so a dropped entry degrades to "this one named capability can no longer
-- be granted" rather than disabling every capability, including the four
-- that were fine.
-- ======================================================================
if type(Config.Permissions) ~= 'table' then
    print(
        '[John-K9] WARNING: Config.Permissions is missing or not a table -- HasPermission/GrantPermission/' ..
        'RevokePermission will treat every permission key as unknown until config.lua is fixed (fails closed, ' ..
        'same as no grants existing). Add the Config.Permissions settings table back to config.lua.'
    )
    Config.Permissions = {}
else
    local validPermissions = {}
    for key, def in pairs(Config.Permissions) do
        if type(key) == 'string' and key ~= ''
            and type(def) == 'table' and type(def.label) == 'string' and def.label ~= ''
            and (def.description == nil or type(def.description) == 'string')
        then
            validPermissions[key] = def
        else
            print(
                ('[John-K9] WARNING: Config.Permissions[%s] is malformed (every key must be a non-empty ' ..
                 'string, .label must be a non-empty string, .description must be a string if present) -- ' ..
                 'dropping this entry so it can never be granted, and continuing to load the rest of ' ..
                 'Config.Permissions.'):format(tostring(key))
            )
        end
    end
    Config.Permissions = validPermissions
end

-- PermissionCache[citizenid] = { [permissionKey] = true, ... } -- see this
-- file's header "CACHING" section for scope (online citizenids only) and
-- the exact staleness window. Local: nothing outside this file should read
-- it directly -- always go through HasPermission(citizenid, permissionKey).
local PermissionCache = {}

-- Anti-fat-finger cooldown shared by GrantPermission/RevokePermission --
-- see header "COOLDOWN" section for why this is a plain positive literal,
-- not a Config field.
local PERMISSION_ACTION_COOLDOWN_MS = 1500
local PermissionActionCooldown = NewCooldown(PERMISSION_ACTION_COOLDOWN_MS)
PermissionActionCooldown.RegisterPlayerDropped()

-- SECURITY (mirrors server/certifications/'s GrantInFlight EXACTLY --
-- see that file's own doc comment for the full TOCTOU writeup, not
-- repeated here): closes GrantPermission's check-then-insert race on its
-- own terms, independent of whether `uq_one_active_permission_per_citizen`
-- is actually present on this install. Keyed "citizenid:permission" (the
-- invariant is scoped per capability). Always released, even on an
-- unexpected thrown error (pcall-wrapped in GrantPermission below).
local GrantInFlight = {}

--- @param value any
--- @return boolean
local function IsValidCitizenId(value)
    -- VARCHAR(50), matching every citizenid column in k9_permissions.
    -- Not an injection backstop (this value only ever reaches a bound `?`
    -- placeholder) -- a plain sanity/DoS-lite bound, matching
    -- server/admin.lua's own IsValidCitizenId.
    return type(value) == 'string' and value ~= '' and #value <= 50
end

--- SECURITY FIX (coder-security, this pass -- the headline finding this
--- pass exists to close): until now this function accepted ONLY an exact
--- key already present in Config.Permissions (the four admin capabilities:
--- k9.access/k9.certify/k9.audit/k9.givexp). It had NO case at all for the
--- 'feature.<Name>'/'block.<Name>' namespace client/tablet.lua's own
--- grantFeature/revokeFeature/blockFeature/unblockFeature (and this file's
--- own header/config.lua's own Config.FeatureControl doc block) already
--- describe as the real storage shape for a per-person feature grant/
--- block -- meaning GrantPermission/RevokePermission rejected EVERY such
--- call with 'invalid_permission' before ever reaching the DB, so
--- Config.FeatureControl.RequireGrant and per-person blocks were
--- unimplementable regardless of what any consuming gate (server/combat.lua's
--- IsCombatFeaturePermittedForCitizenId, server/pursuitsprint.lua's
--- IsPursuitSprintPermittedForCitizenId, server/admin.lua's
--- IsAdminFeaturePermittedForCitizenId, all of which already read
--- HasPermission(citizenid, 'feature.'/'block.' .. Name) correctly) was
--- prepared to check. See server/tablet.lua's own header "A REAL,
--- PRE-EXISTING GAP FOUND WHILE BUILDING THIS" for that file's own
--- independent discovery of the same bug.
---
--- FIXED WITHOUT SIMPLY LOOSENING THE CHECK: `feature.<Name>`/
--- `block.<Name>` are now accepted ONLY when `<Name>` is a REAL key of
--- Config.Features -- the exact same table every one of this resource's
--- feature flags already lives in, so `Config.Features[Name] ~= nil` is a
--- referential check against real, existing resource state, never a
--- free-form pattern match. `feature.NotARealFeature`,
--- `block.'; DROP TABLE k9_permissions;--`, or a >50-char payload are all
--- still rejected exactly as before an unvalidated key would have been --
--- an unvalidated permission key is a new hole, not a fix. Deliberately
--- does NOT additionally require `<Name>` to appear in
--- Config.FeatureControl.RequireGrant: a BLOCK is documented (config.lua's
--- own Config.FeatureControl header) to work against ANY feature, not only
--- ones already listed there ("high command can turn an individual
--- feature on or off for ONE specific K9 or handler"), and a GRANT for a
--- feature that is not in RequireGrant is simply inert rather than unsafe
--- (every consuming gate's own step-3 RequireGrant check only ever reads a
--- 'feature.<Name>' grant when RequireGrant[Name] is true) -- narrowing
--- this further than Config.Features itself would reject a legitimate
--- block with no corresponding safety benefit.
--- OVERLAY UPDATE (owner-directed "add or remove permissions" pass, server/
--- permissionkeycatalog.lua): the four-key `Config.Permissions[value] ~=
--- nil` check below is REPLACED by a soft-dependency call into that file's
--- own live, DB-overlaid catalog (IsKnownPermissionCatalogKey), falling
--- back to the original Config.Permissions-only check if that file is ever
--- absent. This is a genuine behavior WIDENING, deliberate and disclosed:
--- a permission key created PURELY at runtime (never in Config.Permissions
--- at all) now validates here too, and a key high command has TOMBSTONED
--- through that file's own permKeysDelete callback now correctly stops
--- validating even though it is still, unchanged, a literal key of
--- Config.Permissions -- consulting Config.Permissions directly, as this
--- function used to, would have made a tombstoned DEFAULT key impossible
--- to ever actually retire. See server/permissionkeycatalog.lua's own
--- header "NAMESPACE PROTECTION" for why the feature./block. check below
--- is checked FIRST and is completely unaffected by this change -- that
--- namespace is never represented in the permission-key catalog at all,
--- by construction on both sides.
---
--- PRIVILEGE-ESCALATION FIX, DISCLOSED HERE EVEN THOUGH THE FIX ITSELF
--- LIVES ELSEWHERE (server/permissionkeycatalog.lua's own header "RESERVED
--- INTERNAL CAPABILITY KEYS" has the full writeup): IsKnownPermissionCatalogKey
--- now permanently refuses to ever report `true` for 'k9.runtimecontrol' /
--- 'k9.tablettheme' / 'k9.equipmentshoplocations' / 'k9.equipmentshopitems'
--- unless a human has put one of them in Config.Permissions directly --
--- those four literals are every currently-known
--- `HasPermission(citizenid, '<literal>')` escape hatch another file in
--- this resource hardcodes without ever wiring it through Config.Permissions,
--- and this function (via GrantPermission below) is the ONLY place that
--- could otherwise have handed one of them to an arbitrary citizenid once
--- the catalog file let it be manufactured at runtime. Nothing in THIS
--- function changed to close that hole -- the fix is a refusal one layer
--- up, in the only place a brand-new catalog key can ever be created.
-- ADMIN-CAPABILITY BLOCK NAMESPACE (security-audit pass, this pass --
-- "assess, then decide" -- see server/certifications/'s HasK9Access/
-- IsEligibleCertifier and server/admin.lua's IsAuthorizedAdmin, all three
-- of which now consult 'block.k9.access'/'block.k9.certify'/'block.k9.audit'
-- respectively, for the full "why" writeup this table exists to name).
--
-- THE GAP THIS CLOSES: 'k9.access'/'k9.certify'/'k9.audit'/'k9.givexp' each
-- have an INDEPENDENT, non-grant-based qualification route -- HasK9Access's
-- own autoAccessGrade/certification-cache bypasses, IsEligibleCertifier's
-- own certifierGrade/job.isboss bypasses, IsAuthorizedAdmin's own
-- auditGrade/job.isboss bypasses, every one of them ALSO reachable via
-- Config.Features.HighCommand regardless of rank -- that RevokePermission
-- can never touch, because there is no grant row to revoke in the first
-- place. Before this pass, the ONLY lever available to restrain one such
-- officer was demoting their rank or removing them from High Command,
-- which this resource's own owner has repeatedly stated is NOT an
-- acceptable substitute for a scoped, per-person restriction (see
-- config.lua's own Config.FeatureControl header: "an explicit block...
-- can never switch something on, only off" -- the identical principle,
-- previously implemented for Config.Features keys only).
--
-- ONLY these four -- NOT every Config.Permissions/catalog key -- because a
-- CUSTOM key (one with no rank-based bypass of its own, e.g.
-- 'k9.runtimecontrol') is ALREADY fully controlled by RevokePermission
-- alone: there is no independent route around a revoke for a key that is
-- pure grant, so a second, parallel "block" for it would be redundant, not
-- safer -- exactly IsValidPermissionKey's own established "narrower than
-- it could be, on purpose" posture for the feature./block. namespace above.
-- A small, explicit, hand-maintained set (this resource's own established
-- pattern for a genuinely small, closed list -- see LEGACY_PERMISSION_KEYS,
-- server/tablet.lua, for the near-identical precedent this mirrors; kept
-- as its own copy here rather than a shared export for the same
-- "each file keeps its own tiny copy of a genuinely small, self-contained
-- check" reasoning server/permissions.lua's own IsDuplicateKeyError doc
-- comment already names).
--
-- DELIBERATELY 'block.' ONLY, never 'feature.k9.access' etc: there is no
-- POSITIVE-grant concept to add here -- the bare capability key itself
-- ('k9.access') already IS the real, existing positive grant; a second,
-- redundant 'feature.k9.access' grant would just be a confusing synonym
-- for the same fact HasPermission(citizenid, 'k9.access') already answers.
local ADMIN_CAPABILITY_BLOCKABLE_KEYS = { ['k9.access'] = true, ['k9.certify'] = true, ['k9.audit'] = true, ['k9.givexp'] = true }

--- @param value any
--- @return boolean
local function IsValidPermissionKey(value)
    if type(value) ~= 'string' or value == '' or #value > 50 then return false end

    -- feature./block. namespace -- UNCHANGED, checked first, never routed
    -- through the permission-key catalog. See this function's own doc
    -- comment above this pass's OVERLAY UPDATE note for the original,
    -- still-accurate "why" writeup.
    if type(Config.Features) == 'table' then
        local featureName = value:match('^feature%.(.+)$') or value:match('^block%.(.+)$')
        if featureName ~= nil and Config.Features[featureName] ~= nil then
            return true
        end
    end

    -- ADMIN-CAPABILITY BLOCK NAMESPACE (this pass) -- see
    -- ADMIN_CAPABILITY_BLOCKABLE_KEYS' own doc comment immediately above
    -- for the full "why only these four, why 'block.' only" writeup.
    -- Checked here, alongside (not instead of) the feature./block. branch
    -- above -- a literal 'block.k9.access' can never collide with that
    -- branch since 'k9.access' is never a Config.Features key.
    do
        local capabilityName = value:match('^block%.(k9%..+)$')
        if capabilityName ~= nil and ADMIN_CAPABILITY_BLOCKABLE_KEYS[capabilityName] == true then
            return true
        end
    end

    -- PERMISSION-KEY CATALOG (soft dependency -- server/permissionkeycatalog.lua).
    -- OVERLAYS Config.Permissions: when that file is loaded, its own merged
    -- catalog (Config.Permissions defaults + DB overrides/additions, minus
    -- any tombstoned key) is THE authority for this namespace -- consulting
    -- Config.Permissions directly here would let a high-command-tombstoned
    -- default key keep validating forever, and would never recognize a
    -- purely DB-added key at all.
    if type(IsKnownPermissionCatalogKey) == 'function' then
        return IsKnownPermissionCatalogKey(value)
    end

    -- FALLBACK (server/permissionkeycatalog.lua absent): the original,
    -- config-only check -- preserves this function's pre-existing behavior
    -- exactly if that file is ever removed.
    return type(Config.Permissions) == 'table' and Config.Permissions[value] ~= nil
end

--- SECURITY FIX (this pass -- "revoking a retired permission key must
--- always be possible", the same-shape bug one layer deeper than the
--- tablet-aggregation finding this pass also closes: a key nobody can even
--- SEE as held is bad; a key nobody can ever TAKE AWAY is worse). A bare
--- SHAPE check for `permissionKey` -- type/non-empty/length only, the EXACT
--- SAME numeric bound IsValidPermissionKey itself starts with (a plain
--- sanity/DoS-lite cap, not an injection backstop -- this value only ever
--- reaches a bound `?` placeholder, same reasoning as IsValidCitizenId
--- above) -- DELIBERATELY NEVER a catalog/Config.Permissions MEMBERSHIP
--- check. RevokePermission below is this function's ONLY caller.
---
--- THE BUG THIS REPLACES: RevokePermission used to call the same
--- IsValidPermissionKey gate GrantPermission calls. That gate is correct
--- for GRANT (nobody should be able to grant a key that does not currently
--- exist) and WRONG for REVOKE (a key server/permissionkeycatalog.lua has
--- tombstoned is, by that file's own design, EXCLUDED from
--- IsKnownPermissionCatalogKey/IsValidPermissionKey -- see that file's own
--- header "TOMBSTONE, NOT REFERENCE-COUNTED" -- so the old check refused
--- 'invalid_permission' for EVERY revoke of a retired key, forever, with no
--- other path to remove it: high command retires a key, and anyone still
--- holding a grant of it keeps it PERMANENTLY, through every surface,
--- including the tablet's own "retired, revoke-only" row that exists
--- SPECIFICALLY for this case (html/tablet.js's own resolveCapabilityRows
--- third bucket) -- a button that rendered and always failed server-side.
---
--- WHY THIS IS SAFE WITHOUT THE CATALOG CHECK: revoking is the inherently
--- SAFE direction (it only ever narrows access, never widens it), and this
--- function is followed immediately by RevokePermission's own real
--- authority check -- does this EXACT (citizenid, permissionKey) pair have
--- a currently-ACTIVE row at all (K9Store.Perm_RevokeActive's own
--- affectedRows, reported as the 'not_granted' outcome below when it is
--- zero). That is the correct "membership" test for a revoke: not "is this
--- key still creatable", but "does this citizenid actually hold it right
--- now" -- a garbage/never-existed/already-tombstoned-and-never-granted key
--- reaches that exact same, already-safe 'not_granted' outcome through the
--- normal no-rows-affected path, never a false "revoked" success and never
--- a SQL concern (parameterized regardless of this function's own answer).
---
--- HasPermission's OWN posture is UNCHANGED and confirmed still correct: it
--- still calls the real, catalog-aware IsValidPermissionKey (not this
--- function), so a tombstoned key's still-active row confers NOTHING while
--- it sits there waiting to be revoked -- "grantable-in-the-database-but-
--- inert" is exactly the intended state a tombstoned-but-held key is in,
--- and this function's own narrower shape check does not, and must not,
--- change that.
--- @param value any
--- @return boolean
local function IsPlausiblePermissionKeyShape(value)
    return type(value) == 'string' and value ~= '' and #value <= 50
end

--- OWNER DECISION (this pass) -- see this file's header "SELF-GRANT"
--- section for the full writeup. Reads config.lua's
--- Config.FeatureControl.allowHighCommandSelfGrant, defaulting to `true`
--- when the flag or its containing table is absent/malformed -- NEVER
--- `x or default`, which would be indistinguishable from an explicit
--- `false`; this checks `~= false` explicitly so only a deliberate operator
--- opt-out ever restores the stricter, pre-widening behavior. Called ONLY
--- from GrantPermission's self-grant branch, for EVERY permission
--- namespace this file validates (the four named capabilities,
--- 'block.<Name>', and 'feature.<Name>' alike -- widened this pass from
--- 'feature.<Name>' only) -- this function deliberately knows nothing
--- about which permission key is involved, since the owner's own decision
--- applies uniformly rather than per namespace.
--- @return boolean
local function HighCommandSelfGrantAllowed()
    local featureControl = Config.FeatureControl
    if type(featureControl) ~= 'table' then return true end
    return featureControl.allowHighCommandSelfGrant ~= false
end

--- Returns true if `err` (the value pcall caught around the grant INSERT)
--- represents a MySQL/MariaDB duplicate-key error (1062) on
--- `uq_one_active_permission_per_citizen`. Same shape-agnostic detection as
--- server/certifications/'s own IsDuplicateKeyError (duplicated here
--- rather than shared, matching this resource's own established "each file
--- keeps its own tiny copy of a genuinely small, self-contained check"
--- convention -- see server/highcommand.lua's IsValidPositiveFiniteNumber
--- doc comment for the same reasoning applied to a different check).
--- @param err any
--- @return boolean
local function IsDuplicateKeyError(err)
    if type(err) == 'table' then
        if err.errno == 1062 or err.code == 1062 then return true end
        local message = err.message or err.sqlMessage
        if type(message) == 'string' and (message:find('1062', 1, true) or message:find('ER_DUP_ENTRY', 1, true)) then
            return true
        end
    elseif type(err) == 'string' then
        if err:find('1062', 1, true) or err:find('ER_DUP_ENTRY', 1, true) or err:find('Duplicate entry', 1, true) then
            return true
        end
    end
    return false
end

--- Console log line for EVERY GrantPermission/RevokePermission invocation --
--- allowed, denied, rate-limited, or malformed. Matches
--- server/admin.lua's own LogAuditInvocation "%s ran %s(%s) -> %s" format
--- EXACTLY (this task's explicit instruction).
--- @param granterSrc number
--- @param action string -- 'grantPermission' | 'revokePermission'
--- @param detail string
--- @param outcome string
local function LogAuditInvocation(granterSrc, action, detail, outcome)
    local granterPlayer = exports.qbx_core:GetPlayer(granterSrc)
    local granterCitizenid = granterPlayer and granterPlayer.PlayerData and granterPlayer.PlayerData.citizenid
    local whoLabel = granterCitizenid and ('citizenid=' .. granterCitizenid) or ('unresolved-source=' .. tostring(granterSrc))
    print(('[John-K9] AUDIT: %s ran %s(%s) -> %s'):format(whoLabel, action, detail, outcome))
end

-- COULD-NOT-DETERMINE HANDLING (lifecycle QA pass, this pass) -- mirrors
-- server/certifications/'s RefreshCertificationCache fix of the
-- identical class of bug (a transient query failure recorded as a
-- confirmed answer instead of "we don't know"), applied here to
-- PermissionCache. See RefreshPermissionCache's own doc comment below for
-- the full contract.
local PERM_REFRESH_RETRY_ATTEMPTS = 3
local PERM_REFRESH_RETRY_BACKOFF_MS = 200

-- PermissionCheckUnresolved[citizenid] = true once RefreshPermissionCache
-- exhausts its own retry budget with no confirmed answer either way.
-- Purely a bookkeeping flag for the operator-facing message and the resync
-- sweep below -- never read by HasPermission/GetActiveBlockedFeatureNames/
-- any other access-relevant function, and never merged into
-- PermissionCache itself. Local: nothing outside this file needs it.
local PermissionCheckUnresolved = {}

--- Runs `fn()` up to `attempts` times, waiting `backoffMs * attemptNumber`
--- between tries -- identical shape and reasoning to
--- server/certifications/'s own PcallWithBoundedRetry, duplicated here
--- rather than shared, matching this resource's own established "each file
--- keeps its own tiny copy of a genuinely small, self-contained helper"
--- convention (see e.g. that file's own IsDuplicateKeyError, already
--- independently re-implemented in THIS file above for the same reason).
--- @param fn function
--- @param attempts number
--- @param backoffMs number
--- @return boolean ok
--- @return any resultOrErr
---
--- `coroutine.isyieldable()` GUARD -- see server/certifications/'s own
--- identical guard on its own PcallWithBoundedRetry for the full "why":
--- every real call site here runs inside an FXServer-managed coroutine
--- (event handler, command handler, this file's own resync sweep), where
--- `Wait()` is always safe -- this guard exists so the function is ALSO
--- safe to call directly from a plain, non-coroutine Lua call (this
--- resource's own test suite calls RefreshPermissionCache this way
--- throughout tests/permissions_spec.lua), where `Wait()` -> `coroutine.
--- yield()` would otherwise error outright.
local function PcallWithBoundedRetry(fn, attempts, backoffMs)
    local ok, result
    for attempt = 1, attempts do
        ok, result = pcall(fn)
        if ok then return ok, result end
        if attempt < attempts and coroutine.isyieldable() then
            Wait(backoffMs * attempt)
        end
    end
    return ok, result
end

--- Re-queries every ACTIVE permission row for `citizenid` and replaces its
--- cache entry wholesale.
---
--- COULD-NOT-DETERMINE (lifecycle QA pass): a bounded-retry-wrapped read
--- failure is NOT the same fact as a confirmed "holds nothing" answer, and
--- this function no longer conflates the two the way it used to (a
--- single-attempt `pcall` that wrote `PermissionCache[citizenid] = {}` on
--- ANY failure -- a timeout, a dropped connection, a busy pool -- collapsing
--- "confirmed zero grants" and "could not check" into the identical cache
--- state). On total failure: if a previous cache entry already exists for
--- this citizenid (a real risk here specifically, since unlike a fresh
--- login this function is also called again mid-session by Grant/
--- RevokePermission's own RefreshPermissionCacheIfOnline after an already-
--- warmed citizenid's grant/revoke), it is KEPT, unchanged -- never wiped
--- back to empty. If no previous entry exists (the common case: this
--- citizenid's first warm this session, at PlayerLoaded or the
--- onResourceStart backfill, both of which start from an empty
--- PermissionCache table), the entry is left COMPLETELY UNSET rather than
--- written as `{}` -- HasPermission's own `set ~= nil and set[key] ==
--- true` read already treats an absent entry exactly like an empty one for
--- every question it is ever asked (deny, matching this resource's own
--- "nobody may end up with MORE access than a working database would give
--- them" invariant -- unaffected by this change), but leaving it
--- genuinely unset (rather than a manufactured empty table) means a later
--- successful retry, a reconnect, or the bounded resync sweep below can
--- still establish the real grant set without that distinction having
--- already been erased.
--- @param citizenid string
local function RefreshPermissionCache(citizenid)
    local ok, rowsOrErr = PcallWithBoundedRetry(
        function() return K9Store.Perm_GetActiveForCitizen(citizenid) end,
        PERM_REFRESH_RETRY_ATTEMPTS, PERM_REFRESH_RETRY_BACKOFF_MS
    )

    if not ok then
        local previous = PermissionCache[citizenid]
        PermissionCheckUnresolved[citizenid] = true

        if previous ~= nil then
            print((
                '[John-K9] permissions.lua PERMISSION CHECK FAILED for citizenid=%s after %d attempt(s): %s ' ..
                '-- this is NOT a confirmed "holds nothing" answer. KEEPING the previous cached grant set ' ..
                'rather than wiping it to empty. A bounded resync sweep will keep retrying this citizenid ' ..
                'automatically; if this message repeats for the same citizenid, check the database connection.'
            ):format(citizenid, PERM_REFRESH_RETRY_ATTEMPTS, tostring(rowsOrErr)))
            return
        end

        print((
            '[John-K9] permissions.lua PERMISSION CHECK FAILED for citizenid=%s after %d attempt(s): %s -- ' ..
            'this is an UNKNOWN answer, NOT a confirmed "holds nothing" one. No previous cached grant set ' ..
            'exists, so nothing is being written to the cache (left UNSET, never a manufactured empty table). ' ..
            'HasPermission will deny every permission for this citizenid until this resolves, exactly as it ' ..
            'would for a real "no grants" answer -- but the operator should know this citizenid may in fact ' ..
            'HOLD active grants right now and the server simply could not confirm it yet. A bounded resync ' ..
            'sweep will keep retrying automatically.'
        ):format(citizenid, PERM_REFRESH_RETRY_ATTEMPTS, tostring(rowsOrErr)))
        return
    end

    PermissionCheckUnresolved[citizenid] = nil
    local set = {}
    for _, row in ipairs(rowsOrErr or {}) do
        set[row.permission] = true
    end
    PermissionCache[citizenid] = set
end

--- Refreshes `citizenid`'s cache entry ONLY if they are currently online --
--- see this file's header "CACHING" / "SCOPE" section for why an offline
--- citizenid deliberately gets no cache entry at all.
--- @param citizenid string
local function RefreshPermissionCacheIfOnline(citizenid)
    local onlinePlayer = exports.qbx_core:GetPlayerByCitizenId(citizenid)
    if onlinePlayer and onlinePlayer.PlayerData and onlinePlayer.PlayerData.source then
        RefreshPermissionCache(citizenid)
    end
end

-- ======================================================================
-- FEATURE-BLOCK PUSH (this pass) -- closes the drift-guard finding that
-- client/featureblocks.lua registers RegisterNetEvent('john-k9:client:
-- featureBlocksSync', ...) but no server file ever fired it, so the twelve
-- purely client-rendered features that file exists to gate (RadialMenu,
-- VehicleEntryExit, AgilityBasicJump, AgilityAdvanced, ThermalVision,
-- NightVision, HealthStaminaHUD, ContrabandScreenFX, AdvancedBarkRadial,
-- ProximityAudioFX, WaterTrackingDecay, CameraFeedPiP) could never actually
-- be told they were blocked -- the tablet would report a successful block
-- that silently did nothing. See this file's own header "TABLET NETWORK
-- CONTRACT" section neighbourhood for the other server-side contracts this
-- mirrors; this section is deliberately self-contained instead, since it is
-- infrastructure server/tablet.lua's tabletBlockFeature/tabletUnblockFeature
-- reach only indirectly (through the SAME GrantPermission/RevokePermission
-- calls every other permission namespace already goes through -- see
-- IsValidPermissionKey's own 'block.<Name>' branch above).
-- ======================================================================

--- Every active `block.<Name>` row currently cached for `citizenid`, as a
--- bare array of `Name` strings (the `block.` prefix stripped -- never sent
--- over the wire, since client/featureblocks.lua's own
--- CLIENT_ENFORCED_FEATURES allowlist is keyed by the bare name, e.g.
--- `NightVision`, never `block.NightVision`).
---
--- DELIBERATELY NOT filtered down to the twelve client-only names here:
--- this returns every `block.<Name>` row that exists at all, covering both
--- the twelve client-only features AND the twenty-nine server-enforced ones
--- this file's own header describes elsewhere -- client/featureblocks.lua's
--- own CLIENT_ENFORCED_FEATURES table already does that filtering safely,
--- client-side, dropping anything it does not recognise (see that file's
--- own comment on it); duplicating that exact twelve-name list here would
--- be a second copy this file has no way to keep in sync with a future
--- change to a file this pass does not own.
---
--- Reads ONLY the already-warmed PermissionCache -- never a fresh DB query
--- of its own -- so this is a synchronous, zero-cost, in-memory read every
--- time, safe to call from a hot grant/revoke path as well as the bulk
--- PlayerLoaded/onResourceStart warm paths below. Returns an empty table
--- (never nil, never throws) when Config.Features.PermissionGrants is off
--- or `citizenid` has no cache entry at all (not yet warmed, or genuinely
--- holds zero active permissions) -- FAILS OPEN, matching HasPermission's
--- own "feature off means nothing is granted" posture and
--- client/featureblocks.lua's own documented "unknown means allowed"
--- contract: an empty array pushed to a client clears every block it may
--- have been holding, never invents one that is not real.
--- @param citizenid string
--- @return string[] blockedFeatureNames
local function GetActiveBlockedFeatureNames(citizenid)
    if not (Config.Features and Config.Features.PermissionGrants == true) then return {} end
    local set = PermissionCache[citizenid]
    if not set then return {} end
    local names = {}
    for key, active in pairs(set) do
        if active == true then
            local featureName = key:match('^block%.(.+)$')
            if featureName then
                names[#names + 1] = featureName
            end
        end
    end
    return names
end

--- Pushes `citizenid`'s CURRENT, COMPLETE block set to THEIR OWN live
--- client only -- NEVER a broadcast (`TriggerClientEvent(-1, ...)`), per
--- this task's own explicit "send that one player their own block set, not
--- everyone's" requirement. `targetSrc` is always a specific, already-
--- resolved server id this file itself resolved (GetPlayerByCitizenId for
--- the grant/revoke/PlayerLoaded paths, GetPlayers' own per-connection loop
--- for the onResourceStart backfill) -- never a client-supplied value at
--- any call site below. A silent no-op (never throws) when `targetSrc` is
--- not currently a number -- covers every caller that resolves an
--- online-target lookup which came back nil (target is offline; there is
--- no live client to push to, and nothing to clean up either, since an
--- offline citizenid has no cache entry per RefreshPermissionCacheIfOnline's
--- own SCOPE).
--- @param targetSrc number?
--- @param citizenid string
local function PushFeatureBlocksToSource(targetSrc, citizenid)
    if type(targetSrc) ~= 'number' then return end
    TriggerClientEvent('john-k9:client:featureBlocksSync', targetSrc, GetActiveBlockedFeatureNames(citizenid))
end

--- Re-checks a SPECIFIC (citizenid, permission) row's `active` column
--- directly against the DB, independent of RefreshPermissionCache's own
--- collapsed fail-closed return -- same reasoning as
--- server/certifications/'s IsCertRowConfirmedActive: RevokePermission
--- needs to tell "the UPDATE genuinely never committed" apart from
--- "unreadable, true outcome unknown" before deciding whether to report
--- success.
--- @param citizenid string
--- @param permissionKey string
--- @return boolean? active -- true/false if confirmed against the DB, nil if the read itself failed
local function IsPermissionRowConfirmedActive(citizenid, permissionKey)
    local ok, activeIdOrErr = pcall(K9Store.Perm_GetActiveId, citizenid, permissionKey)
    if not ok then
        print(('[John-K9] permissions.lua row-reconciliation read failed for %s/%s: %s'):format(citizenid, permissionKey, tostring(activeIdOrErr)))
        return nil
    end
    return activeIdOrErr ~= nil
end

--- Server-authoritative check: is `source` currently allowed to grant/revoke
--- given the LEGACY (high-command-or-rank) rules that would apply to
--- `permissionKey`'s own capability, WITHOUT consulting any permission
--- grant at all -- used ONLY by RevokePermission's post-revoke
--- reconciliation (see this file's header "THE REVOKED BUT STILL HAS IT BY
--- RANK CASE"). Deliberately duplicates the certifierGrade/auditGrade
--- comparison SHAPE already established in server/certifications/'s
--- IsEligibleCertifier and server/admin.lua's IsAuthorizedAdmin, rather
--- than exporting either of those (both `local`, both in files this task
--- says to edit surgically, not to widen) as new resource-globals purely
--- for this one reconciliation read -- see header for the full reasoning.
--- Fails CLOSED on every unresolvable shape, identical to every other rank
--- gate in this resource: no Player, no job, job.name not a configured
--- department, no numeric grade field for this department, no job.grade,
--- or a non-number job.grade.level all return false; `job.isboss` and
--- IsHighCommand both still short-circuit true, matching every other gate.
--- @param source number
--- @param gradeField string -- 'certifierGrade' | 'auditGrade'
--- @return boolean
local function MeetsDepartmentGradeOrHighCommand(source, gradeField)
    local Player = exports.qbx_core:GetPlayer(source)
    if not Player or not Player.PlayerData then return false end

    local job = Player.PlayerData.job
    if not job or type(Config.Departments) ~= 'table' or not Config.Departments[job.name] then return false end

    if job.isboss then return true end
    if type(IsHighCommand) == 'function' and IsHighCommand(source) then return true end

    local dept = Config.Departments[job.name]
    if type(dept[gradeField]) ~= 'number' then return false end

    return job.grade ~= nil and type(job.grade.level) == 'number' and job.grade.level >= dept[gradeField]
end

--- Dispatches to the right "steps 2+3 only" check for `permissionKey`. See
--- MeetsDepartmentGradeOrHighCommand's own doc comment above for why this
--- is a small local duplicate rather than a call into another file's
--- `local` function. 'k9.access' reuses the real, already-global
--- HasK9Access directly -- safe here specifically because
--- RevokePermission always calls RefreshPermissionCache BEFORE this,
--- so HasK9Access's own step-1 permission read is already correctly false
--- for the grant just revoked (see header for why this cannot double-count).
--- 'k9.givexp' has no legacy tier below high command at all, per
--- config.lua's Config.Permissions catalog -- IsHighCommand alone is
--- steps 2+3 collapsed into one for that capability.
--- @param source number
--- @param permissionKey string
--- @return boolean
local function LegacyOrHighCommandStillQualifies(source, permissionKey)
    if permissionKey == 'k9.access' then
        return type(HasK9Access) == 'function' and HasK9Access(source)
    elseif permissionKey == 'k9.certify' then
        return MeetsDepartmentGradeOrHighCommand(source, 'certifierGrade')
    elseif permissionKey == 'k9.audit' then
        return MeetsDepartmentGradeOrHighCommand(source, 'auditGrade')
    elseif permissionKey == 'k9.givexp' then
        return type(IsHighCommand) == 'function' and IsHighCommand(source)
    end
    -- Every 'feature.<Name>'/'block.<Name>' key (config.lua's Config.FeatureControl
    -- -- IsValidPermissionKey accepts these too, this pass) falls through to
    -- here, and CORRECTLY so, not merely as a leftover fail-closed default:
    -- there is no "legacy rank tier" equivalent for a per-feature grant/block
    -- the way k9.access/k9.certify/k9.audit each have one -- the ONLY way a
    -- citizenid ever holds 'feature.<Name>' is through step 1 (an explicit
    -- grant via this same file), so once THAT grant is revoked there is
    -- nothing else left to "still qualify" via. Returning false here means
    -- RevokePermission's own stillHasAccess correctly reports `nil` (fully
    -- removed) for a feature/block revoke, never a bogus
    -- 'rank_or_high_command' this function has no real basis to claim.
    return false
end

--- Human-readable label for a NotifyPlayer'd grant/revoke, covering BOTH
--- permission namespaces this file accepts (IsValidPermissionKey above):
--- the permission-key catalog's own live label (server/permissionkeycatalog.lua's
--- GetPermissionCatalogLabel -- OVERLAYS Config.Permissions[key].label the
--- same way IsValidPermissionKey now does, this pass, so a high-command
--- RELABEL of a key is reflected here too, not just at validation time) for
--- the admin-capability namespace, falling back to
--- Config.Permissions[key].label directly if that file is absent, and a
--- plain fallback to the raw key itself for 'feature.<Name>'/'block.<Name>'
--- -- config.lua's Config.FeatureControl has no per-feature human label the
--- way Config.Permissions does (RequireGrant is a bare `{ Name = true }`
--- table), so 'feature.BiteAndHold'/'block.BiteAndHold' is the label; still
--- meaningfully readable by an officer, and never a crash from indexing
--- `.label` off a Config.Permissions entry that does not exist for this
--- namespace. Called ONLY after IsValidPermissionKey has already confirmed
--- `permissionKey` is one of the two accepted shapes -- never on an
--- arbitrary string.
--- @param permissionKey string
--- @return string
local function PermissionLabelFor(permissionKey)
    if type(GetPermissionCatalogLabel) == 'function' then
        local catalogLabel = GetPermissionCatalogLabel(permissionKey)
        if type(catalogLabel) == 'string' then
            return catalogLabel
        end
    end

    local def = type(Config.Permissions) == 'table' and Config.Permissions[permissionKey]
    if def and type(def.label) == 'string' then
        return def.label
    end
    return permissionKey
end

--- OWNER-DIRECTED, this pass ("high command should automatically get every
--- permission, every feature, every k9 upgrade -- not have to be granted
--- things one by one"). Resolves a CITIZENID (not a live `source`) to "is
--- this person high command RIGHT NOW" -- the missing piece every
--- 'feature.<Name>' consumer needs, since (unlike the four admin-capability
--- keys -- k9.access/certify/audit/givexp, whose own consuming gates already
--- take a live `source` and can call server/highcommand.lua's
--- IsHighCommand(source) directly, see this file's own header "HOW STEP 1 IS
--- WIRED IN") every 'feature.<Name>'/'block.<Name>' consumer in this
--- resource (server/search.lua, server/tracking.lua, server/combat.lua, and
--- roughly twenty more, all sharing the identical
--- `HasPermission(citizenid, 'feature.' .. Name)` shape) only ever has a
--- CITIZENID on hand, never a `source`.
---
--- OFFLINE CITIZENID: returns `false`, UNCONDITIONALLY, deliberately -- this
--- is NOT "assume not high command", it is "cannot know, so answer as if
--- not" -- the exact same choice this file's own header "THE REVOKED BUT
--- STILL HAS IT BY RANK CASE" already makes for the identical question
--- ("their live job cannot be read at all... there is no secondary source
--- of truth this file queries for an offline citizenid's current job"), and
--- the exact same choice server/tablet.lua's own ResolveTargetHasK9Access
--- documents for its own offline branch ("the offline fallback deliberately
--- does NOT attempt to reconstruct autoAccessGrade/high-command bypass
--- eligibility -- both are inherently properties of a LIVE job, which a
--- disconnected citizenid does not have one of right now"). SAFE, not merely
--- consistent: every consumer of this function only ever WIDENS access for a
--- citizenid this returns `true` for -- answering `false` for an offline
--- citizenid can only ever under-grant relative to what they would get the
--- moment they reconnect while genuinely high command, never over-grant.
--- Nobody's effective access DEPENDS on this returning true while offline --
--- grep confirms every real caller (this file's own HasPermission,
--- server/certtiers.lua's TierCapabilityPermits, server/certifications/'s
--- HasSpecialization, server/progression.lua's cooldown-multiplier family)
--- is itself only ever reached from a live, in-session action gate.
---
--- NEVER CACHED -- re-resolved fresh on every call, matching
--- server/highcommand.lua's own IsHighCommand (re-checks
--- Config.Features.HighCommand and the caller's live job on every
--- invocation, "so flipping the flag off must genuinely turn every bypass
--- back off too, immediately, with no restart required") and this
--- resource's blanket "never cache a live rank/authorization decision"
--- convention -- a citizenid demoted or promoted mid-session is reflected on
--- their VERY NEXT call, with no stale entry to invalidate. Costs one
--- `exports.qbx_core:GetPlayerByCitizenId` lookup (an in-process, O(1)
--- table read this resource already pays at dozens of other call sites
--- every time it needs an online player's row from a citizenid -- never a
--- network hop or a query) plus IsHighCommand's own existing
--- `exports.qbx_core:GetPlayer(source)` lookup and live job/grade
--- comparison -- no new I/O class, only ever paid when `citizenid` is
--- currently online, and only ever paid AFTER an ordinary cache-hit check
--- has already failed at each of this function's own call sites (see e.g.
--- HasPermission below, which only reaches this once the plain grant-cache
--- read has already come back false).
---
--- @param citizenid any
--- @param expectedJobName string? -- OPTIONAL. When given, additionally
---   requires the online player's OWN CURRENT `job.name` to equal this
---   value before consulting IsHighCommand at all -- so a caller evaluating
---   a specific job's own tier/specialization/certification state (server/
---   certtiers.lua's TierCapabilityPermits, server/certifications/'s
---   HasSpecialization, both of which already take a `jobName` argument for
---   exactly this reason) can never have a citizenid's high-command status
---   in some OTHER, unrelated department bleed into a check scoped to THIS
---   one. Omitted by every 'feature.<Name>' caller below, which has no job
---   parameter of its own to cross-check against -- IsHighCommand(source)
---   already independently requires the player's own live job to be a
---   Config.Departments member with a satisfied highCommandGrade, so no
---   further scoping is needed there.
--- @return boolean
function IsHighCommandBypassCitizenId(citizenid, expectedJobName)
    if type(citizenid) ~= 'string' or citizenid == '' then return false end
    if type(IsHighCommand) ~= 'function' then return false end
    if type(exports) ~= 'table' or type(exports.qbx_core) ~= 'table' then return false end

    local ok, player = pcall(exports.qbx_core.GetPlayerByCitizenId, exports.qbx_core, citizenid)
    if not ok or type(player) ~= 'table' or type(player.PlayerData) ~= 'table' then return false end

    if expectedJobName ~= nil then
        local job = player.PlayerData.job
        if type(job) ~= 'table' or job.name ~= expectedJobName then return false end
    end

    local source = player.PlayerData.source
    if type(source) ~= 'number' then return false end

    return IsHighCommand(source) == true
end

-- ======================================================================
-- STEP 1 OF THE RESOLUTION ORDER -- the hot-path check every OTHER gate in
-- this resource consults. See this file's header "CACHING" section for the
-- exact staleness window.
-- ======================================================================

--- Server-authoritative: does `citizenid` currently hold an ACTIVE grant of
--- `permissionKey`? THIS IS STEP 1 ONLY for the four admin-capability keys
--- ('k9.access'/'k9.certify'/'k9.audit'/'k9.givexp') and every custom
--- 'k9.<word>' capability key -- it does not consult high command or any
--- rank gate for THOSE; callers that want the full 4-step resolution order
--- call this FIRST, then fall through to their own existing high-command/
--- rank checks (see header "HOW STEP 1 IS WIRED IN").
---
--- OWNER-DIRECTED EXCEPTION, this pass, 'feature.<Name>' ONLY (never
--- 'block.<Name>', never any 'k9.<word>' key): ALSO returns `true` when no
--- literal grant exists but `citizenid` is CURRENTLY ONLINE and high
--- command right now (IsHighCommandBypassCitizenId below) -- "high command
--- automatically gets every feature" was an explicit, separate ask from the
--- admin-capability keys above, and 'feature.<Name>' has no consuming-gate
--- call site of its own to attach a bypass to the way the four keys above
--- do (server/search.lua and roughly twenty siblings all resolve
--- 'feature.<Name>' through THIS function alone) -- see the bypass's own
--- branch, right before this function's final `return false`, for the full
--- reasoning on why this is the one and only place it needed to go.
---
--- Re-checks Config.Features.PermissionGrants on EVERY call (never cached),
--- matching server/highcommand.lua's IsHighCommand -- see header for why.
--- Fails CLOSED on every unresolvable shape: feature off, a non-string/
--- empty citizenid, or a permissionKey not in Config.Permissions.
---
--- MEMORY-MODE BLOCK ASYMMETRY (security pass, this pass -- closes a gap
--- made materially more reachable by server/datastore.lua's own per-table
--- fallback: a missing `k9_permissions` table used to take the WHOLE
--- resource to memory mode, an obviously-degraded state; now it can be the
--- ONLY table affected while everything else looks completely normal).
---
--- THE BUG: `PermissionCache[citizenid]` is built from
--- `K9Store.Perm_GetActiveForCitizen`, which reads `k9_permissions`'
--- memory-mode mirror (`PermRows`, server/datastore.lua) whenever that
--- table is not database-backed this session. `PermRows` ALWAYS starts
--- completely empty on a fresh boot (server/datastore.lua's own
--- "FAIL-CLOSED, BY CONSTRUCTION" header) -- a real, un-erroring, `ok =
--- true` read of a store that structurally cannot contain a row nobody has
--- re-granted THIS session, not a query failure RefreshPermissionCache's
--- own bounded-retry/"leave unset" handling (above) was ever built to
--- catch. For every OTHER permission namespace ('k9.access'/'k9.certify'/
--- 'k9.audit'/'k9.givexp'/'feature.<Name>') that empty answer fails SAFE:
--- an absent POSITIVE grant reads as `false`, exactly the deny a working
--- database would also give a citizenid nobody (re-)granted yet this
--- session -- ordinary, honest data loss, never more access than before.
--- For `block.<Name>` it fails OPEN instead, because a block is a NEGATIVE
--- grant: a real, still-active block row sitting in a database this table
--- simply cannot reach right now reads back as absent -- indistinguishable
--- from "never blocked" -- which un-blocks, this session, a specific
--- person a human admin deliberately restricted. That is exactly what
--- config.lua's own invariant on this feature forbids ("nobody ever ends
--- up with MORE access than they would have on a database-backed server"),
--- and it is worse than an ordinary lost grant precisely because it is
--- silent and targeted rather than an obvious, blanket "everyone looks
--- decertified" failure.
---
--- WHY THE FIX GOES THE OPPOSITE DIRECTION FROM RefreshPermissionCache's
--- OWN "COULD NOT DETERMINE -> KEEP/LEAVE UNSET" POLICY ABOVE, DELIBERATELY:
--- that policy exists so a transient read failure never LOSES a positive
--- grant someone already had -- "could not confirm" defers to whatever
--- access was already established, because the harm to guard against is
--- losing access you earned. Here the harm runs the other way: "could not
--- confirm" must deny, because the harm to guard against is GAINING access
--- someone else took away. Same file, same "could not determine" shape,
--- opposite resolution -- because a positive grant and a block are opposite
--- questions, and only one direction is safe for each.
---
--- THE FIX: for the 'block.<Name>' namespace ONLY, checked BEFORE the
--- ordinary cache read below, an absent answer is never trusted while
--- `k9_permissions` itself is not database-backed this session
--- (`K9Store.IsDatabaseEnabled('k9_permissions')` -- false whether by
--- Config.Database.enabled = false, this table's own PART-INSTALLED
--- fallback, or a whole-resource schema collision; all three route through
--- that one function, see its own header) -- HasPermission reports the
--- feature BLOCKED, unconditionally, for EVERY citizenid, until the table
--- is restored and this resource restarts. This denies the (finite, named)
--- list of block-gated features to everyone rather than risk handing even
--- one of them back to someone specifically restricted from it -- exactly
--- mirroring how a feature listed in Config.FeatureControl.RequireGrant
--- already, correctly, denies everyone the moment its own positive grant
--- cannot be confirmed (see that config block's own neighbouring check,
--- unaffected by and untouched by this fix, since an absent POSITIVE grant
--- already failed closed before this pass). Every OTHER permission
--- namespace ('k9.access'/'k9.certify'/'k9.audit'/'k9.givexp'/
--- 'feature.<Name>') is completely unaffected -- an ordinary citizenid's
--- own certification, admin capabilities and positive feature grants are
--- untouched by this branch, which matches only the literal `'block.'`
--- prefix. The operator is warned about this loudly, once, from within this
--- file's own pre-existing `onResourceStart` backfill-loop handler below
--- ("BLOCK STATE CANNOT BE VERIFIED" section, folded into that handler
--- rather than a new one of its own -- see that section's own comment for
--- why) -- never repeated on this hot path.
--- @param citizenid string
--- @param permissionKey string
--- @return boolean
function HasPermission(citizenid, permissionKey)
    if not (Config.Features and Config.Features.PermissionGrants == true) then return false end
    if type(citizenid) ~= 'string' or citizenid == '' then return false end
    if not IsValidPermissionKey(permissionKey) then return false end

    -- BLOCKS FAIL CLOSED, ON BOTH WAYS OF NOT KNOWING.
    --
    -- Losing a positive grant fails safe -- someone loses access they had.
    -- Losing a NEGATIVE grant fails OPEN -- someone an admin specifically
    -- barred gets it back, silently, while everything else looks healthy.
    -- So for the block namespace only, "cannot tell" must mean "blocked".
    --
    -- There are TWO distinct ways of not knowing, and only the first used
    -- to be covered:
    --   1. The table is memory-only for this whole session -- database off,
    --      per-table fallback, or a schema collision. Decided once at boot.
    --   2. The table is genuinely database-backed and healthy, but THIS
    --      citizenid's own read failed transiently -- a dropped connection,
    --      a busy pool -- and nothing was ever cached for them. Someone
    --      connecting during a brief outage lands here.
    -- Case 2 fell through to the ordinary cache-miss path below and
    -- returned false: a real, still-active block silently stopped applying
    -- for the length of the outage. A regression pass reproduced it by
    -- granting a block, disconnecting to clear the warm entry, then
    -- reconnecting with the query throwing.
    --
    -- RefreshPermissionCache already tracks case 2 -- it deliberately
    -- leaves the entry unset rather than manufacturing an empty one, and
    -- records the citizenid in PermissionCheckUnresolved. That record is
    -- exactly the signal needed here, and the self-heal sweep clears it as
    -- soon as a real answer arrives, so this denial is never permanent.
    --
    -- Deliberately the OPPOSITE direction to the certification cache, which
    -- preserves prior state when it cannot check. That looks inconsistent
    -- and is not: there, the harm is losing access you earned; here, the
    -- harm is regaining access someone took away.
    --
    -- CASE 0 -- DELIBERATE MEMORY-ONLY MODE IS NOT "CANNOT VERIFY"
    -- (live production bug, owner report: a rank-8 police officer told
    -- "You are not authorized to certify K9 handlers" on a stock install).
    -- Config.Database.enabled = false is the SHIPPED DEFAULT, and it used
    -- to route into case 1 below alongside a genuine schema collision,
    -- because all three causes share one accessor (IsDatabaseEnabled). The
    -- consequence: `block.k9.access` and `block.k9.certify` came back TRUE
    -- for EVERY player, so HasK9Access and IsEligibleCertifier were false
    -- for everyone, and a default install could never certify its first
    -- K9 -- not even a High Command officer certifying themselves. The
    -- whole resource was dead out of the box.
    --
    -- The fail-closed rule is right; the input to it was wrong. "Could not
    -- confirm" is the condition, and deliberate memory mode is not it: the
    -- in-memory store IS the authoritative store for this session, every
    -- block granted in it reads back perfectly through the ordinary cache
    -- path below, and nothing survived from a previous session because the
    -- operator explicitly asked for that. There is no unread block row to
    -- be wrong about. Cases 1 and 2 below are untouched and still fail
    -- closed -- those are the ones where the operator DOES expect
    -- persistence and we genuinely cannot read it.
    --
    -- Guarded with `type(...) == 'function'`, this resource's
    -- soft-dependency convention: if server/datastore.lua ever stops
    -- exposing IsDatabaseConfiguredOff, this reads as `false` and the
    -- strict pre-fix behavior returns -- never the other way around.
    local deliberateMemoryMode = type(K9Store) == 'table'
        and type(K9Store.IsDatabaseConfiguredOff) == 'function'
        and K9Store.IsDatabaseConfiguredOff() == true

    if permissionKey:match('^block%.') and type(K9Store) == 'table' and not deliberateMemoryMode then
        local dbAccessorAvailable = type(K9Store.IsDatabaseEnabled) == 'function'
        if dbAccessorAvailable and not K9Store.IsDatabaseEnabled('k9_permissions') then
            return true -- case 1: the table is unreadable while persistence WAS expected (schema collision, or this table missing from an otherwise-installed database)
        end
        if PermissionCheckUnresolved[citizenid] == true and PermissionCache[citizenid] == nil then
            return true -- case 2: this citizenid's own read never resolved
        end
    end

    local set = PermissionCache[citizenid]
    if set ~= nil and set[permissionKey] == true then return true end

    -- HIGH COMMAND BYPASS (owner-directed, this pass -- "high command
    -- automatically gets every feature, not one at a time"), 'feature.<Name>'
    -- ONLY -- see IsHighCommandBypassCitizenId's own doc comment above for
    -- the full contract (offline citizenid -> false, never cached, no new
    -- I/O class). Deliberately EXCLUDED:
    --   - 'block.<Name>' -- THE ONE THING THE PROJECT OWNER WILL NOT ACCEPT
    --     LOSING. A block is a decision to restrain ONE specific person,
    --     including a high-command one -- see this file's own "MEMORY-MODE
    --     BLOCK ASYMMETRY" section immediately above for how seriously this
    --     file already treats a block's own fail-closed guarantee. This
    --     branch is reached only through the `permissionKey:match('^feature%.')`
    --     guard below, which a literal `'block.'` prefix can never match, so
    --     a block already wins by construction: HasPermission(citizenid,
    --     'block.X') never reaches this branch at all, and every consuming
    --     gate in this resource checks 'block.X' BEFORE 'feature.X' (see
    --     e.g. server/search.lua's IsSearchFeaturePermittedForCitizenId),
    --     so a real, active block short-circuits to `false` before this
    --     bypass could ever be consulted for the same feature.
    --   - the four admin-capability keys ('k9.access'/'k9.certify'/
    --     'k9.audit'/'k9.givexp') and every custom 'k9.<word>' capability key
    --     (server/runtimecontrol.lua's 'k9.runtimecontrol'/'k9.tablettheme',
    --     server/equipmentshop.lua's 'k9.equipmentshoplocations'/
    --     'k9.equipmentshopitems') -- every one of those already has its own
    --     high-command bypass wired at its own SOURCE-based call site (see
    --     this file's header "HOW STEP 1 IS WIRED IN"), and this function's
    --     own doc comment promises "STEP 1 ONLY -- it does not consult high
    --     command" for exactly that namespace: server/certifications/'s
    --     RevokePermission reconciliation (LegacyOrHighCommandStillQualifies
    --     above) depends on HasPermission staying a PURE grant-cache read
    --     for those keys to tell "fully revoked" apart from "still has it by
    --     rank" -- adding a second, silent bypass path here would make that
    --     reconciliation double-count and misreport.
    -- INHERITS Config.Features.HighCommand (via IsHighCommand's own internal
    -- re-check, every call, no restart needed) AND Config.Features.
    -- PermissionGrants (via this very function's own top-of-function guard,
    -- above) for free -- if the grant SYSTEM itself is off, there is no
    -- "implicit grant" for high command to stand in for either, so this
    -- bypass correctly goes dark alongside every real grant the instant
    -- PermissionGrants is disabled.
    if permissionKey:match('^feature%.') and IsHighCommandBypassCitizenId(citizenid) then
        return true
    end

    return false
end

-- ======================================================================
-- GRANT / REVOKE -- only high command may call either. See header
-- "SELF-GRANT" / "DB ERRORS" / "COOLDOWN" / "AUDIT" / "NOTIFICATIONS"
-- sections for the full contract each of these implements.
-- ======================================================================

--- Grants `permissionKey` to `targetCitizenid`. Only callable by high
--- command (re-verified here, server-side, from `granterSrc`'s OWN live
--- job -- never trusts a client claim of authority). Self-grant -- granting
--- to your OWN citizenid -- is permitted by default for EVERY permission
--- namespace this file validates (the four named capabilities
--- k9.access/k9.certify/k9.audit/k9.givexp, 'block.<Name>', and
--- 'feature.<Name>' alike), per config.lua's
--- Config.FeatureControl.allowHighCommandSelfGrant (default true, WIDENED
--- this pass from 'feature.<Name>' only) -- see this file's header
--- "SELF-GRANT" section for the owner's own decision this implements, and
--- HighCommandSelfGrantAllowed above for the exact scope (the switch, not
--- IsHighCommand, is the only thing this widens; an operator can restore
--- the stricter behavior by setting that flag to `false`).
--- Idempotent in effect: granting an already-active permission reports
--- 'already_granted' rather than creating a second row or erroring.
--- @param granterSrc number
--- @param targetCitizenid string
--- @param permissionKey string
--- @param appearanceModelOverride string? -- K9 ROLE/MODEL DECOUPLING (coder-architect, server/appearance.lua): ONLY consulted when permissionKey == 'k9.access' and Config.K9Appearance.applyPedModelOnCertify is on -- the explicit ped model server/appearance.lua's ApplyK9PedRole (the tablet's direct "apply K9" action) wants applied instead of the automatic-grant default (Config.Peds[1].model). Every OTHER caller of GrantPermission simply omits this and gets the default, exactly as before this parameter existed.
--- @return boolean ok
--- @return string outcome -- 'ok' | 'feature_disabled' | 'denied' | 'invalid_permission' | 'invalid_target' | 'invalid_granter' | 'self_grant_blocked' | 'rate_limited' | 'busy' | 'already_granted' | 'db_error'
function GrantPermission(granterSrc, targetCitizenid, permissionKey, appearanceModelOverride)
    if not (Config.Features and Config.Features.PermissionGrants == true) then
        -- SECURITY FIX (coder-security, this pass -- audit-trail completeness):
        -- every OTHER rejection below this line logs via LogAuditInvocation
        -- before returning; this branch used to be the one silent exception --
        -- an attempted grant while the feature is off (including one from a
        -- genuine, currently-authorized high-command account, e.g. while
        -- probing whether the feature is live) left NO trail at all, unlike
        -- 'denied'/'rate_limited'/every other outcome. Logged BEFORE the
        -- IsHighCommand check (which has not run yet here) using the same
        -- granterSrc-derived whoLabel LogAuditInvocation always resolves --
        -- this does not require or imply the caller is authorized, exactly
        -- like the 'denied' log line just below does not.
        LogAuditInvocation(granterSrc, 'grantPermission', ('permission=%s target=%s'):format(tostring(permissionKey), tostring(targetCitizenid)), 'feature_disabled')
        return false, 'feature_disabled'
    end

    if not (type(IsHighCommand) == 'function' and IsHighCommand(granterSrc)) then
        LogAuditInvocation(granterSrc, 'grantPermission', ('permission=%s target=%s'):format(tostring(permissionKey), tostring(targetCitizenid)), 'denied')
        return false, 'denied'
    end

    if not PermissionActionCooldown.Consume(granterSrc, PERMISSION_ACTION_COOLDOWN_MS) then
        LogAuditInvocation(granterSrc, 'grantPermission', ('permission=%s target=%s'):format(tostring(permissionKey), tostring(targetCitizenid)), 'rate_limited')
        return false, 'rate_limited'
    end

    if not IsValidPermissionKey(permissionKey) then
        LogAuditInvocation(granterSrc, 'grantPermission', ('permission=%s target=%s'):format(tostring(permissionKey), tostring(targetCitizenid)), 'invalid_permission')
        return false, 'invalid_permission'
    end

    if not IsValidCitizenId(targetCitizenid) then
        LogAuditInvocation(granterSrc, 'grantPermission', ('permission=%s target=%s'):format(permissionKey, tostring(targetCitizenid)), 'invalid_target')
        return false, 'invalid_target'
    end

    local granterPlayer = exports.qbx_core:GetPlayer(granterSrc)
    local granterCitizenid = granterPlayer and granterPlayer.PlayerData and granterPlayer.PlayerData.citizenid
    if not granterCitizenid then
        -- Should not be reachable in practice -- IsHighCommand(granterSrc)
        -- above already required a resolvable Player -- but never assume
        -- that guarantee holds forever; fail closed and report rather than
        -- index into a nil below.
        LogAuditInvocation(granterSrc, 'grantPermission', ('permission=%s target=%s'):format(permissionKey, targetCitizenid), 'invalid_granter')
        NotifyPlayer(granterSrc, locale('common.unable_to_resolve_citizenid'), 'error')
        return false, 'invalid_granter'
    end

    -- AUDIT (coder-security, this pass -- "a reader of the audit trail
    -- could not actually tell a self-grant apart from an ordinary one"):
    -- computed once, here, and threaded through every LogAuditInvocation
    -- call for the rest of this function as an explicit, ALWAYS-PRESENT
    -- `self=true`/`self=false` field. Before this pass a self-grant's own
    -- audit line only ever proved itself by a human (or a script) noticing
    -- that the SAME citizenid string appears twice in one printed line --
    -- once as `whoLabel` (LogAuditInvocation's own granter resolution),
    -- once inside `detail`'s `target=%s` -- which is trivially missable on
    -- a skim and not a stable, greppable signal either
    -- ("AUDIT:.*self=true" now is). This does not change WHO may self-grant
    -- or WHAT they may self-grant -- it only makes an already-permitted or
    -- already-rejected self-grant impossible to mistake for an ordinary
    -- one afterward. Deliberately a plain boolean comparison against the
    -- SAME two values (targetCitizenid, granterCitizenid) the self-grant
    -- check immediately below already computes -- not a new trust decision.
    local isSelfGrant = targetCitizenid == granterCitizenid

    if isSelfGrant then
        -- OWNER DECISION (this pass) -- see header "SELF-GRANT" for the
        -- full writeup. Governed by ONE switch, HighCommandSelfGrantAllowed
        -- (Config.FeatureControl.allowHighCommandSelfGrant, default true),
        -- for EVERY permission namespace this file validates -- WIDENED
        -- this pass from 'feature.<Name>' only to also cover the four named
        -- capabilities (k9.access/k9.certify/k9.audit/k9.givexp) and
        -- 'block.<Name>'. Widens nothing for anyone who is not already high
        -- command (IsHighCommand(granterSrc) was already required to reach
        -- this line at all, checked earlier in this function) -- this
        -- branch only ever changes what an ALREADY-VERIFIED high-command
        -- officer may do to their own citizenid, never who qualifies as
        -- high command.
        if not HighCommandSelfGrantAllowed() then
            LogAuditInvocation(granterSrc, 'grantPermission', ('permission=%s target=%s self=%s'):format(permissionKey, targetCitizenid, tostring(isSelfGrant)), 'self_grant_blocked')
            return false, 'self_grant_blocked'
        end
        -- Falls through to the normal grant path below -- still fully
        -- logged via LogAuditInvocation like any other grant, now carrying
        -- an explicit `self=true` field (see AUDIT comment above) rather
        -- than relying on a reader to notice target == granter unaided,
        -- still rate-limited, still notified. This is not a silent
        -- exception; it is a same-actor grant that is now permitted to
        -- proceed instead of being refused outright.
    end

    -- PERMISSION-KEY CATALOG RACE GUARD (owner-directed "add or remove
    -- permissions" pass, server/permissionkeycatalog.lua) -- see that
    -- file's own header "THE DELETE-VS-GRANT RACE" for the full writeup.
    -- Acquires the SAME cross-file PermissionKeyEditMutex, keyed by
    -- `permissionKey`, that file's own DeleteKey/UpsertKey acquire before
    -- their own tombstone/relabel writes -- this closes the window where a
    -- concurrent delete of `permissionKey` could otherwise land between
    -- "this key is currently known" (already checked above) and this
    -- INSERT actually committing. Guarded by a `type(...) == 'table'`
    -- runtime existence check, this resource's established soft-dependency
    -- convention -- this function still works exactly as before (accepting
    -- only this previously-undocumented, now-disclosed, narrow race) if
    -- server/permissionkeycatalog.lua is ever removed. Mirrors
    -- server/certifications/'s own SetCertificationTier /
    -- TierEditMutex pairing exactly, and cannot deadlock against that
    -- entirely separate mutex (see this new file's own header for why).
    local havePermKeyMutex = type(PermissionKeyEditMutex) == 'table'
    if havePermKeyMutex and not PermissionKeyEditMutex.TryAcquire(permissionKey) then
        LogAuditInvocation(granterSrc, 'grantPermission', ('permission=%s target=%s self=%s'):format(permissionKey, targetCitizenid, tostring(isSelfGrant)), 'busy')
        return false, 'busy'
    end

    -- Re-check AFTER acquiring the lock, in case `permissionKey` was
    -- deleted by a concurrent permKeysDelete call in the gap between the
    -- earlier check and acquiring this lock -- refuse now rather than
    -- write a grant row for a key that no longer validates.
    if havePermKeyMutex and not IsValidPermissionKey(permissionKey) then
        PermissionKeyEditMutex.Release(permissionKey)
        LogAuditInvocation(granterSrc, 'grantPermission', ('permission=%s target=%s self=%s'):format(permissionKey, targetCitizenid, tostring(isSelfGrant)), 'invalid_permission')
        return false, 'invalid_permission'
    end

    local lockKey = targetCitizenid .. ':' .. permissionKey
    if GrantInFlight[lockKey] then
        if havePermKeyMutex then PermissionKeyEditMutex.Release(permissionKey) end
        LogAuditInvocation(granterSrc, 'grantPermission', ('permission=%s target=%s self=%s'):format(permissionKey, targetCitizenid, tostring(isSelfGrant)), 'already_granted')
        return false, 'already_granted'
    end
    GrantInFlight[lockKey] = true

    -- Everything from here down is the DB critical section GrantInFlight
    -- protects -- wrapped in its own closure so it can be pcall'd as a
    -- unit, guaranteeing GrantInFlight[lockKey] is released on every exit
    -- path, including an unexpected thrown error. Mirrors
    -- server/certifications/'s GrantCertification/doGrantInsert shape
    -- exactly.
    local outcome
    local function doGrantInsert()
        local existingId = K9Store.Perm_GetActiveId(targetCitizenid, permissionKey)
        if existingId then
            outcome = 'already_granted'
            return
        end

        local insertOk, insertResultOrErr = pcall(K9Store.Perm_Insert, targetCitizenid, permissionKey, granterCitizenid)

        if not insertOk then
            if IsDuplicateKeyError(insertResultOrErr) then
                -- Another request won the race between the pre-check above
                -- and this INSERT -- the DB's own unique index caught it;
                -- treat identically to the normal "already granted" no-op.
                RefreshPermissionCacheIfOnline(targetCitizenid)
                outcome = 'already_granted'
                return
            end
            print(('[John-K9] permissions.lua GrantPermission INSERT failed for %s/%s: %s'):format(targetCitizenid, permissionKey, tostring(insertResultOrErr)))
            outcome = 'db_error'
            return
        end

        outcome = 'ok'
    end

    local grantOk, grantErr = pcall(doGrantInsert)
    GrantInFlight[lockKey] = nil
    -- Released here, immediately after the write's own critical section
    -- ends, exactly where server/certifications/'s SetCertificationTier
    -- releases TierEditMutex relative to its own K9Store.Cert_SetTier call
    -- -- never held across the notification/cache-refresh/appearance-hook
    -- tail below.
    if havePermKeyMutex then PermissionKeyEditMutex.Release(permissionKey) end

    if not grantOk then
        print(('[John-K9] permissions.lua GrantPermission unexpected error for %s/%s: %s'):format(targetCitizenid, permissionKey, tostring(grantErr)))
        LogAuditInvocation(granterSrc, 'grantPermission', ('permission=%s target=%s self=%s'):format(permissionKey, targetCitizenid, tostring(isSelfGrant)), 'db_error')
        return false, 'db_error'
    end

    if outcome ~= 'ok' then
        LogAuditInvocation(granterSrc, 'grantPermission', ('permission=%s target=%s self=%s'):format(permissionKey, targetCitizenid, tostring(isSelfGrant)), outcome)
        return false, outcome
    end

    RefreshPermissionCacheIfOnline(targetCitizenid)
    -- AUDIT: `self=true` here is the single most important instance of this
    -- field in the whole file -- this is the line printed for a SUCCESSFUL
    -- self-grant (the exact case the OWNER DECISION above exists to permit,
    -- for every permission namespace this file validates, not only
    -- 'feature.<Name>'). Grep for "AUDIT:.*self=true.*-> ok" to find every
    -- self-service grant that actually took effect, with no need to
    -- cross-reference `whoLabel` against `target=` by eye.
    LogAuditInvocation(granterSrc, 'grantPermission', ('permission=%s target=%s self=%s'):format(permissionKey, targetCitizenid, tostring(isSelfGrant)), 'ok')

    -- NOTIFICATIONS: target only, see header. Always sent on a real grant.
    local onlineTargetPlayer = exports.qbx_core:GetPlayerByCitizenId(targetCitizenid)
    local onlineTargetSrc = onlineTargetPlayer and onlineTargetPlayer.PlayerData and onlineTargetPlayer.PlayerData.source
    if onlineTargetSrc then
        NotifyPlayer(onlineTargetSrc, locale('permissions.grant_notify_target', PermissionLabelFor(permissionKey)), 'success')
    end

    -- FEATURE-BLOCK PUSH ON CHANGE -- see "FEATURE-BLOCK PUSH" above for the
    -- full contract. A `block.<Name>` GRANT here means high command just
    -- blocked `Name` for this specific, already-online citizenid -- push
    -- their fresh, complete block set immediately so client/featureblocks.lua
    -- (and, through it, each owning client file's own maintenance-thread
    -- check) can force off an ALREADY-ACTIVE effect within one polling
    -- interval, per client/featureblocks.lua's own "NEVER GATE A
    -- TERMINATION PATH" rule -- this push only ever ADDS a block; it is
    -- each consuming client file's own existing force-off call that
    -- actually tears down a live effect, never this push itself. Scoped to
    -- the `block.` namespace only -- a `feature.<Name>`/`k9.access`/etc.
    -- grant has nothing to do with this sync and must never trigger it.
    if onlineTargetSrc and permissionKey:match('^block%.') then
        PushFeatureBlocksToSource(onlineTargetSrc, targetCitizenid)
    end

    -- K9 ROLE/MODEL DECOUPLING (coder-architect, server/appearance.lua) --
    -- config.lua's own Config.K9Appearance header is explicit that granting
    -- 'k9.access' is one of the two actions that "actually turns their
    -- character into the ped" when applyPedModelOnCertify is on. Guarded
    -- with `type(...) == 'function'` (this file loads before
    -- server/appearance.lua in fxmanifest.lua's server_scripts, per that
    -- file's own requested placement -- see its header -- so this is a
    -- genuine soft dependency, not a load-order assumption: by the time a
    -- real grant can fire, every server_scripts file has already loaded).
    if permissionKey == 'k9.access' and Config.K9Appearance and Config.K9Appearance.applyPedModelOnCertify
        and type(ApplyK9AppearanceOnGrant) == 'function' then
        ApplyK9AppearanceOnGrant(targetCitizenid, granterCitizenid, appearanceModelOverride)
    end

    return true, 'ok'
end

--- CONSOLIDATION (this pass, cross-team "four doors, one bug" finding):
--- this is THIS FILE's own private copy of the exact three-call teardown
--- sequence (ForceDetachLeashForSource + EndActiveEffectForHolder +
--- ForceBreakPartnershipForCitizenId) that server/certifications/'s OWN
--- identically-shaped local helper of the same name wraps for ALL FIVE of
--- ITS call sites (RevokeCertification, RevokeCertificationOffline, and
--- the three OnJobUpdate branches). Deliberately NOT a single shared
--- resource-global reused by both files -- doing that would need a new
--- entry in BOTH fxmanifest.lua's server_scripts list AND
--- /home/user/FIvem/.luacheckrc's `globals` table (a bare `function Foo()`
--- with no matching read_globals/globals entry is flagged
--- "setting/accessing a non-standard global variable", verified against
--- this exact repo's luacheck config before deciding this), and this task
--- has neither file assignable to it. Separately, and independently of
--- that: this resource's own spec files are written to load only the
--- minimal file set the file under test needs -- tests/certifications_spec.lua
--- never loads server/permissions.lua and tests/permissions_spec.lua never
--- loads server/certifications/ for these tests -- so even a
--- same-name-different-file helper could not be shared without either spec
--- absorbing a file (and that file's own file-load-time Config assertions)
--- it otherwise has no reason to load. Given both constraints, this is one
--- real duplicate between two files -- down from six independent inline
--- copies before this pass -- and is reported as a deliberate, bounded
--- tradeoff rather than a missed consolidation: if a THIRD call site
--- outside these two files ever needs this exact sequence, that is the
--- point to revisit a genuinely shared file with whoever owns
--- fxmanifest.lua and .luacheckrc, not before.
---
--- Same contract as certifications.lua's copy: resolves a live server id
--- for `citizenid` (or reuses `knownSrc` if the caller already has one --
--- RevokePermission below always does, since its own call site is scoped
--- to `onlineTargetSrc` being truthy), force-detaches only a K9-role leash
--- (never the officer/handler role -- that is a different invariant no
--- caller of this copy needs), ends any in-progress bite-hold/takedown/
--- drag, and unconditionally breaks any DB-backed partnership row. Runs NO
--- confirmation/reconciliation check of its own -- RevokePermission's own
--- `stillHasAccess == nil` gate above is what confirms the loss; this is
--- the unconditional, "no unbounded trap" teardown for that ALREADY-
--- CONFIRMED outcome, never a second gate that could itself block it.
--- All three calls stay behind their own `type(...) == 'function'` runtime
--- existence guard -- genuinely required here, not just defensive style:
--- server/main.lua, server/combat.lua and server/partnership.lua all load
--- AFTER this file in fxmanifest.lua's server_scripts list.
--- @param citizenid string
--- @param reason string
--- @param knownSrc number? -- pass an already-resolved live server id when the caller has one (skips a redundant GetPlayerByCitizenId lookup); omit to have this resolve it itself.
local function EndK9AccessForCitizenId(citizenid, reason, knownSrc)
    local src = knownSrc
    if type(src) ~= 'number' then
        local onlinePlayer = exports.qbx_core:GetPlayerByCitizenId(citizenid)
        src = onlinePlayer and onlinePlayer.PlayerData and onlinePlayer.PlayerData.source
    end

    if type(src) == 'number' then
        if type(ForceDetachLeashForSource) == 'function' then
            ForceDetachLeashForSource(src, reason)
        end

        if type(EndActiveEffectForHolder) == 'function' then
            pcall(EndActiveEffectForHolder, src)
        end
    end

    if type(ForceBreakPartnershipForCitizenId) == 'function' then
        ForceBreakPartnershipForCitizenId(citizenid, reason)
    end
end

--- Revokes `permissionKey` from `targetCitizenid`. Only callable by high
--- command. See this file's header "THE REVOKED BUT STILL HAS IT BY RANK
--- CASE" for the full `stillHasAccess` contract -- this is the return value
--- the tablet MUST surface distinctly, per this task's own explicit
--- requirement.
---
--- REVOKING A RETIRED KEY MUST ALWAYS BE POSSIBLE (this pass, SECURITY
--- FIX): unlike GrantPermission, this function does NOT require
--- `permissionKey` to currently be catalog-known/valid -- only that it is a
--- plausible string shape (IsPlausiblePermissionKeyShape above) AND that
--- `targetCitizenid` actually holds an ACTIVE row for it right now (the
--- real gate, enforced naturally by K9Store.Perm_RevokeActive's own
--- affectedRows below -- zero rows affected is reported as 'not_granted',
--- the exact same outcome a garbage or never-granted key already produced
--- before this pass). See IsPlausiblePermissionKeyShape's own doc comment
--- for the full "why the old, grant-shaped check here was actively
--- harmful" writeup -- a tombstoned key's grant must remain revocable
--- forever, or high command retiring a key permanently strands it on
--- everyone who already held it.
--- @param granterSrc number
--- @param targetCitizenid string
--- @param permissionKey string
--- @return boolean ok
--- @return string outcome -- 'ok' | 'feature_disabled' | 'denied' | 'invalid_permission' | 'invalid_target' | 'invalid_granter' | 'rate_limited' | 'not_granted' | 'db_error'
--- @return string? stillHasAccess -- meaningful ONLY when ok == true: nil (fully removed -- target has no other path to this capability), 'rank_or_high_command' (target is online and independently still qualifies -- revoking THIS grant did not remove their access), 'unknown_target_offline' (target is not connected -- their current rank/high-command status cannot be verified right now)
function RevokePermission(granterSrc, targetCitizenid, permissionKey)
    if not (Config.Features and Config.Features.PermissionGrants == true) then
        -- SECURITY FIX (coder-security, this pass) -- see GrantPermission's
        -- own identical comment immediately above its matching branch: audit
        -- every rejection, not just the ones after the authorization check.
        LogAuditInvocation(granterSrc, 'revokePermission', ('permission=%s target=%s'):format(tostring(permissionKey), tostring(targetCitizenid)), 'feature_disabled')
        return false, 'feature_disabled'
    end

    if not (type(IsHighCommand) == 'function' and IsHighCommand(granterSrc)) then
        LogAuditInvocation(granterSrc, 'revokePermission', ('permission=%s target=%s'):format(tostring(permissionKey), tostring(targetCitizenid)), 'denied')
        return false, 'denied'
    end

    if not PermissionActionCooldown.Consume(granterSrc, PERMISSION_ACTION_COOLDOWN_MS) then
        LogAuditInvocation(granterSrc, 'revokePermission', ('permission=%s target=%s'):format(tostring(permissionKey), tostring(targetCitizenid)), 'rate_limited')
        return false, 'rate_limited'
    end

    -- SHAPE ONLY, NOT CATALOG-VALID -- see IsPlausiblePermissionKeyShape's
    -- own doc comment for why this deliberately differs from GrantPermission's
    -- IsValidPermissionKey check just below this same file's own similarly-
    -- named guards.
    if not IsPlausiblePermissionKeyShape(permissionKey) then
        LogAuditInvocation(granterSrc, 'revokePermission', ('permission=%s target=%s'):format(tostring(permissionKey), tostring(targetCitizenid)), 'invalid_permission')
        return false, 'invalid_permission'
    end

    if not IsValidCitizenId(targetCitizenid) then
        LogAuditInvocation(granterSrc, 'revokePermission', ('permission=%s target=%s'):format(permissionKey, tostring(targetCitizenid)), 'invalid_target')
        return false, 'invalid_target'
    end

    local granterPlayer = exports.qbx_core:GetPlayer(granterSrc)
    local granterCitizenid = granterPlayer and granterPlayer.PlayerData and granterPlayer.PlayerData.citizenid
    if not granterCitizenid then
        LogAuditInvocation(granterSrc, 'revokePermission', ('permission=%s target=%s'):format(permissionKey, targetCitizenid), 'invalid_granter')
        NotifyPlayer(granterSrc, locale('common.unable_to_resolve_citizenid'), 'error')
        return false, 'invalid_granter'
    end

    -- YOU MAY NOT LIFT YOUR OWN BLOCK (red-team finding, CRITICAL).
    --
    -- Everywhere a block is READ, this resource defends it properly:
    -- HasK9Access, IsEligibleCertifier, IsAuthorizedAdmin and
    -- IsAuthorizedForXpGrant all consult 'block.k9.*' BEFORE any rank
    -- bypass, and HasPermission structurally refuses to let the high-command
    -- bypass reach a 'block.' key at all. The WRITE side never got the
    -- matching restriction, and that made the whole feature useless against
    -- exactly the person it exists to restrain.
    --
    -- The attack, in full: a chief blocks a misbehaving captain who is still
    -- high command by rank. Being blocked only writes a k9_permissions row --
    -- it does not touch job.grade or job.isboss -- so IsHighCommand still
    -- answers true for that captain. The only check below was
    -- IsHighCommand(granterSrc). So the captain runs revoke against their own
    -- citizenid, the row is deleted, the permission cache refreshes
    -- immediately, and they have handed themselves back the exact capability
    -- they were just restrained from. Same for k9.access, k9.certify,
    -- k9.audit and k9.givexp, and reachable from all three entry points
    -- (the merged command, the legacy command, and the tablet callback),
    -- since each is a deliberate thin pass-through with no check of its own.
    --
    -- There is no higher tier than high command in this resource to appeal
    -- to, so the correct answer is simply that nobody removes their own
    -- block -- someone else with the rank has to. That mirrors the rule
    -- already enforced everywhere the block is read: a block beats everyone,
    -- including you.
    --
    -- Deliberately NOT tied to Config.FeatureControl.allowHighCommandSelfGrant.
    -- That setting governs self-GRANTING a capability and defaults to true so
    -- a lone owner can bootstrap their own server; letting it also govern
    -- self-unblocking would mean the shipped default silently reopens this
    -- hole. Self-revoke of a NON-block key is untouched and still allowed --
    -- giving up your own grant is not an escalation.
    if type(permissionKey) == 'string' and permissionKey:match('^block%.')
        and granterCitizenid == targetCitizenid then
        LogAuditInvocation(granterSrc, 'revokePermission', ('permission=%s target=%s self=true'):format(permissionKey, targetCitizenid), 'denied_self_unblock')
        NotifyPlayer(granterSrc, locale('permissions.cannot_lift_own_block'), 'error')
        return false, 'denied_self_unblock'
    end

    -- AUDIT (coder-security, this pass -- see GrantPermission's identical
    -- comment for the full "a self-grant must not need a human to notice
    -- two matching substrings" writeup): a high-command officer revoking a
    -- grant against their OWN citizenid is not new or newly risky (this
    -- file's header "SELF-GRANT" section already covers why self-revoke was
    -- never restricted the way self-grant is), but it deserves the exact
    -- same "self=true is a stable, greppable field, not an eyeball exercise"
    -- treatment GrantPermission now gets.
    local isSelfTarget = targetCitizenid == granterCitizenid

    -- DB ERRORS THROW, NOT NIL -- pcall-guarded, reconciled on throw exactly
    -- like server/certifications/'s RevokeCertification. A SQL
    -- transaction would not resolve the one genuine ambiguity a thrown
    -- error can leave behind here either (this is the only write in this
    -- function) -- same reasoning that file's own comment already gives.
    local updateOk, affectedRowsOrErr = pcall(K9Store.Perm_RevokeActive, targetCitizenid, permissionKey, granterCitizenid)

    if not updateOk then
        print(('[John-K9] permissions.lua RevokePermission UPDATE failed for %s/%s: %s -- reconciling before reporting an outcome'):format(targetCitizenid, permissionKey, tostring(affectedRowsOrErr)))

        local stillActive = IsPermissionRowConfirmedActive(targetCitizenid, permissionKey)
        if stillActive ~= false then
            -- Either confirmed still active (the UPDATE genuinely never
            -- committed) or unreadable (nil, true outcome unknown) -- in
            -- BOTH cases, never claim a revoke succeeded that this code
            -- cannot confirm, and never run the side effects below (cache
            -- refresh, notification, rank reconciliation) against a guess.
            LogAuditInvocation(granterSrc, 'revokePermission', ('permission=%s target=%s self=%s'):format(permissionKey, targetCitizenid, tostring(isSelfTarget)), 'db_error')
            return false, 'db_error'
        end
        -- Confirmed inactive despite the thrown error (e.g. a success
        -- acknowledgment lost after a real commit) -- fall through to the
        -- normal success path below against this now-confirmed truth.
    elseif not affectedRowsOrErr or affectedRowsOrErr == 0 then
        LogAuditInvocation(granterSrc, 'revokePermission', ('permission=%s target=%s self=%s'):format(permissionKey, targetCitizenid, tostring(isSelfTarget)), 'not_granted')
        return false, 'not_granted'
    end

    -- The revoke is CONFIRMED at this point (either the UPDATE returned
    -- normally with affectedRows > 0, or the reconciliation read above
    -- independently confirmed the row is now inactive). Refresh the cache
    -- BEFORE the rank reconciliation below -- LegacyOrHighCommandStillQualifies
    -- (for 'k9.access') calls the real HasK9Access, which itself re-reads
    -- this same cache; it must see the grant as already gone.
    RefreshPermissionCacheIfOnline(targetCitizenid)

    local stillHasAccess = nil
    local onlineTargetPlayer = exports.qbx_core:GetPlayerByCitizenId(targetCitizenid)
    local onlineTargetSrc = onlineTargetPlayer and onlineTargetPlayer.PlayerData and onlineTargetPlayer.PlayerData.source
    if onlineTargetSrc then
        if LegacyOrHighCommandStillQualifies(onlineTargetSrc, permissionKey) then
            stillHasAccess = 'rank_or_high_command'
        end
    else
        stillHasAccess = 'unknown_target_offline'
    end

    -- FEATURE-BLOCK PUSH ON CHANGE -- see "FEATURE-BLOCK PUSH" above and
    -- GrantPermission's own identical comment. A `block.<Name>` REVOKE here
    -- means high command just UNBLOCKED `Name` for this online citizenid --
    -- push their fresh, complete block set immediately so the twelve
    -- client-only features (and every other consumer of
    -- IsK9FeatureBlocked()) become usable again without a reconnect.
    -- `stillHasAccess` is always `nil` here for the block.<Name> namespace
    -- when `onlineTargetSrc` is truthy (LegacyOrHighCommandStillQualifies
    -- has no legacy tier for this namespace -- see that function's own doc
    -- comment), so this is unconditional on `onlineTargetSrc` alone, not
    -- additionally gated on `stillHasAccess == nil` the way the
    -- target-facing NotifyPlayer below deliberately is -- there is no
    -- "still has it another way" case for a per-feature block to suppress
    -- this sync against.
    if onlineTargetSrc and permissionKey:match('^block%.') then
        PushFeatureBlocksToSource(onlineTargetSrc, targetCitizenid)
    end

    LogAuditInvocation(granterSrc, 'revokePermission', ('permission=%s target=%s self=%s still_has_access=%s'):format(permissionKey, targetCitizenid, tostring(isSelfTarget), tostring(stillHasAccess)), 'ok')

    -- NOTIFICATIONS: target only, and only when something actually changed
    -- for them -- see header "NOTIFICATIONS" for why this is suppressed
    -- when stillHasAccess == 'rank_or_high_command'.
    if onlineTargetSrc and stillHasAccess == nil then
        NotifyPlayer(onlineTargetSrc, locale('permissions.revoke_notify_target', PermissionLabelFor(permissionKey)), 'error')
    end

    -- K9 ROLE/MODEL DECOUPLING (coder-architect, server/appearance.lua) --
    -- only when 'k9.access' is FULLY gone (stillHasAccess == nil): if the
    -- target still qualifies via rank/high-command or is offline (unknown),
    -- MaybeRevertK9Appearance does its OWN independent reconciliation
    -- anyway (it also checks for a separate active k9_certifications row),
    -- so this is a cheap pre-filter, not a correctness dependency. Guarded
    -- with `type(...) == 'function'`, same soft-dependency reasoning as the
    -- grant-side call above.
    if permissionKey == 'k9.access' and stillHasAccess == nil and type(MaybeRevertK9Appearance) == 'function' then
        MaybeRevertK9Appearance(targetCitizenid)
    end

    -- SECURITY FIX (coder-backend, this pass -- "the de-assign button"
    -- gap): server/tablet.lua's own header documents THIS EXACT call
    -- (RevokePermission(..., 'k9.access')) as high command's official
    -- "de-assign K9 role" action, and explicitly reassures its own reader
    -- that MaybeRevertK9Appearance's automatic revert closes the loop --
    -- true for the PED-MODEL half only. Until now this function did
    -- nothing else at all on a confirmed full loss of 'k9.access': no
    -- leash detach, no partnership break, no bite-hold/takedown/drag end.
    -- An officer de-assigned mid-incident through the one, first-class,
    -- DOCUMENTED path for doing so kept physically holding or dragging
    -- their target, and kept an active leash/partnership pairing, for the
    -- rest of that mechanic's own duration -- the exact
    -- leash-holding-a-suspect-for-twenty-seconds shape
    -- server/certifications/'s RevokeCertification/
    -- RevokeCertificationOffline/OnJobUpdate already close for a
    -- CERTIFICATION loss; 'k9.access' is a second, independent door into
    -- the identical hold.
    --
    -- Scoped to `stillHasAccess == nil` -- the ONLY outcome this function
    -- itself already treats as a CONFIRMED, complete loss of K9 access
    -- (identical gate as the MaybeRevertK9Appearance call and the
    -- target-facing notification above it). `stillHasAccess == nil` can
    -- only be reached when `onlineTargetSrc` is truthy (see the if/else
    -- above that sets it), and for 'k9.access' specifically it is set by
    -- LegacyOrHighCommandStillQualifies calling the real, live
    -- HasK9Access(onlineTargetSrc) -- so `nil` here means HasK9Access has
    -- ALREADY confirmed zero remaining routes (certification, this
    -- now-revoked permission grant, autoAccessGrade, high command), not
    -- merely "the permission row is gone."
    --
    -- Called UNCONDITIONALLY of any of those routes' own state -- the "no
    -- unbounded trap" rule: this is a fresh, already-confirmed loss, not a
    -- re-check to gate the teardown behind. CONSOLIDATION (this pass): the
    -- actual three-call sequence (and its own `type(...) == 'function'`
    -- guards, still genuinely required -- server/main.lua, server/combat.lua
    -- and server/partnership.lua all load AFTER this file) now lives in
    -- this file's own EndK9AccessForCitizenId helper above, immediately
    -- before this function -- see that helper's own doc comment for why it
    -- is a private, file-local copy rather than a resource-global shared
    -- with server/certifications/'s identically-named, identically-
    -- shaped helper.
    --
    -- Deliberately does NOT run for `stillHasAccess == 'unknown_target_offline'`
    -- -- this file's own established posture (header "THE REVOKED BUT
    -- STILL HAS IT BY RANK CASE") is to never claim an outcome it cannot
    -- verify for a genuinely offline target. A leash pairing and an
    -- active hold are both online-only, ephemeral state (server/main.lua/
    -- server/combat.lua) and literally cannot exist for a disconnected
    -- citizenid, so skipping those two costs nothing for an offline
    -- target; a DB-backed partnership is deliberately left standing
    -- rather than broken on a guess that may resolve the other way the
    -- moment they reconnect and are found to still qualify by rank. This
    -- is why the call below is INSIDE this `stillHasAccess == nil` gate,
    -- not unconditional -- `onlineTargetSrc` is guaranteed truthy on this
    -- branch (see the if/else above that sets `stillHasAccess`), so
    -- EndK9AccessForCitizenId always has a known, live `src` here and never
    -- needs to fall back to its own internal GetPlayerByCitizenId lookup.
    if permissionKey == 'k9.access' and stillHasAccess == nil then
        EndK9AccessForCitizenId(targetCitizenid, 'k9_access_revoked', onlineTargetSrc)
    end

    return true, 'ok', stillHasAccess
end

-- ======================================================================
-- TABLET QUERIES -- read-only, DB-authoritative (never served from
-- PermissionCache, which is scoped to online citizenids only -- these two
-- must work for an offline target/roster too). Each independently
-- re-verifies high-command authorization from `callerSrc`'s own live job,
-- exactly like GrantPermission/RevokePermission -- never trust a caller to
-- have already checked this themselves.
-- ======================================================================

--- Lists every ACTIVE permission `targetCitizenid` currently holds (the
--- tablet's per-person view). Uses idx_citizen_permission_active as a
--- citizenid-prefix scan -- the exact query shape that index's own
--- sql/install.sql comment documents.
--- @param callerSrc number
--- @param targetCitizenid string
--- @return boolean ok
--- @return table|string rowsOrOutcome -- on success: array of { permission: string, grantedBy: string, grantedAt: string }; on failure: 'denied' | 'invalid_target'
function ListActivePermissionsForCitizenId(callerSrc, targetCitizenid)
    if not (type(IsHighCommand) == 'function' and IsHighCommand(callerSrc)) then
        return false, 'denied'
    end
    if not IsValidCitizenId(targetCitizenid) then
        return false, 'invalid_target'
    end

    local rows = K9Store.Perm_GetHistoryByCitizenId(targetCitizenid)
    local out = {}
    for i, row in ipairs(rows) do
        out[i] = { permission = row.permission, grantedBy = row.granted_by, grantedAt = row.granted_at }
    end
    return true, out
end

--- Lists every citizenid currently holding `permissionKey` (the tablet's
--- roster view for one capability). Uses idx_permission_active -- the exact
--- query shape that index's own sql/install.sql comment documents.
---
--- SAME "REVOKE DIRECTION" REASONING AS RevokePermission (this pass): uses
--- the SHAPE-ONLY IsPlausiblePermissionKeyShape, never the catalog-valid
--- IsValidPermissionKey. Finding out WHO still holds a TOMBSTONED key is a
--- read squarely in service of the exact same "a retired key must remain
--- manageable" requirement -- a roster caller trying to locate every
--- straggler of a just-retired key so each one can be revoked must not
--- itself be refused 'invalid_permission' for asking about that same key. A
--- key nobody has ever granted simply resolves to an empty roster below
--- (K9Store.Perm_GetActiveRosterByPermission's own natural "no rows"
--- answer) -- exactly as before this pass for that case, never a new,
--- different outcome.
--- @param callerSrc number
--- @param permissionKey string
--- @return boolean ok
--- @return table|string rowsOrOutcome -- on success: array of { citizenid: string, grantedBy: string, grantedAt: string }; on failure: 'denied' | 'invalid_permission'
function ListPermissionRoster(callerSrc, permissionKey)
    if not (type(IsHighCommand) == 'function' and IsHighCommand(callerSrc)) then
        return false, 'denied'
    end
    if not IsPlausiblePermissionKeyShape(permissionKey) then
        return false, 'invalid_permission'
    end

    local rows = K9Store.Perm_GetActiveRosterByPermission(permissionKey)
    local out = {}
    for i, row in ipairs(rows) do
        out[i] = { citizenid = row.citizenid, grantedBy = row.granted_by, grantedAt = row.granted_at }
    end
    return true, out
end

-- ======================================================================
-- TABLET CALLBACKS -- see this file's header "TABLET NETWORK CONTRACT" for
-- the full writeup. Gated on Config.Features.CommandTablet AT REGISTRATION
-- TIME (this resource's "gate at registration, not just inside the
-- handler" convention, mirrored from client/tablet.lua's own identical
-- top-of-file gate): if that flag is not `true`, neither callback below is
-- ever registered at all, not merely a runtime no-op. Independent of
-- Config.Features.PermissionGrants -- GrantPermission/RevokePermission
-- themselves already re-check that flag and fail closed with
-- 'feature_disabled' if it is off, so registering these callbacks
-- regardless of PermissionGrants' value is safe and lets the tablet render
-- a clear "feature disabled" reason rather than the callback not existing
-- at all.
-- ======================================================================
if Config.Features and Config.Features.CommandTablet == true then
    lib.callback.register('john-k9:server:tabletGrantPermission', function(source, targetCitizenid, permissionKey)
        local ok, outcome = GrantPermission(source, targetCitizenid, permissionKey)
        if ok then return { ok = true } end
        return { ok = false, reason = outcome }
    end)

    lib.callback.register('john-k9:server:tabletRevokePermission', function(source, targetCitizenid, permissionKey)
        local ok, outcome, stillHasAccess = RevokePermission(source, targetCitizenid, permissionKey)
        if ok then
            if stillHasAccess then
                return { ok = true, reason = stillHasAccess }
            end
            return { ok = true }
        end
        return { ok = false, reason = outcome }
    end)
end

-- ======================================================================
-- CONSOLE/CHAT COMMAND GRANT PATH (this pass) -- closes a genuine single
-- point of failure found by a workflow trace: until now,
-- 'john-k9:server:tabletGrantPermission'/'...:tabletRevokePermission'
-- (immediately above) were the ONLY code in this resource that ever wrote
-- a 'feature.<Name>' grant, and both are registered ONLY when
-- Config.Features.CommandTablet == true. Nine features in config.lua's
-- own Config.FeatureControl.RequireGrant (BiteAndHold, NonLethalTakedown,
-- PropDragging, AdminAuditCommands, FindAlerts, ScentTrailHunt,
-- PursuitSprint) have NO rank-based fallback in
-- their own 4-step resolution (config.lua's own header: step 3 is "ALLOW
-- ONLY IF THEY HOLD A GRANT", full stop) -- so an operator who turns
-- CommandTablet off, which config.lua's own Config.CommandTablet header
-- describes as merely "a VIEW" that "decides nothing", silently loses the
-- ONLY way to ever grant any of those nine features to anyone, including
-- themselves, with nothing telling them why. See this file's own STARTUP
-- WARNING section below for the loud half of this fix; these two commands
-- are the actual second door.
--
-- MIRRORS THE TABLET CALLBACKS EXACTLY, not a fresh reimplementation:
-- both commands are thin `RegisterCommand` wrappers over the SAME
-- GrantPermission/RevokePermission the tablet callbacks above call,
-- passed `source` exactly as ox_lib's own callback dispatch passes it to
-- those -- the real, server-resolved command invoker, never a
-- client-supplied id. GrantPermission/RevokePermission ALREADY perform
-- 100% of the real work for either caller: authorization (IsHighCommand,
-- re-verified from the invoker's OWN live job), rate-limiting
-- (PermissionActionCooldown, the SAME shared instance the tablet path
-- already consumes from), key/citizenid validation, self-grant blocking,
-- the DB write, audit logging (LogAuditInvocation), cache refresh, the
-- feature-block push, and target notification. THIS SECTION ADDS NO
-- SECOND, PARALLEL AUTHORIZATION CHECK OF ITS OWN -- a grant path is a
-- privilege-escalation surface, and the only way to guarantee this new
-- door can never be WIDER than the tablet's is to route it through the
-- exact same gate rather than a hand-written copy of it. If GrantPermission/
-- RevokePermission's own authorization ever changes, both doors change
-- together, by construction.
--
-- REGISTERED UNCONDITIONALLY, unlike the tablet callbacks above (which
-- are gated on Config.Features.CommandTablet at registration time) --
-- that is the entire point: this command must survive exactly the
-- Config.Features.CommandTablet = false case the STARTUP WARNING below
-- exists to flag, or it would inherit the same single point of failure it
-- is here to remove. It is independent of Config.Features.PermissionGrants
-- too, for the identical reason the tablet callbacks already are (see
-- their own comment above) -- GrantPermission/RevokePermission re-check
-- that flag themselves and fail closed with 'feature_disabled'.
--
-- `false` as RegisterCommand's third argument (this resource's own
-- established convention -- matches every RegisterCommand in
-- server/certifications/, e.g. k9certifyoffline/k9decertifyoffline)
-- leaves this command unrestricted at the FiveM ACE permission layer: the
-- REAL gate is GrantPermission/RevokePermission's own IsHighCommand check,
-- run unconditionally on every single invocation. This deliberately
-- includes a plain server-console invocation (source == 0): IsHighCommand
-- has no job to consult for source 0 (see server/highcommand.lua's own
-- header) and therefore already, correctly, refuses it -- exactly the
-- SAME refusal the tablet path gives a non-high-command in-game caller.
-- No console carve-out is added here (unlike server/admin.lua's own
-- opt-in TrustConsole convar for its audit commands) -- that would be
-- WIDENING this door past the tablet's own authorization, which this pass
-- is explicitly told never to do. In practice this means these two
-- commands are run BY an already-online high-command officer, from their
-- own client console or chat box, exactly like /k9certify and friends.
--
-- FEEDBACK TO THE INVOKER: unlike the tablet path (which returns a
-- structured `{ ok, reason }` for client/tablet.lua's own UI to render,
-- deliberately WITHOUT a granter-facing toast of its own -- see header
-- "NOTIFICATIONS") a console/chat command has no UI to hand a structured
-- result to, so THIS section (never GrantPermission/RevokePermission
-- themselves) is responsible for telling the invoker what happened -- the
-- exact same responsibility split server/certifications/'s own
-- RegisterCommand handlers already have relative to
-- GrantCertification/RevokeCertification. The two lookup tables below
-- cover every outcome EXCEPT 'invalid_granter' -- GrantPermission/
-- RevokePermission already send `locale('common.unable_to_resolve_citizenid')`
-- to the invoker for that one themselves (see either function's own
-- body), so adding a second message here would double-notify.
--
-- LOCALE KEYS THIS SECTION NEEDS -- LANDED (verified directly against
-- locales/en.json, and against this file's own real `locale(...)` call
-- sites below, e.g. `locale('permissions.command_usage_grant')`). This
-- comment used to say these keys were NOT yet in locales/en.json (this
-- file being told not to edit that file directly -- reported, not added,
-- matching this file's own header precedent for
-- permissions.grant_notify_target/permissions.revoke_notify_target, which
-- have likewise since landed) -- every key below now resolves for real.
-- Resolved LAZILY, one `locale()` call per actual outcome -- never built
-- as one eagerly-evaluated table -- so a key that is merely UNREACHABLE in
-- a given call never forces every OTHER key to already exist. Every value
-- below is the exact English text that was requested and has since
-- landed:
--   permissions.command_usage_grant        = "Usage: /k9grantpermission [citizenid] [permissionKey]"
--   permissions.command_usage_revoke       = "Usage: /k9revokepermission [citizenid] [permissionKey]"
--   permissions.command_not_authorized     = "You are not authorized to grant or revoke K9 permissions."
--   permissions.command_feature_disabled   = "Permission grants are currently disabled on this server."
--   permissions.command_invalid_permission = "That is not a valid permission key."
--   permissions.command_invalid_target     = "That is not a valid citizen ID."
--   permissions.command_self_grant_blocked = "You cannot grant a permission to yourself."
--   permissions.command_rate_limited       = "Please wait a moment before trying again."
--   permissions.command_busy               = "That permission key is being edited elsewhere right now -- try again in a moment."
--   permissions.command_already_granted    = "%s already holds that permission."
--   permissions.command_db_error           = "A database error occurred. Please try again."
--   permissions.command_grant_ok           = "Granted '%s' to %s."
--   permissions.command_not_granted        = "%s does not currently hold that permission."
--   permissions.command_revoke_ok          = "Revoked '%s' from %s."
--   permissions.command_revoke_ok_rank     = "Revoked '%s' from %s, but they still have it through their rank or High Command status."
--   permissions.command_revoke_ok_offline  = "Revoked '%s' from %s. They are offline, so it could not be checked whether they still qualify for it through rank."
-- ======================================================================

--- Maps a GrantPermission outcome string to the locale KEY to show the
--- invoker (never the resolved text -- see this section's own header for
--- why this is a lazy lookup table, not an eagerly-evaluated one). No
--- entry for 'ok' (handled separately below -- it needs the permission's
--- own label) or 'invalid_granter' (already notified by GrantPermission
--- itself).
local GRANT_COMMAND_OUTCOME_KEYS = {
    feature_disabled   = 'permissions.command_feature_disabled',
    denied             = 'permissions.command_not_authorized',
    invalid_permission = 'permissions.command_invalid_permission',
    invalid_target     = 'permissions.command_invalid_target',
    self_grant_blocked = 'permissions.command_self_grant_blocked',
    rate_limited       = 'permissions.command_rate_limited',
    busy               = 'permissions.command_busy',
    already_granted    = 'permissions.command_already_granted',
    db_error           = 'permissions.command_db_error',
}

--- Same shape as GRANT_COMMAND_OUTCOME_KEYS above, for RevokePermission's
--- own outcome strings. No entry for 'ok' (handled separately below --
--- three different messages depending on `stillHasAccess`) or
--- 'invalid_granter' (already notified by RevokePermission itself). No
--- 'busy'/'self_grant_blocked' entries either -- RevokePermission never
--- returns either outcome (see that function's own doc comment).
local REVOKE_COMMAND_OUTCOME_KEYS = {
    feature_disabled   = 'permissions.command_feature_disabled',
    denied             = 'permissions.command_not_authorized',
    invalid_permission = 'permissions.command_invalid_permission',
    invalid_target     = 'permissions.command_invalid_target',
    rate_limited       = 'permissions.command_rate_limited',
    not_granted        = 'permissions.command_not_granted',
    db_error           = 'permissions.command_db_error',
}

-- `type(RegisterCommand) == 'function'` guard (this resource's established
-- soft-dependency convention): RegisterCommand is a real, always-present
-- FiveM native in production, so this is never false there -- both
-- commands register exactly as unconditionally as described above. It
-- exists purely so a minimal test harness/embedding that never provides
-- one (this file is a widely-depended-upon soft dependency of several
-- OTHER files' own test fixtures -- server/appearance.lua,
-- server/permissionkeycatalog.lua, server/tablet.lua) degrades to "these
-- two commands are not registered in THAT harness" rather than a hard
-- load-time crash the moment this section was added.
-- ======================================================================
-- COMMAND CONSOLIDATION (docs/history/COMMAND_CONSOLIDATION_SPEC.md §5 item 7, §1
-- "permissions" family) -- k9grantpermission/k9revokepermission merge into
-- ONE canonical `/k9permission <grant|revoke> <citizenid> <permission>`.
-- Both handler BODIES below are UNCHANGED from before this pass -- only
-- pulled out into named local functions so the merged dispatcher and both
-- OLD command names (now hidden aliases, kept registered forever per the
-- spec's own "operators have keybinds/cheat-sheets" rule) can share the
-- exact same code, never two copies to drift apart. Confirmed identical
-- gate both ways (Config.Features.PermissionGrants + IsHighCommand,
-- checked INSIDE GrantPermission/RevokePermission themselves, never by
-- this dispatcher) and the SAME PermissionActionCooldown instance either
-- function reaches -- no widening, exactly per this file's own header
-- "does this widen who can do what" test. The merged dispatcher itself
-- adds NO authorization of its own: it only decides WHICH already-gated
-- function to call, matching this task's own "parse the subcommand, then
-- apply that subcommand's own gate" rule -- trivially true here since
-- both subcommands' gates are byte-identical, but the shape is the same
-- either way (never a single top-level gate ahead of knowing which verb
-- was requested).
-- ======================================================================

--- @param source number
--- @param args string[] -- { citizenid, permissionKey }
local function HandleGrantPermissionCommand(source, args)
    local targetCitizenid = args[1]
    local permissionKey = args[2]
    if type(targetCitizenid) ~= 'string' or targetCitizenid == '' or type(permissionKey) ~= 'string' or permissionKey == '' then
        NotifyPlayer(source, locale('permissions.command_usage_grant'), 'error')
        return
    end

    local ok, outcome = GrantPermission(source, targetCitizenid, permissionKey)
    if ok then
        NotifyPlayer(source, locale('permissions.command_grant_ok', PermissionLabelFor(permissionKey), targetCitizenid), 'success')
        return
    end

    if outcome == 'already_granted' then
        NotifyPlayer(source, locale(GRANT_COMMAND_OUTCOME_KEYS.already_granted, targetCitizenid), 'error')
        return
    end
    local key = GRANT_COMMAND_OUTCOME_KEYS[outcome]
    if key then
        NotifyPlayer(source, locale(key), 'error')
    end
    -- outcome == 'invalid_granter': already notified by GrantPermission itself.
end

--- @param source number
--- @param args string[] -- { citizenid, permissionKey }
local function HandleRevokePermissionCommand(source, args)
    local targetCitizenid = args[1]
    local permissionKey = args[2]
    if type(targetCitizenid) ~= 'string' or targetCitizenid == '' or type(permissionKey) ~= 'string' or permissionKey == '' then
        NotifyPlayer(source, locale('permissions.command_usage_revoke'), 'error')
        return
    end

    local ok, outcome, stillHasAccess = RevokePermission(source, targetCitizenid, permissionKey)
    if ok then
        local label = PermissionLabelFor(permissionKey)
        if stillHasAccess == 'rank_or_high_command' then
            NotifyPlayer(source, locale('permissions.command_revoke_ok_rank', label, targetCitizenid), 'success')
        elseif stillHasAccess == 'unknown_target_offline' then
            NotifyPlayer(source, locale('permissions.command_revoke_ok_offline', label, targetCitizenid), 'success')
        else
            NotifyPlayer(source, locale('permissions.command_revoke_ok', label, targetCitizenid), 'success')
        end
        return
    end

    if outcome == 'not_granted' then
        NotifyPlayer(source, locale(REVOKE_COMMAND_OUTCOME_KEYS.not_granted, targetCitizenid), 'error')
        return
    end
    local key = REVOKE_COMMAND_OUTCOME_KEYS[outcome]
    if key then
        NotifyPlayer(source, locale(key), 'error')
    end
    -- outcome == 'invalid_granter': already notified by RevokePermission itself.
end

-- `type(RegisterCommand) == 'function'` guard (this resource's established
-- soft-dependency convention): RegisterCommand is a real, always-present
-- FiveM native in production, so this is never false there -- both
-- commands register exactly as unconditionally as described above. It
-- exists purely so a minimal test harness/embedding that never provides
-- one (this file is a widely-depended-upon soft dependency of several
-- OTHER files' own test fixtures -- server/appearance.lua,
-- server/permissionkeycatalog.lua, server/tablet.lua) degrades to "these
-- two commands are not registered in THAT harness" rather than a hard
-- load-time crash the moment this section was added.
if type(RegisterCommand) == 'function' then
    -- NEW CANONICAL COMMAND. Destructive-vs-additive note (this task's own
    -- rule): revoke IS a destructive/access-removing action, but this is
    -- NOT "contextual dispatch guessing intent" -- the verb is an explicit,
    -- required word (`grant` or `revoke`), never inferred from argument
    -- shape/type the way the online/offline certification pairs infer
    -- online-vs-offline. An unrecognized/missing subcommand prints this
    -- command's own usage string, reusing admin.lua's own
    -- k9audit search/k9audit xp convention verbatim (`if source == 0 then
    -- print(...) else NotifyPlayer(...) end`) rather than inventing a new
    -- one.
    RegisterAdminCommand('k9permission', function(source, args)
        local sub = args[1]
        if sub == 'grant' then
            HandleGrantPermissionCommand(source, { args[2], args[3] })
        elseif sub == 'revoke' then
            HandleRevokePermissionCommand(source, { args[2], args[3] })
        else
            local usage = locale('permissions.usage_permission')
            if source == 0 then print('[John-K9] ' .. usage) else NotifyPlayer(source, usage, 'error') end
        end
    end, false)

    -- HIDDEN ALIASES (docs/history/COMMAND_CONSOLIDATION_SPEC.md §3) -- kept registered
    -- forever, byte-identical bodies to before this merge, for existing
    -- keybinds/macros/cheat-sheets. Not chat-suggested and not listed in
    -- html/tablet.js's COMMAND_REFERENCE anymore (see
    -- client/commandsuggestions.lua's/tests' own HIDDEN_ALIAS_COMMANDS
    -- allowlist) -- `/k9permission grant|revoke` is what a user now
    -- discovers instead.
    RegisterAdminCommand('k9grantpermission', function(source, args)
        HandleGrantPermissionCommand(source, args)
    end, false)

    RegisterAdminCommand('k9revokepermission', function(source, args)
        HandleRevokePermissionCommand(source, args)
    end, false)
end

-- ======================================================================
-- STARTUP WARNING -- CommandTablet-off/unreachable + a non-empty
-- RequireGrant (this pass). Written for the operator who flips
-- Config.Features.CommandTablet off believing it only removes a "VIEW"
-- (config.lua's own Config.CommandTablet header: "The tablet is a VIEW.
-- It decides nothing.") without realising it is ALSO the tablet's own
-- grant/revoke CONTROLS -- see this file's own "CONSOLE/CHAT COMMAND
-- GRANT PATH" section immediately above for the fix; this is the loud,
-- printed half of it, matching this resource's established convention
-- for an unmissable, actionable operator warning (identical shape to
-- server/combat.lua's PropDragging override warning and
-- another file's own override warning -- both
-- `AddEventHandler('onResourceStart', ...)`, both filtered to THIS
-- resource's own restart via `GetCurrentResourceName() ~= resourceName`,
-- both a single loud `print`, never an `assert`, because turning a
-- feature off is a legitimate operator choice, not a misconfiguration to
-- abort over).
--
-- FIRES ONLY WHEN BOTH HOLD:
--   1. Config.FeatureControl.RequireGrant currently lists at least one
--      feature (an empty/absent table means nothing in this resource
--      needs a grant at all, so an unreachable tablet costs nothing).
--   2. The tablet's own grant controls are unreachable right now, either
--      because Config.Features.CommandTablet ~= true (the
--      tabletGrantPermission/tabletRevokePermission callbacks above are
--      then never even registered), OR because
--      Config.CommandTablet.openMode == 'item' -- client/tablet.lua's own
--      header documents that, in 'item' mode, "The command is not
--      registered at all", so the tablet's ONLY door is an inventory item
--      this resource cannot verify exists in your items table (config.lua's
--      own comment on Config.CommandTablet.itemName -- a separate,
--      already-disclosed footgun this warning does not re-diagnose, only
--      accounts for as a second way the tablet can be unreachable).
--
-- NAMES THE EXACT FEATURES, sorted for a deterministic, testable message,
-- rather than a vague "some features" -- an operator should not have to
-- go re-read config.lua to find out what just became affected.
-- NEVER CLAIMS THESE ARE "UNGRANTABLE" (true before this pass, false
-- after it) -- the two commands directly above are ALWAYS registered,
-- regardless of CommandTablet, so this warning points at them as the
-- working alternative rather than describing a dead end.
-- ======================================================================
AddEventHandler('onResourceStart', function(resourceName)
    if GetCurrentResourceName() ~= resourceName then return end

    local requireGrant = type(Config.FeatureControl) == 'table' and Config.FeatureControl.RequireGrant
    if type(requireGrant) ~= 'table' then return end

    local featureNames = {}
    for name, isRequired in pairs(requireGrant) do
        if isRequired == true and type(name) == 'string' then
            featureNames[#featureNames + 1] = name
        end
    end
    if #featureNames == 0 then return end
    table.sort(featureNames)

    local commandTabletOn = Config.Features and Config.Features.CommandTablet == true
    local openModeItemOnly = commandTabletOn and type(Config.CommandTablet) == 'table' and Config.CommandTablet.openMode == 'item'

    if commandTabletOn and not openModeItemOnly then return end

    local reason
    if not commandTabletOn then
        reason = "Config.Features.CommandTablet is off, so the tablet's own grant/revoke controls are not even registered"
    else
        reason = "Config.CommandTablet.openMode is 'item', so the tablet has no chat-command fallback -- it is reachable only by an inventory item this resource cannot verify you have actually configured"
    end

    print(
        ("[John-K9] WARNING: %s. Config.FeatureControl.RequireGrant currently requires an explicit per-person " ..
         "grant before ANYONE (including you) can use: %s. These are NOT ungrantable -- use the /k9grantpermission " ..
         "[citizenid] [permissionKey] and /k9revokepermission [citizenid] [permissionKey] chat commands instead " ..
         "(e.g. /k9grantpermission ABC12345 feature.BiteAndHold). They require the exact same High Command rank " ..
         "the tablet does, nothing looser or different. If you meant to use the tablet for this, turn " ..
         "Config.Features.CommandTablet back on and, if you rely on the 'item' open mode, either add a " ..
         "chat-command fallback by setting Config.CommandTablet.openMode to 'command' or 'both', or confirm " ..
         "Config.CommandTablet.itemName is really registered in your ox_inventory items table."
        ):format(reason, table.concat(featureNames, ', '))
    )
end)

-- ======================================================================
-- CACHE LIFECYCLE -- warm on load/reconnect, evict on disconnect. Mirrors
-- server/certifications/'s own PlayerLoaded/playerDropped handlers and
-- server/main.lua's onResourceStart backfill loop exactly.
-- ======================================================================

--- Warms PermissionCache for a freshly-loaded (or freshly-connected, across
--- a resource restart -- see the onResourceStart backfill below) player.
--- CONFIDENCE NOTE carried over from server/certifications/: this event
--- name is used with medium-high confidence based on established Qbox/
--- QBCore convention, not independently verified against live qbx_core
--- source in this sandbox.
AddEventHandler('QBCore:Server:PlayerLoaded', function(Player)
    if not Player or not Player.PlayerData then return end
    local citizenid = Player.PlayerData.citizenid
    if citizenid then
        RefreshPermissionCache(citizenid)

        -- FEATURE-BLOCK PUSH ON CONNECT -- see "FEATURE-BLOCK PUSH" above.
        -- This is trigger #1 of client/featureblocks.lua's own documented
        -- two: every fresh connection/reconnect gets this citizenid's
        -- current block set immediately, before they can act on any of the
        -- twelve client-only features. Fired AFTER RefreshPermissionCache
        -- above so this reads this citizenid's own, current, just-warmed
        -- cache entry, never stale leftover state from a previous session.
        --
        -- ORDERING, DISCLOSED: this fires the instant QBCore reports the
        -- player loaded, which this resource's own established convention
        -- (server/appearance.lua's identical PlayerLoaded-time push,
        -- server/certifications/'s own confidence note on this same
        -- event) already treats as safe for a push -- client-side resources
        -- start streaming, and run their own top-level RegisterNetEvent
        -- calls, well before a connecting player finishes loading in, so
        -- client/featureblocks.lua's handler is already registered by the
        -- time this fires for the ORDINARY join/reconnect case this handler
        -- exists for. The one case this does NOT cover -- a resource
        -- restart's client half racing this same push -- is handled
        -- separately below (onResourceStart) and by the client-initiated
        -- 'john-k9:server:requestFeatureBlocksSync' pull further down
        -- this file, not by adding complexity here.
        PushFeatureBlocksToSource(Player.PlayerData.source, citizenid)
    end
end)

--- Evicts `citizenid`'s cache entry on disconnect -- see this file's header
--- "CACHING" section: an entry for a now-offline citizenid is never read
--- again until PlayerLoaded repopulates it fresh, so dropping it here is
--- purely a bounded-memory concern, same reasoning
--- server/certifications/'s own playerDropped handler gives for
--- Certifications.
AddEventHandler('playerDropped', function(_reason)
    local src = source
    local Player = exports.qbx_core:GetPlayer(src)
    local citizenid = Player and Player.PlayerData and Player.PlayerData.citizenid
    if citizenid then
        PermissionCache[citizenid] = nil
        -- COULD-NOT-DETERMINE HANDLING (lifecycle QA pass): same
        -- bounded-memory-growth reasoning, applied to the bookkeeping flag
        -- that backs the operator message and the resync sweep. A
        -- disconnected citizenid has no live source for that sweep to act
        -- on anyway; their next PlayerLoaded re-attempts the read fresh.
        PermissionCheckUnresolved[citizenid] = nil
    end
end)

--- Backfill for players already connected across a resource restart --
--- mirrors server/main.lua's identical backfill loop for
--- RefreshCertificationCache verbatim (same GetPlayers()/tonumber/
--- exports.qbx_core:GetPlayer shape), since no fresh PlayerLoaded event
--- fires for a player who was already online before this resource
--- (re)started.
AddEventHandler('onResourceStart', function(resourceName)
    if GetCurrentResourceName() ~= resourceName then return end

    -- WAITS FOR THE SCHEMA-COLLISION PROBE TO SETTLE FIRST (boot-order-race
    -- audit, this pass -- same fix already shipped for
    -- server/certtiers.lua/server/permissionkeycatalog.lua/server/xptiers.lua/
    -- server/k9profiles.lua, simply missed here when it landed for those
    -- four -- see server/datastore.lua's own "BOOT-ORDER SETTLEMENT" header
    -- for the exact race this closes). RefreshPermissionCache below
    -- (K9Store.Perm_GetActiveForCitizen) reads a single column from
    -- k9_permissions -- narrower than the full column set that table is
    -- checked against -- so without this, this loop could warm every
    -- already-connected officer's permission/feature-block cache straight
    -- from a foreign table the full probe would correctly reject as a
    -- collision, during the one window before that probe's own yielding
    -- query has returned. On a `false` return (the probe genuinely had not
    -- settled within the wait budget), this skips every citizenid below
    -- rather than trust an unconfirmed database state -- identical to
    -- RefreshPermissionCache's own existing fail-closed posture on any
    -- other read failure (an empty cache entry, never a stale/guessed one)
    -- -- the next PlayerLoaded, or a restart once the check has had time to
    -- finish, re-syncs it as normal.
    if not K9Store.WaitForSchemaCheckToSettle() then
        print('[John-K9] permissions: the schema-collision check had not finished within its wait budget -- skipping this restart\'s permission-cache backfill for every already-connected officer (no database read attempted, exactly like Config.Database.enabled = false) rather than trust a database state that is not yet confirmed safe. The next PlayerLoaded (or a restart once the check has had time to finish) re-syncs it as normal.')
        return
    end

    -- BLOCK STATE CANNOT BE VERIFIED (security pass, this pass) -- the
    -- loud, once-per-boot half of HasPermission's own "MEMORY-MODE BLOCK
    -- ASYMMETRY" doc comment above; read that first for the full "why"
    -- this exists at all. Folded into THIS handler (rather than a new,
    -- separate `onResourceStart` registration) specifically so it reuses
    -- the WaitForSchemaCheckToSettle() call immediately above instead of
    -- parking a SECOND independent coroutine on that same wait -- this
    -- file already has exactly one participant in the boot-order-race
    -- sequence tests/permissionkeycatalog_spec.lua's own "BOOT-ORDER RACE"
    -- section hand-counts (`resumeNext()` calls, one per parked handler,
    -- in registration order); adding a second one here would silently
    -- desync that count for every file that registers its own
    -- onResourceStart AFTER this one in fxmanifest.lua's load order, not
    -- just fail loudly in a test made specifically to catch drift like it.
    --
    -- FIRES ONLY ONCE, on THIS handler's own single pass -- HasPermission's
    -- own fail-closed behavior above does NOT depend on this print running
    -- (it reads K9Store.IsDatabaseEnabled('k9_permissions') fresh, every
    -- call, on its own) -- this exists purely so the operator is told WHY
    -- every 'block.<Name>' feature just started denying everyone, in one
    -- place, instead of having to notice it from missing tablet
    -- functionality.
    -- NARROWED to the two causes that actually still fail closed (see
    -- HasPermission's own CASE 0 above): a schema collision, or this table
    -- missing from an otherwise-installed database. Deliberate memory-only
    -- mode (Config.Database.enabled = false, the shipped default) no longer
    -- blocks anyone, so warning about it here would be telling the operator
    -- their features are off when they are not -- the exact false alarm
    -- that made a real lockout hard to spot.
    local deliberateMemoryMode = type(K9Store.IsDatabaseConfiguredOff) == 'function'
        and K9Store.IsDatabaseConfiguredOff() == true

    if Config.Features and Config.Features.PermissionGrants == true
        and not deliberateMemoryMode and not K9Store.IsDatabaseEnabled('k9_permissions') then
        print(
            '[John-K9] permissions.lua WARNING: k9_permissions is unreadable this session even though this ' ..
            'server is configured to use a database (see server/datastore.lua\'s own boot message above for ' ..
            'exactly why -- this one table missing from an otherwise-intact database, or a schema collision. ' ..
            'Config.Database.enabled = false is NOT one of the causes any more: deliberate memory-only mode is ' ..
            'a normal, fully-working mode and blocks nobody). Any per-person ' ..
            '`block.<Name>` restriction granted before this restart cannot be verified right now, so -- to avoid ' ..
            'silently handing access back to someone a human admin specifically restricted -- EVERY block-gated ' ..
            'feature is being treated as BLOCKED FOR EVERYONE for the rest of this session, regardless of who ' ..
            'was actually on a block list. Certifications, XP, positive permission/feature grants, and every ' ..
            'feature NOT gated by a per-person block are completely unaffected and continue to work normally. ' ..
            'TO FIX: restore k9_permissions (see server/datastore.lua\'s own TO FIX instructions) and restart ' ..
            'this resource -- every block-gated feature resumes normal per-person enforcement the moment that ' ..
            'table is reachable again.'
        )
    end

    for _, playerId in ipairs(GetPlayers()) do
        local src = tonumber(playerId)
        if src then
            local Player = exports.qbx_core:GetPlayer(src)
            if Player and Player.PlayerData and Player.PlayerData.citizenid then
                RefreshPermissionCache(Player.PlayerData.citizenid)

                -- FEATURE-BLOCK PUSH ON RESOURCE RESTART -- see
                -- "FEATURE-BLOCK PUSH" above. 'QBCore:Server:PlayerLoaded'
                -- never fires again for a player who was already connected
                -- BEFORE this resource (re)started, so this backfill loop is
                -- this citizenid's only immediate re-sync opportunity --
                -- without this, an officer already online when john-k9
                -- restarts would keep whatever stale block state (or total
                -- absence of one) survived the restart until their next full
                -- reconnect.
                --
                -- ORDERING, DISCLOSED, NOT SOLVED HERE: this server-side
                -- onResourceStart and that SAME player's client-side
                -- onClientResourceStart are two independent events with no
                -- ordering guarantee between them -- this push can still
                -- race a client that has not finished (re)registering its
                -- own RegisterNetEvent('john-k9:client:featureBlocksSync',
                -- ...) handler yet. This push is still worth sending
                -- unconditionally (best effort, free of charge, correct in
                -- the common case), but the genuine fix for that race is the
                -- client-initiated 'john-k9:server:requestFeatureBlocksSync'
                -- pull further down this file, which client/featureblocks.lua's
                -- own owner is asked to call once that file's own
                -- onClientResourceStart (if/when it adds one) has finished
                -- registering -- see this pass's own hand-off report.
                PushFeatureBlocksToSource(Player.PlayerData.source, Player.PlayerData.citizenid)
            end
        end
    end
end)

-- ======================================================================
-- FEATURE-BLOCK PUSH -- CLIENT-INITIATED RE-REQUEST. See "FEATURE-BLOCK
-- PUSH" above for the two SERVER-initiated triggers (PlayerLoaded,
-- onResourceStart backfill) and their own disclosed ordering caveat: either
-- one can race a client resource that has not finished (re)registering its
-- own RegisterNetEvent('john-k9:client:featureBlocksSync', ...) handler
-- yet -- most concretely a bare CLIENT-side script restart with the server
-- resource left running, which fires no server-observable event this file
-- could hang a push on at all.
--
-- This is this file's answer to that gap: a plain, CLIENT-initiated pull.
-- Because the request originates FROM the client that wants the answer, it
-- structurally cannot arrive before that same client is ready to receive
-- the reply -- unlike a server-initiated push, there is no ordering race to
-- solve here at all. client/featureblocks.lua's own owner is asked to fire
-- `TriggerServerEvent('john-k9:server:requestFeatureBlocksSync')` once at
-- that file's own top-level load (covers a normal resource start/restart,
-- redundantly with the pushes above -- redundant is fine, see below) AND
-- again from inside an `AddEventHandler('onClientResourceStart', ...)`
-- handler if that file adds one (covers a client-only restart) -- see this
-- pass's own hand-off report for the exact two-line request; NOT added
-- here, since client/featureblocks.lua has a live owner this pass.
--
-- NO COOLDOWN, unlike GrantPermission/RevokePermission's
-- PERMISSION_ACTION_COOLDOWN_MS -- deliberately: this is a read-only,
-- sub-millisecond in-memory table read (GetActiveBlockedFeatureNames above
-- never touches the DB), expected to fire at most a handful of times per
-- player per session, not a repeatable write a fat-fingering or malicious
-- caller could abuse to change persisted state. Calling it twice in a row
-- (a late reply racing a duplicate request, or simply an operator's own
-- resource restart firing both the onResourceStart push above AND this
-- request) is harmless BY CONSTRUCTION: GetActiveBlockedFeatureNames
-- rebuilds the full array fresh from PermissionCache every single call, so
-- two identical pushes back to back are simply two identical, idempotent
-- full replacements -- never a merge, never double-counted -- exactly
-- matching client/featureblocks.lua's own documented "full reassignment,
-- not a merge" handling on the receiving end.
--
-- Resolves `citizenid` from `source` itself -- never trusts a client-
-- supplied identity, matching every other RegisterNetEvent handler in this
-- resource. If that resolves to nothing (this fires before this
-- connection's own QBCore player object exists yet, e.g. during character
-- selection), this is a silent no-op: client/featureblocks.lua's own
-- ClientFeatureBlocks starts empty and fails OPEN, so "no reply yet" is
-- already the correct, safe answer -- there is no unblocked state to
-- correct here, unlike a mutating action that would need to report a
-- failure back to a caller.
-- ======================================================================
RegisterNetEvent('john-k9:server:requestFeatureBlocksSync', function()
    local src = source
    local Player = exports.qbx_core:GetPlayer(src)
    local citizenid = Player and Player.PlayerData and Player.PlayerData.citizenid
    if not citizenid then return end
    PushFeatureBlocksToSource(src, citizenid)
end)

-- ======================================================================
-- COULD-NOT-DETERMINE RESYNC SWEEP (lifecycle QA pass, this pass) --
-- mirrors server/certifications/'s own resync sweep for
-- CertificationCheckUnresolved, applied here to PermissionCheckUnresolved.
-- See RefreshPermissionCache's own doc comment for the full contract this
-- closes the loop on: a citizenid left unresolved by a transient query
-- failure (most likely during the onResourceStart backfill loop's own
-- tight burst, or an unlucky immediately-after-grant/revoke re-read) must
-- recover WITHOUT needing to reconnect.
--
-- ALWAYS RUNS, UNCONDITIONALLY -- not gated behind
-- Config.Features.PermissionGrants: PermissionCheckUnresolved can gain
-- entries from RefreshPermissionCache regardless of that flag's current
-- value (RefreshPermissionCache itself has no such gate -- HasPermission is
-- what re-checks the flag, on every read), so a thread gated on it could
-- start already missing entries created before the flag was last flipped.
-- Matches this resource's own established "a thread governed by something
-- that can change at runtime starts unconditionally and re-checks that
-- thing fresh inside the loop" convention -- see
-- server/certifications/'s own resync sweep and
-- server/runtimecontrol.lua's FEATURE_TIERS entry on server/combat.lua's
-- maintenance threads for the precedent. Cheap on an idle server either
-- way: the overwhelmingly common case is an EMPTY PermissionCheckUnresolved
-- table.
-- ======================================================================

local PERM_RESYNC_SWEEP_INTERVAL_MS = 30000

--- One resync pass: retries RefreshPermissionCache for every citizenid
--- currently recorded in PermissionCheckUnresolved, but ONLY for a
--- citizenid who is CURRENTLY ONLINE -- matching RefreshPermissionCacheIfOnline's
--- own SCOPE (an offline citizenid gets no cache entry at all by design,
--- and their next PlayerLoaded already attempts a fresh read from a clean
--- state). A successful retry needs no separate bookkeeping here:
--- RefreshPermissionCache itself clears PermissionCheckUnresolved[citizenid]
--- the instant it confirms ANY answer -- this function only needs to keep
--- calling it, and push a fresh feature-block sync when it does, so a
--- citizenid stuck on a stale/absent block set sees the correction
--- immediately rather than only on their next login or grant/revoke touch.
local function ResyncUnresolvedPermissions()
    for citizenid in pairs(PermissionCheckUnresolved) do
        local onlinePlayer = exports.qbx_core:GetPlayerByCitizenId(citizenid)
        local targetSrc = onlinePlayer and onlinePlayer.PlayerData and onlinePlayer.PlayerData.source
        if type(targetSrc) == 'number' then
            RefreshPermissionCache(citizenid)
            if not PermissionCheckUnresolved[citizenid] then
                -- Confirmed this pass -- push the corrected block set now
                -- rather than waiting for this citizenid's next
                -- login/grant/revoke touch.
                PushFeatureBlocksToSource(targetSrc, citizenid)
            end
        end
    end
end

CreateThread(function()
    while true do
        Wait(PERM_RESYNC_SWEEP_INTERVAL_MS)

        -- Cheap early-exit, checked fresh every tick -- see this sweep's
        -- own header above for why this table is expected to be empty
        -- essentially always.
        if next(PermissionCheckUnresolved) ~= nil then
            local ok, err = pcall(ResyncUnresolvedPermissions)
            if not ok then
                print(('[John-K9] permissions.lua: permission resync sweep tick error: %s'):format(tostring(err)))
            end
        end
    end
end)
