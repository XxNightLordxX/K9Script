--[[
    tests/clientbreed_spec.lua

    Direct, black-box tests of client/movement.lua's BREED MOVE-RATE WEIGHT
    addition (DEVELOPER_REFERENCE.md Part A §4) against the REAL, unmodified
    production file -- a NEW, separate spec file per this task's own
    instruction, deliberately NOT folded into the existing
    tests/clientmovement_spec.lua (owned by another agent this session; see
    scratchpad/COORDINATION.md's ownership map).

    SCOPE: the `K9MoveRateModifiers.breed` slot and the
    `K9BreedSpeedMultiplierByModelHash` table it is read from -- both added
    this pass. Every OTHER RecomputeK9MoveRate() behavior (the clamp range,
    the other four modifier keys, the three onResourceStop handlers, the
    leash/camera mechanics) is already covered by tests/clientmovement_spec.lua
    and is deliberately NOT re-tested here.

    THE LOAD-BEARING REGRESSION THIS FILE LOCKS IN: today's real,
    unmodified config.lua has NO `speedMultiplier` field on any Config.Peds
    entry, and tests/clientmovement_spec.lua's own fixture Config has NO
    `Peds` field AT ALL. Both must load this production file WITHOUT
    erroring (a bare `ipairs(Config.Peds)` at file-load time would throw
    "attempt to iterate a nil value" against either shape) -- see the
    "loads cleanly with no Config.Peds at all" case below, which is the
    single most important test in this file precisely because a failure
    here would have redenned the ENTIRE suite's tests/clientmovement_spec.lua
    too (both spec files load the same production file).

    FIXTURE STYLE mirrors tests/clientmovement_spec.lua's own
    newMovementFixture() exactly (same native/global stub set), with one
    addition: `pedsConfig` lets each test supply its own Config.Peds shape.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

-- ----------------------------------------------------------------------
-- GetHashKey stand-in -- IDENTICAL formula to tests/clientmovement_spec.lua
-- and main_spec.lua/kennel_spec.lua's own copies. Must be deterministic
-- (same name always hashes to the same value) but does not need to match
-- the real native's actual hash algorithm -- this file never compares
-- against a real GetHashKey output, only against ITS OWN calls to this
-- same stand-in.
-- ----------------------------------------------------------------------
local function GetHashKey(name)
    local hash = 0
    for i = 1, #name do
        hash = (hash * 31 + name:byte(i)) % 2147483647
    end
    return hash
end

local RESOURCE_NAME = 'john-k9'

--- Builds one fresh, independent sandbox loading the real client/movement.lua.
--- @param pedsConfig table? -- becomes Config.Peds; nil/omitted reproduces
---   today's real "no Peds table at all" and "Peds with no speedMultiplier
---   field" shapes depending on what the caller passes.
--- @return table fixture
local function newFixture(pedsConfig)
    local isOwnModelK9 = true
    local function IsOwnModelK9() return isOwnModelK9 end
    local function CanShowK9UI() return true end
    local function DenyK9UIAccess() end

    -- ANY-PED MOVE-RATE FIX (coder-frontend, this pass): RecomputeK9MoveRate()'s
    -- own gate is now `IsOwnModelK9() or HasK9Access()`, not IsOwnModelK9()
    -- alone -- see client/movement.lua's own "SCOPE, CORRECTED" header
    -- comment on K9MoveRateModifiers for the full writeup. HasK9Access() is a
    -- REAL cross-file global from client/main.lua (called unconditionally,
    -- no soft-dependency guard, exactly like IsOwnModelK9()/CanShowK9UI()
    -- above from that same always-loaded foundational file) -- this sandbox
    -- never loads client/main.lua for real, so it needs its own controllable
    -- stand-in exactly like those two already have. Defaults to false, which
    -- reproduces this file's pre-existing behavior exactly (every test here
    -- that flips IsOwnModelK9() to false still expects a full reset -- this
    -- file's own scope is the BREED slot, not this gate's widening, so no
    -- test below exercises HasK9Access() = true).
    local hasK9Access = false
    local function HasK9Access() return hasK9Access end

    local function TriggerServerEvent() end
    local lib = { notify = function() end, alertDialog = function() return 'confirm' end }

    local pedHandle = 1
    local existingEntities = { [1] = true }
    local entityModels = {}
    local function PlayerPedId() return pedHandle end
    local function DoesEntityExist(entity) return existingEntities[entity] == true end
    local function GetEntityModel(entity) return entityModels[entity] end

    local setMoveRateCalls = {}
    local function SetPedMoveRateOverride(ped, rate)
        setMoveRateCalls[#setMoveRateCalls + 1] = { ped = ped, rate = rate }
    end

    local function SetFollowPedCamViewMode() end
    local function GetCurrentResourceName() return RESOURCE_NAME end
    local function GetPlayerFromServerId() return -1 end
    local function GetPlayerName() return 'Player#0' end

    local function RegisterCommand() end
    local function RegisterKeyMapping() end
    local function AddEventHandler() end
    local function RegisterNetEvent() end
    local function CreateThread() end

    local Config = { Features = { AgilityBasicJump = true }, Peds = pedsConfig }

    local env = Sandbox.newEnv({
        GetHashKey = GetHashKey,
        Config = Config,
        RegisterCommand = RegisterCommand,
        RegisterKeyMapping = RegisterKeyMapping,
        AddEventHandler = AddEventHandler,
        RegisterNetEvent = RegisterNetEvent,
        CreateThread = CreateThread,
        IsOwnModelK9 = IsOwnModelK9,
        CanShowK9UI = CanShowK9UI,
        DenyK9UIAccess = DenyK9UIAccess,
        HasK9Access = HasK9Access,
        TriggerServerEvent = TriggerServerEvent,
        lib = lib,
        PlayerPedId = PlayerPedId,
        DoesEntityExist = DoesEntityExist,
        GetEntityModel = GetEntityModel,
        SetPedMoveRateOverride = SetPedMoveRateOverride,
        SetFollowPedCamViewMode = SetFollowPedCamViewMode,
        GetCurrentResourceName = GetCurrentResourceName,
        GetPlayerFromServerId = GetPlayerFromServerId,
        GetPlayerName = GetPlayerName,
    })

    Sandbox.loadInto('../client/movement.lua', env)

    return {
        env = env,
        setIsOwnModelK9 = function(v) isOwnModelK9 = v end,
        setHasK9Access = function(v) hasK9Access = v end,
        setModel = function(hash) entityModels[pedHandle] = hash end,
        lastMoveRate = function() return setMoveRateCalls[#setMoveRateCalls] end,
        moveRateCallCount = function() return #setMoveRateCalls end,
    }
end

-- ----------------------------------------------------------------------
-- THE LOAD-BEARING REGRESSION
-- ----------------------------------------------------------------------

t.test('loads cleanly with Config.Peds entirely absent (nil) -- the exact shape tests/clientmovement_spec.lua\'s own fixture Config already uses -- and breed defaults to a true 1.0 no-op', function()
    local f = newFixture(nil)
    f.setModel(GetHashKey('a_c_shepherd'))
    f.env.RecomputeK9MoveRate()
    t.equals(f.lastMoveRate().rate, 1.0, 'no Config.Peds at all must never error, and must never bias move rate away from neutral')
end)

t.test('loads cleanly with Config.Peds present but NO speedMultiplier field on any entry -- today\'s real, unmodified config.lua shape -- and breed defaults to 1.0', function()
    local f = newFixture({
        { model = 'a_c_shepherd' },
        { model = 'a_c_rottweiler' },
        { model = 'a_c_husky' },
        { model = 'a_c_chop' },
    })
    f.setModel(GetHashKey('a_c_husky'))
    f.env.RecomputeK9MoveRate()
    t.equals(f.lastMoveRate().rate, 1.0, 'a Config.Peds entry with no speedMultiplier field must resolve to the neutral 1.0 default, not nil/0/an error')
end)

-- ----------------------------------------------------------------------
-- REAL DIFFERENTIATION
-- ----------------------------------------------------------------------

local function pedsWithMultipliers()
    return {
        { model = 'a_c_shepherd', speedMultiplier = 1.00 },
        { model = 'a_c_rottweiler', speedMultiplier = 0.98 },
        { model = 'a_c_husky', speedMultiplier = 1.03 },
        { model = 'a_c_chop', speedMultiplier = 1.00 },
    }
end

t.test('a configured speedMultiplier is applied verbatim as the sole modifier (every other slot at its 1.0 default)', function()
    local f = newFixture(pedsWithMultipliers())
    f.setModel(GetHashKey('a_c_husky'))
    f.env.RecomputeK9MoveRate()
    t.equals(f.lastMoveRate().rate, 1.03, 'Husky speedMultiplier (1.03) must reach SetPedMoveRateOverride unchanged when nothing else is contributing')
end)

t.test('a DIFFERENT configured breed applies ITS OWN multiplier, not a cached/stale value from a previous model', function()
    local f = newFixture(pedsWithMultipliers())
    f.setModel(GetHashKey('a_c_husky'))
    f.env.RecomputeK9MoveRate()
    t.equals(f.lastMoveRate().rate, 1.03)

    f.setModel(GetHashKey('a_c_rottweiler'))
    f.env.RecomputeK9MoveRate()
    t.equals(f.lastMoveRate().rate, 0.98, 'switching the controlled ped\'s model between two calls must switch the applied breed multiplier too -- this is recomputed fresh every call, never cached')
end)

t.test('a model NOT present in Config.Peds at all falls back to 1.0 (never nil, never an error)', function()
    local f = newFixture(pedsWithMultipliers())
    f.setModel(GetHashKey('a_c_unknown_streamed_model'))
    f.env.RecomputeK9MoveRate()
    t.equals(f.lastMoveRate().rate, 1.0)
end)

t.test('a non-number speedMultiplier (config typo) is rejected defensively and falls back to 1.0, never reaches SetPedMoveRateOverride as a string/nil', function()
    local f = newFixture({ { model = 'a_c_shepherd', speedMultiplier = '1.05' } })
    f.setModel(GetHashKey('a_c_shepherd'))
    f.env.RecomputeK9MoveRate()
    t.equals(f.lastMoveRate().rate, 1.0)
end)

t.test('a non-positive speedMultiplier (0 or negative) is rejected defensively and falls back to 1.0 -- a misconfigured value must never zero out or invert a K9\'s move rate', function()
    local f = newFixture({ { model = 'a_c_shepherd', speedMultiplier = 0 }, { model = 'a_c_rottweiler', speedMultiplier = -2 } })
    f.setModel(GetHashKey('a_c_shepherd'))
    f.env.RecomputeK9MoveRate()
    t.equals(f.lastMoveRate().rate, 1.0, 'speedMultiplier = 0')

    f.setModel(GetHashKey('a_c_rottweiler'))
    f.env.RecomputeK9MoveRate()
    t.equals(f.lastMoveRate().rate, 1.0, 'speedMultiplier = -2')
end)

t.test('an entry with a missing/non-string model field is skipped defensively at table-build time, never crashes the load or poisons other entries', function()
    local f = newFixture({
        { speedMultiplier = 1.5 }, -- no `model` at all
        { model = 'a_c_husky', speedMultiplier = 1.03 },
    })
    f.setModel(GetHashKey('a_c_husky'))
    f.env.RecomputeK9MoveRate()
    t.equals(f.lastMoveRate().rate, 1.03, 'a malformed sibling entry must not prevent a well-formed entry elsewhere in Config.Peds from working')
end)

-- ----------------------------------------------------------------------
-- COMPOSITION WITH OTHER MODIFIERS -- breed must go through the SAME
-- composer/clamp as every other slot, never a second SetPedMoveRateOverride
-- call or a second clamp.
-- ----------------------------------------------------------------------

t.test('breed composes MULTIPLICATIVELY with another active modifier, through the one shared clamp', function()
    local f = newFixture(pedsWithMultipliers())
    f.setModel(GetHashKey('a_c_husky')) -- 1.03
    f.env.K9MoveRateModifiers.fatigue = 0.85
    f.env.RecomputeK9MoveRate()
    -- 1.03 * 0.85 = 0.8755
    local rate = f.lastMoveRate().rate
    t.isTrue(math.abs(rate - 0.8755) < 0.0001, ('expected ~0.8755, got %s'):format(tostring(rate)))
end)

t.test('breed alone can never push the composed rate outside the existing [0.1, 2.0] clamp -- proposed values stay far inside it, but this proves no SECOND clamp was added (a second clamp would still produce the same visible number here, so this also checks the exact math, not just the range)', function()
    local f = newFixture({ { model = 'a_c_shepherd', speedMultiplier = 1.03 } })
    f.setModel(GetHashKey('a_c_shepherd'))
    f.env.K9MoveRateModifiers.dragging = 2.0 -- deliberately extreme, to approach the ceiling
    f.env.RecomputeK9MoveRate()
    -- 1.03 * 2.0 = 2.06, clamped to 2.0 by the ONE shared ceiling
    t.equals(f.lastMoveRate().rate, 2.0)
end)

t.test('RecomputeK9MoveRate() is still called exactly once per invocation (breed does not add a second SetPedMoveRateOverride call)', function()
    local f = newFixture(pedsWithMultipliers())
    f.setModel(GetHashKey('a_c_husky'))
    f.env.RecomputeK9MoveRate()
    t.equals(f.moveRateCallCount(), 1)
end)

t.test('K9MoveRateModifiers.breed exists at file load, defaulting to 1.0, before RecomputeK9MoveRate() is ever called', function()
    local f = newFixture(pedsWithMultipliers())
    t.equals(f.env.K9MoveRateModifiers.breed, 1.0)
end)

t.test('not currently playing a K9 model: breed is never applied (the whole composer resets to neutral, same as every other modifier)', function()
    local f = newFixture(pedsWithMultipliers())
    -- First apply a real, non-neutral breed rate as a K9 (husky, 1.03) so
    -- the OFF-branch below has a non-neutral lastAppliedMoveRate to reset --
    -- otherwise RecomputeK9MoveRate()'s own "already neutral, skip the
    -- native call" dedup (see tests/clientmovement_spec.lua's identical
    -- case) means SetPedMoveRateOverride is never called at all, and this
    -- test would have nothing to assert on.
    f.setModel(GetHashKey('a_c_husky'))
    f.env.RecomputeK9MoveRate()
    t.equals(f.lastMoveRate().rate, 1.03)

    f.setIsOwnModelK9(false)
    f.env.RecomputeK9MoveRate()
    t.equals(f.lastMoveRate().rate, 1.0, 'switching off IsOwnModelK9 must reset to neutral 1.0, never leave a stale breed-influenced rate applied to a non-K9 ped')
end)

os.exit(t.summary())
