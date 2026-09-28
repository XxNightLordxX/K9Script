--[[
    qbx_k9unit/server/certtiers.lua

    OWNER-DIRECTED REVERSAL of a design decision already shipped in this
    codebase. Owner's own words, verbatim, for THIS pass: "Allow high
    command to edit the tiers trainee certified senior etc add more roles
    edit permissions for those roles etc."

    server/certifications/'s own header ("TIER (§5)") argues, at
    length, for the OPPOSITE of what this file builds:

        "TIER (§5): a fixed, HARDCODED 3-step ordinal — trainee <
        certified < senior (TIER_RANK below) — deliberately NOT a Config
        table. Real K9 tiering is a small, fixed vocabulary; making it
        configurable would let an operator invent tier names no future
        Phase 2/3 gate could rank against, for no real benefit — 'an
        operator can hold the model in their head' ... argued directly
        against an open-ended list here."

    THAT ARGUMENT IS NOT DELETED. It is preserved verbatim, in place, in
    that file's own header, and even preserved as a literal, still-live
    DATA STRUCTURE — the original `TIER_RANK = { trainee = 1,
    certified = 2, senior = 3 }` table is kept, unchanged, as the LAST-
    RESORT FALLBACK this file's own accessors degrade to if THIS file is
    ever unavailable (see server/certifications/'s own
    `IsKnownTierKeyOrLegacyFallback`/`GetTierOrdinalOrLegacyFallback`,
    added alongside this file). The reasoning was sound for the world it
    described — a small, permanently-fixed vocabulary nobody would ever
    need to extend — and stops applying, in full, the instant an owner
    with actual authority over this resource asks for the opposite: an
    operator-EXTENSIBLE list, editable at runtime, with per-tier granted
    capabilities. This is not a case of the earlier author being wrong;
    it is a requirement changing underneath a decision that was correct
    for the requirement it was made against. This file is that new
    requirement, built without pretending the old one was a mistake.

    ======================================================================
    WHAT THIS FILE OWNS
    ======================================================================

    THE TIER CATALOG: an ORDERED list of { key, label, ordinal,
    capabilities }, merged from two sources every time it is (re)built —
    Config.CertificationTiers (the DEFAULTS; owned by whoever owns
    config.lua) and the `k9_certification_tiers` /
    `k9_certification_tier_capabilities` database tables (the operator's
    RUNTIME EDITS, made from the K9 Command Tablet). THE DATABASE WINS —
    a DB row for a given `tier_key` completely overrides that key's
    config-supplied label/ordinal; a DB `deleted = 1` row (a TOMBSTONE,
    not a real row DELETE — see migration 0010's own header for exactly
    why a delete cannot be a real DELETE for a config-sourced key)
    excludes that key from the live catalog entirely, whether it
    originated in Config.CertificationTiers or was itself created
    entirely at runtime. See RefreshCertificationTierCatalog below for
    the exact merge algorithm.

    THE ACCESSORS THIS PASS EXTENDS server/certifications/'s SEAM WITH
    (per this task's own explicit instruction to extend, not replace,
    GetCertificationTier/MeetsTierRequirement/HasSpecialization/
    QueryCertificationRecord/QueryActiveSpecializations): this file adds
    IsKnownCertificationTierKey/GetCertificationTierOrdinal/
    ListCertificationTiers/
    TierHasCapability. server/certifications/'s own five accessors are
    UNCHANGED in name and signature; only their internal ordinal/
    known-key lookups now defer to this file's live catalog instead of a
    hardcoded table, behind a soft-dependency existence guard exactly
    like every other cross-file dependency in this resource.

    A LATER, OWNER-DIRECTED FOLLOW-UP PASS adds exactly one more accessor
    to this same seam: TierCapabilityPermits(citizenid, jobName,
    capabilityKey) -- see header "CAPABILITY COMPOSITION" further down for
    the full design. Unlike the accessors above (which answer questions
    ABOUT the catalog), this one answers the actual authorization question
    a real gate needs ("is citizenid, right now, permitted to do the thing
    capabilityKey names"), composed correctly with this resource's other
    three access layers and with the owner's own default-permissive
    constraint -- see that section before wiring anything to it.

    ======================================================================
    HAZARD 1 — EXISTING ROWS (compatibility with every already-deployed
    database)
    ======================================================================

    Migration 0006 shipped `k9_certifications.tier` as
    `VARCHAR(20) NOT NULL DEFAULT 'certified'`. Every real, already-
    running installation of this resource already has rows holding the
    literal strings 'trainee', 'certified', or 'senior' in that column,
    RIGHT NOW, with 'certified' specifically chosen at the time (per
    migration 0006's own header) to be the tier that "PRESERVES today's
    actual capability" for every pre-existing single-boolean-cert row.

    This file's default Config.CertificationTiers block (sent separately
    to whoever owns config.lua — see this pass's own hand-off note) keeps
    all three keys, at ordinals 1/2/3 respectively, with EMPTY default
    capability sets for all three. Empty is not a placeholder oversight —
    it is load-bearing: nothing anywhere in this resource, before or
    after this pass, gates any mechanic on a tier CAPABILITY (tier
    remains, exactly as server/certifications/'s own header already
    stated, "an ordinal a future search.lua/combat.lua/defense.lua gate
    may opt into" — this pass does not add that gate). Shipping a
    non-empty default capability set here would be inventing new default
    BEHAVIOR no version of this resource has ever had. Net effect: an
    operator who never opens the tablet, on a brand-new install or an
    existing one, sees ZERO behavior change — the merged catalog is
    byte-for-byte the same three keys/ordinals/empty-capabilities either
    way.

    Defensively (not merely by convention): BuildCatalogFromConfigDefaults
    below REJECTS a Config.CertificationTiers that is missing, malformed,
    or missing a 'certified' entry, and falls back to LEGACY_TIER_DEFAULTS
    (the same three keys/ordinals, hardcoded in THIS file) rather than
    letting a config mistake strand every existing certified handler.
    RefreshCertificationTierCatalog additionally re-injects a hardcoded
    'certified' entry if it is ever somehow still missing after the full
    merge (should be unreachable given DeleteTier's own unconditional
    'certified' protection below, but this file does not assume its own
    other safeguards never fail).

    ======================================================================
    HAZARD 2 — A DELETED TIER WITH ROWS STILL POINTING AT IT
    ======================================================================

    DECISION: REFUSE the deletion outright while ANY k9_certifications row
    (active OR historical/inactive — checked with no `active = 1` filter,
    since an inactive row still holds a real, audit-trail-relevant tier
    value that must not start pointing at nothing) references the tier
    key. This resource does NOT fail such rows closed to the lowest tier
    as the alternative the owner's brief also offered — refusing is
    chosen because silently rewriting a historical row's tier value would
    corrupt an audit trail this resource treats as append-only/immutable
    everywhere else (k9_certifications' own revoke history, this file's
    own k9_certification_tier_audit), for a problem refusal already
    solves with no data mutation at all.

    Consequence of "refuse while referenced": a tier key that has EVER
    been assigned to even one citizenid, ever, can never be deleted again
    — permanently. Documented, not hidden: DeleteTier's own doc comment
    states this plainly. An operator who wants a tier gone from FUTURE
    grants without deleting it has no such "retire but don't delete"
    concept in this pass — SetCertificationTier itself simply won't
    accept an already-deleted key as a NEW target (IsKnownCertificationTierKey
    returns false for a tombstoned key), so the only way to make a
    referenced tier fully disappear is to first move every citizenid off
    it (via SetCertificationTier) and then delete it — the same
    two-step an operator would need under a "reassign, then remove"
    model, without this file inventing bulk-reassignment machinery no one
    asked for.

    ADDITIONALLY, UNCONDITIONALLY, REGARDLESS OF REFERENCE COUNT: the
    literal key 'certified' can never be deleted through this surface, at
    all, ever — see PROTECTED_TIER_KEYS below. This is NOT the same
    protection as the reference-count check: 'certified' is the literal
    string baked into migration 0006's `DEFAULT 'certified'` clause AND
    into server/certifications/'s own GrantCertification INSERT
    (which relies on that same DB default and is deliberately never
    edited to accept a tier argument — see that file's own header
    "TIER"). Even a 'certified' tier with ZERO current references could
    be deleted by reference-count alone, yet the very next
    GrantCertification call would silently create a BRAND NEW row
    referencing a tier that no longer exists — the exact hazard this
    whole feature must never produce, arising from a place the reference
    count could never see coming. Hardcoded, not merely reference-
    checked, for exactly that reason.

    Net result: no live, reachable k9_certifications row can ever
    reference a tier key absent from the merged catalog, under any
    ordering of operations this file allows.

    ======================================================================
    HAZARD 3 — REORDERING CHANGES HISTORY RETROACTIVELY
    ======================================================================

    ReorderTiers below REFUSES a partial reorder outright (the submitted
    key list must be an EXACT permutation of every currently-known,
    non-tombstoned tier key — no missing key, no extra key, no
    duplicate) rather than guessing what to do with an omitted tier's
    ordinal. Every successful reorder response includes a non-optional
    `warning` string, in the actual server response (not merely logged),
    stating plainly that every citizenid already holding one of the
    reordered tiers is now ranked at its NEW position immediately —
    GetCertificationTierOrdinal/MeetsTierRequirement/TierHasCapability all
    read the LIVE catalog on every call; none of them pin to whatever
    ordinal was in effect at the moment a citizenid was actually granted
    that tier. The tablet is expected to surface this warning prominently
    (coordinated with the tablet-UI owner separately) — this file
    guarantees the warning text exists and is accurate; it does not
    control how loudly the NUI displays it. Every reorder is additionally
    written to k9_certification_tier_audit as one row (`action =
    'tier_reorder'`, `tier_key = 'ALL'`) with the full before/after
    ordinal listing in `detail` — "say what you did", permanently, not
    just in the moment.

    ======================================================================
    HAZARD 4 — PRIVILEGE ESCALATION (THE ONE THAT MATTERS MOST)
    ======================================================================

    THREAT MODEL, STATED EXPLICITLY: the adversary is an authenticated
    in-game player who currently qualifies as IsHighCommand (a real,
    intended trust level in this resource — see server/highcommand.lua),
    attempting to use the tier-editing surface to grant a tier (their own
    current one, or one they could move themselves or an ally to via
    SetCertificationTier) a capability that exceeds what high command
    itself is unconditionally allowed to do, OR to have that capability
    interpreted, now or by some future consumer, as equivalent to
    granting a PERMISSION (server/permissions.lua's k9_permissions layer)
    or to BECOMING high command. A secondary adversary is a compromised/
    malicious NUI or client sending a forged `source`/authorization claim
    directly to one of this file's lib.callback endpoints, bypassing the
    tablet UI entirely.

    DEFENSE AGAINST THE SECOND ADVERSARY: every one of this file's FOUR
    mutating-or-listing callbacks calls CanManageCertTiers(source) as its
    OWN first action, which itself calls the real, live
    IsHighCommand(source) — server-side, against `source`'s CURRENT
    PlayerData/job/grade at the moment of the call, every single call, no
    caching, no trusting any flag/value the NUI payload itself carries.
    There is no code path in this file that reads an authorization
    decision from the CLIENT rather than re-deriving it server-side. A
    forged callback invocation with an arbitrary `source` still resolves
    through the real qbx_core player object for THAT connection, which an
    attacker does not control — this is the same "the client only offers
    a convenience, the server is the only authority" posture this
    resource enforces everywhere else (see server/certifications/'s
    own DEVELOPER_REFERENCE.md §4.3 quote).

    DEFENSE AGAINST THE FIRST ADVERSARY (the actual privilege-escalation
    surface, structurally, not merely procedurally): CAPABILITY_CATALOG
    below is a FIXED, CODE-OWNED, CLOSED vocabulary — five capability
    keys, none of them editable at runtime, none of them addable via
    config.lua either (this catalog is a `local` Lua table in THIS file,
    not a Config.* value at all, deliberately — an operator with server
    file access could edit config.lua, but even that operator cannot
    invent a new capability key without a real code change to this file).
    High command's editing power over capabilities is SCOPED, BY
    CONSTRUCTION, to toggling MEMBERSHIP in this already-fixed,
    already-code-reviewed set — never to inventing a new capability
    string, and never to associating a tier with anything outside this
    list. The actual safety property this buys: NONE of the five entries
    in CAPABILITY_CATALOG, as shipped in this pass, map to "grant a
    permission", "become high command", "bypass IsHighCommand", or "edit
    the tier system itself" — those remain governed EXCLUSIVELY by their
    own separate, pre-existing, non-tier-based checks
    (server/permissions.lua's own Config.Permissions catalog +
    HasPermission/GrantPermission, and server/highcommand.lua's own
    grade-based IsHighCommand) which this file does not touch, does not
    read, and does not make tier-editable in any way.

    UPDATED THIS PASS (owner-directed follow-up: "wire the capabilities to
    something real, or say plainly why not") — read together with the new
    section "CAPABILITY COMPOSITION — TierCapabilityPermits" below, which
    is the full design writeup. Short version: a real resolution
    primitive, TierCapabilityPermits(citizenid, jobName, capabilityKey),
    now exists in this file and is fully unit-tested. It is NOT, as of
    this pass, called from anywhere outside this file and its own tests —
    confirmed by grep, the same way the previous paragraph's claim was
    confirmed before this pass. That means every capability remains
    exactly as behaviorally INERT in a running server today as it was
    before this pass: granting or revoking one still changes nothing a
    player can observe, because zero consumer call sites exist yet. What
    changed is that a consumer CAN now exist with one added line, in
    exactly the shape every other cross-file gate in this codebase already
    uses (a `type(TierCapabilityPermits) == 'function'` soft-dependency
    guard, then a single AND-condition) — the missing piece was never "how
    would a gate check this", it was "there was no gate to check it FROM",
    since the three real candidate call sites this pass identified
    (server/certifications/'s GrantSpecialization,
    server/combat.lua's ValidateCombatRequest, and
    server/equipmentshop.lua's shop registration) are not files this pass
    owns or may edit. The exact, reviewed diff for the first two has been
    handed to main/coder-backend rather than applied here or left as a
    vague TODO; the third turned out to need more than a diff (see that
    section). This is deliberate, not a placeholder to be embarrassed
    about: it means the WORST CASE of every single edit this surface
    allows, TODAY, in a running server, is still "the tablet displays a
    different set of checkboxes for a tier" — there is no path, today,
    from this file's own code to a real capability change of any kind,
    let alone an escalating one — while the NEXT pass that lands one of
    the two proposed one-line diffs needs no further design work here.

    THE HONEST BOUNDARY OF WHAT THIS PASS CAN GUARANTEE, STATED
    EXPLICITLY: this file cannot retroactively guarantee the safety of a
    FUTURE consumer that chooses to wire a real gate to
    TierCapabilityPermits(citizenid, jobName, 'some_future_capability') —
    that responsibility belongs to whoever adds that consumer, and to
    CAPABILITY_CATALOG's own reviewers at the point a new entry is
    proposed for it (a genuine code change, reviewed like any other, never
    an in-game action). A future consumer wiring a REAL gate should call
    TierCapabilityPermits, not raw TierHasCapability directly — the latter
    has no notion of "dormant until first grant" and would, if called
    directly against citizenid's raw resolved tier, immediately deny every
    capability to every tier on the very first server boot after this
    pass (every shipped tier's capability set is empty — HAZARD 1), which
    is exactly the "quietly strips abilities from everyone" outcome the
    owner's own brief explicitly forbids. TierHasCapability itself is
    unchanged and remains correct for what it has always answered ("does
    THIS tier, right now, carry THIS capability" — the tablet's own
    display question); TierCapabilityPermits is the newer, composed
    question ("should THIS citizenid's action be allowed, given
    everything this file and the owner's own constraints require") a real
    gate actually needs. What this file DOES guarantee, permanently, by
    construction: the SET of capability strings that can ever be
    associated with a tier is closed and code-owned, never open-ended/
    free-text, so no future consumer can ever be surprised by an
    capability key nobody wrote code to define.

    THE DELETE-VS-ASSIGN RACE (found and closed this pass, not merely
    disclosed): a naive "check reference count, then tombstone" DeleteTier
    and a naive "check known-key, then UPDATE" SetCertificationTier (in
    server/certifications/) can interleave across their own
    MySQL.await yield points — DeleteTier's reference-count read could
    observe zero references an instant before a concurrent
    SetCertificationTier commits a BRAND NEW reference to that exact key,
    after which DeleteTier's own tombstone write would still proceed,
    producing exactly the "row referencing a tier that no longer exists"
    outcome this feature must never produce. Closed with `TierEditMutex`
    (NewMutex(), keyed by tier_key, exposed as a bare global specifically
    so server/certifications/'s SetCertificationTier can acquire the
    SAME lock before its own UPDATE — see that function's own updated
    comment) — DeleteTier and SetCertificationTier now serialize on the
    same tier_key, so whichever acquires first completes its ENTIRE
    check-then-write critical section before the other can begin.
    UpsertTier/ReorderTiers acquire the same per-key mutex around their
    own writes for the identical reason (a concurrent rename/capability
    edit or reorder-write racing a delete/restore for the same key).
    Guarded everywhere it is CONSUMED (server/certifications/) with a
    `type(TierEditMutex) == 'table'` runtime existence check, this
    resource's established soft-dependency convention — SetCertificationTier
    still functions, accepting only the narrow, now-explicitly-disclosed
    pre-existing race, if this file is ever removed.

    "MUST NEVER GRANT ITSELF MORE": high command's OWN effective
    authority (IsHighCommand's own grade-based check) is never read from,
    written to, or influenced by anything in this file — there is no
    mechanic anywhere in this file, or in the capability catalog it
    exposes, that can raise a citizenid's OWN job grade, grant them the
    'k9.certify'/'k9.access'/any other k9_permissions key, or otherwise
    widen what IsHighCommand or HasPermission would independently decide
    about them. Editing a tier's label/ordinal/capability set never
    touches any player's job/grade/permission-grant row.

    "IT CAN BE DONE QUIETLY, EVEN IF IT ISN'T ESCALATION" (economy red-team
    follow-up, coder-security): the paragraph above establishes there is no
    PRIVILEGE-ESCALATION shape here -- granting a capability to your own
    currently-held tier cannot make IsHighCommand/HasPermission decide
    anything different about you. It CAN still be self-preferential in a
    quieter way this file did not previously call out: granting capability
    C to your own tier makes C ACTIVE resource-wide (IsCapabilityActiveInternal),
    which instantly narrows every OTHER tier's access to C down to nothing,
    while your own tier keeps it -- then revoking it a moment later restores
    the prior (usually dormant, "everyone allowed") state, with the only
    trace being two ordinary-looking `capabilities_added`/`capabilities_removed`
    audit lines under the same `tier_key`. certTiersUpsert below now
    resolves the acting officer's OWN currently-held tier
    (GetCertificationTier(citizenid, jobName, true), soft-guarded) and, when
    it matches the `key` being edited, appends a `SELF-TIER CAPABILITY EDIT`
    marker to that SAME audit line (not a separate row) and returns a
    non-optional `warning` in the response, mirroring server/xptiers.lua's
    own "louder for a self-serving effect, never blocked" decision for its
    own promoted-online-citizenid case. This is disclosure, not a new gate:
    the edit still completes in one action either way.

    ======================================================================
    CAPABILITY COMPOSITION — TierCapabilityPermits (this pass, owner-
    directed follow-up: "wire the capabilities to something real")
    ======================================================================

    THE QUESTION THIS SECTION ANSWERS, STATED ONCE, FOR EVERY PRESENT AND
    FUTURE CAPABILITY: where does a tier capability sit relative to the
    THREE gates this codebase already has — Config.Features.<Name> (the
    global switch), Config.FeatureControl (per-person block/grant, the
    4-step resolution server/pursuitsprint.lua's own header documents
    canonically), and HasK9Access (certified, OR a granted 'k9.access'
    permission, OR a qualifying job grade)? ONE rule, stated here once,
    not a per-capability judgment call:

      A tier capability is a FLOOR laid UNDERNEATH all three of those —
      never a substitute for any of them, and never able to WIDEN what
      they already decide. A real consumer evaluates the existing three
      exactly as it does today, in their existing order; only once all
      three have already said "allowed" does TierCapabilityPermits get
      consulted, as one FINAL, ADDITIONAL AND-condition. It can only
      NARROW an already-permitted population (e.g. "certified handlers
      may BiteAndHold, but not the trainee-tier ones") — it can never
      grant to someone those three would otherwise refuse.

    DEFAULT-PERMISSIVE ON ABSENCE, PRECISELY (the owner's own explicit
    constraint: "An unconfigured or unrecognised capability must not
    silently deny"). Enforcement for a given capabilityKey is DORMANT —
    TierCapabilityPermits always returns true, for every tier, including
    one with an empty capability set — until the FIRST time ANY tier in
    the LIVE catalog is explicitly granted that exact key
    (the internal IsCapabilityActiveInternal check inside TierCapabilityPermits below). This is what makes landing this pass's
    code a zero-behavior-change event for every existing install: this
    file's own three default tiers ship with EMPTY capability sets
    (HAZARD 1) and nobody has ever ticked a capability checkbox before
    this pass exists, so nothing is ACTIVE anywhere until an operator
    deliberately uses the tablet — the exact same "byte-for-byte
    unaffected until touched" guarantee HAZARD 1 already gives the tier
    catalog itself, extended here to capabilities. The moment an operator
    grants capabilityKey to at least one tier, that key goes ACTIVE
    resource-wide: from then on, a citizenid whose OWN resolved tier does
    not carry it is denied wherever a real consumer checks it. A
    citizenid with NO certification-assigned tier AT ALL for this job —
    no active k9_certifications row ever existed, or it was manually
    revoked (GetCertificationTier(citizenid, jobName, true) returns nil —
    see that accessor's own doc comment, server/certifications/) — is
    ALSO allowed, never denied: their K9 access, if any, necessarily comes
    through the 'k9.access' permission grant / high-command bypass /
    autoAccessGrade job-grade path, none of which HasK9Access treats as
    tier-dependent, and an inability to classify someone this way is
    treated exactly like the dormant case, never as a reason to restrict
    them.
    SECURITY FIX (coder-security, tier-bypass-on-expiry review): this used
    to ALSO cover a citizenid whose certification-assigned tier had merely
    EXPIRED (the 2-argument GetCertificationTier(citizenid, jobName), which
    folds expiry into "no tier" for every OTHER consumer, used to be the
    ONLY signal this function consulted). That let a capability an operator
    explicitly withheld from a tier silently come back the instant that
    handler's certification lapsed, for as long as they kept K9 access
    through one of the other three routes above — no exploitation needed,
    ordinary certification lifecycle produced it. FIXED: this function now
    calls the 3-argument form, GetCertificationTier(citizenid, jobName,
    true), which does NOT fold expiry into "no tier" — an EXPIRED-but-real
    tier assignment is now evaluated for real, and only a citizenid with NO
    certification row at all for this job is treated as unresolvable now.
    An unrecognized capabilityKey (a typo, or
    a key later removed from CAPABILITY_CATALOG) can never be "active" in
    the first place — that internal check itself returns false for
    anything outside the closed catalog — so it always resolves to allow,
    structurally, not by convention.

    NO UNBOUNDED TRAP, RESTATED AS A RULE FOR FUTURE CONSUMERS, NOT MERELY
    AN OBSERVATION ABOUT TODAY'S CODE (see HAZARD 5 immediately below,
    updated this pass): TierCapabilityPermits must NEVER be called from a
    termination/cleanup path — EndActiveEffectForHolder, EndHold, a leash
    detach, Recall, a partnership break, or any other "undo what an
    active effect is doing" code, in this file or any future consumer.
    Gate the REQUEST that OPENS an effect only; a capability revoked
    mid-action must never strand a suspect, a leash, or a hold. This
    mirrors config.lua's own Config.FeatureControl convention exactly —
    server/combat.lua's ValidateCombatRequest doc comment already states
    "NEVER called for a termination/cleanup path" for the identical
    reason — so a future consumer following that same existing discipline
    gets this one for free by construction, not by remembering to.

    THE TWO REAL CANDIDATE CONSUMERS: WIRED, as of a later pass than the one
    that wrote this paragraph. This originally described both as NOT YET
    WIRED, both files off-limits to that pass, with only a proposed diff on
    file; that is no longer true. Both are live now — see
    server/certifications/'s GrantSpecialization (~line 4347) and
    server/combat.lua's ValidateCombatRequest (~line 1650) for the actual
    call sites, and the CAPABILITY_CATALOG labels above, which already say
    ENFORCED for both. The original per-consumer writeup is kept below,
    updated from proposed to landed, for the design reasoning:
      - server/certifications/'s GrantSpecialization — previously
        checked only IsEligibleCertifier(granter) and the TARGET's active
        base certification, never whether the target's OWN tier is even
        eligible to hold a specialization at all. Landed: one added check,
        right after the existing "specialization_requires_active_cert"
        check, calling TierCapabilityPermits(targetCitizenid, jobName,
        'specializations_eligible').
      - server/combat.lua's ValidateCombatRequest — previously checked
        HasK9Access and the existing per-person Config.FeatureControl
        resolution (IsCombatFeaturePermittedForCitizenId), never the
        acting K9 HANDLER's own tier, for BiteAndHold/NonLethalTakedown
        specifically (NOT PropDragging, which shares this same validator
        for an unrelated mechanic the capability catalog does not name).
        Landed: one added check, calling TierCapabilityPermits(k9Citizenid,
        k9JobName, 'bite_hold_and_takedown') — at REQUEST time only, never
        touching EndHold/the maintenance-thread expiry sweep, per "NO
        UNBOUNDED TRAP" above.
    A third candidate, server/equipmentshop.lua's shop registration
    (specialized_equipment_access), was investigated and found to need
    MORE than a diff: this resource routes the entire K9 supply shop
    through one whole-shop K9Compat/ox_inventory RegisterShop call with a
    single shared `groups` restriction and no per-item, per-player,
    per-purchase hook at all — the same class of "ox_inventory has no
    real per-owner ACL primitive to hook" finding this file's own sibling,
    server/inventory.lua's header, already documents for stashes. Gating
    one specific item by tier capability would need new purchase-gating
    machinery (e.g. this resource's own buy-item callback in front of
    ox_inventory, or a live-refreshed second shop registration keyed off
    capability state) that does not exist today — flagged as a real,
    disclosed architectural gap for a future pass, not solved here as a
    false one-liner.

    advanced_tracking and mentor_trainees have NO real mechanic anywhere
    in this codebase, editable or not, that could plausibly be gated —
    confirmed by reading every server file this pass's own agent may and
    may not edit. Neither has a home to wire into yet; both stay reserved
    for that reason alone, independent of the file-ownership boundaries
    that stopped the two candidates above.

    ======================================================================
    HAZARD 5 — NO UNBOUNDED TRAP
    ======================================================================

    Nothing in this file gates, and nothing in this pass's edit to
    server/certifications/'s SetCertificationTier gates, any
    termination/cleanup path (EndActiveEffectForHolder, leash detach,
    Recall, partnership break, etc.) — this file introduces no new gate
    on any of those at all. As of THIS pass this is no longer solely an
    accident of nothing consuming TierHasCapability/TierCapabilityPermits
    yet (a real resolution primitive now exists — see "CAPABILITY
    COMPOSITION" above) — it is additionally now an EXPLICIT rule stated
    in that section, binding on this file and on every future consumer:
    gate the request that opens an effect, never the release that closes
    one. That older, simpler justification — tier capability enforcement
    was globally DORMANT (no tier anywhere had ever had a capability
    granted outside a test), with zero consumer call sites outside this
    file's own tests, so there was doubly no trap to build — held at the
    time this paragraph was written. It no longer does:
    server/certifications/ (~line 4347) and server/combat.lua (~line
    1650) both now call TierCapabilityPermits for real, gating
    specializations_eligible and bite_hold_and_takedown respectively. The
    invariant this section states still holds regardless, because it no
    longer rests on that absence — it rests on the EXPLICIT rule above,
    which both of those call sites already follow (request-time only,
    never a termination/cleanup path).
    SetCertificationTier's pre-existing behavior (confirmed unchanged by
    this pass, re-read before writing this file) never force-detaches
    anything even on an ordinary tier CHANGE, let alone a tier DELETION —
    server/certifications/'s own EXPIRY design note already establishes
    the precedent this follows: "an already-formed leash/partnership/
    in-progress action is untouched" by a passive/administrative tier
    change. Deleting or downgrading the tier out from under someone
    mid-action therefore cannot interrupt that action today, and must not
    be allowed to once a real consumer lands either — the rule in
    "CAPABILITY COMPOSITION" above is what keeps that true going forward,
    not merely the current absence of any consumer.

    ======================================================================
    CONCURRENT-ADD ORDINAL TIE (disclosed, non-security-relevant, minor
    limitation left in place)
    ======================================================================

    UpsertTier assigns a brand-new (or being-restored) tier's ordinal as
    "current max ordinal across the live catalog, plus one", computed
    from the in-memory TierByKey snapshot at the moment of the call, NOT
    inside the same atomic statement as the write. Two DIFFERENT new tier
    keys created in the same instant by two concurrent high-command
    sessions could therefore both compute the same "next" ordinal and end
    up tied. A tie is a fully safe, non-crashing, non-escalating outcome
    (GetCertificationTierOrdinal's `>=` comparison simply treats the two
    as equal rank) — resolved the next time anyone runs ReorderTiers, or
    by re-upserting one of the two tiers. Not mitigated further: closing
    this fully would need a single atomic "compute-next-and-insert" SQL
    statement across a catalog that is PARTLY sourced from config.lua
    (which has no row in this database at all) — disproportionate
    engineering for a display-ordering nicety, unlike the delete-vs-assign
    race above, which risked a real invariant (no dangling tier
    reference), not merely a display tie.
]]

-- ======================================================================
-- LEGACY FALLBACK — the ORIGINAL server/certifications/ TIER_RANK
-- table, preserved here (not merely in a comment) as LEGACY_TIER_DEFAULTS,
-- the built-in floor BuildCatalogFromConfigDefaults falls back to if
-- Config.CertificationTiers is ever missing/malformed. See header
-- "HAZARD 1" above.
-- ======================================================================
local LEGACY_TIER_DEFAULTS = {
    { key = 'trainee',   label = 'Trainee',   ordinal = 1, capabilities = {} },
    { key = 'certified', label = 'Certified', ordinal = 2, capabilities = {} },
    { key = 'senior',    label = 'Senior',    ordinal = 3, capabilities = {} },
}

-- ======================================================================
-- CAPABILITY_CATALOG — fixed, code-owned, CLOSED vocabulary. See header
-- "HAZARD 4" for the full threat-model writeup this table's own existence
-- depends on. NOT a Config.* value, deliberately — adding a new entry
-- here is a real code change, reviewed like any other, never an in-game
-- or config.lua action. This paragraph originally said every entry was
-- INERT with no gate anywhere reading TierHasCapability; that is no
-- longer true for two of the five. See each entry's own label below for
-- its current, individual status, and HAZARD 5 above for the live call
-- sites of the two that are now ENFORCED.
-- ======================================================================
-- LABELS. specializations_eligible and bite_hold_and_takedown are wired
-- to a real consumer each (server/certifications/'s GrantSpecialization
-- and server/combat.lua's ValidateCombatRequest respectively -- see
-- HAZARD 5 above) and their own labels below say ENFORCED. The other
-- three remain inert, for the reasons the previous version of this
-- paragraph already gave and which still hold: advanced_tracking and
-- mentor_trainees have no mechanic anywhere in this codebase to gate at
-- all yet; specialized_equipment_access has a candidate mechanic but
-- needs new purchase-gating machinery this resource does not have today,
-- not a small change.
local CAPABILITY_CATALOG = {
    specializations_eligible = {
        label = 'Eligible to hold K9 specializations (narcotics/explosives/patrol) -- ENFORCED. Grant this to a tier and only that tier can be given specializations. Someone who already holds one keeps it.',
    },
    advanced_tracking = {
        label = 'Advanced tracking (reserved -- no such mechanic exists anywhere in this codebase yet to gate)',
    },
    bite_hold_and_takedown = {
        label = 'Bite & Hold / Non-Lethal Takedown -- ENFORCED. Grant this to a tier and ONLY that tier can bite or take down. Dragging is not covered. Anyone mid-hold can still be released.',
    },
    mentor_trainees = {
        label = 'May mentor/supervise trainee-tier handlers (reserved -- no such mechanic exists anywhere in this codebase yet to gate)',
    },
    specialized_equipment_access = {
        label = 'Access to specialized K9 equipment shop items (reserved -- this resource\'s shop is one whole-shop registration with no per-item purchase check to gate; needs a new design, not a small change)',
    },
}

-- Hardcoded, unconditional -- see header "HAZARD 2". Deletable status is
-- NOT determined by reference count alone for this one key; see
-- DeleteTier below for exactly why.
local PROTECTED_TIER_KEYS = { certified = true }

-- Defensive cap on total live (non-tombstoned) tier count -- an
-- already-authenticated high-command account is a highly trusted actor,
-- but an unbounded catalog is still an unforced footgun (e.g. a stuck
-- tablet retry loop hammering create with a new key each time). Well
-- above any real operator's plausible tier count.
local MAX_TIERS = 40

-- Live, in-memory catalog state -- rebuilt wholesale by
-- RefreshCertificationTierCatalog below, never partially mutated in
-- place. Declared here (before every function that closes over them) so
-- every reference below is a proper upvalue, not an accidental global --
-- same discipline server/certifications/'s own `local Certifications`/
-- `local Specializations` tables already establish.
-- Not initialized to `{}` here -- both are populated for real a few
-- lines down (the "Initial SYNCHRONOUS population" block) before
-- anything ever reads either one, so an intermediate `{}` here would
-- just be dead-written-over state (flagged, correctly, by luacheck).
local TierByKey
local TierOrder

--- @param list any
--- @return boolean
local function IsValidStaticTierDefaultsList(list)
    if type(list) ~= 'table' then return false end
    local seenKeys, seenCertified = {}, false
    for _, entry in ipairs(list) do
        if type(entry) ~= 'table'
            or type(entry.key) ~= 'string' or entry.key == ''
            or type(entry.label) ~= 'string' or entry.label == ''
            or type(entry.ordinal) ~= 'number' then
            return false
        end
        if seenKeys[entry.key] then return false end
        seenKeys[entry.key] = true
        if entry.key == 'certified' then seenCertified = true end
    end
    -- 'certified' MUST be present -- see header "HAZARD 1".
    return seenCertified
end

--- Builds a fresh key -> {label, ordinal, capabilities} map from
--- Config.CertificationTiers, falling back to LEGACY_TIER_DEFAULTS on any
--- shape problem. Does NOT consult the database -- see
--- RefreshCertificationTierCatalog for the merge step that layers runtime
--- overrides on top of this.
--- @return table<string, table>
local function BuildCatalogFromConfigDefaults()
    local source = Config.CertificationTiers
    if not IsValidStaticTierDefaultsList(source) then
        print('[qbx_k9unit] certtiers: Config.CertificationTiers is missing, malformed, or missing a ' ..
            '\'certified\' entry -- falling back to the built-in legacy defaults (trainee=1/certified=2/' ..
            'senior=3) so every existing k9_certifications row (which may hold any of those three literal ' ..
            'strings, per migration 0006\'s own DEFAULT) keeps resolving to a real tier. Fix ' ..
            'Config.CertificationTiers in config.lua.')
        source = LEGACY_TIER_DEFAULTS
    end

    local map = {}
    for _, entry in ipairs(source) do
        local capabilities = {}
        if type(entry.capabilities) == 'table' then
            for capKey, granted in pairs(entry.capabilities) do
                if granted == true and CAPABILITY_CATALOG[capKey] then
                    capabilities[capKey] = true
                end
            end
        end
        map[entry.key] = { label = entry.label, ordinal = entry.ordinal, capabilities = capabilities }
    end
    return map
end

--- Rebuilds `TierByKey`/`TierOrder` from Config.CertificationTiers merged
--- with the current `k9_certification_tiers` /
--- `k9_certification_tier_capabilities` database state -- THE DATABASE
--- WINS per key (see header). Called once at this file's own
--- onResourceStart (see bottom of this file) and again after every
--- successful mutation (Upsert/Reorder/Delete) so a caller's own response
--- (and any other in-flight reader) sees the true new state immediately,
--- never a stale one.
local function RefreshCertificationTierCatalog()
    local merged = BuildCatalogFromConfigDefaults()

    local overrideRows = K9Store.Tier_GetAllRows()
    for _, row in ipairs(overrideRows) do
        if row.deleted == 1 or row.deleted == true then
            -- TOMBSTONE: exclude entirely, whether this key originated in
            -- Config.CertificationTiers or was created purely at runtime.
            -- See migration 0010's own header "WHY A TOMBSTONE" for why
            -- this is the ONE code path handling both cases.
            merged[row.tier_key] = nil
        else
            merged[row.tier_key] = {
                label = row.label,
                ordinal = tonumber(row.ordinal) or 0,
                capabilities = {}, -- filled in below
            }
        end
    end

    -- Capability rows for an already-excluded (tombstoned) tier_key are
    -- simply never attached to anything here -- inert dead weight, not
    -- cleaned up, per migration 0010's own header.
    local capRows = K9Store.TierCap_GetAllRows()
    for _, row in ipairs(capRows) do
        local entry = merged[row.tier_key]
        if entry and CAPABILITY_CATALOG[row.capability_key] then
            entry.capabilities[row.capability_key] = true
        end
    end

    -- FAIL-SAFE (header "HAZARD 1"): should be unreachable through this
    -- file's own DeleteTier (PROTECTED_TIER_KEYS unconditionally refuses
    -- 'certified'), reachable only via a hand-edited database. Never let
    -- that silently strand every existing k9_certifications row with
    -- tier='certified' pointing at nothing.
    if not merged['certified'] then
        print('[qbx_k9unit] certtiers: \'certified\' tier missing from the merged catalog after refresh -- ' ..
            'reinstating the built-in default. This resource\'s own DeleteTier unconditionally refuses to ' ..
            'ever tombstone \'certified\' -- seeing this means k9_certification_tiers was edited outside this ' ..
            'resource\'s own code path.')
        merged['certified'] = { label = 'Certified', ordinal = 2, capabilities = {} }
    end

    local order = {}
    for key in pairs(merged) do order[#order + 1] = key end
    table.sort(order, function(a, b)
        if merged[a].ordinal ~= merged[b].ordinal then return merged[a].ordinal < merged[b].ordinal end
        return a < b -- stable, deterministic tie-break -- see header "CONCURRENT-ADD ORDINAL TIE"
    end)

    TierByKey = merged
    TierOrder = order
end

-- Initial SYNCHRONOUS population from config defaults ONLY, at this
-- file's own load time -- config.lua is a shared_script, loaded in full
-- before any server_scripts file (this one included) starts executing,
-- so Config already holds its real, final values by the time this line
-- runs (same reasoning server/certifications/'s own K9ModelHashes
-- precomputation gives for the identical structural point). This makes
-- every accessor below safe to call even before onResourceStart fires
-- for this resource, at the cost of not yet reflecting any DB override --
-- the onResourceStart handler at the bottom of this file layers the
-- database on top a moment later, before any player action could
-- plausibly reach a tier check.
TierByKey = BuildCatalogFromConfigDefaults()
do
    local order = {}
    for key in pairs(TierByKey) do order[#order + 1] = key end
    table.sort(order, function(a, b) return TierByKey[a].ordinal < TierByKey[b].ordinal end)
    TierOrder = order
end

-- ======================================================================
-- PUBLIC READ ACCESSORS -- exposed globally (no `local`), extending the
-- SAME seam server/certifications/'s own GetCertificationTier/
-- MeetsTierRequirement/HasSpecialization/QueryCertificationRecord/
-- QueryActiveSpecializations already established, per this task's own
-- explicit "extend, not replace" instruction. Every one of these is a
-- read, never a write, and every one is hot-path-safe (cache-based, no
-- query) except where noted.
-- ======================================================================

--- @param key any
--- @return boolean
function IsKnownCertificationTierKey(key)
    return type(key) == 'string' and TierByKey[key] ~= nil
end

--- @param key any
--- @return number?
function GetCertificationTierOrdinal(key)
    local entry = type(key) == 'string' and TierByKey[key]
    return entry and entry.ordinal or nil
end

--- Ordered (by ordinal ascending) snapshot of the live catalog -- a COPY,
--- not the live tables, so a caller (the tablet aggregation layer, or any
--- future consumer) cannot mutate this file's own authoritative state by
--- editing the returned value.
--- @return table[] -- { { key, label, ordinal, capabilities: table<string,true> }, ... }
function ListCertificationTiers()
    local list = {}
    for _, key in ipairs(TierOrder) do
        local entry = TierByKey[key]
        local capsCopy = {}
        for capKey in pairs(entry.capabilities) do capsCopy[capKey] = true end
        list[#list + 1] = { key = key, label = entry.label, ordinal = entry.ordinal, capabilities = capsCopy }
    end
    return list
end

--- @param key any
--- @param capabilityKey any
--- @return boolean
function TierHasCapability(key, capabilityKey)
    if type(capabilityKey) ~= 'string' then return false end
    local entry = type(key) == 'string' and TierByKey[key]
    return entry ~= nil and entry.capabilities[capabilityKey] == true
end

-- ======================================================================
-- CAPABILITY COMPOSITION -- see header "CAPABILITY COMPOSITION" for the
-- full design writeup TierCapabilityPermits below implements.
-- IsCapabilityActiveInternal is a `local` helper, DELIBERATELY not
-- exposed as a resource-global (unlike every accessor above) -- it has no
-- real consumer of its own outside TierCapabilityPermits, and this
-- resource's own .luacheckrc `globals` allowlist is off-limits to this
-- pass (see this pass's own report to main), so the new public surface
-- this file adds is kept to the ONE function a real consumer actually
-- needs to call, not two. Both are hot-path-safe (O(number of live
-- tiers), no query) exactly like every other accessor in this section.
-- ======================================================================

--- Is `capabilityKey` currently ACTIVE anywhere in the LIVE catalog --
--- i.e. does at least one non-tombstoned tier currently carry it? An
--- unrecognized key can never be active: CAPABILITY_CATALOG is closed
--- (HAZARD 4), so a typo'd or future-removed key simply cannot match any
--- tier's own (equally catalog-filtered, see NormalizeCapabilitiesInput)
--- capability set -- this is what makes TierCapabilityPermits below fail
--- OPEN on an unrecognized key structurally, not merely by coincidence.
--- @param capabilityKey any
--- @return boolean
local function IsCapabilityActiveInternal(capabilityKey)
    if type(capabilityKey) ~= 'string' or not CAPABILITY_CATALOG[capabilityKey] then
        return false
    end
    for _, entry in pairs(TierByKey) do
        if entry.capabilities[capabilityKey] then return true end
    end
    return false
end

--- THE single resolution point a real consumer wiring a tier capability
--- to an actual gate must call -- see header "CAPABILITY COMPOSITION" for
--- the full contract this implements (the one rule, stated once: a floor
--- UNDERNEATH Config.Features / Config.FeatureControl / HasK9Access,
--- never a substitute for any of them, checked only AFTER a caller has
--- already evaluated all three). NEVER call this from a termination/
--- cleanup path -- see header "CAPABILITY COMPOSITION" 's own "NO
--- UNBOUNDED TRAP" paragraph and HAZARD 5 below.
---
--- Returns true (ALLOW) in every case this file cannot AFFIRMATIVELY
--- prove should be denied:
---   - `capabilityKey` is not a recognized catalog key (dormant for a
---     reason other than "no tier grants it yet").
---   - `capabilityKey` is DORMANT -- no tier in the live catalog grants it
---     yet. Covers every install that predates this pass, byte for byte
---     (HAZARD 1's empty default capability sets), and every capability
---     no operator has ever touched from the tablet.
---   - GetCertificationTier is unavailable (soft dependency,
---     server/certifications/ absent) or citizenid/jobName are not
---     both strings.
---   - GetCertificationTier(citizenid, jobName, true) returns nil -- NO
---     active, job-matching certification ROW exists for this citizenid at
---     all (never certified for this job, or a manually revoked row). This
---     is NOT assumed to mean "no K9 access" -- HasK9Access can
---     independently be true via a 'k9.access' permission grant, a
---     high-command bypass, or an autoAccessGrade job grade, none of which
---     this file can express as a tier at all. This is the ONLY case
---     treated as unresolvable-and-allowed: this function only ever
---     narrows access for a citizenid it can affirmatively PLACE outside an
---     ACTIVE capability, never for one it cannot classify.
---   - Note what is deliberately NOT in this list any more (SECURITY FIX,
---     coder-security, tier-bypass-on-expiry review): "the certification is
---     expired" used to ALSO be folded into "unresolvable" here, because
---     this function used to call the 2-argument GetCertificationTier(citizenid,
---     jobName), which folds expiry into "no tier" for every consumer. That
---     let a capability an operator explicitly withheld from a tier
---     silently come back the instant that handler's certification lapsed,
---     for as long as they kept K9 access through one of the other three
---     routes above -- no exploitation needed, ordinary certification
---     lifecycle produced it. FIXED: this function now passes
---     `includeExpired = true`, so a citizenid whose certification-assigned
---     tier is merely STALE (a real, active, job-matching row exists, but
---     has expired) has THAT tier evaluated for real below, never silently
---     treated as if no certification had ever existed. Only a citizenid
---     with NO certification row at all for this job is still unresolvable.
--- Returns false ONLY when `capabilityKey` is ACTIVE (>=1 tier grants it)
--- AND citizenid's own resolved tier (STALE or not) is not among the tiers
--- granting it.
--- @param citizenid any
--- @param jobName any
--- @param capabilityKey any
--- @return boolean allowed
function TierCapabilityPermits(citizenid, jobName, capabilityKey)
    if not IsCapabilityActiveInternal(capabilityKey) then return true end
    if type(GetCertificationTier) ~= 'function' then return true end
    if type(citizenid) ~= 'string' or type(jobName) ~= 'string' then return true end

    -- HIGH COMMAND BYPASS (owner-directed, this pass -- "high command
    -- automatically gets every k9 upgrade"). WITHOUT this, a high-command
    -- officer who happens to hold a REAL, active, job-matching certification
    -- row whose TIER simply does not carry `capabilityKey` would be DENIED
    -- here -- this function's own comment above already documents that a
    -- citizenid with NO certification row at all is treated as
    -- unresolvable-and-allowed, so before this fix an UNCERTIFIED
    -- high-command officer passed by accident (via that unresolvable path)
    -- while a CERTIFIED one, at the wrong tier, did not -- an inconsistency
    -- that had nothing to do with rank and everything to do with whether
    -- they happened to hold a cert row, which is exactly backwards for a
    -- rank this resource elsewhere treats as "super op" (server/
    -- highcommand.lua's own header). `type(...) == 'function'` soft
    -- dependency guard, this resource's established convention -- this
    -- function still works exactly as before if server/permissions.lua is
    -- ever removed or Config.Features.HighCommand is off
    -- (IsHighCommandBypassCitizenId's own IsHighCommand call re-checks that
    -- flag on every invocation, no restart needed). `jobName` is passed
    -- through as `expectedJobName` so a citizenid who is high command of
    -- SOME department cannot use a DIFFERENT department's `jobName` string
    -- to borrow that status here -- IsHighCommand itself already requires
    -- the officer's own LIVE job to satisfy this, but this call is scoped
    -- to the specific job this capability check is FOR, never the officer's
    -- job in general. OFFLINE `citizenid` -> IsHighCommandBypassCitizenId
    -- returns false -> falls through to the real, unchanged resolution
    -- below, exactly as before this pass -- see that function's own doc
    -- comment for why this is safe (never a source of over-grant).
    -- NEVER GATES A NEW CALL SITE: this function's only real, request-time
    -- consumers (server/combat.lua's ValidateCombatRequest,
    -- server/certifications/'s GrantSpecialization) are UNCHANGED by
    -- this edit -- it only widens what THIS function itself returns for an
    -- already-existing call, never adds a new one, and neither consumer is
    -- reachable from a termination/cleanup path (see this file's own header
    -- "NO UNBOUNDED TRAP" and combat.lua's own "REQUEST-TIME ONLY" comment
    -- on ValidateCombatRequest).
    if type(IsHighCommandBypassCitizenId) == 'function' and IsHighCommandBypassCitizenId(citizenid, jobName) then
        return true
    end

    -- `includeExpired = true` (SECURITY FIX, coder-security,
    -- tier-bypass-on-expiry review): the ordinary 2-argument
    -- GetCertificationTier(citizenid, jobName) folds an EXPIRED
    -- certification into "no tier", which is correct for every OTHER
    -- consumer but WRONG here -- it let a capability an operator explicitly
    -- withheld from a tier silently unlock the moment that handler's
    -- certification lapsed, for as long as they kept K9 access through a
    -- 'k9.access' permission grant, an autoAccessGrade job grade, or high
    -- command (HasK9Access's other three routes). Passing `true` here
    -- resolves a STALE (expired) tier assignment for real, while still
    -- returning nil for a citizenid with NO certification row at all for
    -- this job (never certified, or manually revoked) -- exactly the
    -- population that remains genuinely unresolvable and must stay
    -- allowed. See GetCertificationTier's own doc comment for the full
    -- "why the data can tell these two apart" writeup (the underlying
    -- cache's `active` and `expired` flags are independent, so "stale" is
    -- not the same bit as "absent").
    local tierKey = GetCertificationTier(citizenid, jobName, true)
    if not tierKey then return true end

    return TierHasCapability(tierKey, capabilityKey)
end

-- ======================================================================
-- AUTHORIZATION -- re-verified on EVERY call, never cached. See header
-- "HAZARD 4".
-- ======================================================================

--- @param source number
--- @return string? citizenid
local function ResolveCitizenId(source)
    local Player = exports.qbx_core:GetPlayer(source)
    local citizenid = Player and Player.PlayerData and Player.PlayerData.citizenid
    if type(citizenid) == 'string' and citizenid ~= '' then return citizenid end
    return nil
end

--- SELF-SERVICE VISIBILITY (coder-security economy pass, same lens
--- server/xptiers.lua's own "THE ALREADY-PROMOTED PLAYER" section applies to
--- its own surface): used ONLY by certTiersUpsert below, to answer "is the
--- tier this edit is touching the SAME tier the acting officer currently
--- holds for their own job". Not an authorization check and never blocks
--- anything -- HAZARD 4 already establishes structurally that no capability
--- in CAPABILITY_CATALOG can grant a permission or become high command, so
--- this is not a privilege-escalation gate. It exists so a high-command
--- account cannot grant (or revoke) a capability on their OWN currently-held
--- tier -- narrowing an ability to "only my tier" is exactly as available to
--- a legitimate operator tuning an unrelated tier, but doing it to your OWN
--- tier is the one shape worth naming explicitly in the log, the same way
--- xptiers.lua now names a self-promotion rather than folding it into a
--- generic "threshold changed" line.
--- @param source number
--- @return string? jobName
local function ResolveJobName(source)
    local Player = exports.qbx_core:GetPlayer(source)
    local jobName = Player and Player.PlayerData and Player.PlayerData.job and Player.PlayerData.job.name
    if type(jobName) == 'string' and jobName ~= '' then return jobName end
    return nil
end

--- Server-authoritative, re-resolved fresh on every call -- never cached,
--- never trusts a client-supplied flag. Deliberately IsHighCommand ONLY
--- -- no HasPermission-based delegation, unlike
--- server/runtimecontrol.lua's CanManageRuntimeControl/CanManageTabletTheme
--- (which also accept a granted 'k9.runtimecontrol'/'k9.tablettheme'
--- permission). This is a deliberate, disclosed scope decision: the
--- owner's own words for THIS feature name "high command" specifically, a
--- plain rank check, and adding a new delegable Config.Permissions key
--- would need config.lua owner sign-off this pass did not request. A
--- follow-up pass can widen this to also accept a 'k9.certtiers' grant
--- the same way runtime control does, if the team wants that -- tracked
--- here, not silently done.
--- @param source number
--- @return boolean authorized, string? citizenid
local function CanManageCertTiers(source)
    local citizenid = ResolveCitizenId(source)
    if type(IsHighCommand) == 'function' and IsHighCommand(source) then
        return true, citizenid
    end
    return false, citizenid
end

-- Cross-file critical-section lock, keyed by tier_key -- NOT a player
-- source, so deliberately no :RegisterPlayerDropped() call (same
-- reasoning server/cooldowns.lua's own header gives for MedkitMutex/
-- PartnershipEstablishMutex, both keyed by something other than a player
-- source). Exposed as a bare global (no `local`) specifically so
-- server/certifications/'s SetCertificationTier can acquire the SAME
-- lock before writing a tier assignment -- see header "HAZARD 4", "THE
-- DELETE-VS-ASSIGN RACE" for exactly which race this closes.
TierEditMutex = NewMutex()

-- Anti-fat-finger/double-submit rate limit, keyed by the ACTING officer's
-- own source -- mirrors server/runtimecontrol.lua's
-- RuntimeControlActionCooldown exactly. Every caller reaching this point
-- is already confirmed high command by CanManageCertTiers above; this
-- guards against a held key or a double-submitted click, not abuse.
local CERT_TIER_ACTION_COOLDOWN_MS = 1000
local CertTierActionCooldown = NewCooldown(CERT_TIER_ACTION_COOLDOWN_MS)
CertTierActionCooldown.RegisterPlayerDropped()

--- @param action string
--- @param tierKey string
--- @param detail string
--- @param changedBy string
local function WriteTierAudit(action, tierKey, detail, changedBy)
    -- AUDIT-SWALLOW FIX (this pass): TierAudit_Append's own boolean return
    -- used to be discarded here -- every call site above already checked
    -- its OWN primary write before ever reaching this helper, so the
    -- action genuinely happened and this file's own `ok = true` responses
    -- remain correct either way -- but a failed audit-trail insert must
    -- not vanish without a trace tying it to this specific action/key.
    -- Mirrors server/runtimecontrol.lua's own identical
    -- "AUDIT-SWALLOW FIX (this pass)" comment/shape exactly.
    if not K9Store.TierAudit_Append(action, tierKey, detail, changedBy or 'unknown') then
        print(('[qbx_k9unit] certtiers.lua: audit-trail write failed for action=%s tierKey=%s (the action itself still succeeded and was persisted).'):format(tostring(action), tostring(tierKey)))
    end
end

-- ======================================================================
-- VALIDATION -- every field a tablet payload can influence is validated
-- server-side before it ever reaches a query, matching this resource's
-- established "treat every inbound payload as adversarial" posture.
-- ======================================================================

--- 2-30 chars, lowercase-start, lowercase/digit/underscore only --
--- comfortably inside k9_certification_tiers.tier_key's VARCHAR(32) and
--- k9_certifications.tier's VARCHAR(20) (migration 0006) alike, so a
--- valid new key can always actually be written to BOTH tables. Lua
--- patterns have no `{n,m}` quantifier -- length is checked separately,
--- not via the pattern itself.
--- @param key any
--- @return boolean
local function IsValidTierKey(key)
    if type(key) ~= 'string' then return false end
    local len = #key
    if len < 2 or len > 20 then return false end
    return key:match('^[a-z][a-z0-9_]*$') ~= nil
end

--- Character filter mirroring server/runtimecontrol.lua's own
--- IsSafeHeaderTitle -- defense in depth on top of the tablet's own
--- textContent-only rendering discipline, not a substitute for it. <=60
--- chars (matches k9_certification_tiers.label's own VARCHAR(60)).
--- @param value any
--- @return boolean
local function IsValidTierLabel(value)
    if type(value) ~= 'string' then return false end
    local len = #value
    if len == 0 or len > 60 then return false end
    if value:find('[<>&"\'`\r\n\t]') then return false end
    for i = 1, len do
        local byte = value:byte(i)
        if byte < 0x20 or byte == 0x7F then return false end
    end
    return true
end

--- Accepts an ARRAY of capability-key strings (the shape a tablet
--- checkbox list naturally serializes to) or nil (-> no capabilities).
--- Rejects the WHOLE input on ANY unrecognized capability key or wrong
--- shape, rather than silently dropping the bad entries -- a
--- partially-applied edit the caller might misread as fully applied is
--- worse than an outright, explicit refusal. See header "HAZARD 4" for
--- why CAPABILITY_CATALOG is the only vocabulary this can ever produce
--- membership in.
--- @param input any
--- @return boolean ok, table<string, true>? set
local function NormalizeCapabilitiesInput(input)
    if input == nil then return true, {} end
    if type(input) ~= 'table' or #input > 32 then return false, nil end
    local set = {}
    for _, capKey in ipairs(input) do
        if type(capKey) ~= 'string' or not CAPABILITY_CATALOG[capKey] then
            return false, nil
        end
        set[capKey] = true
    end
    return true, set
end

--- @return table<string, table> -- { [capabilityKey] = { label = string } }
local function PublicCapabilityCatalog()
    local copy = {}
    for key, def in pairs(CAPABILITY_CATALOG) do
        copy[key] = { label = def.label }
    end
    return copy
end

-- ======================================================================
-- CALLBACKS -- all four re-verify CanManageCertTiers(source) as their own
-- first action (see header "HAZARD 4"). Response shape mirrors
-- server/runtimecontrol.lua's own `{ ok, reason, ... }` convention
-- exactly, for consistency across this resource's tablet-facing surfaces.
-- ======================================================================

lib.callback.register('qbx_k9unit:server:certTiersList', function(source)
    local authorized = CanManageCertTiers(source)
    if not authorized then return { ok = false, reason = 'denied' } end
    return { ok = true, tiers = ListCertificationTiers(), capabilityCatalog = PublicCapabilityCatalog() }
end)

lib.callback.register('qbx_k9unit:server:certTiersUpsert', function(source, payload)
    local authorized, citizenid = CanManageCertTiers(source)
    if not authorized then return { ok = false, reason = 'denied' } end

    if not CertTierActionCooldown.Consume(source, CERT_TIER_ACTION_COOLDOWN_MS) then
        return { ok = false, reason = 'rate_limited' }
    end

    if type(payload) ~= 'table' or type(payload.key) ~= 'string' then
        return { ok = false, reason = 'invalid_payload' }
    end

    local key = payload.key
    if not IsValidTierKey(key) then
        return { ok = false, reason = 'invalid_key' }
    end
    if not IsValidTierLabel(payload.label) then
        return { ok = false, reason = 'invalid_label' }
    end

    local capsOk, capsSet = NormalizeCapabilitiesInput(payload.capabilities)
    if not capsOk then
        return { ok = false, reason = 'invalid_capabilities' }
    end

    if not TierEditMutex.TryAcquire(key) then
        return { ok = false, reason = 'busy' }
    end

    -- `existing` is nil both for a genuinely brand-new key AND for one
    -- currently tombstoned (TierByKey excludes tombstoned keys entirely)
    -- -- `priorRow` below (a direct DB read, ignoring the tombstone
    -- filter) is what actually distinguishes "create" from "restore" for
    -- the audit trail.
    local existing = TierByKey[key]
    local isNewOrRestoring = existing == nil

    if isNewOrRestoring then
        local liveCount = 0
        for _ in pairs(TierByKey) do liveCount = liveCount + 1 end
        if liveCount >= MAX_TIERS then
            TierEditMutex.Release(key)
            return { ok = false, reason = 'too_many_tiers' }
        end
    end

    local ordinal
    if isNewOrRestoring then
        -- Append at the end -- both for a genuinely new key and for one
        -- being restored from a tombstone (a restore does not attempt to
        -- reclaim its old position -- see header "WHY A TOMBSTONE" in
        -- migration 0010).
        local maxOrdinal = 0
        for _, entry in pairs(TierByKey) do
            if entry.ordinal > maxOrdinal then maxOrdinal = entry.ordinal end
        end
        ordinal = maxOrdinal + 1
    else
        -- Editing an already-live tier: ordinal is untouched here. The
        -- ONLY way to change an existing tier's ordinal is ReorderTiers
        -- below -- see header "HAZARD 3".
        ordinal = existing.ordinal
    end

    local priorRow = K9Store.Tier_GetDeletedFlagByKey(key)[1]

    local wrote = K9Store.Tier_Upsert(key, payload.label, ordinal, citizenid or 'unknown')
    if not wrote then
        TierEditMutex.Release(key)
        return { ok = false, reason = 'db_error' }
    end

    -- Reconcile capability grants to EXACTLY the requested set. Safe to
    -- read the DB fresh here (rather than trust the in-memory cache):
    -- TierEditMutex is held for this key for this entire critical
    -- section, so nothing else touching THIS key's capability rows can
    -- have interleaved since this callback started.
    local currentCapRows = K9Store.TierCap_GetForTier(key)
    local currentCapSet = {}
    for _, row in ipairs(currentCapRows) do currentCapSet[row.capability_key] = true end

    -- `added`/`removed` record ONLY what actually landed (the write's own
    -- `ok` return checked, per the SafeWrite contract -- TierCap_Insert/
    -- TierCap_Delete degrade a thrown DB error to `false` rather than
    -- propagating, so a mid-loop DB blip must not be allowed to silently
    -- fall through as if every requested change applied).
    -- `failedAdds`/`failedRemoves` record the requested changes that did
    -- NOT land, so the caller is told exactly what failed rather than
    -- receiving a bare `ok = true` for a partially-applied edit.
    local added, removed, failedAdds, failedRemoves = {}, {}, {}, {}
    for capKey in pairs(capsSet) do
        if not currentCapSet[capKey] then
            if K9Store.TierCap_Insert(key, capKey, citizenid or 'unknown') then
                added[#added + 1] = capKey
            else
                failedAdds[#failedAdds + 1] = capKey
            end
        end
    end
    for capKey in pairs(currentCapSet) do
        if not capsSet[capKey] then
            if K9Store.TierCap_Delete(key, capKey) then
                removed[#removed + 1] = capKey
            else
                failedRemoves[#failedRemoves + 1] = capKey
            end
        end
    end

    TierEditMutex.Release(key)

    local action
    if not isNewOrRestoring then
        action = 'tier_update'
    elseif priorRow ~= nil and (priorRow.deleted == 1 or priorRow.deleted == true) then
        action = 'tier_restore'
    else
        action = 'tier_create'
    end

    -- SELF-SERVICE VISIBILITY -- see ResolveJobName's own doc comment.
    -- Evaluated from what actually SUCCEEDED (`added`/`removed`, already
    -- failure-filtered above), not the requested `capsSet` -- a capability
    -- change that failed to write never happened, so it must never be
    -- reported as a self-tier edit either. Soft-guarded (GetCertificationTier
    -- may be absent, citizenid/jobName may not resolve) -- any of those
    -- leaves `selfTierCapabilityChange` false, never an error, matching this
    -- resource's established soft-dependency convention.
    local selfTierCapabilityChange = false
    if (#added > 0 or #removed > 0) and citizenid and type(GetCertificationTier) == 'function' then
        local actingJobName = ResolveJobName(source)
        if actingJobName then
            local actingTierKey = GetCertificationTier(citizenid, actingJobName, true)
            selfTierCapabilityChange = actingTierKey == key
        end
    end

    -- Audit only what actually succeeded -- `added`/`removed` above already
    -- exclude anything that failed, so this line never overstates what
    -- happened, even though `action` (create/restore/update) itself is
    -- independent of the capability reconciliation outcome. The
    -- SELF-TIER CAPABILITY EDIT suffix is appended in the SAME line (never a
    -- separate, easy-to-miss audit row) so "who changed which tier's
    -- capabilities" and "was that their own tier" are always read together.
    local auditDetail = ('label=%q ordinal=%d capabilities_added=[%s] capabilities_removed=[%s]'):format(
        payload.label, ordinal, table.concat(added, ','), table.concat(removed, ','))
    if selfTierCapabilityChange then
        auditDetail = auditDetail .. (' -- SELF-TIER CAPABILITY EDIT: acting officer %s currently holds tier %q themselves -- this change affects their OWN capabilities immediately, not only other holders of this tier'):format(citizenid or 'unknown', key)
    end
    WriteTierAudit(action, key, auditDetail, citizenid or 'unknown')

    -- Refresh from DB truth regardless of outcome -- if any capability
    -- write failed above, this ensures every reader (including this
    -- call's own response below) sees exactly what actually landed, never
    -- the fully-requested-but-not-fully-applied `capsSet`.
    RefreshCertificationTierCatalog()

    -- LOUDER TREATMENT FOR A SELF-TIER EDIT, not merely a bare mutex/status
    -- flag -- surfaced in the actual server response (not merely logged),
    -- same "the tablet is expected to surface this warning prominently"
    -- convention HAZARD 3's own ReorderTiers warning already establishes.
    -- Never a gate/confirmation dialog -- high command can still complete
    -- the edit in one action; this only makes it visible AT THE MOMENT it
    -- is made, matching xptiers.lua's own "louder for a self-serving effect,
    -- not blocked" decision.
    local selfTierWarning
    if selfTierCapabilityChange then
        local grantPart = #added > 0 and (' Granting %s takes effect for YOUR OWN tier immediately, in addition to every other holder of %q.'):format(table.concat(added, ', '), key) or ''
        local revokePart = #removed > 0 and (' Revoking %s from your own tier takes effect immediately as well.'):format(table.concat(removed, ', ')) or ''
        selfTierWarning = ('This edit changes capabilities on tier %q, which you currently hold yourself.%s%s This is logged distinctly in the tier audit trail for review.'):format(key, grantPart, revokePart)
    end

    if #failedAdds > 0 or #failedRemoves > 0 then
        return {
            ok = false,
            reason = 'capability_write_failed',
            failedCapabilities = { added = failedAdds, removed = failedRemoves },
            tiers = ListCertificationTiers(),
            capabilityCatalog = PublicCapabilityCatalog(),
            warning = selfTierWarning,
        }
    end

    return { ok = true, tiers = ListCertificationTiers(), capabilityCatalog = PublicCapabilityCatalog(), warning = selfTierWarning }
end)

lib.callback.register('qbx_k9unit:server:certTiersReorder', function(source, orderedKeys)
    local authorized, citizenid = CanManageCertTiers(source)
    if not authorized then return { ok = false, reason = 'denied' } end

    if not CertTierActionCooldown.Consume(source, CERT_TIER_ACTION_COOLDOWN_MS) then
        return { ok = false, reason = 'rate_limited' }
    end

    if type(orderedKeys) ~= 'table' or #orderedKeys > MAX_TIERS then
        return { ok = false, reason = 'invalid_payload' }
    end

    -- Must be EXACTLY a permutation of every currently-known
    -- (non-tombstoned) tier key -- see header "HAZARD 3": no partial
    -- reorder, ever.
    local currentKeys, expectedCount = {}, 0
    for key in pairs(TierByKey) do
        currentKeys[key] = true
        expectedCount = expectedCount + 1
    end

    local seen, cleanOrder = {}, {}
    for _, key in ipairs(orderedKeys) do
        if type(key) ~= 'string' or not currentKeys[key] or seen[key] then
            return { ok = false, reason = 'invalid_key_set' }
        end
        seen[key] = true
        cleanOrder[#cleanOrder + 1] = key
    end
    if #cleanOrder ~= expectedCount then
        return { ok = false, reason = 'must_include_every_tier' }
    end

    local beforeParts = {}
    for _, key in ipairs(cleanOrder) do
        beforeParts[#beforeParts + 1] = ('%s=%d'):format(key, TierByKey[key].ordinal)
    end

    -- `writeFailedKeys` collects only a genuine post-acquire DB write
    -- failure (SafeWrite contract: Tier_UpdateOrdinal degrades a thrown DB
    -- error to `false` rather than propagating) -- NOT a busy-skip, which
    -- remains the pre-existing, already-disclosed, benign contention
    -- outcome (logged, ordinal left unchanged, overall response still
    -- `ok = true`) and is deliberately left untouched below. A write
    -- failure is a different, more serious class -- an actual DB error,
    -- not ordinary lock contention -- so it alone escalates the response.
    local afterParts, writeFailedKeys = {}, {}
    for index, key in ipairs(cleanOrder) do
        -- Per-key mutex, held only for THIS key's own write (not across
        -- the whole loop, to avoid serializing an entire reorder behind
        -- one held lock) -- see header "CONCURRENT-ADD ORDINAL TIE" /
        -- "THE DELETE-VS-ASSIGN RACE" for why this narrows (without fully
        -- eliminating) a concurrent single-tier edit racing this
        -- specific key's ordinal write. A busy key is skipped THIS pass
        -- (its ordinal is left unchanged) rather than blocking the rest
        -- of the reorder.
        if TierEditMutex.TryAcquire(key) then
            -- K9Store.Tier_UpdateOrdinal, NOT K9Store.Tier_Upsert -- see
            -- that accessor's own doc comment (server/datastore.lua) for
            -- exactly why this write must never touch `label`, even though
            -- TierByKey[key].label is passed through (used only if this
            -- key has no row in k9_certification_tiers yet at all).
            local wrote = K9Store.Tier_UpdateOrdinal(key, TierByKey[key].label, index, citizenid or 'unknown')
            TierEditMutex.Release(key)
            if wrote then
                afterParts[#afterParts + 1] = ('%s=%d'):format(key, index)
            else
                -- Acquired the lock but the write itself failed (SafeWrite
                -- contract: a thrown DB error degrades to `false`). Log it,
                -- and record the REAL unchanged ordinal (never the intended
                -- `index`), since the write never actually landed.
                writeFailedKeys[#writeFailedKeys + 1] = key
                print(('[qbx_k9unit] certtiers ReorderTiers: tier %s ordinal write failed (db_error) -- its ordinal was left unchanged this pass'):format(key))
                afterParts[#afterParts + 1] = ('%s=%d'):format(key, TierByKey[key].ordinal)
            end
        else
            -- busy-key skip: this branch IS correctly handled, left
            -- unchanged -- see header comment above.
            print(('[qbx_k9unit] certtiers ReorderTiers: tier %s busy (concurrent edit) -- its ordinal was left unchanged this pass'):format(key))
            afterParts[#afterParts + 1] = ('%s=%d'):format(key, index)
        end
    end

    WriteTierAudit('tier_reorder', 'ALL',
        ('before=[%s] after=[%s]'):format(table.concat(beforeParts, ', '), table.concat(afterParts, ', ')),
        citizenid or 'unknown')

    RefreshCertificationTierCatalog()

    local warningText = 'Reordering tiers changes rank comparisons RETROACTIVELY: every citizenid already holding one ' ..
        'of these tiers is now ranked at its NEW position immediately. Tier-based checks read the current ' ..
        'catalog live -- they do not pin to the ordinal that was in effect when a certification was granted.'

    if #writeFailedKeys > 0 then
        return {
            ok = false,
            reason = 'ordinal_write_failed',
            failedKeys = writeFailedKeys,
            tiers = ListCertificationTiers(),
            warning = warningText,
        }
    end

    return {
        ok = true,
        tiers = ListCertificationTiers(),
        warning = warningText,
    }
end)

lib.callback.register('qbx_k9unit:server:certTiersDelete', function(source, key)
    local authorized, citizenid = CanManageCertTiers(source)
    if not authorized then return { ok = false, reason = 'denied' } end

    if not CertTierActionCooldown.Consume(source, CERT_TIER_ACTION_COOLDOWN_MS) then
        return { ok = false, reason = 'rate_limited' }
    end

    if type(key) ~= 'string' or not IsKnownCertificationTierKey(key) then
        return { ok = false, reason = 'unknown_tier' }
    end

    -- UNCONDITIONAL, checked BEFORE the reference-count read -- see header
    -- "HAZARD 2" for why 'certified' cannot rely on reference-count
    -- protection alone.
    if PROTECTED_TIER_KEYS[key] then
        return { ok = false, reason = 'protected_tier' }
    end

    if not TierEditMutex.TryAcquire(key) then
        return { ok = false, reason = 'busy' }
    end

    local countOk, refCountOrErr = pcall(K9Store.Cert_CountByTier, key)
    if not countOk then
        TierEditMutex.Release(key)
        print(('[qbx_k9unit] certtiers DeleteTier reference-count read failed for %s: %s'):format(key, tostring(refCountOrErr)))
        return { ok = false, reason = 'db_error' }
    end

    local refCount = tonumber(refCountOrErr) or 0
    if refCount > 0 then
        TierEditMutex.Release(key)
        return { ok = false, reason = 'tier_in_use', referenceCount = refCount }
    end

    -- THE SECOND REFERRER, which nothing counted until this pass.
    --
    -- Certifications are not the only thing that points at a tier. A supply
    -- shop item can require one before anybody may buy it. Deleting a tier
    -- an item requires does not fail loudly -- it makes that item unbuyable
    -- for every player on the server, forever, and the refusal they get
    -- names a tier that no longer exists and can never be granted to
    -- anyone. Nothing told the officer doing the deleting, and nothing in
    -- the shop explained why it had quietly stopped selling something.
    --
    -- Deliberately a SEPARATE refusal reason from 'tier_in_use' rather than
    -- folding the two counts together: "3 certification records still use
    -- this" and "2 shop items still require this" need completely different
    -- actions from the person reading it, and one number covering both
    -- would send them to the wrong screen.
    --
    -- Guarded call: server/equipmentshop.lua loads AFTER this file
    -- (fxmanifest.lua), so this global does not exist while this file is
    -- being read -- only by the time a tablet callback can actually run.
    -- If it is genuinely absent (that file removed, or failed to load),
    -- this check is skipped rather than erroring: the same posture every
    -- other cross-file global call site in this resource takes.
    if type(CountEquipmentShopItemsRequiringTier) == 'function' then
        local shopOk, shopCount, shopItemKeys = pcall(CountEquipmentShopItemsRequiringTier, key)
        if shopOk and type(shopCount) == 'number' and shopCount > 0 then
            TierEditMutex.Release(key)
            print(('[qbx_k9unit] certtiers: REFUSED to delete tier %s -- %d supply shop item(s) still require it: %s. Change or clear those items\' tier requirement from the tablet first, then delete the tier.')
                :format(key, shopCount, table.concat(type(shopItemKeys) == 'table' and shopItemKeys or {}, ', ')))
            return {
                ok = false,
                reason = 'tier_in_use_by_shop_items',
                referenceCount = shopCount,
                shopItemKeys = type(shopItemKeys) == 'table' and shopItemKeys or {},
            }
        end
    end

    local entry = TierByKey[key]
    local wrote = K9Store.Tier_Tombstone(key, entry.label, entry.ordinal, citizenid or 'unknown')
    TierEditMutex.Release(key)

    if not wrote then
        return { ok = false, reason = 'db_error' }
    end

    WriteTierAudit('tier_delete', key,
        ('tier %s deleted (tombstoned) -- confirmed zero k9_certifications rows AND zero supply shop items referenced it at the moment of deletion'):format(key),
        citizenid or 'unknown')

    RefreshCertificationTierCatalog()

    return { ok = true, tiers = ListCertificationTiers() }
end)

-- ======================================================================
-- BOOT -- layer the persisted DB overrides on top of config.lua's own
-- shipped defaults. Deferred to onResourceStart (not raw top-level --
-- MySQL/oxmysql readiness is not guaranteed at raw server_scripts
-- load-time), mirroring server/runtimecontrol.lua's own identical
-- "config-only defaults at file-load, DB layered on top at
-- onResourceStart" pattern exactly.
--
-- SECURITY FIX (coder-security, authority-layer sweep, this pass) --
-- WAITS FOR THE SCHEMA-COLLISION PROBE TO SETTLE FIRST, the identical
-- boot-order fix server/permissionkeycatalog.lua and server/xptiers.lua
-- already carry for their own sibling catalogs (see either file's own
-- header "WAITS FOR THE SCHEMA-COLLISION PROBE TO SETTLE FIRST" /
-- "boot-order fix" section for the full writeup -- not repeated here).
-- This file's own two tables, k9_certification_tiers and
-- k9_certification_tier_capabilities, are BOTH listed in
-- server/datastore.lua's own EXPECTED_TABLE_COLUMNS (the schema-collision
-- probe's checked set) -- this file was simply missed when that fix
-- landed for its two siblings. server/datastore.lua loads before this
-- file and registers its own onResourceStart handler first, but that
-- handler's own MySQL.query.await yields, and FXServer's event dispatch
-- does not wait for a yielding handler before moving on to THIS one while
-- the probe is still in flight. Without this wait, K9Store.Tier_GetAllRows()
-- below would run its own narrower SELECT (`tier_key, label, ordinal,
-- deleted` -- 4 of the 7 columns the probe checks, omitting created_at/
-- updated_by/updated_at) against whatever `k9_certification_tiers`
-- currently is, before the probe has had a chance to say whether that
-- table is even really ours -- a foreign table the full probe would
-- correctly reject could still satisfy this narrower one during that
-- window, merging a stranger's rows straight into the LIVE tier catalog,
-- including its `capabilities` set (this pass's own TierCapabilityPermits
-- gates real mechanics -- specializations_eligible/bite_hold_and_takedown
-- -- so a collision here is not merely a display glitch). On a `false`
-- return (the probe genuinely had not settled within the wait budget --
-- database unreachable/slow, or off by config, which settles instantly
-- instead of waiting at all), this file boots to config-only defaults for
-- this session, exactly like `Config.Database.enabled == false` --
-- TierByKey/TierOrder already hold those defaults from this file's own
-- synchronous file-load-time population above, so simply skipping the
-- refresh here is sufficient, not a separate fallback path to maintain.
-- The next successful certTiersUpsert/Reorder/Delete call (or a resource
-- restart, by which point the probe will certainly have settled) re-reads
-- the real state as normal.
-- ======================================================================
AddEventHandler('onResourceStart', function(resourceName)
    if GetCurrentResourceName() ~= resourceName then return end
    if not K9Store.WaitForSchemaCheckToSettle() then
        print('[qbx_k9unit] certtiers: the schema-collision check had not finished within its wait budget -- booting this session\'s certification-tier catalog with config.lua defaults ONLY (no database read attempted, exactly like Config.Database.enabled = false) rather than trust a database state that is not yet confirmed safe. The next successful tier edit (or a restart once the check has had time to finish) will pick up any real persisted state.')
        return
    end
    RefreshCertificationTierCatalog()
end)
