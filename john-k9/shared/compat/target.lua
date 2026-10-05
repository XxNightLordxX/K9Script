--[[
    shared/compat/target.lua

    TARGET adapters for Config.Compat's resource-compatibility layer (see
    config.lua's `Config.Compat` block for the operator-facing contract this
    exists to satisfy). Registers one adapter per candidate listed in
    `Config.Compat.Systems.target.candidates`, in the order config.lua lists
    them: ox_target (reference), qb-target, qtarget, interact,
    sleepless_interact.

    THE CONTRACT (as given to this file, verbatim):
        K9Compat.RegisterAdapter('target', '<resourceName>', factory)
        factory(realm) -> table | nil    -- nil = present but unusable, skip me
        Required client methods (checked by core -- a miss means SKIPPED):
            AddGlobalPlayer, AddGlobalVehicle, AddGlobalObject, AddModel,
            AddSphereZone, Remove, AddLocalEntity, RemoveLocalEntity
        Required server methods: {} (none)

    ADDLOCALENTITY/REMOVELOCALENTITY -- ADDED, THE CONTRACT GAP THIS TASK
    EXISTS TO CLOSE. client/equipmentshop.lua's shop-attendant ped feature
    (added AFTER this adapter contract was first written) called
    `exports.ox_target:addLocalEntity`/`removeLocalEntity` directly, bypassing
    this whole compat layer, because those two methods were never added to
    `K9Compat.RequiredMethods.target.client` in the first place -- a feature
    built after an abstraction exists does not announce itself to that
    abstraction; only checking explicitly catches it. This is the third
    instance of exactly this shape in this project (see migration 0010's
    tables missed by the safety scripts, migration 0011's table missed by the
    database layer). Same opaque-handle convention as every other Add*/Remove
    pair in this file: `AddLocalEntity(entity, options)` returns a handle
    private to the adapter that produced it; `RemoveLocalEntity(handle)`
    accepts exactly that value back, untouched, and removes every option this
    resource itself registered for that entity (never a partial removal --
    no real call site in this resource needs one, so none is exposed).

    REMOVE()'S ARGUMENT SHAPE IS NOT PART OF THE CONTRACT AS GIVEN -- only
    the method NAME is specified. This file documents, and relies on, the
    following minimal-surface-area design: every AddGlobalPlayer/
    AddGlobalVehicle/AddGlobalObject/AddModel/AddSphereZone call below
    returns an opaque per-adapter "handle" value (its shape is private to
    each adapter and varies -- a list of names for ox_target, a zone id for
    a sphere zone, etc.), and Remove(handle) accepts EXACTLY what the
    corresponding Add* call returned, nothing else. This means core.lua's
    own wrapper (if any) must pass the Add* return value through to the
    caller UNTOUCHED, and forward it to Remove() UNTOUCHED -- never inspect
    or reshape it. This keeps the underlying target script's real removal
    primitive (which differs wildly: ox_target has five separate typed
    remove* exports, qb-target keys removal by label, sleepless_interact by
    name, qtarget likely by name) entirely encapsulated in the adapter that
    produced the handle. If a different contract is ever needed, core.lua
    and this file's Remove() implementations must change together.

    SECURITY, restated because it is non-negotiable and this file is exactly
    the kind of code that could get it wrong: nothing here grants
    permission. Every `canInteract` this resource writes (client/movement.lua,
    client/partnership.lua, client/search.lua, etc.) is a CONVENIENCE gate
    that only decides whether a menu OPTION is shown -- translating it
    faithfully to a different target script's calling convention (this
    file's main job) does not change that. The corresponding server event
    handler re-validates every real precondition independently and is the
    only authority that can make an action succeed. A hostile or buggy
    third-party target script can at worst make an option appear when it
    normally wouldn't; it cannot make the underlying action succeed, because
    this resource's server side never trusts anything the client's target
    script decided. This file does not change that boundary anywhere.

    NEVER LET A THIRD-PARTY EXPORT THROW INTO THIS RESOURCE. Every export
    access AND call below goes through the two-step shape already
    established by the now-deleted IsOxInventoryHookCapable in server/tracking.lua
    (GetResourceState checked first and unconditionally, THEN a pcall'd
    export index to confirm the method actually exists, kept separate from
    a second, later pcall around the real invocation so a capability probe
    never itself performs a side effect) -- see ResourceStarted/
    IsExportCapable/SafeCall below.

    RESEARCH: every adapter is ranked CONFIRMED (with the primary source
    actually fetched and read this session) or UNCONFIRMED (factory returns
    nil unconditionally -- present-but-unusable, never a guess). See each
    factory's own header for its ranking and sources. No export signature
    below was taken from memory.
]]

-- ======================================================================
-- Shared helpers (file-local; no new resource-globals introduced by this
-- file -- it only ever READS the pre-existing `K9Compat` global).
-- ======================================================================

--- @param resourceName string
--- @return boolean
local function ResourceStarted(resourceName)
    return GetResourceState(resourceName) == 'started'
end

--- Capability probe ONLY -- indexes the export without calling it, so
--- checking for a capability never itself performs a side effect. Mirrors
--- the now-deleted IsOxInventoryHookCapable in server/tracking.lua exactly, generalised to
--- an arbitrary resource/method pair. Per that function's own disclosed
--- limitation (restated here rather than re-derived): indexing an export is
--- understood, not independently re-verified this session, to always
--- return a callable wrapper regardless of whether the target resource
--- really registered that name -- so this is defense-in-depth against
--- `exports[resourceName]` itself throwing, not a guarantee the method
--- truly exists. The later, separate SafeCall pcall is what actually
--- catches a missing/renamed export at the point of use.
--- @param resourceName string
--- @param methodName string
--- @return boolean
local function IsExportCapable(resourceName, methodName)
    if not ResourceStarted(resourceName) then return false end

    local ok, method = pcall(function() return exports[resourceName][methodName] end)
    return ok and type(method) == 'function'
end

--- Call-time protection -- a SEPARATE pcall from IsExportCapable's,
--- wrapping the real invocation (colon-call semantics via
--- `exports[resourceName]:method(...)` are preserved by indexing then
--- calling with the exports table itself as the first argument, exactly
--- what the `:` sugar would do -- required here because resourceName is a
--- runtime value, not a literal, so the normal `exports.name:method(...)`
--- syntax can't be written directly). Re-checks GetResourceState first
--- (unconditional, per the same convention), so a resource that stopped
--- between detection and this call degrades to a clean `false` instead of
--- a thrown error reaching this resource's own call stack.
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

--- Normalizes a single hash-shaped option table OR an array of them into an
--- array, mirroring ox_target's/sleepless_interact's own `checkOptions`
--- logic WITHOUT depending on `table.type` (a CitizenFX Lua54 runtime
--- extension, not part of plain Lua 5.4 -- using it here would make this
--- file untestable under tests/run.sh's plain `lua5.4` interpreter, see
--- DEVELOPER_REFERENCE.md).
--- @param options table
--- @return table[]
local function NormalizeOptions(options)
    if type(options) ~= 'table' then return {} end
    if options[1] ~= nil then return options end
    if options.label or options.name then return { options } end
    return options
end

--- @param options table[]
--- @return string[]
local function ExtractNames(options)
    local names = {}
    for i = 1, #options do
        local name = options[i].name or options[i].label
        if name then names[#names + 1] = name end
    end
    return names
end

--- @param options table[]
--- @return string[]
local function ExtractLabels(options)
    local labels = {}
    for i = 1, #options do
        local label = options[i].label or options[i].name
        if label then labels[#labels + 1] = label end
    end
    return labels
end

--- Largest per-option `.distance` seen, falling back to `fallback`. Used
--- wherever a target script wants ONE outer distance for a batch of
--- options that (in this resource's own ox_target-shaped call sites) each
--- carry their own `.distance` -- taking the max means no individual
--- option's configured distance is ever silently clamped down to a smaller
--- outer default (see qb-target's own SetOptions, which clamps a per-option
--- distance DOWN to the outer wrapper's if the wrapper's is smaller).
--- @param options table[]
--- @param fallback number?
--- @return number
local function MaxDistance(options, fallback)
    local max = fallback
    for i = 1, #options do
        local d = options[i].distance
        if type(d) == 'number' and (not max or d > max) then
            max = d
        end
    end
    return max or 3.0
end

-- ======================================================================
-- ox_target -- REFERENCE adapter. Declared as a hard `dependencies` entry
-- in fxmanifest.lua, so it is always present; this adapter still performs
-- the full runtime capability check rather than assuming that (a stale
-- pinned build, or a fork, can both look identical to fxmanifest.lua at
-- resource-start time -- see fxmanifest.lua's own header on why a version
-- pin can't substitute for a runtime check).
--
-- CONFIRMED against overextended/ox_target's live `main` branch,
-- `client/api.lua`, fetched and read directly this session (2026-08-25):
-- addGlobalPlayer/addGlobalVehicle/addGlobalObject(options),
-- addModel(models, options), addSphereZone(data) -- data = { coords,
-- radius, debug?, options }, returns a numeric zone id. Removal:
-- removeGlobalPlayer/removeGlobalVehicle/removeGlobalObject(names),
-- removeModel(models, names), removeZone(id, suppressWarning).
--
-- NO TRANSLATION NEEDED: every option this resource writes (name, icon,
-- label, distance, groups, canInteract(entity, distance, coords, name),
-- onSelect(data) with data.entity) is already ox_target's own native
-- shape, since this resource was built against ox_target directly. This
-- adapter is a thin, faithful pass-through plus the handle bookkeeping
-- Remove() needs.
-- ======================================================================
local function OxTargetFactory(realm)
    local RESOURCE = 'ox_target'
    if not ResourceStarted(RESOURCE) then return nil end
    if realm == 'server' then return {} end
    if realm ~= 'client' then return nil end

    local REQUIRED_EXPORTS = {
        'addGlobalPlayer', 'addGlobalVehicle', 'addGlobalObject', 'addModel', 'addSphereZone',
        'removeGlobalPlayer', 'removeGlobalVehicle', 'removeGlobalObject', 'removeModel', 'removeZone',
        'addLocalEntity', 'removeLocalEntity',
    }
    for i = 1, #REQUIRED_EXPORTS do
        if not IsExportCapable(RESOURCE, REQUIRED_EXPORTS[i]) then return nil end
    end

    return {
        AddGlobalPlayer = function(options)
            local ok = SafeCall(RESOURCE, 'addGlobalPlayer', options)
            if not ok then return nil end
            return { kind = 'player', names = ExtractNames(NormalizeOptions(options)) }
        end,
        AddGlobalVehicle = function(options)
            local ok = SafeCall(RESOURCE, 'addGlobalVehicle', options)
            if not ok then return nil end
            return { kind = 'vehicle', names = ExtractNames(NormalizeOptions(options)) }
        end,
        AddGlobalObject = function(options)
            local ok = SafeCall(RESOURCE, 'addGlobalObject', options)
            if not ok then return nil end
            return { kind = 'object', names = ExtractNames(NormalizeOptions(options)) }
        end,
        AddModel = function(models, options)
            local ok = SafeCall(RESOURCE, 'addModel', models, options)
            if not ok then return nil end
            return { kind = 'model', models = models, names = ExtractNames(NormalizeOptions(options)) }
        end,
        AddSphereZone = function(data)
            local ok, zoneId = SafeCall(RESOURCE, 'addSphereZone', data)
            if not ok or zoneId == nil then return nil end
            return { kind = 'zone', id = zoneId }
        end,
        Remove = function(handle)
            if type(handle) ~= 'table' then return end
            if handle.kind == 'player' then
                SafeCall(RESOURCE, 'removeGlobalPlayer', handle.names)
            elseif handle.kind == 'vehicle' then
                SafeCall(RESOURCE, 'removeGlobalVehicle', handle.names)
            elseif handle.kind == 'object' then
                SafeCall(RESOURCE, 'removeGlobalObject', handle.names)
            elseif handle.kind == 'model' then
                SafeCall(RESOURCE, 'removeModel', handle.models, handle.names)
            elseif handle.kind == 'zone' then
                SafeCall(RESOURCE, 'removeZone', handle.id, true)
            end
        end,

        --- CONFIRMED against overextended/ox_target's live `main` branch,
        --- `client/api.lua` (`api.addLocalEntity(arr, options)`, this
        --- session's fetch): takes a raw, non-networked entity handle (or
        --- array of them) plus the same option shape every other Add* here
        --- already uses -- no translation needed, same as this factory's
        --- other methods.
        --- @param entity number
        --- @param options table
        --- @return table|nil handle
        AddLocalEntity = function(entity, options)
            local ok = SafeCall(RESOURCE, 'addLocalEntity', entity, options)
            if not ok then return nil end
            return { kind = 'localEntity', entity = entity }
        end,

        --- CONFIRMED (`api.removeLocalEntity(arr, options)`): called here
        --- with NO `options` argument, which its own source
        --- (`if options then removeTarget(...) end; if not options or
        --- #localEntities[entity] == 0 then localEntities[entity] = nil
        --- end`) confirms clears EVERY option this resource registered for
        --- that entity, not just one -- the right choice for this
        --- adapter's one real caller (client/equipmentshop.lua), which owns
        --- the entity outright and always tears it down completely, never
        --- partially.
        --- @param handle table -- exactly what AddLocalEntity returned
        RemoveLocalEntity = function(handle)
            if type(handle) ~= 'table' then return end
            SafeCall(RESOURCE, 'removeLocalEntity', handle.entity)
        end,
    }
end

-- ======================================================================
-- qb-target -- CONFIRMED against qbcore-framework/qb-target's live `main`
-- branch, `registration.lua` + `client.lua`, fetched and read directly this
-- session (2026-08-25).
--
-- THE HARD PART, confirmed by reading qb-target's own source rather than
-- assumed:
--   * qb-target keys an option by its OWN `label` field
--     (`registration.lua`'s SetOptions: `tbl[v.label] = v`) -- there is no
--     separate machine `name` the way ox_target has. Every real call site
--     in this resource gives each option a distinct label, so this is safe
--     in practice; disclosed rather than silently assumed for a future
--     call site that might not.
--   * `canInteract` is invoked as `data.canInteract(entity, distance,
--     data)` -- THREE arguments, the third being the OPTION TABLE ITSELF,
--     never a coords vector (`client.lua`'s CheckOptions). Every
--     `canInteract` this resource writes is authored against ox_target's
--     `(entity, distance, coords, name)` signature (see
--     client/movement.lua:723, client/partnership.lua:559,
--     client/search.lua:292/321, client/fetch.lua:493/519,
--     client/kennel.lua:359, client/medkit.lua:169,
--     client/inventory.lua:238, client/vehicle.lua:437/461,
--     client/movement.lua:1647/1676). Calling one of these unmodified
--     under qb-target would hand it the wrong third argument (the option
--     table instead of coords) and a nil fourth one. Bridged below: the
--     wrapper re-derives `coords` via `GetEntityCoords(entity)` (the same
--     value ox_target's own raycast would have measured) and `name` from
--     the option's own name/label, then calls the ORIGINAL predicate with
--     the signature it was actually written against.
--   * `onSelect`/`action` -- qb-target calls `data.action(data.entity)`
--     (`client.lua`'s `selectTarget` NUI callback) -- entity ALONE, not a
--     data table. ox_target calls `option.onSelect(data)` where every real
--     call site in this resource reads `data.entity` (see the same files
--     as above). Bridged by wrapping `action` to rebuild a
--     `{ entity = entity }` table and calling the original `onSelect` with
--     that -- the one field this resource's onSelect handlers actually
--     read.
--   * `.groups` (ox_target's own job/grade filter field, used by
--     client/equipmentshop.lua:98, shape `{ [jobName] = minGradeLevel }`
--     per qbx_core's own `shared/functions.lua` `HasPlayerGotGroup`) maps
--     directly onto qb-target's `.job` field, which CONFIRMED
--     (`client.lua`'s JobCheck) uses the exact same
--     `{ [jobName] = minGradeLevel }` shape compared against
--     `PlayerData.job.grade.level`. Renamed, not reshaped.
--   * Zones: qb-target has no direct sphere-zone equivalent; translated to
--     `AddCircleZone(name, center, radius, options, targetoptions)`
--     (CONFIRMED, `registration.lua`), where `targetoptions.distance`
--     acts as a fallback/ceiling for any option missing its own
--     `.distance`. CORRECTED (2026-08-26): an earlier revision of this
--     comment named client/equipmentshop.lua as "this resource's one
--     sphere-zone call site" with no per-option distance set. That stopped
--     being true when that file's shop-attendant ped feature was rebuilt
--     around a real, visible ped and `AddLocalEntity` instead of a bare
--     zone -- see this file's own header, "A REAL PED, NOT A BARE SPHERE,"
--     and client/equipmentshop.lua's own header for the history.
--     `AddSphereZone`/`Remove` remain full, required, tested contract
--     methods (core.lua's RequiredMethods.target.client, exercised by
--     tests/compattarget_spec.lua) and this factory still implements them
--     faithfully -- but NEITHER currently has a real call site anywhere in
--     this resource's own client code. `MaxDistance` falling back to the
--     zone's own radius (rather than a smaller per-option default) is this
--     factory's own general-purpose translation behaviour for whatever
--     future caller needs a real zone on this backend, not something a
--     current call site's own zero-distance options exercises.
--   * Removal is by label (`RemoveGlobalPlayer`/`RemoveGlobalVehicle`/
--     `RemoveGlobalObject`/`RemoveTargetModel` all take a label or label
--     array) and by the generated zone name (`RemoveZone`), both CONFIRMED
--     in `registration.lua`.
-- ======================================================================
local function QbTargetFactory(realm)
    local RESOURCE = 'qb-target'
    if not ResourceStarted(RESOURCE) then return nil end
    if realm == 'server' then return {} end
    if realm ~= 'client' then return nil end

    local REQUIRED_EXPORTS = {
        'AddGlobalPlayer', 'AddGlobalVehicle', 'AddGlobalObject', 'AddTargetModel', 'AddCircleZone',
        'RemoveGlobalPlayer', 'RemoveGlobalVehicle', 'RemoveGlobalObject', 'RemoveTargetModel', 'RemoveZone',
        'AddTargetEntity', 'RemoveTargetEntity',
    }
    for i = 1, #REQUIRED_EXPORTS do
        if not IsExportCapable(RESOURCE, REQUIRED_EXPORTS[i]) then return nil end
    end

    --- Translates ONE ox_target-shaped option into a qb-target-shaped one.
    --- See this factory's header above for exactly what changes and why.
    --- @param option table
    --- @return table
    local function TranslateOption(option)
        local translated = {}
        for k, v in pairs(option) do
            translated[k] = v
        end

        translated.label = option.label or option.name

        if option.groups then
            translated.job = option.groups
            translated.groups = nil
        end

        if option.canInteract then
            local original = option.canInteract
            local optionName = option.name or option.label
            translated.canInteract = function(entity, distance, _qbTargetOptionData)
                local coords = entity and GetEntityCoords(entity) or nil
                local ok, result = pcall(original, entity, distance, coords, optionName)
                return ok and result or false
            end
        end

        if option.onSelect then
            local original = option.onSelect
            translated.action = function(entity)
                original({ entity = entity })
            end
            translated.onSelect = nil
        end

        return translated
    end

    --- @param options table
    --- @return table[]
    local function TranslateOptions(options)
        local normalized = NormalizeOptions(options)
        local out = {}
        for i = 1, #normalized do
            out[i] = TranslateOption(normalized[i])
        end
        return out
    end

    local zoneCounter = 0
    local function NextZoneName()
        zoneCounter = zoneCounter + 1
        return ('john-k9:compat:zone:%d'):format(zoneCounter)
    end

    return {
        AddGlobalPlayer = function(options)
            local normalized = NormalizeOptions(options)
            local ok = SafeCall(RESOURCE, 'AddGlobalPlayer',
                { distance = MaxDistance(normalized), options = TranslateOptions(normalized) })
            if not ok then return nil end
            return { kind = 'player', labels = ExtractLabels(normalized) }
        end,
        AddGlobalVehicle = function(options)
            local normalized = NormalizeOptions(options)
            local ok = SafeCall(RESOURCE, 'AddGlobalVehicle',
                { distance = MaxDistance(normalized), options = TranslateOptions(normalized) })
            if not ok then return nil end
            return { kind = 'vehicle', labels = ExtractLabels(normalized) }
        end,
        AddGlobalObject = function(options)
            local normalized = NormalizeOptions(options)
            local ok = SafeCall(RESOURCE, 'AddGlobalObject',
                { distance = MaxDistance(normalized), options = TranslateOptions(normalized) })
            if not ok then return nil end
            return { kind = 'object', labels = ExtractLabels(normalized) }
        end,
        AddModel = function(models, options)
            local normalized = NormalizeOptions(options)
            local ok = SafeCall(RESOURCE, 'AddTargetModel', models,
                { distance = MaxDistance(normalized), options = TranslateOptions(normalized) })
            if not ok then return nil end
            return { kind = 'model', models = models, labels = ExtractLabels(normalized) }
        end,
        AddSphereZone = function(data)
            local normalized = NormalizeOptions(data and data.options or {})
            local name = NextZoneName()
            local ok = SafeCall(RESOURCE, 'AddCircleZone', name, data.coords, data.radius,
                { debugPoly = data.debug or false },
                { options = TranslateOptions(normalized), distance = MaxDistance(normalized, data.radius) })
            if not ok then return nil end
            return { kind = 'zone', id = name }
        end,
        Remove = function(handle)
            if type(handle) ~= 'table' then return end
            if handle.kind == 'player' then
                SafeCall(RESOURCE, 'RemoveGlobalPlayer', handle.labels)
            elseif handle.kind == 'vehicle' then
                SafeCall(RESOURCE, 'RemoveGlobalVehicle', handle.labels)
            elseif handle.kind == 'object' then
                SafeCall(RESOURCE, 'RemoveGlobalObject', handle.labels)
            elseif handle.kind == 'model' then
                SafeCall(RESOURCE, 'RemoveTargetModel', handle.models, handle.labels)
            elseif handle.kind == 'zone' then
                SafeCall(RESOURCE, 'RemoveZone', handle.id)
            end
        end,

        --- CONFIRMED against qbcore-framework/qb-target's live `main`
        --- branch, `registration.lua` (`AddTargetEntity(entities,
        --- parameters)`, this session's fetch). For a NON-networked entity
        --- (`NetworkGetEntityIsNetworked(entity) == false` -- true for
        --- every ped this resource's own client/equipmentshop.lua spawns,
        --- see `CreatePed(..., false, false)`), qb-target keys its options
        --- table by the RAW entity handle itself -- the exact real
        --- equivalent of ox_target's addLocalEntity for this resource's one
        --- actual use case. Same `{ distance, options }` shape and the same
        --- label-keyed, distance-clamping `SetOptions` helper as
        --- AddGlobalPlayer/AddCircleZone above, so this reuses the same
        --- `TranslateOptions`/`MaxDistance` helpers unchanged.
        --- @param entity number
        --- @param options table
        --- @return table|nil handle
        AddLocalEntity = function(entity, options)
            local normalized = NormalizeOptions(options)
            local ok = SafeCall(RESOURCE, 'AddTargetEntity', entity,
                { distance = MaxDistance(normalized), options = TranslateOptions(normalized) })
            if not ok then return nil end
            return { kind = 'entity', entity = entity, labels = ExtractLabels(normalized) }
        end,

        --- CONFIRMED (`RemoveTargetEntity(entities, labels)`): `labels` is
        --- OPTIONAL -- passing it removes only those named options; omitting
        --- it clears the entity's entire options entry. DELIBERATE CHOICE,
        --- not an oversight: called here with NO labels, because this
        --- adapter's one real caller (client/equipmentshop.lua) created and
        --- owns this entity outright and always tears it down completely on
        --- despawn -- never a partial removal shared with some other
        --- resource's own targeting of the same entity. A future caller
        --- that DOES need scoped removal on a shared entity would need a
        --- different method, not a change to this one.
        --- @param handle table -- exactly what AddLocalEntity returned
        RemoveLocalEntity = function(handle)
            if type(handle) ~= 'table' then return end
            SafeCall(RESOURCE, 'RemoveTargetEntity', handle.entity)
        end,
    }
end

-- ======================================================================
-- qtarget -- CONFIRMED against overextended/qtarget's OWN live `main`
-- branch, `client.lua` + `init.lua`, fetched and read directly this session
-- (2026-08-25) -- this REPLACES an earlier revision of this section that
-- inferred qtarget's shape from ox_target's own `client/compat/qtarget.lua`
-- drop-in shim rather than qtarget's real source (that shim is written to
-- imitate qtarget for OTHER resources' benefit; reading it tells you what
-- ox_target normalizes qtarget's calling convention INTO, not what qtarget
-- itself actually does -- exactly the gap that made the earlier revision's
-- `canInteract` handling wrong, see below).
--
-- Real qtarget's export names (CONFIRMED, `client.lua`): Player/
-- RemovePlayer, Vehicle/RemoveVehicle, Object/RemoveObject, AddTargetModel/
-- RemoveTargetModel(models, labels), AddCircleZone(name, center, radius,
-- options, targetoptions), a SINGLE SHARED RemoveZone(name) (not typed per
-- zone kind), and AddTargetEntity(entities, parameters)/RemoveTargetEntity
-- (entities, labels) -- same names/shapes as qb-target's own (see that
-- factory's header), labels optional on removal, omitting them clears
-- everything. Call shape per option: `{ distance = N, options = { {...} }
-- }` (outer distance is a fallback only, never a clamp, unlike qb-target).
-- Field renames: `onSelect` -> `action` (straight pass-through, one
-- argument, the entity handle), `groups` -> `job` (same shape as
-- qb-target's `.job` above).
--
-- THE BUG THE SHIM COULD NOT HAVE CAUGHT, FOUND AND FIXED HERE:
-- `canInteract` is invoked by real qtarget as `data.canInteract(entity,
-- distance, data)` -- THREE arguments, `data` being the OPTION TABLE
-- ITSELF, the SAME convention as qb-target and NOT ox_target's own
-- `(entity, distance, coords, name)` this resource's every `canInteract` is
-- actually written against. An earlier revision of this adapter passed
-- `canInteract` through unchanged on the (reasonable-looking, but WRONG)
-- theory that the ox_target compat shim's silence on the field meant qtarget
-- either used ox_target's own convention or ignored the field entirely --
-- neither was true. Fixed identically to `QbTargetFactory`'s own bridge
-- below: re-derive `coords` via `GetEntityCoords(entity)` and `name` from
-- the option's own name/label, then call the ORIGINAL predicate with the
-- signature it was actually written against.
-- ======================================================================
local function QtargetFactory(realm)
    local RESOURCE = 'qtarget'
    if not ResourceStarted(RESOURCE) then return nil end
    if realm == 'server' then return {} end
    if realm ~= 'client' then return nil end

    local REQUIRED_EXPORTS = {
        'Player', 'Vehicle', 'Object', 'AddTargetModel', 'AddCircleZone',
        'RemovePlayer', 'RemoveVehicle', 'RemoveObject', 'RemoveTargetModel', 'RemoveZone',
        'AddTargetEntity', 'RemoveTargetEntity',
    }
    for i = 1, #REQUIRED_EXPORTS do
        if not IsExportCapable(RESOURCE, REQUIRED_EXPORTS[i]) then return nil end
    end

    --- Translates ONE ox_target-shaped option into a real-qtarget-shaped
    --- one. See this factory's header for exactly what changes and why --
    --- in particular the `canInteract` bridge, CONFIRMED necessary against
    --- qtarget's own source this session (not inferred from the ox_target
    --- shim, which normalizes this away and so cannot be used to confirm
    --- qtarget's own real calling convention).
    --- @param option table
    --- @return table
    local function TranslateOption(option)
        local translated = {}
        for k, v in pairs(option) do
            translated[k] = v
        end

        translated.name = option.name or option.label

        if option.groups then
            translated.job = option.groups
            translated.groups = nil
        end

        if option.canInteract then
            local original = option.canInteract
            local optionName = option.name or option.label
            translated.canInteract = function(entity, distance, _qtargetOptionData)
                local coords = entity and GetEntityCoords(entity) or nil
                local ok, result = pcall(original, entity, distance, coords, optionName)
                return ok and result or false
            end
        end

        if option.onSelect then
            translated.action = option.onSelect
            translated.onSelect = nil
        end

        return translated
    end

    --- @param options table
    --- @return table[]
    local function TranslateOptions(options)
        local normalized = NormalizeOptions(options)
        local out = {}
        for i = 1, #normalized do
            out[i] = TranslateOption(normalized[i])
        end
        return out
    end

    local zoneCounter = 0
    local function NextZoneName()
        zoneCounter = zoneCounter + 1
        return ('john-k9:compat:zone:%d'):format(zoneCounter)
    end

    return {
        AddGlobalPlayer = function(options)
            local normalized = NormalizeOptions(options)
            local ok = SafeCall(RESOURCE, 'Player',
                { distance = MaxDistance(normalized), options = TranslateOptions(normalized) })
            if not ok then return nil end
            return { kind = 'player', names = ExtractNames(normalized) }
        end,
        AddGlobalVehicle = function(options)
            local normalized = NormalizeOptions(options)
            local ok = SafeCall(RESOURCE, 'Vehicle',
                { distance = MaxDistance(normalized), options = TranslateOptions(normalized) })
            if not ok then return nil end
            return { kind = 'vehicle', names = ExtractNames(normalized) }
        end,
        AddGlobalObject = function(options)
            local normalized = NormalizeOptions(options)
            local ok = SafeCall(RESOURCE, 'Object',
                { distance = MaxDistance(normalized), options = TranslateOptions(normalized) })
            if not ok then return nil end
            return { kind = 'object', names = ExtractNames(normalized) }
        end,
        AddModel = function(models, options)
            local normalized = NormalizeOptions(options)
            local ok = SafeCall(RESOURCE, 'AddTargetModel', models,
                { distance = MaxDistance(normalized), options = TranslateOptions(normalized) })
            if not ok then return nil end
            return { kind = 'model', models = models, names = ExtractNames(normalized) }
        end,
        AddSphereZone = function(data)
            local normalized = NormalizeOptions(data and data.options or {})
            local name = NextZoneName()
            local ok = SafeCall(RESOURCE, 'AddCircleZone', name, data.coords, data.radius,
                { debugPoly = data.debug or false },
                { options = TranslateOptions(normalized), distance = MaxDistance(normalized, data.radius) })
            if not ok then return nil end
            return { kind = 'zone', id = name }
        end,
        Remove = function(handle)
            if type(handle) ~= 'table' then return end
            if handle.kind == 'player' then
                SafeCall(RESOURCE, 'RemovePlayer', handle.names)
            elseif handle.kind == 'vehicle' then
                SafeCall(RESOURCE, 'RemoveVehicle', handle.names)
            elseif handle.kind == 'object' then
                SafeCall(RESOURCE, 'RemoveObject', handle.names)
            elseif handle.kind == 'model' then
                SafeCall(RESOURCE, 'RemoveTargetModel', handle.models, handle.names)
            elseif handle.kind == 'zone' then
                SafeCall(RESOURCE, 'RemoveZone', handle.id)
            end
        end,

        --- CONFIRMED against overextended/qtarget's own `main` branch
        --- (`AddTargetEntity(entities, parameters)`, this session's fetch):
        --- same name and `{ distance, options }` shape as qb-target's own
        --- (see that factory's header) -- reuses the same
        --- `TranslateOptions`/`MaxDistance` helpers unchanged.
        --- @param entity number
        --- @param options table
        --- @return table|nil handle
        AddLocalEntity = function(entity, options)
            local normalized = NormalizeOptions(options)
            local ok = SafeCall(RESOURCE, 'AddTargetEntity', entity,
                { distance = MaxDistance(normalized), options = TranslateOptions(normalized) })
            if not ok then return nil end
            return { kind = 'entity', entity = entity, names = ExtractNames(normalized) }
        end,

        --- CONFIRMED (`RemoveTargetEntity(entities, labels)`): `labels` is
        --- OPTIONAL, omitting it clears the entity's entire options entry --
        --- same DELIBERATE choice as `QbTargetFactory`'s identical method:
        --- this adapter's one real caller
        --- (client/equipmentshop.lua) owns the entity outright and always
        --- tears it down completely on despawn.
        --- @param handle table -- exactly what AddLocalEntity returned
        RemoveLocalEntity = function(handle)
            if type(handle) ~= 'table' then return end
            SafeCall(RESOURCE, 'RemoveTargetEntity', handle.entity)
        end,
    }
end

-- ======================================================================
-- interact -- UNCONFIRMED AS A TARGET SYSTEM, AND CONFIRMED NOT TO BE
-- sleepless_interact UNDER ANOTHER NAME. Re-verified (2026-08-25): the
-- resource actually published under the bare export namespace `interact`
-- is a small, unrelated project with a completely different API surface
-- (its own `addNewTarget()`-shaped exports, nothing resembling
-- addGlobalPlayer/addLocalEntity/etc) -- it is NOT a rename or fork of
-- sleepless_interact, and this file's two candidates are correctly kept
-- separate rather than merged or aliased. Its real API could not be
-- confirmed as a genuine targeting-system match worth building an adapter
-- against.
--
-- A candidate that cannot be confirmed against a primary source returns
-- nil unconditionally here -- present in Config.Compat's candidate list (so
-- an operator who DOES run a resource genuinely named `interact` sees it
-- attempted and skipped, not silently ignored), but never treated as
-- usable on a guessed export surface. If a real target for this candidate
-- name is identified later, replace this factory's body with a real
-- implementation following the same pattern as the adapters above -- do
-- not fill in exports.interact:... calls without independently confirming
-- them the same way qb-target/sleepless_interact were confirmed above.
-- @param _realm 'client' | 'server'
-- ======================================================================
local function InteractFactory(_realm)
    return nil
end

-- ======================================================================
-- sleepless_interact -- CONFIRMED against Sleepless-Development/
-- sleepless_interact's live `main` branch, `client/api.lua` +
-- `client/main.lua`, fetched and read directly this session (2026-08-25).
--
-- GOOD NEWS: addGlobalPlayer/addGlobalVehicle/addGlobalObject(options) and
-- addModel(models, options) are BYTE-FOR-BYTE compatible with ox_target's
-- own shape for every field this resource uses -- CONFIRMED, not assumed:
--   * `canInteract` is invoked as `(entity, distance, coords, name)`
--     (`client/main.lua`'s `getCanInteractCached`/the `select` NUI
--     callback) -- the exact signature every canInteract in this resource
--     is written against. NO signature bridging needed, unlike qb-target.
--   * `onSelect` is invoked with `utils.getResponse(option)`
--     (`client/modules/utils.lua`), which CONFIRMED returns a clone of the
--     option table with `.entity` set to the interacted entity -- the same
--     `data.entity` shape every onSelect in this resource already reads.
--   * `.groups` is read directly by the same field name
--     (`client/main.lua`'s `filterValidOptions`: `option.groups`) -- no
--     rename needed, unlike qb-target/qtarget.
--   * Removal is by name (`removeGlobalPlayer`/`removeGlobalVehicle`/
--     `removeGlobalObject`/`removeModel`), the exact same `.name` field
--     ox_target's own removal uses.
--   * `addLocalEntity(entityIds, options)`/`removeLocalEntity(entityIds,
--     remove)` are real, confirmed exports, byte-identical in shape to
--     ox_target's own (see this factory's AddLocalEntity/RemoveLocalEntity
--     below). ONE CONFIRMED TRAP, deliberately NOT triggered by this
--     adapter: setting `option.qtarget = true` on a translated option
--     silently switches this backend's own `onSelect` to receiving a bare
--     entity handle instead of the `{ entity = ... }` table every onSelect
--     in this resource actually reads -- this adapter's methods never set
--     that field (they pass options straight through, unlike
--     qb-target's/qtarget's TranslateOption, which never touches it
--     either), so this trap does not apply here, but it is exactly the kind
--     of thing a future edit to this factory could reintroduce by accident.
--
-- DISCLOSED, UNVERIFIED UNKNOWN: sleepless_interact's own resource manifest
-- declares `provides { 'ox_target', 'qtarget' }` (so scripts written against
-- either of those exports work unmodified against a sleepless_interact
-- install). Whether that makes `GetResourceState('ox_target')`/
-- `GetResourceState('qtarget')` report `'started'` when ONLY
-- sleepless_interact is actually running -- which could affect which
-- candidate this file's own detection walk reaches first -- was not
-- independently confirmed this session. The failure mode is bounded either
-- way, not solved blind: `OxTargetFactory`/`QtargetFactory` each still
-- independently probe for THEIR OWN exact export names
-- (`addGlobalPlayer`/`Player`/etc, camelCase vs PascalCase, both absent from
-- sleepless_interact's real export list), so even if `GetResourceState`
-- reports `'started'` for a name sleepless_interact merely `provides`,
-- `VerifyMethods` in core.lua still rejects that candidate for missing
-- methods and detection moves on -- it does not silently misdetect as a
-- working ox_target/qtarget. Recorded here as an open question for whoever
-- next has a live install to check, not treated as solved.
--
-- ONE GENUINE GAP: sleepless_interact has NO sphere-zone primitive. Its
-- nearest equivalent is `addCoords(coords, options)`
-- (CONFIRMED, `client/api.lua`), which places options at a fixed WORLD
-- POINT and derives each option's own interaction range from that OPTION's
-- OWN `.distance` field (`distanceSq = option.distance^2`, defaulting to
-- 2m if unset) -- there is no separate "zone radius" distinct from the
-- per-option distance the way ox_target's addSphereZone has. Bridged by
-- injecting `data.radius` as each translated option's `.distance` when
-- the option does not already specify its own. CORRECTED (2026-08-26): an
-- earlier revision of this comment named client/equipmentshop.lua as "this
-- resource's one sphere-zone call site," with a fixed 1.5m radius and no
-- per-option distance, as the reason this bridging matters in practice.
-- That stopped being true when that file's shop-attendant ped feature was
-- rebuilt around a real, visible ped and `AddLocalEntity` instead of a
-- bare zone (see this file's own header, "A REAL PED, NOT A BARE SPHERE")
-- -- `AddSphereZone` currently has no real caller anywhere in this
-- resource; this bridging behaviour is exercised only by
-- tests/compattarget_spec.lua today, kept correct and faithful for
-- whichever future caller needs a real sphere zone on this backend.
-- ======================================================================
local function SleeplessInteractFactory(realm)
    local RESOURCE = 'sleepless_interact'
    if not ResourceStarted(RESOURCE) then return nil end
    if realm == 'server' then return {} end
    if realm ~= 'client' then return nil end

    local REQUIRED_EXPORTS = {
        'addGlobalPlayer', 'addGlobalVehicle', 'addGlobalObject', 'addModel', 'addCoords',
        'removeGlobalPlayer', 'removeGlobalVehicle', 'removeGlobalObject', 'removeModel', 'removeCoords',
        'addLocalEntity', 'removeLocalEntity',
    }
    for i = 1, #REQUIRED_EXPORTS do
        if not IsExportCapable(RESOURCE, REQUIRED_EXPORTS[i]) then return nil end
    end

    return {
        AddGlobalPlayer = function(options)
            local ok = SafeCall(RESOURCE, 'addGlobalPlayer', options)
            if not ok then return nil end
            return { kind = 'player', names = ExtractNames(NormalizeOptions(options)) }
        end,
        AddGlobalVehicle = function(options)
            local ok = SafeCall(RESOURCE, 'addGlobalVehicle', options)
            if not ok then return nil end
            return { kind = 'vehicle', names = ExtractNames(NormalizeOptions(options)) }
        end,
        AddGlobalObject = function(options)
            local ok = SafeCall(RESOURCE, 'addGlobalObject', options)
            if not ok then return nil end
            return { kind = 'object', names = ExtractNames(NormalizeOptions(options)) }
        end,
        AddModel = function(models, options)
            local ok = SafeCall(RESOURCE, 'addModel', models, options)
            if not ok then return nil end
            return { kind = 'model', models = models, names = ExtractNames(NormalizeOptions(options)) }
        end,
        AddSphereZone = function(data)
            local normalized = NormalizeOptions(data and data.options or {})
            local translated = {}
            for i = 1, #normalized do
                local option = {}
                for k, v in pairs(normalized[i]) do
                    option[k] = v
                end
                option.distance = option.distance or data.radius
                translated[i] = option
            end

            local ok, id = SafeCall(RESOURCE, 'addCoords', data.coords, translated)
            if not ok or id == nil then return nil end
            return { kind = 'coords', id = id }
        end,
        Remove = function(handle)
            if type(handle) ~= 'table' then return end
            if handle.kind == 'player' then
                SafeCall(RESOURCE, 'removeGlobalPlayer', handle.names)
            elseif handle.kind == 'vehicle' then
                SafeCall(RESOURCE, 'removeGlobalVehicle', handle.names)
            elseif handle.kind == 'object' then
                SafeCall(RESOURCE, 'removeGlobalObject', handle.names)
            elseif handle.kind == 'model' then
                SafeCall(RESOURCE, 'removeModel', handle.models, handle.names)
            elseif handle.kind == 'coords' then
                SafeCall(RESOURCE, 'removeCoords', handle.id)
            end
        end,

        --- CONFIRMED against Sleepless-Development/sleepless_interact's
        --- live `main` branch, `client/api.lua` (`interact.addLocalEntity
        --- (entityIds, options)`, this session's fetch, lines 484-498):
        --- byte-for-byte the same shape as ox_target's own addLocalEntity --
        --- a raw (non-networked) entity handle plus the same option array
        --- this factory's other Add* methods already pass through
        --- unmodified. No translation needed.
        --- @param entity number
        --- @param options table
        --- @return table|nil handle
        AddLocalEntity = function(entity, options)
            local ok = SafeCall(RESOURCE, 'addLocalEntity', entity, options)
            if not ok then return nil end
            return { kind = 'localEntity', entity = entity }
        end,

        --- CONFIRMED (`interact.removeLocalEntity(entityIds, remove)`,
        --- lines 503-529): `remove` is OPTIONAL -- "a single option name or
        --- array of names to remove, or nil to remove all for the resource"
        --- (the function's own doc comment, quoted verbatim). Called here
        --- with NO `remove` argument, matching this factory's other Remove
        --- methods and this adapter's one real caller
        --- (client/equipmentshop.lua), which owns the entity outright and
        --- always tears it down completely on despawn.
        --- @param handle table -- exactly what AddLocalEntity returned
        RemoveLocalEntity = function(handle)
            if type(handle) ~= 'table' then return end
            SafeCall(RESOURCE, 'removeLocalEntity', handle.entity)
        end,
    }
end

-- ======================================================================
-- Registration. Guarded rather than assumed: this file has no control over
-- fxmanifest.lua's shared_scripts ordering, and shared/compat/core.lua,
-- which defines the `K9Compat` global this file only ever READS, must load
-- before this file. A missing K9Compat is a loud console warning and a
-- no-op registration pass, never a hard resource-start error -- FAIL
-- CLOSED, matching this file's own "never let a third-party throw into
-- this resource" posture applied to a load-order mistake instead.
-- ======================================================================
if type(K9Compat) == 'table' and type(K9Compat.RegisterAdapter) == 'function' then
    K9Compat.RegisterAdapter('target', 'ox_target', OxTargetFactory)
    K9Compat.RegisterAdapter('target', 'qb-target', QbTargetFactory)
    K9Compat.RegisterAdapter('target', 'qtarget', QtargetFactory)
    K9Compat.RegisterAdapter('target', 'interact', InteractFactory)
    K9Compat.RegisterAdapter('target', 'sleepless_interact', SleeplessInteractFactory)
else
    print('[John-K9] shared/compat/target.lua: K9Compat is not available at load time -- '
        .. 'no target adapters were registered. This means shared/compat/core.lua did not load '
        .. 'before this file; check fxmanifest.lua shared_scripts ordering.')
end
