--[[
    qbx_k9unit/server/certifications/depth.lua

    Certification DEPTH: the tier ladder, renewal/expiry, and
    specializations -- everything that changes a certification that already
    exists, rather than creating or destroying one.

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
local ConfiguredDepartmentsList = K9Cert.ConfiguredDepartmentsList
local ConfiguredSpecializationsList = K9Cert.ConfiguredSpecializationsList
local DaysRemainingFromUnix = K9Cert.DaysRemainingFromUnix
local ExpiryLapsedNotified = K9Cert.ExpiryLapsedNotified
local ExpiryWarned = K9Cert.ExpiryWarned
local GrantInFlight = K9Cert.GrantInFlight
local IsCertifyActionOnCooldown = K9Cert.IsCertifyActionOnCooldown
local IsDuplicateKeyError = K9Cert.IsDuplicateKeyError
local IsEligibleCertifier = K9Cert.IsEligibleCertifier
local IsKnownTierKeyOrLegacyFallback = K9Cert.IsKnownTierKeyOrLegacyFallback
local RefreshSpecializationCache = K9Cert.RefreshSpecializationCache
local ResolveConfiguredExpiryDays = K9Cert.ResolveConfiguredExpiryDays
local ResolveGranterCitizenId = K9Cert.ResolveGranterCitizenId
local RevokeCertification = K9Cert.RevokeCertification
local RevokeCertificationOffline = K9Cert.RevokeCertificationOffline

-- ======================================================================
-- CERTIFICATION DEPTH (this pass) — TIER / RENEWAL / SPECIALIZATION
-- ACTIONS. See this file's header for the full design writeup. All FIVE
-- functions below share the same shape: IsEligibleCertifier + the SAME
-- CertifyActionCooldown instance grant/revoke already use (this file's
-- own established "one shared cooldown per related-action group"
-- convention) + the SAME self-action/proximity rules GrantCertification
-- uses. DELIBERATE SCOPE REDUCTION vs. RevokeCertification's own
-- reconcile-on-throw dance: these five are secondary-capability actions
-- that never flip base access on their own (a thrown UPDATE here reports
-- a plain error and changes nothing, rather than reconciling against an
-- independent read) — the elaborate reconciliation RevokeCertification
-- performs exists specifically because a WRONGLY-reported outcome on the
-- primary access gate is a real security/trust problem; these five are
-- not that, and treating them identically would be needless complexity
-- for a much lower-stakes mutation. Stated explicitly here, not silently
-- decided, per this task's own instruction to keep the model something
-- an operator (and a reviewer) can hold in their head.
-- ======================================================================

--- K9 COMMAND TABLET AUDIT LOG (this pass) -- console log line for every
--- TABLET-INVOKED tier/renewal/specialization action, covering both
--- successful and refused invocations. Mirrors server/permissions.lua's
--- own LogAuditInvocation "%s ran %s(%s) -> %s" format EXACTLY (this
--- resource's established audit-log convention -- see that file's own doc
--- comment).
---
--- SCOPING DECISION, STATED EXPLICITLY (not silently narrower): this is
--- called ONCE per tablet invocation, at each *ForTablet wrapper's own
--- single exit point, covering the real `(ok, outcome)` this pass's
--- retrofit now returns -- it is NOT retrofitted onto every individual
--- early-return branch INSIDE SetCertificationTier/RenewCertification/
--- GrantSpecialization/RevokeSpecialization(Offline) themselves the way
--- server/permissions.lua's GrantPermission logs its own branches
--- one-by-one. Those five functions are already extensively tested,
--- TOCTOU-sensitive (TierEditMutex, GrantInFlight) code reachable from
--- FIVE call sites each (net event, command, and now this tablet
--- wrapper) -- instrumenting every one of their existing branches
--- individually would be a much wider, higher-risk edit than this task's
--- own "purely additive" instruction calls for, for a resource that has
--- never audited its own /k9settier, /k9recertify, /k9specialize,
--- /k9unspecialize(offline) command paths this way either. One audit line
--- per tablet invocation -- the actual new surface this pass adds -- is
--- the honest scope of what changed.
--- @param granterSrc number
--- @param action string
--- @param detail string
--- @param outcome string
local function LogTabletCertAuditInvocation(granterSrc, action, detail, outcome)
    local granterPlayer = exports.qbx_core:GetPlayer(granterSrc)
    local granterCitizenid = granterPlayer and granterPlayer.PlayerData and granterPlayer.PlayerData.citizenid
    local whoLabel = granterCitizenid and ('citizenid=' .. granterCitizenid) or ('unresolved-source=' .. tostring(granterSrc))
    print(('[qbx_k9unit] AUDIT: %s ran %s(%s) -> %s'):format(whoLabel, action, detail, outcome))
end

--- A role's display name for a message (server/notify.lua's
--- RoleDisplayName), or its key when that file is not loaded.
local function RoleNameForMessage(roleKey)
    if type(RoleDisplayName) == 'function' then return RoleDisplayName(roleKey) end
    return tostring(roleKey)
end

--- ======================================================================
--- TABLET DECERTIFY -- THE FIX (this pass, coordinator-directed follow-up
--- confirming docs/history/COMMAND_CONSOLIDATION_SPEC.md §6). RevokeCertification and
--- RevokeCertificationOffline above ALREADY BOTH EXIST and each already
--- enforces its own correct rules -- the bug is not in either of them. The
--- bug was in client/tablet.lua's tablet:decertify NUI callback: it shelled
--- out to `/k9decertifyoffline` via SubmitAllowlistedCommand for EVERY
--- target, online or offline -- and RevokeCertificationOffline's own
--- "refuse if actually online right now" TOCTOU guard above (mirrors
--- GrantCertificationOffline/SetCertificationTierOffline/
--- RenewCertificationOffline) means an online target ALWAYS hit that
--- refusal. The tablet's own documented contract ("works for an ONLINE or
--- OFFLINE target, same as tablet:certify") was never actually true for
--- decertify.
---
--- THE FIX: `RevokeCertificationForTablet` below, mirroring
--- `GrantCertificationForTablet`'s exact shape -- resolve `citizenid` to a
--- currently-connected server id FIRST and, if that succeeds, delegate to
--- RevokeCertification UNCHANGED (the exact same eligibility, cooldown,
--- self-cert, and proximity rules a live '/k9decertify [server id]' would
--- run -- ONLINE PATH ENTIRELY UNTOUCHED BY THIS CHANGE, its proximity/
--- consent requirements are never weakened to make the offline one easier).
--- Only when the target is NOT currently connected does it fall through to
--- RevokeCertificationOffline. One code path, no duplicated authority.
---
--- AUDIT LOGGING: unlike GrantCertificationForTablet (written before the
--- LogTabletCertAuditInvocation convention above existed), this wrapper
--- DOES log via LogTabletCertAuditInvocation, mirroring
--- SetCertificationTierForTablet/RenewCertificationForTablet/
--- GrantSpecializationForTablet/RevokeSpecializationForTablet below in this
--- file -- decertify is a destructive action (this task's own "destructive
--- actions need an explicit word, gate the start never the stop" rule),
--- and every OTHER destructive/mutating *ForTablet wrapper in this file
--- already gets this audit line; there is no reason for the one newly
--- added here to be the sole exception.
---
--- `reason` is deliberately NOT accepted here: html/tablet.js's own
--- tablet:decertify payload is `{ targetCitizenId, departmentKey }` (no
--- reason field, see client/tablet.lua's own NUI CONTRACT comment) --
--- RevokeCertification(Offline) both treat a nil `reason` exactly like
--- every pre-existing chat-command-only caller that never passed one, so
--- this is not a capability regression versus what the tablet already
--- lacked.
--- @param granterSrc number
--- @param citizenid string
--- @param departmentKey string -- input-sanity/UX check only, same role as
--- GrantCertificationForTablet's own identical parameter -- NEVER used to
--- override the target's actual live job; a live job that does not match
--- `departmentKey` is reported as 'department_mismatch' rather than
--- silently revoking the mismatched real department.
--- @return boolean ok
--- @return string outcome -- every RevokeCertification/RevokeCertificationOffline outcome, plus 'invalid_target' (shape) | 'invalid_department' | 'department_mismatch'
--- ======================================================================
local function RevokeCertificationForTablet(granterSrc, citizenid, departmentKey)
    local ok, outcome = (function()
        if type(citizenid) ~= 'string' or citizenid == '' or type(departmentKey) ~= 'string' or departmentKey == '' then
            return false, 'invalid_target'
        end
        if not Config.Departments[departmentKey] then
            return false, 'invalid_department'
        end

        local onlineTarget = exports.qbx_core:GetPlayerByCitizenId(citizenid)
        local onlineTargetSrc = onlineTarget and onlineTarget.PlayerData and onlineTarget.PlayerData.source
        if onlineTargetSrc then
            local liveJob = onlineTarget.PlayerData.job
            if not liveJob or liveJob.name ~= departmentKey then
                return false, 'department_mismatch'
            end
            return RevokeCertification(granterSrc, onlineTargetSrc)
        end

        return RevokeCertificationOffline(granterSrc, citizenid, departmentKey)
    end)()

    -- ROSTER FIX (coordinator-flagged gap, this pass) -- server/roster.lua's
    -- own ClearPersonnelRowForCitizenJob doc comment already named THIS
    -- function as its intended caller, written before this function itself
    -- existed. Best-effort `k9_personnel` cleanup, run ONLY after a
    -- confirmed successful revoke (never before -- "never gate a
    -- termination path"), and never allowed to turn an already-succeeded
    -- revoke back into a reported failure: a failure here is logged by
    -- ClearPersonnelRowForCitizenJob itself and simply left for a future
    -- cleanup pass, exactly like this file's own
    -- RevokeAllSpecializationsForCitizenJob/MaybeRevertK9Appearance calls
    -- immediately above treat their own best-effort side effects. Without
    -- this call, a fired handler's roster role AND callsign silently
    -- survive the revoke -- invisible today (both roster reads already
    -- filter on an active certification, per that function's own doc
    -- comment) but resurrecting on re-certification, landing them back on
    -- a roster with their old callsign instead of Unassigned
    -- (docs/history/ROSTER_SPEC.md §4). `clearedBy` is resolved fresh here (never
    -- reusing RevokeCertification(Offline)'s own already-notified
    -- ResolveGranterCitizenId call, which would risk a second, spurious
    -- notify to `granterSrc` after the revoke already succeeded) --
    -- falls back to a 'system:...' sentinel per that function's own
    -- documented contract if the granter's citizenid cannot be resolved for
    -- any reason, rather than skipping the cleanup entirely.
    if ok and type(ClearPersonnelRowForCitizenJob) == 'function' then
        local granterPlayer = exports.qbx_core:GetPlayer(granterSrc)
        local clearedBy = (granterPlayer and granterPlayer.PlayerData and granterPlayer.PlayerData.citizenid)
            or 'system:tabletDecertify'
        ClearPersonnelRowForCitizenJob(citizenid, departmentKey, clearedBy)
    end

    LogTabletCertAuditInvocation(granterSrc, 'tabletDecertify',
        ('target=%s department=%s'):format(tostring(citizenid), tostring(departmentKey)), outcome)
    return ok, outcome
end

--- Changes `targetServerId`'s certification tier for their OWN currently
--- active department certification. Deliberately SEPARATE from
--- GrantCertification (see header "TIER") — every grant still always
--- creates a 'certified' row; this is the only way to move a citizenid to
--- 'trainee' or 'senior'.
---
--- RETURN VALUE, ADDED THIS PASS (purely additive -- every pre-existing
--- caller (the RegisterNetEvent/RegisterCommand handlers near the bottom of
--- this file) discards both return values today, exactly as it discarded
--- the previous bare `return`, so this changes NO observable behavior for
--- either of them). Added so the K9 Command Tablet
--- (SetCertificationTierForTablet below) can report a real outcome back to
--- the caller instead of only a fire-and-forget toast -- mirrors
--- GrantCertification's own identical `(ok, outcome)` retrofit earlier in
--- this file.
--- @param granterSrc number
--- @param targetServerId number
--- @param newTier string -- 'trainee'|'certified'|'senior' (or any live, operator-added tier key)
--- @return boolean ok
--- @return string outcome -- 'invalid_target' | 'not_eligible' | 'on_cooldown' | 'invalid_tier' | 'self_certification_disabled' | 'target_must_be_online' | 'target_too_far' | 'target_not_actively_certified' | 'tier_already_set' | 'invalid_granter' | 'busy' | 'db_error' | 'ok'
local function SetCertificationTier(granterSrc, targetServerId, newTier)
    if type(targetServerId) ~= 'number' then
        NotifyPlayer(granterSrc, locale('certifications.invalid_target_id'), 'error')
        return false, 'invalid_target'
    end

    if not IsEligibleCertifier(granterSrc) then
        NotifyPlayer(granterSrc, locale('certifications.not_authorized_to_certify_hint'), 'error')
        return false, 'not_eligible'
    end

    if IsCertifyActionOnCooldown(granterSrc) then
        return false, 'on_cooldown'
    end

    -- OWNER-DIRECTED TIER-EDITING PASS: was `not TIER_RANK[newTier]`
    -- (only trainee/certified/senior could ever be assigned) — now
    -- accepts any tier key the live, operator-extensible catalog
    -- currently recognizes. See IsKnownTierKeyOrLegacyFallback above.
    if type(newTier) ~= 'string' or not IsKnownTierKeyOrLegacyFallback(newTier) then
        NotifyPlayer(granterSrc, locale('certifications.invalid_tier'), 'error')
        return false, 'invalid_tier'
    end

    local isSelfCert = granterSrc == targetServerId
    if isSelfCert and not Config.AllowSelfCertification then
        NotifyPlayer(granterSrc, locale('certifications.self_certification_disabled_hint'), 'error')
        return false, 'self_certification_disabled'
    end

    -- WORKFLOW CLARITY (this pass, item 3): unlike GrantSpecialization
    -- below, a tier change has a real offline-capable counterpart
    -- (SetCertificationTierOffline / /k9settieroffline) -- tell the caller
    -- it exists right where they'd otherwise be stuck.
    local targetPlayer = exports.qbx_core:GetPlayer(targetServerId)
    if not targetPlayer or not targetPlayer.PlayerData then
        NotifyPlayer(granterSrc, locale('certifications.tier_change_target_must_be_online_hint'), 'error')
        return false, 'target_must_be_online'
    end

    if not isSelfCert then
        local granterPed = GetPlayerPed(granterSrc)
        local targetPed = GetPlayerPed(targetServerId)
        local dist = #(GetEntityCoords(granterPed) - GetEntityCoords(targetPed))
        if dist > Config.CertifyProximityMeters then
            NotifyPlayer(granterSrc, locale('certifications.action_target_too_far_distance', tostring(Config.CertifyProximityMeters)), 'error')
            return false, 'target_too_far'
        end
    end

    local targetCitizenid = targetPlayer.PlayerData.citizenid
    local jobName = targetPlayer.PlayerData.job and targetPlayer.PlayerData.job.name
    local cached = jobName and Certifications[targetCitizenid]
    if not (cached and cached.active and cached.job == jobName) then
        NotifyPlayer(granterSrc, locale('certifications.target_not_actively_certified_needs_cert'), 'error')
        return false, 'target_not_actively_certified'
    end

    if cached.tier == newTier then
        NotifyPlayer(granterSrc, locale('certifications.tier_already_set'), 'inform')
        return false, 'tier_already_set'
    end

    local granterCitizenid = ResolveGranterCitizenId(granterSrc)
    if not granterCitizenid then return false, 'invalid_granter' end

    local oldTier = cached.tier

    -- TIER CATALOG RACE GUARD (owner-directed tier-editing pass,
    -- server/certtiers.lua) — see that file's own header "HAZARD 4",
    -- "THE DELETE-VS-ASSIGN RACE" for the full writeup. Acquires the SAME
    -- cross-file TierEditMutex, keyed by `newTier`, that
    -- server/certtiers.lua's DeleteTier acquires before its own
    -- reference-count check + tombstone write — this closes the window
    -- where a concurrent delete of `newTier` could otherwise land between
    -- "this key is currently known" (already checked above) and this
    -- UPDATE actually committing, which would leave this row referencing
    -- a tier that no longer exists (exactly the outcome this feature's
    -- own hazard list forbids). Guarded by a `type(...) == 'table'`
    -- runtime existence check, this resource's established soft-
    -- dependency convention — this function still works exactly as
    -- before (accepting only the previously-undocumented, now-disclosed,
    -- narrow race) if server/certtiers.lua is ever removed.
    local haveTierMutex = type(TierEditMutex) == 'table'
    if haveTierMutex and not TierEditMutex.TryAcquire(newTier) then
        NotifyPlayer(granterSrc, locale('certifications.tier_change_busy'), 'error')
        return false, 'busy'
    end

    -- Re-check AFTER acquiring the lock, in case `newTier` was deleted by
    -- a concurrent DeleteTier call in the gap between the earlier check
    -- and acquiring this lock — refuse now rather than write a reference
    -- to a tier that no longer exists.
    if haveTierMutex and not IsKnownTierKeyOrLegacyFallback(newTier) then
        TierEditMutex.Release(newTier)
        NotifyPlayer(granterSrc, locale('certifications.invalid_tier'), 'error')
        return false, 'invalid_tier'
    end

    -- AFFECTED-ROWS DEFECT FIX (data-truth audit pass): `err` here doubles
    -- as the affected-row count on a NON-thrown update (pcall's own
    -- "true, <every return value>" contract) -- Cert_SetTier is a bare
    -- `WHERE ... AND active = 1` UPDATE (see server/datastore.lua's own
    -- doc comment on K9Store.Cert_SetTier), so it throws NOTHING when the
    -- WHERE clause simply matches zero rows. This entry gate above reads
    -- the in-memory `Certifications` cache, not a fresh row, and the
    -- UPDATE itself yields across a coroutine boundary -- a concurrent
    -- decertify/job-change/second tier change can land in that exact
    -- window and make this UPDATE affect zero rows with no error at all.
    -- Mirrors RevokeCertification's own identical `updateOk`/affected-rows
    -- branch immediately above in this file, byte-for-byte in shape.
    local updateOk, affectedRowsOrErr = pcall(K9Store.Cert_SetTier, targetCitizenid, jobName, newTier)

    if haveTierMutex then TierEditMutex.Release(newTier) end

    if not updateOk then
        print(('[qbx_k9unit] SetCertificationTier UPDATE failed for %s/%s: %s -- reconciling before reporting an outcome'):format(targetCitizenid, jobName, tostring(affectedRowsOrErr)))

        local freshRecord = QueryCertificationRecord(targetCitizenid, jobName)
        if not (freshRecord and freshRecord.tier == newTier) then
            -- Either confirmed the tier never actually changed (the
            -- UPDATE genuinely never committed -- an honest failure, the
            -- target keeps their current, correct tier) or unreadable/
            -- no-longer-active (outcome unknown or moot) -- in BOTH
            -- cases, never claim a tier change succeeded that this code
            -- cannot confirm, and never run the side effects below
            -- (outbound event, success notices) against a guess.
            NotifyPlayer(granterSrc, locale('certifications.tier_change_error'), 'error')
            return false, 'db_error'
        end

        -- Confirmed changed despite the client-side error (e.g. a
        -- success acknowledgment lost after a real commit) -- fall
        -- through to the normal success path below against this
        -- now-confirmed truth; RefreshCertificationCache below will pick
        -- up the correct state.
    elseif not affectedRowsOrErr or affectedRowsOrErr == 0 then
        -- Zero rows matched: WHERE ... AND active = 1 found nothing --
        -- see this branch's own header comment above for exactly why.
        -- Zero is a real, meaningful outcome here, never swallowed by an
        -- `or` fallback -- checked explicitly, same as
        -- RevokeCertification's own identical branch.
        RefreshCertificationCache(targetCitizenid, jobName)
        NotifyPlayer(granterSrc, locale('certifications.target_not_actively_certified_needs_cert'), 'error')
        return false, 'target_not_actively_certified'
    end

    local _, _, freshlyVerified = RefreshCertificationCache(targetCitizenid, jobName)

    -- Read the tier back from the now-authoritative cache before telling
    -- either party anything changed -- mirrors RenewCertification's own
    -- "never display an assumed value" precedent -- rather than blindly
    -- trusting the requested `newTier` (belt-and-braces alongside the
    -- affected-rows check above, covering the reconciled-thrown-error
    -- path where confirmation came from a separate read). Falls back to
    -- `newTier` if the cache is somehow unavailable immediately after a
    -- confirmed write, never silently showing a stale value -- and,
    -- lifecycle QA pass, if the read-back above itself hit a transient
    -- failure: `freshlyVerified` (RefreshCertificationCache's own 3rd
    -- return value) is checked explicitly rather than just `confirmedCached
    -- and confirmedCached.active`, because a RETAINED pre-write cache entry
    -- would satisfy that check too -- with the OLD tier, not the one this
    -- UPDATE (already confirmed committed above) just wrote -- and silently
    -- display stale data as if it were a fresh confirmation.
    local confirmedCached = freshlyVerified and Certifications[targetCitizenid]
    local confirmedTier = (confirmedCached and confirmedCached.active and confirmedCached.job == jobName and confirmedCached.tier) or newTier

    FireOutboundEvent('qbx_k9unit:events:certificationTierChanged', targetCitizenid, jobName, oldTier, confirmedTier, granterCitizenid)

    NotifyPlayer(granterSrc, locale('certifications.tier_change_success_granter', confirmedTier), 'success')
    NotifyPlayer(targetServerId, locale('certifications.tier_change_success_target', confirmedTier), 'success')
    return true, 'ok'
end

--- ======================================================================
--- OFFLINE-CAPABLE COUNTERPART TO SetCertificationTier (this pass) -- see
--- RevokeSpecializationOffline's own doc comment (below in this file) and
--- RevokeCertificationOffline's (above) for the established model this
--- mirrors. UNLIKE GrantCertification/GrantSpecialization (see
--- GrantCertificationForTablet's own "OFFLINE-GRANT ASYMMETRY" writeup and
--- GrantSpecializationForTablet's own doc comment below for why THOSE two
--- have no offline path), a tier change has NO live-ped dependency (no
--- model check, ever -- tier is orthogonal to §4.2 item 5) and NO
--- TierCapabilityPermits gate to keep correct against a possibly-stale
--- cache (that gate exists only for GRANTING a specialization, never for
--- moving an already-certified handler between tiers) -- it is "paperwork"
--- in exactly the sense RenewCertification's own doc comment already uses
--- that word for renewal, so the SAME offline treatment DEVELOPER_REFERENCE.md
--- §4.3 already mandates for revoke is the right call here too: high
--- command must be able to re-tier a handler who is not logged in right
--- now, exactly as they can already decertify one.
---
--- DB-AUTHORITATIVE precondition (QueryCertificationRecord), NOT the
--- online-only `Certifications` cache: a genuinely offline citizenid has no
--- live cache entry at all (evicted on `playerDropped`, per this file's own
--- cache-lifecycle convention), so reusing SetCertificationTier's own
--- `cached.active`/`cached.job` check here would fail closed for EVERY
--- offline target, defeating the entire point of this function.
---
--- SECURITY (mirrors RevokeCertificationOffline's own identical guard,
--- verbatim reasoning): this path exists ONLY to reach a genuinely
--- disconnected target -- that is the sole justification for skipping
--- §4.2 condition 4's proximity check. Refuses outright, pointing the
--- caller at the proximity-checked `/k9settier`, if `citizenid` actually
--- resolves to a currently-connected player right now -- without this
--- guard, an eligible certifier could re-tier ANY online target from
--- anywhere on the map, silently bypassing Config.CertifyProximityMeters,
--- the exact class of bug RevokeCertificationOffline's own SECURITY FIX
--- closed for revoke.
--- @param granterSrc number
--- @param citizenid string
--- @param jobName string
--- @param newTier string
--- @return boolean ok
--- @return string outcome -- 'not_eligible' | 'on_cooldown' | 'invalid_target' | 'invalid_department' | 'invalid_tier' | 'target_online_use_online_action' | 'invalid_granter' | 'target_not_actively_certified' | 'tier_already_set' | 'busy' | 'db_error' | 'ok'
local function SetCertificationTierOffline(granterSrc, citizenid, jobName, newTier)
    if not IsEligibleCertifier(granterSrc) then
        NotifyPlayer(granterSrc, locale('certifications.not_authorized_to_certify_hint'), 'error')
        return false, 'not_eligible'
    end

    if IsCertifyActionOnCooldown(granterSrc) then
        return false, 'on_cooldown'
    end

    if type(citizenid) ~= 'string' or citizenid == '' or type(jobName) ~= 'string' or jobName == '' then
        NotifyPlayer(granterSrc, locale('certifications.usage_settier'), 'error')
        return false, 'invalid_target'
    end

    if not Config.Departments[jobName] then
        NotifyPlayer(granterSrc, locale('certifications.invalid_department_hint', jobName, ConfiguredDepartmentsList()), 'error')
        return false, 'invalid_department'
    end

    if type(newTier) ~= 'string' or not IsKnownTierKeyOrLegacyFallback(newTier) then
        NotifyPlayer(granterSrc, locale('certifications.invalid_tier'), 'error')
        return false, 'invalid_tier'
    end

    local onlineCheckTarget = exports.qbx_core:GetPlayerByCitizenId(citizenid)
    if onlineCheckTarget and onlineCheckTarget.PlayerData and onlineCheckTarget.PlayerData.source then
        NotifyPlayer(granterSrc, locale('certifications.tier_change_target_online_use_online_action', onlineCheckTarget.PlayerData.source), 'error')
        return false, 'target_online_use_online_action'
    end

    local granterCitizenid = ResolveGranterCitizenId(granterSrc)
    if not granterCitizenid then return false, 'invalid_granter' end

    local record = QueryCertificationRecord(citizenid, jobName)
    if not record then
        NotifyPlayer(granterSrc, locale('certifications.target_not_actively_certified_needs_cert'), 'error')
        return false, 'target_not_actively_certified'
    end

    local oldTier = record.tier
    if oldTier == newTier then
        NotifyPlayer(granterSrc, locale('certifications.tier_already_set'), 'inform')
        return false, 'tier_already_set'
    end

    -- Same cross-file TierEditMutex race guard as the online path above --
    -- see SetCertificationTier's own doc comment ("THE DELETE-VS-ASSIGN
    -- RACE") for the full writeup; identical here, reached via a different
    -- (offline) entry point.
    local haveTierMutex = type(TierEditMutex) == 'table'
    if haveTierMutex and not TierEditMutex.TryAcquire(newTier) then
        NotifyPlayer(granterSrc, locale('certifications.tier_change_busy'), 'error')
        return false, 'busy'
    end

    if haveTierMutex and not IsKnownTierKeyOrLegacyFallback(newTier) then
        TierEditMutex.Release(newTier)
        NotifyPlayer(granterSrc, locale('certifications.invalid_tier'), 'error')
        return false, 'invalid_tier'
    end

    -- AFFECTED-ROWS DEFECT FIX (data-truth audit pass) -- see
    -- SetCertificationTier's own identical doc comment above (the online
    -- twin) for the full "why this can affect zero rows with no thrown
    -- error at all" writeup; applies here verbatim -- the entry gate's
    -- own `record` above is a snapshot read that can go stale across this
    -- UPDATE's own coroutine yield exactly the same way the online path's
    -- in-memory cache read can.
    local updateOk, affectedRowsOrErr = pcall(K9Store.Cert_SetTier, citizenid, jobName, newTier)

    if haveTierMutex then TierEditMutex.Release(newTier) end

    if not updateOk then
        print(('[qbx_k9unit] SetCertificationTierOffline UPDATE failed for %s/%s: %s -- reconciling before reporting an outcome'):format(citizenid, jobName, tostring(affectedRowsOrErr)))

        local freshRecord = QueryCertificationRecord(citizenid, jobName)
        if not (freshRecord and freshRecord.tier == newTier) then
            -- Either confirmed the tier never actually changed, or
            -- unreadable/no-longer-active -- never claim a tier change
            -- succeeded that this code cannot confirm. See
            -- SetCertificationTier's own identical branch for the full
            -- reasoning.
            NotifyPlayer(granterSrc, locale('certifications.tier_change_error'), 'error')
            return false, 'db_error'
        end

        -- Confirmed changed despite the client-side error -- fall
        -- through to the normal success path below against this
        -- now-confirmed truth.
    elseif not affectedRowsOrErr or affectedRowsOrErr == 0 then
        -- Zero rows matched -- a real, meaningful outcome, never
        -- swallowed by an `or` fallback -- checked explicitly, same as
        -- the online path's identical branch immediately above in this
        -- file.
        RefreshCertificationCache(citizenid, jobName)
        NotifyPlayer(granterSrc, locale('certifications.target_not_actively_certified_needs_cert'), 'error')
        return false, 'target_not_actively_certified'
    end

    -- Safe to call unconditionally for a genuinely offline citizenid --
    -- see RevokeCertificationOffline's own identical call/comment above
    -- ("RefreshCertificationCache is a plain DB-query-and-cache-write
    -- function with no live-source requirement").
    local _, _, freshlyVerified = RefreshCertificationCache(citizenid, jobName)

    -- Read the tier back from the now-authoritative cache before telling
    -- the granter anything changed -- see SetCertificationTier's own
    -- identical doc comment above for the full reasoning, including the
    -- `freshlyVerified` guard against a retained-but-stale pre-write cache
    -- entry masquerading as a fresh confirmation.
    local confirmedCached = freshlyVerified and Certifications[citizenid]
    local confirmedTier = (confirmedCached and confirmedCached.active and confirmedCached.job == jobName and confirmedCached.tier) or newTier

    FireOutboundEvent('qbx_k9unit:events:certificationTierChanged', citizenid, jobName, oldTier, confirmedTier, granterCitizenid)

    NotifyPlayer(granterSrc, locale('certifications.tier_change_success_granter', confirmedTier), 'success')
    return true, 'ok'
end

--- K9 COMMAND TABLET aggregation wrapper -- keyed by citizenid (not server
--- id), matching every other tablet-facing action in this file
--- (GrantCertificationForTablet above). Resolves the target's live online
--- state itself and picks the RIGHT underlying implementation: an online
--- target gets the SAME proximity-checked SetCertificationTier a live
--- '/k9settier [server id] [tier]' would run (one code path, no duplicated
--- authority -- mirrors GrantCertificationForTablet exactly); a genuinely
--- offline target falls through to SetCertificationTierOffline above.
--- Adds NO authorization/cooldown/mutex logic of its own -- both delegated
--- functions already re-verify IsEligibleCertifier, the SAME
--- CertifyActionCooldown instance, and TierEditMutex internally.
--- `departmentKey` is validated against the target's LIVE job when online
--- (a stale tablet view showing a department the target has since left
--- must surface as 'department_mismatch', never silently retarget) --
--- mirrors GrantCertificationForTablet's own identical `departmentKey`
--- doc comment.
--- @param granterSrc number
--- @param citizenid string
--- @param departmentKey string
--- @param newTier string
--- @return boolean ok
--- @return string outcome -- every SetCertificationTier/SetCertificationTierOffline outcome, plus 'invalid_target' (shape) | 'invalid_department' | 'department_mismatch'
local function SetCertificationTierForTablet(granterSrc, citizenid, departmentKey, newTier)
    local ok, outcome = (function()
        if type(citizenid) ~= 'string' or citizenid == '' or type(departmentKey) ~= 'string' or departmentKey == ''
            or type(newTier) ~= 'string' or newTier == '' then
            return false, 'invalid_target'
        end
        if not Config.Departments[departmentKey] then
            return false, 'invalid_department'
        end

        local onlineTarget = exports.qbx_core:GetPlayerByCitizenId(citizenid)
        local onlineTargetSrc = onlineTarget and onlineTarget.PlayerData and onlineTarget.PlayerData.source
        if onlineTargetSrc then
            local liveJob = onlineTarget.PlayerData.job
            if not liveJob or liveJob.name ~= departmentKey then
                return false, 'department_mismatch'
            end
            return SetCertificationTier(granterSrc, onlineTargetSrc, newTier)
        end

        return SetCertificationTierOffline(granterSrc, citizenid, departmentKey, newTier)
    end)()

    LogTabletCertAuditInvocation(granterSrc, 'tabletSetCertificationTier',
        ('target=%s department=%s tier=%s'):format(tostring(citizenid), tostring(departmentKey), tostring(newTier)), outcome)
    return ok, outcome
end

--- Extends `targetServerId`'s certification expiry by
--- `Config.CertificationExpiryDays` from now, WITHOUT touching
--- `granted_at`/`granted_by` (the original grant lineage is preserved —
--- this is a renewal, not a re-grant). See header "EXPIRY" — date
--- arithmetic happens in SQL (`DATE_ADD(NOW(), INTERVAL ? DAY)`), never in
--- Lua. Does NOT re-run the K9-model check (mirrors RevokeCertification's
--- own "model check is grant-only" precedent — a renewal is re-affirming
--- paperwork, not re-verifying identity).
--- RETURN VALUE, ADDED THIS PASS (purely additive -- see
--- SetCertificationTier's own identical retrofit note just above; every
--- pre-existing caller discards both values, so this changes NO observable
--- behavior for the net-event/command paths).
--- @param granterSrc number
--- @param targetServerId number
--- @return boolean ok
--- @return string outcome -- 'invalid_target' | 'not_eligible' | 'on_cooldown' | 'feature_disabled' | 'self_certification_disabled' | 'target_must_be_online' | 'target_too_far' | 'target_not_actively_certified' | 'invalid_granter' | 'db_error' | 'ok'
local function RenewCertification(granterSrc, targetServerId)
    if type(targetServerId) ~= 'number' then
        NotifyPlayer(granterSrc, locale('certifications.invalid_target_id'), 'error')
        return false, 'invalid_target'
    end

    if not IsEligibleCertifier(granterSrc) then
        NotifyPlayer(granterSrc, locale('certifications.not_authorized_to_certify_hint'), 'error')
        return false, 'not_eligible'
    end

    if IsCertifyActionOnCooldown(granterSrc) then
        return false, 'on_cooldown'
    end

    -- CLAMP-AND-WARN on a misconfigured CertificationExpiryDays lives in
    -- ResolveConfiguredExpiryDays (shared with GrantCertification above) —
    -- see its own doc comment. Returns nil identically whether the feature
    -- is genuinely off or misconfigured while on; either way there is
    -- nothing to renew, so this notice stays accurate for both cases (a
    -- misconfiguration ALSO prints its own, separate, operator-facing
    -- console warning naming the exact bad value).
    local expiryDays = ResolveConfiguredExpiryDays()
    if not expiryDays then
        NotifyPlayer(granterSrc, locale('certifications.renew_feature_disabled'), 'error')
        return false, 'feature_disabled'
    end

    local isSelfCert = granterSrc == targetServerId
    if isSelfCert and not Config.AllowSelfCertification then
        NotifyPlayer(granterSrc, locale('certifications.self_certification_disabled_hint'), 'error')
        return false, 'self_certification_disabled'
    end

    -- WORKFLOW CLARITY (this pass, item 3): unlike GrantSpecialization
    -- below, a renewal has a real offline-capable counterpart
    -- (RenewCertificationOffline / /k9recertifyoffline).
    local targetPlayer = exports.qbx_core:GetPlayer(targetServerId)
    if not targetPlayer or not targetPlayer.PlayerData then
        NotifyPlayer(granterSrc, locale('certifications.renew_target_must_be_online_hint'), 'error')
        return false, 'target_must_be_online'
    end

    if not isSelfCert then
        local granterPed = GetPlayerPed(granterSrc)
        local targetPed = GetPlayerPed(targetServerId)
        local dist = #(GetEntityCoords(granterPed) - GetEntityCoords(targetPed))
        if dist > Config.CertifyProximityMeters then
            NotifyPlayer(granterSrc, locale('certifications.action_target_too_far_distance', tostring(Config.CertifyProximityMeters)), 'error')
            return false, 'target_too_far'
        end
    end

    local targetCitizenid = targetPlayer.PlayerData.citizenid
    local jobName = targetPlayer.PlayerData.job and targetPlayer.PlayerData.job.name
    local cached = jobName and Certifications[targetCitizenid]
    if not (cached and cached.active and cached.job == jobName) then
        NotifyPlayer(granterSrc, locale('certifications.target_not_actively_certified_needs_cert'), 'error')
        return false, 'target_not_actively_certified'
    end

    local granterCitizenid = ResolveGranterCitizenId(granterSrc)
    if not granterCitizenid then return false, 'invalid_granter' end

    -- AFFECTED-ROWS DEFECT FIX (data-truth audit pass, this pass,
    -- coder-backend) — this function used to check only whether the pcall
    -- ITSELF threw, never whether the UPDATE it wrapped actually matched a
    -- row — the exact defect already fixed in SetCertificationTier/
    -- SetCertificationTierOffline (see either's own identical doc comment
    -- for the full writeup). Cert_RenewExpiry is a bare
    -- `WHERE citizenid = ? AND job = ? AND active = 1` UPDATE (see
    -- server/datastore.lua's own doc comment on K9Store.Cert_RenewExpiry),
    -- so it throws NOTHING when the WHERE clause simply matches zero rows.
    -- This entry gate above reads the in-memory `Certifications` cache, not
    -- a fresh row, and the UPDATE itself yields across a coroutine boundary
    -- — a concurrent decertify or job change landing in that exact window
    -- makes this UPDATE affect zero rows with no error at all, which the
    -- pre-fix code reported as an unconditional success to BOTH parties.
    -- Mirrors RevokeCertification/SetCertificationTier's own identical
    -- `updateOk`/affected-rows branch, byte-for-byte in shape.
    --
    -- `oldExpiresAtUnix` is snapshotted from the entry gate's own `cached`
    -- read, BEFORE the write — the reconciliation read below (on a thrown
    -- error only) compares the fresh, DB-authoritative expiry against this
    -- baseline: a renewal is a `DATE_ADD(NOW(), ...)` extension, not a
    -- fixed target value, so "does it now equal what I asked for" (this
    -- file's SetCertificationTier/RevokeCertification shape) does not
    -- apply verbatim — the closest genuine analog of "the invariant this
    -- call was trying to establish now holds" is "the expiry is
    -- confirmably LATER than it was before this call" (or newly set at
    -- all, if it was nil/no-expiry before).
    local oldExpiresAtUnix = cached.expiresAtUnix

    local updateOk, affectedRowsOrErr = pcall(K9Store.Cert_RenewExpiry, targetCitizenid, jobName, expiryDays)

    if not updateOk then
        print(('[qbx_k9unit] RenewCertification UPDATE failed for %s/%s: %s -- reconciling before reporting an outcome'):format(targetCitizenid, jobName, tostring(affectedRowsOrErr)))

        local freshRecord = QueryCertificationRecord(targetCitizenid, jobName)
        local reallyRenewed = freshRecord ~= nil and freshRecord.expiresAtUnix ~= nil
            and (oldExpiresAtUnix == nil or freshRecord.expiresAtUnix > oldExpiresAtUnix)
        if not reallyRenewed then
            -- Either confirmed the expiry never actually moved (the UPDATE
            -- genuinely never committed -- an honest failure, the target
            -- keeps their current, correct expiry) or unreadable/
            -- no-longer-active (outcome unknown or moot) -- in BOTH cases,
            -- never claim a renewal succeeded that this code cannot
            -- confirm, and never run the side effects below (outbound
            -- event, success notices, clearing the expiry-warning flags)
            -- against a guess. Mirrors SetCertificationTier's own
            -- identical branch.
            NotifyPlayer(granterSrc, locale('certifications.renew_error'), 'error')
            return false, 'db_error'
        end

        -- Confirmed extended despite the client-side error (e.g. a success
        -- acknowledgment lost after a real commit) -- fall through to the
        -- normal success path below against this now-confirmed truth;
        -- RefreshCertificationCache below will pick up the correct state.
    elseif not affectedRowsOrErr or affectedRowsOrErr == 0 then
        -- Zero rows matched: WHERE ... AND active = 1 found nothing -- this
        -- entry gate's own in-memory cache read was stale (a concurrent
        -- decertify/job-change landed in the window between that read and
        -- this UPDATE's own coroutine yield). Zero is a real, meaningful
        -- outcome here, never swallowed by an `or` fallback -- checked
        -- explicitly, same as RevokeCertification/SetCertificationTier's
        -- own identical branch.
        RefreshCertificationCache(targetCitizenid, jobName)
        NotifyPlayer(granterSrc, locale('certifications.target_not_actively_certified_needs_cert'), 'error')
        return false, 'target_not_actively_certified'
    end

    local _, _, freshlyVerified = RefreshCertificationCache(targetCitizenid, jobName)
    -- `freshlyVerified` gate (lifecycle QA pass): a could-not-determine
    -- outcome on THIS read-back keeps whatever cache entry already existed
    -- from BEFORE this renewal's own UPDATE -- i.e. the OLD expiry, not the
    -- new one this UPDATE (already confirmed committed above) just wrote.
    -- Without this gate, `newCached and newCached.expiresAtUnix` would
    -- happily read that stale pre-renewal value and report it as if it
    -- were the fresh renewal outcome.
    local newCached = freshlyVerified and Certifications[targetCitizenid]
    FireOutboundEvent('qbx_k9unit:events:certificationRenewed', targetCitizenid, jobName, newCached and newCached.expiresAtUnix, granterCitizenid)

    -- A successful, explicit renewal clears the one-per-session warning/
    -- lapsed flags — see the sweep thread below for why these exist; a
    -- fresh renewal genuinely un-lapses a certification, so the next
    -- sweep pass should be able to warn/announce again on its own future
    -- merits, not stay silenced by a flag set before this renewal.
    ExpiryWarned[targetCitizenid] = nil
    ExpiryLapsedNotified[targetCitizenid] = nil

    -- WORKFLOW CLARITY (this pass, item 5 — "renewing says what changed"):
    -- both success notices now say the ACTUAL new expiry, read straight
    -- back from the cache RefreshCertificationCache just repopulated from
    -- this UPDATE's own committed row -- never a value assumed from
    -- `expiryDays` (the CONFIGURED window), which is not necessarily the
    -- same number of days remaining from "now" once SQL's own
    -- `DATE_ADD(NOW(), ...)` clock and this comparison's clock are read a
    -- moment apart. Falls back to the plain, undated success text if the
    -- days-remaining figure is ever unavailable (e.g. `os.time` missing --
    -- see NowUnix's own doc comment) rather than showing a wrong number.
    local daysRemaining = newCached and DaysRemainingFromUnix(newCached.expiresAtUnix)
    if daysRemaining then
        NotifyPlayer(granterSrc, locale('certifications.renew_success_granter_detail', tostring(daysRemaining)), 'success')
        NotifyPlayer(targetServerId, locale('certifications.renew_success_target_detail', tostring(daysRemaining)), 'success')
    else
        NotifyPlayer(granterSrc, locale('certifications.renew_success_granter'), 'success')
        NotifyPlayer(targetServerId, locale('certifications.renew_success_target'), 'success')
    end
    return true, 'ok'
end

--- ======================================================================
--- OFFLINE-CAPABLE COUNTERPART TO RenewCertification (this pass) -- see
--- SetCertificationTierOffline's own doc comment immediately above for the
--- full "why an offline path is correct here" reasoning; identical logic
--- applies verbatim to renewal (no live-ped dependency, no
--- TierCapabilityPermits-style gate, pure "extend the paperwork" mutation
--- -- RenewCertification's own doc comment already calls this "re-affirming
--- paperwork, not re-verifying identity"). DB-authoritative precondition
--- (QueryCertificationRecord) and the SAME "refuse if actually online"
--- TOCTOU/proximity-bypass guard, for the identical reasons.
--- @param granterSrc number
--- @param citizenid string
--- @param jobName string
--- @return boolean ok
--- @return string outcome -- 'not_eligible' | 'on_cooldown' | 'feature_disabled' | 'invalid_target' | 'invalid_department' | 'target_online_use_online_action' | 'invalid_granter' | 'target_not_actively_certified' | 'db_error' | 'ok'
local function RenewCertificationOffline(granterSrc, citizenid, jobName)
    if not IsEligibleCertifier(granterSrc) then
        NotifyPlayer(granterSrc, locale('certifications.not_authorized_to_certify_hint'), 'error')
        return false, 'not_eligible'
    end

    if IsCertifyActionOnCooldown(granterSrc) then
        return false, 'on_cooldown'
    end

    local expiryDays = ResolveConfiguredExpiryDays()
    if not expiryDays then
        NotifyPlayer(granterSrc, locale('certifications.renew_feature_disabled'), 'error')
        return false, 'feature_disabled'
    end

    if type(citizenid) ~= 'string' or citizenid == '' or type(jobName) ~= 'string' or jobName == '' then
        NotifyPlayer(granterSrc, locale('certifications.usage_certify'), 'error')
        return false, 'invalid_target'
    end

    if not Config.Departments[jobName] then
        NotifyPlayer(granterSrc, locale('certifications.invalid_department_hint', jobName, ConfiguredDepartmentsList()), 'error')
        return false, 'invalid_department'
    end

    local onlineCheckTarget = exports.qbx_core:GetPlayerByCitizenId(citizenid)
    if onlineCheckTarget and onlineCheckTarget.PlayerData and onlineCheckTarget.PlayerData.source then
        NotifyPlayer(granterSrc, locale('certifications.renew_target_online_use_online_action', onlineCheckTarget.PlayerData.source), 'error')
        return false, 'target_online_use_online_action'
    end

    local granterCitizenid = ResolveGranterCitizenId(granterSrc)
    if not granterCitizenid then return false, 'invalid_granter' end

    local record = QueryCertificationRecord(citizenid, jobName)
    if not record then
        NotifyPlayer(granterSrc, locale('certifications.target_not_actively_certified_needs_cert'), 'error')
        return false, 'target_not_actively_certified'
    end

    -- AFFECTED-ROWS DEFECT FIX (data-truth audit pass) -- see
    -- RenewCertification's own identical doc comment above (the online
    -- twin) for the full "why this can affect zero rows with no thrown
    -- error at all, and why the reconciliation compares the fresh expiry
    -- against a pre-write baseline rather than a fixed target value"
    -- writeup; applies here verbatim -- the entry gate's own `record` above
    -- is a snapshot read that can go stale across this UPDATE's own
    -- coroutine yield exactly the same way the online path's in-memory
    -- cache read can.
    local oldExpiresAtUnix = record.expiresAtUnix

    local updateOk, affectedRowsOrErr = pcall(K9Store.Cert_RenewExpiry, citizenid, jobName, expiryDays)

    if not updateOk then
        print(('[qbx_k9unit] RenewCertificationOffline UPDATE failed for %s/%s: %s -- reconciling before reporting an outcome'):format(citizenid, jobName, tostring(affectedRowsOrErr)))

        local freshRecord = QueryCertificationRecord(citizenid, jobName)
        local reallyRenewed = freshRecord ~= nil and freshRecord.expiresAtUnix ~= nil
            and (oldExpiresAtUnix == nil or freshRecord.expiresAtUnix > oldExpiresAtUnix)
        if not reallyRenewed then
            -- Either confirmed the expiry never actually moved, or
            -- unreadable/no-longer-active -- never claim a renewal
            -- succeeded that this code cannot confirm. See
            -- RenewCertification's own identical branch for the full
            -- reasoning.
            NotifyPlayer(granterSrc, locale('certifications.renew_error'), 'error')
            return false, 'db_error'
        end

        -- Confirmed extended despite the client-side error -- fall
        -- through to the normal success path below against this
        -- now-confirmed truth.
    elseif not affectedRowsOrErr or affectedRowsOrErr == 0 then
        -- Zero rows matched -- a real, meaningful outcome, never
        -- swallowed by an `or` fallback -- checked explicitly, same as
        -- the online path's identical branch immediately above in this
        -- file.
        RefreshCertificationCache(citizenid, jobName)
        NotifyPlayer(granterSrc, locale('certifications.target_not_actively_certified_needs_cert'), 'error')
        return false, 'target_not_actively_certified'
    end

    RefreshCertificationCache(citizenid, jobName)
    local newRecord = QueryCertificationRecord(citizenid, jobName)
    FireOutboundEvent('qbx_k9unit:events:certificationRenewed', citizenid, jobName, newRecord and newRecord.expiresAtUnix, granterCitizenid)

    ExpiryWarned[citizenid] = nil
    ExpiryLapsedNotified[citizenid] = nil

    -- WORKFLOW CLARITY (this pass, item 5) -- see RenewCertification's own
    -- identical addition for the full writeup; the target is genuinely
    -- offline here, so only the granter gets a notice either way.
    local daysRemaining = newRecord and DaysRemainingFromUnix(newRecord.expiresAtUnix)
    if daysRemaining then
        NotifyPlayer(granterSrc, locale('certifications.renew_success_granter_detail', tostring(daysRemaining)), 'success')
    else
        NotifyPlayer(granterSrc, locale('certifications.renew_success_granter'), 'success')
    end
    return true, 'ok'
end

--- K9 COMMAND TABLET aggregation wrapper -- see
--- SetCertificationTierForTablet's own doc comment immediately above for
--- the full "resolve online, delegate to the proximity-checked function;
--- else fall through to the offline-capable one" shape this mirrors
--- exactly. Adds no authorization/cooldown logic of its own.
--- @param granterSrc number
--- @param citizenid string
--- @param departmentKey string
--- @return boolean ok
--- @return string outcome -- every RenewCertification/RenewCertificationOffline outcome, plus 'invalid_target' (shape) | 'invalid_department' | 'department_mismatch'
local function RenewCertificationForTablet(granterSrc, citizenid, departmentKey)
    local ok, outcome = (function()
        if type(citizenid) ~= 'string' or citizenid == '' or type(departmentKey) ~= 'string' or departmentKey == '' then
            return false, 'invalid_target'
        end
        if not Config.Departments[departmentKey] then
            return false, 'invalid_department'
        end

        local onlineTarget = exports.qbx_core:GetPlayerByCitizenId(citizenid)
        local onlineTargetSrc = onlineTarget and onlineTarget.PlayerData and onlineTarget.PlayerData.source
        if onlineTargetSrc then
            local liveJob = onlineTarget.PlayerData.job
            if not liveJob or liveJob.name ~= departmentKey then
                return false, 'department_mismatch'
            end
            return RenewCertification(granterSrc, onlineTargetSrc)
        end

        return RenewCertificationOffline(granterSrc, citizenid, departmentKey)
    end)()

    LogTabletCertAuditInvocation(granterSrc, 'tabletRenewCertification',
        ('target=%s department=%s'):format(tostring(citizenid), tostring(departmentKey)), outcome)
    return ok, outcome
end

--- Grants `specializationKey` (a `Config.K9Specializations` key) to
--- `targetServerId` for their OWN currently active department
--- certification. See header "SPECIALIZATIONS" / "WHY THIS DOES NOT REUSE
--- k9_permissions" for the full authorization/design writeup. Mirrors
--- GrantCertification's own online+proximity requirement and TOCTOU
--- lock shape (reusing the SAME `GrantInFlight` table under a distinct,
--- 'spec:'-prefixed key namespace so it can never collide with a base
--- certification's own lock key).
--- RETURN VALUE, ADDED THIS PASS (purely additive -- see
--- SetCertificationTier's own identical retrofit note above; every
--- pre-existing caller discards both values).
--- @param granterSrc number
--- @param targetServerId number
--- @param specializationKey string
--- @return boolean ok
--- @return string outcome -- 'invalid_target' | 'not_eligible' | 'on_cooldown' | 'invalid_specialization' | 'self_certification_disabled' | 'target_must_be_online' | 'target_too_far' | 'requires_active_cert' | 'requires_tier_capability' | 'already_granted' | 'invalid_granter' | 'db_error' | 'ok'
local function GrantSpecialization(granterSrc, targetServerId, specializationKey)
    if type(targetServerId) ~= 'number' then
        NotifyPlayer(granterSrc, locale('certifications.invalid_target_id'), 'error')
        return false, 'invalid_target'
    end

    if not IsEligibleCertifier(granterSrc) then
        NotifyPlayer(granterSrc, locale('certifications.not_authorized_to_certify_hint'), 'error')
        return false, 'not_eligible'
    end

    if IsCertifyActionOnCooldown(granterSrc) then
        return false, 'on_cooldown'
    end

    local catalog = type(Config.K9Specializations) == 'table' and Config.K9Specializations or {}
    if type(specializationKey) ~= 'string' or not catalog[specializationKey] then
        NotifyPlayer(granterSrc, locale('certifications.invalid_specialization_hint', ConfiguredSpecializationsList()), 'error')
        return false, 'invalid_specialization'
    end

    local isSelfCert = granterSrc == targetServerId
    if isSelfCert and not Config.AllowSelfCertification then
        NotifyPlayer(granterSrc, locale('certifications.self_certification_disabled_hint'), 'error')
        return false, 'self_certification_disabled'
    end

    -- WORKFLOW CLARITY (this pass, item 3): UNLIKE tier changes and
    -- renewals above, a specialization GRANT has NO offline counterpart at
    -- all, by design (see GrantSpecializationForTablet's own header) -- say
    -- so plainly rather than leaving the granter to go looking for an
    -- '/k9specializeoffline' command that does not exist.
    local targetPlayer = exports.qbx_core:GetPlayer(targetServerId)
    if not targetPlayer or not targetPlayer.PlayerData then
        NotifyPlayer(granterSrc, locale('certifications.specialization_target_must_be_online_no_offline'), 'error')
        return false, 'target_must_be_online'
    end

    if not isSelfCert then
        local granterPed = GetPlayerPed(granterSrc)
        local targetPed = GetPlayerPed(targetServerId)
        local dist = #(GetEntityCoords(granterPed) - GetEntityCoords(targetPed))
        if dist > Config.CertifyProximityMeters then
            NotifyPlayer(granterSrc, locale('certifications.action_target_too_far_distance', tostring(Config.CertifyProximityMeters)), 'error')
            return false, 'target_too_far'
        end
    end

    local targetCitizenid = targetPlayer.PlayerData.citizenid
    local jobName = targetPlayer.PlayerData.job and targetPlayer.PlayerData.job.name
    local cached = jobName and Certifications[targetCitizenid]
    -- SECURITY FIX (coder-security, tier-bypass-on-expiry review): this
    -- precondition used to omit `not cached.expired`, unlike
    -- GetCertificationTier a few hundred lines below (which this same
    -- file's own header already documents as requiring it). An
    -- EXPIRED-but-still-`active`-in-the-DB row (see RefreshCertificationCache's
    -- doc comment: `active` tracks "not manually revoked", `expired` is a
    -- SEPARATE, independent time-based flag) used to pass this check, so a
    -- certifier could hand a target a brand-new specialization at the exact
    -- moment enforcement should be STRICTER than normal -- the target's base
    -- certification has already lapsed -- not absent. Matches
    -- GetCertificationTier's own `not cached.expired` term exactly, so a
    -- target whose tier is unresolvable for this reason is refused here for
    -- the same, pre-existing "requires an active certification" reason,
    -- not a new one.
    if not (cached and cached.active and cached.job == jobName and not cached.expired) then
        NotifyPlayer(granterSrc, locale('certifications.specialization_requires_active_cert_hint'), 'error')
        return false, 'requires_active_cert'
    end

    -- CERTIFICATION TIER CAPABILITIES (this pass, coordinator-assigned --
    -- server/certtiers.lua's TierCapabilityPermits had zero real consumers
    -- anywhere in this resource until now). This is a SECOND, INDEPENDENT
    -- gate from the active-cert check directly above: `cached.active` and
    -- `cached.job == jobName` only prove the target holds SOME active
    -- certification for the right department, not that their CURRENT tier
    -- is one an operator has actually opted into allowing specializations
    -- for. Placed immediately after that check, never before it, so a
    -- target who fails the active-cert check gets that (more fundamental)
    -- reason, not this one.
    --
    -- Guarded with `type(...) == 'function'`, this resource's established
    -- soft-dependency convention -- server/certtiers.lua loads AFTER this
    -- file in fxmanifest.lua's server_scripts list, so this cannot be
    -- assumed present by load order (same reasoning as every other
    -- guarded cross-file call in this file). Fails OPEN (falls through to
    -- the grant path) when the global is absent -- matching
    -- TierCapabilityPermits' own documented fail-permissive contract, not
    -- a separate decision made here: every existing install predates tier
    -- capabilities entirely, and this call site failing closed on a
    -- missing/older server/certtiers.lua would silently strip a working
    -- specialization-grant flow for every operator who hasn't touched a
    -- single tier capability from the tablet.
    --
    -- GATES GRANTING ONLY, never holding: this is the ONE call site in
    -- this file that consults TierCapabilityPermits for specializations,
    -- and it runs only inside the grant flow above. HasSpecialization
    -- (this file, the read-only accessor every other feature actually
    -- calls to check whether a citizenid currently holds a specialization)
    -- does NOT call TierCapabilityPermits and must not be changed to --
    -- see that function's own doc comment. Nothing in this file cascades
    -- a tier change into stripping an already-granted specialization
    -- either (SetCertificationTier above never touches Specializations/
    -- the specialization DB rows at all), so a handler who already holds
    -- a specialization and whose tier later loses this capability (an
    -- operator un-ticks it from the tablet, or the handler is demoted)
    -- keeps that specialization exactly as HandlerPartnership/leash/etc.
    -- keep working after a permission source changes -- this gate only
    -- ever blocks a NEW grant, never revokes an existing one. If a future
    -- pass ever wants "losing the capability revokes the specialization
    -- too", that is a deliberate new decision belonging next to
    -- RevokeAllSpecializationsForCitizenJob, not an accidental side effect
    -- of this check.
    -- RETIRED: the certification-tier capability check
    -- (specializations_eligible) that used to sit here. Tiers and
    -- specializations are one thing now -- roles (server/roles.lua) --
    -- and a role's own XP requirement decides when it switches on
    -- (HasSpecialization). The tier editor is gone from the tablet, so a
    -- tier box ticked in the past could never be unticked; gating grants
    -- on it would strand high command with no way to give anyone a role.

    local lockKey = 'spec:' .. targetCitizenid .. ':' .. jobName .. ':' .. specializationKey
    if GrantInFlight[lockKey] then
        NotifyPlayer(granterSrc, locale('certifications.specialization_already_granted'), 'inform')
        return false, 'already_granted'
    end
    GrantInFlight[lockKey] = true

    -- RETURN VALUE, ADDED THIS PASS: `outcome` is set by doGrantInsert below
    -- (an upvalue, since doGrantInsert's own `return` exits the closure, not
    -- this outer function) and read back after the pcall -- identical shape
    -- to GrantCertification's own doGrantInsert/outcome pattern above.
    local outcome
    local function doGrantInsert()
        local existingId = K9Store.Spec_GetActiveId(targetCitizenid, jobName, specializationKey)
        if existingId then
            NotifyPlayer(granterSrc, locale('certifications.specialization_already_granted'), 'inform')
            outcome = 'already_granted'
            return
        end

        local granterCitizenid = ResolveGranterCitizenId(granterSrc)
        if not granterCitizenid then
            outcome = 'invalid_granter'
            return
        end

        -- TOCTOU FIX (concurrency audit; mirrors server/partnership.lua's
        -- respondPartnerUp critical section -- see that file's own
        -- "TOCTOU FIX" comment for the precedent this copies). The
        -- `cached.active`/`cached.job`/`not cached.expired` precondition a
        -- few dozen lines above this closure was read ONCE, synchronously,
        -- BEFORE GrantInFlight[lockKey] was ever set and BEFORE this
        -- doGrantInsert closure's own two genuinely-yielding MySQL awaits
        -- (K9Store.Spec_GetActiveId just above, K9Store.Spec_Insert just
        -- below) ever ran. RevokeCertification's own DB write
        -- (K9Store.Cert_RevokeActive) is itself a real await/yield point
        -- that can complete entirely inside that window and flip
        -- Certifications[targetCitizenid] to inactive underneath this
        -- coroutine -- nothing re-checked that afterwards. Concretely: two
        -- supervisors act on the same target at once -- one revokes while
        -- the other is mid-specialization-grant; the revoke's UPDATE
        -- commits and refreshes the cache while this grant is suspended at
        -- the pre-check SELECT above; this coroutine then resumed straight
        -- into the INSERT with no re-check, leaving a real, persisted
        -- specialization row for a citizenid who was decertified a moment
        -- earlier. HasSpecialization itself re-checks cached.active at
        -- READ time (see that function's own doc comment) so this was
        -- never a live capability bypass -- but the stray row silently
        -- reactivates the very next time this citizenid is recertified,
        -- with zero new grant action, which is the actual bug.
        --
        -- Re-read the LIVE cache here -- the last synchronous check before
        -- the INSERT, with nothing else yielding in between
        -- (ResolveGranterCitizenId immediately above is a synchronous,
        -- in-memory exports.qbx_core:GetPlayer call, never a MySQL round
        -- trip) -- so a concurrent revoke landing inside the window above
        -- is caught here, before the row is ever written, instead of
        -- leaving a stray row that quietly reactivates on a later,
        -- unrelated recertification. Same outcome/locale key the original,
        -- now-stale precondition check above uses, since this is the exact
        -- same refusal reason, just caught late instead of early.
        local freshCached = Certifications[targetCitizenid]
        if not (freshCached and freshCached.active and freshCached.job == jobName and not freshCached.expired) then
            NotifyPlayer(granterSrc, locale('certifications.specialization_requires_active_cert_hint'), 'error')
            outcome = 'requires_active_cert'
            return
        end

        local insertOk, insertErr = pcall(K9Store.Spec_Insert, targetCitizenid, jobName, specializationKey, granterCitizenid)

        if not insertOk then
            if IsDuplicateKeyError(insertErr) then
                RefreshSpecializationCache(targetCitizenid, jobName)
                NotifyPlayer(granterSrc, locale('certifications.specialization_already_granted'), 'inform')
                outcome = 'already_granted'
                return
            end
            print(('[qbx_k9unit] GrantSpecialization INSERT failed for %s/%s/%s: %s'):format(targetCitizenid, jobName, specializationKey, tostring(insertErr)))
            NotifyPlayer(granterSrc, locale('certifications.specialization_grant_error'), 'error')
            outcome = 'db_error'
            return
        end

        RefreshSpecializationCache(targetCitizenid, jobName)
        FireOutboundEvent('qbx_k9unit:events:specializationGranted', targetCitizenid, jobName, specializationKey, granterCitizenid)

        NotifyPlayer(granterSrc, locale('certifications.specialization_grant_success_granter', RoleNameForMessage(specializationKey)), 'success')
        NotifyPlayer(targetServerId, locale('certifications.specialization_grant_success_target', RoleNameForMessage(specializationKey)), 'success')
        outcome = 'ok'
    end

    local grantOk, grantErr = pcall(doGrantInsert)
    GrantInFlight[lockKey] = nil
    if not grantOk then
        print(('[qbx_k9unit] GrantSpecialization unexpected error for %s/%s/%s: %s'):format(targetCitizenid, jobName, specializationKey, tostring(grantErr)))
        NotifyPlayer(granterSrc, locale('certifications.specialization_grant_error'), 'error')
        return false, 'db_error'
    end

    return outcome == 'ok', outcome
end

--- K9 COMMAND TABLET aggregation wrapper -- keyed by citizenid. UNLIKE
--- SetCertificationTierForTablet/RenewCertificationForTablet above, this
--- has NO offline branch -- see GrantCertificationForTablet's own "OFFLINE-
--- GRANT ASYMMETRY" header for the general shape of why, and this pass's
--- own report for the specific reason it applies here too: GrantSpecialization's
--- `not cached.expired` precondition and its TierCapabilityPermits gate
--- (both explicitly "do not weaken" per this pass's own instructions) are
--- read from the ONLINE-ONLY `Certifications`/tier-cache state, which is
--- evicted entirely on `playerDropped` -- reconstructing them from
--- QueryCertificationRecord (the DB-authoritative read SetCertificationTierOffline/
--- RenewCertificationOffline use) would still leave TierCapabilityPermits
--- itself unable to resolve a real tier for an offline citizenid (it is
--- cache-based, not DB-based, by its own design), silently making it
--- fail OPEN for every offline grant regardless of what an operator has
--- actually configured for that citizenid's tier -- exactly the "weakening"
--- this task explicitly forbids. A GRANT is also, structurally, the
--- "extend this citizenid's capability" direction (like GrantCertification),
--- not the "paperwork/removal" direction offline support was extended to
--- (renewal, tier reassignment, revoke) -- so, like GrantCertificationForTablet,
--- this fails closed with 'target_must_be_online' for a disconnected
--- target rather than shipping a materially weaker grant path.
--- @param granterSrc number
--- @param citizenid string
--- @param departmentKey string
--- @param specializationKey string
--- @return boolean ok
--- @return string outcome -- every GrantSpecialization outcome, plus 'invalid_target' (shape) | 'invalid_department' | 'target_must_be_online' | 'department_mismatch'
local function GrantSpecializationForTablet(granterSrc, citizenid, departmentKey, specializationKey)
    local ok, outcome = (function()
        if type(citizenid) ~= 'string' or citizenid == '' or type(departmentKey) ~= 'string' or departmentKey == ''
            or type(specializationKey) ~= 'string' or specializationKey == '' then
            return false, 'invalid_target'
        end
        if not Config.Departments[departmentKey] then
            return false, 'invalid_department'
        end

        local onlineTarget = exports.qbx_core:GetPlayerByCitizenId(citizenid)
        local onlineTargetSrc = onlineTarget and onlineTarget.PlayerData and onlineTarget.PlayerData.source
        if not onlineTargetSrc then
            return false, 'target_must_be_online'
        end

        local liveJob = onlineTarget.PlayerData.job
        if not liveJob or liveJob.name ~= departmentKey then
            return false, 'department_mismatch'
        end

        return GrantSpecialization(granterSrc, onlineTargetSrc, specializationKey)
    end)()

    LogTabletCertAuditInvocation(granterSrc, 'tabletGrantSpecialization',
        ('target=%s department=%s specialization=%s'):format(tostring(citizenid), tostring(departmentKey), tostring(specializationKey)), outcome)
    return ok, outcome
end

--- Revokes `specializationKey` from `targetServerId` (online-capable
--- path — see RevokeSpecializationOffline below for a genuinely
--- disconnected target). Mirrors RevokeCertification's own online
--- proximity rule; does NOT require the base certification to still be
--- active (a specialization can legitimately be pulled independently of
--- the base cert, e.g. a narcotics-specific disciplinary issue that
--- doesn't warrant a full decertification).
--- RETURN VALUE, ADDED THIS PASS (purely additive -- see
--- SetCertificationTier's own identical retrofit note above; every
--- pre-existing caller discards both values).
--- @param granterSrc number
--- @param targetServerId number
--- @param specializationKey string
--- @return boolean ok
--- @return string outcome -- 'invalid_target' | 'not_eligible' | 'on_cooldown' | 'invalid_specialization' | 'self_certification_disabled' | 'target_offline' | 'target_too_far' | 'target_no_department_cert' | 'invalid_granter' | 'db_error' | 'not_granted' | 'ok'
local function RevokeSpecialization(granterSrc, targetServerId, specializationKey)
    if type(targetServerId) ~= 'number' then
        NotifyPlayer(granterSrc, locale('certifications.invalid_target_id'), 'error')
        return false, 'invalid_target'
    end

    if not IsEligibleCertifier(granterSrc) then
        NotifyPlayer(granterSrc, locale('certifications.not_authorized_to_revoke_hint'), 'error')
        return false, 'not_eligible'
    end

    if IsCertifyActionOnCooldown(granterSrc) then
        return false, 'on_cooldown'
    end

    if type(specializationKey) ~= 'string' or specializationKey == '' then
        NotifyPlayer(granterSrc, locale('certifications.invalid_specialization_hint', ConfiguredSpecializationsList()), 'error')
        return false, 'invalid_specialization'
    end

    local isSelfCert = granterSrc == targetServerId
    if isSelfCert and not Config.AllowSelfCertification then
        NotifyPlayer(granterSrc, locale('certifications.self_certification_disabled_hint'), 'error')
        return false, 'self_certification_disabled'
    end

    local targetPlayer = exports.qbx_core:GetPlayer(targetServerId)
    if not targetPlayer or not targetPlayer.PlayerData then
        NotifyPlayer(granterSrc, locale('certifications.specialization_target_offline_use_offline_command'), 'error')
        return false, 'target_offline'
    end

    if not isSelfCert then
        local granterPed = GetPlayerPed(granterSrc)
        local targetPed = GetPlayerPed(targetServerId)
        local dist = #(GetEntityCoords(granterPed) - GetEntityCoords(targetPed))
        if dist > Config.CertifyProximityMeters then
            NotifyPlayer(granterSrc, locale('certifications.action_target_too_far_distance', tostring(Config.CertifyProximityMeters)), 'error')
            return false, 'target_too_far'
        end
    end

    local targetCitizenid = targetPlayer.PlayerData.citizenid
    local jobName = targetPlayer.PlayerData.job and targetPlayer.PlayerData.job.name
    if not jobName or not Config.Departments[jobName] then
        NotifyPlayer(granterSrc, locale('certifications.target_no_department_cert'), 'error')
        return false, 'target_no_department_cert'
    end

    local granterCitizenid = ResolveGranterCitizenId(granterSrc)
    if not granterCitizenid then return false, 'invalid_granter' end

    local updateOk, affectedRowsOrErr = pcall(K9Store.Spec_RevokeOne, targetCitizenid, jobName, specializationKey, granterCitizenid)

    if not updateOk then
        print(('[qbx_k9unit] RevokeSpecialization UPDATE failed for %s/%s/%s: %s'):format(targetCitizenid, jobName, specializationKey, tostring(affectedRowsOrErr)))
        NotifyPlayer(granterSrc, locale('certifications.specialization_revoke_error'), 'error')
        return false, 'db_error'
    elseif not affectedRowsOrErr or affectedRowsOrErr == 0 then
        NotifyPlayer(granterSrc, locale('certifications.specialization_not_granted'), 'inform')
        return false, 'not_granted'
    end

    RefreshSpecializationCache(targetCitizenid, jobName)
    FireOutboundEvent('qbx_k9unit:events:specializationRevoked', targetCitizenid, jobName, specializationKey, 'manual')

    NotifyPlayer(granterSrc, locale('certifications.specialization_revoke_success_granter', RoleNameForMessage(specializationKey)), 'success')
    NotifyPlayer(targetServerId, locale('certifications.specialization_revoke_success_target', RoleNameForMessage(specializationKey)), 'error')
    return true, 'ok'
end

--- Offline-capable counterpart to RevokeSpecialization, mirroring
--- RevokeCertificationOffline's exact shape (own online-check guard,
--- deliberately no proximity check — impossible against a disconnected
--- target).
---
--- RETURN VALUE, ADDED THIS PASS (purely additive -- see
--- SetCertificationTier's own identical retrofit note above; this
--- function's only pre-existing caller, the '/k9unspecializeoffline'
--- command below, discards both values).
--- @param granterSrc number
--- @param citizenid string
--- @param job string
--- @param specializationKey string
--- @return boolean ok
--- @return string outcome -- 'not_eligible' | 'on_cooldown' | 'invalid_args' | 'invalid_department' | 'invalid_granter' | 'target_online_use_online_action' | 'db_error' | 'not_granted' | 'ok'
local function RevokeSpecializationOffline(granterSrc, citizenid, job, specializationKey)
    if not IsEligibleCertifier(granterSrc) then
        NotifyPlayer(granterSrc, locale('certifications.not_authorized_to_revoke_hint'), 'error')
        return false, 'not_eligible'
    end

    if IsCertifyActionOnCooldown(granterSrc) then
        return false, 'on_cooldown'
    end

    if type(citizenid) ~= 'string' or citizenid == '' or type(job) ~= 'string' or job == ''
        or type(specializationKey) ~= 'string' or specializationKey == '' then
        NotifyPlayer(granterSrc, locale('certifications.usage_unspecialize'), 'error')
        return false, 'invalid_args'
    end

    if not Config.Departments[job] then
        NotifyPlayer(granterSrc, locale('certifications.invalid_department_hint', job, ConfiguredDepartmentsList()), 'error')
        return false, 'invalid_department'
    end

    local granterCitizenid = ResolveGranterCitizenId(granterSrc)
    if not granterCitizenid then return false, 'invalid_granter' end

    local onlineCheckTarget = exports.qbx_core:GetPlayerByCitizenId(citizenid)
    if onlineCheckTarget and onlineCheckTarget.PlayerData and onlineCheckTarget.PlayerData.source then
        NotifyPlayer(granterSrc, locale('certifications.specialization_target_online_use_online_command', onlineCheckTarget.PlayerData.source), 'error')
        return false, 'target_online_use_online_action'
    end

    local updateOk, affectedRowsOrErr = pcall(K9Store.Spec_RevokeOne, citizenid, job, specializationKey, granterCitizenid)

    if not updateOk then
        print(('[qbx_k9unit] RevokeSpecializationOffline UPDATE failed for %s/%s/%s: %s'):format(citizenid, job, specializationKey, tostring(affectedRowsOrErr)))
        NotifyPlayer(granterSrc, locale('certifications.specialization_revoke_error'), 'error')
        return false, 'db_error'
    elseif not affectedRowsOrErr or affectedRowsOrErr == 0 then
        NotifyPlayer(granterSrc, locale('certifications.specialization_not_granted'), 'inform')
        return false, 'not_granted'
    end

    RefreshSpecializationCache(citizenid, job)
    FireOutboundEvent('qbx_k9unit:events:specializationRevoked', citizenid, job, specializationKey, 'manual_offline')

    NotifyPlayer(granterSrc, locale('certifications.specialization_revoke_success_granter', RoleNameForMessage(specializationKey)), 'success')
    return true, 'ok'
end

--- K9 COMMAND TABLET aggregation wrapper -- see
--- SetCertificationTierForTablet's own doc comment above for the full
--- "resolve online, delegate to the proximity-checked function; else fall
--- through to the offline-capable one" shape this mirrors exactly. A
--- specialization REVOKE is the "remove a capability" direction (like
--- RevokeCertification/RevokeCertificationOffline, which this file's
--- header §4.3 already requires to work offline), not the "grant a new
--- one" direction GrantSpecializationForTablet's own doc comment explains
--- must stay online-only -- RevokeSpecializationOffline already existed
--- before this pass specifically to close that exact gap.
--- @param granterSrc number
--- @param citizenid string
--- @param departmentKey string
--- @param specializationKey string
--- @return boolean ok
--- @return string outcome -- every RevokeSpecialization/RevokeSpecializationOffline outcome, plus 'invalid_target' (shape) | 'invalid_department' | 'department_mismatch'
local function RevokeSpecializationForTablet(granterSrc, citizenid, departmentKey, specializationKey)
    local ok, outcome = (function()
        if type(citizenid) ~= 'string' or citizenid == '' or type(departmentKey) ~= 'string' or departmentKey == ''
            or type(specializationKey) ~= 'string' or specializationKey == '' then
            return false, 'invalid_target'
        end
        if not Config.Departments[departmentKey] then
            return false, 'invalid_department'
        end

        local onlineTarget = exports.qbx_core:GetPlayerByCitizenId(citizenid)
        local onlineTargetSrc = onlineTarget and onlineTarget.PlayerData and onlineTarget.PlayerData.source
        if onlineTargetSrc then
            local liveJob = onlineTarget.PlayerData.job
            if not liveJob or liveJob.name ~= departmentKey then
                return false, 'department_mismatch'
            end
            return RevokeSpecialization(granterSrc, onlineTargetSrc, specializationKey)
        end

        return RevokeSpecializationOffline(granterSrc, citizenid, departmentKey, specializationKey)
    end)()

    LogTabletCertAuditInvocation(granterSrc, 'tabletRevokeSpecialization',
        ('target=%s department=%s specialization=%s'):format(tostring(citizenid), tostring(departmentKey), tostring(specializationKey)), outcome)
    return ok, outcome
end

-- ======================================================================
-- PUBLISHED TO THE LATER FILES IN THIS SPLIT (see this file's own
-- header). Transport only -- not a public API.
-- ======================================================================
K9Cert.GrantSpecialization = GrantSpecialization
K9Cert.GrantSpecializationForTablet = GrantSpecializationForTablet
K9Cert.RenewCertification = RenewCertification
K9Cert.RenewCertificationForTablet = RenewCertificationForTablet
K9Cert.RenewCertificationOffline = RenewCertificationOffline
K9Cert.RevokeCertificationForTablet = RevokeCertificationForTablet
K9Cert.RevokeSpecialization = RevokeSpecialization
K9Cert.RevokeSpecializationForTablet = RevokeSpecializationForTablet
K9Cert.RevokeSpecializationOffline = RevokeSpecializationOffline
K9Cert.SetCertificationTier = SetCertificationTier
K9Cert.SetCertificationTierForTablet = SetCertificationTierForTablet
K9Cert.SetCertificationTierOffline = SetCertificationTierOffline

