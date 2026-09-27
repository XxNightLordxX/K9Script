--[[
    tests/rolesjourney_spec.lua

    ROLES, THE SUPPLY SHOP, WARRANTS AND THE AUDIT TRAIL, END TO END,
    across every real server script (same harness as tests/journey_spec.lua:
    all of fxmanifest.lua's server files, the real config.lua, the in-memory
    data store, three players).

    The path high command actually walks: certify a dog and a handler,
    create a role on the tablet, give it to the dog, watch it stay locked
    until the dog's XP reaches it, gate bites and a shop item on it, get
    refused deleting a role the shop still needs, sniff someone with a
    warrant, read the audit trail, then clean up. Each step goes through
    the same callbacks the tablet and game use.
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
local handlers, callbacks = {}, {}
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

local oxHooks, warrantRows = {}, {}
local env
env = setmetatable({
    print = function(...) if os.getenv('VERBOSE') then print(...) end end,
    IsDuplicityVersion = function() return true end,
    GetCurrentResourceName = function() return 'qbx_k9unit' end,
    -- Only ox_inventory answers as the inventory, so the shop's purchase
    -- check attaches exactly as it would in game.
    GetResourceState = function(name) if name == 'qb-inventory' or name == 'qs-inventory' or name == 'ps-inventory' then return 'missing' end return 'started' end,
    GetGameTimer = function() return now end,
    os = { time = function() return 1700000000 + math.floor(now / 1000) end, date = os.date, clock = os.clock },
    GetConvar = function(_, d) return d end, GetConvarInt = function(_, d) return d end,
    Wait = function() end, CreateThread = function() end, SetTimeout = function() end,
    Citizen = { CreateThread = function() end, Wait = function() end, SetTimeout = function() end },
    AddEventHandler = function(n, fn) handlers[n] = handlers[n] or {}; table.insert(handlers[n], fn) end,
    RegisterNetEvent = function() end,
    RegisterCommand = function() end,
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
        ox_inventory = setmetatable({
            registerHook = function(_, ev, fn) oxHooks[ev] = fn; return 1 end,
            Items = function() return nil end,
        }, { __index = function() return function() return {} end end }) }, { __index = function(_, k) return magic('exports.' .. k) end, __call = function() end }),
    MySQL = setmetatable({
        query = setmetatable({ await = function(sql)
            if type(sql) == 'string' and sql:find('mdt_warrants', 1, true) then return warrantRows end
            return {}
        end }, { __call = function() end }),
    }, { __index = function(_, k) return magic('MySQL.' .. k) end }),
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
local function cb(name, src, ...) local fn = assert(callbacks[name], 'no callback ' .. name); return fn(src, ...) end
local function lastNotify(src) for i = #notifies, 1, -1 do if notifies[i].target == src then return notifies[i].text end end end
local function tick(ms) now = now + (ms or 5000) end

local function notifiesTo(src, pat) local n = 0; for _, x in ipairs(notifies) do if x.target == src and tostring(x.text):find(pat) then n = n + 1 end end; return n end
local function roleByKey(list, key) for _, r in ipairs(list or {}) do if r.key == key then return r end end end

t.test('A. Chief certifies Rex as a K9 and Sam as a handler -- the messages say which, point at roles next, and each lands on the right roster', function()
    local r = cb('qbx_k9unit:server:tabletCertify', 1, 'DOG', 'police', 'a_c_shepherd')
    check(r and r.ok, 'certify Rex: ' .. tostring(r and r.error))
    check(notifiesTo(1, 'as a K9') == 1, 'the Chief is told Rex is being made a K9')
    tick()
    r = cb('qbx_k9unit:server:tabletCertify', 1, 'HANDLER', 'police')
    check(r and r.ok, 'certify Sam: ' .. tostring(r and r.error))
    check(notifiesTo(1, 'as a handler') == 1, 'the Chief is told Sam is a handler')
    check(notifiesTo(1, 'give them roles') >= 2, 'and to give roles next')
    local dogRow = env.K9Store.Personnel_GetActiveRow('DOG', 'police')
    local handlerRow = env.K9Store.Personnel_GetActiveRow('HANDLER', 'police')
    check(dogRow and dogRow.role == 'k9', 'certifying with a breed puts Rex on the K9 roster, got ' .. tostring(dogRow and dogRow.role))
    check(handlerRow and handlerRow.role == 'handler', 'certifying as handler puts Sam on the Handler roster, got ' .. tostring(handlerRow and handlerRow.role))
end)

t.test('B. everyone sees the shipped roles; only the Chief may edit them', function()
    local list = cb('qbx_k9unit:server:tabletRolesList', 1)
    check(list and list.ok and #list.roles == 3, 'three shipped roles')
    check(list.canManage == true, 'the Chief can manage')
    check(cb('qbx_k9unit:server:tabletRolesList', 2).canManage == false, 'Rex cannot')
    check(cb('qbx_k9unit:server:tabletRolesSave', 2, { label = 'Hax', xpRequired = 0 }).error == 'not_authorized', 'Rex cannot create a role')
end)

t.test('C. the Chief creates "Tactical K9" (500 XP, bites and blood tracking)', function()
    tick(60000)
    local r = cb('qbx_k9unit:server:tabletRolesSave', 1, { label = 'Tactical K9', xpRequired = 500, unlocks = { 'bite_takedown', 'track_blood' } })
    check(r and r.ok and r.key == 'tactical_k9', 'created: ' .. tostring(r and (r.error or r.key)))
    check(roleByKey(r.roles, 'tactical_k9').xpRequired == 500, 'listed with its 500 XP')
end)

t.test('D. the Chief gives Rex the role -- held, but locked until 500 XP; his record shows both', function()
    tick(60000)
    local r = cb('qbx_k9unit:server:tabletGrantSpecialization', 1, 'DOG', 'police', 'tactical_k9')
    check(r and r.ok, 'grant: ' .. tostring(r and r.error))
    check(notifiesTo(2, 'Tactical K9 role') == 1, 'Rex is told the role by its name, not its key')
    check(env.HasSpecializationGranted('DOG', 'police', 'tactical_k9'), 'Rex holds it')
    check(not env.HasSpecialization('DOG', 'police', 'tactical_k9'), 'locked at 0 XP')
    check(env.RoleUnlockPermits('DOG', 'police', 'bite_takedown') == false, 'a role now lists bites, and Rex\'s is locked: no bites yet')
    local rec = cb('qbx_k9unit:server:tabletRequestMyRecord', 2)
    check(rec and rec.ok and type(rec.roleXp) == 'number', 'his record carries his XP')
    check(roleByKey(rec.roleCatalog, 'tactical_k9') ~= nil, 'and the live role list, new role included')
end)

t.test('E. the Chief gives Rex 600 XP -- the role switches on and he may bite', function()
    tick(60000)
    local r = cb('qbx_k9unit:server:tabletGiveXp', 1, 'DOG', 600)
    check(r and r.ok, 'give XP: ' .. tostring(r and (r.error or r.message)))
    check(tostring(r and r.message):find('Rex Test'), 'the confirmation names Rex, not his citizen id: ' .. tostring(r and r.message))
    check(env.HasSpecialization('DOG', 'police', 'tactical_k9'), 'role active')
    check(env.RoleUnlockPermits('DOG', 'police', 'bite_takedown') == true, 'Rex may bite')
    check(env.RoleUnlockPermits('HANDLER', 'police', 'bite_takedown') == false, 'Sam, without the role, may not')
end)

t.test('F. supply shop: the medkit needs Tactical K9 -- Rex can buy it, Sam is told which role he lacks', function()
    tick(60000)
    local r = cb('qbx_k9unit:server:equipmentShopItemsUpsert', 1, { key = 'k9_medkit', price = 100, requiredSpecialization = 'tactical_k9' })
    check(r and r.ok, 'item saved: ' .. tostring(r and (r.reason or r.error)))
    local buy = oxHooks.buyItem
    check(type(buy) == 'function', 'the purchase check is attached to the inventory')
    if type(buy) ~= 'function' then return end
    check(buy({ shopType = 'k9supply', source = 2, itemName = 'k9_medkit' }) ~= false, 'Rex can buy it')
    check(buy({ shopType = 'k9supply', source = 3, itemName = 'k9_medkit' }) == false, 'Sam cannot')
    check(tostring(lastNotify(3)):find('Tactical K9 role'), 'Sam is told the role by name: ' .. tostring(lastNotify(3)))
end)

t.test('G. deleting a role the shop still needs is refused, naming the item', function()
    tick(60000)
    local r = cb('qbx_k9unit:server:tabletRolesDelete', 1, 'tactical_k9')
    check(r and r.error == 'role_in_use_by_shop_items' and r.items and r.items[1] == 'k9_medkit', 'refused: ' .. tostring(r and r.error))
    check(env.Config.K9Specializations.tactical_k9 ~= nil, 'the role is still there')
end)

t.test('H. Rex sniffs Sam, who has an approved arrest warrant -- told by name', function()
    warrantRows[1] = { type = 'Arrest Warrant' }
    tick(60000)
    check(env.CheckWarrantOnSniff(2, 3) == 'Arrest Warrant', 'warrant found')
    check(lastNotify(2) == env.locale('warrants.found', 'Sam Test', 'arrest warrant'), 'Rex is told: ' .. tostring(lastNotify(2)))
    warrantRows[1] = nil
end)

t.test('I. the audit trail lists the role changes, newest first, with who made them', function()
    tick(60000)
    local audit = cb('qbx_k9unit:server:tabletAuditCatalog', 1, 'roles', 20)
    check(audit and audit.ok and #audit.rows >= 1, 'audit rows: ' .. tostring(audit and (audit.error or #audit.rows)))
    check(audit.rows[1].role_key == 'tactical_k9' and audit.rows[1].changed_by == 'CHIEF', 'names the role and the Chief')
end)

t.test('J. the Chief clears the shop requirement, then deletes the role -- bites open to everyone again', function()
    tick(60000)
    check(cb('qbx_k9unit:server:equipmentShopItemsUpsert', 1, { key = 'k9_medkit', price = 100 }).ok, 'requirement cleared')
    tick(60000)
    local r = cb('qbx_k9unit:server:tabletRolesDelete', 1, 'tactical_k9')
    check(r and r.ok, 'deleted: ' .. tostring(r and r.error))
    check(not env.HasSpecialization('DOG', 'police', 'tactical_k9'), 'the deleted role no longer counts')
    check(env.RoleUnlockPermits('HANDLER', 'police', 'bite_takedown') == true, 'no role lists bites any more')
    local audit = cb('qbx_k9unit:server:tabletAuditCatalog', 1, 'roles', 20)
    check(audit.rows[1].action == 'role_delete', 'the delete is audited too')
end)

t.test('K. a role with no unlocks saves; a handler\'s own XP counts toward roles', function()
    tick(60000)
    local r = cb('qbx_k9unit:server:tabletRolesSave', 1, { label = 'Senior Handler', xpRequired = 300, unlocks = {} })
    check(r and r.ok and r.key == 'senior_handler', 'a role with nothing ticked saves: ' .. tostring(r and (r.error or r.key)))
    tick(60000)
    check(cb('qbx_k9unit:server:tabletGrantSpecialization', 1, 'HANDLER', 'police', 'senior_handler').ok, 'given to Sam')
    check(not env.HasSpecialization('HANDLER', 'police', 'senior_handler'), 'locked with no XP')
    local realHandlerXP = env.GetHandlerXP
    env.GetHandlerXP = function(cid) if cid == 'HANDLER' then return 350 end return realHandlerXP(cid) end
    check(env.HasSpecialization('HANDLER', 'police', 'senior_handler'), 'Sam\'s 350 handler XP switches it on')
    env.GetHandlerXP = realHandlerXP
end)

t.test('L. taking a role away removes what it unlocked', function()
    tick(60000)
    check(cb('qbx_k9unit:server:tabletRolesSave', 1, { key = 'patrol', label = 'Patrol / apprehension', xpRequired = 0, unlocks = { 'track_blood', 'bite_takedown' } }).ok, 'patrol now unlocks bites')
    tick(60000)
    check(cb('qbx_k9unit:server:tabletGrantSpecialization', 1, 'DOG', 'police', 'patrol').ok, 'Rex given Patrol')
    check(env.RoleUnlockPermits('DOG', 'police', 'bite_takedown') == true, 'Rex may bite')
    tick(60000)
    local r = cb('qbx_k9unit:server:tabletRevokeSpecialization', 1, 'DOG', 'police', 'patrol')
    check(r and r.ok, 'revoked: ' .. tostring(r and r.error))
    check(env.RoleUnlockPermits('DOG', 'police', 'bite_takedown') == false, 'Rex may no longer bite')
end)

t.test('M. an old tier-gated shop item is still enforced (and can be cleared with None)', function()
    tick(60000)
    local r = cb('qbx_k9unit:server:equipmentShopItemsUpsert', 1, { key = 'k9_medkit', price = 100, requiredTierKey = 'senior' })
    check(r and r.ok, 'legacy tier requirement saved: ' .. tostring(r and (r.reason or r.error)))
    check(oxHooks.buyItem({ shopType = 'k9supply', source = 2, itemName = 'k9_medkit' }) == false, 'Rex (default tier) is refused')
    tick(60000)
    check(cb('qbx_k9unit:server:equipmentShopItemsUpsert', 1, { key = 'k9_medkit', price = 100 }).ok, 'cleared')
    check(oxHooks.buyItem({ shopType = 'k9supply', source = 2, itemName = 'k9_medkit' }) ~= false, 'Rex can buy it again')
end)

t.test('N. decertifying someone switches all their roles off', function()
    tick(60000)
    check(cb('qbx_k9unit:server:tabletGrantSpecialization', 1, 'DOG', 'police', 'narcotics').ok, 'Rex given Narcotics')
    check(env.HasSpecialization('DOG', 'police', 'narcotics'), 'active while certified')
    tick(60000)
    local r = cb('qbx_k9unit:server:tabletDecertify', 1, 'DOG', 'police')
    check(r and r.ok, 'decertified: ' .. tostring(r and r.error))
    check(not env.HasSpecialization('DOG', 'police', 'narcotics'), 'no longer counts')
end)

t.test('every message any player was shown along the way has real text', function()
    local missing = {}
    for _, n in ipairs(notifies) do if tostring(n.text):find('^<<') then missing[#missing + 1] = n.text end end
    t.equals(#missing, 0, table.concat(missing, ', '))
end)

os.exit(t.summary())
