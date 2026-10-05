--[[
    tests/clientaudio_spec.lua

    Direct, black-box tests of client/audio.lua (the NUI/Web-Audio bridge)
    against the REAL, unmodified production file: the Config.Features.
    BasicBarkSounds file-scope gate, GetK9AudioMaxDistance(), the
    DistanceToGain()/GainToEntity() falloff math (reached only indirectly,
    through PlayK9Sound -- both are `local`), PlayK9Sound's one-shot vs.
    loop=true paths (including the AUDIO_MAX_LOOP_MS safety ceiling and the
    "entity streamed out mid-loop" self-heal), StopK9Sound, IsK9SoundActive,
    and ToAudioFileKey's known-name-table vs. fallback-transform behavior
    (also reached only through PlayK9Sound's own `sound` payload field).

    STYLE: follows tests/clientvision_spec.lua/tests/clientaudio_spec.lua's
    sibling files -- fresh sandbox per test, drive the real captured globals,
    Sandbox.newThreadRunner() for the one loop=true CreateThread body this
    file ever creates.

    THREAD STEPPING NOTE FOR THIS FILE'S ONE THREAD BODY (PlayK9Sound's
    loop=true branch): its FIRST statement is `local elapsed = 0`, a plain
    assignment, BEFORE the `while` loop even starts -- NOT a `Wait(...)` the
    way DEVELOPER_REFERENCE.md's own generic stepping note assumes (see
    tests/clientvision_spec.lua's own header for the identical situation and
    the same reasoning). So:
      step() #1 (prime) -- resumes from the very start: runs `elapsed = 0`,
        evaluates the while-condition (true, since PlayK9Sound already set
        activeLoops[id] = true and elapsed(0) < AUDIO_MAX_LOOP_MS before this
        thread's body ever runs), enters the loop, and yields at
        Wait(AUDIO_GAIN_POLL_MS) -- the FIRST statement INSIDE the loop. This
        step runs no gain-poll logic yet.
      step() #2 onward -- resumes AFTER Wait, runs exactly one gain-poll pass
        (elapsed += 500, the activeLoops/liveEntity checks, and either a
        'audio:setGain' push or a self-stop), then re-checks the
        while-condition: if still true, loops back to Wait and yields again;
        if false (activeLoops[id] cleared, or the AUDIO_MAX_LOOP_MS ceiling
        reached), falls out of the loop, runs its own final safety-ceiling
        StopK9Sound call if still tracked, and the coroutine dies -- all
        within that SAME step() call, no further yield.

    STUBBING EFFORT, reported honestly per this task's own instruction: every
    native this file touches is a simple capturing/controllable stub
    (PlayerPedId, GetEntityCoords, SendNUIMessage, ResolveNetworkEntity) plus
    CreateThread/Wait -- the same vector3-with-metatables helper reused
    verbatim from clientradial_spec.lua/clientagility_spec.lua for the one
    `#(a - b)` distance calc this file's own GainToEntity() does. Nothing
    here needed disproportionate stubbing.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

-- ----------------------------------------------------------------------
-- Vector3-alike stub -- identical shape to clientradial_spec.lua/
-- clientagility_spec.lua's own copies.
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

--- @param opts { basicBarkSounds: boolean? }?
--- @return table fixture
local function newAudioFixture(opts)
    opts = opts or {}

    local myPed = 1
    local function PlayerPedId() return myPed end

    local coords = { [1] = vec3(0, 0, 0) } -- my own ped, at the origin, by default
    local function GetEntityCoords(entity) return coords[entity] or vec3(0, 0, 0) end

    -- ResolveNetworkEntity: netId -> live entity handle, or nil if this
    -- client doesn't have it streamed in -- mirrors client/main.lua's real
    -- accessor's contract exactly (this file's own doc comment).
    local resolvedEntities = {}
    local resolveCalls = {}
    local function ResolveNetworkEntity(netId) resolveCalls[#resolveCalls + 1] = netId; return resolvedEntities[netId] end

    local sendNUIMessageCalls = {}
    local function SendNUIMessage(payload) sendNUIMessageCalls[#sendNUIMessageCalls + 1] = payload end

    local runner = Sandbox.newThreadRunner()
    local threadCreateCount = 0
    local function CreateThread(fn) threadCreateCount = threadCreateCount + 1; runner.CreateThread(fn) end
    local function Wait(ms) runner.Wait(ms) end

    local env = Sandbox.newEnv({
        PlayerPedId = PlayerPedId,
        GetEntityCoords = GetEntityCoords,
        ResolveNetworkEntity = ResolveNetworkEntity,
        SendNUIMessage = SendNUIMessage,
        CreateThread = CreateThread,
        Wait = Wait,
    })

    Sandbox.loadInto('../config.lua', env)

    if opts.basicBarkSounds == false then
        env.Config.Features.BasicBarkSounds = false
    end

    Sandbox.loadInto('../client/audio.lua', env)

    return {
        env = env,
        sendNUIMessageCalls = sendNUIMessageCalls,
        resolveCalls = resolveCalls,
        threadCreateCount = function() return threadCreateCount end,
        step = function() runner.step() end,
        setEntityCoords = function(entity, x, y, z) coords[entity] = vec3(x, y, z) end,
        registerEntity = function(netId, handle) resolvedEntities[netId] = handle end,
        unresolveEntity = function(netId) resolvedEntities[netId] = nil end,
        lastMessage = function() return sendNUIMessageCalls[#sendNUIMessageCalls] end,
    }
end

-- ----------------------------------------------------------------------
-- Gating -- Config.Features.BasicBarkSounds
-- ----------------------------------------------------------------------

t.test('gating: BasicBarkSounds = false -- neither PlayK9Sound, StopK9Sound, IsK9SoundActive, nor GetK9AudioMaxDistance is defined at all', function()
    local f = newAudioFixture({ basicBarkSounds = false })
    t.isNil(f.env.PlayK9Sound)
    t.isNil(f.env.StopK9Sound)
    t.isNil(f.env.IsK9SoundActive)
    t.isNil(f.env.GetK9AudioMaxDistance)
end)

t.test('gating: BasicBarkSounds = true (the real, shipped default) -- all four globals exist', function()
    local f = newAudioFixture()
    t.equals(type(f.env.PlayK9Sound), 'function')
    t.equals(type(f.env.StopK9Sound), 'function')
    t.equals(type(f.env.IsK9SoundActive), 'function')
    t.equals(type(f.env.GetK9AudioMaxDistance), 'function')
end)

t.test('GetK9AudioMaxDistance returns the real, documented 30.0m ceiling', function()
    local f = newAudioFixture()
    t.equals(f.env.GetK9AudioMaxDistance(), 30.0)
end)

-- ----------------------------------------------------------------------
-- PlayK9Sound -- input guards (reached before ResolveNetworkEntity at all)
-- ----------------------------------------------------------------------

t.test('PlayK9Sound: a non-string soundName returns nil immediately -- ResolveNetworkEntity is never even called', function()
    local f = newAudioFixture()
    local id = f.env.PlayK9Sound(1, 42)
    t.isNil(id)
    t.equals(#f.resolveCalls, 0)
    t.equals(#f.sendNUIMessageCalls, 0)
end)

t.test('PlayK9Sound: an empty-string soundName returns nil immediately, same as a non-string', function()
    local f = newAudioFixture()
    local id = f.env.PlayK9Sound(1, '')
    t.isNil(id)
    t.equals(#f.resolveCalls, 0)
end)

t.test('PlayK9Sound: ResolveNetworkEntity resolves to nil (entity not streamed in on this client) -- returns nil, sends nothing', function()
    local f = newAudioFixture()
    -- deliberately never registered netId 5
    local id = f.env.PlayK9Sound(5, 'Bark')
    t.isNil(id)
    t.equals(#f.sendNUIMessageCalls, 0)
end)

t.test('PlayK9Sound: ResolveNetworkEntity does not exist as a global at all (soft dependency) -- degrades to nil, no crash', function()
    local f = newAudioFixture()
    f.env.ResolveNetworkEntity = nil
    local ok, id = pcall(f.env.PlayK9Sound, 5, 'Bark')
    t.isTrue(ok)
    t.isNil(id)
end)

-- ----------------------------------------------------------------------
-- ToAudioFileKey -- known-name table vs. fallback transform (reached only
-- through PlayK9Sound's own `data.sound` payload field)
-- ----------------------------------------------------------------------

t.test('ToAudioFileKey: the 6 known SOUND_NAME_TO_FILE_KEY entries map exactly as documented', function()
    local f = newAudioFixture()
    f.registerEntity(1, 2)
    -- DoorScratch/DoorNudge added alongside client/movement.lua's fix
    -- routing its door-audio cues (previously a direct, dead
    -- PlaySoundFromEntity call only) through PlaySoundOnNetworkEntity ->
    -- PlayK9Sound, same as every other sound cue in this resource.
    local expected = {
        Bark = 'bark',
        Bark_Alert = 'bark_alert',
        Bark_Aggressive = 'bark_aggressive',
        Bark_Calm = 'bark_calm',
        DoorScratch = 'door_scratch',
        DoorNudge = 'door_nudge',
    }
    for soundName, fileKey in pairs(expected) do
        f.env.PlayK9Sound(1, soundName)
        t.equals(f.lastMessage().data.sound, fileKey, soundName)
    end
end)

t.test('ToAudioFileKey: an unknown soundName falls back to a lowercased, underscore-joined transform', function()
    local f = newAudioFixture()
    f.registerEntity(1, 2)
    f.env.PlayK9Sound(1, 'Growl Ambient Loop')
    t.equals(f.lastMessage().data.sound, 'growl_ambient_loop')
end)

-- ----------------------------------------------------------------------
-- Falloff math -- DistanceToGain/GainToEntity, reached via PlayK9Sound's
-- `data.gain` payload field (both are `local`, per this file's own
-- convention for testing a gated local through its real entry point).
-- ----------------------------------------------------------------------

t.test('gain: zero distance from the listener -- full gain (1.0)', function()
    local f = newAudioFixture()
    f.setEntityCoords(1, 0, 0, 0) -- my own ped
    f.registerEntity(10, 2)
    f.setEntityCoords(2, 0, 0, 0) -- sound source at the SAME spot
    f.env.PlayK9Sound(10, 'Bark')
    t.equals(f.lastMessage().data.gain, 1.0)
end)

t.test('gain: exactly at AUDIO_MAX_DISTANCE (30m) -- zero gain, not a small positive residue', function()
    local f = newAudioFixture()
    f.registerEntity(10, 2)
    f.setEntityCoords(2, 30, 0, 0)
    f.env.PlayK9Sound(10, 'Bark')
    t.equals(f.lastMessage().data.gain, 0.0)
end)

t.test('gain: beyond AUDIO_MAX_DISTANCE -- clamped to zero, not negative', function()
    local f = newAudioFixture()
    f.registerEntity(10, 2)
    f.setEntityCoords(2, 90, 0, 0)
    f.env.PlayK9Sound(10, 'Bark')
    t.equals(f.lastMessage().data.gain, 0.0)
end)

t.test('gain: linear midpoint -- 15m of 30m ceiling is exactly 0.5', function()
    local f = newAudioFixture()
    f.registerEntity(10, 2)
    f.setEntityCoords(2, 15, 0, 0)
    f.env.PlayK9Sound(10, 'Bark')
    t.equals(f.lastMessage().data.gain, 0.5)
end)

-- ----------------------------------------------------------------------
-- One-shot playback (opts omitted, or opts.loop ~= true)
-- ----------------------------------------------------------------------

t.test('one-shot: opts omitted entirely -- loop = false in the payload, an id is still returned, no thread is created, and IsK9SoundActive is false for it', function()
    local f = newAudioFixture()
    f.registerEntity(10, 2)
    local id = f.env.PlayK9Sound(10, 'Bark')
    t.isNotNil(id)
    t.equals(f.lastMessage().action, 'audio:play')
    t.equals(f.lastMessage().data.loop, false)
    t.equals(f.threadCreateCount(), 0)
    t.isFalse(f.env.IsK9SoundActive(id))
end)

t.test('one-shot: opts.loop = false explicitly -- same as omitted', function()
    local f = newAudioFixture()
    f.registerEntity(10, 2)
    local id = f.env.PlayK9Sound(10, 'Bark', { loop = false })
    t.isNotNil(id)
    t.equals(f.threadCreateCount(), 0)
end)

t.test('ids are session-local and monotonically increasing across separate PlayK9Sound calls', function()
    local f = newAudioFixture()
    f.registerEntity(10, 2)
    local id1 = f.env.PlayK9Sound(10, 'Bark')
    local id2 = f.env.PlayK9Sound(10, 'Bark')
    t.equals(id2, id1 + 1)
end)

-- ----------------------------------------------------------------------
-- Loop playback (opts.loop = true) -- thread lifecycle
-- ----------------------------------------------------------------------

t.test('loop: starts exactly one thread, tracks the id as active, and the FIRST payload already carries loop = true', function()
    local f = newAudioFixture()
    f.registerEntity(10, 2)
    local id = f.env.PlayK9Sound(10, 'Growl_Ambient', { loop = true })
    t.equals(f.threadCreateCount(), 1)
    t.isTrue(f.env.IsK9SoundActive(id))
    t.equals(f.lastMessage().data.loop, true)
end)

t.test('loop: the poll thread re-sends gain as the source entity moves, on its own AUDIO_GAIN_POLL_MS (500ms) cadence', function()
    local f = newAudioFixture()
    f.registerEntity(10, 2)
    f.setEntityCoords(2, 0, 0, 0)
    local id = f.env.PlayK9Sound(10, 'Growl_Ambient', { loop = true }) -- gain 1.0 at t=0
    f.step() -- prime (see header) -- reaches the first Wait(500), no poll pass yet

    f.setEntityCoords(2, 15, 0, 0) -- move the source to half the falloff ceiling
    f.step() -- one gain-poll pass
    local msg = f.lastMessage()
    t.equals(msg.action, 'audio:setGain')
    t.equals(msg.data.id, id)
    t.equals(msg.data.gain, 0.5)
end)

t.test('loop: entity streams out mid-loop (ResolveNetworkEntity starts returning nil) -- the thread self-heals: sends audio:stop, untracks the id, and does not poll again', function()
    local f = newAudioFixture()
    f.registerEntity(10, 2)
    local id = f.env.PlayK9Sound(10, 'Growl_Ambient', { loop = true })
    f.step() -- prime

    f.unresolveEntity(10) -- the K9 streamed out of this client's range
    f.step() -- one pass: detects the loss, stops, breaks

    t.equals(f.lastMessage().action, 'audio:stop')
    t.equals(f.lastMessage().data.id, id)
    t.isFalse(f.env.IsK9SoundActive(id))

    local countBefore = #f.sendNUIMessageCalls
    f.step() -- the coroutine is already dead -- must be a harmless no-op, not an error
    t.equals(#f.sendNUIMessageCalls, countBefore, 'a dead loop thread must never send anything further')
end)

t.test('loop: StopK9Sound() called manually while active -- sends audio:stop immediately, untracks the id, and the thread\'s own final safety-net check does not send a SECOND audio:stop', function()
    local f = newAudioFixture()
    f.registerEntity(10, 2)
    local id = f.env.PlayK9Sound(10, 'Growl_Ambient', { loop = true })
    f.step() -- prime

    f.env.StopK9Sound(id)
    t.equals(f.lastMessage().action, 'audio:stop')
    t.isFalse(f.env.IsK9SoundActive(id))
    local stopMessageCountAfterManualStop = 0
    for _, m in ipairs(f.sendNUIMessageCalls) do
        if m.action == 'audio:stop' and m.data.id == id then stopMessageCountAfterManualStop = stopMessageCountAfterManualStop + 1 end
    end
    t.equals(stopMessageCountAfterManualStop, 1)

    f.step() -- the thread notices activeLoops[id] is already gone and breaks -- must NOT send a second audio:stop
    local secondStopCount = 0
    for _, m in ipairs(f.sendNUIMessageCalls) do
        if m.action == 'audio:stop' and m.data.id == id then secondStopCount = secondStopCount + 1 end
    end
    t.equals(secondStopCount, 1, 'StopK9Sound must never be double-sent for the same id')
end)

t.test('loop: StopK9Sound on an id that was never a tracked loop (a one-shot id, or an already-stopped id) is a harmless no-op -- still sends audio:stop, but never errors', function()
    local f = newAudioFixture()
    f.registerEntity(10, 2)
    local oneShotId = f.env.PlayK9Sound(10, 'Bark') -- one-shot, never tracked
    local ok = pcall(f.env.StopK9Sound, oneShotId)
    t.isTrue(ok)
    t.equals(f.lastMessage().action, 'audio:stop')
end)

t.test('loop: AUDIO_MAX_LOOP_MS (60s) safety ceiling force-stops a loop nobody ever called StopK9Sound for -- exactly at the 120th 500ms poll, not before and not never', function()
    local f = newAudioFixture()
    f.registerEntity(10, 2)
    local id = f.env.PlayK9Sound(10, 'Growl_Ambient', { loop = true })
    f.step() -- prime

    for _ = 1, 119 do
        f.step()
    end
    t.isTrue(f.env.IsK9SoundActive(id), 'must still be active just before the ceiling (119 * 500ms = 59500ms < 60000ms)')

    f.step() -- the 120th pass: elapsed reaches 60000ms -- while-condition now false -> falls out, self-stops
    t.isFalse(f.env.IsK9SoundActive(id))
    t.equals(f.lastMessage().action, 'audio:stop')
    t.equals(f.lastMessage().data.id, id)
end)

t.test('loop: two concurrent loops get independent ids, independent threads, and stopping one never touches the other', function()
    local f = newAudioFixture()
    f.registerEntity(10, 2)
    f.registerEntity(11, 3)
    local idA = f.env.PlayK9Sound(10, 'Growl_Ambient', { loop = true })
    local idB = f.env.PlayK9Sound(11, 'Growl_Ambient', { loop = true })
    t.equals(f.threadCreateCount(), 2)
    t.isTrue(idA ~= idB)

    f.env.StopK9Sound(idA)
    t.isFalse(f.env.IsK9SoundActive(idA))
    t.isTrue(f.env.IsK9SoundActive(idB), 'stopping loop A must never affect loop B\'s independent tracking')
end)


-- EVERY CONFIGURED ALERT TIER MUST RESOLVE TO A SOUND FILE THAT EXISTS.
--
-- This is a drift guard, and it exists because the drift already happened:
-- Config.ContrabandAlertTiers ships 'whine' and 'aggressive_bark', neither
-- was in the mapping table, and 'aggressive_bark' is the same two words as
-- the shipped bark_aggressive.ogg in the opposite order -- so the
-- best-effort lower-casing fallback produced a filename that does not
-- exist. The bystander cue for a contraband find had never played on a
-- stock install, silently, because an unrecognised sound name is a no-op
-- rather than an error.
--
-- Reads BOTH real files rather than restating either: the tier names come
-- from config.lua, the shipped assets from the sounds directory. Adding a
-- tier without a sound, or renaming a sound out from under a tier, fails
-- here instead of going quiet in game.
t.test('CONTRABAND ALERT AUDIO: every Config.ContrabandAlertTiers alert name resolves to a sound file that actually ships', function()
    local configHandle = assert(io.open('../config.lua', 'r'))
    local configText = configHandle:read('a')
    configHandle:close()

    local tiers = {}
    for alertName in configText:gmatch("alert%s*=%s*'([%w_]+)'") do
        tiers[#tiers + 1] = alertName
    end
    t.isTrue(#tiers > 0, 'sanity: this guard must actually find the configured alert tiers, or it proves nothing')

    local audioHandle = assert(io.open('../client/audio.lua', 'r'))
    local audioText = audioHandle:read('a')
    audioHandle:close()

    for _, alertName in ipairs(tiers) do
        if alertName ~= 'clean' then -- 'clean' is deliberately silent; see audio.lua's own note
            local mapped = audioText:match("%['" .. alertName .. "'%]%s*=%s*'([%w_]+)'")
            t.isNotNil(mapped, ('alert tier %q has no entry in client/audio.lua SOUND_NAME_TO_FILE_KEY -- it would fall through to a best-effort filename and silently play nothing'):format(alertName))
            if mapped then
                local f = io.open('../html/sounds/' .. mapped .. '.ogg', 'r')
                t.isNotNil(f, ('alert tier %q maps to %q but html/sounds/%s.ogg does not exist -- the cue would be silent in game with no error anywhere'):format(alertName, mapped, mapped))
                if f then f:close() end
            end
        end
    end
end)

os.exit(t.summary())
