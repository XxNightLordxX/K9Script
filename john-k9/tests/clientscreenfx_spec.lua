--[[
    tests/clientscreenfx_spec.lua

    Direct, black-box tests of client/screenfx.lua against the REAL,
    unmodified production file: the Config.Features.ContrabandScreenFX
    file-scope gate (which also gates registration of the
    'john-k9:client:applyContrabandScreenFx' RegisterNetEvent AND the
    onResourceStop safety net -- neither exists at all while the flag is
    off), the `source ~= 65535` origin guard (this file, unlike
    tests/clientvision_spec.lua's subject, IS one of the files
    DEVELOPER_REFERENCE.md's D3 write-up -- formerly DECISIONS_NEEDED.md --
    names as actually reachable via a
    forged local trigger), the modifierName/durationMs config-vs-payload-vs-
    fallback precedence, the SCREENFX_MIN/MAX_DURATION_MS clamp (both
    directions), the maintenance thread's own-death force-clear, its natural
    expiry force-clear, its retrigger-extends-not-stacks behavior (never a
    second competing thread), and the onResourceStop force-clear.

    THREAD STEPPING NOTE: the maintenance thread's FIRST statement is the
    `while` loop's own condition check, and `Wait(SCREENFX_POLL_MS)` is the
    FIRST statement INSIDE that loop -- matching DEVELOPER_REFERENCE.md's own
    generic stepping note exactly (same shape as
    tests/clientproximityaudio_spec.lua's thread, unlike
    tests/clientvision_spec.lua's/tests/clienthud_spec.lua's/
    tests/clientaudio_spec.lua's, which all deviate from it for their own,
    different reasons). So step() #1 is a pure prime (yields at the very
    first Wait, no death/expiry check yet); step() #2 onward is exactly one
    poll pass per call.

    STUBBING EFFORT: every native here is a trivial capturing/controllable
    stub (GetGameTimer, IsEntityDead, PlayerPedId, SetTimecycleModifier,
    ClearTimecycleModifier, GetCurrentResourceName). Nothing here needed
    disproportionate stubbing.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

-- ----------------------------------------------------------------------
-- Sandbox setup
-- ----------------------------------------------------------------------

--- @param opts { contrabandScreenFX: boolean?, modifierName: string?, durationMs: number? }?
--- @return table fixture
local function newScreenFxFixture(opts)
    opts = opts or {}

    local fakeNow = 0
    local function GetGameTimer() return fakeNow end

    local myPed = 1
    local function PlayerPedId() return myPed end
    local isDead = false
    local function IsEntityDead(_ped) return isDead end

    -- PER-PERSON BLOCK (client/featureblocks.lua, REQUESTED) -- stubbed,
    -- same "controllable stand-in" convention as every other cross-file
    -- global in this fixture. Soft dependency: only added to `env` when
    -- `opts.featureBlocksAvailable` is not explicitly false.
    local featureBlocksAvailable = opts.featureBlocksAvailable
    if featureBlocksAvailable == nil then featureBlocksAvailable = true end
    local blockedFeatures = opts.blockedFeatures or {}
    local function IsK9FeatureBlocked(name) return blockedFeatures[name] == true end

    local setModifierCalls = {}
    local function SetTimecycleModifier(name) setModifierCalls[#setModifierCalls + 1] = name end
    local clearModifierCallCount = 0
    local function ClearTimecycleModifier() clearModifierCallCount = clearModifierCallCount + 1 end

    local RESOURCE_NAME = 'john-k9'
    local function GetCurrentResourceName() return RESOURCE_NAME end

    local runner = Sandbox.newThreadRunner()
    local threadCreateCount = 0
    local function CreateThread(fn) threadCreateCount = threadCreateCount + 1; runner.CreateThread(fn) end
    local function Wait(ms) runner.Wait(ms) end

    local netEventHandlers = {}
    local function RegisterNetEvent(eventName, handler) netEventHandlers[eventName] = handler end
    local eventHandlers = {}
    local function AddEventHandler(eventName, handler)
        eventHandlers[eventName] = eventHandlers[eventName] or {}
        eventHandlers[eventName][#eventHandlers[eventName] + 1] = handler
    end

    local env = Sandbox.newEnv({
        GetGameTimer = GetGameTimer,
        PlayerPedId = PlayerPedId,
        IsEntityDead = IsEntityDead,
        SetTimecycleModifier = SetTimecycleModifier,
        ClearTimecycleModifier = ClearTimecycleModifier,
        GetCurrentResourceName = GetCurrentResourceName,
        CreateThread = CreateThread,
        Wait = Wait,
        RegisterNetEvent = RegisterNetEvent,
        AddEventHandler = AddEventHandler,
    })
    if featureBlocksAvailable then
        env.IsK9FeatureBlocked = IsK9FeatureBlocked
    end

    Sandbox.loadInto('../config.lua', env)

    if opts.contrabandScreenFX == false then
        env.Config.Features.ContrabandScreenFX = false
    end
    if opts.modifierName ~= nil then
        env.Config.ContrabandScreenFX.modifierName = opts.modifierName
    end
    if opts.durationMs ~= nil then
        env.Config.ContrabandScreenFX.durationMs = opts.durationMs
    end
    if opts.removeContrabandConfig then
        env.Config.ContrabandScreenFX = nil
    end

    Sandbox.loadInto('../client/screenfx.lua', env)

    return {
        env = env,
        Config = env.Config,
        setModifierCalls = setModifierCalls,
        clearModifierCallCount = function() return clearModifierCallCount end,
        threadCreateCount = function() return threadCreateCount end,
        step = function() runner.step() end,
        advance = function(ms) fakeNow = fakeNow + ms end,
        setDead = function(v) isDead = v end,
        resourceName = RESOURCE_NAME,
        hasEventHandler = function() return netEventHandlers['john-k9:client:applyContrabandScreenFx'] ~= nil end,
        fireApplyScreenFx = function(sourceValue, durationMs)
            local handler = assert(netEventHandlers['john-k9:client:applyContrabandScreenFx'],
                'client/screenfx.lua did not register a john-k9:client:applyContrabandScreenFx handler')
            env.source = sourceValue
            handler(durationMs)
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

t.test('gating: ContrabandScreenFX = false -- no event handler, no onResourceStop handler, no thread ever -- a hostile client cannot reach ANY of this file\'s logic', function()
    local f = newScreenFxFixture({ contrabandScreenFX = false })
    t.isFalse(f.hasEventHandler())
    t.equals(f.onResourceStopHandlerCount(), 0)
    t.equals(f.threadCreateCount(), 0)
end)

t.test('gating: ContrabandScreenFX = true (real shipped default) -- the event handler and onResourceStop handler both exist', function()
    local f = newScreenFxFixture()
    t.isTrue(f.hasEventHandler())
    t.equals(f.onResourceStopHandlerCount(), 1)
end)

-- ----------------------------------------------------------------------
-- Origin guard -- THIS file IS on DEVELOPER_REFERENCE.md's D3 list
-- (formerly DECISIONS_NEEDED.md) (unlike
-- tests/clientvision_spec.lua's subject -- see that file's own header for
-- the contrast).
-- ----------------------------------------------------------------------

t.test('origin guard: source ~= 65535 (a forged local TriggerEvent self-invocation) is rejected -- SetTimecycleModifier is never called, no thread starts', function()
    local f = newScreenFxFixture()
    f.fireApplyScreenFx(1234, 3000)
    t.equals(#f.setModifierCalls, 0)
    t.equals(f.threadCreateCount(), 0)
end)

t.test('origin guard: source == 65535 (a genuine server-sent trigger) is processed normally', function()
    local f = newScreenFxFixture()
    f.fireApplyScreenFx(65535, 3000)
    t.equals(#f.setModifierCalls, 1)
    t.equals(f.threadCreateCount(), 1)
end)

-- ----------------------------------------------------------------------
-- modifierName precedence -- event payload has none (durationMs is the only
-- argument; modifierName always comes from Config/fallback, never the
-- event payload) -- config vs. the file's own fallback constant.
-- ----------------------------------------------------------------------

t.test('modifierName: uses the real, shipped Config.ContrabandScreenFX.modifierName ("drug_wobbly")', function()
    local f = newScreenFxFixture()
    f.fireApplyScreenFx(65535, 3000)
    t.equals(f.setModifierCalls[1], 'drug_wobbly')
end)

t.test('modifierName: falls back to the file\'s own FALLBACK_MODIFIER_NAME when Config.ContrabandScreenFX.modifierName is missing/blank', function()
    local f = newScreenFxFixture({ modifierName = '' })
    f.fireApplyScreenFx(65535, 3000)
    t.equals(f.setModifierCalls[1], 'drug_wobbly', 'the fallback constant happens to equal the real shipped config value, but this proves the FALLBACK path specifically, not just a passthrough')
end)

t.test('modifierName: falls back when Config.ContrabandScreenFX itself is missing entirely', function()
    local f = newScreenFxFixture({ removeContrabandConfig = true })
    local ok = pcall(f.fireApplyScreenFx, 65535, 3000)
    t.isTrue(ok)
    t.equals(f.setModifierCalls[1], 'drug_wobbly')
end)

t.test('modifierName: a non-string Config value is rejected in favor of the fallback', function()
    local f = newScreenFxFixture()
    f.Config.ContrabandScreenFX.modifierName = 42
    f.fireApplyScreenFx(65535, 3000)
    t.equals(f.setModifierCalls[1], 'drug_wobbly')
end)

t.test('modifierName: a custom, real config value is honored verbatim', function()
    local f = newScreenFxFixture({ modifierName = 'custom_modifier' })
    f.fireApplyScreenFx(65535, 3000)
    t.equals(f.setModifierCalls[1], 'custom_modifier')
end)

-- ----------------------------------------------------------------------
-- durationMs precedence: event payload > Config > fallback constant, then
-- clamped to [SCREENFX_MIN_DURATION_MS, SCREENFX_MAX_DURATION_MS] regardless
-- of source.
-- ----------------------------------------------------------------------

t.test('durationMs: the event payload\'s own value wins over Config when both are present and within range', function()
    local f = newScreenFxFixture({ durationMs = 2000 })
    f.fireApplyScreenFx(65535, 2800)
    f.step() -- prime
    -- proven indirectly: still active just before 2800ms, expired at/after it
    f.advance(2700)
    f.step()
    t.equals(f.clearModifierCallCount(), 0, 'must still be active at 2700ms if the payload\'s 2800ms, not Config\'s 2000ms, was honored')
    f.advance(200)
    f.step()
    t.equals(f.clearModifierCallCount(), 1)
end)

t.test('durationMs: payload is not a number -- falls back to Config.ContrabandScreenFX.durationMs', function()
    local f = newScreenFxFixture({ durationMs = 1200 })
    f.fireApplyScreenFx(65535, 'not-a-number')
    f.step()
    f.advance(1100)
    f.step()
    t.equals(f.clearModifierCallCount(), 0)
    f.advance(200)
    f.step()
    t.equals(f.clearModifierCallCount(), 1)
end)

t.test('durationMs: neither payload nor Config resolve -- falls back to FALLBACK_DURATION_MS (3000ms)', function()
    local f = newScreenFxFixture({ removeContrabandConfig = true })
    f.fireApplyScreenFx(65535, nil)
    f.step()
    f.advance(2900)
    f.step()
    t.equals(f.clearModifierCallCount(), 0)
    f.advance(200)
    f.step()
    t.equals(f.clearModifierCallCount(), 1)
end)

t.test('durationMs clamp: a requested duration ABOVE SCREENFX_MAX_DURATION_MS (4000ms) is capped, never honored past it', function()
    local f = newScreenFxFixture()
    f.fireApplyScreenFx(65535, 999999)
    f.step()
    f.advance(3999)
    f.step()
    t.equals(f.clearModifierCallCount(), 0)
    f.advance(2) -- now past the 4000ms ceiling regardless of the 999999ms request
    f.step()
    t.equals(f.clearModifierCallCount(), 1, 'the effective duration must never exceed SCREENFX_MAX_DURATION_MS no matter what was requested')
end)

t.test('durationMs clamp: a requested duration BELOW SCREENFX_MIN_DURATION_MS (500ms, including 0 or negative) is floored, never flashing on-and-off instantly', function()
    local f = newScreenFxFixture()
    f.fireApplyScreenFx(65535, 0)
    f.step()
    f.advance(499)
    f.step()
    t.equals(f.clearModifierCallCount(), 0, 'even a requested 0ms duration must hold for at least SCREENFX_MIN_DURATION_MS')
    f.advance(2)
    f.step()
    t.equals(f.clearModifierCallCount(), 1)
end)

t.test('durationMs clamp: a negative requested duration is treated the same as 0 -- floored to SCREENFX_MIN_DURATION_MS', function()
    local f = newScreenFxFixture()
    f.fireApplyScreenFx(65535, -5000)
    f.step()
    f.advance(499)
    f.step()
    t.equals(f.clearModifierCallCount(), 0)
end)

-- ----------------------------------------------------------------------
-- Maintenance thread -- death, natural expiry, retrigger-extends, and the
-- already-running guard.
-- ----------------------------------------------------------------------

t.test('maintenance thread: does not exist at all before the event ever fires', function()
    local f = newScreenFxFixture()
    t.equals(f.threadCreateCount(), 0)
end)

t.test('maintenance thread: own death force-clears the effect promptly, before the full requested duration elapses', function()
    local f = newScreenFxFixture()
    f.fireApplyScreenFx(65535, 4000)
    f.step() -- prime

    f.setDead(true)
    f.advance(250) -- well before 4000ms
    f.step() -- one poll pass -- detects death, clears immediately
    t.equals(f.clearModifierCallCount(), 1)
end)

t.test('maintenance thread: natural expiry clears the effect once GetGameTimer() passes screenFxExpiresAt, with no death involved', function()
    local f = newScreenFxFixture()
    f.fireApplyScreenFx(65535, 1000)
    f.step()
    f.advance(999)
    f.step()
    t.equals(f.clearModifierCallCount(), 0)
    f.advance(2)
    f.step()
    t.equals(f.clearModifierCallCount(), 1)
end)

t.test('retrigger while already active EXTENDS the hold time rather than starting a second, competing thread', function()
    local f = newScreenFxFixture()
    f.fireApplyScreenFx(65535, 1000) -- expires at t=1000
    t.equals(f.threadCreateCount(), 1)
    f.step() -- prime

    f.advance(800)
    f.fireApplyScreenFx(65535, 1000) -- retrigger -- extends to t=800+1000=1800, must NOT create a 2nd thread
    t.equals(f.threadCreateCount(), 1, 'a retrigger while the maintenance thread is still alive must never start a second, competing thread')

    f.advance(150) -- t=950 -- would already be expired under the FIRST trigger's own 1000ms deadline
    f.step()
    t.equals(f.clearModifierCallCount(), 0, 'the retrigger must have genuinely extended the hold -- the old deadline alone must not have cleared it')

    f.advance(900) -- t=1850 -- now past the retrigger's own 1800ms deadline
    f.step()
    t.equals(f.clearModifierCallCount(), 1)
end)

t.test('a NEW trigger after the previous effect fully cleared starts a genuinely NEW thread', function()
    local f = newScreenFxFixture()
    f.fireApplyScreenFx(65535, 1000)
    f.step()
    f.advance(1000)
    f.step() -- clears, thread exits
    t.equals(f.clearModifierCallCount(), 1)

    f.fireApplyScreenFx(65535, 1000)
    t.equals(f.threadCreateCount(), 2, 'once the previous thread has genuinely exited, a fresh trigger must be able to start a new one')
end)

-- ----------------------------------------------------------------------
-- onResourceStop
-- ----------------------------------------------------------------------

t.test('onResourceStop: a different resource stopping is ignored', function()
    local f = newScreenFxFixture()
    f.fireApplyScreenFx(65535, 3000)
    f.fireResourceStop('some_other_resource')
    t.equals(f.clearModifierCallCount(), 0)
end)

t.test('onResourceStop: this resource stopping force-clears the effect unconditionally', function()
    local f = newScreenFxFixture()
    f.fireApplyScreenFx(65535, 3000)
    f.fireResourceStop(f.resourceName)
    t.equals(f.clearModifierCallCount(), 1)
end)

t.test('onResourceStop: a harmless no-op when the effect was never triggered at all this session', function()
    local f = newScreenFxFixture()
    local ok = pcall(f.fireResourceStop, f.resourceName)
    t.isTrue(ok)
    t.equals(f.clearModifierCallCount(), 1, 'ClearTimecycleModifier is called unconditionally on stop regardless of whether the effect was ever actually active -- an idempotent, harmless no-op per this file\'s own comment')
end)

-- ----------------------------------------------------------------------
-- PER-PERSON BLOCK (client/featureblocks.lua, REQUESTED) -- checked as
-- this file's own header states: at the ONE acting point this feature has
-- (the event handler itself), before the effect is ever applied. No
-- "already active, force off early" concern -- this is a short,
-- self-expiring one-shot, never a toggle the player holds (see this
-- file's own production-code comment on that call site).
-- ----------------------------------------------------------------------

t.test('per-person block: ContrabandScreenFX blocked -- the effect is never applied, no thread starts', function()
    local f = newScreenFxFixture()
    f.setBlocked('ContrabandScreenFX', true)
    f.fireApplyScreenFx(65535, 3000)
    t.equals(#f.setModifierCalls, 0)
    t.equals(f.threadCreateCount(), 0)
end)

t.test('per-person block: a block on a DIFFERENT feature name never affects ContrabandScreenFX', function()
    local f = newScreenFxFixture()
    f.setBlocked('NightVision', true)
    f.fireApplyScreenFx(65535, 3000)
    t.equals(#f.setModifierCalls, 1)
end)

t.test('fails OPEN: client/featureblocks.lua not loaded (IsK9FeatureBlocked undefined) -- the effect applies exactly as before this pass', function()
    local f = newScreenFxFixture({ featureBlocksAvailable = false })
    t.isNil(f.env.IsK9FeatureBlocked)
    f.fireApplyScreenFx(65535, 3000)
    t.equals(#f.setModifierCalls, 1, 'an unknown block state must never suppress this feature -- it must fail OPEN')
end)

os.exit(t.summary())
