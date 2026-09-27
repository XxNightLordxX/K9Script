--[[
    tests/keybindcollisions_spec.lua

    THIS FILE'S JOB, AND ONLY THIS FILE'S JOB: prove that no two keybinds
    this resource ships default to the SAME key, across every client file
    at once.

    WHY IT EXISTS. `client/keybinds.lua`'s own header already states the
    rule, and states it well: a new default key must avoid "every OTHER
    RegisterKeyMapping default already shipped in this resource", and it
    even lists them by name. Nothing enforced it. `tests/clientkeybinds_spec.lua`
    checks that one file's keys do not collide with EACH OTHER, which is a
    useful check and not this one -- a collision between two different
    files sailed straight past it.

    And one did. `client/pursuitsprint.lua` hardcodes 'N' for pursuit
    sprint, which ships ON, while a since-removed feature's keybind also shipped
    'N'. The two never met, because Danger Warn ships OFF and its whole
    file is gated behind that switch -- so a stock install was fine, every
    test passed, and the fault was invisible.

    It was armed by the very comment inviting an owner to switch the
    feature on. The moment anyone did, every press of N would have fired
    BOTH: a K9 sprinting after a suspect barking a danger warning at their
    handler every single time. It would have appeared only after a
    restart, only for the person who opted in, and nothing anywhere warned
    about it.

    THAT SHAPE IS WHY THIS CHECKS SHIPPED DEFAULTS REGARDLESS OF WHETHER
    THE FEATURE IS ON. A collision that only appears once somebody opts in
    is worse than one that appears immediately, not better: it waits, and
    it surfaces on a live server rather than on a developer's.

    WHAT A COLLISION ACTUALLY COSTS, so nobody weakens this later thinking
    it is cosmetic: FiveM keymappings are independent controls that can
    share a key, and both handlers run. Two K9 actions on one press is not
    a preference clash, it is one action firing that the player never
    asked for -- and in a resource where the actions include releasing a
    dog onto somebody, that matters.

    WHAT THIS DELIBERATELY DOES NOT CHECK: whether a default collides with
    a core GTA control (W/A/S/D, E, F, R and friends). That would need the
    game's own binding table, which is not available here, and guessing at
    it would produce exactly the confident-but-wrong findings this
    codebase has been bitten by. Choosing a key that avoids core controls
    stays a human judgement, recorded in the config comment next to each
    one.
--]]

local t = dofile('testkit.lua')

--- @param path string
--- @return string
local function ReadFile(path)
    local handle, err = io.open(path, 'r')
    if not handle then
        error(('could not open %s: %s'):format(path, tostring(err)), 2)
    end
    local text = handle:read('a')
    handle:close()
    return text
end

--- Strips whole-line Lua comments before scanning.
---
--- Non-negotiable here for the same reason it is non-negotiable in
--- tests/commandreferenceregistry_spec.lua: this codebase's comments are
--- dense prose that quote real call shapes to explain them. A doc comment
--- containing `RegisterCommand('...')` once made two separate drift guards
--- report a live command named `...` that does not exist. `client/keybinds.lua`'s
--- own header lists shipped default keys IN PROSE ("L camera, X vault, N
--- pursuit sprint, H camera feed, K thermal vision, J night vision, G
--- handler-down confirm") -- scanning that as code would report a
--- collision on nearly every key in the resource, all of them imaginary.
--- @param text string
--- @return string
local function StripFullLineComments(text)
    local kept = {}
    for line in (text .. '\n'):gmatch('([^\n]*)\n') do
        if not line:match('^%s*%-%-') then
            kept[#kept + 1] = line
        end
    end
    return table.concat(kept, '\n')
end

local CLIENT_DIR = '../client'

--- @return string[]
local function ClientFiles()
    local paths = {}
    local pipe = io.popen(("find %s -type f -name '*.lua' 2>/dev/null"):format(CLIENT_DIR))
    if not pipe then return paths end
    for line in pipe:lines() do paths[#paths + 1] = line end
    pipe:close()
    table.sort(paths)
    return paths
end

--- Every LITERAL default key a RegisterKeyMapping call ships.
---
--- Only literals. A call whose default comes from a Config value
--- (`Config.Vision.Thermal.toggleKey`) is invisible to this pattern by
--- design -- resolving those means executing config.lua, which is
--- ExtractConfiguredDefaultKeys' job below. The two halves are compared
--- together, which is the whole point: the collision that shipped was
--- between a literal in one file and a Config value in another, so
--- checking either half alone would have missed it exactly as the
--- existing per-file test did.
--- @param text string
--- @return table[] -- { command = string, key = string }
local function ExtractLiteralDefaultKeys(text)
    local found = {}
    for command, key in StripFullLineComments(text)
        :gmatch("RegisterKeyMapping%(%s*'([^']+)'.-'keyboard'%s*,%s*'([^']+)'%s*%)") do
        found[#found + 1] = { command = command, key = key }
    end
    return found
end

--- Every default key config.lua ships, by reading the REAL file rather
--- than restating its values here -- a hand-copied list would drift the
--- moment somebody edited config.lua, and a drift guard that drifts is
--- worse than none.
--- @return table[] -- { path = string, key = string }
--- ONE pattern, deliberately, matching any field whose NAME mentions a key
--- and whose VALUE looks like a key name. The first draft of this used two
--- patterns -- one for `*keybind*`, one for `*toggleKey*` -- and reported
--- two imaginary collisions on its very first run, because `toggleKeybind`
--- satisfies BOTH and got counted twice against itself.
---
--- Recording that rather than quietly fixing it, because it is the third
--- time in this project a scanner has accused something innocent, and the
--- lesson keeps being the same one: when a guard reports a problem, the
--- guard is the first suspect, not the last.
local function ExtractConfiguredDefaultKeys()
    local found = {}
    local text = StripFullLineComments(ReadFile('../config.lua'))
    -- Value shape (an all-uppercase FiveM key name: a letter or digit, or a
    -- named key like LBRACKET / PERIOD) is what keeps this off unrelated
    -- string fields that merely have "key" in the name. It used to allow
    -- only one to three characters, which silently skipped every named key
    -- -- the takedown default ('LBRACKET') was invisible to this guard.
    for name, key in text:gmatch("([%a_]+)%s*=%s*'([%u%d][%u%d]*)'") do
        if name:lower():find('key', 1, true) and #key <= 12 then
            found[#found + 1] = { path = name, key = key }
        end
    end
    return found
end

-- ============================================================================
-- CONTROLS FIRST. A scanner that quietly matched nothing would pass the
-- headline test below forever while protecting nothing -- the "fixture never
-- reaches the code under test" failure this codebase has hit repeatedly. These
-- prove the extractors really extract before a clean result is allowed to mean
-- anything.
-- ============================================================================

t.test('CONTROL: the literal extractor finds a real RegisterKeyMapping default, in both the one-line and wrapped-argument shapes this resource actually uses', function()
    local oneLine = "RegisterKeyMapping('k9sit', locale('radial.sit_keybind_label'), 'keyboard', 'V')"
    local found = ExtractLiteralDefaultKeys(oneLine)
    t.equals(#found, 1)
    t.equals(found[1].command, 'k9sit')
    t.equals(found[1].key, 'V')

    local wrapped = "RegisterKeyMapping('k9recall',\n    locale('recall.keybind_label'),\n    'keyboard', 'U')"
    local foundWrapped = ExtractLiteralDefaultKeys(wrapped)
    t.equals(#foundWrapped, 1, 'a call split across lines must still be seen')
    t.equals(foundWrapped[1].key, 'U')
end)

t.test('CONTROL: prose naming shipped keys is NOT read as a registration -- client/keybinds.lua lists them in its own header, and scanning that would invent a collision on nearly every key', function()
    local prose = "-- Default keys chosen below avoid every OTHER RegisterKeyMapping\n"
        .. "-- default already shipped (L camera, X vault, N pursuit sprint).\n"
        .. "RegisterKeyMapping('k9real', locale('x'), 'keyboard', 'Z')"
    local found = ExtractLiteralDefaultKeys(prose)
    t.equals(#found, 1, 'only the live registration counts')
    t.equals(found[1].key, 'Z')
end)

t.test('CONTROL: the scanners genuinely reach the real files on disk -- a clean headline result means nothing if they scanned an empty list', function()
    local literals = {}
    for _, path in ipairs(ClientFiles()) do
        for _, entry in ipairs(ExtractLiteralDefaultKeys(ReadFile(path))) do
            literals[#literals + 1] = entry
        end
    end
    t.isTrue(#literals >= 6, ('expected at least 6 literal keybind defaults across client/, found %d'):format(#literals))
    t.isTrue(#ExtractConfiguredDefaultKeys() >= 4, 'expected at least 4 configured keybind defaults in config.lua')
end)

-- ============================================================================
-- THE HEADLINE GUARD
-- ============================================================================

t.test('LOAD-BEARING GUARD: no two keybinds this resource ships default to the same key -- counting literals in client/ and configured defaults in config.lua TOGETHER, because the one collision that shipped was between the two', function()
    local byKey = {}
    local function record(key, owner)
        byKey[key] = byKey[key] or {}
        table.insert(byKey[key], owner)
    end

    for _, path in ipairs(ClientFiles()) do
        for _, entry in ipairs(ExtractLiteralDefaultKeys(ReadFile(path))) do
            record(entry.key, ('%s (%s)'):format(entry.command, path:gsub('^%.%./', '')))
        end
    end
    for _, entry in ipairs(ExtractConfiguredDefaultKeys()) do
        record(entry.key, ('config.lua %s'):format(entry.path))
    end

    local collisions = {}
    for key, owners in pairs(byKey) do
        if #owners > 1 then
            table.sort(owners)
            collisions[#collisions + 1] = ("  '%s' is the default for %d things: %s"):format(key, #owners, table.concat(owners, ', '))
        end
    end
    table.sort(collisions)

    if #collisions > 0 then
        error(('%d key(s) are the shipped default for more than one action:\n%s\n\n')
            :format(#collisions, table.concat(collisions, '\n'))
            .. 'FiveM lets two keymappings share a key and runs BOTH handlers, so this is not a\n'
            .. 'preference clash -- it is one K9 action firing that the player never asked for,\n'
            .. 'every time they press the other one.\n\n'
            .. 'FIX THIS BY choosing a different default for the newer of the two. client/keybinds.lua\'s\n'
            .. 'own header states the rule: a free, uncommonly-bound letter, avoiding every other\n'
            .. 'default this resource ships and every core movement key. Do NOT fix it by narrowing\n'
            .. 'this guard, and do NOT dismiss it because one of the two features ships switched off --\n'
            .. 'that is exactly how the last one hid: it was armed by the comment inviting an owner\n'
            .. 'to turn the feature on, and would have surfaced on a live server rather than here.', 0)
    end

    t.equals(#collisions, 0)
end)

-- ============================================================================
-- KEYS OUR OWN DEPENDENCIES ALREADY OWN. fxmanifest.lua makes ox_lib and
-- ox_target hard dependencies, so their default keys are on every server
-- this runs on. A K9 default on one of them fires both on every press --
-- and Z is ox_lib's radial menu, the very menu the K9 actions live in:
-- scent vision shipped on Z, so every K9 who opened their menu toggled it.
--
-- Values are read from each dependency's own source, not guessed:
--   ox_lib    resource/interface/client/radial.lua  addKeybind 'ox_lib-radial', defaultKey = 'z'
--   ox_target client/main.lua                        addKeybind 'ox_target',     defaultKey = 'LMENU'
-- ============================================================================
local RESERVED_BY_DEPENDENCIES = {
    Z = "ox_lib's radial menu (the menu every K9 action is in)",
    LMENU = "ox_target's third eye",
}

t.test('CONTROL: the configured-key scanner sees NAMED keys too (LBRACKET, PERIOD), not just one-letter ones', function()
    local seen = {}
    for _, entry in ipairs(ExtractConfiguredDefaultKeys()) do seen[entry.key] = true end
    t.isTrue(seen.LBRACKET == true, 'the takedown default (LBRACKET) must be visible to these guards')
end)

t.test('LOAD-BEARING GUARD: no default key this resource ships is one ox_lib or ox_target already uses', function()
    local hits = {}
    local function check(key, owner)
        local reserved = RESERVED_BY_DEPENDENCIES[key:upper()]
        if reserved then
            hits[#hits + 1] = ("  '%s' (%s) is also %s"):format(key, owner, reserved)
        end
    end
    for _, path in ipairs(ClientFiles()) do
        for _, entry in ipairs(ExtractLiteralDefaultKeys(ReadFile(path))) do
            check(entry.key, ('%s, %s'):format(entry.command, path:gsub('^%.%./', '')))
        end
    end
    for _, entry in ipairs(ExtractConfiguredDefaultKeys()) do
        check(entry.key, 'config.lua ' .. entry.path)
    end
    table.sort(hits)
    if #hits > 0 then
        error(('%d default key(s) clash with a dependency:\n%s\n\nPick a different default.'):format(#hits, table.concat(hits, '\n')), 0)
    end
    t.equals(#hits, 0)
end)

os.exit(t.summary())
