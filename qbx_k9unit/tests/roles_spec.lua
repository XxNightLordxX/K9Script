--[[
    tests/roles_spec.lua

    server/roles.lua -- tiers and specializations merged into one role
    catalog high command edits on the tablet. Owner's choices: high command
    assigns a role; it switches on once the holder's XP reaches it.

    Pinned here:
      * the shipped roles load, with XP and unlocks, and are mirrored into
        Config.K9Specializations (so every existing reader sees them);
      * a role counts only at or above its XP (K9 or handler XP, higher);
      * unlocks come only from held, unlocked roles; bite_takedown restricts
        nobody until some role lists it;
      * only high command can create / edit / delete; bad input is refused;
      * edits persist through K9Store and survive a catalog refresh.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

local function fixture(opts)
    opts = opts or {}
    local rows = {}
    local xp, handlerXp, held = opts.xp or {}, opts.handlerXp or {}, opts.held or {}
    local isHC = opts.isHighCommand or function(src) return src == 1 end

    local Config = {
        K9Specializations = opts.roles or {
            narcotics  = { label = 'Narcotics detection',   xpRequired = 0,    unlocks = { 'detect_narcotics' } },
            patrol     = { label = 'Patrol / apprehension', xpRequired = 0,    unlocks = { 'track_blood' } },
            explosives = { label = 'Explosives detection',  xpRequired = 1250, unlocks = { 'detect_explosives', 'track_gunpowder' } },
        },
        SpecializationTracking = { explosives = { 'gunpowder' }, patrol = { 'blood' } },
        SearchContrabandItems = {},
    }
    local env = Sandbox.newEnv({
        Config = Config,
        print = function() end,
        CreateThread = function() end,
        GetGameTimer = function() return 1000000 end,
        AddEventHandler = function() end,
        IsHighCommand = isHC,
        GetXP = function(cid) return xp[cid] or 0 end,
        GetHandlerXP = function(cid) return handlerXp[cid] or 0 end,
        HasSpecialization = function(cid, _, key)
            -- Mirrors the real accessor: granted AND the role's XP reached.
            return (held[cid] or {})[key] == true and _G.__roles_env.IsRoleXpUnlocked(cid, key)
        end,
        exports = { qbx_core = { GetPlayer = function(_, src) return { PlayerData = { citizenid = 'CID' .. src } } end } },
        K9Store = {
            Role_GetAllRows = function()
                local out = {}
                for k, r in pairs(rows) do out[#out + 1] = { role_key = k, label = r.label, xp_required = r.xp, unlocks = r.unlocks, deleted = r.deleted } end
                return out
            end,
            Role_Upsert = function(k, label, xpReq, unlocks) rows[k] = { label = label, xp = xpReq, unlocks = unlocks, deleted = 0 }; return true end,
            Role_Tombstone = function(k, label) rows[k] = { label = label, xp = 0, unlocks = '', deleted = 1 }; return true end,
        },
        lib = setmetatable({ callback = { register = function(name, fn) (opts.callbacks or {})[name] = fn end } }, { __index = function() return function() end end }),
    })
    _G.__roles_env = env
    Sandbox.loadInto('../server/cooldowns.lua', env)
    local callbacks = {}
    env.lib.callback.register = function(name, fn) callbacks[name] = fn end
    Sandbox.loadInto('../server/roles.lua', env)
    return { env = env, Config = Config, rows = rows, xp = xp, handlerXp = handlerXp, held = held, cb = callbacks }
end

local function roleByKey(list, key)
    for _, r in ipairs(list) do if r.key == key then return r end end
end

t.test('the shipped roles load with their XP and unlocks, and are mirrored into Config.K9Specializations', function()
    local f = fixture()
    local list = f.env.ListRolesForDisplay()
    t.equals(#list, 3)
    t.equals(roleByKey(list, 'explosives').xpRequired, 1250)
    t.equals(table.concat(roleByKey(list, 'explosives').unlocks, ','), 'track_gunpowder,detect_explosives')
    t.equals(f.Config.K9Specializations.explosives.xpRequired, 1250, 'every reader of Config.K9Specializations sees the XP too')
    t.equals(list[#list].key, 'explosives', 'sorted by XP needed')
end)

t.test('a role counts only once the holder\'s XP (K9 or handler, whichever is higher) reaches it', function()
    local f = fixture({ xp = { DOG = 1000 }, handlerXp = { HANDLER = 1300 } })
    t.isFalse(f.env.IsRoleXpUnlocked('DOG', 'explosives'), '1000 K9 XP < 1250')
    t.isTrue(f.env.IsRoleXpUnlocked('HANDLER', 'explosives'), '1300 handler XP >= 1250')
    f.xp.DOG = 1250
    t.isTrue(f.env.IsRoleXpUnlocked('DOG', 'explosives'), 'exactly the requirement is enough')
    t.isTrue(f.env.IsRoleXpUnlocked('NEWBIE', 'narcotics'), 'a 0 XP role is on from day one')
    t.isFalse(f.env.IsRoleXpUnlocked('DOG', 'nonexistent'), 'a role that does not exist never counts')
end)

t.test('unlocks come only from held roles whose XP is reached', function()
    local f = fixture({ xp = { DOG = 100 }, held = { DOG = { patrol = true, explosives = true } } })
    local unlocks = f.env.GetHeldRoleUnlocks('DOG', 'police')
    t.isTrue(unlocks.track_blood, 'patrol (0 XP) is on')
    t.isNil(unlocks.track_gunpowder, 'explosives is held but its 1250 XP is not reached yet')
    f.xp.DOG = 5000
    t.isTrue(f.env.GetHeldRoleUnlocks('DOG', 'police').track_gunpowder)
end)

t.test('bite_takedown restricts nobody until some role lists it -- then only its holders may', function()
    local f = fixture({ held = { DOG = { patrol = true } } })
    t.isTrue(f.env.RoleUnlockPermits('DOG', 'police', 'bite_takedown'))
    t.isTrue(f.env.RoleUnlockPermits('OTHER', 'police', 'bite_takedown'))

    local r = f.cb['qbx_k9unit:server:tabletRolesSave'](1, { key = 'patrol', label = 'Patrol / apprehension', xpRequired = 0, unlocks = { 'track_blood', 'bite_takedown' } })
    t.isTrue(r.ok)
    t.isTrue(f.env.RoleUnlockPermits('DOG', 'police', 'bite_takedown'), 'a patrol holder may bite')
    t.isFalse(f.env.RoleUnlockPermits('OTHER', 'police', 'bite_takedown'), 'someone without it may not')
end)

t.test('high command creates a role: its key comes from the name, it is saved and in the catalog at once', function()
    local f = fixture()
    local r = f.cb['qbx_k9unit:server:tabletRolesSave'](1, { label = 'Tactical K9', xpRequired = 4000, unlocks = { 'track_blood', 'bite_takedown' } })
    t.isTrue(r.ok)
    t.equals(r.key, 'tactical_k9')
    t.equals(f.rows.tactical_k9.xp, 4000)
    t.equals(f.rows.tactical_k9.unlocks, 'track_blood,bite_takedown')
    t.equals(f.Config.K9Specializations.tactical_k9.label, 'Tactical K9', 'grant validation (which reads this table) now accepts it')
    t.isNotNil(roleByKey(r.roles, 'tactical_k9'))
end)

t.test('the same name twice gets a distinct key; editing keeps the key', function()
    local f = fixture()
    local a = f.cb['qbx_k9unit:server:tabletRolesSave'](1, { label = 'Scout', xpRequired = 0 })
    f.env.GetGameTimer = function() return 2000000 end
    local b = f.cb['qbx_k9unit:server:tabletRolesSave'](1, { label = 'Scout', xpRequired = 0 })
    t.equals(a.key, 'scout')
    t.equals(b.key, 'scout_2')
    f.env.GetGameTimer = function() return 3000000 end
    local e = f.cb['qbx_k9unit:server:tabletRolesSave'](1, { key = 'scout', label = 'Scout Team', xpRequired = 50 })
    t.isTrue(e.ok)
    t.equals(e.key, 'scout')
    t.equals(f.Config.K9Specializations.scout.label, 'Scout Team')
end)

t.test('only high command can save or delete; bad input is refused before anything is written', function()
    local f = fixture()
    local save = f.cb['qbx_k9unit:server:tabletRolesSave']
    t.equals(save(2, { label = 'X', xpRequired = 0 }).error, 'not_authorized')
    t.equals(f.cb['qbx_k9unit:server:tabletRolesDelete'](2, 'patrol').error, 'not_authorized')
    t.equals(save(1, { label = '', xpRequired = 0 }).error, 'invalid_label')
    t.equals(save(1, { label = 'X', xpRequired = -5 }).error, 'invalid_xp')
    t.equals(save(1, { label = 'X', xpRequired = 1.5 }).error, 'invalid_xp')
    t.equals(save(1, { label = 'X', xpRequired = 0, unlocks = { 'fly' } }).error, 'invalid_unlocks')
    t.equals(save(1, { key = 'nope', label = 'X', xpRequired = 0 }).error, 'unknown_role')
    t.isNil(next(f.rows), 'nothing was written')
end)

t.test('deleting a role removes it from the catalog (a tombstone, so a shipped role stays gone after a refresh)', function()
    local f = fixture({ held = { DOG = { patrol = true } } })
    local r = f.cb['qbx_k9unit:server:tabletRolesDelete'](1, 'patrol')
    t.isTrue(r.ok)
    t.isNil(f.Config.K9Specializations.patrol)
    t.isNil(f.env.GetHeldRoleUnlocks('DOG', 'police').track_blood, 'a deleted role unlocks nothing, even for someone still holding it')
    f.env.RefreshRoleCatalog()
    t.isNil(f.Config.K9Specializations.patrol, 'still gone after a refresh')
end)

t.test('saved edits survive a catalog refresh (they are read back from K9Store)', function()
    local f = fixture()
    f.cb['qbx_k9unit:server:tabletRolesSave'](1, { key = 'narcotics', label = 'Drug dog', xpRequired = 300, unlocks = { 'detect_narcotics' } })
    f.env.RefreshRoleCatalog()
    t.equals(f.Config.K9Specializations.narcotics.label, 'Drug dog')
    t.equals(f.Config.K9Specializations.narcotics.xpRequired, 300)
end)

t.test('a shipped role with no unlocks list falls back to what it unlocked before roles existed', function()
    local f = fixture({ roles = { patrol = { label = 'Patrol' }, explosives = { label = 'Explosives' } } })
    local list = f.env.ListRolesForDisplay()
    t.equals(table.concat(roleByKey(list, 'patrol').unlocks, ','), 'track_blood,detect_patrol')
    t.equals(table.concat(roleByKey(list, 'explosives').unlocks, ','), 'track_gunpowder,detect_explosives')
end)

t.test('the tablet list offers every unlock as a choice and says whether the viewer may edit', function()
    local f = fixture()
    local r = f.cb['qbx_k9unit:server:tabletRolesList'](1)
    t.isTrue(r.ok)
    t.isTrue(r.canManage)
    t.isFalse(f.cb['qbx_k9unit:server:tabletRolesList'](2).canManage)
    local keys = {}
    for _, u in ipairs(r.unlockOptions) do keys[#keys + 1] = u.key end
    t.equals(table.concat(keys, ','), 'track_blood,track_gunpowder,detect_explosives,detect_narcotics,detect_patrol,bite_takedown')
end)

os.exit(t.summary())
