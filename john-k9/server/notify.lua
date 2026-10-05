--[[
    john-k9/server/notify.lua

    Single shared implementation of `NotifyPlayer`, consolidating 12
    independent `local function NotifyPlayer(...)` definitions that had each
    hand-rolled their own `TriggerClientEvent('ox_lib:notify', ...)` body
    across server/main.lua, server/certifications/, server/kennel.lua,
    server/medkit.lua, server/wellbeing.lua, server/combat.lua,
    server/partnership.lua, server/tenure.lua, server/admin.lua,
    server/propattachment.lua, and server/bonetool.lua.
    All 12 are now deleted (or, for the two files that deliberately vary the
    notification title -- see "TWO CALL SITES DELIBERATELY KEPT AS LOCAL
    WRAPPERS" below -- reduced to a one-line delegation to this file's
    single implementation).

    WHY A NEW FILE, NOT FOLDED INTO server/entities.lua OR
    server/cooldowns.lua: both of those files' headers state, and justify at
    length, this resource's actual established convention -- a shared file
    is scoped to ONE responsibility, specifically so it does not become an
    everything-file as later call sites accumulate (server/cooldowns.lua's
    header: "a shared file should be scoped to ONE responsibility";
    server/entities.lua's header applies that same rule to justify its OWN
    split from cooldowns.lua: "does this client-claimed netId actually
    resolve to something real is a genuinely different responsibility than a
    cooldown/mutex timer"). By that same test, "should this UI toast go out,
    and with what title" is a third, genuinely different responsibility from
    both "timing/mutex state" and "resolve a client-claimed reference
    defensively" -- it has nothing to do with entity resolution, reads no
    entity/network state at all, and every consumer needs it independently
    of whether it also happens to call ResolveNetworkEntity.

    Loaded in fxmanifest.lua's server_scripts alongside server/cooldowns.lua
    and server/entities.lua. Unlike server/cooldowns.lua's constructors
    (called by their consumers at FILE-LOAD time), NotifyPlayer below is,
    same as server/entities.lua's ResolveNetworkEntity, only ever called at
    RUN time from inside an event/callback/command handler -- every one of
    the 12 original copies' call sites was confirmed by direct read before
    this extraction. That means this file's exact position relative to its
    consumers is not load-bearing the same way cooldowns.lua's is (by the
    time any consumer's handler can actually fire, every server_scripts file
    has already finished loading, regardless of manifest order), but it is
    still placed early, alongside cooldowns.lua/entities.lua, to read in the
    same "shared primitive first" order those two already established, and
    so no runtime existence guard (`type(NotifyPlayer) == 'function'`) is
    needed at any call site -- that guard is reserved for a genuine FORWARD
    reference (a file loaded earlier calling into a global defined by a file
    loaded later); every one of this file's consumers is loaded after it,
    exactly like every existing ResolveNetworkEntity call site.

    ======================================================================
    FILE-TO-FILE CONTRACT:
    - THIS FILE exposes ONE resource-global (no `local`) function:
        NotifyPlayer(target: number, description: string, notifyType: string?, title: string?)
      Sends a single ox_lib `ox_lib:notify` client event to `target`.
      `notifyType` defaults to `'info'` and `title` defaults to `'K9 Unit'`.

      DEFAULT VALUE: all 9 of the 12 original hand-rolled copies
      (server/main.lua, server/certifications/, server/kennel.lua,
      server/medkit.lua, server/wellbeing.lua, server/combat.lua,
      server/partnership.lua, server/propattachment.lua)
      hard-coded their own default as the literal string `'inform'`.
      `'inform'` is WRONG: verified directly against ox_lib's real upstream
      source (resource/interface/client/notify.lua, `overextended/ox_lib`
      `master` branch), `lib.notify`'s own `NotificationType` alias is
      exactly `'info' | 'warning' | 'success' | 'error'` -- `'inform'` is not
      a member and never has been on the version this resource's
      fxmanifest.lua depends on. `'inform'` is a leftover from ox_lib v3;
      the current source only remaps `'inform'` -> `'info'` inside the
      DEPRECATED back-compat shim `lib.defaultNotify` (`if data.type ==
      'inform' then data.type = 'info' end`), and this file below always
      fires `TriggerClientEvent('ox_lib:notify', ...)`, whose CLIENT-side
      handler is registered directly against `lib.notify`
      (`RegisterNetEvent('ox_lib:notify', lib.notify)`) -- never through
      `lib.defaultNotify` -- so that remap never ran for any notification
      this resource ever sent. It rendered correctly only by accident: the
      web frontend's `switch(data.type)` in
      `web/src/features/notifications/NotificationWrapper.tsx` has
      explicit `case`s for `'error'`/`'success'`/`'warning'` only, and both
      `'inform'` and the real `'info'` silently fall into the same
      `default:` branch (blue `circle-info` icon) purely because neither is
      one of those three explicit cases -- not because `'inform'` is
      actually handled. Using the genuinely valid `'info'` as the default
      here therefore changes NOTHING about what a player sees for any call
      site that relies on this default; it removes the coincidence, not a
      visual regression.

      This means the default here does NOT byte-for-byte match those 9
      original copies' own hard-coded literal -- it is deliberately
      DIFFERENT from (and a correction of) what they hard-coded. Each of
      those 9 files' individual call sites that still pass the literal
      string `'inform'` explicitly (confirmed by direct grep: they do, at
      every one of their own call sites) are UNCHANGED by this file's
      default and remain their own separate, pre-existing instance of this
      exact same bug -- fixing this shared function's default cannot reach
      an explicit literal passed at a call site; that is out of this
      file's scope and each such file's own responsibility. The ONLY
      current caller(s) that omit `notifyType` and therefore actually
      observe this default's value are server/tenure.lua's 2 call sites
      (`NotifyPlayer(k9Src, ...)` / `NotifyPlayer(handlerSrc, ...)` for
      `'tenure.milestone_reached'`) -- confirmed by direct grep of every
      `NotifyPlayer(...)` call site in this resource, not assumed.
      server/tenure.lua's copy was narrower still before extraction
      (`function NotifyPlayer(target, description)`, no `notifyType`
      parameter at all, always `'inform'`) -- migrated for free the same
      way, its call sites having only ever passed 2 arguments, which now
      produces `type = 'info', title = 'K9 Unit'` through this shared
      function's own (corrected) defaults.

    TWO CALL SITES DELIBERATELY KEPT AS LOCAL WRAPPERS, NOT FLATTENED:
    server/admin.lua (title `'K9 Unit — Admin Audit'`) and
    server/bonetool.lua (title `'K9 Unit — Bone Tool'`) each intentionally
    vary the notification title from the common `'K9 Unit'` default --
    confirmed as a deliberate per-subsystem choice, not an accident (each
    file's own prior comment on this function said so explicitly). Rather
    than either (a) collapsing both onto the generic title -- a real,
    player-visible regression -- or (b) appending the literal title string
    as a 4th argument at every one of admin.lua's 11 and bonetool.lua's 3
    call sites (which would REPLACE one duplicated function body with the
    SAME title string duplicated 11/3 times instead, a lateral move at
    best), each of those two files keeps its own tiny local
    `NotifyPlayer(target, description, notifyType)` function -- same name,
    deliberately shadowing this file's global inside that one file -- whose
    ENTIRE body is now a single delegating call to
    `_G.NotifyPlayer(target, description, notifyType, '<that file's own
    title>')`. The explicit `_G.` prefix is required, not decorative: inside
    a `local function NotifyPlayer(...)` body, a bare `NotifyPlayer(...)`
    call would resolve to the enclosing local itself (Lua's `local function
    f` is sugar for `local f; f = function() ... end`, so `f` is already in
    scope inside its own body) and recurse forever rather than reaching this
    file's global. This keeps each of those two files' every existing call
    site byte-for-byte unchanged while still moving the ACTUAL notification-
    sending logic (the `TriggerClientEvent('ox_lib:notify', ...)` table
    construction) to this single shared implementation -- the duplicated
    logic worth consolidating. Only the one-line title string stays local to
    each file, which is exactly where a genuine per-subsystem difference
    belongs.
    ======================================================================
]]

--- Sends an ox_lib notification to a specific player. Single shared
--- implementation of the pattern 12 independent local copies hand-rolled
--- across this resource's server files -- see this file's header for the
--- full extraction writeup, including the two files that keep a thin local
--- wrapper to preserve their own deliberately different title.
---
--- TARGET GUARD (new, not present in any of the 12 original copies): none
--- of the 12 originals validated `target` before handing it straight to
--- TriggerClientEvent. A caller bug that lets a nil or non-player `target`
--- (nil from an unguarded ResolveConnectedPlayerFromPed result, the `0`
--- "console" source sentinel some call sites already special-case before
--- calling this, a stale/disconnected server id) reach TriggerClientEvent
--- this way is a genuine risk either way: FXServer's own 'ox_lib:notify'
--- delivery for an invalid target is not guaranteed to be a clean no-op,
--- and even when it IS a clean no-op, that failure was previously
--- completely invisible -- no log, no error, just a player who silently
--- never sees a notification they were supposed to get. This guard
--- converts either failure mode into one deterministic, observable
--- outcome: reject before calling TriggerClientEvent at all, and print a
--- console line naming the bad target and the description that would have
--- been sent, so a caller bug surfaces in the server console instead of
--- vanishing. Every existing call site in this resource already passes a
--- real, positive numeric server id (confirmed by direct grep of every
--- `NotifyPlayer(...)` call site before adding this), so this is not
--- expected to change observed behavior for any current caller -- it only
--- changes what happens on a future caller bug.
--- @param target number
--- @param description string
--- @param notifyType string? -- defaults to 'info' (a real ox_lib NotificationType member: 'info' | 'warning' | 'success' | 'error'; see this file's header for why the original hard-coded 'inform' default was wrong and why fixing it here does not change any current caller's rendered output except server/tenure.lua's 2-arg call sites)
--- @param title string? -- defaults to 'K9 Unit', matching 9 of the 12 original copies' hard-coded title
function NotifyPlayer(target, description, notifyType, title)
    if type(target) ~= 'number' or target <= 0 then
        print(('[John-K9] NotifyPlayer: refusing to send to invalid target (%s) -- description was: %s'):format(tostring(target), tostring(description)))
        return
    end

    TriggerClientEvent('ox_lib:notify', target, {
        title = title or 'K9 Unit',
        description = description,
        type = notifyType or 'info',
    })
end

--- A person's character name ("Sam Test") for a message, from their
--- server id. Falls back to their FiveM name, then "player <id>", so a
--- message is never blank.
--- @param src number
--- @return string
function CharacterNameForSource(src)
    local ok, player = pcall(function() return exports.qbx_core:GetPlayer(src) end)
    local info = ok and player and player.PlayerData and player.PlayerData.charinfo
    if type(info) == 'table' and type(info.firstname) == 'string' and info.firstname ~= '' then
        return (info.firstname .. ' ' .. (type(info.lastname) == 'string' and info.lastname or '')):match('^%s*(.-)%s*$')
    end
    local okName, name = pcall(GetPlayerName, src)
    if okName and type(name) == 'string' and name ~= '' then return name end
    return ('player %s'):format(tostring(src))
end

--- Same as CharacterNameForSource, from a citizen id; falls back to the
--- citizen id itself when that person is offline.
--- @param citizenid string
--- @return string
function CharacterNameForCitizenId(citizenid)
    local ok, player = pcall(function() return exports.qbx_core:GetPlayerByCitizenId(citizenid) end)
    local src = ok and player and player.PlayerData and player.PlayerData.source
    if type(src) == 'number' then return CharacterNameForSource(src) end
    return tostring(citizenid)
end

--- A role's display name ("Tactical K9") from its key, for messages.
--- @param roleKey string
--- @return string
function RoleDisplayName(roleKey)
    local def = type(Config.K9Specializations) == 'table' and Config.K9Specializations[roleKey] or nil
    if type(def) == 'table' and type(def.label) == 'string' and def.label ~= '' then return def.label end
    return tostring(roleKey)
end
