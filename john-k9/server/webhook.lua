--[[
    john-k9/server/webhook.lua

    DISCORD WEBHOOK LOGGING -- an outbound-only bridge from this resource's
    OWN already-documented `john-k9:events:*` contract (server/exports.lua
    EVENT CONTRACT section) to a single Discord channel, for operators who
    live in Discord day-to-day rather than an in-game admin panel. This file
    adds a LISTENER on events that already fire; it invents no new event,
    modifies no existing one, and adds no new business logic anywhere else in
    this resource.

    THIS FILE NEVER GRANTS, REVOKES, OR AWARDS ANYTHING -- it only reads
    payloads other files already computed and already fired for their own
    reasons (server/exports.lua's EVENT CONTRACT is the authority on what
    each payload contains and why). If the mapping between an event and what
    gets posted to Discord ever needs to change, THIS is the file to change;
    every other file's own success point stays untouched.

    ======================================================================
    REQUIREMENT 1 -- OFF BY DEFAULT, INERT WITH NO URL CONFIGURED.
    Gated at the very top by `Config.Features.DiscordWebhook` (ships
    `false`) -- same "rawtoplevel" shape as server/integrations.lua's own
    K9DownDispatch gate (see server/runtimecontrol.lua's own ENGINE
    CONSTRAINT section for that vocabulary): with the flag off, this file
    creates no thread, registers no AddEventHandler, allocates no table, and
    reads nothing else off Config.DiscordWebhook at all. With the flag on
    but no real `Config.DiscordWebhook.url` set, this file prints ONE
    warning (never the url's own value -- see REQUIREMENT 2) and returns
    just as early -- a server that turns this flag on without pasting in a
    real webhook URL gets total silence, not a resource that spins forever
    trying to POST to an empty string.

    ======================================================================
    REQUIREMENT 2 -- A WEBHOOK URL IS A SECRET. Enumerated, one item per
    bullet the task specified, each with how this file satisfies it:
      - "never print it to console" -- `Config.DiscordWebhook.url` (aliased
        below as `settings.url`) is read into exactly ONE call in this
        entire file: the `PerformHttpRequest(settings.url, ...)` call inside
        SendHttpPost. No print/error/warning line anywhere in this file ever
        interpolates `settings.url` or `Config.DiscordWebhook.url` -- not
        even the "no URL configured" warning above, which names the MISSING
        config path, never a value.
      - "never include it in an error message" -- every pcall failure this
        file logs (encode failure, PerformHttpRequest throwing, a listener
        callback erroring) formats only the error object pcall returned,
        never `settings` or any field of it.
      - "never expose it through any callback the tablet or a client could
        reach" -- this file registers NO `lib.callback.register`, NO
        `RegisterNetEvent`, and NO `exports(...)` of its own. Nothing in
        server/tablet.lua, server/exports.lua, or anywhere else in this
        resource reads `Config.DiscordWebhook` (verified by direct grep of
        `DiscordWebhook` across every file before writing this one) -- nor
        does anything in this resource dump the whole `Config` table to a
        client (verified by direct grep for any `TriggerClientEvent`/
        `SendNUIMessage`/callback-return site handing back the raw `Config`
        table -- none exists).
      - "never let it reach a client at all. This is server-only." -- this
        file lives in `server_scripts` only, is never listed in
        `client_scripts`, calls no `TriggerClientEvent`, and sends
        `SendNUIMessage` to nobody. The only network call this file ever
        makes is the one outbound `PerformHttpRequest` to Discord itself.

    ======================================================================
    REQUIREMENT 3 -- PerformHttpRequest, VERIFIED, NOT ASSUMED. This
    project's own standing rule (.luacheckrc's header: "an unregistered or
    misused native does not throw on FXServer, it silently does nothing
    forever with nothing logged") applies doubly here, since a silently-dead
    webhook looks IDENTICAL to a working one nobody has triggered yet --
    exactly the failure class the task called out by name.

    VERIFIED AGAINST PRIMARY SOURCE (this pass): `PerformHttpRequest` is NOT
    itself a raw native -- the low-level native is
    `PERFORM_HTTP_REQUEST_INTERNAL_EX` (CFX namespace, hash 0x6B171E87,
    `apiset: server`, confirmed against runtime.fivem.net/doc/natives_cfx.json
    fetched this session). `PerformHttpRequest` is a genuine Lua-level
    WRAPPER function defined in FiveM's own shared Lua runtime file,
    `data/shared/citizen/scripting/lua/scheduler.lua` (citizenfx/fivem,
    master, fetched this session), inside the `if isDuplicityVersion then`
    branch (that file's own line 318, closed by `else` at line 411) --
    i.e. SERVER-ONLY, defined only when the Lua VM is FXServer's, matching
    where this file lives. The exact source (scheduler.lua, ~line 377):

        function PerformHttpRequest(url, cb, method, data, headers, options)
            local followLocation = true
            if options and options.followLocation ~= nil then
                followLocation = options.followLocation
            end
            local t = { url = url, method = method or 'GET', data = data or '',
                        headers = headers or {}, followLocation = followLocation }
            local id = PerformHttpRequestInternalEx(t)
            if id ~= -1 then
                httpDispatch[id] = cb
            else
                cb(0, nil, {}, 'Failure handling HTTP request')
            end
        end

    CONSEQUENCES this file's own design relies on, read directly off that
    source rather than assumed from memory:
      - The callback fires with FOUR arguments -- `(statusCode, body,
        headers, errorData)` -- not the commonly-quoted three-argument
        shape. This file's own callback only ever reads the first
        (`statusCode`), so the extra two are simply unused parameters, never
        misread as something else.
      - A same-tick synchronous failure (`PerformHttpRequestInternalEx`
        returning -1 -- e.g. a malformed request table) invokes `cb`
        IMMEDIATELY, with `statusCode = 0`, not via the async
        `__cfx_internal:httpResponse` dispatch. This file's callback
        branches on `type(statusCode) ~= 'number' or statusCode < 200 or
        statusCode >= 300` for "not a success", which already covers 0
        without a separate special case.
      - `data` is sent as-is, a plain string -- this file always hands it a
        `json.encode(...)`-produced string, never a raw table (a raw table
        there would silently serialize as FXServer's own internal msgpack
        args shape, not JSON, and Discord would 400 on it with nothing
        logged pointing at why).
      - This is genuinely ASYNCHRONOUS from this file's own calling code's
        point of view: `PerformHttpRequest` returns immediately every time
        (the native call at its heart is fire-off-and-poll-later on FXServer's
        own side, never a blocking wait), so calling it from this file's own
        `CreateThread` poll loop can never stall that loop, and this file
        never calls it from inside an event handler on the gameplay path at
        all (see REQUIREMENT 5 below for exactly where it IS called from).

    `json.encode`/`json.decode` are the other CFX-runtime-provided globals
    this file relies on. Not independently re-verified against FiveM's own
    C++ source this pass (that source was not reachable through the
    available channels), but this resource ALREADY, unconditionally,
    transitively depends on `json.encode` being real and present in this
    exact runtime: this resource's own fxmanifest.lua declares `ox_lib` as a
    hard dependency and loads `@ox_lib/init.lua` in `shared_scripts` before
    any file of this resource's own runs, and ox_lib's own `init.lua` calls
    `json.encode` directly at its own top level with no `require`/guard of
    any kind (confirmed by direct source search of the live
    overextended/ox_lib repository this session). If `json.encode` were not
    a real global in this runtime, ox_lib itself would already be broken on
    every install of this resource, independent of anything this file does
    -- so this file rides an already-load-bearing assumption rather than
    introducing a new, unverified one.

    ======================================================================
    REQUIREMENT 4 -- RATE LIMIT AND BATCH, WITH A HARD, BOUNDED CAP.
    Discord rate-limits a single webhook hard (well-documented burst/sustain
    limits well under what "one HTTP request per K9 event" could produce on
    a busy server running searches/SAR calls/certifications back to back).
    This file never sends one request per event. Design:

      1. QUEUE, NOT REQUEST-PER-EVENT. Every enabled event handler below
         does zero network I/O -- it only formats a small embed table and
         appends it to an in-memory array, `Queue`. A single `CreateThread`
         loop wakes every `Config.DiscordWebhook.batchIntervalMs` (default
         8000ms) and sends AT MOST ONE HTTP POST per wake, carrying up to
         Discord's own documented per-message embed cap (10) pulled off the
         front of `Queue`. At the default interval that is at most 7.5
         requests/minute even under sustained saturation -- comfortably
         under Discord's limit with margin for the operator to raise
         `batchIntervalMs` further on an even busier server, or lower it on
         a quiet one.
      2. HARD, BOUNDED QUEUE CAP -- `Config.DiscordWebhook.maxQueueSize`
         (default 40). `EnqueueEmbed` below is a straight `if #Queue >=
         maxQueueSize then <drop, count it> else <append> end` -- there is
         no unbounded growth path in this file, full stop. A burst beyond
         the cap DROPS THE NEW EVENT (never grows the array, never evicts an
         already-queued older one) and increments `queueDroppedCount`. The
         next successful flush appends one extra summary embed naming how
         many were dropped since the last flush, then resets the counter --
         so an operator sees "N events were dropped" rather than silent data
         loss with no signal at all, while the in-memory footprint itself
         never exceeds `maxQueueSize` embed tables plus that one summary
         entry.
      3. RATE-LIMIT BACKOFF ON A REAL 429. If Discord itself responds 429,
         this file backs off ALL further sending for
         `Config.DiscordWebhook.rateLimitBackoffMs` (default 60000) using a
         real `server/cooldowns.lua` `NewCooldown` instance (never a
         hand-rolled timestamp compare -- this resource's own established
         convention, and the exact class of bug ResolveConfiguredThresholdMs's
         own header addendum documents finding repeatedly when a
         config-editable duration is NOT run through it before reaching
         `NewCooldown`). Events keep enqueueing (up to the same cap) during a
         backoff; nothing is lost beyond the normal cap-drop rule already
         described.
      4. NO RETRY-WITH-REQUEUE. A batch that fails to deliver (network
         error, non-2xx, malformed encode) is NOT put back on `Queue` --
         this file fires it once and moves on. This is a deliberate reading
         of the task's own "a dropped log line is acceptable; an unbounded
         queue is not": a retry-and-requeue design is exactly how a
         persistently-down Discord turns into unbounded growth (every failed
         batch adding back to a queue that keeps growing while new events
         keep arriving) -- refusing to requeue keeps the bound in point 2
         absolute, under every failure mode, not just the "queue got full"
         one.

    ======================================================================
    REQUIREMENT 5 -- NEVER LET IT AFFECT GAMEPLAY.
    Every `AddEventHandler('john-k9:events:...', ...)` handler below runs
    SYNCHRONOUSLY, on the SAME call stack as whatever gameplay success point
    fired it (FireOutboundEvent's own `TriggerEvent` is synchronous -- see
    server/events.lua's header) -- so each one is held to the same standard
    a gameplay-path function itself would be: pure in-memory table
    construction and one array append, wrapped in its own `pcall` (belt and
    braces on top of FireOutboundEvent's own pcall around the whole
    `TriggerEvent` call -- this file's own handler must never be the reason
    a DIFFERENT, unrelated listener in another resource fails to run for the
    same event). ZERO network I/O, ZERO natives beyond plain table/string
    operations, and ZERO yields happen inside any event handler in this
    file. The only place `PerformHttpRequest` is ever called from is the
    independent `CreateThread` flush loop -- not triggered by, not awaited
    by, and not blocking any player action. If Discord is completely down,
    the observable effect anywhere else in this resource is exactly zero:
    the flush loop's own `pcall` swallows the failure, logs at most once per
    state transition (see FlushQueue's own comment on `wasFailing`, so a
    persistently-dead Discord produces one console line, not a flood), and
    the next `Config.DiscordWebhook.batchIntervalMs` tick tries again.

    ======================================================================
    REQUIREMENT 6 -- WHICH EVENTS, OPERATOR-CHOSEN, WITH VOLUME-AWARE
    DEFAULTS. `Config.DiscordWebhook.events[<name>]` is an explicit
    per-event boolean; `DEFAULT_EVENTS` below is only the fallback for a
    name the operator's own table leaves unset (nil), never a silent
    override of an explicit `false`. Defaults were chosen on SIGNAL-VS-VOLUME,
    not "everything on":
      DEFAULT ON  -- certificationGranted/Revoked/TierChanged/Renewed,
        specializationGranted/Revoked, k9Down. Every one
        of these is a discrete ADMIN ACTION or a rare safety event -- an
        operator with a real department only sees a handful of these per
        session even on a busy server, and each one is exactly the kind of
        thing an operator staring at Discord, not the in-game audit command,
        wants to know about immediately.
      DEFAULT OFF -- searchCompleted, partnershipEstablished,
        partnershipEnded, xpTierReached. The task named
        "barks, searches, and combat" as the busy-server volume risk by name
        -- `searchCompleted` fires on every single completed search
        (contraband or clean) and is the one event in this whole contract
        most likely to fire dozens of times an hour on a busy PD, so it
        defaults OFF even though some operators will genuinely want every
        search logged (the task's own "some want every search, some only
        want use-of-force" -- this file makes that a one-line config flip,
        never an all-or-nothing choice). partnership*/
        xpTierReached are lower-signal for day-to-day
        Discord-based operations (player-facing flavor/progression, not an
        admin action or a safety event) and default off for that reason,
        not a volume concern on their own.

    ======================================================================
    REQUIREMENT 7 -- NO PERSONAL DATA BEYOND WHAT THE GAME ALREADY SHOWS.
    Every field this file ever puts in an embed is copied VERBATIM from an
    already-documented `john-k9:events:*` payload (server/exports.lua's
    EVENT CONTRACT) -- citizenid, job name, certification tier/specialization
    keys, a server-local connection id, in-world coordinates, a call
    duration, an XP tier label. None of that is invented here, and none of
    it is anything this resource's OWN in-game `AdminAuditCommands` surface
    does not already show a rank-gated in-game viewer. This file never reads
    a license identifier, an IP address, a Discord user id, or any other
    real-person identifier -- none of those exist anywhere in this
    resource's own outbound event payloads to begin with, so there is
    nothing of that kind for this file to accidentally forward.

    ======================================================================
    REQUIREMENT 8 -- LOCALE DECISION: HARDCODED ENGLISH, NOT
    `locales/en.json`. Deliberate, not an oversight -- and this resource
    already has a directly-applicable precedent for it:
    server/integrations.lua's own k9Down dispatch `Alert(...)` call builds
    its `title`/`message` as PLAIN HARDCODED STRINGS, with that file's own
    comment citing shared/compat/dispatch.lua's header LOCALE NOTE ("this
    file deliberately never calls `locale()` itself... `title`/`message`
    arrive already-resolved"). That precedent is for a dispatch-system
    integration message; a Discord embed is an even clearer case of the
    same category -- it is never rendered inside this resource's own NUI,
    never seen by a player unless an operator chooses to give them Discord
    channel access, and is read exclusively by server STAFF running an
    external tool this resource has no rendering control over at all (an
    operator can already rename/re-theme/translate their own Discord
    channel however they like; nothing here would improve on that). This
    resource's `locales/en.json` migration (fxmanifest.lua's own note: "319
    keys, every PLAYER-FACING string... routed through locale()") is scoped
    to strings a PLAYER sees, which this is not. No new locale keys are
    needed or added for this file.
    ======================================================================
]]

if not Config.Features.DiscordWebhook then return end

if type(Config.DiscordWebhook) ~= 'table'
    or type(Config.DiscordWebhook.url) ~= 'string'
    or Config.DiscordWebhook.url == ''
then
    -- INERT, NOT AN ERROR (REQUIREMENT 1) -- and this warning never
    -- interpolates the url's own value, only the fact that a usable one is
    -- absent (REQUIREMENT 2).
    print(
        '[John-K9] Config.Features.DiscordWebhook is true but Config.DiscordWebhook.url is not set to a real ' ..
        'Discord webhook URL -- Discord webhook logging stays OFF for this session. Set Config.DiscordWebhook.url ' ..
        'in config.lua to enable it. Treat that URL as a secret: never commit a real one to source control, and ' ..
        'never paste it anywhere this resource could echo back to a player or an NUI screen.'
    )
    return
end

if type(PerformHttpRequest) ~= 'function' or type(json) ~= 'table' or type(json.encode) ~= 'function' then
    -- Runtime existence guard, this resource's established convention --
    -- never assumed present, even though on a real FXServer both always
    -- are (see this file's header REQUIREMENT 3 for the verification).
    print('[John-K9] PerformHttpRequest/json.encode are not available in this runtime -- Discord webhook logging stays OFF for this session.')
    return
end

local settings = Config.DiscordWebhook

-- ======================================================================
-- CONFIG-SAFETY GUARD -- clamp-and-warn, never assert-and-abort, matching
-- server/integrations.lua's own CONFIG-SAFETY GUARD and server/cooldowns.lua's
-- own ADDENDUM ("does an operator's config.lua edit alone... reach this
-- value? If yes it must be clamped and warned about, never asserted and
-- aborted"). Every field below is exactly that shape.
-- ======================================================================

--- batchIntervalMs/rateLimitBackoffMs are genuine ms DURATIONS an
--- operator's own config.lua edit reaches directly -- routed through the
--- shared ResolveConfiguredThresholdMs (server/cooldowns.lua), not a bespoke
--- reimplementation, per that file's own documented rule for this exact
--- shape.
settings.batchIntervalMs = ResolveConfiguredThresholdMs(
    settings.batchIntervalMs, 8000, 'Config.DiscordWebhook.batchIntervalMs')
settings.rateLimitBackoffMs = ResolveConfiguredThresholdMs(
    settings.rateLimitBackoffMs, 60000, 'Config.DiscordWebhook.rateLimitBackoffMs')

--- maxQueueSize is a COUNT, not a duration -- ResolveConfiguredThresholdMs's
--- own 250ms floor would be meaningless (and wrong) applied to it, the exact
--- same "this field's valid RANGE doesn't match a duration's" reasoning
--- server/integrations.lua's own header gives for healthThreshold getting
--- its own bespoke resolver instead of reusing that one. Must be a positive
--- integer -- at least 1, since 0 would make every single event an
--- automatic drop, silently indistinguishable from the feature doing
--- nothing at all.
--- @param value any
--- @return boolean
local function IsValidQueueSize(value)
    return type(value) == 'number' and value == value and value >= 1 and value == math.floor(value)
end

if not IsValidQueueSize(settings.maxQueueSize) then
    print(('[John-K9] Config.DiscordWebhook.maxQueueSize is missing or not a positive integer (found: %s). ' ..
        'Using the built-in fallback of 40 instead.'):format(tostring(settings.maxQueueSize)))
    settings.maxQueueSize = 40
end

-- ======================================================================
-- EVENT SELECTION (REQUIREMENT 6)
-- ======================================================================

local DEFAULT_EVENTS = {
    certificationGranted     = true,
    certificationRevoked     = true,
    certificationTierChanged = true,
    certificationRenewed     = true,
    specializationGranted    = true,
    specializationRevoked    = true,
    k9Down                   = true,
    searchCompleted          = false,
    partnershipEstablished   = false,
    partnershipEnded         = false,
    xpTierReached            = false,
}

local eventsConfig = type(settings.events) == 'table' and settings.events or {}

--- @param eventName string
--- @return boolean
local function IsEventEnabled(eventName)
    local configured = eventsConfig[eventName]
    if configured == nil then return DEFAULT_EVENTS[eventName] == true end
    return configured == true
end

-- ======================================================================
-- QUEUE (REQUIREMENT 4)
-- ======================================================================

local MAX_EMBEDS_PER_MESSAGE = 10 -- Discord's own documented per-message embed cap

local Queue = {} -- array of embed tables, oldest first -- bounded by settings.maxQueueSize, see EnqueueEmbed
local queueDroppedCount = 0

--- @param embed table
local function EnqueueEmbed(embed)
    if #Queue >= settings.maxQueueSize then
        queueDroppedCount = queueDroppedCount + 1
        return
    end
    Queue[#Queue + 1] = embed
end

--- Pulls up to MAX_EMBEDS_PER_MESSAGE embeds off the FRONT of Queue and
--- shifts the remainder left in one pass -- O(#Queue), fine at this file's
--- own bounded size (<= settings.maxQueueSize, a small operator-set number).
--- @return table batch -- possibly empty
local function TakeBatch()
    local take = math.min(#Queue, MAX_EMBEDS_PER_MESSAGE)
    if take == 0 then return {} end

    local batch = {}
    for i = 1, take do batch[i] = Queue[i] end

    local remaining = #Queue - take
    for i = 1, remaining do Queue[i] = Queue[i + take] end
    for i = remaining + 1, #Queue do Queue[i] = nil end

    return batch
end

-- ======================================================================
-- HTTP SEND (REQUIREMENTS 3 and 5)
-- ======================================================================

local RateLimitCooldown = NewCooldown(settings.rateLimitBackoffMs)
local RATE_LIMIT_KEY = 'discord'

local wasFailing = false -- so a persistently-dead Discord logs one line per state transition, never once per flush tick

--- Fires the one and only HTTP call this file ever makes. Fire-and-forget:
--- returns immediately (see this file's header REQUIREMENT 3 on
--- PerformHttpRequest's own real async shape), and `onDone` is invoked
--- later, asynchronously, with just the status code -- never blocking
--- whatever thread called SendHttpPost.
--- @param jsonBody string
--- @param onDone fun(statusCode: number)
local function SendHttpPost(jsonBody, onDone)
    local ok, err = pcall(PerformHttpRequest, settings.url, function(statusCode, _responseBody, _responseHeaders)
        local cbOk, cbErr = pcall(onDone, statusCode)
        if not cbOk then
            print(('[John-K9] webhook: response-handling error: %s'):format(tostring(cbErr)))
        end
    end, 'POST', jsonBody, { ['Content-Type'] = 'application/json' })

    if not ok then
        -- `err` here is whatever pcall/PerformHttpRequest itself produced --
        -- never settings.url or jsonBody (REQUIREMENT 2).
        print(('[John-K9] webhook: PerformHttpRequest failed to dispatch: %s'):format(tostring(err)))
    end
end

--- One flush pass: takes at most one batch off Queue (plus a queue-overflow
--- summary embed if anything was dropped since the last flush) and sends AT
--- MOST ONE HTTP POST. A no-op (zero calls of any kind) when there is
--- nothing to report and nothing was dropped -- never pings Discord with an
--- empty message.
local function FlushQueue()
    if RateLimitCooldown.IsOnCooldown(RATE_LIMIT_KEY) then return end
    if #Queue == 0 and queueDroppedCount == 0 then return end

    local batch = TakeBatch()

    if queueDroppedCount > 0 then
        batch[#batch + 1] = {
            title = 'Webhook queue overflow',
            description = ('%d K9 unit event(s) were dropped because the outbound queue was full.'):format(queueDroppedCount),
            color = 0xE67E22,
        }
        queueDroppedCount = 0
    end

    if #batch == 0 then return end

    local body = { embeds = batch }
    if type(settings.username) == 'string' and settings.username ~= '' then body.username = settings.username end
    if type(settings.avatarUrl) == 'string' and settings.avatarUrl ~= '' then body.avatar_url = settings.avatarUrl end

    local encodeOk, jsonBody = pcall(json.encode, body)
    if not encodeOk then
        print(('[John-K9] webhook: failed to encode this batch, dropping it (not requeued -- see this file\'s ' ..
            'header REQUIREMENT 4 point 4): %s'):format(tostring(jsonBody)))
        return
    end

    SendHttpPost(jsonBody, function(statusCode)
        if statusCode == 429 then
            RateLimitCooldown.Touch(RATE_LIMIT_KEY)
            return
        end

        if type(statusCode) ~= 'number' or statusCode < 200 or statusCode >= 300 then
            if not wasFailing then
                wasFailing = true
                print(('[John-K9] webhook: Discord returned status %s for a batch -- will keep retrying on ' ..
                    'the next flush interval (this line prints once per failure streak, not once per flush)'):format(tostring(statusCode)))
            end
            return
        end

        if wasFailing then
            wasFailing = false
            print('[John-K9] webhook: Discord delivery recovered')
        end
    end)
end

CreateThread(function()
    while true do
        Wait(settings.batchIntervalMs)
        local ok, err = pcall(FlushQueue)
        if not ok then
            print(('[John-K9] webhook: flush error: %s'):format(tostring(err)))
        end
    end
end)

-- ======================================================================
-- EMBED FORMATTERS -- one per event this file knows about. Every argument
-- read below is exactly, and only, a field server/exports.lua's EVENT
-- CONTRACT already documents for that event name, in the documented order
-- -- see this file's header REQUIREMENT 7. No locale() calls anywhere in
-- this section -- see this file's header REQUIREMENT 8.
-- ======================================================================

local COLOR_GRANT = 0x2ECC71
local COLOR_REVOKE = 0xE74C3C
local COLOR_INFO = 0x3498DB
local COLOR_ALERT = 0xE67E22

--- @param embed table
--- @return table embed -- same table, with the fields every embed shares
local function Finalize(embed)
    embed.footer = { text = 'john-k9' }
    embed.timestamp = os.date('!%Y-%m-%dT%H:%M:%SZ')
    return embed
end

local FORMATTERS = {}

FORMATTERS.certificationGranted = function(citizenid, jobName, grantedByCitizenid)
    return Finalize({
        title = 'K9 Certification Granted',
        color = COLOR_GRANT,
        fields = {
            { name = 'Citizen ID', value = tostring(citizenid), inline = true },
            { name = 'Department', value = tostring(jobName), inline = true },
            { name = 'Granted By', value = tostring(grantedByCitizenid), inline = true },
        },
    })
end

FORMATTERS.certificationRevoked = function(citizenid, jobName, reason)
    return Finalize({
        title = 'K9 Certification Revoked',
        color = COLOR_REVOKE,
        fields = {
            { name = 'Citizen ID', value = tostring(citizenid), inline = true },
            { name = 'Department', value = tostring(jobName), inline = true },
            { name = 'Reason', value = tostring(reason), inline = true },
        },
    })
end

FORMATTERS.certificationTierChanged = function(citizenid, jobName, oldTier, newTier, granterCitizenid)
    return Finalize({
        title = 'K9 Certification Tier Changed',
        color = COLOR_INFO,
        fields = {
            { name = 'Citizen ID', value = tostring(citizenid), inline = true },
            { name = 'Department', value = tostring(jobName), inline = true },
            { name = 'Tier Change', value = ('%s -> %s'):format(tostring(oldTier), tostring(newTier)), inline = true },
            { name = 'Changed By', value = tostring(granterCitizenid), inline = true },
        },
    })
end

FORMATTERS.certificationRenewed = function(citizenid, jobName, expiresAtUnix, granterCitizenid)
    local expiresText = 'unknown'
    if type(expiresAtUnix) == 'number' then
        local ok, formatted = pcall(os.date, '!%Y-%m-%d %H:%M:%S UTC', expiresAtUnix)
        if ok then expiresText = formatted end
    end
    return Finalize({
        title = 'K9 Certification Renewed',
        color = COLOR_INFO,
        fields = {
            { name = 'Citizen ID', value = tostring(citizenid), inline = true },
            { name = 'Department', value = tostring(jobName), inline = true },
            { name = 'Expires', value = expiresText, inline = true },
            { name = 'Renewed By', value = tostring(granterCitizenid), inline = true },
        },
    })
end

FORMATTERS.specializationGranted = function(citizenid, jobName, specializationKey, granterCitizenid)
    return Finalize({
        title = 'K9 Specialization Granted',
        color = COLOR_GRANT,
        fields = {
            { name = 'Citizen ID', value = tostring(citizenid), inline = true },
            { name = 'Department', value = tostring(jobName), inline = true },
            { name = 'Specialization', value = tostring(specializationKey), inline = true },
            { name = 'Granted By', value = tostring(granterCitizenid), inline = true },
        },
    })
end

FORMATTERS.specializationRevoked = function(citizenid, jobName, specializationKey, reason)
    return Finalize({
        title = 'K9 Specialization Revoked',
        color = COLOR_REVOKE,
        fields = {
            { name = 'Citizen ID', value = tostring(citizenid), inline = true },
            { name = 'Department', value = tostring(jobName), inline = true },
            { name = 'Specialization', value = tostring(specializationKey), inline = true },
            { name = 'Reason', value = tostring(reason), inline = true },
        },
    })
end

FORMATTERS.k9Down = function(_source, citizenid, jobName, coords, health)
    local coordsText = 'unknown'
    if type(coords) == 'table' and type(coords.x) == 'number' and type(coords.y) == 'number' and type(coords.z) == 'number' then
        coordsText = ('%.1f, %.1f, %.1f'):format(coords.x, coords.y, coords.z)
    end
    return Finalize({
        title = 'K9 Unit Down',
        color = COLOR_ALERT,
        fields = {
            { name = 'Citizen ID', value = tostring(citizenid), inline = true },
            { name = 'Department', value = tostring(jobName), inline = true },
            { name = 'Health', value = tostring(health), inline = true },
            { name = 'Coordinates', value = coordsText, inline = false },
        },
    })
end

FORMATTERS.searchCompleted = function(searcherCitizenid, searcherJob, targetType, result, totalWeight, alertTier)
    local fields = {
        { name = 'Citizen ID', value = tostring(searcherCitizenid), inline = true },
        { name = 'Department', value = tostring(searcherJob), inline = true },
        { name = 'Target Type', value = tostring(targetType), inline = true },
        { name = 'Result', value = tostring(result), inline = true },
    }
    if type(totalWeight) == 'number' then
        fields[#fields + 1] = { name = 'Total Weight', value = tostring(totalWeight), inline = true }
    end
    if type(alertTier) == 'string' then
        fields[#fields + 1] = { name = 'Alert Tier', value = alertTier, inline = true }
    end
    return Finalize({
        title = 'K9 Search Completed',
        color = result == 'found' and COLOR_ALERT or COLOR_INFO,
        fields = fields,
    })
end

FORMATTERS.partnershipEstablished = function(k9Citizenid, handlerCitizenid)
    return Finalize({
        title = 'K9 Partnership Established',
        color = COLOR_GRANT,
        fields = {
            { name = 'K9 Citizen ID', value = tostring(k9Citizenid), inline = true },
            { name = 'Handler Citizen ID', value = tostring(handlerCitizenid), inline = true },
        },
    })
end

FORMATTERS.partnershipEnded = function(k9Citizenid, handlerCitizenid, reason)
    return Finalize({
        title = 'K9 Partnership Ended',
        color = COLOR_REVOKE,
        fields = {
            { name = 'K9 Citizen ID', value = tostring(k9Citizenid), inline = true },
            { name = 'Handler Citizen ID', value = tostring(handlerCitizenid), inline = true },
            { name = 'Reason', value = tostring(reason), inline = true },
        },
    })
end

FORMATTERS.xpTierReached = function(citizenid, newTier, oldTier)
    local newLabel = type(newTier) == 'table' and tostring(newTier.label) or 'unknown'
    local oldLabel = type(oldTier) == 'table' and tostring(oldTier.label) or 'unknown'
    return Finalize({
        title = 'K9 XP Tier Reached',
        color = COLOR_GRANT,
        fields = {
            { name = 'Citizen ID', value = tostring(citizenid), inline = true },
            { name = 'Tier Change', value = ('%s -> %s'):format(oldLabel, newLabel), inline = true },
        },
    })
end

-- ======================================================================
-- REGISTRATION -- one AddEventHandler per known event name, each doing
-- nothing but format + enqueue (REQUIREMENT 5). See this file's header
-- REQUIREMENT 6 for IsEventEnabled's own default table.
-- ======================================================================

for eventName in pairs(FORMATTERS) do
    AddEventHandler('john-k9:events:' .. eventName, function(...)
        local ok, err = pcall(function(...)
            if not IsEventEnabled(eventName) then return end

            local formatOk, embed = pcall(FORMATTERS[eventName], ...)
            if not formatOk or type(embed) ~= 'table' then
                print(('[John-K9] webhook: failed to format %s for Discord: %s'):format(eventName, tostring(embed)))
                return
            end

            EnqueueEmbed(embed)
        end, ...)

        if not ok then
            print(('[John-K9] webhook: internal error handling %s: %s'):format(eventName, tostring(err)))
        end
    end)
end
