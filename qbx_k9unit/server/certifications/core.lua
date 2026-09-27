--[[
    qbx_k9unit/server/certifications/core.lua

    Certification records, the in-memory cache, K9 access resolution,
    and granting/revoking a certification.

    PART OF A SPLIT FILE. server/certifications/ was 6,012 lines doing
    four separate jobs at once, and it is the file most likely to be edited
    (it is how anyone gets K9 access at all). It is now four files loaded in
    this order, and the dependency flow between them is strictly one-way,
    which is what made the split safe:

        core.lua      -> depth.lua -> accessors.lua -> commands.lua

    HOW THE PIECES REACH EACH OTHER. Lua locals do not cross files, so each
    file publishes what the later ones need onto the shared `K9Cert` table
    at its end, and each later file re-binds those names as locals at its
    top. That re-binding is deliberate: it keeps every function body
    BYTE-IDENTICAL to what it was in the single file, so this split moved
    code without rewriting a single call site. `K9Cert` is a transport
    between these four files only -- it is not a public API, and nothing
    outside server/certifications/ should read it.

    The genuinely public surface is unchanged and still global, exactly as
    before: HasK9Access, IsConfiguredK9Model, RefreshCertificationCache,
    GetCertificationTier, MeetsTierRequirement, HasSpecialization,
    QueryCertificationRecord and QueryActiveSpecializations.
]]

K9Cert = K9Cert or {}

--[[
    qbx_k9unit/server/certifications/

    Phase 1 scaffold only (coder-architect). This file IS the permission
    system (DEVELOPER_REFERENCE.md hard requirement 2) — grant/revoke/check, the
    server-side cert cache, and the automatic revoke-on-job-change path.
    Keep it scoped to "who is allowed to use K9 features" only; misc
    small gated K9 actions (e.g. bark relay) live in server/main.lua so
    this file doesn't balloon as later phases add more of those.

    ======================================================================
    EVENT/CALLBACK CONTRACT — Phase 1, REWRITTEN after DEVELOPER_REFERENCE.md's post-draft
    correction (K9 is a player's own persistent character, no spawn/despawn/
    registry concept at all — see DEVELOPER_REFERENCE.md §1, §2 "Explicit non-goals").
    This block is identical in every stub file it's relevant to, so
    coder-backend and coder-frontend can work in parallel without live
    coordination.

    Callbacks (ox_lib lib.callback):
    1. 'qbx_k9unit:server:hasK9Access' () -> boolean [THIS FILE]
       job.name ∈ Config.Departments AND active cert cached for that exact
       job (OR autoAccessGrade bypass). Per DEVELOPER_REFERENCE.md §4.1/§4.5: this is the
       ONLY access check, and it does NOT consider ped model at all — model
       is checked exclusively at grant time (§4.2 condition 5, below), not
       on every access. A certified handler who later isn't K9-modeled
       still passes this check (client-side display logic hides the UI for
       them anyway, see client/main.lua's IsOwnModelK9(); this is a known,
       spec-confirmed tradeoff, not a bug — flagged for coder-security to
       be aware of, not to "fix" unprompted).

    Server events (RegisterNetEvent, client->server):
    2. 'qbx_k9unit:server:certifyHandler' (targetServerId: number) [THIS FILE]
       Grant flow per DEVELOPER_REFERENCE.md §4.2/§4.3 — re-validate granter eligibility,
       target eligibility (job membership, model, per §4.2), and
       Config.CertifyProximityMeters proximity via live server-side
       coordinates, never client-claimed.
    3. 'qbx_k9unit:server:revokeHandler' (targetServerId: number) [THIS FILE]
       Same re-validation as certify MINUS the model check (§4.2 item 5 —
       "applies to grant only, not revoke").
    4. 'qbx_k9unit:server:relayBark' (barkType: string) [server/main.lua]

    Client events (RegisterNetEvent, server->client):
    5. 'qbx_k9unit:client:playBark' (netId: number, barkType: string) [client/main.lua]

    Commands (server-registered, call the same internal function as events 2/3):
    6. '/k9certify [targetServerId]' [THIS FILE]
    7. '/k9decertify [targetServerId]' [THIS FILE]
    7b. '/k9decertifyoffline [citizenid] [job]' [THIS FILE] — closes the
        online-only gap in event 3/command 7's numeric targetServerId
        contract (DEVELOPER_REFERENCE.md §4.3 requires revocation to work on a target who
        is genuinely disconnected, and a disconnected player has no live
        server id at all — see RevokeCertificationOffline below). No
        client-reachable event equivalent exists, nor should one: a
        disconnected target has no client to trigger anything from, so
        this is command-only, unlike certify/revoke which also expose net
        events 2/3. SECURITY: this path skips the proximity check only
        because it's the ONLY way to reach a genuinely disconnected
        target — RevokeCertificationOffline therefore verifies the
        citizenid actually resolves to no currently-connected player
        before doing anything, and refuses (pointing the caller at
        /k9decertify instead) if the "offline" target turns out to be
        online right now. Without that guard this command would be a
        drop-in proximity-check bypass for revoking an online target from
        anywhere on the map — found and fixed in this pass.

    Automatic, server-only path (no client entry point at all):
    8. AddEventHandler('QBCore:Server:OnJobUpdate', function(source, job) ... end)
       [THIS FILE] — auto-revoke on leaving the department (§4.4).

    REMOVED from the original (pre-correction) scaffold — do not resurrect:
    'qbx_k9unit:server:requestSpawnK9' callback, 'qbx_k9unit:server:registerK9'
    / 'unregisterK9' events, 'qbx_k9unit:client:despawnK9' event, any
    "current K9" netId registry, Config.K9DespawnGraceSeconds. All were
    artifacts of the incorrect NPC-spawn model.

    Cross-cutting security rule (DEVELOPER_REFERENCE.md §3 + §4.3): every access point
    above must re-check server-side, independent of client claims. This is
    THE file coder-security should scrutinize hardest — see the explicit
    security note quoted from DEVELOPER_REFERENCE.md §4.3 below.
    ======================================================================

    DEVELOPER_REFERENCE.md §4.3 explicit security note (quoted): "every one of the
    mechanisms above (grant, manual revoke, check) must re-verify on the
    server, independent of what the requesting client claims about its own
    job, rank, proximity, or ped model. The client-side ox_target option
    visibility and command availability are UX conveniences only, not
    access control — a modified client calling the server event directly
    with an arbitrary target id must still be rejected by the server-side
    checks in §4.2 and §4.3. The automatic revoke path (§4.4) is
    server-triggered and has no client-reachable entry point at all."

    MINOR SPEC INCONSISTENCY, PREVIOUSLY FLAGGED, NOW CORRECTED (issue-closer
    sweep): §4.1's access-rule paragraph used to say access is "checked
    server-side on every access point (menu open request *and* the actual
    spawn request — not just once)" — "the actual spawn request" was
    leftover text from the pre-correction draft, since there is no spawn
    request anymore. DEVELOPER_REFERENCE.md §4.1 has since been reworded ("checked
    server-side on every gated action that grants a real capability ...
    not cached client-side as a one-time pass") and no longer contains the
    stale clause — nothing left to flag here.

    FILE-TO-FILE CONTRACT:
    - THIS FILE exposes three resource-global (no `local`) functions:
        HasK9Access(source) -> boolean
            Called by server/main.lua's relayBark handler (and any future
            Phase 2+ gated action added there) and by the hasK9Access
            callback below. Keep this the SINGLE source of truth for "is
            this player allowed to use K9 features right now" — do not
            duplicate the job/cert logic anywhere else.
        RefreshCertificationCache(citizenid, jobName)
            Re-queries the active-cert row for (citizenid, jobName) and
            updates the in-memory cache. Called from: (a) this file's own
            player-loaded and job-update hooks, and (b) server/main.lua's
            onResourceStart backfill loop (see that file — a resource
            restart while players are already online needs to warm the
            cache for them too, since no fresh player-loaded event fires
            for already-connected players).
        IsConfiguredK9Model(modelHash) -> boolean
            Used here for the §4.2 item 5 grant-time model check, and reused by
            server/main.lua's leash-role determination (§6.1/§9 item 3b —
            leash roles are assigned by which party is actually K9-modeled,
            server-verified, never client-claimed) — one shared model
            check instead of two independent copies of Config.Peds logic.
    - THIS FILE calls `ForceDetachLeashForSource(src, reason)` (server/main.lua),
      `EndActiveEffectForHolder(src)` (server/combat.lua, guarded), and
      `ForceBreakPartnershipForCitizenId(citizenid, reason)`
      (server/partnership.lua, Phase 3, DEVELOPER_REFERENCE.md §12.0 item
      7, guarded) — ALL THREE, ALWAYS TOGETHER — through this file's own
      LOCAL helper `EndK9AccessForCitizenId(citizenid, reason, knownSrc)`,
      defined once (above HasK9Access's own eligibility helpers) and
      called from every path that flips a citizenid's K9-role access to
      lost: RevokeCertification's online branch, RevokeCertificationOffline,
      and all THREE of the QBCore:Server:OnJobUpdate handler's branches —
      department-loss, the same-department autoAccessGrade-loss branch, and
      cert-revoke-due-to-job-change. CONSOLIDATION (this pass, cross-team
      "four doors, one bug" finding): this exact three-call sequence used
      to be reimplemented independently at each of those five call sites,
      which is why the "handler loses K9 access mid-incident and their dog
      keeps holding a suspect" bug kept being found and fixed one call site
      at a time — most recently the department-loss branch, which used to
      call ONLY ForceDetachOfficerLeashForSource (the officer/handler-role
      leash, a DIFFERENT invariant kept as its own direct call, never
      folded into this helper) and never this sequence at all, leaving a
      K9-role party whose only access route was autoAccessGrade or a
      server/permissions.lua 'k9.access' grant (no certification row) able
      to keep their leash/hold/partnership on leaving the department
      entirely — see that branch's own comment, and
      EndK9AccessForCitizenId's own doc comment, for the full writeup and
      why this is now the ONE place in this file meaning "citizenid has
      just, provably, lost K9-role access." server/permissions.lua's
      RevokePermission needs the identical sequence for its own
      'k9.access' de-assign path and keeps its OWN private, identically-
      shaped copy rather than sharing this one as a resource-global — see
      that file's own copy for why (in short: doing otherwise would need a
      new fxmanifest.lua server_scripts entry AND a new
      /home/user/FIvem/.luacheckrc globals entry, and this resource's own
      spec files load only the minimal file set each one's file-under-test
      needs). All three underlying calls stay guarded at
      `type(...) == 'function'` runtime existence checks (this resource's
      established "runtime existence guard, not a load-order assumption"
      convention — see fxmanifest.lua's own comment on server/search.lua's
      AwardXP reuse for the precedent), and are called UNCONDITIONALLY
      of Config.Features.HandlerPartnership's current value — a partnership
      row established while the feature was on must still be torn down by
      a cert revoke/department change even if the flag was later flipped
      off, since ForceBreakPartnershipForCitizenId is itself already a
      cheap, safe no-op when `citizenid` has no active partnership row to
      tear down.
    - THIS FILE calls `ApplyK9AppearanceOnGrant(targetCitizenid, granterCitizenid, modelName?)`
      and `MaybeRevertK9Appearance(citizenid)` (both server/appearance.lua,
      coder-architect's K9 role/model decoupling pass), both guarded by the
      same `type(...) == 'function'` runtime existence check as every other
      cross-file call in this section. SECURITY FIX, this pass (coder-security
      "prove role and model are genuinely separate, everywhere" audit):
      server/appearance.lua's own header already documented these as being
      called from THIS file — ApplyK9AppearanceOnGrant from
      GrantCertification/GrantCertificationOffline's success paths, and
      MaybeRevertK9Appearance from all FIVE of EndK9AccessForCitizenId's own
      call sites above — but neither call actually existed anywhere in this
      file until now. server/permissions.lua's GrantPermission/RevokePermission
      already had the identical pair wired correctly for the 'k9.access'
      grant path, so the documented "certifying someone (or granting
      k9.access) actually turns their character into the ped" promise
      (Config.K9Appearance.applyPedModelOnCertify, README.md "How a K9 gets
      made") only ever worked through ONE of the resource's two documented
      "how a K9 gets made" doors — a plain `/k9certify` grant (or the
      "Certify K9 Handler" ox_target option) never applied the model at all,
      and revoking a certification that was a citizenid's ONLY route to the
      role never reverted it either, permanently stranding the K9 ped model
      on that citizenid with no other code path left to ever clear it. Fixed
      by adding the call at each of the two grant success paths and each of
      the five EndK9AccessForCitizenId call sites — see each call site's own
      doc comment for why it is safe (MaybeRevertK9Appearance's own
      IsCertifiedK9ForAnyJob/HasPermission reconciliation already no-ops
      correctly whenever a separate credential still justifies keeping the
      appearance, so calling it from every loss site, even ones that don't
      end up reverting anything, is inert rather than double-reverting).
    - THIS FILE owns `Certifications` (citizenid -> { active: boolean,
      job: string }) as a local table. STRUCTURAL NOTE: DEVELOPER_REFERENCE.md §4.3's
      prose describes this cache as a bare `Certifications[citizenid] =
      true|false`, but §4.4's auto-revoke handler needs to know WHICH job
      that boolean was scoped to (to tell "left the department" apart from
      "got promoted within it") — §4.3 and §4.4 are only reconcilable if
      the cache also tracks job. Decision: store `{ active, job }` instead
      of a bare boolean; it's a strict superset of what §4.3 asked for and
      avoids a second parallel cache that could drift out of sync.
    - COULD-NOT-DETERMINE (lifecycle QA pass): `Certifications[citizenid]`
      being ABSENT is now a meaningfully different state from `{ active =
      false, job = ... }` being PRESENT — the former means "no confirmed
      answer exists yet" (a fresh login/backfill that has not been checked,
      or a checked-and-failed read with nothing to fall back on); the
      latter means "the database was actually asked and said no." Every
      access-relevant reader in this file already treats both the same way
      for the purposes of DENYING access (a `cached and cached.active`
      pattern, unaffected by this note) — that is still correct and is not
      what changed. What changed is that RefreshCertificationCache no
      longer WRITES the absent case as if it were the confirmed-false one
      on a transient query failure — see that function's own doc comment,
      and the "COULD-NOT-DETERMINE HANDLING" section directly above it, for
      the full retry/bookkeeping/resync-sweep mechanism this enables.

    ======================================================================
    CERTIFICATION DEPTH (this pass) — DEVELOPER_REFERENCE.md Part A §2 (revoke
    reason), §5 (tiered certification), §9 (expiry/recertification), and
    Part B §11 (specializations). These four are ONE coherent change: they
    all reshape "certified" from a boolean into something with a level
    (tier), a scope (specializations), and a lifetime (expiry), on top of
    an unchanged deeper audit trail (revoke_reason). Schema: migration
    0006 (sql/migrations/0006_add_k9_certification_lifecycle.sql) adds
    `tier`/`revoke_reason`/`expires_at` to `k9_certifications` and a new
    sibling table `k9_certification_specializations` — see that file's own
    header for the full compatibility story; summarized here for anyone
    reading only this file.

    COMPATIBILITY (the hard requirement this pass is built around): an
    existing certified handler stays certified and fully functional with
    NO operator action. `tier` defaults to 'certified' for every existing
    row (the migration's DEFAULT, not code here) — 'certified' is chosen,
    not 'trainee', because it is the ordinal tier that preserves today's
    actual capability (everything Phase 1/2/3 already gates behind plain
    HasK9Access). `expires_at` stays NULL for every pre-existing row
    forever unless a certifier explicitly renews it — a certification
    never silently starts a countdown it didn't have before. The whole
    expiry mechanism is additionally gated behind
    `Config.Features.CertificationExpiry` (default false, off until an
    operator opts in).

    TIER (§5): a fixed, HARDCODED 3-step ordinal — trainee < certified <
    senior (TIER_RANK below) — deliberately NOT a Config table. Real K9
    tiering is a small, fixed vocabulary; making it configurable would let
    an operator invent tier names no future Phase 2/3 gate could rank
    against, for no real benefit — "an operator can hold the model in
    their head" (this task's own instruction) argued directly against an
    open-ended list here. HasK9Access (base access — leash/radial/basic
    locomotion) is UNCHANGED by tier: every tier, including 'trainee',
    passes it, matching §5's own framing ("trainee gets... basic
    locomotion only" — i.e. still has *some* K9 access). Tier only gates
    which HIGHER capability a future Phase 2/3 file chooses to check via
    the new `GetCertificationTier`/`MeetsTierRequirement` accessors below
    — this file does not itself gate any Phase 2/3 mechanic on tier; that
    wiring belongs to whichever file owns that mechanic (search.lua,
    combat.lua, defense.lua), reported separately rather than reached into
    here. Tier is changed via the new `SetCertificationTier` action, kept
    DELIBERATELY SEPARATE from GrantCertification (which still always
    creates a plain 'certified' row exactly as before, so its own,
    extensively tested INSERT/signature never changes) — a certifier who
    wants a different initial tier calls SetCertificationTier immediately
    after granting.

    SUPERSEDED, 2026-08-25 (owner-directed reversal — see
    server/certtiers.lua's own header for the full writeup; THIS PARAGRAPH
    IS KEPT, NOT DELETED, per that pass's own instruction to record why
    the reasoning above no longer applies rather than erase it): the
    "deliberately NOT a Config table" argument two paragraphs up was
    correct for a small, permanently-fixed vocabulary nobody would ever
    need to extend. It stops applying the moment the owner asks for the
    opposite — "Allow high command to edit the tiers trainee certified
    senior etc add more roles edit permissions for those roles etc." The
    tier catalog (key/label/ordinal/capabilities) is now data, owned by
    server/certtiers.lua — Config.CertificationTiers for the DEFAULTS
    (which preserve these exact three keys/ordinals, so an operator who
    never opens the tablet sees zero behavior change), the
    `k9_certification_tiers`/`k9_certification_tier_capabilities`
    database tables for high command's runtime edits (the DB wins). The
    literal `TIER_RANK` table immediately below is UNCHANGED and STILL
    LIVE — not vestigial — as the explicit LEGACY FALLBACK every tier
    accessor in this file now degrades to only if server/certtiers.lua's
    own accessors are unavailable (see IsKnownTierKeyOrLegacyFallback/
    GetTierOrdinalOrLegacyFallback below). `SetCertificationTier`'s own
    signature and every call site are UNCHANGED by this — it still takes
    a plain tier-key string; it now simply accepts any key the live
    catalog currently recognizes instead of only these original three.

    REVOKE REASON (§2): an OPTIONAL third argument on RevokeCertification/
    RevokeCertificationOffline and their net-event/command entry points —
    fully backward compatible (nil/omitted behaves exactly as before: a
    NULL `revoke_reason`, same as every historical row). Validated against
    a fixed vocabulary (VALID_REVOKE_REASONS below: retired, reassigned,
    disciplinary, performance, other) — a small fixed set was chosen over
    free text for the same "tablet can render it, operator can hold it in
    their head" reason tier used a fixed set. The automatic
    QBCore:Server:OnJobUpdate auto-revoke path always records
    'reassigned' — an accurate, non-punitive category for "this handler
    changed department," distinct from the mechanism tag ('job_changed')
    already carried on the outbound event.

    EXPIRY (§9) — LIVE-BEHAVIOUR DESIGN CHOICES, STATED EXPLICITLY per
    this task's own instruction:
      1. A certification does NOT force-detach an active leash / interrupt
         an in-progress ability the instant it lapses. Manual revoke keeps
         its existing "immediately" teardown (a human made a deliberate
         right-now decision) — passive time-based expiry is a paperwork
         lapse, not a disciplinary action, and forcibly ripping a K9 off
         an active pairing over an expired form is exactly the harsh
         "silently lapsing mid-shift" experience this task warned against.
         HasK9Access simply stops granting NEW access once expired; an
         already-formed leash/partnership/in-progress action is untouched
         by this file.
      2. Warned ahead of time. An online handler within
         Config.CertificationExpiryWarningDays of their expiry gets a
         one-per-session ox_lib notice (`certifications.expiry_warning`).
         The moment expiry is actually crossed, an online handler gets a
         second, one-time notice (`certifications.expiry_lapsed_notice`)
         PROACTIVELY — not left to discover it only when an ability stops
         working. Both are driven by TickCertificationExpiryWarnings, a
         background sweep (Config.CertificationExpiryCheckIntervalMs,
         same config-driven-interval + fallback-on-misconfiguration
         pattern as server/tenure.lua's own tick loop) over currently
         connected players' cached state — never a live per-access SQL
         query.
      3. Wall-clock arithmetic happens IN SQL, never in Lua. Consistent
         with this resource's own established convention
         (server/tenure.lua's `TIMESTAMPDIFF(SECOND, established_at,
         NOW())`) — RefreshCertificationCache reads
         `UNIX_TIMESTAMP(expires_at)` as a plain number once, at refresh
         time; GrantCertification/RenewCertification write
         `DATE_ADD(NOW(), INTERVAL ? DAY)`. The ONLY Lua-side wall-clock
         read is the global `os.time()` (NOT a FiveM native — ordinary
         Lua 5.4 stdlib; FXServer's server runtime is understood to expose
         it, same MEDIUM-HIGH-confidence, not-independently-verified-live
         posture this file's own PlayerLoaded-event-name note already
         discloses), used only to compare against that one cached number.
         If `os.time` were ever unavailable, this file FAILS TOWARD
         AVAILABILITY, not toward lockout — see IsExpiredUnix's own doc
         comment: an optional, off-by-default feature's primitive going
         missing should make that feature silently inert, never lock out
         every certified handler server-wide.

    SPECIALIZATIONS (Part B §11): a SIBLING TABLE
    (`k9_certification_specializations`), not a column, because a
    citizenid may hold MULTIPLE simultaneously-active specializations for
    the same (citizenid, job) — narcotics AND explosives at once is a
    real, ordinary case, which a single column/CSV/JSON convention this
    table's own append-mostly-audit-log design deliberately avoids
    elsewhere. AUTHORIZATION: reuses IsEligibleCertifier UNCHANGED (the
    exact same rank/high-command/`k9.certify`-permission gate as the base
    certification) rather than a new permission key — see "WHY THIS DOES
    NOT REUSE k9_permissions" below for the full reasoning either way.
    Requires an ACTIVE base certification for the same (citizenid, job) to
    already exist (checked against the live Certifications cache, since
    grant requires the target online exactly like GrantCertification) —
    a specialization with no underlying certification is meaningless.
    Revoking/lapsing the BASE certification cascades: every active
    specialization for that (citizenid, job) is bulk-revoked at every one
    of the THREE existing base-revoke call sites (RevokeCertification's
    online branch, RevokeCertificationOffline, and the
    QBCore:Server:OnJobUpdate auto-revoke handler's both branches) via
    RevokeAllSpecializationsForCitizenJob below — mirrors the leash/
    partnership teardown call sites already at each of those exact three
    places.

    WHY THIS DOES NOT REUSE server/permissions.lua's k9_permissions FOR
    SPECIALIZATIONS (argued, not defaulted, per this task's own
    instruction): k9_permissions grants a named capability GLOBALLY per
    citizenid, callable ONLY by high command (IsHighCommand, unconditionally
    — GrantPermission has no lower rank tier at all), with no per-department
    scoping. A specialization is the opposite shape on every one of those
    three axes: it is scoped to one (citizenid, job) pair (a narcotics K9
    in the police department is not automatically narcotics-cleared if
    they later move to sheriff), it should be grantable by an ORDINARY
    certifying officer (the same rank that already grants the base cert —
    requiring every specialization grant to go all the way up to high
    command would make specializations far less usable than the base
    certification they extend), and it is meaningless without an existing
    base certification row to attach to (k9_permissions grants are
    standalone; nothing in that file requires a citizenid to hold anything
    else first). Building specializations on k9_permissions would therefore
    mean either (a) loosening k9_permissions' own high-command-only
    authorization model specifically to accommodate this one new use
    (widening a file this task does not own, for a fit that's still wrong
    on the other two axes), or (b) keeping it high-command-gated and
    shipping a materially less useful feature than the one asked for. Both
    are worse than extending the SAME certifier-grade mechanism the base
    certification itself already uses. `IsEligibleCertifier` is reused
    UNCHANGED (not duplicated) specifically so a citizenid holding the
    'k9.certify' permission grant already gets specialization-granting
    power for free, with no new permission key and no edit to
    permissions.lua at all — this is the one place the two systems DO
    compose, without either becoming a parallel copy of the other.

    CACHE SHAPE, EXTENDED: `Certifications[citizenid]` is now
    `{ active, job, tier, expiresAtUnix, expired }` — see
    RefreshCertificationCache's own doc comment for exactly how/when each
    field is populated. `expiresAtUnix`/`expired` are nil/false
    respectively for a citizenid whose row has no expiry set, which is
    every row on a server that has never turned
    `Config.Features.CertificationExpiry` on, and every pre-existing row
    everywhere else — the identical "additive, does nothing until
    explicitly used" posture as every other extension in this section.
    Specializations get their OWN small cache, `Specializations[citizenid]
    = { [job] = { [specializationKey] = true, ... } }`, populated
    alongside Certifications at the same refresh points (grant/revoke/
    PlayerLoaded/OnJobUpdate) and evicted on `playerDropped` identically.

    CONFIG THIS FILE ASSUMES MAY EXIST (reported to whoever owns
    config.lua for this pass; every read below is defensive — a missing
    key degrades the relevant feature to a clean no-op, never a crash,
    matching this whole section's "must not break an install with none of
    this configured yet" posture):
      Config.Features.CertificationExpiry : boolean (default false)
      Config.CertificationExpiryDays : number (default 90)
      Config.CertificationExpiryWarningDays : number (default 7)
      Config.CertificationExpiryCheckIntervalMs : number (default 300000)
      Config.K9Specializations : table<string, { label: string }>
        (default catalog: narcotics / explosives / patrol)
]]

-- Certifications[citizenid] = { active = boolean, job = string,
--   tier = string ('trainee'|'certified'|'senior'),
--   expiresAtUnix = number? (epoch seconds; nil = never expires),
--   expired = boolean (true once now >= expiresAtUnix; always false when
--     expiresAtUnix is nil) }
-- `job` is whichever department this cached result was scoped to (the
-- player's job at the time of the last refresh). Local: nothing outside
-- this file should read it directly — always go through HasK9Access(source),
-- RefreshCertificationCache(citizenid, jobName), or the read-only
-- GetCertificationTier/MeetsTierRequirement accessors below.
local Certifications = {}

-- Specializations[citizenid] = { [job] = { [specializationKey] = true, ... } }
-- Mirrors Certifications' own lifecycle (refreshed at the same points,
-- evicted on playerDropped) — see "SPECIALIZATIONS" above. Local: go
-- through HasSpecialization/QueryActiveSpecializations below.
local Specializations = {}

-- ExpiryWarned[citizenid] = true once the warn-ahead-of-expiry notice has
-- been sent THIS SESSION (cleared on playerDropped, and on an explicit
-- RenewCertification). ExpiryLapsedNotified[citizenid] = true once the
-- "just expired" notice has been sent THIS SESSION. Both are ephemeral,
-- one-per-session flags, NOT persisted — see header "EXPIRY" item 2 and
-- TickCertificationExpiryWarnings' own doc comment below for the full
-- warning-cadence design.
local ExpiryWarned = {}
local ExpiryLapsedNotified = {}

-- LEGACY FALLBACK ONLY as of the owner-directed tier-editing pass (see
-- header "SUPERSEDED" note above server/certtiers.lua now owns the LIVE
-- tier catalog, config-defaults-plus-database-overrides, EXTENSIBLE at
-- runtime. This table is kept, byte-identical to its original form, as
-- what IsKnownTierKeyOrLegacyFallback/GetTierOrdinalOrLegacyFallback
-- below degrade to ONLY if server/certtiers.lua's own accessors
-- (IsKnownCertificationTierKey/GetCertificationTierOrdinal) are not
-- available — the same "runtime existence guard, not a load-order
-- assumption" soft-dependency convention this file already applies to
-- IsHighCommand/HasPermission. Every normal-operation code path in this
-- file (server/certtiers.lua is an unconditional, always-loaded file in
-- this resource, not a feature-flagged one) defers to the live catalog
-- instead.
local TIER_RANK = { trainee = 1, certified = 2, senior = 3 }

--- @param key any
--- @return boolean
local function IsKnownTierKeyOrLegacyFallback(key)
    if type(key) ~= 'string' then return false end
    if type(IsKnownCertificationTierKey) == 'function' then
        return IsKnownCertificationTierKey(key)
    end
    return TIER_RANK[key] ~= nil
end

--- @param key any
--- @return number?
local function GetTierOrdinalOrLegacyFallback(key)
    if type(key) ~= 'string' then return nil end
    if type(GetCertificationTierOrdinal) == 'function' then
        return GetCertificationTierOrdinal(key)
    end
    return TIER_RANK[key]
end

-- The tier every row had, implicitly, before this pass — migration 0006's
-- own DEFAULT for existing rows, and GrantCertification's own INSERT
-- column list still relies on this same DB default for every NEW grant
-- too (GrantCertification is deliberately NOT changed to accept a tier
-- argument — see "TIER" above). Referenced here only for the defensive
-- fallback in RefreshCertificationCache below (an unreadable/unexpected
-- tier value defaults to this, never to the least-privileged 'trainee' —
-- consistent with this whole section's "never silently reduce an existing
-- grant's capability" posture).
local DEFAULT_TIER = 'certified'

-- Fixed revoke-reason vocabulary — see "REVOKE REASON" above.
local VALID_REVOKE_REASONS = { retired = true, reassigned = true, disciplinary = true, performance = true, other = true }

--- Real, current Unix time in whole seconds, or nil if unavailable. See
--- "EXPIRY" item 3 above for the full CONFIDENCE NOTE on `os.time`.
--- @return number?
local function NowUnix()
    if type(os) == 'table' and type(os.time) == 'function' then
        return os.time()
    end
    return nil
end

--- @param expiresAtUnix number?
--- @return boolean
--- FAILS TOWARD AVAILABILITY, not toward lockout — deliberately the
--- OPPOSITE failure direction from this file's own authorization-root
--- "fail closed" doctrine (HasK9Access/RefreshCertificationCache on a
--- genuine DB read failure). Those fail closed because an unreadable cert
--- row IS the real, unknown authorization state. A missing `os.time` is
--- not that: it is an environment anomaly unrelated to whether this
--- citizenid's certification is genuinely still valid, and this whole
--- expiry mechanism is opt-in (Config.Features.CertificationExpiry). The
--- safe failure mode for an optional feature's own primitive going
--- missing is "the feature silently does nothing," never "every
--- certified handler on the server loses access."
local function IsExpiredUnix(expiresAtUnix)
    if expiresAtUnix == nil then return false end
    local now = NowUnix()
    if now == nil then return false end
    return now >= expiresAtUnix
end

--- WORKFLOW CLARITY (this pass, item 5 — "renewing says what changed").
--- Whole days remaining until `expiresAtUnix`, rounded UP (a renewal that
--- lands with 30 seconds left in the final day still reads as "1 day", not
--- "0 days" — matching CheckAndNotifyExpiry's own `math.max(1,
--- math.ceil(...))` rounding below so the two surfaces never disagree on
--- how a given expiry reads). Returns nil (never a wrong number) whenever
--- either input is unavailable — a caller must decide its own fallback
--- text for "no expiry" rather than this function inventing one, since
--- "never expires" and "cannot currently be computed" are different
--- situations a message might want to phrase differently.
--- @param expiresAtUnix number?
--- @return number?
local function DaysRemainingFromUnix(expiresAtUnix)
    if type(expiresAtUnix) ~= 'number' then return nil end
    local now = NowUnix()
    if now == nil then return nil end
    return math.max(1, math.ceil((expiresAtUnix - now) / 86400))
end

-- ======================================================================
-- CONFIG-SAFETY GUARD (coder-backend, this pass) — every sibling server
-- file (propattachment.lua, bonetool.lua, progression.lua, admin.lua,
-- search.lua) asserts its own config's shape loudly, failing resource
-- start on a genuine misconfiguration; THIS file — the authorization root
-- HasK9Access gates nearly every other feature behind — had none (found
-- and reported by the agent that wrote tests/certifications_spec.lua's 47
-- cases, which deliberately did not fabricate startup-assert tests for
-- asserts that did not exist).
--
-- Run UNCONDITIONALLY, at this file's own LOAD time — NOT deferred into an
-- onResourceStart handler the way every sibling file above does it. That
-- matters here specifically: the K9ModelHashes block immediately below
-- this guard already reads Config.Peds and calls GetHashKey on every
-- entry's model field the instant this file itself loads, at file scope —
-- by the time any onResourceStart handler could run, that read has
-- already happened. config.lua is a shared_script, loaded in full before
-- any server_scripts file (this one included) starts executing, so Config
-- already holds its real, final values by the time this line runs — not a
-- load-order gamble, the same reasoning server/search.lua's own
-- file-load-time ContrabandItemSet precomputation comment already gives
-- for the identical structural point ("config.lua is a shared_script,
-- loaded before this file").
--
-- CHECKED AGAINST THE ACTUAL SHIPPED config.lua before writing every
-- assert below (Config.Departments.police/sheriff/bcso — certifierGrade
-- 4/3/3, autoAccessGrade nil for all three; Config.Peds' four real a_c_*
-- models; Config.CertifyProximityMeters = 5.0): every one of them passes
-- against the real shipped config. Also re-run against
-- tests/certifications_spec.lua's own newFixture() default Config shape
-- (2-department Config.Departments, 2-entry Config.Peds, proximityMeters
-- default 5.0) and its explicit autoAccessGrade-bypass fixtures (10, an
-- integer) — none of the spec's 47 cases construct a Config shape any of
-- these asserts would reject.
--
-- CLAMP-AND-WARN, NOT ASSERT, FOR Config.Peds / Config.CertifyProximityMeters
-- (this pass) — same incident/reasoning as server/cooldowns.lua's own
-- header ADDENDUM: a bare top-level `assert` that throws aborts THIS
-- ENTIRE FILE from that line onward the instant an operator's config.lua
-- edit reaches it — every function definition (HasK9Access,
-- RefreshCertificationCache, IsConfiguredK9Model), RegisterNetEvent/
-- RegisterCommand, and the QBCore:Server:OnJobUpdate auto-revoke handler
-- textually BELOW the failing line silently never exist, for the rest of
-- the resource's uptime, with nothing but one script-error line at boot to
-- explain why. That is already the worst failure class this resource
-- forbids ("the unbounded trap") anywhere; it is WORSE here specifically
-- because THIS file is the one HasK9Access/GrantCertification/
-- RevokeCertification live in — nearly every other feature in this
-- resource calls into one of those three, so a single config typo on
-- EITHER of these two fields would currently take every gated K9 feature
-- down resource-wide, not just certification. See
-- ResolveConfiguredPositiveNumber below and the Config.Peds build loop
-- immediately after it for the actual clamp-and-warn behavior each is
-- replaced with.
--
-- Config.Departments' own validation immediately below USED TO BE bare
-- asserts, deliberately left unconverted, with a comment reporting them
-- "for whoever owns config.lua/DEVELOPER_REFERENCE.md's broader
-- config-safety pass to weigh in on, rather than decided unilaterally in
-- this one." That pass has now happened resource-wide (Config.Peds/
-- Config.CertifyProximityMeters above, Config.Permissions in
-- server/permissions.lua, Config.K9Appearance/Config.Peds in
-- server/appearance.lua) and a lifecycle sweep confirmed this WAS the
-- single highest-severity unbounded trap left in the whole resource: a
-- single malformed Config.Departments entry — one typo'd certifierGrade,
-- or a department table missing entirely — threw here, at this file's own
-- load time, and took down EVERY function/event/command textually below
-- it (HasK9Access, IsEligibleCertifier, RefreshCertificationCache, every
-- certify/revoke path, the OnJobUpdate auto-revoke handler) for the rest
-- of the server's uptime. Nearly every feature in this resource calls
-- into HasK9Access — one operator typo was a single restart away from
-- disabling K9 access server-wide.
-- ======================================================================

--- CLAMP-AND-WARN (this pass) — converts Config.Departments' own
--- validation from a bare, file-aborting assert into the same
--- drop-the-bad-entry-and-keep-going treatment Config.Permissions already
--- gets in server/permissions.lua (read and matched here, not
--- reinvented): a missing/non-table Config.Departments becomes an empty
--- table (loud WARNING, not silent), and each per-department entry is
--- validated independently — a malformed one is DROPPED from the result,
--- every well-formed one is kept unchanged.
---
--- WHY A MALFORMED `certifierGrade` DROPS THE WHOLE DEPARTMENT, NOT JUST
--- THAT FIELD (the one genuine difference from the Config.Peds/
--- Config.CertifyProximityMeters treatment above, which each substitute a
--- single safe fallback VALUE): unlike a positive number with one obvious
--- already-shipped default, there is no safe substitute grade for
--- `certifierGrade` — clamping it to a guessed integer would either lock
--- out every real certifier in that department or silently let anyone
--- certify, which is itself a correctness risk, not an obviously safer
--- choice. Dropping the entry entirely is what actually FAILS CLOSED here:
--- HasK9Access/IsEligibleCertifier both gate on `Config.Departments[job.name]`
--- existing AT ALL as their very first check (`if not job or not
--- Config.Departments[job.name] then return false end`), so removing a
--- malformed department's entry means nobody employed by that job can be
--- granted K9 access or act as a certifier for it — never "any grade
--- qualifies," never "grade 0 qualifies," for the one entry that could not
--- be parsed. Every OTHER, well-formed department in the same table is
--- completely unaffected by one neighbor's typo.
---
--- WHY A MALFORMED `autoAccessGrade` GETS THE GENTLER TREATMENT (reset to
--- nil, department KEPT): the ORIGINAL bare assert's own message already
--- argued this is safe — "any other non-nil value silently disables the
--- bypass" — and nil (no auto-bypass) is not a guess, it is the exact
--- value every shipped default already uses. The only bug being fixed
--- here is the SILENCE (nothing was ever printed to explain the disabled
--- bypass), not the underlying fail-closed behavior itself, so there is no
--- reason to also drop the department's own valid certifierGrade over it.
--- @return table -- a NEW table: validated Config.Departments replacement
local function ResolveConfiguredDepartments()
    if type(Config.Departments) ~= 'table' then
        print(
            '[qbx_k9unit] certifications.lua: Config.Departments must be a table -- HasK9Access, ' ..
            'IsEligibleCertifier, and every certify/revoke path index it by job.name to decide K9 access and ' ..
            'certifier eligibility. Using an EMPTY table instead of aborting this file -- every job will fail K9 ' ..
            'access/certifier eligibility outright (fails closed) until config.lua is fixed. Add ' ..
            'Config.Departments back to config.lua.'
        )
        return {}
    end

    local validDepartments = {}
    local totalCount, rejectedCount = 0, 0

    for jobName, dept in pairs(Config.Departments) do
        totalCount = totalCount + 1

        if type(dept) ~= 'table' then
            rejectedCount = rejectedCount + 1
            print(
                ('[qbx_k9unit] certifications.lua: Config.Departments[%s] must be a table with a certifierGrade ' ..
                 'field (found: %s) -- DROPPING this department entirely: nobody employed by this job can be ' ..
                 'granted K9 access or act as a certifier for it until this is fixed in config.lua. Every other ' ..
                 'configured department is unaffected.'):format(tostring(jobName), tostring(dept))
            )
        elseif type(dept.certifierGrade) ~= 'number' then
            rejectedCount = rejectedCount + 1
            print(
                ('[qbx_k9unit] certifications.lua: Config.Departments[%s].certifierGrade must be a number ' ..
                 '(found: %s) -- DROPPING this department entirely rather than guessing a grade (no substitute ' ..
                 'number is safe: too low silently lets anyone certify, too high locks out every real ' ..
                 'certifier). Nobody employed by this job can be granted K9 access or act as a certifier for it ' ..
                 'until this is fixed in config.lua. Every other configured department is unaffected.'
                 ):format(tostring(jobName), tostring(dept.certifierGrade))
            )
        else
            local cleanedDept = dept
            if dept.autoAccessGrade ~= nil and type(dept.autoAccessGrade) ~= 'number' then
                print(
                    ('[qbx_k9unit] certifications.lua: Config.Departments[%s].autoAccessGrade must be nil (no ' ..
                     'auto-bypass) or a number (found: %s) -- treating it as nil (no bypass) for this department, ' ..
                     'the same safe value every install ships with by default, instead of the silent, unexplained ' ..
                     'disable this used to be. certifierGrade-based certifier eligibility for this department is ' ..
                     'unaffected. Find Config.Departments[%s].autoAccessGrade in config.lua and fix it if a real ' ..
                     'bypass grade was intended.'):format(tostring(jobName), tostring(dept.autoAccessGrade), tostring(jobName))
                )
                -- Shallow copy, never mutating the operator's own original
                -- config.lua table in place — every OTHER field (including
                -- `label`, deliberately never validated here, see below)
                -- passes through unchanged.
                cleanedDept = {}
                for k, v in pairs(dept) do cleanedDept[k] = v end
                cleanedDept.autoAccessGrade = nil
            end
            -- NOTE: dept.label is NOT validated here — every real consumer
            -- (server/tablet.lua, this file's own OnJobUpdate
            -- department-loss notice) already falls back to the job key
            -- itself when label is missing or not a string, so an absent/
            -- malformed label degrades gracefully rather than needing to
            -- be caught here too.
            validDepartments[jobName] = cleanedDept
        end
    end

    if totalCount > 0 and rejectedCount == totalCount then
        -- EVERY configured department was malformed — a genuinely
        -- degraded install (nobody, anywhere, can be granted K9 access or
        -- act as a certifier), but still not a reason to abort this file:
        -- HasK9Access/RefreshCertificationCache/every command and event
        -- below still need to be DEFINED, even if every one of them can
        -- currently only ever say "no closed department configured."
        -- Printed loudly, and repeated, so an operator actually notices
        -- this rather than mistaking it for one of the ordinary
        -- single-entry warnings above.
        for _ = 1, 3 do
            print(
                '[qbx_k9unit] CRITICAL: every entry in Config.Departments was rejected above -- K9 access and ' ..
                'certification are UNAVAILABLE FOR EVERY JOB on this server until config.lua is fixed. This ' ..
                'resource keeps running (this is not a crash), but nobody can be certified or use any K9 ' ..
                'feature until at least one valid department is configured.'
            )
        end
    end

    return validDepartments
end

-- Reassigns the SAME shared Config table every other file in this resource
-- reads Config.Departments from (server/tablet.lua, server/permissions.lua,
-- server/highcommand.lua, server/admin.lua, server/equipmentshop.lua,
-- server/inventory.lua, server/bonetool.lua, ...) — this file loads early
-- enough in fxmanifest.lua's server_scripts list (verified: the one
-- sibling file that also validates Config.Departments at its own load
-- time, server/highcommand.lua, defers that read into its own
-- onResourceStart handler, which fires only after every server_scripts
-- file, this one included, has already finished loading) that every later
-- reader — and every deferred onResourceStart handler in an EARLIER-loading
-- file — sees this cleaned table, never the raw, potentially-malformed
-- original.
Config.Departments = ResolveConfiguredDepartments()

--- CLAMP-AND-WARN (this pass) — see the CONFIG-SAFETY GUARD block above
--- for the full "why not a bare assert here" reasoning. Resolves a raw
--- Config number to a safe, positive value: unchanged if already valid,
--- otherwise a loud PRINT (never an aborting error) naming the exact key,
--- the bad value found, and the fallback substituted, so this file keeps
--- loading — and every OTHER K9 feature that has nothing to do with the
--- one field that was wrong keeps working — while an operator fixes the
--- real config.lua typo. Mirrors server/cooldowns.lua's own
--- ResolveConfiguredThresholdMs shape exactly (see that function's doc
--- comment for the original incident this responds to), reimplemented
--- locally rather than called directly: that function's own printed
--- wording is cooldown-specific ("does NOT mean 'no cooldown'... would
--- otherwise permanently block the guarded action") and would be actively
--- misleading for the proximity-meters value this is used for below.
--- @param configuredValue any
--- @param fallback number -- a positive, hardcoded call-site literal (this file's own shipped default for the field), never itself read from Config
--- @param configKeyName string
--- @return number
local function ResolveConfiguredPositiveNumber(configuredValue, fallback, configKeyName)
    if type(configuredValue) == 'number' and configuredValue == configuredValue and configuredValue > 0 then
        return configuredValue
    end
    print(
        ('[qbx_k9unit] certifications.lua: %s must be a positive number (found: %s). Using the built-in ' ..
         'fallback of %s instead so this file keeps loading and every OTHER K9 feature keeps working -- find ' ..
         '%s in config.lua and fix it.'):format(configKeyName, tostring(configuredValue), tostring(fallback), configKeyName)
    )
    return fallback
end

-- CLAMP-AND-WARN (this pass): unchanged if valid; otherwise every online
-- grant/revoke's proximity check (§4.2 item 4) falls back to the shipped
-- 5.0-meter default rather than this whole file aborting. See
-- ResolveConfiguredPositiveNumber's own doc comment above.
Config.CertifyProximityMeters = ResolveConfiguredPositiveNumber(Config.CertifyProximityMeters, 5.0, 'Config.CertifyProximityMeters')

-- CLAMP-AND-WARN (this pass, found while tracing the CertificationExpiry
-- chain end-to-end) -- Config.CertificationExpiryCheckIntervalMs already
-- got this treatment (see the CreateThread loop far below); Config.
-- CertificationExpiryDays and Config.CertificationExpiryWarningDays did
-- not, despite being exactly the class of "silently degrades to a
-- DIFFERENT, unannounced behavior" footgun this file's own CONFIG-SAFETY
-- GUARD section above exists to close: an operator who sets
-- Config.Features.CertificationExpiry = true but leaves
-- Config.CertificationExpiryDays misconfigured (a typo'd string, 0, a
-- negative number) gets EVERY certification granted or renewed from that
-- point on with NO expiry at all -- identical, byte-for-byte, to the
-- feature being off -- with nothing printed anywhere to say why. That is
-- the worst possible outcome for a feature an operator just deliberately
-- opted into: it looks enabled and does nothing. One-shot printed
-- warnings (WarnedBadExpiryDays/WarnedBadExpiryWarningDays below), not a
-- per-call print, since both are read from hot, per-action call sites
-- (every grant/renew, every sweep tick) rather than once at file load
-- like Config.CertifyProximityMeters above -- mirrors
-- WarnedBadExpiryCheckIntervalMs's own established one-shot-flag idiom
-- later in this file.
local WarnedBadExpiryDays = false
local WarnedBadExpiryWarningDays = false

--- Resolves Config.CertificationExpiryDays into the expiry window (in
--- days) a fresh grant/renewal should use, or nil if either expiry is
--- genuinely off (Config.Features.CertificationExpiry ~= true -- silent,
--- not a misconfiguration) or misconfigured while expiry IS on (warned
--- once, then silent for the rest of this session -- see CLAMP-AND-WARN
--- above). Shared by GrantCertification and RenewCertification so the one
--- validation/warning lives in one place instead of two independent
--- copies of the same boolean expression free to drift apart.
--- @return number?
local function ResolveConfiguredExpiryDays()
    if not (Config.Features and Config.Features.CertificationExpiry == true) then return nil end
    local raw = Config.CertificationExpiryDays
    if type(raw) == 'number' and raw == raw and raw > 0 then return raw end
    if not WarnedBadExpiryDays then
        WarnedBadExpiryDays = true
        print(
            ('[qbx_k9unit] certifications.lua: Config.CertificationExpiryDays must be a positive number now that ' ..
             'Config.Features.CertificationExpiry is true (found: %s). Every certification granted or renewed ' ..
             'while this stays misconfigured gets NO expiry at all -- identical to the feature being off -- not ' ..
             'the expiry window you just enabled. Find Config.CertificationExpiryDays in config.lua and fix it.'
            ):format(tostring(raw))
        )
    end
    return nil
end

--- Resolves Config.CertificationExpiryWarningDays into the warn-ahead
--- window (in days) CheckAndNotifyExpiry should use, falling back to the
--- shipped default of 7 on any invalid value -- see CLAMP-AND-WARN above.
--- Unlike ResolveConfiguredExpiryDays, this is NOT itself gated on
--- Config.Features.CertificationExpiry: CheckAndNotifyExpiry's only
--- callers already never reach this line unless `cached.expiresAtUnix` is
--- non-nil, which cannot happen unless a grant/renewal already ran with
--- expiry on -- by that point a warn-ahead window is always relevant
--- regardless of the flag's CURRENT value (e.g. an operator who disabled
--- the feature again after some certifications already picked up a real
--- expiry date).
--- @return number
local function ResolveConfiguredExpiryWarningDays()
    local raw = Config.CertificationExpiryWarningDays
    if type(raw) == 'number' and raw == raw and raw > 0 then return raw end
    if not WarnedBadExpiryWarningDays then
        WarnedBadExpiryWarningDays = true
        print(
            ('[qbx_k9unit] certifications.lua: Config.CertificationExpiryWarningDays must be a positive number ' ..
             '(found: %s). Using the built-in fallback of 7 instead -- find Config.CertificationExpiryWarningDays ' ..
             'in config.lua and fix it.'):format(tostring(raw))
        )
    end
    return 7
end

--- Precomputed set of Config.Peds model hashes, built once at file load.
--- Used ONLY by the grant-time model check (§4.2 condition 5) — per
--- §4.1/§4.5, ordinary access checks (HasK9Access) never consult this.
--- Generic over Config.Peds — no hardcoded model name anywhere (DEVELOPER_REFERENCE.md §3
--- acceptance bullet 3), including custom streamed entries.
---
--- CLAMP-AND-WARN (this pass) — see the CONFIG-SAFETY GUARD block above
--- for the full "why not a bare assert here" reasoning. A missing/empty/
--- malformed Config.Peds (or an individual malformed entry within it)
--- degrades to a loud PRINT plus K9ModelHashes simply having no entry for
--- the affected model(s) — IsConfiguredK9Model then correctly rejects
--- every ped it's asked about (every certification GRANT attempt fails
--- with "target not K9 model", exactly as the original assert's own
--- message already described), but HasK9Access/GrantCertification/
--- RevokeCertification/every net event and command this file registers
--- keep working normally — unlike an aborting assert, this is a bounded,
--- single-feature degradation, never a resource-wide one. An individual
--- malformed entry (e.g. Config.Peds[3] missing `.model`) is skipped on
--- its own, by index, without discarding every OTHER valid entry in the
--- same array.
local K9ModelHashes = {}
if type(Config.Peds) ~= 'table' or #Config.Peds == 0 then
    print(
        '[qbx_k9unit] certifications.lua: Config.Peds must be a non-empty array (found: ' ..
        tostring(Config.Peds) .. '). No model will ever be recognized as a K9 model -- every certification ' ..
        'GRANT attempt will fail with "target not K9 model" until this is fixed in config.lua -- but ' ..
        'HasK9Access and every other K9 feature in this file are unaffected. Find Config.Peds in config.lua ' ..
        'and fix it.'
    )
else
    for i, pedEntry in ipairs(Config.Peds) do
        if type(pedEntry) == 'table' and type(pedEntry.model) == 'string' and pedEntry.model ~= '' then
            K9ModelHashes[GetHashKey(pedEntry.model)] = true
        else
            print(
                ('[qbx_k9unit] certifications.lua: Config.Peds[%d].model must be a non-empty string (found: %s). ' ..
                 'Skipping this ONE entry -- it can never be matched by IsConfiguredK9Model -- rather than ' ..
                 'discarding every other valid entry or aborting this file. Find Config.Peds[%d] in config.lua ' ..
                 'and fix it.'):format(i, tostring(pedEntry and pedEntry.model), i)
            )
        end
    end
end

--- @param modelHash number
--- @return boolean
--- Exposed globally (no `local`) — server/main.lua's leash-role
--- determination (§6.1/§9 item 3b) reuses this same model check rather
--- than re-deriving its own copy from Config.Peds.
function IsConfiguredK9Model(modelHash)
    return K9ModelHashes[modelHash] == true
end

--- Re-queries every ACTIVE specialization row for (citizenid, jobName) and
--- replaces that job's slice of `Specializations[citizenid]` wholesale.
--- Fails CLOSED on a thrown read (an unreadable citizenid/job's
--- specialization set is treated as empty, never as "whatever it was
--- before") — same posture as RefreshCertificationCache. Declared BEFORE
--- RefreshCertificationCache (which calls it) since both are in this same
--- file/chunk and this is a `local` — Lua resolves a `local` reference
--- lexically, by textual position, not by call order at runtime. Called
--- from RefreshCertificationCache itself (every point that already
--- refreshes the base cert cache also keeps this in sync) — never called
--- standalone from outside this file.
--- @param citizenid string
--- @param jobName string
local function RefreshSpecializationCache(citizenid, jobName)
    local ok, rowsOrErr = pcall(K9Store.Spec_GetActiveKeys, citizenid, jobName)
    Specializations[citizenid] = Specializations[citizenid] or {}
    if not ok then
        print(('[qbx_k9unit] RefreshSpecializationCache query failed for %s/%s: %s'):format(citizenid, jobName, tostring(rowsOrErr)))
        Specializations[citizenid][jobName] = {}
        return
    end
    local set = {}
    for _, row in ipairs(rowsOrErr or {}) do
        set[row.specialization] = true
    end
    Specializations[citizenid][jobName] = set
end

-- NotifyPlayer used to be defined here as its own local copy (one of 12
-- independent hand-rolled copies found by DEVELOPER_REFERENCE.md's dedup
-- audit). It is now server/notify.lua's single shared resource-global
-- implementation -- ox_lib's `ox_lib:notify` client event was chosen there
-- over exports.qbx_core:Notify for the same reason this file's own original
-- comment gave (a stable, publicly documented API of an already-declared
-- dependency; qbx_core's own Notify export name/signature could not be
-- independently confirmed in this sandbox -- see the CONFIDENCE NOTE near
-- the bottom of this file for the same caveat applied to the player-loaded
-- event name). Every call site below is unchanged: this file's own calls
-- always passed a `notifyType` and never a custom title, which is exactly
-- server/notify.lua's default title, so nothing here needed editing beyond
-- deleting this local copy.

--- Server-authoritative check: is `source` currently allowed to use K9
--- features? DEVELOPER_REFERENCE.md §4.1 "Access rule": job.name in Config.Departments
--- AND (active cert cached for that job OR configured autoAccessGrade
--- bypass OR High Command — server/highcommand.lua's IsHighCommand,
--- project-owner-directed this pass, see that file's own header for the
--- full "run any command" contract). Deliberately does NOT check ped model
--- (§4.5) — see the contract block above for why that's intentional, not
--- an oversight. Exposed globally (no `local`) — server/main.lua calls this directly.
--- @param source number
--- @return boolean
function HasK9Access(source)
    local Player = exports.qbx_core:GetPlayer(source)
    if not Player or not Player.PlayerData then return false end

    local job = Player.PlayerData.job
    if not job or not Config.Departments[job.name] then return false end

    -- EXPLICIT PER-PERSON BLOCK (security-audit pass, this pass -- "assess,
    -- then decide" -- see server/permissions.lua's own
    -- ADMIN_CAPABILITY_BLOCKABLE_KEYS doc comment for the full "why" this
    -- exists). Checked FIRST, before every qualification path below --
    -- including the explicit grant bypass immediately under this comment
    -- and the High Command bypass further down -- mirroring the EXACT
    -- "step 2, before the grant, beats everything" precedence every other
    -- PER-PERSON FEATURE CONTROL check in this resource already uses for
    -- the Config.Features 'block.<Name>' namespace (e.g.
    -- server/admin.lua's IsAdminFeaturePermittedForCitizenId, this file's
    -- own header). This is a NEW namespace ('block.k9.access'), not a
    -- second mechanism: it is the SAME HasPermission call, the SAME
    -- k9_permissions row shape, the SAME MEMORY-MODE BLOCK ASYMMETRY
    -- fail-closed guarantee (HasPermission's own `permissionKey:match('^block%.')`
    -- branch matches this literal string too, automatically, with no
    -- additional code) -- only the key string is new.
    --
    -- COST (128-player audit question, disclosed): this is ONE more
    -- PermissionCache table lookup on an ALREADY-warmed, in-memory table
    -- HasPermission already reads for the grant-bypass check two lines
    -- below -- no new query, no new cache, no new I/O class. HasK9Access
    -- was already O(1) in-memory before this line; it still is.
    --
    -- GATES THE START, NEVER THE STOP (128-player audit question,
    -- disclosed): HasK9Access is consulted at the START of every action
    -- across this resource's ~25 other server/*.lua files -- confirmed by
    -- direct grep, not assumed -- and this resource has an established,
    -- explicitly-documented, resource-wide rule that every STOP/RELEASE/
    -- EXIT/OFF path (server/combat.lua's releaseBiteHold/releaseTakedown/
    -- releaseDrag, server/kennel.lua's requestExitKennel/requestPutDownKennel,
    -- server/propattachment.lua's own remove branch, server/fetch.lua's
    -- releaseFetchBall, server/main.lua's detachLeash) is UNCONDITIONAL
    -- and never calls HasK9Access (or any block check) at all -- "gate the
    -- START of a thing, never the STOP", stated in those exact words
    -- across every one of those files' own comments. This block therefore
    -- cannot strand anyone mid-action: it can only ever prevent a NEW
    -- action from starting, exactly like every OTHER way HasK9Access can
    -- already flip false mid-session (a job change, a decertification, a
    -- revoked 'k9.access' grant) — none of which this resource treats as
    -- a reason to also gate a release path, and this is no different.
    if type(HasPermission) == 'function' and HasPermission(Player.PlayerData.citizenid, 'block.k9.access') then
        return false
    end

    -- PERMISSION GRANT BYPASS (server/permissions.lua, Config.Features.PermissionGrants,
    -- resolution-order STEP 1 -- see that file's own header for the full
    -- 4-step contract: "an active granted 'k9.access' permission -> ALLOW",
    -- checked before the high-command bypass and the legacy cert-cache/
    -- autoAccessGrade gate below, matching config.lua's own documented
    -- "first match wins" order). Guarded by a `type(...) == 'function'`
    -- runtime existence check, this resource's established soft-dependency
    -- convention -- this function still works exactly as before if
    -- server/permissions.lua is ever removed or Config.Features.PermissionGrants
    -- is false (HasPermission re-checks that flag itself and returns false).
    if type(HasPermission) == 'function' and HasPermission(Player.PlayerData.citizenid, 'k9.access') then return true end

    -- HIGH COMMAND BYPASS (server/highcommand.lua, Config.Features.HighCommand,
    -- project-owner-directed this pass) -- "the certification requirement
    -- itself" is explicitly one of the gates a High Command officer must
    -- bypass (see that file's own header PART 1 for the full contract).
    -- Guarded by a `type(...) == 'function'` runtime existence check, this
    -- resource's established soft-dependency convention (see
    -- fxmanifest.lua's comment on server/search.lua's AwardXP reuse
    -- for the precedent) -- this function still works exactly as before if
    -- server/highcommand.lua is ever removed or Config.Features.HighCommand
    -- is false (IsHighCommand re-checks that flag itself and returns false).
    -- Checked BEFORE the cert-cache read below so a high-command officer
    -- with no active cert of their own is granted access without needing
    -- one -- this is a genuine bypass, not merely an alternate cache hit.
    if type(IsHighCommand) == 'function' and IsHighCommand(source) then return true end

    -- The `cached.job == job.name` re-check matters right around a job
    -- change, before RefreshCertificationCache has run for the new job —
    -- don't trust a stale cache entry scoped to an old job.
    --
    -- CERTIFICATION DEPTH (this pass, Part A §9): `not cached.expired` is
    -- the ONLY change to this branch. An expired cert does not hard-fail
    -- this whole function — it simply does not satisfy THIS branch, so
    -- control falls through to the autoAccessGrade bypass below exactly
    -- as it already does for `cached.active == false`; an expired
    -- handler who separately qualifies via autoAccessGrade (or the
    -- permission-grant/high-command bypasses already checked above this
    -- branch) is unaffected. Deliberately does NOT force-detach anything
    -- or mutate `active` in the DB — see this file's header "EXPIRY" item
    -- 1 for why a passive, time-based lapse gets a softer landing than a
    -- manual revoke's "immediately" teardown.
    local cached = Certifications[Player.PlayerData.citizenid]
    if cached and cached.active and cached.job == job.name and not cached.expired then
        return true
    end

    -- A HANDLER PARTNERED WITH A K9 has handler access for as long as the
    -- partnership lasts. Partnering already needs a certified dog to accept
    -- this officer and the officer to be in a K9 department (checked just
    -- above too), so certifying the handler separately was a second step
    -- that only got in the way: an uncertified partner could leash the dog
    -- but not throw its ball, treat it or watch its camera. Only the human
    -- side qualifies (isK9 == false) -- a dog still needs its own
    -- certification, and dog-only moves still check the dog's model.
    if type(GetActivePartnerCitizenId) == 'function' then
        local partnerCid, isK9 = GetActivePartnerCitizenId(Player.PlayerData.citizenid)
        if partnerCid and isK9 == false then return true end
    end

    -- Opt-in bypass, defaults to nil/disabled per shipped config — do not
    -- change the default.
    --
    -- SECURITY FIX (coder-security, authorization-root runtime-nil review):
    -- `job.grade.level` was previously only checked for truthiness, not
    -- type — a non-nil, non-number `level` (a job object shaped
    -- differently than qbx_core's documented `{ name, level: number }`
    -- schema, e.g. a legacy/foreign job source) would reach
    -- `job.grade.level >= dept.autoAccessGrade` and throw an UNCAUGHT
    -- "attempt to compare number with <type>" error instead of failing
    -- closed. `dept.autoAccessGrade`'s own type is already guaranteed by
    -- the file-load-time assert above (`type(dept.autoAccessGrade) ==
    -- 'number'`, checked first via short-circuit `and`), so `type(job.grade
    -- .level) == 'number'` is the only remaining guard this comparison
    -- needs. An explicit type check, not a pcall: a pcall around this would
    -- convert a loud bug (a job object with the wrong shape reaching the
    -- access gate) into exactly the silent no-op this authorization path
    -- must never produce for the wrong reason. FAILS CLOSED — a
    -- non-number `level` makes this bypass evaluate to false (no access
    -- granted via this branch), never true; it does not touch the
    -- cert-cache branch above, so a real cached cert still grants access
    -- through that path regardless.
    local dept = Config.Departments[job.name]
    if type(dept.autoAccessGrade) == 'number' and job.grade and type(job.grade.level) == 'number' and job.grade.level >= dept.autoAccessGrade then
        return true
    end

    return false
end

-- ======================================================================
-- COULD-NOT-DETERMINE HANDLING (lifecycle QA pass, this pass) -- see
-- RefreshCertificationCache's own doc comment below for the full "why".
-- Short version: a transient query failure (timeout, dropped connection,
-- busy pool) is not the same fact as a confirmed "not certified" answer,
-- and treating the two as interchangeable is exactly the silent,
-- session-long lockout this pass exists to close -- most dangerously
-- during server/main.lua's onResourceStart backfill loop, which calls
-- RefreshCertificationCache once per already-connected player in one tight
-- burst (the single highest-risk moment for a transient failure a real
-- server sees). The three pieces below close it: a small bounded retry
-- inside the read itself, a separate bookkeeping table for "this
-- citizenid's last attempt could not be confirmed either way" (NEVER
-- merged into `Certifications` itself -- an unresolved determination must
-- never be mistaken for a real cached answer by HasK9Access or anything
-- else that reads that table), and a periodic bounded resync sweep
-- (defined near the bottom of this file) that keeps retrying exactly those
-- entries so a player recovers without needing to reconnect.
-- ======================================================================

-- Bounded retry budget for RefreshCertificationCache's own existence-check
-- query (K9Store.Cert_GetActiveId) -- deliberately NOT applied to the
-- secondary tier/expiry metadata read a few lines below, which already has
-- its own, unrelated "degrade to the safe default, never more restrictive"
-- fallback (see that branch's own comment) and is not what determines
-- `active`. Short and LINEAR on purpose, never exponential: this exists to
-- ride out a momentary connection blip or a momentarily busy pool during a
-- tight burst of calls, not to wait out a genuinely unreachable database --
-- an unbounded or long retry here would turn one player's transient
-- failure into every subsequent player in the SAME onResourceStart backfill
-- burst waiting behind it. Three attempts at a 200ms linear step costs at
-- most 200+400 = 600ms added to ONE player's own refresh before this
-- function gives up and moves on -- the backfill loop's own `for` continues
-- to the next player regardless, exactly like every other iteration.
local CERT_REFRESH_RETRY_ATTEMPTS = 3
local CERT_REFRESH_RETRY_BACKOFF_MS = 200

--- Runs `fn()` up to `attempts` times (always at least once), waiting
--- `backoffMs * attemptNumber` between tries (never before the first,
--- never after the last) -- a short, linear backoff, not exponential; see
--- CERT_REFRESH_RETRY_ATTEMPTS/CERT_REFRESH_RETRY_BACKOFF_MS's own comment
--- for why linear is the right choice at this small a scale. Mirrors a
--- bare `pcall(fn)`'s own two-or-more-return-value contract exactly --
--- callers check the leading boolean exactly like they would a bare pcall
--- -- so this is a drop-in replacement at every call site in this file
--- that used to be `pcall(f, ...)` and now needs a bounded retry instead of
--- a single attempt.
--- @param fn function -- takes no arguments; wrap a call with its own
--- arguments in a closure at the call site (this file's own established
--- convention -- see server/datastore.lua's identical reasoning on its own
--- `pcall(function() return MySQL.query.await(...) end)` for why the
--- closure form is used instead of `pcall(fn, ...)` -- avoids re-deriving
--- that same footgun here for a second call site).
--- @param attempts number
--- @param backoffMs number
--- @return boolean ok
--- @return any resultOrErr
---
--- `coroutine.isyieldable()` GUARD: every real call site in this file runs
--- inside an FXServer-managed coroutine (an event handler, a command
--- handler, or this file's own CreateThread-based sweeps), where `Wait()`
--- is always safe to call -- so in production this guard is always true
--- and the backoff behaves exactly as documented above. It exists so this
--- function is ALSO safe to call directly from a plain, non-coroutine Lua
--- call (this resource's own test suite calls RefreshCertificationCache
--- this way throughout tests/certifications_spec.lua): `Wait()` ultimately
--- reaches `coroutine.yield()`, which Lua itself errors on when called
--- outside any coroutine ("attempt to yield from outside a coroutine") --
--- an error this function's own caller has no reason to expect and no
--- pcall protecting it from. Skipping the backoff in that one case still
--- preserves the real, load-bearing guarantee (a bounded NUMBER of
--- attempts before giving up) -- only the WAIT between them is skipped,
--- and only when there is no coroutine for it to suspend in the first
--- place.
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

-- CertificationCheckUnresolved[citizenid] = { job = string, attempts =
--   number, firstFailedAt = number? } -- set only when
-- RefreshCertificationCache exhausts CERT_REFRESH_RETRY_ATTEMPTS with no
-- confirmed answer either way for `job`; cleared the instant a LATER call
-- (a reconnect, a grant/revoke touch, or the periodic resync sweep below)
-- actually confirms one, real or absent. Purely a bookkeeping table for the
-- operator-facing message and the resync sweep -- NEVER read by
-- HasK9Access/GetCertificationTier/HasSpecialization/any other
-- access-relevant function, and never merged into `Certifications` itself.
-- Local: nothing outside this file needs it.
local CertificationCheckUnresolved = {}

--- Re-queries the active-cert row for (citizenid, jobName) and updates the
--- in-memory cache. Exposed globally (no `local`) — see FILE-TO-FILE
--- CONTRACT above for every call site.
---
--- Regression-test fix: this is the single most-called function in the
--- cert system (grant, both revoke paths, PlayerLoaded, OnJobUpdate, and
--- server/main.lua's onResourceStart backfill loop — which iterates every
--- connected player in one handler invocation — all call it), yet unlike
--- GrantCertification's INSERT (pcall-wrapped specifically because MySQL
--- errors are expected there) this read was previously unguarded. Per the
--- backfill loop's own comment in server/main.lua, an uncaught error here
--- would abort processing for every subsequent player in that loop — the
--- exact class of ship-blocking bug already found and fixed once in this
--- file for a different root cause. Wrap the read in a bounded retry and,
--- on total failure, treat it as COULD-NOT-DETERMINE rather than a
--- confirmed revoke — see "COULD-NOT-DETERMINE HANDLING" above for the
--- full contract this now implements. HasK9Access's own posture is
--- UNCHANGED and still correct: an unresolved citizenid still fails closed
--- for access (matching config.lua's own "nobody may end up with MORE
--- access than a working database would give them" invariant) — what
--- changed is that this function no longer WRITES a confirmed-false
--- record to get there, which is what let a transient blip permanently
--- outlive the blip itself.
--- @param citizenid string
--- @param jobName string
--- @return boolean active — the best currently-known answer: freshly
--- confirmed against the DB by this call, retained from a genuine PRIOR
--- confirmation for this exact job, or `false` when nothing is known at
--- all.
--- @return boolean stateKnown — true when `active` reflects a real,
--- trustworthy answer (freshly confirmed OR retained from a genuine prior
--- confirmation for this exact job); false only when there is no known
--- answer at all (this call could not confirm one and no matching prior
--- confirmation existed either). Any caller that mirrors `active` into
--- player-facing/display state (server/main.lua's onResourceStart
--- backfill, this file's own PlayerLoaded handler) MUST check this before
--- writing anywhere — writing an unchecked `active` on a `stateKnown ==
--- false` result would manufacture exactly the false "not certified"
--- signal this whole fix exists to stop producing.
--- @return boolean freshlyVerified — true only when THIS call's own query
--- actually succeeded just now (whether the row turned out active or not).
--- A caller that just performed its OWN write and wants to read the cache
--- back for a value that reflects THAT write specifically (not a retained
--- pre-write value that happens to also satisfy `stateKnown`) must check
--- this instead — see SetCertificationTier/SetCertificationTierOffline/
--- RenewCertification's own `freshlyVerified`-gated cache reads for why:
--- `stateKnown` alone would let a stale, retained pre-write cache entry
--- masquerade as confirmation of a write that committed moments earlier
--- but whose own immediate read-back happened to fail.
function RefreshCertificationCache(citizenid, jobName)
    local queryOk, activeIdOrErr = PcallWithBoundedRetry(
        function() return K9Store.Cert_GetActiveId(citizenid, jobName) end,
        CERT_REFRESH_RETRY_ATTEMPTS, CERT_REFRESH_RETRY_BACKOFF_MS
    )

    if not queryOk then
        -- COULD-NOT-DETERMINE, not confirmed-absent -- see "COULD-NOT-
        -- DETERMINE HANDLING" above for the full contract. Deliberately
        -- does NOT write `{ active = false, job = jobName }` here: doing so
        -- would be indistinguishable, to every reader of `Certifications`,
        -- from a genuine revoke -- exactly the bug this pass exists to
        -- close.
        local previous = Certifications[citizenid]
        local previousMatchesThisJob = previous ~= nil and previous.job == jobName

        CertificationCheckUnresolved[citizenid] = {
            job = jobName,
            attempts = CERT_REFRESH_RETRY_ATTEMPTS,
            firstFailedAt = (CertificationCheckUnresolved[citizenid] and CertificationCheckUnresolved[citizenid].firstFailedAt) or NowUnix(),
        }

        if previousMatchesThisJob then
            print((
                '[qbx_k9unit] CERTIFICATION CHECK FAILED for citizenid=%s job=%s after %d attempt(s): %s -- ' ..
                'this is NOT a confirmed revoke. KEEPING the previous cached state (active=%s) rather than ' ..
                'resetting it to uncertified. A bounded resync sweep will keep retrying this citizenid ' ..
                'automatically; if this message repeats for the same citizenid, check the database connection.'
            ):format(citizenid, jobName, CERT_REFRESH_RETRY_ATTEMPTS, tostring(activeIdOrErr), tostring(previous.active)))
            return previous.active, true, false
        end

        print((
            '[qbx_k9unit] CERTIFICATION CHECK FAILED for citizenid=%s job=%s after %d attempt(s): %s -- ' ..
            'this is an UNKNOWN answer, NOT a confirmed "not certified" one. No previous cached state exists ' ..
            'for this exact job, so nothing is being written to the cache (left UNSET, never a manufactured ' ..
            '`false`). HasK9Access will deny access until this resolves, exactly as it would for a real ' ..
            'revoke -- but the operator should know this citizenid may in fact BE certified and the server ' ..
            'simply could not confirm it yet. A bounded resync sweep will keep retrying automatically.'
        ):format(citizenid, jobName, CERT_REFRESH_RETRY_ATTEMPTS, tostring(activeIdOrErr)))
        return false, false, false
    end

    CertificationCheckUnresolved[citizenid] = nil

    local active = activeIdOrErr ~= nil
    if not active then
        Certifications[citizenid] = { active = false, job = jobName }
        Specializations[citizenid] = nil
        return false, true, true
    end

    -- CERTIFICATION DEPTH (this pass, Part A §5/§9) — tier/expiry
    -- metadata, read via a SEPARATE query from the existence check above,
    -- DELIBERATELY: this file's own regression tests sequence exact call
    -- counts against the existence-check call's underlying
    -- `MySQL.scalar.await` invocation (e.g. the GrantInFlight concurrency
    -- test's `scalarCallCount == 2` assertion) — changing that call's own
    -- SQL/shape would be a needless, high-blast-radius edit to already
    -- passing coverage for no behavioral gain. DATASTORE MIGRATION NOTE:
    -- this file now calls K9Store.Cert_GetActiveId instead of
    -- MySQL.scalar.await directly, but K9Store.Cert_GetActiveId forwards
    -- to that exact same MySQL.scalar.await call with the identical SQL/
    -- params when Config.Database.enabled is not literally false, so the
    -- scalarCallCount assertion still counts the same underlying calls
    -- unchanged (see tests/certifications_spec.lua's own fixture, which
    -- loads the real server/datastore.lua alongside this file for exactly
    -- this reason). Only run once an active row is already confirmed to
    -- exist above.
    --
    -- `UNIX_TIMESTAMP(expires_at)` does the date arithmetic in SQL, never
    -- in Lua — see this file's header "EXPIRY" item 3. Returns NULL
    -- (-> Lua nil) when `expires_at` itself is NULL, i.e. "never expires".
    local tier, expiresAtUnix = DEFAULT_TIER, nil
    local metaOk, metaRowOrErr = pcall(K9Store.Cert_GetActiveMeta, citizenid, jobName)
    if not metaOk then
        -- Degrades to the DEFAULT_TIER / never-expires fallback, never to
        -- a hard error and never to a MORE restrictive state than the
        -- existence check above already confirmed — this file's "never
        -- silently reduce an existing grant's capability" posture (see
        -- header) applies to a query failure exactly like it applies to a
        -- pre-migration database that has the base columns but not yet
        -- these new ones.
        print(('[qbx_k9unit] RefreshCertificationCache tier/expiry metadata query failed for %s/%s: %s -- defaulting to tier=%s, no expiry'):format(citizenid, jobName, tostring(metaRowOrErr), DEFAULT_TIER))
    elseif metaRowOrErr then
        -- OWNER-DIRECTED TIER-EDITING PASS: was `TIER_RANK[metaRowOrErr.tier]`
        -- (only the original three hardcoded keys could ever validate) —
        -- now defers to the live, operator-extensible catalog via
        -- IsKnownTierKeyOrLegacyFallback, so a row holding an
        -- operator-ADDED tier key validates too. Falls back to
        -- DEFAULT_TIER exactly as before for anything unrecognized
        -- (including a stale/corrupted string) — this branch's own
        -- "never silently reduce an existing grant's capability" posture
        -- (see header) is unchanged.
        if IsKnownTierKeyOrLegacyFallback(metaRowOrErr.tier) then
            tier = metaRowOrErr.tier
        end
        expiresAtUnix = tonumber(metaRowOrErr.expires_at_unix)
    end

    Certifications[citizenid] = {
        active = true,
        job = jobName,
        tier = tier,
        expiresAtUnix = expiresAtUnix,
        expired = IsExpiredUnix(expiresAtUnix),
    }
    RefreshSpecializationCache(citizenid, jobName)
    return true, true, true
end

--- Re-checks a SPECIFIC (citizenid, job) row's `active` column directly
--- against the DB, independent of and deliberately NOT via
--- RefreshCertificationCache's own return value -- see the three call
--- sites below (RevokeCertification, RevokeCertificationOffline, and the
--- QBCore:Server:OnJobUpdate auto-revoke branch) for why: that function's
--- fail-closed contract collapses "confirmed inactive" and "the read
--- itself failed" into the same `false`, which is the right call for an
--- ACCESS-checking consumer but the wrong one for a caller that just had
--- its OWN revoke UPDATE throw and needs to tell "the UPDATE genuinely
--- never committed" apart from "unreadable, true outcome unknown" before
--- deciding whether to report success or run any further side effects.
--- @param citizenid string
--- @param jobName string
--- @return boolean? active -- true/false if confirmed against the DB, nil if the read itself failed
local function IsCertRowConfirmedActive(citizenid, jobName)
    local ok, activeIdOrErr = pcall(K9Store.Cert_GetActiveId, citizenid, jobName)
    if not ok then
        print(('[qbx_k9unit] cert-row reconciliation read failed for %s/%s: %s'):format(citizenid, jobName, tostring(activeIdOrErr)))
        return nil
    end
    return activeIdOrErr ~= nil
end

--- DEVELOPER_REFERENCE.md §4.2 certifier eligibility check (granter side only — does not
--- check the target or proximity, see GrantCertification/RevokeCertification).
--- Also qualifies unconditionally for a High Command officer
--- (server/highcommand.lua's IsHighCommand, project-owner-directed this
--- pass — see that file's own header for the full "run any command"
--- contract), guarded by a `type(...) == 'function'` runtime existence
--- check inside the function body below.
--- @param source number
--- @return boolean
local function IsEligibleCertifier(source)
    local Player = exports.qbx_core:GetPlayer(source)
    if not Player or not Player.PlayerData then return false end

    local job = Player.PlayerData.job
    if not job or not Config.Departments[job.name] then return false end

    -- EXPLICIT PER-PERSON BLOCK (security-audit pass, this pass) -- see
    -- server/permissions.lua's own ADMIN_CAPABILITY_BLOCKABLE_KEYS doc
    -- comment for the full "why", and HasK9Access's own identical addition
    -- immediately above in this same file for the full "cost at scale" /
    -- "gates the start, never the stop" writeup, both equally true here:
    -- IsEligibleCertifier is a granter-side, request-time-only predicate
    -- (GrantCertification/RevokeCertification/renew/tier-change all call
    -- it once per request, never as part of an ongoing held state), so
    -- there is no "mid-action" concern for this function at all. Checked
    -- BEFORE job.isboss -- this is deliberately the ONE bypass in this
    -- function that a block must beat too, matching the owner's own
    -- stated model ("an explicit block beats everything, including High
    -- Command") applied here to the certifier's own boss status.
    if type(HasPermission) == 'function' and HasPermission(Player.PlayerData.citizenid, 'block.k9.certify') then
        return false
    end

    -- job.isboss always qualifies regardless of the configured numeric
    -- threshold.
    if job.isboss then return true end

    -- PERMISSION GRANT BYPASS (server/permissions.lua, Config.Features.PermissionGrants,
    -- resolution-order STEP 1) -- an active granted 'k9.certify' permission
    -- ALLOWS outright, checked before the high-command bypass and the
    -- certifierGrade comparison below, matching config.lua's own documented
    -- "first match wins" order. Guarded by a `type(...) == 'function'`
    -- runtime existence check -- this function still works exactly as
    -- before if server/permissions.lua is ever removed or
    -- Config.Features.PermissionGrants is false.
    if type(HasPermission) == 'function' and HasPermission(Player.PlayerData.citizenid, 'k9.certify') then return true end

    -- HIGH COMMAND BYPASS (server/highcommand.lua, Config.Features.HighCommand,
    -- project-owner-directed this pass) -- certifierGrade is explicitly one
    -- of the gates a High Command officer must bypass (see that file's own
    -- header PART 1 for the full contract). Guarded by a
    -- `type(...) == 'function'` runtime existence check, this resource's
    -- established soft-dependency convention -- this function still works
    -- exactly as before if server/highcommand.lua is ever removed or
    -- Config.Features.HighCommand is false (IsHighCommand re-checks that
    -- flag itself and returns false). Placed here, right after the
    -- job.isboss short-circuit and before the certifierGrade comparison,
    -- mirroring the identical placement in server/admin.lua's
    -- IsAuthorizedAdmin and server/bonetool.lua's
    -- IsAuthorizedBoneSweepDevTool.
    if type(IsHighCommand) == 'function' and IsHighCommand(source) then return true end

    -- SECURITY FIX (coder-security, authorization-root runtime-nil review):
    -- verified against tests/certifications_spec.lua's own file-header
    -- note (which assumed a nil/non-number `dept.certifierGrade` makes this
    -- comparison "simply always false") — that assumption held for a nil
    -- `certifierGrade` only by accident of Lua's `>=` on two nils never
    -- being reached (the old code never got that far without erroring
    -- first for a NUMBER `job.grade.level` compared against a nil/string
    -- `certifierGrade`). `dept.certifierGrade` itself is now guaranteed to
    -- be a number by the file-load-time assert above and is never mutated
    -- after load (Config is a shared_script, read-only from every file in
    -- this resource — grepped, nothing writes Config.Departments[...] at
    -- runtime), so that operand can no longer be the problem. The
    -- remaining, still-open gap is the OTHER operand: `job.grade.level` was
    -- only ever checked for nil-ness, not type — a job object shaped
    -- differently than qbx_core's documented `{ name, level: number }`
    -- schema (a non-number `level`) reaches the `>=` below and throws an
    -- UNCAUGHT comparison error instead of failing closed. Explicit type
    -- check, not a pcall, for the same reason given on the autoAccessGrade
    -- branch in HasK9Access above: a pcall here would swallow a real
    -- shape-mismatch bug and turn it into exactly the silent "certifier who
    -- can never certify anyone" no-op this file's own asserts above exist
    -- to stop happening quietly. FAILS CLOSED — a non-number `level` makes
    -- this whole function return false (not eligible), never true; the
    -- `job.isboss` early-return above is unaffected and still grants
    -- eligibility for a boss regardless of grade shape, matching DEVELOPER_REFERENCE.md's
    -- documented "isboss always qualifies" rule.
    local dept = Config.Departments[job.name]
    return job.grade ~= nil and type(job.grade.level) == 'number' and job.grade.level >= dept.certifierGrade
end

--- CONSOLIDATION (this pass, cross-team "four doors, one bug" finding):
--- losing K9 access must end an already-formed leash pairing, an
--- in-progress bite-hold/takedown/drag, and any active partnership
--- "immediately" per DEVELOPER_REFERENCE.md §1/§4.4, not just block future
--- attach/certify attempts — CheckLeashEligibility in server/main.lua is
--- only consulted at attach time, so a K9-role party who loses access
--- mid-session while actively leashed/holding/partnered would otherwise
--- stay that way until someone manually intervenes or a safety-valve
--- trips. This exact three-call sequence (ForceDetachLeashForSource +
--- EndActiveEffectForHolder + ForceBreakPartnershipForCitizenId) used to
--- be reimplemented independently at every one of THIS FILE's own call
--- sites that flips a citizenid's K9 access to lost — which is exactly why
--- the bug kept being found and fixed one call site at a time instead of
--- once (most recently: the department-loss branch of the
--- QBCore:Server:OnJobUpdate handler below only called
--- ForceDetachOfficerLeashForSource, never this function, so a
--- non-certified K9-role party — access via autoAccessGrade or a
--- server/permissions.lua 'k9.access' grant only — kept their leash on
--- leaving the department entirely; see that branch's own comment for the
--- fix). This is the ONE place in this file that means "citizenid has
--- just, provably, lost K9-role access — tear down every ephemeral/session
--- consequence of that THIS FUNCTION IS ABLE TO SAFELY TEAR DOWN" — see the
--- new SCOPE BOUNDARY paragraph immediately below for the one honest
--- exception, found and deliberately left as a disclosed gap rather than a
--- silent one by the kennel-vs-vehicle-seat race fix pass.
---
--- RELEASES AN EXCLUSIVE BODY CLAIM (kennel-vs-vehicle-seat race fix pass;
--- CLOSED this pass). Losing K9 access while resting inside a deployable
--- kennel or holding a vehicle seat claim is a real, reachable state, and
--- this function's own stated purpose -- tear down every session
--- consequence -- now genuinely covers it.
---
--- IT DOES NOT DO THE RELEASE ITSELF, AND THAT IS THE WHOLE DESIGN. The
--- state involved lives in three places: server/kennel.lua's KennelOccupants
--- table, server/vehicle.lua's VehicleSeatClaims table (both file-local by
--- deliberate design), and the affected player's own CLIENT, which is still
--- attached to the kennel prop or still sitting in the seat. Clearing only
--- the server registry -- the obvious shortcut -- would free that kennel or
--- seat for a SECOND citizenid while the first is visibly still in it: a
--- silent double-occupancy, strictly worse than the gap it appeared to
--- close. So this function makes ONE call, to
--- server/bodyclaims.lua's ForceReleaseBodyClaimForCitizenId dispatcher (see
--- the call site below), which routes to whichever mechanic owns that state
--- and lets that mechanic tear down its own registry AND tell the client to
--- physically let go, together or not at all.
---
--- Read ForceReleaseBodyClaimForCitizenId's own header for the rest: why
--- each mechanic registers its own releaser rather than exposing its tables,
--- why the live source is always resolved fresh instead of reusing this
--- function's `src`, why an offline target is a success rather than a
--- failure, and why a 'combat_target' claim -- held AGAINST this citizenid
--- by a third party mid-bite -- is deliberately the one thing left alone.
---
--- GATE THE STOP, NEVER THE START, and here that rule does real work:
--- neither the dispatcher nor any releaser may consult HasK9Access, a
--- certification lookup, a Config.Features flag or a cooldown, because this
--- entire path runs for a citizenid whose access has ALREADY been revoked.
--- An access check anywhere in it would be guaranteed false at exactly the
--- moment it matters, and would seal a decertified player inside their own
--- kennel.
---
--- Callable from a site with a live, already-resolved `source` for
--- `citizenid` (pass it as `knownSrc` — RevokeCertification's online
--- branch and all three OnJobUpdate branches always have one) or from a
--- site with only a `citizenid` (RevokeCertificationOffline — omit
--- `knownSrc` and this resolves it itself via
--- exports.qbx_core:GetPlayerByCitizenId, exactly like the
--- ForceDetachLeashIfOnline wrapper this function replaces already did).
--- Naturally a no-op for the leash/hold half on a genuinely offline
--- target: LeashPairs and any bite-hold/takedown/drag are in-memory/
--- ephemeral only (never persisted, per server/main.lua's and
--- server/combat.lua's own headers), so an offline citizenid cannot have
--- either to tear down in the first place. ForceBreakPartnershipForCitizenId
--- runs UNCONDITIONALLY of whether a live `src` was found at all — a
--- partnership row is DB-backed and works identically online or offline
--- (see that function's own "OFFLINE-CAPABLE BY DESIGN" doc comment).
---
--- Runs NO confirmation/reconciliation check of its own, and must never be
--- changed to add one: every call site below already runs its OWN "is
--- this loss actually confirmed" gate (a DB-write reconcile dance for the
--- certification-revoke paths, a plain boolean expression for the
--- autoAccessGrade-loss branch, an unconditional department-loss check)
--- BEFORE ever reaching this function — this is the unconditional, "no
--- unbounded trap" teardown for an ALREADY-CONFIRMED loss, not a second
--- gate that could itself block it. Two of this file's own regression
--- tests (tests/certifications_spec.lua, "a throwing UPDATE that genuinely
--- never committed") assert ZERO side effects — including zero calls into
--- this function — when that confirmation fails; that guarantee lives
--- entirely in each CALLER's own gating and must stay that way.
---
--- Deliberately does NOT call ForceDetachOfficerLeashForSource — that is a
--- DIFFERENT invariant (officer/handler-role department eligibility, not
--- K9-role access) that only the department-loss branch below needs, and
--- it keeps its own direct call for that reason.
---
--- NOT a resource-global, despite server/permissions.lua's own
--- RevokePermission needing this identical sequence for its 'k9.access'
--- de-assign path: doing that would need a new entry in BOTH
--- fxmanifest.lua's server_scripts list AND
--- /home/user/FIvem/.luacheckrc's `globals` table (verified: an
--- unregistered bare `function Foo()` is flagged by this repo's real
--- luacheck config as "setting a non-standard global variable"), and this
--- task has neither file assignable to it. tests/certifications_spec.lua
--- and tests/permissions_spec.lua also each load only the minimal file set
--- their own file under test needs, so a shared implementation would force
--- one spec to load a file it otherwise has no reason to (and inherit that
--- file's own file-load-time Config assertions as an unwanted side
--- effect). server/permissions.lua therefore keeps its OWN small, private,
--- identically-shaped copy of this function (see that file's own doc
--- comment on its copy for the full writeup) — one real duplicate between
--- two files, down from six independent inline copies before this pass.
--- @param citizenid string
--- @param reason string
--- @param knownSrc number? -- pass this file's own already-resolved live server id when known; omit for a citizenid-only caller to have this resolve it.
local function EndK9AccessForCitizenId(citizenid, reason, knownSrc)
    local src = knownSrc
    if type(src) ~= 'number' then
        local onlinePlayer = exports.qbx_core:GetPlayerByCitizenId(citizenid)
        src = onlinePlayer and onlinePlayer.PlayerData and onlinePlayer.PlayerData.source
    end

    if type(src) == 'number' then
        ForceDetachLeashForSource(src, reason)

        if type(EndActiveEffectForHolder) == 'function' then
            pcall(EndActiveEffectForHolder, src)
        end
    end

    if type(ForceBreakPartnershipForCitizenId) == 'function' then
        ForceBreakPartnershipForCitizenId(citizenid, reason)
    end

    -- EXCLUSIVE BODY-CLAIM RELEASE -- lets go of a kennel this citizenid is
    -- resting in, or a vehicle seat they hold, so losing access does not
    -- leave them attached to something the server has stopped tracking. The
    -- dispatcher routes to whichever mechanic actually owns that state and
    -- tells the player's client to physically let go; see
    -- server/bodyclaims.lua's ForceReleaseBodyClaimForCitizenId header for
    -- why a registry-only clear here would be worse than no fix at all, and
    -- for why a 'combat_target' claim (held AGAINST this citizenid by
    -- someone else) is deliberately left alone.
    --
    -- Deliberately UNCONDITIONAL, in the same shape as
    -- ForceBreakPartnershipForCitizenId immediately above: a runtime
    -- existence guard rather than a load-order dependency, and no access
    -- check of any kind. Never pass `src` -- the dispatcher resolves this
    -- citizenid's live source fresh, precisely because this function is
    -- also reachable for an offline citizenid and because server ids are
    -- recycled.
    if type(ForceReleaseBodyClaimForCitizenId) == 'function' then
        ForceReleaseBodyClaimForCitizenId(citizenid, reason)
    end
end

--- Returns true if `err` (the value pcall caught around the grant INSERT)
--- represents a MySQL/MariaDB duplicate-key error (1062) on
--- `uq_one_active_cert_per_job`. The exact shape of an error surfaced
--- through oxmysql's `.await` wrapper could not be confirmed against a
--- live oxmysql install in this sandbox, so this checks every shape the
--- underlying mysql2 driver is documented to use (a table with an
--- `.errno`/`.code` field, or a plain string containing the code) rather
--- than assuming one specific shape.
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

--- MOVED to server/events.lua (2026-08-25 cross-file cleanup pass): this
--- file's own `FireOutboundEvent` copy — byte-for-byte identical to the
--- five other copies that existed alongside it — is now the single shared
--- resource-global implementation in that file. See server/events.lua's
--- header for the full extraction writeup. Every call site below is
--- unchanged: same event names, arguments, order, and firing conditions.

--- CERTIFICATION DEPTH (this pass, Part B §11): a specialization cannot
--- outlive the base certification it requires. Bulk-revokes EVERY active
--- specialization row for (citizenid, job) in one UPDATE (no need to
--- enumerate individual specialization keys first) and refreshes the
--- specialization cache so a still-online target's cache reflects the
--- loss immediately. Called from all THREE existing base-revoke call
--- sites (RevokeCertification's online branch, RevokeCertificationOffline,
--- and the QBCore:Server:OnJobUpdate auto-revoke handler's own
--- cert-revocation branch) — mirrors the leash/partnership teardown call
--- sites already at each of those exact three places.
---
--- BEST-EFFORT, DELIBERATELY: pcall-wrapped and logged on failure, never
--- allowed to turn an already-confirmed, already-committed base
--- certification revoke into a reported failure — the base revoke is the
--- security-critical action; this cascade is a consistency cleanup on top
--- of it. A failure here leaves a specialization row stranded active
--- under a now-inactive base certification.
---
--- DB-AUTHORITATIVE, NOT CACHE-BASED: reads the active specialization set
--- fresh from `k9_certification_specializations` rather than from the
--- in-memory `Specializations` cache, DELIBERATELY — this function is
--- called from RevokeCertificationOffline (a genuinely offline citizenid
--- whose cache entry has already been evicted by `playerDropped`, per
--- this file's own cache-lifecycle convention) just as often as from the
--- online revoke path, and a cache-based read would silently cascade
--- nothing for exactly that offline case.
--- @param citizenid string
--- @param jobName string
--- @param revokedByCitizenidOrSentinel string -- citizenid, or 'system:job_change'
--- @param reason string -- passed straight through to the outbound event, matching this file's existing certificationRevoked reason tagging ('certification_revoked' | 'department_changed' | 'job_changed')
local function RevokeAllSpecializationsForCitizenJob(citizenid, jobName, revokedByCitizenidOrSentinel, reason)
    local selectOk, rowsOrErr = pcall(K9Store.Spec_GetActiveKeys, citizenid, jobName)
    if not selectOk then
        print(('[qbx_k9unit] RevokeAllSpecializationsForCitizenJob pre-read failed for %s/%s: %s -- base certification revoke already committed; specialization rows may be stranded active'):format(citizenid, jobName, tostring(rowsOrErr)))
        return
    end

    local revokedKeys = {}
    for _, row in ipairs(rowsOrErr or {}) do
        revokedKeys[#revokedKeys + 1] = row.specialization
    end
    if #revokedKeys == 0 then return end -- nothing active to cascade -- common case, avoid a needless UPDATE

    local updateOk, updateErr = pcall(K9Store.Spec_RevokeAllForJob, citizenid, jobName, revokedByCitizenidOrSentinel)

    if not updateOk then
        print(('[qbx_k9unit] RevokeAllSpecializationsForCitizenJob UPDATE failed for %s/%s: %s -- base certification revoke already committed; specialization rows may be stranded active until the next refresh'):format(citizenid, jobName, tostring(updateErr)))
        return
    end

    if Specializations[citizenid] then
        Specializations[citizenid][jobName] = {}
    end

    for _, key in ipairs(revokedKeys) do
        FireOutboundEvent('qbx_k9unit:events:specializationRevoked', citizenid, jobName, key, reason)
    end
end

-- SECURITY FIX (coder-security, final pass): grant/revoke are the single
-- most sensitive server-authoritative actions this resource exposes (they
-- ARE the permission system, per this file's header) — yet, unlike
-- server/main.lua's bark relay (BARK_COOLDOWN_MS) and leash-request
-- (LEASH_REQUEST_COOLDOWN_MS), nothing rate-limited them at all. An already
-- eligible certifier-grade officer (or one who self-certifies, per
-- Config.AllowSelfCertification) could otherwise script a tight
-- grant/revoke toggle loop against a nearby target — each iteration costs
-- at least one DB round trip, and on a real state flip, an INSERT/UPDATE
-- plus notifications to two players plus a leash force-detach check. Mirror
-- the exact same per-source cooldown pattern already established elsewhere
-- in this resource. Keyed by the CERTIFIER's own source (granterSrc), not
-- the target, so it throttles how often a given officer can issue ANY
-- certify/revoke action (online, offline, or self), independent of which
-- target/department is named.
local CERTIFY_ACTION_COOLDOWN_MS = 1500

-- DEVELOPER_REFERENCE.md item 1: was its own hand-rolled `lastCertifyActionAt`
-- table, now a NewCooldown() instance (server/cooldowns.lua) — same
-- threshold, same per-granter-source key, same playerDropped-based cleanup
-- (see CertifyActionCooldown.RegisterPlayerDropped() below), behavior
-- unchanged. IsCertifyActionOnCooldown below keeps its original name/
-- boolean-sense ("true" = on cooldown) so its three call sites don't need
-- to change at all — it's a thin wrapper around
-- `not CertifyActionCooldown.Consume(...)`, preserving the exact original
-- "check, and stamp iff not on cooldown" ordering.
local CertifyActionCooldown = NewCooldown(CERTIFY_ACTION_COOLDOWN_MS)
CertifyActionCooldown.RegisterPlayerDropped()

-- ECONOMY FIX (dedicated K9 pass, 2026-08-26 -- self-cert/decertify farm
-- loop, red-team-flagged): CERTIFY_ACTION_COOLDOWN_MS above and this new
-- tracker solve DIFFERENT problems, and conflating them is exactly the bug
-- being fixed here. CERTIFY_ACTION_COOLDOWN_MS is a flat, per-GRANTER
-- fat-finger guard on the ACTION (grant/revoke) -- it exists so a certifier
-- cannot double-click their way into two grants/revokes in the same
-- network tick, nothing more. It was never a MINT throttle, and the
-- comment that used to claim otherwise here (at GrantCertification/
-- GrantCertificationOffline's own AwardHandlerXP call sites below -- search
-- this file for "FALSIFIED CLAIM") and in config.lua's
-- Config.Features.HandlerXPProgression/Config.HandlerXP headers was simply
-- wrong, by this codebase's OWN standard:
-- Config.Features.HandlerXPProgression's header draws exactly this
-- action-cooldown-vs-mint-cooldown distinction for handlerTreatK9
-- (server/medkit.lua's per-TARGET MedkitCooldown throttles the action, not
-- a per-actor mint) and handlerKennelDeploy (server/kennel.lua's
-- DeployCooldown, same shape) -- and correctly leaves BOTH unwired until a
-- real mint cooldown lands for each. handlerCertifyK9 got a pass it never
-- earned: CERTIFY_ACTION_COOLDOWN_MS is the exact same "throttles the
-- action, not a per-actor mint" shape as those two, just spelled
-- differently (per-granter instead of per-target/per-actor), and Config.
-- AllowSelfCertification (true by default) plus RevokeCertification's own
-- "proximity is skipped for self-certification" branch make it trivial for
-- an already-eligible certifier to be their OWN repeatable target:
-- `/k9certify <self>` then `/k9decertify <self>`, on repeat, each side only
-- 1500ms apart (CERTIFY_ACTION_COOLDOWN_MS is a SINGLE tracker shared by
-- grant AND revoke, keyed by granterSrc, so the fastest full cycle is
-- 2 x 1500ms = 3000ms), and RevokeCertification's own base-revoke UPDATE
-- means the NEXT GrantCertification for that same (citizenid, job) always
-- sees `existingId == nil` again -- a genuinely "NEW" certification, by
-- this file's own existingId-based test, every single cycle.
--
-- THE ARITHMETIC THAT MAKES THIS THE WORST FARM IN THIS FILE, RE-DERIVED
-- FROM THE REAL SHIPPED CONSTANTS (measured, not argued from reading):
-- 50 XP (Config.HandlerXP.awards.handlerCertifyK9) every 3,000ms
-- (2 x CERTIFY_ACTION_COOLDOWN_MS) = 60,000 XP/hr GROSS, uncapped -- more
-- than TEN TIMES server/progression.lua's own EIGHTH-XP-FARM-FIX ceiling
-- for round-robining all four K9-mechanic mint cooldowns together
-- (5,700 XP/hr). The shared cross-mechanic XP mint budget (3,600 XP/hr +
-- a one-time starter allowance, server/progression.lua's XP_MINT_BUDGET_*)
-- DOES still bound the damage -- nobody mints unlimited XP -- but at
-- 60,000 XP/hr gross this ONE action alone saturates that ENTIRE shared
-- hourly budget in well under a minute, versus 13.92 minutes for
-- handlerKennelDeploy (5,760 XP/hr gross, uncapped, itself already judged
-- UNSAFE and left deliberately unwired for exactly that reason -- see
-- config.lua's Config.Features.HandlerXPProgression header). Reachable by
-- ANY certifier-grade officer (or boss) alone, no accomplice, no real K9
-- work, in seconds.
--
-- FIX: a real per-actor MINT cooldown on the handlerCertifyK9 AWARD itself
-- -- never on the grant/revoke ACTION (CERTIFY_ACTION_COOLDOWN_MS above is
-- unchanged and still guards fat-fingering; lengthening it would only slow
-- down legitimate admin work without closing this loop, since the loop
-- never needed anything faster than 1500ms per side). Keyed by the
-- (GRANTER, TARGET) citizenid PAIR, not by granter alone and not by target
-- alone:
--   - Per-granter alone would also throttle a certifier legitimately
--     certifying several DIFFERENT genuine new recruits in a row -- that is
--     real work and must keep paying every time.
--   - Per-target alone would block two DIFFERENT certifiers from each
--     legitimately certifying the same eventual target into two different
--     departments (a real, if rare, cross-training scenario) -- no reason
--     to punish the SECOND certifier for the first one's unrelated grant.
--   - Per-(granter, target) pair is the narrowest key that actually matches
--     the exploit shape: the SAME certifier repeatedly minting off the SAME
--     person (most often themselves).
--
-- WINDOW CHOSEN -- 24 REAL HOURS, DELIBERATELY, mirroring this same
-- codebase's own partnershipTenure1Day precedent (Config.XP.awards) for
-- "how long before a repeat of the same relationship counts as a new,
-- distinct event rather than a repeat of the last one": a certifier
-- re-certifying the exact same person again within the same day is
-- overwhelmingly a repeat/farm signal (an accidental double-grant, or
-- exactly this loop); re-certifying them after a day is a plausible,
-- distinct real event (they left the department and came back, an earlier
-- revoke-for-cause was reversed, etc.) and pays again. A FIRST
-- certification of a genuinely new person is a real milestone and always
-- pays immediately, regardless of how recently the SAME granter paid out
-- for a DIFFERENT target -- this cooldown never touches any other
-- (granter, target) pair.
--
-- RESULTING ARITHMETIC: capped at 50 XP per (granter, target) pair per 24h
-- = ~2.08 XP/hr from any single pair -- the self-cert loop's 60,000 XP/hr
-- gross collapses to a number the shared 3,600 XP/hr budget does not even
-- notice. To make handlerCertifyK9 alone matter again at scale, an
-- attacker would need dozens of genuinely DISTINCT real targets, each an
-- actual grant+revoke round trip against an actual other citizenid -- a
-- fundamentally different, far more expensive and far more visible attack
-- than a solo loop, and squarely the kind of "real, if unusual, activity"
-- this resource's economy is built to tolerate rather than the kind of
-- "farm loop" it exists to close.
--
-- NOT :RegisterPlayerDropped() -- keyed by CITIZENID, not player source
-- (mirrors this file's own ExpiryWarned/ExpiryLapsedNotified tables and
-- server/search.lua's CoopSearchXpMintCooldown, both citizenid-keyed and
-- both documented as deliberately NOT using :RegisterPlayerDropped for the
-- same reason: that hook clears by numeric `source`, which would never
-- match a citizenid key, and clearing on disconnect would defeat the
-- entire point of a cooldown meant to survive a relog). Bounded instead by
-- its own independent TTL sweep so this resource's memory footprint does
-- not grow forever across a long server lifetime -- same shape as
-- CoopSearchXpMintCooldown's own sweep in server/search.lua.
--
-- ACCEPTED, DOCUMENTED CAVEAT: this tracker is in-memory only, like every
-- other cooldown in this file (CertifyActionCooldown above included) --
-- a resource or server RESTART resets it, and a (granter, target) pair
-- that just paid out could pay out again immediately after one. This is a
-- narrower gap than the loop being closed: restarting a resource requires
-- admin action, not something a player can trigger at will the way the
-- original loop could be run indefinitely without any admin involvement.
-- Persisting this would need a new table/column (this file's own
-- migration-numbering precedent, e.g. migration 0017/0018, would be the
-- shape) -- judged out of scope for this pass, which exists to close the
-- player-triggerable loop, not to make every anti-farm structure in this
-- resource restart-proof. Flagged here explicitly rather than silently
-- left unmentioned, matching this pass's own PairTenureSeed finding
-- (server/partnership.lua) being called out the same way.
local CERTIFY_XP_MINT_COOLDOWN_MS = 24 * 60 * 60 * 1000 -- 24 real hours
local CertifyXpMintCooldown = NewCooldown()
CertifyXpMintCooldown.StartSweep(CERTIFY_XP_MINT_COOLDOWN_MS, function(now, loggedAt)
    return (now - loggedAt) > (CERTIFY_XP_MINT_COOLDOWN_MS * 2)
end)

--- Composite key for CertifyXpMintCooldown -- a flat NewCooldown() instance
--- (not NewNestedCooldown) keyed by a single "granterCitizenid:targetCitizenid"
--- string, matching server/main.lua's own resolved-identity-string precedent
--- (`'vehicle:<plate>' | 'person:<citizenid>'`) rather than the two-level
--- shape: nothing here ever needs "clear every target for this granter in
--- one shot" (NewNestedCooldown's own :Clear semantics), and a flat
--- NewCooldown is what exposes :StartSweep, which this tracker needs and
--- NewNestedCooldown does not offer (see server/cooldowns.lua's own
--- constructor comparison).
--- @param granterCitizenid string
--- @param targetCitizenid string
--- @return string
local function CertifyXpMintKey(granterCitizenid, targetCitizenid)
    return granterCitizenid .. ':' .. targetCitizenid
end

-- ==========================================================================
-- FARM FIX (audit finding, this pass -- "distinct-target certify farm").
-- CertifyXpMintCooldown above (24h, keyed by the (GRANTER, TARGET) PAIR)
-- closes re-minting off the SAME person -- it was never meant to, and still
-- does not, cap how many DIFFERENT people one granter may mint off in a
-- day. Verified against the real shipped code, not assumed:
--
--   1. `/k9certifyoffline <citizenid> <job>` accepts ANY non-empty string as
--      `citizenid` -- nothing in this file, and nothing in k9_certifications'
--      own schema (sql/install.sql has no FK from `citizenid` to qbx_core's
--      `players` table -- see that migration's own "a hard ERROR 1267" note
--      for why not), checks that this citizenid belongs to a real, existing
--      character. A certifier-grade officer can therefore call this command
--      with a freshly typed, never-before-seen string every time -- NO
--      multicharacter system, NO alt character, and NO accomplice required.
--   2. Even where a real distinct target IS required (the online
--      `/k9certify` path), a server whose multicharacter system allows
--      cheap creation and deletion of throwaway characters gets the
--      identical result more slowly: each new character is, to
--      CertifyXpMintCooldown, simply a citizenid it has never seen paired
--      with this granter before, so it always pays.
--
-- Either way, CertifyXpMintCooldown's own per-pair 24h window never
-- triggers, because every pair really is used exactly once. The other
-- floor this action rides, CERTIFY_ACTION_COOLDOWN_MS (1500ms, shared by
-- grant+revoke, per granter source), was only ever a fat-finger guard, not
-- a mint throttle (see that constant's own declaration comment) -- it does
-- not stand in the way of firing ten `/k9certifyoffline` calls with ten
-- fresh strings roughly 1.5s apart.
--
-- THE ARITHMETIC (re-derived against the REAL shipped numbers in config.lua
-- as of this pass, not assumed): Config.HandlerXP.awards.handlerCertifyK9 =
-- 50 XP, Config.HandlerXPTiers' own Master Handler threshold = 500 XP (10
-- mints). server/progression.lua's shared cross-mechanic
-- XP_MINT_BUDGET_STARTER_TOKENS -- a ONE-TIME allowance sized to cover a
-- genuine same-tick multi-milestone burst for ONE citizenid, see that
-- file's own "STARTING BALANCE" writeup -- sums to 505 XP today (280 from
-- Config.XP.awards + 225 from Config.HandlerXP.awards). That is
-- comfortably enough, ON ITS OWN, to pay all 10 handlerCertifyK9 mints
-- (500 XP) in one sitting, bound only by CERTIFY_ACTION_COOLDOWN_MS: 10
-- grants x 1500ms =~ 13.5-15 seconds from a cold start to MASTER HANDLER,
-- THE TOP RANK, with zero real recruiting, zero real duty time, and (via
-- the offline path) zero character creation at all. server/progression.lua's
-- own starter-allowance design comment explicitly assumed "certifying
-- dozens of distinct new people in an hour is not realistic" -- true for a
-- REAL recruiting drive, false for a fabricated or throwaway one, which is
-- exactly the gap this section closes. This is NOT a finding that the
-- shared budget is broken -- its own hourly/starter ceiling is completely
-- unaffected, unchanged, and still the correct backstop against every
-- OTHER mechanic combined -- it is that ONE mechanic with no per-granter
-- cap of its own can spend that entire starter allowance by itself, in
-- seconds, on targets that cost the attacker nothing.
--
-- FIX: Config.CertifyMaxNewGranteesPerDay (config.lua) -- the most DISTINCT
-- handlerCertifyK9 mints any one granter may collect in a rolling 24-hour
-- window, regardless of how many different (or fabricated) targets they
-- use. Gates ONLY the XP MINT, exactly like CertifyXpMintCooldown already
-- does -- see TryConsumeCertifyHandlerXpMint below -- never the
-- certification GRANT itself, which always succeeds regardless of this cap
-- (gate the reward, never the underlying action).
--
-- WEIGHED AGAINST THE LEGITIMATE CASE before picking a shape or a number: a
-- real training officer onboarding several genuine new recruits in one
-- evening is exactly the behaviour Config.HandlerXPTiers' own Master
-- Handler comment describes wanting ("roughly seven to ten personally-
-- granted certifications... spread across several weeks") -- a cap that
-- refuses recruit #2 of a six-recruit onboarding night would be strictly
-- worse than the farm it exists to stop. A flat per-granter TIME-SPACING
-- cooldown (mirroring CertifyXpMintCooldown's own shape, just keyed by
-- granter alone) was considered and rejected for exactly that reason: it
-- would force a genuine trainer to wait out a fixed interval between EACH
-- of those six recruits, one at a time -- a real, avoidable annoyance a
-- same-day BATCH cap does not impose. A rolling COUNT instead lets an
-- entire batch clear as fast as the recruits themselves can be processed,
-- then simply refuses further NEW mints until the next rolling day, which
-- is what actually needs throttling here (how many NEW people this pays
-- out for per day), not how far apart in time they were certified.
--
-- Config.CertifyMaxNewGranteesPerDay's shipped default (8) is chosen with
-- deliberate headroom above "six recruits in one evening" (that exact
-- legitimate scenario clears with two mints to spare), while still bounding
-- the farm above to AT LEAST a full day-plus of continuous, repeated,
-- VISIBLE manual effort to reach Master Handler (10 mints needed; 8 fit on
-- day one, the remaining 2 cannot mint until day one's OLDEST slot rolls
-- off 24h later) -- turning a single ~15-second script-friendly burst into
-- a multi-day grind an operator can actually notice, matching this
-- ladder's own stated intent far more closely than the pre-fix arithmetic
-- ever did.
--
-- WINDOW is a FILE-LOCAL CONSTANT, NOT a Config key -- same reasoning as
-- server/progression.lua's own XP_MINT_BUDGET_WINDOW_MS: the CAP (how
-- many) is a legitimate operator balance knob; the WINDOW SHAPE (a rolling
-- day) is a structural anti-farm floor, mirroring
-- CERTIFY_XP_MINT_COOLDOWN_MS's own identical 24h window one section up.
--
-- IMPLEMENTATION: Config.CertifyMaxNewGranteesPerDay independent "slots",
-- each its OWN flat NewCooldown() entry keyed by "granterCitizenid:slot<N>"
-- (the SAME composite-string-into-a-flat-NewCooldown technique
-- CertifyXpMintKey above already uses, for the identical reason --
-- :StartSweep is only exposed by NewCooldown, not NewNestedCooldown; see
-- CertifyXpMintKey's own doc comment). A mint is allowed only when at
-- least one of the granter's own `cap` slots is not currently on its own
-- 24h cooldown; on success, exactly ONE such slot is stamped. This is
-- mathematically a proper sliding-window counter of size `cap`: a slot
-- stamped at time T is unavailable again until exactly T + 24h, so at most
-- `cap` mints can ever land for one granter inside ANY rolling 24-hour
-- span -- never a fixed-clock-boundary window (no midnight-edge doubling,
-- the same boundary flaw server/progression.lua's own token-bucket
-- rejected a fixed-window counter for).
--
-- KEYED BY CITIZENID, NOT :RegisterPlayerDropped() -- same reasoning as
-- CertifyXpMintCooldown immediately above (a cooldown that resets on
-- reconnect is not a cooldown; this one must survive the granter logging
-- off and back on, including switching which of THEIR OWN characters is
-- online -- exactly the scenario this fix exists to close). Bounded
-- instead by CertifyNewGrantSlotCooldown's own :StartSweep below.
-- ==========================================================================
local CERTIFY_NEW_GRANT_WINDOW_MS = 24 * 60 * 60 * 1000 -- 24 real hours -- mirrors CERTIFY_XP_MINT_COOLDOWN_MS's own window; see this section's own "WINDOW" note above for why it is not a Config key

-- Sane upper bound on Config.CertifyMaxNewGranteesPerDay -- NOT a balance
-- knob (raising THIS requires editing this file's own source, same
-- "security floor, not an operator-tunable balance knob" posture as
-- server/progression.lua's XP_MINT_BUDGET_STARTER_TOKENS_CEILING_XP) --
-- purely a guard against a config typo (e.g. an extra zero) turning every
-- single certify action into a needlessly long loop. An operator who
-- genuinely wants a materially larger cap than this can still set one;
-- this only stops an accidental one.
local CERTIFY_MAX_NEW_GRANTEES_PER_DAY_CEILING = 1000
-- Used when Config.CertifyMaxNewGranteesPerDay is missing or invalid --
-- matches config.lua's own shipped default (see ResolveCertifyMaxNewGranteesPerDay
-- below for the missing-vs-invalid distinction).
local CERTIFY_MAX_NEW_GRANTEES_PER_DAY_FALLBACK = 8

local WarnedBadCertifyMaxNewGranteesPerDay = false

--- CLAMP AND WARN (never assert -- same posture as every other Config
--- reader in this file). A MISSING Config.CertifyMaxNewGranteesPerDay (nil
--- -- an install predating this pass, or a config an operator simply never
--- touched) falls back SILENTLY to CERTIFY_MAX_NEW_GRANTEES_PER_DAY_FALLBACK
--- (the shipped config.lua default) -- never a console warning for a value
--- nobody was ever asked to set. A PRESENT-BUT-INVALID value (wrong type,
--- NaN, zero, negative, non-integer) warns ONCE per resource lifetime and
--- then behaves exactly like "missing". Clamped to
--- CERTIFY_MAX_NEW_GRANTEES_PER_DAY_CEILING at the top end for the reason
--- that constant's own declaration comment gives.
--- @return number cap
local function ResolveCertifyMaxNewGranteesPerDay()
    local raw = Config.CertifyMaxNewGranteesPerDay
    if raw == nil then return CERTIFY_MAX_NEW_GRANTEES_PER_DAY_FALLBACK end
    if type(raw) == 'number' and raw == raw and raw >= 1 then
        return math.min(math.floor(raw), CERTIFY_MAX_NEW_GRANTEES_PER_DAY_CEILING)
    end
    if not WarnedBadCertifyMaxNewGranteesPerDay then
        WarnedBadCertifyMaxNewGranteesPerDay = true
        print(
            ('[qbx_k9unit] certifications.lua: Config.CertifyMaxNewGranteesPerDay must be a positive number ' ..
             '(found: %s). Using the built-in fallback of %d instead -- find Config.CertifyMaxNewGranteesPerDay ' ..
             'in config.lua and fix it.'):format(tostring(raw), CERTIFY_MAX_NEW_GRANTEES_PER_DAY_FALLBACK)
        )
    end
    return CERTIFY_MAX_NEW_GRANTEES_PER_DAY_FALLBACK
end

local CertifyNewGrantSlotCooldown = NewCooldown()
CertifyNewGrantSlotCooldown.StartSweep(CERTIFY_NEW_GRANT_WINDOW_MS, function(now, loggedAt)
    return (now - loggedAt) > (CERTIFY_NEW_GRANT_WINDOW_MS * 2)
end)

--- @param granterCitizenid string
--- @param slot number
--- @return string
local function CertifyNewGrantSlotKey(granterCitizenid, slot)
    return granterCitizenid .. ':slot' .. slot
end

--- Check-only (never stamps) -- returns the first of the granter's own
--- `cap` slots that is NOT currently on cooldown, or nil if all `cap` slots
--- are still within their own 24h window (this granter has already minted
--- `cap` NEW handlerCertifyK9 payouts in the last rolling day).
--- @param granterCitizenid string
--- @param cap number
--- @return number? availableSlot
local function FindAvailableCertifyNewGrantSlot(granterCitizenid, cap)
    for slot = 1, cap do
        if not CertifyNewGrantSlotCooldown.IsOnCooldown(CertifyNewGrantSlotKey(granterCitizenid, slot), CERTIFY_NEW_GRANT_WINDOW_MS) then
            return slot
        end
    end
    return nil
end

--- Single choke point for "should THIS handlerCertifyK9 mint actually pay
--- out right now" -- called from BOTH GrantCertification's and
--- GrantCertificationOffline's own doGrantInsert, so the two award doors
--- can never drift out of sync with each other (mirrors this file's own
--- existing "second door to the exact same event" reasoning for
--- CertifyXpMintCooldown itself). BOTH independent gates below must agree;
--- NEITHER one is weakened by the other's presence:
---   1. Config.CertifyMaxNewGranteesPerDay, PER-GRANTER, checked (never
---      consumed) FIRST -- see this section's own header above for the full
---      "distinct-target farm" writeup this closes. Checking before gate 2
---      below ever touches anything means a granter who is already at
---      today's cap never burns the NEW target's own once-per-pair 24h
---      cooldown for a mint that was never going to pay anyway -- that
---      target's very first certification with this granter is left
---      completely untouched by CertifyXpMintCooldown, so it can still pay
---      in full the moment a slot frees up, rather than ALSO being forced
---      to wait out its own fresh 24h pair-cooldown.
---   2. CertifyXpMintCooldown, PER-(GRANTER, TARGET) PAIR, 24h -- UNCHANGED,
---      see its own declaration comment above. Still the exact same
---      check-and-consume it always was.
--- Only once BOTH agree is the chosen slot itself stamped -- a slot is
--- never spent on a mint that gate 2 goes on to refuse.
--- @param granterCitizenid string
--- @param targetCitizenid string
--- @return boolean shouldMint
local function TryConsumeCertifyHandlerXpMint(granterCitizenid, targetCitizenid)
    local availableSlot = FindAvailableCertifyNewGrantSlot(granterCitizenid, ResolveCertifyMaxNewGranteesPerDay())
    if not availableSlot then return false end
    if not CertifyXpMintCooldown.Consume(CertifyXpMintKey(granterCitizenid, targetCitizenid), CERTIFY_XP_MINT_COOLDOWN_MS) then
        return false
    end
    CertifyNewGrantSlotCooldown.Touch(CertifyNewGrantSlotKey(granterCitizenid, availableSlot))
    return true
end

-- SECURITY FIX (dedicated K9 pass, 2026-08-25): closes GrantCertification's
-- check-then-act TOCTOU on ITS OWN TERMS, independent of whether
-- `uq_one_active_cert_per_job` (SQL migration 0004) has actually been
-- applied to this install. GrantCertification's existingId-pre-check-then-
-- INSERT sequence awaits two separate MySQL round trips; each `.await`
-- yields this handler's coroutine and lets FXServer resume/process other
-- queued server events — including another GrantCertification call — before
-- it comes back. On an install that HAS run migration 0004, a second
-- concurrent grant for the SAME (citizenid, job) landing in that window is
-- still caught, by the DB's own unique index (see IsDuplicateKeyError
-- below). On an install that has NOT run it, there is neither that index
-- nor the `active_cert_key` column, and nothing previously stopped two
-- concurrent certify actions for the same target/department (e.g. two
-- different certifier-grade officers certifying the same target within the
-- same network round trip) from both observing `existingId == nil` and both
-- successfully INSERTing an active row — silently violating the "at most
-- one active row per (citizenid, job)" invariant this file's revoke paths
-- rely on ("No LIMIT needed -- uq_one_active_cert_per_job guarantees at
-- most one row matches"). This in-memory lock, keyed "citizenid:job" (the
-- invariant is scoped per department), makes that invariant hold at the
-- application level UNCONDITIONALLY. It is not a substitute for running
-- migration 0004 (which also backfills `active_cert_key` for unrelated
-- reasons) -- it is defense-in-depth that does not depend on the DB
-- constraint's presence. Always released in GrantCertification, even if an
-- unexpected error is thrown mid-flight (pcall-wrapped there), so a thrown
-- error can never leave a target permanently stuck un-grantable.
local GrantInFlight = {}

--- @param granterSrc number
--- @return boolean onCooldown
local function IsCertifyActionOnCooldown(granterSrc)
    return not CertifyActionCooldown.Consume(granterSrc)
end

--- Regression-test fix (extract at the 3rd occurrence — this codebase's own
--- established convention, see server/cooldowns.lua's own extraction
--- precedent): GrantCertification, RevokeCertification, and
--- RevokeCertificationOffline each independently re-resolved the granter's
--- OWN citizenid via exports.qbx_core:GetPlayer(granterSrc) and notified on
--- failure with byte-identical logic. Single source of truth now — calls
--- NotifyPlayer itself on failure so every call site can just early-return
--- on a nil result.
--- @param granterSrc number
--- @return string? citizenid — nil if unresolvable (NotifyPlayer already sent)
local function ResolveGranterCitizenId(granterSrc)
    local granterPlayer = exports.qbx_core:GetPlayer(granterSrc)
    local granterCitizenid = granterPlayer and granterPlayer.PlayerData and granterPlayer.PlayerData.citizenid
    if not granterCitizenid then
        NotifyPlayer(granterSrc, locale('common.unable_to_resolve_citizenid'), 'error')
        return nil
    end
    return granterCitizenid
end

-- ======================================================================
-- WORKFLOW-CLARITY MESSAGE HELPERS (this pass — "make the certification
-- lifecycle smooth and self-explaining"). Every refusal this pass touches
-- is swapped to a NEW locale key rather than the existing one so its
-- (unchanged, already-shipped) text is never silently edited out from
-- under locales/en.json — this file may not edit that file directly (see
-- this pass's own report for the full list of proposed keys/text). The
-- OLD key stays defined, unused, in en.json; harmless. Every helper below
-- reads LIVE Config state at call time (never a value captured once at
-- file load) so the text a caller actually sees is always computed from
-- real, current state — never a hardcoded guess — per this task's own
-- "prove any new information is computed from real state" instruction.
-- ======================================================================

--- Deterministic (sorted), comma-joined list of a table's own string keys
--- -- used to tell a certifier which departments/specializations are
--- ACTUALLY configured right now, rather than leaving them to guess or
--- open config.lua. Sorted so the same input always reads back the same
--- way (both for a human reading two error toasts in a row, and for a
--- test asserting on the exact text).
--- @param tbl any
--- @return string -- "(none configured)" for a missing/empty/non-table input
local function SortedKeysJoined(tbl)
    if type(tbl) ~= 'table' then return '(none configured)' end
    local keys = {}
    for key in pairs(tbl) do
        if type(key) == 'string' then keys[#keys + 1] = key end
    end
    if #keys == 0 then return '(none configured)' end
    table.sort(keys)
    return table.concat(keys, ', ')
end

--- @return string
local function ConfiguredDepartmentsList()
    return SortedKeysJoined(Config.Departments)
end

--- @return string
local function ConfiguredSpecializationsList()
    return SortedKeysJoined(Config.K9Specializations)
end

--- How many features on THIS server currently need a separate permission
--- grant on top of certification (config.lua's Config.FeatureControl.
--- RequireGrant) -- read live, not cached, so an operator who edits this
--- table is reflected immediately in the next grant's own summary. Only
--- entries whose value is literally `true` count (mirrors
--- server/pursuitsprint.lua's own documented RequireGrant resolution --
--- a non-true value there is already treated as "not require-grant").
--- @return number
local function CountFeaturesRequiringGrant()
    local requireGrant = Config.FeatureControl and Config.FeatureControl.RequireGrant
    if type(requireGrant) ~= 'table' then return 0 end
    local count = 0
    for _, requires in pairs(requireGrant) do
        if requires == true then count = count + 1 end
    end
    return count
end

--- WORKFLOW CLARITY (this pass, item 1 — "a certifier is never told what
--- is still missing"). Sends the granter ONE additional, informational
--- notice right after a successful grant (online or offline — both
--- GrantCertification and GrantCertificationOffline call this, after their
--- own cache refresh has already run) summarizing exactly what a fresh
--- certification does NOT yet include: a fresh grant always creates the
--- DB's own default tier with zero specializations (see this file's header
--- "TIER" — GrantCertification never accepts a tier argument on purpose),
--- and — independently of this file entirely — some features may still
--- need a SEPARATE grant via server/permissions.lua before they work.
---
--- EVERY NUMBER HERE IS READ FROM REAL STATE, NEVER ASSUMED: `tier` comes
--- from the live `Certifications` cache this same call just populated (not
--- a hardcoded 'certified' literal), the specialization count comes from
--- the live `Specializations` cache (also just populated), and the
--- require-grant count comes from a live read of
--- Config.FeatureControl.RequireGrant at the moment of the call.
--- @param granterSrc number
--- @param citizenid string
--- @param jobName string
local function SendGrantSuccessNextSteps(granterSrc, citizenid, jobName)
    local specCount = 0
    local specsForJob = Specializations[citizenid] and Specializations[citizenid][jobName]
    if type(specsForJob) == 'table' then
        for _ in pairs(specsForJob) do specCount = specCount + 1 end
    end
    -- A brand-new grant never has a specialization of its own yet (this
    -- function has no INSERT path into k9_certification_specializations),
    -- but this reads the real cache rather than assuming 0 -- correct even
    -- if a future pass ever changes what a grant seeds.
    if specCount > 0 then return end

    local requireGrantCount = CountFeaturesRequiringGrant()
    if requireGrantCount > 0 then
        NotifyPlayer(granterSrc, locale('certifications.grant_success_next_steps', requireGrantCount), 'inform')
    else
        NotifyPlayer(granterSrc, locale('certifications.grant_success_next_steps_no_grants'), 'inform')
    end
end

-- ======================================================================
-- CERTIFY AS HANDLER OR AS K9 -- one step either way.
--
-- A certification is the credential BOTH halves of a team hold: the human
-- handler (fetch, gear, the tablet's own abilities) and the player who
-- plays the dog. Certifying used to ALWAYS turn the person into
-- Config.Peds[1] as a side effect -- so certifying a human handler, which
-- the Guide told every new handler to get, turned them into a German
-- shepherd, and making a K9 of a specific breed took a certify AND a
-- separate "Assign K9 Role".
--
-- Now the certifier says which they mean. `k9Model` nil = a handler: the
-- certification is granted and nothing about how they look changes.
-- `k9Model` = one of Config.Peds' models = a K9: certified AND turned into
-- that breed, in the same action. The look change still only happens
-- while Config.K9Appearance.applyPedModelOnCertify is on.
--
-- Who may do this is unchanged: a certifier could already turn someone
-- into a dog by certifying them; this only lets them choose not to, or
-- choose the breed.
-- ======================================================================

--- @param k9Model any
--- @return boolean -- true for nil (a handler) or a model listed in Config.Peds
local function IsValidK9ModelChoice(k9Model)
    if k9Model == nil then return true end
    if type(k9Model) ~= 'string' or k9Model == '' then return false end
    for _, pedEntry in ipairs(Config.Peds or {}) do
        if pedEntry.model == k9Model then return true end
    end
    return false
end

--- Applies the chosen breed after a successful certification, if one was
--- chosen. A no-op for a handler.
--- @param targetCitizenid string
--- @param granterCitizenid string?
--- @param k9Model string?
--- True when this certify will itself turn the person into the chosen
--- breed. Config.K9Appearance.requireK9ModelForRole ("only someone already
--- on a K9 model may be certified") must not refuse a Certify-as-K9 for
--- not being a dog YET -- becoming one is what this certify does.
--- @param k9Model string?
--- @return boolean
local function WillApplyChosenK9Look(k9Model)
    return k9Model ~= nil and Config.K9Appearance ~= nil and Config.K9Appearance.applyPedModelOnCertify == true
        and type(ApplyK9AppearanceOnGrant) == 'function'
end

local function ApplyChosenK9Look(targetCitizenid, granterCitizenid, k9Model)
    if k9Model == nil then return end
    if Config.K9Appearance and Config.K9Appearance.applyPedModelOnCertify
        and type(ApplyK9AppearanceOnGrant) == 'function' then
        ApplyK9AppearanceOnGrant(targetCitizenid, granterCitizenid, k9Model)
    end
end

--- DEVELOPER_REFERENCE.md §4.2/§4.3 grant flow. Called by both event 2 and command 6, and
--- (this pass) the K9 Command Tablet's server-side aggregation layer
--- (server/tablet.lua -- see GrantCertificationForTablet below) via its
--- own resolved, online-only server id.
---
--- RETURN VALUE, ADDED THIS PASS (purely additive -- every pre-existing
--- caller (the RegisterNetEvent/RegisterCommand handlers near the bottom
--- of this file) discards both return values today, exactly as it
--- discarded the previous bare `return`/no-value return, so this changes
--- NO observable behavior for either of them; tests/certifications_spec.lua's
--- 47+ GrantCertification cases assert on NotifyPlayer/MySQL/cache side
--- effects only, never on a return value that did not exist before).
--- Mirrors server/permissions.lua's GrantPermission `(ok, outcome)` shape
--- exactly, and the same `local outcome` + doGrantInsert-closure-sets-it
--- convention that file's own header credits to this function in the
--- first place -- brought back here now that a second caller (the tablet)
--- actually needs a real result instead of only a fire-and-forget toast.
--- @param granterSrc number
--- @param targetServerId number
--- @param k9Model string? -- see CERTIFY AS HANDLER OR AS K9, above
--- @return boolean ok
--- @return string outcome -- 'invalid_target' | 'invalid_model' | 'not_eligible' | 'rate_limited' | 'self_certification_disabled' | 'target_must_be_online' | 'target_not_in_department' | 'target_too_far' | 'target_not_k9_model' | 'already_certified' | 'invalid_granter' | 'db_error' | 'ok'
local function GrantCertification(granterSrc, targetServerId, k9Model)
    if type(targetServerId) ~= 'number' then
        NotifyPlayer(granterSrc, locale('certifications.invalid_target_id'), 'error')
        return false, 'invalid_target'
    end
    if not IsValidK9ModelChoice(k9Model) then
        NotifyPlayer(granterSrc, locale('dogcharacter.invalid_model'), 'error')
        return false, 'invalid_model'
    end

    if not IsEligibleCertifier(granterSrc) then
        NotifyPlayer(granterSrc, locale('certifications.not_authorized_to_certify_hint'), 'error')
        return false, 'not_eligible'
    end

    if IsCertifyActionOnCooldown(granterSrc) then
        return false, 'rate_limited' -- silent no-op (no NotifyPlayer): rate-limited, not an error worth notifying about (matches bark/leash-request convention)
    end

    -- §4.1: self-certification only allowed if the flag is enabled.
    local isSelfCert = granterSrc == targetServerId
    if isSelfCert and not Config.AllowSelfCertification then
        NotifyPlayer(granterSrc, locale('certifications.self_certification_disabled_hint'), 'error')
        return false, 'self_certification_disabled'
    end

    -- Grant requires an online target — unlike revoke, which DEVELOPER_REFERENCE.md
    -- §4.3's flow table explicitly documents as working offline.
    --
    -- WORKFLOW CLARITY (this pass, item 3 — "the offline variants behave
    -- differently... in ways that are correct but surprising"): a granter
    -- who just typed a numeric server id for someone who isn't connected
    -- has no way to know an offline-capable path even exists unless told
    -- right here. Which alternative to point at depends on LIVE config,
    -- not a guess — /k9certifyoffline itself refuses outright when
    -- Config.K9Appearance.requireK9ModelForRole is on (that path cannot
    -- run the model check at all — see GrantCertificationOffline's own
    -- header), so telling a granter to use it in that configuration would
    -- be pointing at a command that is ITSELF about to refuse. Read the
    -- SAME flag GrantCertificationOffline itself reads, so the two
    -- messages can never disagree about which path is actually available.
    local targetPlayer = exports.qbx_core:GetPlayer(targetServerId)
    if not targetPlayer or not targetPlayer.PlayerData then
        if Config.K9Appearance and Config.K9Appearance.requireK9ModelForRole == true then
            NotifyPlayer(granterSrc, locale('certifications.target_must_be_online_model_check'), 'error')
        else
            NotifyPlayer(granterSrc, locale('certifications.target_must_be_online_use_offline'), 'error')
        end
        return false, 'target_must_be_online'
    end

    -- §4.2 item 3: cross-department granting IS currently allowed (open
    -- question §9 item 2 in DEVELOPER_REFERENCE.md, not resolved here) — this only requires
    -- the target be in *some* configured department, not the SAME one as
    -- the granter. Do not silently restrict to same-department.
    local targetJob = targetPlayer.PlayerData.job
    if not targetJob or not Config.Departments[targetJob.name] then
        NotifyPlayer(granterSrc, locale('certifications.target_not_in_department_hint', ConfiguredDepartmentsList()), 'error')
        return false, 'target_not_in_department'
    end

    -- §4.2 item 4 proximity — skipped only for self-cert (nothing to measure
    -- distance to). Live server-side coordinates only, never client-claimed.
    if not isSelfCert then
        local granterPed = GetPlayerPed(granterSrc)
        local targetPed = GetPlayerPed(targetServerId)
        local dist = #(GetEntityCoords(granterPed) - GetEntityCoords(targetPed))
        if dist > Config.CertifyProximityMeters then
            NotifyPlayer(granterSrc, locale('certifications.target_too_far_to_certify_distance', tostring(Config.CertifyProximityMeters)), 'error')
            return false, 'target_too_far'
        end
    end

    -- §4.2 item 5 (grant-only, applies UNIFORMLY even to self-certification):
    -- target's LIVE server-side ped model must be a configured K9 model --
    -- but ONLY when Config.K9Appearance.requireK9ModelForRole is explicitly
    -- true (coder-architect, K9 role/model decoupling pass,
    -- server/appearance.lua). At the false default the K9 ROLE is an
    -- assignment held against a citizenid, independent of what they
    -- currently look like (a human, an unlisted custom model, whatever) --
    -- see server/appearance.lua's header for the full decoupling writeup.
    -- Guarded with `Config.K9Appearance and` for a defensive read: this
    -- file does not itself assert that table's shape (server/appearance.lua
    -- does, at ITS OWN load time), so a config predating this feature or a
    -- config.lua edited out from under this table would otherwise throw
    -- here instead of falling back to the pre-decoupling behavior.
    if Config.K9Appearance and Config.K9Appearance.requireK9ModelForRole == true and not WillApplyChosenK9Look(k9Model) then
        local targetModel = GetEntityModel(GetPlayerPed(targetServerId))
        if not IsConfiguredK9Model(targetModel) then
            NotifyPlayer(granterSrc, locale('certifications.target_not_k9_model_hint'), 'error')
            return false, 'target_not_k9_model'
        end
    end

    local targetCitizenid = targetPlayer.PlayerData.citizenid
    local jobName = targetJob.name

    -- SECURITY FIX (dedicated K9 pass, 2026-08-25): see GrantInFlight's own
    -- doc comment above for the full writeup. Reject outright (rather than
    -- queue/retry) if a grant for this exact (citizenid, job) is already in
    -- flight on this server — the in-flight attempt will resolve to success
    -- or failure on its own, and this caller's own click can simply be
    -- retried if it turns out to have lost the race.
    local lockKey = targetCitizenid .. ':' .. jobName
    if GrantInFlight[lockKey] then
        NotifyPlayer(granterSrc, locale('certifications.target_already_certified_hint'), 'inform')
        return false, 'already_certified'
    end
    GrantInFlight[lockKey] = true

    -- RETURN VALUE, ADDED THIS PASS: `outcome` is set by doGrantInsert below
    -- (an upvalue, since doGrantInsert's own `return` exits the closure, not
    -- this outer function) and read back after the pcall -- identical shape
    -- to server/permissions.lua's GrantPermission, which this function's own
    -- doc comment already credits as the precedent for this exact pattern.
    local outcome
    -- Everything from here down is the actual DB critical section this lock
    -- protects — wrapped in its own closure so it can be pcall'd as a unit
    -- below, guaranteeing GrantInFlight[lockKey] is released on EVERY exit
    -- path, including an unexpected thrown error, not just the normal
    -- early-return paths.
    local function doGrantInsert()
        -- App-level pre-check (§4.3 invariant: at most one active row per
        -- (citizenid, job)) — now protected at the application level
        -- unconditionally by GrantInFlight above, and further backstopped
        -- below by the DB's unique index in case that constraint is present
        -- on this install (see IsDuplicateKeyError).
        local existingId = K9Store.Cert_GetActiveId(targetCitizenid, jobName)
        if existingId then
            NotifyPlayer(granterSrc, locale('certifications.target_already_certified_hint'), 'inform')
            outcome = 'already_certified'
            return
        end

        local granterCitizenid = ResolveGranterCitizenId(granterSrc)
        if not granterCitizenid then
            outcome = 'invalid_granter'
            return
        end

        -- CERTIFICATION DEPTH (this pass, Part A §9): a brand-new grant
        -- starts its own expiry clock immediately, but ONLY when an
        -- operator has explicitly opted in — see this file's header
        -- "COMPATIBILITY"/"EXPIRY" sections. `tier` is deliberately NOT
        -- part of this INSERT at all (see header "TIER") — every new row
        -- still gets the DB's own DEFAULT 'certified', byte-identical to
        -- this INSERT's shape before this pass, for the "else" branch
        -- below (which is exactly what every existing test already
        -- exercises). Date arithmetic happens in SQL
        -- (`DATE_ADD(NOW(), INTERVAL ? DAY)`), never in Lua — see header
        -- "EXPIRY" item 3. CLAMP-AND-WARN on a misconfigured
        -- CertificationExpiryDays lives in ResolveConfiguredExpiryDays
        -- (shared with RenewCertification below) — see its own doc comment.
        local expiryDays = ResolveConfiguredExpiryDays()

        -- K9Store.Cert_Insert owns the with-expiry/without-expiry SQL
        -- branch internally now (byte-identical to the two insertSql
        -- shapes this used to build here) -- see its own doc comment.
        local insertOk, insertResultOrErr = pcall(K9Store.Cert_Insert, targetCitizenid, jobName, granterCitizenid, expiryDays)

        if not insertOk then
            if IsDuplicateKeyError(insertResultOrErr) then
                -- Another request won the check-then-act race between the
                -- pre-check above and this INSERT DESPITE GrantInFlight above
                -- — only possible if this install predates GrantInFlight ever
                -- having been held for the other request too (e.g. a very
                -- unlucky reload) or the DB already held a pre-existing
                -- duplicate from before this lock existed; the DB's own
                -- unique index (`uq_one_active_cert_per_job`, if present on
                -- this install) is what actually caught it here. Treat
                -- identically to the normal "already certified" no-op, not as
                -- an unhandled error.
                RefreshCertificationCache(targetCitizenid, jobName)
                NotifyPlayer(granterSrc, locale('certifications.target_already_certified_hint'), 'inform')
                outcome = 'already_certified'
                return
            end

            print(('[qbx_k9unit] GrantCertification INSERT failed for %s/%s: %s'):format(targetCitizenid, jobName, tostring(insertResultOrErr)))
            NotifyPlayer(granterSrc, locale('certifications.grant_error'), 'error')
            outcome = 'db_error'
            return
        end

        RefreshCertificationCache(targetCitizenid, jobName)

        -- BUGFIX (this pass, found while tracing the EXPIRY chain
        -- end-to-end): a brand-new grant re-arms the one-per-session
        -- warn/lapsed flags -- mirrors RenewCertification's own identical
        -- reset a few functions below (see that call site's comment).
        -- Without this, a citizenid whose PREVIOUS certification already
        -- triggered ExpiryWarned/ExpiryLapsedNotified this session (they
        -- were warned, or their cert fully lapsed), then got revoked and
        -- certified again — a real, ordinary sequence, not a corner case:
        -- exactly the citizenid who just lived through a lapse is the one
        -- most likely to be re-certified afterward — would keep those
        -- stale flags set against their CITIZENID (not their old cert row),
        -- so CheckAndNotifyExpiry would silently refuse to warn/announce
        -- for the NEW certification's own, entirely separate expiry clock
        -- until they disconnect and reconnect (playerDropped is the only
        -- other place these are cleared). That silently breaks this file's
        -- own header promise ("nobody should find out by an ability
        -- silently refusing to work") for the one citizenid it matters most
        -- for. Harmless no-op the overwhelmingly common way this runs: a
        -- citizenid's first-ever certification, or a re-grant that never
        -- triggered either notice, already has both flags nil/false.
        ExpiryWarned[targetCitizenid] = nil
        ExpiryLapsedNotified[targetCitizenid] = nil

        -- Outbound integration event (server/exports.lua's EVENT CONTRACT §1) —
        -- fired here, after the cache refresh that itself follows the committed
        -- INSERT, so any consumer reacting to this has already-committed,
        -- server-authoritative state to query back against (HasK9Access/
        -- GetActivePartnerCitizenId/etc.) if it wants to. Not gated on any
        -- Config.Features flag: certification is this resource's core access
        -- gate (DEVELOPER_REFERENCE.md §4.1), not a phase-numbered toggle, matching this same
        -- reasoning already applied to HasK9Access itself in server/exports.lua's
        -- header.
        FireOutboundEvent('qbx_k9unit:events:certificationGranted', targetCitizenid, jobName, granterCitizenid)

        -- HANDLER XP (Config.Features.HandlerXPProgression, server/
        -- progression.lua) -- paid to the GRANTER, never the target, for
        -- the config-documented 'handlerCertifyK9' action: this INSERT only
        -- ever runs for a genuinely NEW certification (existingId's own
        -- check above already refused a re-grant onto an already-active
        -- row) -- but "genuinely new INSERT" is NOT the same claim as
        -- "rare and hard to repeat cheaply". A self-certifying (or boss)
        -- officer can grant, then revoke, then grant the SAME target again
        -- in seconds (Config.AllowSelfCertification + this function's own
        -- per-granter IsCertifyActionOnCooldown alone never stopped that --
        -- see CertifyXpMintCooldown's own declaration comment above, near
        -- CERTIFY_ACTION_COOLDOWN_MS, for the full "FALSIFIED CLAIM"
        -- writeup and arithmetic; the comment that used to sit here making
        -- that exact false claim is corrected, not just patched around).
        -- CertifyXpMintCooldown below is the real, dedicated per-
        -- (granter, target) MINT throttle that closes it -- gates ONLY
        -- this XP payout, never the certification grant itself, which
        -- always succeeds regardless. Safe to call AwardHandlerXP
        -- unconditionally here (it itself re-checks
        -- Config.Features.HandlerXPProgression as its own first line, and
        -- this file does not need to know or care whether that flag is on)
        -- -- runtime existence guard, not a load-order assumption
        -- (server/progression.lua loads AFTER this file in
        -- fxmanifest.lua's server_scripts list) -- same soft-dependency
        -- convention as ApplyK9AppearanceOnGrant's own guard immediately
        -- below.
        -- FARM FIX (this pass) -- CertifyXpMintCooldown alone (per-pair,
        -- 24h) never caps how many DIFFERENT targets one granter can mint
        -- off in a day (real alts, or via /k9certifyoffline, fabricated
        -- citizenid strings) -- see TryConsumeCertifyHandlerXpMint's own
        -- declaration comment (immediately after CertifyXpMintKey above)
        -- for the full writeup and arithmetic this closes. Both gates run
        -- as one unit now; CertifyXpMintCooldown itself is unchanged.
        if type(AwardHandlerXP) == 'function'
            and TryConsumeCertifyHandlerXpMint(granterCitizenid, targetCitizenid) then
            AwardHandlerXP(granterCitizenid, 'handlerCertifyK9')
        end

        -- Read-only mirror for client HUD display ONLY (DEVELOPER_REFERENCE.md §4.3) — NEVER
        -- read by any server-side authorization check. Do not add a read of
        -- this field to HasK9Access or any other gate.
        targetPlayer.Functions.SetMetaData('k9certified', true)

        -- SECURITY/CONSISTENCY FIX (coder-security, this pass -- "prove
        -- role and model are genuinely separate, everywhere" audit):
        -- server/appearance.lua's own header documents ApplyK9AppearanceOnGrant
        -- as being called from BOTH server/permissions.lua's GrantPermission
        -- (for a 'k9.access' grant) AND this function -- README.md's own
        -- "How a K9 gets made" section promises the SAME automatic model
        -- swap for either path, on the shipped default
        -- (Config.K9Appearance.applyPedModelOnCertify = true). This call
        -- was entirely MISSING from this file: a plain /k9certify grant (or
        -- the "Certify K9 Handler" ox_target option) never turned the
        -- target into the configured ped, silently breaking that documented
        -- promise for what is very likely the MORE commonly used of the two
        -- "how a K9 gets made" paths -- the permission-grant path
        -- (server/permissions.lua) already had this wired correctly, so the
        -- role/model coupling only ever worked for ONE of the two doors.
        -- Mirrors server/permissions.lua's own identical guard/call shape
        -- exactly -- see that file's own GrantPermission for the precedent.
        -- `modelName` is omitted (nil): neither this function nor
        -- server/permissions.lua's GrantPermission carries an explicit
        -- model choice of its own, so ApplyK9AppearanceOnGrant's own
        -- documented default (Config.Peds[1].model) applies, exactly as it
        -- already does for a plain 'k9.access' grant.
        ApplyChosenK9Look(targetCitizenid, granterCitizenid, k9Model)

        NotifyPlayer(granterSrc, locale(k9Model and 'certifications.grant_success_granter_k9' or 'certifications.grant_success_granter'), 'success')
        NotifyPlayer(targetServerId, locale('certifications.grant_success_target'), 'success')

        -- WORKFLOW CLARITY (this pass, item 1 — "a certifier is never told
        -- what is still missing"): a fresh grant leaves the target at the
        -- DB's own default tier with zero specializations, and — completely
        -- independently of anything this file controls — several features
        -- may still need a SEPARATE permission grant (server/permissions.lua,
        -- Config.FeatureControl.RequireGrant) before they work at all. Every
        -- value here is read from the STATE THIS CALL JUST PRODUCED
        -- (RefreshCertificationCache above already populated `Certifications
        -- [targetCitizenid]` and `Specializations[targetCitizenid]` from the
        -- row this INSERT committed, and CountFeaturesRequiringGrant reads
        -- Config.FeatureControl.RequireGrant live) — never an assumed
        -- constant — so this stays correct if the DB default tier, the
        -- specialization catalog, or the require-grant list ever change.
        SendGrantSuccessNextSteps(granterSrc, targetCitizenid, jobName)
        outcome = 'ok'
    end

    local grantOk, grantErr = pcall(doGrantInsert)
    GrantInFlight[lockKey] = nil
    if not grantOk then
        print(('[qbx_k9unit] GrantCertification unexpected error for %s/%s: %s'):format(targetCitizenid, jobName, tostring(grantErr)))
        NotifyPlayer(granterSrc, locale('certifications.grant_error'), 'error')
        return false, 'db_error'
    end

    return outcome == 'ok', outcome
end

--- Offline-capable counterpart to GrantCertification -- see
--- GrantCertificationForTablet's own header immediately below for the full
--- "why this is now safe, and when it deliberately still refuses" writeup.
--- Reuses the SAME `GrantInFlight` table and lock-key SHAPE
--- (`citizenid .. ':' .. jobName`) GrantCertification's own online path
--- uses, so a concurrent online + offline grant attempt for the identical
--- (citizenid, job) still serializes through the ONE lock rather than two
--- independent ones, and the SAME DB-authoritative existingId pre-check +
--- IsDuplicateKeyError backstop that function's own doGrantInsert already
--- uses. Has NO proximity check (impossible against a disconnected target,
--- same reasoning as every other offline-capable action in this file) and
--- the SAME "refuse if actually online right now" TOCTOU/proximity-bypass
--- guard RevokeCertificationOffline/SetCertificationTierOffline/
--- RenewCertificationOffline already establish.
--- @param granterSrc number
--- @param citizenid string
--- @param jobName string
--- @param k9Model string? -- see CERTIFY AS HANDLER OR AS K9
--- @return boolean ok
--- @return string outcome -- 'invalid_model' | 'not_eligible' | 'on_cooldown' | 'invalid_target' | 'invalid_department' | 'model_check_requires_online' | 'target_online_use_online_action' | 'invalid_granter' | 'already_certified' | 'db_error' | 'ok'
local function GrantCertificationOffline(granterSrc, citizenid, jobName, k9Model)
    if not IsValidK9ModelChoice(k9Model) then
        NotifyPlayer(granterSrc, locale('dogcharacter.invalid_model'), 'error')
        return false, 'invalid_model'
    end

    if not IsEligibleCertifier(granterSrc) then
        NotifyPlayer(granterSrc, locale('certifications.not_authorized_to_certify_hint'), 'error')
        return false, 'not_eligible'
    end

    if IsCertifyActionOnCooldown(granterSrc) then
        return false, 'on_cooldown'
    end

    if type(citizenid) ~= 'string' or citizenid == '' or type(jobName) ~= 'string' or jobName == '' then
        NotifyPlayer(granterSrc, locale('certifications.usage_certify'), 'error')
        return false, 'invalid_target'
    end

    if not Config.Departments[jobName] then
        NotifyPlayer(granterSrc, locale('certifications.invalid_department_hint', jobName, ConfiguredDepartmentsList()), 'error')
        return false, 'invalid_department'
    end

    -- See this function's own header (immediately above) and
    -- GrantCertificationForTablet's own header (immediately below) for the
    -- full "why this is the ONE deliberate refusal, never a silent
    -- no-model-check exception" writeup.
    if Config.K9Appearance and Config.K9Appearance.requireK9ModelForRole == true and not WillApplyChosenK9Look(k9Model) then
        NotifyPlayer(granterSrc, locale('certifications.certify_offline_requires_online_model_check'), 'error')
        return false, 'model_check_requires_online'
    end

    -- SECURITY (mirrors RevokeCertificationOffline's own identical guard):
    -- this path exists ONLY to reach a genuinely disconnected target --
    -- refuse and point at the proximity-checked `/k9certify` if `citizenid`
    -- actually resolves to a currently-connected player right now.
    local onlineCheckTarget = exports.qbx_core:GetPlayerByCitizenId(citizenid)
    if onlineCheckTarget and onlineCheckTarget.PlayerData and onlineCheckTarget.PlayerData.source then
        NotifyPlayer(granterSrc, locale('certifications.target_online_use_certify_command', onlineCheckTarget.PlayerData.source), 'error')
        return false, 'target_online_use_online_action'
    end

    -- SAME lock table/key SHAPE as GrantCertification's own online path
    -- (see that function's own GrantInFlight doc comment) -- deliberately
    -- shared, not a second independent lock, so the two paths cannot both
    -- observe "no existing row" for the same (citizenid, job) at once.
    local lockKey = citizenid .. ':' .. jobName
    if GrantInFlight[lockKey] then
        NotifyPlayer(granterSrc, locale('certifications.target_already_certified_hint'), 'inform')
        return false, 'already_certified'
    end
    GrantInFlight[lockKey] = true

    local outcome
    local function doGrantInsert()
        local existingId = K9Store.Cert_GetActiveId(citizenid, jobName)
        if existingId then
            NotifyPlayer(granterSrc, locale('certifications.target_already_certified_hint'), 'inform')
            outcome = 'already_certified'
            return
        end

        local granterCitizenid = ResolveGranterCitizenId(granterSrc)
        if not granterCitizenid then
            outcome = 'invalid_granter'
            return
        end

        local expiryDays = ResolveConfiguredExpiryDays()
        local insertOk, insertResultOrErr = pcall(K9Store.Cert_Insert, citizenid, jobName, granterCitizenid, expiryDays)

        if not insertOk then
            if IsDuplicateKeyError(insertResultOrErr) then
                RefreshCertificationCache(citizenid, jobName)
                NotifyPlayer(granterSrc, locale('certifications.target_already_certified_hint'), 'inform')
                outcome = 'already_certified'
                return
            end
            print(('[qbx_k9unit] GrantCertificationOffline INSERT failed for %s/%s: %s'):format(citizenid, jobName, tostring(insertResultOrErr)))
            NotifyPlayer(granterSrc, locale('certifications.grant_error'), 'error')
            outcome = 'db_error'
            return
        end

        RefreshCertificationCache(citizenid, jobName)
        ExpiryWarned[citizenid] = nil
        ExpiryLapsedNotified[citizenid] = nil

        FireOutboundEvent('qbx_k9unit:events:certificationGranted', citizenid, jobName, granterCitizenid)

        -- HANDLER XP -- same 'handlerCertifyK9' award, same
        -- CertifyXpMintCooldown per-(granter, target) mint throttle, as
        -- GrantCertification's own identical call above (see that call
        -- site's own doc comment, and CertifyXpMintCooldown's own
        -- declaration comment near CERTIFY_ACTION_COOLDOWN_MS, for the full
        -- writeup): this is a second door to the exact same "a NEW
        -- certification was just granted" event, and a handler who happens
        -- to grant through /k9certifyoffline instead of /k9certify must be
        -- throttled identically, not treated as a separate, unthrottled
        -- mint path. IsCertifyActionOnCooldown alone (this function's own
        -- per-granter action cooldown) never covered this -- same
        -- FALSIFIED CLAIM this pass corrects at GrantCertification's call
        -- site, not repeated here.
        -- FARM FIX (this pass) -- same TryConsumeCertifyHandlerXpMint gate as
        -- GrantCertification's own identical call above (see that call
        -- site's own comment, and TryConsumeCertifyHandlerXpMint's own
        -- declaration comment, for the full writeup): this offline door
        -- must be throttled identically, not treated as a separate,
        -- unthrottled distinct-target mint path -- especially since this is
        -- the ONE path that accepts a citizenid with no existence check at
        -- all (see this fix's own header, item 1).
        if type(AwardHandlerXP) == 'function'
            and TryConsumeCertifyHandlerXpMint(granterCitizenid, citizenid) then
            AwardHandlerXP(granterCitizenid, 'handlerCertifyK9')
        end

        -- Reconciles the read-only HUD mirror (and gives the target their
        -- own success notice) if they reconnected in the narrow TOCTOU
        -- window between the online-check guard above and this INSERT
        -- committing -- same reconciliation shape RevokeCertificationOffline's
        -- own `nowOnlinePlayer` check uses for the identical window.
        local nowOnlinePlayer = exports.qbx_core:GetPlayerByCitizenId(citizenid)
        if nowOnlinePlayer and nowOnlinePlayer.PlayerData and nowOnlinePlayer.PlayerData.source then
            nowOnlinePlayer.Functions.SetMetaData('k9certified', true)
            NotifyPlayer(nowOnlinePlayer.PlayerData.source, locale('certifications.grant_success_target'), 'success')
        end

        -- SECURITY/CONSISTENCY FIX (coder-security, this pass) -- same gap,
        -- same fix, as GrantCertification's own identical call above (see
        -- that call site's own doc comment for the full writeup): an
        -- offline /k9certifyoffline grant must apply the automatic model
        -- swap exactly like the online path does, including for a target
        -- who is still offline right now (ApplyK9AppearanceOnGrant/
        -- SendSwapRequest already handle that case -- persisting the
        -- assignment and applying it for real the first time PlayerLoaded
        -- fires for them, per server/appearance.lua's own header).
        ApplyChosenK9Look(citizenid, granterCitizenid, k9Model)

        NotifyPlayer(granterSrc, locale(k9Model and 'certifications.grant_success_granter_k9' or 'certifications.grant_success_granter'), 'success')
        -- WORKFLOW CLARITY (this pass, item 1) -- see GrantCertification's
        -- own identical call for the full writeup; computed from the same
        -- just-refreshed real state, only reached via the offline path here.
        SendGrantSuccessNextSteps(granterSrc, citizenid, jobName)
        outcome = 'ok'
    end

    local grantOk, grantErr = pcall(doGrantInsert)
    GrantInFlight[lockKey] = nil
    if not grantOk then
        print(('[qbx_k9unit] GrantCertificationOffline unexpected error for %s/%s: %s'):format(citizenid, jobName, tostring(grantErr)))
        NotifyPlayer(granterSrc, locale('certifications.grant_error'), 'error')
        return false, 'db_error'
    end

    return outcome == 'ok', outcome
end

--- ======================================================================
--- TABLET CERTIFY -- THE OFFLINE-GRANT ASYMMETRY, CLOSED (this pass,
--- coordinator-directed follow-up). RevokeCertificationOffline above
--- closes the identical gap for REVOKE (a genuinely offline target,
--- reached by citizenid); GrantCertificationForTablet used to be the one
--- remaining side of that asymmetry -- see git history/this pass's own
--- report for the ORIGINAL "DECISION: no offline grant path exists"
--- reasoning this block used to state, kept only in spirit below because
--- it is now STALE against the actual shipped default and would otherwise
--- mislead the next reader.
---
--- THE STALE PREMISE: the original reasoning was that §4.2 item 5's model check
--- (`IsConfiguredK9Model(GetEntityModel(GetPlayerPed(targetServerId)))`)
--- reads a LIVE ped's model with no persisted substitute for an offline
--- target, so an "offline grant" would have to skip a real check the
--- online path enforces -- a materially weaker feature, not a smaller one.
--- That was true when it was written, but GrantCertification's own §4.2 item 5
--- comment (above) was updated in the K9 role/model decoupling pass to
--- gate the model check ENTIRELY behind `Config.K9Appearance.requireK9ModelForRole`
--- -- which DEFAULTS TO FALSE (config.lua's own words: "a CONVENIENCE
--- gate, never a security one"). On the shipped default, the ONLINE path
--- ALREADY does not check the model either -- so refusing every offline
--- grant unconditionally was refusing a capability for a reason that, for
--- most installs, does not actually apply to the online path it was being
--- compared against.
---
--- THE ACTUAL DECISION NOW, MADE EXPLICIT (not silently building a
--- pending-until-login grant, and not silently granting without the check
--- an operator asked for -- both were considered and rejected, see below):
---   - `Config.K9Appearance.requireK9ModelForRole ~= true` (the shipped
---     default): GrantCertificationOffline below proceeds. This is NOT a
---     weaker version of the online path in this configuration -- neither
---     path checks the model at all when this flag is off, so there is
---     nothing left for an offline grant to skip that an online one
---     would otherwise catch.
---   - `Config.K9Appearance.requireK9ModelForRole == true`: an operator
---     has explicitly opted into "the model IS the enforcement" for this
---     install. GrantCertificationOffline REFUSES outright
---     ('model_check_requires_online') rather than either (a) silently
---     granting anyway -- the online path must never be weakened to make
---     the offline one easier, and building an offline exception to a
---     check an operator deliberately turned on would be exactly that --
---     or (b) a new grant-now-verify-on-next-login mechanism, which would
---     need its own pending-state schema/reconciliation logic for a
---     narrow case (this flag is off by default) this pass was not asked
---     to build. The refusal itself IS the "made visible to the operator,
---     not silent" requirement: a clear, distinguishable outcome code the
---     tablet/command surfaces, pointing at the proximity-and-model-
---     checked `/k9certify [server id]` instead of a certification that
---     quietly skipped a check the operator turned on for a reason.
---
--- `GrantCertificationForTablet` below resolves `citizenid` to a
--- currently-connected server id first and, if that succeeds, delegates to
--- GrantCertification UNCHANGED -- the exact same eligibility, cooldown,
--- self-cert, proximity, model-check, INSERT, cache-refresh, notification
--- and outbound-event sequence a live '/k9certify [server id]' would run,
--- one code path, no duplicated authority, ONLINE PATH ENTIRELY UNTOUCHED
--- BY THIS CHANGE. Only when the target is NOT currently connected does it
--- fall through to GrantCertificationOffline.
--- ======================================================================

--- @param granterSrc number
--- @param citizenid string
--- @param departmentKey string -- validated against Config.Departments as an
--- input-sanity/UX check only; NOT used to override the target's actual
--- live job -- GrantCertification (per its own §4.2 item 3 comment) always
--- certifies into whatever department the target's LIVE, server-read job
--- actually is, exactly as a live '/k9certify [server id]' attempt would.
--- A live job that does not match `departmentKey` is reported as
--- 'department_mismatch' rather than silently certifying into the
--- mismatched real department -- a stale tablet view (the target changed
--- department since the operator's roster/summary was last fetched) must
--- surface as an error the UI can react to, never a silent substitution of
--- what the operator actually clicked.
--- @return boolean ok
--- @param k9Model string? -- nil = handler; a Config.Peds model = certify as a K9 of that breed
--- @return string outcome -- every GrantCertification/GrantCertificationOffline outcome, plus 'invalid_target' (shape) | 'invalid_department' | 'department_mismatch'
local function GrantCertificationForTablet(granterSrc, citizenid, departmentKey, k9Model)
    if type(citizenid) ~= 'string' or citizenid == '' or type(departmentKey) ~= 'string' or departmentKey == '' then
        return false, 'invalid_target'
    end
    if not Config.Departments[departmentKey] then
        return false, 'invalid_department'
    end

    local onlineTarget = exports.qbx_core:GetPlayerByCitizenId(citizenid)
    local onlineTargetSrc = onlineTarget and onlineTarget.PlayerData and onlineTarget.PlayerData.source
    local ok, outcome
    if onlineTargetSrc then
        local liveJob = onlineTarget.PlayerData.job
        if not liveJob or liveJob.name ~= departmentKey then
            return false, 'department_mismatch'
        end
        ok, outcome = GrantCertification(granterSrc, onlineTargetSrc, k9Model)
    else
        ok, outcome = GrantCertificationOffline(granterSrc, citizenid, departmentKey, k9Model)
    end

    -- The roster follows the certify choice: a breed puts them on the K9
    -- roster, Handler on the Handler roster -- one press, not a second
    -- "Hire as K9 / Handler" step for something the chief just chose.
    -- server/roster.lua's RosterAssignPersonnelRole is the hook its own
    -- header set aside for exactly this; it refuses harmlessly (e.g. an
    -- offline target whose job cannot be confirmed) and never undoes the
    -- certification.
    if ok and type(RosterAssignPersonnelRole) == 'function' then
        local granter = exports.qbx_core:GetPlayer(granterSrc)
        local granterCid = granter and granter.PlayerData and granter.PlayerData.citizenid or 'unknown'
        pcall(RosterAssignPersonnelRole, citizenid, departmentKey, k9Model and 'k9' or 'handler', granterCid)
    end
    return ok, outcome
end

--- DEVELOPER_REFERENCE.md §4.2/§4.3 revoke flow (manual). Called by both event 3 and
--- command 7. Must work even when the target is offline (§4.3). Does NOT
--- run the model check (§4.2 item 5 applies to grant only).
--- CERTIFICATION DEPTH (this pass, Part A §2): `reason` is a NEW, OPTIONAL
--- third argument — nil/omitted (every pre-existing caller) behaves
--- exactly as before, recording a NULL `revoke_reason`. See this file's
--- header "REVOKE REASON" for the fixed vocabulary and why a mismatch is
--- rejected outright rather than silently stored as free text.
--- RETURN VALUE, ADDED THIS PASS (purely additive -- every pre-existing
--- caller (RegisterNetEvent/RegisterCommand handlers near the bottom of
--- this file) discards both return values today, exactly as it discarded
--- the previous bare `return`, so this changes NO observable behavior for
--- either of them). Added so the K9 Command Tablet's own
--- RevokeCertificationForTablet (below) can report a real, specific
--- outcome back to the caller instead of only a fire-and-forget toast --
--- the SAME retrofit GrantCertification/SetCertificationTier/
--- RenewCertification already received.
--- @param granterSrc number
--- @param targetServerId number
--- @param reason string? -- 'retired'|'reassigned'|'disciplinary'|'performance'|'other', or nil
--- @return boolean ok
--- @return string outcome -- 'invalid_target' | 'not_eligible' | 'on_cooldown' | 'invalid_revoke_reason' | 'self_certification_disabled' | 'target_offline' | 'target_too_far' | 'target_no_department_cert' | 'invalid_granter' | 'db_error' | 'target_not_actively_certified' | 'ok'
local function RevokeCertification(granterSrc, targetServerId, reason)
    if type(targetServerId) ~= 'number' then
        NotifyPlayer(granterSrc, locale('certifications.invalid_target_id'), 'error')
        return false, 'invalid_target'
    end

    if not IsEligibleCertifier(granterSrc) then
        NotifyPlayer(granterSrc, locale('certifications.not_authorized_to_revoke_hint'), 'error')
        return false, 'not_eligible'
    end

    if IsCertifyActionOnCooldown(granterSrc) then
        return false, 'on_cooldown' -- silent no-op: rate-limited, not an error worth notifying about (matches bark/leash-request convention)
    end

    if reason ~= nil and not VALID_REVOKE_REASONS[reason] then
        NotifyPlayer(granterSrc, locale('certifications.invalid_revoke_reason'), 'error')
        return false, 'invalid_revoke_reason'
    end

    local isSelfCert = granterSrc == targetServerId
    if isSelfCert and not Config.AllowSelfCertification then
        NotifyPlayer(granterSrc, locale('certifications.self_certification_disabled_hint'), 'error')
        return false, 'self_certification_disabled'
    end

    local targetPlayer = exports.qbx_core:GetPlayer(targetServerId)
    local targetCitizenid, targetJobName, targetIsOnline

    if targetPlayer and targetPlayer.PlayerData then
        targetIsOnline = true
        targetCitizenid = targetPlayer.PlayerData.citizenid
        targetJobName = targetPlayer.PlayerData.job and targetPlayer.PlayerData.job.name

        -- Online target: same proximity rule as grant (§4.2 item 4), skipped
        -- only for self-cert (nothing to measure distance to).
        if not isSelfCert then
            local granterPed = GetPlayerPed(granterSrc)
            local targetPed = GetPlayerPed(targetServerId)
            local dist = #(GetEntityCoords(granterPed) - GetEntityCoords(targetPed))
            if dist > Config.CertifyProximityMeters then
                NotifyPlayer(granterSrc, locale('certifications.target_too_far_to_revoke_distance', tostring(Config.CertifyProximityMeters)), 'error')
                return false, 'target_too_far'
            end
        end
    else
        -- CONFIRMED READING: a disconnected player has no live server id /
        -- ped at all — GetPlayer(source) only ever resolves a CURRENTLY
        -- CONNECTED player, and FiveM invalidates/recycles numeric source
        -- ids on disconnect. §4.2 point 4's proximity check is inherently
        -- a comparison of two LIVE ped coordinates; with no live target
        -- ped to read a position from, that check cannot apply and is
        -- skipped by necessity for a genuinely offline target.
        --
        -- This function's numeric targetServerId contract still can't
        -- translate a stale/disconnected id back into a citizenid + job,
        -- so it cannot itself serve a genuinely offline target — DEVELOPER_REFERENCE.md
        -- §4.3 requires manual revoke to work offline regardless (it's the
        -- explicit rationale for a DB table over metadata in the first
        -- place), so that gap is closed separately by
        -- RevokeCertificationOffline / the `/k9decertifyoffline [citizenid]
        -- [job]` command below, which takes a citizenid directly instead of
        -- a server id for exactly this reason. This function simply
        -- reports the mismatch back to the granter so they know to use
        -- that command instead of assuming this one silently worked.
        NotifyPlayer(granterSrc, locale('certifications.target_offline_use_decertify_offline'), 'error')
        return false, 'target_offline'
    end

    if not targetJobName or not Config.Departments[targetJobName] then
        NotifyPlayer(granterSrc, locale('certifications.target_no_department_cert'), 'error')
        return false, 'target_no_department_cert'
    end

    local granterCitizenid = ResolveGranterCitizenId(granterSrc)
    if not granterCitizenid then return false, 'invalid_granter' end

    -- No LIMIT needed — uq_one_active_cert_per_job guarantees at most one
    -- row matches (DEVELOPER_REFERENCE.md §4.3).
    --
    -- Wrapped in pcall (this file's own RefreshCertificationCache/
    -- GrantCertification precedent): a real DB error (bad connection,
    -- deadlock, schema drift) otherwise raises an uncaught script error
    -- straight out of this event/command handler instead of degrading —
    -- see IsCertRowConfirmedActive's own doc comment for why the failure
    -- branch below reconciles against a fresh, independent read rather
    -- than just assuming the UPDATE failed outright. A SQL transaction is
    -- deliberately NOT used here either: this is the only write in this
    -- function, and a single UPDATE is already atomic at the
    -- storage-engine level — the only real ambiguity a thrown error can
    -- leave behind is whether THIS callback ever saw the server's own
    -- commit acknowledgment, which a transaction's own COMMIT step would
    -- share identically.
    -- CERTIFICATION DEPTH (this pass, Part A §2): `revoke_reason` added to
    -- the SET clause — this SHIFTS the WHERE-clause params from
    -- positions [2]/[3] to [3]/[4] (SET-clause placeholders bind before
    -- WHERE-clause ones, left-to-right in the SQL text). Every existing
    -- test asserting on `updateParams[1..3]` for THIS call site was
    -- updated to match (tests/certifications_spec.lua) — a deliberate,
    -- reviewed shape change, not an accidental break.
    local updateOk, affectedRowsOrErr = pcall(K9Store.Cert_RevokeActive, targetCitizenid, targetJobName, granterCitizenid, reason)

    if not updateOk then
        print(('[qbx_k9unit] RevokeCertification UPDATE failed for %s/%s: %s -- reconciling before reporting an outcome'):format(targetCitizenid, targetJobName, tostring(affectedRowsOrErr)))

        local stillActive = IsCertRowConfirmedActive(targetCitizenid, targetJobName)
        if stillActive ~= false then
            -- Either confirmed still active (the UPDATE genuinely never
            -- committed — an honest failure, the target keeps their
            -- current, correct certification) or unreadable (nil, true
            -- outcome unknown) — in BOTH cases, never claim a revoke
            -- succeeded that this code cannot confirm, and never run the
            -- side effects below (leash/partnership teardown, HUD
            -- metadata, the target-facing notice) against a guess.
            NotifyPlayer(granterSrc, locale('certifications.revoke_error'), 'error')
            return false, 'db_error'
        end

        -- Confirmed inactive despite the client-side error (e.g. a
        -- success acknowledgment lost after a real commit) — fall through
        -- to the normal success path below against this now-confirmed
        -- truth; RefreshCertificationCache below will pick up the correct
        -- state.
    elseif not affectedRowsOrErr or affectedRowsOrErr == 0 then
        NotifyPlayer(granterSrc, locale('certifications.target_not_actively_certified'), 'inform')
        return false, 'target_not_actively_certified'
    end

    -- Outbound integration event (server/exports.lua's EVENT CONTRACT §2) —
    -- fired immediately once `affectedRows` confirms a real row actually
    -- flipped (never optimistically before this check), same "not gated on
    -- a feature flag" reasoning as the grant event above.
    FireOutboundEvent('qbx_k9unit:events:certificationRevoked', targetCitizenid, targetJobName, 'manual')

    if targetIsOnline then
        RefreshCertificationCache(targetCitizenid, targetJobName)
        -- HUD display mirror only (DEVELOPER_REFERENCE.md §4.3) — never read for authorization.
        targetPlayer.Functions.SetMetaData('k9certified', false)

        -- WORKFLOW CLARITY (this pass, item 4-adjacent -- "the person...
        -- should be able to understand it afterwards" applies just as much
        -- to a deliberate manual revoke as to an automatic job-change one):
        -- tell the revoked handler WHY, when the granter actually gave a
        -- reason, rather than leaving them to guess or ask around. `reason`
        -- is already validated against VALID_REVOKE_REASONS above (or nil)
        -- before this point is ever reached, so this never surfaces
        -- arbitrary free text.
        if reason then
            NotifyPlayer(targetServerId, locale('certifications.revoked_notice_online_with_reason', reason), 'error')
        else
            NotifyPlayer(targetServerId, locale('certifications.revoked_notice_online'), 'error')
        end

        -- QA finding fix, CONSOLIDATED (this pass) onto EndK9AccessForCitizenId
        -- above: an active leash pairing, an in-progress bite-hold/
        -- takedown/drag, and any partnership must not outlive the K9-role
        -- party's certification (DEVELOPER_REFERENCE.md §1/§4.4
        -- "immediately") — see that function's own doc comment for the
        -- full three-call writeup. `targetServerId` is already a live,
        -- currently-connected server id here (we're inside the
        -- `targetIsOnline` branch), so pass it as `knownSrc` rather than
        -- having the helper re-resolve it by citizenid.
        EndK9AccessForCitizenId(targetCitizenid, 'certification_revoked', targetServerId)
    end

    -- CERTIFICATION DEPTH (this pass, Part B §11): a specialization cannot
    -- outlive the base certification it requires — see this file's header
    -- "SPECIALIZATIONS". Called unconditionally of targetIsOnline (a
    -- specialization row is DB-backed, not in-memory-only, so this must
    -- run for an online OR offline target identically) — best-effort:
    -- logged on failure, never allowed to turn an already-confirmed base
    -- revoke back into a reported failure.
    RevokeAllSpecializationsForCitizenJob(targetCitizenid, targetJobName, granterCitizenid, 'certification_revoked')

    -- SECURITY/CONSISTENCY FIX (coder-security, this pass -- "prove role
    -- and model are genuinely separate, everywhere" audit): this file's
    -- own K9 credential (a certification) is one of TWO routes
    -- server/appearance.lua's MaybeRevertK9Appearance reconciles against
    -- before reverting an applied K9 ped (the other being a
    -- server/permissions.lua 'k9.access' grant) -- but until this pass
    -- NOTHING in this file ever called it, on ANY of its five
    -- "K9-role access just, provably, ended" sites (see
    -- EndK9AccessForCitizenId's own doc comment for the enumerated five).
    -- A citizenid certified through the applyPedModelOnCertify default (see
    -- this file's own newly-added ApplyK9AppearanceOnGrant call in
    -- GrantCertification above) who then had ONLY that certification --
    -- never a separate 'k9.access' grant -- revoked would keep the K9 ped
    -- model forever, stranded exactly the way this pass's brief warns
    -- against, with no code path left to ever revert it. Called
    -- UNCONDITIONALLY of targetIsOnline (mirrors
    -- RevokeAllSpecializationsForCitizenJob immediately above) --
    -- MaybeRevertK9Appearance is itself offline-capable (it either sends a
    -- live swap request or persists the reverted row for the target's next
    -- PlayerLoaded, per server/appearance.lua's own header) and already
    -- fails safe (no-op) when the citizenid still independently qualifies
    -- via a separate active cert/permission or holds no appearance
    -- assignment at all. Guarded by `type(...) == 'function'` -- genuine
    -- soft dependency, not a load-order assumption (server/appearance.lua
    -- loads before this file per its own header, but this file must not
    -- hard-require it to exist).
    if type(MaybeRevertK9Appearance) == 'function' then
        MaybeRevertK9Appearance(targetCitizenid)
    end

    NotifyPlayer(granterSrc, locale('certifications.revoke_success'), 'success')
    return true, 'ok'
end

--- DEVELOPER_REFERENCE.md §4.3 offline-capable revoke flow (manual). Called only by the
--- '/k9decertifyoffline [citizenid] [job]' command — see that command's
--- registration below and this file's header (item 7b) for why there is
--- no client-triggerable event equivalent (a disconnected target has no
--- client to trigger anything from). Closes the gap RevokeCertification
--- above cannot: that function's numeric targetServerId contract can only
--- ever resolve a currently-connected player, but DEVELOPER_REFERENCE.md §4.3 requires
--- manual revoke to work on a genuinely offline target (this is the
--- explicit stated rationale for choosing a dedicated DB table as the
--- source of truth over qbx_core metadata in the first place — an
--- admin/chief must be able to pull a cert from someone who isn't logged
--- in right now). Same eligibility rule as the online path. Deliberately
--- has NO proximity check (impossible against a disconnected target — the
--- entire point of this path) and NO model check (revoke never runs the
--- model check regardless of online/offline status, per §4.2 item 5 being
--- grant-only).
--- CERTIFICATION DEPTH (this pass, Part A §2): `reason` is a NEW, OPTIONAL
--- fourth argument — see RevokeCertification's own identical doc comment.
--- RETURN VALUE, ADDED THIS PASS (purely additive -- see RevokeCertification's
--- own identical retrofit note above; this function's only pre-existing
--- caller, the '/k9decertifyoffline' command below, discards both values).
--- Added so the K9 Command Tablet's own RevokeCertificationForTablet
--- (below) can report a real, specific outcome back to the caller.
--- @param granterSrc number
--- @param citizenid string
--- @param job string
--- @param reason string? -- 'retired'|'reassigned'|'disciplinary'|'performance'|'other', or nil
--- @return boolean ok
--- @return string outcome -- 'not_eligible' | 'on_cooldown' | 'invalid_target' | 'invalid_revoke_reason' | 'invalid_department' | 'invalid_granter' | 'target_online_use_online_action' | 'db_error' | 'target_not_actively_certified' | 'ok'
local function RevokeCertificationOffline(granterSrc, citizenid, job, reason)
    if not IsEligibleCertifier(granterSrc) then
        NotifyPlayer(granterSrc, locale('certifications.not_authorized_to_revoke_hint'), 'error')
        return false, 'not_eligible'
    end

    if IsCertifyActionOnCooldown(granterSrc) then
        return false, 'on_cooldown' -- silent no-op: rate-limited, not an error worth notifying about (matches bark/leash-request convention)
    end

    if type(citizenid) ~= 'string' or citizenid == '' or type(job) ~= 'string' or job == '' then
        NotifyPlayer(granterSrc, locale('certifications.usage_decertify'), 'error')
        return false, 'invalid_target'
    end

    if reason ~= nil and not VALID_REVOKE_REASONS[reason] then
        NotifyPlayer(granterSrc, locale('certifications.invalid_revoke_reason'), 'error')
        return false, 'invalid_revoke_reason'
    end

    -- Reject a typo'd/unconfigured job outright rather than silently
    -- no-opping against a job name that could never have an active row.
    if not Config.Departments[job] then
        NotifyPlayer(granterSrc, locale('certifications.invalid_department_hint', job, ConfiguredDepartmentsList()), 'error')
        return false, 'invalid_department'
    end

    local granterCitizenid = ResolveGranterCitizenId(granterSrc)
    if not granterCitizenid then return false, 'invalid_granter' end

    -- SECURITY FIX (coder-security review): this command exists ONLY to
    -- reach a genuinely disconnected target (see this function's header
    -- and DEVELOPER_REFERENCE.md §4.3) — that's the entire justification for skipping
    -- §4.2 condition 4's proximity check. But nothing previously verified
    -- the target was actually offline before running the update: an
    -- eligible certifier could call `/k9decertifyoffline [citizenid] [job]`
    -- against a target who is CURRENTLY ONLINE and standing anywhere on
    -- the map (or the other side of it), silently bypassing
    -- Config.CertifyProximityMeters — the exact "remote/cross-map
    -- certifying via a spoofed command" scenario §4.2 condition 4 is
    -- meant to prevent for "both the ox_target flow and the slash-command
    -- flow." Close that gap: if the citizenid resolves to a currently
    -- connected player, refuse this path and point the caller at
    -- `/k9decertify [server id]`, which enforces the real proximity check.
    -- CONFIDENCE NOTE: exports.qbx_core:GetPlayerByCitizenId(citizenid) is
    -- used here per established QBCore/Qbox convention (the standard
    -- citizenid-keyed counterpart to GetPlayer); not independently
    -- verified against a live qbx_core install in this sandbox — same
    -- caveat as this file's other qbx_core-export notes.
    local onlineCheckTarget = exports.qbx_core:GetPlayerByCitizenId(citizenid)
    if onlineCheckTarget and onlineCheckTarget.PlayerData and onlineCheckTarget.PlayerData.source then
        NotifyPlayer(granterSrc, locale('certifications.target_online_use_decertify_command', onlineCheckTarget.PlayerData.source), 'error')
        return false, 'target_online_use_online_action'
    end

    -- No LIMIT needed — uq_one_active_cert_per_job guarantees at most one
    -- row matches (DEVELOPER_REFERENCE.md §4.3). Same UPDATE pattern as the online path —
    -- including the same pcall + reconcile-on-throw discipline; see
    -- RevokeCertification's own doc comment above for the full reasoning
    -- (a thrown DB error must degrade this offline-capable command, not
    -- raise an uncaught script error, and a SQL transaction would not
    -- resolve the one genuine ambiguity a thrown error can leave behind
    -- here either).
    -- CERTIFICATION DEPTH (this pass, Part A §2): `revoke_reason` added,
    -- same positional shift as RevokeCertification's own UPDATE above —
    -- this call site's own test assertion was updated to match.
    local updateOk, affectedRowsOrErr = pcall(K9Store.Cert_RevokeActive, citizenid, job, granterCitizenid, reason)

    if not updateOk then
        print(('[qbx_k9unit] RevokeCertificationOffline UPDATE failed for %s/%s: %s -- reconciling before reporting an outcome'):format(citizenid, job, tostring(affectedRowsOrErr)))

        local stillActive = IsCertRowConfirmedActive(citizenid, job)
        if stillActive ~= false then
            -- Confirmed still active, or unreadable (true outcome
            -- unknown) — never claim a revoke succeeded that this code
            -- cannot confirm; see RevokeCertification's identical branch
            -- above for the full reasoning.
            NotifyPlayer(granterSrc, locale('certifications.revoke_error'), 'error')
            return false, 'db_error'
        end

        -- Confirmed inactive despite the client-side error — fall through
        -- to the normal success path below against this now-confirmed
        -- truth.
    elseif not affectedRowsOrErr or affectedRowsOrErr == 0 then
        -- Distinguish "no matching active cert" from success — a granter
        -- typo'ing a citizenid should not look identical to a real revoke.
        NotifyPlayer(granterSrc, locale('certifications.offline_target_not_certified'), 'inform')
        return false, 'target_not_actively_certified'
    end

    -- Outbound integration event (server/exports.lua's EVENT CONTRACT §2) —
    -- same "fire only once affectedRows confirms a real row flipped"
    -- discipline as RevokeCertification's online branch above; reason is
    -- 'manual_offline' to distinguish this path from that one.
    FireOutboundEvent('qbx_k9unit:events:certificationRevoked', citizenid, job, 'manual_offline')

    -- Regression-test fix: unlike RevokeCertification's online branch and
    -- the QBCore:Server:OnJobUpdate auto-revoke handler (both of which call
    -- RefreshCertificationCache immediately after their UPDATE), this path
    -- previously left a stale `active = true` in-memory cache entry behind
    -- for a citizenid who was online, disconnected, and then got
    -- offline-revoked — until their next PlayerLoaded fires and re-queries
    -- fresh. RefreshCertificationCache is a plain DB-query-and-cache-write
    -- function with no live-source requirement, so it's safe to call
    -- unconditionally here even for a genuinely offline citizenid: it will
    -- simply cache `active = false` for whenever they next connect, rather
    -- than leaving a drifted entry around. Matches DEVELOPER_REFERENCE.md §4.3's
    -- "invalidated/updated immediately on grant/revoke events".
    RefreshCertificationCache(citizenid, job)

    -- Regression-test fix: keep the read-only `k9certified` HUD mirror
    -- (DEVELOPER_REFERENCE.md §4.3 — never read for authorization, see GrantCertification's
    -- comment on the same field) from drifting stale. The online guard
    -- above already refused this whole path if the citizenid resolved to a
    -- connected player at the time it was checked, so this is normally a
    -- no-op; it only matters for the narrow TOCTOU window where the target
    -- reconnects between that guard and this UPDATE completing — same
    -- window EndK9AccessForCitizenId below is already written to cover.
    local nowOnlinePlayer = exports.qbx_core:GetPlayerByCitizenId(citizenid)
    if nowOnlinePlayer and nowOnlinePlayer.PlayerData and nowOnlinePlayer.PlayerData.source then
        nowOnlinePlayer.Functions.SetMetaData('k9certified', false)
    end

    -- QA finding fix, CONSOLIDATED (this pass) onto EndK9AccessForCitizenId
    -- above: tear down an active leash pairing, an in-progress bite-hold/
    -- takedown/drag, and any partnership for this citizenid, per
    -- DEVELOPER_REFERENCE.md §1/§4.4. In the overwhelmingly common case the
    -- leash/hold half is a genuine no-op — the online guard earlier in this
    -- function already refused this whole path if the citizenid resolved
    -- to a connected player at that point, and both are in-memory-only, so
    -- a genuinely offline target cannot have either to begin with. Still
    -- called unconditionally (rather than assumed unreachable) to close
    -- the narrow TOCTOU window where the target reconnects between that
    -- guard and this UPDATE completing — see EndK9AccessForCitizenId's own
    -- doc comment for the full writeup. Passes `nowOnlinePlayer`'s
    -- already-resolved source (reused from the `k9certified` mirror write
    -- immediately above, no synchronous state change possible in between)
    -- as `knownSrc`, exactly like this function's own prior separate
    -- lookups for leash-detach and hold-end used to do independently — a
    -- behavior-preserving simplification to one lookup, not a change in
    -- what gets resolved. ForceBreakPartnershipForCitizenId, unlike the
    -- leash/hold half, runs even when `knownSrc` resolves to nothing: a K9
    -- partnership is DB-backed and DOES persist across a disconnect
    -- (server/partnership.lua's own "OFFLINE-CAPABLE BY DESIGN" header
    -- section) — this is in fact THE call site that design decision exists
    -- for, since a genuinely offline K9-role citizenid revoked while
    -- off-shift must still have any real, active partnership row torn
    -- down, or it would otherwise stand indefinitely.
    EndK9AccessForCitizenId(citizenid, 'certification_revoked',
        nowOnlinePlayer and nowOnlinePlayer.PlayerData and nowOnlinePlayer.PlayerData.source)

    -- CERTIFICATION DEPTH (this pass, Part B §11): same cascade as
    -- RevokeCertification's online branch — DB-authoritative, so this
    -- works correctly for this genuinely-offline citizenid (see
    -- RevokeAllSpecializationsForCitizenJob's own doc comment for why it
    -- deliberately does not rely on the in-memory cache here).
    RevokeAllSpecializationsForCitizenJob(citizenid, job, granterCitizenid, 'certification_revoked')

    -- SECURITY/CONSISTENCY FIX (coder-security, this pass) -- same gap,
    -- same fix, as RevokeCertification's own identical call above (see
    -- that call site's own doc comment for the full writeup): an offline
    -- /k9decertifyoffline revoke must also reconcile/revert an applied K9
    -- appearance, or a citizenid decertified entirely while offline (their
    -- only route to the role) keeps the K9 ped model forever with no other
    -- path left to ever clear it.
    if type(MaybeRevertK9Appearance) == 'function' then
        MaybeRevertK9Appearance(citizenid)
    end

    NotifyPlayer(granterSrc, locale('certifications.revoke_success'), 'success')
    return true, 'ok'
end

-- ======================================================================
-- PUBLISHED TO THE LATER FILES IN THIS SPLIT (see this file's own
-- header). Transport only -- not a public API.
-- ======================================================================
K9Cert.CertificationCheckUnresolved = CertificationCheckUnresolved
K9Cert.Certifications = Certifications
K9Cert.ConfiguredDepartmentsList = ConfiguredDepartmentsList
K9Cert.ConfiguredSpecializationsList = ConfiguredSpecializationsList
K9Cert.DaysRemainingFromUnix = DaysRemainingFromUnix
K9Cert.EndK9AccessForCitizenId = EndK9AccessForCitizenId
K9Cert.ExpiryLapsedNotified = ExpiryLapsedNotified
K9Cert.ExpiryWarned = ExpiryWarned
K9Cert.GetTierOrdinalOrLegacyFallback = GetTierOrdinalOrLegacyFallback
K9Cert.GrantCertification = GrantCertification
K9Cert.GrantCertificationForTablet = GrantCertificationForTablet
K9Cert.GrantCertificationOffline = GrantCertificationOffline
K9Cert.GrantInFlight = GrantInFlight
K9Cert.IsCertRowConfirmedActive = IsCertRowConfirmedActive
K9Cert.IsCertifyActionOnCooldown = IsCertifyActionOnCooldown
K9Cert.IsDuplicateKeyError = IsDuplicateKeyError
K9Cert.IsEligibleCertifier = IsEligibleCertifier
K9Cert.IsKnownTierKeyOrLegacyFallback = IsKnownTierKeyOrLegacyFallback
K9Cert.NowUnix = NowUnix
K9Cert.RefreshSpecializationCache = RefreshSpecializationCache
K9Cert.ResolveConfiguredExpiryDays = ResolveConfiguredExpiryDays
K9Cert.ResolveConfiguredExpiryWarningDays = ResolveConfiguredExpiryWarningDays
K9Cert.ResolveGranterCitizenId = ResolveGranterCitizenId
K9Cert.RevokeAllSpecializationsForCitizenJob = RevokeAllSpecializationsForCitizenJob
K9Cert.RevokeCertification = RevokeCertification
K9Cert.RevokeCertificationOffline = RevokeCertificationOffline
K9Cert.Specializations = Specializations

