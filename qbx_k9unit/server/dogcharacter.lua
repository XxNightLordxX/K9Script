--[[
    qbx_k9unit/server/dogcharacter.lua

    MANA_POLICEDOGS FEATURE-PARITY PASS. The project owner named a direct
    competitor (mana_policedogs) whose own Tebex description (reached only
    via search-engine snippets in this environment, reported here as such,
    not verified against the primary page) advertises admin commands
    `/setPoliceDog [id] [variation]` / `/removePoliceDog [id]` that mark a
    CHARACTER as a dog, "persisted so that every time the character loads
    in they will load in as a dog with full health", with several
    selectable model variations.

    ======================================================================
    WHY THIS IS A NEW, SEPARATE FILE/TABLE RATHER THAN A REUSE OF THE
    EXISTING CERTIFICATION-DRIVEN APPEARANCE SYSTEM AS-IS: read this
    resource's own existing design first (server/appearance.lua's header,
    Config.K9Appearance in config.lua) -- it ALREADY persists a citizenid's
    K9 ped model across relog/crash/restart (`k9_ped_assignments`,
    migration 0008), already restores full health via this pass's own
    client/appearance.lua hook (see "FULL HEALTH" below), and already
    survives a certification revoked while the target is offline
    (server/appearance.lua's RevokeCertificationOffline call site already
    calls MaybeRevertK9Appearance). So MOST of what mana_policedogs
    describes, this resource ALREADY had, correctly, before this pass
    started -- verified by direct read of server/appearance.lua, not
    assumed. See this pass's own hand-off report for that verification in
    full.

    The ONE genuine gap: that entire existing system treats "is this
    character a dog" as something DERIVED from a certification/permission
    credential -- the model is a SIDE EFFECT of a grant, and
    MaybeRevertK9Appearance correctly UNDOES it the instant that credential
    is lost. mana_policedogs treats it as a PROPERTY OF THE CHARACTER,
    entirely independent of any job/certification -- an admin says "this
    citizenid is a dog" and it stays true until an admin says otherwise,
    full stop. Those are two different, both legitimate, features, and
    conflating them would mean an ordinary certification revoke silently
    undoes an admin's explicit, unrelated decision -- exactly the "must not
    fight the existing certification system" risk this pass's own brief
    called out by name.

    THE PRECEDENCE DECISION, STATED ONCE, PLAINLY: a `k9_dog_characters`
    PIN (this file) always wins for APPEARANCE (what a citizenid looks
    like on reconnect, and whether an unrelated certification-driven
    revert is allowed to touch them) over the certification-driven
    `k9_ped_assignments` state (server/appearance.lua) for as long as the
    pin is active. It NEVER wins, and is never even consulted, for ROLE --
    HasK9Role (server/appearance.lua) is completely untouched by this file:
    a pinned dog-character with no certification and no `k9.access` grant
    still cannot search, bite, track, or use any other K9 ability. "The
    role is the fact, the model is cosmetic" (server/appearance.lua's own
    header) is preserved exactly -- this file only ever adds a SECOND,
    independent way to pin the cosmetic half, never a new way to grant the
    role half. This is deliberate and is the reason `/k9setdog` does NOT
    reuse `ApplyK9PedRole` (which grants `k9.access` as an explicit,
    intentional side effect) -- an admin cosmetically flagging a citizenid
    as a dog must never silently hand them working K9 abilities they were
    not otherwise entitled to.

    Reverse case -- a certified K9 handler with NO dog-character pin --
    behaves exactly as it does today, completely unaffected by this file:
    every function below is a no-op for a citizenid this file has never
    heard of (IsPinnedDogCharacter/GetPinnedDogCharacterModel both answer
    false/nil for an unpinned citizenid, which is the correct "fall through
    to the existing behavior" answer at every one of their call sites).

    ======================================================================
    HOW THE ACTUAL PED SWAP HAPPENS -- REUSE, NOT A SECOND
    CLIENT/CONFIRM/TIMEOUT/SWEEP IMPLEMENTATION: this file owns exactly
    ONE new fact (the pin) and its own admin-command surface. It does NOT
    reimplement the engaged-check refusal, streaming timeout, forced-
    timeout-on-revert sweep, or disconnect-commit handling
    server/appearance.lua's client round trip already has -- rebuilding
    any of that here would be exactly the "second revert path" risk
    server/tablet.lua's own header already flagged once for a different
    feature ("coordinate with it, do not build a second revert path" --
    the owner's own words there). Instead this file is a THIN caller of
    THREE existing/requested server/appearance.lua primitives:
      ApplyK9AppearanceDirect(citizenid, model, granterLabel) -- REQUESTED,
        NOT YET LANDED as of this file being written (see "ROUTED CHANGES"
        below). The swap-only half of ApplyK9PedRole, with NO permission
        grant -- this is the one genuinely new primitive server/appearance.lua
        needs, because every existing entry point that performs a real
        swap (ApplyK9PedRole, ApplyK9AppearanceOnGrant) is wired to a
        credential grant, and this file must not be.
      MaybeRevertK9Appearance(citizenid) -- ALREADY LANDED, called
        UNCHANGED by RemoveDogCharacter below once this file's own pin is
        cleared, to let its own existing credential-based reconciliation
        decide the resulting look (see that function's own doc comment).
      GetAssignedK9Model/HasK9Role -- ALREADY LANDED, read-only, consulted
        nowhere directly in this file today but available to a future
        tablet-side "dog-character" tab that wants to display both facts
        side by side.
    Every one of these is guarded with this resource's established
    `type(fn) == 'function'` soft-dependency convention, so a build that
    has not yet received the routed appearance.lua patch below degrades to
    a loud, honest failure outcome (never a silent no-op, never an
    uncaught error) rather than refusing to load at all -- see
    "DEGRADED MODE" below.

    ======================================================================
    ROUTED CHANGES NEEDED (this file cannot make them -- server/appearance.lua,
    client/appearance.lua, sql/install.sql, locales/en.json, .luacheckrc's
    globals list and fxmanifest.lua's server_scripts entry for THIS file
    are all outside this pass's edit surface; see this pass's own hand-off
    report for the exact diff text of each):

    1. server/appearance.lua -- ONE NEW function, added standalone (does
       not modify any existing line), placed anywhere after
       IsValidPedModelName/SendSwapRequest/WriteAppearanceApplied are
       defined (e.g. immediately after ApplyK9PedRole):
           function ApplyK9AppearanceDirect(targetCitizenid, modelName, granterLabel)
               if not IsValidPedModelName(modelName) then return false, 'invalid_model' end
               local sent = SendSwapRequest(targetCitizenid, 'apply', modelName, granterLabel)
               if sent then return true, 'ok' end
               local wroteOk = WriteAppearanceApplied(targetCitizenid, modelName, nil, granterLabel)
               if not wroteOk then return false, 'db_error' end
               return true, 'persisted_offline'
           end

    2. server/appearance.lua -- ONE new guard line at the very top of the
       EXISTING MaybeRevertK9Appearance function body (the pin-immunity
       decision this file's header documents above):
           function MaybeRevertK9Appearance(citizenid)
               if type(IsPinnedDogCharacter) == 'function' and IsPinnedDogCharacter(citizenid) then return end -- NEW
               if not (Config.K9Appearance and Config.K9Appearance.restoreOriginalPedOnRevoke) then return end
               ... (unchanged below)

    3. server/appearance.lua -- ONE new block inside the EXISTING
       `QBCore:Server:PlayerLoaded` handler, inserted immediately after the
       existing `local src = Player.PlayerData.source` line and BEFORE the
       existing `local row = GetAppearanceRow(citizenid)` line (reconnect
       precedence -- see header above):
           if type(GetPinnedDogCharacterModel) == 'function' then
               local pinnedModel = GetPinnedDogCharacterModel(citizenid)
               if pinnedModel then
                   SendSwapRequest(citizenid, 'apply', pinnedModel, 'system')
                   return
               end
           end

    4. client/appearance.lua -- FULL HEALTH ON LOAD (this pass's item 4,
       genuinely missing today -- verified by direct read: neither
       SetEntityHealth nor GetEntityMaxHealth appears anywhere in that
       file or in server/appearance.lua before this pass). Both natives
       are ALREADY in .luacheckrc's read_globals (client/medkit.lua and
       client/combat.lua both already call them), so this needs NO
       .luacheckrc edit. Two one-line additions inside the existing
       'qbx_k9unit:client:applyK9Ped' handler, immediately after each of
       its two existing `SetPedDefaultComponentVariation(...)` calls:
           SetPedDefaultComponentVariation(swappedPed)
           SetEntityHealth(swappedPed, GetEntityMaxHealth(swappedPed)) -- NEW
       and, inside the `CreateThread(function() Wait(0) ... end)` block a
       few lines below it:
           SetPedDefaultComponentVariation(ped)
           SetEntityHealth(ped, GetEntityMaxHealth(ped)) -- NEW
       This is a GENERAL fix, not scoped to this file's own feature: it
       also fixes full-health-on-load for the pre-existing /k9certify
       swap path and for an ordinary certification-driven reconnect, since
       every one of those funnels through this SAME client handler.

    5. sql/install.sql -- add this migration's CREATE TABLE block
       (sql/migrations/0019_create_k9_dog_characters.sql, verbatim) to the
       fresh-install schema, matching how every prior migration's table
       was folded in (see that file's own per-table header convention).

    6. locales/en.json -- add a new top-level "dogcharacter" section; see
       this file's own RegisterCommand handlers below for the exact key
       list used (dogcharacter.usage_setdog/usage_removedog/set_success/
       remove_success/invalid_model/not_a_dog_character/set_failed/
       remove_failed). Until landed, `locale()` returns each raw key
       string unchanged (ox_lib's own documented fallback) -- the exact
       same interim state server/appearance.lua's own `appearance.*` keys
       are already in, per that file's header.

    7. fxmanifest.lua -- add 'server/dogcharacter.lua' to server_scripts,
       after 'server/appearance.lua' (soft dependency on
       ApplyK9AppearanceDirect/MaybeRevertK9Appearance, both consulted only
       at runtime through the usual `type(fn) == 'function'` guard, so this
       is a placement preference, not a hard requirement) and after
       'server/highcommand.lua'/'server/cooldowns.lua' (HARD requirement:
       NewCooldown is called at THIS file's own load time, below).

    ======================================================================
    DEGRADED MODE, BEFORE ITEMS 1-3 ABOVE LAND: `/k9setdog` still records
    the pin (this file's own self-contained persistence, below) and
    reports a distinct `'appearance_hook_unavailable'` outcome (logged
    AND notified) rather than a false success -- the pin is not lost: the
    very first PlayerLoaded firing for that citizenid AFTER item 3 lands
    will correctly pick it up. `/k9removedog` is UNAFFECTED by these
    routed items being absent: clearing the pin (this file's own write)
    always succeeds or fails on its own terms, independent of
    server/appearance.lua entirely -- only the OPTIONAL immediate-online-
    reconciliation step is soft-guarded.

    ======================================================================
    OFFLINE-CAPABLE ON PURPOSE (both commands): mirrors
    ForceRevertK9Appearance/ApplyK9PedRole, both citizenid-keyed rather
    than server-id-keyed. `/k9setdog`/`/k9removedog [id]` accept EITHER a
    currently-connected server id OR a literal citizenid string
    (ResolveTargetCitizenId below) -- an admin must be able to pin or
    un-pin a dog-character who is not currently online, exactly like
    mana_policedogs' own "persisted so every time the character loads in"
    promise implies (an admin flags a citizenid once; it does not require
    that citizenid to be sitting online at that exact moment). "Never gate
    a termination path": RemoveDogCharacter below clears the DB pin FIRST
    and unconditionally, before attempting any live reconciliation, so a
    target who is offline (or whose live reconciliation step fails for any
    reason) is still guaranteed to come back un-pinned on their next
    connect.

    ======================================================================
    PERSISTENCE / Config.Database.enabled = false: this file's own
    DogChar_GetRow/DogChar_UpsertActive/DogChar_MarkInactive below are a
    DELIBERATE, FLAGGED EXCEPTION to server/datastore.lua's own header
    rule ("THE ONLY PLACE IN THIS RESOURCE THAT MAY NAME A `k9_*` TABLE OR
    CALL `MySQL.*` DIRECTLY") -- this file cannot edit server/datastore.lua
    (outside this pass's edit surface), and a genuinely new table needs
    SOME accessor to exist before it can be used at all. Each of the three
    functions below follows datastore.lua's own established shape EXACTLY
    (one `if DatabaseEnabled(...) then <real SQL> else <plain Lua table>
    end` branch, per-call pcall degrade on a real-query failure, identical
    boolean/row contracts) via `K9Store.IsDatabaseEnabled('k9_dog_characters')`
    -- ALREADY a public, generic, per-table function on the real
    server/datastore.lua (`K9Store.IsDatabaseEnabled = DatabaseEnabled`,
    forwarding any table name), so this needed NO datastore.lua edit to
    call correctly. A server running `Config.Database.enabled = false`
    (or one where datastore.lua's own schema-collision probe forced
    memory-only mode resource-wide) therefore keeps `/k9setdog`/
    `/k9removedog` fully working for the life of the process, with nothing
    remembered past a restart -- the exact same honest trade-off
    server/datastore.lua's own header documents for every other table in
    this schema.

    ROUTING REQUEST: this exception should be consolidated away by moving
    the three functions below (verbatim -- their bodies are already
    written in datastore.lua's own established shape) into
    server/datastore.lua as `K9Store.DogChar_GetRow` /
    `K9Store.DogChar_UpsertActive` / `K9Store.DogChar_MarkInactive`, at
    which point this file's own copies should be deleted and replaced with
    calls to `K9Store.*` like every other server file already does. Not
    done in this pass because server/datastore.lua is outside this pass's
    edit surface.
]]

-- ADMIN CHAT COMMANDS ARE OFF BY DEFAULT (owner: "k9certify should only
-- be done through the tablet", and all other admin work with it). They are
-- only registered when Config.CommandTablet.adminChatCommands is true --
-- the tablet does every one of these. The handlers below are kept (and
-- tested) so an owner who wants console access can switch them back on.
local function RegisterAdminCommand(name, handler, restricted)
    if type(Config.CommandTablet) == 'table' and Config.CommandTablet.adminChatCommands == true then
        RegisterCommand(name, handler, restricted)
    end
end


-- ======================================================================
-- CONFIG-SAFETY -- CLAMP AND WARN, NEVER ASSERT (this resource's own
-- established rule -- see server/appearance.lua's own header for the full
-- "an uncaught error at file-load time takes every function this file
-- defines down with it" reasoning, which applies identically here). This
-- file reads Config.Peds (already normalized to a non-empty array by
-- server/appearance.lua's own load-time guard on every build where that
-- file is loaded, per fxmanifest.lua's load order) but never assumes that
-- guard ran -- every read below already fails closed (never matches, never
-- throws) on a missing/malformed Config.Peds, with no assert of its own
-- needed here.
-- ======================================================================

--- @param name any
--- @return boolean
local function IsValidPedModelName(name)
    if type(name) ~= 'string' or name == '' then return false end
    if type(Config.Peds) ~= 'table' then return false end
    for _, pedEntry in ipairs(Config.Peds) do
        if type(pedEntry) == 'table' and pedEntry.model == name then return true end
    end
    return false
end

--- Accepts either a literal Config.Peds[].model string OR a 1-based index
--- into Config.Peds (admin command ergonomics -- typing "2" is easier to
--- get right than a full model string from memory). Clamp-and-warn shape:
--- an out-of-range/non-integer index is never reinterpreted as a literal
--- model name (a numeric-looking argument was clearly meant as an index),
--- it simply resolves to nil, which every call site below already treats
--- as "invalid variation argument".
--- @param rawArg string?
--- @return string? modelName
local function ResolveVariationArg(rawArg)
    if type(rawArg) ~= 'string' or rawArg == '' then return nil end
    local asIndex = tonumber(rawArg)
    if asIndex ~= nil then
        if asIndex ~= math.floor(asIndex) or type(Config.Peds) ~= 'table' then return nil end
        local entry = Config.Peds[asIndex]
        if entry and type(entry.model) == 'string' and entry.model ~= '' then return entry.model end
        return nil
    end
    return rawArg
end

--- Dual resolution, offline-capable -- see this file's header "OFFLINE-
--- CAPABLE ON PURPOSE". A purely numeric argument is ALWAYS treated as a
--- server id (qbx_core citizenids are never purely numeric), never
--- reinterpreted as a literal citizenid if that id is not currently
--- connected -- an admin typing a stale/mistaken server id gets a clear
--- "no such player" outcome rather than a nonsensical DB lookup for a
--- citizenid that happens to look like a number.
--- @param rawArg string?
--- @return string? citizenid
local function ResolveTargetCitizenId(rawArg)
    if type(rawArg) ~= 'string' or rawArg == '' then return nil end
    local asServerId = tonumber(rawArg)
    if asServerId ~= nil then
        local Player = exports.qbx_core:GetPlayer(asServerId)
        local citizenid = Player and Player.PlayerData and Player.PlayerData.citizenid
        return citizenid
    end
    return rawArg
end

--- @param source number
--- @return string
local function WhoLabelForSource(source)
    local Player = exports.qbx_core:GetPlayer(source)
    local citizenid = Player and Player.PlayerData and Player.PlayerData.citizenid
    return citizenid and ('citizenid=' .. citizenid) or ('unresolved-source=' .. tostring(source))
end

--- Matches server/appearance.lua's LogAppearanceAudit / server/admin.lua's
--- LogAuditInvocation "%s ran %s(%s) -> %s" format EXACTLY -- same
--- established audit-trail convention, not a fourth format invented here.
--- @param whoLabel string
--- @param action string
--- @param detail string
--- @param outcome string
local function LogDogCharacterAudit(whoLabel, action, detail, outcome)
    print(('[qbx_k9unit] AUDIT: %s ran %s(%s) -> %s'):format(whoLabel, action, detail, outcome))
end

-- Anti-fat-finger cooldown, same shape/threshold as
-- server/appearance.lua's own AppearanceActionCooldown (1500ms) -- a
-- SEPARATE instance (this file's own admin actions are conceptually
-- distinct from that file's certify-driven apply/revert, and sharing an
-- instance would mean an operator's own /k9certify use could rate-limit
-- their very next /k9setdog for no principled reason). Keyed by the
-- GRANTER's own source, matching every other per-officer action cooldown
-- in this resource.
local DOG_CHARACTER_ACTION_COOLDOWN_MS = 1500
local DogCharacterActionCooldown = NewCooldown(DOG_CHARACTER_ACTION_COOLDOWN_MS)
DogCharacterActionCooldown.RegisterPlayerDropped()

-- ======================================================================
-- PERSISTENCE -- see this file's header "PERSISTENCE / Config.Database"
-- section for why this lives here (a deliberate, flagged, temporary
-- exception) instead of server/datastore.lua.
-- ======================================================================
local DogCharacterRows = {} -- memory-mode mirror: citizenid -> { model, active, set_by }

--- @return boolean
local function DogCharacterDbEnabled()
    return type(K9Store) == 'table'
        and type(K9Store.IsDatabaseEnabled) == 'function'
        and K9Store.IsDatabaseEnabled('k9_dog_characters') == true
end

--- @param citizenid string
--- @return table? row -- { model, active } or nil (not found, or the read failed)
local function DogChar_GetRow(citizenid)
    if DogCharacterDbEnabled() then
        local ok, rows = pcall(MySQL.query.await, 'SELECT model, active FROM k9_dog_characters WHERE citizenid = ? LIMIT 1', { citizenid })
        if not ok then
            print(('[qbx_k9unit] dogcharacter: DogChar_GetRow query failed for %s: %s'):format(citizenid, tostring(rows)))
            return nil
        end
        return rows and rows[1] or nil
    end
    local row = DogCharacterRows[citizenid]
    if not row then return nil end
    return { model = row.model, active = row.active }
end

--- @param citizenid string
--- @param model string
--- @param setByLabel string
--- @return boolean ok
local function DogChar_UpsertActive(citizenid, model, setByLabel)
    if DogCharacterDbEnabled() then
        local ok, err = pcall(MySQL.query.await, [[
            INSERT INTO k9_dog_characters (citizenid, model, active, set_by, set_at, unset_at)
            VALUES (?, ?, 1, ?, CURRENT_TIMESTAMP, NULL)
            ON DUPLICATE KEY UPDATE
                model = VALUES(model),
                active = 1,
                set_by = VALUES(set_by),
                set_at = CURRENT_TIMESTAMP,
                unset_at = NULL
        ]], { citizenid, model, setByLabel })
        if not ok then
            print(('[qbx_k9unit] dogcharacter: DogChar_UpsertActive write failed for %s: %s'):format(citizenid, tostring(err)))
            return false
        end
        return true
    end
    DogCharacterRows[citizenid] = { model = model, active = 1, set_by = setByLabel }
    return true
end

--- @param citizenid string
--- @return boolean ok
local function DogChar_MarkInactive(citizenid)
    if DogCharacterDbEnabled() then
        local ok, err = pcall(MySQL.query.await, 'UPDATE k9_dog_characters SET active = 0, unset_at = CURRENT_TIMESTAMP WHERE citizenid = ? AND active = 1', { citizenid })
        if not ok then
            print(('[qbx_k9unit] dogcharacter: DogChar_MarkInactive write failed for %s: %s'):format(citizenid, tostring(err)))
            return false
        end
        return true
    end
    local row = DogCharacterRows[citizenid]
    if row then row.active = 0 end
    return true
end

-- ======================================================================
-- EXPOSED PRIMITIVES -- consumed by server/appearance.lua once the routed
-- patch (header items 2-3) lands, guarded there with the standard
-- `type(fn) == 'function'` soft-dependency convention. Both fail CLOSED
-- (false/nil) on any malformed input, matching every other read-only
-- accessor in this resource.
-- ======================================================================

--- @param citizenid string
--- @return boolean
function IsPinnedDogCharacter(citizenid)
    if type(citizenid) ~= 'string' or citizenid == '' then return false end
    local row = DogChar_GetRow(citizenid)
    return row ~= nil and row.active == 1
end

--- @param citizenid string
--- @return string? model -- nil if not currently pinned
function GetPinnedDogCharacterModel(citizenid)
    if type(citizenid) ~= 'string' or citizenid == '' then return nil end
    local row = DogChar_GetRow(citizenid)
    if row and row.active == 1 then return row.model end
    return nil
end

-- ======================================================================
-- ADMIN ENTRY POINTS -- see this file's header for the full "why no
-- permission grant" design decision.
-- ======================================================================

--- '/k9setdog' core mechanics -- see this file's header for the full
--- design writeup. Authorization is high-command ONLY (mirrors
--- ForceRevertK9Appearance's own "credential-blind, granter-only" gate --
--- server/appearance.lua's own precedent for an admin-direct appearance
--- action, not a bare ace check, and not a new permission key: this is an
--- ADMIN override action, the same class as ForceRevertK9Appearance
--- itself, not an ordinary grantable capability).
--- @param granterSrc number
--- @param targetCitizenid string
--- @param modelName string
--- @return boolean ok
--- @return string outcome -- 'ok' | 'persisted_offline' | 'appearance_hook_unavailable' | 'denied' | 'rate_limited' | 'invalid_target' | 'invalid_model' | 'db_error' | 'pin_db_error'
function SetDogCharacter(granterSrc, targetCitizenid, modelName)
    if not (type(IsHighCommand) == 'function' and IsHighCommand(granterSrc)) then
        LogDogCharacterAudit(WhoLabelForSource(granterSrc), 'k9SetDogCharacter',
            ('target=%s model=%s'):format(tostring(targetCitizenid), tostring(modelName)), 'denied')
        return false, 'denied'
    end

    if not DogCharacterActionCooldown.Consume(granterSrc) then
        return false, 'rate_limited'
    end

    if type(targetCitizenid) ~= 'string' or targetCitizenid == '' then
        return false, 'invalid_target'
    end

    if not IsValidPedModelName(modelName) then
        LogDogCharacterAudit(WhoLabelForSource(granterSrc), 'k9SetDogCharacter',
            ('target=%s model=%s'):format(targetCitizenid, tostring(modelName)), 'invalid_model')
        return false, 'invalid_model'
    end

    local granterLabel = WhoLabelForSource(granterSrc)

    -- DEGRADED MODE -- see this file's header. The pin is still recorded
    -- (so nothing is lost once the routed appearance.lua patch lands),
    -- but reported honestly as a distinct, non-'ok' outcome rather than a
    -- false success -- no live/offline ped swap can happen without it.
    if type(ApplyK9AppearanceDirect) ~= 'function' then
        print('[qbx_k9unit] dogcharacter.lua: ApplyK9AppearanceDirect is not defined -- server/appearance.lua ' ..
            'has not yet received this pass\'s requested hook (see server/dogcharacter.lua\'s own header ' ..
            '"ROUTED CHANGES" section, item 1). The pin below is still persisted, but no ped swap can happen ' ..
            'until that patch lands -- this citizenid\'s next PlayerLoaded will pick it up once it does.')
        local pinnedOk = DogChar_UpsertActive(targetCitizenid, modelName, granterLabel)
        local outcome = pinnedOk and 'appearance_hook_unavailable' or 'db_error'
        LogDogCharacterAudit(granterLabel, 'k9SetDogCharacter', ('target=%s model=%s'):format(targetCitizenid, modelName), outcome)
        return pinnedOk, outcome
    end

    local swapOk, swapOutcome = ApplyK9AppearanceDirect(targetCitizenid, modelName, granterLabel)
    if not swapOk then
        LogDogCharacterAudit(granterLabel, 'k9SetDogCharacter', ('target=%s model=%s'):format(targetCitizenid, modelName), swapOutcome)
        return false, swapOutcome
    end

    local pinnedOk = DogChar_UpsertActive(targetCitizenid, modelName, granterLabel)
    if not pinnedOk then
        -- The VISUAL swap already happened/persisted (swapOk == true) --
        -- only the PIN write failed, meaning an unrelated future
        -- certification-driven revert would NOT yet be blocked from
        -- stripping this appearance early. Reported honestly, never as a
        -- clean 'ok'.
        LogDogCharacterAudit(granterLabel, 'k9SetDogCharacter', ('target=%s model=%s'):format(targetCitizenid, modelName), 'pin_db_error')
        return false, 'pin_db_error'
    end

    LogDogCharacterAudit(granterLabel, 'k9SetDogCharacter', ('target=%s model=%s'):format(targetCitizenid, modelName), swapOutcome)
    return true, swapOutcome
end

--- '/k9removedog' core mechanics -- see this file's header "NEVER GATE A
--- TERMINATION PATH" for why the pin-clear below happens first and
--- unconditionally, ahead of any live reconciliation attempt.
--- @param granterSrc number
--- @param targetCitizenid string
--- @return boolean ok
--- @return string outcome -- 'ok' | 'denied' | 'rate_limited' | 'invalid_target' | 'not_a_dog_character' | 'db_error'
function RemoveDogCharacter(granterSrc, targetCitizenid)
    if not (type(IsHighCommand) == 'function' and IsHighCommand(granterSrc)) then
        LogDogCharacterAudit(WhoLabelForSource(granterSrc), 'k9RemoveDogCharacter', ('target=%s'):format(tostring(targetCitizenid)), 'denied')
        return false, 'denied'
    end

    if not DogCharacterActionCooldown.Consume(granterSrc) then
        return false, 'rate_limited'
    end

    if type(targetCitizenid) ~= 'string' or targetCitizenid == '' then
        return false, 'invalid_target'
    end

    local granterLabel = WhoLabelForSource(granterSrc)

    if not IsPinnedDogCharacter(targetCitizenid) then
        LogDogCharacterAudit(granterLabel, 'k9RemoveDogCharacter', ('target=%s'):format(targetCitizenid), 'not_a_dog_character')
        return false, 'not_a_dog_character'
    end

    -- NEVER GATE A TERMINATION PATH -- see this file's header. From the
    -- instant this write lands, IsPinnedDogCharacter/GetPinnedDogCharacterModel
    -- both correctly answer "no" for this citizenid, which alone already
    -- guarantees they never come back pinned on their NEXT reconnect
    -- (server/appearance.lua's own PlayerLoaded precedence check, once
    -- item 3 lands) even if every step below fails outright.
    local unpinnedOk = DogChar_MarkInactive(targetCitizenid)
    if not unpinnedOk then
        LogDogCharacterAudit(granterLabel, 'k9RemoveDogCharacter', ('target=%s'):format(targetCitizenid), 'db_error')
        return false, 'db_error'
    end

    -- IMMEDIATE RECONCILIATION -- reuses server/appearance.lua's own
    -- EXISTING, already-hardened MaybeRevertK9Appearance UNCHANGED (no new
    -- appearance.lua function needed for this half -- see header). Now
    -- that the pin above is gone, its own credential checks run normally:
    -- reverts to the target's true original appearance if they hold no
    -- certification/`k9.access` grant of their own, or correctly no-ops
    -- (leaving whichever certification-driven model k9_ped_assignments
    -- already has recorded) if they do. Not conditioned on the target
    -- being online: every read/write inside MaybeRevertK9Appearance is
    -- citizenid-keyed, and its own revert path already degrades correctly
    -- for an offline target (persists the cleared row, nothing left to
    -- visually undo) -- so calling it here is a harmless, correct no-op
    -- either way, and an OFFLINE target additionally gets a second,
    -- independent correctness backstop for free the next time they
    -- reconnect (server/appearance.lua's own PlayerLoaded, unaffected by
    -- this file once the pin is gone).
    if type(MaybeRevertK9Appearance) == 'function' then
        MaybeRevertK9Appearance(targetCitizenid)
    end

    LogDogCharacterAudit(granterLabel, 'k9RemoveDogCharacter', ('target=%s'):format(targetCitizenid), 'ok')
    return true, 'ok'
end

-- ======================================================================
-- COMMANDS -- gated on Config.Features.HighCommand, the SAME feature flag
-- '/k9givexp' (server/highcommand.lua) already registers behind, since
-- both SetDogCharacter/RemoveDogCharacter's own authorization is
-- IsHighCommand-only (see their own doc comments) -- registering these
-- commands at all when High Command is disabled resource-wide would be
-- registering a command that can never succeed for anyone, which this
-- resource's own established convention (server/highcommand.lua's own
-- onResourceStart guard) already treats as "don't register it". No NEW
-- Config key needed for this gate.
-- ======================================================================
if Config.Features and Config.Features.HighCommand == true then
    --- COMMAND CONSOLIDATION (docs/history/COMMAND_CONSOLIDATION_SPEC.md #2) -- same
    --- refactor shape as server/admin.lua's audit family (#1): each body
    --- below is now a named LOCAL function, called from the original
    --- single-purpose command (kept registered forever as a HIDDEN ALIAS --
    --- see client/commandsuggestions.lua's HIDDEN_ALIAS_COMMANDS) AND from
    --- the new merged '/k9dog <set|remove> ...' dispatcher further down.
    --- IsHighCommand(source) is re-checked from inside THIS SAME function
    --- body regardless of which name reached it -- never widened by a
    --- shared gate at the merged command's own top.
    ---
    --- NOT MADE CONTEXTUAL (project-owner's own "fluid" redirect, evaluated
    --- against this family's real code and deliberately NOT applied here):
    --- removing a dog-character pin is the textbook "removing a record"
    --- case the redirect itself named as requiring an explicit word, never
    --- an auto-guessed action -- even though CURRENT PIN STATE would make
    --- the guess technically inferable (not pinned -> must mean set; pinned
    --- -> must mean remove), guessing right on an admin action that
    --- immediately changes another player's live appearance is not the
    --- same as guessing right on a reversible client-side toggle like
    --- fetch/kennel/training. The bare '/k9dog <target>' form below is
    --- READ-ONLY: it reports current status and NAMES the exact explicit
    --- command to run, never performs the change itself.

    --- '/k9setdog [server id or citizenid] [variation]' core -- see this
    --- file's header for the full design writeup.
    --- @param source number
    --- @param args string[]
    local function HandleSetDog(source, args)
        -- AUTHORIZATION CHECKED HERE TOO, purely so an unauthorized caller
        -- learns nothing about argument validity (mirrors
        -- server/highcommand.lua's own k9givexp ordering) -- the COOLDOWN
        -- itself is consumed exactly ONCE, inside SetDogCharacter below,
        -- never here as well: consuming it in both places would mean the
        -- second (inner) consume always sees ~0ms elapsed since the first
        -- and reports 'rate_limited' on literally every call.
        if not (type(IsHighCommand) == 'function' and IsHighCommand(source)) then
            LogDogCharacterAudit(WhoLabelForSource(source), 'k9SetDogCharacter', 'n/a', 'denied')
            NotifyPlayer(source, locale('highcommand.not_authorized'), 'error')
            return
        end

        local targetCitizenid = ResolveTargetCitizenId(args[1])
        local modelName = ResolveVariationArg(args[2])
        if not targetCitizenid or not modelName then
            LogDogCharacterAudit(WhoLabelForSource(source), 'k9SetDogCharacter', 'n/a', 'invalid_args')
            NotifyPlayer(source, locale('dogcharacter.usage_setdog'), 'error')
            return
        end

        local ok, outcome = SetDogCharacter(source, targetCitizenid, modelName)
        if ok then
            NotifyPlayer(source, locale('dogcharacter.set_success', targetCitizenid, modelName), 'success')
        elseif outcome == 'invalid_model' then
            NotifyPlayer(source, locale('dogcharacter.invalid_model'), 'error')
        elseif outcome ~= 'rate_limited' and outcome ~= 'denied' then
            -- 'rate_limited'/'denied' are intentionally silent here --
            -- already handled/logged above or (rate_limited) matches this
            -- resource's own anti-fat-finger convention of no extra toast.
            NotifyPlayer(source, locale('dogcharacter.set_failed', tostring(outcome)), 'error')
        end
    end

    RegisterAdminCommand('k9setdog', function(source, args)
        HandleSetDog(source, args)
    end, false)

    --- '/k9removedog [server id or citizenid]' core -- see this file's
    --- header for the full design writeup.
    --- @param source number
    --- @param args string[]
    local function HandleRemoveDog(source, args)
        -- Same "check auth here too, but consume the cooldown exactly
        -- once, inside RemoveDogCharacter below" reasoning as k9setdog
        -- above.
        if not (type(IsHighCommand) == 'function' and IsHighCommand(source)) then
            LogDogCharacterAudit(WhoLabelForSource(source), 'k9RemoveDogCharacter', 'n/a', 'denied')
            NotifyPlayer(source, locale('highcommand.not_authorized'), 'error')
            return
        end

        local targetCitizenid = ResolveTargetCitizenId(args[1])
        if not targetCitizenid then
            LogDogCharacterAudit(WhoLabelForSource(source), 'k9RemoveDogCharacter', 'n/a', 'invalid_args')
            NotifyPlayer(source, locale('dogcharacter.usage_removedog'), 'error')
            return
        end

        local ok, outcome = RemoveDogCharacter(source, targetCitizenid)
        if ok then
            NotifyPlayer(source, locale('dogcharacter.remove_success', targetCitizenid), 'success')
        elseif outcome == 'not_a_dog_character' then
            NotifyPlayer(source, locale('dogcharacter.not_a_dog_character'), 'error')
        elseif outcome ~= 'rate_limited' and outcome ~= 'denied' then
            -- 'rate_limited'/'denied' are intentionally silent here --
            -- already handled/logged above or (rate_limited) matches this
            -- resource's own anti-fat-finger convention of no extra toast.
            NotifyPlayer(source, locale('dogcharacter.remove_failed', tostring(outcome)), 'error')
        end
    end

    RegisterAdminCommand('k9removedog', function(source, args)
        HandleRemoveDog(source, args)
    end, false)

    -- ==================================================================
    -- '/k9dog <set|remove> ...' -- docs/history/COMMAND_CONSOLIDATION_SPEC.md #2, the
    -- merged entry point. 'set'/'remove' stay EXPLICIT WORDS, never
    -- auto-inferred from current pin state -- see the header comment on
    -- HandleSetDog/HandleRemoveDog above for why this specific family
    -- keeps the destructive-action carve-out from the project-owner's own
    -- "fluid" redirect.
    --
    -- BARE '/k9dog <target>' (no set/remove word) -- READ-ONLY status
    -- report, still gated on IsHighCommand(source) the same as every other
    -- path in this file (this is the same admin surface, not a public
    -- info leak): tells the caller whether `target` is currently pinned
    -- and, if so, as what model, then NAMES the exact explicit command
    -- (set or remove) that would change it. Never mutates anything itself.
    -- ==================================================================
    local DOG_SUBCOMMAND_HANDLERS = {
        set = HandleSetDog,
        remove = HandleRemoveDog,
    }

    --- @param args string[]
    --- @return string[] shifted
    local function ShiftArgsPastSubcommand(args)
        local shifted = {}
        for i = 2, #args do
            shifted[#shifted + 1] = args[i]
        end
        return shifted
    end

    RegisterAdminCommand('k9dog', function(source, args)
        local subcommand = args[1]
        local handler = subcommand and DOG_SUBCOMMAND_HANDLERS[subcommand]

        if handler then
            handler(source, ShiftArgsPastSubcommand(args))
            return
        end

        -- Not 'set'/'remove' -- if args[1] resolves to a target citizenid,
        -- treat this as the read-only status form ('/k9dog <target>'),
        -- gated identically to every other path here. Anything else
        -- (nothing at all, or an unresolvable target) falls through to the
        -- usage/help print -- docs/history/COMMAND_CONSOLIDATION_SPEC.md §4's own
        -- established no-argument-discoverability convention, reused
        -- verbatim.
        if not (type(IsHighCommand) == 'function' and IsHighCommand(source)) then
            LogDogCharacterAudit(WhoLabelForSource(source), 'k9DogStatus', 'n/a', 'denied')
            NotifyPlayer(source, locale('highcommand.not_authorized'), 'error')
            return
        end

        local targetCitizenid = subcommand and ResolveTargetCitizenId(subcommand)
        if not targetCitizenid then
            local usage = locale('dogcharacter.usage_dog')
            if source == 0 then print('[qbx_k9unit] ' .. usage) else NotifyPlayer(source, usage, 'error') end
            return
        end

        if not DogCharacterActionCooldown.Consume(source) then
            LogDogCharacterAudit(WhoLabelForSource(source), 'k9DogStatus', 'n/a', 'rate_limited')
            return
        end

        local model = GetPinnedDogCharacterModel(targetCitizenid)
        LogDogCharacterAudit(WhoLabelForSource(source), 'k9DogStatus', targetCitizenid, 'ok')
        if model then
            NotifyPlayer(source, locale('dogcharacter.status_pinned', targetCitizenid, model, targetCitizenid), 'info')
        else
            NotifyPlayer(source, locale('dogcharacter.status_not_pinned', targetCitizenid, targetCitizenid), 'info')
        end
    end, false)
end
