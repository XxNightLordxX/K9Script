--[[
    john-k9/client/diagnostics.lua

    The client half of /k9debug. The command itself is registered SERVER-SIDE
    (server/diagnostics.lua, RegisterCommand('k9debug', ...)), matching this
    resource's own established convention for every other chat command
    (k9setdog, k9audit, k9givexp, ...) -- see that file's own header. This
    file's job is narrower and purely additive: report a small set of facts
    ONLY the calling player's own client can see, which the server has no
    way to observe about them at all.

    WHY THIS EXISTS, CONCRETELY: several of this project's own real,
    shipped bugs were exactly this shape -- something stuck ON, client-side,
    with nothing server-side ever able to see it (KNOWN_ISSUES.md's own
    "gate the start, never the stop" incidents: a vest that could not be
    removed, thermal vision stuck on, a K9 shut in a vehicle, a kennel that
    would not release). NUI focus stuck open after the tablet should have
    closed, or a ped stuck ragdolled/in a vehicle it should have exited, is
    invisible to server/diagnostics.lua no matter how comprehensive its own
    checks are -- the server genuinely does not know. This file's small,
    period self-report closes exactly that blind spot, for the reporting
    player's own state only.

    ======================================================================
    DESIGN: NO SYNCHRONOUS SERVER-ASKS-CLIENT ROUND TRIP. This resource's
    existing `lib.callback` usage is exclusively client-calls-server
    (`lib.callback.register` on the server, `lib.callback.await` on the
    client) -- there is no existing precedent anywhere in this resource for
    the reverse direction (server blocking on a client reply), and
    inventing one for a "nice to have" diagnostic field is a real, avoidable
    risk (a disconnected/lagging client would leave a server-side wait
    either hanging or needing its own new bounded-timeout machinery that
    does not exist here today). Instead: a plain, ordinary,
    already-well-established client -> server event
    (`john-k9:server:debugDumpClientHeartbeat`, a TriggerServerEvent, no
    different in kind from the many other one already in this resource),
    sent once shortly after this file loads and again every 5 seconds while
    Config.DebugDump.enabled stays true. server/diagnostics.lua caches only
    the MOST RECENT report per source (never accumulates), and reports its
    age plainly (`clientSelfReport.ageMs`) in any dump it writes -- honest
    about being a snapshot from up to ~5 seconds ago, never pretending to
    be a live, synchronous answer.

    Config.DebugDump is defined in config.lua, a shared_script -- this file
    reads `Config.DebugDump.enabled` directly, client-side, with NO server
    round trip needed to discover whether this subsystem is even on.

    ======================================================================
    SHIPS OFF, DOES NOTHING AT ALL, NO THREAD EVEN STARTS, UNLESS
    Config.DebugDump.enabled IS EXACTLY `true` -- same posture as
    server/diagnostics.lua. This file does NOT itself clamp-and-warn
    Config.DebugDump's other fields (server/diagnostics.lua already owns that
    responsibility and runs first, since config.lua/shared_scripts load
    before client_scripts) -- this file only ever reads `.enabled`, which
    needs no clamping to be read safely (a non-boolean here is simply
    `~= true`, which correctly means "off").

    ======================================================================
    EVERY FIELD SENT IS SMALL, NON-SECRET, AND PURELY DIAGNOSTIC: a model
    hash, ped health/max-health, three booleans, a vehicle model hash, and
    the client's own uptime counter -- nothing that identifies this player
    beyond what the server already knows from `source` alone, nothing that
    could be used for any authorization decision (the server never treats
    this payload as anything but display text in the requesting player's
    OWN dump file -- see server/diagnostics.lua's own validation of every
    field on receipt). Every native call below is wrapped in a single
    `pcall` around the whole snapshot-building function, so a native
    throwing on an unusual client state (e.g. mid-respawn) degrades to
    simply skipping that one heartbeat, never an error, never breaking
    whatever the player is actually doing.
]]

if type(Config) ~= 'table' or type(Config.DebugDump) ~= 'table' or Config.DebugDump.enabled ~= true then
    return
end

--- One heartbeat's worth of client-only facts. Wrapped in a single pcall by
--- its only caller below -- never assumed safe to call unconditionally
--- (PlayerPedId()/GetEntityModel() etc. are ordinary, always-available
--- client natives, but "must never break what it observes" applies to this
--- file exactly as much as it does to server/diagnostics.lua).
--- @return table
local function BuildSelfReport()
    local ped = PlayerPedId()
    local inVehicle = IsPedInAnyVehicle(ped, false) == true

    return {
        modelHash = GetEntityModel(ped),
        pedHealth = GetEntityHealth(ped),
        pedMaxHealth = GetEntityMaxHealth(ped),
        isDead = IsEntityDead(ped) == true,
        isRagdoll = IsPedRagdoll(ped) == true,
        inVehicle = inVehicle,
        vehicleModelHash = inVehicle and GetEntityModel(GetVehiclePedIsIn(ped, false)) or 0,
        -- IsNuiFocused: ext/native-decls/IsNuiFocused.md, HTTP 200, ns CFX,
        -- apiset client -- already independently verified and allowlisted
        -- in .luacheckrc (client/hud.lua's onboarding hint is the existing
        -- consumer). Reports whether NUI focus is held by ANY resource,
        -- which is exactly what a "is the tablet stuck open" diagnostic
        -- needs -- it does not need to know WHICH resource, only whether
        -- input is currently captured away from normal gameplay.
        nuiFocused = IsNuiFocused() == true,
        clientGameTimerMs = GetGameTimer(),
    }
end

CreateThread(function()
    while true do
        local ok, report = pcall(BuildSelfReport)
        if ok and type(report) == 'table' then
            TriggerServerEvent('john-k9:server:debugDumpClientHeartbeat', report)
        end
        Wait(5000)
    end
end)
