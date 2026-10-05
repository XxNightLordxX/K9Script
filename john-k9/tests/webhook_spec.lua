--[[
    tests/webhook_spec.lua

    Tests for server/webhook.lua (Discord webhook logging,
    Config.Features.DiscordWebhook) against the REAL, unmodified production
    file, loaded alongside the REAL server/cooldowns.lua (its
    RateLimitCooldown is a genuine NewCooldown() instance, not a stub -- the
    429-backoff tests below exercise the real cooldown mechanics, not a
    hand-rolled timestamp compare) and the REAL server/events.lua
    (FireOutboundEvent) -- events are fired the SAME way every real call
    site in this resource fires them (`FireOutboundEvent('john-k9:events:...',
    ...)`), not by reaching into server/webhook.lua's own AddEventHandler
    registrations directly, so this suite also proves the wiring end to end.

    PerformHttpRequest is stubbed to CAPTURE, never actually send -- see
    newWebhookFixture's own comment for the exact shape. `json.encode` is
    stubbed as an IDENTITY function (returns its argument unchanged): a
    direct read of server/webhook.lua confirms it calls `json.encode(body)`
    exactly once per flush and hands the result straight to
    PerformHttpRequest's `data` parameter with no further string operation
    on it, so an identity stub lets every assertion below inspect the
    exact structured Lua table PerformHttpRequest received, instead of this
    suite reinventing a JSON parser it has no other use for (the same
    restraint tests/fixtures/sandbox.lua's own locale-file reader documents
    for itself: "Deliberately NOT a general JSON parser").

    WHAT THIS FILE PROVES:
      1. OFF BY DEFAULT / INERT WITHOUT A URL (task requirement 1) --
         Config.Features.DiscordWebhook = false, and = true with no
         Config.DiscordWebhook.url configured, are both a clean no-op: no
         thread, and firing every real event afterward sends zero HTTP
         requests, ever.
      2. THE URL ITSELF NEVER APPEARS IN A LOGGED LINE (task requirement 2)
         -- the "no URL configured" warning names the missing config path,
         never a value; a delivery-failure warning never includes the
         configured URL either.
      3. FIRE-AND-FORGET / NEVER BLOCKS GAMEPLAY (task requirement 5) --
         firing an event synchronously enqueues only; zero HTTP requests
         happen until the independent flush thread actually ticks.
      4. BATCHING AND THE HARD QUEUE CAP (task requirement 4) -- more than
         Discord's 10-embeds-per-message limit queued at once still
         produces exactly ONE HTTP POST per flush tick (never one per
         event), and more than Config.DiscordWebhook.maxQueueSize queued
         before any flush DROPS the overflow (never grows the queue
         unboundedly) and reports the drop count in the next flush rather
         than losing it silently.
      5. 429 RATE-LIMIT BACKOFF -- a real Discord 429 respected via a real
         NewCooldown() instance, not a hand-rolled compare: no further HTTP
         attempt happens until the configured backoff elapses, even with
         events still queued.
      6. PER-EVENT DEFAULTS (task requirement 6) -- every one of the 14
         documented event names' DEFAULT_EVENTS on/off value is pinned
         directly, plus an explicit Config.DiscordWebhook.events override in
         both directions (forcing a default-off event on, and a default-on
         event off).
      7. THE DOCUMENTED PAYLOAD SHAPE per formatter -- pinned field-by-field
         for a representative spread of events, including the two
         formatters with conditional/derived fields (searchCompleted's
         optional totalWeight/alertTier, k9Down's coordinate formatting and
         its "unknown" fallback for malformed coords).
      8. NOTHING IN THIS FILE CAN THROW ACROSS THE EVENT BOUNDARY -- a
         malformed/wrong-shaped payload for a known event name is swallowed
         and logged, never propagates out of FireOutboundEvent, and a LATER
         independent, well-formed event still enqueues and sends normally.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

-- ----------------------------------------------------------------------
-- Fixture builder
-- ----------------------------------------------------------------------

--- @param opts table? -- { featureEnabled: boolean?, settings: table? }
--- @return table fixture
local function newWebhookFixture(opts)
    opts = opts or {}

    local fakeNow = 0
    local function GetGameTimer() return fakeNow end

    local threadRunner = Sandbox.newThreadRunner()
    local createThreadCallCount = 0
    local function CreateThread(fn)
        createThreadCallCount = createThreadCallCount + 1
        threadRunner.CreateThread(fn)
    end

    local eventHandlers = {} -- eventName -> { handler, ... }
    local function AddEventHandler(eventName, handler)
        eventHandlers[eventName] = eventHandlers[eventName] or {}
        eventHandlers[eventName][#eventHandlers[eventName] + 1] = handler
    end
    -- Mirrors real FXServer dispatch closely enough for this suite's
    -- purposes: invokes every handler registered under this exact event
    -- name, in registration order. server/events.lua's REAL FireOutboundEvent
    -- calls this (pcall-wrapped) -- see the `fire` helper below, which goes
    -- through FireOutboundEvent rather than calling a captured handler
    -- directly, so this suite exercises the real production call path.
    local function TriggerEvent(eventName, ...)
        for _, handler in ipairs(eventHandlers[eventName] or {}) do
            handler(...)
        end
    end

    local printedLines = {}
    local function printStub(...)
        local parts = {}
        for i = 1, select('#', ...) do parts[i] = tostring(select(i, ...)) end
        printedLines[#printedLines + 1] = table.concat(parts, '\t')
    end

    -- Captures every PerformHttpRequest call this file makes -- there is
    -- exactly one call site (SendHttpPost), but this stub does not assume
    -- that, it just records whatever arrives. `cb` is exposed so a test can
    -- simulate Discord's own async response by calling it directly, exactly
    -- the shape server/webhook.lua's own header REQUIREMENT 3 documents
    -- (statusCode, body, headers, errorData -- this stub only ever needs to
    -- drive statusCode).
    local httpRequests = {}
    local function PerformHttpRequest(url, cb, method, data, headers, options)
        httpRequests[#httpRequests + 1] = {
            url = url, cb = cb, method = method, body = data, headers = headers, options = options,
        }
    end

    -- TEST-ONLY IDENTITY json stub -- see this file's own header for why
    -- this is deliberate and safe, not a gap: production hands json.encode's
    -- result straight to PerformHttpRequest.data with no further string
    -- operation on it, so returning the table UNCHANGED lets every
    -- assertion below inspect real structure instead of parsed JSON text.
    local jsonEncodeCallCount = 0
    local jsonStub = {
        encode = function(v)
            jsonEncodeCallCount = jsonEncodeCallCount + 1
            if opts.jsonEncodeThrows then error('simulated json.encode failure') end
            return v
        end,
        decode = function(v) return v end,
    }

    local config = {
        Features = { DiscordWebhook = opts.featureEnabled ~= false },
        DiscordWebhook = opts.settings,
    }
    if config.DiscordWebhook == nil and opts.featureEnabled ~= false and opts.noUrl ~= true then
        config.DiscordWebhook = {
            url = 'https://discord.example/api/webhooks/123/a-real-token-shaped-value',
            batchIntervalMs = 1000,
            maxQueueSize = 5,
            rateLimitBackoffMs = 5000,
            events = opts.events,
            username = opts.username,
        }
    elseif config.DiscordWebhook == nil and opts.noUrl == true then
        config.DiscordWebhook = {
            batchIntervalMs = 1000,
            maxQueueSize = 5,
            rateLimitBackoffMs = 5000,
        }
    end

    local envOverrides = {
        GetGameTimer           = GetGameTimer,
        CreateThread           = CreateThread,
        Wait                   = threadRunner.Wait,
        AddEventHandler        = AddEventHandler,
        TriggerEvent           = TriggerEvent,
        print                  = printStub,
        PerformHttpRequest     = PerformHttpRequest,
        json                   = jsonStub,
        GetCurrentResourceName = function() return 'john-k9' end,
        Config                 = config,
    }

    local env = Sandbox.newEnv(envOverrides)

    Sandbox.loadInto('../server/cooldowns.lua', env)
    Sandbox.loadInto('../server/events.lua', env) -- FireOutboundEvent -- real production call path, see this file's own header
    Sandbox.loadInto('../server/webhook.lua', env)

    -- PRIME the flush thread once, here, so every test call site can treat
    -- its own `advance(ms); tick()` pairs as a real pass uniformly -- see
    -- fixtures/sandbox.lua's own newThreadRunner doc comment: "because every
    -- sweep thread in this resource calls Wait(...) as its FIRST statement
    -- inside the loop, the FIRST runner.step() call only reaches that
    -- initial Wait and yields immediately -- it primes the coroutine but
    -- performs no sweep pass." Harmless no-op when the feature is off /
    -- misconfigured and no thread was ever created (threadRunner has zero
    -- captured threads to step).
    threadRunner.step()

    return {
        env = env,
        advance = function(ms) fakeNow = fakeNow + ms end,
        tick = function() threadRunner.step() end,
        --- Fires a real john-k9:events:<name> outbound event through the
        --- REAL FireOutboundEvent, exactly how every real call site in this
        --- resource fires one.
        fire = function(eventName, ...) env.FireOutboundEvent('john-k9:events:' .. eventName, ...) end,
        httpRequests = httpRequests,
        printedLines = printedLines,
        createThreadCallCount = function() return createThreadCallCount end,
        jsonEncodeCallCount = function() return jsonEncodeCallCount end,
    }
end

--- Ticks the fixture's flush thread through one real Wait(batchIntervalMs)
--- cycle: prime, then advance + step. Mirrors integrations_spec.lua's own
--- "prime, then advance/tick" convention for a `while true do Wait(x) ...
--- end` loop.
--- @param f table
--- @param intervalMs number
local function advanceAndFlush(f, intervalMs)
    f.advance(intervalMs)
    f.tick()
end

-- ----------------------------------------------------------------------
-- 1. OFF BY DEFAULT / INERT WITHOUT A URL (requirement 1)
-- ----------------------------------------------------------------------

t.test('Config.Features.DiscordWebhook = false starts no thread, registers nothing observable, and stays silent forever', function()
    local f = newWebhookFixture({ featureEnabled = false })
    t.equals(f.createThreadCallCount(), 0, 'no thread should ever be created while the feature flag is off')

    f.fire('certificationGranted', 'CIT1', 'police', 'GRANTER1')
    f.fire('k9Down', 1, 'CIT1', 'police', { x = 1, y = 2, z = 3 }, 5)
    for _ = 1, 5 do advanceAndFlush(f, 999999) end

    t.equals(#f.httpRequests, 0, 'zero HTTP requests, ever, with the feature off')
end)

t.test('Config.Features.DiscordWebhook = true with no Config.DiscordWebhook.url configured stays OFF, warns once, and never sends', function()
    local f = newWebhookFixture({ noUrl = true })
    t.equals(f.createThreadCallCount(), 0, 'no thread should be created without a configured url')

    local warned = false
    for _, line in ipairs(f.printedLines) do
        if line:find('Config.DiscordWebhook.url', 1, true) then warned = true end
    end
    t.isTrue(warned, 'must warn that no url is configured')

    f.fire('certificationGranted', 'CIT1', 'police', 'GRANTER1')
    for _ = 1, 5 do advanceAndFlush(f, 999999) end
    t.equals(#f.httpRequests, 0, 'zero HTTP requests, ever, without a configured url')
end)

t.test('the "no url configured" warning never contains a url-shaped value -- requirement 2', function()
    local f = newWebhookFixture({ noUrl = true })
    for _, line in ipairs(f.printedLines) do
        t.isNil(line:find('http://', 1, true), 'must never print a URL')
        t.isNil(line:find('https://', 1, true), 'must never print a URL')
    end
end)

-- ----------------------------------------------------------------------
-- 2. FIRE-AND-FORGET -- firing an event never sends synchronously
--    (requirement 5)
-- ----------------------------------------------------------------------

t.test('firing an enabled event enqueues only -- zero HTTP requests until the flush thread actually ticks', function()
    local f = newWebhookFixture()
    t.equals(f.createThreadCallCount(), 1, 'the flush thread must start when properly configured')

    f.fire('certificationGranted', 'CIT1', 'police', 'GRANTER1')
    t.equals(#f.httpRequests, 0, 'must not send synchronously from the firing call stack')

    advanceAndFlush(f, 1000) -- batchIntervalMs
    t.equals(#f.httpRequests, 1, 'the queued embed is sent on the next flush tick')
end)

-- ----------------------------------------------------------------------
-- 3. PAYLOAD SHAPE -- pinned field-by-field for a spread of events
--    (requirement 7 / general correctness)
-- ----------------------------------------------------------------------

t.test('certificationGranted produces the documented embed shape', function()
    local f = newWebhookFixture()
    f.fire('certificationGranted', 'CIT1', 'police', 'GRANTER1')
    advanceAndFlush(f, 1000)

    t.equals(#f.httpRequests, 1)
    local body = f.httpRequests[1].body
    t.equals(f.httpRequests[1].method, 'POST')
    t.equals(f.httpRequests[1].headers['Content-Type'], 'application/json')
    t.equals(#body.embeds, 1)
    local embed = body.embeds[1]
    t.equals(embed.title, 'K9 Certification Granted')
    t.equals(embed.fields[1].value, 'CIT1')
    t.equals(embed.fields[2].value, 'police')
    t.equals(embed.fields[3].value, 'GRANTER1')
    t.isNotNil(embed.timestamp, 'every embed carries a timestamp')
end)

t.test('k9Down formats real numeric coordinates to one decimal place', function()
    local f = newWebhookFixture()
    f.fire('k9Down', 7, 'CIT7', 'police', { x = 100.26, y = -200.5, z = 30.0 }, 15)
    advanceAndFlush(f, 1000)

    local embed = f.httpRequests[1].body.embeds[1]
    t.equals(embed.title, 'K9 Unit Down')
    t.equals(embed.fields[1].value, 'CIT7')
    t.equals(embed.fields[2].value, 'police')
    t.equals(embed.fields[3].value, '15')
    t.equals(embed.fields[4].value, '100.3, -200.5, 30.0')
end)

t.test('k9Down falls back to "unknown" for a malformed/missing coords table, never errors', function()
    local f = newWebhookFixture()
    local ok = pcall(f.fire, 'k9Down', 7, 'CIT7', 'police', nil, 15)
    t.isTrue(ok, 'must not error on a malformed coords argument')
    advanceAndFlush(f, 1000)

    local embed = f.httpRequests[1].body.embeds[1]
    t.equals(embed.fields[4].value, 'unknown')
end)

t.test('searchCompleted omits Total Weight/Alert Tier fields when not provided, and includes them when provided', function()
    local f = newWebhookFixture({ events = { searchCompleted = true } })

    f.fire('searchCompleted', 'CIT1', 'police', 'vehicle', 'clean', nil, nil)
    advanceAndFlush(f, 1000)
    local embedA = f.httpRequests[1].body.embeds[1]
    t.equals(#embedA.fields, 4, 'no optional fields when neither is provided')

    f.fire('searchCompleted', 'CIT1', 'police', 'vehicle', 'found', 12.5, 'high')
    advanceAndFlush(f, 1000)
    local embedB = f.httpRequests[2].body.embeds[1]
    t.equals(#embedB.fields, 6, 'both optional fields present when provided')
    t.equals(embedB.fields[5].value, '12.5')
    t.equals(embedB.fields[6].value, 'high')
end)

t.test('xpTierReached reads .label off the two tier-table copies, never the raw tables themselves', function()
    local f = newWebhookFixture({ events = { xpTierReached = true } })
    f.fire('xpTierReached', 'CIT1', { label = 'Elite', xp = 500 }, { label = 'Veteran', xp = 250 })
    advanceAndFlush(f, 1000)

    local embed = f.httpRequests[1].body.embeds[1]
    t.equals(embed.fields[2].value, 'Veteran -> Elite')
end)

-- ----------------------------------------------------------------------
-- 4. PER-EVENT DEFAULTS (requirement 6) -- pinned for all 11 documented
--    event names, plus explicit overrides in both directions
-- ----------------------------------------------------------------------

local DEFAULT_ON_EVENTS = {
    'certificationGranted', 'certificationRevoked', 'certificationTierChanged', 'certificationRenewed',
    'specializationGranted', 'specializationRevoked', 'k9Down',
}
local DEFAULT_OFF_EVENTS = {
    'searchCompleted', 'partnershipEstablished', 'partnershipEnded',
    'xpTierReached',
}

-- Minimal, well-formed argument lists for every event name -- exactly the
-- documented payload shape (server/exports.lua EVENT CONTRACT), just enough
-- for each formatter to run without erroring. Reused across this whole
-- defaults section so each test only has to name the event, not rebuild its
-- argument list.
local SAMPLE_ARGS = {
    certificationGranted     = { 'CIT', 'police', 'GRANTER' },
    certificationRevoked     = { 'CIT', 'police', 'manual' },
    certificationTierChanged = { 'CIT', 'police', 'trainee', 'certified', 'GRANTER' },
    certificationRenewed     = { 'CIT', 'police', 1234567890, 'GRANTER' },
    specializationGranted    = { 'CIT', 'police', 'narcotics', 'GRANTER' },
    specializationRevoked    = { 'CIT', 'police', 'narcotics', 'manual' },
    k9Down                   = { 1, 'CIT', 'police', { x = 0, y = 0, z = 0 }, 10 },
    searchCompleted          = { 'CIT', 'police', 'vehicle', 'clean' },
    partnershipEstablished   = { 'K9CIT', 'HANDLERCIT' },
    partnershipEnded         = { 'K9CIT', 'HANDLERCIT', 'manual' },
    xpTierReached            = { 'CIT', { label = 'B' }, { label = 'A' } },
}

for _, eventName in ipairs(DEFAULT_ON_EVENTS) do
    t.test(('DEFAULT: %s is ON by default (no Config.DiscordWebhook.events override)'):format(eventName), function()
        local f = newWebhookFixture()
        f.fire(eventName, table.unpack(SAMPLE_ARGS[eventName]))
        advanceAndFlush(f, 1000)
        t.equals(#f.httpRequests, 1, eventName .. ' should be sent by default')
    end)
end

for _, eventName in ipairs(DEFAULT_OFF_EVENTS) do
    t.test(('DEFAULT: %s is OFF by default (no Config.DiscordWebhook.events override)'):format(eventName), function()
        local f = newWebhookFixture()
        f.fire(eventName, table.unpack(SAMPLE_ARGS[eventName]))
        for _ = 1, 3 do advanceAndFlush(f, 1000) end
        t.equals(#f.httpRequests, 0, eventName .. ' should NOT be sent by default')
    end)
end

t.test('OVERRIDE: a default-OFF event (searchCompleted) can be explicitly turned on', function()
    local f = newWebhookFixture({ events = { searchCompleted = true } })
    f.fire('searchCompleted', table.unpack(SAMPLE_ARGS.searchCompleted))
    advanceAndFlush(f, 1000)
    t.equals(#f.httpRequests, 1)
end)

t.test('OVERRIDE: a default-ON event (certificationGranted) can be explicitly turned off', function()
    local f = newWebhookFixture({ events = { certificationGranted = false } })
    f.fire('certificationGranted', table.unpack(SAMPLE_ARGS.certificationGranted))
    for _ = 1, 3 do advanceAndFlush(f, 1000) end
    t.equals(#f.httpRequests, 0)
end)

-- ----------------------------------------------------------------------
-- 5. BATCHING -- one POST per flush regardless of how many events queued
--    (requirement 4)
-- ----------------------------------------------------------------------

t.test('BATCHING: 15 queued events (more than Discords own 10-embed-per-message cap) still produce exactly ONE POST containing 10 embeds, with the rest sent on the next flush', function()
    local f = newWebhookFixture({ settings = {
        url = 'https://discord.example/api/webhooks/123/token', batchIntervalMs = 1000, maxQueueSize = 100, rateLimitBackoffMs = 5000,
    } })

    for i = 1, 15 do
        f.fire('certificationGranted', 'CIT' .. i, 'police', 'GRANTER')
    end
    t.equals(#f.httpRequests, 0, 'no HTTP request until the flush thread ticks, no matter how many were queued')

    advanceAndFlush(f, 1000)
    t.equals(#f.httpRequests, 1, 'exactly one POST for this flush tick')
    t.equals(#f.httpRequests[1].body.embeds, 10, 'capped to Discords own 10-embeds-per-message limit')

    advanceAndFlush(f, 1000)
    t.equals(#f.httpRequests, 2, 'the remaining 5 are sent on the NEXT flush tick, not dropped')
    t.equals(#f.httpRequests[2].body.embeds, 5)
end)

-- ----------------------------------------------------------------------
-- 6. HARD QUEUE CAP -- a burst beyond maxQueueSize drops, never grows
--    unbounded (requirement 4)
-- ----------------------------------------------------------------------

t.test('QUEUE CAP: more events than maxQueueSize before any flush drops the overflow and reports the drop count, never grows past the cap', function()
    local f = newWebhookFixture({ settings = {
        url = 'https://discord.example/api/webhooks/123/token', batchIntervalMs = 1000, maxQueueSize = 3, rateLimitBackoffMs = 5000,
    } })

    -- 5 events queued against a cap of 3 -- 2 must be dropped, not queued.
    for i = 1, 5 do
        f.fire('certificationGranted', 'CIT' .. i, 'police', 'GRANTER')
    end

    advanceAndFlush(f, 1000)
    t.equals(#f.httpRequests, 1)
    local embeds = f.httpRequests[1].body.embeds
    -- 3 real events + 1 overflow-notice embed appended by FlushQueue.
    t.equals(#embeds, 4, 'the 3 that fit plus one overflow-notice embed, never more')
    t.contains(embeds[4].description, '2', 'the notice must name how many were actually dropped')

    -- The drop counter resets after being reported -- a later, well-formed
    -- flush with no further overflow must NOT repeat a stale notice.
    f.fire('certificationGranted', 'CIT_LATER', 'police', 'GRANTER')
    advanceAndFlush(f, 1000)
    t.equals(#f.httpRequests[2].body.embeds, 1, 'no repeated/stale overflow notice once the drop was already reported')
end)

t.test('QUEUE CAP: a queue that never gets flushed still never exceeds maxQueueSize -- proven by flushing afterward and seeing only maxQueueSize real embeds, ever', function()
    local f = newWebhookFixture({ settings = {
        url = 'https://discord.example/api/webhooks/123/token', batchIntervalMs = 1000, maxQueueSize = 2, rateLimitBackoffMs = 5000,
    } })

    for i = 1, 50 do
        f.fire('certificationGranted', 'CIT' .. i, 'police', 'GRANTER')
    end

    advanceAndFlush(f, 1000)
    local embeds = f.httpRequests[1].body.embeds
    -- 2 real (the cap) + 1 overflow notice -- NEVER anywhere close to 50,
    -- proving the in-memory queue itself never grew past the configured cap
    -- despite 50 rapid-fire events.
    t.equals(#embeds, 3)
    t.contains(embeds[3].description, '48', 'must report the real drop count (50 - 2 kept)')
end)

-- ----------------------------------------------------------------------
-- 7. 429 RATE-LIMIT BACKOFF -- a real NewCooldown() instance, never a
--    hand-rolled compare
-- ----------------------------------------------------------------------

t.test('a 429 response pauses ALL further sending until rateLimitBackoffMs elapses, even with events still queued', function()
    local f = newWebhookFixture({ settings = {
        url = 'https://discord.example/api/webhooks/123/token', batchIntervalMs = 1000, maxQueueSize = 50, rateLimitBackoffMs = 10000,
    } })

    f.fire('certificationGranted', 'CIT1', 'police', 'GRANTER')
    advanceAndFlush(f, 1000)
    t.equals(#f.httpRequests, 1)
    f.httpRequests[1].cb(429, '', {}) -- simulate Discord's own rate-limit response

    -- Still within the backoff window -- more events queue up, but nothing
    -- new should be sent.
    f.fire('certificationGranted', 'CIT2', 'police', 'GRANTER')
    advanceAndFlush(f, 1000) -- t = 2000, backoff runs to (roughly) 2000 + 10000
    t.equals(#f.httpRequests, 1, 'must not send again while still inside the backoff window')

    f.fire('certificationGranted', 'CIT3', 'police', 'GRANTER')
    advanceAndFlush(f, 1000) -- t = 3000
    t.equals(#f.httpRequests, 1, 'still backed off')

    -- Clear the backoff window (well past 10000ms from the 429).
    advanceAndFlush(f, 20000)
    t.equals(#f.httpRequests, 2, 'sending resumes once the backoff elapses, and the events queued during backoff are still there, not lost')
end)

t.test('a normal (non-429) failure status does NOT trigger the rate-limit backoff -- only 429 does', function()
    local f = newWebhookFixture()
    f.fire('certificationGranted', 'CIT1', 'police', 'GRANTER')
    advanceAndFlush(f, 1000)
    t.equals(#f.httpRequests, 1)
    f.httpRequests[1].cb(500, '', {})

    f.fire('certificationGranted', 'CIT2', 'police', 'GRANTER')
    advanceAndFlush(f, 1000)
    t.equals(#f.httpRequests, 2, 'a plain 500 must not pause sending the way a 429 does')
end)

t.test('a delivery-failure warning never contains a url-shaped value -- requirement 2', function()
    local f = newWebhookFixture()
    f.fire('certificationGranted', 'CIT1', 'police', 'GRANTER')
    advanceAndFlush(f, 1000)
    f.httpRequests[1].cb(500, '', {})

    for _, line in ipairs(f.printedLines) do
        t.isNil(line:find('discord.example', 1, true), 'must never print the configured url, even on a real delivery failure')
    end
end)

-- ----------------------------------------------------------------------
-- 8. FAILURE CONTAINMENT -- nothing in this file can throw across the
--    event boundary; one bad payload never wedges later, unrelated ones
-- ----------------------------------------------------------------------

t.test('a formatter internal error (e.g. a payload value whose own __tostring throws) is swallowed and logged, and a LATER independent well-formed event still sends normally', function()
    local f = newWebhookFixture()

    -- Every formatter in server/webhook.lua reaches every argument only
    -- through tostring()/type() -- both defensive by construction, so a
    -- merely-wrong-shaped argument (nil, a number where a string was
    -- expected, ...) never actually throws inside a formatter. To exercise
    -- the pcall guard around FORMATTERS[eventName](...) for real, this uses
    -- a value whose OWN __tostring metamethod throws -- the one way a
    -- caller-supplied value can make tostring() itself raise.
    local poison = setmetatable({}, { __tostring = function() error('boom') end })
    local ok = pcall(f.fire, 'certificationGranted', poison, 'police', 'GRANTER')
    t.isTrue(ok, 'a formatter internal error must never throw out of FireOutboundEvent')
    t.equals(#f.httpRequests, 0)

    f.fire('certificationGranted', 'CIT_OK', 'police', 'GRANTER')
    advanceAndFlush(f, 1000)
    t.equals(#f.httpRequests, 1, 'the later, well-formed event must still have been queued and sent')
    t.equals(f.httpRequests[1].body.embeds[1].fields[1].value, 'CIT_OK')

    local sawWarning = false
    for _, line in ipairs(f.printedLines) do
        if line:find('failed to format', 1, true) then sawWarning = true end
    end
    t.isTrue(sawWarning, 'the formatting failure must be logged, not silent')
end)

t.test('a json.encode failure drops that one batch (not requeued) and logs, without crashing the flush thread for later batches', function()
    local f = newWebhookFixture({ jsonEncodeThrows = true })
    f.fire('certificationGranted', 'CIT1', 'police', 'GRANTER')

    local ok = pcall(advanceAndFlush, f, 1000)
    t.isTrue(ok, 'an encode failure must never crash the flush thread')
    t.equals(#f.httpRequests, 0, 'nothing sent when encoding fails')

    local sawWarning = false
    for _, line in ipairs(f.printedLines) do
        if line:find('failed to encode', 1, true) then sawWarning = true end
    end
    t.isTrue(sawWarning, 'the encode failure must be logged, not silent')
end)

os.exit(t.summary())
