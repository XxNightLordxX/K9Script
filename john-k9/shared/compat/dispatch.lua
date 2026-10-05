--[[
    john-k9/shared/compat/dispatch.lua

    K9Compat 'dispatch' adapters. Read shared/compat/core.lua's header AND
    DEVELOPER_REFERENCE.md §21 FIRST -- this file only implements the
    per-resource `factory(realm) -> table | nil` bodies core.lua's generic
    engine calls; it invents no new contract of its own.

    ======================================================================
    THIS FILE DOES NOT REPLACE THE EXISTING OUTBOUND EVENT -- IT IS PURELY
    ADDITIVE. Read server/integrations.lua's header in full before touching
    this file; it argues at length for why 'john-k9:events:k9Down' (a
    plain TriggerEvent on a stable namespace, ZERO config surface) is the
    PRIMARY dispatch integration path, and why a per-hook
    `{ event = ..., export = ..., enabled = bool }` config shape was
    considered and DELIBERATELY REJECTED: it would mean this resource
    calling into exactly one named third-party resource, which is the
    single-integration assumption the whole task exists to forbid, and it
    would give an operator a new place to typo a name a listener written
    straight from the docs would silently stop matching.

    Nothing in this file undoes that decision. A fully custom dispatch that
    writes one `AddEventHandler('john-k9:events:k9Down', ...)` continues
    to need ZERO setup and ZERO knowledge that this file exists. What this
    file adds is a CONVENIENCE layer on top: if a caller ALSO asks
    `K9Compat.Get('dispatch').Alert(payload)` (in addition to, never
    instead of, firing the existing event), and this resource's own
    detection engine found a supported off-the-shelf dispatch actually
    running, that dispatch's own native alert board lights up too, with no
    setup on the operator's part beyond running a supported dispatch.
    BOTH fire. Neither path knows about the other, and removing this file
    entirely would leave the existing event working exactly as it does
    today -- that is the definition of "purely additive."

    WHO ACTUALLY CALLS `K9Compat.Get('dispatch').Alert(...)`: server/
    integrations.lua's PollK9Health -- placed immediately AFTER (never
    instead of) the existing `FireOutboundEvent('john-k9:events:k9Down',
    ...)` call, guarded the same `type(K9Compat) == 'table' and
    type(K9Compat.Get) == 'function'` way every other caller guards its
    own K9Compat.Get('framework') call, so both fire from the exact same
    detection episode and a missing K9Compat degrades to "the convenience
    layer did nothing," never a thrown error. `title` there is a plain
    string, not `locale(...)` (see LOCALE NOTE below -- server/
    integrations.lua is not the locale-file owner). This file does not
    perform that wiring itself; it only guarantees the
    other end (`Alert`) is ready and safe to call the moment someone does.

    ======================================================================
    THE NORMALISED `Alert(payload)` CONTRACT (this file's own design --
    core.lua and DEVELOPER_REFERENCE.md §21 deliberately leave "parameter
    shapes and return values for each method" to the adapter file that owns
    that system, see README.md's own "Parameter shapes..." paragraph).

    `payload` is a plain table. Every field below is read defensively
    (wrong type / missing -> a safe default, never a thrown error) by
    `NormalizeAlertPayload` below, so a caller that gets one field wrong
    degrades a single alert's presentation rather than erroring across the
    resource boundary. Required-in-spirit fields (documented as
    "at minimum" by the task this file was built under) are `code`,
    `title`, `message`, `coords`, `jobs`, `priority`:

        code     (string)  Short, stable, machine-oriented identifier for
                            the KIND of alert, e.g. 'k9_down'. Snake_case,
                            matching this resource's own event-name style.
                            Used as the third-party dispatch's "code name" /
                            mute-and-pin match key where that dispatch
                            supports one; purely cosmetic where it doesn't.
        code10   (string?) OPTIONAL. A human radio-code badge, e.g.
                            '10-99', distinct from `code` above (`code` is
                            for machines to match on and must never change
                            once alerts using it exist anywhere; `code10` is
                            for a human dispatcher's eyes and can be tuned
                            freely). Adapters that show a radio-code badge
                            fall back to `code` itself when this is absent.
        title    (string)  Short headline -- "what happened", one line.
        message  (string)  Longer free-text detail shown under the
                            headline. May be empty; must never be nil to a
                            caller inside this file (NormalizeAlertPayload
                            guarantees this).
        coords   (vector3) Where it happened. A payload with no valid
                            coords is REJECTED by every adapter below
                            (`Alert` returns `false`, nothing is sent) --
                            unlike this resource's other outbound facts, a
                            dispatch alert with no map location is not
                            useful to anyone receiving it (mirrors
                            server/integrations.lua's own header reasoning
                            for why ITS k9Down payload carries coords when
                            none of this resource's other outbound events
                            do).
        jobs     (string[]) Which job names should receive this. Same
                            vocabulary as `Config.Departments` keys (e.g.
                            `{ 'police', 'sheriff' }`) -- this file performs
                            no job-name validation of its own beyond "is it
                            a table of non-empty strings"; a job name a
                            given third-party dispatch doesn't recognise is
                            that dispatch's own concern; not this file's.
        priority (number)  0..3, INTEGER. THIS FILE'S OWN NORMALISED SCALE
                            -- see PRIORITY SCALE below for exactly why 0
                            means "most severe" and where this scale comes
                            from. Any other value (missing, NaN, a string,
                            out of range) is clamped/defaulted by
                            `NormalizePriority` below, never rejected.

    RETURN VALUE: every `Alert` below returns a plain `boolean` -- `true`
    only when this adapter actually attempted delivery to a `'started'`
    underlying resource via a real, confirmed integration point (see
    CONFIRMED VS. UNCONFIRMED below); `false` for an invalid payload
    (no usable coords), a resource that is not `'started'` at the moment of
    the call (a live race against a resource stopping mid-session, see
    RACE WINDOW below), an export/event dispatch that itself threw, or an
    UNCONFIRMED adapter (documented below) that intentionally never sends
    anything. `false` is purely informational for a caller that wants to
    know whether the convenience path fired -- it is NEVER an error the
    caller must handle, and the primary `TriggerEvent('john-k9:events:
    k9Down', ...)` path this file does not touch is entirely unaffected
    either way.

    PRIORITY SCALE -- 0 = critical, 1 = urgent, 2 = routine, 3 = low. This
    is not invented here: it is ps-dispatch's OWN documented scale
    (CONFIRMED -- see that adapter's own citation below), adopted as this
    file's normalised scale specifically because it is the one scale this
    research pass could confirm against a primary source at all, and
    because "0 = most severe" is the more common convention across the
    dispatch resources this file DID get to read source for (a lower number
    reads as "answer this first," matching how a real radio priority
    queue works). Every other adapter below translates INTO this scale from
    whatever its own real resource actually expects (documented per adapter
    where that translation is not a straight pass-through).

    ======================================================================
    RESEARCH METHODOLOGY AND HONEST CONFIDENCE GRADING. A guessed signature
    that detects as working and then silently does nothing is this
    project's most expensive recurring bug class, so every adapter below is
    graded CONFIRMED or UNCONFIRMED against a real primary source, never
    assumed from memory.

    Every CONFIRMED adapter below cites the exact primary source read this
    session (a resource's own README.md, fxmanifest.lua, or real .lua
    source file, fetched directly from that resource's own public GitHub
    repository -- never a memory of "resources like this usually...").
    Every UNCONFIRMED adapter is REGISTERED ANYWAY (never simply omitted)
    with a factory that unconditionally returns `nil` for every realm --
    per core.lua's own contract, `nil` means "this resource is present but
    this factory judges it unusable for this realm -- skip me, try the
    next candidate," which is EXACTLY the right signal for "I could not
    confirm a real integration point for this resource, so I am not
    guessing one." Registering it anyway (rather than leaving the name
    completely unregistered) matters for two concrete reasons:
      1. `/k9compat` (shared/compat/core.lua's diagnostic command) reports
         a SPECIFIC, actionable reason ("resource is started, but its own
         adapter factory reported it unusable for this realm") rather than
         the much less useful "no adapter registered for this resource name
         (nothing called K9Compat.RegisterAdapter for it)" a server owner
         running one of these would otherwise see.
      2. It leaves a single, obvious anchor in this file's own source for
         whoever next confirms that resource's real API to fill in --
         `Ctrl+F` the resource name, replace the stub body, done -- rather
         than requiring them to first notice the resource is entirely
         unhandled and add a whole new registration from scratch.

    Per-resource verdicts, in `Config.Compat.Systems.dispatch.candidates`
    order:

      ps-dispatch (CONFIRMED). Primary source:
      https://raw.githubusercontent.com/Project-Sloth/ps-dispatch/main/README.md
      (fetched this session; repo confirmed live via a real fxmanifest.lua
      fetch at the same URL root). Documents `exports['ps-dispatch']:
      CustomAlert({ message, information, codeName, code, priority, coords,
      jobs, ... })` verbatim, including the 0/1/2/3 priority scale this
      file's own normalised scale mirrors, and independently confirmed by
      three unrelated CFX community-forum threads (forum.cfx.re topics
      5227452, 5162211, 5247409) all linking the same repository for the
      same resource name.

      cd_dispatch (UNCONFIRMED). Searched: raw.githubusercontent.com under
      a wide set of plausible GitHub org names (candoo, Chad-Devs,
      Renewed-Scripts, CD-Team, and others) -- no fxmanifest.lua or
      README.md resolved under any of them. Searched forum.cfx.re
      (dozens of threads mentioning "cd_dispatch") for an outbound link to
      its own source -- every thread that does link a GitHub repository
      links to something else entirely (ox_lib, an unrelated NPC-robbery
      script); not one cd_dispatch thread found this session links its own
      source. This is consistent with cd_dispatch being closed-source
      (Tebex/Discord-distributed, as many popular FiveM dispatch resources
      are) rather than merely hard to find -- but that is an inference, not
      a confirmation, which is exactly why this stays UNCONFIRMED rather
      than being guessed from "dispatch resources of this era usually
      expose an AddCall-shaped export."

      qs-dispatch (UNCONFIRMED). Same search pattern as cd_dispatch (wide
      GitHub org guesses against raw.githubusercontent.com, plus
      forum.cfx.re full-text search across 40+ threads mentioning the exact
      string "qs-dispatch") -- no primary source located.

      rcore_dispatch (UNCONFIRMED). Same search pattern -- no primary
      source located.

      core_dispatch (UNCONFIRMED). Same search pattern -- no primary
      source located. (Not to be confused with `core_dispatch`-adjacent hits
      for an unrelated "gcphone" integration thread found during this
      search, which names the resource but never its source.)

      linden_outlawalert (CONFIRMED). Primary source:
      https://raw.githubusercontent.com/thelindat/linden_outlawalert/main/{fxmanifest.lua,server.lua}
      (fetched this session; repo identity independently cross-confirmed by
      forum.cfx.re topic 4790888, an unrelated thread that links this exact
      repository for this exact resource name). IMPORTANT, EXACTLY THE
      "guessed signature" TRAP THIS RESEARCH REQUIREMENT EXISTS TO CATCH:
      this resource's real custom-alert entry point is
      `RegisterServerEvent('wf-alerts:svNotify')` -- an event namespaced
      `wf-alerts:*`, NOT `linden_outlawalert:*`. A signature guessed from
      the resource's own name alone (a very reasonable-sounding guess) would
      have been wrong and would have detected as "present" while silently
      never delivering a single alert. See the adapter body below for the
      exact payload shape read directly from that file's own commented
      `TestAlert`-equivalent example and its real `AddEventHandler` body.
    ======================================================================

    RACE WINDOW (documented once here, applies to every adapter below):
    core.lua's own detection pass confirms `GetResourceState(name) ==
    'started'` ONCE, before ever calling a factory -- but `Alert` itself can
    be called an arbitrary amount of time later (this resource's own
    Config.Compat.redetectOnResourceRestart default is `true`, so a
    same-session `restart <dispatch>` is normally caught quickly, but is
    not instantaneous). Every adapter below therefore ALSO re-checks
    `GetResourceState` for itself at the moment `Alert` actually runs,
    before touching that resource's export/event surface at all --
    defense-in-depth, not a substitute for core.lua's own check, matching
    this codebase's established "never trust a single layer" posture
    (the now-deleted IsOxInventoryHookCapable in server/tracking.lua kept an identical
    belt-and-suspenders GetResourceState check even though its own caller
    was ALSO gated elsewhere; shared/compat/target.lua's IsExportCapable
    carries that posture forward today). Every export access AND call below goes
    through its own `pcall`, matching server/tracking.lua:772-810's
    two-step shape exactly: `GetResourceState` first (unconditional
    "unavailable" if not `'started'`), then a `pcall`'d INDEX of the export
    (existence check only, never a call), then a SEPARATE `pcall`'d CALL.
    core.lua's own `BuildSafeAdapter` additionally wraps this file's entire
    `Alert` function in one more outer `pcall` -- so a throw here is caught
    twice over, not once.

    ======================================================================
    SECURITY: `Alert` NEVER GRANTS PERMISSION. It is a fire-and-forget
    notification to a third-party UI board; nothing anywhere in this file
    reads the result of an `Alert` call to decide whether an action is
    allowed, and nothing in this resource's own rank/certification/XP code
    reads anything from `K9Compat` at all (see core.lua's own SECURITY
    section for the resource-wide version of this guarantee). The worst a
    hostile or broken third-party dispatch can do through this file is make
    a single alert not show up on someone's board -- never grant, deny, or
    influence any permission decision.

    LOCALE NOTE: this file deliberately never calls `locale()` itself.
    `title`/`message` arrive already-resolved from whoever builds the
    `payload` (see the copy-paste call sketch above, which resolves a
    locale key BEFORE calling `Alert`) -- the same "this file doesn't own
    that call site's locale keys" boundary core.lua's own header draws for
    its diagnostic-command text.
]]

-- ----------------------------------------------------------------------
-- Shared normalisation helpers -- private to this file. Every adapter
-- below calls `NormalizeAlertPayload` exactly once, at the top of its own
-- `Alert`, so no adapter body repeats its own nil/type-checking.
-- ----------------------------------------------------------------------

--- @param value any
--- @param fallback string?
--- @return string?
local function SafeString(value, fallback)
    if type(value) == 'string' and value ~= '' then return value end
    return fallback
end

--- @param value any
--- @return string[]
local function SafeJobs(value)
    local out = {}
    if type(value) ~= 'table' then return out end
    for _, jobName in ipairs(value) do
        if type(jobName) == 'string' and jobName ~= '' then
            out[#out + 1] = jobName
        end
    end
    return out
end

--- Accepts either a real CFX vector3 (type() genuinely reports the string
--- 'vector3' for one -- this is not a guess, it is this resource's own
--- already-established idiom, see this resource's own identical
--- `type(coords) ~= 'table' and type(coords) ~= 'vector3'` check) or a
--- plain `{ x = , y = , z = }` table, for a caller that built one by hand
--- rather than via the `vector3(...)` constructor. Anything else -> nil.
--- @param value any
--- @return vector3|table|nil
local function SafeCoords(value)
    if type(value) == 'vector3' then return value end
    if type(value) == 'table'
        and type(value.x) == 'number' and value.x == value.x
        and type(value.y) == 'number' and value.y == value.y
        and type(value.z) == 'number' and value.z == value.z
    then
        return value
    end
    return nil
end

--- Clamps to this file's own normalised 0..3 integer scale (see header
--- PRIORITY SCALE). Anything unusable defaults to 2 ("routine") -- the
--- middle of the scale, deliberately neither the most nor least urgent
--- default, for a caller that omits priority entirely.
--- @param value any
--- @return integer
local function NormalizePriority(value)
    if type(value) ~= 'number' or value ~= value then return 2 end
    if value < 0 then return 0 end
    if value > 3 then return 3 end
    return math.floor(value)
end

--- @param payload any
--- @return table normalized
local function NormalizeAlertPayload(payload)
    if type(payload) ~= 'table' then payload = {} end
    return {
        code     = SafeString(payload.code, 'k9_alert'),
        code10   = SafeString(payload.code10, nil),
        title    = SafeString(payload.title, 'K9 Unit Alert'),
        message  = SafeString(payload.message, '') or '',
        coords   = SafeCoords(payload.coords),
        jobs     = SafeJobs(payload.jobs),
        priority = NormalizePriority(payload.priority),
    }
end

-- ======================================================================
-- sc-dispatch -- CONFIRMED, written against the resource's own source
-- (sc-dispatch 3.0.0, server/main.lua): a SERVER export
-- `AddNotification(data)` that this server's own scripts already call.
-- It reads data.job_table (job names; any police job reaches every police
-- department), data.title (stored as the call type, VARCHAR(50)),
-- data.message, data.coords ({x,y,z} or vector3), data.street,
-- data.caller, data.priority (1 = top, 2 = normal, 3 = low -- its UI
-- styles exactly those three), data.flash and data.blip
-- ({ sprite, scale, colour, flashes, text }; every field optional). It
-- returns the new call's id, or nil when no department matched.
-- sc-dispatch also ships its own "ps-dispatch" bridge resource; this
-- adapter talks to sc-dispatch directly, so that bridge is not needed.
-- ======================================================================
K9Compat.RegisterAdapter('dispatch', 'sc-dispatch', function(realm)
    if realm ~= 'server' then return nil end

    return {
        --- @param payload table -- see this file's header for the shape
        --- @return boolean sent
        Alert = function(payload)
            local n = NormalizeAlertPayload(payload)
            if not n.coords then return false end

            if GetResourceState('sc-dispatch') ~= 'started' then return false end

            local indexOk, addNotificationExport = pcall(function()
                return exports['sc-dispatch'].AddNotification
            end)
            if not indexOk or type(addNotificationExport) ~= 'function' then return false end

            -- This file's 0..3 scale (0 = critical) onto sc-dispatch's
            -- 1..3 (1 = top): critical and urgent are both its top tier.
            local priority = (n.priority <= 1) and 1 or n.priority
            local title = n.code10 and (n.code10 .. ' ' .. n.title) or n.title
            local jobs = (#n.jobs > 0) and n.jobs or { 'police' }

            local callOk, callId = pcall(function()
                return exports['sc-dispatch']:AddNotification({
                    job_table = jobs,
                    title     = title:sub(1, 50),
                    message   = n.message,
                    coords    = { x = n.coords.x, y = n.coords.y, z = n.coords.z },
                    street    = '',
                    caller    = 'K9 Unit (automated)',
                    priority  = priority,
                    flash     = (priority == 1) and 1 or 0,
                    blip      = { text = n.title, flashes = priority == 1 },
                })
            end)
            return callOk == true and callId ~= nil
        end,
    }
end)

-- ======================================================================
-- ps-dispatch -- CONFIRMED. See header for the exact source cited.
-- ======================================================================
K9Compat.RegisterAdapter('dispatch', 'ps-dispatch', function(realm)
    -- dispatch.client requires nothing (K9Compat.RequiredMethods.dispatch.
    -- client == {}) and this adapter has nothing useful to offer the
    -- client VM anyway (CustomAlert is a server-side export) -- `nil` is
    -- the honest answer for that realm, not a guess dressed as one.
    if realm ~= 'server' then return nil end

    return {
        --- @param payload table -- see this file's header for the shape
        --- @return boolean sent
        Alert = function(payload)
            local n = NormalizeAlertPayload(payload)
            if not n.coords then return false end

            if GetResourceState('ps-dispatch') ~= 'started' then return false end

            -- Two-step shape (index, then call), each its own pcall --
            -- see header RACE WINDOW.
            local indexOk, customAlertExport = pcall(function()
                return exports['ps-dispatch'].CustomAlert
            end)
            if not indexOk or type(customAlertExport) ~= 'function' then return false end

            -- README-confirmed field names: message (headline), information
            -- (free text under the header), codeName (mute/pin match key),
            -- code (radio-code badge), priority (this file's own scale,
            -- IDENTICAL to ps-dispatch's own -- no translation needed),
            -- coords, jobs.
            local callOk = pcall(function()
                exports['ps-dispatch']:CustomAlert({
                    message     = n.title,
                    information = n.message ~= '' and n.message or nil,
                    codeName    = n.code,
                    code        = n.code10,
                    priority    = n.priority,
                    coords      = n.coords,
                    jobs        = n.jobs,
                })
            end)
            return callOk == true
        end,
    }
end)

-- ======================================================================
-- cd_dispatch -- UNCONFIRMED. See header RESEARCH METHODOLOGY for the
-- search actually performed. Registered so /k9compat gives a specific,
-- actionable skip reason instead of "no adapter registered at all," and so
-- whoever next confirms this resource's real integration point has a
-- single obvious anchor to fill in. DO NOT replace this `nil` with a
-- guessed export/event name -- see this file's header for exactly why a
-- guessed signature is worse than no adapter at all (it detects as
-- working, then silently sends nothing).
-- ======================================================================
K9Compat.RegisterAdapter('dispatch', 'cd_dispatch', function(_realm)
    return nil
end)

-- ======================================================================
-- qs-dispatch -- UNCONFIRMED. Same reasoning and same instruction as
-- cd_dispatch immediately above.
-- ======================================================================
K9Compat.RegisterAdapter('dispatch', 'qs-dispatch', function(_realm)
    return nil
end)

-- ======================================================================
-- rcore_dispatch -- UNCONFIRMED. Same reasoning and same instruction as
-- cd_dispatch above.
-- ======================================================================
K9Compat.RegisterAdapter('dispatch', 'rcore_dispatch', function(_realm)
    return nil
end)

-- ======================================================================
-- core_dispatch -- UNCONFIRMED. Same reasoning and same instruction as
-- cd_dispatch above.
-- ======================================================================
K9Compat.RegisterAdapter('dispatch', 'core_dispatch', function(_realm)
    return nil
end)

-- ======================================================================
-- linden_outlawalert -- CONFIRMED. See header for the exact source cited
-- and the "wf-alerts:*, NOT linden_outlawalert:*" finding -- read that
-- before assuming a different event name would also work.
-- ======================================================================
K9Compat.RegisterAdapter('dispatch', 'linden_outlawalert', function(realm)
    if realm ~= 'server' then return nil end

    return {
        --- @param payload table -- see this file's header for the shape
        --- @return boolean sent
        Alert = function(payload)
            local n = NormalizeAlertPayload(payload)
            if not n.coords then return false end

            if GetResourceState('linden_outlawalert') ~= 'started' then return false end

            -- EVENT-DRIVEN, not export-driven (see header CONFIRMED note).
            -- server.lua's own `AddEventHandler('wf-alerts:svNotify', ...)`
            -- reads `pData.dispatchData` (a custom-alert table: displayCode/
            -- description/isImportant/recipientList/info, all confirmed
            -- against that file's own commented TestAlert example and its
            -- handler body) plus top-level `pData.caller` / `pData.coords`.
            --
            -- isImportant TRANSLATION (this file's own judgment call, not
            -- something linden_outlawalert documents as a scale): the
            -- source only ever sets `isImportant = 1` for its own
            -- hardcoded 'officerdown' preset among six presets shown, and
            -- 0 for every other -- read as a genuine two-tier signal, not a
            -- 0..3 scale. This file maps its own 0/1 (critical/urgent) down
            -- to isImportant=1, and its own 2/3 (routine/low) down to
            -- isImportant=0, so a K9-down alert (priority 0 in the
            -- copy-paste call sketch in this file's header) reads as
            -- important here exactly the way 'officerdown' already does in
            -- linden_outlawalert's own preset table.
            --
            -- `caller` has no equivalent field in this file's normalised
            -- payload (it names a civilian 911 caller in the source
            -- resource's own domain, which a K9-down alert has no analogue
            -- of) -- a fixed literal identifies the sender instead, the
            -- same way a real CAD system would show "AUTOMATED" or a unit
            -- callsign for a system-generated call rather than a blank.
            --
            -- CONFIDENCE NOTE on the delivery mechanism itself: this fires
            -- via a bare `TriggerEvent`, not `TriggerServerEvent`, even
            -- though the source registers via `RegisterServerEvent`.
            -- HIGH confidence, standard/widely-documented FXServer event
            -- behaviour (RegisterServerEvent/RegisterNetEvent both mark a
            -- handler as reachable by the OTHER side's Trigger*Event in
            -- ADDITION to same-realm AddEventHandler-style local delivery,
            -- never as a restriction on local delivery) -- not
            -- independently re-verified against the CitizenFX resource-
            -- manager/event-component engine source itself this session
            -- (that source is C++ resource-manager plumbing, not a Lua
            -- runtime file or a native with its own ext/native-decls page,
            -- so it could not be checked the same way this codebase checks
            -- a native). Disclosed rather than silently assumed airtight,
            -- matching this codebase's own established confidence-grading
            -- convention (e.g. client/inventory.lua's openInventory
            -- CONFIDENCE NOTE).
            local callOk = pcall(function()
                TriggerEvent('wf-alerts:svNotify', {
                    dispatchData = {
                        displayCode   = n.code10 or n.code,
                        description   = n.title,
                        isImportant   = (n.priority <= 1) and 1 or 0,
                        recipientList = n.jobs,
                        info          = n.message ~= '' and n.message or nil,
                    },
                    caller = 'K9 Unit (automated)',
                    coords = n.coords,
                })
            end)
            return callOk == true
        end,
    }
end)
