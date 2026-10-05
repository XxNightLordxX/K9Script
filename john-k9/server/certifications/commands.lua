--[[
    john-k9/server/certifications/commands.lua

    The command surface and the tablet callbacks -- every way a human
    reaches the three files above -- plus the background expiry sweeps.

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


-- Re-bound from the shared K9Cert transport (see this file's own header).
-- Same names as in the original single file, so every body below is
-- unchanged.
local CertificationCheckUnresolved = K9Cert.CertificationCheckUnresolved
local Certifications = K9Cert.Certifications
local ConfiguredDepartmentsList = K9Cert.ConfiguredDepartmentsList
local ExpiryLapsedNotified = K9Cert.ExpiryLapsedNotified
local ExpiryWarned = K9Cert.ExpiryWarned
local GrantCertification = K9Cert.GrantCertification
local GrantCertificationForTablet = K9Cert.GrantCertificationForTablet
local GrantCertificationOffline = K9Cert.GrantCertificationOffline
local GrantSpecialization = K9Cert.GrantSpecialization
local GrantSpecializationForTablet = K9Cert.GrantSpecializationForTablet
local NowUnix = K9Cert.NowUnix
local RenewCertification = K9Cert.RenewCertification
local RenewCertificationForTablet = K9Cert.RenewCertificationForTablet
local RenewCertificationOffline = K9Cert.RenewCertificationOffline
local ResolveConfiguredExpiryDays = K9Cert.ResolveConfiguredExpiryDays
local ResolveConfiguredExpiryWarningDays = K9Cert.ResolveConfiguredExpiryWarningDays
local RevokeCertification = K9Cert.RevokeCertification
local RevokeCertificationForTablet = K9Cert.RevokeCertificationForTablet
local RevokeCertificationOffline = K9Cert.RevokeCertificationOffline
local RevokeSpecialization = K9Cert.RevokeSpecialization
local RevokeSpecializationForTablet = K9Cert.RevokeSpecializationForTablet
local RevokeSpecializationOffline = K9Cert.RevokeSpecializationOffline
local SetCertificationTier = K9Cert.SetCertificationTier
local SetCertificationTierForTablet = K9Cert.SetCertificationTierForTablet
local SetCertificationTierOffline = K9Cert.SetCertificationTierOffline
local Specializations = K9Cert.Specializations

-- ======================================================================
-- TABLET CALLBACK -- see GrantCertificationForTablet's own doc comment
-- above for the full "offline-grant asymmetry" writeup. Gated on
-- Config.Features.CommandTablet AT REGISTRATION TIME, mirroring
-- server/permissions.lua's identical "TABLET CALLBACKS" gate (that file's
-- own header: "gate at registration, not just inside the handler")
-- -- independent of whether this file's own underlying feature checks
-- (Config.AllowSelfCertification, IsEligibleCertifier's own rank/grant/
-- high-command resolution) would themselves allow anything; registering
-- this callback regardless of THOSE lets the tablet render a real,
-- specific denial reason instead of the callback not existing at all.
-- `source` is ox_lib's own callback dispatch value (server-verified, never
-- a client-supplied one) and is passed straight through as `granterSrc` --
-- GrantCertificationForTablet/GrantCertification already independently
-- re-verify eligibility from that source's own live job, so this wrapper
-- adds no authorization logic of its own, only the return-shape
-- translation client/tablet.lua's AwaitServerCallback expects.
-- ======================================================================
if Config.Features and Config.Features.CommandTablet == true then
    -- `k9Model`: nil certifies a handler (no change to how they look); a
    -- Config.Peds model certifies them AS A K9 of that breed, in the same
    -- step. See core.lua's "CERTIFY AS HANDLER OR AS K9".
    lib.callback.register('john-k9:server:tabletCertify', function(source, targetCitizenid, departmentKey, k9Model)
        local ok, outcome = GrantCertificationForTablet(source, targetCitizenid, departmentKey, k9Model)
        if ok then return { ok = true } end
        return { ok = false, error = outcome }
    end)

    -- BUGFIX (this pass, docs/history/COMMAND_CONSOLIDATION_SPEC.md §6) -- symmetric with
    -- tabletCertify immediately above. Was previously reached via
    -- client/tablet.lua's SubmitAllowlistedCommand -> '/k9decertifyoffline'
    -- bridge, which structurally could not succeed against a currently
    -- online target (RevokeCertificationOffline's own online-target
    -- refusal). RevokeCertificationForTablet's own doc comment above has
    -- the full writeup; `source` is ox_lib's own server-verified callback
    -- dispatch value, passed straight through as `granterSrc`, same as
    -- every other tablet callback in this file.
    lib.callback.register('john-k9:server:tabletDecertify', function(source, targetCitizenid, departmentKey)
        local ok, outcome = RevokeCertificationForTablet(source, targetCitizenid, departmentKey)
        if ok then return { ok = true } end
        return { ok = false, error = outcome }
    end)

    -- ==================================================================
    -- CERTIFICATION DEPTH (this pass) — the four tablet callbacks closing
    -- this file's biggest remaining "reachable only via net event/command,
    -- no tablet path at all" gap: tier assignment, renewal, and
    -- specialization grant/revoke. SAME shape as tabletCertify immediately
    -- above in every respect: `source` is ox_lib's own server-verified
    -- callback dispatch value, passed straight through as `granterSrc`;
    -- each *ForTablet wrapper already independently re-verifies
    -- IsEligibleCertifier/the shared CertifyActionCooldown/TierEditMutex
    -- internally (via whichever underlying online/offline function it
    -- delegates to), so none of these four add any authorization,
    -- rate-limiting, or locking logic of their own -- only the
    -- return-shape translation client/tablet.lua's AwaitServerCallback
    -- expects, plus the tablet-invocation audit line
    -- (LogTabletCertAuditInvocation, inside each *ForTablet wrapper).
    -- ==================================================================
    lib.callback.register('john-k9:server:tabletSetCertificationTier', function(source, targetCitizenid, departmentKey, newTier)
        local ok, outcome = SetCertificationTierForTablet(source, targetCitizenid, departmentKey, newTier)
        if ok then return { ok = true } end
        return { ok = false, error = outcome }
    end)

    lib.callback.register('john-k9:server:tabletRenewCertification', function(source, targetCitizenid, departmentKey)
        local ok, outcome = RenewCertificationForTablet(source, targetCitizenid, departmentKey)
        if ok then return { ok = true } end
        return { ok = false, error = outcome }
    end)

    lib.callback.register('john-k9:server:tabletGrantSpecialization', function(source, targetCitizenid, departmentKey, specializationKey)
        local ok, outcome = GrantSpecializationForTablet(source, targetCitizenid, departmentKey, specializationKey)
        if ok then return { ok = true } end
        return { ok = false, error = outcome }
    end)

    lib.callback.register('john-k9:server:tabletRevokeSpecialization', function(source, targetCitizenid, departmentKey, specializationKey)
        local ok, outcome = RevokeSpecializationForTablet(source, targetCitizenid, departmentKey, specializationKey)
        if ok then return { ok = true } end
        return { ok = false, error = outcome }
    end)
end

-- The two walk-up events (the old third-eye Certify / Revoke options) are
-- admin chat surface too: only registered with the admin switch on. The
-- third-eye options themselves are gone -- certifying is on the tablet.
local function AdminChatCommandsOn()
    return type(Config.CommandTablet) == 'table' and Config.CommandTablet.adminChatCommands == true
end

if AdminChatCommandsOn() then
RegisterNetEvent('john-k9:server:certifyHandler', function(targetServerId)
    GrantCertification(source, targetServerId)
end)

-- CERTIFICATION DEPTH (this pass, Part A §2): `reason` is a new, optional
-- second argument — an existing client that only ever sends one argument
-- (e.g. client/movement.lua's `TriggerServerEvent('john-k9:server:revokeHandler',
-- GetPlayerServerId(targetPlayer))`) is unaffected: `reason` is simply nil.
RegisterNetEvent('john-k9:server:revokeHandler', function(targetServerId, reason)
    RevokeCertification(source, targetServerId, reason)
end)
end

-- ======================================================================
-- COMMAND CONSOLIDATION (docs/history/COMMAND_CONSOLIDATION_SPEC.md §2/§5 item 8) --
-- k9certify/k9certifyoffline, k9decertify/k9decertifyoffline,
-- k9settier/k9settieroffline, k9recertify/k9recertifyoffline,
-- k9unspecialize/k9unspecializeoffline: 10 commands -> 5. RESOLUTION RULE,
-- reused verbatim from server/dogcharacter.lua's own ResolveTargetCitizenId
-- (not re-derived): `tonumber(args[1])` succeeds -> the argument is a
-- server id, call the ONLINE function, UNCHANGED; fails -> it is a
-- citizenid string, call the OFFLINE function, UNCHANGED. No new
-- resolution/validation logic lives in these dispatchers themselves -- each
-- of the 10 underlying functions already does its own shape validation
-- (and its own usage notify) internally, so the dispatcher only ever
-- decides WHICH already-gated, already-validating function to call, then
-- forwards the rest of `args` unchanged. Confirmed (docs/history/COMMAND_CONSOLIDATION_SPEC.md
-- §1): all 11 grant/revoke/tier/renew/specialization functions in this
-- file share the exact same IsEligibleCertifier gate and
-- IsCertifyActionOnCooldown budget -- merging on the online/offline axis
-- widens nothing.
--
-- RECYCLED SERVER IDS: not a new risk this merge introduces. The numeral
-- is forwarded unchanged straight into the existing online function, which
-- already resolves it to a live Player/citizenid SYNCHRONOUSLY, in the
-- same tick, via exports.qbx_core:GetPlayer(targetServerId) -- nothing is
-- ever cached or persisted keyed on the raw numeral, before or after this
-- change. A numeral that no longer resolves to a connected player hits
-- that function's own existing "target must be online"/"target offline"
-- refusal, exactly as /k9certify [server id] already did against a
-- disconnected id before this pass.
--
-- HIDDEN ALIASES (§3): k9certifyoffline/k9decertifyoffline/
-- k9settieroffline/k9recertifyoffline/k9unspecializeoffline stay
-- registered forever, UNCHANGED bodies, as the explicit escape hatch for a
-- genuinely all-digit citizenid (§2's own disclosed ambiguity note) and for
-- existing macros/cheat-sheets. No longer chat-suggested
-- (client/commandsuggestions.lua) or listed in html/tablet.js's own
-- COMMAND_REFERENCE -- see both files' HIDDEN_ALIAS_COMMANDS allowlists.
-- ======================================================================

--- Should `/k9certify` route this target to RENEW rather than GRANT?
---
--- ROUTING ONLY, NEVER AN AUTHORIZATION DECISION. This answers one narrow
--- question -- "is there an existing certification here to extend?" -- and
--- nothing else. Both branches it routes between (RenewCertification /
--- GrantCertification) re-run the FULL eligibility, cooldown, self-certify,
--- proximity and department checks from the caller's own live state, exactly
--- as they did when they were two separate commands. Nothing here can grant
--- anyone anything, and a wrong answer costs at most a less helpful refusal
--- message, never a permission.
---
--- TWO CONDITIONS, BOTH REQUIRED:
---   1. The target genuinely holds an ACTIVE certification in the department
---      they are currently in -- read from the same `Certifications` cache,
---      with the same active/job comparison, that RenewCertification itself
---      uses to decide whether there is anything to renew.
---   2. Certification expiry is actually switched on. If it is off,
---      RenewCertification refuses outright with `renew_feature_disabled`,
---      which would be a WORSE answer for the caller than the honest
---      "they are already certified" hint GrantCertification gives -- so an
---      already-certified target on a server with expiry off deliberately
---      still falls through to the grant path.
--- Decide which SHAPE a certification-family target argument is: a live
--- server id, or a citizenid to look up in the database.
---
--- THE RULE IS DELIBERATELY SIMPLE AND UNCONDITIONAL: all digits means a
--- server id, anything else means a citizenid. It never consults who is
--- actually connected, so the same typed argument always takes the same
--- path and always produces the same error message -- an operator who
--- types the server id of someone who just disconnected gets the plain
--- "that target must be online" answer, not a confusing report about a
--- citizenid they never typed.
---
--- THE ALL-DIGIT CITIZENID CASE. A citizenid made entirely of digits is
--- legal (IsValidCitizenId accepts any non-empty string up to 50 chars), and
--- this rule cannot reach one from chat -- it would always be read as a
--- server id. That is not a gap: the TABLET is the unambiguous path for it.
--- Every tablet certification callback (tabletSetCertificationTier,
--- tabletRenewCertification, and the certify/revoke pair) takes
--- `targetCitizenid` and `departmentKey` as SEPARATE, explicitly-typed
--- arguments, so no digits-versus-id guess happens there at all.
---
--- This is why the five `*offline` alias commands could be deleted
--- (2026-09-02, at the owner's request) without losing reach: they existed
--- as the chat-side escape hatch for exactly this case, and the tablet
--- covers it properly.
---
--- ROUTING ONLY, NEVER AN AUTHORIZATION DECISION -- the same guarantee
--- ShouldRenewOnlineTarget makes just below, and for the same reason: both
--- branches this routes between re-run the FULL eligibility, cooldown,
--- self-certify, proximity and department checks from the caller's own live
--- state. Nothing here can grant anyone anything.
--- @param arg string
--- @return number? serverId
--- @return string? citizenid
local function ResolveCertificationTarget(arg)
    if type(arg) ~= 'string' or arg == '' then return nil, nil end
    local asNumber = tonumber(arg)
    if asNumber then return asNumber, nil end
    return nil, arg
end

--- @param targetServerId number
--- @return boolean
local function ShouldRenewOnlineTarget(targetServerId)
    if not ResolveConfiguredExpiryDays() then return false end

    local ok, targetPlayer = pcall(function() return exports.qbx_core:GetPlayer(targetServerId) end)
    if not ok or not targetPlayer or not targetPlayer.PlayerData then return false end

    local targetCitizenid = targetPlayer.PlayerData.citizenid
    local jobName = targetPlayer.PlayerData.job and targetPlayer.PlayerData.job.name
    if type(targetCitizenid) ~= 'string' or type(jobName) ~= 'string' then return false end

    local cached = Certifications[targetCitizenid]
    return (cached and cached.active and cached.job == jobName) == true
end

--- The offline half of ShouldRenewOnlineTarget -- same contract, same
--- "routing only" guarantee, reading the stored record the way
--- RenewCertificationOffline itself does rather than the in-memory cache
--- (an offline citizenid may have no cache entry at all).
--- @param citizenid string
--- @param jobName string
--- @return boolean
local function ShouldRenewOfflineTarget(citizenid, jobName)
    if not ResolveConfiguredExpiryDays() then return false end
    if type(citizenid) ~= 'string' or citizenid == '' then return false end
    if type(jobName) ~= 'string' or jobName == '' then return false end
    if not Config.Departments[jobName] then return false end

    local ok, record = pcall(QueryCertificationRecord, citizenid, jobName)
    return (ok and record ~= nil) == true
end

-- MERGED COMMAND (2026-09-02, owner's request: "Merge /k9certify
-- /k9recertify all together").
--
-- One command now covers both jobs, because from a certifier's point of
-- view they were never really two: you walk up to someone and make their
-- certification current. Whether that means creating it or extending it is
-- a fact about the target's record, not a decision the certifier should
-- have to make before they can type anything -- and getting it wrong used
-- to mean a refusal ("they are already certified" / "they are not certified
-- yet") and a second command.
--
-- `/k9recertify` still works, as an undocumented alias -- same convention
-- the audit and dog-record merges used, so nobody's muscle memory or
-- keybind breaks.
--
-- EVERY GATE IS UNCHANGED. This routes; it does not authorize. See
-- ShouldRenewOnlineTarget's own header.
RegisterAdminCommand('k9certify', function(source, args)
    -- DISCOVERABILITY (§4): a totally bare `/k9certify` has no target of
    -- EITHER shape to resolve -- show the combined usage string (both
    -- shapes) rather than silently falling into the offline branch below
    -- and showing only ITS narrower usage message, which would mislead a
    -- caller who never intended the offline form at all.
    if args[1] == nil or args[1] == '' then
        local usage = locale('certifications.usage_certify')
        if source == 0 then print('[John-K9] ' .. usage) else NotifyPlayer(source, usage, 'error') end
        return
    end
    local targetServerId, citizenid = ResolveCertificationTarget(args[1])
    if targetServerId then
        if ShouldRenewOnlineTarget(targetServerId) then
            RenewCertification(source, targetServerId)
        else
            GrantCertification(source, targetServerId)
        end
    else
        if ShouldRenewOfflineTarget(citizenid, args[2]) then
            RenewCertificationOffline(source, citizenid, args[2])
        else
            GrantCertificationOffline(source, citizenid, args[2])
        end
    end
end, false)


RegisterAdminCommand('k9decertify', function(source, args)
    -- DISCOVERABILITY (§4): same "show the combined usage, not the narrower
    -- offline one" reasoning as k9certify above.
    if args[1] == nil or args[1] == '' then
        local usage = locale('certifications.usage_decertify')
        if source == 0 then print('[John-K9] ' .. usage) else NotifyPlayer(source, usage, 'error') end
        return
    end
    local targetServerId, citizenid = ResolveCertificationTarget(args[1])
    if targetServerId then
        -- CERTIFICATION DEPTH (this pass, Part A §2): args[2], an optional
        -- reason code — nil if omitted, exactly like before this pass.
        RevokeCertification(source, targetServerId, args[2])
    else
        -- Offline shape shifts by one position (§2's own "argument-shape
        -- note"): citizenid, job, [reason] -- args[3], not args[2].
        RevokeCertificationOffline(source, citizenid, args[2], args[3])
    end
end, false)


-- ======================================================================
-- CERTIFICATION DEPTH (this pass) — commands for tier/renewal/
-- specialization. An earlier version of this section also registered a
-- RegisterNetEvent per action (mirroring the "command and event both call
-- the same internal function" convention every action above still uses
-- for certify/decertify) -- REMOVED this pass (integration sweep): a
-- registered net event is a live, client-reachable surface regardless of
-- whether anything legitimate calls it, and nothing did. Verified against
-- the whole tree, including html/: no TriggerServerEvent anywhere in
-- client/ or html/ for setCertificationTier/renewCertification/
-- grantSpecialization/revokeSpecialization -- the only callers were
-- tests/certifications_spec.lua invoking the handler function directly
-- through its fake event-dispatch table. The functionality itself is not
-- missing to players: every one of these four actions is reachable two
-- other ways that remain -- the four RegisterCommand blocks immediately
-- below (k9settier/k9recertify/k9specialize/k9unspecialize, unchanged),
-- and the tablet's own complete lib.callback.register contract
-- (tabletSetCertificationTier/tabletRenewCertification/
-- tabletGrantSpecialization/tabletRevokeSpecialization, near the end of
-- this file, correctly consumed by client/tablet.lua's own
-- tablet:setCertificationTier/renewCertification/grantSpecialization/
-- revokeSpecialization NUI bridges and html/tablet.js's runMutation()).
-- Four endpoints nothing legitimate called were four things an attacker
-- still could, and every one mutates certification state -- deleted
-- rather than left as a comment describing them as unreachable-by-design.
-- ======================================================================

-- COMMAND CONSOLIDATION (§2/§5 item 8) -- same dispatcher shape as
-- k9certify/k9decertify above; see that block's own header comment for the
-- full resolution-rule/recycled-id/hidden-alias writeup, not repeated here.
RegisterAdminCommand('k9settier', function(source, args)
    if args[1] == nil or args[1] == '' then
        local usage = locale('certifications.usage_settier')
        if source == 0 then print('[John-K9] ' .. usage) else NotifyPlayer(source, usage, 'error') end
        return
    end
    local targetServerId, citizenid = ResolveCertificationTarget(args[1])
    if targetServerId then
        SetCertificationTier(source, targetServerId, args[2])
    else
        -- Offline shape shifts by one position: citizenid, job, tier --
        -- args[3], not args[2].
        SetCertificationTierOffline(source, citizenid, args[2], args[3])
    end
end, false)


-- COMMAND CONSOLIDATION (§2/§5 item 8) -- same dispatcher shape as
-- k9certify above.


-- COMMAND CONSOLIDATION -- /k9specialize accepts the SAME two target
-- shapes as every other command in this family (2026-09-02, at the owner's
-- request): a live server id, or a citizenid + job.
--
-- WHAT IS AND IS NOT MERGED HERE, PLAINLY. The COMMAND SURFACE is merged --
-- you type the same shape you type for /k9certify, /k9settier and
-- /k9unspecialize, and you no longer have to know which shape this one
-- wants. The GRANT ITSELF still requires the target to be CONNECTED: a
-- citizenid is resolved to that person's live server id first, and refused
-- by name if they are not connected.
--
-- WHY THERE IS NO OFFLINE GRANT PATH TO MERGE. GrantSpecialization's two
-- gates -- `not cached.expired` and TierCapabilityPermits -- both read the
-- ONLINE-ONLY Certifications/tier cache, which is evicted on playerDropped.
-- TierCapabilityPermits is cache-based by its own design and cannot resolve
-- a real tier for a disconnected citizenid at all, so an offline grant path
-- would FAIL OPEN: it would hand out specializations regardless of the tier
-- an operator actually configured for that person. Revoking has no such
-- problem, which is why /k9unspecialize IS fully merged, offline included --
-- taking a capability away can safely fail closed, handing one out cannot.
-- So this refuses, clearly and by name, rather than shipping a materially
-- weaker grant. See GrantSpecializationForTablet's own header.
RegisterAdminCommand('k9specialize', function(source, args)
    if args[1] == nil or args[1] == '' then
        local usage = locale('certifications.usage_specialize')
        if source == 0 then print('[John-K9] ' .. usage) else NotifyPlayer(source, usage, 'error') end
        return
    end

    local targetServerId, citizenid = ResolveCertificationTarget(args[1])
    if targetServerId then
        GrantSpecialization(source, targetServerId, args[2])
        return
    end

    -- Citizenid shape: citizenid, job, specialization -- args[3], not
    -- args[2], exactly matching /k9unspecialize's own offline shape so the
    -- two commands never want the arguments in a different order.
    local jobName, specializationKey = args[2], args[3]
    if type(jobName) ~= 'string' or jobName == '' or type(specializationKey) ~= 'string' or specializationKey == '' then
        NotifyPlayer(source, locale('certifications.usage_specialize'), 'error')
        return
    end

    local resolvedOk, onlineTarget = pcall(function() return exports.qbx_core:GetPlayerByCitizenId(citizenid) end)
    local onlineSrc = resolvedOk and onlineTarget and onlineTarget.PlayerData and onlineTarget.PlayerData.source
    if not onlineSrc then
        NotifyPlayer(source, locale('certifications.specialization_target_must_be_online_no_offline'), 'error')
        return
    end

    -- Same department check GrantSpecializationForTablet makes for the same
    -- reason: the caller named a department, so a mismatch is a typo worth
    -- reporting, never something to silently grant past.
    local liveJob = onlineTarget.PlayerData.job
    if not liveJob or liveJob.name ~= jobName then
        NotifyPlayer(source, locale('certifications.invalid_department_hint', tostring(jobName), ConfiguredDepartmentsList()), 'error')
        return
    end

    GrantSpecialization(source, onlineSrc, specializationKey)
end, false)

-- COMMAND CONSOLIDATION (§2/§5 item 8) -- same dispatcher shape as
-- k9certify above. k9specialize (immediately above) is DELIBERATELY
-- unmerged -- it has no offline counterpart at all (GrantSpecializationForTablet's
-- own doc comment: granting a specialization always requires the target to
-- be online), so there is nothing to fold into it.
RegisterAdminCommand('k9unspecialize', function(source, args)
    if args[1] == nil or args[1] == '' then
        local usage = locale('certifications.usage_unspecialize')
        if source == 0 then print('[John-K9] ' .. usage) else NotifyPlayer(source, usage, 'error') end
        return
    end
    local targetServerId, citizenid = ResolveCertificationTarget(args[1])
    if targetServerId then
        RevokeSpecialization(source, targetServerId, args[2])
    else
        -- Offline shape shifts by one position: citizenid, job,
        -- specialization -- args[3], not args[2].
        RevokeSpecializationOffline(source, citizenid, args[2], args[3])
    end
end, false)


--- CERTIFICATION DEPTH (this pass, Part A §9) — see header "EXPIRY" item
--- 2 for the full design. Sends AT MOST one warn-ahead notice and one
--- just-lapsed notice per (citizenid) per session — never re-sent on
--- every call, so this is safe to call both from PlayerLoaded (once, at
--- login) and from the periodic sweep (repeatedly, for every currently
--- online certified handler) without spamming either one.
--- @param onlineSrc number -- a LIVE, currently-connected server id (never a client claim — resolved by the caller from qbx_core, exactly like every other NotifyPlayer target in this file)
--- @param citizenid string
--- @param cached table -- a Certifications[citizenid] entry (active, job, tier, expiresAtUnix, expired)
local function CheckAndNotifyExpiry(onlineSrc, citizenid, cached)
    if not cached.expiresAtUnix then return end -- no expiry set -- nothing to warn about, ever

    if cached.expired then
        if not ExpiryLapsedNotified[citizenid] then
            ExpiryLapsedNotified[citizenid] = true
            NotifyPlayer(onlineSrc, locale('certifications.expiry_lapsed_notice'), 'error')
        end
        return
    end

    local now = NowUnix()
    if now == nil then return end -- see NowUnix's own doc comment -- fail toward silence, not toward a wrong day-count

    -- CLAMP-AND-WARN on a misconfigured CertificationExpiryWarningDays —
    -- see ResolveConfiguredExpiryWarningDays' own doc comment.
    local warningDays = ResolveConfiguredExpiryWarningDays()
    local secondsRemaining = cached.expiresAtUnix - now
    if secondsRemaining <= (warningDays * 86400) and not ExpiryWarned[citizenid] then
        ExpiryWarned[citizenid] = true
        local daysRemaining = math.max(1, math.ceil(secondsRemaining / 86400))
        NotifyPlayer(onlineSrc, locale('certifications.expiry_warning', tostring(daysRemaining)), 'inform')
    end
end

-- CONFIDENCE NOTE (not silently asserted as verified fact): no qbx_core
-- install was reachable in this sandbox to inspect its actual
-- exports/events against (the filesystem was searched; only this
-- resource's own files exist here). DEVELOPER_REFERENCE.md §4.4 already confirms
-- 'QBCore:Server:OnJobUpdate' as a real, current qbx_core
-- compatibility-bridge event. The player-load equivalent below,
-- 'QBCore:Server:PlayerLoaded', is used here with MEDIUM-HIGH confidence
-- based on established Qbox/QBCore convention — it is the same
-- foundational legacy event name every pre-existing QB job/feature
-- resource depends on, and the same compatibility bridge confirmed to
-- preserve OnJobUpdate is documented (docs.qbox.re) to preserve this one
-- too — but it is NOT independently verified against live qbx_core source
-- in this session. If the cache silently stays empty for freshly-loaded
-- players (they show as uncertified despite holding a real active row),
-- check this event name against the actual installed qbx_core version
-- first.
AddEventHandler('QBCore:Server:PlayerLoaded', function(Player)
    if not Player or not Player.PlayerData then return end
    local job = Player.PlayerData.job
    if not job then return end
    local citizenid = Player.PlayerData.citizenid
    local _, stateKnown = RefreshCertificationCache(citizenid, job.name)

    -- Regression-test fix: resync the read-only `k9certified` HUD mirror
    -- (DEVELOPER_REFERENCE.md §4.3 — never read for authorization) from whatever value
    -- RefreshCertificationCache just determined. The mirror can drift
    -- while a player is offline (e.g. RevokeCertificationOffline revoking
    -- their cert while disconnected) since it's only otherwise written by
    -- GrantCertification, RevokeCertification's online branch, and
    -- OnJobUpdate's auto-revoke — this self-corrects it on every login
    -- regardless of which path (or no path) caused the drift.
    --
    -- COULD-NOT-DETERMINE GUARD (lifecycle QA pass): the "always populates
    -- Certifications[citizenid]" claim this comment used to make here is no
    -- longer true — a could-not-determine outcome (a transient DB failure
    -- right at login, with no previous-session cache entry to fall back on,
    -- since playerDropped already wiped it on this citizenid's last
    -- disconnect) now deliberately leaves `Certifications[citizenid]`
    -- UNSET rather than writing a guessed `false`. `stateKnown` (Refresh-
    -- CertificationCache's own 2nd return value) is what actually tells
    -- this handler whether there is a real answer to act on -- checked
    -- explicitly below instead of assuming `cached` is always a table.
    -- Skipping the mirror write (and the expiry check) on a could-not-
    -- determine login is correct, not merely safe: writing `false` here
    -- would tell this officer's own HUD "not certified" over a transient
    -- blip, and running an expiry check against no confirmed data at all
    -- could mis-warn/mis-announce off of nothing. The periodic resync
    -- sweep further down this file will pick this citizenid up (they are
    -- online, which is exactly what that sweep walks) and correct both the
    -- real access cache and this mirror once the read actually succeeds --
    -- no reconnect required.
    local cached = Certifications[citizenid]
    if stateKnown and cached then
        Player.Functions.SetMetaData('k9certified', cached.active)

        -- CERTIFICATION DEPTH (this pass, Part A §9): a handler logging in
        -- already near or past their own expiry gets the same proactive
        -- notice an already-online handler would get from the periodic
        -- sweep — no need to wait for the next sweep pass just because they
        -- happened to log in between two of them. Gated the same way the
        -- sweep itself is (Player.PlayerData.source is always this login's
        -- own live source, never a client claim).
        if Config.Features and Config.Features.CertificationExpiry == true and cached.active then
            CheckAndNotifyExpiry(Player.PlayerData.source, citizenid, cached)
        end
    end
end)

-- Regression-test fix: `Certifications` is keyed by citizenid and
-- accumulates one entry per distinct citizenid ever loaded this session —
-- unlike LeashPairs/PendingLeashRequests/lastBarkAt in server/main.lua
-- (all cleared per-source in that file's playerDropped handler), nothing
-- ever evicted an entry here, so a long-running server slowly grows this
-- table forever. Not a correctness bug (a stale entry for a now-offline
-- citizenid is simply never read again until PlayerLoaded repopulates it
-- fresh), just unbounded memory growth. Resolve the citizenid for the
-- disconnecting source via qbx_core (still resolvable here — playerDropped
-- fires before the framework fully tears down the player object) and drop
-- its cache entry; it's harmlessly rebuilt from a fresh DB query on their
-- next PlayerLoaded/OnJobUpdate/certify/revoke touch.
AddEventHandler('playerDropped', function(_reason)
    local src = source
    local Player = exports.qbx_core:GetPlayer(src)
    local citizenid = Player and Player.PlayerData and Player.PlayerData.citizenid
    if citizenid then
        Certifications[citizenid] = nil

        -- CERTIFICATION DEPTH (this pass): same unbounded-growth reasoning
        -- as Certifications above, applied to the three new per-citizenid
        -- tables this pass adds. All three are harmlessly rebuilt/re-armed
        -- on the citizenid's next PlayerLoaded/RefreshCertificationCache
        -- touch, exactly like Certifications itself.
        Specializations[citizenid] = nil
        ExpiryWarned[citizenid] = nil
        ExpiryLapsedNotified[citizenid] = nil

        -- COULD-NOT-DETERMINE HANDLING (lifecycle QA pass): same
        -- unbounded-growth reasoning, applied to the bookkeeping table that
        -- backs the operator message and the resync sweep. A disconnected
        -- citizenid has no live source for the sweep to act on anyway (it
        -- walks GetPlayers()), so there is nothing left to resync until
        -- their next PlayerLoaded re-attempts the read fresh.
        CertificationCheckUnresolved[citizenid] = nil
    end

    -- DEVELOPER_REFERENCE.md item 1: CertifyActionCooldown already registered
    -- its OWN `playerDropped` handler via :RegisterPlayerDropped() above
    -- (same unbounded-growth reasoning as Certifications above — keyed by
    -- server id (src) rather than citizenid since CERTIFY_ACTION_COOLDOWN_MS
    -- throttles the CERTIFIER's connection, not any particular citizenid),
    -- so nothing needs to happen here for it anymore.
end)

-- ======================================================================
-- CERTIFICATION DEPTH (this pass, Part A §9) — background expiry sweep.
-- See header "EXPIRY" item 2 for the full design. Mirrors
-- server/tenure.lua's own CreateThread/Wait tick-loop shape exactly,
-- including its config-driven-interval + fallback-on-misconfiguration
-- convention (a non-positive/NaN/non-number interval fed straight to
-- Wait() can busy-loop or silently kill this thread forever — same
-- footgun that file's own PollIntervalMs-adjacent comment documents).
--
-- GATED AT THE CreateThread REGISTRATION ITSELF, not just inside the loop
-- body: on a server that has never turned Config.Features.CertificationExpiry
-- on, this thread is never even created — a total, zero-cost no-op,
-- matching this task's own "a server with none of this configured must
-- see a clean no-op" requirement literally, not just "does nothing when
-- it runs."
-- ======================================================================

--- One sweep pass: for every currently-connected player, if their cached
--- certification carries an expiry, warn ahead of it or announce a lapse
--- (at most once per session each — see CheckAndNotifyExpiry). Walks
--- `GetPlayers()`/cache reads only — NEVER a live SQL query — matching
--- this file's header "EXPIRY" item 2 ("never a live per-access SQL
--- query").
local function TickCertificationExpiryWarnings()
    for _, playerId in ipairs(GetPlayers()) do
        local src = tonumber(playerId)
        if src then
            local Player = exports.qbx_core:GetPlayer(src)
            local citizenid = Player and Player.PlayerData and Player.PlayerData.citizenid
            local cached = citizenid and Certifications[citizenid]
            if cached and cached.active then
                CheckAndNotifyExpiry(src, citizenid, cached)
            end
        end
    end
end

-- CONCURRENCY-AUDIT FIX (this pass): mirrors server/tenure.lua's own
-- identical `checkIntervalMs` fix -- see that file's own doc comment,
-- immediately above its equivalent CreateThread registration, for the
-- full writeup this one intentionally does not repeat verbatim. Same
-- shape here: the OLD `rawIntervalMs > 0` check accepted a hand-edited
-- `1` just as readily as a sane `300000`, entirely bypassing the K9
-- Command Tablet's own 30000-3600000ms bound for this exact field (a
-- bound enforced ONLY by the tablet's own UI, never re-verified here) and
-- the shared 250ms floor server/cooldowns.lua's ResolveConfiguredThresholdMs
-- already enforces for every other Config-sourced interval in this
-- resource. Lower blast radius than tenure.lua's own version of this bug
-- (this sweep is cache-only -- GetPlayers()/Certifications reads, never a
-- live SQL query, per this section's own header above) but the identical
-- defect shape, so the identical fix: delegate to
-- ResolveConfiguredThresholdMs rather than a second hand-rolled copy of
-- its floor/validity rules, with the same "no warn-once flag needed"
-- reasoning tenure.lua's own comment explains (a bad value's own warning
-- can now only repeat once per EXPIRY_CHECK_INTERVAL_FALLBACK_MS, since
-- that fallback is what the very same call sets Wait() to use next).
local EXPIRY_CHECK_INTERVAL_FALLBACK_MS = 300000

if Config.Features and Config.Features.CertificationExpiry == true then
    CreateThread(function()
        while true do
            local rawIntervalMs = Config.CertificationExpiryCheckIntervalMs
            local intervalMs = rawIntervalMs == nil and EXPIRY_CHECK_INTERVAL_FALLBACK_MS
                or ResolveConfiguredThresholdMs(rawIntervalMs, EXPIRY_CHECK_INTERVAL_FALLBACK_MS, 'Config.CertificationExpiryCheckIntervalMs')
            Wait(intervalMs)
            local ok, err = pcall(TickCertificationExpiryWarnings)
            if not ok then
                print(('[John-K9] certification expiry sweep tick error: %s'):format(tostring(err)))
            end
        end
    end)
end

-- ======================================================================
-- COULD-NOT-DETERMINE RESYNC SWEEP (lifecycle QA pass, this pass) -- see
-- "COULD-NOT-DETERMINE HANDLING" above RefreshCertificationCache's own
-- declaration for the full contract this closes the loop on: a citizenid
-- left unresolved by a transient query failure (most likely during
-- server/main.lua's onResourceStart backfill burst, or an unlucky
-- immediately-after-grant re-read) must recover WITHOUT needing to
-- reconnect, per this pass's own explicit requirement. This sweep is that
-- recovery path.
--
-- ALWAYS RUNS, UNCONDITIONALLY -- deliberately NOT gated behind a
-- Config.Features flag the way the expiry-warning sweep just above is:
-- this is not an optional feature, it is the self-heal half of this file's
-- own core access-cache correctness contract, and every install running
-- this resource at all needs it regardless of which optional features are
-- turned on. Matches this resource's own established "a thread governed by
-- something that can change at runtime starts unconditionally and
-- re-checks that thing fresh inside the loop, rather than being gated at
-- CreateThread registration itself" convention -- see
-- server/runtimecontrol.lua's FEATURE_TIERS entry documenting
-- server/combat.lua's own maintenance/position-history threads for the
-- precedent and the exact "live-flip" bug class that gating at
-- registration causes. CertificationCheckUnresolved can gain its first
-- entry at ANY point while this resource is running, not just at boot, so
-- a thread that only started conditionally at load time could miss every
-- entry that starts existing later. Cheap on an idle server either way:
-- the overwhelmingly common case is an EMPTY CertificationCheckUnresolved
-- table, and `next(t) == nil` is an O(1)-ish check, not a walk.
-- ======================================================================

local CERT_RESYNC_SWEEP_INTERVAL_MS = 30000

--- One resync pass: retries RefreshCertificationCache for every citizenid
--- currently recorded in CertificationCheckUnresolved (i.e. every citizenid
--- whose most recent attempt could not be confirmed either way), but ONLY
--- for a citizenid who is CURRENTLY ONLINE and still in the EXACT job the
--- unresolved entry was recorded for. A successful retry needs no separate
--- bookkeeping here: RefreshCertificationCache itself clears
--- CertificationCheckUnresolved[citizenid] the instant it confirms ANY
--- answer, real or absent -- this function only needs to keep calling it.
---
--- WHY ONLINE-ONLY: an offline citizenid's own next 'QBCore:Server:
--- PlayerLoaded' already attempts a fresh read from a clean state, and this
--- sweep has no live job context to retry against for someone who is not
--- connected right now (Certifications/CertificationCheckUnresolved are
--- both citizenid-keyed, but the JOB an entry should be re-verified against
--- is only knowable from a live Player.PlayerData.job -- the same reason
--- server/main.lua's own onResourceStart backfill only ever walks
--- GetPlayers(), never a broader offline-citizenid list).
---
--- WHY EXACT-JOB-ONLY: a citizenid who changed department WHILE unresolved
--- has already had the OnJobUpdate handler fire its own direct
--- RefreshCertificationCache call for whatever their NEW job is (confirmed
--- or not) -- retrying the OLD, now-irrelevant job here would just
--- manufacture a second unresolved entry for a department this citizenid
--- has already left, chasing an answer nothing needs anymore.
local function ResyncUnresolvedCertifications()
    for citizenid, unresolved in pairs(CertificationCheckUnresolved) do
        local onlinePlayer = exports.qbx_core:GetPlayerByCitizenId(citizenid)
        local liveJob = onlinePlayer and onlinePlayer.PlayerData and onlinePlayer.PlayerData.job
        if onlinePlayer and onlinePlayer.PlayerData and onlinePlayer.PlayerData.source
            and liveJob and liveJob.name == unresolved.job then
            RefreshCertificationCache(citizenid, unresolved.job)
        end
    end
end

CreateThread(function()
    while true do
        Wait(CERT_RESYNC_SWEEP_INTERVAL_MS)

        -- Cheap early-exit, checked fresh every tick (never cached/latched)
        -- -- see this sweep's own header above for why this table is
        -- expected to be empty essentially always.
        if next(CertificationCheckUnresolved) ~= nil then
            local ok, err = pcall(ResyncUnresolvedCertifications)
            if not ok then
                print(('[John-K9] certification resync sweep tick error: %s'):format(tostring(err)))
            end
        end
    end
end)
