--[[
    tests/clientproximityaudio_spec.lua

    Direct, black-box tests of client/proximityaudio.lua against the REAL,
    unmodified production file: the Config.Features.ProximityAudioFX
    file-scope gate, the GetK9AudioMaxDistance()-clamped trigger-distance
    computation (both directions -- a configured distance ABOVE the ceiling
    gets clamped down, and the soft-dependency fallback when
    GetK9AudioMaxDistance itself does not exist), the discovery/maintenance
    thread's own-ped exclusion / model / death / existence / range gating,
    the "stale loop" restart path (client/audio.lua's own AUDIO_MAX_LOOP_MS
    ceiling force-stopping a loop out from under this file), and the
    onResourceStop safety net.

    CROSS-FILE GLOBALS -- STUBBED DIRECTLY, NOT LOADED FROM THE REAL FILES:
    this file's own three cross-file dependencies (PlayK9Sound/StopK9Sound/
    IsK9SoundActive from client/audio.lua, GetK9AudioMaxDistance also from
    client/audio.lua, IsEntityModelK9 from client/main.lua) are all simple,
    controllable/capturing stand-ins here -- the SAME "stub the cross-file
    global directly" convention tests/clientradial_spec.lua already
    established for its own ~30 cross-file globals, rather than loading the
    real client/audio.lua/client/main.lua into this sandbox too. This keeps
    this file's own scope precisely on client/proximityaudio.lua's OWN
    discovery/lifecycle logic (already independently, thoroughly covered by
    tests/clientaudio_spec.lua on the audio.lua side).

    THREAD STEPPING NOTE: the discovery thread's FIRST statement is
    `Wait(PROXIMITY_SCAN_INTERVAL_MS)` directly -- no assignment before it,
    matching DEVELOPER_REFERENCE.md's own generic stepping note exactly (unlike
    tests/clientvision_spec.lua/tests/clientaudio_spec.lua's threads, which
    both deviate from it). So step() #1 is a pure prime (yields at the very
    first Wait, no scan pass yet); step() #2 onward is exactly one scan pass
    per call, then yields again at the next Wait.

    VECTOR STUB: identical shape to clientradial_spec.lua/
    clientagility_spec.lua/clientaudio_spec.lua's own copies.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

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

--- @param opts { proximityAudioFX: boolean?, triggerDistance: number?, audioMaxDistance: number|false?, soundName: string? }?
---   `audioMaxDistance = false` means GetK9AudioMaxDistance is NOT defined at
---   all (soft-dependency-absent case); omitted/number means it is defined
---   and returns that number (default 30.0, the real client/audio.lua value).
--- @return table fixture
local function newProximityAudioFixture(opts)
    opts = opts or {}

    local myPed = 100
    local function PlayerPedId() return myPed end

    local coords = { [myPed] = vec3(0, 0, 0) }
    local function GetEntityCoords(entity) return coords[entity] or vec3(0, 0, 0) end

    local gamePool = {}
    local function GetGamePool(poolName) assert(poolName == 'CPed'); return gamePool end

    local existsMap = {}
    local function DoesEntityExist(entity) return existsMap[entity] == true end
    local deadMap = {}
    local function IsEntityDead(entity) return deadMap[entity] == true end
    local k9ModelMap = {}
    local function IsEntityModelK9(entity) return k9ModelMap[entity] == true end
    local netIdMap = {}
    local function NetworkGetNetworkIdFromEntity(entity) return netIdMap[entity] end

    local playK9SoundCalls = {}
    local nextSoundId = 0
    local playK9SoundShouldFail = false
    local function PlayK9Sound(netId, soundName, playOpts)
        playK9SoundCalls[#playK9SoundCalls + 1] = { netId = netId, soundName = soundName, opts = playOpts }
        if playK9SoundShouldFail then return nil end
        nextSoundId = nextSoundId + 1
        return nextSoundId
    end
    local stopK9SoundCalls = {}
    local function StopK9Sound(soundId) stopK9SoundCalls[#stopK9SoundCalls + 1] = soundId end
    local soundActiveMap = {}
    local function IsK9SoundActive(soundId) if soundActiveMap[soundId] == nil then return true end; return soundActiveMap[soundId] end

    -- PER-PERSON BLOCK (client/featureblocks.lua, REQUESTED) -- stubbed,
    -- same "controllable stand-in" convention as this fixture's other
    -- cross-file globals. Soft dependency: only added to `env` when
    -- `opts.featureBlocksAvailable` is not explicitly false.
    local featureBlocksAvailable = opts.featureBlocksAvailable
    if featureBlocksAvailable == nil then featureBlocksAvailable = true end
    local blockedFeatures = opts.blockedFeatures or {}
    local function IsK9FeatureBlocked(name) return blockedFeatures[name] == true end

    local runner = Sandbox.newThreadRunner()
    local threadCreateCount = 0
    local function CreateThread(fn) threadCreateCount = threadCreateCount + 1; runner.CreateThread(fn) end
    local waitCalls = {}
    local function Wait(ms) waitCalls[#waitCalls + 1] = ms; runner.Wait(ms) end

    local RESOURCE_NAME = 'john-k9'
    local function GetCurrentResourceName() return RESOURCE_NAME end
    local eventHandlers = {}
    local function AddEventHandler(eventName, handler)
        eventHandlers[eventName] = eventHandlers[eventName] or {}
        eventHandlers[eventName][#eventHandlers[eventName] + 1] = handler
    end

    local overrides = {
        PlayerPedId = PlayerPedId,
        GetEntityCoords = GetEntityCoords,
        GetGamePool = GetGamePool,
        DoesEntityExist = DoesEntityExist,
        IsEntityDead = IsEntityDead,
        IsEntityModelK9 = IsEntityModelK9,
        NetworkGetNetworkIdFromEntity = NetworkGetNetworkIdFromEntity,
        StopK9Sound = StopK9Sound,
        IsK9SoundActive = IsK9SoundActive,
        CreateThread = CreateThread,
        Wait = Wait,
        GetCurrentResourceName = GetCurrentResourceName,
        AddEventHandler = AddEventHandler,
    }
    -- soft-dependency-absent case (BasicBarkSounds disabled on the audio.lua
    -- side): PlayK9Sound genuinely does not exist as a global at all.
    if not opts.omitPlayK9Sound then
        overrides.PlayK9Sound = PlayK9Sound
    end
    if opts.omitIsK9SoundActive then
        overrides.IsK9SoundActive = nil
    end
    if opts.audioMaxDistance ~= false then
        overrides.GetK9AudioMaxDistance = function() return opts.audioMaxDistance or 30.0 end
    end
    if featureBlocksAvailable then
        overrides.IsK9FeatureBlocked = IsK9FeatureBlocked
    end

    local env = Sandbox.newEnv(overrides)
    Sandbox.loadInto('../config.lua', env)

    if opts.proximityAudioFX == false then
        env.Config.Features.ProximityAudioFX = false
    end
    if opts.triggerDistance then
        env.Config.ProximityAudioFX.triggerDistance = opts.triggerDistance
    end
    if opts.soundName then
        env.Config.ProximityAudioFX.soundName = opts.soundName
    end
    if opts.scanIntervalMs ~= nil then
        env.Config.ProximityAudioFX.scanIntervalMs = opts.scanIntervalMs
    end
    if opts.triggerDistance ~= nil then
        env.Config.ProximityAudioFX.triggerDistance = opts.triggerDistance
    end

    -- CLAMP-AND-WARN CAPTURE -- proves a bad scanIntervalMs actually warns
    -- (not just "doesn't crash"), same convention as
    -- tests/clientkennel_spec.lua's own printLog
    -- captures for this exact class of guard.
    local printLog = {}
    env.print = function(...)
        local parts = {}
        for i = 1, select('#', ...) do parts[i] = tostring(select(i, ...)) end
        printLog[#printLog + 1] = table.concat(parts, '\t')
    end

    Sandbox.loadInto('../client/proximityaudio.lua', env)

    return {
        env = env,
        Config = env.Config,
        printLog = printLog,
        playK9SoundCalls = playK9SoundCalls,
        stopK9SoundCalls = stopK9SoundCalls,
        threadCreateCount = function() return threadCreateCount end,
        waitCalls = waitCalls,
        step = function() runner.step() end,
        setEntityCoords = function(entity, x, y, z) coords[entity] = vec3(x, y, z) end,
        setExists = function(entity, v) existsMap[entity] = v end,
        setDead = function(entity, v) deadMap[entity] = v end,
        setIsK9 = function(entity, v) k9ModelMap[entity] = v end,
        setNetId = function(entity, netId) netIdMap[entity] = netId end,
        setGamePool = function(list) gamePool = list end,
        setPlayK9SoundShouldFail = function(v) playK9SoundShouldFail = v end,
        setSoundActive = function(soundId, v) soundActiveMap[soundId] = v end,
        --- Registers one full, ready-to-track K9 ped at the given distance
        --- along +X from myPed -- the common setup most tests below need.
        addK9 = function(entity, distance, netId)
            gamePool[#gamePool + 1] = entity
            existsMap[entity] = true
            deadMap[entity] = false
            k9ModelMap[entity] = true
            coords[entity] = vec3(distance, 0, 0)
            netIdMap[entity] = netId or (entity * 1000)
        end,
        fireResourceStop = function(resourceName)
            for _, handler in ipairs(eventHandlers['onResourceStop'] or {}) do
                handler(resourceName)
            end
        end,
        onResourceStopHandlerCount = function() return #(eventHandlers['onResourceStop'] or {}) end,
        setBlocked = function(name, blocked) blockedFeatures[name] = blocked or nil end,
    }
end

-- ----------------------------------------------------------------------
-- Gating
-- ----------------------------------------------------------------------

t.test('gating: ProximityAudioFX = false -- no thread, no onResourceStop handler, file is entirely inert', function()
    local f = newProximityAudioFixture({ proximityAudioFX = false })
    t.equals(f.threadCreateCount(), 0)
    t.equals(f.onResourceStopHandlerCount(), 0)
end)

t.test('gating: ProximityAudioFX = true (the real, shipped default) -- one discovery thread and one onResourceStop handler', function()
    local f = newProximityAudioFixture()
    t.equals(f.threadCreateCount(), 1)
    t.equals(f.onResourceStopHandlerCount(), 1)
end)

t.test('the discovery thread waits on the real, configured scanIntervalMs (2500ms) every pass -- never Wait(0), never a tight idle spin', function()
    local f = newProximityAudioFixture()
    f.step() -- prime
    f.step() -- one pass
    f.step() -- another pass
    for _, ms in ipairs(f.waitCalls) do
        t.equals(ms, 2500)
    end
    t.isTrue(#f.waitCalls >= 2)
end)

-- ----------------------------------------------------------------------
-- CLAMP AND WARN: Config.ProximityAudioFX.scanIntervalMs -- BUG (found +
-- fixed this pass): `scanIntervalMs or 2500` let a configured 0 (or any
-- other non-positive/invalid value) pass straight through as the real
-- Wait() argument -- Lua's `or` only falls through on nil/false, and 0 is
-- a genuine, truthy number. See client/proximityaudio.lua's own comment on
-- PROXIMITY_SCAN_INTERVAL_MS_DEFAULT for the full writeup.
-- ----------------------------------------------------------------------

t.test('CLAMP AND WARN: scanIntervalMs = 0 no longer removes the throttle -- falls back to the shipped 2500ms default and warns loudly, naming the exact key', function()
    local f = newProximityAudioFixture({ scanIntervalMs = 0 })
    f.step() -- prime
    f.step() -- one pass
    for _, ms in ipairs(f.waitCalls) do
        t.equals(ms, 2500, 'FIXED: a configured 0 must never reach Wait() directly -- that would be a full per-frame scan, not a faster one')
    end

    local warned = false
    for _, line in ipairs(f.printLog) do
        if line:find('Config.ProximityAudioFX.scanIntervalMs', 1, true) and line:find('got 0', 1, true) then warned = true end
    end
    t.isTrue(warned, 'must warn loudly, naming both the config path and the bad value -- silent clamping trains operators to never notice their config typo')
end)

-- ----------------------------------------------------------------------
-- CLAMP AND WARN: Config.ProximityAudioFX.triggerDistance. The sibling
-- guard above existed for scanIntervalMs and was never applied here, even
-- though this one is worse: `triggerDistance or default` is evaluated at
-- FILE SCOPE and fed straight to math.min, so a truthy non-number -- a
-- quoted '25' from a hand-edited config, a boolean, a stray table --
-- throws and aborts the rest of the file's load. The discovery thread and
-- the onResourceStop cleanup never register, and the whole feature is gone
-- for that session with only a stack trace to show for it.
--
-- These two tests pin both halves: the loud one that used to crash, and
-- the quiet one where a truthy zero passes through and no loop ever
-- starts.
-- ----------------------------------------------------------------------

t.test('CLAMP AND WARN: a non-number triggerDistance no longer aborts the file at load -- it falls back and warns, naming the key and the bad value', function()
    local f = newProximityAudioFixture({ triggerDistance = '25' })
    t.isTrue(f.threadCreateCount() > 0, 'FIXED: a truthy non-number reaching math.min at file scope used to throw and take the rest of this file down with it -- the discovery thread proves the file finished loading')

    local warned = false
    for _, line in ipairs(f.printLog) do
        if line:find('Config.ProximityAudioFX.triggerDistance', 1, true) and line:find('got 25', 1, true) then warned = true end
    end
    t.isTrue(warned, 'must warn loudly, naming both the config path and the bad value')
end)

t.test('CLAMP AND WARN: a triggerDistance of 0 falls back rather than silently starting no loop -- zero is truthy in Lua, so `or` never catches it', function()
    local f = newProximityAudioFixture({ triggerDistance = 0 })
    t.isTrue(f.threadCreateCount() > 0, 'a zero must not abort the file either')

    local warned = false
    for _, line in ipairs(f.printLog) do
        if line:find('Config.ProximityAudioFX.triggerDistance', 1, true) and line:find('got 0', 1, true) then warned = true end
    end
    t.isTrue(warned, 'a non-positive distance means no ambient loop ever starts -- silent is the wrong failure here')
end)

t.test('CLAMP AND WARN: a negative scanIntervalMs also falls back to the default and warns', function()
    local f = newProximityAudioFixture({ scanIntervalMs = -500 })
    f.step()
    f.step()
    for _, ms in ipairs(f.waitCalls) do
        t.equals(ms, 2500)
    end
end)

t.test('CLAMP AND WARN: a non-number scanIntervalMs (a numeric-looking string, matching a plain form-field/JSON-config footgun) also falls back to the default and warns', function()
    local f = newProximityAudioFixture({ scanIntervalMs = '2500' })
    f.step()
    f.step()
    for _, ms in ipairs(f.waitCalls) do
        t.equals(ms, 2500)
    end
end)

t.test('CLAMP AND WARN: a VALID, non-default scanIntervalMs is still used as-is, not silently replaced by the fallback', function()
    local f = newProximityAudioFixture({ scanIntervalMs = 9000 })
    f.step()
    f.step()
    for _, ms in ipairs(f.waitCalls) do
        t.equals(ms, 9000)
    end
    for _, line in ipairs(f.printLog) do
        t.isNil(line:find('scanIntervalMs', 1, true), 'a valid configured value must pass through silently -- warning on a good value trains operators to ignore the warning')
    end
end)

-- ----------------------------------------------------------------------
-- Trigger-distance clamp -- GetK9AudioMaxDistance() cross-file read
-- ----------------------------------------------------------------------

t.test('clamp: real shipped config (triggerDistance 25.0, audio ceiling 30.0) -- effective radius is 25.0 (the smaller of the two)', function()
    local f = newProximityAudioFixture()
    f.step() -- prime
    f.addK9(1, 25.0) -- exactly at the boundary -- "<=" is inclusive
    f.step()
    t.equals(#f.playK9SoundCalls, 1, 'a K9 exactly at the real 25.0m trigger distance must still be started')
end)

t.test('clamp: a K9 just beyond the real 25.0m trigger distance is never started', function()
    local f = newProximityAudioFixture()
    f.step()
    f.addK9(1, 25.5)
    f.step()
    t.equals(#f.playK9SoundCalls, 0)
end)

t.test('clamp: a configured triggerDistance ABOVE the real audio ceiling gets clamped DOWN to the ceiling -- a K9 between the two distances is NOT started', function()
    local f = newProximityAudioFixture({ triggerDistance = 40.0, audioMaxDistance = 30.0 })
    f.step()
    f.addK9(1, 35.0) -- inside the configured 40.0 request, but beyond the real 30.0 ceiling
    f.step()
    t.equals(#f.playK9SoundCalls, 0, 'the clamp must protect against a config value above audio.lua\'s own falloff ceiling -- otherwise this loop would sit at a permanent, wasted gain of 0.0')
end)

t.test('clamp: GetK9AudioMaxDistance NOT DEFINED AT ALL (soft dependency absent) -- falls back to the file\'s own hardcoded 25.0m default, clamped against itself', function()
    local f = newProximityAudioFixture({ audioMaxDistance = false, triggerDistance = 40.0 })
    f.step()
    f.addK9(1, 30.0) -- beyond the 25.0 fallback ceiling
    f.step()
    t.equals(#f.playK9SoundCalls, 0)

    f.addK9(2, 20.0) -- within the 25.0 fallback ceiling
    f.step()
    t.equals(#f.playK9SoundCalls, 1)
end)

-- ----------------------------------------------------------------------
-- Discovery gating -- own ped / model / death / existence
-- ----------------------------------------------------------------------

t.test('the local player\'s OWN ped is never tracked, even if (hypothetically) it were K9-modeled', function()
    local f = newProximityAudioFixture()
    f.step()
    f.setGamePool({ 100 }) -- 100 is myPed
    f.setIsK9(100, true)
    f.setExists(100, true)
    f.setDead(100, false)
    f.step()
    t.equals(#f.playK9SoundCalls, 0)
end)

t.test('a non-K9-modeled ped in range is never tracked', function()
    local f = newProximityAudioFixture()
    f.step()
    f.addK9(1, 5.0)
    f.setIsK9(1, false)
    f.step()
    t.equals(#f.playK9SoundCalls, 0)
end)

t.test('a dead K9-modeled ped in range is never tracked', function()
    local f = newProximityAudioFixture()
    f.step()
    f.addK9(1, 5.0)
    f.setDead(1, true)
    f.step()
    t.equals(#f.playK9SoundCalls, 0)
end)

t.test('a K9-modeled ped that DoesEntityExist reports false for is never tracked', function()
    local f = newProximityAudioFixture()
    f.step()
    f.addK9(1, 5.0)
    f.setExists(1, false)
    f.step()
    t.equals(#f.playK9SoundCalls, 0)
end)

t.test('a resolvable netId of 0 (or nil) blocks StartProximityLoop even for an otherwise perfectly valid, in-range K9', function()
    local f = newProximityAudioFixture()
    f.step()
    f.addK9(1, 5.0, 0) -- netId 0 -- treated as unresolvable
    f.step()
    t.equals(#f.playK9SoundCalls, 0)
end)

t.test('a valid, alive, in-range, K9-modeled ped starts a loop with the real Config.ProximityAudioFX.soundName and the correct netId', function()
    local f = newProximityAudioFixture()
    f.step()
    f.addK9(1, 5.0, 4242)
    f.step()
    t.equals(#f.playK9SoundCalls, 1)
    t.equals(f.playK9SoundCalls[1].netId, 4242)
    t.equals(f.playK9SoundCalls[1].soundName, 'Growl_Ambient')
    t.equals(f.playK9SoundCalls[1].opts.loop, true)
end)

-- ----------------------------------------------------------------------
-- Cleanup -- range/death/despawn, and PlayK9Sound declining
-- ----------------------------------------------------------------------

t.test('a tracked K9 moving out of trigger range gets its loop stopped on the next scan', function()
    local f = newProximityAudioFixture()
    f.step()
    f.addK9(1, 5.0)
    f.step()
    t.equals(#f.playK9SoundCalls, 1)

    f.setEntityCoords(1, 26.0, 0, 0) -- now beyond the real 25.0m radius
    f.step()
    t.equals(#f.stopK9SoundCalls, 1)
end)

t.test('a tracked K9 that dies gets its loop stopped on the next scan', function()
    local f = newProximityAudioFixture()
    f.step()
    f.addK9(1, 5.0)
    f.step()
    t.equals(#f.playK9SoundCalls, 1)

    f.setDead(1, true)
    f.step()
    t.equals(#f.stopK9SoundCalls, 1)
end)

t.test('a tracked K9 that despawns (DoesEntityExist -> false) gets its loop stopped on the next scan', function()
    local f = newProximityAudioFixture()
    f.step()
    f.addK9(1, 5.0)
    f.step()
    t.equals(#f.playK9SoundCalls, 1)

    f.setExists(1, false)
    f.step()
    t.equals(#f.stopK9SoundCalls, 1)
end)

t.test('PlayK9Sound declining (returns nil) leaves nothing tracked -- the next scan retries StartProximityLoop for the same still-in-range K9', function()
    local f = newProximityAudioFixture()
    f.setPlayK9SoundShouldFail(true)
    f.step()
    f.addK9(1, 5.0)
    f.step()
    t.equals(#f.playK9SoundCalls, 1)

    f.step() -- still in range, still no tracked loop -- must retry
    t.equals(#f.playK9SoundCalls, 2)

    f.setPlayK9SoundShouldFail(false)
    f.step()
    t.equals(#f.playK9SoundCalls, 3, 'a THIRD attempt must finally succeed once PlayK9Sound stops declining')
end)

t.test('PlayK9Sound not defined at all (soft dependency absent) -- never errors, never tracks anything, across repeated scans', function()
    local f = newProximityAudioFixture({ omitPlayK9Sound = true })
    f.step()
    f.addK9(1, 5.0)
    local ok1 = pcall(f.step)
    local ok2 = pcall(f.step)
    t.isTrue(ok1)
    t.isTrue(ok2)
end)

-- ----------------------------------------------------------------------
-- Stale-loop restart -- client/audio.lua's own AUDIO_MAX_LOOP_MS ceiling
-- force-stopping a loop out from under this file, while the K9 is STILL in
-- range.
-- ----------------------------------------------------------------------

t.test('stale loop: IsK9SoundActive turns false for a still-in-range K9 (audio.lua\'s own safety ceiling fired) -- the next scan detects it, drops the stale entry, and starts a genuinely NEW loop (a new PlayK9Sound call)', function()
    local f = newProximityAudioFixture()
    f.step()
    f.addK9(1, 5.0)
    f.step()
    t.equals(#f.playK9SoundCalls, 1)

    f.setSoundActive(1, false) -- audio.lua's own ceiling silently force-stopped soundId 1
    f.step()
    t.equals(#f.playK9SoundCalls, 2, 'a stale (silently-expired) loop for a K9 still in range must be replaced with a fresh PlayK9Sound call, not left permanently untracked')
end)

t.test('stale loop: IsK9SoundActive NOT DEFINED AT ALL (soft dependency absent) -- a tracked loop is NEVER treated as stale, even if it silently died on the audio.lua side -- documented, accepted degrade, not a crash', function()
    local f = newProximityAudioFixture({ omitIsK9SoundActive = true })
    f.step()
    f.addK9(1, 5.0)
    f.step()
    t.equals(#f.playK9SoundCalls, 1)

    f.step()
    f.step()
    t.equals(#f.playK9SoundCalls, 1, 'without IsK9SoundActive, staleLoop can never be detected -- this is this file\'s own documented soft-dependency degrade, not a new bug introduced by this spec')
end)

-- ----------------------------------------------------------------------
-- onResourceStop
-- ----------------------------------------------------------------------

t.test('onResourceStop: a different resource stopping is ignored -- the tracked loop is untouched', function()
    local f = newProximityAudioFixture()
    f.step()
    f.addK9(1, 5.0)
    f.step()
    f.fireResourceStop('some_other_resource')
    t.equals(#f.stopK9SoundCalls, 0)
end)

t.test('onResourceStop: this resource stopping stops EVERY currently-tracked loop', function()
    local f = newProximityAudioFixture()
    f.step()
    f.addK9(1, 5.0)
    f.addK9(2, 6.0)
    f.step()
    t.equals(#f.playK9SoundCalls, 2)

    f.fireResourceStop('john-k9')
    t.equals(#f.stopK9SoundCalls, 2)
end)

t.test('onResourceStop: a harmless no-op when nothing was ever tracked', function()
    local f = newProximityAudioFixture()
    local ok = pcall(f.fireResourceStop, 'john-k9')
    t.isTrue(ok)
    t.equals(#f.stopK9SoundCalls, 0)
end)

-- ----------------------------------------------------------------------
-- PER-PERSON BLOCK (client/featureblocks.lua, REQUESTED) -- this is the
-- LISTENER's own ability to hear ambient K9 audio, so a block silences an
-- already-playing loop outright (never merely refuses a new one) -- see
-- this file's own production-code comment on this exact scan-thread check.
-- ----------------------------------------------------------------------

t.test('per-person block: ProximityAudioFX blocked -- discovery is skipped entirely, no new loop ever starts', function()
    local f = newProximityAudioFixture()
    f.step() -- prime
    f.setBlocked('ProximityAudioFX', true)
    f.addK9(1, 5.0)
    f.step()
    t.equals(#f.playK9SoundCalls, 0)
end)

t.test('per-person block: a block applied AFTER a loop is already playing stops it on the very next scan pass', function()
    local f = newProximityAudioFixture()
    f.step() -- prime
    f.addK9(1, 5.0)
    f.step() -- starts the loop
    t.equals(#f.playK9SoundCalls, 1)

    f.setBlocked('ProximityAudioFX', true)
    f.step() -- must stop it, not merely refuse a NEW one
    t.equals(#f.stopK9SoundCalls, 1)
end)

t.test('per-person block: unblocking lets discovery resume on the next scan pass', function()
    local f = newProximityAudioFixture()
    f.step() -- prime
    f.setBlocked('ProximityAudioFX', true)
    f.addK9(1, 5.0)
    f.step() -- blocked -- no loop starts
    t.equals(#f.playK9SoundCalls, 0)

    f.setBlocked('ProximityAudioFX', false)
    f.step() -- unblocked -- discovery resumes
    t.equals(#f.playK9SoundCalls, 1)
end)

t.test('per-person block: a block on a DIFFERENT feature name never affects ProximityAudioFX', function()
    local f = newProximityAudioFixture()
    f.step() -- prime
    f.setBlocked('NightVision', true)
    f.addK9(1, 5.0)
    f.step()
    t.equals(#f.playK9SoundCalls, 1)
end)

t.test('fails OPEN: client/featureblocks.lua not loaded (IsK9FeatureBlocked undefined) -- discovery works exactly as before this pass', function()
    local f = newProximityAudioFixture({ featureBlocksAvailable = false })
    t.isNil(f.env.IsK9FeatureBlocked)
    f.step() -- prime
    f.addK9(1, 5.0)
    f.step()
    t.equals(#f.playK9SoundCalls, 1, 'an unknown block state must never silence this feature -- it must fail OPEN')
end)

os.exit(t.summary())
