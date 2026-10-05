--[[
    john-k9/shared/compat/core.lua

    THE DETECTION ENGINE for Config.Compat (config.lua, bottom of the file --
    read that block's own comment FIRST; it is the plain-English contract
    this file implements and every promise it makes to a non-technical
    owner is honoured here by construction, not by convention).

    Owner's own words for the underlying request: "I want even further
    control of stuff in my config what if i use diffrent resources or
    custom resources custom inventory etc i want it to be able to autodetect
    what i use and it will work with it."

    ======================================================================
    WHAT THIS FILE IS

    A SHARED script (loaded on both the client and server Lua VMs
    independently -- see fxmanifest.lua's own comment on this file's
    placement). It exposes ONE resource-global table, `K9Compat`, that four
    sibling files (shared/compat/inventory.lua, target.lua, framework.lua,
    dispatch.lua, ambulance.lua -- each ALSO a shared script, each loaded
    AFTER this one) register adapters into, and that every OTHER file in
    this resource that needs to talk to a third-party inventory/target/
    framework/dispatch/ambulance script reads adapters FROM.

    THE CONTRACT (unchanged from what every sibling file is already coding
    against -- if this file's public shape below ever needs to change, that
    is a breaking change to four other files being written concurrently and
    must be raised with all of them AND main before landing, not decided
    here alone):

        K9Compat.RegisterAdapter(system, resourceName, factory)
            factory(realm) -> table | nil    -- realm is 'client' or
                                              -- 'server'; nil means "this
                                              -- resource is present but this
                                              -- factory judges it unusable
                                              -- for this realm -- skip me,
                                              -- try the next candidate."
        K9Compat.Get(system) -> adapter       -- NEVER nil.
        K9Compat.Which(system) -> resourceName|nil, reasonString
        K9Compat.Report() -> multi-line human-readable string
        K9Compat.Redetect() -> nil
        K9Compat.RequiredMethods[system][realm] -> array of method-name
            strings that MUST exist on whatever factory(realm) returns, or
            that candidate is REJECTED (see VERIFICATION below).

    RESOLUTION ORDER, highest first, per system: `Systems[system].custom`
    (an operator-written table -- wins outright, even over `.override`) >
    `.override` (a single resource name, as a string -- skips the whole
    candidate walk) > `.candidates` (walked in order; first one that is
    actually started AND passes verification wins).

    A JUDGMENT CALL made in THIS file, worth being explicit about because
    the contract's own VERIFICATION section is phrased in terms of "after a
    factory returns a table" (which literally only describes the
    override/candidates path, since `custom` never goes through a
    RegisterAdapter'd factory at all): `custom` is ALSO run through the
    exact same required-method verification as override/candidates, rather
    than being accepted unchecked. Reasoning: the whole stated point of this
    engine is "a resource that is running but is an old or renamed version
    must be rejected rather than silently half-working" -- an operator's own
    hand-written `custom` table missing a method is the SAME failure mode,
    and catching it at STARTUP (loud, in the summary and /k9compat) is
    strictly better for a non-technical owner than discovering it only when
    a specific ability silently no-ops in play. If `custom` is set but fails
    verification, this system resolves to the no-op stub -- it does NOT fall
    through to `override`/`candidates` -- for the same reason `override`
    doesn't fall through either: config.lua's own comment says override
    "skips detection entirely and uses THIS one", and `custom` "wins
    outright... over override too". Both read as absolute pins, not soft
    preferences, and a silent fallback to a totally different resource the
    operator never asked for would violate that promise even though it
    might "work". This does NOT change any function signature or the
    resolution order itself, so it was not something siblings needed to be
    consulted on.

    VERIFICATION: after a factory returns a table (or `custom`/`override`
    resolve to one), core checks it exposes every method named in
    `RequiredMethods[system][realm]` for the realm THIS VM is currently
    running as. A missing method -> that candidate is skipped, the exact
    reason is recorded, and (for the `candidates` tier only) detection moves
    on to the next one.

    ======================================================================
    WHY A REALM PARAMETER, GIVEN THIS FILE IS SHARED

    `shared/compat/*.lua` are shared_scripts: the SAME source file is loaded
    into the client Lua VM and the server Lua VM as two entirely separate
    processes with no shared memory. Each VM's copy of this file only ever
    detects its OWN realm (a client can't detect a server-only export, and
    vice versa) -- `REALM` below is computed ONCE, from `IsDuplicityVersion()`
    (verified: ext/native-decls/IsDuplicityVersion.md, HTTP 200,
    `apiset: shared`, "Gets whether or not this is the CitizenFX server" --
    exactly the shared-vs-client-vs-server disambiguation needed here), and
    never changes for the lifetime of that VM.

    A sibling adapter file (e.g. shared/compat/inventory.lua) is ALSO a
    shared script, so it too runs independently on both VMs. It calls
    `K9Compat.RegisterAdapter('inventory', 'ox_inventory', function(realm)
    ... end)` exactly ONCE in its own source, but that ONE registration call
    happens on BOTH VMs (once per VM, since the file loads on both) --
    registering, in effect, "the same factory" into each VM's own,
    independent `K9Compat`. The factory itself receives `realm` as an
    argument specifically so ONE function body, loaded identically on both
    sides, can build a client-shaped table when called from the client VM
    (`factory('client')`) and a server-shaped table when called from the
    server VM (`factory('server')`) -- each VM only ever calls it with its
    OWN fixed realm, so a client VM never accidentally executes
    server-only export access and vice versa, without needing two separate
    files.

    ======================================================================
    NEVER-NIL, NEVER-THROWS, NEVER-A-PER-CALL-LOG

    `K9Compat.Get(system)` always returns a table with a callable method for
    every name in `RequiredMethods[system][REALM]`. Two layers make this
    safe:

    1. THE NO-OP STUB (`BuildNoOpStub` below) -- used when nothing was
       detected at all. Every stubbed method returns `nil` unconditionally
       (this file's own documented "nil/false" choice: `nil`, uniformly,
       for every method regardless of that method's real domain semantics
       -- this file cannot know whether a given inventory/target/framework/
       dispatch/ambulance method's "empty" answer should read as `0`,
       `false`, or `nil` to ITS caller, since that is domain knowledge owned
       by the sibling adapter files, not this generic engine. Every genuine
       call site in this codebase already treats `nil` and `false`
       identically in an `if not x then` guard, so this is safe as a
       universal default). The stub logs its "nothing detected" reason
       EXACTLY ONCE for the lifetime of the current detection result (never
       per call -- a per-call log inside, say, a target predicate evaluated
       every frame would flood the console at 60fps, which this codebase has
       already been burned by with other silent-failure classes).

    2. THE SAFE-ADAPTER WRAPPER (`BuildSafeAdapter` below) -- used when a
       real adapter WAS detected and verified. Every one of its required
       methods is wrapped in `pcall` before being handed to a caller, so a
       throwing, broken, or hostile third-party resource's export can NEVER
       propagate an error into this resource's own call stack (the
       resource-wide, non-negotiable constraint this task was built under).
       A method that throws is caught, logged ONCE per (system, resourceName,
       method) for the life of the current detection result, and returns
       `nil` from then on for that method -- fail closed, not a retry loop.

    Both layers mean every consumer elsewhere in this resource can write
    `K9Compat.Get('inventory').ItemExists(name)` directly, with no
    additional `type(...) == 'function'` guard and no `pcall` of its own --
    the safety is already built into what `Get` hands back.

    ======================================================================
    SECURITY: DETECTION NEVER GRANTS PERMISSION

    Nothing in this file, or reachable through it, performs or influences
    any rank/certification/ownership/XP decision. `K9Compat.Get`/`Which`/
    `Report`/`Redetect` are pure information plumbing: "which resource
    answers this question" and "what does it say". Every actual permission
    check anywhere else in this resource (HasK9Access, IsHighCommand,
    IsEligibleCertifier, ...) is unconditionally server-side and reads
    Config.Departments/the certification tables directly -- NONE of them
    read anything from `K9Compat` or from any detected adapter, so a
    hostile or broken third-party inventory/target/framework/dispatch/
    ambulance script reachable through this file can, at worst, make a
    FEATURE stop working (degrade to the no-op stub above). It cannot make a
    player a K9, mint XP, or bypass a rank -- there is no code path from "an
    adapter method returned X" to any of those outcomes anywhere in this
    resource, and this file adds none.

    The ONE place this file itself makes an authorization decision is the
    `/k9compat` diagnostic command below (it names every script this server
    runs, which is not information for every player) -- gated on
    server/highcommand.lua's `IsHighCommand`, guarded with the same
    `type(fn) == 'function'` check used everywhere else in this codebase for
    a soft cross-file dependency (see server/admin.lua's IsAuthorizedAdmin
    for the identical idiom), and FAILS CLOSED: if `IsHighCommand` is not a
    function for any reason (server/highcommand.lua failed to load,
    Config.Features.HighCommand is off so it always returns false anyway,
    or a future refactor removes it), nobody is authorized -- never
    "everybody is", matching this resource's fail-closed convention for
    every other rank gate.

    ======================================================================
    Config.Features.ResourceAutoDetect VS. Config.Compat.autoDetect

    Two flags exist and this file gives them a deliberately narrow,
    non-overlapping-with-diagnostics meaning: BOTH must be `true` for the
    `candidates` tier (the actual third-party-resource SCANNING) to run.
    Either being off does NOT disable the whole file -- `override` and
    `custom` (the "pin it by hand" mechanisms) still resolve normally,
    matching config.lua's own plain-English comment on
    Config.Features.ResourceAutoDetect: "Set it to `false` only if you want
    to pin every system by hand in Config.Compat below" -- which is a
    description of a still-FUNCTIONING mode, not "everything stops". The
    startup summary print, the `/k9compat` command, and the live-restart
    redetect hook are each independently controlled by their OWN
    Config.Compat key (`logDetectionOnStart`, `diagnosticCommand`,
    `redetectOnResourceRestart`) and are NOT additionally gated on either
    autoDetect flag -- an operator running in "pin it by hand" mode still,
    if anything MORE, wants to see confirmation their pin actually resolved.

    ======================================================================
    FILE-TO-FILE CONTRACT / LOAD ORDER

    - THIS FILE must load BEFORE shared/compat/inventory.lua, target.lua,
      framework.lua, dispatch.lua and ambulance.lua -- a HARD requirement,
      since each of those calls `K9Compat.RegisterAdapter(...)` at its OWN
      file-load time, which needs `K9Compat` to already exist. Required
      fxmanifest.lua placement: `shared_scripts`, immediately after
      `'config.lua'` (this file reads `Config.Compat`/`Config.Features`
      inside functions that only run after at least one tick has passed,
      but `config.lua` must still be loaded first since nothing here waits
      for it beyond that).
    - THIS FILE must load AFTER `config.lua` (reads `Config.Compat`/
      `Config.Features`, defensively type-checked throughout since a
      malformed or missing Config.Compat must degrade to "nothing pinned,
      nothing scanned" rather than error).
    - THIS FILE calls `IsHighCommand` (server/highcommand.lua) ONLY from
      inside the `/k9compat` command handler, at RUN time, behind a
      `type(...) == 'function'` guard -- a genuine soft dependency, no load
      order requirement either way, matching every other such reference in
      this codebase.
    - THIS FILE does not require server/notify.lua, ox_lib, or any other
      resource file to be loaded at all. The diagnostic command's output is
      deliberately plain `print()` (server console, audit trail) plus
      `TriggerClientEvent('chat:addMessage', ...)` (visible to the caller),
      NOT routed through `NotifyPlayer`/`locale()` -- this is a technical,
      multi-line, highly dynamic diagnostic dump (resource names, resource
      states, per-candidate skip reasons), the same category of text this
      resource already treats as plain English rather than localized
      player-facing UX (see server/admin.lua's/server/highcommand.lua's own
      `LogAuditInvocation` console lines for the established precedent).
      This also means this file introduces NO new locales/en.json keys, so
      nothing here needed to go through the locale-file owner.
]]

K9Compat = {}

-- ----------------------------------------------------------------------
-- REALM -- computed once, for the lifetime of this VM. See header for why
-- IsDuplicityVersion() is the right native here (verified against
-- ext/native-decls/IsDuplicityVersion.md: HTTP 200, apiset: shared).
-- ----------------------------------------------------------------------
local REALM = IsDuplicityVersion() and 'server' or 'client'

-- ----------------------------------------------------------------------
-- THE CONTRACT TABLE -- exactly as specified. Every sibling adapter file
-- and every future consumer reads method NAMES from here, never invents
-- its own list.
-- ----------------------------------------------------------------------
K9Compat.RequiredMethods = {
    inventory = {
        client = { 'OpenStash', 'OpenShop', 'UseItem', 'ItemExists' },
        -- 'ItemExists' ADDED: server/equipmentshop.lua's and
        -- server/wellbeing.lua's own onResourceStart item-name sanity
        -- warnings both independently found and documented ("COMPAT-LAYER
        -- FINDING, DELIBERATELY NOT ROUTED") the exact same gap -- this
        -- list had no server-realm ItemExists for them to route through, so
        -- both stayed hardwired to a direct `exports.ox_inventory:Items(...)`
        -- call. See shared/compat/inventory.lua's own header for what every
        -- registered adapter now does with this: ox_inventory answers it
        -- for real (same export the client realm already used); every
        -- other adapter that returns a non-nil server table for a
        -- resource-name it cannot verify a catalog-lookup capability for
        -- must still supply a disclosed, honest placeholder -- never guess
        -- an export name to fill this slot, see that file's own per-adapter
        -- comments.
        server = { 'GetInventoryItems', 'GetContainerFromSlot', 'GetItemCount', 'RemoveItem', 'RegisterStash', 'RegisterShop', 'RegisterHook', 'ItemExists' },
    },
    target = {
        client = { 'AddGlobalPlayer', 'AddGlobalVehicle', 'AddGlobalObject', 'AddModel', 'AddSphereZone', 'Remove', 'AddLocalEntity', 'RemoveLocalEntity' },
        server = {},
    },
    framework = {
        client = { 'GetPlayerData' },
        server = { 'GetPlayer', 'GetPlayerByCitizenId', 'GetCitizenId', 'GetJob' },
    },
    dispatch = {
        server = { 'Alert' },
        client = {},
    },
    ambulance = {
        server = { 'IsDowned' },
        client = {},
    },
}

-- Fixed, deterministic iteration order for reporting -- Lua's `pairs()`
-- order over K9Compat.RequiredMethods is unspecified, and a report whose
-- system order shuffles between runs is needlessly harder to read/diff.
local SYSTEM_ORDER = { 'inventory', 'target', 'framework', 'dispatch', 'ambulance' }
local KNOWN_SYSTEMS = {}
for _, systemName in ipairs(SYSTEM_ORDER) do
    KNOWN_SYSTEMS[systemName] = true
end

-- ----------------------------------------------------------------------
-- LOGGING -- one shared prefix so every line this file ever prints is
-- greppable as a unit, matching this resource's own established
-- `[John-K9] <subsystem>: ...` / `[John-K9] WARNING: ...` convention.
-- ----------------------------------------------------------------------
local function Info(fmt, ...)
    print(('[John-K9] K9Compat: ' .. fmt):format(...))
end

local function Warn(fmt, ...)
    print(('[John-K9] K9Compat: WARNING: ' .. fmt):format(...))
end

-- ----------------------------------------------------------------------
-- STATE -- all private to this file. Nothing here is ever exposed except
-- through the six documented K9Compat.* entry points above.
-- ----------------------------------------------------------------------
local RegisteredFactories = {} -- [system][resourceName] = factory
local DetectionCache = {}      -- [system] = { resourceName = string|nil, adapter = table, tier = string, reason = string }
local SkipLog = {}             -- [system] = { { resourceName = string, reason = string }, ... } -- most recent pass only
local StubWarned = {}          -- [system] = true once the "nothing detected" line has printed for the CURRENT detection result
local MethodWarned = {}        -- ["system.resourceName.methodName"] = true once that method's own throw has been logged

--- @param candidate any
--- @param required string[]
--- @return boolean ok, string[] missing
local function VerifyMethods(candidate, required)
    if type(candidate) ~= 'table' then
        return false, { ('adapter value is not a table (got %s)'):format(type(candidate)) }
    end
    local missing = {}
    for _, methodName in ipairs(required or {}) do
        if type(candidate[methodName]) ~= 'function' then
            missing[#missing + 1] = methodName
        end
    end
    return (#missing == 0), missing
end

--- @param system string
--- @param resourceName string -- may be a synthetic label ('custom', '(candidates)') as well as a real resource name
--- @param reason string
local function RecordSkip(system, resourceName, reason)
    SkipLog[system] = SkipLog[system] or {}
    local list = SkipLog[system]
    list[#list + 1] = { resourceName = resourceName, reason = reason }
end

--- Wraps every required method of an ALREADY-VERIFIED adapter table in
--- pcall, so a throwing/broken third-party export can never propagate into
--- this resource's own call stack (the resource-wide, non-negotiable
--- constraint this file was built under). Logs at most ONCE per
--- (system, resourceName, methodName) for the life of the CURRENT detection
--- result -- never per call, which would flood the console for a hot-path
--- predicate (e.g. a target zone check running every frame).
--- @param system string
--- @param resourceName string
--- @param realTable table -- already verified to expose every name in methodNames as a function
--- @param methodNames string[]
--- @return table safeAdapter
local function BuildSafeAdapter(system, resourceName, realTable, methodNames)
    local safe = {}
    for _, methodName in ipairs(methodNames) do
        local fn = realTable[methodName]
        local warnKey = system .. '.' .. resourceName .. '.' .. methodName
        safe[methodName] = function(...)
            local results = { pcall(fn, ...) }
            if not results[1] then
                if not MethodWarned[warnKey] then
                    MethodWarned[warnKey] = true
                    Warn('%s adapter "%s" method %s errored -- failing closed (returning nil) for this and every future call to it this session. Underlying error: %s',
                        system, resourceName, methodName, tostring(results[2]))
                end
                return nil
            end
            return table.unpack(results, 2)
        end
    end
    return safe
end

--- Builds the NEVER-NIL fallback for `system`: every required method for
--- THIS VM's realm exists and is callable, and every one of them returns
--- `nil` (this file's documented, uniform "nil/false" choice -- see header).
--- The "nothing usable was detected" reason is logged EXACTLY ONCE for the
--- life of the current detection result, not per call.
--- @param system string
--- @param reason string -- human-readable, used only for the one-time log line
--- @return table stub
local function BuildNoOpStub(system, reason)
    local stub = {}
    local required = (K9Compat.RequiredMethods[system] or {})[REALM] or {}
    for _, methodName in ipairs(required) do
        stub[methodName] = function(...)
            if not StubWarned[system] then
                StubWarned[system] = true
                Warn('%s: nothing usable detected (%s). Every %s method returns nil for this session -- see /k9compat (if enabled) for exactly why each candidate was skipped.',
                    system, reason, system)
            end
            return nil
        end
    end
    return stub
end

--- @param system string
--- @param resourceName string
--- @return function|nil
local function ResolveFactory(system, resourceName)
    local bucket = RegisteredFactories[system]
    return bucket and bucket[resourceName]
end

--- Tries ONE named resource for `system`: resolves its registered factory,
--- confirms it is actually started (GetResourceState -- verified:
--- ext/native-decls/GetResourceState.md, HTTP 200, apiset: shared, one of
--- "missing"|"started"|"starting"|"stopped"|"stopping"|"uninitialized"|
--- "unknown" -- only "started" counts as usable, and accessing an export on
--- a resource that is not started can throw rather than return nil, which
--- is exactly why this check runs BEFORE the factory is ever called, same
--- convention as the now-deleted IsOxInventoryHookCapable in server/tracking.lua
--- and its server/inventory.lua twin, both since deleted), calls
--- `factory(REALM)` inside pcall, and
--- verifies the returned table exposes every required method. NEVER
--- throws -- every path that could error from third-party or sibling code
--- (the factory call itself) is pcall-guarded.
--- @param system string
--- @param resourceName string
--- @param required string[]
--- @return table|nil verifiedAdapterTable
local function TryResourceCandidate(system, resourceName, required)
    local factory = ResolveFactory(system, resourceName)
    if not factory then
        RecordSkip(system, resourceName, 'no adapter registered for this resource name (nothing called K9Compat.RegisterAdapter for it)')
        return nil
    end

    local state = GetResourceState(resourceName)
    if state ~= 'started' then
        RecordSkip(system, resourceName, ('resource not started (state=%s)'):format(tostring(state)))
        return nil
    end

    local ok, resultOrErr = pcall(factory, REALM)
    if not ok then
        RecordSkip(system, resourceName, ('adapter factory errored: %s'):format(tostring(resultOrErr)))
        return nil
    end

    if resultOrErr == nil then
        RecordSkip(system, resourceName, 'resource is started, but its own adapter factory reported it unusable for this realm (returned nil)')
        return nil
    end

    local verified, missing = VerifyMethods(resultOrErr, required)
    if not verified then
        RecordSkip(system, resourceName, ('missing required method(s): %s'):format(table.concat(missing, ', ')))
        return nil
    end

    return resultOrErr
end

--- Full detection pass for ONE system. Populates DetectionCache[system] and
--- resets/repopulates SkipLog[system]. NEVER throws.
--- @param system string
local function DetectSystem(system)
    SkipLog[system] = {}
    local required = (K9Compat.RequiredMethods[system] or {})[REALM] or {}

    local sys = type(Config) == 'table' and type(Config.Compat) == 'table'
        and type(Config.Compat.Systems) == 'table' and Config.Compat.Systems[system]
    if type(sys) ~= 'table' then
        Warn('Config.Compat.Systems.%s is missing or malformed -- treating this system as fully unconfigured (no custom, no override, no candidates).', system)
        sys = {}
    end

    -- TIER 0: custom -- wins outright, even over override. See header for
    -- why this file verifies it rather than accepting it unchecked.
    if type(sys.custom) == 'table' then
        local verified, missing = VerifyMethods(sys.custom, required)
        if verified then
            DetectionCache[system] = {
                resourceName = 'custom',
                adapter = BuildSafeAdapter(system, 'custom', sys.custom, required),
                reason = ('operator-provided custom table (Config.Compat.Systems.%s.custom)'):format(system),
            }
            return
        end
        RecordSkip(system, 'custom', ('Config.Compat.Systems.%s.custom is missing required method(s): %s'):format(system, table.concat(missing, ', ')))
        DetectionCache[system] = {
            resourceName = nil,
            adapter = BuildNoOpStub(system, 'a custom table is set but is missing required method(s) -- see /k9compat'),
            reason = 'custom table set but failed verification -- does not fall through to override/candidates (custom is an absolute pin, see this file\'s header)',
        }
        return
    end

    -- TIER 1: override -- a single named resource, skips the candidate walk
    -- entirely (does not fall through to candidates on failure either --
    -- same "absolute pin" reasoning as custom above).
    if type(sys.override) == 'string' and sys.override ~= '' then
        local verifiedTable = TryResourceCandidate(system, sys.override, required)
        if verifiedTable then
            DetectionCache[system] = {
                resourceName = sys.override,
                adapter = BuildSafeAdapter(system, sys.override, verifiedTable, required),
                reason = ('override (Config.Compat.Systems.%s.override = "%s")'):format(system, sys.override),
            }
            return
        end
        DetectionCache[system] = {
            resourceName = nil,
            adapter = BuildNoOpStub(system, ('override "%s" is set but unusable -- see /k9compat'):format(sys.override)),
            reason = ('override "%s" set but unusable -- overrides do not fall through to candidates by design'):format(sys.override),
        }
        return
    end

    -- TIER 2: candidates, walked in order -- only when auto-detection is on
    -- at BOTH the top-level feature switch and this block's own nested
    -- switch (see header for why these are two independent, narrow gates).
    local autoDetectEnabled =
        type(Config) == 'table' and type(Config.Features) == 'table' and Config.Features.ResourceAutoDetect == true
        and type(Config.Compat) == 'table' and Config.Compat.autoDetect == true

    if not autoDetectEnabled then
        RecordSkip(system, '(candidates)', 'auto-detection is off (Config.Features.ResourceAutoDetect and/or Config.Compat.autoDetect is not true) -- candidates were not scanned; set override or custom to pin this system by hand')
    elseif type(sys.candidates) == 'table' then
        for _, resourceName in ipairs(sys.candidates) do
            local verifiedTable = TryResourceCandidate(system, resourceName, required)
            if verifiedTable then
                DetectionCache[system] = {
                    resourceName = resourceName,
                    adapter = BuildSafeAdapter(system, resourceName, verifiedTable, required),
                    reason = ('auto-detected candidate "%s"'):format(resourceName),
                }
                return
            end
        end
    end

    DetectionCache[system] = {
        resourceName = nil,
        adapter = BuildNoOpStub(system, 'nothing usable detected'),
        reason = 'nothing usable detected -- see /k9compat (if enabled) for why each candidate was skipped',
    }
end

-- ----------------------------------------------------------------------
-- PUBLIC CONTRACT
-- ----------------------------------------------------------------------

--- @param system string -- one of the keys in K9Compat.RequiredMethods
--- @param resourceName string
--- @param factory fun(realm: string): table|nil
--- @return boolean registered
function K9Compat.RegisterAdapter(system, resourceName, factory)
    if not KNOWN_SYSTEMS[system] then
        Warn('RegisterAdapter called for unknown system "%s" -- ignored. Known systems: %s.', tostring(system), table.concat(SYSTEM_ORDER, ', '))
        return false
    end
    if type(resourceName) ~= 'string' or resourceName == '' then
        Warn('RegisterAdapter(%s, ...) called with an invalid resourceName (%s) -- ignored.', system, tostring(resourceName))
        return false
    end
    if type(factory) ~= 'function' then
        Warn('RegisterAdapter(%s, %s, ...) called with a non-function factory (got %s) -- ignored.', system, resourceName, type(factory))
        return false
    end

    RegisteredFactories[system] = RegisteredFactories[system] or {}
    if RegisteredFactories[system][resourceName] then
        Warn('RegisterAdapter(%s, %s, ...) overwrites a previously registered adapter for the same resource name -- last registration wins.', system, resourceName)
    end
    RegisteredFactories[system][resourceName] = factory
    return true
end

--- NEVER nil. Detects lazily on first call for a given system (so a system
--- nothing has asked about yet costs nothing), cached afterward until the
--- next K9Compat.Redetect().
--- @param system string
--- @return table adapter
function K9Compat.Get(system)
    if not KNOWN_SYSTEMS[system] then
        Warn('Get(%s) called for an unknown system -- returning an empty table. Known systems: %s.', tostring(system), table.concat(SYSTEM_ORDER, ', '))
        return {}
    end
    if DetectionCache[system] == nil then
        DetectSystem(system)
    end
    return DetectionCache[system].adapter
end

--- @param system string
--- @return string|nil resourceName, string reason
function K9Compat.Which(system)
    if not KNOWN_SYSTEMS[system] then
        return nil, 'unknown system: ' .. tostring(system)
    end
    if DetectionCache[system] == nil then
        DetectSystem(system)
    end
    local entry = DetectionCache[system]
    return entry.resourceName, entry.reason
end

--- @return string multiLineSummary
function K9Compat.Report()
    local lines = { ('K9Compat detection summary (realm=%s):'):format(REALM) }
    for _, system in ipairs(SYSTEM_ORDER) do
        if DetectionCache[system] == nil then
            DetectSystem(system)
        end
        local entry = DetectionCache[system]
        if entry.resourceName then
            lines[#lines + 1] = ('  %-10s -> %-20s (%s)'):format(system, entry.resourceName, entry.reason)
        else
            lines[#lines + 1] = ('  %-10s -> NOT FOUND -- no-op stub in use (%s)'):format(system, entry.reason)
        end
    end
    return table.concat(lines, '\n')
end

--- Re-runs detection for every known system, discarding all cached results
--- and skip logs. Never throws. Clears the "warned once" markers too, so a
--- resource that genuinely changed state (fixed and restarted, or newly
--- stopped) gets a fresh diagnostic rather than staying silently suppressed
--- on stale state -- Redetect() only runs on human-scale events (this
--- resource's own startup, or another resource starting/stopping), never
--- per-tick, so this is not a flood risk.
--- @return nil
function K9Compat.Redetect()
    for _, system in ipairs(SYSTEM_ORDER) do
        DetectSystem(system)
    end
    for _, system in ipairs(SYSTEM_ORDER) do
        StubWarned[system] = nil
    end
    for key in pairs(MethodWarned) do
        MethodWarned[key] = nil
    end
    return nil
end

-- ======================================================================
-- STARTUP DETECTION (with grace window) + LIVE REDETECTION ON RESOURCE
-- START/STOP + THE /k9compat DIAGNOSTIC COMMAND
-- ======================================================================

--- Runs once, Config.Compat.startupGraceMs after THIS resource starts.
--- Resource start order across a server is NOT guaranteed, so detecting at
--- t=0 is a coin flip on a busy server -- this delay exists specifically so
--- candidates that are merely slow to start (not missing) still get found.
local function ScheduleInitialDetection()
    CreateThread(function()
        local graceMs = type(Config) == 'table' and type(Config.Compat) == 'table' and Config.Compat.startupGraceMs
        if type(graceMs) ~= 'number' or graceMs ~= graceMs or graceMs < 0 then
            if graceMs ~= nil then
                Warn('Config.Compat.startupGraceMs (%s) is not a valid non-negative number -- detecting immediately instead of waiting out a grace window. This risks a false "not found" for a candidate that is merely slow to start; fix startupGraceMs to silence this.', tostring(graceMs))
            end
            graceMs = 0
        end
        if graceMs > 0 then Wait(graceMs) end

        K9Compat.Redetect()

        local logOn = type(Config) == 'table' and type(Config.Compat) == 'table' and Config.Compat.logDetectionOnStart == true
        if logOn then
            print(K9Compat.Report())
        end
    end)
end

--- Re-runs detection when ANOTHER resource starts or stops, if
--- Config.Compat.redetectOnResourceRestart is true -- so `restart
--- ox_inventory` (or swapping which inventory a server runs) is picked up
--- live, without a full john-k9 restart. Self-start/stop is explicitly
--- excluded here (the initial grace-window pass above owns that) so this
--- resource's own boot never runs detection twice back to back for no
--- reason.
--- @param resourceName string
local function MaybeLiveRedetect(resourceName)
    if resourceName == GetCurrentResourceName() then return end

    local hookOn = type(Config) == 'table' and type(Config.Compat) == 'table' and Config.Compat.redetectOnResourceRestart == true
    if not hookOn then return end

    local before = {}
    for _, system in ipairs(SYSTEM_ORDER) do
        before[system] = DetectionCache[system] and DetectionCache[system].resourceName
    end

    K9Compat.Redetect()

    local changed = false
    for _, system in ipairs(SYSTEM_ORDER) do
        if before[system] ~= DetectionCache[system].resourceName then
            changed = true
            break
        end
    end

    if changed then
        local logOn = type(Config) == 'table' and type(Config.Compat) == 'table' and Config.Compat.logDetectionOnStart == true
        if logOn then
            Info('re-ran detection after "%s" changed state -- new result:', resourceName)
            print(K9Compat.Report())
        end
    end
end

if REALM == 'server' then
    AddEventHandler('onResourceStart', function(resourceName)
        if resourceName == GetCurrentResourceName() then
            ScheduleInitialDetection()
        else
            MaybeLiveRedetect(resourceName)
        end
    end)
    AddEventHandler('onResourceStop', MaybeLiveRedetect)
else
    AddEventHandler('onClientResourceStart', function(resourceName)
        if resourceName == GetCurrentResourceName() then
            ScheduleInitialDetection()
        else
            MaybeLiveRedetect(resourceName)
        end
    end)
    AddEventHandler('onClientResourceStop', MaybeLiveRedetect)
end

-- ----------------------------------------------------------------------
-- /k9compat -- SERVER ONLY. Names every script this server runs, which is
-- not information for every player, so this is gated to High Command --
-- see header SECURITY section for the exact fail-closed contract.
-- ----------------------------------------------------------------------
if REALM == 'server' then
    AddEventHandler('onResourceStart', function(resourceName)
        if GetCurrentResourceName() ~= resourceName then return end

        local cmdName = type(Config) == 'table' and type(Config.Compat) == 'table' and Config.Compat.diagnosticCommand
        if cmdName == false then
            Info('Config.Compat.diagnosticCommand is false -- no diagnostic command registered, by config.')
            return
        end
        if type(cmdName) ~= 'string' or cmdName == '' then
            Warn('Config.Compat.diagnosticCommand (%s) is neither a valid command-name string nor exactly `false` -- not registering a diagnostic command this session. Set it to a string (e.g. "k9compat") or to `false`.', tostring(cmdName))
            return
        end

        RegisterCommand(cmdName, function(source, _args)
            -- FAILS CLOSED: if IsHighCommand is not a function for any
            -- reason (server/highcommand.lua absent, or a future refactor),
            -- nobody is authorized -- never "everybody is". Same idiom as
            -- server/admin.lua's IsAuthorizedAdmin high-command bypass.
            local authorized = type(IsHighCommand) == 'function' and IsHighCommand(source) == true

            if not authorized then
                Info('DENIED: source=%s ran /%s without High Command rank.', tostring(source), cmdName)
                if type(source) == 'number' and source > 0 then
                    TriggerClientEvent('chat:addMessage', source, { args = { '[K9Compat]', 'You are not authorized to run this command.' } })
                end
                return
            end

            Info('source=%s (High Command) ran /%s.', tostring(source), cmdName)

            local reportLines = {}
            for line in (K9Compat.Report() .. '\n'):gmatch('([^\n]*)\n') do
                reportLines[#reportLines + 1] = line
            end
            for _, system in ipairs(SYSTEM_ORDER) do
                local skips = SkipLog[system]
                if skips and #skips > 0 then
                    reportLines[#reportLines + 1] = ('-- %s: skipped candidates --'):format(system)
                    for _, skip in ipairs(skips) do
                        reportLines[#reportLines + 1] = ('   %s: %s'):format(tostring(skip.resourceName), skip.reason)
                    end
                end
            end

            if type(source) == 'number' and source > 0 then
                for _, line in ipairs(reportLines) do
                    TriggerClientEvent('chat:addMessage', source, { args = { '[K9Compat]', line } })
                end
            else
                -- Console invocation: IsHighCommand(0) always resolves
                -- false (no resolvable qbx_core player for source 0), so
                -- this branch is unreachable via the console today -- kept
                -- anyway as the correct, fail-safe behavior if that ever
                -- changes, rather than assuming source is always a player.
                for _, line in ipairs(reportLines) do
                    print(('[John-K9] K9Compat: %s'):format(line))
                end
            end
        end, false)

        Info('diagnostic command /%s registered (High Command only).', cmdName)
    end)
end
