--[[
    john-k9/client/bonetool.lua

    Client half of the dev-only bone-index sweep tool — see
    server/bonetool.lua's header for the full access-model/purpose writeup
    (read that file first). Built directly against this resource's own
    prior research (DEVELOPER_REFERENCE.md#phase-5-research,
    read in full before writing this file): no documented bone NAME exists
    for an `a_c_*` quadruped skeleton anywhere this codebase's research could
    reach, but `AttachEntityToEntity` only ever needed a raw INDEX, and
    `GetWorldPositionOfEntityBone` (confirmed directly against
    citizenfx/natives by that research pass, ENTITY namespace, hash
    0x44A8FCB8ED227738 / alt 0x7C6339DF) is entity-type-agnostic and requires
    no name at all — so the right tool is a raw-index position sweep, not
    another documentation search.

    ======================================================================
    RE-CONFIRMED DIRECTLY AGAINST A FRESH CLONE OF citizenfx/natives (not
    taken on the prior research pass's word alone):
      - ENTITY/AttachEntityToEntity.md, 0x6B9BBD38AB0796DF: `boneIndex`
        (3rd param) doc text verbatim — "This is different to boneID, use
        GET_PED_BONE_INDEX to get the index from the ID... entity1 will be
        attached to the center of entity2 if bone index given doesn't
        correspond to bone indexes for that entity type." That second
        clause is precisely why a wrong/out-of-range index degrades to
        "visibly wrong," never a crash — it's the native's own documented
        fallback, not this file's assumption.
      - ENTITY/GetWorldPositionOfEntityBone.md, 0x44A8FCB8ED227738: declared
        `Entity entity`, ENTITY namespace — confirmed (again) entity-type
        agnostic, not PED-only.
      - PED/GetPedBoneIndex.md, 0x3F428D08BE5AAE31: see the GETPEDBONEINDEX
        section below — new ground, not previously covered.
    PRECISION NOTE: the native imposes NO restriction on which raw index is
    valid for which entity type — it will happily accept any int and fall
    back to "center of entity2" if that slot is unused. The reason a
    human-derived semantic bone (a name/id meaningful on a PLAYER skeleton)
    is not automatically meaningful here is entirely the MODEL's doing, not
    the native's: whether a given raw index — or a given semantic boneId
    resolved via GetPedBoneIndex — corresponds to anything recognizable on
    an `a_c_*` skeleton depends on how that specific asset was rigged,
    which no native call and no documentation search can answer from
    outside the engine. Only looking, via this tool, answers it.

    GETPEDBONEINDEX — CONFIRMED AGAINST PRIMARY SOURCE, AND THE CONCLUSION
    ON WHETHER THIS TOOL (OR THE FEATURES IT SERVES) SHOULD CONVERT THROUGH
    IT: `int GET_PED_BONE_INDEX(Ped ped, int boneId)` — converts a semantic
    `ePedBoneId` value (e.g. `SKEL_Head = 0x796E`) into the raw index
    AttachEntityToEntity wants; this is the exact conversion
    AttachEntityToEntity's own doc points at. That same enum ALSO lists
    entries no purely human skeleton would ever need — `SKEL_Tail_01`
    through `SKEL_Tail_05`, `SKEL_SADDLE` — which only makes sense if this
    id table is shared across skeleton TYPES in this game's asset pipeline,
    not human-only. That's corroborating evidence, not proof, that some of
    these ids resolve to something real on an `a_c_*` model.
    CONCLUSION: this file now offers GetPedBoneIndex as a FAST-PATH
    shortcut (the 'known' subcommand below) alongside the raw sweep, never
    instead of it, for two reasons this file will not paper over:
      1. GetPedBoneIndex's own primary-source doc page has an EMPTY "Return
         value" section — it could not be confirmed what it returns for a
         boneId absent from a given skeleton (a `-1` sentinel, or something
         else). 'known' below reports every raw value UNFILTERED and says
         so, rather than silently guessing which ones are "hits."
      2. Even a boneId that resolves to SOME real index on a dog's skeleton
         is not guaranteed to be anatomically where a human familiar with
         the human-skeleton name would expect — the lookup matches by hash
         TAG against however THIS asset was actually rigged, which nothing
         here has a way to inspect (binary mesh/skeleton data is outside
         what any tool here can read). A 'known' hit is a CANDIDATE to
         visually confirm via 'goto', exactly like every other index this
         tool surfaces — never a trusted answer by itself.

    TWO MODES, BOTH DRIVEN BY THE SAME `currentBoneIndex`, PLUS ONE
    INFORMATIONAL SHORTCUT:
    1. PREVIEW (subcommands 'goto'/'next'/'prev', always active once any of
       these has been used at least once): every frame, draws a small debug
       marker AND an on-screen text label (see Draw3DText below) at
       `GetWorldPositionOfEntityBone(PlayerPedId(), currentBoneIndex)`. This
       is a pure position QUERY — it never creates an object and never
       calls AttachEntityToEntity — exactly the "cheapest possible" sweep
       primitive the research pass identified, and the reason this tool
       needs no marker prop model at all for this half of the workflow. A
       human walks around their own K9-modelled ped, runs '/k9bonetool goto
       <n>' (or next/prev [step] to move by an arbitrary amount — see
       server/bonetool.lua's own EVENT CONTRACT), and watches where the
       marker AND its index label land relative to their own ped for each
       raw index.
    2. TEST (subcommand 'test'): once a candidate index looks promising in
       PREVIEW mode, this does a REAL CreateObject + AttachEntityToEntity at
       that exact index (via client/propattachment.lua's shared
       AttachPropToOwnPed — see that file's own contract), so the human can
       confirm the actual attach call (rotation space, offset behavior,
       whether it clips during this resource's existing bark/pant scenario
       animations — see the research note on FetchMechanic's mouth-bone
       articulation risk) rather than trusting the position query alone.
    3. 'known' (informational only, see GETPEDBONEINDEX above): resolves a
       curated list of documented ePedBoneId semantic names against the
       caller's own live ped and reports every result via chat + console.
       Never touches currentBoneIndex/sweepActive/testEntity — it exists
       purely to hand the human a shortlist of indices worth a 'goto',
       rather than a blind 0..MaxBoneIndex crawl every time.

    GRACEFUL DEGRADATION: `GetWorldPositionOfEntityBone`'s behavior for an
    out-of-range index was NOT independently confirmed (no live client
    available) — the research pass's own honest assessment is "expected to
    fail gracefully... based on the sibling native's documented -1-on-miss
    convention," not a confirmed fact for THIS native specifically. This
    file never asserts on the returned vector — an invalid index is
    expected, at worst, to draw a marker at some uninformative position
    (e.g. coincident with the ped's own root), which is itself useful sweep
    information ("nothing distinct lives at this index"), never a crash.

    OPERATIONAL CAVEAT (also stated in config.lua's own
    Config.Features.BoneSweepDevTool comment and in server/bonetool.lua's
    own ACCESS MODEL section; restated here because this file is the one
    that actually runs the draw thread and registers the event handler):
    this file's own registration gate (the `if Config.Features and
    Config.Features.BoneSweepDevTool == true and GetConvarInt(...) == 1
    then` a few lines below) is evaluated ONCE, when this file loads.
    Flipping the flag or the convar off and back on WITHOUT a resource
    restart does not un-register anything on THIS client either — same
    "gate at registration, not inside the handler" tradeoff
    server/bonetool.lua's own command registration makes, applied here to
    the event handler/draw thread/cleanup hooks. Never treat "the flag/
    convar is off now" as sufficient by itself without also restarting.

    SECOND, EXPLICIT OPT-IN — CONVAR (see server/bonetool.lua's own header
    SECOND, EXPLICIT OPT-IN section for the full "why" writeup, not
    re-derived here): this file's own registration gate now ALSO requires
    `GetConvarInt('john_k9_enable_bone_dev_tool', 0) == 1`, not just the
    feature flag — WHY THIS FILE NEEDS ITS OWN COPY OF THAT CHECK, not
    merely relying on the server never sending
    'john-k9:client:boneToolCommand' when it's unset: without it, EVERY
    client on a server that ships Config.Features.BoneSweepDevTool = true
    but has not opted in via the convar would still register this file's
    RegisterNetEvent handler and start its per-frame preview draw thread
    (harmless in effect — the SOURCE-ORIGIN GUARD below means a client can
    never trigger its own handler, and the server-side command that would
    ever dispatch this event does not exist in that configuration — but
    genuinely pointless: a permanently-idle thread and a permanently-dead
    event registered on every connected player's client for a feature that
    can never fire). Requiring the SAME convar here closes that gap
    entirely rather than leaving it "harmless but wasteful." This is why
    server/bonetool.lua's own header insists on a REPLICATED (`setr`, not
    `set`) convar: a plain `set` convar is only ever visible server-side,
    and this file could not read it at all without one.

    FILE-TO-FILE CONTRACT:
    - THIS FILE calls `AttachPropToOwnPed`/`DetachAndDeleteProp`, both
      exposed by client/propattachment.lua — do not re-implement the
      CreateObject/RequestModel/AttachEntityToEntity sequence here. NO HARD
      LOAD-ORDER REQUIREMENT: both calls happen at RUNTIME, inside this
      file's own event handler / local functions, never at file-load time —
      same "global-function resolution is at call time, not load time"
      convention client/combat.lua's own header already established for its
      own soft cross-file dependencies. Placed after client/propattachment.lua
      in fxmanifest.lua purely for topical/reading-order grouping (both
      files serve the same PropAttachments/bone-index problem), not because
      either requires it.
    - THIS FILE exposes no resource-global functions of its own.
]]

-- Debug-marker draw constants — plain local constants, not config, since
-- this is purely a rendering choice for a dev-only tool, not a tunable
-- gameplay value. Small, bright red sphere-ish marker (native marker type 1,
-- a widely-used generic debug marker shape in the wider FiveM ecosystem) —
-- MEDIUM confidence on the specific type-1 shape rendering as expected
-- (not independently re-verified in this sandbox), but DrawMarker itself is
-- already an established native in this codebase (client/movement.lua's
-- AgilityAdvanced groundwork) and an out-of-range/unexpected marker type is
-- expected to be a harmless no-render, never a crash, per this native's own
-- long-standing ecosystem-wide convention.
local MARKER_TYPE = 1
local MARKER_SCALE = 0.15
local MARKER_COLOR = { r = 255, g = 40, b = 40, a = 200 }

-- On-screen index-label draw constants — same "plain local constants, not
-- config" reasoning as the marker constants above. FONT_CONDENSED (4) is
-- taken from citizenfx/natives HUD/SetTextFont.md's own eTextFonts enum,
-- confirmed — a plain, compact, legible face for a short numeric label.
-- LABEL_HEIGHT_OFFSET lifts the label clear of the marker sphere
-- (MARKER_SCALE 0.15) so the two never visually overlap.
local LABEL_TEXT_SCALE = 0.35
local LABEL_TEXT_FONT = 4
local LABEL_HEIGHT_OFFSET = 0.45

-- SECOND, EXPLICIT OPT-IN — see this file's header SECOND, EXPLICIT OPT-IN
-- section, and server/bonetool.lua's own header, for the full "why"
-- writeup. MUST be the exact same literal as server/bonetool.lua's own
-- BONE_DEV_TOOL_ENABLE_CONVAR constant — the two are duplicated per-file
-- (see that file's own comment on this constant) rather than shared, but
-- both must resolve to one REPLICATED (`setr`) convar for this file to
-- ever see the same value the server used.
local BONE_DEV_TOOL_ENABLE_CONVAR = 'john_k9_enable_bone_dev_tool'

-- This client's own state — all local-only, never read from another file.
local sweepActive = false
local currentBoneIndex = 0
local testEntity = nil

--- @param boneIndex number
--- @param maxIndex number
--- @return number clamped
local function ClampBoneIndex(boneIndex, maxIndex)
    if boneIndex < 0 then return 0 end
    if boneIndex > maxIndex then return maxIndex end
    return boneIndex
end

--- Sets the active preview index, starts the draw loop if not already
--- running, and gives the human immediate feedback on what index they're
--- now looking at — INCLUDING how to record it once it looks right (the
--- tool must tell a human what to do with what they find). Multi-line
--- description, same established pattern as server/admin.lua's own
--- `table.concat(lines, '\n')` NotifyPlayer calls — ox_lib's notify
--- already renders embedded newlines correctly in that existing use.
--- @param boneIndex number
local function SetPreviewBoneIndex(boneIndex)
    currentBoneIndex = boneIndex
    sweepActive = true
    lib.notify({
        title = locale('bonetool.notify_title'),
        description = locale('bonetool.preview_bone_index', boneIndex),
        type = 'info',
    })
    print(('[John-K9] bonetool: previewing bone index %d'):format(boneIndex))
end

-- ======================================================================
-- REGISTRATION-TIME FEATURE GATE — the preview draw thread below, the
-- RegisterNetEvent handler, and the onResourceStop cleanup hook are now
-- all inside this single `if`, evaluated once at this file's own load
-- time. Config.lua is a shared_scripts file, loaded in full before any
-- client_scripts file runs, so Config.Features.BoneSweepDevTool already
-- holds its real value here — not a load-order gamble. Mirrors this SAME
-- file's own client/propattachment.lua sibling gate and this resource's
-- server/bonetool.lua precedent ('/k9bonetool' is only ever
-- RegisterCommand'd inside its own flag-checked onResourceStart): a
-- dev-only sweep tool left merely "gated inside the handler" would still
-- run a per-frame draw thread (once triggered) and a registered, reachable
-- event on every production client that never opted in — this makes it
-- genuinely inert instead, not merely hidden. The FEATURE GATE check
-- already inside the handler below is kept regardless, as defense-in-depth
-- (same "layered checks" posture as the SOURCE-ORIGIN GUARD immediately
-- below it).
-- ======================================================================
if Config.Features and Config.Features.BoneSweepDevTool == true and GetConvarInt(BONE_DEV_TOOL_ENABLE_CONVAR, 0) == 1 then

--- On-screen 3D text label at a world position — shows the current bone
--- index directly next to the preview marker, so a human doesn't have to
--- remember/scroll back through a chat notification while walking around
--- their own dog looking from different angles (the index must be
--- readable, not just logged once). Every native below is confirmed
--- directly against a fresh clone of citizenfx/natives, as the CURRENT,
--- non-deprecated names for what older FiveM scripts universally call
--- SET_TEXT_ENTRY/ADD_TEXT_COMPONENT_STRING/DRAW_TEXT — that repo's own
--- reference no longer lists those three under separate entries at all,
--- only as `aliases` on the ones actually called here
--- (HUD/BeginTextCommandDisplayText.md aliases `_SET_TEXT_ENTRY`,
--- HUD/AddTextComponentSubstringPlayerName.md aliases
--- `_ADD_TEXT_COMPONENT_STRING`, HUD/EndTextCommandDisplayText.md aliases
--- `_DRAW_TEXT`). GRAPHICS/SetDrawOrigin.md's own doc EXAMPLE uses this
--- exact BeginTextCommand/SetDrawOrigin/EndTextCommand/ClearDrawOrigin
--- pairing anchored on a bone coordinate — precisely this function's use
--- case.
--- ONE THING NOT independently re-confirmed by that primary-source read:
--- that the 'STRING' text label itself expands to the placeholder '~a~'
--- (which is what makes AddTextComponentSubstringPlayerName's arbitrary
--- text actually show up instead of a literal, meaningless "STRING" token
--- on screen). This is the single most widely relied-upon convention in
--- the entire FiveM scripting ecosystem, and the same primary-source doc
--- corroborates it indirectly (BeginTextCommandDisplayText.md lists
--- 'STRING' as the very first decompiled label in active use) — but its
--- exact expansion was not restated verbatim there, so this is graded
--- MEDIUM-HIGH, not "confirmed," matching this file's own established
--- confidence discipline elsewhere.
--- SetTextColour is called with equal R/G/B here specifically because its
--- own primary-source doc discloses the argument order is actually
--- R,B,G,A despite the parameter names ("colors you input not same as you
--- think? for some reason its R B G A") — with all three equal (plain
--- white) that quirk has no visible effect, so it's sidestepped rather
--- than solved.
--- SetTextProportional is deliberately NOT called: its own primary-source
--- doc states it "does absolutely nothing, just a nullsub" — calling a
--- confirmed no-op would be dead code dressed up as boilerplate, not
--- defensive programming.
--- @param x number
--- @param y number
--- @param z number
--- @param text string
local function Draw3DText(x, y, z, text)
    SetTextScale(LABEL_TEXT_SCALE, LABEL_TEXT_SCALE)
    SetTextFont(LABEL_TEXT_FONT)
    SetTextColour(255, 255, 255, 215)
    SetTextCentre(true)
    BeginTextCommandDisplayText('STRING')
    AddTextComponentSubstringPlayerName(text)
    SetDrawOrigin(x, y, z, 0)
    EndTextCommandDisplayText(0.0, 0.0)
    ClearDrawOrigin()
end

--- PREVIEW draw loop — only does real work while `sweepActive` is true, and
--- backs off to a slow poll otherwise so this thread costs nothing for the
--- overwhelming majority of a session where the tool isn't in use (this
--- resource's own established "don't run a hot loop for an inactive
--- feature" convention, e.g. client/wellbeing.lua's own tick-gating).
CreateThread(function()
    while true do
        if sweepActive then
            local ped = PlayerPedId()
            if DoesEntityExist(ped) and not IsEntityDead(ped) then
                local pos = GetWorldPositionOfEntityBone(ped, currentBoneIndex)
                DrawMarker(
                    MARKER_TYPE, pos.x, pos.y, pos.z,
                    0.0, 0.0, 0.0, 0.0, 0.0, 0.0,
                    MARKER_SCALE, MARKER_SCALE, MARKER_SCALE,
                    MARKER_COLOR.r, MARKER_COLOR.g, MARKER_COLOR.b, MARKER_COLOR.a,
                    false, false, 2, false, nil, nil, false
                )
                -- LOCALIZATION FIX: was `labelText .. ' (TEST PROP
                -- ATTACHED)'` -- exactly the untranslatable
                -- Lua-concatenation pattern this whole migration exists to
                -- close (see DEVELOPER_REFERENCE.md's "Format" section and its
                -- running "expect a third instance" note). Two full-sentence
                -- keys instead, same "on/off-shaped state words don't
                -- translate uniformly via concatenation/templating" reasoning
                -- already established for movement.camera_first_person/
                -- camera_third_person and partnership.now_partnered_as_*.
                local labelText
                if testEntity and DoesEntityExist(testEntity) then
                    labelText = locale('bonetool.bone_index_label_test_attached', currentBoneIndex)
                else
                    labelText = locale('bonetool.bone_index_label', currentBoneIndex)
                end
                Draw3DText(pos.x, pos.y, pos.z + LABEL_HEIGHT_OFFSET, labelText)
            end
            Wait(0) -- DrawMarker/Draw3DText must be reasserted every frame, same discipline as every other per-frame native call already in this resource
        else
            Wait(500)
        end
    end
end)

--- TEST mode: a real CreateObject + AttachEntityToEntity at
--- `currentBoneIndex`, via the shared mechanic client/propattachment.lua
--- exposes. Replaces any previous test object first.
local function RunAttachTest()
    DetachAndDeleteProp(testEntity)
    testEntity = nil

    local cfg = Config.BoneSweepTool
    local obj = AttachPropToOwnPed(
        cfg.TestPropModel, currentBoneIndex,
        cfg.TestOffsetX, cfg.TestOffsetY, cfg.TestOffsetZ,
        0.0, 0.0, 0.0,
        false, -- isNetworked: local-only diagnostic aid, see this file's header
        nil
    )

    if not obj then
        lib.notify({ title = locale('bonetool.notify_title'), description = locale('bonetool.test_prop_load_failed'), type = 'error' })
        return
    end

    testEntity = obj
    lib.notify({
        title = locale('bonetool.notify_title'),
        description = locale('bonetool.test_attached', currentBoneIndex),
        type = 'info',
    })
end

-- CANDIDATE SEMANTIC BONE IDS for the 'known' subcommand — see this file's
-- header GETPEDBONEINDEX section for the full honesty caveats before
-- treating any of these as more than "worth a look." Every {name, id} pair
-- here is transcribed verbatim from citizenfx/natives' own
-- PED/GetPedBoneIndex.md ePedBoneId enum (confirmed, hash
-- 0x3F428D08BE5AAE31) — re-diff against that file directly if this list is
-- ever extended, rather than trusting a second-hand copy. Deliberately a
-- SHORT curated shortlist (skeleton landmarks + the two entries most
-- relevant to this resource's own two consumers: a back/torso point for
-- PropAttachments' vest, a head/jaw point for FetchMechanic's mouth carry)
-- rather than the enum's full ~400 entries — most of that enum is
-- human-facial-rig-only and has no plausible bearing on a quadruped.
local KNOWN_BONE_CANDIDATES = {
    { name = 'SKEL_ROOT',         id = 0x0 },
    { name = 'SKEL_Pelvis',       id = 0x2E28 },
    { name = 'SKEL_PelvisRoot',   id = 0x45FC },
    { name = 'SKEL_Spine_Root',   id = 0xE0FD },
    { name = 'SKEL_Spine0',       id = 0x5C01 },
    { name = 'SKEL_Spine1',       id = 0x60F0 },
    { name = 'SKEL_Spine2',       id = 0x60F1 },
    { name = 'SKEL_Spine3',       id = 0x60F2 },
    { name = 'SKEL_Neck_1',       id = 0x9995 },
    { name = 'SKEL_Neck_2',       id = 0x5FD4 },
    { name = 'SKEL_Head',         id = 0x796E },
    { name = 'FACIAL_facialRoot', id = 0xFE2C },
    { name = 'FACIAL_jaw',        id = 0xB21 },
    { name = 'SKEL_SADDLE',       id = 0x9524 },
    { name = 'SKEL_L_Thigh',      id = 0xE39F },
    { name = 'SKEL_R_Thigh',      id = 0xCA72 },
    { name = 'SKEL_Tail_01',      id = 0x347 },
    { name = 'SKEL_Tail_02',      id = 0x348 },
    { name = 'SKEL_Tail_03',      id = 0x349 },
    { name = 'SKEL_Tail_04',      id = 0x34A },
    { name = 'SKEL_Tail_05',      id = 0x34B },
}

--- 'known' subcommand — see this file's header GETPEDBONEINDEX section.
--- CLIENT-LOCAL ONLY: never touches currentBoneIndex/sweepActive/
--- testEntity, never talks to the server. Purely reports candidate indices
--- for the human to 'goto' and visually confirm themselves — GetPedBoneIndex
--- is called here, ONLY here, and its result is never trusted further than
--- "worth a look."
local function RunKnownBoneSweep()
    local ped = PlayerPedId()
    local lines = { locale('bonetool.known_sweep_header') }
    for _, candidate in ipairs(KNOWN_BONE_CANDIDATES) do
        local resolved = GetPedBoneIndex(ped, candidate.id)
        lines[#lines + 1] = locale('bonetool.known_sweep_line', candidate.name, candidate.id, tostring(resolved))
    end
    lines[#lines + 1] = locale('bonetool.known_sweep_footer')

    -- table.concat below joins already-localized `lines` entries with '\n'
    -- -- this is not the "rebuild a sentence with .." pattern the migration
    -- guards against, since none of the individual locale() results
    -- themselves get concatenated onto each other's TEXT, only assembled as
    -- separate lines. The print() one line down stays untouched (operator
    -- diagnostic), same as everywhere else in this migration.
    local message = table.concat(lines, '\n')
    print('[John-K9] bonetool known-name sweep:\n' .. message)
    lib.notify({ title = locale('bonetool.notify_title'), description = message, type = 'info' })
end

--- Server-issued instruction — see server/bonetool.lua's own EVENT
--- CONTRACT for the full subcommand list.
--- @param subcommand string
--- @param arg number? -- absolute index for 'goto'; a positive STEP size for 'next'/'prev' (defaults to 1 if absent/invalid); unused otherwise
RegisterNetEvent('john-k9:client:boneToolCommand', function(subcommand, arg)
    -- SOURCE-ORIGIN GUARD (see client/combat.lua's "SOURCE-ORIGIN GUARD"
    -- header block and DEVELOPER_REFERENCE.md#trust-boundary for the full
    -- writeup, not re-derived here). Confidence: MEDIUM-HIGH, the official
    -- documented pattern, not independently verified in-engine.
    if source ~= 65535 then return end

    -- FEATURE GATE — this handler must never fire real effects while the
    -- flag or the convar is off, even though server/bonetool.lua only ever
    -- sends this event from behind its own flag+convar (registration-time)
    -- and job-rank (per-invocation) gates; defense in depth, matching every
    -- other gated handler's own per-handler convention in this resource.
    if not (Config.Features and Config.Features.BoneSweepDevTool == true) then return end
    if GetConvarInt(BONE_DEV_TOOL_ENABLE_CONVAR, 0) ~= 1 then return end

    local maxIndex = (Config.BoneSweepTool and Config.BoneSweepTool.MaxBoneIndex) or currentBoneIndex

    if subcommand == 'goto' then
        if type(arg) ~= 'number' then return end
        SetPreviewBoneIndex(ClampBoneIndex(math.floor(arg), maxIndex))
    elseif subcommand == 'next' or subcommand == 'prev' then
        -- `arg`, if present, is a STEP size, never an absolute index.
        -- server/bonetool.lua already validates/clamps it to a positive
        -- integer before ever sending it; re-validated here rather than
        -- trusted blindly, same defense-in-depth posture as the feature
        -- gate immediately above.
        local step = 1
        if type(arg) == 'number' and arg >= 1 then
            step = math.floor(arg)
        end
        local delta = subcommand == 'next' and step or -step
        SetPreviewBoneIndex(ClampBoneIndex(currentBoneIndex + delta, maxIndex))
    elseif subcommand == 'test' then
        RunAttachTest()
    elseif subcommand == 'known' then
        RunKnownBoneSweep()
    elseif subcommand == 'stop' then
        sweepActive = false
        DetachAndDeleteProp(testEntity)
        testEntity = nil
    end
end)

-- Resource-restart safety net — same class of fix as
-- client/propattachment.lua's/client/kennel.lua's own onResourceStop
-- handlers. Doubly important here since this is a dev-only tool expected to
-- be used, forgotten about, and left running mid-session.
AddEventHandler('onResourceStop', function(resourceName)
    if resourceName ~= GetCurrentResourceName() then return end

    sweepActive = false
    DetachAndDeleteProp(testEntity)
    testEntity = nil
end)

end -- if Config.Features.BoneSweepDevTool -- REGISTRATION-TIME FEATURE GATE, see this block's own opening comment
