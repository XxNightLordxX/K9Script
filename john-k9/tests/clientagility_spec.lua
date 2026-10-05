--[[
    tests/clientagility_spec.lua

    Direct, black-box tests of client/agility.lua against the REAL,
    unmodified production file: the Config.Combat.AgilityAdvanced.detectionMethod
    startup assert, the CanShowK9UI()/vehicle/cooldown/obstacle-height gates on
    TryVault(), the multi-band capsule-sweep algorithm (DetectVaultableObstacleHeight,
    reached only indirectly through TryVault -- it is a `local`), the
    SHAPE_TEST_MAX_POLLS timeout safety cap, and one real, provable bug this
    pass found and fixed IN client/agility.lua itself (this spec file's author
    owns that file per this task's assignment): TryVault() had no re-entrancy
    guard around its own async, multi-frame obstacle-detection sweep, letting
    two overlapping invocations both launch the K9. See the "RE-ENTRANCY BUG"
    section below for the full writeup, repro, and fix description.

    STYLE: follows tests/clientvision_spec.lua and tests/clientradial_spec.lua
    exactly -- fresh sandbox per test, drive the real captured RegisterCommand
    handler (never a reimplementation of TryVault, which is a `local` reached
    only that way), the same vec3-with-metatables helper reused verbatim from
    clientradial_spec.lua/combat_spec.lua/certifications_spec.lua/tenure_spec.lua.

    THREAD/COROUTINE SIMULATION -- WHY THIS FILE DOES NOT USE
    Sandbox.newThreadRunner(): client/agility.lua's TryVault() never calls
    CreateThread at all -- FiveM's own RegisterCommand handlers are already
    invoked inside their own coroutine context (this is how a keybind-bound
    command handler can call Wait() at all, which DetectVaultableObstacleHeight's
    own GET_SHAPE_TEST_RESULT poll loop does whenever a shape test reports
    "still processing"). Sandbox.newThreadRunner() is purpose-built for
    stepping CreateThread-created coroutines one pass at a time and does not
    fit this shape (there is no CreateThread call to wrap here at all, and the
    RE-ENTRANCY BUG section below needs to interleave TWO independent
    coroutines by hand, which that helper's step()-resumes-everything model
    cannot express). This file instead wraps the captured command handler in
    its own plain `coroutine.create`/`coroutine.resume` pair directly --
    exactly the same underlying mechanism newThreadRunner uses internally,
    just driven by hand for the fine-grained interleaving control this one
    scenario needs. `runVault()` below (used by every OTHER test in this
    file) is the same idea reduced to "run one coroutine to completion,
    regardless of how many times it yields," which covers every non-interleaving
    test uniformly whether or not that particular call's own shape-test
    resolver ever actually yields.

    STUBBING EFFORT, reported honestly per this task's own instruction: every
    native this file touches is either a simple capturing/controllable stub
    (CanShowK9UI, DenyK9UIAccess, PlayerPedId, IsPedInAnyVehicle, IsInK9Vehicle,
    GetEntityCoords, GetEntityForwardVector, GetEntitySpeed, SetEntityVelocity,
    GetGameTimer, RegisterCommand, RegisterKeyMapping) or a small,
    deliberately-designed per-handle sequencer (StartShapeTestCapsule/
    GetShapeTestResult -- the one pair genuinely worth custom-building, since
    DetectVaultableObstacleHeight's own poll-until-resolved contract needs a
    controllable "still processing N times, then resolved" sequence per
    shape-test call, not just a single canned return). Nothing here needed
    disproportionate stubbing.

    GetEntitySpeed (fluidity pass, coder-frontend): added alongside the
    momentum-carry-through fix in client/agility.lua itself (see that file's
    TryVault() "FIXED THIS PASS" comment) -- defaults to 0 (a stationary test
    ped), which keeps every pre-existing SetEntityVelocity assertion in this
    file byte-for-byte unchanged (math.max(3.5, 0) == 3.5, the same flat
    constant every existing test already expects) without silently softening
    what any of them check. `setEntitySpeed(v)` below lets a test opt into a
    faster-than-3.5 reading to actually exercise the new "never slower than
    the K9 was already moving" behavior -- see the dedicated test for it
    further down.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')
local locale = Sandbox.locale

-- ----------------------------------------------------------------------
-- Vector3-alike stub -- identical shape to clientradial_spec.lua/
-- combat_spec.lua/certifications_spec.lua/tenure_spec.lua's own copies.
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

-- ----------------------------------------------------------------------
-- Sandbox setup
-- ----------------------------------------------------------------------

--- Builds one fresh, independent sandbox: the real config.lua (with optional
--- per-test overrides to Config.Combat.AgilityAdvanced applied AFTER load,
--- since agilityCfg.detectionMethod/maxVaultHeight/vaultCooldownMs are all
--- read live via field access at TryVault()-call time, never captured by
--- value -- only detectionMethod is checked at FILE-LOAD time, via the
--- startup assert) + the real client/agility.lua.
--- @param opts { detectionMethod: string?, maxVaultHeight: number?, vaultCooldownMs: number?,
---               agilityAdvanced: boolean?, expectLoadError: boolean?,
---               isInK9VehicleDefined: boolean?, canShowK9UI: boolean? }?
--- @return table fixture
local function newAgilityFixture(opts)
    opts = opts or {}

    local canShowK9UI = opts.canShowK9UI
    if canShowK9UI == nil then canShowK9UI = true end
    local canShowK9UICalls = 0
    local function CanShowK9UI() canShowK9UICalls = canShowK9UICalls + 1; return canShowK9UI end
    local denyCalls = 0
    local function DenyK9UIAccess() denyCalls = denyCalls + 1 end

    local fakeNow = 0
    local function GetGameTimer() return fakeNow end

    local pedHandle = 1
    local function PlayerPedId() return pedHandle end

    local isPedInAnyVehicle = false
    local isPedInAnyVehicleCalls = {}
    local function IsPedInAnyVehicle(ped, bool) isPedInAnyVehicleCalls[#isPedInAnyVehicleCalls + 1] = { ped = ped, bool = bool }; return isPedInAnyVehicle end

    local isInK9Vehicle = false
    local function IsInK9Vehicle() return isInK9Vehicle end

    -- PER-PERSON BLOCK (client/featureblocks.lua, REQUESTED) -- stubbed,
    -- same "controllable stand-in" convention as CanShowK9UI/DenyK9UIAccess
    -- above. Soft dependency: only added to `env` when
    -- `opts.featureBlocksAvailable` is not explicitly false.
    local featureBlocksAvailable = opts.featureBlocksAvailable
    if featureBlocksAvailable == nil then featureBlocksAvailable = true end
    local blockedFeatures = opts.blockedFeatures or {}
    local function IsK9FeatureBlocked(name) return blockedFeatures[name] == true end
    local denyK9FeatureBlockedCallCount = 0
    local function DenyK9FeatureBlocked() denyK9FeatureBlockedCallCount = denyK9FeatureBlockedCallCount + 1 end

    local pedCoords = { [1] = vec3(0, 0, 0) }
    local function GetEntityCoords(entity) return pedCoords[entity] or vec3(0, 0, 0) end
    local forwardVector = vec3(1, 0, 0)
    local function GetEntityForwardVector(_entity) return forwardVector end

    -- GetEntitySpeed (fluidity pass) -- see this file's header note on why
    -- this defaults to 0 (never overrides the flat 3.5 forwardSpeed floor
    -- unless a test explicitly opts in via setEntitySpeed below).
    local entitySpeed = 0
    local function GetEntitySpeed(_entity) return entitySpeed end

    -- StartShapeTestCapsule/GetShapeTestResult -- see this file's header.
    -- Every StartShapeTestCapsule call (across the WHOLE fixture's lifetime,
    -- not just one TryVault() call) gets the NEXT sequential handle number,
    -- so a test can address "the very first shape-test call this fixture
    -- ever made" deterministically regardless of how many TryVault()
    -- invocations came before it. `shapeTestResolver(handle, pollNumber)`
    -- decides what GetShapeTestResult returns on the Nth call for a given
    -- handle -- default: resolved with no hit on the very first poll, i.e.
    -- never yields at all (the common, expected case per this file's own
    -- comment: "typically resolves within the same or next frame").
    local shapeTestCalls = {}
    local shapeTestPollCounts = {}
    local nextShapeTestHandle = 0
    local shapeTestResolver = function(_handle, _pollNumber) return 2, false end
    local function StartShapeTestCapsule(startX, startY, startZ, endX, endY, endZ, radius, flags, ped, p10)
        nextShapeTestHandle = nextShapeTestHandle + 1
        local handle = nextShapeTestHandle
        shapeTestCalls[#shapeTestCalls + 1] = {
            handle = handle, startX = startX, startY = startY, startZ = startZ,
            endX = endX, endY = endY, endZ = endZ, radius = radius, flags = flags,
            ped = ped, p10 = p10,
        }
        shapeTestPollCounts[handle] = 0
        return handle
    end
    local function GetShapeTestResult(handle)
        shapeTestPollCounts[handle] = shapeTestPollCounts[handle] + 1
        return shapeTestResolver(handle, shapeTestPollCounts[handle])
    end

    local waitCalls = {}
    local function Wait(ms) waitCalls[#waitCalls + 1] = ms; coroutine.yield() end

    local setEntityVelocityCalls = {}
    local function SetEntityVelocity(entity, x, y, z) setEntityVelocityCalls[#setEntityVelocityCalls + 1] = { entity = entity, x = x, y = y, z = z } end

    local registerCommandCalls = {}
    local function RegisterCommand(name, handler, restricted)
        registerCommandCalls[#registerCommandCalls + 1] = { name = name, handler = handler, restricted = restricted }
    end
    local registerKeyMappingCalls = {}
    local function RegisterKeyMapping(commandName, description, ioType, defaultKey)
        registerKeyMappingCalls[#registerKeyMappingCalls + 1] = { commandName = commandName, description = description, ioType = ioType, defaultKey = defaultKey }
    end

    -- CLAMP-AND-WARN CAPTURE -- proves the guard actually warns (not just
    -- "doesn't crash") without spamming real stdout during the test run.
    local printLog = {}
    local function printStub(...)
        local parts = {}
        for i = 1, select('#', ...) do parts[i] = tostring(select(i, ...)) end
        printLog[#printLog + 1] = table.concat(parts, '\t')
    end

    local overrides = {
        print = printStub,
        CanShowK9UI = CanShowK9UI,
        DenyK9UIAccess = DenyK9UIAccess,
        GetGameTimer = GetGameTimer,
        PlayerPedId = PlayerPedId,
        IsPedInAnyVehicle = IsPedInAnyVehicle,
        GetEntityCoords = GetEntityCoords,
        GetEntityForwardVector = GetEntityForwardVector,
        GetEntitySpeed = GetEntitySpeed,
        StartShapeTestCapsule = StartShapeTestCapsule,
        GetShapeTestResult = GetShapeTestResult,
        Wait = Wait,
        SetEntityVelocity = SetEntityVelocity,
        RegisterCommand = RegisterCommand,
        RegisterKeyMapping = RegisterKeyMapping,
    }
    -- IsInK9Vehicle is this file's own documented SOFT dependency (`IsInK9Vehicle
    -- and IsInK9Vehicle()`) -- omitted entirely unless a test opts in, so the
    -- "global not defined at all" branch is genuinely exercised, not just the
    -- "defined and returns false" one.
    if opts.isInK9VehicleDefined ~= false then
        overrides.IsInK9Vehicle = IsInK9Vehicle
    end
    if featureBlocksAvailable then
        overrides.IsK9FeatureBlocked = IsK9FeatureBlocked
        overrides.DenyK9FeatureBlocked = DenyK9FeatureBlocked
    end

    local env = Sandbox.newEnv(overrides)
    Sandbox.loadInto('../config.lua', env)

    if opts.agilityAdvanced == false then
        env.Config.Features.AgilityAdvanced = false
    end
    if opts.detectionMethod then
        env.Config.Combat.AgilityAdvanced.detectionMethod = opts.detectionMethod
    end
    if opts.maxVaultHeight then
        env.Config.Combat.AgilityAdvanced.maxVaultHeight = opts.maxVaultHeight
    end
    if opts.vaultCooldownMs then
        env.Config.Combat.AgilityAdvanced.vaultCooldownMs = opts.vaultCooldownMs
    end

    -- RESET printLog HERE, AFTER config.lua's own load finishes and BEFORE
    -- client/agility.lua's -- config.lua's own ResolveFeatureGroups() (see
    -- that file's "FEATURE GROUPS RESOLVER" section) unconditionally
    -- prints one status line every time it loads ("Config.FeatureGroups
    -- found/not found..."), same as server/datastore.lua's own
    -- Config.Database startup line -- real, correct, and out of scope for
    -- what THIS fixture's printLog exists to check (client/agility.lua's
    -- own clamp-and-warn behaviour). Without this reset, every "must print
    -- nothing" assertion below would see config.lua's unrelated startup
    -- line and fail for a reason that has nothing to do with agility.
    for key in pairs(printLog) do printLog[key] = nil end

    local ok, err = pcall(Sandbox.loadInto, '../client/agility.lua', env)
    if opts.expectLoadError then
        return { loadOk = ok, loadError = err, printLog = printLog }
    end
    assert(ok, 'client/agility.lua failed to load: ' .. tostring(err))

    return {
        env = env,
        Config = env.Config,
        printLog = printLog,
        registerCommandCalls = registerCommandCalls,
        registerKeyMappingCalls = registerKeyMappingCalls,
        setEntityVelocityCalls = setEntityVelocityCalls,
        isPedInAnyVehicleCalls = isPedInAnyVehicleCalls,
        waitCalls = waitCalls,
        shapeTestCalls = shapeTestCalls,
        advance = function(ms) fakeNow = fakeNow + ms end,
        setCanShowK9UI = function(v) canShowK9UI = v end,
        canShowK9UICallCount = function() return canShowK9UICalls end,
        denyCallCount = function() return denyCalls end,
        setIsPedInAnyVehicle = function(v) isPedInAnyVehicle = v end,
        setIsInK9Vehicle = function(v) isInK9Vehicle = v end,
        setPedCoords = function(entity, x, y, z) pedCoords[entity] = vec3(x, y, z) end,
        setForwardVector = function(x, y, z) forwardVector = vec3(x, y, z) end,
        setEntitySpeed = function(v) entitySpeed = v end,
        setShapeTestResolver = function(fn) shapeTestResolver = fn end,
        setBlocked = function(name, blocked) blockedFeatures[name] = blocked or nil end,
        denyK9FeatureBlockedCallCount = function() return denyK9FeatureBlockedCallCount end,
        --- Runs the captured 'john-k9:vault' command handler to completion
        --- inside its own fresh coroutine, regardless of how many times (zero
        --- or more) it internally yields at Wait(0) -- see this file's header.
        runVault = function()
            local handler = assert(registerCommandCalls[1], 'client/agility.lua did not register the john-k9:vault command').handler
            local co = coroutine.create(handler)
            while coroutine.status(co) ~= 'dead' do
                local resumeOk, resumeErr = coroutine.resume(co)
                if not resumeOk then error('runVault: TryVault coroutine errored: ' .. tostring(resumeErr), 2) end
            end
        end,
    }
end

-- ----------------------------------------------------------------------
-- Startup assert -- Config.Combat.AgilityAdvanced.detectionMethod
-- ----------------------------------------------------------------------

t.test('loads cleanly with the real, shipped config.lua (detectionMethod = "raycast")', function()
    local f = newAgilityFixture()
    t.equals(#f.registerCommandCalls, 1)
    t.equals(f.registerCommandCalls[1].name, 'john-k9:vault')
end)

-- REGRESSION (this pass): this test used to assert the OPPOSITE -- that any
-- detectionMethod other than "raycast" made the WHOLE FILE fail to load via
-- a hard `assert`, which lives directly inside a top-level `if
-- Config.Features.AgilityAdvanced then` block with no deferring
-- onResourceStart/RegisterNetEvent wrapper -- so a failure there would have
-- silently un-registered 'john-k9:vault' below it too, over one operator
-- typo in a single string field. See server/cooldowns.lua's header
-- ADDENDUM for the general case this responds to. Now CLAMP AND WARN: the
-- file loads, the command still registers, and the feature runs on the only
-- implemented detection method while printing one loud, named warning.
t.test('CLAMP AND WARN: any detectionMethod other than "raycast" no longer fails to load -- warns loudly by name, falls back to raycast, and the vault command still registers', function()
    local f = newAgilityFixture({ detectionMethod = 'taggedProp' })

    local warned = false
    for _, line in ipairs(f.printLog) do
        if line:find('taggedProp', 1, true) and line:find("only 'raycast'", 1, true) then
            warned = true
        end
    end
    t.isTrue(warned, 'must name the exact bad value and explain what is actually implemented')
    t.equals(f.Config.Combat.AgilityAdvanced.detectionMethod, 'raycast', 'resolved back into Config so any later read in this file sees the corrected value')
    t.equals(#f.registerCommandCalls, 1, 'john-k9:vault must still register')
end)

t.test('CLAMP AND WARN: Config.Combat.AgilityAdvanced entirely missing no longer fails to load -- warns loudly, falls back to every built-in default, and the vault command still registers', function()
    local f = newAgilityFixture()
    f.env.Config.Combat.AgilityAdvanced = nil
    -- newAgilityFixture already loaded the file by this point (it mutates
    -- AFTER load in the fixture builder), so re-drive the load directly to
    -- exercise the "table is nil" branch specifically.
    local printLog = {}
    local function printStub(...)
        local parts = {}
        for i = 1, select('#', ...) do parts[i] = tostring(select(i, ...)) end
        printLog[#printLog + 1] = table.concat(parts, '\t')
    end
    f.env.print = printStub
    local ok, err = pcall(Sandbox.loadInto, '../client/agility.lua', f.env)
    t.isTrue(ok, 'client/agility.lua failed to reload: ' .. tostring(err))

    local warned = false
    for _, line in ipairs(printLog) do
        if line:find('Config.Combat.AgilityAdvanced', 1, true) and line:find('missing', 1, true) then
            warned = true
        end
    end
    t.isTrue(warned, 'must warn that the whole settings table is missing')
    t.equals(f.env.Config.Combat.AgilityAdvanced.detectionMethod, 'raycast')
    t.equals(f.env.Config.Combat.AgilityAdvanced.maxVaultHeight, 1.2)
    t.equals(f.env.Config.Combat.AgilityAdvanced.vaultCooldownMs, 2000)
end)

t.test('CLAMP AND WARN: a non-positive maxVaultHeight no longer errors the first time a vault is attempted -- warns loudly at load and falls back to the shipped 1.2m default', function()
    local f = newAgilityFixture({ maxVaultHeight = 0 })

    local warned = false
    for _, line in ipairs(f.printLog) do
        if line:find('Config.Combat.AgilityAdvanced.maxVaultHeight', 1, true) and line:find('found: 0', 1, true) then
            warned = true
        end
    end
    t.isTrue(warned, 'must name the exact key and the value found')
    t.equals(f.Config.Combat.AgilityAdvanced.maxVaultHeight, 1.2)
end)

t.test('CLAMP AND WARN: a non-positive vaultCooldownMs no longer silently un-throttles every vault attempt -- warns loudly at load and falls back to the shipped 2000ms default', function()
    local f = newAgilityFixture({ vaultCooldownMs = -500 })

    local warned = false
    for _, line in ipairs(f.printLog) do
        if line:find('Config.Combat.AgilityAdvanced.vaultCooldownMs', 1, true) and line:find('found: -500', 1, true) then
            warned = true
        end
    end
    t.isTrue(warned, 'must name the exact key and the value found')
    t.equals(f.Config.Combat.AgilityAdvanced.vaultCooldownMs, 2000)
end)

t.test('CLAMP AND WARN: a valid, non-default Config.Combat.AgilityAdvanced passes through completely silently', function()
    local f = newAgilityFixture({ detectionMethod = 'raycast', maxVaultHeight = 1.5, vaultCooldownMs = 3000 })
    t.equals(#f.printLog, 0, 'a fully valid config must never print anything')
    t.equals(f.Config.Combat.AgilityAdvanced.maxVaultHeight, 1.5)
    t.equals(f.Config.Combat.AgilityAdvanced.vaultCooldownMs, 3000)
end)

t.test('gating: Config.Features.AgilityAdvanced = false registers zero commands and zero key mappings', function()
    local f = newAgilityFixture({ agilityAdvanced = false })
    t.equals(#f.registerCommandCalls, 0)
    t.equals(#f.registerKeyMappingCalls, 0)
end)

t.test('registers the real Config.Vault... keybind label from locales/en.json, and the real "X" default key', function()
    local f = newAgilityFixture()
    t.equals(#f.registerKeyMappingCalls, 1)
    t.equals(f.registerKeyMappingCalls[1].commandName, 'john-k9:vault')
    t.equals(f.registerKeyMappingCalls[1].description, locale('agility.vault_keybind_label'))
    t.equals(f.registerKeyMappingCalls[1].ioType, 'keyboard')
    t.equals(f.registerKeyMappingCalls[1].defaultKey, 'X')
end)

-- ----------------------------------------------------------------------
-- TryVault -- access/vehicle/cooldown gates
-- ----------------------------------------------------------------------

t.test('TryVault: CanShowK9UI() false -- DenyK9UIAccess() called, no shape test ever fired, no velocity applied', function()
    local f = newAgilityFixture({ canShowK9UI = false })
    f.runVault()
    t.equals(f.denyCallCount(), 1)
    t.equals(#f.shapeTestCalls, 0)
    t.equals(#f.setEntityVelocityCalls, 0)
end)

t.test('TryVault: within cooldown of a real prior vault -- silent return, no shape test, no DenyK9UIAccess', function()
    local f = newAgilityFixture({ vaultCooldownMs = 2000 })
    f.setShapeTestResolver(function(_h, _p) return 2, true end) -- every band hits -- first call succeeds
    f.runVault()
    t.equals(#f.setEntityVelocityCalls, 1)

    f.advance(1000) -- still within the 2000ms cooldown
    f.runVault()
    t.equals(#f.setEntityVelocityCalls, 1, 'a second attempt inside the real cooldown window must not launch again')
    t.equals(f.denyCallCount(), 0, 'a cooldown rejection is silent, not an access-denied notification')
end)

t.test('TryVault: cooldown elapsed -- a second, later vault against a fresh obstacle succeeds independently', function()
    local f = newAgilityFixture({ vaultCooldownMs = 2000 })
    f.setShapeTestResolver(function(_h, _p) return 2, true end)
    f.runVault()
    t.equals(#f.setEntityVelocityCalls, 1)

    f.advance(2000) -- exactly at the cooldown boundary -- (now - lastVaultAt) < vaultCooldownMs is false at exactly ==
    f.runVault()
    t.equals(#f.setEntityVelocityCalls, 2)
end)

t.test('TryVault: seated in ANY vehicle -- silent return, never reaches the obstacle sweep', function()
    local f = newAgilityFixture()
    f.setIsPedInAnyVehicle(true)
    f.runVault()
    t.equals(#f.shapeTestCalls, 0)
    t.equals(#f.setEntityVelocityCalls, 0)
    t.equals(f.isPedInAnyVehicleCalls[1].bool, false, 'IsPedInAnyVehicle must be called with the real 2nd arg (false), matching production')
end)

t.test('TryVault: IsInK9Vehicle() true (soft dependency DEFINED) -- silent return, never reaches the sweep', function()
    local f = newAgilityFixture({ isInK9VehicleDefined = true })
    f.setIsInK9Vehicle(true)
    f.runVault()
    t.equals(#f.shapeTestCalls, 0)
end)

t.test('TryVault: IsInK9Vehicle NOT DEFINED AT ALL (soft dependency absent) -- does not error, and does not block the vault', function()
    local f = newAgilityFixture({ isInK9VehicleDefined = false })
    f.setShapeTestResolver(function(_h, _p) return 2, true end)
    local ok = pcall(f.runVault)
    t.isTrue(ok, 'the `IsInK9Vehicle and IsInK9Vehicle()` soft-dependency guard must never error when the global is entirely undefined')
    t.equals(#f.setEntityVelocityCalls, 1)
end)

-- ----------------------------------------------------------------------
-- DetectVaultableObstacleHeight -- reached only through TryVault (it is a
-- `local`), per this file's own convention for testing gated locals.
-- ----------------------------------------------------------------------

t.test('no obstacle in any of the 4 height bands -- silent, no velocity applied, and the miss does NOT consume the cooldown', function()
    local f = newAgilityFixture({ vaultCooldownMs = 2000 })
    f.setShapeTestResolver(function(_h, _p) return 2, false end) -- every band: resolved, no hit
    f.runVault()
    t.equals(#f.setEntityVelocityCalls, 0)
    t.equals(#f.shapeTestCalls, 4, 'all 4 height bands must be swept even though none of them hit')

    -- Immediately (fakeNow unchanged, well within vaultCooldownMs) retry with
    -- a real obstacle now present -- must succeed, proving a MISS never wrote
    -- lastVaultAt and never left any stuck reentrancy state behind either.
    f.setShapeTestResolver(function(_h, _p) return 2, true end)
    f.runVault()
    t.equals(#f.setEntityVelocityCalls, 1)
end)

t.test('obstacle taller than the configured maxVaultHeight -- silent, no velocity applied', function()
    local f = newAgilityFixture({ maxVaultHeight = 0.5, vaultCooldownMs = 2000 })
    -- Only band #4 (the 4th StartShapeTestCapsule call of this run, height
    -- 1.2m) reports a hit -- 1.2 > 0.5, rejected.
    local callCount = 0
    f.setShapeTestResolver(function(_h, _pollNumber)
        callCount = callCount + 1
        return 2, callCount == 4
    end)
    f.runVault()
    t.equals(#f.setEntityVelocityCalls, 0, 'a detected obstacle taller than maxVaultHeight must never launch the K9')
end)

t.test('obstacle exactly AT maxVaultHeight is accepted (boundary is ">", not ">=")', function()
    local f = newAgilityFixture({ maxVaultHeight = 1.2 }) -- real config default -- the tallest band exactly equals it
    f.setShapeTestResolver(function(_h, _p) return 2, true end)
    f.runVault()
    t.equals(#f.setEntityVelocityCalls, 1)
end)

t.test('a hit ONLY on a middle band (0.6m), nothing shorter or taller hitting -- obstacleHeight resolves to that band, not 0 and not the tallest band', function()
    local f = newAgilityFixture({ maxVaultHeight = 1.2 })
    local callCount = 0
    f.setShapeTestResolver(function(_h, _p)
        callCount = callCount + 1
        return 2, callCount == 2 -- band index 2 == 0.6m (SWEEP_HEIGHT_BANDS = {0.3, 0.6, 0.9, 1.2})
    end)
    f.setForwardVector(1, 0, 0)
    f.runVault()
    t.equals(#f.setEntityVelocityCalls, 1)
    -- verticalSpeed = 4.0 + obstacleHeight * 2.0 -- 4.0 + 0.6*2.0 = 5.2 proves obstacleHeight was really 0.6, not 0 (would be 4.0) or 1.2 (would be 6.4)
    t.equals(f.setEntityVelocityCalls[1].z, 5.2)
end)

t.test('SHAPE_TEST_MAX_POLLS safety cap: a band whose shape test NEVER resolves polls exactly 60 times (60 Wait(0) calls), then is treated as "no hit" for that band -- not an infinite hang', function()
    local f = newAgilityFixture({ maxVaultHeight = 1.2 })
    -- Band 1 (handle 1) never resolves; every other band (handles 2-4) resolves
    -- immediately with no hit either, so this proves the OVERALL call still
    -- completes (no hang) and treats the stuck band as a miss.
    f.setShapeTestResolver(function(handle, _pollNumber)
        if handle == 1 then return 1, false end -- "still processing" forever
        return 2, false
    end)
    local ok = pcall(f.runVault)
    t.isTrue(ok, 'a shape test handle that never resolves must not hang TryVault forever')
    t.equals(#f.waitCalls, 60, 'exactly SHAPE_TEST_MAX_POLLS (60) Wait(0) calls for the one stuck band, not unbounded')
    t.equals(#f.setEntityVelocityCalls, 0, 'a band that times out must be treated as a miss, not a hit')
end)

t.test('a band that resolves "still processing" once, then resolves with a hit on the very next poll -- exactly one Wait(0), no hang, obstacle still detected', function()
    local f = newAgilityFixture({ maxVaultHeight = 1.2 })
    f.setShapeTestResolver(function(handle, pollNumber)
        if handle == 1 and pollNumber == 1 then return 1, false end
        return 2, true
    end)
    f.runVault()
    t.equals(#f.waitCalls, 1, 'only band 1 ever yields, and only once')
    t.equals(#f.setEntityVelocityCalls, 1)
end)

t.test('the common case (every shape test resolves synchronously on its first poll) never calls Wait at all -- zero-frame-cost obstacle detection, matching this file\'s own "typically resolves within the same or next frame" comment', function()
    local f = newAgilityFixture()
    f.setShapeTestResolver(function(_h, _p) return 2, true end)
    f.runVault()
    t.equals(#f.waitCalls, 0)
end)

-- ----------------------------------------------------------------------
-- Successful vault -- velocity impulse shape
-- ----------------------------------------------------------------------

t.test('a successful vault applies SetEntityVelocity to the player\'s OWN ped, scaled by the detected obstacle height, along the ped\'s forward vector', function()
    local f = newAgilityFixture({ maxVaultHeight = 1.2 })
    f.setShapeTestResolver(function(_h, _p) return 2, true end) -- tallest band (1.2m) hits last -> obstacleHeight = 1.2
    f.setForwardVector(0, 1, 0) -- facing +Y this time, to prove the impulse really follows the forward vector, not a hardcoded axis
    f.runVault()
    t.equals(#f.setEntityVelocityCalls, 1)
    local call = f.setEntityVelocityCalls[1]
    t.equals(call.entity, 1) -- PlayerPedId()'s own fixed handle
    t.equals(call.x, 0.0) -- forward.x (0) * forwardSpeed
    t.equals(call.y, 3.5) -- forward.y (1) * forwardSpeed (3.5)
    t.equals(call.z, 4.0 + 1.2 * 2.0) -- verticalSpeed formula, obstacleHeight = 1.2
end)

-- FLUIDITY FIX (this pass, coder-frontend): SetEntityVelocity previously
-- REPLACED the K9's own momentum with a flat 3.5 forwardSpeed constant no
-- matter how fast it was already moving -- a K9 sprinting into a vault would
-- visibly snap/decelerate exactly at takeoff. See client/agility.lua's
-- TryVault() "FIXED THIS PASS" comment for the full writeup this test
-- proves both directions of.
t.test('a K9 already moving FASTER than the flat 3.5 constant carries that speed through the vault instead of being slowed down to it', function()
    local f = newAgilityFixture({ maxVaultHeight = 1.2 })
    f.setShapeTestResolver(function(_h, _p) return 2, true end)
    f.setForwardVector(1, 0, 0)
    f.setEntitySpeed(6.0) -- sprinting faster than the old flat constant
    f.runVault()
    t.equals(#f.setEntityVelocityCalls, 1)
    t.equals(f.setEntityVelocityCalls[1].x, 6.0, 'the vault must never go SLOWER than the K9 was already moving')
end)

t.test('a K9 slower than (or at) the flat 3.5 constant -- standing start, walking, or exactly 3.5 -- still gets the existing floor, not throttled down further', function()
    local f = newAgilityFixture({ maxVaultHeight = 1.2 })
    f.setShapeTestResolver(function(_h, _p) return 2, true end)
    f.setForwardVector(1, 0, 0)
    f.setEntitySpeed(1.5) -- walking -- slower than the 3.5 floor
    f.runVault()
    t.equals(f.setEntityVelocityCalls[1].x, 3.5, 'a slow-moving K9 still gets the same minimum launch speed it always did, unchanged by this fix')
end)

-- ----------------------------------------------------------------------
-- RE-ENTRANCY BUG (found and fixed this pass, client/agility.lua) --
-- TryVault() previously had no guard around its own async, multi-frame
-- obstacle-detection sweep. See client/agility.lua's own "Bug fix (this
-- pass..." comment right above `vaultInProgress`'s declaration for the full
-- writeup this test proves.
--
-- REPRO SHAPE: two overlapping TryVault() invocations (modeling a keybind
-- double-press, engine auto-repeat, or two inputs landing in the same/
-- adjacent frame) where the FIRST call's own obstacle-detection sweep has
-- not finished (has yielded at least once at Wait(0)) by the time the
-- SECOND call starts. Both calls detect the SAME real obstacle and, before
-- the fix, both called SetEntityVelocity -- a stacked double-launch from
-- what the player experienced as one button press.
--
-- Driven with two independent, hand-created coroutines (see this file's
-- header for why Sandbox.newThreadRunner() does not fit this one scenario)
-- so this test controls the EXACT interleaving: resume A to its own first
-- yield, THEN start B (proving B's cooldown check runs while A is still
-- mid-flight and lastVaultAt has NOT yet been updated by A), THEN drain
-- both to completion.
-- ----------------------------------------------------------------------

t.test('BUG (found + fixed this pass): a second TryVault() invocation overlapping the first call\'s still-in-flight async obstacle sweep is rejected, not stacked into a second SetEntityVelocity call', function()
    local f = newAgilityFixture({ vaultCooldownMs = 2000 })

    -- Handles 1 and 2 are the very FIRST StartShapeTestCapsule call each
    -- coroutine makes (its own band-1 sweep) -- each reports "still
    -- processing" exactly once, forcing exactly one Wait(0) yield per
    -- coroutine. Every other handle (both coroutines' bands 2-4) resolves
    -- immediately. Every band hits, so DetectVaultableObstacleHeight
    -- resolves to the tallest band (1.2m) for BOTH calls -- well within the
    -- real, unmodified 1.2m maxVaultHeight ceiling (equal, not over).
    f.setShapeTestResolver(function(handle, pollNumber)
        if handle <= 2 and pollNumber == 1 then
            return 1, false -- "still processing" -- the one deliberate yield point
        end
        return 2, true
    end)

    local handler = f.registerCommandCalls[1].handler
    local coA = coroutine.create(handler)
    local coB = coroutine.create(handler) -- the SAME captured production handler -- a second, independent invocation, exactly what a double-press dispatches

    local okA = coroutine.resume(coA)
    assert(okA, 'coroutine A errored before its first yield')
    assert(coroutine.status(coA) == 'suspended', 'expected A to be mid-flight (suspended inside its own Wait(0) poll), not already finished -- if this fails, the shape-test resolver setup above is wrong, not the production code')

    -- THE BUG WINDOW: A has not returned yet, so lastVaultAt has NOT been
    -- updated (that only happens AFTER DetectVaultableObstacleHeight
    -- returns) -- B's own cooldown check below runs against the
    -- STILL-STALE lastVaultAt from before this test ever ran (-math.huge),
    -- so it passes trivially, exactly like a real double-press would.
    local okB = coroutine.resume(coB)
    assert(okB, 'coroutine B errored before its first yield (or on completion, if the fix already rejected it outright)')

    -- Drain whichever of A/B are still alive to completion, in either order
    -- -- this loop is written to work identically whether the fix causes B
    -- to finish immediately on its first resume (rejected before ever
    -- yielding) or, on the UNFIXED code, to run a full independent sweep of
    -- its own.
    while coroutine.status(coA) ~= 'dead' do
        local ok, err = coroutine.resume(coA)
        assert(ok, 'coroutine A errored mid-flight: ' .. tostring(err))
    end
    while coroutine.status(coB) ~= 'dead' do
        local ok, err = coroutine.resume(coB)
        assert(ok, 'coroutine B errored mid-flight: ' .. tostring(err))
    end

    t.equals(#f.setEntityVelocityCalls, 1,
        'a second, overlapping TryVault() call arriving while the first call\'s own async obstacle-detection sweep is still in flight must be rejected outright, not run its own independent sweep and stack a second launch impulse on top of the first')
end)

t.test('RE-ENTRANCY GUARD RESET: once the in-flight sweep from a FIRST call fully completes, a genuinely NEW, later TryVault() call (after the sweep, not overlapping it) is not permanently blocked by the guard', function()
    local f = newAgilityFixture({ vaultCooldownMs = 2000 })
    f.setShapeTestResolver(function(handle, pollNumber)
        if handle == 1 and pollNumber == 1 then return 1, false end
        return 2, true
    end)

    f.runVault() -- completes fully (drains its own one yield) -- vaultInProgress must be reset to false by the time this returns
    t.equals(#f.setEntityVelocityCalls, 1)

    f.advance(2000) -- past cooldown
    f.runVault() -- a genuinely new, later, non-overlapping call must still work
    t.equals(#f.setEntityVelocityCalls, 2, 'the re-entrancy guard must reset once a sweep completes -- it must never permanently stick at true and block every future vault attempt')
end)

-- ----------------------------------------------------------------------
-- PER-PERSON BLOCK (client/featureblocks.lua, REQUESTED) -- checked right
-- after the existing CanShowK9UI() gate. A vault is a single one-shot
-- action with no held/persistent state, so there is no "already active"
-- teardown case to prove here, unlike client/vision.lua's toggles.
-- ----------------------------------------------------------------------

t.test('TryVault: AgilityAdvanced blocked -- DenyK9FeatureBlocked() called, no shape test ever fired, no velocity applied', function()
    local f = newAgilityFixture()
    f.setBlocked('AgilityAdvanced', true)
    f.runVault()
    t.equals(f.denyK9FeatureBlockedCallCount(), 1)
    t.equals(#f.shapeTestCalls, 0)
    t.equals(#f.setEntityVelocityCalls, 0)
end)

t.test('TryVault: a block on a DIFFERENT feature name never affects AgilityAdvanced', function()
    local f = newAgilityFixture()
    f.setBlocked('RadialMenu', true)
    f.setShapeTestResolver(function(_h, _p) return 2, true end)
    f.runVault()
    t.equals(#f.setEntityVelocityCalls, 1)
end)

t.test('fails OPEN: client/featureblocks.lua not loaded (IsK9FeatureBlocked undefined) -- TryVault works exactly as before this pass', function()
    local f = newAgilityFixture({ featureBlocksAvailable = false })
    t.isNil(f.env.IsK9FeatureBlocked)
    f.setShapeTestResolver(function(_h, _p) return 2, true end)
    f.runVault()
    t.equals(#f.setEntityVelocityCalls, 1, 'an unknown block state must never freeze this ability -- it must fail OPEN')
end)

os.exit(t.summary())
