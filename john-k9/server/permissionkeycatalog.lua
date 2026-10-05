--[[
    john-k9/server/permissionkeycatalog.lua

    OWNER-DIRECTED EXTENSION of a design pattern already shipped in this
    codebase. Owner's own words, verbatim, for THIS pass: "have high
    command add more certification roles and change the permissions for
    them or remove certification roles or even add or remove permissions."

    server/certtiers.lua already answers the FIRST half of that sentence
    (certification ROLES/TIERS -- trainee/certified/senior, plus anything
    added since). THIS FILE answers the SECOND half: the PERMISSION KEYS
    themselves -- 'k9.access', 'k9.certify', 'k9.audit', 'k9.givexp', and
    anything a high-command officer adds from now on. Read server/
    certtiers.lua's own header FIRST -- it is this file's blueprint, and
    this header only explains where and why this file deliberately departs
    from it, not the parts it copies unchanged.

    ======================================================================
    WHAT THIS FILE OWNS
    ======================================================================

    THE PERMISSION-KEY CATALOG: a map of `permissionKey -> { label,
    description? }`, merged from two sources every time it is (re)built --
    Config.Permissions (the DEFAULTS; owned by whoever owns config.lua) and
    the `k9_permission_keys` database table (the operator's RUNTIME EDITS,
    made from the K9 Command Tablet, alongside the certification-tier
    editor server/certtiers.lua already put there). THE DATABASE WINS -- a
    DB row for a given `permission_key` completely overrides that key's
    config-supplied label/description; a DB `deleted = 1` row (a
    TOMBSTONE, not a real row DELETE -- see migration 0013's own header)
    excludes that key from the live catalog entirely, whether it
    originated in Config.Permissions or was itself created entirely at
    runtime. See RefreshPermissionKeyCatalog below for the exact merge
    algorithm -- byte-for-byte the same shape as
    server/certtiers.lua's own RefreshCertificationTierCatalog, minus that
    function's ordinal/capability bookkeeping (see "WHY NO ORDINAL, NO
    CAPABILITIES TABLE" below for why this file has neither).

    THE SEAM THIS FILE EXTENDS: server/permissions.lua's own
    IsValidPermissionKey and PermissionLabelFor (both `local`) now defer to
    this file's live catalog -- IsKnownPermissionCatalogKey and
    GetPermissionCatalogLabel below -- behind the SAME `type(...) ==
    'function'` soft-dependency guard every other cross-file dependency in
    this resource uses, so server/permissions.lua keeps working, unchanged,
    against Config.Permissions alone if this file is ever removed. THIS IS
    THE ONLY EDIT THIS PASS MAKES TO server/permissions.lua's OWN LOGIC --
    everything else in that file (HasPermission's own resolution order,
    GrantPermission/RevokePermission's own authorization/cooldown/audit/
    notification behavior) is unchanged, PLUS the one addition documented
    in "THE DELETE-VS-GRANT RACE" below (GrantPermission now also acquires
    this file's own PermissionKeyEditMutex around its own write, mirroring
    exactly what server/certtiers.lua's header already documents for
    SetCertificationTier and TierEditMutex).

    ======================================================================
    NAMESPACE PROTECTION -- block.<Feature> / feature.<Feature> ARE NOT
    PART OF THIS CATALOG, EVER
    ======================================================================

    config.lua's Config.FeatureControl documents a SECOND, entirely
    separate namespace living in the SAME k9_permissions.permission column:
    `feature.<Name>` (a per-person grant) and `block.<Name>` (a per-person
    block), where `<Name>` is a REAL key of Config.Features. That namespace
    is load-bearing for server/pursuitsprint.lua's own documented 4-step
    per-person feature resolution, and server/permissions.lua's own
    IsValidPermissionKey already validates it by checking `<Name>` against
    Config.Features directly -- NOT against any catalog, this file's or
    otherwise.

    THIS FILE NEVER TOUCHES THAT NAMESPACE, IN EITHER DIRECTION, BY
    CONSTRUCTION:
      - IsValidPermissionCatalogKey below (the shape/format gate every
        UpsertKey call passes through) UNCONDITIONALLY REJECTS any key
        that is exactly 'feature', exactly 'block', or starts with
        'feature.'/'block.' -- see IsReservedNamespaceKey. A high-command
        officer can never create, rename, or restore a catalog entry that
        shadows or collides with that namespace.
      - server/permissions.lua's own IsValidPermissionKey (the ACTUAL
        authorization gate HasPermission/GrantPermission/RevokePermission
        all call) checks the `feature.`/`block.` pattern FIRST, before ever
        consulting this file's catalog at all -- see that file's own
        updated doc comment. Even if this file's own reservation above were
        somehow bypassed (it cannot be, from this surface), the namespace
        check upstream of it would still resolve independently and
        correctly.
      - This file's own PermKeyByKey table is NEVER populated from
        Config.FeatureControl and never reads it. The two namespaces are
        kept structurally disjoint, not merely disjoint by convention.
    Net effect: an operator with tablet access to THIS screen cannot
    delete, rename, or shadow a `block.<Feature>`/`feature.<Feature>` key
    no matter what string they type into the "add a permission key" form --
    the request is refused outright, before any write, with a distinct
    `reserved_namespace` outcome the tablet can explain plainly.

    ======================================================================
    RESERVED INTERNAL CAPABILITY KEYS -- CLOSES A CONFIRMED PRIVILEGE
    ESCALATION (red-team pass, this task). See IsReservedInternalCapabilityKey
    below for the exact list and the "how to re-derive it" audit command.
    ======================================================================

    Several files elsewhere in this resource each ship their OWN
    `HasPermission(citizenid, '<literal>')` escape hatch, believed safe
    ONLY because that exact literal string is not (yet) a key of
    Config.Permissions -- server/runtimecontrol.lua's own header says so in
    those words: "the permission-grant escape hatch activat[es]
    automatically ... the moment those two keys are added" (its two keys:
    'k9.runtimecontrol', 'k9.tablettheme', gating CanManageRuntimeControl/
    CanManageTabletTheme). server/equipmentshop.lua ships the identical
    pattern for 'k9.equipmentshoplocations'/'k9.equipmentshopitems'
    (CanManageShopLocations/CanManageShopItems). Every one of those four
    literals is, by shape alone, an ordinary 'k9.<word>' string --
    IsValidPermissionCatalogKey below cannot, and must not try to, tell one
    of them apart from a legitimate brand-new custom key an operator might
    want (the four REAL Config.Permissions defaults -- k9.access/k9.certify/
    k9.audit/k9.givexp -- share the exact same shape), so the shape
    validator alone was never going to catch this.

    THE CHAIN THIS CLOSES, TRACED END TO END: before this section existed,
    permKeysUpsert let ANY high-command officer manufacture
    'k9.runtimecontrol' (or any of the other three) as a brand-new catalog
    key at RUNTIME -- no restart, no config.lua edit, nothing
    IsReservedNamespaceKey's feature./block. check above was ever built to
    catch. server/permissions.lua's GrantPermission then had no reason to
    refuse handing that freshly-manufactured key to ANY citizenid at all --
    GrantPermission requires only the GRANTER to be high command, never the
    recipient (a grant targets a citizenid, not a rank). The result: an
    already-verified high-command officer could permanently deputize an
    ORDINARY PLAYER with server/runtimecontrol.lua's full feature/tunable-
    toggle authority (or server/equipmentshop.lua's shop-management
    authority) -- a capability manufactured out of thin air that no
    config.lua edit ever sanctioned.

    THIS IS NOT the same decision as "high command may grant anything to
    themselves" (config.lua's Config.FeatureControl.allowHighCommandSelfGrant,
    server/permissions.lua's own SELF-GRANT section): that governs what an
    ALREADY-VERIFIED officer may hold for themselves. This bug let high
    command manufacture a NEW kind of authority and hand it to someone who
    is not high command at all -- an escalation nobody asked for, and
    distinct from anything the self-grant switch controls (self-grant does
    not even apply here: the target citizenid need not be the granter's
    own).

    FIXED HERE, not in either consuming file (this catalog is the ONLY
    place a brand-new key can be manufactured at all -- see "THE SEAM THIS
    FILE EXTENDS" above): IsReservedInternalCapabilityKey refuses to create
    (or rename/restore) any of the four known literals through
    permKeysUpsert, unconditionally -- the same absolute "cannot create,
    rename, or shadow" treatment IsReservedNamespaceKey already gives
    feature./block. NEVER blocks the deliberate, config-owner-driven
    activation path: BuildPermissionCatalogFromConfigDefaults still ingests
    any of these four literals unconditionally the moment a human adds it
    to Config.Permissions in config.lua and restarts -- exactly the "the
    moment those two keys are added" activation server/runtimecontrol.lua's
    own header already documents as intended and owner-authorized. Nor does
    it touch permKeysDelete: tombstoning a key that could never have been
    created through this surface in the first place is already an inert
    no-op via the ordinary `unknown_key` path.

    A MANUALLY-MAINTAINED LIST, NOT A SELF-REGISTERING MECHANISM, DISCLOSED
    PLAINLY: this file does not own, and must not edit,
    server/runtimecontrol.lua or server/equipmentshop.lua, so neither can
    be made to call back into this file and register its own literal. A
    FIFTH file shipping a fifth such hardcoded-but-unwired
    `HasPermission(citizenid, 'k9.<word>')` gate in the future REOPENS this
    exact hole for that one new literal unless it is also added to
    IsReservedInternalCapabilityKey's own table -- see that function's own
    doc comment for the audit command that re-derives the full, current
    list directly from source whenever this needs rechecking.

    ======================================================================
    WHY NO ORDINAL, NO CAPABILITIES TABLE (a deliberate, disclosed
    departure from server/certtiers.lua's own shape)
    ======================================================================

    server/certtiers.lua's catalog needs an ORDINAL (tiers are RANKED --
    MeetsTierRequirement/GetCertificationTierOrdinal compare two tiers) and
    a CAPABILITIES sibling table (one tier can carry several toggleable
    capabilities). A permission key has neither property: HasPermission(
    citizenid, permissionKey) is a flat membership test with no notion of
    "greater than" between two keys, and a permission key does not itself
    carry a further sub-list of capabilities -- the key IS the capability.
    Adding either concept here would model a relationship that does not
    exist in server/permissions.lua's own resolution order, for no benefit.
    This is a considered omission, not an oversight: if a future pass ever
    needs to RANK permission keys against each other, that is a new,
    separate design question, not an extension of this file.

    ======================================================================
    TOMBSTONE, NOT REFERENCE-COUNTED (a deliberate, disclosed departure
    from server/certtiers.lua's own DeleteTier)
    ======================================================================

    server/certtiers.lua's DeleteTier REFUSES to tombstone a tier while ANY
    k9_certifications row still references it, because `k9_certifications
    .tier` is a `NOT NULL DEFAULT 'certified'` column with no "no tier"
    state a rewritten reference could safely fall back to -- refusing is
    the only option that does not corrupt an append-only audit trail (see
    that file's own header "HAZARD 2" for the full writeup).

    A PERMISSION KEY HAS NO SUCH SCHEMA-LEVEL HAZARD, so this file's own
    DeleteKey (the `john-k9:server:permKeysDelete` callback below)
    NEVER refuses on reference count -- it tombstones unconditionally,
    provided the key is known and not reserved-namespace. Here is the exact
    reasoning this departure rests on, stated once:

      HasPermission(citizenid, permissionKey) -- server/permissions.lua's
      OWN authorization root, the ONLY function every other gate in this
      resource actually calls -- validates `permissionKey` against
      IsValidPermissionKey on EVERY SINGLE CALL, not merely at grant time.
      IsValidPermissionKey (this file's seam into that function) resolves
      "is this key currently live" against THIS FILE's merged catalog. The
      instant a key is tombstoned, IsValidPermissionKey starts returning
      false for it, which makes HasPermission return false for EVERY
      existing k9_permissions row naming that key, ACTIVE OR NOT, with no
      further action needed and no row anywhere left in an "invalid" state
      -- a tombstoned key's grant rows simply become permanently inert,
      exactly as `k9_certification_tier_capabilities` rows for a
      tombstoned TIER already become inert dead weight in the sibling
      system (migration 0010's own header, "not cleaned up ... simply
      become unreachable"). There is no column anywhere that must keep
      holding a "valid" value the way `k9_certifications.tier` must --
      k9_permissions.permission is a free-form VARCHAR with no DEFAULT and
      no downstream comparison operator, so "this string no longer names a
      recognized capability" is a perfectly safe, predictable, PERMANENT
      state for a row to sit in, exactly the way an ordinary revoked grant
      already does.

      "Grants referencing a retired key must resolve predictably" (this
      task's own explicit requirement) is therefore satisfied structurally,
      not by a reference-count refusal: every such grant resolves to
      "denied", deterministically, forever, the moment the key is
      tombstoned -- and resolves back to whatever it would have anyway
      (governed by whether the grant row is still `active = 1`) the moment
      the SAME key is restored. Restoring a key never revives a grant that
      was separately revoked; it only makes an ALREADY-ACTIVE grant of that
      key valid again.

    DeleteKey's response DOES still surface HOW MANY active grants exist
    right now (`activeGrantCount`, via K9Store.Perm_CountActiveByPermission)
    -- purely INFORMATIONAL, computed with ONE scalar query (never an
    N+1 pattern across the whole catalog -- see ListPermissionCatalogKeys'
    own doc comment for why the LIST response deliberately omits this same
    number for every row), so the deleting officer sees the blast radius
    before confirming, without this file EVER refusing the delete because
    of it.

    NO PROTECTED KEY THE WAY server/certtiers.lua HARDCODES 'certified':
    that protection exists because 'certified' is the literal string baked
    into migration 0006's `k9_certifications.tier DEFAULT 'certified'` and
    into GrantCertification's own INSERT, which relies on that DB default.
    NOTHING in this resource has an equivalent hardcoded dependency on any
    ONE specific permission-key string -- 'k9.access'/'k9.certify'/
    'k9.audit'/'k9.givexp' are each read via a plain string LITERAL
    comparison inside server/permissions.lua (LegacyOrHighCommandStillQualifies,
    the K9-appearance hook), never via a DB column DEFAULT -- so deleting
    any one of the four default keys through this surface changes what
    GrantPermission/HasPermission will accept for that string GOING
    FORWARD, and nothing else; it cannot strand a write the way deleting
    'certified' could. This is disclosed here explicitly, not merely
    absent by omission: an operator CAN tombstone 'k9.access' itself, which
    turns off the ABILITY TO GRANT/HOLD that one capability by this route
    -- HasK9Access's other three routes (certification, autoAccessGrade,
    high command) are completely independent of this file and are
    unaffected either way.

    ======================================================================
    THE DELETE-VS-GRANT RACE (the identical hazard server/certtiers.lua's
    header calls "THE DELETE-VS-ASSIGN RACE", closed the same way)
    ======================================================================

    A naive "check the key is known, then INSERT a grant row" in
    server/permissions.lua's GrantPermission and a naive "check reference
    count (or nothing at all, per TOMBSTONE section above), then tombstone"
    in this file's own DeleteKey could interleave across their own
    MySQL.await yield points -- GrantPermission's own IsValidPermissionKey
    check could observe a key as live an instant before a concurrent
    DeleteKey commits its tombstone, after which GrantPermission's own
    INSERT would still proceed, committing a permission grant that
    reads as valid for the brief window before the very next
    RefreshPermissionKeyCatalog-driven HasPermission check (which will
    already correctly deny it, per the TOMBSTONE section above) -- and, more
    subtly, this file's own audit trail could then show a `permkey_delete`
    row followed by an apparently-successful grant of the just-deleted key,
    which is confusing even though it is never actually EXPLOITABLE (see
    above: HasPermission re-validates on every call, so the worst case is a
    misleading audit entry, never a live privilege).

    CLOSED THE SAME WAY server/certtiers.lua closes the tier-editing
    equivalent: `PermissionKeyEditMutex` (NewMutex(), keyed by
    permissionKey, exposed as a bare global specifically so
    server/permissions.lua's GrantPermission can acquire the SAME lock
    before its own INSERT -- see that function's own updated comment).
    UpsertKey/DeleteKey below acquire the same per-key mutex around their
    own writes for the identical reason (a concurrent relabel/restore
    racing a delete for the same key). Guarded everywhere it is CONSUMED
    (server/permissions.lua) with a `type(PermissionKeyEditMutex) ==
    'table'` runtime existence check, this resource's established
    soft-dependency convention -- GrantPermission still functions,
    accepting only this narrow, now-disclosed race, if this file is ever
    removed.

    NO DEADLOCK AGAINST server/certtiers.lua's OWN TierEditMutex:
    PermissionKeyEditMutex is a SEPARATE NewMutex() instance with its own,
    disjoint key space (permission-key strings vs. tier-key strings). No
    function anywhere in this resource acquires both mutexes nested inside
    one another -- server/permissions.lua's GrantPermission acquires ONLY
    PermissionKeyEditMutex, server/certifications/'s SetCertificationTier
    acquires ONLY TierEditMutex, and neither calls into the other's file at
    all. Two independent, never-nested locks cannot deadlock against each
    other by construction, not merely by discipline.

    ======================================================================
    FAIL-CLOSED, NOT FAIL-OPEN (this task's own explicit requirement)
    ======================================================================

    HasPermission is an authorization root -- see server/permissions.lua's
    own header. This file's catalog is consulted from INSIDE that function
    (via IsValidPermissionKey), so this file's own failure modes must never
    turn a real DB read failure into an accidental ALLOW:
      - K9Store.PermKey_GetAllRows/K9Store.PermKey_GetDeletedFlagByKey (the
        two reads RefreshPermissionKeyCatalog performs) already fail closed
        at the K9Store layer -- a thrown query is pcall-guarded there and
        degrades to an EMPTY result set, never nil, never a partial/stale
        table (see server/datastore.lua's own doc comments on these two
        accessors). An empty result from K9Store.PermKey_GetAllRows simply
        means "no DB overrides exist" -- RefreshPermissionKeyCatalog then
        falls back to Config.Permissions ALONE for that refresh cycle,
        which is a narrower catalog than a correct merge might have been
        (a key created ONLY at runtime would be temporarily invisible), but
        NEVER a wider one -- IsKnownPermissionCatalogKey can only ever
        return false more often on a degraded read, never true for a key
        that should be denied. A degraded read cannot manufacture a new
        ALLOW.
      - BuildPermissionCatalogFromConfigDefaults below CLAMPS AND WARNS
        (a `print`, matching server/cooldowns.lua's own
        ResolveConfiguredThresholdMs precedent for exactly this pattern --
        see that function's own doc comment for the incident behind the
        rule) rather than asserting on a malformed Config.Permissions --
        this file's own top level contains NO bare `assert`/`error` that
        could abort every registration below it for the rest of this
        file's load. A malformed Config.Permissions degrades this file's
        OWN base catalog to empty (server/permissions.lua's own
        UNCONDITIONAL top-level assert on the same table already means this
        is unreachable in a real deployment where that file loaded first --
        this file does not assume that ordering held, and degrades safely
        on its own terms regardless).
      - The one case this file WIDENS relative to server/permissions.lua's
        own pre-existing behavior (a plain `Config.Permissions[value] ~=
        nil` check) is DELIBERATE and DOCUMENTED, not a fail-open accident:
        a key added PURELY at runtime (never in Config.Permissions at all)
        now validates where it previously would not have -- that is the
        entire point of this feature, authorized exclusively through
        UpsertKey's own CanManagePermissionKeys(source) high-command gate,
        never through a degraded read.

    ======================================================================
    Config.Database.enabled = false
    ======================================================================

    Every read/write in this file goes through K9Store (server/
    datastore.lua) -- ZERO direct MySQL/oxmysql calls, ZERO `k9_*` table
    names, anywhere in this file, matching that file's own "the ONLY place
    in this resource that may name a k9_* table or call MySQL.* directly"
    invariant. K9Store.PermKey_*/K9Store.PermKeyAudit_Append/
    K9Store.Perm_CountActiveByPermission each carry their own in-memory
    mirror for `Config.Database.enabled = false`, so this file needs (and
    contains) no branch on that flag at all -- the resource keeps running,
    high command can still add/relabel/delete permission keys for the rest
    of THIS server process, and every edit is simply forgotten on the next
    restart, the same honest story server/datastore.lua's own header
    already promises for every other feature it backs.

    ======================================================================
    AUTHORIZATION (mirrors server/certtiers.lua's own HAZARD 4 exactly)
    ======================================================================

    Every one of this file's THREE callbacks (list/upsert/delete -- one
    fewer than server/certtiers.lua's four, since there is no reorder
    concept here -- see "WHY NO ORDINAL" above) calls
    CanManagePermissionKeys(source) as its OWN first action, which itself
    calls the real, live IsHighCommand(source) -- server-side, against
    `source`'s CURRENT PlayerData/job/grade at the moment of the call,
    every single call, no caching, no trusting any flag/value the NUI
    payload itself carries. Deliberately IsHighCommand ONLY, same scope
    decision server/certtiers.lua's own CanManageCertTiers already made and
    documents the reasoning for -- a follow-up pass can widen this to also
    accept a delegable Config.Permissions-style grant if the team wants
    that, tracked here, not silently done.

    AUDITED via the SAME K9Store.PermKeyAudit_Append/append-only pattern
    (`k9_permission_key_audit`) the tier catalog uses, and every
    invocation (allowed or refused) is auditable the same way this file's
    sibling already is.
]]

-- ======================================================================
-- Initial state -- populated for real a few lines below, before anything
-- ever reads it. Not initialized to `{}` here for the identical reason
-- server/certtiers.lua's own TierByKey/TierOrder comment gives (luacheck's
-- own "dead written-over state" flag).
-- ======================================================================
local PermKeyByKey

--- @param list any
--- @return boolean
local function IsValidConfigPermissionsTable(list)
    if type(list) ~= 'table' then return false end
    for key, def in pairs(list) do
        if type(key) ~= 'string' or key == '' then return false end
        if type(def) ~= 'table' or type(def.label) ~= 'string' or def.label == '' then return false end
        if def.description ~= nil and type(def.description) ~= 'string' then return false end
    end
    return true
end

--- Builds a fresh permissionKey -> {label, description, isConfigDefault}
--- map from Config.Permissions. CLAMP-AND-WARN (print, never assert/error
--- -- see header "FAIL-CLOSED, NOT FAIL-OPEN"): a malformed
--- Config.Permissions degrades this file's own base catalog to EMPTY rather
--- than aborting this file's load, since server/permissions.lua's own
--- unconditional top-level assert on the identical table is what a real
--- deployment actually relies on to catch this -- this file does not
--- assume that assert ran first. Does NOT consult the database -- see
--- RefreshPermissionKeyCatalog for the merge step that layers runtime
--- overrides on top of this.
--- @return table<string, table>
local function BuildPermissionCatalogFromConfigDefaults()
    if not IsValidConfigPermissionsTable(Config.Permissions) then
        print('[John-K9] permissionkeycatalog: Config.Permissions is missing or malformed -- starting the ' ..
            'permission-key catalog with NO config-shipped defaults for this refresh cycle. ' ..
            'server/permissions.lua\'s own unconditional load-time assert on this same table should already ' ..
            'have caught this in a real deployment; seeing this print means this file loaded without that ' ..
            'guard having run first. Any permission key already added from the tablet/database is unaffected. ' ..
            'Fix Config.Permissions in config.lua.')
        return {}
    end

    local map = {}
    for key, def in pairs(Config.Permissions) do
        map[key] = {
            label = def.label,
            description = type(def.description) == 'string' and def.description or nil,
            isConfigDefault = true,
        }
    end
    return map
end

--- Rebuilds `PermKeyByKey` from Config.Permissions merged with the current
--- `k9_permission_keys` database state -- THE DATABASE WINS per key (see
--- header). Called once at this file's own onResourceStart (see bottom of
--- this file) and again after every successful mutation (Upsert/Delete) so
--- a caller's own response (and any other in-flight reader, chiefly
--- server/permissions.lua's HasPermission/IsValidPermissionKey) sees the
--- true new state immediately, never a stale one.
local function RefreshPermissionKeyCatalog()
    local merged = BuildPermissionCatalogFromConfigDefaults()

    local overrideRows = K9Store.PermKey_GetAllRows()
    for _, row in ipairs(overrideRows) do
        if row.deleted == 1 or row.deleted == true then
            -- TOMBSTONE: exclude entirely, whether this key originated in
            -- Config.Permissions or was created purely at runtime. See
            -- header "TOMBSTONE, NOT REFERENCE-COUNTED" for the full
            -- reasoning this is safe with no reference check at all.
            merged[row.permission_key] = nil
        else
            merged[row.permission_key] = {
                label = row.label,
                description = (type(row.description) == 'string' and row.description ~= '') and row.description or nil,
                isConfigDefault = (type(Config.Permissions) == 'table' and Config.Permissions[row.permission_key] ~= nil) or nil,
            }
        end
    end

    PermKeyByKey = merged
end

-- Initial SYNCHRONOUS population from config defaults ONLY, at this file's
-- own load time -- config.lua is a shared_script, loaded in full before any
-- server_scripts file (this one included) starts executing, so Config
-- already holds its real, final values by the time this line runs (same
-- reasoning server/certtiers.lua's own identical initial-population line
-- gives). This makes every accessor below safe to call even before
-- onResourceStart fires for this resource, at the cost of not yet
-- reflecting any DB override -- the onResourceStart handler at the bottom
-- of this file layers the database on top a moment later, before any
-- player action could plausibly reach a permission check.
PermKeyByKey = BuildPermissionCatalogFromConfigDefaults()

-- ======================================================================
-- PUBLIC READ ACCESSORS -- exposed globally (no `local`), extending the
-- SAME seam server/permissions.lua's own IsValidPermissionKey/
-- PermissionLabelFor already established. Every one of these is a read,
-- never a write, and every one is hot-path-safe (cache-based, no query).
-- ======================================================================

--- @param key any
--- @return boolean
function IsKnownPermissionCatalogKey(key)
    return type(key) == 'string' and PermKeyByKey[key] ~= nil
end

--- @param key any
--- @return string? label -- nil for an unknown/tombstoned key, or for the
--- 'feature.<Name>'/'block.<Name>' namespace, which this catalog never
--- represents at all (see header "NAMESPACE PROTECTION").
function GetPermissionCatalogLabel(key)
    local entry = type(key) == 'string' and PermKeyByKey[key]
    return entry and entry.label or nil
end

--- Alphabetical-by-key snapshot of the live catalog -- a COPY, not the
--- live table, so a caller (the tablet aggregation layer, or any future
--- consumer) cannot mutate this file's own authoritative state by editing
--- the returned value. Sorted by key (not by any "importance" -- there is
--- no ordinal here, see header "WHY NO ORDINAL") purely for a stable,
--- deterministic tablet listing.
---
--- DELIBERATELY OMITS a per-key active-grant count (unlike DeleteKey's own
--- response, which includes one for the SINGLE key being deleted) -- see
--- K9Store.Perm_CountActiveByPermission's own doc comment: computing that
--- for EVERY row in this list would be one additional query per catalog
--- entry, an N+1 pattern this resource's own server-side-performance
--- discipline forbids for a screen that can legitimately render dozens of
--- rows. A tablet wanting that number for one specific key can already get
--- it via ListPermissionRoster (server/permissions.lua, unchanged).
--- @return table[] -- { { key, label, description?, isConfigDefault }, ... }
function ListPermissionCatalogKeys()
    local list = {}
    for key, entry in pairs(PermKeyByKey) do
        list[#list + 1] = { key = key, label = entry.label, description = entry.description, isConfigDefault = entry.isConfigDefault == true }
    end
    table.sort(list, function(a, b) return a.key < b.key end)
    return list
end

-- ======================================================================
-- AUTHORIZATION -- re-verified on EVERY call, never cached. See header
-- "AUTHORIZATION".
-- ======================================================================

--- @param source number
--- @return string? citizenid
local function ResolveCitizenId(source)
    local Player = exports.qbx_core:GetPlayer(source)
    local citizenid = Player and Player.PlayerData and Player.PlayerData.citizenid
    if type(citizenid) == 'string' and citizenid ~= '' then return citizenid end
    return nil
end

--- Server-authoritative, re-resolved fresh on every call -- never cached,
--- never trusts a client-supplied flag. Deliberately IsHighCommand ONLY --
--- see header "AUTHORIZATION" for the full scope-decision writeup this
--- mirrors verbatim from server/certtiers.lua's own CanManageCertTiers.
--- @param source number
--- @return boolean authorized, string? citizenid
local function CanManagePermissionKeys(source)
    local citizenid = ResolveCitizenId(source)
    if type(IsHighCommand) == 'function' and IsHighCommand(source) then
        return true, citizenid
    end
    return false, citizenid
end

-- Cross-file critical-section lock, keyed by permission_key -- NOT a
-- player source, same reasoning server/certtiers.lua's own TierEditMutex
-- doc comment gives for itself. Exposed as a bare global (no `local`)
-- specifically so server/permissions.lua's GrantPermission can acquire the
-- SAME lock before writing a new grant -- see header "THE DELETE-VS-GRANT
-- RACE" for exactly which race this closes, and why it cannot deadlock
-- against server/certtiers.lua's own, entirely separate TierEditMutex.
PermissionKeyEditMutex = NewMutex()

-- Anti-fat-finger/double-submit rate limit, keyed by the ACTING officer's
-- own source -- mirrors server/certtiers.lua's CertTierActionCooldown
-- exactly. Every caller reaching this point is already confirmed high
-- command by CanManagePermissionKeys above; this guards against a held key
-- or a double-submitted click, not abuse.
local PERMKEY_ACTION_COOLDOWN_MS = 1000
local PermKeyActionCooldown = NewCooldown(PERMKEY_ACTION_COOLDOWN_MS)
PermKeyActionCooldown.RegisterPlayerDropped()

-- Defensive cap on total live (non-tombstoned) key count -- an
-- already-authenticated high-command account is a highly trusted actor,
-- but an unbounded catalog is still an unforced footgun (e.g. a stuck
-- tablet retry loop hammering create with a new key each time). Well above
-- any real operator's plausible custom-permission count.
local MAX_PERMISSION_KEYS = 60

--- @param action string
--- @param permissionKey string
--- @param detail string
--- @param changedBy string
local function WritePermKeyAudit(action, permissionKey, detail, changedBy)
    -- AUDIT-SWALLOW FIX (this pass): PermKeyAudit_Append's own boolean
    -- return used to be discarded here -- every call site above already
    -- checked its OWN primary write before ever reaching this helper, so
    -- the action genuinely happened and this file's own `ok = true`
    -- responses remain correct either way -- but a failed audit-trail
    -- insert must not vanish without a trace tying it to this specific
    -- action/key. Mirrors server/runtimecontrol.lua's own identical
    -- "AUDIT-SWALLOW FIX (this pass)" comment/shape exactly.
    if not K9Store.PermKeyAudit_Append(action, permissionKey, detail, changedBy or 'unknown') then
        print(('[John-K9] permissionkeycatalog.lua: audit-trail write failed for action=%s permissionKey=%s (the action itself still succeeded and was persisted).'):format(tostring(action), tostring(permissionKey)))
    end
end

-- ======================================================================
-- VALIDATION -- every field a tablet payload can influence is validated
-- server-side before it ever reaches a query, matching this resource's
-- established "treat every inbound payload as adversarial" posture.
-- ======================================================================

--- Reserved-namespace check -- see header "NAMESPACE PROTECTION". Checked
--- BEFORE the plain shape validator below so a caller gets the more
--- specific, more honest refusal reason ('reserved_namespace', not
--- 'invalid_key') for a key that is shaped correctly but collides with the
--- feature./block. per-person-feature-control namespace.
--- @param key any
--- @return boolean
local function IsReservedNamespaceKey(key)
    if type(key) ~= 'string' then return false end
    if key == 'feature' or key == 'block' then return true end
    return key:match('^feature%.') ~= nil or key:match('^block%.') ~= nil
end

--- RESERVED INTERNAL CAPABILITY KEYS -- see header "RESERVED INTERNAL
--- CAPABILITY KEYS" for the full privilege-escalation writeup this closes.
--- Every entry below is a `HasPermission(citizenid, '<literal>')` escape
--- hatch some OTHER file in this resource hardcodes, deliberately left
--- INERT by that file's own author because the literal is not (yet) a key
--- of Config.Permissions -- this catalog must never let that literal be
--- manufactured out of thin air through permKeysUpsert, or the "inert"
--- premise silently stops being true.
---
--- AUDIT COMMAND -- re-run this any time a new file might have added one of
--- these gates, and add whatever it finds that is NOT already a genuine
--- Config.Permissions default to the table below:
---   grep -rhoE "HasPermission\([^,]+, *'k9\.[a-z0-9_.]+'\)" server/*.lua \
---     | sed -E "s/.*'(k9\.[a-z0-9_.]+)'.*/\1/" | sort -u
--- As of this pass that command returns exactly eight keys. Four are real
--- Config.Permissions defaults (k9.access, k9.audit, k9.certify, k9.givexp
--- -- NEVER add these here: they are the legitimate, config-owner-issued
--- capability catalog this whole file exists to serve, and reserving a live
--- default would wrongly block high command from ever relabeling it). The
--- remaining four are every currently-known inert hatch, reserved below:
---   k9.runtimecontrol        -- server/runtimecontrol.lua CanManageRuntimeControl
---   k9.tablettheme           -- server/runtimecontrol.lua CanManageTabletTheme
---   k9.equipmentshoplocations -- server/equipmentshop.lua CanManageShopLocations
---   k9.equipmentshopitems    -- server/equipmentshop.lua CanManageShopItems
--- @param key any
--- @return boolean
local RESERVED_INTERNAL_CAPABILITY_KEYS = {
    ['k9.runtimecontrol']         = true,
    ['k9.tablettheme']            = true,
    ['k9.equipmentshoplocations'] = true,
    ['k9.equipmentshopitems']     = true,
}

local function IsReservedInternalCapabilityKey(key)
    return type(key) == 'string' and RESERVED_INTERNAL_CAPABILITY_KEYS[key] == true
end

--- 2-40 chars, lowercase-start, lowercase/digit/underscore/dot segments
--- only (matches the shape every shipped key already uses, e.g.
--- 'k9.access') -- comfortably inside both k9_permission_keys
--- .permission_key's VARCHAR(50) and k9_permissions.permission's own
--- VARCHAR(50) (migration 0005), so a valid new key can always actually be
--- written to BOTH tables. Lua patterns have no `{n,m}` quantifier --
--- length is checked separately, not via the pattern itself. Does NOT
--- require a dot -- a plain, undotted custom key (e.g. 'special_access')
--- is equally valid and cannot collide with the feature./block. namespace
--- (that collision is checked separately, first, by IsReservedNamespaceKey
--- above).
---
--- IMPLEMENTATION NOTE: Lua patterns have no way to repeat a MULTI-
--- character GROUP the way a real regex `(\.[a-z][a-z0-9_]*)*` can --
--- `()` in a Lua pattern only ever creates a CAPTURE, never a repeatable
--- group, so a single `key:match(...)` cannot validate an arbitrary number
--- of dot-separated segments in one pattern. Validated in two passes
--- instead: an overall character-set/first-character check, then each
--- dot-separated segment individually via `gmatch`.
--- @param key any
--- @return boolean
local function IsValidPermissionCatalogKey(key)
    if type(key) ~= 'string' then return false end
    local len = #key
    if len < 2 or len > 40 then return false end
    if not key:match('^[a-z][a-z0-9_.]*$') then return false end
    if key:find('%.%.') or key:sub(-1) == '.' then return false end
    for segment in key:gmatch('[^.]+') do
        if not segment:match('^[a-z][a-z0-9_]*$') then return false end
    end
    return true
end

--- Character filter mirroring server/certtiers.lua's own IsValidTierLabel
--- (itself mirroring server/runtimecontrol.lua's IsSafeHeaderTitle) --
--- defense in depth on top of the tablet's own textContent-only rendering
--- discipline, not a substitute for it. Used for BOTH `label` (<=60 chars,
--- matches k9_permission_keys.label's own VARCHAR(60)) and the optional
--- `description` (<=300 chars, matches k9_permission_keys.description's
--- own VARCHAR(300)) -- one shared validator, two call sites, two
--- different `maxLen` arguments.
--- @param value any
--- @param maxLen number
--- @return boolean
local function IsValidSafeText(value, maxLen)
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

-- ======================================================================
-- CALLBACKS -- all three re-verify CanManagePermissionKeys(source) as
-- their own first action (see header "AUTHORIZATION"). Response shape
-- mirrors server/certtiers.lua's own `{ ok, reason, ... }` convention
-- exactly, for consistency across this resource's tablet-facing surfaces
-- (client/tablet.lua's existing TranslateReasonResult bridges this to the
-- NUI's own `{ ok, error?, ... }` contract with no change needed there).
-- ======================================================================

lib.callback.register('john-k9:server:permKeysList', function(source)
    local authorized = CanManagePermissionKeys(source)
    if not authorized then return { ok = false, reason = 'denied' } end
    return { ok = true, keys = ListPermissionCatalogKeys() }
end)

lib.callback.register('john-k9:server:permKeysUpsert', function(source, payload)
    local authorized, citizenid = CanManagePermissionKeys(source)
    if not authorized then return { ok = false, reason = 'denied' } end

    if not PermKeyActionCooldown.Consume(source, PERMKEY_ACTION_COOLDOWN_MS) then
        return { ok = false, reason = 'rate_limited' }
    end

    if type(payload) ~= 'table' or type(payload.key) ~= 'string' then
        return { ok = false, reason = 'invalid_payload' }
    end

    local key = payload.key
    if IsReservedNamespaceKey(key) then
        return { ok = false, reason = 'reserved_namespace' }
    end
    -- PRIVILEGE-ESCALATION FIX (this pass) -- see header "RESERVED INTERNAL
    -- CAPABILITY KEYS". Checked before the shape validator, same reasoning
    -- IsReservedNamespaceKey's own placement comment gives: a caller gets
    -- the more specific, more honest 'reserved_internal_key' refusal for a
    -- key that is shaped correctly but names an inert authorization hatch
    -- another file already hardcodes, rather than the generic 'invalid_key'.
    if IsReservedInternalCapabilityKey(key) then
        return { ok = false, reason = 'reserved_internal_key' }
    end
    if not IsValidPermissionCatalogKey(key) then
        return { ok = false, reason = 'invalid_key' }
    end
    if not IsValidSafeText(payload.label, 60) then
        return { ok = false, reason = 'invalid_label' }
    end
    if payload.description ~= nil and not IsValidSafeText(payload.description, 300) then
        return { ok = false, reason = 'invalid_description' }
    end

    if not PermissionKeyEditMutex.TryAcquire(key) then
        return { ok = false, reason = 'busy' }
    end

    -- `existing` is nil both for a genuinely brand-new key AND for one
    -- currently tombstoned (PermKeyByKey excludes tombstoned keys
    -- entirely) -- `priorRow` below (a direct DB read, ignoring the
    -- tombstone filter) is what actually distinguishes "create" from
    -- "restore" for the audit trail.
    local existing = PermKeyByKey[key]
    local isNewOrRestoring = existing == nil

    if isNewOrRestoring then
        local liveCount = 0
        for _ in pairs(PermKeyByKey) do liveCount = liveCount + 1 end
        if liveCount >= MAX_PERMISSION_KEYS then
            PermissionKeyEditMutex.Release(key)
            return { ok = false, reason = 'too_many_keys' }
        end
    end

    local priorRow = K9Store.PermKey_GetDeletedFlagByKey(key)[1]

    local wrote = K9Store.PermKey_Upsert(key, payload.label, payload.description, citizenid or 'unknown')
    PermissionKeyEditMutex.Release(key)

    if not wrote then
        return { ok = false, reason = 'db_error' }
    end

    local action
    if not isNewOrRestoring then
        action = 'permkey_update'
    elseif priorRow ~= nil and (priorRow.deleted == 1 or priorRow.deleted == true) then
        action = 'permkey_restore'
    else
        action = 'permkey_create'
    end

    WritePermKeyAudit(action, key,
        ('label=%q description=%q'):format(payload.label, payload.description or ''),
        citizenid or 'unknown')

    RefreshPermissionKeyCatalog()

    return { ok = true, keys = ListPermissionCatalogKeys() }
end)

lib.callback.register('john-k9:server:permKeysDelete', function(source, key)
    local authorized, citizenid = CanManagePermissionKeys(source)
    if not authorized then return { ok = false, reason = 'denied' } end

    if not PermKeyActionCooldown.Consume(source, PERMKEY_ACTION_COOLDOWN_MS) then
        return { ok = false, reason = 'rate_limited' }
    end

    if type(key) ~= 'string' or not IsKnownPermissionCatalogKey(key) then
        return { ok = false, reason = 'unknown_key' }
    end

    if not PermissionKeyEditMutex.TryAcquire(key) then
        return { ok = false, reason = 'busy' }
    end

    local entry = PermKeyByKey[key]
    local wrote = K9Store.PermKey_Tombstone(key, entry.label, entry.description, citizenid or 'unknown')
    PermissionKeyEditMutex.Release(key)

    if not wrote then
        return { ok = false, reason = 'db_error' }
    end

    -- INFORMATIONAL ONLY -- see header "TOMBSTONE, NOT REFERENCE-COUNTED":
    -- this NEVER refuses the delete, it only tells the deleting officer how
    -- many currently-active grants of this key are about to go inert. A
    -- failed count read (pcall-guarded, matching every other K9Store
    -- reconciliation read in this resource) degrades to `nil` rather than
    -- blocking an already-committed tombstone on a second, unrelated query.
    local countOk, activeCountOrErr = pcall(K9Store.Perm_CountActiveByPermission, key)
    local activeGrantCount = countOk and tonumber(activeCountOrErr) or nil

    WritePermKeyAudit('permkey_delete', key,
        ('permission key %s deleted (tombstoned) -- %s active grant(s) at the moment of deletion, now permanently inert until/unless restored'):format(
            key, tostring(activeGrantCount or 'unknown')),
        citizenid or 'unknown')

    RefreshPermissionKeyCatalog()

    return { ok = true, keys = ListPermissionCatalogKeys(), activeGrantCount = activeGrantCount }
end)

-- ======================================================================
-- BOOT -- layer the persisted DB overrides on top of config.lua's own
-- shipped defaults. Deferred to onResourceStart (not raw top-level --
-- MySQL/oxmysql readiness is not guaranteed at raw server_scripts
-- load-time), mirroring server/certtiers.lua's own identical
-- "config-only defaults at file-load, DB layered on top at
-- onResourceStart" pattern exactly.
--
-- WAITS FOR THE SCHEMA-COLLISION PROBE TO SETTLE FIRST (db-schema
-- boot-order fix, this pass): server/datastore.lua loads before this file
-- and registers its own onResourceStart handler first, but that handler's
-- own MySQL.query.await yields -- and a yielding handler does not block
-- FXServer's event dispatch from moving straight on to THIS handler while
-- the probe is still in flight. Without this wait,
-- K9Store.PermKey_GetAllRows() below would run its own, narrower SELECT
-- (4 of the 7 columns k9_permission_keys is checked against) against
-- whatever `k9_permission_keys` currently is, before the probe has had a
-- chance to say whether that table is even really ours -- a foreign table
-- the full probe would correctly reject could still satisfy this
-- narrower one during that window. K9Store.WaitForSchemaCheckToSettle()
-- (server/datastore.lua) blocks THIS coroutine only, with a bounded
-- timeout, until that determination is final -- see its own header for
-- the full contract. On a `false` return (the probe genuinely had not
-- settled within the wait budget -- database unreachable/slow, or off by
-- config, which settles instantly instead of waiting at all), this
-- catalog boots to config-only defaults for this session, exactly like
-- `Config.Database.enabled == false` -- PermKeyByKey already holds those
-- defaults from this file's own synchronous file-load-time population
-- above, so simply skipping the refresh here is sufficient, not a
-- separate fallback path to maintain. The next successful
-- permKeysUpsert/DeleteKey call (or a resource restart, by which point the
-- probe will certainly have settled) re-reads the real state as normal.
-- ======================================================================
AddEventHandler('onResourceStart', function(resourceName)
    if GetCurrentResourceName() ~= resourceName then return end
    if not K9Store.WaitForSchemaCheckToSettle() then
        print('[John-K9] permissionkeycatalog: the schema-collision check had not finished within its wait budget -- booting this session\'s permission-key catalog with config.lua defaults ONLY (no database read attempted, exactly like Config.Database.enabled = false) rather than trust a database state that is not yet confirmed safe. The next successful permission-key edit (or a restart once the check has had time to finish) will pick up any real persisted state.')
        return
    end
    RefreshPermissionKeyCatalog()
end)
