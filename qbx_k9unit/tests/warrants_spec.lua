--[[
    tests/warrants_spec.lua

    server/warrants.lua.
      * A K9 may act on ANY player by default (RequireWantedStatus ships
        false) -- the owner removed suspect marking entirely.
      * The optional wanted gate still works for an owner who turns it on.
      * The sniff looks the person up in sc-dispatch's MDT and tells the K9
        and its partner about an approved arrest or bench warrant.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

local function fixture(opts)
    opts = opts or {}
    local queries, notifies = {}, {}
    local players = {}
    local function addPlayer(src, cid, metadata)
        players[src] = { PlayerData = { source = src, citizenid = cid, metadata = metadata or {} } }
    end
    addPlayer(1, 'HANDLER')
    addPlayer(2, 'DOG')
    addPlayer(3, 'SUSPECT')
    addPlayer(5, 'CIVILIAN')

    local Config = {
        Combat = {
            RequireWantedStatus = opts.requireWanted == true,
            WantedStatusCheckOverride = opts.override,
            WantedFromDispatch = opts.dispatchCfg or { resource = 'sc-dispatch', warrantTypes = { 'arrest', 'bench' } },
        },
    }
    local env = Sandbox.newEnv({
        Config = Config,
        print = function() end,
        NotifyPlayer = function(target, text, kind) notifies[#notifies + 1] = { target = target, text = text, kind = kind } end,
        GetActivePartnerCitizenId = function(cid)
            if cid == 'HANDLER' then return 'DOG', false end
            if cid == 'DOG' then return 'HANDLER', true end
        end,
        GetResourceState = function(name) return (opts.running or { ['sc-dispatch'] = true })[name] and 'started' or 'missing' end,
        MySQL = { query = { await = function(sql, params)
            queries[#queries + 1] = { sql = sql, params = params }
            if opts.mysql then return opts.mysql(sql, params) end
            return {}
        end } },
        exports = { qbx_core = {
            GetPlayer = function(_, src) return players[src] end,
            GetPlayerByCitizenId = function(_, cid)
                for _, p in pairs(players) do if p.PlayerData.citizenid == cid then return p end end
            end,
        } },
    })
    Sandbox.loadInto('../server/warrants.lua', env)
    local f = { env = env, players = players, queries = queries, notifies = notifies, Config = Config }
    function f.lastTo(src)
        for i = #notifies, 1, -1 do if notifies[i].target == src then return notifies[i].text end end
    end
    return f
end

local function warrantsFor(byCid, opts)
    opts = opts or {}
    return function(sql, params)
        if opts.noApprovalColumn and sql:find('approval_status', 1, true) then error('Unknown column approval_status') end
        if opts.broken then error('connection lost') end
        return byCid[params[1]] or {}
    end
end

t.test('a K9 can act on ANY player by default -- no mark, warrant or wanted flag needed', function()
    local f = fixture()
    t.isTrue(f.env.IsPlayerK9Wanted(3))
    t.isTrue(f.env.IsPlayerK9Wanted(5))
end)

t.test('the shipped config.lua has the wanted gate OFF', function()
    local env = Sandbox.newEnv({})
    Sandbox.loadInto('../config.lua', env)
    t.equals(env.Config.Combat.RequireWantedStatus, false)
    t.isNil(env.Config.Combat.SuspectMarkMinutes, 'suspect marking is gone, and so is its setting')
end)

t.test('an owner who turns the gate on: metadata.wanted and the override decide; an erroring override fails closed', function()
    local f = fixture({ requireWanted = true })
    t.isFalse(f.env.IsPlayerK9Wanted(3))
    f.players[3].PlayerData.metadata.wanted = true
    t.isTrue(f.env.IsPlayerK9Wanted(3))

    local g = fixture({ requireWanted = true, override = function(src) return src == 5 end })
    t.isTrue(g.env.IsPlayerK9Wanted(5))
    t.isFalse(g.env.IsPlayerK9Wanted(3))

    local h = fixture({ requireWanted = true, override = function() error('dispatch down') end })
    t.isFalse(h.env.IsPlayerK9Wanted(3))
end)

t.test('no suspect marking is left anywhere: no command, no net event, no marking globals', function()
    local f = fixture()
    for _, name in ipairs({ 'ToggleK9SuspectMark', 'IsK9SuspectMarked', 'AskHandlerToMarkSuspect', 'MarkNearestSuspect' }) do
        t.isNil(rawget(f.env, name), name .. ' is gone')
    end
    local function exists(path) local h = io.open(path) if h then h:close() return true end return false end
    t.isFalse(exists('../server/suspects.lua'))
    t.isFalse(exists('../client/suspects.lua'))
end)

t.test('SNIFF: an approved ARREST warrant is reported to the K9 and its partner -- information only, nothing else changes', function()
    local f = fixture({ mysql = warrantsFor({ SUSPECT = { { type = 'Arrest Warrant' } } }) })
    f.env.CharacterNameForSource = function(src) return src == 3 and 'Sam Suspect' or ('player ' .. src) end
    t.equals(f.env.CheckWarrantOnSniff(2, 3), 'Arrest Warrant')
    t.equals(f.lastTo(2), Sandbox.locale('warrants.found', 'Sam Suspect', 'arrest warrant'), 'names the person, not their server id')
    t.equals(f.lastTo(1), Sandbox.locale('warrants.found_partner', 'Sam Suspect', 'arrest warrant'))
    t.contains(f.queries[1].sql, "COALESCE(approval_status, 'approved') = 'approved'", 'only approved warrants, like sc-dispatch itself')
    t.contains(f.queries[1].sql, 'active = 1')
    t.equals(f.queries[1].params[1], 'SUSPECT')
end)

t.test('SNIFF: a bench warrant is reported; a search warrant (a place, not a person) is not; no warrant says nothing', function()
    local f = fixture({ mysql = warrantsFor({ SUSPECT = { { type = 'Bench Warrant' } }, CIVILIAN = { { type = 'Search Warrant' } } }) })
    t.equals(f.env.CheckWarrantOnSniff(2, 3), 'Bench Warrant')
    local before = #f.notifies
    t.isNil(f.env.CheckWarrantOnSniff(2, 5))
    t.equals(#f.notifies, before)
end)

t.test('SNIFF: an old sc-dispatch row that just says "Arrest" reads as "Arrest Warrant"', function()
    local f = fixture({ mysql = warrantsFor({ SUSPECT = { { type = 'Arrest' } } }) })
    t.equals(f.env.CheckWarrantOnSniff(2, 3), 'Arrest Warrant')
end)

t.test('SNIFF: a database from before sc-dispatch added approval_status still works', function()
    local f = fixture({ mysql = warrantsFor({ SUSPECT = { { type = 'Arrest Warrant' } } }, { noApprovalColumn = true }) })
    t.equals(f.env.CheckWarrantOnSniff(2, 3), 'Arrest Warrant')
    t.equals(#f.queries, 2)
end)

t.test('SNIFF: a database that cannot be read reports nothing', function()
    local f = fixture({ mysql = warrantsFor({}, { broken = true }) })
    t.isNil(f.env.CheckWarrantOnSniff(2, 3))
    t.equals(#f.notifies, 0)
end)

t.test('SNIFF: nothing is read when sc-dispatch is not running, or when the owner turned it off', function()
    local f = fixture({ running = {}, mysql = warrantsFor({ SUSPECT = { { type = 'Arrest Warrant' } } }) })
    t.isNil(f.env.CheckWarrantOnSniff(2, 3))
    t.equals(#f.queries, 0)

    local g = fixture({ dispatchCfg = { resource = nil }, mysql = warrantsFor({ SUSPECT = { { type = 'Arrest Warrant' } } }) })
    t.isNil(g.env.CheckWarrantOnSniff(2, 3))
    t.equals(#g.queries, 0)
end)

t.test('SNIFF: no background polling -- loading the file reads nothing', function()
    local f = fixture()
    t.equals(#f.queries, 0)
end)

os.exit(t.summary())
