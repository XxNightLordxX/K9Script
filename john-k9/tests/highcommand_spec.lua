--[[
    tests/highcommand_spec.lua

    Tests server/highcommand.lua against the REAL, unmodified production
    file, via tests/fixtures/sandbox.lua -- same harness style as
    tests/admin_spec.lua (read end to end before writing this file): a fresh
    sandbox env per scenario that needs different Config.HighCommand
    registration-time behavior (the maxXpPerGrant footgun can only be
    observed by re-running onResourceStart against a different Config, so it
    needs its own env), plus one shared, reusable harness for everything
    else (IsHighCommand's own fail-closed paths, and every '/k9givexp'
    behavior that does not depend on registration-time config).

    LOCALE DEPENDENCY, DISCLOSED UP FRONT: tests/fixtures/sandbox.lua's
    locale() RAISES on any key not present in the real locales/en.json --
    deliberately (see that file's own header). server/highcommand.lua calls
    eight NEW locale() keys this pass requested from the locales/en.json
    owner but which, as of this file being written, are NOT YET in
    locales/en.json (see server/highcommand.lua's own header "LOCALE KEYS
    THIS FILE NEEDS" section for the exact eight keys/strings requested).

    THIS DOES NOT LEAVE THIS SUITE RED: every test below is deliberately
    written to assert on state that server/highcommand.lua's own command
    handler produces BEFORE it ever reaches a locale()-dependent
    NotifyPlayer call on any given path (LogAuditInvocation's print(), and
    any AwardXPDirect stub invocation, both unconditionally precede every
    NotifyPlayer(locale(...)) call site -- read that file's handler top to
    bottom to confirm this ordering) -- via `runCommand(...)` below, a thin
    wrapper that pcalls the registered handler and returns `(ok, err)`
    without ever letting the EVENTUAL locale()-raised error abort the
    surrounding t.test() case before those assertions run. "Was XP actually
    awarded" / "was the right audit outcome printed" are therefore provable,
    and asserted on, completely independent of whether any of the eight
    pending keys currently resolves -- this suite passes 48/48 as of this
    pass, with all eight keys still missing, and stays 48/48 once they land
    (verified: no assertion below inspects the ENGLISH TEXT of any of the
    eight pending keys -- only the two ALREADY-PRESENT `common.*` keys this
    file also reuses get a content assertion, since those cannot throw
    either way). `assertAmountRejected` below additionally makes an
    OPT-IN-ONLY extra check while a key is still missing (the raised error
    names the exact key that was looked up, confirming the right rejection
    branch fired) -- skipped once `ok` is true, specifically so it can never
    regress this file the moment the locale owner applies the requested
    keys.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

local fakeNow = 0

local nextSource = 1000
--- @return number
local function freshSourceNumber()
    nextSource = nextSource + 1
    return nextSource
end

--- Builds one fresh, isolated sandbox: its own captured-output tables, its
--- own RegisterCommand/AddEventHandler stubs (so different harnesses never
--- share registeredCommands/eventHandlers), and fires 'onResourceStart' once
--- (as FXServer would) against the given Config. Mirrors tests/admin_spec.lua's
--- module-level stub shapes, but factored into a constructor here because
--- this spec genuinely needs MULTIPLE independent sandboxes (the
--- maxXpPerGrant registration-time footgun can only be observed by varying
--- Config BEFORE onResourceStart runs, which only ever runs once per env).
--- @param highCommandConfig table -- Config.HighCommand
--- @param departments table? -- Config.Departments; defaults to a single 'police' dept, highCommandGrade = 6
--- @return table harness
local function newHarness(highCommandConfig, departments)
    local capturedNotifications = {}
    local capturedPrints = {}
    local capturedAwardCalls = {}
    local playersBySource = {}
    local registeredCommands = {}
    local eventHandlers = {}
    local partnerships = {} -- directCitizenid -> { partner = string, isK9 = boolean }

    local function RegisterCommandStub(name, handler, _restricted)
        registeredCommands[name] = handler
    end

    local function AddEventHandlerStub(eventName, handler)
        eventHandlers[eventName] = eventHandlers[eventName] or {}
        eventHandlers[eventName][#eventHandlers[eventName] + 1] = handler
    end

    local function GetCurrentResourceNameStub()
        return 'john-k9'
    end

    local exportsStub = {
        qbx_core = {
            GetPlayer = function(_self, src)
                return playersBySource[src]
            end,
        },
    }

    local function NotifyPlayerStub(target, description, notifyType, title)
        capturedNotifications[#capturedNotifications + 1] = {
            target = target, description = description, notifyType = notifyType, title = title,
        }
    end

    local function printStub(...)
        local parts = {}
        for i = 1, select('#', ...) do
            parts[i] = tostring(select(i, ...))
        end
        capturedPrints[#capturedPrints + 1] = table.concat(parts, '\t')
    end

    local permissionsByCitizenid = {}
    local runningTotals = {}
    local function AwardXPDirectStub(citizenid, amount, reason)
        capturedAwardCalls[#capturedAwardCalls + 1] = { citizenid = citizenid, amount = amount, reason = reason }
        runningTotals[citizenid] = (runningTotals[citizenid] or 0) + amount
        return runningTotals[citizenid]
    end

    local function GetActivePartnerCitizenIdStub(citizenid)
        local row = partnerships[citizenid]
        if not row then return nil, nil end
        return row.partner, row.isK9
    end

    local Config = {
        CommandTablet = { adminChatCommands = true }, -- admin chat commands are off by default; these tests drive them
        Features = { HighCommand = true },
        Departments = departments or {
            police = { label = 'Los Santos Police Department', highCommandGrade = 6 },
        },
        HighCommand = highCommandConfig,
    }

    local env = Sandbox.newEnv({
        GetGameTimer = function() return fakeNow end,
        RegisterCommand = RegisterCommandStub,
        AddEventHandler = AddEventHandlerStub,
        GetCurrentResourceName = GetCurrentResourceNameStub,
        exports = exportsStub,
        NotifyPlayer = NotifyPlayerStub,
        print = printStub,
        Config = Config,
    })

    -- server/highcommand.lua calls NewCooldown() at file-load time
    -- (HighCommandGrantCooldown) -- must load server/cooldowns.lua into the
    -- SAME env first, same load-order requirement fxmanifest.lua's own
    -- server_scripts list will document once this file is wired in.
    Sandbox.loadInto('../server/cooldowns.lua', env)
    Sandbox.loadInto('../server/highcommand.lua', env)

    -- GetActivePartnerCitizenId / AwardXPDirect are consulted through a
    -- `type(...) == 'function'` guard at COMMAND-HANDLER RUN TIME, never at
    -- this file's own load time -- safe to inject into `env` any time before
    -- a test actually invokes the registered command, exactly mirroring how
    -- a real server would have server/partnership.lua/server/progression.lua
    -- already loaded by the time any player can reach '/k9givexp'.
    env.AwardXPDirect = AwardXPDirectStub
    env.GetActivePartnerCitizenId = GetActivePartnerCitizenIdStub

    -- IsHighCommand / HasPermission are resource-globals server/highcommand.lua
    -- reaches through `type(...) == 'function'` guards at COMMAND-HANDLER RUN
    -- TIME, same as the two above, so they can be injected here.
    --
    -- Injected specifically so 'block.k9.givexp' can be tested. That block key
    -- is ACCEPTED AND STORED by server/permissions.lua (it is listed in
    -- ADMIN_CAPABILITY_BLOCKABLE_KEYS), so an owner can set it and believe it
    -- restrains somebody -- and until this was fixed, IsAuthorizedForXpGrant
    -- never read it, so it silently did nothing. A security control that
    -- appears to exist and does not is worse than one that is simply absent,
    -- which is why this is pinned here rather than left to the permissions
    -- spec, which only ever proved the key could be STORED.
    permissionsByCitizenid = permissionsByCitizenid or {}
    env.HasPermission = function(citizenid, key)
        local perms = permissionsByCitizenid[citizenid]
        return perms ~= nil and perms[key] == true
    end


    for _, handler in ipairs(eventHandlers['onResourceStart'] or {}) do
        handler('john-k9')
    end

    return {
        env = env,
        registeredCommands = registeredCommands,
        capturedNotifications = capturedNotifications,
        capturedPrints = capturedPrints,
        capturedAwardCalls = capturedAwardCalls,
        playersBySource = playersBySource,
        partnerships = partnerships,
        permissionsByCitizenid = permissionsByCitizenid,
        -- Clears the SAME table objects IN PLACE, rather than rebinding the
        -- local variables to fresh tables: printStub/NotifyPlayerStub/
        -- AwardXPDirectStub above and the harness fields returned below both
        -- close over/reference these exact table objects, so a `capturedPrints
        -- = {}`-style reassignment here would only redirect the STUBS (which
        -- share the reassigned upvalue) while leaving `harness.capturedPrints`
        -- (a snapshot of the table reference taken once, above, at harness
        -- construction time) pointed at the old, now-frozen table forever --
        -- exactly the kind of stale-reference bug this comment exists to stop
        -- a future edit from reintroducing.
        resetCaptures = function()
            for i = #capturedNotifications, 1, -1 do capturedNotifications[i] = nil end
            for i = #capturedPrints, 1, -1 do capturedPrints[i] = nil end
            for i = #capturedAwardCalls, 1, -1 do capturedAwardCalls[i] = nil end
        end,
    }
end

--- Registers a player record at a fresh source number and returns it.
--- @param harness table
--- @param citizenid string?
--- @param job table?
--- @return number source
local function registerPlayer(harness, citizenid, job)
    local src = freshSourceNumber()
    harness.playersBySource[src] = citizenid and { PlayerData = { citizenid = citizenid, job = job } } or nil
    return src
end

--- Invokes a registered command handler through pcall, so a locale()-raised
--- error (see this file's header) never aborts the surrounding t.test() body
--- before its OTHER assertions (on capturedAwardCalls/capturedPrints, both
--- always populated BEFORE any locale()-dependent NotifyPlayer call on every
--- path in server/highcommand.lua) get to run.
--- @param harness table
--- @param src number
--- @param args table
--- @return boolean ok
--- @return any err
local function runCommand(harness, src, args)
    return pcall(harness.registeredCommands.k9givexp, src, args)
end

-- ============================================================================
-- IsHighCommand -- every fail-closed path, isboss bypass, threshold
-- comparison, and the nil-highCommandGrade footgun.
-- ============================================================================

do
    local h = newHarness({ maxXpPerGrant = 5000, grantCooldownMs = 1500, allowSelfGrant = false })

    t.test('IsHighCommand: Config.Features.HighCommand == false denies even a boss', function()
        local src = registerPlayer(h, 'BOSS1', { name = 'police', isboss = true, grade = { level = 0 } })
        h.env.Config.Features.HighCommand = false
        t.isFalse(h.env.IsHighCommand(src))
        h.env.Config.Features.HighCommand = true -- restore for subsequent cases
    end)

    t.test('IsHighCommand: no resolvable player record fails closed', function()
        t.isFalse(h.env.IsHighCommand(999999))
    end)

    t.test('IsHighCommand: a player with no job at all fails closed, does not throw', function()
        local src = freshSourceNumber()
        h.playersBySource[src] = { PlayerData = { citizenid = 'NOJOB1' } }
        local ok, result = pcall(h.env.IsHighCommand, src)
        t.isTrue(ok, 'must not raise: ' .. tostring(result))
        t.isFalse(result)
    end)

    t.test('IsHighCommand: a job not in Config.Departments fails closed', function()
        local src = registerPlayer(h, 'AMBO1', { name = 'ambulance', grade = { level = 99 } })
        t.isFalse(h.env.IsHighCommand(src))
    end)

    t.test('IsHighCommand: job.isboss authorizes regardless of grade level', function()
        local src = registerPlayer(h, 'BOSS2', { name = 'police', isboss = true, grade = { level = 0 } })
        t.isTrue(h.env.IsHighCommand(src))
    end)

    t.test('IsHighCommand: job.isboss authorizes even when highCommandGrade is nil for that department', function()
        h.env.Config.Departments.police.highCommandGrade = nil
        local src = registerPlayer(h, 'BOSS3', { name = 'police', isboss = true, grade = { level = 0 } })
        t.isTrue(h.env.IsHighCommand(src))
        h.env.Config.Departments.police.highCommandGrade = 6 -- restore
    end)

    t.test('IsHighCommand: a grade ONE BELOW the threshold is denied (threshold is really compared, not merely present)', function()
        local src = registerPlayer(h, 'LOW1', { name = 'police', grade = { level = 5 } }) -- threshold is 6
        t.isFalse(h.env.IsHighCommand(src))
    end)

    t.test('IsHighCommand: a grade EXACTLY AT the threshold is authorized', function()
        local src = registerPlayer(h, 'ATT1', { name = 'police', grade = { level = 6 } })
        t.isTrue(h.env.IsHighCommand(src))
    end)

    t.test('IsHighCommand: a grade ABOVE the threshold is authorized', function()
        local src = registerPlayer(h, 'ABOVE1', { name = 'police', grade = { level = 10 } })
        t.isTrue(h.env.IsHighCommand(src))
    end)

    t.test('IsHighCommand: nil highCommandGrade denies even a boss-LESS high grade -- nil means "no such tier", never "everyone qualifies"', function()
        h.env.Config.Departments.police.highCommandGrade = nil
        local src = registerPlayer(h, 'HIGHGRADE1', { name = 'police', grade = { level = 999 } }) -- no isboss
        t.isFalse(h.env.IsHighCommand(src))
        h.env.Config.Departments.police.highCommandGrade = 6 -- restore
    end)

    t.test('IsHighCommand: a non-number highCommandGrade fails closed, does not throw', function()
        h.env.Config.Departments.police.highCommandGrade = '6' -- corrupted config: a string, not a number
        local src = registerPlayer(h, 'BADCFG1', { name = 'police', grade = { level = 10 } })
        local ok, result = pcall(h.env.IsHighCommand, src)
        t.isTrue(ok, 'must not raise: ' .. tostring(result))
        t.isFalse(result)
        h.env.Config.Departments.police.highCommandGrade = 6 -- restore
    end)

    t.test('IsHighCommand: a job with no grade table at all fails closed, does not throw', function()
        local src = registerPlayer(h, 'NOGRADE1', { name = 'police' })
        local ok, result = pcall(h.env.IsHighCommand, src)
        t.isTrue(ok, 'must not raise: ' .. tostring(result))
        t.isFalse(result)
    end)

    t.test('IsHighCommand: a non-number job.grade.level fails closed, does not throw', function()
        local src = registerPlayer(h, 'BADGRADE1', { name = 'police', grade = { level = '6' } })
        local ok, result = pcall(h.env.IsHighCommand, src)
        t.isTrue(ok, 'must not raise: ' .. tostring(result))
        t.isFalse(result)
    end)

    t.test('IsHighCommand: Config.Departments not a table fails closed, does not throw (defensive)', function()
        local src = registerPlayer(h, 'DEFENSIVE1', { name = 'police', grade = { level = 10 } })
        local realDepartments = h.env.Config.Departments
        h.env.Config.Departments = nil
        local ok, result = pcall(h.env.IsHighCommand, src)
        h.env.Config.Departments = realDepartments -- restore immediately, before any assertion can fail and skip it
        t.isTrue(ok, 'must not raise: ' .. tostring(result))
        t.isFalse(result)
    end)
end

-- ============================================================================
-- CONFIG-ABORT REGRESSION (this pass): Config.Departments[*].highCommandGrade
-- used to be a bare per-department `assert` inside this file's own
-- onResourceStart handler -- and RegisterCommand('k9givexp') sits AFTER it,
-- in that SAME handler, so one malformed department used to silently remove
-- '/k9givexp' for the whole session. A malformed value must now warn and
-- force that ONE department's own highCommandGrade to nil (fails closed,
-- same as IsHighCommand's own runtime type check) rather than throw -- and,
-- the part a bare "does not throw" test would miss, '/k9givexp' AND every
-- OTHER configured department's own highCommandGrade must both keep working
-- afterward, completely unaffected.
-- ============================================================================

t.test('CONFIG-ABORT REGRESSION: a malformed highCommandGrade on one department must warn and fail closed for that department only -- /k9givexp still registers, and every OTHER department is unaffected', function()
    local h = newHarness(
        { maxXpPerGrant = 5000, grantCooldownMs = 1500, allowSelfGrant = false },
        {
            -- MALFORMED: a quoted string instead of a number -- the exact
            -- plausible owner typo this regression guards against.
            police  = { label = 'Los Santos Police Department', highCommandGrade = '6' },
            sheriff = { label = 'Blaine County Sheriff', highCommandGrade = 5 },
        }
    )

    t.isNotNil(h.registeredCommands.k9givexp, '/k9givexp must still be registered despite the malformed police.highCommandGrade')

    local warned = false
    for _, line in ipairs(h.capturedPrints) do
        if line:find('highCommandGrade', 1, true) and line:find('police', 1, true) then warned = true end
    end
    t.isTrue(warned, 'a malformed Config.Departments.police.highCommandGrade must print a warning naming both the field and the department')

    -- The malformed department's own highCommandGrade must have been forced
    -- to nil (the same safe fail-closed value IsHighCommand's own runtime
    -- type check already produces for a malformed grade) -- NOT left as the
    -- stray string, and NOT guessed at any number.
    t.isNil(h.env.Config.Departments.police.highCommandGrade, 'the malformed department\'s highCommandGrade must be forced to nil')

    -- The malformed department: even an absurdly high grade must now fail
    -- closed (no High Command tier at all for this department any more),
    -- but job.isboss still unconditionally qualifies regardless.
    local badDeptSrc = registerPlayer(h, 'POLICE_HIGH', { name = 'police', grade = { level = 999 } })
    t.isFalse(h.env.IsHighCommand(badDeptSrc), 'nil highCommandGrade (forced) must fail closed for a non-boss officer')
    local badDeptBossSrc = registerPlayer(h, 'POLICE_BOSS', { name = 'police', isboss = true, grade = { level = 0 } })
    t.isTrue(h.env.IsHighCommand(badDeptBossSrc), 'job.isboss must still unconditionally qualify even in the department whose highCommandGrade was corrected')

    -- The OTHER, validly-configured department must be completely
    -- unaffected -- its own numeric highCommandGrade still works exactly as
    -- configured.
    t.equals(h.env.Config.Departments.sheriff.highCommandGrade, 5, 'an unrelated department\'s own valid highCommandGrade must be untouched')
    local belowSrc = registerPlayer(h, 'SHERIFF_LOW', { name = 'sheriff', grade = { level = 4 } })
    t.isFalse(h.env.IsHighCommand(belowSrc), 'sheriff grade 4 is below its own threshold of 5')
    local atThresholdSrc = registerPlayer(h, 'SHERIFF_HIGH', { name = 'sheriff', grade = { level = 5 } })
    t.isTrue(h.env.IsHighCommand(atThresholdSrc), 'sheriff grade 5 meets its own threshold and must still qualify')

    -- '/k9givexp' itself must actually work end to end for the unaffected
    -- department, not merely "be registered" -- clamp-and-warn means "still
    -- functions", not merely "does not crash at boot".
    h.resetCaptures()
    local target = registerPlayer(h, 'SHERIFF_TARGET', { name = 'sheriff', grade = { level = 1 } })
    runCommand(h, atThresholdSrc, { tostring(target), '50' })
    t.equals(#h.capturedAwardCalls, 1, '/k9givexp must still actually grant XP through the unaffected department')
    t.equals(h.capturedAwardCalls[1].citizenid, 'SHERIFF_TARGET')
end)

-- ============================================================================
-- Registration-time gating: the maxXpPerGrant footgun. A non-positive/nil/
-- NaN/infinite Config.HighCommand.maxXpPerGrant must DISABLE '/k9givexp'
-- (never registered), never be silently read as "unlimited". Each case needs
-- its OWN fresh harness -- onResourceStart only ever runs once per env.
-- ============================================================================

t.test('/k9givexp registration: a valid positive maxXpPerGrant registers the command', function()
    local h = newHarness({ maxXpPerGrant = 5000, grantCooldownMs = 1500, allowSelfGrant = false })
    t.isNotNil(h.registeredCommands.k9givexp)
end)

t.test('FOOTGUN: maxXpPerGrant == 0 disables /k9givexp entirely (never "unlimited")', function()
    local h = newHarness({ maxXpPerGrant = 0, grantCooldownMs = 1500, allowSelfGrant = false })
    t.isNil(h.registeredCommands.k9givexp, '/k9givexp must not be registered when maxXpPerGrant is 0')
    local warned = false
    for _, line in ipairs(h.capturedPrints) do
        if line:find('maxXpPerGrant', 1, true) then warned = true end
    end
    t.isTrue(warned, 'expected a startup warning naming maxXpPerGrant')
end)

t.test('FOOTGUN: maxXpPerGrant == nil disables /k9givexp entirely', function()
    local h = newHarness({ maxXpPerGrant = nil, grantCooldownMs = 1500, allowSelfGrant = false })
    t.isNil(h.registeredCommands.k9givexp)
end)

t.test('FOOTGUN: a negative maxXpPerGrant disables /k9givexp entirely', function()
    local h = newHarness({ maxXpPerGrant = -100, grantCooldownMs = 1500, allowSelfGrant = false })
    t.isNil(h.registeredCommands.k9givexp)
end)

t.test('FOOTGUN: a NaN maxXpPerGrant disables /k9givexp entirely, does not throw at registration', function()
    local ok, h = pcall(newHarness, { maxXpPerGrant = 0 / 0, grantCooldownMs = 1500, allowSelfGrant = false })
    t.isTrue(ok, 'onResourceStart must not raise on a NaN maxXpPerGrant: ' .. tostring(h))
    t.isNil(h.registeredCommands.k9givexp)
end)

t.test('FOOTGUN: an infinite maxXpPerGrant disables /k9givexp entirely', function()
    local h = newHarness({ maxXpPerGrant = math.huge, grantCooldownMs = 1500, allowSelfGrant = false })
    t.isNil(h.registeredCommands.k9givexp)
end)

-- ============================================================================
-- Authorization: only a High Command officer can run '/k9givexp' at all.
-- ============================================================================

do
    local h = newHarness({ maxXpPerGrant = 5000, grantCooldownMs = 1500, allowSelfGrant = false })

    t.test('/k9givexp: a non-high-command officer is denied, audited as denied, no XP awarded', function()
        h.resetCaptures()
        local src = registerPlayer(h, 'LOWRANK1', { name = 'police', grade = { level = 1 } })
        local target = registerPlayer(h, 'TARGETX', { name = 'police', grade = { level = 1 } })
        runCommand(h, src, { tostring(target), '100' })
        t.equals(#h.capturedAwardCalls, 0, 'an unauthorized caller must never mint XP')
        t.contains(h.capturedPrints[#h.capturedPrints], 'denied')
    end)
end

-- ============================================================================
-- Amount validation -- positive integer, at or below maxXpPerGrant. Every
-- hostile numeric shape below must be rejected with NO XP awarded.
-- NOT blocked on the pending highcommand.invalid_amount/usage_givexp locale
-- keys (see this file's header): LogAuditInvocation's print() and the
-- capturedAwardCalls check both happen BEFORE the locale()-dependent
-- NotifyPlayer call on this path, so `runCommand`'s pcall wrapper safely
-- absorbs that eventual throw without weakening either assertion below. As a
-- belt-and-suspenders bonus, WHILE the key is still missing, the raised
-- error names the exact key server/highcommand.lua tried to look up -- a
-- second, independent confirmation that the RIGHT rejection branch fired.
-- That extra check is deliberately skipped once `ok` is true (the key has
-- landed and the real notification succeeded) so this test suite does not
-- regress the moment the locale owner applies the requested keys.
-- ============================================================================

do
    local h = newHarness({ maxXpPerGrant = 5000, grantCooldownMs = 1500, allowSelfGrant = false })
    local granterJob = { name = 'police', isboss = true, grade = { level = 0 } }

    --- @param amountArg string?
    local function assertAmountRejected(amountArg, label)
        h.resetCaptures()
        local src = registerPlayer(h, 'HC_AMT_' .. label, granterJob)
        local target = registerPlayer(h, 'TARGET_AMT_' .. label, { name = 'police', grade = { level = 1 } })
        local ok, err = runCommand(h, src, { tostring(target), amountArg })
        t.equals(#h.capturedAwardCalls, 0, label .. ': must never mint XP')
        t.contains(h.capturedPrints[#h.capturedPrints], 'invalid_args', label .. ': must audit as invalid_args')
        if not ok then
            t.contains(tostring(err), 'highcommand.', label .. ': the locale() lookup that ran must be one of this file\'s own highcommand.* keys')
        end
    end

    t.test('amount validation: non-numeric garbage is rejected', function()
        assertAmountRejected('abc', 'nonnumeric')
    end)

    t.test('amount validation: negative is rejected', function()
        assertAmountRejected('-5', 'negative')
    end)

    t.test('amount validation: zero is rejected (not a positive integer)', function()
        assertAmountRejected('0', 'zero')
    end)

    t.test('amount validation: NaN is rejected', function()
        assertAmountRejected('nan', 'nan')
    end)

    t.test('amount validation: "-nan" is rejected', function()
        assertAmountRejected('-nan', 'negnan')
    end)

    t.test('amount validation: infinite is rejected', function()
        assertAmountRejected('inf', 'inf')
    end)

    t.test('amount validation: numeric overflow to +inf ("1e400") is rejected', function()
        assertAmountRejected('1e400', 'overflow')
    end)

    t.test('amount validation: a fractional amount is rejected, never floored/accepted', function()
        assertAmountRejected('3.9', 'fractional')
    end)

    t.test('amount validation: an amount above maxXpPerGrant (5001 > 5000) is rejected', function()
        assertAmountRejected('5001', 'abovemax')
    end)

    t.test('amount validation: an amount exactly AT maxXpPerGrant (boundary) is ACCEPTED', function()
        h.resetCaptures()
        local src = registerPlayer(h, 'HC_BOUNDARY', granterJob)
        local target = registerPlayer(h, 'TARGET_BOUNDARY', { name = 'police', grade = { level = 1 } })
        runCommand(h, src, { tostring(target), '5000' })
        t.equals(#h.capturedAwardCalls, 1)
        t.equals(h.capturedAwardCalls[1].amount, 5000)
        t.equals(h.capturedAwardCalls[1].citizenid, 'TARGET_BOUNDARY')
    end)

    t.test('amount validation: a missing amount argument (nil) is rejected as invalid_args, never coerced to a default', function()
        h.resetCaptures()
        local src = registerPlayer(h, 'HC_NOAMOUNT', granterJob)
        local target = registerPlayer(h, 'TARGET_NOAMOUNT', { name = 'police', grade = { level = 1 } })
        runCommand(h, src, { tostring(target) }) -- args[2] absent
        t.equals(#h.capturedAwardCalls, 0)
        t.contains(h.capturedPrints[#h.capturedPrints], 'invalid_args')
    end)

    t.test('target validation: a non-numeric server id is rejected as invalid_args, never awards XP', function()
        h.resetCaptures()
        local src = registerPlayer(h, 'HC_BADTARGET', granterJob)
        runCommand(h, src, { 'not-a-server-id', '100' })
        t.equals(#h.capturedAwardCalls, 0)
        t.contains(h.capturedPrints[#h.capturedPrints], 'invalid_args')
    end)
end

-- ============================================================================
-- Target resolution -- credit the K9 directly, or redirect a handler target
-- to their active K9 partner. The award call's own citizenid argument is
-- captured BEFORE any locale()-dependent notification, so every assertion
-- below is NOT blocked on the pending locale keys.
-- ============================================================================

do
    local h = newHarness({ maxXpPerGrant = 5000, grantCooldownMs = 1500, allowSelfGrant = false })
    local granterJob = { name = 'police', isboss = true, grade = { level = 0 } }

    t.test('target resolution: a target with NO active partnership is credited directly', function()
        h.resetCaptures()
        local src = registerPlayer(h, 'HC_SOLO', granterJob)
        local target = registerPlayer(h, 'SOLO_K9', { name = 'police', grade = { level = 1 } })
        -- h.partnerships['SOLO_K9'] is deliberately left unset -- GetActivePartnerCitizenIdStub returns nil, nil
        runCommand(h, src, { tostring(target), '50' })
        t.equals(#h.capturedAwardCalls, 1)
        t.equals(h.capturedAwardCalls[1].citizenid, 'SOLO_K9')
    end)

    t.test('target resolution: a target who IS the K9-role party of an active partnership is credited directly, not redirected', function()
        h.resetCaptures()
        local src = registerPlayer(h, 'HC_K9DIRECT', granterJob)
        local target = registerPlayer(h, 'K9_DIRECT', { name = 'police', grade = { level = 1 } })
        h.partnerships['K9_DIRECT'] = { partner = 'HANDLER_OF_K9DIRECT', isK9 = true }
        runCommand(h, src, { tostring(target), '50' })
        t.equals(#h.capturedAwardCalls, 1)
        t.equals(h.capturedAwardCalls[1].citizenid, 'K9_DIRECT', 'the K9-role party must be credited directly, never their handler')
    end)

    t.test('target resolution: a target who is the HANDLER-role party of an active partnership redirects XP to their K9 partner', function()
        h.resetCaptures()
        local src = registerPlayer(h, 'HC_REDIRECT', granterJob)
        local target = registerPlayer(h, 'HANDLER_A', { name = 'police', grade = { level = 1 } })
        h.partnerships['HANDLER_A'] = { partner = 'K9_A', isK9 = false }
        runCommand(h, src, { tostring(target), '50' })
        t.equals(#h.capturedAwardCalls, 1)
        t.equals(h.capturedAwardCalls[1].citizenid, 'K9_A', 'a handler-role target must redirect the XP effect to their K9 partner')
    end)
end

-- ============================================================================
-- Self-grant: Config.HighCommand.allowSelfGrant (DEFAULT TRUE, this pass --
-- OWNER DECISION: "High command can grant anything they want to themselves
-- -- xp promotions permissions etc"). This harness explicitly passes
-- `allowSelfGrant = false` for the first two tests below so the STRICT,
-- opt-out behaviour stays provable and unweakened -- that switch, not the
-- default, is what these two tests exercise.
-- ============================================================================

do
    local h = newHarness({ maxXpPerGrant = 5000, grantCooldownMs = 1500, allowSelfGrant = false })
    local granterJob = { name = 'police', isboss = true, grade = { level = 0 } }

    t.test('self-grant: blocked when Config.HighCommand.allowSelfGrant is explicitly false, targeting your own server id', function()
        h.resetCaptures()
        local src = registerPlayer(h, 'SELF1', granterJob)
        runCommand(h, src, { tostring(src), '50' })
        t.equals(#h.capturedAwardCalls, 0)
        t.contains(h.capturedPrints[#h.capturedPrints], 'self_grant_blocked')
    end)

    t.test('self-grant: the partnership-redirect loophole is ALSO blocked -- targeting your own handler whose K9 partner is YOU must still be treated as self-grant', function()
        h.resetCaptures()
        local src = registerPlayer(h, 'SELF_K9', granterJob) -- the granter's own citizenid is 'SELF_K9'
        local handlerTarget = registerPlayer(h, 'SELF_HANDLER', { name = 'police', grade = { level = 1 } })
        h.partnerships['SELF_HANDLER'] = { partner = 'SELF_K9', isK9 = false } -- redirects to the granter's own citizenid
        runCommand(h, src, { tostring(handlerTarget), '50' })
        t.equals(#h.capturedAwardCalls, 0, 'redirecting to the granter\'s own citizenid one hop removed must still be blocked')
        t.contains(h.capturedPrints[#h.capturedPrints], 'self_grant_blocked')
    end)

    t.test('self-grant: ALLOWED once Config.HighCommand.allowSelfGrant is true, and the audit line names the SAME citizenid as granter and recipient with an explicit self_grant=true marker', function()
        h.resetCaptures()
        h.env.Config.HighCommand.allowSelfGrant = true
        local src = registerPlayer(h, 'SELF2', granterJob)
        runCommand(h, src, { tostring(src), '50' })
        t.equals(#h.capturedAwardCalls, 1)
        t.equals(h.capturedAwardCalls[1].citizenid, 'SELF2')

        -- AUDIT (this pass -- OWNER DECISION requirement: self-service is
        -- the owner's decision, not an invisible one): the audit line must
        -- be provably a self-grant, not merely inferable by comparing the
        -- granter (whoLabel) and target_citizenid fields by eye.
        local found = false
        for i = 1, #h.capturedPrints do
            local line = h.capturedPrints[i]
            if line:find('AUDIT', 1, true) and line:find('citizenid=SELF2', 1, true)
                and line:find('target_citizenid=SELF2', 1, true)
                and line:find('self_grant=true', 1, true) and line:find('-> ok', 1, true) then
                found = true
            end
        end
        t.isTrue(found, 'a successful XP self-grant must be audited with an explicit self_grant=true marker naming the same citizenid as both granter and recipient')

        h.env.Config.HighCommand.allowSelfGrant = false -- restore
    end)

    t.test('AUDIT: an ORDINARY (non-self) XP grant explicitly prints self_grant=false -- the field is always present, never omitted when it would read as "not a self-grant"', function()
        h.resetCaptures()
        h.env.Config.HighCommand.allowSelfGrant = true
        local src = registerPlayer(h, 'ORDINARY-GRANTER', granterJob)
        local targetSrc = registerPlayer(h, 'ORDINARY-TARGET', { name = 'police', grade = { level = 1 } })
        runCommand(h, src, { tostring(targetSrc), '50' })

        local found = false
        for i = 1, #h.capturedPrints do
            local line = h.capturedPrints[i]
            if line:find('AUDIT', 1, true) and line:find('self_grant=false', 1, true) and line:find('-> ok', 1, true) then
                found = true
            end
        end
        t.isTrue(found, 'an ordinary XP grant must be explicitly labeled self_grant=false, not merely lack a self_grant=true tag')

        h.env.Config.HighCommand.allowSelfGrant = false -- restore
    end)
end

-- ============================================================================
-- A CONFIG TABLE WRITTEN BEFORE THIS SWITCH EXISTED (this pass): Config.
-- HighCommand as a real table, but with the `allowSelfGrant` key entirely
-- ABSENT -- the exact shape every real config.lua had before this field was
-- ever added. Must behave per the NEW default (self-grant allowed) rather
-- than erroring or silently reverting to the OLD default (blocked).
-- ============================================================================

do
    -- Deliberately omits `allowSelfGrant` entirely -- see newHarness's own
    -- `Config = { ..., HighCommand = highCommandConfig }` wiring: whatever
    -- table is passed here becomes Config.HighCommand verbatim.
    local h = newHarness({ maxXpPerGrant = 5000, grantCooldownMs = 1500 })
    local granterJob = { name = 'police', isboss = true, grade = { level = 0 } }

    t.test('self-grant: a Config.HighCommand table with NO allowSelfGrant key at all (pre-existing config.lua) still defaults to ALLOWED, never errors', function()
        h.resetCaptures()
        local src = registerPlayer(h, 'LEGACY-SELF', granterJob)
        -- runCommand pcalls the handler (see this file's own header -- eight
        -- 'highcommand.*' locale keys are still pending as of this suite,
        -- so a later locale()-driven NotifyPlayer call may raise; that is
        -- expected and unrelated to this test, per this file's established
        -- convention of asserting on capturedAwardCalls/capturedPrints,
        -- both populated BEFORE any locale()-dependent call on this path,
        -- rather than on runCommand's own returned `ok`).
        runCommand(h, src, { tostring(src), '50' })
        t.equals(#h.capturedAwardCalls, 1, 'a config table missing this key entirely must still award XP, per the new default, not silently disable the command')
        t.equals(h.capturedAwardCalls[1].citizenid, 'LEGACY-SELF')
        t.contains(h.capturedPrints[#h.capturedPrints], '-> ok')
    end)
end

-- ============================================================================
-- Cooldown -- Config.HighCommand.grantCooldownMs via server/cooldowns.lua's
-- NewCooldown, keyed by the granter's own source. Includes the
-- non-positive-threshold-means-"permanently on", never "no cooldown"
-- footgun this codebase keeps hitting.
-- ============================================================================

do
    local h = newHarness({ maxXpPerGrant = 5000, grantCooldownMs = 300, allowSelfGrant = false })
    local granterJob = { name = 'police', isboss = true, grade = { level = 0 } }

    t.test('cooldown: a second grant from the same officer inside the window is rate-limited, no XP awarded', function()
        h.resetCaptures()
        fakeNow = 0
        local src = registerPlayer(h, 'CD_OFFICER1', granterJob)
        local targetA = registerPlayer(h, 'CD_TARGETA', { name = 'police', grade = { level = 1 } })
        local targetB = registerPlayer(h, 'CD_TARGETB', { name = 'police', grade = { level = 1 } })

        runCommand(h, src, { tostring(targetA), '50' })
        t.equals(#h.capturedAwardCalls, 1)

        fakeNow = 100 -- still within the 300ms window
        runCommand(h, src, { tostring(targetB), '50' })
        t.equals(#h.capturedAwardCalls, 1, 'the rate-limited second grant must not reach AwardXPDirect')
        t.contains(h.capturedPrints[#h.capturedPrints], 'rate_limited')

        fakeNow = 400 -- past the window
        runCommand(h, src, { tostring(targetB), '50' })
        t.equals(#h.capturedAwardCalls, 2, 'a grant after the cooldown window has elapsed must succeed')
    end)

    t.test('cooldown: rate limiting is per-GRANTER, not per-target -- a different officer is unaffected', function()
        h.resetCaptures()
        fakeNow = 1000
        local src1 = registerPlayer(h, 'CD_OFFICER2', granterJob)
        local src2 = registerPlayer(h, 'CD_OFFICER3', granterJob)
        local target = registerPlayer(h, 'CD_TARGETC', { name = 'police', grade = { level = 1 } })

        runCommand(h, src1, { tostring(target), '50' })
        t.equals(#h.capturedAwardCalls, 1)

        runCommand(h, src2, { tostring(target), '50' }) -- same fakeNow, different officer
        t.equals(#h.capturedAwardCalls, 2, 'a different officer must not be blocked by another officer\'s cooldown')
    end)
end

t.test('FOOTGUN: grantCooldownMs == 0 permanently blocks an officer after their FIRST grant, never means "no cooldown"', function()
    local h = newHarness({ maxXpPerGrant = 5000, grantCooldownMs = 0, allowSelfGrant = false })
    local granterJob = { name = 'police', isboss = true, grade = { level = 0 } }
    fakeNow = 0
    local src = registerPlayer(h, 'CD0_OFFICER', granterJob)
    local target1 = registerPlayer(h, 'CD0_TARGET1', { name = 'police', grade = { level = 1 } })
    local target2 = registerPlayer(h, 'CD0_TARGET2', { name = 'police', grade = { level = 1 } })

    runCommand(h, src, { tostring(target1), '50' })
    t.equals(#h.capturedAwardCalls, 1, 'the FIRST grant must still succeed (server/cooldowns.lua: a never-touched key is never on cooldown)')

    fakeNow = fakeNow + 10000000 -- arbitrarily far in the future
    runCommand(h, src, { tostring(target2), '50' })
    t.equals(#h.capturedAwardCalls, 1, 'a 0 grantCooldownMs must permanently block this officer after their first grant, not mean "unlimited"')
    t.contains(h.capturedPrints[#h.capturedPrints], 'rate_limited')
end)

t.test('FOOTGUN: grantCooldownMs == nil behaves identically to 0 -- permanently blocked after the first grant', function()
    local h = newHarness({ maxXpPerGrant = 5000, grantCooldownMs = nil, allowSelfGrant = false })
    local granterJob = { name = 'police', isboss = true, grade = { level = 0 } }
    fakeNow = 0
    local src = registerPlayer(h, 'CDNIL_OFFICER', granterJob)
    local target1 = registerPlayer(h, 'CDNIL_TARGET1', { name = 'police', grade = { level = 1 } })
    local target2 = registerPlayer(h, 'CDNIL_TARGET2', { name = 'police', grade = { level = 1 } })

    runCommand(h, src, { tostring(target1), '50' })
    t.equals(#h.capturedAwardCalls, 1)

    fakeNow = fakeNow + 10000000
    runCommand(h, src, { tostring(target2), '50' })
    t.equals(#h.capturedAwardCalls, 1, 'nil grantCooldownMs must never mean "no cooldown"')
end)

-- ============================================================================
-- Target/granter citizenid resolution failures -- both reuse EXISTING
-- locales/en.json keys (common.unable_to_resolve_citizenid /
-- common.target_no_longer_online), so these are NOT blocked on the pending
-- locale keys.
-- ============================================================================

do
    local h = newHarness({ maxXpPerGrant = 5000, grantCooldownMs = 1500, allowSelfGrant = false })

    t.test('target resolution failure: a server id with no connected player is rejected, no XP awarded', function()
        h.resetCaptures()
        local src = registerPlayer(h, 'HC_NOTGT', { name = 'police', isboss = true, grade = { level = 0 } })
        local disconnectedTarget = freshSourceNumber() -- never registered in playersBySource
        local ok = runCommand(h, src, { tostring(disconnectedTarget), '50' })
        t.isTrue(ok, 'common.target_no_longer_online already exists in locales/en.json -- this path must not throw')
        t.equals(#h.capturedAwardCalls, 0)
        t.equals(#h.capturedNotifications, 1)
        t.contains(h.capturedNotifications[1].description, 'no longer online')
    end)

    t.test('granter citizenid resolution failure: a high-command Player with no citizenid on PlayerData is rejected, no XP awarded', function()
        h.resetCaptures()
        local src = freshSourceNumber()
        h.playersBySource[src] = { PlayerData = { job = { name = 'police', isboss = true, grade = { level = 0 } } } } -- no citizenid field
        local target = registerPlayer(h, 'HC_TARGETNOCIT', { name = 'police', grade = { level = 1 } })
        local ok = runCommand(h, src, { tostring(target), '50' })
        t.isTrue(ok, 'common.unable_to_resolve_citizenid already exists in locales/en.json -- this path must not throw')
        t.equals(#h.capturedAwardCalls, 0)
        t.contains(h.capturedNotifications[1].description, 'Unable to resolve')
    end)
end

-- ============================================================================
-- XP system unavailable -- AwardXPDirect not (yet) present in
-- server/progression.lua (this pass's own hand-off note). Guarded by
-- `type(AwardXPDirect) == 'function'`; must fail closed with a clear
-- message, never silently no-op indistinguishably from a bug. Not blocked
-- on the pending highcommand.xp_system_unavailable locale key -- see this
-- file's header for why (the assertions below only inspect state captured
-- before that key's NotifyPlayer call).
-- ============================================================================

t.test('XP system unavailable: AwardXPDirect missing is audited as xp_unavailable, no XP awarded, no throw from the missing function itself', function()
    local h = newHarness({ maxXpPerGrant = 5000, grantCooldownMs = 1500, allowSelfGrant = false })
    h.env.AwardXPDirect = nil -- simulate server/progression.lua not yet exposing it
    local src = registerPlayer(h, 'HC_NOAWARD', { name = 'police', isboss = true, grade = { level = 0 } })
    local target = registerPlayer(h, 'TARGET_NOAWARD', { name = 'police', grade = { level = 1 } })
    runCommand(h, src, { tostring(target), '50' })
    t.equals(#h.capturedAwardCalls, 0)
    t.contains(h.capturedPrints[#h.capturedPrints], 'xp_unavailable')
end)

-- ============================================================================
-- Audit line: EVERY grant prints granter citizenid, target citizenid, amount
-- and resulting total, mirroring server/admin.lua's LogAuditInvocation
-- format. LogAuditInvocation's print() runs BEFORE the locale()-dependent
-- success notifications, so this is NOT blocked on the pending locale keys.
-- ============================================================================

t.test('audit: a successful grant prints granter citizenid, target citizenid, amount, and resulting total', function()
    local h = newHarness({ maxXpPerGrant = 5000, grantCooldownMs = 1500, allowSelfGrant = false })
    local src = registerPlayer(h, 'AUDIT_GRANTER', { name = 'police', isboss = true, grade = { level = 0 } })
    local target = registerPlayer(h, 'AUDIT_TARGET', { name = 'police', grade = { level = 1 } })

    runCommand(h, src, { tostring(target), '250' })

    local auditLine
    for _, line in ipairs(h.capturedPrints) do
        if line:find('AUDIT:', 1, true) and line:find('-> ok', 1, true) then auditLine = line end
    end
    t.isNotNil(auditLine, 'expected an "-> ok" audit line for a successful grant')
    t.contains(auditLine, 'citizenid=AUDIT_GRANTER', 'audit line must name the granter citizenid')
    t.contains(auditLine, 'target_citizenid=AUDIT_TARGET', 'audit line must name the target citizenid')
    t.contains(auditLine, 'amount=250', 'audit line must name the amount')
    t.contains(auditLine, 'new_total=250', 'audit line must name the resulting total')
end)

t.test('audit: EVERY invocation is logged, including denied/rate_limited/invalid_args, not just successful grants', function()
    local h = newHarness({ maxXpPerGrant = 5000, grantCooldownMs = 100000, allowSelfGrant = false })
    local granterJob = { name = 'police', isboss = true, grade = { level = 0 } }

    -- denied
    local lowRankSrc = registerPlayer(h, 'AUDITALL_LOWRANK', { name = 'police', grade = { level = 1 } })
    local target = registerPlayer(h, 'AUDITALL_TARGET', { name = 'police', grade = { level = 1 } })
    runCommand(h, lowRankSrc, { tostring(target), '50' })
    t.contains(h.capturedPrints[#h.capturedPrints], 'denied')

    -- ok, then rate_limited on the very next call from the SAME officer
    fakeNow = 0
    local hcSrc = registerPlayer(h, 'AUDITALL_HC', granterJob)
    runCommand(h, hcSrc, { tostring(target), '50' })
    t.contains(h.capturedPrints[#h.capturedPrints], '-> ok')
    runCommand(h, hcSrc, { tostring(target), '50' })
    t.contains(h.capturedPrints[#h.capturedPrints], 'rate_limited')

    -- invalid_args, from a THIRD officer so the cooldown above cannot mask it
    fakeNow = 0
    local hcSrc2 = registerPlayer(h, 'AUDITALL_HC2', granterJob)
    runCommand(h, hcSrc2, { tostring(target), 'not-a-number' })
    t.contains(h.capturedPrints[#h.capturedPrints], 'invalid_args')
end)



-- ============================================================================
-- block.k9.givexp -- an explicit block must beat rank, like every sibling.
--
-- This was a real, shipped gap found by a verification pass. It is worse than
-- a missing feature: server/permissions.lua LISTS 'k9.givexp' in
-- ADMIN_CAPABILITY_BLOCKABLE_KEYS and happily accepts and stores
-- 'block.k9.givexp', so an owner could set that block, be told it saved, and
-- get no protection whatsoever -- while the three sibling capabilities
-- (block.k9.access, block.k9.certify, block.k9.audit) all correctly beat rank.
-- Granting XP is also the one capability that mints economy value from
-- nothing, so it is the LAST one that should have been unenforceable.
-- ============================================================================

t.test('block.k9.givexp beats HIGH COMMAND RANK -- the bypass must not short-circuit past an explicit block', function()
    local h = newHarness({ maxXpPerGrant = 5000, grantCooldownMs = 1500, allowSelfGrant = false })
    -- isboss qualifies as high command without needing a grade threshold.
    local src = registerPlayer(h, 'BLOCKED_HC', { name = 'police', isboss = true, grade = { level = 0 } })
    local target = registerPlayer(h, 'TARGET_A', { name = 'police', grade = { level = 1 } })
    h.permissionsByCitizenid['BLOCKED_HC'] = { ['block.k9.givexp'] = true }

    runCommand(h, src, { tostring(target), '100' })

    t.equals(#h.capturedAwardCalls, 0, 'a blocked high command officer must mint no XP at all')
end)

t.test('block.k9.givexp beats an explicit k9.givexp GRANT too -- a block is not merely the absence of a grant', function()
    local h = newHarness({ maxXpPerGrant = 5000, grantCooldownMs = 1500, allowSelfGrant = false })
    local src = registerPlayer(h, 'BLOCKED_GRANTEE', { name = 'police', grade = { level = 0 } })
    local target = registerPlayer(h, 'TARGET_B', { name = 'police', grade = { level = 1 } })
    h.permissionsByCitizenid['BLOCKED_GRANTEE'] = { ['k9.givexp'] = true, ['block.k9.givexp'] = true }

    runCommand(h, src, { tostring(target), '100' })

    t.equals(#h.capturedAwardCalls, 0, 'holding both a grant and a block resolves to blocked')
end)

t.test('CONTROL: the same high command officer WITHOUT the block still grants normally -- proving the refusals above are the block, not a broken fixture', function()
    local h = newHarness({ maxXpPerGrant = 5000, grantCooldownMs = 1500, allowSelfGrant = false })
    local src = registerPlayer(h, 'UNBLOCKED_HC', { name = 'police', isboss = true, grade = { level = 0 } })
    local target = registerPlayer(h, 'TARGET_C', { name = 'police', grade = { level = 1 } })
    -- deliberately no permissions row at all

    runCommand(h, src, { tostring(target), '100' })

    t.equals(#h.capturedAwardCalls, 1, 'an unblocked high command officer still mints XP -- the two tests above fail for the block, not because the fixture never reaches the grant')
end)

os.exit(t.summary())
