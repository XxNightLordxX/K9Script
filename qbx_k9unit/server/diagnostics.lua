--[[
    qbx_k9unit/server/diagnostics.lua

    EVERY DIAGNOSTIC THIS RESOURCE HAS, IN ONE FILE (merged 2026-09-02,
    owner's request: "I want all diagnostic features merged into one command
    and all functions for diagnostic testing etc moved into one file", and
    then "I want all diagnostic stuff merged completley together").

    This is server/selfcheck.lua and server/debugdump.lua joined. They were
    always halves of one job -- selfcheck ran a handful of checks at boot and
    printed a one-line summary, debugdump ran a much larger catalogue on
    demand and wrote it to a file -- and debugdump already reached into
    selfcheck for the dependency check. Splitting them meant an operator had
    to know which of two files owned the answer to "is anything wrong with my
    install", and a check added to one was invisible to the other.

    ONE COMMAND: /k9debug. It now runs the boot self-checks too, so a dump
    contains everything the console said at start-up plus everything the
    dump already covered -- no more reading the console for half the picture
    and a file for the other half.

    ONE BOOT SUMMARY: still printed on resource start, unchanged. That is not
    a command and never was; it is the line an operator sees without asking,
    and folding it into the dump would have made a healthy install silent
    about a broken dependency until someone thought to run a command.

    TWO SECTIONS BELOW, in load order:
      1. SELF-CHECK -- the pure, testable K9SelfCheck.* helpers and the
         boot-time runners that use them. Kept as a public table because
         section 2 and tests both call into it; a merge is not a reason to
         collapse a tested seam.
      2. DEBUG DUMP -- the /k9debug command, its client heartbeat, and the
         full check catalogue.

    CONFIG KEY DELIBERATELY UNCHANGED: this still reads Config.DebugDump,
    not a renamed Config.Diagnostics. Renaming a config block silently turns
    an operator's existing edits into no-ops, and that is a separate,
    user-visible change -- not something to fold into a file merge. See
    DIAGNOSTIC_CHECKS.md for the full catalogue these checks are drawn from.
]]

-- ======================================================================
-- SECTION 1 -- SELF-CHECK (was server/selfcheck.lua)
--
-- Boot-time self-check, extending a pattern this resource already trusts:
-- server/datastore.lua's own "SCHEMA COLLISION SAFETY NET" tells an
-- operator, precisely and by name, when its OWN database does not match
-- what it expects -- never silently, never by refusing to start.
-- ======================================================================

K9SelfCheck = K9SelfCheck or {}

-- ----------------------------------------------------------------------
-- PURE LOGIC -- no native calls, no globals beyond arguments. Exercised
-- directly (fabricated inputs, no natives, no LoadResourceFile) by
-- tests/diagnostics_selfcheck_spec.lua.
-- ----------------------------------------------------------------------

--- Parses a MAJOR.MINOR[.PATCH] numeric core out of a version string,
--- tolerating a leading "v" and ignoring any trailing pre-release/build
--- suffix. Returns nil for anything that does not start with at least
--- MAJOR.MINOR (a git hash, a bare date written with dashes, an empty
--- string, a non-string) -- that is the UNKNOWN case, deliberately never
--- coerced into a number for comparison.
--- @param versionString any
--- @return table? -- { major = integer, minor = integer, patch = integer }
function K9SelfCheck.ParseSemver(versionString)
    if type(versionString) ~= 'string' then return nil end
    local major, minor, patch = versionString:match('^v?(%d+)%.(%d+)%.?(%d*)')
    if not major then return nil end
    return {
        major = tonumber(major),
        minor = tonumber(minor),
        patch = tonumber(patch) or 0,
    }
end

--- @param a table -- a K9SelfCheck.ParseSemver() result
--- @param b table -- a K9SelfCheck.ParseSemver() result
--- @return integer -- negative if a < b, 0 if equal, positive if a > b
function K9SelfCheck.CompareSemver(a, b)
    if a.major ~= b.major then return a.major - b.major end
    if a.minor ~= b.minor then return a.minor - b.minor end
    return a.patch - b.patch
end

--- Classifies one dependency's real, observed state against its minimum --
--- pure decision table, no native calls. Every branch here is one of the
--- five cases this check's own design brief requires distinguishing.
--- @param resourceState string -- GetResourceState(name)'s real return, or 'unknown' if that native was unavailable
--- @param versionString string? -- GetResourceMetadata(name, 'version', 0)'s real return; nil = no metadata shipped, or not checked because not started
--- @param minVersionString string -- this resource's own recorded minimum (from README.md), e.g. '3.39.0'
--- @return table { status = 'not_started'|'no_metadata'|'unknown_format'|'below_minimum'|'ok', found = string? }
function K9SelfCheck.EvaluateDependencyVersion(resourceState, versionString, minVersionString)
    if resourceState ~= 'started' then
        return { status = 'not_started', resourceState = resourceState }
    end
    if versionString == nil or versionString == '' then
        return { status = 'no_metadata' }
    end
    local found = K9SelfCheck.ParseSemver(versionString)
    local min = K9SelfCheck.ParseSemver(minVersionString)
    if not found or not min then
        return { status = 'unknown_format', found = versionString }
    end
    if K9SelfCheck.CompareSemver(found, min) < 0 then
        return { status = 'below_minimum', found = versionString }
    end
    -- Equal to, or newer than, the minimum -- both are the quiet "say
    -- nothing" case this check's own design brief calls for explicitly
    -- ("version newer (say nothing)"); there is no useful distinction to
    -- an operator between "exactly the version we last checked" and
    -- "newer", so both collapse into 'ok' rather than a third status.
    return { status = 'ok', found = versionString }
end

--- Builds the one console line for a dependency verdict that is NOT 'ok'
--- -- returns nil for 'ok' (the "say nothing" case), matching this
--- resource's own established voice (plain English, `!!` reserved for
--- something that actually warrants attention -- see server/datastore.lua's
--- schema-collision messages for the same convention). Never asserts,
--- never mentions blocking -- this resource has been bitten before by a
--- top-level failure taking every registration below it down with it, and
--- this check exists to warn, not to repeat that mistake in a new file.
--- @param dep table -- { name = string, minVersion = string }
--- @param verdict table -- a K9SelfCheck.EvaluateDependencyVersion() result
--- @return string?
function K9SelfCheck.FormatDependencyWarning(dep, verdict)
    if verdict.status == 'not_started' then
        return ("[qbx_k9unit] selfcheck: !! dependency '%s' is not currently running (state=%s) -- its version could not be checked. It is a hard dependency in fxmanifest.lua; FXServer should refuse to start qbx_k9unit at all without it running, so seeing this means something stopped it AFTER boot. Start/restart '%s'."):format(dep.name, tostring(verdict.resourceState), dep.name)
    elseif verdict.status == 'no_metadata' then
        return ("[qbx_k9unit] selfcheck: '%s' is running but its own fxmanifest.lua ships no 'version' field, so its version could not be checked against %s, the version this resource was last checked compatible against (see README.md). Shipping no version metadata is normal for some resources/forks -- this is informational, not an error."):format(dep.name, dep.minVersion)
    elseif verdict.status == 'unknown_format' then
        return ("[qbx_k9unit] selfcheck: '%s' reports version '%s', which is not a plain MAJOR.MINOR[.PATCH] number this check knows how to compare against %s, the version this resource was last checked compatible against (see README.md). NOT treated as too old -- just unverifiable automatically. Check by hand if you are unsure."):format(dep.name, tostring(verdict.found), dep.minVersion)
    elseif verdict.status == 'below_minimum' then
        return ("[qbx_k9unit] selfcheck: !! '%s' version %s is older than %s, the version this resource was last checked compatible against (see README.md's compatibility table). It may still work -- this is a warning, never a block -- but if something behaves oddly, updating '%s' is the first thing to try."):format(dep.name, verdict.found, dep.minVersion, dep.name)
    end
    return nil
end

--- ======================================================================
--- PART 2 -- UNRECOGNISED Config.Features KEY CHECK
---
--- WHERE THE "SET THIS RESOURCE REALLY READS" COMES FROM, AND WHY: the one
--- genuinely authoritative list of every real feature key already exists
--- -- server/runtimecontrol.lua's own FEATURE_TIERS table, which that
--- file's own header confirms is kept in lock-step with every real
--- Config.Features key today (tests/runtimefeaturetiers_spec.lua is the
--- existing drift guard proving it, and this pass independently verified
--- the same fact by hand: both currently name the identical 58 keys).
---
--- THAT TABLE CANNOT BE READ DEFENSIVELY FROM HERE -- this is not "it may
--- not be loaded yet", which a guarded read could wait out; it is a plain
--- Lua `local FEATURE_TIERS = { ... }` with no resource-global, no export,
--- and no accessor anywhere. server/runtimecontrol.lua's own header says
--- so outright ("THIS FILE exposes no resource-global functions"), and
--- tests/runtimefeaturetiers_spec.lua's own header independently confirms
--- the same limitation from the test side ("not reachable without
--- exporting FEATURE_TIERS' own key list, which server/runtimecontrol.lua
--- ... declines to do"). There is structurally nothing to guard against --
--- it is invisible from this file regardless of load order, so "read it
--- defensively" is not an option here, only "derive the list another way".
---
--- THE OTHER WAY: this file reads server/runtimecontrol.lua's own RAW
--- TEXT (via LoadResourceFile, at real boot -- via a fabricated string in
--- tests/diagnostics_selfcheck_spec.lua) and checks whether each Config.Features key
--- appears ANYWHERE in it as a whole identifier. This is deliberately NOT
--- a structural parse of the FEATURE_TIERS table (extracting exactly its
--- keys via brace-depth tracking) -- that would break the moment a comment
--- inside that block used an unbalanced brace, or the table were
--- reformatted, for a check whose one job is to never cry wolf. A plain
--- whole-word substring scan across the WHOLE FILE is far more tolerant:
--- every real feature key has to appear literally as text somewhere in
--- that file for FEATURE_TIERS/GetFeatureTier to work AT ALL (a Lua table
--- key is written as literal text even when looked up through a runtime
--- variable elsewhere), so the failure mode this looser check trades away
--- is "misses a truly exotic case where a real key is never once written
--- out literally in that file" -- something that cannot happen today,
--- since every one of the 58 real keys is a literal FEATURE_TIERS entry --
--- in exchange for near-zero risk of the ONE outcome this task explicitly
--- calls worse than not having the check at all: warning about a
--- legitimate key.
---
--- WHY server/runtimecontrol.lua SPECIFICALLY, AND NOT A HAND-MAINTAINED
--- list duplicated into THIS file: a second, independently hand-kept list
--- of "every real feature key" is exactly the failure mode
--- server/runtimecontrol.lua's own header already documents happening
--- once for real (eleven features shipped in Config.Features with no
--- matching FEATURE_TIERS entry, unnoticed for months) -- writing a THIRD
--- copy here would not fix that class of bug, it would add another place
--- for the same drift to happen invisibly. Reading runtimecontrol.lua's
--- own text instead means this check can never drift out of sync with
--- itself; it can only ever be as complete as that file already is, which
--- tests/runtimefeaturetiers_spec.lua independently keeps honest.
--- ======================================================================

--- @param configFeatures table<string, boolean> -- Config.Features
--- @param registrySourceText string -- raw text of server/runtimecontrol.lua (or any equivalent corpus, in a test)
--- @return string[] -- sorted list of keys not found as a whole identifier anywhere in registrySourceText
function K9SelfCheck.FindUnrecognizedFeatureKeys(configFeatures, registrySourceText)
    local unrecognized = {}
    if type(configFeatures) ~= 'table' or type(registrySourceText) ~= 'string' then
        return unrecognized
    end

    for key in pairs(configFeatures) do
        local found = false
        local searchFrom = 1
        while not found do
            local matchStart, matchEnd = registrySourceText:find(key, searchFrom, true)
            if not matchStart then break end
            -- Whole-identifier match only: a key must not be preceded or
            -- followed by another Lua identifier character, so e.g.
            -- 'ScentTracking' cannot falsely match inside a longer name
            -- like 'ScentTrackingAdvanced' that happens to start the same
            -- way (no such key exists today, but this keeps the check
            -- correct as longer names are added later).
            local before = registrySourceText:sub(matchStart - 1, matchStart - 1)
            local after = registrySourceText:sub(matchEnd + 1, matchEnd + 1)
            local boundaryOk = (before == '' or not before:match('[%w_]'))
                and (after == '' or not after:match('[%w_]'))
            if boundaryOk then
                found = true
            else
                searchFrom = matchEnd + 1
            end
        end
        if not found then
            unrecognized[#unrecognized + 1] = key
        end
    end

    table.sort(unrecognized)
    return unrecognized
end

--- ======================================================================
--- FINAL BOOT SUMMARY LINE
---
--- Added after a new-buyer walkthrough found this resource prints
--- essentially nothing on a healthy install -- every print( ) in
--- server/*.lua answers a degraded or error state, so a first-time owner
--- with a clean install has to infer success from silence alone, out of
--- step with how loud and specific this resource is about everything that
--- CAN go wrong. This is the one line that always prints, win or lose --
--- carrying real, already-computed information (this resource's own
--- version, the dependency/feature-key tallies the checks above already
--- produced, and the database backend) rather than a bare "loaded OK".
---
--- NEVER FABRICATES A STATE IT DID NOT VERIFY: the database clause reports
--- only what server/datastore.lua's own K9Store.IsDatabaseEnabled()
--- exposes -- connected-with-no-whole-resource-collision, or memory-only.
--- K9Store exposes no table-count accessor at all (grep confirms exactly
--- one function assigned onto that global table,
--- `K9Store.IsDatabaseEnabled`), so this deliberately does NOT claim "N
--- tables verified" -- a confident number this file cannot actually
--- confirm would be worse than the shorter, honest line below. If an
--- exact verified-table-count becomes available from server/datastore.lua
--- in the future (something to route to whoever owns that file, not
--- edited here), this line can be extended to use it.
--- ======================================================================

--- Which trail types are BOTH switched on AND now gated behind a
--- specialization nobody may have granted yet.
---
--- WHY THIS CHECK EXISTS. Blood and gunpowder tracking used to work for
--- every certified dog. The owner-directed decluttering pass
--- (Config.SpecializationTracking, config.lua) made each of them require a
--- specialization instead. That is the change that was asked for, but it
--- means an existing server SILENTLY LOSES two capabilities the moment it
--- updates: the radial entry is still there, the dog still walks up, and
--- the answer is simply "nothing found" forever, with nothing anywhere
--- saying why. A capability that stops existing without a word is the
--- worst outcome this resource can produce, so it gets a line at boot.
---
--- Deliberately CONFIG-ONLY -- it never asks the database whether anybody
--- actually holds the specialization. A boot-time query would let this say
--- "and nobody has one yet", but it would also make a startup line depend
--- on the database being up, and this file's whole contract is that it
--- never blocks or fails a boot. Naming the requirement unconditionally is
--- less precise and cannot be wrong.
--- @param configFeatures table -- Config.Features
--- @param specializationTracking table|nil -- Config.SpecializationTracking
--- @param trackTypeFeatureFlags table -- trackType -> Config.Features key
--- @return { trackType: string, feature: string, specialization: string }[]
function K9SelfCheck.FindSpecializationGatedTrackTypes(configFeatures, specializationTracking, trackTypeFeatureFlags)
    local out = {}
    if type(configFeatures) ~= 'table' or type(specializationTracking) ~= 'table'
        or type(trackTypeFeatureFlags) ~= 'table' then
        return out
    end

    -- Invert the config's specialization -> {trackType, ...} shape into
    -- trackType -> specialization. A trail listed under SEVERAL
    -- specializations collapses to one key here, and which specialization
    -- is reported for it is arbitrary -- pairs() order is
    -- implementation-defined, so no ordering guard could make it otherwise.
    -- Deliberately accepted: this warning's job is to say the requirement
    -- now EXISTS, so naming one specialization that unlocks the trail is
    -- enough. It does not claim to name the only one.
    local requiredBy = {}
    for specialization, trackTypes in pairs(specializationTracking) do
        if type(trackTypes) == 'table' then
            for _, trackType in ipairs(trackTypes) do
                if type(trackType) == 'string' then
                    requiredBy[trackType] = specialization
                end
            end
        end
    end

    -- Sorted so the warning reads identically across boots -- pairs() over
    -- either table would otherwise reorder it run to run and look like
    -- something changed when nothing did. NOTE FOR ANYONE EDITING: deleting
    -- this sort cannot be caught by a test that reliably goes red, because
    -- Lua's pairs() order is implementation-defined and may happen to come
    -- out sorted anyway. tests/diagnostics_selfcheck_spec.lua asserts the RESULT is in
    -- ascending order rather than pretending to prove the sort by deleting
    -- it -- an honest property assertion, not a red-green proof.
    local trackTypes = {}
    for trackType in pairs(requiredBy) do trackTypes[#trackTypes + 1] = trackType end
    table.sort(trackTypes)

    for _, trackType in ipairs(trackTypes) do
        local featureKey = trackTypeFeatureFlags[trackType]
        -- Only warn about a trail the owner actually has switched ON. A
        -- server running with blood tracking off has lost nothing and does
        -- not need telling about a requirement it will never reach.
        if type(featureKey) == 'string' and configFeatures[featureKey] then
            out[#out + 1] = {
                trackType = trackType,
                feature = featureKey,
                specialization = requiredBy[trackType],
            }
        end
    end

    return out
end

--- ======================================================================
--- PART 3 -- K9 EQUIPMENT SHOP PURCHASE-ENFORCEMENT BACKEND CHECK
--- (coder-security, this pass -- red-team finding on server/equipmentshop.lua
--- ~2286-2356, VERIFIED against the real code before acting).
---
--- server/equipmentshop.lua's K9 Supply shop enforces exactly two things
--- ONLY through ox_inventory-vocabulary `registerHook('openShop', ...)` /
--- `registerHook('buyItem', ...)` calls, routed via `K9Compat.Get('inventory')
--- .RegisterHook` (see that file's own "PURCHASE-TIME ENFORCEMENT" section):
--- the per-person `block.K9EquipmentShop` / `feature.K9EquipmentShop` grant
--- gate, AND every item's own `requiredTierKey`/`requiredSpecialization`
--- gate. shared/compat/inventory.lua's own "RegisterHook VOCABULARY" section
--- confirms ox_inventory is currently the ONLY adapter whose RegisterHook
--- translates an ARBITRARY event name; every other backend (qb-inventory
--- CONFIRMED, ps-inventory skipped entirely, five others UNCONFIRMED) only
--- ever translates `'swapItems'` -- a RegisterHook call for `'openShop'`/
--- `'buyItem'` on any of them returns `false` immediately, registering
--- nothing.
---
--- THIS WAS RE-VERIFIED, NOT ASSUMED, TO ALREADY FAIL CLOSED CORRECTLY:
--- server/equipmentshop.lua's own ActivateEquipmentShopIfEnabled (its
--- "HOOKS FIRST, ALWAYS" section) refuses to ever call RegisterShop unless
--- BOTH hooks confirm registered -- so the practical effect on an
--- unsupported backend is already "the K9 Supply shop is not offered at
--- all, gated items or not", never "sold with no enforcement". That refusal
--- already prints its own loud ERROR line the moment it happens -- but only
--- there, deep in server console scrollback, and only if Config.Features.
--- K9EquipmentShop was already true AT BOOT (a later runtime toggle-on hits
--- the exact same refusal, on the same poll thread, equally deep in
--- scrollback). THIS check exists purely to put the SAME fact on the one
--- line an owner actually reads at the top of their console: the boot
--- summary.
---
--- WHY "REFUSE THE WHOLE SHOP" AND NOT "SELL ONLY THE UNGATED ITEMS" --
--- REJECTED ALTERNATIVE, RECORDED HERE: stripping only gated items from the
--- RegisterShop call on an unsupported backend would still leave the
--- OTHER, more fundamental thing these same two hooks enforce -- the
--- per-person block.K9EquipmentShop/feature.K9EquipmentShop grant --
--- completely unenforced. An officer High Command has explicitly blocked
--- from this shop could still buy every ungated item freely on that
--- backend, which is a worse, more surprising failure for an operator to
--- discover than "the shop is not offered here at all". Refusing the whole
--- shop is therefore the correct fail-closed choice for BOTH concerns at
--- once, not an overreaction to the narrower tier/specialization finding
--- alone.
---
--- CONFIG-ONLY, EXACTLY LIKE THE SPECIALIZATION-GATE CHECK ABOVE: this
--- reads Config.Features.K9EquipmentShop and K9Compat.Which('inventory')
--- only -- it does not, and structurally cannot from here, re-derive
--- whether server/equipmentshop.lua's own EquipmentShopFullyActivated flag
--- is currently true (that file exposes no accessor for it at all, matching
--- the specialization check's own documented reason for not reaching into
--- server/runtimecontrol.lua's FEATURE_TIERS directly). This reports what
--- WOULD happen / already did happen for the DETECTED backend, which is
--- exactly as far as this file can honestly see.
---
--- A `Config.Compat.Systems.inventory.custom` operator-authored adapter is
--- DELIBERATELY NOT treated as "unsupported": K9Compat.Which('inventory')
--- reports its resourceName as the literal string `'custom'`, and this file
--- has no way to see whether that adapter's own RegisterHook actually
--- translates 'openShop'/'buyItem' or not -- guessing either way would risk
--- exactly the "crying wolf" false alarm this resource's own checks are
--- built to avoid (see PART 2's header). Reported as its own distinct,
--- non-alarming, informational case instead ('unknown') -- never silently
--- folded into either 'ok' or 'unsupported_backend'.
--- ======================================================================

--- Adapters CONFIRMED (shared/compat/inventory.lua's own "RegisterHook
--- VOCABULARY" section) to translate an ARBITRARY RegisterHook event name --
--- specifically the 'openShop'/'buyItem' pair the K9 Supply shop needs.
--- Hand-kept here, matching this file's own DEPENDENCIES table's own
--- "hand-kept, changes exactly as often as the file it mirrors" precedent
--- (see PART 1's header) -- update this list in the SAME change that
--- shared/compat/inventory.lua ever gains a second adapter whose
--- RegisterHook stops being restricted to translating 'swapItems' only.
local EQUIPMENT_SHOP_ENFORCEMENT_CAPABLE_BACKENDS = { ['ox_inventory'] = true }

--- @param featureEnabled boolean? -- Config.Features.K9EquipmentShop
--- @param inventoryBackendName string? -- K9Compat.Which('inventory')'s first return value; nil = nothing usable detected at all
--- @return string status -- 'not_applicable' (feature off) | 'ok' | 'unsupported_backend' | 'unknown' (a custom adapter -- cannot verify from here)
function K9SelfCheck.EvaluateEquipmentShopEnforcement(featureEnabled, inventoryBackendName)
    if featureEnabled ~= true then return 'not_applicable' end
    if inventoryBackendName == 'custom' then return 'unknown' end
    if type(inventoryBackendName) == 'string' and EQUIPMENT_SHOP_ENFORCEMENT_CAPABLE_BACKENDS[inventoryBackendName] then
        return 'ok'
    end
    -- Covers every other named backend (e.g. 'qb-inventory') AND nil (no
    -- usable backend detected at all, K9Compat.Get('inventory') already a
    -- no-op stub) -- both are conclusively unable to register either hook.
    return 'unsupported_backend'
end

--- @param status string -- a K9SelfCheck.EvaluateEquipmentShopEnforcement() result
--- @param inventoryBackendName string?
--- @return string? -- nil for 'not_applicable'/'ok' (the "say nothing" cases)
function K9SelfCheck.FormatEquipmentShopEnforcementWarning(status, inventoryBackendName)
    if status == 'unsupported_backend' then
        local backendLabel = inventoryBackendName or 'no inventory backend detected'
        return ("[qbx_k9unit] selfcheck: !! Config.Features.K9EquipmentShop is on, but the detected inventory backend (%s) cannot enforce the K9 Supply shop's purchase-time checks (the block.K9EquipmentShop/feature.K9EquipmentShop per-person gate, and any item's tier/specialization requirement) -- ox_inventory is currently the only backend confirmed to support the openShop/buyItem hooks this needs. server/equipmentshop.lua already refuses to activate this shop at all on this backend rather than sell it unenforced, so nothing is for sale here, gated or not, until you either switch to ox_inventory or turn Config.Features.K9EquipmentShop back off."):format(backendLabel)
    elseif status == 'unknown' then
        return "[qbx_k9unit] selfcheck: Config.Features.K9EquipmentShop is on, and Config.Compat.Systems.inventory.custom is in use -- this check cannot verify from here whether your custom inventory adapter's RegisterHook actually translates 'openShop'/'buyItem' (the two hooks the K9 Supply shop's purchase-time enforcement needs). If it does not, server/equipmentshop.lua will refuse to activate that shop at boot and say so loudly in its own console output -- watch for a line there naming 'REFUSING to activate'."
    end
    return nil
end

--- @param info table {
---   version = string?,                                    -- this resource's own fxmanifest.lua version, or nil if unknown
---   deps = { total, ok, unverified, problems }?,           -- from the dependency check, or nil if it could not run
---   features = { total, unrecognized }?,                   -- from the Config.Features check, or nil if it could not run
---   equipmentShop = { status = string }?,                  -- from K9SelfCheck.EvaluateEquipmentShopEnforcement, or nil if it could not run
---   databaseState = string,                                -- short phrase; never fabricated, see header above
--- }
--- @return string -- exactly ONE line, never a banner
function K9SelfCheck.BuildBootSummaryLine(info)
    local parts = {}

    parts[#parts + 1] = info.version and ('v' .. info.version) or 'version unknown'

    if info.deps then
        if info.deps.problems > 0 or info.deps.unverified > 0 then
            parts[#parts + 1] = ('dependencies: %d/%d at/above minimum (%d unverified, %d warning(s) above)')
                :format(info.deps.ok, info.deps.total, info.deps.unverified, info.deps.problems)
        else
            parts[#parts + 1] = ('dependencies: %d/%d at/above minimum'):format(info.deps.ok, info.deps.total)
        end
    else
        parts[#parts + 1] = 'dependencies: not checked'
    end

    if info.features then
        local recognized = info.features.total - info.features.unrecognized
        if info.features.unrecognized > 0 then
            parts[#parts + 1] = ('Config.Features: %d/%d keys recognized (%d warning(s) above)')
                :format(recognized, info.features.total, info.features.unrecognized)
        else
            parts[#parts + 1] = ('Config.Features: %d/%d keys recognized'):format(info.features.total, info.features.total)
        end
    else
        parts[#parts + 1] = 'Config.Features: not checked'
    end

    -- Omitted entirely for 'not_applicable' (the feature is off -- nothing
    -- to say, matching this file's own "only warn about a switched-on
    -- capability" convention) exactly as the specialization-gate check
    -- above already omits itself for a trail type that is switched off.
    if info.equipmentShop and info.equipmentShop.status ~= 'not_applicable' then
        if info.equipmentShop.status == 'ok' then
            parts[#parts + 1] = 'K9 Supply shop: enforced'
        elseif info.equipmentShop.status == 'unsupported_backend' then
            parts[#parts + 1] = 'K9 Supply shop: NOT offered (see warning above -- inventory backend cannot enforce it)'
        elseif info.equipmentShop.status == 'unknown' then
            parts[#parts + 1] = 'K9 Supply shop: enforcement unverified (custom inventory adapter)'
        end
    end

    parts[#parts + 1] = 'database: ' .. (info.databaseState or 'unknown')

    return '[qbx_k9unit] selfcheck: boot summary -- ' .. table.concat(parts, ' | ')
end

-- ----------------------------------------------------------------------
-- NATIVE-TOUCHING GLUE -- guarded, thin, not independently unit-tested
-- beyond "registers nothing in a native-less sandbox" (see this file's own
-- header). Every native call is pcall-wrapped; nothing here can throw past
-- its own boundary, matching server/datastore.lua's own schema-probe
-- discipline exactly.
-- ----------------------------------------------------------------------

-- Verbatim from README.md's "Last checked compatible against" line and
-- fxmanifest.lua's own `dependencies { ... }` block -- see this file's own
-- header for why this is hand-kept here rather than derived from a
-- dependency-metadata native. Update BOTH this table and README.md's own
-- compatibility line in the same change if either ever changes.
local DEPENDENCIES = {
    { name = 'qbx_core',     minVersion = '1.24.0' },
    { name = 'ox_lib',       minVersion = '3.39.0' },
    { name = 'ox_target',    minVersion = '1.18.1' },
    { name = 'oxmysql',      minVersion = '2.14.1' },
    { name = 'ox_inventory', minVersion = '2.47.9' },
}

--- @param resourceName string
--- @return string -- GetResourceState's real return, or 'unknown' if the native is unavailable or throws
local function SafeGetResourceState(resourceName)
    if type(GetResourceState) ~= 'function' then return 'unknown' end
    local ok, state = pcall(GetResourceState, resourceName)
    if ok and type(state) == 'string' then return state end
    return 'unknown'
end

--- @param resourceName string
--- @return string? -- GetResourceMetadata(resourceName, 'version', 0)'s real return, or nil
local function SafeGetVersionMetadata(resourceName)
    if type(GetResourceMetadata) ~= 'function' then return nil end
    local ok, value = pcall(GetResourceMetadata, resourceName, 'version', 0)
    if ok and type(value) == 'string' and value ~= '' then return value end
    return nil
end

--- Runs the dependency version check, printing one line per dependency
--- that is NOT 'ok' (see K9SelfCheck.FormatDependencyWarning), and returns
--- the tally BuildBootSummaryLine needs. Returns nil (check "could not
--- run", never "everything failed") if the natives it needs are absent --
--- the only realistic way that happens is tests/diagnostics_selfcheck_spec.lua's plain
--- Lua sandbox, which has neither native.
--- @return table? { total, ok, unverified, problems }
local function RunDependencyCheck()
    if type(GetResourceState) ~= 'function' or type(GetResourceMetadata) ~= 'function' then
        print('[qbx_k9unit] selfcheck: dependency version check could not run in this environment (GetResourceState/GetResourceMetadata unavailable) -- skipping. This never blocks startup either way.')
        return nil
    end

    local okCount, unverifiedCount, problemCount = 0, 0, 0
    for _, dep in ipairs(DEPENDENCIES) do
        local state = SafeGetResourceState(dep.name)
        local version = (state == 'started') and SafeGetVersionMetadata(dep.name) or nil
        local verdict = K9SelfCheck.EvaluateDependencyVersion(state, version, dep.minVersion)
        local line = K9SelfCheck.FormatDependencyWarning(dep, verdict)
        if line then print(line) end

        if verdict.status == 'ok' then
            okCount = okCount + 1
        elseif verdict.status == 'no_metadata' or verdict.status == 'unknown_format' then
            unverifiedCount = unverifiedCount + 1
        else
            problemCount = problemCount + 1
        end
    end

    return { total = #DEPENDENCIES, ok = okCount, unverified = unverifiedCount, problems = problemCount }
end

--- @param relativePath string -- e.g. 'server/runtimecontrol.lua'
--- @return string? -- the file's raw text, or nil if it could not be read
local function ReadOwnResourceFile(relativePath)
    if type(LoadResourceFile) ~= 'function' or type(GetCurrentResourceName) ~= 'function' then
        return nil
    end
    local ok, content = pcall(LoadResourceFile, GetCurrentResourceName(), relativePath)
    if ok and type(content) == 'string' and content ~= '' then return content end
    return nil
end

--- Runs the Config.Features key check, printing one named warning if any
--- unrecognized key is found, and returns the tally BuildBootSummaryLine
--- needs. Returns nil ("could not run") if Config.Features is missing, or
--- server/runtimecontrol.lua could not be read -- never treated as "every
--- key is bad".
--- @return table? { total, unrecognized }
local function RunFeatureKeyCheck()
    if type(Config) ~= 'table' or type(Config.Features) ~= 'table' then
        print('[qbx_k9unit] selfcheck: Config.Features is missing or malformed -- skipping the unrecognized-key check.')
        return nil
    end

    local registryText = ReadOwnResourceFile('server/runtimecontrol.lua')
    if not registryText then
        print('[qbx_k9unit] selfcheck: could not read server/runtimecontrol.lua to cross-check Config.Features keys (LoadResourceFile unavailable, or the file is missing) -- skipping that check this boot. This never blocks startup either way.')
        return nil
    end

    local total = 0
    for _ in pairs(Config.Features) do total = total + 1 end

    local unrecognized = K9SelfCheck.FindUnrecognizedFeatureKeys(Config.Features, registryText)
    if #unrecognized > 0 then
        print(("[qbx_k9unit] selfcheck: !! %d Config.Features key(s) do not appear anywhere in this resource's own feature registry (server/runtimecontrol.lua) -- almost certainly a typo, a renamed/removed feature, or a leftover from an old install: %s. Setting one of these to true/false has NO EFFECT: nothing in this resource reads it, and the real feature it was probably meant to control keeps whatever value it already has. Check the exact spelling against config.lua's own comments or README.md."):format(#unrecognized, table.concat(unrecognized, ', ')))
    end

    return { total = total, unrecognized = #unrecognized }
end

--- Prints the specialization-gate warning. See
--- K9SelfCheck.FindSpecializationGatedTrackTypes above for why this exists.
--- @return number -- how many gated-and-enabled trail types were named
local function RunSpecializationGateCheck()
    if type(Config) ~= 'table' or type(Config.Features) ~= 'table' then return 0 end

    local gated = K9SelfCheck.FindSpecializationGatedTrackTypes(
        Config.Features,
        Config.SpecializationTracking,
        { scent = 'ScentTracking', blood = 'BloodTracking', gunpowder = 'GunpowderSniffing' }
    )
    if #gated == 0 then return 0 end

    local parts = {}
    for _, entry in ipairs(gated) do
        parts[#parts + 1] = ("%s tracking needs the '%s' specialization"):format(entry.trackType, entry.specialization)
    end

    print(("[qbx_k9unit] selfcheck: %d trail type(s) now require a specialization before any dog can follow them: %s. " ..
           "This changed deliberately -- following a person's scent is still something every certified dog can do, " ..
           "but these ones are now specialist skills. A dog without the specialization finds NOTHING on these trails " ..
           "and is told nothing, which looks exactly like the feature being broken. Grant them with /k9specialize, " ..
           "or switch the trail off in config.lua if you do not want it. Change which specialization unlocks what " ..
           "under Config.SpecializationTracking in config.lua."):format(#gated, table.concat(parts, '; ')))

    return #gated
end

--- Prints the equipment-shop enforcement warning (see PART 3's own header
--- above) and returns the tally BuildBootSummaryLine needs. Reads
--- K9Compat.Which('inventory') defensively (pcall-guarded, and the whole
--- K9Compat global may not even be loaded in some sandboxes) -- never
--- throws, and never claims a backend it could not actually confirm.
--- @return table? { status = string } -- nil only if Config.Features itself is missing/malformed (matches RunSpecializationGateCheck's own "nothing to check" case)
local function RunEquipmentShopEnforcementCheck()
    if type(Config) ~= 'table' or type(Config.Features) ~= 'table' then return nil end

    local inventoryBackendName = nil
    if type(K9Compat) == 'table' and type(K9Compat.Which) == 'function' then
        local ok, name = pcall(K9Compat.Which, 'inventory')
        if ok then inventoryBackendName = name end
    end

    local status = K9SelfCheck.EvaluateEquipmentShopEnforcement(Config.Features.K9EquipmentShop, inventoryBackendName)
    local line = K9SelfCheck.FormatEquipmentShopEnforcementWarning(status, inventoryBackendName)
    if line then print(line) end

    return { status = status }
end

--- ----------------------------------------------------------------------
--- PART 5 -- CONFIG.DEPARTMENTS vs THE SERVER'S REAL JOBS
---
--- THE FAILURE THIS EXISTS FOR. Config.Departments ships with 'police',
--- 'sheriff' and 'bcso'. A server whose jobs are named anything else --
--- 'lspd', 'sast', a custom framework's own naming -- gets a resource that
--- is COMPLETELY INERT and says nothing about it. Every gate in this
--- resource is `Config.Departments[job.name]`, so nobody can certify,
--- nobody is high command, no radial item appears, and the tablet refuses
--- everyone. Meanwhile the boot summary reports 61/61 feature keys
--- recognized and 4/4 dependencies fine, because both of those ARE fine.
---
--- It is the single most likely day-one misconfiguration and the one with
--- the worst symptom: everything looks healthy and nothing works.
---
--- WHY THIS PROBES AND NEVER ASSUMES. There is no export in this file's
--- verified set that lists a server's jobs -- this resource only ever calls
--- GetPlayer/GetPlayerByCitizenId/GetOfflinePlayer/Notify on qbx_core. An
--- unregistered native or export returns nil forever and logs nothing (see
--- client/vision.lua's IsSeethroughActive finding for what that costs), so
--- calling a guessed `GetJobs` would produce a check that silently never
--- runs while looking like it does. Instead this uses the same two-step
--- probe shape shared/compat/target.lua's IsExportCapable established:
--- confirm the resource is started, then confirm the method is really a
--- function, both pcall-guarded. If it is not there, this says so in one
--- line and checks nothing -- an honest "could not verify" rather than a
--- false all-clear.
--- ----------------------------------------------------------------------

--- Pure comparison, kept separate from the probe so it is testable without
--- a live qbx_core.
--- @param configuredDepartments table -- Config.Departments
--- @param realJobNames table -- set-like or array of job names the server actually defines
--- @return string[] missing -- configured names with no matching real job, sorted
function K9SelfCheck.FindUnknownDepartmentJobs(configuredDepartments, realJobNames)
    local missing = {}
    if type(configuredDepartments) ~= 'table' or type(realJobNames) ~= 'table' then return missing end

    -- Accept either shape: { police = {...} } or { 'police', 'sheriff' }.
    local known = {}
    for key, value in pairs(realJobNames) do
        if type(key) == 'string' then known[key:lower()] = true end
        if type(value) == 'string' then known[value:lower()] = true end
    end
    if next(known) == nil then return missing end

    for jobName in pairs(configuredDepartments) do
        if type(jobName) == 'string' and not known[jobName:lower()] then
            missing[#missing + 1] = jobName
        end
    end
    table.sort(missing)
    return missing
end

--- @param missing string[]
--- @param totalConfigured number
--- @return string? line -- nil when there is nothing to say
function K9SelfCheck.FormatUnknownDepartmentWarning(missing, totalConfigured)
    if type(missing) ~= 'table' or #missing == 0 then return nil end

    if #missing >= totalConfigured then
        return ('[qbx_k9unit] selfcheck: !! NONE of your Config.Departments job names exist on this server (%s). '):format(table.concat(missing, ', '))
            .. 'Every K9 feature is gated on the player\'s job being one of these, so right now NOBODY can certify, '
            .. 'reach High Command, or use the tablet -- the resource is effectively off. '
            .. 'Fix the job names in config.lua to match your server\'s real ones.'
    end

    return ('[qbx_k9unit] selfcheck: !! %d of %d Config.Departments job name(s) do not exist on this server: %s. ')
        :format(#missing, totalConfigured, table.concat(missing, ', '))
        .. 'Nobody in those departments can certify, reach High Command, or use the tablet. '
        .. 'Either fix the name in config.lua or remove the entry.'
end

--- Probes for a job-listing export and, if one is really there, checks the
--- configured department names against it. Never throws.
local function RunDepartmentJobNameCheck()
    if type(Config) ~= 'table' or type(Config.Departments) ~= 'table' then return end

    local total = 0
    for _ in pairs(Config.Departments) do total = total + 1 end
    if total == 0 then
        print('[qbx_k9unit] selfcheck: !! Config.Departments is empty -- no job can use any K9 feature. '
            .. 'Add at least one real job name from your server.')
        return
    end

    -- Two-step probe, per this section's header. GetJobs is the shape Qbox
    -- is expected to expose; it is NOT assumed to exist.
    local capable = false
    if type(GetResourceState) == 'function' and GetResourceState('qbx_core') == 'started' then
        local ok, method = pcall(function() return exports.qbx_core.GetJobs end)
        capable = ok and type(method) == 'function'
    end
    if not capable then
        print('[qbx_k9unit] selfcheck: could not read this server\'s job list (qbx_core exposes no GetJobs here), '
            .. 'so Config.Departments job names were NOT verified. If K9 features do nothing for everyone, '
            .. 'a mismatched job name in Config.Departments is the first thing to check.')
        return
    end

    local ok, jobs = pcall(function() return exports.qbx_core:GetJobs() end)
    if not ok or type(jobs) ~= 'table' then
        print('[qbx_k9unit] selfcheck: this server\'s job list could not be read, so Config.Departments job '
            .. 'names were NOT verified. See the note above if nothing K9-related works.')
        return
    end

    local line = K9SelfCheck.FormatUnknownDepartmentWarning(
        K9SelfCheck.FindUnknownDepartmentJobs(Config.Departments, jobs), total)
    if line then print(line) end
end

--- Short, honest phrase for the final summary line's database clause.
--- Waits (bounded) for server/datastore.lua's own schema-collision probe
--- to settle first -- the same K9Store.WaitForSchemaCheckToSettle() every
--- other file's own boot-time reader of that state already calls before
--- its first read, per that function's own doc comment -- so this does
--- not race the answer and report a stale "connected" the instant before
--- a real collision is found. Never claims a table count (see this file's
--- own "FINAL BOOT SUMMARY LINE" header for why).
--- @return string
local function BuildDatabaseStatePhrase()
    if type(K9Store) ~= 'table' or type(K9Store.IsDatabaseEnabled) ~= 'function' then
        return 'unknown (server/datastore.lua not loaded)'
    end
    if type(K9Store.WaitForSchemaCheckToSettle) == 'function' then
        pcall(K9Store.WaitForSchemaCheckToSettle)
    end
    local ok, enabled = pcall(K9Store.IsDatabaseEnabled)
    if not ok then return 'unknown' end
    if enabled then
        return 'connected (no whole-resource schema collision detected -- see any warning above for individual tables)'
    end

    -- TWO VERY DIFFERENT REASONS TO BE MEMORY-ONLY, and telling them apart
    -- is the whole point of this branch.
    --
    -- Config.Database.enabled = false is the SHIPPED DEFAULT (the resource
    -- is drag-and-drop out of the box), so it is the ordinary case, not a
    -- fault, and there is no warning above explaining it. This used to
    -- return "see any warning above for why" unconditionally, which sent
    -- every operator running the default configuration hunting for an
    -- explanation that was never printed.
    --
    -- The other reason -- datastore.lua's schema-collision probe forcing
    -- memory-only because another resource owns a k9_* table -- IS a fault,
    -- DOES print a warning above, and must keep pointing at it.
    if type(Config) == 'table' and type(Config.Database) == 'table' and Config.Database.enabled == false then
        -- "capped, not absent" is deliberate wording: the audit trail DOES
        -- work in memory mode (server/datastore.lua records it and the
        -- tablet reads it back), it is just bounded and lost on restart.
        -- An earlier version of this line said no audit trail was written
        -- at all, which was simply untrue and would have talked an operator
        -- out of checking a dispute they could actually have checked.
        return 'memory-only BY CONFIG (Config.Database.enabled = false -- the shipped default). '
            .. 'Everything works, but nothing survives a restart: certifications, XP, partnerships, permissions, '
            .. 'callsigns and themes all reset. The audit trail works this session but is capped '
            .. '(500 search entries, 200 of everything else) and resets too. '
            .. 'Set Config.Database.enabled = true and run sql/install.sql once to keep them.'
    end

    return 'memory-only UNEXPECTEDLY -- Config.Database.enabled is not false, so this was forced at runtime. '
        .. 'See the warning above from server/datastore.lua for which table collided and why.'
end

if type(AddEventHandler) == 'function' then
    AddEventHandler('onResourceStart', function(resourceName)
        if type(GetCurrentResourceName) == 'function' and GetCurrentResourceName() ~= resourceName then return end

        -- ORDER MATTERS: dependency check, then Config.Features check, then
        -- the one final summary line -- so the summary reads as the
        -- conclusion of the two checks above it, never an unrelated
        -- announcement ahead of them.
        local depResult = RunDependencyCheck()
        local featureResult = RunFeatureKeyCheck()
        RunSpecializationGateCheck()
        -- Placed before the summary so a job-name mismatch is read BEFORE
        -- the all-green tallies, not after them.
        RunDepartmentJobNameCheck()
        local equipmentShopResult = RunEquipmentShopEnforcementCheck()
        local databaseState = BuildDatabaseStatePhrase()

        local ownVersion = nil
        if type(GetCurrentResourceName) == 'function' then
            ownVersion = SafeGetVersionMetadata(GetCurrentResourceName())
        end

        print(K9SelfCheck.BuildBootSummaryLine({
            version = ownVersion,
            deps = depResult,
            features = featureResult,
            equipmentShop = equipmentShopResult,
            databaseState = databaseState,
        }))
    end)
end

-- ======================================================================
-- SECTION 2 -- DEBUG DUMP (was server/debugdump.lua)
--
-- The `/k9debug` command -- owner's own words: "I want a debug mode
-- setup... so that way when I am testing I can give you the information for
-- fixes etc," "I also want that debug super comprehensive," "I don't want
-- it showing up in the console I want it to log in a folder in the script
-- itself." Everything above this line is available to it directly now,
-- rather than through a cross-file global.
-- ======================================================================

-- ======================================================================
-- SECTION 0 -- CONFIG CLAMP-AND-WARN, THEN THE ONE EARLY EXIT THIS WHOLE
-- FILE HAS.
-- ======================================================================

if type(Config) ~= 'table' then Config = {} end
if type(Config.DebugDump) ~= 'table' then
    Config.DebugDump = { enabled = false, level = 'normal', maxRetainedDumps = 200, autoOnBoot = false }
end

local function ClampDebugDumpConfig()
    local dd = Config.DebugDump

    if type(dd.enabled) ~= 'boolean' then
        print(('[qbx_k9unit] debugdump: Config.DebugDump.enabled is not a boolean (got %s) -- using false (this whole subsystem ships off by default). Fix Config.DebugDump.enabled in config.lua.'):format(type(dd.enabled)))
        dd.enabled = false
    end

    if dd.level ~= 'normal' and dd.level ~= 'verbose' then
        if dd.level ~= nil then
            print(('[qbx_k9unit] debugdump: Config.DebugDump.level is %q, not "normal" or "verbose" -- using "normal". Fix Config.DebugDump.level in config.lua.'):format(tostring(dd.level)))
        end
        dd.level = 'normal'
    end

    if type(dd.maxRetainedDumps) ~= 'number' or dd.maxRetainedDumps <= 0 then
        print(('[qbx_k9unit] debugdump: Config.DebugDump.maxRetainedDumps is not a positive number (got %s) -- using 200. Fix Config.DebugDump.maxRetainedDumps in config.lua.'):format(tostring(dd.maxRetainedDumps)))
        dd.maxRetainedDumps = 200
    else
        dd.maxRetainedDumps = math.floor(dd.maxRetainedDumps)
    end

    if type(dd.autoOnBoot) ~= 'boolean' then
        dd.autoOnBoot = true
    end
end

ClampDebugDumpConfig()

if Config.DebugDump.enabled ~= true then
    -- Ships off. Nothing below this line ever runs: no command, no
    -- wrapping, no thread, no file I/O. See this file's own header.
    return
end

-- ======================================================================
-- SECTION 1 -- SMALL, SHARED HELPERS
-- ======================================================================

local DUMP_DIR = 'diagnostics'
local MANIFEST_PATH = DUMP_DIR .. '/_manifest.json'

-- ReadOwnResourceFile lived in BOTH server/selfcheck.lua and
-- server/debugdump.lua as byte-identical copies -- invisible while they
-- were separate files, an actual shadowing duplicate once merged. The
-- Section 1 definition above is the surviving one; both call sites use it.

--- @param relativePath string
--- @param content string
--- @return boolean
local function SafeSaveResourceFile(relativePath, content)
    if type(SaveResourceFile) ~= 'function' or type(GetCurrentResourceName) ~= 'function' then return false end
    if type(relativePath) ~= 'string' or type(content) ~= 'string' then return false end
    local ok, result = pcall(SaveResourceFile, GetCurrentResourceName(), relativePath, content, #content)
    return ok == true and result == true
end

--- @param v any
--- @return boolean?
local function ClampBoolean(v)
    if v == true or v == false then return v end
    return nil
end

--- @param v any
--- @param min number
--- @param max number
--- @return number?
local function ClampNumber(v, min, max)
    if type(v) ~= 'number' or v ~= v then return nil end -- v ~= v rejects NaN
    if v < min then return min end
    if v > max then return max end
    return math.floor(v)
end

--- Whitelists a raw string down to `[%w%-_]` for safe use as ONE PATH
--- COMPONENT inside a SaveResourceFile fileName -- see this file's own
--- header "FILENAMES" for the full threat model this defends against.
--- @param raw any
--- @param fallback string
--- @return string
local function SanitizeForFilename(raw, fallback)
    if type(raw) ~= 'string' or raw == '' then return fallback end
    local cleaned = raw:gsub('[^%w%-]', '_'):gsub('_+', '_'):gsub('^_+', ''):gsub('_+$', '')
    if cleaned == '' then return fallback end
    -- Belt-and-suspenders: a string built ONLY from [%w_-] cannot contain
    -- '.', '/', or '\\' at all -- but this is checked explicitly anyway
    -- rather than trusted, since a bug in the substitution above feeding a
    -- path-escape straight into SaveResourceFile's own fileName argument
    -- would be a serious bug, not a cosmetic one.
    if cleaned:find('%.%.', 1, true) or cleaned:find('[/\\]') then return fallback end
    return cleaned
end

--- @param source number
--- @return string? citizenid, string? displayName
local function ResolvePlayerIdentity(source)
    local ok, citizenid, displayName = pcall(function()
        local Player = exports.qbx_core:GetPlayer(source)
        if not Player or not Player.PlayerData then return nil, nil end
        local id = Player.PlayerData.citizenid
        local name = nil
        local charinfo = Player.PlayerData.charinfo
        if type(charinfo) == 'table' and type(charinfo.firstname) == 'string' and type(charinfo.lastname) == 'string' then
            name = (charinfo.firstname .. ' ' .. charinfo.lastname):match('^%s*(.-)%s*$')
        end
        return id, name
    end)
    if not ok then return nil, nil end
    if type(citizenid) ~= 'string' or citizenid == '' then citizenid = nil end
    return citizenid, displayName
end

-- ======================================================================
-- SECTION 2 -- MINIMAL, DETERMINISTIC JSON ENCODER (see this file's own
-- header "DIFFABILITY" for why this exists instead of `json.encode`).
-- ======================================================================

--- @param orderedPairs table[] -- array of {key, value} 2-element arrays, IN THE EXACT ORDER TO EMIT
local function JsonObj(orderedPairs) return { __jsonKind = 'obj', pairs = orderedPairs } end
--- @param items any[] -- plain array, IN THE EXACT ORDER TO EMIT
local function JsonArr(items) return { __jsonKind = 'arr', items = items } end

local JSON_SIMPLE_ESCAPES = {
    ['\\'] = '\\\\', ['"'] = '\\"', ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t',
    ['\b'] = '\\b', ['\f'] = '\\f',
}

--- @param s string
--- @return string -- WITH surrounding quotes
local function JsonEncodeString(s)
    local escaped = s:gsub('[%c\\"]', function(c)
        return JSON_SIMPLE_ESCAPES[c] or ('\\u%04x'):format(c:byte())
    end)
    return '"' .. escaped .. '"'
end

local JsonEncodeValue -- forward declaration, for the obj/arr branches' own recursive calls

--- @param value any
--- @param depth number
--- @param buffer string[] -- appended to in place
JsonEncodeValue = function(value, depth, buffer)
    if value == nil then
        buffer[#buffer + 1] = 'null'
        return
    end

    local t = type(value)
    if t == 'string' then
        buffer[#buffer + 1] = JsonEncodeString(value)
    elseif t == 'boolean' then
        buffer[#buffer + 1] = value and 'true' or 'false'
    elseif t == 'number' then
        if value ~= value or value == math.huge or value == -math.huge then
            buffer[#buffer + 1] = 'null' -- NaN/inf have no JSON representation; never emit invalid JSON over one bad number
        else
            buffer[#buffer + 1] = tostring(value)
        end
    elseif t == 'table' and value.__jsonKind == 'obj' then
        local indent, childIndent = ('  '):rep(depth), ('  '):rep(depth + 1)
        if #value.pairs == 0 then
            buffer[#buffer + 1] = '{}'
        else
            buffer[#buffer + 1] = '{\n'
            for i, kv in ipairs(value.pairs) do
                buffer[#buffer + 1] = childIndent
                buffer[#buffer + 1] = JsonEncodeString(tostring(kv[1]))
                buffer[#buffer + 1] = ': '
                JsonEncodeValue(kv[2], depth + 1, buffer)
                buffer[#buffer + 1] = (i < #value.pairs) and ',\n' or '\n'
            end
            buffer[#buffer + 1] = indent .. '}'
        end
    elseif t == 'table' and value.__jsonKind == 'arr' then
        local indent, childIndent = ('  '):rep(depth), ('  '):rep(depth + 1)
        if #value.items == 0 then
            buffer[#buffer + 1] = '[]'
        else
            buffer[#buffer + 1] = '[\n'
            for i, item in ipairs(value.items) do
                buffer[#buffer + 1] = childIndent
                JsonEncodeValue(item, depth + 1, buffer)
                buffer[#buffer + 1] = (i < #value.items) and ',\n' or '\n'
            end
            buffer[#buffer + 1] = indent .. ']'
        end
    else
        -- Should never happen -- every call site in this file only ever
        -- hands this strings/numbers/booleans/JsonObj/JsonArr/nil. Falls
        -- back to a harmless placeholder string rather than throwing, per
        -- this file's own "must never break what it observes" rule.
        buffer[#buffer + 1] = JsonEncodeString('(unencodable value of type ' .. t .. ')')
    end
end

--- @param root table -- a JsonObj(...) or JsonArr(...)
--- @return string?
local function EncodeOrderedJson(root)
    local buffer = {}
    local ok = pcall(JsonEncodeValue, root, 0, buffer)
    if not ok then return nil end
    return table.concat(buffer)
end

-- ======================================================================
-- SECTION 3 -- MANIFEST / RETENTION (see this file's own header "WHY
-- EMPTYING, NOT DELETING").
-- ======================================================================

local EMPTIED_PLACEHOLDER = '{"readMeFirst":"This dump was emptied to keep this resource under Config.DebugDump.maxRetainedDumps. There is no verified CFX native for deleting a resource file outright, so old dumps are emptied instead of deleted -- see server/diagnostics.lua\'s own header, WHY EMPTYING NOT DELETING. Its real content is gone."}'

--- @return string[] -- filenames, oldest first; empty on any read/parse failure
local function LoadManifest()
    local content = ReadOwnResourceFile(MANIFEST_PATH)
    if not content then return {} end
    if type(json) ~= 'table' or type(json.decode) ~= 'function' then return {} end
    local ok, decoded = pcall(json.decode, content)
    if not ok or type(decoded) ~= 'table' then return {} end
    local out = {}
    for _, entry in ipairs(decoded) do
        if type(entry) == 'string' and entry ~= '' then out[#out + 1] = entry end
    end
    return out
end

--- @param list string[]
--- @return boolean
local function SaveManifest(list)
    if type(json) ~= 'table' or type(json.encode) ~= 'function' then return false end
    local ok, encoded = pcall(json.encode, list)
    if not ok or type(encoded) ~= 'string' then return false end
    return SafeSaveResourceFile(MANIFEST_PATH, encoded)
end

--- Mutates `manifest` in place: empties (never deletes) the oldest entries
--- until at most `cap` remain, dropping each emptied entry from the list.
--- @param manifest string[]
--- @param cap number
local function EnforceRetention(manifest, cap)
    while #manifest > cap do
        local oldest = table.remove(manifest, 1)
        if type(oldest) == 'string' then
            SafeSaveResourceFile(oldest, EMPTIED_PLACEHOLDER)
        end
    end
end

local dumpSeq = 0

--- @param citizenid string?
--- @param jsonContent string
--- @return string? filename, string? errorReason
local function WriteDumpFile(citizenid, jsonContent)
    dumpSeq = dumpSeq + 1
    local safeId = SanitizeForFilename(citizenid, 'unknown')
    local stamp = os.date('%Y%m%d_%H%M%S')
    local filename = ('%s/k9debug_%s_%s_%03d.json'):format(DUMP_DIR, safeId, stamp, dumpSeq % 1000)

    local cap = Config.DebugDump.maxRetainedDumps
    local manifest = LoadManifest()
    EnforceRetention(manifest, math.max(0, cap - 1)) -- make room for the one about to be added

    local wrote = SafeSaveResourceFile(filename, jsonContent)
    if not wrote then
        return nil, 'write_failed'
    end

    manifest[#manifest + 1] = filename
    SaveManifest(manifest) -- best-effort: a manifest write failure only affects FUTURE retention bookkeeping, never this dump's own success

    return filename, nil
end

-- ======================================================================
-- SECTION 4 -- RE-SURFACED / NEW CHECKS. See this file's own header for
-- which of these are full re-surfacings, which are partial (with the exact
-- accessible-data reasoning), and which are new. Every function below
-- degrades to an honest "could not verify" line rather than throwing.
-- ======================================================================

--- A1 -- see this file's own header for the full "why WORTH-CHECKING, not
--- FINDING, whenever a family is disabled" reasoning.
--- @return { findings: string[], worthChecking: string[] }
local function CheckFeatureGroupsDisagreement()
    local out = { findings = {}, worthChecking = {} }
    if type(Config.Features) ~= 'table' or type(Config.FeaturesBeforeGrouping) ~= 'table' then
        return out -- classic flat config.lua, or ResolveFeatureGroups never ran -- nothing to compare, nothing wrong
    end

    local anyFamilyDisabled = false
    if type(Config.FeatureGroups) == 'table' then
        for _, value in pairs(Config.FeatureGroups) do
            if type(value) == 'table' and value.enabled == false then
                anyFamilyDisabled = true
                break
            end
        end
    end

    local mismatchKeys = {}
    for key, flatValue in pairs(Config.FeaturesBeforeGrouping) do
        local current = Config.Features[key]
        if current ~= nil and current ~= flatValue then
            mismatchKeys[#mismatchKeys + 1] = key
        end
    end
    table.sort(mismatchKeys)

    for _, key in ipairs(mismatchKeys) do
        local flatValue, currentValue = Config.FeaturesBeforeGrouping[key], Config.Features[key]
        if anyFamilyDisabled then
            out.worthChecking[#out.worthChecking + 1] = ('Config.Features.%s was authored as %s but is currently in effect as %s. This MAY be an intentional cascade from a Config.FeatureGroups family that is currently disabled (at least one family in your config has enabled = false right now), or it may be a quiet, unintended override -- search config.lua for "%s" and check which Config.FeatureGroups family it belongs to and whether that family is the one you meant to turn off.'):format(key, tostring(flatValue), tostring(currentValue), key)
        else
            out.findings[#out.findings + 1] = ('Config.Features.%s was authored as %s but is currently in effect as %s, and no Config.FeatureGroups family is disabled right now -- so this is not an intentional cascade, Config.FeatureGroups is quietly overriding this flat switch on its own. Search config.lua for "%s" to find both settings and make them agree.'):format(key, tostring(flatValue), tostring(currentValue), key)
        end
    end
    return out
end

--- A2 (partial -- see this file's own header). @return string[] state, string[] worthChecking
local function CheckRuntimeOverrides()
    local state, worthChecking = {}, {}
    if type(K9Store) ~= 'table' or type(K9Store.Override_GetAll) ~= 'function' then
        state[#state + 1] = 'K9Store.Override_GetAll is not available -- cannot list runtime tablet overrides this run.'
        return state, worthChecking
    end

    local ok, rows = pcall(K9Store.Override_GetAll)
    if not ok or type(rows) ~= 'table' then
        state[#state + 1] = 'K9Store.Override_GetAll failed or returned something unexpected -- cannot list runtime tablet overrides this run.'
        return state, worthChecking
    end

    table.sort(rows, function(a, b) return tostring(a.override_key) < tostring(b.override_key) end)

    if #rows == 0 then
        state[#state + 1] = 'No runtime tablet overrides are currently active for any Config.Features flag or tunable.'
    end

    for _, row in ipairs(rows) do
        state[#state + 1] = ('override_key=%s kind=%s value=%s updated_by=%s updated_at=%s'):format(
            tostring(row.override_key), tostring(row.kind), tostring(row.value), tostring(row.updated_by), tostring(row.updated_at))

        if row.kind == 'feature' and type(row.override_key) == 'string' and type(Config.FeaturesBeforeGrouping) == 'table' then
            local name = row.override_key:match('^feature:(.+)$')
            local fileFlat = name and Config.FeaturesBeforeGrouping[name]
            if fileFlat ~= nil then
                local storedValue = (row.value == 'true')
                if fileFlat ~= storedValue then
                    worthChecking[#worthChecking + 1] = ('A tablet override for Config.Features.%s is currently stored as %s, while config.lua\'s own FLAT switch says %s. This comparison is against the flat switch ONLY (before any Config.FeatureGroups resolution) -- if Config.FeatureGroups also touches this key, this may not reflect the fully-resolved picture. The authoritative comparison is server/runtimecontrol.lua\'s own "HEADS UP" console line at boot -- check the server console history from the last restart for it.'):format(name, tostring(storedValue), tostring(fileFlat))
                end
            end
        end
    end
    return state, worthChecking
end

--- PERFORMANCE FIX (load audit, this pass): server/datastore.lua (~238KB)
--- cannot change while this resource is running, so its
--- EXPECTED_TABLE_COLUMNS extraction below is invariant for the lifetime of
--- the process -- re-reading and re-parsing the whole file on every single
--- /k9debug run (CheckDatabaseSchemaState calls ExtractDatastoreTableNames
--- unconditionally, every BuildReport) was pure waste past the first call.
--- Memoized here, module-level, nil-checked -- a SUCCESSFUL extraction is
--- cached forever; a FAILED one (nil -- unreadable file, anchors not found,
--- zero names parsed) is deliberately NEVER cached, so one transient read
--- failure (e.g. a hypothetical future sandboxed/restricted environment, or
--- a fixture in this file's own spec) can never poison every later run for
--- the remainder of this resource's uptime. This is now the ONLY source
--- file this diagnostic reads: the sibling dependency-list extraction that
--- used to sit beside it became a plain in-scope table reference when the
--- diagnostics merge brought both halves into this file (see
--- DependencyList below).
local datastoreTableNamesCache = nil

--- A3 -- reads server/datastore.lua's own EXPECTED_TABLE_COLUMNS table
--- NAMES straight out of its source text, so this list can never drift out
--- of sync with the real one (see this file's own header). Deliberately
--- narrow: it only ever locates ONE specific, named, delimited block via
--- exact anchor strings and extracts `identifier =` lines from inside it --
--- never a generic sweep of the file's text.
--- @return string[]?
local function ExtractDatastoreTableNames()
    if datastoreTableNamesCache ~= nil then return datastoreTableNamesCache end

    local src = ReadOwnResourceFile('server/datastore.lua')
    if not src then return nil end
    local startPos = src:find('local EXPECTED_TABLE_COLUMNS = {', 1, true)
    if not startPos then return nil end
    local endPos = src:find('\n}', startPos, true)
    if not endPos then return nil end
    local block = src:sub(startPos, endPos)
    local names = {}
    for name in block:gmatch('\n%s*(k9_[%w_]+)%s*=%s*{') do
        names[#names + 1] = name
    end
    if #names == 0 then return nil end
    datastoreTableNamesCache = names -- only a SUCCESSFUL parse is ever cached -- see this cache's own declaration comment above
    return names
end

-- Short, hand-written descriptions for the handful of tables an owner is
-- most likely to actually notice missing (matches DIAGNOSTIC_CHECKS.md
-- §A3's own priority list) -- written fresh for this file, NOT copied from
-- server/datastore.lua's own MISSING_TABLE_FEATURE_DESCRIPTIONS (a `local`
-- this file has no access to and does not own). Any table not in this map
-- is still reported, just by its bare name -- see CheckDatabaseSchemaState.
local NOTABLE_TABLE_DESCRIPTIONS = {
    k9_wellbeing = 'K9 fatigue',
    k9_dog_characters = 'admin-pinned "this citizenid is permanently a dog" records (/k9setdog)',
    k9_personnel = 'the K9/Handler roster assignments and callsigns',
    k9_individual_overrides = 'per-officer speed/scent/cooldown overrides',
    k9_certifications = 'certifications (who is certified, and at what tier)',
    k9_partnerships = 'K9/handler partnerships',
    k9_progression = 'XP and handler XP',
    k9_permissions = 'individual permission grants and per-person feature blocks',
}

--- @return string[] findings, string[] state
local function CheckDatabaseSchemaState()
    local findings, state = {}, {}
    if type(K9Store) ~= 'table' or type(K9Store.IsDatabaseEnabled) ~= 'function' then
        state[#state + 1] = 'K9Store is not available -- cannot check database schema state this run.'
        return findings, state
    end

    if type(K9Store.WaitForSchemaCheckToSettle) == 'function' then
        pcall(K9Store.WaitForSchemaCheckToSettle)
    end

    local wholeOk, wholeEnabled = pcall(K9Store.IsDatabaseEnabled)
    if wholeOk and wholeEnabled == false then
        findings[#findings + 1] = 'The ENTIRE resource is running memory-only this session -- either Config.Database.enabled is false, the database is unreachable, or server/datastore.lua found a whole-resource schema collision at boot. Nothing saved to ANY table will survive a restart. Check the server console from this boot for server/datastore.lua\'s own "SCHEMA COLLISION" warning.'
    end

    local names = ExtractDatastoreTableNames()
    if not names then
        state[#state + 1] = 'Could not automatically read the list of tables this resource expects from server/datastore.lua -- skipping the per-table breakdown. This never blocks anything else in this dump.'
        return findings, state
    end
    table.sort(names)

    for _, name in ipairs(names) do
        local ok, enabled = pcall(K9Store.IsDatabaseEnabled, name)
        local description = NOTABLE_TABLE_DESCRIPTIONS[name]
        if ok and enabled == false then
            local line = description
                and ('Table `%s` (%s) is memory-only this session -- it either does not exist yet (run your migrations) or its columns do not match what this resource expects (a name collision with a different resource\'s table). Data in it will NOT survive a restart.'):format(name, description)
                or ('Table `%s` is memory-only this session (missing, or a schema collision).'):format(name)
            if description then
                findings[#findings + 1] = line
            else
                state[#state + 1] = line
            end
        elseif ok then
            state[#state + 1] = ('Table `%s`: OK (database-backed).'):format(name)
        else
            state[#state + 1] = ('Table `%s`: could not verify (K9Store.IsDatabaseEnabled threw).'):format(name)
        end
    end
    return findings, state
end

--- A4 -- the dependency list this check needs.
---
--- THIS USED TO BE A FILE READ. Before the diagnostics merge, DEPENDENCIES
--- was a file-local of server/selfcheck.lua and the dump lived in a
--- different file, so the only way to reach it was to LoadResourceFile that
--- ~45KB source and pattern-match the table back out of its own text --
--- with a memoization cache, a parse that could fail, and a "could not read
--- the dependency list" degraded path to go with it. The merge put both
--- halves in this one file, so DEPENDENCIES is simply in scope here now:
--- the read, the parse, the cache and the failure mode all go away, and
--- what the dump reports can no longer drift from what the boot check
--- actually enforces, because they are now literally the same table.
--- @return { name: string, minVersion: string }[]
local function DependencyList()
    return DEPENDENCIES
end

--- @return string[]
local function CheckDependencyVersions()
    local state = {}
    if type(K9SelfCheck) ~= 'table' or type(K9SelfCheck.EvaluateDependencyVersion) ~= 'function' or type(K9SelfCheck.FormatDependencyWarning) ~= 'function' then
        state[#state + 1] = 'K9SelfCheck is not available -- cannot re-check dependency versions this run.'
        return state
    end
    if type(GetResourceState) ~= 'function' or type(GetResourceMetadata) ~= 'function' then
        state[#state + 1] = 'GetResourceState/GetResourceMetadata are not available in this environment -- cannot re-check dependency versions this run.'
        return state
    end

    local deps = DependencyList()

    for _, dep in ipairs(deps) do
        local okState, resourceState = pcall(GetResourceState, dep.name)
        resourceState = (okState and type(resourceState) == 'string') and resourceState or 'unknown'
        local version = nil
        if resourceState == 'started' then
            local okVer, v = pcall(GetResourceMetadata, dep.name, 'version', 0)
            if okVer and type(v) == 'string' and v ~= '' then version = v end
        end
        local verdict = K9SelfCheck.EvaluateDependencyVersion(resourceState, version, dep.minVersion)
        local line = K9SelfCheck.FormatDependencyWarning(dep, verdict)
        state[#state + 1] = line or ('%s: ok (%s, minimum checked-compatible version %s)'):format(dep.name, version or resourceState, dep.minVersion)
    end
    return state
end

--- B1 -- one-shot world-model census. NEVER a finding -- see this file's
--- own header for both disclosed caveats. Returns nil, nil for both if the
--- relevant feature(s) are off (nothing to scan) or the required natives
--- are unavailable.
--- @return number? matches, number? modelCount
local function ScanForConfiguredWorldModels(modelNames)
    if type(modelNames) ~= 'table' or #modelNames == 0 then return nil, nil end
    if type(GetAllObjects) ~= 'function' or type(GetAllVehicles) ~= 'function'
        or type(GetEntityModel) ~= 'function' or type(GetHashKey) ~= 'function' then
        return nil, nil
    end

    local hashSet, hashCount = {}, 0
    for _, name in ipairs(modelNames) do
        if type(name) == 'string' and name ~= '' then
            local ok, hash = pcall(GetHashKey, name)
            if ok and hash then
                if not hashSet[hash] then hashCount = hashCount + 1 end
                hashSet[hash] = true
            end
        end
    end
    if hashCount == 0 then return nil, nil end

    local matches = 0
    local okObj, objs = pcall(GetAllObjects)
    if okObj and type(objs) == 'table' then
        for _, obj in ipairs(objs) do
            local okm, model = pcall(GetEntityModel, obj)
            if okm and hashSet[model] then matches = matches + 1 end
        end
    end
    local okVeh, vehs = pcall(GetAllVehicles)
    if okVeh and type(vehs) == 'table' then
        for _, veh in ipairs(vehs) do
            local okm, model = pcall(GetEntityModel, veh)
            if okm and hashSet[model] then matches = matches + 1 end
        end
    end
    return matches, hashCount
end

--- @return string[] worthChecking
local function CheckWorldPropScans()
    local out = {}
    if type(Config.Features) ~= 'table' or type(Config.Wellbeing) ~= 'table' then return out end

    if Config.Features.FatigueSystem == true and type(Config.Wellbeing.Fatigue) == 'table' then
        local matches, modelCount = ScanForConfiguredWorldModels(Config.Wellbeing.Fatigue.restSources)
        if matches ~= nil then
            out[#out + 1] = ('Config.Wellbeing.Fatigue.restSources (%d configured model name(s)): %d currently-spawned/networked object or vehicle entity match(es) found in THIS ONE SCAN, just now. A single scan finding zero proves very little -- run /k9debug again at different points in a real testing session before treating a repeated zero as meaningful. Even a sustained zero is not proof the model name is wrong: GetAllObjects()/GetAllVehicles() only see currently networked/spawned entities, never static .ymap map decoration -- a correct model name for a prop placed only as map scenery will report zero matches forever, correctly.'):format(modelCount, matches)
        end
    end


    return out
end

--- B2. @return string -- 'ok' | 'missing' | 'invalid_name' | 'not_running' | 'unverifiable'
local function CheckOxInventoryItemExists(itemName)
    if type(itemName) ~= 'string' or itemName == '' then return 'invalid_name' end
    if type(GetResourceState) == 'function' then
        local ok, state = pcall(GetResourceState, 'ox_inventory')
        if ok and state ~= 'started' then return 'not_running' end
    end
    local ok, item = pcall(function() return exports.ox_inventory:Items(itemName) end)
    if not ok then return 'unverifiable' end
    if not item then return 'missing' end
    return 'ok'
end

--- @return string[] findings
local function CheckItemExistence()
    local findings = {}
    if type(Config.Features) ~= 'table' then return findings end

    --- @param itemName any
    --- @param configPath string
    --- @param featureFlagName string
    local function CheckOne(itemName, configPath, featureFlagName)
        local status = CheckOxInventoryItemExists(itemName)
        if status == 'missing' then
            findings[#findings + 1] = ('%s is enabled and %s is set to %q, but that item does not exist in your ox_inventory item registry. Every attempt to use this feature will silently fail as a generic "you do not have that item" error. Add %q to ox_inventory\'s data/items.lua, or point %s at a real item name.'):format(featureFlagName, configPath, itemName, itemName, configPath)
        elseif status == 'invalid_name' then
            findings[#findings + 1] = ('%s is enabled but %s is not a valid, non-empty item name (found: %s) -- cannot verify it against ox_inventory at all.'):format(featureFlagName, configPath, tostring(itemName))
        end
        -- 'ok' / 'not_running' / 'unverifiable' -- all reported nowhere:
        -- 'ok' has nothing worth saying, and 'not_running'/'unverifiable'
        -- are a limitation of THIS check, not evidence of a real problem
        -- (see this file's own header -- other inventory backends have no
        -- server-side existence check in this resource's compat contract).
    end

    if Config.Features.K9Medkit == true and type(Config.K9Medkit) == 'table' then
        CheckOne(Config.K9Medkit.itemName, 'Config.K9Medkit.itemName', 'Config.Features.K9Medkit')
    end

    return findings
end

--- H1. @return string[]
local function CheckSelfGrantSwitches()
    local a = type(Config.HighCommand) == 'table' and Config.HighCommand.allowSelfGrant
    local b = type(Config.FeatureControl) == 'table' and Config.FeatureControl.allowHighCommandSelfGrant
    return {
        ('Config.HighCommand.allowSelfGrant = %s -- controls whether a rank-based High Command officer can grant themselves an explicit k9_permissions row (a certification, specialization, or admin capability) through the normal grant commands.'):format(tostring(a)),
        ('Config.FeatureControl.allowHighCommandSelfGrant = %s -- a SEPARATE switch controlling High Command\'s own rank-based bypass acting on themselves. Both default true; disagreeing values are a valid, intentional configuration, not a bug -- see KNOWN_ISSUES.md.'):format(tostring(b)),
    }
end

--- Known, disclosed gaps -- checks this file could not build with full
--- fidelity because the data they need is `local` to a file this pass does
--- not own. See this file's own header for the full reasoning on each.
local KNOWN_GAPS = {
    'F1 (asymmetric leash/partnership pairs) is NOT checked -- LeashPairs is `local` to server/main.lua with no export. Would need a small read-only accessor added there.',
    'F3 (an active Bite/Hold/Takedown/Drag past its own hard expiry) is NOT checked -- ActiveHolds is `local` to server/combat.lua with no export.',
    'E1 (a per-dog speed override above the movement engine\'s real ceiling) is NOT checked -- DescribeSpeedOverrideCeiling/RefreshOverrideCache are `local` to server/k9profiles.lua with no export.',
    'A2\'s tuning-kind overrides (numeric tunables set from the tablet) are listed above as raw state but NOT compared against config.lua -- TUNABLE_REGISTRY and config.lua\'s own tunable defaults are `local` to server/runtimecontrol.lua with no export.',
}

-- ======================================================================
-- SECTION 5 -- THE DECISION TRAIL (verbose level only). See this file's
-- own header for the full design/risk writeup.
-- ======================================================================

local DECISION_TRAIL_CAP = 300
local DecisionTrail = {}
local decisionTrailWriteIndex = 0
local decisionTrailFilled = 0
local decisionTrailSeq = 0
local decisionWrappingInstalled = false

--- @param fnName string
--- @param resultValue any
--- @param arg1 any -- kept RAW (not stringified) so report-time filtering can match a citizenid or resolve a source
--- @param argsDisplay string
local function RecordDecision(fnName, resultValue, arg1, argsDisplay)
    decisionTrailSeq = decisionTrailSeq + 1
    decisionTrailWriteIndex = (decisionTrailWriteIndex % DECISION_TRAIL_CAP) + 1
    DecisionTrail[decisionTrailWriteIndex] = {
        seq = decisionTrailSeq,
        fn = fnName,
        arg1 = arg1,
        argsDisplay = argsDisplay,
        result = resultValue,
        at = (type(GetGameTimer) == 'function') and GetGameTimer() or 0,
    }
    if decisionTrailFilled < DECISION_TRAIL_CAP then decisionTrailFilled = decisionTrailFilled + 1 end
end

local function InstallDecisionWrapping()
    if decisionWrappingInstalled then return end
    decisionWrappingInstalled = true

    local function WrapGlobal(name)
        local original = _G[name]
        if type(original) ~= 'function' then
            print(('[qbx_k9unit] debugdump: %s is not currently a global function -- the verbose decision trail will not include it this session.'):format(name))
            return
        end
        _G[name] = function(...)
            -- THE REAL CALL, FIRST, UNCONDITIONALLY, UNTOUCHED. Everything
            -- below this line is recording only and is itself pcall-guarded
            -- so a bug in recording can NEVER change what this returns.
            local result = original(...)
            local n = select('#', ...)
            local arg1 = (...)
            local parts = { ... }
            for i = 1, n do parts[i] = tostring(parts[i]) end
            pcall(RecordDecision, name, result, arg1, table.concat(parts, ', ', 1, n))
            return result
        end
    end

    WrapGlobal('HasK9Access')
    WrapGlobal('IsHighCommand')
    WrapGlobal('HasPermission')
end

if Config.DebugDump.level == 'verbose' then
    InstallDecisionWrapping()
end

--- @param entry table -- one DecisionTrail slot
--- @param citizenid string
--- @return boolean
local function DecisionEntryBelongsTo(entry, citizenid)
    if entry.fn == 'HasPermission' then
        return entry.arg1 == citizenid
    end
    -- HasK9Access/IsHighCommand: arg1 is a source number at capture time.
    -- Resolved FRESH here (best-effort -- the player may have reconnected
    -- with a different source since this entry was recorded, in which case
    -- this entry simply will not match anymore, which is the safe failure
    -- direction for "own state only").
    if type(entry.arg1) == 'number' then
        local ok, resolvedId = pcall(function()
            local Player = exports.qbx_core:GetPlayer(entry.arg1)
            return Player and Player.PlayerData and Player.PlayerData.citizenid
        end)
        return ok and resolvedId == citizenid
    end
    return false
end

--- @param citizenid string
--- @return string[]? lines, string? unavailableReason
local function BuildDecisionTrailLines(citizenid)
    if not decisionWrappingInstalled then
        return nil, 'Verbose decision-trail wrapping was never installed this session (Config.DebugDump.level was not "verbose" when this resource started).'
    end

    local entries = {}
    for i = 1, decisionTrailFilled do
        local entry = DecisionTrail[i]
        if entry and DecisionEntryBelongsTo(entry, citizenid) then
            entries[#entries + 1] = entry
        end
    end
    table.sort(entries, function(a, b) return a.seq < b.seq end)

    if #entries == 0 then
        return {}, ('No recorded HasK9Access/IsHighCommand/HasPermission calls for citizenid %s yet this session (this trail holds only the most recent %d calls RESOURCE-WIDE -- yours may have scrolled out of it, or you simply have not triggered one of these checks yet).'):format(citizenid, DECISION_TRAIL_CAP)
    end

    local lines = {}
    for _, entry in ipairs(entries) do
        lines[#lines + 1] = ('#%d t=%sms %s(%s) -> %s'):format(entry.seq, tostring(entry.at), entry.fn, entry.argsDisplay, tostring(entry.result))
    end
    return lines, nil
end

-- ======================================================================
-- SECTION 6 -- CLIENT SELF-REPORT (client/diagnostics.lua's own heartbeat).
-- Own-state-only, never accumulating, never trusted for anything but
-- display -- see this file's own header and client/diagnostics.lua's.
-- ======================================================================

local ClientSelfReports = {} -- source -> { receivedAtServerMs = number, data = table }
local HeartbeatCooldown = NewCooldown(2000)
HeartbeatCooldown.RegisterPlayerDropped()

RegisterNetEvent('qbx_k9unit:server:debugDumpClientHeartbeat')
AddEventHandler('qbx_k9unit:server:debugDumpClientHeartbeat', function(payload)
    local src = source
    if type(src) ~= 'number' or src <= 0 then return end
    if not HeartbeatCooldown.Consume(src) then return end -- a modified client spamming this event beyond a sane rate is simply ignored, never processed
    if type(payload) ~= 'table' then return end

    -- Every field is independently type/range-clamped -- this payload comes
    -- from the calling player's own client, which this file treats as
    -- adversarial input like any other inbound net event, even though the
    -- worst case here is only a misleading line in that SAME player's own
    -- diagnostic dump (never money/items/permissions -- nothing here is
    -- ever used for an authorization decision).
    ClientSelfReports[src] = {
        receivedAtServerMs = (type(GetGameTimer) == 'function') and GetGameTimer() or 0,
        data = {
            modelHash = ClampNumber(payload.modelHash, 0, 4294967295),
            pedHealth = ClampNumber(payload.pedHealth, 0, 2000),
            pedMaxHealth = ClampNumber(payload.pedMaxHealth, 0, 2000),
            isDead = ClampBoolean(payload.isDead),
            isRagdoll = ClampBoolean(payload.isRagdoll),
            inVehicle = ClampBoolean(payload.inVehicle),
            vehicleModelHash = ClampNumber(payload.vehicleModelHash, 0, 4294967295),
            nuiFocused = ClampBoolean(payload.nuiFocused),
            clientGameTimerMs = ClampNumber(payload.clientGameTimerMs, 0, math.huge),
        },
    }
end)

AddEventHandler('playerDropped', function()
    ClientSelfReports[source] = nil
end)

-- ======================================================================
-- SECTION 7 -- REPORT ASSEMBLY
-- ======================================================================

local ownVersionCache = nil
local function GetOwnVersion()
    if ownVersionCache == nil then
        if type(GetCurrentResourceName) == 'function' and type(GetResourceMetadata) == 'function' then
            local ok, v = pcall(GetResourceMetadata, GetCurrentResourceName(), 'version', 0)
            ownVersionCache = (ok and type(v) == 'string' and v ~= '') and v or false
        else
            ownVersionCache = false
        end
    end
    return ownVersionCache or 'unknown'
end

--- @param clientReport table? -- ClientSelfReports[source], or nil
--- @return table -- JsonObj
local function BuildClientStateObj(clientReport)
    if not clientReport then
        return JsonObj({
            { 'received', false },
            { 'note', 'No client self-report received yet this session (the player may have connected very recently -- client/diagnostics.lua sends one within a few seconds of loading, and every 5 seconds after that while Config.DebugDump.enabled is true).' },
        })
    end
    local d = clientReport.data
    return JsonObj({
        { 'received', true },
        { 'ageMs', (type(GetGameTimer) == 'function' and GetGameTimer() or 0) - clientReport.receivedAtServerMs },
        { 'modelHash', d.modelHash },
        { 'pedHealth', d.pedHealth },
        { 'pedMaxHealth', d.pedMaxHealth },
        { 'isDead', d.isDead },
        { 'isRagdoll', d.isRagdoll },
        { 'inVehicle', d.inVehicle },
        { 'vehicleModelHash', d.vehicleModelHash },
        { 'nuiFocused', d.nuiFocused },
        { 'clientGameTimerMs', d.clientGameTimerMs },
    })
end

--- @param stringList string[]
--- @return table -- JsonArr of strings
local function StringArr(stringList)
    return JsonArr(stringList)
end

--- @param source number
--- @param citizenid string
--- @param displayName string?
--- @param level string -- 'normal' | 'verbose', for THIS dump only
--- A5 -- THE BOOT SELF-CHECKS, ON DEMAND. Only possible since the merge:
--- these five runners used to live in server/selfcheck.lua and fired once,
--- at resource start, printing to the console. An operator who missed that
--- line (or restarted before reading it, or is reading a dump someone else
--- generated) had no way to get it back short of restarting the server.
---
--- Runs the SAME functions the boot handler runs, so a dump and the console
--- line can never disagree -- there is one implementation of each check, not
--- a dump-flavoured copy of it.
---
--- DELIBERATELY RE-RUN RATHER THAN CACHED FROM BOOT: every one of these
--- reads live config and live resource state, so re-running answers "is
--- anything wrong NOW", which is what someone running a diagnostic wants --
--- a cached boot verdict would be stale the moment a runtime override or a
--- dependency restart changed the answer.
--- @return table findings, table worthChecking
local function CheckBootSelfChecks()
    local findings, worthChecking = {}, {}

    -- Each runner prints its own warnings as a side effect (that is what
    -- makes the boot line useful); what comes back is the structured verdict.
    local depOk, depResult = pcall(RunDependencyCheck)
    if not depOk then
        findings[#findings + 1] = 'dependency check itself errored: ' .. tostring(depResult)
    elseif type(depResult) == 'table' and depResult.problems and depResult.problems > 0 then
        findings[#findings + 1] = ('%d dependency problem(s) -- see the console warnings above for which resource and which version'):format(depResult.problems)
    end

    local featOk, featResult = pcall(RunFeatureKeyCheck)
    if not featOk then
        findings[#findings + 1] = 'Config.Features key check itself errored: ' .. tostring(featResult)
    elseif type(featResult) == 'table' and featResult.unrecognized and featResult.unrecognized > 0 then
        findings[#findings + 1] = ('%d unrecognized Config.Features key(s) -- a typo here means the feature behind it is silently off'):format(featResult.unrecognized)
    end

    local specOk, specErr = pcall(RunSpecializationGateCheck)
    if not specOk then
        worthChecking[#worthChecking + 1] = 'specialization-gate check itself errored: ' .. tostring(specErr)
    end

    local deptOk, deptErr = pcall(RunDepartmentJobNameCheck)
    if not deptOk then
        worthChecking[#worthChecking + 1] = 'department job-name check itself errored: ' .. tostring(deptErr)
    end

    local shopOk, shopResult = pcall(RunEquipmentShopEnforcementCheck)
    if not shopOk then
        worthChecking[#worthChecking + 1] = 'equipment-shop enforcement check itself errored: ' .. tostring(shopResult)
    elseif type(shopResult) == 'table' and shopResult.status and shopResult.status ~= 'ok' then
        worthChecking[#worthChecking + 1] = 'equipment shop enforcement: ' .. tostring(shopResult.status)
    end

    return findings, worthChecking
end

--- @param trigger string -- 'command' | 'auto_on_boot'
--- @return string? jsonText, number findingCount, number worthCheckingCount
local function BuildReport(source, citizenid, displayName, level, trigger)
    local findings, worthChecking = {}, {}

    local a1 = CheckFeatureGroupsDisagreement()
    for _, l in ipairs(a1.findings) do findings[#findings + 1] = '[A1] ' .. l end
    for _, l in ipairs(a1.worthChecking) do worthChecking[#worthChecking + 1] = '[A1] ' .. l end

    local a2State, a2Worth = CheckRuntimeOverrides()
    for _, l in ipairs(a2Worth) do worthChecking[#worthChecking + 1] = '[A2] ' .. l end

    local a3Findings, a3State = CheckDatabaseSchemaState()
    for _, l in ipairs(a3Findings) do findings[#findings + 1] = '[A3] ' .. l end

    local a4State = CheckDependencyVersions()

    local b1Worth = CheckWorldPropScans()
    for _, l in ipairs(b1Worth) do worthChecking[#worthChecking + 1] = '[B1] ' .. l end

    local b2Findings = CheckItemExistence()
    for _, l in ipairs(b2Findings) do findings[#findings + 1] = '[B2] ' .. l end

    local h1State = CheckSelfGrantSwitches()

    -- A5 -- the boot self-checks, re-run live. See CheckBootSelfChecks().
    local a5Findings, a5Worth = CheckBootSelfChecks()
    for _, l in ipairs(a5Findings) do findings[#findings + 1] = '[A5] ' .. l end
    for _, l in ipairs(a5Worth) do worthChecking[#worthChecking + 1] = '[A5] ' .. l end

    local decisionTrailLines, decisionTrailNote = nil, nil
    if level == 'verbose' then
        decisionTrailLines, decisionTrailNote = BuildDecisionTrailLines(citizenid)
    end

    local generatedAt = os.date('%Y-%m-%d %H:%M:%S')

    local readMeFirst = ('K9 Debug Dump for %s (citizenid %s), generated %s -- level: %s, trigger: %s.\n\n' ..
        '%d FINDING(S) below (see "findings"): things this resource is confident are actually wrong, worst first.\n' ..
        '%d WORTH-CHECKING item(s) below (see "worthChecking"): suspicious, with an innocent explanation possible -- read as questions, not verdicts.\n' ..
        'Everything else ("fullState") is exhaustive raw detail with no judgement attached -- meant to be searched, not read top to bottom. ' ..
        'See "fullState.knownGaps" for what this tool could NOT check and why.'
    ):format(displayName or 'unknown', citizenid, generatedAt, level, trigger, #findings, #worthChecking)

    local fullStatePairs = {
        { 'dependencyVersions', StringArr(a4State) },
        { 'databaseTables', StringArr(a3State) },
        { 'runtimeOverrides', StringArr(a2State) },
        { 'selfGrantSwitches', StringArr(h1State) },
        { 'clientSelfReport', BuildClientStateObj(ClientSelfReports[source]) },
        { 'knownGaps', StringArr(KNOWN_GAPS) },
    }

    if level == 'verbose' then
        fullStatePairs[#fullStatePairs + 1] = { 'decisionTrail', decisionTrailLines and StringArr(decisionTrailLines) or JsonArr({}) }
        if decisionTrailNote then
            fullStatePairs[#fullStatePairs + 1] = { 'decisionTrailNote', decisionTrailNote }
        end
    end

    local root = JsonObj({
        { 'readMeFirst', readMeFirst },
        { 'findings', StringArr(findings) },
        { 'worthChecking', StringArr(worthChecking) },
        { 'meta', JsonObj({
            { 'generatedAt', generatedAt },
            { 'resourceVersion', GetOwnVersion() },
            { 'requestedByCitizenid', citizenid },
            { 'requestedByName', displayName },
            { 'level', level },
            { 'trigger', trigger },
        }) },
        { 'fullState', JsonObj(fullStatePairs) },
    })

    return EncodeOrderedJson(root), #findings, #worthChecking
end

-- ======================================================================
-- SECTION 8 -- THE COMMAND. Own state only: `source` is the ONLY identity
-- this ever reads, never a target argument -- there is no target argument
-- at all, on purpose (see this file's own header).
-- ======================================================================

local DebugDumpCommandCooldown = NewCooldown(10000)
DebugDumpCommandCooldown.RegisterPlayerDropped()

RegisterCommand('k9debug', function(source, args)
    if type(source) ~= 'number' or source == 0 then
        print('[qbx_k9unit] /k9debug must be run by a connected player, not the server console -- it dumps that PLAYER\'s own state.')
        return
    end

    if not DebugDumpCommandCooldown.Consume(source) then
        NotifyPlayer(source, locale('debugdump.cooldown'), 'error')
        return
    end

    local citizenid, displayName = ResolvePlayerIdentity(source)
    if not citizenid then
        NotifyPlayer(source, locale('debugdump.no_citizenid'), 'error')
        return
    end

    local level = Config.DebugDump.level
    local rawArg = args[1] and tostring(args[1]):lower() or nil
    if rawArg ~= nil then
        if rawArg == 'normal' or rawArg == 'verbose' then
            if rawArg == 'verbose' and Config.DebugDump.level ~= 'verbose' then
                NotifyPlayer(source, locale('debugdump.verbose_not_collected'), 'error')
                level = 'normal'
            else
                level = rawArg
            end
        else
            NotifyPlayer(source, locale('debugdump.bad_level_arg', tostring(args[1]), Config.DebugDump.level), 'error')
            level = Config.DebugDump.level
        end
    end

    local reportJson, findingCount, worthCheckingCount = BuildReport(source, citizenid, displayName, level, 'command')
    if type(reportJson) ~= 'string' then
        NotifyPlayer(source, locale('debugdump.write_failed'), 'error')
        return
    end

    local filename, writeErr = WriteDumpFile(citizenid, reportJson)
    if writeErr or not filename then
        NotifyPlayer(source, locale('debugdump.write_failed'), 'error')
        return
    end

    NotifyPlayer(source, locale('debugdump.written', filename, findingCount, worthCheckingCount), 'success')
end, false)

-- ======================================================================
-- SECTION 9 -- autoOnBoot. Resource-wide facts only (no requesting player,
-- so no citizenid-scoped section -- decision trail/client self-report are
-- both meaningless here and are simply omitted).
-- ======================================================================

if Config.DebugDump.autoOnBoot == true then
    AddEventHandler('onResourceStart', function(resourceName)
        if type(GetCurrentResourceName) == 'function' and GetCurrentResourceName() ~= resourceName then return end

        local a1 = CheckFeatureGroupsDisagreement()
        local a3Findings = CheckDatabaseSchemaState()
        local b2Findings = CheckItemExistence()

        local totalFindings = #a1.findings + #a3Findings + #b2Findings
        if totalFindings == 0 then
            return -- a clean boot writes nothing extra -- see Config.DebugDump.autoOnBoot's own comment in config.lua
        end

        local findings = {}
        for _, l in ipairs(a1.findings) do findings[#findings + 1] = '[A1] ' .. l end
        for _, l in ipairs(a3Findings) do findings[#findings + 1] = '[A3] ' .. l end
        for _, l in ipairs(b2Findings) do findings[#findings + 1] = '[B2] ' .. l end

        local generatedAt = os.date('%Y-%m-%d %H:%M:%S')
        local readMeFirst = ('K9 Debug Dump (automatic, at boot), generated %s -- %d finding(s) were found during this resource\'s own boot-time checks. See "findings" below.'):format(generatedAt, #findings)

        local root = JsonObj({
            { 'readMeFirst', readMeFirst },
            { 'findings', StringArr(findings) },
            { 'meta', JsonObj({
                { 'generatedAt', generatedAt },
                { 'resourceVersion', GetOwnVersion() },
                { 'trigger', 'auto_on_boot' },
            }) },
        })

        local jsonText = EncodeOrderedJson(root)
        if type(jsonText) ~= 'string' then return end

        WriteDumpFile('boot', jsonText)
    end)
end
