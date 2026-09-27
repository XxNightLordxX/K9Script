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
    exports = setmetatable({ qbx_core = qbx }, { __index = function(_, k) return magic('exports.' .. k) end, __call = function() end }),
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
