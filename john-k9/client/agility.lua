--[[
    john-k9/client/agility.lua

    EXTRACTED FROM client/movement.lua: the ADVANCED AGILITY block below
    (Config.Features.AgilityAdvanced's fence/window vault approximation)
    used to live at the bottom of client/movement.lua. It was pulled out
    into its own file because, unlike every other concern that file owns
    (camera toggle, Sit self-emote, the two-player leash mechanic, the
    shared K9 move-rate composer, AgilityBasicJump's suppression thread,
    door interaction), this block:
      - shares NO local state with anything else in client/movement.lua
        (confirmed by reading the whole file before moving this — no local
        variable/function defined here is read outside this block, and
        nothing here reads a local defined outside it either);
      - has nothing else in this resource depending on it at all (confirmed
        by grep across the whole tree for AgilityAdvanced/TryVault/
        DetectVaultableObstacleHeight/john-k9:vault before moving this —
        the only other hits are comments/spec docs, not code);
      - is entirely self-contained top-to-bottom: its own config validation
        assert, its own tuning constants, its own shape-test sweep helper,
        its own command/keybind registration, all gated behind the same
        single `if Config.Features.AgilityAdvanced then` block.
    Everything else in client/movement.lua either shares state across
    sections (the leash pull-back thread and the door-interaction/vault
    canInteract checks all consult IsInK9Vehicle()/CanShowK9UI() the same
    way, and the move-rate composer is read by three OTHER files) or is
    woven into that file's own always-on threads (the camera/AgilityBasicJump
    onResourceStop handlers) — none of that is true here, which is why this
    one block was judged to genuinely stand alone while the rest of
    client/movement.lua was not split further. client/movement.lua's own
    header carries the same note for anyone arriving from that file first.

    Only the "this file"/"above"/"below" self-references inside the block's
    original comments were adjusted for accuracy in this new location (e.g.
    a comment that used to say "this file's own Config.DoorInteraction...
    assertion above" now says "client/movement.lua's own ... assertion",
    since that assertion lives in the other file now). No code, native call,
    constant, gating condition, or behavior was changed by this move.

    Depends on resource-globals defined elsewhere, all consumed via plain
    call (not a `type(fn) == 'function'` guard) because this resource's own
    fxmanifest.lua load-order convention already places client/main.lua
    before this file and CanShowK9UI()/IsOwnModelK9() are unconditionally
    defined there (unlike, say, IsInK9Vehicle() below, which IS guarded —
    see the inline comment at its one call site for why: client/vehicle.lua
    loading after this file in the manifest is the reason, not a change
    introduced by this extraction — the original code in client/movement.lua
    already guarded that exact same call the same way):
      - Config (config.lua, shared_scripts, loaded before every client
        script)
      - CanShowK9UI() (client/main.lua)
      - IsOwnModelK9() referenced only in this block's header commentary,
        not called by any code path here
      - IsInK9Vehicle() (client/vehicle.lua, soft/optional — guarded)
    Exposes no resource-global of its own: RegisterCommand/RegisterKeyMapping
    are this file's only two entry points, exactly as in the original
    location.
]]

-- ======================================================================
-- ADVANCED AGILITY -- fence/window vault approximation
-- (Config.Features.AgilityAdvanced). DEVELOPER_REFERENCE.md §12.5.5, §12.0 item 3
-- (DECIDED: capsule-sweep raycast, detectionMethod = 'raycast', as the
-- Phase 3 default), §12.1 sub-phase 3a ("independent, start immediately --
-- pure client-local own-body movement, does not touch target/combat logic
-- at all"), §12.3's file/module plan (originally assigned to
-- client/movement.lua's row: "Extends... AgilityAdvanced's vault trigger
-- and multi-height capsule-sweep detection" -- now this separate file, see
-- this file's own header above for why it was pulled out).
--
-- SCOPE NOTE, checked explicitly before writing this block: this feature
-- NEVER resolves, targets, or applies any effect to another ped/player --
-- it only reads world geometry (via a capsule shape-test sweep) and
-- repositions the K9's OWN ped. It is therefore entirely UNAFFECTED by
-- DEVELOPER_REFERENCE.md §12.0 item 8 (the still-open client-relay/
-- non-cooperating-target-client question), which only concerns effects a
-- K9 applies to a DIFFERENT entity (BiteAndHold / NonLethalTakedown /
-- PropDragging). Do not conflate this feature with those three just
-- because they share the same Phase 3 config table.
--
-- EVENT/CALLBACK CONTRACT: NONE. No TriggerServerEvent, no callback,
-- nothing server-authoritative touched anywhere in this block -- matches
-- DEVELOPER_REFERENCE.md §12.5.5's own "Event/callback contract: unchanged --
-- minimal, entirely client-local" framing exactly.
--
-- GATING CHOICE: gated on CanShowK9UI() (not just the cheap, local
-- IsOwnModelK9() check client/movement.lua's camera toggle/AgilityBasicJump
-- suppression use) -- this is a genuinely new, opt-in-by-default-off Phase 3
-- capability layered ON TOP of native locomotion, not baseline behavior
-- inherent to the ped model the way jump/crouch are. This matches every
-- other self-initiated GRANTED capability in client/movement.lua (K9Sit,
-- RequestLeashAttach), not the baseline-QoL camera/native-locomotion
-- carve-out client/main.lua's own OPEN QUESTION note documents.
-- ======================================================================
if Config.Features.AgilityAdvanced then
    -- CLAMP AND WARN, NOT ASSERT (see server/cooldowns.lua's header
    -- ADDENDUM: "does an operator's config.lua edit alone... reach this
    -- value? If yes it must be clamped and warned about, never asserted
    -- and aborted"). detectionMethod/maxVaultHeight/vaultCooldownMs below
    -- USED TO be one hard `assert` on detectionMethod alone (mirroring
    -- client/movement.lua's own Config.DoorInteraction.nudgeRequiresUnlocked
    -- precedent -- correct for THAT field, since a locked-door bypass has no
    -- safe substitute value, but wrong here) -- an uncaught error thrown from
    -- THIS BLOCK aborts client/agility.lua's remaining top-level execution
    -- from that line onward, since this `if` runs directly at file-load time
    -- with no deferring onResourceStart/RegisterNetEvent wrapper around it:
    -- the 'john-k9:vault' RegisterCommand near the bottom of this same
    -- block would silently never register, over one operator typo in a
    -- single string field. maxVaultHeight/vaultCooldownMs were previously
    -- read straight off Config with NO validation at all (a bad value there
    -- would not fail at load time -- it would throw or misbehave the first
    -- time a player actually attempted a vault, which is a worse, harder to
    -- diagnose failure mode than either an assert or a warning).
    -- Resolved values are written BACK into Config.Combat.AgilityAdvanced
    -- (not copied into a disconnected local table) so `agilityCfg` stays an
    -- alias into the real Config path below -- preserving this file's
    -- existing "read live via field access at TryVault()-call time, never
    -- captured by value" property (see this file's own header and this
    -- spec's fixture comment) for maxVaultHeight/vaultCooldownMs, exactly
    -- as it worked before this guard existed.
    if type(Config.Combat) ~= 'table' then
        Config.Combat = {}
    end
    if type(Config.Combat.AgilityAdvanced) ~= 'table' then
        print(
            '[John-K9] WARNING: Config.Features.AgilityAdvanced is true but Config.Combat.AgilityAdvanced ' ..
            'is missing or not a table -- using this file\'s own built-in defaults (detectionMethod=\'raycast\', ' ..
            'maxVaultHeight=1.2, vaultCooldownMs=2000) so the vault command still registers. Add the ' ..
            'Config.Combat.AgilityAdvanced settings table back to config.lua.'
        )
        Config.Combat.AgilityAdvanced = {}
    end
    local agilityCfg = Config.Combat.AgilityAdvanced

    if agilityCfg.detectionMethod ~= 'raycast' then
        -- DEVELOPER_REFERENCE.md §12.2/§12.5.5 document 'taggedProp' as a
        -- theoretical per-server override SHAPE, but no such detection path
        -- is built in this codebase.
        print(
            ("[John-K9] WARNING: Config.Combat.AgilityAdvanced.detectionMethod = '%s' is not implemented -- " ..
             "only 'raycast' (the DEVELOPER_REFERENCE.md §12.0 item 3 Phase 3 default, a multi-height capsule " ..
             "sweep) is built in client/agility.lua. Using 'raycast' for this session instead of refusing to " ..
             "load -- set Config.Combat.AgilityAdvanced.detectionMethod back to 'raycast' in config.lua, or " ..
             "implement the 'taggedProp' path with a reviewed code change."):format(tostring(agilityCfg.detectionMethod))
        )
        agilityCfg.detectionMethod = 'raycast'
    end

    if not (type(agilityCfg.maxVaultHeight) == 'number' and agilityCfg.maxVaultHeight == agilityCfg.maxVaultHeight and agilityCfg.maxVaultHeight > 0) then
        print(
            ('[John-K9] Config.Combat.AgilityAdvanced.maxVaultHeight must be a positive number of meters ' ..
             '(found: %s). Using the built-in fallback of 1.2 instead so this feature keeps working while the ' ..
             'config is fixed.'):format(tostring(agilityCfg.maxVaultHeight))
        )
        agilityCfg.maxVaultHeight = 1.2
    end

    -- vaultCooldownMs IS a genuine cooldown threshold (compared against
    -- below with `< agilityCfg.vaultCooldownMs`) -- 0/negative here would
    -- make every vault attempt read as "always past cooldown" (elapsed >= 0
    -- is never < 0), the OPPOSITE of server/cooldowns.lua's own documented
    -- fail-closed convention for a threshold of this shape, so it gets the
    -- same positive-number floor as every *CooldownMs field in config.lua.
    if not (type(agilityCfg.vaultCooldownMs) == 'number' and agilityCfg.vaultCooldownMs == agilityCfg.vaultCooldownMs and agilityCfg.vaultCooldownMs > 0) then
        print(
            ('[John-K9] Config.Combat.AgilityAdvanced.vaultCooldownMs must be a positive number of ' ..
             'milliseconds (found: %s). Using the built-in fallback of 2000 instead so this feature keeps ' ..
             'working while the config is fixed.'):format(tostring(agilityCfg.vaultCooldownMs))
        )
        agilityCfg.vaultCooldownMs = 2000
    end

    -- Capsule-sweep TUNING CONSTANTS -- deliberately plain local constants,
    -- NOT promoted into config.lua, because DEVELOPER_REFERENCE.md §12.5.5's own
    -- "Open questions" list names the exact height bands/capsule radius/
    -- forward distance as in-engine TUNING work still to be done against
    -- real map geometry, not a settled design choice -- promoting untested
    -- numbers into a server-owner-facing config table would imply a
    -- confidence this file doesn't have yet. Revisit alongside
    -- maxVaultHeight/vaultCooldownMs once an in-engine tuning pass happens.
    local SWEEP_FORWARD_DISTANCE = 1.0                  -- meters ahead of the K9 to sweep toward
    local SWEEP_CAPSULE_RADIUS = 0.25                   -- meters, capsule thickness
    local SWEEP_HEIGHT_BANDS = { 0.3, 0.6, 0.9, 1.2 }   -- meters above the K9's own feet, each swept independently (see DetectVaultableObstacleHeight below for why one sweep per band, not one sweep total)
    -- Shape-test intersect flag bit for "world/map geometry only" (not
    -- peds/vehicles/objects) -- CONFIDENCE: MEDIUM. This is the
    -- widely-used ecosystem convention for START_SHAPE_TEST_*'s flags
    -- argument (bit 1 = IntersectMap), but unlike StartShapeTestCapsule/
    -- GetShapeTestResult's own hash/signature (HIGH confidence, verified
    -- directly against raw.githubusercontent.com/citizenfx/natives per
    -- DEVELOPER_REFERENCE.md#phase-3-combat §5), the exact flag-bit
    -- MEANINGS were not independently re-verified against that same
    -- canonical source this session -- if the sweep reports hits against
    -- unexpected entity types (or misses static fences/walls) in testing,
    -- this is the first value to have native-api-assistant re-confirm.
    local SHAPE_TEST_FLAG_INTERSECT_MAP = 1

    -- Bug fix: the polling loop below used to have no upper bound at all --
    -- if GET_SHAPE_TEST_RESULT ever kept returning 1 ("still processing")
    -- forever for a given handle (a stuck/leaked handle, or any other
    -- engine-side edge case that never resolves), TryVault() would hang in
    -- that coroutine permanently, once per height band, since nothing else
    -- in this function can make progress until the `repeat` loop below
    -- exits. A real capsule sweep against static world geometry is expected
    -- to resolve within a frame or two (see the loop's own comment), so a
    -- generous-but-bounded cap catches only the genuinely-stuck case, not a
    -- normal-but-slightly-slow one. Treated as "no hit" for that band on
    -- timeout, the same silent fallback this function already uses for a
    -- band that legitimately reports no hit -- consistent with this file's
    -- "cooldown/no-obstacle branches are silent, not notification spam"
    -- posture elsewhere.
    local SHAPE_TEST_MAX_POLLS = 60

    --- Multi-height capsule sweep: fires one shape test per configured
    --- height band, forward from the K9's current position, and returns
    --- the TALLEST band that still reports a hit as this obstacle's
    --- approximate climbable height. A single capsule sweep only reports
    --- "hit or not" for the exact line it was cast along -- it doesn't by
    --- itself tell you how tall the thing it hit is -- so sweeping several
    --- level bands and taking the tallest one that still connects
    --- approximates "solid up to at least this height," which is the
    --- actual question `maxVaultHeight` needs answered (distinguishing a
    --- low curb from a full wall).
    ---
    --- CONFIDENCE: the underlying natives are HIGH confidence (see above).
    --- This specific multi-band-sweep ALGORITHM built on top of them is
    --- this file's own construction, not verified in-engine this session --
    --- exactly the "in-engine tuning... against real map geometry"
    --- DEVELOPER_REFERENCE.md §12.5.5 already lists as open, unresolved TUNING
    --- work, not a design fork. Treat the returned height as an
    --- approximation to be validated against real fences/windows in
    --- testing, not a precise measurement.
    ---
    --- NON-NEGOTIABLE (per this resource's fxmanifest.lua `lua54` +
    --- `use_experimental_fxv2_oal` combination): this call reads ONLY
    --- resultCode and hit from GetShapeTestResult below -- never
    --- endCoords/surfaceNormal, the vector returns reported broken by that
    --- combination on some builds. Do not add a read of either vector
    --- return here without re-verifying that known issue against the build
    --- in use FIRST -- see fxmanifest.lua's own comment on this exact call
    --- for the full warning to a future editor.
    --- @param ped number
    --- @return number obstacleHeight -- 0.0 if nothing detected in any band
    local function DetectVaultableObstacleHeight(ped)
        local pedCoords = GetEntityCoords(ped)
        local forward = GetEntityForwardVector(ped)
        local tallestHit = 0.0

        for _, height in ipairs(SWEEP_HEIGHT_BANDS) do
            -- Level sweep at THIS band's height -- start and end share the
            -- same Z, forward.z is deliberately never applied to either
            -- endpoint, so every band stays level regardless of the K9's
            -- current ground pitch/slope.
            local startX, startY, startZ = pedCoords.x, pedCoords.y, pedCoords.z + height
            local endX = startX + forward.x * SWEEP_FORWARD_DISTANCE
            local endY = startY + forward.y * SWEEP_FORWARD_DISTANCE

            local shapeTestHandle = StartShapeTestCapsule(
                startX, startY, startZ, endX, endY, startZ,
                SWEEP_CAPSULE_RADIUS, SHAPE_TEST_FLAG_INTERSECT_MAP, ped, 0
            )

            -- GET_SHAPE_TEST_RESULT's own documented contract (confirmed,
            -- DEVELOPER_REFERENCE.md#phase-3-combat §5): poll until it
            -- returns 0 (invalid handle) or 2 (complete) -- 1 means "still
            -- processing," NOT a single guaranteed-synchronous call. A
            -- capsule sweep this short against static world geometry
            -- typically resolves within the same or next frame, but this
            -- loop does not assume that -- it keeps polling (yielding a
            -- frame between attempts) until the handle itself reports done.
            local resultCode, hit
            local pollCount = 0
            repeat
                resultCode, hit = GetShapeTestResult(shapeTestHandle)
                if resultCode == 1 then
                    pollCount = pollCount + 1
                    Wait(0)
                end
            until resultCode ~= 1 or pollCount >= SHAPE_TEST_MAX_POLLS

            if resultCode == 2 and hit then
                tallestHit = height
            end
            -- resultCode == 1 here means SHAPE_TEST_MAX_POLLS was reached
            -- without the handle ever resolving -- treated identically to
            -- "no hit this band" (see SHAPE_TEST_MAX_POLLS's own comment
            -- above), not an error.
        end

        return tallestHit
    end

    local lastVaultAt = -math.huge -- GetGameTimer()-scale; never on cooldown for the very first attempt

    -- Bug fix: TryVault() had no re-entrancy guard around its own async
    -- obstacle-detection sweep. DetectVaultableObstacleHeight below can
    -- yield at Wait(0) one or more times (whenever GET_SHAPE_TEST_RESULT
    -- reports "still processing" -- see that function's own comment: this
    -- is not guaranteed synchronous even for a short capsule sweep).
    -- `lastVaultAt` was only ever updated AFTER that async sweep returned,
    -- so a SECOND TryVault() invocation reaching this function while the
    -- FIRST one's sweep was still in flight (a keybind double-press/
    -- auto-repeat, or two inputs landing in the same or adjacent frame)
    -- passed the cooldown check against the STILL-STALE `lastVaultAt` and
    -- ran its own independent, fully overlapping detection sweep. If both
    -- calls detected the same obstacle, both called SetEntityVelocity,
    -- stacking a second re-launch impulse on top of the first from what the
    -- player experienced as a single vault attempt (and doubling the
    -- shape-test native call volume for that press). This flag closes that
    -- window: a second call arriving while a sweep is already in flight is
    -- rejected outright, silently, same posture as the cooldown/
    -- no-obstacle branches above and below.
    local vaultInProgress = false

    --- Shared implementation behind the vault keybind below. Re-checks
    --- access/cooldown/obstacle every call -- there is no separate
    --- "canInteract"-style predicate for a keybind the way ox_target
    --- options in client/movement.lua get one, so all of that lives
    --- directly here.
    local function TryVault()
        if not CanShowK9UI() then
            DenyK9UIAccess()
            return
        end

        -- Per-person block (client/featureblocks.lua -- see that file's
        -- header for the full contract). A vault is a single one-shot
        -- action with no held/persistent state (unlike Leash/Bite & Hold/
        -- Drag above it in this file's sibling files) -- there is no
        -- release/termination branch here for this check to ever risk
        -- gating. `type(...) == 'function'` guard: fails open (never
        -- blocked) if client/featureblocks.lua has not loaded.
        if type(IsK9FeatureBlocked) == 'function' and IsK9FeatureBlocked('AgilityAdvanced') then
            if type(DenyK9FeatureBlocked) == 'function' then DenyK9FeatureBlocked() end
            return
        end

        local now = GetGameTimer()
        if (now - lastVaultAt) < agilityCfg.vaultCooldownMs then
            return -- silent -- a cooldown-rejected keypress retry isn't worth a notification every time, mirrors client/movement.lua's AgilityBasicJump's own no-notification-spam posture
        end

        local ped = PlayerPedId()
        if IsPedInAnyVehicle(ped, false) or (IsInK9Vehicle and IsInK9Vehicle()) then
            return -- nothing to vault over while seated/tucked, same exclusion client/movement.lua's leash pull-back thread and door-interaction options already apply for this exact state
        end

        if vaultInProgress then
            return -- a previous TryVault() call's own async obstacle-detection sweep (see vaultInProgress's own comment above) hasn't finished yet -- silent, same posture as every other rejection branch here
        end
        vaultInProgress = true

        local obstacleHeight = DetectVaultableObstacleHeight(ped)
        if obstacleHeight <= 0.0 or obstacleHeight > agilityCfg.maxVaultHeight then
            vaultInProgress = false
            return -- nothing vaultable detected in range, or it's taller than configured -- silent, same reasoning as the cooldown branch above
        end

        lastVaultAt = now

        -- Scripted arc over the detected obstacle. DEVELOPER_REFERENCE.md
        -- §12.5.5's own wording correction applies here: there is no
        -- dedicated ped "jump" TASK native (confirmed absent,
        -- DEVELOPER_REFERENCE.md#phase-3-combat §5) -- this arc is driven
        -- directly via SET_ENTITY_VELOCITY (confirmed real,
        -- 0x1C99BB7B6E96D16F, HIGH confidence), an upward+forward impulse
        -- scaled by the detected obstacle's height, not a task/input
        -- simulation layered on native jump.
        --
        -- CONFIDENCE on the arc feel itself (verticalSpeed/forwardSpeed
        -- formula below): LOW/UNTUNED -- this is a first-pass placeholder
        -- shape, not derived from any confirmed source, and is exactly the
        -- kind of "in-engine tuning against real map geometry" work
        -- DEVELOPER_REFERENCE.md §12.5.5 already flags as open. Revisit after an
        -- in-engine pass, same as the sweep tuning constants above.
        --
        -- REVIEWED (still not fixable without a live client -- both
        -- findings below require eyes on an actual vault against real map
        -- geometry, not more reading):
        --   1. Dimensionally sane, by rough projectile-motion arithmetic
        --      (peak height h = v^2/(2g), using GTA's approximate default
        --      gravity of ~9.8 units/s^2 at gravity level 0 -- an
        --      approximation, not a native-confirmed constant, since
        --      gravity is an engine-level physics value, not something a
        --      script native documents): at the smallest detectable
        --      obstacle (obstacleHeight just above 0), verticalSpeed=4.0
        --      gives a ~0.8m apex -- comfortably clears it. At
        --      Config.Combat.AgilityAdvanced.maxVaultHeight (1.2m, itself
        --      UNTUNED per config.lua's own comment), verticalSpeed=6.4
        --      gives a ~2.1m apex and, at forwardSpeed=3.5, roughly 4.5m of
        --      forward travel over the full arc -- clears a 1.2m obstacle
        --      with a lot of room to spare, which reads more like a
        --      superhero leap than a fence vault. This is the first thing
        --      to look at in an in-engine pass: forwardSpeed likely needs
        --      to scale down (or verticalSpeed's multiplier scale down)
        --      for the taller end of the configured height range, not stay
        --      flat across the whole band.
        --   2. FIXED: SetEntityVelocity SETS the ped's velocity outright
        --      (it does not add to whatever velocity the ped already had --
        --      this is the established, widely-relied-upon behavior of
        --      this native across the FiveM ecosystem, not something this
        --      file invents). A K9 already sprinting faster than the flat
        --      3.5 units/s constant this used to hardcode would have its
        --      actual forward momentum REPLACED by that constant the
        --      instant it vaulted -- a visible snap/deceleration exactly at
        --      takeoff, the single most common way a player would ever
        --      brush against this feature (sprint at a fence, vault it),
        --      rather than a smooth leap that carries the sprint through.
        --      GetEntitySpeed(ped) (GET_ENTITY_SPEED, 0xB2D8994DBB3E68C1 --
        --      PED/ENTITY-namespace native returning the entity's current
        --      speed magnitude in m/s; added to the repo-root
        --      .luacheckrc read_globals for this) is read once, right
        --      here, and floored into the forward-impulse magnitude below
        --      so a vault can only ever match-or-exceed the K9's own
        --      current speed, never go slower than it was already moving.
        --      Reads the ped's TOTAL 3D speed (would include a vertical
        --      component if the K9 were already airborne/falling) rather
        --      than a horizontal-only projection -- an acceptable
        --      approximation for this call site specifically, since
        --      TryVault() above already refuses to reach this point while
        --      seated/tucked in a vehicle, and a grounded sprinting K9's
        --      vertical velocity component is negligible. The vertical arc
        --      height (verticalSpeed below) is UNCHANGED by this fix --
        --      still scaled only from the detected obstacle's height, per
        --      finding 1 above, which this does not touch. Still
        --      UNTUNED/first-pass on the absolute numbers (both findings
        --      share that same open, in-engine-pass caveat) -- this only
        --      fixes the "goes SLOWER than the K9 already was" direction of
        --      the problem, not the overall arc feel.
        local forward = GetEntityForwardVector(ped)
        local verticalSpeed = 4.0 + obstacleHeight * 2.0 -- taller obstacle -> slightly higher arc
        local forwardSpeed = math.max(3.5, GetEntitySpeed(ped))
        SetEntityVelocity(ped, forward.x * forwardSpeed, forward.y * forwardSpeed, verticalSpeed)

        vaultInProgress = false
    end

    RegisterCommand('john-k9:vault', function()
        -- KEYBIND SILENCE GATE (live-bug fix) -- a keypress carries no
        -- evidence that a K9 action was intended, so a player who is not a K9
        -- gets nothing at all instead of a refusal toast. See
        -- IsK9KeybindAudience() in client/main.lua for the full writeup of the
        -- city-wide toast spam this closes.
        if not IsK9KeybindAudience() then return end

        TryVault()
    end, false)

    RegisterKeyMapping('john-k9:vault', locale('agility.vault_keybind_label'), 'keyboard', 'X')
end
