--[[
    tests/certifications_spec.lua

    Direct + indirect tests of server/certifications/ -- the authorization
    root of this entire resource (HasK9Access gates nearly every feature) --
    against the REAL, unmodified production file. Before this spec, this
    file had ZERO direct coverage despite being the single most
    security-sensitive file in the resource.

    HasK9Access/RefreshCertificationCache/IsConfiguredK9Model are exposed
    resource-globals (no `local`), reached directly. GrantCertification,
    RevokeCertification, RevokeCertificationOffline, and the
    QBCore:Server:OnJobUpdate auto-revoke handler are all `local` -- reached
    the same way a real caller does, through the captured
    RegisterNetEvent/RegisterCommand/AddEventHandler entry points this file
    itself wires them into (same convention as admin_spec.lua/
    progression_spec.lua).

    Loads server/cooldowns.lua into the SAME sandbox env FIRST:
    certifications.lua's own file-load-time `NewCooldown(1500)` call
    (CertifyActionCooldown) needs the real constructor in scope, same
    load-order requirement fxmanifest.lua's own server_scripts list already
    documents. Every test that fires more than one grant/revoke/decertify
    action from the SAME granter source must advance the fake clock by more
    than CERTIFY_ACTION_COOLDOWN_MS (1500) between calls, or the 2nd+ call is
    a silent, by-design no-op -- see newFixture()'s `state.now` / each such
    test's own comment.

    Unlike most specs in this suite, `locale` is NEVER stubbed here
    (Sandbox.newEnv already wires the real locale() reader over the real
    locales/en.json) -- per this task's own brief, every notify path this
    spec drives therefore doubles as a check that the locale key it resolves
    genuinely exists. Expected notification text is built by calling the
    SAME Sandbox.locale(...) the production code calls, rather than
    hardcoding a copy of the English string here, so this spec can never
    silently drift from en.json's actual wording while still asserting
    real content, not just "some string was sent".

    UPDATED (workflow-clarity pass -- "make the certification lifecycle
    smooth and self-explaining"): env.locale is now `localeWithPendingCertKeys`
    (below), NOT bare `Sandbox.locale`, for every fixture in this file --
    mirrors tests/permissions_spec.lua's own `localeWithPendingCommandKeys`
    pattern exactly, generalized to the file's default rather than an
    opt-in override, because this pass touches the large majority of this
    file's own refusal messages. For every key ALREADY shipped in
    locales/en.json, `localeWithPendingCertKeys` is BYTE-IDENTICAL to
    `Sandbox.locale` (a plain pass-through) -- the "doubles as a check the
    key really exists" guarantee above is therefore still fully intact for
    every pre-existing key. It ONLY substitutes the small, explicitly-listed
    set of BRAND NEW keys this pass introduces (not yet in locales/en.json
    -- this file may not edit that file directly; see PENDING_CERT_LOCALE
    below for the exact, proposed English text of every one, forwarded to
    whoever owns locales/en.json) with their proposed final text, so this
    spec can assert on the REAL new wording today rather than skipping
    those branches the way this file's own prior "one case this spec cannot
    pin yet" note (removed this pass, now resolved) had to for
    `specialization_requires_tier_capability` before that key actually
    shipped.

    GENUINE FINDING (not a deviation to paper over): this file was audited
    for `assert(...)` calls at file-load time (the shape server/
    propattachment.lua, server/bonetool.lua, server/progression.lua,
    server/admin.lua, and server/search.lua all use to fail loudly at
    resource start on a malformed Config table). server/certifications/
    has ZERO such asserts -- a malformed Config.Departments entry (e.g. a
    missing/non-numeric certifierGrade, or Config.Peds containing a
    non-string `model` field) is never validated at load time here; it would
    instead surface later, silently, as a certifier who can never certify
    anyone (job.grade.level >= dept.certifierGrade against a nil/non-number
    certifierGrade is simply always false) or a K9 model that can never pass
    IsConfiguredK9Model. No "startup asserts" section is written below for
    this file because there is nothing to exercise -- see this spec's final
    report for the same note. This is disclosed, not silently worked around.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

-- ======================================================================
-- WORKFLOW-CLARITY PASS -- brand new locale keys, proposed to and not yet
-- added by whoever owns locales/en.json (this file may not edit that file
-- directly). Mirrors tests/permissions_spec.lua's own
-- PENDING_COMMAND_LOCALE/localeWithPendingCommandKeys pattern exactly.
-- Every value below is the EXACT English text requested -- see this
-- pass's own report for the same list handed off verbatim.
-- ======================================================================
local PENDING_CERT_LOCALE = {
    ['certifications.invalid_target_id'] =
        "Invalid target -- provide the target's numeric server id (see /players).",
    ['certifications.not_authorized_to_certify_hint'] =
        "You are not authorized to certify K9 handlers -- you need your department's certifying rank, the k9.certify permission, or High Command status.",
    ['certifications.not_authorized_to_revoke_hint'] =
        "You are not authorized to revoke K9 certifications -- you need your department's certifying rank, the k9.certify permission, or High Command status.",
    ['certifications.self_certification_disabled_hint'] =
        "Self-certification is disabled on this server -- ask another certifying officer to do this for you instead.",
    ['certifications.target_must_be_online_use_offline'] =
        "Target must be online to be certified this way. If they are offline, use /k9certify [citizenid] [job] instead.",
    ['certifications.target_must_be_online_model_check'] =
        "Target must be online to be certified -- this server requires verifying their current K9 model, which cannot be checked while they are offline. There is no offline path for this while that check is enabled.",
    ['certifications.target_not_in_department_hint'] =
        'Target is not employed by an eligible department. Configured departments: %s.',
    ['certifications.target_too_far_to_certify_distance'] =
        'Target is too far away to certify -- move within %sm of them and try again.',
    ['certifications.target_too_far_to_revoke_distance'] =
        'Target is too far away to revoke their certification -- move within %sm of them and try again.',
    ['certifications.action_target_too_far_distance'] =
        'Target is too far away for this action -- move within %sm of them and try again.',
    ['certifications.target_not_k9_model_hint'] =
        "Target is not playing a recognized K9 model. Ask them to switch to one of this server's configured K9 models before certifying, or ask an operator to turn off Config.K9Appearance.requireK9ModelForRole if that check isn't needed.",
    ['certifications.target_already_certified_hint'] =
        "Target already holds an active certification for this department. Use /k9settier or /k9specialize to adjust it, or /k9decertify and re-certify to start over.",
    ['certifications.invalid_department_hint'] =
        "'%s' is not a configured department. Configured departments: %s.",
    ['certifications.tier_change_target_must_be_online_hint'] =
        "Target must be online for this action, or use /k9settier [citizenid] [job] [tier] to change their tier while they're offline.",
    ['certifications.renew_target_must_be_online_hint'] =
        "Target must be online for this action, or use /k9certify [citizenid] [job] to renew their certification while they're offline.",
    ['certifications.specialization_target_must_be_online_no_offline'] =
        "Target must be online for this action -- specializations can only be granted while the target is connected; there is no offline path for this one.",
    ['certifications.target_not_actively_certified_needs_cert'] =
        "Target does not hold an active certification for this department -- certify them first with /k9certify [server id] (or /k9certify [citizenid] [job] if they're offline).",
    ['certifications.tier_change_busy'] =
        'That tier is being edited elsewhere right now -- try again in a moment.',
    ['certifications.invalid_specialization_hint'] =
        'That is not a configured K9 specialization. Configured specializations: %s.',
    ['certifications.specialization_requires_active_cert_hint'] =
        "That person must hold an active certification for this department before a specialization can be granted -- certify them first with /k9certify.",
    ['certifications.specialization_requires_tier_capability_hint'] =
        "That person's certification tier does not permit specializations for this department -- change their tier with /k9settier, or ask an operator to grant this capability to their tier from the tablet.",
    ['certifications.grant_success_next_steps'] =
        "They start at the '%s' tier with no specializations yet. %d feature(s) on this server also require a separate grant (/k9grantpermission, or the tablet) before they will work for them.",
    ['certifications.grant_success_next_steps_no_grants'] =
        "They start at the '%s' tier with no specializations yet.",
    ['certifications.revoked_notice_online_with_reason'] =
        'Your K9 certification has been revoked (reason: %s).',
    ['certifications.renew_success_granter_detail'] =
        "Target's certification has been renewed -- it now expires in %s day(s).",
    ['certifications.renew_success_target_detail'] =
        'Your K9 certification has been renewed -- it now expires in %s day(s).',
    ['certifications.k9_access_lost_department_change'] =
        'You are no longer employed by an eligible K9 department, so your K9 access permission no longer applies here. Any active K9 pairing has ended.',
    ['certifications.k9_access_lost_grade_change'] =
        'Your K9 access has ended -- your current rank no longer qualifies you, and you hold no separate certification for this department. Any active K9 pairing has ended.',
    ['certifications.revoked_notice_job_change_next_steps'] =
        'If you need K9 access in your new department, ask a certifying officer there to certify you.',
}

--- @param key string
--- @return string
local function localeWithPendingCertKeys(key, ...)
    local text = PENDING_CERT_LOCALE[key]
    if text then
        if select('#', ...) > 0 then return text:format(...) end
        return text
    end
    return Sandbox.locale(key, ...)
end

-- ----------------------------------------------------------------------
-- Vector3-alike stub -- GrantCertification/RevokeCertification's proximity
-- check does `#(GetEntityCoords(a) - GetEntityCoords(b))`, so both the `-`
-- and `#` metamethods must be modeled, same as tenure_spec.lua's own vec3.
-- ----------------------------------------------------------------------

local Vec3MT = {}
Vec3MT.__index = Vec3MT
Vec3MT.__sub = function(a, b)
    return setmetatable({ x = a.x - b.x, y = a.y - b.y, z = a.z - b.z }, Vec3MT)
end
Vec3MT.__len = function(v)
    return math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z)
end
local function vec3(x, y, z)
    return setmetatable({ x = x, y = y, z = z }, Vec3MT)
end

-- Model hash constants shared by every fixture below (matches
-- Config.Peds -- see newFixture()).
local K9_HASH_SHEPHERD = 111
local K9_HASH_ROTTWEILER = 112
local NON_K9_HASH = 999

local function GetHashKey(modelName)
    local hashes = { a_c_shepherd = K9_HASH_SHEPHERD, a_c_rottweiler = K9_HASH_ROTTWEILER }
    return hashes[modelName] or 0
end

-- ----------------------------------------------------------------------
-- Fixture builder: one fresh env + fresh load of cooldowns.lua +
-- certifications.lua per top-level scenario, exactly like
-- tenure_spec.lua's newTenureFixture -- this file's local `Certifications`
-- cache, `GrantInFlight` lock table, and `CertifyActionCooldown` state must
-- never leak between unrelated test cases.
-- ----------------------------------------------------------------------

--- @param opts table? -- { includePartnershipHook: boolean (default true), departments: table (default 2-dept Config.Departments), allowSelfCert: boolean (default true), proximityMeters: number (default 5.0), features: table? (Config.Features -- default nil, matching every pre-existing test's shipped-default posture), expiryDays/expiryWarningDays/expiryCheckIntervalMs: number?, k9Specializations: table?, certifyMaxNewGranteesPerDay: number? (default nil -- production's own built-in fallback of 8 applies) }
local function newFixture(opts)
    opts = opts or {}

    local state = { now = 1000000, nowUnix = 1700000000 }
    local function GetGameTimer() return state.now end
    -- CERTIFICATION DEPTH (this pass): a SEPARATE fake clock from
    -- GetGameTimer's `state.now` (ms-since-resource-start) -- os.time()
    -- models real wall-clock epoch seconds, a genuinely different axis
    -- this file's own EXPIRY design deliberately keeps as the ONLY
    -- Lua-side wall-clock read (see certifications.lua's own NowUnix doc
    -- comment). Overridable per test via advanceUnixTime below.
    local osStub = {
        time = function() return state.nowUnix end,
        -- ROSTER FIX (coordinator-flagged gap, this pass): server/datastore.lua's
        -- own memory-mode FormatDateTime helper calls os.date(...) directly
        -- (real oxmysql DATETIME-string formatting has no equivalent to fake in
        -- real-DB mode, which every OTHER test in this file uses -- this only
        -- matters for the one opts.database={enabled=false} integration test).
        -- The REAL os.date is safe to pass through verbatim: called only with an
        -- explicit unixTime argument, it is pure/deterministic, never reads the
        -- actual wall clock.
        date = os.date,
    }

    -- CERTIFICATION DEPTH (this pass): GetPlayers() backs
    -- TickCertificationExpiryWarnings' sweep loop -- reflects whichever
    -- sources are CURRENTLY registered (registerPlayer/disconnectPlayer),
    -- exactly like the real native. Returns STRING ids, matching FiveM's
    -- own documented GetPlayers() contract (server/main.lua's own
    -- onResourceStart backfill loop already assumes/tonumber()s this same
    -- shape).
    local playersBySourceRef -- forward-declared; assigned once playersBySource itself exists below
    local function GetPlayers()
        local out = {}
        for src in pairs(playersBySourceRef) do
            out[#out + 1] = tostring(src)
        end
        return out
    end

    local notifyLog = {} -- { {source=, message=, kind=}, ... }
    local function NotifyPlayer(source, message, kind)
        notifyLog[#notifyLog + 1] = { source = source, message = message, kind = kind }
    end

    local outboundEvents = {} -- { {eventName, ...}, ... }
    local function TriggerEvent(eventName, ...)
        outboundEvents[#outboundEvents + 1] = { eventName, ... }
    end

    local leashDetachCalls = {}         -- ForceDetachLeashForSource(src, reason)
    local officerLeashDetachCalls = {}  -- ForceDetachOfficerLeashForSource(src, reason)
    local partnershipBreakCalls = {}    -- ForceBreakPartnershipForCitizenId(citizenid, reason)
    local bodyClaimReleaseCalls = {}    -- ForceReleaseBodyClaimForCitizenId(citizenid, reason)
    local effectEndCalls = {}           -- EndActiveEffectForHolder(src) -- server/combat.lua, called via pcall at every "must not outlive certification" call site in the production file; never previously stubbed/observed by this spec (opts.includeEffectHook, default true, mirrors opts.includePartnershipHook's own existence-guard test below)
    -- APPEARANCE HOOK (coder-security, this pass -- "prove role and model
    -- are genuinely separate, everywhere" audit): ApplyK9AppearanceOnGrant/
    -- MaybeRevertK9Appearance (server/appearance.lua) were found completely
    -- unwired in this file despite that file's own header documenting them
    -- as called from here -- see certifications.lua's own newly-added
    -- FILE-TO-FILE CONTRACT entry for the full writeup. Same
    -- runtime-existence-guard convention/opt-out shape as
    -- includePartnershipHook/includeEffectHook above (opts.includeAppearanceHook,
    -- default true).
    local appearanceApplyCalls = {}   -- ApplyK9AppearanceOnGrant(targetCitizenid, granterCitizenid, modelName?)
    local appearanceRevertCalls = {}  -- MaybeRevertK9Appearance(citizenid)
    -- ECONOMY FIX (self-cert/decertify farm loop pass): AwardHandlerXP
    -- (server/progression.lua) is runtime-existence-guarded at both
    -- GrantCertification/GrantCertificationOffline call sites, same
    -- soft-dependency shape as ApplyK9AppearanceOnGrant/
    -- ForceBreakPartnershipForCitizenId above -- included by default so
    -- most tests can assert on exactly which (citizenid, actionKey) pairs
    -- were minted (and, just as importantly, which repeat mints were
    -- SILENTLY SKIPPED by CertifyXpMintCooldown), opt out via
    -- opts.includeHandlerXpHook = false to confirm the guard tolerates the
    -- global being entirely absent.
    local handlerXpAwardCalls = {} -- { citizenid, actionKey }

    -- ROSTER FIX (coordinator-flagged gap, this pass) --
    -- ClearPersonnelRowForCitizenJob (server/roster.lua) is a NEW soft
    -- dependency this pass added a real call site for
    -- (RevokeCertificationForTablet), same runtime-existence-guard shape as
    -- every other cross-file hook above -- opt out via
    -- opts.includeRosterHook = false to confirm that guard tolerates the
    -- global being entirely absent (server/roster.lua not loaded /
    -- Config.Features.CommandTablet off).
    local personnelClearCalls = {} -- { citizenid, job, clearedBy }

    local playersBySource = {}
    local playersByCitizenId = {}
    playersBySourceRef = playersBySource

    --- @param source number
    --- @param citizenid string
    --- @param job table -- { name, isboss?, grade? = { level } }
    local function registerPlayer(source, citizenid, job)
        local metaWrites = {}
        local p = {
            PlayerData = { citizenid = citizenid, job = job, source = source },
            Functions = {
                SetMetaData = function(key, value)
                    metaWrites[#metaWrites + 1] = { key = key, value = value }
                end,
            },
            _metaWrites = metaWrites,
        }
        playersBySource[source] = p
        playersByCitizenId[citizenid] = p
        return p
    end

    --- Simulates a genuine disconnect: removed from BOTH lookup maps, exactly
    --- like the real qbx_core GetPlayer/GetPlayerByCitizenId would behave for
    --- someone no longer connected.
    --- @param source number
    local function disconnectPlayer(source)
        local p = playersBySource[source]
        if not p then return end
        playersBySource[source] = nil
        playersByCitizenId[p.PlayerData.citizenid] = nil
    end

    local exportsStub = {
        qbx_core = {
            GetPlayer = function(_self, source) return playersBySource[source] end,
            GetPlayerByCitizenId = function(_self, citizenid) return playersByCitizenId[citizenid] end,
        },
    }

    local pedsBySource = {}
    local pedCoordsByPed = {}
    local pedModelByPed = {}

    local function GetPlayerPed(source) return pedsBySource[source] or 0 end
    local function GetEntityCoords(ped) return pedCoordsByPed[ped] or vec3(0, 0, 0) end
    local function GetEntityModel(ped) return pedModelByPed[ped] end

    --- @param source number
    --- @param pedHandle number
    --- @param coords table -- vec3(x,y,z)
    --- @param modelHash number?
    local function setPed(source, pedHandle, coords, modelHash)
        pedsBySource[source] = pedHandle
        pedCoordsByPed[pedHandle] = coords
        if modelHash then pedModelByPed[pedHandle] = modelHash end
    end

    local mysql = {
        scalar = { await = function(_sql, _params) return nil end }, -- default: "no existing active row"
        insert = { await = function(_sql, _params) return 1 end },   -- default: insert succeeds, fake id 1
        update = { await = function(_sql, _params) return 1 end },   -- default: exactly one row affected
        -- CERTIFICATION DEPTH (this pass): RefreshCertificationCache's tier/
        -- expiry metadata read and RefreshSpecializationCache both go through
        -- MySQL.single.await / MySQL.query.await respectively -- default to
        -- "no metadata row" / "no active specializations" so every
        -- PRE-EXISTING test (which only ever stubs scalar/insert/update) gets
        -- a real, working default rather than an unstubbed-field crash.
        single = { await = function(_sql, _params) return nil end },
        query = { await = function(_sql, _params) return {} end },
    }

    local capturedEvents = {}
    local function RegisterNetEvent(name, fn) capturedEvents[name] = fn end

    local capturedCommands = {}
    local function RegisterCommand(name, fn, restricted) capturedCommands[name] = { fn = fn, restricted = restricted } end

    local eventHandlers = {} -- eventName -> { fn, fn, ... }
    local function AddEventHandler(name, fn)
        eventHandlers[name] = eventHandlers[name] or {}
        eventHandlers[name][#eventHandlers[name] + 1] = fn
    end

    local capturedCallbacks = {}
    local libStub = { callback = { register = function(name, fn) capturedCallbacks[name] = fn end } }

    local printLog = {}
    local function printStub(...)
        local parts = {}
        for i = 1, select('#', ...) do parts[i] = tostring(select(i, ...)) end
        printLog[#printLog + 1] = table.concat(parts, '\t')
    end

    local Config = {
        Peds = opts.peds or {
            { model = 'a_c_shepherd' },
            { model = 'a_c_rottweiler' },
        },
        Departments = opts.departments or {
            police = { label = 'Police Department', certifierGrade = 4, autoAccessGrade = nil },
            sheriff = { label = 'Sheriff', certifierGrade = 3, autoAccessGrade = nil },
        },
        AllowSelfCertification = opts.allowSelfCert,
        CertifyProximityMeters = opts.proximityMeters or 5.0,
        -- FARM FIX (this pass) -- absent (nil) by default, matching every
        -- pre-existing test's shipped-default posture: the production
        -- resolver (ResolveCertifyMaxNewGranteesPerDay) already falls back
        -- to its own built-in default (8) when this reads nil, exactly the
        -- same way a real, un-upgraded server config would. Tests that care
        -- about the cap set this explicitly via opts.certifyMaxNewGranteesPerDay.
        CertifyMaxNewGranteesPerDay = opts.certifyMaxNewGranteesPerDay,
        -- K9 role/model decoupling (coder-architect, server/appearance.lua,
        -- landed concurrently with this pass): GrantCertification's own
        -- §4.2 item 5 model check now only runs when
        -- Config.K9Appearance.requireK9ModelForRole is explicitly true --
        -- absent here by default so most tests match this file's own
        -- pre-decoupling shape (Config.Peds/model-hash tests below opt
        -- in explicitly via opts.k9Appearance where the model check itself
        -- is under test).
        K9Appearance = opts.k9Appearance,
        -- CERTIFICATION DEPTH (this pass): Features/expiry knobs default to
        -- ABSENT (nil), matching every pre-existing test's shipped-default
        -- posture (the feature is off until a test explicitly opts in via
        -- opts.features) -- see this fixture's own header for the full
        -- opts shape.
        Features = opts.features,
        CertificationExpiryDays = opts.expiryDays,
        CertificationExpiryWarningDays = opts.expiryWarningDays,
        CertificationExpiryCheckIntervalMs = opts.expiryCheckIntervalMs,
        K9Specializations = opts.k9Specializations or {
            narcotics = { label = 'Narcotics detection' },
            explosives = { label = 'Explosives detection' },
        },
        -- WORKFLOW CLARITY (this pass, item 1): absent by default (every
        -- pre-existing test's shipped-default posture, matching Features/
        -- expiry above) -- CountFeaturesRequiringGrant treats a missing
        -- table as zero, exactly like the real config.lua default
        -- ("an empty table changes nothing").
        FeatureControl = opts.featureControl,
        -- ROSTER FIX (coordinator-flagged gap, this pass) -- absent by
        -- default (every pre-existing test's shipped-default posture,
        -- matching Features/expiry above -- K9Store's own DatabaseEnabled()
        -- fails safe to real-DB mode when this is nil, unchanged for every
        -- existing test). A dedicated integration test opts into
        -- `{ enabled = false }` (memory mode) so it can load the REAL
        -- server/roster.lua alongside this file and prove a genuine
        -- certify -> assign role/callsign -> revoke -> re-certify round
        -- trip without hand-mocking every roster K9Store query too.
        Database = opts.database,
    }
    if Config.AllowSelfCertification == nil then Config.AllowSelfCertification = true end

    -- CERTIFICATION DEPTH (this pass): the sweep thread's own
    -- CreateThread(...) call happens at THIS FILE'S OWN LOAD TIME (gated
    -- on Config.Features.CertificationExpiry), so the thread runner and
    -- CapturingWait must both be wired into `overrides` BEFORE
    -- Sandbox.loadInto below -- mirrors tests/tenure_spec.lua's own
    -- identical setup for server/tenure.lua's tick loop.
    local threadRunner = Sandbox.newThreadRunner()
    local waitCalls = {}
    local function CapturingWait(ms)
        waitCalls[#waitCalls + 1] = ms
        return threadRunner.Wait(ms)
    end

    local overrides = {
        Config = Config,
        GetHashKey = GetHashKey,
        exports = exportsStub,
        NotifyPlayer = NotifyPlayer,
        MySQL = mysql,
        TriggerEvent = TriggerEvent,
        GetPlayerPed = GetPlayerPed,
        GetEntityCoords = GetEntityCoords,
        GetEntityModel = GetEntityModel,
        GetGameTimer = GetGameTimer,
        RegisterNetEvent = RegisterNetEvent,
        RegisterCommand = RegisterCommand,
        AddEventHandler = AddEventHandler,
        lib = libStub,
        print = printStub,
        ForceDetachLeashForSource = function(src, reason) leashDetachCalls[#leashDetachCalls + 1] = { src, reason } end,
        ForceDetachOfficerLeashForSource = function(src, reason) officerLeashDetachCalls[#officerLeashDetachCalls + 1] = { src, reason } end,
        os = osStub,
        GetPlayers = GetPlayers,
        CreateThread = threadRunner.CreateThread,
        Wait = CapturingWait,
    }
    -- ForceBreakPartnershipForCitizenId is runtime-existence-guarded
    -- (`type(...) == 'function'`) at every call site in the production file
    -- -- included by default so most tests can assert it fires; a dedicated
    -- test below passes includePartnershipHook = false to confirm the guard
    -- itself actually tolerates the global being entirely absent.
    if opts.includePartnershipHook ~= false then
        overrides.ForceBreakPartnershipForCitizenId = function(citizenid, reason)
            partnershipBreakCalls[#partnershipBreakCalls + 1] = { citizenid, reason }
        end
    end
    -- EndActiveEffectForHolder is runtime-existence-guarded
    -- (`type(...) == 'function'`, always inside a pcall) at every call site
    -- in the production file, exactly like ForceBreakPartnershipForCitizenId
    -- above -- included by default so tests can assert it fires; pass
    -- includeEffectHook = false to confirm a call site's own guard
    -- tolerates the global being entirely absent (server/combat.lua not
    -- loaded / Config.Features.BiteAndHold off).
    if opts.includeEffectHook ~= false then
        overrides.EndActiveEffectForHolder = function(src)
            effectEndCalls[#effectEndCalls + 1] = src
        end
    end
    -- ForceReleaseBodyClaimForCitizenId (server/bodyclaims.lua) is
    -- runtime-existence-guarded at its call site in exactly the same shape
    -- as ForceBreakPartnershipForCitizenId above. Included by default so
    -- tests can assert it fires; pass includeBodyClaimHook = false to
    -- confirm the guard tolerates the global being absent entirely
    -- (server/bodyclaims.lua not loaded).
    if opts.includeBodyClaimHook ~= false then
        overrides.ForceReleaseBodyClaimForCitizenId = function(citizenid, reason)
            bodyClaimReleaseCalls[#bodyClaimReleaseCalls + 1] = { citizenid, reason }
        end
    end
    -- See appearanceApplyCalls/appearanceRevertCalls's own declaration-site
    -- comment above for the full writeup.
    if opts.includeAppearanceHook ~= false then
        overrides.ApplyK9AppearanceOnGrant = function(targetCitizenid, granterCitizenid, modelName)
            appearanceApplyCalls[#appearanceApplyCalls + 1] = { targetCitizenid, granterCitizenid, modelName }
        end
        overrides.MaybeRevertK9Appearance = function(citizenid)
            appearanceRevertCalls[#appearanceRevertCalls + 1] = citizenid
        end
    end
    if opts.includeHandlerXpHook ~= false then
        overrides.AwardHandlerXP = function(citizenid, actionKey)
            handlerXpAwardCalls[#handlerXpAwardCalls + 1] = { citizenid, actionKey }
        end
    end
    if opts.includeRosterHook ~= false then
        overrides.ClearPersonnelRowForCitizenJob = function(citizenid, job, clearedBy)
            personnelClearCalls[#personnelClearCalls + 1] = { citizenid, job, clearedBy }
            return true
        end
    end

    -- WORKFLOW-CLARITY PASS -- see this file's own header for the full
    -- "byte-identical to Sandbox.locale except for the explicitly pending
    -- keys" writeup.
    overrides.locale = localeWithPendingCertKeys

    local env = Sandbox.newEnv(overrides)

    -- server/datastore.lua -- REAL, unmodified, loaded first (fxmanifest.lua's
    -- own load order: the only file allowed to call MySQL.* directly).
    -- server/certifications/'s own k9_certifications/
    -- k9_certification_specializations reads and writes now go through
    -- K9Store.* rather than a local MySQL.*.await call -- Config.Database
    -- is deliberately absent from this fixture's Config table above, so
    -- K9Store's own DatabaseEnabled() fails safe to `true` (real-DB mode),
    -- routing every K9Store.* call straight through to this fixture's own
    -- `mysql` stub above, unchanged -- including every scalarCallCount-
    -- style call-count assertion below (see this file's own header note
    -- added at the certifications.lua call site for the full reasoning).
    Sandbox.loadInto('../server/cooldowns.lua', env)
    Sandbox.loadInto('../server/datastore.lua', env)
    Sandbox.loadInto('../server/events.lua', env) -- FireOutboundEvent, extracted from six identical local copies into one shared helper; loaded in the real resource via fxmanifest, so a sandbox that omits it fails where the game would not
    -- SPLIT 2026-09-02: one 6,012-line file became four, loaded in the same
    -- order fxmanifest.lua loads them. The order is load-bearing -- each
    -- file re-binds names the earlier ones published onto K9Cert, so a
    -- file loaded out of order would re-bind nil.
    Sandbox.loadInto('../server/certifications/core.lua', env)
    Sandbox.loadInto('../server/certifications/depth.lua', env)
    Sandbox.loadInto('../server/certifications/accessors.lua', env)
    Sandbox.loadInto('../server/certifications/commands.lua', env)

    -- ROSTER FIX (coordinator-flagged gap, this pass) -- opt-in, REAL,
    -- unmodified server/roster.lua loaded into the SAME env/K9Store so an
    -- integration test can exercise RevokeCertificationForTablet's new
    -- ClearPersonnelRowForCitizenJob call site against roster.lua's own
    -- genuine re-hire semantics (docs/history/ROSTER_SPEC.md §4), not a stub. Requires
    -- `Config.Database = { enabled = false }` (memory mode, opts.database
    -- above) -- roster.lua's own file-level gate
    -- (`Config.Features.CommandTablet == true`) also requires
    -- opts.features.CommandTablet = true, same as tabletFixture() below.
    if opts.includeRoster == true then
        Sandbox.loadInto('../server/roster.lua', env)
    end

    return {
        env = env,
        state = state,
        notifyLog = notifyLog,
        outboundEvents = outboundEvents,
        leashDetachCalls = leashDetachCalls,
        officerLeashDetachCalls = officerLeashDetachCalls,
        partnershipBreakCalls = partnershipBreakCalls,
        bodyClaimReleaseCalls = bodyClaimReleaseCalls,
        effectEndCalls = effectEndCalls,
        appearanceApplyCalls = appearanceApplyCalls,
        appearanceRevertCalls = appearanceRevertCalls,
        handlerXpAwardCalls = handlerXpAwardCalls,
        personnelClearCalls = personnelClearCalls,
        registerPlayer = registerPlayer,
        disconnectPlayer = disconnectPlayer,
        setPed = setPed,
        mysql = mysql,
        events = capturedEvents,
        commands = capturedCommands,
        callbacks = capturedCallbacks,
        eventHandlers = eventHandlers,
        printLog = printLog,
        setSource = function(src) env.source = src end,
        advanceTime = function(ms) state.now = state.now + ms end,
        -- CERTIFICATION DEPTH (this pass): advances the SEPARATE os.time()
        -- fake clock (real wall-clock seconds), independent of advanceTime
        -- above (GetGameTimer ms).
        advanceUnixTime = function(seconds) state.nowUnix = state.nowUnix + seconds end,
        threadRunner = threadRunner,
        waitCalls = waitCalls,
    }
end

--- @param f table -- a newFixture() result
--- @param source number
--- @return table? -- the LAST notifyLog entry for that source, or nil
local function lastNotifyFor(f, source)
    local found
    for _, entry in ipairs(f.notifyLog) do
        if entry.source == source then found = entry end
    end
    return found
end

--- @param f table
--- @param source number
--- @param message string
--- @param kind string
--- @return boolean
local function notifiedExactly(f, source, message, kind)
    local entry = lastNotifyFor(f, source)
    return entry ~= nil and entry.message == message and entry.kind == kind
end

--- Unlike notifiedExactly (last entry only), scans EVERY notifyLog entry
--- for `source` -- needed for self-certification, where granterSrc ==
--- targetServerId and BOTH the granter-facing and target-facing
--- NotifyPlayer calls land on the SAME source, so the target message
--- overwrites the granter message as far as "last" is concerned.
--- @param f table
--- @param source number
--- @param message string
--- @param kind string
--- @return boolean
local function anyNotify(f, source, message, kind)
    for _, entry in ipairs(f.notifyLog) do
        if entry.source == source and entry.message == message and entry.kind == kind then return true end
    end
    return false
end

-- COOLDOWN CONSTANT mirrored from the production file's own
-- CERTIFY_ACTION_COOLDOWN_MS (1500) -- not re-derived from the source, just
-- named here so every advanceTime() call below documents WHY it needs to
-- exceed this value.
local COOLDOWN_MS = 1500

-- ======================================================================
-- FIX (this pass): Config.Peds / Config.CertifyProximityMeters were
-- previously bare top-level `assert`s -- a malformed value on EITHER threw
-- at this file's own load time, aborting the ENTIRE FILE from that line
-- onward (HasK9Access, every net event/command, the OnJobUpdate handler --
-- all of it silently gone for the rest of the resource's uptime). Neither
-- was covered by any test before this pass ("nothing tests them either
-- way"). Now CLAMP AND WARN instead: this section pins that the file loads
-- successfully, a warning is printed, and the resulting degraded state is
-- exactly what's documented (a bad CertifyProximityMeters falls back to
-- 5.0; a bad/malformed Config.Peds means no model is ever recognized, but
-- HasK9Access itself is entirely unaffected).
-- ======================================================================

t.test('CONFIG-SAFETY: Config.CertifyProximityMeters = 0 does not abort the file -- resolves to the 5.0 fallback and warns', function()
    local f = newFixture({ proximityMeters = 0 })
    t.equals(f.env.Config.CertifyProximityMeters, 5.0)
    local warned = false
    for _, line in ipairs(f.printLog) do
        if line:find('Config.CertifyProximityMeters', 1, true) then warned = true end
    end
    t.isTrue(warned, 'a clamp-and-warn substitution must be loud, never silent')

    -- Functional proof, not just the raw value: an online revoke at 6m
    -- (beyond the OLD, invalid "0" but within the substituted 5.0... no --
    -- beyond 5.0 too) still enforces a real, positive proximity bound
    -- rather than the file having crashed or the check being disabled.
    f.registerPlayer(1000, 'PROX-GRANTER', { name = 'police', isboss = true })
    f.registerPlayer(1001, 'PROX-TARGET', { name = 'police', grade = { level = 1 } })
    f.setPed(1000, 5000, vec3(0, 0, 0))
    f.setPed(1001, 5001, vec3(6, 0, 0))
    f.setSource(1000)
    f.events['qbx_k9unit:server:certifyHandler'](1001)
    t.isTrue(notifiedExactly(f, 1000, localeWithPendingCertKeys('certifications.target_too_far_to_certify_distance', tostring(5.0)), 'error'))
end)

t.test('CONFIG-SAFETY: Config.CertifyProximityMeters = -3 (negative) does not abort the file -- resolves to the 5.0 fallback and warns', function()
    local f = newFixture({ proximityMeters = -3 })
    t.equals(f.env.Config.CertifyProximityMeters, 5.0)
end)

t.test('CONFIG-SAFETY: Config.CertifyProximityMeters = "5" (a string, not a number) does not abort the file -- resolves to the 5.0 fallback and warns', function()
    local f = newFixture({ proximityMeters = '5' })
    t.equals(f.env.Config.CertifyProximityMeters, 5.0)
end)

t.test('CONFIG-SAFETY: a VALID, non-default Config.CertifyProximityMeters passes through unchanged, with no warning', function()
    local f = newFixture({ proximityMeters = 12.5 })
    t.equals(f.env.Config.CertifyProximityMeters, 12.5)
    for _, line in ipairs(f.printLog) do
        t.isFalse(line:find('CertifyProximityMeters', 1, true) ~= nil, 'a genuinely valid value must never warn')
    end
end)

-- ----------------------------------------------------------------------
-- CONFIG-SAFETY -- Config.CertificationExpiryDays / Config.
-- CertificationExpiryWarningDays. Found while tracing the EXPIRY chain
-- end-to-end: Config.CertificationExpiryCheckIntervalMs already had a
-- clamp-and-warn (see the CreateThread loop's own regression tests
-- further below), but these two silently degraded with no print at all --
-- an operator who enables Config.Features.CertificationExpiry and typos
-- Config.CertificationExpiryDays would see the feature "on" and get NO
-- expiry set on any new/renewed certification, forever, with nothing
-- printed anywhere to explain why.
-- ----------------------------------------------------------------------

t.test('CONFIG-SAFETY: Config.CertificationExpiryDays = 0 while the feature is ON does not silently succeed with an expiry anyway -- warns loudly and the grant gets NO expiry at all', function()
    local f = newFixture({ features = { CertificationExpiry = true }, expiryDays = 0 })
    f.registerPlayer(10, 'GRANTER', { name = 'police', isboss = true })
    f.registerPlayer(20, 'TARGET', { name = 'police', grade = { level = 1 } })
    f.setPed(10, 1000, vec3(0, 0, 0))
    f.setPed(20, 2000, vec3(1, 0, 0), K9_HASH_SHEPHERD)

    local insertParams
    f.mysql.insert.await = function(_sql, params) insertParams = params; return 55 end
    local scalarCallCount = 0
    f.mysql.scalar.await = function()
        scalarCallCount = scalarCallCount + 1
        if scalarCallCount == 1 then return nil end
        return 55
    end

    f.setSource(10)
    f.events['qbx_k9unit:server:certifyHandler'](20)

    t.equals(#insertParams, 3, 'a misconfigured expiry window must degrade to the pre-expiry 3-argument INSERT, never a 4th argument built from a bad number')

    local warned = false
    for _, line in ipairs(f.printLog) do
        if line:find('Config.CertificationExpiryDays', 1, true) then warned = true end
    end
    t.isTrue(warned, 'a clamp-and-warn substitution must be loud, never silent -- an operator who deliberately enabled the feature deserves to know it is not doing anything')
end)

t.test("CONFIG-SAFETY: Config.CertificationExpiryDays misconfigured while the feature is OFF never warns -- an unused garbage value on a server that never opted in is not this file's business", function()
    local f = newFixture({ expiryDays = 0 }) -- Config.Features absent -- expiry off
    f.registerPlayer(10, 'GRANTER', { name = 'police', isboss = true })
    f.registerPlayer(20, 'TARGET', { name = 'police', grade = { level = 1 } })
    f.setPed(10, 1000, vec3(0, 0, 0))
    f.setPed(20, 2000, vec3(1, 0, 0), K9_HASH_SHEPHERD)
    f.mysql.insert.await = function() return 56 end
    f.mysql.scalar.await = function() return nil end

    f.setSource(10)
    f.events['qbx_k9unit:server:certifyHandler'](20)

    for _, line in ipairs(f.printLog) do
        t.isFalse(line:find('CertificationExpiryDays', 1, true) ~= nil, 'the feature being off must never itself trigger this warning')
    end
end)

t.test('CONFIG-SAFETY: Config.CertificationExpiryWarningDays = -1 does not abort -- falls back to 7 and warns loudly', function()
    local f = newFixture({ features = { CertificationExpiry = true }, expiryDays = 90, expiryWarningDays = -1 })
    f.registerPlayer(20, 'TARGET', { name = 'police', grade = { level = 1 } })
    f.mysql.scalar.await = function() return 5 end
    -- 3 days remaining -- would fall inside any sane warning window, so
    -- this also proves the fallback actually applied is 7 (wide enough to
    -- catch it), not 0 or "never warn".
    f.mysql.single.await = function() return { tier = 'certified', expires_at_unix = 1700000000 + 259200 } end
    f.env.RefreshCertificationCache('TARGET', 'police')

    f.threadRunner.step()
    f.threadRunner.step()

    t.isTrue(notifiedExactly(f, 20, Sandbox.locale('certifications.expiry_warning', '3'), 'inform'), 'the fallback of 7 days must still be wide enough to catch 3 days remaining')

    local warned = false
    for _, line in ipairs(f.printLog) do
        if line:find('Config.CertificationExpiryWarningDays', 1, true) then warned = true end
    end
    t.isTrue(warned, 'a clamp-and-warn substitution must be loud, never silent')
end)

t.test('CONFIG-SAFETY: an EMPTY Config.Peds does not abort the file -- HasK9Access keeps working normally, IsConfiguredK9Model rejects every model, and a warning is printed', function()
    local f = newFixture({ peds = {} })
    local warned = false
    for _, line in ipairs(f.printLog) do
        if line:find('Config.Peds', 1, true) then warned = true end
    end
    t.isTrue(warned)
    t.isFalse(f.env.IsConfiguredK9Model(K9_HASH_SHEPHERD))

    -- HasK9Access itself never consults Config.Peds at all -- unaffected.
    f.registerPlayer(1010, 'PEDS-EMPTY-CIT', { name = 'police', grade = { level = 1 } })
    f.mysql.scalar.await = function() return 55 end
    f.env.RefreshCertificationCache('PEDS-EMPTY-CIT', 'police')
    t.isTrue(f.env.HasK9Access(1010))
end)

t.test('CONFIG-SAFETY: a non-table Config.Peds does not abort the file -- same degraded-but-bounded outcome as empty', function()
    local f = newFixture({ peds = 'not-a-table' })
    t.isFalse(f.env.IsConfiguredK9Model(K9_HASH_SHEPHERD))
    f.registerPlayer(1011, 'PEDS-BADTYPE-CIT', { name = 'police', grade = { level = 1 } })
    f.mysql.scalar.await = function() return 56 end
    f.env.RefreshCertificationCache('PEDS-BADTYPE-CIT', 'police')
    t.isTrue(f.env.HasK9Access(1011))
end)

t.test('CONFIG-SAFETY: ONE malformed Config.Peds entry is skipped on its own -- every OTHER valid entry in the same array still works, and exactly one warning names that entry', function()
    local f = newFixture({ peds = {
        { model = 'a_c_shepherd' },
        { model = 123 },              -- malformed: not a string
        { model = 'a_c_rottweiler' },
    } })
    t.isTrue(f.env.IsConfiguredK9Model(K9_HASH_SHEPHERD), 'the valid entry BEFORE the bad one must still be recognized')
    t.isTrue(f.env.IsConfiguredK9Model(K9_HASH_ROTTWEILER), 'the valid entry AFTER the bad one must still be recognized')

    local warnCount = 0
    for _, line in ipairs(f.printLog) do
        if line:find('Config.Peds%[2%]') then warnCount = warnCount + 1 end
    end
    t.equals(warnCount, 1, 'exactly one warning, naming the one bad index -- never one per valid entry')
end)

-- ======================================================================
-- HasK9Access -- the gate everything else trusts
-- ======================================================================

t.test('HasK9Access: a certified handler in the exact cached job passes', function()
    local f = newFixture()
    f.registerPlayer(1, 'CIT1', { name = 'police', grade = { level = 1 } })
    f.mysql.scalar.await = function() return 42 end -- an active row exists
    f.env.RefreshCertificationCache('CIT1', 'police')
    t.isTrue(f.env.HasK9Access(1))
end)

t.test('HasK9Access: a player with no cert at all (never refreshed) fails -- pure cache miss', function()
    local f = newFixture()
    f.registerPlayer(2, 'CIT2', { name = 'police', grade = { level = 1 } })
    t.isFalse(f.env.HasK9Access(2))
end)

t.test('HasK9Access: an unknown citizenid (never seen by this cert system at all) fails, not errors', function()
    local f = newFixture()
    f.registerPlayer(3, 'NEVER-SEEN-CITIZENID', { name = 'police', grade = { level = 1 } })
    t.isFalse(f.env.HasK9Access(3))
end)

t.test('HasK9Access: cached ACTIVE cert scoped to a DIFFERENT job than the player\'s current job fails (stale cache after a job change)', function()
    local f = newFixture()
    -- CIT4 was certified for police, then switched jobs to sheriff, but
    -- RefreshCertificationCache has not yet re-scoped the cache to sheriff.
    f.mysql.scalar.await = function() return 7 end
    f.env.RefreshCertificationCache('CIT4', 'police')
    f.registerPlayer(4, 'CIT4', { name = 'sheriff', grade = { level = 1 } })
    t.isFalse(f.env.HasK9Access(4), 'a cert cached for a DIFFERENT job must never grant access under the new job')
end)

t.test('HasK9Access: cached INACTIVE cert (revoked) fails even though a cache entry exists', function()
    local f = newFixture()
    f.mysql.scalar.await = function() return nil end -- no active row -> RefreshCertificationCache caches active=false
    f.env.RefreshCertificationCache('CIT5', 'police')
    f.registerPlayer(5, 'CIT5', { name = 'police', grade = { level = 1 } })
    t.isFalse(f.env.HasK9Access(5))
end)

t.test('HasK9Access: a job not in Config.Departments fails outright, never consults the cache', function()
    local f = newFixture()
    f.mysql.scalar.await = function() return 99 end
    f.env.RefreshCertificationCache('CIT6', 'taxi')
    f.registerPlayer(6, 'CIT6', { name = 'taxi', grade = { level = 99 } })
    t.isFalse(f.env.HasK9Access(6))
end)

t.test('HasK9Access: GetPlayer resolving to nil (unknown/disconnected source) fails', function()
    local f = newFixture()
    t.isFalse(f.env.HasK9Access(9999))
end)

t.test('HasK9Access: a player object with no PlayerData fails', function()
    local f = newFixture()
    f.env.exports.qbx_core.GetPlayer = function(_self, source)
        if source == 7 then return { PlayerData = nil } end
    end
    t.isFalse(f.env.HasK9Access(7))
end)

t.test('HasK9Access: autoAccessGrade bypass grants access with NO cert cached at all, once grade meets the threshold', function()
    local f = newFixture({ departments = {
        police = { label = 'Police', certifierGrade = 4, autoAccessGrade = 10 },
    } })
    f.registerPlayer(8, 'CIT8', { name = 'police', grade = { level = 10 } })
    t.isTrue(f.env.HasK9Access(8), 'grade 10 >= autoAccessGrade 10 must bypass the cert requirement entirely')
end)

t.test('HasK9Access: autoAccessGrade bypass does NOT apply below the configured threshold', function()
    local f = newFixture({ departments = {
        police = { label = 'Police', certifierGrade = 4, autoAccessGrade = 10 },
    } })
    f.registerPlayer(9, 'CIT9', { name = 'police', grade = { level = 9 } })
    t.isFalse(f.env.HasK9Access(9))
end)

t.test('HasK9Access: autoAccessGrade configured but job.grade itself is missing fails defensively, never errors', function()
    local f = newFixture({ departments = {
        police = { label = 'Police', certifierGrade = 4, autoAccessGrade = 10 },
    } })
    f.registerPlayer(10, 'CIT10', { name = 'police' }) -- no .grade field at all
    t.isFalse(f.env.HasK9Access(10))
end)

t.test('HasK9Access: with autoAccessGrade nil (shipped default), a high grade alone never bypasses the cert requirement', function()
    local f = newFixture() -- shipped-shape Config.Departments.police.autoAccessGrade = nil
    f.registerPlayer(11, 'CIT11', { name = 'police', isboss = true, grade = { level = 99 } })
    t.isFalse(f.env.HasK9Access(11), 'isboss/high grade with no active cert and no autoAccessGrade configured must still fail -- matches the shipped Config.AllowSelfCertification default not implying an access bypass')
end)

-- ======================================================================
-- HasK9Access -- EXPLICIT PER-PERSON BLOCK (security-audit pass, this
-- pass -- "assess, then decide": k9.access/k9.certify/k9.audit/k9.givexp
-- had NO block mechanism at all, so an owner could not selectively
-- restrain one otherwise-qualifying officer without demoting them). Proves
-- 'block.k9.access' beats EVERY qualifying route HasK9Access has -- the
-- explicit grant, an active certification, and the autoAccessGrade rank
-- bypass -- exactly matching the "an explicit block beats everything"
-- precedence this resource already uses for the Config.Features
-- 'block.<Name>' namespace.
-- ======================================================================

t.test('HasK9Access: block.k9.access beats an explicit, real k9.access grant', function()
    local f = newFixture()
    f.registerPlayer(20, 'CIT20', { name = 'police', grade = { level = 1 } })
    f.env.HasPermission = function(citizenid, key)
        return citizenid == 'CIT20' and (key == 'k9.access' or key == 'block.k9.access')
    end
    t.isFalse(f.env.HasK9Access(20), 'a real grant must not survive an explicit block on the same capability')
end)

t.test('HasK9Access: block.k9.access beats the autoAccessGrade rank bypass', function()
    local f = newFixture({ departments = {
        police = { label = 'Police', certifierGrade = 4, autoAccessGrade = 10 },
    } })
    f.registerPlayer(21, 'CIT21', { name = 'police', grade = { level = 10 } }) -- meets autoAccessGrade exactly
    f.env.HasPermission = function(citizenid, key) return citizenid == 'CIT21' and key == 'block.k9.access' end
    t.isFalse(f.env.HasK9Access(21), 'rank alone must not survive an explicit block -- this is the ONE lever to restrain a rank-qualified officer without demoting them')
end)

t.test('HasK9Access: block.k9.access beats an active, real certification', function()
    local f = newFixture()
    f.mysql.scalar.await = function() return 55 end -- an active cert row exists
    f.env.RefreshCertificationCache('CIT22', 'police')
    f.registerPlayer(22, 'CIT22', { name = 'police', grade = { level = 1 } })
    f.env.HasPermission = function(citizenid, key) return citizenid == 'CIT22' and key == 'block.k9.access' end
    t.isFalse(f.env.HasK9Access(22), 'a genuine, active certification must not survive an explicit block')
end)

t.test('HasK9Access: block.k9.access is scoped to that ONE citizenid -- a different, unblocked handler with an identical certification is unaffected', function()
    local f = newFixture()
    f.mysql.scalar.await = function() return 56 end
    f.env.RefreshCertificationCache('CIT23', 'police')
    f.registerPlayer(23, 'CIT23', { name = 'police', grade = { level = 1 } })
    f.env.HasPermission = function(citizenid, key) return citizenid == 'SOMEONE-ELSE' and key == 'block.k9.access' end
    t.isTrue(f.env.HasK9Access(23), 'a block on a DIFFERENT citizenid must never leak onto this one')
end)

t.test('HasK9Access: block.k9.access does not accidentally block on an UNRELATED capability key -- specificity of the match', function()
    local f = newFixture()
    f.mysql.scalar.await = function() return 57 end
    f.env.RefreshCertificationCache('CIT24', 'police')
    f.registerPlayer(24, 'CIT24', { name = 'police', grade = { level = 1 } })
    -- Only 'block.k9.certify' is set for this citizenid -- 'block.k9.access' itself is never true.
    f.env.HasPermission = function(citizenid, key) return citizenid == 'CIT24' and key == 'block.k9.certify' end
    t.isTrue(f.env.HasK9Access(24), 'a block on a DIFFERENT capability must never narrow this one')
end)

-- ======================================================================
-- GrantCertification -- reached via the captured net event; env.source is
-- the ambient global the real RegisterNetEvent closure reads, exactly as
-- FXServer would set it per-invocation.
-- ======================================================================

t.test('GrantCertification: a non-numeric targetServerId is rejected outright, before any MySQL call', function()
    local f = newFixture()
    f.registerPlayer(1, 'G1', { name = 'police', isboss = true })
    local scalarCalled = false
    f.mysql.scalar.await = function() scalarCalled = true end
    f.setSource(1)
    f.events['qbx_k9unit:server:certifyHandler']('not-a-number')
    t.isTrue(notifiedExactly(f, 1, localeWithPendingCertKeys('certifications.invalid_target_id'), 'error'))
    t.isFalse(scalarCalled)
end)

t.test('GrantCertification: a granter who is not certifier-eligible is rejected', function()
    local f = newFixture()
    f.registerPlayer(1, 'G1', { name = 'police', grade = { level = 1 } }) -- below certifierGrade 4, not boss
    f.registerPlayer(2, 'T1', { name = 'police', grade = { level = 1 } })
    f.setSource(1)
    f.events['qbx_k9unit:server:certifyHandler'](2)
    t.isTrue(notifiedExactly(f, 1, localeWithPendingCertKeys('certifications.not_authorized_to_certify_hint'), 'error'))
end)

-- ======================================================================
-- IsEligibleCertifier -- EXPLICIT PER-PERSON BLOCK (security-audit pass,
-- this pass). Reached indirectly through the real GrantCertification net
-- event, exactly like the "not certifier-eligible" test immediately above
-- -- proves 'block.k9.certify' beats even job.isboss, the ONE bypass in
-- this function nothing else can override.
-- ======================================================================

t.test('GrantCertification: an explicit block.k9.certify denies even job.isboss', function()
    local f = newFixture()
    f.registerPlayer(1, 'G1', { name = 'police', isboss = true })
    f.registerPlayer(2, 'T1', { name = 'police', grade = { level = 1 } })
    f.env.HasPermission = function(citizenid, key) return citizenid == 'G1' and key == 'block.k9.certify' end
    f.setSource(1)
    f.events['qbx_k9unit:server:certifyHandler'](2)
    t.isTrue(notifiedExactly(f, 1, localeWithPendingCertKeys('certifications.not_authorized_to_certify_hint'), 'error'),
        'an explicit block must beat job.isboss -- this is the ONE lever to restrain a boss-ranked officer\'s certifying ability without demoting them')
end)

t.test('GrantCertification: block.k9.certify is scoped to that ONE citizenid -- a DIFFERENT boss-ranked granter is unaffected', function()
    local f = newFixture()
    f.registerPlayer(1, 'G2', { name = 'police', isboss = true })
    f.registerPlayer(2, 'T2', { name = 'police', grade = { level = 1 } })
    f.setPed(1, 100, vec3(0, 0, 0))
    f.setPed(2, 200, vec3(0, 0, 0), K9_HASH_SHEPHERD)
    f.env.HasPermission = function(citizenid, key) return citizenid == 'SOMEONE-ELSE' and key == 'block.k9.certify' end
    f.setSource(1)
    f.events['qbx_k9unit:server:certifyHandler'](2)
    t.isFalse(notifiedExactly(f, 1, localeWithPendingCertKeys('certifications.not_authorized_to_certify_hint'), 'error'),
        'a block on a DIFFERENT citizenid must never leak onto this granter')
end)

t.test('GrantCertification: the certifier action cooldown silently no-ops the second rapid call from the SAME granter (no notification at all)', function()
    local f = newFixture()
    f.registerPlayer(1, 'G1', { name = 'police', isboss = true })
    f.registerPlayer(2, 'T1', { name = 'police', grade = { level = 1 } })
    f.setPed(1, 100, vec3(0, 0, 0))
    f.setPed(2, 200, vec3(0, 0, 0), K9_HASH_SHEPHERD)
    f.setSource(1)
    f.events['qbx_k9unit:server:certifyHandler'](2) -- first call: succeeds
    local notifyCountAfterFirst = #f.notifyLog
    f.events['qbx_k9unit:server:certifyHandler'](2) -- second call, same tick: on cooldown
    t.equals(#f.notifyLog, notifyCountAfterFirst, 'a cooldown rejection must be a silent no-op, matching the bark/leash-request convention documented in the source')
end)

t.test('GrantCertification: self-certification is rejected when Config.AllowSelfCertification is false', function()
    local f = newFixture({ allowSelfCert = false })
    f.registerPlayer(1, 'G1', { name = 'police', isboss = true })
    f.setSource(1)
    f.events['qbx_k9unit:server:certifyHandler'](1)
    t.isTrue(notifiedExactly(f, 1, localeWithPendingCertKeys('certifications.self_certification_disabled_hint'), 'error'))
end)

-- ======================================================================
-- THE OWNER'S OWN LIVE REPORT, END TO END
--
-- "i am rank 8 on the police job and it says i am not high command to
-- certify myself with /k9certify" -- on a STOCK install, which ships
-- Config.Database.enabled = false.
--
-- The cause was in server/permissions.lua (memory-only mode being read as
-- "cannot verify blocks", so block.k9.certify came back TRUE for
-- everyone) and permissions_spec.lua's own CASE 0 block pins that unit
-- directly. What NOTHING pinned was the whole journey: a boss-ranked
-- officer, nobody having blocked them, actually getting certified by
-- pressing the thing they pressed.
--
-- Those are different failures. The unit test would still pass if some
-- later change broke self-certification for a boss somewhere further down
-- GrantCertification -- proximity, eligibility, the self-cert branch --
-- and the owner would be looking at the same refusal message again. This
-- asserts the outcome he actually cared about.
-- ======================================================================

t.test('OWNER REPORT, END TO END: a boss-ranked officer self-certifies successfully on a stock install with nothing blocked', function()
    local f = newFixture()
    f.registerPlayer(1, 'CHIEF', { name = 'police', isboss = true, grade = { level = 8 } })
    f.setPed(1, 100, vec3(0, 0, 0))
    -- Stock install: no permission rows exist at all, so HasPermission
    -- answers false for EVERY key -- including block.k9.certify. This is
    -- exactly the state the CASE 0 fix restored; before it, this same
    -- accessor returned true for the block key and refused the request.
    f.env.HasPermission = function() return false end
    f.setSource(1)
    f.events['qbx_k9unit:server:certifyHandler'](1)

    t.isFalse(notifiedExactly(f, 1, localeWithPendingCertKeys('certifications.not_authorized_to_certify_hint'), 'error'),
        'THE REPORTED BUG: a rank-8 boss must never be told they are not authorized to certify on a stock install')
    t.isFalse(notifiedExactly(f, 1, localeWithPendingCertKeys('certifications.self_certification_disabled_hint'), 'error'),
        'and Config.AllowSelfCertification ships true, so self-certification must not be refused either')
end)

t.test('OWNER REPORT, CONTROL: reintroducing the defect (block.k9.certify reading true, as memory-mode used to) refuses that same officer', function()
    local f = newFixture()
    f.registerPlayer(1, 'CHIEF', { name = 'police', isboss = true, grade = { level = 8 } })
    f.setPed(1, 100, vec3(0, 0, 0))
    -- The pre-fix behaviour, reproduced exactly: memory-only mode made the
    -- block namespace fail closed, so this key answered true for a
    -- citizenid nobody had ever blocked.
    f.env.HasPermission = function(_, key) return key == 'block.k9.certify' end
    f.setSource(1)
    f.events['qbx_k9unit:server:certifyHandler'](1)

    t.isTrue(notifiedExactly(f, 1, localeWithPendingCertKeys('certifications.not_authorized_to_certify_hint'), 'error'),
        'proves the test above is really watching this path -- with the defect back, the same officer is refused again')
end)

t.test('GrantCertification: an offline target (not currently connected) is rejected -- grant requires an online target', function()
    local f = newFixture()
    f.registerPlayer(1, 'G1', { name = 'police', isboss = true })
    f.setSource(1)
    f.events['qbx_k9unit:server:certifyHandler'](2) -- source 2 never registered -> offline
    -- Config.K9Appearance is absent in this fixture (requireK9ModelForRole
    -- not true), so the "point at the offline shape" variant applies -- see
    -- the matching model-check variant test further below.
    t.isTrue(notifiedExactly(f, 1, localeWithPendingCertKeys('certifications.target_must_be_online_use_offline'), 'error'))
end)

t.test('GrantCertification: an offline target is told the MODEL-CHECK variant instead when Config.K9Appearance.requireK9ModelForRole is true -- never a false promise that the offline shape would work', function()
    local f = newFixture({ k9Appearance = { requireK9ModelForRole = true } })
    f.registerPlayer(1, 'G1', { name = 'police', isboss = true })
    f.setSource(1)
    f.events['qbx_k9unit:server:certifyHandler'](2)
    t.isTrue(notifiedExactly(f, 1, localeWithPendingCertKeys('certifications.target_must_be_online_model_check'), 'error'))
end)

t.test('GrantCertification: a target not employed by any configured department is rejected', function()
    local f = newFixture()
    f.registerPlayer(1, 'G1', { name = 'police', isboss = true })
    f.registerPlayer(2, 'T1', { name = 'taxi', grade = { level = 1 } })
    f.setSource(1)
    f.events['qbx_k9unit:server:certifyHandler'](2)
    t.isTrue(notifiedExactly(f, 1, localeWithPendingCertKeys('certifications.target_not_in_department_hint', 'police, sheriff'), 'error'))
end)

t.test('GrantCertification: a target beyond Config.CertifyProximityMeters is rejected (live server-side coords, not client-claimed)', function()
    local f = newFixture({ proximityMeters = 5.0 })
    f.registerPlayer(1, 'G1', { name = 'police', isboss = true })
    f.registerPlayer(2, 'T1', { name = 'police', grade = { level = 1 } })
    f.setPed(1, 100, vec3(0, 0, 0))
    f.setPed(2, 200, vec3(100, 0, 0), K9_HASH_SHEPHERD) -- 100m away, target IS K9-modeled
    f.setSource(1)
    f.events['qbx_k9unit:server:certifyHandler'](2)
    t.isTrue(notifiedExactly(f, 1, localeWithPendingCertKeys('certifications.target_too_far_to_certify_distance', tostring(5.0)), 'error'))
end)

t.test('GrantCertification: proximity is skipped for self-certification (nothing to measure distance to)', function()
    local f = newFixture()
    f.registerPlayer(1, 'G1', { name = 'police', isboss = true })
    f.setPed(1, 100, vec3(0, 0, 0), K9_HASH_SHEPHERD) -- self-cert: same ped serves as both granter and target
    f.setSource(1)
    f.events['qbx_k9unit:server:certifyHandler'](1)
    -- Self-cert means granterSrc == targetServerId, so BOTH the
    -- granter-facing and target-facing NotifyPlayer calls land on the same
    -- source -- use anyNotify (scans every entry), not notifiedExactly
    -- (last entry only, which here would only ever see the target-facing
    -- message since it's sent second).
    t.isTrue(anyNotify(f, 1, Sandbox.locale('certifications.grant_success_granter'), 'success'), 'a huge proximity would have rejected this if it were checked -- self-cert must skip it entirely')
    t.isTrue(anyNotify(f, 1, Sandbox.locale('certifications.grant_success_target'), 'success'))
end)


t.test('GrantCertification: a target not employed by any configured department is rejected', function()
    local f = newFixture()
    f.registerPlayer(1, 'G1', { name = 'police', isboss = true })
    f.registerPlayer(2, 'T1', { name = 'taxi', grade = { level = 1 } })
    f.setSource(1)
    f.events['qbx_k9unit:server:certifyHandler'](2)
    t.isTrue(notifiedExactly(f, 1, localeWithPendingCertKeys('certifications.target_not_in_department_hint', 'police, sheriff'), 'error'))
end)

t.test('GrantCertification: a target beyond Config.CertifyProximityMeters is rejected (live server-side coords, not client-claimed)', function()
    local f = newFixture({ proximityMeters = 5.0 })
    f.registerPlayer(1, 'G1', { name = 'police', isboss = true })
    f.registerPlayer(2, 'T1', { name = 'police', grade = { level = 1 } })
    f.setPed(1, 100, vec3(0, 0, 0))
    f.setPed(2, 200, vec3(100, 0, 0), K9_HASH_SHEPHERD) -- 100m away, target IS K9-modeled
    f.setSource(1)
    f.events['qbx_k9unit:server:certifyHandler'](2)
    t.isTrue(notifiedExactly(f, 1, localeWithPendingCertKeys('certifications.target_too_far_to_certify_distance', tostring(5.0)), 'error'))
end)

t.test('GrantCertification: proximity is skipped for self-certification (nothing to measure distance to)', function()
    local f = newFixture()
    f.registerPlayer(1, 'G1', { name = 'police', isboss = true })
    f.setPed(1, 100, vec3(0, 0, 0), K9_HASH_SHEPHERD) -- self-cert: same ped serves as both granter and target
    f.setSource(1)
    f.events['qbx_k9unit:server:certifyHandler'](1)
    -- Self-cert means granterSrc == targetServerId, so BOTH the
    -- granter-facing and target-facing NotifyPlayer calls land on the same
    -- source -- use anyNotify (scans every entry), not notifiedExactly
    -- (last entry only, which here would only ever see the target-facing
    -- message since it's sent second).
    t.isTrue(anyNotify(f, 1, Sandbox.locale('certifications.grant_success_granter'), 'success'), 'a huge proximity would have rejected this if it were checked -- self-cert must skip it entirely')
    t.isTrue(anyNotify(f, 1, Sandbox.locale('certifications.grant_success_target'), 'success'))
end)

-- ======================================================================
-- ECONOMY FIX: self-cert/decertify farm loop (CertifyXpMintCooldown).
--
-- See server/certifications/'s own CertifyXpMintCooldown declaration
-- comment (search that file for "ECONOMY FIX", right after
-- CERTIFY_ACTION_COOLDOWN_MS/CertifyActionCooldown) for the full writeup
-- this section proves out end to end, against the REAL production file,
-- not by reasoning about it: an eligible certifier (an officer at or above
-- certifierGrade, or a boss -- Config.AllowSelfCertification true by
-- default, and RevokeCertification's own proximity check is explicitly
-- skipped for self-cert) could otherwise `/k9certify <self>` then
-- `/k9decertify <self>` on repeat, minting handlerCertifyK9's 50 XP every
-- ~3 real seconds -- 60,000 XP/hr gross, worse than either
-- handlerKennelDeploy or handlerTreatK9, both of which this codebase
-- already refused to wire for exactly this class of gap.
--
-- These tests drive GrantCertification/RevokeCertification/
-- GrantCertificationOffline through the REAL net-event/command entry
-- points (never the local functions directly), exactly like every other
-- test in this file, and assert on handlerXpAwardCalls (this fixture's own
-- AwardHandlerXP spy, newFixture's own opts.includeHandlerXpHook) -- never
-- on reasoning about what SHOULD have happened. Every action is spaced by
-- more than CERTIFY_ACTION_COOLDOWN_MS (1500ms, shared by grant+revoke for
-- one granter source) via f.advanceTime, matching this file's own header
-- convention -- a loop that never cleared that fat-finger guard would not
-- be exercising the real exploit shape at all.
-- ======================================================================

-- Mirrors server/certifications/'s own CERTIFY_XP_MINT_COOLDOWN_MS
-- literal exactly (a hardcoded file-local constant there, not a Config
-- value -- see that file's own declaration comment for why) so a future
-- change to the production constant is impossible to silently drift out of
-- sync with here without this file's own arithmetic below visibly failing.
local CERTIFY_XP_MINT_COOLDOWN_MS = 24 * 60 * 60 * 1000

t.test('ECONOMY FIX: repeated self-certify/decertify of the SAME target must stop paying handlerCertifyK9 after the first mint', function()
    local f = newFixture()
    f.registerPlayer(1, 'G1', { name = 'police', isboss = true })
    f.setPed(1, 100, vec3(0, 0, 0), K9_HASH_SHEPHERD)
    f.setSource(1)

    -- Cycle 1: certify self -- a genuinely NEW certification, must pay.
    f.events['qbx_k9unit:server:certifyHandler'](1)
    t.equals(#f.handlerXpAwardCalls, 1, 'the FIRST self-certification is a genuine new grant and must pay')
    t.equals(f.handlerXpAwardCalls[1][1], 'G1')
    t.equals(f.handlerXpAwardCalls[1][2], 'handlerCertifyK9')

    f.advanceTime(COOLDOWN_MS + 100)
    f.events['qbx_k9unit:server:revokeHandler'](1, nil)

    -- Cycles 2..5: repeat the certify/decertify loop several more times in
    -- a row, each action spaced past CERTIFY_ACTION_COOLDOWN_MS but well
    -- inside CertifyXpMintCooldown's 24-hour window -- the exact loop the
    -- economy audit measured (a 3-second cycle at 50 XP -- 60,000 XP/hr
    -- gross without this fix).
    for _ = 1, 4 do
        f.advanceTime(COOLDOWN_MS + 100)
        f.events['qbx_k9unit:server:certifyHandler'](1)
        f.advanceTime(COOLDOWN_MS + 100)
        f.events['qbx_k9unit:server:revokeHandler'](1, nil)
    end

    t.equals(#f.handlerXpAwardCalls, 1, 'four more full certify/decertify cycles against the SAME (granter, target) pair, well inside the 24h mint-cooldown window, must mint ZERO additional handlerCertifyK9 XP -- the loop must be closed, not merely slowed')
end)

t.test('ECONOMY FIX: a legitimate first certification of a genuinely NEW person still pays normally, independent of another pair\'s mint cooldown', function()
    local f = newFixture()
    f.registerPlayer(1, 'G1', { name = 'police', isboss = true })
    f.setPed(1, 100, vec3(0, 0, 0), K9_HASH_SHEPHERD)
    f.setSource(1)

    -- Exhaust the self-cert pair's mint cooldown first (matches the loop
    -- above), then prove a DIFFERENT, genuinely new target still pays
    -- immediately -- proving the fix is scoped to the (granter, target)
    -- PAIR, not a blanket per-granter throttle that would also break real,
    -- distinct certification work.
    f.events['qbx_k9unit:server:certifyHandler'](1)
    f.advanceTime(COOLDOWN_MS + 100)
    f.events['qbx_k9unit:server:revokeHandler'](1, nil)
    f.advanceTime(COOLDOWN_MS + 100)
    f.events['qbx_k9unit:server:certifyHandler'](1) -- same pair again -- must NOT pay
    t.equals(#f.handlerXpAwardCalls, 1, 'sanity check on this test\'s own setup -- the self-pair repeat must not have paid')

    f.registerPlayer(2, 'T1', { name = 'police', grade = { level = 1 } })
    f.setPed(2, 200, vec3(0, 0, 0), K9_HASH_SHEPHERD)
    f.advanceTime(COOLDOWN_MS + 100)
    f.events['qbx_k9unit:server:certifyHandler'](2)

    t.equals(#f.handlerXpAwardCalls, 2, 'a genuinely NEW (granter, target) pair must pay immediately, even while the SAME granter\'s self-pair is still on its own mint cooldown')
    t.equals(f.handlerXpAwardCalls[2][1], 'G1')
    t.equals(f.handlerXpAwardCalls[2][2], 'handlerCertifyK9')
end)

t.test('ECONOMY FIX: re-certifying the SAME (granter, target) pair pays again once CertifyXpMintCooldown\'s 24-hour window has fully elapsed', function()
    local f = newFixture()
    f.registerPlayer(1, 'G1', { name = 'police', isboss = true })
    f.setPed(1, 100, vec3(0, 0, 0), K9_HASH_SHEPHERD)
    f.setSource(1)

    f.events['qbx_k9unit:server:certifyHandler'](1)
    t.equals(#f.handlerXpAwardCalls, 1)
    f.advanceTime(COOLDOWN_MS + 100)
    f.events['qbx_k9unit:server:revokeHandler'](1, nil)

    -- Just under 24h later: still the SAME farm-window, must not pay yet.
    f.advanceTime(CERTIFY_XP_MINT_COOLDOWN_MS - 2000)
    f.events['qbx_k9unit:server:certifyHandler'](1)
    t.equals(#f.handlerXpAwardCalls, 1, 'still inside the 24h mint-cooldown window -- must not pay yet')
    f.advanceTime(COOLDOWN_MS + 100)
    f.events['qbx_k9unit:server:revokeHandler'](1, nil)

    -- Push fully past 24h measured from the FIRST mint's own stamp.
    f.advanceTime(5000)
    f.events['qbx_k9unit:server:certifyHandler'](1)
    t.equals(#f.handlerXpAwardCalls, 2, 'a real, distinct re-certification of the same person after a full day is a plausible genuine event and must pay again -- this cooldown throttles a FARM, not every future legitimate re-grant of the same person forever')
end)

t.test('ECONOMY FIX: the SAME farm loop through /k9certify + /k9decertify with citizenids is closed by the identical CertifyXpMintCooldown', function()
    local f = newFixture()
    f.registerPlayer(1, 'G1', { name = 'police', isboss = true })
    f.setSource(1)

    f.commands['k9certify'].fn(1, { 'OFFLINE_T1', 'police' })
    t.equals(#f.handlerXpAwardCalls, 1, 'a genuinely new offline grant still pays')

    f.advanceTime(COOLDOWN_MS + 100)
    f.commands['k9decertify'].fn(1, { 'OFFLINE_T1', 'police' })
    f.advanceTime(COOLDOWN_MS + 100)
    f.commands['k9certify'].fn(1, { 'OFFLINE_T1', 'police' })

    t.equals(#f.handlerXpAwardCalls, 1, 'repeating the SAME (granter, target) pair through the offline grant path must not mint a second time either -- GrantCertification and GrantCertificationOffline share the SAME CertifyXpMintCooldown tracker')
end)

t.test('ECONOMY FIX: AwardHandlerXP being entirely absent (soft dependency) never breaks the grant/revoke flow itself -- CertifyXpMintCooldown.Consume is only ever reached alongside a real AwardHandlerXP call', function()
    local f = newFixture({ includeHandlerXpHook = false })
    f.registerPlayer(1, 'G1', { name = 'police', isboss = true })
    f.setPed(1, 100, vec3(0, 0, 0), K9_HASH_SHEPHERD)
    f.setSource(1)

    f.events['qbx_k9unit:server:certifyHandler'](1)
    t.isTrue(anyNotify(f, 1, Sandbox.locale('certifications.grant_success_granter'), 'success'), 'the grant itself must still succeed with no AwardHandlerXP global defined at all')
end)

-- ======================================================================
-- FARM FIX: distinct-target certify farm (Config.CertifyMaxNewGranteesPerDay).
--
-- See server/certifications/'s own header comment right after
-- CertifyXpMintKey's declaration (search for "FARM FIX (audit finding,
-- this pass") for the full writeup this section proves out end to end,
-- against the REAL production file: CertifyXpMintCooldown above (per
-- (granter, target) PAIR, 24h) never caps how many DIFFERENT targets one
-- granter mints off in a day -- every pair used exactly once always pays,
-- whether the "different target" is a real alt character or (via
-- /k9certify's citizenid shape, which accepts ANY citizenid string) a plain typed
-- string that never corresponds to a real character at all. These tests
-- drive that exact command, through the REAL RegisterCommand entry point
-- captured in f.commands, never a local function directly.
-- ======================================================================

t.test('FARM FIX: a granter minting more DISTINCT new certifications than Config.CertifyMaxNewGranteesPerDay in one sitting is paid for exactly the cap, never more -- the farm loop is refused at the configured bound, not merely slowed', function()
    local f = newFixture({ certifyMaxNewGranteesPerDay = 3 })
    f.registerPlayer(1, 'G1', { name = 'police', isboss = true })
    f.setSource(1)

    -- Nine DISTINCT, entirely fabricated citizenids -- exactly the shape
    -- this fix closes. Each is a genuinely NEW (granter, target) pair, so
    -- CertifyXpMintCooldown ALONE would happily pay every single one.
    for i = 1, 9 do
        f.advanceTime(COOLDOWN_MS + 100)
        f.commands['k9certify'].fn(1, { 'FAKE' .. i, 'police' })
    end

    t.equals(#f.handlerXpAwardCalls, 3, 'exactly Config.CertifyMaxNewGranteesPerDay (3) of the nine distinct-target attempts may mint handlerCertifyK9 XP in one rolling day')
    for i = 1, 3 do
        t.equals(f.handlerXpAwardCalls[i][1], 'G1')
        t.equals(f.handlerXpAwardCalls[i][2], 'handlerCertifyK9')
    end
end)

t.test('FARM FIX: a certification refused its handlerCertifyK9 mint by the granter-level cap still succeeds as a REAL certification -- the cap gates only the XP reward, never the grant itself', function()
    local f = newFixture({ certifyMaxNewGranteesPerDay = 1 })
    f.registerPlayer(1, 'G1', { name = 'police', isboss = true })
    f.setSource(1)

    f.commands['k9certify'].fn(1, { 'FAKE1', 'police' })
    t.equals(#f.handlerXpAwardCalls, 1, 'sanity: the first mint pays')

    f.advanceTime(COOLDOWN_MS + 100)
    f.commands['k9certify'].fn(1, { 'FAKE2', 'police' })
    t.equals(#f.handlerXpAwardCalls, 1, 'the second, over-cap certification must NOT mint XP')

    local grantedFake2 = false
    for _, ev in ipairs(f.outboundEvents) do
        if ev[1] == 'qbx_k9unit:events:certificationGranted' and ev[2] == 'FAKE2' and ev[3] == 'police' then
            grantedFake2 = true
        end
    end
    t.isTrue(grantedFake2, 'the certification itself must still be granted for real (outbound event fired, DB row committed) even though the granter is already at their daily XP-mint cap -- gate the reward, never the action')
end)

t.test('FARM FIX: a real training officer certifying six genuine recruits in one evening is paid for every single one -- the shipped default cap has deliberate headroom above this exact legitimate case', function()
    local f = newFixture() -- opts.certifyMaxNewGranteesPerDay omitted -- production's own shipped default (8) applies
    f.registerPlayer(1, 'TRAINER', { name = 'police', isboss = true })
    f.setPed(1, 100, vec3(0, 0, 0), K9_HASH_SHEPHERD)
    f.setSource(1)

    for i = 1, 6 do
        f.registerPlayer(10 + i, 'RECRUIT' .. i, { name = 'police', grade = { level = 1 } })
        f.setPed(10 + i, 200 + i, vec3(0, 0, 0), K9_HASH_SHEPHERD)
        f.advanceTime(COOLDOWN_MS + 100)
        f.events['qbx_k9unit:server:certifyHandler'](10 + i)
    end

    t.equals(#f.handlerXpAwardCalls, 6, 'a genuine six-recruit onboarding evening must be paid IN FULL under the shipped default cap -- a cap that punishes this legitimate case would be worse than the farm it exists to stop')
end)

t.test('FARM FIX: the per-granter daily cap survives the granter disconnecting and reconnecting under a DIFFERENT, recycled server id -- it is keyed by citizenid, never by source', function()
    local f = newFixture({ certifyMaxNewGranteesPerDay = 1 })
    f.registerPlayer(1, 'G1', { name = 'police', isboss = true })
    f.setSource(1)
    f.commands['k9certify'].fn(1, { 'FAKE1', 'police' })
    t.equals(#f.handlerXpAwardCalls, 1)

    -- Genuine disconnect + reconnect under a DIFFERENT numeric source
    -- (FXServer recycles ids) -- the SAME citizenid, G1, logging back in.
    f.disconnectPlayer(1)
    f.registerPlayer(99, 'G1', { name = 'police', isboss = true })
    f.setSource(99)

    f.advanceTime(COOLDOWN_MS + 100)
    f.commands['k9certify'].fn(99, { 'FAKE2', 'police' })
    t.equals(#f.handlerXpAwardCalls, 1, "a resource restart-free relog cannot reset this citizenid's own daily cap -- it must still refuse the second distinct target")
end)

t.test('FARM FIX: a slot freed by rolling past its OWN 24-hour window frees up exactly one more granter-level mint, never the whole cap at once', function()
    local f = newFixture({ certifyMaxNewGranteesPerDay = 2 })
    f.registerPlayer(1, 'G1', { name = 'police', isboss = true })
    f.setSource(1)

    f.commands['k9certify'].fn(1, { 'FAKE1', 'police' })
    local slot1StampedAt = f.state.now
    t.equals(#f.handlerXpAwardCalls, 1)

    -- A full hour between slot 1's and slot 2's own stamps -- gives a wide,
    -- unambiguous margin between their two INDEPENDENT 24h rollover points
    -- for the assertions below (slot 1 rolls off a full hour before slot 2
    -- does, so "past slot 1's rollover" and "past slot 2's rollover" are
    -- never ambiguous instants).
    f.advanceTime(3600000)
    f.commands['k9certify'].fn(1, { 'FAKE2', 'police' })
    t.equals(#f.handlerXpAwardCalls, 2, "sanity: both of the cap's 2 slots are now used")

    f.advanceTime(COOLDOWN_MS + 100)
    f.commands['k9certify'].fn(1, { 'FAKE3', 'police' })
    t.equals(#f.handlerXpAwardCalls, 2, "still inside slot 1's own 24h window -- a 3rd distinct target must not pay yet")

    -- Advance to just past slot 1's OWN 24h mark, measured from when IT was
    -- stamped (not from "now") -- mirrors the existing CertifyXpMintCooldown
    -- "pays again once 24h has fully elapsed" test's own style. This lands
    -- comfortably short of slot 2's OWN rollover, a full hour further out.
    f.advanceTime((slot1StampedAt + CERTIFY_XP_MINT_COOLDOWN_MS + 500) - f.state.now)
    f.commands['k9certify'].fn(1, { 'FAKE4', 'police' })
    t.equals(#f.handlerXpAwardCalls, 3, "slot 1 has now rolled off its own 24h window -- exactly ONE more mint frees up")

    f.advanceTime(COOLDOWN_MS + 100)
    f.commands['k9certify'].fn(1, { 'FAKE5', 'police' })
    t.equals(#f.handlerXpAwardCalls, 3, "slot 2 has not rolled off yet (nearly a full hour still remains on it) -- a second extra mint must still be refused")
end)

t.test("FARM FIX: a NEW target refused its mint only by the granter-level cap is NOT also forced onto its own 24h pair-cooldown -- it can pay in full as soon as a granter slot frees up", function()
    local f = newFixture({ certifyMaxNewGranteesPerDay = 1 })
    f.registerPlayer(1, 'G1', { name = 'police', isboss = true })
    f.setSource(1)

    f.commands['k9certify'].fn(1, { 'FAKE1', 'police' }) -- uses the ONLY slot
    t.equals(#f.handlerXpAwardCalls, 1)

    f.advanceTime(COOLDOWN_MS + 100)
    f.commands['k9certify'].fn(1, { 'FAKE2', 'police' }) -- refused by the granter cap, not by its own pair-cooldown
    t.equals(#f.handlerXpAwardCalls, 1)

    -- Free the granter's own slot back up (FAKE1's stamp rolls off 24h
    -- later). If TryConsumeCertifyHandlerXpMint had also consumed FAKE2's
    -- OWN pair-cooldown on the earlier, denied attempt, this next call
    -- would incorrectly still be refused for a further 24h.
    f.advanceTime(CERTIFY_XP_MINT_COOLDOWN_MS)
    f.commands['k9certify'].fn(1, { 'FAKE2', 'police' })
    t.equals(#f.handlerXpAwardCalls, 2, "FAKE2 must pay the moment a granter slot is free again -- its own pair-cooldown must never have been consumed by the earlier, denied attempt")
end)

t.test('FARM FIX: Config.CertifyMaxNewGranteesPerDay -- CLAMP AND WARN on an invalid configured value (never assert), falling back to the built-in default', function()
    local f = newFixture({ certifyMaxNewGranteesPerDay = 0 })
    f.registerPlayer(1, 'G1', { name = 'police', isboss = true })
    f.setSource(1)

    for i = 1, 9 do
        f.advanceTime(COOLDOWN_MS + 100)
        f.commands['k9certify'].fn(1, { 'FAKE' .. i, 'police' })
    end
    t.equals(#f.handlerXpAwardCalls, 8, 'an invalid (zero) configured cap must fall back to the built-in default (8) -- never "always refuse" and never "never refuse"')

    local warned = false
    for _, line in ipairs(f.printLog) do
        if line:find('CertifyMaxNewGranteesPerDay', 1, true) then warned = true end
    end
    t.isTrue(warned, 'an invalid configured value must be warned about loudly, not silently substituted')
end)

t.test('FARM FIX: Config.CertifyMaxNewGranteesPerDay left UNSET (nil, an un-upgraded config) silently uses the built-in default -- no console warning for a value nobody was ever asked to set', function()
    local f = newFixture() -- opts.certifyMaxNewGranteesPerDay omitted -> nil
    f.registerPlayer(1, 'G1', { name = 'police', isboss = true })
    f.setSource(1)

    f.commands['k9certify'].fn(1, { 'FAKE1', 'police' })
    t.equals(#f.handlerXpAwardCalls, 1)

    for _, line in ipairs(f.printLog) do
        t.isFalse(line:find('CertifyMaxNewGranteesPerDay', 1, true) ~= nil, 'a missing config value must never itself trigger a console warning')
    end
end)

t.test('FARM FIX: a large, validly-configured Config.CertifyMaxNewGranteesPerDay is honored, not silently clamped down to the built-in fallback', function()
    local f = newFixture({ certifyMaxNewGranteesPerDay = 50 })
    f.registerPlayer(1, 'G1', { name = 'police', isboss = true })
    f.setSource(1)

    for i = 1, 20 do
        f.advanceTime(COOLDOWN_MS + 100)
        f.commands['k9certify'].fn(1, { 'FAKE' .. i, 'police' })
    end
    t.equals(#f.handlerXpAwardCalls, 20, 'a real, validly-configured cap of 50 must allow more than the built-in fallback of 8 to pay in one rolling day')
end)

t.test('GrantCertification: a target whose LIVE ped model is not a configured K9 model is rejected, even if job/proximity pass (Config.K9Appearance.requireK9ModelForRole opted in)', function()
    -- K9 role/model decoupling (coder-architect, server/appearance.lua):
    -- this check now only runs when explicitly opted in -- see this
    -- fixture's own Config.K9Appearance comment above.
    local f = newFixture({ k9Appearance = { requireK9ModelForRole = true } })
    f.registerPlayer(1, 'G1', { name = 'police', isboss = true })
    f.registerPlayer(2, 'T1', { name = 'police', grade = { level = 1 } })
    f.setPed(1, 100, vec3(0, 0, 0))
    f.setPed(2, 200, vec3(0, 0, 0), NON_K9_HASH)
    f.setSource(1)
    f.events['qbx_k9unit:server:certifyHandler'](2)
    t.isTrue(notifiedExactly(f, 1, localeWithPendingCertKeys('certifications.target_not_k9_model_hint'), 'error'))
end)

t.test('GrantCertification: an already-actively-certified target (existingId pre-check) is rejected as a no-op, never reaches the INSERT', function()
    local f = newFixture()
    f.registerPlayer(1, 'G1', { name = 'police', isboss = true })
    f.registerPlayer(2, 'T1', { name = 'police', grade = { level = 1 } })
    f.setPed(1, 100, vec3(0, 0, 0))
    f.setPed(2, 200, vec3(0, 0, 0), K9_HASH_SHEPHERD)
    f.mysql.scalar.await = function() return 55 end -- an active row already exists
    local insertCalled = false
    f.mysql.insert.await = function() insertCalled = true; return 1 end
    f.setSource(1)
    f.events['qbx_k9unit:server:certifyHandler'](2)
    t.isTrue(notifiedExactly(f, 1, localeWithPendingCertKeys('certifications.target_already_certified_hint'), 'inform'))
    t.isFalse(insertCalled)
end)

t.test('GrantCertification: full success path -- INSERT fires once, cache reflects the new active grant, both parties notified, outbound event fired, k9certified mirror set', function()
    local f = newFixture()
    f.registerPlayer(10, 'GRANTER', { name = 'police', isboss = true })
    local target = f.registerPlayer(20, 'TARGET', { name = 'police', grade = { level = 1 } })
    f.setPed(10, 1000, vec3(0, 0, 0))
    f.setPed(20, 2000, vec3(1, 0, 0), K9_HASH_SHEPHERD)

    local insertParams
    f.mysql.insert.await = function(_sql, params) insertParams = params; return 77 end
    -- The SAME MySQL.scalar.await backs both the pre-check (must see "no
    -- existing row" to let the insert proceed) and the post-insert
    -- RefreshCertificationCache re-query (must now see the row this INSERT
    -- just created) -- model that with a call counter rather than a single
    -- static return, or the cache would incorrectly re-read as inactive
    -- immediately after its own successful grant.
    local scalarCallCount = 0
    f.mysql.scalar.await = function()
        scalarCallCount = scalarCallCount + 1
        if scalarCallCount == 1 then return nil end -- pre-check: nothing active yet
        return 77 -- post-insert refresh: the row this INSERT just created
    end

    f.setSource(10)
    f.events['qbx_k9unit:server:certifyHandler'](20)

    -- WORKFLOW CLARITY (this pass, item 1): GrantCertification now sends
    -- the granter ONE additional "what's still missing" notice right after
    -- this one -- see the dedicated test below for that message's own
    -- content -- so the granter-facing success text is no longer
    -- necessarily the LAST entry; anyNotify (scans every entry) still
    -- proves it was sent, which is all this test itself is about.
    t.isTrue(anyNotify(f, 10, Sandbox.locale('certifications.grant_success_granter'), 'success'))
    t.isTrue(notifiedExactly(f, 20, Sandbox.locale('certifications.grant_success_target'), 'success'))
    t.equals(insertParams[1], 'TARGET')
    t.equals(insertParams[2], 'police')
    t.equals(insertParams[3], 'GRANTER')
    t.isTrue(f.env.HasK9Access(20), 'the cache must reflect the fresh grant immediately, without a separate PlayerLoaded/refresh')
    t.equals(target._metaWrites[#target._metaWrites].key, 'k9certified')
    t.isTrue(target._metaWrites[#target._metaWrites].value)

    local firedGrant = false
    for _, ev in ipairs(f.outboundEvents) do
        if ev[1] == 'qbx_k9unit:events:certificationGranted' and ev[2] == 'TARGET' and ev[3] == 'police' and ev[4] == 'GRANTER' then
            firedGrant = true
        end
    end
    t.isTrue(firedGrant, 'the outbound integration event must fire only after the INSERT + cache refresh already committed')
end)

-- ======================================================================
-- WORKFLOW CLARITY (this pass, item 1 -- "a certifier is never told what
-- is still missing"). SendGrantSuccessNextSteps -- every value it reports
-- is proven here to come from REAL STATE (the just-refreshed cache /
-- Config.FeatureControl.RequireGrant), never a hardcoded assumption.
-- ======================================================================

t.test('GrantCertification: WORKFLOW CLARITY -- success sends the granter a follow-up naming the real tier and specialization count, with no features requiring a grant on this server (the shipped default)', function()
    local f = newFixture()
    f.registerPlayer(10, 'GRANTER', { name = 'police', isboss = true })
    f.registerPlayer(20, 'TARGET', { name = 'police', grade = { level = 1 } })
    f.setPed(10, 1000, vec3(0, 0, 0))
    f.setPed(20, 2000, vec3(1, 0, 0), K9_HASH_SHEPHERD)
    f.mysql.scalar.await = function() return nil end
    f.mysql.insert.await = function() return 77 end

    f.setSource(10)
    f.events['qbx_k9unit:server:certifyHandler'](20)

    -- No Config.FeatureControl at all in this fixture (opts.featureControl
    -- absent) -- CountFeaturesRequiringGrant reads that as zero, so the
    -- NO-GRANTS-NEEDED variant is the one that must be sent, naming the
    -- REAL tier ('certified', the DB's own default -- read back from the
    -- cache this same call just populated, never hardcoded here).
    t.isTrue(notifiedExactly(f, 10, localeWithPendingCertKeys('certifications.grant_success_next_steps_no_grants', 'certified'), 'inform'))
end)

t.test('GrantCertification: WORKFLOW CLARITY -- when Config.FeatureControl.RequireGrant lists features, the follow-up names the REAL, live count, not a hardcoded number', function()
    local f = newFixture({ featureControl = { RequireGrant = { BiteAndHold = true, NonLethalTakedown = true, PropDragging = false } } })
    f.registerPlayer(10, 'GRANTER', { name = 'police', isboss = true })
    f.registerPlayer(20, 'TARGET', { name = 'police', grade = { level = 1 } })
    f.setPed(10, 1000, vec3(0, 0, 0))
    f.setPed(20, 2000, vec3(1, 0, 0), K9_HASH_SHEPHERD)
    f.mysql.scalar.await = function() return nil end
    f.mysql.insert.await = function() return 77 end

    f.setSource(10)
    f.events['qbx_k9unit:server:certifyHandler'](20)

    -- Exactly 2 of the 3 entries are `true` (PropDragging is `false`, and
    -- must NOT be counted) -- proves the count is computed live from the
    -- actual table shape, not merely "the table is non-empty".
    t.isTrue(notifiedExactly(f, 10, localeWithPendingCertKeys('certifications.grant_success_next_steps', 'certified', 2), 'inform'))
end)

t.test('GrantCertificationOffline: WORKFLOW CLARITY -- the same follow-up is sent on the offline grant path too, computed from the same just-refreshed real state', function()
    local f = newFixture({ featureControl = { RequireGrant = { FindAlerts = true } } })
    f.registerPlayer(1, 'G1', { name = 'police', isboss = true })
    f.mysql.scalar.await = function() return nil end
    f.mysql.insert.await = function() return 5 end

    f.commands['k9certify'].fn(1, { 'OFFLINE_CIT', 'police' })

    t.isTrue(notifiedExactly(f, 1, localeWithPendingCertKeys('certifications.grant_success_next_steps', 'certified', 1), 'inform'))
end)

-- ======================================================================
-- SECURITY FIX (coder-security, this pass -- "prove role and model are
-- genuinely separate, everywhere" audit): ApplyK9AppearanceOnGrant/
-- MaybeRevertK9Appearance (server/appearance.lua) were documented, in that
-- file's own header, as being called from THIS file's grant/revoke paths --
-- but were never actually wired in anywhere here until this pass. See
-- certifications.lua's own newly-added FILE-TO-FILE CONTRACT entry for the
-- full writeup. These tests pin the new wiring at every call site this pass
-- touched.
-- ======================================================================

-- CERTIFY AS HANDLER OR AS K9 (the owner's rework pass). Certifying used
-- to ALWAYS turn the person into Config.Peds[1] -- so every new HANDLER
-- was turned into a dog. Now: no breed = a handler, looks untouched; a
-- breed = certified as the K9 AND turned into that breed, one step.

t.test('CERTIFY AS HANDLER: a plain certify (walk-up option / chat command, no breed) certifies them and NEVER changes how they look', function()
    local f = newFixture({ k9Appearance = { applyPedModelOnCertify = true } })
    f.registerPlayer(10, 'GRANTER', { name = 'police', isboss = true })
    f.registerPlayer(20, 'TARGET', { name = 'police', grade = { level = 1 } })
    f.setPed(10, 1000, vec3(0, 0, 0))
    f.setPed(20, 2000, vec3(1, 0, 0), NON_K9_HASH)

    local scalarCallCount = 0
    f.mysql.scalar.await = function()
        scalarCallCount = scalarCallCount + 1
        if scalarCallCount == 1 then return nil end
        return 77
    end

    f.setSource(10)
    f.events['qbx_k9unit:server:certifyHandler'](20)

    t.isTrue(f.env.HasK9Access(20), 'the handler is certified')
    t.equals(#f.appearanceApplyCalls, 0, 'a handler must not be turned into a dog by being certified')
end)

t.test('CERTIFY AS K9: certifying from the tablet with a breed picked certifies them AND turns them into exactly that breed, in one step', function()
    local f = newFixture({ k9Appearance = { applyPedModelOnCertify = true }, features = { CommandTablet = true } })
    f.registerPlayer(10, 'GRANTER', { name = 'police', isboss = true })
    f.registerPlayer(20, 'TARGET', { name = 'police', grade = { level = 1 } })
    f.setPed(10, 1000, vec3(0, 0, 0))
    f.setPed(20, 2000, vec3(1, 0, 0), NON_K9_HASH)

    local scalarCallCount = 0
    f.mysql.scalar.await = function()
        scalarCallCount = scalarCallCount + 1
        if scalarCallCount == 1 then return nil end
        return 77
    end

    local result = f.callbacks['qbx_k9unit:server:tabletCertify'](10, 'TARGET', 'police', 'a_c_rottweiler')

    t.isTrue(result.ok)
    t.isTrue(f.env.HasK9Access(20))
    t.equals(#f.appearanceApplyCalls, 1)
    t.equals(f.appearanceApplyCalls[1][1], 'TARGET')
    t.equals(f.appearanceApplyCalls[1][2], 'GRANTER')
    t.equals(f.appearanceApplyCalls[1][3], 'a_c_rottweiler', 'the breed the certifier picked, not a default')
end)

t.test('CERTIFY AS K9: a breed that is not in Config.Peds is refused before anything is written -- never quietly certified as a handler instead', function()
    local f = newFixture({ k9Appearance = { applyPedModelOnCertify = true }, features = { CommandTablet = true } })
    f.registerPlayer(10, 'GRANTER', { name = 'police', isboss = true })
    f.registerPlayer(20, 'TARGET', { name = 'police', grade = { level = 1 } })
    f.setPed(10, 1000, vec3(0, 0, 0))
    f.setPed(20, 2000, vec3(1, 0, 0), NON_K9_HASH)
    local inserted = false
    f.mysql.insert.await = function() inserted = true; return 1 end

    for _, bad in ipairs({ 'a_c_pig', '', 42 }) do
        local result = f.callbacks['qbx_k9unit:server:tabletCertify'](10, 'TARGET', 'police', bad)
        t.isFalse(result.ok)
        t.equals(result.error, 'invalid_model', tostring(bad))
    end
    t.isFalse(inserted)
    t.equals(#f.appearanceApplyCalls, 0)
end)

t.test('CERTIFY AS K9: from the tablet with NO breed (Handler picked) behaves exactly like a handler certify -- looks unchanged', function()
    local f = newFixture({ k9Appearance = { applyPedModelOnCertify = true }, features = { CommandTablet = true } })
    f.registerPlayer(10, 'GRANTER', { name = 'police', isboss = true })
    f.registerPlayer(20, 'TARGET', { name = 'police', grade = { level = 1 } })
    f.setPed(10, 1000, vec3(0, 0, 0))
    f.setPed(20, 2000, vec3(1, 0, 0), NON_K9_HASH)

    local result = f.callbacks['qbx_k9unit:server:tabletCertify'](10, 'TARGET', 'police', nil)
    t.isTrue(result.ok)
    t.equals(#f.appearanceApplyCalls, 0)
end)

t.test('CERTIFY AS K9: a target on an ORDINARY HUMAN BODY is certified AND the breed is applied -- role and model are genuinely independent', function()
    -- Config.K9Appearance.requireK9ModelForRole is absent (shipped default,
    -- false) -- the target's LIVE ped model is deliberately NOT a
    -- configured K9 model at all, proving the grant (and its automatic
    -- appearance-apply side effect) is not gated on, or blocked by, the
    -- target's current body.
    local f = newFixture({ k9Appearance = { applyPedModelOnCertify = true } })
    f.registerPlayer(10, 'GRANTER', { name = 'police', isboss = true })
    f.registerPlayer(20, 'TARGET', { name = 'police', grade = { level = 1 } })
    f.setPed(10, 1000, vec3(0, 0, 0))
    f.setPed(20, 2000, vec3(1, 0, 0), NON_K9_HASH) -- an ordinary human body, not a Config.Peds model

    -- Same "pre-check sees nothing, post-insert refresh sees the row this
    -- INSERT just created" scalar-call-count stub as the pre-existing "full
    -- success path" test above -- otherwise RefreshCertificationCache's own
    -- post-insert re-query would (incorrectly, only for this stub's sake)
    -- read back as inactive and HasK9Access(20) would be a false negative
    -- unrelated to the appearance wiring this test actually exercises.
    local scalarCallCount = 0
    f.mysql.scalar.await = function()
        scalarCallCount = scalarCallCount + 1
        if scalarCallCount == 1 then return nil end
        return 77
    end

    f.setSource(10)
    t.isTrue(f.env.K9Cert.GrantCertification(10, 20, 'a_c_shepherd'))

    t.isTrue(f.env.HasK9Access(20), 'the ROLE must be granted regardless of the target\'s CURRENT model')
    t.equals(#f.appearanceApplyCalls, 1, 'the chosen breed is applied to a human-bodied target -- that is what turns them into the dog, not a check that refuses because they are not one yet')
    t.equals(f.appearanceApplyCalls[1][1], 'TARGET')
    t.equals(f.appearanceApplyCalls[1][3], 'a_c_shepherd')
end)

t.test('GrantCertification: with Config.K9Appearance.applyPedModelOnCertify explicitly false, the appearance-apply hook is never called -- even with a breed picked', function()
    local f = newFixture({ k9Appearance = { applyPedModelOnCertify = false } })
    f.registerPlayer(10, 'GRANTER', { name = 'police', isboss = true })
    f.registerPlayer(20, 'TARGET', { name = 'police', grade = { level = 1 } })
    f.setPed(10, 1000, vec3(0, 0, 0))
    f.setPed(20, 2000, vec3(1, 0, 0), K9_HASH_SHEPHERD)

    local scalarCallCount = 0
    f.mysql.scalar.await = function()
        scalarCallCount = scalarCallCount + 1
        if scalarCallCount == 1 then return nil end
        return 77
    end

    f.setSource(10)
    f.env.K9Cert.GrantCertification(10, 20, 'a_c_shepherd')

    t.isTrue(f.env.HasK9Access(20), 'the role itself must still be granted -- only the automatic appearance side effect is opted out')
    t.equals(#f.appearanceApplyCalls, 0)
end)

t.test('GrantCertification: APPEARANCE FIX -- with Config.K9Appearance entirely absent (a config predating this feature), the appearance-apply hook is never called -- no crash, no behavior change from before this pass', function()
    local f = newFixture() -- no k9Appearance opt at all -- Config.K9Appearance is nil
    f.registerPlayer(10, 'GRANTER', { name = 'police', isboss = true })
    f.registerPlayer(20, 'TARGET', { name = 'police', grade = { level = 1 } })
    f.setPed(10, 1000, vec3(0, 0, 0))
    f.setPed(20, 2000, vec3(1, 0, 0), K9_HASH_SHEPHERD)

    local scalarCallCount = 0
    f.mysql.scalar.await = function()
        scalarCallCount = scalarCallCount + 1
        if scalarCallCount == 1 then return nil end
        return 77
    end

    f.setSource(10)
    f.events['qbx_k9unit:server:certifyHandler'](20)

    t.isTrue(f.env.HasK9Access(20))
    t.equals(#f.appearanceApplyCalls, 0)
end)

t.test('GrantCertification: APPEARANCE FIX -- the runtime existence guard genuinely tolerates ApplyK9AppearanceOnGrant being entirely absent (server/appearance.lua not loaded)', function()
    local f = newFixture({ k9Appearance = { applyPedModelOnCertify = true }, includeAppearanceHook = false })
    f.registerPlayer(10, 'GRANTER', { name = 'police', isboss = true })
    f.registerPlayer(20, 'TARGET', { name = 'police', grade = { level = 1 } })
    f.setPed(10, 1000, vec3(0, 0, 0))
    f.setPed(20, 2000, vec3(1, 0, 0), K9_HASH_SHEPHERD)

    local scalarCallCount = 0
    f.mysql.scalar.await = function()
        scalarCallCount = scalarCallCount + 1
        if scalarCallCount == 1 then return nil end
        return 77
    end

    f.setSource(10)
    local ok = pcall(f.env.K9Cert.GrantCertification, 10, 20, 'a_c_shepherd')

    t.isTrue(ok, 'a missing soft dependency must never throw out of the grant path')
    t.isTrue(f.env.HasK9Access(20), 'the grant itself must still succeed with server/appearance.lua entirely absent')
end)

t.test('CERTIFY AS HANDLER (offline): /k9certify [citizenid] [job] certifies an offline handler and never changes how they look', function()
    local f = newFixture({ k9Appearance = { applyPedModelOnCertify = true } })
    f.registerPlayer(10, 'GRANTER', { name = 'police', isboss = true })
    -- TARGET intentionally never registered -- genuinely offline.
    local inserted = false
    f.mysql.insert.await = function() inserted = true; return 1 end

    f.commands['k9certify'].fn(10, { 'TARGET', 'police' })

    t.isTrue(inserted, 'the certification is written')
    t.equals(#f.appearanceApplyCalls, 0)
end)

t.test('CERTIFY AS K9 (offline): from the tablet with a breed picked, an offline target is certified and the breed is applied for their next login', function()
    local f = newFixture({ k9Appearance = { applyPedModelOnCertify = true }, features = { CommandTablet = true } })
    f.registerPlayer(10, 'GRANTER', { name = 'police', isboss = true })

    local result = f.callbacks['qbx_k9unit:server:tabletCertify'](10, 'TARGET', 'police', 'a_c_rottweiler')

    t.isTrue(result.ok)
    t.equals(#f.appearanceApplyCalls, 1)
    t.equals(f.appearanceApplyCalls[1][1], 'TARGET')
    t.equals(f.appearanceApplyCalls[1][2], 'GRANTER')
    t.equals(f.appearanceApplyCalls[1][3], 'a_c_rottweiler')
end)

-- ----------------------------------------------------------------------
-- CertificationExpiry (Config.Features.CertificationExpiry) -- traced
-- end-to-end from GrantCertification's own INSERT through to the cache,
-- since this feature's own header claims "a brand-new grant starts its own
-- expiry clock immediately, but ONLY when an operator has explicitly opted
-- in", and (prior to this pass) NOTHING in this file's own test suite ever
-- exercised GrantCertification with the flag on at all -- every existing
-- EXPIRY-tagged test above drives RefreshCertificationCache/
-- TickCertificationExpiryWarnings/RenewCertification directly, never a real
-- grant through the flag. A grep for "CertificationExpiry" finding 40+
-- hits in this file is not evidence this path was ever actually run.
-- ----------------------------------------------------------------------

t.test('GrantCertification: EXPIRY -- when the feature is enabled, a brand-new grant INSERT carries Config.CertificationExpiryDays, and the resulting cache reflects a real expiresAtUnix', function()
    local f = newFixture({ features = { CertificationExpiry = true }, expiryDays = 90 })
    f.registerPlayer(10, 'GRANTER', { name = 'police', isboss = true })
    f.registerPlayer(20, 'TARGET', { name = 'police', grade = { level = 1 } })
    f.setPed(10, 1000, vec3(0, 0, 0))
    f.setPed(20, 2000, vec3(1, 0, 0), K9_HASH_SHEPHERD)

    local insertParams
    f.mysql.insert.await = function(_sql, params) insertParams = params; return 88 end
    local scalarCallCount = 0
    f.mysql.scalar.await = function()
        scalarCallCount = scalarCallCount + 1
        if scalarCallCount == 1 then return nil end -- pre-check: nothing active yet
        return 88 -- post-insert refresh: the row this INSERT just created
    end
    -- Models what a real DATE_ADD(NOW(), INTERVAL 90 DAY) INSERT would read
    -- back as, through RefreshCertificationCache's own follow-up metadata
    -- query -- this file never computes the expiry date itself in Lua (see
    -- header "EXPIRY" item 3), so this test does not either.
    f.mysql.single.await = function() return { tier = 'certified', expires_at_unix = 1700000000 + 90 * 86400 } end

    f.setSource(10)
    f.events['qbx_k9unit:server:certifyHandler'](20)

    t.equals(insertParams[1], 'TARGET')
    t.equals(insertParams[2], 'police')
    t.equals(insertParams[3], 'GRANTER')
    t.equals(insertParams[4], 90, 'the INSERT must carry the configured expiry window so the DB computes DATE_ADD(NOW(), INTERVAL ? DAY), never a Lua-computed date')
    t.isTrue(f.env.HasK9Access(20), 'a freshly-granted, not-yet-expired certification must still grant access')
    t.isTrue(notifiedExactly(f, 20, Sandbox.locale('certifications.grant_success_target'), 'success'))
end)

t.test('GrantCertification: EXPIRY -- with the feature OFF (default, unset Config.Features), a brand-new grant INSERT carries no fourth (expiry-days) argument at all', function()
    local f = newFixture() -- Config.Features absent -- the shipped default
    f.registerPlayer(10, 'GRANTER', { name = 'police', isboss = true })
    f.registerPlayer(20, 'TARGET', { name = 'police', grade = { level = 1 } })
    f.setPed(10, 1000, vec3(0, 0, 0))
    f.setPed(20, 2000, vec3(1, 0, 0), K9_HASH_SHEPHERD)

    local insertParams
    f.mysql.insert.await = function(_sql, params) insertParams = params; return 89 end
    local scalarCallCount = 0
    f.mysql.scalar.await = function()
        scalarCallCount = scalarCallCount + 1
        if scalarCallCount == 1 then return nil end
        return 89
    end

    f.setSource(10)
    f.events['qbx_k9unit:server:certifyHandler'](20)

    t.equals(#insertParams, 3, 'the pre-expiry 3-argument INSERT shape must stay byte-identical on a server that has not opted in')
end)

t.test('GrantCertification: EXPIRY BUGFIX -- re-certifying a citizenid whose PREVIOUS certification already lapsed this session re-arms the warned/lapsed flags for the brand-new certification', function()
    local f = newFixture({ features = { CertificationExpiry = true }, expiryDays = 90 })
    f.registerPlayer(10, 'GRANTER', { name = 'police', isboss = true })
    f.registerPlayer(20, 'TARGET', { name = 'police', grade = { level = 1 } })
    f.setPed(10, 1010, vec3(0, 0, 0))
    f.setPed(20, 1020, vec3(0, 0, 0), K9_HASH_SHEPHERD)

    -- TARGET already holds an active certification that has already lapsed
    -- (a real, ordinary paperwork lapse this feature's own header describes
    -- as a normal, non-disciplinary event).
    f.mysql.scalar.await = function() return 5 end
    f.mysql.single.await = function() return { tier = 'certified', expires_at_unix = 1699999999 } end -- lapsed
    f.env.RefreshCertificationCache('TARGET', 'police')

    f.threadRunner.step()
    f.threadRunner.step()
    t.isTrue(notifiedExactly(f, 20, Sandbox.locale('certifications.expiry_lapsed_notice'), 'error'), 'sanity: lapsed notice sent once for the OLD certification')

    -- The lapsed certification is manually revoked, freeing (TARGET,
    -- police) for a brand-new grant -- exactly the ordinary "paperwork
    -- lapsed, so decertify and recertify" sequence a real department would
    -- follow rather than leaving a permanently-lapsed row active forever.
    f.mysql.update.await = function() return 1 end
    f.setSource(10)
    f.events['qbx_k9unit:server:revokeHandler'](20)
    t.isTrue(notifiedExactly(f, 10, Sandbox.locale('certifications.revoke_success'), 'success'), 'sanity: revoke succeeded')

    f.advanceTime(COOLDOWN_MS + 1) -- clear CERTIFY_ACTION_COOLDOWN_MS before the next certify action from the same granter

    -- Brand-new grant, with its own brand-new far-future expiry.
    local scalarCallCount = 0
    f.mysql.scalar.await = function()
        scalarCallCount = scalarCallCount + 1
        if scalarCallCount == 1 then return nil end -- pre-check: the revoke above freed this row
        return 99 -- post-insert refresh: the row this INSERT just created
    end
    f.mysql.insert.await = function() return 99 end
    f.mysql.single.await = function() return { tier = 'certified', expires_at_unix = 1707776000 } end -- new cert, ~90 days out
    f.events['qbx_k9unit:server:certifyHandler'](20)
    t.isTrue(notifiedExactly(f, 20, Sandbox.locale('certifications.grant_success_target'), 'success'), 'sanity: re-grant succeeded')

    -- Simulate the NEW certification eventually lapsing too, in this SAME
    -- session. WITHOUT the fix, ExpiryLapsedNotified['TARGET'] would still
    -- be true from the OLD (now-revoked) certification's own lapse above,
    -- and this genuinely NEW lapse -- under a completely different
    -- certification row -- would be silently swallowed until TARGET
    -- disconnects and reconnects.
    f.mysql.single.await = function() return { tier = 'certified', expires_at_unix = 1699999999 } end
    f.env.RefreshCertificationCache('TARGET', 'police')
    f.threadRunner.step()

    local lapsedCount = 0
    for _, e in ipairs(f.notifyLog) do
        if e.source == 20 and e.message == Sandbox.locale('certifications.expiry_lapsed_notice') then lapsedCount = lapsedCount + 1 end
    end
    t.equals(lapsedCount, 2, 'a brand-new certification must be able to announce its OWN lapse even though the same citizenid was already lapsed-notified once this session under a DIFFERENT, now-revoked certification')
end)

t.test('GrantCertification: a duplicate-key error thrown by the INSERT (DB backstop, uq_one_active_cert_per_job) is treated as the same "already certified" no-op, not a hard error', function()
    local f = newFixture()
    f.registerPlayer(1, 'G1', { name = 'police', isboss = true })
    f.registerPlayer(2, 'T1', { name = 'police', grade = { level = 1 } })
    f.setPed(1, 100, vec3(0, 0, 0))
    f.setPed(2, 200, vec3(0, 0, 0), K9_HASH_SHEPHERD)
    f.mysql.insert.await = function() error({ errno = 1062, message = 'Duplicate entry' }) end
    f.setSource(1)
    f.events['qbx_k9unit:server:certifyHandler'](2)
    t.isTrue(notifiedExactly(f, 1, localeWithPendingCertKeys('certifications.target_already_certified_hint'), 'inform'))
end)

-- ----------------------------------------------------------------------
-- GrantInFlight concurrency lock -- the highest-value case in this file.
-- GrantCertification's check-then-INSERT sequence spans two MySQL awaits,
-- each of which yields the real FXServer coroutine. Two coroutines below
-- model two truly overlapping grant attempts for the SAME (citizenid, job)
-- through a MySQL stub that genuinely yields via coroutine.yield(), proving
-- the lock (not test-harness luck) is what prevents a double-insert.
-- ----------------------------------------------------------------------

t.test('GrantCertification: LOAD-BEARING -- two overlapping grants for the SAME (citizenid, job), interleaved through a yielding MySQL stub, produce exactly ONE insert', function()
    local f = newFixture()
    f.registerPlayer(10, 'GRANTER-A', { name = 'police', isboss = true })
    f.registerPlayer(11, 'GRANTER-B', { name = 'police', isboss = true })
    f.registerPlayer(20, 'TARGET-SHARED', { name = 'police', grade = { level = 1 } })
    f.setPed(10, 1010, vec3(0, 0, 0))
    f.setPed(11, 1011, vec3(0, 0, 0))
    f.setPed(20, 1020, vec3(0, 0, 0), K9_HASH_SHEPHERD)

    local insertCount = 0
    local scalarCallCount = 0
    -- Every MySQL.scalar.await call (both the pre-check inside
    -- doGrantInsert AND the post-insert RefreshCertificationCache call)
    -- yields the calling coroutine here, modeling a real network round
    -- trip -- exactly the window the old code's TOCTOU bug lived in.
    f.mysql.scalar.await = function(_sql, _params)
        scalarCallCount = scalarCallCount + 1
        coroutine.yield()
        return nil -- no pre-existing active row, in every call, for this test
    end
    f.mysql.insert.await = function(_sql, _params)
        insertCount = insertCount + 1
        return insertCount
    end

    local coA = coroutine.create(function()
        f.setSource(10)
        f.events['qbx_k9unit:server:certifyHandler'](20)
    end)
    local coB = coroutine.create(function()
        f.setSource(11)
        f.events['qbx_k9unit:server:certifyHandler'](20)
    end)

    -- Run A up to its FIRST yield -- this is the point in real FXServer
    -- where A has already synchronously set GrantInFlight[lockKey] = true
    -- and is now suspended awaiting the pre-check SELECT.
    local okA1, errA1 = coroutine.resume(coA)
    t.isTrue(okA1, tostring(errA1))
    t.equals(coroutine.status(coA), 'suspended', 'coroutine A must be paused mid-flight at the MySQL pre-check await')

    -- Now let B run to completion. If the lock did not exist, B would reach
    -- its own pre-check SELECT (also stubbed to yield) and this resume
    -- would leave B suspended too, mirroring the exact double-insert bug
    -- this lock fixes. Because GrantInFlight[lockKey] was already set
    -- (synchronously, before A's own first yield), B must instead observe
    -- the lock and bail out BEFORE ever calling MySQL at all.
    local okB, errB = coroutine.resume(coB)
    t.isTrue(okB, tostring(errB))
    t.equals(coroutine.status(coB), 'dead', 'B must run to completion in a single resume -- proving it never reached (and therefore never yielded at) a MySQL call')

    -- Drain every remaining yield in A (pre-check, then the post-insert
    -- RefreshCertificationCache re-query) until it finishes.
    while coroutine.status(coA) ~= 'dead' do
        local okA, errA = coroutine.resume(coA)
        t.isTrue(okA, tostring(errA))
    end

    t.equals(insertCount, 1, 'exactly one INSERT must occur despite the interleaved concurrent attempt')
    t.equals(scalarCallCount, 2, 'both MySQL.scalar.await calls that DID happen must both be attributable to A alone (its own pre-check + its own post-insert cache refresh) -- B made zero MySQL calls')
    t.isTrue(anyNotify(f, 10, Sandbox.locale('certifications.grant_success_granter'), 'success'), 'the winner (A) must see a real success')
    t.isTrue(notifiedExactly(f, 11, localeWithPendingCertKeys('certifications.target_already_certified_hint'), 'inform'), 'the loser (B) must see the same "already certified" no-op a real post-facto duplicate would -- not an error, not silence')
end)

t.test('GrantCertification: LOAD-BEARING -- GrantInFlight is released even when the critical section throws an unexpected error, so a thrown error can never permanently block future grants for that (citizenid, job)', function()
    local f = newFixture()
    f.registerPlayer(10, 'GRANTER-X', { name = 'police', isboss = true })
    f.registerPlayer(20, 'TARGET-X', { name = 'police', grade = { level = 1 } })
    f.setPed(10, 1110, vec3(0, 0, 0))
    f.setPed(20, 1120, vec3(0, 0, 0), K9_HASH_SHEPHERD)

    local scalarShouldThrow = true
    f.mysql.scalar.await = function(_sql, _params)
        if scalarShouldThrow then
            error('simulated connection drop mid-flight')
        end
        return nil
    end
    local insertCount = 0
    f.mysql.insert.await = function() insertCount = insertCount + 1; return insertCount end

    f.setSource(10)
    f.events['qbx_k9unit:server:certifyHandler'](20) -- errors inside doGrantInsert -> pcall catches it -> lock must still be released

    t.isTrue(notifiedExactly(f, 10, Sandbox.locale('certifications.grant_error'), 'error'), 'the caller must see the generic grant_error notification, not a raw Lua error')
    t.equals(insertCount, 0, 'the failed attempt must never have reached the INSERT')

    -- Advance past the certifier-action cooldown (same granter source) and
    -- retry the SAME (citizenid, job) with a now-working MySQL stub. If the
    -- lock had leaked (never released on the error path), this retry would
    -- be rejected as "already in flight" and insertCount would stay 0
    -- forever -- exactly the permanent-un-grantable-target regression this
    -- test guards against.
    f.advanceTime(COOLDOWN_MS + 1)
    scalarShouldThrow = false
    f.events['qbx_k9unit:server:certifyHandler'](20)

    t.equals(insertCount, 1, 'the retry must succeed -- proving GrantInFlight[lockKey] was genuinely released after the thrown error, not left held')
    t.isTrue(anyNotify(f, 10, Sandbox.locale('certifications.grant_success_granter'), 'success'), 'the retry must be a real success, not another "already certified"/still-locked rejection')
end)

-- ======================================================================
-- RevokeCertification (online-capable, numeric targetServerId path) --
-- reached via the captured net event, same ambient-source convention as
-- GrantCertification above.
-- ======================================================================

t.test('RevokeCertification: full online success path -- UPDATE fires with the granter\'s citizenid, cache flips to inactive, leash force-detached, outbound event fired', function()
    local f = newFixture()
    f.registerPlayer(10, 'REVOKER', { name = 'police', isboss = true })
    local target = f.registerPlayer(20, 'REVOKEE', { name = 'police', grade = { level = 1 } })
    f.setPed(10, 1010, vec3(0, 0, 0))
    f.setPed(20, 1020, vec3(0, 0, 0))
    f.mysql.scalar.await = function() return 5 end -- seed an active cert first
    f.env.RefreshCertificationCache('REVOKEE', 'police')
    t.isTrue(f.env.HasK9Access(20), 'sanity: the target really is certified before the revoke')

    local updateParams
    f.mysql.update.await = function(_sql, params) updateParams = params; return 1 end
    -- After the revoke, RefreshCertificationCache re-queries -- simulate the
    -- row now being inactive.
    f.mysql.scalar.await = function() return nil end

    f.setSource(10)
    f.events['qbx_k9unit:server:revokeHandler'](20)

    -- CERTIFICATION DEPTH (this pass, Part A §2): `revoke_reason` (nil,
    -- since no reason was passed) is now bound as params[2], shifting
    -- citizenid/job to params[3]/[4] -- see RevokeCertification's own
    -- comment on its UPDATE statement.
    t.equals(updateParams[1], 'REVOKER')
    t.isNil(updateParams[2])
    t.equals(updateParams[3], 'REVOKEE')
    t.equals(updateParams[4], 'police')
    t.isFalse(f.env.HasK9Access(20), 'access must be gone immediately after an online revoke')
    t.isTrue(notifiedExactly(f, 10, Sandbox.locale('certifications.revoke_success'), 'success'))
    t.isTrue(notifiedExactly(f, 20, Sandbox.locale('certifications.revoked_notice_online'), 'error'))
    t.equals(target._metaWrites[#target._metaWrites].value, false)
    t.equals(f.leashDetachCalls[#f.leashDetachCalls][1], 20)
    t.equals(f.leashDetachCalls[#f.leashDetachCalls][2], 'certification_revoked')

    local fired = false
    for _, ev in ipairs(f.outboundEvents) do
        if ev[1] == 'qbx_k9unit:events:certificationRevoked' and ev[2] == 'REVOKEE' and ev[3] == 'police' and ev[4] == 'manual' then fired = true end
    end
    t.isTrue(fired)
end)

t.test('RevokeCertification: WORKFLOW CLARITY -- when the granter supplies a reason, the revoked handler is told what it was, not just that they were revoked', function()
    local f = newFixture()
    f.registerPlayer(10, 'REVOKER', { name = 'police', isboss = true })
    f.registerPlayer(20, 'REVOKEE', { name = 'police', grade = { level = 1 } })
    f.setPed(10, 1010, vec3(0, 0, 0))
    f.setPed(20, 1020, vec3(0, 0, 0))
    f.mysql.update.await = function() return 1 end
    f.mysql.scalar.await = function() return nil end

    f.setSource(10)
    f.commands['k9decertify'].fn(10, { '20', 'disciplinary' })

    t.isTrue(notifiedExactly(f, 20, localeWithPendingCertKeys('certifications.revoked_notice_online_with_reason', 'disciplinary'), 'error'))
end)

-- ======================================================================
-- SECURITY FIX (coder-security, this pass) -- MaybeRevertK9Appearance was
-- documented (server/appearance.lua's own header) as being called from this
-- file's five "K9-role access just, provably, ended" sites, but never
-- actually was. MID-STATE REVERSION MATTERS HERE: without this call, a
-- citizenid whose ONLY route to the role was this exact certification (no
-- separate 'k9.access' permission grant) would keep the K9 ped model
-- forever after being revoked -- stranded, per this pass's own brief.
-- ======================================================================

t.test('RevokeCertification: APPEARANCE FIX -- a full online revoke calls MaybeRevertK9Appearance(targetCitizenid), so a citizenid whose ONLY route to the role was this certification is never stranded on the K9 model', function()
    local f = newFixture()
    f.registerPlayer(10, 'REVOKER', { name = 'police', isboss = true })
    f.registerPlayer(20, 'REVOKEE', { name = 'police', grade = { level = 1 } })
    f.setPed(10, 1010, vec3(0, 0, 0))
    f.setPed(20, 1020, vec3(0, 0, 0))
    f.mysql.scalar.await = function() return 5 end
    f.env.RefreshCertificationCache('REVOKEE', 'police')

    f.mysql.update.await = function() return 1 end
    f.mysql.scalar.await = function() return nil end

    f.setSource(10)
    f.events['qbx_k9unit:server:revokeHandler'](20)

    t.equals(#f.appearanceRevertCalls, 1)
    t.equals(f.appearanceRevertCalls[1], 'REVOKEE')
end)

t.test('RevokeCertification: APPEARANCE FIX -- the runtime existence guard genuinely tolerates MaybeRevertK9Appearance being entirely absent (server/appearance.lua not loaded)', function()
    local f = newFixture({ includeAppearanceHook = false })
    f.registerPlayer(10, 'REVOKER', { name = 'police', isboss = true })
    f.registerPlayer(20, 'REVOKEE', { name = 'police', grade = { level = 1 } })
    f.setPed(10, 1010, vec3(0, 0, 0))
    f.setPed(20, 1020, vec3(0, 0, 0))
    f.mysql.scalar.await = function() return 5 end
    f.env.RefreshCertificationCache('REVOKEE', 'police')

    f.mysql.update.await = function() return 1 end
    f.mysql.scalar.await = function() return nil end

    f.setSource(10)
    local ok = pcall(f.events['qbx_k9unit:server:revokeHandler'], 20)

    t.isTrue(ok, 'a missing soft dependency must never throw out of the revoke path')
    t.isFalse(f.env.HasK9Access(20), 'the revoke itself must still succeed with server/appearance.lua entirely absent')
end)

t.test('RevokeCertificationOffline: APPEARANCE FIX -- an offline revoke (/k9decertifyoffline) also calls MaybeRevertK9Appearance(citizenid)', function()
    local f = newFixture()
    f.registerPlayer(10, 'REVOKER', { name = 'police', isboss = true })
    -- REVOKEE intentionally never registered -- genuinely offline.
    f.mysql.update.await = function() return 1 end
    f.mysql.scalar.await = function() return nil end

    f.commands['k9decertify'].fn(10, { 'REVOKEE', 'police' })

    t.equals(#f.appearanceRevertCalls, 1)
    t.equals(f.appearanceRevertCalls[1], 'REVOKEE')
end)

t.test('RevokeCertification: a target holding no active cert for that department is a distinguishable no-op, not a silent success', function()
    local f = newFixture()
    f.registerPlayer(10, 'REVOKER', { name = 'police', isboss = true })
    f.registerPlayer(20, 'REVOKEE', { name = 'police', grade = { level = 1 } })
    f.setPed(10, 1010, vec3(0, 0, 0))
    f.setPed(20, 1020, vec3(0, 0, 0))
    f.mysql.update.await = function() return 0 end -- WHERE ... active = 1 matched nothing

    f.setSource(10)
    f.events['qbx_k9unit:server:revokeHandler'](20)

    t.isTrue(notifiedExactly(f, 10, Sandbox.locale('certifications.target_not_actively_certified'), 'inform'))
    t.equals(#f.outboundEvents, 0, 'no outbound event must fire when nothing actually flipped')
end)

t.test('RevokeCertification: a target beyond proximity is rejected, same rule as grant', function()
    local f = newFixture({ proximityMeters = 5.0 })
    f.registerPlayer(10, 'REVOKER', { name = 'police', isboss = true })
    f.registerPlayer(20, 'REVOKEE', { name = 'police', grade = { level = 1 } })
    f.setPed(10, 1010, vec3(0, 0, 0))
    f.setPed(20, 1020, vec3(50, 0, 0))
    f.setSource(10)
    f.events['qbx_k9unit:server:revokeHandler'](20)
    t.isTrue(notifiedExactly(f, 10, localeWithPendingCertKeys('certifications.target_too_far_to_revoke_distance', tostring(5.0)), 'error'))
end)

t.test('RevokeCertification: a genuinely offline target (numeric-id path) is refused with a pointer to the offline command, never silently proceeds', function()
    local f = newFixture()
    f.registerPlayer(10, 'REVOKER', { name = 'police', isboss = true })
    f.setPed(10, 1010, vec3(0, 0, 0))
    local updateCalled = false
    f.mysql.update.await = function() updateCalled = true; return 1 end
    f.setSource(10)
    f.events['qbx_k9unit:server:revokeHandler'](999) -- never registered -> offline
    t.isTrue(notifiedExactly(f, 10, Sandbox.locale('certifications.target_offline_use_decertify_offline'), 'error'))
    t.isFalse(updateCalled, 'the numeric-id revoke path must never attempt an UPDATE against an unresolvable offline target')
end)

t.test('RevokeCertification: not certifier-eligible is rejected', function()
    local f = newFixture()
    f.registerPlayer(10, 'REVOKER', { name = 'police', grade = { level = 1 } }) -- below certifierGrade 4
    f.registerPlayer(20, 'REVOKEE', { name = 'police', grade = { level = 1 } })
    f.setSource(10)
    f.events['qbx_k9unit:server:revokeHandler'](20)
    t.isTrue(notifiedExactly(f, 10, localeWithPendingCertKeys('certifications.not_authorized_to_revoke_hint'), 'error'))
end)

-- ----------------------------------------------------------------------
-- REGRESSION (dependency-verification pass): oxmysql's `.await` funnels
-- every query through one shared `await(fn, query, parameters)` whose
-- callback does `if error then return p:reject(error) end`, and a
-- REJECTED promise raises via `error(promise.value, 2)` inside
-- `Citizen.Await` -- a real DB error (bad connection, deadlock, schema
-- drift) THROWS out of a bare `.await` call, it does not return nil. This
-- file's revoke paths now pcall every `.await` (see RevokeCertification's
-- own doc comment above the UPDATE). The two cases below drive an
-- `error(...)`-throwing MySQL.update.await stub through the real,
-- unmodified production handler and assert: (1) the thrown error never
-- propagates out of the event handler, (2) the granter gets a sensible
-- notification either way, and (3) the in-memory Certifications cache
-- never diverges from what actually happened in the DB.
-- ----------------------------------------------------------------------

t.test('RevokeCertification: REGRESSION -- a throwing UPDATE that genuinely never committed (reconciliation confirms still active) never propagates, notifies revoke_error, and leaves the cert/leash/outbound state completely untouched', function()
    local f = newFixture()
    f.registerPlayer(10, 'REVOKER', { name = 'police', isboss = true })
    f.registerPlayer(20, 'REVOKEE', { name = 'police', grade = { level = 1 } })
    f.setPed(10, 1010, vec3(0, 0, 0))
    f.setPed(20, 1020, vec3(0, 0, 0))
    f.mysql.scalar.await = function() return 5 end -- seed an active cert first
    f.env.RefreshCertificationCache('REVOKEE', 'police')
    t.isTrue(f.env.HasK9Access(20), 'sanity: really certified before the simulated outage')

    f.mysql.update.await = function() error('simulated connection drop mid-UPDATE') end
    -- Reconciliation SELECT (IsCertRowConfirmedActive) confirms the row is
    -- STILL active -- the UPDATE genuinely never committed.
    f.mysql.scalar.await = function() return 5 end

    f.setSource(10)
    local ok, err = pcall(f.events['qbx_k9unit:server:revokeHandler'], 20)
    t.isTrue(ok, 'the event handler must never propagate a thrown DB error: ' .. tostring(err))

    t.isTrue(notifiedExactly(f, 10, Sandbox.locale('certifications.revoke_error'), 'error'), 'the granter must see a sensible error notification, not silence')
    t.isNil(lastNotifyFor(f, 20), 'the target must NOT be told their cert was revoked -- it genuinely was not')
    t.isTrue(f.env.HasK9Access(20), 'NO PARTIAL STATE: the cache must still report the cert active, matching the DB (the UPDATE never committed)')
    t.equals(#f.leashDetachCalls, 0, 'no leash teardown must run for a revoke that never actually happened')
    t.equals(#f.outboundEvents, 0, 'no outbound certificationRevoked event for a revoke that never actually happened')
end)

t.test('RevokeCertification: REGRESSION -- a throwing UPDATE that ACTUALLY committed (ack lost after a real commit) is confirmed via reconciliation and reported as the genuine success it was, never left diverging from the DB', function()
    local f = newFixture()
    f.registerPlayer(10, 'REVOKER', { name = 'police', isboss = true })
    local target = f.registerPlayer(20, 'REVOKEE', { name = 'police', grade = { level = 1 } })
    f.setPed(10, 1010, vec3(0, 0, 0))
    f.setPed(20, 1020, vec3(0, 0, 0))
    f.mysql.scalar.await = function() return 5 end
    f.env.RefreshCertificationCache('REVOKEE', 'police')
    t.isTrue(f.env.HasK9Access(20))

    f.mysql.update.await = function() error('simulated ack lost after a real commit') end
    -- Every scalar.await call after the throwing UPDATE (the
    -- IsCertRowConfirmedActive reconciliation read, and then
    -- RefreshCertificationCache's own re-query on the fall-through success
    -- path) now sees the row as inactive -- confirming the UPDATE actually
    -- committed despite the client-side error.
    f.mysql.scalar.await = function() return nil end

    f.setSource(10)
    local ok, err = pcall(f.events['qbx_k9unit:server:revokeHandler'], 20)
    t.isTrue(ok, 'must not propagate: ' .. tostring(err))

    t.isFalse(f.env.HasK9Access(20), 'the cache must reflect the CONFIRMED true outcome (revoked), never the failed client-side call alone')
    t.isTrue(notifiedExactly(f, 20, Sandbox.locale('certifications.revoked_notice_online'), 'error'), 'the target must be told their cert was actually revoked, since it genuinely was')
    t.isTrue(notifiedExactly(f, 10, Sandbox.locale('certifications.revoke_success'), 'success'), 'the granter must see a real success, not an error, once reconciliation confirms the DB truth')
    t.equals(target._metaWrites[#target._metaWrites].value, false)
    t.equals(f.leashDetachCalls[#f.leashDetachCalls][1], 20)
end)

t.test('RevokeCertification: REGRESSION -- the reconciliation read ITSELF also failing (true outcome unknown) still degrades safely, never propagates, and never claims success it cannot confirm', function()
    local f = newFixture()
    f.registerPlayer(10, 'REVOKER', { name = 'police', isboss = true })
    f.registerPlayer(20, 'REVOKEE', { name = 'police', grade = { level = 1 } })
    f.setPed(10, 1010, vec3(0, 0, 0))
    f.setPed(20, 1020, vec3(0, 0, 0))
    f.mysql.scalar.await = function() return 5 end
    f.env.RefreshCertificationCache('REVOKEE', 'police')

    f.mysql.update.await = function() error('simulated connection drop mid-UPDATE') end
    f.mysql.scalar.await = function() error('simulated: DB still unreachable for the reconciliation read too') end

    f.setSource(10)
    local ok, err = pcall(f.events['qbx_k9unit:server:revokeHandler'], 20)
    t.isTrue(ok, 'must not propagate even when BOTH the UPDATE and the reconciliation read throw: ' .. tostring(err))

    t.isTrue(notifiedExactly(f, 10, Sandbox.locale('certifications.revoke_error'), 'error'), 'an unconfirmable outcome must still notify an honest error, never silence')
    t.isTrue(f.env.HasK9Access(20), 'an unconfirmed outcome must never flip the cache toward "revoked" on a guess')
    t.equals(#f.outboundEvents, 0)
end)

-- ======================================================================
-- RevokeCertificationOffline -- the ONLY path reachable, per the file's own
-- header, through the '/k9decertifyoffline [citizenid] [job]' command (no
-- net-event counterpart exists for a genuinely disconnected target).
-- ======================================================================

t.test('RevokeCertificationOffline: full offline success path -- UPDATE fires, cache re-primed to inactive for next login, outbound event reason is manual_offline', function()
    local f = newFixture()
    f.registerPlayer(10, 'REVOKER', { name = 'police', isboss = true })
    -- REVOKEE is intentionally never registered -- genuinely offline.
    local updateParams
    f.mysql.update.await = function(_sql, params) updateParams = params; return 1 end
    f.mysql.scalar.await = function() return nil end -- post-revoke re-cache: no active row

    f.commands['k9decertify'].fn(10, { 'REVOKEE', 'police' })

    -- CERTIFICATION DEPTH (this pass, Part A §2): same positional shift as
    -- the online path above.
    t.equals(updateParams[1], 'REVOKER')
    t.isNil(updateParams[2])
    t.equals(updateParams[3], 'REVOKEE')
    t.equals(updateParams[4], 'police')
    t.isTrue(notifiedExactly(f, 10, Sandbox.locale('certifications.revoke_success'), 'success'))

    local fired = false
    for _, ev in ipairs(f.outboundEvents) do
        if ev[1] == 'qbx_k9unit:events:certificationRevoked' and ev[4] == 'manual_offline' then fired = true end
    end
    t.isTrue(fired)
end)

t.test('RevokeCertificationOffline: SECURITY -- refuses outright when the "offline" citizenid is actually online right now, pointing the caller at /k9decertify instead (closes the proximity-check bypass)', function()
    local f = newFixture()
    f.registerPlayer(10, 'REVOKER', { name = 'police', isboss = true })
    f.registerPlayer(20, 'ACTUALLY-ONLINE', { name = 'police', grade = { level = 1 } })
    local updateCalled = false
    f.mysql.update.await = function() updateCalled = true; return 1 end

    f.commands['k9decertify'].fn(10, { 'ACTUALLY-ONLINE', 'police' })

    t.isTrue(notifiedExactly(f, 10, Sandbox.locale('certifications.target_online_use_decertify_command', 20), 'error'))
    t.isFalse(updateCalled, 'a currently-online target must never be revocable through the proximity-check-free offline path')
end)

t.test('RevokeCertificationOffline: a citizenid with no active cert for that department is a distinguishable no-op', function()
    local f = newFixture()
    f.registerPlayer(10, 'REVOKER', { name = 'police', isboss = true })
    f.mysql.update.await = function() return 0 end
    f.commands['k9decertify'].fn(10, { 'NOBODY', 'police' })
    t.isTrue(notifiedExactly(f, 10, Sandbox.locale('certifications.offline_target_not_certified'), 'inform'))
end)

t.test('RevokeCertificationOffline: a typo\'d/unconfigured department is rejected outright, never runs a query that could never match', function()
    local f = newFixture()
    f.registerPlayer(10, 'REVOKER', { name = 'police', isboss = true })
    local updateCalled = false
    f.mysql.update.await = function() updateCalled = true; return 1 end
    f.commands['k9decertify'].fn(10, { 'SOMEONE', 'not-a-real-department' })
    t.isTrue(notifiedExactly(f, 10, localeWithPendingCertKeys('certifications.invalid_department_hint', 'not-a-real-department', 'police, sheriff'), 'error'))
    t.isFalse(updateCalled)
end)

t.test('RevokeCertificationOffline: a missing job argument is rejected with the usage message, matching the command\'s own arg-shape guard', function()
    local f = newFixture()
    f.registerPlayer(10, 'REVOKER', { name = 'police', isboss = true })
    f.commands['k9decertify'].fn(10, { 'SOMEONE' }) -- args[2] missing
    t.isTrue(notifiedExactly(f, 10, Sandbox.locale('certifications.usage_decertify'), 'error'))
end)

t.test('RevokeCertificationOffline: REGRESSION -- a throwing UPDATE degrades safely (reconciliation confirms still active), never propagates, notifies revoke_error, and leaves the cert untouched', function()
    local f = newFixture()
    f.registerPlayer(10, 'REVOKER', { name = 'police', isboss = true })
    -- Seed the cache as actively certified for REVOKEE (citizenid-keyed,
    -- independent of being online -- REVOKEE is intentionally never
    -- registered here, exactly like the offline success test above).
    f.mysql.scalar.await = function() return 5 end
    f.env.RefreshCertificationCache('REVOKEE', 'police')

    f.mysql.update.await = function() error('simulated connection drop mid-UPDATE') end
    -- Reconciliation (IsCertRowConfirmedActive) confirms the row is STILL
    -- active -- the UPDATE genuinely never committed.
    f.mysql.scalar.await = function() return 5 end

    local ok, err = pcall(f.commands['k9decertify'].fn, 10, { 'REVOKEE', 'police' })
    t.isTrue(ok, 'the command handler must never propagate a thrown DB error: ' .. tostring(err))

    t.isTrue(notifiedExactly(f, 10, Sandbox.locale('certifications.revoke_error'), 'error'))
    t.equals(#f.outboundEvents, 0, 'no outbound certificationRevoked event for a revoke that never actually happened')

    -- NO PARTIAL STATE: REVOKEE's certification cache must still be
    -- observably active for their real, current job.
    f.registerPlayer(21, 'REVOKEE', { name = 'police', grade = { level = 1 } })
    t.isTrue(f.env.HasK9Access(21), 'the cache must still report the cert active, matching the DB (the UPDATE never committed)')
end)

-- ======================================================================
-- FIX (this pass, consistency finding): RevokeCertificationOffline already
-- closes the TOCTOU window where the target reconnects between the
-- online-check guard and the UPDATE landing for leash and partnership
-- (ForceBreakPartnershipForCitizenId) -- EndActiveEffectForHolder was the
-- one call in that same "must not outlive certification" family missing
-- from this call site. All three now go through this file's own shared
-- EndK9AccessForCitizenId helper (server/certifications/) -- see that
-- function's own doc comment for the full writeup.
-- ======================================================================

t.test('RevokeCertificationOffline: FIX -- ends any active bite-hold/takedown/drag if the target reconnects in the narrow window between the online-check guard and the UPDATE landing (consistency with leash/partnership at this same call site)', function()
    local f = newFixture()
    f.registerPlayer(10, 'REVOKER', { name = 'police', isboss = true })
    -- REVOKEE starts genuinely offline (passes the online-check guard),
    -- then "reconnects" as a side effect of the UPDATE landing -- modeling
    -- the exact TOCTOU window EndK9AccessForCitizenId's own doc comment
    -- already describes closing for leash/partnership at this call site.
    f.mysql.update.await = function(_sql, _params)
        f.registerPlayer(99, 'REVOKEE', { name = 'police', grade = { level = 1 } })
        return 1
    end
    f.mysql.scalar.await = function() return nil end

    f.commands['k9decertify'].fn(10, { 'REVOKEE', 'police' })

    t.equals(f.leashDetachCalls[#f.leashDetachCalls][1], 99)
    t.equals(f.effectEndCalls[#f.effectEndCalls], 99)
    t.equals(f.partnershipBreakCalls[#f.partnershipBreakCalls][1], 'REVOKEE')
end)

t.test('RevokeCertificationOffline: a genuinely offline target (never reconnects mid-window) never calls EndActiveEffectForHolder at all -- nothing to end for an offline citizenid', function()
    local f = newFixture()
    f.registerPlayer(10, 'REVOKER', { name = 'police', isboss = true })
    -- REVOKEE is intentionally never registered at any point.
    f.mysql.update.await = function() return 1 end
    f.mysql.scalar.await = function() return nil end

    f.commands['k9decertify'].fn(10, { 'REVOKEE', 'police' })

    t.equals(#f.effectEndCalls, 0)
end)

-- ======================================================================
-- Automatic revoke-on-job-change (QBCore:Server:OnJobUpdate) -- no client
-- entry point at all, per the file's own header; fired directly via the
-- captured AddEventHandler closure with an explicit (source, job) pair.
-- ======================================================================

local function fireJobUpdate(f, source, newJob)
    f.eventHandlers['QBCore:Server:OnJobUpdate'][1](source, newJob)
end

t.test('OnJobUpdate: a same-department GRADE change (promotion/demotion) does NOT revoke the certification', function()
    local f = newFixture()
    f.registerPlayer(30, 'CIT30', { name = 'police', grade = { level = 1 } })
    f.mysql.scalar.await = function() return 3 end
    f.env.RefreshCertificationCache('CIT30', 'police')
    t.isTrue(f.env.HasK9Access(30))

    local updateCalled = false
    f.mysql.update.await = function() updateCalled = true; return 1 end

    fireJobUpdate(f, 30, { name = 'police', grade = { level = 5 } }) -- SAME job name, just a higher grade

    t.isFalse(updateCalled, 'a grade change within the same department must never trigger a revoke UPDATE')
    -- The player's job object was replaced with a new table (grade=5) but
    -- job.name is unchanged, so re-checking access should still reflect the
    -- cache untouched by this handler (still active for 'police').
    f.registerPlayer(30, 'CIT30', { name = 'police', grade = { level = 5 } })
    t.isTrue(f.env.HasK9Access(30), 'the cached cert must still be intact after a mere grade change')
end)

-- ======================================================================
-- FIX (this pass, "the worst bug this project has already fixed once" --
-- second door): an autoAccessGrade-only holder has no cached certification
-- row at all, so the grade-change guard above (correctly!) never revokes
-- anything for them via a DB write -- but that also meant NOTHING tore
-- down their leash/partnership/hold when a same-department demotion below
-- autoAccessGrade genuinely took their K9 access away. See OnJobUpdate's
-- own new doc comment (server/certifications/) for the full writeup.
-- ======================================================================

t.test('OnJobUpdate: FIX -- a same-department demotion below autoAccessGrade, for a citizenid with NO cached cert (autoAccessGrade was their ONLY route), force-detaches the leash, ends any held effect, and breaks the partnership', function()
    local f = newFixture({ departments = {
        police = { label = 'Police', certifierGrade = 4, autoAccessGrade = 5 },
    } })
    f.registerPlayer(90, 'CIT90', { name = 'police', grade = { level = 5 } })
    f.mysql.scalar.await = function() return nil end -- never certified
    f.env.RefreshCertificationCache('CIT90', 'police') -- populates the cache as inactive, scoped to 'police' -- this is what PlayerLoaded/the onResourceStart backfill would already have done for a real, currently-connected player
    t.isTrue(f.env.HasK9Access(90), 'grade 5 >= autoAccessGrade 5 must grant access with no cert at all')

    local updateCalled = false
    f.mysql.update.await = function() updateCalled = true; return 1 end

    fireJobUpdate(f, 90, { name = 'police', grade = { level = 3 } }) -- demoted below the threshold, SAME department

    t.isFalse(updateCalled, 'there was never an active cert row to revoke -- no DB write should be attempted for this citizenid')
    t.equals(f.leashDetachCalls[#f.leashDetachCalls][1], 90)
    t.equals(f.leashDetachCalls[#f.leashDetachCalls][2], 'k9_access_lost')
    t.equals(f.effectEndCalls[#f.effectEndCalls], 90)
    t.equals(f.partnershipBreakCalls[#f.partnershipBreakCalls][1], 'CIT90')
    t.equals(f.partnershipBreakCalls[#f.partnershipBreakCalls][2], 'k9_access_lost')

    -- WORKFLOW CLARITY (this pass, item 4 -- "a job change is the
    -- invisible one"): this is the EXACT case that pass closes -- a
    -- confirmed grade-based access loss reachable with NO admin action at
    -- all. Zero false-positive risk here BY CONSTRUCTION (reaching this
    -- line already required `stillHasNonCertAccess == false`), so this
    -- must always notify.
    t.isTrue(notifiedExactly(f, 90, localeWithPendingCertKeys('certifications.k9_access_lost_grade_change'), 'error'))
    local audited = false
    for _, line in ipairs(f.printLog) do
        if line:find('AUDIT: job change ended K9 access', 1, true) and line:find('CIT90', 1, true) then audited = true end
    end
    t.isTrue(audited, 'the actor (unreachable directly -- OnJobUpdate carries no acting source) must be able to understand this afterward via the server console')
end)

t.test('OnJobUpdate: APPEARANCE FIX -- a same-department demotion below autoAccessGrade (no cached cert) also calls MaybeRevertK9Appearance, so an autoAccessGrade-only role-holder is never stranded on the K9 model after losing the grade', function()
    local f = newFixture({ departments = {
        police = { label = 'Police', certifierGrade = 4, autoAccessGrade = 5 },
    } })
    f.registerPlayer(90, 'CIT90', { name = 'police', grade = { level = 5 } })
    f.mysql.scalar.await = function() return nil end
    f.env.RefreshCertificationCache('CIT90', 'police')
    t.isTrue(f.env.HasK9Access(90))

    fireJobUpdate(f, 90, { name = 'police', grade = { level = 3 } })

    t.equals(#f.appearanceRevertCalls, 1)
    t.equals(f.appearanceRevertCalls[1], 'CIT90')
end)

t.test('OnJobUpdate: FIX -- a same-department demotion that STAYS at/above autoAccessGrade does nothing (access genuinely unchanged)', function()
    local f = newFixture({ departments = {
        police = { label = 'Police', certifierGrade = 4, autoAccessGrade = 5 },
    } })
    f.registerPlayer(91, 'CIT91', { name = 'police', grade = { level = 10 } })
    f.mysql.scalar.await = function() return nil end
    f.env.RefreshCertificationCache('CIT91', 'police')

    fireJobUpdate(f, 91, { name = 'police', grade = { level = 5 } }) -- still >= 5

    t.equals(#f.leashDetachCalls, 0)
    t.equals(#f.effectEndCalls, 0)
    t.equals(#f.partnershipBreakCalls, 0)
    -- WORKFLOW CLARITY (this pass, item 4) -- no real loss occurred, so no
    -- "your K9 access ended" notice must be sent either; an ordinary
    -- promotion/demotion that stays above the threshold must be silent.
    t.equals(#f.notifyLog, 0)
end)

t.test('OnJobUpdate: FIX -- a same-department demotion below autoAccessGrade does NOT tear anything down when the citizenid separately holds an active k9.access permission grant', function()
    local f = newFixture({ departments = {
        police = { label = 'Police', certifierGrade = 4, autoAccessGrade = 5 },
    } })
    f.registerPlayer(92, 'CIT92', { name = 'police', grade = { level = 5 } })
    f.mysql.scalar.await = function() return nil end
    f.env.RefreshCertificationCache('CIT92', 'police')
    f.env.HasPermission = function(citizenid, key) return citizenid == 'CIT92' and key == 'k9.access' end

    fireJobUpdate(f, 92, { name = 'police', grade = { level = 1 } }) -- demoted well below the threshold

    t.equals(#f.leashDetachCalls, 0, 'the citizenid still has K9 access via the permission grant -- nothing to tear down')
    t.equals(#f.effectEndCalls, 0)
    t.equals(#f.partnershipBreakCalls, 0)
end)

t.test('OnJobUpdate: FIX -- a same-department demotion below autoAccessGrade does NOT tear anything down when the citizenid is high command', function()
    local f = newFixture({ departments = {
        police = { label = 'Police', certifierGrade = 4, autoAccessGrade = 5 },
    } })
    f.registerPlayer(93, 'CIT93', { name = 'police', grade = { level = 5 } })
    f.mysql.scalar.await = function() return nil end
    f.env.RefreshCertificationCache('CIT93', 'police')
    f.env.IsHighCommand = function(src) return src == 93 end

    fireJobUpdate(f, 93, { name = 'police', grade = { level = 1 } })

    t.equals(#f.leashDetachCalls, 0)
    t.equals(#f.effectEndCalls, 0)
    t.equals(#f.partnershipBreakCalls, 0)
end)

t.test('OnJobUpdate: FIX -- with NO cached entry at all for this citizenid (never logged in this session), the new autoAccessGrade branch is a disclosed no-op, leaving the existing behavior unchanged rather than guessing', function()
    local f = newFixture({ departments = {
        police = { label = 'Police', certifierGrade = 4, autoAccessGrade = 5 },
    } })
    f.registerPlayer(94, 'CIT94', { name = 'police', grade = { level = 5 } })
    -- Deliberately never call RefreshCertificationCache -- `Certifications['CIT94']` stays nil.

    fireJobUpdate(f, 94, { name = 'police', grade = { level = 1 } })

    t.equals(#f.leashDetachCalls, 0)
    t.equals(#f.effectEndCalls, 0)
    t.equals(#f.partnershipBreakCalls, 0)
end)

t.test('OnJobUpdate: a REAL department change revokes the old cert, re-scopes the cache to the new job, notifies, and force-detaches the leash', function()
    local f = newFixture()
    local player = f.registerPlayer(40, 'CIT40', { name = 'police', grade = { level = 1 } })
    f.mysql.scalar.await = function() return 9 end
    f.env.RefreshCertificationCache('CIT40', 'police')
    t.isTrue(f.env.HasK9Access(40))

    local updateParams
    f.mysql.update.await = function(_sql, params) updateParams = params; return 1 end
    f.mysql.scalar.await = function() return nil end -- new job ('sheriff') has no active row

    fireJobUpdate(f, 40, { name = 'sheriff', grade = { level = 1 } })

    -- CERTIFICATION DEPTH (this pass, Part A §2): the automatic auto-revoke
    -- path always records revoke_reason='reassigned', now bound as
    -- params[2], shifting citizenid/job to params[3]/[4].
    t.equals(updateParams[1], 'system:job_change')
    t.equals(updateParams[2], 'reassigned')
    t.equals(updateParams[3], 'CIT40')
    t.equals(updateParams[4], 'police')
    -- WORKFLOW CLARITY (this pass, item 4): a "what to do next" follow-up
    -- is now sent right after this one -- see the dedicated test below --
    -- so this is no longer necessarily the LAST notice; anyNotify still
    -- proves it was sent.
    t.isTrue(anyNotify(f, 40, Sandbox.locale('certifications.revoked_notice_job_change', 'Police Department'), 'error'))
    t.isTrue(notifiedExactly(f, 40, localeWithPendingCertKeys('certifications.revoked_notice_job_change_next_steps'), 'inform'))
    t.equals(player._metaWrites[#player._metaWrites].value, false)
    t.equals(f.leashDetachCalls[#f.leashDetachCalls][1], 40)
    t.equals(f.leashDetachCalls[#f.leashDetachCalls][2], 'certification_revoked')

    local fired = false
    for _, ev in ipairs(f.outboundEvents) do
        if ev[1] == 'qbx_k9unit:events:certificationRevoked' and ev[2] == 'CIT40' and ev[3] == 'police' and ev[4] == 'job_changed' then fired = true end
    end
    t.isTrue(fired)
end)

t.test('OnJobUpdate: APPEARANCE FIX -- a real department (job-name) change that auto-revokes the old certification also calls MaybeRevertK9Appearance, closing the last of the five "K9-role access just ended" sites that never wired it', function()
    local f = newFixture()
    f.registerPlayer(40, 'CIT40', { name = 'police', grade = { level = 1 } })
    f.mysql.scalar.await = function() return 9 end
    f.env.RefreshCertificationCache('CIT40', 'police')
    t.isTrue(f.env.HasK9Access(40))

    f.mysql.update.await = function() return 1 end
    f.mysql.scalar.await = function() return nil end

    fireJobUpdate(f, 40, { name = 'sheriff', grade = { level = 1 } })

    t.equals(#f.appearanceRevertCalls, 1)
    t.equals(f.appearanceRevertCalls[1], 'CIT40')
end)

t.test('OnJobUpdate: losing department membership entirely (new job not in Config.Departments) force-detaches the OFFICER-role leash even with no cert of the player\'s own', function()
    local f = newFixture()
    f.registerPlayer(50, 'CIT50', { name = 'police', grade = { level = 1 } }) -- never certified -- pure handler/officer role
    fireJobUpdate(f, 50, { name = 'taxi', grade = { level = 1 } })
    t.equals(f.officerLeashDetachCalls[#f.officerLeashDetachCalls][1], 50)
    t.equals(f.officerLeashDetachCalls[#f.officerLeashDetachCalls][2], 'department_changed')
    t.equals(#f.notifyLog, 0, 'a player with no active cert of their own must get no cert-revoke notification from this path')
end)

-- ======================================================================
-- WORKFLOW CLARITY (this pass, item 4 -- "a job change is the invisible
-- one... whatever happens, both the person and the actor should be able
-- to understand it afterwards"). The department-loss branch above runs
-- for EVERY employee leaving an eligible department, so it must stay
-- silent for the overwhelming majority (the test immediately above already
-- pins that). It is scoped to notify ONLY the one case this file can
-- verify after the fact without a second tracking cache: a citizenid who
-- separately holds a 'k9.access' PERMISSION GRANT (not job-scoped, so
-- still checkable once `job` is already the new one) -- see this file's
-- header for the disclosed autoAccessGrade-only residual gap.
-- ======================================================================

t.test('OnJobUpdate: WORKFLOW CLARITY -- leaving the department entirely notifies a citizenid who holds a separate k9.access permission grant, since that grant silently stops working the instant department membership is lost', function()
    local f = newFixture()
    f.registerPlayer(52, 'CIT52', { name = 'police', grade = { level = 1 } })
    f.env.HasPermission = function(citizenid, key) return citizenid == 'CIT52' and key == 'k9.access' end

    fireJobUpdate(f, 52, { name = 'taxi', grade = { level = 1 } })

    t.isTrue(notifiedExactly(f, 52, localeWithPendingCertKeys('certifications.k9_access_lost_department_change'), 'error'))
    local audited = false
    for _, line in ipairs(f.printLog) do
        if line:find('AUDIT: job change ended K9 access', 1, true) and line:find('CIT52', 1, true) then audited = true end
    end
    t.isTrue(audited)
end)

t.test('OnJobUpdate: a K9-role player who ALSO loses department membership entirely triggers BOTH the officer-role leash detach AND the cert-revoke leash detach -- pinned as observed, not assumed exclusive', function()
    -- FINDING (behavior pin, not a bug report): server/certifications/'s
    -- header states an officer/handler-role party "never holds a K9
    -- certification of their own" as the reason the department-loss branch
    -- and the cert-revoke branch are independent. That's a gameplay
    -- invariant, not one this handler itself enforces -- a hypothetical
    -- citizenid holding an active cert whose NEW job is not a configured
    -- department at all satisfies BOTH branches' conditions, so both fire.
    local f = newFixture()
    f.registerPlayer(60, 'CIT60', { name = 'police', grade = { level = 1 } })
    f.mysql.scalar.await = function() return 1 end
    f.env.RefreshCertificationCache('CIT60', 'police')

    f.mysql.update.await = function() return 1 end
    f.mysql.scalar.await = function() return nil end

    fireJobUpdate(f, 60, { name = 'taxi', grade = { level = 1 } })

    t.equals(f.officerLeashDetachCalls[#f.officerLeashDetachCalls][1], 60)
    t.equals(f.officerLeashDetachCalls[#f.officerLeashDetachCalls][2], 'department_changed')
    t.equals(f.leashDetachCalls[#f.leashDetachCalls][1], 60)
    t.equals(f.leashDetachCalls[#f.leashDetachCalls][2], 'certification_revoked')
end)

t.test('OnJobUpdate: ForceBreakPartnershipForCitizenId is called for a real department change when the global is present', function()
    local f = newFixture()
    f.registerPlayer(70, 'CIT70', { name = 'police', grade = { level = 1 } })
    f.mysql.scalar.await = function() return 1 end
    f.env.RefreshCertificationCache('CIT70', 'police')
    f.mysql.update.await = function() return 1 end
    f.mysql.scalar.await = function() return nil end

    fireJobUpdate(f, 70, { name = 'taxi', grade = { level = 1 } })

    local found = false
    for _, call in ipairs(f.partnershipBreakCalls) do
        if call[1] == 'CIT70' and call[2] == 'department_changed' then found = true end
    end
    t.isTrue(found)
end)

-- ======================================================================
-- FORCED BODY-CLAIM RELEASE (this pass) -- EndK9AccessForCitizenId's own
-- last missing teardown. A player who lost K9 access while resting in a
-- kennel or holding a vehicle seat kept both: still attached to the prop,
-- still seated, with the server's own registries still recording them.
--
-- These tests pin the CALL and its guard. The dispatcher's routing is
-- proven in tests/bodyclaims_spec.lua; the two mechanics' own teardowns in
-- tests/kennel_spec.lua and tests/vehicle_spec.lua. What is proven here is
-- only that this file makes the call at all, with the durable citizenid and
-- never a source, and that it survives the global being absent.
-- ======================================================================

t.test('FORCED BODY-CLAIM RELEASE: losing department membership entirely releases any kennel-rest or vehicle-seat claim this citizenid holds', function()
    local f = newFixture({
        departments = {
            police = { label = 'Police Department', certifierGrade = 4, autoAccessGrade = 5 },
        },
    })
    f.registerPlayer(96, 'CIT96', { name = 'police', grade = { level = 5 } })
    t.isTrue(f.env.HasK9Access(96), 'sanity: has access before the change')

    fireJobUpdate(f, 96, { name = 'taxi', grade = { level = 5 } })

    local last = f.bodyClaimReleaseCalls[#f.bodyClaimReleaseCalls]
    t.isNotNil(last, 'a K9 resting in a kennel when their access is revoked must not stay attached to it')
    t.equals(last[1], 'CIT96', 'keyed by the DURABLE citizenid, never a source -- server ids are recycled and this is also reachable for an offline player')
    t.equals(last[2], 'department_changed', 'the reason travels through so the player can be told why')
end)

t.test('FORCED BODY-CLAIM RELEASE: the runtime-existence guard tolerates server/bodyclaims.lua not being loaded at all', function()
    local f = newFixture({
        includeBodyClaimHook = false,
        departments = {
            police = { label = 'Police Department', certifierGrade = 4, autoAccessGrade = 5 },
        },
    })
    f.registerPlayer(97, 'CIT97', { name = 'police', grade = { level = 5 } })

    -- The real assertion is that this does not error, and that the rest of
    -- the teardown still completes -- one absent optional global must never
    -- take the whole access-revocation path down with it.
    fireJobUpdate(f, 97, { name = 'taxi', grade = { level = 5 } })

    t.equals(#f.bodyClaimReleaseCalls, 0)
    t.equals(f.partnershipBreakCalls[#f.partnershipBreakCalls][1], 'CIT97',
        'the teardown steps around the absent global still run')
end)

-- ======================================================================
-- FIFTH GAP FIX (this pass, cross-team "four doors, one bug" finding,
-- closing the fifth and last known instance): a K9-role party whose ONLY
-- access route is autoAccessGrade (or, equally, a server/permissions.lua
-- 'k9.access' grant) -- no certification row at all -- used to keep an
-- active leash, an in-progress bite-hold/takedown/drag, and any
-- partnership on leaving the department entirely. The department-loss
-- branch above only ever called ForceDetachOfficerLeashForSource (the
-- OFFICER-role leash), never ForceDetachLeashForSource/
-- EndActiveEffectForHolder for the K9-role party, and the
-- cert-revoke-due-to-job-change branch further below can never observe
-- this citizenid at all (it is gated on `cached.active`, and this
-- citizenid never had a certification row to cache in the first place).
-- See EndK9AccessForCitizenId's own doc comment and the department-loss
-- branch's own comment (both server/certifications/) for the full
-- writeup of why this is now closed via that shared helper.
-- ======================================================================

t.test('OnJobUpdate: FIFTH-GAP FIX -- a K9-role party with autoAccessGrade-only access (no certification row) force-detaches their OWN leash, ends any held effect, and breaks any partnership on losing department membership entirely', function()
    local f = newFixture({
        departments = {
            police = { label = 'Police Department', certifierGrade = 4, autoAccessGrade = 5 },
        },
    })
    f.registerPlayer(95, 'CIT95', { name = 'police', grade = { level = 5 } })
    -- Sanity: really has K9 access via autoAccessGrade alone, with no
    -- certification ever cached (RefreshCertificationCache deliberately
    -- never called) for this citizenid -- this is the exact "no
    -- certification row" shape the fifth gap needed.
    t.isTrue(f.env.HasK9Access(95), 'sanity: autoAccessGrade alone must already grant K9 access with zero certification cache entry')

    fireJobUpdate(f, 95, { name = 'taxi', grade = { level = 5 } })

    t.equals(f.leashDetachCalls[#f.leashDetachCalls][1], 95, 'the K9-role leash for this exact source must be force-detached, not just the officer-role one')
    t.equals(f.leashDetachCalls[#f.leashDetachCalls][2], 'department_changed')
    t.equals(f.effectEndCalls[#f.effectEndCalls], 95, 'an in-progress bite-hold/takedown/drag must not outlive this access loss either')
    t.equals(f.partnershipBreakCalls[#f.partnershipBreakCalls][1], 'CIT95')
    t.equals(f.partnershipBreakCalls[#f.partnershipBreakCalls][2], 'department_changed')

    -- The pre-existing officer-role detach must still fire too -- this fix
    -- is additive, alongside the existing department-loss behavior, never
    -- a replacement of it.
    t.equals(f.officerLeashDetachCalls[#f.officerLeashDetachCalls][1], 95)
    t.equals(f.officerLeashDetachCalls[#f.officerLeashDetachCalls][2], 'department_changed')
end)

t.test('OnJobUpdate: APPEARANCE FIX -- losing department membership entirely also calls MaybeRevertK9Appearance for the K9-role citizenid (autoAccessGrade/permission-grant-only access, no certification row at all, is exactly the case with no OTHER call site left to ever revert it)', function()
    local f = newFixture({
        departments = {
            police = { label = 'Police Department', certifierGrade = 4, autoAccessGrade = 5 },
        },
    })
    f.registerPlayer(95, 'CIT95', { name = 'police', grade = { level = 5 } })
    t.isTrue(f.env.HasK9Access(95), 'sanity: autoAccessGrade alone grants K9 access with zero certification cache entry')

    fireJobUpdate(f, 95, { name = 'taxi', grade = { level = 5 } })

    t.equals(#f.appearanceRevertCalls, 1)
    t.equals(f.appearanceRevertCalls[1], 'CIT95')
end)

t.test('OnJobUpdate: APPEARANCE FIX -- department loss with a STILL-ACTIVE certification row correctly defers the revert to the later job-name-change branch instead of double-firing here (MaybeRevertK9Appearance itself is idempotent/reconciling, so calling it from both branches is safe either way)', function()
    local f = newFixture()
    f.registerPlayer(60, 'CIT60', { name = 'police', grade = { level = 1 } })
    f.mysql.scalar.await = function() return 1 end
    f.env.RefreshCertificationCache('CIT60', 'police')

    f.mysql.update.await = function() return 1 end
    f.mysql.scalar.await = function() return nil end

    fireJobUpdate(f, 60, { name = 'taxi', grade = { level = 1 } })

    -- Both the department-loss branch AND the job-name-change cert-revoke
    -- branch fire for this exact scenario (see the pre-existing "BOTH the
    -- officer-role leash detach AND the cert-revoke leash detach" test
    -- above) -- MaybeRevertK9Appearance is called from both, but the stub
    -- here simply records every call rather than de-duplicating, so this
    -- pins the OBSERVED count (2) rather than assuming a single call site
    -- wins, matching this file's own "pinned as observed, not assumed
    -- exclusive" precedent for the leash-detach calls in that sibling test.
    t.equals(#f.appearanceRevertCalls, 2)
    t.equals(f.appearanceRevertCalls[1], 'CIT60')
    t.equals(f.appearanceRevertCalls[2], 'CIT60')
end)

t.test('OnJobUpdate: the runtime existence guard genuinely tolerates ForceBreakPartnershipForCitizenId being entirely absent (server/partnership.lua not loaded / feature off)', function()
    local f = newFixture({ includePartnershipHook = false })
    f.registerPlayer(80, 'CIT80', { name = 'police', grade = { level = 1 } })
    -- Must not error even though the department-loss branch would otherwise
    -- try to call a nonexistent global.
    fireJobUpdate(f, 80, { name = 'taxi', grade = { level = 1 } })
    t.equals(f.officerLeashDetachCalls[#f.officerLeashDetachCalls][1], 80, 'the rest of the handler must still run normally when this one optional global is absent')
end)

t.test('OnJobUpdate: REGRESSION -- a throwing auto-revoke UPDATE (reconciliation confirms still active) never propagates out of the AddEventHandler and runs ZERO side effects, leaving the cert intact', function()
    local f = newFixture()
    f.registerPlayer(40, 'CIT40', { name = 'police', grade = { level = 1 } })
    f.mysql.scalar.await = function() return 9 end
    f.env.RefreshCertificationCache('CIT40', 'police')
    t.isTrue(f.env.HasK9Access(40))

    f.mysql.update.await = function() error('simulated connection drop mid-UPDATE') end
    -- Reconciliation confirms the OLD job's row is STILL active.
    f.mysql.scalar.await = function() return 9 end

    local ok, err = pcall(fireJobUpdate, f, 40, { name = 'sheriff', grade = { level = 1 } })
    t.isTrue(ok, 'the AddEventHandler callback must never propagate a thrown DB error: ' .. tostring(err))

    t.equals(#f.notifyLog, 0, 'no accurate notification can be given for an outcome that was never confirmed')
    t.equals(#f.leashDetachCalls, 0)
    t.equals(#f.partnershipBreakCalls, 0)
    t.equals(#f.outboundEvents, 0)

    -- NO PARTIAL STATE: re-register under the SAME (unchanged, per this
    -- test) job to confirm the cache still reports the original cert active.
    f.registerPlayer(40, 'CIT40', { name = 'police', grade = { level = 1 } })
    t.isTrue(f.env.HasK9Access(40), 'the cache must still report the cert active for the OLD job -- it was never actually revoked')
end)

t.test('OnJobUpdate: REGRESSION -- a throwing auto-revoke UPDATE that ACTUALLY committed (ack lost after a real commit) is confirmed via reconciliation and the normal revoke side effects still run against that confirmed truth', function()
    local f = newFixture()
    local player = f.registerPlayer(41, 'CIT41', { name = 'police', grade = { level = 1 } })
    f.mysql.scalar.await = function() return 9 end
    f.env.RefreshCertificationCache('CIT41', 'police')
    t.isTrue(f.env.HasK9Access(41))

    f.mysql.update.await = function() error('simulated ack lost after a real commit') end
    -- Reconciliation, and the later RefreshCertificationCache re-query for
    -- the new job, both see the OLD job's row as inactive.
    f.mysql.scalar.await = function() return nil end

    local ok, err = pcall(fireJobUpdate, f, 41, { name = 'sheriff', grade = { level = 1 } })
    t.isTrue(ok, 'must not propagate: ' .. tostring(err))

    t.isTrue(anyNotify(f, 41, Sandbox.locale('certifications.revoked_notice_job_change', 'Police Department'), 'error'))
    t.equals(player._metaWrites[#player._metaWrites].value, false)
    t.equals(f.leashDetachCalls[#f.leashDetachCalls][1], 41)

    local fired = false
    for _, ev in ipairs(f.outboundEvents) do
        if ev[1] == 'qbx_k9unit:events:certificationRevoked' and ev[2] == 'CIT41' and ev[3] == 'police' and ev[4] == 'job_changed' then fired = true end
    end
    t.isTrue(fired)
end)

-- ======================================================================
-- Command wiring -- k9certify / k9decertify have their OWN arg-parsing
-- guard (tonumber(args[1])) layered in front of the shared functions above;
-- these two tests exercise that layer specifically, distinct from the net
-- event path's `type(targetServerId) ~= 'number'` guard already covered.
-- ======================================================================

-- ======================================================================
-- COMMAND CONSOLIDATION (docs/history/COMMAND_CONSOLIDATION_SPEC.md §2/§5 item 8) --
-- /k9certify and /k9decertify are now DISPATCHERS: `tonumber(args[1])`
-- succeeds -> online branch (unchanged); fails -> offline branch
-- (GrantCertificationOffline/RevokeCertificationOffline, unchanged). A
-- non-numeric args[1] is therefore no longer rejected outright -- it is a
-- CITIZENID, treated exactly like a direct citizenid call would.
-- ======================================================================

t.test('/k9certify command: a non-numeric args[1] is treated as an offline citizenid attempt, not rejected -- routes to GrantCertificationOffline unchanged', function()
    local f = newFixture()
    f.registerPlayer(1, 'G1', { name = 'police', isboss = true })

    local insertParams
    f.mysql.insert.await = function(_sql, params) insertParams = params; return 1 end

    f.commands['k9certify'].fn(1, { 'OFFLINE_CIT', 'police' })

    t.equals(insertParams[1], 'OFFLINE_CIT')
    t.equals(insertParams[2], 'police')
    t.isTrue(anyNotify(f, 1, Sandbox.locale('certifications.grant_success_granter'), 'success'))
end)

t.test('/k9certify command: a numeric args[1] still routes to the ONLINE GrantCertification, completely unchanged by the merge', function()
    local f = newFixture()
    f.registerPlayer(1, 'G1', { name = 'police', isboss = true })
    f.registerPlayer(20, 'T1', { name = 'police', grade = { level = 1 } })
    f.setPed(1, 1010, vec3(0, 0, 0))
    f.setPed(20, 1020, vec3(0, 0, 0))

    local insertCalled = false
    f.mysql.insert.await = function() insertCalled = true; return 1 end

    f.commands['k9certify'].fn(1, { '20' })

    t.isTrue(insertCalled)
    t.isTrue(notifiedExactly(f, 20, Sandbox.locale('certifications.grant_success_target'), 'success'))
end)

t.test('/k9certify command: a totally bare command (no args at all) shows the COMBINED usage string (both shapes), never just the narrower offline-only message', function()
    local f = newFixture()
    f.registerPlayer(1, 'G1', { name = 'police', isboss = true })
    f.commands['k9certify'].fn(1, {})
    t.isTrue(notifiedExactly(f, 1, Sandbox.locale('certifications.usage_certify'), 'error'))
    -- Since the offline aliases were deleted there is only ONE usage string
    -- left for this command, and it names both shapes -- so the old "must
    -- not show the NARROWER offline-only usage" assertion no longer has a
    -- second string to distinguish. Assert the positive claim it protected.
    t.isTrue(notifiedExactly(f, 1, Sandbox.locale('certifications.usage_certify'), 'error'), 'a bare /k9certify must show the combined usage naming both target shapes')
end)

-- ======================================================================
-- THE CERTIFY MERGE (2026-09-02, owner: "Merge /k9certify /k9recertify all
-- together").
--
-- /k9certify now decides for itself whether the target needs certifying or
-- renewing, because from a certifier's point of view those were never two
-- jobs: you make someone's certification current. Getting the choice wrong
-- used to cost a refusal and a second command.
--
-- The routing is NOT an authorization decision -- both destinations re-run
-- every eligibility, cooldown, self-certify, proximity and department check
-- exactly as before. These tests pin the routing itself, and pin the two
-- cases where it deliberately does NOT route to renew.
-- ======================================================================

--- Puts `citizenid` into the state the merged /k9certify treats as
--- "already certified", through server/certifications/'s OWN
--- RefreshCertificationCache rather than by writing the cache table
--- directly -- so this fixture agrees with production about what that state
--- means, instead of asserting against a shape the real code never builds.
--- @param f table @param citizenid string @param jobName string
local function seedActiveCertification(f, citizenid, jobName)
    local previousScalar = f.mysql.scalar.await
    f.mysql.scalar.await = function() return 55 end -- an active row exists
    f.env.RefreshCertificationCache(citizenid, jobName)
    f.mysql.scalar.await = previousScalar
end

t.test('MERGE: an already-certified ONLINE target is RENEWED, not refused with "already certified"', function()
    local f = newFixture({ features = { CertificationExpiry = true }, expiryDays = 90 })
    f.registerPlayer(1, 'G1', { name = 'police', isboss = true })
    f.registerPlayer(20, 'T1', { name = 'police', grade = { level = 1 } })
    f.setPed(1, 1010, vec3(0, 0, 0))
    f.setPed(20, 1020, vec3(0, 0, 0))

    seedActiveCertification(f, 'T1', 'police')

    local renewCalled = false
    f.mysql.update.await = function() renewCalled = true; return 1 end
    local insertCalled = false
    f.mysql.insert.await = function() insertCalled = true; return 1 end

    f.commands['k9certify'].fn(1, { '20' })

    t.isTrue(renewCalled, '/k9certify on an already-certified target must RENEW')
    t.isFalse(insertCalled, 'and must not attempt a second INSERT')
end)

t.test('MERGE: a NOT-yet-certified target still goes to the grant path, completely unchanged', function()
    -- The control. Without it, a change that routed everything to renew
    -- would pass the test above.
    local f = newFixture({ features = { CertificationExpiry = true }, expiryDays = 90 })
    f.registerPlayer(1, 'G1', { name = 'police', isboss = true })
    f.registerPlayer(20, 'T1', { name = 'police', grade = { level = 1 } })
    f.setPed(1, 1010, vec3(0, 0, 0))
    f.setPed(20, 1020, vec3(0, 0, 0))

    local insertCalled = false
    f.mysql.insert.await = function() insertCalled = true; return 1 end

    f.commands['k9certify'].fn(1, { '20' })

    t.isTrue(insertCalled, 'a brand-new target is INSERTed, exactly as before the merge')
    t.isTrue(notifiedExactly(f, 20, Sandbox.locale('certifications.grant_success_target'), 'success'))
end)

t.test('MERGE: with expiry switched OFF, an already-certified target falls through to GRANT and gets the honest "already certified" hint -- never the useless "renew is disabled" one', function()
    -- The second deliberate non-routing case, and the reason the router
    -- checks the expiry feature at all: RenewCertification refuses outright
    -- when expiry is off, which would be a strictly worse answer for the
    -- caller than the grant path's own accurate hint.
    local f = newFixture() -- Config.Features absent -- expiry off
    f.registerPlayer(1, 'G1', { name = 'police', isboss = true })
    f.registerPlayer(20, 'T1', { name = 'police', grade = { level = 1 } })
    f.setPed(1, 1010, vec3(0, 0, 0))
    f.setPed(20, 1020, vec3(0, 0, 0))

    seedActiveCertification(f, 'T1', 'police')
    f.mysql.scalar.await = function() return 55 end -- the grant path's own pre-check sees it too
    f.commands['k9certify'].fn(1, { '20' })

    t.isTrue(anyNotify(f, 1, Sandbox.locale('certifications.target_already_certified_hint'), 'inform'),
        'the grant path\'s own accurate hint')
    t.isFalse(anyNotify(f, 1, Sandbox.locale('certifications.renew_feature_disabled'), 'error'),
        'never the renew path\'s "this feature is off" refusal, which tells the caller nothing useful')
end)

t.test('MERGE: routing is NOT authorization -- an ineligible caller is still refused on an already-certified target', function()
    -- The routing helper runs before either destination, so it must not
    -- become a way to reach the renew path without passing its gates.
    local f = newFixture({ features = { CertificationExpiry = true }, expiryDays = 90 })
    f.registerPlayer(1, 'G1', { name = 'police', isboss = true })
    f.registerPlayer(20, 'T1', { name = 'police', grade = { level = 1 } })
    f.setPed(1, 1010, vec3(0, 0, 0))
    f.setPed(20, 1020, vec3(0, 0, 0))
    -- Seed the RENEW state specifically, so this test genuinely exercises the
    -- renew branch. Without it the empty cache would route to GRANT, which
    -- refuses an ineligible caller identically -- and this test would pass
    -- while proving nothing about the branch it names.
    seedActiveCertification(f, 'T1', 'police')

    -- Now strip the caller's authority.
    f.registerPlayer(1, 'G1', { name = 'police', grade = { level = 0 } })
    local renewCalled = false
    f.mysql.update.await = function() renewCalled = true; return 1 end

    f.commands['k9certify'].fn(1, { '20' })

    t.isFalse(renewCalled, 'an ineligible caller must not reach the renew write')
    t.isTrue(anyNotify(f, 1, Sandbox.locale('certifications.not_authorized_to_certify_hint'), 'error'))
end)

t.test('/k9decertify command: a non-numeric args[1] is treated as an offline citizenid attempt, not rejected -- routes to RevokeCertificationOffline unchanged, args shifted by one for the optional reason', function()
    local f = newFixture()
    f.registerPlayer(1, 'G1', { name = 'police', isboss = true })

    local updateParams
    f.mysql.update.await = function(_sql, params) updateParams = params; return 1 end
    f.mysql.scalar.await = function() return nil end

    f.commands['k9decertify'].fn(1, { 'OFFLINE_CIT', 'police', 'disciplinary' })

    t.equals(updateParams[2], 'disciplinary', 'the third arg must forward as the reason -- the offline shape shifts by one position vs. the online one')
    t.equals(updateParams[3], 'OFFLINE_CIT')
    t.equals(updateParams[4], 'police')
end)

t.test('/k9decertify command: a totally bare command (no args at all) shows the COMBINED usage string, never the offline-only one', function()
    local f = newFixture()
    f.registerPlayer(1, 'G1', { name = 'police', isboss = true })
    f.commands['k9decertify'].fn(1, {})
    t.isTrue(notifiedExactly(f, 1, Sandbox.locale('certifications.usage_decertify'), 'error'))
end)

t.test('HIDDEN ALIAS: /k9decertifyoffline still works standalone, byte-identical body', function()
    local f = newFixture()
    f.registerPlayer(1, 'G1', { name = 'police', isboss = true })
    local updateParams
    f.mysql.update.await = function(_sql, params) updateParams = params; return 1 end
    f.mysql.scalar.await = function() return nil end

    f.commands['k9decertify'].fn(1, { 'REVOKEE', 'police' })

    t.equals(updateParams[3], 'REVOKEE')
    t.equals(updateParams[4], 'police')
end)

t.test('RECYCLED SERVER ID SAFETY (docs/history/COMMAND_CONSOLIDATION_SPEC.md §2): the merged /k9decertify command resolves a numeric arg via a fresh GetPlayer() lookup on EVERY invocation, never a cached mapping -- a server id that is reassigned between two calls resolves to whoever holds it NOW, exactly like the pre-merge /k9decertify already did', function()
    local f = newFixture()
    f.registerPlayer(1, 'G1', { name = 'police', isboss = true })
    f.registerPlayer(20, 'FIRST_OCCUPANT', { name = 'police', grade = { level = 1 } })
    f.setPed(1, 1010, vec3(0, 0, 0))
    f.setPed(20, 1020, vec3(0, 0, 0))
    f.mysql.scalar.await = function() return 5 end
    f.env.RefreshCertificationCache('FIRST_OCCUPANT', 'police')

    f.disconnectPlayer(20)
    f.registerPlayer(20, 'SECOND_OCCUPANT', { name = 'police', grade = { level = 1 } })
    f.setPed(20, 1030, vec3(0, 0, 0))
    f.mysql.scalar.await = function() return 5 end
    f.env.RefreshCertificationCache('SECOND_OCCUPANT', 'police')

    local updateParams
    f.mysql.update.await = function(_sql, params) updateParams = params; return 1 end
    f.mysql.scalar.await = function() return nil end

    -- '20' now means SECOND_OCCUPANT -- the numeral is forwarded straight
    -- into GetPlayer(20), resolved fresh, in this same tick.
    f.commands['k9decertify'].fn(1, { '20' })

    t.equals(updateParams[3], 'SECOND_OCCUPANT', 'the numeral must resolve to whoever currently holds server id 20, never a stale mapping to whoever held it earlier')
end)

t.test('/k9certify command: a valid numeric string arg reaches the real grant flow end-to-end', function()
    local f = newFixture()
    f.registerPlayer(1, 'G1', { name = 'police', isboss = true })
    f.registerPlayer(2, 'T1', { name = 'police', grade = { level = 1 } })
    f.setPed(1, 100, vec3(0, 0, 0))
    f.setPed(2, 200, vec3(0, 0, 0), K9_HASH_SHEPHERD)
    f.commands['k9certify'].fn(1, { '2' })
    t.isTrue(anyNotify(f, 1, Sandbox.locale('certifications.grant_success_granter'), 'success'))
end)

-- ======================================================================
-- lib.callback.register('qbx_k9unit:server:hasK9Access', ...) wiring
-- ======================================================================

t.test('hasK9Access callback: registered exactly once, and delegates to the real HasK9Access for the caller\'s own source', function()
    local f = newFixture()
    f.registerPlayer(1, 'CIT1', { name = 'police', grade = { level = 1 } })
    f.mysql.scalar.await = function() return 1 end
    f.env.RefreshCertificationCache('CIT1', 'police')
    t.isTrue(type(f.callbacks['qbx_k9unit:server:hasK9Access']) == 'function')
    t.isTrue(f.callbacks['qbx_k9unit:server:hasK9Access'](1))
    t.isFalse(f.callbacks['qbx_k9unit:server:hasK9Access'](999))
end)

-- ======================================================================
-- RefreshCertificationCache: fail-closed on a query error
-- ======================================================================

-- COULD-NOT-DETERMINE HANDLING (lifecycle QA pass, this pass): the test
-- immediately below used to be titled "fails CLOSED (active = false),
-- never leaves a stale/unknown cache entry" and asserted exactly the bug
-- this pass exists to close -- a transient query failure for an already-
-- certified officer used to be recorded as a CONFIRMED revoke, silently
-- and durably, for the rest of that officer's session. That old assertion
-- is now WRONG and has been REPLACED (not merely renamed) below: a
-- previously-CONFIRMED certification must SURVIVE a transient read
-- failure. See RefreshCertificationCache's own doc comment in
-- server/certifications/ for the full contract this section proves.

t.test('RefreshCertificationCache: COULD-NOT-DETERMINE -- a throwing MySQL.scalar.await for an ALREADY-CERTIFIED citizenid KEEPS the previous confirmed state, never resets to uncertified', function()
    local f = newFixture()
    f.registerPlayer(90, 'CIT90', { name = 'police', grade = { level = 1 } })
    f.mysql.scalar.await = function() return 1 end
    f.env.RefreshCertificationCache('CIT90', 'police')
    t.isTrue(f.env.HasK9Access(90), 'sanity: really certified before the simulated outage')

    f.mysql.scalar.await = function() error('connection lost') end
    local active, stateKnown, freshlyVerified = f.env.RefreshCertificationCache('CIT90', 'police')
    t.isTrue(active, 'a transient failure must report the RETAINED previous value, never a manufactured false')
    t.isTrue(stateKnown, 'a retained previous confirmation is still a KNOWN state, safe for a caller to act on')
    t.isFalse(freshlyVerified, 'this exact call did not itself confirm anything -- it retained an EARLIER confirmation')
    t.isTrue(f.env.HasK9Access(90), 'a transient read failure must never silently revoke a real, already-confirmed certification')

    local sawCheckFailed, sawNotCertified = false, false
    for _, line in ipairs(f.printLog) do
        if line:find('CIT90', 1, true) and line:find('CERTIFICATION CHECK FAILED', 1, true) then sawCheckFailed = true end
        if line:find('CIT90', 1, true) and line:find('not certified', 1, true) then sawNotCertified = true end
    end
    t.isTrue(sawCheckFailed, 'the operator message must name the citizenid and say the CHECK failed')
    t.isFalse(sawNotCertified, 'the operator message must never claim this citizenid is "not certified" -- that is not what happened')
end)

t.test('RefreshCertificationCache: a GENUINE "not certified" answer (query succeeds, no active row) still results in not certified', function()
    local f = newFixture()
    f.registerPlayer(91, 'CIT91', { name = 'police', grade = { level = 1 } })
    f.mysql.scalar.await = function() return nil end -- a REAL, successful query -- genuinely no active row

    local active, stateKnown, freshlyVerified = f.env.RefreshCertificationCache('CIT91', 'police')
    t.isFalse(active, 'a confirmed-absent row must still report not-active')
    t.isTrue(stateKnown, 'a confirmed absence IS a known state -- this is not the could-not-determine case')
    t.isTrue(freshlyVerified, 'this call itself confirmed the absence, fresh, against the DB')
    t.isFalse(f.env.HasK9Access(91), 'a genuinely uncertified citizenid must still be denied access')
end)

t.test('RefreshCertificationCache: COULD-NOT-DETERMINE -- a failure with NO prior cached value never manufactures a false "denied" cache entry', function()
    local f = newFixture()
    f.registerPlayer(92, 'CIT92', { name = 'police', grade = { level = 1 } })
    f.mysql.scalar.await = function() error('connection lost') end -- first-ever check for this citizenid, and it fails

    local active, stateKnown, freshlyVerified = f.env.RefreshCertificationCache('CIT92', 'police')
    t.isFalse(active, 'with nothing known at all, the best-effort return value degrades to false')
    t.isFalse(stateKnown, 'this is the "truly unknown" case -- callers must NOT treat this as a confirmed answer')
    t.isFalse(freshlyVerified, 'nothing was confirmed by this call')
    t.isFalse(f.env.HasK9Access(92), 'access must still fail closed while genuinely unresolved')

    -- NOTE: unlike the "kept previous value" test above, this branch's own
    -- real message text legitimately contains the SUBSTRING "not certified"
    -- (inside the phrase `NOT a confirmed "not certified" one` -- the
    -- message is explicitly explaining what it is NOT claiming), so a bare
    -- substring search for that phrase would false-positive against the
    -- message's own careful hedging. Assert the POSITIVE hedge instead --
    -- that it explicitly says the truth is unknown and may still be a real
    -- certification -- which is the actual requirement (never assert
    -- "not certified" as a bare, confident claim).
    local sawCheckFailed, sawHedgedUnknown = false, false
    for _, line in ipairs(f.printLog) do
        if line:find('CIT92', 1, true) and line:find('CERTIFICATION CHECK FAILED', 1, true) then sawCheckFailed = true end
        if line:find('CIT92', 1, true) and line:find('may in fact BE certified', 1, true) then sawHedgedUnknown = true end
    end
    t.isTrue(sawCheckFailed, 'the operator message must name the citizenid and say the CHECK failed')
    t.isTrue(sawHedgedUnknown, 'the operator message must hedge honestly -- this citizenid may in fact be certified, not a confident "not certified" claim')

    -- Proves nothing false was durably written: a LATER, successful check
    -- for the SAME citizenid must be free to establish a real "certified"
    -- answer, unobstructed by anything the failed attempt above wrote.
    f.mysql.scalar.await = function() return 1 end
    f.mysql.single.await = function() return { tier = 'certified', expires_at_unix = nil } end
    local active2, stateKnown2, freshlyVerified2 = f.env.RefreshCertificationCache('CIT92', 'police')
    t.isTrue(active2)
    t.isTrue(stateKnown2)
    t.isTrue(freshlyVerified2)
    t.isTrue(f.env.HasK9Access(92), 'a later successful check must be able to certify this citizenid with no lingering effect from the earlier failure')
end)

t.test('RefreshCertificationCache: the retry is BOUNDED, not infinite -- exactly CERT_REFRESH_RETRY_ATTEMPTS (3) attempts, then gives up', function()
    local f = newFixture()
    f.registerPlayer(93, 'CIT93', { name = 'police', grade = { level = 1 } })

    local scalarCallCount = 0
    f.mysql.scalar.await = function()
        scalarCallCount = scalarCallCount + 1
        error('connection lost')
    end

    local active, stateKnown = f.env.RefreshCertificationCache('CIT93', 'police')
    t.equals(scalarCallCount, 3, 'must attempt exactly the bounded number of times -- never once (no retry at all) and never unboundedly')
    t.isFalse(active)
    t.isFalse(stateKnown)

    -- Sanity: a genuinely eventual success within the retry budget (fails
    -- twice, succeeds on the 3rd attempt) must be picked up as a real,
    -- fresh confirmation -- the bound is on ATTEMPTS, not a hard "give up
    -- after the first failure" in disguise.
    scalarCallCount = 0
    f.mysql.scalar.await = function()
        scalarCallCount = scalarCallCount + 1
        if scalarCallCount < 3 then error('connection lost') end
        return 1
    end
    f.mysql.single.await = function() return { tier = 'certified', expires_at_unix = nil } end
    local active2, stateKnown2, freshlyVerified2 = f.env.RefreshCertificationCache('CIT93', 'police')
    t.equals(scalarCallCount, 3, 'must have retried exactly up to the successful 3rd attempt, not fewer')
    t.isTrue(active2)
    t.isTrue(stateKnown2)
    t.isTrue(freshlyVerified2)

    -- This whole test calls RefreshCertificationCache directly, outside any
    -- coroutine (exactly like every other direct call in this spec file) --
    -- proves PcallWithBoundedRetry's own coroutine.isyieldable() guard
    -- degrades to "retry immediately, no backoff" rather than erroring
    -- ("attempt to yield from outside a coroutine") in that context.
    t.equals(#f.waitCalls, 0, 'Wait() must never be called from a non-coroutine context -- the isyieldable guard must have skipped it')
end)

-- ======================================================================
-- CERTIFICATION DEPTH (this pass) -- Part A §2/§5/§9, Part B §11.
-- ======================================================================

-- ----------------------------------------------------------------------
-- MIGRATION PATH: RefreshCertificationCache's tier/expiry metadata read
-- must degrade cleanly on a pre-migration-0006 database (columns don't
-- exist yet -- MySQL.single.await throws), and must correctly parse a
-- real metadata row once they do exist.
-- ----------------------------------------------------------------------

t.test('RefreshCertificationCache: MIGRATION PATH -- a throwing tier/expiry metadata query (pre-0006 schema) still succeeds active=true, defaults to tier=certified with no expiry', function()
    local f = newFixture()
    f.registerPlayer(1, 'CIT1', { name = 'police', grade = { level = 1 } })
    f.mysql.scalar.await = function() return 5 end -- existence check: active row confirmed
    f.mysql.single.await = function() error("unknown column 'tier' in 'field list' (simulated pre-migration-0006 schema)") end

    local active = f.env.RefreshCertificationCache('CIT1', 'police')

    t.isTrue(active, 'the base existence check must still succeed independent of the metadata query')
    t.isTrue(f.env.HasK9Access(1), 'access must not be affected by a metadata-read failure')
    t.equals(f.env.GetCertificationTier('CIT1', 'police'), 'certified', 'an unreadable tier must default to certified, never a less-privileged tier')
end)

t.test('RefreshCertificationCache: a real tier/expiry metadata row is parsed correctly into the cache', function()
    local f = newFixture()
    f.registerPlayer(1, 'CIT1', { name = 'police', grade = { level = 1 } })
    f.mysql.scalar.await = function() return 5 end
    f.mysql.single.await = function() return { tier = 'senior', expires_at_unix = 1700086400 } end -- 1 day after fixture's default nowUnix (1700000000)

    f.env.RefreshCertificationCache('CIT1', 'police')

    t.equals(f.env.GetCertificationTier('CIT1', 'police'), 'senior')
    t.isTrue(f.env.HasK9Access(1), 'not yet expired -- 1700086400 > nowUnix 1700000000')
end)

t.test('RefreshCertificationCache: an unrecognized tier value from the DB (data corruption) defaults to certified rather than an unranked string', function()
    local f = newFixture()
    f.registerPlayer(1, 'CIT1', { name = 'police', grade = { level = 1 } })
    f.mysql.scalar.await = function() return 5 end
    f.mysql.single.await = function() return { tier = 'not-a-real-tier', expires_at_unix = nil } end

    f.env.RefreshCertificationCache('CIT1', 'police')

    t.equals(f.env.GetCertificationTier('CIT1', 'police'), 'certified')
end)

-- ----------------------------------------------------------------------
-- EXPIRY BOUNDARIES
-- ----------------------------------------------------------------------

t.test('HasK9Access: EXPIRY BOUNDARY -- expiresAtUnix one second in the FUTURE still grants access', function()
    local f = newFixture()
    f.registerPlayer(1, 'CIT1', { name = 'police', grade = { level = 1 } })
    f.mysql.scalar.await = function() return 5 end
    f.mysql.single.await = function() return { tier = 'certified', expires_at_unix = 1700000001 } end -- nowUnix + 1
    f.env.RefreshCertificationCache('CIT1', 'police')
    t.isTrue(f.env.HasK9Access(1))
end)

t.test('HasK9Access: EXPIRY BOUNDARY -- expiresAtUnix EXACTLY equal to now is treated as expired (>=, not >)', function()
    local f = newFixture()
    f.registerPlayer(1, 'CIT1', { name = 'police', grade = { level = 1 } })
    f.mysql.scalar.await = function() return 5 end
    f.mysql.single.await = function() return { tier = 'certified', expires_at_unix = 1700000000 } end -- == nowUnix exactly
    f.env.RefreshCertificationCache('CIT1', 'police')
    t.isFalse(f.env.HasK9Access(1), 'the exact expiry second must already be treated as expired, not one grace second later')
end)

t.test('HasK9Access: EXPIRY BOUNDARY -- expiresAtUnix one second in the PAST is expired', function()
    local f = newFixture()
    f.registerPlayer(1, 'CIT1', { name = 'police', grade = { level = 1 } })
    f.mysql.scalar.await = function() return 5 end
    f.mysql.single.await = function() return { tier = 'certified', expires_at_unix = 1699999999 } end -- nowUnix - 1
    f.env.RefreshCertificationCache('CIT1', 'police')
    t.isFalse(f.env.HasK9Access(1))
end)

t.test('HasK9Access: an expired cert falls through to the autoAccessGrade bypass rather than hard-failing', function()
    local f = newFixture({ departments = {
        police = { label = 'Police', certifierGrade = 4, autoAccessGrade = 10 },
    } })
    f.registerPlayer(1, 'CIT1', { name = 'police', grade = { level = 10 } })
    f.mysql.scalar.await = function() return 5 end
    f.mysql.single.await = function() return { tier = 'certified', expires_at_unix = 1699999999 } end -- already expired
    f.env.RefreshCertificationCache('CIT1', 'police')
    t.isTrue(f.env.HasK9Access(1), 'grade 10 >= autoAccessGrade 10 must still bypass, independent of the expired cert')
end)

t.test('HasK9Access: EXPIRY -- a missing os.time() (environment anomaly) fails TOWARD availability, never toward lockout', function()
    local f = newFixture()
    f.registerPlayer(1, 'CIT1', { name = 'police', grade = { level = 1 } })
    f.mysql.scalar.await = function() return 5 end
    f.mysql.single.await = function() return { tier = 'certified', expires_at_unix = 1699999999 } end -- would be expired, IF os.time() were readable
    f.env.RefreshCertificationCache('CIT1', 'police')
    t.isFalse(f.env.HasK9Access(1), 'sanity: genuinely expired under the real os stub')

    -- Simulate os.time being entirely unavailable and re-refresh -- IsExpiredUnix
    -- must degrade to "not expired" rather than erroring or defaulting to locked-out.
    f.env.os = nil
    f.env.RefreshCertificationCache('CIT1', 'police')
    t.isTrue(f.env.HasK9Access(1), 'a missing os.time must never be indistinguishable from "definitely expired"')
end)

-- ----------------------------------------------------------------------
-- READ-ONLY ACCESSORS: GetCertificationTier / MeetsTierRequirement /
-- HasSpecialization
-- ----------------------------------------------------------------------

t.test('GetCertificationTier: nil for a citizenid with no active/matching cert', function()
    local f = newFixture()
    t.isNil(f.env.GetCertificationTier('NOBODY', 'police'))
end)

-- ----------------------------------------------------------------------
-- GetCertificationTier's `includeExpired` 3rd parameter (coder-security,
-- tier-bypass-on-expiry fix): server/certtiers.lua's TierCapabilityPermits'
-- own escape hatch for distinguishing a STALE tier assignment (a real,
-- active, job-matching row exists, but has expired) from NO tier
-- assignment at all (never certified for this job, or manually revoked).
-- Every 2-argument call site (every test above this block, and every real
-- consumer other than TierCapabilityPermits) is completely unaffected --
-- `includeExpired` defaults to nil/falsy, which is byte-for-byte the
-- original behavior.
-- ----------------------------------------------------------------------

t.test('GetCertificationTier(includeExpired=true): nil for a citizenid with no active/matching cert at all -- same as the 2-arg form', function()
    local f = newFixture()
    t.isNil(f.env.GetCertificationTier('NOBODY', 'police', true))
end)

t.test('GetCertificationTier(includeExpired=true): returns the real tier for an active, unexpired cert -- same as the 2-arg form', function()
    local f = newFixture()
    f.registerPlayer(1, 'CIT1', { name = 'police', grade = { level = 1 } })
    f.mysql.scalar.await = function() return 5 end
    f.mysql.single.await = function() return { tier = 'senior', expires_at_unix = 9999999999 } end
    f.env.RefreshCertificationCache('CIT1', 'police')

    t.equals(f.env.GetCertificationTier('CIT1', 'police', true), 'senior')
    t.equals(f.env.GetCertificationTier('CIT1', 'police'), 'senior', 'sanity: both agree while unexpired')
end)

t.test('GetCertificationTier(includeExpired=true): STILL returns the assigned tier once EXPIRED, unlike the 2-arg form -- this is the whole point of the fix', function()
    local f = newFixture()
    f.registerPlayer(1, 'CIT1', { name = 'police', grade = { level = 1 } })
    f.mysql.scalar.await = function() return 5 end
    f.mysql.single.await = function() return { tier = 'trainee', expires_at_unix = 1699999999 } end -- long since expired
    f.env.RefreshCertificationCache('CIT1', 'police')

    t.isNil(f.env.GetCertificationTier('CIT1', 'police'), 'the 2-arg form folds expiry into "no tier" for every OTHER consumer -- unchanged')
    t.equals(f.env.GetCertificationTier('CIT1', 'police', true), 'trainee',
        'but the underlying row DID assign a real tier -- `includeExpired = true` must not report it as unresolvable')
end)

t.test('GetCertificationTier(includeExpired=true): nil for a MANUALLY REVOKED cert (active = false) -- genuinely no tier, distinct from stale', function()
    local f = newFixture()
    f.registerPlayer(1, 'CIT1', { name = 'police', grade = { level = 1 } })
    f.mysql.scalar.await = function() return 5 end
    f.mysql.single.await = function() return { tier = 'senior', expires_at_unix = 9999999999 } end
    f.env.RefreshCertificationCache('CIT1', 'police')
    t.equals(f.env.GetCertificationTier('CIT1', 'police', true), 'senior', 'sanity: assigned while active')

    f.mysql.scalar.await = function() return nil end -- no active row any more -- revoked
    f.env.RefreshCertificationCache('CIT1', 'police')
    t.isNil(f.env.GetCertificationTier('CIT1', 'police', true),
        'a revoked (no longer active) row must be treated as no tier at all, never as "stale"')
end)

t.test('GetCertificationTier(includeExpired=true): nil when the cached job does not match the requested job', function()
    local f = newFixture()
    f.registerPlayer(1, 'CIT1', { name = 'police', grade = { level = 1 } })
    f.mysql.scalar.await = function() return 5 end
    f.mysql.single.await = function() return { tier = 'senior', expires_at_unix = 9999999999 } end
    f.env.RefreshCertificationCache('CIT1', 'police')

    t.isNil(f.env.GetCertificationTier('CIT1', 'ambulance', true), 'scoped to whichever job was last refreshed, exactly like the 2-arg form')
end)

t.test('MeetsTierRequirement: senior meets a certified requirement; trainee does not; an unrecognized minTier fails closed', function()
    local f = newFixture()
    f.registerPlayer(1, 'CIT1', { name = 'police', grade = { level = 1 } })
    f.mysql.scalar.await = function() return 5 end
    f.mysql.single.await = function() return { tier = 'senior' } end
    f.env.RefreshCertificationCache('CIT1', 'police')

    t.isTrue(f.env.MeetsTierRequirement('CIT1', 'police', 'certified'))
    t.isTrue(f.env.MeetsTierRequirement('CIT1', 'police', 'senior'))
    t.isFalse(f.env.MeetsTierRequirement('CIT1', 'police', 'not-a-real-tier'), 'an unrecognized minTier must never be treated as a low bar to clear')

    f.registerPlayer(2, 'CIT2', { name = 'police', grade = { level = 1 } })
    f.mysql.single.await = function() return { tier = 'trainee' } end
    f.env.RefreshCertificationCache('CIT2', 'police')
    t.isFalse(f.env.MeetsTierRequirement('CIT2', 'police', 'certified'))
end)

t.test('HasSpecialization: true only when BOTH the base cert is active/unexpired AND the specialization is active', function()
    local f = newFixture()
    f.registerPlayer(1, 'CIT1', { name = 'police', grade = { level = 1 } })
    f.mysql.scalar.await = function() return 5 end
    f.mysql.query.await = function() return { { specialization = 'narcotics' } } end
    f.env.RefreshCertificationCache('CIT1', 'police')

    t.isTrue(f.env.HasSpecialization('CIT1', 'police', 'narcotics'))
    t.isFalse(f.env.HasSpecialization('CIT1', 'police', 'explosives'), 'a specialization never granted must read false')
end)

t.test('HasSpecialization: an EXPIRED base cert soft-disables its specializations too, without any DB write', function()
    local f = newFixture()
    f.registerPlayer(1, 'CIT1', { name = 'police', grade = { level = 1 } })
    f.mysql.scalar.await = function() return 5 end
    f.mysql.single.await = function() return { tier = 'certified', expires_at_unix = 1699999999 } end -- expired
    f.mysql.query.await = function() return { { specialization = 'narcotics' } } end
    f.env.RefreshCertificationCache('CIT1', 'police')

    t.isFalse(f.env.HasK9Access(1), 'sanity: base cert is expired')
    t.isFalse(f.env.HasSpecialization('CIT1', 'police', 'narcotics'), 'the specialization row is still active in the DB but must read as unusable while the base cert is expired')
end)

-- ----------------------------------------------------------------------
-- HIGH COMMAND BYPASS (owner-directed "high command automatically gets
-- every k9 upgrade" pass) -- MeetsTierRequirement and HasSpecialization
-- both now consult server/permissions.lua's IsHighCommandBypassCitizenId,
-- a soft dependency set directly on `f.env` (this file's own established
-- pattern -- see the existing `f.env.IsHighCommand = ...` precedent
-- elsewhere in this spec) rather than booting server/permissions.lua for
-- real.
-- ----------------------------------------------------------------------

t.test('HIGH COMMAND BYPASS: MeetsTierRequirement is satisfied for a high-command officer who holds no certification at all', function()
    local f = newFixture()
    -- CIT1 has NO certification row whatsoever -- MeetsTierRequirement
    -- fails closed for this citizenid on every ordinary path (its own doc
    -- comment: "fails closed on a nil actual tier").
    f.env.IsHighCommandBypassCitizenId = function(citizenid, jobName) return citizenid == 'HC-OFFICER' and jobName == 'police' end

    t.isFalse(f.env.MeetsTierRequirement('ORDINARY_UNCERTIFIED', 'police', 'senior'), 'control: an ordinary uncertified citizenid is still denied')
    t.isTrue(f.env.MeetsTierRequirement('HC-OFFICER', 'police', 'senior'), 'high command must clear a minimum-tier bar they never personally certified for')
end)

t.test('HIGH COMMAND BYPASS: MeetsTierRequirement still fails closed for high command on an unrecognized minTier -- never a way to paper over a caller bug', function()
    local f = newFixture()
    f.env.IsHighCommandBypassCitizenId = function(citizenid, _jobName) return citizenid == 'HC-OFFICER' end

    t.isFalse(f.env.MeetsTierRequirement('HC-OFFICER', 'police', 'not-a-real-tier'))
end)

t.test('HIGH COMMAND BYPASS: HasSpecialization is satisfied for a high-command officer who was never granted it and holds no active certification', function()
    local f = newFixture()
    f.env.IsHighCommandBypassCitizenId = function(citizenid, jobName) return citizenid == 'HC-OFFICER' and jobName == 'police' end

    t.isFalse(f.env.HasSpecialization('ORDINARY_UNCERTIFIED', 'police', 'narcotics'), 'control: an ordinary uncertified citizenid is still denied')
    t.isTrue(f.env.HasSpecialization('HC-OFFICER', 'police', 'narcotics'), 'high command must hold a specialization "k9 upgrade" they never personally earned')
end)

t.test('HIGH COMMAND BYPASS: an OFFLINE citizenid (or one who is simply not high command) gets no bypass -- real resolution, unaffected', function()
    local f = newFixture()
    f.registerPlayer(1, 'CIT1', { name = 'police', grade = { level = 1 } })
    f.mysql.scalar.await = function() return 5 end
    f.mysql.single.await = function() return { tier = 'trainee' } end
    f.env.RefreshCertificationCache('CIT1', 'police')
    f.env.IsHighCommandBypassCitizenId = function(_citizenid, _jobName) return false end -- mirrors the real function's own offline/not-high-command answer

    t.isFalse(f.env.MeetsTierRequirement('CIT1', 'police', 'certified'))
    t.isFalse(f.env.HasSpecialization('CIT1', 'police', 'narcotics'))
end)

t.test('HIGH COMMAND BYPASS: soft dependency -- MeetsTierRequirement/HasSpecialization behave exactly as before when IsHighCommandBypassCitizenId is entirely absent', function()
    local f = newFixture()
    t.isNil(f.env.IsHighCommandBypassCitizenId, 'this fixture genuinely has no IsHighCommandBypassCitizenId defined by default')

    t.isFalse(f.env.MeetsTierRequirement('ANYONE', 'police', 'senior'))
    t.isFalse(f.env.HasSpecialization('ANYONE', 'police', 'narcotics'))
end)

-- ----------------------------------------------------------------------
-- SetCertificationTier
-- ----------------------------------------------------------------------

t.test('SetCertificationTier: FAIL-CLOSED -- a granter who is not certifier-eligible is rejected', function()
    local f = newFixture()
    f.registerPlayer(1, 'G1', { name = 'police', grade = { level = 1 } }) -- below certifierGrade 4, not boss
    f.registerPlayer(2, 'T1', { name = 'police', grade = { level = 1 } })
    f.commands['k9settier'].fn(1, { '2', 'senior' })
    t.isTrue(notifiedExactly(f, 1, localeWithPendingCertKeys('certifications.not_authorized_to_certify_hint'), 'error'))
end)

t.test('SetCertificationTier: FAIL-CLOSED -- an invalid tier name is rejected outright, before any MySQL call', function()
    local f = newFixture()
    f.registerPlayer(1, 'G1', { name = 'police', isboss = true })
    f.registerPlayer(2, 'T1', { name = 'police', grade = { level = 1 } })
    f.setPed(1, 100, vec3(0, 0, 0))
    f.setPed(2, 200, vec3(0, 0, 0))
    local updateCalled = false
    f.mysql.update.await = function() updateCalled = true; return 1 end
    f.commands['k9settier'].fn(1, { '2', 'not-a-real-tier' })
    t.isTrue(notifiedExactly(f, 1, Sandbox.locale('certifications.invalid_tier'), 'error'))
    t.isFalse(updateCalled)
end)

t.test('SetCertificationTier: FAIL-CLOSED -- self-action is rejected when Config.AllowSelfCertification is false', function()
    local f = newFixture({ allowSelfCert = false })
    f.registerPlayer(1, 'G1', { name = 'police', isboss = true })
    f.commands['k9settier'].fn(1, { '1', 'senior' })
    t.isTrue(notifiedExactly(f, 1, localeWithPendingCertKeys('certifications.self_certification_disabled_hint'), 'error'))
end)

t.test('SetCertificationTier: FAIL-CLOSED -- an offline target is rejected', function()
    local f = newFixture()
    f.registerPlayer(1, 'G1', { name = 'police', isboss = true })
    f.commands['k9settier'].fn(1, { '2', 'senior' })
    t.isTrue(notifiedExactly(f, 1, localeWithPendingCertKeys('certifications.tier_change_target_must_be_online_hint'), 'error'))
end)

t.test('SetCertificationTier: FAIL-CLOSED -- a target beyond Config.CertifyProximityMeters is rejected', function()
    local f = newFixture({ proximityMeters = 5.0 })
    f.registerPlayer(1, 'G1', { name = 'police', isboss = true })
    f.registerPlayer(2, 'T1', { name = 'police', grade = { level = 1 } })
    f.setPed(1, 1010, vec3(0, 0, 0))
    f.setPed(2, 1020, vec3(50, 0, 0))
    f.commands['k9settier'].fn(1, { '2', 'senior' })
    t.isTrue(notifiedExactly(f, 1, localeWithPendingCertKeys('certifications.action_target_too_far_distance', tostring(5.0)), 'error'))
end)

t.test('SetCertificationTier: FAIL-CLOSED -- a target with no active certification for their current job is rejected', function()
    local f = newFixture()
    f.registerPlayer(1, 'G1', { name = 'police', isboss = true })
    f.registerPlayer(2, 'T1', { name = 'police', grade = { level = 1 } }) -- never certified
    f.setPed(1, 1010, vec3(0, 0, 0))
    f.setPed(2, 1020, vec3(0, 0, 0))
    f.commands['k9settier'].fn(1, { '2', 'senior' })
    t.isTrue(notifiedExactly(f, 1, localeWithPendingCertKeys('certifications.target_not_actively_certified_needs_cert'), 'error'))
end)

t.test('SetCertificationTier: already holding the requested tier is a distinguishable no-op', function()
    local f = newFixture()
    f.registerPlayer(1, 'G1', { name = 'police', isboss = true })
    f.registerPlayer(2, 'T1', { name = 'police', grade = { level = 1 } })
    f.setPed(1, 1010, vec3(0, 0, 0))
    f.setPed(2, 1020, vec3(0, 0, 0))
    f.mysql.scalar.await = function() return 5 end
    f.mysql.single.await = function() return { tier = 'certified' } end
    f.env.RefreshCertificationCache('T1', 'police')
    f.commands['k9settier'].fn(1, { '2', 'certified' })
    t.isTrue(notifiedExactly(f, 1, Sandbox.locale('certifications.tier_already_set'), 'inform'))
end)

t.test('SetCertificationTier: TIER TRANSITION -- full success path promotes certified -> senior, updates the cache, notifies both parties, fires the outbound event', function()
    local f = newFixture()
    f.registerPlayer(10, 'GRANTER', { name = 'police', isboss = true })
    f.registerPlayer(20, 'TARGET', { name = 'police', grade = { level = 1 } })
    f.setPed(10, 1010, vec3(0, 0, 0))
    f.setPed(20, 1020, vec3(0, 0, 0))
    f.mysql.scalar.await = function() return 5 end
    f.mysql.single.await = function() return { tier = 'certified' } end
    f.env.RefreshCertificationCache('TARGET', 'police')
    t.equals(f.env.GetCertificationTier('TARGET', 'police'), 'certified', 'sanity')

    local updateParams
    f.mysql.update.await = function(_sql, params) updateParams = params; return 1 end
    f.mysql.single.await = function() return { tier = 'senior' } end -- post-update re-cache reflects the new tier

    f.commands['k9settier'].fn(10, { '20', 'senior' })

    t.equals(updateParams[1], 'senior')
    t.equals(updateParams[2], 'TARGET')
    t.equals(updateParams[3], 'police')
    t.equals(f.env.GetCertificationTier('TARGET', 'police'), 'senior', 'the cache must reflect the promotion immediately')
    t.isTrue(notifiedExactly(f, 10, Sandbox.locale('certifications.tier_change_success_granter', 'senior'), 'success'))
    t.isTrue(notifiedExactly(f, 20, Sandbox.locale('certifications.tier_change_success_target', 'senior'), 'success'))

    local fired = false
    for _, ev in ipairs(f.outboundEvents) do
        if ev[1] == 'qbx_k9unit:events:certificationTierChanged' and ev[2] == 'TARGET' and ev[3] == 'police' and ev[4] == 'certified' and ev[5] == 'senior' and ev[6] == 'GRANTER' then fired = true end
    end
    t.isTrue(fired)
end)

t.test('SetCertificationTier: TIER TRANSITION -- demotion certified -> trainee also succeeds (a non-punitive refresher, not a revoke)', function()
    local f = newFixture()
    f.registerPlayer(10, 'GRANTER', { name = 'police', isboss = true })
    f.registerPlayer(20, 'TARGET', { name = 'police', grade = { level = 1 } })
    f.setPed(10, 1010, vec3(0, 0, 0))
    f.setPed(20, 1020, vec3(0, 0, 0))
    f.mysql.scalar.await = function() return 5 end
    f.mysql.single.await = function() return { tier = 'certified' } end
    f.env.RefreshCertificationCache('TARGET', 'police')

    f.mysql.single.await = function() return { tier = 'trainee' } end
    f.commands['k9settier'].fn(10, { '20', 'trainee' })

    t.equals(f.env.GetCertificationTier('TARGET', 'police'), 'trainee')
    t.isTrue(f.env.HasK9Access(20), 'a trainee still holds BASE K9 access -- tiering only gates higher capability, never base access')
end)

t.test('SetCertificationTier: a thrown UPDATE reports tier_change_error, never a silent success', function()
    local f = newFixture()
    f.registerPlayer(10, 'GRANTER', { name = 'police', isboss = true })
    f.registerPlayer(20, 'TARGET', { name = 'police', grade = { level = 1 } })
    f.setPed(10, 1010, vec3(0, 0, 0))
    f.setPed(20, 1020, vec3(0, 0, 0))
    f.mysql.scalar.await = function() return 5 end
    f.mysql.single.await = function() return { tier = 'certified' } end
    f.env.RefreshCertificationCache('TARGET', 'police')

    f.mysql.update.await = function() error('simulated connection drop') end
    local ok = pcall(f.commands['k9settier'].fn, 10, { '20', 'senior' })
    t.isTrue(ok, 'must never propagate a thrown DB error')
    t.isTrue(notifiedExactly(f, 10, Sandbox.locale('certifications.tier_change_error'), 'error'))
    t.equals(f.env.GetCertificationTier('TARGET', 'police'), 'certified', 'the cache must be untouched by a failed update')
end)

-- ----------------------------------------------------------------------
-- REGRESSION (data-truth audit pass, finding #2): K9Store.Cert_SetTier is
-- a bare `WHERE citizenid = ? AND job = ? AND active = 1` UPDATE (NOT
-- itself pcall-wrapped in server/datastore.lua) -- when a concurrent
-- decertify/job-change/second tier change lands between this function's
-- own in-memory-cache entry gate and the UPDATE's own commit, the WHERE
-- clause matches ZERO rows and MySQL throws NOTHING for that. The
-- pre-existing code discarded the affected-row count entirely (only
-- checked pcall's own true/false), so this exact case reported a bare
-- success to both parties while nothing in the DB had changed. Mirrors
-- RevokeCertification's own identical two-sided REGRESSION coverage
-- immediately above in this file (zero-affected-rows, and a thrown error
-- that actually committed).
-- ----------------------------------------------------------------------

t.test('SetCertificationTier: REGRESSION -- a zero-affected-rows UPDATE (no thrown error) reports target_not_actively_certified, never a silent success', function()
    local f = newFixture()
    f.registerPlayer(10, 'GRANTER', { name = 'police', isboss = true })
    f.registerPlayer(20, 'TARGET', { name = 'police', grade = { level = 1 } })
    f.setPed(10, 1010, vec3(0, 0, 0))
    f.setPed(20, 1020, vec3(0, 0, 0))
    f.mysql.scalar.await = function() return 5 end
    f.mysql.single.await = function() return { tier = 'certified' } end
    f.env.RefreshCertificationCache('TARGET', 'police')
    t.equals(f.env.GetCertificationTier('TARGET', 'police'), 'certified', 'sanity')

    -- A concurrent decertify/job-change landed between the entry gate's
    -- cache read and this UPDATE's own commit -- WHERE ... active = 1
    -- matches nothing, and no error is thrown for that.
    f.mysql.update.await = function() return 0 end
    -- RefreshCertificationCache's own post-write re-query now sees the
    -- row as genuinely gone.
    f.mysql.scalar.await = function() return nil end

    local ok = pcall(f.commands['k9settier'].fn, 10, { '20', 'senior' })
    t.isTrue(ok, 'must never propagate')

    t.isTrue(notifiedExactly(f, 10, localeWithPendingCertKeys('certifications.target_not_actively_certified_needs_cert'), 'error'), 'the granter must be told the tier change did not land, never a bare success')
    t.isNil(lastNotifyFor(f, 20), 'the target must NOT be told their tier changed -- it genuinely did not')
    t.isFalse(f.env.HasK9Access(20), 'the cache must reflect the CONFIRMED true outcome (no longer certified), never keep pretending the old tier is still current')
    t.equals(#f.outboundEvents, 0, 'no outbound certificationTierChanged event for a tier change that did not actually land')
end)

t.test('SetCertificationTier: REGRESSION -- a throwing UPDATE that ACTUALLY committed (ack lost after a real commit) is confirmed via reconciliation and reported as the genuine success it was', function()
    local f = newFixture()
    f.registerPlayer(10, 'GRANTER', { name = 'police', isboss = true })
    f.registerPlayer(20, 'TARGET', { name = 'police', grade = { level = 1 } })
    f.setPed(10, 1010, vec3(0, 0, 0))
    f.setPed(20, 1020, vec3(0, 0, 0))
    f.mysql.scalar.await = function() return 5 end
    f.mysql.single.await = function() return { tier = 'certified' } end
    f.env.RefreshCertificationCache('TARGET', 'police')

    f.mysql.update.await = function() error('simulated ack lost after a real commit') end
    -- The reconciliation read (QueryCertificationRecord) AND the
    -- post-write RefreshCertificationCache both now see the NEW tier --
    -- confirming the UPDATE actually committed despite the client-side
    -- error.
    f.mysql.single.await = function() return { tier = 'senior' } end

    local ok, err = pcall(f.commands['k9settier'].fn, 10, { '20', 'senior' })
    t.isTrue(ok, 'must not propagate: ' .. tostring(err))

    t.equals(f.env.GetCertificationTier('TARGET', 'police'), 'senior', 'the cache must reflect the CONFIRMED true outcome, never the failed client-side call alone')
    t.isTrue(notifiedExactly(f, 10, Sandbox.locale('certifications.tier_change_success_granter', 'senior'), 'success'), 'the granter must see a real success, not an error, once reconciliation confirms the DB truth')
    t.isTrue(notifiedExactly(f, 20, Sandbox.locale('certifications.tier_change_success_target', 'senior'), 'success'))
end)

-- COMMAND CONSOLIDATION (docs/history/COMMAND_CONSOLIDATION_SPEC.md §2/§5 item 8):
-- /k9settier is now a dispatcher, same shape as /k9certify/k9decertify above.
t.test('/k9settier command: a non-numeric args[1] is treated as an offline citizenid attempt, not rejected -- routes to SetCertificationTierOffline unchanged, args shifted by one for the tier', function()
    local f = newFixture()
    f.registerPlayer(1, 'G1', { name = 'police', isboss = true })
    f.mysql.single.await = function() return { tier = 'certified', expires_at_unix = nil } end

    local updateParams
    f.mysql.update.await = function(_sql, params) updateParams = params; return 1 end

    f.commands['k9settier'].fn(1, { 'OFFLINE_CIT', 'police', 'senior' })

    t.equals(updateParams[1], 'senior')
    t.equals(updateParams[2], 'OFFLINE_CIT')
    t.equals(updateParams[3], 'police')
end)

t.test('/k9settier command: a totally bare command shows the COMBINED usage string', function()
    local f = newFixture()
    f.registerPlayer(1, 'G1', { name = 'police', isboss = true })
    f.commands['k9settier'].fn(1, {})
    t.isTrue(notifiedExactly(f, 1, Sandbox.locale('certifications.usage_settier'), 'error'))
end)

t.test('MERGED: /k9settier with a citizenid re-tiers an offline handler', function()
    local f = newFixture()
    f.registerPlayer(1, 'G1', { name = 'police', isboss = true })
    f.mysql.single.await = function() return { tier = 'certified', expires_at_unix = nil } end
    local updateParams
    f.mysql.update.await = function(_sql, params) updateParams = params; return 1 end

    f.commands['k9settier'].fn(1, { 'T1', 'police', 'senior' })

    t.equals(updateParams[2], 'T1')
    t.equals(updateParams[3], 'police')
end)

-- ----------------------------------------------------------------------
-- RenewCertification
-- ----------------------------------------------------------------------

-- REACHED VIA THE TABLET CALLBACK, not a command. /k9recertify was deleted
-- in the 2026-09-02 merge, and the merged /k9certify deliberately does NOT
-- route to renew while expiry is off (it falls through to grant, for the
-- honest hint -- see the MERGE tests above). The tablet callback is the
-- surviving entry point to RenewCertification's own gates, so these two
-- FAIL-CLOSED tests go through it rather than through a command that would
-- never reach the function they are about.
t.test('RenewCertification: FAIL-CLOSED -- disabled by default (Config.Features.CertificationExpiry absent) is rejected outright', function()
    -- CommandTablet on so the callback is registered; expiry deliberately
    -- left OFF, which is the thing under test.
    local f = newFixture({ features = { CommandTablet = true } })
    f.registerPlayer(1, 'G1', { name = 'police', isboss = true })
    f.registerPlayer(2, 'T1', { name = 'police', grade = { level = 1 } })
    local result = f.callbacks['qbx_k9unit:server:tabletRenewCertification'](1, 'T1', 'police')
    t.isFalse(result.ok, 'renewal must be refused outright while the expiry feature is off')
end)

t.test('RenewCertification: FAIL-CLOSED -- a granter who is not certifier-eligible is rejected even with the feature enabled', function()
    local f = newFixture({ features = { CertificationExpiry = true, CommandTablet = true }, expiryDays = 90 })
    f.registerPlayer(1, 'G1', { name = 'police', grade = { level = 1 } })
    f.registerPlayer(2, 'T1', { name = 'police', grade = { level = 1 } })
    local result = f.callbacks['qbx_k9unit:server:tabletRenewCertification'](1, 'T1', 'police')
    t.isFalse(result.ok, 'a caller who is not certifier-eligible must be refused')
end)

-- VIA THE TABLET CALLBACK, deliberately. The merged /k9certify routes an
-- uncertified target to GRANT -- that IS the merge -- so it can no longer
-- reach this renew-side refusal, and asserting it through the command would
-- test the grant path while claiming to test renew.
t.test('RenewCertification: FAIL-CLOSED -- a target with no active certification is rejected', function()
    local f = newFixture({ features = { CertificationExpiry = true, CommandTablet = true }, expiryDays = 90 })
    f.registerPlayer(1, 'G1', { name = 'police', isboss = true })
    f.registerPlayer(2, 'T1', { name = 'police', grade = { level = 1 } })
    f.setPed(1, 1010, vec3(0, 0, 0))
    f.setPed(2, 1020, vec3(0, 0, 0))
    local result = f.callbacks['qbx_k9unit:server:tabletRenewCertification'](1, 'T1', 'police')
    t.isFalse(result.ok, 'renewing someone who holds no active certification must be refused')
end)

t.test('RenewCertification: EXPIRY -- full success path extends expires_at via DATE_ADD(NOW(), INTERVAL ? DAY), refreshes the cache, clears the warned/lapsed flags, fires the outbound event', function()
    local f = newFixture({ features = { CertificationExpiry = true }, expiryDays = 90 })
    f.registerPlayer(10, 'GRANTER', { name = 'police', isboss = true })
    f.registerPlayer(20, 'TARGET', { name = 'police', grade = { level = 1 } })
    f.setPed(10, 1010, vec3(0, 0, 0))
    f.setPed(20, 1020, vec3(0, 0, 0))
    f.mysql.scalar.await = function() return 5 end
    f.mysql.single.await = function() return { tier = 'certified', expires_at_unix = 1700000100 } end -- near-expiry
    f.env.RefreshCertificationCache('TARGET', 'police')

    local updateParams
    f.mysql.update.await = function(_sql, params) updateParams = params; return 1 end
    f.mysql.single.await = function() return { tier = 'certified', expires_at_unix = 1707776000 } end -- ~90 days out, post-renewal

    f.commands['k9certify'].fn(10, { '20' })

    t.equals(updateParams[1], 90)
    t.equals(updateParams[2], 'TARGET')
    t.equals(updateParams[3], 'police')
    -- WORKFLOW CLARITY (this pass, item 5 -- "renewing says what changed"):
    -- state.nowUnix (1700000000) to the new expiresAtUnix (1707776000) is
    -- exactly 90 days -- both success notices now say so explicitly.
    t.isTrue(notifiedExactly(f, 10, localeWithPendingCertKeys('certifications.renew_success_granter_detail', '90'), 'success'))
    t.isTrue(notifiedExactly(f, 20, localeWithPendingCertKeys('certifications.renew_success_target_detail', '90'), 'success'))

    local fired = false
    for _, ev in ipairs(f.outboundEvents) do
        if ev[1] == 'qbx_k9unit:events:certificationRenewed' and ev[2] == 'TARGET' and ev[3] == 'police' and ev[4] == 1707776000 and ev[5] == 'GRANTER' then fired = true end
    end
    t.isTrue(fired)
end)

t.test('RenewCertification: a thrown UPDATE reports renew_error, never a silent success', function()
    local f = newFixture({ features = { CertificationExpiry = true }, expiryDays = 90 })
    f.registerPlayer(10, 'GRANTER', { name = 'police', isboss = true })
    f.registerPlayer(20, 'TARGET', { name = 'police', grade = { level = 1 } })
    f.setPed(10, 1010, vec3(0, 0, 0))
    f.setPed(20, 1020, vec3(0, 0, 0))
    f.mysql.scalar.await = function() return 5 end
    f.mysql.single.await = function() return { tier = 'certified' } end
    f.env.RefreshCertificationCache('TARGET', 'police')

    f.mysql.update.await = function() error('simulated connection drop') end
    local ok = pcall(f.commands['k9certify'].fn, 10, { '20' })
    t.isTrue(ok)
    t.isTrue(notifiedExactly(f, 10, Sandbox.locale('certifications.renew_error'), 'error'))
end)

-- ----------------------------------------------------------------------
-- REGRESSION (data-truth audit pass, this pass, coder-backend) -- the SAME
-- defect already fixed in SetCertificationTier/SetCertificationTierOffline
-- (see either's own REGRESSION coverage above), reached through
-- RenewCertification instead: this function used to check only whether the
-- pcall wrapping K9Store.Cert_RenewExpiry ITSELF threw, never whether the
-- UPDATE it wrapped actually matched a row. Cert_RenewExpiry is a bare
-- `WHERE citizenid = ? AND job = ? AND active = 1` UPDATE (NOT itself
-- pcall-wrapped in server/datastore.lua) -- when a concurrent decertify/
-- job-change lands between this function's own in-memory-cache entry gate
-- and the UPDATE's own commit, the WHERE clause matches ZERO rows and
-- MySQL throws NOTHING for that. The test immediately above only ever
-- covers the THROWN-error path -- this pair covers the path that would
-- have actually caught the shipped bug (a thrown-nothing, zero-row UPDATE
-- reported as an unconditional success), plus the mirrored "thrown but
-- actually committed" case for symmetry with RevokeCertification/
-- SetCertificationTier's own two-sided coverage.
-- ----------------------------------------------------------------------

t.test('RenewCertification: REGRESSION -- a zero-affected-rows UPDATE (no thrown error) reports target_not_actively_certified, never a silent success', function()
    local f = newFixture({ features = { CertificationExpiry = true }, expiryDays = 90 })
    f.registerPlayer(10, 'GRANTER', { name = 'police', isboss = true })
    f.registerPlayer(20, 'TARGET', { name = 'police', grade = { level = 1 } })
    f.setPed(10, 1010, vec3(0, 0, 0))
    f.setPed(20, 1020, vec3(0, 0, 0))
    f.mysql.scalar.await = function() return 5 end
    f.mysql.single.await = function() return { tier = 'certified', expires_at_unix = 1700000100 } end -- near-expiry, entry-gate cache baseline
    f.env.RefreshCertificationCache('TARGET', 'police')

    -- A concurrent decertify/job-change landed between the entry gate's
    -- cache read and this UPDATE's own commit -- WHERE ... active = 1
    -- matches nothing, and no error is thrown for that (pcall reports
    -- true, 0 -- this is the exact case the pre-fix code discarded).
    f.mysql.update.await = function() return 0 end
    -- RefreshCertificationCache's own post-write re-query now sees the
    -- row as genuinely gone.
    f.mysql.scalar.await = function() return nil end

    local ok = pcall(f.commands['k9certify'].fn, 10, { '20' })
    t.isTrue(ok, 'must never propagate')

    t.isTrue(notifiedExactly(f, 10, localeWithPendingCertKeys('certifications.target_not_actively_certified_needs_cert'), 'error'), 'the granter must be told the renewal did not land, never a bare success')
    t.isNil(lastNotifyFor(f, 20), 'the target must NOT be told they were renewed -- it genuinely did not happen')
    t.equals(#f.outboundEvents, 0, 'no outbound certificationRenewed event for a renewal that did not actually land')
end)

t.test('RenewCertification: REGRESSION -- a throwing UPDATE that ACTUALLY committed (ack lost after a real commit) is confirmed via reconciliation and reported as the genuine success it was', function()
    local f = newFixture({ features = { CertificationExpiry = true }, expiryDays = 90 })
    f.registerPlayer(10, 'GRANTER', { name = 'police', isboss = true })
    f.registerPlayer(20, 'TARGET', { name = 'police', grade = { level = 1 } })
    f.setPed(10, 1010, vec3(0, 0, 0))
    f.setPed(20, 1020, vec3(0, 0, 0))
    f.mysql.scalar.await = function() return 5 end
    f.mysql.single.await = function() return { tier = 'certified', expires_at_unix = 1700000100 } end -- near-expiry, entry-gate cache baseline
    f.env.RefreshCertificationCache('TARGET', 'police')

    f.mysql.update.await = function() error('simulated ack lost after a real commit') end
    -- The reconciliation read (QueryCertificationRecord) AND the post-write
    -- RefreshCertificationCache both now see a LATER expiry than the
    -- baseline above -- confirming the UPDATE actually committed despite
    -- the client-side error.
    f.mysql.single.await = function() return { tier = 'certified', expires_at_unix = 1707776000 } end -- ~90 days out, post-renewal

    local ok, err = pcall(f.commands['k9certify'].fn, 10, { '20' })
    t.isTrue(ok, 'must not propagate: ' .. tostring(err))

    t.isTrue(notifiedExactly(f, 10, localeWithPendingCertKeys('certifications.renew_success_granter_detail', '90'), 'success'), 'the granter must see a real success, not an error, once reconciliation confirms the DB truth')
    t.isTrue(notifiedExactly(f, 20, localeWithPendingCertKeys('certifications.renew_success_target_detail', '90'), 'success'))
end)

t.test('MERGED: /k9certify with a citizenid renews an offline handler', function()
    local f = newFixture({ features = { CertificationExpiry = true }, expiryDays = 90 })
    f.registerPlayer(1, 'G1', { name = 'police', isboss = true })
    f.mysql.single.await = function() return { tier = 'certified', expires_at_unix = 1700000000 } end

    local updateCalled = false
    f.mysql.update.await = function() updateCalled = true; return 1 end

    f.commands['k9certify'].fn(1, { 'T1', 'police' })

    t.isTrue(updateCalled)
end)

-- ----------------------------------------------------------------------
-- GrantSpecialization / RevokeSpecialization / RevokeSpecializationOffline
-- ----------------------------------------------------------------------

t.test('GrantSpecialization: FAIL-CLOSED -- an unconfigured specialization key is rejected outright', function()
    local f = newFixture()
    f.registerPlayer(1, 'G1', { name = 'police', isboss = true })
    f.registerPlayer(2, 'T1', { name = 'police', grade = { level = 1 } })
    f.setPed(1, 100, vec3(0, 0, 0))
    f.setPed(2, 200, vec3(0, 0, 0))
    f.commands['k9specialize'].fn(1, { '2', 'not-a-real-specialization' })
    t.isTrue(notifiedExactly(f, 1, localeWithPendingCertKeys('certifications.invalid_specialization_hint', 'explosives, narcotics'), 'error'))
end)

t.test('GrantSpecialization: FAIL-CLOSED -- a target with no active base certification is rejected', function()
    local f = newFixture()
    f.registerPlayer(1, 'G1', { name = 'police', isboss = true })
    f.registerPlayer(2, 'T1', { name = 'police', grade = { level = 1 } })
    f.setPed(1, 100, vec3(0, 0, 0))
    f.setPed(2, 200, vec3(0, 0, 0))
    f.commands['k9specialize'].fn(1, { '2', 'narcotics' })
    t.isTrue(notifiedExactly(f, 1, localeWithPendingCertKeys('certifications.specialization_requires_active_cert_hint'), 'error'))
end)

t.test('GrantSpecialization: SECURITY FIX -- a target whose base certification is EXPIRED (active=true in the DB, but past expires_at) is also rejected, matching GetCertificationTier', function()
    local f = newFixture()
    f.registerPlayer(1, 'G1', { name = 'police', isboss = true })
    f.registerPlayer(2, 'T1', { name = 'police', grade = { level = 1 } })
    f.setPed(1, 100, vec3(0, 0, 0))
    f.setPed(2, 200, vec3(0, 0, 0))
    f.mysql.scalar.await = function() return 5 end -- active=true in the DB (never revoked)...
    f.mysql.single.await = function() return { tier = 'trainee', expires_at_unix = 1699999999 } end -- ...but long since expired
    f.env.RefreshCertificationCache('T1', 'police')
    t.isNil(f.env.GetCertificationTier('T1', 'police'), 'sanity: GetCertificationTier already treats this as no tier')

    local insertCalled = false
    f.mysql.insert.await = function() insertCalled = true; return 1 end

    f.commands['k9specialize'].fn(1, { '2', 'narcotics' })

    t.isTrue(notifiedExactly(f, 1, localeWithPendingCertKeys('certifications.specialization_requires_active_cert_hint'), 'error'),
        'this precondition used to omit `not cached.expired`, unlike GetCertificationTier -- an expired-but-not-revoked row must be refused here too, not treated as still-active')
    t.isFalse(insertCalled, 'must never reach the INSERT for an expired base certification')
end)

t.test('GrantSpecialization: full success path -- INSERT fires, cache reflects the grant, both parties notified, outbound event fired', function()
    local f = newFixture()
    f.registerPlayer(10, 'GRANTER', { name = 'police', isboss = true })
    f.registerPlayer(20, 'TARGET', { name = 'police', grade = { level = 1 } })
    f.setPed(10, 1010, vec3(0, 0, 0))
    f.setPed(20, 1020, vec3(0, 0, 0))
    f.mysql.scalar.await = function() return 5 end -- active base cert
    f.env.RefreshCertificationCache('TARGET', 'police')

    local scalarCallCount = 0
    f.mysql.scalar.await = function()
        scalarCallCount = scalarCallCount + 1
        return nil -- pre-check: no existing active specialization row
    end
    local insertParams
    f.mysql.insert.await = function(_sql, params) insertParams = params; return 1 end
    f.mysql.query.await = function() return { { specialization = 'narcotics' } } end -- post-insert cache refresh

    f.commands['k9specialize'].fn(10, { '20', 'narcotics' })

    t.equals(insertParams[1], 'TARGET')
    t.equals(insertParams[2], 'police')
    t.equals(insertParams[3], 'narcotics')
    t.equals(insertParams[4], 'GRANTER')
    t.isTrue(f.env.HasSpecialization('TARGET', 'police', 'narcotics'))
    t.isTrue(notifiedExactly(f, 10, Sandbox.locale('certifications.specialization_grant_success_granter', 'narcotics'), 'success'))
    t.isTrue(notifiedExactly(f, 20, Sandbox.locale('certifications.specialization_grant_success_target', 'narcotics'), 'success'))

    local fired = false
    for _, ev in ipairs(f.outboundEvents) do
        if ev[1] == 'qbx_k9unit:events:specializationGranted' and ev[2] == 'TARGET' and ev[3] == 'police' and ev[4] == 'narcotics' and ev[5] == 'GRANTER' then fired = true end
    end
    t.isTrue(fired)
end)

t.test('GrantSpecialization: an already-held specialization (existingId pre-check) is rejected as a no-op, never reaches the INSERT', function()
    local f = newFixture()
    f.registerPlayer(10, 'GRANTER', { name = 'police', isboss = true })
    f.registerPlayer(20, 'TARGET', { name = 'police', grade = { level = 1 } })
    f.setPed(10, 1010, vec3(0, 0, 0))
    f.setPed(20, 1020, vec3(0, 0, 0))
    f.mysql.scalar.await = function() return 5 end
    f.env.RefreshCertificationCache('TARGET', 'police')

    f.mysql.scalar.await = function() return 99 end -- existing active specialization row
    local insertCalled = false
    f.mysql.insert.await = function() insertCalled = true; return 1 end

    f.commands['k9specialize'].fn(10, { '20', 'narcotics' })

    t.isTrue(notifiedExactly(f, 10, Sandbox.locale('certifications.specialization_already_granted'), 'inform'))
    t.isFalse(insertCalled)
end)

t.test('GrantSpecialization: a duplicate-key error thrown by the INSERT is treated as the same "already granted" no-op', function()
    local f = newFixture()
    f.registerPlayer(10, 'GRANTER', { name = 'police', isboss = true })
    f.registerPlayer(20, 'TARGET', { name = 'police', grade = { level = 1 } })
    f.setPed(10, 1010, vec3(0, 0, 0))
    f.setPed(20, 1020, vec3(0, 0, 0))
    f.mysql.scalar.await = function() return 5 end
    f.env.RefreshCertificationCache('TARGET', 'police')

    f.mysql.scalar.await = function() return nil end
    f.mysql.insert.await = function() error({ errno = 1062, message = 'Duplicate entry' }) end

    f.commands['k9specialize'].fn(10, { '20', 'narcotics' })

    t.isTrue(notifiedExactly(f, 10, Sandbox.locale('certifications.specialization_already_granted'), 'inform'))
end)

-- ----------------------------------------------------------------------
-- GrantSpecialization TOCTOU (concurrency audit, reproduced): the
-- `cached.active`/`cached.job`/`not cached.expired` precondition is read
-- ONCE, synchronously, BEFORE GrantInFlight[lockKey] is set and BEFORE
-- doGrantInsert's own two genuinely-yielding MySQL awaits
-- (K9Store.Spec_GetActiveId, K9Store.Spec_Insert) ever run. A concurrent
-- RevokeCertification's own DB write (K9Store.Cert_RevokeActive) is
-- itself a real yield point that can commit -- and refresh the cache --
-- entirely inside that window. Reproduced here with the SAME
-- yielding-MySQL-stub-through-a-real-coroutine technique as the
-- GrantCertification GrantInFlight test above (see that test's own
-- header for why this is the only way to prove a genuine interleaving,
-- not just test-harness luck). LOAD-BEARING.
-- ----------------------------------------------------------------------

t.test('GrantSpecialization: LOAD-BEARING TOCTOU -- a RevokeCertification that commits WHILE a concurrent GrantSpecialization is suspended inside its own pre-check await must not leave a granted specialization row behind', function()
    local f = newFixture()
    f.registerPlayer(10, 'SPEC-GRANTER', { name = 'police', isboss = true })
    f.registerPlayer(11, 'REVOKER', { name = 'police', isboss = true })
    f.registerPlayer(20, 'TARGET', { name = 'police', grade = { level = 1 } })
    f.setPed(10, 1010, vec3(0, 0, 0))
    f.setPed(11, 1011, vec3(0, 0, 0))
    f.setPed(20, 1020, vec3(0, 0, 0))

    -- Warm the cache with a genuinely active base certification for
    -- TARGET BEFORE any of the race stubs below are installed -- an
    -- ordinary, non-yielding refresh, exactly like every other test in
    -- this file.
    f.mysql.scalar.await = function() return 5 end
    f.env.RefreshCertificationCache('TARGET', 'police')
    t.isTrue(f.env.GetCertificationTier('TARGET', 'police') ~= nil, 'sanity: TARGET starts genuinely certified')

    local insertCalled = false
    f.mysql.insert.await = function(_sql, _params)
        insertCalled = true
        return 1
    end

    -- Distinguishes GrantSpecialization's own pre-check
    -- (K9Store.Spec_GetActiveId, table k9_certification_specializations)
    -- from RevokeCertification's post-revoke cache-refresh read
    -- (K9Store.Cert_GetActiveId, table k9_certifications) -- ONLY the
    -- former yields, modeling the real coroutine suspension point a
    -- genuine oxmysql round trip would be. The latter must resolve
    -- immediately so the revoke below runs start-to-finish as a single,
    -- ordinary call, exactly matching the report's "officer A's revoke
    -- commits" step (this test needs the RACE to be genuine only on the
    -- grant side -- RevokeCertification's own concurrency is already
    -- covered elsewhere).
    f.mysql.scalar.await = function(sql, _params)
        if sql:find('k9_certification_specializations', 1, true) then
            coroutine.yield()
            return nil -- no pre-existing active specialization row
        end
        return nil -- Cert_GetActiveId during the revoke's own cache refresh: confirmed inactive
    end

    local coGrant = coroutine.create(function()
        f.commands['k9specialize'].fn(10, { '20', 'narcotics' })
    end)

    -- Run the specialization grant up to its FIRST yield -- this is the
    -- point in real FXServer where GrantSpecialization's ONE-TIME,
    -- synchronous `cached.active` precondition has already passed and
    -- GrantInFlight[lockKey] is already set, and the coroutine is now
    -- suspended awaiting the pre-check SELECT.
    local ok1, err1 = coroutine.resume(coGrant)
    t.isTrue(ok1, tostring(err1))
    t.equals(coroutine.status(coGrant), 'suspended', 'the grant must be paused mid-flight at the specialization pre-check await')

    -- Officer B's revoke now runs to completion, entirely underneath the
    -- suspended grant above -- a plain, ordinary call (this side of the
    -- race never yields for this test, matching the report's "A's revoke
    -- commits" step).
    f.commands['k9decertify'].fn(11, { '20' })
    t.isTrue(notifiedExactly(f, 11, Sandbox.locale('certifications.revoke_success'), 'success'), 'sanity: the revoke must have genuinely committed')
    t.isNil(f.env.GetCertificationTier('TARGET', 'police'), 'sanity: the cache must already reflect the revoke before the grant resumes')

    -- Resume the grant -- drains every remaining yield until it finishes.
    while coroutine.status(coGrant) ~= 'dead' do
        local ok, err = coroutine.resume(coGrant)
        t.isTrue(ok, tostring(err))
    end

    t.isFalse(insertCalled, 'the INSERT must never run once the target has been decertified underneath the in-flight grant')
    t.isFalse(f.env.HasSpecialization('TARGET', 'police', 'narcotics'), 'no specialization row may exist for a target decertified mid-grant')
    t.isTrue(notifiedExactly(f, 10, localeWithPendingCertKeys('certifications.specialization_requires_active_cert_hint'), 'error'),
        'the granter must see the same "requires active cert" refusal a fresh, non-racing attempt against an already-decertified target would get -- not a false "granted" success')
end)

-- ======================================================================
-- TIER CAPABILITIES (coordinator-assigned, this pass): server/certtiers.lua's
-- TierCapabilityPermits(citizenid, jobName, capabilityKey) had zero real
-- consumers anywhere in this resource before this pass -- GrantSpecialization
-- is now one of the two. Fail-PERMISSIVE by design (see that function's
-- own doc comment, server/certtiers.lua): allow unless the capability is
-- ACTIVELY granted by at least one tier AND this citizenid's own resolved
-- tier is not among them. THE ONE CASE THIS SPEC CANNOT PIN YET: "capability
-- active and the target's tier lacks it -> grant refused" reaches a BRAND
-- NEW locale key, `certifications.specialization_requires_tier_capability`,
-- proposed to and not yet added by whoever owns locales/en.json (this file
-- never stubs `locale`, so that branch would raise "locale key missing"
-- until it lands -- see this file's own header for why locale is never
-- faked here). The two cases below that do NOT reach that key are pinned
-- now; the refusal case is reported, not silently skipped.
-- ======================================================================

t.test('GrantSpecialization: TIER CAPABILITY -- consulted with (targetCitizenid, jobName, \'specializations_eligible\') AFTER the active-cert check passes, and a tier that HOLDS the capability still grants normally', function()
    local f = newFixture()
    f.registerPlayer(10, 'GRANTER', { name = 'police', isboss = true })
    f.registerPlayer(20, 'TARGET', { name = 'police', grade = { level = 1 } })
    f.setPed(10, 1010, vec3(0, 0, 0))
    f.setPed(20, 1020, vec3(0, 0, 0))
    f.mysql.scalar.await = function() return 5 end -- active base cert
    f.env.RefreshCertificationCache('TARGET', 'police')

    local capturedArgs
    f.env.TierCapabilityPermits = function(citizenid, jobName, capabilityKey)
        capturedArgs = { citizenid, jobName, capabilityKey }
        return true -- this tier HOLDS the capability
    end

    f.mysql.scalar.await = function() return nil end -- pre-check: no existing active specialization row
    local insertParams
    f.mysql.insert.await = function(_sql, params) insertParams = params; return 1 end
    f.mysql.query.await = function() return { { specialization = 'narcotics' } } end

    f.commands['k9specialize'].fn(10, { '20', 'narcotics' })

    t.equals(capturedArgs[1], 'TARGET')
    t.equals(capturedArgs[2], 'police')
    t.equals(capturedArgs[3], 'specializations_eligible')
    t.equals(insertParams[1], 'TARGET', 'a tier that holds the capability must not block the grant')
    t.isTrue(f.env.HasSpecialization('TARGET', 'police', 'narcotics'))
end)

t.test('GrantSpecialization: TIER CAPABILITY -- the runtime existence guard genuinely tolerates TierCapabilityPermits being entirely absent (server/certtiers.lua not loaded), failing OPEN to the ordinary grant path', function()
    local f = newFixture()
    f.registerPlayer(10, 'GRANTER', { name = 'police', isboss = true })
    f.registerPlayer(20, 'TARGET', { name = 'police', grade = { level = 1 } })
    f.setPed(10, 1010, vec3(0, 0, 0))
    f.setPed(20, 1020, vec3(0, 0, 0))
    f.mysql.scalar.await = function() return 5 end
    f.env.RefreshCertificationCache('TARGET', 'police')

    -- TierCapabilityPermits deliberately left undefined -- f.env never sets
    -- it (this spec never loads server/certtiers.lua at all), mirroring a
    -- server that never shipped/loaded that file.
    t.isNil(f.env.TierCapabilityPermits)

    f.mysql.scalar.await = function() return nil end
    local insertParams
    f.mysql.insert.await = function(_sql, params) insertParams = params; return 1 end
    f.mysql.query.await = function() return { { specialization = 'narcotics' } } end

    f.commands['k9specialize'].fn(10, { '20', 'narcotics' })

    t.equals(insertParams[1], 'TARGET', 'a missing TierCapabilityPermits must fail OPEN, never block every grant on every server that predates tier capabilities')
end)

t.test('/k9specialize command: a non-numeric args[1] is rejected with the usage message', function()
    local f = newFixture()
    f.registerPlayer(1, 'G1', { name = 'police', isboss = true })
    f.commands['k9specialize'].fn(1, { 'not-a-number', 'narcotics' })
    t.isTrue(notifiedExactly(f, 1, Sandbox.locale('certifications.usage_specialize'), 'error'))
end)

t.test('RevokeSpecialization: FAIL-CLOSED -- a granter who is not certifier-eligible is rejected', function()
    local f = newFixture()
    f.registerPlayer(1, 'G1', { name = 'police', grade = { level = 1 } })
    f.registerPlayer(2, 'T1', { name = 'police', grade = { level = 1 } })
    f.commands['k9unspecialize'].fn(1, { '2', 'narcotics' })
    t.isTrue(notifiedExactly(f, 1, localeWithPendingCertKeys('certifications.not_authorized_to_revoke_hint'), 'error'))
end)

t.test('RevokeSpecialization: an offline target is refused with a pointer to the offline command', function()
    local f = newFixture()
    f.registerPlayer(1, 'G1', { name = 'police', isboss = true })
    f.commands['k9unspecialize'].fn(1, { '2', 'narcotics' })
    t.isTrue(notifiedExactly(f, 1, Sandbox.locale('certifications.specialization_target_offline_use_offline_command'), 'error'))
end)

t.test('RevokeSpecialization: full online success path -- UPDATE fires, cache refreshed, outbound event reason is manual', function()
    local f = newFixture()
    f.registerPlayer(10, 'REVOKER', { name = 'police', isboss = true })
    f.registerPlayer(20, 'TARGET', { name = 'police', grade = { level = 1 } })
    f.setPed(10, 1010, vec3(0, 0, 0))
    f.setPed(20, 1020, vec3(0, 0, 0))

    local updateParams
    f.mysql.update.await = function(_sql, params) updateParams = params; return 1 end
    f.mysql.query.await = function() return {} end -- post-revoke cache refresh: no active specializations left

    f.commands['k9unspecialize'].fn(10, { '20', 'narcotics' })

    t.equals(updateParams[1], 'REVOKER')
    t.equals(updateParams[2], 'TARGET')
    t.equals(updateParams[3], 'police')
    t.equals(updateParams[4], 'narcotics')
    t.isTrue(notifiedExactly(f, 10, Sandbox.locale('certifications.specialization_revoke_success_granter', 'narcotics'), 'success'))
    t.isTrue(notifiedExactly(f, 20, Sandbox.locale('certifications.specialization_revoke_success_target', 'narcotics'), 'error'))

    local fired = false
    for _, ev in ipairs(f.outboundEvents) do
        if ev[1] == 'qbx_k9unit:events:specializationRevoked' and ev[4] == 'narcotics' and ev[5] == 'manual' then fired = true end
    end
    t.isTrue(fired)
end)

t.test('RevokeSpecialization: a specialization not currently held is a distinguishable no-op', function()
    local f = newFixture()
    f.registerPlayer(10, 'REVOKER', { name = 'police', isboss = true })
    f.registerPlayer(20, 'TARGET', { name = 'police', grade = { level = 1 } })
    f.setPed(10, 1010, vec3(0, 0, 0))
    f.setPed(20, 1020, vec3(0, 0, 0))
    f.mysql.update.await = function() return 0 end
    f.commands['k9unspecialize'].fn(10, { '20', 'narcotics' })
    t.isTrue(notifiedExactly(f, 10, Sandbox.locale('certifications.specialization_not_granted'), 'inform'))
end)

t.test('RevokeSpecializationOffline: full offline success path -- UPDATE fires, outbound event reason is manual_offline', function()
    local f = newFixture()
    f.registerPlayer(10, 'REVOKER', { name = 'police', isboss = true })
    -- TARGET intentionally never registered -- genuinely offline.
    local updateParams
    f.mysql.update.await = function(_sql, params) updateParams = params; return 1 end
    f.mysql.query.await = function() return {} end

    f.commands['k9unspecialize'].fn(10, { 'TARGET', 'police', 'narcotics' })

    t.equals(updateParams[1], 'REVOKER')
    t.equals(updateParams[2], 'TARGET')
    t.equals(updateParams[3], 'police')
    t.equals(updateParams[4], 'narcotics')
    t.isTrue(notifiedExactly(f, 10, Sandbox.locale('certifications.specialization_revoke_success_granter', 'narcotics'), 'success'))

    local fired = false
    for _, ev in ipairs(f.outboundEvents) do
        if ev[1] == 'qbx_k9unit:events:specializationRevoked' and ev[5] == 'manual_offline' then fired = true end
    end
    t.isTrue(fired)
end)

t.test('RevokeSpecializationOffline: SECURITY -- refuses outright when the "offline" citizenid is actually online right now', function()
    local f = newFixture()
    f.registerPlayer(10, 'REVOKER', { name = 'police', isboss = true })
    f.registerPlayer(20, 'ACTUALLY-ONLINE', { name = 'police', grade = { level = 1 } })
    local updateCalled = false
    f.mysql.update.await = function() updateCalled = true; return 1 end
    f.commands['k9unspecialize'].fn(10, { 'ACTUALLY-ONLINE', 'police', 'narcotics' })
    t.isTrue(notifiedExactly(f, 10, Sandbox.locale('certifications.specialization_target_online_use_online_command', 20), 'error'))
    t.isFalse(updateCalled)
end)

t.test('RevokeSpecializationOffline: a typo\'d/unconfigured department is rejected outright', function()
    local f = newFixture()
    f.registerPlayer(10, 'REVOKER', { name = 'police', isboss = true })
    f.commands['k9unspecialize'].fn(10, { 'SOMEONE', 'not-a-real-department', 'narcotics' })
    t.isTrue(notifiedExactly(f, 10, localeWithPendingCertKeys('certifications.invalid_department_hint', 'not-a-real-department', 'police, sheriff'), 'error'))
end)

-- COMMAND CONSOLIDATION (docs/history/COMMAND_CONSOLIDATION_SPEC.md §2/§5 item 8):
-- /k9unspecialize is now a dispatcher, same shape as the others above.
-- /k9specialize (grant) has NO offline counterpart at all and is
-- deliberately left untouched -- see this file's own new comment above its
-- RegisterCommand call.
t.test('/k9unspecialize command: a non-numeric args[1] is treated as an offline citizenid attempt, not rejected -- routes to RevokeSpecializationOffline unchanged, args shifted by one for the specialization key', function()
    local f = newFixture()
    f.registerPlayer(1, 'G1', { name = 'police', isboss = true })

    local updateParams
    f.mysql.update.await = function(_sql, params) updateParams = params; return 1 end
    f.mysql.query.await = function() return {} end

    f.commands['k9unspecialize'].fn(1, { 'OFFLINE_CIT', 'police', 'narcotics' })

    t.equals(updateParams[2], 'OFFLINE_CIT')
    t.equals(updateParams[3], 'police')
    t.equals(updateParams[4], 'narcotics')
end)

t.test('/k9unspecialize command: a totally bare command shows the COMBINED usage string', function()
    local f = newFixture()
    f.registerPlayer(1, 'G1', { name = 'police', isboss = true })
    f.commands['k9unspecialize'].fn(1, {})
    t.isTrue(notifiedExactly(f, 1, Sandbox.locale('certifications.usage_unspecialize'), 'error'))
end)

t.test('MERGED: /k9unspecialize with a citizenid revokes from an offline handler', function()
    local f = newFixture()
    f.registerPlayer(1, 'G1', { name = 'police', isboss = true })
    local updateParams
    f.mysql.update.await = function(_sql, params) updateParams = params; return 1 end
    f.mysql.query.await = function() return {} end

    f.commands['k9unspecialize'].fn(1, { 'T1', 'police', 'narcotics' })

    t.equals(updateParams[2], 'T1')
    t.equals(updateParams[3], 'police')
    t.equals(updateParams[4], 'narcotics')
end)

t.test('/k9unspecialize (offline shape): a missing specialization argument is rejected with the usage message', function()
    local f = newFixture()
    f.registerPlayer(10, 'REVOKER', { name = 'police', isboss = true })
    f.commands['k9unspecialize'].fn(10, { 'SOMEONE', 'police' }) -- args[3] missing
    t.isTrue(notifiedExactly(f, 10, Sandbox.locale('certifications.usage_unspecialize'), 'error'))
end)

-- ----------------------------------------------------------------------
-- SPECIALIZATION CASCADE: a specialization must not outlive the base
-- certification it requires.
-- ----------------------------------------------------------------------

t.test('RevokeCertification: CASCADE -- revoking the base certification also revokes every active specialization for that (citizenid, job)', function()
    local f = newFixture()
    f.registerPlayer(10, 'REVOKER', { name = 'police', isboss = true })
    f.registerPlayer(20, 'REVOKEE', { name = 'police', grade = { level = 1 } })
    f.setPed(10, 1010, vec3(0, 0, 0))
    f.setPed(20, 1020, vec3(0, 0, 0))

    f.mysql.scalar.await = function() return 5 end
    f.mysql.query.await = function() return { { specialization = 'narcotics' } } end
    f.env.RefreshCertificationCache('REVOKEE', 'police')
    t.isTrue(f.env.HasSpecialization('REVOKEE', 'police', 'narcotics'), 'sanity: specialization active before the revoke')

    local specUpdateParams
    f.mysql.update.await = function(sql, params)
        if sql:find('k9_certification_specializations', 1, true) then
            specUpdateParams = params
        end
        return 1
    end
    f.mysql.scalar.await = function() return nil end -- post-revoke base-cert re-cache: no active row

    f.setSource(10)
    f.events['qbx_k9unit:server:revokeHandler'](20)

    -- The cascade UPDATE is a BULK revoke over every active row for
    -- (citizenid, job) -- no `specialization = ?` filter, only 3 bound
    -- params -- unlike a single-specialization RevokeSpecialization call.
    t.isNotNil(specUpdateParams, 'the specialization cascade UPDATE must have fired')
    t.equals(specUpdateParams[1], 'REVOKER')
    t.equals(specUpdateParams[2], 'REVOKEE')
    t.equals(specUpdateParams[3], 'police')

    local fired = false
    for _, ev in ipairs(f.outboundEvents) do
        if ev[1] == 'qbx_k9unit:events:specializationRevoked' and ev[2] == 'REVOKEE' and ev[3] == 'police' and ev[4] == 'narcotics' and ev[5] == 'certification_revoked' then fired = true end
    end
    t.isTrue(fired)
end)

t.test('RevokeCertificationOffline: CASCADE -- revoking an offline citizenid\'s base certification also revokes their active specializations (DB-authoritative, not cache-dependent)', function()
    local f = newFixture()
    f.registerPlayer(10, 'REVOKER', { name = 'police', isboss = true })
    -- REVOKEE never registered -- genuinely offline, so its Specializations
    -- cache entry was never populated either -- proves the cascade reads the
    -- DB directly rather than relying on the in-memory cache (see
    -- RevokeAllSpecializationsForCitizenJob's own doc comment).
    local specUpdateParams
    f.mysql.update.await = function(sql, params)
        if sql:find('k9_certification_specializations', 1, true) then
            specUpdateParams = params
        end
        return 1
    end
    f.mysql.query.await = function() return { { specialization = 'explosives' } } end
    f.mysql.scalar.await = function() return nil end

    f.commands['k9decertify'].fn(10, { 'REVOKEE', 'police' })

    t.isNotNil(specUpdateParams, 'the specialization cascade UPDATE must have fired for the offline path too')
    t.equals(specUpdateParams[1], 'REVOKER')
    t.equals(specUpdateParams[2], 'REVOKEE')
    t.equals(specUpdateParams[3], 'police')

    local fired = false
    for _, ev in ipairs(f.outboundEvents) do
        if ev[1] == 'qbx_k9unit:events:specializationRevoked' and ev[4] == 'explosives' and ev[5] == 'certification_revoked' then fired = true end
    end
    t.isTrue(fired)
end)

t.test('OnJobUpdate: CASCADE -- a real department change also revokes every active specialization for the OLD (citizenid, job)', function()
    local f = newFixture()
    f.registerPlayer(40, 'CIT40', { name = 'police', grade = { level = 1 } })
    f.mysql.scalar.await = function() return 9 end
    f.mysql.query.await = function() return { { specialization = 'narcotics' } } end
    f.env.RefreshCertificationCache('CIT40', 'police')

    local specUpdateParams
    f.mysql.update.await = function(sql, params)
        if sql:find('k9_certification_specializations', 1, true) then
            specUpdateParams = params
        end
        return 1
    end
    f.mysql.scalar.await = function() return nil end

    fireJobUpdate(f, 40, { name = 'sheriff', grade = { level = 1 } })

    t.isNotNil(specUpdateParams)
    t.equals(specUpdateParams[1], 'system:job_change')
    t.equals(specUpdateParams[2], 'CIT40')
    t.equals(specUpdateParams[3], 'police')
end)

t.test('RevokeAllSpecializationsForCitizenJob: no active specializations means no UPDATE at all -- common case is a cheap no-op', function()
    local f = newFixture()
    f.registerPlayer(10, 'REVOKER', { name = 'police', isboss = true })
    f.registerPlayer(20, 'REVOKEE', { name = 'police', grade = { level = 1 } })
    f.setPed(10, 1010, vec3(0, 0, 0))
    f.setPed(20, 1020, vec3(0, 0, 0))
    f.mysql.scalar.await = function() return 5 end
    f.env.RefreshCertificationCache('REVOKEE', 'police') -- no specializations seeded -- query.await defaults to {}

    local specUpdateCalled = false
    f.mysql.update.await = function(sql, params)
        if sql:find('k9_certification_specializations', 1, true) then specUpdateCalled = true end
        return 1
    end
    f.mysql.scalar.await = function() return nil end

    f.setSource(10)
    f.events['qbx_k9unit:server:revokeHandler'](20)

    t.isFalse(specUpdateCalled, 'no specialization UPDATE should run when the pre-read finds nothing active')
end)

-- ----------------------------------------------------------------------
-- EXPIRY WARNING SWEEP
-- ----------------------------------------------------------------------

t.test('TickCertificationExpiryWarnings: warns an online handler once within the warning window, then never again the same session', function()
    local f = newFixture({ features = { CertificationExpiry = true }, expiryDays = 90, expiryWarningDays = 7 })
    local target = f.registerPlayer(20, 'TARGET', { name = 'police', grade = { level = 1 } })
    f.mysql.scalar.await = function() return 5 end
    -- 3 days remaining (259200s) -- inside the 7-day warning window.
    f.mysql.single.await = function() return { tier = 'certified', expires_at_unix = 1700000000 + 259200 } end
    f.env.RefreshCertificationCache('TARGET', 'police')

    -- Prime, then run one full sweep pass (fixtures/sandbox.lua's own
    -- newThreadRunner convention: the first step() only reaches the
    -- initial Wait()).
    f.threadRunner.step()
    f.threadRunner.step()

    t.isTrue(notifiedExactly(f, 20, Sandbox.locale('certifications.expiry_warning', '3'), 'inform'))

    local warnCountAfterFirst = 0
    for _, e in ipairs(f.notifyLog) do
        if e.source == 20 then warnCountAfterFirst = warnCountAfterFirst + 1 end
    end

    f.threadRunner.step() -- a second sweep pass, same session
    local warnCountAfterSecond = 0
    for _, e in ipairs(f.notifyLog) do
        if e.source == 20 then warnCountAfterSecond = warnCountAfterSecond + 1 end
    end
    t.equals(warnCountAfterSecond, warnCountAfterFirst, 'a second sweep pass in the same session must not re-warn')
    t.isNotNil(target) -- silence unused-var lint
end)

t.test('TickCertificationExpiryWarnings: proactively announces a JUST-LAPSED certification once, never every tick', function()
    local f = newFixture({ features = { CertificationExpiry = true }, expiryDays = 90 })
    f.registerPlayer(20, 'TARGET', { name = 'police', grade = { level = 1 } })
    f.mysql.scalar.await = function() return 5 end
    f.mysql.single.await = function() return { tier = 'certified', expires_at_unix = 1699999999 } end -- already lapsed
    f.env.RefreshCertificationCache('TARGET', 'police')

    f.threadRunner.step()
    f.threadRunner.step()
    t.isTrue(notifiedExactly(f, 20, Sandbox.locale('certifications.expiry_lapsed_notice'), 'error'))

    local lapsedCount = 0
    for _, e in ipairs(f.notifyLog) do
        if e.source == 20 and e.message == Sandbox.locale('certifications.expiry_lapsed_notice') then lapsedCount = lapsedCount + 1 end
    end
    f.threadRunner.step()
    local lapsedCountAfter = 0
    for _, e in ipairs(f.notifyLog) do
        if e.source == 20 and e.message == Sandbox.locale('certifications.expiry_lapsed_notice') then lapsedCountAfter = lapsedCountAfter + 1 end
    end
    t.equals(lapsedCountAfter, lapsedCount, 'the lapsed notice must fire at most once per session')
end)

t.test('RenewCertification: clears the warned/lapsed session flags so a genuinely renewed handler can be warned again on its own future merits', function()
    local f = newFixture({ features = { CertificationExpiry = true }, expiryDays = 90 })
    f.registerPlayer(10, 'GRANTER', { name = 'police', isboss = true })
    f.registerPlayer(20, 'TARGET', { name = 'police', grade = { level = 1 } })
    f.setPed(10, 1010, vec3(0, 0, 0))
    f.setPed(20, 1020, vec3(0, 0, 0))
    f.mysql.scalar.await = function() return 5 end
    f.mysql.single.await = function() return { tier = 'certified', expires_at_unix = 1699999999 } end -- lapsed
    f.env.RefreshCertificationCache('TARGET', 'police')

    f.threadRunner.step()
    f.threadRunner.step()
    t.isTrue(notifiedExactly(f, 20, Sandbox.locale('certifications.expiry_lapsed_notice'), 'error'), 'sanity: lapsed notice sent once')

    f.mysql.single.await = function() return { tier = 'certified', expires_at_unix = 1707776000 } end -- renewed, far future
    f.commands['k9certify'].fn(10, { '20' })

    local lapsedCountAfterRenewal = 0
    for _, e in ipairs(f.notifyLog) do
        if e.source == 20 and e.message == Sandbox.locale('certifications.expiry_lapsed_notice') then lapsedCountAfterRenewal = lapsedCountAfterRenewal + 1 end
    end

    -- Simulate a SECOND, later lapse (e.g. the renewal's own new deadline
    -- eventually passes too) and confirm the flag genuinely resets rather
    -- than staying permanently silenced by the FIRST lapse this session.
    f.mysql.single.await = function() return { tier = 'certified', expires_at_unix = 1699999999 } end
    f.env.RefreshCertificationCache('TARGET', 'police')
    f.threadRunner.step()

    local lapsedCountAfterSecondLapse = 0
    for _, e in ipairs(f.notifyLog) do
        if e.source == 20 and e.message == Sandbox.locale('certifications.expiry_lapsed_notice') then lapsedCountAfterSecondLapse = lapsedCountAfterSecondLapse + 1 end
    end
    t.equals(lapsedCountAfterSecondLapse, lapsedCountAfterRenewal + 1, 'a renewal must clear the one-per-session lapsed flag so a genuinely NEW lapse can be announced again')
end)

-- ----------------------------------------------------------------------
-- CONCURRENCY-AUDIT FIX (this pass): Config.CertificationExpiryCheckIntervalMs
-- validation, mirroring server/tenure.lua's own IDENTICAL checkIntervalMs
-- fix -- see that file's own doc comment (immediately above its
-- checkIntervalMs CreateThread registration) for the full writeup, and
-- this file's own equivalent comment above its own CreateThread
-- registration for why the same fix applies here at lower severity (this
-- sweep is cache-only, never a live SQL query -- see this section's own
-- header). The OLD `rawIntervalMs > 0` check accepted a hand-edited `1`
-- exactly as readily as a sane `300000`, entirely bypassing the K9
-- Command Tablet's own 30000-3600000ms bound for this exact field (a
-- bound enforced ONLY by the tablet's own UI, never re-verified here) and
-- the shared 250ms floor server/cooldowns.lua's ResolveConfiguredThresholdMs
-- already enforces for every other Config-sourced interval in this
-- resource -- now delegated to that same function instead.
--
-- SHARED-THREADRUNNER NOTE: with Config.Features.CertificationExpiry on
-- (every test below), server/certifications/'s file scope registers
-- FOUR separate CreateThread loops onto this ONE fixture-wide
-- threadRunner, in this exact registration order: (1) CertifyXpMintCooldown's
-- 24h StartSweep cleanup (unconditional, registered first, near this
-- file's top), (2) FARM FIX (this pass): CertifyNewGrantSlotCooldown's own
-- 24h StartSweep cleanup (unconditional, registered immediately after (1),
-- right next to CertifyXpMintKey -- see that section's own header), (3)
-- THIS section's own expiry-check thread (registered third, only when the
-- feature above is on), and (4) the always-on unresolved-certification
-- resync sweep (registered fourth, unconditional, 30000ms). fixtures/
-- sandbox.lua's own newThreadRunner.step() resumes every registered
-- thread once per call, in registration order, so the four threads'
-- captured Wait() values interleave 1:1:1:1 in the SAME f.waitCalls array
-- -- expiryThreadWaitCalls() below isolates just this section's own
-- thread's captures (position 3 of every 4) so each test can assert on
-- ITS OWN thread's interval without the other three, unrelated threads'
-- fixed 86400000/86400000/30000 values ever being mistaken for a
-- regression here.
-- ----------------------------------------------------------------------

--- @param f table -- a newFixture() result
--- @return table -- just this section's expiry-check thread's own captured Wait() ms values, in order
local function expiryThreadWaitCalls(f)
    local out = {}
    for i = 3, #f.waitCalls, 4 do out[#out + 1] = f.waitCalls[i] end
    return out
end

--- @param f table
--- @param substr string
--- @return number -- how many f.printLog entries contain `substr`
local function countPrintedLinesContaining(f, substr)
    local count = 0
    for _, line in ipairs(f.printLog) do
        if line:find(substr, 1, true) then count = count + 1 end
    end
    return count
end

t.test('CONCURRENCY-AUDIT FIX: CertificationExpiryCheckIntervalMs = 0 never reaches Wait() directly -- the real 300000ms fallback is used instead, with a loud warning naming the key', function()
    -- NOTE on count: threadRunner.step() both PRIMES (one Wait() call,
    -- reaching the very first loop iteration) and STEPS (one more Wait()
    -- call, after the first real TickCertificationExpiryWarnings pass
    -- loops back to the top) -- see fixtures/sandbox.lua's own
    -- newThreadRunner doc comment, and tests/tenure_spec.lua's own
    -- identical convention for the equivalent tenure thread.
    local f = newFixture({ features = { CertificationExpiry = true }, expiryCheckIntervalMs = 0 })
    f.threadRunner.step()
    f.threadRunner.step()
    local calls = expiryThreadWaitCalls(f)
    t.equals(#calls, 2)
    t.equals(calls[1], 300000, 'a 0 checkIntervalMs must never be passed straight to Wait() directly')
    t.equals(calls[2], 300000, 'the fallback must apply on every loop pass, not just the first')
    t.equals(countPrintedLinesContaining(f, 'CertificationExpiryCheckIntervalMs'), 2, 'one warning per validation pass, matching the 2 captured Wait() calls above')
end)

t.test('CONCURRENCY-AUDIT FIX: CertificationExpiryCheckIntervalMs = 1 (a valid, POSITIVE number, but below the shared 250ms floor) is ALSO caught now -- the old `> 0` check let this straight through completely unclamped', function()
    local f = newFixture({ features = { CertificationExpiry = true }, expiryCheckIntervalMs = 1 })
    f.threadRunner.step()
    f.threadRunner.step()
    local calls = expiryThreadWaitCalls(f)
    t.equals(calls[1], 300000, 'a sub-250ms positive value must never reach Wait() verbatim -- it must resolve to the safe fallback like every other bad shape')
    t.equals(calls[2], 300000)
    t.isTrue(countPrintedLinesContaining(f, 'CertificationExpiryCheckIntervalMs') > 0)
    t.isTrue(countPrintedLinesContaining(f, '(1)') > 0, 'the warning must name the actual bad value found, not just say "invalid"')
end)

t.test('CONCURRENCY-AUDIT FIX: CertificationExpiryCheckIntervalMs exactly AT the shared 250ms floor is used verbatim, no warning -- the floor is inclusive, not exclusive', function()
    local f = newFixture({ features = { CertificationExpiry = true }, expiryCheckIntervalMs = 250 })
    f.threadRunner.step()
    f.threadRunner.step()
    local calls = expiryThreadWaitCalls(f)
    t.equals(calls[1], 250)
    t.equals(calls[2], 250)
    t.equals(countPrintedLinesContaining(f, 'CertificationExpiryCheckIntervalMs'), 0)
end)

t.test('CertificationExpiryCheckIntervalMs entirely MISSING falls back silently too -- no warning, matching this resource\'s established "not configured yet" convention', function()
    local f = newFixture({ features = { CertificationExpiry = true } }) -- expiryCheckIntervalMs omitted -> nil
    f.threadRunner.step()
    f.threadRunner.step()
    local calls = expiryThreadWaitCalls(f)
    t.equals(calls[1], 300000)
    t.equals(calls[2], 300000)
    t.equals(countPrintedLinesContaining(f, 'CertificationExpiryCheckIntervalMs'), 0, 'a merely-absent field is not the same as a present-but-bad one -- must stay silent')
end)

t.test('A VALID, positive CertificationExpiryCheckIntervalMs is used exactly as configured, with no warning', function()
    local f = newFixture({ features = { CertificationExpiry = true }, expiryCheckIntervalMs = 45000 })
    f.threadRunner.step()
    f.threadRunner.step()
    local calls = expiryThreadWaitCalls(f)
    t.equals(calls[1], 45000, 'the real configured value must be used verbatim, not silently overridden by the fallback')
    t.equals(calls[2], 45000)
    t.equals(countPrintedLinesContaining(f, 'CertificationExpiryCheckIntervalMs'), 0)
end)

t.test('CONCURRENCY-AUDIT FIX: the CertificationExpiryCheckIntervalMs warning repeats once per pass against a persistently-broken config, never a flood -- the same ResolveConfiguredThresholdMs call is what sets the fallback Wait() uses, so a repeat can only land once per full 300000ms fallback interval', function()
    local f = newFixture({ features = { CertificationExpiry = true }, expiryCheckIntervalMs = 0 })
    f.threadRunner.step() -- prime (1 Wait call)
    f.threadRunner.step() -- + 1 step (1 more Wait call) = 2 total
    f.threadRunner.step() -- + 1 more step = 3 total
    f.threadRunner.step() -- + 1 more step = 4 total
    local calls = expiryThreadWaitCalls(f)
    t.equals(#calls, 4)
    t.equals(countPrintedLinesContaining(f, 'CertificationExpiryCheckIntervalMs'), 4, 'one warning per validation pass -- each one only fires after the FULL 300000ms fallback interval the previous pass already selected, never faster')
    for i = 1, #calls do
        t.equals(calls[i], 300000, 'the fallback keeps applying on every single loop pass, not just the first')
    end
end)

-- ======================================================================
-- K9 COMMAND TABLET -- TIER / RENEWAL / SPECIALIZATION / OFFLINE CERTIFY
-- (this pass). SetCertificationTierForTablet/RenewCertificationForTablet/
-- GrantSpecializationForTablet/RevokeSpecializationForTablet, plus
-- GrantCertificationForTablet's own newly-added offline branch, and their
-- five lib.callback.register entries -- registered only when
-- Config.Features.CommandTablet == true. Reached here the SAME way
-- tabletserver_spec.lua reaches tabletRequestMyRecord/etc: through
-- f.callbacks[name](source, ...), which returns the REAL {ok, error?}
-- table a tablet click would receive. This is also the ONLY way this spec
-- can observe the new (ok, outcome) RETURN CONTRACT this pass adds to
-- SetCertificationTier/RenewCertification/GrantSpecialization/
-- RevokeSpecialization(Offline)/GrantCertification(Offline) themselves --
-- those remain `local`, reached everywhere else in this file only through
-- the net-event/command dispatch tables, which discard whatever they
-- return, exactly as before this pass (see each retrofit's own "purely
-- additive" doc comment). The ONLINE branch of every *ForTablet wrapper
-- calls straight through to the exact same online function unchanged, so
-- pinning an ONLINE success/failure here through the wrapper IS pinning
-- that underlying function's own return value.
--
-- LOCALE KEYS: this pass introduced seven new certifications.* keys
-- (the merged usage strings, which name both target shapes -- the
-- two "target is actually online, use the online command instead"
-- security-guard messages, and certify_offline_requires_online_model_check)
-- that did not exist in locales/en.json when this pass's server-side code
-- was first written -- all seven have since LANDED there (confirmed
-- against the real, unmodified locales/en.json this spec reads, per this
-- file's own header: locale() is never stubbed here), so every notify
-- text below is asserted for real, exactly like every other locale call
-- in this file -- no gap left disclosed.
-- ======================================================================

--- @param opts table? -- same shape as newFixture's own opts, with Config.Features.CommandTablet forced to true
local function tabletFixture(opts)
    opts = opts or {}
    opts.features = opts.features or {}
    opts.features.CommandTablet = true
    return newFixture(opts)
end

--- @param f table -- a tabletFixture() result
--- @param action string -- e.g. 'tabletSetCertificationTier'
--- @param outcome string -- e.g. 'ok', 'not_eligible'
local function auditedWith(f, action, outcome)
    for _, line in ipairs(f.printLog) do
        -- Substring match on action(...)-> outcome would be too loose
        -- (the real line embeds real args between the parens) -- match
        -- the action name and the exact trailing "-> outcome" separately
        -- instead.
        if line:find('AUDIT:', 1, true) and line:find(action .. '(', 1, true) and line:find('-> ' .. outcome, 1, true) then
            return true
        end
    end
    return false
end

t.test('tabletSetCertificationTier: SECURITY -- a caller with no rank/grant/high-command is refused, no DB write attempted, and the refusal is audited', function()
    local f = tabletFixture()
    f.registerPlayer(1, 'G1', { name = 'police', grade = { level = 0 } })

    local updateCalled = false
    f.mysql.update.await = function() updateCalled = true; return 1 end

    local result = f.callbacks['qbx_k9unit:server:tabletSetCertificationTier'](1, 'T1', 'police', 'senior')

    t.isFalse(result.ok)
    t.equals(result.error, 'not_eligible')
    t.isFalse(updateCalled)
    t.isTrue(notifiedExactly(f, 1, localeWithPendingCertKeys('certifications.not_authorized_to_certify_hint'), 'error'))
    t.isTrue(auditedWith(f, 'tabletSetCertificationTier', 'not_eligible'), 'a DENIED tablet invocation must be audited too, not only a successful one')
end)

t.test('tabletSetCertificationTier: DESIGN -- a plain certifier-grade rank officer (NOT high command) is allowed, matching every other tablet certification action (IsEligibleCertifier, not IsHighCommand, is the real gate)', function()
    local f = tabletFixture()
    f.registerPlayer(10, 'G1', { name = 'police', grade = { level = 4 } }) -- meets certifierGrade=4, not isboss
    f.registerPlayer(20, 'T1', { name = 'police', grade = { level = 1 } })
    f.setPed(10, 1010, vec3(0, 0, 0))
    f.setPed(20, 1020, vec3(0, 0, 0))
    f.mysql.scalar.await = function() return 5 end
    f.env.RefreshCertificationCache('T1', 'police')

    t.isNil(f.env.IsHighCommand, 'sanity: server/highcommand.lua is not loaded in this fixture at all')

    local result = f.callbacks['qbx_k9unit:server:tabletSetCertificationTier'](10, 'T1', 'police', 'senior')

    t.isTrue(result.ok, 'IsEligibleCertifier (certifierGrade rank), not IsHighCommand, is the real authorization gate for every tablet action in this file')
    t.isTrue(auditedWith(f, 'tabletSetCertificationTier', 'ok'))
end)

t.test('tabletSetCertificationTier: ONLINE success delegates to the proximity-checked SetCertificationTier unchanged', function()
    local f = tabletFixture()
    f.registerPlayer(10, 'G1', { name = 'police', isboss = true })
    f.registerPlayer(20, 'T1', { name = 'police', grade = { level = 1 } })
    f.setPed(10, 1010, vec3(0, 0, 0))
    f.setPed(20, 1020, vec3(0, 0, 0))
    f.mysql.scalar.await = function() return 5 end -- active base cert exists
    f.env.RefreshCertificationCache('T1', 'police') -- primes cache tier = 'certified' (DEFAULT_TIER)

    -- AFFECTED-ROWS DEFECT FIX (data-truth audit pass): SetCertificationTier
    -- now reads the tier back from the post-write cache refresh before
    -- notifying either party (mirrors RenewCertification's own "never
    -- display an assumed value" precedent -- see that function's own doc
    -- comment and SetCertificationTier's own identical new comment), same
    -- as the pre-existing "TIER TRANSITION" test's own
    -- "post-update re-cache reflects the new tier" single.await re-mock.
    f.mysql.single.await = function() return { tier = 'senior' } end

    local result = f.callbacks['qbx_k9unit:server:tabletSetCertificationTier'](10, 'T1', 'police', 'senior')

    t.isTrue(result.ok)
    t.isTrue(notifiedExactly(f, 20, Sandbox.locale('certifications.tier_change_success_target', 'senior'), 'success'))
end)

t.test('tabletSetCertificationTier: ONLINE proximity is still enforced, exactly like a live /k9settier -- a distant target is refused', function()
    local f = tabletFixture()
    f.registerPlayer(10, 'G1', { name = 'police', isboss = true })
    f.registerPlayer(20, 'T1', { name = 'police', grade = { level = 1 } })
    f.setPed(10, 1010, vec3(0, 0, 0))
    f.setPed(20, 1020, vec3(999, 999, 0))
    f.mysql.scalar.await = function() return 5 end
    f.env.RefreshCertificationCache('T1', 'police')

    local result = f.callbacks['qbx_k9unit:server:tabletSetCertificationTier'](10, 'T1', 'police', 'senior')

    t.isFalse(result.ok)
    t.equals(result.error, 'target_too_far')
end)

t.test('tabletSetCertificationTier: RETURN CONTRACT -- already holding the requested tier propagates outcome=\'tier_already_set\' through the tablet wrapper unchanged', function()
    local f = tabletFixture()
    f.registerPlayer(10, 'G1', { name = 'police', isboss = true })
    f.registerPlayer(20, 'T1', { name = 'police', grade = { level = 1 } })
    f.setPed(10, 1010, vec3(0, 0, 0))
    f.setPed(20, 1020, vec3(0, 0, 0))
    f.mysql.scalar.await = function() return 5 end
    f.env.RefreshCertificationCache('T1', 'police') -- tier defaults to 'certified'

    local result = f.callbacks['qbx_k9unit:server:tabletSetCertificationTier'](10, 'T1', 'police', 'certified')

    t.isFalse(result.ok)
    t.equals(result.error, 'tier_already_set')
end)

t.test('tabletSetCertificationTier: OFFLINE success -- a disconnected target still gets re-tiered, no proximity possible or required, and is audited', function()
    local f = tabletFixture()
    f.registerPlayer(10, 'G1', { name = 'police', isboss = true })
    -- T1 is NOT registered as an online player at all.
    f.mysql.single.await = function() return { tier = 'certified', expires_at_unix = nil } end -- QueryCertificationRecord: active row exists

    local updateParams
    f.mysql.update.await = function(_sql, params) updateParams = params; return 1 end

    local result = f.callbacks['qbx_k9unit:server:tabletSetCertificationTier'](10, 'T1', 'police', 'senior')

    t.isTrue(result.ok)
    t.equals(updateParams[1], 'senior')
    t.equals(updateParams[2], 'T1')
    t.equals(updateParams[3], 'police')
    t.isTrue(notifiedExactly(f, 10, Sandbox.locale('certifications.tier_change_success_granter', 'senior'), 'success'), 'granter is notified even though the target is offline')
    t.isTrue(auditedWith(f, 'tabletSetCertificationTier', 'ok'))
end)

t.test('tabletSetCertificationTier: OFFLINE -- no active certification row for that department is refused, never written', function()
    local f = tabletFixture()
    f.registerPlayer(10, 'G1', { name = 'police', isboss = true })
    f.mysql.single.await = function() return nil end -- QueryCertificationRecord: no active row

    local updateCalled = false
    f.mysql.update.await = function() updateCalled = true; return 1 end

    local result = f.callbacks['qbx_k9unit:server:tabletSetCertificationTier'](10, 'T1', 'police', 'senior')

    t.isFalse(result.ok)
    t.equals(result.error, 'target_not_actively_certified')
    t.isFalse(updateCalled)
end)

t.test('tabletSetCertificationTier: an unknown tier key is refused (online path), never reaches the UPDATE', function()
    local f = tabletFixture()
    f.registerPlayer(10, 'G1', { name = 'police', isboss = true })
    f.registerPlayer(20, 'T1', { name = 'police', grade = { level = 1 } })
    f.setPed(10, 1010, vec3(0, 0, 0))
    f.setPed(20, 1020, vec3(0, 0, 0))
    f.mysql.scalar.await = function() return 5 end
    f.env.RefreshCertificationCache('T1', 'police')

    local updateCalled = false
    f.mysql.update.await = function() updateCalled = true; return 1 end

    local result = f.callbacks['qbx_k9unit:server:tabletSetCertificationTier'](10, 'T1', 'police', 'made_up_tier')

    t.isFalse(result.ok)
    t.equals(result.error, 'invalid_tier')
    t.isFalse(updateCalled)
end)

t.test('tabletSetCertificationTier: an unknown tier key is ALSO refused offline, never reaches the UPDATE', function()
    local f = tabletFixture()
    f.registerPlayer(10, 'G1', { name = 'police', isboss = true })

    local updateCalled = false
    f.mysql.update.await = function() updateCalled = true; return 1 end

    local result = f.callbacks['qbx_k9unit:server:tabletSetCertificationTier'](10, 'T1', 'police', 'made_up_tier')

    t.isFalse(result.ok)
    t.equals(result.error, 'invalid_tier')
    t.isFalse(updateCalled)
end)

t.test('tabletSetCertificationTier: TIER CATALOG RACE -- a tier deleted between the initial check and TierEditMutex acquisition is refused, never written (online path)', function()
    local f = tabletFixture()
    f.registerPlayer(10, 'G1', { name = 'police', isboss = true })
    f.registerPlayer(20, 'T1', { name = 'police', grade = { level = 1 } })
    f.setPed(10, 1010, vec3(0, 0, 0))
    f.setPed(20, 1020, vec3(0, 0, 0))
    f.mysql.scalar.await = function() return 5 end
    f.env.RefreshCertificationCache('T1', 'police')

    f.env.TierEditMutex = {
        TryAcquire = function() return true end,
        Release = function() end,
    }
    local knownCallCount = 0
    f.env.IsKnownCertificationTierKey = function(_key)
        knownCallCount = knownCallCount + 1
        -- 1st call: SetCertificationTier's own initial validity check
        -- (before acquiring the lock) -- 'senior' is genuinely known.
        -- 2nd call: the RE-CHECK after acquiring TierEditMutex -- simulates
        -- a concurrent DeleteTier landing in the gap between the two,
        -- exactly the race server/certtiers.lua's own "HAZARD 4" names.
        return knownCallCount == 1
    end

    local updateCalled = false
    f.mysql.update.await = function() updateCalled = true; return 1 end

    local result = f.callbacks['qbx_k9unit:server:tabletSetCertificationTier'](10, 'T1', 'police', 'senior')

    t.isFalse(result.ok)
    t.equals(result.error, 'invalid_tier')
    t.isFalse(updateCalled, 'a tier deleted mid-flight must never be written')
end)

t.test('tabletSetCertificationTier: TIER CATALOG RACE -- the identical race is caught offline too, never written', function()
    local f = tabletFixture()
    f.registerPlayer(10, 'G1', { name = 'police', isboss = true })
    f.mysql.single.await = function() return { tier = 'certified', expires_at_unix = nil } end

    f.env.TierEditMutex = {
        TryAcquire = function() return true end,
        Release = function() end,
    }
    local knownCallCount = 0
    f.env.IsKnownCertificationTierKey = function(_key)
        knownCallCount = knownCallCount + 1
        return knownCallCount == 1
    end

    local updateCalled = false
    f.mysql.update.await = function() updateCalled = true; return 1 end

    local result = f.callbacks['qbx_k9unit:server:tabletSetCertificationTier'](10, 'T1', 'police', 'senior')

    t.isFalse(result.ok)
    t.equals(result.error, 'invalid_tier')
    t.isFalse(updateCalled)
end)

t.test('tabletSetCertificationTier: a held TierEditMutex key reports busy, never writes (online path)', function()
    local f = tabletFixture()
    f.registerPlayer(10, 'G1', { name = 'police', isboss = true })
    f.registerPlayer(20, 'T1', { name = 'police', grade = { level = 1 } })
    f.setPed(10, 1010, vec3(0, 0, 0))
    f.setPed(20, 1020, vec3(0, 0, 0))
    f.mysql.scalar.await = function() return 5 end
    f.env.RefreshCertificationCache('T1', 'police')

    f.env.TierEditMutex = {
        TryAcquire = function() return false end,
        Release = function() end,
    }

    local updateCalled = false
    f.mysql.update.await = function() updateCalled = true; return 1 end

    local result = f.callbacks['qbx_k9unit:server:tabletSetCertificationTier'](10, 'T1', 'police', 'senior')

    t.isFalse(result.ok)
    t.equals(result.error, 'busy')
    t.isFalse(updateCalled)
end)

t.test('tabletSetCertificationTier: a stale department view (target changed job since) is refused as department_mismatch, never silently retargeted', function()
    local f = tabletFixture()
    f.registerPlayer(10, 'G1', { name = 'police', isboss = true })
    f.registerPlayer(20, 'T1', { name = 'sheriff', grade = { level = 1 } }) -- now sheriff; tablet still thinks police
    f.setPed(10, 1010, vec3(0, 0, 0))
    f.setPed(20, 1020, vec3(0, 0, 0))

    local result = f.callbacks['qbx_k9unit:server:tabletSetCertificationTier'](10, 'T1', 'police', 'senior')

    t.isFalse(result.ok)
    t.equals(result.error, 'department_mismatch')
end)

t.test('tabletSetCertificationTier: shape validation -- an empty tier is invalid_target before any lookup, no notify sent at all', function()
    local f = tabletFixture()
    f.registerPlayer(10, 'G1', { name = 'police', isboss = true })

    local result = f.callbacks['qbx_k9unit:server:tabletSetCertificationTier'](10, 'T1', 'police', '')

    t.isFalse(result.ok)
    t.equals(result.error, 'invalid_target')
    t.equals(#f.notifyLog, 0, 'a bare shape check must never call NotifyPlayer -- the tablet UI renders its own error')
end)

t.test('tabletSetCertificationTier: an unconfigured department key is invalid_department before any lookup', function()
    local f = tabletFixture()
    f.registerPlayer(10, 'G1', { name = 'police', isboss = true })

    local result = f.callbacks['qbx_k9unit:server:tabletSetCertificationTier'](10, 'T1', 'not_a_real_department', 'senior')

    t.isFalse(result.ok)
    t.equals(result.error, 'invalid_department')
end)

-- ======================================================================
-- THE BUGFIX (docs/history/COMMAND_CONSOLIDATION_SPEC.md §6) -- tabletDecertify /
-- RevokeCertificationForTablet. Before this pass, client/tablet.lua's
-- tablet:decertify NUI callback shelled out to the OFFLINE-ONLY
-- '/k9decertifyoffline' command for EVERY target, online or offline --
-- and RevokeCertificationOffline's own "refuse if actually online right
-- now" guard (tested above at "RevokeCertificationOffline: SECURITY")
-- means clicking Decertify against a currently-connected person ALWAYS
-- hit that refusal and did nothing. RevokeCertificationForTablet (mirrors
-- GrantCertificationForTablet exactly) is the fix: resolve online-vs-
-- offline from the citizenid itself and delegate to the correct,
-- UNCHANGED underlying function either way.
-- ======================================================================

t.test('tabletDecertify: THE BUG, PINNED -- an ONLINE target is actually revoked through the tablet callback (this is what silently failed before RevokeCertificationForTablet existed)', function()
    local f = tabletFixture()
    f.registerPlayer(10, 'G1', { name = 'police', isboss = true })
    f.registerPlayer(20, 'T1', { name = 'police', grade = { level = 1 } })
    f.setPed(10, 1010, vec3(0, 0, 0))
    f.setPed(20, 1020, vec3(0, 0, 0))
    f.mysql.scalar.await = function() return 5 end -- seed an active cert first
    f.env.RefreshCertificationCache('T1', 'police')
    t.isTrue(f.env.HasK9Access(20), 'sanity: the target really is certified before the revoke')

    local updateCalled = false
    f.mysql.update.await = function(_sql, params) updateCalled = true; return 1 end
    f.mysql.scalar.await = function() return nil end -- post-revoke re-cache: no active row

    local result = f.callbacks['qbx_k9unit:server:tabletDecertify'](10, 'T1', 'police')

    t.isTrue(result.ok, 'an ONLINE target must actually be revocable through the tablet -- this assertion is exactly what the old command-bridge implementation could never satisfy')
    t.isTrue(updateCalled)
    t.isFalse(f.env.HasK9Access(20), 'access must genuinely be gone, not just reported gone')
    t.isTrue(auditedWith(f, 'tabletDecertify', 'ok'))
end)

t.test('tabletDecertify: SECURITY -- a caller with no rank/grant/high-command is refused, no DB write attempted, and the refusal is audited', function()
    local f = tabletFixture()
    f.registerPlayer(1, 'G1', { name = 'police', grade = { level = 0 } })

    local updateCalled = false
    f.mysql.update.await = function() updateCalled = true; return 1 end

    local result = f.callbacks['qbx_k9unit:server:tabletDecertify'](1, 'T1', 'police')

    t.isFalse(result.ok)
    t.equals(result.error, 'not_eligible')
    t.isFalse(updateCalled)
    t.isTrue(auditedWith(f, 'tabletDecertify', 'not_eligible'), 'a DENIED tablet invocation must be audited too, not only a successful one')
end)

t.test('tabletDecertify: ONLINE proximity is still enforced, exactly like a live /k9decertify -- a distant target is refused, the online path is never weakened for the tablet', function()
    local f = tabletFixture()
    f.registerPlayer(10, 'G1', { name = 'police', isboss = true })
    f.registerPlayer(20, 'T1', { name = 'police', grade = { level = 1 } })
    f.setPed(10, 1010, vec3(0, 0, 0))
    f.setPed(20, 1020, vec3(999, 999, 0))
    f.mysql.scalar.await = function() return 5 end
    f.env.RefreshCertificationCache('T1', 'police')

    local updateCalled = false
    f.mysql.update.await = function() updateCalled = true; return 1 end

    local result = f.callbacks['qbx_k9unit:server:tabletDecertify'](10, 'T1', 'police')

    t.isFalse(result.ok)
    t.equals(result.error, 'target_too_far')
    t.isFalse(updateCalled)
end)

t.test('tabletDecertify: OFFLINE success -- a disconnected target still gets revoked, no proximity possible or required, and is audited', function()
    local f = tabletFixture()
    f.registerPlayer(10, 'G1', { name = 'police', isboss = true })
    -- T1 is NOT registered as an online player at all.
    local updateParams
    f.mysql.update.await = function(_sql, params) updateParams = params; return 1 end
    f.mysql.scalar.await = function() return nil end

    local result = f.callbacks['qbx_k9unit:server:tabletDecertify'](10, 'T1', 'police')

    t.isTrue(result.ok)
    t.equals(updateParams[3], 'T1')
    t.equals(updateParams[4], 'police')
    t.isTrue(notifiedExactly(f, 10, Sandbox.locale('certifications.revoke_success'), 'success'), 'granter is notified even though the target is offline')
    t.isTrue(auditedWith(f, 'tabletDecertify', 'ok'))
end)

t.test('tabletDecertify: OFFLINE -- no active certification row for that department is a distinguishable no-op, never a false success', function()
    local f = tabletFixture()
    f.registerPlayer(10, 'G1', { name = 'police', isboss = true })
    f.mysql.update.await = function() return 0 end

    local result = f.callbacks['qbx_k9unit:server:tabletDecertify'](10, 'NOBODY', 'police')

    t.isFalse(result.ok)
    t.equals(result.error, 'target_not_actively_certified')
end)

t.test('tabletDecertify: a stale department view (target changed job since) is refused as department_mismatch, never silently revoking their real, current department', function()
    local f = tabletFixture()
    f.registerPlayer(10, 'G1', { name = 'police', isboss = true })
    f.registerPlayer(20, 'T1', { name = 'sheriff', grade = { level = 1 } }) -- really "sheriff" now, tablet still thinks "police"

    local updateCalled = false
    f.mysql.update.await = function() updateCalled = true; return 1 end

    local result = f.callbacks['qbx_k9unit:server:tabletDecertify'](10, 'T1', 'police')

    t.isFalse(result.ok)
    t.equals(result.error, 'department_mismatch')
    t.isFalse(updateCalled)
end)

t.test('tabletDecertify: shape validation -- an empty citizenid is invalid_target before any lookup, no notify sent at all', function()
    local f = tabletFixture()
    f.registerPlayer(10, 'G1', { name = 'police', isboss = true })

    local result = f.callbacks['qbx_k9unit:server:tabletDecertify'](10, '', 'police')

    t.isFalse(result.ok)
    t.equals(result.error, 'invalid_target')
end)

t.test('tabletDecertify: an unconfigured department key is invalid_department before any lookup', function()
    local f = tabletFixture()
    f.registerPlayer(10, 'G1', { name = 'police', isboss = true })

    local result = f.callbacks['qbx_k9unit:server:tabletDecertify'](10, 'T1', 'not_a_real_department')

    t.isFalse(result.ok)
    t.equals(result.error, 'invalid_department')
end)

t.test('tabletDecertify: RECYCLED SERVER ID SAFETY -- resolution is by citizenid only, never a client-supplied numeral, so a server id previously belonging to the revoke target cannot leak onto whoever holds that number now', function()
    local f = tabletFixture()
    f.registerPlayer(10, 'G1', { name = 'police', isboss = true })
    f.registerPlayer(20, 'T1', { name = 'police', grade = { level = 1 } })
    f.setPed(10, 1010, vec3(0, 0, 0))
    f.setPed(20, 1020, vec3(0, 0, 0))
    f.mysql.scalar.await = function() return 5 end
    f.env.RefreshCertificationCache('T1', 'police')

    -- T1 disconnects; FiveM recycles their old numeric source id (20) onto
    -- an entirely unrelated new connection, T2, who happens to hold an
    -- active cert of their own for the SAME department.
    f.disconnectPlayer(20)
    f.registerPlayer(20, 'T2', { name = 'police', grade = { level = 1 } })
    f.setPed(20, 1030, vec3(0, 0, 0))
    f.mysql.scalar.await = function() return 5 end
    f.env.RefreshCertificationCache('T2', 'police')
    t.isTrue(f.env.HasK9Access(20), 'sanity: T2 (the NEW occupant of source id 20) is genuinely certified')

    -- Decertifying T1 (now genuinely offline) must resolve via
    -- GetPlayerByCitizenId('T1') -- which now correctly returns nothing,
    -- since T1 is not who is connected as source 20 anymore -- and fall
    -- through to the offline path for T1's own row, never touching T2's
    -- live, currently-certified access just because '20' used to mean T1.
    local updateParams
    f.mysql.update.await = function(_sql, params) updateParams = params; return 1 end
    f.mysql.scalar.await = function() return nil end -- T1's own post-revoke recache: no active row

    local result = f.callbacks['qbx_k9unit:server:tabletDecertify'](10, 'T1', 'police')

    t.isTrue(result.ok)
    t.equals(updateParams[3], 'T1', 'the UPDATE must target T1 (the citizenid actually requested), never T2 merely because T2 now holds T1\'s old numeral')
    t.equals(updateParams[4], 'police')
    t.isTrue(f.env.HasK9Access(20), 'T2 (whoever actually holds source id 20 right now) must be completely unaffected by decertifying a DIFFERENT citizenid')
end)

-- ======================================================================
-- ROSTER FIX (coordinator-flagged gap, this pass) -- RevokeCertificationForTablet
-- did not call server/roster.lua's own ClearPersonnelRowForCitizenJob, so a
-- fired handler's `k9_personnel` row (their roster role AND callsign)
-- survived the revoke -- invisible today (both roster reads already filter
-- on an active certification) but resurrecting on re-certification,
-- landing them back on a roster with their OLD callsign instead of
-- Unassigned (docs/history/ROSTER_SPEC.md §4). This is a genuine, end-to-end
-- INTEGRATION test -- REAL server/roster.lua loaded alongside this file,
-- REAL K9Store (memory mode), no stubbing of ClearPersonnelRowForCitizenJob
-- at all -- proving the actual production call site, not a mocked stand-in.
-- ======================================================================

t.test('INTEGRATION: certify -> assign roster role + callsign -> revoke via tabletDecertify -> re-certify -- the re-certified handler lands back in Unassigned with no callsign, never resurrecting the old row', function()
    local f = newFixture({
        features = { CommandTablet = true },
        database = { enabled = false }, -- memory mode -- real K9Store, no MySQL mocking needed
        includeRoster = true,           -- loads the REAL server/roster.lua into this same env
    })
    f.registerPlayer(10, 'GRANTER', { name = 'police', isboss = true })
    f.registerPlayer(20, 'TARGET', { name = 'police', grade = { level = 1 } })
    f.setPed(10, 1010, vec3(0, 0, 0))
    f.setPed(20, 1020, vec3(0, 0, 0))

    -- CERTIFY (online, real GrantCertification via the command path).
    f.commands['k9certify'].fn(10, { '20' })
    t.isTrue(f.env.HasK9Access(20), 'sanity: TARGET is really certified before any roster assignment')

    -- ASSIGN a roster role and a callsign -- real RosterAssignPersonnelRole/
    -- RosterSetCallsign, exactly as the tablet's own roster screen would.
    local assignOk, assignOutcome = f.env.RosterAssignPersonnelRole('TARGET', 'police', 'k9', 'GRANTER')
    t.isTrue(assignOk, assignOutcome)
    local callsignOk = f.env.RosterSetCallsign('TARGET', 'police', '6-Frank-2')
    t.isTrue(callsignOk)

    local beforeRow = f.env.K9Store.Personnel_GetActiveRow('TARGET', 'police')
    t.isNotNil(beforeRow, 'sanity: a real personnel row exists before the revoke')
    t.equals(beforeRow.role, 'k9')
    t.equals(beforeRow.callsign, '6-Frank-2')

    -- REVOKE via the REAL tabletDecertify callback -- RevokeCertificationForTablet,
    -- the actual production call site this pass fixed.
    f.advanceTime(COOLDOWN_MS + 100)
    local revokeResult = f.callbacks['qbx_k9unit:server:tabletDecertify'](10, 'TARGET', 'police')
    t.isTrue(revokeResult.ok, 'sanity: the revoke itself must succeed')
    t.isFalse(f.env.HasK9Access(20), 'sanity: certification is really gone')

    -- THE ACTUAL FIX: the personnel row must be gone too, immediately,
    -- without needing a resource restart or a manual roster edit.
    t.isNil(f.env.K9Store.Personnel_GetActiveRow('TARGET', 'police'),
        'ClearPersonnelRowForCitizenJob must have run -- a fired handler\'s roster row must not survive their own revoke')

    -- RE-CERTIFY (still online, same server id) -- the exact re-hire
    -- scenario docs/history/ROSTER_SPEC.md §4 requires to land in Unassigned.
    f.advanceTime(COOLDOWN_MS + 100)
    f.commands['k9certify'].fn(10, { '20' })
    t.isTrue(f.env.HasK9Access(20), 'sanity: TARGET is certified again')

    -- THE REGRESSION THIS TEST PINS: without the fix, the OLD personnel row
    -- (role=k9, callsign=6-Frank-2) would still be sitting there, active,
    -- the moment this second certification landed -- resurrecting them
    -- straight back onto the roster under their old callsign instead of
    -- Unassigned.
    t.isNil(f.env.K9Store.Personnel_GetActiveRow('TARGET', 'police'),
        'a re-certified handler must start Unassigned, with no callsign -- the old row must never resurrect')
end)

t.test('tabletRenewCertification: OFFLINE success extends expiry with no proximity possible or required', function()
    local f = tabletFixture({ features = { CertificationExpiry = true }, expiryDays = 90 })
    f.registerPlayer(10, 'G1', { name = 'police', isboss = true })
    f.mysql.single.await = function() return { tier = 'certified', expires_at_unix = 1700000000 } end

    local updateParams
    f.mysql.update.await = function(_sql, params) updateParams = params; return 1 end

    local result = f.callbacks['qbx_k9unit:server:tabletRenewCertification'](10, 'T1', 'police')

    t.isTrue(result.ok)
    t.equals(updateParams[1], 90)
    t.equals(updateParams[2], 'T1')
    t.equals(updateParams[3], 'police')
    -- expires_at_unix (1700000000) equals this fixture's default nowUnix
    -- exactly -- DaysRemainingFromUnix clamps to a minimum of 1 rather than
    -- reporting 0 (see that function's own rounding doc comment).
    t.isTrue(notifiedExactly(f, 10, localeWithPendingCertKeys('certifications.renew_success_granter_detail', '1'), 'success'))
end)

t.test('tabletRenewCertification: ONLINE success is unaffected', function()
    local f = tabletFixture({ features = { CertificationExpiry = true }, expiryDays = 90 })
    f.registerPlayer(10, 'G1', { name = 'police', isboss = true })
    f.registerPlayer(20, 'T1', { name = 'police', grade = { level = 1 } })
    f.setPed(10, 1010, vec3(0, 0, 0))
    f.setPed(20, 1020, vec3(0, 0, 0))
    f.mysql.scalar.await = function() return 5 end
    f.env.RefreshCertificationCache('T1', 'police')

    local result = f.callbacks['qbx_k9unit:server:tabletRenewCertification'](10, 'T1', 'police')

    t.isTrue(result.ok)
    t.isTrue(notifiedExactly(f, 20, Sandbox.locale('certifications.renew_success_target'), 'success'))
end)

t.test('tabletRenewCertification: feature disabled is refused the SAME way online or offline', function()
    local f = tabletFixture() -- Config.Features.CertificationExpiry absent
    f.registerPlayer(10, 'G1', { name = 'police', isboss = true })

    local result = f.callbacks['qbx_k9unit:server:tabletRenewCertification'](10, 'T1', 'police')

    t.isFalse(result.ok)
    t.equals(result.error, 'feature_disabled')
end)

t.test('tabletRenewCertification: OFFLINE -- no active certification row is refused, never written', function()
    local f = tabletFixture({ features = { CertificationExpiry = true }, expiryDays = 90 })
    f.registerPlayer(10, 'G1', { name = 'police', isboss = true })
    f.mysql.single.await = function() return nil end

    local updateCalled = false
    f.mysql.update.await = function() updateCalled = true; return 1 end

    local result = f.callbacks['qbx_k9unit:server:tabletRenewCertification'](10, 'T1', 'police')

    t.isFalse(result.ok)
    t.equals(result.error, 'target_not_actively_certified')
    t.isFalse(updateCalled)
end)

t.test('tabletGrantSpecialization: NO OFFLINE PATH -- a disconnected target fails closed with target_must_be_online, by design (see GrantSpecializationForTablet\'s own doc comment on why, unlike tier/renew/revoke)', function()
    local f = tabletFixture()
    f.registerPlayer(10, 'G1', { name = 'police', isboss = true })
    -- T1 not registered online at all.

    local insertCalled = false
    f.mysql.insert.await = function() insertCalled = true; return 1 end

    local result = f.callbacks['qbx_k9unit:server:tabletGrantSpecialization'](10, 'T1', 'police', 'narcotics')

    t.isFalse(result.ok)
    t.equals(result.error, 'target_must_be_online')
    t.isFalse(insertCalled)
    t.equals(#f.notifyLog, 0, 'the bare online-resolution check must never call NotifyPlayer')
end)

t.test('tabletGrantSpecialization: ONLINE success is unchanged and audited', function()
    local f = tabletFixture()
    f.registerPlayer(10, 'G1', { name = 'police', isboss = true })
    f.registerPlayer(20, 'T1', { name = 'police', grade = { level = 1 } })
    f.setPed(10, 1010, vec3(0, 0, 0))
    f.setPed(20, 1020, vec3(0, 0, 0))
    f.mysql.scalar.await = function() return 5 end -- active base cert
    f.env.RefreshCertificationCache('T1', 'police')
    f.mysql.scalar.await = function() return nil end -- pre-check: no existing active specialization row
    f.mysql.query.await = function() return { { specialization = 'narcotics' } } end

    local result = f.callbacks['qbx_k9unit:server:tabletGrantSpecialization'](10, 'T1', 'police', 'narcotics')

    t.isTrue(result.ok)
    t.isTrue(f.env.HasSpecialization('T1', 'police', 'narcotics'))
    t.isTrue(auditedWith(f, 'tabletGrantSpecialization', 'ok'))
end)

t.test('tabletGrantSpecialization: an unconfigured specialization key is refused, never reaches the INSERT', function()
    local f = tabletFixture()
    f.registerPlayer(10, 'G1', { name = 'police', isboss = true })
    f.registerPlayer(20, 'T1', { name = 'police', grade = { level = 1 } })
    f.setPed(10, 1010, vec3(0, 0, 0))
    f.setPed(20, 1020, vec3(0, 0, 0))
    f.mysql.scalar.await = function() return 5 end
    f.env.RefreshCertificationCache('T1', 'police')

    local insertCalled = false
    f.mysql.insert.await = function() insertCalled = true; return 1 end

    local result = f.callbacks['qbx_k9unit:server:tabletGrantSpecialization'](10, 'T1', 'police', 'not_a_real_specialization')

    t.isFalse(result.ok)
    t.equals(result.error, 'invalid_specialization')
    t.isFalse(insertCalled)
end)

t.test('tabletRevokeSpecialization: SECURITY -- a caller with no rank/grant/high-command is refused, never writes', function()
    local f = tabletFixture()
    f.registerPlayer(10, 'G1', { name = 'police', grade = { level = 0 } })

    local updateCalled = false
    f.mysql.update.await = function() updateCalled = true; return 1 end

    local result = f.callbacks['qbx_k9unit:server:tabletRevokeSpecialization'](10, 'T1', 'police', 'narcotics')

    t.isFalse(result.ok)
    t.equals(result.error, 'not_eligible')
    t.isFalse(updateCalled)
end)

t.test('tabletRevokeSpecialization: OFFLINE success -- mirrors RevokeSpecializationOffline unchanged', function()
    local f = tabletFixture()
    f.registerPlayer(10, 'G1', { name = 'police', isboss = true })
    -- T1 not registered online.
    local updateParams
    f.mysql.update.await = function(_sql, params) updateParams = params; return 1 end

    local result = f.callbacks['qbx_k9unit:server:tabletRevokeSpecialization'](10, 'T1', 'police', 'narcotics')

    t.isTrue(result.ok)
    -- K9Store.Spec_RevokeOne's own param order is (revokedBy, citizenid,
    -- job, specialization) -- revokedBy is the GRANTER's own citizenid.
    t.equals(updateParams[1], 'G1')
    t.equals(updateParams[2], 'T1')
    t.equals(updateParams[3], 'police')
    t.equals(updateParams[4], 'narcotics')
end)

t.test('tabletRevokeSpecialization: ONLINE success delegates to the proximity-checked RevokeSpecialization unchanged', function()
    local f = tabletFixture()
    f.registerPlayer(10, 'G1', { name = 'police', isboss = true })
    f.registerPlayer(20, 'T1', { name = 'police', grade = { level = 1 } })
    f.setPed(10, 1010, vec3(0, 0, 0))
    f.setPed(20, 1020, vec3(0, 0, 0))

    local updateParams
    f.mysql.update.await = function(_sql, params) updateParams = params; return 1 end

    local result = f.callbacks['qbx_k9unit:server:tabletRevokeSpecialization'](10, 'T1', 'police', 'narcotics')

    t.isTrue(result.ok)
    t.equals(updateParams[2], 'T1')
end)

t.test('tabletRevokeSpecialization: ONLINE proximity is still enforced -- a distant target is refused', function()
    local f = tabletFixture()
    f.registerPlayer(10, 'G1', { name = 'police', isboss = true })
    f.registerPlayer(20, 'T1', { name = 'police', grade = { level = 1 } })
    f.setPed(10, 1010, vec3(0, 0, 0))
    f.setPed(20, 1020, vec3(999, 999, 0))

    local result = f.callbacks['qbx_k9unit:server:tabletRevokeSpecialization'](10, 'T1', 'police', 'narcotics')

    t.isFalse(result.ok)
    t.equals(result.error, 'target_too_far')
end)

-- ======================================================================
-- COORDINATOR-DIRECTED FOLLOW-UP -- the certify/decertify offline
-- asymmetry, closed. GrantCertificationForTablet used to fail closed with
-- 'target_must_be_online' for EVERY disconnected target, unconditionally
-- (see this file's own header block above GrantCertificationForTablet,
-- kept for the historical reasoning); it now falls through to
-- GrantCertificationOffline UNLESS Config.K9Appearance.requireK9ModelForRole
-- is explicitly true (the ONE case an offline grant still cannot safely
-- proceed -- see that function's own doc comment).
-- ======================================================================

t.test('tabletCertify: OFFLINE grant now succeeds when Config.K9Appearance.requireK9ModelForRole is off (the shipped default) -- closes the certify/decertify asymmetry', function()
    local f = tabletFixture()
    f.registerPlayer(10, 'G1', { name = 'police', isboss = true })
    -- T1 not registered online -- GrantCertificationForTablet must fall
    -- through to GrantCertificationOffline instead of failing closed.

    local insertParams
    f.mysql.insert.await = function(_sql, params) insertParams = params; return 1 end

    local result = f.callbacks['qbx_k9unit:server:tabletCertify'](10, 'T1', 'police')

    t.isTrue(result.ok)
    t.equals(insertParams[1], 'T1')
    t.equals(insertParams[2], 'police')
    t.isTrue(anyNotify(f, 10, Sandbox.locale('certifications.grant_success_granter'), 'success'))
end)

t.test('tabletCertify: OFFLINE grant is REFUSED when Config.K9Appearance.requireK9ModelForRole is explicitly true -- never silently skips a check the operator turned on', function()
    local f = tabletFixture({ k9Appearance = { requireK9ModelForRole = true } })
    f.registerPlayer(10, 'G1', { name = 'police', isboss = true })

    local insertCalled = false
    f.mysql.insert.await = function() insertCalled = true; return 1 end

    local result = f.callbacks['qbx_k9unit:server:tabletCertify'](10, 'T1', 'police')

    t.isFalse(result.ok)
    t.equals(result.error, 'model_check_requires_online')
    t.isFalse(insertCalled)
    t.isTrue(notifiedExactly(f, 10, Sandbox.locale('certifications.certify_offline_requires_online_model_check'), 'error'))
end)

t.test('tabletCertify: ONLINE grant is COMPLETELY UNAFFECTED by this pass -- still enforces the model check when Config.K9Appearance.requireK9ModelForRole is true', function()
    local f = tabletFixture({ k9Appearance = { requireK9ModelForRole = true } })
    f.registerPlayer(10, 'G1', { name = 'police', isboss = true })
    f.registerPlayer(20, 'T1', { name = 'police', grade = { level = 1 } })
    f.setPed(10, 1010, vec3(0, 0, 0))
    f.setPed(20, 1020, vec3(0, 0, 0), NON_K9_HASH)

    local insertCalled = false
    f.mysql.insert.await = function() insertCalled = true; return 1 end

    local result = f.callbacks['qbx_k9unit:server:tabletCertify'](10, 'T1', 'police')

    t.isFalse(result.ok)
    t.equals(result.error, 'target_not_k9_model')
    t.isFalse(insertCalled)
end)

t.test('requireK9ModelForRole on: Certify as K9 WITH a breed is not refused for the target not being a dog yet -- the certify is what makes them one', function()
    local f = tabletFixture({ k9Appearance = { requireK9ModelForRole = true, applyPedModelOnCertify = true } })
    f.registerPlayer(1, 'G1', { name = 'police', isboss = true })
    f.registerPlayer(2, 'T1', { name = 'police', grade = { level = 1 } })
    f.setPed(1, 100, vec3(0, 0, 0))
    f.setPed(2, 200, vec3(1, 0, 0), NON_K9_HASH)

    local result = f.callbacks['qbx_k9unit:server:tabletCertify'](1, 'T1', 'police', 'a_c_shepherd')
    t.isTrue(result.ok, 'got ' .. tostring(result.error))
    t.equals(#f.appearanceApplyCalls, 1)
end)

t.test('requireK9ModelForRole on: certifying a HUMAN as a handler (no breed) is still refused, as the operator opted in', function()
    local f = tabletFixture({ k9Appearance = { requireK9ModelForRole = true, applyPedModelOnCertify = true } })
    f.registerPlayer(1, 'G1', { name = 'police', isboss = true })
    f.registerPlayer(2, 'T1', { name = 'police', grade = { level = 1 } })
    f.setPed(1, 100, vec3(0, 0, 0))
    f.setPed(2, 200, vec3(1, 0, 0), NON_K9_HASH)

    local result = f.callbacks['qbx_k9unit:server:tabletCertify'](1, 'T1', 'police')
    t.isFalse(result.ok)
    t.equals(result.error, 'target_not_k9_model')
end)

t.test('tabletCertify: ONLINE grant STILL succeeds against a real K9 model, unaffected by this pass, when requireK9ModelForRole is true', function()
    local f = tabletFixture({ k9Appearance = { requireK9ModelForRole = true } })
    f.registerPlayer(10, 'G1', { name = 'police', isboss = true })
    f.registerPlayer(20, 'T1', { name = 'police', grade = { level = 1 } })
    f.setPed(10, 1010, vec3(0, 0, 0))
    f.setPed(20, 1020, vec3(0, 0, 0), K9_HASH_SHEPHERD)

    local insertCalled = false
    f.mysql.insert.await = function() insertCalled = true; return 1 end

    local result = f.callbacks['qbx_k9unit:server:tabletCertify'](10, 'T1', 'police')

    t.isTrue(result.ok)
    t.isTrue(insertCalled)
end)

t.test('tabletCertify: OFFLINE -- an already-certified target is a distinguishable no-op, not a duplicate row', function()
    local f = tabletFixture()
    f.registerPlayer(10, 'G1', { name = 'police', isboss = true })
    f.mysql.scalar.await = function() return 5 end -- existing active row

    local insertCalled = false
    f.mysql.insert.await = function() insertCalled = true; return 1 end

    local result = f.callbacks['qbx_k9unit:server:tabletCertify'](10, 'T1', 'police')

    t.isFalse(result.ok)
    t.equals(result.error, 'already_certified')
    t.isFalse(insertCalled)
end)

t.test('/k9certify (offline shape): an unconfigured department is rejected, never reaches the INSERT', function()
    local f = newFixture()
    f.registerPlayer(1, 'G1', { name = 'police', isboss = true })

    local insertCalled = false
    f.mysql.insert.await = function() insertCalled = true; return 1 end

    f.commands['k9certify'].fn(1, { 'T1', 'not_a_real_department' })

    t.isTrue(notifiedExactly(f, 1, localeWithPendingCertKeys('certifications.invalid_department_hint', 'not_a_real_department', 'police, sheriff'), 'error'))
    t.isFalse(insertCalled)
end)

t.test('/k9settier (offline shape): a non-certifier is rejected before any lookup', function()
    local f = newFixture()
    f.registerPlayer(1, 'G1', { name = 'police', grade = { level = 0 } })

    f.commands['k9settier'].fn(1, { 'T1', 'police', 'senior' })

    t.isTrue(notifiedExactly(f, 1, localeWithPendingCertKeys('certifications.not_authorized_to_certify_hint'), 'error'))
end)

-- VIA THE TABLET CALLBACK, same reasoning as the RenewCertification
-- FAIL-CLOSED test above: with expiry off the merged /k9certify falls
-- through to GRANT deliberately (see the MERGE tests), so the renew path's
-- own "this feature is off" refusal is reachable only here.
t.test('RenewCertificationOffline: disabled-by-default expiry feature is rejected before any citizenid/job validation', function()
    local f = newFixture({ features = { CommandTablet = true } }) -- CertificationExpiry absent
    f.registerPlayer(1, 'G1', { name = 'police', isboss = true })

    local result = f.callbacks['qbx_k9unit:server:tabletRenewCertification'](1, 'T1', 'police')

    t.isFalse(result.ok, 'renewal must be refused while the expiry feature is off')
end)

t.test('/k9settier (offline shape): a missing job argument shows the usage message', function()
    local f = newFixture()
    f.registerPlayer(1, 'G1', { name = 'police', isboss = true })

    f.commands['k9settier'].fn(1, { 'T1' })

    t.isTrue(notifiedExactly(f, 1, Sandbox.locale('certifications.usage_settier'), 'error'))
end)

t.test('/k9certify (offline shape): a missing job argument shows the usage message (feature enabled, so the usage check itself is reached)', function()
    local f = newFixture({ features = { CertificationExpiry = true }, expiryDays = 90 })
    f.registerPlayer(1, 'G1', { name = 'police', isboss = true })

    f.commands['k9certify'].fn(1, { 'T1' })

    t.isTrue(notifiedExactly(f, 1, Sandbox.locale('certifications.usage_certify'), 'error'))
end)

t.test('/k9certify (offline shape): a missing job argument shows the usage message', function()
    local f = newFixture()
    f.registerPlayer(1, 'G1', { name = 'police', isboss = true })

    f.commands['k9certify'].fn(1, { 'T1' })

    t.isTrue(notifiedExactly(f, 1, Sandbox.locale('certifications.usage_certify'), 'error'))
end)

t.test('SetCertificationTierOffline SECURITY: an "offline" citizenid who is actually online right now is refused, pointing at /k9settier -- closes the identical proximity-check bypass RevokeCertificationOffline already guards against', function()
    local f = newFixture()
    f.registerPlayer(1, 'G1', { name = 'police', isboss = true })
    f.registerPlayer(99, 'T1', { name = 'police', grade = { level = 1 } }) -- T1 IS currently connected

    local updateCalled = false
    f.mysql.update.await = function() updateCalled = true; return 1 end

    f.commands['k9settier'].fn(1, { 'T1', 'police', 'senior' })

    t.isTrue(notifiedExactly(f, 1, Sandbox.locale('certifications.tier_change_target_online_use_online_action', 99), 'error'))
    t.isFalse(updateCalled)
end)

-- ----------------------------------------------------------------------
-- REGRESSION (data-truth audit pass, finding #2, offline twin) -- same
-- underlying defect as SetCertificationTier's own REGRESSION coverage
-- above, reached through the offline entry point instead: the entry
-- gate's own `record` snapshot (QueryCertificationRecord, a plain read)
-- can go stale across K9Store.Cert_SetTier's own coroutine yield exactly
-- like the online path's in-memory cache read can.
-- ----------------------------------------------------------------------

t.test('SetCertificationTierOffline: REGRESSION -- a zero-affected-rows UPDATE (no thrown error) reports target_not_actively_certified, never a silent success', function()
    local f = newFixture()
    f.registerPlayer(1, 'G1', { name = 'police', isboss = true })
    -- T1 is NOT registered as an online player at all.
    f.mysql.single.await = function() return { tier = 'certified', expires_at_unix = nil } end -- QueryCertificationRecord: active row exists at the entry gate

    -- A concurrent decertify/job-change landed between the entry gate's
    -- read and this UPDATE's own commit -- WHERE ... active = 1 matches
    -- nothing, and no error is thrown for that.
    f.mysql.update.await = function() return 0 end

    f.commands['k9settier'].fn(1, { 'T1', 'police', 'senior' })

    t.isTrue(notifiedExactly(f, 1, localeWithPendingCertKeys('certifications.target_not_actively_certified_needs_cert'), 'error'), 'the granter must be told the tier change did not land, never a bare success')
    t.equals(#f.outboundEvents, 0, 'no outbound certificationTierChanged event for a tier change that did not actually land')
end)

t.test('SetCertificationTierOffline: REGRESSION -- a throwing UPDATE that genuinely never committed (reconciliation still sees the OLD tier) reports tier_change_error, never a guessed success', function()
    local f = newFixture()
    f.registerPlayer(1, 'G1', { name = 'police', isboss = true })
    -- T1 is NOT registered as an online player at all.
    f.mysql.single.await = function() return { tier = 'certified', expires_at_unix = nil } end -- QueryCertificationRecord: active row exists at the entry gate

    f.mysql.update.await = function() error('simulated connection drop mid-UPDATE') end
    -- The reconciliation read (QueryCertificationRecord) still sees the
    -- OLD tier -- the UPDATE genuinely never committed.

    f.commands['k9settier'].fn(1, { 'T1', 'police', 'senior' })

    t.isTrue(notifiedExactly(f, 1, Sandbox.locale('certifications.tier_change_error'), 'error'))
end)

t.test('SetCertificationTierOffline: REGRESSION -- a throwing UPDATE that ACTUALLY committed (ack lost after a real commit) is confirmed via reconciliation and reported as the genuine success it was', function()
    local f = newFixture()
    f.registerPlayer(1, 'G1', { name = 'police', isboss = true })
    -- T1 is NOT registered as an online player at all.
    f.mysql.single.await = function() return { tier = 'certified', expires_at_unix = nil } end -- QueryCertificationRecord: active row exists at the entry gate

    f.mysql.update.await = function() error('simulated ack lost after a real commit') end

    f.commands['k9settier'].fn(1, { 'T1', 'police', 'senior' })
    t.isTrue(notifiedExactly(f, 1, Sandbox.locale('certifications.tier_change_error'), 'error'), 'sanity: the reconciliation read still sees the OLD tier this pass, so this run must still report a genuine failure')

    -- Re-run with the entry-gate read seeing the OLD tier (so the "already
    -- set" no-op check above the UPDATE does not short-circuit this run)
    -- but the POST-throw reconciliation read seeing the NEW tier --
    -- confirming the UPDATE actually committed despite the client-side
    -- error.
    local f2 = newFixture()
    f2.registerPlayer(1, 'G1', { name = 'police', isboss = true })
    local singleAwaitCallCount = 0
    f2.mysql.single.await = function()
        singleAwaitCallCount = singleAwaitCallCount + 1
        if singleAwaitCallCount == 1 then return { tier = 'certified', expires_at_unix = nil } end -- entry-gate read
        return { tier = 'senior', expires_at_unix = nil } -- post-throw reconciliation read
    end
    f2.mysql.update.await = function() error('simulated ack lost after a real commit') end

    f2.commands['k9settier'].fn(1, { 'T1', 'police', 'senior' })
    t.isTrue(notifiedExactly(f2, 1, Sandbox.locale('certifications.tier_change_success_granter', 'senior'), 'success'), 'the granter must see a real success, not an error, once reconciliation confirms the DB truth')
end)

t.test('RenewCertificationOffline SECURITY: an "offline" citizenid who is actually online right now is refused, pointing at /k9certify', function()
    local f = newFixture({ features = { CertificationExpiry = true }, expiryDays = 90 })
    f.registerPlayer(1, 'G1', { name = 'police', isboss = true })
    f.registerPlayer(99, 'T1', { name = 'police', grade = { level = 1 } })

    -- An existing record, so the merged /k9certify's router sends this to
    -- RENEW rather than GRANT -- otherwise this test would exercise
    -- GrantCertificationOffline's own (identical, separately tested) guard
    -- while claiming to test the renew one.
    f.mysql.single.await = function() return { tier = 'certified', expires_at_unix = 1700000100 } end

    local updateCalled = false
    f.mysql.update.await = function() updateCalled = true; return 1 end

    f.commands['k9certify'].fn(1, { 'T1', 'police' })

    t.isTrue(notifiedExactly(f, 1, Sandbox.locale('certifications.renew_target_online_use_online_action', 99), 'error'))
    t.isFalse(updateCalled)
end)

-- ----------------------------------------------------------------------
-- REGRESSION (data-truth audit pass, offline twin) -- same underlying
-- defect as RenewCertification's own REGRESSION coverage above, reached
-- through the offline entry point instead: the entry gate's own `record`
-- snapshot (QueryCertificationRecord, a plain read) can go stale across
-- K9Store.Cert_RenewExpiry's own coroutine yield exactly like the online
-- path's in-memory cache read can.
-- ----------------------------------------------------------------------

t.test('RenewCertificationOffline: REGRESSION -- a zero-affected-rows UPDATE (no thrown error) reports target_not_actively_certified, never a silent success', function()
    local f = newFixture({ features = { CertificationExpiry = true }, expiryDays = 90 })
    f.registerPlayer(1, 'G1', { name = 'police', isboss = true })
    -- T1 is NOT registered as an online player at all.
    f.mysql.single.await = function() return { tier = 'certified', expires_at_unix = 1700000100 } end -- QueryCertificationRecord: active row exists at the entry gate

    -- A concurrent decertify/job-change landed between the entry gate's
    -- read and this UPDATE's own commit -- WHERE ... active = 1 matches
    -- nothing, and no error is thrown for that.
    f.mysql.update.await = function() return 0 end

    f.commands['k9certify'].fn(1, { 'T1', 'police' })

    t.isTrue(notifiedExactly(f, 1, localeWithPendingCertKeys('certifications.target_not_actively_certified_needs_cert'), 'error'), 'the granter must be told the renewal did not land, never a bare success')
    t.equals(#f.outboundEvents, 0, 'no outbound certificationRenewed event for a renewal that did not actually land')
end)

t.test('RenewCertificationOffline: REGRESSION -- a throwing UPDATE that ACTUALLY committed (ack lost after a real commit) is confirmed via reconciliation and reported as the genuine success it was', function()
    local f = newFixture({ features = { CertificationExpiry = true }, expiryDays = 90 })
    f.registerPlayer(1, 'G1', { name = 'police', isboss = true })
    -- T1 is NOT registered as an online player at all.
    local singleAwaitCallCount = 0
    f.mysql.single.await = function()
        singleAwaitCallCount = singleAwaitCallCount + 1
        -- Call #1 is the merged /k9certify router's own record lookup
        -- (ShouldRenewOfflineTarget); call #2 is RenewCertificationOffline's
        -- entry-gate read. Both want the near-expiry baseline.
        if singleAwaitCallCount <= 2 then return { tier = 'certified', expires_at_unix = 1700000100 } end
        return { tier = 'certified', expires_at_unix = 1707776000 } -- post-throw reconciliation + RefreshCertificationCache reads (extended)
    end
    f.mysql.update.await = function() error('simulated ack lost after a real commit') end

    f.commands['k9certify'].fn(1, { 'T1', 'police' })

    t.isTrue(notifiedExactly(f, 1, localeWithPendingCertKeys('certifications.renew_success_granter_detail', '90'), 'success'), 'the granter must see a real success, not an error, once reconciliation confirms the DB truth')
end)

t.test('GrantCertificationOffline SECURITY: an "offline" citizenid who is actually online right now is refused, pointing at /k9certify -- the SAME proximity-check-bypass guard as decertify/tier/renew', function()
    local f = newFixture()
    f.registerPlayer(1, 'G1', { name = 'police', isboss = true })
    f.registerPlayer(99, 'T1', { name = 'police', grade = { level = 1 } })

    local insertCalled = false
    f.mysql.insert.await = function() insertCalled = true; return 1 end

    f.commands['k9certify'].fn(1, { 'T1', 'police' })

    t.isTrue(notifiedExactly(f, 1, Sandbox.locale('certifications.target_online_use_certify_command', 99), 'error'))
    t.isFalse(insertCalled)
end)

os.exit(t.summary())
