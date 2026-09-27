-- Root luacheck config for this repo.
--
-- Scope: currently only qbx_k9unit/ has Lua code, but this file is kept at
-- the repo root (not qbx_k9unit/.luacheckrc) per the "one shared root config
-- beats a different one per resource" rule, so a second resource dropped in
-- later inherits it automatically.
--
-- WHY THIS EXISTS ONLY AS A LINT CONFIG, NOT A FORMATTER: a stylua/format
-- config was deliberately rejected earlier for this codebase because of
-- genuine, intentional style choices a blanket formatter would rewrite away
-- (column-aligned tables, native-call argument grouping, the FiveM manifest
-- DSL). luacheck is pure lint -- it only reports, it never rewrites a single
-- byte -- so it does not carry that risk. What it DOES carry is false-positive
-- risk from not knowing FXServer/CFX natives or this resource's own
-- cross-file globals; the two blocks below exist specifically to eliminate
-- that, not to invent new rules.

std = "lua54" -- matches the actual runtime: .github/workflows/lua-check.yml
              -- already validates every file with luac5.4.

-- fxmanifest.lua is a declarative resource-manifest DSL (fx_version, game,
-- dependencies{}, shared_scripts{}, etc.), not procedural logic -- there is
-- no meaningful "unused variable" or "undefined global" bug class in it, only
-- an ever-growing set of DSL keywords (files, server_only, provide,
-- escrow_ignore, ...) that would need constant upkeep here for zero payoff.
-- Its syntax is already checked by the existing luac5.4 job. Excluded here
-- rather than allowlisted.
exclude_files = {
    "**/fxmanifest.lua",
}

-- Read-only: FiveM/CFX natives and the implicit server-event `source` global
-- this codebase actually calls. This list was generated FROM this
-- codebase's real usage (`luacheck qbx_k9unit` run with no config, then every
-- "accessing undefined variable" finding that is a genuine engine/runtime
-- global rather than a typo was pulled out) -- it is not a speculative
-- everything-native list, so it should stay in sync with actual usage: if a
-- newly-added file's `luacheck` run reports a NEW "accessing undefined
-- variable" for a real native, add it here rather than reaching for a
-- suppression comment.
read_globals = {
    -- Threading / events
    "CreateThread", "Wait", "AddEventHandler", "RegisterNetEvent",
    "TriggerClientEvent", "TriggerServerEvent", "TriggerEvent", "RegisterCommand",
    -- Cancellable-wait primitives, needed by any thread that must abort a long
    -- sleep early instead of polling on a short Wait (client/combat.lua's
    -- suppression thread is the first such consumer). These are NOT natives and
    -- so have no ext/native-decls entry -- the 404 there means nothing for them.
    -- VERIFIED against primary source instead, in the Lua runtime itself:
    --   data/shared/citizen/scripting/lua/deferred.lua sets `_G.promise = M`
    --   data/shared/citizen/scripting/lua/scheduler.lua:114 sets
    --     `SetTimeout = Citizen.SetTimeout`
    -- and code/components/citizen-scripting-lua/src/LuaScriptRuntime.cpp loads
    -- BOTH files unconditionally via LoadSystemFile at runtime init. That
    -- component is the shared Lua runtime, so both globals exist on client and
    -- server alike -- no per-side qualification needed.
    "promise", "SetTimeout",
    -- GetConvarInt: server/bonetool.lua reads the second, explicit opt-in
    --   convar that must be set on top of Config.Features.BoneSweepDevTool
    --   before the dev-only /k9bonetool command will register at all.
    -- NetworkGetEntityOwner: server/propattachment.lua verifies which client
    --   actually owns a networked entity, so a client-supplied netId cannot
    --   be pointed at another player's real object.
    -- Both VERIFIED server-callable on 2026-08-25, not assumed: fetching
    -- citizenfx/fivem ext/native-decls/<Name>.md returns HTTP 200 with
    -- `ns: CFX` and `apiset: shared` for each. This matters because FXServer
    -- does NOT throw on an unregistered native -- the result buffer is never
    -- written, so the call returns zero/nil forever with nothing logged. Six
    -- such silent no-ops have already been found in this resource, including
    -- four death-check gates that had never once fired. Never allowlist a
    -- native here on an assumption; run the check.
    "GetConvarInt", "NetworkGetEntityOwner",
    -- client/tablet.lua's NUI focus handling. Both verified 2026-08-25
    -- rather than assumed, by two different routes because they answer
    -- differently:
    --   SetNuiFocus -- ext/native-decls/SetNuiFocus.md returns HTTP 200,
    --     ns: CFX, apiset: client. Directly confirmed.
    --   IsDisabledControlJustPressed -- its decl page 404s, which for a
    --     legacy R* native means "no CFX decl page was ever written", NOT
    --     "does not exist". Confirmed instead against the official
    --     natives.json: IS_DISABLED_CONTROL_JUST_PRESSED, hash
    --     0x91AEF906BCA88877. Several equally ubiquitous legacy natives
    --     already in this list (IsEntityAttached, IsEntityOnFire) 404 the
    --     same way, so a 404 alone is never grounds to reject a native --
    --     nor grounds to accept one. Check the hash database.
    -- Both are client-only, which is correct: NUI focus and control state
    -- have no server-side meaning.
    "SetNuiFocus", "IsDisabledControlJustPressed",
    -- GetResourceKvpString -- client/hud.lua's onboarding hint, remembering
    -- per-citizenid whether this player has opened the tablet or dismissed
    -- the hint, across reconnects.
    --
    -- I ALLOWLISTED A NATIVE THAT DOES NOT EXIST HERE, AND THIS NOTE STAYS
    -- SO NOBODY REPEATS IT. I originally added `SetResourceKvpString`
    -- alongside this one, reasoning that its decl page 404ing was not proof
    -- of absence and that both names were widely used in public resources.
    -- A native-verification pass then checked the one source I had not:
    -- the actual CitizenFX registration list in
    -- code/components/citizen-resources-client/src/KVScriptFunctions.cpp.
    -- I re-fetched it and confirmed directly. The registered setters are
    -- SET_RESOURCE_KVP, SET_RESOURCE_KVP_INT, SET_RESOURCE_KVP_FLOAT (plus
    -- _NO_SYNC variants). THERE IS NO SET_RESOURCE_KVP_STRING. The getter
    -- has a _STRING-suffixed variant because it needs to say which type to
    -- read back; the setter's bare name already means string.
    --
    -- So the correct pairing is asymmetric and reads wrong at a glance:
    --   GetResourceKvpString(key)  -- real
    --   SetResourceKvp(key, value) -- real
    -- which is exactly why the mistake was easy and why lint must stay the
    -- thing that catches it.
    --
    -- The lesson, since this file already carries the rule and I broke it
    -- anyway: a 404 decl page is grounds for neither accepting nor
    -- rejecting, and the natives.json fallback CANNOT settle a CFX native
    -- (it is the Rockstar hash database and contains no CFX entries at all).
    -- When both fail, the C++ registration list in the citizenfx/fivem repo
    -- is the primary source. Use it. Do not fall back to "this name looks
    -- familiar" -- that is precisely how this resource shipped two invented
    -- vision getters that returned nil silently for months while its own
    -- tests invented the same names and agreed with them.
    "GetResourceKvpString", "SetResourceKvp",
    -- IsNuiFocused -- ext/native-decls/IsNuiFocused.md returns HTTP 200,
    -- ns CFX, apiset client, BOOL IS_NUI_FOCUSED(). Reports whether NUI
    -- focus is currently held by ANY resource, so opening the tablet can
    -- tell whether it is taking focus from someone else and hand it back
    -- on close instead of releasing globally.
    "IsNuiFocused",
    --   SetPlayerModel -- ext/native-decls/SetPlayerModel.md returns HTTP
    --   404, which as the note above establishes is NOT proof of absence:
    --   the legacy R* natives largely have no decl page. Verified instead
    --   against the natives.json hash database (runtime.fivem.net/doc/
    --   natives.json, fetched 2026-08-25): namespace PLAYER, hash
    --   0x00A1CADD00108836, name SET_PLAYER_MODEL, params (player, model),
    --   and NO `apiset` key -- which for that database means the default,
    --   client-only. Its one call site, client/appearance.lua:369, is
    --   client-side, so the realm is right. This is the native that makes
    --   "assign a K9 ped role to any player, any model" actually change
    --   what the player looks like; get the realm wrong and it is a silent
    --   no-op with nothing logged, which is exactly this project's most
    --   expensive recurring bug class.
    "SetPlayerModel",
    --   SetPedDefaultComponentVariation -- client/appearance.lua, applied
    --   to the new ped immediately after SetPlayerModel above. WITHOUT it
    --   the swapped ped renders as nothing at all: SET_PLAYER_MODEL builds
    --   the ped with no component variation set, and for an animal ped
    --   every part of the dog IS a component, so there is nothing to draw.
    --   Reported from a live server as "it changes me to air". Verified the
    --   same way SetPlayerModel/CreatePed above were: its decl page 404s (a
    --   legacy R* native with no CFX page, never grounds to reject one on
    --   its own), so checked against the natives.json hash database instead
    --   -- namespace PED, hash 0x45EEE61580806D63, name
    --   SET_PED_DEFAULT_COMPONENT_VARIATION, params (ped), and NO `apiset`
    --   key, which in that database means the default, client-only.
    --   client/appearance.lua is its only call site and is a client file,
    --   so the realm is right. Getting the realm wrong here would have been
    --   a silent no-op with nothing logged -- a "fix" that changed nothing
    --   while looking correct, which is this project's most expensive
    --   recurring bug class and precisely why this list exists.
    "SetPedDefaultComponentVariation",
    --   CreatePed -- client/equipmentshop.lua's supply-point ped (a dog
    --   standing at each shop location), created LOCAL and never networked.
    --   Verified the same way SetPlayerModel above
    --   was: its decl page 404s (a legacy R* native with no CFX page, which
    --   is never grounds to reject a native on its own), so checked against
    --   the natives.json hash database instead (fetched 2026-08-25):
    --   namespace PED, hash 0xD49F9B0955C367DE, name CREATE_PED, and NO
    --   `apiset` key -- which in that database means the default,
    --   client-only. client/equipmentshop.lua is the only call site and
    --   is a client file, so the realm is right. No server file creates a
    --   ped at all, which is why nothing here can leak one.
    "CreatePed",
    --   SetEntityInvincible / SetEntityAsMissionEntity --
    --   client/equipmentshop.lua's shop ped (a dog standing at each supply
    --   point). Both decl pages 404, which for a legacy R* native is never
    --   proof of absence; both were re-verified INDEPENDENTLY here against
    --   the natives.json hash database rather than taken on report:
    --     SET_ENTITY_INVINCIBLE        ENTITY 0x3882114BDE571AD4
    --     SET_ENTITY_AS_MISSION_ENTITY ENTITY 0xAD738C3085FE7E11
    --   Neither carries an `apiset` key, which in that database means the
    --   default, client-only -- matching their one call site. The mission-
    --   entity flag is the load-bearing one: without it the game's own
    --   population cleanup can despawn a shop ped out from under the file's
    --   tracking table, after which every later deletion is aimed at a
    --   handle that no longer belongs to us.
    "SetEntityInvincible", "SetEntityAsMissionEntity",
    -- vector3 is NOT a native and has no decl page to check -- it is a Lua
    -- RUNTIME TYPE that CitizenFX's Lua build adds to the language itself,
    -- alongside vector2/vector4/quat, in both realms. Nothing declares it,
    -- so luacheck cannot know about it; it is listed here for that reason
    -- and not because anything was assumed about a native. config.lua uses
    -- it for Config.K9EquipmentShop.locations, since ox_target's
    -- addSphereZone takes a vector3 for `coords`.
    "vector3", "vector2", "vector4", "quat",
    --   IsDuplicityVersion -- ext/native-decls/IsDuplicityVersion.md
    --   returns HTTP 200, apiset: shared, "Gets whether or not this is the
    --   CitizenFX server". shared/compat/core.lua uses it for realm
    --   detection, which is load-bearing: get it wrong and every adapter is
    --   built for the wrong VM and silently does nothing.
    "IsDuplicityVersion",
    -- ExecuteCommand -- verified 2026-08-25, HTTP 200, ns: CFX,
    -- apiset: shared. client/tablet.lua uses it to route a tablet action
    -- through the SAME RegisterCommand handler a player typing the command
    -- would hit, rather than reimplementing the action. That is deliberate:
    -- a forked entry point is how one path ends up guarded and the other
    -- does not, which this resource has already been bitten by once
    -- (ScratchAtDoor/NudgeDoor checked vehicle state in ox_target's
    -- canInteract but not inside the function). The tradeoff, documented at
    -- the call site, is that a command handler has no synchronous return
    -- value, so the tablet can only report "submitted", never "succeeded" --
    -- the command's own handler notifies the real outcome, exactly as it
    -- does for chat-typed usage.
    "ExecuteCommand",
    -- GET_RESOURCE_STATE. Used by server/tracking.lua's ox_inventory
    -- capability probe as the first gate, because accessing an export on a
    -- resource that is not started can throw rather than return nil.
    -- VERIFIED: ext/native-decls/GetResourceState.md declares apiset `shared`.
    "GetResourceState",
    -- GET_RESOURCE_METADATA. server/selfcheck.lua's boot-time dependency
    -- version check. VERIFIED against ext/native-decls/GetResourceMetadata.md
    -- (ns CFX, apiset shared): `char* GET_RESOURCE_METADATA(char*
    -- resourceName, char* metadataKey, int index)` -- a `char*`-returning
    -- native, the same "string or nil" shape GetResourceState and
    -- LoadResourceFile already use here, confirmed against the primary
    -- declaration rather than assumed from the name. Not exercised against a
    -- live FXServer (none available in this environment) -- see that file's
    -- own header for the exact scope of what "verified" means here.
    "GetResourceMetadata",
    -- LOAD_RESOURCE_FILE. server/selfcheck.lua reads server/runtimecontrol.lua's
    -- own raw text at boot to cross-check Config.Features keys against the
    -- feature names that file's own FEATURE_TIERS table actually names --
    -- see that file's own header for why a text scan, not a Lua `require`,
    -- is the only way to reach a table that is a true `local` with no
    -- resource-global or export surface at all. VERIFIED against
    -- ext/native-decls/LoadResourceFile.md (ns CFX, apiset shared): `char*
    -- LOAD_RESOURCE_FILE(char* resourceName, char* fileName)` -- same
    -- `char*` "string or nil" shape as the two natives above. The doc's one
    -- caveat ("if executed on the client, this file has to be included in
    -- `files`") does not apply here -- every call site in this resource is
    -- server-side only.
    "LoadResourceFile",
    -- SAVE_RESOURCE_FILE. server/debugdump.lua's `/k9debug` command writes
    -- one timestamped diagnostic file per run under this resource's own
    -- `diagnostics/` folder -- the owner's own explicit request was a file
    -- in a folder inside the resource, never console/chat output. VERIFIED
    -- against ext/native-decls/SaveResourceFile.md (fetched fresh this
    -- pass, not assumed from the similarly-named LoadResourceFile above):
    -- HTTP 200, `ns: CFX`, `apiset: server`, `BOOL SAVE_RESOURCE_FILE(char*
    -- resourceName, char* fileName, char* data, int dataLength)`. Every
    -- call site in this resource is server-side only, matching that
    -- `apiset`. NOT verified by this pass: whether it creates an
    -- intermediate directory that does not already exist on disk (the decl
    -- page does not say either way) -- server/debugdump.lua's own header
    -- discloses this and ships `diagnostics/.gitkeep` specifically so that
    -- folder exists on disk regardless of which way that turns out to
    -- behave.
    "SaveResourceFile",
    -- Server-side entity pool enumeration, used by server/wellbeing.lua's rest-
    -- source proximity check. VERIFIED against primary source: each has an
    -- ext/native-decls entry declaring `apiset: server`. Same test the native
    -- audit established, and the same one that falsified the earlier
    -- "no apiset in frontmatter means client-only" method.
    "GetAllObjects", "GetAllVehicles",
    -- client/bonetool.lua's on-screen bone-index label (dev tool only).
    -- All VERIFIED present in citizenfx/natives at the namespaces named:
    -- PED/GetPedBoneIndex, HUD/SetText*, HUD/*TextCommandDisplayText,
    -- HUD/AddTextComponentSubstringPlayerName, GRAPHICS/SetDrawOrigin,
    -- GRAPHICS/ClearDrawOrigin. Client-side only, and only called from a
    -- client file. GetPedBoneIndex is used ONLY as a lookup shortcut in the
    -- sweep tool, never as a live conversion in the shipped feature -- its own
    -- doc page has an empty Return value section, so its not-found convention
    -- is unconfirmed and the tool reports raw values unfiltered rather than
    -- guessing which are hits.
    "GetPedBoneIndex",
    "SetTextScale", "SetTextFont", "SetTextColour", "SetTextCentre",
    "BeginTextCommandDisplayText", "AddTextComponentSubstringPlayerName",
    "SetDrawOrigin", "EndTextCommandDisplayText", "ClearDrawOrigin",
    -- Timecycle modifiers, client/screenfx.lua. VERIFIED client-only against
    -- primary source: both are declared in citizenfx/natives GRAPHICS with no
    -- ext/native-decls server override, and FXServer has no renderer at all.
    -- Hashes 0x2C933ABF17A1DF41 / 0x0F07E7745A236711.
    "SetTimecycleModifier", "ClearTimecycleModifier",
    -- GET_WORLD_POSITION_OF_ENTITY_BONE, client/propattachment.lua and
    -- client/bonetool.lua. VERIFIED: declared in citizenfx/natives ENTITY
    -- (the ENTITY namespace, not PED -- it takes a generic Entity, which is
    -- what makes it usable against a quadruped K9 ped), no ext/native-decls
    -- server override, so client-only. Takes a bone INDEX, not a name; a
    -- human-derived index is not meaningful on a dog skeleton, which is
    -- exactly what the bonetool sweep exists to resolve.
    "GetWorldPositionOfEntityBone",
    "RegisterKeyMapping",
    -- Player / entity queries -- THIS WHOLE LINE CARRIED NO CITATION AT ALL
    -- before this pass (2026-08-27 native-verification audit), despite
    -- GetPlayers being the single riskiest kind of miss possible: unlike an
    -- unregistered NATIVE (which resolves to a silent nil forever, this
    -- file's own standing warning), GetPlayers() is not a native at all --
    -- it is a plain LUA GLOBAL FUNCTION, defined only inside `if
    -- isDuplicityVersion then ... end` in citizenfx/fivem's own
    -- data/shared/citizen/scripting/lua/scheduler.lua (fetched and read
    -- directly this pass, same file this repo's own PerformHttpRequest
    -- entry below already cites for the identical "Lua wrapper, not a raw
    -- native" shape): `function GetPlayers() local num =
    -- GetNumPlayerIndices() ... for i = 0, num - 1 do table_insert(t,
    -- GetPlayerFromIndex(i)) end return t end`. Calling it from a CLIENT
    -- script (where that whole `if isDuplicityVersion` block never even
    -- executes, so the global is simply never assigned) is therefore NOT a
    -- silent no-op -- it is a hard Lua runtime error, "attempt to call a
    -- nil value (global 'GetPlayers')", on the very first line that tries.
    -- SIDEDNESS CONFIRMED BY DIRECT SEARCH, this pass: every real call site
    -- of `GetPlayers()` anywhere in this resource
    -- (server/certifications/commands.lua, server/combat.lua,
    -- server/entities.lua, server/integrations.lua, server/k9profiles.lua,
    -- server/main.lua, server/partnership.lua, server/permissions.lua,
    -- server/progression.lua, server/search.lua, server/tablet.lua,
    -- server/tenure.lua, server/tracking.lua, server/wellbeing.lua,
    -- server/xptiers.lua) is a server file -- the one
    -- apparent client-side hit (client/progression.lua) is, on inspection,
    -- a comment describing a design suggestion FOR server/progression.lua,
    -- not a real call (exactly the "a comment containing a call shape
    -- counts as a match" trap this pass's own instructions warned about --
    -- opened and read, not trusted from the grep alone).
    --
    -- GetActivePlayers -- CONFIRMED CFX, apiset client, directly from its
    -- own ext/native-decls page (HTTP 200, not a 404): "Returns all player
    -- indices for 'active' physical players known to the client." THE
    -- OPPOSITE REALM FROM GetPlayers ABOVE, and easy to reach for by name
    -- alone -- this resource's only call site (client/radial.lua) is
    -- correctly client-side.
    --
    -- GetPlayerFromServerId / GetPlayerServerId -- CONFIRMED CFX, apiset
    -- client, both via runtime.fivem.net/doc/natives_cfx.json (fetched this
    -- pass): GET_PLAYER_FROM_SERVER_ID hash 0x344EA166, GET_PLAYER_SERVER_ID
    -- hash 0x4D97BCC7, neither in the base-game natives.json at all (these
    -- are CFX-only additions, not Rockstar natives -- natives.json would
    -- never carry them regardless of realm). Confirmed by direct search:
    -- every real call site of either name in this resource is a client
    -- file (client/leashvisual.lua, client/main.lua, client/medkit.lua,
    -- client/movement.lua, client/partnership.lua, client/radial.lua,
    -- client/vision.lua) --
    -- the several server/*.lua occurrences of "GetPlayerServerId(...)" as
    -- literal text are all inside comments explicitly explaining why that
    -- combination is NOT used server-side (server/entities.lua,
    -- server/inventory.lua, server/certifications.lua all document the same
    -- "never verified server-side, the scan is strictly more conservative"
    -- reasoning -- see server/entities.lua's own ResolveConnectedPlayerFromPed).
    --
    -- GetPlayerName / GetPlayerPed -- BOTH GENUINELY DUAL-REGISTERED under
    -- the same Lua name, confirmed against BOTH databases this pass, which
    -- is why this codebase safely calls each from EITHER realm:
    --   natives.json (base-game, Rockstar): PLAYER GET_PLAYER_NAME (hash
    --     0x6D0DE6A7B5DA71F8, no apiset -> client-only default, "index in,
    --     name out"); PLAYER GET_PLAYER_PED (hash 0x43A66C31C68491C0, no
    --     apiset -> client-only default, "index in, ped out").
    --   natives_cfx.json (CFX-only extension, SEPARATE hash, SEPARATE
    --     registration): CFX GET_PLAYER_NAME (hash 0x406B4B20, apiset
    --     server, "server id in, name out"); CFX GET_PLAYER_PED (hash
    --     0x6E31E993, apiset server, "server id in, ped out").
    -- Confirmed by reading actual call sites: every server/*.lua call
    -- passes `source` or another server id (the CFX server-side overload);
    -- every client/*.lua call passes a player INDEX (PlayerId(),
    -- GetPlayerFromServerId(...), a GetActivePlayers()/GetPlayers() loop
    -- variable) (the base-game client-side overload). Two natives, one
    -- shared Lua name, resolved by which VM is running -- not a
    -- coincidence and not something to "simplify."
    --
    -- PlayerId -- CONFIRMED base-game (natives.json), PLAYER namespace,
    -- hash 0x4F8644AF03D0E0D6, no apiset -> client-only default ("Gets the
    -- local player's player index"), which is structurally the only realm
    -- this could ever mean anything in (a server has no single "local
    -- player"). Every call site in this resource is a client file.
    "GetPlayers", "GetActivePlayers", "GetPlayerFromServerId",
    "GetPlayerServerId", "GetPlayerName", "GetPlayerPed", "PlayerId",
    -- Player(serverId).state -- CFX player statebag accessor, both realms
    "Player",
    -- GetSelectedPedWeapon: a genuine SERVER native (CFX, apiset: server),
    -- verified against ext/native-decls/GetSelectedPedWeapon.md, where it
    -- is documented as an alias of GET_CURRENT_PED_WEAPON. That page also
    -- states plainly that the SEPARATE client native of the same name --
    -- the one that reads the weapon wheel -- is NOT available to FXServer,
    -- so do not "correct" a server-side call here into the client one.
    -- Used by server/wellbeing.lua to require that whoever reports nearby
    -- gunfire is actually holding a weapon.
    "GetSelectedPedWeapon",
    -- PlayerPedId / NetworkGetPlayerIndexFromPed -- also previously
    -- uncited. Both confirmed base-game (natives.json, fetched this pass):
    -- PLAYER_PED_ID (PLAYER, hash 0xD80958FC74E988A6, no apiset ->
    -- client-only default -- "Gets the local player's active ped");
    -- NETWORK_GET_PLAYER_INDEX_FROM_PED (NETWORK, hash 0x6C0E2E0125610278,
    -- no apiset -> client-only default, converts a ped entity to a player
    -- index -- a concept ("player index") that only exists client-side in
    -- the first place). Confirmed by direct search: every real call site of
    -- either name in this resource is a client file (client/fetch.lua,
    -- client/inventory.lua, client/leashvisual.lua, client/main.lua,
    -- client/movement.lua, client/partnership.lua, client/pursuitsprint.lua
    -- for NetworkGetPlayerIndexFromPed; PlayerPedId is used pervasively
    -- across client/*.lua) -- server/entities.lua's own mention of
    -- NetworkGetPlayerIndexFromPed is inside a comment explaining why that
    -- combination is deliberately NOT used server-side (see the
    -- GetPlayerServerId/GetPlayerName/GetPlayerPed entry above for the
    -- fuller writeup of that same finding).
    "PlayerPedId", "NetworkGetPlayerIndexFromPed",
    "GetCurrentResourceName",
    -- Entity / world
    "DoesEntityExist", "IsEntityDead", "GetEntityCoords", "SetEntityCoords",
    "GetEntityHeading", "SetEntityHeading", "GetEntityModel",
    -- GET_ENTITY_SPEED -- VERIFIED 2026-08-26 against
    -- raw.githubusercontent.com/citizenfx/fivem/master/ext/native-decls/GetEntitySpeed.md
    -- (ns CFX, apiset: server, returns a float in metres per second). It is
    -- also a long-standing base-game CLIENT native, which is the side
    -- client/agility.lua calls it from.
    "GetEntitySpeed",
    "GetEntityType", "GetEntityArchetypeName", "GetOffsetFromEntityInWorldCoords",
    -- SetEntityVisible REMOVED 2026-08-27 (independent native-verification
    -- pass): zero call sites anywhere in this resource as of this audit
    -- (client/, server/, shared/, tests/ all searched -- not even a comment
    -- references it). git history confirms it once had exactly one real
    -- caller, client/vehicle.lua's old boot-attach K9-vehicle approximation
    -- (`SetEntityVisible(ped, false, false)` to hide the dog while it sat
    -- invisibly in the trunk) -- removed outright by commit e23d1981
    -- ("Seat the dog in the car..."), which replaced that approximation with
    -- a real seated-in-vehicle implementation that deliberately keeps the K9
    -- visible. The allowlist entry was never cleaned up alongside the
    -- feature it existed for -- exactly the stale-entry failure mode this
    -- file's own "REMOVE THIS ENTRY if the function is ever abandoned" rule
    -- (see ForceRevertK9Appearance/ApplyK9AppearanceDirect above) targets.
    -- SET_ENTITY_VISIBLE is a genuine native (natives.json, ENTITY
    -- namespace, hash 0xEA1C610A04DB6BBB, no apiset key -- client-only under
    -- this file's own established reading of that field) -- removed here for
    -- being dead, not for being fake. Restore only alongside a real, live
    -- call site.
    "SetEntityCollision", "FreezeEntityPosition",
    "AttachEntityToEntity", "DetachEntity", "GetGamePool",
    "GetHashKey",
    -- CAM namespace + GetEntityRotation, for client/vision.lua's partner
    -- camera feed. Verified 2026-08-26 against runtime.fivem.net's live
    -- natives.json (HTTP 200, 2.7MB), not from memory and not from the
    -- decl pages, which 404 for all of these -- a 404 there is not proof
    -- of absence, which is exactly why the fallback exists. Every one
    -- resolves in the CAM namespace (GetEntityRotation in ENTITY) with a
    -- real hash and no apiset key, i.e. client-only, matching how they are
    -- used. Hashes at time of check: CreateCam 0xC3981DCE61D9E13F,
    -- AttachCamToEntity 0xFEDB7D269E8C60E3, RenderScriptCams
    -- 0x07E5B515DB0636FC, SetCamActive 0x026FB97D0A425F84, DestroyCam
    -- 0x865908C81A2C22E9, DoesCamExist 0xA7A932170592B50E, SetCamFov
    -- 0xB13C14F66A00D047, SetCamRot 0x85973643155D0B07,
    -- GetEntityRotation 0xAFBD61CC738D9EB9.
    "CreateCam", "AttachCamToEntity", "SetCamFov", "GetEntityRotation",
    "SetCamRot", "SetCamActive", "RenderScriptCams", "DoesCamExist",
    "DestroyCam",
    -- GetWaterHeightNoWaves -- RE-VERIFIED 2026-08-26 (native-api-assistant
    -- pass): runtime.fivem.net/doc/natives.json was reachable this session
    -- (the earlier egress-proxy block noted below was environment-specific,
    -- not permanent) and confirms WATER namespace, hash 0x8EE6B53CE13A9794,
    -- params (float x, float y, float z, float* height) -> BOOL, no apiset
    -- key -- the default, client-only, matching this native's one call site
    -- (client/tracking.lua's water-crossing sampler, a client file). The
    -- `float* height` out-param is correctly consumed as a second Lua return
    -- value (`local found = GetWaterHeightNoWaves(x, y, z)` only captures the
    -- first), not passed as an input argument -- same convention already
    -- established for the sibling GetWaterHeight. Superseded finding, kept
    -- for the historical record: its ext/native-decls page still 404s (not
    -- proof of absence -- many real natives have none), and an earlier pass
    -- of this environment could not reach runtime.fivem.net to fall back to,
    -- so this entry was carried at reduced confidence until now.
    "GetWaterHeightNoWaves",
    -- The eight entries below (NetworkGetEntityFromNetworkId through
    -- GetEntityForwardVector) carried NO citation at all before this pass
    -- (2026-08-27 native-verification audit) -- unlike almost every other
    -- entry in this file, there was nothing here recording where any of
    -- them were checked, only that they clearly work in practice (this
    -- resource calls all eight from multiple already-shipping features).
    -- Verified this pass against a freshly-fetched runtime.fivem.net/doc/
    -- natives.json (all eight are real, base-game natives, none carrying an
    -- `apiset` key, i.e. client-only under this file's own default reading):
    --   NETWORK_GET_ENTITY_FROM_NETWORK_ID    0xCE4E5D9B0A4FF560
    --   NETWORK_GET_NETWORK_ID_FROM_ENTITY    0xA11700682F3AD45C
    --   NETWORK_DOES_ENTITY_EXIST_WITH_NETWORK_ID 0x18A47D074708FD68
    --   GET_VEHICLE_NUMBER_PLATE_TEXT         0x7CE1CCB9B293020E
    --   IS_PED_IN_ANY_VEHICLE                 0x997ABD671D25CA0B
    --   GET_ENTITY_HEALTH                     0xEEF059FAD016D209
    --   GET_ENTITY_MAX_HEALTH                 0x15D757606D170C3C
    --   GET_ENTITY_FORWARD_VECTOR             0x0A794A5A57F8DF91
    -- SIDEDNESS, checked against actual call sites, not assumed from the
    -- natives.json default alone -- this matters because natives.json's
    -- "no apiset key" reading is a DEFAULT, not a guarantee a later FXServer
    -- build never added a real server registration on top (GetEntitySpeed/
    -- IsPedRagdoll elsewhere in this file are exactly that exception):
    --   NetworkGetEntityFromNetworkId / NetworkGetNetworkIdFromEntity /
    --     GetEntityHealth / GetEntityMaxHealth / GetVehicleNumberPlateText /
    --     IsPedInAnyVehicle -- INDEPENDENTLY RE-CONFIRMED server-callable
    --     too, this pass, by direct read of citizenfx/fivem's
    --     code/components/citizen-server-impl/src/state/
    --     ServerGameState_Scripting.cpp (the same authoritative
    --     "which GET_ENTITY_*/etc. FXServer actually registers" source
    --     server/kennel.lua's own GetEntityForwardVector finding below
    --     relies on): real handlers found for NETWORK_GET_ENTITY_FROM_NETWORK_ID,
    --     NETWORK_GET_NETWORK_ID_FROM_ENTITY, GET_ENTITY_HEALTH,
    --     GET_ENTITY_MAX_HEALTH, GET_VEHICLE_NUMBER_PLATE_TEXT and
    --     IS_PED_IN_ANY_VEHICLE alike -- all six are genuinely dual-realm,
    --     matching every one of this resource's own call sites for them,
    --     client and server both.
    --   NetworkDoesEntityExistWithNetworkId -- server-side registration
    --     NOT FOUND in that same file, but that is NOT treated as proof of
    --     absence here (this file is one component among several; a native
    --     with no hit in one source file is UNVERIFIED, never CONFIRMED
    --     ABSENT, on that alone -- the exact distinction this whole audit
    --     exists to keep straight). Moot in practice either way: direct
    --     search confirms its ONLY real call site anywhere in this resource
    --     is client/main.lua:439 (inside PlaySoundOnNetworkEntity), a client
    --     file -- every server/*.lua mention of this name is inside a
    --     comment describing an OLD inline pattern already migrated away to
    --     ResolveNetworkEntity's own NetworkGetEntityFromNetworkId +
    --     DoesEntityExist pairing (server/entities.lua) -- so its server-side
    --     status is UNVERIFIED but also uncalled-from-server-anywhere today.
    --   GetEntityForwardVector -- the ONE entry of these eight CONFIRMED
    --     ABSENT server-side, not merely unchecked -- see server/kennel.lua's
    --     own "NOT GetEntityForwardVector(ped) -- CONFIRMED BROKEN
    --     SERVER-SIDE" finding a few hundred lines below this file's own
    --     server/wellbeing.lua-adjacent natives for the full writeup (traced
    --     dispatch to FXServer's `s_invalidNativeHandler` no-op). Direct
    --     search this pass confirms every server/*.lua occurrence of this
    --     name is inside a comment explicitly saying NOT to call it
    --     server-side (server/kennel.lua, server/fetch.lua) -- its only real
    --     call sites anywhere in this resource are client/agility.lua,
    --     client/combat.lua and client/movement.lua, all client files. Kept
    --     allowlisted (client-side use is real and correct) -- this note
    --     exists so nobody reads its presence here as license to call it
    --     from a NEW server file.
    "NetworkGetEntityFromNetworkId", "NetworkGetNetworkIdFromEntity",
    "NetworkDoesEntityExistWithNetworkId",
    "GetVehicleNumberPlateText", "IsPedInAnyVehicle",
    -- GET_PED_IN_VEHICLE_SEAT (0xBB40DD2270B65366, VEHICLE namespace,
    -- client) -- (vehicle, seatIndex) -> Ped. Added for
    -- client/vehicle.lua's driver-seat guard: asking "is THIS ped the one
    -- in seat -1" is the only way to catch a K9 that reached the driver's
    -- seat by a route this resource never saw (an admin teleport, another
    -- resource seating them, or pressing enter before this file loaded).
    -- A long-standing base-game native with an ext/native-decls entry;
    -- realm is client-only, and every call site here is client-side.
    "GetPedInVehicleSeat",
    "GetEntityHealth", "GetEntityMaxHealth", "GetEntityForwardVector",
    "ApplyForceToEntity",
    -- K9Medkit (client/medkit.lua, server/medkit.lua, Phase 4,
    -- PHASE4_SPEC.md §13.4.4) -- health-restore write native, the one
    -- ENTITY-STATE native this resource calls that wasn't already covered
    -- by the GetEntityHealth/GetEntityMaxHealth reads above
    "SetEntityHealth",
    -- K9 move-rate composer (client/movement.lua RecomputeK9MoveRate(),
    -- Phase 4, PHASE4_SPEC.md §13.0 Decision 2) -- the ONE call site for
    -- this native anywhere in this resource (see that function's own
    -- header comment for the "one and only call" confirmation and this
    -- native's honest confidence grading).
    "SetPedMoveRateOverride",
    -- Timers / misc client natives
    "GetGameTimer", "DrawMarker", "DisableControlAction",
    "ClearPedTasksImmediately", "TaskStartScenarioInPlace", "IsPedShooting",
    "PlaySoundFromEntity", "SetFollowPedCamViewMode",
    "GetPlayerSprintStaminaRemaining",
    -- NATIVE SPRINT STAMINA ASSIST (client/wellbeing.lua, owner directive:
    -- "make sure high command can edit the ability to make stamina last
    -- longer or even permanently") -- confirmed real against FiveM's own
    -- natives.json (runtime.fivem.net/doc/natives.json), documented with an
    -- official example ("Adds a percentage to a players stamina").
    "RestorePlayerStamina",
    -- AgilityAdvanced capsule-sweep vault (client/agility.lua, extracted from
    -- client/movement.lua, Phase 3,
    -- PHASE3_SPEC.md §12.5.5/§12.0 item 3) -- the ORIGINAL citation for this
    -- entry pointed only at this resource's own internal doc
    -- (qbx_k9unit/DEVELOPER_REFERENCE.md#phase-3-combat), not a primary CFX
    -- source -- an internal doc can be just as wrong as a misremembered
    -- name, so this pass (2026-08-27) independently re-verified all three
    -- against a freshly-fetched runtime.fivem.net/doc/natives.json rather
    -- than trust that reference: SHAPETEST START_SHAPE_TEST_CAPSULE (hash
    -- 0x28579D1B8F8AAC80, params x1,y1,z1,x2,y2,z2,radius,flags,entity,p9 ->
    -- int), SHAPETEST GET_SHAPE_TEST_RESULT (hash 0x3D87450E15D98694, params
    -- shapeTestHandle,hit*,endCoords*,surfaceNormal*,entityHit* -> int), and
    -- ENTITY SET_ENTITY_VELOCITY (hash 0x1C99BB7B6E96D16F, params
    -- entity,x,y,z -> void) -- none carry an `apiset` key, meaning
    -- client-only default, matching client/agility.lua's own realm (its
    -- only call site for all three, confirmed by direct search). Argument
    -- COUNT also cross-checked against the actual call site
    -- (client/agility.lua's DetectVaultableObstacleHeight): 10 positional
    -- arguments passed to StartShapeTestCapsule, matching the 10-parameter
    -- signature above exactly.
    "StartShapeTestCapsule", "GetShapeTestResult", "SetEntityVelocity",
    -- NUI bridge (client/hud.lua)
    "SendNUIMessage", "RegisterNUICallback",
    -- Vision natives (see client/vision.lua -- distinct from this resource's
    -- own IsNightVisionActive/IsThermalVisionActive wrapper functions
    -- declared below, which are this file's OWN functions, not natives).
    --
    -- CORRECTED 2026-08-27 (independent native-verification pass): the
    -- previous version of this comment asserted "these are the actual CFX
    -- native names" for all four entries below. That claim was WRONG for
    -- two of them and, unlike every other entry in this file, carried no
    -- hash/decl citation backing it up -- exactly the un-sourced-allowlist-
    -- entry failure mode this file otherwise guards against.
    --   SetNightvision / SetSeethrough -- REAL, CONFIRMED. Both 404 on
    --     ext/native-decls (legacy R* natives, not proof of absence) but are
    --     present in runtime.fivem.net/doc/natives.json: GRAPHICS
    --     SET_NIGHTVISION (hash 0x18F621F7A5B1F85D, params: BOOL toggle) and
    --     GRAPHICS SET_SEETHROUGH (hash 0x7E08924259E08CE0, params: BOOL
    --     toggle). No apiset key -> client-only default, matching their only
    --     call sites in client/vision.lua. Single-BOOL-arg call shape used
    --     there is correct.
    --   IsNightvisionActive / IsSeethroughActive -- CONFIRMED DOES NOT EXIST
    --     AS A NATIVE, EITHER ONE. No ext/native-decls page (404) AND no
    --     matching entry in natives.json under any underscore-split
    --     reconstruction of that name. The natives.json hash database's
    --     actual GETTERS for this pair are GRAPHICS GET_USINGNIGHTVISION
    --     (hash 0x2202A3F42C8E5F79) and GRAPHICS GET_USINGSEETHROUGH (hash
    --     0x44B80ABAB9D80BD3) -- which the CFX Lua native-name generator
    --     (PascalCase of the underscore-split name) exposes as
    --     GetUsingnightvision() / GetUsingseethrough(), NOT
    --     IsNightvisionActive()/IsSeethroughActive(). Independently
    --     corroborated: alt:V's own natives typings
    --     (@altv/types-natives, generated from the same underlying GTA5
    --     native database by a different vendor) declare
    --     `getUsingnightvision()` / `getUsingseethrough()`, not an
    --     "isNightvisionActive"/"isSeethroughActive" of any casing.
    --
    --     THE BUG THIS DESCRIBED HAS SINCE BEEN FIXED IN client/vision.lua,
    --     RE-CONFIRMED BY A LATER INDEPENDENT PASS (2026-08-27, this same
    --     day): `IsThermalVisionActive()`/`IsNightVisionActive()` -- this
    --     resource's OWN capital-V-named wrapper functions, declared further
    --     down this file's `globals` block, NOT natives themselves -- now
    --     call `NativeReportsActive(GetUsingseethrough())`/
    --     `NativeReportsActive(GetUsingnightvision())` (client/vision.lua,
    --     right where this comment used to warn the fix still needed to
    --     land), and the two fake names `IsNightvisionActive`/
    --     `IsSeethroughActive` have ZERO live call sites left anywhere in
    --     client/, server/, shared/ or tests/ -- every remaining occurrence
    --     of either name (client/vision.lua's own header, tests/clienthud_spec.lua,
    --     tests/clientvision_spec.lua) is inside a comment describing this
    --     historical bug/fix, confirmed by direct search this pass. GetUsingnightvision/
    --     GetUsingseethrough themselves were independently re-confirmed
    --     against a freshly-fetched runtime.fivem.net/doc/natives.json this
    --     same pass (same two hashes as above, no `apiset` key -> client-only,
    --     matching client/vision.lua's own realm).
    --
    --     NEITHER FAKE NAME IS PRESENT IN THIS ALLOWLIST, and per this
    --     file's own "REMOVE THIS ENTRY if the function is ever abandoned"
    --     rule (see ForceRevertK9Appearance/SetEntityVisible above) neither
    --     should be re-added unless a real call site returns -- an
    --     allowlisted name that resolves to no registered native is exactly
    --     the failure mode this whole file exists to catch, not paper over.
    --     This entry is kept purely as the historical record of a real,
    --     shipped, silent-nil bug (thermal/night vision could only ever turn
    --     ON, never off, for as long as this went unnoticed) and its fix, so
    --     a future reader does not have to rediscover either from scratch --
    --     it documents two names that are CONFIRMED ABSENT, never two names
    --     to allowlist.
    "SetNightvision", "GetUsingnightvision", "SetSeethrough", "GetUsingseethrough",
    -- DeployableKennel (client/kennel.lua, server/kennel.lua, Phase 5 R&D,
    -- qbx_k9unit/DEVELOPER_REFERENCE.md#phase-5-research) -- object creation/
    -- placement/model-loading natives, none previously used anywhere else
    -- in this resource
    "CreateObject", "PlaceObjectOnGroundProperly", "DeleteEntity",
    "RequestModel", "HasModelLoaded", "SetModelAsNoLongerNeeded", "IsModelValid",
    -- Phase 3 BiteAndHold/NonLethalTakedown (client/combat.lua) --
    -- CLIENT-side ped-behavior/physics natives, each with a genuine,
    -- confirmed CLIENT call site in that file (applyBiteHold/forceRagdoll/
    -- applyNpcBiteHold/applyNpcTakedown and their own teardown handlers).
    -- Deliberately NOT added on the strength of server/combat.lua's own
    -- usage -- this session's native-api-assistant verification pass
    -- confirmed SetEntityCanBeDamaged is CLIENT-ONLY (no apiset entry on
    -- the canonical citizenfx/fivem native declaration) and could NOT
    -- confirm SetPedFleeAttributes/SetBlockingOfNonTemporaryEvents/
    -- SetPedToRagdollWithFall's SERVER-side validity either way (their
    -- CLIENT-side validity was never in question -- these are standard,
    -- well-established client ped-AI/physics natives). server/combat.lua
    -- no longer calls any of these four directly as of this same pass --
    -- every NPC-target effect is relayed to the requesting K9's own client
    -- instead (see that file's own header "NPC-TARGET NATIVE EXECUTION
    -- CONTEXT" section for the full finding and the reasoning for why this
    -- sidesteps the three unresolved natives' server-side status rather
    -- than assert it). Adding these here asserts ONLY their confirmed
    -- CLIENT validity, never their server-side status.
    "SetEntityCanBeDamaged", "SetPedFleeAttributes",
    "SetBlockingOfNonTemporaryEvents", "SetPedToRagdollWithFall",
    -- Phase 3 combat NON-COMPLIANCE DETECTION staff alert
    -- (server/combat.lua's FlagNonCompliance) -- standard, ubiquitous
    -- FXServer permission-check native (ACE permissions are inherently a
    -- server-side concept); HIGH confidence, not independently
    -- cross-checked against two live sources this session but not one of
    -- the four natives this pass's native-api-assistant verification
    -- flagged as genuinely in question -- see that same header section.
    "IsPlayerAceAllowed",
    -- Phase 3 PropDragging (client/combat.lua, server/combat.lua,
    -- PHASE3_SPEC.md §12.5.4). NetworkRequestControlOfEntity is called
    -- before every native this client applies to a ped it may not own --
    -- added after a QA pass found the pre-existing applyNpcBiteHold/
    -- applyNpcTakedown handlers omitted it, which this resource's own
    -- qbx_k9unit/DEVELOPER_REFERENCE.md#phase-3-combat names as required for
    -- exactly those natives. It is best-effort: no success-check native is
    -- confirmed available here, so the call improves the odds of the
    -- effect landing rather than guaranteeing it -- see client/combat.lua's
    -- own disclosure.
    --
    -- CORRECTED 2026-08-27 (independent native-verification pass):
    -- IsPedDeadOrDying REMOVED from this list. This comment used to say it
    -- backed the NPC branch of server/combat.lua's IsTargetDowned alongside
    -- IsPedRagdoll -- true when originally written, but server/combat.lua's
    -- own later header/inline comments (around IsTargetDowned and
    -- PED_DEAD_HEALTH_THRESHOLD) already record that IsPedDeadOrDying "has
    -- no FXServer server implementation at all" and was replaced there with
    -- `GetEntityHealth(ped) <= PED_DEAD_HEALTH_THRESHOLD`. Verified this
    -- pass by direct search: IsPedDeadOrDying( has ZERO live call sites left
    -- anywhere in client/, server/, shared/ or tests/ -- every remaining
    -- occurrence of the name is inside a comment describing that historical
    -- fix (server/combat.lua, tests/combat_spec.lua). An allowlisted global
    -- with no caller anywhere is exactly the stale-entry failure mode this
    -- file's own "REMOVE THIS ENTRY if the function is ever abandoned" rule
    -- (see ForceRevertK9Appearance/ApplyK9AppearanceDirect above) targets --
    -- restore this entry only alongside a real, live call site.
    --
    -- IsPedRagdoll -- CONFIRMED server-callable, INDEPENDENTLY, THIS PASS
    -- (2026-08-27), closing the gap the paragraph below used to leave open.
    -- Client-side reality first, unchanged from before: it is a real native
    -- (natives.json, PED namespace, IS_PED_RAGDOLL, hash 0x47E4E977581C5B55,
    -- params (ped) -> BOOL; no `apiset` key in that database, meaning
    -- client-only under this file's own established reading of that field
    -- WHEN THAT IS ALL YOU HAVE); it has no ext/native-decls page (404, not
    -- proof of absence). What THIS pass adds: raw-fetched
    -- code/components/citizen-server-impl/src/state/ServerGameState_Scripting.cpp
    -- (citizenfx/fivem, master) directly -- the same file server/kennel.lua's
    -- own GetEntityForwardVector finding below already established as the
    -- authoritative list of which GET_ENTITY_*/IS_PED_* natives FXServer
    -- registers a real handler for -- and found, at the line registering it:
    -- `RegisterNativeHandler("IS_PED_RAGDOLL", makeEntityFunction([...]
    -- { auto movementGroup = entity->syncTree->GetPedMovementGroup(); return
    -- movementGroup ? movementGroup->isRagdolling : false; }))`. This is a
    -- REAL, working server-side implementation reading the synced entity's
    -- own movement-group state -- not a stub, not the
    -- `s_invalidNativeHandler` no-op the GetEntityForwardVector finding
    -- below documents for an unregistered GET_ENTITY_* native. IsPedRagdoll
    -- is therefore CONFIRMED EXISTS, server apiset, on top of its
    -- already-established client-only-per-natives.json reading -- this is
    -- one of the natives.json database's "no apiset key" entries where that
    -- field's absence does NOT mean client-only, matching this file's own
    -- GetEntitySpeed precedent above (also a base-game client native with a
    -- SEPARATE, later-added FXServer registration natives.json's own
    -- `apiset` field never learned to describe). Confirmed real call site:
    -- server/combat.lua's IsTargetDowned NPC branch
    -- (`GetEntityHealth(targetPed) <= PED_DEAD_HEALTH_THRESHOLD or
    -- IsPedRagdoll(targetPed)`) -- that OR's second branch is now known-live,
    -- not merely hoped-live; no live-FXServer print-test is needed to trust
    -- it further, since the C++ source itself is the primary source and
    -- leaves nothing to a runtime guess.
    "NetworkRequestControlOfEntity", "IsPedRagdoll",
    -- Server-side implicit global inside event handlers
    "source",
    -- ox_lib / oxmysql / export surface
    "lib", "locale", "exports", "MySQL",
    -- qbx_core's client-side player-data cache (client/hud.lua)
    "QBX",
    -- client/vehicle.lua's real-seat K9 vehicle entry (this pass, replacing
    -- the old attach-to-trunk approximation). Every one of these 404s on
    -- ext/native-decls (a 404 there is never proof of absence, per this
    -- file's own standing rule) and was instead verified against the
    -- documented fallback, runtime.fivem.net/doc/natives.json (fetched
    -- 2026-08-26), which carries a real hash + parameter list for each:
    --   IS_VEHICLE_SEAT_FREE                 VEHICLE 0x22AC59A870E6A669
    --   SET_PED_INTO_VEHICLE                 PED     0xF75B0D629E1C063D
    --   GET_VEHICLE_MAX_NUMBER_OF_PASSENGERS VEHICLE 0xA7C4F2C6E744A550
    --   SET_VEHICLE_DOOR_OPEN                VEHICLE 0x7C65DAC73C35C862
    --   SET_VEHICLE_DOOR_SHUT                VEHICLE 0x93D9BD300D7789E5
    --   TASK_LEAVE_VEHICLE                   TASK    0xD3DBCE61A490BE02
    -- None carry an `apiset` key in that database, which -- per this file's
    -- own established reading of the same field elsewhere above -- means
    -- the default, client-only; every call site is in client/vehicle.lua.
    -- GET_VEHICLE_PED_IS_IN is the one exception with a real, live decl
    -- page: https://raw.githubusercontent.com/citizenfx/fivem/master/
    -- ext/native-decls/GetVehiclePedIsIn.md returns HTTP 200, ns PED, hash
    -- 0x9A9112A0FE9A4713.
    "IsVehicleSeatFree", "SetPedIntoVehicle", "GetVehicleMaxNumberOfPassengers",
    "SetVehicleDoorOpen", "SetVehicleDoorShut", "TaskLeaveVehicle",
    "GetVehiclePedIsIn",
    -- server/webhook.lua (Discord webhook logging, Config.Features.DiscordWebhook)
    -- -- PerformHttpRequest is NOT itself a raw native; it is a genuine
    -- Lua-level wrapper function defined in FiveM's own shared Lua runtime,
    -- data/shared/citizen/scripting/lua/scheduler.lua (citizenfx/fivem,
    -- master, fetched this session), inside the `if isDuplicityVersion then`
    -- branch (line 318, closed by `else` at line 411) -- i.e. SERVER-ONLY,
    -- matching this native's one call site (server/webhook.lua, a
    -- server_scripts-only file). Same rule as promise/SetTimeout above:
    -- verified against that primary source directly, not from memory --
    -- see server/webhook.lua's own header REQUIREMENT 3 for the full
    -- signature/callback-shape writeup (the callback fires with FOUR
    -- arguments, statusCode/body/headers/errorData, not the commonly-quoted
    -- three). The underlying raw native it calls,
    -- PERFORM_HTTP_REQUEST_INTERNAL_EX, is independently confirmed CFX
    -- namespace, hash 0x6B171E87, apiset: server, against
    -- runtime.fivem.net/doc/natives_cfx.json fetched this same session.
    "PerformHttpRequest",
    -- json.encode/json.decode -- a genuine CitizenFX Lua-runtime global
    -- (both realms), used by server/webhook.lua to build the JSON body its
    -- one PerformHttpRequest call posts to Discord. Not independently
    -- re-verified against FiveM's own C++ source this pass (unreachable
    -- through the available channels this session), but this resource
    -- ALREADY, unconditionally, transitively depends on json.encode being
    -- real here: fxmanifest.lua declares ox_lib as a hard dependency and
    -- loads its init.lua before any file of this resource's own runs, and
    -- ox_lib's own init.lua calls json.encode directly at its own top
    -- level with no require/guard of any kind (confirmed by direct source
    -- search of the live overextended/ox_lib repository this session) --
    -- so this rides an already-load-bearing assumption, not a new one.
    "json",
    -- client/hud.lua's K9 ONBOARDING HINT feature (Config.Features.
    -- K9OnboardingHint, in progress as of this pass -- this file was still
    -- being actively edited by another pass at the moment of this
    -- verification, so re-check its call sites if this feature's shape
    -- changes further). Two natives added here; a THIRD name that file
    -- currently calls is deliberately NOT added -- see that finding below.
    --
    --   IsControlJustPressed -- ext/native-decls page 404s (legacy R*
    --     native, not proof of absence). Confirmed instead against
    --     runtime.fivem.net/doc/natives.json: PAD namespace, hash
    --     0x580417101DDB492F, params (padIndex, control), no apiset key ->
    --     client-only default. client/hud.lua's one call site passes
    --     (0, <control>), matching that two-int signature, and is itself a
    --     client file, so the realm is right.
    --
    --   GetResourceKvpString -- ext/native-decls page 404s. Confirmed
    --     instead against the primary C++ registration list itself
    --     (citizenfx/fivem, master,
    --     code/components/citizen-resources-client/src/KVScriptFunctions.cpp):
    --     `RegisterNativeHandler("GET_RESOURCE_KVP_STRING",
    --     GetResourceKvp<const char*>)`, in the CLIENT resource component
    --     (the file path itself says so), matching this native's one call
    --     site (client/hud.lua, a client file). INDEPENDENTLY RE-FETCHED AND
    --     RE-CONFIRMED 2026-08-27 (a later, separate verification pass, not
    --     taken on the strength of the paragraph above): raw-fetched that
    --     exact file from citizenfx/fivem master this session and grepped
    --     its own `RegisterNativeHandler` calls directly -- line 575 reads
    --     `RegisterNativeHandler("GET_RESOURCE_KVP_STRING",
    --     GetResourceKvp<const char*>)`, verbatim. This is precisely the
    --     "symmetry is not verification" check this repo's own history
    --     shows is worth re-running even when a prior pass already did it:
    --     the getter and setter are NOT a symmetric pair (see immediately
    --     below), so confirming one is real says nothing about the other.
    --
    --   SET_RESOURCE_KVP_STRING -- CONFIRMED DOES NOT EXIST, by the same
    --     direct read of that same file (both the original pass and the
    --     2026-08-27 re-fetch above): the registrations in that
    --     KVScriptFunctions.cpp block are `SET_RESOURCE_KVP` (the
    --     string-taking overload -- `SetResourceKvp<const char*>`),
    --     `SET_RESOURCE_KVP_INT` and `SET_RESOURCE_KVP_FLOAT` -- there is no
    --     "_STRING"-suffixed setter to mirror the getter's own
    --     GET_RESOURCE_KVP_STRING; the setter's unsuffixed base name already
    --     means "string". THE BUG THIS ONCE DESCRIBED IS FIXED: client/hud.lua's
    --     MarkDurablyOpenedTablet/MarkDurablyDismissedHint now call
    --     `SetResourceKvp(...)` (confirmed by reading that file directly,
    --     2026-08-27), not the invented `SetResourceKvpString` this comment
    --     used to warn about -- SetResourceKvp is allowlisted above,
    --     alongside GetResourceKvpString's own original verification entry.
    --     SET_RESOURCE_KVP_STRING remains deliberately UN-allowlisted, same
    --     "an allowlist entry for a name that does not exist is how exactly
    --     this bug hides from luacheck" reasoning as the IsNightvisionActive/
    --     IsSeethroughActive entry above -- kept here purely as the
    --     historical record of a real, shipped, silent-write bug and its
    --     fix, not as a name to ever re-add.
    "IsControlJustPressed", "GetResourceKvpString",
}

-- Read+write: this resource's OWN cross-file globals. Every one of these is
-- deliberately declared as a bare global function (no `local`) in exactly
-- one file and called from others -- documented as this resource's
-- established "global helper, private per-file state" convention (see e.g.
-- server/cooldowns.lua's own file header, and server/certifications.lua for
-- the pattern it followed first). These are NOT undeclared-global typos, so
-- they belong in `globals` (readable AND assignable), not `read_globals`.
globals = {
    "Config",
    -- client/audio.lua -- NUI audio bridge (Phase 5). Plumbing only; no
    -- audio files ship with this resource, see html/sounds/CREDITS.md.
    "PlayK9Sound", "StopK9Sound", "IsK9SoundActive",
    -- Accessor so client/proximityaudio.lua can read client/audio.lua's
    -- AUDIO_MAX_DISTANCE at runtime instead of hand-copying it. Those two
    -- constants MUST agree: a trigger distance above the gain-falloff
    -- ceiling means every ambient loop plays at gain 0.0 -- a live audio
    -- source and a poll thread producing nothing audible, with no error.
    -- proximityaudio.lua currently clamps against a local duplicate of the
    -- ceiling, which defends the likely direction (trigger distance raised)
    -- but not the reverse (ceiling lowered). This entry exists so that
    -- duplicate can be replaced by a live read.
    "GetK9AudioMaxDistance",
    -- server/combat.lua -- termination primitive with no gate of its own.
    -- Authorization is the CALLER's job; gating a termination path is how
    -- an unbounded trap gets built. (It was first exposed for a recall
    -- feature that has since been removed; the primitive itself is still
    -- used by combat's own release paths.)
    "EndActiveEffectForHolder",
    -- server/entities.lua -- the shared cross-feature netId claim registry.
    -- ResolveNetworkEntity deliberately performs NO ownership or proximity
    -- check (see its own doc comment), so every caller must add one. The
    -- problem that forced a SHARED registry: DeployableKennel, FetchMechanic
    -- and PropAttachments all spawn networked props and all fall back to the
    -- same model, but each feature's ownership check only ever scanned its
    -- OWN table -- so a netId naming another feature's live object read as
    -- "unclaimed, safe to delete". Three per-feature checks that must be kept
    -- in sync are three checks that will drift; one registry all three
    -- consult cannot. Consumed by server/kennel.lua, server/fetch.lua and
    -- server/propattachment.lua.
    -- NOTE for anyone touching these: a Release path must NEVER be gated on
    -- an access check. Termination and cleanup have to stay reachable even
    -- for a caller who has lost access, or the fix becomes a permanent
    -- stranded-entity trap -- a worse bug than the hijack it closed.
    "ClaimNetworkEntity", "ReleaseNetworkEntity", "IsNetworkEntityClaimedByOther",
    -- server/bodyclaims.lua -- the SAME cross-feature-registry pattern as
    -- ClaimNetworkEntity/ReleaseNetworkEntity/IsNetworkEntityClaimedByOther
    -- immediately above, applied to a citizenid instead of a netId: closes
    -- a real, demonstrated race between server/kennel.lua's requestEnterKennel
    -- and server/vehicle.lua's requestVehicleSeatClaim (each could
    -- independently grant an exclusive claim on the SAME citizenid's own
    -- body at once, since neither previously consulted the other's
    -- registry), and extends the same guarantee to server/combat.lua's
    -- BiteAndHold/NonLethalTakedown/PropDragging target AND holder sides.
    -- IsBodyClaimed (distinct from IsBodyClaimedByOther) has no "own
    -- mechanic" to exempt -- it exists for a caller (server/combat.lua's own
    -- HOLDER-side check) that does not itself participate in this registry
    -- at all. Consumed by server/kennel.lua, server/vehicle.lua, and
    -- server/combat.lua. Same "a Release path must never be gated" note as
    -- immediately above applies here too.
    "ClaimBody", "ReleaseBody", "IsBodyClaimedByOther", "IsBodyClaimed",
    -- server/bodyclaims.lua, FORCED-RELEASE dispatcher (same file, same
    -- registry). ForceReleaseBodyClaimForCitizenId is called from
    -- server/certifications.lua's EndK9AccessForCitizenId when a player
    -- loses K9 access while still resting in a kennel or holding a vehicle
    -- seat; RegisterBodyClaimReleaser is how server/kennel.lua and
    -- server/vehicle.lua hand it their OWN teardown, so no file ever
    -- reaches into another's private occupancy table. A release path must
    -- never be gated -- see the identical note above, which is load-bearing
    -- here specifically: this dispatcher runs for a citizenid whose access
    -- has ALREADY been revoked, so any access check inside it would seal
    -- them inside the kennel it exists to let them out of.
    "RegisterBodyClaimReleaser", "ForceReleaseBodyClaimForCitizenId",
    -- server/progression.lua -- validates a Config-supplied XP mint budget
    -- parameter. Exists because a boundary value must never silently mean
    -- "blocked forever": server/cooldowns.lua's IsOnCooldown already treats a
    -- non-positive threshold as PERMANENTLY ON rather than "no cooldown", and
    -- the budget's first implementation created each citizenid's bucket empty
    -- and checked it in the same call, silently dropping the first XP award
    -- of every session for every player.
    "IsValidXpMintBudgetParam",
    -- server/progression.lua -- an XP TIER UNLOCK. Tiers used to apply only
    -- multipliers; this is one of the first that returns real capability.
    -- Anything gated behind a tier is gated behind roughly 2h27m of
    -- deliberate grinding at the current capped ceiling, so only put things
    -- here that are harmless in the hands of someone who simply ground for
    -- them -- and never something that would override a high-command block,
    -- which resolves separately and must win.
    "GetXPTierMedkitCooldownMs",
    -- server/highcommand.lua -- the PD high-command tier. IsHighCommand is
    -- consulted by server/admin.lua, server/certifications.lua and
    -- server/bonetool.lua to let high command bypass their own rank gates;
    -- every consumer guards it with type(fn) == 'function' so those files
    -- still work with Config.Features.HighCommand off. AwardXPDirect is the
    -- /k9givexp entry point, deliberately SEPARATE from server/progression's
    -- AwardXP: that one takes a config-owned actionKey precisely so no caller
    -- can name an arbitrary amount, and weakening it would have removed the
    -- guarantee for every other caller. This one accepts an amount, and is
    -- why it is bounded by Config.HighCommand.maxXpPerGrant and audited on
    -- every use.
    "IsHighCommand", "AwardXPDirect",
    -- client/tablet.lua -- the K9 command tablet. OpenTablet/CloseTablet are
    -- exposed so the radial and any other entry point route through the SAME
    -- open/close path rather than each managing NUI focus themselves. That
    -- matters more here than the usual DRY argument: this is the first
    -- focus-taking surface in this resource, and a stuck NUI focus locks a
    -- player out of their own character with no recovery short of a
    -- reconnect. One close path, reachable from everywhere, is the whole
    -- defence -- so never call SetNuiFocus directly from a second site.
    "OpenTablet", "CloseTablet",
    -- client/radial.lua -- candidate resolution for the leash and partner
    -- actions. Both were `local` until 2026-08-25; client/tablet.lua called
    -- them as globals, which would have been a nil call at runtime, so the
    -- tablet's leash and partner buttons would simply have errored. The seam
    -- was opened rather than letting the tablet carry its own copy: two
    -- implementations of "who is standing near me and eligible" drift apart
    -- the first time either is fixed. Callers guard with
    -- type(fn) == 'function' because client/radial.lua returns early when
    -- its own feature flag is off, in which case neither is ever defined.
    "FindNearestLeashCandidate", "FindNearestPartnerCandidate",
    -- server/permissions.lua -- the grantable-permission layer. High command
    -- grants a named capability, or a per-person feature grant or block, to
    -- one specific handler or K9.
    -- HasPermission is the hot path, consulted by server/certifications.lua
    -- and others behind the usual type(fn) == 'function' guard so those
    -- files still work with Config.Features.PermissionGrants off.
    -- Two properties worth remembering before touching any of these:
    --   * a grant only ever WIDENS access. Resolution is grant, then high
    --     command, then the legacy rank gate, then deny -- so revoking a
    --     grant from someone who also qualifies by RANK does not remove
    --     their access, and the caller has to be able to tell the operator
    --     that rather than reporting a successful revoke.
    --   * revoke deactivates a row, never deletes one. This is an
    --     authorization audit trail: who gave whom what power, and when it
    --     was taken away.
    "HasPermission", "GrantPermission", "RevokePermission",
    "ListActivePermissionsForCitizenId", "ListPermissionRoster",
    -- IsHighCommandBypassCitizenId (owner-directed "high command gets every
    -- permission/feature/upgrade automatically" pass) -- resolves a
    -- CITIZENID (never a live `source`) to "is this person high command
    -- right now", for the 'feature.<Name>' namespace's own HasPermission
    -- bypass and for server/certtiers.lua's TierCapabilityPermits,
    -- server/certifications.lua's HasSpecialization, and
    -- server/progression.lua's cooldown-multiplier family, all consulted
    -- behind the usual type(fn) == 'function' soft-dependency guard.
    "IsHighCommandBypassCitizenId",
    -- Seams opened so other files can reach logic that was previously locked
    -- inside an ox_target closure or a `local`. Each verified defined before
    -- being declared here: client/inventory.lua:326, client/medkit.lua:311,
    -- server/search.lua:685.
    -- GetContrabandAlertTier exposes the PURE tier calculation only -- it is a
    -- testability seam, and must never become a path that reaches inventory
    -- contents while skipping the access, proximity and cooldown checks the
    -- real search callback enforces.
    "RequestOpenOwnK9Inventory", "RequestTreatNearestK9", "GetContrabandAlertTier",
    -- client/propattachment.lua + client/fetch.lua (PropAttachments,
    -- FetchMechanic). Both features are REGISTERED in fxmanifest.lua and load
    -- on every server; their flags ship `false`. The note that stood here --
    -- "UNREGISTERED ... files that are in the tree but do not yet ship" -- was
    -- true when written and was overtaken by the registration pass.
    "AttachPropToOwnPed", "DetachAndDeleteProp", "RequestToggleK9PropAttachment",
    -- IsPropAttachmentEngaged: client/propattachment.lua's own engagement
    -- predicate, read by client/appearance.lua's "is this player mid-action"
    -- check via the same `type(...) == 'function'` soft-dependency guard the
    -- siblings below use (IsBiteHoldEngaged, IsDragEngaged,
    -- IsFetchCarryEngaged, IsInK9Vehicle). Added 2026-08-26: appearance.lua
    -- was consulting the other four and not this one, so a forced revert
    -- could fire on a player still wearing an attached prop.
    "IsPropAttachmentEngaged",
    -- ToggleCameraFeed: client/vision.lua's partner-camera toggle, same
    -- cross-file shape as ToggleThermalVision/ToggleNightVision.
    "ToggleCameraFeed",
    -- TierCapabilityPermits: server/certtiers.lua's capability gate, called
    -- by feature files to ask "does this person's certification tier allow
    -- this action". Deliberately fail-PERMISSIVE: it returns true unless the
    -- capability is actively granted by at least one tier AND this person's
    -- resolved tier is not among them. Every unresolvable case -- no tier,
    -- no lookup function, bad arguments, a capability no tier grants -- is
    -- an allow. That direction is load-bearing: every tier in every existing
    -- install predates capabilities, so failing closed would silently strip
    -- abilities from everyone on upgrade.
    "TierCapabilityPermits",
    -- IsK9FeatureBlocked / DenyK9FeatureBlocked: client/featureblocks.lua
    -- (defined at :280 and :289). The client-side half of per-person feature
    -- control -- the twelve features that live entirely on the player's own
    -- game and so have no server-side enforcement point to gate. Every call
    -- site gates the START of a feature only; the rule these must never
    -- violate is that a termination or cleanup path is never gated on a
    -- block check, or a blocked player gets stranded mid-feature.
    "IsK9FeatureBlocked", "DenyK9FeatureBlocked",
    -- server/permissionkeycatalog.lua -- the live, operator-editable
    -- permission-key catalog, overlaying Config.Permissions the same way
    -- server/certtiers.lua overlays its own config defaults. Definitions:
    -- IsKnownPermissionCatalogKey :425, GetPermissionCatalogLabel :433,
    -- ListPermissionCatalogKeys :454, PermissionKeyEditMutex :498.
    -- Consumed by server/permissions.lua through a type-guarded soft
    -- dependency, so permissions.lua keeps working if this file is absent.
    -- PermissionKeyEditMutex guards the delete-vs-grant race: without it a
    -- grant can commit a brand-new reference to a key deleted between the
    -- existence check and the write -- the same race TierEditMutex exists
    -- for in server/certtiers.lua.
    "IsKnownPermissionCatalogKey", "GetPermissionCatalogLabel",
    "ListPermissionCatalogKeys", "PermissionKeyEditMutex",
    "IsFetchCarryEngaged", "IsMyFetchBallOut", "FetchContextual", "ReleaseFetchBall", "RequestRecallFetchBall", "RequestThrowFetchBall",
    -- server/warrants.lua -- the sniff's warrant check and the optional wanted gate
    "IsPlayerK9Wanted", "CheckWarrantOnSniff",
    -- server/cooldowns.lua constructors
    "NewCooldown", "NewNestedCooldown", "NewMutex",
    -- server/notify.lua -- shared ox_lib notify wrapper, replacing 12
    -- hand-rolled copies. Two files deliberately keep a thin local wrapper
    -- over it to preserve their own distinct notification title.
    "NotifyPlayer",
    -- server/events.lua -- the shared outbound-event helper, extracted from
    -- six identical local copies into one resource-global. Fires the stable
    -- qbx_k9unit:events:* contract that server/exports.lua's header
    -- documents. Same consolidation as NotifyPlayer directly above.
    "FireOutboundEvent",
    -- server/certifications.lua
    "HasK9Access", "IsConfiguredK9Model", "RefreshCertificationCache",
    -- server/certifications.lua READ-ONLY ACCESSORS (certification-depth
    -- pass). All five are reads, never writes: a tier lookup, a tier-ordinal
    -- comparison, a specialization check, and two DB-authoritative reads the
    -- tablet and the offline-player paths need. No natives are involved, so
    -- none of these needed the native-decl verification step this file
    -- applies to real natives further down -- they are this resource's own
    -- cross-file global convention, identical in shape to the line above.
    "GetCertificationTier", "MeetsTierRequirement", "HasSpecialization",
    "QueryCertificationRecord", "QueryActiveSpecializations",
    -- client/appearance.lua + server/appearance.lua -- the K9 ROLE/MODEL
    -- DECOUPLING pass. These exist to satisfy a hard owner requirement:
    -- "everything works with any ped". A player holding the K9 ROLE gets
    -- every feature regardless of what model they wear -- a custom streamed
    -- ped, a ped absent from Config.Peds entirely, or a plain human model.
    -- That is why the role question (IsK9Role/HasK9Role) is deliberately a
    -- DIFFERENT function from the model question (IsEntityModelK9/
    -- IsConfiguredK9Model), which still answers "is this entity dog-shaped"
    -- and is still the right call for animations, bone indices and prop
    -- offsets. Do not collapse the two back into one: they answer different
    -- questions and the model one must keep its old meaning.
    -- IsK9RoleForPlayer answers the OTHER-player form of the same question,
    -- which the ten client target predicates need and which neither
    -- IsK9Role (self, client) nor HasK9Role (self, server) could answer.
    -- Remember what a predicate is: a CONVENIENCE gate. A stale or forged
    -- client-side answer here may make a menu option appear; the server
    -- re-checks on the action, so it must never make the action succeed.
    "IsK9Role", "IsK9RoleForPlayer",
    -- client/pursuitsprint.lua (K9_IDEAS.md §5) -- a resource-global so the
    -- radial and a chat command can both reach ONE entry point rather than
    -- forking the command body.
    "RequestPursuitSprint",
    -- server/datastore.lua -- the single accessor layer behind
    -- Config.Database.enabled. ONE code path, TWO backends: every DB read
    -- and write in this resource goes through K9Store, which dispatches to
    -- either real SQL or an in-memory table. The whole point is that there
    -- is no second `if Config.Database.enabled then` branch anywhere else,
    -- because a divergence between two branches is a bug that only shows up
    -- on whichever one the operator happens to run.
    "K9Store",
    -- server/selfcheck.lua -- boot-time dependency-version + Config.Features
    -- key check, extending K9Store's own "warn loudly, never block"
    -- discipline to two things nothing previously checked. Every function on
    -- this table is pure (no native calls, no globals beyond its own
    -- arguments), so tests/selfcheck_spec.lua exercises it directly with
    -- fabricated inputs -- see that file's own header.
    "K9SelfCheck",
    -- server/cooldowns.lua -- reads an operator-set cooldown out of Config
    -- and substitutes a safe fallback with a loud, key-naming warning when
    -- it is non-positive, instead of the previous error() at file-load time.
    -- That error was proportionate to nothing: setting one nested value to 0
    -- -- which means "no cooldown" in almost every other script an operator
    -- has ever configured -- crashed the whole file's top-level chunk, so
    -- BiteAndHold, NonLethalTakedown and PropDragging all died together and
    -- EndActiveEffectForHolder was never defined, leaving mid-hold players
    -- with no termination path at all.
    "ResolveConfiguredThresholdMs",
    -- server/certtiers.lua -- runtime-editable certification tiers. These
    -- answer questions ABOUT a tier (does it exist, what does it outrank,
    -- what does it grant); the tier a person HOLDS is still answered by
    -- server/certifications.lua's GetCertificationTier. Keep that split:
    -- one is a catalogue, the other is a record.
    "ListCertificationTiers", "IsKnownCertificationTierKey",
    "GetCertificationTierOrdinal",
    "TierHasCapability", "TierEditMutex",
    -- server/k9profiles.lua -- the per-INDIVIDUAL-K9 override layer (GAP 1
    -- closure: promoted from `local` to a resource-global in the SAME pass
    -- that gives it its first real cross-file consumer,
    -- server/progression.lua's GetXPTierMedkitCooldownMs and its client
    -- tier-snapshot composer -- exactly this resource's own established
    -- "add the allowlist entry in the same pass that creates the cross-file
    -- need" convention). Composes GLOBAL DEFAULT -> XP TIER -> INDIVIDUAL
    -- OVERRIDE into one effective speed/scent/medkit-cooldown answer; never
    -- a boolean, never an authorization decision.
    "GetK9EffectiveMultipliers",
    -- shared/compat/core.lua -- the resource auto-detection registry.
    -- Assigned in core.lua, read by the five sibling adapter files and by
    -- any future consumer. Same "global helper, per-file private state"
    -- convention as Config/IsHighCommand/NotifyPlayer above.
    "K9Compat",
    -- server/certifications/*.lua -- the TRANSPORT between the four files
    -- that 2026-09-02 split server/certifications.lua into. Lua locals do
    -- not cross files, so core.lua publishes what depth/accessors/commands
    -- need onto this table and each of those re-binds the same names as
    -- locals at its top -- which is what let the split move 6,012 lines
    -- without rewriting a single call site. NOT a public API: nothing
    -- outside server/certifications/ should read it, and the genuinely
    -- public surface (HasK9Access, GetCertificationTier and friends) stays
    -- global exactly as before.
    "K9Cert",
    "HasK9Role", "GetAssignedK9Model", "ApplyK9PedRole",
    "ApplyK9AppearanceOnGrant", "MaybeRevertK9Appearance",
    -- ForceRevertK9Appearance -- LANDED (verified by reading
    -- server/appearance.lua directly: a real, complete function at that
    -- file's own ForceRevertK9Appearance definition). This entry used to be
    -- PENDING: server/tablet.lua already called it so high command could
    -- strip someone's K9 ped and put them back to a human from the tablet,
    -- but server/appearance.lua had not defined it yet, so the call site's
    -- `type(fn) == 'function'` guard failed closed to a clean no-op.
    -- server/appearance.lua has since defined it (see that file's own
    -- ForceRevertK9Appearance doc comment, and server/tablet.lua's own
    -- "HAS NOW LANDED" note at its call site), so the guard now genuinely
    -- fires. Still listed here (same reason IsPinnedDogCharacter/
    -- GetPinnedDogCharacterModel above stay listed after landing): luacheck
    -- checks each file independently and does not infer this global from
    -- server/appearance.lua while linting server/tablet.lua. REMOVE THIS
    -- ENTRY only if the function is ever abandoned.
    "ForceRevertK9Appearance",
    -- MANA_POLICEDOGS FEATURE-PARITY PASS (server/dogcharacter.lua, NEW
    -- FILE) -- an explicit, admin-pinned "this citizenid is a dog" record,
    -- independent of any certification/permission credential. See that
    -- file's own header for the full precedence writeup against
    -- server/appearance.lua's existing certification-driven appearance.
    -- IsPinnedDogCharacter/GetPinnedDogCharacterModel/SetDogCharacter/
    -- RemoveDogCharacter are ALL already defined, in server/dogcharacter.lua
    -- itself (not pending) -- listed here because IsPinnedDogCharacter/
    -- GetPinnedDogCharacterModel are consumed from server/appearance.lua
    -- (a soft dependency, `type(fn) == 'function'` guarded there) once that
    -- file's own requested patch lands (see server/dogcharacter.lua's own
    -- header "ROUTED CHANGES" items 2-3) -- until then those two names are
    -- simply unread outside this file, which is not a lint issue.
    "IsPinnedDogCharacter", "GetPinnedDogCharacterModel",
    "SetDogCharacter", "RemoveDogCharacter",
    -- ApplyK9AppearanceDirect -- PENDING, same precedent as
    -- ForceRevertK9Appearance above: server/dogcharacter.lua's own
    -- SetDogCharacter already calls it (guarded with
    -- `type(fn) == 'function'`, degrading to a distinct, honest
    -- 'appearance_hook_unavailable' outcome rather than an error) but
    -- server/appearance.lua has not defined it yet as of this pass -- see
    -- server/dogcharacter.lua's own header "ROUTED CHANGES" item 1 for the
    -- exact function body requested. REMOVE THIS ENTRY if the function is
    -- ever abandoned -- an allowlisted name that nothing defines is how a
    -- missing function stops being visible, which is the failure class
    -- this project keeps finding.
    "ApplyK9AppearanceDirect",
    -- IsBiteHoldTargetEngaged -- LANDED (verified by reading
    -- client/combat.lua directly: a real, complete function, `return
    -- ActiveBiteHold ~= nil`). This entry used to be PENDING, same
    -- precedent as ForceRevertK9Appearance above: client/appearance.lua's
    -- IsCurrentlyEngaged() calls it so a bite-hold TARGET refuses a
    -- mid-hold model swap, mirroring the sibling
    -- IsDragTargetEngaged()/IsLocalPlayerForceRagdolled() checks right
    -- beside it in that same function, but client/combat.lua had not yet
    -- defined it (its own ActiveBiteHold target-side state was a bare file
    -- `local` with no exposed predicate, unlike ActiveDragSpeedLimit/
    -- ActiveForcedRagdoll, which both already had one). client/combat.lua
    -- has since defined it, so the `type(fn) == 'function'` guard at that
    -- call site now genuinely fires. Still listed here (same reason
    -- IsPinnedDogCharacter/GetPinnedDogCharacterModel above stay listed
    -- after landing): luacheck checks each file independently and does not
    -- infer this global from client/combat.lua while linting
    -- client/appearance.lua. REMOVE THIS ENTRY only if the function is ever
    -- abandoned.
    "IsBiteHoldTargetEngaged",
    -- server/main.lua
    "ForceDetachLeashForSource", "ForceDetachOfficerLeashForSource",
    -- client/main.lua
    "IsOwnModelK9", "CanShowK9UI", "DenyK9UIAccess", "IsK9KeybindAudience", "PlaySoundOnNetworkEntity",
    -- server/entities.lua (REFACTOR_ROADMAP.md near-term item 2) AND,
    -- separately, client/main.lua's OWN client-side function of the same
    -- name -- two distinct Lua VMs (server vs. client), same name by
    -- design for readability (same concept, mirrored API), same
    -- "shared name is intentional, not a shared symbol" convention
    -- client/main.lua's own header already documents for
    -- HasK9Access(source) vs. client/main.lua's HasK9Access().
    "ResolveNetworkEntity",
    -- REFACTOR_ROADMAP.md Revision 5 items 2b and 3, extracted this pass.
    -- ResolveConnectedPlayerFromPed (server/entities.lua) replaced three
    -- verbatim hand-copies in server/search.lua, server/inventory.lua and
    -- server/combat.lua; ResolvePlayerServerIdFromPed and IsEntityModelK9
    -- (both client/main.lua) replaced the client-side equivalents in
    -- client/medkit.lua and client/wellbeing.lua. Note
    -- ResolveConnectedPlayerFromPed deliberately scans GetPlayers()/
    -- GetPlayerPed rather than using NetworkGetPlayerIndexFromPed — that
    -- native combo was never verified server-side, and the scan is
    -- strictly more conservative. Do not "clean it up" into the native.
    "ResolveConnectedPlayerFromPed", "ResolvePlayerServerIdFromPed",
    "IsEntityModelK9",
    -- client/movement.lua
    "ToggleK9Camera", "K9Sit", "IsLeashed", "RequestLeashAttach", "DetachLeash",
    -- client/tracking.lua
    "GetActiveTrackType", "StartScentTrack", "StartBloodTrack",
    "StartGunpowderTrack", "StopTracking", "IsTracking",
    -- client/tracking.lua -- THE ONE MERGED ACTION (owner-directed
    -- decluttering pass, 2026-08-26): StartCertifiedTrack() is the single
    -- entry point client/radial.lua's collapsed "K9: Search" item and the
    -- new 'k9track' chat command both call, in place of the three former
    -- separate Track Scent/Blood/Gunpowder items above.
    "StartCertifiedTrack",
    -- client/tracking.lua -- SCENT VISION (owner-directed pass: a keybound
    -- coloured-dot "who walked through here" overlay, separate from the
    -- Track Scent/Blood/Gunpowder trio above). ToggleScentVision is the
    -- keybind entry point client/keybinds.lua's own new k9scentvision
    -- command calls; IsScentVisionActive is a read-only accessor exposed
    -- as a presentation surface, never a gate.
    "ToggleScentVision", "IsScentVisionActive",
    -- client/vehicle.lua
    "EnterNearestK9Vehicle", "ExitK9Vehicle", "IsInK9Vehicle",
    -- client/vision.lua
    "IsThermalVisionActive", "IsNightVisionActive", "ToggleThermalVision",
    "ToggleNightVision",
    -- CycleVision: client/vision.lua's vision-merge entry point (this pass,
    -- coder-architect) -- steps Off -> Night -> Thermal -> Off, skipping
    -- whichever mode is flag-off/feature-blocked. Called by the new
    -- 'k9vision' command/keybind (same file) and by client/radial.lua's new
    -- "K9 Vision" item.
    "CycleVision",
    -- client/kennel.lua (Phase 5 R&D, DeployableKennel)
    "RequestDeployKennel",
    -- RequestEnterOwnKennel / RequestKennelContextual: client/kennel.lua's
    -- command-consolidation pass -- the merged "/k9kennel" works out deploy
    -- vs enter vs exit from what is actually around you, instead of the
    -- player picking between three separate commands. Both are declared
    -- here rather than left to the file, because a resource-global that
    -- luacheck has never been told about reads as a typo forever.
    "RequestEnterOwnKennel",
    "RequestKennelContextual",
    -- RequestCloseKennelDoor / RequestOpenKennelDoor: the closeable-kennel
    -- extension to the same merged "/k9kennel" -- owner or current
    -- occupant only (server-authoritative), never gates leaving. See
    -- server/kennel.lua's own "CLOSEABLE KENNEL" header section.
    "RequestCloseKennelDoor",
    "RequestOpenKennelDoor",
    -- IsRestingInKennel/IsCarryingKennel: client/kennel.lua's own K9-can-
    -- ride-along pass, same "engagement predicate" shape as
    -- IsPropAttachmentEngaged/IsInK9Vehicle above -- exposed for a future
    -- client/appearance.lua model-swap guard, not yet wired there.
    "IsRestingInKennel", "IsCarryingKennel",
    -- ExitKennelRest: client/kennel.lua's trap-hunt fix (this pass) -- the
    -- occupant's own always-available exit, called from
    -- client/keybinds.lua's k9exitkennel command/keybind and
    -- client/radial.lua's "Exit Kennel" item, mirroring
    -- DetachLeash/ExitK9Vehicle above.
    "ExitKennelRest",
    -- server/progression.lua (Phase 4, PHASE4_SPEC.md §13.4.1,
    -- XPProgression) -- real, implemented this pass. AwardXP/GetXPTier are
    -- read from server/tracking.lua (the only current call sites) behind a
    -- `type(AwardXP) == 'function'` / `type(GetXPTier) == 'function'`
    -- existence guard each (this resource's standard soft-dependency
    -- convention), even though server/progression.lua itself
    -- already exists as of this pass -- the guard is kept regardless, per
    -- this resource's own "runtime existence guard, not a load-order
    -- assumption" convention (see fxmanifest.lua's own comment on
    -- server/medkit.lua's ordering for the precedent this follows).
    "AwardXP", "GetXPTier", "GetXP",
    -- server/progression.lua -- GAP 1 closure (per-INDIVIDUAL-K9 override,
    -- server/k9profiles.lua). Exposed so that file's own k9ProfileUpsert/
    -- k9ProfileReset tablet callbacks can push a fresh, override-composed
    -- tier snapshot to an already-connected citizenid's client THE MOMENT
    -- high command edits their override -- without this, the edit would sit
    -- correct-but-invisible until that citizenid's next real tier crossing,
    -- reconnect, or a resource restart.
    "PushXPTierSnapshotIfOnline",
    -- server/progression.lua -- HANDLER XP (Config.Features.
    -- HandlerXPProgression), a SEPARATE accumulated total from AwardXP/
    -- GetXPTier above (own `handler_xp` column, own Config.HandlerXPTiers
    -- ladder). AwardHandlerXP is read from server/certifications.lua (both
    -- GrantCertification and GrantCertificationOffline) and
    -- server/tenure.lua's CheckTenureMilestonesForK9, each behind a
    -- `type(AwardHandlerXP) == 'function'` runtime existence guard, same
    -- soft-dependency convention as AwardXP itself. GetHandlerXPTier has no
    -- external caller yet (exposed for the same future-consumer reason
    -- GetXP was originally exposed) but is listed here now rather than
    -- deferred, since it is already a real, tested, resource-global
    -- function as of this pass.
    "AwardHandlerXP", "GetHandlerXPTier",
    -- server/progression.lua. Handler-side twin of GetXP, added for the
    -- tablet's Progression screen: GetHandlerXPTier alone cannot answer "how
    -- far into this rank am I" because a tier's own `xp` field is a
    -- THRESHOLD, not a running total. Read by server/tablet.lua.
    "GetHandlerXP",
    -- server/progression.lua. Display-safe copies of the two XP ladders
    -- (label + threshold only -- never the multipliers, which are internal
    -- tuning a player has no use for and which would publish how a server
    -- has tuned its own K9s). Read by server/tablet.lua's Progression
    -- screen to answer "what is my next rank and how far away is it".
    "GetXPLadderForDisplay",
    "GetHandlerXPLadderForDisplay",
    -- server/progression.lua -- HANDLER XP TIER COOLDOWN EFFECTS
    -- (Config.HandlerXPTiers' medkitTreatCooldownMultiplier/
    -- kennelDeployCooldownMultiplier, previously defined but read by
    -- nothing). Read from server/medkit.lua's RunUseK9MedkitMutation and
    -- server/kennel.lua's deploy/pickup success path respectively, each
    -- behind a `type(...) == 'function'` runtime existence guard, same
    -- soft-dependency convention as AwardHandlerXP itself. Deliberately NOT
    -- an XP mint eligibility check -- see this file's own declaration
    -- comment on these two functions for why deriving mint eligibility from
    -- either cooldown effect would reopen a rank-climbing farm loop.
    "GetHandlerXPTierMedkitCooldownMs", "GetHandlerXPTierKennelDeployCooldownMs",
    -- client/movement.lua's PHASE4_SPEC.md §13.0 Decision 2 "move-rate
    -- composer" -- REAL, IMPLEMENTED (coder-frontend pass, real-bug fix):
    -- a qa-tester finding caught client/wellbeing.lua unconditionally
    -- writing K9MoveRateModifiers.fatigue/.injury/.mood and calling
    -- RecomputeK9MoveRate() with NEITHER symbol defined anywhere in this
    -- codebase (this comment previously read "FORWARD-DECLARED ONLY --
    -- neither symbol exists," which was accurate at the time it was
    -- written but is now stale) -- a guaranteed hard error the instant any
    -- wellbeing feature flag flipped true, latent only because every such
    -- flag defaults to false in config.lua. Both symbols are now defined
    -- for real in client/movement.lua: K9MoveRateModifiers is a plain
    -- table of named multiplier contributions (fatigue/injury/mood/
    -- xpTier/dragging, each defaulting to 1.0), and RecomputeK9MoveRate()
    -- composes them multiplicatively, clamps to [0.1, 2.0], and makes the
    -- single real SetPedMoveRateOverride call for the K9's own ped -- see
    -- that function's own header comment in client/movement.lua for the
    -- full composition/clamp/interaction writeup. client/progression.lua
    -- still reads BOTH behind `if K9MoveRateModifiers then ... end` /
    -- `type(RecomputeK9MoveRate) == 'function'` existence guards even
    -- though they now really exist -- that's intentional, not stale
    -- itself: this resource's documented convention is a runtime
    -- existence guard, not a load-order assumption (see fxmanifest.lua's
    -- own comment on server/medkit.lua's ordering for the same precedent),
    -- so those guards are correct to keep regardless of load order.
    "K9MoveRateModifiers", "RecomputeK9MoveRate",
    -- client/progression.lua (Phase 4, PHASE4_SPEC.md §13.4.1) -- real,
    -- implemented this pass. Exposed for a future HUD/display need
    -- (PHASE4_SPEC.md §13.4.1's own "additive read, not a new
    -- authorization surface" framing), not currently consumed elsewhere in
    -- this resource.
    "GetCurrentXPTier",
    -- client/progression.lua's handler-ladder counterpart to GetCurrentXPTier
    -- above (owner-directed progression pass). Declared ABOVE that file's own
    -- `if not Config.Features.XPProgression then return end` gate on purpose:
    -- the handler ladder is a SEPARATE switch (HandlerXPProgression), so a
    -- server running one without the other must still get this. Consumed by
    -- client/tablet.lua's Progression screen.
    "GetHandlerXPState",
    -- client/combat.lua (Phase 3 completion pass, BiteAndHold/
    -- NonLethalTakedown self-initiated triggers) -- for a future
    -- client/radial.lua "Bite & Hold"/"Takedown" entry to call, same
    -- "global helper, private per-file state" convention as
    -- RequestLeashAttach/DetachLeash above.
    "RequestBiteHold", "ReleaseBiteHold", "IsBiteHoldEngaged", "RequestTakedown",
    -- ReleaseTakedown/IsTakedownEngaged: CANCEL-PATH FIX (this pass,
    -- coder-frontend — audit-flagged gap). Mirrors ReleaseBiteHold/
    -- IsBiteHoldEngaged's own shape exactly, for server/combat.lua's new
    -- releaseTakedown handler — see client/combat.lua's own doc comment on
    -- ReleaseTakedown() for why this is not yet wired into
    -- client/radial.lua/client/keybinds.lua (outside this pass's edit
    -- scope), same "exposed for a future entry" convention as
    -- RequestDrag/ReleaseDrag/IsDragEngaged below.
    "ReleaseTakedown", "IsTakedownEngaged",
    -- client/combat.lua (focus-and-state audit finding #2, this pass) --
    -- whether THIS client is currently the TARGET of an active forced
    -- ragdoll (the non-lethal takedown above), consumed by
    -- client/tablet.lua's own watch thread to force-close an open tablet
    -- on the same "cannot act" condition it already force-closes on death
    -- for -- see that file's own header "DOWNED-BY-TAKEDOWN ALSO
    -- FORCE-CLOSES". Guarded with `type(fn) == 'function'` at its one call
    -- site, same non-optional convention as FindNearestLeashCandidate/
    -- FindNearestPartnerCandidate above.
    "IsLocalPlayerForceRagdolled",
    -- server/partnership.lua (Phase 3, HandlerPartnership registry,
    -- PHASE3_SPEC.md §12.0 item 7/§12.3). RefreshPartnershipCache mirrors
    -- server/certifications.lua's RefreshCertificationCache reuse hook
    -- (called from this file's own onResourceStart backfill loop, exposed
    -- globally for the same "documented reuse hook" reason). GetActivePartnerCitizenId/
    -- IsActivePartnerOf are read-only accessors (server/appearance.lua and
    -- server/main.lua's partner leash shortcut, plus server/exports.lua).
    -- ForceBreakPartnershipForCitizenId is citizenid-keyed (not
    -- source-keyed, unlike leash's ForceDetachLeashForSource/
    -- ForceDetachOfficerLeashForSource above) -- called by
    -- server/certifications/'s cert-revoke/department-change teardowns and
    -- the tablet's Force End.
    "RefreshPartnershipCache", "ForceBreakPartnershipForCitizenId",
    "GetActivePartnerCitizenId", "IsActivePartnerOf",
    -- client/partnership.lua (Phase 3, the client half of
    -- server/partnership.lua above) -- RequestPartnerUp/BreakPartnership
    -- mirror client/movement.lua's RequestLeashAttach/DetachLeash pair
    -- exactly (self-initiated trigger + zero-consent termination).
    -- TogglePartnership is the one Partner Up / Break Partnership action
    -- shared by /k9partner, the radial item and the tablet button.
    -- IsPartnered/GetPartnerServerId are read-only accessors.
    "RequestPartnerUp", "BreakPartnership", "TogglePartnership", "IsPartnered", "GetPartnerServerId",
    -- RefreshPartnershipStateFromServer yields on a server callback and
    -- re-syncs the local cache before returning fresh IsPartnered()/
    -- GetPartnerServerId() values. It exists because the local cache can
    -- under-report after a reconnect (nothing re-syncs an already-partnered
    -- client), and a naive IsPartnered()-driven radial toggle would then
    -- offer "Partner Up" to exactly the player who needs the exit. Kept in
    -- client/partnership.lua rather than called raw from client/radial.lua,
    -- so every partnership round trip stays owned by one file.
    "RefreshPartnershipStateFromServer",
    -- client/combat.lua's PropDragging trigger surface (Phase 3,
    -- PHASE3_SPEC.md §12.5.4) -- same self-initiated-trigger plus
    -- zero-consent-release shape as RequestBiteHold/ReleaseBiteHold above.
    -- Not yet wired into client/radial.lua; exposed for that future entry.
    "RequestDrag", "ReleaseDrag", "IsDragEngaged",
    -- IsDragTargetEngaged answers the OTHER half of the same question --
    -- "am I the one BEING dragged", as opposed to IsDragEngaged()'s "am I
    -- the one dragging". server/combat.lua's releaseDrag handler has always
    -- accepted a release from the target as well as the holder, but every
    -- client call site asked only the holder-side question and so fell
    -- through to the REQUEST branch for a target, where CanShowK9UI()
    -- denied them -- making the documented self-release unreachable in
    -- practice. Consumed by client/keybinds.lua, client/radial.lua and
    -- client/tablet.lua, each with the same `type(fn) == 'function'` guard
    -- its siblings above use.
    "IsDragTargetEngaged",
    -- server/equipmentshop.lua -- READ-ONLY: how many supply shop items
    -- currently require a given certification tier, plus their keys.
    -- Consumed by server/certtiers.lua's delete refusal, which loads
    -- BEFORE equipmentshop.lua (fxmanifest.lua) and so calls it through
    -- the same `type(fn) == 'function'` guard every other cross-file
    -- global here uses. It lives in equipmentshop.lua because only the
    -- MERGED config+database item catalog knows the answer -- a raw
    -- database count would include tombstoned items, and config alone
    -- carries no tier requirements at all.
    "CountEquipmentShopItemsRequiringTier",
    -- client/search.lua -- READ-ONLY: is this K9 part-way through a
    -- contraband search right now. The other half of the MUTUAL GUARD
    -- between searching and the three combat mechanics: client/search.lua
    -- refuses to start a search while a bite/drag/vehicle already owns the
    -- ped, and client/combat.lua reads this to refuse the reverse. A guard
    -- in only one direction does not prevent the conflict, it just decides
    -- which mechanic has to be started second.
    "IsSearchInProgress",
    -- server/progression.lua -- re-pushes every connected K9's XP-tier
    -- snapshot, called by server/runtimecontrol.lua when high command
    -- flips Config.Features.XPProgression from the tablet. That flag is
    -- declared `tier = 'live'`, i.e. the resource promises a toggle that
    -- needs no restart -- but the push used to hard-return while the flag
    -- was off, so it could never send the "this is off now" payload the
    -- client half was already written and tested to handle. An officer
    -- switching XP progression off mid-shift left every K9 already online
    -- holding their earned speed buff until that specific player
    -- reconnected. Guarded at its one call site with the same
    -- `type(fn) == 'function'` convention as every other cross-file global.
    "RefreshXPProgressionLiveStateForAllOnline",
    -- server/progression.lua -- the HANDLER-side twin of
    -- RefreshXPProgressionLiveStateForAllOnline immediately above, added
    -- when a client push (qbx_k9unit:client:handlerXpTierChanged) was
    -- built for the handler XP ladder for the first time ("a handler
    -- cannot see their own rank or XP anywhere" gap closure). NOT YET
    -- called from server/runtimecontrol.lua's ApplyFeatureOverride as of
    -- this entry -- see this function's own declaration comment
    -- (server/progression.lua) for the exact one-branch hookup that file
    -- still needs and why it was not made in the same pass that added this
    -- function.
    "RefreshHandlerXPProgressionLiveStateForAllOnline",
    -- server/combat.lua / server/kennel.lua -- READ-ONLY live headcount
    -- accessors for server/runtimecontrol.lua's own "ACTIVE-USAGE
    -- CONFIRMATION FEATURES" gate (that file's own header section): "how
    -- many players are doing this specific thing right now", so a high-
    -- command officer disabling BiteAndHold/NonLethalTakedown/PropDragging/
    -- DeployableKennel while it is genuinely in use gets a real, current
    -- number in the confirmation warning rather than a generic "are you
    -- sure?". Both runtime-existence-guarded + pcall-wrapped by their one
    -- caller, same soft-dependency convention as EndActiveEffectForHolder
    -- above -- server/runtimecontrol.lua's own test sandbox does not load
    -- either combat.lua or kennel.lua, by that spec's own design.
    "CountActiveHoldsByEffectType", "CountKennelOccupants",
    -- server/search.lua -- READ-ONLY: iterates connected players within a
    -- given radius of a given point and calls back for each. Extracted from
    -- BroadcastContrabandAlert's own original inline loop (PERFORMANCE AUDIT
    -- PASS, this pass, coder-backend) so server/main.lua's relayBark/
    -- relayDoorScratch can reuse the identical "who is genuinely near this
    -- point right now" logic instead of each hand-rolling its own
    -- GetPlayers()/GetPlayerPed()/distance loop, to distance-filter what
    -- used to be unconditional `TriggerClientEvent(..., -1, ...)`
    -- broadcasts. Never gates on anything itself (no HasK9Access/
    -- Config.Features check) -- every caller applies its own gating before
    -- or inside the callback it passes in.
    "ForEachNearbyPlayer",
    -- server/combat.lua -- READ-ONLY: is this K9 currently the active holder
    -- of a bite, a takedown or a drag. NO LONGER PENDING (2026-08-26) -- it
    -- was allowlisted ahead of being written, and is now genuinely defined
    -- in that file, right after CountActiveHoldsByEffectType.
    --
    -- Consumed by server/search.lua, which needed to refuse a search from a
    -- dog that already has hold of somebody. The client half of that guard
    -- already existed and was worth nothing against a modified game, because
    -- it ran on the player's own machine; the server had no way to ask the
    -- question at all until this.
    "IsK9CurrentlyHolding",
    -- server/combat.lua -- READ-ONLY, same posture as IsK9CurrentlyHolding
    -- immediately above: which effectType (if any) a holder currently
    -- holds, so a denying caller (server/vehicle.lua's own
    -- requestVehicleSeatClaim) can pick between two already-shipped,
    -- effect-specific rejection messages instead of one generic one.
    "GetActiveHoldEffectTypeForHolder",
    -- IsSearchInProgressForSource -- server/search.lua, exposed for a
    -- FUTURE server/combat.lua consumer, same "expose now, wire up later"
    -- precedent as FindNearestLeashCandidate/FindNearestPartnerCandidate
    -- above. Read-only accessor over that file's own file-local
    -- SearchMutex -- answers "is this source's own searchTarget call
    -- genuinely in flight right now", the read half of closing the reverse
    -- direction of the search/combat MUTUAL GUARD (a bite/takedown/drag
    -- starting while a search's progress bar is already running
    -- server-side) -- NOT yet wired into server/combat.lua's
    -- ValidateCombatRequest, which is that file's own call to make.
    "IsSearchInProgressForSource",
    -- server/roster.lua (NEW FILE, ROSTER_SPEC.md, Phase A -- K9 Command
    -- Tablet rosters, data layer + server logic). These are CORE LOGIC
    -- functions exposed as globals DELIBERATELY WITHOUT their own
    -- authorization check (see each one's own doc comment): this file's
    -- own `lib.callback` handlers are one caller, re-verifying
    -- IsHighCommand(source) before calling in; a later, serialized pass
    -- integrating `GrantCertificationForTablet`/a new
    -- `RevokeCertificationForTablet` wrapper (both server/certifications.lua,
    -- out of scope for this pass) is expected to call
    -- RosterAssignPersonnelRole/ClearPersonnelRowForCitizenJob directly,
    -- from ITS OWN already-verified authority, at hire/fire time
    -- respectively -- see server/roster.lua's own file header for the
    -- exact integration this allowlists in advance.
    "RosterAssignPersonnelRole", "RosterSetCallsign", "ClearPersonnelRowForCitizenJob",
    -- config.lua -- FEATURE GROUPS (FEATURE_STRUCTURE_SPEC.md, the nested
    -- Config.FeatureGroups tree). Deliberately global, not local, same
    -- documented exception this codebase already makes elsewhere (see
    -- GetXPTier above): each has a REAL caller beyond the test suite.
    -- GetFeatureGroupFamily/IsStandaloneFeatureFlag are read by
    -- tests/featuregroups_spec.lua to prove the family-membership drift
    -- guard against the real function, never a hand-typed duplicate of it.
    -- IsFeatureGroupParentEnabled is read by server/runtimecontrol.lua's
    -- own "PARENT-OFF REFUSES CHILD-ON" gate (runtimeSetFeature) and its
    -- boot-time override-reapply loop, both behind a
    -- `type(IsFeatureGroupParentEnabled) == 'function'` runtime existence
    -- guard, same soft-dependency convention as every other cross-file
    -- global in this list -- config.lua loads before server/runtimecontrol.lua
    -- either way (fxmanifest.lua), so the guard is defensive, not a real
    -- load-order gap.
    -- ResolveFeatureGroups itself -- called once, unconditionally, at the
    -- bottom of config.lua's own "FEATURE GROUPS RESOLVER" section; global
    -- for the identical reason as the three above (tests/featuregroups_spec.lua
    -- re-invokes the real function against a mutated Config.FeatureGroups
    -- rather than testing a duplicate of its logic).
    "ResolveFeatureGroups",
    "GetFeatureGroupFamily", "IsStandaloneFeatureFlag", "IsFeatureGroupParentEnabled",
}

-- Unused-argument checking is off. Rationale, not a blanket "quiet the
-- linter" call: this codebase's event/native callbacks (ox_target
-- interaction handlers, entity-enumeration callbacks, etc.) receive a fixed
-- positional signature (entity, distance, coords, name, ...) dictated by the
-- caller, not by this code -- a handler that only needs `entity` still has
-- to accept the rest positionally. Flagging every one of those as "unused
-- argument" is exactly the kind of pure noise this task asked to avoid, and
-- was confirmed by spot-checking: every current instance is a fixed-shape
-- callback parameter, not a leftover/forgotten one.
-- Unused LOCAL variables are still flagged (unused_args only silences
-- parameters) -- that class is left on because it does catch real mistakes.
unused_args = false

-- Line length is left unenforced. This codebase's dominant convention (see
-- any file's header comment, or e.g. server/cooldowns.lua) is dense, precise
-- inline documentation of WHY a line of code is the way it is, and several
-- existing lines already run well past a conventional 120-column limit for
-- exactly that reason. That is the same kind of deliberate, load-bearing
-- style choice that ruled out an automatic formatter earlier -- enforcing a
-- column limit here would flag the convention itself, not a real problem.
-- If this repo later wants line-length enforcement, that's a judgment call
-- for whoever owns the style guide, not something to slip in silently here.
max_line_length = false
