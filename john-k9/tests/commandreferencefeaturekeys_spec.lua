--[[
    tests/commandreferencefeaturekeys_spec.lua

    THE FAILURE THIS EXISTS FOR (2026-09-01, from the owner's live testing:
    "everything in the command console in the status says disabled").

    html/tablet.js's commandReferenceStatus() resolves each command's live
    status badge from its entry's `gate.featureKey`, by looking that key up
    in `state.myRecord.myFeatures[]`. A key it does NOT find there resolves
    to 'global_off' -- "Disabled server-wide" -- and that fallback is
    CORRECT and deliberate: server/tablet.lua's BuildMyFeaturesArray walks
    ListFeatureKeys(), which enumerates `pairs(Config.Features)` fresh on
    every call, so a key absent from Config.Features never gets an array
    entry, and in Lua that same missing key makes ResolveFeatureState's own
    `Config.Features[key] == true` false exactly as an explicit `false`
    would. Absent means off. See that function's own long comment.

    But that makes the SPELLING of every `featureKey` in COMMAND_REFERENCE
    load-bearing in a way nothing checked. Rename a Config.Features key,
    delete one, or typo a new entry, and every command gated on it silently
    starts reporting "Disabled server-wide" on a completely healthy server
    -- with no error, no log line, and no failing test. The badge is not
    lying about what it resolved; the two sides simply stopped agreeing
    about what the key is called. That is indistinguishable, to an owner
    reading the screen, from the resource being switched off.

    So this file proves ONE thing: every `featureKey` COMMAND_REFERENCE
    names really is a key in config.lua's own `Config.Features` table --
    with a narrow, explicitly-reasoned allowlist for the keys that are
    absent ON PURPOSE.

    It does NOT check gate correctness, wording, or categorisation (that is
    html/tests/tablet_command_reference_spec.js's job), nor the set of
    command NAMES (tests/commandreferenceregistry_spec.lua's job). Only that
    no gate points at a Config.Features key that does not exist.

    WHY TEXT-PATTERN EXTRACTION: the same reason
    tests/commandreferenceregistry_spec.lua gives in its own header --
    html/tablet.js is a browser IIFE this sandbox cannot execute, and
    config.lua's Config.Features is a plain literal table, so both facts are
    read out of raw source text rather than by booting either file.
]]

local t = dofile('testkit.lua')

local function ReadFile(path)
    local handle, err = io.open(path, 'r')
    assert(handle, 'could not open ' .. path .. ': ' .. tostring(err))
    local text = handle:read('*a')
    handle:close()
    return text
end

--- Every `featureKey: '...'` named inside the COMMAND_REFERENCE literal.
--- Scoped to that array's own body specifically -- `featureKey` appears in
--- prose comments and in other structures elsewhere in this 15k-line file,
--- and matching those would produce failures about names that are not gates.
--- @param text string -- raw html/tablet.js source
--- @return table<string, boolean> -- set of key names
local function ExtractGateFeatureKeys(text)
    local startPos = text:find('var COMMAND_REFERENCE = [', 1, true)
    assert(startPos, 'var COMMAND_REFERENCE = [ not found in html/tablet.js or html/tablet-catalog.js')
    local endPos = text:find('\n    ];', startPos, true)
    assert(endPos, 'closing "];" for COMMAND_REFERENCE not found in html/tablet.js or html/tablet-catalog.js')
    local body = text:sub(startPos, endPos)

    local out = {}
    for key in body:gmatch("featureKey:%s*'([^']+)'") do
        out[key] = true
    end
    return out
end

--- Every key declared in config.lua's `Config.Features` table.
--- Brace-counts from the opening `{` so a nested table inside the block can
--- never end the scan early, and strips comments first so a key named only
--- inside a `--` or `--[[ ]]` comment is never mistaken for a real one.
--- @param text string -- raw config.lua source
--- @return table<string, boolean> -- set of key names
local function ExtractConfigFeatureKeys(text)
    local startPos = text:find('Config.Features%s*=%s*{')
    assert(startPos, 'Config.Features = { not found in config.lua')
    local openPos = text:find('{', startPos, true)

    local depth, i = 1, openPos + 1
    while depth > 0 do
        local ch = text:sub(i, i)
        assert(ch ~= '', 'unterminated Config.Features table in config.lua')
        if ch == '{' then depth = depth + 1
        elseif ch == '}' then depth = depth - 1 end
        i = i + 1
    end

    local body = text:sub(openPos + 1, i - 2)
    body = body:gsub('%-%-%[%[.-%]%]', '')  -- block comments first
    body = body:gsub('%-%-[^\n]*', '')      -- then line comments

    local out = {}
    for key in body:gmatch('([%a_][%w_]*)%s*=') do
        out[key] = true
    end
    return out
end

--[[
    KEYS DELIBERATELY ABSENT FROM Config.Features.

    An entry here is a claim that a command's gate names a key config.lua
    genuinely does not (and should not) declare, so its "Disabled
    server-wide" badge is the honest, intended answer rather than drift.
    Each needs a real reason, not just a name -- an allowlist you can add to
    without justifying is how the drift this file guards against gets waved
    through one entry at a time.

    Both directions are checked below: an allowlisted key that turns out to
    BE in Config.Features fails too, so this list cannot quietly outlive the
    reason it was added.
]]
local INTENTIONALLY_ABSENT = {
    ScentTrailHunt = 'Removed from config.lua when scent tracking was merged into one '
        .. 'certification-driven action. /k9nosehunt keeps its COMMAND_REFERENCE entry so '
        .. 'the screen can honestly report it as off rather than omitting it (a command a '
        .. 'player might still type needs an answer), and '
        .. 'html/tests/tablet_command_reference_spec.js pins that exact badge.',
}

t.test('SYNTHETIC: the extractors actually find what they claim to (a guard that passes on an empty set proves nothing)', function()
    local fakeJs = [[
    var COMMAND_REFERENCE = [
        { command: 'k9one', gate: { kind: 'access', featureKey: 'RealOne' } },
        { command: 'k9two', gate: { kind: 'open' } },
        { command: 'k9three', gate: { kind: 'access', featureKey: 'RealTwo' } },
    ];
]]
    local found = ExtractGateFeatureKeys(fakeJs)
    assert(found.RealOne, 'extractor found the first featureKey')
    assert(found.RealTwo, 'extractor found the second featureKey')

    local fakeConfig = [[
Config.Features = {
    RealOne = true,
    RealTwo = false,
    Nested = { Inner = true },
    -- CommentedOut = true,
}
]]
    local cfg = ExtractConfigFeatureKeys(fakeConfig)
    assert(cfg.RealOne, 'config extractor found an enabled key')
    assert(cfg.RealTwo, 'config extractor found a DISABLED key too -- present-but-false is still declared')
    assert(not cfg.CommentedOut, 'a key that exists only inside a comment is not treated as declared')
end)

t.test('SYNTHETIC: a featureKey missing from Config.Features is actually detected (proves the real test below can fail)', function()
    local fakeJs = [[
    var COMMAND_REFERENCE = [
        { command: 'k9one', gate: { kind: 'access', featureKey: 'TypoedName' } },
    ];
]]
    local fakeConfig = 'Config.Features = {\n    CorrectName = true,\n}\n'
    local gates = ExtractGateFeatureKeys(fakeJs)
    local cfg = ExtractConfigFeatureKeys(fakeConfig)

    local missing = {}
    for key in pairs(gates) do
        if not cfg[key] then missing[#missing + 1] = key end
    end
    assert(#missing == 1 and missing[1] == 'TypoedName',
        'a renamed/typoed gate key is caught -- this is the exact drift that makes a healthy server report everything disabled')
end)

t.test('every COMMAND_REFERENCE gate.featureKey exists in Config.Features (or is explicitly allowlisted as intentionally absent)', function()
    local gates = ExtractGateFeatureKeys((ReadFile('../html/tablet.js') .. ReadFile('../html/tablet-catalog.js')))
    local cfg = ExtractConfigFeatureKeys(ReadFile('../config.lua'))

    local count = 0
    for _ in pairs(gates) do count = count + 1 end
    assert(count > 0, 'extracted zero featureKeys -- the extraction pattern has gone stale, and this test would otherwise pass by checking nothing')

    local missing = {}
    for key in pairs(gates) do
        if not cfg[key] and not INTENTIONALLY_ABSENT[key] then
            missing[#missing + 1] = key
        end
    end
    table.sort(missing)

    if #missing > 0 then
        error('COMMAND_REFERENCE gate(s) name a Config.Features key that does not exist: '
            .. table.concat(missing, ', ')
            .. '. Every command gated on one of these renders "Disabled server-wide" on a '
            .. 'completely healthy server -- silently, with no error anywhere. Either fix the '
            .. 'spelling to match config.lua, or add the key to INTENTIONALLY_ABSENT in this '
            .. 'file WITH the reason it is absent on purpose.', 0)
    end
end)

t.test('the intentionally-absent allowlist does not outlive its own reason', function()
    -- The other direction. If a key on that list is added back to
    -- Config.Features, the entry is now false -- and a stale allowlist is
    -- exactly a hole in the check above, silently excusing a real drift for
    -- whatever name happens to be listed.
    local cfg = ExtractConfigFeatureKeys(ReadFile('../config.lua'))

    local stale = {}
    for key in pairs(INTENTIONALLY_ABSENT) do
        if cfg[key] then stale[#stale + 1] = key end
    end
    table.sort(stale)

    if #stale > 0 then
        error('INTENTIONALLY_ABSENT lists key(s) that ARE now declared in Config.Features: '
            .. table.concat(stale, ', ')
            .. '. Remove them from that list -- while listed, a genuine future drift on those '
            .. 'exact names would be waved through.', 0)
    end
end)

t.test('every allowlist entry carries a real reason, not just a name', function()
    for key, reason in pairs(INTENTIONALLY_ABSENT) do
        assert(type(reason) == 'string' and #reason >= 40,
            'INTENTIONALLY_ABSENT["' .. key .. '"] needs a real explanation of why the key is '
            .. 'absent on purpose -- an allowlist you can add to without justifying is how the '
            .. 'drift this file guards against gets waved through one entry at a time')
    end
end)

os.exit(t.summary())
