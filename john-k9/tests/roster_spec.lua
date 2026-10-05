--[[
    tests/roster_spec.lua

    Tests server/roster.lua -- the K9 Command Tablet roster data layer +
    server logic (docs/history/ROSTER_SPEC.md, PHASE A) -- against the REAL, unmodified
    production file, loaded alongside the REAL, unmodified
    server/cooldowns.lua and server/datastore.lua (memory-mode: this file's
    own logic, not the SQL-forwarding shape, is what this spec covers --
    tests/datastore_spec.lua's own new PART 5 already proves the k9_personnel
    K9Store accessors directly, DB branch included).

    THE "DELETE-YOUR-OWN-GUARD-AND-WATCH-IT-FAIL" DISCIPLINE, APPLIED
    WITHOUT DELETING CODE: every security-relevant guard below (the
    high-command check, the department-mismatch check, the
    active-certification check) is proven with a SELF-PROVING pattern --
    the SAME call is made twice, with only the one fact the guard is
    supposed to gate on changed between the two calls (e.g. IsHighCommand
    flipped from false to true on the SAME fixture, mid-test), and the
    test asserts the two outcomes actually DIFFER. A guard that was
    silently removed or short-circuited would make both calls return the
    same thing, which is exactly what these assertions catch -- the same
    thing a literal delete-the-guard-and-re-run exercise would catch,
    without requiring a second, throwaway edit to the production file.

    Every mutation is exercised BOTH at the core-logic layer
    (RosterAssignPersonnelRole/RosterSetCallsign/ClearPersonnelRowForCitizenJob,
    called directly, which do NOT check authorization themselves -- see
    their own doc comments in server/roster.lua) AND through the
    `lib.callback` handlers this file registers (which DO re-verify
    IsHighCommand(source) on every call) -- so a regression in EITHER
    layer is caught, not just one.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

-- ----------------------------------------------------------------------
-- Fixture
-- ----------------------------------------------------------------------

--- @param citizenid string
--- @param jobName string?
--- @param extra table? -- { grade = { name, level }, isboss = bool, source = number, charinfo = {...} }
--- @return table -- { PlayerData = {...} }
local function makePlayer(citizenid, jobName, extra)
    extra = extra or {}
    local job = nil
    if jobName then
        job = { name = jobName, grade = extra.grade, isboss = extra.isboss }
    end
    return { PlayerData = { citizenid = citizenid, job = job, source = extra.source, charinfo = extra.charinfo } }
end

--- @param opts table?
--- @return table fixture
local function newFixture(opts)
    opts = opts or {}

    local printedLines = {}
    local function printStub(...)
        local parts = {}
        for i = 1, select('#', ...) do parts[i] = tostring(select(i, ...)) end
        printedLines[#printedLines + 1] = table.concat(parts, '\t')
    end

    local playersBySource = opts.playersBySource or {}
    local playersByCitizenId = opts.playersByCitizenId or {}
    local offlinePlayers = opts.offlinePlayers or {}

    local exportsStub = {
        qbx_core = {
            GetPlayer = function(_self, source) return playersBySource[source] end,
            GetPlayerByCitizenId = function(_self, citizenid) return playersByCitizenId[citizenid] end,
            GetOfflinePlayer = function(_self, citizenid) return offlinePlayers[citizenid] end,
        },
    }

    local callbacks = {}
    local libStub = { callback = { register = function(name, handler) callbacks[name] = handler end } }

    local Config = {
        Features = {
            CommandTablet = opts.commandTabletEnabled ~= false, -- default true
            HighCommand = true,
            XPProgression = opts.xpProgression or false,
            HandlerPartnership = opts.handlerPartnership or false,
        },
        Departments = opts.departments or {
            police = { label = 'Police Department' },
            sheriff = { label = 'Sheriff Department' },
        },
        CertificationTiers = opts.certificationTiers or {
            { key = 'trainee', label = 'Trainee', ordinal = 1 },
            { key = 'certified', label = 'Certified', ordinal = 2 },
            { key = 'senior', label = 'Senior', ordinal = 3 },
        },
        Database = opts.database or { enabled = false },
    }

    -- CONTROLLABLE TIME (leak-fix pass): was a permanently-fixed `return 0`
    -- with a comment claiming "no test in this file relies on real elapsed
    -- time" -- true when written, but that is exactly what made this
    -- fixture structurally unable to see RosterReadCooldown/
    -- RosterMutateCooldown's own cleanup (or lack of it): a cooldown
    -- tracker frozen at a single instant can never expire, so no test
    -- built on it could ever distinguish "cleaned up on disconnect" from
    -- "leaked forever" -- both look identical when `now` never moves.
    -- `nowMs` is now a real, settable upvalue (default 0, unchanged
    -- behavior for every pre-existing test that never touches it) --
    -- `f.advanceTime(ms)` below moves it forward for the tests that need to
    -- actually observe elapsed time.
    local nowMs = opts.now or 0

    -- AddEventHandler (leak-fix pass): server/roster.lua's
    -- RosterReadCooldown/RosterMutateCooldown now call
    -- .RegisterPlayerDropped() at this file's own load time (server/
    -- cooldowns.lua's :RegisterPlayerDropped registers a real
    -- `AddEventHandler('playerDropped', ...)` closure) -- this sandbox
    -- must supply a real AddEventHandler or loading server/roster.lua
    -- itself throws "attempt to call a nil value" before any test below
    -- ever runs. Captures every handler by event name, exactly mirroring
    -- this suite's own `eventHandlers`/`firePlayerDropped`
    -- shape, so `f.firePlayerDropped(source)` below can fire them the same
    -- way FXServer would: by setting the ambient `source` global the
    -- captured closure itself reads (server/cooldowns.lua's
    -- :RegisterPlayerDropped closure takes no argument, same as every
    -- other tracker's own cleanup closure), then invoking every captured
    -- handler with no arguments.
    local eventHandlers = {}
    local function addEventHandlerStub(eventName, handler)
        eventHandlers[eventName] = eventHandlers[eventName] or {}
        eventHandlers[eventName][#eventHandlers[eventName] + 1] = handler
    end

    local env = Sandbox.newEnv({
        Config = Config,
        exports = exportsStub,
        lib = libStub,
        print = printStub,
        IsHighCommand = opts.isHighCommand or function() return true end,
        GetPlayerName = function(_src) return 'NativeName' end,
        AddEventHandler = addEventHandlerStub,
        -- server/cooldowns.lua's NewCooldown/.Consume fall back to
        -- GetGameTimer() whenever no explicit `now` override is passed --
        -- server/roster.lua's own RosterReadCooldown/RosterMutateCooldown
        -- calls never pass one, so this must exist or every single
        -- lib.callback invocation below throws "attempt to call a nil
        -- value" before ever reaching this file's own logic. Reads the
        -- controllable `nowMs` upvalue above (see its own comment for why
        -- this is no longer a bare fixed `0`).
        GetGameTimer = function() return nowMs end,
        QueryCertificationRecord = opts.queryCertificationRecord,
        GetXP = opts.getXP,
        IsPinnedDogCharacter = opts.isPinnedDogCharacter,
        GetPinnedDogCharacterModel = opts.getPinnedDogCharacterModel,
    })

    Sandbox.loadInto('../server/cooldowns.lua', env)
    Sandbox.loadInto('../server/datastore.lua', env)
    Sandbox.loadInto('../server/roster.lua', env)

    return {
        env = env,
        callbacks = callbacks,
        K9Store = env.K9Store,
        printedLines = printedLines,
        playersBySource = playersBySource,
        playersByCitizenId = playersByCitizenId,
        advanceTime = function(deltaMs) nowMs = nowMs + deltaMs end,
        --- Fires every captured `playerDropped` handler as if `source` had
        --- genuinely disconnected -- see addEventHandlerStub's own comment
        --- above for why this sets the ambient `source` global rather than
        --- passing it as an argument.
        --- @param source number
        firePlayerDropped = function(source)
            env.source = source
            for _, handler in ipairs(eventHandlers['playerDropped'] or {}) do
                handler()
            end
        end,
    }
end

-- ----------------------------------------------------------------------
-- GATE: Config.Features.CommandTablet -- "gate the START of a thing,
-- never the STOP". Reused, not a second flag.
-- ----------------------------------------------------------------------

t.test('the whole file is inert when Config.Features.CommandTablet is off -- no callback is ever registered', function()
    local f = newFixture({ commandTabletEnabled = false })
    t.isNil(f.callbacks['john-k9:server:rosterList'])
    t.isNil(f.callbacks['john-k9:server:rosterSetPersonnelRole'])
    t.isNil(f.callbacks['john-k9:server:rosterSetCallsign'])
end)

t.test('every callback IS registered when the flag is on', function()
    local f = newFixture()
    t.isNotNil(f.callbacks['john-k9:server:rosterList'])
    t.isNotNil(f.callbacks['john-k9:server:rosterSetPersonnelRole'])
    t.isNotNil(f.callbacks['john-k9:server:rosterSetCallsign'])
end)

-- ----------------------------------------------------------------------
-- HIGH COMMAND GATE -- every mutation AND the roster read itself. Proven
-- SELF-PROVINGLY: the exact same call, only IsHighCommand's answer
-- changed in between, must produce two DIFFERENT outcomes. A client flag
-- claiming high command must never substitute for the real, server-side
-- check.
-- ----------------------------------------------------------------------

t.test('rosterList: a non-high-command caller is refused; the SAME caller becomes authorized the instant IsHighCommand says so -- never before', function()
    local player = makePlayer('HC-VIEWER', 'police', { grade = { name = 'Officer', level = 1 } })
    local f = newFixture({
        isHighCommand = function() return false end,
        playersBySource = { [1] = player },
    })

    local denied = f.callbacks['john-k9:server:rosterList'](1)
    t.isFalse(denied.ok)
    t.equals(denied.error, 'not_authorized')

    f.env.IsHighCommand = function() return true end
    local allowed = f.callbacks['john-k9:server:rosterList'](1)
    t.isTrue(allowed.ok, 'flipping the REAL server-side IsHighCommand check must be what unlocks this, not anything the client sent')
end)

t.test('rosterSetPersonnelRole: refused for a non-high-command caller EVEN WHEN the payload itself claims high command / success', function()
    local player = makePlayer('HC-ACTOR', 'police', { grade = { name = 'Officer', level = 1 } })
    local f = newFixture({
        isHighCommand = function() return false end,
        playersBySource = { [1] = player },
        playersByCitizenId = { ['HC-ACTOR'] = player, ['TARGET1'] = makePlayer('TARGET1', 'police') },
    })
    f.K9Store.Cert_Insert('TARGET1', 'police', 'HC-ACTOR', nil)

    local payload = { citizenid = 'TARGET1', job = 'police', personnelRole = 'k9', isHighCommand = true, ok = true }
    local denied = f.callbacks['john-k9:server:rosterSetPersonnelRole'](1, payload)
    t.isFalse(denied.ok, 'a client-supplied flag must never substitute for the real server-side check')
    t.equals(denied.error, 'not_authorized')
    t.isNil(f.K9Store.Personnel_GetActiveRow('TARGET1', 'police'), 'a refused mutation must never have written anything')

    f.env.IsHighCommand = function() return true end
    local allowed = f.callbacks['john-k9:server:rosterSetPersonnelRole'](1, payload)
    t.isTrue(allowed.ok)
    t.equals(allowed.outcome, 'assigned')
end)

t.test('rosterSetCallsign: refused for a non-high-command caller, allowed once IsHighCommand says so', function()
    local player = makePlayer('HC-ACTOR2', 'police', { grade = { name = 'Officer', level = 1 } })
    local target = makePlayer('TARGET2', 'police')
    local f = newFixture({
        isHighCommand = function() return false end,
        playersBySource = { [1] = player },
        playersByCitizenId = { ['HC-ACTOR2'] = player, ['TARGET2'] = target },
    })
    f.K9Store.Cert_Insert('TARGET2', 'police', 'HC-ACTOR2', nil)
    f.K9Store.Personnel_Insert('TARGET2', 'police', 'k9', 'HC-ACTOR2')

    local payload = { citizenid = 'TARGET2', job = 'police', callsign = '1-Adam-1' }
    local denied = f.callbacks['john-k9:server:rosterSetCallsign'](1, payload)
    t.isFalse(denied.ok)
    t.equals(denied.error, 'not_authorized')
    t.isNil(f.K9Store.Personnel_GetActiveRow('TARGET2', 'police').callsign)

    f.env.IsHighCommand = function() return true end
    local allowed = f.callbacks['john-k9:server:rosterSetCallsign'](1, payload)
    t.isTrue(allowed.ok)
    t.equals(f.K9Store.Personnel_GetActiveRow('TARGET2', 'police').callsign, '1-Adam-1')
end)

-- ----------------------------------------------------------------------
-- LEAK FIX: RosterReadCooldown / RosterMutateCooldown (QA-found, this
-- pass). Both are keyed by `source` ONLY. Before this fix, NEITHER had a
-- .RegisterPlayerDropped() nor a .StartSweep() -- so a source's entry
-- lived forever, and because FXServer RECYCLES server ids, a brand-new
-- player could inherit a stale "still on cooldown" timestamp left behind
-- by a totally different PRIOR occupant of that same id, on their very
-- first roster read/mutate ever. These tests need the fixture's
-- previously-fixed `GetGameTimer` and previously-absent `AddEventHandler`
-- (both added above, this same pass) to even be expressible -- a cooldown
-- frozen at a single instant can never expire, so no test built on the old
-- fixture could ever have told "cleaned up on disconnect" apart from
-- "leaked forever".
-- ----------------------------------------------------------------------

t.test('LEAK FIX: RosterReadCooldown is cleared on playerDropped -- a source id recycled onto a brand-new player never inherits a stale cooldown left by a different prior occupant', function()
    local f = newFixture()
    f.playersBySource[1] = makePlayer('CIT_OLD', 'police')

    local first = f.callbacks['john-k9:server:rosterList'](1)
    t.isTrue(first.ok, 'sanity: the first read must succeed')

    -- Immediately afterward, with zero real time elapsed, the SAME source
    -- is genuinely still inside ROSTER_READ_COOLDOWN_MS (500ms) -- proves
    -- the tracker is actually gating something, not a vacuous test.
    local second = f.callbacks['john-k9:server:rosterList'](1)
    t.isFalse(second.ok)
    t.equals(second.error, 'rate_limited')

    -- Source 1 disconnects, and FXServer reissues that exact same id to a
    -- brand-new, unrelated player -- with NO real time having passed.
    f.firePlayerDropped(1)
    f.playersBySource[1] = makePlayer('CIT_NEW', 'police')

    local afterRecycle = f.callbacks['john-k9:server:rosterList'](1)
    t.isTrue(afterRecycle.ok,
        'a brand-new player recycled onto a just-freed source id must never inherit a stale cooldown timestamp left behind by a totally different prior occupant of that id')
end)

t.test('LEAK FIX: RosterReadCooldown genuinely expires after real elapsed time too (not ONLY via playerDropped) -- sanity that the tracker still behaves like a cooldown', function()
    local f = newFixture()
    f.playersBySource[1] = makePlayer('CIT_A', 'police')
    t.isTrue(f.callbacks['john-k9:server:rosterList'](1).ok)
    t.isFalse(f.callbacks['john-k9:server:rosterList'](1).ok, 'sanity: still on cooldown before any time passes')

    f.advanceTime(501) -- past ROSTER_READ_COOLDOWN_MS (500)
    t.isTrue(f.callbacks['john-k9:server:rosterList'](1).ok, 'a genuinely elapsed cooldown must allow a fresh read for the SAME still-connected source')
end)

t.test('LEAK FIX: RosterMutateCooldown is cleared on playerDropped -- same recycled-id bug, the OTHER tracker', function()
    local f = newFixture()
    f.playersBySource[1] = makePlayer('CIT_OLD', 'police')

    local first = f.callbacks['john-k9:server:rosterSetPersonnelRole'](1, {})
    t.isFalse(first.ok)
    t.equals(first.error, 'invalid_target', 'sanity: the mutate cooldown is consumed BEFORE payload validation, so an empty payload still proves the cooldown itself fired')

    local second = f.callbacks['john-k9:server:rosterSetPersonnelRole'](1, {})
    t.isFalse(second.ok)
    t.equals(second.error, 'rate_limited', 'sanity: the SAME source is genuinely still inside ROSTER_MUTATE_COOLDOWN_MS (750ms)')

    f.firePlayerDropped(1)
    f.playersBySource[1] = makePlayer('CIT_NEW', 'police')

    local afterRecycle = f.callbacks['john-k9:server:rosterSetPersonnelRole'](1, {})
    t.isFalse(afterRecycle.ok)
    t.equals(afterRecycle.error, 'invalid_target',
        'a brand-new player recycled onto a just-freed source id must reach payload validation, not a stale rate_limited refusal from a totally different prior occupant of that id')
end)

-- ----------------------------------------------------------------------
-- CORE LOGIC -- RosterAssignPersonnelRole. Called directly (this function
-- does NOT check authorization itself -- see its own doc comment).
-- ----------------------------------------------------------------------

t.test('RosterAssignPersonnelRole: rejects a citizenid with no active certification -- becomes assignable the instant one exists, never before', function()
    local f = newFixture({ playersByCitizenId = { ['CERT-CHECK'] = makePlayer('CERT-CHECK', 'police') } })

    local ok, outcome = f.env.RosterAssignPersonnelRole('CERT-CHECK', 'police', 'k9', 'ACTOR')
    t.isFalse(ok)
    t.equals(outcome, 'not_certified')

    f.K9Store.Cert_Insert('CERT-CHECK', 'police', 'ACTOR', nil)
    local ok2, outcome2 = f.env.RosterAssignPersonnelRole('CERT-CHECK', 'police', 'k9', 'ACTOR')
    t.isTrue(ok2)
    t.equals(outcome2, 'assigned')
end)

t.test('RosterAssignPersonnelRole: department_mismatch when the target\'s LIVE job does not match, resolved fresh every call', function()
    local player = makePlayer('DEPT-CHECK', 'sheriff')
    local f = newFixture({ playersByCitizenId = { ['DEPT-CHECK'] = player } })
    f.K9Store.Cert_Insert('DEPT-CHECK', 'police', 'ACTOR', nil)

    local ok, outcome = f.env.RosterAssignPersonnelRole('DEPT-CHECK', 'police', 'k9', 'ACTOR')
    t.isFalse(ok, 'the citizenid\'s LIVE job is sheriff, not police -- this must never silently substitute the clicked department')
    t.equals(outcome, 'department_mismatch')

    -- The SAME citizenid, matched against their REAL live department,
    -- must succeed -- proving this reads the live job fresh, not some
    -- captured/stale value.
    f.K9Store.Cert_Insert('DEPT-CHECK', 'sheriff', 'ACTOR', nil)
    local ok2, outcome2 = f.env.RosterAssignPersonnelRole('DEPT-CHECK', 'sheriff', 'k9', 'ACTOR')
    t.isTrue(ok2)
    t.equals(outcome2, 'assigned')
end)

t.test('RosterAssignPersonnelRole: rejects an unrecognized personnelRole', function()
    local f = newFixture({ playersByCitizenId = { ['ROLE-CHECK'] = makePlayer('ROLE-CHECK', 'police') } })
    f.K9Store.Cert_Insert('ROLE-CHECK', 'police', 'ACTOR', nil)
    local ok, outcome = f.env.RosterAssignPersonnelRole('ROLE-CHECK', 'police', 'medic', 'ACTOR')
    t.isFalse(ok)
    t.equals(outcome, 'invalid_personnel_role')
end)

t.test('RosterAssignPersonnelRole: calling with the SAME role again is a harmless no-op ("unchanged"), never a second row', function()
    local f = newFixture({ playersByCitizenId = { ['SAME-ROLE'] = makePlayer('SAME-ROLE', 'police') } })
    f.K9Store.Cert_Insert('SAME-ROLE', 'police', 'ACTOR', nil)
    f.env.RosterAssignPersonnelRole('SAME-ROLE', 'police', 'k9', 'ACTOR')
    local firstId = f.K9Store.Personnel_GetActiveRow('SAME-ROLE', 'police').id

    local ok, outcome = f.env.RosterAssignPersonnelRole('SAME-ROLE', 'police', 'k9', 'ACTOR')
    t.isTrue(ok)
    t.equals(outcome, 'unchanged')
    t.equals(f.K9Store.Personnel_GetActiveRow('SAME-ROLE', 'police').id, firstId, 'must still be the SAME row, not a new one')
end)

t.test('RosterAssignPersonnelRole: a role CHANGE clears the callsign in the same action (docs/history/ROSTER_SPEC.md §4)', function()
    local f = newFixture({ playersByCitizenId = { ['ROLE-CHANGE'] = makePlayer('ROLE-CHANGE', 'police') } })
    f.K9Store.Cert_Insert('ROLE-CHANGE', 'police', 'ACTOR', nil)
    f.env.RosterAssignPersonnelRole('ROLE-CHANGE', 'police', 'k9', 'ACTOR')
    f.env.RosterSetCallsign('ROLE-CHANGE', 'police', '4-Edward-8')
    t.equals(f.K9Store.Personnel_GetActiveRow('ROLE-CHANGE', 'police').callsign, '4-Edward-8')

    local ok, outcome = f.env.RosterAssignPersonnelRole('ROLE-CHANGE', 'police', 'handler', 'ACTOR')
    t.isTrue(ok)
    t.equals(outcome, 'role_changed')
    local row = f.K9Store.Personnel_GetActiveRow('ROLE-CHANGE', 'police')
    t.equals(row.role, 'handler')
    t.isNil(row.callsign, 'a role change must clear the callsign -- a K9 callsign and a handler callsign mean different things')
end)

t.test('RosterAssignPersonnelRole: FIRE (via ClearPersonnelRowForCitizenJob) then RE-HIRE produces a NEW row and starts back in Unassigned semantics (no callsign)', function()
    local f = newFixture({ playersByCitizenId = { ['FIRE-REHIRE'] = makePlayer('FIRE-REHIRE', 'police') } })
    f.K9Store.Cert_Insert('FIRE-REHIRE', 'police', 'ACTOR', nil)
    f.env.RosterAssignPersonnelRole('FIRE-REHIRE', 'police', 'k9', 'ACTOR')
    f.env.RosterSetCallsign('FIRE-REHIRE', 'police', '6-Frank-2')
    local firstId = f.K9Store.Personnel_GetActiveRow('FIRE-REHIRE', 'police').id

    -- FIRE: certification revoked (mirrors RevokeCertificationForTablet
    -- succeeding), then the best-effort personnel cleanup.
    f.K9Store.Cert_RevokeActive('FIRE-REHIRE', 'police', 'ACTOR', 'other')
    t.isTrue(f.env.ClearPersonnelRowForCitizenJob('FIRE-REHIRE', 'police', 'ACTOR'))
    t.isNil(f.K9Store.Personnel_GetActiveRow('FIRE-REHIRE', 'police'))

    -- RE-HIRE: a fresh certification, then a fresh assignment.
    f.K9Store.Cert_Insert('FIRE-REHIRE', 'police', 'ACTOR', nil)
    local ok, outcome = f.env.RosterAssignPersonnelRole('FIRE-REHIRE', 'police', 'k9', 'ACTOR')
    t.isTrue(ok)
    t.equals(outcome, 'assigned', 'a re-hire must be a fresh assignment, never treated as an unchanged/role-changed edit of the old row')
    local row = f.K9Store.Personnel_GetActiveRow('FIRE-REHIRE', 'police')
    t.isTrue(row.id ~= firstId, 'must be a NEW row')
    t.isNil(row.callsign, 'the old callsign must never be resurrected')
end)

t.test('ClearPersonnelRowForCitizenJob: best-effort, never throws on a citizenid with no active row', function()
    local f = newFixture()
    local ok = f.env.ClearPersonnelRowForCitizenJob('NEVER-ASSIGNED', 'police', 'ACTOR')
    t.isTrue(ok, 'clearing a row that never existed must be a harmless success, never an error a Fire action would have to handle specially')
end)

-- ----------------------------------------------------------------------
-- CORE LOGIC -- RosterSetCallsign
-- ----------------------------------------------------------------------

t.test('RosterSetCallsign: rejects out-of-range length (0 chars is a clear, not a set; 13+ chars is invalid) and disallowed characters', function()
    local f = newFixture({ playersByCitizenId = { ['CS-FORMAT'] = makePlayer('CS-FORMAT', 'police') } })
    f.K9Store.Cert_Insert('CS-FORMAT', 'police', 'ACTOR', nil)
    f.env.RosterAssignPersonnelRole('CS-FORMAT', 'police', 'k9', 'ACTOR')

    local ok1, outcome1 = f.env.RosterSetCallsign('CS-FORMAT', 'police', '1234567890123') -- 13 chars
    t.isFalse(ok1)
    t.equals(outcome1, 'invalid_callsign')

    local ok2, outcome2 = f.env.RosterSetCallsign('CS-FORMAT', 'police', 'bad_underscore')
    t.isFalse(ok2)
    t.equals(outcome2, 'invalid_callsign')

    local ok3, outcome3 = f.env.RosterSetCallsign('CS-FORMAT', 'police', 'bad!char')
    t.isFalse(ok3)
    t.equals(outcome3, 'invalid_callsign')

    -- Exactly 12 chars, letters/digits/spaces/hyphens -- accepted.
    local ok4, outcome4 = f.env.RosterSetCallsign('CS-FORMAT', 'police', 'Unit 12-Ade1')
    t.isTrue(ok4, tostring(outcome4))
    t.equals(outcome4, 'callsign_set')

    -- '' clears (not a format error).
    local ok5, outcome5 = f.env.RosterSetCallsign('CS-FORMAT', 'police', '')
    t.isTrue(ok5)
    t.equals(outcome5, 'callsign_cleared')
end)

t.test('RosterSetCallsign: requires an ACTIVE personnel row -- a citizenid still in Unassigned cannot be given a callsign', function()
    local f = newFixture({ playersByCitizenId = { ['UNASSIGNED-CS'] = makePlayer('UNASSIGNED-CS', 'police') } })
    f.K9Store.Cert_Insert('UNASSIGNED-CS', 'police', 'ACTOR', nil)
    local ok, outcome = f.env.RosterSetCallsign('UNASSIGNED-CS', 'police', '1-Adam-1')
    t.isFalse(ok)
    t.equals(outcome, 'no_active_personnel')
end)

t.test('RosterSetCallsign: COLLISION within a department returns callsign_taken and never overwrites the existing holder, case-insensitively', function()
    local f = newFixture({
        playersByCitizenId = {
            ['CS-A'] = makePlayer('CS-A', 'police'),
            ['CS-B'] = makePlayer('CS-B', 'police'),
        },
    })
    f.K9Store.Cert_Insert('CS-A', 'police', 'ACTOR', nil)
    f.K9Store.Cert_Insert('CS-B', 'police', 'ACTOR', nil)
    f.env.RosterAssignPersonnelRole('CS-A', 'police', 'k9', 'ACTOR')
    f.env.RosterAssignPersonnelRole('CS-B', 'police', 'handler', 'ACTOR')
    f.env.RosterSetCallsign('CS-A', 'police', '8-George-1')

    local ok, outcome = f.env.RosterSetCallsign('CS-B', 'police', '8-GEORGE-1')
    t.isFalse(ok, 'a case-insensitive collision must be refused')
    t.equals(outcome, 'callsign_taken')
    t.equals(f.K9Store.Personnel_GetActiveRow('CS-A', 'police').callsign, '8-George-1', 'the existing holder must never be silently overwritten')
    t.isNil(f.K9Store.Personnel_GetActiveRow('CS-B', 'police').callsign)
end)

t.test('RosterSetCallsign: a callsign colliding ACROSS the two rosters in the same department is also rejected (combined namespace, §4)', function()
    -- CS-A above is a K9 with '8-George-1'; CS-C is a HANDLER in the SAME
    -- department trying to take the identical text.
    local f = newFixture({
        playersByCitizenId = {
            ['CS-A2'] = makePlayer('CS-A2', 'police'),
            ['CS-C'] = makePlayer('CS-C', 'police'),
        },
    })
    f.K9Store.Cert_Insert('CS-A2', 'police', 'ACTOR', nil)
    f.K9Store.Cert_Insert('CS-C', 'police', 'ACTOR', nil)
    f.env.RosterAssignPersonnelRole('CS-A2', 'police', 'k9', 'ACTOR')
    f.env.RosterAssignPersonnelRole('CS-C', 'police', 'handler', 'ACTOR')
    f.env.RosterSetCallsign('CS-A2', 'police', 'Delta-9')

    local ok, outcome = f.env.RosterSetCallsign('CS-C', 'police', 'Delta-9')
    t.isFalse(ok, 'a K9\'s callsign and a handler\'s callsign in the SAME department must share one namespace')
    t.equals(outcome, 'callsign_taken')
end)

t.test('RosterSetCallsign: department_mismatch resolved fresh, same as RosterAssignPersonnelRole', function()
    local f = newFixture({ playersByCitizenId = { ['CS-DEPT'] = makePlayer('CS-DEPT', 'sheriff') } })
    f.K9Store.Cert_Insert('CS-DEPT', 'police', 'ACTOR', nil)
    f.K9Store.Personnel_Insert('CS-DEPT', 'police', 'k9', 'ACTOR')
    local ok, outcome = f.env.RosterSetCallsign('CS-DEPT', 'police', '1-Adam-1')
    t.isFalse(ok)
    t.equals(outcome, 'department_mismatch')
end)

-- ----------------------------------------------------------------------
-- rosterList -- bucketing, sort, and THE FILTER DISCIPLINE (docs/history/ROSTER_SPEC.md
-- §7): a citizenid must stop appearing as hired on EITHER roster the
-- moment their certification's own active flag flips, EVEN IF the
-- k9_personnel cleanup itself never ran (the exact "never gate a
-- termination path" acceptance criterion).
-- ----------------------------------------------------------------------

t.test('rosterList: buckets K9/Handler/Unassigned correctly', function()
    local f = newFixture({
        playersByCitizenId = {
            ['LIST-K9'] = makePlayer('LIST-K9', 'police'),
            ['LIST-HANDLER'] = makePlayer('LIST-HANDLER', 'police'),
            ['LIST-UNASSIGNED'] = makePlayer('LIST-UNASSIGNED', 'police'),
        },
        playersBySource = { [1] = makePlayer('VIEWER', 'police', { isboss = true }) },
    })
    f.K9Store.Cert_Insert('LIST-K9', 'police', 'ACTOR', nil)
    f.K9Store.Cert_Insert('LIST-HANDLER', 'police', 'ACTOR', nil)
    f.K9Store.Cert_Insert('LIST-UNASSIGNED', 'police', 'ACTOR', nil)
    f.env.RosterAssignPersonnelRole('LIST-K9', 'police', 'k9', 'ACTOR')
    f.env.RosterAssignPersonnelRole('LIST-HANDLER', 'police', 'handler', 'ACTOR')

    local result = f.callbacks['john-k9:server:rosterList'](1)
    t.isTrue(result.ok)
    t.equals(#result.k9, 1)
    t.equals(result.k9[1].citizenid, 'LIST-K9')
    t.equals(#result.handlers, 1)
    t.equals(result.handlers[1].citizenid, 'LIST-HANDLER')
    t.equals(#result.unassigned, 1)
    t.equals(result.unassigned[1].citizenid, 'LIST-UNASSIGNED')
end)

t.test('rosterList: a FIRED citizenid disappears from every bucket immediately, even if the k9_personnel row was never cleared', function()
    local f = newFixture({
        playersByCitizenId = { ['GONE'] = makePlayer('GONE', 'police') },
        playersBySource = { [1] = makePlayer('VIEWER2', 'police', { isboss = true }) },
    })
    f.K9Store.Cert_Insert('GONE', 'police', 'ACTOR', nil)
    f.env.RosterAssignPersonnelRole('GONE', 'police', 'k9', 'ACTOR')

    -- Simulate a Fire whose secondary cleanup FAILED -- the certification
    -- is revoked, but the k9_personnel row is deliberately left active=1.
    f.K9Store.Cert_RevokeActive('GONE', 'police', 'ACTOR', 'other')

    local result = f.callbacks['john-k9:server:rosterList'](1)
    t.isTrue(result.ok)
    for _, row in ipairs(result.k9) do t.isTrue(row.citizenid ~= 'GONE') end
    for _, row in ipairs(result.handlers) do t.isTrue(row.citizenid ~= 'GONE') end
    for _, row in ipairs(result.unassigned) do t.isTrue(row.citizenid ~= 'GONE') end
end)

t.test('rosterList: default sort is certification tier ordinal DESCENDING, ties broken by name (docs/history/ROSTER_SPEC.md §9)', function()
    local tierByCitizen = { ALPHA = 'trainee', BRAVO = 'senior', CHARLIE = 'certified', DELTA = 'senior' }
    local f = newFixture({
        playersByCitizenId = {
            ['ALPHA'] = makePlayer('ALPHA', 'police'), ['BRAVO'] = makePlayer('BRAVO', 'police'),
            ['CHARLIE'] = makePlayer('CHARLIE', 'police'), ['DELTA'] = makePlayer('DELTA', 'police'),
        },
        playersBySource = { [1] = makePlayer('VIEWER3', 'police', { isboss = true }) },
        queryCertificationRecord = function(citizenid, _job) return { tier = tierByCitizen[citizenid] } end,
    })
    for cit in pairs(tierByCitizen) do
        f.K9Store.Cert_Insert(cit, 'police', 'ACTOR', nil)
        f.env.RosterAssignPersonnelRole(cit, 'police', 'k9', 'ACTOR')
    end

    local result = f.callbacks['john-k9:server:rosterList'](1)
    local order = {}
    for i, row in ipairs(result.k9) do order[i] = row.citizenid end
    -- senior(3): BRAVO, DELTA (name tiebreak) -> certified(2): CHARLIE -> trainee(1): ALPHA
    t.equals(order[1], 'BRAVO')
    t.equals(order[2], 'DELTA')
    t.equals(order[3], 'CHARLIE')
    t.equals(order[4], 'ALPHA')
end)

os.exit(t.summary())
