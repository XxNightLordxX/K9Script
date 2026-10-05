--[[
    tests/bodyclaims_spec.lua

    Direct tests of server/bodyclaims.lua's own three resource-globals
    (ClaimBody/ReleaseBody/IsBodyClaimedByOther) against the REAL,
    unmodified production file, in isolation. Same overall shape as
    tests/entities_spec.lua's own CROSS-FEATURE NETID CLAIM REGISTRY
    section (ClaimNetworkEntity/ReleaseNetworkEntity/
    IsNetworkEntityClaimedByOther) — this file is that same pattern applied
    to a citizenid instead of a netId; read that section's own header
    comment first if this one is unclear.

    THE RED-THEN-GREEN PROOF this file exists to carry, per the task that
    scoped this pass:
      1. RED, closed: a second, DIFFERENT mechanic's claim on the SAME
         citizenid while a first is still live is REFUSED — see "ClaimBody:
         a DIFFERENT mechanic cannot claim a citizenid already live-claimed
         by another" below. This is the exact shape of the confirmed
         kennel-vs-vehicle-seat race, reduced to this file's own primitives
         with no kennel/vehicle-specific machinery needed to prove it.
      2. GREEN, the control: an ordinary single claim (no prior claim held)
         still succeeds every time — see "ClaimBody: an unclaimed
         citizenid can always be claimed" below. A fix that refused
         EVERYTHING would pass proof 1 above trivially and be
         catastrophic; this is the assertion that would catch that.
      3. GREEN, the other control: releasing (the "stop" path) works
         correctly WHILE a claim is actively held, and remains a safe no-op
         when it is not — see the ReleaseBody section below, including the
         "never lets a stranger release someone else's claim" case, which
         is this file's own version of the "never gate a termination path"
         rule applied to a WRONG caller rather than a right one.
    The actual CROSS-FILE integration — proving server/kennel.lua's
    requestEnterKennel, server/vehicle.lua's requestVehicleSeatClaim, and
    server/combat.lua's ValidateCombatRequest genuinely consult this SAME
    registry instance and correctly refuse a real cross-mechanic race — is
    covered in each of those three files' own specs (kennel_spec.lua's,
    vehicle_spec.lua's, and combat_spec.lua's own EXCLUSIVE BODY-CLAIM
    REGISTRY sections), not duplicated here; this file only proves the
    three primitives' own, file-local contract in isolation — mirroring
    entities_spec.lua's own explicit split for the identical reason.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

-- ----------------------------------------------------------------------
-- Sandbox setup — a real, steppable GetGameTimer (needed for TTL/expiry),
-- and a real thread runner (needed for the periodic-sweep-exists proof).
-- Mirrors server/vehicle.lua's own tests/vehicle_spec.lua fixture shape.
-- ----------------------------------------------------------------------

local fakeNow = 0
local function GetGameTimer() return fakeNow end

local printedLines = {}
local function printStub(...)
    local parts = {}
    for i = 1, select('#', ...) do parts[i] = tostring(select(i, ...)) end
    printedLines[#printedLines + 1] = table.concat(parts, '\t')
end

local runner = Sandbox.newThreadRunner()
local threadCreateCount = 0
local function CreateThread(fn)
    threadCreateCount = threadCreateCount + 1
    runner.CreateThread(fn)
end

local env = Sandbox.newEnv({
    GetGameTimer = GetGameTimer,
    CreateThread = CreateThread,
    Wait = runner.Wait,
    print = printStub,
})

Sandbox.loadInto('../server/bodyclaims.lua', env)

local ClaimBody = env.ClaimBody
local ReleaseBody = env.ReleaseBody
local IsBodyClaimedByOther = env.IsBodyClaimedByOther
local RegisterBodyClaimReleaser = env.RegisterBodyClaimReleaser
local ForceReleaseBodyClaimForCitizenId = env.ForceReleaseBodyClaimForCitizenId

t.isNotNil(ClaimBody, 'server/bodyclaims.lua must define global ClaimBody')
t.isNotNil(ReleaseBody, 'server/bodyclaims.lua must define global ReleaseBody')
t.isNotNil(IsBodyClaimedByOther, 'server/bodyclaims.lua must define global IsBodyClaimedByOther')

-- ----------------------------------------------------------------------
-- BodyClaims itself is one shared table for this entire loaded env (not
-- reset between tests, same as entities_spec.lua's own ClaimedNetworkEntities
-- note) -- every test below uses its own distinct citizenid so no test can
-- observe another's claims.
-- ----------------------------------------------------------------------

t.test('IsBodyClaimedByOther: an unclaimed citizenid is never claimed by anyone', function()
    t.isFalse(IsBodyClaimedByOther('CIT_0001', 'kennel_rest'))
end)

t.test('ClaimBody: an unclaimed citizenid can always be claimed -- THE CONTROL: an ordinary single claim must succeed', function()
    t.isTrue(ClaimBody('CIT_0002', 'kennel_rest'))
    t.isFalse(IsBodyClaimedByOther('CIT_0002', 'kennel_rest'), 'the claimant itself never collides with its own claim')
    t.isTrue(IsBodyClaimedByOther('CIT_0002', 'vehicle_seat'), 'a DIFFERENT mechanic correctly sees this citizenid as claimed')
end)

t.test('ClaimBody: re-claiming for the SAME mechanic is a RENEWAL, not a collision, and always succeeds', function()
    t.isTrue(ClaimBody('CIT_0003', 'vehicle_seat', 1000))
    t.isTrue(ClaimBody('CIT_0003', 'vehicle_seat', 1000), 'the same mechanic re-confirming its own prior claim must never be refused')
end)

t.test('ClaimBody: a DIFFERENT mechanic cannot claim a citizenid already live-claimed by another -- THE RACE THIS FILE CLOSES', function()
    t.isTrue(ClaimBody('CIT_0004', 'kennel_rest'))
    t.isFalse(ClaimBody('CIT_0004', 'vehicle_seat', 10000), 'a second, different exclusive mechanic must be refused while the first claim is still live')
    -- and the ORIGINAL claim must still stand, untouched by the refused attempt
    t.isFalse(IsBodyClaimedByOther('CIT_0004', 'kennel_rest'), 'the original claimant is unaffected by the refused collision')
end)

t.test('IsBodyClaimedByOther: names WHICH mechanic holds the claim, for a denying caller to pick an accurate message', function()
    ClaimBody('CIT_0005', 'combat_target', 5000, 'drag')
    local claimed, otherMechanic, detail = IsBodyClaimedByOther('CIT_0005', 'vehicle_seat')
    t.isTrue(claimed)
    t.equals(otherMechanic, 'combat_target')
    t.equals(detail, 'drag')
end)

t.test('IsBodyClaimedByOther: detail is nil when the claiming call never supplied one', function()
    ClaimBody('CIT_0006', 'kennel_rest')
    local claimed, otherMechanic, detail = IsBodyClaimedByOther('CIT_0006', 'vehicle_seat')
    t.isTrue(claimed)
    t.equals(otherMechanic, 'kennel_rest')
    t.isNil(detail)
end)

-- ----------------------------------------------------------------------
-- ReleaseBody
-- ----------------------------------------------------------------------

t.test('ReleaseBody: clears a claim when the mechanic matches exactly -- releasing while a claim is held works, and frees the citizenid for a different mechanic', function()
    ClaimBody('CIT_0007', 'kennel_rest')
    ReleaseBody('CIT_0007', 'kennel_rest')
    t.isFalse(IsBodyClaimedByOther('CIT_0007', 'vehicle_seat'), 'unclaimed after release -- no longer collides with anyone')
    t.isTrue(ClaimBody('CIT_0007', 'vehicle_seat', 10000), 'a DIFFERENT mechanic can now claim the same citizenid, exactly the control this whole registry exists to preserve')
end)

t.test('ReleaseBody: does NOT clear a claim when the mechanic does not match -- fails closed, never lets a stranger release someone else\'s claim', function()
    ClaimBody('CIT_0008', 'kennel_rest')
    ReleaseBody('CIT_0008', 'vehicle_seat') -- wrong mechanic
    t.isTrue(IsBodyClaimedByOther('CIT_0008', 'vehicle_seat'), 'the real claim must still stand')
    t.isFalse(IsBodyClaimedByOther('CIT_0008', 'kennel_rest'), 'and the real claimant still recognizes it as its own')
end)

t.test('ReleaseBody: a no-op on a citizenid that was never claimed at all -- never errors', function()
    ReleaseBody('CIT_0009', 'kennel_rest')
    t.isFalse(IsBodyClaimedByOther('CIT_0009', 'vehicle_seat'))
end)

t.test('ReleaseBody: never gates on anything -- callable at any time, mirrors this resource\'s "never gate a termination path" rule', function()
    ClaimBody('CIT_0010', 'combat_target', 5000, 'bite')
    ReleaseBody('CIT_0010', 'combat_target')
    ReleaseBody('CIT_0010', 'combat_target') -- calling it again after it's already gone must still be a safe no-op
    t.isFalse(IsBodyClaimedByOther('CIT_0010', 'vehicle_seat'))
end)

-- ----------------------------------------------------------------------
-- Malformed input -- defensive, never trust a caller's own bug into a bad write
-- ----------------------------------------------------------------------

t.test('ClaimBody: a nil citizenid is a silent no-op / always false, never an error', function()
    t.isFalse(ClaimBody(nil, 'kennel_rest'))
end)

t.test('ClaimBody: an empty-string citizenid is a silent no-op / always false, never an error', function()
    t.isFalse(ClaimBody('', 'kennel_rest'))
end)

t.test('ClaimBody: a non-string citizenid (a raw server id number, the exact mistake this file\'s own header warns against) is a silent no-op', function()
    t.isFalse(ClaimBody(42, 'kennel_rest'), 'server ids are recycled -- this registry must only ever accept a durable citizenid')
end)

t.test('ReleaseBody/IsBodyClaimedByOther: a non-string citizenid never errors and never reports a claim', function()
    ReleaseBody(42, 'kennel_rest') -- must not error
    t.isFalse(IsBodyClaimedByOther(42, 'vehicle_seat'))
end)

-- ----------------------------------------------------------------------
-- EXPIRY POLICY: a supplied ttlMs bounds the claim; omitting it (nil) means
-- permanent -- see server/bodyclaims.lua's own header for the full
-- 'kennel_rest' reasoning this locks in.
-- ----------------------------------------------------------------------

t.test('ClaimBody with a ttlMs: still live just before expiry', function()
    fakeNow = 0
    ClaimBody('CIT_0011', 'combat_target', 1000, 'takedown')
    fakeNow = 999
    t.isTrue(IsBodyClaimedByOther('CIT_0011', 'vehicle_seat'), 'must still be live at 999ms of a 1000ms claim')
end)

t.test('ClaimBody with a ttlMs: lazily expires the instant it is read past its own expiresAt, freeing the citizenid for a different mechanic', function()
    fakeNow = 0
    ClaimBody('CIT_0012', 'combat_target', 1000, 'takedown')
    fakeNow = 1001
    t.isFalse(IsBodyClaimedByOther('CIT_0012', 'vehicle_seat'), 'an expired claim must never be reported as live')
    t.isTrue(ClaimBody('CIT_0012', 'vehicle_seat', 10000), 'a DIFFERENT mechanic must be able to claim it once the old one has genuinely expired -- a 300ms race must never become a permanent lockout')
end)

t.test('ClaimBody with NO ttlMs (omitted -- the kennel_rest shape): NEVER expires by time alone, no matter how far the clock advances', function()
    fakeNow = 0
    ClaimBody('CIT_0013', 'kennel_rest')
    fakeNow = 24 * 60 * 60 * 1000 -- 24 real hours later
    t.isTrue(IsBodyClaimedByOther('CIT_0013', 'vehicle_seat'), 'a permanent claim (no ttlMs) must still be live -- kennel-rest legitimately has no natural time limit')
    -- Only an explicit ReleaseBody call ends it -- exactly the same
    -- "explicit release, not a timer" discipline server/kennel.lua's own
    -- KennelOccupants registry already relies on.
    ReleaseBody('CIT_0013', 'kennel_rest')
    t.isFalse(IsBodyClaimedByOther('CIT_0013', 'vehicle_seat'))
end)

t.test('CLAMP-AND-WARN: a non-positive ttlMs is clamped to a safe fallback, never a bare crash', function()
    fakeNow = 0
    local before = #printedLines
    local ok = ClaimBody('CIT_0014', 'vehicle_seat', 0)
    t.isTrue(ok, 'a bad ttlMs must degrade the claim to a safe bound, never abort the calling handler')
    t.isTrue(#printedLines > before, 'a clamp must be logged, not silently swallowed')
    -- Still bounded (not accidentally made permanent) -- advancing well past
    -- BODY_CLAIM_FALLBACK_TTL_MS (15000, per that file's own declared
    -- constant) must eventually free it.
    fakeNow = 20000
    t.isFalse(IsBodyClaimedByOther('CIT_0014', 'kennel_rest'), 'the clamped fallback TTL must still be a REAL bound, not an accidental permanent claim')
end)

t.test('CLAMP-AND-WARN: a negative ttlMs is likewise clamped, never a bare crash', function()
    fakeNow = 0
    t.isTrue(ClaimBody('CIT_0015', 'vehicle_seat', -500))
end)

t.test('CLAMP-AND-WARN: a non-number ttlMs is likewise clamped, never a bare crash', function()
    fakeNow = 0
    t.isTrue(ClaimBody('CIT_0016', 'vehicle_seat', 'soon'))
end)

-- ----------------------------------------------------------------------
-- PERIODIC SWEEP -- "a way to expire" must not depend solely on some future
-- caller happening to touch this exact citizenid again (mirrors
-- server/vehicle.lua's own VEHICLE_SEAT_CLAIM_SWEEP_INTERVAL_MS mechanism
-- 4). The deeper behavioral guarantee (a stale claim never blocks forever)
-- is already locked in by the lazy-expiry test above -- both mechanisms
-- share the identical `expiresAt` condition, so this test only needs to
-- confirm the sweep thread itself exists and is started UNCONDITIONALLY at
-- file load, mirroring server/vehicle.lua's own "LIVE-FLIP FIX" test shape.
-- ----------------------------------------------------------------------

t.test('the periodic sweep thread is created unconditionally at file load', function()
    t.equals(threadCreateCount, 1, 'server/bodyclaims.lua has no feature flag of its own to gate this on -- it must always start')
end)

-- ========================================================================
-- FORCED RELEASE -- ForceReleaseBodyClaimForCitizenId + the
-- RegisterBodyClaimReleaser dispatcher it routes through.
--
-- THE DEFECT THIS CLOSES: server/certifications/'s
-- EndK9AccessForCitizenId tore down every session consequence of holding K9
-- access EXCEPT a kennel-rest occupancy and a vehicle-seat claim, leaving a
-- decertified player still attached to a kennel prop, or seated, with the
-- server still recording them as the occupant.
--
-- WHAT THESE TESTS ARE REALLY GUARDING. The dangerous fix here was always
-- the SHORTCUT -- clearing the body claim alone and calling it done, which
-- frees the kennel for a second citizenid while the first is visibly still
-- in it. So the load-bearing assertions below are the ones proving the two
-- halves are inseparable: a mechanic with no registered releaser has its
-- claim LEFT INTACT rather than half-released, and every releaser is
-- reached with no access check of any kind in front of it.
--
-- The cross-file half (server/kennel.lua and server/vehicle.lua really
-- registering their own releasers, clearing their own private tables, and
-- firing their own client events) lives in kennel_spec.lua and
-- vehicle_spec.lua, mirroring this file's own established split -- see the
-- header.
-- ========================================================================

t.isNotNil(RegisterBodyClaimReleaser, 'server/bodyclaims.lua must define global RegisterBodyClaimReleaser')
t.isNotNil(ForceReleaseBodyClaimForCitizenId, 'server/bodyclaims.lua must define global ForceReleaseBodyClaimForCitizenId')

t.test('ForceReleaseBodyClaimForCitizenId: junk input is refused before any lookup happens', function()
    -- WHAT THIS DOES AND DOES NOT PROVE, recorded because the first version
    -- of this comment overclaimed. Mutation testing (2026-08-31) showed that
    -- deleting this function's `type(citizenid) ~= 'string'` guard leaves the
    -- whole suite green -- INCLUDING this test. That is not a coverage hole:
    -- the mutation is semantically equivalent. Without the guard, the lookup
    -- below is keyed on nil, finds nothing, and the very next line returns
    -- false anyway. There is no observable difference to assert.
    --
    -- So this test pins the CONTRACT, not the guard: whatever the internals
    -- do, junk in must produce a plain `false` and never a throw. That is
    -- worth holding, because this is the teardown dispatcher -- callers on
    -- revocation paths rely on a boolean, and an error here would abort a
    -- release chain partway through. The guard itself stays as defence in
    -- depth for a future refactor that makes the nil path reachable.
    for _, junk in ipairs({ '' }) do
        t.isFalse(ForceReleaseBodyClaimForCitizenId(junk, 'test'),
            ('a %q citizenid must be refused outright'):format(tostring(junk)))
    end
    t.isFalse(ForceReleaseBodyClaimForCitizenId(nil, 'test'), 'a nil citizenid must be refused outright')
    t.isFalse(ForceReleaseBodyClaimForCitizenId(12345, 'test'), 'a numeric citizenid must be refused outright')
    t.isFalse(ForceReleaseBodyClaimForCitizenId({}, 'test'), 'a table citizenid must be refused outright')
end)

t.test('ForceReleaseBodyClaimForCitizenId: a citizenid holding NOTHING is a safe no-op returning false', function()
    t.isFalse(ForceReleaseBodyClaimForCitizenId('CIT_F001', 'revoked'))
end)

t.test('ForceReleaseBodyClaimForCitizenId: a malformed citizenid never errors and never releases anything', function()
    t.isFalse(ForceReleaseBodyClaimForCitizenId(nil, 'revoked'))
    t.isFalse(ForceReleaseBodyClaimForCitizenId(12345, 'revoked'))
    t.isFalse(ForceReleaseBodyClaimForCitizenId('', 'revoked'))
end)

t.test('ForceReleaseBodyClaimForCitizenId: routes to the OWNING mechanic\'s releaser, passes the reason through, and clears the claim', function()
    local seen = {}
    RegisterBodyClaimReleaser('kennel_rest', function(citizenid, reason)
        seen[#seen + 1] = { citizenid = citizenid, reason = reason }
        return true
    end)

    t.isTrue(ClaimBody('CIT_F002', 'kennel_rest'))
    t.isTrue(ForceReleaseBodyClaimForCitizenId('CIT_F002', 'cert_revoked'))

    t.equals(#seen, 1, 'the owning mechanic\'s releaser must be called exactly once')
    t.equals(seen[1].citizenid, 'CIT_F002')
    t.equals(seen[1].reason, 'cert_revoked', 'the reason must reach the mechanic so it can tell the player why')
    t.isFalse(IsBodyClaimedByOther('CIT_F002', 'vehicle_seat'),
        'the body claim must be gone afterwards -- a DIFFERENT mechanic now sees this citizenid as free')
end)

t.test('ForceReleaseBodyClaimForCitizenId: only the OWNING mechanic\'s releaser runs, never every registered one', function()
    local kennelCalls, vehicleCalls = 0, 0
    RegisterBodyClaimReleaser('kennel_rest', function() kennelCalls = kennelCalls + 1; return true end)
    RegisterBodyClaimReleaser('vehicle_seat', function() vehicleCalls = vehicleCalls + 1; return true end)

    t.isTrue(ClaimBody('CIT_F003', 'vehicle_seat', 60000))
    t.isTrue(ForceReleaseBodyClaimForCitizenId('CIT_F003', 'revoked'))

    t.equals(vehicleCalls, 1, 'the mechanic actually holding the claim is torn down')
    t.equals(kennelCalls, 0, 'a mechanic holding nothing must never be asked to tear down state it does not have')
end)

t.test('LOAD-BEARING: a mechanic with NO registered releaser has its claim LEFT INTACT, never registry-only released', function()
    -- The whole point of the dispatcher. A registry-only clear here would
    -- free the body for a second mechanic while the first is still
    -- physically holding it -- a silent double-occupancy, which is strictly
    -- worse than the gap this function closes. Leaving the claim and
    -- complaining loudly is the correct, conservative failure.
    local before = #printedLines
    t.isTrue(ClaimBody('CIT_F004', 'mechanic_that_forgot_to_register', 60000))
    t.isFalse(ForceReleaseBodyClaimForCitizenId('CIT_F004', 'revoked'))

    t.isTrue(IsBodyClaimedByOther('CIT_F004', 'kennel_rest'),
        'the claim MUST still be held -- releasing it with nobody able to tell the client is the double-occupancy hazard this design exists to refuse')
    t.isTrue(#printedLines > before, 'and it must complain loudly, because it means a claiming mechanic shipped without a teardown')
end)

t.test('LOAD-BEARING: a \'combat_target\' claim is deliberately NEVER force-released -- it is held AGAINST this citizenid by someone else', function()
    local combatCalls = 0
    RegisterBodyClaimReleaser('combat_target', function() combatCalls = combatCalls + 1; return true end)

    t.isTrue(ClaimBody('CIT_F005', 'combat_target', 60000, 'bite'))
    t.isFalse(ForceReleaseBodyClaimForCitizenId('CIT_F005', 'revoked'))

    t.equals(combatCalls, 0, 'even WITH a releaser registered, combat_target must be skipped')
    t.isTrue(IsBodyClaimedByOther('CIT_F005', 'kennel_rest'),
        'the claim stays: ending a third party\'s in-flight bite from the registry side, while their own client carries on, is the same desync pointed at someone else. These claims carry a real TTL and expire on their own.')
end)

t.test('a releaser that ERRORS is caught, logged, and the body claim is cleared anyway', function()
    -- A permanent 'kennel_rest' claim left behind after a failed teardown
    -- would block every other exclusive mechanic for that citizenid
    -- forever -- a worse outcome than the failed teardown itself.
    RegisterBodyClaimReleaser('kennel_rest', function() error('releaser blew up') end)

    local before = #printedLines
    t.isTrue(ClaimBody('CIT_F006', 'kennel_rest'))
    t.isFalse(ForceReleaseBodyClaimForCitizenId('CIT_F006', 'revoked'), 'returns false -- the teardown genuinely did not fully succeed')
    t.isTrue(#printedLines > before, 'and says so, rather than failing silently')
    t.isFalse(IsBodyClaimedByOther('CIT_F006', 'vehicle_seat'),
        'but the claim itself is gone -- a stuck permanent claim would lock this citizenid out of every exclusive mechanic')
end)

t.test('a releaser that finds nothing of its own (returns false) still clears the claim -- no orphan left behind', function()
    RegisterBodyClaimReleaser('kennel_rest', function() return false end)
    t.isTrue(ClaimBody('CIT_F007', 'kennel_rest'))
    t.isTrue(ForceReleaseBodyClaimForCitizenId('CIT_F007', 'revoked'))
    t.isFalse(IsBodyClaimedByOther('CIT_F007', 'vehicle_seat'),
        'the registry must not keep a claim whose owning mechanic has already forgotten it')
end)

t.test('an EXPIRED claim is treated as absent -- the releaser is never called for one', function()
    local calls = 0
    RegisterBodyClaimReleaser('vehicle_seat', function() calls = calls + 1; return true end)

    t.isTrue(ClaimBody('CIT_F008', 'vehicle_seat', 1000))
    fakeNow = fakeNow + 5000
    t.isFalse(ForceReleaseBodyClaimForCitizenId('CIT_F008', 'revoked'))
    t.equals(calls, 0, 'nothing is held any more, so there is nothing to tear down')
end)

t.test('RegisterBodyClaimReleaser: a malformed registration is refused and logged, never stored', function()
    local before = #printedLines
    RegisterBodyClaimReleaser('', function() return true end)
    RegisterBodyClaimReleaser('some_mechanic', 'not a function')
    RegisterBodyClaimReleaser(nil, function() return true end)
    t.isTrue(#printedLines >= before + 3, 'each malformed registration must complain')
end)

t.test('RegisterBodyClaimReleaser: re-registering the same mechanic REPLACES it -- a resource restart must not stack releasers', function()
    local first, second = 0, 0
    RegisterBodyClaimReleaser('kennel_rest', function() first = first + 1; return true end)
    RegisterBodyClaimReleaser('kennel_rest', function() second = second + 1; return true end)

    t.isTrue(ClaimBody('CIT_F009', 'kennel_rest'))
    t.isTrue(ForceReleaseBodyClaimForCitizenId('CIT_F009', 'revoked'))
    t.equals(first, 0, 'the superseded releaser must not run')
    t.equals(second, 1)
end)

os.exit(t.summary())
