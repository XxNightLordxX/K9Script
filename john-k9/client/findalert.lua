--[[
    john-k9/client/findalert.lua

    PROJECT_HISTORY.md §1 ("Make finds feel like a real alert, not a pop-up
    message"). Client half of server/findalert.lua -- see that file's own
    header for the full hook/ownership writeup (this feature is a pure
    REACTION layer bolted onto server/search.lua's already-fired
    'john-k9:events:searchCompleted' outbound event and, as bonus
    coverage, client/tracking.lua's already-fired
    'john-k9:server:reportTrackSourceArrival' event -- ZERO new detection
    logic anywhere in either of this feature's two files).

    This feature reacts to existing hooks in server/search.lua,
    client/search.lua, client/tracking.lua, and client/movement.lua without
    modifying any of them -- see server/findalert.lua's own header for the
    exact hook points read (not modified) to make that true.

    ======================================================================
    EVENT/CALLBACK CONTRACT:

    Client events (RegisterNetEvent, server->client):
    1. 'john-k9:client:playFindAlertReaction' (alertTier: string)
       [THIS FILE] -- fired by server/findalert.lua, ALWAYS unicast to the
       one client whose own search/track just resolved (never a -1
       broadcast, unlike client/main.lua's playBark -- this reaction is
       about the searching K9's OWN body, not something nearby players are
       meant to witness; client/search.lua's EXISTING, separate
       Config.Features.ContrabandAlerts bystander broadcast already covers
       the "nearby players hear something" case and this file does not
       duplicate it). `alertTier` is one of Config.FindAlerts.
       reactionsByAlertTier's own keys -- an opaque lookup key this file
       resolves against ITS OWN copy of that shared config table (config.lua
       is a shared_script, so both realms already see the identical table;
       server/findalert.lua never needs to compute or echo a client-facing
       reaction shape of its own -- this mirrors client/search.lua's
       existing playContrabandAlert receiver's own "server sends a short
       opaque key, client resolves via shared config" shape). No netId at
       all, unlike playBark/playContrabandAlert -- this reaction always
       targets THIS client's OWN PlayerPedId(), never another entity, so
       there is nothing to resolve.
    ======================================================================

    WHY THIS FILE DOES NOT CALL client/movement.lua's K9Sit() (a DELIBERATE
    dedup trade-off, flagged rather than silently made): K9Sit() opens with
    `if not CanShowK9UI() then DenyK9UIAccess() return end`, and
    CanShowK9UI() awaits a real 'john-k9:server:hasK9Access' server
    callback. Two problems that combination creates specifically for an
    AUTOMATIC, server-triggered reaction (as opposed to K9Sit()'s real,
    intended caller -- a player who just clicked "Sit" themselves):
      1. LATENCY: this reaction is supposed to feel instant ("the dog
         itself should react... automatically at the right moment",
         PROJECT_HISTORY.md §1) -- adding a second network round trip for a
         permission check that was ALREADY satisfied server-side
         milliseconds earlier (the search/track this reaction is about
         could not have produced a real alertTier at all without
         HasK9Access already having passed server-side) works directly
         against that goal.
      2. WRONG-CONTEXT UX: in the narrow window where access has ACTUALLY
         changed between the search completing and this event arriving
         (e.g. a concurrent decertification), K9Sit()'s own
         DenyK9UIAccess() would show "you cannot use K9 features right now"
         immediately after the player's own search-success notification --
         reads as a bug, not a real security boundary (this reaction has no
         capability of its own to deny; it is strictly cosmetic).
    This file therefore duplicates ONLY the small, already
    native-api-assistant-verified per-breed sit-scenario lookup table
    client/movement.lua's K9Sit() itself uses (WORLD_DOG_SITTING_* -- see
    that file's own doc comment, immediately above its K9Sit() function,
    for the full verification writeup this table is copied from verbatim,
    not re-guessed) and calls ClearPedTasksImmediately/
    TaskStartScenarioInPlace directly. If this table is ever promoted to a
    shared resource-global (removing this duplication), it needs a
    .luacheckrc `globals` entry and a small client/movement.lua edit.

    OWN-DEATH / OWN-VEHICLE GUARDS: neither is present on K9Sit() itself (a
    player-clicked action -- being dead or in a vehicle already makes the
    radial item unreachable/irrelevant in practice). This file adds both
    explicitly since it has no such natural precondition -- a server-fired
    reaction could in principle arrive at any moment relative to what the
    player's ped is currently doing, however unlikely given how search/track
    actually work today (both require the K9 on foot, stationary, next to
    the target/source, at the exact moment the reaction fires).
]]

--- Precomputed model-hash -> sit-scenario lookup, built once at file load.
--- COPIED VERBATIM (not re-derived, not re-guessed) from
--- client/movement.lua's K9_SIT_SCENARIO_BY_MODEL_HASH -- see that file's
--- own doc comment, immediately above its K9Sit() function, for the full
--- native-api-assistant verification writeup (two independently maintained
--- community scenario dumps, DioneB/GTAV-Scenarios and kibook/spooner's
--- scenarios.lua, agreeing exactly that "WORLD_DOG_SIT" is not a real
--- scenario and that the genuine per-breed names are
--- WORLD_DOG_SITTING_SHEPHERD / _ROTTWEILER / _RETRIEVER / _SMALL). See
--- THIS file's own header "WHY THIS FILE DOES NOT CALL K9Sit()" section for
--- why this is a disclosed duplicate rather than a shared-global reuse.
local K9_FIND_ALERT_SIT_SCENARIO_BY_MODEL_HASH = {}
for model, scenario in pairs({
    a_c_shepherd   = 'WORLD_DOG_SITTING_SHEPHERD',
    a_c_rottweiler = 'WORLD_DOG_SITTING_ROTTWEILER',
    a_c_chop       = 'WORLD_DOG_SITTING_ROTTWEILER', -- Chop is Rottweiler-framed; no Chop-specific scenario exists
    a_c_husky      = 'WORLD_DOG_SITTING_RETRIEVER',  -- no husky-specific scenario; RETRIEVER is the closest general/medium-dog sit
}) do
    K9_FIND_ALERT_SIT_SCENARIO_BY_MODEL_HASH[GetHashKey(model)] = scenario
end
local K9_FIND_ALERT_SIT_DEFAULT_SCENARIO = 'WORLD_DOG_SITTING_SHEPHERD' -- fallback if playing an unmapped/future Config.Peds model, same default K9Sit() uses

--- Plays the "trained final response" sit pose on the LOCAL player's own
--- ped, mirroring K9Sit()'s own ClearPedTasksImmediately +
--- TaskStartScenarioInPlace sequence exactly -- see this file's header for
--- why this is a deliberate small duplicate rather than a call to K9Sit()
--- itself.
--- @param ped number
local function PlayFindAlertSitPose(ped)
    local scenarioName = K9_FIND_ALERT_SIT_SCENARIO_BY_MODEL_HASH[GetEntityModel(ped)] or K9_FIND_ALERT_SIT_DEFAULT_SCENARIO
    ClearPedTasksImmediately(ped)
    TaskStartScenarioInPlace(ped, scenarioName, 0, true)
end

--- Server->client receiver -- see this file's header EVENT/CALLBACK
--- CONTRACT item 1 for the full contract. Always reacts against THIS
--- client's OWN ped only.
--- @param alertTier string
RegisterNetEvent('john-k9:client:playFindAlertReaction', function(alertTier)
    -- SOURCE-ORIGIN GUARD, resource-wide convention (see client/main.lua's
    -- playBark handler / client/search.lua's playContrabandAlert handler
    -- for the fullest citation of this pattern -- not re-derived here).
    -- Cosmetic-only payoff even if forged (this client's own sit pose/bark
    -- sound), applied for resource-wide consistency, not because this event
    -- carries real exploit severity on its own.
    if source ~= 65535 then return end

    -- Re-checked here too, mirroring this resource's "disabled feature must
    -- be a real no-op at every layer, not just hidden/ungated upstream"
    -- convention -- server/findalert.lua already gates this at the point it
    -- fires; this is defense-in-depth against a config reload racing an
    -- in-flight event, not the primary gate.
    if not Config.Features.FindAlerts then return end
    if type(alertTier) ~= 'string' then return end -- defensive: never trust an event payload's shape blindly, even a same-resource one

    local reaction = Config.FindAlerts and Config.FindAlerts.reactionsByAlertTier and Config.FindAlerts.reactionsByAlertTier[alertTier]
    if not reaction then return end -- unrecognized/unmapped tier (e.g. 'clean', or a future tier an operator added without a matching row) -- fail closed, never guess a default reaction

    local ped = PlayerPedId()

    -- OWN-DEATH / OWN-VEHICLE GUARDS -- see this file's header for why
    -- these exist here even though K9Sit() itself has neither.
    if IsEntityDead(ped) then return end
    if IsPedInAnyVehicle(ped, false) then return end

    if reaction.sit == true then
        PlayFindAlertSitPose(ped)
    end

    if type(reaction.sound) == 'string' and reaction.sound ~= '' then
        -- Reuses client/main.lua's existing PlaySoundOnNetworkEntity
        -- wholesale -- both the placeholder RAGE-audio PlaySoundFromEntity
        -- call AND the real client/audio.lua NUI bridge attempt it already
        -- makes, so this feature adds zero new sound-playback plumbing of
        -- its own. Always the LOCAL player's own ped/netId -- this
        -- reaction never targets another entity.
        PlaySoundOnNetworkEntity(NetworkGetNetworkIdFromEntity(ped), reaction.sound)
    end
end)
