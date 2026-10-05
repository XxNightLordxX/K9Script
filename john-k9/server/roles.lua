--[[
    john-k9/server/roles.lua

    K9 ROLES -- the owner's merge of certification tiers and
    specializations ("the tiers and specializations should be merged and
    the k9 highcommand can create roles and apply those ... so as they get
    xp they get access to those tiers"). Owner's choices: high command
    assigns a role, and it switches on once that person's XP reaches the
    role's requirement.

    A ROLE is { label, xpRequired, unlocks }:
      label       what the tablet shows ("Narcotics detection").
      xpRequired  the XP the holder needs before the role does anything --
                  their K9 XP or their handler XP, whichever is higher.
      unlocks     what it switches on, from a closed list (UNLOCK
                  VOCABULARY below): tracking types (track_blood,
                  track_gunpowder), contraband detection categories
                  (detect_<category>) and bite_takedown.

    WHERE ROLES LIVE
      * The shipped roles are config.lua's Config.K9Specializations.
      * High command's tablet edits are rows in k9_roles (K9Store.Role_*):
        a row overrides a role's label / XP / unlocks, adds a new role, or
        (a tombstone) removes one -- the same overlay shape as the tier
        catalog in server/certtiers.lua.
      * Who holds which role is still the specialization grant table
        (k9_certification_specializations), keyed by role key, and granted
        or revoked with the existing tablet actions. HasSpecialization
        (server/certifications/accessors.lua) now also asks
        IsRoleXpUnlocked, so a role only counts once its XP is reached.

    THE LIVE CATALOG IS MIRRORED INTO Config.K9Specializations IN PLACE
    (label + xpRequired per key), so every existing reader -- grant
    validation, the shop's required role, search and tracking -- sees roles
    created on the tablet with no change of its own.

    WHAT CHANGED FOR THE FEATURES THAT READ ROLES
      * Tracking (server/tracking.lua): a trail type is available when a
        held, unlocked role has track_<type>. Scent is always available.
      * Search (server/search.lua): a contraband category counts when a
        held, unlocked role has detect_<category>.
      * Bite & takedown (server/combat.lua): while NO role lists
        bite_takedown, every K9 may bite (the shipped default). The moment
        high command gives any role bite_takedown, only holders of an
        unlocked role with it may. Releasing a hold is never gated.
    High command bypasses all of it, as before (HasSpecialization's own
    high-command bypass).
]]

local MAX_ROLES = 40
local MAX_XP_REQUIRED = 10000000
local ROLE_KEY_PATTERN = '^[a-z0-9_]+$'
local ROLE_KEY_MAX = 32
local LABEL_MAX = 60

local RoleEditCooldown = NewCooldown(750)
RoleEditCooldown.RegisterPlayerDropped()

-- ======================================================================
-- UNLOCK VOCABULARY -- closed; the tablet shows these as checkboxes.
-- ======================================================================
local function TitleCase(word)
    return (tostring(word):gsub('_', ' '):gsub('^%l', string.upper))
end

--- Trail types a role may unlock: every type config.lua's
--- Config.SpecializationTracking names, plus blood and gunpowder (the two
--- tracking.lua knows). Scent is never listed -- it is always on.
local function KnownTrackTypes()
    local seen, out = {}, {}
    local function add(t)
        if type(t) == 'string' and t ~= '' and t ~= 'scent' and not seen[t] then seen[t] = true; out[#out + 1] = t end
    end
    add('blood'); add('gunpowder')
    for _, types in pairs(type(Config.SpecializationTracking) == 'table' and Config.SpecializationTracking or {}) do
        if type(types) == 'table' then for _, t in ipairs(types) do add(t) end end
    end
    table.sort(out)
    return out
end

--- Contraband categories a role may detect: every category
--- Config.SearchContrabandItems names, plus each shipped role's own key
--- (a category is a role key by the shipped convention).
local function KnownDetectCategories(baseRoles)
    local seen, out = {}, {}
    local function add(c)
        if type(c) == 'string' and c ~= '' and not seen[c] then seen[c] = true; out[#out + 1] = c end
    end
    for key in pairs(baseRoles) do add(key) end
    for k, v in pairs(type(Config.SearchContrabandItems) == 'table' and Config.SearchContrabandItems or {}) do
        if type(k) == 'string' and type(v) == 'string' then add(v) end
    end
    table.sort(out)
    return out
end

local UNLOCK_KEYS = {}     -- ordered { key, label }
local IS_UNLOCK_KEY = {}   -- key -> true

local function BuildUnlockVocabulary(baseRoles)
    UNLOCK_KEYS, IS_UNLOCK_KEY = {}, {}
    local function add(key, label) UNLOCK_KEYS[#UNLOCK_KEYS + 1] = { key = key, label = label }; IS_UNLOCK_KEY[key] = true end
    for _, t in ipairs(KnownTrackTypes()) do add('track_' .. t, locale('roles.unlock_track_template', TitleCase(t))) end
    for _, c in ipairs(KnownDetectCategories(baseRoles)) do add('detect_' .. c, locale('roles.unlock_detect_template', TitleCase(c))) end
    add('bite_takedown', locale('roles.unlock_bite_takedown'))
end

--- @return table<string, boolean>
local function ParseUnlocks(value)
    local set = {}
    if type(value) == 'table' then
        for k, v in pairs(value) do
            local key = (type(k) == 'number') and v or (v == true and k or nil)
            if type(key) == 'string' and IS_UNLOCK_KEY[key] then set[key] = true end
        end
    elseif type(value) == 'string' then
        for key in value:gmatch('[^,%s]+') do
            if IS_UNLOCK_KEY[key] then set[key] = true end
        end
    end
    return set
end

local function SortedUnlockList(set)
    local out = {}
    for _, entry in ipairs(UNLOCK_KEYS) do if set[entry.key] then out[#out + 1] = entry.key end end
    return out
end

-- ======================================================================
-- CATALOG
-- ======================================================================
local BASE_ROLES = {} -- snapshot of the shipped roles
local ROLES = {}      -- live catalog: key -> { label, xpRequired, unlocks = set }
-- Keys of deleted roles. A new role never reuses one: people who held the
-- deleted role still have that grant on record, and would silently get a
-- brand-new role that happened to share its name.
local DELETED_KEYS = {}

local function NormalizeXp(value)
    local n = tonumber(value)
    if not n or n ~= n or n < 0 then return 0 end
    return math.min(math.floor(n), MAX_XP_REQUIRED)
end

--- The shipped roles, read once. A shipped role without an `unlocks` list
--- falls back to what it unlocked before roles existed: the trail types
--- Config.SpecializationTracking gives its key, and detecting its own key
--- as a contraband category.
local function SnapshotBaseRoles()
    local base = {}
    local cfg = type(Config.K9Specializations) == 'table' and Config.K9Specializations or {}
    for key, def in pairs(cfg) do
        if type(key) == 'string' and type(def) == 'table' then
            base[key] = { label = type(def.label) == 'string' and def.label or key, xpRequired = NormalizeXp(def.xpRequired), rawUnlocks = def.unlocks }
        end
    end
    BuildUnlockVocabulary(base)
    for key, role in pairs(base) do
        if type(role.rawUnlocks) == 'table' then
            role.unlocks = ParseUnlocks(role.rawUnlocks)
        else
            local fallback = { ['detect_' .. key] = true }
            local tracks = type(Config.SpecializationTracking) == 'table' and Config.SpecializationTracking[key]
            if type(tracks) == 'table' then for _, t in ipairs(tracks) do fallback['track_' .. t] = true end end
            role.unlocks = ParseUnlocks(fallback)
        end
        role.rawUnlocks = nil
    end
    return base
end

local function CopyRole(role)
    local unlocks = {}
    for k in pairs(role.unlocks or {}) do unlocks[k] = true end
    return { label = role.label, xpRequired = role.xpRequired, unlocks = unlocks }
end

--- Rewrites Config.K9Specializations in place from the live catalog, so
--- every reader holding that table sees the change.
local function MirrorIntoConfig()
    if type(Config.K9Specializations) ~= 'table' then Config.K9Specializations = {} end
    local live = Config.K9Specializations
    for key in pairs(live) do live[key] = nil end
    for key, role in pairs(ROLES) do live[key] = { label = role.label, xpRequired = role.xpRequired } end
end

--- Rebuilds the live catalog: shipped roles, then every k9_roles row on
--- top. Yields (a database read) when the database is on.
function RefreshRoleCatalog()
    local fresh, deleted = {}, {}
    for key, role in pairs(BASE_ROLES) do fresh[key] = CopyRole(role) end
    for _, row in ipairs(K9Store.Role_GetAllRows()) do
        local key = row.role_key
        if type(key) == 'string' then
            if tonumber(row.deleted) == 1 or row.deleted == true then
                fresh[key] = nil
                deleted[key] = true
            else
                fresh[key] = { label = tostring(row.label or key), xpRequired = NormalizeXp(row.xp_required), unlocks = ParseUnlocks(row.unlocks or '') }
            end
        end
    end
    ROLES = fresh
    DELETED_KEYS = deleted
    MirrorIntoConfig()
end

BASE_ROLES = SnapshotBaseRoles()
for key, role in pairs(BASE_ROLES) do ROLES[key] = CopyRole(role) end
MirrorIntoConfig()

CreateThread(function()
    if type(K9Store.WaitForSchemaCheckToSettle) == 'function' and not K9Store.WaitForSchemaCheckToSettle() then
        print('[John-K9] roles: the database check had not finished in time -- using the roles from config.lua for this session. The next role edit on the tablet (or a restart) picks up saved changes.')
        return
    end
    RefreshRoleCatalog()
end)

-- ======================================================================
-- QUESTIONS OTHER FILES ASK
-- ======================================================================

--- The XP a role requirement is measured against: the person's K9 XP or
--- handler XP, whichever is higher (a dog earns one, a handler the other).
--- @return number
function GetRoleXpForCitizen(citizenid)
    local k9 = type(GetXP) == 'function' and tonumber(GetXP(citizenid)) or 0
    local handler = type(GetHandlerXP) == 'function' and tonumber(GetHandlerXP(citizenid)) or 0
    return math.max(k9 or 0, handler or 0)
end

--- Does the role exist, and has this person reached its XP?
--- @return boolean
function IsRoleXpUnlocked(citizenid, roleKey)
    local role = ROLES[roleKey]
    if not role then return false end
    return GetRoleXpForCitizen(citizenid) >= (role.xpRequired or 0)
end

--- Every unlock from the roles this person holds and has unlocked.
--- @return table<string, boolean>
function GetHeldRoleUnlocks(citizenid, jobName)
    local held = {}
    if type(HasSpecialization) ~= 'function' or type(citizenid) ~= 'string' then return held end
    for key, role in pairs(ROLES) do
        if HasSpecialization(citizenid, jobName, key) then
            for unlock in pairs(role.unlocks) do held[unlock] = true end
        end
    end
    return held
end

--- Nobody is restricted by an unlock no role grants (the shipped state for
--- bite_takedown); once some role grants it, only holders of it pass.
--- @return boolean
function RoleUnlockPermits(citizenid, jobName, unlock)
    local anyRoleGrants = false
    for _, role in pairs(ROLES) do
        if role.unlocks[unlock] then anyRoleGrants = true; break end
    end
    if not anyRoleGrants then return true end
    return GetHeldRoleUnlocks(citizenid, jobName)[unlock] == true
end

--- Which roles unlock each trail type, for the boot self-check: one entry
--- per track type some role unlocks, role names sorted.
--- @return table<string, string[]> trackType -> role labels
function ListTrailRoleRequirements()
    local out = {}
    for _, role in pairs(ROLES) do
        for unlock in pairs(role.unlocks) do
            local trackType = unlock:match('^track_(.+)$')
            if trackType then
                out[trackType] = out[trackType] or {}
                table.insert(out[trackType], role.label)
            end
        end
    end
    for _, labels in pairs(out) do table.sort(labels) end
    return out
end

--- The catalog for display: sorted by XP needed, then name.
--- @return table[] { key, label, xpRequired, unlocks = string[] }
function ListRolesForDisplay()
    local out = {}
    for key, role in pairs(ROLES) do
        out[#out + 1] = { key = key, label = role.label, xpRequired = role.xpRequired, unlocks = SortedUnlockList(role.unlocks) }
    end
    table.sort(out, function(a, b)
        if a.xpRequired ~= b.xpRequired then return a.xpRequired < b.xpRequired end
        return a.label < b.label
    end)
    return out
end

--- @return table[] { key, label }
function ListRoleUnlockOptions()
    local out = {}
    for _, entry in ipairs(UNLOCK_KEYS) do out[#out + 1] = { key = entry.key, label = entry.label } end
    return out
end

-- ======================================================================
-- TABLET: list / save / delete (high command only for the last two)
-- ======================================================================
local function CallerCitizenId(source)
    local player = exports.qbx_core:GetPlayer(source)
    return player and player.PlayerData and player.PlayerData.citizenid or nil
end

local function IsCallerHighCommand(source)
    return type(IsHighCommand) == 'function' and IsHighCommand(source) == true
end

local function SlugFromLabel(label)
    local slug = tostring(label):lower():gsub('[^a-z0-9]+', '_'):gsub('^_+', ''):gsub('_+$', '')
    if slug == '' then slug = 'role' end
    return slug:sub(1, ROLE_KEY_MAX - 3)
end

local function CountRoles()
    local n = 0
    for _ in pairs(ROLES) do n = n + 1 end
    return n
end

lib.callback.register('john-k9:server:tabletRolesList', function(source)
    return {
        ok = true,
        roles = ListRolesForDisplay(),
        unlockOptions = ListRoleUnlockOptions(),
        canManage = IsCallerHighCommand(source),
    }
end)

--- @param data table { key?: string, label: string, xpRequired: number, unlocks: string[] }
lib.callback.register('john-k9:server:tabletRolesSave', function(source, data)
    if not IsCallerHighCommand(source) then
        return { ok = false, error = 'not_authorized', message = locale('highcommand.not_authorized') }
    end
    if type(data) ~= 'table' then return { ok = false, error = 'invalid_args' } end

    local label = type(data.label) == 'string' and data.label:gsub('^%s+', ''):gsub('%s+$', '') or ''
    if label == '' or #label > LABEL_MAX then return { ok = false, error = 'invalid_label', field = 'label' } end

    local xp = tonumber(data.xpRequired)
    if not xp or xp ~= xp or xp < 0 or xp > MAX_XP_REQUIRED or math.floor(xp) ~= xp then
        return { ok = false, error = 'invalid_xp', field = 'xpRequired' }
    end

    local unlocks = {}
    if data.unlocks ~= nil then
        if type(data.unlocks) ~= 'table' then return { ok = false, error = 'invalid_unlocks', field = 'unlocks' } end
        for _, key in ipairs(data.unlocks) do
            if type(key) ~= 'string' or not IS_UNLOCK_KEY[key] then return { ok = false, error = 'invalid_unlocks', field = 'unlocks' } end
            unlocks[key] = true
        end
    end

    local key = data.key
    local isNew = key == nil or key == ''
    if isNew then
        if CountRoles() >= MAX_ROLES then return { ok = false, error = 'too_many_roles' } end
        local base = SlugFromLabel(label)
        key = base
        local n = 2
        while ROLES[key] or DELETED_KEYS[key] do key = base .. '_' .. n; n = n + 1 end
    elseif type(key) ~= 'string' or #key > ROLE_KEY_MAX or not key:match(ROLE_KEY_PATTERN) or not ROLES[key] then
        return { ok = false, error = 'unknown_role' }
    end

    -- k9_roles.unlocks is VARCHAR(255).
    local unlockText = table.concat(SortedUnlockList(unlocks), ',')
    if #unlockText > 255 then return { ok = false, error = 'invalid_unlocks', field = 'unlocks' } end

    if not RoleEditCooldown.Consume(source) then return { ok = false, error = 'rate_limited' } end

    local who = CallerCitizenId(source) or 'unknown'
    if not K9Store.Role_Upsert(key, label, xp, unlockText, who) then
        return { ok = false, error = 'db_error' }
    end
    RefreshRoleCatalog()
    local detail = ('label=%s xp=%d unlocks=%s'):format(label, xp, table.concat(SortedUnlockList(unlocks), ','))
    if type(K9Store.RoleAudit_Append) == 'function' then
        K9Store.RoleAudit_Append(isNew and 'role_create' or 'role_update', key, detail, who)
    end
    print(('[John-K9] role %s %s by %s: %s'):format(key, isNew and 'created' or 'updated', who, detail))
    return { ok = true, key = key, roles = ListRolesForDisplay() }
end)

lib.callback.register('john-k9:server:tabletRolesDelete', function(source, key)
    if not IsCallerHighCommand(source) then
        return { ok = false, error = 'not_authorized', message = locale('highcommand.not_authorized') }
    end
    if type(key) ~= 'string' or not ROLES[key] then return { ok = false, error = 'unknown_role' } end
    -- A shop item that needs this role could never be bought again.
    if type(CountEquipmentShopItemsRequiringRole) == 'function' then
        local count, items = CountEquipmentShopItemsRequiringRole(key)
        if count > 0 then return { ok = false, error = 'role_in_use_by_shop_items', count = count, items = items } end
    end
    if not RoleEditCooldown.Consume(source) then return { ok = false, error = 'rate_limited' } end

    local who = CallerCitizenId(source) or 'unknown'
    local deletedLabel = ROLES[key].label
    if not K9Store.Role_Tombstone(key, deletedLabel, who) then return { ok = false, error = 'db_error' } end
    RefreshRoleCatalog()
    if type(K9Store.RoleAudit_Append) == 'function' then
        K9Store.RoleAudit_Append('role_delete', key, ('label=%s'):format(tostring(deletedLabel)), who)
    end
    print(('[John-K9] role %s deleted by %s'):format(key, who))
    return { ok = true, roles = ListRolesForDisplay() }
end)
