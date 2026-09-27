--[[
    tests/journey_spec.lua

    ONE WHOLE SHIFT, END TO END, ACROSS THE REAL SERVER. Every other spec
    loads one or two files with the rest stubbed; this loads EVERY server
    script in fxmanifest.lua's order, with the real config.lua and the
    in-memory data store, three players (a high-command chief, the player
    who plays the dog, a handler), and drives a real sequence of actions
    through the same net events and callbacks the game and tablet use.

    WHY IT EXISTS: it found a bug no single-file spec could. Once a handler
    could be certified without being turned into a dog, HasK9Role still
    treated every certification as "is the dog", so a certified handler and
    a real K9 were refused with "Both of you are playing K9s" -- each file's
    own tests were green because each stubbed the other.

    Engine natives nobody here cares about resolve to an inert stub; the
    ones the journey depends on (players, peds, positions, models) are real
    fakes below.
]]
local t = dofile('testkit.lua')
local ROOT = '../'
local function read(p) local f = assert(io.open(ROOT .. p)); local s = f:read('a'); f:close(); return s end

local manifest = read('fxmanifest.lua'):gsub('%-%-%[(=*)%[.-%]%1%]', ''):gsub('%-%-[^\n]*', '')
local function block(name)
    local b = manifest:match(name .. '%s*(%b{})') or '{}'
    local out = {}
    for item in b:gmatch("'([^']+)'") do if item:sub(1, 1) ~= '@' then out[#out + 1] = item end end
    return out
end

local magicMT
local function magic(name) return setmetatable({ __name = name }, magicMT) end
magicMT = {
    __index = function(self, k) return magic(rawget(self, '__name') .. '.' .. tostring(k)) end,
    __call = function() return nil end,
    __len = function() return 0 end,
}

local localeData = {}
do
    local src = read('locales/en.json')
    for group, body in src:gmatch('"([%w_]+)"%s*:%s*(%b{})') do
        for k, v in body:gmatch('"([%w_]+)"%s*:%s*"(.-[^\\])"') do localeData[group .. '.' .. k] = v end
    end
end

local now = 100000
local handlers, netEvents, commands, callbacks = {}, {}, {}, {}
local clientEvents, notifies = {}, {}
local HUMAN = 1111
local function hash(s) local h = 7; for i = 1, #s do h = (h * 31 + s:byte(i)) % 2147483647 end; return h end

-- players
local players = {}
local function addPlayer(src, cid, first, job, grade, isboss)
    players[src] = {
        PlayerData = { source = src, citizenid = cid, charinfo = { firstname = first, lastname = 'Test' },
            job = { name = job, label = job, grade = { level = grade, name = 'g' .. grade }, isboss = isboss, onduty = true },
            metadata = {} },
        Functions = { SetMetaData = function() end },
        ped = src * 100, model = HUMAN, coords = { x = src, y = 0, z = 0 },
    }
end
addPlayer(1, 'CHIEF', 'Chief', 'police', 4, true)
addPlayer(2, 'DOG', 'Rex', 'police', 1, false)
addPlayer(3, 'HANDLER', 'Sam', 'police', 1, false)
addPlayer(4, 'SUSPECT', 'Joe', 'unemployed', 0, false)
addPlayer(5, 'WANTED', 'Vic', 'unemployed', 0, false)
players[5].coords = { x = 2.5, y = -0.5, z = 0 }
players[4].coords = { x = 2.5, y = 0.5, z = 0 }
local function byPed(ped) for _, p in pairs(players) do if p.ped == ped then return p end end end
local function byCid(cid) for _, p in pairs(players) do if p.PlayerData.citizenid == cid then return p end end end

local qbx = {
    GetPlayer = function(_, src) return players[src] end,
    GetPlayerByCitizenId = function(_, cid) return byCid(cid) end,
    GetOfflinePlayer = function() return nil end,
    GetPlayers = function() return players end,
}
local vec
vec = function(x, y, z)
    return setmetatable({ x = x or 0, y = y or 0, z = z or 0 }, { __sub = function(a, b) return vec(a.x - b.x, a.y - b.y, a.z - b.z) end, __len = function(a) return math.sqrt(a.x ^ 2 + a.y ^ 2 + a.z ^ 2) end })
end

local env
env = setmetatable({
    print = function(...) if os.getenv('VERBOSE') then print(...) end end,
    IsDuplicityVersion = function() return true end,
    GetCurrentResourceName = function() return 'qbx_k9unit' end,
    GetResourceState = function() return 'started' end,
    GetGameTimer = function() return now end,
    os = { time = function() return 1700000000 + math.floor(now / 1000) end, date = os.date, clock = os.clock },
    GetConvar = function(_, d) return d end, GetConvarInt = function(_, d) return d end,
    Wait = function() end, CreateThread = function() end, SetTimeout = function() end,
    Citizen = { CreateThread = function() end, Wait = function() end, SetTimeout = function() end },
    AddEventHandler = function(n, fn) handlers[n] = handlers[n] or {}; table.insert(handlers[n], fn) end,
    RegisterNetEvent = function(n, fn) if fn then netEvents[n] = fn end end,
    RegisterCommand = function(n, fn) commands[n] = fn end,
    TriggerEvent = function(n, ...) for _, fn in ipairs(handlers[n] or {}) do fn(...) end end,
    TriggerClientEvent = function(n, target, ...) clientEvents[#clientEvents + 1] = { event = n, target = target, args = { ... } } end,
    GetPlayerPed = function(src) return players[src] and players[src].ped or 0 end,
    DoesEntityExist = function(ped) return byPed(ped) ~= nil end,
    GetEntityCoords = function(ped) local p = byPed(ped); return p and vec(p.coords.x, p.coords.y, p.coords.z) or vec() end,
    GetEntityModel = function(ped) local p = byPed(ped); return p and p.model or 0 end,
    GetEntityHealth = function() return 200 end,
    -- network ids are the ped handles themselves in this fake world
    NetworkGetEntityFromNetworkId = function(n) return n end,
    NetworkGetNetworkIdFromEntity = function(e) return e end,
    NetworkGetEntityOwner = function(e) local p = byPed(e); return p and p.PlayerData.source or 0 end,
    GetEntityType = function(e) return byPed(e) and 1 or 0 end,
    IsPedAPlayer = function(e) return byPed(e) ~= nil end,
    GetVehiclePedIsIn = function() return 0 end,
    GetEntitySpeed = function() return 0 end,
    GetEntityHeading = function() return 0 end,
    GetPedSourceOfDeath = function() return 0 end,
    IsEntityDead = function() return false end,
    GetPlayerName = function(src) return 'P' .. tostring(src) end,
    GetPlayers = function() local o = {}; for s in pairs(players) do o[#o + 1] = tostring(s) end; return o end,
    GetHashKey = hash, joaat = hash,
    vector3 = vec, vec3 = vec,
    json = { encode = function() return '{}' end, decode = function() return nil end },
    LoadResourceFile = function(_, p) local f = io.open(ROOT .. p); if not f then return nil end; local s = f:read('a'); f:close(); return s end,
    SaveResourceFile = function() return true end,
    locale = function(key, ...) local s = localeData[key]; if not s then return '<<' .. key .. '>>' end; local ok, r = pcall(string.format, s, ...); return ok and r or s end,
    lib = setmetatable({
        callback = { register = function(n, fn) callbacks[n] = fn end, await = function() return nil end },
        locale = function() end,
    }, { __index = function(_, k) return magic('lib.' .. k) end }),
    exports = setmetatable({ qbx_core = qbx,
        -- A stand-in ox_inventory: every export exists and every pocket is empty,
        -- so a sniff runs to the end (clean) the way it does in game.
        ox_inventory = setmetatable({}, { __index = function() return function() return {} end end }) }, { __index = function(_, k) return magic('exports.' .. k) end, __call = function() end }),
    MySQL = setmetatable({}, { __index = function(_, k) return magic('MySQL.' .. k) end }),
    PerformHttpRequest = function() end,
    source = 0,
}, { __index = function(_, k) if _G[k] ~= nil then return _G[k] end; return magic(k) end })

local files = {}
for _, p in ipairs(block('shared_scripts')) do files[#files + 1] = p end
for _, p in ipairs(block('server_scripts')) do files[#files + 1] = p end
for _, p in ipairs(files) do
    local chunk = assert(load(read(p), '@' .. p, 't', env))
    local ok, err = pcall(chunk)
    if not ok then print('LOAD FAIL ' .. p .. ': ' .. tostring(err)) end
end
-- capture notifications after notify.lua defined NotifyPlayer
env.NotifyPlayer = function(target, text, kind, ...) notifies[#notifies + 1] = { target = target, text = text, kind = kind } end
for _, fn in ipairs(handlers['onResourceStart'] or {}) do pcall(fn, 'qbx_k9unit') end
for _, fn in ipairs(handlers['QBCore:Server:OnPlayerLoaded'] or {}) do pcall(fn) end

local function check(cond, msg) t.isTrue(cond == true or (cond ~= nil and cond ~= false), msg) end
local function net(name, src, ...) env.source = src; local fn = assert(netEvents[name], 'no net event ' .. name); return fn(...) end
local function cb(name, src, ...) local fn = assert(callbacks[name], 'no callback ' .. name); return fn(src, ...) end
local function lastNotify(src) for i = #notifies, 1, -1 do if notifies[i].target == src then return notifies[i].text end end end
local function eventsTo(name, src) local n = 0; for _, e in ipairs(clientEvents) do if e.event == name and (src == nil or e.target == src) then n = n + 1 end end; return n end
local function tick(ms) now = now + (ms or 5000) end

t.test('1. Chief certifies Rex AS A K9 (German Shepherd) from the tablet', function()
    local r = cb('qbx_k9unit:server:tabletCertify', 1, 'DOG', 'police', 'a_c_shepherd')
    check(r and r.ok, 'certify as K9 ok: ' .. tostring(r and r.error))
    check(env.HasK9Access(2), 'Rex has K9 access')
    local swap
    for _, e in ipairs(clientEvents) do if e.event == 'qbx_k9unit:client:applyK9Ped' and e.target == 2 then swap = e end end
    check(swap ~= nil, 'Rex was sent the swap to a dog')
    if swap then
        players[2].model = hash('a_c_shepherd')
        net('qbx_k9unit:server:confirmK9PedSwap', 2, swap.args[1], true)
        check(env.GetAssignedK9Model and env.GetAssignedK9Model('DOG') == 'a_c_shepherd', 'assignment saved as a_c_shepherd, got ' .. tostring(env.GetAssignedK9Model and env.GetAssignedK9Model('DOG')))
    end
end)

t.test('2. Chief certifies Sam as a HANDLER with /k9certify -- looks unchanged', function()
    tick()
    local before = eventsTo('qbx_k9unit:client:applyK9Ped', 3)
    commands['k9certify'](1, { '3' })
    check(env.HasK9Access(3), 'Sam certified')
    check(eventsTo('qbx_k9unit:client:applyK9Ped', 3) == before, 'Sam was NOT turned into a dog')
end)

t.test('3. Sam partners up with Rex (request + accept)', function()
    tick()
    net('qbx_k9unit:server:requestPartnerUp', 3, 2)
    net('qbx_k9unit:server:respondPartnerUp', 2, 3, true)
    check(env.IsActivePartnerOf('DOG', 'HANDLER'), 'partnered: ' .. tostring(lastNotify(3)))
end)

t.test('4. Sam clips the leash on -- partners, so no prompt', function()
    tick()
    local prompts = eventsTo('qbx_k9unit:client:leashAttachRequest')
    net('qbx_k9unit:server:requestLeashAttach', 3, 2)
    check(eventsTo('qbx_k9unit:client:leashAttachRequest') == prompts, 'no accept prompt between partners')
    check(eventsTo('qbx_k9unit:client:leashAttached', 2) == 1 and eventsTo('qbx_k9unit:client:leashAttached', 3) == 1, 'both leashed: ' .. tostring(lastNotify(3)))
    net('qbx_k9unit:server:detachLeash', 3)
    check(eventsTo('qbx_k9unit:client:leashDetached', 2) >= 1, 'detached')
end)

t.test('4a. Chief gives Rex 50 XP from the tablet', function()
    tick()
    local r = cb('qbx_k9unit:server:tabletGiveXp', 1, 'DOG', 50)
    check(r and r.ok, 'give XP ok: ' .. tostring(r and (r.error or r.message)))
end)

t.test('4b. Sam (a certified HANDLER, human) throws the fetch ball', function()
    tick()
    local before = #clientEvents
    net('qbx_k9unit:server:requestThrowFetchBall', 3)
    check(#clientEvents > before, 'the server answered the throw: ' .. tostring(lastNotify(3)))
    check(lastNotify(3) ~= env.locale('fetch.not_authorized_equipment'), 'a certified handler is allowed to throw')
end)

t.test('4c. Rex searches the suspect', function()
    tick()
    local r = cb('qbx_k9unit:server:searchTarget', 2, 'person', players[4].ped)
    check(r ~= nil, 'search answered')
    check(r and r.reason ~= 'not_authorized' and r.reason ~= 'invalid_target', 'search allowed: ' .. tostring(r and (r.reason or r.ok)))
end)

t.test('4c2. Rex sniffs Vic, who has an approved arrest warrant in sc-dispatch -- the sniff marks him and Rex and Sam are told', function()
    tick(20000)
    local realMySQL = env.MySQL
    env.MySQL = setmetatable({ query = { await = function(sql, params)
        if sql:find('mdt_warrants', 1, true) then
            return params[1] == 'WANTED' and { { type = 'Arrest Warrant' } } or {}
        end
        return realMySQL.query.await(sql, params)
    end } }, { __index = realMySQL })
    local r = cb('qbx_k9unit:server:searchTarget', 2, 'person', players[5].ped)
    env.MySQL = realMySQL
    check(r and r.ok, 'the sniff finished: ' .. tostring(r and (r.reason or r.ok)))
    check(lastNotify(2) == env.locale('suspects.warrant_found', 5, 'Arrest Warrant'), 'Rex hears about the warrant, got ' .. tostring(lastNotify(2)))
    check(lastNotify(3) == env.locale('suspects.warrant_found_partner', 5, 'Arrest Warrant'), 'Sam hears too, got ' .. tostring(lastNotify(3)))
    check(env.IsPlayerK9Wanted(5), 'Vic is now a suspect')
    check(not env.IsPlayerK9Wanted(4), 'Joe, with no warrant, is not')
end)

t.test('4d. Rex tries to bite a player who is NOT wanted -- refused, and told exactly why', function()
    tick()
    net('qbx_k9unit:server:requestBiteHold', 2, players[4].ped)
    check(lastNotify(2) == env.locale('combat.not_eligible_target'), 'refused with the wanted-status reason, got ' .. tostring(lastNotify(2)))
    check(eventsTo('qbx_k9unit:client:suspectMarkAsked', 3) == 1, 'Sam, his handler, gets a one-tap "Mark them?" prompt')
end)

t.test('4e. Rex cannot mark his own target; Sam taps "Mark them", Rex is told, and then bites and holds', function()
    tick()
    commands['k9suspect'](2, { '4' })
    check(lastNotify(2) == env.locale('suspects.not_allowed'), 'the dog is refused, got ' .. tostring(lastNotify(2)))
    net('qbx_k9unit:server:answerSuspectAsk', 3, 4, true)
    check(lastNotify(2) == env.locale('suspects.partner_marked', 4), 'Sam tapped "Mark them"; Rex hears Joe was marked, got ' .. tostring(lastNotify(2)))
    local before = #clientEvents
    net('qbx_k9unit:server:requestBiteHold', 2, players[4].ped)
    check(#clientEvents > before, 'the bite reached a client: ' .. tostring(lastNotify(2)))
    net('qbx_k9unit:server:releaseBiteHold', 2)
end)

t.test('4e2. Sam (the handler, a human) cannot use a dog-only move -- his bite is refused and nothing reaches the suspect', function()
    tick(20000)
    local before = eventsTo('qbx_k9unit:client:biteHoldStarted') + eventsTo('qbx_k9unit:client:applyBiteHold')
    local notesBefore = #notifies
    net('qbx_k9unit:server:requestBiteHold', 3, players[4].ped)
    local after = eventsTo('qbx_k9unit:client:biteHoldStarted') + eventsTo('qbx_k9unit:client:applyBiteHold')
    check(after == before, 'no bite started for a human handler')
    check(#notifies > notesBefore, 'he is told no, not silently ignored')
end)

t.test('4e3. Rex asks for the nearest trail to track -- answered, not refused for access', function()
    tick()
    local r = cb('qbx_k9unit:server:findNearestTrackableSource', 2)
    check(type(r) == 'table', 'tracking answered')
end)

t.test('4f. Rex deploys a kennel', function()
    tick()
    local before = #clientEvents
    net('qbx_k9unit:server:requestDeployKennel', 2)
    check(#clientEvents > before, 'deploy answered: ' .. tostring(lastNotify(2)))
end)

t.test('4g. each player opens their own tablet record -- the dog reads as a K9, the handler as a handler', function()
    tick()
    local dog = cb('qbx_k9unit:server:tabletRequestMyRecord', 2)
    tick()
    local handler = cb('qbx_k9unit:server:tabletRequestMyRecord', 3)
    check(dog and dog.ok, 'Rex record ok')
    check(handler and handler.ok, 'Sam record ok')
    check(dog and dog.viewer and dog.viewer.isK9 == true, 'Rex is shown as the K9, got ' .. tostring(dog and dog.viewer and dog.viewer.isK9))
    check(handler and handler.viewer and handler.viewer.isK9 ~= true, 'Sam is shown as a handler')
end)

t.test('5. Chief force-ends the partnership from the tablet; history names the Chief', function()
    tick()
    local r = cb('qbx_k9unit:server:tabletForceEndPartnership', 1, 'HANDLER')
    check(r and r.ok, 'force end ok: ' .. tostring(r and r.error))
    check(not env.IsActivePartnerOf('DOG', 'HANDLER'), 'partnership gone')
    tick()
    local hist = cb('qbx_k9unit:server:tabletRequestMyPartnerships', 2)
    local row = hist and hist.partnerships and hist.partnerships[1]
    check(row and row.endedByName == 'Chief Test', 'Rex\'s history names the Chief, got ' .. tostring(row and (row.endedByName or row.endedBySystemReason)))
end)

t.test('6. Rex tries anything to turn himself human -- impossible; Chief reverts him', function()
    local selfRevert = cb('qbx_k9unit:server:tabletRevertK9Ped', 2, 'DOG')
    check(selfRevert and not selfRevert.ok, 'Rex cannot revert himself')
    tick()
    local r = cb('qbx_k9unit:server:tabletRevertK9Ped', 1, 'DOG')
    check(r and r.ok, 'Chief reverts Rex: ' .. tostring(r and r.error))
end)

t.test('7. Chief decertifies Sam from the tablet', function()
    tick()
    local r = cb('qbx_k9unit:server:tabletDecertify', 1, 'HANDLER', 'police')
    check(r and r.ok, 'decertify ok: ' .. tostring(r and r.error))
    check(not env.HasK9Access(3), 'Sam no longer has access')
end)

t.test('every message any player was shown along the way has real text -- no missing translation', function()
    local missing = {}
    for _, n in ipairs(notifies) do if tostring(n.text):find('^<<') then missing[#missing + 1] = n.text end end
    t.equals(#missing, 0, table.concat(missing, ', '))
end)

os.exit(t.summary())
