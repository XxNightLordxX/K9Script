--[[
    tests/suspects_spec.lua

    server/suspects.lua -- who a K9 may bite, take down or drag.

    Out of the box nothing on a Qbox server sets metadata.wanted, so with
    Config.Combat.RequireWantedStatus on no player could ever be bitten.
    Officers now mark suspects (/k9suspect <id>, or the third eye), and a
    dispatch/MDT can do the same with a server-only event. Pinned here:
      * who may mark (on-duty department member, never the dog itself),
      * the mark makes IsPlayerK9Wanted true, marking again clears it,
      * it expires, and ends when either player leaves,
      * the server event works and cannot be reached as a net event,
      * the override and metadata sources still work, and a failing
        override does not erase a mark,
      * the officer's K9 partner is told.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

local function fixture(opts)
    opts = opts or {}
    local now = 1000
    local players = {}
    local function addPlayer(src, cid, job, onduty, metadata)
        players[src] = { PlayerData = { source = src, citizenid = cid, metadata = metadata or {},
            job = { name = job, onduty = onduty ~= false } } }
    end
    addPlayer(1, 'OFFICER', 'police', true)
    addPlayer(2, 'DOG', 'police', true)
    addPlayer(3, 'SUSPECT', 'unemployed', true)
    addPlayer(4, 'OFFDUTY', 'police', false)
    addPlayer(5, 'CIVILIAN', 'mechanic', true)

    local handlers, netEvents, commands, notifies, timeouts, states = {}, {}, {}, {}, {}, {}
    local Config = {
        Departments = { police = { certifierGrade = 4 } },
        Combat = { RequireWantedStatus = true, SuspectMarkMinutes = 10, WantedStatusCheckOverride = opts.override },
    }
    local env = Sandbox.newEnv({
        Config = Config,
        print = function() end,
        GetGameTimer = function() return now end,
        SetTimeout = function(ms, fn) timeouts[#timeouts + 1] = { at = now + ms, fn = fn } end,
        RegisterCommand = function(name, fn) commands[name] = fn end,
        RegisterNetEvent = function(name, fn) netEvents[name] = fn end,
        AddEventHandler = function(name, fn) handlers[name] = handlers[name] or {}; table.insert(handlers[name], fn) end,
        NotifyPlayer = function(target, text, kind) notifies[#notifies + 1] = { target = target, text = text, kind = kind } end,
        HasK9Role = function(src) return src == 2 end,
        GetActivePartnerCitizenId = function(cid)
            if cid == 'OFFICER' then return 'DOG', false end
            if cid == 'DOG' then return 'OFFICER', true end
        end,
        Player = function(src)
            states[src] = states[src] or {}
            return { state = { set = function(_, key, value) states[src][key] = value end } }
        end,
        exports = { qbx_core = {
            GetPlayer = function(_, src) return players[src] end,
            GetPlayerByCitizenId = function(_, cid)
                for _, p in pairs(players) do if p.PlayerData.citizenid == cid then return p end end
            end,
        } },
    })
    Sandbox.loadInto('../server/cooldowns.lua', env)
    Sandbox.loadInto('../server/suspects.lua', env)

    local f = { env = env, players = players, notifies = notifies, states = states, Config = Config, handlers = handlers, netEvents = netEvents, commands = commands }
    function f.advance(ms)
        now = now + ms
        for i = #timeouts, 1, -1 do
            if timeouts[i].at <= now then local fn = timeouts[i].fn; table.remove(timeouts, i); fn() end
        end
    end
    function f.command(src, ...) env.source = src; commands.k9suspect(src, { ... }) end
    function f.drop(src)
        for _, fn in ipairs(handlers.playerDropped or {}) do env.source = src; fn() end
        players[src] = nil
    end
    function f.lastTo(src)
        for i = #notifies, 1, -1 do if notifies[i].target == src then return notifies[i].text end end
    end
    return f
end

t.test('nobody is a suspect to start with -- a K9 cannot act on a random player', function()
    local f = fixture()
    t.isFalse(f.env.IsPlayerK9Wanted(3))
end)

t.test('an on-duty officer marks a player with /k9suspect <id>: the K9 may now act, and the officer is told', function()
    local f = fixture()
    f.command(1, '3')
    t.isTrue(f.env.IsPlayerK9Wanted(3))
    t.equals(f.lastTo(1), Sandbox.locale('suspects.marked', 3, 10))
    t.equals(f.states[3].k9Suspect, true, 'the third eye can show "Clear" for this player')
end)

t.test('the officer\'s K9 partner is told who was marked', function()
    local f = fixture()
    f.command(1, '3')
    t.equals(f.lastTo(2), Sandbox.locale('suspects.partner_marked', 3))
end)

t.test('running it again clears the mark', function()
    local f = fixture()
    f.command(1, '3')
    f.advance(2000) -- past the anti-spam gap
    f.command(1, '3')
    t.isFalse(f.env.IsPlayerK9Wanted(3))
    t.equals(f.lastTo(1), Sandbox.locale('suspects.cleared', 3))
    t.isNil(f.states[3].k9Suspect)
end)

t.test('the dog can never mark its own targets', function()
    local f = fixture()
    f.command(2, '3')
    t.isFalse(f.env.IsPlayerK9Wanted(3))
    t.equals(f.lastTo(2), Sandbox.locale('suspects.not_allowed'))
end)

t.test('an off-duty officer, or someone outside the K9 departments, cannot mark', function()
    local f = fixture()
    f.command(4, '3')
    f.command(5, '3')
    t.isFalse(f.env.IsPlayerK9Wanted(3))
    t.equals(f.lastTo(4), Sandbox.locale('suspects.not_allowed'))
    t.equals(f.lastTo(5), Sandbox.locale('suspects.not_allowed'))
end)

t.test('/k9suspect with no ID asks the officer\'s own game to mark whoever is nearest', function()
    local f = fixture()
    local sent = {}
    f.env.TriggerClientEvent = function(name, target) sent[#sent + 1] = { name = name, target = target } end
    f.command(1)
    t.equals(#sent, 1)
    t.equals(sent[1].name, 'qbx_k9unit:client:markNearestSuspect')
    t.equals(sent[1].target, 1)
end)

t.test('an offline ID, or your own, is refused plainly', function()
    local f = fixture()
    f.command(1, '99')
    t.equals(f.lastTo(1), Sandbox.locale('suspects.no_player'))
    f.command(1, '1')
    t.equals(f.lastTo(1), Sandbox.locale('suspects.no_player'))
end)

t.test('the third eye sends the same request, and the server checks it the same way', function()
    local f = fixture()
    f.env.source = 5
    f.netEvents['qbx_k9unit:server:toggleSuspectMark'](3)
    t.isFalse(f.env.IsPlayerK9Wanted(3), 'a civilian\'s forged request does nothing')
    f.env.source = 1
    f.netEvents['qbx_k9unit:server:toggleSuspectMark'](3)
    t.isTrue(f.env.IsPlayerK9Wanted(3))
end)

t.test('a mark runs out after SuspectMarkMinutes', function()
    local f = fixture()
    f.command(1, '3')
    f.advance(9 * 60000)
    t.isTrue(f.env.IsPlayerK9Wanted(3))
    f.advance(61000)
    t.isFalse(f.env.IsPlayerK9Wanted(3))
    t.isNil(f.states[3].k9Suspect, 'the third eye stops showing "Clear"')
end)

t.test('a mark ends if the suspect leaves, or if the officer who set it leaves', function()
    local f = fixture()
    f.command(1, '3')
    f.drop(3)
    t.isFalse(f.env.IsPlayerK9Wanted(3))

    local g = fixture()
    g.command(1, '3')
    g.drop(1)
    t.isFalse(g.env.IsPlayerK9Wanted(3))
end)

t.test('a dispatch or MDT script marks and clears with the server-only qbx_k9unit:setK9Suspect event', function()
    local f = fixture()
    t.isNil(f.netEvents['qbx_k9unit:setK9Suspect'], 'never a net event -- no game client can reach it')
    f.handlers['qbx_k9unit:setK9Suspect'][1](3, true, 5)
    t.isTrue(f.env.IsPlayerK9Wanted(3))
    f.advance(5 * 60000 + 1)
    t.isFalse(f.env.IsPlayerK9Wanted(3), 'the minutes it passed are honoured')
    f.handlers['qbx_k9unit:setK9Suspect'][1](3, true)
    f.handlers['qbx_k9unit:setK9Suspect'][1](3, false)
    t.isFalse(f.env.IsPlayerK9Wanted(3))
end)

t.test('the older sources still count: metadata.wanted, and the override', function()
    local f = fixture()
    f.players[3].PlayerData.metadata.wanted = true
    t.isTrue(f.env.IsPlayerK9Wanted(3))

    local g = fixture({ override = function(src) return src == 3 end })
    t.isTrue(g.env.IsPlayerK9Wanted(3))
    t.isFalse(g.env.IsPlayerK9Wanted(5))
end)

t.test('an override that errors fails closed -- but a mark an officer set still counts', function()
    local f = fixture({ override = function() error('dispatch not running') end })
    t.isFalse(f.env.IsPlayerK9Wanted(3))
    f.command(1, '3')
    t.isTrue(f.env.IsPlayerK9Wanted(3))
end)

t.test('with RequireWantedStatus off, anyone is fair game and marking says it is not needed', function()
    local f = fixture()
    f.Config.Combat.RequireWantedStatus = false
    t.isTrue(f.env.IsPlayerK9Wanted(3))
    f.command(1, '3')
    t.equals(f.lastTo(1), Sandbox.locale('suspects.not_needed'))
end)

local function withClientEvents(f)
    local sent = {}
    f.env.TriggerClientEvent = function(name, target, ...) sent[#sent + 1] = { name = name, target = target, args = { ... } } end
    return sent
end

t.test('ONE-TAP ASK: the K9 goes for someone unmarked -- its handler gets a "Mark them?" prompt and the K9 is told', function()
    local f = fixture()
    local sent = withClientEvents(f)
    t.isTrue(f.env.AskHandlerToMarkSuspect(2, 3))
    t.equals(sent[1].name, 'qbx_k9unit:client:suspectMarkAsked')
    t.equals(sent[1].target, 1, 'the prompt goes to the dog\'s partner')
    t.equals(sent[1].args[1], 3)
    t.equals(f.lastTo(2), Sandbox.locale('suspects.asked_handler', 3))
end)

t.test('ONE-TAP ASK: the handler taps "Mark them" -- the suspect is marked and both are told', function()
    local f = fixture()
    withClientEvents(f)
    f.env.AskHandlerToMarkSuspect(2, 3)
    f.env.source = 1
    f.netEvents['qbx_k9unit:server:answerSuspectAsk'](3, true)
    t.isTrue(f.env.IsPlayerK9Wanted(3))
    t.equals(f.lastTo(1), Sandbox.locale('suspects.marked', 3, 10))
    t.equals(f.lastTo(2), Sandbox.locale('suspects.partner_marked', 3))
end)

t.test('ONE-TAP ASK: "Not now" leaves them unmarked and the K9 hears it', function()
    local f = fixture()
    withClientEvents(f)
    f.env.AskHandlerToMarkSuspect(2, 3)
    f.env.source = 1
    f.netEvents['qbx_k9unit:server:answerSuspectAsk'](3, false)
    t.isFalse(f.env.IsPlayerK9Wanted(3))
    t.equals(f.lastTo(2), Sandbox.locale('suspects.handler_declined', 3))
end)

t.test('ONE-TAP ASK: an answer nobody asked for, for a different player, or after 30 seconds does nothing', function()
    local f = fixture()
    withClientEvents(f)
    f.env.source = 1
    f.netEvents['qbx_k9unit:server:answerSuspectAsk'](3, true)
    t.isFalse(f.env.IsPlayerK9Wanted(3), 'no ask was pending')

    f.env.AskHandlerToMarkSuspect(2, 3)
    f.netEvents['qbx_k9unit:server:answerSuspectAsk'](5, true)
    t.isFalse(f.env.IsPlayerK9Wanted(5), 'the answer must match the player asked about')

    f.advance(16000)
    f.env.AskHandlerToMarkSuspect(2, 3)
    f.advance(31000)
    f.netEvents['qbx_k9unit:server:answerSuspectAsk'](3, true)
    t.isFalse(f.env.IsPlayerK9Wanted(3), 'a stale prompt no longer marks anyone')
end)

t.test('ONE-TAP ASK: at most one prompt per K9 every 15 seconds, and never for a K9 with no handler', function()
    local f = fixture()
    local sent = withClientEvents(f)
    f.env.AskHandlerToMarkSuspect(2, 3)
    f.env.AskHandlerToMarkSuspect(2, 3)
    t.equals(#sent, 1)
    f.advance(15001)
    f.env.AskHandlerToMarkSuspect(2, 3)
    t.equals(#sent, 2)

    local g = fixture()
    local sentG = withClientEvents(g)
    g.env.GetActivePartnerCitizenId = function() return nil end
    t.isFalse(g.env.AskHandlerToMarkSuspect(2, 3))
    t.equals(#sentG, 0)
end)

os.exit(t.summary())
