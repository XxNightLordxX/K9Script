--[[
    john-k9/server/roster.lua

    K9 COMMAND TABLET ROSTERS -- data layer + server logic (docs/history/ROSTER_SPEC.md,
    PHASE A). Owner's own words for the request this answers: "make it in
    the tablet where there is a roster where we can assign callsigns see
    list of hired k9s and full menu to fire promote etc", "Also a separate
    roster for handlers same thing", "The roster should be able to be
    where we can also assign roles sub features features permissions etc",
    "Also in the roster be able to reorder them by rank."

    WHAT THIS FILE OWNS: two roster LISTS (K9, Handler) plus an explicit
    "Unassigned" bucket (docs/history/ROSTER_SPEC.md §3/§5/§8), each row backed by the
    new `k9_personnel` table (migration 0020) layered over the existing
    `k9_certifications` data server/certifications//server/tablet.lua
    already own -- and the mutations that change a row's roster
    role/callsign. This file registers its OWN `john-k9:server:roster*`
    lib.callback endpoints -- it does NOT add anything to
    server/tablet.lua, which is being edited concurrently by another pass.

    WHAT THIS FILE DELIBERATELY DOES NOT DO (PHASE A SCOPE CUT, STATED
    PLAINLY): it does not change `GrantCertificationForTablet`'s signature,
    and it does not wire a Hire/Fire/Promote/Demote button anywhere --
    server/certifications/ is being edited concurrently by another pass
    and is out of scope here. docs/history/ROSTER_SPEC.md §3 says
    `GrantCertificationForTablet` should gain a required `personnelRole`
    parameter at hire time; this file does not make that change. Instead
    it exposes `RosterAssignPersonnelRole` (below) as a GLOBAL, reusable
    core function with its OWN, independent authorization contract, so a
    later, serialized pass can call it directly from inside
    `GrantCertificationForTablet` once that function gains its own
    `personnelRole` parameter -- see that function's own doc comment for
    exactly why its authorization circle is deliberately WIDER than a
    standalone roster mutation's. The exact signature this file needs
    landed there: `GrantCertificationForTablet(granterSrc, citizenid,
    departmentKey, personnelRole)` -- a fourth, required argument, threaded
    through to a call to `RosterAssignPersonnelRole(citizenid,
    departmentKey, personnelRole, <granter's citizenid>)` immediately after
    a successful grant (best-effort, non-fatal on its own failure, mirroring
    this file's own `ClearPersonnelRowForCitizenJob` doc comment on the
    identical "never gate a termination path" contract applied to the
    opposite, hiring, direction).

    Similarly, `RevokeCertificationForTablet` (docs/history/ROSTER_SPEC.md §1/§6's
    "closes the dead Decertify button gap") -- LANDED (verified by reading
    server/certifications/ directly): the wrapper this comment used to
    say was not yet written now exists there, and it does call
    `ClearPersonnelRowForCitizenJob` (below) immediately AFTER its own
    revoke succeeds, never before -- see that function's own doc comment.

    AUTHORIZATION -- THE SECURITY RULE, unchanged: every mutation this file
    exposes as a `lib.callback` re-verifies `IsHighCommand(source)` itself,
    live, on every call -- never a cached/client-claimed value
    (docs/history/ROSTER_SPEC.md §6's own table: "Who: High command" for every row).
    The CORE logic functions this file also exposes as globals
    (`RosterAssignPersonnelRole`, `RosterSetCallsign`,
    `ClearPersonnelRowForCitizenJob`) deliberately do NOT check
    authorization themselves -- see each one's own doc comment for why:
    they are reusable building blocks whose caller decides, and re-verifies,
    who may call them; this file's own `lib.callback` handlers are ONE such
    caller (the standalone roster-mutation gate, `IsHighCommand`), not the
    only one a future integration must use.

    RECYCLED SERVER IDS: every function in this file is keyed on citizenid,
    never a server id, resolving online-vs-offline state fresh at the
    moment of each call (`ResolveLiveJobName` below) -- this resource's
    established fix for exactly the "server ids get recycled" hazard.

    GATED THE SAME WAY server/tablet.lua GATES ITSELF --
    `Config.Features.CommandTablet` -- reusing that existing master flag
    rather than inventing a second one for what is still, functionally,
    one feature (the K9 Command Tablet). "Gate the START of a thing, never
    the STOP": this `return` happens once, at file-load time, before any
    `lib.callback.register` call below -- there is no code path in this
    file that re-checks the flag inside a handler and no way for it to
    silently stop a mutation already in flight.
]]

if not (Config.Features and Config.Features.CommandTablet == true) then return end

-- ======================================================================
-- SMALL LOCAL HELPERS -- each one a deliberate, small, per-file copy of a
-- pattern this resource already establishes elsewhere (server/tablet.lua's
-- own ResolveDisplayName/SafeStoreCall, server/certifications/'s own
-- IsDuplicateKeyError) -- see server/permissions.lua's own doc comment on
-- "each file keeps its own tiny copy" for why this resource does not share
-- these across files that otherwise have no load-order relationship.
-- ======================================================================

--- Mirrors server/tablet.lua's own SafeStoreCall -- pcall wraps a
--- K9Store.* accessor so a real DB failure degrades to a documented
--- fallback (nil/false/{}) rather than throwing out of a lib.callback
--- handler.
--- @param fn function
--- @return any
local function SafeStoreCall(fn, ...)
    local ok, resultOrErr = pcall(fn, ...)
    if not ok then
        print(('[John-K9] roster.lua K9Store call failed: %s'):format(tostring(resultOrErr)))
        return nil
    end
    return resultOrErr
end

--- Best-effort display name -- same "online first, offline qbx_core
--- export next, citizenid itself as the always-safe last resort" shape as
--- server/tablet.lua's own ResolveDisplayName.
--- @param citizenid string
--- @return string
local function ResolveDisplayName(citizenid)
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

    return citizenid
end

--- The target's LIVE department right now, resolved fresh (online
--- preferred, offline fallback), never a value captured earlier when a
--- roster/person screen was opened -- docs/history/ROSTER_SPEC.md §7's "resolve online
--- state fresh, from the citizenid, at call time" requirement, applied to
--- every mutation in this file exactly like `GrantCertificationForTablet`
--- already applies it to Hire.
--- @param citizenid string
--- @return string? -- the live job name, or nil if unresolvable at all
local function ResolveLiveJobName(citizenid)
    local onlinePlayer = exports.qbx_core:GetPlayerByCitizenId(citizenid)
    if onlinePlayer and onlinePlayer.PlayerData and type(onlinePlayer.PlayerData.job) == 'table' then
        return onlinePlayer.PlayerData.job.name
    end

    local ok, offlinePlayer = pcall(function() return exports.qbx_core:GetOfflinePlayer(citizenid) end)
    if ok and type(offlinePlayer) == 'table' and offlinePlayer.PlayerData and type(offlinePlayer.PlayerData.job) == 'table' then
        return offlinePlayer.PlayerData.job.name
    end

    return nil
end

--- @param citizenid string
--- @return table? -- { gradeLabel: string?, gradeLevel: number? } | nil if no resolvable job
local function ResolveJobGradeSummary(citizenid)
    local player = exports.qbx_core:GetPlayerByCitizenId(citizenid)
    if not (player and player.PlayerData) then
        local ok, offlinePlayer = pcall(function() return exports.qbx_core:GetOfflinePlayer(citizenid) end)
        if ok and type(offlinePlayer) == 'table' then player = offlinePlayer end
    end

    local job = player and player.PlayerData and player.PlayerData.job
    if type(job) ~= 'table' then return nil end

    local gradeLabel = (type(job.grade) == 'table' and type(job.grade.name) == 'string') and job.grade.name or nil
    local gradeLevel = (type(job.grade) == 'table' and type(job.grade.level) == 'number') and job.grade.level or nil
    return { gradeLabel = gradeLabel, gradeLevel = gradeLevel }
end

--- DB-authoritative partner summary -- mirrors server/tablet.lua's own
--- ResolvePartnershipInfo (works for an offline target, unlike
--- server/partnership.lua's online-only in-memory cache).
--- @param citizenid string
--- @return table? -- { citizenid: string, name: string } | nil
local function ResolvePartnerSummary(citizenid)
    if not (Config.Features and Config.Features.HandlerPartnership == true) then return nil end

    local row = SafeStoreCall(K9Store.Partner_GetActiveRowByParty, citizenid)
    if type(row) ~= 'table' then return nil end

    local isK9 = row.k9_citizenid == citizenid
    local partnerCitizenid = isK9 and row.handler_citizenid or row.k9_citizenid
    if type(partnerCitizenid) ~= 'string' or partnerCitizenid == '' then return nil end

    return { citizenid = partnerCitizenid, name = ResolveDisplayName(partnerCitizenid) }
end

--- Looks up a certification tier key's label/ordinal from
--- `Config.CertificationTiers` -- the SAME sort key docs/history/ROSTER_SPEC.md §9
--- names as the roster's default sort ("certification tier ordinal,
--- descending... the one 'rank' concept both rosters already share
--- identically").
--- @param tierKey string?
--- @return table? -- { label: string, ordinal: number } | nil
local function ResolveTierMeta(tierKey)
    if type(tierKey) ~= 'string' or type(Config.CertificationTiers) ~= 'table' then return nil end
    for _, tier in ipairs(Config.CertificationTiers) do
        if type(tier) == 'table' and tier.key == tierKey then
            return {
                label = type(tier.label) == 'string' and tier.label or tierKey,
                ordinal = type(tier.ordinal) == 'number' and tier.ordinal or 0,
            }
        end
    end
    return nil
end

--- Sibling of server/certifications/'s own IsDuplicateKeyError -- same
--- "each file keeps its own tiny copy" convention that file's own doc
--- comment already documents, checking `err.errno == 1062` first, before
--- ever inspecting a message string, so it recognizes BOTH a real MySQL
--- duplicate-key error and server/datastore.lua's own memory-mode
--- `ThrowDuplicateActiveRow`/`ThrowDuplicateCallsign` throws identically.
--- @param err any
--- @return boolean
local function IsDuplicateKeyError(err)
    return type(err) == 'table' and err.errno == 1062
end

--- @param value any
--- @return boolean
local function IsValidPersonnelRole(value)
    return value == 'k9' or value == 'handler'
end

-- Callsign format (docs/history/ROSTER_SPEC.md §4): plain text, clamped 1-12
-- characters, restricted to letters, digits, spaces and hyphens SERVER
-- SIDE. Hardcoded literals, not read from Config -- docs/history/ROSTER_SPEC.md §4
-- explicitly says "clamp-and-warn IF Config ever exposes this as
-- configurable -- not asserted" -- it does not today, so there is nothing
-- to clamp-and-warn against yet; if a future pass adds a Config knob for
-- this, that pass must resolve it the same clamp-and-warn way every other
-- operator-editable numeric setting in this resource already is, never a
-- bare assert.
local CALLSIGN_MIN_LENGTH = 1
local CALLSIGN_MAX_LENGTH = 12

--- An explicit ALLOWLIST, not a blocklist -- docs/history/ROSTER_SPEC.md §4 calls for a
--- narrow, predictable character set for a dispatch-style callsign, not
--- merely "nothing dangerous". This is a UX/sanity bound layered ON TOP OF
--- this codebase's existing `.textContent`-only rendering discipline
--- (a UI-layer concern owned by html/tablet.js, not this file) -- never a
--- substitute for it.
--- @param value any
--- @return boolean
local function IsValidCallsignFormat(value)
    if type(value) ~= 'string' then return false end
    local len = #value
    if len < CALLSIGN_MIN_LENGTH or len > CALLSIGN_MAX_LENGTH then return false end
    return value:find('^[%a%d %-]+$') ~= nil
end

-- ======================================================================
-- COOLDOWNS -- own copies, same shape as server/tablet.lua's
-- TabletReadCooldown/TABLET_READ_COOLDOWN_MS, matching this file's own
-- "no shared mutable state across files with no load-order relationship"
-- convention. Hardcoded local constants (never a raw Config value passed
-- straight through), so NewCooldown's own AssertValidDefaultThreshold is
-- the right guard here, not ResolveConfiguredThresholdMs -- see
-- server/cooldowns.lua's own header for exactly which shape gets which
-- guard.
-- ======================================================================
local ROSTER_READ_COOLDOWN_MS = 500
local ROSTER_MUTATE_COOLDOWN_MS = 750
local RosterReadCooldown = NewCooldown(ROSTER_READ_COOLDOWN_MS)
local RosterMutateCooldown = NewCooldown(ROSTER_MUTATE_COOLDOWN_MS)
-- Both keyed by player source ONLY (see the three .Consume(source, ...)
-- call sites below) -- RegisterPlayerDropped, not StartSweep, is the
-- correct hook per server/cooldowns.lua's own header. Without this, a
-- disconnecting source's entry lived forever, and since FXServer RECYCLES
-- server ids, a brand-new player could inherit a stale "still on cooldown"
-- timestamp from a completely different prior player on their very first
-- roster read/mutate -- matches server/tablet.lua's own
-- TabletReadCooldown.RegisterPlayerDropped() precedent for the identical
-- source-keyed shape.
RosterReadCooldown.RegisterPlayerDropped()
RosterMutateCooldown.RegisterPlayerDropped()

-- Bounded, fixed fetch cap per department -- this callback is
-- high-command-only (never a base-rank browse surface), so a generous,
-- fixed ceiling is the right shape here, matching ONLINE_PLAYERS_ROW_CAP's
-- own "fixed, not config-driven" precedent in server/tablet.lua rather
-- than a caller-influenced value.
local ROSTER_FETCH_CAP = 500

--- One roster row's full payload -- docs/history/ROSTER_SPEC.md §5's "K9 roster row" /
--- "Handler roster row" (identical shape) / "Unassigned" row shapes,
--- unioned into one superset object (the Unassigned rows simply carry
--- `personnelRole = nil`/`callsign = nil` and are otherwise identical) so
--- the eventual UI pass has one row shape to render across all three
--- buckets rather than three.
--- @param citizenid string
--- @param jobKey string
--- @param deptLabel string
--- @param personnelRole string? -- 'k9' | 'handler' | nil (Unassigned)
--- @param callsign string?
--- @param certifiedSince string? -- k9_certifications.granted_at
--- @return table
local function BuildRosterRow(citizenid, jobKey, deptLabel, personnelRole, callsign, certifiedSince)
    local tierKey, tierLabel, tierOrdinal = nil, nil, 0
    if type(QueryCertificationRecord) == 'function' then
        local ok, record = pcall(QueryCertificationRecord, citizenid, jobKey)
        if ok and type(record) == 'table' then
            tierKey = record.tier
            local meta = ResolveTierMeta(tierKey)
            if meta then
                tierLabel, tierOrdinal = meta.label, meta.ordinal
            end
        end
    end

    local xp = nil
    if Config.Features and Config.Features.XPProgression == true and type(GetXP) == 'function' then
        xp = GetXP(citizenid)
    end

    local partner = ResolvePartnerSummary(citizenid)
    local grade = ResolveJobGradeSummary(citizenid)

    -- Informational, non-authoritative only (docs/history/ROSTER_SPEC.md §1/§3) --
    -- never the thing that decided which bucket this row is in.
    local pinnedDogModel = nil
    if type(IsPinnedDogCharacter) == 'function' then
        local ok, pinned = pcall(IsPinnedDogCharacter, citizenid)
        if ok and pinned == true and type(GetPinnedDogCharacterModel) == 'function' then
            local okModel, model = pcall(GetPinnedDogCharacterModel, citizenid)
            pinnedDogModel = (okModel and type(model) == 'string') and model or true
        end
    end

    return {
        citizenid = citizenid,
        name = ResolveDisplayName(citizenid),
        departmentKey = jobKey,
        departmentLabel = deptLabel,
        personnelRole = personnelRole,
        callsign = callsign,
        tierKey = tierKey,
        tierLabel = tierLabel,
        tierOrdinal = tierOrdinal,
        xp = xp,
        partnerCitizenid = partner and partner.citizenid or nil,
        partnerName = partner and partner.name or nil,
        gradeLabel = grade and grade.gradeLabel or nil,
        gradeLevel = grade and grade.gradeLevel or nil,
        certifiedSince = certifiedSince,
        pinnedDogModel = pinnedDogModel,
    }
end

--- Default sort (docs/history/ROSTER_SPEC.md §9): certification tier ordinal,
--- descending, ties broken by name. Alternate sorts (grade, XP) are pure
--- client-side re-sorts of this already-fetched row list -- no additional
--- server round trip, per acceptance criterion #13; this function is only
--- ever the FIRST sort a fresh fetch is returned in.
--- @param rows table[]
local function SortRosterRowsDefault(rows)
    table.sort(rows, function(a, b)
        if a.tierOrdinal ~= b.tierOrdinal then return a.tierOrdinal > b.tierOrdinal end
        return a.name < b.name
    end)
end

-- ======================================================================
-- CORE LOGIC -- exposed as GLOBAL, resource-wide functions, DELIBERATELY
-- WITHOUT their own authorization check (see this file's own header for
-- the full "why"). Every `lib.callback` handler below is ONE caller of
-- these, re-verifying `IsHighCommand(source)` itself before calling in.
-- ======================================================================

--- Assigns a currently-Unassigned, actively-certified citizenid to a
--- roster role, OR changes an already-assigned citizenid's role
--- (clearing their callsign in the same action -- docs/history/ROSTER_SPEC.md §4: a K9
--- callsign and a handler callsign mean different things, so the old one
--- is never silently relabelled as the new kind).
---
--- DOES NOT CHECK AUTHORIZATION ITSELF. This is the "personnel row can be
--- created independently" hook this file's own header describes: a
--- future `GrantCertificationForTablet` integration (once that function
--- gains its own required `personnelRole` parameter) would call this
--- directly from ITS OWN already-verified certifier authority
--- (`IsEligibleCertifier`, a BROADER gate than `IsHighCommand` -- a
--- department's configured `certifierGrade` rank, OR the `k9.certify`
--- permission, OR High Command, any one of which is enough to Hire) --
--- deliberately a WIDER circle of callers than a standalone roster
--- mutation gets (this file's own `lib.callback` handler below narrows
--- that back down to High Command only, per docs/history/ROSTER_SPEC.md §6's table).
--- Guard any future cross-file call site with
--- `type(RosterAssignPersonnelRole) == 'function'`, this resource's
--- standard soft-dependency convention.
---
--- @param citizenid string
--- @param job string -- Config.Departments key
--- @param personnelRole string -- 'k9' | 'handler'
--- @param actorCitizenid string -- citizenid recorded as `granted_by` on a fresh assignment
--- @return boolean ok
--- @return string outcome -- ok=true: 'assigned' | 'role_changed' | 'unchanged'.
---   ok=false: 'invalid_target' | 'invalid_department' | 'invalid_personnel_role' |
---   'department_mismatch' | 'not_certified' | 'already_assigned' | 'db_error'
function RosterAssignPersonnelRole(citizenid, job, personnelRole, actorCitizenid)
    if type(citizenid) ~= 'string' or citizenid == '' or type(job) ~= 'string' or job == '' then
        return false, 'invalid_target'
    end
    if type(Config.Departments) ~= 'table' or not Config.Departments[job] then
        return false, 'invalid_department'
    end
    if not IsValidPersonnelRole(personnelRole) then
        return false, 'invalid_personnel_role'
    end

    -- docs/history/ROSTER_SPEC.md §7: refuse a stale-department write server-side,
    -- exactly like GrantCertificationForTablet/SetCertificationTierForTablet
    -- already do -- never silently substitute the operator's clicked
    -- department for the target's real, live one.
    if ResolveLiveJobName(citizenid) ~= job then
        return false, 'department_mismatch'
    end

    if not SafeStoreCall(K9Store.Cert_GetActiveId, citizenid, job) then
        return false, 'not_certified'
    end

    local existing = SafeStoreCall(K9Store.Personnel_GetActiveRow, citizenid, job)
    if type(existing) == 'table' then
        if existing.role == personnelRole then
            return true, 'unchanged'
        end
        local ok, affectedOrErr = pcall(K9Store.Personnel_UpdateRole, citizenid, job, personnelRole)
        if not ok then
            print(('[John-K9] roster: Personnel_UpdateRole failed for %s::%s: %s'):format(citizenid, job, tostring(affectedOrErr)))
            return false, 'db_error'
        end
        return true, 'role_changed'
    end

    local ok, idOrErr = pcall(K9Store.Personnel_Insert, citizenid, job, personnelRole, actorCitizenid)
    if not ok then
        if IsDuplicateKeyError(idOrErr) then
            return false, 'already_assigned'
        end
        print(('[John-K9] roster: Personnel_Insert failed for %s::%s: %s'):format(citizenid, job, tostring(idOrErr)))
        return false, 'db_error'
    end
    return true, 'assigned'
end

--- Assigns/changes/clears a citizenid's callsign on their active roster
--- row. Same "does not check authorization itself" contract as
--- `RosterAssignPersonnelRole` above -- see that function's own doc
--- comment.
---
--- Uniqueness is checked COMBINED-NAMESPACE, per department, case
--- insensitively (docs/history/ROSTER_SPEC.md §4) -- a K9's callsign and a handler's
--- callsign in the SAME department share one namespace. Checked twice, on
--- purpose: once here (an accurate, immediate, specific
--- `'callsign_taken'` outcome for the ordinary case) and once more at the
--- DB level via `k9_personnel.uq_one_active_callsign_per_job`
--- (`K9Store.Personnel_SetCallsign`'s own possible throw, caught below) --
--- the same defense-in-depth, check-then-write-plus-race-backstop pattern
--- this schema already uses for `k9_certifications`' own
--- `uq_one_active_cert_per_job`.
---
--- @param citizenid string
--- @param job string
--- @param callsign string? -- nil or '' clears the callsign
--- @return boolean ok
--- @return string outcome -- ok=true: 'callsign_set' | 'callsign_cleared'.
---   ok=false: 'invalid_target' | 'department_mismatch' | 'no_active_personnel' |
---   'invalid_callsign' | 'callsign_taken' | 'db_error'
function RosterSetCallsign(citizenid, job, callsign)
    if type(citizenid) ~= 'string' or citizenid == '' or type(job) ~= 'string' or job == '' then
        return false, 'invalid_target'
    end

    if ResolveLiveJobName(citizenid) ~= job then
        return false, 'department_mismatch'
    end

    local existing = SafeStoreCall(K9Store.Personnel_GetActiveRow, citizenid, job)
    if type(existing) ~= 'table' then
        return false, 'no_active_personnel'
    end

    local normalizedCallsign = callsign
    if normalizedCallsign == '' then normalizedCallsign = nil end

    if normalizedCallsign ~= nil then
        if not IsValidCallsignFormat(normalizedCallsign) then
            return false, 'invalid_callsign'
        end

        local needle = normalizedCallsign:lower()
        local jobRows = SafeStoreCall(K9Store.Personnel_GetActiveRowsByJob, job) or {}
        for _, row in ipairs(jobRows) do
            if row.citizenid ~= citizenid and type(row.callsign) == 'string' and row.callsign:lower() == needle then
                return false, 'callsign_taken'
            end
        end
    end

    local ok, affectedOrErr = pcall(K9Store.Personnel_SetCallsign, citizenid, job, normalizedCallsign)
    if not ok then
        if IsDuplicateKeyError(affectedOrErr) then
            return false, 'callsign_taken'
        end
        print(('[John-K9] roster: Personnel_SetCallsign failed for %s::%s: %s'):format(citizenid, job, tostring(affectedOrErr)))
        return false, 'db_error'
    end

    return true, (normalizedCallsign ~= nil and 'callsign_set' or 'callsign_cleared')
end

--- Best-effort `k9_personnel` row cleanup for a citizenid whose
--- certification was JUST revoked (Fire -- docs/history/ROSTER_SPEC.md §6/§7). PUBLIC,
--- GLOBAL, callable from a future `server/certifications/`
--- `RevokeCertificationForTablet` wrapper -- guard with
--- `type(ClearPersonnelRowForCitizenJob) == 'function'` at that call site.
---
--- NEVER CALL THIS BEFORE THE REVOKE ITSELF HAS ALREADY SUCCEEDED
--- (docs/history/ROSTER_SPEC.md §7: "Never gate a termination path"). This function
--- does not, and must not, re-check certification/authorization itself --
--- by the time it is called the certification is already gone, and the
--- citizenid has already stopped appearing on either roster regardless of
--- what this function does next: both roster reads in this file filter on
--- "active certification (via K9Store.Cert_GetActiveRosterByJobUnordered)
--- AND active personnel row", so a stray row this cleanup fails to clear
--- can never resurrect a fired citizenid's visible hired status. A
--- failure here is logged and reported honestly to the caller (mirrors
--- server/dogcharacter.lua's own `pin_db_error` pattern) but never rolled
--- back or retried automatically, and never blocks/undoes the revoke that
--- already succeeded.
--- @param citizenid string
--- @param job string
--- @param clearedBy string -- citizenid of the officer who fired them, or a 'system:...' sentinel
--- @return boolean ok
function ClearPersonnelRowForCitizenJob(citizenid, job, clearedBy)
    if type(citizenid) ~= 'string' or citizenid == '' or type(job) ~= 'string' or job == '' then
        return false
    end
    local ok, affectedOrErr = pcall(K9Store.Personnel_ClearActive, citizenid, job, clearedBy)
    if not ok then
        print(('[John-K9] roster: Personnel_ClearActive failed for %s::%s: %s'):format(citizenid, job, tostring(affectedOrErr)))
        return false
    end
    return true
end

-- ======================================================================
-- LIB.CALLBACK REGISTRATIONS -- this file's OWN callbacks, per the
-- coordinator's explicit instruction not to add these to
-- server/tablet.lua. Every one of these re-verifies `IsHighCommand(source)`
-- itself, live, on every call (THE SECURITY RULE) -- never a
-- client-supplied flag, never a value cached from an earlier request.
-- ======================================================================

--- CALLBACK -- john-k9:server:rosterList
--- High-command-only read. Returns every currently-hired K9, every
--- currently-hired Handler, and the "Unassigned" bucket (docs/history/ROSTER_SPEC.md
--- §3/§5/§8), across every configured department, each row already
--- default-sorted (certification tier ordinal descending, ties by name --
--- §9). Alternate sorts (grade, XP) are pure client-side re-sorts of this
--- same payload -- no second round trip.
lib.callback.register('john-k9:server:rosterList', function(source)
    local Player = exports.qbx_core:GetPlayer(source)
    local callerCitizenid = Player and Player.PlayerData and Player.PlayerData.citizenid
    if not callerCitizenid then
        return { ok = false, error = 'not_authorized' }
    end

    if not (type(IsHighCommand) == 'function' and IsHighCommand(source) == true) then
        return { ok = false, error = 'not_authorized' }
    end

    if not RosterReadCooldown.Consume(source, ROSTER_READ_COOLDOWN_MS) then
        return { ok = false, error = 'rate_limited' }
    end

    local k9Rows, handlerRows, unassignedRows = {}, {}, {}

    if type(Config.Departments) == 'table' then
        local jobKeys = {}
        for jobKey in pairs(Config.Departments) do jobKeys[#jobKeys + 1] = jobKey end
        table.sort(jobKeys)

        for _, jobKey in ipairs(jobKeys) do
            local dept = Config.Departments[jobKey]
            local deptLabel = (type(dept) == 'table' and type(dept.label) == 'string') and dept.label or jobKey

            -- docs/history/ROSTER_SPEC.md §7: "both roster queries must filter on
            -- active certification AND (personnel row, if any, also
            -- active)" -- the certification list below IS that filter;
            -- a citizenid never appears in any bucket without an active
            -- certification for this exact department, regardless of
            -- what its own k9_personnel row says.
            local certRows = SafeStoreCall(K9Store.Cert_GetActiveRosterByJobUnordered, jobKey, ROSTER_FETCH_CAP) or {}
            local personnelRows = SafeStoreCall(K9Store.Personnel_GetActiveRowsByJob, jobKey) or {}
            local personnelByCitizen = {}
            for _, prow in ipairs(personnelRows) do
                personnelByCitizen[prow.citizenid] = prow
            end

            for _, certRow in ipairs(certRows) do
                local personnel = personnelByCitizen[certRow.citizenid]
                local role = personnel and personnel.role or nil
                local row = BuildRosterRow(certRow.citizenid, jobKey, deptLabel, role,
                    personnel and personnel.callsign or nil, certRow.granted_at)

                if role == 'k9' then
                    k9Rows[#k9Rows + 1] = row
                elseif role == 'handler' then
                    handlerRows[#handlerRows + 1] = row
                else
                    unassignedRows[#unassignedRows + 1] = row
                end
            end
        end
    end

    SortRosterRowsDefault(k9Rows)
    SortRosterRowsDefault(handlerRows)
    SortRosterRowsDefault(unassignedRows)

    return { ok = true, k9 = k9Rows, handlers = handlerRows, unassigned = unassignedRows }
end)

--- CALLBACK -- john-k9:server:rosterSetPersonnelRole
--- payload: { citizenid: string, job: string, personnelRole: 'k9'|'handler' }
--- High-command-only. Wraps `RosterAssignPersonnelRole` with THE SECURITY
--- RULE's own re-verification, exactly as this file's header documents.
lib.callback.register('john-k9:server:rosterSetPersonnelRole', function(source, payload)
    local Player = exports.qbx_core:GetPlayer(source)
    local actorCitizenid = Player and Player.PlayerData and Player.PlayerData.citizenid
    if not actorCitizenid then
        return { ok = false, error = 'not_authorized' }
    end

    if not (type(IsHighCommand) == 'function' and IsHighCommand(source) == true) then
        return { ok = false, error = 'not_authorized' }
    end

    if not RosterMutateCooldown.Consume(source, ROSTER_MUTATE_COOLDOWN_MS) then
        return { ok = false, error = 'rate_limited' }
    end

    if type(payload) ~= 'table' then
        return { ok = false, error = 'invalid_target' }
    end

    local ok, outcome = RosterAssignPersonnelRole(payload.citizenid, payload.job, payload.personnelRole, actorCitizenid)

    print(('[John-K9] roster audit: %s -> personnel_role_change citizenid=%s job=%s role=%s ok=%s outcome=%s'):format(
        actorCitizenid, tostring(payload.citizenid), tostring(payload.job), tostring(payload.personnelRole), tostring(ok), tostring(outcome)))

    if ok then
        return { ok = true, outcome = outcome }
    end
    return { ok = false, error = outcome }
end)

--- CALLBACK -- john-k9:server:rosterSetCallsign
--- payload: { citizenid: string, job: string, callsign: string? }
--- High-command-only. Wraps `RosterSetCallsign` with THE SECURITY RULE's
--- own re-verification, exactly as this file's header documents.
lib.callback.register('john-k9:server:rosterSetCallsign', function(source, payload)
    local Player = exports.qbx_core:GetPlayer(source)
    local actorCitizenid = Player and Player.PlayerData and Player.PlayerData.citizenid
    if not actorCitizenid then
        return { ok = false, error = 'not_authorized' }
    end

    if not (type(IsHighCommand) == 'function' and IsHighCommand(source) == true) then
        return { ok = false, error = 'not_authorized' }
    end

    if not RosterMutateCooldown.Consume(source, ROSTER_MUTATE_COOLDOWN_MS) then
        return { ok = false, error = 'rate_limited' }
    end

    if type(payload) ~= 'table' then
        return { ok = false, error = 'invalid_target' }
    end

    local ok, outcome = RosterSetCallsign(payload.citizenid, payload.job, payload.callsign)

    print(('[John-K9] roster audit: %s -> callsign_change citizenid=%s job=%s ok=%s outcome=%s'):format(
        actorCitizenid, tostring(payload.citizenid), tostring(payload.job), tostring(ok), tostring(outcome)))

    if ok then
        return { ok = true, outcome = outcome }
    end
    return { ok = false, error = outcome }
end)
