--[[
    tests/bonetool_spec.lua

    Direct tests of server/bonetool.lua against the REAL, unmodified
    production file (same Sandbox.loadInto pattern tests/notify_spec.lua
    already uses for its own, narrower bonetool.lua coverage — read that
    file first; this spec does NOT duplicate its NotifyPlayer-delegation
    cases, only the bonetool-specific surface that file does not cover).

    THREE THINGS THIS FILE PROVES, per this pass's own task brief:
      1. THE TWO-LAYER REGISTRATION GATE (coder-security, this pass):
           - Config.Features.BoneSweepDevTool = true AND the convar
             `qbx_k9unit_enable_bone_dev_tool` = 1 -> '/k9bonetool' IS
             registered.
           - flag = true, convar UNSET (reads back as GetConvarInt's own
             default of 0) -> '/k9bonetool' is NOT registered, and exactly
             one loud, actionable WARNING is printed naming the convar.
           - flag = false, REGARDLESS of the convar -> '/k9bonetool' is NOT
             registered, and NOTHING is printed at all (a default install
             with the flag off must stay silent).
      2. THE JOB-RANK AUTHORIZATION CONVERSION (coder-security, this pass —
         ACE -> police job-rank, at the project owner's direction):
         IsAuthorizedBoneSweepDevTool grants ONLY on `job.isboss == true`
         for a job whose name is a configured Config.Departments key —
         deliberately NOT server/admin.lua's IsAuthorizedAdmin threshold
         (job.isboss OR job.grade.level >= dept.auditGrade) — see
         server/bonetool.lua's own header ACCESS MODEL section for why. A
         senior (high-grade, non-boss) officer in a configured department
         must still be DENIED.
      3. THE NO-UNBOUNDED-TRAP FIX (coder-security, this pass): 'stop' —
         this tool's only termination/cleanup path — must stay reachable
         for a caller who fails IsAuthorizedBoneSweepDevTool entirely (no
         resolvable player record at all), while still being subject to
         the SAME per-source cooldown every other subcommand shares (this
         is anti-spam, never authorization, so it only ever delays a repeat
         call briefly, never denies it outright). Console (source == 0) is
         REQUIRED to stay rejected regardless of subcommand, including
         'stop' — that check runs before the 'stop' bypass, not after it.

    Uses fixtures/sandbox.lua exactly like notify_spec.lua/admin_spec.lua:
    loads server/cooldowns.lua then server/notify.lua then the REAL
    server/bonetool.lua into one env per scenario (a fresh env per scenario
    because the registration decision is made exactly once, at
    onResourceStart, per this file's own documented "gate at registration"
    convention — there is no way to re-decide it inside a single env
    without restarting the whole sandboxed load).
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

-- MUST match server/bonetool.lua's own BONE_DEV_TOOL_ENABLE_CONVAR literal
-- exactly (that file duplicates this same string into client/bonetool.lua
-- too, per its own comment on why the two are not shared as a resource
-- global) — re-diff this constant against that file directly if it is ever
-- renamed, rather than trusting this second-hand copy.
local BONE_DEV_TOOL_ENABLE_CONVAR = 'qbx_k9unit_enable_bone_dev_tool'

--- Builds one fresh, isolated environment and loads the real
--- cooldowns.lua/notify.lua/bonetool.lua into it, exactly like
--- notify_spec.lua's own boneToolEnv setup. Returns a table of everything a
--- test needs to drive and inspect it.
--- @param opts table { featureFlag: boolean, convarValue: number, playersBySource: table<number, table> }
--- @return table ctx
local function buildEnv(opts)
    local registeredCommands = {}
    local function RegisterCommand(name, handler, _restricted)
        registeredCommands[name] = handler
    end

    local eventHandlers = {}
    local function AddEventHandler(eventName, handler)
        eventHandlers[eventName] = eventHandlers[eventName] or {}
        eventHandlers[eventName][#eventHandlers[eventName] + 1] = handler
    end

    local function GetCurrentResourceName()
        return 'qbx_k9unit'
    end

    local capturedEvents = {}
    local function TriggerClientEvent(eventName, target, ...)
        capturedEvents[#capturedEvents + 1] = { eventName, target, ... }
    end

    local now = 0
    local function GetGameTimer()
        return now
    end

    local printedLines = {}
    local function printStub(s)
        printedLines[#printedLines + 1] = tostring(s)
    end

    local convarValue = opts.convarValue or 0
    local function GetConvarInt(name, default)
        if name == BONE_DEV_TOOL_ENABLE_CONVAR then return convarValue end
        return default
    end

    local playersBySource = opts.playersBySource or {}
    local exportsStub = {
        qbx_core = {
            GetPlayer = function(_self, source) return playersBySource[source] end,
        },
    }

    local Config = {
        Features = { BoneSweepDevTool = opts.featureFlag },
        BoneSweepTool = {
            TestPropModel     = 'prop_test_model',
            MaxBoneIndex      = 200,
            TestOffsetX = 0, TestOffsetY = 0, TestOffsetZ = 0,
            CommandCooldownMs = 500,
        },
        -- Mirrors admin_spec.lua/notify_spec.lua's own Departments fixture
        -- shape. auditGrade is present (matching config.lua's real shape)
        -- purely for realism -- IsAuthorizedBoneSweepDevTool never reads it
        -- (that is exactly what this file's job-rank tests below prove: a
        -- high auditGrade must NOT be enough on its own).
        Departments = {
            police = { label = 'Los Santos Police Department', certifierGrade = 4, auditGrade = 4, autoAccessGrade = nil },
        },
        -- PER-PERSON FEATURE CONTROL fixture knob (SCENARIO D, below) --
        -- nil unless a test opts in, mirroring pursuitsprint_spec.lua's own
        -- `opts.requireGrantListed` shape.
        FeatureControl = opts.featureControl,
    }

    -- HasPermission is a GLOBAL in production (server/permissions.lua),
    -- soft-dependency-guarded (`type(HasPermission) == 'function'`) by
    -- server/bonetool.lua's own IsBoneSweepDevToolPermittedForCitizenId --
    -- nil by default here (SCENARIO A/B/C above never define it, exactly
    -- like production without server/permissions.lua installed), settable
    -- per test for SCENARIO D.
    local envOverrides = {
        RegisterCommand        = RegisterCommand,
        AddEventHandler        = AddEventHandler,
        GetCurrentResourceName = GetCurrentResourceName,
        TriggerClientEvent     = TriggerClientEvent,
        GetGameTimer           = GetGameTimer,
        GetConvarInt           = GetConvarInt,
        exports                = exportsStub,
        print                  = printStub,
        Config                 = Config,
    }
    if opts.hasPermissionFn then
        envOverrides.HasPermission = opts.hasPermissionFn
    end

    local env = Sandbox.newEnv(envOverrides)

    Sandbox.loadInto('../server/cooldowns.lua', env)
    Sandbox.loadInto('../server/notify.lua', env)
    Sandbox.loadInto('../server/bonetool.lua', env)

    return {
        env                 = env,
        registeredCommands  = registeredCommands,
        eventHandlers       = eventHandlers,
        capturedEvents      = capturedEvents,
        printedLines        = printedLines,
        setNow              = function(v) now = v end,
        advance             = function(ms) now = now + ms end,
    }
end

--- Fires every registered onResourceStart handler for 'qbx_k9unit', exactly
--- like notify_spec.lua/admin_spec.lua's own identical loop.
--- @param ctx table
local function startResource(ctx)
    for _, handler in ipairs(ctx.eventHandlers['onResourceStart'] or {}) do
        handler('qbx_k9unit')
    end
end

--- @param events table
--- @param eventName string
--- @return table? lastMatch
local function lastEventNamed(events, eventName)
    local match = nil
    for _, e in ipairs(events) do
        if e[1] == eventName then match = e end
    end
    return match
end

--- @param events table
--- @param eventName string
--- @return number
local function countEventsNamed(events, eventName)
    local n = 0
    for _, e in ipairs(events) do
        if e[1] == eventName then n = n + 1 end
    end
    return n
end

-- ======================================================================
-- SCENARIO A: Config.Features.BoneSweepDevTool = false. Per this file's own
-- documented "flag off means genuinely inert" convention, this must hold
-- REGARDLESS of the convar -- tested with the convar both unset (0) and
-- explicitly set (1), since a naive "convar first" reordering of the two
-- registration checks could otherwise let a stray convar alone leak a
-- warning print on every default (flag-off) install.
-- ======================================================================

t.test('flag OFF, convar unset (0): k9bonetool is not registered, and NOTHING is printed at all', function()
    local ctx = buildEnv({ featureFlag = false, convarValue = 0 })
    startResource(ctx)
    t.isNil(ctx.registeredCommands.k9bonetool, 'k9bonetool must not be registered when the feature flag is false')
    t.equals(#ctx.printedLines, 0, 'a default install with the flag off must produce zero console output from this file')
end)

t.test('flag OFF, convar SET to 1: k9bonetool is still not registered, and still nothing is printed', function()
    local ctx = buildEnv({ featureFlag = false, convarValue = 1 })
    startResource(ctx)
    t.isNil(ctx.registeredCommands.k9bonetool, 'the convar alone must never register the command -- the feature flag gates first')
    t.equals(#ctx.printedLines, 0, 'the flag being off must stay silent even if an operator has already set the convar (e.g. ahead of flipping the flag on later)')
end)

-- ======================================================================
-- SCENARIO B: flag = true, convar UNSET (defaults to 0 via GetConvarInt's
-- own default argument) -- the exact "all 40 Config.Features flags flipped
-- true at once, nobody touched server.cfg" scenario this second opt-in
-- exists to catch.
-- ======================================================================

t.test('flag ON, convar UNSET: k9bonetool is NOT registered, and exactly one calm note names the convar', function()
    local ctx = buildEnv({ featureFlag = true, convarValue = 0 })
    startResource(ctx)
    t.isNil(ctx.registeredCommands.k9bonetool, 'the flag alone must never register the command -- the convar is a required second opt-in')
    t.equals(#ctx.printedLines, 1, 'exactly one line, not silence and not a flood')
    -- The flag ships on, so this is the normal live-server state: a note
    -- that says so, never a WARNING the owner thinks they must fix.
    t.notContains(ctx.printedLines[1], 'WARNING')
    t.contains(ctx.printedLines[1], 'nothing to do')
    t.contains(ctx.printedLines[1], BONE_DEV_TOOL_ENABLE_CONVAR, 'the note must name the exact convar an operator needs to set')
    t.contains(ctx.printedLines[1], 'OFF')
    t.notContains(ctx.printedLines[1], 'dev-only bone-index sweep tool registered', 'this must be the not-registered warning, never the success line')
end)

-- ======================================================================
-- SCENARIO C: flag = true, convar = 1 -- both LAYER 1 conditions satisfied.
-- k9bonetool registers, and LAYER 2 (per-invocation job-rank authorization)
-- plus the NO-UNBOUNDED-TRAP 'stop' exemption are exercised against it.
-- ======================================================================

-- citizenid is required this pass for IsBoneSweepDevToolPermittedForCitizenId
-- (server/bonetool.lua's own PER-PERSON FEATURE CONTROL check, mirroring
-- every other block/grant-supporting file's own fixture convention, e.g.
-- pursuitsprint_spec.lua's 'K9-CID') -- without one, an otherwise-authorized
-- caller would be denied for failing to resolve a citizenid at all, never
-- reaching the (correctly permissive, since HasPermission is not stubbed in
-- this sandbox) block/grant resolution itself.
local bossInConfiguredDept = { PlayerData = { citizenid = 'BONE-BOSS-CID', job = { name = 'police', isboss = true,  grade = { level = 1 } } } }
local seniorNonBoss        = { PlayerData = { job = { name = 'police', isboss = false, grade = { level = 10 } } } } -- HIGH grade, NOT boss -- must still be denied (no numeric-grade branch)
local bossInUnconfiguredJob = { PlayerData = { job = { name = 'mechanic', isboss = true, grade = { level = 1 } } } } -- boss of a job that isn't a configured K9 department
local playerWithNoJob      = { PlayerData = {} } -- job entirely absent -- fail closed, never throw

local SRC_BOSS        = 7001
local SRC_SENIOR      = 7002
local SRC_WRONG_JOB   = 7003
local SRC_NO_JOB      = 7004
local SRC_UNRESOLVED  = 7005 -- GetPlayer(source) resolves to nil entirely -- no entry in playersBySource at all
local SRC_CONSOLE     = 0

local ctx = buildEnv({
    featureFlag = true,
    convarValue = 1,
    playersBySource = {
        [SRC_BOSS]      = bossInConfiguredDept,
        [SRC_SENIOR]    = seniorNonBoss,
        [SRC_WRONG_JOB] = bossInUnconfiguredJob,
        [SRC_NO_JOB]    = playerWithNoJob,
    },
})
startResource(ctx)

t.isNotNil(ctx.registeredCommands.k9bonetool, 'onResourceStart must register k9bonetool when BOTH the flag and the convar are satisfied')
t.equals(#ctx.printedLines, 1, 'exactly the success line, no warning')
t.contains(ctx.printedLines[1], 'registered')
t.notContains(ctx.printedLines[1], 'WARNING')

ctx.setNow(1000)

t.test('unresolved player record (GetPlayer returns nil): goto is denied, not_authorized notify, no client dispatch', function()
    ctx.registeredCommands.k9bonetool(SRC_UNRESOLVED, { 'goto', '5' })
    local notify = lastEventNamed(ctx.capturedEvents, 'ox_lib:notify')
    t.isNotNil(notify, 'a denial must still notify the caller')
    t.equals(notify[2], SRC_UNRESOLVED)
    t.equals(notify[3].type, 'error')
    t.isNil(lastEventNamed(ctx.capturedEvents, 'qbx_k9unit:client:boneToolCommand'), 'an unauthorized goto must never reach the client')
end)

t.test('boss in a configured K9 department: goto is authorized and the index is clamped to MaxBoneIndex', function()
    ctx.registeredCommands.k9bonetool(SRC_BOSS, { 'goto', '999' })
    local dispatched = lastEventNamed(ctx.capturedEvents, 'qbx_k9unit:client:boneToolCommand')
    t.isNotNil(dispatched)
    t.equals(dispatched[2], SRC_BOSS)
    t.equals(dispatched[3], 'goto')
    t.equals(dispatched[4], 200, 'must clamp to Config.BoneSweepTool.MaxBoneIndex, not forward the raw 999')
end)

t.test('goto immediately again from the SAME source is blocked by the shared per-source cooldown', function()
    local before = countEventsNamed(ctx.capturedEvents, 'qbx_k9unit:client:boneToolCommand')
    ctx.registeredCommands.k9bonetool(SRC_BOSS, { 'goto', '1' })
    local after = countEventsNamed(ctx.capturedEvents, 'qbx_k9unit:client:boneToolCommand')
    t.equals(after, before, 'still within CommandCooldownMs of the previous call from this same source -- nothing new dispatched')
end)

t.test("'stop' from an AUTHORIZED source is ALSO gated by the SAME shared cooldown bucket as its own immediately-prior goto -- the NO-UNBOUNDED-TRAP bypass exempts authorization only, never the anti-spam cooldown", function()
    -- Still now=1000, same instant as the two calls above (cooldown[SRC_BOSS]
    -- was last stamped at 1000 by the very first 'goto 999' call) -- so this
    -- 'stop' call must be blocked too, exactly like the immediate repeat
    -- 'goto' just above it, proving the bypass added for 'stop' does not
    -- also silently exempt it from the cooldown.
    local before = countEventsNamed(ctx.capturedEvents, 'qbx_k9unit:client:boneToolCommand')
    ctx.registeredCommands.k9bonetool(SRC_BOSS, { 'stop' })
    local after = countEventsNamed(ctx.capturedEvents, 'qbx_k9unit:client:boneToolCommand')
    t.equals(after, before, 'an authorized caller\'s own stop is still throttled by the same per-source cooldown bucket their prior goto just touched')
end)

t.test('a HIGH-GRADE but non-boss officer in a configured department is DENIED -- no numeric-grade fallback exists for this tool', function()
    ctx.registeredCommands.k9bonetool(SRC_SENIOR, { 'goto', '5' })
    local notify = lastEventNamed(ctx.capturedEvents, 'ox_lib:notify')
    t.isNotNil(notify)
    t.equals(notify[2], SRC_SENIOR)
    t.equals(notify[3].type, 'error')
end)

t.test('a boss of a job that is not a configured Config.Departments key is DENIED', function()
    local before = countEventsNamed(ctx.capturedEvents, 'qbx_k9unit:client:boneToolCommand')
    ctx.registeredCommands.k9bonetool(SRC_WRONG_JOB, { 'goto', '5' })
    local after = countEventsNamed(ctx.capturedEvents, 'qbx_k9unit:client:boneToolCommand')
    t.equals(after, before, 'an unconfigured department must never authorize this tool, isboss or not')
end)

t.test('a player record with no job table at all fails closed rather than throwing', function()
    local ok = pcall(ctx.registeredCommands.k9bonetool, SRC_NO_JOB, { 'goto', '5' })
    t.isTrue(ok, 'a missing job must never raise -- fail closed, same discipline as IsAuthorizedAdmin')
    local notify = lastEventNamed(ctx.capturedEvents, 'ox_lib:notify')
    t.equals(notify[2], SRC_NO_JOB)
    t.equals(notify[3].type, 'error')
end)

t.test('console (source == 0) is rejected for EVERY subcommand, including stop, and never dispatches anything', function()
    local beforeCommand = countEventsNamed(ctx.capturedEvents, 'qbx_k9unit:client:boneToolCommand')
    local beforePrints = #ctx.printedLines
    ctx.registeredCommands.k9bonetool(SRC_CONSOLE, { 'stop' })
    t.equals(countEventsNamed(ctx.capturedEvents, 'qbx_k9unit:client:boneToolCommand'), beforeCommand, 'console must never reach the stop bypass -- the source == 0 check runs first')
    t.equals(#ctx.printedLines, beforePrints + 1, 'console gets its own dedicated rejection print')
    t.contains(ctx.printedLines[#ctx.printedLines], 'console')
end)

-- ----------------------------------------------------------------------
-- NO UNBOUNDED TRAP: 'stop' must stay reachable for a caller who fails
-- IsAuthorizedBoneSweepDevTool entirely (SRC_UNRESOLVED has no player
-- record at all, and was already denied a 'goto' above without ever
-- touching its own cooldown bucket).
-- ----------------------------------------------------------------------

t.test("'stop' bypasses authorization entirely -- an unresolved/never-authorized caller can still clean up", function()
    ctx.registeredCommands.k9bonetool(SRC_UNRESOLVED, { 'stop' })
    local dispatched = lastEventNamed(ctx.capturedEvents, 'qbx_k9unit:client:boneToolCommand')
    t.isNotNil(dispatched)
    t.equals(dispatched[2], SRC_UNRESOLVED)
    t.equals(dispatched[3], 'stop')
    t.isNil(dispatched[4])
end)

t.test("'stop' still respects the per-source cooldown (anti-spam, never authorization) -- an immediate repeat is silently blocked", function()
    local before = countEventsNamed(ctx.capturedEvents, 'qbx_k9unit:client:boneToolCommand')
    ctx.registeredCommands.k9bonetool(SRC_UNRESOLVED, { 'stop' })
    local after = countEventsNamed(ctx.capturedEvents, 'qbx_k9unit:client:boneToolCommand')
    t.equals(after, before, 'the cooldown throttle still applies to stop -- it is not an unconditional bypass of everything')
end)

t.test("'stop' succeeds again once the cooldown window has elapsed -- the block above was temporary, never permanent", function()
    ctx.advance(1000) -- well past CommandCooldownMs (500)
    local before = countEventsNamed(ctx.capturedEvents, 'qbx_k9unit:client:boneToolCommand')
    ctx.registeredCommands.k9bonetool(SRC_UNRESOLVED, { 'stop' })
    local after = countEventsNamed(ctx.capturedEvents, 'qbx_k9unit:client:boneToolCommand')
    t.equals(after, before + 1)
end)

t.test("once its own cooldown window has elapsed, an authorized source's 'stop' succeeds normally (the earlier block was temporary, not a lockout)", function()
    -- now=2000 at this point (advanced by the previous test); SRC_BOSS's
    -- cooldown bucket was last stamped at 1000 by its own 'goto 999' call
    -- and was never re-stamped by either of the two blocked calls right
    -- after it -- elapsed is now 1000ms, comfortably past CommandCooldownMs
    -- (500), so this call is expected to succeed.
    local before = countEventsNamed(ctx.capturedEvents, 'qbx_k9unit:client:boneToolCommand')
    ctx.registeredCommands.k9bonetool(SRC_BOSS, { 'stop' })
    local after = countEventsNamed(ctx.capturedEvents, 'qbx_k9unit:client:boneToolCommand')
    t.equals(after, before + 1)
    local dispatched = lastEventNamed(ctx.capturedEvents, 'qbx_k9unit:client:boneToolCommand')
    t.equals(dispatched[2], SRC_BOSS)
    t.equals(dispatched[3], 'stop')
end)

t.test("an invalid/unknown subcommand from an authorized caller gets the usage error, never a client dispatch", function()
    ctx.advance(1000) -- clear SRC_BOSS's cooldown again (last touched at 2000 by the stop above)
    ctx.registeredCommands.k9bonetool(SRC_BOSS, { 'bogus' })
    local notify = lastEventNamed(ctx.capturedEvents, 'ox_lib:notify')
    t.isNotNil(notify)
    t.equals(notify[2], SRC_BOSS)
    t.equals(notify[3].type, 'error')
end)

t.test("'help' from an authorized caller returns the full usage text with type 'info', with no client dispatch", function()
    ctx.advance(1000)
    local beforeCommand = countEventsNamed(ctx.capturedEvents, 'qbx_k9unit:client:boneToolCommand')
    ctx.registeredCommands.k9bonetool(SRC_BOSS, { 'help' })
    local notify = lastEventNamed(ctx.capturedEvents, 'ox_lib:notify')
    t.isNotNil(notify)
    t.equals(notify[2], SRC_BOSS)
    t.equals(notify[3].type, 'info')
    t.equals(countEventsNamed(ctx.capturedEvents, 'qbx_k9unit:client:boneToolCommand'), beforeCommand, "'help' is handled entirely server-side, per this file's own EVENT CONTRACT")
end)

-- ======================================================================
-- SCENARIO D: PER-PERSON FEATURE CONTROL (IsBoneSweepDevToolPermittedForCitizenId,
-- server/bonetool.lua). Each test below builds its OWN fresh ctx (unlike
-- SCENARIO C's single shared ctx) since HasPermission/Config.FeatureControl
-- differ per test and this section does not need SCENARIO C's careful
-- shared-cooldown-timing choreography.
-- ======================================================================

local SRC_D = 8001
local D_CITIZENID = 'BONE-D-CID'
local dBoss = { PlayerData = { citizenid = D_CITIZENID, job = { name = 'police', isboss = true, grade = { level = 1 } } } }

--- @param opts table { featureControl: table?, hasPermissionFn: function? }
--- @return table ctx
local function buildScenarioDCtx(opts)
    local dctx = buildEnv({
        featureFlag = true,
        convarValue = 1,
        playersBySource = { [SRC_D] = dBoss },
        featureControl = opts.featureControl,
        hasPermissionFn = opts.hasPermissionFn,
    })
    startResource(dctx)
    return dctx
end

t.test('PER-PERSON: block.BoneSweepDevTool denies an otherwise-authorized (boss) caller, and burns NO command cooldown', function()
    local dctx = buildScenarioDCtx({
        hasPermissionFn = function(citizenid, key) return key == 'block.BoneSweepDevTool' and citizenid == D_CITIZENID end,
    })
    dctx.registeredCommands.k9bonetool(SRC_D, { 'goto', '5' })
    local notify = lastEventNamed(dctx.capturedEvents, 'ox_lib:notify')
    t.isNotNil(notify, 'a block must still produce the same not_authorized notify a rank failure would')
    t.equals(notify[2], SRC_D)
    t.equals(notify[3].type, 'error')
    t.equals(countEventsNamed(dctx.capturedEvents, 'qbx_k9unit:client:boneToolCommand'), 0)

    -- Cooldown must never be burned by a denied request -- an immediate
    -- retry (still blocked) proves nothing was consumed, only that the
    -- block itself denies every time.
    dctx.registeredCommands.k9bonetool(SRC_D, { 'goto', '5' })
    t.equals(countEventsNamed(dctx.capturedEvents, 'qbx_k9unit:client:boneToolCommand'), 0)
end)

t.test('PER-PERSON: not blocked and not listed in RequireGrant -- default ALLOW (step 4), matching config.lua\'s documented default', function()
    local dctx = buildScenarioDCtx({
        hasPermissionFn = function() return false end,
    })
    dctx.registeredCommands.k9bonetool(SRC_D, { 'goto', '5' })
    t.equals(countEventsNamed(dctx.capturedEvents, 'qbx_k9unit:client:boneToolCommand'), 1)
end)

t.test('PER-PERSON: RequireGrant.BoneSweepDevTool = true + no active feature.BoneSweepDevTool grant -- denied even though the rank check passes', function()
    local dctx = buildScenarioDCtx({
        featureControl = { RequireGrant = { BoneSweepDevTool = true } },
        hasPermissionFn = function() return false end,
    })
    dctx.registeredCommands.k9bonetool(SRC_D, { 'goto', '5' })
    local notify = lastEventNamed(dctx.capturedEvents, 'ox_lib:notify')
    t.isNotNil(notify)
    t.equals(notify[3].type, 'error')
    t.equals(countEventsNamed(dctx.capturedEvents, 'qbx_k9unit:client:boneToolCommand'), 0)
end)

t.test('PER-PERSON: RequireGrant.BoneSweepDevTool = true + an active feature.BoneSweepDevTool grant -- allowed', function()
    local dctx = buildScenarioDCtx({
        featureControl = { RequireGrant = { BoneSweepDevTool = true } },
        hasPermissionFn = function(citizenid, key) return key == 'feature.BoneSweepDevTool' and citizenid == D_CITIZENID end,
    })
    dctx.registeredCommands.k9bonetool(SRC_D, { 'goto', '5' })
    t.equals(countEventsNamed(dctx.capturedEvents, 'qbx_k9unit:client:boneToolCommand'), 1)
end)

t.test('PER-PERSON: server/permissions.lua entirely absent (HasPermission not even defined) + RequireGrant listed -- fails CLOSED, never open', function()
    local dctx = buildScenarioDCtx({
        featureControl = { RequireGrant = { BoneSweepDevTool = true } },
        -- hasPermissionFn deliberately omitted -- HasPermission stays undefined in this env
    })
    local ok = pcall(dctx.registeredCommands.k9bonetool, SRC_D, { 'goto', '5' })
    t.isTrue(ok, 'a missing HasPermission must never error the command handler')
    t.equals(countEventsNamed(dctx.capturedEvents, 'qbx_k9unit:client:boneToolCommand'), 0, 'RequireGrant-listed + unresolvable grant machinery must deny, not silently allow')
end)

t.test("PER-PERSON: NO UNBOUNDED TRAP -- 'stop' still works instantly for a caller who is now block.BoneSweepDevTool-blocked", function()
    local dctx = buildScenarioDCtx({
        hasPermissionFn = function(citizenid, key) return key == 'block.BoneSweepDevTool' and citizenid == D_CITIZENID end,
    })
    -- 'goto' is denied (proves the block is genuinely active for this caller)...
    dctx.registeredCommands.k9bonetool(SRC_D, { 'goto', '5' })
    t.equals(countEventsNamed(dctx.capturedEvents, 'qbx_k9unit:client:boneToolCommand'), 0)

    -- ...but 'stop' -- this tool's only termination/cleanup path -- must
    -- still dispatch, exactly like SCENARIO C's identical proof against a
    -- rank failure: a block on STARTING the tool must never strand someone
    -- who already has a preview marker/test prop attached with no way to
    -- remove it.
    dctx.registeredCommands.k9bonetool(SRC_D, { 'stop' })
    local dispatched = lastEventNamed(dctx.capturedEvents, 'qbx_k9unit:client:boneToolCommand')
    t.isNotNil(dispatched)
    t.equals(dispatched[2], SRC_D)
    t.equals(dispatched[3], 'stop')
end)

-- ======================================================================
-- CONFIG-ABORT REGRESSION (this pass): every INDIVIDUAL Config.BoneSweepTool
-- field used to be a bare per-field `assert` inside this SAME
-- onResourceStart handler, and RegisterCommand('k9bonetool') sits AFTER all
-- of them, in that same handler -- so one malformed field used to silently
-- remove the command entirely for the whole session. A malformed value must
-- now warn and fall back instead of throwing, and k9bonetool must still
-- register and actually work off the substituted safe values.
-- ======================================================================

t.test('CONFIG-ABORT REGRESSION: a malformed CommandCooldownMs (the exact footgun the old assert caught) now warns and clamps to the built-in fallback instead of throwing', function()
    local regressionCtx = buildEnv({ featureFlag = true, convarValue = 1 })
    regressionCtx.env.Config.BoneSweepTool.CommandCooldownMs = 0 -- 0 does NOT mean "no cooldown" here -- see this file's own comment
    local ok, err = pcall(startResource, regressionCtx)
    t.isTrue(ok, 'onResourceStart must not throw: ' .. tostring(err))
    t.isNotNil(regressionCtx.registeredCommands.k9bonetool, 'k9bonetool must still be registered despite the malformed CommandCooldownMs')
    t.equals(regressionCtx.env.Config.BoneSweepTool.CommandCooldownMs, 500, 'must be forced to the built-in fallback (config.lua\'s own shipped default)')

    local warned = false
    for _, line in ipairs(regressionCtx.printedLines) do
        if line:find('CommandCooldownMs', 1, true) then warned = true end
    end
    t.isTrue(warned, 'a malformed CommandCooldownMs must print a warning naming it')
end)

t.test('CONFIG-ABORT REGRESSION: a malformed TestPropModel/MaxBoneIndex/TestOffsetX all warn and fall back, and k9bonetool still registers and actually dispatches off the corrected values', function()
    local regressionCtx = buildEnv({ featureFlag = true, convarValue = 1 })
    regressionCtx.env.Config.BoneSweepTool.TestPropModel = '' -- empty string, invalid
    regressionCtx.env.Config.BoneSweepTool.MaxBoneIndex = -5 -- must be >= 0
    regressionCtx.env.Config.BoneSweepTool.TestOffsetX = 'oops' -- not a number

    local ok, err = pcall(startResource, regressionCtx)
    t.isTrue(ok, 'onResourceStart must not throw: ' .. tostring(err))
    t.isNotNil(regressionCtx.registeredCommands.k9bonetool, 'k9bonetool must still be registered despite three malformed fields')

    t.equals(regressionCtx.env.Config.BoneSweepTool.TestPropModel, 'prop_tennis_ball', 'TestPropModel must fall back to config.lua\'s own shipped default')
    t.equals(regressionCtx.env.Config.BoneSweepTool.MaxBoneIndex, 200, 'MaxBoneIndex must fall back to config.lua\'s own shipped default')
    t.equals(regressionCtx.env.Config.BoneSweepTool.TestOffsetX, 0.0, 'TestOffsetX must fall back to 0.0')

    for _, key in ipairs({ 'TestPropModel', 'MaxBoneIndex', 'TestOffsetX' }) do
        local warned = false
        for _, line in ipairs(regressionCtx.printedLines) do
            if line:find(key, 1, true) then warned = true end
        end
        t.isTrue(warned, ('a malformed %s must print a warning naming it'):format(key))
    end

    -- k9bonetool must actually WORK end to end off the corrected values --
    -- clamp-and-warn means "still functions", not merely "does not crash at
    -- boot". A boss in a configured department requesting an out-of-range
    -- index must clamp to the CORRECTED MaxBoneIndex (200), not the
    -- malformed -5 (which would otherwise floor every requested index to
    -- itself and break the tool for every caller).
    regressionCtx.env.Config.Departments = { police = { label = 'Los Santos Police Department', certifierGrade = 4, auditGrade = 4 } }
    local playersBySource = { [1] = { PlayerData = { citizenid = 'REGRESSION1', job = { name = 'police', isboss = true, grade = { level = 0 } } } } }
    regressionCtx.env.exports.qbx_core.GetPlayer = function(_self, source) return playersBySource[source] end
    regressionCtx.registeredCommands.k9bonetool(1, { 'goto', '999' })
    local dispatched = lastEventNamed(regressionCtx.capturedEvents, 'qbx_k9unit:client:boneToolCommand')
    t.isNotNil(dispatched, 'a boss must still be able to run k9bonetool off the corrected config')
    t.equals(dispatched[4], 200, 'must clamp to the CORRECTED MaxBoneIndex (200), not the malformed -5')
end)

os.exit(t.summary())
