--[[
    qbx_k9unit/server/bonetool.lua

    DEV-ONLY BONE-INDEX SWEEP TOOL — Config.Features.BoneSweepDevTool
    (MUST default `false` and MUST NEVER be flipped `true` on a production
    server — see the ACCESS MODEL section below).

    ======================================================================
    WHY THIS EXISTS: repeated attempts to find a documented bone NAME for
    a quadruped/animal skeleton, for Config.Features.PropAttachments,
    failed, and reading existing open-source dog scripts found nobody
    attaching props to an animal ped at all. The reframe that unblocks it:
    AttachEntityToEntity takes a bone INDEX, not a name, and
    GetWorldPositionOfEntityBone-class natives are entity-type-agnostic —
    so the right method is an in-engine visual sweep by a human on a real
    dev server, not more documentation searching. This file (plus
    client/bonetool.lua) is that sweep tool. It answers the SAME open
    question for Config.Features.FetchMechanic — see this file's own
    EXPOSED SURFACE note below for exactly what that feature can reuse
    here rather than building its own copy.

    THIS FILE PRODUCES NO ANSWER BY ITSELF. It lets a human connected to a
    real dev server jump to/step through numeric bone indices on their OWN
    current ped and see, with their own eyes (a live debug marker drawn at
    GetWorldPositionOfEntityBone's own result, PLUS an optional real
    CreateObject+AttachEntityToEntity test — see client/bonetool.lua's own
    header for the two-mode PREVIEW/TEST design), which index puts a visible
    marker prop where a vest/harness (or, for FetchMechanic, a fetched item
    held in the mouth) should sit. A human operator still needs to record
    which index looks correct once found.

    ======================================================================
    ACCESS MODEL — TWO INDEPENDENT LAYERS. BOTH must hold; neither alone is
    sufficient. A server owner who leaves the flag on must still have never
    set the convar for this to do anything, and vice versa; separately, a
    server that DOES opt in at the registration layer still requires a
    per-invocation, in-game authorization check on every single command.

    LAYER 1 — REGISTRATION-TIME, OUT-OF-GAME (see SECOND, EXPLICIT OPT-IN
    below for the full "why a convar on top of the flag" reasoning):
    Config.Features.BoneSweepDevTool must be `true` AND the convar
    `qbx_k9unit_enable_bone_dev_tool` must read as `1` via GetConvarInt —
    BOTH checked ONCE, in the onResourceStart block below, before
    '/k9bonetool' is ever RegisterCommand'd. If either is not satisfied,
    the command is never registered at all, matching this resource's
    established "flag off means genuinely inert" convention — extended
    here to "flag-on-but-not-opted-in also means genuinely inert."

    LAYER 2 — PER-INVOCATION, IN-GAME, JOB-RANK GATED (an ACE ->
    police-job-rank conversion, at the project owner's explicit direction
    to convert every remaining ACE-gated action in this resource; this
    file's `IsPlayerAceAllowed(..., Config.BoneSweepTool.AcePermission)`
    gate was the last of exactly two ACE gates in this resource, the other
    being server/admin.lua's, which was converted the same way):
    IsAuthorizedBoneSweepDevTool(source), re-checked on EVERY invocation
    inside the handler, mirroring server/admin.lua's IsAuthorizedAdmin
    shape — fail closed on every unresolvable player/job shape, never
    throw. Read that function's own doc comment (below) and admin.lua's
    IsAuthorizedAdmin before touching either.

    DELIBERATELY NOT THE SAME THRESHOLD AS IsAuthorizedAdmin: that function
    grants on `job.isboss OR job.grade.level >= Config.Departments[...].
    auditGrade`. IsAuthorizedBoneSweepDevTool below grants on `job.isboss`
    ONLY — no numeric-grade branch, and deliberately no new per-department
    config field added to give it one:
      1. config.lua's own comment on the AcePermission field this replaces
         already draws the line this threshold must not cross: "A SEPARATE
         principal from Config.AdminAudit.AcePermission on purpose.
         Granting someone read-only audit access should not also hand them
         a tool that spawns and attaches props to peds." Reusing
         `auditGrade` here — the only numeric per-department threshold
         config.lua already defines — would collapse exactly that
         deliberately-kept separation the moment the ACE gate is removed:
         every senior officer trusted to review search/cert/partnership
         history would, with no further action by anyone, also become
         trusted to spawn and attach props on command. That is a
         materially different capability than read-only audit access, and
         this resource's own config comment already says so.
      2. This tool's actual intended population (see this file's own
         opening paragraph) is developers/QA testers sweeping bone indices
         on a dev box, not police officers doing police work. A job-rank
         gate is a poor population selector for it on BOTH sides — it can
         lock out a fresh/test character with no police job at all (the
         exact person this tool is FOR), and it can hand real
         CreateObject+AttachEntityToEntity capability to a genuinely senior
         officer with no development/server-owner role (a person this tool
         was never FOR). Converting anyway, per direction, at the
         NARROWEST threshold this resource's existing job shape already
         offers (isboss, no configurable grade) minimizes that mismatch
         rather than pretending it away: a dev-server operator can
         trivially grant their own test character boss status on their own
         box, and `job.isboss` needs no new config key that could quietly
         widen this later. LAYER 1's convar — not this in-game threshold —
         is what actually keeps this tool off a production server.

    OPERATIONAL CAVEAT (also stated in config.lua's own
    Config.Features.BoneSweepDevTool comment; restated here because THIS
    file is the one that actually acts on it): both LAYER 1 checks
    (Config.Features.BoneSweepDevTool and the convar) are read ONCE, in the
    onResourceStart block below, to decide whether to RegisterCommand
    '/k9bonetool' at all. Changing either — flipping the flag back to
    false, or unsetting/changing the convar — WITHOUT a resource restart
    does NOT unregister the command; it stays reachable (still gated by
    IsAuthorizedBoneSweepDevTool inside the handler, re-checked on every
    invocation) until the next restart. client/bonetool.lua's own
    registration gate has the identical property for its event
    handler/draw thread, and now checks the SAME convar (see that file's
    own header) rather than the flag alone. Never treat "I changed the
    flag/convar" as sufficient by itself to consider this tool inert on a
    server where it was ever registered, without also restarting the
    resource.

    CONSOLE (source == 0) IS DELIBERATELY NOT SUPPORTED, UNLIKE
    server/admin.lua's own console carve-out (Config.AdminAudit.TrustConsole):
    every subcommand this tool exposes acts on "your own current ped" (see
    EVENT CONTRACT below) — the server console has no client and no ped for
    that concept to apply to, and — now that LAYER 2 is a job-rank check,
    not an ACE grant — the console has no Player/PlayerData/job for
    IsAuthorizedBoneSweepDevTool to consult either way. This is a narrower,
    simpler answer than admin.lua's own read-only-query carve-out needed,
    not an oversight; flagged explicitly per this resource's own "disclose
    access-model judgment calls, don't decide them silently" convention.

    ======================================================================
    SECOND, EXPLICIT OPT-IN — WHY A CONVAR ON TOP OF THE FEATURE FLAG: this
    resource ships 40 independent Config.Features.* toggles, meant to be
    flippable together (a server owner reviewing/enabling "all features").
    This is the one flag whose own config.lua comment says the opposite of
    what a blanket "all features on" pass just did to it — "NEVER enable
    this on a production server" — and a real FXServer run confirms it:
    with the flag alone set true, this tool registers live at startup. A
    boolean that reads identically to 39 other, genuinely-safe-to-bulk-
    enable flags is not a strong enough signal that enabling THIS one was a
    deliberate, standalone decision, because on the evidence available it
    demonstrably was not.

    `qbx_k9unit_enable_bone_dev_tool` is a second gate a bulk flag-flip
    cannot satisfy by construction: it must be set BY NAME, as its own line
    in server.cfg, by whoever operates the box, and setting it alone does
    nothing (Config.Features.BoneSweepDevTool must ALSO still be true) — an
    operator who wants this tool has to touch two independent places, not
    one. Use `setr` (set + REPLICATE), not a plain `set`, specifically so
    client/bonetool.lua's own registration gate can read the exact same
    value the server used, rather than this file needing to export it over
    a bespoke event just for that purpose:

        setr qbx_k9unit_enable_bone_dev_tool 1

    Read via GetConvarInt (both here and in client/bonetool.lua) — `1`
    means on; anything else, INCLUDING the convar never being set at all
    (which reads back as this call's own default of `0`), means off.

    WARNING, NOT ASSERT — same posture as server/combat.lua's own
    PropDragging/IsPlayerDownedOverride resource-start warning (matched
    deliberately; read that file's own comment block before changing this
    one). This is a WEAKER guard than an assert on purpose: the "fix" here
    is "the operator did not opt in," a state this resource must tolerate
    gracefully (leave the tool unregistered, resource still starts) rather
    than a misconfiguration worth crashing resource start over — this must
    never become an assert/error. The printed warning below is the loud,
    actionable line that makes "the tool did not register" legible in
    server console output instead of a silent, unexplained absence —
    printed ONLY when Config.Features.BoneSweepDevTool is true, so a
    default install with the flag off (most installs) prints nothing extra
    at all.

    GETPEDBONEINDEX — CONFIRMED AGAINST PRIMARY SOURCE, AND THE CONCLUSION
    ON WHETHER THIS TOOL SHOULD CONVERT THROUGH IT (full writeup in
    client/bonetool.lua's own header, since the actual native call happens
    there; summarized here for anyone who only reads this file):
    `GET_PED_BONE_INDEX(Ped ped, int boneId)` (0x3F428D08BE5AAE31, read
    directly off a fresh clone of citizenfx/natives) converts a semantic
    `ePedBoneId` value into the raw index AttachEntityToEntity wants — the
    exact conversion AttachEntityToEntity's own doc points at ("This is
    different to boneID, use GET_PED_BONE_INDEX..."). That same enum lists
    animal-only entries (SKEL_Tail_01..05, SKEL_SADDLE), which is
    corroborating evidence — not proof — that some of these ids resolve to
    something real on an `a_c_*` skeleton. CONCLUSION: yes, worth exposing
    as a FAST-PATH shortcut (the new 'known' subcommand below), but never as
    a replacement for the raw sweep, because (1) that native's own doc page
    has an EMPTY "Return value" section, so its not-found convention could
    not be confirmed, and 'known' reports every raw value unfiltered rather
    than silently filtering "hits", and (2) even a real resolved index
    isn't guaranteed to be anatomically where the human-skeleton name
    suggests on a differently-rigged model — every 'known' result is still
    just a candidate for the human to 'goto' and confirm with their own
    eyes, never a trusted answer by itself.

    THIS TOOL NEVER TOUCHES NETWORKED STATE: every subcommand below is
    forwarded, unchanged, to the ONE calling client's own client-side
    handler (client/bonetool.lua). The PREVIEW half ('goto'/'next'/'prev')
    never creates any entity at all — it only draws a per-frame debug marker
    at a queried bone position. The TEST half ('test') creates its object
    with CreateObject's isNetwork = false (a purely local visual aid — see
    client/bonetool.lua's own header). There is no server-side registry of
    "who currently has a test object attached" and no broadcast to any other
    client. This means the tool has a structurally smaller entity-leak blast
    radius than every other prop-creating feature in this resource: a test
    prop that somehow survives its intended cleanup is, at worst, a
    LOCAL-ONLY object on the one connected admin's own client, gone the
    moment that client disconnects or this resource stops
    (client/bonetool.lua still runs its own onResourceStop/'stop' cleanup
    regardless — this is a structural property of local-only objects, not a
    reason to skip the explicit cleanup path).

    ======================================================================
    EVENT CONTRACT:
    Client events (RegisterNetEvent, server->client), sent ONLY to the one
    calling client, never broadcast:
    - 'qbx_k9unit:client:boneToolCommand' (subcommand: string, arg: number?)
      [client/bonetool.lua] subcommand ∈ {'goto', 'next', 'prev', 'test',
      'known', 'stop'} ('help' never reaches the client at all — see below).
      'goto' carries a validated, clamped integer index in [0, MaxBoneIndex].
      'next'/'prev' now carry an optional positive integer STEP (NOT an
      index — how many indices to move, defaulting to 1, validated/clamped
      here before ever being sent, and re-validated client-side too). Every
      other subcommand carries no argument at all — the CLIENT owns its own
      current-index state (this file deliberately does not track it
      server-side; there is nothing security-relevant about which integer a
      dev-tool marker currently sits at).

    Commands (server-registered):
    - '/k9bonetool <goto|next|prev|test|stop|known|help> [arg]'
        goto <index>  — preview this exact bone index (a live debug marker
                        AND an on-screen index-number label at its
                        GetWorldPositionOfEntityBone position; replaces
                        whatever index was previously previewed).
        next [step]   — step the CLIENT's own current preview index forward
                        by [step] (default 1, must be a positive integer;
                        clamped to [0, MaxBoneIndex] client-side). A human
                        sweeping up to MaxBoneIndex (200 by default)
                        benefits from being able to skip ahead rather than
                        stepping one at a time the whole way.
        prev [step]   — same, stepping backward.
        test          — real CreateObject + AttachEntityToEntity at the
                        CLIENT's own current preview index, for a final
                        visual confirmation of the actual attach call
                        (replaces any previous test object).
        stop          — stops the preview marker and removes any test object.
        known         — CLIENT-LOCAL ONLY (the GetPedBoneIndex fast-path —
                        see the GETPEDBONEINDEX section above): resolves a
                        curated list of documented ePedBoneId semantic names
                        against the caller's own live ped and reports every
                        raw result via chat + console. Never changes the
                        current preview index — purely a candidate
                        shortlist to 'goto' into and confirm.
        help          — handled ENTIRELY here, server-side: no client
                        dispatch at all, just the full goto/next/prev/known/
                        test/stop/record-your-result workflow via
                        NotifyPlayer, so a human can read it before
                        confirming anything client-side is even working.

    ======================================================================
    EXPOSED SURFACE FOR FetchMechanic: NOTHING beyond this command itself
    needs to be exposed — FetchMechanic's own dev-testing workflow is
    simply "connect to a dev server, run '/k9bonetool goto <n>' repeatedly
    while playing as a K9 (or whatever model FetchMechanic targets), read
    off the index that visually looks right for a mouth/head attach point,
    and hard-code that into their own feature's config." No shared
    server-side state, no shared function signature, is needed for that
    workflow — the tool IS the shared surface. The one thing this file's
    sibling, client/bonetool.lua, DOES also expose as a resource-global
    (not duplicated) is client/propattachment.lua's AttachPropToOwnPed /
    DetachAndDeleteProp pair (client/bonetool.lua calls those directly
    rather than re-implementing its own CreateObject/AttachEntityToEntity
    sequence) — FetchMechanic's own client file should call those same two
    functions for its actual (non-dev-tool) attach, rather than hand-rolling
    a third copy of that mechanic. See client/propattachment.lua's own
    header for that function pair's full contract.

    FILE-TO-FILE CONTRACT:
    - THIS FILE calls `NewCooldown()` (server/cooldowns.lua) at file-load
      time — must load after that file.
    - THIS FILE exposes no resource-global functions of its own.

    CONFIG THIS FILE ASSUMES EXISTS (not owned by this file; see
    config.lua/fxmanifest.lua/.luacheckrc):
      Config.Features.BoneSweepDevTool : boolean (default false; MUST
                                          stay false on any production server)
      Config.BoneSweepTool.TestPropModel     : string  -- only used by the 'test' subcommand; the 'goto'/'next'/'prev' preview needs no model at all (pure position query)
      Config.BoneSweepTool.MaxBoneIndex      : integer >= 0
      Config.BoneSweepTool.TestOffsetX/Y/Z   : number
      Config.BoneSweepTool.CommandCooldownMs : number > 0 (NOT >= 0 -- see the
                                          onResourceStart assert below: this
                                          value is read fresh at call time by
                                          a NewCooldown() with no constructor
                                          default, so 0/negative fails CLOSED
                                          -- permanently on cooldown after one
                                          use -- rather than meaning "no
                                          cooldown")
      Config.Departments                     : table -- shared with server/admin.lua/server/certifications/; IsAuthorizedBoneSweepDevTool below reads Config.Departments[job.name] to decide whether the caller's job is a configured K9 department at all (job.isboss is still additionally required — see LAYER 2 above).
      Config.BoneSweepTool.AcePermission is NO LONGER READ by this file
      (see the ACE -> job-rank conversion in LAYER 2 above) -- it is DEAD
      CONFIG, same as Config.AdminAudit.AcePermission. It should be removed
      from config.lua, along with that file's own two now-stale comments
      referencing it (its Config.Features.BoneSweepDevTool and
      Config.BoneSweepTool.AcePermission comments).

      NOT A Config.* FIELD, so not listed above as one, but equally REQUIRED
      for this tool to ever register (LAYER 1 — see SECOND, EXPLICIT OPT-IN
      above): the convar `qbx_k9unit_enable_bone_dev_tool`, read via
      GetConvarInt, must be `1`. Set via `setr qbx_k9unit_enable_bone_dev_tool 1`
      in server.cfg.
]]

-- SECOND, EXPLICIT OPT-IN -- see this file's header SECOND, EXPLICIT OPT-IN
-- section for the full "why" writeup. Read via GetConvarInt at
-- onResourceStart below; `1` means opted in, anything else (including
-- never being set, which reads back as GetConvarInt's own default of `0`)
-- means not opted in. A plain local constant, not a Config field, per this
-- file's own established "tiny constant, private per file" convention
-- (see REQUEST_MODEL_TIMEOUT_MS's identical duplication note in
-- client/propattachment.lua) -- client/bonetool.lua duplicates this exact
-- literal for its own registration gate rather than sharing a resource
-- global, since the two files must each independently decide whether to
-- register regardless of the other's load order.
local BONE_DEV_TOOL_ENABLE_CONVAR = 'qbx_k9unit_enable_bone_dev_tool'

-- NOTE: 'goto' is a reserved word in Lua 5.4, so its key must be bracketed
-- (['goto'] = true) rather than the bare `goto = true` shorthand every
-- other key here uses.
local VALID_SUBCOMMAND_SET = { ['goto'] = true, next = true, prev = true, test = true, stop = true, known = true, help = true }

-- Full workflow reference — shown both on an invalid/missing subcommand and
-- via the explicit 'help' subcommand (a human must be able to see how to
-- record what they find, not just see a marker). Built once via
-- table.concat, same multi-line-notify pattern server/admin.lua's own
-- NotifyPlayer call sites already establish as safe for ox_lib's notify
-- (embedded '\n' renders as real line breaks there).
local BONE_TOOL_USAGE = locale('bonetool.usage')

--- Sends an ox_lib notification to a specific player, using this file's own
--- 'K9 Unit — Bone Tool' title. Deliberately kept as a thin LOCAL wrapper
--- (same name, shadowing the resource-global on purpose) rather than
--- flattened onto server/notify.lua's shared implementation directly at
--- every call site below — see that file's header "TWO CALL SITES
--- DELIBERATELY KEPT AS LOCAL WRAPPERS" section for the full reasoning
--- (this title is a deliberate, player-visible per-subsystem difference,
--- not an accident). The explicit `_G.` prefix below is required, not
--- decorative: a bare `NotifyPlayer(...)` call inside this same-named local
--- function's own body would resolve to this local (already in scope
--- inside its own body) and recurse forever instead of reaching the shared
--- global.
--- @param target number
--- @param description string
--- @param notifyType string?
local function NotifyPlayer(target, description, notifyType)
    _G.NotifyPlayer(target, description, notifyType, 'K9 Unit — Bone Tool')
end

--- LAYER 2 authorization check — see this file's header ACCESS MODEL
--- section for the full "why job-rank, why boss-only, why not
--- IsAuthorizedAdmin's threshold" writeup. Mirrors server/admin.lua's
--- IsAuthorizedAdmin shape exactly for every resolvable-shape check: fails
--- CLOSED (returns false, never throws) on a missing player record, a
--- missing job, or a job whose name is not a configured Config.Departments
--- key. UNLIKE IsAuthorizedAdmin, there is no per-department numeric-grade
--- branch of its own at all — only `job.isboss` OR High Command
--- (server/highcommand.lua's IsHighCommand, added at the project owner's
--- direction -- see that file's own header for the full "run any command"
--- contract) qualifies (see header for why reusing
--- Config.Departments[...].auditGrade here would be a real regression, not
--- a convenience — that reasoning is UNCHANGED by the High Command bypass,
--- which is a resource-wide "senior command can do anything this resource
--- offers" tier, not a reuse of any existing per-department threshold). No
--- console carve-out either: this is only ever called for `src ~= 0` (see
--- the RegisterCommand handler below, which already rejects source == 0
--- before this function is ever reached).
--- @param source number
--- @return boolean
local function IsAuthorizedBoneSweepDevTool(source)
    local Player = exports.qbx_core:GetPlayer(source)
    if not Player or not Player.PlayerData then return false end

    local job = Player.PlayerData.job
    if not job or not Config.Departments or not Config.Departments[job.name] then return false end

    if job.isboss == true then return true end

    -- HIGH COMMAND BYPASS (server/highcommand.lua, Config.Features.HighCommand,
    -- added at the project owner's direction) -- LAYER 2 (this in-game rank
    -- check) only -- LAYER 1 (Config.Features.BoneSweepDevTool AND the
    -- `qbx_k9unit_enable_bone_dev_tool` convar, checked once at
    -- registration, above/before this function is ever reached) is a
    -- server-OPERATOR opt-in, deliberately left untouched: an in-game
    -- promotion must never be able to switch on a dev-only prop-spawning
    -- tool an operator never opted into at the process level. Guarded by a
    -- `type(...) == 'function'` runtime existence check, this resource's
    -- established soft-dependency convention -- this function still works
    -- exactly as before if server/highcommand.lua is ever removed or
    -- Config.Features.HighCommand is false (IsHighCommand re-checks that
    -- flag itself and returns false).
    return type(IsHighCommand) == 'function' and IsHighCommand(source)
end

-- DEVELOPER_REFERENCE.md item 1 convention: per-source rate limit on running
-- this command at all — spam/abuse guard only (this is an admin-only tool,
-- but a misbehaving or scripted client is still worth throttling, same
-- reasoning as server/admin.lua's own AuditCooldown).
local BoneToolCooldown = NewCooldown()
BoneToolCooldown.RegisterPlayerDropped()

-- ======================================================================
-- PER-PERSON FEATURE CONTROL -- config.lua's own Config.FeatureControl
-- header documents the 4-step resolution; step 1,
-- Config.Features.BoneSweepDevTool, is already this file's own
-- onResourceStart registration-time gate (with the convar as a SECOND,
-- independent opt-in on top of it -- see this file's header). Mirrors
-- server/pursuitsprint.lua's IsPursuitSprintPermittedForCitizenId shape
-- verbatim. ONLY ever consulted for a subcommand that STARTS/CONTINUES the
-- tool (goto/next/prev/test/known/help below) -- 'stop' is this tool's
-- termination path and is handled, and dispatched, BEFORE this is ever
-- reached (see the RegisterCommand handler's own "NO UNBOUNDED TRAP"
-- comment) -- a per-person block must never be able to strand someone
-- mid-sweep with an attached test prop and no way to remove it.
-- ======================================================================
--- @param citizenid string
--- @return boolean allowed
local function IsBoneSweepDevToolPermittedForCitizenId(citizenid)
    -- Soft dependency, this resource's established convention -- see
    -- server/pursuitsprint.lua's own identical comment on its own copy of
    -- this guard.
    local hasPermissionAvailable = type(HasPermission) == 'function'

    if hasPermissionAvailable and HasPermission(citizenid, 'block.BoneSweepDevTool') == true then
        return false -- step 2: an explicit block always wins, even over an active grant
    end

    local featureControl = Config.FeatureControl
    local requiresGrant = type(featureControl) == 'table'
        and type(featureControl.RequireGrant) == 'table'
        and featureControl.RequireGrant.BoneSweepDevTool == true

    if requiresGrant then
        -- step 3: listed in RequireGrant -> ALLOW only with an active grant.
        return hasPermissionAvailable and HasPermission(citizenid, 'feature.BoneSweepDevTool') == true
    end

    return true -- step 4: not listed in RequireGrant at all -- default allow (matches config.lua's own documented default)
end

AddEventHandler('onResourceStart', function(resourceName)
    if GetCurrentResourceName() ~= resourceName then return end

    if not (Config.Features and Config.Features.BoneSweepDevTool == true) then
        return -- feature disabled (or not yet configured) — the command is never registered at all
    end

    -- LAYER 1, SECOND HALF -- see header SECOND, EXPLICIT OPT-IN section.
    -- Checked AFTER the feature-flag return above on purpose: a default
    -- install with the flag off (the overwhelming majority of installs)
    -- must print nothing extra at all, only a server that has ALREADY
    -- opted in at the flag layer gets this warning, so the signal stays
    -- meaningful rather than becoming console noise every install sees.
    -- WARNING, NOT ASSERT — see header for why this must never become a
    -- hard failure of resource start.
    if GetConvarInt(BONE_DEV_TOOL_ENABLE_CONVAR, 0) ~= 1 then
        -- The normal state on a live server, so a plain note, not a
        -- warning: the flag ships on, and the convar is the real switch.
        print(
            ("[qbx_k9unit] bonetool.lua: the /k9bonetool developer tool is OFF (normal for a live server -- " ..
             "nothing to do). It only turns on if you also put `setr %s 1` in server.cfg, which is " ..
             "meant for a private test server only."):format(BONE_DEV_TOOL_ENABLE_CONVAR)
        )
        return
    end

    assert(type(Config.BoneSweepTool) == 'table', '[qbx_k9unit] Config.Features.BoneSweepDevTool is true but Config.BoneSweepTool is missing.')
    assert(type(Config.Departments) == 'table', '[qbx_k9unit] Config.Features.BoneSweepDevTool is true but Config.Departments is missing -- IsAuthorizedBoneSweepDevTool requires it to resolve the caller\'s own job.')

    -- CLAMP AND WARN, DELIBERATELY NEVER THROW -- this used to be six bare
    -- per-field `assert`s in a row (the two structural checks just above --
    -- Config.BoneSweepTool/Config.Departments entirely missing -- are kept
    -- as hard asserts; those are a far more severe misconfiguration than
    -- one malformed field, and this dev-only tool is opt-in twice over
    -- already, layer 1 and layer 2 above, so an operator who reaches this
    -- point has already deliberately turned it on). A throw from ANY ONE of
    -- these used to abort this entire handler on the spot -- and
    -- RegisterCommand('k9bonetool') sits AFTER every one of them, in this
    -- SAME handler, below -- so one operator typo in a section config.lua's
    -- own comment invites tuning of ("replace after a dev-server sweep")
    -- would silently remove the command entirely for the rest of this
    -- resource's uptime, with nothing in the console to explain why.
    --- @param key string
    --- @param predicate fun(value: any): boolean
    --- @param fallback any
    --- @param description string -- plain-English requirement, used only in the printed warning
    local function ResolveBoneSweepToolField(key, predicate, fallback, description)
        local value = Config.BoneSweepTool[key]
        if not predicate(value) then
            print(
                ('[qbx_k9unit] WARNING: Config.BoneSweepTool.%s %s (found: %s) -- using the built-in fallback ' ..
                 '%s instead of aborting registration of /k9bonetool over one field. Fix ' ..
                 'Config.BoneSweepTool.%s in config.lua to silence this warning.'
                ):format(key, description, tostring(value), tostring(fallback), key)
            )
            Config.BoneSweepTool[key] = fallback
        end
    end

    ResolveBoneSweepToolField('TestPropModel', function(v) return type(v) == 'string' and v ~= '' end, 'prop_tennis_ball', 'must be a non-empty string')
    ResolveBoneSweepToolField('MaxBoneIndex', function(v) return type(v) == 'number' and v >= 0 end, 200, 'must be a number >= 0')
    for _, key in ipairs({ 'TestOffsetX', 'TestOffsetY', 'TestOffsetZ' }) do
        ResolveBoneSweepToolField(key, function(v) return type(v) == 'number' end, 0.0, 'must be a number')
    end
    -- MUST be strictly > 0, not >= 0: BoneToolCooldown below is a
    -- server/cooldowns.lua NewCooldown() instance with no constructor
    -- default, so this value is read fresh at every call-time IsOnCooldown
    -- check (see BoneToolCooldown.Consume below). That file's own
    -- IsValidThreshold rejects 0/negative as "no cooldown" and instead
    -- treats it as PERMANENTLY on cooldown (fail-closed) after the very
    -- first use — a 0 here does not mean "unthrottled," it means the tool
    -- locks out after exactly one invocation until this resource restarts.
    -- This mirrors cooldowns.lua's own AssertValidDefaultThreshold guard
    -- (`value > 0`) and server/admin.lua's identical positive-floor
    -- requirement on its own CommandCooldownMs, applied here at the
    -- call-time-threshold call shape instead of the constructor-default
    -- shape.
    ResolveBoneSweepToolField('CommandCooldownMs', function(v) return type(v) == 'number' and v > 0 end, 500,
        'must be a number > 0 -- 0 or negative does NOT mean "no cooldown" here, it means this tool fails closed ' ..
        '(permanently blocked) after one use; see server/cooldowns.lua\'s fail-closed threshold handling')

    RegisterCommand('k9bonetool', function(src, args)
        if src == 0 then
            -- Console carve-out is DELIBERATELY absent here — see this
            -- file's header ACCESS MODEL section.
            print('[qbx_k9unit] /k9bonetool must be run by a connected player, not the server console.')
            return
        end

        local sub = args[1]

        -- NO UNBOUNDED TRAP -- 'stop' is this tool's ONLY termination/cleanup
        -- path (removes the preview marker AND any attached test object,
        -- see EVENT CONTRACT above) and MUST stay reachable even for a
        -- caller whose IsAuthorizedBoneSweepDevTool grant is revoked
        -- mid-session (a job change, a demotion, a boss toggling someone's
        -- isboss flag off) — mirroring the rule the since-removed recall
        -- feature was built around: a handler whose certification is revoked
        -- mid-bite must still be able to call their dog off, so an access
        -- check must never sit on the escape-hatch path.
        -- Deliberately checked and dispatched BEFORE the authorization gate
        -- below, not merely exempted from it after the fact, so no future
        -- edit can accidentally reorder an authorization check back in
        -- front of it. The per-source cooldown still applies (same as
        -- Recall's own RequestCooldownMs) — this is anti-spam, not
        -- authorization, and only ever delays a repeat call briefly, never
        -- denies it outright.
        if sub == 'stop' then
            if not BoneToolCooldown.Consume(src, Config.BoneSweepTool.CommandCooldownMs) then
                return -- silent no-op: rate-limited, matches this resource's own bark/leash-request/certify-action convention
            end
            TriggerClientEvent('qbx_k9unit:client:boneToolCommand', src, 'stop', nil)
            return
        end

        if not IsAuthorizedBoneSweepDevTool(src) then
            NotifyPlayer(src, locale('bonetool.not_authorized'), 'error')
            return
        end

        -- PER-PERSON FEATURE CONTROL -- see IsBoneSweepDevToolPermittedForCitizenId
        -- above. Checked BEFORE BoneToolCooldown.Consume below, matching this
        -- resource's own "a block must never burn a cooldown slot" discipline.
        -- Reuses the same 'bonetool.not_authorized' locale as the rank check
        -- immediately above -- a per-person block reads to the caller exactly
        -- like "you are not authorized," which is true either way.
        do
            local player = exports.qbx_core:GetPlayer(src)
            local citizenid = player and player.PlayerData and player.PlayerData.citizenid
            if not citizenid or not IsBoneSweepDevToolPermittedForCitizenId(citizenid) then
                NotifyPlayer(src, locale('bonetool.not_authorized'), 'error')
                return
            end
        end

        if not BoneToolCooldown.Consume(src, Config.BoneSweepTool.CommandCooldownMs) then
            return -- silent no-op: rate-limited, matches this resource's own bark/leash-request/certify-action convention
        end

        if not VALID_SUBCOMMAND_SET[sub] then
            NotifyPlayer(src, BONE_TOOL_USAGE, 'error')
            return
        end

        if sub == 'help' then
            -- Handled ENTIRELY here — no client dispatch needed for plain
            -- text, and a human should be able to read the full workflow
            -- even before confirming anything client-side is working.
            NotifyPlayer(src, BONE_TOOL_USAGE, 'info')
            return
        end

        if sub == 'goto' then
            local index = tonumber(args[2])
            if not index then
                NotifyPlayer(src, locale('bonetool.usage_goto'), 'error')
                return
            end
            index = math.floor(index)
            if index < 0 then index = 0 end
            if index > Config.BoneSweepTool.MaxBoneIndex then index = Config.BoneSweepTool.MaxBoneIndex end
            TriggerClientEvent('qbx_k9unit:client:boneToolCommand', src, 'goto', index)
        elseif sub == 'next' or sub == 'prev' then
            -- args[2], if present, is a STEP size (how many indices to
            -- move), never an absolute index — see this file's header
            -- EVENT CONTRACT. Defaults to 1, matching the tool's original
            -- one-at-a-time behavior; a human sweeping up to MaxBoneIndex
            -- (200 by default) benefits from being able to skip ahead.
            local step = 1
            local parsed = tonumber(args[2])
            if parsed then
                step = math.max(1, math.floor(parsed))
            end
            TriggerClientEvent('qbx_k9unit:client:boneToolCommand', src, sub, step)
        else
            -- 'test' / 'known' — no argument of any kind. ('stop' is
            -- handled earlier, above, before the authorization check — see
            -- the NO UNBOUNDED TRAP comment there.)
            TriggerClientEvent('qbx_k9unit:client:boneToolCommand', src, sub, nil)
        end
    end, false)

    print('[qbx_k9unit] bonetool.lua: dev-only bone-index sweep tool registered (/k9bonetool). DO NOT enable Config.Features.BoneSweepDevTool on a production server.')
end)
