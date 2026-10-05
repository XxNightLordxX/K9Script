--[[
    john-k9/server/exports.lua

    PUBLIC API SURFACE. See DEVELOPER_REFERENCE.md Part B §1 ("Give this
    resource a real export/event API — prerequisite, not optional") for why
    this file exists: before it was added, fxmanifest.lua declared zero
    exports and README.md said so explicitly ("integration by other
    resources is currently limited to reading the metadata.k9certified
    display flag... these are internal contracts, not a stable public
    API"). Every export below closes that gap for READ access. See "NOT IN
    THIS FILE" near the bottom for what is deliberately still missing and
    why — that section is as load-bearing as the exports themselves for
    anyone reviewing this contract.

    ======================================================================
    DESIGN PRINCIPLES — read before adding a new export here:
    1. READ-ONLY. Every export below reads existing server-authoritative
       state; none of them grant, revoke, award, or otherwise mutate
       anything. See "NOT IN THIS FILE" for the mutations considered and
       explicitly rejected for v1.
    2. RE-DERIVE, NEVER TRUST. Every export re-derives its answer from the
       same server-authoritative source the internal code already uses
       (the certification cache via HasK9Access, the partnership cache via
       GetActivePartnerCitizenId/IsActivePartnerOf, the XP cache via
       GetXP/GetXPTier). A caller-supplied source/citizenid is only ever
       used as a LOOKUP KEY into that state, never as a claim about the
       result — an export is not a trusted caller, exactly like any other
       network-facing entry point in this resource.
    3. NO RAW INTERNAL TABLES. Every table-returning export copies before
       returning. This is not theoretical: server/progression.lua's own
       doc comment confirms its internal tier resolver "returns the SAME
       table object (by reference) for every xp value that falls in one
       tier's bracket" — that object IS Config.XPTiers[n], shared by every
       citizenid in that bracket. Handing that reference to an external
       resource would let a caller's `tier.speedMultiplier = 999` corrupt
       movement speed for every K9 in that tier, server-wide, for the rest
       of this resource's uptime. Copy first, always — see CopyTier
       below.
    4. THIS FILE WRAPS, IT DOES NOT REIMPLEMENT. Every export below is a
       thin wrapper around an existing resource-global function or a
       direct Config table read — no new business logic, no new SQL.
       Where a genuinely new read (e.g. search-log audit access) would
       require query logic that its owning file doesn't already expose
       globally, it is deliberately NOT added here — see "NOT IN THIS
       FILE". Writing that logic in this file instead of the file that
       owns the table would split ownership of that table across two
       files for no reason beyond this file's own convenience.
    5. FAIL CLOSED, NEVER THROW ACROSS THE RESOURCE BOUNDARY. Every export
       body validates its own argument types and pcall-wraps the call into
       the wrapped function — a bug on this resource's side must never
       propagate an uncaught error into a caller resource's own call
       stack, and a caller passing a malformed argument must never reach
       the wrapped function with it. Bad input returns the same safe
       default this resource already treats as "unknown state" everywhere
       else (false / 0 / nil) — matching server/certifications/'s own
       "fail closed" convention for an unreadable cert row.

    NOTE ON NAMING: several exports below are given the exact same name as
    the resource-global function they wrap (e.g. `exports('HasK9Access', ...)`
    wraps the global `HasK9Access`), for 1:1 traceability against the
    functions this contract cites. `exports(name, fn)` registers into
    FXServer's per-resource export table, NOT the Lua global namespace — it
    does not shadow, rename, or otherwise touch the actual global `HasK9Access`
    function, so a call to the bare identifier `HasK9Access(...)` inside one
    of this file's export bodies still reaches server/certifications/'s
    real implementation, not this file's own export of the same name. This
    mirrors an already-established convention in this codebase (client/
    main.lua's `HasK9Access()` and server/certifications/'s
    `HasK9Access(source)` already share a name across the client/server realm
    split — see .luacheckrc's own comment on that pair).
    ======================================================================

    VERSIONING: GetAPIVersion() is the intended feature-detection entry
    point. This surface starts at 1.0.0. Semver posture: an additive change
    (a new export, a new optional field on an existing return table) bumps
    MINOR; removing/renaming an export or narrowing an existing return shape
    bumps MAJOR and should be treated as a breaking change requiring a
    migration note, not a silent edit. A consumer should call
    GetAPIVersion() once and branch on `.major` rather than assume this
    surface never changes underneath it.

    ======================================================================
    Config.Features GATING — decided explicitly per export, not defaulted
    either way:
    - HasK9Access / IsConfiguredK9Model: NOT gated by any Config.Features
      flag. Neither wrapped function is itself gated by a feature flag
      internally — HasK9Access is the core access gate DEVELOPER_REFERENCE.md §4.1
      describes (independent of which specific K9 mechanics are toggled
      on), and IsConfiguredK9Model is roster truth, not a feature. An
      export diverging from its own wrapped function's real behavior would
      be a worse bug than not gating at all.
    - GetActivePartnerCitizenId / IsActivePartnerOf: NOT gated on
      Config.Features.HandlerPartnership. Mirrors the wrapped functions
      exactly — server/partnership.lua's own accessors read the in-memory
      cache unconditionally, with no internal feature check. If that flag
      is later flipped off on a live server, any partnership established
      while it was on remains real, queryable state until torn down some
      other way; gating the EXPORT but not the underlying cache would make
      this file lie about state relative to its own source of truth.
    - GetXP / GetXPTier: NOT gated on Config.Features.XPProgression, for
      the identical reason — server/progression.lua's own doc comment
      states its GetXPTier "does not gate internally, so it stays a plain,
      always-correct cache read regardless of caller," with the gating
      responsibility explicitly pushed to the CALLER. This file is exactly
      that caller, so it inherits that responsibility rather than
      resolving it silently on the operator's behalf. A consumer that
      wants to respect the operator's toggle should pair a GetXP/GetXPTier
      call with IsFeatureEnabled('XPProgression') (below) and decide for
      itself what "disabled" should mean for its own UI.
    - IsFeatureEnabled(featureKey): reads Config.Features directly, so by
      definition always reflects the operator's real, current toggle
      state — this is the one export whose entire purpose IS reading a
      feature flag, so there is nothing else for it to be gated by.
    ======================================================================

    EVENT CONTRACT — a `john-k9:events:<name>` namespace, distinct from
    the existing `john-k9:server:`/`john-k9:client:` namespaces
    (which README.md already documents as internal and "may change") —
    `john-k9:events:*` is the one meant to be a stable contract other
    resources can rely on. Every one fires via plain `TriggerEvent`
    (server-local — any other server-side resource can `AddEventHandler`
    on these directly; never `TriggerClientEvent`, these are not for this
    resource's own clients).

    Fired from server/certifications/, server/partnership.lua,
    server/progression.lua, server/search.lua and server/integrations.lua,
    each at the exact success points described below, through one shared
    resource-global `FireOutboundEvent` helper defined in server/events.lua
    (see that file's header) — this file only documents the contract and
    does not fire anything directly; firing
    happens at the owning files' own success points.

    Current full list (measured by grepping every `john-k9:events:`
    string literal across client/ and server/ and de-duplicating):

      certificationGranted      certificationRenewed
      certificationRevoked      certificationTierChanged
      k9Down                    partnershipEnded
      partnershipEstablished    searchCompleted
      specializationGranted     specializationRevoked
      xpTierReached

    This is a PUBLIC contract other resources are written against: do not
    state a count here unless you have just measured it, and do not simply
    re-affirm an inherited one — a stale count in a stable-contract header
    is worse than no count, because a consumer trusts it. If you add an
    event, add its name to the list above in the same edit — the list is
    the contract; a summary count of it is not.

    1. 'john-k9:events:certificationGranted'
       (citizenid: string, jobName: string, grantedByCitizenid: string)
       Fire from: server/certifications/'s GrantCertification, right
       after the `RefreshCertificationCache(targetCitizenid, jobName)` call
       that follows a successful INSERT — targetCitizenid/jobName/
       granterCitizenid are already in scope there.

    2. 'john-k9:events:certificationRevoked'
       (citizenid: string, jobName: string, reason: 'manual'|'manual_offline'|'job_changed')
       Fire from THREE existing success points in server/certifications/:
       RevokeCertification (right after `affectedRows` confirms a real row
       flipped; reason = 'manual'), RevokeCertificationOffline (its
       equivalent UPDATE success point; reason = 'manual_offline'), and the
       QBCore:Server:OnJobUpdate auto-revoke path (reason = 'job_changed').
       Same payload shape at all three — a small shared local helper in
       that file avoids duplicating the TriggerEvent call three times.

    3. 'john-k9:events:partnershipEstablished'
       (k9Citizenid: string, handlerCitizenid: string)
       Fire from: server/partnership.lua's respondPartnerUp handler,
       alongside the two existing
       `TriggerClientEvent('john-k9:client:partnershipEstablished', ...)`
       calls — k9Citizenid/officerCitizenid are already in scope there.

    4. 'john-k9:events:partnershipEnded'
       (k9Citizenid: string, handlerCitizenid: string, reason: string)
       Fire from: server/partnership.lua's DoBreakPartnership, right before
       its final `return true` — row.k9_citizenid/row.handler_citizenid/
       broadcastReason are already in scope there. This one function backs
       both the player-initiated breakPartnership event AND
       ForceBreakPartnershipForCitizenId (the automatic teardown on cert
       revoke), so wiring it here — not at either caller — covers both
       paths in one place.

    5. 'john-k9:events:searchCompleted'
       (searcherCitizenid: string, searcherJob: string,
        targetType: 'vehicle'|'person', result: 'found'|'clean'|'search_failed',
        totalWeight: number?, alertTier: string?)
       Fire from: server/search.lua's LogSearchAttempt, right after its
       `pcall(MySQL.insert, ...)` call — every field in this payload is
       already a parameter of that function, and all six call sites in
       that file already funnel through it, so wiring the event there (not
       at each call site) covers all of them at once and guarantees the
       event payload can never drift from what actually lands in the
       `k9_search_log` audit row.
       RECOMMENDED, NOT YET APPLIED (see server/integrations.lua's own
       header for the full writeup): extend this payload with the two
       target-identity fields (`plateOrNil`, `targetCitizenidOrNil`)
       already in scope at this exact call site — an MDT/evidence
       integration cannot attach a `found` result to a real case record
       without knowing WHAT was searched, only who searched it. Additive
       (MINOR), not yet applied here.

    6. 'john-k9:events:xpTierReached'
       (citizenid: string, newTier: table, oldTier: table — both COPIES,
        same shape as this file's own GetXPTier export below, never the
        raw Config.XPTiers reference)
       Fire from: server/progression.lua's AwardXP, at the existing
       `if newTier ~= oldTier then` branch, which already detects the exact
       crossing this event exists to announce — right alongside the
       existing `PushTierSnapshot(targetSrc, newTier)` call in that same
       branch.

    7. 'john-k9:events:k9Down' (DEVELOPER_REFERENCE.md Part A §7, "K9
       down / injured critically" dispatch integration hook)
       (source: number, citizenid: string, jobName: string, coords: vector3,
        health: number)
       Fire from: server/integrations.lua's own self-contained health-poll
       thread (PollK9Health), not from an existing success point in another
       file — see that file's own header for the full design (edge-triggered
       on a configurable Config.K9DownDispatch.healthThreshold, a minimum
       qualifying duration, and a per-source re-fire cooldown, mirroring
       server/wellbeing.lua's own PED_DEAD_HEALTH_THRESHOLD pattern) and for
       why this is a poll rather than a hook inside that file's existing
       TickWellbeing loop. The one payload in this whole contract that
       carries a location (`coords`), deliberately: unlike the other six
       events, a dispatch alert's entire purpose is a map pin.

    CORRECTED (integration-verification pass, 2026-08-26): the "Current full
    list" table above already named every event — it was measured by
    grepping every real call site, not guessed — but only #1–#7 above had a
    documented payload shape. The rest were real, already-firing events
    with no contract entry here at all, which is exactly the kind of gap a
    resource built against this file from the table alone would not have
    caught until it tried to read a field that was never documented.
    Filled in below, each verified directly against its own
    `FireOutboundEvent` call site(s), never guessed from the name:

    8. 'john-k9:events:certificationTierChanged'
       (citizenid: string, jobName: string, oldTier: string, newTier: string,
        granterCitizenid: string)
       oldTier/newTier are plain tier-KEY strings ('trainee'|'certified'|
       'senior', or any live operator-added key from server/certtiers.lua) —
       NOT table copies, unlike xpTierReached's newTier/oldTier (#6) above.
       Fire from TWO existing success points in server/certifications/:
       SetCertificationTier (online target) and SetCertificationTierOffline
       (offline target), each right after its own post-write
       RefreshCertificationCache confirms the tier that actually landed.
       SetCertificationTierForTablet wraps both and has no separate fire site
       of its own.

    9. 'john-k9:events:certificationRenewed'
       (citizenid: string, jobName: string, expiresAtUnix: number|nil,
        granterCitizenid: string)
       `expiresAtUnix` is read back from the post-write cache, never the
       requested value — `nil` only if that read-back itself could not be
       confirmed fresh (see the call site's own "freshlyVerified" gate).
       Fire from TWO existing success points in server/certifications/:
       RenewCertification (online target) and RenewCertificationOffline
       (offline target). RenewCertificationForTablet wraps both and has no
       separate fire site of its own.

    10. 'john-k9:events:specializationGranted'
        (citizenid: string, jobName: string, specializationKey: string,
         granterCitizenid: string)
        Fire from: server/certifications/'s GrantSpecialization, right
        after RefreshSpecializationCache following a confirmed INSERT.
        GrantSpecializationForTablet wraps it and has no separate fire site.

    11. 'john-k9:events:specializationRevoked'
        (citizenid: string, jobName: string, specializationKey: string,
         reason: 'manual'|'manual_offline'|'certification_revoked'|
         'department_changed'|'job_changed')
        Fire from THREE existing success points in server/certifications/:
        RevokeSpecialization (reason='manual'), RevokeSpecializationOffline
        (reason='manual_offline'), and RevokeAllSpecializationsForCitizenJob
        (reason passed through from its own caller — the cascade this
        function runs from a base-certification revoke or a job/department
        change, so it fires once per specialization key still active at that
        moment, not once per call). RevokeSpecializationForTablet wraps the
        first of these and has no separate fire site of its own.

    Every payload above uses ONLY values the owning file already computes
    for its own internal purposes (a DB column just written, an existing
    TriggerClientEvent's own arguments, or — for #7 — a live, server-resolved
    read taken at the moment of firing). Wiring #1 through #6 required no new
    logic beyond firing at an existing success point, matching
    DEVELOPER_REFERENCE.md Part B's own "Effort: small" assessment for that
    item; #7 is genuinely new detection logic, scoped to its own file rather
    than any existing one — see server/integrations.lua's own header. #8
    onward are, like #1–#6, all wired at a pre-existing success point in
    a file that already computed every field in their payload for its own
    purposes — none of them required new detection logic either.
    ======================================================================

    ======================================================================
    COVERAGE OF LATER-ADDED FEATURES — four features landed in this resource
    after this file was first written: PropAttachments (server/propattachment.lua,
    client/propattachment.lua), FetchMechanic (server/fetch.lua,
    client/fetch.lua), ProximityAudioFX (client/proximityaudio.lua only —
    no server-side file exists for it), and two more that don't map to a
    single feature file: partnership tenure (server/tenure.lua) and the
    admin/audit surface (server/admin.lua). Each was read in full and
    evaluated against this file's own DESIGN PRINCIPLES above (wrap an
    EXISTING resource-global read accessor, never invent one; never add
    SQL; never weaken the "no new mutations" stance). Result for THIS file
    (server/exports.lua): **zero new exports.** Every one of the four either
    exposes no resource-global function this file could wrap at all, or its
    only resource-global surface is a self-initiated mutation already
    excluded by this file's existing "no new mutations" principle. Decided
    per feature, not defaulted:

    - PropAttachments (server/propattachment.lua): NOTHING. That file's own
      header says so explicitly and this was re-confirmed by direct read:
      "THIS FILE exposes NO resource-global functions... no other file in
      this resource... needs to call into prop-attachment state directly."
      `PropAttachmentState`/`PendingPropAttachConfirm` are both `local`.
      There is no "is citizenid X currently wearing a prop" accessor to
      wrap because none exists, and adding one would mean writing new code
      inside a file this one does not own.
    - FetchMechanic (server/fetch.lua): NOTHING on the server side, by the
      identical reasoning — `FetchBalls`/`CarrierIndex`/
      `PendingFetchThrows`/`PendingFetchCarries`/`PendingFetchDrops` are
      all `local`, and every server-side function in that file is `local`
      too (confirmed: zero `function <Name>(` — non-`local` —
      declarations anywhere in server/fetch.lua). The one genuinely useful
      read this feature produces — is the LOCAL K9 currently carrying a
      fetch ball right now — is client-side (`IsFetchCarryEngaged()`,
      client/fetch.lua), added to client/exports.lua instead.
    - ProximityAudioFX (client/proximityaudio.lua): NOTHING, and there is
      no server-side file for this feature to begin with — it is a purely
      client-local cosmetic ambient-audio effect (see that file's own
      header). Not applicable to this file at all.
    - Partnership tenure (server/tenure.lua): NOTHING. That file's own
      header says so explicitly ("THIS FILE owns no resource-global
      (non-`local`) function of its own"), re-confirmed by direct read.
      Beyond that: the tenure VALUE itself is never cached in memory at
      all — `CheckTenureMilestonesForK9` computes it fresh via a
      `TIMESTAMPDIFF(SECOND, established_at, NOW())` SELECT every time it
      is checked (that file's own header, design question 1); the only
      in-memory table this file keeps, `TenureFullyCollected`, is a
      per-row boolean skip-cache with no tenure DURATION in it, and is
      `local` regardless. Exporting a genuine "current tenure for this
      pair" read would require either (a) a brand-new SQL query this file
      would have to own itself (forbidden by DESIGN PRINCIPLE 4 — "no
      unbounded DB work," and a caller-invoked export is exactly the "in a
      loop" case that principle exists to prevent), or (b) adding a new
      resource-global accessor inside server/tenure.lua itself, which is
      not this file's own file to edit. Both routes are closed; nothing is
      exported.
    - Admin/audit surface (server/admin.lua): NOTHING — already covered by
      the existing "k9_search_log READ-BACK" entry in "NOT IN THIS FILE"
      below, re-verified by direct read of server/admin.lua: every query
      function in that file (QueryCertificationHistory/
      QueryPartnershipHistory/QuerySearchLogByOfficer/QuerySearchLogByPlate/
      QuerySearchLogByPerson/QuerySearchLogRecent, etc.) is `local`,
      ACE-gated, and command-driven — no resource-global accessor exists to
      wrap, and building one here would mean inventing a new any-caller-
      resource authorization model for tables this file doesn't own,
      exactly the objection that existing entry already raises. No change
      needed there.

    NET EFFECT ON VERSIONING: because none of the six produced a wrappable
    resource-global on the SERVER side, this file's own API_VERSION stays
    at 1.0.0 — there is nothing additive to bump for. See VERSIONING above
    and client/exports.lua's own header for why that file's version moved
    instead, for genuinely new CLIENT-side reads (`IsFetchCarryEngaged`,
    `HasFreshDefensePrompt` + `GetDefenseSuggestedTargetNetId`, and later
    `IsPropAttachmentEngaged`). Do not read a count off this paragraph:
    client/exports.lua's own API_VERSION line is the authority. The two
    files' API_VERSION numbers are independent contracts, tracked
    separately, and are not expected to stay numerically identical going
    forward — see client/exports.lua's own VERSIONING note for the full
    reasoning.
    ======================================================================

    NOT IN THIS FILE — deliberate, with reasons:
    - Any grant/revoke/award/force-detach MUTATION (GrantCertification,
      RevokeCertification*, AwardXP, ForceDetachLeashForSource,
      ForceDetachOfficerLeashForSource, ForceBreakPartnershipForCitizenId).
      Every one of these has its own reviewed eligibility/
      proximity/cooldown/notification logic specific to how this resource's
      own client-triggered flow calls it; exporting the mutation directly
      would let an external resource skip all of that context (e.g. an MDT
      plugin "granting" a certification without ever running
      IsEligibleCertifier's checks, or a badly-written integration spamming
      ForceDetachLeashForSource). A bug in someone else's resource would
      become a live bug in this resource's own authorization state. None of
      these are exposed in v1; a genuine cross-resource need for one should
      be reviewed on its own merits, not added by default alongside the
      read-only surface.
    - k9_search_log READ-BACK (audit/dispute-history access) as a PUBLIC
      EXPORT. Still deliberately not added here. No resource-global accessor
      this file could wrap exists — server/search.lua's own LogSearchAttempt
      remains `local`. server/admin.lua has since added its own direct,
      ACE-gated `/k9audit search` SELECT against this table — so an absolute
      "nothing in this resource ever reads it back" framing is no longer
      true (check `sql/install.sql`'s own schema comment directly rather
      than assuming it needs the identical correction). That does not
      change the reasoning for this file: server/admin.lua's read is a
      console/ACE-authorized admin command with its own access-scope
      decision already made for that context, not a general-purpose,
      any-caller-resource export — building the latter would still mean
      inventing new authorization logic for a table this file doesn't own
      (principle 4 above), and would still be a distinct, unreviewed product
      question (should an arbitrary caller resource see every row, only
      their own department's, only one citizenid's?) from the admin
      command's own already-settled ACE model. Recommend, unchanged: a real
      `GetSearchHistoryForCitizenid`/`GetSearchHistoryForPlate`-style
      accessor belongs in server/search.lua itself first, exported from
      here once it exists and its access scope is decided —
      server/admin.lua's existence is useful precedent for that future
      work, not a substitute for it.
    - RefreshCertificationCache / RefreshPartnershipCache. Both are already
      resource-global functions, but both perform a live, awaited SQL query
      as a side effect of being called, and today are only ever invoked
      from this resource's own reviewed trigger points (job change,
      PlayerLoaded, resource start, an explicit revoke). Exposing either
      would let any external resource trigger an unbounded number of ad hoc
      DB round-trips against this resource's own tables on a schedule this
      resource doesn't control. HasK9Access(source) below already covers
      the overwhelming common real use case (is THIS currently-online
      player allowed to use K9 features right now) without that cost; an
      offline-citizenid certification check has no existing internal
      accessor to wrap, and building a new one here is the same "new logic
      outside its owning file" objection as the search-log case above.
    - ResolveNetworkEntity / ResolveConnectedPlayerFromPed (server/
      entities.lua), NewCooldown / NewNestedCooldown / NewMutex (server/
      cooldowns.lua). Internal plumbing utilities, not domain state — no
      external resource has a legitimate reason to resolve this resource's
      own netId-to-entity mappings, or to construct one of this resource's
      own cooldown objects.
    - A generic "list all K9 citizenids" / "list all active partnerships"
      export. Would require iterating internal `local` caches
      (Certifications in server/certifications/, Partnerships in
      server/partnership.lua, K9XP in server/progression.lua) that this
      file genuinely cannot see — true Lua file-local scope, not just a
      convention this file is choosing to respect. The only honest way to
      build one would be a new accessor added inside each owning file. A
      real consumer needing one should get a purpose-built accessor added
      to the owning file first, alongside the event-wiring work above.
    ======================================================================
]]

--- Copies a Config.XPTiers-shaped entry (xp/label/speedMultiplier/
--- scentRangeMultiplier) into a fresh table. See DESIGN PRINCIPLES item 3 above for
--- exactly why this matters: the wrapped GetXPTier() can return the SAME
--- Config.XPTiers[n] table object for many different citizenids, and this
--- file must never let an external caller obtain a live reference to it.
--- @param tier table
--- @return table copy
local function CopyTier(tier)
    -- WHY THIS RECURSES, given Config.XPTiers is flat today: the whole point
    -- of copying is that GetXPTier() internally returns the SHARED
    -- Config.XPTiers[n] reference, so handing it out raw would let any
    -- consumer mutate movement speed for every K9 in that tier, server-wide
    -- and for the rest of this resource's uptime. A shallow copy closes that
    -- for the current flat shape (xp/label/speedMultiplier/scentRangeMultiplier, all
    -- scalars) -- but it would SILENTLY STOP protecting the moment anyone
    -- adds a nested field, e.g. a per-tier perks list. Nothing would error,
    -- no test would fail, and the hole would just be open again. That
    -- "a control quietly stops working and says nothing" failure mode has
    -- bitten this resource repeatedly, so this recurses instead of relying
    -- on a shape assumption a future editor has no reason to know about.
    local copy = {}
    for key, value in pairs(tier) do
        if type(value) == 'table' then
            copy[key] = CopyTier(value)
        else
            copy[key] = value
        end
    end
    return copy
end

-- Base-tier fallback used whenever the real GetXPTier() global is missing,
-- errors, or is handed a malformed citizenid — Config.XPTiers[1] is this
-- resource's own established "unknown state defaults to least privilege"
-- baseline (see server/progression.lua's ResolveTier doc comment), reused
-- here rather than inventing a second one.
local function BaseTierCopy()
    return CopyTier(Config.XPTiers[1])
end

-- ======================================================================
-- VERSIONING
-- ======================================================================

local API_VERSION = { major = 1, minor = 0, patch = 0, string = '1.0.0' }

--- @return table { major: number, minor: number, patch: number, string: string }
exports('GetAPIVersion', function()
    -- Fresh copy every call, per DESIGN PRINCIPLES item 3 — API_VERSION
    -- above is this file's own internal state, not something a caller
    -- should hold a live reference to.
    return { major = API_VERSION.major, minor = API_VERSION.minor, patch = API_VERSION.patch, string = API_VERSION.string }
end)

-- ======================================================================
-- CERTIFICATION / ACCESS STATE (wraps server/certifications/)
-- ======================================================================

--- Server-authoritative: is `source` (a live, currently-connected player)
--- currently allowed to use K9 features? Wraps the real HasK9Access(source)
--- global 1:1 — see this file's header for why this is NOT gated on any
--- Config.Features flag. Only ever resolves a CURRENTLY-CONNECTED player;
--- there is no offline-citizenid variant (see "NOT IN THIS FILE" above).
--- @param source number
--- @return boolean
exports('HasK9Access', function(source)
    if type(source) ~= 'number' then return false end
    if type(HasK9Access) ~= 'function' then return false end -- runtime existence guard, not a load-order assumption (this resource's own convention)

    local ok, result = pcall(HasK9Access, source)
    if not ok then
        print(('[John-K9] exports:HasK9Access failed for source %s: %s'):format(tostring(source), tostring(result)))
        return false
    end
    return result == true
end)

--- Is `modelHash` (a GetHashKey'd ped model) one of this server's
--- configured K9 models (Config.Peds)? Wraps IsConfiguredK9Model 1:1 — pure
--- roster truth, not gated by any feature flag.
--- @param modelHash number
--- @return boolean
exports('IsConfiguredK9Model', function(modelHash)
    if type(modelHash) ~= 'number' then return false end
    if type(IsConfiguredK9Model) ~= 'function' then return false end

    local ok, result = pcall(IsConfiguredK9Model, modelHash)
    if not ok then return false end
    return result == true
end)

--- Is `jobName` one of this server's configured K9-eligible departments
--- (Config.Departments)? Pure config read, no wrapped function needed.
--- @param jobName string
--- @return boolean
exports('IsK9Department', function(jobName)
    if type(jobName) ~= 'string' then return false end
    return Config.Departments[jobName] ~= nil
end)

-- ======================================================================
-- PARTNERSHIP STATE (wraps server/partnership.lua)
-- ======================================================================

--- Is `citizenid` currently in an active partnership, and if so with whom?
--- Wraps GetActivePartnerCitizenId 1:1 — see this file's header for why
--- this is NOT gated on Config.Features.HandlerPartnership.
--- @param citizenid string
--- @return string? partnerCitizenid — nil if not currently partnered
--- @return boolean? isK9 — true if `citizenid` is the K9-role party; nil if not currently partnered
exports('GetActivePartnerCitizenId', function(citizenid)
    if type(citizenid) ~= 'string' or citizenid == '' then return nil, nil end
    if type(GetActivePartnerCitizenId) ~= 'function' then return nil, nil end

    local ok, partner, isK9 = pcall(GetActivePartnerCitizenId, citizenid)
    if not ok then return nil, nil end
    return partner, isK9
end)

--- Is `citizenid` currently actively partnered specifically with
--- `allegedPartnerCitizenid`? Wraps IsActivePartnerOf 1:1.
--- @param citizenid string
--- @param allegedPartnerCitizenid string
--- @return boolean
exports('IsActivePartnerOf', function(citizenid, allegedPartnerCitizenid)
    if type(citizenid) ~= 'string' or type(allegedPartnerCitizenid) ~= 'string' then return false end
    if type(IsActivePartnerOf) ~= 'function' then return false end

    local ok, result = pcall(IsActivePartnerOf, citizenid, allegedPartnerCitizenid)
    if not ok then return false end
    return result == true
end)

-- ======================================================================
-- XP / PROGRESSION STATE (wraps server/progression.lua)
-- ======================================================================

--- Raw accumulated XP total for `citizenid` (0 if uncached/unknown/invalid
--- input). Wraps GetXP 1:1 — see this file's header for why this is NOT
--- gated on Config.Features.XPProgression.
--- @param citizenid string
--- @return number
exports('GetXP', function(citizenid)
    if type(citizenid) ~= 'string' or citizenid == '' then return 0 end
    if type(GetXP) ~= 'function' then return 0 end

    local ok, xp = pcall(GetXP, citizenid)
    if not ok or type(xp) ~= 'number' then return 0 end
    return xp
end)

--- The resolved Config.XPTiers entry for `citizenid`'s current XP total —
--- ALWAYS a fresh copy (see DESIGN PRINCIPLES item 3; CopyTier
--- above), never the shared Config.XPTiers[n] reference the internal
--- GetXPTier() returns. Defaults to a copy of the base tier for an
--- unknown/invalid citizenid or if the wrapped global is unavailable —
--- this resource's own "unknown state defaults to least privilege"
--- convention, so an unresolved lookup can only ever under-report, never
--- over-report, a K9's real tier.
---
--- COMPOSES THE INDIVIDUAL OVERRIDE (bugfix, this pass): this used to
--- return the PLAIN tier — correct for a citizenid with no operator
--- override, but silently wrong for one that has a live per-K9
--- speedMultiplier/scentRangeMultiplier/medkitCooldownMultiplier override
--- set through the tablet (server/k9profiles.lua), since that override was
--- never consulted at all. server/progression.lua's own
--- BuildEffectiveTierSnapshot (the server->client `xpTierChanged` push) and
--- server/tracking.lua's own scent-range consumer both already resolve
--- through `GetK9EffectiveMultipliers(citizenid)` — server/k9profiles.lua's
--- ONE seam for its documented GLOBAL DEFAULT -> XP TIER -> INDIVIDUAL
--- OVERRIDE resolution order — instead of reading a raw tier. This export
--- now does the identical overlay: same fresh tier copy as before, with
--- `GetK9EffectiveMultipliers`'s answer composed onto it field-by-field,
--- never a re-implementation of that order (see server/progression.lua's
--- BuildEffectiveTierSnapshot for the exact overlay this mirrors — a
--- 3-field `if type(...) == 'number' then snapshot.x = effective.x end`
--- overlay onto the plain copy, not a new ladder).
---
--- SOFT-GUARDED, this resource's established `type(...) == 'function'`
--- convention: when server/k9profiles.lua is absent (an install that
--- predates it) or the pcall'd call throws, this degrades to the PLAIN
--- tier copy — this export's own pre-fix behavior, byte-for-byte — never an
--- error, and never nil to a caller resource with no idea why. A
--- citizenid with no live override is unaffected either way:
--- GetK9EffectiveMultipliers itself only overwrites a field when an
--- override row actually sets it, so this is a strict widening of
--- correctness, never a narrowing of what a non-overridden citizenid saw
--- before.
---
--- SHAPE UNCHANGED: still a copy of a Config.XPTiers-shaped entry
--- (xp/label/speedMultiplier/scentRangeMultiplier/medkitCooldownMultiplier?
--- /badge?) — only the VALUES of the three overridable fields can now
--- differ from the raw tier, never the table's shape.
--- @param citizenid string
--- @return table { xp: number, label: string, speedMultiplier: number, scentRangeMultiplier: number }
exports('GetXPTier', function(citizenid)
    if type(citizenid) ~= 'string' or citizenid == '' then return BaseTierCopy() end
    if type(GetXPTier) ~= 'function' then return BaseTierCopy() end

    local ok, tier = pcall(GetXPTier, citizenid)
    if not ok or type(tier) ~= 'table' then return BaseTierCopy() end

    local snapshot = CopyTier(tier)

    if type(GetK9EffectiveMultipliers) == 'function' then
        local effOk, effective = pcall(GetK9EffectiveMultipliers, citizenid)
        if effOk and type(effective) == 'table' then
            if type(effective.speedMultiplier) == 'number' then snapshot.speedMultiplier = effective.speedMultiplier end
            if type(effective.scentRangeMultiplier) == 'number' then snapshot.scentRangeMultiplier = effective.scentRangeMultiplier end
            if type(effective.medkitCooldownMultiplier) == 'number' then snapshot.medkitCooldownMultiplier = effective.medkitCooldownMultiplier end
        end
    end

    return snapshot
end)

-- ======================================================================
-- FEATURE-FLAG INTROSPECTION
-- ======================================================================

--- Reads Config.Features[featureKey] directly — always reflects the
--- operator's real, current toggle state (see this file's header gating
--- rationale for why every other export above is deliberately NOT gated
--- the same way). Distinguishes "a real feature that is off" (returns
--- false) from "not a recognized feature name" (returns nil) so a caller
--- can feature-detect rather than silently treat a typo'd key as disabled.
--- @param featureKey string — a key in Config.Features, e.g. 'XPProgression'
--- @return boolean? enabled — nil if featureKey is not a recognized Config.Features key
exports('IsFeatureEnabled', function(featureKey)
    if type(featureKey) ~= 'string' then return nil end

    local value = Config.Features[featureKey]
    if value == nil then return nil end
    return value == true
end)
