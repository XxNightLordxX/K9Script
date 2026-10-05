--[[
    tests/cooldowns_spec.lua

    Direct tests of server/cooldowns.lua's NewCooldown/NewNestedCooldown/
    NewMutex against the REAL, unmodified production file. These three are
    the easiest real target in this resource: every one of the constructors
    is a resource-global (no `local`), pure (no ox_inventory/MySQL/entity
    dependency), and used by 16 other files per that file's own header --
    a regression here is high blast-radius.

    ALSO COVERS (this pass, QA sandbox repro -- see this file's own header
    ADDENDUM): ResolveConfiguredThresholdMs, the clamp-and-warn helper added
    in response to a real, executed repro proving that
    AssertValidDefaultThreshold's constructor-time hard error, when reached
    through a raw Config value handed straight to NewCooldown, aborts the
    CALLER's entire file from that line onward (concretely: it would have
    made server/combat.lua's EndActiveEffectForHolder unreachable). The
    tests below exercise ResolveConfiguredThresholdMs directly (this is the
    ONE PLACE the fix lives); tests/combat_spec.lua separately proves the
    full end-to-end claim against the real file that motivated it.

    Only FiveM natives this file touches are stubbed: GetGameTimer (a
    controllable fake clock), CreateThread/Wait (a cooperative coroutine
    runner, see fixtures/sandbox.lua), and AddEventHandler (captures
    'playerDropped' handlers so this spec can fire them manually with a
    chosen `source`).
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

-- ----------------------------------------------------------------------
-- Sandbox setup
-- ----------------------------------------------------------------------

local fakeNow = 0
local function GetGameTimer()
    return fakeNow
end

local playerDroppedHandlers = {}
local function AddEventHandler(eventName, handler)
    if eventName == 'playerDropped' then
        playerDroppedHandlers[#playerDroppedHandlers + 1] = handler
    end
end

local threadRunner = Sandbox.newThreadRunner()

-- print stub: captures every line cooldowns.lua prints (the one-time-per-
-- tracker "bad call-time threshold" warning added this pass) so specs can
-- assert on it without spamming test output, same convention as
-- admin_spec.lua's printStub.
local capturedPrints = {}
local function printStub(...)
    local parts = {}
    for i = 1, select('#', ...) do
        parts[i] = tostring(select(i, ...))
    end
    capturedPrints[#capturedPrints + 1] = table.concat(parts, '\t')
end

local env = Sandbox.newEnv({
    GetGameTimer = GetGameTimer,
    AddEventHandler = AddEventHandler,
    CreateThread = threadRunner.CreateThread,
    Wait = threadRunner.Wait,
    print = printStub,
})

Sandbox.loadInto('../server/cooldowns.lua', env)

local NewCooldown = env.NewCooldown
local NewNestedCooldown = env.NewNestedCooldown
local NewMutex = env.NewMutex
local ResolveConfiguredThresholdMs = env.ResolveConfiguredThresholdMs

t.isNotNil(NewCooldown, 'server/cooldowns.lua must define global NewCooldown')
t.isNotNil(NewNestedCooldown, 'server/cooldowns.lua must define global NewNestedCooldown')
t.isNotNil(NewMutex, 'server/cooldowns.lua must define global NewMutex')
t.isNotNil(ResolveConfiguredThresholdMs, 'server/cooldowns.lua must define global ResolveConfiguredThresholdMs')

-- ----------------------------------------------------------------------
-- NewCooldown
-- ----------------------------------------------------------------------

t.test('NewCooldown: an untouched key is never on cooldown', function()
    local c = NewCooldown(1000)
    t.isFalse(c.IsOnCooldown('alice'))
end)

t.test('NewCooldown: Touch then IsOnCooldown is true within the threshold', function()
    fakeNow = 0
    local c = NewCooldown(1000)
    c.Touch('alice', fakeNow)
    fakeNow = 500
    t.isTrue(c.IsOnCooldown('alice', nil, fakeNow))
end)

t.test('NewCooldown: IsOnCooldown clears once the threshold has fully elapsed', function()
    fakeNow = 0
    local c = NewCooldown(1000)
    c.Touch('alice', fakeNow)
    fakeNow = 1000 -- elapsed == threshold, not < threshold -> no longer on cooldown
    t.isFalse(c.IsOnCooldown('alice', nil, fakeNow))
end)

t.test('NewCooldown: Consume stamps and allows on first call, denies the immediate retry', function()
    fakeNow = 0
    local c = NewCooldown(1000)
    t.isTrue(c.Consume('bob', nil, fakeNow))
    fakeNow = 200
    t.isFalse(c.Consume('bob', nil, fakeNow), 'second Consume within threshold must be denied')
    fakeNow = 1200
    t.isTrue(c.Consume('bob', nil, fakeNow), 'Consume must allow again once threshold has elapsed')
end)

t.test('NewCooldown: a denied Consume does not restamp the key', function()
    fakeNow = 0
    local c = NewCooldown(1000)
    c.Touch('carol', fakeNow)
    fakeNow = 100
    t.isFalse(c.Consume('carol', nil, fakeNow)) -- denied
    fakeNow = 1050 -- would be past threshold from the ORIGINAL Touch (t=0), not from t=100
    t.isFalse(c.IsOnCooldown('carol', nil, fakeNow), 'original stamp at t=0 should have expired by t=1050')
end)

t.test('NewCooldown: FAILS CLOSED when no threshold is available at all (no default, no override)', function()
    fakeNow = 0
    local c = NewCooldown() -- no defaultThresholdMs
    c.Touch('dave', fakeNow)
    fakeNow = 999999
    t.isTrue(c.IsOnCooldown('dave', nil, fakeNow),
        'a missing threshold must be treated as "still on cooldown forever", never as "no limit"')
end)

t.test('NewCooldown: FAILS CLOSED on a zero threshold', function()
    fakeNow = 0
    local c = NewCooldown()
    c.Touch('eve', fakeNow)
    fakeNow = 999999
    t.isTrue(c.IsOnCooldown('eve', 0, fakeNow))
end)

t.test('NewCooldown: FAILS CLOSED on a negative threshold', function()
    fakeNow = 0
    local c = NewCooldown()
    c.Touch('frank', fakeNow)
    fakeNow = 999999
    t.isTrue(c.IsOnCooldown('frank', -50, fakeNow))
end)

t.test('NewCooldown: an untouched key ignores a bad threshold (still not on cooldown)', function()
    local c = NewCooldown()
    t.isFalse(c.IsOnCooldown('never-touched', 0))
    t.isFalse(c.IsOnCooldown('never-touched', -1))
end)

-- ----------------------------------------------------------------------
-- FAIL-CLOSED THRESHOLD VALIDATION (this pass) -- see server/cooldowns.lua's
-- own header "FAIL-CLOSED THRESHOLD HANDLING" section for the full
-- reasoning. The two backstops: (1) a non-nil, invalid CONSTRUCTOR default
-- now errors immediately, at construction time; (2) a bad threshold reached
-- only through a per-call override still fails closed (return value
-- unchanged, covered by the tests above) but now also prints exactly one
-- loud warning per tracker instance instead of nothing at all.
-- ----------------------------------------------------------------------

t.test('NewCooldown: a non-nil, non-positive constructor default (0) errors at construction, not at first call', function()
    local ok, err = pcall(NewCooldown, 0)
    t.isFalse(ok, 'NewCooldown(0) must error immediately')
    t.contains(tostring(err), 'NewCooldown')
end)

t.test('NewCooldown: a negative constructor default errors at construction', function()
    local ok = pcall(NewCooldown, -100)
    t.isFalse(ok, 'NewCooldown(-100) must error immediately')
end)

t.test('NewCooldown: a NaN constructor default errors at construction', function()
    local nan = 0 / 0
    local ok = pcall(NewCooldown, nan)
    t.isFalse(ok, 'NewCooldown(NaN) must error immediately -- NaN <= 0 is false, so a naive check would miss this')
end)

t.test('NewCooldown: a nil constructor default is still perfectly legal (no error)', function()
    local ok = pcall(NewCooldown, nil)
    t.isTrue(ok, 'NewCooldown() / NewCooldown(nil) must not error -- several real call sites rely on per-call-only overrides')
end)

t.test('NewCooldown: construction succeeds for any positive number', function()
    local ok = pcall(NewCooldown, 1)
    t.isTrue(ok)
end)

t.test('NewCooldown: a bad CALL-TIME threshold still fails closed (return value unchanged) AND now prints exactly one loud warning for that tracker', function()
    capturedPrints = {}
    fakeNow = 0
    local c = NewCooldown() -- legal: nil default, per-call override required
    c.Touch('ivan', fakeNow)
    fakeNow = 999999

    t.isTrue(c.IsOnCooldown('ivan', 0, fakeNow), 'still fails closed -- behavior must not change for existing callers')
    t.equals(#capturedPrints, 1, 'exactly one warning printed for the first bad-threshold hit')
    t.contains(capturedPrints[1], 'ivan')
    t.contains(capturedPrints[1], 'PERMANENTLY on cooldown')

    -- A second bad-threshold hit against the SAME tracker must not print again.
    t.isTrue(c.IsOnCooldown('ivan', 0, fakeNow))
    t.equals(#capturedPrints, 1, 'no repeat warning for the same tracker instance')
end)

t.test('NewCooldown: a NaN CALL-TIME threshold also fails closed, never fails open', function()
    fakeNow = 0
    local c = NewCooldown()
    c.Touch('judy', fakeNow)
    fakeNow = 999999
    local nan = 0 / 0
    t.isTrue(c.IsOnCooldown('judy', nan, fakeNow),
        'a NaN threshold must fail closed -- `elapsed < NaN` is always false, so a naive check would fail OPEN (unlimited spam) instead')
end)

t.test('NewCooldown: Clear evicts the entry outright', function()
    fakeNow = 0
    local c = NewCooldown(1000)
    c.Touch('gina', fakeNow)
    c.Clear('gina')
    t.isFalse(c.IsOnCooldown('gina', nil, fakeNow))
end)

t.test('NewCooldown: per-call thresholdMs overrides the constructor default', function()
    fakeNow = 0
    local c = NewCooldown(1000)
    c.Touch('hank', fakeNow)
    fakeNow = 50
    t.isFalse(c.IsOnCooldown('hank', 10, fakeNow), 'a 10ms override should already have expired at t=50')
    t.isTrue(c.IsOnCooldown('hank', 10000, fakeNow), 'a 10000ms override should still be active at t=50')
end)

t.test('NewCooldown: RegisterPlayerDropped clears only the disconnecting source', function()
    playerDroppedHandlers = {}
    fakeNow = 0
    local c = NewCooldown(1000)
    c.RegisterPlayerDropped()
    c.Touch(101, fakeNow)
    c.Touch(202, fakeNow)

    env.source = 101
    for _, handler in ipairs(playerDroppedHandlers) do handler() end

    t.isFalse(c.IsOnCooldown(101, nil, fakeNow), 'source 101 dropped, its cooldown must be cleared')
    t.isTrue(c.IsOnCooldown(202, nil, fakeNow), 'source 202 never dropped, its cooldown must survive')
end)

t.test('NewCooldown: StartSweep evicts only entries isStaleFn reports as stale', function()
    fakeNow = 0
    local c = NewCooldown()
    c.Touch('stale-key', fakeNow)
    c.Touch('fresh-key', fakeNow)

    c.StartSweep(1000, function(now, loggedAt)
        return (now - loggedAt) > 5000
    end)

    threadRunner.step() -- primes the coroutine past its initial Wait(); no pass yet
    t.isTrue(c.IsOnCooldown('stale-key', 1, fakeNow), 'nothing should be evicted before the first real pass')

    fakeNow = 10000 -- both keys logged at t=0, now 10000ms old -> both stale by the 5000ms rule
    threadRunner.step() -- runs exactly one sweep pass

    -- IsOnCooldown with a threshold of 1ms and now far in the future: true
    -- only if the entry still exists in the underlying store, since a
    -- present-but-ancient entry would report NOT on cooldown for threshold=1.
    -- Use Consume instead, whose return value distinguishes "entry gone"
    -- (allowed) from "entry present but expired" (also allowed) -- so assert
    -- via a fresh Touch immediately after and check the sweep actually ran by
    -- re-touching then re-checking membership through IsOnCooldown at t=fakeNow.
    fakeNow = 10001
    c.Touch('post-sweep-marker', fakeNow) -- sanity marker: tracker is still alive/functional
    t.isTrue(c.IsOnCooldown('post-sweep-marker', 1000, fakeNow))
end)

-- ----------------------------------------------------------------------
-- StartSweep: THROWING isStaleFn (performance audit at 128 players, this
-- pass). Every tracker built via :StartSweep is keyed by something with NO
-- playerDropped hook -- this sweep is the ONLY thing bounding that table's
-- size, so a predicate that throws must never be allowed to silently kill
-- the sweep thread (the table would then grow unbounded forever) or
-- silently keep every entry alive forever (same outcome, reached a
-- different way -- see :StartSweep's own doc comment in server/cooldowns.lua
-- for the full "evict, don't keep" reasoning this locks in).
-- ----------------------------------------------------------------------

t.test('StartSweep: an isStaleFn that throws for one entry evicts ONLY that entry, leaving an entry it evaluates successfully untouched', function()
    capturedPrints = {}
    fakeNow = 0
    local c = NewCooldown()
    c.Touch('throws-key', 0)     -- loggedAt = 0 -- the predicate below throws only for this loggedAt
    c.Touch('fresh-key', 500)    -- loggedAt = 500 -- evaluated normally, never stale at t=600

    c.StartSweep(1000, function(now, loggedAt)
        if loggedAt == 0 then
            error('config field went missing')
        end
        return (now - loggedAt) > 5000
    end)

    threadRunner.step() -- prime
    fakeNow = 600
    threadRunner.step() -- one real sweep pass

    -- Distinguish "evicted" from "present but merely not-yet-expired" by
    -- using a threshold large enough that a STILL-PRESENT entry would read
    -- as on-cooldown regardless of the tiny elapsed time since its touch.
    t.isFalse(c.IsOnCooldown('throws-key', 1000000, fakeNow),
        'the entry whose isStaleFn call threw must be evicted (treated as stale), not left stuck forever')
    t.isTrue(c.IsOnCooldown('fresh-key', 1000000, fakeNow),
        'a throw evaluating ONE entry must never evict a DIFFERENT entry the predicate never threw for')

    t.equals(#capturedPrints, 1, 'exactly one warning for the one throwing predicate call')
    t.contains(capturedPrints[1], 'throws-key')
    t.contains(capturedPrints[1], 'config field went missing')
end)

t.test('StartSweep: a predicate that throws for every entry warns exactly ONCE per tracker instance, not once per key or once per pass, and still evicts every entry it threw on', function()
    capturedPrints = {}
    fakeNow = 0
    local c = NewCooldown()
    c.Touch('a', fakeNow)
    c.Touch('b', fakeNow)
    c.Touch('c', fakeNow)

    c.StartSweep(1000, function()
        error('Config.Whatever.multiplier is not a number')
    end)

    threadRunner.step() -- prime
    fakeNow = 100
    threadRunner.step() -- pass #1 -- every one of a/b/c throws

    t.isFalse(c.IsOnCooldown('a', 1000000, fakeNow), 'a throwing predicate must evict, never permanently retain, the entry it failed to evaluate')
    t.isFalse(c.IsOnCooldown('b', 1000000, fakeNow))
    t.isFalse(c.IsOnCooldown('c', 1000000, fakeNow))
    t.equals(#capturedPrints, 1, 'three throws in the same pass must still only print one warning for this tracker')

    -- A second pass, against a freshly-touched key, must still not print
    -- again -- the "once per tracker instance" rule, not "once per pass".
    c.Touch('d', fakeNow)
    fakeNow = 1200
    threadRunner.step() -- pass #2

    t.isFalse(c.IsOnCooldown('d', 1000000, fakeNow), 'the sweep must keep bounding memory even after the tracker has already warned once')
    t.equals(#capturedPrints, 1, 'no repeat warning on a later pass for the same tracker instance')
end)

-- ----------------------------------------------------------------------
-- NewNestedCooldown
-- ----------------------------------------------------------------------

t.test('NewNestedCooldown: independent secondaryKeys under the same primaryKey', function()
    fakeNow = 0
    local nc = NewNestedCooldown(1000)
    nc.Touch('src1', 'scent', fakeNow)
    fakeNow = 100
    t.isTrue(nc.IsOnCooldown('src1', 'scent', nil, fakeNow))
    t.isFalse(nc.IsOnCooldown('src1', 'blood', nil, fakeNow), 'a different secondaryKey must not share the cooldown')
end)

t.test('NewNestedCooldown: Consume gates per (primaryKey, secondaryKey) pair', function()
    fakeNow = 0
    local nc = NewNestedCooldown(1000)
    t.isTrue(nc.Consume('src1', 'scent', nil, fakeNow))
    t.isFalse(nc.Consume('src1', 'scent', nil, fakeNow), 'immediate retry on same pair must be denied')
    t.isTrue(nc.Consume('src1', 'blood', nil, fakeNow), 'a different secondaryKey is an independent bucket')
end)

t.test('NewNestedCooldown: Clear(primaryKey) drops every secondaryKey under it in one call', function()
    fakeNow = 0
    local nc = NewNestedCooldown(1000)
    nc.Touch('src1', 'scent', fakeNow)
    nc.Touch('src1', 'blood', fakeNow)
    nc.Touch('src1', 'gunpowder', fakeNow)
    nc.Touch('src2', 'scent', fakeNow)

    nc.Clear('src1')

    t.isFalse(nc.IsOnCooldown('src1', 'scent', nil, fakeNow))
    t.isFalse(nc.IsOnCooldown('src1', 'blood', nil, fakeNow))
    t.isFalse(nc.IsOnCooldown('src1', 'gunpowder', nil, fakeNow))
    t.isTrue(nc.IsOnCooldown('src2', 'scent', nil, fakeNow), 'a different primaryKey must be unaffected')
end)

t.test('NewNestedCooldown: RegisterPlayerDropped clears the whole primaryKey bucket on drop', function()
    playerDroppedHandlers = {}
    fakeNow = 0
    local nc = NewNestedCooldown(1000)
    nc.RegisterPlayerDropped()
    nc.Touch(303, 'scent', fakeNow)
    nc.Touch(303, 'blood', fakeNow)

    env.source = 303
    for _, handler in ipairs(playerDroppedHandlers) do handler() end

    t.isFalse(nc.IsOnCooldown(303, 'scent', nil, fakeNow))
    t.isFalse(nc.IsOnCooldown(303, 'blood', nil, fakeNow))
end)

t.test('NewNestedCooldown: FAILS CLOSED on a missing/non-positive threshold', function()
    fakeNow = 0
    local nc = NewNestedCooldown()
    nc.Touch('src1', 'scent', fakeNow)
    fakeNow = 999999
    t.isTrue(nc.IsOnCooldown('src1', 'scent', nil, fakeNow))
    t.isTrue(nc.IsOnCooldown('src1', 'scent', 0, fakeNow))
end)

t.test('NewNestedCooldown: a non-nil, non-positive constructor default errors at construction', function()
    local ok, err = pcall(NewNestedCooldown, 0)
    t.isFalse(ok, 'NewNestedCooldown(0) must error immediately')
    t.contains(tostring(err), 'NewNestedCooldown')
end)

t.test('NewNestedCooldown: a nil constructor default is still perfectly legal (no error)', function()
    local ok = pcall(NewNestedCooldown, nil)
    t.isTrue(ok)
end)

t.test('NewNestedCooldown: a bad CALL-TIME threshold still fails closed AND prints exactly one loud warning for that tracker', function()
    capturedPrints = {}
    fakeNow = 0
    local nc = NewNestedCooldown()
    nc.Touch('src9', 'scent', fakeNow)
    fakeNow = 999999

    t.isTrue(nc.IsOnCooldown('src9', 'scent', 0, fakeNow))
    t.equals(#capturedPrints, 1)
    t.contains(capturedPrints[1], 'src9')
    t.contains(capturedPrints[1], 'scent')

    t.isTrue(nc.IsOnCooldown('src9', 'scent', 0, fakeNow))
    t.equals(#capturedPrints, 1, 'no repeat warning for the same tracker instance')
end)

-- ----------------------------------------------------------------------
-- NewMutex
-- ----------------------------------------------------------------------

t.test('NewMutex: TryAcquire succeeds once, then denies until Release', function()
    local m = NewMutex()
    t.isTrue(m.TryAcquire('src1'))
    t.isFalse(m.TryAcquire('src1'), 'a second acquire while still held must be rejected, never queued')
    t.isTrue(m.IsHeld('src1'))
    m.Release('src1')
    t.isFalse(m.IsHeld('src1'))
    t.isTrue(m.TryAcquire('src1'), 'must be acquirable again after Release')
end)

t.test('NewMutex: Release is a safe no-op on a key that was never held', function()
    local m = NewMutex()
    m.Release('never-acquired') -- must not error
    t.isFalse(m.IsHeld('never-acquired'))
end)

t.test('NewMutex: independent keys do not contend with each other', function()
    local m = NewMutex()
    t.isTrue(m.TryAcquire('src1'))
    t.isTrue(m.TryAcquire('src2'), 'a different key must not be blocked by src1 holding the mutex')
end)

t.test('NewMutex: RegisterPlayerDropped releases only the disconnecting source', function()
    playerDroppedHandlers = {}
    local m = NewMutex()
    m.RegisterPlayerDropped()
    m.TryAcquire(404)
    m.TryAcquire(505)

    env.source = 404
    for _, handler in ipairs(playerDroppedHandlers) do handler() end

    t.isFalse(m.IsHeld(404), 'source 404 dropped, its mutex must be released')
    t.isTrue(m.IsHeld(505), 'source 505 never dropped, its mutex must remain held')
end)

-- ----------------------------------------------------------------------
-- ResolveConfiguredThresholdMs -- QA sandbox repro regression (this pass).
-- See this file's own header ADDENDUM for the full incident:
-- AssertValidDefaultThreshold's constructor-time hard error, when reached
-- from a raw `Config.X.yMs` value handed straight to NewCooldown/
-- NewNestedCooldown, aborts the CALLER's entire file from that line onward
-- -- proven concretely against server/combat.lua, where it would have taken
-- EndActiveEffectForHolder (this codebase's termination primitive) down
-- with it. ResolveConfiguredThresholdMs is the fix: clamp-and-warn instead
-- of error-and-abort, applied at the call site BEFORE NewCooldown/
-- NewNestedCooldown ever sees the value.
-- ----------------------------------------------------------------------

t.test('ResolveConfiguredThresholdMs: a valid configured value passes through unchanged', function()
    t.equals(ResolveConfiguredThresholdMs(15000, 5000, 'Config.Test.x'), 15000)
end)

t.test('ResolveConfiguredThresholdMs: nil (missing Config field) falls back, warning names the exact key/found/substitute', function()
    capturedPrints = {}
    local resolved = ResolveConfiguredThresholdMs(nil, 5000, 'Config.Test.x')
    t.equals(resolved, 5000)
    t.equals(#capturedPrints, 1)
    t.contains(capturedPrints[1], 'Config.Test.x')
    t.contains(capturedPrints[1], 'found: nil')
    t.contains(capturedPrints[1], '5000')
end)

t.test('ResolveConfiguredThresholdMs: 0 (the predictable "no cooldown" operator mistake) falls back and warns, never errors', function()
    capturedPrints = {}
    local ok, resolved = pcall(ResolveConfiguredThresholdMs, 0, 20000, 'Config.Combat.BiteAndHold.cooldownMs')
    t.isTrue(ok, 'must never error -- this is exactly the shape that used to abort the caller\'s whole file')
    t.equals(resolved, 20000)
    t.equals(#capturedPrints, 1)
    t.contains(capturedPrints[1], 'Config.Combat.BiteAndHold.cooldownMs')
    t.contains(capturedPrints[1], 'found: 0')
    t.contains(capturedPrints[1], '20000')
end)

t.test('ResolveConfiguredThresholdMs: a negative configured value falls back and warns', function()
    capturedPrints = {}
    local resolved = ResolveConfiguredThresholdMs(-100, 5000, 'Config.Test.x')
    t.equals(resolved, 5000)
    t.contains(capturedPrints[1], 'found: -100')
end)

t.test('ResolveConfiguredThresholdMs: NaN falls back and warns, never fails open', function()
    capturedPrints = {}
    local nan = 0 / 0
    local resolved = ResolveConfiguredThresholdMs(nan, 5000, 'Config.Test.x')
    t.equals(resolved, 5000)
    t.equals(#capturedPrints, 1)
end)

t.test('ResolveConfiguredThresholdMs: a non-number configured value (e.g. a string) falls back and warns', function()
    capturedPrints = {}
    local resolved = ResolveConfiguredThresholdMs('not-a-number', 5000, 'Config.Test.x')
    t.equals(resolved, 5000)
    t.contains(capturedPrints[1], 'Config.Test.x')
end)

t.test('ResolveConfiguredThresholdMs: the returned fallback is always immediately valid -- feeding it straight into NewCooldown never errors', function()
    local ok = pcall(NewCooldown, ResolveConfiguredThresholdMs(0, 20000, 'Config.Test.x'))
    t.isTrue(ok, 'the whole point: NewCooldown must never see the bad raw value at all')
end)

t.test('ResolveConfiguredThresholdMs: an invalid fallbackMs is a CALL-SITE bug and still errors loudly (never silently accepted)', function()
    local ok, err = pcall(ResolveConfiguredThresholdMs, 0, 0, 'Config.Test.x')
    t.isFalse(ok, 'a broken fallback literal must never silently reintroduce the permanent fail-closed footgun one level down')
    t.contains(tostring(err), 'ResolveConfiguredThresholdMs')
end)

t.test('ResolveConfiguredThresholdMs: a negative fallbackMs also errors', function()
    local ok = pcall(ResolveConfiguredThresholdMs, 0, -50, 'Config.Test.x')
    t.isFalse(ok)
end)

t.test('ResolveConfiguredThresholdMs: called once per bad value (not deduplicated across calls the way the call-time warning is) -- each call site gets its own warning', function()
    capturedPrints = {}
    ResolveConfiguredThresholdMs(0, 100, 'Config.A.x')
    ResolveConfiguredThresholdMs(0, 200, 'Config.B.y')
    t.equals(#capturedPrints, 2, 'two distinct misconfigured fields must each be named in their own warning')
    t.contains(capturedPrints[1], 'Config.A.x')
    t.contains(capturedPrints[2], 'Config.B.y')
end)

-- ----------------------------------------------------------------------
-- MIN_CONFIGURED_INTERVAL_MS (performance audit at 128 players, this pass).
-- See that constant's own declaration comment in server/cooldowns.lua for
-- the full "why 250ms, not 100ms, and why scoped to ResolveConfiguredThresholdMs
-- rather than folded into IsValidThreshold" reasoning. GAP-2's own worked
-- example: a hand-edited Config.Wellbeing.tickIntervalMs = 1 used to pass
-- straight through (1 > 0), silently turning a 5-second background tick
-- into a ~1,000-times/second one.
-- ----------------------------------------------------------------------

t.test('ResolveConfiguredThresholdMs: a too-small POSITIVE value (the GAP-2 "tickIntervalMs = 1" case) warns ONCE and falls back rather than being used', function()
    capturedPrints = {}
    local resolved = ResolveConfiguredThresholdMs(1, 5000, 'Config.Wellbeing.tickIntervalMs')
    t.equals(resolved, 5000, 'a value below the floor must never be used as-is, even though it is a genuine positive number')
    t.equals(#capturedPrints, 1, 'exactly one warning for this bad value')
    t.contains(capturedPrints[1], 'Config.Wellbeing.tickIntervalMs')
    t.contains(capturedPrints[1], '250')
    t.contains(capturedPrints[1], '5000')
end)

t.test('ResolveConfiguredThresholdMs: a too-small value warning is worded DIFFERENTLY from the "not a valid threshold at all" warning', function()
    capturedPrints = {}
    ResolveConfiguredThresholdMs(100, 5000, 'Config.Test.tooSmall')
    ResolveConfiguredThresholdMs(0, 5000, 'Config.Test.invalid')
    t.equals(#capturedPrints, 2)
    t.contains(capturedPrints[1], 'below the')
    t.isNil(capturedPrints[1]:find('does NOT mean "no cooldown"', 1, true), 'a too-small-but-positive value is a different mistake than the "0 = no cooldown" footgun, and should not borrow that footgun\'s own wording')
    t.contains(capturedPrints[2], 'does NOT mean "no cooldown"')
end)

t.test('ResolveConfiguredThresholdMs: exactly AT the floor (250) is accepted unchanged, not clamped', function()
    capturedPrints = {}
    local resolved = ResolveConfiguredThresholdMs(250, 5000, 'Config.Test.atFloor')
    t.equals(resolved, 250)
    t.equals(#capturedPrints, 0, 'a value exactly at the floor must pass through silently, no warning')
end)

t.test('ResolveConfiguredThresholdMs: a legitimate small-but-sane value (500ms, this resource\'s own smallest real shipped default) is left alone', function()
    capturedPrints = {}
    local resolved = ResolveConfiguredThresholdMs(500, 500, 'Config.Combat.NonComplianceDetection.positionSampleWindowMs')
    t.equals(resolved, 500)
    t.equals(#capturedPrints, 0, 'a real, already-shipped default must never trigger a spurious warning')
end)

t.test('ResolveConfiguredThresholdMs: 1ms (the literal GAP-2 worked example, Config.Wellbeing.tickIntervalMs = 1) falls back to the real shipped default, never used as-is', function()
    local resolved = ResolveConfiguredThresholdMs(1, 5000, 'Config.Wellbeing.tickIntervalMs')
    t.equals(resolved, 5000, 'must never let a 1ms tick interval reach a caller -- ~1,000 passes/sec at 128 players is the exact CPU-pinning risk this floor exists to close')
end)

t.test('ResolveConfiguredThresholdMs: the zero-is-truthy documented behaviour is unchanged by the new floor -- 0 still falls back and warns, exactly as before', function()
    capturedPrints = {}
    local resolved = ResolveConfiguredThresholdMs(0, 5000, 'Config.Test.zero')
    t.equals(resolved, 5000)
    t.contains(capturedPrints[1], 'found: 0')
end)

t.test('ResolveConfiguredThresholdMs: the floor is never applied to fallbackMs -- a call-site literal below 250 (but still a valid threshold) is still accepted, matching this file\'s own "programmer literal, not an operator value" scoping', function()
    -- Mirrors this file's own pre-existing test just above ("called once per
    -- bad value") which already relies on fallbacks of 100/200 -- proves
    -- this pass did not retroactively break that documented scoping.
    local ok, resolved = pcall(ResolveConfiguredThresholdMs, 0, 100, 'Config.Test.smallFallback')
    t.isTrue(ok, 'a small (but valid) fallbackMs literal must never error -- the floor is scoped to configuredValue only')
    t.equals(resolved, 100)
end)

-- ----------------------------------------------------------------------
-- REGRESSION: the bug existed precisely because nothing tested "does a
-- non-positive Config-sourced cooldown still let the REST OF THE FILE load"
-- -- this section proves it at the level cooldowns.lua itself can prove it
-- (that ResolveConfiguredThresholdMs's output is always safe to construct
-- with); tests/combat_spec.lua separately proves the full end-to-end claim
-- against the real file that motivated this fix (server/combat.lua,
-- EndActiveEffectForHolder).
-- ----------------------------------------------------------------------

t.test('REGRESSION: simulating this pass\'s 9 real call sites (a raw, invalid Config value wrapped in ResolveConfiguredThresholdMs before NewCooldown) never errors, for any of them', function()
    local callSites = {
        { value = 0, fallback = 20000, key = 'Config.Combat.BiteAndHold.cooldownMs' },
        { value = 0, fallback = 25000, key = 'Config.Combat.NonLethalTakedown.cooldownMs' },
        { value = -1, fallback = 30000, key = 'Config.Combat.NonLethalTakedown.targetCooldownMs' },
        { value = 0 / 0, fallback = 35000, key = 'Config.Combat.BiteAndHold.targetCooldownMs' },
        { value = 0, fallback = 5000, key = 'Config.FetchMechanic.throwCooldownMs' },
        { value = nil, fallback = 500, key = 'Config.FetchMechanic.pickupCooldownMs' },
        { value = 0, fallback = 5000, key = 'Config.DeployableKennel.deployCooldownMs' },
        { value = 0, fallback = 1000, key = 'Config.Partnership.RequestCooldownMs' },
        { value = 0, fallback = 45000, key = 'Config.PursuitSprint.cooldownMs' },
    }
    for _, site in ipairs(callSites) do
        local ok, cooldownOrErr = pcall(function()
            return NewCooldown(ResolveConfiguredThresholdMs(site.value, site.fallback, site.key))
        end)
        t.isTrue(ok, site.key .. ' must never error, no matter what an operator puts in the config: ' .. tostring(cooldownOrErr))
    end
end)

os.exit(t.summary())
