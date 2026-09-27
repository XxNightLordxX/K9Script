--[[
    qbx_k9unit/server/suspects.lua

    WHO A K9 MAY BITE, TAKE DOWN OR DRAG (player targets only).

    With Config.Combat.RequireWantedStatus on (the default) a K9 can only act
    on a player who is flagged wanted. A stock Qbox server has nothing that
    sets that flag, so out of the box no player could ever be bitten. This
    file gives the flag three sources, any one of which is enough:

      1. An officer marks the player. Any on-duty member of a department in
         Config.Departments (who is not playing a K9 -- the dog never picks
         its own targets) runs /k9suspect <id> or uses "Mark as K9 Suspect"
         on the player with the third eye. The mark lasts
         Config.Combat.SuspectMarkMinutes, can be cleared the same way, and
         ends if either player leaves.
      2. Another server script says so -- a dispatch or MDT calls
         TriggerEvent('qbx_k9unit:setK9Suspect', playerId, true, minutes).
         A plain server event: AddEventHandler, never RegisterNetEvent, so no
         game client can trigger it.
      3. Config.Combat.WantedStatusCheckOverride returns true, or -- when no
         override is set -- the player's metadata.wanted / metadata.iswanted.
         An override that errors fails closed for this source only; a mark
         from 1 or 2 still counts, because it is this server's own record.

    IsPlayerK9Wanted is the ONE implementation; server/combat.lua and
    server/pursuitsprint.lua both call it (they used to carry two copies).
]]

local markCooldown = NewCooldown(1500)
markCooldown.RegisterPlayerDropped()

--- [targetSrc] = { expiresAt = GetGameTimer() ms, markedBy = src or nil }
local suspects = {}

local function MarkMinutes(minutes)
    if type(minutes) == 'number' and minutes > 0 then return math.min(minutes, 240) end
    local configured = Config.Combat and Config.Combat.SuspectMarkMinutes
    if type(configured) == 'number' and configured > 0 then return configured end
    return 10
end

local function IsConnected(src)
    return type(src) == 'number' and src > 0 and exports.qbx_core:GetPlayer(src) ~= nil
end

--- @param targetSrc number
--- @return boolean
function IsK9SuspectMarked(targetSrc)
    local entry = suspects[targetSrc]
    if not entry then return false end
    if GetGameTimer() >= entry.expiresAt then
        suspects[targetSrc] = nil
        return false
    end
    return true
end

--- The single "may a K9 act on this player" check.
--- @param targetSrc number
--- @return boolean
function IsPlayerK9Wanted(targetSrc)
    local combatCfg = Config.Combat
    if type(combatCfg) ~= 'table' or not combatCfg.RequireWantedStatus then return true end
    if IsK9SuspectMarked(targetSrc) then return true end

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

--- Sets or clears a mark with no permission check -- callers decide who may.
--- @return boolean changed
--- Mirrors the mark onto a replicated player statebag so the third-eye
--- option can say "Mark" or "Clear". Display only -- every decision reads
--- the server table above.
local function PublishMark(targetSrc, isSuspect)
    local ok, err = pcall(function() Player(targetSrc).state:set('k9Suspect', isSuspect or nil, true) end)
    if not ok then print(('[qbx_k9unit] suspects.lua: could not update the k9Suspect statebag for %s: %s'):format(targetSrc, tostring(err))) end
end

local function SetMark(targetSrc, isSuspect, minutes, markedBy)
    if not IsConnected(targetSrc) then return false end
    if isSuspect then
        local durationMs = MarkMinutes(minutes) * 60000
        local entry = { expiresAt = GetGameTimer() + durationMs, markedBy = markedBy }
        suspects[targetSrc] = entry
        SetTimeout(durationMs, function()
            if suspects[targetSrc] == entry then
                suspects[targetSrc] = nil
                PublishMark(targetSrc, false)
            end
        end)
    else
        suspects[targetSrc] = nil
    end
    PublishMark(targetSrc, isSuspect)
    return true
end

--- On duty in a K9 department and not playing a dog.
local function CanMarkSuspects(src)
    local player = exports.qbx_core:GetPlayer(src)
    local job = player and player.PlayerData and player.PlayerData.job
    if type(job) ~= 'table' or type(Config.Departments) ~= 'table' or not Config.Departments[job.name] then return false end
    if job.onduty == false then return false end
    if type(HasK9Role) == 'function' and HasK9Role(src) then return false end
    return true
end

--- Tells the marking officer's K9 partner, when they have one online.
local function TellPartnerK9(officerSrc, key, targetSrc)
    if type(GetActivePartnerCitizenId) ~= 'function' then return end
    local officer = exports.qbx_core:GetPlayer(officerSrc)
    local cid = officer and officer.PlayerData and officer.PlayerData.citizenid
    if not cid then return end
    local partnerCid, callerIsK9 = GetActivePartnerCitizenId(cid)
    if not partnerCid or callerIsK9 then return end
    local partner = exports.qbx_core:GetPlayerByCitizenId(partnerCid)
    local partnerSrc = partner and partner.PlayerData and partner.PlayerData.source
    if partnerSrc then NotifyPlayer(partnerSrc, locale(key, targetSrc), 'inform') end
end

--- An officer toggles the mark on `targetSrc`.
--- @param officerSrc number
--- @param targetSrc number
function ToggleK9SuspectMark(officerSrc, targetSrc)
    if not CanMarkSuspects(officerSrc) then
        NotifyPlayer(officerSrc, locale('suspects.not_allowed'), 'error')
        return
    end
    if not (Config.Combat and Config.Combat.RequireWantedStatus) then
        NotifyPlayer(officerSrc, locale('suspects.not_needed'), 'inform')
        return
    end
    targetSrc = tonumber(targetSrc)
    if not targetSrc or targetSrc == officerSrc or not IsConnected(targetSrc) then
        NotifyPlayer(officerSrc, locale('suspects.no_player'), 'error')
        return
    end
    if not markCooldown.Consume(officerSrc) then return end

    if IsK9SuspectMarked(targetSrc) then
        SetMark(targetSrc, false)
        NotifyPlayer(officerSrc, locale('suspects.cleared', targetSrc), 'success')
        TellPartnerK9(officerSrc, 'suspects.partner_cleared', targetSrc)
        print(('[qbx_k9unit] K9 suspect mark cleared on %s by %s'):format(targetSrc, officerSrc))
    else
        SetMark(targetSrc, true, nil, officerSrc)
        NotifyPlayer(officerSrc, locale('suspects.marked', targetSrc, MarkMinutes()), 'success')
        TellPartnerK9(officerSrc, 'suspects.partner_marked', targetSrc)
        print(('[qbx_k9unit] K9 suspect mark set on %s by %s for %d min'):format(targetSrc, officerSrc, MarkMinutes()))
    end
end

-- ======================================================================
-- ONE-TAP ASK. A K9 that goes for someone not yet marked is refused -- and
-- if its partner handler is on duty nearby in the game, the handler gets a
-- "Mark them?" prompt instead of having to find the ID and type a command
-- mid-chase. One ask per K9 every 15 seconds; an ask lapses after 30.
-- ======================================================================
local askCooldown = NewCooldown(15000)
askCooldown.RegisterPlayerDropped()
local ASK_TTL_MS = 30000
--- [handlerSrc] = { target = src, k9 = src, expiresAt = ms }
local pendingAsks = {}

--- @return number? handlerSrc -- the K9's online partner, when k9Src is the dog side
local function PartnerHandlerOf(k9Src)
    if type(GetActivePartnerCitizenId) ~= 'function' then return nil end
    local k9 = exports.qbx_core:GetPlayer(k9Src)
    local cid = k9 and k9.PlayerData and k9.PlayerData.citizenid
    if not cid then return nil end
    local partnerCid, callerIsK9 = GetActivePartnerCitizenId(cid)
    if not partnerCid or not callerIsK9 then return nil end
    local handler = exports.qbx_core:GetPlayerByCitizenId(partnerCid)
    return handler and handler.PlayerData and handler.PlayerData.source or nil
end

--- Called by server/combat.lua and server/pursuitsprint.lua right after they
--- refuse a K9 because its target is not a suspect.
--- @return boolean asked
function AskHandlerToMarkSuspect(k9Src, targetSrc)
    if not (Config.Combat and Config.Combat.RequireWantedStatus) then return false end
    if not IsConnected(targetSrc) or IsK9SuspectMarked(targetSrc) then return false end
    local handlerSrc = PartnerHandlerOf(k9Src)
    if not handlerSrc or handlerSrc == targetSrc or not CanMarkSuspects(handlerSrc) then return false end
    if not askCooldown.Consume(k9Src) then return false end

    pendingAsks[handlerSrc] = { target = targetSrc, k9 = k9Src, expiresAt = GetGameTimer() + ASK_TTL_MS }
    TriggerClientEvent('qbx_k9unit:client:suspectMarkAsked', handlerSrc, targetSrc)
    NotifyPlayer(k9Src, locale('suspects.asked_handler', targetSrc), 'inform')
    return true
end

RegisterNetEvent('qbx_k9unit:server:answerSuspectAsk', function(targetSrc, yes)
    local handlerSrc = source
    local ask = pendingAsks[handlerSrc]
    pendingAsks[handlerSrc] = nil
    if not ask or ask.target ~= tonumber(targetSrc) or GetGameTimer() > ask.expiresAt then return end
    if yes ~= true then
        NotifyPlayer(ask.k9, locale('suspects.handler_declined', ask.target), 'inform')
        return
    end
    if not CanMarkSuspects(handlerSrc) or not SetMark(ask.target, true, nil, handlerSrc) then return end
    NotifyPlayer(handlerSrc, locale('suspects.marked', ask.target, MarkMinutes()), 'success')
    NotifyPlayer(ask.k9, locale('suspects.partner_marked', ask.target), 'success')
    print(('[qbx_k9unit] K9 suspect mark set on %s by %s (asked by K9 %s)'):format(ask.target, handlerSrc, ask.k9))
end)

RegisterNetEvent('qbx_k9unit:server:toggleSuspectMark', function(targetSrc)
    ToggleK9SuspectMark(source, targetSrc)
end)

RegisterCommand('k9suspect', function(source, args)
    if source <= 0 then return end
    local targetSrc = tonumber(args and args[1])
    if not targetSrc then
        -- No ID typed: mark whoever is standing nearest (the client picks,
        -- skipping dogs; the server re-checks everything as usual).
        TriggerClientEvent('qbx_k9unit:client:markNearestSuspect', source)
        return
    end
    ToggleK9SuspectMark(source, targetSrc)
end, false)

--- For a dispatch/MDT resource: server-side only.
--- TriggerEvent('qbx_k9unit:setK9Suspect', playerId, true|false, minutes?)
AddEventHandler('qbx_k9unit:setK9Suspect', function(targetSrc, isSuspect, minutes)
    SetMark(tonumber(targetSrc), isSuspect == true, minutes)
end)

AddEventHandler('playerDropped', function()
    local dropped = source
    suspects[dropped] = nil
    pendingAsks[dropped] = nil
    for target, entry in pairs(suspects) do
        if entry.markedBy == dropped then
            suspects[target] = nil
            PublishMark(target, false)
        end
    end
end)
