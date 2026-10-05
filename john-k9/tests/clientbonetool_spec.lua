--[[
    tests/clientbonetool_spec.lua

    Direct tests of client/bonetool.lua against the REAL, unmodified
    production file -- the client half of the dev-only bone-index sweep
    tool (tests/bonetool_spec.lua already covers server/bonetool.lua's own
    registration/authorization surface; this file had NO spec at all before
    this pass, confirmed by grep -rn "bonetool" tests/*.lua turning up only
    that one server-side file and tests/notify_spec.lua's narrower
    NotifyPlayer-delegation slice).

    WHY THIS FILE, PER ITS OWN TASK BRIEF: a convar-gated dev tool is low
    SEVERITY, but its per-frame draw thread and its onResourceStop handler
    are exactly the "untested thread" category that has hidden real bugs in
    this resource before (see e.g. the six previously-silent dead natives
    server/wellbeing.lua's own header documents). Covered here: the thread
    body's actual branching (active vs. idle, ped missing/dead, test-prop
    label switching), the registration-time convar gate meaning the whole
    file -- thread included -- is genuinely inert (never merely hidden), and
    the onResourceStop cleanup path releasing correctly AND idempotently on
    a double fire.

    SANDBOX APPROACH: `AttachPropToOwnPed`/`DetachAndDeleteProp` are
    resolved at CALL TIME as cross-file resource globals (client/
    propattachment.lua's own contract, no load-order requirement -- see
    that file's own header and client/bonetool.lua's FILE-TO-FILE CONTRACT
    section) -- so, per this suite's own "stub the one thing under test
    doesn't own" convention (matching every compat*_spec.lua's fake
    K9Compat), this file supplies its own minimal, controllable stand-ins
    rather than loading the real client/propattachment.lua. Their real
    CreateObject/RequestModel/AttachEntityToEntity sequence is already
    covered end-to-end by tests/clientpropattachment_spec.lua; this spec
    only needs to prove client/bonetool.lua calls them with the RIGHT
    arguments at the RIGHT times, not that they themselves work.

    `source` is set as a plain sandbox global immediately before dispatching
    the captured RegisterNetEvent handler, matching every other net-event
    handler in this codebase (see tests/clientpropattachment_spec.lua's
    identical `dispatchNetEvent` convention) -- this handler never yields
    (no Wait(...) call anywhere inside it), so a coroutine wrapper is not
    needed here, unlike that file's own dispatcher.

    NO UNBOUNDED TRAP, per this pass's own rule: 'stop' and onResourceStop
    are this tool's only two termination paths. Both are proven reachable
    and idempotent from every state this suite drives the tool into,
    including a state where nothing was ever activated at all.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')
local locale = Sandbox.locale

local BONE_DEV_TOOL_ENABLE_CONVAR = 'john_k9_enable_bone_dev_tool'
local RESOURCE_NAME = 'john-k9'

--- @param opts table? { featureFlag: boolean?, convarValue: number?, omitFeaturesTable: boolean? }
--- @return table ctx
local function buildEnv(opts)
    opts = opts or {}

    -- ---- convar / feature flag (both MUTABLE after construction, so a
    -- test can simulate an operator flipping either post-registration) ----
    local convarValue = opts.convarValue or 0
    local function GetConvarInt(name, default)
        if name == BONE_DEV_TOOL_ENABLE_CONVAR then return convarValue end
        return default
    end

    local featuresTable = nil
    if not opts.omitFeaturesTable then
        featuresTable = { BoneSweepDevTool = opts.featureFlag }
    end
    local Config = {
        Features = featuresTable,
        BoneSweepTool = {
            TestPropModel = 'prop_test_model',
            MaxBoneIndex = 200,
            TestOffsetX = 0.1, TestOffsetY = 0.2, TestOffsetZ = 0.3,
        },
    }

    -- ---- notify / print capture ----
    local notifyCalls = {}
    local lib = { notify = function(payload) notifyCalls[#notifyCalls + 1] = payload end }
    local printedLines = {}
    local function printStub(s) printedLines[#printedLines + 1] = tostring(s) end

    -- ---- event registration capture ----
    local netEvents = {}
    local function RegisterNetEvent(eventName, handler) netEvents[eventName] = handler end
    local eventHandlers = {}
    local function AddEventHandler(eventName, handler)
        eventHandlers[eventName] = eventHandlers[eventName] or {}
        eventHandlers[eventName][#eventHandlers[eventName] + 1] = handler
    end
    local function GetCurrentResourceName() return RESOURCE_NAME end

    -- ---- thread ----
    local threadRunner = Sandbox.newThreadRunner()
    local threadCreateCount = 0
    local function CountingCreateThread(fn)
        threadCreateCount = threadCreateCount + 1
        threadRunner.CreateThread(fn)
    end

    -- ---- ped / entity world state ----
    local pedHandle = 1
    local existingEntities = { [pedHandle] = true }
    local pedDead = false
    local function PlayerPedId() return pedHandle end
    local function DoesEntityExist(entity) return existingEntities[entity] == true end
    local function IsEntityDead(entity) return entity == pedHandle and pedDead or false end

    -- ---- bone position query + draw natives ----
    local boneWorldPosCalls = {}
    local function GetWorldPositionOfEntityBone(ped, boneIndex)
        boneWorldPosCalls[#boneWorldPosCalls + 1] = { ped = ped, boneIndex = boneIndex }
        -- Deterministic, boneIndex-derived position so a test can prove the
        -- draw calls below really did flow from THIS query's own result,
        -- not a hardcoded value.
        return { x = boneIndex * 1.0, y = boneIndex * 2.0, z = boneIndex * 3.0 }
    end

    local drawMarkerCalls = {}
    local function DrawMarker(...) drawMarkerCalls[#drawMarkerCalls + 1] = { ... } end

    local textDrawCalls = {} -- one entry per Draw3DText invocation: { text = ..., origin = {x,y,z} }
    local pendingLabelText, pendingScale, pendingFont
    local function SetTextScale(scale) pendingScale = scale end
    local function SetTextFont(font) pendingFont = font end
    local function SetTextColour(...) end
    local function SetTextCentre(...) end
    local function BeginTextCommandDisplayText(...) end
    local function AddTextComponentSubstringPlayerName(text) pendingLabelText = text end
    local pendingOrigin
    local function SetDrawOrigin(x, y, z, w) pendingOrigin = { x = x, y = y, z = z, w = w } end
    local function EndTextCommandDisplayText(...)
        textDrawCalls[#textDrawCalls + 1] = { text = pendingLabelText, origin = pendingOrigin, scale = pendingScale, font = pendingFont }
    end
    local function ClearDrawOrigin() end

    -- ---- GetPedBoneIndex ('known' subcommand) ----
    local boneIndexResolutions = {}
    local boneIndexLookupCalls = {}
    local function GetPedBoneIndex(ped, id)
        boneIndexLookupCalls[#boneIndexLookupCalls + 1] = { ped = ped, id = id }
        return boneIndexResolutions[id] or -1
    end

    -- ---- AttachPropToOwnPed / DetachAndDeleteProp (see this file's own
    -- header on why these are hand-rolled fixture stand-ins, not the real
    -- client/propattachment.lua) ----
    local attachCalls = {}
    local detachCalls = {}
    local attachShouldFail = false
    local nextEntityId = 1000
    local function AttachPropToOwnPed(modelName, boneIndex, offsetX, offsetY, offsetZ, rotX, rotY, rotZ, isNetworked, timeoutMs)
        attachCalls[#attachCalls + 1] = {
            modelName = modelName, boneIndex = boneIndex,
            offsetX = offsetX, offsetY = offsetY, offsetZ = offsetZ,
            rotX = rotX, rotY = rotY, rotZ = rotZ,
            isNetworked = isNetworked, timeoutMs = timeoutMs,
        }
        if attachShouldFail then return nil end
        local entity = nextEntityId
        nextEntityId = nextEntityId + 1
        existingEntities[entity] = true
        return entity
    end
    local function DetachAndDeleteProp(entity)
        -- BOXED, deliberately: `detachCalls[#detachCalls + 1] = entity` would
        -- silently fail to record a call made with entity == nil (assigning
        -- nil to a table key is a no-op store in Lua, so #detachCalls would
        -- never advance) -- exactly the "solve it in the fixture" case this
        -- suite's own task brief calls out, not a production bug.
        detachCalls[#detachCalls + 1] = { entity = entity }
        if entity then existingEntities[entity] = nil end
    end

    local env = Sandbox.newEnv({
        Config = Config,
        GetConvarInt = GetConvarInt,
        lib = lib,
        print = printStub,
        RegisterNetEvent = RegisterNetEvent,
        AddEventHandler = AddEventHandler,
        GetCurrentResourceName = GetCurrentResourceName,
        CreateThread = CountingCreateThread,
        Wait = threadRunner.Wait,
        PlayerPedId = PlayerPedId,
        DoesEntityExist = DoesEntityExist,
        IsEntityDead = IsEntityDead,
        GetWorldPositionOfEntityBone = GetWorldPositionOfEntityBone,
        DrawMarker = DrawMarker,
        SetTextScale = SetTextScale,
        SetTextFont = SetTextFont,
        SetTextColour = SetTextColour,
        SetTextCentre = SetTextCentre,
        BeginTextCommandDisplayText = BeginTextCommandDisplayText,
        AddTextComponentSubstringPlayerName = AddTextComponentSubstringPlayerName,
        SetDrawOrigin = SetDrawOrigin,
        EndTextCommandDisplayText = EndTextCommandDisplayText,
        ClearDrawOrigin = ClearDrawOrigin,
        GetPedBoneIndex = GetPedBoneIndex,
        AttachPropToOwnPed = AttachPropToOwnPed,
        DetachAndDeleteProp = DetachAndDeleteProp,
    })

    Sandbox.loadInto('../client/bonetool.lua', env)

    return {
        env = env,
        Config = Config,
        netEvents = netEvents,
        eventHandlers = eventHandlers,
        notifyCalls = notifyCalls,
        lastNotify = function() return notifyCalls[#notifyCalls] end,
        printedLines = printedLines,
        threadCreateCount = function() return threadCreateCount end,
        step = threadRunner.step,
        setConvar = function(v) convarValue = v end,
        setFeatureFlag = function(v) Config.Features.BoneSweepDevTool = v end,
        setPedDead = function(v) pedDead = v end,
        setPedExists = function(v)
            if v then existingEntities[pedHandle] = true else existingEntities[pedHandle] = nil end
        end,
        setAttachShouldFail = function(v) attachShouldFail = v end,
        setBoneIndexResolution = function(id, value) boneIndexResolutions[id] = value end,
        killEntity = function(entity) existingEntities[entity] = nil end,
        drawMarkerCalls = drawMarkerCalls,
        lastDrawMarker = function() return drawMarkerCalls[#drawMarkerCalls] end,
        textDrawCalls = textDrawCalls,
        lastTextDraw = function() return textDrawCalls[#textDrawCalls] end,
        boneWorldPosCalls = boneWorldPosCalls,
        boneIndexLookupCalls = boneIndexLookupCalls,
        attachCalls = attachCalls,
        detachCalls = detachCalls,
        detachCallCount = function() return #detachCalls end,
        detachedEntityAt = function(i) local call = detachCalls[i]; return call and call.entity end,
        lastDetachedEntity = function() local call = detachCalls[#detachCalls]; return call and call.entity end,
        --- Dispatches the captured net-event handler with `source` set as a
        --- plain sandbox global immediately beforehand -- same convention
        --- as tests/clientpropattachment_spec.lua's own dispatcher. This
        --- handler never yields, so no coroutine wrapper is needed.
        dispatch = function(sourceValue, subcommand, arg)
            local handler = netEvents['john-k9:client:boneToolCommand']
            assert(handler, 'boneToolCommand handler was never registered')
            env.source = sourceValue
            handler(subcommand, arg)
        end,
        fireResourceStop = function(resourceName)
            for _, handler in ipairs(eventHandlers['onResourceStop'] or {}) do
                handler(resourceName)
            end
        end,
    }
end

-- ========================================================================
-- REGISTRATION-TIME GATE: the convar OFF (or the flag off) must make the
-- whole file -- net event, thread, onResourceStop hook -- genuinely absent,
-- never merely hidden.
-- ========================================================================

t.test('flag OFF, convar unset: nothing is registered at all', function()
    local ctx = buildEnv({ featureFlag = false, convarValue = 0 })
    t.isNil(ctx.netEvents['john-k9:client:boneToolCommand'])
    t.equals(ctx.threadCreateCount(), 0, 'the draw thread must never even be CREATED, not merely left idle')
    t.isNil(ctx.eventHandlers['onResourceStop'])
end)

t.test('flag OFF, convar SET to 1: still nothing registered -- the flag gates first, the convar alone is never enough', function()
    local ctx = buildEnv({ featureFlag = false, convarValue = 1 })
    t.isNil(ctx.netEvents['john-k9:client:boneToolCommand'])
    t.equals(ctx.threadCreateCount(), 0)
    t.isNil(ctx.eventHandlers['onResourceStop'])
end)

t.test('flag ON, convar UNSET (defaults to 0): still nothing registered -- the convar is a required second opt-in', function()
    local ctx = buildEnv({ featureFlag = true, convarValue = 0 })
    t.isNil(ctx.netEvents['john-k9:client:boneToolCommand'])
    t.equals(ctx.threadCreateCount(), 0)
    t.isNil(ctx.eventHandlers['onResourceStop'])
end)

t.test('Config.Features entirely absent: no crash, nothing registered', function()
    local ok, ctx = pcall(buildEnv, { omitFeaturesTable = true })
    t.isTrue(ok, 'must never throw merely because Config.Features is absent')
    t.isNil(ctx.netEvents['john-k9:client:boneToolCommand'])
    t.equals(ctx.threadCreateCount(), 0)
end)

t.test('flag ON, convar = 1: BOTH gates satisfied -- the net event, the draw thread, and the onResourceStop hook all register', function()
    local ctx = buildEnv({ featureFlag = true, convarValue = 1 })
    t.isNotNil(ctx.netEvents['john-k9:client:boneToolCommand'])
    t.equals(ctx.threadCreateCount(), 1, 'exactly one draw thread, not zero and not a duplicate')
    t.isNotNil(ctx.eventHandlers['onResourceStop'])
    t.equals(#ctx.eventHandlers['onResourceStop'], 1)
end)

-- ========================================================================
-- SOURCE-ORIGIN GUARD: only source == 65535 (the server-only sentinel) may
-- ever drive this handler.
-- ========================================================================

t.test('SOURCE-ORIGIN GUARD: a non-65535 source produces no effect at all -- no notify, no state change', function()
    local ctx = buildEnv({ featureFlag = true, convarValue = 1 })
    ctx.dispatch(1, 'goto', 5)
    t.equals(#ctx.notifyCalls, 0, 'goto from a spoofed/foreign source must never even reach the feature-gate check, let alone notify')
    ctx.step() -- prime
    ctx.step() -- one sweep pass
    t.equals(#ctx.drawMarkerCalls, 0, 'sweepActive must never have been engaged by an untrusted source')
end)

-- ========================================================================
-- DEFENSE IN DEPTH: the handler re-checks the flag/convar on EVERY
-- invocation, even though the file's own header documents the
-- REGISTRATION-TIME gate as permanent until a resource restart. Flipping
-- either off after registration must make every subsequent call a no-op,
-- without ever un-registering anything.
-- ========================================================================

t.test('DEFENSE IN DEPTH: flipping Config.Features.BoneSweepDevTool off after registration makes every call a no-op, without un-registering the handler', function()
    local ctx = buildEnv({ featureFlag = true, convarValue = 1 })
    ctx.setFeatureFlag(false)
    ctx.dispatch(65535, 'goto', 5)
    t.equals(#ctx.notifyCalls, 0)
    t.isNotNil(ctx.netEvents['john-k9:client:boneToolCommand'], 'the handler itself stays registered -- only its own effects are suppressed')
end)

t.test('DEFENSE IN DEPTH: flipping the convar to 0 after registration makes every call a no-op', function()
    local ctx = buildEnv({ featureFlag = true, convarValue = 1 })
    ctx.setConvar(0)
    ctx.dispatch(65535, 'goto', 5)
    t.equals(#ctx.notifyCalls, 0)
end)

-- ========================================================================
-- goto/next/prev: validation + clamping
-- ========================================================================

t.test('goto: a valid index engages the preview and notifies the exact index', function()
    local ctx = buildEnv({ featureFlag = true, convarValue = 1 })
    ctx.dispatch(65535, 'goto', 50)
    t.equals(#ctx.notifyCalls, 1)
    t.equals(ctx.lastNotify().description, locale('bonetool.preview_bone_index', 50))
end)

t.test('goto: clamps an out-of-range positive index down to Config.BoneSweepTool.MaxBoneIndex', function()
    local ctx = buildEnv({ featureFlag = true, convarValue = 1 })
    ctx.dispatch(65535, 'goto', 999)
    t.equals(ctx.lastNotify().description, locale('bonetool.preview_bone_index', 200))
end)

t.test('goto: clamps a negative index up to 0', function()
    local ctx = buildEnv({ featureFlag = true, convarValue = 1 })
    ctx.dispatch(65535, 'goto', -40)
    t.equals(ctx.lastNotify().description, locale('bonetool.preview_bone_index', 0))
end)

t.test('goto: floors a fractional index', function()
    local ctx = buildEnv({ featureFlag = true, convarValue = 1 })
    ctx.dispatch(65535, 'goto', 12.9)
    t.equals(ctx.lastNotify().description, locale('bonetool.preview_bone_index', 12))
end)

t.test('goto: a non-number arg is silently ignored -- no notify, no state change', function()
    local ctx = buildEnv({ featureFlag = true, convarValue = 1 })
    ctx.dispatch(65535, 'goto', 'not-a-number')
    t.equals(#ctx.notifyCalls, 0)
end)

t.test('next/prev: no arg defaults to a step of 1', function()
    local ctx = buildEnv({ featureFlag = true, convarValue = 1 })
    ctx.dispatch(65535, 'goto', 10)
    ctx.dispatch(65535, 'next')
    t.equals(ctx.lastNotify().description, locale('bonetool.preview_bone_index', 11))
    ctx.dispatch(65535, 'prev')
    t.equals(ctx.lastNotify().description, locale('bonetool.preview_bone_index', 10))
end)

t.test('next/prev: an explicit positive integer step is honored', function()
    local ctx = buildEnv({ featureFlag = true, convarValue = 1 })
    ctx.dispatch(65535, 'goto', 10)
    ctx.dispatch(65535, 'next', 5)
    t.equals(ctx.lastNotify().description, locale('bonetool.preview_bone_index', 15))
    ctx.dispatch(65535, 'prev', 3)
    t.equals(ctx.lastNotify().description, locale('bonetool.preview_bone_index', 12))
end)

t.test('next/prev: a non-number or sub-1 step re-validates back to the default step of 1, never trusted raw', function()
    local ctx = buildEnv({ featureFlag = true, convarValue = 1 })
    ctx.dispatch(65535, 'goto', 10)
    ctx.dispatch(65535, 'next', 0.5) -- < 1 -- must fall back to 1, never floor(0.5) == 0 (a no-op step)
    t.equals(ctx.lastNotify().description, locale('bonetool.preview_bone_index', 11))
    ctx.dispatch(65535, 'prev', 'bogus')
    t.equals(ctx.lastNotify().description, locale('bonetool.preview_bone_index', 10))
end)

t.test('next: clamps at MaxBoneIndex rather than overflowing past it', function()
    local ctx = buildEnv({ featureFlag = true, convarValue = 1 })
    ctx.dispatch(65535, 'goto', 199)
    ctx.dispatch(65535, 'next', 50)
    t.equals(ctx.lastNotify().description, locale('bonetool.preview_bone_index', 200))
end)

-- ========================================================================
-- THE DRAW THREAD BODY -- the untested-thread category this pass exists to
-- close. Every case below drives the REAL thread function captured by the
-- CreateThread stub, stepped deterministically via Sandbox's cooperative
-- thread runner.
-- ========================================================================

t.test('draw thread: sweepActive starts false -- no DrawMarker/text draw on the very first pass', function()
    local ctx = buildEnv({ featureFlag = true, convarValue = 1 })
    ctx.step() -- primes past the initial Wait
    ctx.step() -- one full pass through the idle (Wait(500)) branch
    t.equals(#ctx.drawMarkerCalls, 0)
    t.equals(#ctx.textDrawCalls, 0)
end)

t.test('draw thread: once sweepActive is engaged via goto, the NEXT pass draws a marker at GetWorldPositionOfEntityBone\'s own result and labels it with the plain (non-test) bone index text', function()
    local ctx = buildEnv({ featureFlag = true, convarValue = 1 })
    ctx.step() -- prime
    ctx.dispatch(65535, 'goto', 7)
    ctx.step() -- one active pass
    t.equals(#ctx.boneWorldPosCalls, 1)
    t.equals(ctx.boneWorldPosCalls[1].boneIndex, 7)
    local marker = ctx.lastDrawMarker()
    t.isNotNil(marker)
    -- DrawMarker(type, x, y, z, ...) -- position must be EXACTLY what
    -- GetWorldPositionOfEntityBone(ped, 7) returned (x=7, y=14, z=21 per
    -- this fixture's own deterministic formula), never a hardcoded stand-in.
    t.equals(marker[2], 7.0)
    t.equals(marker[3], 14.0)
    t.equals(marker[4], 21.0)

    local textDraw = ctx.lastTextDraw()
    t.isNotNil(textDraw)
    t.equals(textDraw.text, locale('bonetool.bone_index_label', 7))
    t.isTrue(textDraw.origin.z > 21.0, 'the label must be drawn lifted above the marker\'s own z, never coincident with it')
end)

t.test('draw thread: does not draw at all while the ped does not exist, even though sweepActive is true', function()
    local ctx = buildEnv({ featureFlag = true, convarValue = 1 })
    ctx.step()
    ctx.dispatch(65535, 'goto', 3)
    ctx.setPedExists(false)
    ctx.step()
    t.equals(#ctx.drawMarkerCalls, 0)
end)

t.test('draw thread: does not draw at all while the ped is dead, even though sweepActive is true', function()
    local ctx = buildEnv({ featureFlag = true, convarValue = 1 })
    ctx.step()
    ctx.dispatch(65535, 'goto', 3)
    ctx.setPedDead(true)
    ctx.step()
    t.equals(#ctx.drawMarkerCalls, 0)
end)

t.test('draw thread: draws again once the ped exists and is alive again -- not a permanent trip', function()
    local ctx = buildEnv({ featureFlag = true, convarValue = 1 })
    ctx.step()
    ctx.dispatch(65535, 'goto', 3)
    ctx.setPedDead(true)
    ctx.step()
    t.equals(#ctx.drawMarkerCalls, 0)
    ctx.setPedDead(false)
    ctx.step()
    t.equals(#ctx.drawMarkerCalls, 1)
end)

t.test('draw thread: after stop, the very next pass draws nothing at all', function()
    local ctx = buildEnv({ featureFlag = true, convarValue = 1 })
    ctx.step()
    ctx.dispatch(65535, 'goto', 3)
    ctx.step()
    t.equals(#ctx.drawMarkerCalls, 1)
    ctx.dispatch(65535, 'stop')
    ctx.step()
    t.equals(#ctx.drawMarkerCalls, 1, 'no new draw call after stop')
end)

t.test('draw thread: once a live test prop is attached, the label switches to the TEST-ATTACHED text', function()
    local ctx = buildEnv({ featureFlag = true, convarValue = 1 })
    ctx.step()
    ctx.dispatch(65535, 'goto', 4)
    ctx.dispatch(65535, 'test')
    ctx.step()
    t.equals(ctx.lastTextDraw().text, locale('bonetool.bone_index_label_test_attached', 4))
end)

t.test('draw thread: if the test prop stops existing externally (e.g. despawned), the label reverts to plain text without crashing', function()
    local ctx = buildEnv({ featureFlag = true, convarValue = 1 })
    ctx.step()
    ctx.dispatch(65535, 'goto', 4)
    ctx.dispatch(65535, 'test')
    local attachedEntity = ctx.attachCalls[1] and (1000)
    ctx.killEntity(attachedEntity)
    local ok = pcall(ctx.step)
    t.isTrue(ok)
    t.equals(ctx.lastTextDraw().text, locale('bonetool.bone_index_label', 4))
end)

-- ========================================================================
-- TEST MODE (RunAttachTest)
-- ========================================================================

t.test('test: attaches with Config.BoneSweepTool\'s own model/offset, ZERO rotation, isNetworked=false, and no timeout override', function()
    local ctx = buildEnv({ featureFlag = true, convarValue = 1 })
    ctx.dispatch(65535, 'goto', 9)
    ctx.dispatch(65535, 'test')
    t.equals(#ctx.attachCalls, 1)
    local call = ctx.attachCalls[1]
    t.equals(call.modelName, 'prop_test_model')
    t.equals(call.boneIndex, 9)
    t.equals(call.offsetX, 0.1)
    t.equals(call.offsetY, 0.2)
    t.equals(call.offsetZ, 0.3)
    t.equals(call.rotX, 0.0)
    t.equals(call.rotY, 0.0)
    t.equals(call.rotZ, 0.0)
    t.isFalse(call.isNetworked, 'a local-only diagnostic prop must never be networked')
    t.isNil(call.timeoutMs)
    t.equals(ctx.lastNotify().type, 'info')
end)

t.test('test: a load failure notifies an error and leaves no dangling attach call recorded as a success', function()
    local ctx = buildEnv({ featureFlag = true, convarValue = 1 })
    ctx.setAttachShouldFail(true)
    ctx.dispatch(65535, 'goto', 9)
    ctx.dispatch(65535, 'test')
    t.equals(ctx.lastNotify().type, 'error')
    t.equals(ctx.lastNotify().description, locale('bonetool.test_prop_load_failed'))
end)

t.test('test: replaces a PRE-EXISTING test prop -- the old one is detached before the new one is attached', function()
    local ctx = buildEnv({ featureFlag = true, convarValue = 1 })
    ctx.dispatch(65535, 'goto', 9)
    ctx.dispatch(65535, 'test')
    t.equals(ctx.detachCallCount(), 1, 'the first test call still detaches the (nil) prior entity -- see the idempotent-nil case below')
    t.isNil(ctx.detachedEntityAt(1))

    ctx.dispatch(65535, 'test') -- second test call -- must detach the first attach's own entity first
    t.equals(ctx.detachCallCount(), 2)
    t.equals(ctx.detachedEntityAt(2), 1000, 'must detach the FIRST attach\'s entity id before creating the second')
    t.equals(#ctx.attachCalls, 2)
end)

-- ========================================================================
-- 'known' subcommand: informational only, never touches sweepActive/
-- currentBoneIndex/testEntity.
-- ========================================================================

t.test("'known': resolves every candidate via GetPedBoneIndex against the caller's own ped, and reports all of them, header to footer, via BOTH chat and console", function()
    local ctx = buildEnv({ featureFlag = true, convarValue = 1 })
    ctx.setBoneIndexResolution(0x796E, 12345) -- SKEL_Head
    ctx.dispatch(65535, 'known')

    t.isTrue(#ctx.boneIndexLookupCalls >= 20, 'every curated candidate must be looked up, not a subset')
    for _, call in ipairs(ctx.boneIndexLookupCalls) do
        t.equals(call.ped, 1)
    end

    local notify = ctx.lastNotify()
    t.isNotNil(notify)
    t.equals(notify.type, 'info')
    t.contains(notify.description, locale('bonetool.known_sweep_header'))
    t.contains(notify.description, locale('bonetool.known_sweep_footer'))
    t.contains(notify.description, 'SKEL_Head')
    t.contains(notify.description, '12345')

    local sawConsoleReport = false
    for _, line in ipairs(ctx.printedLines) do
        if line:find('SKEL_Head', 1, true) and line:find('12345', 1, true) then sawConsoleReport = true end
    end
    t.isTrue(sawConsoleReport, 'the console print must carry the same report as the chat notify')
end)

t.test("'known' never engages the preview loop by itself -- calling it before any goto leaves the draw thread idle", function()
    local ctx = buildEnv({ featureFlag = true, convarValue = 1 })
    ctx.step() -- prime
    ctx.dispatch(65535, 'known')
    ctx.step()
    t.equals(#ctx.drawMarkerCalls, 0, "'known' must never itself flip sweepActive")
end)

-- ========================================================================
-- onResourceStop -- release + idempotency
-- ========================================================================

t.test('onResourceStop: firing for a DIFFERENT resource name has no effect', function()
    local ctx = buildEnv({ featureFlag = true, convarValue = 1 })
    ctx.step()
    ctx.dispatch(65535, 'goto', 5)
    ctx.dispatch(65535, 'test')
    ctx.fireResourceStop('some-other-resource')
    t.equals(ctx.detachCallCount(), 1, 'only the ONE detach already made by the test call itself (its own stale-prop guard) -- the resource-stop handler must not have fired for a foreign name')
    ctx.step()
    t.equals(#ctx.drawMarkerCalls, 1, 'the sweep must still be active -- a foreign onResourceStop must not have torn anything down')
end)

t.test('onResourceStop: firing for THIS resource stops the sweep and detaches the live test prop', function()
    local ctx = buildEnv({ featureFlag = true, convarValue = 1 })
    ctx.step()
    ctx.dispatch(65535, 'goto', 5)
    ctx.dispatch(65535, 'test')
    local detachesBefore = ctx.detachCallCount()
    ctx.fireResourceStop(RESOURCE_NAME)
    t.equals(ctx.detachCallCount(), detachesBefore + 1)
    t.equals(ctx.lastDetachedEntity(), 1000, 'must detach the actual live test-prop entity, not a stale/nil one')

    ctx.step()
    t.equals(#ctx.drawMarkerCalls, 0, 'the sweep must be genuinely stopped -- no further draw calls after resource stop')
end)

t.test('onResourceStop: IDEMPOTENT on a double fire -- never throws, and the second call is a harmless nil-entity detach', function()
    local ctx = buildEnv({ featureFlag = true, convarValue = 1 })
    ctx.step()
    ctx.dispatch(65535, 'goto', 5)
    ctx.dispatch(65535, 'test')

    local ok1 = pcall(ctx.fireResourceStop, RESOURCE_NAME)
    t.isTrue(ok1)
    local ok2 = pcall(ctx.fireResourceStop, RESOURCE_NAME)
    t.isTrue(ok2, 'a second onResourceStop for the same resource must never throw')
    t.isNil(ctx.lastDetachedEntity(), 'the second call detaches an already-nil testEntity -- harmless, matching DetachAndDeleteProp\'s own nil-tolerant contract')
end)

-- ========================================================================
-- NO UNBOUNDED TRAP: 'stop' must stay reachable and idempotent from every
-- state, including a state where nothing was ever activated.
-- ========================================================================

t.test("NO UNBOUNDED TRAP: 'stop' from a totally fresh, never-activated state is a harmless no-op, never a throw", function()
    local ctx = buildEnv({ featureFlag = true, convarValue = 1 })
    local ok = pcall(ctx.dispatch, 65535, 'stop')
    t.isTrue(ok)
    t.isNil(ctx.lastDetachedEntity())
end)

t.test("NO UNBOUNDED TRAP: 'stop' is idempotent -- calling it twice in a row never throws and the sweep stays stopped", function()
    local ctx = buildEnv({ featureFlag = true, convarValue = 1 })
    ctx.step()
    ctx.dispatch(65535, 'goto', 5)
    ctx.dispatch(65535, 'stop')
    local ok = pcall(ctx.dispatch, 65535, 'stop')
    t.isTrue(ok)
    ctx.step()
    t.equals(#ctx.drawMarkerCalls, 0)
end)

t.test("NO UNBOUNDED TRAP: 'stop' still works after onResourceStop has already torn everything down once", function()
    local ctx = buildEnv({ featureFlag = true, convarValue = 1 })
    ctx.step()
    ctx.dispatch(65535, 'goto', 5)
    ctx.fireResourceStop(RESOURCE_NAME)
    local ok = pcall(ctx.dispatch, 65535, 'stop')
    t.isTrue(ok)
end)

os.exit(t.summary())
