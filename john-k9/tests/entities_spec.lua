--[[
    tests/entities_spec.lua

    Direct tests of server/entities.lua's ResolveNetworkEntity and
    ResolveConnectedPlayerFromPed against the REAL, unmodified production
    file. Both are resource-globals (no `local`) per that file's own
    FILE-TO-FILE CONTRACT, so unlike server/search.lua's local
    ResolveAlertTier (see DEVELOPER_REFERENCE.md's "not covered" section), no
    RegisterCommand/callback indirection is needed to reach them -- they're
    called directly, exactly as server/main.lua/server/search.lua/
    server/kennel.lua/server/inventory.lua already do.

    ResolveNetworkEntity is the security chokepoint every client-supplied
    netId in this resource passes through before anything else touches it
    (that file's own header: "audited as a security primitive, not just a
    convenience wrapper"). This spec locks in its documented GUARANTEES
    section literally: non-number rejection, the existence guard (0 AND
    DoesEntityExist), and that an expectedEntityType mismatch is a hard
    `nil` reject, never advisory.

    Only FiveM natives this file touches are stubbed: NetworkGetEntityFromNetworkId,
    DoesEntityExist, GetEntityType (all test-controlled maps/sets) and
    GetPlayers/GetPlayerPed (for ResolveConnectedPlayerFromPed).

    Also covers ClaimNetworkEntity/ReleaseNetworkEntity/
    IsNetworkEntityClaimedByOther (coder-architect, this pass) -- the
    CROSS-FEATURE NETID CLAIM REGISTRY that closes the residual gap
    server/kennel.lua's and server/fetch.lua's own header comments each
    disclosed (see this file's own header section for the full writeup):
    three resource-globals, no natives involved at all, so these tests need
    no additional stubs beyond testkit itself. The actual CROSS-FILE
    integration -- proving server/kennel.lua's and server/fetch.lua's own
    confirm handlers genuinely share ONE registry instance and correctly
    reject a cross-feature collision -- is covered in kennel_spec.lua's and
    fetch_spec.lua's own dedicated CROSS-FEATURE sections (a combined
    fixture loading both production files together), not duplicated here;
    this file only proves the three primitives' own, file-local contract in
    isolation.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

-- ----------------------------------------------------------------------
-- Sandbox setup
-- ----------------------------------------------------------------------

-- netId -> entity handle, exactly as NetworkGetEntityFromNetworkId's real
-- contract: returns 0 for anything it doesn't recognize (never nil, never
-- an error) -- includes floats/negatives, which is why this file's own doc
-- comment says those are rejected via the existence guard, not the type
-- check.
local networkEntities = {}
local function NetworkGetEntityFromNetworkId(netId)
    return networkEntities[netId] or 0
end

-- entity handle -> true/false, models a stale handle (nonzero from the
-- native above, but no longer live) independently of the netId map.
local existingEntities = {}
local function DoesEntityExist(entity)
    return existingEntities[entity] == true
end

-- entity handle -> GetEntityType's real return domain (1 = ped, 2 = vehicle,
-- 3 = object).
local entityTypes = {}
local function GetEntityType(entity)
    return entityTypes[entity] or 0
end

local connectedPlayerIds = {}
local function GetPlayers()
    return connectedPlayerIds
end

local pedsByPlayerId = {}
local function GetPlayerPed(playerId)
    return pedsByPlayerId[playerId] or 0
end

local env = Sandbox.newEnv({
    NetworkGetEntityFromNetworkId = NetworkGetEntityFromNetworkId,
    DoesEntityExist = DoesEntityExist,
    GetEntityType = GetEntityType,
    GetPlayers = GetPlayers,
    GetPlayerPed = GetPlayerPed,
})

Sandbox.loadInto('../server/entities.lua', env)

local ResolveNetworkEntity = env.ResolveNetworkEntity
local ResolveConnectedPlayerFromPed = env.ResolveConnectedPlayerFromPed
local ClaimNetworkEntity = env.ClaimNetworkEntity
local ReleaseNetworkEntity = env.ReleaseNetworkEntity
local IsNetworkEntityClaimedByOther = env.IsNetworkEntityClaimedByOther

t.isNotNil(ResolveNetworkEntity, 'server/entities.lua must define global ResolveNetworkEntity')
t.isNotNil(ResolveConnectedPlayerFromPed, 'server/entities.lua must define global ResolveConnectedPlayerFromPed')
t.isNotNil(ClaimNetworkEntity, 'server/entities.lua must define global ClaimNetworkEntity')
t.isNotNil(ReleaseNetworkEntity, 'server/entities.lua must define global ReleaseNetworkEntity')
t.isNotNil(IsNetworkEntityClaimedByOther, 'server/entities.lua must define global IsNetworkEntityClaimedByOther')

--- Test helper: registers netId 100 -> entity 5000, marks entity 5000 as
--- existing, with no type assigned (entityTypes[5000] defaults to 0, never
--- matching any real expectedEntityType 1/2/3).
local function resetFixtures()
    networkEntities = { [100] = 5000 }
    existingEntities = { [5000] = true }
    entityTypes = {}
    connectedPlayerIds = {}
    pedsByPlayerId = {}
end

-- ----------------------------------------------------------------------
-- ResolveNetworkEntity: type guard on netId itself
-- ----------------------------------------------------------------------

t.test('ResolveNetworkEntity: a string netId is rejected outright (never reaches the native)', function()
    resetFixtures()
    t.isNil(ResolveNetworkEntity('100'))
end)

t.test('ResolveNetworkEntity: a table netId is rejected outright', function()
    resetFixtures()
    t.isNil(ResolveNetworkEntity({ 100 }))
end)

t.test('ResolveNetworkEntity: a nil netId is rejected outright', function()
    resetFixtures()
    t.isNil(ResolveNetworkEntity(nil))
end)

t.test('ResolveNetworkEntity: a boolean netId is rejected outright', function()
    resetFixtures()
    t.isNil(ResolveNetworkEntity(true))
end)

-- ----------------------------------------------------------------------
-- ResolveNetworkEntity: existence guard (0 result, AND stale-handle DoesEntityExist)
-- ----------------------------------------------------------------------

t.test('ResolveNetworkEntity: an unrecognized netId (native returns 0) resolves to nil', function()
    resetFixtures()
    t.isNil(ResolveNetworkEntity(999999))
end)

t.test('ResolveNetworkEntity: a nonzero handle that fails DoesEntityExist is rejected (stale handle)', function()
    resetFixtures()
    existingEntities[5000] = false -- native resolved something, but it's not live at this instant
    t.isNil(ResolveNetworkEntity(100), 'a stale/nonexistent entity must never be returned, even with a nonzero native result')
end)

t.test('ResolveNetworkEntity: a live entity with no expectedEntityType resolves successfully', function()
    resetFixtures()
    t.equals(ResolveNetworkEntity(100), 5000)
end)

t.test('ResolveNetworkEntity: never returns 0 itself even if that were somehow the live handle', function()
    resetFixtures()
    networkEntities[100] = 0 -- pathological: native "resolved" to 0
    -- entity == 0 is caught by the `entity == 0 or not DoesEntityExist(entity)` guard
    -- before DoesEntityExist is even consulted for it.
    t.isNil(ResolveNetworkEntity(100))
end)

-- ----------------------------------------------------------------------
-- ResolveNetworkEntity: expectedEntityType -- enforced, hard reject on mismatch
-- ----------------------------------------------------------------------

t.test('ResolveNetworkEntity: expectedEntityType match resolves successfully', function()
    resetFixtures()
    entityTypes[5000] = 3 -- object
    t.equals(ResolveNetworkEntity(100, 3), 5000)
end)

t.test('ResolveNetworkEntity: expectedEntityType mismatch is a HARD reject (nil), not advisory', function()
    resetFixtures()
    entityTypes[5000] = 1 -- ped
    t.isNil(ResolveNetworkEntity(100, 3), 'a type mismatch must return nil, identical to a nonexistent entity -- never a soft pass-through')
end)

t.test('ResolveNetworkEntity: omitting expectedEntityType skips type filtering entirely', function()
    resetFixtures()
    entityTypes[5000] = 1 -- ped -- would mismatch type 3, but no expectedEntityType was passed
    t.equals(ResolveNetworkEntity(100), 5000, 'omitting expectedEntityType must resolve regardless of the entity\'s real type')
end)

t.test('ResolveNetworkEntity: expectedEntityType = 0 is falsy-adjacent but still a real check (GetEntityType returning the "unknown" sentinel does not match a real type)', function()
    resetFixtures()
    -- entityTypes[5000] left unset -> GetEntityType stub returns 0 (this
    -- spec's own "unknown" sentinel, not a real FiveM return value, but
    -- exercises the exact-match branch against a non-matching type).
    t.isNil(ResolveNetworkEntity(100, 2), 'an entity of unresolved/unknown type must not match a real expectedEntityType')
end)

-- ----------------------------------------------------------------------
-- ResolveNetworkEntity: numeric edge cases the doc comment explicitly calls
-- out as "rejected via the existence check, not the type check"
-- ----------------------------------------------------------------------

t.test('ResolveNetworkEntity: a non-integer float netId is not type-rejected, but fails to resolve to anything real', function()
    resetFixtures()
    -- Never registered in networkEntities under the float key -> native
    -- returns 0 -> existence guard rejects it. Confirms the doc comment's
    -- claim: type(netId) == 'number' accepts this; it dies at the existence
    -- check instead.
    t.isNil(ResolveNetworkEntity(100.5))
end)

t.test('ResolveNetworkEntity: a negative netId is not type-rejected, but fails to resolve to anything real', function()
    resetFixtures()
    t.isNil(ResolveNetworkEntity(-100))
end)

t.test('ResolveNetworkEntity: a huge out-of-range netId is not type-rejected, but fails to resolve', function()
    resetFixtures()
    t.isNil(ResolveNetworkEntity(2 ^ 40))
end)

-- ----------------------------------------------------------------------
-- ResolveConnectedPlayerFromPed
-- ----------------------------------------------------------------------

t.test('ResolveConnectedPlayerFromPed: matches a connected player\'s own ped', function()
    resetFixtures()
    connectedPlayerIds = { '1', '2', '3' }
    pedsByPlayerId = { [1] = 9001, [2] = 9002, [3] = 9003 }
    t.equals(ResolveConnectedPlayerFromPed(9002), 2)
end)

t.test('ResolveConnectedPlayerFromPed: an NPC ped (matches nobody) resolves to nil', function()
    resetFixtures()
    connectedPlayerIds = { '1', '2' }
    pedsByPlayerId = { [1] = 9001, [2] = 9002 }
    t.isNil(ResolveConnectedPlayerFromPed(7777))
end)

t.test('ResolveConnectedPlayerFromPed: no connected players resolves to nil', function()
    resetFixtures()
    connectedPlayerIds = {}
    t.isNil(ResolveConnectedPlayerFromPed(9001))
end)

t.test('ResolveConnectedPlayerFromPed: scans past a non-numeric player id entry without erroring', function()
    resetFixtures()
    -- GetPlayers() in real FiveM always yields numeric-string ids, but this
    -- locks in that a malformed entry (tonumber -> nil) is skipped rather
    -- than crashing the whole resolve.
    connectedPlayerIds = { 'not-a-number', '2' }
    pedsByPlayerId = { [2] = 9002 }
    t.equals(ResolveConnectedPlayerFromPed(9002), 2)
end)

t.test('ResolveConnectedPlayerFromPed: matches the correct player among several, not just the first scanned', function()
    resetFixtures()
    connectedPlayerIds = { '10', '20', '30' }
    pedsByPlayerId = { [10] = 111, [20] = 222, [30] = 333 }
    t.equals(ResolveConnectedPlayerFromPed(333), 30)
end)

-- ----------------------------------------------------------------------
-- CROSS-FEATURE NETID CLAIM REGISTRY: ClaimNetworkEntity /
-- ReleaseNetworkEntity / IsNetworkEntityClaimedByOther. `ClaimedNetworkEntities`
-- is one shared table for this entire loaded env (not reset between tests,
-- unlike the native-stub tables above, since nothing in entities.lua exposes
-- a reset hook for it and none is needed) -- every test below uses its own
-- distinct netId so no test can observe another's claims.
-- ----------------------------------------------------------------------

t.test('IsNetworkEntityClaimedByOther: an unclaimed netId is never claimed by anyone', function()
    t.isFalse(IsNetworkEntityClaimedByOther(70001, 'kennel', 'AAA111'))
end)

t.test('ClaimNetworkEntity then IsNetworkEntityClaimedByOther: the SAME (feature, ownerId) that claimed it is never "claimed by OTHER"', function()
    ClaimNetworkEntity(70002, 'kennel', 'AAA111')
    t.isFalse(IsNetworkEntityClaimedByOther(70002, 'kennel', 'AAA111'), 're-confirming/overwriting your OWN prior claim is never a collision with yourself')
end)

t.test('ClaimNetworkEntity then IsNetworkEntityClaimedByOther: a DIFFERENT ownerId under the SAME feature IS claimed by other', function()
    ClaimNetworkEntity(70003, 'fetch', 'AAA111')
    t.isTrue(IsNetworkEntityClaimedByOther(70003, 'fetch', 'BBB222'))
end)

t.test('ClaimNetworkEntity then IsNetworkEntityClaimedByOther: a DIFFERENT feature entirely IS claimed by other -- THE CROSS-FEATURE CASE this registry exists for', function()
    ClaimNetworkEntity(70004, 'kennel', 'AAA111')
    t.isTrue(IsNetworkEntityClaimedByOther(70004, 'fetch', 'AAA111'), 'same ownerId, different feature -- still a collision, exactly the shared-prop-model gap this registry closes')
    t.isTrue(IsNetworkEntityClaimedByOther(70004, 'propattachment', 'AAA111'))
end)

t.test('ReleaseNetworkEntity: clears a claim when the (feature, ownerId) pair matches exactly', function()
    ClaimNetworkEntity(70005, 'kennel', 'AAA111')
    ReleaseNetworkEntity(70005, 'kennel', 'AAA111')
    t.isFalse(IsNetworkEntityClaimedByOther(70005, 'fetch', 'ZZZ999'), 'unclaimed after release -- no longer collides with anyone')
end)

t.test('ReleaseNetworkEntity: does NOT clear a claim when ownerId does not match -- fails closed, never lets a stranger release someone else\'s claim', function()
    ClaimNetworkEntity(70006, 'kennel', 'AAA111')
    ReleaseNetworkEntity(70006, 'kennel', 'MALLORY')
    t.isTrue(IsNetworkEntityClaimedByOther(70006, 'fetch', 'ZZZ999'), 'the real owner\'s claim must still stand')
    t.isFalse(IsNetworkEntityClaimedByOther(70006, 'kennel', 'AAA111'), 'and the real owner still recognizes it as their own')
end)

t.test('ReleaseNetworkEntity: does NOT clear a claim when feature does not match, even with the correct ownerId', function()
    ClaimNetworkEntity(70007, 'kennel', 'AAA111')
    ReleaseNetworkEntity(70007, 'fetch', 'AAA111') -- same citizenid, wrong feature
    t.isTrue(IsNetworkEntityClaimedByOther(70007, 'fetch', 'ZZZ999'), 'kennel\'s claim survives a mismatched-feature release attempt')
end)

t.test('ReleaseNetworkEntity: a no-op on a netId that was never claimed at all -- never errors', function()
    ReleaseNetworkEntity(70008, 'kennel', 'AAA111')
    t.isFalse(IsNetworkEntityClaimedByOther(70008, 'fetch', 'ZZZ999'))
end)

t.test('ClaimNetworkEntity: overwrites a prior claim for the SAME netId (last write wins) -- models re-claiming after a netId overwrite (confirmFetchBallCarried/Dropped\'s own release-then-claim pattern)', function()
    ClaimNetworkEntity(70009, 'kennel', 'AAA111')
    ClaimNetworkEntity(70009, 'fetch', 'BBB222')
    t.isFalse(IsNetworkEntityClaimedByOther(70009, 'fetch', 'BBB222'), 'the new claim is now authoritative')
    t.isTrue(IsNetworkEntityClaimedByOther(70009, 'kennel', 'AAA111'), 'the old claimant no longer owns it')
end)

t.test('ClaimNetworkEntity/ReleaseNetworkEntity/IsNetworkEntityClaimedByOther: a non-number netId is a silent no-op / always false, never an error', function()
    ClaimNetworkEntity('not-a-number', 'kennel', 'AAA111') -- must not error, and must not affect anything
    t.isFalse(IsNetworkEntityClaimedByOther('not-a-number', 'fetch', 'ZZZ999'))
    ReleaseNetworkEntity('not-a-number', 'kennel', 'AAA111') -- must not error
end)

os.exit(t.summary())
