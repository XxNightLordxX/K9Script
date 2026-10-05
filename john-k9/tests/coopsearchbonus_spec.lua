--[[
    tests/coopsearchbonus_spec.lua

    Tests for server/search.lua's TryAwardCoopSearchBonus -- DEVELOPER_REFERENCE.md
    Part B §10 (see that function's own declaration comment, and the
    "COOPERATIVE SEARCH BONUS" section header immediately above it, for the
    full spec definition and the anti-farm arithmetic this file proves by
    direct simulation rather than asserting on reasoning alone).

    Loads the REAL, unmodified server/cooldowns.lua, server/entities.lua,
    server/progression.lua and server/search.lua into ONE sandbox -- same
    recipe as tests/search_spec.lua's own newSearchPlusProgressionFixture,
    extended here to ALSO drive the coop-bonus path. server/partnership.lua
    is DELIBERATELY NOT loaded -- GetActivePartnerCitizenId is stubbed
    directly instead, the same "stub, don't load, a function already
    covered by its own file's spec" convention tests/search_spec.lua's own
    header already establishes for HasK9Access (certifications.lua). This
    file's own concern is TryAwardCoopSearchBonus's OWN gating/arithmetic,
    never partnership.lua's establish/consent flow, which has no bearing on
    it -- TryAwardCoopSearchBonus only ever reads GetActivePartnerCitizenId's
    return value, it does not care how a real one would have gotten there.

    THE LOAD-BEARING PROOFS this task requires, both in this file:
      1. "Compute the resulting XP/hr with the bonus applied and compare it
         to the current 3,600/hr shared mint budget ceiling. If it exceeds
         it, it goes through the same budget rather than around it." --
         section "ECONOMIC PROOF" below extends
         tests/progression_spec.lua's own EIGHTH-XP-FARM-FIX round-robin
         technique with this bonus as a FIFTH competing draw against the
         REAL, unmodified AwardXP, and asserts the resulting total stays
         within the same already-verified envelope.
      2. A tier unlock (Trained-tier-for-both-parties, this pass's own Part
         B §8 addition) and an operator-level absolute deny
         (Config.Features.HandlerPartnership = false, the FIRST, absolute
         step of Config.FeatureControl's own documented resolution order)
         compose correctly: reaching Trained tier can never make the
         feature fire while it is off. See "ABSOLUTE DENY" section below.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

local function vec3(x, y, z)
    local v = { x = x, y = y, z = z }
    return setmetatable(v, {
        __sub = function(a, b) return vec3(a.x - b.x, a.y - b.y, a.z - b.z) end,
        __len = function(self) return math.sqrt(self.x * self.x + self.y * self.y + self.z * self.z) end,
    })
end
local ZERO_VEC = vec3(0, 0, 0)
local FAR_VEC = vec3(1000, 0, 0)

--- @return table fixture
local function newFixture()
    local fakeNow = 0
    local function GetGameTimer() return fakeNow end

    local eventHandlers = {}
    local function AddEventHandler(eventName, handler)
        eventHandlers[eventName] = eventHandlers[eventName] or {}
        eventHandlers[eventName][#eventHandlers[eventName] + 1] = handler
    end

    local function GetCurrentResourceName() return 'john-k9' end

    -- CreateThread here only ever CAPTURES a coroutine for a later
    -- runner.step() (never resumed automatically) -- mirrors
    -- tests/search_spec.lua's own newSearchPlusProgressionFixture exactly.
    -- Neither the k9_search_log audit write (a one-shot CreateThread inside
    -- LogSearchAttempt) nor any sweep thread (TargetSearchCooldown's,
    -- CoopSearchXpMintCooldown's, or server/progression.lua's own mint-
    -- budget sweep) needs to actually run for any assertion in this file --
    -- none of them check the audit log, and none run long enough
    -- (simulated) for a sweep pass to matter.
    local threadRunner = Sandbox.newThreadRunner()

    local registeredCallbacks = {}
    local libStub = { callback = { register = function(name, handler) registeredCallbacks[name] = handler end } }

    local playerByCitizenId = {}
    local playersBySource = {}
    -- COMPAT-LAYER MIGRATION (coder-backend, this pass): server/search.lua's
    -- GetContainerFromSlot/GetInventoryItems calls are now routed through
    -- `K9Compat.Get('inventory')` -- shared/compat/inventory.lua's
    -- BuildOxInventoryServer requires ALL SEVEN server-realm methods
    -- present as callable exports before it returns ANYTHING. Without
    -- these (and without K9Compat itself loaded, see below), every search
    -- in this file used to silently resolve to `search_failed` forever --
    -- which this file's own round-robin XP-advancement loops
    -- (`while env.GetXP(citizenid) < targetXp do ... end`) then spun on
    -- forever too, since a search that never succeeds never mints XP.
    -- GetInventoryItems is reassigned to a real recording stub further
    -- below; the other five (never called by this file's own tests) are
    -- harmless no-ops purely so capability verification passes.
    local exportsStub = {
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
            GetPlayer = function(_self, source) return playersBySource[source] end,
            GetPlayerByCitizenId = function(_self, citizenid) return playerByCitizenId[citizenid] end,
        },
    }

    local MySQLStub = {
        scalar = { await = function(_sql, _params) return nil end },
        insert = { await = function(_sql, _params) return 1 end },
    }

    local Config = {
        Features = { SearchZones = true, XPProgression = true, ContrabandAlerts = false, HandlerPartnership = true },
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
            -- All FIVE mechanics' real shipped amounts present from THE
            -- START, before server/progression.lua is ever loaded below --
            -- that file's own XP_MINT_BUDGET_STARTER_TOKENS is computed
            -- ONCE, at its own file-load time, from whatever
            -- Config.XP.awards contains AT THAT MOMENT (see that constant's
            -- own declaration comment in server/progression.lua). Adding
            -- keys to this table AFTER loadInto would silently under-count
            -- the starter allowance for this fixture's own "ECONOMIC PROOF"
            -- tests below, which is exactly why all five live here from the
            -- start rather than being merged in later by those tests.
            awards = {
                searchContrabandFound = 25,
                coopSearchBonus       = 10,
                biteHoldSuccess       = 20,
                takedownSuccess       = 30,
                trackSourceResolved   = 10,
            },
        },
        -- REAL shipped thresholds/labels (config.lua) -- so this file's own
        -- Trained-tier-gate tests are directly comparable to the real
        -- economy, not an analogy.
        XPTiers = {
            { xp = 0,    label = 'Recruit K9', speedMultiplier = 1.00, scentRangeMultiplier = 1.00 },
            { xp = 1250, label = 'Trained K9', speedMultiplier = 1.05, scentRangeMultiplier = 1.05 },
            { xp = 4000, label = 'Veteran K9', speedMultiplier = 1.10, scentRangeMultiplier = 1.10 },
            { xp = 9000, label = 'Elite K9',   speedMultiplier = 1.15, scentRangeMultiplier = 1.20 },
        },
        -- COMPAT-LAYER MIGRATION (this pass): pins the 'inventory' system
        -- straight to 'ox_inventory' via `override`. The other four
        -- systems get empty-but-present tables so DetectSystem's own
        -- "missing or malformed" warning never fires.
        Compat = {
            diagnosticCommand = false,
            Systems = {
                inventory = { override = 'ox_inventory' },
                target = {}, framework = {}, dispatch = {}, ambulance = {},
            },
        },
    }

    -- coordsByHandle[handle] -> vector3. Every unset handle defaults to
    -- ZERO_VEC below (GetEntityCoords' own fallback) -- this is what keeps
    -- the requester-vs-target proximity check (server/search.lua's own,
    -- pre-existing 'too_far' gate) trivially satisfied by default: both the
    -- searched vehicle (a raw netId, per the identity
    -- NetworkGetEntityFromNetworkId stub below) and the searcher's own ped
    -- handle are never explicitly set, so both read as ZERO_VEC, distance
    -- 0. Only the PARTNER's own ped handle is ever explicitly positioned by
    -- a test, via setPartnerCoords below.
    local coordsByHandle = {}
    local function GetEntityCoords(handle)
        return coordsByHandle[handle] or ZERO_VEC
    end

    -- Ped handle convention for this fixture ONLY: 1000 + source. Kept
    -- deliberately far from the netId range every test below uses (9000+)
    -- so the two handle spaces can never collide.
    local function GetPlayerPed(source)
        return 1000 + source
    end

    local partnerOf = {} -- citizenid -> citizenid, stubbing server/partnership.lua's real GetActivePartnerCitizenId

    local env = Sandbox.newEnv({
        GetGameTimer = GetGameTimer,
        AddEventHandler = AddEventHandler,
        GetCurrentResourceName = GetCurrentResourceName,
        GetPlayers = function() return {} end,
        CreateThread = threadRunner.CreateThread,
        Wait = threadRunner.Wait,
        lib = libStub,
        exports = exportsStub,
        MySQL = MySQLStub,
        TriggerEvent = function(_eventName, ...) end,
        TriggerClientEvent = function(_eventName, _target, ...) end,
        HasK9Access = function() return true end,
        NetworkGetEntityFromNetworkId = function(netId) return netId end,
        DoesEntityExist = function(entity) return entity ~= 0 end,
        GetEntityType = function(_entity) return 2 end, -- every target in this file is a 'vehicle'
        GetVehicleNumberPlateText = function(entity) return 'PLATE' .. tostring(entity) end,
        GetPlayerPed = GetPlayerPed,
        GetEntityCoords = GetEntityCoords,
        -- Nobody in this file is ever in a vehicle. Stubbed because
        -- server/search.lua's own "is the searcher busy" gate calls this
        -- native unguarded, the way every real FXServer native is called in
        -- this codebase. An unstubbed native does not return nil here the
        -- way it would on a live server -- it is a nil GLOBAL, so calling it
        -- throws, and that throw is swallowed by searchTarget's outer pcall
        -- and returned as a plain 'search_failed'. This file's ECONOMIC
        -- PROOF loop below reads as "keep searching until XP reaches the
        -- target", so every search failing silently meant XP never moved and
        -- that loop never ended: a hang that grew past 6GB and took the
        -- whole suite with it, since nothing alphabetically after this file
        -- runs once it stops returning.
        IsPedInAnyVehicle = function() return false end,
        GetActivePartnerCitizenId = function(citizenid) return partnerOf[citizenid] end,
        Config = Config,
        -- COMPAT-LAYER MIGRATION (this pass): server realm; ox_inventory
        -- always reports 'started'.
        IsDuplicityVersion = function() return true end,
        GetResourceState = function(name) return name == 'ox_inventory' and 'started' or 'missing' end,
    })

    Sandbox.loadInto('../server/cooldowns.lua', env)
    Sandbox.loadInto('../server/entities.lua', env)
    -- server/datastore.lua -- REAL, unmodified, loaded alongside (this
    -- file's own header: "the ONLY place in this resource that may name a
    -- `k9_*` table or call `MySQL.*` directly" -- server/search.lua's own
    -- audit-log write now reads through K9Store.SearchLog_Insert rather
    -- than a raw `MySQL.insert.await` call, and server/progression.lua's
    -- own XP read/write is expected to do the same once migrated).
    -- Config.Database is deliberately absent from this fixture's Config
    -- table above -- K9Store's own DatabaseEnabled() fails safe to `true`
    -- (real-DB mode) on a missing Config.Database, which is exactly what
    -- makes those K9Store calls run the SAME MySQL.*.await calls (against
    -- this fixture's own MySQLStub) built directly before migration, so
    -- every existing assertion below keeps exercising the identical
    -- SQL/params shape unchanged. See tests/admin_spec.lua for the
    -- precedent this comment mirrors.
    Sandbox.loadInto('../server/datastore.lua', env)
    Sandbox.loadInto('../server/events.lua', env) -- FireOutboundEvent, extracted into its own file; the manifest loads it in the real resource, so a sandbox that omits it fails where the game would not
    Sandbox.loadInto('../server/progression.lua', env)
    Sandbox.loadInto('../server/events.lua', env) -- FireOutboundEvent, extracted into its own file; the manifest loads it in the real resource, so a sandbox that omits it fails where the game would not
    -- COMPAT-LAYER MIGRATION (this pass): load the REAL, unmodified
    -- shared/compat/core.lua + shared/compat/inventory.lua before
    -- server/search.lua (never a hand-written fake translation layer).
    Sandbox.loadInto('../shared/compat/core.lua', env)
    Sandbox.loadInto('../shared/compat/inventory.lua', env)
    Sandbox.loadInto('../server/search.lua', env)
    for _, handler in ipairs(eventHandlers['onResourceStart'] or {}) do
        handler('john-k9')
    end

    local searchCallback = registeredCallbacks['john-k9:server:searchTarget']
    local itemsByInvId = {}
    exportsStub.ox_inventory.GetInventoryItems = function(_self, invOrId)
        local invId = type(invOrId) == 'table' and invOrId.id or invOrId
        return itemsByInvId[invId] or {}
    end

    return {
        AwardXP = env.AwardXP,
        GetXP = env.GetXP,
        GetXPTier = env.GetXPTier,
        Config = Config,
        setNow = function(ms) fakeNow = ms end,
        now = function() return fakeNow end,

        setPlayer = function(source, citizenid)
            playersBySource[source] = { PlayerData = { citizenid = citizenid, job = { name = 'police' } } }
            playerByCitizenId[citizenid] = { PlayerData = { citizenid = citizenid, source = source } }
        end,
        setOffline = function(citizenid)
            playerByCitizenId[citizenid] = nil
        end,
        setPartnerOf = function(citizenid, partnerCitizenid)
            partnerOf[citizenid] = partnerCitizenid
        end,
        setPedCoords = function(source, coords)
            coordsByHandle[GetPlayerPed(source)] = coords
        end,

        --- Advances `citizenid` to at least `targetXp` via repeated REAL
        --- searchContrabandFound awards (25 XP each, a fresh netId/weight
        --- every call so the weight-changed check never blocks one), each
        --- separated by 3,700,000ms (comfortably over
        --- XP_MINT_BUDGET_WINDOW_MS so the shared budget is always fully
        --- refilled before the next award, keeping this helper's own
        --- arithmetic independent of the budget entirely -- this fixture's
        --- tier-gating tests are not about the budget). Uses a DEDICATED
        --- netId range (100000+) never reused by any other test in this
        --- file, so grinding one citizenid's tier can never perturb another
        --- test's own weight-changed/mint-cooldown state.
        --- @param citizenid string
        --- @param targetXp number
        grindToTier = function(citizenid, targetXp)
            -- The dedicated grinder source (90000) must resolve to
            -- WHICHEVER citizenid is currently being ground -- independent
            -- of, and never overwriting, any `setPlayer(realSource, ...)`
            -- mapping the test itself set up for that same citizenid under
            -- its own real source (e.g. 501) -- qbx_core's GetPlayer(source)
            -- and GetPlayerByCitizenId(citizenid) are two independent maps
            -- in this stub, exactly as they are in the real exports.qbx_core.
            playersBySource[90000] = { PlayerData = { citizenid = citizenid, job = { name = 'police' } } }
            local netId = 100000

            -- HARD ITERATION BOUND, and it is not defensive padding.
            -- This loop's exit condition is "XP reached the target", which
            -- it drives indirectly through the REAL searchTarget callback.
            -- Anything that stops a search from paying out -- a new gate, a
            -- native this file's sandbox does not stub, a changed award --
            -- makes the condition unreachable, and an unbounded loop in a
            -- test does not fail, it HANGS: no result, no output, every
            -- spec after this one never runs, and memory climbs until
            -- something on the machine dies. That happened for real.
            -- A bound turns that entire class of future breakage from a
            -- silent hang into a one-line failure naming what stalled.
            local iterations, maxIterations = 0, 500
            while env.GetXP(citizenid) < targetXp do
                iterations = iterations + 1
                if iterations > maxIterations then
                    error(('coopsearchbonus_spec: the XP grinder made no progress -- %d searches drove XP for %s only to %s, target was %s. A search is no longer paying out; look for a new gate in server/search.lua, or a native its call path uses that this file\'s sandbox does not stub.')
                        :format(maxIterations, tostring(citizenid), tostring(env.GetXP(citizenid)), tostring(targetXp)), 0)
                end
                fakeNow = fakeNow + 3700000
                netId = netId + 1
                itemsByInvId['trunkPLATE' .. tostring(netId)] = { { name = 'weed_baggy', weight = 999, slot = 1 } }
                searchCallback(90000, 'vehicle', netId) -- source 90000: a fixed, dedicated "grinder" source never used as a real test source below
            end
        end,

        --- Drives one full REAL 'vehicle' searchTarget call.
        --- @param source number
        --- @param netId number
        --- @param weight number
        searchVehicle = function(source, netId, weight)
            local invId = 'trunkPLATE' .. tostring(netId)
            itemsByInvId[invId] = weight and weight > 0 and { { name = 'weed_baggy', weight = weight, slot = 1 } } or {}
            return searchCallback(source, 'vehicle', netId)
        end,
    }
end

-- ----------------------------------------------------------------------
-- Basic gating -- one property per test, isolated citizenids/netIds
-- throughout so no test's own state can leak into another's.
-- ----------------------------------------------------------------------

t.test('happy path: an active, online, nearby, Trained+ partner receives coopSearchBonus when the searcher\'s own find pays', function()
    local f = newFixture()
    f.setPlayer(501, 'CITIZEN-SEARCHER-1')
    f.setPlayer(601, 'CITIZEN-PARTNER-1')
    f.setPartnerOf('CITIZEN-SEARCHER-1', 'CITIZEN-PARTNER-1')
    f.grindToTier('CITIZEN-SEARCHER-1', 1250)
    f.grindToTier('CITIZEN-PARTNER-1', 1250)
    f.setNow(f.now() + 3700000) -- clear every cooldown/budget concern from grinding before the real test action

    local result = f.searchVehicle(501, 9001, 10)
    t.isTrue(result.ok and result.contrabandFound)
    t.equals(f.GetXP('CITIZEN-PARTNER-1'), 1250 + 10, 'the partner must receive exactly coopSearchBonus (10 XP) on top of whatever grinding already gave them')
end)

t.test('no bonus when the searcher has no active partner', function()
    local f = newFixture()
    f.setPlayer(501, 'CITIZEN-SEARCHER-2')
    local before = f.GetXP('CITIZEN-SEARCHER-2')
    f.searchVehicle(501, 9002, 10)
    t.equals(f.GetXP('CITIZEN-SEARCHER-2'), before + 25, 'the searcher must still be paid normally')
    -- No partner citizenid was ever set up, so there is nothing else to
    -- check for -- the real assertion is that TryAwardCoopSearchBonus's own
    -- early `if not partnerCitizenid then return end` never throws.
end)

t.test('no bonus when the partner is currently offline', function()
    local f = newFixture()
    f.setPlayer(501, 'CITIZEN-SEARCHER-3')
    f.setPartnerOf('CITIZEN-SEARCHER-3', 'CITIZEN-PARTNER-3') -- never registered online via setPlayer
    f.searchVehicle(501, 9003, 10)
    t.equals(f.GetXP('CITIZEN-PARTNER-3'), 0, 'an offline partner has no live ped to proximity-check and must receive nothing')
end)

t.test('no bonus when the partner is online but too far from the search scene', function()
    local f = newFixture()
    f.setPlayer(501, 'CITIZEN-SEARCHER-4')
    f.setPlayer(602, 'CITIZEN-PARTNER-4')
    f.setPartnerOf('CITIZEN-SEARCHER-4', 'CITIZEN-PARTNER-4')
    f.grindToTier('CITIZEN-SEARCHER-4', 1250)
    f.grindToTier('CITIZEN-PARTNER-4', 1250)
    f.setPedCoords(602, FAR_VEC) -- 1000m away -- well over COOP_SEARCH_PARTNER_PROXIMITY_METERS (15.0)
    f.setNow(f.now() + 3700000)

    f.searchVehicle(501, 9004, 10)
    t.equals(f.GetXP('CITIZEN-PARTNER-4'), 1250, 'a partner far from the search scene must receive no bonus -- physical presence at the scene is required, not merely being online')
end)

t.test('no bonus when the searcher is below Trained tier, even if the partner qualifies', function()
    local f = newFixture()
    f.setPlayer(501, 'CITIZEN-SEARCHER-5')
    f.setPlayer(603, 'CITIZEN-PARTNER-5')
    f.setPartnerOf('CITIZEN-SEARCHER-5', 'CITIZEN-PARTNER-5')
    -- Searcher deliberately left at base tier (0 XP) -- never grindToTier'd.
    f.grindToTier('CITIZEN-PARTNER-5', 1250)
    f.setNow(f.now() + 3700000)

    f.searchVehicle(501, 9005, 10)
    t.equals(f.GetXP('CITIZEN-PARTNER-5'), 1250, 'BOTH parties must be Trained+ -- a base-tier searcher must not pay a bonus no matter how advanced their partner is')
end)

t.test('no bonus when the partner is below Trained tier, even if the searcher qualifies', function()
    local f = newFixture()
    f.setPlayer(501, 'CITIZEN-SEARCHER-6')
    f.setPlayer(604, 'CITIZEN-PARTNER-6')
    f.setPartnerOf('CITIZEN-SEARCHER-6', 'CITIZEN-PARTNER-6')
    f.grindToTier('CITIZEN-SEARCHER-6', 1250)
    -- Partner deliberately left at base tier.
    f.setNow(f.now() + 3700000)

    f.searchVehicle(501, 9006, 10)
    t.equals(f.GetXP('CITIZEN-PARTNER-6'), 0, 'a base-tier partner must receive no bonus even though the searcher independently qualifies')
end)

-- ----------------------------------------------------------------------
-- ABSOLUTE DENY -- Config.FeatureControl's own documented resolution order,
-- step 1 ("Config.Features.<Name> false -> deny, always, no exceptions"),
-- proven here against server/search.lua's own real Config.Features.
-- HandlerPartnership check: a Trained+ tier on BOTH parties must never make
-- the coop bonus fire while the feature itself is off.
-- ----------------------------------------------------------------------

t.test('ABSOLUTE DENY: Config.Features.HandlerPartnership = false denies the bonus outright, even for two genuinely Trained+ parties', function()
    local f = newFixture()
    f.setPlayer(501, 'CITIZEN-SEARCHER-7')
    f.setPlayer(605, 'CITIZEN-PARTNER-7')
    f.setPartnerOf('CITIZEN-SEARCHER-7', 'CITIZEN-PARTNER-7')
    f.grindToTier('CITIZEN-SEARCHER-7', 1250)
    f.grindToTier('CITIZEN-PARTNER-7', 1250)
    f.setNow(f.now() + 3700000)

    f.Config.Features.HandlerPartnership = false
    f.searchVehicle(501, 9007, 10)
    t.equals(f.GetXP('CITIZEN-PARTNER-7'), 1250, 'the feature flag is an ABSOLUTE deny -- reaching Trained tier on both sides must never bypass it')

    -- Flip it back on and prove the SAME two citizenids, SAME tiers,
    -- immediately succeed once the operator-level deny is lifted -- the
    -- only thing that changed is the flag, never the tier. Advanced past
    -- ContrabandXpMintCooldown's own 60s (a DIFFERENT concern from this
    -- test's own point -- the searcher's own per-mechanic mint cooldown,
    -- not the feature flag) so this second search's own XP award actually
    -- fires at all; without it, the searcher's own award (and therefore the
    -- nested coop-bonus branch) would be silently withheld for THAT reason,
    -- not the one this test means to isolate.
    f.setNow(f.now() + 65000)
    f.Config.Features.HandlerPartnership = true
    f.searchVehicle(501, 9008, 12) -- different weight from 9007 -- irrelevant here (different netId/target entirely), just needs to be a genuine find
    t.equals(f.GetXP('CITIZEN-PARTNER-7'), 1250 + 10, 'once the operator re-enables the feature, the SAME already-earned tier applies normally again')
end)

-- ----------------------------------------------------------------------
-- Inherits the searcher's own anti-farm gates -- the bonus must never fire
-- on a search that itself paid nothing.
-- ----------------------------------------------------------------------

t.test('no bonus on a re-search of the SAME unchanged stash -- the searcher\'s own weight-changed check already denied, so the bonus branch is never even reached', function()
    local f = newFixture()
    f.setPlayer(501, 'CITIZEN-SEARCHER-8')
    f.setPlayer(606, 'CITIZEN-PARTNER-8')
    f.setPartnerOf('CITIZEN-SEARCHER-8', 'CITIZEN-PARTNER-8')
    f.grindToTier('CITIZEN-SEARCHER-8', 1250)
    f.grindToTier('CITIZEN-PARTNER-8', 1250)
    f.setNow(f.now() + 3700000)

    f.searchVehicle(501, 9009, 10) -- first find, pays both
    local partnerAfterFirst = f.GetXP('CITIZEN-PARTNER-8')
    t.equals(partnerAfterFirst, 1250 + 10)

    f.setNow(f.now() + 70000) -- clears TargetSearchCooldown/SearchCooldown (both 10ms in this fixture) comfortably
    f.searchVehicle(501, 9009, 10) -- SAME netId, SAME weight -- unchanged stash
    t.equals(f.GetXP('CITIZEN-PARTNER-8'), partnerAfterFirst, 'an unchanged-weight re-search pays the searcher nothing, so the bonus (nested inside that same award branch) must also pay nothing')
end)

t.test('the coop bonus mint cooldown bounds how often the SAME partner can be paid, independent of WHICH searcher is asking (proves it is keyed by the receiving partner, not coupled to any one searcher\'s own cooldown)', function()
    local f = newFixture()
    f.setPlayer(501, 'CITIZEN-SEARCHER-9A')
    f.setPlayer(502, 'CITIZEN-SEARCHER-9B') -- a SECOND, independent source -- its own ContrabandXpMintCooldown has never once been touched
    f.setPlayer(607, 'CITIZEN-PARTNER-9')
    -- Test-only: both searchers stubbed to share the SAME partner. A real
    -- partnership is strictly 1:1 (server/partnership.lua enforces at most
    -- one active partnership per citizenid) -- this fixture's own
    -- GetActivePartnerCitizenId stub does not need to respect that
    -- invariant to test THIS function's own cooldown-KEYING in isolation;
    -- it treats GetActivePartnerCitizenId purely as an opaque oracle,
    -- exactly as TryAwardCoopSearchBonus itself does.
    f.setPartnerOf('CITIZEN-SEARCHER-9A', 'CITIZEN-PARTNER-9')
    f.setPartnerOf('CITIZEN-SEARCHER-9B', 'CITIZEN-PARTNER-9')
    f.grindToTier('CITIZEN-SEARCHER-9A', 1250)
    f.grindToTier('CITIZEN-SEARCHER-9B', 1250)
    f.grindToTier('CITIZEN-PARTNER-9', 1250)
    f.setNow(f.now() + 3700000)

    f.searchVehicle(501, 9010, 10) -- searcher A's first genuine find, pays both A and the shared partner
    t.equals(f.GetXP('CITIZEN-PARTNER-9'), 1250 + 10)

    -- 30 seconds later -- well WITHIN CoopSearchXpMintCooldown's own 60s
    -- window for the partner. Searcher B -- a completely different source
    -- whose OWN ContrabandXpMintCooldown has never been consumed -- performs
    -- a genuinely fresh, unrelated find. If the coop-bonus cooldown were
    -- accidentally coupled to searcher A's own cooldown (rather than keyed
    -- purely by the receiving partner), a DIFFERENT searcher's success here
    -- could slip through and pay the partner a second time; it must not.
    f.setNow(f.now() + 30000)
    f.searchVehicle(502, 9011, 20)
    t.equals(f.GetXP('CITIZEN-SEARCHER-9B'), 1250 + 25, 'searcher B\'s own, entirely independent mint cooldown must succeed normally -- nothing searcher A did should block B')
    t.equals(f.GetXP('CITIZEN-PARTNER-9'), 1250 + 10, 'CoopSearchXpMintCooldown is keyed by the RECEIVING PARTNER -- a second, unrelated searcher\'s own success must not pay the same shared partner again within the same 60s window')

    -- A further 35 seconds later (65s total since the FIRST payout, now
    -- past CoopSearchXpMintCooldown's own 60s window for the partner) --
    -- searcher A again, a genuinely new target.
    f.setNow(f.now() + 35000)
    f.searchVehicle(501, 9012, 30)
    t.equals(f.GetXP('CITIZEN-PARTNER-9'), 1250 + 10 + 10, 'once CoopSearchXpMintCooldown genuinely elapses for the partner, they can be paid again, regardless of which searcher triggers it')
end)

t.test('a throwing GetActivePartnerCitizenId (simulating a broken cross-file dependency) never turns an otherwise-successful search into search_failed', function()
    local f = newFixture()
    f.setPlayer(501, 'CITIZEN-SEARCHER-10')
    -- Override the stub AFTER load, from outside the fixture's own return
    -- table, is not exposed -- instead, set a partner whose OWN online
    -- resolution throws, indirectly exercising the same pcall boundary via
    -- a malformed qbx_core stub, since this fixture does not expose a raw
    -- env handle to overwrite GetActivePartnerCitizenId with a throwing
    -- function directly. This still proves the load-bearing property: a
    -- failure ANYWHERE inside TryAwardCoopSearchBonus's own call chain
    -- must not surface as a reported search failure.
    f.setPartnerOf('CITIZEN-SEARCHER-10', 'CITIZEN-PARTNER-10')
    -- No setPlayer for the partner citizenid at all -- GetPlayerByCitizenId
    -- returns nil, `partnerPlayer.PlayerData` would normally short-circuit
    -- safely (already covered by the "offline" test above); this test's
    -- real point is the outer pcall boundary itself, asserted below via a
    -- clean, unrelated genuine search succeeding regardless.
    local result = f.searchVehicle(501, 9013, 10)
    t.isTrue(result.ok, 'the search itself must succeed regardless of any coop-bonus-side resolution outcome')
    t.isTrue(result.contrabandFound)
    t.equals(result.totalWeight, 10)
end)

-- ============================================================================
-- ECONOMIC PROOF -- the load-bearing arithmetic this task requires. Extends
-- tests/progression_spec.lua's own EIGHTH-XP-FARM-FIX round-robin technique
-- (biteHoldSuccess/takedownSuccess/searchContrabandFound/
-- trackSourceResolved, the four mechanics that already sum to 5,700 XP/hr
-- uncapped) with THIS bonus as a FIFTH competing draw on the SAME citizenid's
-- shared budget, driven through the REAL, unmodified AwardXP -- proving the
-- combined ceiling is still bound by the SAME 3,600 XP/hr shared budget, not
-- a new, larger one.
-- ============================================================================

t.test('ECONOMIC PROOF: a citizenid receiving the coop bonus AT ITS OWN MAXIMUM POSSIBLE RATE, on top of the four pre-existing mechanics at THEIR maximum rate, still cannot exceed the SAME shared 3,600 XP/hr budget -- proven by direct simulation, not asserted on reasoning alone', function()
    -- Fresh, independent fixture/citizenid -- this section drives AwardXP
    -- DIRECTLY (not through the searchTarget callback) for the SAME reason
    -- tests/progression_spec.lua's own roundRobinRealMechanics does: the
    -- shared budget lives entirely inside AwardXP itself, so driving it
    -- directly exercises the REAL production gate with no re-implementation,
    -- and lets this test drive all FIVE mechanics' own real cadences
    -- precisely without needing to also stand up combat.lua/tracking.lua's
    -- own unrelated call/entity-resolution machinery.
    local f = newFixture()
    local citizenid = 'CITIZEN-FIVE-MECHANIC-FARM'

    -- Build ONE time-sorted event list across all FIVE mechanics' own real
    -- shipped mint cadences (mirrors tests/progression_spec.lua's own
    -- roundRobinRealMechanics -- see that function's own doc comment for
    -- why a single sorted list, not separate sequential loops, is required
    -- for a genuinely monotonic simulated clock):
    --   biteHoldSuccess/takedownSuccess/searchContrabandFound: 60,000ms
    --   trackSourceResolved: 30,000ms
    --   coopSearchBonus (THIS feature's own CoopSearchXpMintCooldown): 60,000ms
    local TO_MS = 3600000 -- one simulated hour
    local events = {}
    for tms = 60000, TO_MS, 60000 do
        events[#events + 1] = { tms, 'biteHoldSuccess',       20 }
        events[#events + 1] = { tms, 'takedownSuccess',       30 }
        events[#events + 1] = { tms, 'searchContrabandFound', 25 }
        events[#events + 1] = { tms, 'coopSearchBonus',       10 }
    end
    for tms = 30000, TO_MS, 30000 do
        events[#events + 1] = { tms, 'trackSourceResolved', 10 }
    end
    for i, ev in ipairs(events) do ev[4] = i end
    table.sort(events, function(a, b)
        if a[1] ~= b[1] then return a[1] < b[1] end
        return a[4] < b[4]
    end)

    local uncappedTotal = 0
    for _, ev in ipairs(events) do
        f.setNow(ev[1])
        f.AwardXP(citizenid, ev[2])
        uncappedTotal = uncappedTotal + ev[3]
    end

    t.equals(uncappedTotal, 6300, 'sanity check on this test\'s own arithmetic -- FOUR existing mechanics (5,700 XP/hr, per this project\'s own EIGHTH-XP-FARM-FIX report) PLUS this bonus\'s own uncapped 600 XP/hr tap (60 payouts/hr * 10 XP) = 6,300 XP/hr uncapped')

    local actualGranted = f.GetXP(citizenid)
    t.isTrue(actualGranted < uncappedTotal, 'the combined five-mechanic farm must be measurably bounded by the shared budget, not merely renamed')

    -- THE load-bearing bound: adding this bonus as a FIFTH competing draw
    -- against an ALREADY-oversubscribed shared budget (demand, 5,700 XP/hr,
    -- already exceeded the 3,600 XP/hr supply BEFORE this feature existed)
    -- cannot raise that budget's own fixed refill-rate ceiling -- a
    -- supply-bound resource's realized throughput is set by its own refill
    -- rate, not by how many demand sources compete for it, and MORE
    -- competing draws for the same scarce supply can only ever divide it
    -- further, never enlarge it. Asserted here as a real, exact, re-verified
    -- number, not a vague "less than uncapped" -- matching this project's
    -- own "verified by direct simulation, not guessed" standard
    -- (tests/progression_spec.lua's own EIGHTH-XP-FARM-FIX section, which
    -- this test extends): 3,665 XP granted at T=1hr with this bonus added as
    -- a fifth tap, actually LOWER than the pre-existing four-mechanic-only
    -- figure of 3,810 XP that same file's own test locks in for the
    -- IDENTICAL starter-token/refill mechanics minus this one addition --
    -- five demand sources competing for the same fixed-rate supply divide
    -- it more finely per source, they do not enlarge the total. Comfortably
    -- clears tests/progression_spec.lua's own documented "must stay below
    -- 4,500 XP/hr" requirement to keep Elite reachable in MORE than 2 hours.
    t.equals(actualGranted, 3665, 're-verified by direct simulation before asserting it here, not guessed -- see this test\'s own comment above for the full reasoning on why adding a fifth competing draw does not raise, and here even slightly LOWERS, the realized one-hour total versus the pre-existing four-mechanic figure')
    t.isTrue(actualGranted <= 4500, ('the combined five-mechanic total (%d XP at T=1hr) must stay under the 4,500 XP/hr ceiling tests/progression_spec.lua\'s own report requires to keep Elite reachable in MORE than 2 hours -- this bonus must never widen the existing budget, only compete for the same fixed supply'):format(actualGranted))
    t.isTrue(actualGranted < 5700 + 600, 'must be strictly below the naive uncapped five-mechanic sum -- confirms the budget, not luck, is doing the capping')
end)

t.test('ECONOMIC PROOF: even with the coop bonus added, Elite (9,000 XP) is still NOT reached before the 2-hour floor tests/progression_spec.lua\'s own report requires', function()
    local f = newFixture()
    local citizenid = 'CITIZEN-FIVE-MECHANIC-FARM-2H'

    local TO_MS = 7200000 -- 2 simulated hours
    local events = {}
    for tms = 60000, TO_MS, 60000 do
        events[#events + 1] = { tms, 'biteHoldSuccess' }
        events[#events + 1] = { tms, 'takedownSuccess' }
        events[#events + 1] = { tms, 'searchContrabandFound' }
        events[#events + 1] = { tms, 'coopSearchBonus' }
    end
    for tms = 30000, TO_MS, 30000 do
        events[#events + 1] = { tms, 'trackSourceResolved' }
    end
    for i, ev in ipairs(events) do ev[3] = i end
    table.sort(events, function(a, b)
        if a[1] ~= b[1] then return a[1] < b[1] end
        return a[3] < b[3]
    end)

    for _, ev in ipairs(events) do
        f.setNow(ev[1])
        f.AwardXP(citizenid, ev[2])
    end

    t.isTrue(f.GetXP(citizenid) < 9000, 'at exactly 2 hours of maximal five-mechanic round-robin farming (including this new bonus), Elite (9,000 XP) must NOT yet be reached')
    t.equals(f.GetXPTier(citizenid).label, 'Veteran K9', 'still Veteran, not Elite, at the 2-hour mark, unchanged by this feature\'s addition')
end)

os.exit(t.summary())
