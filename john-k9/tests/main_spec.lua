--[[
    tests/main_spec.lua

    First client-side spec in this suite (DEVELOPER_REFERENCE.md Part B item 3
    -- formerly DEVELOPER_REFERENCE.md, merged 2026-08-25).
    Direct tests of client/main.lua's small pure-logic cluster against the
    REAL, unmodified production file: IsEntityModelK9, IsOwnModelK9,
    HasK9Access (and its TTL debounce cache -- DEVELOPER_REFERENCE.md's own "checked... on
    every access point... not just once" requirement, balanced against a
    hot ox_target canInteract predicate not flooding the server), the
    CanShowK9UI combinator, DenyK9UIAccess, and ResolveNetworkEntity's
    client-side counterpart to server/entities.lua's function of the same
    name (already covered by entities_spec.lua -- this is a DIFFERENT
    function, same name by design, different Lua VM/signature: the client
    version here takes only `netId`, no `expectedEntityType`).

    All five are resource-globals (no `local`) per that file's own
    FILE-TO-FILE CONTRACT, so -- exactly like entities_spec.lua -- no
    RegisterCommand/callback indirection is needed to reach them.

    EXTENDED (this pass) to close out the three functions the original
    draft of this file explicitly scoped out as a SCOPE boundary, not a
    difficulty one (see that draft's own "NATIVES DELIBERATELY NOT
    STUBBED, AND WHY" comment, now removed below since it no longer
    describes this file): ResolvePlayerServerIdFromPed
    (NetworkGetPlayerIndexFromPed + GetPlayerServerId), PlaySoundOnNetworkEntity
    (PlaySoundFromEntity + the PlayK9Sound resource-global, which may not
    exist at all -- see that section's own comment), and the
    RegisterNetEvent('john-k9:client:playBark', ...) handler, including
    its `source ~= 65535` origin guard. All four of that guard's natives
    (NetworkGetPlayerIndexFromPed, GetPlayerServerId, PlaySoundFromEntity,
    RegisterNetEvent's own capturing stub) are now stubbed in
    newMainFixture() below -- every native client/main.lua's load-time and
    runtime paths touch is now covered; nothing in this file remains
    unstubbed by choice.

    LOAD ORDER: the real config.lua (for the REAL Config.Peds model list --
    the task this spec was written for explicitly asked for this, not a
    fabricated stand-in) is loaded into the sandbox FIRST, then the real
    client/main.lua on top -- matching fxmanifest.lua's own
    shared_scripts { ..., 'config.lua' } before client_scripts { 'client/main.lua', ... }
    order. config.lua itself calls no natives at load time (verified: it is
    pure Lua table literals), so it needs no extra stub beyond the ones
    client/main.lua itself requires.

    ONE FRESH SANDBOX PER TEST (never shared) -- same rule kennel_spec.lua
    documents for its own file-load-time locals. client/main.lua's
    `hasK9AccessCache` table is exactly this kind of module-load-time local
    state (declared once, at the top of the file, above HasK9Access): a
    shared sandbox would let one test's cached access decision leak into an
    unrelated test's assertions about a fresh miss. newMainFixture() below
    builds one complete, independent world for every single t.test() call.

    GetHashKey stand-in: same deterministic, non-native approach
    kennel_spec.lua already uses (a stable hash of the model NAME, not the
    real Jenkins one-at-a-time GET_HASH_KEY algorithm) -- this spec only
    needs client/main.lua's own K9ModelHashes table (built from
    Config.Peds via GetHashKey at file-load time) and this file's
    GetEntityModel stub to agree on what hash a given model name maps to,
    never the real native's exact bit pattern.

    PlaySoundOnNetworkEntity / playBark's source-origin guard -- WHAT THIS
    SPEC DOES AND DOES NOT PROVE: client/main.lua's playBark handler carries
    a `if source ~= 65535 then return end` guard (see that file's own
    "SOURCE-ORIGIN GUARD" comment and DEVELOPER_REFERENCE.md#trust-boundary).
    This spec's sandbox models `source` as an ordinary Lua global the
    handler reads via `_ENV` -- exactly like every other stubbed native
    here -- and every test below sets it explicitly before invoking the
    captured handler. That is sufficient to pin what THE CODE does: a
    65535-sourced call is processed, anything else is rejected before doing
    any work. It is NOT sufficient, and is not claimed to be sufficient, to
    settle whether FiveM's real client runtime always/reliably repopulates
    `source` this way on every dispatch, or whether it can fail open via a
    stale carry-over from a prior genuine server-sent event landing on a
    since-forged local trigger -- DEVELOPER_REFERENCE.md#trust-boundary
    §1.2 already grades that engine-level question MEDIUM-HIGH, not
    certain, and flags it as unresolved after three independent passes.
    Every test in the playBark section below repeats this in its own
    comment rather than relying on this header alone, so a reader landing
    mid-file via a failure report still sees the caveat.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')
local locale = Sandbox.locale

-- ----------------------------------------------------------------------
-- GetHashKey stand-in -- see header comment above. Identical formula to
-- kennel_spec.lua's own, kept local here rather than shared, matching this
-- suite's existing convention of each spec owning its own tiny fixtures.
-- ----------------------------------------------------------------------
local function GetHashKey(name)
    local hash = 0
    for i = 1, #name do
        hash = (hash * 31 + name:byte(i)) % 2147483647
    end
    return hash
end

-- config.lua's REAL Config.Peds list, as of this spec's authoring (see
-- config.lua:169-178) -- transcribed here ONLY for readable test names/
-- comments below; every assertion in this file drives the REAL
-- Config.Peds table loaded from the real config.lua, never a copy of it.
local REAL_K9_MODELS = { 'a_c_shepherd', 'a_c_rottweiler', 'a_c_husky', 'a_c_chop' }

-- Deliberately NOT one of the four models above (verified: config.lua has
-- no 'a_c_pug' entry) -- this spec's one "not a recognized K9 model" case.
local NON_K9_MODEL = 'a_c_pug'

local HAS_K9_ACCESS_CACHE_TTL_MS = 1000 -- must match client/main.lua's own HAS_K9_ACCESS_CACHE_TTL_MS

-- client/main.lua's own placeholder sound-bank literals (client/main.lua:202,
-- :208), transcribed here ONLY for readable assertions below -- every test
-- that uses these drives the REAL BARK_SOUND_NAME/K9_SOUND_SET-shaped calls
-- the real PlaySoundOnNetworkEntity/playBark handler makes, never a
-- reimplementation of either constant.
local BARK_SOUND_NAME = 'Bark'
local K9_SOUND_SET = 'john_k9_sounds'

-- config.lua's REAL Config.AdvancedBarkRadial table (config.lua:963-967),
-- transcribed the same way as REAL_K9_MODELS above -- one real entry, used
-- to prove playBark's barkType -> soundName lookup resolves a RECOGNIZED
-- barkType to its own distinct sound rather than always falling back to
-- BARK_SOUND_NAME. Built unconditionally by client/main.lua regardless of
-- Config.Features.AdvancedBarkRadial's value (that file's own
-- BarkTypeSoundNames comment), so this is reachable even though that
-- feature flag defaults to false.
local REAL_ADVANCED_BARK_TYPE = 'bark_alert'
local REAL_ADVANCED_BARK_SOUND = 'Bark_Alert'

-- ----------------------------------------------------------------------
-- Sandbox setup
-- ----------------------------------------------------------------------

--- Builds one fresh, independent sandbox: the real config.lua + the real
--- client/main.lua loaded into it, plus every native/global stub either
--- file's LOAD-TIME execution or this spec's exercised call paths need.
--- @return table fixture
local function newMainFixture()
    local fakeNow = 0
    local function GetGameTimer() return fakeNow end

    local pedHandle = 1
    local entityModels = {} -- entity handle -> model hash (GetEntityModel's stub backing store)
    local function GetEntityModel(entity) return entityModels[entity] end
    local function PlayerPedId() return pedHandle end

    -- ox_lib lib.callback.await stub: a FIFO queue of canned responses PLUS
    -- a call log, so a test can assert both WHAT HasK9Access() returned and
    -- exactly HOW MANY real round trips it caused -- the only way to prove
    -- the TTL cache is actually suppressing calls, not just returning a
    -- plausible value. table.remove() on an empty queue returns nil, which
    -- models a server round trip that resolved successfully to nil/nothing
    -- (e.g. the server callback itself returned nothing) -- a genuinely
    -- DIFFERENT case from a timeout/unregistered-callback failure below.
    --
    -- THROW MODELING (dependency-verification finding, this pass -- a
    -- second-hand report was VERIFIED against the real upstream source
    -- directly, not taken on faith): a prior draft of this fixture modeled
    -- every failed/timed-out round trip as `lib.callback.await` returning
    -- plain nil. That is WRONG. Read directly this pass:
    --   ox_lib imports/callback/client.lua's triggerServerCallback does
    --   `SetTimeout(callbackTimeout, function() promise:reject(("callback
    --   event '%s' timed out"):format(key)) end)` for a timeout, and its
    --   pendingCallbacks response handler does `promise:reject(response)`
    --   when response == 'cb_invalid' (callback not registered
    --   server-side) -- both go through `return table.unpack(Citizen.Await(promise))`.
    --   FiveM's own data/shared/citizen/scripting/lua/scheduler.lua
    --   Citizen.Await does `if promise.state == 2 or promise.state == 4
    --   then error(promise.value, 2) end` -- a rejected promise makes
    --   Citizen.Await THROW via Lua's error(), it never returns a value at
    --   all in that case.
    -- `queueCallbackTimeout`/`queueCallbackInvalid` below queue a distinct,
    -- identity-tagged marker (never confusable with a real nil/false/table
    -- response) that callbackAwait recognizes and turns into a real Lua
    -- error() call, so every site under test genuinely exercises its own
    -- pcall guard rather than a plain-nil stand-in.
    local ThrowMarkerMT = {}
    local function callbackThrow(message)
        return setmetatable({ message = message }, ThrowMarkerMT)
    end

    local callbackResponses = {}
    local callbackCallLog = {}
    local function callbackAwait(eventName, timeout, ...)
        callbackCallLog[#callbackCallLog + 1] = { event = eventName, timeout = timeout, args = { ... } }
        local response = table.remove(callbackResponses, 1)
        if type(response) == 'table' and getmetatable(response) == ThrowMarkerMT then
            error(response.message, 2)
        end
        return response
    end

    local notifyCalls = {}
    local lib = {
        callback = { await = callbackAwait },
        notify = function(payload) notifyCalls[#notifyCalls + 1] = payload end,
    }

    local networkEntities = {} -- netId -> entity handle, present only once "registered" (models NetworkDoesEntityExistWithNetworkId's real true/false contract, not just a 0-vs-nonzero return)
    -- netId -> how many more checks must happen before it "streams in".
    -- Models the real race ResolveNetworkEntity's retry parameter exists for:
    -- a net event arriving a fraction before the entity finishes streaming.
    local streamsInAfter = {}
    local existenceChecks = 0
    local function NetworkDoesEntityExistWithNetworkId(netId)
        existenceChecks = existenceChecks + 1
        local pending = streamsInAfter[netId]
        if pending then
            if pending > 1 then
                streamsInAfter[netId] = pending - 1
                return false
            end
            streamsInAfter[netId] = nil -- streamed in on this check
        end
        return networkEntities[netId] ~= nil
    end

    -- ResolveNetworkEntity waits BETWEEN attempts. Nothing else in this file
    -- yields, so a bare counter is enough to prove both that it waits when
    -- retrying and that it never waits after its final attempt.
    local waitCalls = {}
    local function Wait(ms) waitCalls[#waitCalls + 1] = ms end
    local function NetworkGetEntityFromNetworkId(netId) return networkEntities[netId] or 0 end
    local existingEntities = {} -- entity handle -> true
    local function DoesEntityExist(entity) return existingEntities[entity] == true end

    -- ResolvePlayerServerIdFromPed's two natives. playerIndexByPed defaults
    -- to -1 (the real native's own "not a player ped" sentinel) for any
    -- entity never explicitly registered -- `playerIndexByPed[entity] or -1`
    -- is safe even when a test registers index 0 for an entity, since 0 is
    -- truthy in Lua (only nil/false are falsy), so it is never mistaken for
    -- "unset". serverIdByPlayerIndex intentionally has NO such default: an
    -- unregistered index reads back as bare nil, modeling GetPlayerServerId
    -- returning nothing for an index this fixture was never told about.
    local playerIndexByPed = {} -- entity -> playerIndex
    local function NetworkGetPlayerIndexFromPed(entity) return playerIndexByPed[entity] or -1 end
    local serverIdByPlayerIndex = {} -- playerIndex -> serverId (or explicitly 0/nil, set per test)
    local getPlayerServerIdCallLog = {} -- proves ResolvePlayerServerIdFromPed short-circuits on index == -1 without even calling this
    local function GetPlayerServerId(playerIndex)
        getPlayerServerIdCallLog[#getPlayerServerIdCallLog + 1] = playerIndex
        return serverIdByPlayerIndex[playerIndex]
    end

    -- PlaySoundOnNetworkEntity's native half -- a call log, not a real
    -- audio-playing stub, so a test can assert exactly what args reached it
    -- (or that it was never called at all, e.g. behind playBark's origin
    -- guard or a stale/unresolvable netId).
    local playSoundFromEntityCalls = {}
    local function PlaySoundFromEntity(networkId, soundName, entity, soundSet, isNetworkSynced, flags)
        playSoundFromEntityCalls[#playSoundFromEntityCalls + 1] = {
            networkId = networkId, soundName = soundName, entity = entity,
            soundSet = soundSet, isNetworkSynced = isNetworkSynced, flags = flags,
        }
    end

    -- RegisterNetEvent is called once at client/main.lua's own load time
    -- (the playBark handler). Capturing stub, keyed by event name, so this
    -- fixture's triggerPlayBark() below can invoke the REAL captured
    -- handler body -- not a reimplementation of it -- exactly the same
    -- capturing-stub convention kennel_spec.lua/certifications_spec.lua
    -- already use for their own RegisterNetEvent/RegisterCommand handlers.
    local netEventHandlers = {}
    local function RegisterNetEvent(eventName, handler) netEventHandlers[eventName] = handler end

    local env = Sandbox.newEnv({
        GetHashKey = GetHashKey,
        GetEntityModel = GetEntityModel,
        PlayerPedId = PlayerPedId,
        GetGameTimer = GetGameTimer,
        lib = lib,
        NetworkDoesEntityExistWithNetworkId = NetworkDoesEntityExistWithNetworkId,
        Wait = Wait,
        NetworkGetEntityFromNetworkId = NetworkGetEntityFromNetworkId,
        DoesEntityExist = DoesEntityExist,
        NetworkGetPlayerIndexFromPed = NetworkGetPlayerIndexFromPed,
        GetPlayerServerId = GetPlayerServerId,
        PlaySoundFromEntity = PlaySoundFromEntity,
        RegisterNetEvent = RegisterNetEvent,
    })

    -- Real config.lua FIRST (shared_scripts order), real client/main.lua on
    -- top (client_scripts order) -- see this file's own header.
    Sandbox.loadInto('../config.lua', env)
    Sandbox.loadInto('../client/main.lua', env)

    return {
        env = env,
        advance = function(deltaMs) fakeNow = fakeNow + deltaMs end,
        setPed = function(handle) pedHandle = handle end,
        setModel = function(entity, hash) entityModels[entity] = hash end,
        queueCallbackResponse = function(value) callbackResponses[#callbackResponses + 1] = value end,
        -- Queues a THROWING round trip -- see callbackAwait's own comment
        -- above for the verified real-source citation. `eventName` is only
        -- used to build a readable message, same shape as ox_lib's real
        -- rejection strings; the exact text is not asserted on by any test
        -- below, only that HasK9Access() fails closed and does not let the
        -- error escape uncaught.
        queueCallbackTimeout = function(eventName)
            callbackResponses[#callbackResponses + 1] = callbackThrow(("callback event '%s' timed out"):format(eventName))
        end,
        queueCallbackInvalid = function(eventName)
            callbackResponses[#callbackResponses + 1] = callbackThrow(("callback '%s' does not exist"):format(eventName))
        end,
        callbackCallCount = function() return #callbackCallLog end,
        lastCallbackCall = function() return callbackCallLog[#callbackCallLog] end,
        notifyCalls = notifyCalls,
        registerEntity = function(netId, handle, exists)
            networkEntities[netId] = handle
            existingEntities[handle] = exists ~= false
        end,
        --- Registers an entity that only reports as streamed-in from the
        --- Nth existence check onward, so a retry can be observed working.
        registerEntityAfterChecks = function(netId, handle, checks)
            networkEntities[netId] = handle
            existingEntities[handle] = true
            streamsInAfter[netId] = checks
        end,
        waitCallCount = function() return #waitCalls end,
        existenceCheckCount = function() return existenceChecks end,
        setPlayerIndexForPed = function(entity, playerIndex) playerIndexByPed[entity] = playerIndex end,
        setServerIdForPlayerIndex = function(playerIndex, serverId) serverIdByPlayerIndex[playerIndex] = serverId end,
        getPlayerServerIdCallCount = function() return #getPlayerServerIdCallLog end,
        playSoundFromEntityCalls = playSoundFromEntityCalls,
        -- Invokes the REAL captured 'john-k9:client:playBark' handler
        -- body with `source` set to `sourceValue` immediately beforehand --
        -- modeling the handler reading the ambient `source` global via
        -- _ENV, same convention certifications_spec.lua's own setSource
        -- uses for its server-side net events. Errors loudly (rather than
        -- silently no-op'ing) if client/main.lua ever stops registering
        -- this exact event name, so a rename there fails this spec instead
        -- of quietly testing nothing.
        triggerPlayBark = function(sourceValue, netId, barkType)
            local handler = assert(netEventHandlers['john-k9:client:playBark'],
                'client/main.lua did not register a john-k9:client:playBark handler')
            env.source = sourceValue
            handler(netId, barkType)
        end,
    }
end

-- ----------------------------------------------------------------------
-- Sanity: the whole file loaded and exposed exactly what its own
-- FILE-TO-FILE CONTRACT documents, before trusting any test below.
-- ----------------------------------------------------------------------

t.test('client/main.lua exposes all five documented resource-globals', function()
    local f = newMainFixture()
    t.isNotNil(f.env.IsEntityModelK9)
    t.isNotNil(f.env.IsOwnModelK9)
    t.isNotNil(f.env.HasK9Access)
    t.isNotNil(f.env.CanShowK9UI)
    t.isNotNil(f.env.DenyK9UIAccess)
    t.isNotNil(f.env.ResolveNetworkEntity, 'the client-side ResolveNetworkEntity, distinct from server/entities.lua\'s function of the same name')
end)

-- ----------------------------------------------------------------------
-- IsEntityModelK9 -- against the REAL Config.Peds list from the real
-- config.lua, not a fabricated stand-in list.
-- ----------------------------------------------------------------------

for _, modelName in ipairs(REAL_K9_MODELS) do
    t.test(('IsEntityModelK9: recognizes the real config.lua Config.Peds entry %q'):format(modelName), function()
        local f = newMainFixture()
        local entity = 500
        f.setModel(entity, GetHashKey(modelName))
        t.isTrue(f.env.IsEntityModelK9(entity))
    end)
end

t.test('IsEntityModelK9: a model not present in Config.Peds returns false', function()
    local f = newMainFixture()
    local entity = 500
    f.setModel(entity, GetHashKey(NON_K9_MODEL))
    t.isFalse(f.env.IsEntityModelK9(entity))
end)

t.test('IsEntityModelK9: an entity with no resolvable model (GetEntityModel returns nil) is false, not an error', function()
    local f = newMainFixture()
    -- Never registered in entityModels -- GetEntityModel(entity) returns
    -- nil. K9ModelHashes[nil] is a safe table READ (only a nil-keyed WRITE
    -- errors in Lua), so this must resolve to false cleanly, never throw.
    t.isFalse(f.env.IsEntityModelK9(0))
end)

t.test('IsEntityModelK9: an entity whose model hash is the literal sentinel 0 is false (never coincides with a real Config.Peds hash)', function()
    local f = newMainFixture()
    local entity = 0
    f.setModel(entity, 0)
    t.isFalse(f.env.IsEntityModelK9(entity))
end)

-- ----------------------------------------------------------------------
-- IsOwnModelK9 -- IsEntityModelK9(PlayerPedId())
-- ----------------------------------------------------------------------

t.test('IsOwnModelK9: true when the local player\'s own ped model is a recognized K9 model', function()
    local f = newMainFixture()
    f.setPed(9001)
    f.setModel(9001, GetHashKey('a_c_husky'))
    t.isTrue(f.env.IsOwnModelK9())
end)

t.test('IsOwnModelK9: false when the local player\'s own ped is a human/other model', function()
    local f = newMainFixture()
    f.setPed(9001)
    f.setModel(9001, GetHashKey(NON_K9_MODEL))
    t.isFalse(f.env.IsOwnModelK9())
end)

-- ----------------------------------------------------------------------
-- HasK9Access -- THE TTL DEBOUNCE CACHE. This is the section the task this
-- spec was written for called out as "what matters most": a cache that
-- fails OPEN here would show K9 UI to an uncertified player.
-- ----------------------------------------------------------------------

t.test('HasK9Access: a cold cache is a MISS -- awaits the real server callback', function()
    local f = newMainFixture()
    f.queueCallbackResponse(true)
    t.isTrue(f.env.HasK9Access())
    t.equals(f.callbackCallCount(), 1)
    t.equals(f.lastCallbackCall().event, 'john-k9:server:hasK9Access')
end)

t.test('HasK9Access: a second call at the SAME instant is a cache HIT -- no second round trip', function()
    local f = newMainFixture()
    f.queueCallbackResponse(true)
    t.isTrue(f.env.HasK9Access())
    t.equals(f.callbackCallCount(), 1)

    -- Queue a DIFFERENT response the cache must never consult if it's
    -- really serving from cache rather than re-awaiting.
    f.queueCallbackResponse(false)
    t.isTrue(f.env.HasK9Access(), 'still the cached true, not the freshly-queued false')
    t.equals(f.callbackCallCount(), 1, 'no new round trip was made -- the cache, not a second live check, answered this call')
end)

t.test('HasK9Access: just under the TTL boundary is still a cache HIT', function()
    local f = newMainFixture()
    f.queueCallbackResponse(true)
    t.isTrue(f.env.HasK9Access())
    f.advance(HAS_K9_ACCESS_CACHE_TTL_MS - 1)
    f.queueCallbackResponse(false)
    t.isTrue(f.env.HasK9Access(), 'still cached -- one millisecond short of the TTL')
    t.equals(f.callbackCallCount(), 1)
end)

t.test('HasK9Access: at exactly the TTL boundary the cache has EXPIRED -- a fresh round trip is made', function()
    local f = newMainFixture()
    f.queueCallbackResponse(true)
    t.isTrue(f.env.HasK9Access())
    -- client/main.lua's own check is `(now - checkedAt) < TTL` -- strictly
    -- less-than, so `now - checkedAt == TTL` must already be a miss, not
    -- one more instant of grace.
    f.advance(HAS_K9_ACCESS_CACHE_TTL_MS)
    f.queueCallbackResponse(false)
    t.isFalse(f.env.HasK9Access(), 'the newly-queued response, proving a real re-check happened')
    t.equals(f.callbackCallCount(), 2)
end)

t.test('HasK9Access: comfortably past the TTL is a MISS -- re-awaits and reflects a revoked access', function()
    local f = newMainFixture()
    f.queueCallbackResponse(true)
    t.isTrue(f.env.HasK9Access())
    f.advance(HAS_K9_ACCESS_CACHE_TTL_MS + 500)
    f.queueCallbackResponse(false) -- certification revoked in between
    t.isFalse(f.env.HasK9Access())
    t.equals(f.callbackCallCount(), 2)
end)

t.test('HasK9Access: the server explicitly denying access (false) is returned and cached as false, not re-queried within the TTL', function()
    local f = newMainFixture()
    f.queueCallbackResponse(false)
    t.isFalse(f.env.HasK9Access())
    f.queueCallbackResponse(true) -- must not be consulted -- still within the TTL
    t.isFalse(f.env.HasK9Access())
    t.equals(f.callbackCallCount(), 1)
end)

-- THE load-bearing case this spec was specifically asked to prove --
-- REVISED this pass after a dependency-verification agent's claim was
-- independently verified against the REAL upstream source (both ox_lib's
-- imports/callback/client.lua and FiveM's own scheduler.lua, fetched and
-- read directly, not taken on a second-hand report): `lib.callback.await`
-- does NOT return nil on a timeout or an unregistered-callback ('cb_invalid')
-- response -- it THROWS, via ox_lib's promise:reject(...) feeding FiveM's
-- own Citizen.Await, which calls error(promise.value, 2) on a rejected
-- promise. The previous version of this section modeled the failure case
-- as a plain nil return and asserted the failure got cached for the full
-- TTL -- BOTH of those were wrong and have been replaced below. See
-- callbackAwait's own comment in newMainFixture() above for the full
-- citation, and client/main.lua's HasK9Access() for the real pcall guard
-- these tests now exercise.
t.test('HasK9Access: a callback TIMEOUT (lib.callback.await throws) FAILS CLOSED -- returns false, never true, never lets the error escape', function()
    local f = newMainFixture()
    f.queueCallbackTimeout('john-k9:server:hasK9Access')
    local result = f.env.HasK9Access()
    t.isFalse(result, 'HasK9Access must fail closed on a thrown timeout -- a cache that fails OPEN here would show K9 UI to an uncertified player, and an uncaught throw would abort the calling thread with no decision at all')
    t.equals(f.callbackCallCount(), 1, 'the round trip really was attempted, not skipped')
end)

t.test('HasK9Access: an UNREGISTERED callback (lib.callback.await throws cb_invalid) FAILS CLOSED -- returns false, never true', function()
    local f = newMainFixture()
    f.queueCallbackInvalid('john-k9:server:hasK9Access')
    local result = f.env.HasK9Access()
    t.isFalse(result, 'a cb_invalid throw (e.g. the server-side resource has not registered this callback yet) must fail closed the same as a timeout')
    t.equals(f.callbackCallCount(), 1)
end)

t.test('HasK9Access: a thrown failure is NOT cached -- the very next call, even within the TTL, re-attempts rather than sticking on a poisoned false', function()
    local f = newMainFixture()
    f.queueCallbackTimeout('john-k9:server:hasK9Access')
    t.isFalse(f.env.HasK9Access(), 'first call: thrown timeout, fails closed for THIS call')
    t.equals(f.callbackCallCount(), 1)

    -- Deliberately NO f.advance() -- still the exact same instant, well
    -- inside HAS_K9_ACCESS_CACHE_TTL_MS. A genuinely-true response is
    -- queued now. If the earlier failure HAD been written into
    -- hasK9AccessCache (poisoning it with a false negative that sticks for
    -- the full TTL, the exact regression this test guards against), this
    -- second call would silently return the stale cached false and never
    -- even attempt a second round trip. The correct behavior is the
    -- opposite of a real success being cached: a FAILURE must not stick,
    -- so this call re-attempts immediately and reflects the fresh true.
    f.queueCallbackResponse(true)
    t.isTrue(f.env.HasK9Access(), 'a failed lookup must not poison the cache with a false negative for the whole TTL -- the very next call must re-check')
    t.equals(f.callbackCallCount(), 2, 'a genuine second round trip happened -- the earlier failure was not served from a poisoned cache entry')
end)

t.test('HasK9Access: AFTER a thrown failure is followed by a real success, THAT success IS cached normally for the rest of the TTL', function()
    local f = newMainFixture()
    f.queueCallbackTimeout('john-k9:server:hasK9Access')
    t.isFalse(f.env.HasK9Access())
    f.queueCallbackResponse(true)
    t.isTrue(f.env.HasK9Access())
    t.equals(f.callbackCallCount(), 2)

    -- Now a real cache exists (checkedAt was stamped by the SUCCESSFUL
    -- second call above). A third call at the same instant must be a
    -- normal cache HIT -- proving the fix only skips caching ON FAILURE,
    -- it does not disable the TTL cache altogether.
    f.queueCallbackResponse(false) -- must not be consulted -- still within the TTL from the successful call
    t.isTrue(f.env.HasK9Access(), 'still the cached true from the successful round trip, not a third live call')
    t.equals(f.callbackCallCount(), 2, 'no third round trip -- the TTL cache still works normally once a real (non-thrown) result lands')
end)

-- ----------------------------------------------------------------------
-- CanShowK9UI -- IsOwnModelK9() and HasK9Access()
-- ----------------------------------------------------------------------

t.test('CanShowK9UI: true only when both the own-model check and the server access check pass', function()
    local f = newMainFixture()
    f.setPed(9001)
    f.setModel(9001, GetHashKey('a_c_chop'))
    f.queueCallbackResponse(true)
    t.isTrue(f.env.CanShowK9UI())
end)

t.test('CanShowK9UI: false when the own model is not a K9 model, even if the server would grant access -- and the server is never even asked (short-circuit)', function()
    local f = newMainFixture()
    f.setPed(9001)
    f.setModel(9001, GetHashKey(NON_K9_MODEL))
    f.queueCallbackResponse(true) -- would grant access, but must never be consulted
    t.isFalse(f.env.CanShowK9UI())
    t.equals(f.callbackCallCount(), 0, 'Lua\'s `and` short-circuits: IsOwnModelK9() being false means HasK9Access() -- a real network round trip -- must never even run')
end)

t.test('CanShowK9UI: false when the own model IS a K9 model but the server denies access', function()
    local f = newMainFixture()
    f.setPed(9001)
    f.setModel(9001, GetHashKey('a_c_shepherd'))
    f.queueCallbackResponse(false)
    t.isFalse(f.env.CanShowK9UI())
end)

-- ----------------------------------------------------------------------
-- DenyK9UIAccess -- the shared denial notification. Exercising this also
-- doubles as a check that both locale keys it references genuinely exist
-- in locales/en.json, per this suite's own convention (Sandbox.locale
-- RAISES on a missing key, and is never stubbed away).
-- ----------------------------------------------------------------------

t.test('DenyK9UIAccess: called with no reason notifies with common.notify_title / the improved common.no_k9_access_unknown generic fallback, as an error', function()
    local f = newMainFixture()
    f.env.DenyK9UIAccess()
    t.equals(#f.notifyCalls, 1)
    t.equals(f.notifyCalls[1].title, locale('common.notify_title'))
    t.equals(f.notifyCalls[1].description, locale('common.no_k9_access_unknown'))
    t.equals(f.notifyCalls[1].type, 'error')
end)

-- REASON PARAMETER (ease-of-use audit finding) -- a caller that already
-- tested a specific gate before calling DenyK9UIAccess() can now pass the
-- locale key naming that exact reason instead of getting the same generic
-- sentence as everyone else.
t.test('DenyK9UIAccess: called with a specific reason locale key uses that key, not the generic fallback', function()
    local f = newMainFixture()
    f.env.DenyK9UIAccess('combat.no_access')
    t.equals(#f.notifyCalls, 1)
    t.equals(f.notifyCalls[1].title, locale('common.notify_title'))
    t.equals(f.notifyCalls[1].description, locale('combat.no_access'))
    t.isFalse(f.notifyCalls[1].description == locale('common.no_k9_access_unknown'))
    t.equals(f.notifyCalls[1].type, 'error')
end)

t.test('DenyK9UIAccess: the broader CanShowK9UI()-style reason key is distinct from both the no-access and the unknown fallback strings', function()
    local f = newMainFixture()
    f.env.DenyK9UIAccess('common.no_k9_role_or_access')
    t.equals(f.notifyCalls[1].description, locale('common.no_k9_role_or_access'))
    t.isFalse(locale('common.no_k9_role_or_access') == locale('combat.no_access'))
    t.isFalse(locale('common.no_k9_role_or_access') == locale('common.no_k9_access_unknown'))
end)

t.test('DenyK9UIAccess: a non-string/empty-string reason value still falls back to the generic message, never errors', function()
    local f = newMainFixture()
    f.env.DenyK9UIAccess('')
    t.equals(f.notifyCalls[1].description, locale('common.no_k9_access_unknown'))

    f = newMainFixture()
    f.env.DenyK9UIAccess(123)
    t.equals(f.notifyCalls[1].description, locale('common.no_k9_access_unknown'))
end)

-- ----------------------------------------------------------------------
-- ResolveNetworkEntity -- client/main.lua's OWN function of this name (see
-- header comment: distinct from, and simpler than, server/entities.lua's
-- function of the same name already covered by entities_spec.lua -- no
-- expectedEntityType parameter here at all).
-- ----------------------------------------------------------------------

t.test('ResolveNetworkEntity: a netId this client has never seen streamed in resolves to nil', function()
    local f = newMainFixture()
    t.isNil(f.env.ResolveNetworkEntity(999999))
end)

t.test('ResolveNetworkEntity: a netId that exists on the network but whose local entity no longer exists (stale) resolves to nil', function()
    local f = newMainFixture()
    f.registerEntity(100, 5000, false) -- NetworkDoesEntityExistWithNetworkId(100) is true, but DoesEntityExist(5000) is false
    t.isNil(f.env.ResolveNetworkEntity(100), 'a stale/despawned entity must never be returned, even once the netId itself is recognized')
end)

t.test('ResolveNetworkEntity: a live, currently-streamed-in entity resolves successfully to its real handle', function()
    local f = newMainFixture()
    f.registerEntity(100, 5000, true)
    t.equals(f.env.ResolveNetworkEntity(100), 5000)
end)

-- ----------------------------------------------------------------------
-- ResolvePlayerServerIdFromPed -- NetworkGetPlayerIndexFromPed + GetPlayerServerId.
-- Priority per this pass's task: the DEGENERATE inputs (a ped that maps to
-- no player at all, and the zero sentinel) matter most -- both are exercised
-- below, alongside the happy path for contrast and the "round trip came
-- back with nothing" case the same `if not targetServerId or ... == 0`
-- guard also covers.
-- ----------------------------------------------------------------------

t.test('ResolvePlayerServerIdFromPed: a ped that maps to no player (NetworkGetPlayerIndexFromPed == -1) resolves to nil, and GetPlayerServerId is never even called', function()
    local f = newMainFixture()
    local entity = 700
    -- Never registered via setPlayerIndexForPed -- NetworkGetPlayerIndexFromPed
    -- stub returns its default -1, the real native's own "not a player ped" sentinel.
    t.isNil(f.env.ResolvePlayerServerIdFromPed(entity))
    t.equals(f.getPlayerServerIdCallCount(), 0, 'the -1 guard must short-circuit BEFORE calling GetPlayerServerId at all')
end)

t.test('ResolvePlayerServerIdFromPed: the zero sentinel (GetPlayerServerId returns 0) resolves to nil, never the literal 0', function()
    local f = newMainFixture()
    local entity = 701
    f.setPlayerIndexForPed(entity, 3)
    f.setServerIdForPlayerIndex(3, 0)
    t.isNil(f.env.ResolvePlayerServerIdFromPed(entity), 'server id 0 is never a real player -- must be treated the same as "no player", not returned as-is')
end)

t.test('ResolvePlayerServerIdFromPed: GetPlayerServerId returning nothing at all (nil) also resolves to nil, not an error', function()
    local f = newMainFixture()
    local entity = 702
    f.setPlayerIndexForPed(entity, 4)
    -- setServerIdForPlayerIndex deliberately not called for index 4 -- GetPlayerServerId(4) reads back bare nil.
    t.isNil(f.env.ResolvePlayerServerIdFromPed(entity))
end)

t.test('ResolvePlayerServerIdFromPed: a real player ped resolves to that player\'s real, nonzero server id', function()
    local f = newMainFixture()
    local entity = 703
    f.setPlayerIndexForPed(entity, 0) -- playerIndex 0 is itself a valid index, not a sentinel -- must not be confused with "unset"
    f.setServerIdForPlayerIndex(0, 42)
    t.equals(f.env.ResolvePlayerServerIdFromPed(entity), 42)
end)

-- ----------------------------------------------------------------------
-- PlaySoundOnNetworkEntity -- ResolveNetworkEntity + PlaySoundFromEntity,
-- THEN (this pass's priority #2) the PlayK9Sound resource-global, which
-- genuinely may not exist as a global at all when
-- Config.Features.BasicBarkSounds is false (client/audio.lua returns
-- without ever defining it) -- client/main.lua's own contract for that case
-- is a runtime `type(PlayK9Sound) == 'function'` guard, not a load-order
-- assumption, and the whole point of the cases below is proving the absent
-- path degrades cleanly rather than erroring.
-- ----------------------------------------------------------------------

t.test('PlaySoundOnNetworkEntity: a netId that does not resolve to a live entity is a clean no-op -- no PlaySoundFromEntity call at all', function()
    local f = newMainFixture()
    f.env.PlaySoundOnNetworkEntity(999999, BARK_SOUND_NAME)
    t.equals(#f.playSoundFromEntityCalls, 0)
end)

t.test('PlaySoundOnNetworkEntity: a stale (despawned) network entity is also a clean no-op', function()
    local f = newMainFixture()
    f.registerEntity(100, 5000, false) -- recognized netId, but the local entity handle no longer exists
    f.env.PlaySoundOnNetworkEntity(100, BARK_SOUND_NAME)
    t.equals(#f.playSoundFromEntityCalls, 0)
end)

-- THE priority-#2 case: PlayK9Sound genuinely absent as a global (this
-- fixture's sandbox never defines it, modeling Config.Features.BasicBarkSounds
-- == false -- client/audio.lua's own contract for that case, per
-- client/main.lua's own comment on this exact guard).
t.test('PlaySoundOnNetworkEntity: PlayK9Sound entirely absent as a global degrades cleanly -- PlaySoundFromEntity still fires, no error is thrown', function()
    local f = newMainFixture()
    f.registerEntity(100, 5000, true)
    t.isNil(f.env.PlayK9Sound, 'sanity: this sandbox genuinely does not define PlayK9Sound, same as a real client with BasicBarkSounds == false')

    -- pcall, not a bare call: if `type(PlayK9Sound) == 'function'` were ever
    -- missing/wrong in client/main.lua, calling a nil global would throw --
    -- this proves it does not, rather than merely asserting the visible
    -- side effect and hoping nothing errored along the way.
    local ok, err = pcall(f.env.PlaySoundOnNetworkEntity, 100, BARK_SOUND_NAME)
    t.isTrue(ok, 'PlaySoundOnNetworkEntity must not error when PlayK9Sound does not exist: ' .. tostring(err))

    t.equals(#f.playSoundFromEntityCalls, 1)
    t.equals(f.playSoundFromEntityCalls[1].networkId, -1)
    t.equals(f.playSoundFromEntityCalls[1].soundName, BARK_SOUND_NAME)
    t.equals(f.playSoundFromEntityCalls[1].entity, 5000)
    t.equals(f.playSoundFromEntityCalls[1].soundSet, K9_SOUND_SET)
    t.equals(f.playSoundFromEntityCalls[1].isNetworkSynced, false)
    t.equals(f.playSoundFromEntityCalls[1].flags, 0)
end)

t.test('PlaySoundOnNetworkEntity: when PlayK9Sound DOES exist as a function, it is also called, alongside (not instead of) PlaySoundFromEntity', function()
    local f = newMainFixture()
    f.registerEntity(100, 5000, true)
    local playK9SoundCalls = {}
    f.env.PlayK9Sound = function(netId, soundName)
        playK9SoundCalls[#playK9SoundCalls + 1] = { netId = netId, soundName = soundName }
    end

    f.env.PlaySoundOnNetworkEntity(100, BARK_SOUND_NAME)

    t.equals(#f.playSoundFromEntityCalls, 1, 'the native call must still fire even when PlayK9Sound also exists')
    t.equals(#playK9SoundCalls, 1)
    t.equals(playK9SoundCalls[1].netId, 100)
    t.equals(playK9SoundCalls[1].soundName, BARK_SOUND_NAME)
end)

-- ----------------------------------------------------------------------
-- RegisterNetEvent('john-k9:client:playBark', ...) handler --
-- this pass's #1 priority: the `source ~= 65535` origin guard.
--
-- IMPORTANT SCOPE NOTE, repeated from this file's header (deliberately not
-- left to be found only there): every test in this section pins what
-- CLIENT/MAIN.LUA'S CODE does when `source` holds a given value at call
-- time. None of them settle, and none should be read as settling, FiveM's
-- own real-engine question of whether `source` is reliably repopulated
-- on every dispatch or can fail open via a stale carry-over from an
-- earlier genuine server event -- DEVELOPER_REFERENCE.md#trust-boundary
-- §1.2 already grades that MEDIUM-HIGH/unresolved after three prior
-- passes, and nothing in a Lua-level sandbox test can raise or lower that
-- grade. This section is worth having regardless: it proves the guard as
-- WRITTEN does reject a non-65535 `source`, which is a necessary (not
-- sufficient) condition for the mitigation to work at all.
-- ----------------------------------------------------------------------

t.test('client/main.lua registers exactly the john-k9:client:playBark event name (sanity for every test below)', function()
    local f = newMainFixture()
    -- triggerPlayBark() itself asserts the handler was captured -- this
    -- test just exercises that assertion path directly, with a harmless
    -- unresolvable netId, so a rename shows up here first with a clear name.
    f.triggerPlayBark(65535, 999999, 'bark')
end)

t.test('playBark: source == 65535 (the documented genuine-server sentinel) is processed -- an unrecognized barkType falls back to the generic BARK_SOUND_NAME', function()
    local f = newMainFixture()
    f.registerEntity(200, 6000, true)
    f.triggerPlayBark(65535, 200, 'bark') -- Phase 1's literal, per client/main.lua's own comment -- not in BarkTypeSoundNames
    t.equals(#f.playSoundFromEntityCalls, 1, 'a genuinely server-sourced call must be processed, not rejected')
    t.equals(f.playSoundFromEntityCalls[1].soundName, BARK_SOUND_NAME)
    t.equals(f.playSoundFromEntityCalls[1].entity, 6000)
    t.equals(f.playSoundFromEntityCalls[1].soundSet, K9_SOUND_SET)
end)

t.test('playBark: source == 65535 with a barkType recognized in Config.AdvancedBarkRadial resolves to ITS OWN distinct sound, not the generic fallback', function()
    local f = newMainFixture()
    f.registerEntity(201, 6001, true)
    f.triggerPlayBark(65535, 201, REAL_ADVANCED_BARK_TYPE)
    t.equals(#f.playSoundFromEntityCalls, 1)
    t.equals(f.playSoundFromEntityCalls[1].soundName, REAL_ADVANCED_BARK_SOUND,
        'a recognized barkType must map through BarkTypeSoundNames, built from the real config.lua Config.AdvancedBarkRadial regardless of the AdvancedBarkRadial feature flag')
end)

t.test('playBark: a forged local trigger with an arbitrary non-65535 numeric source is rejected -- no sound is played at all', function()
    local f = newMainFixture()
    f.registerEntity(202, 6002, true) -- deliberately resolvable, so a bypassed guard WOULD produce a visible call
    f.triggerPlayBark(1, 202, 'bark') -- forged source: some other player's server id, not the server sentinel
    t.equals(#f.playSoundFromEntityCalls, 0, 'source ~= 65535 must reject before PlaySoundOnNetworkEntity ever runs -- pins the CODE\'s behavior only, see this section\'s header note on the open engine-level question')
end)

t.test('playBark: source left unset (nil) -- modeling a bare local TriggerEvent() call, which carries no origin parameter at all -- is also rejected', function()
    local f = newMainFixture()
    f.registerEntity(203, 6003, true)
    f.triggerPlayBark(nil, 203, 'bark')
    t.equals(#f.playSoundFromEntityCalls, 0, 'nil ~= 65535 in Lua, so this must reject exactly like any other non-sentinel value -- same open-engine-question caveat as above')
end)

-- THE RETRY PARAMETER. Three call sites in client/kennel.lua -- the pickup,
-- put-down and enter-kennel confirmations -- have passed `3` as a second
-- argument to ResolveNetworkEntity since they were written, while the
-- function took ONE parameter. Lua silently discarded it: no error, no
-- warning, no retry. All three fire immediately after a server round trip,
-- which is exactly when a single check can legitimately answer false because
-- the entity has not finished streaming in yet -- so the real kennel was
-- treated as absent and the action silently did nothing.
--
-- These tests pin the behaviour those call sites were always asking for, and
-- equally pin that a one-attempt caller stayed exactly as synchronous as it
-- has always been. Several callers run this inside per-frame maintenance
-- loops where an unexpected yield would be its own bug.
t.test('ResolveNetworkEntity: the default is ONE check and ZERO waits -- every existing caller is unchanged and never yields', function()
    local f = newMainFixture()
    f.registerEntity(200, 6000)

    t.equals(f.env.ResolveNetworkEntity(200), 6000)
    t.equals(f.existenceCheckCount(), 1, 'exactly one existence check for a plain call')
    t.equals(f.waitCallCount(), 0, 'a single-attempt resolve must never yield -- per-frame callers depend on this')
end)

t.test('ResolveNetworkEntity: an entity that streams in a moment late is found on a retry, instead of being wrongly reported absent', function()
    local f = newMainFixture()
    -- Absent for the first two checks, present from the third -- the exact
    -- race the kennel confirmations hit.
    f.registerEntityAfterChecks(201, 6001, 3)

    t.equals(f.env.ResolveNetworkEntity(201, 3), 6001, 'three attempts must find an entity that arrives by the third check')
    t.equals(f.waitCallCount(), 2, 'waits BETWEEN attempts only -- two waits for three attempts, never a wasted one after the last')
end)

t.test('ResolveNetworkEntity: the same late entity is MISSED with the default single attempt -- proving the retry is what makes the difference, not the fixture', function()
    local f = newMainFixture()
    f.registerEntityAfterChecks(202, 6002, 3)

    t.isNil(f.env.ResolveNetworkEntity(202), 'one attempt cannot see an entity that has not streamed in yet -- this is the silent no-op the three kennel call sites were suffering')
end)

t.test('ResolveNetworkEntity: retries are BOUNDED -- an entity that never streams in gives up rather than looping forever', function()
    local f = newMainFixture()
    -- Never arrives: more pending checks than attempts allowed.
    f.registerEntityAfterChecks(203, 6003, 99)

    t.isNil(f.env.ResolveNetworkEntity(203, 3))
    t.equals(f.existenceCheckCount(), 3, 'exactly the requested number of attempts, no more')
    t.equals(f.waitCallCount(), 2, 'and no wait after the final failed attempt')
end)

t.test('ResolveNetworkEntity: a nonsense attempts argument falls back to a single check rather than misbehaving', function()
    local f = newMainFixture()
    f.registerEntity(204, 6004)

    -- 0 is the case a bare `attempts or 1` would get wrong, since 0 is truthy
    -- in Lua. A string is the case arithmetic would throw on.
    t.equals(f.env.ResolveNetworkEntity(204, 0), 6004)
    t.equals(f.env.ResolveNetworkEntity(204, 'three'), 6004)
    t.equals(f.waitCallCount(), 0, 'neither may yield')
end)

os.exit(t.summary())
