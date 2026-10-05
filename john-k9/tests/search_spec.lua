--[[
    tests/search_spec.lua

    Direct tests of server/search.lua's GetContrabandAlertTier(totalWeight)
    -- a thin resource-global pass-through to the file-local
    ResolveAlertTier, added specifically as a test/inspection seam (see that
    file's own FILE-TO-FILE CONTRACT and GetContrabandAlertTier's own doc
    comment for why this does not widen the file's trust boundary: it
    accepts a plain number, never resolves any entity/inventory/access
    state, and cannot be used to read any real target's contraband).

    Structurally identical in shape to server/progression.lua's
    GetXPTier/ResolveTier pair (already covered by progression_spec.lua) --
    same "walk ascending, keep the LAST tier whose threshold is met" logic,
    over Config.ContrabandAlertTiers instead of Config.XPTiers.

    Loading the whole file (not just the wrapper) means satisfying every
    native/global this file's OWN top-level (load-time) statements touch --
    NewMutex()/NewCooldown() (server/cooldowns.lua, loaded first, same
    order fxmanifest.lua requires), TargetSearchCooldown.StartSweep(...)
    (spins a CreateThread at load time), and lib.callback.register(...) (a
    real call this spec never fires -- captured and ignored, exactly like
    RegisterCommand/AddEventHandler elsewhere in this suite). None of this
    indirect stubbing affects GetContrabandAlertTier's own behavior -- it
    is only there because Sandbox.loadInto executes the whole file, per
    that fixture's own documented "immediately execute" behavior.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

-- ----------------------------------------------------------------------
-- Sandbox setup
-- ----------------------------------------------------------------------

local fakeNow = 0
local function GetGameTimer()
    return fakeNow
end

local eventHandlers = {}
local function AddEventHandler(eventName, handler)
    eventHandlers[eventName] = eventHandlers[eventName] or {}
    eventHandlers[eventName][#eventHandlers[eventName] + 1] = handler
end

local function GetCurrentResourceName()
    return 'john-k9'
end

local threadRunner = Sandbox.newThreadRunner()

-- server/search.lua's k9_search_log audit write runs inside its own ONE-SHOT
-- CreateThread(...) (silent-failure fix: MySQL.insert.await instead of a
-- callback-less MySQL.insert -- see that function's own SILENT-FAILURE FIX
-- comment). Sandbox.newThreadRunner's own CreateThread only CAPTURES a thread
-- for a later runner.step(), and this spec never calls step() -- so handing
-- that one-shot write to it would leave it never resumed and the audit row
-- never written, failing the assertions below for a pure harness reason
-- rather than a real one. Mirror tests/progression_spec.lua's own inlined
-- CreateThread instead: create the coroutine and resume it ONCE right away,
-- so a one-shot body (no Wait()) runs to completion on that single resume,
-- exactly as FXServer's real CreateThread would. A recurring
-- `while true do Wait(...) end` body (server/cooldowns.lua's load-time sweep)
-- still yields at its first Wait and is simply left parked there -- the same
-- place threadRunner.CreateThread left it before, since step() is never
-- called here either way. Wait still comes from threadRunner.
local function CreateThread(fn)
    local co = coroutine.create(fn)
    local ok, err = coroutine.resume(co)
    if not ok then
        error(('search_spec.lua: a CreateThread body errored: %s'):format(tostring(err)))
    end
end

local registeredCallbacks = {}
local libStub = {
    callback = {
        register = function(name, handler)
            registeredCallbacks[name] = handler
        end,
    },
}

local Config = {
    Features = {},
    SearchZones = { alertBroadcastRadius = 50.0, searchCooldownMs = 5000 },
    -- SPECIALIZATION CATEGORIES (owner-directed decluttering pass,
    -- 2026-08-26) -- 'weed_baggy' stays a bare array entry (UNCATEGORISED,
    -- every existing test in this file below already relies on it being
    -- found unconditionally). 'coke_brick'/'weapon_pistol' are ADDITIVE --
    -- categorised entries only this pass's own new specialization-category
    -- test section further below ever puts into a fake inventory; nothing
    -- else in this file references either name, so this does not disturb
    -- any pre-existing test's own contraband-weight math.
    SearchContrabandItems = { 'weed_baggy', coke_brick = 'narcotics', weapon_pistol = 'explosives' },
    K9Specializations = {
        narcotics  = { label = 'Narcotics detection' },
        explosives = { label = 'Explosives detection' },
        patrol     = { label = 'Patrol / apprehension' },
    },
    ContrabandAlertTiers = {
        { minWeight = 0,   alert = 'clean' },
        { minWeight = 1,   alert = 'whine' },
        { minWeight = 250, alert = 'aggressive_bark' },
    },
    -- COMPAT-LAYER MIGRATION (coder-backend, this pass): pins the
    -- 'inventory' system straight to 'ox_inventory' via `override`
    -- (shared/compat/core.lua's TIER 1, skipping the candidate-scanning
    -- walk). The other four systems get empty-but-present tables so
    -- DetectSystem's own "missing or malformed" warning never fires.
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
    AddEventHandler = AddEventHandler,
    GetCurrentResourceName = GetCurrentResourceName,
    CreateThread = CreateThread,
    Wait = threadRunner.Wait,
    lib = libStub,
    -- COMPAT-LAYER MIGRATION (this pass): server/search.lua's
    -- GetContainerFromSlot/GetInventoryItems calls are now routed through
    -- `K9Compat.Get('inventory')` -- shared/compat/inventory.lua's
    -- BuildOxInventoryServer requires ALL SEVEN server-realm methods
    -- present as callable exports before it returns ANYTHING.
    -- GetInventoryItems is reassigned to a real recording stub further
    -- below (this section's own tests populate it); the other five
    -- (GetContainerFromSlot/GetItemCount/RemoveItem/RegisterStash/
    -- RegisterShop -- never called by server/search.lua at all, except
    -- GetContainerFromSlot which this section's own tests never populate a
    -- nested container for) are harmless no-ops purely so capability
    -- verification passes.
    exports = {
        ox_inventory = {
            GetInventoryItems = function() return {} end,
            GetContainerFromSlot = function() return nil end,
            GetItemCount = function() return 0 end,
            RemoveItem = function() return false end,
            RegisterStash = function() return true end,
            RegisterShop = function() return true end,
            registerHook = function() return 1 end,
        },
    },
    Config = Config,
    -- COMPAT-LAYER MIGRATION (this pass): server realm; ox_inventory
    -- always reports 'started'.
    IsDuplicityVersion = function() return true end,
    GetResourceState = function(name) return name == 'ox_inventory' and 'started' or 'missing' end,
})

Sandbox.loadInto('../server/cooldowns.lua', env)
Sandbox.loadInto('../server/entities.lua', env) -- ResolveNetworkEntity/ResolveConnectedPlayerFromPed, read by search.lua per its own FILE-TO-FILE CONTRACT
-- server/datastore.lua -- REAL, unmodified, loaded alongside (this file's
-- own header: "the ONLY place in this resource that may name a `k9_*`
-- table or call `MySQL.*` directly" -- server/search.lua's own audit-log
-- write now reads through K9Store.SearchLog_Insert rather than a raw
-- `MySQL.insert.await` call). Config.Database is deliberately absent from
-- this fixture's Config table above -- K9Store's own DatabaseEnabled()
-- fails safe to `true` (real-DB mode) on a missing Config.Database, which
-- is exactly what makes SearchLog_Insert below run the SAME
-- MySQL.insert.await call (against `env.MySQL`, assigned further down
-- this file) that the audit write built directly before this migration,
-- so every existing assertion below keeps exercising the identical
-- SQL/params shape unchanged. See tests/admin_spec.lua for the precedent
-- this comment mirrors.
Sandbox.loadInto('../server/datastore.lua', env)
Sandbox.loadInto('../server/events.lua', env) -- FireOutboundEvent, extracted from six identical local copies into one shared helper; loaded in the real resource via fxmanifest, so a sandbox that omits it fails where the game would not
-- COMPAT-LAYER MIGRATION (this pass): server/search.lua's
-- GetContainerFromSlot/GetInventoryItems calls are now routed through
-- `K9Compat.Get('inventory')` -- load the REAL, unmodified
-- shared/compat/core.lua + shared/compat/inventory.lua first (never a
-- hand-written fake translation layer).
Sandbox.loadInto('../shared/compat/core.lua', env)
Sandbox.loadInto('../shared/compat/inventory.lua', env)
Sandbox.loadInto('../server/search.lua', env)

-- Fire onResourceStart: search.lua's own config-safety guards (the
-- ContrabandAlertTiers[1] == clean/minWeight==0 assertion, the sorted-order
-- assertion, and the alertBroadcastRadius <= 200.0 ceiling) all run here --
-- a real regression in this spec's OWN Config fixture would surface as a
-- loud assertion failure right at this line, not a silent mismatch later.
for _, handler in ipairs(eventHandlers['onResourceStart'] or {}) do
    handler('john-k9')
end

local GetContrabandAlertTier = env.GetContrabandAlertTier
t.isNotNil(GetContrabandAlertTier, 'server/search.lua must define global GetContrabandAlertTier')
t.isNotNil(registeredCallbacks['john-k9:server:searchTarget'],
    'server/search.lua must register its lib.callback handler at load time (sanity check that the whole file loaded, not just the wrapper)')

-- ----------------------------------------------------------------------
-- Tier-boundary resolution
-- ----------------------------------------------------------------------

t.test('GetContrabandAlertTier: totalWeight = 0 resolves to the mandatory clean baseline', function()
    t.equals(GetContrabandAlertTier(0).alert, 'clean')
end)

t.test('GetContrabandAlertTier: exactly AT a tier threshold (>=) resolves to that tier, not the one below', function()
    t.equals(GetContrabandAlertTier(1).alert, 'whine', 'totalWeight == 1 must reach whine, the tier whose minWeight is exactly 1')
    t.equals(GetContrabandAlertTier(250).alert, 'aggressive_bark', 'totalWeight == 250 must reach aggressive_bark')
end)

t.test('GetContrabandAlertTier: one unit below a threshold stays on the lower tier', function()
    t.equals(GetContrabandAlertTier(0.999).alert, 'clean', 'just under 1 must not reach whine')
    t.equals(GetContrabandAlertTier(249).alert, 'whine', 'just under 250 must not reach aggressive_bark')
end)

t.test('GetContrabandAlertTier: a very large totalWeight resolves to the top tier, not the first match', function()
    t.equals(GetContrabandAlertTier(999999).alert, 'aggressive_bark')
end)

t.test('GetContrabandAlertTier: a negative totalWeight (defensive input) still resolves to the clean baseline, never nil', function()
    local tier = GetContrabandAlertTier(-5)
    t.isNotNil(tier)
    t.equals(tier.alert, 'clean')
end)

-- ----------------------------------------------------------------------
-- HandleSearchTarget / searchTarget callback -- full end-to-end drive,
-- ContrabandXpMintCooldown gate (coder-backend, XP-farm-audit pass).
--
-- Everything above this point only ever exercised the pure
-- GetContrabandAlertTier seam. This section additionally stubs every
-- native/export HandleSearchTarget's own VEHICLE branch touches
-- (ResolveNetworkEntity's own natives via server/entities.lua, already
-- loaded above; GetVehicleNumberPlateText; GetPlayerPed/GetEntityCoords,
-- backed by a minimal vector3-with-metatables so `#(a - b)` behaves exactly
-- like the real FXServer vector3 type for the purposes of the proximity
-- check; exports.ox_inventory.GetInventoryItems; exports.qbx_core.GetPlayer;
-- MySQL.insert; TriggerEvent/TriggerClientEvent; AwardXP) so the REAL
-- 'john-k9:server:searchTarget' callback captured above can be invoked
-- end-to-end, never a re-implementation of its logic. Only the 'vehicle'
-- targetType is driven (the 'person' branch's extra
-- ResolveConnectedPlayerFromPed step is orthogonal to the XP-mint gate this
-- section tests and adds no coverage value here).
-- ----------------------------------------------------------------------

local function vec3(x, y, z)
    local v = { x = x, y = y, z = z }
    return setmetatable(v, {
        __sub = function(a, b) return vec3(a.x - b.x, a.y - b.y, a.z - b.z) end,
        __len = function(self) return math.sqrt(self.x * self.x + self.y * self.y + self.z * self.z) end,
    })
end
local ZERO_VEC = vec3(0, 0, 0)

local awardCalls = {}
local mysqlInsertCount = 0
local triggerEventCount = 0
local triggerClientEventCount = 0
local currentItemsByInvId = {}

env.HasK9Access = function() return true end
env.NetworkGetEntityFromNetworkId = function(netId) return netId end -- identity mapping: this section's fake "entity handle" IS the netId
env.DoesEntityExist = function(entity) return entity ~= 0 end
env.GetEntityType = function(_entity) return 2 end -- every entity in this section is a vehicle
env.GetVehicleNumberPlateText = function(entity) return 'PLATE' .. tostring(entity) end
env.GetPlayerPed = function(_source) return 42 end -- fixed nonzero ped handle for every source; irrelevant to the proximity math below since GetEntityCoords is constant for every handle
env.GetEntityCoords = function(_entity) return ZERO_VEC end -- every entity (requester ped AND searched vehicle) reports the same coords -- proximity distance is always 0, well under any maxDistance/alertBroadcastRadius configured below

-- SEARCHER-BUSY GUARD (server-side half of client/search.lua's own
-- IsBusyWithSomethingElse(), commit a32a554 -- see server/search.lua's own
-- IsSearcherBusyElsewhere doc comment for the full writeup). `requesterInVehicle`
-- defaults false so every EXISTING test in this section (written before this
-- guard existed) keeps exercising the exact same "requester not in a
-- vehicle" path it always has -- only the two dedicated SEARCHER-BUSY GUARD
-- tests further below flip it. `env.IsK9CurrentlyHolding` is DELIBERATELY
-- left undefined here (never assigned in this shared section) -- this is
-- the REAL current production state (server/combat.lua has not defined this
-- accessor yet; see this file's own FILE-TO-FILE CONTRACT header), and every
-- existing test below must keep passing with the soft dependency genuinely
-- absent, not merely stubbed to return false. The dedicated
-- "K9ActiveEffect[source] set" test further below assigns and then restores
-- (sets back to nil) this exact global, rather than pre-declaring a stub
-- here, specifically to prove BOTH states -- absent, and present-and-true --
-- are handled correctly.
local requesterInVehicle = false
env.IsPedInAnyVehicle = function(_ped, _atGetIn) return requesterInVehicle end
env.GetPlayers = function() return { '501' } end -- one fixed bystander id for BroadcastContrabandAlert's own loop, resolved via the same fixed GetPlayerPed stub above
env.TriggerEvent = function(_eventName, ...) triggerEventCount = triggerEventCount + 1 end -- FireOutboundEvent's outbound 'john-k9:events:searchCompleted'
env.TriggerClientEvent = function(eventName, _playerId, ...)
    if eventName == 'john-k9:client:playContrabandAlert' then
        triggerClientEventCount = triggerClientEventCount + 1
    end
end
env.MySQL = { insert = { await = function(_sql, _params) mysqlInsertCount = mysqlInsertCount + 1; return 1 end } } -- .await shape: search.lua's audit write is now CreateThread + MySQL.insert.await (silent-failure fix), not a callback-less MySQL.insert
env.AwardXP = function(citizenid, actionKey) awardCalls[#awardCalls + 1] = { citizenid = citizenid, actionKey = actionKey } end

-- SPECIALIZATION CATEGORIES (owner-directed decluttering pass, 2026-08-26)
-- -- controllable stand-in for server/certifications/'s real
-- HasSpecialization, same "plain mutable state + setter" shape as this
-- section's own `requesterInVehicle` above. Defaults to NOTHING held for
-- any citizenid -- every pre-existing test in this section keeps exercising
-- exactly what it always has, since 'weed_baggy' (the only item those
-- tests ever seed) is UNCATEGORISED and therefore never consults this at
-- all.
local specializationGrants = {} -- [citizenid][specKey] = true/false
env.HasSpecialization = function(citizenid, _jobName, specKey)
    return specializationGrants[citizenid] ~= nil and specializationGrants[citizenid][specKey] == true
end
local function grantSpecialization(citizenid, specKey, value)
    specializationGrants[citizenid] = specializationGrants[citizenid] or {}
    specializationGrants[citizenid][specKey] = value
end

local exportsStub = env.exports
exportsStub.ox_inventory.GetInventoryItems = function(_self, invOrId)
    local invId = type(invOrId) == 'table' and invOrId.id or invOrId
    return currentItemsByInvId[invId] or {}
end
exportsStub.qbx_core = {
    GetPlayer = function(_self, source)
        return { PlayerData = { citizenid = 'CITIZEN' .. tostring(source), job = { name = 'police' } } }
    end,
}

-- Config for this section only -- overrides/extends the shared Config table
-- above. Values chosen to make TargetSearchCooldown/SearchCooldown (both
-- 10ms) trivially clearable by advancing `fakeNow` a little, so the ONLY
-- meaningful throttle left in play across this section's test timeline is
-- CONTRABAND_XP_MINT_COOLDOWN_MS (60000ms, a server/search.lua file-local
-- constant, never read from Config -- see that constant's own declaration
-- comment for why).
Config.Features.SearchZones = true
Config.Features.XPProgression = true
Config.Features.ContrabandAlerts = true -- so this section can also assert the alert broadcast keeps firing independently of the XP-mint gate below
Config.SearchZones.sniffAnimDurationMs = 10
Config.SearchZones.searchCooldownMs = 10 -- overrides the 5000 set above -- this section's own per-target cooldown, not the XP mint gate
Config.SearchZones.vehicleSearchDistance = 100.0
Config.SearchZones.personSearchDistance = 100.0
Config.XP = { awards = { searchContrabandFound = 25 } }

local searchTargetCallback = registeredCallbacks['john-k9:server:searchTarget']

--- Drives one full 'vehicle' searchTarget call. `netId` doubles as this
--- section's fake resolved entity handle (see NetworkGetEntityFromNetworkId
--- stub above) and feeds GetVehicleNumberPlateText's stub, so each distinct
--- netId is a distinct, independently-cooldown-tracked vehicle identity.
--- @param source number
--- @param netId number
--- @param weight number -- 0/nil = an empty trunk (contrabandFound = false); > 0 = one 'weed_baggy' slot of exactly this weight
--- @return table result -- the real HandleSearchTarget return value
local function searchVehicle(source, netId, weight)
    local invId = 'trunkPLATE' .. tostring(netId)
    if weight and weight > 0 then
        currentItemsByInvId[invId] = { { name = 'weed_baggy', weight = weight, slot = 1 } }
    else
        currentItemsByInvId[invId] = {}
    end
    return searchTargetCallback(source, 'vehicle', netId)
end

t.test('a fresh target always pays on its first find, and the search/audit/alert side effects all fire', function()
    fakeNow = 0
    local mysqlBefore, triggerBefore, alertBefore = mysqlInsertCount, triggerEventCount, triggerClientEventCount
    local result = searchVehicle(501, 1001, 10)
    t.isTrue(result.ok, 'a valid, in-range, first-ever search of this target must succeed')
    t.isTrue(result.contrabandFound)
    t.equals(result.totalWeight, 10, 'the requester must see the real, current weight')
    t.equals(#awardCalls, 1)
    t.equals(awardCalls[1].actionKey, 'searchContrabandFound')
    t.equals(mysqlInsertCount, mysqlBefore + 1, 'k9_search_log audit row must be written')
    t.equals(triggerEventCount, triggerBefore + 1, 'the john-k9:events:searchCompleted outbound event must fire')
    t.equals(triggerClientEventCount, alertBefore + 1, 'the contraband alert broadcast must fire for a non-clean tier')
end)

t.test('CONSTRAINT CHECK: toggling the weight while the mint cooldown is still active still returns a fully normal search/alert/audit -- only the XP mint is withheld', function()
    fakeNow = 1000 -- clears the 10ms sniff/target cooldowns; nowhere near the 60000ms mint cooldown armed at fakeNow=0 by the previous test
    local mysqlBefore, triggerBefore, alertBefore, awardsBefore = mysqlInsertCount, triggerEventCount, triggerClientEventCount, #awardCalls
    local result = searchVehicle(501, 1001, 20) -- toggled: weight changed 10 -> 20, exactly the solo-farm exploit shape this gate closes
    t.isTrue(result.ok, 'search itself must keep succeeding while the XP mint is on cooldown')
    t.isTrue(result.contrabandFound, 'contraband must still be reported to the requester')
    t.equals(result.totalWeight, 20, 'the requester must still see the real, current (changed) weight -- never withheld alongside the XP')
    t.equals(#awardCalls, awardsBefore, 'no additional AwardXP call: the per-searcher mint cooldown blocks a second real weight-changed find inside its window')
    t.equals(mysqlInsertCount, mysqlBefore + 1, 'the k9_search_log audit row must still be written for this attempt even though XP was withheld')
    t.equals(triggerEventCount, triggerBefore + 1, 'the outbound searchCompleted event must still fire')
    t.equals(triggerClientEventCount, alertBefore + 1, 'the contraband alert broadcast must still fire -- this gate must never touch it')
end)

t.test('past the mint cooldown window, the still-differing weight now pays -- the earlier skipped attempt was never silently treated as paid', function()
    fakeNow = 61000 -- 61s after the FIRST award at fakeNow=0, past CONTRABAND_XP_MINT_COOLDOWN_MS (60000ms)
    local awardsBefore = #awardCalls
    local result = searchVehicle(501, 1001, 20) -- same weight as the BLOCKED attempt above (20), but still differs from the last PAID weight (10)
    t.isTrue(result.ok)
    t.equals(result.totalWeight, 20)
    t.equals(#awardCalls, awardsBefore + 1, 'ContrabandXpState was correctly left unupdated by the skipped attempt, so this still reads as "changed since last PAID weight" and pays once the mint cooldown allows')
end)

t.test('immediately toggling again right after that payout is blocked by the freshly re-armed mint cooldown', function()
    fakeNow = 61010
    local awardsBefore = #awardCalls
    local result = searchVehicle(501, 1001, 30)
    t.isTrue(result.ok)
    t.equals(result.totalWeight, 30)
    t.equals(#awardCalls, awardsBefore, 'freshly re-armed at fakeNow=61000 by the previous payout; another payout this soon must be blocked again')
end)

t.test('an unchanged-weight repeat never spends the mint budget: a later real change still pays at exactly the ORIGINAL cooldown expiry, not a later one', function()
    fakeNow = 0
    local netId = 2002
    local awardsBefore = #awardCalls
    local first = searchVehicle(502, netId, 5)
    t.isTrue(first.ok)
    t.equals(#awardCalls, awardsBefore + 1, 'first-ever find on this fresh target pays')

    -- Three unchanged-weight re-searches at various points inside the mint
    -- cooldown window the award above just opened. None of these should pay
    -- (weight never changed since the last PAID weight) -- and, if the
    -- ordering in server/search.lua's AwardXP block is correct (weight-
    -- changed check BEFORE ContrabandXpMintCooldown.Consume), none of them
    -- should re-arm/extend that cooldown either.
    fakeNow = 50
    searchVehicle(502, netId, 5)
    fakeNow = 100
    searchVehicle(502, netId, 5)
    fakeNow = 59000
    searchVehicle(502, netId, 5)
    t.equals(#awardCalls, awardsBefore + 1, 'no unchanged-weight repeat may ever pay')

    -- Exactly one tick past the ORIGINAL mint cooldown (armed at fakeNow=0,
    -- +60000ms), a real weight change arrives. If any of the three no-op
    -- searches above had incorrectly re-touched the mint cooldown, this
    -- would still read as blocked (not expiring until 59000+60000=119000).
    -- It must instead have expired at exactly fakeNow=60000.
    fakeNow = 60001
    local changed = searchVehicle(502, netId, 15)
    t.isTrue(changed.ok)
    t.equals(changed.totalWeight, 15)
    t.equals(#awardCalls, awardsBefore + 2,
        'a real weight change must pay exactly when the cooldown opened by the FIRST award expires -- proves the unchanged-weight repeats above never extended it')
end)

t.test("the mint cooldown is keyed by the SEARCHER, not the target: a second, different officer is never blocked by the first officer's own budget", function()
    fakeNow = 0
    local netId = 5005
    local awardsBefore = #awardCalls
    local resultA = searchVehicle(701, netId, 8) -- officer 701's first paid find on this fresh target
    t.isTrue(resultA.ok)
    t.equals(#awardCalls, awardsBefore + 1)

    fakeNow = 20 -- clears the 10ms target/sniff cooldowns; nowhere near officer 701's own 60000ms mint cooldown
    local resultB = searchVehicle(702, netId, 9) -- a DIFFERENT officer, weight genuinely changed since the last PAID weight (8 -> 9)
    t.isTrue(resultB.ok)
    t.equals(#awardCalls, awardsBefore + 2, "a second, different officer must not be blocked by the first officer's own per-searcher mint cooldown")
end)

-- ----------------------------------------------------------------------
-- SEARCHER-BUSY GUARD -- server-side half of client/search.lua's own
-- IsBusyWithSomethingElse() (commit a32a554). See server/search.lua's
-- IsSearcherBusyElsewhere doc comment for the full writeup: a modified
-- client never runs client/search.lua's guard at all, so these two checks
-- are the actual enforcement.
-- ----------------------------------------------------------------------

t.test('SEARCHER-BUSY GUARD: a K9 currently seated in a vehicle is rejected with searcher_in_vehicle, before any inventory read/cooldown stamp', function()
    fakeNow = 100000 -- a source/netId pair never used elsewhere in this section
    local mysqlBefore = mysqlInsertCount
    requesterInVehicle = true
    local result = searchVehicle(801, 8008, 10)
    requesterInVehicle = false

    t.isFalse(result.ok)
    t.equals(result.reason, 'searcher_in_vehicle')
    t.equals(mysqlInsertCount, mysqlBefore, 'a searcher-busy rejection must never reach the real inventory read/audit log -- it is cheaper than even step 1')

    -- Proves the rejection above genuinely happened BEFORE either cooldown
    -- was stamped (STEP 0 runs before TargetSearchCooldown/SearchCooldown
    -- are ever touched): the SAME source, SAME target, one tick later
    -- (nowhere near any real cooldown window), now NOT in a vehicle, must
    -- succeed normally -- if the busy-rejection had incorrectly stamped a
    -- cooldown anyway, this would read on_cooldown instead.
    fakeNow = 100001
    local followUp = searchVehicle(801, 8008, 10)
    t.isTrue(followUp.ok, 'a prior searcher-busy rejection must never leave a stray cooldown stamp behind')
end)

t.test('SEARCHER-BUSY GUARD: not in a vehicle and IsK9CurrentlyHolding undefined (the real current production state, server/combat.lua has not defined it yet) never blocks', function()
    t.isNil(env.IsK9CurrentlyHolding, 'sanity check: this global must genuinely be undefined for this assertion to mean anything')
    fakeNow = 100010
    -- Fresh source (never 801 -- that one is still inside its own flat
    -- SearchCooldown window from the prior test, only 9ms earlier against a
    -- 10ms sniffAnimDurationMs) so this assertion is never confounded by an
    -- unrelated cooldown rejection.
    local result = searchVehicle(804, 8010, 10)
    t.isTrue(result.ok, 'the soft dependency being absent must degrade to "not busy", never to an error')
end)

t.test('SEARCHER-BUSY GUARD: IsK9CurrentlyHolding available and true is rejected with searcher_engaged, before any inventory read/cooldown stamp', function()
    fakeNow = 100020
    local mysqlBefore = mysqlInsertCount
    env.IsK9CurrentlyHolding = function(_holderSrc) return true end
    local result = searchVehicle(802, 8020, 10)
    env.IsK9CurrentlyHolding = nil -- restore the "undefined" default for every later test in this file

    t.isFalse(result.ok)
    t.equals(result.reason, 'searcher_engaged')
    t.equals(mysqlInsertCount, mysqlBefore, 'a searcher-busy rejection must never reach the real inventory read/audit log')
end)

t.test('SEARCHER-BUSY GUARD: IsK9CurrentlyHolding available and false does not block (only a TRUE result does)', function()
    fakeNow = 100030
    env.IsK9CurrentlyHolding = function(_holderSrc) return false end
    local result = searchVehicle(803, 8030, 10)
    env.IsK9CurrentlyHolding = nil -- restore the "undefined" default for every later test in this file

    t.isTrue(result.ok)
end)

t.test('SEARCHER-BUSY GUARD, INCIDENT REGRESSION: IsPedInAnyVehicle undefined (a test sandbox that has not stubbed this native, e.g. tests/coopsearchbonus_spec.lua before this fix) degrades to "not busy", never to a thrown error', function()
    -- This native is ALWAYS present on a real FXServer (see
    -- IsSearcherBusyElsewhere's own INCIDENT FIX comment) -- this test
    -- proves the ONLY scenario this guard actually matters for: a Lua test
    -- sandbox that never stubbed it. Genuinely undefine it here (not merely
    -- stub it to return false) to prove the guard, not just the outcome.
    local originalIsPedInAnyVehicle = env.IsPedInAnyVehicle
    env.IsPedInAnyVehicle = nil
    fakeNow = 100040
    local ok, result = pcall(searchVehicle, 805, 8040, 10)
    env.IsPedInAnyVehicle = originalIsPedInAnyVehicle

    t.isTrue(ok, 'IsPedInAnyVehicle being undefined must never throw a raw Lua error out of the search callback: ' .. tostring(result))
    t.isTrue(ok and result.ok, 'the native being undefined must degrade to "not busy" and let the search proceed, never refuse it')
end)

-- ----------------------------------------------------------------------
-- SearchMutex re-entrancy -- does a SECOND searchTarget request from the
-- SAME source, arriving while the FIRST is genuinely mid-flight (yielded
-- on the ox_inventory read, exactly like a real uncached vehicle-trunk lazy
-- DB load per this file's own extensive doc comment on that scenario),
-- actually get rejected? And is the mutex fully released once the first
-- completes, rather than left permanently stuck held? Direct evidence, not
-- reasoning-only: this drives the REAL, unmodified searchTarget callback
-- across a real coroutine suspend/resume boundary.
-- ----------------------------------------------------------------------

t.test('SearchMutex: a second request from the SAME source while the first is genuinely mid-flight is rejected with search_in_progress, and the mutex is fully released once the first completes', function()
    fakeNow = 300000
    local netId = 9001
    local invId = 'trunkPLATE' .. tostring(netId)
    currentItemsByInvId[invId] = { { name = 'weed_baggy', weight = 5, slot = 1 } }

    -- Make GetInventoryItems for this one test yield ONCE, so the first
    -- request's own HandleSearchTarget genuinely suspends mid-flight --
    -- exactly the real uncached-vehicle-trunk lazy-DB-load scenario
    -- server/search.lua's own doc comment (right above its pcall-wrapped
    -- GetInventoryItems call site) describes as the genuine reason this
    -- mutex exists at all.
    local originalGetInventoryItems = exportsStub.ox_inventory.GetInventoryItems
    exportsStub.ox_inventory.GetInventoryItems = function(_self, invOrId)
        coroutine.yield()
        local invId2 = type(invOrId) == 'table' and invOrId.id or invOrId
        return currentItemsByInvId[invId2] or {}
    end

    local firstResult
    local co = coroutine.create(function()
        firstResult = searchTargetCallback(901, 'vehicle', netId)
    end)
    local resumeOk, resumeErr = coroutine.resume(co)
    t.isTrue(resumeOk, 'first request must suspend cleanly at the stubbed yield point: ' .. tostring(resumeErr))
    t.equals(coroutine.status(co), 'suspended', 'the first request must genuinely be mid-flight (yielded), not already finished')

    -- SECOND request, SAME source, fired while the first is STILL suspended
    -- mid-flight. SearchMutex.TryAcquire is a synchronous check-then-set --
    -- this call must return immediately (never yield) with search_in_progress.
    local secondResult = searchTargetCallback(901, 'vehicle', netId)
    t.isFalse(secondResult.ok)
    t.equals(secondResult.reason, 'search_in_progress', 'the mutex must reject a second request from the same source while the first is genuinely mid-flight')

    -- Let the first request run to completion.
    local resumeOk2, resumeErr2 = coroutine.resume(co)
    t.isTrue(resumeOk2, 'first request must complete cleanly once resumed: ' .. tostring(resumeErr2))
    t.equals(coroutine.status(co), 'dead')
    t.isTrue(firstResult.ok, 'the first request itself must have succeeded normally, unaffected by the rejected second one')

    exportsStub.ox_inventory.GetInventoryItems = originalGetInventoryItems

    -- THIRD request, same source, once the first has genuinely completed
    -- (mutex released) and the flat per-source cooldown has cleared: must
    -- succeed normally -- proving the mutex was released, not left stuck
    -- held forever by the earlier in-flight request.
    fakeNow = 300100
    currentItemsByInvId[invId] = {}
    local thirdResult = searchTargetCallback(901, 'vehicle', netId)
    t.isTrue(thirdResult.ok, 'the mutex must be fully released after the first request completes, not left stuck held')
end)

t.test('IsSearchInProgressForSource: read-only accessor exposed for a future server/combat.lua consumer -- true only while a real search for that source is genuinely mid-flight', function()
    t.isNotNil(env.IsSearchInProgressForSource, 'must be a real resource-global, not merely documented')
    fakeNow = 310000
    local netId = 9101
    currentItemsByInvId['trunkPLATE' .. tostring(netId)] = {}

    t.isFalse(env.IsSearchInProgressForSource(910), 'false before any search has ever started for this source')

    local originalGetInventoryItems = exportsStub.ox_inventory.GetInventoryItems
    exportsStub.ox_inventory.GetInventoryItems = function(_self, invOrId)
        coroutine.yield()
        local invId2 = type(invOrId) == 'table' and invOrId.id or invOrId
        return currentItemsByInvId[invId2] or {}
    end

    local co = coroutine.create(function()
        searchTargetCallback(910, 'vehicle', netId)
    end)
    coroutine.resume(co)
    t.isTrue(env.IsSearchInProgressForSource(910), 'true while genuinely mid-flight (yielded on the inventory read)')

    coroutine.resume(co) -- let it finish
    exportsStub.ox_inventory.GetInventoryItems = originalGetInventoryItems
    t.isFalse(env.IsSearchInProgressForSource(910), 'false again once the search has completed and the mutex released')
end)

t.test('GetContrabandAlertTier: never leaks a mutable reference that corrupts Config.ContrabandAlertTiers on write', function()
    -- Unlike server/progression.lua's AwardXP (which defensively copies the
    -- outbound event payload via CopyTier), this wrapper returns the SAME
    -- table reference from Config.ContrabandAlertTiers -- documented here
    -- as the REAL, current behavior (not asserted as a bug): this file's
    -- own doc comment for GetContrabandAlertTier only promises "no read
    -- access to any real target's inventory," never a defensive copy, and
    -- an internal, test-only caller mutating its own read result is a
    -- different risk profile than progression.lua's outbound
    -- TriggerEvent payload (handed to potentially-external resources).
    local tier = GetContrabandAlertTier(250)
    local original = Config.ContrabandAlertTiers[3].alert
    t.equals(tier, Config.ContrabandAlertTiers[3], 'current behavior: this wrapper returns the LIVE Config table entry, not a copy')
    Config.ContrabandAlertTiers[3].alert = original -- restore regardless (no mutation performed, just confirming identity)
end)

t.test('SILENT-FAILURE FIX: a k9_search_log audit INSERT that genuinely FAILS is caught and logged, never propagated into the search result', function()
    -- Pins server/search.lua's LogSearchAttempt silent-failure fix. That write
    -- moved from a decorative `pcall(MySQL.insert, ...)` (fire-and-forget: the
    -- pcall returns before the query runs, so a real SQL failure could never
    -- reach it) to `CreateThread(function() pcall(MySQL.insert.await, ...) end)`,
    -- which DOES surface a genuine query error. This test drives that newly-real
    -- error path with the four failure shapes a live MySQL/MariaDB actually
    -- returns for this INSERT -- 1146 (k9_search_log missing: install.sql or a
    -- migration never applied), 1265 (an ENUM value drift on result/target_type),
    -- and 1406 (an over-length target_plate/alert_tier) -- and asserts the fix
    -- kept its OTHER half of the contract: a logging failure must still never
    -- surface as, or cause, a search failure for the requesting officer. Without
    -- the pcall this raises straight out of the callback and result.ok is nil.
    fakeNow = 10000000 -- far past every cooldown window any test above armed; this test runs LAST so it never moves the clock backwards for another test
    local realInsert = env.MySQL.insert
    for _, sqlError in ipairs({
        "ERROR 1146 (42S02): Table 'k9.k9_search_log' doesn't exist",
        "ERROR 1265 (01000): Data truncated for column 'result' at row 1",
        "ERROR 1406 (22001): Data too long for column 'target_plate' at row 1",
        "ERROR 1406 (22001): Data too long for column 'alert_tier' at row 1",
    }) do
        env.MySQL.insert = { await = function(_sql, _params) error(sqlError, 0) end }
        local triggerBefore = triggerEventCount
        local ok, result = pcall(searchVehicle, 501, 3003, 15)
        t.isTrue(ok, 'a failing audit INSERT must never raise out of the searchTarget callback: ' .. sqlError)
        t.isTrue(result.ok, 'the search itself must still succeed and report normally despite the audit write failing: ' .. sqlError)
        t.equals(result.totalWeight, 15, 'the requester must still get the real weight even though the audit row was lost')
        t.equals(triggerEventCount, triggerBefore + 1, 'the outbound searchCompleted event must still fire after a failed audit write')
        fakeNow = fakeNow + 100000 -- fresh window for the next iteration's own search
    end
    env.MySQL.insert = realInsert
end)

-- ============================================================================
-- EIGHTH XP-FARM FIX: cross-file integration -- proves server/progression.lua's
-- new SHARED cross-mechanic XP mint budget genuinely binds through THIS
-- file's own real, unmodified 'john-k9:server:searchTarget' callback, not
-- just via a directly-called AwardXP the way tests/progression_spec.lua's
-- own coverage already does. Everything above this point in this file stubs
-- AwardXP directly (see this file's own header) -- this section is the one
-- place that loads the REAL server/progression.lua alongside the REAL
-- server/search.lua in the SAME sandbox, so a contraband find that goes
-- through search.lua's OWN validation/cooldown/weight-changed logic still
-- has its XP withheld by the budget when that budget is already spent,
-- while every other side effect (the search result itself, the audit log,
-- the alert broadcast) keeps firing normally -- exactly the "gate the mint,
-- never the mechanic" property this pass's own report documents for every
-- other mechanic. Deliberately a FRESH, independent sandbox (own Config, own
-- fake clock) rather than reusing this file's shared `env` above, so it
-- cannot perturb any of the 13 tests already passing against that shared
-- state.
-- ============================================================================

local function newSearchPlusProgressionFixture()
    local fakeNow2 = 0
    local function GetGameTimer2() return fakeNow2 end

    local eventHandlers2 = {}
    local function AddEventHandler2(eventName, handler)
        eventHandlers2[eventName] = eventHandlers2[eventName] or {}
        eventHandlers2[eventName][#eventHandlers2[eventName] + 1] = handler
    end

    local function GetCurrentResourceName2() return 'john-k9' end

    local threadRunner2 = Sandbox.newThreadRunner()

    local registeredCallbacks2 = {}
    local libStub2 = { callback = { register = function(name, handler) registeredCallbacks2[name] = handler end } }

    local playerByCitizenId2 = {}
    local playersBySource2 = {}
    -- COMPAT-LAYER MIGRATION (this pass): see this file's shared `env`
    -- section above for the full "why all seven server-realm methods" writeup.
    local exportsStub2 = {
        ox_inventory = {
            GetInventoryItems = function() return {} end,
            GetContainerFromSlot = function() return nil end,
            GetItemCount = function() return 0 end,
            RemoveItem = function() return false end,
            RegisterStash = function() return true end,
            RegisterShop = function() return true end,
            registerHook = function() return 1 end,
        },
        qbx_core = {
            GetPlayer = function(_self, source) return playersBySource2[source] end,
            GetPlayerByCitizenId = function(_self, citizenid) return playerByCitizenId2[citizenid] end,
        },
    }

    local MySQLStub2 = {
        scalar = { await = function(_sql, _params) return nil end },
        insert = { await = function(_sql, _params) return 1 end },
    }

    local onlineIds2 = {}
    local function GetPlayers2()
        local out = {}
        for id in pairs(onlineIds2) do out[#out + 1] = tostring(id) end
        return out
    end

    -- REAL Config.XP.awards -- just the one mechanic this integration test
    -- needs (searchContrabandFound = 25, matching config.lua exactly) --
    -- XP_MINT_BUDGET_STARTER_TOKENS (server/progression.lua) will compute as
    -- exactly 25 from this table, so a single 25-XP award drains it to
    -- precisely 0 in one call -- see the test below for why that is useful.
    local Config2 = {
        Features = { SearchZones = true, XPProgression = true, ContrabandAlerts = false },
        SearchZones = {
            alertBroadcastRadius = 50.0, searchCooldownMs = 10, sniffAnimDurationMs = 10,
            vehicleSearchDistance = 100.0, personSearchDistance = 100.0,
        },
        SearchContrabandItems = { 'weed_baggy' },
        ContrabandAlertTiers = {
            { minWeight = 0, alert = 'clean' },
            { minWeight = 1, alert = 'whine' },
        },
        XP = {
            scopePerCitizenidOrJob = 'citizenid',
            awards = { searchContrabandFound = 25 },
        },
        XPTiers = {
            { xp = 0, label = 'Recruit K9', speedMultiplier = 1.00, scentRangeMultiplier = 1.00 },
        },
        -- COMPAT-LAYER MIGRATION (this pass): see this file's shared Config
        -- section above for the full writeup.
        Compat = {
            diagnosticCommand = false,
            Systems = {
                inventory = { override = 'ox_inventory' },
                target = {}, framework = {}, dispatch = {}, ambulance = {},
            },
        },
    }

    local env2 = Sandbox.newEnv({
        GetGameTimer = GetGameTimer2,
        AddEventHandler = AddEventHandler2,
        GetCurrentResourceName = GetCurrentResourceName2,
        GetPlayers = GetPlayers2,
        CreateThread = threadRunner2.CreateThread,
        Wait = threadRunner2.Wait,
        lib = libStub2,
        exports = exportsStub2,
        MySQL = MySQLStub2,
        TriggerEvent = function(_eventName, ...) end,
        TriggerClientEvent = function(_eventName, _target, ...) end,
        HasK9Access = function() return true end,
        NetworkGetEntityFromNetworkId = function(netId) return netId end,
        DoesEntityExist = function(entity) return entity ~= 0 end,
        GetEntityType = function(_entity) return 2 end, -- vehicle, same convention as this file's shared section above
        GetVehicleNumberPlateText = function(entity) return 'PLATE' .. tostring(entity) end,
        GetPlayerPed = function(_source) return 42 end,
        GetEntityCoords = function(_entity) return ZERO_VEC end,
        -- SEARCHER-BUSY GUARD -- this fixture is about the shared XP-mint
        -- budget, not this guard, so a fixed `false` is correct throughout.
        IsPedInAnyVehicle = function() return false end,
        Config = Config2,
        -- COMPAT-LAYER MIGRATION (this pass): server realm; ox_inventory
        -- always reports 'started'.
        IsDuplicityVersion = function() return true end,
        GetResourceState = function(name) return name == 'ox_inventory' and 'started' or 'missing' end,
    })

    Sandbox.loadInto('../server/cooldowns.lua', env2)
    Sandbox.loadInto('../server/entities.lua', env2)
    -- server/datastore.lua -- REAL, unmodified, loaded alongside (see this
    -- file's own top-of-file loadInto comment above for the full
    -- reasoning). server/progression.lua's own AwardXP/LoadXPForCitizenid
    -- now read/write through K9Store.XP_Get/K9Store.XP_UpsertAdd rather
    -- than raw SQL; Config2.Database is deliberately absent, so
    -- DatabaseEnabled() fails safe to `true` and those calls forward
    -- straight through to MySQLStub2 exactly as before this migration.
    Sandbox.loadInto('../server/datastore.lua', env2)
    Sandbox.loadInto('../server/progression.lua', env2)
    Sandbox.loadInto('../server/events.lua', env2) -- FireOutboundEvent, extracted from six identical local copies into one shared helper; loaded in the real resource via fxmanifest, so a sandbox that omits it fails where the game would not
    -- COMPAT-LAYER MIGRATION (this pass): see this file's shared `env`
    -- section above for the full writeup.
    Sandbox.loadInto('../shared/compat/core.lua', env2)
    Sandbox.loadInto('../shared/compat/inventory.lua', env2)
    Sandbox.loadInto('../server/search.lua', env2)
    for _, handler in ipairs(eventHandlers2['onResourceStart'] or {}) do
        handler('john-k9')
    end

    local searchCallback2 = registeredCallbacks2['john-k9:server:searchTarget']
    local itemsByInvId2 = {}
    exportsStub2.ox_inventory.GetInventoryItems = function(_self, invOrId)
        local invId = type(invOrId) == 'table' and invOrId.id or invOrId
        return itemsByInvId2[invId] or {}
    end

    return {
        AwardXP = env2.AwardXP,
        GetXP = env2.GetXP,
        setNow = function(ms) fakeNow2 = ms end,
        now = function() return fakeNow2 end,
        runOneTick = function()
            if not threadRunner2.primed then threadRunner2.step(); threadRunner2.primed = true end
            threadRunner2.step()
        end,
        setPlayer = function(source, citizenid)
            playersBySource2[source] = { PlayerData = { citizenid = citizenid, job = { name = 'police' } } }
            playerByCitizenId2[citizenid] = { PlayerData = { citizenid = citizenid, source = source } }
            onlineIds2[source] = true
        end,
        --- Drives one full REAL 'vehicle' searchTarget call, exactly mirroring
        --- this file's own top-level searchVehicle helper, against THIS
        --- fixture's own fresh callback/state instead of the shared one.
        --- @param source number
        --- @param netId number
        --- @param weight number
        searchVehicle = function(source, netId, weight)
            local invId = 'trunkPLATE' .. tostring(netId)
            itemsByInvId2[invId] = weight and weight > 0 and { { name = 'weed_baggy', weight = weight, slot = 1 } } or {}
            return searchCallback2(source, 'vehicle', netId)
        end,
    }
end

t.test('EIGHTH XP-FARM FIX (cross-file integration): a real search find through the REAL, unmodified searchTarget callback still succeeds normally when the shared XP mint budget is already spent -- only the XP is withheld', function()
    local f = newSearchPlusProgressionFixture()
    local citizenid = 'CITIZEN-COMPOUND-FARM'
    f.setPlayer(501, citizenid)

    -- Drain the shared budget directly via the REAL AwardXP (standing in for
    -- "this citizenid already spent it via bite-hold/takedown/tracking
    -- elsewhere this hour" -- server/combat.lua/tracking.lua are not loaded
    -- in this sandbox, but AwardXP is the SAME single chokepoint every one
    -- of them goes through, so calling it directly here is calling the real
    -- gate, not a re-implementation of it). XP_MINT_BUDGET_STARTER_TOKENS
    -- computes to exactly 25 from this fixture's own Config.XP.awards (see
    -- newSearchPlusProgressionFixture's own comment), so one 25-XP award
    -- drains it to precisely 0 with negligible elapsed time.
    f.setNow(0)
    f.AwardXP(citizenid, 'searchContrabandFound')
    t.equals(f.GetXP(citizenid), 25, 'sanity check: the direct drain call itself must pay (this citizenid has never earned anything before it)')

    -- Advance past AwardXPCooldown's OWN pre-existing 500ms-per-
    -- (citizenid,actionKey) floor (server/progression.lua) before the real
    -- search below -- NOT the mechanism this test means to isolate. Without
    -- this, the search callback's own internal AwardXP('searchContrabandFound')
    -- call would be blocked by THAT floor instead of by the shared budget,
    -- making this test pass for the wrong reason. 600ms leaves the shared
    -- budget's own refill at a negligible ~0.6 XP -- nowhere near enough to
    -- cover the 25-XP find below, so the shared budget is still the thing
    -- actually being exercised.
    f.setNow(600)

    -- Now drive a GENUINE, fresh, first-ever find through the REAL
    -- searchTarget callback -- a different target, a real weight, every one
    -- of server/search.lua's own gates (HasK9Access, proximity, cooldowns,
    -- the weight-changed check, ContrabandXpMintCooldown) passes on its own
    -- terms. The shared budget is still, for all practical purposes, at 0
    -- tokens.
    local result = f.searchVehicle(501, 9001, 20)
    t.isTrue(result.ok, 'the search request itself must still succeed -- the shared budget must never block the MECHANIC, only the mint')
    t.isTrue(result.contrabandFound, 'contraband must still be reported to the requester')
    t.equals(result.totalWeight, 20, 'the requester must still see the real, current weight')
    t.equals(f.GetXP(citizenid), 25, 'no additional XP may be granted -- the shared budget (server/progression.lua) correctly withheld this genuine find\'s XP because it is already fully spent, even though search.lua\'s OWN per-mechanic gates (ContrabandXpMintCooldown, the weight-changed check) all independently passed')
end)

t.test('EIGHTH XP-FARM FIX (cross-file integration): once the shared budget has refilled, the SAME kind of real search find pays normally again', function()
    local f = newSearchPlusProgressionFixture()
    local citizenid = 'CITIZEN-COMPOUND-FARM-2'
    f.setPlayer(501, citizenid)

    f.setNow(0)
    f.AwardXP(citizenid, 'searchContrabandFound') -- drains to exactly 0, same as above
    t.equals(f.GetXP(citizenid), 25)

    -- A full hour later (XP_MINT_BUDGET_WINDOW_MS, server/progression.lua) --
    -- the bucket has fully refilled to XP_MINT_BUDGET_CAP_XP (3,600 XP) --
    -- comfortably enough for one more 25-XP find.
    f.setNow(3600000)
    local result = f.searchVehicle(501, 9002, 20)
    t.isTrue(result.ok)
    t.equals(f.GetXP(citizenid), 50, 'a real search find must pay normally again once the shared budget has genuinely refilled -- this gate is a temporary throttle, never a permanent lockout')
end)

-- ============================================================================
-- QB-INVENTORY VEHICLE SEARCH FIX (coder-backend, this pass) -- KNOWN_ISSUES.md's
-- "vehicle search always returns empty on qb-inventory" gap.
--
-- ROOT CAUSE, CONFIRMED against qbcore-framework/qb-inventory's real `main`
-- branch source this pass (client/vehicles.lua's own
-- `qb-inventory:client:vehicleCheck` callback): qb-inventory's real
-- vehicle-trunk inventory identifier is `'trunk-' .. plate` (HYPHENATED) --
-- a plain SCALAR key (server/functions.lua's `GetInventory(identifier)` is
-- a direct `Inventories[identifier]` lookup, confirmed to have no
-- table-shaped-argument concept at all). server/search.lua used to
-- unconditionally build the ox_inventory-only `'trunk' .. plate` id (no
-- separator) AND wrap it in the ox_inventory-only `{ id, netid }` table
-- shape needed for THAT backend's own uncached-trunk lazy-load mechanism --
-- which qb-inventory's own GetInventoryItems deliberately fails closed to
-- nil for (see tests/compatinventory_spec.lua's own coverage of that
-- still-correct behavior for every OTHER caller). Fixed by deriving the
-- correct, backend-real SCALAR identifier and passing it as a plain scalar
-- when the resolved inventory backend is qb-inventory.
--
-- A FRESH, independent sandbox (own Config, own exports, `Config.Compat`
-- pinned to qb-inventory via `override`) -- mirrors
-- newSearchPlusProgressionFixture's own reasoning for why this cannot
-- reuse this file's shared top-level `env` (already permanently detected
-- as ox_inventory the moment this file's own onResourceStart loop ran).
-- ============================================================================

local function newSearchQbInventoryFixture()
    local fakeNow3 = 0
    local function GetGameTimer3() return fakeNow3 end

    local eventHandlers3 = {}
    local function AddEventHandler3(eventName, handler)
        eventHandlers3[eventName] = eventHandlers3[eventName] or {}
        eventHandlers3[eventName][#eventHandlers3[eventName] + 1] = handler
    end

    local function GetCurrentResourceName3() return 'john-k9' end
    local threadRunner3 = Sandbox.newThreadRunner()

    local function CreateThread3(fn)
        local co = coroutine.create(fn)
        local ok, err = coroutine.resume(co)
        if not ok then
            error(('search_spec.lua (qb-inventory fixture): a CreateThread body errored: %s'):format(tostring(err)))
        end
    end

    local registeredCallbacks3 = {}
    local libStub3 = { callback = { register = function(name, handler) registeredCallbacks3[name] = handler end } }

    -- Records every identifier `GetInventory` was actually called with, so
    -- the tests below can assert the EXACT scalar shape/spelling reaching
    -- qb-inventory's own real export -- not just the end-to-end result.
    local getInventoryCalls = {}
    local itemsByInvId3 = {}
    local exportsStub3 = {
        ['qb-inventory'] = {
            GetInventory = function(_self, id)
                getInventoryCalls[#getInventoryCalls + 1] = id
                if type(id) ~= 'string' and type(id) ~= 'number' then return nil end
                local items = itemsByInvId3[id]
                if not items then return nil end
                return { items = items }
            end,
            GetItemCount = function() return 0 end,
            RemoveItem = function() return true end,
            CreateInventory = function() return true end,
            CreateShop = function() return true end,
            AddHook = function() return 1 end,
        },
        qbx_core = {
            -- UPDATED (per-person feature control pass, coder-backend):
            -- used to return nil unconditionally -- harmless before this
            -- pass, since nothing in server/search.lua's core search path
            -- needed a resolvable citizenid to succeed (LogSearchAttempt/
            -- AwardXP already tolerated a nil citizenid gracefully, and
            -- this fixture's own Config3 has XPProgression/ContrabandAlerts
            -- both off, so neither of those paths is exercised here
            -- anyway). Now HANDLESearchTarget's own new
            -- IsSearchFeaturePermittedForCitizenId gate (see server/search.lua's
            -- header) genuinely NEEDS a resolvable citizenid for the core
            -- search to proceed at all -- fails CLOSED on an unresolvable
            -- one, matching server/pursuitsprint.lua's own established
            -- precedent for the identical situation. A real, connected
            -- player who has already passed HasK9Access (stubbed `true`
            -- above for this whole fixture) always resolves a real
            -- citizenid via this same export in production; returning one
            -- here matches that reality instead of an untested-in-practice
            -- "access granted but citizenid unresolvable" state this
            -- fixture was never actually exercising.
            GetPlayer = function(_self, source) return { PlayerData = { citizenid = 'CITIZEN' .. tostring(source), job = { name = 'police' } } } end,
            GetPlayerByCitizenId = function(_self, _citizenid) return nil end,
        },
    }

    local MySQLStub3 = {
        scalar = { await = function(_sql, _params) return nil end },
        insert = { await = function(_sql, _params) return 1 end },
    }

    local Config3 = {
        Features = { SearchZones = true, XPProgression = false, ContrabandAlerts = false },
        SearchZones = {
            alertBroadcastRadius = 50.0, searchCooldownMs = 10, sniffAnimDurationMs = 10,
            vehicleSearchDistance = 100.0, personSearchDistance = 100.0,
        },
        SearchContrabandItems = { 'weed_baggy' },
        ContrabandAlertTiers = {
            { minWeight = 0, alert = 'clean' },
            { minWeight = 1, alert = 'whine' },
        },
        -- Pins the 'inventory' system straight to qb-inventory (TIER 1,
        -- `override` -- skips the candidate-scanning walk entirely, same
        -- mechanism this file's shared `env` section above already uses to
        -- pin ox_inventory).
        Compat = {
            diagnosticCommand = false,
            Systems = {
                inventory = { override = 'qb-inventory' },
                target = {}, framework = {}, dispatch = {}, ambulance = {},
            },
        },
    }

    local env3 = Sandbox.newEnv({
        GetGameTimer = GetGameTimer3,
        AddEventHandler = AddEventHandler3,
        GetCurrentResourceName = GetCurrentResourceName3,
        CreateThread = CreateThread3,
        Wait = threadRunner3.Wait,
        lib = libStub3,
        exports = exportsStub3,
        MySQL = MySQLStub3,
        TriggerEvent = function(_eventName, ...) end,
        TriggerClientEvent = function(_eventName, _target, ...) end,
        HasK9Access = function() return true end,
        NetworkGetEntityFromNetworkId = function(netId) return netId end,
        DoesEntityExist = function(entity) return entity ~= 0 end,
        GetEntityType = function(_entity) return 2 end, -- vehicle, same convention as this file's shared section above
        GetVehicleNumberPlateText = function(entity) return 'PLATE' .. tostring(entity) end,
        GetPlayerPed = function(_source) return 42 end,
        GetEntityCoords = function(_entity) return ZERO_VEC end,
        -- SEARCHER-BUSY GUARD -- this fixture is about the qb-inventory
        -- vehicle-search fix, not this guard, so a fixed `false` is correct
        -- throughout.
        IsPedInAnyVehicle = function() return false end,
        Config = Config3,
        IsDuplicityVersion = function() return true end,
        -- qb-inventory always reports 'started'; ox_inventory is absent
        -- entirely from this fixture, so a regression that fell back to the
        -- ox_inventory-shaped table form would surface as a hard
        -- capability-check failure, not a silent pass.
        GetResourceState = function(name) return name == 'qb-inventory' and 'started' or 'missing' end,
    })

    Sandbox.loadInto('../server/cooldowns.lua', env3)
    Sandbox.loadInto('../server/entities.lua', env3)
    Sandbox.loadInto('../server/datastore.lua', env3)
    Sandbox.loadInto('../server/events.lua', env3)
    Sandbox.loadInto('../shared/compat/core.lua', env3)
    Sandbox.loadInto('../shared/compat/inventory.lua', env3)
    Sandbox.loadInto('../server/search.lua', env3)
    for _, handler in ipairs(eventHandlers3['onResourceStart'] or {}) do
        handler('john-k9')
    end

    local searchCallback3 = registeredCallbacks3['john-k9:server:searchTarget']

    return {
        getInventoryCalls = getInventoryCalls,
        --- Drives one full REAL 'vehicle' searchTarget call against a
        --- qb-inventory-resolved backend. Stores the contraband under
        --- qb-inventory's own REAL, hyphenated identifier convention
        --- (`'trunk-' .. plate`) -- exactly what a real qb-inventory server
        --- would have persisted/lazily created it under, per
        --- client/vehicles.lua's own confirmed `vehicleCheck` callback.
        --- @param source number
        --- @param netId number
        --- @param weight number
        searchVehicle = function(source, netId, weight)
            local plate = 'PLATE' .. tostring(netId)
            local invId = 'trunk-' .. plate
            itemsByInvId3[invId] = weight and weight > 0 and { { name = 'weed_baggy', weight = weight, slot = 1 } } or {}
            return searchCallback3(source, 'vehicle', netId)
        end,
        --- Drives the same REAL callback WITHOUT ever seeding
        --- `itemsByInvId3` for this target's identifier first -- the stubbed
        --- `GetInventory` above then genuinely returns `nil` (no entry at
        --- all), exactly matching real qb-inventory's own
        --- `Inventories[identifier]` for a trunk nobody has ever opened this
        --- server's lifetime.
        --- @param source number
        --- @param netId number
        searchVehicleNeverSeeded = function(source, netId)
            return searchCallback3(source, 'vehicle', netId)
        end,
    }
end

t.test('qb-inventory VEHICLE SEARCH FIX: a real trunk search finds contraband stored under qb-inventory\'s own real, hyphenated identifier -- never empty by default', function()
    local f = newSearchQbInventoryFixture()
    local result = f.searchVehicle(501, 5001, 15)
    t.isTrue(result.ok, 'a valid, in-range, first-ever qb-inventory vehicle search must succeed')
    t.isTrue(result.contrabandFound, 'this used to always be false/empty on qb-inventory -- the entire point of this fix')
    t.equals(result.totalWeight, 15)
end)

t.test('qb-inventory VEHICLE SEARCH FIX: GetInventory is called with the correct SCALAR, hyphenated identifier -- never the ox_inventory-only {id,netid} table shape', function()
    local f = newSearchQbInventoryFixture()
    f.searchVehicle(502, 5002, 0)
    t.equals(#f.getInventoryCalls, 1, 'exactly one GetInventory call must reach the real export')
    local calledWith = f.getInventoryCalls[1]
    t.equals(type(calledWith), 'string', 'a TABLE-shaped inv (the ox_inventory-only form) would fail closed to nil on qb-inventory -- this call site must never pass one to this backend')
    t.equals(calledWith, 'trunk-PLATE5002', 'qb-inventory\'s own real convention is hyphenated (client/vehicles.lua\'s confirmed vehicleCheck callback) -- ox_inventory\'s own \'trunk\' .. plate (no separator) is a DIFFERENT, wrong string on this backend')
end)

t.test('qb-inventory VEHICLE SEARCH FIX: an already-initialized but empty trunk correctly reports clean, not search_failed', function()
    local f = newSearchQbInventoryFixture()
    local result = f.searchVehicle(503, 5003, 0) -- weight=0 still pre-populates an EMPTY {} items table under the real id, simulating a trunk this session already opened/created with nothing in it
    t.isTrue(result.ok)
    t.isFalse(result.contrabandFound)
    t.equals(result.totalWeight, 0)
end)

t.test('qb-inventory VEHICLE SEARCH FIX: a trunk NOBODY has ever opened this server\'s lifetime (no persisted row at all -- GetInventory genuinely returns nil, confirmed real qb-inventory behavior for an uninitialized identifier) reports search_failed -- never a false clean bill, never a crash', function()
    local f = newSearchQbInventoryFixture()
    local result = f.searchVehicleNeverSeeded(504, 5004)
    t.isTrue(result.ok == false, 'no persisted/lazily-created row at all is a genuine "the search could not be performed" outcome')
    t.equals(result.reason, 'search_failed')
end)

-- ========================================================================
-- PER-PERSON FEATURE CONTROL (config.lua's Config.FeatureControl 4-step
-- resolution) -- IsSearchFeaturePermittedForCitizenId, generalized this
-- pass (was hardcoded to 'SearchZones' only) to also gate ContrabandAlerts.
-- Own self-contained fixture, mirroring newSearchQbInventoryFixture's own
-- shape exactly, so nothing here can leak state into (or depend on
-- leftover state from) the shared top-level `env`/`Config` sections above.
-- ========================================================================

--- @param opts table? { featureControl: table?, hasPermissionFn: function?, withHasPermission: boolean? }
local function newSearchPermissionFixture(opts)
    opts = opts or {}

    local fakeNow4 = 0
    local function GetGameTimer4() return fakeNow4 end

    local threadRunner4 = Sandbox.newThreadRunner()

    local eventHandlers4 = {}
    local function AddEventHandler4(eventName, handler)
        eventHandlers4[eventName] = eventHandlers4[eventName] or {}
        eventHandlers4[eventName][#eventHandlers4[eventName] + 1] = handler
    end

    local function GetCurrentResourceName4() return 'john-k9' end

    local function CreateThread4(fn)
        local co = coroutine.create(fn)
        local ok, err = coroutine.resume(co)
        if not ok then
            error(('search_spec.lua (permission fixture): a CreateThread body errored: %s'):format(tostring(err)))
        end
    end

    local registeredCallbacks4 = {}
    local libStub4 = { callback = { register = function(name, handler) registeredCallbacks4[name] = handler end } }

    local itemsByInvId4 = {}
    local triggerClientEventCount4 = 0
    local exportsStub4 = {
        ox_inventory = {
            GetInventoryItems = function(_self, invOrId)
                local invId = type(invOrId) == 'table' and invOrId.id or invOrId
                return itemsByInvId4[invId] or {}
            end,
            GetContainerFromSlot = function() return nil end,
            GetItemCount = function() return 0 end,
            RemoveItem = function() return false end,
            RegisterStash = function() return true end,
            RegisterShop = function() return true end,
            registerHook = function() return 1 end,
        },
        qbx_core = {
            GetPlayer = function(_self, source) return { PlayerData = { citizenid = 'PCID' .. tostring(source), job = { name = 'police' } } } end,
        },
    }

    local function defaultHasPermission(citizenid, key)
        if type(opts.hasPermissionFn) == 'function' then
            return opts.hasPermissionFn(citizenid, key)
        end
        return false
    end

    local Config4 = {
        Features = { SearchZones = true, XPProgression = false, ContrabandAlerts = true },
        SearchZones = {
            alertBroadcastRadius = 50.0, searchCooldownMs = 10, sniffAnimDurationMs = 10,
            vehicleSearchDistance = 100.0, personSearchDistance = 100.0,
        },
        SearchContrabandItems = { 'weed_baggy' },
        ContrabandAlertTiers = {
            { minWeight = 0, alert = 'clean' },
            { minWeight = 1, alert = 'whine' },
        },
        Compat = {
            diagnosticCommand = false,
            Systems = {
                inventory = { override = 'ox_inventory' },
                target = {}, framework = {}, dispatch = {}, ambulance = {},
            },
        },
        FeatureControl = opts.featureControl,
    }

    local envOverrides4 = {
        GetGameTimer = GetGameTimer4,
        AddEventHandler = AddEventHandler4,
        GetCurrentResourceName = GetCurrentResourceName4,
        CreateThread = CreateThread4,
        Wait = threadRunner4.Wait,
        lib = libStub4,
        exports = exportsStub4,
        MySQL = { insert = { await = function() return 1 end } },
        TriggerEvent = function() end,
        TriggerClientEvent = function(eventName)
            if eventName == 'john-k9:client:playContrabandAlert' then
                triggerClientEventCount4 = triggerClientEventCount4 + 1
            end
        end,
        HasK9Access = function() return true end,
        NetworkGetEntityFromNetworkId = function(netId) return netId end,
        DoesEntityExist = function(entity) return entity ~= 0 end,
        GetEntityType = function() return 2 end, -- vehicle
        GetVehicleNumberPlateText = function(entity) return 'PLATE' .. tostring(entity) end,
        GetPlayerPed = function() return 42 end,
        GetEntityCoords = function() return ZERO_VEC end,
        GetPlayers = function() return { '501' } end,
        -- SEARCHER-BUSY GUARD (server-side half of client/search.lua's own
        -- IsBusyWithSomethingElse(), commit a32a554) -- this fixture never
        -- exercises that guard itself (a self-contained PER-PERSON FEATURE
        -- CONTROL fixture, orthogonal to it), so a fixed `false` is correct
        -- for every test built on it. IsK9CurrentlyHolding is deliberately
        -- left undefined here too, same "genuinely absent, matching real
        -- production today" reasoning as the shared top-level env above.
        IsPedInAnyVehicle = function() return false end,
        Config = Config4,
        IsDuplicityVersion = function() return true end,
        GetResourceState = function(name) return name == 'ox_inventory' and 'started' or 'missing' end,
    }
    if opts.withHasPermission ~= false then
        envOverrides4.HasPermission = defaultHasPermission
    end

    local env4 = Sandbox.newEnv(envOverrides4)

    Sandbox.loadInto('../server/cooldowns.lua', env4)
    Sandbox.loadInto('../server/entities.lua', env4)
    Sandbox.loadInto('../server/datastore.lua', env4)
    Sandbox.loadInto('../server/events.lua', env4)
    Sandbox.loadInto('../shared/compat/core.lua', env4)
    Sandbox.loadInto('../shared/compat/inventory.lua', env4)
    Sandbox.loadInto('../server/search.lua', env4)
    for _, handler in ipairs(eventHandlers4['onResourceStart'] or {}) do
        handler('john-k9')
    end

    local searchCallback4 = registeredCallbacks4['john-k9:server:searchTarget']

    return {
        triggerClientEventCount = function() return triggerClientEventCount4 end,
        --- @param source number
        --- @param netId number
        --- @param weight number
        searchVehicle = function(source, netId, weight)
            local invId = 'trunkPLATE' .. tostring(netId)
            itemsByInvId4[invId] = weight and weight > 0 and { { name = 'weed_baggy', weight = weight, slot = 1 } } or {}
            return searchCallback4(source, 'vehicle', netId)
        end,
    }
end

t.test('PER-PERSON SearchZones: block.SearchZones denies the search outright, even though HasK9Access is true', function()
    local f = newSearchPermissionFixture({
        hasPermissionFn = function(citizenid, key) return key == 'block.SearchZones' and citizenid == 'PCID601' end,
    })
    local result = f.searchVehicle(601, 6001, 10)
    t.isFalse(result.ok)
    t.equals(result.reason, 'not_granted')
end)

t.test('PER-PERSON SearchZones: not blocked and not listed in RequireGrant -- default ALLOW (step 4)', function()
    local f = newSearchPermissionFixture()
    local result = f.searchVehicle(602, 6002, 10)
    t.isTrue(result.ok)
    t.isTrue(result.contrabandFound)
end)

t.test('PER-PERSON SearchZones: RequireGrant.SearchZones = true + no active feature.SearchZones grant -- denied', function()
    local f = newSearchPermissionFixture({ featureControl = { RequireGrant = { SearchZones = true } } })
    local result = f.searchVehicle(603, 6003, 10)
    t.isFalse(result.ok)
    t.equals(result.reason, 'not_granted')
end)

t.test('PER-PERSON SearchZones: RequireGrant.SearchZones = true + an active feature.SearchZones grant -- allowed', function()
    local f = newSearchPermissionFixture({
        featureControl = { RequireGrant = { SearchZones = true } },
        hasPermissionFn = function(citizenid, key) return key == 'feature.SearchZones' and citizenid == 'PCID604' end,
    })
    local result = f.searchVehicle(604, 6004, 10)
    t.isTrue(result.ok)
end)

t.test('PER-PERSON SearchZones: server/permissions.lua entirely absent (HasPermission not even defined) + RequireGrant listed -- fails CLOSED, never open', function()
    local f = newSearchPermissionFixture({ withHasPermission = false, featureControl = { RequireGrant = { SearchZones = true } } })
    local ok, result = pcall(f.searchVehicle, 605, 6005, 10)
    t.isTrue(ok, 'a missing HasPermission must never error the callback')
    t.isFalse(result.ok, 'RequireGrant-listed + unresolvable grant machinery must deny, not silently allow')
end)

t.test('PER-PERSON SearchZones: server/permissions.lua entirely absent + NOT listed in RequireGrant -- still allowed (falls through to step 4)', function()
    local f = newSearchPermissionFixture({ withHasPermission = false })
    local result = f.searchVehicle(606, 6006, 10)
    t.isTrue(result.ok)
end)

t.test('PER-PERSON ContrabandAlerts: block.ContrabandAlerts suppresses ONLY the broadcast -- the search itself still succeeds, is logged, and still pays XP-eligible contrabandFound', function()
    local f = newSearchPermissionFixture({
        hasPermissionFn = function(citizenid, key) return key == 'block.ContrabandAlerts' and citizenid == 'PCID607' end,
    })
    local before = f.triggerClientEventCount()
    local result = f.searchVehicle(607, 6007, 10)
    t.isTrue(result.ok, 'ContrabandAlerts is a broadcast-only feature -- a block on it must never affect the search result itself')
    t.isTrue(result.contrabandFound)
    t.equals(f.triggerClientEventCount(), before, 'a blocked searcher\'s find must never broadcast the alert to nearby players')
end)

t.test('PER-PERSON ContrabandAlerts: not blocked -- the alert still broadcasts normally on a real find', function()
    local f = newSearchPermissionFixture()
    local before = f.triggerClientEventCount()
    f.searchVehicle(608, 6008, 10)
    t.equals(f.triggerClientEventCount(), before + 1)
end)

t.test('PER-PERSON ContrabandAlerts: RequireGrant.ContrabandAlerts = true + no grant -- broadcast suppressed, search still succeeds', function()
    local f = newSearchPermissionFixture({ featureControl = { RequireGrant = { ContrabandAlerts = true } } })
    local before = f.triggerClientEventCount()
    local result = f.searchVehicle(609, 6009, 10)
    t.isTrue(result.ok)
    t.equals(f.triggerClientEventCount(), before)
end)

t.test('PER-PERSON ContrabandAlerts: RequireGrant.ContrabandAlerts = true + an active grant -- broadcast fires', function()
    local f = newSearchPermissionFixture({
        featureControl = { RequireGrant = { ContrabandAlerts = true } },
        hasPermissionFn = function(citizenid, key) return key == 'feature.ContrabandAlerts' and citizenid == 'PCID610' end,
    })
    local before = f.triggerClientEventCount()
    f.searchVehicle(610, 6010, 10)
    t.equals(f.triggerClientEventCount(), before + 1)
end)

t.test('PER-PERSON ContrabandAlerts: server/permissions.lua entirely absent + RequireGrant listed -- fails CLOSED (broadcast suppressed), search still succeeds', function()
    local f = newSearchPermissionFixture({ withHasPermission = false, featureControl = { RequireGrant = { ContrabandAlerts = true } } })
    local before = f.triggerClientEventCount()
    local ok, result = pcall(f.searchVehicle, 611, 6011, 10)
    t.isTrue(ok, 'a missing HasPermission must never error the callback')
    t.isTrue(result.ok, 'ContrabandAlerts denial must never fail the search itself')
    t.equals(f.triggerClientEventCount(), before)
end)

-- ============================================================================
-- CONFIG-ABORT REGRESSION (this pass): Config.ContrabandAlertTiers and
-- Config.SearchZones.alertBroadcastRadius used to be a pair of bare
-- `assert`s inside this file's own onResourceStart handler. A malformed
-- value must now warn and fall back instead of throwing -- and, the part a
-- bare "does not throw" test would miss, GetContrabandAlertTier (and the
-- searchTarget callback this file registers) must still resolve correctly
-- afterward off the SUBSTITUTED safe value, not the malformed one. A fresh,
-- fully independent env/Config (never the shared `env`/`Config` above).
-- ============================================================================

t.test('CONFIG-ABORT REGRESSION: a malformed Config.ContrabandAlertTiers (missing the mandatory clean baseline) and an over-ceiling alertBroadcastRadius must warn and fall back, never throw, and leave the file fully working', function()
    local eventHandlersCfg = {}
    local function AddEventHandlerCfg(eventName, handler)
        eventHandlersCfg[eventName] = eventHandlersCfg[eventName] or {}
        eventHandlersCfg[eventName][#eventHandlersCfg[eventName] + 1] = handler
    end
    local registeredCallbacksCfg = {}
    local libStubCfg = { callback = { register = function(name, handler) registeredCallbacksCfg[name] = handler end } }
    local printedCfg = {}
    local function printStubCfg(...)
        local parts = {}
        for i = 1, select('#', ...) do parts[i] = tostring(select(i, ...)) end
        printedCfg[#printedCfg + 1] = table.concat(parts, '\t')
    end
    local threadRunnerCfg = Sandbox.newThreadRunner()
    local function CreateThreadCfg(fn)
        local co = coroutine.create(fn)
        local ok, err = coroutine.resume(co)
        if not ok then error(('search_spec.lua CONFIG-ABORT REGRESSION: a CreateThread body errored: %s'):format(tostring(err))) end
    end

    local ConfigCfg = {
        Features = {},
        -- ABOVE the 200.0 hard ceiling.
        SearchZones = { alertBroadcastRadius = 5000.0, searchCooldownMs = 5000 },
        SearchContrabandItems = { 'weed_baggy' },
        -- MALFORMED: the mandatory { minWeight = 0, alert = 'clean' }
        -- baseline is entirely missing.
        ContrabandAlertTiers = {
            { minWeight = 1,   alert = 'whine' },
            { minWeight = 250, alert = 'aggressive_bark' },
        },
        Compat = {
            diagnosticCommand = false,
            Systems = {
                inventory = { override = 'ox_inventory' },
                target = {}, framework = {}, dispatch = {}, ambulance = {},
            },
        },
    }

    local envCfg = Sandbox.newEnv({
        GetGameTimer = function() return 0 end,
        AddEventHandler = AddEventHandlerCfg,
        GetCurrentResourceName = function() return 'john-k9' end,
        CreateThread = CreateThreadCfg,
        Wait = threadRunnerCfg.Wait,
        lib = libStubCfg,
        print = printStubCfg,
        exports = {
            ox_inventory = {
                GetInventoryItems = function() return {} end,
                GetContainerFromSlot = function() return nil end,
                GetItemCount = function() return 0 end,
                RemoveItem = function() return false end,
                RegisterStash = function() return true end,
                RegisterShop = function() return true end,
                registerHook = function() return 1 end,
            },
        },
        Config = ConfigCfg,
        IsDuplicityVersion = function() return true end,
        GetResourceState = function(name) return name == 'ox_inventory' and 'started' or 'missing' end,
    })

    Sandbox.loadInto('../server/cooldowns.lua', envCfg)
    Sandbox.loadInto('../server/entities.lua', envCfg)
    Sandbox.loadInto('../server/datastore.lua', envCfg)
    Sandbox.loadInto('../server/events.lua', envCfg)
    Sandbox.loadInto('../shared/compat/core.lua', envCfg)
    Sandbox.loadInto('../shared/compat/inventory.lua', envCfg)

    local loadOk, loadErr = pcall(Sandbox.loadInto, '../server/search.lua', envCfg)
    t.isTrue(loadOk, 'server/search.lua must load without throwing: ' .. tostring(loadErr))

    -- THE ACTUAL REGRESSION TEST -- must complete WITHOUT throwing. Wrapped
    -- in pcall purely so a real regression (an assert firing again) is
    -- reported as a clear, named test failure below rather than a raw Lua
    -- error aborting this whole spec file's run.
    local fireOk, fireErr = pcall(function()
        for _, handler in ipairs(eventHandlersCfg['onResourceStart'] or {}) do
            handler('john-k9')
        end
    end)
    t.isTrue(fireOk, 'onResourceStart must complete without throwing on a malformed ContrabandAlertTiers/over-ceiling alertBroadcastRadius: ' .. tostring(fireErr))

    -- The searchTarget callback (registered at file LOAD time, before
    -- onResourceStart ever fires) must still be reachable -- proving this
    -- file's own registration was never actually at risk from either guard.
    t.isNotNil(registeredCallbacksCfg['john-k9:server:searchTarget'], 'searchTarget callback must still be registered')

    -- GetContrabandAlertTier must now resolve off the SUBSTITUTED fallback
    -- table, not the malformed configured one -- a totalWeight of 0 must
    -- resolve to 'clean' even though the configured table never had that
    -- baseline entry at all (this is the assertion a bare "did not throw"
    -- check would miss: the corrected value must actually be in effect).
    t.isNotNil(envCfg.GetContrabandAlertTier, 'GetContrabandAlertTier must still be defined')
    t.equals(envCfg.GetContrabandAlertTier(0).alert, 'clean', 'a genuinely clean search must resolve to clean off the fallback tier table')
    t.equals(envCfg.GetContrabandAlertTier(1).alert, 'whine', 'the fallback table must resolve every other tier correctly too')

    -- Config.SearchZones.alertBroadcastRadius must have been clamped DOWN
    -- to the 200.0 hard ceiling, not left at the configured 5000.0.
    t.equals(ConfigCfg.SearchZones.alertBroadcastRadius, 200.0, 'alertBroadcastRadius must be clamped to the 200.0 ceiling')

    local warnedTiers, warnedRadius = false, false
    for _, line in ipairs(printedCfg) do
        if line:find('ContrabandAlertTiers', 1, true) then warnedTiers = true end
        if line:find('alertBroadcastRadius', 1, true) then warnedRadius = true end
    end
    t.isTrue(warnedTiers, 'a malformed Config.ContrabandAlertTiers must print a warning naming it, not fail silently either')
    t.isTrue(warnedRadius, 'an over-ceiling alertBroadcastRadius must print a warning naming it, not fail silently either')
end)

-- ========================================================================
-- SPECIALIZATION-SCOPED CONTRABAND CATEGORIES (owner-directed decluttering
-- pass, 2026-08-26 -- "if i am certed in drugs... it will only search for
-- drugs or if i am certed for drugs and explosives its still the same it
-- will search for those 2"). Reuses the SAME shared harness/env/Config the
-- searchVehicle()-based sections above already established (this file's
-- top-level Config.SearchContrabandItems already carries 'coke_brick' =
-- 'narcotics' and 'weapon_pistol' = 'explosives' additively -- see that
-- table's own comment -- and `grantSpecialization`/`env.HasSpecialization`
-- above are this section's own new controllable stub).
--
-- MONOTONIC BY DESIGN (see config.lua's own Config.SearchContrabandItems
-- comment and server/search.lua's own ContrabandItemInfo header): an
-- UNCATEGORISED item ('weed_baggy') is the baseline, found by everyone,
-- always; a CATEGORISED item is found ONLY by a searcher holding that
-- exact specialization, ON TOP OF the baseline -- there is no "holds
-- nothing -> finds everything" fallback.
-- ========================================================================

--- Drives one full 'vehicle' searchTarget call with an ARBITRARY set of
--- named items -- `searchVehicle`'s own generalization for this section,
--- which needs more than one fixed item name ('weed_baggy').
--- @param source number
--- @param netId number
--- @param items { name: string, weight: number }[]
--- @return table result
local function searchVehicleWithItems(source, netId, items)
    local invId = 'trunkPLATE' .. tostring(netId)
    local slots = {}
    for i, item in ipairs(items) do
        slots[i] = { name = item.name, weight = item.weight, slot = i }
    end
    currentItemsByInvId[invId] = slots
    return searchTargetCallback(source, 'vehicle', netId)
end

t.test('BASELINE: an uncategorised item is found by a searcher with NO specializations at all', function()
    fakeNow = 20000000
    local result = searchVehicleWithItems(9101, 9101, { { name = 'weed_baggy', weight = 5 } })
    t.isTrue(result.ok)
    t.isTrue(result.contrabandFound)
    t.equals(result.totalWeight, 5)
end)

t.test('BASELINE: an uncategorised item is ALSO found by a specialist -- specializing never takes the baseline away', function()
    fakeNow = 20000100
    grantSpecialization('CITIZEN9102', 'narcotics', true)
    local result = searchVehicleWithItems(9102, 9102, { { name = 'weed_baggy', weight = 5 } })
    t.isTrue(result.contrabandFound)
    t.equals(result.totalWeight, 5, 'the baseline item must count for a specialist exactly as it does for anyone else')
end)

t.test('CATEGORISED: a searcher with NO specializations does NOT find a categorised item -- baseline items are unaffected', function()
    fakeNow = 20000200
    local result = searchVehicleWithItems(9103, 9103, {
        { name = 'weed_baggy', weight = 5 },   -- uncategorised -- still counts
        { name = 'coke_brick', weight = 100 }, -- narcotics-only -- must NOT count
    })
    t.isTrue(result.ok)
    t.isTrue(result.contrabandFound, 'the uncategorised item alone is still enough to report a find')
    t.equals(result.totalWeight, 5, 'the categorised item must be excluded entirely from the weight total -- not merely deprioritized')
end)

t.test('CATEGORISED: narcotics-only finds narcotics contraband, and does NOT find explosives contraband', function()
    fakeNow = 20000300
    grantSpecialization('CITIZEN9104', 'narcotics', true)
    local result = searchVehicleWithItems(9104, 9104, {
        { name = 'coke_brick', weight = 100 },    -- narcotics -- HELD -- counts
        { name = 'weapon_pistol', weight = 200 }, -- explosives -- NOT held -- must not count
    })
    t.isTrue(result.contrabandFound)
    t.equals(result.totalWeight, 100, 'only the narcotics-category item may count -- explosives must be fully excluded')
end)

t.test('CATEGORISED: narcotics AND explosives together find BOTH categories -- monotonic, nothing lost by adding a second specialization', function()
    fakeNow = 20000400
    grantSpecialization('CITIZEN9105', 'narcotics', true)
    grantSpecialization('CITIZEN9105', 'explosives', true)
    local result = searchVehicleWithItems(9105, 9105, {
        { name = 'coke_brick', weight = 100 },
        { name = 'weapon_pistol', weight = 200 },
        { name = 'weed_baggy', weight = 5 },
    })
    t.isTrue(result.contrabandFound)
    t.equals(result.totalWeight, 305, 'both categorised items PLUS the uncategorised baseline must all count together')
end)

t.test('MONOTONICITY: granting explosives to an ALREADY-narcotics-specialized searcher strictly ADDS the explosives find -- the narcotics find and the baseline are unaffected', function()
    fakeNow = 20000500
    grantSpecialization('CITIZEN9106', 'narcotics', true)
    local before = searchVehicleWithItems(9106, 9106, {
        { name = 'coke_brick', weight = 100 },
        { name = 'weapon_pistol', weight = 200 },
        { name = 'weed_baggy', weight = 5 },
    })
    t.equals(before.totalWeight, 105, 'PRE-GRANT: narcotics + baseline only')

    fakeNow = fakeNow + 20 -- clears the 10ms sniff/target cooldowns before re-searching the SAME target
    grantSpecialization('CITIZEN9106', 'explosives', true)
    local after = searchVehicleWithItems(9106, 9106, {
        { name = 'coke_brick', weight = 100 },
        { name = 'weapon_pistol', weight = 200 },
        { name = 'weed_baggy', weight = 5 },
    })
    t.equals(after.totalWeight, 305, 'POST-GRANT: strictly a superset -- explosives ADDED, nothing removed')
end)

t.test('CLAMP AND WARN: a Config.SearchContrabandItems entry naming a category not in Config.K9Specializations degrades to UNCATEGORISED (found by everyone) and warns', function()
    -- A SEPARATE, throwaway env/load of server/search.lua with its own
    -- malformed Config, mirroring this file's own "CONFIG-ABORT REGRESSION"
    -- section's pattern of loading a second isolated instance rather than
    -- reusing the shared one above (which already committed to its own
    -- Config.SearchContrabandItems at load time).
    local badConfig = {
        Features = { SearchZones = true },
        SearchZones = { alertBroadcastRadius = 50.0, searchCooldownMs = 5000, sniffAnimDurationMs = 10, vehicleSearchDistance = 100.0, personSearchDistance = 100.0 },
        SearchContrabandItems = { 'weed_baggy', mystery_item = 'not_a_real_specialization' },
        K9Specializations = { narcotics = { label = 'Narcotics detection' } },
        ContrabandAlertTiers = { { minWeight = 0, alert = 'clean' }, { minWeight = 1, alert = 'whine' } },
        Compat = {
            diagnosticCommand = false,
            Systems = { inventory = { override = 'ox_inventory' }, target = {}, framework = {}, dispatch = {}, ambulance = {} },
        },
    }
    local printedBad = {}
    local badEventHandlers = {}
    local badRegisteredCallbacks = {}
    local badEnv = Sandbox.newEnv({
        GetGameTimer = function() return 0 end,
        AddEventHandler = function(name, handler) badEventHandlers[name] = badEventHandlers[name] or {}; table.insert(badEventHandlers[name], handler) end,
        GetCurrentResourceName = function() return 'john-k9' end,
        -- Wait MUST actually yield (coroutine.yield()), not merely return --
        -- server/cooldowns.lua's own `while true do Wait(x) ... end` sweep
        -- thread would otherwise spin forever, synchronously, inside the
        -- ONE coroutine.resume below, hanging this entire test file.
        CreateThread = function(fn) local co = coroutine.create(fn); coroutine.resume(co) end,
        Wait = function() coroutine.yield() end,
        lib = { callback = { register = function(name, handler) badRegisteredCallbacks[name] = handler end } },
        print = function(...)
            local parts = {}
            for i = 1, select('#', ...) do parts[i] = tostring(select(i, ...)) end
            printedBad[#printedBad + 1] = table.concat(parts, '\t')
        end,
        exports = {
            ox_inventory = {
                GetInventoryItems = function() return {} end, GetContainerFromSlot = function() return nil end,
                GetItemCount = function() return 0 end, RemoveItem = function() return false end,
                RegisterStash = function() return true end, RegisterShop = function() return true end,
                registerHook = function() return 1 end,
            },
        },
        Config = badConfig,
        IsDuplicityVersion = function() return true end,
        GetResourceState = function(name) return name == 'ox_inventory' and 'started' or 'missing' end,
    })
    Sandbox.loadInto('../server/cooldowns.lua', badEnv)
    Sandbox.loadInto('../server/entities.lua', badEnv)
    Sandbox.loadInto('../server/datastore.lua', badEnv)
    Sandbox.loadInto('../server/events.lua', badEnv)
    Sandbox.loadInto('../shared/compat/core.lua', badEnv)
    Sandbox.loadInto('../shared/compat/inventory.lua', badEnv)
    Sandbox.loadInto('../server/search.lua', badEnv)

    local warned = false
    for _, line in ipairs(printedBad) do
        if line:find('mystery_item', 1, true) and line:find('not_a_real_specialization', 1, true) then warned = true end
    end
    t.isTrue(warned, 'a bad category must print a console warning naming the exact item and the exact bad category')
    -- Behavioral proof the degrade actually happened (not merely a printed
    -- warning with no real effect): drive one real search through THIS
    -- bad-config instance and confirm the mis-categorised item counts for
    -- a searcher holding NO specializations at all -- exactly the
    -- "uncategorised, found by everyone" behavior it must have degraded to.
    badEnv.HasK9Access = function() return true end
    badEnv.NetworkGetEntityFromNetworkId = function(netId) return netId end
    badEnv.DoesEntityExist = function(entity) return entity ~= 0 end
    badEnv.GetEntityType = function() return 2 end
    badEnv.GetVehicleNumberPlateText = function(entity) return 'PLATE' .. tostring(entity) end
    badEnv.GetPlayerPed = function() return 42 end
    local zeroVec = vec3(0, 0, 0)
    badEnv.GetEntityCoords = function() return zeroVec end
    badEnv.IsPedInAnyVehicle = function() return false end
    badEnv.GetPlayers = function() return {} end
    badEnv.TriggerEvent = function() end
    badEnv.TriggerClientEvent = function() end
    badEnv.MySQL = { insert = { await = function() return 1 end } }
    badEnv.exports.ox_inventory.GetInventoryItems = function(_self, invOrId)
        local invId = type(invOrId) == 'table' and invOrId.id or invOrId
        if invId == 'trunkPLATE501' then
            return { { name = 'mystery_item', weight = 42, slot = 1 } }
        end
        return {}
    end
    badEnv.exports.qbx_core = {
        GetPlayer = function(_self, source) return { PlayerData = { citizenid = 'BADCFG' .. tostring(source), job = { name = 'police' } } } end,
    }
    for _, handler in ipairs(badEventHandlers['onResourceStart'] or {}) do handler('john-k9') end

    local badSearchCallback = assert(badRegisteredCallbacks['john-k9:server:searchTarget'])
    local result = badSearchCallback(501, 'vehicle', 501)
    t.isTrue(result.ok)
    t.isTrue(result.contrabandFound, "the mis-categorised item must still be found (degraded to uncategorised) even for a searcher holding NO specializations")
    t.equals(result.totalWeight, 42, "the full weight of the degraded item must count -- the bad category must never make an item unfindable by anyone")
end)

os.exit(t.summary())
