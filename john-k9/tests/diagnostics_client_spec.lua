--[[
    tests/diagnostics_client_spec.lua

    Tests client/diagnostics.lua -- the small, periodic client-only self-
    report heartbeat that closes the "server cannot see this" blind spot
    server/diagnostics.lua's own header names (NUI focus stuck open, a ped
    stuck ragdolled/in a vehicle). See that file's own header for the full
    design (deliberately NOT a synchronous server-asks-client round trip).

    This file has no public API surface at all (a single top-level
    CreateThread loop, gated behind an early `return`) -- reached here via
    tests/fixtures/sandbox.lua's own cooperative thread runner, exactly the
    way tests/cooldowns_spec.lua and others
    already step through a real `while true do ... Wait(x) end` production
    loop one pass at a time.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

--- @param opts table? -- { enabled: boolean (default true) }
--- @return table fixture
local function newFixture(opts)
    opts = opts or {}
    local enabled = opts.enabled
    if enabled == nil then enabled = true end

    local threadRunner = Sandbox.newThreadRunner()

    local state = {
        pedHandle = 1,
        health = 180,
        maxHealth = 200,
        dead = false,
        ragdoll = false,
        inVehicle = false,
        vehicleHandle = 0,
        vehicleModelHash = 0,
        nuiFocused = false,
        gameTimer = 1000,
        modelHash = 999,
    }

    local sentEvents = {} -- { {event=, args={...}}, ... }
    local function TriggerServerEvent(eventName, ...)
        sentEvents[#sentEvents + 1] = { event = eventName, args = { ... } }
    end

    local env = Sandbox.newEnv({
        Config = { DebugDump = { enabled = enabled } },
        CreateThread = threadRunner.CreateThread,
        Wait = threadRunner.Wait,
        TriggerServerEvent = TriggerServerEvent,
        PlayerPedId = function() return state.pedHandle end,
        GetEntityModel = function(handle)
            if handle == state.vehicleHandle and state.inVehicle then return state.vehicleModelHash end
            return state.modelHash
        end,
        GetEntityHealth = function() return state.health end,
        GetEntityMaxHealth = function() return state.maxHealth end,
        IsEntityDead = function() return state.dead end,
        IsPedRagdoll = function() return state.ragdoll end,
        IsPedInAnyVehicle = function() return state.inVehicle end,
        GetVehiclePedIsIn = function() return state.vehicleHandle end,
        IsNuiFocused = function() return state.nuiFocused end,
        GetGameTimer = function() return state.gameTimer end,
    })

    Sandbox.loadInto('../client/diagnostics.lua', env)

    return { env = env, state = state, step = threadRunner.step, sentEvents = sentEvents }
end

t.test('Config.DebugDump.enabled = false starts no thread at all -- zero heartbeats, ever', function()
    local f = newFixture({ enabled = false })
    f.step()
    f.step()
    f.step()
    t.equals(#f.sentEvents, 0)
end)

t.test('enabled = true sends a heartbeat on the very first step (no initial Wait before the first report)', function()
    local f = newFixture({ enabled = true })
    -- Unlike most sweep threads in this resource, this file's own loop body
    -- runs its real work FIRST and calls Wait(5000) LAST -- "fire
    -- immediately, then every 5 seconds" is the whole point (see this
    -- file's own header) -- so, unlike Sandbox.newThreadRunner's own
    -- documented default stepping semantics, ONE step() already reaches
    -- the send before yielding at that first Wait. No priming call needed.
    f.step()
    t.equals(#f.sentEvents, 1)
    t.equals(f.sentEvents[1].event, 'john-k9:server:debugDumpClientHeartbeat')
end)

t.test('the heartbeat payload carries every documented field, correctly reflecting a healthy, non-vehicle ped', function()
    local f = newFixture()
    f.state.health, f.state.maxHealth = 175, 200
    f.state.modelHash = 5555
    f.state.nuiFocused = true
    f.state.gameTimer = 4242
    f.step()
    f.step()

    local payload = f.sentEvents[1].args[1]
    t.equals(payload.modelHash, 5555)
    t.equals(payload.pedHealth, 175)
    t.equals(payload.pedMaxHealth, 200)
    t.isFalse(payload.isDead)
    t.isFalse(payload.isRagdoll)
    t.isFalse(payload.inVehicle)
    t.equals(payload.vehicleModelHash, 0)
    t.isTrue(payload.nuiFocused)
    t.equals(payload.clientGameTimerMs, 4242)
end)

t.test('a ped currently in a vehicle reports inVehicle = true and the REAL vehicle model hash, not the ped\'s own', function()
    local f = newFixture()
    f.state.inVehicle = true
    f.state.vehicleHandle = 77
    f.state.vehicleModelHash = 8888
    f.step()
    f.step()

    local payload = f.sentEvents[1].args[1]
    t.isTrue(payload.inVehicle)
    t.equals(payload.vehicleModelHash, 8888)
end)

t.test('a ragdolled, dead ped is reported honestly -- this is exactly the "stuck" state a developer needs to see', function()
    local f = newFixture()
    f.state.dead = true
    f.state.ragdoll = true
    f.step()
    f.step()

    local payload = f.sentEvents[1].args[1]
    t.isTrue(payload.isDead)
    t.isTrue(payload.isRagdoll)
end)

t.test('a native throwing mid-snapshot degrades to skipping that one heartbeat, never an uncaught error', function()
    local f = newFixture()
    f.env.IsPedRagdoll = function() error('simulated native failure') end
    local ok = pcall(f.step)
    ok = ok and pcall(f.step)
    t.isTrue(ok, 'a thrown native must never escape this file\'s own thread')
    t.equals(#f.sentEvents, 0, 'a failed snapshot must not send a half-built or stale payload')
end)

t.test('a second step (one more full loop pass) sends a second heartbeat -- this genuinely repeats, it does not fire once and stop', function()
    local f = newFixture()
    f.step() -- first pass -- first heartbeat
    f.step() -- second pass, past the first Wait(5000) -- second heartbeat
    t.equals(#f.sentEvents, 2)
end)

print('')
print(('diagnostics_client_spec.lua: %d passed, %d failed'):format(t.passed, t.failed))
os.exit(t.summary())
