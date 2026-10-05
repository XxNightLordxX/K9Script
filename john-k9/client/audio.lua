--[[
    john-k9/client/audio.lua

    NUI AUDIO BRIDGE — closes this resource's oldest disclosed gap (Phase 1's
    placeholder bark soundset; see client/main.lua's BARK_SOUND_NAME/
    K9_SOUND_SET header comment) by giving PlaySoundOnNetworkEntity (that
    file) a second, real playback path through this resource's existing
    NUI page, alongside its current, harmless-no-op PlaySoundFromEntity
    call into the RAGE audio engine.

    client/main.lua's PlaySoundOnNetworkEntity function body already calls
    `if type(PlayK9Sound) == 'function' then PlayK9Sound(netId, soundName)
    end` immediately after its existing PlaySoundFromEntity call, with
    exactly the runtime-existence guard this file's own "GATING" section
    below requires. This file itself is not edited to make that happen —
    the wiring lives entirely in client/main.lua.

    AUTHORITATIVE BACKGROUND — read before touching this file:
      - DEVELOPER_REFERENCE.md#dependencies-and-audio (concluded that
        extending this resource's already-live NUI bridge is cheaper than
        authoring a real .awc/dat151/dat54 RAGE audio bank — this file,
        plus html/app.js's matching additions, IS that extension).
      - DEVELOPER_REFERENCE.md#phase-5-research (confirms a
        Web Audio GainNode does continuous volume scripting natively, with
        zero dependency on any FiveM native, RAGE metadata, or authored
        RTPC variable — the reason this path can do distance-based gain at
        all. Also confirms the ecosystem's own most-used NUI audio library,
        plunkettscott/interact-sound, has a still-open TODO for even the
        SIMPLE, single-factor version of this. Treat this file's falloff
        math as new, unverified-in-the-wild plumbing, not a copy of a
        proven pattern.)
      - client/hud.lua (the existing NUI bridge file this one is modeled
        on — same gating convention, same "global helper, private per-file
        state" convention, same focus policy, same tuning-constants-are-
        code-local-not-Config posture).
      - html/app.js's own header comment for the JS-side half of this exact
        contract (payload shapes below must match byte-for-byte).

    ==========================================================================
    WHAT THIS FILE DELIBERATELY DOES NOT DO:

      - Does NOT ship, fabricate, download, or reference the bytes of any
        real .ogg file. No such file exists in this resource, and none was
        added to produce this file. This file's entire job is the PLUMBING
        that plays a real file once a server operator drops one in at
        html/sounds/<key>.ogg — see ToAudioFileKey() below for the exact
        name this file will look up, and html/app.js's loadSoundBuffer()
        for the fetch path convention. Every play attempt against a
        not-yet-supplied file degrades to a silent, zero-console-output
        no-op end to end (this file never even learns whether the file
        existed — see "NO ACK CHANNEL" below).

      - Does NOT call SetNuiFocus, anywhere. This resource's one NUI page
        (html/index.html) has never called it — client/hud.lua's own header
        states plainly why: "this is a passive... overlay with zero
        player-driven interaction... that entire 'stuck open with focus
        grabbed' bug class structurally cannot occur on a surface that
        never grabs focus in the first place." Audio playback adds no
        button, no dismiss target, nothing to click or type into — there is
        nothing here that would ever legitimately need focus. If a future
        change seems to need it, STOP and re-decide the whole focus
        question exactly as client/hud.lua's header instructs; do not bolt
        SetNuiFocus onto this file's focus-free lifecycle.

      - Does NOT edit client/main.lua. This file only DEFINES PlayK9Sound/
        StopK9Sound/IsK9SoundActive; client/main.lua's PlaySoundOnNetworkEntity
        is the one that CALLS PlayK9Sound (guarded with
        `type(PlayK9Sound) == 'function'`) — already wired there.

      - Does NOT add a JS -> Lua NUI callback / RegisterNUICallback of any
        kind. Every message this file sends is one-directional
        (SendNUIMessage, Lua -> JS only) — there is no fetch() anywhere in
        html/app.js's audio-handling code that reaches back into this file,
        and therefore no new payload here for a modified client to forge
        into a callback. The only "input" a hostile client could exploit is
        calling this file's own exposed globals (PlayK9Sound/StopK9Sound)
        directly with arbitrary arguments — which is the same trust
        boundary every other self-initiated global in this resource already
        accepts (RequestLeashAttach, RequestBiteHold, RequestPartnerUp,
        etc. are all directly callable by a modified client too), and the
        entire effect of calling it is "this ONE client's own browser
        attempts to play a locally-fetched, read-only audio file at a
        gain the caller also controls" — a purely local, purely cosmetic
        effect with no server-authoritative state and no other player ever
        exposed to it. Disclosed here regardless, per this resource's
        standing convention of naming trust-relevant details even when the
        practical severity is low.

      - NO ACK CHANNEL, ON PURPOSE, UNLIKE client/hud.lua's 'hud:ready':
        client/hud.lua's design deliberately waits for an explicit
        'hud:ready' handshake before its first push, because a dropped
        SendNUIMessage there would otherwise mean the HUD shows nothing
        until its own ~1s heartbeat repairs it — worth the extra round
        trip for a continuously-live surface. This file's 'audio:play'
        pushes have no such self-healing "next tick" (a missed bark is
        just... missed, forever, for that one bark), so in principle the
        exact same startup race client/hud.lua's handshake solves for
        applies here too. This file accepts that risk deliberately rather
        than adding a second ack channel to the same page, for two
        concrete reasons: (1) html/index.html's `ui_page` loads once for
        the ENTIRE client session at resource start, and by the time any
        player could realistically trigger a bark (requires K9 model +
        certification + opening the radial menu), the page's `message`
        listener has been attached for a comparatively very long time —
        this is not the same "first paint" race client/hud.lua's
        'hud:ready' exists to close; (2) the cost of losing a race here is
        a single missed one-shot sound cue, not a wrong/stale persistent
        readout — a materially lower-severity failure mode than the one
        'hud:ready' protects against. If this assumption is ever wrong in
        practice (e.g. a server that force-triggers a bark within the
        first tick of resource start), that would show up as an
        occasionally-silent very-first bark only — not a stuck or broken
        state — and is a cheap thing to revisit later, not a correctness
        bug being silently shipped.
    ==========================================================================

    GATING — "gate at registration, not just inside the loop" (same
    convention as client/hud.lua's own header, client/vision.lua's
    Config.Features.ThermalVision gate, and client/movement.lua's
    AgilityBasicJump thread). This file returns entirely, defining NEITHER
    PlayK9Sound NOR StopK9Sound, while Config.Features.BasicBarkSounds is
    false — the SAME flag that already governs whether bark audio plays at
    all anywhere else in this resource today (client/radial.lua only
    registers the Bark radial item under this flag; server/main.lua's
    relayBark handler returns immediately if it's false). This file rides
    that exact, already-established flag rather than inventing a parallel
    one, matching this resource's own "AdvancedBarkRadial is layered ON TOP
    of BasicBarkSounds, still requires it underneath" convention
    (config.lua's own Config.AdvancedBarkRadial header comment) —
    ProximityAudioFX, if it is ever built on top of this bridge, would
    need this flag true anyway for the same reason. client/main.lua's
    one-line delegate call MUST guard with `type(PlayK9Sound) ==
    'function'` before calling it, per this resource's own established
    "runtime existence guard, not a load-order assumption" convention (see
    config.lua's globals comment on AwardXP/GetXPTier for the
    precedent this follows) — with Config.Features.BasicBarkSounds false,
    PlayK9Sound simply does not exist as a global at all, and that guard is
    what keeps that call site from hard-erroring in that state.
]]

if not Config.Features.BasicBarkSounds then return end

-- ----------------------------------------------------------------------
-- Tuning constants — code-local, not Config.* entries, matching how
-- client/hud.lua's HUD_POLL_TICK_MS/HUD_HEARTBEAT_MS and
-- client/movement.lua's LEASH_TICK_MS are file-local tuning knobs rather
-- than exposed config ("none of the above needs a config addition").
-- ----------------------------------------------------------------------

-- Meters. Beyond this distance from the sound's source entity, THIS
-- client's own computed gain is 0.0. A straight-line cutoff, not the game
-- engine's own (much larger, non-linear) audio rolloff curve — a Web Audio
-- sound played via html/app.js has NO positional/distance behavior of its
-- own; this constant and DistanceToGain() below are the only things giving
-- it any at all.
local AUDIO_MAX_DISTANCE = 30.0

--- Read-only accessor for this file's private AUDIO_MAX_DISTANCE, so a
--- caller in another file (client/proximityaudio.lua's own
--- PROXIMITY_TRIGGER_DISTANCE_METERS clamp) can stay live-consistent with
--- this file's actual falloff cutoff instead of hand-syncing a duplicate
--- constant of its own. Added specifically for that consumer, after the
--- root .luacheckrc `globals` list was extended to allow it (see that
--- file's own comment on this entry). Every caller MUST still guard with
--- `type(GetK9AudioMaxDistance) == 'function'` before calling this -- this
--- resource's own "runtime existence guard, not a load-order assumption"
--- convention (config.lua's globals comment on
--- AwardXP/GetXPTier is the precedent) -- this file does not define this
--- function at all while Config.Features.BasicBarkSounds is false, no
--- matter what fxmanifest.lua's own load order promises.
--- @return number meters
function GetK9AudioMaxDistance()
    return AUDIO_MAX_DISTANCE
end

-- How often a LOOPING sound's gain gets recomputed against its source
-- entity's live position (see PlayK9Sound's `opts.loop`). Only relevant to
-- loop=true playback — client/proximityaudio.lua's continuous ambient
-- growl loop (Config.Features.ProximityAudioFX) is the real consumer of
-- loop=true playback. Deliberately slower than client/hud.lua's 250ms
-- vitals poll: a loop's volume drifting smoothly over half a second is
-- inaudible as "steps" the way a fast-changing numeric HUD readout would
-- be.
local AUDIO_GAIN_POLL_MS = 500

-- Hard safety ceiling on a looping sound's own polling thread. If nothing
-- ever calls StopK9Sound() for a given id (a caller bug, or an entity that
-- silently stops mattering without anyone noticing), this thread
-- self-terminates and tells html/app.js to stop the sound after one
-- minute rather than polling — and holding a loop open — forever. A missed
-- StopK9Sound is a caller bug either way; this only bounds its blast
-- radius to "one stale minute-long sound," not "forever."
local AUDIO_MAX_LOOP_MS = 60000

--- Maps this resource's existing RAGE-audio-style sound name/set
--- identifiers (client/main.lua's BARK_SOUND_NAME = 'Bark'; config.lua's
--- Config.AdvancedBarkRadial variant `sound` strings, e.g. 'Bark_Alert')
--- to the base filename (no extension) html/app.js's loadSoundBuffer()
--- will try to fetch from html/sounds/<key>.ogg. This indirection exists
--- so adding real playback does not force a rename of every existing
--- placeholder sound-name string already live in client/main.lua/
--- config.lua — those strings stay exactly what they are today,
--- unrelated to whether a real .ogg file exists yet at the key they map
--- to here.
---
--- 'DoorScratch'/'DoorNudge' (client/movement.lua's
--- DOOR_SCRATCH_SOUND_NAME/DOOR_NUDGE_SOUND_NAME) route through
--- PlayK9Sound too (see that file's own comment on
--- DOOR_SCRATCH_SOUND_NAME). Neither key has a shipped html/sounds/*.ogg
--- (only bark/bark_alert/bark_aggressive/bark_calm/growl_ambient do);
--- listed explicitly anyway, same as the four Bark entries below, purely
--- so the intended filename (door_scratch/door_nudge, underscored to
--- match this table's own naming convention) is documented rather than
--- left to ToAudioFileKey()'s best-effort fallback transform (which would
--- guess 'doorscratch'/'doornudge' instead — still a harmless no-op
--- either way, just a less-obvious filename for an operator to guess when
--- eventually adding the asset).
local SOUND_NAME_TO_FILE_KEY = {
    ['Bark']            = 'bark',           -- client/main.lua's BARK_SOUND_NAME, the Phase 1 generic bark
    ['Bark_Alert']      = 'bark_alert',      -- config.lua's Config.AdvancedBarkRadial
    ['Bark_Aggressive'] = 'bark_aggressive', -- config.lua's Config.AdvancedBarkRadial
    ['Bark_Calm']       = 'bark_calm',       -- config.lua's Config.AdvancedBarkRadial
    ['DoorScratch']     = 'door_scratch',    -- client/movement.lua's DOOR_SCRATCH_SOUND_NAME
    ['DoorNudge']       = 'door_nudge',      -- client/movement.lua's DOOR_NUDGE_SOUND_NAME

    -- CONTRABAND ALERT TIERS -- these were never mapped, so the
    -- bystander-audible cue for a contraband find has never played on a
    -- stock install. Config.ContrabandAlertTiers' own `alert` strings are
    -- broadcast by server/search.lua and passed straight through as the
    -- sound name by client/search.lua, so they have to resolve HERE.
    -- 'aggressive_bark' is the same two words as the shipped
    -- bark_aggressive.ogg in the opposite order, so the best-effort
    -- lower-casing fallback produced a filename that does not exist.
    ['aggressive_bark'] = 'bark_aggressive', -- large stash -- the real, shipped aggressive bark
    -- 'whine' has NO shipped asset of its own. bark_alert is the nearest
    -- honest stand-in: a short attention cue for a small find, audibly
    -- distinct from the aggressive one above so the two tiers still differ.
    -- If a real whine is ever recorded, add whine.ogg and change this line.
    ['whine']           = 'bark_alert',
    -- 'clean' is deliberately absent. Finding nothing should make no sound,
    -- and an unmapped name is a harmless no-op, so leaving it out IS the
    -- intended behaviour rather than an oversight.
}

--- Translates a RAGE-audio-style sound name into the base filename this
--- bridge will ask html/app.js to fetch. Falls back to a best-effort
--- lowercase/underscore transform for any soundName not (yet) listed in
--- SOUND_NAME_TO_FILE_KEY above (e.g. a future Config.AdvancedBarkRadial
--- variant nobody updated this table for), rather than refusing to send a
--- message at all — that guessed key is no different in outcome from any
--- other lookup that doesn't resolve to a real file: html/app.js's own
--- loadSoundBuffer() already treats every unresolved key as a silent,
--- expected no-op (see this file's header). soundName only ever originates
--- from client/main.lua's own fixed BarkTypeSoundNames table (itself built
--- from config.lua's own Config.AdvancedBarkRadial, i.e. config-authored,
--- not player input) — never from anything a player-controlled payload
--- supplies directly.
--- @param soundName string
--- @return string fileKey
local function ToAudioFileKey(soundName)
    local mapped = SOUND_NAME_TO_FILE_KEY[soundName]
    if mapped then return mapped end

    return tostring(soundName):lower():gsub('%s+', '_')
end

-- Monotonically-increasing id issued to every PlayK9Sound() call, passed
-- through to html/app.js so a LATER StopK9Sound() call (loop=true only)
-- can address the exact playback instance it means, even if several
-- overlapping sounds are in flight. Session-local only — never persisted,
-- never sent anywhere but this client's own NUI page.
local nextSoundId = 0
--- @return number
local function NextSoundId()
    nextSoundId = nextSoundId + 1
    return nextSoundId
end

-- Ids of every currently-looping sound THIS client started, keyed by the
-- id PlayK9Sound issued to it. Read by that sound's own polling thread
-- (below) each tick to know whether it should keep polling — StopK9Sound
-- clears an id's entry here, which is that thread's own signal to stop.
local activeLoops = {}

--- Straight-line falloff: 1.0 at zero distance, 0.0 at/beyond
--- AUDIO_MAX_DISTANCE, linear in between. Deliberately the simplest
--- possible curve — see this file's header: nothing about this mechanism
--- claims to reproduce GTA's own inverse-square-ish native audio rolloff
--- feel, only to give a Web Audio sound SOME distance behavior where today
--- it would otherwise have none at all. A more realistic curve is a later,
--- purely-cosmetic tuning change, not a correctness fix.
--- @param distance number
--- @return number gain 0.0-1.0
local function DistanceToGain(distance)
    if distance >= AUDIO_MAX_DISTANCE then return 0.0 end
    if distance <= 0.0 then return 1.0 end
    return 1.0 - (distance / AUDIO_MAX_DISTANCE)
end

--- This client's own gain toward a given source entity, computed from THIS
--- client's own ped position — matching the "each listening client
--- computes its own per-listener falloff" shape
--- DEVELOPER_REFERENCE.md#dependencies-and-audio already sketched for
--- ordinary bark playback, and the same vector-subtraction-length idiom
--- (`#(a - b)`) already used for every other distance check in this
--- resource (client/combat.lua, client/vehicle.lua, client/radial.lua,
--- client/movement.lua) rather than a separate GetDistanceBetweenCoords
--- native call — this needed zero new natives and zero new luacheckrc
--- entries as a result.
--- @param entity number
--- @return number gain 0.0-1.0
local function GainToEntity(entity)
    local distance = #(GetEntityCoords(PlayerPedId()) - GetEntityCoords(entity))
    return DistanceToGain(distance)
end

--- The one entry point client/main.lua's PlaySoundOnNetworkEntity
--- delegates to (see this file's header for the wiring). Resolves netId to
--- a live, currently-streamed-in entity exactly the way
--- PlaySoundOnNetworkEntity itself already does, computes THIS client's
--- own distance-based gain to it, and pushes an 'audio:play' SendNUIMessage
--- into html/app.js — the only place that actually touches Web Audio.
--- Every guard below fails CLOSED to "don't send the message" rather than
--- sending a payload already known here to be meaningless, mirroring
--- client/hud.lua's own ReadVitals/clampPercent defensiveness (html/app.js
--- additionally defends its own side of this same contract independently,
--- per this codebase's standing "assume the other side of an NUI bridge
--- can be wrong or absent" posture).
--- @param netId number netId of the entity the sound should appear to come from — same resolution path as client/main.lua's ResolveNetworkEntity/PlaySoundOnNetworkEntity
--- @param soundName string one of this resource's existing placeholder sound-name strings (client/main.lua's BARK_SOUND_NAME, config.lua's Config.AdvancedBarkRadial `sound` values) — NOT a filename; see ToAudioFileKey() above for the translation
--- @param opts table? optional `{ loop: boolean }`. client/proximityaudio.lua's ambient growl loop is the current loop=true consumer (see this file's header note near AUDIO_GAIN_POLL_MS).
--- @return number? id the id to later pass to StopK9Sound (only meaningful for loop=true), or nil if nothing was sent (bad args / entity not resolvable on this client)
function PlayK9Sound(netId, soundName, opts)
    if type(soundName) ~= 'string' or soundName == '' then return nil end

    -- Same defensive resolve PlaySoundOnNetworkEntity already performs —
    -- if this client doesn't have the entity streamed in at all, there is
    -- nothing to compute a distance TO, so this degrades to exactly the
    -- same silent no-op that function already has for that case (no
    -- error, no message sent, no console output). Guarded with a
    -- `type(...) == 'function'` existence check per this resource's
    -- standing convention, even though client/main.lua (where
    -- ResolveNetworkEntity lives) is always present in practice — this
    -- file makes no load-order assumption about it regardless.
    local entity = type(ResolveNetworkEntity) == 'function' and ResolveNetworkEntity(netId) or nil
    if not entity then return nil end

    local loop = opts ~= nil and opts.loop == true
    local id = NextSoundId()

    SendNUIMessage({
        action = 'audio:play',
        data = {
            id = id,
            sound = ToAudioFileKey(soundName),
            gain = GainToEntity(entity),
            loop = loop,
        },
    })

    if loop then
        activeLoops[id] = true

        CreateThread(function()
            local elapsed = 0

            while activeLoops[id] and elapsed < AUDIO_MAX_LOOP_MS do
                Wait(AUDIO_GAIN_POLL_MS)
                elapsed = elapsed + AUDIO_GAIN_POLL_MS

                if not activeLoops[id] then break end -- StopK9Sound() ran while this thread was waiting

                local liveEntity = type(ResolveNetworkEntity) == 'function' and ResolveNetworkEntity(netId) or nil
                if not liveEntity then
                    -- Entity streamed out from under this client mid-loop
                    -- (e.g. the K9 went out of this client's own streaming
                    -- range) — stop cleanly rather than polling a distance
                    -- to nothing that would otherwise just silently stay
                    -- at its last-sent gain forever.
                    StopK9Sound(id)
                    break
                end

                SendNUIMessage({ action = 'audio:setGain', data = { id = id, gain = GainToEntity(liveEntity) } })
            end

            -- AUDIO_MAX_LOOP_MS safety-ceiling exit: if StopK9Sound was
            -- never called by anything, tell html/app.js to actually stop
            -- the audio too — this thread ending on its own must never
            -- leave a sound playing forever on the JS side with nothing
            -- left on the Lua side still tracking (and therefore able to
            -- stop) it.
            if activeLoops[id] then
                StopK9Sound(id)
            end
        end)
    end

    return id
end

--- Stops a sound previously started by PlayK9Sound. Only meaningful for a
--- loop=true call — a one-shot sound simply ends on its own once its own
--- buffer finishes playing (html/app.js's own onended handling), and
--- calling this against a one-shot (or already-ended, or never-started)
--- id is a harmless no-op both here and on the JS side (html/app.js treats
--- an 'audio:stop' for an id it has no active sound for as a no-op that
--- also defensively cancels that id's playback if it is still in the
--- middle of asynchronously loading — see that file's own comment).
--- @param id number
function StopK9Sound(id)
    activeLoops[id] = nil

    SendNUIMessage({ action = 'audio:stop', data = { id = id } })
end

--- (client/proximityaudio.lua, Config.Features.ProximityAudioFX) -- a pure
--- Lua-side query helper, NOT a new NUI message: it reads this file's own
--- private `activeLoops` bookkeeping table and sends nothing to
--- html/app.js, so it carries zero risk to the "payload shapes must match
--- byte-for-byte" contract that file's own header warns about. Exists
--- because AUDIO_MAX_LOOP_MS above (this file's own 60s safety ceiling)
--- can force-stop a long-lived loop out from under a caller that never
--- itself called StopK9Sound -- a caller managing a longer-than-60s
--- ambient effect (the realistic first real one: ProximityAudioFX's
--- continuous proximity loop) needs a way to notice that happened on its
--- OWN polling cadence and decide whether to re-issue a fresh PlayK9Sound
--- call to keep the effect going. Deliberately NOT an auto-renew mechanism
--- on this file's own side -- see AUDIO_MAX_LOOP_MS's own comment: a
--- caller bug should not silently become "loops forever" just because this
--- query helper exists; renewal, if any, is entirely the CALLER's
--- decision, made with fresh information each time.
--- @param id number an id previously returned by PlayK9Sound(..., {loop = true})
--- @return boolean active true if this file still considers `id` a live, tracked loop (not yet stopped, not yet past its own AUDIO_MAX_LOOP_MS ceiling)
function IsK9SoundActive(id)
    return activeLoops[id] == true
end
