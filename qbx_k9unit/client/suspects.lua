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
