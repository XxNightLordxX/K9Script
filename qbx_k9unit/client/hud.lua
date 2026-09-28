--[[
    qbx_k9unit/client/hud.lua

    Phase 4. Config.Features.HealthStaminaHUD
    gate (currently `false` in config.lua — this file registers NOTHING at
    all while that stays false, see the gating note below). DEVELOPER_REFERENCE.md §6.6
    first bullet: "NUI HUD displays health and stamina for
    the active K9... only if Config.Features.HealthStaminaHUD is true."

    Authoritative contract for everything in this file:
    DEVELOPER_REFERENCE.md#hud-bridge (read that in full before
    touching the callback/message names, payload shape, focus policy, or
    push-cadence constants below — this file is a direct implementation of
    that note's §2/§3/§4/§5/§6, not an independent design pass). The NUI
    frontend (html/index.html, html/style.css, html/app.js) already exists
    and its own header comments encode the identical contract in JS-side
    terms — the two sides must match byte-for-byte on action/callback
    names and payload keys; this is the single most common silent-failure
    point in NUI code (a name that doesn't match on both sides just hangs
    or drops silently, no error thrown on either side).

    ======================================================================
    EVENT/CALLBACK CONTRACT — Phase 4 (NUI, not net events — see the design
    note §1 for why this deliberately does NOT use the
    qbx_k9unit:client:/qbx_k9unit:server: net-event prefix convention the
    rest of this codebase's RegisterNetEvent/TriggerServerEvent names use):

    1. 'hud:ready' [RegisterNUICallback, JS -> Lua, THIS FILE]
       Fired once by html/app.js immediately after it attaches its
       `message` listener (see that file's init()/sendReadyAck() ordering
       comment). Fire-and-forget from the JS side — cb({}) is called
       unconditionally and immediately, since there is nothing meaningful
       to return, but ALSO used here as the trigger to push one immediate
       vitals snapshot (design note §5 point 6) rather than making a
       freshly-loaded HUD wait out the ~1s heartbeat ceiling for its first
       paint.
    2. 'hud:updateVitals' [SendNUIMessage, Lua -> JS, THIS FILE]
       The one and only ongoing push. Payload shape (design note §3):
           {
             action = 'hud:updateVitals',
             data = {
               visible = <boolean>,
               health  = <number>,  -- 0-100
               stamina = <number>,  -- 0-100
             },
           }
       `visible` and all four numbers are ALWAYS sent together, never
       split into separate messages (design note §3's rationale: a split
       design can desync if one message is dropped). When visibility
       transitions to false, the last REAL known values are sent alongside
       `visible = false` — never zeroed out — so a quick false->true flip
       doesn't show a stale-zero flash on the JS side before the next real
       poll tick lands.
    ======================================================================

    ======================================================================
    WELLBEING / XP TIER EXTENSION. Same message action, same single
    combined push (`hud:updateVitals`) as above — no new action name, no
    second message, per the same "never split, so a dropped message can't
    desync fields" rationale the original four vitals already follow. The
    payload's `data` object gains two new keys, ALWAYS present as tables
    (possibly with some/all of their own keys absent), sent alongside
    `visible`/health/stamina on every push:

        data.wellbeing = {
          fatigue    = <number 0-100>,  -- KEY ABSENT unless Config.Features.FatigueSystem
        }
        data.xpTier = {
          label = <string>,  -- KEY ABSENT unless Config.Features.XPProgression AND a
                              -- tier snapshot has actually been received client-side
          badge = <string>,  -- KEY ABSENT unless label above is also present AND the
                              -- current tier's own Config.XPTiers[n].badge (or a live
                              -- DB override -- server/xptiers.lua's own XPTiersUpsert)
                              -- is a non-empty string. THIS FIELD IS THE FIX for the
                              -- previously-disclosed gap in server/progression.lua's
                              -- own "XP TIER UNLOCKS" section ("Elite -- SERVER HALF
                              -- WIRED, DISPLAY NOT WIRED... client/hud.lua's PushVitals
                              -- only ever sends xpTier.label... html/app.js has no
                              -- badge handling at all"): that comment can now be
                              -- flipped to WIRED (server/progression.lua is owned by
                              -- coder-backend/coder-security, not touched by this
                              -- pass — flagged to them separately rather than left
                              -- silently stale). Purely cosmetic, same posture as
                              -- config.lua's own Elite-row comment ("Display only, no
                              -- mechanical effect") — grants nothing, gates nothing.
        }

    A key's ABSENCE (not a zeroed/false/empty-string value) is how a
    disabled feature — or, for xpTier.label/xpTier.badge, a not-yet-known
    tier or a tier with no configured badge — is signaled. html/app.js must
    render that element as genuinely gone from the DOM (its row hidden),
    never as a blank/zero placeholder — must be absent, not blank or
    zeroed. This mirrors the flag-gated inertness client/wellbeing.lua and
    client/progression.lua already both apply to their OWN gating (a
    disabled feature's section is inert, not merely quiet).

    DATA SOURCE — NO NEW SERVER ROUND TRIP, EITHER FOR WELLBEING OR XP:
      - Wellbeing (fatigue): this file
        registers its OWN independent RegisterNetEvent handler on
        'qbx_k9unit:client:wellbeingUpdate' — the SAME event
        client/wellbeing.lua's own handler already consumes (FiveM allows
        multiple independent handlers per event name; RegisterNetEvent's
        two-argument form both (re-)registers the event name and attaches
        a NEW handler each time it's called, it does not replace a prior
        handler). This file's handler only mirrors the payload into a
        local read-only `wellbeingCache` for display — it never calls
        client/wellbeing.lua's ApplyWellbeingSnapshot, never touches
        K9MoveRateModifiers, and never itself calls the
        'qbx_k9unit:server:getWellbeingSnapshot' callback
        client/wellbeing.lua already owns. See `wellbeingCache`'s own
        comment below for the one disclosed consequence of this approach
        (bounded staleness right after a K9-model transition, before the
        first periodic tick broadcast lands — client/wellbeing.lua's own
        on-demand catch-up fetch for that moment is applied locally inside
        that file only, never re-broadcast as this same event).
      - XP tier (xpTier.label, xpTier.badge): both read off the SAME
        `GetCurrentXPTier()` table, the resource-global client/progression.lua
        already exposes for exactly this "future HUD/display need" (see
        that file's own header) — called behind a
        `type(GetCurrentXPTier) == 'function'` guard, this codebase's
        established soft-dependency convention (mirrors
        client/progression.lua's own guard on RecomputeK9MoveRate), even
        though the symbol is already declared in .luacheckrc's `globals`
        list — the guard covers the real runtime case where
        Config.Features.XPProgression is false and client/progression.lua
        returns at its own top-of-file gate before ever defining the
        function at all. `badge` is read from the exact same cached tier
        table `label` already was — no second accessor, no second
        soft-dependency guard, no new server round trip.

    CROSS-FILE COORDINATION NOTE FOR WHOEVER NEXT TOUCHES
    client/wellbeing.lua: this file deliberately does NOT ask that file for
    a new accessor — see the "NO NEW SERVER ROUND TRIP" note above for why
    the existing net-event is sufficient. No .luacheckrc change and no
    wellbeing.lua change are required for this HUD extension to work as
    written.

    PER-TICK COST of this extension (same 250ms/1000ms cadence as
    before — no new thread, no tightened interval): a handful of local
    table field reads (`wellbeingCache.*`, already up to date from the
    push-driven event listener above, not polled), up to 5 extra
    `math.abs`/equality comparisons in the existing change-detection check
    below (skipped entirely per-field when that field's owning flag is
    off, via short-circuited `and`), one optional resource-global function
    call (`GetCurrentXPTier()`, itself just a table field return — no
    network, no native call), and two small extra sub-tables added to the
    SAME SendNUIMessage payload this thread already constructs every push.
    No new native calls, no new network round trips, no new allocations
    beyond those two small sub-tables.
    ======================================================================

    GATING — "gate at registration, not just inside the loop":
    mirrors client/movement.lua's AgilityBasicJump thread
    (`if not Config.Features.AgilityBasicJump then CreateThread(...) end`)
    and client/vision.lua's `if Config.Features.ThermalVision then
    RegisterCommand(...)/RegisterKeyMapping(...) end` — the flag is
    checked ONCE at file-load time to decide whether to register the NUI
    callback / start the poll thread AT ALL, not read once at the top of
    an always-running loop body. While Config.Features.HealthStaminaHUD is
    `false` (the shipped default), this file registers zero NUI callbacks
    and starts zero threads — not merely "renders nothing," genuinely
    inert.

    VISIBILITY GATE — RESOLVED per design note §6: `CanShowK9UI()`
    (IsOwnModelK9() AND HasK9Access()), the SAME combinator
    client/radial.lua's Bark/Sit/Leash/Vehicle items and client/vehicle.lua
    already gate on — deliberately NOT `IsOwnModelK9()` alone (that would
    be client/vision.lua's thermal/night-vision precedent, which does not
    apply here: this HUD is a department-issued monitoring instrument per
    DEVELOPER_REFERENCE.md §6.1's own acceptance criterion grouping it with the radial
    menu, not the K9's innate perception). Do not regress this to
    IsOwnModelK9() alone — see design note §6 for the full "innate
    perception vs. granted privilege" reasoning on both sides of this call.

    "...or nearby" (a handler seeing their PARTNER K9's vitals) is
    explicitly OUT OF SCOPE here per design note §6 — this file only ever
    reads/pushes the LOCAL player's own vitals, gated on the LOCAL
    player's own CanShowK9UI(). Flagged to resolve separately, not decided
    or half-built here.

    FOCUS POLICY — NO SetNuiFocus, ANYWHERE, EVER, IN THIS FILE. This is a
    passive, always-visible-while-relevant overlay with zero player-driven
    interaction (design note §4) — no buttons, no dismiss, nothing to
    click or type into, so there is no escape/close-path handling either
    (no Escape keylistener, no close callback) — that entire "stuck open
    with focus grabbed" bug class structurally cannot occur on a surface
    that never grabs focus in the first place. If a future revision adds
    an actual interactive element to html/index.html, that is a signal to
    STOP and re-decide the whole focus question, not to bolt SetNuiFocus
    onto this file's existing focus-free lifecycle.

    STAMINA NATIVE — CONFIDENCE NOTE, RESOLVED: this file calls
    GetPlayerSprintStaminaRemaining(PlayerId()), which the design note §3
    correctly identifies as existing with range [0.0-100.0], but the
    NAME is misleading — the native tracks sprint EXERTION, rising toward
    100 as the player tires, not stamina remaining. Multiple independent,
    widely-used community HUD resources (status-hud, ps-hud, qz-hud,
    apx_hud) and Cfx forum threads consistently confirm this and compute
    displayed stamina as `100 - GetPlayerSprintStaminaRemaining(...)`. The
    ReadVitals() code below now does the same subtraction so "stamina" on
    the HUD bar means what it says (full when fresh, draining as the K9
    tires).

    HUNGER/THIRST ROWS REMOVED (owner directive: "hungerthirstsystem" is
    one of the subsystems removed completely). This HUD used to carry two
    further bars alongside health and stamina, read from
    `QBX.PlayerData.metadata.hunger`/`.thirst`. The K9-specific
    hunger/thirst mechanic was already gone by then; what those two bars
    still showed was the PLAYER's ordinary framework hunger and thirst,
    which the server's own core HUD already displays -- so they were both
    a duplicate readout and the last visible trace of a removed feature.
    Deleted here, in html/index.html, html/app.js and html/style.css
    together; the wire contract in this header no longer carries the two
    fields at all.

    ONRESOURCESTOP — deliberately NOT added. Contrast client/vision.lua's
    onResourceStop handler, which exists because SetSeethrough/
    SetNightvision are REAL ENGINE STATE that persists across a resource
    restart independent of script state (a native post-effect toggle left
    on with no script left alive to turn it off). This file has no
    equivalent sticky state to clean up: it never calls SetNuiFocus, never
    toggles any native/engine-persistent effect, and its only two side
    effects are (a) a `while true` CreateThread loop, which FiveM already
    tears down automatically the instant this resource stops, and (b)
    SendNUIMessage pushes into html/index.html's own browser context,
    which is unloaded/destroyed by FiveM the moment this resource (the
    `ui_page` owner) stops — there is no "HUD left stuck visible after
    resource stop" failure mode possible, since the page rendering it stops
    existing at the same moment. Revisit only if a future revision of this
    file adds state that genuinely outlives the resource (it should not,
    for a passive display-only overlay).
]]

-- ============================================================================
-- HANDLER CONDITION BADGE (this pass, coder-backend) -- see
-- server/wellbeing.lua's own "HANDLER CONDITION BADGE" header section for
-- the full server-side design this renders. Closes a production-readiness
-- audit's own "the single best remaining thing to build" finding: a
-- handler (the human officer, NEVER the player controlling the dog) had no
-- way to learn their own bonded K9 partner's wellbeing short of the other
-- player typing it out of character.
--
-- DELIBERATELY ABOVE Config.Features.HealthStaminaHUD's early-return
-- (immediately below this block) — THIS IS NOT A BUG, READ BEFORE MOVING
-- IT: HealthStaminaHUD gates the K9's OWN on-screen vitals (health/
-- stamina/wellbeing bars) for whoever is CURRENTLY PLAYING
-- THE DOG. This feature is for the opposite audience — a plain officer who
-- is NOT their own K9, so CanShowK9UI() (IsOwnModelK9() AND HasK9Access())
-- is false for them essentially always. Gating this badge behind the same
-- flag as the K9's own vitals HUD would tie two logically independent
-- audiences to one operator switch for no reason, and would make this
-- feature permanently invisible on any server that ships with
-- HealthStaminaHUD left at its own documented-provisional `false` default
-- (config.lua) while still wanting handlers to see their partner's
-- condition. The server already independently gates whether this feature
-- has anything to send at all (Config.Features.HandlerPartnership plus,
-- per tag, each stat's own owning flag — server/wellbeing.lua's
-- PushHandlerConditionUpdate/ComputeHandlerConditionTags); this file adds
-- no redundant client-side flag gate on top of that.
--
-- REGISTERED UNCONDITIONALLY, NOT GATED AT FILE-LOAD TIME LIKE THE REST OF
-- THIS FILE'S "GATING" CONVENTION: this file's own established rule
-- ("check the flag once at file-load time, register nothing while it's
-- off") exists to avoid starting an expensive CreateThread poll loop for
-- nothing — see this file's own "GATING" header note. There is no thread
-- here to avoid starting: a bare RegisterNetEvent costs nothing beyond
-- registering a dormant handler, and the SERVER is the sole authority on
-- whether this event is EVER actually sent (see above) — registering
-- unconditionally here, rather than mirroring the wellbeingCache
-- listener's own `ANY_WELLBEING_ELEMENT_ENABLED`-gated pattern further
-- down this file, avoids that OTHER listener's own disclosed limitation (a
-- feature flag flipped ON live, after this client already connected with
-- every relevant flag off, would never be picked up without a resource
-- restart) at zero extra cost — there being no thread to (not) start is
-- exactly what makes doing this differently from that other, pre-existing
-- listener the more correct choice here, not a deviation invented for its
-- own sake.
--
-- PURELY A FORWARDING RELAY — no locale text is embedded in the network
-- payload (server/wellbeing.lua sends only fixed, non-numeric TAG CODES,
-- never pre-rendered text, so the same payload works regardless of this
-- client's own locale). This file resolves each tag's PLAYER-VISIBLE
-- STRING via the shared ox_lib `locale()` function (locales/en.json's
-- `hud` group, ADDITIVE new keys this pass) exactly ONCE, at file-load
-- time (cheap, never re-resolved per message), and forwards the resolved
-- table to html/app.js as `data.strings` — mirroring the SAME
-- `data.strings` shape this file's own header already documents
-- html/app.js as expecting for the pre-existing Distraction status row
-- (`hud.distraction_active`/`hud.distraction_clear`), the established
-- convention for locale text on this NUI surface. html/app.js keeps its
-- own hardcoded English fallback table for defense-in-depth (a
-- malformed/missing `strings` entry never renders blank), same as every
-- other locale-carrying message on this surface.
--
-- SOURCE-ORIGIN GUARD, PAYLOAD VALIDATION: same `source ~= 65535` check,
-- same reasoning, as every other server->client event handler in this
-- file/this resource — a locally-triggered TriggerEvent (not
-- TriggerClientEvent from the real server) would otherwise be
-- indistinguishable from a genuine server push. `payload.tags` is walked
-- defensively (only string entries survive) rather than forwarded
-- verbatim — this page's own NO innerHTML / textContent-only rendering
-- (html/app.js) already makes an unexpected tag harmless even without
-- this, but never trusting a network payload's exact shape is this
-- resource's own standing convention regardless of what the immediate
-- consumer happens to do with it.
-- ============================================================================
local PARTNER_CONDITION_EVENT = 'qbx_k9unit:client:partnerConditionUpdate'

--- Resolved ONCE, at file-load time — see this section's own "PURELY A
--- FORWARDING RELAY" note above for why this is never re-resolved per
--- message. Keys match exactly the six possible tag codes
--- server/wellbeing.lua's ComputeHandlerConditionTags can ever emit, plus
--- 'fine' (shown when `tags` arrives empty) and 'label' (this badge's own
--- heading).
local PARTNER_CONDITION_STRINGS = {
    tired = locale('hud.partner_condition_tired'),
    fine = locale('hud.partner_condition_fine'),
    label = locale('hud.partner_condition_label'),
}

RegisterNetEvent(PARTNER_CONDITION_EVENT, function(payload)
    if source ~= 65535 then return end
    if type(payload) ~= 'table' then return end

    local visible = payload.visible == true
    local tags = {}
    if visible and type(payload.tags) == 'table' then
        for i = 1, #payload.tags do
            if type(payload.tags[i]) == 'string' then
                tags[#tags + 1] = payload.tags[i]
            end
        end
    end

    SendNUIMessage({
        action = 'hud:partnerCondition',
        data = {
            visible = visible,
            tags = tags,
            strings = PARTNER_CONDITION_STRINGS,
        },
    })
end)

-- ============================================================================
-- K9 ONBOARDING HINT (Config.K9Onboarding.enabled) -- ease-of-use audit
-- finding, this pass: a brand-new K9 or handler's ENTIRE onboarding is one
-- fire-and-forget chat line (locales/en.json's
-- appearance.apply_success_target), sent exactly once, at the moment their
-- role is granted -- "You are now a K9. Open your tablet with /k9tablet and
-- read the Help tab...". Miss that one line (tabbed out, mid-conversation,
-- chat scrolled) and there is nothing else anywhere in this resource that
-- ever tells them the tablet exists at all. This section is the second
-- chance: a small, PERSISTENT, DISMISSIBLE on-screen nudge that keeps
-- coming back -- across reconnects, not just within one session -- until
-- they either open the tablet for real or dismiss it themselves.
--
-- DELIBERATELY ABOVE Config.Features.HealthStaminaHUD's early-return below,
-- same reasoning as the HANDLER CONDITION BADGE section immediately above
-- this one: this nudge has nothing to do with the K9's own vitals bars, and
-- gating it behind that flag would make it permanently invisible on any
-- server that turns HealthStaminaHUD off for an entirely unrelated reason.
--
-- DELIBERATELY NOT A Config.Features KEY: this resource's own drift-guard
-- suite (tests/runtimefeaturetiers_spec.lua, tests/tabletfeaturedomains_spec.lua,
-- tests/customizationregistry_spec.lua and others) requires EVERY
-- Config.Features key to carry a runtime-control tier
-- (server/runtimecontrol.lua), a tablet feature-domain
-- (server/tablet.lua), and either a per-person server-side block path or a
-- reviewed exemption -- real governance machinery for a feature with a
-- server-side access decision to gate. This nudge has none of that: it is
-- a purely client-local, cosmetic discovery aid with no server round trip
-- at all, closer in kind to Config.LeashVisual.enabled (an "extra operator
-- kill-switch... independent of" the governed feature it rides on) than to
-- a governed Config.Features entry. Config.K9Onboarding.enabled below is
-- that same kind of switch: still config-driven, still off-able by a
-- non-technical owner, without pulling in machinery built for a different
-- kind of feature.
--
-- ELIGIBILITY (re-derived every tick, never cached beyond one poll
-- interval): CanShowK9UI() is true (the SAME "on-duty, access-granted K9 or
-- role holder" combinator every other K9 UI element in this resource
-- already gates on -- client/main.lua) AND this specific CITIZENID has
-- never durably opened the tablet AND never durably dismissed this hint.
-- No per-person block check here (unlike the vitals poll thread further
-- down, which checks IsK9FeatureBlocked('HealthStaminaHUD')) -- that
-- mechanism exists for governed Config.Features keys, which this
-- deliberately is not (see above); wiring it in for a name nothing could
-- ever actually set would just imply a control surface that does not
-- exist.
--
-- TIME WINDOW, PER SESSION, NOT PER LIFETIME: once eligible, the nudge stays
-- visible for up to Config.K9Onboarding.nudgeDurationMinutes minutes of
-- THIS session, then auto-hides. That auto-hide is NOT a durable dismissal
-- -- it comes back and shows again next time this citizenid reconnects (or
-- the next time CanShowK9UI() turns true mid-session, whichever happens
-- first), for as long as they still have not opened the tablet or
-- dismissed it. This is deliberate: a player who was genuinely tabbed out
-- for the entire window must not be left permanently unhelped just because
-- one timer ran out while they were not looking -- that is the exact bug
-- this section exists to fix, and a one-shot timer would just move it
-- somewhere else.
--
-- GONE FOR GOOD, IMMEDIATELY, the instant EITHER of these two happens
-- (never both required, and both are recorded DURABLY -- see "DURABLE
-- STORAGE" below):
--   1. The tablet is opened -- through ANY door (command, item, or the K9
--      radial menu), all of which funnel through client/tablet.lua's
--      OpenTablet(), which always SendNUIMessage({action = 'tablet:open',
--      ...}) before anything else. That message lands on the SAME
--      top-level window this page's own html/app.js already listens on --
--      html/tablet-bridge.js's own header already establishes that a
--      second, independent `message` listener on that one window coexists
--      with zero interference; app.js's own listener picking up this SAME
--      message is the identical pattern, not a new one. app.js relays that
--      fact into THIS file's own 'hud:tabletOpened' NUI callback below.
--      NOTHING in client/tablet.lua, html/tablet.js, or
--      html/tablet-bridge.js is touched, or needs to be, for this to work.
--   2. The player presses Config.K9Onboarding.dismissControl (default:
--      Backspace / Xbox B) WHILE the nudge is actually on screen. See
--      ONBOARD_DISMISS_CONTROL's own comment below for why this is a raw
--      IsDisabledControlJustPressed() read rather than a RegisterCommand/
--      RegisterKeyMapping pair.
--
-- DURABLE STORAGE -- BY CITIZENID, NEVER BY SOURCE/SERVER ID: this file
-- uses this CLIENT's own KVP store (GetResourceKvpString/
-- SetResourceKvp), keyed by this literal citizenid string, for both
-- "opened the tablet" and "dismissed the hint". Never keyed by `source`
-- (the numeric server id) -- server ids are RECYCLED the moment a
-- connection drops, so a brand-new player's very first connection this
-- session could be handed a stranger's old, already-onboarded id; keying
-- by citizenid instead means a new citizenid always starts with a clean
-- slate, and switching characters never lets one identity's history leak
-- into another's.
-- HONEST LIMITATION, DISCLOSED: KVP is local to THIS FiveM client install,
-- not this server's own central database -- it is not touched by, and does
-- not touch, server/*.lua at all (this section adds no new server file, no
-- new net event, no new table). A player who plays the same citizenid from
-- a genuinely different PC sees the hint again there once, which is the
-- correct, safe failure mode for a fresh device -- a future pass could
-- upgrade this to a server-persisted flag (metadata, mirroring how
-- `k9certified` already round-trips through Player.Functions.SetMetaData),
-- but that touches server files outside this pass's edit scope, so it is
-- flagged here rather than silently half-built.
-- ============================================================================
local ONBOARD_CFG = type(Config.K9Onboarding) == 'table' and Config.K9Onboarding or {}

-- Gate at registration, same "check once at file-load time" convention
-- this file's own header already establishes for
-- Config.Features.HealthStaminaHUD below -- while
-- Config.K9Onboarding.enabled is false, nothing inside this `if` ever
-- runs: zero NUI callbacks, zero threads. Read with `~= false` rather
-- than `== true`/truthy: an operator who adds a Config.K9Onboarding table
-- of their own without an explicit `enabled` line (nil) gets the feature
-- ON, matching this table's own shipped default and every other boolean
-- field in this resource that defaults to "on unless explicitly turned
-- off". Deliberately a plain `if ... then ... end`, NOT a `do return end`
-- guard -- unlike Config.Features.HealthStaminaHUD's own file-level early
-- return a few dozen lines below (which is correct there because nothing
-- after it should ever run with that flag off), a bare `return` here
-- would abort this entire file -- including the vitals HUD/wellbeing/
-- partner-badge sections below, which have nothing to do with this flag.
if ONBOARD_CFG.enabled ~= false then
    local onboardCfg = ONBOARD_CFG

    -- CONFIG SAFETY -- clamp-and-warn, NEVER a bare assert (this resource's
    -- own standing rule; mirrors client/leashvisual.lua's
    -- ResolvePositiveNumber precedent exactly). A bad Config.K9Onboarding
    -- value must never take this file's registration down for the rest of
    -- this client's session.
    local ONBOARD_DEFAULT_NUDGE_MINUTES = 5
    local nudgeMinutes = onboardCfg.nudgeDurationMinutes
    if type(nudgeMinutes) ~= 'number' or nudgeMinutes ~= nudgeMinutes or nudgeMinutes <= 0 then
        print(('[qbx_k9unit] hud.lua: Config.K9Onboarding.nudgeDurationMinutes is missing or not a positive number (found: %s). Using %s instead.')
            :format(tostring(nudgeMinutes), tostring(ONBOARD_DEFAULT_NUDGE_MINUTES)))
        nudgeMinutes = ONBOARD_DEFAULT_NUDGE_MINUTES
    end
    local ONBOARD_NUDGE_WINDOW_MS = nudgeMinutes * 60000

    -- Raw GTA control ID for the dismiss action -- deliberately NOT a
    -- RegisterCommand/RegisterKeyMapping pair. Adding any new
    -- RegisterCommand('...') literal anywhere in this resource requires a
    -- matching html/tablet.js COMMAND_REFERENCE entry
    -- (tests/commandreferenceregistry_spec.lua drift-guards this) AND a
    -- matching client/commandsuggestions.lua entry
    -- (tests/commandsuggestions_spec.lua drift-guards THAT) -- both outside
    -- this pass's edit scope (html/tablet.js is explicitly off-limits, and
    -- client/commandsuggestions.lua has another agent live in it this same
    -- pass). A pure IsDisabledControlJustPressed() read below registers
    -- nothing at all: it cannot desync from either drift guard because it
    -- never adds the one thing either of them looks for.
    --
    -- WHY IsDisabledControlJustPressed, NOT IsControlJustPressed: the
    -- former is ALREADY the exact native this resource's own
    -- client/tablet.lua relies on for its own Escape-key handling (see the
    -- root .luacheckrc's own read_globals entry for the verification
    -- citation -- IS_DISABLED_CONTROL_JUST_PRESSED, hash
    -- 0x91AEF906BCA88877, confirmed against the native hash database), and
    -- it reads the control regardless of whatever ELSE may have disabled
    -- it that frame -- the more robust choice for a background hotkey read
    -- that must not silently miss a press just because some other system
    -- disabled controls that frame. This never disables the control
    -- itself (that would need a separate DisableControlAction call, never
    -- made here) -- it is a passive read, same as IsControlJustPressed
    -- would have been, just less likely to miss the press.
    --
    -- CONTROL ID CONFIDENCE NOTE -- HONEST, NOT INDEPENDENTLY VERIFIED
    -- IN-ENGINE THIS PASS (same posture as this file's own "STAMINA
    -- NATIVE" note above -- this is about the NUMBER 202, not about
    -- whether the native itself exists, which the citation above already
    -- settles): 202 is widely and consistently documented, across
    -- independent FiveM/GTA native control-ID references, as
    -- INPUT_FRONTEND_CANCEL -- Backspace on keyboard, B on an Xbox pad --
    -- a "back/cancel/close" control the base game itself only actively
    -- uses inside its own menus, not during ordinary on-foot/vehicle play,
    -- and one none of this resource's own RegisterKeyMapping defaults
    -- (H/J/K/I and friends -- client/vision.lua, client/keybinds.lua)
    -- ever claim. Change
    -- Config.K9Onboarding.dismissControl (and its matching
    -- dismissControlLabel, shown in the hint text itself) if this ever
    -- turns out to collide with something else on your own server.
    local ONBOARD_DEFAULT_DISMISS_CONTROL = 202
    local dismissControl = onboardCfg.dismissControl
    if type(dismissControl) ~= 'number' or dismissControl ~= dismissControl or dismissControl < 0 then
        print(('[qbx_k9unit] hud.lua: Config.K9Onboarding.dismissControl is missing or not a non-negative number (found: %s). Using %s (INPUT_FRONTEND_CANCEL) instead.')
            :format(tostring(dismissControl), tostring(ONBOARD_DEFAULT_DISMISS_CONTROL)))
        dismissControl = ONBOARD_DEFAULT_DISMISS_CONTROL
    end
    local ONBOARD_DISMISS_CONTROL = math.floor(dismissControl)

    local ONBOARD_DEFAULT_DISMISS_LABEL = 'Backspace'
    local dismissLabel = onboardCfg.dismissControlLabel
    if type(dismissLabel) ~= 'string' or dismissLabel == '' then
        dismissLabel = ONBOARD_DEFAULT_DISMISS_LABEL
    end
    local ONBOARD_DISMISS_LABEL = dismissLabel

    -- Resolved ONCE, at file-load time -- same "never re-resolved per
    -- message" posture as PARTNER_CONDITION_STRINGS above.
    local ONBOARD_STRINGS = {
        title = locale('hud.onboarding_title'),
        body = locale('hud.onboarding_body'),
        dismissHint = locale('hud.onboarding_dismiss_hint', ONBOARD_DISMISS_LABEL),
    }
    -- The dog and the handler each get the one line that matters to them.
    local ONBOARD_HANDLER_BODY = locale('hud.onboarding_body_handler')

    -- Tick cadence -- same idle/active TWO-SPEED PATTERN this file already
    -- established for the vitals poll thread below (HUD_POLL_TICK_MS/
    -- HUD_IDLE_TICK_MS), reused here rather than inventing a third scheme.
    -- Nothing in THIS thread needs 250ms responsiveness the way a
    -- live-changing numeric bar does -- a second's delay noticing a
    -- dismiss keypress, or noticing the timer ran out, is imperceptible
    -- for a discovery hint -- so both numbers here are deliberately
    -- coarser than HUD_POLL_TICK_MS/HUD_IDLE_TICK_MS, not copies of them.
    local ONBOARD_ACTIVE_TICK_MS = 1000  -- while eligible (showing or about to show)
    local ONBOARD_IDLE_TICK_MS = 10000   -- while not currently eligible at all -- nothing here can change any faster than a role grant/revoke or a reconnect, both already slow events

    local ONBOARD_KVP_OPENED_PREFIX = 'qbx_k9unit_onboard_opened_'
    local ONBOARD_KVP_DISMISSED_PREFIX = 'qbx_k9unit_onboard_dismissed_'

    --- @return string|nil -- nil while QBX.PlayerData has not populated a
    --- citizenid yet -- QBX.PlayerData may not be populated this early in
    --- a session, so never trust it is already there.
    local function GetOwnCitizenId()
        local playerData = QBX and QBX.PlayerData
        local citizenid = playerData and playerData.citizenid
        if type(citizenid) == 'string' and citizenid ~= '' then return citizenid end
        return nil
    end

    --- @param citizenid string
    --- @return boolean
    local function HasDurablyOpenedTablet(citizenid)
        return GetResourceKvpString(ONBOARD_KVP_OPENED_PREFIX .. citizenid) == '1'
    end

    --- @param citizenid string
    local function MarkDurablyOpenedTablet(citizenid)
        SetResourceKvp(ONBOARD_KVP_OPENED_PREFIX .. citizenid, '1')
    end

    --- @param citizenid string
    --- @return boolean
    local function HasDurablyDismissedHint(citizenid)
        return GetResourceKvpString(ONBOARD_KVP_DISMISSED_PREFIX .. citizenid) == '1'
    end

    --- @param citizenid string
    local function MarkDurablyDismissedHint(citizenid)
        SetResourceKvp(ONBOARD_KVP_DISMISSED_PREFIX .. citizenid, '1')
    end

    -- Last-pushed visibility + this session's own window start time. Kept
    -- SEPARATE from `hudState` above -- this feature has its own
    -- independent flag (Config.K9Onboarding.enabled), its own message
    -- action ('hud:onboardingHint'), and no data in common with the
    -- vitals HUD's own state.
    local onboardState = {
        visible = false,
        windowStartedAt = nil, -- GetGameTimer() timestamp this session's window began, or nil before it ever has
        citizenidWhenStarted = nil, -- see the thread body below for why this is re-checked every tick, not just read once
    }

    --- @param visible boolean
    local function PushOnboardVisibility(visible)
        onboardState.visible = visible
        local amDog = type(IsOwnModelK9) == 'function' and IsOwnModelK9()
        SendNUIMessage({
            action = 'hud:onboardingHint',
            data = { visible = visible, strings = {
                title = ONBOARD_STRINGS.title,
                body = amDog and ONBOARD_STRINGS.body or ONBOARD_HANDLER_BODY,
                dismissHint = ONBOARD_STRINGS.dismissHint,
            } },
        })
    end

    -- ------------------------------------------------------------------
    -- 'hud:tabletOpened' -- see this section's header point 1 above. Fired
    -- by html/app.js the instant it independently observes a 'tablet:open'
    -- SendNUIMessage push arrive on the shared top-level window -- see
    -- that file's own handleTabletOpened() for the JS half of this
    -- handshake. cb({}) fires immediately and unconditionally, same
    -- convention as 'hud:ready' above (an uninvoked NUI callback hangs the
    -- calling fetch forever).
    -- ------------------------------------------------------------------
    RegisterNUICallback('hud:tabletOpened', function(_, cb)
        cb({})

        local citizenid = GetOwnCitizenId()
        if citizenid then
            MarkDurablyOpenedTablet(citizenid)
        end
        if onboardState.visible then
            PushOnboardVisibility(false)
        end
    end)

    -- ------------------------------------------------------------------
    -- Poll thread -- see this section's header for the full eligibility/
    -- window/dismiss contract this implements.
    -- ------------------------------------------------------------------
    CreateThread(function()
        while true do
            local citizenid = GetOwnCitizenId()

            if citizenid ~= onboardState.citizenidWhenStarted then
                -- Either the very first citizenid this session has ever
                -- seen, or (defensive: a character switch WITHOUT a
                -- reconnect, which some frameworks allow -- QBX.PlayerData
                -- would update in place with no resource restart at all)
                -- a genuinely NEW identity replacing a previous one.
                -- Either way, any in-progress window belongs to whichever
                -- citizenid was active when it started, never to this new
                -- one -- forget it and let the checks below decide fresh.
                onboardState.citizenidWhenStarted = citizenid
                onboardState.windowStartedAt = nil
                if onboardState.visible then
                    PushOnboardVisibility(false)
                end
            end

            -- No per-person block check here (unlike the vitals poll
            -- thread further down's IsK9FeatureBlocked('HealthStaminaHUD')
            -- check) -- see this section's own header "DELIBERATELY NOT A
            -- Config.Features KEY" note for why: that mechanism exists for
            -- governed Config.Features keys, which this deliberately is
            -- not.
            local durablySuppressed = citizenid == nil
                or HasDurablyOpenedTablet(citizenid)
                or HasDurablyDismissedHint(citizenid)
            -- The K9 itself, or a handler who has just partnered up with one.
            local eligible = (not durablySuppressed)
                and (CanShowK9UI() or (type(IsPartnered) == 'function' and IsPartnered()))

            if not eligible then
                onboardState.windowStartedAt = nil
                if onboardState.visible then
                    PushOnboardVisibility(false)
                end
                Wait(ONBOARD_IDLE_TICK_MS)
            else
                local now = GetGameTimer()
                if not onboardState.windowStartedAt then
                    onboardState.windowStartedAt = now
                end

                -- Only worth reading the dismiss control while the hint is
                -- ACTUALLY on screen right now (onboardState.visible
                -- reflects what was pushed as of the end of the last
                -- pass) -- pressing this key while nothing is showing has
                -- nothing to dismiss, and must not be misread as one.
                local justDismissed = false
                if onboardState.visible and IsDisabledControlJustPressed(0, ONBOARD_DISMISS_CONTROL) then
                    MarkDurablyDismissedHint(citizenid)
                    justDismissed = true
                end

                local withinWindow = (not justDismissed) and (now - onboardState.windowStartedAt) < ONBOARD_NUDGE_WINDOW_MS
                if withinWindow ~= onboardState.visible then
                    PushOnboardVisibility(withinWindow)
                end

                Wait(ONBOARD_ACTIVE_TICK_MS)
            end
        end
    end)
end

if not Config.Features.HealthStaminaHUD then return end

-- ----------------------------------------------------------------------
-- Tuning constants — code-local, not Config.* entries, matching how
-- client/movement.lua's LEASH_TICK_MS/LEASH_IDLE_TICK_MS and
-- LEASH_PULL_ZONE_FACTOR/LEASH_HARD_CAP_FACTOR are file-local tuning
-- knobs rather than exposed config (design note §5's closing note: "None
-- of the above needs a config addition").
-- ----------------------------------------------------------------------
local HUD_POLL_TICK_MS = 250   -- design note §5.1: active poll cadence while visible
local HUD_IDLE_TICK_MS = 1000  -- design note §5.4: idle backoff while not visible
local HUD_HEARTBEAT_MS = 1000  -- design note §5.3: forced re-push ceiling even with no real change
local HUD_CHANGE_EPSILON = 0.5 -- design note §5.2: per-field change threshold (0-100 scale) before re-pushing; reused unchanged for the wellbeing numeric fields below (same 0-100 contract)

-- Shared, reused (never mutated) metatable forcing dkjson (this runtime's
-- `json.encode`, which SendNUIMessage's table-argument path encodes
-- through) to serialize a table as a JSON object (`{}`/`{...}`) even when
-- it has zero keys, rather than defaulting an empty table to `[]` — see
-- PushVitals below, where this is applied to the `wellbeing`/`xpTier`
-- sub-tables every push, for the full reasoning. One shared table reused
-- via setmetatable on each push (never recreated per-push) so this costs
-- nothing beyond the two setmetatable calls already cheap on their own.
local JSON_FORCE_OBJECT_MT = { __jsontype = 'object' }

-- Which of the five wellbeing HUD elements are live, computed ONCE at
-- file-load time (see this file's header "GATING" note — the same
-- check-once-not-every-tick posture applies here) so the poll thread below
-- never re-reads Config.Features.* per field per tick. Independent of
-- Config.Features.HealthStaminaHUD itself (already guaranteed true, since
-- this whole file returned early above if it weren't) — these five flags
-- gate each wellbeing ROW independently, gated so each element only
-- appears when its own feature is enabled.
local WELLBEING_ELEMENT_ENABLED = {
    fatigue = Config.Features.FatigueSystem,
}
local ANY_WELLBEING_ELEMENT_ENABLED = WELLBEING_ELEMENT_ENABLED.fatigue

-- Same "computed once, not every tick" posture for the XP tier row.
local XP_TIER_ELEMENT_ENABLED = Config.Features.XPProgression

-- Last-pushed snapshot, also doubling as the "last real known values" the
-- design note §3 requires be resent (never zeroed) alongside a
-- visible = false push. Seeded at 100 for every stat so an unlikely
-- push-before-any-real-read edge case (shouldn't happen — hud:ready
-- always reads fresh values first) never shows a false "empty" bar. The
-- wellbeing fields below follow the identical seeding posture (100/100/0/
-- 100 healthy defaults, matching client/wellbeing.lua's own `lastStats`
-- seed exactly) — a disabled wellbeing element's slot here simply never
-- moves off this seed and is never read or sent (see
-- WELLBEING_ELEMENT_ENABLED above), so it is harmless either way.
local hudState = {
    visible = false,
    health = 100.0,
    stamina = 100.0,
    fatigue = 100.0,
    xpTierLabel = nil, -- string|nil; nil means "no tier known yet" (XPProgression disabled, or no snapshot received this session yet) — rendered as an absent row in that case, per the header's "absence, not blank" rule
    xpTierBadge = nil, -- string|nil; nil means "no badge on the current tier" (same absent-row rule as xpTierLabel above) -- e.g. non-nil for config.lua's Elite row (`badge = 'elite'`), nil for every other shipped tier
    lastPushAt = -HUD_HEARTBEAT_MS, -- forces the very first real push to count as heartbeat-due
}

-- Local read-only mirror of the server-pushed wellbeing snapshot,
-- populated ONLY by observing 'qbx_k9unit:client:wellbeingUpdate' below —
-- this file never calls the 'qbx_k9unit:server:getWellbeingSnapshot'
-- callback itself (see this file's header "WELLBEING / XP TIER EXTENSION"
-- section for why: client/wellbeing.lua already owns that on-demand
-- fetch, and this file must not add a second round trip for the same
-- data). Seeded at each stat's healthy default (mirrors
-- client/wellbeing.lua's own `lastStats` seed exactly), so a not-yet-
-- received snapshot never displays as empty/critical.
--
-- DISCLOSED LIMITATION: this cache only updates on the periodic server
-- tick broadcast (Config.Wellbeing.tickIntervalMs, 5000ms by default),
-- NOT on client/wellbeing.lua's own one-shot on-demand catch-up fetch for
-- the moment this client's ped first becomes K9-modeled (that fetch's
-- result is applied only LOCALLY inside client/wellbeing.lua via a direct
-- function call, never re-broadcast as this same event) — so these HUD
-- rows may lag up to one tick interval behind client/wellbeing.lua's own
-- already-applied state right after a K9 model change. Bounded and
-- self-healing (the same heartbeat philosophy the rest of this file
-- already relies on for the four core vitals), not a silent gap.
local wellbeingCache = {
    fatigue = 100.0,
}

if ANY_WELLBEING_ELEMENT_ENABLED then
    -- Deliberately a SEPARATE, independent listener on the SAME event
    -- client/wellbeing.lua's own RegisterNetEvent('qbx_k9unit:client:wellbeingUpdate', ...)
    -- already consumes — see this file's header for why this is not a new
    -- round trip. Gated at registration (not just in the loop body) so
    -- this file registers zero extra listeners when no wellbeing element
    -- is enabled, matching this file's own "GATING" convention.
    RegisterNetEvent('qbx_k9unit:client:wellbeingUpdate', function(stats)
        -- SOURCE-ORIGIN GUARD — same check, same reasoning, same
        -- confidence grading as client/wellbeing.lua's own identical guard
        -- on this exact event (see that file's header for the full
        -- writeup) — duplicated here rather than shared, matching this
        -- codebase's established per-file guard convention
        -- (client/combat.lua, client/progression.lua, client/wellbeing.lua
        -- each keep their own copy rather than sharing one).
        if source ~= 65535 then return end
        if type(stats) ~= 'table' then return end

        wellbeingCache.fatigue = tonumber(stats.fatigue) or wellbeingCache.fatigue
    end)
end

--- Clamps a single stat value to the 0-100 range this HUD's payload
--- contract uses for all four fields (design note §3). The four fields
--- below previously clamped via two different idioms (a two-statement
--- if/if pair vs. a single if/elseif) — unified on this one helper so
--- every field clamps identically.
--- @param v number
--- @return number
local function clamp01to100(v)
    if v < 0 then return 0.0 end
    if v > 100 then return 100.0 end
    return v
end

--- Reads all four vitals fresh from their real client-local sources. Pure
--- reads, no network round trip (design note §3: "structurally simpler
--- bridge... all four source values are already known to the client with
--- zero network latency").
--- @return number health, number stamina
local function ReadVitals()
    local ped = PlayerPedId()

    -- health — GetEntityHealth normalized against GetEntityMaxHealth, per
    -- design note §3, so the JS side never has to know GTA-specific health
    -- semantics (default max 200, "dead" threshold at 0 not 100).
    local maxHealth = GetEntityMaxHealth(ped)
    local health = 100.0
    if maxHealth > 0 then
        health = (GetEntityHealth(ped) / maxHealth) * 100.0
    end
    health = clamp01to100(health)

    -- stamina — see this file's header "STAMINA NATIVE — CONFIDENCE NOTE,
    -- RESOLVED" for why this is inverted from the raw native's own value
    -- (the native tracks exertion, rising as the K9 tires, not stamina
    -- remaining).
    -- Defaults to 100.0 (full stamina) when the native doesn't return a
    -- number, matching the same "never paints as starving/depleted"
    -- fallback philosophy health already follows above — a malformed read
    -- should never look like an empty stamina bar.
    local staminaRemaining = GetPlayerSprintStaminaRemaining(PlayerId())
    local stamina = type(staminaRemaining) == 'number' and (100.0 - staminaRemaining) or 100.0
    stamina = clamp01to100(stamina)

    return health, stamina
end

--- Reads the wellbeing display field (fatigue, the only one left) fresh from `wellbeingCache`
--- (itself only ever updated by the push-driven event listener above —
--- see this file's header, no network read happens here), returning nil
--- for any field whose owning Config.Features flag is off. A nil return
--- here is what ultimately makes that field's KEY ABSENT from the
--- SendNUIMessage payload (see PushVitals below) — the mechanism behind
--- this file's "must be absent, not blank or zeroed" requirement.
--- @return number|nil fatigue
local function ReadWellbeingForDisplay()
    local fatigue = nil

    if WELLBEING_ELEMENT_ENABLED.fatigue then
        fatigue = clamp01to100(wellbeingCache.fatigue)
    end

    return fatigue
end

--- Reads the current XP tier's label and badge, or (nil, nil) if
--- XPProgression is off, the client/progression.lua accessor doesn't exist
--- (soft-dependency guard — see this file's header), or no tier snapshot
--- has been received this session yet (GetCurrentXPTier() itself returning
--- nil, which is its own documented behavior before the first
--- 'qbx_k9unit:client:xpTierChanged' event lands).
---
--- BADGE, THIS PASS: closes the previously-disclosed gap in
--- server/progression.lua's own "XP TIER UNLOCKS" section (Elite —
--- "SERVER HALF WIRED, DISPLAY NOT WIRED") — the badge was already
--- forwarded verbatim onto the SAME `GetCurrentXPTier()` table `label`
--- was already being read from (CopyTier's own `for key, value in
--- pairs(tier)`), so this is a one-field read added to an already-existing
--- accessor, not a new one. `tier.badge` is deliberately allowed to be nil
--- (most tiers configure none — only config.lua's Elite row ships with
--- `badge = 'elite'` today) — that is a NORMAL, expected case, not an
--- error, and is why this returns a second nil rather than failing the
--- whole read.
--- @return string|nil label
--- @return string|nil badge
local function ReadXPTierDisplay()
    if not XP_TIER_ELEMENT_ENABLED then return nil, nil end
    if type(GetCurrentXPTier) ~= 'function' then return nil, nil end

    local tier = GetCurrentXPTier()
    if type(tier) ~= 'table' or type(tier.label) ~= 'string' then return nil, nil end

    local badge = tier.badge
    if type(badge) ~= 'string' or badge == '' then badge = nil end

    return tier.label, badge
end

--- Sends one hud:updateVitals push and updates hudState to match — the
--- single choke point every call site below routes through, so
--- "what did we last actually send" (used both for the epsilon comparison
--- and for the visible=false "resend last known values" rule) can never
--- drift from what was truly pushed.
--- @param visible boolean
--- @param health number
--- @param stamina number
--- @param fatigue number|nil
--- @param xpTierLabel string|nil
--- @param xpTierBadge string|nil
local function PushVitals(visible, health, stamina, fatigue, xpTierLabel, xpTierBadge)
    -- See this file's header "WELLBEING / XP TIER EXTENSION" — any of
    -- these five keys being nil above means it is simply ABSENT here (a
    -- Lua table never stores a nil-valued key), which is exactly the
    -- "absent, not blank/zeroed" signal html/app.js keys its per-row
    -- show/hide off of.
    --
    -- WIRE-SHAPE FIX: with every wellbeing flag off and XPProgression off
    -- (the shipped default — see config.lua) every key in both sub-tables
    -- below is nil, leaving each an EMPTY Lua table. json.lua (dkjson,
    -- this runtime's actual `json.encode` backing SendNUIMessage's table
    -- argument — confirmed by reading
    -- data/shared/citizen/scripting/lua/json.lua directly) cannot tell an
    -- empty array from an empty object from table content alone and
    -- defaults an empty table to a JSON array (`isarray({})` returns true
    -- there since an empty `pairs` loop never trips its "not a
    -- sequential-integer key" bailout) — so without a hint, this file
    -- would silently send `wellbeing: []` / `xpTier: []` on the wire,
    -- contradicting both this header's "always present as tables" promise
    -- and html/app.js's own `{ ..., wellbeing?: object, xpTier?: object }`
    -- JSDoc contract. dkjson's own `__jsontype = 'object'` metatable hint
    -- (same file, checked right where it decides array-vs-object) exists
    -- for exactly this ambiguity — applied to both sub-tables below so
    -- they always encode as `{}`/`{...}`, never `[]`, regardless of how
    -- many of their keys end up populated this push. html/app.js's current
    -- bracket-property access (`wellbeing[stat]`, `wellbeing.distracted`)
    -- happens to tolerate either shape today (property access on a JS
    -- array works the same as on an object), so this was not an observed
    -- runtime failure — this closes the gap before a stricter downstream
    -- consumer (or a future app.js rewrite) could turn it into one.
    local wellbeing = {
        fatigue = fatigue,
    }
    local xpTier = {
        label = xpTierLabel,
        badge = xpTierBadge,
    }
    setmetatable(wellbeing, JSON_FORCE_OBJECT_MT)
    setmetatable(xpTier, JSON_FORCE_OBJECT_MT)

    SendNUIMessage({
        action = 'hud:updateVitals',
        data = {
            visible = visible,
            health = health,
            stamina = stamina,
            wellbeing = wellbeing,
            xpTier = xpTier,
        },
    })

    hudState.visible = visible
    hudState.health = health
    hudState.stamina = stamina
    hudState.fatigue = fatigue
    hudState.xpTierLabel = xpTierLabel
    hudState.xpTierBadge = xpTierBadge
    hudState.lastPushAt = GetGameTimer()
end

-- ----------------------------------------------------------------------
-- 'hud:ready' — design note §5 point 6. SendNUIMessage delivery is not
-- queued/retried: a message sent before html/app.js has attached its
-- `message` listener is simply lost. This handler is the other half of
-- that handshake — cb({}) fires immediately and unconditionally (an
-- uninvoked NUI callback hangs the frontend's fetch promise forever, the
-- most common silent-failure point in NUI code), and an immediate
-- snapshot push follows so a freshly-loaded HUD paints right away instead
-- of waiting out the ~1s heartbeat ceiling.
-- ----------------------------------------------------------------------
RegisterNUICallback('hud:ready', function(_, cb)
    cb({})

    local health, stamina = ReadVitals()
    local fatigue = ReadWellbeingForDisplay()
    local xpTierLabel, xpTierBadge = ReadXPTierDisplay()
    PushVitals(CanShowK9UI(), health, stamina, fatigue, xpTierLabel, xpTierBadge)
end)

-- ----------------------------------------------------------------------
-- Poll/push thread — design note §5. Only ever started because the whole
-- file already returned early above when Config.Features.HealthStaminaHUD
-- is false, so there is no redundant flag re-check needed in the loop body
-- itself (see this file's header "GATING" note).
-- ----------------------------------------------------------------------
CreateThread(function()
    while true do
        -- CanShowK9UI() itself is cheap to call every tick here: it's
        -- IsOwnModelK9() (pure local) ANDed with HasK9Access(), and
        -- HasK9Access() is already debounced by client/main.lua's own
        -- HAS_K9_ACCESS_CACHE_TTL_MS = 1000 TTL cache — so evaluating this
        -- once per 250ms poll tick triggers at most one fresh
        -- lib.callback.await per second, not one per tick (design note
        -- §5.1's footnote). This is the same cache every other
        -- CanShowK9UI()/HasK9Access() call site in this codebase already
        -- relies on for exactly this reason (every radial item's
        -- onSelect, client/vehicle.lua's canInteract).
        -- Per-person block (client/featureblocks.lua -- see that file's
        -- header for the full contract). Folded directly into `canShow`
        -- -- this poll thread already re-derives `canShow` fresh every
        -- tick (see this thread's own header comment), so a block applied
        -- while the HUD is currently showing hides it on the very next
        -- tick (<= HUD_POLL_TICK_MS), the same "already-active effect
        -- reacts live" property this resource's other continuous-display
        -- features get from their own already-existing poll loops. Hiding
        -- a passive, read-only display is never a "trap" (there is no
        -- exit path to strand anyone from) -- unlike every gated ability
        -- elsewhere in this resource, this one needs no separate
        -- initiation-vs-termination split.
        local canShow = CanShowK9UI()
            and not (type(IsK9FeatureBlocked) == 'function' and IsK9FeatureBlocked('HealthStaminaHUD'))

        if not canShow then
            if hudState.visible then
                -- true -> false transition: push immediately (design note
                -- §5.5), reusing the LAST KNOWN good vitals AND wellbeing/
                -- xpTier fields already sitting in hudState — never a
                -- fresh read, never zeroed — per design note §3's "so the
                -- JS doesn't have to wait out a stale-zero flash" rule,
                -- extended here to the wellbeing/xpTier fields for the
                -- identical reason.
                PushVitals(false, hudState.health, hudState.stamina,
                    hudState.fatigue,
                    hudState.xpTierLabel, hudState.xpTierBadge)
            end

            Wait(HUD_IDLE_TICK_MS) -- design note §5.4: idle backoff while not currently relevant
        else
            local health, stamina = ReadVitals()
            local fatigue = ReadWellbeingForDisplay()
            local xpTierLabel, xpTierBadge = ReadXPTierDisplay()
            local becameVisible = not hudState.visible
            local now = GetGameTimer()

            local changedEnough = math.abs(health - hudState.health) > HUD_CHANGE_EPSILON
                or math.abs(stamina - hudState.stamina) > HUD_CHANGE_EPSILON
                -- Each wellbeing comparison below short-circuits on its own
                -- enabled flag BEFORE ever touching hudState's (possibly
                -- nil, if disabled) slot for that field — see
                -- WELLBEING_ELEMENT_ENABLED's own comment above.
                or (WELLBEING_ELEMENT_ENABLED.fatigue and math.abs(fatigue - hudState.fatigue) > HUD_CHANGE_EPSILON)
                or xpTierLabel ~= hudState.xpTierLabel
                or xpTierBadge ~= hudState.xpTierBadge
            local heartbeatDue = (now - hudState.lastPushAt) >= HUD_HEARTBEAT_MS

            -- becameVisible short-circuits straight to a push (design note
            -- §5.5's false -> true immediate-push rule), independent of
            -- both the epsilon check and the heartbeat ceiling.
            if becameVisible or changedEnough or heartbeatDue then
                PushVitals(true, health, stamina, fatigue, xpTierLabel, xpTierBadge)
            end

            Wait(HUD_POLL_TICK_MS) -- design note §5.1: active poll cadence while visible
        end
    end
end)
