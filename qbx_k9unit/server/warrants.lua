--[[
    qbx_k9unit/server/warrants.lua

    Two things, both about "is this person wanted":

    1. THE SNIFF CHECKS FOR WARRANTS (Config.Combat.WantedFromDispatch).
       When a K9 sniffs a person (third eye > Sniff Person), server/search.lua
       calls CheckWarrantOnSniff after the contraband check. If sc-dispatch's
       MDT holds an active, APPROVED warrant for that person whose type makes
       a person wanted (arrest, bench -- not a search warrant), the K9 and
       its partner are told. It is information for the roleplay only: a K9
       can bite, take down, drag or chase anyone, warrant or not (owner:
       "the dog should be able to do that whether someone is marked or
       not").

       sc-dispatch exposes no export or event for warrants, so this reads its
       own mdt_warrants table -- the same way sc-dispatch's own BOLO plate
       reader reads its BOLOs -- and only when someone is
       actually sniffed; nothing polls. "Approved" matches sc-dispatch's own
       GetCitizenWarrants; COALESCE covers rows from before it added
       approval_status, and a database without that column falls back to
       active = 1. Any read failure means "no warrant found".

    2. IsPlayerK9Wanted -- the optional wanted gate. Config.Combat.
       RequireWantedStatus ships FALSE, so this answers true for everyone.
       An owner who turns it on limits K9 moves on players to those
       WantedStatusCheckOverride (or metadata.wanted / metadata.iswanted)
       says are wanted. server/combat.lua and server/pursuitsprint.lua both
       call this one implementation.
]]

--- @param targetSrc number
--- @return boolean
function IsPlayerK9Wanted(targetSrc)
    local combatCfg = Config.Combat
    if type(combatCfg) ~= 'table' or not combatCfg.RequireWantedStatus then return true end

    local override = combatCfg.WantedStatusCheckOverride
    if type(override) == 'function' then
        local ok, result = pcall(override, targetSrc)
        if not ok then
            print(('[qbx_k9unit] Config.Combat.WantedStatusCheckOverride errored for source %s: %s -- failing closed (target treated as NOT eligible)'):format(targetSrc, tostring(result)))
            return false
        end
        return result == true
    end

    local player = exports.qbx_core:GetPlayer(targetSrc)
    local metadata = player and player.PlayerData and player.PlayerData.metadata
    if type(metadata) ~= 'table' then return false end
    return metadata.wanted == true or metadata.iswanted == true
end

local function DispatchCfg()
    local cfg = Config.Combat and Config.Combat.WantedFromDispatch
    if type(cfg) ~= 'table' or type(cfg.resource) ~= 'string' or cfg.resource == '' then return nil end
    return cfg
end

--- Does this warrant type make a PERSON wanted (arrest/bench, not search)?
local function IsPersonWarrantType(warrantType, cfg)
    local words = type(cfg.warrantTypes) == 'table' and cfg.warrantTypes or { 'arrest', 'bench' }
    local text = string.lower(tostring(warrantType or 'arrest'))
    for _, word in ipairs(words) do
        if type(word) == 'string' and word ~= '' and text:find(string.lower(word), 1, true) then return true end
    end
    return false
end

--- @return table[]? rows -- nil when the MDT could not be read
local function ReadWarrantRows(citizenid)
    local ok, rows = pcall(function()
        return MySQL.query.await("SELECT type FROM mdt_warrants WHERE citizenid = ? AND active = 1 AND COALESCE(approval_status, 'approved') = 'approved'", { citizenid })
    end)
    if ok and type(rows) == 'table' then return rows end
    ok, rows = pcall(function()
        return MySQL.query.await('SELECT type FROM mdt_warrants WHERE citizenid = ? AND active = 1', { citizenid })
    end)
    if ok and type(rows) == 'table' then return rows end
    print(('[qbx_k9unit] Could not read warrants from the MDT (mdt_warrants): %s'):format(tostring(rows)))
    return nil
end

--- The other half of `src`'s partnership, when they are online (either side).
local function PartnerSrcOf(src)
    if type(GetActivePartnerCitizenId) ~= 'function' then return nil end
    local player = exports.qbx_core:GetPlayer(src)
    local cid = player and player.PlayerData and player.PlayerData.citizenid
    if not cid then return nil end
    local partnerCid = GetActivePartnerCitizenId(cid)
    if not partnerCid then return nil end
    local partner = exports.qbx_core:GetPlayerByCitizenId(partnerCid)
    return partner and partner.PlayerData and partner.PlayerData.source or nil
end

--- Called by server/search.lua when `sniffSrc` has just sniffed the player
--- `targetSrc`. Yields (one MySQL read) -- only call it after the search has
--- committed everything it needs to.
--- @return string? warrantType -- the warrant found, or nil
function CheckWarrantOnSniff(sniffSrc, targetSrc)
    local cfg = DispatchCfg()
    if not cfg or GetResourceState(cfg.resource) ~= 'started' or type(MySQL) ~= 'table' then return nil end
    local target = exports.qbx_core:GetPlayer(targetSrc)
    local cid = target and target.PlayerData and target.PlayerData.citizenid
    if type(cid) ~= 'string' or cid == '' then return nil end

    local rows = ReadWarrantRows(cid)
    if not rows then return nil end
    local found
    for _, row in ipairs(rows) do
        if IsPersonWarrantType(row.type, cfg) then found = tostring(row.type or 'Arrest'); break end
    end
    if found and not found:lower():find('warrant', 1, true) then
        found = found .. ' Warrant' -- older sc-dispatch rows say just "Arrest"
    end
    if not found then return nil end

    NotifyPlayer(sniffSrc, locale('warrants.found', targetSrc, found), 'success')
    local partnerSrc = PartnerSrcOf(sniffSrc)
    if partnerSrc then NotifyPlayer(partnerSrc, locale('warrants.found_partner', targetSrc, found), 'inform') end
    return found
end
