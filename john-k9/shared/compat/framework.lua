--[[
    shared/compat/framework.lua

    FRAMEWORK adapters for Config.Compat's resource-compatibility layer (see
    config.lua's `Config.Compat` block). Registers one adapter per candidate
    listed in `Config.Compat.Systems.framework.candidates`, in the order
    config.lua lists them: qbx_core (reference), qb-core, es_extended.

    THE CONTRACT (as given to this file, verbatim):
        K9Compat.RegisterAdapter('framework', '<resourceName>', factory)
        factory(realm) -> table | nil    -- nil = present but unusable, skip me
        Required client methods: GetPlayerData
        Required server methods: GetPlayer, GetPlayerByCitizenId,
                                  GetCitizenId, GetJob

    WHY GetCitizenId/GetJob EXIST AS SEPARATE METHODS RATHER THAN EXPOSING
    THE RAW PLAYER OBJECT: qbx_core, qb-core and es_extended each return a
    genuinely different player object with different field paths for the
    citizen id and for job name/grade (confirmed below, not assumed -- see
    each factory's own header). Exposing the raw object would leak a
    framework-shaped value into caller code that is supposed to stay
    framework-agnostic, and would silently break the moment an operator
    switches frameworks. Every adapter below normalises inside itself and
    never returns a framework-shaped object from GetCitizenId/GetJob --
    only a plain string (citizenid) or a (string, integer) pair (job name,
    job grade level).

    GetJob'S SETTLED SHAPE: `GetJob(player)` returns exactly two values,
    `jobName, jobGradeLevel` -- a string and an integer (or `nil, nil` if
    the player/job can't be resolved). No `isboss`, no label, no third
    value -- the task that produced this file scoped GetJob to precisely a
    "consistent (name, grade) pair", and all three frameworks' real grade
    representations (qbx_core/qb-core: `job.grade.level`, an integer inside
    a nested table; es_extended: `job.grade`, a bare integer -- CONFIRMED
    below) collapse cleanly onto a single integer with no loss, so this is
    a genuine normalisation, not a lossy compromise.

    GetPlayerData()'S SETTLED SHAPE (client): `{ citizenid = string|nil,
    job = { name = string|nil, grade = integer|nil } }` -- deliberately the
    smallest normalised shape covering every field this resource's
    documented real usage of framework player data needs (citizenid, job
    name, job grade level), for the same "never leak a framework-shaped
    object" reason GetJob exists server-side. If a future caller needs more
    (e.g. onduty), extend this shape in one place here rather than having
    callers reach into a raw framework object again.

    SECURITY, restated: nothing in this file is a permission grant. Every
    caller of GetJob/GetCitizenId/GetPlayerData is expected to treat the
    result as informational (what does the framework currently say?),
    never as the authorization decision itself -- this resource's existing
    server-side gates (server/certifications/, server/permissions.lua,
    etc.) are the actual authority and this file changes none of that.

    NEVER LET A THIRD-PARTY EXPORT THROW INTO THIS RESOURCE. Every export
    access AND call below goes through the same two-step
    ResourceStarted -> IsExportCapable -> SafeCall shape used in
    shared/compat/target.lua (a shape that originated as a local
    IsOxInventoryHookCapable helper in server/tracking.lua, since deleted in
    the compat-layer migration -- IsExportCapable below is where it lives
    now) -- duplicated here as file-local helpers
    rather than shared across files, since STRICT OWNERSHIP for this task
    permits creating only these two compat files plus one test spec, not a
    shared third helper module.

    RESEARCH: every adapter is ranked CONFIRMED, with the primary source
    actually fetched and read this session. No export signature or player
    object field path below was taken from memory.
]]

-- ======================================================================
-- Shared helpers (file-local; deliberately duplicated from
-- shared/compat/target.lua rather than factored into a shared module --
-- see header above for why).
-- ======================================================================

--- @param resourceName string
--- @return boolean
local function ResourceStarted(resourceName)
    return GetResourceState(resourceName) == 'started'
end

--- Capability probe only -- see shared/compat/target.lua's IsExportCapable
--- for the full rationale.
--- @param resourceName string
--- @param methodName string
--- @return boolean
local function IsExportCapable(resourceName, methodName)
    if not ResourceStarted(resourceName) then return false end

    local ok, method = pcall(function() return exports[resourceName][methodName] end)
    return ok and type(method) == 'function'
end

--- Call-time protection -- see shared/compat/target.lua's SafeCall for the
--- full rationale.
--- @param resourceName string
--- @param methodName string
--- @return boolean ok
--- @return any result
local function SafeCall(resourceName, methodName, ...)
    if not ResourceStarted(resourceName) then return false end

    local target = exports[resourceName]
    local ok, result = pcall(function(...) return target[methodName](target, ...) end, ...)
    if not ok then return false end
    return true, result
end

--- A job's grade is sometimes a nested `{ name, level }` table
--- (qbx_core/qb-core) and sometimes a bare integer (es_extended). Collapses
--- either into a plain integer (or nil).
--- @param grade table | number | nil
--- @return number?
local function GradeLevel(grade)
    if type(grade) == 'table' then return grade.level end
    if type(grade) == 'number' then return grade end
    return nil
end

-- ======================================================================
-- qbx_core -- REFERENCE adapter. Already a hard `dependencies` entry in
-- fxmanifest.lua, per THE REAL SURFACE this resource's existing server code
-- already calls `exports.qbx_core:GetPlayer(src)` /
-- `GetPlayerByCitizenId(cid)` directly (server/search.lua,
-- server/highcommand.lua, server/combat.lua) -- this adapter wraps the
-- exact same two exports, it does not change what they do.
--
-- CONFIRMED against Qbox-project/qbx_core's live `main` branch, fetched and
-- read directly this session (2026-08-25):
--   * `exports.qbx_core:GetPlayer(source)` / `GetPlayerByCitizenId(citizenid)`
--     (`server/functions.lua`) return a `Player` object whose
--     `player.PlayerData.citizenid` (string) and
--     `player.PlayerData.job = { name, label, isboss, bankAuth, onduty,
--     payment, type, grade = { name, level } }` (`server/player.lua`'s
--     `toPlayerJob`) are both CONFIRMED field paths.
--   * Client: `exports.qbx_core:GetPlayerData()` (`modules/playerdata.lua`,
--     which this resource's own fxmanifest.lua comment already documents
--     as the source of the `QBX.PlayerData` global other client files in
--     this resource read directly) returns the same PlayerData shape.
-- ======================================================================
local function QbxCoreFactory(realm)
    local RESOURCE = 'qbx_core'
    if not ResourceStarted(RESOURCE) then return nil end

    if realm == 'server' then
        if not IsExportCapable(RESOURCE, 'GetPlayer') then return nil end
        if not IsExportCapable(RESOURCE, 'GetPlayerByCitizenId') then return nil end

        return {
            GetPlayer = function(source)
                local ok, player = SafeCall(RESOURCE, 'GetPlayer', source)
                if not ok then return nil end
                return player
            end,
            GetPlayerByCitizenId = function(citizenid)
                local ok, player = SafeCall(RESOURCE, 'GetPlayerByCitizenId', citizenid)
                if not ok then return nil end
                return player
            end,
            GetCitizenId = function(player)
                if type(player) ~= 'table' or type(player.PlayerData) ~= 'table' then return nil end
                return player.PlayerData.citizenid
            end,
            GetJob = function(player)
                if type(player) ~= 'table' or type(player.PlayerData) ~= 'table' then return nil, nil end
                local job = player.PlayerData.job
                if type(job) ~= 'table' then return nil, nil end
                return job.name, GradeLevel(job.grade)
            end,
        }
    end

    if realm == 'client' then
        if not IsExportCapable(RESOURCE, 'GetPlayerData') then return nil end

        return {
            GetPlayerData = function()
                local ok, playerData = SafeCall(RESOURCE, 'GetPlayerData')
                if not ok or type(playerData) ~= 'table' then return nil end
                local job = playerData.job
                return {
                    citizenid = playerData.citizenid,
                    job = {
                        name = type(job) == 'table' and job.name or nil,
                        grade = type(job) == 'table' and GradeLevel(job.grade) or nil,
                    },
                }
            end,
        }
    end

    return nil
end

-- ======================================================================
-- qb-core -- CONFIRMED against qbcore-framework/qb-core's live `main`
-- branch, fetched and read directly this session (2026-08-25).
--
--   * `exports['qb-core']:GetPlayer(source)` /
--     `GetPlayerByCitizenId(citizenid)` (`server/player.lua`) return a
--     built `iface` object with `iface.PlayerData` -- CONFIRMED to carry
--     the exact same `.citizenid` / `.job = { name, label, isboss,
--     grade = { name, level, payment, isboss } }` shape as qbx_core
--     (`server/player.lua`'s job-assignment code sets these same fields;
--     unsurprising since qbx_core is a fork/successor of qb-core, but
--     verified independently rather than assumed identical).
--   * Client: qb-core has NO direct `GetPlayerData` export -- the
--     documented, CONFIRMED pattern (used by qb-target's own client.lua,
--     itself fetched this session) is
--     `exports['qb-core']:GetCoreObject()` returning the `QBCore` object,
--     then `QBCore.Functions.GetPlayerData()` (`client/functions.lua`).
--     Both steps are pcall-guarded below.
--
-- NOTE for whoever finishes shared/compat/core.lua: qbx_core's own
-- fxmanifest.lua declares `provide 'qb-core'`, so `GetResourceState
-- ('qb-core')` may resolve truthy purely because qbx_core is installed
-- (FXServer's resource-provides aliasing was not independently verified
-- against engine source this session). Config.Compat's candidate order
-- already lists qbx_core before qb-core specifically to make this safe as
-- long as candidates are tried in that order and the first successful one
-- wins -- flagged here so that ordering assumption is visible, not just
-- implied by config.lua's comment ordering.
-- ======================================================================
local function QbCoreFactory(realm)
    local RESOURCE = 'qb-core'
    if not ResourceStarted(RESOURCE) then return nil end

    if realm == 'server' then
        if not IsExportCapable(RESOURCE, 'GetPlayer') then return nil end
        if not IsExportCapable(RESOURCE, 'GetPlayerByCitizenId') then return nil end

        return {
            GetPlayer = function(source)
                local ok, player = SafeCall(RESOURCE, 'GetPlayer', source)
                if not ok then return nil end
                return player
            end,
            GetPlayerByCitizenId = function(citizenid)
                local ok, player = SafeCall(RESOURCE, 'GetPlayerByCitizenId', citizenid)
                if not ok then return nil end
                return player
            end,
            GetCitizenId = function(player)
                if type(player) ~= 'table' or type(player.PlayerData) ~= 'table' then return nil end
                return player.PlayerData.citizenid
            end,
            GetJob = function(player)
                if type(player) ~= 'table' or type(player.PlayerData) ~= 'table' then return nil, nil end
                local job = player.PlayerData.job
                if type(job) ~= 'table' then return nil, nil end
                return job.name, GradeLevel(job.grade)
            end,
        }
    end

    if realm == 'client' then
        if not IsExportCapable(RESOURCE, 'GetCoreObject') then return nil end

        return {
            GetPlayerData = function()
                local ok, core = SafeCall(RESOURCE, 'GetCoreObject')
                if not ok or type(core) ~= 'table' or type(core.Functions) ~= 'table'
                    or type(core.Functions.GetPlayerData) ~= 'function' then
                    return nil
                end

                local okData, playerData = pcall(core.Functions.GetPlayerData)
                if not okData or type(playerData) ~= 'table' then return nil end

                local job = playerData.job
                return {
                    citizenid = playerData.citizenid,
                    job = {
                        name = type(job) == 'table' and job.name or nil,
                        grade = type(job) == 'table' and GradeLevel(job.grade) or nil,
                    },
                }
            end,
        }
    end

    return nil
end

-- ======================================================================
-- es_extended -- CONFIRMED against esx-framework/esx_core's live `main`
-- branch (the `[core]/es_extended` subfolder is the actual runnable
-- resource -- its own fxmanifest.lua has no `provide`/`name` override, so
-- it deploys under the folder name `es_extended`, matching
-- Config.Compat's candidate string and every real-world install this
-- session's forum search turned up), fetched and read directly this
-- session (2026-08-25).
--
-- DISCLOSED, GENUINE SEMANTIC GAP, not glossed over: ES_EXTENDED HAS NO
-- CITIZENID / PER-CHARACTER ID CONCEPT AT ALL. Confirmed by reading
-- `server/classes/player.lua` directly: a player object's only persistent
-- identity field is `.identifier` (`self.identifier = identifier`, an
-- account-scoped Rockstar/Steam license string, e.g. `license:...`), with
-- no separate per-character key the way qb/qbx's citizenid is one. This
-- adapter's `GetCitizenId`/`GetPlayerByCitizenId` therefore use `.identifier`
-- as the closest available stable per-player key -- it is genuinely the
-- best equivalent ESX has, but it is ACCOUNT-scoped, not CHARACTER-scoped:
-- a server running a multi-character addon on top of ESX (e.g.
-- esx_multicharacter, referenced as a submodule of esx_core) may still
-- expose only one `.identifier` per Rockstar account across however many
-- characters that account has, in which case this resource's own
-- citizenid-keyed tables (k9_certifications, k9_partnerships, etc.) would
-- key on the ACCOUNT rather than the CHARACTER for an ESX server. This is
-- disclosed rather than silently pretended away; it does not affect
-- qbx_core/qb-core, both of which have a real per-character citizenid.
--
--   * `exports['es_extended']:getSharedObject()` (`shared/main.lua`,
--     loaded on both realms) returns the `ESX` object on either side.
--   * Server: `ESX.GetPlayerFromId(source)` / `GetPlayerFromIdentifier
--     (identifier)` (`server/functions.lua`) return an `xPlayer` object;
--     `xPlayer.getIdentifier()` / `xPlayer.getJob()` (`server/classes/
--     player.lua`) are OBJECT-BOUND closures (ESX's own OOP convention --
--     confirmed by reading the class constructor directly, e.g.
--     `function self.getJob() return self.job end`), so they are called
--     with NO arguments and no `:` self-passing, exactly as written below.
--     `xPlayer.job = { id, name, label, type, onDuty, grade (a bare
--     integer, NOT a nested table -- confirmed in `self.setJob`),
--     grade_name, grade_label, grade_salary, skin_male, skin_female }` --
--     note the plain-integer grade is why `GradeLevel()` above needs to
--     handle both shapes, not just qbx_core/qb-core's nested one.
--   * Client: `ESX.GetPlayerData()` (`client/functions.lua`) returns the
--     same `.identifier`/`.job` shape as `ESX.PlayerData`.
-- ======================================================================
local function EsExtendedFactory(realm)
    local RESOURCE = 'es_extended'
    if not ResourceStarted(RESOURCE) then return nil end
    if not IsExportCapable(RESOURCE, 'getSharedObject') then return nil end

    if realm == 'server' then
        return {
            GetPlayer = function(source)
                local ok, esx = SafeCall(RESOURCE, 'getSharedObject')
                if not ok or type(esx) ~= 'table' or type(esx.GetPlayerFromId) ~= 'function' then return nil end
                local okPlayer, player = pcall(esx.GetPlayerFromId, source)
                if not okPlayer then return nil end
                return player
            end,
            -- `citizenid` here is really ESX's `identifier` -- see this
            -- factory's header DISCLOSED GAP above.
            GetPlayerByCitizenId = function(citizenid)
                local ok, esx = SafeCall(RESOURCE, 'getSharedObject')
                if not ok or type(esx) ~= 'table' or type(esx.GetPlayerFromIdentifier) ~= 'function' then
                    return nil
                end
                local okPlayer, player = pcall(esx.GetPlayerFromIdentifier, citizenid)
                if not okPlayer then return nil end
                return player
            end,
            GetCitizenId = function(player)
                if type(player) ~= 'table' then return nil end
                if type(player.getIdentifier) == 'function' then
                    local ok, identifier = pcall(player.getIdentifier)
                    if ok and identifier then return identifier end
                end
                return player.identifier
            end,
            GetJob = function(player)
                if type(player) ~= 'table' then return nil, nil end
                local job
                if type(player.getJob) == 'function' then
                    local ok, result = pcall(player.getJob)
                    if ok then job = result end
                end
                job = job or player.job
                if type(job) ~= 'table' then return nil, nil end
                return job.name, GradeLevel(job.grade)
            end,
        }
    end

    if realm == 'client' then
        return {
            GetPlayerData = function()
                local ok, esx = SafeCall(RESOURCE, 'getSharedObject')
                if not ok or type(esx) ~= 'table' or type(esx.GetPlayerData) ~= 'function' then return nil end
                local okData, playerData = pcall(esx.GetPlayerData)
                if not okData or type(playerData) ~= 'table' then return nil end

                local job = playerData.job
                return {
                    citizenid = playerData.identifier,
                    job = {
                        name = type(job) == 'table' and job.name or nil,
                        grade = type(job) == 'table' and GradeLevel(job.grade) or nil,
                    },
                }
            end,
        }
    end

    return nil
end

-- ======================================================================
-- Registration. See shared/compat/target.lua's own registration block for
-- why this is guarded rather than assumed (K9Compat must load first; a
-- missing K9Compat degrades to a loud console warning, never a hard
-- resource-start error).
-- ======================================================================
if type(K9Compat) == 'table' and type(K9Compat.RegisterAdapter) == 'function' then
    K9Compat.RegisterAdapter('framework', 'qbx_core', QbxCoreFactory)
    K9Compat.RegisterAdapter('framework', 'qb-core', QbCoreFactory)
    K9Compat.RegisterAdapter('framework', 'es_extended', EsExtendedFactory)
else
    print('[John-K9] shared/compat/framework.lua: K9Compat is not available at load time -- '
        .. 'no framework adapters were registered. This means shared/compat/core.lua did not load '
        .. 'before this file; check fxmanifest.lua shared_scripts ordering.')
end
