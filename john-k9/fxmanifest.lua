fx_version 'cerulean'
game 'gta5'

name 'John-K9' -- display name; the folder (resource name) is john-k9, lowercase on purpose (see README "Installing")
author 'John Allday'
description 'Player-controlled K9 unit for Qbox police/security departments'
version '0.1.0'

-- Built by John Allday. Proprietary -- not open source. See LICENSE.md for
-- the full terms; the short version is that this is licensed for use on the
-- purchaser's own server and may not be redistributed, resold, shared or
-- published, in whole or in part.

-- ----------------------------------------------------------------------
-- Manifest convention note:
-- Matched against real Qbox-project resources fetched at scaffold time
-- (qbx_ambulancejob, qbx_policejob, qbx_truckerjob, qbx_smallresources):
--   * `ox_lib 'locale'` + `'@ox_lib/init.lua'` in shared_scripts is the
--     standard way every one of those resources pulls in ox_lib.
--   * `'@qbx_core/modules/playerdata.lua'` (client) and
--     `'@qbx_core/modules/lib.lua'` (shared) are included in every fetched
--     qbx_* job/feature resource, not just qbx_core itself. playerdata.lua
--     exposes a live-updated global `QBX.PlayerData` client-side cache
--     (job/citizenid/etc.) so client stubs should read from that rather
--     than re-inventing a player-data cache.
--   * ox_target and oxmysql ship no equivalent `@resource/init.lua` to
--     require -- they're consumed purely through their exports/wrapper --
--     so they only need to appear in `dependencies` below (oxmysql also
--     gets its `@oxmysql/lib/MySQL.lua` wrapper in server_scripts since
--     server/certifications/ and server/search.lua do direct SQL work
--     -- server/main.lua does not call MySQL.* at all, it only calls
--     RefreshCertificationCache/HasK9Access, exposed globals owned by
--     server/certifications/).
-- ----------------------------------------------------------------------
ox_lib 'locale'

dependencies {
    'qbx_core',
    'ox_lib',
    'ox_target',
    'oxmysql',
    -- NOTE for anyone setting Config.Database.enabled = false: oxmysql
    -- below is a HARD dependency and FXServer refuses to start this
    -- resource without that resource present and started. That check runs
    -- before config.lua is ever read, so no config setting can route
    -- around it. Turning Config.Database off means this resource sends
    -- oxmysql no queries and needs none of its own tables -- it does NOT
    -- mean you can uninstall oxmysql.
    'ox_inventory', -- server/search.lua reads item weights/contents via ox_inventory exports (GetInventoryItems/GetContainerFromSlot).
}

shared_scripts {
    '@ox_lib/init.lua',
    '@qbx_core/modules/lib.lua',
    'config.lua',
    -- RESOURCE AUTO-DETECTION (Config.Compat). shared_scripts, not
    -- client_scripts/server_scripts, because every one of these files runs
    -- on BOTH Lua VMs from the same source: core.lua works out its own
    -- realm via IsDuplicityVersion() and hands 'client' or 'server' to each
    -- adapter's factory, so one registration serves both sides.
    -- HARD ORDER: core.lua before all five adapters -- they call
    -- K9Compat.RegisterAdapter at their own file-load time, so core being
    -- later is a nil-index at start, not a degraded feature. core.lua after
    -- config.lua, since it reads Config.Compat. Order AMONG the five
    -- adapters does not matter.
    'shared/compat/core.lua',
    'shared/compat/inventory.lua',
    'shared/compat/target.lua',
    'shared/compat/framework.lua',
    'shared/compat/dispatch.lua',
    'shared/compat/ambulance.lua',
}

-- The first NUI surface this resource has ever had (the passive vitality
-- HUD, Config.Features.HealthStaminaHUD — `true` in config.lua as of
-- 2026-08-25, when every Config.Features flag was enabled; see
-- client/hud.lua). ui_page is loaded/kept
-- alive for the entire client session (not opened/closed like a modal —
-- html/index.html starts hidden and stays that way client-side until
-- client/hud.lua's poll thread says otherwise), per
-- DEVELOPER_REFERENCE.md#hud-bridge §7.
ui_page 'html/index.html'

files {
    'html/index.html',
    'html/style.css',
    -- The server logo shown in the tablet header. A placeholder ships here
    -- so this entry is never dangling; the operator replaces the FILE, not
    -- this line. An image the manifest does not list is silently not sent
    -- to clients -- it renders as nothing, with no error saying why -- which
    -- is why the config tells anyone changing the path to add it here too.
    'html/images/logo.png',
    'html/app.js',
    -- The NUI audio layer fetches 'sounds/<key>.ogg' relative to
    -- html/index.html, so every shipped sound needs its own entry here or it
    -- 404s on the client and the loader degrades to silence -- which looks
    -- exactly like the feature being off.
    -- COMPLETE as of 2026-08-25: all five keys the bridge can request now
    -- ship. Four come from client/audio.lua's SOUND_NAME_TO_FILE_KEY map;
    -- the fifth, growl_ambient, comes from Config.ProximityAudioFX.soundName
    -- via ToAudioFileKey's lowercase fallback, which is easy to miss when
    -- auditing this list against that map alone.
    -- Provenance and licences are recorded in html/sounds/CREDITS.md -- read
    -- it before adding or replacing any file here. The three extra barks are
    -- genuinely distinct takes from the same source recording as bark.ogg,
    -- not copies of it, and growl_ambient is a seam-verified loop (the
    -- proximity layer plays it with loop = true, so an edge fade would put an
    -- audible gap in every repeat).
    'html/sounds/bark.ogg',
    'html/sounds/bark_alert.ogg',
    'html/sounds/bark_aggressive.ogg',
    'html/sounds/bark_calm.ogg',
    'html/sounds/growl_ambient.ogg',
    -- K9 Command Tablet (Config.Features.CommandTablet). FiveM allows only
    -- ONE ui_page, which is already html/index.html for the vitality HUD, so
    -- the tablet lives in its own document loaded through an <iframe> that
    -- index.html embeds, with tablet-bridge.js relaying between the two
    -- windows. That keeps it fully isolated from the HUD's own DOM, CSS and
    -- JS -- html/app.js is not touched at all -- which matters because the
    -- HUD is a passive always-on surface and the tablet is an interactive
    -- one that takes NUI focus.
    -- EVERY ONE OF THESE FOUR MUST BE LISTED. An unlisted asset is a 404
    -- that the loader swallows, and a tablet that silently never renders
    -- looks exactly like the feature being switched off.
    'html/tablet.html',
    -- SPLIT 2026-09-02: 1,749 lines of pure catalog data (the string
    -- table and the command reference) moved out of tablet.js. BOTH must
    -- be listed -- an unlisted asset 404s silently and the tablet renders
    -- nothing -- and tablet.html loads the catalog FIRST, on purpose.
    'html/tablet-catalog.js',
    'html/tablet.js',
    'html/tablet.css',
    'html/tablet-bridge.js',
    -- ox_lib 'locale' has been declared at the top of this manifest from the
    -- start, promising localisation that did not exist -- every player-facing
    -- string was hardcoded English until now. That migration is COMPLETE as of
    -- 2026-08-25: every player-facing string in the resource routed through
    -- locale(), cross-checked to zero missing (no call site anywhere
    -- references a key that does not exist). This comment used to pin an
    -- exact key count ("319 keys... cross-checked to zero missing and zero
    -- unused") — that count is long stale (the resource has grown
    -- substantially since), and "zero unused" does not hold either: a
    -- handful of keys are flagged unused at any given time (dead weight from
    -- a renamed/removed feature, safe to delete once confirmed). Rather than
    -- re-pin a number here that will just go stale again, run
    -- `python3 .github/scripts/locale_cross_check.py` for the current,
    -- authoritative key/call-site/missing/unused counts. The earlier note
    -- here before this one said 2 of ~48 files were migrated; that is long
    -- stale too.
    -- Listed explicitly rather than as 'locales/*.json': research into the
    -- files{} glob found `*` currently behaves recursively and is itself the
    -- subject of an open upstream replacement proposal, and every other entry
    -- in this manifest is explicit. Add each new locale file by name.
    'locales/en.json',
}

client_scripts {
    '@qbx_core/modules/playerdata.lua',
    'client/main.lua',
    'client/appearance.lua', -- K9 role client half (IsK9Role/IsK9RoleForPlayer). Loaded after client/main.lua because CanShowK9UI() consults IsK9Role() -- resolution is at CALL time, so this is convention rather than a hard requirement, but keep the order.
    -- Per-person feature blocks for the twelve CLIENT-ONLY features
    -- (server/runtimecontrol.lua tiers them 'clientonly'): they live
    -- entirely on the player's own game, so there is no server-side
    -- point of use to gate and this is their ONLY per-person block path.
    -- Defines IsK9FeatureBlocked/DenyK9FeatureBlocked, consumed by
    -- agility, hud, proximityaudio, radial, screenfx, vehicle and vision.
    -- Listed before all of them: Lua resolves globals at CALL time so this
    -- is convention rather than a hard requirement, same as the
    -- client/appearance.lua note above -- but keep the order.
    'client/featureblocks.lua',
    'client/movement.lua',
    'client/agility.lua', -- AgilityAdvanced (fence/window vault), extracted from client/movement.lua. Self-contained: no shared local state with its old home, and nothing else in the resource read its locals. No load-order dependency -- calls CanShowK9UI()/IsOwnModelK9() at call time only.
    'client/radial.lua',
    -- K9 command tablet (Config.Features.CommandTablet). Two surfaces in
    -- one: high command gets a control console, and every certified handler
    -- or K9 gets a read-only view of their own record plus the ability to
    -- TRIGGER what they hold, as an alternative to keybinds and commands.
    -- It routes each action to the same client function the keybind calls
    -- rather than reimplementing it -- a forked entry point is how one path
    -- ends up guarded and the other does not, which this resource has
    -- already been bitten by once (ScratchAtDoor/NudgeDoor).
    -- NOTE this is the FIRST focus-taking NUI surface here. A stuck focus
    -- locks a player out of their own character, so the close path is
    -- deliberately singular: OpenTablet/CloseTablet are globals precisely so
    -- no other site calls SetNuiFocus itself. Its html assets are listed in
    -- files{} above once the UI lands.
    'client/tablet.lua',
    'client/vehicle.lua',
    'client/tracking.lua',
    'client/pursuitsprint.lua', -- PROJECT_HISTORY.md §5 (PursuitSprint), client half. No load-order dependency.
    'client/search.lua',
    'client/findalert.lua', -- PROJECT_HISTORY.md §1 (FindAlerts), client half. Reuses client/main.lua's PlaySoundOnNetworkEntity at runtime only, so no load-order requirement beyond that file existing.
    'client/vision.lua',
    'client/hud.lua',
    'client/inventory.lua', -- K9Inventory, DEVELOPER_REFERENCE.md §13.4.2
    'client/kennel.lua',   -- R&D (DeployableKennel, DEVELOPER_REFERENCE.md#phase-5-research §5)
    'client/medkit.lua',   -- K9Medkit, DEVELOPER_REFERENCE.md §13.4.4
    'client/wellbeing.lua', -- Fatigue subsystem, client half (the mood/fear-stress/distraction/injury stats it once shared a file with were removed 2026-09-02)
    'client/progression.lua', -- XPProgression, DEVELOPER_REFERENCE.md §13.4.1
    'client/combat.lua', -- BiteAndHold/NonLethalTakedown, DEVELOPER_REFERENCE.md §12.5.1/§12.5.2 -- the client half of server/combat.lua; no ordering dependency on anything else in this list (reads Config.Combat/Config.Features from config.lua, already loaded via shared_scripts, and calls CanShowK9UI/DenyK9UIAccess from client/main.lua, which is loaded earlier in this same list, but Lua global-function resolution here is at CALL time, not load time, so this would still work even loaded first)
    'client/partnership.lua', -- HandlerPartnership registry, DEVELOPER_REFERENCE.md §12.0 item 7/§12.3 -- the client half of server/partnership.lua (Partner Up consent prompt, ox_target option, IsPartnered()/GetPartnerServerId(), and RefreshPartnershipStateFromServer() which yields on a server callback to re-sync the local cache before a caller decides Partner Up vs Break Partnership -- the local cache alone can under-report after a reconnect. The radial entry is now wired, in client/radial.lua). Same "no ordering dependency" note as client/combat.lua above -- calls CanShowK9UI()/IsOwnModelK9() from client/main.lua only at CALL time (inside RequestPartnerUp/the ox_target predicate), never at file-load time.
    'client/propattachment.lua', -- R&D (PropAttachments). Also owns the generic AttachPropToOwnPed/DetachAndDeleteProp mechanic that client/bonetool.lua and client/fetch.lua both reuse rather than hand-rolling a third copy.
    'client/leashvisual.lua',    -- Makes the leash mechanic (client/movement.lua, server/main.lua) actually visible: a rendered rope between handler and K9 for the whole leash duration, plus a leash-handle prop on the handler's own hand. Loaded AFTER client/propattachment.lua deliberately, same "reuses that file's AttachPropToOwnPed/DetachAndDeleteProp rather than hand-rolling a third prop-attach copy" reasoning as client/fetch.lua's own placement note directly below -- no hard load-order requirement either (global-function resolution is at CALL time, not load time, per every other file's note in this list), kept here purely for consistency with that established convention. Adds no new event to client/movement.lua's or server/main.lua's contract -- it registers its OWN second handler for the SAME 'john-k9:client:leashAttached'/'john-k9:client:leashDetached' events client/movement.lua already handles (RegisterNetEvent supports multiple independent handlers per event name), and introduces this resource's first entity-scoped statebag (read: client/leashvisual.lua's own header "BYSTANDER VISIBILITY" section) so a rope is visible to nearby bystanders too, not just the two leash participants -- entirely self-contained; neither movement.lua nor server/main.lua was touched.
    'client/bonetool.lua',       -- Dev-only bone-index sweep (BoneSweepDevTool). Placed here for topical grouping only; calls propattachment's globals at runtime, so no load-order requirement.
    'client/fetch.lua',          -- FetchMechanic. Loaded AFTER client/propattachment.lua deliberately: it reuses that file's AttachPropToOwnPed/DetachAndDeleteProp rather than hand-rolling a third prop-attach copy. An earlier note here claimed this ordering was a HARD REQUIREMENT because the two globals are only defined inside propattachment's feature gate, making the flags coupled. THAT IS WRONG and is corrected here rather than left standing: AttachPropToOwnPed and DetachAndDeleteProp are defined at propattachment.lua:78 and :134, UNCONDITIONALLY -- the first real `Config.Features.PropAttachments` gate check in that file is at :238, well after both (line :174 is only a comment, not a gate), and that file's own header states plainly that neither function is gated. So the globals exist whenever the file loads, regardless of the flag. It IS true that client/fetch.lua calls them without a type() guard, so the load ORDER above still matters; the flags are NOT coupled and no nil-global call is reachable. Note what this feature is NOT -- the K9 does not walk the ball back on its own; it cannot, because the K9 is a connected player's character and nothing here scripts a player's ped movement. The return leg is a real, server-validated player action.
    'client/screenfx.lua', -- ContrabandScreenFX. Held out of this manifest until its two timecycle natives were verified against primary source (no native is allowlisted here on an unverified assertion); both are now confirmed client-only. Registers its OWN handler for john-k9:client:applyContrabandScreenFx rather than extending client/search.lua -- an additional consumer, the same pattern server/wellbeing.lua and server/tracking.lua use for relayDamageEvent. No load-order dependency.
    'client/audio.lua', -- The NUI audio bridge, and it is LIVE: client/main.lua's PlaySoundOnNetworkEntity calls PlayK9Sound() (guarded with type()), and all five sound keys this bridge can request now ship and are listed in this manifest's files{} block (see html/sounds/CREDITS.md for provenance and licensing). A key with no file degrades to a silent no-op end to end, which looks exactly like the feature being off -- so keep that list complete.
    'client/proximityaudio.lua', -- ProximityAudioFX. Distance-scaled gain over client/audio.lua's NUI bridge, so it loads after it. Registers no net-event handlers at all -- confirmed the forged-event class does not apply. Its sound, growl_ambient.ogg, now ships (Config.ProximityAudioFX.soundName -> ToAudioFileKey's lowercase fallback, not the SOUND_NAME_TO_FILE_KEY map).
    -- Owner-directed "combat should be keybinds, not third-eye" feature.
    -- Adds RegisterCommand+RegisterKeyMapping pairs for the fast,
    -- in-the-moment K9 actions that previously had NEITHER
    -- (client/combat.lua's BiteAndHold/NonLethalTakedown/PropDragging were
    -- radial-only), plus Sit/Bark (the owner's own named fast-action
    -- examples). SOFT dependency only -- every cross-file call is behind
    -- this resource's standard `type(fn) == 'function'` guard, not a
    -- load-order assumption (see that file's own header).
    'client/keybinds.lua',
    'client/equipmentshop.lua', -- K9 Supply shop walk-up (DEVELOPER_REFERENCE.md Part B §6) -- the client half of server/equipmentshop.lua. Adds the ox_target marker ox_inventory's own RegisterShop does not create, then hands off to exports.ox_inventory:openInventory('shop', ...). Every price/permission decision stays inside ox_inventory's own server-side shop code; this file only opens the UI. No load-order dependency.
    'client/exports.lua', -- Public client-side export surface. No load-order dependency: every wrapped function is reached through a `type(fn) == 'function'` guard plus pcall, so an export over a file that early-returns under its own feature flag returns a documented nil/false rather than erroring.
    'client/commandsuggestions.lua', -- NEW FILE -- chat:addSuggestion for every RegisterCommand this resource registers (fresh-install finding: zero chat:addSuggestion calls existed anywhere in this resource before this file). No load-order dependency at all: reads only Config (already loaded via shared_scripts) and fires a purely local TriggerEvent at its own onResourceStart, calling no other client file's globals. Placed last purely because it has nothing to be ordered against, same reasoning as client/exports.lua immediately above it.
    -- The client half of /k9debug (server/diagnostics.lua owns
    -- the command itself). Reads Config.DebugDump.enabled directly
    -- (shared_scripts, already loaded) and, only while that is true, sends
    -- a small, periodic self-report of client-only facts (ped health,
    -- ragdoll/vehicle/NUI-focus state) the server cannot observe on its
    -- own -- see that file's own header. No load-order dependency: calls
    -- no other client file's globals, only real natives and
    -- TriggerServerEvent.
    'client/diagnostics.lua',
}

server_scripts {
    '@oxmysql/lib/MySQL.lua',
    -- Database accessor layer -- the switch behind Config.Database.enabled.
    -- Every other server file reads and writes this resource's persistent
    -- state through K9Store.* rather than calling MySQL.* or naming a k9_*
    -- table itself. Loaded FIRST among this resource's own files: it has no
    -- dependency of its own, and every file below it is a consumer.
    'server/datastore.lua',
    -- DEVELOPER_REFERENCE.md item 1: shared cooldown/mutex helper (NewCooldown/
    -- NewNestedCooldown/NewMutex), loaded FIRST among this resource's own
    -- files since main.lua/certifications.lua/tracking.lua/search.lua all
    -- call these resource-global constructors at their own file-load time.
    'server/cooldowns.lua',
    -- Live feature control (Config.Features.RuntimeFeatureControl). Loaded
    -- immediately after cooldowns.lua for two reasons, both hard: it calls
    -- NewCooldown at its own file-load time, and it must run BEFORE every
    -- feature file whose gate is evaluated at onResourceStart, so a
    -- persisted override from the tablet is already applied by the time
    -- those files read Config.Features. Later in this list and a toggle
    -- would silently not survive a restart.
    'server/runtimecontrol.lua',
    -- DEVELOPER_REFERENCE.md near-term item 2: shared defensive netId->entity
    -- resolver (ResolveNetworkEntity), loaded alongside cooldowns.lua and
    -- before main.lua/search.lua, its two consumers.
    'server/entities.lua',
    -- EXCLUSIVE BODY-CLAIM REGISTRY (kennel-vs-vehicle-seat race fix pass,
    -- coder-backend) -- ClaimBody/ReleaseBody/IsBodyClaimedByOther, the
    -- single shared seam server/kennel.lua (kennel_rest),
    -- server/vehicle.lua (vehicle_seat), and server/combat.lua
    -- (combat_target) each now consult before committing an exclusive claim
    -- on a citizenid's own body, closing a real, demonstrated race between
    -- "Rest in Kennel" and "Enter Vehicle" -- see that file's own header for
    -- the full writeup, including why the leash is deliberately NOT one of
    -- this registry's participants. Placed alongside server/entities.lua,
    -- the resource's other citizenid/netId cross-feature claim registry,
    -- for the identical "shared primitive, grouped together" reasoning that
    -- file's own placement comment gives -- no file-load-time call of its
    -- own (every consumer reaches it only from inside a RegisterNetEvent
    -- handler), so this ordering is thematic, not a hard requirement,
    -- exactly like server/entities.lua immediately above it.
    'server/bodyclaims.lua',
    -- Shared ox_lib notify wrapper (NotifyPlayer). Extracted after this
    -- pattern turned up hand-rolled 12 separate times across server files --
    -- with real drift already visible between copies -- while the roadmap
    -- recorded it as "2 copies, closed". Loaded early alongside cooldowns.lua
    -- and entities.lua, the resource's other shared-helper files, since its
    -- consumers span nearly every server file below.
    'server/notify.lua',
    -- Shared outbound-event helper (FireOutboundEvent). Extracted after this
    -- exact five-line pcall(TriggerEvent, ...) wrapper was found hand-rolled
    -- SIX separate times, byte-for-byte identical, across
    -- certifications.lua, search.lua, partnership.lua,
    -- progression.lua and integrations.lua. These fire the documented
    -- john-k9:events:* public contract, so the risk was never untidiness
    -- -- it was someone improving one copy and not the other five, leaving a
    -- subset of the fourteen events quietly off-contract with nothing to
    -- catch it. Same consolidation, and same reasoning, as NotifyPlayer's
    -- twelve copies becoming server/notify.lua above.
    -- Not a hard load-order requirement (every call site is inside a runtime
    -- handler, verified per site, never at file-load time), but kept in the
    -- shared-primitive position alongside cooldowns/entities/notify.
    'server/events.lua',
    -- PD high command (Config.Features.HighCommand). Grouped with the shared
    -- helpers above rather than with the feature files below, because it is
    -- one: it exposes IsHighCommand(), which server/admin.lua,
    -- server/certifications/ and server/bonetool.lua all consult so high
    -- command bypasses their own rank gates. Loading it before its consumers
    -- is a consistency choice, not a hard requirement -- every consumer
    -- guards the call with type(fn) == 'function', this resource's standard
    -- soft-dependency convention, so they still work with the feature off.
    -- It also owns /k9givexp and AwardXPDirect, the ONLY path in this
    -- resource that mints a caller-specified XP amount. server/progression's
    -- AwardXP deliberately takes a config-owned actionKey instead, so that
    -- no ordinary caller can name an amount; this one is bounded by
    -- Config.HighCommand.maxXpPerGrant and audited on every use.
    'server/highcommand.lua',
    -- Grantable permissions (Config.Features.PermissionGrants). Grouped with
    -- the shared helpers for the same reason highcommand.lua is: it exposes
    -- HasPermission(), which other server files consult behind the usual
    -- type(fn) == 'function' guard. Loaded after highcommand.lua because a
    -- permission check falls through to a high-command check when no grant
    -- exists; again a consistency choice, not a hard requirement, since the
    -- lookup happens at call time.
    -- Owns the k9_permissions table: both the four admin capabilities and
    -- the per-person feature grants and blocks, which share that table keyed
    -- feature.<Name> and block.<Name> so they inherit its audit trail and
    -- its one-active-row-per-key guarantee for free.
    -- K9 ROLE / PED ASSIGNMENT. This is what makes "everything works with
    -- any ped" true: the K9 role is a stored assignment, not a model
    -- lookup, so a role-holder on a custom streamed ped, a ped absent from
    -- Config.Peds, or a plain human model still gets K9 features. Exposes
    -- HasK9Role/GetAssignedK9Model/ApplyK9PedRole/ApplyK9AppearanceOnGrant/
    -- MaybeRevertK9Appearance.
    -- HARD load-order requirement on server/cooldowns.lua: NewCooldown is
    -- called at this file's own file-load time (line 230), not lazily.
    -- Placed before server/permissions.lua because that file calls two of
    -- these functions -- through a type(fn) == 'function' guard, so it is a
    -- soft dependency, but there is no reason to make the guard do that job.
    'server/appearance.lua',
    -- MANA_POLICEDOGS FEATURE-PARITY PASS -- an EXPLICIT, admin-pinned
    -- "this citizenid is a dog" record (`k9_dog_characters`, migration
    -- 0019), independent of any certification/permission credential --
    -- see this file's own header for the full precedence writeup against
    -- server/appearance.lua's existing certification-driven appearance.
    -- Exposes IsPinnedDogCharacter/GetPinnedDogCharacterModel/
    -- SetDogCharacter/RemoveDogCharacter, and the '/k9setdog'/
    -- '/k9removedog' admin commands.
    -- HARD load-order requirement on server/cooldowns.lua: NewCooldown is
    -- called at this file's own file-load time. Placed after
    -- server/appearance.lua (soft dependency on that file's
    -- ApplyK9AppearanceDirect/MaybeRevertK9Appearance, both consulted only
    -- at runtime through the usual type(fn) == 'function' guard, so this
    -- is a placement preference grouping it with the file it most directly
    -- extends, not a hard requirement) and after server/highcommand.lua
    -- (IsHighCommand, also a runtime-only soft dependency).
    'server/dogcharacter.lua',
    'server/permissions.lua',
    -- Owner-directed extension of the SAME "add or remove" ask
    -- server/certtiers.lua already answers for certification tiers, this
    -- time for the PERMISSION KEYS themselves (k9.access/k9.certify/
    -- k9.audit/k9.givexp, plus anything added since): high command can now
    -- add, relabel, or tombstone a permission key from the tablet at
    -- runtime, layered over Config.Permissions the same way
    -- k9_certification_tiers layers over Config.CertificationTiers.
    -- Persists via migration 0013. EXTENDS server/permissions.lua's own
    -- IsValidPermissionKey/PermissionLabelFor seam (that file's own updated
    -- doc comments) rather than replacing them, and additionally shares a
    -- cross-file mutex with that file's GrantPermission the same way
    -- server/certtiers.lua's TierEditMutex is shared with
    -- server/certifications/'s SetCertificationTier. Placed immediately
    -- after server/permissions.lua for the same "group with the file it
    -- most directly extends" reason server/certtiers.lua sits immediately
    -- after server/certifications/ below -- not a hard requirement,
    -- since every cross-file call in either direction is guarded by
    -- `type(...) == 'function'`/`type(...) == 'table'` and reached only at
    -- runtime, by which point every server_scripts file has already
    -- loaded. HARD load-order requirement on server/cooldowns.lua only:
    -- NewCooldown/NewMutex are called at this file's own file-load time.
    'server/permissionkeycatalog.lua',
    'server/main.lua',
    -- SPLIT 2026-09-02 (was one 6,012-line server/certifications/ doing
    -- four jobs). ORDER IS LOAD-BEARING: each file publishes what the later
    -- ones need onto the shared K9Cert transport at its end, and each later
    -- file re-binds those names as locals at its top -- so a file loaded out
    -- of order would re-bind nil and every call through it would fail. The
    -- dependency flow is strictly one-way, which is what made the split
    -- safe; see any of the four files' own headers for the full writeup.
    'server/certifications/core.lua',        -- records, cache, K9 access, grant/revoke
    'server/certifications/depth.lua',       -- tier ladder, renewal/expiry, specializations
    'server/certifications/accessors.lua',   -- the read-only public accessors
    'server/certifications/commands.lua',    -- commands, tablet callbacks, expiry sweeps
    -- Owner-directed reversal of an earlier design decision. Certification
    -- tiers were a hardcoded 3-step ordinal, argued for on the grounds that
    -- an operator could hold the model in their head. The owner asked for
    -- the opposite -- add tiers, rename them, edit what they grant, from
    -- the tablet, at runtime -- so the catalogue is now data. Persists via
    -- migration 0010. EXTENDS server/certifications/'s existing tier
    -- accessors rather than replacing them; the three shipped keys must
    -- keep their names, since every certification row already in a live
    -- database holds one of them. No hard load-order requirement -- every
    -- function here is called at event time, never at file load.
    'server/certtiers.lua',
    'server/roles.lua',     -- K9 roles: tiers and specializations merged into one catalog high command edits on the tablet (label, XP needed, unlocks), overlaid on Config.K9Specializations and saved in k9_roles. NewCooldown at file-load time (after server/cooldowns.lua); K9Store/HasSpecialization/GetXP at run time only.
    -- K9 COMMAND TABLET, server half. This is high command's actual control
    -- surface: the roster read side, plus tabletAssignK9Role and
    -- tabletRevertK9Ped -- assigning someone the K9 role and stripping it
    -- back to a human. It was written and never registered, so every one of
    -- those callbacks silently never answered. Loaded after
    -- server/permissions.lua and server/certifications/, whose
    -- IsHighCommand/HasPermission/HasK9Access it consults (21 call sites,
    -- all at runtime, so this is convention rather than a hard requirement).
    'server/tablet.lua',
    -- K9 COMMAND TABLET ROSTERS, server half (docs/history/ROSTER_SPEC.md, Phase A --
    -- data layer + server logic only; the UI/entry-point work is a
    -- separate, later pass). Two roster LISTS (K9s, Handlers) plus an
    -- explicit "Unassigned" bucket, layered over the certification data
    -- server/tablet.lua/server/certifications/ already own -- NOT a
    -- second person-detail screen (docs/history/ROSTER_SPEC.md §1's "extend
    -- buildPersonScreen(), do not fork it" decision belongs to that later
    -- UI pass; this file only supplies the data/mutations it will consume).
    -- Owns its OWN lib.callback registrations (`john-k9:server:roster*`)
    -- rather than adding them to server/tablet.lua, and its OWN table
    -- (`k9_personnel`, migration 0020) behind K9Store like every other
    -- table in this schema. Gated the same way server/tablet.lua gates
    -- itself -- `Config.Features.CommandTablet` -- reusing that existing
    -- master flag rather than inventing a second one for what is still,
    -- functionally, one feature (the K9 Command Tablet). Loaded
    -- immediately after server/tablet.lua: soft dependencies only
    -- (IsHighCommand from server/highcommand.lua, K9Store from
    -- server/datastore.lua, QueryCertificationRecord/GetXP/GetXPTier from
    -- server/certifications//server/progression.lua, all already loaded
    -- earlier in this list, all reached only at call time behind this
    -- resource's standard `type(...) == 'function'` guard) -- placed here
    -- purely for topical grouping with the other tablet file, not a hard
    -- ordering requirement.
    'server/roster.lua',
    -- HandlerPartnership registry, DEVELOPER_REFERENCE.md §12.0 item 7/§12.3
    -- -- loaded after server/cooldowns.lua (NewCooldown/
    -- NewMutex at this file's own file-load time) and server/certifications/
    -- (IsConfiguredK9Model/HasK9Access reuse at runtime inside the
    -- eligibility check below). Per this file's own header note: loaded
    -- AFTER certifications.lua even though certifications.lua's
    -- RevokeCertification/RevokeCertificationOffline/OnJobUpdate call INTO
    -- this file's ForceBreakPartnershipForCitizenId -- same "runtime
    -- existence guard, not a load-order assumption" convention as every
    -- other soft cross-file dependency in this manifest (see this file's
    -- own comment on server/search.lua's AwardXP reuse below); those
    -- four call sites (confirmed as four, not the three an earlier revision
    -- of this comment claimed) guard the call with a `type(...) == 'function'`
    -- check rather than assuming load order, since by the time any of them
    -- can actually FIRE (a real player action), every server_scripts file
    -- below has already finished loading regardless of manifest order.
    'server/partnership.lua',
    'server/warrants.lua',  -- The K9's sniff checks sc-dispatch's MDT for arrest/bench warrants and tells the dog and its partner (information only), plus the one optional wanted gate (IsPlayerK9Wanted, off by default) server/combat.lua and server/pursuitsprint.lua call. No file-load-time dependencies.
    'server/tracking.lua',
    'server/pursuitsprint.lua', -- PROJECT_HISTORY.md §5 (PursuitSprint), server half. HARD load-order dependency on server/cooldowns.lua (NewCooldown at file-load time). Also holds the only correct implementation of the four-step per-person FeatureControl resolution -- read it before writing a second one anywhere else.
    'server/search.lua',
    'server/findalert.lua', -- PROJECT_HISTORY.md §1 (FindAlerts), server half. An ADDITIONAL consumer of server/search.lua's searchCompleted and client/tracking.lua's reportTrackSourceArrival events -- it adds no detection logic of its own, which is why it needs no ordering against either. It DOES call NewCooldown at its own file-load time, so server/cooldowns.lua before it is a hard requirement; HasK9Access is runtime-only.
    'server/inventory.lua', -- K9Inventory, DEVELOPER_REFERENCE.md §13.4.2
    'server/kennel.lua',    -- R&D (DeployableKennel, DEVELOPER_REFERENCE.md#phase-5-research §5) -- loaded after cooldowns.lua (NewCooldown at file-load time) and certifications.lua (HasK9Access)
    'server/vehicle.lua',   -- SEAT-RACE FIX (NEW FILE) -- server-side seat claim for client/vehicle.lua's VehicleEntryExit, closing the one paired mechanic left client-authoritative (see that file's own header for the concurrency audit finding). No file-load-time dependency of its own beyond Config/GetHashKey (both already available via shared_scripts); HasK9Access/ResolveNetworkEntity/NotifyPlayer are consulted only at RUN time, inside its RegisterNetEvent handlers, so placement here is purely thematic (grouped with server/kennel.lua, the other paired-mechanic file its own design most directly mirrors), not a hard ordering requirement.
    'server/medkit.lua',    -- K9Medkit, DEVELOPER_REFERENCE.md §13.4.4 -- loaded after cooldowns.lua (NewCooldown/NewMutex at file-load time) and certifications.lua (IsConfiguredK9Model). It has no ordering dependency on server/progression.lua either: AwardHandlerXP is called through a runtime existence guard, not a load-order assumption
    -- Unified wellbeing subsystem, DEVELOPER_REFERENCE.md §13.0 Decision 1 --
    -- loaded after cooldowns.lua (NewCooldown at file-load time) and
    -- certifications.lua (HasK9Access). Deliberately loaded AFTER
    -- server/tracking.lua: both register a handler for the same
    -- relayDamageEvent/relayWeaponFire client events (FiveM fires every
    -- registered handler, so this is an additional CONSUMER of an existing
    -- signal, not a replacement -- DEVELOPER_REFERENCE.md §13.0's own "a new
    -- consumer, not a new detection mechanism" framing), and each keeps its
    -- own independent rate limit.
    'server/wellbeing.lua',
    -- XPProgression, DEVELOPER_REFERENCE.md §13.4.1 -- loaded after
    -- tracking.lua/search.lua, which call AwardXP/GetXPTier through runtime
    -- existence guards rather than a load-order assumption.
    'server/progression.lua',
    -- Owner-directed "set experience level for each rank up" feature. A DB-
    -- backed overlay over Config.XPTiers, high-command-editable from the
    -- tablet at runtime -- see this file's own header for the full design,
    -- including why it mutates Config.XPTiers[ordinal] IN PLACE rather
    -- than adding a second merged-catalog structure (zero footprint on
    -- server/progression.lua itself, verified by this file's own header:
    -- that file is not edited by this addition at all). Loaded after
    -- server/cooldowns.lua (NewCooldown/NewMutex at file-load time),
    -- server/highcommand.lua (IsHighCommand, called at runtime through a
    -- soft-dependency guard, not a load-order assumption), and
    -- server/datastore.lua (K9Store.XPTier_*). Loaded after
    -- server/progression.lua for readability only (both files' own
    -- onResourceStart handlers are independent and do not depend on each
    -- other's relative firing order -- see this file's own header,
    -- "WHY IN-PLACE MUTATION").
    'server/xptiers.lua',
    -- Owner-directed "god over that tablet, full customization over
    -- everything related to that K9" feature -- the per-INDIVIDUAL-K9
    -- override half (server/xptiers.lua immediately above already covers
    -- the per-RANK half; see this file's own header for the full "what
    -- already existed" writeup and the explicit GLOBAL DEFAULT -> XP TIER
    -- -> INDIVIDUAL OVERRIDE resolution order). Persists via migration
    -- 0016. Loaded after server/cooldowns.lua (NewCooldown/NewMutex at
    -- file-load time), server/highcommand.lua (IsHighCommand, runtime-only
    -- soft dependency), server/datastore.lua (K9Store.Override_*), and
    -- server/progression.lua/server/xptiers.lua (GetXPTier, runtime-only
    -- soft dependency -- see this file's own "INTEGRATION HANDOFF" section
    -- for why nothing here actually calls it eagerly at load time either).
    'server/k9profiles.lua',
    -- BiteAndHold/NonLethalTakedown, DEVELOPER_REFERENCE.md §12.5.1/
    -- §12.5.2/§12.0 item 8 -- loaded after cooldowns.lua (NewCooldown/
    -- NewMutex at file-load time, per this file's own header) and
    -- entities.lua/certifications.lua (ResolveNetworkEntity/HasK9Access,
    -- called at runtime, but kept load-ordered before this file for the
    -- same reason every other consumer of those two already is).
    -- Deliberately loaded AFTER server/progression.lua even though it
    -- CONSUMES AwardXP from it -- same "runtime existence guard, not a
    -- load-order assumption" convention every other soft cross-file
    -- dependency in this manifest already follows; loading after it simply
    -- means that guard is non-nil from this file's very first tick rather
    -- than only after a resource restart, not a correctness requirement.
    'server/combat.lua',
    'server/propattachment.lua',
    'server/bonetool.lua',
    -- FetchMechanic server half. Loaded after cooldowns.lua
    -- (NewCooldown at file-load time -- hard requirement), entities.lua and
    -- certifications.lua. Never trusts a bare netId: every pickup/deliver
    -- request is resolved through ResolveNetworkEntity, model-checked against
    -- an allowlist, and cross-checked for equality against the server's own
    -- tracked ball. Every ball carries an absolute lifetime ceiling
    -- independent of any activity path, so none can outlive its cycle.
    'server/fetch.lua',
    -- Partnership-tenure milestone XP bonus (Config.Features.PartnershipTenureBonus,
    -- DEVELOPER_REFERENCE.md Part B item 7) -- the first gameplay consequence
    -- wired to the HandlerPartnership registry, which landed as a
    -- foundation with none. Extends partnership.lua/progression.lua through
    -- their already-exposed accessors; no load-order dependency on either.
    -- REQUIRES k9_partnerships.tenure_bonus_tier_granted (sql/install.sql
    -- for fresh installs, sql/migrations/0003_*.sql for existing ones);
    -- without it the milestone would re-grant on every restart, so its
    -- queries are pcall-wrapped and go inert rather than misbehaving.
    'server/tenure.lua',
    -- Read-only, POLICE-JOB-RANK-gated audit surface over the three tables this
    -- resource writes. Loaded after cooldowns.lua (NewCooldown at file-load
    -- time); deliberately does NOT call into certifications.lua or
    -- partnership.lua -- see its own ACCESS MODEL header.
    -- Training Mode server half (DEVELOPER_REFERENCE.md Part A Tier B §6). HARD
    -- load-order requirement on server/cooldowns.lua: it calls NewCooldown()
    -- at THIS FILE'S OWN file-load time (twice -- ToggleCooldown and
    -- ActionCooldown), not lazily inside a handler, so cooldowns.lua being
    -- later in this list is a nil-call at start, not a degraded feature.
    -- HasK9Access (server/certifications/) is reached at runtime through a
    -- type(fn) == 'function' guard that fails CLOSED, so that one is a soft
    -- dependency; it is still listed after certifications.lua so the guard
    -- never actually has to do that job. Mints ZERO XP by construction and
    -- must stay that way -- a training dummy has less friction than any of
    -- the four real mechanics, so any award here would be reachable faster
    -- than the compound farm server/progression.lua's mint budget closed.
    -- /k9stats leaderboard (Config.Features.K9Leaderboard). Load-order:
    -- after server/cooldowns.lua, a HARD requirement whenever the feature
    -- flag is on -- it calls NewCooldown() at this file's own file-load
    -- time, immediately past its feature gate, not lazily inside the
    -- command handler. Also after server/certifications/, since
    -- HasK9Access(source) is the only gate on the command. Reads
    -- k9_progression through the idx_xp index added by SQL migration 0009;
    -- without that index the query is a full table scan plus a filesort on
    -- every engine, so do not remove it.
    'server/leaderboard.lua',
    -- K9 Supply shop registration (DEVELOPER_REFERENCE.md Part B §6). Sells the
    -- item names this codebase already invented as documented placeholders
    -- with nowhere to buy them (k9_medkit / k9_treat / k9_meat_bait /
    -- k9_ultrasonic_whistle) -- it finishes a half-built loop rather than
    -- opening a new one. No load-order dependency (no NewCooldown/NewMutex at
    -- file-load time); the whole ox_inventory RegisterShop call is wrapped in
    -- pcall so an older/different RegisterShop shape degrades to one console
    -- line instead of failing resource start.
    'server/equipmentshop.lua',
    'server/admin.lua',
    -- Public server-side export surface -- this resource's first exports.
    -- Self-registers via the runtime `exports('name', fn)` call, so no
    -- `server_exports` manifest key is needed. Loaded last so every wrapped
    -- internal function is already defined, though each call is guarded
    -- anyway.
    -- External-system integration surface. Fires 'john-k9:events:k9Down'
    -- from a self-contained health-poll thread. Loaded after cooldowns.lua
    -- (NewCooldown at file-load time) and certifications.lua (HasK9Access
    -- and IsConfiguredK9Model, called at runtime).
    'server/integrations.lua',
    -- Discord webhook logging (Config.Features.DiscordWebhook, ships
    -- `false`) -- a pure LISTENER on the already-documented
    -- `john-k9:events:*` contract server/exports.lua's own EVENT
    -- CONTRACT section documents; it fires nothing new and touches no
    -- other file. HARD load-order requirement on server/cooldowns.lua:
    -- calls NewCooldown() at this file's own file-load time, immediately
    -- past its own feature/URL gates. No dependency on server/events.lua
    -- (that file's FireOutboundEvent is only what OTHER files call to
    -- fire these events in the first place; this file only ever
    -- AddEventHandler's on the event NAMES themselves, which works
    -- regardless of load order the same way any other resource's own
    -- listener would). Loaded after server/integrations.lua purely for
    -- topical grouping (both are "external-system integration surface"
    -- files) -- no functional dependency between the two.
    'server/webhook.lua',
    'server/exports.lua',
    -- EVERY server-side diagnostic, in one file: the boot self-checks that
    -- warn at startup AND the `/k9debug` command (Config.DebugDump, ships
    -- off) that reports them on demand.
    -- HARD load-order requirement: loaded absolute LAST among this
    -- resource's own server_scripts, on purpose -- the dump half re-surfaces
    -- checks from server/datastore.lua (K9Store) and from this same file's
    -- own self-check half, and (at Config.DebugDump.level = 'verbose' only)
    -- wraps the real global HasK9Access/IsHighCommand/HasPermission
    -- functions defined in server/certifications//server/highcommand.lua/
    -- server/permissions.lua respectively -- every one of those must already
    -- be the REAL function, not a stub, at the moment this file's own
    -- top-level code runs. See that file's own header for the full design.
    'server/diagnostics.lua', -- EVERY diagnostic in one file (merged 2026-09-02 from server/selfcheck.lua + server/debugdump.lua). Loaded LAST for the same reason selfcheck was: it only ever WARNS, never blocks, and its database-state clause waits on K9Store.WaitForSchemaCheckToSettle() rather than racing it -- so this placement is about reading everything else last, not a load-order requirement of its own.
}

lua54 'yes'
-- OAL = "One Argument List", an experimental change to the Lua native-calling
-- convention -- NOT an object/asset loader, which is what a release review
-- initially assumed and flagged as risky to ship. Under it, natives no longer
-- auto-unpack a vector3 into x, y, z.
--
-- KEPT DELIBERATELY, after checking rather than assuming. qbx_core, ox_lib,
-- ox_target and ox_inventory all set this flag in their own live main-branch
-- manifests (verified Aug 2026), so a server running this resource already
-- needs a build supporting fxv2 OAL regardless of what we set here. Dropping
-- it would reduce this resource's real exposure by nothing.
--
-- This resource's own calls are already OAL-safe: every coordinate-taking
-- native is passed manually unpacked x/y/z, never a bare vector3. The one
-- GetShapeTestResult call (client/agility.lua's vault sweep -- moved there
-- from client/movement.lua) reads only
-- resultCode and hit -- never endCoords or surfaceNormal, the exact vector
-- returns reported broken by lua54 + fxv2_oal together on some builds.
-- If a future call here needs to read a shape-test or raycast vector result,
-- re-verify that known issue against the build in use FIRST.
use_experimental_fxv2_oal 'yes'
