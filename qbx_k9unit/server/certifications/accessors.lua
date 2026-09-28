--[[
    qbx_k9unit/server/certifications/accessors.lua

    The READ-ONLY accessors other resources and other files in this one
    call to ask about a certification, without being able to change it.

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

-- Re-bound from the shared K9Cert transport (see this file's own header).
-- Same names as in the original single file, so every body below is
-- unchanged.
local Certifications = K9Cert.Certifications
local EndK9AccessForCitizenId = K9Cert.EndK9AccessForCitizenId
local GetTierOrdinalOrLegacyFallback = K9Cert.GetTierOrdinalOrLegacyFallback
local IsCertRowConfirmedActive = K9Cert.IsCertRowConfirmedActive
local IsKnownTierKeyOrLegacyFallback = K9Cert.IsKnownTierKeyOrLegacyFallback
local RevokeAllSpecializationsForCitizenJob = K9Cert.RevokeAllSpecializationsForCitizenJob
local Specializations = K9Cert.Specializations

-- ======================================================================
-- READ-ONLY ACCESSORS (this pass) — exposed globally (no `local`) for
-- future Phase 2/3 gates (search.lua/combat.lua/defense.lua-style files,
-- none of which this pass reaches into — see header "TIER") and for
-- whichever file ends up owning the tablet's roster aggregation (see
-- header "CACHE SHAPE" / server/permissions.lua's own
-- ListActivePermissionsForCitizenId precedent for the identical
-- "expose an accessor, let another file aggregate" pattern).
-- ======================================================================

--- Cache-based, hot-path-safe: `citizenid`'s current tier for `jobName`,
--- or nil if not actively/matchingly certified (regardless of whether
--- that's because they were never certified, were revoked, or their
--- certification has lapsed — same "just say no capability" shape
--- HasK9Access already uses, not a 3-way distinction, for every caller that
--- omits `includeExpired`).
---
--- SECURITY FIX (coder-security, tier-bypass-on-expiry review) — added the
--- optional 3rd parameter `includeExpired` (does NOT change this function's
--- name or its existing 2-argument callers' behavior at all — every one of
--- them keeps getting exactly the collapsed "expired counts as no tier"
--- answer above): server/certtiers.lua's TierCapabilityPermits needs a
--- DIFFERENT answer than every other consumer. That function's own contract
--- is fail-PERMISSIVE when a citizenid's tier "cannot be resolved" —
--- deliberately, because HasK9Access grants access through THREE routes
--- this file cannot express as a tier at all (a 'k9.access' permission
--- grant, an autoAccessGrade job grade, or high command), and none of those
--- citizenids should ever be denied a capability just because this file has
--- no tier to name them by. But the 2-argument form ALSO returns nil for a
--- citizenid who very much DOES have a tier assignment — one whose
--- certification has simply EXPIRED — and folding that case into
--- "unresolvable" let an expired handler who still holds K9 access via one
--- of the other three routes silently regain any capability an operator
--- explicitly withheld from their assigned tier, on every ordinary
--- certification lapse, with no action from anyone. That is a STALE tier,
--- not an absent one — the underlying cache can tell the two apart because
--- `active` (a real, non-revoked k9_certifications row exists) and
--- `expired` (that row's expires_at has passed) are independent flags (see
--- RefreshCertificationCache's own doc comment). `includeExpired = true`
--- returns that real, assigned tier EVEN IF it has expired; nil, even with
--- `includeExpired = true`, means there truly is no active/job-matching row
--- at all (never certified for this job, or a manually revoked one) — the
--- ONLY population TierCapabilityPermits should still treat as
--- unresolvable-and-allowed. A non-nil result — stale or not — is what
--- TierCapabilityPermits must evaluate for real, never skip.
--- @param citizenid string
--- @param jobName string
--- @param includeExpired boolean? -- default false/nil: unchanged, original
--- behavior. true: also return an EXPIRED tier rather than folding it into
--- nil (see SECURITY FIX above).
--- @return string?
function GetCertificationTier(citizenid, jobName, includeExpired)
    local cached = Certifications[citizenid]
    if cached and cached.active and cached.job == jobName and (includeExpired or not cached.expired) then
        return cached.tier
    end
    return nil
end

--- Cache-based, hot-path-safe: does `citizenid` currently hold AT LEAST
--- `minTier` for `jobName`? Ordinal comparison via TIER_RANK — a future
--- Phase 2/3 gate calls this instead of duplicating the tier-ranking
--- logic itself. Fails closed on a nil actual tier (not certified) or an
--- unrecognized `minTier` (a typo'd tier name must never accidentally
--- open a gate; a malformed argument is a bug, not a low bar to clear).
--- @param citizenid string
--- @param jobName string
--- @param minTier string
--- @return boolean
function MeetsTierRequirement(citizenid, jobName, minTier)
    -- OWNER-DIRECTED TIER-EDITING PASS: ordinal comparison now defers to
    -- the live, operator-extensible catalog (server/certtiers.lua) via
    -- GetTierOrdinalOrLegacyFallback, so a future gate can compare
    -- against an operator-ADDED tier, not just the original three.
    if not IsKnownTierKeyOrLegacyFallback(minTier) then return false end

    -- HIGH COMMAND BYPASS (owner-directed, this pass -- "high command
    -- automatically gets every k9 upgrade"). This is the ONE OTHER live
    -- min-tier gate in this resource (server/equipmentshop.lua's own
    -- `entry.requiredTierKey` requirement, alongside
    -- `entry.requiredSpecialization` below, which HasSpecialization's own
    -- bypass covers) -- unlike server/certtiers.lua's TierCapabilityPermits,
    -- this function fails CLOSED for a citizenid with no certification row
    -- at all (an uncertified handler must not clear a minimum-tier bar by
    -- accident), so without an explicit bypass here a high-command officer
    -- who has never personally certified for this job would be denied an
    -- item ordinary Elite-tier officers can buy -- exactly the "grant one
    -- thing at a time" friction this pass exists to remove. Checked AFTER
    -- the `minTier` validity guard above (a caller-bug malformed minTier
    -- literal stays denied for everyone, high command included -- never a
    -- new way to paper over a bug in this file's own static shop catalog).
    -- Same `expectedJobName` scoping, same offline-citizenid answer
    -- (false -> falls through to the unchanged resolution below), same
    -- `type(...) == 'function'` soft-dependency guard as
    -- server/certtiers.lua's identical bypass -- see
    -- IsHighCommandBypassCitizenId's own doc comment (server/permissions.lua)
    -- for the full contract. NEVER GATES A TERMINATION PATH: this
    -- function's only real caller (server/equipmentshop.lua's buyItem hook)
    -- is a request-time purchase gate, not a cleanup/teardown path, and this
    -- edit adds no new call site.
    if type(IsHighCommandBypassCitizenId) == 'function' and type(citizenid) == 'string' and type(jobName) == 'string'
        and IsHighCommandBypassCitizenId(citizenid, jobName) then
        return true
    end

    local actualTier = GetCertificationTier(citizenid, jobName)
    if not IsKnownTierKeyOrLegacyFallback(actualTier) then return false end
    local actualOrdinal = GetTierOrdinalOrLegacyFallback(actualTier)
    local minOrdinal = GetTierOrdinalOrLegacyFallback(minTier)
    if not actualOrdinal or not minOrdinal then return false end
    return actualOrdinal >= minOrdinal
end

--- Cache-based, hot-path-safe: does `citizenid` currently hold
--- `specializationKey` for `jobName`? Also requires the BASE certification
--- to currently be active/matching/unexpired — see header "SPECIALIZATIONS":
--- an expired base certification softly disables its specializations too,
--- the same "stop granting NEW access, never force-detach" posture
--- HasK9Access already applies one level up.
--- @param citizenid string
--- @param jobName string
--- @param specializationKey string
--- @return boolean
function HasSpecialization(citizenid, jobName, specializationKey)
    -- HIGH COMMAND BYPASS (owner-directed, this pass -- "high command
    -- automatically gets every k9 upgrade"). Specializations are exactly
    -- the "k9 upgrade" a base certification alone does not carry (header
    -- "SPECIALIZATIONS") -- without this, a high-command officer with no
    -- active certification, or one whose cached specializations row simply
    -- never had this key set, is denied a capability every other rank gate
    -- in this resource already treats high command as automatically
    -- qualifying for. Checked BEFORE the cache read below, mirroring
    -- HasK9Access's own "checked before the cert-cache read... a genuine
    -- bypass, not merely an alternate cache hit" placement. Same
    -- `expectedJobName` scoping, same offline-citizenid answer (false ->
    -- falls through to the unchanged cache read below), same
    -- `type(...) == 'function'` soft-dependency guard as
    -- server/certtiers.lua's TierCapabilityPermits/this file's own
    -- MeetsTierRequirement, both given the identical bypass this same pass
    -- -- see IsHighCommandBypassCitizenId's own doc comment
    -- (server/permissions.lua) for the full contract. NEVER GATES A
    -- TERMINATION PATH: this function's only real caller
    -- (server/equipmentshop.lua's buyItem hook, `entry.requiredSpecialization`)
    -- is a request-time purchase gate, and this edit adds no new call site
    -- -- GrantSpecialization's own grant-time TierCapabilityPermits check
    -- (server/certtiers.lua, this same pass) is a SEPARATE function this
    -- edit does not touch.
    if type(IsHighCommandBypassCitizenId) == 'function' and IsHighCommandBypassCitizenId(citizenid, jobName) then
        return true
    end

    if not HasSpecializationGranted(citizenid, jobName, specializationKey) then return false end
    -- ROLES (server/roles.lua): a role only counts once it still exists and
    -- this person's XP has reached its requirement.
    if type(IsRoleXpUnlocked) == 'function' and not IsRoleXpUnlocked(citizenid, specializationKey) then return false end
    return true
end

--- True when this person has been GIVEN the role (active, unexpired
--- certification in this job, role granted), whether or not their XP has
--- reached it yet -- HasSpecialization above is the "does it count" check.
--- Used to tell someone "you have it, it unlocks at N XP" rather than
--- "you don't have it".
--- @param citizenid string @param jobName string @param specializationKey string
--- @return boolean
function HasSpecializationGranted(citizenid, jobName, specializationKey)
    local cached = Certifications[citizenid]
    if not (cached and cached.active and cached.job == jobName and not cached.expired) then return false end
    local jobSpecs = Specializations[citizenid] and Specializations[citizenid][jobName]
    return jobSpecs ~= nil and jobSpecs[specializationKey] == true
end

--- DB-authoritative (works for an OFFLINE citizenid too, unlike the
--- cache-based accessors above — for tablet/roster/admin reads, mirroring
--- server/permissions.lua's own ListActivePermissionsForCitizenId
--- precedent). Fails closed (returns nil) on a query error or an
--- unreadable citizenid, matching this file's own established SafeQuery
--- posture.
--- @param citizenid string
--- @param jobName string
--- @return table? record -- { tier, grantedBy, grantedAt, revokedBy, revokedAt, revokeReason, expiresAtUnix, specializations: string[] } for the active row, or nil if none
function QueryCertificationRecord(citizenid, jobName)
    if type(citizenid) ~= 'string' or citizenid == '' or type(jobName) ~= 'string' or jobName == '' then return nil end

    local ok, row = pcall(K9Store.Cert_GetActiveRecord, citizenid, jobName)
    if not ok or not row then
        if not ok then
            print(('[qbx_k9unit] QueryCertificationRecord query failed for %s/%s: %s'):format(citizenid, jobName, tostring(row)))
        end
        return nil
    end

    return {
        tier = row.tier,
        grantedBy = row.granted_by,
        grantedAt = row.granted_at,
        revokedBy = row.revoked_by,
        revokedAt = row.revoked_at,
        revokeReason = row.revoke_reason,
        expiresAtUnix = tonumber(row.expires_at_unix),
        specializations = QueryActiveSpecializations(citizenid, jobName),
    }
end

--- DB-authoritative list of every specialization key `citizenid` currently
--- holds for `jobName` — see QueryCertificationRecord's own doc comment
--- for the "works offline, fails closed" contract this shares.
--- @param citizenid string
--- @param jobName string
--- @return string[]
function QueryActiveSpecializations(citizenid, jobName)
    if type(citizenid) ~= 'string' or citizenid == '' or type(jobName) ~= 'string' or jobName == '' then return {} end

    local ok, rows = pcall(K9Store.Spec_GetActiveKeys, citizenid, jobName)
    if not ok then
        print(('[qbx_k9unit] QueryActiveSpecializations query failed for %s/%s: %s'):format(citizenid, jobName, tostring(rows)))
        return {}
    end

    local out = {}
    for i, row in ipairs(rows or {}) do
        out[i] = row.specialization
    end
    return out
end

--- WORKFLOW CLARITY (this pass, item 4 — "a job change is the invisible
--- one... whatever happens, both the person and the actor should be able
--- to understand it afterwards"). QBCore:Server:OnJobUpdate carries no
--- identity for WHO changed the job (a boss menu, an admin command, a
--- promotion script — the event signature is just `(source, job)`), so
--- there is no live "actor" `source` this file could ever NotifyPlayer
--- directly — the only channel available to "the actor" here is the
--- server console/log, which whoever performed the change (or an admin
--- reviewing it afterward) can actually read. One shared, consistently-
--- shaped audit line for every branch of the handler below that actually
--- ends K9-role access as a result of a job change, mirroring this file's
--- own LogTabletCertAuditInvocation convention (a single, greppable
--- `[qbx_k9unit] AUDIT:` prefix) rather than three independently-worded
--- prints that could drift.
--- @param citizenid string
--- @param detail string -- e.g. 'left eligible department (held a k9.access permission grant); new job=police-retired'
local function LogJobChangeEndedK9Access(citizenid, detail)
    print(('[qbx_k9unit] AUDIT: job change ended K9 access for citizenid=%s: %s'):format(citizenid, detail))
end

--- DEVELOPER_REFERENCE.md §4.4 (NEW): automatic revoke when actually leaving the
--- department (not on a same-department grade change). Server-only path —
--- never exposed as a client-callable event.
--- @param source number
--- @param job table  -- new PlayerJob object, per qbx_core's event payload
AddEventHandler('QBCore:Server:OnJobUpdate', function(source, job)
    local Player = exports.qbx_core:GetPlayer(source)
    if not Player or not Player.PlayerData then return end

    local citizenid = Player.PlayerData.citizenid

    -- Regression-test fix: SECOND, INDEPENDENT check from the
    -- certification-revocation branch below — an officer/handler leashed
    -- to a K9 never holds a K9 certification of their own (DEVELOPER_REFERENCE.md §9 item
    -- 9: their access is pure Config.Departments membership, not a cert),
    -- so the cert-revocation branch below (gated on `cached.active`) can
    -- never observe them losing eligibility. If this citizenid's NEW job no
    -- longer satisfies Config.Departments membership, force-detach any
    -- leash where `source` is currently the officer-role party — this is
    -- not a variant of the cert-revoke path, it's a wholly separate
    -- eligibility loss (department membership, not certification) that
    -- CheckLeashEligibility in server/main.lua already refuses on
    -- re-attach, so an already-formed pairing must not be allowed to
    -- outlive it either. See server/main.lua's ForceDetachOfficerLeashForSource
    -- for the role check (only actually detaches if `source` is the
    -- officer/handler-role, not K9-role, party of its pairing).
    if not job or not Config.Departments[job.name] then
        ForceDetachOfficerLeashForSource(source, 'department_changed')

        -- FIFTH-GAP FIX (this pass -- "four doors, one bug", closing the
        -- fifth): this branch used to stop at the ForceDetachOfficerLeashForSource
        -- call above, which only ever detaches `source` when they are
        -- currently the OFFICER/handler-role party of a pairing. It never
        -- checked the OTHER role: `source` currently being the K9-ROLE
        -- party. HasK9Access(source) (this file, above) hard-gates on
        -- `Config.Departments[job.name]` as its VERY FIRST check, before
        -- the permission-grant bypass, the high-command bypass, the
        -- cert-cache read, or the autoAccessGrade bypass are ever
        -- consulted -- so losing department membership entirely means
        -- HasK9Access is now unconditionally false for `source`, REGARDLESS
        -- of which route (an active certification, a server/permissions.lua
        -- 'k9.access' grant, or an autoAccessGrade rank) used to grant it.
        -- A K9-role party whose ONLY route was a certification is already
        -- covered further below (the cert-revoke-due-to-job-change branch,
        -- gated on `cached.active`) -- but a K9-role party with NO
        -- certification row at all (autoAccessGrade- or permission-grant-
        -- only access) has no active row in `Certifications` for that
        -- branch to ever observe, so it never fires for them, and until
        -- this fix nothing else in this handler did either: they kept
        -- their leash, an in-progress bite-hold/takedown/drag, and any
        -- partnership indefinitely on leaving the department entirely --
        -- the exact "handler loses K9 access mid-incident and their dog
        -- keeps holding a suspect" shape this file already closes for a
        -- certification loss, reached through the one door that was still
        -- open. EndK9AccessForCitizenId (this file, above) is UNCONDITIONAL
        -- here, never re-gated on "does source currently hold K9-role
        -- access via some other route" -- there is no other route left to
        -- check: department membership loss alone already makes
        -- HasK9Access false for every route at once (see the hard gate
        -- described above), so this cannot collide with the SEPARATE
        -- same-department autoAccessGrade-demotion branch below (which
        -- DOES need its own "does the new job still grant non-cert access"
        -- computation, because THAT branch's job still passes
        -- Config.Departments membership) or with the job-name-change
        -- cert-revoke branch's own DB-write reconciliation dance (this
        -- branch performs no DB write of its own at all -- it is pure,
        -- unconditional teardown of ephemeral/session state, same as the
        -- officer-role call directly above it always has been). `source`
        -- is already live here (OnJobUpdate fired for it), so passed
        -- directly as `knownSrc`. See EndK9AccessForCitizenId's own doc
        -- comment for the full three-call (leash/hold/partnership)
        -- writeup, and this file's header FILE-TO-FILE CONTRACT section
        -- for this branch's place in the "five known call sites, one
        -- fixed this pass" history.
        EndK9AccessForCitizenId(citizenid, 'department_changed', source)

        -- WORKFLOW CLARITY (this pass, item 4) -- this branch runs for
        -- EVERY employee who leaves an eligible department, the overwhelming
        -- majority of whom never touched K9 features at all; notifying every
        -- one of them "your K9 access ended" would be noise for people who
        -- never had any. Scoped to the ONE case this file CAN verify after
        -- the fact without a second tracking cache: a citizenid who holds a
        -- 'k9.access' PERMISSION GRANT (server/permissions.lua) -- unlike a
        -- job-grade-based autoAccessGrade bypass, a permission grant is NOT
        -- job-scoped, so it is still checkable here even though `job` is
        -- already the NEW one. DISCLOSED, NARROW RESIDUAL WINDOW: a
        -- citizenid whose ONLY route was autoAccessGrade (no cert, no
        -- permission grant) still loses access here (EndK9AccessForCitizenId
        -- above is unconditional) but is NOT told why, since their old
        -- job's grade is no longer available to check once `job` has already
        -- become the new one -- the same class of gap this file's own
        -- "SCOPED DELIBERATELY NARROW" comment a few lines above already
        -- accepts rather than adding a second job-tracking cache to close.
        local hadPermissionAccess = type(HasPermission) == 'function' and HasPermission(citizenid, 'k9.access')
        if hadPermissionAccess then
            LogJobChangeEndedK9Access(citizenid, ('left eligible department; new job=%s'):format(tostring(job and job.name)))
            NotifyPlayer(source, locale('certifications.k9_access_lost_department_change'), 'error')
        end

        -- SECURITY/CONSISTENCY FIX (coder-security, this pass -- see this
        -- file's own newly-added MaybeRevertK9Appearance call in
        -- RevokeCertification above for the full "why this file never
        -- called it at all" writeup). Same reasoning as the comment
        -- immediately above this call applies here too: a K9-role party
        -- whose ONLY route was autoAccessGrade or a 'k9.access' permission
        -- grant (no certification row at all) has their K9 ped model
        -- stranded forever on leaving the department, with no OTHER branch
        -- in this handler ever reaching them, unless this call is here.
        -- Safe to call even when this citizenid DOES still hold an active
        -- certification row for their old job (the common case the
        -- job-name-change branch further below will separately revoke and
        -- revert) -- MaybeRevertK9Appearance's own IsCertifiedK9ForAnyJob
        -- reconciliation sees that still-active row and correctly no-ops
        -- here, deferring the actual revert to that later branch's own call
        -- once the row is genuinely revoked.
        if type(MaybeRevertK9Appearance) == 'function' then
            MaybeRevertK9Appearance(citizenid)
        end
    end

    local cached = Certifications[citizenid]

    -- SECOND, INDEPENDENT gap in the "loses K9 access" family (distinct
    -- from leaving the department above and from losing an active
    -- certification below): HasK9Access grants K9-role access via THREE
    -- routes and keeps no record of which one applied -- an active
    -- certification (this file's own Certifications cache), an active
    -- `k9.access` permission grant (server/permissions.lua), or a job
    -- grade at/above Config.Departments[job].autoAccessGrade. A citizenid
    -- whose ONLY route is autoAccessGrade has no active row in
    -- Certifications at all, so the job-name-change branch below (gated
    -- on `cached.active`) returns before it ever looks at the grade. Left
    -- unhandled, an ordinary SAME-department demotion below
    -- autoAccessGrade left an already-formed K9-role leash pairing,
    -- partnership row, and any in-progress bite-hold/takedown/drag
    -- completely untouched -- identical in shape to the
    -- leash-holding-a-suspect-for-twenty-seconds incident this file
    -- already closed for the certification-revoke path, just reached
    -- through a different door, and reachable with NO admin action at all
    -- -- an ordinary promotion/demotion does it.
    --
    -- SCOPED DELIBERATELY NARROW to avoid any interaction with the
    -- job-name-change reconciliation logic below (which owns its own
    -- DB-write confirm/reconcile dance end to end): this only fires when
    -- `cached` already exists AND is scoped to this EXACT job name --
    -- i.e. this is provably a grade-only change within the department
    -- this citizenid was already known to be in as of their last cache
    -- refresh (PlayerLoaded, the onResourceStart backfill, or their own
    -- prior grant/revoke/OnJobUpdate touch), never a cross-department
    -- move (which the branch below already owns). `cached` being ABSENT
    -- (never refreshed this session) or scoped to a DIFFERENT job name (a
    -- genuine department change, however recent) both intentionally skip
    -- this branch -- neither can be told apart from a same-department
    -- demotion without a second job-tracking cache this fix does not
    -- introduce. DISCLOSED, NARROW RESIDUAL WINDOW: a non-cert citizenid
    -- who changes department more than once without an intervening
    -- PlayerLoaded/backfill keeps a stale `cached.job` from before their
    -- most recent move, so a LATER same-department demotion in their NEW
    -- department would not be caught by this branch either -- accepted
    -- rather than adding a second cache purely to close it, since
    -- HasK9Access itself (the actual authorization gate) is never wrong
    -- either way; only this best-effort teardown trigger can miss it.
    if job and Config.Departments[job.name] and cached and cached.job == job.name and not cached.active then
        local dept = Config.Departments[job.name]
        local stillHasNonCertAccess =
            (type(HasPermission) == 'function' and HasPermission(citizenid, 'k9.access'))
            or (type(IsHighCommand) == 'function' and IsHighCommand(source))
            or (type(dept.autoAccessGrade) == 'number' and job.grade ~= nil and type(job.grade.level) == 'number' and job.grade.level >= dept.autoAccessGrade)

        if not stillHasNonCertAccess then
            -- Mirrors RevokeCertification's online branch exactly, via the
            -- same EndK9AccessForCitizenId helper (CONSOLIDATED this pass)
            -- -- called UNCONDITIONALLY once this specific access route is
            -- confirmed lost, never re-gated on whether some OTHER route
            -- might independently justify keeping the pairing: the
            -- leash/partnership/hold that exist right now were formed
            -- under eligibility that no longer holds, and a fresh
            -- HasK9Access re-check on the next real access attempt is
            -- what re-establishes anything, not a stale pairing carried
            -- over from before this demotion. `source` is already live
            -- here, passed as `knownSrc`.
            EndK9AccessForCitizenId(citizenid, 'k9_access_lost', source)

            -- WORKFLOW CLARITY (this pass, item 4) -- UNLIKE the
            -- department-loss branch above, this one is already
            -- zero-false-positive by construction: reaching this line
            -- REQUIRES `stillHasNonCertAccess == false`, i.e. this citizenid
            -- is CONFIRMED, right now, to have just lost their only route to
            -- K9 access via an ordinary grade/promotion change that this
            -- file's own header calls out as otherwise "reachable with NO
            -- admin action at all" -- exactly the invisible case this task
            -- asks to close. Safe to notify unconditionally here.
            LogJobChangeEndedK9Access(citizenid, ('same-department grade change; job=%s'):format(tostring(job.name)))
            NotifyPlayer(source, locale('certifications.k9_access_lost_grade_change'), 'error')

            -- SECURITY/CONSISTENCY FIX (coder-security, this pass -- see
            -- RevokeCertification's own newly-added call for the full
            -- writeup). This branch is scoped to `not cached.active` (no
            -- active cert for THIS job), so a citizenid reaching here whose
            -- K9 ped model was ever applied got it ONLY through
            -- autoAccessGrade or a 'k9.access' grant -- exactly the
            -- credential that was just confirmed lost above
            -- (stillHasNonCertAccess == false). MaybeRevertK9Appearance's
            -- own IsCertifiedK9ForAnyJob reconciliation still correctly
            -- no-ops if a SEPARATE active certification for a different
            -- department independently justifies keeping the appearance
            -- (cross-department certs are allowed -- DEVELOPER_REFERENCE.md §4.2 item 3).
            if type(MaybeRevertK9Appearance) == 'function' then
                MaybeRevertK9Appearance(citizenid)
            end
        end
    end

    -- No active cert to revoke, nothing to do.
    if not (cached and cached.active) then return end

    -- SAME department, this is a grade/promotion change, NOT a department
    -- change (§4.4 "Important consequences": a promotion/demotion must
    -- NOT revoke the certification). This guard is the entire point of
    -- storing `.job` on the cache — do not remove it or every promotion
    -- silently strips certs.
    if not job or job.name == cached.job then return end

    local oldJob = cached.job

    -- Wrapped in pcall — this fires directly out of an AddEventHandler
    -- with nothing above it to catch a thrown error, so a real DB error
    -- (bad connection, deadlock, schema drift) would otherwise raise an
    -- uncaught script error out of this handler instead of degrading,
    -- silently skipping every side effect below (leash/partnership
    -- teardown) with no controlled log line explaining why. Same "a
    -- transaction would not resolve the one genuine ambiguity a thrown
    -- error can leave behind" reasoning as RevokeCertification above —
    -- this is this function's only write.
    -- CERTIFICATION DEPTH (this pass, Part A §2): `revoke_reason` is
    -- always 'reassigned' for this automatic path — an accurate,
    -- non-punitive category for "this handler changed department,"
    -- distinct from the mechanism tag ('job_changed') the outbound event
    -- below already carries. Same positional shift as the two manual
    -- revoke paths above; this call site's own test assertion was
    -- updated to match.
    local updateOk, updateErr = pcall(K9Store.Cert_RevokeActive, citizenid, oldJob, 'system:job_change', 'reassigned')

    if not updateOk then
        print(('[qbx_k9unit] OnJobUpdate auto-revoke UPDATE failed for %s/%s: %s -- reconciling before applying any side effects'):format(citizenid, oldJob, tostring(updateErr)))

        -- Reconcile against an independent, fresh read before running ANY
        -- of the side effects below — see IsCertRowConfirmedActive's own
        -- doc comment for why this can't just trust
        -- RefreshCertificationCache's collapsed return value here. Those
        -- side effects (leash detach, partnership teardown, the
        -- player-facing "your cert was revoked" notice) must only fire on
        -- a CONFIRMED loss, never a merely-unknown one.
        local stillActive = IsCertRowConfirmedActive(citizenid, oldJob)
        if stillActive ~= false then
            -- Confirmed still certified for the old job (the UPDATE
            -- genuinely never committed), or unreadable (true outcome
            -- unknown) — in BOTH cases nothing was confirmed lost, so
            -- there is nothing accurate to tell this player beyond the
            -- console log above for an operator to investigate. `cached`
            -- above is still accurate either way (never touched by this
            -- branch), so the in-memory cache is not at risk of diverging
            -- from the DB here.
            return
        end

        -- Confirmed inactive despite the client-side error (e.g. a
        -- success acknowledgment lost after a real commit) — fall through
        -- to the normal "certification just ended" side effects below
        -- against this now-confirmed truth.
    end

    -- Outbound integration event (server/exports.lua's EVENT CONTRACT §2) —
    -- fired once the UPDATE above is confirmed to have taken effect
    -- (either it returned normally, or the pcall failure branch above
    -- already independently confirmed the row is inactive before falling
    -- through here). This branch is only reached once `cached.active` and
    -- a real job-name change have already been confirmed (see the guards
    -- above), so — unlike the two manual revoke paths — there is no
    -- separate `affectedRows` result to gate on here.
    FireOutboundEvent('qbx_k9unit:events:certificationRevoked', citizenid, oldJob, 'job_changed')

    -- Repopulate the cache scoped to the NEW job (almost certainly
    -- active = false unless they already hold a separate active cert for
    -- that new department from a prior stint — a fresh grant is required
    -- either way per DEVELOPER_REFERENCE.md §9 item 3).
    RefreshCertificationCache(citizenid, job.name)

    -- Regression-test fix: keep the read-only `k9certified` HUD mirror
    -- (DEVELOPER_REFERENCE.md §4.3) in sync here too — this player is online by
    -- definition (OnJobUpdate fired for their live Player object), so this
    -- is a plain, unconditional write, no online-check needed.
    Player.Functions.SetMetaData('k9certified', false)

    local deptLabel = (Config.Departments[oldJob] and Config.Departments[oldJob].label) or oldJob
    NotifyPlayer(source, locale('certifications.revoked_notice_job_change', deptLabel), 'error')

    -- WORKFLOW CLARITY (this pass, item 4) -- this branch only runs once a
    -- REAL, active certification is confirmed lost (the `not (cached and
    -- cached.active) then return` guard above), so it fires for a bounded,
    -- meaningful population -- never every ordinary job change -- and can
    -- safely say exactly what happened without spamming the console.
    LogJobChangeEndedK9Access(citizenid, ('certification for %s ended by job change; new job=%s'):format(oldJob, tostring(job.name)))
    NotifyPlayer(source, locale('certifications.revoked_notice_job_change_next_steps'), 'inform')

    -- QA finding fix (DEVELOPER_REFERENCE.md §1/§4.4 "immediately"),
    -- CONSOLIDATED (this pass) onto EndK9AccessForCitizenId above: this
    -- player is online by definition (OnJobUpdate fired for their live
    -- `source`), so pass it as `knownSrc` rather than having the helper
    -- re-resolve it by citizenid — same reasoning as the online branch of
    -- RevokeCertification above. This branch is only reached for a
    -- K9-role citizenid — the department-membership-only handler/officer
    -- role never holds a certification of its own (see this handler's own
    -- comment near its top on that exact asymmetry) — so `citizenid` here
    -- is always the K9-role party of any active leash/hold/partnership it
    -- might hold. See EndK9AccessForCitizenId's own doc comment for the
    -- full three-call (leash/hold/partnership) writeup.
    EndK9AccessForCitizenId(citizenid, 'certification_revoked', source)

    -- CERTIFICATION DEPTH (this pass, Part B §11): same cascade as both
    -- manual revoke paths above.
    RevokeAllSpecializationsForCitizenJob(citizenid, oldJob, 'system:job_change', 'certification_revoked')

    -- SECURITY/CONSISTENCY FIX (coder-security, this pass -- see
    -- RevokeCertification's own newly-added call above for the full
    -- writeup): a promotion/department-change that auto-revokes the OLD
    -- job's certification must also reconcile/revert an applied K9
    -- appearance -- otherwise a citizenid whose only route to the role was
    -- this now-revoked certification keeps the K9 ped model forever, with
    -- no other branch in this handler ever reaching them again for this
    -- specific loss.
    if type(MaybeRevertK9Appearance) == 'function' then
        MaybeRevertK9Appearance(citizenid)
    end
end)

lib.callback.register('qbx_k9unit:server:hasK9Access', function(source)
    return HasK9Access(source)
end)
