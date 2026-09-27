--[[
    qbx_k9unit/client/suspects.lua

    "Mark as K9 Suspect" / "Clear K9 Suspect Mark" on the third eye, for an
    on-duty officer from a K9 department who is not playing a dog. Same
    thing as /k9suspect <id> (registered in server/suspects.lua, which
    decides everything -- this only shows the option and sends the request).
]]

local function CombatNeedsSuspects()
    local features = Config.Features or {}
    if not (Config.Combat and Config.Combat.RequireWantedStatus) then return false end
    return features.BiteAndHold == true or features.NonLethalTakedown == true or features.PropDragging == true
        or features.PursuitSprint == true
end

if not CombatNeedsSuspects() then return end

--- Display-only mirror of server/suspects.lua's CanMarkSuspects.
local function ICanMarkSuspects()
    local job = QBX and QBX.PlayerData and QBX.PlayerData.job
    if type(job) ~= 'table' or not Config.Departments[job.name] then return false end
    if job.onduty == false then return false end
    if type(IsK9Role) == 'function' and IsK9Role() then return false end
    return true
end

local function TargetServerId(entity)
    local playerIndex = NetworkGetPlayerIndexFromPed(entity)
    if playerIndex == -1 or playerIndex == PlayerId() then return nil end
    return GetPlayerServerId(playerIndex)
end

local function IsMarked(serverId)
    local state = Player(serverId).state
    return state and state.k9Suspect == true
end

local function Toggle(data)
    local serverId = TargetServerId(data.entity)
    if serverId then TriggerServerEvent('qbx_k9unit:server:toggleSuspectMark', serverId) end
end

local NEAREST_SUSPECT_RANGE = 8.0

--- The closest other player within range who is not a dog -- your own K9 is
--- usually the player standing nearest you, and marking it would be useless.
--- @return number? serverId
local function FindNearestSuspect()
    local myCoords = GetEntityCoords(PlayerPedId())
    local nearestId, nearestDist
    for _, playerIndex in ipairs(GetActivePlayers()) do
        if playerIndex ~= PlayerId() then
            local ped = GetPlayerPed(playerIndex)
            if ped ~= 0 and DoesEntityExist(ped) and not IsEntityModelK9(ped) then
                local dist = #(myCoords - GetEntityCoords(ped))
                if dist <= NEAREST_SUSPECT_RANGE and (not nearestDist or dist < nearestDist) then
                    nearestId, nearestDist = playerIndex, dist
                end
            end
        end
    end
    return nearestId and GetPlayerServerId(nearestId) or nil
end

--- Marks (or clears) the nearest player -- the K9 menu button and a bare
--- /k9suspect both land here, so nobody has to look up an ID.
function MarkNearestSuspect()
    local serverId = FindNearestSuspect()
    if not serverId then
        lib.notify({ title = locale('common.notify_title'), description = locale('suspects.nobody_near'), type = 'error' })
        return
    end
    TriggerServerEvent('qbx_k9unit:server:toggleSuspectMark', serverId)
end

--- Display-only: does this player get the Mark Suspect button?
function CanMarkSuspectsHere()
    return ICanMarkSuspects()
end

K9Compat.Get('target').AddGlobalPlayer({
    {
        name = 'qbx_k9unit:markSuspect',
        icon = 'fas fa-user-tie',
        label = locale('suspects.target_mark'),
        distance = 5.0,
        canInteract = function(entity)
            local serverId = TargetServerId(entity)
            return serverId ~= nil and ICanMarkSuspects() and not IsMarked(serverId)
        end,
        onSelect = Toggle,
    },
    {
        name = 'qbx_k9unit:clearSuspect',
        icon = 'fas fa-user-tie',
        label = locale('suspects.target_clear'),
        distance = 5.0,
        canInteract = function(entity)
            local serverId = TargetServerId(entity)
            return serverId ~= nil and ICanMarkSuspects() and IsMarked(serverId)
        end,
        onSelect = Toggle,
    },
})

RegisterNetEvent('qbx_k9unit:client:markNearestSuspect', function()
    if source ~= 65535 then return end -- only the server may ask
    MarkNearestSuspect()
end)

--- The handler's one-tap prompt: your K9 went for someone who is not marked.
RegisterNetEvent('qbx_k9unit:client:suspectMarkAsked', function(targetSrc)
    if source ~= 65535 then return end -- only the server may ask
    local answer = lib.alertDialog({
        header = locale('suspects.ask_header'),
        content = locale('suspects.ask_content', targetSrc),
        centered = true,
        cancel = true,
        labels = { confirm = locale('suspects.ask_yes'), cancel = locale('suspects.ask_no') },
    })
    TriggerServerEvent('qbx_k9unit:server:answerSuspectAsk', targetSrc, answer == 'confirm')
end)
