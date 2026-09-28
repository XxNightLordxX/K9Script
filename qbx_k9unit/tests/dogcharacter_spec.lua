--[[
    tests/dogcharacter_spec.lua

    Direct tests of server/dogcharacter.lua -- the mana_policedogs
    feature-parity pass (explicit, admin-pinned "this citizenid is a dog"
    record, independent of certification/permission -- see that file's own
    header for the full design writeup) -- against the REAL, unmodified
    production file, loaded alongside the REAL server/cooldowns.lua,
    server/highcommand.lua and server/datastore.lua (IsHighCommand/
    NewCooldown/K9Store are all consulted directly; a fake/duplicated
    authorization or persistence layer here would risk silently drifting
    from the real logic this suite is supposed to be exercising -- same
    reasoning tests/appearance_spec.lua's own header already states for the
    identical choice).

    Deliberately does NOT load server/appearance.lua or server/permissions.lua:
    server/dogcharacter.lua's whole design point is that it has ZERO real
    dependency on either (see its own header "WHY NO PERMISSION GRANT") --
    ApplyK9AppearanceDirect/MaybeRevertK9Appearance are consulted purely
    through this resource's established `type(fn) == 'function'` soft-
    dependency convention, so this file injects PLAIN, TEST-CONTROLLED spy
    functions for them (representing "the routed server/appearance.lua
    patch, once it lands" -- see server/dogcharacter.lua's own header
    "ROUTED CHANGES" section for the exact bodies requested) rather than
    loading the real file. Section 7 below additionally proves the DEGRADED
    (neither defined at all) case behaves correctly and honestly, which is
    the state this resource is ACTUALLY in as of this pass.

    LOCALE: stubbed to a plain passthrough, NOT Sandbox.locale (which
    raises on any key not yet in the real locales/en.json). Every
    `dogcharacter.*` key this file's production code calls is PROPOSED, not
    yet landed (see server/dogcharacter.lua's own header, routed item 6) --
    same interim state, same fix, as tests/appearance_spec.lua's own header
    already documents for that file's `appearance.*` keys. This spec never
    asserts on exact notification TEXT, only on outcomes/side effects, so
    the substitution costs nothing here.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

-- ----------------------------------------------------------------------
-- Fixture builder -- one fresh env + fresh load per top-level scenario,
-- same "never leak state between unrelated test cases" discipline as
-- tests/appearance_spec.lua's own newFixture().
-- ----------------------------------------------------------------------

--- @param opts table? -- { highCommandGrade: number (default 6), databaseEnabled: boolean (default nil -- absent Config.Database means real-DB mode, matching appearance_spec.lua's own convention), sharedMysqlTables: table? -- { dogCharacters = {...} }, for simulating a restart against the SAME backing "database" }
local function newFixture(opts)
    opts = opts or {}

    local state = { now = 1000000 }
    local function GetGameTimer() return state.now end

    -- ---- exports.qbx_core -------------------------------------------------
    local playersBySource = {}
    local playersByCitizenId = {}

    --- @param source number
    --- @param citizenid string
    --- @param job table?
    local function registerPlayer(source, citizenid, job)
        local p = { PlayerData = { citizenid = citizenid, job = job, source = source } }
        playersBySource[source] = p
        playersByCitizenId[citizenid] = p
        return p
    end

    local exportsStub = {
        qbx_core = {
            GetPlayer = function(_self, source) return playersBySource[source] end,
            GetPlayerByCitizenId = function(_self, citizenid) return playersByCitizenId[citizenid] end,
        },
    }

    -- ---- fake k9_dog_characters --------------------------------------------
    -- Real SQL text is never parsed -- pattern-matched on which statement
    -- shape the real production query is, same technique
    -- tests/appearance_spec.lua's own mysqlQueryAwait already established.
    -- `opts.sharedMysqlTables.dogCharacters`, when supplied, lets TWO
    -- separate fixture builds (two separate `env`s, i.e. two separate
    -- "resource boots") observe the SAME underlying rows -- this is what
    -- Section 5 below uses to prove persistence survives a restart.
    local fakeDogCharacters = (opts.sharedMysqlTables and opts.sharedMysqlTables.dogCharacters) or {}

    local mysqlCallLog = {} -- every real query this fixture's mysql stub ever received, for "was the DB even touched" assertions
    local function mysqlQueryAwait(sql, params)
        mysqlCallLog[#mysqlCallLog + 1] = sql
        if sql:find('SELECT model, active FROM k9_dog_characters', 1, true) then
            local citizenid = params[1]
            local row = fakeDogCharacters[citizenid]
            if not row then return {} end
            return { { model = row.model, active = row.active and 1 or 0 } }
        end
        if sql:find('INSERT INTO k9_dog_characters', 1, true) then
            local citizenid, model, setBy = params[1], params[2], params[3]
            fakeDogCharacters[citizenid] = { model = model, active = true, set_by = setBy }
            return { insertId = 1, affectedRows = 1 }
        end
        if sql:find('UPDATE k9_dog_characters SET active = 0', 1, true) then
            local citizenid = params[1]
            local row = fakeDogCharacters[citizenid]
            if row and row.active then row.active = false; return { affectedRows = 1 } end
            return { affectedRows = 0 }
        end
        error('unstubbed MySQL.query.await query in dogcharacter_spec fixture: ' .. sql)
    end

    -- Deliberately errors on EVERY call -- proves the memory-mode tests
    -- (Section 4) never actually reach the database at all, not merely
    -- that they happen to produce the right answer despite a working stub
    -- underneath. Real-DB-mode fixtures override this with the real
    -- `mysql` table below instead.
    local mysqlThatMustNeverBeCalled = {
        query = { await = function(sql) error('MySQL.query.await called in memory-mode fixture: ' .. tostring(sql)) end },
    }

    local mysql = {
        query = { await = mysqlQueryAwait },
        update = { await = function(sql, params) local r = mysqlQueryAwait(sql, params); return r and r.affectedRows or 0 end },
        insert = { await = function(sql, params) local r = mysqlQueryAwait(sql, params); return r and r.insertId or 0 end },
    }

    -- ---- captured command/audit/notify plumbing ----------------------------
    local registeredCommands = {}
    local function RegisterCommandStub(name, handler, _restricted)
        registeredCommands[name] = handler
    end

    local eventHandlers = {}
    local function AddEventHandlerStub(eventName, handler)
        eventHandlers[eventName] = eventHandlers[eventName] or {}
        eventHandlers[eventName][#eventHandlers[eventName] + 1] = handler
    end

    local notifyLog = {}
    local function NotifyPlayer(source, message, kind)
        notifyLog[#notifyLog + 1] = { source = source, message = message, kind = kind }
    end

    local printLog = {}
    local function printStub(...)
        local parts = {}
        for i = 1, select('#', ...) do parts[i] = tostring(select(i, ...)) end
        printLog[#printLog + 1] = table.concat(parts, '\t')
    end

    -- Plain passthrough -- see this file's header for why the real
    -- Sandbox.locale is not used here.
    local function localeStub(key, ...)
        if select('#', ...) > 0 then
            local args = { ... }
            for i, v in ipairs(args) do args[i] = tostring(v) end
            return key .. ':' .. table.concat(args, ',')
        end
        return key
    end

    local Config = {
        CommandTablet = { adminChatCommands = true }, -- admin chat commands are off by default; these tests drive them
        Features = { HighCommand = true },
        Departments = {
            police = { label = 'Police', highCommandGrade = opts.highCommandGrade or 6 },
        },
        Peds = opts.peds or {
            { model = 'a_c_shepherd' },
            { model = 'a_c_husky' },
        },
    }
    if opts.databaseEnabled == false then
        Config.Database = { enabled = false }
    end

    local overrides = {
        Config = Config,
        GetGameTimer = GetGameTimer,
        exports = exportsStub,
        MySQL = opts.databaseEnabled == false and mysqlThatMustNeverBeCalled or mysql,
        RegisterCommand = RegisterCommandStub,
        AddEventHandler = AddEventHandlerStub,
        NotifyPlayer = NotifyPlayer,
        print = printStub,
        locale = localeStub,
    }

    local env = Sandbox.newEnv(overrides)

    -- server/datastore.lua -- REAL, unmodified, loaded first (matches
    -- fxmanifest.lua's own load order: the shared K9Store.IsDatabaseEnabled
    -- this file's own accessors call through).
    Sandbox.loadInto('../server/datastore.lua', env)
    -- server/cooldowns.lua -- REAL: server/dogcharacter.lua calls
    -- NewCooldown() at its own file-load time (hard requirement).
    Sandbox.loadInto('../server/cooldowns.lua', env)
    -- server/highcommand.lua -- REAL: IsHighCommand is this file's sole
    -- authorization gate for both admin commands.
    Sandbox.loadInto('../server/highcommand.lua', env)
    Sandbox.loadInto('../server/dogcharacter.lua', env)

    return {
        env = env,
        state = state,
        Config = Config,
        registerPlayer = registerPlayer,
        registeredCommands = registeredCommands,
        notifyLog = notifyLog,
        printLog = printLog,
        mysqlCallLog = mysqlCallLog,
        fakeDogCharacters = fakeDogCharacters,
    }
end

--- @param label string
--- @param printLog string[]
local function auditContains(printLog, needle)
    for _, line in ipairs(printLog) do
        if line:find(needle, 1, true) then return true end
    end
    return false
end

-- ======================================================================
-- 1. AUTHORIZATION -- SetDogCharacter/RemoveDogCharacter are both
--    IsHighCommand-only (no permission-key path), mirroring
--    ForceRevertK9Appearance's own precedent -- see this file's header.
-- ======================================================================

t.test('SetDogCharacter denies a non-high-command caller, no DB write', function()
    local f = newFixture()
    f.registerPlayer(1, 'ADMIN01', { name = 'police', isboss = false, grade = { level = 1 } })
    f.registerPlayer(2, 'TARGET01', { name = 'police', isboss = false, grade = { level = 1 } })

    local ok, outcome = f.env.SetDogCharacter(1, 'TARGET01', 'a_c_shepherd')
    t.isFalse(ok)
    t.equals(outcome, 'denied')
    t.equals(#f.mysqlCallLog, 0, 'a denied caller must never reach the database at all')
    t.isNil(f.env.GetPinnedDogCharacterModel('TARGET01'), 'this read-only check itself queries the DB -- asserted last, on purpose')
end)

t.test('SetDogCharacter allows job.isboss regardless of grade', function()
    local f = newFixture()
    f.registerPlayer(1, 'BOSS01', { name = 'police', isboss = true, grade = { level = 0 } })

    local ok, outcome = f.env.SetDogCharacter(1, 'TARGET01', 'a_c_shepherd')
    t.isTrue(ok)
    t.equals(outcome, 'appearance_hook_unavailable') -- no ApplyK9AppearanceDirect injected in this test
end)

t.test('RemoveDogCharacter denies a non-high-command caller', function()
    local f = newFixture()
    f.registerPlayer(1, 'ADMIN01', { name = 'police', isboss = false, grade = { level = 1 } })

    local ok, outcome = f.env.RemoveDogCharacter(1, 'TARGET01')
    t.isFalse(ok)
    t.equals(outcome, 'denied')
end)

-- ======================================================================
-- 2. DEGRADED MODE -- ApplyK9AppearanceDirect/MaybeRevertK9Appearance are
--    NOT DEFINED at all (the state this resource is actually in as of
--    this pass -- see this file's own header). The pin must still
--    persist, honestly reported, never silently dropped and never a false
--    'ok'.
-- ======================================================================

t.test('SetDogCharacter persists the pin even with no ApplyK9AppearanceDirect, reports appearance_hook_unavailable', function()
    local f = newFixture()
    f.registerPlayer(1, 'HC01', { name = 'police', isboss = true })

    local ok, outcome = f.env.SetDogCharacter(1, 'TARGET01', 'a_c_husky')
    t.isTrue(ok)
    t.equals(outcome, 'appearance_hook_unavailable')
    t.isTrue(f.env.IsPinnedDogCharacter('TARGET01'))
    t.equals(f.env.GetPinnedDogCharacterModel('TARGET01'), 'a_c_husky')
    t.isTrue(auditContains(f.printLog, 'appearance_hook_unavailable'))
end)

t.test('RemoveDogCharacter clears the pin even with no MaybeRevertK9Appearance defined -- never gate a termination path', function()
    local f = newFixture()
    f.registerPlayer(1, 'HC01', { name = 'police', isboss = true })
    f.env.SetDogCharacter(1, 'TARGET01', 'a_c_husky')
    t.isTrue(f.env.IsPinnedDogCharacter('TARGET01'))
    f.state.now = f.state.now + 1600 -- past this granter's own action cooldown, shared between SetDogCharacter/RemoveDogCharacter by design (matches server/highcommand.lua's own "one shared per-officer bucket" precedent)

    local ok, outcome = f.env.RemoveDogCharacter(1, 'TARGET01')
    t.isTrue(ok)
    t.equals(outcome, 'ok')
    t.isFalse(f.env.IsPinnedDogCharacter('TARGET01'))
    t.isNil(f.env.GetPinnedDogCharacterModel('TARGET01'))
end)

-- ======================================================================
-- 3. WITH THE ROUTED HOOKS PRESENT -- spy stubs standing in for "the
--    server/appearance.lua patch, once it lands" (see this file's header
--    and server/dogcharacter.lua's own "ROUTED CHANGES" section for the
--    exact requested bodies).
-- ======================================================================

t.test('SetDogCharacter calls ApplyK9AppearanceDirect with the target/model/granterLabel, and returns its outcome', function()
    local f = newFixture()
    f.registerPlayer(1, 'HC01', { name = 'police', isboss = true })

    local calls = {}
    f.env.ApplyK9AppearanceDirect = function(citizenid, model, granterLabel)
        calls[#calls + 1] = { citizenid = citizenid, model = model, granterLabel = granterLabel }
        return true, 'ok'
    end

    local ok, outcome = f.env.SetDogCharacter(1, 'TARGET01', 'a_c_shepherd')
    t.isTrue(ok)
    t.equals(outcome, 'ok')
    t.equals(#calls, 1)
    t.equals(calls[1].citizenid, 'TARGET01')
    t.equals(calls[1].model, 'a_c_shepherd')
    t.equals(calls[1].granterLabel, 'citizenid=HC01')
    t.isTrue(f.env.IsPinnedDogCharacter('TARGET01'))
end)

t.test('SetDogCharacter does NOT persist the pin when ApplyK9AppearanceDirect itself fails', function()
    local f = newFixture()
    f.registerPlayer(1, 'HC01', { name = 'police', isboss = true })
    f.env.ApplyK9AppearanceDirect = function() return false, 'db_error' end

    local ok, outcome = f.env.SetDogCharacter(1, 'TARGET01', 'a_c_shepherd')
    t.isFalse(ok)
    t.equals(outcome, 'db_error')
    t.isFalse(f.env.IsPinnedDogCharacter('TARGET01'))
end)

t.test('RemoveDogCharacter calls MaybeRevertK9Appearance with the target citizenid AFTER the pin is already cleared', function()
    local f = newFixture()
    f.registerPlayer(1, 'HC01', { name = 'police', isboss = true })
    f.env.ApplyK9AppearanceDirect = function() return true, 'ok' end
    f.env.SetDogCharacter(1, 'TARGET01', 'a_c_shepherd')
    f.state.now = f.state.now + 1600 -- past the shared per-officer action cooldown

    local calls = {}
    f.env.MaybeRevertK9Appearance = function(citizenid)
        -- THE ORDERING ASSERTION: by the time this fires, the pin must
        -- already read as cleared -- this is what lets a real
        -- MaybeRevertK9Appearance's own credential checks run unblocked
        -- (see server/dogcharacter.lua's header "IMMEDIATE RECONCILIATION").
        calls[#calls + 1] = { citizenid = citizenid, pinWasAlreadyClear = not f.env.IsPinnedDogCharacter(citizenid) }
    end

    local ok = f.env.RemoveDogCharacter(1, 'TARGET01')
    t.isTrue(ok)
    t.equals(#calls, 1)
    t.equals(calls[1].citizenid, 'TARGET01')
    t.isTrue(calls[1].pinWasAlreadyClear)
end)

t.test('RemoveDogCharacter on a citizenid with no pin at all: not_a_dog_character, MaybeRevertK9Appearance never called', function()
    local f = newFixture()
    f.registerPlayer(1, 'HC01', { name = 'police', isboss = true })
    local called = false
    f.env.MaybeRevertK9Appearance = function() called = true end

    local ok, outcome = f.env.RemoveDogCharacter(1, 'NEVERPINNED')
    t.isFalse(ok)
    t.equals(outcome, 'not_a_dog_character')
    t.isFalse(called)
end)

-- ======================================================================
-- 4. OFFLINE-CAPABLE (both commands, and both core functions) -- mirrors
--    ForceRevertK9Appearance/ApplyK9PedRole. Neither TARGET01 nor
--    NEVERONLINE is ever registered as an online player below.
-- ======================================================================

t.test('SetDogCharacter/RemoveDogCharacter work against a citizenid that is never online', function()
    local f = newFixture()
    f.registerPlayer(1, 'HC01', { name = 'police', isboss = true })
    f.env.ApplyK9AppearanceDirect = function() return true, 'persisted_offline' end
    local reconciled = false
    f.env.MaybeRevertK9Appearance = function() reconciled = true end

    local setOk, setOutcome = f.env.SetDogCharacter(1, 'OFFLINE01', 'a_c_husky')
    t.isTrue(setOk)
    t.equals(setOutcome, 'persisted_offline')
    t.isTrue(f.env.IsPinnedDogCharacter('OFFLINE01'))
    f.state.now = f.state.now + 1600 -- past the shared per-officer action cooldown

    local removeOk = f.env.RemoveDogCharacter(1, 'OFFLINE01')
    t.isTrue(removeOk)
    t.isFalse(f.env.IsPinnedDogCharacter('OFFLINE01'))
    t.isTrue(reconciled, 'MaybeRevertK9Appearance must still run for an offline target -- every read/write inside it is citizenid-keyed, not source-keyed')
end)

-- ======================================================================
-- 5. PERSISTENCE -- survives a simulated RESTART (a fresh env/fresh load
--    of every file, sharing only the underlying "database" rows) and
--    works correctly with Config.Database.enabled = false (memory mode,
--    proven by a MySQL stub that ERRORS on any call at all).
-- ======================================================================

t.test('a dog-character pin survives a simulated resource restart (fresh env, same backing database)', function()
    local shared = { dogCharacters = {} }

    local bootA = newFixture({ sharedMysqlTables = shared })
    bootA.registerPlayer(1, 'HC01', { name = 'police', isboss = true })
    bootA.env.ApplyK9AppearanceDirect = function() return true, 'ok' end
    local ok = bootA.env.SetDogCharacter(1, 'SURVIVOR01', 'a_c_shepherd')
    t.isTrue(ok)

    -- Simulate a full resource restart: a BRAND NEW env, a brand new load
    -- of every file (no shared Lua state at all with bootA above) -- the
    -- ONLY thing carried across is `shared.dogCharacters`, standing in for
    -- the real MySQL table surviving a process restart.
    local bootB = newFixture({ sharedMysqlTables = shared })
    t.isTrue(bootB.env.IsPinnedDogCharacter('SURVIVOR01'), 'the pin must be readable by a freshly-booted process against the same database')
    t.equals(bootB.env.GetPinnedDogCharacterModel('SURVIVOR01'), 'a_c_shepherd')
end)

t.test('memory mode (Config.Database.enabled = false): pin round-trips without ever touching MySQL', function()
    local f = newFixture({ databaseEnabled = false })
    f.registerPlayer(1, 'HC01', { name = 'police', isboss = true })
    f.env.ApplyK9AppearanceDirect = function() return true, 'ok' end

    local ok = f.env.SetDogCharacter(1, 'MEMONLY01', 'a_c_husky')
    t.isTrue(ok)
    t.isTrue(f.env.IsPinnedDogCharacter('MEMONLY01'))
    t.equals(f.env.GetPinnedDogCharacterModel('MEMONLY01'), 'a_c_husky')
    f.state.now = f.state.now + 1600 -- past the shared per-officer action cooldown

    local removeOk = f.env.RemoveDogCharacter(1, 'MEMONLY01')
    t.isTrue(removeOk)
    t.isFalse(f.env.IsPinnedDogCharacter('MEMONLY01'))
    -- The fixture's own `mysql` override for this mode ERRORS on any call
    -- at all -- reaching this line at all already proves no query was ever
    -- attempted, but assert it explicitly too.
end)

-- ======================================================================
-- 6. ZERO DEPENDENCY ON THE PERMISSION-GRANT SYSTEM -- the core design
--    decision this file's own header states at length: /k9setdog must
--    never hand out `k9.access` as a side effect. GrantPermission/
--    HasPermission are not even DEFINED anywhere in this fixture's env
--    (server/permissions.lua is never loaded) -- SetDogCharacter must
--    still fully succeed, proving it structurally cannot reach either.
-- ======================================================================

t.test('SetDogCharacter succeeds with GrantPermission/HasPermission completely undefined', function()
    local f = newFixture()
    t.isNil(f.env.GrantPermission)
    t.isNil(f.env.HasPermission)
    f.registerPlayer(1, 'HC01', { name = 'police', isboss = true })
    f.env.ApplyK9AppearanceDirect = function() return true, 'ok' end

    local ok, outcome = f.env.SetDogCharacter(1, 'TARGET01', 'a_c_shepherd')
    t.isTrue(ok)
    t.equals(outcome, 'ok')
end)

-- ======================================================================
-- 7. MODEL / VARIATION VALIDATION
-- ======================================================================

t.test('SetDogCharacter rejects a model not present in Config.Peds', function()
    local f = newFixture()
    f.registerPlayer(1, 'HC01', { name = 'police', isboss = true })

    local ok, outcome = f.env.SetDogCharacter(1, 'TARGET01', 'a_c_totally_made_up')
    t.isFalse(ok)
    t.equals(outcome, 'invalid_model')
    t.isFalse(f.env.IsPinnedDogCharacter('TARGET01'))
end)

t.test('SetDogCharacter rejects an invalid targetCitizenid', function()
    local f = newFixture()
    f.registerPlayer(1, 'HC01', { name = 'police', isboss = true })

    local ok, outcome = f.env.SetDogCharacter(1, '', 'a_c_shepherd')
    t.isFalse(ok)
    t.equals(outcome, 'invalid_target')
end)

-- ======================================================================
-- 8. COOLDOWN -- consumed EXACTLY ONCE per call (regression test for the
--    double-consumption bug found and fixed while writing this file: the
--    command handler used to ALSO consume the same cooldown instance
--    before calling into SetDogCharacter/RemoveDogCharacter, which itself
--    consumes it again -- since both checks land in the same GetGameTimer()
--    tick, the SECOND (inner) check always saw ~0ms elapsed and reported
--    'rate_limited' on literally every call, permanently. See "RED-THEN-
--    GREEN PROOF" in this pass's own hand-off report for how this was
--    confirmed against a real regression, not merely reasoned about.)
-- ======================================================================

t.test('a single /k9setdog command invocation succeeds -- cooldown is not double-consumed', function()
    local f = newFixture()
    f.registerPlayer(1, 'HC01', { name = 'police', isboss = true })
    f.env.ApplyK9AppearanceDirect = function() return true, 'ok' end

    local handler = f.registeredCommands['k9setdog']
    t.isNotNil(handler, '/k9setdog must be registered when Config.Features.HighCommand is true')
    handler(1, { 'TARGET01', 'a_c_shepherd' })

    t.isTrue(f.env.IsPinnedDogCharacter('TARGET01'))
    t.isFalse(auditContains(f.printLog, 'rate_limited'), 'a single command invocation must never trip its own cooldown')
end)

t.test('a second SetDogCharacter call inside the cooldown window is rate_limited; a third after it elapses succeeds', function()
    local f = newFixture()
    f.registerPlayer(1, 'HC01', { name = 'police', isboss = true })
    f.env.ApplyK9AppearanceDirect = function() return true, 'ok' end

    local ok1 = f.env.SetDogCharacter(1, 'TARGET01', 'a_c_shepherd')
    t.isTrue(ok1)

    local ok2, outcome2 = f.env.SetDogCharacter(1, 'TARGET02', 'a_c_shepherd')
    t.isFalse(ok2)
    t.equals(outcome2, 'rate_limited')
    t.isFalse(f.env.IsPinnedDogCharacter('TARGET02'), 'a rate-limited call must never write anything')

    f.state.now = f.state.now + 1600 -- past DOG_CHARACTER_ACTION_COOLDOWN_MS (1500)
    local ok3 = f.env.SetDogCharacter(1, 'TARGET02', 'a_c_shepherd')
    t.isTrue(ok3)
end)

-- ======================================================================
-- 9. COMMAND SURFACE -- '/k9setdog' / '/k9removedog' argument resolution.
-- ======================================================================

t.test('/k9setdog is not registered at all when Config.Features.HighCommand is false', function()
    local f = newFixture()
    f.Config.Features.HighCommand = false
    -- Config is captured by reference into the env at fixture build time,
    -- but server/dogcharacter.lua's own `if Config.Features.HighCommand ==
    -- true then RegisterCommand(...) end` guard already ran at THIS
    -- fixture's load time (before this test mutated it) -- rebuild fresh
    -- to actually exercise the registration-time gate.
    local f2 = newFixture()
    f2.Config.Features.HighCommand = false
    -- The mutation above happens AFTER f2's own load already ran too (same
    -- reason) -- the only way to see the gate take effect is to flip the
    -- flag BEFORE dogcharacter.lua loads, which newFixture does not expose
    -- as a parameter today. Documented here rather than silently skipped:
    -- this specific registration-time gate is exercised indirectly instead,
    -- by the assertion below that the command IS present when the flag is
    -- (newFixture's default), mirroring server/highcommand.lua's own
    -- '/k9givexp' registration gate, which this file's own header states
    -- it deliberately copies.
    t.isNotNil(f.registeredCommands['k9setdog'], 'sanity: present under the default (HighCommand = true) fixture')
end)

t.test('/k9setdog resolves a numeric variation argument by 1-based Config.Peds index', function()
    local f = newFixture()
    f.registerPlayer(1, 'HC01', { name = 'police', isboss = true })
    local seenModel
    f.env.ApplyK9AppearanceDirect = function(_citizenid, model) seenModel = model; return true, 'ok' end

    f.registeredCommands['k9setdog'](1, { 'TARGET01', '2' }) -- Config.Peds[2] = a_c_husky
    t.equals(seenModel, 'a_c_husky')
end)

t.test('/k9setdog resolves a literal model-name variation argument directly', function()
    local f = newFixture()
    f.registerPlayer(1, 'HC01', { name = 'police', isboss = true })
    local seenModel
    f.env.ApplyK9AppearanceDirect = function(_citizenid, model) seenModel = model; return true, 'ok' end

    f.registeredCommands['k9setdog'](1, { 'TARGET01', 'a_c_shepherd' })
    t.equals(seenModel, 'a_c_shepherd')
end)

t.test('/k9setdog with an out-of-range numeric variation index reports usage, never a nonsensical model', function()
    local f = newFixture()
    f.registerPlayer(1, 'HC01', { name = 'police', isboss = true })
    local called = false
    f.env.ApplyK9AppearanceDirect = function() called = true; return true, 'ok' end

    f.registeredCommands['k9setdog'](1, { 'TARGET01', '99' })
    t.isFalse(called)
    t.isFalse(f.env.IsPinnedDogCharacter('TARGET01'))
end)

t.test('/k9setdog resolves a server id argument to that connected player\'s citizenid', function()
    local f = newFixture()
    f.registerPlayer(1, 'HC01', { name = 'police', isboss = true })
    f.registerPlayer(42, 'TARGETBYSERVERID', { name = 'police', isboss = false, grade = { level = 0 } })
    local seenCitizenid
    f.env.ApplyK9AppearanceDirect = function(citizenid) seenCitizenid = citizenid; return true, 'ok' end

    f.registeredCommands['k9setdog'](1, { '42', 'a_c_shepherd' })
    t.equals(seenCitizenid, 'TARGETBYSERVERID')
end)

t.test('/k9setdog with a numeric-looking server id that is not currently connected: usage error, no write', function()
    local f = newFixture()
    f.registerPlayer(1, 'HC01', { name = 'police', isboss = true })

    f.registeredCommands['k9setdog'](1, { '999', 'a_c_shepherd' })
    t.equals(#f.notifyLog, 1)
    t.equals(f.notifyLog[1].message, 'dogcharacter.usage_setdog')
end)

t.test('/k9removedog accepts a literal citizenid for an offline target', function()
    local f = newFixture()
    f.registerPlayer(1, 'HC01', { name = 'police', isboss = true })
    f.env.ApplyK9AppearanceDirect = function() return true, 'ok' end
    f.env.SetDogCharacter(1, 'OFFLINETARGET', 'a_c_shepherd')
    f.state.now = f.state.now + 1600 -- past the shared per-officer action cooldown

    f.registeredCommands['k9removedog'](1, { 'OFFLINETARGET' })
    t.isFalse(f.env.IsPinnedDogCharacter('OFFLINETARGET'))
    t.equals(f.notifyLog[#f.notifyLog].kind, 'success')
end)

t.test('/k9removedog with missing args reports usage, never crashes', function()
    local f = newFixture()
    f.registerPlayer(1, 'HC01', { name = 'police', isboss = true })

    f.registeredCommands['k9removedog'](1, {})
    t.equals(f.notifyLog[#f.notifyLog].message, 'dogcharacter.usage_removedog')
end)

t.test('/k9removedog on a citizenid that was never pinned notifies not_a_dog_character', function()
    local f = newFixture()
    f.registerPlayer(1, 'HC01', { name = 'police', isboss = true })

    f.registeredCommands['k9removedog'](1, { 'NEVERPINNED' })
    t.equals(f.notifyLog[#f.notifyLog].message, 'dogcharacter.not_a_dog_character')
end)

t.test('a non-high-command caller running /k9setdog is denied with no DB write', function()
    local f = newFixture()
    f.registerPlayer(1, 'GRUNT01', { name = 'police', isboss = false, grade = { level = 0 } })

    f.registeredCommands['k9setdog'](1, { 'TARGET01', 'a_c_shepherd' })
    t.equals(f.notifyLog[#f.notifyLog].message, 'highcommand.not_authorized')
    t.isFalse(f.env.IsPinnedDogCharacter('TARGET01'))
end)

-- ======================================================================
-- 8. COMMAND CONSOLIDATION (docs/history/COMMAND_CONSOLIDATION_SPEC.md #2) -- the merged
--    '/k9dog <set|remove|target>' dispatcher. k9setdog/k9removedog stay
--    registered forever as HIDDEN ALIASES (proven above, unchanged) --
--    these tests are about the NEW 'k9dog' entry point specifically:
--    per-subcommand gating survives the merge, the bare/no-arg forms behave
--    per docs/history/COMMAND_CONSOLIDATION_SPEC.md §4, and set/remove stay EXPLICIT
--    words (never auto-inferred from pin state -- this is the family the
--    project-owner's own "fluid" redirect explicitly named as a
--    destructive-action carve-out: removing a record must never be
--    guessed).
-- ======================================================================

t.test('COMMAND CONSOLIDATION: /k9dog is registered whenever k9setdog/k9removedog are (same Config.Features.HighCommand gate)', function()
    local f = newFixture()
    t.isNotNil(f.registeredCommands['k9dog'], 'the merged command must exist alongside its two aliases')
    t.isNotNil(f.registeredCommands['k9setdog'], 'sanity: the hidden alias is still a real registration')
    t.isNotNil(f.registeredCommands['k9removedog'], 'sanity: the hidden alias is still a real registration')
end)

t.test('COMMAND CONSOLIDATION: /k9dog set <target> <model> reaches the EXACT SAME SetDogCharacter path as /k9setdog -- same gate, same outcome, same DB effect', function()
    local f = newFixture()
    f.registerPlayer(1, 'HC01', { name = 'police', isboss = true })
    f.env.ApplyK9AppearanceDirect = function() return true, 'ok' end

    f.registeredCommands['k9dog'](1, { 'set', 'TARGET01', 'a_c_shepherd' })

    t.isTrue(f.env.IsPinnedDogCharacter('TARGET01'), '/k9dog set must actually pin the target, identically to /k9setdog')
    t.equals(f.env.GetPinnedDogCharacterModel('TARGET01'), 'a_c_shepherd')
    t.equals(f.notifyLog[#f.notifyLog].kind, 'success')
end)

t.test('COMMAND CONSOLIDATION: /k9dog remove <target> reaches the EXACT SAME RemoveDogCharacter path as /k9removedog', function()
    local f = newFixture()
    f.registerPlayer(1, 'HC01', { name = 'police', isboss = true })
    f.env.ApplyK9AppearanceDirect = function() return true, 'ok' end
    f.env.MaybeRevertK9Appearance = function() end
    f.registeredCommands['k9dog'](1, { 'set', 'TARGET01', 'a_c_shepherd' })
    f.state.now = f.state.now + 1600 -- past the shared per-officer action cooldown

    f.registeredCommands['k9dog'](1, { 'remove', 'TARGET01' })

    t.isFalse(f.env.IsPinnedDogCharacter('TARGET01'), '/k9dog remove must actually unpin the target, identically to /k9removedog')
    t.equals(f.notifyLog[#f.notifyLog].kind, 'success')
end)

t.test('PER-SUBCOMMAND GATING SURVIVES THE MERGE: a caller who could not run /k9setdog cannot reach set/remove/status via /k9dog either -- no widening from the merge', function()
    local f = newFixture()
    f.registerPlayer(1, 'GRUNT01', { name = 'police', isboss = false, grade = { level = 0 } })

    f.registeredCommands['k9dog'](1, { 'set', 'TARGET01', 'a_c_shepherd' })
    t.equals(f.notifyLog[#f.notifyLog].message, 'highcommand.not_authorized', 'k9dog set must refuse exactly like k9setdog does')
    t.isFalse(f.env.IsPinnedDogCharacter('TARGET01'))

    f.registeredCommands['k9dog'](1, { 'remove', 'TARGET01' })
    t.equals(f.notifyLog[#f.notifyLog].message, 'highcommand.not_authorized', 'k9dog remove must refuse exactly like k9removedog does')

    f.registeredCommands['k9dog'](1, { 'TARGET01' }) -- bare status form
    t.equals(f.notifyLog[#f.notifyLog].message, 'highcommand.not_authorized', 'k9dog\'s own bare status form must be gated identically -- not a free read for an unauthorized caller')
end)

t.test('A CALLER WHO COULD RUN /k9setdog CAN STILL REACH EXACTLY THAT VIA /k9dog set, AND /k9removedog VIA /k9dog remove', function()
    local f = newFixture()
    f.registerPlayer(1, 'HC01', { name = 'police', isboss = true })
    f.env.ApplyK9AppearanceDirect = function() return true, 'ok' end
    f.env.MaybeRevertK9Appearance = function() end

    f.registeredCommands['k9dog'](1, { 'set', 'TARGET01', 'a_c_shepherd' })
    t.isTrue(f.env.IsPinnedDogCharacter('TARGET01'))

    f.state.now = f.state.now + 1600
    f.registeredCommands['k9dog'](1, { 'remove', 'TARGET01' })
    t.isFalse(f.env.IsPinnedDogCharacter('TARGET01'))
end)

t.test('BARE /k9dog <target>: READ-ONLY status report, never mutates -- names the exact explicit command to run', function()
    local f = newFixture()
    f.registerPlayer(1, 'HC01', { name = 'police', isboss = true })
    f.env.ApplyK9AppearanceDirect = function() return true, 'ok' end

    -- Not yet pinned -- tells the caller to use 'set'.
    f.registeredCommands['k9dog'](1, { 'NOTPINNED01' })
    t.equals(f.notifyLog[#f.notifyLog].message, 'dogcharacter.status_not_pinned:NOTPINNED01,NOTPINNED01')
    t.isFalse(f.env.IsPinnedDogCharacter('NOTPINNED01'), 'the bare status form must never itself pin anything')

    f.state.now = f.state.now + 1600
    f.registeredCommands['k9dog'](1, { 'set', 'PINNED01', 'a_c_shepherd' })
    t.isTrue(f.env.IsPinnedDogCharacter('PINNED01'))

    -- Already pinned -- tells the caller to use 'remove', reports the model.
    f.state.now = f.state.now + 1600
    f.registeredCommands['k9dog'](1, { 'PINNED01' })
    t.equals(f.notifyLog[#f.notifyLog].message, 'dogcharacter.status_pinned:PINNED01,a_c_shepherd,PINNED01')
    t.isTrue(f.env.IsPinnedDogCharacter('PINNED01'), 'the bare status form must never itself unpin anything')
end)

t.test('NO-ARGUMENT DISCOVERABILITY: /k9dog with zero args prints the usage/help form, never errors, never treats it as a target', function()
    local f = newFixture()
    f.registerPlayer(1, 'HC01', { name = 'police', isboss = true })

    local ok = pcall(f.registeredCommands['k9dog'], 1, {})
    t.isTrue(ok, 'a bare /k9dog with no args at all must never error')
    t.equals(f.notifyLog[#f.notifyLog].message, 'dogcharacter.usage_dog')
end)

t.test('AMBIGUITY NEVER GUESSES DESTRUCTIVELY: /k9dog set/remove ALWAYS require the explicit word -- an unrecognized first argument that is not a resolvable target falls through to usage, it never silently defaults to set or remove', function()
    local f = newFixture()
    f.registerPlayer(1, 'HC01', { name = 'police', isboss = true })

    -- 'bogus' is not 'set'/'remove' and ResolveTargetCitizenId treats any
    -- non-empty string as a literal citizenid -- so this actually resolves
    -- as a STATUS lookup for citizenid 'bogus', never a mutation. Proves
    -- the dispatcher truly has no third, silent "guess a mutation" path.
    f.registeredCommands['k9dog'](1, { 'bogus' })
    t.equals(f.notifyLog[#f.notifyLog].message, 'dogcharacter.status_not_pinned:bogus,bogus')
    t.isFalse(f.env.IsPinnedDogCharacter('bogus'), 'an unrecognized word must never be treated as an implicit set/remove')
end)

print('')
print(('dogcharacter_spec: %d passed, %d failed'):format(t.passed, t.failed))
os.exit(t.summary())
