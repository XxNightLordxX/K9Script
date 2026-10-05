--[[
    tests/tracking_spec.lua

    First test coverage for server/tracking.lua's per-person feature control
    (Config.FeatureControl -- config.lua's own documented 4-step
    resolution), added alongside that gate itself (see server/tracking.lua's
    own header, "PER-PERSON FEATURE CONTROL", for the design this pins).
    server/tracking.lua otherwise had ZERO existing spec coverage before
    this pass (confirmed: no tests/tracking_spec.lua existed at all,
    client/tracking.lua's own tests/clienttracking_spec.lua is a different
    file testing a different side of this feature) -- this file is scoped
    narrowly to the block/grant gate this pass added, the "capture must
    never be gated" regression this pass's own task explicitly demanded,
    and the "an already-earned reward survives a later block" decision
    documented at reportTrackSourceArrival's own call site. It does not
    attempt to backfill full coverage of every pre-existing branch in this
    file (the XP-farm anti-abuse arithmetic, the ox_inventory scent hook,
    water-crossing decay, etc.) -- those are unrelated to this pass's own
    scope.

    Loads the REAL, unmodified server/cooldowns.lua -> server/tracking.lua
    chain (server/entities.lua is NOT needed -- unlike server/search.lua/
    a sibling file, this file never calls ResolveNetworkEntity), mirrors
    tests/pursuitsprint_spec.lua's own fixture shape (that file being the
    canonical per-person-feature-control reference this pass's own task
    named) almost line for line, adapted for findTrackableSource's
    lib.callback shape instead of a RegisterNetEvent.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

-- ----------------------------------------------------------------------
-- Vector3-alike stub -- identical shape to every other spec in this suite.
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

local TRACK_TYPE_FEATURE = {
    scent = 'ScentTracking',
    blood = 'BloodTracking',
    gunpowder = 'GunpowderSniffing',
}

--- DETERMINISTIC ITERATION ORDER: plain `pairs(TRACK_TYPE_FEATURE)` would
--- work fine for correctness (every test body below builds its own fresh
--- fixture and asserts independently of the others), but Lua's table
--- iteration order over string keys is not guaranteed stable across
--- process runs (lstate.c seeds the string hash per-VM-instance) -- this
--- file's own three-type loop below was observed emitting its
--- 'not blocked...'/'block.X denies...'/'block.X on ONE track type...'
--- trios in a different scent/blood/gunpowder order from one `lua5.4
--- tracking_spec.lua` run to the next. Harmless to pass/fail, but it
--- makes a run-to-run diff of this file's own output noisy for no
--- reason. Iterating this fixed array instead of the map directly pins
--- the order without changing which cases run.
local TRACK_TYPES_ORDERED = { 'scent', 'blood', 'gunpowder' }

--- @param opts table? {
---   requireGrantListed: table? -- e.g. { BloodTracking = true } -- Config.FeatureControl.RequireGrant
---   withHasPermission: boolean (default true)
---   hasPermissionFn: function
---   xpProgression: boolean (default false)
---   maxLoggedEntries: table? -- e.g. { blood = 3 } -- per-type Config.Tracking.<Type>.maxLoggedEntries override
---   searchCooldownMs: table? -- e.g. { blood = 9000 } -- per-type Config.Tracking.<Type>.searchCooldownMs override (default 5000 for all three)
---   hasSpecializationDefault: boolean (default true) -- see the HasSpecialization stub's own declaration comment below
---   specializationTracking: table? -- overrides Config.SpecializationTracking entirely (default: { explosives = { 'gunpowder' }, patrol = { 'blood' } })
--- }
--- @return table fixture
local function newTrackingFixture(opts)
    opts = opts or {}

    local state = { now = 1000000 }
    local function GetGameTimer() return state.now end

    local threadRunner = Sandbox.newThreadRunner() -- prune thread parked at its first Wait forever -- never stepped, matching this suite's "not exercised" convention for a thread it doesn't need to drive

    local printLog = {}
    local function printStub(...)
        local parts = {}
        for i = 1, select('#', ...) do parts[i] = tostring(select(i, ...)) end
        printLog[#printLog + 1] = table.concat(parts, '\t')
    end

    local playersBySource, pedBySource = {}, {}
    local function registerPlayer(src, citizenid, pedHandle)
        playersBySource[src] = { PlayerData = { citizenid = citizenid } }
        pedBySource[src] = pedHandle
    end

    -- NOTE: production code calls this with COLON syntax
    -- (`exports.qbx_core:GetPlayer(src)`), passing `exports.qbx_core`
    -- itself as an implicit first arg -- mirrors every other fixture in
    -- this suite (tests/pursuitsprint_spec.lua's own qbxGetPlayer shape).
    local exportsTable = {
        qbx_core = {
            GetPlayer = function(_self, src) return playersBySource[src] end,
        },
    }

    local function GetPlayerPed(src) return pedBySource[src] or 0 end

    local pedCoords = {}
    local function GetEntityCoords(entity) return pedCoords[entity] or vec3(0, 0, 0) end

    local hasK9Access = true
    local function HasK9Access(_src) return hasK9Access end

    -- SPECIALIZATION-SCOPED TRACKING (owner-directed decluttering pass,
    -- 2026-08-26). DEFAULT TRUE for every citizenid/specKey -- this file's
    -- pre-existing tests (written before this feature existed) universally
    -- assume "a certified K9 can already Track Blood/Track Gunpowder with
    -- no extra grant", which is exactly the real, INTENTIONAL regression
    -- this pass introduces (see Config.SpecializationTracking's own
    -- config.lua comment) -- defaulting to true here keeps every one of
    -- those pre-existing tests exercising what it was actually written to
    -- test, unaffected by this new, orthogonal gate, without editing each
    -- one individually. Tests that specifically exercise the NEW gating
    -- behavior (below) explicitly opt into `hasSpecializationDefault =
    -- false` and/or `setHasSpecialization` per citizenid/key instead.
    local hasSpecializationDefault = opts.hasSpecializationDefault
    if hasSpecializationDefault == nil then hasSpecializationDefault = true end
    local specializationOverrides = {} -- [citizenid][specKey] = true/false
    local hasSpecializationCalls = {}
    local function HasSpecialization(citizenid, _jobName, specKey)
        hasSpecializationCalls[#hasSpecializationCalls + 1] = { citizenid = citizenid, specKey = specKey }
        local perCitizen = specializationOverrides[citizenid]
        if perCitizen and perCitizen[specKey] ~= nil then
            return perCitizen[specKey]
        end
        return hasSpecializationDefault
    end

    local permissionGrants = {} -- [citizenid][key] = true/false
    local permissionCalls = {}
    local function defaultHasPermission(citizenid, key)
        permissionCalls[#permissionCalls + 1] = { citizenid = citizenid, key = key }
        return permissionGrants[citizenid] and permissionGrants[citizenid][key] == true
    end

    local awardXpCalls = {}
    local function AwardXP(citizenid, actionKey)
        awardXpCalls[#awardXpCalls + 1] = { citizenid = citizenid, actionKey = actionKey }
    end

    local requireGrant = {}
    for k, v in pairs(opts.requireGrantListed or {}) do requireGrant[k] = v end

    -- ENTRY-COUNT CEILING (performance audit at 128 players, this pass) --
    -- lets a test override any/all of Config.Tracking.<Type>.maxLoggedEntries
    -- (e.g. `{ blood = 3 }`) without needing its own bespoke fixture; any
    -- type not named here falls back to a generous default no existing test
    -- in this file could ever realistically hit.
    local maxLoggedEntriesOverrides = opts.maxLoggedEntries or {}
    local searchCooldownMsOverrides = opts.searchCooldownMs or {}

    local Config = {
        Features = {
            ScentTracking = true,
            BloodTracking = true,
            GunpowderSniffing = true,
            XPProgression = opts.xpProgression == true,
        },
        Tracking = {
            Scent     = { maxAgeSeconds = 300, maxRange = 40.0, searchCooldownMs = searchCooldownMsOverrides.scent or 5000, relayCooldownMs = 500, maxLoggedEntries = maxLoggedEntriesOverrides.scent or 6000 },
            Blood     = { maxAgeSeconds = 300, maxRange = 40.0, searchCooldownMs = searchCooldownMsOverrides.blood or 5000, relayCooldownMs = 500, maxLoggedEntries = maxLoggedEntriesOverrides.blood or 8000 },
            Gunpowder = { maxAgeSeconds = 120, maxRange = 40.0, searchCooldownMs = searchCooldownMsOverrides.gunpowder or 5000, relayCooldownMs = 300, maxLoggedEntries = maxLoggedEntriesOverrides.gunpowder or 6000 },
        },
        WaterTrackingDecay = { breaksTrail = false },
        FeatureControl = { RequireGrant = requireGrant },
        XP = { trackArrivalRadius = 3.0, trackArrivalTTLMs = 60000 },
        K9Specializations = {
            narcotics  = { label = 'Narcotics detection' },
            explosives = { label = 'Explosives detection' },
            patrol     = { label = 'Patrol / apprehension' },
        },
        SpecializationTracking = opts.specializationTracking or {
            explosives = { 'gunpowder' },
            patrol     = { 'blood' },
        },
    }

    local registeredCallbacks = {}
    local libStub = { callback = { register = function(name, fn) registeredCallbacks[name] = fn end } }

    local capturedEvents = {}
    local function RegisterNetEvent(name, fn) capturedEvents[name] = fn end

    local eventHandlers = {}
    local function AddEventHandler(name, fn)
        eventHandlers[name] = eventHandlers[name] or {}
        eventHandlers[name][#eventHandlers[name] + 1] = fn
    end

    local function GetCurrentResourceName() return 'john-k9' end

    local overrides = {
        Config = Config,
        GetGameTimer = GetGameTimer,
        print = printStub,
        exports = exportsTable,
        GetPlayerPed = GetPlayerPed,
        GetEntityCoords = GetEntityCoords,
        HasK9Access = HasK9Access,
        HasSpecialization = HasSpecialization,
        lib = libStub,
        RegisterNetEvent = RegisterNetEvent,
        AddEventHandler = AddEventHandler,
        GetCurrentResourceName = GetCurrentResourceName,
        CreateThread = threadRunner.CreateThread,
        Wait = threadRunner.Wait,
    }
    if opts.withHasPermission ~= false then
        overrides.HasPermission = opts.hasPermissionFn or defaultHasPermission
    end
    if opts.xpProgression then
        overrides.AwardXP = AwardXP
    end

    local env = Sandbox.newEnv(overrides)
    Sandbox.loadInto('../server/cooldowns.lua', env)
    Sandbox.loadInto('../server/tracking.lua', env)

    return {
        Config = Config,
        printLog = printLog,
        permissionCalls = permissionCalls,
        awardXpCalls = awardXpCalls,
        hasSpecializationCalls = hasSpecializationCalls,
        advance = function(ms) state.now = state.now + ms end,
        setHasK9Access = function(v) hasK9Access = v end,
        --- Per-citizenid/specKey override for the HasSpecialization stub
        --- above -- e.g. `f.setHasSpecialization('K9-CID', 'patrol', true)`.
        --- Overrides `hasSpecializationDefault` for that EXACT
        --- (citizenid, specKey) pair only; every other pair keeps returning
        --- the fixture's own default.
        setHasSpecialization = function(citizenid, specKey, value)
            specializationOverrides[citizenid] = specializationOverrides[citizenid] or {}
            specializationOverrides[citizenid][specKey] = value
        end,
        grantPermission = function(citizenid, key, value)
            permissionGrants[citizenid] = permissionGrants[citizenid] or {}
            permissionGrants[citizenid][key] = value
        end,
        registerPlayer = registerPlayer,
        setPedCoords = function(entity, x, y, z) pedCoords[entity] = vec3(x, y, z) end,
        --- Calls the real captured findTrackableSource callback directly --
        --- ox_lib's own convention (`source` as an explicit first arg, not
        --- the ambient ~ RegisterNetEvent `source` global this file's OTHER
        --- handlers use).
        --- @return table result
        findTrackableSource = function(src, trackType)
            local handler = assert(registeredCallbacks['john-k9:server:findTrackableSource'],
                'server/tracking.lua did not register john-k9:server:findTrackableSource')
            return handler(src, trackType)
        end,
        --- Calls the real captured findNearestTrackableSource callback
        --- directly -- the NEW merged, server-resolved action (this pass).
        --- @return table result
        findNearestTrackableSource = function(src)
            local handler = assert(registeredCallbacks['john-k9:server:findNearestTrackableSource'],
                'server/tracking.lua did not register john-k9:server:findNearestTrackableSource')
            return handler(src)
        end,
        --- Dispatches the real captured relayDamageEvent handler, mirroring
        --- every other RegisterNetEvent-driven fixture's `dispatch` helper
        --- (ambient `source` set via env.source first).
        relayDamageEvent = function(src)
            env.source = src
            local handler = assert(capturedEvents['john-k9:server:relayDamageEvent'])
            handler()
        end,
        relayWeaponFire = function(src)
            env.source = src
            local handler = assert(capturedEvents['john-k9:server:relayWeaponFire'])
            handler()
        end,
        reportTrackSourceArrival = function(src)
            env.source = src
            local handler = assert(capturedEvents['john-k9:server:reportTrackSourceArrival'])
            handler()
        end,
    }
end

-- ========================================================================
-- QUERY-SIDE GATE (findTrackableSource) -- the entry point this pass gates.
-- Table-driven across all three trackTypes, since
-- IsTrackingFeaturePermittedForCitizenId is the SAME shared function
-- parameterized by featureName for all three -- one detailed pass per
-- type would be triplicated, near-identical code.
-- ========================================================================

for _, trackType in ipairs(TRACK_TYPES_ORDERED) do
    local featureName = TRACK_TYPE_FEATURE[trackType]
    t.test(('not blocked, not in RequireGrant -- %s search succeeds (default allow, step 4)'):format(trackType), function()
        local f = newTrackingFixture()
        f.registerPlayer(1, 'K9-CID', 100)
        f.setPedCoords(100, 0, 0, 0)
        -- Log a source of the matching type within range via the REAL
        -- capture path (relayDamageEvent for blood, relayWeaponFire for
        -- gunpowder) -- for 'scent' (fed only by the ox_inventory hook this
        -- suite deliberately never wires up), seed a fresh log entry the
        -- only other way this file offers: report damage/weapon-fire is
        -- type-specific, so 'scent' is exercised via the RequireGrant/block
        -- tests below instead, where `found` is not the assertion (see
        -- those tests' own comments).
        if trackType == 'blood' then
            f.registerPlayer(2, 'VICTIM-CID', 200)
            f.setPedCoords(200, 0, 0, 0)
            f.relayDamageEvent(2)
        elseif trackType == 'gunpowder' then
            f.registerPlayer(2, 'SHOOTER-CID', 200)
            f.setPedCoords(200, 0, 0, 0)
            f.relayWeaponFire(2)
        end

        if trackType ~= 'scent' then
            local result = f.findTrackableSource(1, trackType)
            t.isTrue(result.found, ('a fresh, in-range, unblocked %s search must find the logged source'):format(trackType))
        else
            -- 'scent' has no logged entry in this fixture at all (no
            -- ox_inventory hook wired) -- found = false is the CORRECT,
            -- expected answer either way; this loop iteration exists only
            -- so the block test below has a companion "not blocked" case
            -- for the SAME featureName, proving the denial there is really
            -- the block, not an unrelated always-false scent search.
            local result = f.findTrackableSource(1, trackType)
            t.isFalse(result.found)
        end
    end)

    t.test(('block.%s denies the search outright (found = false), even with HasK9Access true'):format(featureName), function()
        local f = newTrackingFixture()
        f.registerPlayer(1, 'K9-CID', 100)
        f.setPedCoords(100, 0, 0, 0)
        f.grantPermission('K9-CID', 'block.' .. featureName, true)

        if trackType == 'blood' then
            f.registerPlayer(2, 'VICTIM-CID', 200)
            f.setPedCoords(200, 0, 0, 0)
            f.relayDamageEvent(2)
        elseif trackType == 'gunpowder' then
            f.registerPlayer(2, 'SHOOTER-CID', 200)
            f.setPedCoords(200, 0, 0, 0)
            f.relayWeaponFire(2)
        end

        local result = f.findTrackableSource(1, trackType)
        t.isFalse(result.found, ('block.%s must deny the search regardless of a real, in-range logged source'):format(featureName))
    end)

    t.test(('block.%s on ONE track type does not affect the other two'):format(featureName), function()
        local f = newTrackingFixture()
        f.registerPlayer(1, 'K9-CID', 100)
        f.setPedCoords(100, 0, 0, 0)
        f.grantPermission('K9-CID', 'block.' .. featureName, true)

        for _, otherType in ipairs(TRACK_TYPES_ORDERED) do
            local otherFeature = TRACK_TYPE_FEATURE[otherType]
            if otherType ~= trackType then
                -- Only assert on the two capturable types (blood/gunpowder)
                -- -- scent has no logged source in this fixture regardless.
                if otherType ~= 'scent' then
                    f.registerPlayer(900, 'BYSTANDER-' .. otherType, 800)
                    f.setPedCoords(800, 0, 0, 0)
                    if otherType == 'blood' then f.relayDamageEvent(900) else f.relayWeaponFire(900) end
                    local result = f.findTrackableSource(1, otherType)
                    t.isTrue(result.found, ('blocking %s must not affect an unrelated %s search'):format(featureName, otherFeature))
                end
            end
        end
    end)
end

t.test('A BLOCKED REQUEST NEVER BURNS THE QUERY COOLDOWN: removing the block immediately after still succeeds on the very same tick', function()
    local f = newTrackingFixture()
    f.registerPlayer(1, 'K9-CID', 100)
    f.registerPlayer(2, 'VICTIM-CID', 200)
    f.setPedCoords(100, 0, 0, 0)
    f.setPedCoords(200, 0, 0, 0)
    f.relayDamageEvent(2)

    f.grantPermission('K9-CID', 'block.BloodTracking', true)
    local blockedResult = f.findTrackableSource(1, 'blood')
    t.isFalse(blockedResult.found)

    -- Same GetGameTimer value (no advance() call) -- if the blocked attempt
    -- above had wrongly stamped TrackQueryCooldown, this would now read as
    -- on_cooldown (found = false) instead of succeeding.
    f.grantPermission('K9-CID', 'block.BloodTracking', false)
    local unblockedResult = f.findTrackableSource(1, 'blood')
    t.isTrue(unblockedResult.found, 'the earlier blocked attempt must not have consumed the per-(source, trackType) query cooldown')
end)

t.test('grant_required: RequireGrant.BloodTracking = true + no grant held -- denied even though HasK9Access is true', function()
    local f = newTrackingFixture({ requireGrantListed = { BloodTracking = true } })
    f.registerPlayer(1, 'K9-CID', 100)
    f.registerPlayer(2, 'VICTIM-CID', 200)
    f.setPedCoords(100, 0, 0, 0)
    f.setPedCoords(200, 0, 0, 0)
    f.relayDamageEvent(2)
    -- deliberately NOT granted

    local result = f.findTrackableSource(1, 'blood')
    t.isFalse(result.found)
end)

t.test('RequireGrant.BloodTracking = true + an active feature.BloodTracking grant -- allowed', function()
    local f = newTrackingFixture({ requireGrantListed = { BloodTracking = true } })
    f.registerPlayer(1, 'K9-CID', 100)
    f.registerPlayer(2, 'VICTIM-CID', 200)
    f.setPedCoords(100, 0, 0, 0)
    f.setPedCoords(200, 0, 0, 0)
    f.relayDamageEvent(2)
    f.grantPermission('K9-CID', 'feature.BloodTracking', true)

    local result = f.findTrackableSource(1, 'blood')
    t.isTrue(result.found)
end)

t.test('BLOCK ALWAYS WINS even with an active grant held', function()
    local f = newTrackingFixture({ requireGrantListed = { BloodTracking = true } })
    f.registerPlayer(1, 'K9-CID', 100)
    f.registerPlayer(2, 'VICTIM-CID', 200)
    f.setPedCoords(100, 0, 0, 0)
    f.setPedCoords(200, 0, 0, 0)
    f.relayDamageEvent(2)
    f.grantPermission('K9-CID', 'feature.BloodTracking', true)
    f.grantPermission('K9-CID', 'block.BloodTracking', true)

    local result = f.findTrackableSource(1, 'blood')
    t.isFalse(result.found)
end)

t.test('server/permissions.lua entirely absent (HasPermission not even defined): RequireGrant-listed feature fails CLOSED, never open', function()
    local f = newTrackingFixture({ requireGrantListed = { BloodTracking = true }, withHasPermission = false })
    f.registerPlayer(1, 'K9-CID', 100)
    f.registerPlayer(2, 'VICTIM-CID', 200)
    f.setPedCoords(100, 0, 0, 0)
    f.setPedCoords(200, 0, 0, 0)
    f.relayDamageEvent(2)

    local ok, result = pcall(f.findTrackableSource, 1, 'blood')
    t.isTrue(ok, 'a missing HasPermission must never error the request handler')
    t.isFalse(result.found)
end)

t.test('server/permissions.lua entirely absent + feature NOT listed in RequireGrant -- still allowed', function()
    local f = newTrackingFixture({ requireGrantListed = {}, withHasPermission = false })
    f.registerPlayer(1, 'K9-CID', 100)
    f.registerPlayer(2, 'VICTIM-CID', 200)
    f.setPedCoords(100, 0, 0, 0)
    f.setPedCoords(200, 0, 0, 0)
    f.relayDamageEvent(2)

    local result = f.findTrackableSource(1, 'blood')
    t.isTrue(result.found)
end)

-- ========================================================================
-- CAPTURE MUST NEVER BE GATED (this pass's own explicit, non-negotiable
-- requirement) -- relayDamageEvent (blood) and relayWeaponFire (gunpowder)
-- never consult HasPermission at all, and a reporting citizenid's own
-- block status has zero effect on whether their event gets logged.
-- ========================================================================

t.test('REGRESSION: relayWeaponFire (gunpowder CAPTURE) never consults HasPermission at all, even when the reporter is block.GunpowderSniffing', function()
    local f = newTrackingFixture()
    f.registerPlayer(2, 'SHOOTER-CID', 200)
    f.setPedCoords(200, 0, 0, 0)
    f.grantPermission('SHOOTER-CID', 'block.GunpowderSniffing', true)

    f.relayWeaponFire(2)

    t.equals(#f.permissionCalls, 0, "capture must not gate on the REPORTER's own block/grant state at all")

    -- Prove the entry really got logged despite the reporter's own block --
    -- a DIFFERENT, unblocked K9 searching for it must find it.
    f.registerPlayer(1, 'K9-CID', 100)
    f.setPedCoords(100, 0, 0, 0)
    local result = f.findTrackableSource(1, 'gunpowder')
    t.isTrue(result.found, 'the shot fired by a block.GunpowderSniffing-flagged reporter must still be trackable by another K9')
end)

t.test('REGRESSION: relayDamageEvent (blood CAPTURE) never consults HasPermission at all, even when the victim is block.BloodTracking', function()
    local f = newTrackingFixture()
    f.registerPlayer(2, 'VICTIM-CID', 200)
    f.setPedCoords(200, 0, 0, 0)
    f.grantPermission('VICTIM-CID', 'block.BloodTracking', true)

    f.relayDamageEvent(2)

    t.equals(#f.permissionCalls, 0, "capture must not gate on the reporting party's own block/grant state at all")

    f.registerPlayer(1, 'K9-CID', 100)
    f.setPedCoords(100, 0, 0, 0)
    local result = f.findTrackableSource(1, 'blood')
    t.isTrue(result.found, 'blood logged by a block.BloodTracking-flagged victim must still be trackable by another K9')
end)

t.test('a BLOCKED K9 (the searcher, not the reporter) still logs their OWN relayDamageEvent/relayWeaponFire normally -- capture is never gated on the acting citizenid either', function()
    local f = newTrackingFixture()
    f.registerPlayer(1, 'K9-CID', 100)
    f.setPedCoords(100, 0, 0, 0)
    f.grantPermission('K9-CID', 'block.BloodTracking', true)
    f.grantPermission('K9-CID', 'block.GunpowderSniffing', true)

    f.relayDamageEvent(1)
    f.relayWeaponFire(1)

    t.equals(#f.permissionCalls, 0)
end)

-- ========================================================================
-- "GATE THE ENTRY POINT, NOT THE SYMPTOM" -- reportTrackSourceArrival is
-- deliberately NOT re-checked against the block/grant gate (see that
-- handler's own comment in server/tracking.lua): a ticket minted while
-- permitted must still pay out even if a block lands afterward, while the
-- K9 is already travelling toward an already-resolved, already-authorized
-- source.
-- ========================================================================

t.test('an in-flight, already-minted track ticket still pays XP on arrival even after the citizenid is blocked in between resolve and arrival', function()
    local f = newTrackingFixture({ xpProgression = true })
    f.registerPlayer(1, 'K9-CID', 100)
    f.registerPlayer(2, 'VICTIM-CID', 200)

    -- K9 starts 20m from the logged source -- clears MIN_TRACK_XP_DISTANCE
    -- (15.0, server/tracking.lua's own local constant) so a ticket is
    -- actually minted.
    f.setPedCoords(200, 20, 0, 0)
    f.relayDamageEvent(2) -- logs the blood source at (20, 0, 0)
    f.setPedCoords(100, 0, 0, 0)

    local result = f.findTrackableSource(1, 'blood')
    t.isTrue(result.found, 'the resolve itself must succeed while still permitted -- this is the entry point the gate actually applies to')

    -- Block the K9 for BloodTracking AFTER the ticket was already minted --
    -- the non-negotiable this test pins: an already-earned reward must not
    -- be stranded by a block landing on an in-flight action.
    f.grantPermission('K9-CID', 'block.BloodTracking', true)

    -- Real travel + real elapsed time, exactly as server/tracking.lua's own
    -- ADDENDUM 2 economy fix requires (minElapsedMs = 20 / 25.0 * 1000 = 800ms).
    f.setPedCoords(100, 20, 0, 0) -- now co-located with the resolved source
    f.advance(900)

    f.reportTrackSourceArrival(1)

    t.equals(#f.awardXpCalls, 1, 'arrival must still pay out -- this is a completion of an already-authorized action, not a new entry-point request')
    t.equals(f.awardXpCalls[1].citizenid, 'K9-CID')
    t.equals(f.awardXpCalls[1].actionKey, 'trackSourceResolved')
end)

t.test('a citizenid who was ALREADY blocked before ever resolving a source never gets a ticket to redeem in the first place', function()
    local f = newTrackingFixture({ xpProgression = true })
    f.registerPlayer(1, 'K9-CID', 100)
    f.registerPlayer(2, 'VICTIM-CID', 200)
    f.grantPermission('K9-CID', 'block.BloodTracking', true)

    f.setPedCoords(200, 20, 0, 0)
    f.relayDamageEvent(2)
    f.setPedCoords(100, 0, 0, 0)

    local result = f.findTrackableSource(1, 'blood')
    t.isFalse(result.found, 'blocked at resolve time -- no ticket, no reveal')

    f.setPedCoords(100, 20, 0, 0)
    f.advance(900)
    f.reportTrackSourceArrival(1)

    t.equals(#f.awardXpCalls, 0, 'nothing was ever minted for this citizenid to redeem')
end)

-- ========================================================================
-- GAP CLOSURE (this pass, coder-backend): server/k9profiles.lua's own
-- header names THIS FILE's scent-range consumer as one of three left
-- unwired -- `findTrackableSource`'s maxRange bonus used to read
-- `GetXPTier(trackerCitizenid).scentRangeMultiplier` RAW, so a per-K9
-- individual override on `scentRangeMultiplier` was stored, audited, and
-- shown back to the operator, but had ZERO effect on the actual detection
-- range this callback computes. Fixed by routing through
-- GetK9EffectiveMultipliers (see server/tracking.lua's own maxRange
-- calculation for the full writeup) -- this section proves that fix reaches
-- a REAL, VISIBLE effect (found = true vs. found = false), through the
-- REAL, unmodified server/progression.lua + server/k9profiles.lua chain,
-- not a stubbed GetXPTier/GetK9EffectiveMultipliers.
--
-- Deliberately a SEPARATE fixture from newTrackingFixture above (never
-- modifies it): this section additionally loads server/datastore.lua (for
-- K9Store, server/k9profiles.lua's own persistence layer) and
-- server/progression.lua/server/k9profiles.lua themselves, in
-- fxmanifest.lua's real server_scripts order (datastore -> cooldowns ->
-- tracking -> progression -> k9profiles). `onResourceStart` is
-- DELIBERATELY NEVER FIRED here: server/k9profiles.lua's own
-- RefreshOverrideCache() already runs unconditionally, synchronously, right
-- inside k9ProfileUpsert itself after every successful write (see that
-- function's own body) -- it does not depend on the boot-time cache warm --
-- and firing onResourceStart in this fixture would ALSO invoke
-- server/tracking.lua's own scent-inventory-hook registration
-- (RegisterScentInventoryHook, which calls K9Compat.Get('inventory')), an
-- entirely unrelated surface this section has no need to drag in. Every
-- other existing test in this file already establishes the same
-- "onResourceStart is never fired" convention for server/tracking.lua on
-- its own (grep this file: zero prior references to onResourceStart or
-- K9Compat) -- this section does not change that.
-- ========================================================================

--- @return table fixture
local function newTrackingOverrideChainFixture()
    local state = { now = 0 }
    local function GetGameTimer() return state.now end

    -- server/progression.lua starts a recurring mint-budget sweep thread
    -- UNCONDITIONALLY at its own file-load time -- this fixture never needs
    -- to step it, so a one-shot resume that parks it at its first Wait() is
    -- sufficient, matching tests/progression_spec.lua's own GAP 1 fixture
    -- and tests/medkit_spec.lua's own GAP CLOSURE fixture.
    local function CreateThread(fn)
        local co = coroutine.create(fn)
        local ok, err = coroutine.resume(co)
        if not ok then
            error(('newTrackingOverrideChainFixture: a captured CreateThread body errored: %s'):format(tostring(err)))
        end
    end
    local function Wait(_ms) coroutine.yield() end

    local printLog = {}
    local function printStub(...)
        local parts = {}
        for i = 1, select('#', ...) do parts[i] = tostring(select(i, ...)) end
        printLog[#printLog + 1] = table.concat(parts, '\t')
    end

    local playersBySource, pedBySource = {}, {}
    local function registerPlayer(src, citizenid, pedHandle)
        playersBySource[src] = { PlayerData = { citizenid = citizenid, source = src } }
        pedBySource[src] = pedHandle
    end

    local exportsTable = {
        qbx_core = {
            GetPlayer = function(_self, src) return playersBySource[src] end,
            GetPlayerByCitizenId = function(_self, citizenid)
                for _, p in pairs(playersBySource) do
                    if p.PlayerData.citizenid == citizenid then return p end
                end
                return nil
            end,
        },
    }

    local function GetPlayerPed(src) return pedBySource[src] or 0 end

    local pedCoords = {}
    local function GetEntityCoords(entity) return pedCoords[entity] or vec3(0, 0, 0) end

    local function HasK9Access(_src) return true end

    -- Unrelated to what THIS fixture actually exercises (the
    -- scentRangeMultiplier override chain) -- defaulted to true so this
    -- pre-existing test keeps testing what it was written to test, per the
    -- same reasoning newTrackingFixture's own HasSpecialization stub
    -- documents above.
    local function HasSpecialization(_citizenid, _jobName, _specKey) return true end

    local isHighCommand = true

    local registeredCallbacks = {}
    local libStub = { callback = { register = function(name, fn) registeredCallbacks[name] = fn end } }

    local capturedEvents = {}
    local function RegisterNetEvent(name, fn) capturedEvents[name] = fn end

    local eventHandlers = {}
    local function AddEventHandler(name, fn)
        eventHandlers[name] = eventHandlers[name] or {}
        eventHandlers[name][#eventHandlers[name] + 1] = fn
    end

    local function GetCurrentResourceName() return 'john-k9' end

    local Config = {
        Features = {
            ScentTracking = true, BloodTracking = true, GunpowderSniffing = true,
            XPProgression = true,
        },
        Tracking = {
            -- A deliberately SMALL maxRange -- see the tests below for
            -- exactly why: it must be small enough that a source PAST it is
            -- reachable only once a genuine override multiplies it.
            Scent     = { maxAgeSeconds = 300, maxRange = 10.0, searchCooldownMs = 5000, relayCooldownMs = 500 },
            Blood     = { maxAgeSeconds = 300, maxRange = 10.0, searchCooldownMs = 5000, relayCooldownMs = 500 },
            Gunpowder = { maxAgeSeconds = 120, maxRange = 10.0, searchCooldownMs = 5000, relayCooldownMs = 300 },
        },
        WaterTrackingDecay = { breaksTrail = false },
        FeatureControl = { RequireGrant = {} },
        XP = {
            trackArrivalRadius = 3.0, trackArrivalTTLMs = 60000,
            scopePerCitizenidOrJob = 'citizenid', awards = {},
        },
        K9Specializations = {
            narcotics  = { label = 'Narcotics detection' },
            explosives = { label = 'Explosives detection' },
            patrol     = { label = 'Patrol / apprehension' },
        },
        SpecializationTracking = {
            explosives = { 'gunpowder' },
            patrol     = { 'blood' },
        },
        -- A single-rank ladder -- this section is about the INDIVIDUAL
        -- override layered on top, not the XP-tier ladder itself. See
        -- tests/medkit_spec.lua's own identical GAP CLOSURE fixture comment
        -- for why a single rank is a valid, if minimal, Config.XPTiers.
        XPTiers = { { xp = 0, label = 'Recruit', speedMultiplier = 1.00, scentRangeMultiplier = 1.00 } },
        Database = { enabled = false },
    }

    local env = Sandbox.newEnv({
        Config = Config,
        GetGameTimer = GetGameTimer,
        CreateThread = CreateThread,
        Wait = Wait,
        print = printStub,
        exports = exportsTable,
        GetPlayerPed = GetPlayerPed,
        GetEntityCoords = GetEntityCoords,
        HasK9Access = HasK9Access,
        HasSpecialization = HasSpecialization,
        IsHighCommand = function(_src) return isHighCommand end,
        lib = libStub,
        RegisterNetEvent = RegisterNetEvent,
        AddEventHandler = AddEventHandler,
        GetCurrentResourceName = GetCurrentResourceName,
    })

    Sandbox.loadInto('../server/datastore.lua', env)
    Sandbox.loadInto('../server/cooldowns.lua', env)
    Sandbox.loadInto('../server/tracking.lua', env)
    Sandbox.loadInto('../server/progression.lua', env)
    Sandbox.loadInto('../server/k9profiles.lua', env)

    return {
        Config = Config,
        printLog = printLog,
        advance = function(ms) state.now = state.now + ms end,
        registerPlayer = registerPlayer,
        setPedCoords = function(entity, x, y, z) pedCoords[entity] = vec3(x, y, z) end,
        findTrackableSource = function(src, trackType)
            local handler = assert(registeredCallbacks['john-k9:server:findTrackableSource'])
            return handler(src, trackType)
        end,
        relayDamageEvent = function(src)
            env.source = src
            local handler = assert(capturedEvents['john-k9:server:relayDamageEvent'])
            handler()
        end,
        upsertProfile = function(hcSrc, payload)
            local handler = assert(registeredCallbacks['john-k9:server:k9ProfileUpsert'])
            return handler(hcSrc, payload)
        end,
    }
end

t.test('GAP CLOSURE: an individual scentRangeMultiplier override reaches findTrackableSource\'s own maxRange calculation through the REAL server/progression.lua + server/k9profiles.lua chain -- not a stub', function()
    local f = newTrackingOverrideChainFixture()
    local HC_SRC = 999

    f.registerPlayer(1, 'K9-CID', 100)
    f.registerPlayer(2, 'VICTIM-CID', 200)
    f.setPedCoords(100, 0, 0, 0) -- the K9

    -- Log a blood source 15m away -- PAST Config.Tracking.Blood.maxRange
    -- (10.0) with no override, but well WITHIN it once a 2.0x override
    -- doubles it to 20.0.
    f.setPedCoords(200, 15, 0, 0)
    f.relayDamageEvent(2)

    -- CONTROL: no override exists yet -- the base tier (Recruit,
    -- scentRangeMultiplier = 1.00) never raises maxRange past its
    -- configured 10.0, so a source 15m away must NOT be found.
    local before = f.findTrackableSource(1, 'blood')
    t.isFalse(before.found, 'a source past the plain configured maxRange, with no override, must not be found')

    -- THE OVERRIDE ITSELF: a genuine high-command tablet edit, through
    -- server/k9profiles.lua's own REAL callback.
    local upsert = f.upsertProfile(HC_SRC, { citizenid = 'K9-CID', scentRangeMultiplier = 2.0 })
    t.isTrue(upsert.ok, 'the override write itself must succeed')
    t.equals(upsert.effective.scentRangeMultiplier, 2.0)

    -- Clear TrackQueryCooldown's own per-(source, trackType) searchCooldownMs
    -- (5000ms) floor -- the CONTROL call above already consumed it for
    -- (1, 'blood') at t=0; without this advance, the call below would be
    -- rejected as on_cooldown (found = false) before ever reaching the
    -- maxRange calculation this test actually exists to exercise.
    f.advance(5001)

    -- SAME source, SAME distance, SAME K9 -- the ONLY thing that changed is
    -- the override just written. If this now finds it, the override
    -- demonstrably reached findTrackableSource's own live maxRange
    -- calculation through the real, unmodified GetK9EffectiveMultipliers
    -- chain -- not merely stored, audited, and displayed back inertly.
    local after = f.findTrackableSource(1, 'blood')
    t.isTrue(after.found, 'after a 2.0 scentRangeMultiplier override, the SAME 15m-away source that was unreachable a moment ago must now be found -- this is the exact "reaches a visible effect" property this pass exists to prove')
end)

t.test('GAP CLOSURE control: WITHOUT the individual override (a different K9 citizenid, same distance), the plain configured maxRange still applies -- the effect above is caused by the override, not a fixture quirk', function()
    local f = newTrackingOverrideChainFixture()

    f.registerPlayer(1, 'K9-CID-NO-OVERRIDE', 100)
    f.registerPlayer(2, 'VICTIM-CID-2', 200)
    f.setPedCoords(100, 0, 0, 0)
    f.setPedCoords(200, 15, 0, 0)
    f.relayDamageEvent(2)

    local result = f.findTrackableSource(1, 'blood')
    t.isFalse(result.found, 'no override was ever set for this citizenid -- the plain configured maxRange (10.0) must still apply to a source 15m away')
end)

-- ========================================================================
-- SCENT VISION (Config.Features.ScentVision) -- owner-directed pass: a
-- keybound coloured-dot "who walked through here" overlay. A NEW, SEPARATE
-- fixture (never modifies newTrackingFixture above): this feature's capture
-- thread scans EVERY CONNECTED player (GetPlayers()), not a single resolved
-- source, and needs a real, steppable CreateThread/Wait pair
-- (Sandbox.newThreadRunner(), the exact same shape newTrackingFixture
-- already uses) to drive the capture/prune threads this pass adds -- no
-- pre-existing test in this file needed either.
-- ========================================================================

--- @param opts table? { requireGrantListed: table?, trackingOverrides: table? }
--- @return table fixture
local function newScentVisionFixture(opts)
    opts = opts or {}

    local state = { now = 1000000 }
    local function GetGameTimer() return state.now end

    local threadRunner = Sandbox.newThreadRunner()

    local printLog = {}
    local function printStub(...)
        local parts = {}
        for i = 1, select('#', ...) do parts[i] = tostring(select(i, ...)) end
        printLog[#printLog + 1] = table.concat(parts, '\t')
    end

    local playersBySource, pedBySource, connected = {}, {}, {}
    local function registerPlayer(src, citizenid, pedHandle)
        playersBySource[src] = { PlayerData = { citizenid = citizenid } }
        pedBySource[src] = pedHandle
        connected[src] = true
    end

    local exportsTable = {
        qbx_core = {
            GetPlayer = function(_self, src) return playersBySource[src] end,
        },
    }

    local function GetPlayerPed(src) return pedBySource[src] or 0 end
    local pedCoords = {}
    local function GetEntityCoords(entity) return pedCoords[entity] or vec3(0, 0, 0) end
    local function setPedCoords(src, x, y, z) pedCoords[pedBySource[src]] = vec3(x, y, z) end

    -- Real GetPlayers() returns an ARRAY OF STRINGS -- mirrored here exactly
    -- (server/entities.lua's own ResolveConnectedPlayerFromPed and this
    -- pass's own capture thread both `tonumber(...)` every entry).
    local function GetPlayers()
        local ids = {}
        for src in pairs(connected) do ids[#ids + 1] = tostring(src) end
        return ids
    end

    local hasK9Access = true
    local function HasK9Access(_src) return hasK9Access end

    local permissionGrants = {}
    local function defaultHasPermission(citizenid, key)
        return permissionGrants[citizenid] and permissionGrants[citizenid][key] == true
    end

    local requireGrant = {}
    for k, v in pairs(opts.requireGrantListed or {}) do requireGrant[k] = v end

    -- CONTRABAND BODY HIGHLIGHT support (owner-directed follow-up,
    -- 2026-08-26) -- OFF by default (opts.contraband absent), matching
    -- production's own "contrabandHighlight table absent/enabled=false"
    -- fail-closed default: every pre-existing test above/below that never
    -- passes opts.contraband gets none of this wired in at all, so none of
    -- it can affect a single test that predates this feature.
    local contrabandOpts = opts.contraband or {}
    local specializationGrants = {}
    for citizenid, keys in pairs(contrabandOpts.specializationGrants or {}) do
        specializationGrants[citizenid] = {}
        for k, v in pairs(keys) do specializationGrants[citizenid][k] = v end
    end
    -- Mirrors the REAL server/certifications/ signature
    -- (citizenid, jobName, specializationKey) -- see server/tracking.lua's
    -- own `type(HasSpecialization) == 'function'` soft-dependency call
    -- sites, both the pre-existing one (ResolveEnabledTrackTypesForCitizenId)
    -- and this pass's own (ResolveHeldContrabandSpecializationsForCitizenId).
    local function HasSpecialization(citizenid, _jobName, specKey)
        return specializationGrants[citizenid] ~= nil and specializationGrants[citizenid][specKey] == true
    end

    -- inventoryItemsBySrc[src] = { { name = 'coke_brick', slot = 1, weight = 1 }, ... }
    -- -- exactly K9Compat.Get('inventory').GetInventoryItems' own real
    -- return shape (an array of ItemSlot-alikes), keyed by the TARGET's own
    -- live numeric server id, matching HandleSearchTarget's own real
    -- inventoryId derivation for a connected player (server/search.lua).
    local inventoryItemsBySrc = {}
    for src, items in pairs(contrabandOpts.inventoryItemsBySrc or {}) do
        inventoryItemsBySrc[src] = items
    end
    local K9CompatStub = {
        Get = function(name)
            if name == 'inventory' then
                return {
                    GetInventoryItems = function(src) return inventoryItemsBySrc[src] end,
                    -- No container-recursion fixtures needed for this
                    -- pass's own pinned tests (mirrors server/search.lua's
                    -- own SumContrabandWeight, already independently tested
                    -- elsewhere for the container-recursion case) --
                    -- always "no container here", never a crash.
                    GetContainerFromSlot = function(_inventoryId, _slot) return nil end,
                }
            end
            return nil
        end,
    }

    -- Deterministic, REVERSIBLE stub (never the real 32-bit-wrap semantics,
    -- which this suite has no need to reproduce) -- entity handle + a fixed
    -- offset, so a test can predict exactly which netId a given pedHandle
    -- will be reported under without needing to inspect the stub's own
    -- internals.
    local function NetworkGetNetworkIdFromEntity(entity) return entity + 10000 end

    local Config = {
        Features = { ScentVision = true },
        K9Specializations = contrabandOpts.k9Specializations or {},
        SearchContrabandItems = contrabandOpts.searchContrabandItems or {},
        SearchZones = contrabandOpts.searchZones or { personSearchDistance = 2.0 },
        Tracking = {
            -- REQUIRED even though this fixture never exercises Scent/Blood/
            -- Gunpowder directly (qa-tester finding, this pass): server/tracking.lua's
            -- own PruneTrackableLogs runs on an UNCONDITIONAL thread (no
            -- Config.Features gate at all) and reads
            -- Config.Tracking.Scent/Blood/Gunpowder.maxAgeSeconds every
            -- TRACKABLE_LOG_PRUNE_INTERVAL_MS (15000ms) regardless of which
            -- feature is under test -- a ScentVision test that advances the
            -- clock past that threshold and then calls `f.step()` would
            -- otherwise crash this fixture with "attempt to index a nil
            -- value (field 'Scent')" the instant that thread's own Wait
            -- resolves. Real config.lua always ships all four
            -- Config.Tracking sub-tables together; this fixture must too.
            Scent     = { maxAgeSeconds = 300 },
            Blood     = { maxAgeSeconds = 300 },
            Gunpowder = { maxAgeSeconds = 120 },
            ScentVision = {
                sampleIntervalMs        = 4000,
                minSampleMovementMeters = 2.0,
                maxPointsPerPerson      = 4,  -- small, deliberately, so the hard cap is easy to reach in a test
                dotLifetimeMs           = 45000,
                queryRangeMeters        = 40.0,
                maxVisibleTrails        = 2,  -- small, deliberately, so "handful" truncation is easy to prove
                queryMaxPointsPerTrail  = 12,
                queryCooldownMs         = 1000,
                mode                    = 'keybind', -- matches config.lua's own shipped default; set via opts.trackingOverrides for the MODE section's own tests below
                palette = {
                    { r = 230, g = 25,  b = 75  },
                    { r = 60,  g = 180, b = 75  },
                },
            },
        },
        FeatureControl = { RequireGrant = requireGrant },
    }
    for k, v in pairs(opts.trackingOverrides or {}) do
        Config.Tracking.ScentVision[k] = v
    end

    if opts.contraband then
        Config.Tracking.ScentVision.contrabandHighlight = {
            enabled = contrabandOpts.enabled ~= false, -- default true whenever opts.contraband is passed at all
            rangeMeters = contrabandOpts.rangeMeters or 2.0,
            categoryPalette = contrabandOpts.categoryPalette or { { r = 1, g = 1, b = 1 } },
            baselineColor = contrabandOpts.baselineColor or { r = 9, g = 9, b = 9 },
        }
    end

    local registeredCallbacks = {}
    local libStub = { callback = { register = function(name, fn) registeredCallbacks[name] = fn end } }

    local eventHandlers = {}
    local function AddEventHandler(name, fn)
        eventHandlers[name] = eventHandlers[name] or {}
        eventHandlers[name][#eventHandlers[name] + 1] = fn
    end
    local function RegisterNetEvent(name, fn)
        eventHandlers[name] = eventHandlers[name] or {}
        eventHandlers[name][#eventHandlers[name] + 1] = fn
    end

    local function GetCurrentResourceName() return 'john-k9' end

    local env = Sandbox.newEnv({
        Config = Config,
        GetGameTimer = GetGameTimer,
        print = printStub,
        exports = exportsTable,
        GetPlayers = GetPlayers,
        GetPlayerPed = GetPlayerPed,
        GetEntityCoords = GetEntityCoords,
        HasK9Access = HasK9Access,
        HasPermission = defaultHasPermission,
        HasSpecialization = HasSpecialization,
        K9Compat = K9CompatStub,
        NetworkGetNetworkIdFromEntity = NetworkGetNetworkIdFromEntity,
        lib = libStub,
        RegisterNetEvent = RegisterNetEvent,
        AddEventHandler = AddEventHandler,
        GetCurrentResourceName = GetCurrentResourceName,
        CreateThread = threadRunner.CreateThread,
        Wait = threadRunner.Wait,
    })

    Sandbox.loadInto('../server/cooldowns.lua', env)
    Sandbox.loadInto('../server/tracking.lua', env)

    return {
        Config = Config,
        printLog = printLog,
        advance = function(ms) state.now = state.now + ms end,
        step = threadRunner.step,
        registerPlayer = registerPlayer,
        setPedCoords = setPedCoords,
        --- Fires every RegisterPlayerDropped-registered handler AND this
        --- file's own final playerDropped handler -- the real cleanup path,
        --- not a reimplementation of it.
        disconnectPlayer = function(src)
            connected[src] = nil
            env.source = src
            for _, fn in ipairs(eventHandlers['playerDropped'] or {}) do fn('test') end
        end,
        grantPermission = function(citizenid, key, value)
            permissionGrants[citizenid] = permissionGrants[citizenid] or {}
            permissionGrants[citizenid][key] = value
        end,
        getScentVisionPoints = function(src)
            local handler = assert(registeredCallbacks['john-k9:server:getScentVisionPoints'],
                'server/tracking.lua did not register john-k9:server:getScentVisionPoints')
            return handler(src)
        end,
    }
end

t.test('ScentVision: a moving player is captured across multiple sample passes and revealed to a nearby K9, coloured', function()
    local f = newScentVisionFixture()
    f.registerPlayer(1, 'K9-CID', 100)      -- the querying K9
    f.registerPlayer(2, 'SUSPECT-CID', 200) -- the person being tracked
    f.setPedCoords(1, 0, 0, 0)
    f.setPedCoords(2, 0, 0, 0)

    f.step() -- primes all captured threads (reaches each one's first Wait, no capture work yet)

    -- Walk the suspect a few metres each capture pass -- comfortably past
    -- minSampleMovementMeters (2.0) every time, so every pass records a NEW point.
    f.setPedCoords(2, 5, 0, 0)
    f.step()
    f.setPedCoords(2, 10, 0, 0)
    f.step()
    f.setPedCoords(2, 15, 0, 0)
    f.step()

    local result = f.getScentVisionPoints(1)
    t.isTrue(#result.points >= 3, ('expected at least 3 captured points, got %d'):format(#result.points))
    for _, p in ipairs(result.points) do
        t.isTrue(type(p.r) == 'number' and type(p.g) == 'number' and type(p.b) == 'number', 'every revealed point must carry a colour')
        t.isNil(p.citizenid, 'the client must never be told WHO a point belongs to')
        t.isNil(p.source, 'the client must never be told WHO a point belongs to')
    end
end)

t.test('ScentVision: each dot expires against its OWN timestamp -- advancing the clock directly (no extra capture passes) expires it', function()
    local f = newScentVisionFixture({ trackingOverrides = { dotLifetimeMs = 10000 } })
    f.registerPlayer(1, 'K9-CID', 100)
    f.registerPlayer(2, 'SUSPECT-CID', 200)
    f.setPedCoords(1, 0, 0, 0)
    f.setPedCoords(2, 5, 0, 0)

    f.step() -- prime
    f.step() -- capture pass #1 -- one point recorded at the current GetGameTimer()

    local beforeExpiry = f.getScentVisionPoints(1)
    t.isTrue(#beforeExpiry.points >= 1, 'the point must still be visible before its own lifetime elapses')

    -- Advance the CLOCK directly past dotLifetimeMs -- no additional capture
    -- passes, no additional frames -- proving expiry is evaluated against a
    -- TIMESTAMP, never a per-frame-decremented countdown (owner's own
    -- explicit requirement).
    f.advance(10001)

    local afterExpiry = f.getScentVisionPoints(1)
    t.equals(#afterExpiry.points, 0, 'a point older than dotLifetimeMs must never be revealed, regardless of how it got old')
end)

t.test('LOITER FIX: a player who stays within minSampleMovementMeters of their own last dot has that dot\'s decay RESET on every capture pass, instead of aging out on schedule', function()
    -- mana_policedogs competitor-parity request: "if a player hasn't moved
    -- far enough away from their last dropped scent, their existing scent
    -- will have its decay reset." Regression for the bug this pass fixes
    -- in RecordScentVisionPoint (server/tracking.lua): the "hasn't moved
    -- far enough" branch used to just `return`, never touching the
    -- existing point's own timestamp, so a perfectly stationary player's
    -- one dot aged out on the ORIGINAL capture time regardless of how long
    -- they kept standing right there.
    --
    -- TEST-DESIGN NOTE (do not "simplify" this back, it was tried and it
    -- masks the bug): querying IMMEDIATELY after a capture pass is not a
    -- valid way to observe this fix. RecordScentVisionPoint's own
    -- DiscardExpiredScentVisionPoints call runs FIRST, on every pass, even
    -- pre-fix -- so if a capture pass happens to land AFTER the point's
    -- original timestamp has already aged past dotLifetimeMs, the OLD
    -- (buggy) code evicts it and then immediately appends a brand-new
    -- point at that SAME pass's `now`, which coincidentally reads exactly
    -- like a "reset" if you only ever query right after a capture pass --
    -- even with the bug still present. The real, user-visible bug is a
    -- point going dark in the GAP BETWEEN two capture passes. This test
    -- therefore queries `advance()`d past the point's ORIGINAL lifetime
    -- WITHOUT an intervening capture pass, exactly mirroring the sibling
    -- "each dot expires against its OWN timestamp -- advancing the clock
    -- directly" test's own technique above.
    local f = newScentVisionFixture({ trackingOverrides = { dotLifetimeMs = 10000, minSampleMovementMeters = 2.0 } })
    f.registerPlayer(1, 'K9-CID', 100)      -- the querying K9
    f.registerPlayer(2, 'SUSPECT-CID', 200) -- the loitering suspect
    f.setPedCoords(1, 0, 0, 0)
    f.setPedCoords(2, 0, 0, 0)

    f.step() -- prime
    f.step() -- capture pass #1 -- one point recorded at t = 0 (relative)

    -- Suspect stands PERFECTLY still (never moves past minSampleMovementMeters)
    -- across two more capture passes, each only 4000ms apart -- comfortably
    -- UNDER dotLifetimeMs (10000), so DiscardExpiredScentVisionPoints never
    -- evicts anything at either of these two passes, pre- or post-fix. This
    -- is what isolates the ACTUAL branch under test (the refresh-on-loiter
    -- fix), rather than the evict-and-recreate path covered by the note
    -- above.
    f.advance(4000)
    f.step() -- capture pass #2 -- still at (0,0,0): fixed code refreshes the dot's timestamp to t=4000; buggy code leaves it at t=0
    f.advance(4000)
    f.step() -- capture pass #3 -- still at (0,0,0): fixed code refreshes to t=8000; buggy code STILL leaves it at t=0

    -- Advance the CLOCK ONLY (no further capture pass) to t=12000 and query
    -- right there, in the gap before capture pass #4 would ever run.
    -- Fixed: dot's own age is (12000 - 8000) = 4000ms, well alive.
    -- Buggy: dot's own age is STILL measured against its never-updated t=0
    -- timestamp -- (12000 - 0) = 12000ms, past dotLifetimeMs (10000) -- the
    -- query-time freshness filter in getScentVisionPoints (which reads the
    -- SAME stored timestamp, independently of any discard pass) excludes
    -- it, and this assertion fails, exactly the bug being fixed.
    f.advance(4000)

    local result = f.getScentVisionPoints(1)
    t.equals(#result.points, 1, 'a stationary player\'s dot must still be alive after its ORIGINAL age would have expired it, because every capture pass while loitering refreshes it -- querying between capture passes (not immediately after one) is what actually proves this')
end)

t.test('LOITER FIX: refreshing a stationary dot never grows storage -- a long loiter still holds exactly one point in the underlying bucket', function()
    local f = newScentVisionFixture({ trackingOverrides = { dotLifetimeMs = 10000, minSampleMovementMeters = 2.0, maxPointsPerPerson = 4 } })
    f.registerPlayer(1, 'K9-CID', 100)
    f.registerPlayer(2, 'SUSPECT-CID', 200)
    f.setPedCoords(1, 0, 0, 0)
    f.setPedCoords(2, 0, 0, 0)

    f.step() -- prime

    -- Many capture passes, all at the exact same spot, each spaced well
    -- under dotLifetimeMs -- if the fix ever appended instead of
    -- refreshing, this would blow straight past maxPointsPerPerson (4) and
    -- this assertion would fail.
    for _ = 1, 10 do
        f.advance(1000)
        f.step()
    end

    local result = f.getScentVisionPoints(1)
    t.equals(#result.points, 1, 'loitering in one spot must never accumulate more than the single dot minSampleMovementMeters already limits a stationary player to')
end)

t.test('ScentVision: maxPointsPerPerson is a hard cap regardless of how many capture passes accumulate', function()
    local f = newScentVisionFixture({ trackingOverrides = { maxPointsPerPerson = 3 } })
    f.registerPlayer(1, 'K9-CID', 100)
    f.registerPlayer(2, 'SUSPECT-CID', 200)
    f.setPedCoords(1, 0, 0, 0)
    f.setPedCoords(2, 0, 0, 0)

    f.step() -- prime

    for i = 1, 10 do
        f.setPedCoords(2, i * 3, 0, 0) -- always moves well past minSampleMovementMeters
        f.step()
    end

    local result = f.getScentVisionPoints(1)
    t.isTrue(#result.points <= 3, ('expected at most 3 points (hard cap), got %d'):format(#result.points))
end)

-- ========================================================================
-- UPPER CEILING on maxPointsPerPerson (performance audit at 128 players,
-- this pass). See server/tracking.lua's own
-- SCENT_VISION_MAX_POINTS_PER_PERSON_CEILING declaration comment for the
-- full worked arithmetic. This field is the one caller of
-- ResolveScentVisionNumber that passes an upper `maxAllowed` -- matching
-- server/runtimecontrol.lua's own tablet-side bound (min=1, max=50) for the
-- identical field, so a config.lua hand-edit cannot reach a value the
-- tablet's own UI already refuses.
-- ========================================================================

t.test('ScentVision: an excessively large maxPointsPerPerson is clamped to this resource\'s own ceiling (50) and warns, rather than reintroducing unbounded per-player trail memory', function()
    -- queryMaxPointsPerTrail/queryRangeMeters overridden generously large so
    -- the QUERY side never masks what this test actually cares about: the
    -- STORAGE-side cap enforced by RecordScentVisionPoint's own `maxPoints`
    -- (resolved from maxPointsPerPerson). Clock is never advanced between
    -- capture passes (matching the sibling hard-cap test just above), so
    -- dotLifetimeMs expiry cannot be the reason any point is missing either.
    local f = newScentVisionFixture({ trackingOverrides = {
        maxPointsPerPerson     = 100000, -- far above the 50 ceiling this resource enforces
        minSampleMovementMeters = 0.5,
        queryMaxPointsPerTrail  = 100000,
        queryRangeMeters        = 100000,
    } })
    f.registerPlayer(1, 'K9-CID', 100)
    f.registerPlayer(2, 'SUSPECT-CID', 200)
    f.setPedCoords(1, 0, 0, 0)
    f.setPedCoords(2, 0, 0, 0)

    f.step() -- prime

    for i = 1, 55 do
        f.setPedCoords(2, i * 1, 0, 0) -- always moves well past minSampleMovementMeters (0.5)
        f.step()
    end

    local result = f.getScentVisionPoints(1)
    t.isTrue(#result.points <= 50,
        ('expected at most 50 points (this resource\'s own built-in ceiling, matching the tablet\'s own bound), got %d -- an unclamped maxPointsPerPerson would have let this reach 55'):format(#result.points))

    local warningLine
    for _, line in ipairs(f.printLog) do
        if line:find('Config.Tracking.ScentVision.maxPointsPerPerson', 1, true) and line:find('exceeds', 1, true) then
            warningLine = line
        end
    end
    t.isNotNil(warningLine, 'an excessively large maxPointsPerPerson must print a warning naming the exact key')
    t.contains(warningLine, '100000', 'the warning must name the value that was actually found')
    t.contains(warningLine, '50', 'the warning must name the ceiling value substituted')
end)

t.test('ScentVision: the shipped default (15) and the tablet\'s own max (50) both sit at-or-under the ceiling -- neither ever warns', function()
    local f1 = newScentVisionFixture() -- fixture default maxPointsPerPerson = 4, well under
    f1.registerPlayer(1, 'K9-CID', 100)
    f1.registerPlayer(2, 'SUSPECT-CID', 200)
    f1.setPedCoords(1, 0, 0, 0)
    f1.setPedCoords(2, 0, 0, 0)
    f1.step()
    f1.setPedCoords(2, 5, 0, 0)
    f1.step()
    for _, line in ipairs(f1.printLog) do
        t.isFalse(line:find('maxPointsPerPerson', 1, true) ~= nil and line:find('exceeds', 1, true) ~= nil,
            'a small, legitimate maxPointsPerPerson must never trip the upper-ceiling warning: ' .. line)
    end

    local f2 = newScentVisionFixture({ trackingOverrides = { maxPointsPerPerson = 50 } }) -- exactly the tablet's own max
    f2.registerPlayer(1, 'K9-CID', 100)
    f2.registerPlayer(2, 'SUSPECT-CID', 200)
    f2.setPedCoords(1, 0, 0, 0)
    f2.setPedCoords(2, 0, 0, 0)
    f2.step()
    f2.setPedCoords(2, 5, 0, 0)
    f2.step()
    for _, line in ipairs(f2.printLog) do
        t.isFalse(line:find('maxPointsPerPerson', 1, true) ~= nil and line:find('exceeds', 1, true) ~= nil,
            'exactly the tablet\'s own max (50) must never itself trigger the "exceeds" warning: ' .. line)
    end
end)

t.test('ScentVision: only maxVisibleTrails distinct trails are revealed at once -- the FURTHEST is dropped under load', function()
    local f = newScentVisionFixture() -- maxVisibleTrails = 2 in this fixture's own defaults
    f.registerPlayer(1, 'K9-CID', 100)
    f.registerPlayer(2, 'NEAR-CID', 200)
    f.registerPlayer(3, 'MID-CID', 300)
    f.registerPlayer(4, 'FAR-CID', 400)
    f.setPedCoords(1, 0, 0, 0)
    f.setPedCoords(2, 5, 0, 0)
    f.setPedCoords(3, 15, 0, 0)
    f.setPedCoords(4, 25, 0, 0)

    f.step() -- prime
    f.step() -- capture pass #1 -- all three get their first point recorded

    local result = f.getScentVisionPoints(1)
    t.equals(#result.points, 2, 'only maxVisibleTrails (2) distinct trails-worth of points may be revealed at once')

    local sawFar = false
    for _, p in ipairs(result.points) do
        if p.x == 25 then sawFar = true end
    end
    t.isFalse(sawFar, 'the FURTHEST trail (x=25) must be the one dropped when more than maxVisibleTrails are in range')
end)

-- ========================================================================
-- PER-PERSON DURABLE COLOUR (owner-directed follow-up, 2026-08-26 -- "hold
-- a colour stable... the same person is the same colour... for every
-- handler looking"). REPLACES a PRE-EXISTING test here
-- ("a freed slot is reused by a newcomer...") that pinned the OLD
-- per-observer/slot-reuse mechanism this pass replaced -- that old test
-- happened to still PASS after the rewrite (a coincidental hash collision
-- between its own 'A-CID'/'C-CID' fixture citizenids at the fixture's
-- 2-swatch palette made its final assertion true for the wrong reason),
-- which is exactly the kind of accidentally-still-green, no-longer-honest
-- test this whole pass's own "prove it, don't assume it" discipline exists
-- to catch. Removed rather than left, and replaced with tests that pin the
-- REAL, NEW mechanism (a pure hash of citizenid, no server-side memory).
-- ========================================================================

t.test('ScentVision: the SAME citizenid gets the SAME colour across repeated queries, with no state change in between', function()
    local f = newScentVisionFixture()
    f.registerPlayer(1, 'K9-CID', 100)
    f.registerPlayer(2, 'SUSPECT-CID', 200)
    f.setPedCoords(1, 0, 0, 0)
    f.setPedCoords(2, 5, 0, 0)
    f.step()
    f.step()

    local first = f.getScentVisionPoints(1)
    t.equals(#first.points, 1)
    local firstColor = { r = first.points[1].r, g = first.points[1].g, b = first.points[1].b }

    f.advance(2000) -- clear queryCooldownMs before the next query
    local second = f.getScentVisionPoints(1)
    t.equals(#second.points, 1)
    t.equals(second.points[1].r, firstColor.r, 'repeated queries for the SAME still-visible person must return the SAME colour')
    t.equals(second.points[1].g, firstColor.g, 'repeated queries for the SAME still-visible person must return the SAME colour')
    t.equals(second.points[1].b, firstColor.b, 'repeated queries for the SAME still-visible person must return the SAME colour')
end)

t.test('ScentVision: colour is DURABLE per citizenid -- reconnecting under a brand-new (recycled) source number still gets the SAME colour, while an unrelated still-visible trail is unaffected', function()
    local f = newScentVisionFixture() -- maxVisibleTrails = 2, palette length 2
    f.registerPlayer(1, 'K9-CID', 100)
    f.registerPlayer(2, 'A-CID', 200)
    f.registerPlayer(3, 'B-CID', 300)
    f.setPedCoords(1, 0, 0, 0)
    f.setPedCoords(2, 5, 0, 0)
    f.setPedCoords(3, 10, 0, 0)

    f.step() -- prime
    f.step() -- capture pass #1 -- A and B both logged

    local first = f.getScentVisionPoints(1)
    t.equals(#first.points, 2)
    local colorByX = {}
    for _, p in ipairs(first.points) do colorByX[p.x] = { r = p.r, g = p.g, b = p.b } end
    local aColorBefore, bColor = colorByX[5], colorByX[10]
    t.isNotNil(aColorBefore, 'A-CID must be visible before disconnecting')
    t.isNotNil(bColor, 'B-CID must be visible throughout')

    -- A-CID disconnects entirely (PositionTrail[2] is cleared).
    f.disconnectPlayer(2)

    -- A-CID reconnects under a BRAND-NEW source number -- this codebase's
    -- own standing discipline is that server ids are RECYCLED, so this is
    -- the expected shape of a reconnect, not an edge case being invented
    -- for this test.
    f.registerPlayer(5, 'A-CID', 500)
    f.setPedCoords(5, 5, 0, 0)
    f.advance(2000) -- clear queryCooldownMs before the next query
    f.step()

    local second = f.getScentVisionPoints(1)
    t.equals(#second.points, 2, "B-CID (never left) plus A-CID (reconnected under a new source number) fill the same 2 slots")
    local colorByX2 = {}
    for _, p in ipairs(second.points) do colorByX2[p.x] = { r = p.r, g = p.g, b = p.b } end

    t.equals(colorByX2[10].r, bColor.r, "B-CID's colour must be UNCHANGED -- it never left the visible set")
    t.equals(colorByX2[10].g, bColor.g, "B-CID's colour must be UNCHANGED -- it never left the visible set")
    t.equals(colorByX2[10].b, bColor.b, "B-CID's colour must be UNCHANGED -- it never left the visible set")

    t.equals(colorByX2[5].r, aColorBefore.r, "A-CID's colour is DURABLE -- reconnecting under a brand-new source number must reproduce the exact same colour, since it is now a pure function of citizenid, never a per-observer slot")
    t.equals(colorByX2[5].g, aColorBefore.g, "A-CID's colour is DURABLE across a reconnect")
    t.equals(colorByX2[5].b, aColorBefore.b, "A-CID's colour is DURABLE across a reconnect")
end)

t.test("ScentVision: two different citizenids get DIFFERENT colours when the palette has room (indices verified by directly computing this resource's own hash formula, not assumed)", function()
    -- 'A-CID' and 'B-CID' were verified, by running this resource's own
    -- HashStringToIndex formula (server/tracking.lua) directly against a
    -- 5-entry palette BEFORE this test was written, to resolve to indices 3
    -- and 4 respectively -- picked BECAUSE they differ, not assumed to.
    local f = newScentVisionFixture({
        trackingOverrides = {
            maxVisibleTrails = 2,
            palette = {
                { r = 1, g = 1, b = 1 },
                { r = 2, g = 2, b = 2 },
                { r = 3, g = 3, b = 3 }, -- index 3 -- A-CID's own colour
                { r = 4, g = 4, b = 4 }, -- index 4 -- B-CID's own colour
                { r = 5, g = 5, b = 5 },
            },
        },
    })
    f.registerPlayer(1, 'K9-CID', 100)
    f.registerPlayer(2, 'A-CID', 200)
    f.registerPlayer(3, 'B-CID', 300)
    f.setPedCoords(1, 0, 0, 0)
    f.setPedCoords(2, 5, 0, 0)
    f.setPedCoords(3, 10, 0, 0)

    f.step()
    f.step()

    local result = f.getScentVisionPoints(1)
    t.equals(#result.points, 2)
    local colorByX = {}
    for _, p in ipairs(result.points) do colorByX[p.x] = { r = p.r, g = p.g, b = p.b } end

    t.equals(colorByX[5].r, 3, "A-CID must resolve to palette index 3 (r=3), per this resource's own HashStringToIndex formula")
    t.equals(colorByX[10].r, 4, "B-CID must resolve to palette index 4 (r=4), per this resource's own HashStringToIndex formula")
    t.isFalse(colorByX[5].r == colorByX[10].r, 'two different citizenids with room in the palette must get genuinely different colours')
end)

t.test('ScentVision: colours REPEAT once there are more distinct people than palette swatches -- disclosed, accepted (pigeonhole: 3 people can never produce more than 2 distinct colours out of a 2-swatch palette)', function()
    local f = newScentVisionFixture({ trackingOverrides = { maxVisibleTrails = 3 } }) -- palette length 2, fixture default
    f.registerPlayer(1, 'K9-CID', 100)
    f.registerPlayer(2, 'A-CID', 200)
    f.registerPlayer(3, 'B-CID', 300)
    f.registerPlayer(4, 'C-CID', 400)
    f.setPedCoords(1, 0, 0, 0)
    f.setPedCoords(2, 5, 0, 0)
    f.setPedCoords(3, 10, 0, 0)
    f.setPedCoords(4, 15, 0, 0)

    f.step()
    f.step()

    local result = f.getScentVisionPoints(1)
    t.equals(#result.points, 3, 'all three must be simultaneously visible for the pigeonhole argument below to apply')

    local seenColorKeys = {}
    local distinctCount = 0
    for _, p in ipairs(result.points) do
        local key = ('%d,%d,%d'):format(p.r, p.g, p.b)
        if not seenColorKeys[key] then
            seenColorKeys[key] = true
            distinctCount = distinctCount + 1
        end
    end
    t.isTrue(distinctCount <= 2, ('a 2-swatch palette showing 3 simultaneously-visible people must produce AT MOST 2 distinct colours (pigeonhole) -- got %d distinct colours, which would mean this implementation used a colour outside the configured palette'):format(distinctCount))
end)

t.test("ScentVision: a K9 never sees their own trail", function()
    local f = newScentVisionFixture()
    f.registerPlayer(1, 'K9-CID', 100)
    f.setPedCoords(1, 0, 0, 0)

    f.step()
    f.setPedCoords(1, 5, 0, 0)
    f.step()

    local result = f.getScentVisionPoints(1)
    t.equals(#result.points, 0, "a K9's own recorded trail must never be revealed back to themselves")
end)

t.test('ScentVision: a non-positive dotLifetimeMs is clamped to a safe default, never read as "forever" (or the opposite failure -- instant, silent, total blindness)', function()
    local f = newScentVisionFixture({ trackingOverrides = { dotLifetimeMs = 0 } })
    f.registerPlayer(1, 'K9-CID', 100)
    f.registerPlayer(2, 'SUSPECT-CID', 200)
    f.setPedCoords(1, 0, 0, 0)
    f.setPedCoords(2, 5, 0, 0)

    f.step()
    f.step()

    -- The safe fallback default (45000ms, server/tracking.lua's own
    -- ResolveConfiguredThresholdMs call site) must be in effect -- advancing
    -- well past it must still expire the point, proving 0 did NOT silently
    -- become "no expiry ever".
    f.advance(45001)
    local result = f.getScentVisionPoints(1)
    t.equals(#result.points, 0, 'dotLifetimeMs = 0 must fall back to a safe positive default, never "forever"')
    t.isTrue(#f.printLog > 0, 'a bad dotLifetimeMs must print a loud, named warning, not fail silently')
end)

t.test('ScentVision: block.ScentVision denies the reveal outright, even with a fresh in-range trail', function()
    local f = newScentVisionFixture()
    f.registerPlayer(1, 'K9-CID', 100)
    f.registerPlayer(2, 'SUSPECT-CID', 200)
    f.setPedCoords(1, 0, 0, 0)
    f.setPedCoords(2, 5, 0, 0)
    f.grantPermission('K9-CID', 'block.ScentVision', true)

    f.step()
    f.step()

    local result = f.getScentVisionPoints(1)
    t.equals(#result.points, 0, 'block.ScentVision must deny the reveal regardless of a real, in-range trail')
end)

t.test('ScentVision: the server enforces queryCooldownMs regardless of how fast the client asks', function()
    local f = newScentVisionFixture()
    f.registerPlayer(1, 'K9-CID', 100)
    f.registerPlayer(2, 'SUSPECT-CID', 200)
    f.setPedCoords(1, 0, 0, 0)
    f.setPedCoords(2, 5, 0, 0)

    f.step()
    f.step()

    local firstResult = f.getScentVisionPoints(1)
    t.isTrue(#firstResult.points > 0)

    -- Same instant, no advance() -- a second immediate query must be refused.
    local secondResult = f.getScentVisionPoints(1)
    t.equals(#secondResult.points, 0, 'a query inside queryCooldownMs must be refused, not answered again for free')
end)

-- ========================================================================
-- MODE (Config.Tracking.ScentVision.mode) -- owner-directed pass: "make the
-- scent tracking a keybind and choose always active or [not]". Server-side
-- coverage only: this file never decides whether to RENDER (that is
-- entirely client/tracking.lua's job, covered by tests/clienttracking_spec.lua)
-- -- it only proves (1) getScentVisionPoints echoes the server's own live-
-- resolved mode fresh on every call, the exact channel the client relies on
-- to stop rendering live, and (2) that value never changes what/whether the
-- capture thread records, per this task's own explicit requirement that
-- 'always' must cost nothing extra server-side.
-- ========================================================================

t.test('MODE: getScentVisionPoints echoes the configured mode back on a successful query', function()
    local f = newScentVisionFixture({ trackingOverrides = { mode = 'always' } })
    f.registerPlayer(1, 'K9-CID', 100)
    f.registerPlayer(2, 'SUSPECT-CID', 200)
    f.setPedCoords(1, 0, 0, 0)
    f.setPedCoords(2, 5, 0, 0)

    f.step()
    f.step()

    local result = f.getScentVisionPoints(1)
    t.equals(result.mode, 'always', 'the echoed mode must match the live server config, not a stale/default guess')
end)

-- THE LEAK THIS SECTION USED TO STEP AROUND.
-- Two independent red-team passes reproduced the same thing: `mode` was
-- resolved only to be echoed back for the client to decide whether to
-- render, and nothing on the server stopped a query when it was 'off'.
-- Any certified handler with a modified client could call this callback
-- directly on the 1s cooldown floor and receive live position trails of
-- every player in range -- a real-time wallhack, running precisely while
-- the admin control meant to prevent it was switched on. Background
-- capture keeps running in 'off' mode by design, so the data was always
-- fresh and waiting.
-- The old MODE test below deliberately flipped mode back to 'keybind'
-- before querying, so this exact case shipped untested. It is tested now.
t.test('MODE: "off" returns NO points to a direct callback call -- the off switch is enforced on the SERVER, not merely respected by a cooperating client', function()
    local f = newScentVisionFixture({ trackingOverrides = { mode = 'off' } })
    f.registerPlayer(1, 'K9-CID', 100)
    f.registerPlayer(2, 'SUSPECT-CID', 200)
    f.setPedCoords(1, 0, 0, 0)
    f.setPedCoords(2, 5, 0, 0)

    -- Let the capture thread record real, in-range points for the victim.
    -- They must exist and be fresh -- otherwise this test would pass for
    -- the wrong reason, proving only that nothing was captured.
    f.step()
    f.step()

    local result = f.getScentVisionPoints(1)
    t.equals(#result.points, 0, 'a direct call while mode is "off" must return nothing -- the client choosing not to poll is a courtesy, not a boundary, and a modified client does not extend that courtesy')
    t.equals(result.mode, 'off', 'the echoed mode must still be honest so a cooperating client also stops rendering')

    -- Control: the same fixture, same players, same captured data, with the
    -- switch on -- proving the zero above is caused by the mode and not by
    -- an empty capture.
    local g = newScentVisionFixture({ trackingOverrides = { mode = 'keybind' } })
    g.registerPlayer(1, 'K9-CID', 100)
    g.registerPlayer(2, 'SUSPECT-CID', 200)
    g.setPedCoords(1, 0, 0, 0)
    g.setPedCoords(2, 5, 0, 0)
    g.step()
    g.step()
    t.isTrue(#g.getScentVisionPoints(1).points > 0, 'control: with mode on, this same setup DOES return points -- so the zero above is the mode, not a fixture quirk')
end)

t.test('MODE: an unrecognised Config.Tracking.ScentVision.mode falls back to "keybind" and warns once, naming the exact setting', function()
    local f = newScentVisionFixture({ trackingOverrides = { mode = 'bogus-value' } })
    f.registerPlayer(1, 'K9-CID', 100)
    f.registerPlayer(2, 'SUSPECT-CID', 200)
    f.setPedCoords(1, 0, 0, 0)
    f.setPedCoords(2, 5, 0, 0)

    f.step()
    f.step()

    local result = f.getScentVisionPoints(1)
    t.equals(result.mode, 'keybind', 'a bad mode value must never silently become "always" -- the safest default wins')

    local warned = false
    for _, line in ipairs(f.printLog) do
        if line:find('Config.Tracking.ScentVision.mode', 1, true) then warned = true end
    end
    t.isTrue(warned, 'a bad mode value must print a loud warning naming this exact setting, never fail silently')
end)

t.test('MODE: Config.Features.ScentVision = false echoes mode = "off" regardless of Config.Tracking.ScentVision.mode\'s own value', function()
    local f = newScentVisionFixture({ trackingOverrides = { mode = 'always' } })
    f.Config.Features.ScentVision = false

    local result = f.getScentVisionPoints(1) -- no players registered at all -- must not error
    t.equals(result.mode, 'off', 'the master feature being off must read as mode == "off" to an already-polling client, regardless of the mode field')
    t.equals(#result.points, 0)
end)

t.test('MODE: "off" does NOT change the capture threads own cost -- population-wide sampling keeps recording exactly as it does under "keybind"/"always"', function()
    local f = newScentVisionFixture({ trackingOverrides = { mode = 'off' } })
    f.registerPlayer(1, 'K9-CID', 100)
    f.registerPlayer(2, 'SUSPECT-CID', 200)
    f.setPedCoords(1, 0, 0, 0)
    f.setPedCoords(2, 0, 0, 0)

    f.step() -- prime

    f.setPedCoords(2, 5, 0, 0)
    f.step()
    f.setPedCoords(2, 10, 0, 0)
    f.step()

    -- Read the reveal back with mode flipped to 'keybind' -- the QUERY side
    -- is allowed to differ by mode in principle, but the CAPTURE that
    -- already happened above (while mode was 'off') must have recorded
    -- real points regardless, proving the capture thread never consulted
    -- `mode` at all -- exactly this task's own "must NOT change the
    -- server-side sampling cost" requirement.
    f.Config.Tracking.ScentVision.mode = 'keybind'
    local result = f.getScentVisionPoints(1)
    t.isTrue(#result.points >= 2, ('capture must be unaffected by mode == "off" -- expected at least 2 points, got %d'):format(#result.points))
end)

-- ========================================================================
-- CONTRABAND BODY HIGHLIGHT (owner-directed follow-up, 2026-08-26 --
-- "diffrent colors on there body if they have explosives drugs etc"). See
-- server/tracking.lua's own "CONTRABAND BODY HIGHLIGHT" header (five
-- decisions) for the design this pins. Uses newScentVisionFixture's
-- opts.contraband extension (see that fixture's own comment for the exact
-- shape) -- every test below is OPT-IN (opts.contraband present), so none
-- of the ScentVision-only tests above this point are affected.
-- ========================================================================

--- Recursively walks `value` and asserts every TABLE KEY encountered is in
--- `allowedKeys`, and every STRING/NUMBER LEAF is not one of the forbidden
--- `forbiddenValues` -- the "assert on the payload's actual shape, not on
--- intent" check this pass's own task explicitly demanded, rather than
--- trusting that the production code simply "doesn't mean to" leak an item
--- name/count/weight.
--- @param value any
--- @param allowedKeys table<string, boolean>
--- @param forbiddenValues table<any, boolean>
--- @param path string
local function assertPayloadShape(value, allowedKeys, forbiddenValues, path)
    if type(value) == 'table' then
        for k, v in pairs(value) do
            if type(k) == 'string' then
                t.isTrue(allowedKeys[k] == true, ('payload key %q at %s is not in the allow-list -- the server must never send a field this suite has not explicitly vetted'):format(k, path))
            end
            assertPayloadShape(v, allowedKeys, forbiddenValues, path .. '.' .. tostring(k))
        end
    elseif type(value) == 'string' or type(value) == 'number' then
        t.isFalse(forbiddenValues[value] == true, ('forbidden value %s found at %s -- the server must never send an item name, count, or weight'):format(tostring(value), path))
    end
end

local CONTRABAND_PAYLOAD_ALLOWED_KEYS = {
    points = true, highlights = true, mode = true, dotLifetimeMs = true,
    x = true, y = true, z = true, r = true, g = true, b = true, ageMs = true,
    netId = true, colors = true,
}

t.test('CONTRABAND HIGHLIGHT: a dog with NO matching specialization gets NO highlight for a categorised item, and the payload contains nothing it could infer one from', function()
    local f = newScentVisionFixture({
        contraband = {
            rangeMeters = 2.0,
            k9Specializations = { narcotics = {}, explosives = {} },
            searchContrabandItems = { coke_brick = 'narcotics' },
            searchZones = { personSearchDistance = 2.0 },
            specializationGrants = {}, -- K9-CID holds NOTHING
            inventoryItemsBySrc = { [2] = { { name = 'coke_brick', slot = 1, weight = 1.0 } } },
            categoryPalette = { { r = 201, g = 202, b = 203 } },
            baselineColor = { r = 210, g = 211, b = 212 },
        },
    })
    f.registerPlayer(1, 'K9-CID', 100)
    f.registerPlayer(2, 'SUSPECT-CID', 200)
    f.setPedCoords(1, 0, 0, 0)
    f.setPedCoords(2, 1, 0, 0) -- well within the 2.0m highlight range

    f.step()
    f.step()

    local result = f.getScentVisionPoints(1)
    t.isTrue(#result.points > 0, 'the trail reveal itself must be unaffected -- this test isolates the highlight half only')
    t.equals(#result.highlights, 0, 'a dog with no matching specialization must get NO highlight entry at all for a categorised-only item -- not an entry with an empty colour list, no entry')
end)

t.test('CONTRABAND HIGHLIGHT: a dog with narcotics but NOT explosives highlights drugs and NOT explosives', function()
    -- categoryPalette indices verified by directly computing this
    -- resource's own HashStringToIndex('narcotics', 5) = 2 and
    -- HashStringToIndex('explosives', 5) = 1 before writing this test (see
    -- server/tracking.lua's own HashStringToIndex) -- picked so the two
    -- categories resolve to two DIFFERENT, individually identifiable
    -- swatches below.
    local f = newScentVisionFixture({
        contraband = {
            rangeMeters = 2.0,
            k9Specializations = { narcotics = {}, explosives = {} },
            searchContrabandItems = { coke_brick = 'narcotics', c4 = 'explosives' },
            searchZones = { personSearchDistance = 2.0 },
            specializationGrants = { ['K9-CID'] = { narcotics = true } }, -- narcotics ONLY, not explosives
            inventoryItemsBySrc = { [2] = {
                { name = 'coke_brick', slot = 1, weight = 1.0 },
                { name = 'c4', slot = 2, weight = 1.0 },
            } },
            categoryPalette = {
                { r = 11, g = 11, b = 11 }, -- index 1 -- explosives' own colour
                { r = 22, g = 22, b = 22 }, -- index 2 -- narcotics' own colour
                { r = 33, g = 33, b = 33 },
                { r = 44, g = 44, b = 44 },
                { r = 55, g = 55, b = 55 },
            },
            baselineColor = { r = 99, g = 99, b = 99 },
        },
    })
    f.registerPlayer(1, 'K9-CID', 100)
    f.registerPlayer(2, 'SUSPECT-CID', 200)
    f.setPedCoords(1, 0, 0, 0)
    f.setPedCoords(2, 1, 0, 0)

    f.step()
    f.step()

    local result = f.getScentVisionPoints(1)
    t.equals(#result.highlights, 1, 'exactly one visible person is carrying matched contraband')
    local colors = result.highlights[1].colors
    t.equals(#colors, 1, 'only narcotics matched -- explosives must NOT appear, and there is no uncategorised item here either')
    t.equals(colors[1].r, 22, "the one colour present must be narcotics' own swatch (index 2)")
    t.equals(colors[1].g, 22, "the one colour present must be narcotics' own swatch (index 2)")
    t.equals(colors[1].b, 22, "the one colour present must be narcotics' own swatch (index 2)")
end)

t.test('CONTRABAND HIGHLIGHT: uncategorised contraband is highlighted for EVERY K9 with search access, regardless of specialization -- the same shared baseline search itself already grants', function()
    local f = newScentVisionFixture({
        contraband = {
            rangeMeters = 2.0,
            k9Specializations = { narcotics = {} },
            searchContrabandItems = { 'weed_bud' }, -- bare array entry -- UNCATEGORISED, matches this file's own real shipped Config.SearchContrabandItems shape
            searchZones = { personSearchDistance = 2.0 },
            specializationGrants = {}, -- holds NOTHING -- must not matter for the baseline
            inventoryItemsBySrc = { [2] = { { name = 'weed_bud', slot = 1, weight = 1.0 } } },
            categoryPalette = { { r = 201, g = 202, b = 203 } },
            baselineColor = { r = 210, g = 211, b = 212 },
        },
    })
    f.registerPlayer(1, 'K9-CID', 100)
    f.registerPlayer(2, 'SUSPECT-CID', 200)
    f.setPedCoords(1, 0, 0, 0)
    f.setPedCoords(2, 1, 0, 0)

    f.step()
    f.step()

    local result = f.getScentVisionPoints(1)
    t.equals(#result.highlights, 1, 'uncategorised contraband must highlight even with zero specializations held')
    local colors = result.highlights[1].colors
    t.equals(#colors, 1)
    t.equals(colors[1].r, 210, 'the baseline colour, never a categoryPalette entry, must be used for uncategorised contraband')
end)

t.test('CONTRABAND HIGHLIGHT: a target beyond the configured range is never included, even though their trail is still visible -- the range check uses server-read coordinates for BOTH peds', function()
    local f = newScentVisionFixture({
        contraband = {
            rangeMeters = 2.0, -- highlight range -- deliberately SHORT
            k9Specializations = { narcotics = {} },
            searchContrabandItems = { coke_brick = 'narcotics' },
            searchZones = { personSearchDistance = 5.0 }, -- higher ceiling, so 2.0 above is OUR configured value being enforced, not merely a clamp
            specializationGrants = { ['K9-CID'] = { narcotics = true } },
            inventoryItemsBySrc = { [2] = { { name = 'coke_brick', slot = 1, weight = 1.0 } } },
            categoryPalette = { { r = 201, g = 202, b = 203 } },
            baselineColor = { r = 210, g = 211, b = 212 },
        },
        -- queryRangeMeters (trail visibility) stays at this fixture's own
        -- 40.0 default -- comfortably wider than the 8m below, so the trail
        -- itself is still revealed; only the highlight's own much tighter
        -- 2.0m must exclude this target.
    })
    f.registerPlayer(1, 'K9-CID', 100)
    f.registerPlayer(2, 'SUSPECT-CID', 200)
    f.setPedCoords(1, 0, 0, 0)
    f.setPedCoords(2, 8, 0, 0) -- 8m -- inside queryRangeMeters (40), OUTSIDE contrabandHighlight.rangeMeters (2.0)

    f.step()
    f.step()

    local result = f.getScentVisionPoints(1)
    t.isTrue(#result.points > 0, 'the trail itself must still be revealed at 8m -- this test isolates the highlight range gate specifically')
    t.equals(#result.highlights, 0, 'a target outside contrabandHighlight.rangeMeters must never be highlighted, even though they match specialization and are carrying a matching item')
end)

t.test('CONTRABAND HIGHLIGHT: with ScentVision switched OFF (Config.Features.ScentVision = false), the server answers NOTHING at all -- no points, no highlights, even with a fully-matching setup', function()
    local f = newScentVisionFixture({
        contraband = {
            rangeMeters = 2.0,
            k9Specializations = { narcotics = {} },
            searchContrabandItems = { coke_brick = 'narcotics' },
            searchZones = { personSearchDistance = 2.0 },
            specializationGrants = { ['K9-CID'] = { narcotics = true } },
            inventoryItemsBySrc = { [2] = { { name = 'coke_brick', slot = 1, weight = 1.0 } } },
            categoryPalette = { { r = 201, g = 202, b = 203 } },
            baselineColor = { r = 210, g = 211, b = 212 },
        },
    })
    f.registerPlayer(1, 'K9-CID', 100)
    f.registerPlayer(2, 'SUSPECT-CID', 200)
    f.setPedCoords(1, 0, 0, 0)
    f.setPedCoords(2, 1, 0, 0)

    f.step()
    f.step()

    -- Control: prove this exact setup DOES produce a highlight while the
    -- feature is on, so the zero below is caused by the master switch, not
    -- a fixture quirk.
    local controlResult = f.getScentVisionPoints(1)
    t.equals(#controlResult.highlights, 1, 'control: this setup must produce a highlight while ScentVision is on')

    f.advance(2000) -- clear queryCooldownMs
    f.Config.Features.ScentVision = false
    local result = f.getScentVisionPoints(1)
    t.equals(#result.points, 0, 'master feature off must answer with zero points')
    t.equals(#result.highlights, 0, 'master feature off must answer with zero highlights too -- the off switch must not leak a "yes, they are carrying something" bit via a different field')
    t.equals(result.mode, 'off')
end)

t.test('CONTRABAND HIGHLIGHT: the payload never contains an item name, a count, or a weight, anywhere -- asserted on the payload\'s actual shape, not on intent', function()
    local f = newScentVisionFixture({
        contraband = {
            rangeMeters = 2.0,
            k9Specializations = { narcotics = {}, explosives = {} },
            searchContrabandItems = { 'weed_bud', coke_brick = 'narcotics', c4 = 'explosives' }, -- coke_brick/c4 CATEGORISED; weed_bud a bare array entry (UNCATEGORISED) -- both shapes in one table, exactly config.lua's own documented illustrative example
            searchZones = { personSearchDistance = 2.0 },
            specializationGrants = { ['K9-CID'] = { narcotics = true, explosives = true } },
            -- A distinctive item NAME, WEIGHT, and COUNT this test can prove
            -- never reaches the payload anywhere -- 91.0 and 17 chosen to
            -- not coincidentally collide with any coordinate/colour/age
            -- value this test itself configures below.
            inventoryItemsBySrc = { [2] = {
                { name = 'coke_brick', slot = 1, weight = 91.0, count = 17 },
                { name = 'c4', slot = 2, weight = 91.0, count = 17 },
                { name = 'weed_bud', slot = 3, weight = 91.0, count = 17 },
            } },
            categoryPalette = {
                { r = 201, g = 202, b = 203 },
                { r = 204, g = 205, b = 206 },
                { r = 207, g = 208, b = 209 },
                { r = 210, g = 211, b = 212 },
                { r = 213, g = 214, b = 215 },
            },
            baselineColor = { r = 220, g = 221, b = 222 },
        },
    })
    f.registerPlayer(1, 'K9-CID', 100)
    f.registerPlayer(2, 'SUSPECT-CID', 200)
    f.setPedCoords(1, 0, 0, 0)
    f.setPedCoords(2, 1, 0, 0)

    f.step()
    f.step()

    local result = f.getScentVisionPoints(1)
    t.isTrue(#result.highlights >= 1, 'this setup must actually produce a highlight -- otherwise the shape check below would trivially pass for the wrong reason')

    local forbiddenValues = { ['coke_brick'] = true, ['c4'] = true, ['weed_bud'] = true, [91.0] = true, [17] = true }
    assertPayloadShape(result, CONTRABAND_PAYLOAD_ALLOWED_KEYS, forbiddenValues, 'result')
end)

-- ========================================================================
-- ENTRY-COUNT CEILING (performance audit at 128 players, this pass --
-- coder-backend). Proves TrackableLog.<type> never grows past
-- Config.Tracking.<Type>.maxLoggedEntries no matter how many entries are
-- logged, and that eviction always takes the OLDEST entry first (never the
-- newest -- see server/tracking.lua's own AppendTrackableLogEntry doc
-- comment for why). Exercised entirely through the real, public
-- relayDamageEvent/relayWeaponFire/findTrackableSource surface -- TrackableLog
-- itself is file-local and deliberately not exposed to this suite, matching
-- this file's own "exposes NO resource-global functions" contract.
-- ========================================================================

t.test('ENTRY-COUNT CEILING: exceeding the cap evicts the two OLDEST entries, keeping the boundary entry and everything newer reachable', function()
    local f = newTrackingFixture({ maxLoggedEntries = { blood = 3 } })
    f.registerPlayer(1, 'K9-CID', 100) -- the searching K9

    -- Five distinct victims, each 100 units apart on the X axis -- far
    -- enough that only an entry ACTUALLY STILL PRESENT in the log (within
    -- maxRange=40.0 of the K9's own search position) can ever match.
    for i = 1, 5 do
        local victimSrc = 100 + i
        local ped = 200 + i
        f.registerPlayer(victimSrc, 'VICTIM-' .. i, ped)
        f.setPedCoords(ped, i * 100, 0, 0)
        f.relayDamageEvent(victimSrc) -- appends one TrackableLog.blood entry at (i*100, 0, 0)
    end
    -- Cap is 3, 5 entries were logged in order 1..5 -- entries 1 and 2 (the
    -- two OLDEST) must have been evicted; 3, 4, 5 (the three NEWEST) must
    -- remain, exactly matching AppendTrackableLogEntry's documented
    -- discard-on-write, oldest-first shape.

    local function searchFrom(x)
        f.setPedCoords(100, x, 0, 0) -- move the K9's OWN ped to stand exactly where victim i bled
        local result = f.findTrackableSource(1, 'blood')
        f.advance(6000) -- clear the K9's own per-(source, trackType) query cooldown (5000ms) before the next search
        return result.found
    end

    t.isFalse(searchFrom(1 * 100), 'entry 1 (the oldest) must have been evicted')
    t.isFalse(searchFrom(2 * 100), 'entry 2 must also have been evicted -- the cap of 3 only leaves room for 3, 4, 5')
    t.isTrue(searchFrom(3 * 100), 'entry 3 is the oldest SURVIVING entry -- exactly at the cap boundary -- and must still be found')
    t.isTrue(searchFrom(4 * 100), 'entry 4 must still be found')
    t.isTrue(searchFrom(5 * 100), 'entry 5 (the newest) must never be the one evicted to make room for an older entry')
end)

t.test('ENTRY-COUNT CEILING: the cap holds under MANY repeated writes -- only the newest N (cap) entries are ever findable, no matter how many total entries were logged', function()
    local CAP = 5
    local TOTAL_WRITES = 40
    local f = newTrackingFixture({ maxLoggedEntries = { gunpowder = CAP } })
    f.registerPlayer(1, 'K9-CID', 100) -- the searching K9

    for i = 1, TOTAL_WRITES do
        local shooterSrc = 1000 + i
        local ped = 2000 + i
        f.registerPlayer(shooterSrc, 'SHOOTER-' .. i, ped)
        f.setPedCoords(ped, i * 100, 0, 0)
        f.relayWeaponFire(shooterSrc) -- appends one TrackableLog.gunpowder entry at (i*100, 0, 0)
    end

    -- Only the LAST `CAP` entries (indices TOTAL_WRITES-CAP+1 .. TOTAL_WRITES,
    -- i.e. the 5 most recently logged out of 40 total) can still be found --
    -- every earlier one, no matter how much earlier, must have been evicted.
    --
    -- A FRESH searcher source per check (never the same K9 twice), rather
    -- than advancing the clock between checks: Gunpowder's own
    -- maxAgeSeconds (120s in this fixture) is short enough that advancing
    -- the clock 40 times in a row to dodge TrackQueryCooldown's
    -- per-(source, trackType) 5000ms gate would itself age every entry out
    -- by AGE well before reaching the end of the loop -- an unrelated
    -- expiry, not the CAP eviction this test exists to isolate. A fresh
    -- source has no query-cooldown history at all, so `now` never needs to
    -- move, and only maxLoggedEntries can be responsible for any `found`
    -- result below.
    for i = 1, TOTAL_WRITES do
        local searcherSrc = 5000 + i
        local searcherPed = 6000 + i
        f.registerPlayer(searcherSrc, 'SEARCHER-' .. i, searcherPed)
        f.setPedCoords(searcherPed, i * 100, 0, 0)
        local result = f.findTrackableSource(searcherSrc, 'gunpowder')
        local shouldSurvive = i > (TOTAL_WRITES - CAP)
        t.equals(result.found, shouldSurvive,
            ('entry %d of %d (cap %d) should %s survive'):format(i, TOTAL_WRITES, CAP, shouldSurvive and '' or 'NOT'))
    end
end)

t.test('ENTRY-COUNT CEILING: an invalid Config.Tracking.<Type>.maxLoggedEntries clamps to the built-in fallback and warns, rather than breaking the feature', function()
    local f = newTrackingFixture({ maxLoggedEntries = { blood = 'not-a-number' } })
    f.registerPlayer(1, 'K9-CID', 100)
    f.registerPlayer(2, 'VICTIM-CID', 200)
    f.setPedCoords(100, 0, 0, 0)
    f.setPedCoords(200, 0, 0, 0)
    f.relayDamageEvent(2)

    local warned = false
    for _, line in ipairs(f.printLog) do
        if line:find('Config.Tracking.Blood.maxLoggedEntries', 1, true) then warned = true end
    end
    t.isTrue(warned, 'an invalid maxLoggedEntries value must print a warning naming the exact key')

    local result = f.findTrackableSource(1, 'blood')
    t.isTrue(result.found, 'the feature must keep working off the built-in fallback -- an invalid cap must never collapse to something that evicts every entry on arrival')
end)

-- ========================================================================
-- UPPER CEILING on maxLoggedEntries (performance audit at 128 players, this
-- pass -- follow-up finding). See server/tracking.lua's own
-- MAX_LOGGED_ENTRIES_CEILING declaration comment for the full worked
-- arithmetic behind the 50000 figure. This field is hand-edit-only (not
-- tablet-reachable), so it was the one place a floor-only clamp still let
-- an operator reintroduce the exact unbounded-growth incident this whole
-- mechanism exists to close.
-- ========================================================================

t.test('UPPER CEILING: a maxLoggedEntries value above the built-in ceiling is clamped down and warns, naming the exact key and the ceiling substituted', function()
    local f = newTrackingFixture({ maxLoggedEntries = { blood = 999999 } })

    local warningLine
    for _, line in ipairs(f.printLog) do
        if line:find('Config.Tracking.Blood.maxLoggedEntries', 1, true) and line:find('exceeds', 1, true) then
            warningLine = line
        end
    end
    t.isNotNil(warningLine, 'a maxLoggedEntries value above the ceiling must print a warning naming the exact key')
    t.contains(warningLine, '999999', 'the warning must name the value that was actually found')
    t.contains(warningLine, '50000', 'the warning must name the ceiling value substituted')
end)

t.test('UPPER CEILING: exactly AT the ceiling (50000) is accepted unchanged, with no warning', function()
    local f = newTrackingFixture({ maxLoggedEntries = { gunpowder = 50000 } })

    for _, line in ipairs(f.printLog) do
        t.isNil(line:find('Config.Tracking.Gunpowder.maxLoggedEntries', 1, true) and line:find('exceeds', 1, true),
            'a value exactly at the ceiling must never trigger the "exceeds ceiling" warning')
    end
end)

t.test('UPPER CEILING: one ms over the ceiling (50001) still warns -- boundary is inclusive, not off-by-one', function()
    local f = newTrackingFixture({ maxLoggedEntries = { scent = 50001 } })

    local warned = false
    for _, line in ipairs(f.printLog) do
        if line:find('Config.Tracking.Scent.maxLoggedEntries', 1, true) and line:find('exceeds', 1, true) then
            warned = true
        end
    end
    t.isTrue(warned, '50001 (one over the ceiling) must still be clamped and warned about')
end)

t.test('UPPER CEILING: every real shipped config.lua default (6000/8000/6000) sits comfortably under the ceiling -- no warning ever fires for an untouched config', function()
    local f = newTrackingFixture() -- uses this fixture's own defaults, which mirror config.lua's shipped values

    for _, line in ipairs(f.printLog) do
        t.isFalse(line:find('maxLoggedEntries', 1, true) ~= nil and line:find('exceeds', 1, true) ~= nil,
            'the shipped defaults must never trip the new upper-ceiling warning: ' .. line)
    end
end)

-- ========================================================================
-- O(1) RING-BUFFER EVICTION (load audit, this pass -- coder-backend).
--
-- AppendTrackableLogEntry used to be `log[#log+1] = entry; while #log >
-- maxEntries do table.remove(log, 1) end`. That was already CORRECT --
-- the ENTRY-COUNT CEILING tests above prove exactly that shape evicts
-- oldest-first -- but O(n) PER WRITE once a log is saturated:
-- `table.remove(t, 1)` shifts every remaining element down by one slot. At
-- this resource's own documented worst case (128 players bleeding, Blood's
-- 500ms relay floor, Blood's own 8000-entry cap) that was roughly 2 million
-- slot copies per second purely from eviction. Converted to a real
-- circular buffer (head/tail indices, O(1) per write) following
-- server/diagnostics.lua's own DecisionTrail ring-index pattern -- see
-- AppendTrackableLogEntry's own doc comment in server/tracking.lua for the
-- full writeup.
--
-- IMPORTANT, why the tests above do NOT already prove this fix: "the cap
-- holds" and "eviction is oldest-first" both pass against the OLD O(n)
-- implementation too (it was slow, never incorrect) -- so neither one can
-- distinguish the fix from the bug it replaces, and neither one can catch
-- the NEW, DIFFERENT correctness risk this exact kind of conversion
-- invites: once eviction becomes "overwrite a physical slot in place"
-- instead of "shift the whole array down", physical slot layout stops
-- matching chronological (append) order the instant a log first wraps. A
-- reader that naively walks raw physical slots 1..count (instead of
-- computing where the CURRENT oldest entry actually lives, the way
-- TrackableRingLogEntriesOldestFirst does) would silently reorder what
-- every consumer sees. The two tests below are the additional, distinct
-- proof this needs:
--   1. a static proof the write path really is O(1) now (no `table.remove`
--      left anywhere in AppendTrackableLogEntry's own body) -- RED-proven
--      this pass by running it against server/tracking.lua with
--      AppendTrackableLogEntry temporarily reverted to the pre-fix
--      `table.remove`-based body (confirmed FAIL), then restored (confirmed
--      PASS again).
--   2. a behavioral proof that reads still come back in true chronological
--      (oldest-first) order after a wrap, via a tie-break outcome that only
--      a genuinely order-correct reader gets right -- RED-proven this pass
--      by temporarily hobbling TrackableRingLogEntriesOldestFirst to always
--      start its walk at physical slot 1 regardless of wrap state (exactly
--      the naive-conversion bug this test exists to catch), confirming it
--      FAILED (returned the newer entry's coords instead of the older
--      one's), then restoring the real head-tracking implementation and
--      confirming it PASSED again.
-- ========================================================================

t.test('PERFORMANCE: AppendTrackableLogEntry no longer contains an O(n)-per-write table.remove loop', function()
    local handle = assert(io.open('../server/tracking.lua', 'r'))
    local source = handle:read('a')
    handle:close()

    local startPos = source:find('\nlocal function AppendTrackableLogEntry(', 1, true)
    assert(startPos, 'AppendTrackableLogEntry not found in server/tracking.lua -- this test needs updating alongside whatever renamed it')
    local endPos = source:find('\nend', startPos, true)
    assert(endPos, 'could not find the end of AppendTrackableLogEntry in server/tracking.lua')
    local body = source:sub(startPos, endPos)

    t.isFalse(body:find('table.remove', 1, true) ~= nil,
        'AppendTrackableLogEntry must never call table.remove -- that is exactly the O(n)-per-write shape this pass closed (see this section\'s own header for the full writeup)')
end)

t.test('RING BUFFER ORDER: a reader must still see entries OLDEST FIRST after a wrap -- proven via a tie-break outcome only a chronologically-correct reader gets right', function()
    local f = newTrackingFixture({ maxLoggedEntries = { blood = 2 } })
    f.registerPlayer(1, 'K9-CID', 100) -- the searching K9, standing at the origin
    f.setPedCoords(100, 0, 0, 0)

    -- Fill the cap-2 ring, then force exactly one wrap: FILLER (evicted),
    -- then A, then B -- so by the time B is written, physical slot 1 (the
    -- one FILLER originally occupied) now holds B, and physical slot 2
    -- still holds A. A reader that walked raw physical order (1, then 2)
    -- would visit B before A -- the OPPOSITE of reality, since A was
    -- logged strictly before B.
    f.registerPlayer(101, 'FILLER-CID', 201)
    f.setPedCoords(201, 9999, 9999, 0) -- far outside maxRange -- only here to occupy, then vacate, physical slot 1
    f.relayDamageEvent(101)

    f.registerPlayer(102, 'A-CID', 202)
    f.setPedCoords(202, 20, 0, 0) -- distance 20 from the K9 at the origin
    f.relayDamageEvent(102) -- A -- the OLDER of the two entries that survive the wrap

    f.registerPlayer(103, 'B-CID', 203)
    f.setPedCoords(203, -20, 0, 0) -- distance 20 from the K9 at the origin -- an EXACT tie with A, opposite side
    f.relayDamageEvent(103) -- B -- this write evicts FILLER; B is the NEWER of the two survivors

    -- A and B are an exact distance tie (20 each). FindNearestFreshTrackableEntry's
    -- own tie-break is `dist < nearestDist` (strict) -- the FIRST entry
    -- encountered in the walk keeps its claim over an equal-distance later
    -- one. Read in true chronological order (A, then B), A wins. Read by
    -- raw physical slot instead (B, then A, post-wrap), B would win
    -- instead -- this is the one observable signal available through the
    -- real event/callback surface for "which order did the reader actually
    -- walk in".
    local result = f.findTrackableSource(1, 'blood')
    t.isTrue(result.found)
    t.equals(result.coords.x, 20,
        'the tie must be won by A (x=20), the OLDER of the two surviving entries -- a reader walking raw physical slot order instead of true chronological order would incorrectly return B (x=-20) here')
end)

t.test('RING BUFFER ORDER: the SAME tie-break outcome still holds after MULTIPLE wraps, not just the first one', function()
    local f = newTrackingFixture({ maxLoggedEntries = { blood = 2 } })
    f.registerPlayer(1, 'K9-CID', 100)
    f.setPedCoords(100, 0, 0, 0)

    -- FIVE (deliberately ODD -- see below) irrelevant fillers, each far
    -- outside maxRange, so any leftover physical-slot aliasing from an
    -- earlier wrap has every opportunity to surface. ODD matters: with an
    -- EVEN filler count, A and B would land back on the SAME physical
    -- slots (1, 2) they'd occupy with zero fillers at all -- coincidentally
    -- matching chronological order again even under a naive
    -- always-start-at-slot-1 reader, and silently failing to exercise
    -- anything the single-wrap test above does not already cover. An ODD
    -- count instead lands A and B on slots (2, 1) -- physically REVERSED
    -- from chronological order, exactly like the single-wrap test, but only
    -- reachable here after several additional wraps.
    for i = 1, 5 do
        local src, ped = 200 + i, 300 + i
        f.registerPlayer(src, 'FILLER-' .. i, ped)
        f.setPedCoords(ped, 9999, 9999, 0)
        f.relayDamageEvent(src)
    end

    f.registerPlayer(102, 'A-CID', 202)
    f.setPedCoords(202, 20, 0, 0)
    f.relayDamageEvent(102) -- A -- older survivor

    f.registerPlayer(103, 'B-CID', 203)
    f.setPedCoords(203, -20, 0, 0)
    f.relayDamageEvent(103) -- B -- newer survivor, this write evicts the last filler

    local result = f.findTrackableSource(1, 'blood')
    t.isTrue(result.found)
    t.equals(result.coords.x, 20, 'after several full wraps, the tie must still be won by A (x=20), the older survivor')
end)

-- ========================================================================
-- SPECIALIZATION-SCOPED TRACKING (owner-directed decluttering pass,
-- 2026-08-26 -- "merge all the scent tracking stuff into one thing... when
-- certed for extra stuff it just does it"). Pins:
--   1. 'scent' can NEVER be specialization-gated (coordinator correction:
--      it is the base capability every K9-access handler has, not a
--      narcotics-detection mechanic -- gating it would silently break
--      search-and-rescue/scent-trail-hunt narratively, even though this
--      pass confirmed by direct code reading that those two features do
--      not actually share this file's TrackableLog.scent at all).
--   2. blood/gunpowder require patrol/explosives respectively -- a REAL,
--      INTENTIONAL regression from "every certified dog can already track
--      blood/gunpowder" (see config.lua's own Config.SpecializationTracking
--      comment for the full plain-English writeup).
--   3. MONOTONIC: granting a specialization only ever ADDS a track type,
--      never removes one that was already enabled -- there is deliberately
--      NO "citizenid holds zero specializations -> enable everything"
--      fallback (an EARLIER, REJECTED design -- see config.lua's own
--      header for the "make it more fluid" writeup this supersedes).
--   4. Config.SpecializationTracking is CLAMPED AND WARNED, never asserted,
--      against a bad entry.
--   5. Both findTrackableSource (single-type) AND the NEW merged
--      findNearestTrackableSource enforce this SERVER-side -- a caller
--      asking for a type it is not entitled to gets found = false, never
--      trusted.
-- Scent capture (the ox_inventory swapItems hook) is NOT wired into this
-- fixture at all (see newTrackingOverrideChainFixture's own header and
-- this file's own established "onResourceStart is never fired... zero
-- prior references to K9Compat" convention) -- a real TrackableLog.scent
-- entry cannot be seeded here. "Scent is never gated" is therefore proven
-- via `hasSpecializationCalls` below (ResolveEnabledTrackTypesForCitizenId
-- structurally never even ASKS HasSpecialization about 'scent' -- there is
-- no key in Config.SpecializationTracking it could ever be validated
-- under, per that config's own header) rather than via a found=true/false
-- comparison scent's own capture path can't produce in this suite.
-- ========================================================================

t.test("SCENT IS STRUCTURALLY UNGATED: HasSpecialization is never even asked about 'scent', for either callback, regardless of what specializations are held", function()
    local f = newTrackingFixture({ hasSpecializationDefault = false })
    f.registerPlayer(1, 'K9-CID', 100)
    f.setPedCoords(100, 0, 0, 0)

    f.findTrackableSource(1, 'scent')
    f.findNearestTrackableSource(1)

    for _, call in ipairs(f.hasSpecializationCalls) do
        t.isFalse(call.specKey == 'scent', "HasSpecialization must never be consulted for 'scent' -- it has no entry in Config.SpecializationTracking and can never be gated by one")
    end
end)

t.test('THE REAL REGRESSION, MADE EXPLICIT: a citizenid with NO specializations at all cannot Track Blood or Track Gunpowder, even with a real, in-range, fresh logged source', function()
    local f = newTrackingFixture({ hasSpecializationDefault = false })
    f.registerPlayer(1, 'K9-CID', 100)
    f.setPedCoords(100, 0, 0, 0)
    f.registerPlayer(2, 'VICTIM-CID', 200)
    f.setPedCoords(200, 0, 0, 0)
    f.relayDamageEvent(2)
    f.registerPlayer(3, 'SHOOTER-CID', 300)
    f.setPedCoords(300, 0, 0, 0)
    f.relayWeaponFire(3)

    t.isFalse(f.findTrackableSource(1, 'blood').found, 'no patrol specialization -> blood must not be findable, even though a real source is logged and in range')
    t.isFalse(f.findTrackableSource(1, 'gunpowder').found, 'no explosives specialization -> gunpowder must not be findable, even though a real source is logged and in range')
end)

t.test('MONOTONICITY: granting explosives strictly ADDS gunpowder to the enabled set -- blood stays exactly as it was (unaffected), nothing is ever taken away', function()
    local f = newTrackingFixture({ hasSpecializationDefault = false })
    f.registerPlayer(1, 'K9-CID', 100)
    f.setPedCoords(100, 0, 0, 0)
    f.registerPlayer(2, 'VICTIM-CID', 200)
    f.setPedCoords(200, 0, 0, 0)
    f.relayDamageEvent(2)
    f.registerPlayer(3, 'SHOOTER-CID', 300)
    f.setPedCoords(300, 0, 0, 0)
    f.relayWeaponFire(3)

    -- BEFORE: the pre-grant set.
    t.isFalse(f.findTrackableSource(1, 'blood').found, 'PRE-GRANT: blood not yet enabled')
    t.isFalse(f.findTrackableSource(1, 'gunpowder').found, 'PRE-GRANT: gunpowder not yet enabled')

    f.advance(6000) -- clear both per-type query cooldowns just consumed above before re-querying
    f.setHasSpecialization('K9-CID', 'explosives', true)

    -- AFTER: strictly a SUPERSET of the pre-grant set -- gunpowder added,
    -- blood UNCHANGED (still false -- explosives must never also grant
    -- blood, only what it actually maps to).
    t.isFalse(f.findTrackableSource(1, 'blood').found, 'POST-GRANT: granting explosives must never also grant blood')
    t.isTrue(f.findTrackableSource(1, 'gunpowder').found, 'POST-GRANT: granting explosives must add gunpowder -- this is the ADD half of monotonicity')
end)

t.test('MONOTONICITY: granting patrol strictly ADDS blood to the enabled set -- gunpowder stays exactly as it was (unaffected), nothing is ever taken away', function()
    local f = newTrackingFixture({ hasSpecializationDefault = false })
    f.registerPlayer(1, 'K9-CID', 100)
    f.setPedCoords(100, 0, 0, 0)
    f.registerPlayer(2, 'VICTIM-CID', 200)
    f.setPedCoords(200, 0, 0, 0)
    f.relayDamageEvent(2)
    f.registerPlayer(3, 'SHOOTER-CID', 300)
    f.setPedCoords(300, 0, 0, 0)
    f.relayWeaponFire(3)

    t.isFalse(f.findTrackableSource(1, 'blood').found, 'PRE-GRANT: blood not yet enabled')
    t.isFalse(f.findTrackableSource(1, 'gunpowder').found, 'PRE-GRANT: gunpowder not yet enabled')

    f.advance(6000)
    f.setHasSpecialization('K9-CID', 'patrol', true)

    t.isTrue(f.findTrackableSource(1, 'blood').found, 'POST-GRANT: granting patrol must add blood -- this is the ADD half of monotonicity')
    t.isFalse(f.findTrackableSource(1, 'gunpowder').found, 'POST-GRANT: granting patrol must never also grant gunpowder')
end)

t.test('narcotics has NO track-type mapping at all -- a narcotics-only citizenid is exactly as (un)able to Track Blood/Gunpowder as a citizenid with zero specializations', function()
    local f = newTrackingFixture({ hasSpecializationDefault = false })
    f.registerPlayer(1, 'K9-CID', 100)
    f.setPedCoords(100, 0, 0, 0)
    f.registerPlayer(2, 'VICTIM-CID', 200)
    f.setPedCoords(200, 0, 0, 0)
    f.relayDamageEvent(2)
    f.registerPlayer(3, 'SHOOTER-CID', 300)
    f.setPedCoords(300, 0, 0, 0)
    f.relayWeaponFire(3)

    f.setHasSpecialization('K9-CID', 'narcotics', true)

    t.isFalse(f.findTrackableSource(1, 'blood').found, 'narcotics grants no track type -- blood must stay locked')
    t.isFalse(f.findTrackableSource(1, 'gunpowder').found, 'narcotics grants no track type -- gunpowder must stay locked')
end)

t.test('CLAMP AND WARN: a Config.SpecializationTracking entry naming a specialization key not in Config.K9Specializations is dropped, warns, and grants nothing to anyone', function()
    local f = newTrackingFixture({
        hasSpecializationDefault = true, -- even with EVERY specialization "held", a bogus config key must grant nothing
        specializationTracking = { not_a_real_specialization = { 'blood' } },
    })
    f.registerPlayer(1, 'K9-CID', 100)
    f.setPedCoords(100, 0, 0, 0)
    f.registerPlayer(2, 'VICTIM-CID', 200)
    f.setPedCoords(200, 0, 0, 0)
    f.relayDamageEvent(2)

    t.isFalse(f.findTrackableSource(1, 'blood').found, 'a bogus Config.SpecializationTracking key must never grant a track type, even to a citizenid holding every real specialization')

    local warned = false
    for _, line in ipairs(f.printLog) do
        if line:find('not_a_real_specialization', 1, true) and line:find('Config.K9Specializations', 1, true) then warned = true end
    end
    t.isTrue(warned, 'the bad entry must print a console warning naming the exact bad key')
end)

t.test("CLAMP AND WARN: a Config.SpecializationTracking entry listing 'scent' is dropped for that entry, warns, and does not otherwise break the rest of that specialization's real track types", function()
    local f = newTrackingFixture({
        hasSpecializationDefault = false,
        specializationTracking = { patrol = { 'scent', 'blood' } },
    })
    f.registerPlayer(1, 'K9-CID', 100)
    f.setPedCoords(100, 0, 0, 0)
    f.registerPlayer(2, 'VICTIM-CID', 200)
    f.setPedCoords(200, 0, 0, 0)
    f.relayDamageEvent(2)

    f.setHasSpecialization('K9-CID', 'patrol', true)
    -- 'blood' (the OTHER, valid entry in the same list) must still work --
    -- one bad list ELEMENT degrades only itself, not its whole entry.
    t.isTrue(f.findTrackableSource(1, 'blood').found, "a 'scent' entry alongside a valid one must not also break the valid one")

    local warned = false
    for _, line in ipairs(f.printLog) do
        if line:find("'scent'", 1, true) and line:find('patrol', 1, true) then warned = true end
    end
    t.isTrue(warned, "listing 'scent' under a specialization must print a console warning naming it")
end)

t.test('an EMPTY Config.SpecializationTracking (owner deletes both entries) leaves blood/gunpowder unreachable for EVERYONE -- there is no generalist fallback in the corrected design', function()
    local f = newTrackingFixture({ hasSpecializationDefault = true, specializationTracking = {} })
    f.registerPlayer(1, 'K9-CID', 100)
    f.setPedCoords(100, 0, 0, 0)
    f.registerPlayer(2, 'VICTIM-CID', 200)
    f.setPedCoords(200, 0, 0, 0)
    f.relayDamageEvent(2)
    f.registerPlayer(3, 'SHOOTER-CID', 300)
    f.setPedCoords(300, 0, 0, 0)
    f.relayWeaponFire(3)

    -- hasSpecializationDefault = true means EVERY specialization is
    -- "held" -- and it still doesn't matter, because nothing in
    -- Config.SpecializationTracking maps ANY specialization to blood or
    -- gunpowder anymore. This is the loud, documented, intentional
    -- consequence server/diagnostics.lua's own boot warning exists for.
    t.isFalse(f.findTrackableSource(1, 'blood').found)
    t.isFalse(f.findTrackableSource(1, 'gunpowder').found)
end)

-- ------------------------------------------------------------------------
-- THE MERGED ACTION: findNearestTrackableSource
-- ------------------------------------------------------------------------

t.test('findNearestTrackableSource: resolves the NEAREST match across every type this citizenid is entitled to, and reports WHICH type matched', function()
    local f = newTrackingFixture({ hasSpecializationDefault = false })
    f.registerPlayer(1, 'K9-CID', 100)
    f.setPedCoords(100, 0, 0, 0)
    f.setHasSpecialization('K9-CID', 'patrol', true)
    f.setHasSpecialization('K9-CID', 'explosives', true)

    -- A gunpowder source at 20m, a blood source at 10m -- both types are
    -- enabled (patrol + explosives both held) -- blood, the CLOSER one,
    -- must win.
    f.registerPlayer(2, 'SHOOTER-CID', 200)
    f.setPedCoords(200, 20, 0, 0)
    f.relayWeaponFire(2)
    f.registerPlayer(3, 'VICTIM-CID', 300)
    f.setPedCoords(300, 10, 0, 0)
    f.relayDamageEvent(3)

    local result = f.findNearestTrackableSource(1)
    t.isTrue(result.found)
    t.equals(result.trackType, 'blood', 'the nearer of the two enabled types must win')
end)

t.test('findNearestTrackableSource: a type this citizenid is NOT entitled to is excluded entirely, even when it is the objectively nearest source', function()
    local f = newTrackingFixture({ hasSpecializationDefault = false })
    f.registerPlayer(1, 'K9-CID', 100)
    f.setPedCoords(100, 0, 0, 0)
    -- Only patrol held -- gunpowder is NOT enabled at all.
    f.setHasSpecialization('K9-CID', 'patrol', true)

    -- Gunpowder at 5m (nearer), blood at 30m (farther) -- gunpowder must be
    -- ignored entirely (not entitled), so blood -- the only ELIGIBLE
    -- source -- wins despite being farther away.
    f.registerPlayer(2, 'SHOOTER-CID', 200)
    f.setPedCoords(200, 5, 0, 0)
    f.relayWeaponFire(2)
    f.registerPlayer(3, 'VICTIM-CID', 300)
    f.setPedCoords(300, 30, 0, 0)
    f.relayDamageEvent(3)

    local result = f.findNearestTrackableSource(1)
    t.isTrue(result.found)
    t.equals(result.trackType, 'blood', 'gunpowder must be excluded entirely, not merely deprioritized -- the nearer gunpowder source must never win')
end)

t.test('findNearestTrackableSource: zero enabled/permitted candidate types -> found = false, no cooldown consumed, no lookup performed', function()
    local f = newTrackingFixture({ hasSpecializationDefault = false, specializationTracking = {} })
    f.registerPlayer(1, 'K9-CID', 100)
    f.setPedCoords(100, 0, 0, 0)
    f.Config.Features.ScentTracking = false -- now NOTHING is even a candidate: scent's own feature flag is off, and blood/gunpowder have no mapping at all in this fixture's specializationTracking = {}

    local result = f.findNearestTrackableSource(1)
    t.isFalse(result.found)
end)

t.test('ONE COOLDOWN, SIZED TO THE SLOWEST CANDIDATE: the merged action is throttled at the MAXIMUM searchCooldownMs among its candidate types, not the fastest, and independently of the three per-type keys', function()
    local f = newTrackingFixture({
        hasSpecializationDefault = false,
        searchCooldownMs = { scent = 2000, blood = 9000, gunpowder = 2000 },
    })
    f.registerPlayer(1, 'K9-CID', 100)
    f.setPedCoords(100, 0, 0, 0)
    f.setHasSpecialization('K9-CID', 'patrol', true) -- candidates: scent (2000ms) + blood (9000ms) -- slowest is blood's 9000ms

    f.registerPlayer(2, 'VICTIM-CID', 200)
    f.setPedCoords(200, 5, 0, 0)
    f.relayDamageEvent(2)

    local first = f.findNearestTrackableSource(1)
    t.isTrue(first.found, 'first call must succeed and consume the merged cooldown')

    -- 5000ms later -- past scent's own 2000ms, but NOT past blood's 9000ms
    -- (the slowest candidate). If the merged cooldown had wrongly used the
    -- FASTEST candidate (2000ms) instead of the slowest, this second call
    -- would incorrectly succeed here -- exactly the "three times cheaper to
    -- spam" trap this design was told to avoid.
    f.advance(5000)
    local second = f.findNearestTrackableSource(1)
    t.isFalse(second.found, 'still within the SLOWEST candidate type\'s own cooldown window -- must still be refused')

    -- Past even the slowest candidate's 9000ms now -- must succeed again.
    f.advance(4001)
    local third = f.findNearestTrackableSource(1)
    t.isTrue(third.found, 'once the slowest candidate\'s own cooldown has fully elapsed, the merged action must work again')
end)

t.test('ONE COOLDOWN, INDEPENDENT KEY: the merged action never touches, and is never blocked by, the three per-type findTrackableSource cooldown keys', function()
    local f = newTrackingFixture({ hasSpecializationDefault = false })
    f.registerPlayer(1, 'K9-CID', 100)
    f.setPedCoords(100, 0, 0, 0)
    f.setHasSpecialization('K9-CID', 'patrol', true)
    f.setHasSpecialization('K9-CID', 'explosives', true)

    f.registerPlayer(2, 'VICTIM-CID', 200)
    f.setPedCoords(200, 5, 0, 0)
    f.relayDamageEvent(2)

    -- Burn the OLD single-type 'blood' cooldown key via the orphaned
    -- findTrackableSource path first.
    t.isTrue(f.findTrackableSource(1, 'blood').found)

    -- The merged action must NOT be refused by that unrelated key -- it
    -- has never touched it, and vice versa.
    local merged = f.findNearestTrackableSource(1)
    t.isTrue(merged.found, 'the merged action must never be blocked by the OLD single-type cooldown key')
end)

-- ------------------------------------------------------------------------
-- SERVER-SIDE AUTHORITY: the client never decides which type applies.
-- ------------------------------------------------------------------------

t.test('SERVER-SIDE AUTHORITY: a client directly requesting a type it is not specialization-entitled to (via the OLDER single-type callback) is answered found = false, never trusted', function()
    local f = newTrackingFixture({ hasSpecializationDefault = false })
    f.registerPlayer(1, 'K9-CID', 100)
    f.setPedCoords(100, 0, 0, 0)
    f.registerPlayer(2, 'SHOOTER-CID', 200)
    f.setPedCoords(200, 0, 0, 0)
    f.relayWeaponFire(2)

    -- A modified client (or the orphaned StartGunpowderTrack() global)
    -- asking DIRECTLY for 'gunpowder' with no explosives specialization
    -- held must be refused, exactly as if it had gone through the merged
    -- action -- the OLDER callback is not a bypass.
    local result = f.findTrackableSource(1, 'gunpowder')
    t.isFalse(result.found, "a direct request for an un-entitled type must never be honored, regardless of which callback the client calls")
end)

os.exit(t.summary())
