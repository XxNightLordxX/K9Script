--[[
    tests/mainserver_spec.lua

    First test coverage for server/main.lua -- previously ZERO. This file
    owns the leash consent handshake (Config.Features.LeashMechanics, one
    of only FIVE features that ship ENABLED by default alongside RadialMenu/
    VehicleEntryExit/BasicBarkSounds/AgilityBasicJump -- see config.lua),
    plus relayBark and relayDoorScratch. Named mainserver_spec.lua, not
    main_spec.lua -- that name is already taken by the CLIENT-side spec
    (client/main.lua's IsEntityModelK9/HasK9Access/CanShowK9UI cluster), a
    completely different file in a completely different Lua VM.

    Loads the REAL, unmodified server/cooldowns.lua -> server/entities.lua
    -> server/main.lua chain, in the exact order fxmanifest.lua's
    server_scripts list requires (main.lua's own header FILE-TO-FILE
    CONTRACT: BarkCooldown/LeashRequestCooldown/DoorScratchCooldown/
    DoorScratchByDoorCooldown are real NewCooldown() trackers, and
    relayDoorScratch's ResolveNetworkEntity call is the real resolve+
    existence+type-guard primitive) -- never a reimplementation of either.
    HasK9Access, IsConfiguredK9Model, and NotifyPlayer are stubbed directly,
    same convention kennel_spec.lua/combat_spec.lua already established:
    all three are genuinely OTHER files' own logic (server/certifications/,
    server/notify.lua), already covered by their own specs -- this file's
    job is server/main.lua's own handshake/relay/cleanup logic, not a
    second copy of those.

    locale() is NEVER stubbed (per this suite's own convention -- see
    DEVELOPER_REFERENCE.md §20). LEASH_REJECT_MESSAGES is built ONCE, at server/main.lua's
    own file-load time, from 8 locale() calls -- every single test in this
    file that successfully loads the sandbox (i.e. every test) already
    proves all 8 of those keys resolve against the real locales/en.json, since
    a missing one would raise at Sandbox.loadInto time and fail EVERY test in
    this file, not just one. Section 4 below additionally drives each of
    those 8 reasons through its OWN real code path and asserts the exact
    notified string against Sandbox.locale(...) (never a hand-copied English
    string), closing the gap a load-time-only proof leaves open: that each
    key is not just present in en.json, but is the ACTUAL message the real
    reason->message table maps its own reason string to.

    ONE FRESH SANDBOX PER TEST (never shared) -- LeashPairs, PendingLeashRequests,
    and every cooldown tracker's own internal store are file-lifetime `local`
    upvalues, so reusing one sandbox across unrelated cases would leak state
    exactly the way kennel_spec.lua/combat_spec.lua's own headers warn about.
    newMainFixture() below builds one complete, independent world for every
    single t.test() call.

    ======================================================================
    HANDLER INVENTORY -- built by READING server/main.lua top to bottom
    (never by grepping), pinned by Section 1 below:

    RegisterNetEvent (client->server), exactly 5:
      'qbx_k9unit:server:relayBark'            (Section 2)
      'qbx_k9unit:server:relayDoorScratch'     (Section 3)
      'qbx_k9unit:server:requestLeashAttach'   (Sections 4-6)
      'qbx_k9unit:server:respondLeashAttach'   (Sections 4, 7-8)
      'qbx_k9unit:server:detachLeash'          (Section 9)

    AddEventHandler('onResourceStart', ...), exactly 2 in this file, BOTH
    now fired and pinned by Section 12 below (previously neither was --
    see that section's own header for the "TODO that pointed nowhere" fix
    this coverage accompanies):
      - the Config.DoorInteraction.nudgeRequiresUnlocked safety assert
      - the RefreshCertificationCache/k9certified-mirror backfill loop

    AddEventHandler('playerDropped', ...): 4 TOTAL when cooldowns.lua is
    loaded alongside (as it always is here, per FILE-TO-FILE CONTRACT) -- 1
    registered BY THIS FILE (the leash pending/pairing cleanup, Section 10)
    plus 3 more registered BY server/cooldowns.lua itself, one per
    :RegisterPlayerDropped() call this file makes (BarkCooldown,
    LeashRequestCooldown, DoorScratchCooldown -- DoorScratchByDoorCooldown
    deliberately has none, per its own :StartSweep comment, since it's keyed
    by doorNetId, not by a disconnecting source).

    AddEventHandler('onResourceStop', ...): ZERO. See "FINDING" in Section 11.

    Resource-globals (no `local`) exposed by this file: ForceDetachLeashForSource,
    ForceDetachOfficerLeashForSource (both role-aware detach hooks for
    server/certifications/; Section 9).

    CreateThread(...): ONE, added this pass (DEATH-DETECTION FIX,
    coder-frontend) -- the leash death-detection poll, gated behind
    Config.Features.LeashMechanics, pinned by Section 13. Before this pass
    this file created ZERO threads of its own (DoorScratchByDoorCooldown's
    own sweep thread is server/cooldowns.lua's CreateThread call, not this
    file's).
    ======================================================================

    WHAT THIS FILE DOES NOT COVER, AND WHY:
      - RefreshCertificationCache's OWN internal DB-query/tier/expiry logic
        (Section 12 below stubs it, same convention as HasK9Access/
        IsConfiguredK9Model elsewhere in this file) -- that is genuinely
        server/certifications/'s own logic, already covered by its own
        spec. Section 12 only pins server/main.lua's OWN responsibility:
        that the backfill loop calls it, with the right arguments, for the
        right set of already-connected players, and wires its return value
        into the k9certified metadata mirror.
      - barkType's content/enum semantics -- DEVELOPER_REFERENCE.md and this file's own
        header both say Phase 1 treats it as an opaque passthrough string;
        Section 2 only pins length/type/cooldown/access gating, never a
        specific barkType value's meaning.
      - LEASH_REJECT_MESSAGES's own fallback branch (`or locale('leash.reject_fallback')`
        inside the LOCAL LeashRejectReasonMessage function) is NOT exercised
        here: CheckLeashEligibility's `reason` return is always exactly one
        of the 8 keys the table itself defines, and LeashRejectReasonMessage
        is `local` (only reachable through requestLeashAttach/respondLeashAttach,
        which only ever pass a CheckLeashEligibility-produced reason) -- so
        the fallback string is provably DEAD CODE via every real caller in
        this file today. Disclosed here per this suite's own convention
        ("say so, don't silently skip, and never poke a local's internals to
        force a path no real caller can produce") rather than faked via
        direct access to a local this file deliberately doesn't expose.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')
local locale = Sandbox.locale

-- ----------------------------------------------------------------------
-- Vector3-alike stub -- identical shape/reasoning to combat_spec.lua's/
-- defense_spec.lua's own copies (GetEntityCoords' `-`/`#` operators are the
-- only vector math CheckLeashEligibility/relayDoorScratch's distance checks
-- need).
-- ----------------------------------------------------------------------
local Vec3MT = {}
Vec3MT.__index = Vec3MT
Vec3MT.__sub = function(a, b)
    return setmetatable({ x = a.x - b.x, y = a.y - b.y, z = a.z - b.z }, Vec3MT)
end
Vec3MT.__len = function(v)
    return math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z)
end
local function vec3(x, y, z)
    return setmetatable({ x = x, y = y, z = z }, Vec3MT)
end
local ORIGIN = vec3(0, 0, 0)

-- Fixed, test-controlled "model hash" constants. GetEntityModel and
-- IsConfiguredK9Model are BOTH stubbed by this spec (IsConfiguredK9Model is
-- genuinely server/certifications/'s own logic, already covered by
-- certifications_spec.lua), so these can be any two distinct numbers this
-- file agrees with itself on -- never the real GetHashKey algorithm, which
-- CheckLeashEligibility never calls directly anyway (it only ever calls
-- GetEntityModel then hands the result to IsConfiguredK9Model).
local K9_MODEL_HASH = 111111
local OFFICER_MODEL_HASH = 222222

-- Real, shipped config.lua baseline for the one number this whole subsystem
-- hinges on (Config.LeashMaxDistance = 8.0) -- same "use the actual shipped
-- number, not a round test value" discipline combat_spec.lua's/defense_spec.lua's
-- own baseline-config helpers already establish.
local LEASH_MAX_DISTANCE = 8.0

-- ----------------------------------------------------------------------
-- Sandbox setup
-- ----------------------------------------------------------------------

--- Builds one complete, independent sandbox for server/main.lua, with the
--- real server/cooldowns.lua and server/entities.lua loaded alongside it.
--- @param opts table? -- opts.features: shallow-merged onto the default Config.Features
--- @return table fixture
local function newMainFixture(opts)
    opts = opts or {}

    local fakeNow = 0
    local function GetGameTimer() return fakeNow end

    local eventHandlers = {} -- eventName -> { handler, handler, ... } (AddEventHandler)
    local function AddEventHandler(eventName, handler)
        eventHandlers[eventName] = eventHandlers[eventName] or {}
        eventHandlers[eventName][#eventHandlers[eventName] + 1] = handler
    end

    local netEvents = {} -- eventName -> handler (RegisterNetEvent) -- main.lua registers exactly one handler per event name
    local function RegisterNetEvent(eventName, handler)
        netEvents[eventName] = handler
    end

    local function GetCurrentResourceName() return 'qbx_k9unit' end

    local clientEvents = {} -- { {event=, target=, args={...}}, ... }
    local function TriggerClientEvent(eventName, target, ...)
        clientEvents[#clientEvents + 1] = { event = eventName, target = target, args = { ... } }
    end

    local notifyCalls = {} -- { {target=, description=, notifyType=}, ... }
    local function NotifyPlayer(target, description, notifyType)
        notifyCalls[#notifyCalls + 1] = { target = target, description = description, notifyType = notifyType }
    end

    -- PERFORMANCE AUDIT FIX (this pass) -- see installForEachNearbyPlayer's
    -- own comment near this fixture's return table for the full writeup.
    local forEachNearbyPlayerCalls = {} -- { {coords=, radius=}, ... }

    local hasAccessBySource = {}
    local function HasK9Access(src) return hasAccessBySource[src] == true end

    local function IsConfiguredK9Model(hash) return hash == K9_MODEL_HASH end

    -- K9 role/model decoupling (server/appearance.lua) -- CheckLeashEligibility
    -- ORs this in alongside IsConfiguredK9Model(GetEntityModel(...)) to let a
    -- role-holder on a human/custom model still count as "the K9 party".
    -- Stubbed here (not the real server/appearance.lua) for the same reason
    -- HasK9Access/IsConfiguredK9Model are: this file's job is main.lua's OWN
    -- eligibility/handshake logic, not a second copy of appearance.lua's,
    -- which has its own spec (appearance_spec.lua). Defaults to false for
    -- every source, matching "no role granted" being the default real-world
    -- state.
    local hasRoleBySource = {}
    local function HasK9Role(src) return hasRoleBySource[src] == true end

    local jobBySource = {} -- source -> job name, or nil = unresolved/no Player record at all
    local citizenidBySource = {} -- source -> citizenid string, or nil = no Player record at all (Section 12's backfill loop)
    local metaDataCalls = {} -- source -> { {key=, value=}, ... }, most recent last (Section 12: Player.Functions.SetMetaData)
    local pedBySource = {} -- source -> ped handle (unset/0 == "offline") -- declared here (moved above exportsStub) so GetPlayer below can see it as an upvalue

    -- PER-PERSON FEATURE CONTROL (this pass): CheckLeashEligibility and
    -- relayBark both now resolve a citizenid via exports.qbx_core:GetPlayer
    -- before running IsLeashMechanicsPermittedForCitizenId/
    -- IsBasicBarkSoundsPermittedForCitizenId. Every test in this file
    -- registers a source as "a real connected player" via setPed (leash/bark
    -- tests, which never cared about job/citizenid before this pass) or
    -- setJob/setOnlinePlayer (department/backfill tests) -- rather than
    -- rewrite every one of those call sites to also thread a citizenid
    -- through, GetPlayer synthesizes a stable, deterministic citizenid
    -- ('CIT-<src>') for any source this fixture already knows is connected
    -- (has a registered ped OR an explicitly set job/citizenid), matching
    -- real qbx_core's own invariant that a resolvable Player always carries
    -- BOTH a job (if any) and a citizenid together -- "job present, citizenid
    -- absent" is a gap this STUB introduced, not a real-world state. Explicit
    -- citizenidBySource[src] (Section 12's setOnlinePlayer) always wins over
    -- the synthesized fallback.
    local function citizenidFor(src)
        return citizenidBySource[src] or (pedBySource[src] and ('CIT-' .. tostring(src)) or nil)
    end

    local exportsStub = {
        qbx_core = {
            GetPlayer = function(_self, src)
                local job = jobBySource[src]
                local citizenid = citizenidFor(src)
                -- No record at all (never connected/registered by this fixture)
                -- vs. a record with no job assigned yet -- Section 12 needs to
                -- exercise BOTH "GetPlayer returns nil" and "Player exists but
                -- PlayerData.job is falsy", so a bare job==nil check can't be
                -- the only gate here the way it was pre-Section-12 (every
                -- caller before Section 12 only ever cared about the job case).
                if not job and not citizenid then return nil end
                return {
                    PlayerData = { job = job and { name = job } or nil, citizenid = citizenid },
                    Functions = {
                        SetMetaData = function(key, value)
                            metaDataCalls[src] = metaDataCalls[src] or {}
                            local calls = metaDataCalls[src]
                            calls[#calls + 1] = { key = key, value = value }
                        end,
                    },
                }
            end,
        },
    }
    local function GetPlayerPed(src) return pedBySource[src] or 0 end

    -- DEATH-DETECTION FIX (this pass, coder-frontend) -- IsLeashPartyDead's
    -- own final floor (GetEntityHealth <= 100). Defaults to 200 (a healthy
    -- ped's real default max health) for any ped never explicitly set via
    -- setHealth below -- every OTHER test in this file (none of which call
    -- setHealth) therefore exercises the "not dead" path unchanged.
    local healthByPed = {}
    local function GetEntityHealth(ped) return healthByPed[ped] or 200 end

    -- DEATH-DETECTION FIX (this pass) -- K9Compat.Get('ambulance').IsDowned,
    -- the SAME hand-rolled stand-in shape tests/combat_spec.lua's/
    -- this suite's own `fakeK9Compat` already establishes (never
    -- the real shared/compat/core.lua -- see combat_spec.lua's own comment
    -- on why: loading that file would register its own onResourceStart
    -- handlers/command, breaking this file's own handler-count assertions).
    -- Defaults to always returning nil (adapter UNKNOWN/not detected) for
    -- every test that never sets opts.ambulanceIsDowned -- every test
    -- written BEFORE this pass keeps exercising IsLeashPartyDead's
    -- pre-existing metadata/health fallback completely unchanged, zero
    -- opt-in required.
    local ambulanceIsDownedCalls = {}
    local function ambulanceIsDownedFn(src)
        ambulanceIsDownedCalls[#ambulanceIsDownedCalls + 1] = src
        if type(opts.ambulanceIsDowned) == 'function' then
            return opts.ambulanceIsDowned(src)
        end
        return nil
    end
    local fakeK9Compat = {
        Get = function(system)
            if system == 'ambulance' then
                return { IsDowned = ambulanceIsDownedFn }
            end
            return {}
        end,
    }

    local coordsByHandle = {} -- handle (ped OR door entity) -> vec3
    local function GetEntityCoords(handle) return coordsByHandle[handle] or ORIGIN end

    local modelByPed = {} -- ped handle -> model hash
    local function GetEntityModel(handle) return modelByPed[handle] end

    local netIdOffset = 500000 -- deterministic, distinguishable transform -- never the real native's bit pattern
    local function NetworkGetNetworkIdFromEntity(handle) return handle + netIdOffset end

    local networkEntities = {} -- netId -> handle (door/object entities named by relayDoorScratch's caller)
    local function NetworkGetEntityFromNetworkId(netId) return networkEntities[netId] or 0 end

    local existingEntities = {} -- handle -> true
    local function DoesEntityExist(handle) return existingEntities[handle] == true end

    local entityTypes = {} -- handle -> 1|2|3 (GetEntityType's real domain; 3 = object)
    local function GetEntityType(handle) return entityTypes[handle] or 0 end

    local onlinePlayerIds = {} -- array of STRINGS (GetPlayers' real, documented return shape -- source ids as strings, tonumber'd by the backfill loop itself) -- Section 12
    local function GetPlayers() return onlinePlayerIds end

    -- Section 12 (resource-start cache backfill): server/certifications/
    -- is NOT loaded into this sandbox (this file's job is main.lua's own
    -- backfill LOOP, not RefreshCertificationCache's own DB/tier logic,
    -- which is that file's own spec's job) -- same soft-dependency stub
    -- convention as HasK9Access/IsConfiguredK9Model above. Keyed by
    -- "citizenid|jobName" (both arguments the real function takes) so a
    -- test can assert exactly which (citizenid, jobName) pair the loop
    -- called it with, not just that it was called at all.
    local refreshCalls = {} -- array of { citizenid=, jobName= }, call order preserved
    local refreshResultByKey = {} -- "citizenid|jobName" -> boolean, default false (matches HasK9Access's own "no access" default posture)
    -- SECOND RETURN VALUE, `stateKnown` (concurrent contract change, this
    -- pass -- the real server/certifications/'s RefreshCertificationCache
    -- now returns `isActive, stateKnown`, and this file's own onResourceStart
    -- backfill call site was updated to match -- see that handler's own
    -- "COULD-NOT-DETERMINE GUARD" comment): this stub models a plain
    -- boolean lookup table with no "the query itself failed" concept at
    -- all, so it is always confidently `true` here -- every existing test
    -- in this file already asserts on a definite true/false `isActive`
    -- value, never on "could not determine," so defaulting `stateKnown` to
    -- true keeps every one of them meaning exactly what it already says.
    local function RefreshCertificationCache(citizenid, jobName)
        refreshCalls[#refreshCalls + 1] = { citizenid = citizenid, jobName = jobName }
        return refreshResultByKey[citizenid .. '|' .. tostring(jobName)] == true, true
    end

    local threadRunner = Sandbox.newThreadRunner() -- DoorScratchByDoorCooldown.StartSweep() runs at main.lua's OWN file-load time, unconditionally (not gated on Config.Features.DoorInteraction) -- CreateThread/Wait must exist regardless of which feature this fixture is testing

    -- DEATH-DETECTION FIX (this pass) -- server/main.lua now ALSO calls
    -- CreateThread once for its own leash death-detection poll, gated behind
    -- Config.Features.LeashMechanics (which defaults to true, both in real
    -- config.lua and in this fixture). Counted here (a thin wrapper around
    -- threadRunner.CreateThread, not a replacement) so a test can assert
    -- exactly how many threads this file creates for a given Config shape,
    -- the same "prove the gate, not just the behavior" discipline
    -- combat_spec.lua's own maintenance-thread gating tests already
    -- establish.
    local threadCreateCount = 0
    local function CountedCreateThread(fn)
        threadCreateCount = threadCreateCount + 1
        threadRunner.CreateThread(fn)
    end

    -- PER-PERSON FEATURE CONTROL (this pass) -- mirrors
    -- tests/pursuitsprint_spec.lua's own `permissionGrants`/`defaultHasPermission`/
    -- `grantPermission` fixture shape exactly, for
    -- IsLeashMechanicsPermittedForCitizenId/IsBasicBarkSoundsPermittedForCitizenId.
    local permissionGrants = {} -- [citizenid][key] = true/false
    local permissionCalls = {}
    local function defaultHasPermission(citizenid, key)
        permissionCalls[#permissionCalls + 1] = { citizenid = citizenid, key = key }
        return permissionGrants[citizenid] and permissionGrants[citizenid][key] == true
    end

    local config = {
        Features = {
            LeashMechanics = true,
            BasicBarkSounds = true,
            DoorInteraction = true, -- ships `false` by default in real config.lua; enabled here, same "exercise the logic behind a disabled-by-default flag" precedent search_spec.lua/kennel_spec.lua already establish for their own features
        },
        LeashMaxDistance = LEASH_MAX_DISTANCE,
        Departments = { police = true, sheriff = true },
        DoorInteraction = {
            interactDistance = 1.5,   -- real shipped default
            scratchCooldownMs = 3000, -- real shipped default
            nudgeRequiresUnlocked = true,
        },
        FeatureControl = { RequireGrant = {} },
        -- DEATH-DETECTION FIX (this pass) -- IsLeashPartyDead reuses
        -- Config.Combat.PropDragging.IsPlayerDownedOverride, the SAME
        -- override server/combat.lua's own PropDragging and
        -- a sibling file already read (see
        -- server/main.lua's own doc comment on IsLeashPartyDead for the
        -- "one shared per-server integration point" rationale). nil by
        -- default (opts.downedOverride, unset for every pre-existing test).
        Combat = {
            PropDragging = {
                IsPlayerDownedOverride = opts.downedOverride,
            },
        },
    }
    if opts.features then
        for k, v in pairs(opts.features) do config.Features[k] = v end
    end

    local envOverrides = {
        GetGameTimer = GetGameTimer,
        AddEventHandler = AddEventHandler,
        RegisterNetEvent = RegisterNetEvent,
        GetCurrentResourceName = GetCurrentResourceName,
        TriggerClientEvent = TriggerClientEvent,
        NotifyPlayer = NotifyPlayer,
        HasK9Access = HasK9Access,
        IsConfiguredK9Model = IsConfiguredK9Model,
        HasK9Role = HasK9Role,
        exports = exportsStub,
        -- opts.withHasPermission = false (this pass) -- lets a
        -- "server/permissions.lua entirely absent" test omit HasPermission
        -- from the sandbox entirely, mirroring
        -- tests/pursuitsprint_spec.lua's own `withHasPermission` knob.
        -- Defaults to true (unchanged for every existing caller).
        HasPermission = (opts.withHasPermission ~= false) and defaultHasPermission or nil,
        GetPlayerPed = GetPlayerPed,
        GetEntityCoords = GetEntityCoords,
        GetEntityModel = GetEntityModel,
        NetworkGetNetworkIdFromEntity = NetworkGetNetworkIdFromEntity,
        NetworkGetEntityFromNetworkId = NetworkGetEntityFromNetworkId,
        DoesEntityExist = DoesEntityExist,
        GetEntityType = GetEntityType,
        GetPlayers = GetPlayers,
        RefreshCertificationCache = RefreshCertificationCache,
        -- opts.schemaCheckSettled (this pass) -- lets a dedicated
        -- boot-order-race test simulate the schema-collision probe never
        -- settling within its wait budget (server/datastore.lua's own
        -- K9Store.WaitForSchemaCheckToSettle). Defaults to true (settled,
        -- unaffected) for every existing test, which never cared about
        -- this mechanism at all before the onResourceStart backfill below
        -- started calling it.
        K9Store = { WaitForSchemaCheckToSettle = function() return opts.schemaCheckSettled ~= false end },
        CreateThread = CountedCreateThread,
        Wait = threadRunner.Wait,
        Config = config,
        -- DEATH-DETECTION FIX (this pass) -- IsLeashPartyDead's own two new
        -- dependencies.
        GetEntityHealth = GetEntityHealth,
        K9Compat = fakeK9Compat,
    }

    local env = Sandbox.newEnv(envOverrides)

    Sandbox.loadInto('../server/cooldowns.lua', env)
    Sandbox.loadInto('../server/entities.lua', env)
    Sandbox.loadInto('../server/main.lua', env)

    return {
        env = env,
        config = config,
        clientEvents = clientEvents,
        notifyCalls = notifyCalls,
        netEventNames = netEvents,
        eventHandlerCount = function(name) return #(eventHandlers[name] or {}) end,
        advance = function(deltaMs) fakeNow = fakeNow + deltaMs end,
        now = function() return fakeNow end,
        setAccess = function(src, allowed) hasAccessBySource[src] = allowed end,
        -- DEATH-DETECTION FIX (this pass): setHealth (keyed by PED HANDLE,
        -- same convention as combat_spec.lua's own identically-named
        -- setter), threadCreateCount (proves the Config.Features.LeashMechanics
        -- gate on the new thread), ambulanceIsDownedCalls (proves the
        -- adapter is actually consulted, not just configured), and
        -- runOneTick (steps every captured thread -- the door-scratch sweep
        -- AND the new leash death-detection poll alike -- exactly one full
        -- pass; mirrors combat_spec.lua's own identically-named helper's
        -- documented priming discipline: the FIRST call only reaches each
        -- thread's initial Wait() and primes it, every call after that runs
        -- one real pass).
        setHealth = function(ped, hp) healthByPed[ped] = hp end,
        threadCreateCount = function() return threadCreateCount end,
        ambulanceIsDownedCalls = ambulanceIsDownedCalls,
        runOneTick = function()
            if not threadRunner.primed then
                threadRunner.step()
                threadRunner.primed = true
            end
            threadRunner.step()
        end,
        setK9Role = function(src, hasRole) hasRoleBySource[src] = hasRole end,
        setJob = function(src, jobName) jobBySource[src] = jobName end,
        setPed = function(src, pedHandle, coords, modelHash)
            pedBySource[src] = pedHandle
            coordsByHandle[pedHandle] = coords or ORIGIN
            if modelHash then modelByPed[pedHandle] = modelHash end
        end,
        moveEntity = function(handle, coords) coordsByHandle[handle] = coords end,
        setOffline = function(src) pedBySource[src] = 0 end,
        registerDoorEntity = function(netId, handle, opts2)
            opts2 = opts2 or {}
            networkEntities[netId] = handle
            existingEntities[handle] = opts2.exists ~= false
            entityTypes[handle] = opts2.entityType or 3
            coordsByHandle[handle] = opts2.coords or ORIGIN
        end,
        dispatchNetEvent = function(eventName, src, ...)
            env.source = src
            local handler = netEvents[eventName]
            assert(handler, 'no handler registered for ' .. eventName)
            return handler(...)
        end,
        firePlayerDropped = function(src, reason)
            env.source = src
            for _, handler in ipairs(eventHandlers['playerDropped'] or {}) do
                handler(reason)
            end
        end,
        -- Section 12: registers `src` as "already connected" for GetPlayers()
        -- AND gives exports.qbx_core:GetPlayer(src) a real-shaped record.
        -- `jobName = nil` deliberately allowed (simulates a connected player
        -- whose PlayerData.job hasn't resolved yet -- the backfill loop's own
        -- `Player.PlayerData.job` guard must skip these, not error).
        setOnlinePlayer = function(src, citizenid, jobName)
            onlinePlayerIds[#onlinePlayerIds + 1] = tostring(src)
            citizenidBySource[src] = citizenid
            if jobName then jobBySource[src] = jobName end
        end,
        setRefreshResult = function(citizenid, jobName, active)
            refreshResultByKey[citizenid .. '|' .. tostring(jobName)] = active
        end,
        refreshCalls = refreshCalls,
        metaDataCallsFor = function(src) return metaDataCalls[src] or {} end,
        fireOnResourceStart = function(resourceName)
            for _, handler in ipairs(eventHandlers['onResourceStart'] or {}) do
                handler(resourceName or 'qbx_k9unit')
            end
        end,
        clearCaptures = function()
            for i = #clientEvents, 1, -1 do clientEvents[i] = nil end
            for i = #notifyCalls, 1, -1 do notifyCalls[i] = nil end
        end,
        ForceDetachLeashForSource = env.ForceDetachLeashForSource,
        ForceDetachOfficerLeashForSource = env.ForceDetachOfficerLeashForSource,
        -- PER-PERSON FEATURE CONTROL (this pass) -- see the fixture's own
        -- header comment above for why this mirrors
        -- tests/pursuitsprint_spec.lua's `grantPermission`/`citizenidFor`.
        -- (`config` is already returned once above -- LINT FIX, this pass:
        -- a duplicate `config = config` key here was overwriting the same
        -- value with itself, a harmless no-op at runtime but a real
        -- luacheck warning; dropped rather than reverting any of this
        -- section's actual additions.)
        citizenidFor = citizenidFor,
        grantPermission = function(citizenid, key, value)
            permissionGrants[citizenid] = permissionGrants[citizenid] or {}
            permissionGrants[citizenid][key] = value
        end,
        permissionCalls = permissionCalls,
        -- PERFORMANCE AUDIT FIX (this pass) -- server/search.lua's
        -- ForEachNearbyPlayer is a resource-global, loaded from a SEPARATE
        -- file this fixture deliberately never loads (this file's own
        -- header: server/main.lua's real dependency chain is
        -- cooldowns.lua -> entities.lua -> main.lua only). It is therefore
        -- genuinely UNDEFINED here by default -- exactly like a real server
        -- would never see (server/search.lua always loads too), but exactly
        -- what proves relayBark/relayDoorScratch's own documented
        -- FALLBACK-TO-`-1`-BROADCAST path (every EXISTING test above/below,
        -- none of which call installForEachNearbyPlayer, keeps exercising
        -- that fallback unchanged -- see relayBark's own "success broadcasts
        -- to -1" test for the pinned proof). installForEachNearbyPlayer
        -- opts IN a minimal, faithful test double for the dedicated
        -- distance-filter tests below -- never the real implementation
        -- (that belongs to search_spec.lua alone), just enough to prove
        -- relayBark/relayDoorScratch call it with the right (coords, radius)
        -- and correctly fan out to whichever players it invites.
        forEachNearbyPlayerCalls = forEachNearbyPlayerCalls,
        installForEachNearbyPlayer = function(nearbyPlayerIds)
            env.ForEachNearbyPlayer = function(coords, radius, callback)
                forEachNearbyPlayerCalls[#forEachNearbyPlayerCalls + 1] = { coords = coords, radius = radius }
                for _, playerId in ipairs(nearbyPlayerIds) do
                    callback(playerId, pedBySource[playerId] or 0)
                end
            end
        end,
        uninstallForEachNearbyPlayer = function() env.ForEachNearbyPlayer = nil end,
    }
end

--- @param f table
--- @param eventName string
--- @return table? -- the most recently captured {event=,target=,args=} entry for eventName, or nil
local function lastClientEvent(f, eventName)
    for i = #f.clientEvents, 1, -1 do
        if f.clientEvents[i].event == eventName then
            return f.clientEvents[i]
        end
    end
    return nil
end

--- @param f table
--- @param eventName string
--- @param target number?
--- @return integer
local function countClientEvents(f, eventName, target)
    local n = 0
    for _, e in ipairs(f.clientEvents) do
        if e.event == eventName and (target == nil or e.target == target) then n = n + 1 end
    end
    return n
end

--- @param f table
--- @param target number
--- @return table? -- the most recently captured {target=,description=,notifyType=} entry for `target`, or nil
local function lastNotifyTo(f, target)
    for i = #f.notifyCalls, 1, -1 do
        if f.notifyCalls[i].target == target then
            return f.notifyCalls[i]
        end
    end
    return nil
end

--- Sets up one fully-eligible K9/officer pair, close together, both online,
--- K9 certified, officer employed by a configured department -- the shared
--- "both parties are individually eligible" baseline nearly every leash test
--- below starts from (each test then perturbs exactly the ONE thing it's
--- testing, e.g. moves a ped, revokes access, changes a job).
--- @param f table
--- @param k9Src number
--- @param officerSrc number
local function setupEligiblePair(f, k9Src, officerSrc)
    f.setPed(k9Src, k9Src * 10, ORIGIN, K9_MODEL_HASH)
    f.setAccess(k9Src, true)
    f.setPed(officerSrc, officerSrc * 10, ORIGIN, OFFICER_MODEL_HASH)
    f.setJob(officerSrc, 'police')
end

--- Drives a full, successful requestLeashAttach -> respondLeashAttach(accept)
--- handshake for an already-eligible pair (see setupEligiblePair). By
--- default clears captured events/notifications afterward so the caller's
--- own assertions start from a clean slate -- pass keepCaptures = true for
--- the (rarer) case where the caller needs to inspect the leashAttached
--- broadcasts THIS handshake itself produced (e.g. Section 5's symmetric
--- role assignment tests, which exist specifically to check who got which
--- role in the broadcast payload).
--- @param f table
--- @param k9Src number
--- @param officerSrc number
--- @param initiatorSrc number -- either k9Src or officerSrc; whichever requests
--- @param keepCaptures boolean?
local function formLeashPair(f, k9Src, officerSrc, initiatorSrc, keepCaptures)
    local targetSrc = (initiatorSrc == k9Src) and officerSrc or k9Src
    f.dispatchNetEvent('qbx_k9unit:server:requestLeashAttach', initiatorSrc, targetSrc)
    f.dispatchNetEvent('qbx_k9unit:server:respondLeashAttach', targetSrc, initiatorSrc, true)
    if not keepCaptures then f.clearCaptures() end
end

-- ========================================================================
-- SECTION 1: file load / handler inventory (read from the source, pinned
-- here so a future silent addition/removal of a handler shows up as a
-- failing count, not just a missing test).
-- ========================================================================

t.test('server/main.lua loads and registers exactly 5 RegisterNetEvent handlers, by name', function()
    local f = newMainFixture()
    local names = {}
    for name in pairs(f.netEventNames) do names[#names + 1] = name end
    table.sort(names)
    t.equals(#names, 5)
    for _, expected in ipairs({
        'qbx_k9unit:server:relayBark',
        'qbx_k9unit:server:relayDoorScratch',
        'qbx_k9unit:server:requestLeashAttach',
        'qbx_k9unit:server:respondLeashAttach',
        'qbx_k9unit:server:detachLeash',
    }) do
        t.isNotNil(f.netEventNames[expected], expected .. ' must be registered')
    end
end)

t.test('server/main.lua registers exactly 2 onResourceStart handlers (cache backfill + config-safety assert -- both fired and pinned by Section 12, not by this inventory-only test)', function()
    local f = newMainFixture()
    t.equals(f.eventHandlerCount('onResourceStart'), 2)
end)

t.test('playerDropped handler count is 4 when cooldowns.lua is loaded alongside: 1 from main.lua itself (leash cleanup) + 3 from cooldowns.lua (Bark/LeashRequest/DoorScratch trackers\' own RegisterPlayerDropped calls)', function()
    local f = newMainFixture()
    t.equals(f.eventHandlerCount('playerDropped'), 4)
end)

-- ============================================================================
-- THE REAL TRIPWIRE -- GENERALISED ACROSS EVERY server/*.lua FILE (this
-- pass). This used to be a single-file test, scanning ONLY server/main.lua's
-- own text. That was exactly the blind spot that let THREE separate real
-- leaks ship with the whole suite green at once: server/roster.lua's
-- RosterReadCooldown/RosterMutateCooldown pair (source-keyed, neither
-- .RegisterPlayerDropped() nor .StartSweep() -- and since FXServer RECYCLES
-- server ids, a brand-new player could inherit a stale "still on cooldown"
-- timestamp from a totally different prior occupant of that id) and
-- a removed feature's own start cooldown (citizenid-keyed, correctly
-- NOT .RegisterPlayerDropped()'d -- clearing it on disconnect would let a
-- citizenid dodge its own anti-farm floor by relogging -- but also missing
-- the .StartSweep() it should have had instead, a pure omission since the
-- flat NewCooldown API already supports it). tests/combat_spec.lua found
-- and fixed this exact blind spot for its own file first; that fix never
-- propagated to the other single-file copies of this same test (including
-- this one) -- this generalised version is that propagation, done once,
-- for every file, so the next instance of this bug class fails HERE
-- instead of shipping a fourth time.
--
-- FILE LIST: derived from fxmanifest.lua's own server_scripts block, never
-- hand-typed -- a hand-typed list rots the moment a new server/*.lua file
-- is added and nobody remembers to add it here too.
--
-- THREE legitimate cleanup shapes now recognised (the third is new this
-- pass -- see CLEARED-IN-OWN-PLAYERDROPPED-HANDLER below):
--   1. keyed by a player `src` directly       -> .RegisterPlayerDropped()
--   2. keyed by anything with no per-connection
--      hook (a netId, a resolved identity string,
--      a fixed constant)                      -> .StartSweep()
--   3. keyed by something RESOLVED FROM a disconnecting source (e.g. a
--      citizenid looked up from `source` at drop time) inside the file's
--      OWN hand-written `AddEventHandler('playerDropped', ...)` handler,
--      which calls `<Tracker>.Clear(<resolvedKey>)` directly -- this is
--      functionally identical to strategy 1, just unable to use the
--      .RegisterPlayerDropped() helper itself, because that helper always
--      clears by the raw `source` value, never a value resolved from it
--      (see server/cooldowns.lua's own NewCooldown/NewNestedCooldown
--      :RegisterPlayerDropped doc comments). server/progression.lua's
--      AwardXPCooldown (NewNestedCooldown, keyed by citizenid) is the one
--      real example today, cleared via `AwardXPCooldown.Clear(citizenid)`
--      inside that file's general playerDropped handler, right alongside
--      the same handler's K9XP/HandlerXP cache eviction.
--
-- A tracker with NONE of the three leaks.
--
-- ALLOWLIST: a small, explicit, per-(file, name) table for trackers that
-- GENUINELY need no cleanup at all -- never a way to silence a real gap.
-- Every real entry today is a NewMutex() keyed by something other than a
-- player source, backed by server/cooldowns.lua's own NewMutex doc comment
-- (GROUP A/GROUP B release-discipline audit): a mutex only ever holds an
-- entry for the duration of one in-flight, guaranteed-to-release critical
-- section, so unlike a cooldown/TTL table it does not accumulate with
-- uptime or connection count regardless of what its key domain is -- plus
-- one NewCooldown() keyed by a single hardcoded constant (never more than
-- one possible entry, ever). Guarded below (mirroring the guard shape
-- tests/partnership_spec.lua already established for its own single-file
-- ALLOWED_WITHOUT_CLEANUP) so this list can never quietly grow to swallow
-- real leaks instead of catching them.
-- ============================================================================
t.test('EVERY tracker (NewCooldown/NewNestedCooldown/NewMutex) in EVERY server/*.lua file has a cleanup strategy -- source-keyed ones register a playerDropped hook, key-keyed ones sweep, citizenid-from-source ones clear inline, and none has NEITHER', function()
    local fxHandle = assert(io.open('../fxmanifest.lua', 'r'))
    local fxText = fxHandle:read('*a')
    fxHandle:close()

    local serverScriptsBlock = fxText:match('\nserver_scripts%s*{(.-)\n}')
    t.isNotNil(serverScriptsBlock,
        'sanity: could not find a top-level server_scripts { ... } block in fxmanifest.lua -- the parse pattern has probably drifted; fix it rather than lowering any floor below')

    local files = {}
    for path in serverScriptsBlock:gmatch("'(server/[%w_]+%.lua)'") do
        files[#files + 1] = path
    end
    t.isTrue(#files >= 40,
        ('sanity: only found %d server/*.lua file(s) declared in fxmanifest.lua server_scripts -- the parse pattern has probably drifted; fix it rather than lowering this floor'):format(#files))

    --- Every playerDropped handler this FILE wrote itself (never
    --- server/cooldowns.lua's internal ones inside :RegisterPlayerDropped/
    --- :StartSweep, since those live in cooldowns.lua's own text, not the
    --- calling file's) as a list of substrings, so strategy 3 above can be
    --- checked as "does this tracker's own .Clear( call appear inside one
    --- of THESE handlers specifically", not "does .Clear( appear anywhere
    --- in the file at all" (which would too easily pass for an unrelated,
    --- non-cleanup .Clear() call elsewhere).
    --- @param text string
    --- @return string[]
    local function extractOwnPlayerDroppedBlocks(text)
        local blocks = {}
        local searchFrom = 1
        while true do
            local s = text:find("AddEventHandler%('playerDropped'", searchFrom)
            if not s then break end
            local e = text:find('\nend%)', s)
            if not e then break end
            blocks[#blocks + 1] = text:sub(s, e)
            searchFrom = e + 1
        end
        return blocks
    end

    local ALLOWED_WITHOUT_CLEANUP = {
        ['server/partnership.lua'] = {
            PartnershipEstablishMutex = 'NewMutex() keyed by ONE fixed resource-wide constant, never a player source -- holds at most one entry, released synchronously (GROUP A pcall discipline). Nothing to leak.',
        },
        ['server/certtiers.lua'] = {
            TierEditMutex = 'NewMutex() keyed by tier_key, a small bounded admin-managed catalogue, never a player source -- GROUP B discipline (explicit release before every early return; critical section contains only SafeWrite-contract K9Store calls, which return false rather than throw). Never accumulates with uptime.',
        },
        ['server/equipmentshop.lua'] = {
            ShopItemEditMutex = 'NewMutex() keyed by an item key, a small bounded admin-managed catalogue, never a player source -- same GROUP B discipline as TierEditMutex.',
        },
        ['server/permissionkeycatalog.lua'] = {
            PermissionKeyEditMutex = 'NewMutex() keyed by a permission key, a small bounded admin-managed catalogue, never a player source -- same GROUP B discipline as TierEditMutex.',
        },
        ['server/xptiers.lua'] = {
            XPTierEditMutex = 'NewMutex() keyed by ONE fixed ladder-wide lock constant, never a player source -- same reasoning as PartnershipEstablishMutex.',
        },
        ['server/medkit.lua'] = {
            MedkitMutex = 'NewMutex() keyed by targetCitizenid, never a player source -- GROUP A discipline (whole critical section wrapped in pcall, unconditional Release immediately after). A mutex only holds an entry for an in-flight critical section, never accumulates over time regardless of key domain.',
        },
        ['server/k9profiles.lua'] = {
            K9ProfileEditMutex = 'NewMutex() keyed by citizenid, never a player source -- GROUP B discipline (explicit release before every early return; critical section contains only SafeWrite-contract K9Store calls). Never accumulates with uptime.',
        },
        ['server/webhook.lua'] = {
            RateLimitCooldown = "NewCooldown() keyed by RATE_LIMIT_KEY, a single hardcoded constant ('discord') -- this store can never hold more than one entry, ever, regardless of player connect/disconnect activity. Nothing to leak.",
        },
    }
    local ALLOWLIST_MAX_ENTRIES = 12 -- hard cap: forces a re-justification pass (not a one-line addition) once this list stops being "small and explicit"

    local allowlistEntryCount, allowlistMatchedCount = 0, 0
    for _, byName in pairs(ALLOWED_WITHOUT_CLEANUP) do
        for _ in pairs(byName) do allowlistEntryCount = allowlistEntryCount + 1 end
    end
    t.isTrue(allowlistEntryCount <= ALLOWLIST_MAX_ENTRIES,
        ('the allowlist has grown to %d entries (cap %d) -- re-justify the whole list rather than adding one more line'):format(allowlistEntryCount, ALLOWLIST_MAX_ENTRIES))

    local totalDeclared, totalChecked = 0, 0

    for _, path in ipairs(files) do
        local handle = assert(io.open('../' .. path, 'r'), 'could not open ' .. path)
        local text = handle:read('*a')
        handle:close()

        local declared = {}
        for line in (text .. '\n'):gmatch('(.-)\n') do
            local name = line:match('^local%s+([%w_]+)%s*=%s*New[CMN]')
                or line:match('^([%w_]+)%s*=%s*New[CMN]')
            if name then declared[#declared + 1] = name end
        end
        totalDeclared = totalDeclared + #declared
        if #declared == 0 then goto continueFile end

        local ownPlayerDroppedBlocks = extractOwnPlayerDroppedBlocks(text)
        local allowedForThisFile = ALLOWED_WITHOUT_CLEANUP[path] or {}

        for _, name in ipairs(declared) do
            if allowedForThisFile[name] then
                allowlistMatchedCount = allowlistMatchedCount + 1
            else
                totalChecked = totalChecked + 1
                local hasPlayerDropped = text:find(name .. '.RegisterPlayerDropped(', 1, true) ~= nil
                local hasSweep = text:find(name .. '.StartSweep(', 1, true) ~= nil
                local hasInlineClear = false
                if not (hasPlayerDropped or hasSweep) then
                    for _, block in ipairs(ownPlayerDroppedBlocks) do
                        if block:find(name .. '.Clear(', 1, true) then
                            hasInlineClear = true
                            break
                        end
                    end
                end
                t.isTrue(hasPlayerDropped or hasSweep or hasInlineClear,
                    ('%s: %s has none of .RegisterPlayerDropped(), .StartSweep(), or an inline .Clear(...) inside this file\'s own playerDropped handler -- whatever it is keyed by, its table grows for the whole uptime of the server with nothing to bound it'):format(path, name))
            end
        end
        ::continueFile::
    end

    -- FLOOR LOWERED 75 -> 65 on 2026-09-02, and the message below says not to
    -- do this lightly, so: ten server files were deleted outright with the
    -- the twelve features the owner removed and their halves,
    -- taking their own trackers with them. The floor's job is to catch the
    -- DISCOVERY PATTERN going stale -- a rename of NewCooldown/NewMutex
    -- would match nothing and this test would pass while checking zero
    -- trackers -- so it must stay well above zero, but it can only ever be
    -- as high as what the surviving files genuinely declare (71 today).
    t.isTrue(totalDeclared >= 65,
        ('sanity: only found %d tracker declaration(s) across every server/*.lua file -- the discovery pattern has probably drifted; fix it rather than lowering this floor'):format(totalDeclared))
    t.equals(allowlistMatchedCount, allowlistEntryCount,
        'every ALLOWED_WITHOUT_CLEANUP entry must match a tracker actually declared in the file it names -- a non-matching entry is stale (renamed/removed tracker) and must be deleted, not left to silently do nothing')
    -- Mirrors tests/partnership_spec.lua's own guard shape for its
    -- single-file ALLOWED_WITHOUT_CLEANUP ("the allowlist must never grow
    -- to cover every tracker -- that would make this test vacuous"),
    -- scaled to the whole-resource count: the overwhelming majority of
    -- every tracker in this resource must still be actively checked by the
    -- real assertion above, not waved through.
    t.isTrue(totalChecked >= totalDeclared - ALLOWLIST_MAX_ENTRIES,
        'more trackers were skipped than the allowlist cap allows -- the allowlist is silently covering trackers that were never added to ALLOWED_WITHOUT_CLEANUP by name (or the discovery pattern double-counted); this test must never pass by skipping instead of checking')
    t.isTrue(totalChecked >= 1, 'the allowlist must never grow to cover every tracker -- that would make this test vacuous')
end)

t.test('server/main.lua exposes ForceDetachLeashForSource and ForceDetachOfficerLeashForSource as resource-global functions', function()
    local f = newMainFixture()
    t.equals(type(f.ForceDetachLeashForSource), 'function')
    t.equals(type(f.ForceDetachOfficerLeashForSource), 'function')
end)

-- ========================================================================
-- SECTION 2: relayBark
-- ========================================================================

t.test('relayBark: feature disabled is a silent no-op (no broadcast, no notify)', function()
    local f = newMainFixture({ features = { BasicBarkSounds = false } })
    f.setPed(1, 10, ORIGIN)
    f.setAccess(1, true)
    f.dispatchNetEvent('qbx_k9unit:server:relayBark', 1, 'bark')
    t.equals(countClientEvents(f, 'qbx_k9unit:client:playBark'), 0)
    t.equals(#f.notifyCalls, 0)
end)

t.test('relayBark: non-string barkType is a silent no-op (never trusts client payload shape)', function()
    local f = newMainFixture()
    f.setPed(1, 10, ORIGIN)
    f.setAccess(1, true)
    f.dispatchNetEvent('qbx_k9unit:server:relayBark', 1, 12345)
    t.equals(countClientEvents(f, 'qbx_k9unit:client:playBark'), 0)
end)

t.test('relayBark: barkType over BARK_TYPE_MAX_LENGTH (16) is a silent no-op, and does NOT consume the rate limit', function()
    local f = newMainFixture()
    f.setPed(1, 10, ORIGIN)
    f.setAccess(1, true)
    f.dispatchNetEvent('qbx_k9unit:server:relayBark', 1, ('x'):rep(17))
    t.equals(countClientEvents(f, 'qbx_k9unit:client:playBark'), 0)
    -- Proves the oversized attempt never reached BarkCooldown.Consume: an
    -- immediately-following, in-length call in the SAME tick still succeeds.
    f.dispatchNetEvent('qbx_k9unit:server:relayBark', 1, 'bark')
    t.equals(countClientEvents(f, 'qbx_k9unit:client:playBark'), 1)
end)

t.test('relayBark: exactly BARK_TYPE_MAX_LENGTH (16) characters is accepted (boundary, not rejected)', function()
    local f = newMainFixture()
    f.setPed(1, 10, ORIGIN)
    f.setAccess(1, true)
    f.dispatchNetEvent('qbx_k9unit:server:relayBark', 1, ('x'):rep(16))
    t.equals(countClientEvents(f, 'qbx_k9unit:client:playBark'), 1)
end)

t.test('relayBark: not certified (HasK9Access false) is a silent no-op', function()
    local f = newMainFixture()
    f.setPed(1, 10, ORIGIN)
    f.setAccess(1, false)
    f.dispatchNetEvent('qbx_k9unit:server:relayBark', 1, 'bark')
    t.equals(countClientEvents(f, 'qbx_k9unit:client:playBark'), 0)
end)

t.test('relayBark: success broadcasts to -1 with the SENDER\'S OWN server-resolved netId (never a client-claimed one -- relayBark takes no netId argument at all)', function()
    local f = newMainFixture()
    f.setPed(7, 70, ORIGIN)
    f.setAccess(7, true)
    f.dispatchNetEvent('qbx_k9unit:server:relayBark', 7, 'bark')
    local ev = lastClientEvent(f, 'qbx_k9unit:client:playBark')
    t.isNotNil(ev)
    t.equals(ev.target, -1)
    t.equals(ev.args[1], 70 + 500000) -- NetworkGetNetworkIdFromEntity(GetPlayerPed(7)) via this fixture's deterministic transform
    t.equals(ev.args[2], 'bark')
end)

t.test('relayBark: per-source cooldown (1000ms) blocks a second call in the same tick, and a third call succeeds once the cooldown has elapsed', function()
    local f = newMainFixture()
    f.setPed(1, 10, ORIGIN)
    f.setAccess(1, true)
    f.dispatchNetEvent('qbx_k9unit:server:relayBark', 1, 'bark')
    f.dispatchNetEvent('qbx_k9unit:server:relayBark', 1, 'bark')
    t.equals(countClientEvents(f, 'qbx_k9unit:client:playBark'), 1)
    f.advance(1000)
    f.dispatchNetEvent('qbx_k9unit:server:relayBark', 1, 'bark')
    t.equals(countClientEvents(f, 'qbx_k9unit:client:playBark'), 2)
end)

t.test('relayBark: the per-source cooldown does not block a DIFFERENT source in the same tick', function()
    local f = newMainFixture()
    f.setPed(1, 10, ORIGIN)
    f.setAccess(1, true)
    f.setPed(2, 20, ORIGIN)
    f.setAccess(2, true)
    f.dispatchNetEvent('qbx_k9unit:server:relayBark', 1, 'bark')
    f.dispatchNetEvent('qbx_k9unit:server:relayBark', 2, 'bark')
    t.equals(countClientEvents(f, 'qbx_k9unit:client:playBark'), 2)
end)

-- ------------------------------------------------------------------
-- PERFORMANCE AUDIT FIX (this pass) -- distance-filtered broadcast via
-- server/search.lua's ForEachNearbyPlayer, in place of an unconditional
-- `-1` broadcast. See NEARBY_BROADCAST_RADIUS_METERS's own declaration
-- comment in server/main.lua for the full writeup (bandwidth fix, never a
-- privacy one -- a bark's netId is inert to a client that never has it
-- streamed in).
-- ------------------------------------------------------------------

t.test('relayBark PERFORMANCE FIX: when ForEachNearbyPlayer is available, it is called with the BARKING K9\'s OWN live coords and the shared NEARBY_BROADCAST_RADIUS_METERS radius (300.0), and the event fans out only to whichever players it invites -- never a bare -1', function()
    local f = newMainFixture()
    f.setPed(7, 70, vec3(100, 200, 300))
    f.setAccess(7, true)
    f.installForEachNearbyPlayer({ 501, 502 }) -- two "nearby" players this test double invites

    f.dispatchNetEvent('qbx_k9unit:server:relayBark', 7, 'bark')

    t.equals(#f.forEachNearbyPlayerCalls, 1, 'relayBark must call ForEachNearbyPlayer exactly once per accepted bark')
    local call = f.forEachNearbyPlayerCalls[1]
    t.equals(call.coords.x, 100)
    t.equals(call.coords.y, 200)
    t.equals(call.coords.z, 300)
    t.equals(call.radius, 300.0, 'must be main.lua\'s own NEARBY_BROADCAST_RADIUS_METERS constant, not an ad-hoc value')

    t.equals(countClientEvents(f, 'qbx_k9unit:client:playBark'), 2, 'exactly one playBark event per invited player, never a bare -1 broadcast when the helper is available')
    local targets = {}
    for _, ev in ipairs(f.clientEvents) do
        if ev.event == 'qbx_k9unit:client:playBark' then targets[ev.target] = true end
    end
    t.isTrue(targets[501] and targets[502], 'both invited players must individually receive the event')
    t.isNil(targets[-1], 'must never ALSO fire a bare -1 broadcast alongside the filtered ones')

    f.uninstallForEachNearbyPlayer()
end)

t.test('relayBark PERFORMANCE FIX: when ForEachNearbyPlayer is unavailable (this fixture\'s own default -- server/search.lua genuinely not loaded alongside main.lua here, mirroring any real load-order edge case), relayBark falls back to the original, safe -1 broadcast rather than silently broadcasting to nobody', function()
    local f = newMainFixture()
    f.setPed(7, 70, ORIGIN)
    f.setAccess(7, true)
    -- Deliberately never calling installForEachNearbyPlayer -- proves the
    -- fallback, not merely the happy path.
    f.dispatchNetEvent('qbx_k9unit:server:relayBark', 7, 'bark')
    local ev = lastClientEvent(f, 'qbx_k9unit:client:playBark')
    t.isNotNil(ev)
    t.equals(ev.target, -1, 'a bark nobody hears because a helper failed to load is a worse bug than the bandwidth fix -- must fall back to broadcasting to everyone, never silently to no one')
end)

-- ------------------------------------------------------------------
-- PER-PERSON FEATURE CONTROL (config.lua's Config.FeatureControl 4-step
-- resolution) -- IsBasicBarkSoundsPermittedForCitizenId. Mirrors
-- tests/pursuitsprint_spec.lua's own section of the same name.
-- ------------------------------------------------------------------

t.test('relayBark BLOCK: an explicit block.BasicBarkSounds grant is a silent no-op even though HasK9Access is true, and burns NO cooldown', function()
    local f = newMainFixture()
    f.setPed(1, 10, ORIGIN)
    f.setAccess(1, true)
    f.grantPermission(f.citizenidFor(1), 'block.BasicBarkSounds', true)

    f.dispatchNetEvent('qbx_k9unit:server:relayBark', 1, 'bark')
    t.equals(countClientEvents(f, 'qbx_k9unit:client:playBark'), 0)

    -- Unblock and retry IMMEDIATELY (same tick) -- if the blocked attempt
    -- had consumed BarkCooldown, this would now be silently rate-limited
    -- instead of succeeding.
    f.grantPermission(f.citizenidFor(1), 'block.BasicBarkSounds', false)
    f.dispatchNetEvent('qbx_k9unit:server:relayBark', 1, 'bark')
    t.equals(countClientEvents(f, 'qbx_k9unit:client:playBark'), 1, 'a block must never burn the cooldown a legitimate follow-up bark still needs')
end)

t.test('relayBark not blocked: an ordinary K9 with no grant/block row at all still barks (default allow, step 4)', function()
    local f = newMainFixture()
    f.setPed(1, 10, ORIGIN)
    f.setAccess(1, true)
    f.dispatchNetEvent('qbx_k9unit:server:relayBark', 1, 'bark')
    t.equals(countClientEvents(f, 'qbx_k9unit:client:playBark'), 1)
end)

t.test('relayBark RequireGrant listed + no grant held -- denied even though HasK9Access is true', function()
    local f = newMainFixture()
    f.config.FeatureControl.RequireGrant.BasicBarkSounds = true
    f.setPed(1, 10, ORIGIN)
    f.setAccess(1, true)
    -- deliberately NOT granted
    f.dispatchNetEvent('qbx_k9unit:server:relayBark', 1, 'bark')
    t.equals(countClientEvents(f, 'qbx_k9unit:client:playBark'), 0)
end)

t.test('relayBark RequireGrant listed + an active feature.BasicBarkSounds grant -- allowed', function()
    local f = newMainFixture()
    f.config.FeatureControl.RequireGrant.BasicBarkSounds = true
    f.setPed(1, 10, ORIGIN)
    f.setAccess(1, true)
    f.grantPermission(f.citizenidFor(1), 'feature.BasicBarkSounds', true)
    f.dispatchNetEvent('qbx_k9unit:server:relayBark', 1, 'bark')
    t.equals(countClientEvents(f, 'qbx_k9unit:client:playBark'), 1)
end)

-- ========================================================================
-- SECTION 3: relayDoorScratch
-- ========================================================================

t.test('relayDoorScratch: feature disabled is a silent no-op', function()
    local f = newMainFixture({ features = { DoorInteraction = false } })
    f.setPed(1, 10, ORIGIN)
    f.setAccess(1, true)
    f.registerDoorEntity(9001, 900, { coords = ORIGIN })
    f.dispatchNetEvent('qbx_k9unit:server:relayDoorScratch', 1, 9001)
    t.equals(countClientEvents(f, 'qbx_k9unit:client:playDoorScratch'), 0)
end)

t.test('relayDoorScratch: non-number doorNetId is a silent no-op', function()
    local f = newMainFixture()
    f.setPed(1, 10, ORIGIN)
    f.setAccess(1, true)
    f.dispatchNetEvent('qbx_k9unit:server:relayDoorScratch', 1, 'not-a-number')
    t.equals(countClientEvents(f, 'qbx_k9unit:client:playDoorScratch'), 0)
end)

t.test('relayDoorScratch: not certified is a silent no-op', function()
    local f = newMainFixture()
    f.setPed(1, 10, ORIGIN)
    f.setAccess(1, false)
    f.registerDoorEntity(9001, 900, { coords = ORIGIN })
    f.dispatchNetEvent('qbx_k9unit:server:relayDoorScratch', 1, 9001)
    t.equals(countClientEvents(f, 'qbx_k9unit:client:playDoorScratch'), 0)
end)

t.test('relayDoorScratch: a doorNetId that does not resolve to any real entity is a silent no-op (real ResolveNetworkEntity, not a reimplementation)', function()
    local f = newMainFixture()
    f.setPed(1, 10, ORIGIN)
    f.setAccess(1, true)
    f.dispatchNetEvent('qbx_k9unit:server:relayDoorScratch', 1, 999999)
    t.equals(countClientEvents(f, 'qbx_k9unit:client:playDoorScratch'), 0)
end)

t.test('relayDoorScratch: a resolved entity that is NOT type 3 (object) -- e.g. another player\'s ped -- is a hard reject, not advisory', function()
    local f = newMainFixture()
    f.setPed(1, 10, ORIGIN)
    f.setAccess(1, true)
    f.registerDoorEntity(9001, 900, { coords = ORIGIN, entityType = 1 }) -- 1 = ped
    f.dispatchNetEvent('qbx_k9unit:server:relayDoorScratch', 1, 9001)
    t.equals(countClientEvents(f, 'qbx_k9unit:client:playDoorScratch'), 0)
end)

t.test('relayDoorScratch: exactly at the distance boundary (interactDistance + 1.0m tolerance = 2.5m) is allowed', function()
    local f = newMainFixture()
    f.setPed(1, 10, vec3(0, 0, 0))
    f.setAccess(1, true)
    f.registerDoorEntity(9001, 900, { coords = vec3(2.5, 0, 0) })
    f.dispatchNetEvent('qbx_k9unit:server:relayDoorScratch', 1, 9001)
    t.equals(countClientEvents(f, 'qbx_k9unit:client:playDoorScratch'), 1)
end)

t.test('relayDoorScratch: just past the distance boundary is rejected', function()
    local f = newMainFixture()
    f.setPed(1, 10, vec3(0, 0, 0))
    f.setAccess(1, true)
    f.registerDoorEntity(9001, 900, { coords = vec3(2.51, 0, 0) })
    f.dispatchNetEvent('qbx_k9unit:server:relayDoorScratch', 1, 9001)
    t.equals(countClientEvents(f, 'qbx_k9unit:client:playDoorScratch'), 0)
end)

t.test('relayDoorScratch: per-SOURCE cooldown blocks a second scratch on a DIFFERENT door from the same source', function()
    local f = newMainFixture()
    f.setPed(1, 10, ORIGIN)
    f.setAccess(1, true)
    f.registerDoorEntity(9001, 900, { coords = ORIGIN })
    f.registerDoorEntity(9002, 901, { coords = ORIGIN })
    f.dispatchNetEvent('qbx_k9unit:server:relayDoorScratch', 1, 9001)
    f.dispatchNetEvent('qbx_k9unit:server:relayDoorScratch', 1, 9002)
    t.equals(countClientEvents(f, 'qbx_k9unit:client:playDoorScratch'), 1)
end)

t.test('relayDoorScratch: per-DOOR cooldown blocks a second scratch on the SAME door from a DIFFERENT (also-certified) source -- closes the colluding-accounts flood', function()
    local f = newMainFixture()
    f.setPed(1, 10, ORIGIN)
    f.setAccess(1, true)
    f.setPed(2, 20, ORIGIN)
    f.setAccess(2, true)
    f.registerDoorEntity(9001, 900, { coords = ORIGIN })
    f.dispatchNetEvent('qbx_k9unit:server:relayDoorScratch', 1, 9001)
    f.dispatchNetEvent('qbx_k9unit:server:relayDoorScratch', 2, 9001)
    t.equals(countClientEvents(f, 'qbx_k9unit:client:playDoorScratch'), 1)
end)

t.test('relayDoorScratch: after BOTH cooldowns elapse, the same door can be scratched again', function()
    local f = newMainFixture()
    f.setPed(1, 10, ORIGIN)
    f.setAccess(1, true)
    f.registerDoorEntity(9001, 900, { coords = ORIGIN })
    f.dispatchNetEvent('qbx_k9unit:server:relayDoorScratch', 1, 9001)
    f.advance(3000)
    f.dispatchNetEvent('qbx_k9unit:server:relayDoorScratch', 1, 9001)
    t.equals(countClientEvents(f, 'qbx_k9unit:client:playDoorScratch'), 2)
end)

t.test('relayDoorScratch: success broadcasts doorNetId to -1 (global -- a door location carries no person/vehicle identity to leak)', function()
    local f = newMainFixture()
    f.setPed(1, 10, ORIGIN)
    f.setAccess(1, true)
    f.registerDoorEntity(9001, 900, { coords = ORIGIN })
    f.dispatchNetEvent('qbx_k9unit:server:relayDoorScratch', 1, 9001)
    local ev = lastClientEvent(f, 'qbx_k9unit:client:playDoorScratch')
    t.isNotNil(ev)
    t.equals(ev.target, -1)
    t.equals(ev.args[1], 9001)
end)

-- ------------------------------------------------------------------
-- PERFORMANCE AUDIT FIX (this pass) -- same ForEachNearbyPlayer mechanism
-- as relayBark's own section above, centered on the DOOR's own coords (the
-- sound's actual source), not the calling K9's -- see the broadcast call
-- site's own comment in server/main.lua.
-- ------------------------------------------------------------------

t.test('relayDoorScratch PERFORMANCE FIX: when ForEachNearbyPlayer is available, it is called with the DOOR\'s own coords (not the K9\'s) and the shared NEARBY_BROADCAST_RADIUS_METERS radius (300.0), fanning out only to invited players -- never a bare -1', function()
    local f = newMainFixture()
    f.setPed(1, 10, vec3(1, 0, 0)) -- the K9's OWN position, deliberately different from the door's below
    f.setAccess(1, true)
    f.registerDoorEntity(9001, 900, { coords = vec3(0, 0, 0) })
    f.installForEachNearbyPlayer({ 501, 502 })

    f.dispatchNetEvent('qbx_k9unit:server:relayDoorScratch', 1, 9001)

    t.equals(#f.forEachNearbyPlayerCalls, 1, 'relayDoorScratch must call ForEachNearbyPlayer exactly once per accepted scratch')
    local call = f.forEachNearbyPlayerCalls[1]
    t.equals(call.coords.x, 0, 'must be centered on the DOOR entity\'s own coords, not the K9\'s')
    t.equals(call.coords.y, 0)
    t.equals(call.coords.z, 0)
    t.equals(call.radius, 300.0, 'must be main.lua\'s own shared NEARBY_BROADCAST_RADIUS_METERS constant, not an ad-hoc value')

    t.equals(countClientEvents(f, 'qbx_k9unit:client:playDoorScratch'), 2, 'exactly one playDoorScratch event per invited player, never a bare -1 broadcast when the helper is available')

    f.uninstallForEachNearbyPlayer()
end)

t.test('relayDoorScratch PERFORMANCE FIX: when ForEachNearbyPlayer is unavailable (this fixture\'s own default), relayDoorScratch falls back to the original, safe -1 broadcast rather than silently broadcasting to nobody', function()
    local f = newMainFixture()
    f.setPed(1, 10, ORIGIN)
    f.setAccess(1, true)
    f.registerDoorEntity(9001, 900, { coords = ORIGIN })
    f.dispatchNetEvent('qbx_k9unit:server:relayDoorScratch', 1, 9001)
    local ev = lastClientEvent(f, 'qbx_k9unit:client:playDoorScratch')
    t.isNotNil(ev)
    t.equals(ev.target, -1)
end)

-- ------------------------------------------------------------------
-- PER-PERSON FEATURE CONTROL (config.lua's Config.FeatureControl 4-step
-- resolution) -- IsDoorInteractionPermittedForCitizenId. Mirrors this same
-- file's own relayBark/BasicBarkSounds section above verbatim -- relayDoorScratch
-- is a one-shot relay with no ongoing state of its own (unlike leash), so
-- there is no separate termination/cleanup path to pin here: gating the
-- whole action is the correct, and only, decision for this feature.
-- ------------------------------------------------------------------

t.test('relayDoorScratch BLOCK: an explicit block.DoorInteraction grant is a silent no-op even though HasK9Access is true, and burns NO cooldown', function()
    local f = newMainFixture()
    f.setPed(1, 10, ORIGIN)
    f.setAccess(1, true)
    f.registerDoorEntity(9001, 900, { coords = ORIGIN })
    f.grantPermission(f.citizenidFor(1), 'block.DoorInteraction', true)

    f.dispatchNetEvent('qbx_k9unit:server:relayDoorScratch', 1, 9001)
    t.equals(countClientEvents(f, 'qbx_k9unit:client:playDoorScratch'), 0)

    -- Unblock and retry IMMEDIATELY (same tick) -- if the blocked attempt
    -- had consumed either cooldown, this would now be silently rate-limited
    -- instead of succeeding.
    f.grantPermission(f.citizenidFor(1), 'block.DoorInteraction', false)
    f.dispatchNetEvent('qbx_k9unit:server:relayDoorScratch', 1, 9001)
    t.equals(countClientEvents(f, 'qbx_k9unit:client:playDoorScratch'), 1, 'a block must never burn the cooldown a legitimate follow-up scratch still needs')
end)

t.test('relayDoorScratch not blocked: an ordinary K9 with no grant/block row at all still scratches (default allow, step 4)', function()
    local f = newMainFixture()
    f.setPed(1, 10, ORIGIN)
    f.setAccess(1, true)
    f.registerDoorEntity(9001, 900, { coords = ORIGIN })
    f.dispatchNetEvent('qbx_k9unit:server:relayDoorScratch', 1, 9001)
    t.equals(countClientEvents(f, 'qbx_k9unit:client:playDoorScratch'), 1)
end)

t.test('relayDoorScratch RequireGrant listed + no grant held -- denied even though HasK9Access is true', function()
    local f = newMainFixture()
    f.config.FeatureControl.RequireGrant.DoorInteraction = true
    f.setPed(1, 10, ORIGIN)
    f.setAccess(1, true)
    f.registerDoorEntity(9001, 900, { coords = ORIGIN })
    -- deliberately NOT granted
    f.dispatchNetEvent('qbx_k9unit:server:relayDoorScratch', 1, 9001)
    t.equals(countClientEvents(f, 'qbx_k9unit:client:playDoorScratch'), 0)
end)

t.test('relayDoorScratch RequireGrant listed + an active feature.DoorInteraction grant -- allowed', function()
    local f = newMainFixture()
    f.config.FeatureControl.RequireGrant.DoorInteraction = true
    f.setPed(1, 10, ORIGIN)
    f.setAccess(1, true)
    f.registerDoorEntity(9001, 900, { coords = ORIGIN })
    f.grantPermission(f.citizenidFor(1), 'feature.DoorInteraction', true)
    f.dispatchNetEvent('qbx_k9unit:server:relayDoorScratch', 1, 9001)
    t.equals(countClientEvents(f, 'qbx_k9unit:client:playDoorScratch'), 1)
end)

t.test('relayDoorScratch: server/permissions.lua entirely absent (HasPermission not even defined) + RequireGrant listed -- fails CLOSED, never open', function()
    local f = newMainFixture({ withHasPermission = false })
    f.config.FeatureControl.RequireGrant.DoorInteraction = true
    f.setPed(1, 10, ORIGIN)
    f.setAccess(1, true)
    f.registerDoorEntity(9001, 900, { coords = ORIGIN })
    local ok = pcall(f.dispatchNetEvent, 'qbx_k9unit:server:relayDoorScratch', 1, 9001)
    t.isTrue(ok, 'a missing HasPermission must never error the event handler')
    t.equals(countClientEvents(f, 'qbx_k9unit:client:playDoorScratch'), 0, 'RequireGrant-listed + unresolvable grant machinery must deny, not silently allow')
end)

t.test('relayDoorScratch: server/permissions.lua entirely absent + NOT listed in RequireGrant -- still allowed (step 2/3 both structurally unreachable, falls through to step 4)', function()
    local f = newMainFixture({ withHasPermission = false })
    f.setPed(1, 10, ORIGIN)
    f.setAccess(1, true)
    f.registerDoorEntity(9001, 900, { coords = ORIGIN })
    f.dispatchNetEvent('qbx_k9unit:server:relayDoorScratch', 1, 9001)
    t.equals(countClientEvents(f, 'qbx_k9unit:client:playDoorScratch'), 1)
end)

-- ========================================================================
-- SECTION 4: CheckLeashEligibility's 8 rejection reasons, each driven
-- through requestLeashAttach's real code path and pinned against the REAL
-- locale() string (never a hand-copied English literal).
-- ========================================================================

t.test('leash reject reason: feature_disabled', function()
    local f = newMainFixture({ features = { LeashMechanics = false } })
    setupEligiblePair(f, 1, 2)
    f.dispatchNetEvent('qbx_k9unit:server:requestLeashAttach', 1, 2)
    t.equals(lastNotifyTo(f, 1).description, locale('leash.feature_disabled'))
    t.equals(countClientEvents(f, 'qbx_k9unit:client:leashAttachRequest'), 0)
end)

t.test('leash reject reason: invalid_target via requestLeashAttach\'s own upfront type guard (non-number targetServerId)', function()
    local f = newMainFixture()
    setupEligiblePair(f, 1, 2)
    f.dispatchNetEvent('qbx_k9unit:server:requestLeashAttach', 1, 'not-a-number')
    t.equals(lastNotifyTo(f, 1).description, locale('leash.invalid_target'))
end)

t.test('leash reject reason: invalid_target via CheckLeashEligibility\'s self-target guard (initiatorSrc == targetSrc)', function()
    local f = newMainFixture()
    setupEligiblePair(f, 1, 2)
    f.dispatchNetEvent('qbx_k9unit:server:requestLeashAttach', 1, 1)
    t.equals(lastNotifyTo(f, 1).description, locale('leash.invalid_target'))
end)

t.test('leash reject reason: already_leashed (initiator already paired with a third party)', function()
    local f = newMainFixture()
    setupEligiblePair(f, 1, 2)
    formLeashPair(f, 1, 2, 2) -- 1 (K9) and 2 (officer) are now leashed to each other
    setupEligiblePair(f, 3, 4)
    f.setJob(3, 'police') -- harmless extra; 3 will act as a second officer requesting 1
    f.dispatchNetEvent('qbx_k9unit:server:requestLeashAttach', 3, 1)
    t.equals(lastNotifyTo(f, 3).description, locale('leash.already_leashed'))
end)

t.test('leash reject reason: already_leashed (target already paired with a third party)', function()
    local f = newMainFixture()
    setupEligiblePair(f, 1, 2)
    formLeashPair(f, 1, 2, 2)
    setupEligiblePair(f, 5, 1) -- overwrite ped 1's setup is fine, 1 stays the paired K9
    f.dispatchNetEvent('qbx_k9unit:server:requestLeashAttach', 5, 1)
    t.equals(lastNotifyTo(f, 5).description, locale('leash.already_leashed'))
end)

t.test('leash reject reason: offline (target never connected -- GetPlayerPed returns 0)', function()
    local f = newMainFixture()
    f.setPed(1, 10, ORIGIN, K9_MODEL_HASH)
    f.setAccess(1, true)
    -- target 2 never set up at all -> GetPlayerPed(2) == 0
    f.dispatchNetEvent('qbx_k9unit:server:requestLeashAttach', 1, 2)
    t.equals(lastNotifyTo(f, 1).description, locale('common.target_no_longer_online'))
end)

t.test('leash reject reason: too_far (both online, beyond Config.LeashMaxDistance)', function()
    local f = newMainFixture()
    setupEligiblePair(f, 1, 2)
    f.moveEntity(20, vec3(LEASH_MAX_DISTANCE + 1.0, 0, 0)) -- officer's ped handle is officerSrc*10 = 20
    f.dispatchNetEvent('qbx_k9unit:server:requestLeashAttach', 1, 2)
    t.equals(lastNotifyTo(f, 1).description, locale('leash.too_far'))
end)

t.test('leash reject reason: no_k9_party (neither party is a configured K9 model)', function()
    local f = newMainFixture()
    f.setPed(1, 10, ORIGIN, OFFICER_MODEL_HASH)
    f.setJob(1, 'police')
    f.setPed(2, 20, ORIGIN, OFFICER_MODEL_HASH)
    f.setJob(2, 'police')
    f.dispatchNetEvent('qbx_k9unit:server:requestLeashAttach', 1, 2)
    t.equals(lastNotifyTo(f, 1).description, locale('common.no_k9_party'))
end)

-- K9 ROLE/MODEL DECOUPLING WIDENING -- "I also want everything to work with
-- any ped". Previously, a certified handler holding the K9 role while
-- standing on a human (or any unrecognized custom) model was rejected
-- outright as `no_k9_party`, exactly as if neither party were a K9 at all.
-- These pin the fix: HasK9Role(src) now stands in for
-- IsConfiguredK9Model(GetEntityModel(...)) wherever the model check alone
-- would otherwise fail.
t.test('K9 ROLE/MODEL DECOUPLING: a role-holder on a HUMAN model (not a configured K9 model) is still accepted as the K9 party -- no longer no_k9_party', function()
    local f = newMainFixture()
    -- Both peds wear the officer model; only source 1 holds the decoupled
    -- K9 role. Pre-widening this was unconditionally `no_k9_party`.
    f.setPed(1, 10, ORIGIN, OFFICER_MODEL_HASH)
    f.setAccess(1, true)
    f.setK9Role(1, true)
    f.setPed(2, 20, ORIGIN, OFFICER_MODEL_HASH)
    f.setJob(2, 'police')
    f.dispatchNetEvent('qbx_k9unit:server:requestLeashAttach', 1, 2)
    t.equals(lastNotifyTo(f, 1).description, locale('leash.request_sent'), 'a human-modeled role-holder must be accepted as the K9 party, not rejected as no_k9_party')
end)

t.test('K9 ROLE/MODEL DECOUPLING: role-holder-on-human-model still must satisfy HasK9Access (not_certified still fires)', function()
    local f = newMainFixture()
    f.setPed(1, 10, ORIGIN, OFFICER_MODEL_HASH)
    f.setAccess(1, false) -- role granted, but not currently certified/access-holding
    f.setK9Role(1, true)
    f.setPed(2, 20, ORIGIN, OFFICER_MODEL_HASH)
    f.setJob(2, 'police')
    f.dispatchNetEvent('qbx_k9unit:server:requestLeashAttach', 1, 2)
    t.equals(lastNotifyTo(f, 1).description, locale('common.k9_not_certified'), 'the widening only decides WHO counts as the K9 party -- HasK9Access is still independently enforced')
end)

t.test('K9 ROLE/MODEL DECOUPLING: HasK9Role not being loaded at all (soft dependency absent) fails CLOSED to the pre-decoupling model-only check, never errors', function()
    -- Rebuild a fixture with no HasK9Role global at all (simulates
    -- server/appearance.lua being removed/not loaded) by loading main.lua
    -- directly rather than through newMainFixture(), which always injects
    -- the stub above.
    local fakeNow = 0
    local eventHandlers, netEvents = {}, {}
    local env = Sandbox.newEnv({
        GetGameTimer = function() return fakeNow end,
        AddEventHandler = function(name, h) eventHandlers[name] = eventHandlers[name] or {}; eventHandlers[name][#eventHandlers[name] + 1] = h end,
        RegisterNetEvent = function(name, h) netEvents[name] = h end,
        GetCurrentResourceName = function() return 'qbx_k9unit' end,
        TriggerClientEvent = function() end,
        NotifyPlayer = function() end,
        HasK9Access = function() return true end,
        IsConfiguredK9Model = function(hash) return hash == K9_MODEL_HASH end,
        -- HasK9Role deliberately OMITTED.
        exports = { qbx_core = { GetPlayer = function() return nil end } },
        GetPlayerPed = function() return 0 end,
        GetEntityCoords = function() return ORIGIN end,
        GetEntityModel = function() return OFFICER_MODEL_HASH end,
        NetworkGetNetworkIdFromEntity = function(h) return h end,
        NetworkGetEntityFromNetworkId = function() return 0 end,
        DoesEntityExist = function() return false end,
        GetEntityType = function() return 0 end,
        GetPlayers = function() return {} end,
        CreateThread = Sandbox.newThreadRunner().CreateThread,
        Wait = Sandbox.newThreadRunner().Wait,
        Config = { Features = { LeashMechanics = true }, LeashMaxDistance = LEASH_MAX_DISTANCE, Departments = { police = true } },
    })
    Sandbox.loadInto('../server/cooldowns.lua', env)
    Sandbox.loadInto('../server/entities.lua', env)
    -- Must not raise merely from HasK9Role being absent (type(HasK9Role) ==
    -- 'function' is false for a nil global -- the `and` short-circuits
    -- before ever calling it).
    Sandbox.loadInto('../server/main.lua', env)
    t.isNotNil(netEvents['qbx_k9unit:server:requestLeashAttach'], 'file must still load and register its handlers with HasK9Role entirely absent')
end)

-- ========================================================================
-- BOTH-ARE-K9 REJECTION (owner-reported gap, this pass): CheckLeashEligibility
-- previously only ever rejected "NEITHER party is a K9" -- when BOTH
-- genuinely hold the K9 role, the EDGE CASE tie-break used to silently
-- cast one of them as the officer/handler role instead of refusing
-- outright, since a K9 role-holder is typically ALSO a department member
-- and so trivially clears officer_not_in_department too. See
-- server/main.lua's own "BOTH-ARE-K9 CASE" comment and IsGenuinelyK9Party's
-- doc comment for the full "role, not model, not HasK9Access" reasoning
-- this section pins -- identical shape to server/partnership.lua's own
-- CheckPartnershipEligibility fix and tests/partnership_spec.lua's mirror
-- of these same four cases.
-- ========================================================================

-- ========================================================================
-- PARTNERS LEASH WITHOUT A PROMPT. Two players who are partnered already
-- agreed to work together, so the leash goes on at once. Everyone else is
-- still asked.
-- ========================================================================

--- @param f table
--- @param pairs table -- { {cidA, cidB}, ... } treated as partnered (either order)
local function setPartners(f, pairsList)
    f.env.IsActivePartnerOf = function(a, b)
        for _, p in ipairs(pairsList) do
            if (p[1] == a and p[2] == b) or (p[1] == b and p[2] == a) then return true end
        end
        return false
    end
end

t.test('partners: the officer asks, and the leash goes on at once for both -- no accept prompt', function()
    local f = newMainFixture({ features = { HandlerPartnership = true } })
    setupEligiblePair(f, 1, 2)
    setPartners(f, { { f.citizenidFor(1), f.citizenidFor(2) } })

    f.dispatchNetEvent('qbx_k9unit:server:requestLeashAttach', 2, 1)

    t.equals(countClientEvents(f, 'qbx_k9unit:client:leashAttachRequest'), 0, 'no prompt between partners')
    t.equals(countClientEvents(f, 'qbx_k9unit:client:leashAttached', 1), 1, 'the K9 is leashed')
    t.equals(countClientEvents(f, 'qbx_k9unit:client:leashAttached', 2), 1, 'the officer holds the leash')
end)

t.test('partners: works the same when the K9 is the one who asks', function()
    local f = newMainFixture({ features = { HandlerPartnership = true } })
    setupEligiblePair(f, 1, 2)
    setPartners(f, { { f.citizenidFor(1), f.citizenidFor(2) } })

    f.dispatchNetEvent('qbx_k9unit:server:requestLeashAttach', 1, 2)

    t.equals(countClientEvents(f, 'qbx_k9unit:client:leashAttachRequest'), 0)
    t.equals(countClientEvents(f, 'qbx_k9unit:client:leashAttached'), 2)
end)

t.test('not partners: the other player is still asked first, and nothing attaches until they accept', function()
    local f = newMainFixture({ features = { HandlerPartnership = true } })
    setupEligiblePair(f, 1, 2)
    setPartners(f, { { f.citizenidFor(1), 'SOMEONE-ELSE' } })

    f.dispatchNetEvent('qbx_k9unit:server:requestLeashAttach', 2, 1)

    t.equals(countClientEvents(f, 'qbx_k9unit:client:leashAttachRequest', 1), 1, 'the K9 gets the accept/decline prompt')
    t.equals(countClientEvents(f, 'qbx_k9unit:client:leashAttached'), 0)
end)

t.test('partners, but partnership turned off on this server: back to asking', function()
    local f = newMainFixture({ features = { HandlerPartnership = false } })
    setupEligiblePair(f, 1, 2)
    setPartners(f, { { f.citizenidFor(1), f.citizenidFor(2) } })

    f.dispatchNetEvent('qbx_k9unit:server:requestLeashAttach', 2, 1)

    t.equals(countClientEvents(f, 'qbx_k9unit:client:leashAttachRequest', 1), 1)
    t.equals(countClientEvents(f, 'qbx_k9unit:client:leashAttached'), 0)
end)

t.test('partners: every normal leash rule still applies -- too far apart is refused, nothing attaches', function()
    local f = newMainFixture({ features = { HandlerPartnership = true } })
    setupEligiblePair(f, 1, 2)
    setPartners(f, { { f.citizenidFor(1), f.citizenidFor(2) } })
    f.moveEntity(20, vec3(ORIGIN.x + LEASH_MAX_DISTANCE * 10, ORIGIN.y, ORIGIN.z))

    f.dispatchNetEvent('qbx_k9unit:server:requestLeashAttach', 2, 1)

    t.equals(countClientEvents(f, 'qbx_k9unit:client:leashAttached'), 0)
    t.equals(lastNotifyTo(f, 2).notifyType, 'error')
end)

t.test('partners: the normal request cooldown still applies, so attach cannot be spammed', function()
    local f = newMainFixture({ features = { HandlerPartnership = true } })
    setupEligiblePair(f, 1, 2)
    setPartners(f, { { f.citizenidFor(1), f.citizenidFor(2) } })

    f.dispatchNetEvent('qbx_k9unit:server:requestLeashAttach', 2, 1)
    f.dispatchNetEvent('qbx_k9unit:server:detachLeash', 2)
    f.clearCaptures()
    f.dispatchNetEvent('qbx_k9unit:server:requestLeashAttach', 2, 1) -- same instant
    t.equals(countClientEvents(f, 'qbx_k9unit:client:leashAttached'), 0, 'refused inside the cooldown')

    f.advance(1000)
    f.dispatchNetEvent('qbx_k9unit:server:requestLeashAttach', 2, 1)
    t.equals(countClientEvents(f, 'qbx_k9unit:client:leashAttached'), 2, 'allowed once it has passed')
end)

t.test('requestLeashAttach: both parties genuinely holding the K9 role (HasK9Role) is rejected as both_k9, not silently assigning one of them the officer/handler role', function()
    local f = newMainFixture()
    f.setPed(1, 10, ORIGIN, OFFICER_MODEL_HASH) -- neither is even on a K9 MODEL -- role alone must be enough to catch this
    f.setJob(1, 'police')
    f.setK9Role(1, true)
    f.setAccess(1, true)
    f.setPed(2, 20, ORIGIN, OFFICER_MODEL_HASH)
    f.setJob(2, 'police')
    f.setK9Role(2, true)
    f.setAccess(2, true)
    f.dispatchNetEvent('qbx_k9unit:server:requestLeashAttach', 1, 2)
    -- The dedicated key landed 2026-08-26, so this now reports its own
    -- message rather than the generic fallback. What matters either way:
    -- it MUST NOT be reported as no_k9_party (the wrong diagnosis) and
    -- MUST NOT silently succeed (the bug itself).
    t.equals(lastNotifyTo(f, 1).description, locale('common.both_k9'))
    t.equals(countClientEvents(f, 'qbx_k9unit:client:leashAttachRequest'), 0, 'no consent prompt may ever be sent when both parties are genuinely K9s')
end)

t.test('requestLeashAttach: both on a CONFIGURED K9 MODEL but only ONE genuinely holds the K9 role still succeeds -- ped model alone must never trigger both_k9 (preserves "a handler can visually be on a dog model")', function()
    local f = newMainFixture()
    f.setPed(1, 10, ORIGIN, K9_MODEL_HASH) -- on the configured K9 model, but...
    f.setJob(1, 'police')
    -- ...holds no K9 role/access at all -- an ordinary department officer
    -- who merely happens to be modeled as the configured K9 species.
    f.setPed(2, 20, ORIGIN, K9_MODEL_HASH)
    f.setJob(2, 'police')
    f.setAccess(2, true) -- only the actual K9 (2) is certified
    f.setK9Role(2, true)
    f.dispatchNetEvent('qbx_k9unit:server:requestLeashAttach', 1, 2)
    t.equals(lastNotifyTo(f, 1).description, locale('leash.request_sent'), 'a department officer merely modeled as a K9, holding no real K9 role, must still be able to anchor a real K9')
end)

t.test('requestLeashAttach: a HasK9Access bypass (e.g. High Command/autoAccessGrade) with no actual K9 role must not be misread as "genuinely a K9" for the both_k9 check', function()
    local f = newMainFixture()
    f.setPed(1, 10, ORIGIN, OFFICER_MODEL_HASH)
    f.setJob(1, 'police')
    f.setAccess(1, true) -- HasK9Access true (bypass) but no HasK9Role -- see IsGenuinelyK9Party's own doc comment for why HasK9Access alone is deliberately too WIDE a signal for this check
    f.setPed(2, 20, ORIGIN, OFFICER_MODEL_HASH)
    f.setJob(2, 'police')
    f.setAccess(2, true)
    f.setK9Role(2, true)
    f.dispatchNetEvent('qbx_k9unit:server:requestLeashAttach', 1, 2)
    t.equals(lastNotifyTo(f, 1).description, locale('leash.request_sent'), 'HasK9Access alone must not count as "genuinely a K9" here, or a bypass-holding officer could never anchor a real K9 at all')
end)

-- ========================================================================
-- SAME-IDENTITY GUARD, BY CITIZENID (owner-directed, this pass): a server
-- id is a per-connection number, not a stable identity -- the citizenid is.
-- ========================================================================

t.test('requestLeashAttach: two different server ids that resolve to the SAME citizenid are rejected as invalid_target, not treated as two distinct parties', function()
    local f = newMainFixture()
    -- Simulates a stale pending request (or any other path) resolving
    -- against a NEW session for the same citizenid: two live server ids,
    -- one underlying person.
    f.setOnlinePlayer(1, 'SAME-CID', 'police')
    f.setOnlinePlayer(2, 'SAME-CID', 'police')
    f.setPed(1, 10, ORIGIN, OFFICER_MODEL_HASH)
    f.setPed(2, 20, ORIGIN, K9_MODEL_HASH)
    f.setAccess(2, true)
    f.dispatchNetEvent('qbx_k9unit:server:requestLeashAttach', 1, 2)
    t.equals(lastNotifyTo(f, 1).description, locale('leash.invalid_target'))
    t.equals(countClientEvents(f, 'qbx_k9unit:client:leashAttachRequest'), 0)
end)

t.test('leash reject reason: not_certified (K9-modeled party lacks HasK9Access)', function()
    local f = newMainFixture()
    setupEligiblePair(f, 1, 2)
    f.setAccess(1, false) -- K9 party (1) is not certified
    f.dispatchNetEvent('qbx_k9unit:server:requestLeashAttach', 1, 2)
    t.equals(lastNotifyTo(f, 1).description, locale('common.k9_not_certified'))
end)

t.test('leash reject reason: officer_not_in_department (officer has no Player record at all)', function()
    local f = newMainFixture()
    f.setPed(1, 10, ORIGIN, K9_MODEL_HASH)
    f.setAccess(1, true)
    f.setPed(2, 20, ORIGIN, OFFICER_MODEL_HASH)
    -- deliberately never f.setJob(2, ...) -- exports.qbx_core:GetPlayer(2) returns nil
    f.dispatchNetEvent('qbx_k9unit:server:requestLeashAttach', 1, 2)
    t.equals(lastNotifyTo(f, 1).description, locale('common.handler_not_in_department'))
end)

t.test('leash reject reason: officer_not_in_department (officer has a Player record, but an unconfigured job)', function()
    local f = newMainFixture()
    setupEligiblePair(f, 1, 2)
    f.setJob(2, 'civilian')
    f.dispatchNetEvent('qbx_k9unit:server:requestLeashAttach', 1, 2)
    t.equals(lastNotifyTo(f, 1).description, locale('common.handler_not_in_department'))
end)

t.test('a genuinely eligible request notifies the initiator with leash.request_sent, not a rejection', function()
    local f = newMainFixture()
    setupEligiblePair(f, 1, 2)
    f.dispatchNetEvent('qbx_k9unit:server:requestLeashAttach', 1, 2)
    t.equals(lastNotifyTo(f, 1).description, locale('leash.request_sent'))
end)

-- ------------------------------------------------------------------
-- PER-PERSON FEATURE CONTROL (config.lua's Config.FeatureControl 4-step
-- resolution) -- IsLeashMechanicsPermittedForCitizenId, checked for BOTH
-- parties. Mirrors tests/pursuitsprint_spec.lua's own section of the same
-- name.
-- ------------------------------------------------------------------

t.test('leash BLOCK on the K9-role party denies the request, and burns NO rate limit', function()
    local f = newMainFixture()
    setupEligiblePair(f, 1, 2)
    f.grantPermission(f.citizenidFor(1), 'block.LeashMechanics', true)

    f.dispatchNetEvent('qbx_k9unit:server:requestLeashAttach', 1, 2)
    t.equals(lastNotifyTo(f, 1).description, locale('leash.reject_fallback'))
    t.isNil(lastClientEvent(f, 'qbx_k9unit:client:leashAttachRequest'), 'a blocked request must never even prompt the target')

    -- Unblock and retry IMMEDIATELY (same tick) -- if the blocked attempt
    -- had consumed LeashRequestCooldown, this would now be silently
    -- rate-limited instead of succeeding.
    f.grantPermission(f.citizenidFor(1), 'block.LeashMechanics', false)
    f.dispatchNetEvent('qbx_k9unit:server:requestLeashAttach', 1, 2)
    t.equals(lastNotifyTo(f, 1).description, locale('leash.request_sent'), 'a block must never burn the cooldown a legitimate follow-up request still needs')
end)

t.test('leash BLOCK on the OFFICER/handler-role party ALSO denies the request -- a block on either party refuses forming the pair', function()
    local f = newMainFixture()
    setupEligiblePair(f, 1, 2)
    f.grantPermission(f.citizenidFor(2), 'block.LeashMechanics', true)
    f.dispatchNetEvent('qbx_k9unit:server:requestLeashAttach', 1, 2)
    t.equals(lastNotifyTo(f, 1).description, locale('leash.reject_fallback'))
end)

t.test('leash not blocked: an ordinary pair with no grant/block row at all still forms (default allow, step 4)', function()
    local f = newMainFixture()
    setupEligiblePair(f, 1, 2)
    f.dispatchNetEvent('qbx_k9unit:server:requestLeashAttach', 1, 2)
    t.equals(lastNotifyTo(f, 1).description, locale('leash.request_sent'))
end)

t.test('leash RequireGrant listed + no grant held -- denied even though every other check passes', function()
    local f = newMainFixture()
    f.config.FeatureControl.RequireGrant.LeashMechanics = true
    setupEligiblePair(f, 1, 2)
    -- deliberately NOT granted
    f.dispatchNetEvent('qbx_k9unit:server:requestLeashAttach', 1, 2)
    t.equals(lastNotifyTo(f, 1).description, locale('leash.reject_fallback'))
end)

t.test('leash RequireGrant listed + BOTH parties hold an active feature.LeashMechanics grant -- allowed', function()
    local f = newMainFixture()
    f.config.FeatureControl.RequireGrant.LeashMechanics = true
    setupEligiblePair(f, 1, 2)
    f.grantPermission(f.citizenidFor(1), 'feature.LeashMechanics', true)
    f.grantPermission(f.citizenidFor(2), 'feature.LeashMechanics', true)
    f.dispatchNetEvent('qbx_k9unit:server:requestLeashAttach', 1, 2)
    t.equals(lastNotifyTo(f, 1).description, locale('leash.request_sent'))
end)

t.test('leash RequireGrant listed + only ONE of the two parties holds a grant -- still denied (both parties must independently pass)', function()
    local f = newMainFixture()
    f.config.FeatureControl.RequireGrant.LeashMechanics = true
    setupEligiblePair(f, 1, 2)
    f.grantPermission(f.citizenidFor(1), 'feature.LeashMechanics', true)
    -- citizenid 2 (the officer) deliberately NOT granted
    f.dispatchNetEvent('qbx_k9unit:server:requestLeashAttach', 1, 2)
    t.equals(lastNotifyTo(f, 1).description, locale('leash.reject_fallback'))
end)

t.test('TERMINATION PATH UNAFFECTED: detachLeash still works instantly for a K9-role party who is now block.LeashMechanics-blocked -- "detach a leash" must never be gated', function()
    local f = newMainFixture()
    setupEligiblePair(f, 1, 2)
    formLeashPair(f, 1, 2, 1, true) -- keepCaptures = true, just to sanity-check the pair formed below
    t.isNotNil(lastClientEvent(f, 'qbx_k9unit:client:leashAttached'), 'sanity: the pair really formed')

    -- Block AFTER the pair is already formed -- mirrors a real "high command
    -- blocks this handler mid-session" sequence.
    f.grantPermission(f.citizenidFor(1), 'block.LeashMechanics', true)
    f.clearCaptures()
    f.dispatchNetEvent('qbx_k9unit:server:detachLeash', 1)
    t.equals(countClientEvents(f, 'qbx_k9unit:client:leashDetached'), 2, 'a blocked K9 must still be able to detach unilaterally, and both parties are still notified')
    t.isFalse(f.ForceDetachLeashForSource(1), 'no longer leashed -- the detach genuinely went through')
end)

-- ========================================================================
-- SECTION 5: symmetric role assignment -- "What matters most" item 1.
-- CheckLeashEligibility assigns K9/officer roles from each party's LIVE PED
-- MODEL, never from who initiated. Proven by running the SAME two concrete
-- players through BOTH request directions and confirming both resolve to
-- the identical k9Src/officerSrc assignment.
-- ========================================================================

t.test('symmetric role assignment: OFFICER-initiated request resolves K9-role to the K9-modeled party, officer-role to the officer-modeled party', function()
    local f = newMainFixture()
    setupEligiblePair(f, 100, 200) -- 100 = K9 model, 200 = officer model
    -- Officer (200) initiates towards the K9 (100).
    formLeashPair(f, 100, 200, 200, true)
    -- Both attach broadcasts fired; find each by target.
    local toK9, toOfficer
    for _, ev in ipairs(f.clientEvents) do
        if ev.event == 'qbx_k9unit:client:leashAttached' then
            if ev.target == 100 then toK9 = ev end
            if ev.target == 200 then toOfficer = ev end
        end
    end
    t.isNotNil(toK9, 'K9 (100) must receive its own leashAttached broadcast')
    t.isNotNil(toOfficer, 'officer (200) must receive its own leashAttached broadcast')
    t.equals(toK9.args[1], 200) -- partnerServerId
    t.equals(toK9.args[2], true) -- isConstrained = true for the K9 role
    t.equals(toOfficer.args[1], 100)
    t.equals(toOfficer.args[2], false) -- isConstrained = false for the officer role
end)

t.test('symmetric role assignment: K9-initiated request resolves to the IDENTICAL k9Src/officerSrc assignment as the officer-initiated case above', function()
    local f = newMainFixture()
    setupEligiblePair(f, 100, 200) -- same two concrete players, same models, as the test above
    -- This time the K9 (100) initiates towards the officer (200).
    formLeashPair(f, 100, 200, 100, true)
    local toK9, toOfficer
    for _, ev in ipairs(f.clientEvents) do
        if ev.event == 'qbx_k9unit:client:leashAttached' then
            if ev.target == 100 then toK9 = ev end
            if ev.target == 200 then toOfficer = ev end
        end
    end
    t.isNotNil(toK9, 'K9 (100) must receive its own leashAttached broadcast')
    t.isNotNil(toOfficer, 'officer (200) must receive its own leashAttached broadcast')
    -- IDENTICAL to the officer-initiated case: role comes from live ped
    -- model, never from which side called requestLeashAttach.
    t.equals(toK9.args[1], 200)
    t.equals(toK9.args[2], true)
    t.equals(toOfficer.args[1], 100)
    t.equals(toOfficer.args[2], false)
end)

t.test('EDGE CASE, confirmed in server/main.lua\'s own header: when BOTH parties are K9-modeled, the REQUEST TARGET becomes the constrained/K9 role, regardless of which specific player is asked', function()
    local f = newMainFixture()
    -- Both players share the K9 model. Both need HasK9Access (either could
    -- end up in the K9 role) AND a configured department job (either could
    -- end up in the officer role) for every direction to be able to succeed.
    f.setPed(300, 3000, ORIGIN, K9_MODEL_HASH)
    f.setAccess(300, true)
    f.setJob(300, 'police')
    f.setPed(400, 4000, ORIGIN, K9_MODEL_HASH)
    f.setAccess(400, true)
    f.setJob(400, 'police')

    -- Direction 1: 300 requests attach to 400 -> 400 (the target) becomes K9-role.
    formLeashPair(f, 400, 300, 300, true) -- k9Src=400, officerSrc=300, initiator=300
    local toTarget400
    for _, ev in ipairs(f.clientEvents) do
        if ev.event == 'qbx_k9unit:client:leashAttached' and ev.target == 400 then toTarget400 = ev end
    end
    t.isNotNil(toTarget400)
    t.equals(toTarget400.args[2], true, 'the request TARGET (400) must be the constrained/K9 role')

    -- Tear down, then reverse direction with a FRESH pair of ids so this
    -- fixture's already_leashed guard doesn't interfere.
    f.dispatchNetEvent('qbx_k9unit:server:detachLeash', 400)
    f.clearCaptures()

    -- Direction 2: 400 requests attach to 300 -> 300 (the NEW target) becomes K9-role this time.
    formLeashPair(f, 300, 400, 400, true) -- k9Src=300, officerSrc=400, initiator=400
    local toTarget300
    for _, ev in ipairs(f.clientEvents) do
        if ev.event == 'qbx_k9unit:client:leashAttached' and ev.target == 300 then toTarget300 = ev end
    end
    t.isNotNil(toTarget300)
    t.equals(toTarget300.args[2], true, 'the request TARGET (300) must be the constrained/K9 role this time -- confirms it tracks "who was asked", not a fixed id')
end)

-- ========================================================================
-- SECTION 6: requestLeashAttach's own single-slot pending guard + rate
-- limit ordering.
-- ========================================================================

t.test('a second request to a target with an already-live pending request is rejected (pending_request_exists), WITHOUT clobbering the first pending entry', function()
    local f = newMainFixture()
    setupEligiblePair(f, 1, 2) -- A(1, K9) -> T(2, officer)
    setupEligiblePair(f, 3, 2) -- overwrites 2's ped/job identically; B(3, K9) will also target T(2)
    f.dispatchNetEvent('qbx_k9unit:server:requestLeashAttach', 1, 2) -- A's request lands first
    f.clearCaptures()
    f.dispatchNetEvent('qbx_k9unit:server:requestLeashAttach', 3, 2) -- B's request while A's is still live
    t.equals(lastNotifyTo(f, 3).description, locale('leash.pending_request_exists'))
    t.equals(countClientEvents(f, 'qbx_k9unit:client:leashAttachRequest', 2), 0, 'B\'s rejected request must not reach the target as a second prompt')

    -- A's ORIGINAL pending entry must still be intact: T can still accept A.
    f.dispatchNetEvent('qbx_k9unit:server:respondLeashAttach', 2, 1, true)
    t.equals(countClientEvents(f, 'qbx_k9unit:client:leashAttached', 1), 1, 'A\'s original request must still resolve to a real pairing')
end)

t.test('the pending_request_exists rejection does NOT consume the rejected caller\'s own rate limit', function()
    local f = newMainFixture()
    setupEligiblePair(f, 1, 2)
    setupEligiblePair(f, 3, 2)
    f.dispatchNetEvent('qbx_k9unit:server:requestLeashAttach', 1, 2)
    f.clearCaptures()
    f.dispatchNetEvent('qbx_k9unit:server:requestLeashAttach', 3, 2) -- rejected: pending_request_exists
    -- B (3) immediately tries a DIFFERENT target (4) in the SAME tick -- if
    -- the rejection above had burned B's cooldown, this would be silently
    -- dropped instead of reaching CheckLeashEligibility's own reject path.
    setupEligiblePair(f, 3, 4)
    f.dispatchNetEvent('qbx_k9unit:server:requestLeashAttach', 3, 4)
    t.equals(countClientEvents(f, 'qbx_k9unit:client:leashAttachRequest', 4), 1,
        'B\'s cooldown must still be available immediately after a pending_request_exists rejection')
end)

t.test('after the pending TTL (30s) expires, a new request to the same target is allowed again', function()
    local f = newMainFixture()
    setupEligiblePair(f, 1, 2)
    setupEligiblePair(f, 3, 2)
    f.dispatchNetEvent('qbx_k9unit:server:requestLeashAttach', 1, 2)
    f.advance(30001)
    f.clearCaptures()
    f.dispatchNetEvent('qbx_k9unit:server:requestLeashAttach', 3, 2)
    -- B's request now genuinely succeeds (A's stale pending no longer blocks
    -- it) -- the notify B gets is the real success message, not a rejection.
    t.equals(lastNotifyTo(f, 3).description, locale('leash.request_sent'))
    t.equals(countClientEvents(f, 'qbx_k9unit:client:leashAttachRequest', 2), 1)
end)

t.test('LEASH_REQUEST_COOLDOWN_MS (1000ms) rate-limits requestLeashAttach per INITIATOR: a second request in the same tick is silently dropped', function()
    local f = newMainFixture()
    setupEligiblePair(f, 1, 2)
    setupEligiblePair(f, 1, 3) -- same initiator (1), a different target this time
    f.dispatchNetEvent('qbx_k9unit:server:requestLeashAttach', 1, 2)
    f.clearCaptures()
    f.dispatchNetEvent('qbx_k9unit:server:requestLeashAttach', 1, 3)
    t.equals(#f.notifyCalls, 0, 'rate-limited: silent no-op, not an error notify')
    t.equals(countClientEvents(f, 'qbx_k9unit:client:leashAttachRequest', 3), 0)
end)

-- ========================================================================
-- SECTION 7: respondLeashAttach -- type guard, spoofed fromServerId,
-- expiry, decline, and (priority 3) double-accept/double-respond fail-closed.
-- ========================================================================

t.test('respondLeashAttach: non-number fromServerId is a silent no-op', function()
    local f = newMainFixture()
    setupEligiblePair(f, 1, 2)
    f.dispatchNetEvent('qbx_k9unit:server:requestLeashAttach', 1, 2)
    f.clearCaptures()
    f.dispatchNetEvent('qbx_k9unit:server:respondLeashAttach', 2, 'not-a-number', true)
    t.equals(#f.notifyCalls, 0)
    t.equals(countClientEvents(f, 'qbx_k9unit:client:leashAttached'), 0)
end)

t.test('respondLeashAttach: a MISMATCHED fromServerId never notifies the wrongly-claimed id, and never forms a pair (the half of the coder-security fix that IS correct)', function()
    local f = newMainFixture()
    setupEligiblePair(f, 1, 2) -- real pending: 1 -> 2
    setupEligiblePair(f, 9, 2) -- 9 exists as a real, unrelated online player, never actually requested anything
    f.dispatchNetEvent('qbx_k9unit:server:requestLeashAttach', 1, 2)
    f.clearCaptures()
    f.dispatchNetEvent('qbx_k9unit:server:respondLeashAttach', 2, 9, true) -- 2 claims fromServerId = 9, but the real pending is from 1
    t.equals(lastNotifyTo(f, 2).description, locale('leash.request_no_longer_valid_self'))
    t.isNil(lastNotifyTo(f, 9), 'the mismatched/unrelated id must receive NOTHING (verifiedMatch is false)')
    t.equals(countClientEvents(f, 'qbx_k9unit:client:leashAttached'), 0)
end)

t.test('REGRESSION GUARD: a MISMATCHED fromServerId no longer destroys an unrelated initiator\'s still-live pending request. This was a real bug -- the `not verifiedMatch` branch cleared PendingLeashRequests[src] unconditionally, so an ordinary duplicate or stale respondLeashAttach naming the WRONG fromServerId silently wiped a FRESH, valid request from a DIFFERENT initiator, who was never told. No attacker needed: a UI double-fire carrying an already-resolved interaction id was enough. LeashMechanics ships enabled, so this reached ordinary servers.', function()
    local f = newMainFixture()
    setupEligiblePair(f, 1, 2) -- A(1) sends a real, currently-live request to T(2)
    f.dispatchNetEvent('qbx_k9unit:server:requestLeashAttach', 1, 2)
    f.clearCaptures()

    -- T's client fires respondLeashAttach with a stale/wrong fromServerId
    -- (9 stands in for "anything other than 1" -- e.g. a duplicated click
    -- still carrying a previous, already-resolved interaction's id). This
    -- has NOTHING to do with A's real, still-pending request from 1.
    f.dispatchNetEvent('qbx_k9unit:server:respondLeashAttach', 2, 9, true)
    t.equals(lastNotifyTo(f, 2).description, locale('leash.request_no_longer_valid_self'),
        'the caller is still told their response was not valid')
    t.isNil(lastNotifyTo(f, 1),
        'and the wrongly-named id is still never notified -- that no-echo property predates this fix and must survive it, or an arbitrary-target notify reopens')

    -- A's real request SURVIVES the unrelated mismatched call. This is the
    -- fix: the branch now leaves an entry it never verified alone.
    f.clearCaptures()
    f.dispatchNetEvent('qbx_k9unit:server:respondLeashAttach', 2, 1, true)
    t.equals(countClientEvents(f, 'qbx_k9unit:client:leashAttached'), 2,
        'A\'s genuine request still accepts normally -- the entry backing it was never touched')
    t.isNil(lastNotifyTo(f, 2), 'and a successful accept produces no error notice to either side')
end)

t.test('respondLeashAttach: an EXPIRED but genuinely-matching pending request notifies BOTH sides "no longer valid" (verified match, just too late)', function()
    local f = newMainFixture()
    setupEligiblePair(f, 1, 2)
    f.dispatchNetEvent('qbx_k9unit:server:requestLeashAttach', 1, 2)
    f.advance(30001)
    f.clearCaptures()
    f.dispatchNetEvent('qbx_k9unit:server:respondLeashAttach', 2, 1, true)
    t.equals(lastNotifyTo(f, 2).description, locale('leash.request_no_longer_valid_self'))
    t.equals(lastNotifyTo(f, 1).description, locale('leash.request_no_longer_valid_initiator'))
    t.equals(countClientEvents(f, 'qbx_k9unit:client:leashAttached'), 0)
end)

t.test('respondLeashAttach: decline notifies ONLY the initiator (leash.request_declined), never the decliner, and forms no pair', function()
    local f = newMainFixture()
    setupEligiblePair(f, 1, 2)
    f.dispatchNetEvent('qbx_k9unit:server:requestLeashAttach', 1, 2)
    f.clearCaptures()
    f.dispatchNetEvent('qbx_k9unit:server:respondLeashAttach', 2, 1, false)
    t.equals(lastNotifyTo(f, 1).description, locale('leash.request_declined'))
    t.isNil(lastNotifyTo(f, 2), 'the decliner receives no notification of their own decline')
    t.equals(countClientEvents(f, 'qbx_k9unit:client:leashAttached'), 0)
end)

t.test('DOUBLE-ACCEPT fails closed: the pending entry is consumed immediately on the first accept -- a second accept for the same request finds nothing', function()
    local f = newMainFixture()
    setupEligiblePair(f, 1, 2)
    f.dispatchNetEvent('qbx_k9unit:server:requestLeashAttach', 1, 2)
    f.dispatchNetEvent('qbx_k9unit:server:respondLeashAttach', 2, 1, true) -- first accept: real pairing forms
    t.equals(countClientEvents(f, 'qbx_k9unit:client:leashAttached'), 2, 'sanity: the first accept really did form a pair (one broadcast per side)')
    f.clearCaptures()

    f.dispatchNetEvent('qbx_k9unit:server:respondLeashAttach', 2, 1, true) -- SECOND accept, same args
    t.equals(countClientEvents(f, 'qbx_k9unit:client:leashAttached'), 0, 'no second attach broadcast')
    t.equals(lastNotifyTo(f, 2).description, locale('leash.request_no_longer_valid_self'))
    t.isNil(lastNotifyTo(f, 1), 'the original initiator gets nothing on a replayed accept (no matching pending -- verifiedMatch is false)')

    -- The ORIGINAL pairing must still be intact, undisturbed by the replay.
    t.isTrue(f.ForceDetachLeashForSource(1), 'the real pairing from the FIRST accept must still exist')
end)

t.test('a DECLINE after an already-consumed ACCEPT also fails closed (same "consumed immediately" mechanism, not a separate bug class)', function()
    local f = newMainFixture()
    setupEligiblePair(f, 1, 2)
    f.dispatchNetEvent('qbx_k9unit:server:requestLeashAttach', 1, 2)
    f.dispatchNetEvent('qbx_k9unit:server:respondLeashAttach', 2, 1, true) -- consumed by the real accept
    f.clearCaptures()

    f.dispatchNetEvent('qbx_k9unit:server:respondLeashAttach', 2, 1, false) -- replayed as a decline this time
    t.equals(lastNotifyTo(f, 2).description, locale('leash.request_no_longer_valid_self'))
    t.isNil(lastNotifyTo(f, 1), 'the initiator must not receive a spurious request_declined for an already-resolved request')
    t.equals(countClientEvents(f, 'qbx_k9unit:client:leashDetached'), 0, 'a fail-closed replay must not detach the real, already-formed pairing either')
end)

t.test('a DOUBLE-DECLINE also fails closed on the second call', function()
    local f = newMainFixture()
    setupEligiblePair(f, 1, 2)
    f.dispatchNetEvent('qbx_k9unit:server:requestLeashAttach', 1, 2)
    f.dispatchNetEvent('qbx_k9unit:server:respondLeashAttach', 2, 1, false) -- first decline: consumes the pending
    f.clearCaptures()
    f.dispatchNetEvent('qbx_k9unit:server:respondLeashAttach', 2, 1, false) -- second decline: nothing left to consume
    t.equals(lastNotifyTo(f, 2).description, locale('leash.request_no_longer_valid_self'))
    t.isNil(lastNotifyTo(f, 1), 'initiator must not receive a second request_declined')
end)

-- ========================================================================
-- SECTION 8: TOCTOU -- distance AND liveness are re-checked in full at
-- accept time, closing the window between request and accept.
-- ========================================================================

t.test('TOCTOU: parties were within range at REQUEST time but moved apart before ACCEPT -- the accept is rejected (too_far), and no pair forms', function()
    local f = newMainFixture()
    setupEligiblePair(f, 1, 2)
    f.dispatchNetEvent('qbx_k9unit:server:requestLeashAttach', 1, 2) -- succeeds: both at ORIGIN
    t.equals(countClientEvents(f, 'qbx_k9unit:client:leashAttachRequest'), 1, 'sanity: the request itself was valid while both were close')
    f.moveEntity(10, vec3(LEASH_MAX_DISTANCE + 5.0, 0, 0)) -- K9's ped (1*10=10) walks far away before responding
    f.clearCaptures()

    f.dispatchNetEvent('qbx_k9unit:server:respondLeashAttach', 2, 1, true)
    t.equals(countClientEvents(f, 'qbx_k9unit:client:leashAttached'), 0)
    t.equals(lastNotifyTo(f, 1).description, locale('leash.too_far'))
    t.equals(lastNotifyTo(f, 2).description, locale('leash.too_far'))
    t.isFalse(f.ForceDetachLeashForSource(1), 'no pairing was ever actually formed')
end)

t.test('TOCTOU: the initiator disconnects (ped resolves to 0) between request and accept -- the accept is rejected (offline), not silently paired with a stale ped', function()
    local f = newMainFixture()
    setupEligiblePair(f, 1, 2)
    f.dispatchNetEvent('qbx_k9unit:server:requestLeashAttach', 1, 2)
    f.setOffline(1) -- simulates a vanished ped WITHOUT going through the playerDropped cleanup path -- isolates CheckLeashEligibility's own re-check
    f.clearCaptures()

    f.dispatchNetEvent('qbx_k9unit:server:respondLeashAttach', 2, 1, true)
    t.equals(countClientEvents(f, 'qbx_k9unit:client:leashAttached'), 0)
    t.equals(lastNotifyTo(f, 1).description, locale('common.target_no_longer_online'))
    t.equals(lastNotifyTo(f, 2).description, locale('common.target_no_longer_online'))
end)

t.test('TOCTOU: certification is revoked between request and accept -- the accept is rejected (not_certified)', function()
    local f = newMainFixture()
    setupEligiblePair(f, 1, 2)
    f.dispatchNetEvent('qbx_k9unit:server:requestLeashAttach', 1, 2)
    f.setAccess(1, false) -- K9's certification revoked mid-flight
    f.clearCaptures()

    f.dispatchNetEvent('qbx_k9unit:server:respondLeashAttach', 2, 1, true)
    t.equals(countClientEvents(f, 'qbx_k9unit:client:leashAttached'), 0)
    t.equals(lastNotifyTo(f, 1).description, locale('common.k9_not_certified'))
end)

t.test('TOCTOU: a THIRD leash forms in between, making one party already_leashed by accept time -- the accept is rejected', function()
    local f = newMainFixture()
    setupEligiblePair(f, 1, 2)
    f.dispatchNetEvent('qbx_k9unit:server:requestLeashAttach', 1, 2)
    -- While 2 (the officer) is deciding, 1 (the K9) gets leashed to a THIRD party instead.
    setupEligiblePair(f, 1, 3)
    f.dispatchNetEvent('qbx_k9unit:server:requestLeashAttach', 3, 1)
    f.dispatchNetEvent('qbx_k9unit:server:respondLeashAttach', 1, 3, true)
    f.clearCaptures()

    f.dispatchNetEvent('qbx_k9unit:server:respondLeashAttach', 2, 1, true) -- 2 finally accepts the now-stale request
    t.equals(countClientEvents(f, 'qbx_k9unit:client:leashAttached'), 0)
    t.equals(lastNotifyTo(f, 1).description, locale('leash.already_leashed'))
    t.equals(lastNotifyTo(f, 2).description, locale('leash.already_leashed'))
end)

-- ========================================================================
-- SECTION 9: voluntary detachLeash (zero consent) + role-aware forced
-- detach (ForceDetachLeashForSource / ForceDetachOfficerLeashForSource).
-- ========================================================================

t.test('detachLeash: either party can detach unilaterally, with zero consent, and both sides are notified', function()
    local f = newMainFixture()
    setupEligiblePair(f, 1, 2)
    formLeashPair(f, 1, 2, 2)
    f.dispatchNetEvent('qbx_k9unit:server:detachLeash', 1) -- the K9 side detaches itself, no accept needed from 2
    local toK9 = lastClientEvent(f, 'qbx_k9unit:client:leashDetached')
    t.isNotNil(toK9)
    t.equals(countClientEvents(f, 'qbx_k9unit:client:leashDetached'), 2, 'both parties are notified of the detach')
    t.isFalse(f.ForceDetachLeashForSource(1), 'no longer leashed -- ForceDetachLeashForSource is now a no-op')
end)

t.test('detachLeash: a no-op (no error, no broadcast) for a source that was never leashed to anyone', function()
    local f = newMainFixture()
    setupEligiblePair(f, 1, 2)
    f.dispatchNetEvent('qbx_k9unit:server:detachLeash', 1)
    t.equals(#f.clientEvents, 0)
end)

t.test('ForceDetachLeashForSource: detaches when `src` is the K9-role party of its pairing', function()
    local f = newMainFixture()
    setupEligiblePair(f, 1, 2)
    formLeashPair(f, 1, 2, 2)
    t.isTrue(f.ForceDetachLeashForSource(1))
    t.equals(countClientEvents(f, 'qbx_k9unit:client:leashDetached'), 2)
end)

t.test('ForceDetachLeashForSource: role-blind-by-id-membership REGRESSION GUARD -- a no-op when `src` is only the OFFICER/handler-role party of its pairing (their revoked cert must not tear down a leash they\'re merely anchoring)', function()
    local f = newMainFixture()
    setupEligiblePair(f, 1, 2)
    formLeashPair(f, 1, 2, 2)
    t.isFalse(f.ForceDetachLeashForSource(2), 'src=2 is the officer/handler role -- must be a no-op')
    t.equals(#f.clientEvents, 0, 'the still-valid pairing must be completely undisturbed')
    -- Prove the pairing really is still intact via the K9 side.
    t.isTrue(f.ForceDetachLeashForSource(1))
end)

t.test('ForceDetachLeashForSource: a no-op for a source not currently leashed to anyone at all, and never throws for a non-number src', function()
    local f = newMainFixture()
    t.isFalse(f.ForceDetachLeashForSource(1))
    t.isFalse(f.ForceDetachLeashForSource('not-a-number'))
end)

t.test('ForceDetachOfficerLeashForSource: detaches when `src` is the OFFICER-role party, mirrors ForceDetachLeashForSource for the opposite role', function()
    local f = newMainFixture()
    setupEligiblePair(f, 1, 2)
    formLeashPair(f, 1, 2, 2)
    t.isTrue(f.ForceDetachOfficerLeashForSource(2))
    t.equals(countClientEvents(f, 'qbx_k9unit:client:leashDetached'), 2)
end)

t.test('ForceDetachOfficerLeashForSource: a no-op when `src` is the K9-role party instead (that case belongs to ForceDetachLeashForSource, not this one)', function()
    local f = newMainFixture()
    setupEligiblePair(f, 1, 2)
    formLeashPair(f, 1, 2, 2)
    t.isFalse(f.ForceDetachOfficerLeashForSource(1))
    t.equals(#f.clientEvents, 0)
end)

-- ========================================================================
-- SECTION 10: playerDropped -- pending-request leak on disconnect for BOTH
-- parties, active-pairing teardown, and server-id-recycling non-inheritance.
-- "What matters most" item 2.
-- ========================================================================

t.test('playerDropped clears the TARGET-side pending slot: a recycled id does not inherit a stale request aimed at the previous occupant', function()
    local f = newMainFixture()
    setupEligiblePair(f, 1, 2) -- A=1 (K9), T=2 (officer)
    f.dispatchNetEvent('qbx_k9unit:server:requestLeashAttach', 1, 2) -- A -> T, T never responds
    f.firePlayerDropped(2, 'quit') -- T disconnects
    f.clearCaptures()

    -- A brand-new player is assigned the now-freed id 2 (a different model/job entirely).
    f.setPed(2, 999, ORIGIN, OFFICER_MODEL_HASH)
    f.setJob(2, 'police')
    f.dispatchNetEvent('qbx_k9unit:server:respondLeashAttach', 2, 1, true) -- the new occupant "accepts" A's stale request
    t.equals(lastNotifyTo(f, 2).description, locale('leash.request_no_longer_valid_self'))
    t.isNil(lastNotifyTo(f, 1), 'A must not be told anything -- the new occupant never had a genuine matching pending request')
    t.equals(countClientEvents(f, 'qbx_k9unit:client:leashAttached'), 0, 'the new occupant must not be silently leashed to A')
end)

t.test('playerDropped scans and clears the INITIATOR-side pending entry too: a recycled initiator id does not get silently paired via a stale request', function()
    local f = newMainFixture()
    setupEligiblePair(f, 1, 2) -- A=1 (K9), T=2 (officer)
    f.dispatchNetEvent('qbx_k9unit:server:requestLeashAttach', 1, 2) -- A -> T, T never responds
    f.firePlayerDropped(1, 'quit') -- A (the INITIATOR) disconnects, not the target
    f.clearCaptures()

    -- A brand-new, unrelated player is assigned the now-freed id 1.
    f.setPed(1, 888, ORIGIN, OFFICER_MODEL_HASH) -- deliberately NOT a K9 model, to make an accidental pairing obviously wrong if it happened
    f.setJob(1, 'police')
    f.dispatchNetEvent('qbx_k9unit:server:respondLeashAttach', 2, 1, true) -- T, unaware, tries to accept citing the (now-recycled) id 1
    t.equals(lastNotifyTo(f, 2).description, locale('leash.request_no_longer_valid_self'))
    t.isNil(lastNotifyTo(f, 1), 'the new occupant of id 1 must not be notified about a request they never made')
    t.equals(countClientEvents(f, 'qbx_k9unit:client:leashAttached'), 0)
end)

t.test('playerDropped\'s target-side clear does not disturb an UNRELATED pending entry for a different target', function()
    local f = newMainFixture()
    setupEligiblePair(f, 1, 2)
    setupEligiblePair(f, 3, 4)
    f.dispatchNetEvent('qbx_k9unit:server:requestLeashAttach', 1, 2)
    f.dispatchNetEvent('qbx_k9unit:server:requestLeashAttach', 3, 4)
    f.firePlayerDropped(2, 'quit') -- only target 2 disconnects
    f.clearCaptures()

    f.dispatchNetEvent('qbx_k9unit:server:respondLeashAttach', 4, 3, true) -- the UNRELATED pending (3 -> 4) must still be valid
    t.equals(countClientEvents(f, 'qbx_k9unit:client:leashAttached'), 2)
end)

t.test('playerDropped tears down an ACTIVE pairing for either disconnecting party, and a recycled id inherits none of it', function()
    local f = newMainFixture()
    setupEligiblePair(f, 1, 2) -- K9=1, officer=2
    formLeashPair(f, 1, 2, 2)
    f.firePlayerDropped(2, 'quit') -- the officer/handler disconnects
    t.equals(countClientEvents(f, 'qbx_k9unit:client:leashDetached'), 2, 'partner_disconnected broadcast to both (including, harmlessly, the disconnecting id itself)')
    for _, ev in ipairs(f.clientEvents) do
        if ev.event == 'qbx_k9unit:client:leashDetached' and ev.target == 1 then
            t.equals(ev.args[1], 'partner_disconnected')
        end
    end
    f.clearCaptures()

    -- A completely unrelated new player takes the freed id 2.
    f.setPed(2, 777, ORIGIN, OFFICER_MODEL_HASH)
    t.isFalse(f.ForceDetachOfficerLeashForSource(2), 'the new occupant of id 2 inherits no pairing')
    t.isFalse(f.ForceDetachLeashForSource(1), 'the K9 (1) is no longer leashed to anyone -- not silently left bound to the new id 2')
end)

t.test('playerDropped: the disconnecting player\'s OWN pending target-side slot and any pairing they held are cleared even when both apply at once (target of one request AND leashed to someone else is not a real reachable combination, but a lone pairing plus playerDropped on the K9 side is)', function()
    local f = newMainFixture()
    setupEligiblePair(f, 1, 2)
    formLeashPair(f, 1, 2, 2)
    f.firePlayerDropped(1, 'quit') -- the K9 itself disconnects this time
    t.equals(countClientEvents(f, 'qbx_k9unit:client:leashDetached'), 2)
    t.isFalse(f.ForceDetachOfficerLeashForSource(2), 'the officer is no longer leashed to anyone either')
end)

-- ========================================================================
-- SECTION 11: ephemeral / in-memory-only state, and the onResourceStop
-- FINDING. "What matters most" item 6.
-- ========================================================================

t.test('FINDING (disclosed, not fixed here per this task\'s hard rule): server/main.lua registers ZERO onResourceStop handlers for the leash subsystem -- unlike server/kennel.lua/server/propattachment.lua/server/fetch.lua, which each explicitly delete their own live world entities on resource stop, LeashPairs/PendingLeashRequests are pure in-memory bookkeeping with no world entity to clean up, so there is nothing here for an onResourceStop hook to delete. Teardown on a same-session restart (player stays connected) is achieved entirely CLIENT-side today (client/movement.lua\'s own onResourceStop calls DetachLeash(), a normal round trip into THIS file\'s detachLeash handler) -- this server file has no independent fallback if that client-side call never happens (a non-standard/broken client, or a server-only crash with no matching client-side onResourceStop at all). Recorded here as a real, disclosed gap, not asserted as a bug -- see this spec\'s own file header.', function()
    local f = newMainFixture()
    t.equals(f.eventHandlerCount('onResourceStop'), 0)
end)

t.test('ephemeral by construction: a fresh module load (simulating a resource restart) starts with completely empty leash state -- a pairing formed in one sandbox instance is provably invisible to an independently-loaded one', function()
    local f1 = newMainFixture()
    setupEligiblePair(f1, 1, 2)
    formLeashPair(f1, 1, 2, 2)
    t.isTrue(f1.ForceDetachLeashForSource(1), 'sanity: the pairing really exists in f1')
    -- Re-forming it since ForceDetachLeashForSource above just consumed it --
    -- this spec needs the PAIRING to still exist in f1 at the moment f2 is
    -- built, to prove f2 shares NO memory with f1 (not merely that f1 can be
    -- reset, which would prove nothing about cross-instance isolation).
    -- Advance past LEASH_REQUEST_COOLDOWN_MS first: officer 2 (the initiator
    -- inside formLeashPair's own convention here) already consumed that
    -- cooldown once above, in the same fake tick.
    f1.advance(1000)
    setupEligiblePair(f1, 1, 2)
    formLeashPair(f1, 1, 2, 2)

    -- A COMPLETELY SEPARATE sandbox -- fresh cooldowns.lua/entities.lua/
    -- main.lua module load, exactly as a real `/restart qbx_k9unit` would
    -- produce (every local upvalue re-initialized from scratch; nothing
    -- persisted to disk by this file at all -- it calls no MySQL.* anywhere).
    local f2 = newMainFixture()
    t.isFalse(f2.ForceDetachLeashForSource(1), 'a freshly-loaded module instance must know NOTHING about f1\'s pairing')
    t.isFalse(f2.ForceDetachOfficerLeashForSource(2), 'neither role-side of f1\'s pairing leaks into f2')

    -- f1's own pairing, meanwhile, is untouched by f2 having been created.
    t.isTrue(f1.ForceDetachLeashForSource(1), 'f1\'s real pairing still exists independently of f2')
end)

-- ========================================================================
-- SECTION 12: resource-start certification-cache backfill (the "dangling
-- TODO" fix). This file's own header used to say "Resource-start cache
-- backfill (see TODO below)" -- but `grep -n TODO server/main.lua` finds
-- only that one line, the header's own self-reference, and nothing below
-- it. Read from the code (never from the comment, per this task's own
-- instruction): the backfill is NOT missing. It is fully implemented, a
-- few hundred lines further down, as the SECOND of this file's two
-- `onResourceStart` handlers (the "STRUCTURAL GAP backfill" comment block
-- immediately above it) -- it loops GetPlayers(), calls
-- RefreshCertificationCache(citizenid, jobName) for every already-connected
-- player with a resolved job, and resyncs the k9certified metadata mirror
-- from that call's own return value. The dangling pointer is a stale
-- self-reference left over from whenever the inline TODO comment that used
-- to live at this handler's location was replaced by the real
-- implementation (and its accompanying regression-test-fix commentary)
-- without anyone updating the header's pointer to match -- i.e. this is
-- case (a) from this task's brief ("implemented, someone deleted the TODO
-- without updating the pointer"), not case (b) ("never implemented, the
-- marker was lost along with the gap it flagged"). The header above has
-- been corrected to stop pointing at a TODO that no longer exists; this
-- section exists so that fact is pinned by a real test, not just a
-- corrected comment -- until now, NOTHING fired either of this file's two
-- onResourceStart handlers anywhere in this test suite (this file's own
-- prior header disclosed skipping them; server/certifications/'s own
-- spec, tests/certifications_spec.lua, never loads server/main.lua at all
-- and stubs its own unrelated GetPlayers() for a different purpose) -- so
-- the backfill loop's actual behavior was previously unverified by any
-- spec, resting entirely on manual code reading.
-- ========================================================================

t.test('onResourceStart backfill: an already-connected, already-job-resolved player is re-warmed via RefreshCertificationCache(citizenid, jobName) -- the exact scenario a `/restart qbx_k9unit` (or crash-restart) with players online produces', function()
    local f = newMainFixture()
    f.setOnlinePlayer(10, 'ABC123', 'police')
    f.fireOnResourceStart()
    t.equals(#f.refreshCalls, 1)
    t.equals(f.refreshCalls[1].citizenid, 'ABC123')
    t.equals(f.refreshCalls[1].jobName, 'police')
end)

t.test('onResourceStart backfill: resyncs the k9certified metadata mirror from RefreshCertificationCache\'s own return value -- true case', function()
    local f = newMainFixture()
    f.setOnlinePlayer(10, 'ABC123', 'police')
    f.setRefreshResult('ABC123', 'police', true)
    f.fireOnResourceStart()
    local calls = f.metaDataCallsFor(10)
    t.equals(#calls, 1)
    t.equals(calls[1].key, 'k9certified')
    t.isTrue(calls[1].value)
end)

t.test('onResourceStart backfill: resyncs the k9certified metadata mirror from RefreshCertificationCache\'s own return value -- false case (e.g. a stale, out-of-band-edited mirror that must be corrected DOWN, not just up)', function()
    local f = newMainFixture()
    f.setOnlinePlayer(11, 'XYZ789', 'police')
    f.setRefreshResult('XYZ789', 'police', false)
    f.fireOnResourceStart()
    local calls = f.metaDataCallsFor(11)
    t.equals(#calls, 1)
    t.isFalse(calls[1].value)
end)

t.test('onResourceStart backfill: multiple already-connected players are each independently backfilled, in GetPlayers() order', function()
    local f = newMainFixture()
    f.setOnlinePlayer(10, 'AAA', 'police')
    f.setOnlinePlayer(20, 'BBB', 'sheriff')
    f.setRefreshResult('AAA', 'police', true)
    f.setRefreshResult('BBB', 'sheriff', false)
    f.fireOnResourceStart()
    t.equals(#f.refreshCalls, 2)
    t.equals(f.refreshCalls[1].citizenid, 'AAA')
    t.equals(f.refreshCalls[2].citizenid, 'BBB')
    t.isTrue(f.metaDataCallsFor(10)[1].value)
    t.isFalse(f.metaDataCallsFor(20)[1].value)
end)

t.test('onResourceStart backfill: a connected player with no resolved job (Player.PlayerData.job falsy) is skipped -- no RefreshCertificationCache call, no metadata write, no error', function()
    local f = newMainFixture()
    f.setOnlinePlayer(10, 'NOJOB', nil)
    local ok = pcall(f.fireOnResourceStart)
    t.isTrue(ok, 'a job-less connected player must never abort this handler')
    t.equals(#f.refreshCalls, 0)
    t.equals(#f.metaDataCallsFor(10), 0)
end)

t.test('onResourceStart backfill: exports.qbx_core:GetPlayer returning nil (GetPlayers() named an id with no real Player record, e.g. a mid-drop race) is skipped -- no error, and does not abort processing the REST of the online player list', function()
    local f = newMainFixture()
    -- Simulate the "no Player record at all" case directly: an online id that
    -- was never registered via setOnlinePlayer's citizenid/job bookkeeping,
    -- but IS present in GetPlayers()'s own list.
    f.setOnlinePlayer(99, nil, nil) -- citizenid AND job both nil => exportsStub.GetPlayer(99) returns nil, exactly like a real unresolved id
    f.setOnlinePlayer(10, 'REAL', 'police') -- a genuine, resolvable player listed AFTER the unresolvable one
    f.setRefreshResult('REAL', 'police', true)
    local ok = pcall(f.fireOnResourceStart)
    t.isTrue(ok, 'an unresolvable GetPlayer(src) must never abort the whole backfill loop')
    t.equals(#f.refreshCalls, 1, 'only the genuinely resolvable player is backfilled')
    t.equals(f.refreshCalls[1].citizenid, 'REAL')
end)

t.test('onResourceStart backfill: ignores a DIFFERENT resource starting (GetCurrentResourceName mismatch) -- zero RefreshCertificationCache calls even with players online', function()
    local f = newMainFixture()
    f.setOnlinePlayer(10, 'ABC123', 'police')
    f.fireOnResourceStart('some_other_resource')
    t.equals(#f.refreshCalls, 0)
    t.equals(#f.metaDataCallsFor(10), 0)
end)

t.test('onResourceStart config-safety assert: Config.DoorInteraction.nudgeRequiresUnlocked = true (the shipped default) starts fine, no error', function()
    local f = newMainFixture()
    local ok = pcall(f.fireOnResourceStart)
    t.isTrue(ok, 'the shipped-safe default must never itself trip the assert')
end)

t.test('onResourceStart config-safety assert: nudgeRequiresUnlocked = false fails LOUDLY (a thrown assert), naming the field, rather than silently accepting an unsafe lockpick-bypass config', function()
    local f = newMainFixture()
    f.config.DoorInteraction.nudgeRequiresUnlocked = false
    local ok, err = pcall(f.fireOnResourceStart)
    t.isFalse(ok, 'an unsafe nudgeRequiresUnlocked value must abort resource start, not be silently accepted (config-safety guards fail loud, not silent, per this project\'s own "never abort silently" rule read the other way: a REAL safety invariant DOES get a loud abort, unlike an ordinary tunable misconfiguration)')
    t.isTrue(tostring(err):find('nudgeRequiresUnlocked', 1, true) ~= nil, 'the error must name the offending field')
end)

t.test('onResourceStart config-safety assert: ignores a DIFFERENT resource starting -- an unsafe nudgeRequiresUnlocked value does not abort an unrelated resource\'s own start', function()
    local f = newMainFixture()
    f.config.DoorInteraction.nudgeRequiresUnlocked = false
    local ok = pcall(f.fireOnResourceStart, 'some_other_resource')
    t.isTrue(ok, 'a different resource\'s own onResourceStart must never run this resource\'s own startup assert')
end)

-- ========================================================================
-- SECTION 13: DEATH-DETECTION FIX (this pass, coder-frontend -- audit-
-- flagged gap). LeashPairs previously had NO death handler touching it at
-- all -- confirmed by a full read of this file during the visible-leash
-- work (client/leashvisual.lua's own header). A K9 or handler who died
-- mid-leash stayed leashed indefinitely; this section pins the new
-- background poll thread that closes that gap, mirroring
-- an already-tested `IsHandlerDown` precedence
-- (override -> K9Compat ambulance adapter -> metadata -> raw health) rather
-- than re-deriving or re-proving that whole precedence chain a second time
-- here (defense_spec.lua already owns exhaustive coverage of the identical
-- logic shape) -- this section instead proves THIS file's own new
-- responsibility: the thread exists exactly when it should, calls
-- doDetachLeash (the ONE place that mutates LeashPairs on detach) when a
-- participant is detected dead, leaves a genuinely-alive pairing alone, and
-- is safe to run against a small, actively-mutating LeashPairs table.
-- ========================================================================

-- INVERTED ON PURPOSE (2026-08-26). This test used to REQUIRE that the
-- death-detection thread only be created when Config.Features.LeashMechanics
-- was already true AT THIS FILE'S OWN LOAD TIME -- that boot-time snapshot
-- WAS the live-flip bug (see server/main.lua's own doc comment immediately
-- above this thread's `CreateThread` call): server/runtimecontrol.lua's
-- FEATURE_TIERS lists LeashMechanics as `tier = 'live'`, so an operator who
-- boots with the flag off and flips it on later, from the tablet, got a
-- fully live CheckLeashEligibility/respondLeashAttach (each re-checks the
-- flag fresh) writing real LeashPairs entries with the ONE thread that ever
-- auto-detaches a dead party's pairing never having started -- a leashed
-- player who died had nothing to auto-detach their surviving partner for the
-- rest of that server's uptime (client/movement.lua's own elastic pull-back
-- mitigates the worst case down to "has to walk away from a corpse," but
-- that is a mitigation, not a fix). FIXED: this thread now always starts,
-- unconditionally, with no inner flag check at all -- unlike
-- server/combat.lua's K9-position-history thread (which DOES need one, see
-- that thread's own comment for why), this loop iterates ONLY
-- `pairs(LeashPairs)`, never an always-populated collection like
-- GetPlayers(), so an idle/never-used server pays nothing extra for it. So
-- this test now asserts the OPPOSITE of what it once did -- see the
-- LIVE-FLIP FIX test immediately below for the real regression coverage (a
-- pairing formed AFTER a live flip really does get its dead party
-- auto-detached, no restart required).
t.test('DEATH-DETECTION: the death-detection thread is created UNCONDITIONALLY, regardless of Config.Features.LeashMechanics at load time -- gating its START on this flag was the bug, now fixed', function()
    local fOff = newMainFixture({ features = { LeashMechanics = false } })
    local fOn = newMainFixture({ features = { LeashMechanics = true } })
    t.equals(fOff.threadCreateCount(), fOn.threadCreateCount(),
        'LeashMechanics=false must create exactly the SAME number of threads as LeashMechanics=true -- the death-detection thread (like the door-scratch sweep) now starts every time this file loads, never gated on this flag\'s boot-time value')
end)

t.test('LIVE-FLIP FIX: a pairing formed after flipping LeashMechanics on LIVE (booted with the flag off) still gets a dead party auto-detached -- no restart of this resource required', function()
    local f = newMainFixture({ features = { LeashMechanics = false } })
    setupEligiblePair(f, 1, 2)

    -- Boot-time state: request-time gating still denies -- this fix never
    -- widens that check.
    f.dispatchNetEvent('qbx_k9unit:server:requestLeashAttach', 1, 2)
    t.equals(countClientEvents(f, 'qbx_k9unit:client:leashAttachRequest'), 0, 'still denied while the flag is off at boot')
    f.clearCaptures()

    -- Prime the death-detection thread's own first Wait() BEFORE the flag
    -- ever flips -- this is the whole point: the thread genuinely started
    -- while LeashMechanics was still false at boot. The old, buggy gate
    -- would never have created this thread at all in that case.
    f.runOneTick()

    -- High command flips LeashMechanics on LIVE, mid-session -- exactly the
    -- scenario server/runtimecontrol.lua's own FEATURE_TIERS entry for this
    -- flag documents (`tier = 'live'`, `restartRequired = false`).
    f.config.Features.LeashMechanics = true

    formLeashPair(f, 1, 2, 1, true) -- keepCaptures: prove the pairing genuinely formed
    t.equals(countClientEvents(f, 'qbx_k9unit:client:leashAttached'), 2, 'the request-time gate (CheckLeashEligibility) is genuinely live -- a real pairing is formed')
    f.clearCaptures()

    -- THE ACTUAL BUG, pre-fix: the death-detection thread never started (the
    -- flag was false when this fixture's server/main.lua loaded), so nothing
    -- server-authoritative would ever have auto-detached this pairing on
    -- either party's death. Prove the opposite now holds -- the SAME thread
    -- that has been idling over an empty LeashPairs since load time (already
    -- primed above) picks this pairing up and detaches it, with no restart
    -- of this resource in between.
    f.setHealth(10, 50) -- k9Src(1) * 10 == ped handle 10 (setupEligiblePair's own convention), well below the death threshold (100)
    f.runOneTick()

    t.equals(countClientEvents(f, 'qbx_k9unit:client:leashDetached'), 2,
        'a pairing formed after a LIVE flag flip must still be auto-detached when a party dies -- the survivor must never be stranded waiting for a resource restart')
end)

t.test('DEATH-DETECTION: the K9-role party\'s health crossing the death threshold (<=100) ends the pairing as partner_died, broadcast to BOTH parties', function()
    local f = newMainFixture()
    setupEligiblePair(f, 1, 2)
    formLeashPair(f, 1, 2, 1) -- clears captures by default

    f.setHealth(10, 100) -- k9Src(1) * 10 == ped handle 10, per setupEligiblePair -- 100 is the documented boundary, PED_DEAD_HEALTH_THRESHOLD-equivalent
    f.runOneTick() -- primes every captured thread (door-scratch sweep AND the new death poll) -- no real pass yet
    f.runOneTick() -- one real pass over both

    t.equals(countClientEvents(f, 'qbx_k9unit:client:leashDetached'), 2, 'both parties must be told the pairing ended')
    t.isFalse(f.ForceDetachLeashForSource(2), 'LeashPairs must already be fully cleared (both directions) -- a second detach attempt against the OTHER party is a no-op')
end)

t.test('DEATH-DETECTION: the OFFICER-role party dying ALSO ends the pairing (not just the K9-role party)', function()
    local f = newMainFixture()
    setupEligiblePair(f, 1, 2)
    formLeashPair(f, 1, 2, 1)

    f.setHealth(20, 50) -- officerSrc(2) * 10 == ped handle 20, well below the threshold
    f.runOneTick()
    f.runOneTick()

    t.equals(countClientEvents(f, 'qbx_k9unit:client:leashDetached'), 2)
end)

t.test('DEATH-DETECTION: a genuinely alive pairing (health 101, one point above the threshold) is left completely alone', function()
    local f = newMainFixture()
    setupEligiblePair(f, 1, 2)
    formLeashPair(f, 1, 2, 1)

    f.setHealth(10, 101)
    f.runOneTick()
    f.runOneTick()

    t.equals(countClientEvents(f, 'qbx_k9unit:client:leashDetached'), 0)
    t.isTrue(f.ForceDetachLeashForSource(1), 'the pairing must still genuinely exist, untouched')
end)

t.test('DEATH-DETECTION: with no active pairing at all, the thread is a true no-op every tick -- never throws against an empty LeashPairs', function()
    local f = newMainFixture()
    f.setHealth(999, 0) -- an unrelated ped, not party to anything
    local ok = pcall(function()
        f.runOneTick()
        f.runOneTick()
        f.runOneTick()
    end)
    t.isTrue(ok)
    t.equals(#f.clientEvents, 0)
end)

t.test('DEATH-DETECTION: `Config.Combat.PropDragging.IsPlayerDownedOverride`, when configured, is consulted and its TRUE answer ends the pairing even at full (200) raw health', function()
    local f = newMainFixture({ downedOverride = function(_src) return true end })
    setupEligiblePair(f, 1, 2)
    formLeashPair(f, 1, 2, 1)
    -- health is left at the default (200, healthy) -- the override alone must be sufficient
    f.runOneTick()
    f.runOneTick()
    t.equals(countClientEvents(f, 'qbx_k9unit:client:leashDetached'), 2, 'a configured override wins even when every fallback signal says alive')
end)

t.test('DEATH-DETECTION: an `IsPlayerDownedOverride` that ERRORS fails CLOSED (treated as NOT down this tick) -- same posture as every other downed-check in this resource, safe here because this is a REPEATING poll, never a one-shot', function()
    local f = newMainFixture({ downedOverride = function(_src) error('boom') end })
    setupEligiblePair(f, 1, 2)
    formLeashPair(f, 1, 2, 1)
    f.setHealth(10, 100) -- would otherwise be caught by the raw-health floor, but the override -- once configured -- wins UNCONDITIONALLY (see IsLeashPartyDead's own doc comment), even on error
    local ok = pcall(function()
        f.runOneTick()
        f.runOneTick()
    end)
    t.isTrue(ok, 'an override error must never crash the death-detection thread itself')
    t.equals(countClientEvents(f, 'qbx_k9unit:client:leashDetached'), 0, 'a fail-closed "not down" verdict this tick must leave the pairing alone -- it is retried next tick, never a permanent trap')
end)

t.test('DEATH-DETECTION: the K9Compat ambulance adapter is genuinely consulted (not merely configured) when no override is set, and a confirmed TRUE ends the pairing', function()
    local f = newMainFixture({ ambulanceIsDowned = function(_src) return true end })
    setupEligiblePair(f, 1, 2)
    formLeashPair(f, 1, 2, 1)
    -- health left healthy (200) -- the adapter alone must be sufficient, same as the override test above
    f.runOneTick()
    f.runOneTick()
    t.isTrue(#f.ambulanceIsDownedCalls > 0, 'the adapter must actually be called, not just registered')
    t.equals(countClientEvents(f, 'qbx_k9unit:client:leashDetached'), 2)
end)

t.test('DEATH-DETECTION: doDetachLeash is the ONLY mutation path -- proven by re-forming a fresh pairing immediately after a death-triggered detach, with no leftover state from the old one', function()
    local f = newMainFixture()
    setupEligiblePair(f, 1, 2)
    formLeashPair(f, 1, 2, 1)
    f.setHealth(10, 50)
    f.runOneTick()
    f.runOneTick()
    t.equals(countClientEvents(f, 'qbx_k9unit:client:leashDetached'), 2)

    -- The K9 "revives" (health restored) and a BRAND NEW pairing forms with
    -- a different officer -- must succeed cleanly, with no stale
    -- already-leashed state surviving the death-triggered detach.
    -- Clock advanced past LeashRequestCooldown (1000ms, per-INITIATOR,
    -- src=1 initiated the first request above too) -- otherwise this
    -- second request would be refused by that unrelated rate limit, not by
    -- anything this test actually cares about.
    f.advance(1001)
    f.setHealth(10, 200)
    f.clearCaptures()
    setupEligiblePair(f, 1, 3)
    formLeashPair(f, 1, 3, 1, true) -- keepCaptures: this test wants to see the fresh leashAttached broadcast
    t.equals(countClientEvents(f, 'qbx_k9unit:client:leashAttached'), 2, 'a fresh pairing must form normally -- no orphaned LeashPairs entry blocked it')
end)

print('')
print('mainserver_spec.lua coverage summary (112 cases as of the LIVE-FLIP FIX')
print('pass -- this count was already stale (98 claimed, 102')
print('actually ran) before the DEATH-DETECTION FIX pass touched it, a pre-existing')
print('drift left uncorrected beyond what each pass\'s own Section 13 additions')
print('bring -- run this file, do not')
print('grep it, per DEVELOPER_REFERENCE.md §20\'s own "count you must run" note): relayBark')
print('(8) + its own PER-PERSON FEATURE CONTROL section (4: block/no-cooldown-burn,')
print('default-allow, RequireGrant-denied, RequireGrant-granted), relayDoorScratch (11)')
print('+ its own PER-PERSON FEATURE CONTROL section (6: block/no-cooldown-burn,')
print('default-allow, RequireGrant-denied, RequireGrant-granted, missing-HasPermission')
print('fails closed when RequireGrant-listed, missing-HasPermission still allows when')
print('not listed), CheckLeashEligibility\'s 8 reject reasons + happy')
print('path + 3 K9 role/model decoupling widening cases (15), its own PER-PERSON')
print('FEATURE CONTROL section (7: block on either party + no-cooldown-burn,')
print('default-allow, RequireGrant-denied, RequireGrant-granted requiring BOTH')
print('parties, RequireGrant with only one party granted, and detachLeash staying')
print('unconditional for an already-blocked K9), symmetric role')
print('assignment incl. the both-K9 tie-break (3),')
print('request-time pending/rate-limit ordering (4), respondLeashAttach incl.')
print('double-accept/double-decline fail-closed AND the mismatched-fromServerId')
print('FINDING (9), TOCTOU re-validation at accept (4), detach/ForceDetach')
print('role-awareness (7), playerDropped disconnect/id-recycling (5), ephemeral-state')
print('+ onResourceStop FINDING (2), file-load inventory (4), the two onResourceStart')
print('handlers -- cache backfill + config-safety assert, previously registered but')
print('never fired by any spec in this suite (10). See this file\'s own header for')
print('what is deliberately NOT covered and why, Section 7 for the one real,')
print('disclosed production finding this pass caught, Section 12 for the')
print('dangling-TODO-header fix that backfill coverage accompanies, and Section 13')
print('(10 cases) for the DEATH-DETECTION FIX and its own follow-on LIVE-FLIP FIX:')
print('no death handler had ever touched LeashPairs before -- either party dying')
print('mid-leash now ends the pairing via a new background poll thread, reusing')
print('the IsHandlerDown precedence (override -> K9Compat')
print('ambulance adapter -> metadata -> raw health) rather than re-deriving it. That')
print('poll thread now starts UNCONDITIONALLY (LIVE-FLIP FIX, follow-on pass) --')
print('request-time formation (CheckLeashEligibility) still genuinely gates on')
print('Config.Features.LeashMechanics, checked fresh on every call, but the poll')
print('thread itself no longer is, so a pairing formed after flipping the flag on')
print('live is guaranteed a working death watchdog with no restart required.')

os.exit(t.summary())
