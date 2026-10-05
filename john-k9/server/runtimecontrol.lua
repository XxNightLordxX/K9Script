--[[
    john-k9/server/runtimecontrol.lua

    Config.Features.RuntimeFeatureControl / Config.Features.TabletTheming.
    The owner's own words: "I want the high command to have even more
    control over all the features and sub features" / "Or even able to edit
    the tablet look." Two independent surfaces, both tablet-callback-driven,
    both high-command-only, both persisted:

      PART 1 -- runtime feature control: switch a Config.Features.* flag on
      or off, and tune a small allowlisted set of numeric Config values,
      without editing config.lua or restarting -- where that is honestly
      possible (see "THE ENGINE CONSTRAINT" below; it is NOT always
      possible, and this file says so instead of pretending).

      PART 2 -- tablet theming: a handful of colour slots, a density
      setting, and one header-title string, saved server-side and applied
      for every viewer. COSMETIC ONLY -- see "PART 2" below for the exact
      boundary.

    TWO SHAPES OF "this needs a typed confirmation before it applies", ONE
    MECHANISM: "LOCKOUT-RISK FEATURES" below (HighCommand/PermissionGrants/
    RuntimeFeatureControl/TabletTheming/CommandTablet -- always risky, no
    matter what anyone is doing) and "ACTIVE-USAGE CONFIRMATION FEATURES"
    below that (BiteAndHold/NonLethalTakedown/PropDragging/DeployableKennel
    -- risky only while a player is genuinely doing that exact thing right
    now, with a real, live headcount in the warning). Both share the
    identical response shape (`reason = 'confirmation_required'`,
    `lockoutRisk = true`, `warning = <text>`) and the identical
    html/tablet.js read-and-type panel -- see that second section's own
    header for why this is one mechanism serving two triggers, not two
    mechanisms.

    ======================================================================
    THE ENGINE CONSTRAINT -- READ THIS BEFORE TRUSTING ANY TOGGLE THIS FILE
    OFFERS. Every feature in this resource gates its RegisterCommand/
    RegisterNetEvent/lib.callback.register calls ONCE, at file-load or
    onResourceStart time -- config.lua's own header on this exact flag
    quotes this as deliberate: "that is what makes a disabled feature
    genuinely inert instead of merely hidden." The consequence, worked out
    file-by-file below rather than assumed:
      - A feature whose HANDLER re-checks Config.Features.<Name> itself,
        live, on every invocation (not a value captured once at load) can
        be switched OFF at runtime and it genuinely, immediately stops --
        AND can be switched back ON just as immediately, because nothing
        about its registration ever depended on the flag in the first
        place. These are marked `tier = 'live'` below.
      - A feature gated ONLY at registration time, whose handler body does
        NOT re-check the flag, cannot be turned off by mutating the flag
        alone -- the handler stays reachable regardless, because it was
        already registered. Two different sub-cases, found by reading every
        registration site in this resource, not assumed from the pattern's
        name alone:
          * `tier = 'onstart'` -- the registration itself lives inside
            `AddEventHandler('onResourceStart', ...)`. THIS FILE is loaded
            before every one of these (see FXMANIFEST PLACEMENT below), so
            it registers ITS OWN 'onResourceStart' handler first -- when the
            server actually fires that event, handlers run in the order
            they were added, so this file's override re-application runs
            BEFORE theirs. That means a persisted override genuinely takes
            effect on the NEXT restart (never on the current one -- nothing
            can retroactively call RegisterCommand for a session already
            running), which is enough to satisfy "an override must survive
            a restart" for these.
          * `tier = 'rawtoplevel'` -- the registration is gated by a bare
            `if not Config.Features.X then return end` at the very top of
            the file, executed the instant that file's turn comes up during
            this resource's own sequential server_scripts load -- which
            happens BEFORE FXServer ever fires 'onResourceStart' for this
            resource at all. No onResourceStart handler, however early it
            is registered, can run before that. A persisted override for
            one of these CANNOT take effect through a restart of this
            resource alone, on any restart, ever, through this mechanism --
            the operator has to edit config.lua's own value directly and
            restart. This file still records the override (for the tablet
            to show what high command asked for, and for forward
            compatibility if that file is ever refactored to check the flag
            live), but every response for one of these says so plainly
            (`configEditRequired = true`, not merely `restartRequired`).
      - A feature with NO server-side registration point at all (a pure
        client-rendered cosmetic/HUD toggle) has nothing this file could
        ever flip regardless of restart -- `tier = 'clientonly'`. Mutating
        Config.Features.X server-side changes nothing for an already-
        connected client, which loaded its own independent copy of
        config.lua at ITS OWN resource start and never re-reads this
        server's in-memory table. Making these genuinely live would need a
        client-side listener this file does not own (see "WHAT THIS FILE
        DOES NOT DO" below) -- reported, not built here.
      - Two features are `tier = 'protected'` and cannot be toggled through
        this system AT ALL, regardless of caller: `HighCommand` and
        `PermissionGrants`. Both gate the very authorization check this
        file's own callbacks depend on (IsHighCommand/HasPermission). Both
        also happen to be genuinely `live` internally (IsHighCommand/
        HasPermission both re-check their own flag on every call, by their
        own files' explicit design) -- but a high-command officer using a
        high-command-gated tool to switch off the high-command gate itself,
        mid-session, is a self-lockout with a MUCH wider blast radius than
        any other entry in this table (every OTHER high-command bypass in
        this resource stops working in the same instant, not just this
        tablet). An operator who genuinely wants either off does so in
        config.lua, on purpose, with a restart -- not from inside the
        system that bypass itself protects.

    THE FULL AUDIT, tier by tier (every entry below was confirmed by
    directly reading the file that registers it, not inferred from its
    name or from this resource's own general "read the flag at the point of
    use" convention alone -- that convention is real and is DEVELOPER_REFERENCE.md §3's own
    acceptance criterion, restated at config.lua's Config.Features header,
    but is not universally followed to the letter every file claims; several
    files say so themselves, e.g. server/fetch.lua's own "GATE AT
    REGISTRATION, NOT INSIDE THE HANDLER" comment):

    UPDATED 2026-08-26: eleven Config.Features keys shipped after this
    audit was first written (CameraFeedPiP, FindAlerts, K9DownDispatch,
    K9EquipmentShop, K9Leaderboard, PursuitSprint, ResourceAutoDetect, and
    four features since removed) had no FEATURE_TIERS
    entry at all -- GetFeatureTier silently resolved every one of them to
    'unaudited', and runtimeSetFeature did NOT actually refuse an
    'unaudited' tier despite this header's own "fails closed" claim in
    "FEATURE REGISTRY" below -- a real doc/implementation mismatch, now
    fixed on both sides (see that section for the fix). All eleven were
    read file-by-file this pass exactly like the original 45 and now carry
    a real tier: live (FindAlerts), onstart
    (K9EquipmentShop, ResourceAutoDetect), rawtoplevel (K9DownDispatch,
    K9Leaderboard, PursuitSprint),
    clientonly (CameraFeedPiP -- a genuine special case; see its own
    FEATURE_TIERS note below, it has NO implementing code anywhere in this
    resource at all, server or client). The full file-by-file evidence for
    each is recorded as that entry's own `note` field in FEATURE_TIERS
    below, not duplicated a second time in this prose list -- two copies of
    the same evidence is exactly the kind of thing that drifts.
    tests/runtimefeaturetiers_spec.lua now fails the whole suite if
    Config.Features and FEATURE_TIERS are ever allowed to drift apart like
    this again.

      live       -- XPProgression (server/progression.lua's AwardXP),
                    HandlerPartnership (server/partnership.lua's
                    CheckPartnershipEligibility), BiteAndHold /
                    NonLethalTakedown / PropDragging (server/combat.lua's
                    ValidateCombatRequest, passed the live flag at every
                    request), DeployableKennel (server/kennel.lua, checked
                    inside both RegisterNetEvent handlers), ScentTracking /
                    BloodTracking / GunpowderSniffing (server/tracking.lua;
                    the QUERY side -- findTrackableSource -- re-checks the
                    right flag per trackType on every call; ScentTracking's
                    INPUT side, the ox_inventory drop hook, is registered
                    once at resource-start and is NOT reopened by flipping
                    this back on mid-session -- disclosed per-feature below,
                    not silently folded into "live"), ContrabandAlerts /
                    SearchZones (server/search.lua's searchTarget callback
                    and HandleSearchTarget), K9Inventory
                    (server/inventory.lua's openK9Inventory callback),
                    K9Medkit (server/medkit.lua's useK9Medkit callback),
                    LeashMechanics (server/main.lua's
                    CheckLeashEligibility), BasicBarkSounds /
                    DoorInteraction (server/main.lua's relayBark /
                    relayDoorScratch handlers), CertificationExpiry
                    (server/certifications/'s GrantCertification checks
                    it live for the primary "does a new grant get an
                    expiry" effect; the courtesy-warning SWEEP THREAD is
                    only started if the flag was already true when
                    certifications.lua loaded -- disclosed per-feature,
                    same reasoning as ScentTracking above), FatigueSystem
                    (server/wellbeing.lua, re-checked inside the functions
                    its own tick/relay handlers call),
                    PartnershipTenureBonus (server/tenure.lua's
                    TickPartnershipTenure re-checks all three of
                    HandlerPartnership/XPProgression/PartnershipTenureBonus
                    on every tick, per that file's own "DEVELOPER_REFERENCE.md §3... point
                    of use" comment -- but the TICK THREAD ITSELF only
                    starts if all three were already true when tenure.lua
                    loaded, so turning this on when it was off at boot has
                    the same "nothing is polling to notice" gap as
                    ScentTracking's drop hook -- disclosed per-feature).
      onstart    -- AdminAuditCommands (server/admin.lua), BoneSweepDevTool
                    (server/bonetool.lua) -- both register every command
                    inside their own `onResourceStart` handler, and neither
                    handler re-checks the flag inside itself afterward.
      rawtoplevel -- FetchMechanic (server/fetch.lua: "the entire file is
                    inert... while the flag is off", its own words),
                    PropAttachments
                    (server/propattachment.lua wraps its entire back half
                    in `if Config.Features.PropAttachments then ... end`),
                    CommandTablet (server/permissions.lua's own two tablet
                    callbacks are registered inside a bare
                    `if Config.Features.CommandTablet == true then ...
                    end` at that file's own top level -- other files may
                    register their own tablet-only surfaces the same way;
                    this file does not attempt to enumerate every one).
      clientonly -- RadialMenu, AgilityBasicJump, AgilityAdvanced,
                    ThermalVision, NightVision, HealthStaminaHUD,
                    ContrabandScreenFX, AdvancedBarkRadial, ProximityAudioFX,
                    WaterTrackingDecay -- zero occurrences in any
                    server/*.lua file (confirmed by grep before writing this
                    list, not assumed from the name), so there is no
                    server-side enforcement point for this file to touch at
                    all. Listed in ListFeatures' response as
                    `tier = 'clientonly'` so the tablet can grey these out
                    rather than silently omit them.
                    VEHICLEENTRYEXIT WAS IN THIS LIST AND IS NOT ANY MORE
                    (2026-08-26): the claim above was true when it was
                    written and stopped being true the moment vehicle entry
                    gained a server half. server/vehicle.lua now arbitrates
                    seat claims and re-reads this flag live on every claim
                    request, so it is `tier = 'live'`. Leaving it as
                    clientonly would have told an operator, in this tablet's
                    own words, that switching it off does nothing until a
                    restart -- while the server was in fact already refusing
                    claims. This entry is corrected here rather than
                    quietly, because a stale tier claim is exactly the class
                    of thing this file's own CameraFeedPiP note exists to
                    warn about.
      protected  -- NO ENTRIES USE THIS TIER as of the 2026-08-26 owner-
                    directive pass -- HighCommand/PermissionGrants (the only
                    two that ever did) are now tier = 'live' with
                    `lockoutRisk = true, sessionOnly = true` instead -- see
                    FEATURE_TIERS' own entries for both, and "LOCKOUT-RISK
                    FEATURES" above GetFeatureTier, for the full mechanism
                    that replaced outright refusal. This tier's mechanism
                    (runtimeSetFeature/runtimeResetFeature both still refuse
                    a 'protected' feature outright, unconditionally, before
                    any write) is kept fully functional and undeleted, for
                    defense in depth and for any future value that
                    genuinely has no safe path to being opened at all --
                    just currently unused.

    THE ESCAPE-HATCH RULE THIS PART EXISTS FOR. A `rawtoplevel` feature
    that was ON at boot stays reachable all session regardless of what an
    override says, so a termination or escape-hatch path can never be
    taken away from a player mid-session by a runtime toggle. The risk this
    file guards against is the OPPOSITE and much smaller one: an operator
    who shipped such a feature OFF and expects a runtime toggle to turn it
    on mid-session would otherwise be told "done" while nothing changed.
    SetFeature refuses to imply that -- see `configEditRequired` below.
    (The feature this note was originally written about was removed on
    2026-09-02; the rule outlives it and applies to every escape hatch.)

    ======================================================================
    PART 1B -- TUNING. Config.Features.RuntimeFeatureControl.
    An EXPLICIT ALLOWLIST (TUNABLE_REGISTRY below), not "every number in
    config.lua" -- deliberately. Each entry carries a hard [min, max] this
    file refuses to go outside of (never silently clamped to the boundary --
    an out-of-range request is REJECTED with the bounds told back to the
    caller, so a typo'd extra zero is loud, not silently rewritten to
    something else the caller didn't ask for). Three exclusion rules,
    applied while building this list, stated here so the exclusion is a
    decision and not an oversight:

    AMENDMENT (2026-08-26), READ THIS BEFORE TAKING RULES 1 AND 2 BELOW AT
    FACE VALUE: the owner directed, in his own words, given twice, "High
    command can grant anything they want to themselves xp promotions
    permissions etc" / "If its high command they should have the ability to
    grant whatever they want edit whatever they want etc." Rules 1 and 2
    below are PRESERVED VERBATIM, unedited, because they remain an accurate
    record of the RISK each exclusion was guarding against -- but they no
    longer describe this file's actual behavior for every value they name.
    Config.HighCommand.maxXpPerGrant/grantCooldownMs, every numeric key
    under Config.XP, and Config.CertificationExpiryDays/WarningDays are now
    OPEN -- see the TUNABLE_REGISTRY entries under "OWNER DIRECTIVE" further
    below (after BoneSweepTool.MaxBoneIndex) for the actual current
    entries, their bounds, and the reasoning for each, including one real
    footgun (a server/progression.lua bare assert this pass's own bounds
    exist specifically to keep unreachable) found while doing this. Rule 3
    (read fresh at the point of use) is UNCHANGED and was re-verified,
    file-by-file, for every newly-opened value before it was added -- this
    amendment only ever widens rules 1/2, never rule 3. Config.Departments
    and Config.HighCommand.allowSelfGrant remain excluded, on purpose, for
    entirely different reasons stated in full at that same location -- this
    amendment does not touch either.
      1. ECONOMY-AFFECTING VALUES ARE NOT TUNABLE AT ALL, UP OR DOWN, FROM
         THIS SURFACE. Every key under Config.XP (award amounts, the
         mint-budget cap referenced by server/progression.lua) and every
         key under Config.HighCommand (maxXpPerGrant, grantCooldownMs) is
         excluded outright -- config.lua's own Config.XPTiers header
         documents eight independent XP-farm shapes this resource has
         already had to close; a UI path that can raise any of those
         numbers is exactly the ninth. This is the "exclude entirely"
         choice the task's own brief offered as an alternative to "cap
         tightly" -- taken here because there is no legitimate high-command
         use case for LOWERING these live either that is worth the
         surface area of also allowing raising them from the same control.
      2. ACCESS-CONTROL-SEMANTIC VALUES ARE EXCLUDED, not because they are
         economy but because live-changing them has a retroactive-feeling
         side effect on real people's access: Config.CertificationExpiryDays
         and Config.CertificationExpiryWarningDays are left out (an
         instant policy change to how long every future grant's clock runs
         is a real decision an operator should make in config.lua, not a
         live dial) -- Config.CertificationExpiryCheckIntervalMs (merely
         how often a courtesy reminder sweep polls, not a policy value) IS
         included.
      3. EVERYTHING INCLUDED BELOW WAS INDIVIDUALLY CONFIRMED READ FRESH AT
         THE POINT OF USE, not captured once as some other file's
         constructor default, by direct code read (server/tracking.lua's
         Config.Tracking.*.searchCooldownMs/relayCooldownMs/maxRange/
         maxAgeSeconds are all read inside a live callback/handler body per
         request, matching that Config block's own header quoting DEVELOPER_REFERENCE.md
         §3 verbatim; server/admin.lua's Config.AdminAudit.CommandCooldownMs
         and Config.AdminAudit.MaxResults.* are both read fresh inside each
         command's own handler on every invocation, never captured as a
         NewCooldown constructor default; server/certifications/'s
         Config.CertificationExpiryCheckIntervalMs is re-read at the top of
         every sweep-thread loop iteration, confirmed by direct read of
         that exact loop). A tunable this file could not confirm this way
         is not on the list -- "restart required" is the safe direction of
         error for a FEATURE toggle this file cannot verify; for a TUNABLE,
         the safe direction is simply not exposing it at all until it is
         confirmed, since a wrong "applied live" claim here is a silent
         no-op with no distinguishing observable symptom the way a feature
         toggle at least prints once (see server/cooldowns.lua's own
         warnedBadCallTimeThreshold backstop) -- there is no equivalent
         backstop for a tuning value quietly not being re-read.

    THE cooldowns.lua FOOTGUN, why this file exists to specifically defend
    against it here: server/cooldowns.lua's IsOnCooldown treats a
    non-positive threshold as PERMANENTLY on, never "no cooldown" (see that
    file's own header). Every *_ms tunable's `min` below is a real positive
    floor for exactly this reason -- 0 is never in range for any of them,
    so SetTunable's own range check (never a bare `> 0`, always the
    registry's own min/max) already refuses it before it could ever reach a
    cooldown tracker. Tested explicitly in tests/runtimecontrol_spec.lua.

    ======================================================================
    PART 2 -- TABLET THEMING. Config.Features.TabletTheming.
    COSMETIC ONLY, STATED PLAINLY: nothing in k9_tablet_theme, nothing this
    file reads from it, and nothing GetTheme/SetTheme/ResetTheme below ever
    return is consulted by any authorization check anywhere in this
    resource. A theme value can change what the tablet LOOKS like; it can
    never change what pressing a button in it actually DOES -- every action
    the tablet offers is, and remains, re-authorized server-side from the
    caller's own live job/grants at the point that action's own callback
    runs, exactly as it was before this file existed. GetTheme deliberately
    has NO authorization check beyond "you are a connected player" -- it is
    read by, and applied for, EVERY viewer, not just high command, matching
    the owner's own "applied for everyone" framing; only SetTheme/ResetTheme
    require the same high-command check as Part 1.

    A SIX-FIELD SURFACE, not a CSS field, because "free-form CSS injection
    from a UI is not a feature worth having" (this task's own words, and
    this file agrees): four named colour slots (primaryColor/accentColor/
    backgroundColor/textColor, each validated as EXACTLY `#RRGGBB` -- see
    IsValidHexColor below, a strict pattern match, not a permissive "looks
    colour-ish" heuristic), one density enum (`comfortable` | `compact` --
    a fixed lookup table, never free text), and one header-title string
    (<=40 chars, VARCHAR(40)-backed, additionally rejected outright if it
    contains any of `< > & " ' \` or a control/CR/LF/TAB byte -- see
    IsSafeHeaderTitle below). That last check is DEFENSE IN DEPTH, not the
    primary control: html/tablet.js's own test suite
    (html/tests/tablet_xss_spec.js, read before writing this file) already
    proves that file renders every dynamic string via `textContent`, never
    `innerHTML` -- html/tests/tablet-dom-stub.js's own innerHTML setter is
    deliberately "trapped" specifically to catch a regression on that
    point. This file's own character-level rejection exists so that a
    theme value which somehow reached a DIFFERENT, less careful renderer
    later (a future companion app, a log viewer, anything else that might
    one day read k9_tablet_theme) still could not carry markup -- belt AND
    suspenders, not one instead of the other.

    BROADCAST ON CHANGE: SetTheme/ResetTheme, on success, additionally
    TriggerClientEvent('john-k9:client:themeUpdated', -1, theme) so an
    already-open tablet updates without the viewer having to close and
    reopen it -- "applied for everyone" means everyone currently looking at
    one too, not just the next person to open one. THIS FILE DOES NOT
    REGISTER A CLIENT-SIDE HANDLER FOR THAT EVENT -- see "WHAT THIS FILE
    DOES NOT DO" below; that is client/tablet.lua's own owner's call to
    wire up, reported in full in this pass's hand-off note with the exact
    payload shape.

    ======================================================================
    WHAT THIS FILE DOES NOT DO, ON PURPOSE:
      - It does not attempt a synchronous database read at this file's own
        raw top-level (before any AddEventHandler/CreateThread). Every
        existing DB-dependent startup path in this resource
        (server/admin.lua, server/highcommand.lua, server/certifications/'s
        backfill, server/permissions.lua's backfill) defers its first real
        query into `AddEventHandler('onResourceStart', ...)` -- none of
        them do it at bare file scope. This file follows that same,
        already-proven convention rather than introducing an unprecedented
        pattern this resource has never actually exercised, even though a
        successful raw-top-level read would have let this file's override
        reach `rawtoplevel`-tier files too. The honest, disclosed cost of
        that caution is exactly the `rawtoplevel` tier documented above --
        a real limitation, not hidden by this design choice.
      - It does not push a live Config update to already-connected
        CLIENTS for anything other than the theme broadcast above. A
        client's own copy of config.lua is independent, per-connection,
        Lua state loaded at that client's own resource start; this
        resource has never had a "push a config value to every client"
        mechanism before this file, and inventing a generic one is a
        client/coder-frontend decision, not a server-lens one. Reported as
        a follow-up, not built here.
      - It does not add a new Config.Permissions capability key to
        config.lua (owned by the config owner this pass, not edited here).
        Every authorization check below tries `HasPermission(citizenid,
        'k9.runtimecontrol')` / `HasPermission(citizenid, 'k9.tablettheme')`
        behind the usual `type(HasPermission) == 'function'` guard, which
        today always returns `false` for either key (HasPermission fails
        closed on any key not present in Config.Permissions) -- so
        IsHighCommand alone is what actually authorizes every call right
        now, exactly matching this task's own "high command only" brief,
        with the permission-grant escape hatch activating automatically,
        with zero code change here, the moment those two keys are added.

    ======================================================================
    FILE-TO-FILE CONTRACT:
    - THIS FILE calls `NewCooldown` (server/cooldowns.lua) at this file's
      own file-load time -- MUST load after server/cooldowns.lua.
    - THIS FILE calls `IsHighCommand` (server/highcommand.lua) and
      `HasPermission` (server/permissions.lua) at CALLBACK-CALL time only,
      both behind `type(...) == 'function'` guards -- genuine soft
      dependencies; this file may load before either.
    - THIS FILE MUST load before every `onstart`/`rawtoplevel`-tier file
      named above (server/admin.lua, server/bonetool.lua,
      server/fetch.lua, server/propattachment.lua, server/permissions.lua,
      and in practice
      every other server/*.lua feature file) for the "persisted override
      survives a restart" property described above to hold for the
      `onstart` tier at all. See FXMANIFEST PLACEMENT below for the exact
      request.
    - THIS FILE exposes no resource-global functions -- nothing else in
      this resource needs to call into it; every effect it has on another
      file is via mutating the shared `Config` table those files already
      read, never via a direct function call in either direction.
    - THIS FILE owns four new tables: k9_runtime_feature_overrides,
      k9_runtime_override_audit, k9_tablet_theme, k9_tablet_theme_audit --
      see sql/migrations/0007_create_k9_runtime_control.sql for the exact
      shape and sql/rollback/0007_down.sql for why none of the four are
      ever dropped by this resource's own rollback tooling.

    FXMANIFEST PLACEMENT REQUESTED (server_scripts, not edited here --
    the manifest owner owns this file): insert
    `'server/runtimecontrol.lua',` immediately after `'server/cooldowns.lua',`
    -- i.e. BEFORE `'server/entities.lua'`, `'server/notify.lua'`,
    `'server/highcommand.lua'`, `'server/permissions.lua'`, and every
    other server/*.lua file. This satisfies the one hard load-order
    requirement (after cooldowns.lua, for NewCooldown at this file's own
    load time) and the "loads before every onstart/rawtoplevel file"
    requirement above in one placement -- this file needs nothing from
    entities.lua/notify.lua, so their relative order versus this file does
    not matter.

    LOCALE KEYS THIS FILE NEEDS: THIS COMMENT IS STALE AND WAS LEFT WRONG BY
    A PRIOR PASS -- corrected here rather than re-asserted, because the pass
    editing this file right now was about to make it more wrong, not less.
    Every callback below STILL returns a structured `{ ok, reason, ... }`
    table -- outcome tags, never player-facing prose, matching
    server/permissions.lua's own established "no granter-facing toast, the
    tablet renders its own inline feedback from `reason`" precedent (see
    that file's header) -- that part of this claim remains true. What is
    NOT true any more: GetFeatureLockoutWarning (below) already reads
    locales/en.json's `tablet.runtime_lockout_warning_*_template` keys via
    `pcall(locale, ...)`, and GetTunableDescription (below, added this
    pass) reads `tablet.runtime_tunable_desc_*` the identical way -- both
    ARE player-facing prose, deliberately, and both go through the locale
    system for exactly the reason every other player(operator)-facing
    string in this resource does. Every pcall(locale, ...) call site in
    this file is written to degrade gracefully (a missing key never throws
    past the pcall, never blanks a required field) specifically because
    this file cannot assume every locale this resource ships has caught up
    with every key added here. No RegisterCommand exists here for a usage
    string to need translating
    either -- this surface is tablet-only, per the owner's own framing.
]]

-- ======================================================================
-- BASELINE CAPTURE -- must run before ANYTHING below mutates Config.
-- CONFIG_LUA_DEFAULT_FEATURES/_TUNABLES are the exact values config.lua
-- shipped with, on THIS boot, before any override is re-applied -- the
-- "obvious way back to the config.lua default" the task asked for reads
-- from these, never from a second copy of config.lua or a guess.
-- ======================================================================
local CONFIG_LUA_DEFAULT_FEATURES = {}
for name, value in pairs(Config.Features or {}) do
    CONFIG_LUA_DEFAULT_FEATURES[name] = value
end

-- ======================================================================
-- FEATURE REGISTRY -- tier metadata for every Config.Features key this
-- file knows how to reason about. As of the 2026-08-26 owner-directive pass
-- this table has an entry for all 57 current Config.Features keys (56 as
-- of the audit further above in this header, +1 for ScentVision, landed
-- concurrently with this pass by a different agent and classified here --
-- see that entry's own comment) -- see tests/runtimefeaturetiers_spec.lua,
-- which fails the entire suite the moment that stops being true again.
--
-- A name present in Config.Features but NOT in this table (a FUTURE
-- feature this file's own audit has not yet covered -- there is
-- deliberately none of these today) is treated as tier = 'unaudited' by
-- GetFeatureTier below. THIS IS NOW THE ACTUAL, ENFORCED BEHAVIOR, not
-- merely documented intent left unimplemented -- a prior version of this
-- file wrote this exact "fails closed" claim here while runtimeSetFeature's
-- own code silently did the opposite (applied the toggle anyway, with only
-- a note) for eleven shipped features that had no FEATURE_TIERS entry.
-- That gap is closed on both sides now:
--   - runtimeSetFeature REFUSES to toggle an unaudited feature (reason =
--     'unaudited_feature'), the same fail-closed treatment 'protected'
--     gets, and prints a named console warning identifying exactly which
--     feature and what to do about it.
--   - This file ALSO prints a loud, unmissable warning at its own load
--     time (see the block right after GetFeatureNote below) enumerating
--     every currently-unaudited Config.Features key, so the gap is visible
--     on every single boot, not only the moment someone happens to try the
--     tablet.
--   - ListFeatures still lists it (tier = 'unaudited' in the response) so
--     the tablet can show it exists and is not yet toggleable, rather than
--     silently omitting it.
-- ======================================================================
local FEATURE_TIERS = {
    -- tier = 'live' -- see header "THE FULL AUDIT" for the exact evidence per entry.
    XPProgression          = { tier = 'live' },
    -- server/progression.lua's AwardHandlerXP re-checks
    -- Config.Features.HandlerXPProgression fresh on its own first line,
    -- exactly like AwardXP re-checks XPProgression above -- genuinely live,
    -- not merely registered once at load/start time. Ships `false` by
    -- default (config.lua's own comment on this key: two of its six award
    -- keys are deliberately left unwired pending a per-actor mint cooldown
    -- in server/medkit.lua/server/kennel.lua) -- that is an economy/anti-farm
    -- readiness question, not a liveness one, so it does not change this
    -- classification.
    HandlerXPProgression   = { tier = 'live' },
    HandlerPartnership     = { tier = 'live' },
    -- RESOLVED (coder-backend, this pass): this entry used to disclose a
    -- partial-liveness gap -- server/combat.lua's own expiry maintenance
    -- thread and its K9-position-history sampling thread each used to only
    -- start if one of BiteAndHold/NonLethalTakedown/PropDragging/
    -- the feature was ALREADY true when that file loaded, so
    -- flipping one on live (all four off at boot) produced holds/takedowns/
    -- drags with no automatic release path until a restart. Both threads
    -- now start unconditionally and re-check their governing flag(s) fresh
    -- every tick (the expiry thread needed no inner check at all -- an
    -- empty ActiveHolds is genuinely free to walk; the position-history
    -- thread's flag check moved inside its loop, since GetPlayers() is not
    -- free to walk unconditionally). See server/combat.lua's own comments
    -- at both thread definitions, and tests/combat_spec.lua's two
    -- "LIVE-FLIP FIX" tests, for the full writeup and regression coverage.
    -- ACTIVE-USAGE CONFIRMATION (this pass, coder-ui) -- see
    -- "ACTIVE-USAGE CONFIRMATION FEATURES" below GetFeatureLockoutWarning
    -- for the full mechanism: SetFeature/ResetFeature additionally refuse
    -- to disable any one of these four with the SAME
    -- reason='confirmation_required'/`confirm` gate as a lockoutRisk
    -- feature, WHILE (and only while) at least one player is genuinely
    -- doing the exact thing it gates right now -- a real, live headcount
    -- in the warning text, never a generic "are you sure?". Never blocks
    -- releasing/ending one already in progress; only blocks STARTING to
    -- disable the feature.
    BiteAndHold            = { tier = 'live' },
    NonLethalTakedown      = { tier = 'live' },
    PropDragging           = { tier = 'live' },
    DeployableKennel       = { tier = 'live' },
    ScentTracking          = { tier = 'live', note = 'Query side (findTrackableSource) is fully live. The ox_inventory drop hook that logs NEW scent sources is only (re-)registered at server start -- turning this on mid-session re-enables searching existing/already-logged sources immediately, but new drops will not be logged as scent sources until this resource restarts.' },
    BloodTracking          = { tier = 'live' },
    GunpowderSniffing      = { tier = 'live' },
    ContrabandAlerts       = { tier = 'live' },
    SearchZones            = { tier = 'live' },
    K9Inventory            = { tier = 'live' },
    K9Medkit               = { tier = 'live' },
    LeashMechanics         = { tier = 'live' },
    BasicBarkSounds        = { tier = 'live' },
    DoorInteraction        = { tier = 'live' },
    CertificationExpiry    = { tier = 'live', note = 'New/renewed grants getting an expiry date works immediately either way. The courtesy expiry-warning sweep thread only starts if this was already true when server/certifications/ loaded -- turning it on mid-session does not start a sweep that never began; a restart is needed for the warning sweep specifically (grants themselves are unaffected).' },
    FatigueSystem          = { tier = 'live' },
    PartnershipTenureBonus = { tier = 'live', note = 'The milestone check itself re-verifies HandlerPartnership/XPProgression/PartnershipTenureBonus fresh every tick. The tick thread only starts if all three were already true when server/tenure.lua loaded -- if it was off at boot, turning it on mid-session has nothing polling to notice a milestone until this resource restarts.' },
    -- ADDED 2026-08-26 (closing the 11-feature audit gap -- see header "UPDATED 2026-08-26"):
    -- Entries for features removed on 2026-09-02 were taken out here
    -- alongside their TUNABLE_REGISTRY entries further below. An orphaned
    -- FEATURE_TIERS entry for a feature that no longer exists has zero
    -- behavioural consequence either way (see
    -- tests/runtimefeaturetiers_spec.lua's own documented guarantee of
    -- that) -- removed anyway, so no stale trace is left in a file this
    -- pass could reach.
    FindAlerts             = { tier = 'live', note = 'server/findalert.lua registers both AddEventHandlers (john-k9:events:searchCompleted, john-k9:server:reportTrackSourceArrival) unconditionally at file-load time -- no raw top-level gate exists in this file at all. The shared DispatchFindAlertReaction helper both handlers funnel through re-checks Config.Features.FindAlerts fresh on every single call (its own first line: "if not Config.Features.FindAlerts then return end -- real no-op, not just hidden"), so toggling this off/on stops/starts the bark-on-find reaction genuinely and immediately, with nothing captured once at registration time.' },
    -- ADDED post-2026-08-26 (coder-frontend/coder-architect's ScentVision
    -- feature, landed concurrently with this pass -- classified here per
    -- their own analysis, independently re-confirmed by direct read of
    -- server/tracking.lua before trusting it): the CAPTURE thread is a bare
    -- `while true do if Config.Features.ScentVision then ... else
    -- Wait(idle) end end` (no raw top-level gate, no onResourceStart-only
    -- registration) -- re-checked fresh every single loop pass. The QUERY
    -- side, getScentVisionPoints (lib.callback.register), opens with "if
    -- not Config.Features.ScentVision then return { points = {} } end" --
    -- also re-checked fresh on every call. Genuinely live in both
    -- directions, no partial-liveness caveat needed (unlike ScentTracking's
    -- own drop-hook gap above).
    ScentVision            = { tier = 'live' },

    -- tier = 'onstart' -- registered inside AddEventHandler('onResourceStart', ...); this file's own override re-application runs first (see FXMANIFEST PLACEMENT), so a persisted override reliably applies on the NEXT restart, never within the current session.
    AdminAuditCommands     = { tier = 'onstart' },
    BoneSweepDevTool       = { tier = 'onstart', note = 'Also requires the john_k9_enable_bone_dev_tool convar and a boss-rank caller regardless of this flag -- see config.lua\'s own comment on this feature.' },
    -- ADDED 2026-08-26:
    K9EquipmentShop        = { tier = 'onstart', note = 'server/equipmentshop.lua registers the actual ox_inventory shop (RegisterShop plus item/currency verification) AND loads persisted runtime shop locations, BOTH inside their own AddEventHandler(\'onResourceStart\', ...) handlers, gated on Config.Features.K9EquipmentShop == true at that point only -- neither re-checks the flag again afterward, so having a purchasable shop at all needs a restart in EITHER direction, same shape as AdminAuditCommands/BoneSweepDevTool above. DISCLOSED PARTIAL LIVENESS, not folded into a false "live" claim: the runtime-shop-location management callbacks (equipmentShopGetLocations/AddLocation/MoveLocation and their siblings) ARE always registered and DO re-check the flag live on every call -- but they only manage WHERE an already-registered shop\'s ped stands, never whether the shop exists at all, so this entry reports the tier that governs the actual "can a player buy anything here" effect.' },
    -- server/webhook.lua reads Config.Features.DiscordWebhook and
    -- Config.DiscordWebhook.url once, at its own FILE-LOAD time, past its
    -- own feature/URL gates -- NewCooldown() is called there, and the flush
    -- thread is created there. Nothing re-reads the flag afterwards. So
    -- switching this on at runtime does not start the poster, and switching
    -- it off does not stop it, until the resource restarts. Classified
    -- rawtoplevel rather than live for exactly that reason: a SetFeature
    -- response must never tell an operator "already applied" for something
    -- that will not take effect until they restart.
    DiscordWebhook         = { tier = 'rawtoplevel', note = 'Posting to Discord starts and stops at resource start, not when you flip this. Change it and restart the resource. Note that the URL matters more than the flag: with no Config.DiscordWebhook.url set, nothing is posted regardless of this switch.' },
    ResourceAutoDetect     = { tier = 'onstart', note = 'shared/compat/core.lua (not owned by this pass -- read-only audit, this file does not edit it) is not gated by a raw top-level early return or a plain onResourceStart registration in the usual sense: DetectSystem() reads Config.Features.ResourceAutoDetect fresh on every call, and K9Compat.Redetect() (which calls DetectSystem for every system) DOES run again later -- on another resource starting/stopping when Config.Compat.redetectOnResourceRestart is true, and opportunistically from several feature files\' own defensive "redetect if the cached adapter looks stale" calls this file does not control. None of those later triggers are caused BY this file\'s own SetFeature call, though -- the only trigger this file can rely on with certainty is ScheduleInitialDetection\'s own CreateThread(Wait(startupGraceMs) then Redetect()), which fires exactly once, on THIS resource\'s own onResourceStart. Classified onstart, never live, so a SetFeature response never over-promises "already applied" for an effect this file cannot guarantee happens before the next restart -- an override may well take effect sooner in practice, opportunistically, but that is a bonus this file does not document as its contract.' },

    -- tier = 'rawtoplevel' -- gated before this resource\'s own onResourceStart ever fires; no restart of THIS resource alone can apply an override -- config.lua itself must be edited.
    FetchMechanic          = { tier = 'rawtoplevel' },
    PropAttachments        = { tier = 'rawtoplevel' },
    -- ADDED 2026-08-26 -- all six confirmed by direct read of a bare
    -- `if not Config.Features.X then return end` at that file's own raw
    -- top level, before any RegisterCommand/RegisterNetEvent/lib.callback
    -- call -- identical shape to FetchMechanic above:
    K9DownDispatch         = { tier = 'rawtoplevel', note = 'server/integrations.lua opens with "if not Config.Features.K9DownDispatch then return end" -- the poll thread, the NewCooldown construction, and the playerDropped handler are never even reached when the flag is off at load time.' },
    K9Leaderboard          = { tier = 'rawtoplevel', note = 'server/leaderboard.lua opens with "if not (Config.Features and Config.Features.K9Leaderboard == true) then return end" before its own RegisterCommand(\'k9stats\', ...) -- the command is never registered at all when the flag is off at load time.' },
    PursuitSprint          = { tier = 'rawtoplevel', note = 'server/pursuitsprint.lua opens with "if not Config.Features.PursuitSprint then return end" before its own config asserts and RegisterNetEvent(\'john-k9:server:requestPursuitSprint\', ...) -- the net event is never registered at all when the flag is off at load time.' },
    CommandTablet          = { tier = 'rawtoplevel', lockoutRisk = true,
        note = 'Multiple files register their own CommandTablet-gated tablet callbacks this same way (server/permissions.lua confirmed by direct read; others may exist). Turning this off here does not close an already-registered tablet callback anywhere in this resource.',
        lockoutWarningKey = 'commandtablet',
    },

    -- tier = 'clientonly' -- zero occurrences in any server/*.lua file (grepped before writing this list); nothing server-side to toggle.
    RadialMenu             = { tier = 'clientonly' },
    -- LIVE, not clientonly. server/vehicle.lua's seat-claim handler
    -- re-reads Config.Features.VehicleEntryExit on every request, so
    -- switching this off stops new claims being granted immediately, with
    -- no restart -- and switching it on starts granting them immediately.
    -- The claim-expiry sweep in that same file is started unconditionally
    -- and checks the flag inside its own loop, precisely so that flipping
    -- this on mid-session can never leave claims being created with nothing
    -- running to clean them up (the live-flip trap server/combat.lua and
    -- server/wellbeing.lua each had to be fixed for). The CLIENT half still
    -- only reads its own gate at resource start, so an already-connected
    -- player keeps their local entry controls until they reconnect -- which
    -- costs nothing, because the server refuses the claim regardless.
    VehicleEntryExit       = { tier = 'live', note = 'Turning this off stops new vehicle entries being granted straight away -- the server refuses the seat claim. A player already connected keeps the on-screen prompt until they reconnect, but pressing it will be refused. Anyone already sitting in a vehicle stays there and can always get out; that is never gated.' },
    AgilityBasicJump       = { tier = 'clientonly' },
    AgilityAdvanced        = { tier = 'clientonly' },
    ThermalVision          = { tier = 'clientonly' },
    NightVision            = { tier = 'clientonly' },
    HealthStaminaHUD       = { tier = 'clientonly' },
    ContrabandScreenFX     = { tier = 'clientonly' },
    AdvancedBarkRadial     = { tier = 'clientonly' },
    ProximityAudioFX       = { tier = 'clientonly' },
    WaterTrackingDecay     = { tier = 'clientonly' },
    -- ADDED 2026-08-26:
    CameraFeedPiP          = { tier = 'clientonly', note = 'Live toggle takes effect for a client on their next resource start, same as every other clientonly entry. THIS NOTE SAID THE OPPOSITE UNTIL 2026-08-26: it claimed the flag had zero implementing code anywhere and was genuinely inert. That was true when it was written and is not now -- client/vision.lua implements the feature (ToggleCameraFeed / StartCameraFeedAttempt / StopCameraFeed, bound to a command and a keybind when the flag is on), and config.lua\'s own comment on this flag was corrected to match. The old text was served verbatim to operators in this tablet\'s own runtime control screen, telling them a working, shipped, documented feature does nothing. What it IS: a full-screen switch to an active partner\'s viewpoint, not a true picture-in-picture inset -- the engine has no native for a second simultaneous viewport, which is the part that remains genuinely impossible.' },

    -- ==================================================================
    -- OWNER DIRECTIVE (2026-08-26), stated twice, verbatim: "High command
    -- can grant anything they want to themselves xp promotions permissions
    -- etc" / "If its high command they should have the ability to grant
    -- whatever they want edit whatever they want etc." These two were
    -- `tier = 'protected'` -- refused unconditionally, regardless of
    -- caller, no exceptions -- see header "THE ENGINE CONSTRAINT" for the
    -- ORIGINAL reasoning that shipped with that tier. That reasoning is
    -- kept verbatim above because it is still exactly correct as a
    -- description of the RISK; this pass is a deliberate, owner-directed
    -- decision to accept that risk with guardrails, not a retraction of
    -- the reasoning. OPENED THIS PASS, tier = 'live' (the HONEST tier --
    -- both are genuinely re-checked live on every call: server/
    -- highcommand.lua's IsHighCommand, line 382-383, `if not
    -- (Config.Features and Config.Features.HighCommand == true) then
    -- return false end`; server/permissions.lua's HasPermission, line
    -- 1391-1392, the identical shape for PermissionGrants -- both
    -- re-confirmed by direct read this pass), gated by two new mechanisms
    -- documented in full immediately below this table ("LOCKOUT-RISK
    -- FEATURES"):
    --   `lockoutRisk = true` -- SetFeature/ResetFeature both REFUSE to
    --   change either of these without the caller's own `confirm`
    --   argument matching the feature name EXACTLY (reason =
    --   'confirmation_required', the response carrying this entry's own
    --   `lockoutWarning` text back to the caller) -- "the refusal-to-change
    --   becomes a confirmed-change, not a silent one" (this task's own
    --   words), never a bare, silent flip of a value this dangerous.
    --   `sessionOnly = true` -- THE ONE THING THAT GENUINELY MATTERS HERE.
    --   Disabling Config.Features.HighCommand from the tablet, persisted
    --   the NORMAL way (K9Store.Override_Upsert, re-applied at the next
    --   boot by this file's own onResourceStart handler, which the
    --   FXMANIFEST PLACEMENT contract guarantees runs BEFORE every other
    --   file's), would let a STORED override survive a restart and WIN
    --   OVER a corrected config.lua -- an operator editing config.lua back
    --   to `HighCommand = true` and restarting would find the resource
    --   still boots with it OFF, because the stale DB row gets re-applied
    --   on top of the freshly-corrected value. THAT is a real bricking
    --   bug, and a self-inflicted, mid-session lockout of the one screen
    --   that could undo it is exactly the "worse than the day-one
    --   deadlock" scenario this task named directly. Closed by
    --   construction, not by hoping nobody hits it: SetFeature/
    --   ResetFeature never call K9Store.Override_Upsert/Override_Delete at
    --   all for a `sessionOnly` feature -- the change is a live Config
    --   mutation ONLY, kept in `ActiveOverrides` for THIS session's tablet
    --   display, and still fully audited via K9Store.OverrideAudit_Append
    --   (a permanent, append-only history row -- see that table's own
    --   migration comment confirming it needs no matching current-override
    --   row to exist) -- so there is never a row for the boot-time reapply
    --   loop to find in the first place. The boot loop ALSO defensively
    --   excludes `sessionOnly` features outright regardless (see that
    --   loop's own comment), so even a manually-inserted row, or a row
    --   left over from before this design existed (true today for
    --   RuntimeFeatureControl/TabletTheming below, which shipped `live`
    --   and toggleable, without this protection, before this very pass),
    --   can never win over config.lua on the next boot either. RESULT:
    --   config.lua on disk is the SOLE source of truth for this flag after
    --   EVERY restart, no exception -- recovery needs nothing more than
    --   restarting this resource; editing config.lua first only makes that
    --   recovery permanent instead of one-restart-temporary.
    -- ==================================================================
    HighCommand            = {
        tier = 'live', lockoutRisk = true, sessionOnly = true,
        note = 'Genuinely live in both directions (IsHighCommand re-checks this flag on every call) -- but see lockoutWarning: this is the single highest-blast-radius flag in this resource, since every OTHER high-command bypass in this resource stops working the same instant this does.',
        lockoutWarningKey = 'highcommand',
    },
    PermissionGrants       = {
        tier = 'live', lockoutRisk = true, sessionOnly = true,
        note = 'Genuinely live in both directions (HasPermission re-checks this flag on every call) -- see lockoutWarning: turning this off removes the grant-based access path for anyone who reaches this screen only via an explicit k9.runtimecontrol/k9.tablettheme grant rather than IsHighCommand.',
        lockoutWarningKey = 'permissiongrants',
    },

    -- This file's own two flags. Internally self-hosting (this file's own
    -- callbacks are ALWAYS registered, unconditionally, and re-check their
    -- own flag live on every call -- see "SELF-HOSTING" below), so both are
    -- genuinely `live`. FLAGGED `lockoutRisk`/`sessionOnly` THIS PASS, for
    -- the IDENTICAL reason as HighCommand above -- found while verifying
    -- this task's own "does a restart actually recover" requirement, NOT
    -- something the owner asked opened (neither was ever `protected`; both
    -- shipped `live` and toggleable from this file's very first version).
    -- Every one of this file's own Part-1 callbacks begins `if not
    -- (Config.Features and Config.Features.RuntimeFeatureControl == true)
    -- then return { ok = false, reason = 'feature_disabled' } end` --
    -- disabling it locks out the only screen that could turn it back on,
    -- the exact self-referential shape this task's own "one thing that
    -- genuinely matters" section describes. Left unfixed, this file would
    -- have opened a NEW lockout hole while closing an OLD one. Fixed here,
    -- in the same file, the same pass.
    RuntimeFeatureControl  = {
        tier = 'live', lockoutRisk = true, sessionOnly = true,
        lockoutWarningKey = 'runtimefeaturecontrol',
    },
    TabletTheming          = {
        tier = 'live', lockoutRisk = true, sessionOnly = true,
        note = 'Cosmetic only (see header PART 2) -- disabling this loses the ABILITY to re-theme until a restart, never any access or functionality.',
        lockoutWarningKey = 'tablettheming',
    },
}

--- @param name string
--- @return string tier -- 'live' | 'onstart' | 'rawtoplevel' | 'clientonly' | 'protected' | 'unaudited'
local function GetFeatureTier(name)
    local entry = FEATURE_TIERS[name]
    return entry and entry.tier or 'unaudited'
end

--- @param name string
--- @return string? note
local function GetFeatureNote(name)
    local entry = FEATURE_TIERS[name]
    return entry and entry.note or nil
end

-- ======================================================================
-- LOCKOUT-RISK FEATURES -- see FEATURE_TIERS' own HighCommand/
-- PermissionGrants/RuntimeFeatureControl/TabletTheming/CommandTablet
-- entries above for the full reasoning behind each one individually. Read
-- with `entry.lockoutRisk == true`/`entry.sessionOnly == true` directly
-- (never `entry.lockoutRisk`/`entry.sessionOnly` alone, and never `or
-- false` -- both would be correct here since neither field is ever the
-- number 0, but this file's own task brief is explicit that a boolean
-- must always be read as `~= false`, never `x or default`, as a blanket
-- discipline -- applied here for consistency even though this specific
-- pair of fields could not actually trip the "0 is falsy-adjacent"
-- footgun that rule exists to prevent).
--- @param name string
--- @return boolean
local function GetFeatureLockoutRisk(name)
    local entry = FEATURE_TIERS[name]
    return entry ~= nil and entry.lockoutRisk == true
end

--- @param name string
--- @return boolean
local function GetFeatureSessionOnly(name)
    local entry = FEATURE_TIERS[name]
    return entry ~= nil and entry.sessionOnly == true
end

--- Fills `{placeholder}` tokens in a locale template against a plain
--- table of values -- the SAME token syntax and substitution semantics as
--- html/tablet.js's own formatTemplate() (a JS function this file cannot
--- call directly; this is its Lua-side equivalent, kept byte-compatible
--- with that function's `{key}` -> `tostring(value)` behaviour so the two
--- stay interchangeable in spirit even though nothing here shares code
--- with the browser). Every lockout/active-usage warning below is built
--- through this, never a hardcoded Lua string, so its wording lives in
--- locales/en.json like every other player(operator)-facing string in
--- this resource, instead of bypassing the locale system entirely.
--- @param template string
--- @param params table<string, any>
--- @return string
local function FormatLocaleTemplate(template, params)
    local out = template
    for key, value in pairs(params) do
        out = out:gsub('{' .. key .. '}', (tostring(value):gsub('%%', '%%%%')))
    end
    return out
end

--- @param name string
--- @return string warning -- never nil for a lockoutRisk feature (every
--- entry with lockoutRisk = true carries its own lockoutWarningKey -- a
--- missing one would silently hand the tablet an empty confirmation
--- dialog for exactly the class of change this mechanism exists to make
--- loud, so this falls back to a generic-but-still-real warning rather
--- than nil/empty if a future lockoutRisk entry is ever added without one,
--- or if locales/en.json is ever missing the key this resolves to).
local function GetFeatureLockoutWarning(name)
    local entry = FEATURE_TIERS[name]
    local key = entry and entry.lockoutWarningKey
    if type(key) == 'string' and key ~= '' then
        local ok, template = pcall(locale, 'tablet.runtime_lockout_warning_' .. key .. '_template')
        if ok and type(template) == 'string' and template ~= '' then
            return FormatLocaleTemplate(template, { name = tostring(name) })
        end
    end
    local ok, genericTemplate = pcall(locale, 'tablet.runtime_lockout_warning_generic_template')
    if ok and type(genericTemplate) == 'string' and genericTemplate ~= '' then
        return FormatLocaleTemplate(genericTemplate, { name = tostring(name) })
    end
    -- Last-resort fallback, reached only if locales/en.json is missing
    -- EVEN the generic template above -- never surfaced under normal
    -- operation, but a lockoutRisk confirmation must never show an empty
    -- warning no matter how badly the locale file has drifted.
    return ('Changing Config.Features.%s carries a lockout risk, but no specific warning text is available for it -- proceed only if you understand exactly what this feature controls and how to recover (usually via config.lua and a restart) if something goes wrong.'):format(tostring(name))
end

-- ======================================================================
-- ACTIVE-USAGE CONFIRMATION FEATURES -- separate from, and ADDITIONAL TO,
-- the LOCKOUT-RISK mechanism just above. A lockout-risk feature is always
-- risky, regardless of what any player happens to be doing at the moment
-- (HighCommand/PermissionGrants/RuntimeFeatureControl/TabletTheming/
-- CommandTablet, all five above). These four are the opposite shape:
-- completely ordinary, everyday `tier = 'live'` toggles the rest of the
-- time, but genuinely disruptive AT THE EXACT MOMENT a player is doing the
-- specific thing each one gates, because disabling it live blocks anyone
-- from STARTING that thing again until it is switched back on.
--
-- REUSED, NOT REINVENTED (this task's own explicit instruction): the SAME
-- response shape (`reason = 'confirmation_required'`, `lockoutRisk =
-- true`, `warning = <text>`) and the SAME client-side read-and-type panel
-- (html/tablet.js's buildRuntimeLockoutConfirmPanel(), which renders any
-- row with `lockoutRisk = true` identically regardless of WHY it is
-- true -- see that function's own doc comment). The only thing genuinely
-- new here is WHEN `lockoutRisk` becomes true for one of these four:
-- computed FRESH, at the moment of the call (list, set, or reset), from a
-- live headcount this file asks the feature's own implementation file
-- for -- never cached, because "3 players are doing this right now" stops
-- being true the instant it stops being true.
--
-- WHY ONLY THESE FOUR, out of every `tier = 'live'` entry above -- checked
-- against the real code, not assumed from a feature's name or from this
-- task's own brief:
--   BiteAndHold / NonLethalTakedown / PropDragging -- server/combat.lua's
--     ActiveHolds table holds one entry per currently-open hold/takedown/
--     drag, keyed by effectType ('bite'/'takedown'/'drag') -- exactly the
--     "someone is doing this right now" state this mechanism needs. Read
--     via CountActiveHoldsByEffectType(effectType), a plain global
--     function server/combat.lua exposes for this (this resource's
--     established "global helper, private per-file state" convention --
--     see e.g. EndActiveEffectForHolder's own doc comment in that same
--     file), NEVER trusted to exist (runtime-existence-guarded +
--     pcall-wrapped exactly like every other soft cross-file dependency in
--     this resource -- see server/combat.lua's own EndActiveEffectForHolder
--     doc comment for the identical shape) so this file's own test sandbox
--     (tests/runtimecontrol_spec.lua, which loads ONLY
--     server/cooldowns.lua + server/runtimecontrol.lua by that spec's own
--     header) keeps working with no active-usage count available at all,
--     exactly as if nobody were using anything.
--   DeployableKennel -- server/kennel.lua's KennelOccupants table holds one
--     entry per citizenid whose K9 is genuinely resting inside a deployed
--     kennel right now. Read via CountKennelOccupants(), same soft-
--     dependency shape as above.
--   A `rawtoplevel` FEATURE -- DELIBERATELY EXCLUDED from active-usage
--     warnings as a class. Such a feature's whole file is gated by a single
--     `if not Config.Features.X then return end` at its own top level,
--     executed once when that file loads. If it was true at boot (the
--     ordinary case), every handler is already registered and never
--     re-checks the flag for the rest of the session -- so a live tablet
--     toggle provably changes nothing for anyone currently connected, and
--     SetFeature already says so (`restartRequired = true,
--     configEditRequired = true`). Adding a "N players are using this right
--     now" warning to a toggle that changes nothing live would be exactly
--     the overclaiming this file rejects elsewhere. (The training mode this
--     note was written about was removed on 2026-09-02; the rule applies to
--     every rawtoplevel feature.)
--   Every OTHER `tier = 'live'` feature (XPProgression,
--     HandlerXPProgression, HandlerPartnership, ScentTracking/
--     BloodTracking/GunpowderSniffing, ContrabandAlerts/SearchZones,
--     K9Inventory, K9Medkit, LeashMechanics, BasicBarkSounds/
--     DoorInteraction, CertificationExpiry, FatigueSystem,
--     PartnershipTenureBonus) has no equivalent "one player is inside a
--     continuous session of this right now" state to count in the first
--     place -- each of those is a momentary check-then-act (a single XP
--     award, a single medkit use, a single bark relay), not an ongoing
--     hold/occupancy this file could meaningfully warn about mid-flight.
--
-- WHAT THIS DOES NOT CLAIM: disabling any of these four does NOT force-end
-- an already-open hold or evict an already-resting K9 -- verified directly
-- against the code, not assumed. server/combat.lua's shared maintenance
-- thread (expiry/holder-death/vehicle-entry/max-drag-distance) and every
-- release event (releaseBiteHold/releaseTakedown/releaseDrag) never
-- re-check Config.Features.* at all, and server/kennel.lua's
-- requestExitKennel is likewise ungated -- exactly this resource's own
-- "never gate a termination path" rule, independently confirmed here
-- rather than taken on faith. GetActiveUsageWarning below says so
-- explicitly, for the same reason GetFeatureLockoutWarning's own callers
-- never overclaim what a sessionOnly toggle persists.
-- ======================================================================

--- Runtime-existence-guarded + pcall-wrapped read of server/combat.lua's
--- own ActiveHolds table, via the plain global function that file exposes
--- for exactly this -- see "ACTIVE-USAGE CONFIRMATION FEATURES" above for
--- the full reasoning.
--- @param effectType 'bite'|'takedown'|'drag'
--- @return integer? count -- nil if server/combat.lua is not loaded in
--- this environment (this file's own test sandbox, by design), never a
--- false 0 standing in for "unknown".
local function CountLiveCombatHolds(effectType)
    if type(CountActiveHoldsByEffectType) ~= 'function' then return nil end
    local ok, n = pcall(CountActiveHoldsByEffectType, effectType)
    if ok and type(n) == 'number' then return n end
    return nil
end

--- Same shape as CountLiveCombatHolds above, for server/kennel.lua's own
--- KennelOccupants table.
--- @return integer? count
local function CountLiveKennelOccupants()
    if type(CountKennelOccupants) ~= 'function' then return nil end
    local ok, n = pcall(CountKennelOccupants)
    if ok and type(n) == 'number' then return n end
    return nil
end

--- name -> { countFn = function(): integer?, activity = string } -- see
--- "ACTIVE-USAGE CONFIRMATION FEATURES" above for which four features are
--- here and why, and why a rawtoplevel feature deliberately is not.
local ACTIVE_USAGE_FEATURES = {
    -- `activity` is deliberately WITHOUT its own leading article -- see
    -- GetActiveUsageWarning below, which supplies "a"/"currently" in two
    -- DIFFERENT grammatical positions for the same string ("in a
    -- bite-and-hold" and "a NEW bite-and-hold") -- baking an article into
    -- the noun itself produced a genuine "a NEW a bite-and-hold" bug,
    -- caught by this pass's own tests before it ever reached a player.
    BiteAndHold       = { countFn = function() return CountLiveCombatHolds('bite') end,     activity = 'bite-and-hold' },
    NonLethalTakedown = { countFn = function() return CountLiveCombatHolds('takedown') end, activity = 'non-lethal takedown' },
    PropDragging      = { countFn = function() return CountLiveCombatHolds('drag') end,     activity = 'prop drag' },
    -- DeployableKennel's own activity string is a full clause, not a noun
    -- phrase needing an article at all -- see its own branch below.
    DeployableKennel  = { countFn = CountLiveKennelOccupants,                                activity = 'resting inside a deployed kennel' },
}

--- @param name string
--- @return integer? count -- a POSITIVE count if `name` is one of
--- ACTIVE_USAGE_FEATURES and at least one player is doing that thing right
--- now; nil otherwise (either `name` is not one of these four, the live
--- count came back 0, or the count could not be read at all -- all three
--- cases mean the same thing here: no active-usage confirmation is owed).
local function GetActiveUsageCount(name)
    local entry = ACTIVE_USAGE_FEATURES[name]
    if not entry then return nil end
    local ok, count = pcall(entry.countFn)
    if ok and type(count) == 'number' and count > 0 then return count end
    return nil
end

--- Plain-English, REAL-NUMBER warning for an active-usage confirmation --
--- this task's own explicit requirement: say WHAT will happen, never "are
--- you sure?". Honest about what actually happens on each of these four
--- (see "WHAT THIS DOES NOT CLAIM" above -- an already-open hold/occupancy
--- is never force-ended by this).
--- @param name string @param count integer -- already confirmed > 0 by GetActiveUsageCount
--- @return string
local function GetActiveUsageWarning(name, count)
    local entry = ACTIVE_USAGE_FEATURES[name]
    local subject = (count == 1) and '1 player is' or (count .. ' players are')
    local templateKey = (name == 'DeployableKennel')
        and 'tablet.runtime_active_usage_warning_kennel_template'
        or 'tablet.runtime_active_usage_warning_hold_template'
    local ok, template = pcall(locale, templateKey)
    if ok and type(template) == 'string' and template ~= '' then
        return FormatLocaleTemplate(template, { subject = subject, activity = entry.activity, name = tostring(name) })
    end
    -- Last-resort fallback, reached only if locales/en.json is missing
    -- one of the two templates above -- byte-identical to the wording
    -- this function hardcoded before it started reading locales/en.json,
    -- so a locale-file regression degrades to the same honest text rather
    -- than an empty confirmation dialog.
    if name == 'DeployableKennel' then
        return ('%s currently %s right now. Disabling %s will NOT remove them or force an exit -- a K9 already resting can always leave normally, unaffected -- but nobody will be able to deploy, enter, or pick up a kennel until it is turned back on.'):format(subject, entry.activity, name)
    end
    return ('%s currently in a %s right now. Disabling %s will NOT end an already-started hold -- automatic release, expiry, and manual release all keep working regardless -- but nobody will be able to start a NEW %s until it is turned back on.'):format(subject, entry.activity, name, entry.activity)
end

-- ======================================================================
-- STARTUP AUDIT WARNING -- loud, unmissable, printed once at THIS FILE'S
-- OWN LOAD TIME (not deferred into onResourceStart, so it appears
-- regardless of whether this resource ever finishes starting, and
-- regardless of whether anyone ever opens the tablet) for every
-- Config.Features key this table does not yet classify. This is the exact
-- loud warning "FEATURE REGISTRY" above promises in place of the SILENT
-- gap this file's own history already proved happens for real: eleven
-- shipped features went unclassified for an entire pass with nothing
-- printing a single word about it, and runtimeSetFeature quietly toggled
-- them anyway. Config is guaranteed already fully populated by this point
-- (config.lua is a shared_script, loaded in full before any server_scripts
-- file, this one included, per FXMANIFEST PLACEMENT above).
-- ======================================================================
do
    local unauditedNames = {}
    for name in pairs(Config.Features or {}) do
        if GetFeatureTier(name) == 'unaudited' then
            unauditedNames[#unauditedNames + 1] = name
        end
    end
    if #unauditedNames > 0 then
        table.sort(unauditedNames)
        print(('[John-K9] runtimecontrol.lua: WARNING -- %d Config.Features key(s) have NO FEATURE_TIERS entry in this file: %s. Runtime toggling via the tablet is REFUSED for every one of these (reason = "unaudited_feature") until classified. FIX: read that feature\'s real server/client implementation (does its handler re-check the flag live, once at onResourceStart, once at a raw file-top gate, or nowhere server-side at all?), then add FEATURE_TIERS.<Name> = { tier = ... } to server/runtimecontrol.lua matching one of the five tiers documented in this file\'s own header ("THE FULL AUDIT") -- see tests/runtimefeaturetiers_spec.lua, which exists specifically to catch this before it ships again.'):format(#unauditedNames, table.concat(unauditedNames, ', ')))
    end
end

-- ======================================================================
-- OWNER-EDITABLE CEILING for PursuitSprint.speedMultiplier's own `max`
-- field below (Part A of the owner's "keep the speed and stamina editing
-- where i can edit it to as high as i want" request). Was a hardcoded
-- 3.0; now read fresh from config.lua's `Config.MaxSpeedScentMultiplier`
-- at this file's own load time (Config is guaranteed already fully
-- populated by this point -- see "FXMANIFEST PLACEMENT" above).
-- ======================================================================

--- Owner-editable ceiling for speedMultiplier/scentRangeMultiplier, read
--- fresh from config.lua at this file's own load time. CLAMPS AND WARNS,
--- never asserts -- a bare top-level `assert` on a value an OPERATOR can
--- reach (a mistyped config.lua) would silently abort every registration
--- in THIS FILE from that point on, for the rest of this resource's
--- uptime -- see server/cooldowns.lua's own ResolveConfiguredThresholdMs
--- doc comment for the incident this mirrors. Falls back to 10.0
--- (config.lua's own shipped default) for anything that is not a real,
--- positive, finite number: missing, non-numeric, NaN, infinity, zero, or
--- negative. Duplicated in server/xptiers.lua and server/k9profiles.lua
--- rather than shared -- this resource's established "no cross-file
--- `local` import mechanism" convention (see server/k9profiles.lua's own
--- header, "BOUNDS -- REUSED, NOT REINVENTED").
--- @return number
local function ResolveMaxSpeedScentMultiplier()
    local fallback = 10.0
    local raw = Config and Config.MaxSpeedScentMultiplier
    local value = tonumber(raw)
    if value == nil or value ~= value or value == math.huge or value == -math.huge or value <= 0 then
        print(('[John-K9] runtimecontrol: Config.MaxSpeedScentMultiplier is missing or not a valid positive number (found: %s). Using the built-in fallback of %s instead -- find Config.MaxSpeedScentMultiplier in config.lua and set it to a positive number.'):format(tostring(raw), tostring(fallback)))
        return fallback
    end
    return value
end

-- ======================================================================
-- TUNABLE REGISTRY -- explicit allowlist. See header "PART 1B" for the
-- three exclusion rules this list was built under. `path` navigates the
-- global `Config` table; `integer = true` additionally requires a whole
-- number (never accepted with a fractional part, matching
-- server/highcommand.lua's own IsValidGrantAmount discipline for a
-- different value).
-- ======================================================================
local TUNABLE_REGISTRY = {
    ['LeashMaxDistance']                       = { path = { 'LeashMaxDistance' },                             min = 3.0,   max = 20.0,      integer = false },
    ['CertifyProximityMeters']                 = { path = { 'CertifyProximityMeters' },                       min = 1.0,   max = 15.0,      integer = false },
    ['VehicleInteractMeters']                  = { path = { 'VehicleInteractMeters' },                        min = 1.0,   max = 8.0,       integer = false },

    ['Tracking.Scent.searchCooldownMs']        = { path = { 'Tracking', 'Scent', 'searchCooldownMs' },        min = 1000,  max = 60000,     integer = true },
    ['Tracking.Scent.relayCooldownMs']         = { path = { 'Tracking', 'Scent', 'relayCooldownMs' },         min = 100,   max = 10000,     integer = true },
    ['Tracking.Scent.maxRange']                = { path = { 'Tracking', 'Scent', 'maxRange' },                min = 5.0,   max = 100.0,     integer = false },
    ['Tracking.Scent.maxAgeSeconds']           = { path = { 'Tracking', 'Scent', 'maxAgeSeconds' },           min = 30,    max = 3600,      integer = true },

    ['Tracking.Blood.searchCooldownMs']        = { path = { 'Tracking', 'Blood', 'searchCooldownMs' },        min = 1000,  max = 60000,     integer = true },
    ['Tracking.Blood.relayCooldownMs']         = { path = { 'Tracking', 'Blood', 'relayCooldownMs' },         min = 100,   max = 10000,     integer = true },
    ['Tracking.Blood.maxRange']                = { path = { 'Tracking', 'Blood', 'maxRange' },                min = 5.0,   max = 100.0,     integer = false },
    ['Tracking.Blood.maxAgeSeconds']           = { path = { 'Tracking', 'Blood', 'maxAgeSeconds' },           min = 30,    max = 3600,      integer = true },

    ['Tracking.Gunpowder.searchCooldownMs']    = { path = { 'Tracking', 'Gunpowder', 'searchCooldownMs' },    min = 1000,  max = 60000,     integer = true },
    ['Tracking.Gunpowder.relayCooldownMs']     = { path = { 'Tracking', 'Gunpowder', 'relayCooldownMs' },     min = 100,   max = 10000,     integer = true },
    ['Tracking.Gunpowder.maxRange']            = { path = { 'Tracking', 'Gunpowder', 'maxRange' },            min = 5.0,   max = 100.0,     integer = false },
    ['Tracking.Gunpowder.maxAgeSeconds']       = { path = { 'Tracking', 'Gunpowder', 'maxAgeSeconds' },       min = 30,    max = 3600,      integer = true },

    ['AdminAudit.CommandCooldownMs']           = { path = { 'AdminAudit', 'CommandCooldownMs' },              min = 250,   max = 60000,     integer = true },
    ['AdminAudit.MaxResults.Certifications']   = { path = { 'AdminAudit', 'MaxResults', 'Certifications' },   min = 1,     max = 100,       integer = true },
    ['AdminAudit.MaxResults.Partnerships']     = { path = { 'AdminAudit', 'MaxResults', 'Partnerships' },     min = 1,     max = 100,       integer = true },
    ['AdminAudit.MaxResults.SearchLog']        = { path = { 'AdminAudit', 'MaxResults', 'SearchLog' },        min = 1,     max = 100,       integer = true },

    ['CertificationExpiryCheckIntervalMs']     = { path = { 'CertificationExpiryCheckIntervalMs' },           min = 30000, max = 3600000,   integer = true },

    -- ==================================================================
    -- EXPANSION PASS (2026-08-26). Every entry below was individually
    -- confirmed READ FRESH AT THE POINT OF USE by direct read of the file
    -- that consumes it, matching exclusion rule 3 above -- not assumed from
    -- a field's name or from another field's precedent. A large class of
    -- config.lua numbers were read and REJECTED for this registry along the
    -- way; see this pass's own hand-off report for the full skip list and
    -- reasoning (captured-once-at-load locals, values applied only by an
    -- independent CLIENT copy of config.lua with no server enforcement
    -- point, economy-adjacent XP/reward tables, and a handful of values a
    -- sibling file's own comment explicitly calls "a hard safety ceiling,
    -- not a server-tunable-to-anything toggle").
    -- ==================================================================

    -- server/integrations.lua (Config.Features.K9DownDispatch, rawtoplevel).
    -- `local tuning = Config.K9DownDispatch` is a TABLE REFERENCE, not a
    -- copy -- PollK9Health reads tuning.healthThreshold/minDurationMs fresh
    -- every poll pass, and the poll thread's own Wait(tuning.pollIntervalMs)
    -- re-reads pollIntervalMs every iteration. reFireCooldownMs is
    -- DELIBERATELY EXCLUDED -- it is baked once into K9DownFireCooldown's
    -- own NewCooldown(...) constructor call and never re-read afterward
    -- (Consume(src) below is called with no per-call override), the exact
    -- "constructor default" shape exclusion rule 3 rules out.
    ['K9DownDispatch.healthThreshold']          = { path = { 'K9DownDispatch', 'healthThreshold' },             min = 1,     max = 200,       integer = true },
    ['K9DownDispatch.minDurationMs']            = { path = { 'K9DownDispatch', 'minDurationMs' },                min = 0,     max = 60000,     integer = true },
    ['K9DownDispatch.pollIntervalMs']           = { path = { 'K9DownDispatch', 'pollIntervalMs' },               min = 500,   max = 30000,     integer = true },

    -- The four ScentTrailHunt.* tunables that used to live here were
    -- removed alongside the feature's own FEATURE_TIERS entry above and
    -- the feature flag itself (config.lua's own comment
    -- there has the full writeup) -- that feature's own top-level
    -- flag check returned before its tuning values were ever read, so a
    -- live tuning slider for them would have controlled
    -- nothing. Removed rather than left registered-but-inert, so the
    -- tablet's own Runtime Control screen never offers a knob for a
    -- feature that no longer runs.

    -- server/pursuitsprint.lua (Config.Features.PursuitSprint, rawtoplevel).
    -- requestRangeMeters is re-read directly off Config in the request
    -- handler (that file's own comment says so explicitly) -- genuinely
    -- live.
    --
    -- speedMultiplier/durationMs -- FORMERLY EXCLUDED, NOW INCLUDED (this
    -- pass, "make the speed boost and duration numbers genuinely editable"
    -- task). THE OLD EXCLUSION WAS CORRECT AS OF WHEN IT WAS WRITTEN: the
    -- granted-sprint event used to carry NO PAYLOAD at all, so the boost/
    -- duration were applied entirely by the K9's own client reading its own
    -- independent shared_scripts copy of config.lua -- a live edit here
    -- would have been a silent no-op for the one thing an operator was
    -- actually trying to change, exactly the failure this registry's own
    -- rule 3 exists to refuse. THE SYNC GAP IS NOW CLOSED, not just
    -- asserted closed: server/pursuitsprint.lua's request handler now reads
    -- both fields fresh off THIS live `Config.PursuitSprint` at the exact
    -- moment each grant is decided and sends them AS the
    -- 'john-k9:client:pursuitSprintGranted' event's own payload;
    -- client/pursuitsprint.lua applies whatever it was sent, never its own
    -- local config copy, for that one grant (see both files' own headers,
    -- section "EVENT CONTRACT", for the full writeup). A tablet edit here is
    -- therefore genuinely live -- it takes effect on the AFFECTED K9's NEXT
    -- grant (server/pursuitsprint.lua's own documented, deliberate choice:
    -- a burst already in flight keeps the exact value it was granted with
    -- for its own duration, never updated retroactively mid-burst -- see
    -- that file's "LIVE EDIT MID-SPRINT" note for why). RANGES: speedMultiplier's
    -- floor of 1.0 keeps a "boost" from ever becoming a same-or-worse-than-
    -- baseline slow (a non-positive/zero multiplier is refused outright by
    -- this file's own [min,max] check below, same discipline this task
    -- itself named as non-negotiable); its ceiling was a hardcoded 3.0,
    -- now OWNER-EDITABLE (this pass, coder-backend) via the SAME
    -- `Config.MaxSpeedScentMultiplier` server/xptiers.lua and
    -- server/k9profiles.lua each read through their own identical
    -- ResolveMaxSpeedScentMultiplier resolver, resolved once at this
    -- file's own load time via THIS file's own local copy of that
    -- resolver (see it declared immediately above TUNABLE_REGISTRY).
    -- Raising it is made SAFE regardless of how high it is set by
    -- infrastructure that predates this tunable entirely --
    -- client/movement.lua's RecomputeK9MoveRate() clamps the PRODUCT of
    -- every active move-rate modifier to [0.1, 2.0] (that file's own "CLAMP
    -- RANGE" header), so this tunable can never itself become the vector for
    -- an unbounded speed (see this file's own pursuitsprint.lua header, "THE
    -- BALANCE PROBLEM", for the full worst-case arithmetic, unchanged by
    -- this tunable's existence) -- see Config.MaxSpeedScentMultiplier's own
    -- comment in config.lua for the plain-English version of that same
    -- disclosure. durationMs's floor of 500ms keeps a "short
    -- burst" from ever being misread as instant/zero-duration (this file's
    -- own [min,max] check refuses a non-positive value outright -- the
    -- "does 0 mean instant or forever" ambiguity this task warns against is
    -- structurally unreachable here); its ceiling of 30000ms (30s) keeps an
    -- operator from turning a short burst into a de facto permanent buff
    -- while still leaving ample room above the shipped 5s default. NO
    -- UNBOUNDED TRAP either way: client/pursuitsprint.lua's own end-timer,
    -- generation guard, and onResourceStop reset are UNCHANGED by this
    -- tunable's existence -- every one of those already reads whatever
    -- duration/multiplier this specific grant actually carried, never a
    -- live Config re-read mid-burst, so a tablet edit landing while a burst
    -- is already running cannot strand anyone at a stale value (there is
    -- nothing stale to strand -- the running burst was never going to
    -- re-read Config again regardless). cooldownMs remains EXCLUDED (baked
    -- into PursuitCooldown's own NewCooldown constructor).
    ['PursuitSprint.requestRangeMeters']        = { path = { 'PursuitSprint', 'requestRangeMeters' },            min = 5.0,   max = 100.0,     integer = false },
    ['PursuitSprint.speedMultiplier']           = { path = { 'PursuitSprint', 'speedMultiplier' },                min = 1.0,   max = ResolveMaxSpeedScentMultiplier(), integer = false },
    ['PursuitSprint.durationMs']                = { path = { 'PursuitSprint', 'durationMs' },                     min = 500,   max = 30000,     integer = true },

    -- server/combat.lua (Config.Features.BiteAndHold / NonLethalTakedown /
    -- PropDragging, all `live`). Every entry below is read straight off
    -- `Config.Combat.*` inline, inside the request handler or the shared
    -- maintenance-thread check, on every single invocation -- confirmed by
    -- direct read, not inferred. cooldownMs/targetCooldownMs for all three
    -- mechanics are EXCLUDED (each is baked into its own NewCooldown
    -- constructor; the one exception, requestBiteHold/requestTakedown's OWN
    -- cooldown checks, was deliberately changed AWAY from a per-call Config
    -- re-read this same pass specifically to stop shadowing the safe
    -- constructor default -- see that file's own "QA sandbox repro" comment
    -- -- so re-exposing it here as a live tunable would reopen exactly the
    -- bug that change closed). healthFloor is EXCLUDED -- the server-side
    -- SetEntityHealth call on the NPC path was REMOVED as a suspected silent
    -- no-op; the real, load-bearing floor is applied entirely by
    -- client/combat.lua reading its own shared_scripts copy. ragdollFallTimeMs/
    -- ragdollFallTimeP2/AgilityAdvanced.* are EXCLUDED -- never read anywhere
    -- in server/combat.lua (grepped), client-only. NonComplianceDetection.*
    -- (biteHoldIdleCeiling/biteHoldSpeedTolerance/biteHoldViolationSamples/
    -- takedownNetDisplacementMeters/dragComplianceSlackMeters/
    -- positionSampleWindowMs) are ALL EXCLUDED even though several ARE read
    -- fresh inside SampleCompliance: the sampling thread that ever calls
    -- SampleCompliance is only created if
    -- Config.Combat.NonComplianceDetection.enabled was ALREADY true when
    -- this file loaded (`if Config.Combat.NonComplianceDetection.enabled
    -- then CreateThread(...) end`, confirmed by direct read) -- and unlike a
    -- top-level Config.Features flag, that nested boolean has no entry of
    -- its own in ListFeatures for an operator to see WHY a live edit here
    -- did nothing. positionSampleWindowMs specifically is ALSO captured once
    -- into a local (`PositionSampleWindowMs`) feeding the thread's own
    -- Wait() -- doubly non-live.
    ['Combat.BiteAndHold.range']                = { path = { 'Combat', 'BiteAndHold', 'range' },                 min = 0.5,   max = 10.0,      integer = false },
    ['Combat.BiteAndHold.maxDurationMs']        = { path = { 'Combat', 'BiteAndHold', 'maxDurationMs' },         min = 5000,  max = 60000,     integer = true },
    ['Combat.NonLethalTakedown.range']          = { path = { 'Combat', 'NonLethalTakedown', 'range' },           min = 0.5,   max = 10.0,      integer = false },
    ['Combat.NonLethalTakedown.minTargetSpeed'] = { path = { 'Combat', 'NonLethalTakedown', 'minTargetSpeed' },  min = 0.5,   max = 15.0,      integer = false },
    ['Combat.NonLethalTakedown.speedSampleWindowMs'] = { path = { 'Combat', 'NonLethalTakedown', 'speedSampleWindowMs' }, min = 100, max = 2000, integer = true },
    ['Combat.NonLethalTakedown.ragdollDurationMs'] = { path = { 'Combat', 'NonLethalTakedown', 'ragdollDurationMs' }, min = 1000, max = 30000,  integer = true },
    ['Combat.PropDragging.range']               = { path = { 'Combat', 'PropDragging', 'range' },                min = 0.5,   max = 10.0,      integer = false },
    ['Combat.PropDragging.maxDragDistance']     = { path = { 'Combat', 'PropDragging', 'maxDragDistance' },      min = 5.0,   max = 200.0,     integer = false },
    ['Combat.PropDragging.maxDragDurationMs']   = { path = { 'Combat', 'PropDragging', 'maxDragDurationMs' },    min = 5000,  max = 60000,     integer = true },

    -- A removed feature's three tuning entries lived here until
    -- 2026-09-02. Its pollIntervalMs was EXCLUDED -- that file's own
    -- comment stated outright it was "still captured once into a local (not re-read from
    -- Config every loop iteration)". retriggerCooldownMs/
    -- attackerReportCooldownMs are EXCLUDED (each baked into its own
    -- NewCooldown constructor). promptTtlMs/confirmKey are EXCLUDED -- never
    -- read server-side at all (that value is a client-local clock/keybind).

    -- server/partnership.lua (Config.Features.HandlerPartnership, live).
    -- ProximityMeters is read inline at the confirm step; RequestTTLMs is
    -- read inline when a request record is created. RequestCooldownMs is
    -- EXCLUDED (NewCooldown constructor default).
    ['Partnership.ProximityMeters']             = { path = { 'Partnership', 'ProximityMeters' },                 min = 1.0,   max = 15.0,      integer = false },
    ['Partnership.RequestTTLMs']                = { path = { 'Partnership', 'RequestTTLMs' },                    min = 5000,  max = 300000,    integer = true },

    -- server/tenure.lua (Config.Features.PartnershipTenureBonus, live).
    -- A genuine RARITY in this codebase, called out by that file's own
    -- comment in full: "this file re-reads the value every iteration" --
    -- checkIntervalMs is read fresh from Config.Partnership.TenureBonus on
    -- every single pass of the tick loop, not captured once like every
    -- sibling poll-interval this pass otherwise had to exclude.
    ['Partnership.TenureBonus.checkIntervalMs'] = { path = { 'Partnership', 'TenureBonus', 'checkIntervalMs' },  min = 10000, max = 3600000,   integer = true },

    -- server/kennel.lua (Config.Features.DeployableKennel, live).
    -- placementForwardOffsetMeters/pendingPlacementTtlMs are both read
    -- inline inside the deploy-request handler, fresh per request.
    -- deployCooldownMs is EXCLUDED (NewCooldown constructor default).
    -- interactDistanceMeters is EXCLUDED -- never read anywhere in
    -- server/kennel.lua (grepped); it is a client-only ox_target radius.
    ['DeployableKennel.placementForwardOffsetMeters'] = { path = { 'DeployableKennel', 'placementForwardOffsetMeters' }, min = 0.5, max = 10.0, integer = false },
    ['DeployableKennel.pendingPlacementTtlMs']  = { path = { 'DeployableKennel', 'pendingPlacementTtlMs' },      min = 2000,  max = 120000,    integer = true },

    -- server/propattachment.lua (Config.Features.PropAttachments,
    -- rawtoplevel). toggleCooldownMs is passed as an EXPLICIT per-call
    -- override to ToggleCooldown.Consume (never baked into the constructor)
    -- -- the same "read fresh, passed per call" shape server/admin.lua's own
    -- CommandCooldownMs already established as genuinely live.
    -- pendingConfirmTtlMs/confirmDistanceTolerance are both read inline.
    -- boneIndex/offsetX/Y/Z/rotX/Y/Z are EXCLUDED -- never read anywhere in
    -- server/propattachment.lua outside its own load-time `assert` shape
    -- checks (grepped); the actual AttachEntityToEntity call is entirely
    -- client-side, reading its own shared_scripts copy.
    ['PropAttachments.toggleCooldownMs']        = { path = { 'PropAttachments', 'toggleCooldownMs' },            min = 500,   max = 60000,     integer = true },
    ['PropAttachments.pendingConfirmTtlMs']     = { path = { 'PropAttachments', 'pendingConfirmTtlMs' },         min = 2000,  max = 120000,    integer = true },
    ['PropAttachments.confirmDistanceTolerance'] = { path = { 'PropAttachments', 'confirmDistanceTolerance' },   min = 1.0,   max = 20.0,      integer = false },

    -- server/fetch.lua (Config.Features.FetchMechanic, rawtoplevel).
    -- `local cfg = Config.FetchMechanic` inside the throw-request handler
    -- (called fresh per throw, not hoisted to file scope) reads
    -- throwForwardOffsetMeters/throwUpOffsetMeters/throwForceForward/
    -- throwForceUp/pendingThrowTtlMs live -- and UNLIKE PursuitSprint's
    -- identical-looking speedMultiplier/durationMs above, these ARE
    -- genuinely server-authoritative: the computed spawn position and force
    -- vector are sent AS the 'john-k9:client:throwFetchBallAt' payload,
    -- not left for an independent client copy to apply. maxBallLifetimeMs/
    -- pickupInteractDistanceMeters/deliverProximityMeters are each read
    -- inline at their own call sites. throwCooldownMs/pickupCooldownMs are
    -- EXCLUDED (each baked into its own NewCooldown constructor).
    -- maintenanceIntervalMs is EXCLUDED -- captured once into
    -- FETCH_MAINTENANCE_INTERVAL_MS, feeding that thread's own Wait().
    -- mouthBoneIndex/mouthOffsetX/Y/Z/mouthCarryMode are non-numeric/
    -- client-cosmetic and out of scope for this registry.
    ['FetchMechanic.throwForwardOffsetMeters']  = { path = { 'FetchMechanic', 'throwForwardOffsetMeters' },      min = 0.2,   max = 5.0,       integer = false },
    ['FetchMechanic.throwUpOffsetMeters']       = { path = { 'FetchMechanic', 'throwUpOffsetMeters' },           min = 0.2,   max = 5.0,       integer = false },
    ['FetchMechanic.throwForceForward']         = { path = { 'FetchMechanic', 'throwForceForward' },             min = 1.0,   max = 50.0,      integer = false },
    ['FetchMechanic.throwForceUp']              = { path = { 'FetchMechanic', 'throwForceUp' },                  min = 0.0,   max = 30.0,      integer = false },
    ['FetchMechanic.maxBallLifetimeMs']         = { path = { 'FetchMechanic', 'maxBallLifetimeMs' },             min = 30000, max = 1800000,   integer = true },
    ['FetchMechanic.pickupInteractDistanceMeters'] = { path = { 'FetchMechanic', 'pickupInteractDistanceMeters' }, min = 0.5, max = 10.0,       integer = false },
    ['FetchMechanic.pendingThrowTtlMs']         = { path = { 'FetchMechanic', 'pendingThrowTtlMs' },             min = 2000,  max = 120000,    integer = true },
    ['FetchMechanic.deliverProximityMeters']    = { path = { 'FetchMechanic', 'deliverProximityMeters' },        min = 0.5,   max = 15.0,      integer = false },

    -- server/medkit.lua (Config.Features.K9Medkit, live). range/
    -- healthRestore is read inline at its own call
    -- sites, genuinely fresh, confirmed by direct read.
    --
    -- cooldownMs is NOW INCLUDED (issue-closer sweep, 2026-08-26) -- this
    -- entry used to exclude it, on real grounds at the time: the sweep's
    -- own staleAfterMs was a captured-once-at-load local
    -- (`local MedkitBaseCooldownMs = ResolveConfiguredThresholdMs(
    -- Config.K9Medkit.cooldownMs, ...)`), so a LIVE RAISE through this
    -- registry would have been silently undermined -- the sweep would keep
    -- pruning a target's cooldown-tracker entry using the OLD, now-too-short
    -- window, letting the cooldown reset early. THAT BUG IS FIXED, verified
    -- by direct read of server/medkit.lua: `ResolveMedkitBaseCooldownMs()`
    -- (a tiny, cheap, non-yielding function, never cached) is now called
    -- FRESH both by the per-request gate AND, every single tick, inside the
    -- StartSweep prune callback itself (`local staleAfterMs =
    -- ResolveMedkitBaseCooldownMs() * 2`) -- see that file's own "ACTUAL
    -- FIX" comment on `ResolveMedkitBaseCooldownMs` for the full writeup,
    -- including the self-corrected first attempt (a frozen local) that
    -- would have reopened this exact gap from the other direction. Both
    -- read paths now agree with each other and with whatever
    -- Config.K9Medkit.cooldownMs currently holds, satisfying rule 3 the
    -- same way every other included tunable does. See
    -- tests/runtimecontrol_spec.lua's own "K9Medkit.cooldownMs is now safely
    -- exposed" case for the regression guard, inverted from this entry's
    -- old "must never be exposed" pinning test.
    ['K9Medkit.cooldownMs']                     = { path = { 'K9Medkit', 'cooldownMs' },                          min = 1000,  max = 300000,    integer = true },
    ['K9Medkit.range']                          = { path = { 'K9Medkit', 'range' },                              min = 0.5,   max = 10.0,      integer = false },
    ['K9Medkit.healthRestore']                  = { path = { 'K9Medkit', 'healthRestore' },                      min = 1,     max = 200,       integer = true },

    -- server/inventory.lua (Config.Features.K9Inventory, live).
    -- interactRange is read live inline at the stash-open proximity check.
    -- slots/maxWeight are DELIBERATELY EXCLUDED, not because the read is
    -- stale, but because the read only happens ONCE PER CITIZENID PER
    -- SESSION: EnsureK9Stash memoizes `EnsuredK9Stashes[citizenid] = true`
    -- after the first successful RegisterStash call and never calls
    -- RegisterStash again for that citizenid this session. A live edit
    -- would apply to a K9 opening their stash for the very first time this
    -- session and be a silent no-op for every K9 who already had -- exactly
    -- the "wrong applied-live claim with no distinguishing symptom" rule 3
    -- warns against.
    ['K9Inventory.interactRange']               = { path = { 'K9Inventory', 'interactRange' },                   min = 0.5,   max = 10.0,      integer = false },

    -- server/main.lua (Config.Features.DoorInteraction, live).
    -- interactDistance and scratchCooldownMs are each read live inline
    -- (scratchCooldownMs passed as an explicit per-call override to
    -- IsOnCooldown, same live shape as this section's other cooldowns).
    ['DoorInteraction.interactDistance']        = { path = { 'DoorInteraction', 'interactDistance' },            min = 0.5,   max = 5.0,       integer = false },
    ['DoorInteraction.scratchCooldownMs']       = { path = { 'DoorInteraction', 'scratchCooldownMs' },           min = 500,   max = 60000,     integer = true },

    -- server/search.lua (Config.Features.SearchZones, live).
    -- vehicleSearchDistance/personSearchDistance/searchCooldownMs/
    -- sniffAnimDurationMs are all read live inline (the latter two both
    -- passed as explicit per-call overrides to IsOnCooldown --
    -- sniffAnimDurationMs doubles as the per-source, any-target flood floor,
    -- that file's own comment explaining exactly why). alertBroadcastRadius
    -- is DELIBERATELY EXCLUDED -- that file's own onResourceStart assert
    -- says outright it "is a hard safety ceiling, not a
    -- server-tunable-to-anything toggle": a contraband alert is
    -- distance-filtered specifically so it never leaks a specific
    -- vehicle/person's flagged status to an accomplice server-wide, and
    -- this registry takes that sentence at face value rather than exposing
    -- it with a matching cap anyway.
    ['SearchZones.vehicleSearchDistance']       = { path = { 'SearchZones', 'vehicleSearchDistance' },           min = 0.5,   max = 10.0,      integer = false },
    ['SearchZones.personSearchDistance']        = { path = { 'SearchZones', 'personSearchDistance' },            min = 0.5,   max = 10.0,      integer = false },
    ['SearchZones.sniffAnimDurationMs']         = { path = { 'SearchZones', 'sniffAnimDurationMs' },             min = 1000,  max = 30000,     integer = true },
    ['SearchZones.searchCooldownMs']            = { path = { 'SearchZones', 'searchCooldownMs' },                min = 1000,  max = 120000,    integer = true },

    -- server/appearance.lua (Config.Features.HighCommand-adjacent, always
    -- registered). modelLoadTimeoutMs feeds ApplyRequestTtlMs(), called
    -- fresh every swap request -- a server-side backstop window distinct
    -- from (and in addition to) the client's own independent load timeout.
    ['K9Appearance.modelLoadTimeoutMs']         = { path = { 'K9Appearance', 'modelLoadTimeoutMs' },             min = 2000,  max = 60000,     integer = true },

    -- server/wellbeing.lua (Config.Features.FatigueSystem, `live`). Every value below is
    -- read directly off Config.Wellbeing.* inline inside the callback or
    -- tick-loop body that consumes it, confirmed by direct read.
    -- tickIntervalMs is EXCLUDED -- captured once into TICK_INTERVAL_MS,
    -- feeding the shared tick thread's own Wait() and every dtSeconds
    -- calculation.
    --
    -- Fatigue.speedPenaltyThreshold/speedPenaltyMultiplier,
    -- Mood.performancePenaltyThreshold/performancePenaltyMultiplier, and
    -- Injury.sprintBlockThreshold/jumpBlockThreshold/speedPenaltyMultiplier
    -- -- FORMERLY EXCLUDED, NOW INCLUDED (this pass, "make the speed boost
    -- and stamina numbers genuinely editable" task, widened by the owner to
    -- every K9 stat). THE OLD EXCLUSION WAS CORRECT WHEN WRITTEN: these
    -- seven move-rate/input-block values used to be applied entirely by
    -- client/movement.lua and client/wellbeing.lua reading their own
    -- shared_scripts copy, with no server push of any kind -- "a live dial
    -- this file cannot even confirm reaches the client" (this comment's own
    -- prior wording). THE SYNC GAP IS NOW CLOSED, not just asserted closed:
    -- server/wellbeing.lua's SnapshotOf (the SAME function that already
    -- piggybacks the five `featureFlags` booleans onto its existing
    -- `wellbeingUpdate` tick push / `getWellbeingSnapshot` on-demand fetch)
    -- now ALSO piggybacks these seven numbers as `wellbeingTunables` --
    -- extending the existing channel, never a new one. client/wellbeing.lua
    -- mirrors them into `LiveWellbeingTunables` and reads that instead of
    -- its own static Config copy at every point of use (see that file's own
    -- header "LIVE WELLBEING TUNABLES" for the full writeup, including the
    -- MID-EFFECT decision: unlike PursuitSprint's one-shot grant, these are
    -- continuous per-tick judgments re-evaluated every tick regardless, so a
    -- live edit updates an ALREADY-APPLIED penalty/block on its very next
    -- recompute rather than waiting for a fresh grant -- the right choice
    -- for a value class server/wellbeing.lua's own tick loop was already
    -- re-deciding from scratch every cycle). RANGES: every *Threshold below
    -- is bounded to [1, 99] -- never 0 (a non-positive threshold could never
    -- misread as "always on" the way a cooldown does, since a stat can be 0
    -- but never negative, but 0 would still mean "only exactly-zero
    -- triggers it", a degenerate no-op nobody configuring this dial would
    -- intend) and never >= 100 (this resource's own shipped `max` for each
    -- of these three stats), so a threshold can never be set to the exact
    -- ceiling value where it would read as "the penalty applies to every
    -- non-maximum stat value" by surprise. Every *Multiplier below is
    -- bounded to [0.1, 1.0] -- the floor of 0.1 matches
    -- client/movement.lua's own RecomputeK9MoveRate() composer floor (that
    -- file's "CLAMP RANGE [0.1, 2.0]" header) so this tunable is never
    -- itself the source of a non-positive/zero move-rate input; the ceiling
    -- of 1.0 keeps a "penalty" multiplier from being configured into an
    -- accidental BUFF (a value above 1.0 would speed the K9 up while
    -- supposedly penalizing it -- nonsensical for this field's own documented
    -- purpose, refused outright rather than silently accepted). NO
    -- UNBOUNDED TRAP: neither this registry's own range check nor the
    -- client-side mirror change anything about client/wellbeing.lua's
    -- existing, UNCHANGED removal paths (LiveFeatureFlags gating that
    -- already resets each modifier to 1.0 the instant its owning flag is
    -- off, the Injury block thread's own per-iteration re-check, this file's
    -- own onResourceStop-independent nature since these are pure config
    -- reads with no per-effect state of their own to leak) -- a live edit to
    -- any of these seven can only ever change WHICH threshold/multiplier the
    -- existing, already-reviewed removal machinery uses, never bypass it.
    -- Fatigue.max is ALSO EXCLUDED even
    -- though it is read live server-side -- a stat's `max` is ALSO
    -- read independently by the client for its own HUD gauge scaling, and a
    -- server-only change here would desync the server's clamp ceiling from
    -- the client's displayed one with no mechanism to keep them in sync.
    -- A removed subsystem's gunfire/hesitation tunables were ALL EXCLUDED
    -- on purpose while they existed -- they were the live, disclosed,
    -- FORGEABLE lever behind a real combat-lockout interaction, and
    -- loosening any one of them shifted the balance of an already-tricky
    -- security tradeoff. Its recovery-side tunables were kept for the
    -- opposite reason: widening one only ever helped the victim, never the
    -- forger.
    ['Wellbeing.Fatigue.speedPenaltyThreshold']  = { path = { 'Wellbeing', 'Fatigue', 'speedPenaltyThreshold' },  min = 1,     max = 99,        integer = false },
    ['Wellbeing.Fatigue.speedPenaltyMultiplier'] = { path = { 'Wellbeing', 'Fatigue', 'speedPenaltyMultiplier' }, min = 0.1,   max = 1.0,       integer = false },
    -- STAMINA DURATION (OWNER DIRECTIVE, this pass: "make sure high command
    -- can edit the ability to make stamina last longer or even
    -- permanently"). Config.Wellbeing.Fatigue IS this resource's own
    -- "stamina" system in its own already-established vocabulary -- see the
    -- two entries immediately above, whose own comment already calls this
    -- the "'make the speed boost and stamina numbers genuinely editable'
    -- task", and client/wellbeing.lua's "LIVE WELLBEING TUNABLES" header,
    -- which uses the identical phrase. That earlier pass wired WHAT HAPPENS
    -- once a K9 is tired (speedPenaltyThreshold/speedPenaltyMultiplier,
    -- immediately above) but never the one field that decides HOW LONG
    -- stamina lasts before that penalty ever applies: sprintDecayPerTick,
    -- the sole per-tick decrement server/wellbeing.lua's TickWellbeing ever
    -- subtracts from `stats.fatigue` (its own FatigueSystem branch, `stats.fatigue
    -- = Clamp(stats.fatigue - Config.Wellbeing.Fatigue.sprintDecayPerTick, 0,
    -- max)`) -- confirmed READ FRESH at that exact call site, never captured
    -- to a local, so this entry needs no client-side push of any kind
    -- (unlike the two entries above, which DO reach client/wellbeing.lua's
    -- move-rate composer and therefore ride the separate `wellbeingTunables`
    -- snapshot channel): a live edit here changes what the SERVER'S OWN NEXT
    -- TICK decrements by, full stop, no restart, no second wire-up.
    --
    -- MIN = 0, DELIBERATELY DIFFERENT FROM EVERY SIBLING PER-TICK FIELD
    -- BELOW (every sibling recovery rate floors at 0.1, never 0): those are
    -- RECOVERY rates, where 0 would mean "this stat can never recover" --
    -- never something an operator tuning recovery would want. This field is
    -- the opposite direction, HARM, where 0 has a genuine, intended meaning
    -- this task explicitly asked for: `stats.fatigue - 0` is an EXACT no-op
    -- every single tick, forever -- fatigue can never fall below wherever it
    -- already is, for as long as this stays 0, no matter how many ticks the
    -- server runs. That is genuinely PERMANENT stamina, not merely a very
    -- slow drain that eventually runs out (the exact failure mode this task
    -- warned against) -- proven directly in tests/wellbeing_spec.lua by
    -- running many simulated ticks of continuous sprinting and asserting
    -- fatigue never moves. A "very large but finite" value (this file's own
    -- fallback advice for a field with no natural zero) is deliberately NOT
    -- used here: dividing by even an enormous finite multiplier still leaves
    -- a nonzero decay that would eventually cross the threshold, which is
    -- worse than an exact, provable zero when one is available.
    -- MAX = 20.0 -- the SAME ceiling already reviewed and shipped for every
    -- sibling per-tick field below, reused rather than picked fresh: more
    -- than enough for an operator who wants stamina to drain almost
    -- instantly (20/tick clears the shipped 70-point max-to-threshold gap in
    -- 4 ticks), and small enough that Clamp's own [0, Fatigue.max] bound is
    -- never at any real risk from one tick's subtraction.
    ['Wellbeing.Fatigue.sprintDecayPerTick']     = { path = { 'Wellbeing', 'Fatigue', 'sprintDecayPerTick' },     min = 0,     max = 20.0,      integer = false },
    -- NATIVE SPRINT STAMINA ASSIST -- see config.lua's own comment on this
    -- exact field for the full "why this is separate from the Fatigue
    -- fields above" writeup: this is GTA/FiveM's OWN built-in player
    -- sprint-stamina limit (the same value client/hud.lua's "Stamina" HUD
    -- row displays), not this resource's custom Fatigue stat. [0, 1.0] is
    -- not a bound this pass invented -- it is RESTORE_PLAYER_STAMINA's own
    -- documented parameter range (FiveM's natives.json: "seems to be a
    -- percentage that ranges from 0.0 to 1.0 (1.0 being 100%)") -- a value
    -- outside it has no documented meaning for the native this feeds,
    -- exactly the "a number that... goes [somewhere undefined] must not be
    -- [reachable]" risk this registry's own bounds exist to prevent. 0
    -- (the shipped default) is a genuine, safe value here too: client/wellbeing.lua
    -- never calls RestorePlayerStamina at all while this is 0, so a server
    -- that never raises it sees byte-identical vanilla stamina behaviour to
    -- before this pass -- no regression by default. Read fresh by
    -- client/wellbeing.lua's own LiveWellbeingTunables mirror (piggybacked
    -- on the SAME wellbeingUpdate/getWellbeingSnapshot channel the other
    -- Wellbeing.* tunables above already use), not captured once -- a live
    -- edit reaches an already-connected K9 within one
    -- Config.Wellbeing.tickIntervalMs, same as every sibling entry below.
    ['Wellbeing.Fatigue.nativeStaminaRestorePercent'] = { path = { 'Wellbeing', 'Fatigue', 'nativeStaminaRestorePercent' }, min = 0.0, max = 1.0, integer = false },
    -- config.lua's own comment on this exact field: "CONFIGURABLE: set to 0
    -- to disable entirely... or any value in [0, Injury.max]" -- the [0,100]
    -- bound below is not this pass's own judgment call, it is that comment's
    -- explicitly documented safe range, transcribed.

    -- server/bonetool.lua (Config.Features.BoneSweepDevTool, onstart --
    -- ALSO requires the john_k9_enable_bone_dev_tool convar, checked once
    -- at onResourceStart, and a boss-rank caller regardless of this flag --
    -- see that feature's own FEATURE_TIERS note above, already disclosed on
    -- the tablet's features panel). CommandCooldownMs is passed as an
    -- explicit per-call override to BoneToolCooldown.Consume (never baked
    -- into the constructor); MaxBoneIndex is read live inline where a
    -- caller-requested index is clamped. Both are dev-tool-only in practice
    -- but genuinely live and genuinely safe -- a debug marker sweep, never
    -- networked, never touching another player.
    ['BoneSweepTool.CommandCooldownMs']         = { path = { 'BoneSweepTool', 'CommandCooldownMs' },             min = 100,   max = 10000,     integer = true },
    ['BoneSweepTool.MaxBoneIndex']              = { path = { 'BoneSweepTool', 'MaxBoneIndex' },                  min = 1,     max = 500,       integer = true },

    -- ==================================================================
    -- OWNER DIRECTIVE (2026-08-26), stated twice, verbatim: "High command
    -- can grant anything they want to themselves xp promotions permissions
    -- etc" / "If its high command they should have the ability to grant
    -- whatever they want edit whatever they want etc." This section opens
    -- the two POLICY exclusion rules stated in this file's own header
    -- above ("PART 1B", rules 1 and 2) -- Config.HighCommand.*, every
    -- numeric key under Config.XP, and Config.CertificationExpiryDays/
    -- WarningDays ("anything governing who may do what"). These are
    -- POLICY exclusions being deliberately overridden by the owner's own
    -- instruction, NOT technical "cannot be read live" exclusions -- every
    -- OTHER exclusion further above this point in this table
    -- (SearchZones.alertBroadcastRadius and the other forgery-adjacent
    -- values) is UNCHANGED and remains correctly excluded; opening a
    -- POLICY restriction is not licence to also open a CORRECTNESS/SECURITY
    -- one that happens to sit near it. (K9Medkit.cooldownMs used to be
    -- named here too, as a technical exclusion -- it no longer is one,
    -- since server/medkit.lua's own sweep now reads it fresh; see that
    -- key's own TUNABLE_REGISTRY entry above for the full correction. Not
    -- an example of this section's POLICY-vs-technical distinction any
    -- more, so it is removed from this list rather than left to imply the
    -- old exclusion still holds.)
    --
    -- WHAT IS DELIBERATELY STILL **NOT** OPENED, from this same directive,
    -- and why -- read before assuming an omission here is an oversight:
    --   * Config.Departments (the `highCommandGrade`/`certifierGrade`/etc.
    --     rank thresholds that literally DEFINE who is high command) --
    --     NEVER a candidate for this registry, at any point, for any
    --     reason. This task's own non-negotiable: widening WHAT high
    --     command may edit is the decision; widening WHO COUNTS AS high
    --     command is a different one this pass must not make, and a
    --     two-hop path where editing a tunable could promote its own
    --     editor into high command would defeat this entire mechanism's
    --     one real safety property. tests/runtimecontrol_spec.lua's own
    --     "no TUNABLE_REGISTRY path may ever touch Config.Departments"
    --     regression test exists specifically to keep this true by
    --     construction, not merely by this comment's promise.
    --   * Config.HighCommand.allowSelfGrant -- a BOOLEAN, not a number, so
    --     it is not a candidate for this registry's own mechanism at all
    --     (SetTunable's own `isFiniteNumber` check refuses anything that
    --     is not a number by construction, further below) -- and it is
    --     squarely the OTHER agent's self-GRANT scope in
    --     server/highcommand.lua/server/permissions.lua, which this task's
    --     own instruction explicitly says not to touch.
    --   * Config.XP.mintXpForNpcCombatTargets (boolean) and
    --     Config.XP.scopePerCitizenidOrJob (a fixed enum string,
    --     server/progression.lua's own onResourceStart currently asserts
    --     it must be exactly 'citizenid') -- same "not a number, no
    --     mechanism for it" reasoning as allowSelfGrant above.
    --   * Config.XPTiers (the tier threshold/multiplier table) -- NOT
    --     named by this file's own original exclusion rule 1 at all (that
    --     rule only ever named Config.XP and Config.HighCommand), and
    --     server/xptiers.lua is on this task's own DO-NOT-EDIT list, which
    --     makes independently re-confirming its own "read fresh at point
    --     of use" behaviour (this registry's own rule 3) a heavier lift
    --     than this pass's owner-directed scope actually asked for. Left
    --     out of this pass deliberately, reported as a candidate for a
    --     FUTURE pass if the owner wants it too, not silently forgotten.
    -- ==================================================================

    -- Config.HighCommand.maxXpPerGrant / grantCooldownMs
    -- (server/highcommand.lua, NOT edited by this pass -- read-only
    -- audit). Both confirmed read FRESH at their point of use:
    -- '/k9givexp' AND tabletGiveXp both re-read
    -- Config.HighCommand.maxXpPerGrant (IsValidGrantAmount's own call
    -- site) / Config.HighCommand.grantCooldownMs
    -- (HighCommandGrantCooldown.Consume's own call site) LIVE on every
    -- single invocation -- a live edit here genuinely changes the
    -- ceiling/cooldown for the NEXT grant, no restart needed.
    --
    -- ONE DISCLOSED PARTIAL LIVENESS, same class as this file's other
    -- "request-time gate is live, registration is not" entries further
    -- above: whether '/k9givexp' gets REGISTERED AT ALL is decided ONCE,
    -- at server/highcommand.lua's own onResourceStart, from THAT boot's
    -- STARTING Config.HighCommand.maxXpPerGrant value (must already be a
    -- valid positive finite number, or the command is never registered
    -- this session at all -- that file's own "infinite maxXpPerGrant
    -- DISABLES '/k9givexp'" comment) -- raising/lowering it live through
    -- this registry cannot retroactively register a command that never
    -- was, if config.lua itself shipped an invalid starting value. Not
    -- relevant on a normal boot -- the shipped default (5000) is valid.
    --
    -- BOUNDS, NOT LITERALLY "ANYTHING": max = 1,000,000 is a deliberately
    -- enormous but still FINITE ceiling -- "whatever they want" does not
    -- mean literally unbounded/math.huge, which server/highcommand.lua's
    -- own registration guard treats as INVALID and refuses to ever
    -- register '/k9givexp' for at all (see the disclosure above) -- a
    -- finite max, however large, can never accidentally trip that guard
    -- the way a literal infinity could. grantCooldownMs's min of 100ms
    -- mirrors this file's own cooldowns.lua-footgun discipline (0 is never
    -- in range -- see header) even though config.lua's own comment on this
    -- field says this specific cooldown is an anti-fat-finger guard, not
    -- an abuse limit.
    --
    -- NOT SUBJECT TO THE XP MINT BUDGET -- disclosed for the operator's
    -- own risk awareness, not because it changes this entry's bounds:
    -- '/k9givexp' calls AwardXPDirect, NOT AwardXP -- server/progression.lua's
    -- own header comment on AwardXPDirect states outright it is
    -- "Deliberately NOT subject to AwardXPCooldown or the shared XP mint
    -- budget." Raising maxXpPerGrant therefore has NO interaction with,
    -- and is not bounded by, XP_MINT_BUDGET_CAP_XP -- unlike
    -- Config.XP.awards.* immediately below, which very much is.
    ['HighCommand.maxXpPerGrant']       = { path = { 'HighCommand', 'maxXpPerGrant' },   min = 1,   max = 1000000, integer = true },
    ['HighCommand.grantCooldownMs']     = { path = { 'HighCommand', 'grantCooldownMs' }, min = 100, max = 600000,  integer = true },

    -- Config.XP.awards.* / trackArrivalRadius / trackArrivalTTLMs
    -- (server/progression.lua, NOT edited by this pass -- read-only
    -- audit). Every `awards` key is read fresh inside AwardXP's own
    -- `Config.XP.awards[actionKey]` lookup, on every call, confirmed by
    -- direct read; trackArrivalRadius/trackArrivalTTLMs are likewise read
    -- inline wherever a track-arrival report is validated.
    --
    -- A REAL FOOTGUN FOUND WHILE OPENING THIS, NOT PRE-EXISTING IN THIS
    -- REGISTRY, WHICH THIS PASS'S OWN [min,max] BOUNDS EXIST SPECIFICALLY
    -- TO PREVENT: server/progression.lua has its OWN bare
    -- `assert(amount <= XP_MINT_BUDGET_CAP_XP, ...)` for every single
    -- Config.XP.awards[*] value, checked ONCE, in a loop over every award
    -- key, at that file's own onResourceStart (XP_MINT_BUDGET_CAP_XP =
    -- 3600, a LOCAL constant in that file -- not itself part of Config,
    -- and therefore not reachable by this registry's own `path` mechanism
    -- at all). Before this pass, that assert could only ever fail against
    -- a hand-edited config.lua, caught by whoever edited it, at the exact
    -- moment they edited it. AFTER opening these as tunables, if any
    -- Config.XP.awards.* entry were left tunable ABOVE 3600, a
    -- high-command officer could set one live via this registry's own
    -- SetTunable (which succeeds immediately -- nothing re-validates
    -- against that OTHER file's own assert at the moment of the tunable
    -- write) -- but the persisted override would then be RE-APPLIED, by
    -- THIS FILE's own onResourceStart handler, BEFORE
    -- server/progression.lua's onResourceStart ever runs (this file is
    -- required to load, and therefore register onResourceStart, before
    -- every other file -- see header "FXMANIFEST PLACEMENT") -- meaning
    -- Config.XP.awards.<key> would already be the too-large value the
    -- MOMENT server/progression.lua's own bare assert runs, on the very
    -- next restart, throwing an uncaught error -- precisely the "one bad
    -- assert silently kills every registration below it" failure this
    -- task's own brief warns against, and this file did not previously
    -- have any way to trigger since nothing here could ever write to
    -- Config.XP.awards before this pass. CLOSED HERE, not in
    -- server/progression.lua (not edited this pass, not in this pass's
    -- file list): every Config.XP.awards.* entry's `max` below is capped
    -- at EXACTLY 3600 (XP_MINT_BUDGET_CAP_XP, transcribed as a literal
    -- since that constant is not itself part of Config and so has no
    -- `path` this registry could point at) -- SetTunable's own [min,max]
    -- check already refuses anything above that BEFORE it is ever
    -- persisted or applied, so this specific assert can never be tripped
    -- through this registry, by construction, regardless of which single
    -- award key is being tuned (that assert's own loop applies the
    -- identical 3600 ceiling to every key in Config.XP.awards uniformly).
    -- IF XP_MINT_BUDGET_CAP_XP IS EVER CHANGED in server/progression.lua,
    -- these `max` values must be re-reviewed together with it -- they are
    -- NOT independently derived, and this comment is the only place that
    -- relationship is recorded.
    ['XP.awards.searchContrabandFound']  = { path = { 'XP', 'awards', 'searchContrabandFound' },  min = 0, max = 3600, integer = true },
    ['XP.awards.trackSourceResolved']    = { path = { 'XP', 'awards', 'trackSourceResolved' },    min = 0, max = 3600, integer = true },
    ['XP.awards.biteHoldSuccess']        = { path = { 'XP', 'awards', 'biteHoldSuccess' },        min = 0, max = 3600, integer = true },
    ['XP.awards.takedownSuccess']        = { path = { 'XP', 'awards', 'takedownSuccess' },        min = 0, max = 3600, integer = true },
    ['XP.awards.coopSearchBonus']        = { path = { 'XP', 'awards', 'coopSearchBonus' },        min = 0, max = 3600, integer = true },
    ['XP.awards.partnershipTenure1Day']  = { path = { 'XP', 'awards', 'partnershipTenure1Day' },  min = 0, max = 3600, integer = true },
    ['XP.awards.partnershipTenure7Day']  = { path = { 'XP', 'awards', 'partnershipTenure7Day' },  min = 0, max = 3600, integer = true },
    ['XP.awards.partnershipTenure30Day'] = { path = { 'XP', 'awards', 'partnershipTenure30Day' }, min = 0, max = 3600, integer = true },

    -- trackArrivalRadius/trackArrivalTTLMs are NOT part of Config.XP.awards
    -- (they are separate top-level Config.XP fields), so the mint-budget
    -- structural-guard loop described above (which iterates
    -- `pairs(Config.XP.awards)` specifically) never touches them at all --
    -- no interaction with XP_MINT_BUDGET_CAP_XP, and no shared ceiling
    -- with the awards above. Bounds below are ordinary radius/TTL
    -- reasoning, matching this registry's own similar entries elsewhere
    -- (e.g. Partnership.ProximityMeters, DeployableKennel.pendingPlacementTtlMs).
    ['XP.trackArrivalRadius']            = { path = { 'XP', 'trackArrivalRadius' },               min = 1.0,   max = 20.0,     integer = false },
    ['XP.trackArrivalTTLMs']             = { path = { 'XP', 'trackArrivalTTLMs' },                min = 5000,  max = 600000,   integer = true },

    -- Config.CertificationExpiryDays / Config.CertificationExpiryWarningDays
    -- (server/certifications/, NOT edited by this pass -- read-only
    -- audit). This file's own header (PART 1B, exclusion rule 2)
    -- previously excluded these on a POLICY ground ("an instant policy
    -- change to how long every future grant's clock runs is a real
    -- decision an operator should make in config.lua, not a live dial") --
    -- overridden by the owner's own explicit "edit whatever they want"
    -- instruction this pass. Both are confirmed read fresh at their point
    -- of use (ResolveConfiguredExpiryDays/ResolveConfiguredExpiryWarningDays,
    -- called fresh from GrantCertification/RenewCertification/
    -- CheckAndNotifyExpiry -- confirmed by direct read), and BOTH already
    -- have their own clamp-and-warn discipline in that file (never a bare
    -- assert -- a misconfigured value there degrades to "no expiry" /
    -- falls back to the built-in 7-day default, with a one-time console
    -- warning, never a crash) -- this registry's own [min,max] simply
    -- keeps a live edit inside the same "positive number" contract that
    -- file already enforces on its own. ONLY FUTURE grants/renewals are
    -- affected by a live edit here -- an already-granted certification's
    -- own stored expiry timestamp is never rewritten retroactively by
    -- either of these. Not marked `integer` -- neither file asserts a
    -- whole-number day count, and the `* 86400` arithmetic downstream
    -- (CheckAndNotifyExpiry) is exact for a fractional value too.
    ['CertificationExpiryDays']        = { path = { 'CertificationExpiryDays' },        min = 1, max = 3650, integer = false },
    ['CertificationExpiryWarningDays'] = { path = { 'CertificationExpiryWarningDays' }, min = 1, max = 365,  integer = false },

    -- ==================================================================
    -- Config.Tracking.ScentVision.* (server/tracking.lua, NOT edited by
    -- this pass -- read-only audit; ScentVision itself is coder-frontend/
    -- coder-architect's feature, landed concurrently with this pass, not
    -- part of the owner directive above). Spec supplied by coder-frontend
    -- (who did the implementation), each bound independently re-confirmed
    -- read fresh at its point of use by direct read of server/tracking.lua
    -- before being added here, per this registry's own rule 3 (never taken
    -- on trust from another agent's own claim alone): the capture thread's
    -- own loop body reads sampleIntervalMs/minSampleMovementMeters/
    -- maxPointsPerPerson/dotLifetimeMs fresh every pass via
    -- ResolveConfiguredThresholdMs/ResolveScentVisionNumber (both
    -- clamp-and-warn helpers, never a bare assert); getScentVisionPoints
    -- re-reads queryCooldownMs/queryRangeMeters/dotLifetimeMs/
    -- maxVisibleTrails/queryMaxPointsPerTrail fresh via its own
    -- `local svConfig = Config.Tracking.ScentVision or {}` at the top of
    -- every single call.
    --
    -- NOT INCLUDED, and why -- flagged by coder-frontend themselves, not
    -- discovered independently:
    --   * pollIntervalMs -- confirmed by direct grep: ZERO occurrences in
    --     server/tracking.lua. It is read ONLY by client/tracking.lua's own
    --     independent copy of config.lua -- this file has no server-side
    --     enforcement point to confirm a live edit here would do anything
    --     (see header "WHAT THIS FILE DOES NOT DO": this file has no
    --     mechanism to push a Config change to an already-connected
    --     client), the exact "not confirmed read fresh at the point of
    --     use, so not exposed at all" exclusion rule 3 requires -- same
    --     class as every other client-only numeric already excluded
    --     elsewhere in this table (FetchMechanic's mouthBoneIndex, etc).
    --   * palette (an array of {r,g,b} tables) and fadeEnabled (a boolean)
    --     -- neither fits this registry's own single-number [min,max]
    --     shape (palette is variable-length and not a single value;
    --     fadeEnabled is not a number at all, no different from
    --     mintXpForNpcCombatTargets/allowSelfGrant above). Not built this
    --     pass -- reported back to coder-frontend as a shape question for a
    --     future pass, not silently dropped.
    --   * mode (a THREE-WAY STRING choice -- 'always'/'keybind'/'off', added
    --     a LATER pass than the rest of this block, owner-directed: "make
    --     the scent tracking a keybind and choose always active or
    --     [not]"). CHECKED THIS PASS, NOT ASSUMED: this registry's shape
    --     (TUNABLE_REGISTRY's own [min,max]/`integer` fields), the
    --     runtimeSetTunable callback's own `type(newValue) == 'number'`
    --     finite-number gate below, runtimeListTunables' own
    --     min/max/integer echo, THIS FILE's own onResourceStart
    --     tuning-override reload loop (`tonumber(row.value)`, a few screens
    --     down), AND client/tablet.lua's own tablet:runtimeSetTunable NUI
    --     bridge (`type(data.value) ~= 'number'`) are ALL numeric-only,
    --     end to end -- confirmed by direct read of all four, not inferred
    --     from one. Retrofitting a string enum through this exact path
    --     would mean a coordinated change across three files, two of them
    --     (client/tablet.lua, html/tablet.js's generic Tunables table
    --     renderer) outside this file's own lens entirely -- reported here,
    --     same as the two entries directly above, rather than half-built
    --     into a registry shape that cannot represent it without silently
    --     misrendering (an "undefined – undefined" min/max column, a number
    --     input a string value could never satisfy) for this one row. The
    --     setting itself shipped this pass regardless -- config.lua only,
    --     restart-to-apply, exactly like the vast majority of this file's
    --     own Config fields that were never candidates for this registry in
    --     the first place -- see that setting's own config.lua comment for
    --     the one exception this pass DID build: an admin turning
    --     Config.Features.ScentVision off from the tablet (already
    --     `tier = 'live'`, already fully supported, no change needed here)
    --     still reaches an already-rendering player's screen immediately,
    --     with no restart, via server/tracking.lua's own getScentVisionPoints
    --     echo -- that liveness guarantee did not need this registry at all.
    ['Tracking.ScentVision.sampleIntervalMs']        = { path = { 'Tracking', 'ScentVision', 'sampleIntervalMs' },        min = 1000, max = 30000,  integer = true },
    ['Tracking.ScentVision.minSampleMovementMeters'] = { path = { 'Tracking', 'ScentVision', 'minSampleMovementMeters' }, min = 0.0,  max = 20.0,   integer = false },
    ['Tracking.ScentVision.maxPointsPerPerson']      = { path = { 'Tracking', 'ScentVision', 'maxPointsPerPerson' },      min = 1,    max = 50,     integer = true },
    ['Tracking.ScentVision.dotLifetimeMs']           = { path = { 'Tracking', 'ScentVision', 'dotLifetimeMs' },           min = 5000, max = 300000, integer = true },
    ['Tracking.ScentVision.queryRangeMeters']        = { path = { 'Tracking', 'ScentVision', 'queryRangeMeters' },        min = 5.0,  max = 150.0,  integer = false },
    ['Tracking.ScentVision.maxVisibleTrails']        = { path = { 'Tracking', 'ScentVision', 'maxVisibleTrails' },        min = 1,    max = 10,     integer = true },
    ['Tracking.ScentVision.queryMaxPointsPerTrail']  = { path = { 'Tracking', 'ScentVision', 'queryMaxPointsPerTrail' },  min = 1,    max = 30,     integer = true },
    ['Tracking.ScentVision.queryCooldownMs']         = { path = { 'Tracking', 'ScentVision', 'queryCooldownMs' },         min = 250,  max = 10000,  integer = true },
}

-- ======================================================================
-- TUNABLE DESCRIPTIONS -- the fix for the exact confusion this resource's
-- own commit history predicted and then shipped anyway: the tablet's
-- Runtime Control -> Settings table used to show ONLY a tunable's raw
-- Config path (e.g. "Wellbeing.Fatigue.sprintDecayPerTick") as its one and
-- only label. A non-technical server owner reading that has no way to
-- tell it apart from "Wellbeing.Fatigue.nativeStaminaRestorePercent" --
-- two settings that control GENUINELY DIFFERENT things (this resource's
-- own custom tiredness stat vs. the game engine's own built-in sprint
-- stamina bar) -- without reading this file's source. See this section's
-- own two entries below for the fix written for exactly that pair.
--
-- MIRRORS FEATURE_TIERS' OWN `note`/`lockoutWarningKey` SHAPE ON PURPOSE:
-- same posture as GetFeatureNote/GetFeatureLockoutWarning above -- the
-- authoritative statement of what a setting IS belongs here, next to the
-- setting's own registry entry, not duplicated into html/tablet.js where
-- it could silently drift out of sync with this file's own comments (the
-- ones every description below was written FROM). Routed through the
-- SAME locale mechanism GetFeatureLockoutWarning already uses
-- (`pcall(locale, ...)` + FormatLocaleTemplate), for the same reason: this
-- is player(operator)-facing prose, and every other one of those already
-- lives in locales/en.json, not hardcoded into this file.
--
-- DELIBERATELY NOT a hand-maintained field on every TUNABLE_REGISTRY
-- entry (unlike lockoutWarningKey, which a single-digit handful of
-- FEATURE_TIERS entries need): with 100+ tunables, a second, independently
-- spelled slug per entry is itself a drift risk this mechanism exists to
-- avoid. The registry's own key (already unique, already stable) is
-- deterministically turned into a locale key instead -- one fewer thing to
-- keep in sync by hand, not a shortcut around the "mirror FEATURE_TIERS"
-- instruction, just a stricter reading of ITS OWN "next to the setting's
-- own definition, so it cannot drift" reasoning.
--
-- NEVER BREAKS THE ROW: a tunable with no description yet (locales/en.json
-- has no matching `tablet.runtime_tunable_desc_*` key) returns nil here,
-- exactly like a feature with no `note`. html/tablet.js's own
-- buildRuntimeTunableRow falls back to showing the raw key alone in that
-- case -- the ORIGINAL (if incomplete) behaviour, never a thrown error and
-- never a hidden row. Some tunables genuinely have no sensible
-- plain-English description shorter than this file's own multi-paragraph
-- comment explaining them (a few of the most deeply footnoted
-- entries above, e.g. the XP mint-budget-capped `XP.awards.*` block) --
-- left undescribed deliberately rather than filled with filler text; see
-- this pass's own hand-off report for the specific list.
-- ======================================================================

--- Deterministically derives the locale key suffix for a TUNABLE_REGISTRY
--- key's own description, e.g. 'Wellbeing.Fatigue.sprintDecayPerTick' ->
--- 'tablet.runtime_tunable_desc_wellbeing_fatigue_sprintdecaypertick'.
--- Collision-free because TUNABLE_REGISTRY's own keys already are (this
--- registry's `pairs` iteration would itself be broken by a duplicate Lua
--- table key long before this function ever ran).
--- @param key string -- TUNABLE_REGISTRY key
--- @return string localeKey
local function TunableDescriptionLocaleKey(key)
    return 'tablet.runtime_tunable_desc_' .. tostring(key):gsub('%.', '_'):lower()
end

--- @param key string -- TUNABLE_REGISTRY key
--- @return string? description -- nil (never a thrown error, never an
--- empty string) if this tunable has no plain-English description yet in
--- locales/en.json -- see this section's own header for why a missing
--- description must never break, hide, or otherwise change how its row
--- renders.
local function GetTunableDescription(key)
    local ok, text = pcall(locale, TunableDescriptionLocaleKey(key))
    if ok and type(text) == 'string' and text ~= '' then
        return text
    end
    return nil
end

--- Navigates a dotted registry `path` against the live `Config` table.
--- @param path table -- array of string keys
--- @return any value, boolean resolvable -- resolvable is false if some intermediate node is missing/not a table
local function GetConfigByPath(path)
    local node = Config
    for i = 1, #path do
        if type(node) ~= 'table' then return nil, false end
        node = node[path[i]]
    end
    return node, true
end

--- @param path table
--- @param value any
--- @return boolean ok
local function SetConfigByPath(path, value)
    local node = Config
    for i = 1, #path - 1 do
        if type(node[path[i]]) ~= 'table' then return false end
        node = node[path[i]]
    end
    node[path[#path]] = value
    return true
end

-- Snapshot of every tunable's config.lua-shipped default, captured before
-- any override below is re-applied -- same "obvious way back" contract as
-- CONFIG_LUA_DEFAULT_FEATURES above.
local CONFIG_LUA_DEFAULT_TUNABLES = {}
for key, entry in pairs(TUNABLE_REGISTRY) do
    local value = GetConfigByPath(entry.path)
    CONFIG_LUA_DEFAULT_TUNABLES[key] = value
end

-- ======================================================================
-- THEME -- see header PART 2. DEFAULT_THEME's four COLOUR fields seed from
-- Config.CommandTablet.branding.theme (the operator's own "starting
-- colours, matched to the shipped logo" -- config.lua's own comment) so a
-- FRESH install with no k9_tablet_theme row yet, and no override ever
-- saved, shows the operator's actual branding immediately rather than a
-- generic placeholder blue that would only ever be replaced once someone
-- opened the tablet's theme tab and pressed Save at least once.
-- CROSS-FILE GAP THIS CLOSES: this file's four colour literals were
-- previously hardcoded independently of config.lua's own
-- branding.theme -- shipped config.lua sets branding.theme to a crimson
-- palette, but a fresh install (no DB row) rendered the OLD placeholder
-- blue below until the real tabletGetTheme response replaced it, since
-- THIS default (not branding.theme) is what CurrentTheme seeds from at
-- boot. The old literals are kept as the FALLBACK-of-fallback (an
-- invalid/missing/malformed branding.theme entry, or no
-- Config.CommandTablet table at all e.g. CommandTablet disabled) --
-- never silently propagating a bad config value into CurrentTheme, same
-- "never trust blindly" posture ValidateFullTheme already applies to a
-- loaded DB row. `density`/`headerTitle` are NOT part of branding.theme
-- (config.lua's own comment: branding.theme is "starting colours" only)
-- and keep their own literal defaults, matching
-- sql/migrations/0007_create_k9_runtime_control.sql's own k9_tablet_theme
-- column DEFAULTs exactly, so "never configured yet" and "explicitly
-- reset" always converge on the same non-colour values.
-- ======================================================================
local FALLBACK_THEME_COLORS = {
    primaryColor    = '#2563eb',
    accentColor     = '#f59e0b',
    backgroundColor = '#111827',
    textColor       = '#f9fafb',
}

--- Narrow, standalone `#RRGGBB` check -- duplicated from IsValidHexColor's
--- own pattern (defined further below in this file) rather than reordered
--- ahead of it, so a config-authored branding colour is validated with the
--- exact same rule a runtime-submitted one is, without restructuring this
--- file's existing top-to-bottom section order for one early call site.
--- @param value any
--- @return boolean
local function IsPlausibleHexColorForBrandingSeed(value)
    return type(value) == 'string' and value:match('^#%x%x%x%x%x%x$') ~= nil
end

--- @param field string -- one of the four DEFAULT_THEME colour keys
--- @return string
local function ResolveBrandingSeedColor(field)
    local branding = type(Config.CommandTablet) == 'table' and Config.CommandTablet.branding
    local brandingTheme = type(branding) == 'table' and branding.theme
    local candidate = type(brandingTheme) == 'table' and brandingTheme[field]
    if IsPlausibleHexColorForBrandingSeed(candidate) then return candidate end
    return FALLBACK_THEME_COLORS[field]
end

local DEFAULT_THEME = {
    primaryColor    = ResolveBrandingSeedColor('primaryColor'),
    accentColor     = ResolveBrandingSeedColor('accentColor'),
    backgroundColor = ResolveBrandingSeedColor('backgroundColor'),
    textColor       = ResolveBrandingSeedColor('textColor'),
    density         = 'comfortable',
    headerTitle     = 'K9 Command Tablet',
}

local VALID_DENSITIES = { comfortable = true, compact = true }

--- Strict `#RRGGBB` match only -- a colour must actually be a colour, per
--- this task's own instruction, not merely "a short string". Rejects a
--- 3-digit shorthand, an `rgb(...)` function, a named colour ('red'), and
--- anything with whitespace -- deliberately narrow.
--- @param value any
--- @return boolean
local function IsValidHexColor(value)
    return type(value) == 'string' and value:match('^#%x%x%x%x%x%x$') ~= nil
end

--- @param value any
--- @return boolean
local function IsValidDensity(value)
    return type(value) == 'string' and VALID_DENSITIES[value] == true
end

--- <=40 chars (matches k9_tablet_theme.header_title's own VARCHAR(40)),
--- non-empty, and rejects every byte that could ever look like markup or a
--- control sequence -- see header PART 2 "A SIX-FIELD SURFACE" for why
--- this is defense-in-depth on top of html/tablet.js's own textContent-only
--- rendering discipline, not a substitute for it.
--- @param value any
--- @return boolean
local function IsSafeHeaderTitle(value)
    if type(value) ~= 'string' then return false end
    local len = #value
    if len == 0 or len > 40 then return false end
    if value:find('[<>&"\'`\r\n\t]') then return false end
    for i = 1, len do
        local byte = value:byte(i)
        -- Reject C0 control bytes and DEL. Bytes >= 0x80 (UTF-8 multibyte
        -- continuation/lead bytes for non-ASCII text) are accepted --
        -- this is a markup/control-character filter, not an ASCII-only
        -- filter.
        if byte < 0x20 or byte == 0x7F then return false end
    end
    return true
end

--- Validates a FULL theme table (every field required) against the four
--- checks above. Used by both SetTheme (after merging a partial request
--- onto the current theme -- see that callback) and the boot-time DB
--- read (defense in depth: even a row this file itself wrote is
--- re-validated on read, never trusted blindly).
--- @param theme table
--- @return boolean ok
--- @return string? badField
local function ValidateFullTheme(theme)
    if type(theme) ~= 'table' then return false, 'theme' end
    if not IsValidHexColor(theme.primaryColor) then return false, 'primaryColor' end
    if not IsValidHexColor(theme.accentColor) then return false, 'accentColor' end
    if not IsValidHexColor(theme.backgroundColor) then return false, 'backgroundColor' end
    if not IsValidHexColor(theme.textColor) then return false, 'textColor' end
    if not IsValidDensity(theme.density) then return false, 'density' end
    if not IsSafeHeaderTitle(theme.headerTitle) then return false, 'headerTitle' end
    return true
end

-- Current in-memory theme -- always a FULL, already-validated table.
-- Populated from the DB (or DEFAULT_THEME on a fresh install / failed
-- read) inside the onResourceStart handler below. GetTheme reads this
-- directly -- never a fresh query per viewer, matching this file's own
-- "cosmetic, read-mostly" scope.
local CurrentTheme = {}
for k, v in pairs(DEFAULT_THEME) do CurrentTheme[k] = v end

-- Current in-memory override state -- ActiveOverrides['feature:HighCommand']
-- = { kind = 'feature', value = 'false', updatedBy = '...', updatedByName =
-- '...' | nil, updatedAt = '...' }, mirroring k9_runtime_feature_overrides
-- (which has no `updatedByName` column of its own -- see this file's own
-- "DISPLAY NAME RESOLUTION" header, further below, for why that field is
-- session-only, resolved at write time, and nil for a row re-applied from
-- the database at boot). Populated at boot, kept in sync by
-- SetFeature/SetTunable/ResetFeature/ResetTunable below -- ListFeatures/
-- ListTunables read this rather than re-querying the DB on every tablet
-- open.
local ActiveOverrides = {}

-- ======================================================================
-- SHARED HELPERS -- rate limiting, authorization, audit, safe DB access.
-- ======================================================================

-- One shared cooldown instance, keyed by the calling officer's own source,
-- covering every mutating callback in this file (Set/Reset for features,
-- tunables, and theme) -- mirrors server/permissions.lua's
-- PermissionActionCooldown / server/highcommand.lua's
-- HighCommandGrantCooldown shape exactly: one instance per related-action
-- group, anti-fat-finger only (every caller here is already high command
-- or an explicit permission holder, i.e. already trusted -- this guards
-- against a held key or a double-submitted click, not abuse).
local RUNTIME_CONTROL_ACTION_COOLDOWN_MS = 1000
local RuntimeControlActionCooldown = NewCooldown(RUNTIME_CONTROL_ACTION_COOLDOWN_MS)
RuntimeControlActionCooldown.RegisterPlayerDropped()

--- @param source number
--- @return string? citizenid
local function ResolveCitizenId(source)
    local Player = exports.qbx_core:GetPlayer(source)
    local citizenid = Player and Player.PlayerData and Player.PlayerData.citizenid
    if type(citizenid) == 'string' and citizenid ~= '' then return citizenid end
    return nil
end

--- Server-authoritative: may `source` manage runtime feature/tuning
--- overrides right now? Re-resolved fresh on every call, per this task's
--- explicit "high command only, re-resolved server-side per call"
--- instruction -- never cached, never trusts a client claim of authority.
--- @param source number
--- @return boolean, string? citizenid -- citizenid is returned when known, for the caller to use as the audit `changed_by`
local function CanManageRuntimeControl(source)
    local citizenid = ResolveCitizenId(source)
    if type(IsHighCommand) == 'function' and IsHighCommand(source) then
        return true, citizenid
    end
    if citizenid and type(HasPermission) == 'function' and HasPermission(citizenid, 'k9.runtimecontrol') == true then
        return true, citizenid
    end
    return false, citizenid
end

--- Same shape as CanManageRuntimeControl, for the theming surface's own
--- capability key -- kept SEPARATE (not reused) so a server could one day
--- grant "may restyle the tablet" without also granting "may switch
--- features on and off", or vice versa, the moment the config owner adds
--- either key to Config.Permissions.
--- @param source number
--- @return boolean, string? citizenid
local function CanManageTabletTheme(source)
    local citizenid = ResolveCitizenId(source)
    if type(IsHighCommand) == 'function' and IsHighCommand(source) then
        return true, citizenid
    end
    if citizenid and type(HasPermission) == 'function' and HasPermission(citizenid, 'k9.tablettheme') == true then
        return true, citizenid
    end
    return false, citizenid
end

-- ======================================================================
-- DISPLAY NAME RESOLUTION (owner's request, verbatim, server/admin.lua:920:
-- "Ensure a name actually pops up and not the player id in the tablet
-- etc."). Applied here to the ONE surface on this file's own Runtime
-- Control screen that was still missing it: the `overriddenBy` field
-- runtimeListFeatures/runtimeListTunables return, which html/tablet.js's
-- existing `runtime_overridden_by_at` template ("Overridden by {who} at
-- {when}") already renders verbatim -- previously the raw citizenid that
-- made the edit, e.g. "Overridden by Z1234567 at ...", on the one screen
-- an owner is most likely to look at right after making a change.
--
-- A DELIBERATE, SELF-CONTAINED LOCAL DUPLICATE of server/tablet.lua's own
-- ResolveDisplayName / server/admin.lua's own ResolveAuditDisplayName --
-- same resolution order (online charinfo -> GetPlayerName native ->
-- offline GetOfflinePlayer charinfo -> citizenid fallback, never blank),
-- NOT a cross-file call to either `local` function, for the identical two
-- reasons server/admin.lua's own header already gives for its own
-- duplicate: (1) exporting either as a resource-global would need a new
-- .luacheckrc `globals` entry this file cannot add for itself, and this
-- resource's established convention for a small, self-contained helper is
-- a per-file duplicate; (2) server/tablet.lua returns entirely at its own
-- top (`if not Config.Features.CommandTablet then return end`) and
-- Config.Features.RuntimeFeatureControl/CommandTablet are independent
-- flags -- a server could run RuntimeFeatureControl = true with
-- CommandTablet = false, so depending on a global that file only
-- SOMETIMES defines would make this file's own name resolution silently
-- break whenever CommandTablet happens to be off.
--
-- RESOLVED AND STORED AT WRITE TIME, NEVER AT READ TIME -- the load-
-- bearing design decision this fix turns on, not a stylistic preference:
-- ResolveDisplayName's OFFLINE branch below calls qbx_core's
-- `GetOfflinePlayer`, a real database read (confirmed by reading that
-- export before deciding this, per this task's own instruction) -- cheap
-- once, but runtimeListFeatures/runtimeListTunables are polled every time
-- an officer opens the tablet's Settings screen, and can iterate dozens of
-- overridden rows in one call. Resolving at READ time would mean one
-- blocking DB round trip PER OVERRIDDEN ROW, PER tablet open, for every
-- citizenid who has since gone offline -- an N+1 query pattern this file's
-- own SHARED HELPERS section exists to avoid elsewhere. Resolving at WRITE
-- time instead (runtimeSetFeature/runtimeSetTunable below) is genuinely
-- free: `source` at that exact moment IS the officer who just made the
-- edit, by construction ALREADY connected (they are the one making this
-- exact callback invocation) -- ResolveDisplayName's ONLINE branch always
-- answers there, with no database access at all, and the resolved name is
-- cached on ActiveOverrides[overrideKey].updatedByName as a point-in-time
-- SNAPSHOT, exactly the way a name is supposed to work here (the officer
-- who made a change is frequently offline again by the time someone else
-- reads the row back -- a stale-but-correct snapshot of who they were
-- when they made the change is the right answer, not a live re-lookup
-- that would need the DB call this avoids).
--
-- `updatedBy` (the raw citizenid) is NEVER replaced or removed -- it
-- remains the durable key this file's own boot-time re-application loop
-- and every audit trail keys off; `updatedByName` is a purely additive,
-- resolved-once snapshot sitting alongside it. A row re-applied from
-- `k9_runtime_feature_overrides` at boot (this file's own onResourceStart
-- handler, above) has no name to carry -- that table has no such column,
-- and this fix does not add one (a schema change is out of scope for this
-- pass) -- so `updatedByName` is explicitly nil for every such row until
-- an officer edits that same key again THIS session. The read side below
-- (`overriddenBy = override and (override.updatedByName or
-- override.updatedBy) or nil`) falls back to the raw citizenid in exactly
-- that case, and for any citizenid ResolveDisplayName could not put a real
-- name to (ResolveDisplayName's own final fallback) -- never nil, never a
-- blank string, matching this task's "never nil/blank" requirement.
-- ======================================================================

--- @param charinfo any
--- @return string?
local function FullNameFromCharinfo(charinfo)
    if type(charinfo) == 'table' and type(charinfo.firstname) == 'string' and type(charinfo.lastname) == 'string' then
        local full = (charinfo.firstname .. ' ' .. charinfo.lastname):match('^%s*(.-)%s*$')
        if type(full) == 'string' and full ~= '' then return full end
    end
    return nil
end

--- @param citizenid string
--- @return string -- ALWAYS a non-empty string; falls back to `citizenid` itself when no name resolves, never blank
local function ResolveDisplayName(citizenid)
    local onlinePlayer = exports.qbx_core:GetPlayerByCitizenId(citizenid)
    if onlinePlayer and onlinePlayer.PlayerData then
        local full = FullNameFromCharinfo(onlinePlayer.PlayerData.charinfo)
        if full then return full end

        local onlineSrc = onlinePlayer.PlayerData.source
        if type(onlineSrc) == 'number' then
            local ok, viaNative = pcall(GetPlayerName, onlineSrc)
            if ok and type(viaNative) == 'string' and viaNative ~= '' then return viaNative end
        end
    end

    -- OFFLINE -- ask qbx_core's own offline accessor before giving up. NOT
    -- expected to actually be reached from either call site below (both
    -- resolve `source`, which is always online at that exact moment) --
    -- kept for parity with server/tablet.lua's/server/admin.lua's own
    -- ResolveDisplayName, and as a safety net if a future caller in this
    -- file ever resolves an OFFLINE citizenid instead.
    local ok, offlinePlayer = pcall(function() return exports.qbx_core:GetOfflinePlayer(citizenid) end)
    if ok and type(offlinePlayer) == 'table' and offlinePlayer.PlayerData then
        local full = FullNameFromCharinfo(offlinePlayer.PlayerData.charinfo)
        if full then return full end
    end

    -- Still nothing usable -- fall back to the citizenid itself. Never
    -- blank, never a guess at an unverified schema.
    return citizenid
end

--- Console log line for EVERY mutating call in this file -- matches
--- server/admin.lua's/server/permissions.lua's own "%s ran %s(%s) -> %s"
--- audit format exactly, per this task's own "AUDITED: who changed what,
--- from what, to what" requirement.
--- @param source number
--- @param action string
--- @param detail string
--- @param outcome string
local function LogAuditInvocation(source, action, detail, outcome)
    local citizenid = ResolveCitizenId(source)
    local whoLabel = citizenid and ('citizenid=' .. citizenid) or ('unresolved-source=' .. tostring(source))
    print(('[John-K9] AUDIT: %s ran %s(%s) -> %s'):format(whoLabel, action, detail, outcome))
end

-- server/datastore.lua's K9Store.Override_*/OverrideAudit_Append/Theme_*/
-- ThemeAudit_Append now provide the SafeQuery/SafeWrite contract this
-- file's own local wrappers used to (empty table / false on failure,
-- never a raw Lua error) -- see that file's own header: "the ONLY place
-- in this resource that may name a `k9_*` table or call `MySQL.*`
-- directly". Every call site below reads/writes through K9Store now.

-- ======================================================================
-- APPLYING AN OVERRIDE TO THE LIVE Config TABLE
-- ======================================================================

--- UNBOUNDED-TRAP FIX (restart/reconnect audit follow-up, this pass): this
--- is the SINGLE mutation point for every path that changes
--- Config.Features[name] at runtime -- the boot-time re-application loop
--- above, runtimeSetFeature, and runtimeResetFeature all funnel through
--- it -- which makes it the ONE correct place to hook a "tell already-
--- connected clients this specific flag just changed" side effect, rather
--- than duplicating the hook at every call site. XPProgression specifically
--- needs this because client/progression.lua's own static
--- Config.Features.XPProgression copy (fixed at that CLIENT's own resource
--- start) never updates on its own when this flag changes here -- an
--- already-online K9 with a real speedMultiplier/scentRangeMultiplier
--- effect applied would otherwise stay stuck at that value until reconnect
--- or a full resource restart even after high command switches the flag
--- off, exactly the "unbounded trap" client/progression.lua's own header
--- (search that file for "AN UNBOUNDED TRAP") documents finding. Soft-
--- dependency `type(...) == 'function'` guard, matching this codebase's
--- established convention for a cross-file call that is always real in a
--- normal boot but must never hard-crash this function if
--- server/progression.lua were ever absent/reordered (server/medkit.lua's
--- `type(AwardXP) == 'function'`, client/progression.lua's own
--- `type(RecomputeK9MoveRate) == 'function'`).
---
--- HandlerXPProgression NOW HAS THE SAME HOOK, and this comment used to say
--- the opposite. What it said was true when it was written and stopped
--- being true the moment handlers could see their own rank: there was no
--- client-side handler tier cache to leave stranded, because nothing had
--- ever told a handler what their rank was. Now something does
--- ('john-k9:client:handlerXpTierChanged', server/progression.lua), so
--- the flag has exactly the client-visible state its K9-side sibling had,
--- and needs exactly the same treatment: a handler already looking at a
--- rank on screen must be told the moment high command switches the feature
--- off, not on their next reconnect. Without this branch that is the
--- identical bug that had to be fixed for XPProgression -- a `tier = 'live'`
--- flag whose "no restart needed" promise quietly did not hold for anyone
--- already connected.
--- @param name string
--- @param value boolean
local function ApplyFeatureOverride(name, value)
    if type(Config.Features) == 'table' and Config.Features[name] ~= nil then
        Config.Features[name] = value
        if name == 'XPProgression' and type(RefreshXPProgressionLiveStateForAllOnline) == 'function' then
            RefreshXPProgressionLiveStateForAllOnline()
        end
        if name == 'HandlerXPProgression' and type(RefreshHandlerXPProgressionLiveStateForAllOnline) == 'function' then
            RefreshHandlerXPProgressionLiveStateForAllOnline()
        end
    end
end

--- @param key string -- TUNABLE_REGISTRY key
--- @param value number
local function ApplyTunableOverride(key, value)
    local entry = TUNABLE_REGISTRY[key]
    if entry then
        SetConfigByPath(entry.path, value)
    end
end

-- ======================================================================
-- BOOT -- re-apply every persisted override and the persisted theme on
-- top of config.lua's own shipped defaults. Deferred to onResourceStart
-- (not this file's own raw top-level -- see header "WHAT THIS FILE DOES
-- NOT DO") -- registered here, FIRST among this resource's own files
-- (see FXMANIFEST PLACEMENT), so it runs before every onstart-tier
-- file's own onResourceStart handler.
-- ======================================================================
AddEventHandler('onResourceStart', function(resourceName)
    if GetCurrentResourceName() ~= resourceName then return end

    -- BOOT-ORDER RACE FIX (issue-closer sweep, 2026-08-26): this handler
    -- reads TWO schema-checked tables below (K9Store.Override_GetAll --
    -- k9_runtime_feature_overrides -- and K9Store.Theme_GetRows --
    -- k9_tablet_theme) and, until now, did so with no call to
    -- K9Store.WaitForSchemaCheckToSettle() first -- the exact race that
    -- function's own doc comment (server/datastore.lua) exists to close,
    -- and this file was missing from that comment's own "AUTHORITATIVE
    -- CALLER LIST" despite genuinely needing to be on it. This handler
    -- registers AFTER server/datastore.lua's own onResourceStart (fxmanifest.lua
    -- loads server/datastore.lua first), so the probe's handler has already
    -- been registered and its first yielding query is already in flight by
    -- the time this one runs -- but "registered first" does not mean
    -- "finished first" (see WaitForSchemaCheckToSettle's own doc comment,
    -- "THE RACE, PRECISELY"), so this call is genuinely load-bearing, not
    -- decorative. On a `false` return (the probe had not settled within its
    -- wait budget), this skips override/theme re-application for this boot
    -- entirely -- config.lua's own shipped defaults and the built-in theme
    -- stand for this session, exactly like Config.Database.enabled = false
    -- -- rather than trust a database state that is not yet confirmed safe.
    -- The next SetFeature/SetTunable/SetTheme call (or a restart once the
    -- check has had time to finish) re-syncs the persisted state as normal.
    if not K9Store.WaitForSchemaCheckToSettle() then
        print('[John-K9] runtimecontrol.lua: the schema-collision check had not finished within its wait budget -- skipping this restart\'s override/theme re-application (no database read attempted, exactly like Config.Database.enabled = false) rather than trust a database state that is not yet confirmed safe. config.lua\'s own shipped defaults and the built-in theme stand for this session; the next admin edit (or a restart once the check has had time to finish) re-syncs it as normal.')
        return
    end

    local overrideRows = K9Store.Override_GetAll()
    local appliedCount, skippedCount = 0, 0

    -- THE SILENT-CLOBBER LOG (operator-tuning audit).
    --
    -- Re-applying a stored override is correct and deliberate: a setting
    -- changed from the tablet is meant to keep winning over config.lua
    -- until somebody resets it from the tablet. The tablet screen itself
    -- discloses this well.
    --
    -- What was missing is the one place an owner actually looks. Someone
    -- edits config.lua, restarts, watches the console, and sees only
    -- "N override(s) re-applied" -- a number. If one of those N happened to
    -- be the exact setting they just edited, their edit was thrown away and
    -- nothing told them. They then spend an evening convinced the setting
    -- does not work.
    --
    -- So: name every override whose stored value DISAGREES with what
    -- config.lua now says, and say how to undo it. Deliberately only the
    -- disagreements -- an override that matches the file cost the operator
    -- nothing, and printing those too would bury the ones that did in noise
    -- on every single boot.
    --
    -- CONFIG_LUA_DEFAULT_FEATURES / _TUNABLES are the right thing to
    -- compare against: both are snapshotted at this file's own load time,
    -- from config.lua as it sits on disk, BEFORE any override below is
    -- applied. They are literally "what the file says right now".
    local clobbered = {}

    for _, row in ipairs(overrideRows) do
        local applied = false
        local handledAsSessionOnly = false

        if row.kind == 'feature' then
            local name = row.override_key:match('^feature:(.+)$')
            -- FAIL-CLOSED FIX (this pass): this condition used to exclude
            -- ONLY 'protected' -- but runtimeSetFeature refuses to CREATE an
            -- override for an 'unaudited' feature just as hard as it
            -- refuses one for 'protected' (both share the exact same
            -- "refused, never written" code path above). A row for a
            -- feature that is unaudited TODAY can still exist here if it
            -- was persisted before this file's own FEATURE_TIERS table
            -- classified it (this file's own header already documents that
            -- exact history happening for real, for eleven features, in a
            -- single prior pass) -- silently re-applying such a row at boot
            -- would let a feature this file admits it "does not know what
            -- toggling would actually do" be toggled anyway, the precise
            -- silent gap this file's own "FAILS CLOSED, FOR REAL" header
            -- claims is closed everywhere. Now excluded here too, matching
            -- runtimeSetFeature's own refusal exactly.
            -- BELT AND SUSPENDERS (this pass): also excludes any feature
            -- with `sessionOnly = true` (HighCommand, PermissionGrants,
            -- RuntimeFeatureControl, TabletTheming -- see FEATURE_TIERS'
            -- own entries for the full "why"), regardless of how a row for
            -- one of them got into this table. SetFeature/ResetFeature now
            -- never WRITE such a row going forward -- but this check does
            -- not rely on that alone: a manually-inserted row, or a row
            -- persisted by an EARLIER version of this file (true today, in
            -- real production databases, for RuntimeFeatureControl/
            -- TabletTheming specifically, which were tier='live' and
            -- freely toggleable, with no sessionOnly protection at all,
            -- before this very pass) must ALSO never be allowed to win
            -- over a corrected config.lua on a future boot. This is what
            -- makes "config.lua on disk is the sole source of truth after
            -- a restart" true unconditionally for these four, not merely
            -- true "as long as nothing ever wrote a stray row" -- see this
            -- file's own task brief on why a stored override outliving a
            -- config fix is a real bricking bug, not a hypothetical one.
            local tier = GetFeatureTier(name)
            local sessionOnly = GetFeatureSessionOnly(name)
            -- PARENT-OFF SKIP (docs/history/FEATURE_STRUCTURE_SPEC.md §11) -- a stored
            -- override trying to turn a child ON while config.lua's own
            -- Config.FeatureGroups now has its parent `enabled = false`
            -- must NOT be silently re-applied here: ApplyFeatureOverride
            -- would flip Config.Features[name] true in memory for this
            -- boot, directly contradicting what runtimeSetFeature's own
            -- "PARENT-OFF REFUSES CHILD-ON" gate (above) would have
            -- refused had the same request been made live, and reproducing
            -- the exact "override says one thing, config.lua says another,
            -- nothing tells the operator" bug this whole re-apply loop's
            -- own "SILENT-CLOBBER LOG" exists to close. Checked BEFORE the
            -- generic apply below, same "skip and say why, do not apply
            -- and stay quiet" shape as the sessionOnly branch just below
            -- it -- and, like that branch, the row itself is left alone
            -- (never deleted) so it re-applies correctly on a LATER boot
            -- once the parent is enabled again.
            local storedValueForParentCheck = row.value == 'true'
            local parentBlocksThis = storedValueForParentCheck
                and type(IsFeatureGroupParentEnabled) == 'function'
                and not IsFeatureGroupParentEnabled(name)
            if name and Config.Features and Config.Features[name] ~= nil and tier ~= 'protected' and tier ~= 'unaudited' and not sessionOnly and not parentBlocksThis then
                local storedValue = storedValueForParentCheck
                local fileValue = CONFIG_LUA_DEFAULT_FEATURES[name]
                if fileValue ~= nil and fileValue ~= storedValue then
                    clobbered[#clobbered + 1] = ('Config.Features.%s -- config.lua says %s, a tablet change says %s (the tablet wins)')
                        :format(name, tostring(fileValue), tostring(storedValue))
                end
                ApplyFeatureOverride(name, storedValue)
                applied = true
            elseif name and parentBlocksThis then
                handledAsSessionOnly = true -- reuses the SAME "already explained, do not ALSO fall into the generic stale/unrecognized branch" routing sessionOnly rows use -- see that flag's own doc comment just below for why a flag, not a goto, is used here
                skippedCount = skippedCount + 1
                local parentName = type(GetFeatureGroupFamily) == 'function' and GetFeatureGroupFamily(name) or nil
                print(('[John-K9] runtimecontrol.lua: NOT re-applying persisted override %s -- Config.FeatureGroups.%s.enabled is false in config.lua, so turning %s on would have no real effect and would only re-drift right back to false. The stored override is kept, untouched, and will be re-applied correctly on a future restart once %s.enabled is true again.'):format(tostring(row.override_key), tostring(parentName), name, tostring(parentName)))
            elseif name and sessionOnly then
                -- Distinct from the generic "stale/unrecognized" skip
                -- message below -- this is EXPECTED, BY DESIGN, not a sign
                -- of drift or corruption, and should never read like one in
                -- an operator's console log. `handledAsSessionOnly` routes
                -- this row past the generic skip-message branch further
                -- down without needing a `goto` -- this loop body has
                -- locals declared after this point (`key`/`entry` in the
                -- `tuning` branch below), and Lua forbids a forward `goto`
                -- into a still-live local's scope, so a flag is the correct
                -- tool here, not a workaround for one.
                handledAsSessionOnly = true
                skippedCount = skippedCount + 1
                print(('[John-K9] runtimecontrol.lua: NOT re-applying persisted override %s -- this feature is session-only by design (see FEATURE_TIERS.sessionOnly in server/runtimecontrol.lua). config.lua on disk (currently: %s) is always authoritative for it after a restart, regardless of any prior tablet toggle. This is intentional, not a bug.'):format(tostring(row.override_key), tostring(Config.Features[name])))
            end
        elseif row.kind == 'tuning' then
            local key = row.override_key:match('^tuning:(.+)$')
            local entry = key and TUNABLE_REGISTRY[key]
            if entry then
                local numberValue = tonumber(row.value)
                if numberValue and numberValue >= entry.min and numberValue <= entry.max then
                    local fileValue = CONFIG_LUA_DEFAULT_TUNABLES[key]
                    if type(fileValue) == 'number' and fileValue ~= numberValue then
                        clobbered[#clobbered + 1] = ('%s -- config.lua says %s, a tablet change says %s (the tablet wins)')
                            :format(key, tostring(fileValue), tostring(numberValue))
                    end
                    ApplyTunableOverride(key, numberValue)
                    applied = true
                end
            end
        end

        if applied then
            appliedCount = appliedCount + 1
            -- DISPLAY-NAME FIX (this pass): deliberately NO `updatedByName`
            -- here -- k9_runtime_feature_overrides has no such column, and
            -- this row is being re-applied from exactly that table, so
            -- there is no resolved name to carry forward. runtimeListFeatures/
            -- runtimeListTunables' own read below falls back to this row's
            -- `updatedBy` (the raw citizenid) whenever `updatedByName` is
            -- nil -- see this file's own "DISPLAY NAME RESOLUTION" header
            -- above for the full contract. The next SetFeature/SetTunable
            -- call for this SAME key (this session) fills `updatedByName`
            -- in, same as any other override.
            ActiveOverrides[row.override_key] = { kind = row.kind, value = row.value, updatedBy = row.updated_by, updatedAt = row.updated_at }
        -- `handledAsSessionOnly` rows were already counted and printed
        -- above, with a message specific to WHY that row is intentionally
        -- not applied -- must not ALSO fall into the generic
        -- "stale/unrecognized" branch below, which would both double-count
        -- it in skippedCount and print a confusing second, contradictory
        -- line for the same row.
        elseif not handledAsSessionOnly then
            skippedCount = skippedCount + 1
            print(('[John-K9] runtimecontrol.lua: skipped stale/unrecognized override %s (kind=%s, value=%s) -- the underlying feature/tuning key no longer exists or is out of its currently configured range.'):format(tostring(row.override_key), tostring(row.kind), tostring(row.value)))
        end
    end

    local themeRows = K9Store.Theme_GetRows()
    if themeRows[1] then
        local loaded = {
            primaryColor    = themeRows[1].primary_color,
            accentColor     = themeRows[1].accent_color,
            backgroundColor = themeRows[1].background_color,
            textColor       = themeRows[1].text_color,
            density         = themeRows[1].density,
            headerTitle     = themeRows[1].header_title,
        }
        if ValidateFullTheme(loaded) then
            CurrentTheme = loaded
        else
            print('[John-K9] runtimecontrol.lua: k9_tablet_theme row failed validation on read -- keeping the built-in default theme this session. Check for a manual/foreign edit to that table.')
        end
    end

    print(('[John-K9] runtimecontrol.lua: %d override(s) re-applied, %d skipped, at resource start.'):format(appliedCount, skippedCount))

    -- Printed AFTER the count line, so it reads as the detail behind the
    -- number rather than an unrelated warning somewhere further up the log.
    if clobbered[1] then
        print(('[John-K9] runtimecontrol.lua: HEADS UP -- %d of those override(s) DISAGREE with what config.lua currently says. If you just edited one of these in config.lua, your edit is NOT in effect: a change made from the tablet keeps winning over the file until somebody resets it from the tablet (K9 Tablet -> Settings -> the row -> Reset to config.lua). The file is not being ignored generally; only these specific settings:'):format(#clobbered))
        for _, line in ipairs(clobbered) do
            print('[John-K9] runtimecontrol.lua:   * ' .. line)
        end
    end
end)

-- ======================================================================
-- PART 1 CALLBACKS -- feature toggles. ALWAYS registered, unconditionally
-- (this file's own "SELF-HOSTING" design -- see header): each re-checks
-- Config.Features.RuntimeFeatureControl live, on every call, exactly like
-- server/highcommand.lua's IsHighCommand re-checks Config.Features.HighCommand.
-- This is deliberate, not an inconsistency with "gate at registration" --
-- a meta-control surface that could lock itself out by being toggled off
-- would be the single worst instance of the failure mode this whole file
-- exists to avoid.
-- ======================================================================

lib.callback.register('john-k9:server:runtimeListFeatures', function(source)
    local authorized = CanManageRuntimeControl(source)
    if not authorized then return { ok = false, reason = 'denied' } end

    local rows = {}
    for name, currentValue in pairs(Config.Features or {}) do
        local tier = GetFeatureTier(name)
        local overrideKey = 'feature:' .. name
        local override = ActiveOverrides[overrideKey]
        local lockoutRisk = GetFeatureLockoutRisk(name)
        -- ACTIVE-USAGE CONFIRMATION (see that section above
        -- GetFeatureLockoutWarning for the full mechanism) -- only
        -- meaningful while `currentValue` is true (a feature already off
        -- has nothing pending to disable, so no badge is owed here even if
        -- a stray leftover count existed). Folds into the SAME
        -- `lockoutRisk`/`lockoutWarning` fields the static entries above
        -- use, so html/tablet.js needs no changes at all to show this
        -- exactly like any other lockout-risk row.
        local activeUsageCount = currentValue and GetActiveUsageCount(name) or nil
        if activeUsageCount then lockoutRisk = true end
        rows[#rows + 1] = {
            name = name,
            currentValue = currentValue,
            configLuaDefault = CONFIG_LUA_DEFAULT_FEATURES[name],
            tier = tier,
            note = GetFeatureNote(name),
            overridden = override ~= nil,
            -- DISPLAY-NAME FIX (this pass, owner's request verbatim --
            -- server/admin.lua:920): `overriddenBy` now carries the
            -- write-time-resolved display name when one was cached
            -- (`updatedByName`, set by runtimeSetFeature below), falling
            -- back to the raw citizenid (`updatedBy`) for a row re-applied
            -- from k9_runtime_feature_overrides at boot (no name column
            -- there) or for a citizenid ResolveDisplayName could not
            -- resolve -- NEVER nil while `override` itself is non-nil, and
            -- NEVER the literal string "nil". html/tablet.js's existing
            -- `runtime_overridden_by_at` template already renders this
            -- field verbatim as "who" -- no client-side change needed to
            -- pick this up. See this file's own "DISPLAY NAME RESOLUTION"
            -- header above for the full write-time-not-read-time
            -- reasoning.
            overriddenBy = override and (override.updatedByName or override.updatedBy) or nil,
            overriddenAt = override and override.updatedAt or nil,
            protected = tier == 'protected',
            -- CONTRACT FOR html/tablet.js (not edited by this pass -- see
            -- this pass's own hand-off report for the full UI contract):
            -- `lockoutRisk = true` means SetFeature/ResetFeature for this
            -- name WILL be refused with reason = 'confirmation_required'
            -- unless the call also carries `confirm` equal to `name`
            -- EXACTLY -- the tablet must show `lockoutWarning`'s full text
            -- in a real confirmation step (not a toast that auto-dismisses)
            -- before ever sending that second call. `sessionOnly = true`
            -- means a successful change here is NOT persisted -- the
            -- tablet should tell the officer this change reverts on the
            -- next restart unless config.lua is also edited to match.
            -- `lockoutRisk` is TRUE for two different reasons now (a
            -- static self-lockout risk, OR a live active-usage count right
            -- now) -- the tablet does not need to tell them apart; either
            -- way `lockoutWarning` already carries the real, specific
            -- explanation to show verbatim.
            lockoutRisk = lockoutRisk,
            sessionOnly = GetFeatureSessionOnly(name),
            lockoutWarning = lockoutRisk and (activeUsageCount and GetActiveUsageWarning(name, activeUsageCount) or GetFeatureLockoutWarning(name)) or nil,
        }
    end
    return { ok = true, features = rows }
end)

--- @param source number
--- @param name string
--- @param newValue boolean
--- @param confirm string? -- REQUIRED, and must equal `name` EXACTLY, for
--- any feature with `lockoutRisk = true` (see FEATURE_TIERS' own
--- lockoutRisk entries and "LOCKOUT-RISK FEATURES" above GetFeatureTier
--- for the full mechanism) OR one of the four "ACTIVE-USAGE CONFIRMATION
--- FEATURES" (see that section above GetFeatureLockoutWarning) while
--- `newValue == false` and at least one player is genuinely doing that
--- thing right now -- ignored entirely for every other feature/value
--- combination, so every existing caller of this callback keeps working
--- unmodified with only 3 arguments.
lib.callback.register('john-k9:server:runtimeSetFeature', function(source, name, newValue, confirm)
    if not (Config.Features and Config.Features.RuntimeFeatureControl == true) then
        return { ok = false, reason = 'feature_disabled' }
    end

    local authorized, citizenid = CanManageRuntimeControl(source)
    if not authorized then
        LogAuditInvocation(source, 'runtimeSetFeature', ('name=%s'):format(tostring(name)), 'denied')
        return { ok = false, reason = 'denied' }
    end

    if not RuntimeControlActionCooldown.Consume(source, RUNTIME_CONTROL_ACTION_COOLDOWN_MS) then
        return { ok = false, reason = 'rate_limited' }
    end

    if type(name) ~= 'string' or Config.Features == nil or Config.Features[name] == nil then
        LogAuditInvocation(source, 'runtimeSetFeature', ('name=%s'):format(tostring(name)), 'invalid_feature')
        return { ok = false, reason = 'invalid_feature' }
    end

    if type(newValue) ~= 'boolean' then
        LogAuditInvocation(source, 'runtimeSetFeature', ('name=%s value=%s'):format(name, tostring(newValue)), 'invalid_value')
        return { ok = false, reason = 'invalid_value' }
    end

    local tier = GetFeatureTier(name)
    if tier == 'protected' then
        LogAuditInvocation(source, 'runtimeSetFeature', ('name=%s'):format(name), 'protected_feature')
        return { ok = false, reason = 'protected_feature' }
    end

    -- FAILS CLOSED, FOR REAL, NOT JUST IN THIS FILE'S OWN COMMENTS: an
    -- 'unaudited' feature is one this file's own FEATURE_TIERS table has
    -- never actually read -- see "FEATURE REGISTRY" above for the exact
    -- history of why this check has to exist (this header used to CLAIM
    -- this refusal happened while the code silently did not). Refused the
    -- same way 'protected' is refused, PLUS a named, actionable console
    -- warning every single time someone tries -- a silent denial here
    -- would reproduce the exact bug this check exists to close, just one
    -- layer down. This is never expected to fire for one of the 56
    -- features known to this file today (see the STARTUP AUDIT WARNING
    -- above, which already caught it at boot if it did) -- it exists as
    -- the safety net for feature 57, not a routine block on a real one.
    if tier == 'unaudited' then
        LogAuditInvocation(source, 'runtimeSetFeature', ('name=%s'):format(name), 'unaudited_feature')
        print(('[John-K9] runtimecontrol.lua: WARNING: refused to toggle %q -- this Config.Features key has no FEATURE_TIERS entry in this file, so this file does not know what toggling it would actually do. Read its real server/client implementation and add FEATURE_TIERS.%s = { tier = ... } to server/runtimecontrol.lua before it can be toggled at runtime -- see this file\'s header "THE FULL AUDIT" for the five tiers and how each is decided.'):format(name, name))
        return { ok = false, reason = 'unaudited_feature' }
    end

    -- PARENT-OFF REFUSES CHILD-ON (owner-directed, docs/history/FEATURE_STRUCTURE_SPEC.md
    -- §11) -- config.lua's Config.FeatureGroups tree (see that file's own
    -- header) can force a whole family of Config.Features keys off via one
    -- `enabled = false`. Accepting an override that turns ONE of those keys
    -- back on while its parent is off would store a value that can never
    -- take effect -- ApplyFeatureOverride below still WOULD flip
    -- Config.Features[name] true for this session, but the very next
    -- config.lua reload/restart re-runs ResolveFeatureGroups, which forces
    -- it straight back to false regardless, silently. That is exactly the
    -- invisible-state bug class this file already closed for
    -- HighCommand/PermissionGrants/RuntimeFeatureControl/TabletTheming's
    -- own lockout protection (see those entries' own history above) --
    -- refused here loudly instead, naming the parent, rather than accepted
    -- silently. Only checked when `newValue == true`: turning a child OFF
    -- never needs a working parent, so that direction is never refused by
    -- this gate (matches this file's own "gate the start, never the stop"
    -- convention applied to this file's own machinery, not just the
    -- features it controls).
    --
    -- OLD FLAT-SHAPE CONFIGS ARE UNAFFECTED: IsFeatureGroupParentEnabled
    -- (config.lua) always reports true for every key when
    -- Config.FeatureGroups does not exist at all -- there is no parent
    -- concept to consult, so this gate can never fire for an install that
    -- has not adopted the grouped format. Also never fires for one of the
    -- standalone flags (HighCommand/PermissionGrants/
    -- AdminAuditCommands/BoneSweepDevTool/RadialMenu) -- none of those has
    -- a parent to be disabled by, by design.
    if newValue == true and type(IsFeatureGroupParentEnabled) == 'function' and not IsFeatureGroupParentEnabled(name) then
        local parentName = type(GetFeatureGroupFamily) == 'function' and GetFeatureGroupFamily(name) or nil
        LogAuditInvocation(source, 'runtimeSetFeature', ('name=%s parent=%s'):format(name, tostring(parentName)), 'parent_disabled')
        return { ok = false, reason = 'parent_disabled', parent = parentName,
            note = ('Config.FeatureGroups.%s.enabled is false in config.lua, so %s cannot be turned on from here -- it would be forced back off the next time this resource restarts regardless of this override. Enable %s.enabled in config.lua (or under the family it belongs to) first, then restart, then this can be toggled live.'):format(tostring(parentName), name, tostring(parentName)) }
    end

    -- LOCKOUT-RISK CONFIRMATION GATE (see FEATURE_TIERS' own lockoutRisk
    -- entries above, and "LOCKOUT-RISK FEATURES" above GetFeatureTier, for
    -- the full reasoning). Placed AFTER the rate-limit consume above (an
    -- unconfirmed attempt on a lockout-risk feature still consumes the
    -- officer's own anti-fat-finger window, matching this file's existing
    -- "every rejection past that point still consumes it" convention) and
    -- AFTER the unaudited/protected checks (so a genuinely bad `name`
    -- reports THAT problem, not a confusing confirmation prompt for a
    -- feature that could never be toggled at all). `confirm` must equal
    -- `name` EXACTLY -- not merely truthy -- so a UI cannot pass a single
    -- hardcoded `true` for every toggle without actually naming which one
    -- it is confirming.
    --
    -- ACTIVE-USAGE CONFIRMATION GATE (see "ACTIVE-USAGE CONFIRMATION
    -- FEATURES" above GetFeatureLockoutWarning for the full mechanism) --
    -- STACKED onto the same gate, not a separate one: only relevant when
    -- `newValue == false` (turning something OFF is the only direction
    -- that can strand a player mid-use; turning it back ON never can), and
    -- re-checked FRESH right here, at the moment of this exact call, never
    -- trusted from a stale list response or a client-supplied count.
    local lockoutRisk = GetFeatureLockoutRisk(name)
    local activeUsageCount = (newValue == false) and GetActiveUsageCount(name) or nil
    if activeUsageCount then lockoutRisk = true end
    if lockoutRisk and confirm ~= name then
        LogAuditInvocation(source, 'runtimeSetFeature', ('name=%s'):format(name), 'confirmation_required')
        return { ok = false, reason = 'confirmation_required', lockoutRisk = true, warning = activeUsageCount and GetActiveUsageWarning(name, activeUsageCount) or GetFeatureLockoutWarning(name) }
    end

    local oldValue = Config.Features[name]
    local overrideKey = 'feature:' .. name
    local valueStr = newValue and 'true' or 'false'
    local sessionOnly = GetFeatureSessionOnly(name)

    -- SESSION-ONLY PERSISTENCE SKIP (see FEATURE_TIERS' own sessionOnly
    -- entries for the full "why" -- summary: a stored override for one of
    -- these could survive a restart and win over a corrected config.lua,
    -- which is the one bricking shape this pass exists to rule out). The
    -- CORE toggle below (ApplyFeatureOverride/ActiveOverrides) is
    -- unconditional either way -- only the DURABLE row is skipped.
    if not sessionOnly then
        local wrote = K9Store.Override_Upsert(overrideKey, 'feature', valueStr, citizenid or 'unknown')
        if not wrote then
            LogAuditInvocation(source, 'runtimeSetFeature', ('name=%s value=%s'):format(name, valueStr), 'db_error')
            return { ok = false, reason = 'db_error' }
        end
    end

    -- AUDIT-SWALLOW FIX (this pass): see runtimeResetFeature's identical
    -- comment further below for the full reasoning -- the primary write
    -- already succeeded (or was intentionally skipped, for a sessionOnly
    -- feature -- either way the in-memory change below still happens), so
    -- `ok = true` remains correct, but a failed audit-trail insert must
    -- not vanish without a trace tying it to this specific name/value.
    -- ALWAYS attempted, even for a sessionOnly feature -- "every edit must
    -- be audited" does not stop being true just because this one is not
    -- also durably re-appliable at boot; this is the ONE durable record
    -- that HighCommand/PermissionGrants/RuntimeFeatureControl/TabletTheming
    -- were ever touched at all, and by whom.
    if not K9Store.OverrideAudit_Append(overrideKey, 'feature', tostring(oldValue), valueStr, citizenid or 'unknown') then
        print(('[John-K9] runtimecontrol.lua: runtimeSetFeature audit-trail write failed for name=%s value=%s (the change itself still succeeded).'):format(name, valueStr))
    end

    ApplyFeatureOverride(name, newValue)
    -- DISPLAY-NAME FIX (this pass): `source` is, by construction, the
    -- CURRENTLY connected officer making this exact call -- ResolveDisplayName's
    -- online branch always answers here, no database read involved. See
    -- this file's own "DISPLAY NAME RESOLUTION" header (above
    -- CanManageRuntimeControl) for why this is resolved HERE, at write
    -- time, rather than deferred to runtimeListFeatures' read side.
    local updatedByName = (type(citizenid) == 'string' and citizenid ~= '') and ResolveDisplayName(citizenid) or nil
    -- `citizenid or 'unknown'` -- matches the SAME fallback the DB writes
    -- above already use (Override_Upsert/OverrideAudit_Append), for the
    -- rare defensive case where CanManageRuntimeControl authorized this
    -- call (IsHighCommand) but could not resolve a citizenid at all --
    -- keeps `overriddenBy`'s own "never nil, never blank" guarantee true
    -- even here, rather than silently reintroducing a nil in this one edge
    -- case.
    ActiveOverrides[overrideKey] = { kind = 'feature', value = valueStr, updatedBy = citizenid or 'unknown', updatedByName = updatedByName, updatedAt = os.date('%Y-%m-%d %H:%M:%S') }

    LogAuditInvocation(source, 'runtimeSetFeature', ('name=%s old=%s new=%s tier=%s sessionOnly=%s'):format(name, tostring(oldValue), valueStr, tier, tostring(sessionOnly)), 'ok')

    local response
    if tier == 'live' then
        response = { ok = true, appliedLive = true, restartRequired = false, tier = tier }
    elseif tier == 'onstart' then
        response = { ok = true, appliedLive = false, restartRequired = true, tier = tier, note = 'This feature only re-checks this flag at server start. Saved -- it will take effect after the next resource restart, but nothing has changed for players on this session.' }
    elseif tier == 'rawtoplevel' then
        response = { ok = true, appliedLive = false, restartRequired = true, configEditRequired = true, tier = tier, note = 'This feature is gated before this resource finishes starting. A restart of THIS resource alone is not enough -- Config.Features.' .. name .. ' must also be changed in config.lua for this to take effect.' }
    else -- 'clientonly' -- the only tier that still reaches here; 'protected' and 'unaudited' are both refused above, before any write.
        response = { ok = true, appliedLive = false, restartRequired = true, tier = tier, note = 'No confirmed server-side enforcement point for this feature -- this value is saved, but this file cannot confirm it will have any live effect.' }
    end

    if lockoutRisk then response.lockoutRisk = true end
    if sessionOnly then
        response.sessionOnly = true
        response.note = (response.note and (response.note .. ' ') or '') ..
            'SESSION-ONLY: this change is NOT persisted -- the next resource restart (with or without a config.lua edit) reverts Config.Features.' .. name .. ' to whatever config.lua has on disk.'
    end
    return response
end)

--- @param source number
--- @param name string
--- @param confirm string? -- see runtimeSetFeature's own doc comment -- same
--- exact-name-match requirement, for the same lockoutRisk feature set. A
--- reset can set a lockoutRisk feature to an unexpected value just as
--- easily as a Set can (e.g. if config.lua's own shipped default happens
--- to differ from what the caller expects), so this is symmetric with
--- SetFeature, never a quieter back door around the same confirmation.
lib.callback.register('john-k9:server:runtimeResetFeature', function(source, name, confirm)
    if not (Config.Features and Config.Features.RuntimeFeatureControl == true) then
        return { ok = false, reason = 'feature_disabled' }
    end

    local authorized, citizenid = CanManageRuntimeControl(source)
    if not authorized then
        LogAuditInvocation(source, 'runtimeResetFeature', ('name=%s'):format(tostring(name)), 'denied')
        return { ok = false, reason = 'denied' }
    end

    if not RuntimeControlActionCooldown.Consume(source, RUNTIME_CONTROL_ACTION_COOLDOWN_MS) then
        return { ok = false, reason = 'rate_limited' }
    end

    if type(name) ~= 'string' or CONFIG_LUA_DEFAULT_FEATURES[name] == nil then
        return { ok = false, reason = 'invalid_feature' }
    end

    local defaultValue = CONFIG_LUA_DEFAULT_FEATURES[name]

    -- LOCKOUT-RISK CONFIRMATION GATE -- see runtimeSetFeature's identical
    -- gate above for the full reasoning; symmetric here on purpose.
    --
    -- ACTIVE-USAGE CONFIRMATION GATE -- also symmetric with
    -- runtimeSetFeature's own stacked check above: relevant here exactly
    -- when the RESULT of this reset would turn the feature off
    -- (`defaultValue == false`), the same "resulting value" test
    -- SetFeature applies to its own `newValue` argument -- never based on
    -- the CURRENT value, which a reset does not care about (config.lua's
    -- own shipped default is the only thing that matters here).
    local lockoutRisk = GetFeatureLockoutRisk(name)
    local activeUsageCount = (defaultValue == false) and GetActiveUsageCount(name) or nil
    if activeUsageCount then lockoutRisk = true end
    if lockoutRisk and confirm ~= name then
        LogAuditInvocation(source, 'runtimeResetFeature', ('name=%s'):format(name), 'confirmation_required')
        return { ok = false, reason = 'confirmation_required', lockoutRisk = true, warning = activeUsageCount and GetActiveUsageWarning(name, activeUsageCount) or GetFeatureLockoutWarning(name) }
    end

    local overrideKey = 'feature:' .. name
    local oldValue = Config.Features[name]
    local sessionOnly = GetFeatureSessionOnly(name)

    -- SESSION-ONLY PERSISTENCE SKIP -- see runtimeSetFeature's identical
    -- skip above, and FEATURE_TIERS' own sessionOnly entries, for the full
    -- "why" (a stored override for one of these could otherwise survive a
    -- restart and win over a corrected config.lua). Nothing was ever
    -- written to k9_runtime_feature_overrides for a sessionOnly feature in
    -- the first place (SetFeature above skips it too), so there is
    -- structurally nothing here TO delete for one of these -- but the
    -- delete is still attempted defensively for every OTHER feature,
    -- unchanged, exactly as before this pass.
    if not sessionOnly then
        -- CLAIMS-MORE-THAN-HAPPENED FIX (earlier pass, preserved): Override_Delete's
        -- own boolean return used to be discarded outright here, so a DB
        -- failure was reported to the caller as an unqualified `ok = true`
        -- even though the persisted override row was NEVER actually
        -- removed. Checked and refused before ANY in-memory Config
        -- mutation, so a failed persist can never leave this session's
        -- live value out of sync with what will survive a restart.
        local deleted = K9Store.Override_Delete(overrideKey)
        if not deleted then
            LogAuditInvocation(source, 'runtimeResetFeature', ('name=%s'):format(name), 'db_error')
            return { ok = false, reason = 'db_error' }
        end
    end

    -- AUDIT-SWALLOW FIX (earlier pass, preserved): OverrideAudit_Append's
    -- own boolean return used to be discarded here too. ALWAYS attempted,
    -- even for a sessionOnly feature -- same "this is the one durable
    -- record this ever happened" reasoning as runtimeSetFeature above.
    if not K9Store.OverrideAudit_Append(overrideKey, 'feature', tostring(oldValue), nil, citizenid or 'unknown') then
        print(('[John-K9] runtimecontrol.lua: runtimeResetFeature audit-trail write failed for name=%s (the reset itself still succeeded).'):format(name))
    end

    ApplyFeatureOverride(name, defaultValue)
    ActiveOverrides[overrideKey] = nil

    LogAuditInvocation(source, 'runtimeResetFeature', ('name=%s restored=%s sessionOnly=%s'):format(name, tostring(defaultValue), tostring(sessionOnly)), 'ok')

    -- TIER-AWARE RESPONSE -- FIXED (earlier pass, preserved): this
    -- callback used to unconditionally return `restartRequired = false`
    -- regardless of the feature's own tier, the exact asymmetry this
    -- file's own runtimeSetFeature above does NOT have. Mirrors
    -- SetFeature's own tier branch field-for-field.
    local tier = GetFeatureTier(name)
    local response
    if tier == 'live' then
        response = { ok = true, value = defaultValue, appliedLive = true, restartRequired = false, tier = tier }
    elseif tier == 'onstart' then
        response = { ok = true, value = defaultValue, appliedLive = false, restartRequired = true, tier = tier, note = 'This feature only re-checks this flag at server start. Restored to its config.lua default -- it will take effect after the next resource restart, but nothing has changed for players on this session.' }
    elseif tier == 'rawtoplevel' then
        response = { ok = true, value = defaultValue, appliedLive = false, restartRequired = true, configEditRequired = true, tier = tier, note = 'This feature is gated before this resource finishes starting. A restart of THIS resource alone is not enough -- Config.Features.' .. name .. ' must also match this default in config.lua for this to take effect.' }
    else -- 'clientonly' -- and, defensively, 'protected'/'unaudited': SetFeature refuses both of those before ever creating an override, so a reset of either is normally a no-op restoring an already-current value, but this callback does not itself gate on tier the way SetFeature does (see above) -- falling through to the same "cannot confirm" response SetFeature gives 'clientonly' is the safe direction of error for a tier this file does not fully trust here, never a false "no restart needed".
        response = { ok = true, value = defaultValue, appliedLive = false, restartRequired = true, tier = tier, note = 'No confirmed server-side enforcement point this file can guarantee applies this restore live -- this value is saved, but this file cannot confirm it will have any live effect this session.' }
    end

    if lockoutRisk then response.lockoutRisk = true end
    if sessionOnly then
        response.sessionOnly = true
        response.note = (response.note and (response.note .. ' ') or '') ..
            'SESSION-ONLY: this restore is NOT persisted -- there was never a stored override to remove for this feature; the next resource restart applies whatever config.lua has on disk regardless of this call.'
    end
    return response
end)

-- ======================================================================
-- PART 1B CALLBACKS -- tuning. Same self-hosting/always-registered design
-- as the feature callbacks above.
-- ======================================================================

lib.callback.register('john-k9:server:runtimeListTunables', function(source)
    if not CanManageRuntimeControl(source) then return { ok = false, reason = 'denied' } end

    local rows = {}
    for key, entry in pairs(TUNABLE_REGISTRY) do
        local currentValue = GetConfigByPath(entry.path)
        local overrideKey = 'tuning:' .. key
        local override = ActiveOverrides[overrideKey]
        rows[#rows + 1] = {
            key = key,
            currentValue = currentValue,
            configLuaDefault = CONFIG_LUA_DEFAULT_TUNABLES[key],
            min = entry.min,
            max = entry.max,
            integer = entry.integer,
            overridden = override ~= nil,
            -- DISPLAY-NAME FIX (this pass) -- identical fallback chain to
            -- runtimeListFeatures' own `overriddenBy` above; see this
            -- file's "DISPLAY NAME RESOLUTION" header for the full "why".
            overriddenBy = override and (override.updatedByName or override.updatedBy) or nil,
            overriddenAt = override and override.updatedAt or nil,
            -- PLAIN-ENGLISH DESCRIPTION (see this file's own "TUNABLE
            -- DESCRIPTIONS" header above GetTunableDescription): nil, never
            -- an empty string or a thrown error, for any key this pass has
            -- not written a locales/en.json entry for yet -- html/tablet.js
            -- falls back to showing `key` alone in that case, exactly like
            -- before this field existed.
            description = GetTunableDescription(key),
        }
    end
    return { ok = true, tunables = rows }
end)

lib.callback.register('john-k9:server:runtimeSetTunable', function(source, key, newValue)
    if not (Config.Features and Config.Features.RuntimeFeatureControl == true) then
        return { ok = false, reason = 'feature_disabled' }
    end

    local authorized, citizenid = CanManageRuntimeControl(source)
    if not authorized then
        LogAuditInvocation(source, 'runtimeSetTunable', ('key=%s'):format(tostring(key)), 'denied')
        return { ok = false, reason = 'denied' }
    end

    if not RuntimeControlActionCooldown.Consume(source, RUNTIME_CONTROL_ACTION_COOLDOWN_MS) then
        return { ok = false, reason = 'rate_limited' }
    end

    local entry = type(key) == 'string' and TUNABLE_REGISTRY[key] or nil
    if not entry then
        LogAuditInvocation(source, 'runtimeSetTunable', ('key=%s'):format(tostring(key)), 'invalid_key')
        return { ok = false, reason = 'invalid_key' }
    end

    -- FAIL CLOSED, exhaustively -- never a bare `> 0`. Rejects nil,
    -- non-number, NaN (`newValue == newValue` is Lua's standard NaN test --
    -- see server/cooldowns.lua's own IsValidThreshold for why `> 0` alone
    -- does not catch NaN), and infinities, on top of the actual
    -- [min, max] range this task asked for. This is the "refuse anything
    -- outside a sane range" requirement -- values outside [min, max] are
    -- REJECTED, never silently coerced to the nearest boundary; the
    -- caller is told the exact bounds so a typo is loud, not silently
    -- rewritten into a different, unrequested number.
    local isFiniteNumber = type(newValue) == 'number' and newValue == newValue and newValue > -math.huge and newValue < math.huge
    if not isFiniteNumber or newValue < entry.min or newValue > entry.max then
        LogAuditInvocation(source, 'runtimeSetTunable', ('key=%s value=%s'):format(key, tostring(newValue)), 'out_of_range')
        return { ok = false, reason = 'out_of_range', min = entry.min, max = entry.max }
    end

    if entry.integer and newValue ~= math.floor(newValue) then
        LogAuditInvocation(source, 'runtimeSetTunable', ('key=%s value=%s'):format(key, tostring(newValue)), 'not_integer')
        return { ok = false, reason = 'not_integer' }
    end

    local oldValue = GetConfigByPath(entry.path)
    local overrideKey = 'tuning:' .. key
    local valueStr = tostring(newValue)

    local wrote = K9Store.Override_Upsert(overrideKey, 'tuning', valueStr, citizenid or 'unknown')
    if not wrote then
        LogAuditInvocation(source, 'runtimeSetTunable', ('key=%s value=%s'):format(key, valueStr), 'db_error')
        return { ok = false, reason = 'db_error' }
    end

    -- AUDIT-SWALLOW FIX (this pass): see runtimeSetFeature's identical
    -- comment above for the full reasoning.
    if not K9Store.OverrideAudit_Append(overrideKey, 'tuning', tostring(oldValue), valueStr, citizenid or 'unknown') then
        print(('[John-K9] runtimecontrol.lua: runtimeSetTunable audit-trail write failed for key=%s value=%s (the change itself still succeeded and was persisted).'):format(key, valueStr))
    end

    ApplyTunableOverride(key, newValue)
    -- DISPLAY-NAME FIX (this pass) -- identical reasoning to runtimeSetFeature
    -- above: `source` is the currently-connected caller, so this resolves
    -- for free off the online branch, no database read.
    local updatedByName = (type(citizenid) == 'string' and citizenid ~= '') and ResolveDisplayName(citizenid) or nil
    -- `citizenid or 'unknown'` -- see runtimeSetFeature's identical comment
    -- above for why.
    ActiveOverrides[overrideKey] = { kind = 'tuning', value = valueStr, updatedBy = citizenid or 'unknown', updatedByName = updatedByName, updatedAt = os.date('%Y-%m-%d %H:%M:%S') }

    LogAuditInvocation(source, 'runtimeSetTunable', ('key=%s old=%s new=%s'):format(key, tostring(oldValue), valueStr), 'ok')
    return { ok = true, appliedLive = true, restartRequired = false, value = newValue }
end)

lib.callback.register('john-k9:server:runtimeResetTunable', function(source, key)
    if not (Config.Features and Config.Features.RuntimeFeatureControl == true) then
        return { ok = false, reason = 'feature_disabled' }
    end

    local authorized, citizenid = CanManageRuntimeControl(source)
    if not authorized then
        LogAuditInvocation(source, 'runtimeResetTunable', ('key=%s'):format(tostring(key)), 'denied')
        return { ok = false, reason = 'denied' }
    end

    if not RuntimeControlActionCooldown.Consume(source, RUNTIME_CONTROL_ACTION_COOLDOWN_MS) then
        return { ok = false, reason = 'rate_limited' }
    end

    local entry = type(key) == 'string' and TUNABLE_REGISTRY[key] or nil
    if not entry then
        return { ok = false, reason = 'invalid_key' }
    end

    local overrideKey = 'tuning:' .. key
    local oldValue = GetConfigByPath(entry.path)
    local defaultValue = CONFIG_LUA_DEFAULT_TUNABLES[key]

    -- CLAIMS-MORE-THAN-HAPPENED FIX (this pass): identical bug, identical
    -- fix, as runtimeResetFeature's own Override_Delete check immediately
    -- above -- see that callback's own comment for the full "silently
    -- undoes itself on the next restart" consequence this closes. Every
    -- TUNABLE_REGISTRY entry is confirmed read fresh at its point of use
    -- (this file's own "PART 1B" header, exclusion rule 3), so a
    -- successfully persisted reset is always genuinely live -- refusing
    -- BEFORE any in-memory Config mutation on a failed delete keeps that
    -- guarantee honest.
    local deleted = K9Store.Override_Delete(overrideKey)
    if not deleted then
        LogAuditInvocation(source, 'runtimeResetTunable', ('key=%s'):format(key), 'db_error')
        return { ok = false, reason = 'db_error' }
    end

    -- AUDIT-SWALLOW FIX (this pass): same reasoning as runtimeResetFeature
    -- above -- the primary write already succeeded, so `ok = true` below is
    -- correct, but a failed audit-trail insert must still leave a trace
    -- tied to this specific key.
    if not K9Store.OverrideAudit_Append(overrideKey, 'tuning', tostring(oldValue), nil, citizenid or 'unknown') then
        print(('[John-K9] runtimecontrol.lua: runtimeResetTunable audit-trail write failed for key=%s (the reset itself still succeeded and was persisted).'):format(key))
    end

    ApplyTunableOverride(key, defaultValue)
    ActiveOverrides[overrideKey] = nil

    LogAuditInvocation(source, 'runtimeResetTunable', ('key=%s restored=%s'):format(key, tostring(defaultValue)), 'ok')
    -- SHAPE-CONSISTENCY FIX (this pass): `appliedLive` was previously absent
    -- from this response even though runtimeSetTunable's own success shape
    -- always includes it (and every tunable is, by this registry's own
    -- construction, confirmed genuinely live either way) -- a consumer
    -- checking `result.appliedLive` after a Reset the same way it does
    -- after a Set would have read `nil`/falsy for an operation that is in
    -- fact exactly as live as a Set. Added for parity, never previously
    -- promised false.
    return { ok = true, value = defaultValue, appliedLive = true, restartRequired = false }
end)

-- ======================================================================
-- PART 2 CALLBACKS -- tablet theming. GetTheme is intentionally open to
-- ANY connected caller (no CanManageTabletTheme check) -- see header
-- PART 2 for why: this is read-and-applied for every viewer, not just
-- high command. Set/Reset require CanManageTabletTheme, exactly like
-- Part 1's mutations require CanManageRuntimeControl.
-- ======================================================================

lib.callback.register('john-k9:server:tabletGetTheme', function(source)
    if type(source) ~= 'number' or source <= 0 then
        return { ok = false, reason = 'invalid_source' }
    end
    local theme = {}
    for k, v in pairs(CurrentTheme) do theme[k] = v end
    return { ok = true, theme = theme }
end)

lib.callback.register('john-k9:server:tabletSetTheme', function(source, partialTheme)
    if not (Config.Features and Config.Features.TabletTheming == true) then
        return { ok = false, reason = 'feature_disabled' }
    end

    local authorized, citizenid = CanManageTabletTheme(source)
    if not authorized then
        LogAuditInvocation(source, 'tabletSetTheme', 'n/a', 'denied')
        return { ok = false, reason = 'denied' }
    end

    if not RuntimeControlActionCooldown.Consume(source, RUNTIME_CONTROL_ACTION_COOLDOWN_MS) then
        return { ok = false, reason = 'rate_limited' }
    end

    if type(partialTheme) ~= 'table' then
        LogAuditInvocation(source, 'tabletSetTheme', 'n/a', 'invalid_payload')
        return { ok = false, reason = 'invalid_payload' }
    end

    -- Merge the caller-supplied partial theme onto the CURRENT theme (never
    -- onto an empty table -- an admin changing only headerTitle must not
    -- accidentally blank every colour slot back to Lua's `nil`), THEN
    -- validate the full, merged result as one unit -- every field is
    -- re-validated even if unchanged this call, so a field that was
    -- somehow already invalid (should not be reachable, since every write
    -- path validates before persisting) can never silently persist through
    -- an unrelated edit.
    local merged = {}
    for k, v in pairs(CurrentTheme) do merged[k] = v end
    for _, field in ipairs({ 'primaryColor', 'accentColor', 'backgroundColor', 'textColor', 'density', 'headerTitle' }) do
        if partialTheme[field] ~= nil then merged[field] = partialTheme[field] end
    end

    local valid, badField = ValidateFullTheme(merged)
    if not valid then
        LogAuditInvocation(source, 'tabletSetTheme', ('field=%s'):format(tostring(badField)), 'invalid_field')
        return { ok = false, reason = 'invalid_field', field = badField }
    end

    local wrote = K9Store.Theme_Upsert(merged.primaryColor, merged.accentColor, merged.backgroundColor, merged.textColor, merged.density, merged.headerTitle, citizenid or 'unknown')
    if not wrote then
        LogAuditInvocation(source, 'tabletSetTheme', 'n/a', 'db_error')
        return { ok = false, reason = 'db_error' }
    end

    -- AUDIT-SWALLOW FIX (this pass): see runtimeSetFeature's identical
    -- comment above for the full reasoning -- the theme write already
    -- succeeded, so `ok = true` below remains correct.
    if not K9Store.ThemeAudit_Append(merged.primaryColor, merged.accentColor, merged.backgroundColor, merged.textColor, merged.density, merged.headerTitle, citizenid or 'unknown') then
        print('[John-K9] runtimecontrol.lua: tabletSetTheme audit-trail write failed (the theme change itself still succeeded and was persisted).')
    end

    CurrentTheme = merged
    LogAuditInvocation(source, 'tabletSetTheme', ('primary=%s accent=%s background=%s text=%s density=%s header=%q'):format(
        merged.primaryColor, merged.accentColor, merged.backgroundColor, merged.textColor, merged.density, merged.headerTitle
    ), 'ok')

    local broadcastTheme = {}
    for k, v in pairs(merged) do broadcastTheme[k] = v end
    TriggerClientEvent('john-k9:client:themeUpdated', -1, broadcastTheme)

    return { ok = true, theme = broadcastTheme }
end)

lib.callback.register('john-k9:server:tabletResetTheme', function(source)
    if not (Config.Features and Config.Features.TabletTheming == true) then
        return { ok = false, reason = 'feature_disabled' }
    end

    local authorized, citizenid = CanManageTabletTheme(source)
    if not authorized then
        LogAuditInvocation(source, 'tabletResetTheme', 'n/a', 'denied')
        return { ok = false, reason = 'denied' }
    end

    if not RuntimeControlActionCooldown.Consume(source, RUNTIME_CONTROL_ACTION_COOLDOWN_MS) then
        return { ok = false, reason = 'rate_limited' }
    end

    local reset = {}
    for k, v in pairs(DEFAULT_THEME) do reset[k] = v end

    local wrote = K9Store.Theme_Upsert(reset.primaryColor, reset.accentColor, reset.backgroundColor, reset.textColor, reset.density, reset.headerTitle, citizenid or 'unknown')
    if not wrote then
        LogAuditInvocation(source, 'tabletResetTheme', 'n/a', 'db_error')
        return { ok = false, reason = 'db_error' }
    end

    -- AUDIT-SWALLOW FIX (this pass): see tabletSetTheme's identical comment
    -- above for the full reasoning.
    if not K9Store.ThemeAudit_Append(reset.primaryColor, reset.accentColor, reset.backgroundColor, reset.textColor, reset.density, reset.headerTitle, citizenid or 'unknown') then
        print('[John-K9] runtimecontrol.lua: tabletResetTheme audit-trail write failed (the theme reset itself still succeeded and was persisted).')
    end

    CurrentTheme = reset
    LogAuditInvocation(source, 'tabletResetTheme', 'n/a', 'ok')

    local broadcastTheme = {}
    for k, v in pairs(reset) do broadcastTheme[k] = v end
    TriggerClientEvent('john-k9:client:themeUpdated', -1, broadcastTheme)

    return { ok = true, theme = broadcastTheme }
end)
