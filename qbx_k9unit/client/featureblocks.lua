--[[
    qbx_k9unit/client/featureblocks.lua

    THE PROBLEM THIS FILE EXISTS TO CLOSE: the owner's own words, restated
    directly -- "the high command tablet be able to turn on and off all
    features for everyone or per person." 29 features already honour a
    per-person block (server/permissions.lua's `HasPermission(citizenid,
    'block.<Name>')`, checked inside each feature's own server-side handler
    at the point it acts). Twelve cannot, at all, because they are purely
    client-rendered/client-local and have NO server-side registration point
    a block could ever be checked from -- confirmed by grep across every
    server/*.lua file, not assumed from the name:
        RadialMenu, AgilityBasicJump, AgilityAdvanced,
        ThermalVision, NightVision, HealthStaminaHUD, ContrabandScreenFX,
        AdvancedBarkRadial, ProximityAudioFX, WaterTrackingDecay,
        CameraFeedPiP
    (VehicleEntryExit was the twelfth and is no longer one of them -- see
    CLIENT_ENFORCED_FEATURES below for why it moved.)
    server/runtimecontrol.lua's own FEATURE_TIERS table already documents
    exactly this list under `tier = 'clientonly'`, for the SAME underlying
    reason (no server-side point to toggle from) applied to the GLOBAL
    on/off question rather than the per-person one this file answers.

    ======================================================================
    THE HONEST LIMIT, STATED PLAINLY, ONCE, HERE -- read this before relying
    on anything below: THE CLIENT CANNOT BE TRUSTED TO POLICE ITSELF. Every
    check this file's own IsK9FeatureBlocked() answers is a check the SAME
    modified client that hosts it could always choose to skip -- there is no
    client-side trick that changes that. This is not a reason to skip
    building it: it is a reason to be precise about what it buys. What it
    DOES do: it makes the block genuinely work for every ordinary,
    unmodified client, exactly like every other client-side check this
    resource already ships and already trusts for the identical reason --
    IsOwnModelK9() (client/main.lua), the CanShowK9UI() gate every radial
    item already relies on, DenyK9UIAccess() itself. None of those are
    "real" security boundaries either; all of them are already load-bearing
    UX/policy gates this codebase treats as legitimate. This file is the
    twelve-feature extension of that SAME already-accepted trust model, not
    a new, weaker one. What it does NOT do, and cannot be made to do from
    the client side no matter how it is written: stop a genuinely modified
    client (memory-patched, a forged local event, a rewritten Lua chunk
    loaded in place of this file) from ignoring a block entirely. That gap
    is structural to every client-side check in this resource, not specific
    to this file, and is reported as such rather than glossed over.

    ======================================================================
    ONE MECHANISM, NOT TWELVE. These twelve features live across eight
    client files: client/vision.lua (x3), client/hud.lua, client/screenfx.lua,
    client/radial.lua (x3), client/agility.lua, client/proximityaudio.lua,
    client/vehicle.lua, client/movement.lua (AgilityBasicJump's suppression
    thread), and client/tracking.lua (WaterTrackingDecay's water-crossing
    check). Every one of those eight call sites reads the SAME shared
    predicate below, fed by the SAME single server push, rather than each
    inventing its own poll/cache/event -- twelve independent mechanisms
    answering the same question slightly differently is exactly how the
    per-person gap this file closes was allowed to open in the first place.

    ======================================================================
    HOW THE CLIENT LEARNS IT IS BLOCKED -- PUSH, NOT POLL. The SERVER
    already knows (server/permissions.lua's `k9_permissions` table is the
    single source of truth for every 'block.<Name>' row); this file never
    re-derives that answer itself, it only caches whatever the server most
    recently pushed. Two triggers, both server-owned (implemented in
    server/permissions.lua):
      1. ON JOIN / RECONNECT -- once, right after this citizenid's
         permission cache is warmed server-side (server/permissions.lua's
         own 'QBCore:Server:PlayerLoaded' warmup is the natural hook).
      2. ON CHANGE -- every time a high-command tablet action grants or
         revokes a 'block.<Name>' permission row for one of the twelve keys
         above, for a target who is currently online, mirroring
         server/runtimecontrol.lua's own "BROADCAST ON CHANGE" precedent for
         `qbx_k9unit:client:themeUpdated` exactly (full current state sent
         again, never a delta -- see that file's header PART 2 for why a
         delta is not this resource's convention for a small, infrequently-
         changing set).

    FAILING SAFE ON UNKNOWN STATE -- THE DIRECTION MATTERS. Until the first
    sync arrives (a fresh connection, a resource restart, or simply because
    the server-side push above has not been implemented yet at all), this
    file's own block set below is EMPTY, and an empty set means "nothing is
    blocked" -- fails OPEN, never closed. This is the ONLY safe direction:
    every existing install has zero rows in the 'block.<Name>' namespace
    today, so "briefly unknown" must read exactly like "definitely not
    blocked," not like "definitely blocked" -- the latter would freeze
    someone's night vision/radial/vault/etc. the instant they load in, for
    a condition that is not even true, on every single server running this
    resource, until the day the server-side half of this contract ships.
    Consequently: IsK9FeatureBlocked() below can NEVER error and can NEVER
    default to true for an unrecognised or not-yet-synced key -- every
    return path is a plain boolean read of an in-memory table with a
    `== true` comparison, never a bare truthy check, never a pcall, never a
    network round trip.

    ======================================================================
    WHERE THE CHECK GOES, PER CALLER (this file does not decide this --
    each owning file does, at its own call site; recorded here only as a
    cross-reference so a future reader does not have to grep for it):
    client/vision.lua, client/hud.lua, client/screenfx.lua,
    client/agility.lua, client/proximityaudio.lua and client/vehicle.lua
    each check IsK9FeatureBlocked() at the point the ability ACTS (a
    toggle's "turning on" branch, a one-shot action's own existing
    CanShowK9UI() gate, a continuous poll/maintenance thread's own per-tick
    condition) -- NEVER merely at registration, and NEVER on a
    termination/release/detach/stop branch (see the next section).
    Client/movement.lua's and client/tracking.lua's own call sites follow
    the identical rule -- both are ALREADY-LIVE per-tick/per-frame checks,
    so adding this predicate to their existing condition is what makes a
    live block take effect on an ALREADY-ACTIVE effect (an ongoing
    night-vision view, an in-progress scent trail) within one polling
    interval of that check, not merely block the NEXT attempt to turn it
    on -- satisfying the "a block applied while someone is already using it
    should take effect" requirement without this file needing a second,
    bespoke push-triggered teardown mechanism of its own.

    client/radial.lua is the ONE exception to "check at the point it acts,
    never at registration" -- and deliberately so, not an inconsistency:
    RadialMenu and AdvancedBarkRadial are themselves about client-side
    REGISTRATION STRUCTURE (does the K9 Unit wheel exist at all for this
    client; does its Bark entry expand into a variant submenu or stay a
    single item), not about a single ability's own point-of-use. That file
    already re-derives its ENTIRE menu tree from scratch on every
    RegisterK9RadialMenu() call, and its own header independently verifies
    (against ox_lib's real source) that repeating those registrations
    REPLACES them in place rather than duplicating anything -- so the
    correct, safe way to make THOSE two block per-person is to make that
    rebuild ALSO consult IsK9FeatureBlocked(), and to re-run the rebuild
    whenever a block changes (this file's own `qbx_k9unit:client:
    featureBlocksApplied` local re-broadcast above exists specifically for
    that one consumer). Every OTHER ability reachable through the radial
    (Sit, Bark itself, Leash, Track, Bite & Hold, Vehicle, etc.) is
    completely unaffected by a RadialMenu block beyond simply losing that
    ONE entry point -- each keeps working from its own resource-global
    function via every other surface (keybind, command, tablet trigger,
    export) exactly as before, and none of those functions' own
    termination/release branches gained a new check at all.

    NEVER GATE A TERMINATION PATH -- restated here because it is this
    resource's single most-repeated lesson (five separate prior bugs) and
    because IsK9FeatureBlocked() is a NEW tool an editor could reach for at
    the wrong call site: DetachLeash(), ExitK9Vehicle(), StopTracking(),
    ReleaseBiteHold(), ReleaseDrag(), BreakPartnership(), and every other
    release/stop/detach path in this resource stay exactly as ungated as
    they already are. A block on, say, NightVision or
    VehicleEntryExit only ever refuses a NEW turn-on/entry; it is written,
    in every call site here, to never be able to refuse turning the SAME
    thing off or getting back out. This is why the maintenance-thread
    additions in client/vision.lua call the existing
    SetSeethrough(false)/SetNightvision(false)/StopCameraFeed() force-off
    paths when a live block arrives, rather than ever routing a block
    through DenyK9UIAccess()/DenyK9FeatureBlocked() on an exit path -- those
    two notify-and-refuse helpers are for an INITIATION being refused,
    never for an effect being force-ended.

    ======================================================================
    FILE-TO-FILE CONTRACT:
    - THIS FILE exposes two resource-global (no `local`) functions, per
      this resource's established "global helper, private per-file state"
      convention (server/cooldowns.lua/server/certifications/'s own
      header cites this as the pattern; client/main.lua's IsOwnModelK9/
      CanShowK9UI/DenyK9UIAccess are the closest client-side precedent):
        IsK9FeatureBlocked(featureName) -> boolean
        DenyK9FeatureBlocked() -> nil (side effect: one lib.notify call)
      Every caller in another file guards with `type(IsK9FeatureBlocked) ==
      'function'` before calling it (this resource's documented "runtime
      existence guard, not a load-order assumption" convention) -- which
      also means: if this file is ever NOT loaded at all (fxmanifest.lua
      not yet updated, an operator's fork excludes it), every one of the
      twelve features silently behaves as fully unblockable per-person, but
      never erroring and never freezing anyone. That is the correct
      degrade, not a bug to "fix" by removing the guard.
    - THIS FILE requires ZERO new Config.Features entry and reads none --
      it is cross-cutting infrastructure in the same sense
      server/runtimecontrol.lua is (that file's own header: gated on
      nothing itself, so the SEPARATE features it manages can each be
      gated independently), not a feature of its own that could itself be
      switched off.
    - THIS FILE registers exactly one RegisterNetEvent, fired only by the
      server (see TRUST BOUNDARY below) -- it triggers no server event of
      its own, and calls no other file's global.
    - FXMANIFEST PLACEMENT: client/featureblocks.lua loads early in
      client_scripts (before client/movement.lua, client/agility.lua,
      client/radial.lua, client/vehicle.lua, client/tracking.lua,
      client/vision.lua, client/hud.lua, client/screenfx.lua,
      client/audio.lua and client/proximityaudio.lua), since every one of
      those either calls into this file directly or is one of its
      consumers. This file itself depends on nothing else in this resource
      (no call into any other client file, no read of Config beyond
      nothing at all), so there is no lower bound on its own placement
      other than "as early as practical" -- loading it early satisfies
      every consumer's own ordering need in one placement, the same
      reasoning server/runtimecontrol.lua's own header uses for an
      analogous cross-cutting file on the server side.

    TRUST BOUNDARY -- same discipline client/screenfx.lua's own header
    already applies to its `qbx_k9unit:client:applyContrabandScreenFx`
    handler (that file's own "TRUST BOUNDARY" section, read before writing
    this one): `source ~= 65535` is checked first, rejecting a locally
    self-triggered event that did not actually arrive from the server, per
    FiveM's own documented "Secure your events" guidance. Forging this
    specific event could only ever CLEAR a block for the forger's own
    client (never someone else's, since TriggerEvent has no cross-client
    reach) -- a modified client capable of forging a local event is
    already capable of simply patching IsK9FeatureBlocked() to always
    return false without ever touching the network, so this check buys no
    real security here either; it is kept anyway, for the same reason
    client/screenfx.lua kept it for its own net-effect-free case: one line,
    consistent with this resource's own stated convention, rather than an
    unexplained exception to it.

    LOCALE KEYS THIS FILE USES -- ONE key, reused verbatim by every one of
    the twelve features' own denial rather than minting twelve near-identical
    strings (this resource's own established "reuse a key when the English
    matches exactly" convention):
        common.k9_feature_blocked = "High Command has blocked this ability for you."
    Deliberately GENERIC (names no specific feature) -- the tablet is
    already the place an affected person can see WHICH feature and read
    its plain-language block-effect explanation; this notify exists
    only to explain, in the moment, why an action that should have worked
    just silently didn't.
]]

-- Restricted to exactly the twelve features named in this file's own
-- header -- a defensive allowlist, not a trust in whatever array the
-- server happens to send. A key outside this set is dropped silently
-- (never stored, never able to make IsK9FeatureBlocked() answer true for
-- a feature this file was never told to police), so a malformed or
-- future-drifted payload can never accidentally start blocking a
-- server-enforced feature this file has nothing to do with, or a feature
-- name typo'd on either end of this contract.
-- VEHICLEENTRYEXIT WAS IN THIS TABLE AND IS NOT ANY MORE (2026-08-26).
-- It belonged here for as long as vehicle entry was purely client-local,
-- with no server-side registration point a block could ever be checked
-- from. That stopped being true the moment vehicle entry gained a server
-- half: server/vehicle.lua now arbitrates seat claims and checks
-- `block.VehicleEntryExit` itself, per person, before granting one.
--
-- Leaving it here as well would not merely be redundant, it would be a
-- LIE ABOUT WHERE THE BOUNDARY IS -- this file's own header is explicit
-- that a client-enforced block is a courtesy a modified client can simply
-- decline, and listing a now-server-enforced feature alongside the genuinely
-- unenforceable ones invites the next reader to assume the server has it
-- covered for all twelve. The resource's own drift guard
-- (tests/customizationregistry_spec.lua) caught this the moment the tier
-- changed, which is exactly what it is for.
local CLIENT_ENFORCED_FEATURES = {
    RadialMenu = true,
    AgilityBasicJump = true,
    AgilityAdvanced = true,
    ThermalVision = true,
    NightVision = true,
    HealthStaminaHUD = true,
    ContrabandScreenFX = true,
    AdvancedBarkRadial = true,
    ProximityAudioFX = true,
    WaterTrackingDecay = true,
    CameraFeedPiP = true,
}

-- Current known block state -- ClientFeatureBlocks[featureName] = true
-- means "the server most recently told this client it is blocked from
-- this feature." ABSENCE of a key (never a stored `false`) means "not
-- blocked, as far as this client currently knows" -- this is also the
-- correct, safe, fail-OPEN starting value before the first sync ever
-- arrives (see this file's header "FAILING SAFE ON UNKNOWN STATE").
local ClientFeatureBlocks = {}

--- Is `featureName` currently blocked for the LOCAL player, per the most
--- recent server push? Always a plain, synchronous, zero-cost table read
--- -- safe to call every frame from a per-frame maintenance thread (see
--- client/vision.lua's camera-feed thread) as well as from a one-shot
--- action's own initiation gate. Returns `false` (never blocked) for any
--- name this file does not recognise as one of the twelve it polices, and
--- for any recognised name before the first sync has arrived -- both are
--- the SAME "unknown means allowed" answer, per this file's own header.
--- @param featureName string
--- @return boolean
function IsK9FeatureBlocked(featureName)
    return ClientFeatureBlocks[featureName] == true
end

--- Shared denial notify for an INITIATION refused because of a per-person
--- block -- the direct sibling of client/main.lua's own DenyK9UIAccess(),
--- same no-argument shape, same "declare once, reuse everywhere"
--- convention. NEVER call this from a termination/release/detach/stop
--- branch -- see this file's header "NEVER GATE A TERMINATION PATH".
function DenyK9FeatureBlocked()
    lib.notify({ title = locale('common.notify_title'), description = locale('common.k9_feature_blocked'), type = 'error' })
end

-- ======================================================================
-- SERVER SYNC -- see this file's header "HOW THE CLIENT LEARNS IT IS
-- BLOCKED". `blockedKeys` is a plain array of feature-name strings
-- currently blocked for this citizenid (a full replacement of this file's
-- own state every time, never a delta -- see header). Every entry not in
-- CLIENT_ENFORCED_FEATURES above, and every non-string entry, is silently
-- dropped rather than stored.
-- ======================================================================
RegisterNetEvent('qbx_k9unit:client:featureBlocksSync', function(blockedKeys)
    -- TRUST BOUNDARY -- see this file's header. First statement, per
    -- client/screenfx.lua's own established shape for this exact check.
    if source ~= 65535 then return end

    local nextBlocks = {}
    if type(blockedKeys) == 'table' then
        for _, name in ipairs(blockedKeys) do
            if type(name) == 'string' and CLIENT_ENFORCED_FEATURES[name] == true then
                nextBlocks[name] = true
            end
        end
    end
    -- Full reassignment, not a merge -- a feature absent from THIS sync is
    -- authoritatively "not blocked now" (it may have just been unblocked),
    -- never "still blocked from a previous sync this one forgot to repeat".
    ClientFeatureBlocks = nextBlocks

    -- Local (SAME client, same resource -- TriggerEvent, never
    -- TriggerServerEvent/TriggerClientEvent) re-broadcast for a consumer
    -- whose own client-side STRUCTURE depends on block state at
    -- REGISTRATION time, not only at the moment an ability acts --
    -- client/radial.lua is the one consumer (see that file's own "K9 UNIT
    -- RADIAL -- PER-PERSON BLOCK" section): it already rebuilds its entire
    -- menu tree from scratch on every RegisterK9RadialMenu() call, and
    -- that file's own header separately verifies (against ox_lib's actual
    -- source) that re-running its registrations REPLACES them in place
    -- rather than duplicating anything -- so reacting to this event by
    -- simply calling that function again is cheap and safe, not a new
    -- risk. Fired unconditionally on every sync (even one that changed
    -- nothing) -- simpler and safer than diffing old vs. new here, and a
    -- rebuild this infrequent (join, reconnect, or a high-command
    -- block/unblock action) costs nothing worth guarding against.
    TriggerEvent('qbx_k9unit:client:featureBlocksApplied')
end)

-- ======================================================================
-- STARTUP PULL
--
-- The server pushes a fresh block set when a player loads and when high
-- command grants or revokes a block. Neither covers this file's OTHER
-- start case: the client scripts restarting while the server resource
-- keeps running. The server's PlayerLoaded hook does not re-fire for a
-- player who never disconnected, so without this a script restart would
-- leave this client with an empty set -- every feature unblocked -- until
-- their next reconnect or the next time high command happened to change
-- something for them.
--
-- Asking rather than waiting also removes an ordering assumption: a push
-- that races this file's own load can no longer be the only copy of the
-- state, because we ask for it again once we are definitely ready.
--
-- The request is read-only, resolves the citizenid from `source`
-- server-side (it carries no arguments at all, so there is nothing to
-- forge), and is idempotent -- the handler above full-replaces the set
-- rather than merging, so a duplicate answer changes nothing.
--
-- Asked from onClientResourceStart rather than at file scope, on purpose.
-- That event fires for this resource on a fresh join AND on a bare client
-- script restart, so it covers both cases a single top-level call would,
-- while guaranteeing the network layer is actually up when the request
-- goes out -- a file-scope TriggerServerEvent runs while the resource is
-- still loading.
--
-- FAIL DIRECTION: if this never reaches the server, or the answer never
-- comes back, ClientFeatureBlocks stays empty and every feature works.
-- That is deliberate. A networking hiccup silently stripping someone's
-- abilities would be far worse than a block landing late.
-- ======================================================================
AddEventHandler('onClientResourceStart', function(resourceName)
    if resourceName ~= GetCurrentResourceName() then return end
    TriggerServerEvent('qbx_k9unit:server:requestFeatureBlocksSync')
end)
