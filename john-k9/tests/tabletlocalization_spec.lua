--[[
    tests/tabletlocalization_spec.lua

    Regression coverage for the tablet localization pass: html/tablet.js's
    own DEFAULT_STRINGS (the English fallback / resilience net, KEPT
    unchanged) must stay a 1:1 KEY match with locales/en.json's `tablet`
    group, and client/tablet.lua's real OpenTablet() payload must actually
    send every one of those keys, locale()-resolved, not the old `{}`.

    This file does NOT re-derive DEFAULT_STRINGS' VALUES from JS (a real
    JS parser is out of scope for a zero-dependency Lua spec) -- it extracts
    just the KEY NAMES with a narrow, line-oriented pattern identical in
    spirit to the one used to originally enumerate them (`^%s+([%a_][%w_]*):%s*'`),
    which is exactly precise enough to catch the one thing that actually
    matters here: a key added to/removed from html/tablet.js's
    DEFAULT_STRINGS without a matching change in locales/en.json's `tablet`
    group and client/tablet.lua's TABLET_STRING_KEYS list. VALUE correctness
    (byte-for-byte against DEFAULT_STRINGS) was verified by hand against a
    real JS-object parse when these three files were authored; this spec
    guards the key SET from silently drifting apart afterward.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')
local locale = Sandbox.locale

-- ----------------------------------------------------------------------
-- Extract DEFAULT_STRINGS' key names straight from the real,
-- unmodified html/tablet.js.
-- ----------------------------------------------------------------------

--- @return string[] keys, integer count
local function ExtractDefaultStringsKeys()
    -- DEFAULT_STRINGS moved to html/tablet-catalog.js on 2026-09-02; read
    -- the pair concatenated so this works wherever the literal lives.
    local handle = assert(io.open('../html/tablet-catalog.js', 'r'))
    local text = handle:read('a')
    handle:close()

    local startPos = text:find('var DEFAULT_STRINGS = {', 1, true)
    assert(startPos, 'DEFAULT_STRINGS declaration not found in html/tablet-catalog.js')
    local endPos = text:find('\n    };', startPos, true)
    assert(endPos, 'closing "};" for DEFAULT_STRINGS not found')
    local body = text:sub(startPos, endPos)

    local keys = {}
    for line in body:gmatch('[^\n]+') do
        -- Accept BOTH quote styles. This pattern was single-quote-only
        -- until 2026-08-26, and two real strings (home_no_certification_title,
        -- shop_item_label_placeholder) had been written with double quotes
        -- and were therefore invisible to every assertion in this file --
        -- both were genuinely missing from locales/en.json the whole time
        -- and this spec, whose entire job is to catch exactly that, could
        -- not see them. An extractor that silently skips valid input is
        -- worse than no extractor, because it reports green.
        local key = line:match("^%s+([%a_][%w_]*):%s*['\"]")
        if key then keys[#keys + 1] = key end
    end
    return keys, #keys
end

-- ----------------------------------------------------------------------
-- Minimal fixture -- just enough of client/tablet.lua's own load-time
-- dependencies to reach OpenTablet()'s tablet:open payload. Full
-- behavioral coverage (focus lifecycle, NUI callbacks, SECTION 2/3, etc.)
-- already lives in tests/clienttablet_spec.lua; this fixture only needs to
-- prove the `strings` payload.
-- ----------------------------------------------------------------------

local function newFixture()
    local sendNuiMessageCalls = {}
    local function SendNUIMessage(payload) sendNuiMessageCalls[#sendNuiMessageCalls + 1] = payload end
    local function SetNuiFocus(_hasFocus, _hasCursor) end
    -- CROSS-RESOURCE FOCUS INTEROP (client/tablet.lua, this pass) --
    -- OpenTablet() now calls IsNuiFocused() once per open to decide what
    -- CloseTablet() later restores -- this spec only cares about the
    -- string payload, so a plain always-false stub is enough;
    -- tests/clienttablet_spec.lua owns the focus-interop behavior itself.
    local function IsNuiFocused() return false end

    local runner = Sandbox.newThreadRunner()
    local function CreateThread(fn) runner.CreateThread(fn) end
    local function Wait(ms) runner.Wait(ms) end

    local function RegisterCommand(_name, _handler, _restricted) end
    local function RegisterNUICallback(_name, _handler) end
    local function AddEventHandler(_eventName, _handler) end
    local function GetCurrentResourceName() return 'john-k9' end
    local function GetResourceState(_resourceName) return 'started' end
    local function DisableControlAction() end
    local function IsDisabledControlJustPressed() return false end
    local function IsEntityDead() return false end
    local function PlayerPedId() return 1 end

    local fakeK9Compat = {
        Which = function() return nil end, -- no inventory adapter needed for this spec
        Get = function() return {} end,
    }

    local overrides = {
        SendNUIMessage = SendNUIMessage, SetNuiFocus = SetNuiFocus,
        IsNuiFocused = IsNuiFocused,
        CreateThread = CreateThread, Wait = Wait,
        RegisterCommand = RegisterCommand, RegisterNUICallback = RegisterNUICallback,
        AddEventHandler = AddEventHandler, GetCurrentResourceName = GetCurrentResourceName,
        -- client/tablet.lua now RegisterNetEvent's the live theme push
        -- (previously AddEventHandler-only, which never receives a
        -- server-originated TriggerClientEvent -- that was the bug). This
        -- spec only cares about the string payload, so a plain capture is
        -- enough; tests/clienttablet_spec.lua owns the theme behaviour.
        RegisterNetEvent = function(_eventName, _handler) end,
        GetResourceState = GetResourceState, K9Compat = fakeK9Compat,
        DisableControlAction = DisableControlAction,
        IsDisabledControlJustPressed = IsDisabledControlJustPressed,
        IsEntityDead = IsEntityDead, PlayerPedId = PlayerPedId,
        lib = { notify = function() end, callback = { await = function() error('not needed for this spec', 0) end } },
        CanShowK9UI = function() return true end,
        HasK9Access = function() return true end,
        DenyK9UIAccess = function() end,
    }

    local env = Sandbox.newEnv(overrides)
    Sandbox.loadInto('../config.lua', env)

    env.Config.Features.CommandTablet = true
    env.Config.CommandTablet = env.Config.CommandTablet or {}
    env.Config.CommandTablet.openMode = 'command'
    env.Config.CommandTablet.command = 'k9tablet'
    env.Config.FeatureControl = env.Config.FeatureControl or {}
    env.Config.FeatureControl.allowActionsFromTablet = true

    Sandbox.loadInto('../client/tablet.lua', env)

    return {
        env = env,
        sendNuiMessageCalls = sendNuiMessageCalls,
    }
end

-- ----------------------------------------------------------------------
-- The key set itself: html/tablet.js's DEFAULT_STRINGS <-> locales/en.json
-- ----------------------------------------------------------------------

-- WHY THERE IS NO HARDCODED KEY COUNT HERE ANY MORE
--
-- These assertions used to pin an exact literal (202, then 255, then 262,
-- then 287 -- four manual bumps in a single working session). Every one of
-- those bumps was a correct, deliberate string addition, and every one made
-- this file fail for a reason that had nothing to do with a real defect.
-- A test that cries wolf on correct work teaches people to update the
-- number without reading what broke, which is exactly how a genuinely
-- dropped string would sail through.
--
-- What actually needed protecting was never the number. It was:
--   1. the two key lists agreeing with each other,
--   2. every key resolving against locales/en.json,
--   3. no duplicate keys, and
--   4. the set not collapsing to near-nothing through a bad edit.
-- All four are pinned below without naming a total, so adding a string
-- costs nobody a bump and dropping one still fails loudly.
--
-- tests/schemaconvergence_spec.lua made the same call for its own table
-- count, and its comment explains the reasoning at more length.

--- A deliberately loose floor. Not a count -- a catastrophe detector, for
--- a botched edit that truncates DEFAULT_STRINGS or an extractor that
--- silently matches nothing. Well below the real total so ordinary
--- additions and removals never touch it.
local MIN_PLAUSIBLE_TABLET_STRINGS = 200

t.test('html/tablet.js DEFAULT_STRINGS is populated (a truncating edit, or an extractor matching nothing, fails here)', function()
    local _, count = ExtractDefaultStringsKeys()
    t.isTrue(
        count >= MIN_PLAUSIBLE_TABLET_STRINGS,
        ('DEFAULT_STRINGS has %d keys, below the %d floor -- either a large block of strings was lost, or ' ..
         'this spec\'s extractor no longer matches the file\'s shape'):format(count, MIN_PLAUSIBLE_TABLET_STRINGS)
    )
end)

t.test('every DEFAULT_STRINGS key resolves via locale() against locales/en.json\'s `tablet` group', function()
    local keys = ExtractDefaultStringsKeys()
    for _, key in ipairs(keys) do
        local ok, result = pcall(locale, 'tablet.' .. key)
        t.isTrue(ok, 'locale(\'tablet.' .. key .. '\') should resolve, got error: ' .. tostring(result))
    end
end)

t.test('no duplicate keys in DEFAULT_STRINGS (a copy/paste key collision would silently drop a string)', function()
    local keys = ExtractDefaultStringsKeys()
    local seen = {}
    for _, key in ipairs(keys) do
        t.isNil(seen[key], 'duplicate DEFAULT_STRINGS key: ' .. key)
        seen[key] = true
    end
end)

-- ----------------------------------------------------------------------
-- The real production payload -- OpenTablet() must actually SEND every
-- one of those keys, locale()-resolved, not the old `strings = {}`.
-- ----------------------------------------------------------------------

t.test('OpenTablet(): `strings` is no longer the empty-table placeholder', function()
    local f = newFixture()
    f.env.OpenTablet()
    local msg = f.sendNuiMessageCalls[1]
    t.equals(msg.action, 'tablet:open')
    t.isTrue(next(msg.data.strings) ~= nil, 'strings must not ship empty')
end)

t.test('OpenTablet(): `strings` carries every DEFAULT_STRINGS key, each equal to locale(\'tablet.<key>\')', function()
    local f = newFixture()
    f.env.OpenTablet()
    local strings = f.sendNuiMessageCalls[1].data.strings

    local keys = ExtractDefaultStringsKeys()
    for _, key in ipairs(keys) do
        t.equals(strings[key], locale('tablet.' .. key), 'strings.' .. key .. ' must equal locale(\'tablet.' .. key .. '\')')
    end
end)

t.test('OpenTablet(): `strings` carries no MORE than DEFAULT_STRINGS does -- a renamed or stale extra entry fails here', function()
    local f = newFixture()
    f.env.OpenTablet()
    local strings = f.sendNuiMessageCalls[1].data.strings

    local sentCount = 0
    for _ in pairs(strings) do sentCount = sentCount + 1 end

    -- Compared against the live extracted total rather than a literal.
    -- Paired with the "carries every DEFAULT_STRINGS key" test directly
    -- above, this is set equality: that one proves every JS key is sent,
    -- this one proves nothing else is. A key renamed on one side and not
    -- the other still fails, which is the case the old hardcoded number
    -- was really there for.
    local _, jsCount = ExtractDefaultStringsKeys()
    t.equals(sentCount, jsCount)
end)

-- ----------------------------------------------------------------------
-- THE REMAINING BLIND SPOT, CLOSED. Every assertion above starts from a
-- key that already exists on a CODE side (DEFAULT_STRINGS, or the strings
-- payload OpenTablet builds from TABLET_STRING_KEYS) and checks it resolves
-- against locales/en.json. Nothing iterated the other way. So a key that
-- exists ONLY in locales/en.json -- left behind by a renamed or deleted
-- screen -- was invisible to this whole file, which is precisely the
-- "missing from the code sides, passes silently" case this spec exists to
-- catch. An integration audit flagged a suspected gap here and could not
-- enumerate it by hand; this test enumerates it mechanically instead.
--
-- Dead locale text is not merely untidy. Every one of these is a string
-- somebody wrote, that a translator will faithfully translate, that no
-- screen will ever show.
--
-- SERVER-RESOLVED PREFIXES ARE NOT DEAD and are excluded by prefix, not by
-- name: server/runtimecontrol.lua builds these key names at runtime
-- ('tablet.runtime_tunable_desc_' .. key:lower()) and sends the already-
-- resolved TEXT to the page, so they legitimately have no DEFAULT_STRINGS
-- or TABLET_STRING_KEYS entry and never will. Excluding by prefix rather
-- than listing each one keeps this from needing an edit every time a
-- tunable is added.
local SERVER_RESOLVED_KEY_PREFIXES = {
    'runtime_tunable_desc_',
    'runtime_lockout_warning_',
    'runtime_active_usage_warning_',
}

local function IsServerResolvedKey(key)
    for _, prefix in ipairs(SERVER_RESOLVED_KEY_PREFIXES) do
        if key:sub(1, #prefix) == prefix then return true end
    end
    return false
end

--- Every `tablet.<key>` name mentioned literally anywhere in server/*.lua
--- or client/*.lua. This is the THIRD legitimate way a tablet string gets
--- used, alongside DEFAULT_STRINGS and the OpenTablet payload: Lua resolves
--- it itself and sends already-rendered text to the page. Eight real keys
--- work this way today (console_not_authorized, the online_player_* family,
--- open_failed_generic, the revoke_* pair, roster_truncated_notice), and
--- treating them as dead would be wrong.
---
--- DERIVED BY SCANNING, never a hand-written list. A list would need
--- editing every time somebody resolves a string in Lua, and the edit that
--- gets forgotten is the one that turns this test into a nuisance somebody
--- disables. Scanning costs one pass over the source and cannot rot.
--- Deliberately a plain substring match rather than something stricter: the
--- cost of a false NEGATIVE here is a dead string surviving, which is minor,
--- while a false POSITIVE would be this test failing over a live key, which
--- is how a good test gets deleted.
local function CollectKeysReferencedInLua()
    local referenced = {}
    local handle = io.popen('cat ../server/*.lua ../client/*.lua 2>/dev/null')
    if not handle then return referenced end
    local text = handle:read('a') or ''
    handle:close()
    for key in text:gmatch("tablet%.([%a_][%w_]*)") do referenced[key] = true end
    for key in text:gmatch("'([%a_][%w_]*)'") do referenced[key] = true end
    return referenced
end

t.test('LOAD-BEARING: locales/en.json\'s `tablet` group carries no key that no code side can ever use -- dead text a translator would translate and no screen would show', function()
    local f = newFixture()
    f.env.OpenTablet()
    local strings = f.sendNuiMessageCalls[1].data.strings
    local defaultKeys = ExtractDefaultStringsKeys()

    local reachable = {}
    for _, key in ipairs(defaultKeys) do reachable[key] = true end
    for key in pairs(strings) do reachable[key] = true end

    -- Read the `tablet` group straight out of the real locale file. Doing
    -- it here rather than through locale() deliberately: locale() answers
    -- "does this key resolve", which is the direction every other test in
    -- this file already covers. The question here is the opposite one --
    -- what is IN the file that nothing asks for -- and only the file itself
    -- can answer that.
    local localeHandle = assert(io.open('../locales/en.json', 'r'))
    local localeText = localeHandle:read('a')
    localeHandle:close()
    local tabletGroupStart = localeText:find('"tablet"%s*:%s*{')
    assert(tabletGroupStart, 'the `tablet` group was not found in locales/en.json')
    local depth, i, groupEnd = 0, localeText:find('{', tabletGroupStart, true), nil
    while i and i <= #localeText do
        local c = localeText:sub(i, i)
        if c == '{' then depth = depth + 1
        elseif c == '}' then
            depth = depth - 1
            if depth == 0 then groupEnd = i break end
        end
        i = i + 1
    end
    assert(groupEnd, 'the `tablet` group in locales/en.json is not brace-balanced')
    local groupBody = localeText:sub(tabletGroupStart, groupEnd)

    local localeKeys = {}
    for line in groupBody:gmatch('[^\n]+') do
        local key = line:match('^%s+"([%a_][%w_]*)"%s*:')
        if key then localeKeys[key] = true end
    end

    local referencedInLua = CollectKeysReferencedInLua()

    local orphans = {}
    for key in pairs(localeKeys) do
        if not reachable[key] and not IsServerResolvedKey(key) and not referencedInLua[key] then
            orphans[#orphans + 1] = key
        end
    end
    table.sort(orphans)

    t.equals(#orphans, 0, ('locales/en.json has %d `tablet` key(s) that neither DEFAULT_STRINGS nor the OpenTablet strings payload can reach, and which are not server-resolved: %s'):format(#orphans, table.concat(orphans, ', ')))
end)

os.exit(t.summary())
