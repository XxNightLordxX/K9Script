--[[
    qbx_k9unit/server/appearance.lua

    Decouples the K9 ROLE from the K9 PED MODEL, per the project owner's
    three requirements:
      1. High command, from the tablet, can either certify a handler (the
         existing server/certifications/ flow) OR directly "apply K9" to
         any citizenid, and either path PERMANENTLY changes that player's
         own character to a configured ped.
      2. Any Config.Peds entry works, including a custom/non-dog model —
         nothing here ever assumes a dog, or even an animal.
      3. A player on an unlisted model, INCLUDING AN ORDINARY HUMAN PED, can
         still hold the K9 role and use every K9 ability — the role is now
         an assignment this file holds against a citizenid
         (`k9_ped_assignments`, sql/migrations/0006), not an inference from
         whatever the player currently looks like.

    ======================================================================
    THE DECOUPLING, IN ONE PLACE (read this before touching anything else
    that gates on "is this player the K9"):

    "HOLDS THE K9 ROLE" now means, precisely: an active
    `k9_certifications` row for the citizenid's CURRENT job (the traditional
    credential this resource already calls "K9 certification" — see
    server/certifications/'s own OnJobUpdate comment: "the cert is
    specifically the 'I am a working K9' credential, not 'I am allowed near
    one'" — that sentence is the whole finding this file is built on), OR an
    active `k9.access` grant in server/permissions.lua's k9_permissions
    table. Both are EXISTING credentials this file adds no third copy of —
    see HasK9Role() below, which is nothing more than that OR, spelled out.
    Deliberately EXCLUDES the autoAccessGrade/high-command BYPASSES inside
    HasK9Access(): those grant broad, blanket access to K9 *features*
    (so a chief can test/oversee them) without making that officer's own
    character *be* the K9 — see CanShowK9UI()'s own updated doc comment in
    client/main.lua for why that distinction matters for UI gating.

    "WHAT THE ROLE-HOLDER LOOKS LIKE" is wholly separate, tracked in
    `k9_ped_assignments` (citizenid -> currently-applied model name, plus
    the ORIGINAL model hash captured before the very first swap so a revoke
    can put it back). Config.K9Appearance.requireK9ModelForRole (default
    false) controls ONLY whether server/certifications/'s grant-time
    model check still runs — it never touches HasK9Role() above, which was
    already model-independent by construction before this file existed.

    ======================================================================
    EVENT/CALLBACK CONTRACT:
    Callbacks (ox_lib lib.callback):
      'qbx_k9unit:server:hasK9Role' () -> boolean [THIS FILE]
      'qbx_k9unit:server:isK9RoleForTarget' (targetServerId: number) -> boolean [THIS FILE -- backs client/appearance.lua's IsK9RoleForPlayer(), the "does THAT OTHER player hold the K9 role" primitive consumed by the ten ox_target canInteract predicates this K9 role/model decoupling widening touches; see that file's own STATEBAG VS CACHED CALLBACK header section for why this is a cached callback, not a replicated statebag]
    Client events (RegisterNetEvent, server->client):
      'qbx_k9unit:client:applyK9Ped' (requestId: string, modelNameOrHash: string|number) [client/appearance.lua]
    Server events (RegisterNetEvent, client->server):
      'qbx_k9unit:server:confirmK9PedSwap' (requestId: string, ok: boolean, reason: string?) [THIS FILE]

    ======================================================================
    FILE-TO-FILE CONTRACT:
    - THIS FILE exposes four resource-global (no `local`) functions:
        HasK9Role(source) -> boolean
        ApplyK9PedRole(granterSrc, targetCitizenid, modelName) -> ok, outcome
            The explicit tablet "apply K9" action (requirement 1's second
            verb). modelName is REQUIRED and must be a Config.Peds entry —
            this is how requirement 2 (any configured ped, including
            custom/non-dog) is satisfied: the tablet reads Config.Peds
            (with its new optional `.label`) and this function accepts
            whichever `.model` string the operator picked.
        ApplyK9AppearanceOnGrant(targetCitizenid, granterCitizenid, modelName?)
            The AUTOMATIC side effect Config.K9Appearance's own header
            documents ("certifying someone (or granting them k9.access)
            actually turns their character into the ped") — called ONLY
            from server/certifications/'s GrantCertification and
            server/permissions.lua's GrantPermission, each already gated on
            Config.K9Appearance.applyPedModelOnCertify at the call site.
            modelName defaults to Config.Peds[1].model when omitted, since
            neither caller carries a model choice of its own.
        MaybeRevertK9Appearance(citizenid)
            Called from every path in server/certifications/ and
            server/permissions.lua that just confirmed a K9 credential is
            GONE (RevokeCertification, RevokeCertificationOffline,
            OnJobUpdate's auto-revoke, and RevokePermission's
            stillHasAccess == nil case). Reconciles against the OTHER
            credential before reverting anything — see its own doc comment.
      Each is guarded at its call site with the established
      `type(...) == 'function'` soft-dependency convention (this file loads
      after server/permissions.lua/server/highcommand.lua/server/cooldowns.lua
      and before server/certifications/ in fxmanifest.lua).
    - THIS FILE calls `HasPermission`/`GrantPermission`/`RevokePermission`
      (server/permissions.lua), `IsHighCommand` (server/highcommand.lua) and
      `NewCooldown` (server/cooldowns.lua, at THIS file's own load time — a
      hard load-order requirement, same as every other consumer), and
      `NotifyPlayer` (server/notify.lua). All guarded except NewCooldown,
      which every consumer in this resource calls unconditionally at load
      time.
    - THIS FILE does NOT call into server/certifications/'s `local`
      Certifications cache directly (it is private to that file) —
      IsCertifiedK9ForCurrentJob below reads `k9_certifications` itself,
      the same table certifications.lua reads, rather than requiring a new
      exposed accessor there. This keeps certifications.lua's surgical edit
      surface to the two call-outs above plus the two items in its own
      header note, nothing more.

    ======================================================================
    PER-PED STATE ACROSS A MODEL SWAP — SPEC-LEVEL DECISION (client-side
    enforcement lives in client/appearance.lua, documented in full there):
    REFUSE the swap, don't force-clear, whenever the target is in ANY
    resource-tracked "busy" state (leashed, mid drag as either party, mid
    bite-hold, mid fetch-carry, inside a K9 vehicle) — this file only
    reasons about server-authoritative role/DB state, so it cannot itself
    know these; the client-side pre-flight check owns that decision.

    ======================================================================
    STREAMING FAILURE CONTRACT: a model that never finishes loading within
    Config.K9Appearance.modelLoadTimeoutMs is an ABANDONED swap — this file
    NEVER writes `model`/`active` to `k9_ped_assignments` until the
    client's own confirmation event says the swap actually landed. A
    still-offline target is the one exception: there the row is written
    immediately with no swap attempted at all yet (nothing to confirm), and
    the real swap — with its own real timeout/abandon handling — runs the
    first time PlayerLoaded fires for them.
]]

-- ======================================================================
-- CONFIG-SAFETY GUARD — run unconditionally at load time (NOT gated behind
-- any Config.Features flag: applyPedModelOnCertify is its own internal
-- on/off switch, and ApplyK9PedRole/ApplyK9AppearanceOnGrant/
-- MaybeRevertK9Appearance are called from certification/permission grant
-- paths that run regardless).
--
-- CLAMP AND WARN, NOT ASSERT (see server/cooldowns.lua's header ADDENDUM:
-- "does an operator's config.lua edit alone... reach this value? If yes it
-- must be clamped and warned about, never asserted and aborted"). This
-- used to be three hard `assert`s here -- each correctly diagnosing a real
-- risk, but with the wrong remedy: an uncaught error thrown from THIS
-- FILE's own top-level chunk (this guard runs unconditionally, with no
-- deferring onResourceStart/RegisterNetEvent wrapper, and with no
-- Config.Features gate to make it opt-in) aborts server/appearance.lua's
-- load from that line onward -- taking every function this file defines
-- (ApplyK9PedRole, ApplyK9AppearanceOnGrant, MaybeRevertK9Appearance, and
-- everything else below) down with it, for the rest of that server's
-- uptime, over one operator typo in a custom Config.Peds entry added to
-- try a new breed. Other server_scripts files (server/certifications/,
-- the tablet, permission grants) call into this file's functions
-- unconditionally and would see them simply not exist, with nothing but
-- one script-error line at boot to explain why.
-- ======================================================================
if type(Config.K9Appearance) ~= 'table' then
    print(
        '[qbx_k9unit] WARNING: Config.K9Appearance is missing or not a table -- using a built-in default ' ..
        '(applyPedModelOnCertify=false, i.e. this resource will detect K9 models but never assign one, same as ' ..
        'before this feature existed) so certification/permission grants keep working while the config is ' ..
        'fixed. Add the Config.K9Appearance settings table back to config.lua.'
    )
    Config.K9Appearance = { applyPedModelOnCertify = false }
end

if type(Config.Peds) ~= 'table' or #Config.Peds == 0 then
    print(
        '[qbx_k9unit] WARNING: Config.Peds must be a non-empty array (found: ' .. tostring(Config.Peds) .. ') -- ' ..
        "ApplyK9PedRole validates every caller-supplied model name against it, and ApplyK9AppearanceOnGrant " ..
        "defaults to Config.Peds[1].model when no explicit model is given. Using a single built-in fallback " ..
        "entry ('a_c_shepherd') instead of refusing every K9 ped assignment on this server -- add your real " ..
        'roster back to Config.Peds in config.lua.'
    )
    Config.Peds = { { model = 'a_c_shepherd', speedMultiplier = 1.00 } }
end

-- Individual malformed entries are dropped (not fatal) rather than
-- rejecting the whole roster over one bad line -- same "one bad entry
-- should not disable every other, valid entry" reasoning as
-- Config.K9Specializations/Config.Departments elsewhere in this resource.
do
    local validPeds = {}
    for i, pedEntry in ipairs(Config.Peds) do
        if type(pedEntry) == 'table' and type(pedEntry.model) == 'string' and pedEntry.model ~= '' then
            validPeds[#validPeds + 1] = pedEntry
        else
            print(('[qbx_k9unit] WARNING: Config.Peds[%d].model must be a non-empty string -- dropping this ' ..
                'entry and continuing with the rest of the roster.'):format(i))
        end
    end
    if #validPeds == 0 then
        print(
            '[qbx_k9unit] WARNING: every entry in Config.Peds was malformed -- using a single built-in ' ..
            "fallback entry ('a_c_shepherd') instead of leaving the roster empty."
        )
        validPeds = { { model = 'a_c_shepherd', speedMultiplier = 1.00 } }
    end
    Config.Peds = validPeds
end

-- ======================================================================
-- K9 IDENTITY CONFIG GUARD (THIS PASS) -- same CLAMP-AND-WARN posture as
-- every guard above: a malformed/missing Config.K9Identity must degrade to
-- "feature behaves as if switched on, with its default shape" rather than
-- throwing out of this file's top-level chunk and taking every function
-- below it down with it (see this section header's own reasoning above for
-- why an assert here would be the wrong fix). See config.lua's own
-- Config.K9Identity comment for what an operator actually sees.
-- ======================================================================
if type(Config.K9Identity) ~= 'table' then
    print(
        '[qbx_k9unit] WARNING: Config.K9Identity is missing or not a table -- using a built-in default ' ..
        '(enabled=true, showHandlerName=true) so the "Identify K9" target option keeps working while the ' ..
        'config is fixed. Add the Config.K9Identity settings table back to config.lua.'
    )
    Config.K9Identity = {}
end
if type(Config.K9Identity.enabled) ~= 'boolean' then
    Config.K9Identity.enabled = true
end
if type(Config.K9Identity.showHandlerName) ~= 'boolean' then
    Config.K9Identity.showHandlerName = true
end

--- @param name any
--- @return boolean
local function IsValidPedModelName(name)
    if type(name) ~= 'string' or name == '' then return false end
    for _, pedEntry in ipairs(Config.Peds) do
        if pedEntry.model == name then return true end
    end
    return false
end

-- Anti-fat-finger cooldown, same shape/threshold as
-- server/certifications/'s CertifyActionCooldown and
-- server/permissions.lua's PermissionActionCooldown (1500ms, a plain
-- literal, not a Config field -- this file cannot edit config.lua either).
-- Keyed by the GRANTER's own source, mirroring both of those exactly.
local APPEARANCE_ACTION_COOLDOWN_MS = 1500
local AppearanceActionCooldown = NewCooldown(APPEARANCE_ACTION_COOLDOWN_MS)
AppearanceActionCooldown.RegisterPlayerDropped()

-- PendingSwap[citizenid] = { requestId, kind = 'apply'|'revert',
--   granterLabel, modelName (string, apply only), modelHash (number,
--   revert only, or apply's resolved hash for audit), expiresAt }
-- In-memory / ephemeral only, same posture as server/main.lua's
-- PendingLeashRequests and server/kennel.lua's PendingKennelPlacements.
--
-- CORRECTED: an earlier version of this comment claimed "nothing was ever
-- written ... no DB state to clean up" for BOTH kinds; that is only true
-- for 'apply' -- a pending 'apply' that never confirms (crash/disconnect/
-- timeout mid-flight) really is a clean no-op -- no pre-existing DB row it
-- could leave dangling, see "STREAMING FAILURE CONTRACT" below. A pending
-- 'revert', by contrast, starts from a PRE-EXISTING `active = 1` row that
-- must not survive the swap being abandoned -- both the sweep thread
-- (below, timeout) and the playerDropped handler (below, disconnect)
-- COMMIT the revert unconditionally in that case, precisely because
-- leaving that row untouched would let a decertified citizenid come back
-- as a K9 on their very next reconnect.
local PendingSwap = {}

-- Generous margin over the client's own load timeout, so a legitimate
-- slow-but-successful load is never mistaken here for an abandoned one —
-- the client is always the one that decides "abandoned", this is only a
-- backstop against a confirm that never arrives at all (disconnect).
local function ApplyRequestTtlMs()
    local timeout = (Config.K9Appearance and Config.K9Appearance.modelLoadTimeoutMs) or 10000
    if type(timeout) ~= 'number' or timeout <= 0 then timeout = 10000 end
    return timeout + 5000
end

local requestCounter = 0
local function NextRequestId()
    requestCounter = requestCounter + 1
    return ('%d:%d'):format(GetGameTimer(), requestCounter)
end

--- @param source number
--- @return string
local function WhoLabelForSource(source)
    local Player = exports.qbx_core:GetPlayer(source)
    local citizenid = Player and Player.PlayerData and Player.PlayerData.citizenid
    return citizenid and ('citizenid=' .. citizenid) or ('unresolved-source=' .. tostring(source))
end

--- Matches server/admin.lua's LogAuditInvocation / server/permissions.lua's
--- LogAuditInvocation "%s ran %s(%s) -> %s" format EXACTLY. `whoLabel` is
--- pre-resolved by the caller so this works uniformly whether the actor is
--- a live source (tablet action) or a system-triggered path (auto-revert
--- on decertify/job-change), matching server/certifications/'s own
--- 'system:job_change' sentinel precedent for the latter.
--- @param whoLabel string
--- @param action string
--- @param detail string
--- @param outcome string
local function LogAppearanceAudit(whoLabel, action, detail, outcome)
    print(('[qbx_k9unit] AUDIT: %s ran %s(%s) -> %s'):format(whoLabel, action, detail, outcome))
end

--- Server-authoritative: does `citizenid` hold an active k9_certifications
--- row for THEIR CURRENT job? Deliberately re-derives this from the DB
--- directly rather than reaching into server/certifications/'s private
--- `Certifications` cache (not exposed, and this file's header explains why
--- it stays that way) -- this call is never on a hot path (role
--- reconciliation on revoke, and the HasK9Role callback, itself cached
--- client-side on the same 1s TTL as HasK9Access), so a direct read is
--- simpler and cannot drift from a second in-memory copy.
--- FAILS CLOSED on a read error (an unreadable row is never treated as an
--- active credential), matching every other cert-table read in this
--- resource.
--- @param citizenid string
--- @param jobName string?
--- @return boolean
local function IsCertifiedK9ForJob(citizenid, jobName)
    if type(citizenid) ~= 'string' or citizenid == '' or type(jobName) ~= 'string' or jobName == '' then
        return false
    end
    local ok, idOrErr = pcall(K9Store.Cert_GetActiveId, citizenid, jobName)
    if not ok then
        print(('[qbx_k9unit] appearance.lua IsCertifiedK9ForJob query failed for %s/%s: %s'):format(citizenid, jobName, tostring(idOrErr)))
        return false
    end
    return idOrErr ~= nil
end

--- Same as IsCertifiedK9ForJob, but across EVERY department at once — used
--- ONLY by MaybeRevertK9Appearance's reconciliation (a citizenid can hold a
--- separate active cert for a DIFFERENT department than the one that just
--- got revoked -- DEVELOPER_REFERENCE.md's own "cross-department granting IS currently
--- allowed" -- and losing one must not revert an appearance still backed
--- by the other). FAILS OPEN here deliberately (an unreadable row is
--- treated as "assume still qualified, don't revert") -- unlike every
--- ACCESS check in this resource, this is a REVERT guard: reverting a
--- player's character on a transient DB hiccup would itself be the
--- destructive mistake, whereas skipping a revert that should have
--- happened just leaves them as a K9 a little longer, correctable the next
--- time this runs cleanly.
--- @param citizenid string
--- @return boolean
local function IsCertifiedK9ForAnyJob(citizenid)
    local ok, idOrErr = pcall(K9Store.Cert_GetActiveIdAnyJob, citizenid)
    if not ok then
        print(('[qbx_k9unit] appearance.lua IsCertifiedK9ForAnyJob query failed for %s: %s'):format(citizenid, tostring(idOrErr)))
        return true -- fail OPEN -- see doc comment above
    end
    return idOrErr ~= nil
end

--- THE role check: "is this player the DOG half of a team?" Server-
--- authoritative. Exposed globally; ~20 call sites (partnering, leashing,
--- treating, the K9 menus, client IsK9Role()) ask it.
---
--- A CERTIFICATION ALONE DOES NOT MAKE YOU THE DOG. A certification is held
--- by both halves of a team (the owner's rework pass: "Certify as Handler /
--- as K9"). This used to answer `true` for anyone certified -- harmless
--- only while certifying always turned the person into a dog. Once a
--- handler could be certified without that, every certified handler read
--- as a second K9: partnering and leashing refused with "Both of you are
--- playing K9s", and handlers were shown dog-only abilities.
---
--- The dog is someone who:
---   1. holds the 'k9.access' grant -- what Assign K9 Role gives, and
---      model-independent by design; or
---   2. is certified AND actually a K9: an active K9 appearance assignment
---      (Certify as K9, Assign K9 Role, or a legacy auto-certify), a pinned
---      dog character, or currently wearing a configured K9 model (servers
---      that leave appearance to the player's own character system).
--- A certified player who is none of those is a HANDLER.
--- @param source number
--- @return boolean
function HasK9Role(source)
    local Player = exports.qbx_core:GetPlayer(source)
    if not Player or not Player.PlayerData then return false end

    local citizenid = Player.PlayerData.citizenid
    if type(HasPermission) == 'function' and HasPermission(citizenid, 'k9.access') then
        return true
    end

    local job = Player.PlayerData.job
    if not (job ~= nil and IsCertifiedK9ForJob(citizenid, job.name)) then
        return false
    end

    if type(IsConfiguredK9Model) == 'function' then
        local ped = GetPlayerPed(source)
        if ped and ped ~= 0 and IsConfiguredK9Model(GetEntityModel(ped)) then return true end
    end
    if GetAssignedK9Model(citizenid) ~= nil then return true end
    if type(IsPinnedDogCharacter) == 'function' and IsPinnedDogCharacter(citizenid) then return true end
    return false
end

lib.callback.register('qbx_k9unit:server:hasK9Role', function(source)
    return HasK9Role(source)
end)

--- THE one real gap in the primitives: HasK9Role/IsK9Role both answer about
--- the CALLER only. Several ox_target canInteract predicates elsewhere in
--- this resource (client/movement.lua's "Certify K9 Handler"/"Revoke
--- Certification"/"Attach Leash", client/partnership.lua's "Partner Up",
--- client/medkit.lua's "Treat K9", client/wellbeing.lua's "Pet K9"/
--- "Feed K9") need to ask "is THAT OTHER player, right now, a K9-role
--- holder" to correctly show their option to/for a role-holder on an
--- unlisted or human model. Not security-sensitive to expose (same class
--- of fact as the existing `k9certified` metadata mirror, already
--- broadcast client-side) — this is a CONVENIENCE gate only, same posture
--- as every other canInteract predicate in this resource; every real
--- action still re-verifies server-side via HasK9Role/HasK9Access
--- regardless of what this answers.
--- @param source number -- the ASKING client (unused; the query is about targetServerId, not the caller)
--- @param targetServerId number
lib.callback.register('qbx_k9unit:server:isK9RoleForTarget', function(_source, targetServerId)
    if type(targetServerId) ~= 'number' then return false end
    return HasK9Role(targetServerId)
end)

-- ======================================================================
-- k9_ped_assignments READ/WRITE HELPERS (sql/migrations/0006). See that
-- file for the exact schema this reads/writes.
-- ======================================================================

--- @param citizenid string
--- @return table? row -- { model, original_model_hash, active } or nil (not found, or the read failed)
local function GetAppearanceRow(citizenid)
    -- K9Store.Appearance_GetRow already pcall-wraps its own DB read
    -- internally (never throws -- see datastore.lua's own doc comment on
    -- this function), so this is a direct passthrough, not a pcall around
    -- it -- this file's own callers (WriteAppearanceApplied historically,
    -- GetAssignedK9Model below) already only ever expected a row-or-nil
    -- return, never a caught error.
    return K9Store.Appearance_GetRow(citizenid)
end

--- Writes the "a swap for `model` was just confirmed applied" state.
--- Preserves an existing `original_model_hash` ONLY when the existing row
--- is still `active` (a fresh assignment after a genuine revert must
--- capture a NEW original, not reuse a stale one from a prior stint -- see
--- this file's header "STREAMING FAILURE CONTRACT" neighbor note on
--- revert). `originalHash` may be nil (not yet known -- an offline-target
--- persisted assignment that hasn't had its first swap attempt yet).
---
--- DATASTORE MIGRATION NOTE: this used to pre-read the existing row itself
--- (GetAppearanceRow) and resolve the "keep or replace" decision in Lua
--- before ever reaching the INSERT -- K9Store.Appearance_UpsertApplied's
--- own doc comment confirms its COALESCE(VALUES(original_model_hash),
--- original_model_hash) reproduces the real SQL verbatim, so that pre-read
--- is now redundant (every call site in this file already passes
--- `originalHash = nil` on every re-apply-while-still-a-K9 path, so the
--- SQL-level COALESCE alone reaches the identical outcome the Lua-level
--- pre-read used to compute) and has been dropped rather than kept as dead
--- weight duplicating logic the accessor already owns.
--- @param citizenid string
--- @param model string
--- @param originalHash number?
--- @param appliedByLabel string
local function WriteAppearanceApplied(citizenid, model, originalHash, appliedByLabel)
    -- K9Store.Appearance_UpsertApplied mirrors this function's own
    -- pre-existing boolean (never-throws) contract -- see its own doc
    -- comment ("Mirrors WriteAppearanceApplied's own boolean contract").
    return K9Store.Appearance_UpsertApplied(citizenid, model, originalHash, appliedByLabel)
end

--- @param citizenid string
--- @return boolean ok
local function WriteAppearanceReverted(citizenid)
    -- K9Store.Appearance_MarkReverted mirrors this function's own
    -- pre-existing boolean (never-throws) contract.
    return K9Store.Appearance_MarkReverted(citizenid)
end

--- Read-only convenience accessor (no known caller in this resource today,
--- exposed for a future consumer / the tablet's own display needs, same
--- "expose the accessor, let a later file decide it wants it" reasoning
--- server/certifications/'s IsConfiguredK9Model already documents).
--- @param citizenid string
--- @return string? model -- nil if no active assignment
function GetAssignedK9Model(citizenid)
    local row = GetAppearanceRow(citizenid)
    if row and row.active == 1 then return row.model end
    return nil
end

-- ======================================================================
-- CLIENT ROUND TRIP -- see this file's header "STREAMING FAILURE CONTRACT"
-- and client/appearance.lua's own header for the full client-side half
-- (engaged-check, RequestModel/HasModelLoaded polling with the leak fix,
-- abandon-on-timeout).
-- ======================================================================

--- @param targetCitizenid string
--- @param kind 'apply'|'revert'
--- @param payload string|number -- modelName (apply) or modelHash (revert)
--- @param granterLabel string
--- @return boolean sent -- false if the target isn't currently online (caller decides what that means for its own flow)
local function SendSwapRequest(targetCitizenid, kind, payload, granterLabel)
    local targetPlayer = exports.qbx_core:GetPlayerByCitizenId(targetCitizenid)
    local targetSrc = targetPlayer and targetPlayer.PlayerData and targetPlayer.PlayerData.source
    if not targetSrc then return false end

    local requestId = NextRequestId()
    PendingSwap[targetCitizenid] = {
        requestId = requestId,
        kind = kind,
        granterLabel = granterLabel,
        payload = payload,
        expiresAt = GetGameTimer() + ApplyRequestTtlMs(),
    }
    TriggerClientEvent('qbx_k9unit:client:applyK9Ped', targetSrc, requestId, payload)
    return true
end

--- @param citizenid string
--- @return table? pending -- nil if none, or it already expired (also clears it)
local function TakePendingSwap(citizenid)
    local pending = PendingSwap[citizenid]
    if not pending then return nil end
    if GetGameTimer() > pending.expiresAt then
        PendingSwap[citizenid] = nil
        return nil
    end
    return pending
end

-- SECURITY FIX: confirmK9PedSwap below only ever writes
-- `k9_ped_assignments` when the CLIENT reports `ok = true` -- correct and
-- necessary for an APPLY (never half-apply a model that may not have
-- actually loaded), but wrong for a REVERT: client/appearance.lua's
-- IsCurrentlyEngaged() is entirely self-reported (IsLeashed/
-- IsBiteHoldEngaged/IsDragEngaged/IsFetchCarryEngaged/IsInK9Vehicle are all
-- local client-side booleans), so a modified client could reply `false,
-- 'engaged'` forever, or simply never reply at all, and a revert --
-- including server/tablet.lua's own ForceRevertK9Appearance, high
-- command's explicit "remove K9 ped, revert to human" action -- would
-- never complete. That is exactly the "no unbounded trap" rule from the
-- other direction: a TERMINATION path must not be vetoable by the party it
-- terminates.
--
-- This sweep is the fix: any PENDING 'revert' whose grace period
-- (ApplyRequestTtlMs -- the same generous modelLoadTimeoutMs + margin
-- window a cooperating client's own RequestModel/HasModelLoaded polling
-- gets) has elapsed with no valid confirm is completed HERE,
-- server-side, unconditionally -- HasK9Role/HasK9Access were already
-- false from the moment the underlying credential was revoked (this
-- table only ever tracks cosmetic state), so this sweep closes the
-- "permanently stuck showing as a K9" gap without ever touching a live,
-- possibly mid-action ped without that ped's own client-side engaged
-- check having had a fair, bounded chance to run first. A cooperating
-- player who is genuinely mid-bite-hold gets that full grace window to
-- finish and reply; a hostile or unresponsive one cannot hold it open
-- longer than that.
--
-- 'apply' entries are NOT forced the other way (never grant an unconfirmed
-- appearance) -- a stale one past its own grace period is simply dropped,
-- which also bounds PendingSwap's memory (same "add a sweep" precedent as
-- every other per-citizenid/per-source table in this resource that isn't
-- already cleared on playerDropped alone).
local APPEARANCE_SWEEP_INTERVAL_MS = 2000
CreateThread(function()
    while true do
        Wait(APPEARANCE_SWEEP_INTERVAL_MS)

        local now = GetGameTimer()
        for citizenid, pending in pairs(PendingSwap) do
            if now > pending.expiresAt then
                PendingSwap[citizenid] = nil
                if pending.kind == 'revert' then
                    -- DISCARDED-WRITE FIX: this is the SECURITY-CRITICAL
                    -- forced-timeout revert this sweep's own header comment
                    -- documents -- its whole point is that a
                    -- hostile/unresponsive client cannot hold a revert open
                    -- past its grace period. The write's own boolean result
                    -- was previously discarded, so a DB failure here was
                    -- logged as 'forced_timeout' (success) and could even
                    -- tell an online target their appearance was reverted,
                    -- while k9_ped_assignments still reads active=1.
                    -- HasK9Role(src) is already false for this citizenid
                    -- (that's why this is a pending revert at all), so
                    -- PlayerLoaded's own stale-row backstop still refuses to
                    -- re-apply the model on their next reconnect regardless --
                    -- this is a logging/notify accuracy fix, not a second
                    -- security hole, but the audit trail and the player toast
                    -- must not claim a persistence success that did not
                    -- happen.
                    local wroteOk = WriteAppearanceReverted(citizenid)
                    if wroteOk then
                        LogAppearanceAudit(pending.granterLabel, 'k9AppearanceRevert', ('citizenid=%s'):format(citizenid), 'forced_timeout')
                        local onlinePlayer = exports.qbx_core:GetPlayerByCitizenId(citizenid)
                        local onlineSrc = onlinePlayer and onlinePlayer.PlayerData and onlinePlayer.PlayerData.source
                        if onlineSrc then
                            NotifyPlayer(onlineSrc, locale('appearance.revert_success_target'), 'success')
                        end
                    else
                        print(('[qbx_k9unit] appearance.lua forced-timeout revert: DB write failed for citizenid=%s -- k9_ped_assignments still reads active=1.'):format(citizenid))
                        LogAppearanceAudit(pending.granterLabel, 'k9AppearanceRevert', ('citizenid=%s'):format(citizenid), 'forced_timeout_db_error')
                    end
                else
                    LogAppearanceAudit(pending.granterLabel, 'k9AppearanceApply', ('citizenid=%s'):format(citizenid), 'abandoned:no_confirm_received')
                end
            end
        end
    end
end)

RegisterNetEvent('qbx_k9unit:server:confirmK9PedSwap', function(requestId, ok, reason)
    local src = source
    local Player = exports.qbx_core:GetPlayer(src)
    local citizenid = Player and Player.PlayerData and Player.PlayerData.citizenid
    if not citizenid then return end

    local pending = TakePendingSwap(citizenid)
    -- Stale/forged confirm (wrong requestId, expired, or none in flight at
    -- all) -- ignore rather than trust a client-claimed requestId blindly.
    if not pending or pending.requestId ~= requestId then return end
    PendingSwap[citizenid] = nil

    if ok then
        -- DISCARDED-WRITE FIX: WriteAppearanceApplied/WriteAppearanceReverted
        -- both follow this resource's SafeWrite contract
        -- (K9Store.Appearance_UpsertApplied/Appearance_MarkReverted degrade
        -- a thrown DB error to `false` rather than propagating it) -- their
        -- return value was previously discarded outright here, so a DB
        -- failure was silently reported to the target as a "success" toast
        -- AND logged as outcome 'ok', even though k9_ped_assignments was
        -- never actually written. The client-side model swap itself already
        -- happened (that's what `ok == true` on this branch means) -- only
        -- persistence can still fail, and that must not be reported as a
        -- clean success.
        local wroteOk
        if pending.kind == 'apply' then
            wroteOk = WriteAppearanceApplied(citizenid, pending.payload, nil, pending.granterLabel)
        else
            wroteOk = WriteAppearanceReverted(citizenid)
        end

        local actionLabel = 'k9Appearance' .. (pending.kind == 'apply' and 'Apply' or 'Revert')
        if wroteOk then
            NotifyPlayer(src, locale(pending.kind == 'apply' and 'appearance.apply_success_target' or 'appearance.revert_success_target'), 'success')
            LogAppearanceAudit(pending.granterLabel, actionLabel, ('citizenid=%s'):format(citizenid), 'ok')
        else
            -- No player-facing message is sent here: this file has no
            -- already-shipped locale key for "the swap displayed but was not
            -- saved", and a false "success" would be worse than silence.
            -- The accurate console/audit trail below is what lets an
            -- operator notice and retry -- this citizenid's
            -- k9_ped_assignments row is unaffected (still whatever it was
            -- before this confirm), so their NEXT reconnect/resource
            -- restart re-derives from that unchanged, correct row rather
            -- than from the visual state that just failed to persist.
            print(('[qbx_k9unit] appearance.lua confirmK9PedSwap: %s DB write failed for citizenid=%s -- the client-side swap succeeded but was NOT persisted.'):format(pending.kind, citizenid))
            LogAppearanceAudit(pending.granterLabel, actionLabel, ('citizenid=%s'):format(citizenid), 'db_error')
        end
    else
        -- ABANDONED, per this file's header contract: no DB write at all --
        -- the player is exactly as they were. `reason` is a client-supplied
        -- opaque tag ('engaged' | 'timeout') for the audit line only, never
        -- passed to locale() -- see client/appearance.lua for the exact set.
        LogAppearanceAudit(pending.granterLabel, 'k9Appearance' .. (pending.kind == 'apply' and 'Apply' or 'Revert'),
            ('citizenid=%s'):format(citizenid), 'abandoned:' .. tostring(reason))
    end
end)

-- ======================================================================
-- GRANT-SIDE ENTRY POINTS
-- ======================================================================

--- The explicit tablet "apply K9" action (requirement 1's second verb).
--- Reuses server/permissions.lua's GrantPermission wholesale for
--- authorization (high command only, self-grant blocked, cooldown, audit,
--- DB persistence of the 'k9.access' credential) rather than re-deriving
--- any of that here -- see this file's header FILE-TO-FILE CONTRACT.
--- `modelName` is REQUIRED (unlike ApplyK9AppearanceOnGrant's default) --
--- this is the one entry point where the operator is explicitly choosing a
--- ped, including a custom/non-dog one (requirement 2).
--- @param granterSrc number
--- @param targetCitizenid string
--- @param modelName string
--- @return boolean ok
--- @return string outcome -- every GrantPermission outcome, plus 'invalid_model' and 'db_error'
function ApplyK9PedRole(granterSrc, targetCitizenid, modelName)
    if not IsValidPedModelName(modelName) then
        LogAppearanceAudit(WhoLabelForSource(granterSrc), 'applyK9PedRole',
            ('model=%s target=%s'):format(tostring(modelName), tostring(targetCitizenid)), 'invalid_model')
        return false, 'invalid_model'
    end

    if not AppearanceActionCooldown.Consume(granterSrc) then
        return false, 'rate_limited'
    end

    -- DOUBLE-APPLY GUARD (found by this file's own test suite, not merely
    -- reasoned about): GrantPermission's own hook (ApplyK9AppearanceOnGrant,
    -- wired in server/permissions.lua's GrantPermission) fires
    -- automatically for a BRAND NEW grant when
    -- Config.K9Appearance.applyPedModelOnCertify is on -- passing
    -- `modelName` straight through as GrantPermission's 4th
    -- (appearanceModelOverride) parameter means that hook applies the
    -- EXACT model this tablet action chose, not the automatic-grant
    -- default (Config.Peds[1].model). A first draft of this function
    -- called SendSwapRequest itself UNCONDITIONALLY after GrantPermission
    -- returned -- for a brand-new grant that sent a SECOND, redundant swap
    -- request (the hook's + this function's own), racing each other for
    -- no reason. Below, this function only performs its OWN swap for the
    -- 'already_granted' outcome, where GrantPermission's hook correctly
    -- does NOT fire (nothing NEW was granted) but the operator may still
    -- be choosing a DIFFERENT ped for a citizenid who already holds the
    -- role (Shepherd -> Husky, requirement 2).
    local grantOk, grantOutcome = GrantPermission(granterSrc, targetCitizenid, 'k9.access', modelName)

    -- Every OTHER GrantPermission failure (denied/rate_limited/
    -- invalid_target/self_grant_blocked/db_error/feature_disabled) is a
    -- real stop -- GrantPermission has already logged/audited/notified it
    -- itself.
    if not grantOk and grantOutcome ~= 'already_granted' then
        return false, grantOutcome
    end

    local granterLabel = WhoLabelForSource(granterSrc)

    if grantOutcome == 'ok' then
        -- Brand-new grant -- GrantPermission's own hook already applied
        -- (or persisted-offline) exactly this modelName; this is a
        -- read-only re-check of online status purely to pick the right
        -- granter-facing message, not a second attempt at anything.
        local targetPlayer = exports.qbx_core:GetPlayerByCitizenId(targetCitizenid)
        if targetPlayer and targetPlayer.PlayerData and targetPlayer.PlayerData.source then
            NotifyPlayer(granterSrc, locale('appearance.apply_success_granter'), 'success')
            return true, 'ok'
        end
        NotifyPlayer(granterSrc, locale('appearance.apply_pending_offline'), 'inform')
        return true, 'persisted_offline'
    end

    -- grantOutcome == 'already_granted': apply THIS explicit model
    -- ourselves, since nothing else will for a re-apply.
    local sent = SendSwapRequest(targetCitizenid, 'apply', modelName, granterLabel)
    if sent then
        NotifyPlayer(granterSrc, locale('appearance.apply_success_granter'), 'success')
        return true, 'ok'
    end

    -- Offline target: persist the assignment now (no swap to attempt yet;
    -- original_model_hash captured lazily on their next PlayerLoaded,
    -- below, before the real swap runs against them for the first time).
    local granterPlayer = exports.qbx_core:GetPlayer(granterSrc)
    local granterCitizenid = granterPlayer and granterPlayer.PlayerData and granterPlayer.PlayerData.citizenid
    -- DISCARDED-WRITE FIX: this write's boolean result was previously
    -- discarded outright -- a DB failure here used to be reported to the
    -- granter as `true, 'persisted_offline'` (an "inform" toast promising
    -- the role would be there on the target's next login) even though
    -- nothing was actually persisted. Reported honestly instead, matching
    -- this resource's established `reason = 'db_error'` convention for a
    -- SafeWrite-contract write returning `false` (see e.g.
    -- server/certtiers.lua's identical pattern).
    local wroteOk = WriteAppearanceApplied(targetCitizenid, modelName, nil, granterCitizenid or granterLabel)
    if not wroteOk then
        LogAppearanceAudit(granterLabel, 'applyK9PedRole', ('model=%s target=%s'):format(modelName, targetCitizenid), 'db_error')
        return false, 'db_error'
    end
    LogAppearanceAudit(granterLabel, 'applyK9PedRole', ('model=%s target=%s'):format(modelName, targetCitizenid), 'persisted_offline')
    NotifyPlayer(granterSrc, locale('appearance.apply_pending_offline'), 'inform')
    return true, 'persisted_offline'
end

--- The AUTOMATIC side effect of a successful certify or 'k9.access'
--- permission grant, per Config.K9Appearance's own header — called ONLY
--- when the caller has already checked
--- Config.K9Appearance.applyPedModelOnCertify itself. Neither caller
--- (server/certifications/'s GrantCertification, server/permissions.lua's
--- GrantPermission) carries a model choice, so this defaults to
--- Config.Peds[1].model when `modelName` is omitted or invalid.
--- @param targetCitizenid string
--- @param granterCitizenid string?
--- @param modelName string?
function ApplyK9AppearanceOnGrant(targetCitizenid, granterCitizenid, modelName)
    local resolvedModel = IsValidPedModelName(modelName) and modelName or Config.Peds[1].model
    local granterLabel = granterCitizenid and ('citizenid=' .. granterCitizenid) or 'system'

    local sent = SendSwapRequest(targetCitizenid, 'apply', resolvedModel, granterLabel)
    if not sent then
        -- DISCARDED-WRITE FIX: return value previously ignored -- see
        -- confirmK9PedSwap's own identical fix above for the full
        -- reasoning. This function is a void automatic side effect (its
        -- callers, GrantCertification/GrantPermission, never check a return
        -- value by design), so the only way this failure is ever visible at
        -- all is an accurate audit outcome.
        local wroteOk = WriteAppearanceApplied(targetCitizenid, resolvedModel, nil, granterCitizenid or 'system')
        LogAppearanceAudit(granterLabel, 'applyK9AppearanceOnGrant',
            ('model=%s target=%s'):format(resolvedModel, targetCitizenid), wroteOk and 'persisted_offline' or 'db_error')
        if not wroteOk then
            print(('[qbx_k9unit] appearance.lua ApplyK9AppearanceOnGrant: DB write failed for citizenid=%s -- the automatic K9 appearance grant was NOT persisted for this offline target.'):format(targetCitizenid))
        end
    end
end

--- Reverts `citizenid`'s appearance IFF Config.K9Appearance.restoreOriginalPedOnRevoke
--- is on AND they no longer qualify for the K9 role through ANY path (see
--- IsCertifiedK9ForAnyJob's own doc comment for why this fails OPEN on a
--- read error, unlike every access check elsewhere in this resource).
--- Safe to call unconditionally from every revoke path in
--- server/certifications/ / server/permissions.lua — a citizenid with no
--- active k9_ped_assignments row is a cheap no-op (mirrors
--- ForceDetachLeashIfOnline/ForceBreakPartnershipForCitizenId's own
--- "harmless no-op for the common case" convention).
--- @param citizenid string
--- Shared core for both MaybeRevertK9Appearance (automatic, credential-
--- reconciled) and ForceRevertK9Appearance (explicit, high-command,
--- credential-blind by design -- see that function's own doc comment).
--- Neither pre-check belongs here: by the time this runs, the caller has
--- already decided the revert should happen.
--- @param citizenid string
--- @param granterLabel string
--- @return boolean ok
--- @return string outcome -- 'ok' | 'no_active_assignment' | 'no_fallback_configured' | 'db_error'
local function PerformRevert(citizenid, granterLabel)
    local row = GetAppearanceRow(citizenid)
    if not row or row.active ~= 1 then return false, 'no_active_assignment' end -- nothing currently applied for this citizenid

    local originalHash = row.original_model_hash
    if not originalHash then
        -- No original was ever captured (this install had an existing K9
        -- before this feature shipped, or the citizenid's very first swap
        -- is still pending on a currently-offline target) -- fall back
        -- per Config.K9Appearance.fallbackHumanModel's own documented
        -- purpose, rather than leaving them stranded as whatever they
        -- currently are. Resolved by NAME here (client resolves the hash
        -- itself via GetHashKey), matching Config.Peds' own string
        -- convention.
        local fallback = Config.K9Appearance and Config.K9Appearance.fallbackHumanModel
        if type(fallback) ~= 'string' or fallback == '' then
            print(('[qbx_k9unit] appearance.lua PerformRevert: no original_model_hash and no ' ..
                'Config.K9Appearance.fallbackHumanModel configured for %s -- refusing to revert rather than guess.'):format(citizenid))
            return false, 'no_fallback_configured'
        end
        local sent = SendSwapRequest(citizenid, 'revert', fallback, granterLabel)
        if not sent then
            -- DISCARDED-WRITE FIX: this write's boolean result was
            -- previously discarded -- ForceRevertK9Appearance (this
            -- function's caller) then unconditionally reported `true, 'ok'`
            -- and notified high command "reverted successfully" even when
            -- the row was never actually cleared. That matters MORE here
            -- than for an ordinary write: ForceRevertK9Appearance is
            -- deliberately credential-blind (it can be called on a target who
            -- STILL holds an active certification), so PlayerLoaded's own
            -- HasK9Role backstop would NOT catch a silently-failed clear on
            -- their next reconnect the way it does for an automatic
            -- (credential-driven) revert -- the K9 model would simply come
            -- back, silently undoing the exact action high command just took.
            if not WriteAppearanceReverted(citizenid) then return false, 'db_error' end
        end
        return true, 'ok'
    end

    local sent = SendSwapRequest(citizenid, 'revert', originalHash, granterLabel)
    if not sent then
        -- Offline: nothing to visually revert right now -- just clear the
        -- row so PlayerLoaded below doesn't re-apply the K9 model on their
        -- next connect. They reconnect looking like whatever they logged
        -- out as, which is correct: the swap, if any was ever live, has
        -- already been undone from server-authoritative state.
        --
        -- DISCARDED-WRITE FIX: same reasoning as the fallback branch
        -- immediately above -- see that branch's own comment.
        if not WriteAppearanceReverted(citizenid) then return false, 'db_error' end
    end
    return true, 'ok'
end

--- Automatic reconciliation -- called from every path in
--- server/certifications/ and server/permissions.lua that just
--- confirmed a K9 credential is GONE. Reverts ONLY when the citizenid no
--- longer qualifies via ANY path -- see its own credential checks below.
--- For the DELIBERATE, high-command-initiated "remove K9 ped" action that
--- must work regardless of credentials, see ForceRevertK9Appearance below.
--- @param citizenid string
function MaybeRevertK9Appearance(citizenid)
    if not (Config.K9Appearance and Config.K9Appearance.restoreOriginalPedOnRevoke) then return end
    if type(citizenid) ~= 'string' or citizenid == '' then return end

    if type(HasPermission) == 'function' and HasPermission(citizenid, 'k9.access') then return end
    if IsCertifiedK9ForAnyJob(citizenid) then return end

    -- DISCARDED-WRITE FIX: this is a void automatic side effect (this
    -- function's own callers never check a return value, by design -- same
    -- as ApplyK9AppearanceOnGrant above), so a failed revert was previously
    -- indistinguishable from a successful one anywhere in the logs. Not
    -- itself a NEW security gap -- HasK9Role/HasK9Access are already false
    -- for this citizenid (that's why this reconciliation ran at all), so
    -- PlayerLoaded's own stale-row HasK9Role backstop still refuses to
    -- re-apply the model on their next reconnect regardless of whether
    -- this particular write landed -- but a silent DB failure here
    -- deserves a console line, not nothing.
    local ok, outcome = PerformRevert(citizenid, 'system')
    if not ok and outcome == 'db_error' then
        print(('[qbx_k9unit] appearance.lua MaybeRevertK9Appearance: revert DB write failed for citizenid=%s.'):format(citizenid))
    end
end

--- The tablet's explicit, high-command-initiated "remove K9 ped, revert to
--- human" action (server/tablet.lua's ForceRevertK9Appearance call site).
--- Deliberately does NOT run MaybeRevertK9Appearance's credential checks:
--- those exist so an AUTOMATIC reconciliation never undoes an appearance
--- still legitimately backed by a separate credential. This is the
--- opposite case -- a direct command from high command that must succeed
--- EVEN IF the target still holds an active certification/permission on
--- paper (the role and the appearance are being deliberately decoupled by
--- this action, not reconciled) -- and, per the NO UNBOUNDED TRAP rule
--- applied to a TERMINATION path, must ALSO succeed on a target who has
--- ALREADY lost every credential, or revoking someone first would strand
--- them permanently. Authorization is therefore keyed on the GRANTER alone
--- (IsHighCommand), never on anything about the target.
---
--- NO SELF-SERVICE REVERT. EVER. Asked directly, the owner's answer was
--- "No never": a player wearing the K9 CANNOT return themselves to human,
--- and no command, radial entry, tablet button or item may ever be added
--- that lets them. High command puts someone into the role and high
--- command is the only way out of it.
---
--- This is a standing product decision, not an unfinished feature -- do
--- not "fix" it. The obvious argument for adding one (a player stuck as
--- the dog at 3am with no admin online) was put to the owner explicitly
--- and rejected, so raising it again needs a new decision from him, not a
--- patch. The player-facing half is the Guide's "Go Back to Being Human"
--- walkthrough, which tells them plainly that the only route is to ask
--- high command -- keep the two in step if this ever does change.
---
--- WHY IT SITS HERE, on the granter-authorized primitive: this function is
--- where anyone adding a self-revert would start, because it is already
--- the one path that reverts unconditionally. Making it callable by its
--- own target is a two-line change and would look like a small
--- convenience.
--- @param granterSrc number
--- @param targetCitizenid string
--- @return boolean ok
--- @return string outcome -- 'ok' | 'denied' | 'rate_limited' | 'invalid_target' | 'no_active_assignment' | 'no_fallback_configured' | 'db_error'
function ForceRevertK9Appearance(granterSrc, targetCitizenid)
    if not (type(IsHighCommand) == 'function' and IsHighCommand(granterSrc)) then
        LogAppearanceAudit(WhoLabelForSource(granterSrc), 'forceRevertK9Appearance', ('target=%s'):format(tostring(targetCitizenid)), 'denied')
        return false, 'denied'
    end

    if not AppearanceActionCooldown.Consume(granterSrc) then
        return false, 'rate_limited'
    end

    if type(targetCitizenid) ~= 'string' or targetCitizenid == '' then
        return false, 'invalid_target'
    end

    local granterLabel = WhoLabelForSource(granterSrc)
    local ok, outcome = PerformRevert(targetCitizenid, granterLabel)

    LogAppearanceAudit(granterLabel, 'forceRevertK9Appearance', ('target=%s'):format(targetCitizenid), outcome)
    if ok then
        NotifyPlayer(granterSrc, locale('appearance.revert_success_granter'), 'success')
    end
    return ok, outcome
end

-- ======================================================================
-- PERSISTENCE ACROSS RELOG/CRASH/RESTART (item B) -- Config.K9Appearance
-- .persistAcrossSessions. A resource restart alone never changes a
-- connected player's actual ped (SetPlayerModel is a game-engine-level
-- change, untouched by this resource stopping/starting), so the only real
-- re-application point is a fresh connection.
-- ======================================================================
AddEventHandler('QBCore:Server:PlayerLoaded', function(Player)
    if not (Config.K9Appearance and Config.K9Appearance.persistAcrossSessions) then return end
    if not Player or not Player.PlayerData then return end
    local citizenid = Player.PlayerData.citizenid
    local src = Player.PlayerData.source

    local row = GetAppearanceRow(citizenid)
    if not row or row.active ~= 1 then return end

    -- SECURITY FIX: BACKSTOP, independent of the playerDropped fix below --
    -- a persisted `active = 1` row must never be trusted blindly on
    -- reconnect. Without this, ANY way a stale active row could survive
    -- past a real credential loss (the disconnect-during-revert window the
    -- playerDropped fix below closes, or any other future path that
    -- writes this table without going through HasK9Role first) would
    -- silently re-apply a K9 model to a citizenid who no longer holds the
    -- role at all. HasK9Role(src) is the SAME server-authoritative check
    -- CanShowK9UI()/every gate ultimately reduces to -- if it says no,
    -- clear the stale row here and now rather than re-apply it.
    if type(HasK9Role) == 'function' and not HasK9Role(src) then
        -- DISCARDED-WRITE FIX: return value previously ignored. The
        -- fail-safe behavior itself is unaffected either way -- this
        -- branch already `return`s below without ever re-applying the model,
        -- regardless of whether the clear-write actually landed -- but the
        -- audit trail must not claim 'stale_row_cleared_no_role' (success)
        -- for a write that silently failed.
        if WriteAppearanceReverted(citizenid) then
            LogAppearanceAudit('system', 'k9AppearancePlayerLoaded', ('citizenid=%s'):format(citizenid), 'stale_row_cleared_no_role')
        else
            print(('[qbx_k9unit] appearance.lua PlayerLoaded: stale-row clear DB write failed for citizenid=%s -- the K9 model was NOT re-applied this connect (fail-safe), but the stale active=1 row is still there for a future attempt to clear.'):format(citizenid))
            LogAppearanceAudit('system', 'k9AppearancePlayerLoaded', ('citizenid=%s'):format(citizenid), 'stale_row_clear_db_error')
        end
        return
    end

    if not row.original_model_hash then
        -- First-ever swap for this citizenid and they were offline when it
        -- was requested -- capture their CURRENT (pre-swap) live model now,
        -- before pushing the swap below, so a later revert has something
        -- real to restore. A few short retries: the server-side ped can
        -- lag slightly behind PlayerLoaded firing.
        local attempts = 0
        local ped = 0
        while attempts < 10 do
            ped = GetPlayerPed(src)
            if ped ~= 0 then break end
            Wait(500)
            attempts = attempts + 1
        end
        if ped ~= 0 then
            -- K9Store.Appearance_SetOriginalHashIfMissing mirrors this
            -- call site's own pre-existing boolean (never-throws) contract
            -- internally -- no pcall needed around it (unlike the raw
            -- MySQL.update.await this replaces, it never propagates a
            -- thrown DB error to this caller).
            local ok = K9Store.Appearance_SetOriginalHashIfMissing(citizenid, GetEntityModel(ped))
            if not ok then
                print(('[qbx_k9unit] appearance.lua PlayerLoaded original-model capture failed for %s'):format(citizenid))
            end
        else
            print(('[qbx_k9unit] appearance.lua PlayerLoaded: could not resolve a live ped for %s to capture ' ..
                'their pre-swap original model -- a later revert will use Config.K9Appearance.fallbackHumanModel instead.'):format(citizenid))
        end
    end

    SendSwapRequest(citizenid, 'apply', row.model, 'system')
end)

-- SECURITY FIX: ASYMMETRIC ON PURPOSE, unlike this file's own earlier
-- (WRONG, since corrected) header claim that a dropped pending swap always
-- means "nothing was ever written -- no DB state to clean up": that is
-- true for 'apply' (no pre-existing DB state a drop could leave dangling
-- -- a pending apply that never confirmed correctly stays un-applied) but
-- NOT for 'revert', which starts from a PRE-EXISTING `active = 1` row. A
-- target who disconnects mid-revert (deliberately -- an alt-F4 the moment
-- a suspicious model swap arrives, or simply after seeing it -- or by
-- pure chance) previously left that stale active row untouched, and
-- PlayerLoaded (above) would have re-applied it on their very next
-- reconnect with NO re-check of anything, permanently defeating a
-- decertification. The server already MADE this decision before ever
-- sending the swap (this is what distinguishes a revert from an apply,
-- which is not yet a decision to keep, only a request that might fail to
-- load); only the client's own visual confirmation is missing, and that
-- stops mattering the instant the player is gone. Commit it here,
-- unconditionally, for a dropped 'revert' only -- the PlayerLoaded
-- HasK9Role backstop above is a second, independent line of defense for
-- any OTHER way a stale active row could ever occur.
AddEventHandler('playerDropped', function(_reason)
    local src = source
    local Player = exports.qbx_core:GetPlayer(src)
    local citizenid = Player and Player.PlayerData and Player.PlayerData.citizenid
    if citizenid then
        local pending = PendingSwap[citizenid]
        PendingSwap[citizenid] = nil
        if pending and pending.kind == 'revert' then
            -- DISCARDED-WRITE FIX: return value previously ignored -- see
            -- confirmK9PedSwap's own identical fix above for the full
            -- reasoning, applied here to the disconnect-commit path.
            if WriteAppearanceReverted(citizenid) then
                LogAppearanceAudit(pending.granterLabel, 'k9AppearanceRevert', ('citizenid=%s'):format(citizenid), 'committed_on_disconnect')
            else
                print(('[qbx_k9unit] appearance.lua playerDropped: commit-on-disconnect revert DB write failed for citizenid=%s.'):format(citizenid))
                LogAppearanceAudit(pending.granterLabel, 'k9AppearanceRevert', ('citizenid=%s'):format(citizenid), 'committed_on_disconnect_db_error')
            end
        end
    end
end)

-- ======================================================================
-- K9 IDENTITY (THIS PASS) -- "make a K9 identifiable to the people around
-- it" (ease-of-use audit finding: a K9 has no in-character identity to a
-- bystander -- other players see a dog, and this resource's own targeting
-- menu never said whose dog it was, or what they're called on the radio).
--
-- WHAT THIS IS: one new lib.callback, 'qbx_k9unit:server:k9Identity'
-- (targetServerId: number) -> table, backing client/appearance.lua's new
-- "Identify K9" ox_target(-equivalent) option. Given a target the caller
-- is standing next to and can already see, it answers with that
-- character's own name, their roster callsign if the K9 Command Tablet
-- roster has given them one, and (optionally) their partnered handler's
-- name -- nothing else.
--
-- WHY NOT PUT THE NAME IN THE ox_target OPTION'S OWN `label` FIELD (the
-- literal text the menu itself shows): every option this resource
-- registers goes through shared/compat/target.lua's K9Compat abstraction
-- so it keeps working under qb-target/qtarget/sleepless_interact, not just
-- ox_target -- read directly this pass (that file's own OxTargetFactory
-- header, "CONFIRMED against overextended/ox_target's live main branch...
-- label... is already ox_target's own native shape"): `label` is a plain
-- STATIC string fixed at registration time, the same for every player and
-- every look, across every one of those backends -- there is no per-hover
-- "who am I currently looking at" text slot in any of them. Every existing
-- ox_target option in this resource (client/wellbeing.lua's "Pet K9"/
-- "Feed K9", client/movement.lua's "Attach Leash", etc.) is built on that
-- same static-label assumption. Making the label ITSELF the dog's name
-- would mean re-registering a per-entity option every time a K9 comes into
-- view or changes identity, on every nearby client, continuously -- a poll
-- this task explicitly ruled out ("must not add a poll"), for a smaller
-- win than it costs. The option's OWN label instead names the ACTION
-- ("Identify K9", locale('appearance.identity_target_label') --
-- client/appearance.lua), and selecting it reveals the resolved identity
-- via a plain notification -- one read, on selection, never per frame,
-- exactly this task's "read on target, not per frame" instruction.
--
-- SERVER-RESOLVED, NEVER CLIENT-SUPPLIED (this task's rule 2): the only
-- input this callback ever takes from the ASKING client is a
-- targetServerId (a number) -- the citizenid, name, callsign and handler
-- name all come from THIS server's own records for whoever that id
-- resolves to right now, exactly like server/wellbeing.lua's petK9/feedK9
-- resolve their own target identity server-side rather than trusting
-- anything the asking client claims. There is no field anywhere in this
-- callback's signature a modified client could use to claim a citizenid,
-- name or callsign that is not its own -- RECYCLED SERVER IDS are handled
-- the same way HasK9Role/every other per-source lookup in this file
-- already does: targetServerId -> exports.qbx_core:GetPlayer(...) ->
-- PlayerData.citizenid, resolved fresh on every call, never cached
-- against a source id across a session.
--
-- NOT A TRACKER (this task's rule 3): both peds' positions are read
-- server-side, right now, and the request is refused ('too_far') unless
-- the asking player is genuinely standing next to the target -- the exact
-- same server-authoritative distance re-check server/wellbeing.lua's
-- petK9/feedK9 already establish for this identical class of "the client
-- claims to be near something" concern (see K9_IDENTITY_INTERACT_RANGE
-- below). This can only ever answer about a K9 the caller could already
-- see and target; it adds no way to ask about a K9 anywhere else on the
-- map.
--
-- NEVER CONDITION/CERTIFICATION/POSITION (this task's rule 1): the
-- returned table has exactly four possible keys on success --
-- `ok`, `name`, `callsign`, `handlerName` -- and one more, `reason`, on
-- failure. No health, fatigue, mood/fear-stress value, certification
-- tier, specialization/detection capability or coordinate of anyone ever
-- goes in it. This is an identity surface, not a status readout -- the
-- same line this resource already drew for a K9's contraband-detection
-- ability (server/search.lua's own header) applies here identically.
--
-- DEGRADES CLEANLY (this task's rule 4): a K9 with no roster row, no
-- callsign and no partner -- the NORMAL case on a fresh server, since
-- Config.Features.CommandTablet's roster (server/roster.lua) is the ONLY
-- writer of a k9_personnel row and server/partnership.lua's Handler
-- Partnership is its own optional feature -- renders as just the K9's own
-- name, with `callsign`/`handlerName` both nil rather than blank strings
-- or the literal text "nil" (client/appearance.lua's own NotifyIdentity
-- only ever adds a line for a field that is actually a non-empty string).
--
-- CHEAP (this task's rule 5): one lib.callback round trip per "Identify
-- K9" selection -- never a poll, never per-frame. K9Store.Personnel_GetActiveRow
-- and GetActivePartnerCitizenId (server/partnership.lua's own read-only,
-- already-live in-memory cache) are both already-cheap, already-existing
-- reads this file adds no new caching layer in front of: the FIRST cache
-- in this whole path is client/appearance.lua's own ox_target canInteract
-- gate deciding whether the option is even offered, which happens for
-- free as part of hovering, not as a separate poll this file introduces.
--
-- DOES NOT DUPLICATE THE ROSTER'S OWN AUTHORIZATION (per this task's own
-- instruction): server/roster.lua's `qbx_k9unit:server:rosterList`
-- callback is HIGH-COMMAND-ONLY and returns the WHOLE roster -- the wrong
-- shape and the wrong authorization circle for "can a nearby officer read
-- ONE already-visible K9's own callsign". K9Store.Personnel_GetActiveRow
-- (server/datastore.lua) is the narrow, single-row, read-only accessor
-- server/roster.lua's own RosterAssignPersonnelRole/RosterSetCallsign
-- already call directly, and that file's own header states plainly that
-- these K9Store accessors carry NO baked-in authorization by design --
-- "reusable building blocks whose caller decides... who may call them".
-- This file is exactly that: a second, independent caller, deciding (per
-- this task's own brief) that ANY player standing next to an
-- already-visible, already-HasK9Role-confirmed K9 may read that one row --
-- not a bypass of roster.lua's own high-command gate, because that gate
-- was never meant to cover this narrower, already-public-by-design
-- question in the first place.
-- ======================================================================

-- Same physical range as server/wellbeing.lua's own MOOD_INTERACT_RANGE
-- (petK9/feedK9) -- "close enough to plausibly be looking at/talking to
-- this K9", not a tuned value specific to this feature.
local K9_IDENTITY_INTERACT_RANGE = 3.0

--- Bystander-facing display name for `citizenid`, resolved fresh (online
--- preferred, offline fallback) -- same "online first, offline qbx_core
--- export next" shape as server/roster.lua's own ResolveDisplayName
--- (this file's own established "each file keeps its own tiny copy"
--- convention -- see server/permissions.lua's header on why this resource
--- does not share small per-file helpers like this one across files with
--- no load-order relationship), with ONE deliberate difference: this NEVER
--- falls back to the raw citizenid string. server/roster.lua's own
--- fallback is safe there because that whole surface is HIGH-COMMAND-only;
--- this one reaches every bystander who merely looks at a K9, and a
--- citizenid is an internal database key, not something to hand to anyone
--- standing nearby. A name that is genuinely unresolvable (charinfo
--- missing on both an online AND an offline record, and the GetPlayerName
--- native also failing -- should not happen for a target confirmed online
--- a moment ago, but never assumed) shows a generic placeholder instead.
--- @param citizenid string
--- @return string
local function ResolveIdentityDisplayName(citizenid)
    local onlinePlayer = exports.qbx_core:GetPlayerByCitizenId(citizenid)
    if onlinePlayer and onlinePlayer.PlayerData then
        local charinfo = onlinePlayer.PlayerData.charinfo
        if type(charinfo) == 'table' and type(charinfo.firstname) == 'string' and type(charinfo.lastname) == 'string' then
            local full = (charinfo.firstname .. ' ' .. charinfo.lastname):match('^%s*(.-)%s*$')
            if type(full) == 'string' and full ~= '' then return full end
        end
        local onlineSrc = onlinePlayer.PlayerData.source
        if type(onlineSrc) == 'number' then
            local ok, viaNative = pcall(GetPlayerName, onlineSrc)
            if ok and type(viaNative) == 'string' and viaNative ~= '' then return viaNative end
        end
    end

    local ok, offlinePlayer = pcall(function() return exports.qbx_core:GetOfflinePlayer(citizenid) end)
    if ok and type(offlinePlayer) == 'table' and offlinePlayer.PlayerData then
        local charinfo = offlinePlayer.PlayerData.charinfo
        if type(charinfo) == 'table' and type(charinfo.firstname) == 'string' and type(charinfo.lastname) == 'string' then
            local full = (charinfo.firstname .. ' ' .. charinfo.lastname):match('^%s*(.-)%s*$')
            if type(full) == 'string' and full ~= '' then return full end
        end
    end

    return locale('appearance.identity_name_fallback')
end

--- The K9's roster callsign for THEIR CURRENT job, or nil -- nil covers
--- every "no callsign to show" case uniformly (no k9_personnel row at all,
--- a row that exists but was never given a callsign, or
--- Config.Features.CommandTablet having never been on so the table this
--- reads is simply empty for everyone): server/roster.lua's own
--- Personnel_GetActiveRow already returns nil for all of those, and this
--- function adds no special-casing on top of that. READ-ONLY, no
--- authorization check -- see this section's own header,
--- "DOES NOT DUPLICATE THE ROSTER'S OWN AUTHORIZATION", for why that is
--- the deliberate, narrower contract this call site needs, not an
--- oversight.
--- @param citizenid string
--- @param jobName string?
--- @return string?
local function ResolveIdentityCallsign(citizenid, jobName)
    if type(jobName) ~= 'string' or jobName == '' then return nil end
    if type(K9Store) ~= 'table' or type(K9Store.Personnel_GetActiveRow) ~= 'function' then return nil end

    local ok, row = pcall(K9Store.Personnel_GetActiveRow, citizenid, jobName)
    if not ok or type(row) ~= 'table' then return nil end
    if type(row.callsign) ~= 'string' or row.callsign == '' then return nil end
    return row.callsign
end

--- The K9's partnered handler's display name, or nil -- nil covers "no
--- active partnership", "Config.K9Identity.showHandlerName is off",
--- "server/partnership.lua did not load" and "citizenid is somehow the
--- HANDLER party, not the K9, in whatever partnership row exists"
--- uniformly, exactly like ResolveIdentityCallsign above does for its own
--- set of "nothing to show" cases. GetActivePartnerCitizenId
--- (server/partnership.lua) is a read-only accessor over that file's own
--- already-live in-memory cache -- no new DB read, no new poll.
--- @param citizenid string -- the K9's own citizenid
--- @return string?
local function ResolveIdentityHandlerName(citizenid)
    if not (Config.K9Identity and Config.K9Identity.showHandlerName == true) then return nil end
    if type(GetActivePartnerCitizenId) ~= 'function' then return nil end

    local partnerCitizenid, isK9 = GetActivePartnerCitizenId(citizenid)
    if isK9 ~= true then return nil end
    if type(partnerCitizenid) ~= 'string' or partnerCitizenid == '' then return nil end

    return ResolveIdentityDisplayName(partnerCitizenid)
end

--- Strips ASCII control characters and clamps length -- defense in depth
--- for a player-controllable string (a character's own charinfo name,
--- which this resource does not itself validate at creation time) before
--- it reaches ANOTHER player's screen via this bystander-facing payload.
--- Does not attempt to neutralise markdown syntax: the one client-side
--- renderer this reaches today (ox_lib's lib.notify) goes through
--- react-markdown with no rehype-raw plugin registered (checked directly
--- against ox_lib's own web/src/features/notifications/
--- NotificationWrapper.tsx and web/src/features/config/
--- MarkdownComponents.tsx source this pass), so markdown syntax in a name
--- renders as at most odd-looking formatting, never raw HTML/DOM
--- injection -- this is about keeping a malformed/oversized/
--- control-character-laden string from ever reaching another client at
--- all, not a workaround for an injection hole that was not found to
--- exist in the one renderer this ships against today.
--- @param value string?
--- @return string?
local function SanitizeIdentityDisplayString(value)
    if type(value) ~= 'string' then return nil end
    local cleaned = value:gsub('%c', '')
    cleaned = cleaned:match('^%s*(.-)%s*$')
    if cleaned == '' then return nil end
    if #cleaned > 48 then cleaned = cleaned:sub(1, 48) end
    return cleaned
end

--- CALLBACK -- qbx_k9unit:server:k9Identity. See this section's own header
--- for the full design; this is the one entry point that ties the pieces
--- above together.
--- @param source number -- the ASKING client
--- @param targetServerId number
--- @return table -- { ok = true, name: string, callsign: string?, handlerName: string? } | { ok = false, reason: string }
lib.callback.register('qbx_k9unit:server:k9Identity', function(source, targetServerId)
    if not (Config.K9Identity and Config.K9Identity.enabled == true) then
        return { ok = false, reason = 'disabled' }
    end
    if type(targetServerId) ~= 'number' then
        return { ok = false, reason = 'invalid_target' }
    end

    local askingPed = GetPlayerPed(source)
    local targetPed = GetPlayerPed(targetServerId)
    if askingPed == 0 or targetPed == 0 or targetPed == askingPed then
        return { ok = false, reason = 'invalid_target' }
    end

    -- SAME server-authoritative pattern as server/wellbeing.lua's petK9/
    -- feedK9: never trust the asking client's own idea of distance -- both
    -- peds' positions are read fresh, server-side, right now. This is what
    -- keeps this feature from ever being a tracker (this task's rule 3):
    -- it can only ever answer about a K9 the caller is genuinely standing
    -- next to.
    local dist = #(GetEntityCoords(askingPed) - GetEntityCoords(targetPed))
    if dist > K9_IDENTITY_INTERACT_RANGE then
        return { ok = false, reason = 'too_far' }
    end

    -- Server-authoritative "is this even a K9 right now" gate -- the SAME
    -- HasK9Role this whole file's role/model decoupling already treats as
    -- ground truth (see this file's own header). Refusing here means a
    -- modified client cannot use this callback to fish for the identity of
    -- an ordinary bystander it merely dressed up an ox_target option for.
    if not HasK9Role(targetServerId) then
        return { ok = false, reason = 'not_k9' }
    end

    -- CLIENT CANNOT SELF-LABEL AS SOMEONE ELSE'S DOG (this task's rule 2):
    -- targetServerId is the ONLY thing this callback ever takes from the
    -- asking client; everything below is resolved fresh from THIS
    -- server's own qbx_core player record for whoever that id currently
    -- belongs to. There is no citizenid/name/callsign argument anywhere in
    -- this signature for a modified client to smuggle a different
    -- identity through.
    local Player = exports.qbx_core:GetPlayer(targetServerId)
    local citizenid = Player and Player.PlayerData and Player.PlayerData.citizenid
    if type(citizenid) ~= 'string' or citizenid == '' then
        return { ok = false, reason = 'invalid_target' }
    end

    local jobName = Player.PlayerData.job and Player.PlayerData.job.name

    return {
        ok = true,
        name = SanitizeIdentityDisplayString(ResolveIdentityDisplayName(citizenid)) or locale('appearance.identity_name_fallback'),
        callsign = SanitizeIdentityDisplayString(ResolveIdentityCallsign(citizenid, jobName)),
        handlerName = SanitizeIdentityDisplayString(ResolveIdentityHandlerName(citizenid)),
    }
end)
