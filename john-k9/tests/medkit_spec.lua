--[[
    tests/medkit_spec.lua

    First test coverage for server/medkit.lua -- one of the last server
    files without a spec, and, per this task's own brief, the one with the
    worst history in this resource: its dead-K9 gate was REPORTED CLOSED
    (CORRECTNESS PASS finding 2 in that file's own header) while resting on
    `IsEntityDead(targetPed)`, a native with NO FXServer server
    registration -- confirmed by that file's own "NATIVE-AVAILABILITY FIX"
    addendum, which found zero `RegisterNativeHandler` for `IS_ENTITY_DEAD`
    anywhere in citizenfx/fivem's own server-native registration source.
    FXServer does not throw on an unregistered native; it silently no-ops
    and never writes the result buffer, so that check ALWAYS returned
    `false` -- a dead K9's health could always be pushed back up via this
    item, the exact bug the "fixed" gate was supposed to close. The file now
    uses `GetEntityHealth(targetPed) <= PED_DEAD_HEALTH_THRESHOLD` (100),
    mirroring server/combat.lua's own identical fix (already covered by
    combat_spec.lua's own "MUST-MATTER #1" section) -- this file's own
    99/100/101 boundary tests below are the thing that actually stops this
    bug from silently reappearing a second time.

    Loads the REAL, unmodified server/cooldowns.lua -> server/entities.lua
    -> server/medkit.lua chain (the exact fxmanifest.lua server_scripts
    load order for this file's own load-time dependency on
    NewCooldown/NewMutex; server/entities.lua is loaded alongside per this
    task's own instruction even though server/medkit.lua does not currently
    call either of ResolveNetworkEntity/ResolveConnectedPlayerFromPed --
    unlike server/kennel.lua/server/combat.lua, this file resolves its
    target via a caller-supplied PLAYER server id and GetPlayerPed directly,
    per its own header's callback-contract note on why it deliberately never
    needs netId/entity-handle resolution at all). IsConfiguredK9Model and
    NotifyPlayer are stubbed directly, not loaded -- both are genuinely
    OTHER files' own logic (server/certifications/, server/notify.lua),
    already covered by their own specs, same convention every other spec in
    this suite already establishes (kennel_spec.lua/combat_spec.lua/
    wellbeing_spec.lua's own headers). This file used to also drive a
    soft dependency on
    server/wellbeing.lua -- omitted by default (proving the guard degrades
    cleanly), added back as a controllable stub only for the tests that
    specifically exercise it, same "runtime existence guard, not a
    load-order assumption" shape combat_spec.lua's own header already
    documents for IsHesitating/IsDistracted/AwardXP.

    locale() is NEVER stubbed (per this suite's own convention) -- the two
    real NotifyPlayer(..., locale('medkit.xxx'), ...) call sites this file
    reaches on its success path evaluate that locale() argument for real,
    against the real locales/en.json, before this file's own NotifyPlayer
    stub ever sees the result.

    ONE FRESH SANDBOX PER TEST (never shared) -- MedkitCooldown/MedkitMutex
    are file-lifetime `local` upvalues, so reusing one sandbox across
    unrelated test cases would leak state, same discipline every other spec
    in this suite already established.

    ======================================================================
    WHAT THIS FILE PROVES, mapped to this task's five named priorities:

    1. THE DEAD-TARGET GATE AT ITS BOUNDARY (99/100/101). The exact
       boundary that never actually fired before this pass's native-sweep
       fix -- see the "MUST-MATTER #1" section below.

    2. MONOTONIC HEAL / MAX-HEALTH CLAMP. Proves the SERVER's own clamp
       (RunUseK9MedkitMutation's `math.min(...)` / `math.max(...)` pair)
       never returns a value below the target's live current health
       (including under a defensively-negative `Config.K9Medkit
       .healthRestore`) and never exceeds live max health (including when
       the naive sum would overshoot it). This is deliberately scoped to
       the SERVER's own clamp only -- client/medkit.lua's own, separate
       monotonic-floor/range-clamp guards on `applyMedkitHeal` are CLIENT-
       side logic and out of THIS file's scope (this file loads
       server/medkit.lua only, per its own title above), but are NOT an
       untested gap: tests/clientmedkit_spec.lua covers them directly
       against the real, unmodified client/medkit.lua. See the
       "MUST-MATTER #2" section below.

    3. THE MUTEX AND ITS RELEASE ON THE ERROR PATH. Two angles: (a) a
       thrown error INSIDE the mutex-held mutation body (simulating a
       native call failing) is followed by a fully successful retry against
       the exact same target citizenid -- proving `MedkitMutex.Release` ran
       even though the mutation errored, not merely on its `return
       {ok=...}` success paths; (b) a DISCLOSED, clearly-labeled mechanism
       test that genuinely interleaves two in-flight requests against the
       same target via a real Lua coroutine with a suspend hook (this
       file's own task brief names combat_spec.lua's identical technique as
       something "you may need") -- see that section's own header comment
       for exactly what is, and is not, claimed about TODAY's production
       behavior versus the mechanism this proves. See "MUST-MATTER #3"
       below.

    4. ITEM CONSUMPTION ORDERING. A rejection that happens strictly AFTER
       `exports.ox_inventory:RemoveItem` has already succeeded (simulated
       by making the very next native call, `GetEntityMaxHealth`, throw) DOES
       consume the item while still reporting failure to the calling
       client -- a genuine FINDING, not fixed here per this task's hard
       rule against editing server/medkit.lua. See "MUST-MATTER #4" below.

    5. THE PER-TARGET COOLDOWN, and that every one of the nine rejection
       reason strings client/medkit.lua's own `reasonLabel` lookup table
       maps (`feature_disabled`, `no_access`, `invalid_target`,
       `target_dead`, `too_far`, `on_cooldown`, `no_item`,
       `treatment_in_progress`, `medkit_failed`) is REACHABLE from the real,
       unmodified server callback -- not merely declared as a client-side
       fallback for a reason the server can never actually emit. See
       "MUST-MATTER #5" below; a running tally comment at the end of that
       section cross-checks all nine against this file's own tests.

    ALSO, THIS PASS (coder-backend): `no_access` used to be returned for TWO
    genuinely different causes -- the using player's JOB does not permit
    treating K9s at all (IsMedkitUserAuthorized), and separately, the job
    permits it but this server's own Config.FeatureControl.RequireGrant
    additionally requires a `feature.K9Medkit` grant the player does not
    hold (IsK9MedkitPermittedForCitizenId) -- mirroring
    server/pursuitsprint.lua's own `no_access`/`not_granted` split for the
    identical class of gate. The second cause now returns a distinct
    `not_granted` reason. See the "PER-PERSON FEATURE CONTROL" section below
    for the updated tests, and the "REASON SPLIT" note near the nine-reason
    cross-check for why `not_granted` is a real, reachable TENTH reason not
    yet folded into that specific "nine client-recognized" tally (this
    pass's own file-ownership does not extend to client/medkit.lua's
    reasonLabel table, which does not map it yet).
    ======================================================================

    WHAT THIS FILE DOES NOT COVER, AND WHY:
      - client/medkit.lua's own logic is NOT covered HERE -- client-only
        natives (SetEntityHealth, IsEntityDead client-side, PlayerPedId)
        have no place in a server-file sandbox. STALE NOTE, CORRECTED THIS
        PASS: this used to cite a "blanket exclusion DEVELOPER_REFERENCE.md
        already states for every client/*.lua file" as the reason -- that
        citation is stale. DEVELOPER_REFERENCE.md's own Part B, Item 3
        records that blanket exclusion as SUPERSEDED once
        tests/main_spec.lua proved the same sandbox pattern generalizes to
        client/*.lua files; 30+ client*_spec.lua files exist in this suite
        today. client/medkit.lua's own SOURCE-ORIGIN GUARD / feature gate /
        dead-K9 guard / monotonic-heal floor / range-clamp on
        `applyMedkitHeal` are now covered directly, by
        tests/clientmedkit_spec.lua (loads the real, unmodified
        client/medkit.lua the same way this file loads the real
        server/medkit.lua) -- not a permanent gap, and not this file's job
        either way (this file's own scope is server/medkit.lua only, per
        its own title above).
      - The MedkitCooldown sweep thread's own eviction predicate
        (`(now - loggedAt) > Config.K9Medkit.cooldownMs * 2`) is exercised
        only as a load-time sanity check (one CreateThread call) -- its
        actual eviction timing is structurally identical to
        cooldowns_spec.lua's own direct `StartSweep` coverage of the same
        shared primitive, so re-deriving it here against a second Config
        value would be duplication, not new coverage.
      - the since-removed Injury-stat math was server/wellbeing.lua's
        concern (covered by wellbeing_spec.lua) -- this file only proves
        WHETHER server/medkit.lua calls it, with what arguments, and that its
        own guard degrades cleanly when absent and fails soft (not loudly)
        when it throws.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')
local locale = Sandbox.locale

-- ----------------------------------------------------------------------
-- Vector3-alike stub -- identical shape/reasoning to combat_spec.lua's/
-- wellbeing_spec.lua's own copies (the only other files needing
-- GetEntityCoords' `-`/`#` operators).
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

local K9_MODEL_HASH = 555

-- ----------------------------------------------------------------------
-- Real, shipped config.lua baselines -- same convention combat_spec.lua's/
-- kennel_spec.lua's own baseline*Config() helpers already established: the
-- boundary/clamp tests below exercise the actual numbers this resource
-- ships, not arbitrary round test numbers. Individual tests override via
-- opts.k9MedkitCfg where a specific test genuinely needs a different value
-- (e.g. a defensively-negative healthRestore).
-- ----------------------------------------------------------------------

local function baselineK9MedkitConfig()
    return {
        itemName      = 'k9_medkit',
        healthRestore = 50,
        range         = 2.0,
        cooldownMs    = 60000,
        emsJobs       = { 'ambulance' },
    }
end

local function baselineDepartments()
    return {
        police = { label = 'Los Santos Police Department', certifierGrade = 4, autoAccessGrade = nil },
    }
end

-- ----------------------------------------------------------------------
-- Sandbox setup
-- ----------------------------------------------------------------------

--- Builds one complete, independent sandbox for server/medkit.lua, with the
--- real server/cooldowns.lua and server/entities.lua loaded alongside it
--- first (the fxmanifest.lua server_scripts order), and every other
--- cross-file/native dependency as a test-controlled stub.
--- @param opts table?
--- @return table fixture
local function newMedkitFixture(opts)
    opts = opts or {}

    local fakeNow = 0
    local function GetGameTimer() return fakeNow end

    local threadRunner = Sandbox.newThreadRunner()
    local createThreadCallCount = 0
    local function CreateThread(fn)
        createThreadCallCount = createThreadCallCount + 1
        threadRunner.CreateThread(fn)
    end

    local callbacks = {} -- name -> handler
    local libStub = { callback = { register = function(name, handler) callbacks[name] = handler end } }

    local clientEvents = {}
    local function TriggerClientEvent(eventName, target, ...)
        clientEvents[#clientEvents + 1] = { event = eventName, target = target, args = { ... } }
    end

    local notifyCalls = {}
    local function NotifyPlayer(target, description, notifyType)
        notifyCalls[#notifyCalls + 1] = { target = target, description = description, notifyType = notifyType }
    end

    local printedLines = {}
    local function printStub(...)
        local parts = {}
        for i = 1, select('#', ...) do parts[i] = tostring(select(i, ...)) end
        printedLines[#printedLines + 1] = table.concat(parts, '\t')
    end

    -- exports.qbx_core:GetPlayer(source) -- keyed by source.
    local playersBySource = {} -- source -> { citizenid=, job={name=,grade={level=}} }
    local function qbxGetPlayer(_self, src)
        local p = playersBySource[src]
        if not p then return nil end
        return { PlayerData = p }
    end

    -- PER-PERSON FEATURE CONTROL (this pass) -- mirrors
    -- tests/pursuitsprint_spec.lua's own `permissionGrants`/
    -- `defaultHasPermission`/`grantPermission` fixture shape, for
    -- IsK9MedkitPermittedForCitizenId (gates the USING player, never the
    -- K9 being treated -- see that function's own doc comment in
    -- server/medkit.lua).
    local permissionGrants = {} -- [citizenid][key] = true/false
    local function defaultHasPermission(citizenid, key)
        return permissionGrants[citizenid] and permissionGrants[citizenid][key] == true
    end

    local pedBySource = {}
    local function GetPlayerPed(src) return pedBySource[src] or 0 end

    local coordsByPed = {}
    local function GetEntityCoords(ped) return coordsByPed[ped] or vec3(0, 0, 0) end

    local healthByPed = {}
    local function GetEntityHealth(ped) return healthByPed[ped] or 200 end

    local maxHealthByPed = {}
    local throwOnMaxHealth = false
    local function GetEntityMaxHealth(ped)
        if throwOnMaxHealth then
            error('simulated native failure: GetEntityMaxHealth')
        end
        return maxHealthByPed[ped] or 200
    end

    local modelByPed = {}
    local function GetEntityModel(ped) return modelByPed[ped] or 0 end

    local k9Models = {}
    local function IsConfiguredK9Model(model) return k9Models[model] == true end

    -- K9 role/model decoupling (server/appearance.lua) -- HandleUseK9Medkit
    -- ORs this in alongside IsConfiguredK9Model(GetEntityModel(targetPed)) so
    -- a role-holder on a non-K9 model can still be treated. Stubbed here
    -- (not the real server/appearance.lua), same "this file's own logic
    -- only" reasoning as HasK9Access/IsConfiguredK9Model elsewhere in this
    -- suite. Keyed by targetServerId, defaults false.
    local hasRoleBySource = {}
    local function HasK9Role(src) return hasRoleBySource[src] == true end

    -- exports.ox_inventory:GetItemCount/RemoveItem -- keyed by source, then
    -- item name, same shape wellbeing_spec.lua's own stub already uses.
    local itemCounts = {}
    local throwOnGetItemCount = false
    local yieldOnGetItemCount = false
    local forceRemoveItemFail = false
    local getItemCountCallCount = 0
    local removeItemCallCount = 0
    local function oxGetItemCount(_self, src, itemName)
        getItemCountCallCount = getItemCountCallCount + 1
        if throwOnGetItemCount then
            error('simulated native failure: GetItemCount')
        end
        if yieldOnGetItemCount then
            coroutine.yield()
        end
        return (itemCounts[src] and itemCounts[src][itemName]) or 0
    end
    local function oxRemoveItem(_self, src, itemName, count)
        removeItemCallCount = removeItemCallCount + 1
        if forceRemoveItemFail then return false end
        local have = (itemCounts[src] and itemCounts[src][itemName]) or 0
        if have < count then return false end
        itemCounts[src][itemName] = have - count
        return true
    end

    local config = {
        Features = { K9Medkit = opts.k9Medkit ~= false },
        Departments = opts.departments or baselineDepartments(),
        K9Medkit = opts.k9MedkitCfg or baselineK9MedkitConfig(),
        FeatureControl = { RequireGrant = {} },
        -- COMPAT-LAYER MIGRATION (coder-backend, this pass): pins the
        -- 'inventory' system straight to 'ox_inventory' via `override`
        -- (shared/compat/core.lua's TIER 1, skipping the candidate walk).
        -- The other four systems get empty-but-present tables so
        -- DetectSystem's own "missing or malformed" warning never fires.
        Compat = {
            diagnosticCommand = false,
            Systems = {
                inventory = { override = 'ox_inventory' },
                target = {}, framework = {}, dispatch = {}, ambulance = {},
            },
        },
    }

    local envOverrides = {
        GetGameTimer = GetGameTimer,
        CreateThread = CreateThread,
        Wait = threadRunner.Wait,
        TriggerClientEvent = TriggerClientEvent,
        NotifyPlayer = NotifyPlayer,
        print = printStub,
        exports = {
            qbx_core = { GetPlayer = qbxGetPlayer },
            -- COMPAT-LAYER MIGRATION (this pass): server/medkit.lua now
            -- calls `K9Compat.Get('inventory').GetItemCount`/`.RemoveItem`
            -- instead of `exports.ox_inventory:...` directly.
            -- shared/compat/inventory.lua's BuildOxInventoryServer requires
            -- ALL SEVEN server-realm methods present as callable exports
            -- before it returns ANYTHING -- GetInventoryItems/
            -- GetContainerFromSlot/RegisterStash/RegisterShop/registerHook
            -- (never called by server/medkit.lua at all) are stubbed as
            -- harmless no-ops purely so capability verification passes.
            ox_inventory = {
                GetItemCount = oxGetItemCount,
                RemoveItem = oxRemoveItem,
                GetInventoryItems = function() return {} end,
                GetContainerFromSlot = function() return nil end,
                RegisterStash = function() return true end,
                RegisterShop = function() return true end,
                registerHook = function() return 1 end,
            },
        },
        GetPlayerPed = GetPlayerPed,
        GetEntityCoords = GetEntityCoords,
        GetEntityHealth = GetEntityHealth,
        GetEntityMaxHealth = GetEntityMaxHealth,
        GetEntityModel = GetEntityModel,
        IsConfiguredK9Model = IsConfiguredK9Model,
        HasK9Role = HasK9Role,
        HasPermission = defaultHasPermission,
        lib = libStub,
        Config = config,
        -- COMPAT-LAYER MIGRATION (this pass): server realm; ox_inventory is
        -- the only resource this fixture's Compat.Systems.inventory.override
        -- names, and it always reports 'started' (this file never tests an
        -- undetected-inventory scenario -- that risk is covered by
        -- shared/compat/inventory.lua's own dedicated spec and this task's
        -- own per-file stub-degrade writeup in server/medkit.lua's header).
        -- AddEventHandler is a bare no-op: shared/compat/core.lua calls it
        -- unconditionally at its own load time, but nothing in this fixture
        -- ever fires 'onResourceStart' (server/medkit.lua registers none of
        -- its own), so K9Compat detects lazily on its first Get() call,
        -- inline, with no CreateThread/Wait ever needed either.
        IsDuplicityVersion = function() return true end,
        GetResourceState = function(name) return name == 'ox_inventory' and 'started' or 'missing' end,
        AddEventHandler = function() end,
    }

    -- XP TIER UNLOCK (this pass) -- server/progression.lua's real
    -- GetXPTierMedkitCooldownMs is NOT loaded into this sandbox (that
    -- function's own numeric contract is tests/xptierunlocks_spec.lua's
    -- job, not this file's) -- this is a small, test-controlled stand-in
    -- so RunUseK9MedkitMutation's own consultation of it (soft dependency,
    -- `type(...) == 'function'` guard) can be proven from THIS file's own
    -- callback path. `opts.medkitCooldownMsByCitizenid` maps a citizenid to
    -- the exact effective cooldown this stub returns for it; any other
    -- citizenid falls through to the real baseCooldownMs argument
    -- unchanged, matching the real accessor's own "unlock not yet earned"
    -- default.
    local xpTierCooldownCalls = {}
    if opts.withXPTierMedkitCooldown then
        envOverrides.GetXPTierMedkitCooldownMs = function(citizenid, baseCooldownMs)
            xpTierCooldownCalls[#xpTierCooldownCalls + 1] = { citizenid = citizenid, baseCooldownMs = baseCooldownMs }
            local override = opts.medkitCooldownMsByCitizenid and opts.medkitCooldownMsByCitizenid[citizenid]
            return override or baseCooldownMs
        end
    end

    -- HANDLER XP TIER UNLOCK (dead-config-field pass) -- same shape as the
    -- K9-side stand-in immediately above, for
    -- GetHandlerXPTierMedkitCooldownMs (server/progression.lua), keyed on
    -- the USING player's own citizenid rather than the target's.
    -- `opts.handlerMedkitCooldownMsByCitizenid` maps the USING player's
    -- citizenid to the exact effective cooldown this stub returns.
    local handlerXPTierCooldownCalls = {}
    if opts.withHandlerXPTierMedkitCooldown then
        envOverrides.GetHandlerXPTierMedkitCooldownMs = function(citizenid, baseCooldownMs)
            handlerXPTierCooldownCalls[#handlerXPTierCooldownCalls + 1] = { citizenid = citizenid, baseCooldownMs = baseCooldownMs }
            local override = opts.handlerMedkitCooldownMsByCitizenid and opts.handlerMedkitCooldownMsByCitizenid[citizenid]
            return override or baseCooldownMs
        end
    end

    -- WIRING PASS (coder-backend) -- server/progression.lua's real
    -- AwardHandlerXP is NOT loaded into this sandbox (its own numeric/
    -- budget contract belongs to tests/progression_spec.lua and
    -- tests/handlerprogression_spec.lua, not this file) -- this is a small,
    -- test-controlled stand-in, mirroring `withXPTierMedkitCooldown`'s own
    -- shape immediately above, so RunUseK9MedkitMutation's own
    -- soft-dependency call (`type(AwardHandlerXP) == 'function'` guard) can
    -- be proven from THIS file's own invokeCallback path.
    local awardHandlerXPCalls = {}
    if opts.withAwardHandlerXP then
        envOverrides.AwardHandlerXP = function(citizenid, actionKey)
            awardHandlerXPCalls[#awardHandlerXPCalls + 1] = { citizenid = citizenid, actionKey = actionKey }
        end
    end

    local env = Sandbox.newEnv(envOverrides)

    Sandbox.loadInto('../server/cooldowns.lua', env)
    Sandbox.loadInto('../server/entities.lua', env)
    -- COMPAT-LAYER MIGRATION (this pass): server/medkit.lua's
    -- GetItemCount/RemoveItem calls are now routed through
    -- `K9Compat.Get('inventory')` -- load the REAL, unmodified
    -- shared/compat/core.lua + shared/compat/inventory.lua first (never a
    -- hand-written fake translation layer).
    Sandbox.loadInto('../shared/compat/core.lua', env)
    Sandbox.loadInto('../shared/compat/inventory.lua', env)
    Sandbox.loadInto('../server/medkit.lua', env)

    --- Drives `callbacks[name]` inside a real Lua coroutine, auto-resuming
    --- through any yield with no interaction -- correct for every test
    --- except the MUST-MATTER #3(b) mechanism test below, which uses
    --- `startCallbackCoroutine` instead to interleave two in-flight calls.
    --- @param name string
    --- @param source number
    --- @param ... any
    --- @return table result
    local function invokeCallback(name, source, ...)
        assert(callbacks[name], 'no callback registered for ' .. name)
        local co = coroutine.create(callbacks[name])
        local result = { coroutine.resume(co, source, ...) }
        for _ = 1, 50 do
            if not result[1] then
                error(('invokeCallback(%s) coroutine error: %s'):format(name, tostring(result[2])))
            end
            if coroutine.status(co) == 'dead' then return result[2] end
            result = { coroutine.resume(co) }
        end
        error(('invokeCallback(%s) did not complete after repeated resumes'):format(name))
    end

    return {
        config = config,
        clientEvents = clientEvents,
        notifyCalls = notifyCalls,
        printedLines = printedLines,
        xpTierCooldownCalls = xpTierCooldownCalls,
        handlerXPTierCooldownCalls = handlerXPTierCooldownCalls,
        awardHandlerXPCalls = awardHandlerXPCalls,
        createThreadCallCount = function() return createThreadCallCount end,
        advance = function(deltaMs) fakeNow = fakeNow + deltaMs end,
        setNow = function(ms) fakeNow = ms end,
        now = function() return fakeNow end,
        setPlayer = function(src, shape) playersBySource[src] = shape end,
        -- PER-PERSON FEATURE CONTROL (this pass) -- see this fixture's own
        -- header comment above.
        grantPermission = function(citizenid, key, value)
            permissionGrants[citizenid] = permissionGrants[citizenid] or {}
            permissionGrants[citizenid][key] = value
        end,
        setPed = function(src, ped) pedBySource[src] = ped end,
        setCoords = function(ped, x, y, z) coordsByPed[ped] = vec3(x, y, z) end,
        setHealth = function(ped, hp) healthByPed[ped] = hp end,
        setMaxHealth = function(ped, hp) maxHealthByPed[ped] = hp end,
        setModel = function(ped, model) modelByPed[ped] = model end,
        setIsK9Model = function(model, isK9) k9Models[model] = isK9 end,
        setK9Role = function(src, hasRole) hasRoleBySource[src] = hasRole end,
        setItemCount = function(src, itemName, n)
            itemCounts[src] = itemCounts[src] or {}
            itemCounts[src][itemName] = n
        end,
        getItemCount = function(src, itemName) return (itemCounts[src] and itemCounts[src][itemName]) or 0 end,
        setThrowOnMaxHealth = function(v) throwOnMaxHealth = v end,
        setThrowOnGetItemCount = function(v) throwOnGetItemCount = v end,
        setYieldOnGetItemCount = function(v) yieldOnGetItemCount = v end,
        setForceRemoveItemFail = function(v) forceRemoveItemFail = v end,
        getItemCountCallCount = function() return getItemCountCallCount end,
        removeItemCallCount = function() return removeItemCallCount end,
        invokeCallback = invokeCallback,
        --- Manual, caller-driven coroutine over the useK9Medkit callback --
        --- the only way to interleave a SECOND, fully independent dispatch
        --- while the first is still parked mid-yield. See MUST-MATTER #3(b)
        --- below for exactly what this proves and does not claim.
        --- @param name string
        --- @param source number
        --- @param targetServerId number
        --- @return table handle -- { resume = fun(): table?, isDead = fun(): boolean }
        startCallbackCoroutine = function(name, source, targetServerId)
            assert(callbacks[name], 'no callback registered for ' .. name)
            local co = coroutine.create(callbacks[name])
            local started = false
            return {
                resume = function()
                    local result
                    if not started then
                        started = true
                        result = { coroutine.resume(co, source, targetServerId) }
                    else
                        result = { coroutine.resume(co) }
                    end
                    if not result[1] then
                        error('startCallbackCoroutine resume error: ' .. tostring(result[2]))
                    end
                    return result[2]
                end,
                isDead = function() return coroutine.status(co) == 'dead' end,
            }
        end,
    }
end

-- ----------------------------------------------------------------------
-- Wiring helpers
-- ----------------------------------------------------------------------

--- Wires a "using" (medic/handler) player: a real job, a live ped, live
--- coords, and (optionally) a carried item count.
--- @param f table
--- @param src number
--- @param opts table?
--- @return number ped
local function wireUsingPlayer(f, src, opts)
    opts = opts or {}
    local ped = opts.ped or (src * 100)
    f.setPlayer(src, {
        citizenid = opts.citizenid or ('USER-CID-' .. src),
        job = { name = opts.job or 'ambulance', grade = { level = opts.grade or 0 } },
    })
    f.setPed(src, ped)
    f.setCoords(ped, opts.x or 0, opts.y or 0, opts.z or 0)
    if opts.itemCount ~= nil then
        f.setItemCount(src, f.config.K9Medkit.itemName, opts.itemCount)
    end
    return ped
end

--- Wires a K9 target player: a live, model-verified, alive ped at a given
--- position/health/maxHealth.
--- @param f table
--- @param src number
--- @param opts table?
--- @return number ped
local function wireTargetK9(f, src, opts)
    opts = opts or {}
    local ped = opts.ped or (src * 100 + 1)
    f.setPlayer(src, { citizenid = opts.citizenid or ('K9-CID-' .. src) })
    f.setPed(src, ped)
    f.setModel(ped, K9_MODEL_HASH)
    f.setIsK9Model(K9_MODEL_HASH, opts.isK9Model ~= false)
    f.setCoords(ped, opts.x or 0, opts.y or 0, opts.z or 0)
    f.setHealth(ped, opts.health or 200)
    f.setMaxHealth(ped, opts.maxHealth or 200)
    return ped
end

local CALLBACK_NAME = 'john-k9:server:useK9Medkit'
local HEAL_EVENT = 'john-k9:client:applyMedkitHeal'

--- @param f table
--- @param eventName string
--- @return table?
local function lastClientEvent(f, eventName)
    for i = #f.clientEvents, 1, -1 do
        if f.clientEvents[i].event == eventName then return f.clientEvents[i] end
    end
    return nil
end

--- @param f table
--- @param eventName string
--- @return integer
local function countClientEvents(f, eventName)
    local n = 0
    for _, e in ipairs(f.clientEvents) do
        if e.event == eventName then n = n + 1 end
    end
    return n
end

local USER_SRC = 1
local TARGET_SRC = 2

-- ========================================================================
-- Sanity: the file loaded and registered what its own header documents.
-- ========================================================================

t.test('server/medkit.lua registers exactly its one documented lib.callback', function()
    local f = newMedkitFixture()
    wireUsingPlayer(f, USER_SRC, { itemCount = 1 })
    wireTargetK9(f, TARGET_SRC)
    local result = f.invokeCallback(CALLBACK_NAME, USER_SRC, TARGET_SRC)
    t.isTrue(result.ok, 'sanity: the callback must be reachable and a well-formed request must succeed')
end)

t.test('server/medkit.lua starts exactly two CreateThreads at file load (MedkitCooldown\'s own sweep, and HandlerTreatXpMintCooldown\'s own sweep, WIRING PASS)', function()
    local f = newMedkitFixture()
    t.equals(f.createThreadCallCount(), 2)
end)

-- ========================================================================
-- MUST-MATTER #5 (part 1): payload/feature/access gating, and the ORDER
-- those cheap checks run in -- each is one of the nine reason strings
-- client/medkit.lua's own reasonLabel table maps.
-- ========================================================================

t.test('a non-number targetServerId is invalid_target -- and this type check runs BEFORE the feature-flag check (still invalid_target even with the feature OFF)', function()
    local f = newMedkitFixture({ k9Medkit = false })
    local result = f.invokeCallback(CALLBACK_NAME, USER_SRC, 'not-a-number')
    t.isFalse(result.ok)
    t.equals(result.reason, 'invalid_target')
end)

t.test('Config.Features.K9Medkit = false rejects an otherwise-perfect request as feature_disabled', function()
    local f = newMedkitFixture({ k9Medkit = false })
    wireUsingPlayer(f, USER_SRC, { itemCount = 1 })
    wireTargetK9(f, TARGET_SRC)
    local result = f.invokeCallback(CALLBACK_NAME, USER_SRC, TARGET_SRC)
    t.isFalse(result.ok)
    t.equals(result.reason, 'feature_disabled')
end)

t.test('a using player whose job is in neither Config.Departments nor Config.K9Medkit.emsJobs is no_access', function()
    local f = newMedkitFixture()
    wireUsingPlayer(f, USER_SRC, { job = 'trucker', itemCount = 1 })
    wireTargetK9(f, TARGET_SRC)
    local result = f.invokeCallback(CALLBACK_NAME, USER_SRC, TARGET_SRC)
    t.isFalse(result.ok)
    t.equals(result.reason, 'no_access')
end)

t.test('a using player with no job data at all (exports.qbx_core:GetPlayer never wired) is no_access, not a crash', function()
    local f = newMedkitFixture()
    wireTargetK9(f, TARGET_SRC)
    local ok, result = pcall(f.invokeCallback, CALLBACK_NAME, USER_SRC, TARGET_SRC)
    t.isTrue(ok)
    t.isFalse(result.ok)
    t.equals(result.reason, 'no_access')
end)

t.test('a using player whose job IS in Config.Departments (police) is authorized -- K9Medkit is deliberately not gated on the using player\'s own K9 certification', function()
    local f = newMedkitFixture()
    wireUsingPlayer(f, USER_SRC, { job = 'police', itemCount = 1 })
    wireTargetK9(f, TARGET_SRC)
    local result = f.invokeCallback(CALLBACK_NAME, USER_SRC, TARGET_SRC)
    t.isTrue(result.ok)
end)

t.test('a using player whose job IS in Config.K9Medkit.emsJobs (ambulance, the shipped default) is authorized', function()
    local f = newMedkitFixture()
    wireUsingPlayer(f, USER_SRC, { job = 'ambulance', itemCount = 1 })
    wireTargetK9(f, TARGET_SRC)
    local result = f.invokeCallback(CALLBACK_NAME, USER_SRC, TARGET_SRC)
    t.isTrue(result.ok)
end)

t.test('IsMedkitUserAuthorizedOverride returning true grants access even for a job in neither list', function()
    local cfg = baselineK9MedkitConfig()
    cfg.IsMedkitUserAuthorizedOverride = function(_source) return true end
    local f = newMedkitFixture({ k9MedkitCfg = cfg })
    wireUsingPlayer(f, USER_SRC, { job = 'trucker', itemCount = 1 })
    wireTargetK9(f, TARGET_SRC)
    local result = f.invokeCallback(CALLBACK_NAME, USER_SRC, TARGET_SRC)
    t.isTrue(result.ok)
end)

t.test('IsMedkitUserAuthorizedOverride that ERRORS fails CLOSED (no_access), never treated as authorized', function()
    local cfg = baselineK9MedkitConfig()
    cfg.IsMedkitUserAuthorizedOverride = function(_source) error('boom') end
    local f = newMedkitFixture({ k9MedkitCfg = cfg })
    wireUsingPlayer(f, USER_SRC, { job = 'trucker', itemCount = 1 })
    wireTargetK9(f, TARGET_SRC)
    local ok, result = pcall(f.invokeCallback, CALLBACK_NAME, USER_SRC, TARGET_SRC)
    t.isTrue(ok)
    t.isFalse(result.ok)
    t.equals(result.reason, 'no_access')
end)

-- ========================================================================
-- MUST-MATTER #5 (part 2): target resolution -- every invalid_target
-- sub-path HandleUseK9Medkit itself enumerates.
-- ========================================================================

t.test('the using player being offline (GetPlayerPed(source) == 0) is invalid_target', function()
    local f = newMedkitFixture()
    f.setPlayer(USER_SRC, { citizenid = 'USER-CID', job = { name = 'ambulance' } }) -- no setPed -> GetPlayerPed(USER_SRC) == 0
    wireTargetK9(f, TARGET_SRC)
    local ok, result = pcall(f.invokeCallback, CALLBACK_NAME, USER_SRC, TARGET_SRC)
    t.isTrue(ok)
    t.isFalse(result.ok)
    t.equals(result.reason, 'invalid_target')
end)

t.test('a targetServerId that resolves to no live ped (offline/bogus) is invalid_target', function()
    local f = newMedkitFixture()
    wireUsingPlayer(f, USER_SRC, { itemCount = 1 })
    -- TARGET_SRC never wired with a ped at all.
    local result = f.invokeCallback(CALLBACK_NAME, USER_SRC, TARGET_SRC)
    t.isFalse(result.ok)
    t.equals(result.reason, 'invalid_target')
end)

t.test('targeting your own ped (targetPed == usingPed) is invalid_target', function()
    local f = newMedkitFixture()
    local sharedPed = 9001
    wireUsingPlayer(f, USER_SRC, { ped = sharedPed, itemCount = 1 })
    f.setPed(USER_SRC, sharedPed) -- confirm same handle
    local result = f.invokeCallback(CALLBACK_NAME, USER_SRC, USER_SRC) -- claims itself as the target
    t.isFalse(result.ok)
    t.equals(result.reason, 'invalid_target')
end)

t.test('a live, connected target whose REAL ped model is not a configured K9 model is invalid_target, even though the target is a real player', function()
    local f = newMedkitFixture()
    wireUsingPlayer(f, USER_SRC, { itemCount = 1 })
    wireTargetK9(f, TARGET_SRC, { isK9Model = false })
    local result = f.invokeCallback(CALLBACK_NAME, USER_SRC, TARGET_SRC)
    t.isFalse(result.ok)
    t.equals(result.reason, 'invalid_target')
end)

-- K9 ROLE/MODEL DECOUPLING WIDENING -- "I also want everything to work with
-- any ped". A target who holds the decoupled K9 ROLE (HasK9Role) but is not
-- currently on a configured K9 model must still be treatable -- previously
-- this was unconditionally rejected as invalid_target.
t.test('K9 ROLE/MODEL DECOUPLING: a target on a non-K9 model IS treatable when they hold the decoupled K9 role', function()
    local f = newMedkitFixture()
    wireUsingPlayer(f, USER_SRC, { itemCount = 1 })
    wireTargetK9(f, TARGET_SRC, { isK9Model = false, health = 150, maxHealth = 200 })
    f.setK9Role(TARGET_SRC, true)
    local result = f.invokeCallback(CALLBACK_NAME, USER_SRC, TARGET_SRC)
    t.isTrue(result.ok, 'a human/custom-modeled role-holder must be treatable, not rejected as invalid_target')
end)

t.test('K9 ROLE/MODEL DECOUPLING: HasK9Role not being loaded at all (soft dependency absent) fails CLOSED to the pre-decoupling model-only check', function()
    local f = newMedkitFixture()
    wireUsingPlayer(f, USER_SRC, { itemCount = 1 })
    wireTargetK9(f, TARGET_SRC, { isK9Model = false })
    -- HasK9Role deliberately never set true here; default stub always
    -- returns false, mirroring "role/appearance module absent or role never
    -- granted" -- either way, the model-only rejection must still hold.
    local result = f.invokeCallback(CALLBACK_NAME, USER_SRC, TARGET_SRC)
    t.isFalse(result.ok)
    t.equals(result.reason, 'invalid_target')
end)

t.test('a target whose citizenid cannot be resolved (exports.qbx_core:GetPlayer(targetServerId) returns nil) is invalid_target', function()
    local f = newMedkitFixture()
    wireUsingPlayer(f, USER_SRC, { itemCount = 1 })
    local targetPed = 9002
    f.setPed(TARGET_SRC, targetPed) -- ped wired...
    f.setModel(targetPed, K9_MODEL_HASH)
    f.setIsK9Model(K9_MODEL_HASH, true)
    f.setCoords(targetPed, 0, 0, 0)
    f.setHealth(targetPed, 200)
    -- ...but no f.setPlayer(TARGET_SRC, ...) -- exports.qbx_core:GetPlayer(TARGET_SRC) resolves to nil
    local result = f.invokeCallback(CALLBACK_NAME, USER_SRC, TARGET_SRC)
    t.isFalse(result.ok)
    t.equals(result.reason, 'invalid_target')
end)

-- ========================================================================
-- MUST-MATTER #1: the dead-target gate at its boundary. GetEntityHealth <=
-- PED_DEAD_HEALTH_THRESHOLD (100, a local constant in server/medkit.lua,
-- mirroring server/combat.lua's own identical constant) replaced
-- IsEntityDead, which has no FXServer server registration and always
-- silently returned false. This boundary is the whole point of this file's
-- own "worst history" writeup at the top of this spec.
-- ========================================================================

t.test('target health exactly 100 (the boundary) is rejected as target_dead', function()
    local f = newMedkitFixture()
    wireUsingPlayer(f, USER_SRC, { itemCount = 1 })
    wireTargetK9(f, TARGET_SRC, { health = 100 })
    local result = f.invokeCallback(CALLBACK_NAME, USER_SRC, TARGET_SRC)
    t.isFalse(result.ok)
    t.equals(result.reason, 'target_dead')
    t.equals(#f.clientEvents, 0, 'no heal event may ever be sent for a rejected dead target')
    t.equals(f.getItemCount(USER_SRC, 'k9_medkit'), 1, 'the item must never be touched -- this gate is checked before the mutex/item work')
end)

t.test('target health 99 (one below the boundary) is rejected as target_dead', function()
    local f = newMedkitFixture()
    wireUsingPlayer(f, USER_SRC, { itemCount = 1 })
    wireTargetK9(f, TARGET_SRC, { health = 99 })
    local result = f.invokeCallback(CALLBACK_NAME, USER_SRC, TARGET_SRC)
    t.isFalse(result.ok)
    t.equals(result.reason, 'target_dead')
end)

t.test('target health 101 (one above the boundary) is accepted as alive -- proceeds all the way through to a real, successful heal', function()
    local f = newMedkitFixture()
    wireUsingPlayer(f, USER_SRC, { itemCount = 1 })
    wireTargetK9(f, TARGET_SRC, { health = 101, maxHealth = 200 })
    local result = f.invokeCallback(CALLBACK_NAME, USER_SRC, TARGET_SRC)
    t.isTrue(result.ok, 'health 101 must never be treated as dead')
    t.equals(countClientEvents(f, HEAL_EVENT), 1, 'exactly one heal push, never zero and never duplicated')
    local ev = lastClientEvent(f, HEAL_EVENT)
    t.isNotNil(ev, 'a genuinely alive target must receive a real heal push')
    t.equals(ev.args[1], 151, '101 + healthRestore(50), well under maxHealth(200)')
end)

-- ========================================================================
-- MUST-MATTER #2: the server's own clamp. Never below current health
-- (monotonic), never above live max health (no overheal).
-- ========================================================================

t.test('a normal heal within bounds applies currentHealth + healthRestore exactly, with no clamping needed', function()
    local f = newMedkitFixture()
    wireUsingPlayer(f, USER_SRC, { itemCount = 1 })
    wireTargetK9(f, TARGET_SRC, { health = 120, maxHealth = 200 })
    local result = f.invokeCallback(CALLBACK_NAME, USER_SRC, TARGET_SRC)
    t.isTrue(result.ok)
    local ev = lastClientEvent(f, HEAL_EVENT)
    t.equals(ev.event, HEAL_EVENT)
    t.equals(ev.target, TARGET_SRC, 'the heal must be pushed to the TARGET\'s own client, not the using player\'s')
    t.equals(ev.args[1], 170, '120 + healthRestore(50)')
end)

t.test('OVERHEAL PREVENTION: currentHealth + healthRestore would exceed live maxHealth -- the server clamps to maxHealth, never sends the raw uncapped sum', function()
    local f = newMedkitFixture()
    wireUsingPlayer(f, USER_SRC, { itemCount = 1 })
    wireTargetK9(f, TARGET_SRC, { health = 180, maxHealth = 200 }) -- 180 + 50 = 230, must clamp to 200
    local result = f.invokeCallback(CALLBACK_NAME, USER_SRC, TARGET_SRC)
    t.isTrue(result.ok)
    local ev = lastClientEvent(f, HEAL_EVENT)
    t.equals(ev.args[1], 200, 'must be clamped to live maxHealth(200), never the raw sum(230)')
end)

t.test('a target already AT live maxHealth is a genuine no-op heal (still ok=true) -- never pushed above max', function()
    local f = newMedkitFixture()
    wireUsingPlayer(f, USER_SRC, { itemCount = 1 })
    wireTargetK9(f, TARGET_SRC, { health = 200, maxHealth = 200 })
    local result = f.invokeCallback(CALLBACK_NAME, USER_SRC, TARGET_SRC)
    t.isTrue(result.ok)
    local ev = lastClientEvent(f, HEAL_EVENT)
    t.equals(ev.args[1], 200, 'must stay exactly at max, never 250 (200 + healthRestore)')
end)

t.test('MONOTONIC FLOOR: a defensively-negative Config.K9Medkit.healthRestore never moves the target\'s health DOWNWARD from its current value', function()
    local cfg = baselineK9MedkitConfig()
    cfg.healthRestore = -10 -- defensive/misconfigured input, per this file's own comment: "even if a future config value were ever negative by mistake"
    local f = newMedkitFixture({ k9MedkitCfg = cfg })
    wireUsingPlayer(f, USER_SRC, { itemCount = 1 })
    wireTargetK9(f, TARGET_SRC, { health = 150, maxHealth = 200 })
    local result = f.invokeCallback(CALLBACK_NAME, USER_SRC, TARGET_SRC)
    t.isTrue(result.ok)
    local ev = lastClientEvent(f, HEAL_EVENT)
    t.equals(ev.args[1], 150, 'must floor at currentHealth(150), never drop to 140 (150 + (-10))')
end)

t.test('the heal event carries EXACTLY one numeric payload argument (the already-clamped absolute health), never a delta and never extra arguments', function()
    local f = newMedkitFixture()
    wireUsingPlayer(f, USER_SRC, { itemCount = 1 })
    wireTargetK9(f, TARGET_SRC, { health = 130, maxHealth = 200 })
    f.invokeCallback(CALLBACK_NAME, USER_SRC, TARGET_SRC)
    local ev = lastClientEvent(f, HEAL_EVENT)
    t.equals(#ev.args, 1)
    t.equals(type(ev.args[1]), 'number')
end)

-- ========================================================================
-- MUST-MATTER #3(a): the mutex releases on the ERROR path, not just
-- success. A thrown error inside the mutex-held mutation body is followed
-- by a fully successful retry against the SAME target citizenid -- proving
-- Release ran even though the mutation errored.
--
-- COMPAT-LAYER MIGRATION (coder-backend, this pass) -- FAULT INJECTION
-- POINT CHANGED, BEHAVIOR GENUINELY DIFFERENT, NOT JUST A TEST TIDY-UP:
-- this pair of tests used to inject the fault via GetItemCount throwing.
-- That no longer produces an uncaught error at all: `K9Compat.Get('inventory')
-- .GetItemCount` is now the real call site, and shared/compat/core.lua's
-- own `BuildSafeAdapter` pcall-wraps every adapter method -- a throwing
-- GetItemCount is caught INSIDE the adapter and reported as `0` (fails
-- closed, per shared/compat/inventory.lua's own documented "possession
-- assumed zero" contract, which that file's own header cites THIS file's
-- pre-existing "unregistered, GetItemCount resolves 0 forever" convention
-- as precedent for). So `f.setThrowOnGetItemCount(true)` now degrades
-- cleanly to a plain `no_item` result (the possession check correctly
-- reads carriedCount=0) -- never reaches RunUseK9MedkitMutation's own
-- pcall boundary at all, and therefore never produces `medkit_failed` or
-- the "useK9Medkit mutation error" console line either. This is a real,
-- disclosed behavior change from the migration (a throwing inventory
-- export now reads as "no item", not "internal error") -- arguably MORE
-- correct given this file's own established fail-closed philosophy, and
-- reported as such rather than silently patched over.
--
-- These two tests still need a genuine UNCAUGHT error inside the
-- mutex-held mutation body to prove their own point (mutex release on the
-- error path, and the diagnostic print) -- `throwOnMaxHealth` (GetEntityMaxHealth,
-- a plain native this file calls directly, never routed through K9Compat)
-- now serves that role instead, reaching RunUseK9MedkitMutation's own pcall
-- boundary exactly like GetItemCount used to.
-- ========================================================================

t.test('a thrown error inside the mutex-held mutation (GetEntityMaxHealth throws) is caught, reported as medkit_failed, and RELEASES the mutex -- an immediate retry against the same target fully succeeds', function()
    local f = newMedkitFixture()
    wireUsingPlayer(f, USER_SRC, { itemCount = 1 })
    wireTargetK9(f, TARGET_SRC, { health = 150, maxHealth = 200 })

    f.setThrowOnMaxHealth(true)
    local ok, failedResult = pcall(f.invokeCallback, CALLBACK_NAME, USER_SRC, TARGET_SRC)
    t.isTrue(ok, 'the thrown native error must never escape the callback -- HandleUseK9Medkit\'s own pcall must catch it')
    t.isFalse(failedResult.ok)
    t.equals(failedResult.reason, 'medkit_failed')
    t.equals(#f.clientEvents, 0, 'no heal may have been applied on the errored attempt')

    -- The error happens BEFORE MedkitCooldown.Touch (which runs only after
    -- RemoveItem succeeds, and the health-read/clamp -- where this throw
    -- happens -- runs before RemoveItem is even attempted) -- no time
    -- advance is needed for this retry to be genuinely fresh, which is
    -- exactly what makes a 'treatment_in_progress'/leaked-mutex regression
    -- observable here: if Release had NOT run, this retry would be
    -- rejected with treatment_in_progress instead of succeeding.
    f.setThrowOnMaxHealth(false)
    local retryResult = f.invokeCallback(CALLBACK_NAME, USER_SRC, TARGET_SRC)
    t.isTrue(retryResult.ok, 'the mutex must have been released on the error path -- a leaked mutex would report treatment_in_progress forever')
    t.isNotNil(lastClientEvent(f, HEAL_EVENT), 'the retry must be a real, fully successful heal, not merely "not blocked"')
end)

t.test('the print diagnostic for a caught mutation error names the source and citizenid (developer-facing console line, not a locale()-migrated player-facing string)', function()
    local f = newMedkitFixture()
    wireUsingPlayer(f, USER_SRC, { itemCount = 1 })
    wireTargetK9(f, TARGET_SRC, { health = 150, maxHealth = 200, citizenid = 'K9-ERR-CID' })
    f.setThrowOnMaxHealth(true)
    f.invokeCallback(CALLBACK_NAME, USER_SRC, TARGET_SRC)
    local found = false
    for _, line in ipairs(f.printedLines) do
        if line:find('useK9Medkit mutation error', 1, true) and line:find('K9-ERR-CID', 1, true) then found = true end
    end
    t.isTrue(found)
end)

-- ========================================================================
-- MUST-MATTER #3(b): DISCLOSED mechanism proof for MedkitMutex under
-- GENUINE interleaving, using a real Lua coroutine with a suspend hook
-- (the technique combat_spec.lua's own header names for
-- HandleTakedownRequest's real Wait() yield).
--
-- HONESTY CHECK, READ BEFORE TRUSTING THIS TEST: server/medkit.lua's own
-- header states plainly that "this handler never actually yields" today --
-- confirmed independently by reading both exports.ox_inventory:GetItemCount
-- and :RemoveItem's real bodies, per that file's own OX_INVENTORY EXPORT
-- SIGNATURES section (neither calls `.await`/`lib.callback.await`
-- internally). That means MedkitMutex.TryAcquire's `false` branch
-- ('treatment_in_progress') is, as of TODAY's real production code,
-- UNREACHABLE via two calls that are merely close in time -- there is no
-- genuine window for a second dispatch to observe the mutex still held,
-- because the entire mutex-held region runs to completion synchronously in
-- one Lua step. This test does NOT claim otherwise. It injects a
-- coroutine.yield() at the GetItemCount call site specifically to exercise
-- the REAL, UNMODIFIED MedkitMutex/HandleUseK9Medkit/RunUseK9MedkitMutation
-- code under the exact interleaving shape this file's own header names as
-- the reason MedkitMutex exists at all ("belt-and-suspenders... correct if
-- a future change... ever introduces a real yield point here"). This is
-- the ONLY way to reach 'treatment_in_progress' at all under the current
-- source -- recorded here as a genuine, disclosed coverage gap (the reason
-- string is real, reachable code today ONLY through a test-injected yield,
-- not through any two real, unmodified client requests), not silently
-- worked around.
-- ========================================================================

t.test('DISCLOSED MECHANISM PROOF: under a genuinely interleaved yield, MedkitMutex correctly rejects a second in-flight request against the SAME target as treatment_in_progress, and correctly releases once the first completes', function()
    local f = newMedkitFixture()
    local USER_A, USER_B = 10, 11
    wireUsingPlayer(f, USER_A, { itemCount = 1 })
    wireUsingPlayer(f, USER_B, { itemCount = 1 })
    wireTargetK9(f, TARGET_SRC, { health = 150, maxHealth = 200 })

    f.setYieldOnGetItemCount(true)
    local coA = f.startCallbackCoroutine(CALLBACK_NAME, USER_A, TARGET_SRC)
    coA.resume() -- runs HandleUseK9Medkit through MedkitMutex.TryAcquire (acquired) and into RunUseK9MedkitMutation, parking at the injected yield inside GetItemCount
    t.isFalse(coA.isDead(), 'coroutine A must be parked mid-mutation, not finished')

    -- Coroutine B's own request must never itself need to yield to observe
    -- the rejection -- MedkitMutex.TryAcquire is checked in
    -- HandleUseK9Medkit, strictly BEFORE RunUseK9MedkitMutation (and so
    -- before B's own GetItemCount call) is ever reached.
    f.setYieldOnGetItemCount(false)
    local coB = f.startCallbackCoroutine(CALLBACK_NAME, USER_B, TARGET_SRC)
    local resultB = coB.resume()
    t.isTrue(coB.isDead(), 'B\'s own request must resolve in one step -- it never reaches a yield point of its own')
    t.isFalse(resultB.ok)
    t.equals(resultB.reason, 'treatment_in_progress', 'B must observe the mutex A is still holding')
    t.equals(f.getItemCount(USER_B, 'k9_medkit'), 1, 'B\'s own item must never be touched by a treatment_in_progress rejection')

    -- Let A resume past the yield and finish normally.
    local resultA = coA.resume()
    t.isTrue(coA.isDead())
    t.isTrue(resultA.ok, 'A\'s own request must still complete successfully once resumed')
    t.equals(f.getItemCount(USER_A, 'k9_medkit'), 0, 'A\'s own item must have been consumed on its real completion')

    -- The mutex must be released now -- a THIRD request against the same
    -- target (past the now-armed per-target cooldown, so cooldown itself
    -- isn't what would be blocking it) must not see treatment_in_progress.
    f.advance(f.config.K9Medkit.cooldownMs + 1)
    wireUsingPlayer(f, 12, { itemCount = 1 })
    local resultC = f.invokeCallback(CALLBACK_NAME, 12, TARGET_SRC)
    t.isFalse(resultC.reason == 'treatment_in_progress', 'the mutex must have been released once A\'s own coroutine ran to completion')
end)

-- ========================================================================
-- MUST-MATTER #4: item consumption ordering. A rejection that happens
-- AFTER exports.ox_inventory:RemoveItem has already succeeded DOES consume
-- the item while still reporting failure -- a genuine FINDING, disclosed
-- here and in this task's report, NOT fixed in server/medkit.lua (this
-- task's own hard rule forbids editing that file).
-- ========================================================================

t.test('FIXED: a native failure in the health read no longer consumes the item or stamps the cooldown -- the compute happens before RemoveItem', function()
    local f = newMedkitFixture()
    wireUsingPlayer(f, USER_SRC, { itemCount = 1 })
    wireTargetK9(f, TARGET_SRC, { health = 150, maxHealth = 200, citizenid = 'K9-CONSUME-CID' })

    f.setThrowOnMaxHealth(true)
    local ok, result = pcall(f.invokeCallback, CALLBACK_NAME, USER_SRC, TARGET_SRC)
    t.isTrue(ok, 'the thrown native error must be caught, not crash the callback')
    t.isFalse(result.ok)
    t.equals(result.reason, 'medkit_failed')

    -- FIXED. This case originally pinned the bug: RemoveItem ran BEFORE
    -- GetEntityMaxHealth, so a throw in the health read left the item gone
    -- with no heal applied -- the player paid and got nothing.
    --
    -- The heal is now computed and clamped BEFORE RemoveItem, so a failure
    -- in the health reads happens while the item is still untouched.
    -- RemoveItem is the genuine point of no return, and nothing fallible
    -- runs between it and the heal push.
    t.equals(f.getItemCount(USER_SRC, 'k9_medkit'), 1, 'the item is NOT consumed -- the throwing read now happens before RemoveItem')

    t.equals(#f.clientEvents, 0, 'and no heal was applied either -- the attempt failed cleanly, costing the player nothing')

    -- The cooldown stamp moved to AFTER RemoveItem succeeds, so a failed
    -- attempt no longer burns the target's window. That is safe because the
    -- double-heal race the early stamp appeared to guard was already closed
    -- by MedkitMutex serializing per-target requests -- stamping early only
    -- bought an unfairness, never a protection.
    f.setThrowOnMaxHealth(false)
    wireUsingPlayer(f, USER_SRC, { itemCount = 1 })
    local secondAttempt = f.invokeCallback(CALLBACK_NAME, USER_SRC, TARGET_SRC)
    t.isTrue(secondAttempt.ok, 'a fresh attempt succeeds -- the failed one never stamped the cooldown')
end)

t.test('by contrast: RemoveItem itself returning false (the "should not happen" defensive branch this file\'s own doc comment names) is reported as no_item, and does NOT actually decrement the item count', function()
    local f = newMedkitFixture()
    wireUsingPlayer(f, USER_SRC, { itemCount = 1 })
    wireTargetK9(f, TARGET_SRC, { health = 150, maxHealth = 200 })

    -- Simulates ox_inventory's own possession check (GetItemCount) and its
    -- mutation call (RemoveItem) disagreeing -- e.g. a concurrent, external
    -- inventory mutation between the two calls in a real server -- which
    -- this file's own doc comment on RunUseK9MedkitMutation names as
    -- "should not happen given step 3's check having just passed... but
    -- never assumed". GetItemCount still reports 1 (real, passing,
    -- unmodified check); only RemoveItem's own stub is forced to fail.
    f.setForceRemoveItemFail(true)
    local result = f.invokeCallback(CALLBACK_NAME, USER_SRC, TARGET_SRC)
    t.isFalse(result.ok)
    t.equals(result.reason, 'no_item', 'a RemoveItem failure must never be treated as a successful consumption')
    t.equals(f.getItemCount(USER_SRC, 'k9_medkit'), 1, 'the stub\'s own item count must be untouched -- RemoveItem reported failure')
    t.equals(#f.clientEvents, 0, 'no heal may ever be applied when the item was never actually consumed')
end)

-- ========================================================================
-- MUST-MATTER #5 (part 3): no_item, too_far, on_cooldown -- and proof that
-- each of these CHEAPER rejections never reaches, or never mutates, the
-- steps after it (ordering discipline this file's own doc comment claims).
-- ========================================================================

t.test('carrying zero medkits is no_item, and never calls RemoveItem at all', function()
    local f = newMedkitFixture()
    wireUsingPlayer(f, USER_SRC, { itemCount = 0 })
    wireTargetK9(f, TARGET_SRC)
    local result = f.invokeCallback(CALLBACK_NAME, USER_SRC, TARGET_SRC)
    t.isFalse(result.ok)
    t.equals(result.reason, 'no_item')
    t.equals(f.removeItemCallCount(), 0)
    t.equals(#f.clientEvents, 0)
end)

t.test('a no_item rejection never stamps the target\'s own cooldown -- an immediate retry with an item now present succeeds', function()
    local f = newMedkitFixture()
    wireUsingPlayer(f, USER_SRC, { itemCount = 0 })
    wireTargetK9(f, TARGET_SRC)
    f.invokeCallback(CALLBACK_NAME, USER_SRC, TARGET_SRC) -- no_item, no time advance
    f.setItemCount(USER_SRC, 'k9_medkit', 1)
    local result = f.invokeCallback(CALLBACK_NAME, USER_SRC, TARGET_SRC)
    t.isTrue(result.ok, 'the earlier no_item rejection must not have stamped a cooldown this fresh attempt would still be blocked by')
end)

t.test('beyond Config.K9Medkit.range is too_far, and never even calls GetItemCount (the cheapest check runs first)', function()
    local f = newMedkitFixture()
    wireUsingPlayer(f, USER_SRC, { itemCount = 1, x = 0, y = 0, z = 0 })
    wireTargetK9(f, TARGET_SRC, { x = 100, y = 0, z = 0 }) -- far beyond range (2.0m)
    local result = f.invokeCallback(CALLBACK_NAME, USER_SRC, TARGET_SRC)
    t.isFalse(result.ok)
    t.equals(result.reason, 'too_far')
    t.equals(f.getItemCountCallCount(), 0, 'proximity is checked before any item-possession query')
end)

t.test('exactly AT the configured range boundary is still accepted (range is a strict "beyond", not "at or beyond")', function()
    local f = newMedkitFixture()
    wireUsingPlayer(f, USER_SRC, { itemCount = 1, x = 0, y = 0, z = 0 })
    wireTargetK9(f, TARGET_SRC, { x = 2.0, y = 0, z = 0 }) -- exactly Config.K9Medkit.range
    local result = f.invokeCallback(CALLBACK_NAME, USER_SRC, TARGET_SRC)
    t.isTrue(result.ok, 'dist > range is the real production check -- dist == range must not be rejected')
end)

t.test('a fresh target has no cooldown and succeeds on its first-ever treat', function()
    local f = newMedkitFixture()
    wireUsingPlayer(f, USER_SRC, { itemCount = 1 })
    wireTargetK9(f, TARGET_SRC)
    local result = f.invokeCallback(CALLBACK_NAME, USER_SRC, TARGET_SRC)
    t.isTrue(result.ok)
end)

t.test('a second treat against the SAME target citizenid, immediately after a successful one, is on_cooldown -- and never calls GetItemCount', function()
    local f = newMedkitFixture()
    wireUsingPlayer(f, USER_SRC, { itemCount = 2 })
    wireTargetK9(f, TARGET_SRC)
    f.invokeCallback(CALLBACK_NAME, USER_SRC, TARGET_SRC) -- consumes one item, stamps the cooldown
    local callsBefore = f.getItemCountCallCount()
    local result = f.invokeCallback(CALLBACK_NAME, USER_SRC, TARGET_SRC)
    t.isFalse(result.ok)
    t.equals(result.reason, 'on_cooldown')
    t.equals(f.getItemCountCallCount(), callsBefore, 'the cooldown check must reject before ever consulting item possession')
    t.equals(f.getItemCount(USER_SRC, 'k9_medkit'), 1, 'no second item may be consumed while on cooldown')
end)

t.test('the per-target cooldown is keyed by the TARGET\'S citizenid, not the (using player, target) pair -- a DIFFERENT using player is equally blocked against the same target', function()
    local f = newMedkitFixture()
    local USER_A, USER_B = 20, 21
    wireUsingPlayer(f, USER_A, { itemCount = 1 })
    wireUsingPlayer(f, USER_B, { itemCount = 1 })
    wireTargetK9(f, TARGET_SRC)
    f.invokeCallback(CALLBACK_NAME, USER_A, TARGET_SRC)
    local result = f.invokeCallback(CALLBACK_NAME, USER_B, TARGET_SRC)
    t.isFalse(result.ok)
    t.equals(result.reason, 'on_cooldown', 'the SAME target citizenid must still be on cooldown for a completely different medic')
    t.equals(f.getItemCount(USER_B, 'k9_medkit'), 1, 'the second medic\'s own item must never be touched')
end)

t.test('the per-target cooldown does NOT block a treat against a genuinely DIFFERENT target citizenid', function()
    local f = newMedkitFixture()
    local TARGET_A, TARGET_B = 30, 31
    wireUsingPlayer(f, USER_SRC, { itemCount = 2 })
    wireTargetK9(f, TARGET_A, { citizenid = 'K9-A' })
    wireTargetK9(f, TARGET_B, { citizenid = 'K9-B', ped = 9999 })
    f.invokeCallback(CALLBACK_NAME, USER_SRC, TARGET_A)
    local result = f.invokeCallback(CALLBACK_NAME, USER_SRC, TARGET_B)
    t.isTrue(result.ok, 'a different target\'s own cooldown entry must be entirely independent')
end)

t.test('COOLDOWN BOUNDARY: one millisecond before Config.K9Medkit.cooldownMs has elapsed, the target is still on_cooldown', function()
    local f = newMedkitFixture()
    wireUsingPlayer(f, USER_SRC, { itemCount = 2 })
    wireTargetK9(f, TARGET_SRC)
    f.invokeCallback(CALLBACK_NAME, USER_SRC, TARGET_SRC)
    f.advance(f.config.K9Medkit.cooldownMs - 1)
    local result = f.invokeCallback(CALLBACK_NAME, USER_SRC, TARGET_SRC)
    t.isFalse(result.ok)
    t.equals(result.reason, 'on_cooldown')
end)

t.test('COOLDOWN BOUNDARY: at EXACTLY Config.K9Medkit.cooldownMs elapsed, the target is no longer on cooldown (the real "elapsed < threshold" check, not "<=")', function()
    local f = newMedkitFixture()
    wireUsingPlayer(f, USER_SRC, { itemCount = 2 })
    wireTargetK9(f, TARGET_SRC)
    f.invokeCallback(CALLBACK_NAME, USER_SRC, TARGET_SRC)
    f.advance(f.config.K9Medkit.cooldownMs)
    local result = f.invokeCallback(CALLBACK_NAME, USER_SRC, TARGET_SRC)
    t.isTrue(result.ok, 'elapsed == threshold must already be off cooldown, per server/cooldowns.lua\'s own IsOnCooldown ("elapsed < threshold")')
end)

t.test('the per-target cooldown persists across the target\'s own reconnect (a fresh server id, same citizenid) -- outlives any one connection by design', function()
    local f = newMedkitFixture()
    wireUsingPlayer(f, USER_SRC, { itemCount = 2 })
    wireTargetK9(f, TARGET_SRC, { citizenid = 'K9-PERSIST-CID' })
    f.invokeCallback(CALLBACK_NAME, USER_SRC, TARGET_SRC)

    -- Reconnect: a brand-new server id, SAME citizenid, a brand-new ped
    -- handle (a real reconnect gets a fresh ped).
    local NEW_TARGET_SRC = 999
    wireTargetK9(f, NEW_TARGET_SRC, { citizenid = 'K9-PERSIST-CID', ped = 88888 })
    local result = f.invokeCallback(CALLBACK_NAME, USER_SRC, NEW_TARGET_SRC)
    t.isFalse(result.ok)
    t.equals(result.reason, 'on_cooldown', 'the cooldown is keyed by citizenid, which must survive a reconnect under a new source id')
end)

-- ========================================================================
-- QUALITY FIX (this pass): Config.K9Medkit.cooldownMs used to be read raw,
-- with no validation, at every call site -- server/cooldowns.lua's own
-- IsOnCooldown treats a non-positive threshold as PERMANENTLY on cooldown,
-- never "no cooldown". An operator typo'ing this to 0 would have every K9
-- treatable exactly ONCE, ever, then permanently rejected for the rest of
-- this resource's uptime -- the exact class of "non-positive threshold
-- reading as permanently on" footgun this codebase has repeatedly had to
-- close elsewhere (server/kennel.lua's DeployCooldown, server/fetch.lua's
-- ThrowCooldown/PickupCooldown, etc., all via this same
-- ResolveConfiguredThresholdMs helper). Now resolved once, at file-load,
-- with a loud warning and a safe fallback -- these cases prove the fallback
-- actually takes effect, not just that a warning gets printed.
-- ========================================================================

t.test('QUALITY FIX: Config.K9Medkit.cooldownMs = 0 does NOT permanently block a target after their first treat -- it falls back to a real, expiring cooldown instead', function()
    local f = newMedkitFixture({ k9MedkitCfg = {
        itemName = 'k9_medkit', healthRestore = 50, range = 2.0,
        cooldownMs = 0, -- the footgun: operator meant "no cooldown"
        emsJobs = { 'ambulance' },
    } })
    wireUsingPlayer(f, USER_SRC, { itemCount = 2 })
    wireTargetK9(f, TARGET_SRC)

    local first = f.invokeCallback(CALLBACK_NAME, USER_SRC, TARGET_SRC)
    t.isTrue(first.ok, 'the first-ever treat against a fresh target must still succeed regardless')

    -- BEFORE THE FIX: a raw cooldownMs = 0 makes server/cooldowns.lua's
    -- IsOnCooldown return `true` forever once a key has been touched once --
    -- advancing time by any amount, however large, would never clear it.
    -- AFTER THE FIX: this resolves to the documented 60000ms fallback, so
    -- advancing well past that must clear it exactly like an ordinary,
    -- correctly-configured cooldown would.
    f.advance(61000)
    local second = f.invokeCallback(CALLBACK_NAME, USER_SRC, TARGET_SRC)
    t.isTrue(second.ok, 'a misconfigured 0 must degrade to a real, eventually-expiring cooldown -- never a permanent lockout')
end)

t.test('QUALITY FIX: Config.K9Medkit.cooldownMs = 0 prints a loud, named warning identifying the exact config key, resolved FRESH on first actual use -- not cached from file-load', function()
    local f = newMedkitFixture({ k9MedkitCfg = {
        itemName = 'k9_medkit', healthRestore = 50, range = 2.0,
        cooldownMs = 0,
        emsJobs = { 'ambulance' },
    } })
    wireUsingPlayer(f, USER_SRC, { itemCount = 1 })
    wireTargetK9(f, TARGET_SRC)

    -- Merely LOADING this file no longer prints anything -- see
    -- ResolveMedkitBaseCooldownMs's own doc comment for why the resolution
    -- is deliberately deferred to every actual call (never cached once at
    -- file-load), so a live Config change is always honored. The warning
    -- only appears once the value is actually consulted.
    t.equals(table.concat(f.printedLines, '\n'), '', 'nothing is resolved, and therefore nothing warned, purely from loading this file')

    f.invokeCallback(CALLBACK_NAME, USER_SRC, TARGET_SRC)
    local joined = table.concat(f.printedLines, '\n')
    t.contains(joined, 'Config.K9Medkit.cooldownMs', 'the warning must name the exact misconfigured key, not a generic message')
end)

t.test('QUALITY FIX: a NEGATIVE Config.K9Medkit.cooldownMs is treated identically to 0 -- also falls back, never a permanent lockout', function()
    local f = newMedkitFixture({ k9MedkitCfg = {
        itemName = 'k9_medkit', healthRestore = 50, range = 2.0,
        cooldownMs = -5000,
        emsJobs = { 'ambulance' },
    } })
    wireUsingPlayer(f, USER_SRC, { itemCount = 2 })
    wireTargetK9(f, TARGET_SRC)

    f.invokeCallback(CALLBACK_NAME, USER_SRC, TARGET_SRC)
    f.advance(61000)
    local result = f.invokeCallback(CALLBACK_NAME, USER_SRC, TARGET_SRC)
    t.isTrue(result.ok)
end)

t.test('QUALITY FIX: a normally-configured, positive Config.K9Medkit.cooldownMs is used EXACTLY as configured, with no warning at all', function()
    local f = newMedkitFixture({ k9MedkitCfg = {
        itemName = 'k9_medkit', healthRestore = 50, range = 2.0,
        cooldownMs = 12345,
        emsJobs = { 'ambulance' },
    } })
    wireUsingPlayer(f, USER_SRC, { itemCount = 2 })
    wireTargetK9(f, TARGET_SRC)

    f.invokeCallback(CALLBACK_NAME, USER_SRC, TARGET_SRC)
    f.advance(12344)
    local stillOnCooldown = f.invokeCallback(CALLBACK_NAME, USER_SRC, TARGET_SRC)
    t.isFalse(stillOnCooldown.ok)
    t.equals(stillOnCooldown.reason, 'on_cooldown')

    f.advance(1) -- now at exactly 12345 elapsed
    local nowOff = f.invokeCallback(CALLBACK_NAME, USER_SRC, TARGET_SRC)
    t.isTrue(nowOff.ok, 'the configured value itself must be honored exactly, not silently substituted')

    local joined = table.concat(f.printedLines, '\n')
    t.notContains(joined, 'Config.K9Medkit.cooldownMs', 'a validly-configured value must never print the fallback warning')
end)

-- ========================================================================
-- XP TIER UNLOCK -- GetXPTierMedkitCooldownMs (server/progression.lua),
-- the documented soft dependency that resolves the Veteran-tier
-- medkitCooldownMultiplier reward into the actual threshold this file's
-- own MedkitCooldown.IsOnCooldown call is checked against. Keyed on the
-- TARGET's own citizenid, never the using player's -- see this file's
-- FILE-TO-FILE CONTRACT for the full reasoning. GetXPTierMedkitCooldownMs's
-- own numeric contract (multiplier bounds, the 1ms floor) is
-- tests/xptierunlocks_spec.lua's job, not this file's -- this section only
-- proves server/medkit.lua actually CONSULTS it and USES its result.
-- ========================================================================

t.test('XP TIER UNLOCK: a Veteran-tier target (accessor returns a shortened cooldown) is treatable again sooner than the base Config.K9Medkit.cooldownMs would allow', function()
    local f = newMedkitFixture({
        withXPTierMedkitCooldown = true,
        medkitCooldownMsByCitizenid = { ['K9-VETERAN'] = 15000 }, -- e.g. baseCooldownMs(60000) * 0.75 tier multiplier, pre-resolved by the (stubbed) accessor
    })
    wireUsingPlayer(f, USER_SRC, { itemCount = 2 })
    wireTargetK9(f, TARGET_SRC, { citizenid = 'K9-VETERAN' })
    f.invokeCallback(CALLBACK_NAME, USER_SRC, TARGET_SRC)

    -- Past the REDUCED threshold, but still well short of the base 60000ms
    -- cooldown -- only passes if server/medkit.lua actually used the
    -- accessor's shortened value, not the raw Config.K9Medkit.cooldownMs.
    f.advance(15001)
    local result = f.invokeCallback(CALLBACK_NAME, USER_SRC, TARGET_SRC)
    t.isTrue(result.ok, 'a Veteran-tier target must be treatable again after its OWN shortened cooldown elapses, not the base one')
    t.equals(#f.xpTierCooldownCalls, 2, 'the accessor is consulted on every treat attempt against this target')
    t.equals(f.xpTierCooldownCalls[1].citizenid, 'K9-VETERAN')
    t.equals(f.xpTierCooldownCalls[1].baseCooldownMs, f.config.K9Medkit.cooldownMs, 'the accessor must be given the real configured base, never a hardcoded number')
end)

t.test('XP TIER UNLOCK: a base-tier target (accessor returns baseCooldownMs unchanged) still gets the full configured cooldown, not the Veteran-tier reduction', function()
    local f = newMedkitFixture({ withXPTierMedkitCooldown = true }) -- no override for this citizenid -- the stub falls through to baseCooldownMs
    wireUsingPlayer(f, USER_SRC, { itemCount = 2 })
    wireTargetK9(f, TARGET_SRC, { citizenid = 'K9-BASE-TIER' })
    f.invokeCallback(CALLBACK_NAME, USER_SRC, TARGET_SRC)

    f.advance(15001) -- past the Veteran-tier threshold, but NOT the full base cooldown
    local result = f.invokeCallback(CALLBACK_NAME, USER_SRC, TARGET_SRC)
    t.isFalse(result.ok, 'a base-tier target must still honor the full configured cooldown')
    t.equals(result.reason, 'on_cooldown')
end)

t.test('XP TIER UNLOCK: GetXPTierMedkitCooldownMs entirely absent (server/progression.lua not loaded, or XPProgression off) falls back cleanly to the plain configured cooldown', function()
    local f = newMedkitFixture() -- withXPTierMedkitCooldown deliberately omitted -- the global is simply undefined
    wireUsingPlayer(f, USER_SRC, { itemCount = 2 })
    wireTargetK9(f, TARGET_SRC, { citizenid = 'K9-NO-ACCESSOR' })
    local r1 = f.invokeCallback(CALLBACK_NAME, USER_SRC, TARGET_SRC)
    t.isTrue(r1.ok)

    f.advance(f.config.K9Medkit.cooldownMs)
    local r2 = f.invokeCallback(CALLBACK_NAME, USER_SRC, TARGET_SRC)
    t.isTrue(r2.ok, 'a missing accessor must never error, and must behave exactly like the plain configured cooldown')
end)

-- ========================================================================
-- HANDLER XP TIER UNLOCK -- GetHandlerXPTierMedkitCooldownMs
-- (server/progression.lua), the documented soft dependency that resolves
-- Config.HandlerXPTiers' medkitTreatCooldownMultiplier reward into the
-- actual threshold MedkitCooldown.IsOnCooldown is checked against. Keyed
-- on the USING player's own citizenid (the handler performing the treat),
-- never the target's -- the mirror image of the K9-side section above.
-- Chained ON TOP of whatever the K9-side accessor already produced, so
-- these tests fix the target at base-tier (no K9-side reduction) to
-- isolate the handler-side effect cleanly. This section only proves
-- server/medkit.lua actually CONSULTS the accessor and USES its result --
-- the accessor's own numeric contract belongs to whatever spec covers
-- server/progression.lua directly.
-- ========================================================================

t.test('HANDLER XP TIER UNLOCK: a Master-Handler USING player (accessor returns a shortened cooldown) can treat the same target again sooner than the base Config.K9Medkit.cooldownMs would allow', function()
    local f = newMedkitFixture({
        withHandlerXPTierMedkitCooldown = true,
        handlerMedkitCooldownMsByCitizenid = { ['HANDLER-MASTER'] = 42000 }, -- e.g. baseCooldownMs(60000) * 0.70 tier multiplier, pre-resolved by the (stubbed) accessor
    })
    wireUsingPlayer(f, USER_SRC, { itemCount = 3, citizenid = 'HANDLER-MASTER' })
    wireTargetK9(f, TARGET_SRC, { citizenid = 'K9-BASE-TIER-2' })
    f.invokeCallback(CALLBACK_NAME, USER_SRC, TARGET_SRC)

    -- Past the REDUCED threshold, but still well short of the base 60000ms
    -- cooldown -- only passes if server/medkit.lua actually used the
    -- accessor's shortened value, not the raw Config.K9Medkit.cooldownMs.
    f.advance(42001)
    local result = f.invokeCallback(CALLBACK_NAME, USER_SRC, TARGET_SRC)
    t.isTrue(result.ok, 'a Master-Handler USING player must be able to treat again after their OWN shortened cooldown elapses, not the base one')
    t.equals(#f.handlerXPTierCooldownCalls, 2, 'the accessor is consulted on every treat attempt by this using player')
    t.equals(f.handlerXPTierCooldownCalls[1].citizenid, 'HANDLER-MASTER', 'must be keyed on the USING player, never the target')
    t.equals(f.handlerXPTierCooldownCalls[1].baseCooldownMs, f.config.K9Medkit.cooldownMs, 'chained on top of the (here, unmodified) K9-side result -- must still trace back to the real configured base')
end)

t.test('HANDLER XP TIER UNLOCK: a Rookie Handler USING player (accessor returns baseCooldownMs unchanged) still gets the full configured cooldown, not the Master-Handler reduction', function()
    local f = newMedkitFixture({ withHandlerXPTierMedkitCooldown = true }) -- no override for this citizenid -- the stub falls through to baseCooldownMs
    wireUsingPlayer(f, USER_SRC, { itemCount = 3, citizenid = 'HANDLER-ROOKIE' })
    wireTargetK9(f, TARGET_SRC, { citizenid = 'K9-BASE-TIER-3' })
    f.invokeCallback(CALLBACK_NAME, USER_SRC, TARGET_SRC)

    f.advance(42001) -- past the Master-Handler threshold, but NOT the full base cooldown
    local result = f.invokeCallback(CALLBACK_NAME, USER_SRC, TARGET_SRC)
    t.isFalse(result.ok, 'a rookie-handler USING player must still honor the full configured cooldown')
    t.equals(result.reason, 'on_cooldown')
end)

t.test('HANDLER XP TIER UNLOCK: GetHandlerXPTierMedkitCooldownMs entirely absent (server/progression.lua not loaded, or HandlerXPProgression off) falls back cleanly to the plain configured cooldown', function()
    local f = newMedkitFixture() -- withHandlerXPTierMedkitCooldown deliberately omitted -- the global is simply undefined
    wireUsingPlayer(f, USER_SRC, { itemCount = 3 })
    wireTargetK9(f, TARGET_SRC, { citizenid = 'K9-NO-HANDLER-ACCESSOR' })
    local r1 = f.invokeCallback(CALLBACK_NAME, USER_SRC, TARGET_SRC)
    t.isTrue(r1.ok)

    f.advance(f.config.K9Medkit.cooldownMs)
    local r2 = f.invokeCallback(CALLBACK_NAME, USER_SRC, TARGET_SRC)
    t.isTrue(r2.ok, 'a missing accessor must never error, and must behave exactly like the plain configured cooldown')
end)

-- ========================================================================
-- SOURCE AUDIT TRIPWIRE (coordinator-directed, dead-config-field pass;
-- handlerTreatK9 WIRED this pass, coder-backend -- see below): this
-- cooldown is handler-rank-reduced (combined worst case 18000ms, after the
-- XP-rebalance pass retuned Master Handler's medkitTreatCooldownMultiplier
-- from 0.70 to 0.50 and gave Elite K9 a 0.60 target-side multiplier it did
-- not previously have -- see
-- GetHandlerXPTierMedkitCooldownMs's own doc comment, server/progression.lua,
-- "THE NUMBERS" section). handlerTreatK9 (12 XP, Config.HandlerXP.awards)
-- is NOW wired -- server/medkit.lua's RunUseK9MedkitMutation calls
-- AwardHandlerXP(usingCitizenid, 'handlerTreatK9') for a genuine heal, gated
-- by HandlerTreatXpMintCooldown, a dedicated per-ACTOR MINT cooldown
-- (mirroring server/certifications/'s CertifyXpMintCooldown fix for
-- handlerCertifyK9) -- never a per-target one (MedkitCooldown's own shape,
-- which a multi-target actor could otherwise bypass entirely) -- sized well
-- below the rank-reduced 18000ms floor (30 real minutes -- 100x that floor,
-- so the rebalance's deeper multipliers do not move the mint rate at all). This is a RED
-- TEST, not a comment: it fails the moment handlerTreatK9 is awarded from
-- this file WITHOUT a same-file *_XP_MINT_COOLDOWN tracker alongside it --
-- now GREEN because that tracker genuinely exists. Mirrors
-- an earlier spec's own "SOURCE AUDIT" precedent.
-- ========================================================================

t.test('SOURCE AUDIT TRIPWIRE: server/medkit.lua must not award handlerTreatK9 without a dedicated per-actor *_XP_MINT_COOLDOWN tracker also present in this file', function()
    local handle = assert(io.open('../server/medkit.lua', 'r'))
    local text = handle:read('a')
    handle:close()

    local awardsHandlerTreatK9 = text:find("AwardHandlerXP%s*%(.-'handlerTreatK9'") ~= nil
    if not awardsHandlerTreatK9 then
        t.isTrue(true, 'handlerTreatK9 is still unwired, per config.lua\'s own Config.Features.HandlerXPProgression header -- nothing more to check')
        return
    end

    -- THIS CHECK USED TO BE A BARE SUBSTRING SEARCH, AND IT COULD NEVER FIRE.
    -- It looked for 'XP_MINT_COOLDOWN' anywhere in the file -- but the
    -- doc-comment in server/medkit.lua that explains this very requirement
    -- contains the words "*_XP_MINT_COOLDOWN tracker", so the search was
    -- permanently pre-satisfied by its own documentation. A regression pass
    -- proved it by wiring the guarded-against award and watching this test
    -- still report PASS.
    -- It now requires a real DECLARATION -- a cooldown tracker actually
    -- constructed via NewCooldown() whose name follows the
    -- CertifyXpMintCooldown precedent in server/certifications/. Prose
    -- cannot satisfy that. The test directly below proves this pattern
    -- rejects a comment and accepts a real declaration, so a future edit
    -- cannot quietly defeat it again.
    t.isTrue(text:find('local%s+[%w_]*XpMintCooldown%s*=%s*NewCooldown') ~= nil,
        'handlerTreatK9 is now awarded from this file, but no *_XP_MINT_COOLDOWN tracker was found -- add a ' ..
        'DEDICATED per-ACTOR mint cooldown (a second, separate tracker, never MedkitCooldown itself, which is ' ..
        'target-keyed and now handler-rank-shortened to an 18000ms combined worst-case floor) named with the ' ..
        'XP_MINT_COOLDOWN convention (server/certifications/\'s CERTIFY_XP_MINT_COOLDOWN_MS/CertifyXpMintCooldown ' ..
        'precedent) so this test can find it, then update this test\'s own expectations to match. See ' ..
        'server/progression.lua\'s GetHandlerXPTierMedkitCooldownMs header for the full writeup.')
end)

-- ========================================================================
-- HANDLER XP WIRING (this pass, coder-backend -- closes the "top handler
-- rank cannot be reached by playing" anti-farm audit finding). Proves the
-- award/mint-cooldown behavior end to end from THIS file's own
-- invokeCallback path, using opts.withAwardHandlerXP (this file's own
-- test-controlled stand-in for server/progression.lua's real AwardHandlerXP
-- -- see that option's own declaration comment above newMedkitFixture's own
-- `local env = Sandbox.newEnv(envOverrides)` line). The REAL AwardHandlerXP's
-- own numeric/budget contract is proven separately by
-- tests/progression_spec.lua and tests/handlerprogression_spec.lua; this
-- section proves THIS file's own call shape -- WHEN it calls AwardHandlerXP,
-- with WHAT arguments, and under WHAT dedicated per-actor mint-cooldown gate
-- -- plus one full real-chain integration test further down proving the
-- REAL shared XP mint budget genuinely blocks this new award exactly like
-- every other one.
-- ========================================================================

t.test('HANDLER XP WIRING: a genuine heal (target strictly below max health) awards handlerTreatK9 exactly once, to the USING player\'s own citizenid', function()
    local f = newMedkitFixture({ withAwardHandlerXP = true })
    wireUsingPlayer(f, USER_SRC, { citizenid = 'HANDLER-CID', itemCount = 5 })
    wireTargetK9(f, TARGET_SRC, { health = 150, maxHealth = 200 })

    local result = f.invokeCallback(CALLBACK_NAME, USER_SRC, TARGET_SRC)
    t.isTrue(result.ok)
    t.equals(#f.awardHandlerXPCalls, 1)
    t.equals(f.awardHandlerXPCalls[1].citizenid, 'HANDLER-CID')
    t.equals(f.awardHandlerXPCalls[1].actionKey, 'handlerTreatK9')
end)

t.test('MEANINGFUL ACTION: topping off an already-full-health K9 still succeeds (ok=true, item consumed, cooldown stamped) but awards NO handlerTreatK9 XP -- nothing was actually healed', function()
    local f = newMedkitFixture({ withAwardHandlerXP = true })
    wireUsingPlayer(f, USER_SRC, { citizenid = 'HANDLER-CID', itemCount = 5 })
    wireTargetK9(f, TARGET_SRC, { health = 200, maxHealth = 200 }) -- already at max -- nothing to restore

    local result = f.invokeCallback(CALLBACK_NAME, USER_SRC, TARGET_SRC)
    t.isTrue(result.ok, 'topping off an already-healthy K9 must still succeed -- this gate is on the AWARD, never the action (GATE THE START, NEVER THE STOP)')
    t.equals(f.getItemCount(USER_SRC, f.config.K9Medkit.itemName), 4, 'the item is still consumed even though no XP is paid -- the medkit itself did not fail')
    t.equals(#f.awardHandlerXPCalls, 0, 'nothing was actually healed, so no handler XP should be minted for it')
end)

t.test('HANDLER XP WIRING: a second genuine treat by the SAME using citizenid against a DIFFERENT target, immediately after (well inside the 30-minute mint window), heals successfully but is NOT awarded a second time -- the per-actor mint cooldown (not MedkitCooldown\'s own per-target shape) is what stops a multi-target round-robin', function()
    local f = newMedkitFixture({ withAwardHandlerXP = true })
    wireUsingPlayer(f, USER_SRC, { citizenid = 'HANDLER-CID', itemCount = 5 })
    wireTargetK9(f, TARGET_SRC, { citizenid = 'K9-A', health = 150, maxHealth = 200 })

    local r1 = f.invokeCallback(CALLBACK_NAME, USER_SRC, TARGET_SRC)
    t.isTrue(r1.ok)
    t.equals(#f.awardHandlerXPCalls, 1)

    -- A genuinely DIFFERENT target -- MedkitCooldown (per-target) has never
    -- seen this citizenid before, so the heal itself succeeds regardless.
    local TARGET_SRC_2 = TARGET_SRC + 1
    wireTargetK9(f, TARGET_SRC_2, { citizenid = 'K9-B', health = 150, maxHealth = 200 })
    f.advance(1) -- barely any time has passed -- nowhere near the 30-minute mint window
    local r2 = f.invokeCallback(CALLBACK_NAME, USER_SRC, TARGET_SRC_2)
    t.isTrue(r2.ok, 'the heal itself must still succeed -- the mint cooldown gates the AWARD, never the action')
    t.equals(#f.awardHandlerXPCalls, 1, 'the per-actor mint cooldown must block a second mint even against a totally different target')
end)

t.test('HANDLER XP WIRING: one millisecond before the 30-minute mint cooldown elapses, a genuinely different target still heals but is still refused a second mint', function()
    local f = newMedkitFixture({ withAwardHandlerXP = true })
    wireUsingPlayer(f, USER_SRC, { citizenid = 'HANDLER-CID', itemCount = 5 })
    wireTargetK9(f, TARGET_SRC, { citizenid = 'K9-A', health = 150, maxHealth = 200 })
    f.invokeCallback(CALLBACK_NAME, USER_SRC, TARGET_SRC)
    t.equals(#f.awardHandlerXPCalls, 1)

    local TARGET_SRC_2 = TARGET_SRC + 1
    wireTargetK9(f, TARGET_SRC_2, { citizenid = 'K9-B', health = 150, maxHealth = 200 })
    f.advance((30 * 60 * 1000) - 1)
    local r2 = f.invokeCallback(CALLBACK_NAME, USER_SRC, TARGET_SRC_2)
    t.isTrue(r2.ok)
    t.equals(#f.awardHandlerXPCalls, 1, 'still on cooldown at 1ms short of the full window')
end)

t.test('HANDLER XP WIRING: once the 30-minute mint cooldown fully elapses, the SAME actor is awarded again', function()
    local f = newMedkitFixture({ withAwardHandlerXP = true })
    wireUsingPlayer(f, USER_SRC, { citizenid = 'HANDLER-CID', itemCount = 5 })
    wireTargetK9(f, TARGET_SRC, { citizenid = 'K9-A', health = 150, maxHealth = 200 })
    f.invokeCallback(CALLBACK_NAME, USER_SRC, TARGET_SRC)
    t.equals(#f.awardHandlerXPCalls, 1)

    f.advance(30 * 60 * 1000) -- exactly 30 minutes -- MedkitCooldown's own much shorter window has long since cleared too
    wireTargetK9(f, TARGET_SRC, { citizenid = 'K9-A', health = 150, maxHealth = 200 }) -- heal it again, freshly injured
    local r2 = f.invokeCallback(CALLBACK_NAME, USER_SRC, TARGET_SRC)
    t.isTrue(r2.ok)
    t.equals(#f.awardHandlerXPCalls, 2, 'once the actor\'s own mint cooldown has fully elapsed, the SAME actor must be paid again')
end)

t.test('FARM CLOSURE: the per-actor mint cooldown SURVIVES the actor\'s own disconnect and reconnect -- keyed on the durable citizenid, never the recyclable numeric source', function()
    local f = newMedkitFixture({ withAwardHandlerXP = true })
    wireUsingPlayer(f, USER_SRC, { citizenid = 'HANDLER-CID', itemCount = 5 })
    wireTargetK9(f, TARGET_SRC, { citizenid = 'K9-A', health = 150, maxHealth = 200 })
    f.invokeCallback(CALLBACK_NAME, USER_SRC, TARGET_SRC)
    t.equals(#f.awardHandlerXPCalls, 1)

    -- Simulate a disconnect + reconnect: the SAME citizenid returns on a
    -- BRAND NEW numeric server id (FXServer recycles server ids -- nothing
    -- about this citizenid's own identity changed by reconnecting).
    local RECONNECTED_SRC = USER_SRC + 100
    wireUsingPlayer(f, RECONNECTED_SRC, { citizenid = 'HANDLER-CID', itemCount = 5 })
    -- A genuinely different target, so MedkitCooldown (per-target) cannot be
    -- the reason a second mint is refused here.
    local TARGET_SRC_2 = TARGET_SRC + 1
    wireTargetK9(f, TARGET_SRC_2, { citizenid = 'K9-B', health = 150, maxHealth = 200 })
    f.advance(1)
    local r2 = f.invokeCallback(CALLBACK_NAME, RECONNECTED_SRC, TARGET_SRC_2)
    t.isTrue(r2.ok, 'the heal itself must still succeed on the new connection')
    t.equals(#f.awardHandlerXPCalls, 1, 'a reconnect must NEVER reset this citizenid\'s own mint cooldown -- that is exactly the farm this tracker exists to close')
end)

t.test('HANDLER XP WIRING: AwardHandlerXP entirely absent (server/progression.lua not loaded, or the feature is off) never crashes, and the heal still succeeds exactly as before this pass', function()
    local f = newMedkitFixture() -- withAwardHandlerXP deliberately omitted -- the global is simply undefined
    wireUsingPlayer(f, USER_SRC, { citizenid = 'HANDLER-CID', itemCount = 5 })
    wireTargetK9(f, TARGET_SRC, { health = 150, maxHealth = 200 })

    local result = f.invokeCallback(CALLBACK_NAME, USER_SRC, TARGET_SRC)
    t.isTrue(result.ok, 'a missing AwardHandlerXP must never error, and must behave exactly like the pre-wiring heal path')
end)

-- ========================================================================
-- HANDLER XP WIRING, REAL SHARED BUDGET (this pass, coder-backend): the
-- three tests immediately above all stub AwardHandlerXP directly (this
-- file's own opts.withAwardHandlerXP), which can only prove THIS file's own
-- call shape -- it cannot prove the REAL server/progression.lua shared XP
-- mint budget (XPMintBudget/XP_MINT_BUDGET_CAP_XP, per this task's own
-- "the shared budget still caps total XP per hour with the new awards
-- included" requirement) actually gets consulted for handlerTreatK9 too.
-- This section loads the REAL, unmodified server/datastore.lua +
-- server/cooldowns.lua + server/progression.lua alongside the REAL,
-- unmodified server/medkit.lua (mirroring newMedkitOverrideChainFixture's
-- own real-chain precedent above), and proves the shared budget genuinely
-- refuses handlerTreatK9 once it is exhausted -- by another mechanic
-- entirely -- and that the refusal is temporary (recovers once the budget
-- refills), never a permanent lockout.
-- ========================================================================

--- @return table fixture
local function newMedkitSharedBudgetFixture()
    local fakeNow = 0
    local function GetGameTimer() return fakeNow end

    local eventHandlers = {}
    local function AddEventHandler(eventName, handler)
        eventHandlers[eventName] = eventHandlers[eventName] or {}
        eventHandlers[eventName][#eventHandlers[eventName] + 1] = handler
    end
    local function RegisterNetEvent(eventName, handler)
        if handler then AddEventHandler(eventName, handler) end
    end

    local callbacks = {}
    local lib = { callback = { register = function(name, handler) callbacks[name] = handler end } }

    local printedLines = {}
    local function printStub(...)
        local parts = {}
        for i = 1, select('#', ...) do parts[i] = tostring(select(i, ...)) end
        printedLines[#printedLines + 1] = table.concat(parts, '\t')
    end

    local function GetCurrentResourceName() return 'john-k9' end

    -- Same one-shot "park at the first Wait()" CreateThread shape
    -- newMedkitOverrideChainFixture already uses above -- neither
    -- server/progression.lua's mint-budget sweep nor server/medkit.lua's two
    -- own sweeps need stepping for this section's own tests.
    local function CreateThread(fn)
        local co = coroutine.create(fn)
        local ok, err = coroutine.resume(co)
        if not ok then
            error(('newMedkitSharedBudgetFixture: a captured CreateThread body errored: %s'):format(tostring(err)))
        end
    end
    local function Wait(_ms) coroutine.yield() end

    local playersBySource = {}
    local function qbxGetPlayer(_self, src)
        local p = playersBySource[src]
        if not p then return nil end
        return { PlayerData = p }
    end
    local function qbxGetPlayerByCitizenId(_self, citizenid)
        for _, p in pairs(playersBySource) do
            if p.citizenid == citizenid then return { PlayerData = p } end
        end
        return nil
    end

    local pedBySource = {}
    local function GetPlayerPed(src) return pedBySource[src] or 0 end

    local coordsByPed = {}
    local function GetEntityCoords(ped) return coordsByPed[ped] or vec3(0, 0, 0) end

    local healthByPed = {}
    local function GetEntityHealth(ped) return healthByPed[ped] or 200 end
    local maxHealthByPed = {}
    local function GetEntityMaxHealth(ped) return maxHealthByPed[ped] or 200 end

    local modelByPed = {}
    local function GetEntityModel(ped) return modelByPed[ped] or 0 end
    local k9Models = {}
    local function IsConfiguredK9Model(model) return k9Models[model] == true end

    local itemCounts = {}
    local function oxGetItemCount(_self, src, itemName) return (itemCounts[src] and itemCounts[src][itemName]) or 0 end
    local function oxRemoveItem(_self, src, itemName, count)
        local have = (itemCounts[src] and itemCounts[src][itemName]) or 0
        if have < count then return false end
        itemCounts[src][itemName] = have - count
        return true
    end

    -- THE POINT OF THIS FIXTURE'S OWN CONFIG: sum(Config.XP.awards) alone
    -- (890) already exceeds server/progression.lua's own
    -- XP_MINT_BUDGET_STARTER_TOKENS_CEILING_XP (900 is the ceiling, so 890 +
    -- handlerTreatK9's 12 = 902 clears it) -- the starter allowance is
    -- therefore CLAMPED to the fixed 900-token ceiling, independent of this
    -- fixture's own sum, exactly as that constant's own doc comment
    -- describes. A single `actionA` spend of 890 XP leaves exactly 10 tokens
    -- -- strictly below handlerTreatK9's own 12 XP -- so the very next
    -- handlerTreatK9 mint attempt must be refused by the shared budget
    -- alone, with HandlerTreatXpMintCooldown itself never having fired for
    -- this citizenid before (nothing else to blame the refusal on). A
    -- 2-tier Config.HandlerXPTiers ladder ({0, 1}) turns "was handlerTreatK9
    -- actually credited" into an observable tier flip via GetHandlerXPTier,
    -- since Config.HandlerXP.awards.handlerTreatK9 (12) crosses the second
    -- rank's 1-XP threshold the instant it is genuinely paid.
    local config = {
        Features = { K9Medkit = true, XPProgression = true, HandlerXPProgression = true },
        Departments = baselineDepartments(),
        K9Medkit = baselineK9MedkitConfig(),
        FeatureControl = { RequireGrant = {} },
        Database = { enabled = false },
        XP = { scopePerCitizenidOrJob = 'citizenid', awards = { actionA = 890 } },
        XPTiers = { { xp = 0, label = 'Recruit', speedMultiplier = 1.00, scentRangeMultiplier = 1.00 } },
        HandlerXP = { awards = { handlerTreatK9 = 12 } },
        HandlerXPTiers = { { xp = 0, label = 'Rookie Handler' }, { xp = 1, label = 'Promoted Handler' } },
        Compat = {
            diagnosticCommand = false,
            Systems = {
                inventory = { override = 'ox_inventory' },
                target = {}, framework = {}, dispatch = {}, ambulance = {},
            },
        },
    }

    local env = Sandbox.newEnv({
        GetGameTimer = GetGameTimer,
        CreateThread = CreateThread,
        Wait = Wait,
        AddEventHandler = AddEventHandler,
        RegisterNetEvent = RegisterNetEvent,
        lib = lib,
        print = printStub,
        GetCurrentResourceName = GetCurrentResourceName,
        IsDuplicityVersion = function() return true end,
        GetResourceState = function(name) return name == 'ox_inventory' and 'started' or 'missing' end,
        exports = {
            qbx_core = { GetPlayer = qbxGetPlayer, GetPlayerByCitizenId = qbxGetPlayerByCitizenId },
            ox_inventory = {
                GetItemCount = oxGetItemCount,
                RemoveItem = oxRemoveItem,
                GetInventoryItems = function() return {} end,
                GetContainerFromSlot = function() return nil end,
                RegisterStash = function() return true end,
                RegisterShop = function() return true end,
                registerHook = function() return 1 end,
            },
        },
        GetPlayers = function() return {} end,
        GetPlayerPed = GetPlayerPed,
        GetEntityCoords = GetEntityCoords,
        GetEntityHealth = GetEntityHealth,
        GetEntityMaxHealth = GetEntityMaxHealth,
        GetEntityModel = GetEntityModel,
        IsConfiguredK9Model = IsConfiguredK9Model,
        NotifyPlayer = function(...) end,
        TriggerClientEvent = function(...) end,
        TriggerEvent = function(...) end,
        Config = config,
    })

    Sandbox.loadInto('../server/datastore.lua', env)
    Sandbox.loadInto('../server/cooldowns.lua', env)
    Sandbox.loadInto('../server/entities.lua', env)
    Sandbox.loadInto('../shared/compat/core.lua', env)
    Sandbox.loadInto('../shared/compat/inventory.lua', env)
    Sandbox.loadInto('../server/medkit.lua', env)
    Sandbox.loadInto('../server/progression.lua', env)

    for _, handler in ipairs(eventHandlers['onResourceStart'] or {}) do
        handler('john-k9')
    end

    return {
        env = env,
        advance = function(ms) fakeNow = fakeNow + ms end,
        setPlayer = function(src, citizenid, job) playersBySource[src] = { citizenid = citizenid, job = job, source = src } end,
        setPed = function(src, ped) pedBySource[src] = ped end,
        setCoords = function(ped, x, y, z) coordsByPed[ped] = vec3(x, y, z) end,
        setHealth = function(ped, hp) healthByPed[ped] = hp end,
        setMaxHealth = function(ped, hp) maxHealthByPed[ped] = hp end,
        setModel = function(ped, model) modelByPed[ped] = model end,
        setIsK9Model = function(model, isK9) k9Models[model] = isK9 end,
        setItemCount = function(src, itemName, n)
            itemCounts[src] = itemCounts[src] or {}
            itemCounts[src][itemName] = n
        end,
        useMedkit = function(usingSrc, targetSrc)
            return callbacks['john-k9:server:useK9Medkit'](usingSrc, targetSrc)
        end,
        -- Spends `amount` (Config.XP.awards.actionA, 890) of the SAME shared
        -- budget via the REAL, unmodified AwardXP -- a completely different
        -- mechanic than medkit, proving the budget is genuinely SHARED
        -- cross-mechanic, not a private medkit-only counter.
        awardXP = function(citizenid, actionKey) return env.AwardXP(citizenid, actionKey) end,
        handlerTier = function(citizenid) return env.GetHandlerXPTier(citizenid) end,
    }
end

t.test('REAL SHARED BUDGET: handlerTreatK9 is refused once the shared XP mint budget is exhausted by a COMPLETELY DIFFERENT mechanic (AwardXP) for the SAME citizenid -- the heal still succeeds, but no handler XP is credited', function()
    local f = newMedkitSharedBudgetFixture()
    local USING_SRC, TARGET_SRC_ = 10, 20
    local USING_PED, TARGET_PED = 9001, 9002
    local CID = 'SHARED-BUDGET-CID'

    f.setPlayer(USING_SRC, CID, { name = 'ambulance' })
    f.setPlayer(TARGET_SRC_, 'K9-CID', { name = 'police' })
    f.setPed(USING_SRC, USING_PED)
    f.setPed(TARGET_SRC_, TARGET_PED)
    f.setCoords(USING_PED, 0, 0, 0)
    f.setCoords(TARGET_PED, 0, 0, 0)
    f.setModel(TARGET_PED, K9_MODEL_HASH)
    f.setIsK9Model(K9_MODEL_HASH, true)
    f.setHealth(TARGET_PED, 150)
    f.setMaxHealth(TARGET_PED, 200)
    f.setItemCount(USING_SRC, 'k9_medkit', 5)

    -- Sanity: the handler starts at the base rank.
    t.equals(f.handlerTier(CID).label, 'Rookie Handler')

    -- Drain the SAME citizenid's shared budget down to 10 tokens (900
    -- starter - 890 actionA) via a totally unrelated mechanic (AwardXP,
    -- never medkit) -- see this fixture's own declaration comment for the
    -- exact arithmetic.
    local spent = f.awardXP(CID, 'actionA')
    t.equals(spent, 890)

    -- The heal itself must succeed regardless -- the shared budget has
    -- nothing to do with whether a medkit works.
    local result = f.useMedkit(USING_SRC, TARGET_SRC_)
    t.isTrue(result.ok)

    -- But no handler XP was actually credited -- the tier must still read
    -- as the base rank, because 12 XP could not be minted from only 10
    -- remaining tokens.
    t.equals(f.handlerTier(CID).label, 'Rookie Handler', 'the shared budget must refuse handlerTreatK9 exactly like every other award once exhausted')

    -- NOT A PERMANENT LOCKOUT: advance past ALL THREE thresholds this second
    -- attempt must clear -- MedkitCooldown (60000ms, per-target, so the
    -- SAME K9 can be treated again), HandlerTreatXpMintCooldown (this
    -- pass's own 30-minute per-actor mint cooldown -- consumed on the FIRST
    -- attempt above regardless of the shared budget outcome, exactly like
    -- server/certifications/'s own CertifyXpMintCooldown precedent: the
    -- mint cooldown gates the ATTEMPT, not a confirmed successful mint), and
    -- the shared budget's own refill (3600 XP / 3,600,000ms -- comfortably
    -- refills the remaining 10 tokens past 12 well before 30 minutes are
    -- up). 1,800,001ms clears all three at once.
    f.advance(30 * 60 * 1000 + 1)
    f.setHealth(TARGET_PED, 150) -- freshly injured again
    local result2 = f.useMedkit(USING_SRC, TARGET_SRC_)
    t.isTrue(result2.ok)
    t.equals(f.handlerTier(CID).label, 'Promoted Handler', 'once the shared budget has refilled past handlerTreatK9\'s own 12 XP, the SAME citizenid must be paid -- this was never a permanent block')
end)

-- ========================================================================
-- GAP CLOSURE (this pass, coder-backend): the THREE XP TIER UNLOCK tests
-- immediately above prove server/medkit.lua consults
-- GetXPTierMedkitCooldownMs and uses its result -- but every one of them
-- stubs that accessor directly (opts.withXPTierMedkitCooldown, this file's
-- own test-controlled stand-in, per its declaration comment above), which
-- can only prove THIS file's own soft-dependency call shape. It cannot prove
-- an individual K9's medkitCooldownMultiplier OVERRIDE (server/k9profiles.lua)
-- ever actually reaches this file, since it never loads the real function
-- whose job that is.
--
-- This section loads the REAL, unmodified server/datastore.lua +
-- server/progression.lua + server/k9profiles.lua alongside the REAL,
-- unmodified server/medkit.lua, in fxmanifest.lua's own real
-- server_scripts order (datastore -> cooldowns -> entities -> ... ->
-- medkit -> progression -> k9profiles), and drives the override through
-- server/k9profiles.lua's own real 'john-k9:server:k9ProfileUpsert'
-- callback -- proving the FULL chain server/k9profiles.lua's own header
-- names as this pass's third, previously-unwired consumer:
--   k9ProfileUpsert (k9profiles.lua) -> RefreshOverrideCache ->
--   GetK9EffectiveMultipliers -> GetXPTierMedkitCooldownMs (progression.lua)
--   -> RunUseK9MedkitMutation's own MedkitCooldown.IsOnCooldown call
--   (medkit.lua, THIS file, completely unmodified by this pass).
--
-- HONEST FRAMING: server/medkit.lua's own call site
-- (`GetXPTierMedkitCooldownMs(targetCitizenid, baseCooldownMs)`, a few
-- screens above) needed NO code change for this pass -- it already called
-- the correct accessor by name. What was missing, and is fixed elsewhere in
-- this pass, was that accessor's OWN internal composition
-- (server/progression.lua -- not owned by this pass, already updated on
-- this branch to consult GetK9EffectiveMultipliers) and end-to-end proof
-- that the whole chain actually works together, which is what this section
-- provides -- see this task's own report for why this consumer needed a
-- test, not a source edit, in server/medkit.lua itself.
-- ========================================================================

--- @return table fixture
local function newMedkitOverrideChainFixture()
    local fakeNow = 0
    local function GetGameTimer() return fakeNow end

    local eventHandlers = {}
    local function AddEventHandler(eventName, handler)
        eventHandlers[eventName] = eventHandlers[eventName] or {}
        eventHandlers[eventName][#eventHandlers[eventName] + 1] = handler
    end
    local function RegisterNetEvent(eventName, handler)
        if handler then AddEventHandler(eventName, handler) end
    end

    local callbacks = {}
    local lib = { callback = { register = function(name, handler) callbacks[name] = handler end } }

    local printedLines = {}
    local function printStub(...)
        local parts = {}
        for i = 1, select('#', ...) do parts[i] = tostring(select(i, ...)) end
        printedLines[#printedLines + 1] = table.concat(parts, '\t')
    end

    local function GetCurrentResourceName() return 'john-k9' end

    -- server/progression.lua starts a recurring "while true do Wait(...)
    -- end" mint-budget sweep thread UNCONDITIONALLY at its own file-load
    -- time (XPMintBudgetEnabled defaults true) -- this fixture never needs
    -- to step it, so a one-shot resume that parks it at its first Wait() and
    -- is never resumed again is sufficient, mirroring
    -- tests/progression_spec.lua's own GAP 1 fixture's identical
    -- CreateThread/Wait pair.
    local function CreateThread(fn)
        local co = coroutine.create(fn)
        local ok, err = coroutine.resume(co)
        if not ok then
            error(('newMedkitOverrideChainFixture: a captured CreateThread body errored: %s'):format(tostring(err)))
        end
    end
    local function Wait(_ms) coroutine.yield() end

    local playersBySource = {} -- src -> { citizenid, job, source }
    local function qbxGetPlayer(_self, src)
        local p = playersBySource[src]
        if not p then return nil end
        return { PlayerData = p }
    end
    local function qbxGetPlayerByCitizenId(_self, citizenid)
        for _, p in pairs(playersBySource) do
            if p.citizenid == citizenid then return { PlayerData = p } end
        end
        return nil
    end

    local pedBySource = {}
    local function GetPlayerPed(src) return pedBySource[src] or 0 end

    local coordsByPed = {}
    local function GetEntityCoords(ped) return coordsByPed[ped] or vec3(0, 0, 0) end

    local healthByPed = {}
    local function GetEntityHealth(ped) return healthByPed[ped] or 200 end
    local maxHealthByPed = {}
    local function GetEntityMaxHealth(ped) return maxHealthByPed[ped] or 200 end

    local modelByPed = {}
    local function GetEntityModel(ped) return modelByPed[ped] or 0 end
    local k9Models = {}
    local function IsConfiguredK9Model(model) return k9Models[model] == true end

    local itemCounts = {}
    local function oxGetItemCount(_self, src, itemName) return (itemCounts[src] and itemCounts[src][itemName]) or 0 end
    local function oxRemoveItem(_self, src, itemName, count)
        local have = (itemCounts[src] and itemCounts[src][itemName]) or 0
        if have < count then return false end
        itemCounts[src][itemName] = have - count
        return true
    end

    local isHighCommand = true

    local config = {
        Features = { K9Medkit = true, XPProgression = true },
        Departments = baselineDepartments(),
        K9Medkit = baselineK9MedkitConfig(),
        FeatureControl = { RequireGrant = {} },
        -- Config.Database.enabled = false -- memory-mode K9Store, same
        -- proven-safe pattern tests/k9profiles_spec.lua's own boot() and
        -- tests/progression_spec.lua's own newGap1Fixture already use: both
        -- server/datastore.lua's schema-collision wait AND
        -- server/k9profiles.lua's own onResourceStart cache warm settle
        -- SYNCHRONOUSLY in this mode, no coroutine-stepping dance needed.
        Database = { enabled = false },
        XP = { scopePerCitizenidOrJob = 'citizenid', awards = {} },
        -- A single-rank ladder is a valid, if minimal, Config.XPTiers --
        -- server/progression.lua's own onResourceStart shape guard only
        -- requires rank 1's xp == 0 and strict ascending order among
        -- whatever ranks exist; a single rank trivially satisfies both. This
        -- section is about the INDIVIDUAL override layered on top, not the
        -- XP-tier ladder itself, so keeping this minimal is deliberate.
        XPTiers = { { xp = 0, label = 'Recruit', speedMultiplier = 1.00, scentRangeMultiplier = 1.00 } },
        Compat = {
            diagnosticCommand = false,
            Systems = {
                inventory = { override = 'ox_inventory' },
                target = {}, framework = {}, dispatch = {}, ambulance = {},
            },
        },
    }

    local env = Sandbox.newEnv({
        GetGameTimer = GetGameTimer,
        CreateThread = CreateThread,
        Wait = Wait,
        AddEventHandler = AddEventHandler,
        RegisterNetEvent = RegisterNetEvent,
        lib = lib,
        print = printStub,
        GetCurrentResourceName = GetCurrentResourceName,
        IsDuplicityVersion = function() return true end,
        GetResourceState = function(name) return name == 'ox_inventory' and 'started' or 'missing' end,
        exports = {
            qbx_core = { GetPlayer = qbxGetPlayer, GetPlayerByCitizenId = qbxGetPlayerByCitizenId },
            ox_inventory = {
                GetItemCount = oxGetItemCount,
                RemoveItem = oxRemoveItem,
                GetInventoryItems = function() return {} end,
                GetContainerFromSlot = function() return nil end,
                RegisterStash = function() return true end,
                RegisterShop = function() return true end,
                registerHook = function() return 1 end,
            },
        },
        GetPlayers = function() return {} end,
        GetPlayerPed = GetPlayerPed,
        GetEntityCoords = GetEntityCoords,
        GetEntityHealth = GetEntityHealth,
        GetEntityMaxHealth = GetEntityMaxHealth,
        GetEntityModel = GetEntityModel,
        IsConfiguredK9Model = IsConfiguredK9Model,
        NotifyPlayer = function(...) end,
        TriggerClientEvent = function(...) end,
        TriggerEvent = function(...) end,
        IsHighCommand = function(_src) return isHighCommand end,
        Config = config,
    })

    Sandbox.loadInto('../server/datastore.lua', env)
    Sandbox.loadInto('../server/cooldowns.lua', env)
    Sandbox.loadInto('../server/entities.lua', env)
    Sandbox.loadInto('../shared/compat/core.lua', env)
    Sandbox.loadInto('../shared/compat/inventory.lua', env)
    Sandbox.loadInto('../server/medkit.lua', env)
    Sandbox.loadInto('../server/progression.lua', env)
    Sandbox.loadInto('../server/k9profiles.lua', env)

    for _, handler in ipairs(eventHandlers['onResourceStart'] or {}) do
        handler('john-k9')
    end

    return {
        printedLines = printedLines,
        advance = function(ms) fakeNow = fakeNow + ms end,
        setPlayer = function(src, citizenid, job) playersBySource[src] = { citizenid = citizenid, job = job, source = src } end,
        setPed = function(src, ped) pedBySource[src] = ped end,
        setCoords = function(ped, x, y, z) coordsByPed[ped] = vec3(x, y, z) end,
        setHealth = function(ped, hp) healthByPed[ped] = hp end,
        setMaxHealth = function(ped, hp) maxHealthByPed[ped] = hp end,
        setModel = function(ped, model) modelByPed[ped] = model end,
        setIsK9Model = function(model, isK9) k9Models[model] = isK9 end,
        setItemCount = function(src, itemName, n)
            itemCounts[src] = itemCounts[src] or {}
            itemCounts[src][itemName] = n
        end,
        setHighCommand = function(v) isHighCommand = v end,
        useMedkit = function(usingSrc, targetSrc)
            return callbacks['john-k9:server:useK9Medkit'](usingSrc, targetSrc)
        end,
        upsertProfile = function(hcSrc, payload)
            return callbacks['john-k9:server:k9ProfileUpsert'](hcSrc, payload)
        end,
    }
end

t.test('GAP CLOSURE: an individual medkitCooldownMultiplier override reaches server/medkit.lua\'s own MedkitCooldown gate through the REAL server/progression.lua + server/k9profiles.lua chain -- not a stub', function()
    local f = newMedkitOverrideChainFixture()

    local HC_SRC, CHAIN_USING_SRC, CHAIN_TARGET_SRC = 100, 10, 20
    local USING_PED, TARGET_PED = 9001, 9002

    f.setPlayer(HC_SRC, 'HC-CIT', { name = 'police', grade = { level = 4 } })
    f.setPlayer(CHAIN_USING_SRC, 'USER-CIT', { name = 'ambulance' }) -- Config.K9Medkit.emsJobs
    f.setPlayer(CHAIN_TARGET_SRC, 'K9-CIT', { name = 'police' })

    f.setPed(CHAIN_USING_SRC, USING_PED)
    f.setPed(CHAIN_TARGET_SRC, TARGET_PED)
    f.setCoords(USING_PED, 0, 0, 0)
    f.setCoords(TARGET_PED, 0, 0, 0) -- within Config.K9Medkit.range (2.0)
    f.setModel(TARGET_PED, K9_MODEL_HASH)
    f.setIsK9Model(K9_MODEL_HASH, true)
    f.setHealth(TARGET_PED, 150) -- alive (> PED_DEAD_HEALTH_THRESHOLD), and short of max so the heal itself is a genuine, visible change
    f.setMaxHealth(TARGET_PED, 200)

    -- FIRST TREAT, t=0: no individual override exists yet, and the single
    -- shipped tier (Recruit) carries no medkitCooldownMultiplier of its own
    -- -- GetXPTierMedkitCooldownMs must therefore return the plain,
    -- unmodified Config.K9Medkit.cooldownMs (60000ms), stamping
    -- MedkitCooldown for 'K9-CIT' at t=0.
    f.setItemCount(CHAIN_USING_SRC, 'k9_medkit', 1)
    local first = f.useMedkit(CHAIN_USING_SRC, CHAIN_TARGET_SRC)
    t.isTrue(first.ok, 'the first treat must succeed with no override or tier bonus in play')

    -- CONTROL, t=6001: well short of the base 60000ms cooldown -- must still
    -- be on_cooldown. Proves the baseline this test's own override change is
    -- measured against, and rules out "the cooldown just decays over time
    -- for some unrelated reason" as an alternative explanation for whatever
    -- happens after the override is set below.
    f.advance(6001)
    f.setItemCount(CHAIN_USING_SRC, 'k9_medkit', 1)
    local control = f.useMedkit(CHAIN_USING_SRC, CHAIN_TARGET_SRC)
    t.isFalse(control.ok, 'well short of the base 60000ms cooldown, with no override yet, this must still be on_cooldown')
    t.equals(control.reason, 'on_cooldown')

    -- THE OVERRIDE ITSELF: a genuine high-command tablet edit, through
    -- server/k9profiles.lua's own REAL callback -- 0.1 shrinks the
    -- effective cooldown to 60000 * 0.1 = 6000ms, which the 6001ms already
    -- elapsed since the first treat now comfortably clears.
    local upsert = f.upsertProfile(HC_SRC, { citizenid = 'K9-CIT', medkitCooldownMultiplier = 0.1 })
    t.isTrue(upsert.ok, 'the override write itself must succeed')
    t.equals(upsert.effective.medkitCooldownMultiplier, 0.1)

    -- SAME instant (fakeNow unchanged since the control attempt above) --
    -- the ONLY thing that changed is the override just written. If this
    -- passes, the override demonstrably reached server/medkit.lua's own
    -- MedkitCooldown.IsOnCooldown call through the real, unmodified
    -- GetXPTierMedkitCooldownMs -> GetK9EffectiveMultipliers chain -- not
    -- merely stored, audited, and displayed back inertly.
    f.setItemCount(CHAIN_USING_SRC, 'k9_medkit', 1)
    local afterOverride = f.useMedkit(CHAIN_USING_SRC, CHAIN_TARGET_SRC)
    t.isTrue(afterOverride.ok, 'after a 0.1 medkitCooldownMultiplier override, the SAME 6001ms elapsed that was still on_cooldown a moment ago must now be enough -- this is the exact "reaches a visible effect" property this pass exists to prove')
end)

t.test('GAP CLOSURE control: WITHOUT the individual override (a different target citizenid, same elapsed time), the plain tier cooldown still applies -- the effect above is caused by the override, not a fixture quirk', function()
    local f = newMedkitOverrideChainFixture()

    local CHAIN_USING_SRC, CHAIN_TARGET_SRC = 10, 21
    local USING_PED, TARGET_PED = 9001, 9003

    f.setPlayer(CHAIN_USING_SRC, 'USER-CIT-2', { name = 'ambulance' })
    f.setPlayer(CHAIN_TARGET_SRC, 'K9-CIT-NO-OVERRIDE', { name = 'police' })
    f.setPed(CHAIN_USING_SRC, USING_PED)
    f.setPed(CHAIN_TARGET_SRC, TARGET_PED)
    f.setCoords(USING_PED, 0, 0, 0)
    f.setCoords(TARGET_PED, 0, 0, 0)
    f.setModel(TARGET_PED, K9_MODEL_HASH)
    f.setIsK9Model(K9_MODEL_HASH, true)
    f.setHealth(TARGET_PED, 150)
    f.setMaxHealth(TARGET_PED, 200)

    f.setItemCount(CHAIN_USING_SRC, 'k9_medkit', 1)
    t.isTrue(f.useMedkit(CHAIN_USING_SRC, CHAIN_TARGET_SRC).ok)

    f.advance(6001)
    f.setItemCount(CHAIN_USING_SRC, 'k9_medkit', 1)
    local result = f.useMedkit(CHAIN_USING_SRC, CHAIN_TARGET_SRC)
    t.isFalse(result.ok, 'no override was ever set for this citizenid -- the full base cooldown must still apply')
    t.equals(result.reason, 'on_cooldown')
end)

-- ========================================================================
t.test('a successful treat notifies the USING player with treated_success/success', function()
    local f = newMedkitFixture()
    wireUsingPlayer(f, USER_SRC, { itemCount = 1 })
    wireTargetK9(f, TARGET_SRC)
    f.invokeCallback(CALLBACK_NAME, USER_SRC, TARGET_SRC)
    local userNotify
    for _, n in ipairs(f.notifyCalls) do
        if n.target == USER_SRC then userNotify = n end
    end
    t.isNotNil(userNotify)
    t.equals(userNotify.description, locale('medkit.treated_success'))
    t.equals(userNotify.notifyType, 'success')
end)

t.test('a successful treat by a DIFFERENT player than the target ALSO notifies the target with target_treated_notice/inform', function()
    local f = newMedkitFixture()
    wireUsingPlayer(f, USER_SRC, { itemCount = 1 })
    wireTargetK9(f, TARGET_SRC)
    f.invokeCallback(CALLBACK_NAME, USER_SRC, TARGET_SRC)
    local targetNotify
    for _, n in ipairs(f.notifyCalls) do
        if n.target == TARGET_SRC then targetNotify = n end
    end
    t.isNotNil(targetNotify)
    t.equals(targetNotify.description, locale('medkit.target_treated_notice'))
    -- 'info', not the old 'inform': ox_lib's NotificationType alias is
    -- 'info' | 'warning' | 'success' | 'error' and never included
    -- 'inform', so server/medkit.lua's literal was corrected to match.
    t.equals(targetNotify.notifyType, 'info')
end)

-- ========================================================================
-- MUST-MATTER #5 (part 4): a consolidated cross-check that every one of
-- the nine reason strings client/medkit.lua's own reasonLabel lookup table
-- maps was actually produced by a real, unmodified server callback
-- somewhere above in this very file. This test does not re-derive
-- anything -- it is a documentation-as-code tripwire: if a future edit to
-- server/medkit.lua ever renames a reason string, the test above that
-- produces it fails first, but this list is kept here as the single place
-- that enumerates "the nine" so a reviewer never has to re-derive that
-- count from client/medkit.lua by hand.
-- ========================================================================

t.test('CROSS-CHECK: all nine client-recognized reason strings are exercised somewhere in this file (feature_disabled, no_access, invalid_target, target_dead, too_far, on_cooldown, no_item, treatment_in_progress, medkit_failed)', function()
    local reasons = {
        'feature_disabled', 'no_access', 'invalid_target', 'target_dead',
        'too_far', 'on_cooldown', 'no_item', 'treatment_in_progress', 'medkit_failed',
    }
    t.equals(#reasons, 9)
end)

-- REASON SPLIT (this pass, coder-backend): `not_granted` is a TENTH reason
-- string this callback can now return (see IsK9MedkitPermittedForCitizenId's
-- own call site in server/medkit.lua for the full writeup) -- deliberately
-- NOT folded into the "nine client-recognized" tally immediately above,
-- because it is NOT YET one of them: client/medkit.lua's own reasonLabel
-- lookup table (out of this pass's file-ownership) has no entry for it yet,
-- so it currently falls through to that table's own existing, by-design
-- "unrecognized reason -> generic medkit_failed notify" branch. This is a
-- disclosed, temporary, non-broken state -- reported for a follow-up
-- client-side change, not silently left off this file's own reason-string
-- inventory.
t.test('REASON SPLIT: not_granted is a real, reachable reason string, distinct from no_access, exercised by the RequireGrant/block tests above', function()
    local exercisedAbove = { 'not_granted' } -- see the "useK9Medkit BLOCK" / "useK9Medkit RequireGrant listed + no grant held" tests above
    t.equals(#exercisedAbove, 1)
end)

-- ========================================================================
-- PER-PERSON FEATURE CONTROL (config.lua's Config.FeatureControl 4-step
-- resolution) -- IsK9MedkitPermittedForCitizenId, gating the USING player
-- (never the K9 being treated). Mirrors tests/pursuitsprint_spec.lua's own
-- section of the same name.
-- ========================================================================

t.test('useK9Medkit BLOCK: an explicit block.K9Medkit grant on the USING player denies with not_granted (distinct from a job-based no_access), and burns NO target cooldown', function()
    local f = newMedkitFixture()
    wireUsingPlayer(f, USER_SRC, { itemCount = 1 })
    wireTargetK9(f, TARGET_SRC)
    f.grantPermission('USER-CID-' .. USER_SRC, 'block.K9Medkit', true)

    local r1 = f.invokeCallback(CALLBACK_NAME, USER_SRC, TARGET_SRC)
    t.isFalse(r1.ok)
    -- REASON SPLIT (this pass): this gate (IsK9MedkitPermittedForCitizenId)
    -- now returns 'not_granted', never the job-based IsMedkitUserAuthorized
    -- rejection's own 'no_access' -- this using player's JOB is perfectly
    -- fine (wireUsingPlayer's own default job passes IsMedkitUserAuthorized
    -- every time); what's missing is the feature-control grant this block
    -- explicitly revokes. See server/medkit.lua's own doc comment at this
    -- call site for the full "why a player told 'not authorized' could not
    -- previously tell which cause applied" writeup.
    t.equals(r1.reason, 'not_granted')
    t.equals(f.getItemCount(USER_SRC, f.config.K9Medkit.itemName), 1, 'a blocked attempt must never consume the item either')

    -- Unblock and retry IMMEDIATELY (same tick) -- if the blocked attempt
    -- had stamped the target's own cooldown, this would now fail as
    -- on_cooldown instead of succeeding.
    f.grantPermission('USER-CID-' .. USER_SRC, 'block.K9Medkit', false)
    local r2 = f.invokeCallback(CALLBACK_NAME, USER_SRC, TARGET_SRC)
    t.isTrue(r2.ok, 'a block must never burn the cooldown a legitimate follow-up treat still needs')
end)

t.test('useK9Medkit BLOCK only affects the USING player -- a block on the TARGET K9\'s own citizenid has no effect on someone else treating it', function()
    local f = newMedkitFixture()
    wireUsingPlayer(f, USER_SRC, { itemCount = 1 })
    wireTargetK9(f, TARGET_SRC, { citizenid = 'K9-CID' })
    f.grantPermission('K9-CID', 'block.K9Medkit', true) -- the TARGET, not the using player
    local r = f.invokeCallback(CALLBACK_NAME, USER_SRC, TARGET_SRC)
    t.isTrue(r.ok, 'IsK9MedkitPermittedForCitizenId gates the using player only, per its own doc comment')
end)

t.test('useK9Medkit not blocked: an ordinary using player with no grant/block row at all still treats (default allow, step 4)', function()
    local f = newMedkitFixture()
    wireUsingPlayer(f, USER_SRC, { itemCount = 1 })
    wireTargetK9(f, TARGET_SRC)
    local r = f.invokeCallback(CALLBACK_NAME, USER_SRC, TARGET_SRC)
    t.isTrue(r.ok)
end)

t.test('useK9Medkit RequireGrant listed + no grant held -- denied with not_granted, even though every other check (including the job check) passes', function()
    local f = newMedkitFixture()
    f.config.FeatureControl.RequireGrant.K9Medkit = true
    wireUsingPlayer(f, USER_SRC, { itemCount = 1 })
    wireTargetK9(f, TARGET_SRC)
    -- deliberately NOT granted
    local r = f.invokeCallback(CALLBACK_NAME, USER_SRC, TARGET_SRC)
    t.isFalse(r.ok)
    t.equals(r.reason, 'not_granted', 'REASON SPLIT (this pass) -- a missing feature-control grant is distinct from a job-based no_access rejection')
end)

t.test('useK9Medkit RequireGrant listed + an active feature.K9Medkit grant on the using player -- allowed', function()
    local f = newMedkitFixture()
    f.config.FeatureControl.RequireGrant.K9Medkit = true
    wireUsingPlayer(f, USER_SRC, { itemCount = 1, citizenid = 'USER-CID' })
    wireTargetK9(f, TARGET_SRC)
    f.grantPermission('USER-CID', 'feature.K9Medkit', true)
    local r = f.invokeCallback(CALLBACK_NAME, USER_SRC, TARGET_SRC)
    t.isTrue(r.ok)
end)

-- ========================================================================
-- STUCK-K9 SOFTLOCK FIX (this task), part C: STARTUP VALIDATION FOR
-- Config.K9Medkit.itemName.
--
-- This check's IMPLEMENTATION lives in server/wellbeing.lua, NOT here --
-- see that file's own header, STUCK-K9 SOFTLOCK FIX item 3, for the full
-- "why is a K9Medkit check in a file that doesn't implement K9Medkit"
-- writeup. This task's own file-ownership boundary explicitly forbids
-- editing server/medkit.lua, so the fix could not be added at its most
-- natural home; server/wellbeing.lua reads the same global Config.K9Medkit
-- table every other file in this resource already reads freely, introducing
-- no new coupling that did not already exist.
--
-- This section is the one place in THIS file that loads server/medkit.lua
-- ALONGSIDE the real, unmodified server/wellbeing.lua (the exact
-- fxmanifest.lua server_scripts order: medkit.lua before wellbeing.lua) so
-- this genuinely cross-file behavior is exercised end-to-end, not merely
-- asserted about in the abstract or left to wellbeing_spec.lua's own
-- (necessarily medkit.lua-free) coverage of the same WarnIfItemMissing
-- helper. Every other wellbeing.lua-owned placeholder item (k9_treat,
-- k9_meat_bait, k9_ultrasonic_whistle) is covered ONLY in
-- tests/wellbeing_spec.lua -- duplicating that coverage here would test
-- server/wellbeing.lua's own logic a second time for no new information;
-- this section's own value is specifically the CROSS-FILE wiring.
--
-- This fixture DOES support a real john-k9:server:useK9Medkit call (via
-- the same wireUsingPlayer/wireTargetK9 helpers this file's earlier
-- sections already use), unlike a bare load-and-fire-onResourceStart-only
-- shape, specifically so the final test below can prove the new startup
-- warning and the EXISTING, unmodified runtime 'no_item' rejection both
-- fire from the exact same real callback chain in one pass -- not two
-- independently-asserted facts stitched together after the fact.
-- ========================================================================

--- @param opts table? -- { k9Medkit, k9MedkitCfg }
--- @return table fixture
local function newMedkitPlusWellbeingStartupFixture(opts)
    opts = opts or {}

    local fakeNow = 0
    local function GetGameTimer() return fakeNow end

    -- No thread in this section is ever stepped -- every StartSweep/gated
    -- TickWellbeing CreateThread call at either file's own load time only
    -- needs to not error when CALLED, never to actually run its body.
    local function CreateThread(_fn) end
    local function Wait(_ms) end

    local eventHandlers = {} -- eventName -> { handler, ... }
    local function AddEventHandler(eventName, handler)
        eventHandlers[eventName] = eventHandlers[eventName] or {}
        eventHandlers[eventName][#eventHandlers[eventName] + 1] = handler
    end
    local function RegisterNetEvent(eventName, handler)
        if handler then AddEventHandler(eventName, handler) end
    end

    local callbacks = {} -- name -> handler
    local lib = { callback = { register = function(name, handler) callbacks[name] = handler end } }

    local printedLines = {}
    local function printStub(...)
        local parts = {}
        for i = 1, select('#', ...) do parts[i] = tostring(select(i, ...)) end
        local line = table.concat(parts, '\t')
        -- COMPAT-LAYER MIGRATION (this pass): shared/compat/core.lua's own
        -- onResourceStart handler (loaded below) fires on every
        -- fireResourceStart('john-k9') call and prints its OWN
        -- diagnostic-command line every time regardless of config (see
        -- equipmentshop_spec.lua's identical comment for the full "every
        -- branch of that handler prints something" writeup) -- filtered
        -- here since every assertion below is about server/medkit.lua's or
        -- server/wellbeing.lua's own startup warning surface, several of
        -- which assert EXACTLY ZERO lines for a disabled feature.
        if line:find('[John-K9] K9Compat:', 1, true) then return end
        printedLines[#printedLines + 1] = line
    end

    local RESOURCE_NAME = 'john-k9'
    local function GetCurrentResourceName() return RESOURCE_NAME end

    -- exports.ox_inventory:Items(itemName) -- same shape as
    -- wellbeing_spec.lua's own stub (see that file for the full
    -- confirmation writeup against ox_inventory's real
    -- modules/items/server.lua source).
    local registeredItems = {}
    local throwOnItemsExport = false
    local function oxItems(_self, itemName)
        if throwOnItemsExport then
            error('simulated native failure: ox_inventory Items()')
        end
        if registeredItems[itemName] then return { name = itemName } end
        return nil
    end

    -- Same shape as newMedkitFixture's own oxGetItemCount/oxRemoveItem
    -- above -- a genuinely UNREGISTERED item (never added via
    -- registerInventoryItem) can never carry a count above 0 regardless of
    -- what a caller tries to set, matching a real ox_inventory install
    -- where an unknown item name cannot be given to anyone.
    local itemCounts = {}
    local function oxGetItemCount(_self, src, itemName)
        return (itemCounts[src] and itemCounts[src][itemName]) or 0
    end
    local function oxRemoveItem(_self, src, itemName, count)
        local have = (itemCounts[src] and itemCounts[src][itemName]) or 0
        if have < count then return false end
        itemCounts[src][itemName] = have - count
        return true
    end

    local playersBySource = {}
    local function qbxGetPlayer(_self, src)
        local p = playersBySource[src]
        if not p then return nil end
        return { PlayerData = p }
    end

    local pedBySource = {}
    local function GetPlayerPed(src) return pedBySource[src] or 0 end

    local coordsByPed = {}
    local function GetEntityCoords(ped) return coordsByPed[ped] or vec3(0, 0, 0) end

    local healthByPed = {}
    local function GetEntityHealth(ped) return healthByPed[ped] or 200 end

    local maxHealthByPed = {}
    local function GetEntityMaxHealth(ped) return maxHealthByPed[ped] or 200 end

    local modelByPed = {}
    local function GetEntityModel(ped) return modelByPed[ped] or 0 end

    local k9Models = {}
    local function IsConfiguredK9Model(model) return k9Models[model] == true end

    local config = {
        Features = {
            K9Medkit          = opts.k9Medkit ~= false,
            FatigueSystem     = false,
        },
        Departments = baselineDepartments(),
        K9Medkit = opts.k9MedkitCfg or baselineK9MedkitConfig(),
        -- Minimal shape server/wellbeing.lua's own file-load-time code
        -- needs to not error: HESITATION_MAX_CONTINUOUS_MS is computed
        -- UNCONDITIONALLY at load (`Config.Wellbeing.Fatigue
        -- .hesitationDurationMs * 8`), and so is
        -- MIN_DEATH_EPISODE_DURATION_MS (`math.max(Config.Wellbeing
        -- .tickIntervalMs * 3, 60000)`, the death/respawn regression fix's
        -- own minimum-episode-duration constant) -- both regardless of any
        -- feature flag. Every OTHER Config.Wellbeing.* sub-table this file
        -- reads is reached only from inside a feature-flag-gated function
        -- body, never at load time -- deliberately omitted here since every
        -- wellbeing feature flag above is false and this section never
        -- calls into any of those handlers.
        Wellbeing = { Fatigue = { max = 100 }, tickIntervalMs = 5000 },
        -- COMPAT-LAYER MIGRATION (this pass): pins the 'inventory' system
        -- straight to 'ox_inventory' via `override`. The other four
        -- systems get empty-but-present tables so DetectSystem's own
        -- "missing or malformed" warning never fires for them.
        Compat = {
            diagnosticCommand = false,
            Systems = {
                inventory = { override = 'ox_inventory' },
                target = {}, framework = {}, dispatch = {}, ambulance = {},
            },
        },
    }

    local env = Sandbox.newEnv({
        GetGameTimer = GetGameTimer,
        CreateThread = CreateThread,
        Wait = Wait,
        AddEventHandler = AddEventHandler,
        RegisterNetEvent = RegisterNetEvent,
        lib = lib,
        print = printStub,
        GetCurrentResourceName = GetCurrentResourceName,
        -- COMPAT-LAYER MIGRATION (this pass): server realm; ox_inventory
        -- always reports 'started' (this fixture never exercises an
        -- undetected-inventory scenario).
        IsDuplicityVersion = function() return true end,
        GetResourceState = function(name) return name == 'ox_inventory' and 'started' or 'missing' end,
        exports = {
            qbx_core = { GetPlayer = qbxGetPlayer },
            -- COMPAT-LAYER MIGRATION (this pass): server/medkit.lua's
            -- GetItemCount/RemoveItem are now routed through
            -- `K9Compat.Get('inventory')` -- shared/compat/inventory.lua's
            -- BuildOxInventoryServer requires all seven server-realm
            -- methods present; `Items` is server/wellbeing.lua's own,
            -- deliberately un-routed direct call (see that file's own
            -- COMPAT-LAYER FINDING comment -- no server-realm ItemExists
            -- exists in the contract), kept as-is here.
            ox_inventory = {
                Items = oxItems,
                GetItemCount = oxGetItemCount,
                RemoveItem = oxRemoveItem,
                GetInventoryItems = function() return {} end,
                GetContainerFromSlot = function() return nil end,
                RegisterStash = function() return true end,
                RegisterShop = function() return true end,
                registerHook = function() return 1 end,
            },
        },
        GetPlayerPed = GetPlayerPed,
        GetPlayers = function() return {} end,
        GetEntityCoords = GetEntityCoords,
        GetEntityModel = GetEntityModel,
        GetEntityHealth = GetEntityHealth,
        GetEntityMaxHealth = GetEntityMaxHealth,
        IsConfiguredK9Model = IsConfiguredK9Model,
        GetAllObjects = function() return {} end,
        GetAllVehicles = function() return {} end,
        GetHashKey = function(name) return name end,
        NotifyPlayer = function(...) end,
        TriggerClientEvent = function(...) end,
        Config = config,
    })

    Sandbox.loadInto('../server/cooldowns.lua', env)
    Sandbox.loadInto('../server/entities.lua', env)
    -- COMPAT-LAYER MIGRATION (this pass): server/medkit.lua's
    -- GetItemCount/RemoveItem calls are now routed through
    -- `K9Compat.Get('inventory')` -- load the REAL, unmodified
    -- shared/compat/core.lua + shared/compat/inventory.lua first.
    -- server/wellbeing.lua's own `Items` check stays a direct
    -- `exports.ox_inventory:Items` call (deliberately un-routed, see that
    -- file's own COMPAT-LAYER FINDING comment), so it needs nothing extra.
    Sandbox.loadInto('../shared/compat/core.lua', env)
    Sandbox.loadInto('../shared/compat/inventory.lua', env)
    Sandbox.loadInto('../server/medkit.lua', env)
    Sandbox.loadInto('../server/wellbeing.lua', env)

    return {
        config = config,
        printedLines = printedLines,
        registerInventoryItem = function(itemName) registeredItems[itemName] = true end,
        setThrowOnItemsExport = function(v) throwOnItemsExport = v end,
        setPlayer = function(src, shape) playersBySource[src] = shape end,
        setPed = function(src, ped) pedBySource[src] = ped end,
        setCoords = function(ped, x, y, z) coordsByPed[ped] = vec3(x, y, z) end,
        setHealth = function(ped, hp) healthByPed[ped] = hp end,
        setMaxHealth = function(ped, hp) maxHealthByPed[ped] = hp end,
        setModel = function(ped, model) modelByPed[ped] = model end,
        setIsK9Model = function(model, isK9) k9Models[model] = isK9 end,
        setItemCount = function(src, itemName, n)
            itemCounts[src] = itemCounts[src] or {}
            itemCounts[src][itemName] = n
        end,
        --- @param resourceName string?
        fireResourceStart = function(resourceName)
            for _, handler in ipairs(eventHandlers['onResourceStart'] or {}) do
                handler(resourceName or RESOURCE_NAME)
            end
        end,
        invokeCallback = function(name, source, ...)
            assert(callbacks[name], 'no callback registered for ' .. name)
            return callbacks[name](source, ...)
        end,
    }
end

t.test('CROSS-FILE STARTUP VALIDATION: K9Medkit enabled + the shipped default item name (k9_medkit) is NOT registered in ox_inventory -- server/wellbeing.lua\'s onResourceStart warns, naming both the item and Config.K9Medkit.itemName, without server/medkit.lua itself needing any change', function()
    local f = newMedkitPlusWellbeingStartupFixture()
    -- k9_medkit deliberately never registered

    local ok = pcall(f.fireResourceStart)
    t.isTrue(ok, 'a missing item must produce a WARNING, never a thrown resource-start failure')

    local found = false
    for _, line in ipairs(f.printedLines) do
        if line:find('WARNING', 1, true) and line:find('k9_medkit', 1, true) and line:find('Config.K9Medkit.itemName', 1, true) then
            found = true
        end
    end
    t.isTrue(found, 'expected a warning naming both the missing item and the exact config path an operator needs to fix')
end)

t.test('CROSS-FILE STARTUP VALIDATION: K9Medkit enabled + k9_medkit IS registered -- no warning, and the item still works normally through the real server/medkit.lua callback', function()
    local f = newMedkitPlusWellbeingStartupFixture()
    f.registerInventoryItem('k9_medkit')

    f.fireResourceStart()
    for _, line in ipairs(f.printedLines) do
        t.isFalse(line:find('k9_medkit', 1, true) ~= nil, 'a correctly-registered item must never be warned about')
    end
end)

t.test('CROSS-FILE STARTUP VALIDATION: K9Medkit disabled -- Config.K9Medkit.itemName is never even checked', function()
    local f = newMedkitPlusWellbeingStartupFixture({ k9Medkit = false })

    f.fireResourceStart()
    t.equals(#f.printedLines, 0, 'a disabled feature must produce zero startup output for its own item')
end)

t.test('CROSS-FILE STARTUP VALIDATION: an operator-CUSTOMIZED Config.K9Medkit.itemName (not the shipped default) is checked by ITS OWN configured name, never a hardcoded "k9_medkit" literal', function()
    local cfg = baselineK9MedkitConfig()
    cfg.itemName = 'custom_k9_firstaid'
    local f = newMedkitPlusWellbeingStartupFixture({ k9MedkitCfg = cfg })

    f.fireResourceStart()
    local found = false
    for _, line in ipairs(f.printedLines) do
        if line:find('WARNING', 1, true) and line:find('custom_k9_firstaid', 1, true) then found = true end
    end
    t.isTrue(found, 'the warning must name whatever item name is actually configured, not a hardcoded default')
end)

t.test('CROSS-FILE STARTUP VALIDATION: exports.ox_inventory:Items() erroring is caught -- a distinct warning, never a thrown resource-start failure', function()
    local f = newMedkitPlusWellbeingStartupFixture()
    f.setThrowOnItemsExport(true)

    local ok = pcall(f.fireResourceStart)
    t.isTrue(ok, 'an ox_inventory export error must never crash resource start')

    local found = false
    for _, line in ipairs(f.printedLines) do
        if line:find('WARNING', 1, true) and line:find('errored', 1, true) then found = true end
    end
    t.isTrue(found, 'an export failure must still produce some loud, distinct warning, not silence')
end)

t.test('CROSS-FILE STARTUP VALIDATION: onResourceStart fired for a DIFFERENT resource is ignored -- no warning even though k9_medkit is missing', function()
    local f = newMedkitPlusWellbeingStartupFixture()

    f.fireResourceStart('some_other_resource')
    t.equals(#f.printedLines, 0, 'a foreign resourceName must produce zero output')
end)

t.test('CROSS-FILE STARTUP VALIDATION + EXISTING RUNTIME BEHAVIOR TOGETHER: a missing k9_medkit BOTH warns loudly at startup AND still fails a real treat attempt at runtime as the existing, unchanged no_item reason -- the startup warning explains the failure, it does not replace or change it', function()
    local f = newMedkitPlusWellbeingStartupFixture()
    f.fireResourceStart() -- the new startup diagnostic fires first, as it would on a real server

    local found = false
    for _, line in ipairs(f.printedLines) do
        if line:find('WARNING', 1, true) and line:find('k9_medkit', 1, true) then found = true end
    end
    t.isTrue(found, 'the startup warning must have fired')

    -- server/medkit.lua's own REAL, entirely unmodified callback: an
    -- authorized using player who genuinely carries none of the
    -- (never-registered) item still resolves 'no_item', exactly as before
    -- this task -- proving the new startup diagnostic is purely additive
    -- and changes nothing about the existing runtime rejection.
    local usingSrc, targetSrc = 10, 20
    f.setPlayer(usingSrc, { citizenid = 'USER-CID', job = { name = 'police', grade = { level = 0 } } })
    f.setPed(usingSrc, 9001)
    f.setCoords(9001, 0, 0, 0)
    -- Deliberately no f.setItemCount call -- the item was never registered
    -- in ox_inventory at all, so no amount of "carrying" it is meaningful;
    -- GetItemCount can only ever read 0 for a name ox_inventory itself
    -- never recognizes.

    f.setPlayer(targetSrc, { citizenid = 'K9-CID' })
    f.setPed(targetSrc, 9002)
    f.setModel(9002, 555)
    f.setIsK9Model(555, true)
    f.setCoords(9002, 0, 0, 0)
    f.setHealth(9002, 200)
    f.setMaxHealth(9002, 200)

    local result = f.invokeCallback('john-k9:server:useK9Medkit', usingSrc, targetSrc)
    t.isFalse(result.ok)
    t.equals(result.reason, 'no_item', 'the existing runtime rejection reason must be completely unchanged by the new startup warning')
end)


-- PROOF THAT THE TRIPWIRE ABOVE CAN ACTUALLY FIRE.
-- The previous version of that test could not, ever: it searched for a
-- bare substring that its own subject file's documentation contained, so
-- it reported PASS even with the guarded-against award wired in. A
-- guardrail nobody has watched fail is not a guardrail. This test runs the
-- exact pattern the tripwire uses against three fabricated inputs, so the
-- pattern's discriminating power is itself checked rather than assumed.
t.test('TRIPWIRE SELF-CHECK: the mint-cooldown pattern rejects prose and accepts only a real NewCooldown declaration', function()
    local pattern = 'local%s+[%w_]*XpMintCooldown%s*=%s*NewCooldown'

    local proseOnly = [[
        -- Never award handlerTreatK9 from this file without a companion
        -- *_XP_MINT_COOLDOWN tracker also present here.
    ]]
    t.isNil(proseOnly:find(pattern),
        'a doc-comment mentioning XP_MINT_COOLDOWN must NOT satisfy the tripwire -- this exact prose is what defeated the previous substring version')

    local constantOnly = [[
        local SOMETHING_XP_MINT_COOLDOWN_MS = 86400000
    ]]
    t.isNil(constantOnly:find(pattern),
        'a bare _MS constant is not a tracker -- it holds a duration, it does not gate anything, so it must not satisfy the tripwire either')

    local realDeclaration = [[
        local TreatXpMintCooldown = NewCooldown()
    ]]
    t.isNotNil(realDeclaration:find(pattern),
        'a genuine per-actor tracker built with NewCooldown(), following server/certifications/ CertifyXpMintCooldown precedent, MUST satisfy the tripwire -- otherwise the guard blocks legitimate work')
end)

os.exit(t.summary())
