--[[
    tests/commandsuggestions_spec.lua

    NEW FILE, pairing client/commandsuggestions.lua (also new this pass).
    Two jobs:

    1. DRIFT GUARD, same shape and same reasoning as
       tests/commandreferenceregistry_spec.lua's own LOAD-BEARING DRIFT
       GUARD test (read that file's header before touching this one's own
       extraction logic -- this follows it deliberately, not a second,
       independent design): proves client/commandsuggestions.lua's own
       hand-maintained COMMAND_SUGGESTIONS table names EXACTLY the same set
       of commands as the real `RegisterCommand('...')` calls across
       server/*.lua + client/*.lua, in both directions, using the
       IDENTICAL text-pattern extraction
       (`RegisterCommand%('([^']+)'`) that spec already established and
       this file's own header ("DERIVATION") explicitly says it reuses
       rather than re-deriving.

    2. BEHAVIOUR: loads the REAL client/commandsuggestions.lua into a
       sandbox and proves it actually calls
       `TriggerEvent('chat:addSuggestion', ...)` with the right command
       name, a real (or correctly-pending) locale-backed description, and
       correctly-parsed parameter hints -- for a representative sample
       spanning every shape this file's own header documents (a bare
       no-arg command, one with a single required param, one with a
       required-plus-optional pair, one of the seven colon-namespaced
       keybind commands, and all three dynamic-name commands under every
       relevant Config combination).

    HAND-MAINTAINED FILE LIST, SAME DISCLOSED TRADEOFF as
    tests/commandreferenceregistry_spec.lua's own SERVER_LUA_FILES/
    CLIENT_LUA_FILES (see that file's header for the full writeup) --
    SERVER_LUA_FILES/CLIENT_LUA_FILES below are an INDEPENDENT snapshot of
    the exact same real files, taken the same day (2026-08-26). A brand-new
    server/*.lua or client/*.lua file that registers its own command must
    be added to the matching list in BOTH this file and
    tests/commandreferenceregistry_spec.lua in the same change, or each
    spec will independently under-report the real command set (never over-
    report -- a missing FILE only ever yields FEWER real names, which can
    only make the "documented/suggested has no real match" side of each
    comparison fire, loudly, never let a real command through unnoticed).
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

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

-- ============================================================================
-- PART 1: DRIFT GUARD
-- ============================================================================

--- Every `server/*.lua` / `client/*.lua` filename, read from DISK at run
--- time rather than kept as a hand-maintained snapshot -- same change, same
--- reasoning, and the same drift history as
--- tests/commandreferenceregistry_spec.lua's own pair (read LuaFilesIn's
--- comment there for the full writeup).
---
--- Kept as an INDEPENDENT enumeration rather than importing that file's,
--- which is the one property of the old two-snapshot arrangement worth
--- preserving: these two specs check different catalogs (COMMAND_REFERENCE
--- vs COMMAND_SUGGESTIONS) and a shared helper would let one bug blind both
--- at once. Enumerating the same folders twice costs nothing and keeps them
--- genuinely independent.
--- @param dir string
--- @return string[]
local function LuaFilesIn(dir)
    -- RECURSIVE, deliberately (`find`, not `ls dir/*.lua`). Commands do not
    -- only live one level down any more: server/certifications/ was split
    -- on 2026-09-02 into server/certifications/{core,depth,accessors,
    -- commands}.lua, and a non-recursive listing silently stopped seeing
    -- five real commands -- /k9certify, /k9decertify, /k9settier,
    -- /k9specialize and /k9unspecialize. That is the exact "real but
    -- undiscovered" direction this file's own header warns about: the
    -- commands kept working in-game while this guard reported their tablet
    -- entries as naming commands that do not exist. Returns paths RELATIVE
    -- to `dir`, so a nested file reads back correctly.
    local handle = assert(io.popen('find ' .. dir .. ' -name "*.lua" 2>/dev/null'))
    local names = {}
    local prefix = dir .. '/'
    for line in handle:lines() do
        local rel = line:sub(1, #prefix) == prefix and line:sub(#prefix + 1) or line:match('([^/]+%.lua)$')
        if rel then names[#names + 1] = rel end
    end
    handle:close()
    table.sort(names)
    return names
end

local SERVER_LUA_FILES = LuaFilesIn('../server')
local CLIENT_LUA_FILES = LuaFilesIn('../client')

-- HIDDEN_ALIAS_COMMANDS (docs/history/COMMAND_CONSOLIDATION_SPEC.md §3) -- old,
-- single-purpose command names that a command-family merge (§5) folded
-- into one new canonical command. Each one is STILL a real, live
-- RegisterCommand(...) call (macros/keybinds/cheat-sheets keep working
-- forever) -- it is simply no longer chat-suggested or tablet-documented,
-- so the "real command with no suggestion" check below must not flag it.
-- A SMALL, EXPLICIT, HAND-MAINTAINED ALLOWLIST, deliberately NOT a
-- wildcard/pattern -- see the "every allowlisted name must still be REAL"
-- test immediately below this table for what stops a genuinely removed
-- command from hiding in here forever instead of being caught.
local HIDDEN_ALIAS_COMMANDS = {
    -- NOT AN ALIAS -- REGISTERED DYNAMICALLY, so the static-table scan
    -- below cannot see it. server/diagnostics.lua's /k9debug IS suggested to
    -- the player, but from client/commandsuggestions.lua's live block at
    -- the bottom of that file rather than from its COMMAND_SUGGESTIONS
    -- table, because its switch is Config.DebugDump.enabled -- not a
    -- Config.Features key, which is the only kind the table's `featureFlag`
    -- field can express. Read that block's own comment before touching
    -- this; the code is right and this entry is the test catching up to it.
    --
    -- Surfaced the moment this spec started enumerating source files from
    -- disk instead of a hand-maintained snapshot: the old list was missing
    -- debugdump.lua entirely (it had been added to
    -- tests/commandreferenceregistry_spec.lua's twin snapshot and not to
    -- this one), so this command was invisible to this guard rather than
    -- exempted by it. Exempting it deliberately, in writing, is the whole
    -- difference.
    k9debug = true,
    -- family #1: audit (5 -> 1, 'k9audit') -- server/admin.lua
    -- family #2: dog record (2 -> 1, 'k9dog') -- server/dogcharacter.lua
    -- family #3: fetch (3 -> 1, 'k9fetch') -- client/fetch.lua
    k9throwfetchball = true,
    k9dropfetchball = true,
    k9recallfetchball = true,
    -- family #5: kennel (ADDITIVE, 'k9kennel') -- client/kennel.lua +
    -- client/keybinds.lua. Unlike every other entry in this table,
    -- k9deploykennel/k9exitkennel are NOT being folded away -- both keep
    -- their own registration forever (RegisterKeyMapping/radial.lua need
    -- the literal name) -- only their chat-suggestion visibility is hidden,
    -- so the player sees one thing (k9kennel) per the project-owner's own
    -- "additive still means the player sees one thing" instruction.
    k9deploykennel = true,
    -- family #7: permissions (2 -> 1, 'k9permission') -- server/permissions.lua
    -- family #8: online/offline certification pairs (10 -> 5) --
    -- server/certifications/. k9certify/k9decertify/k9settier/
    -- k9unspecialize stays its own canonical name (unchanged); k9recertify
    -- was DELETED in the 2026-09-02 merge, not aliased --
    -- joined this table on 2026-09-02 when it merged into /k9certify
    -- and are NOT in this table -- only their *offline counterparts fold
    -- away. k9specialize has no offline counterpart at all and is
    -- untouched.
    -- family #9 (Sensory/vision) -- REVERTED (owner reversal, this pass,
    -- coder-architect): a prior pass had folded
    -- qbx_k9unit:toggleThermalVision/qbx_k9unit:toggleNightVision into a
    -- 'k9vision' cycle and hidden them here. The owner has since asked for
    -- thermal and night vision to be separate, first-class controls again
    -- ("I want the thermal and night vision separate") -- both are chat-
    -- suggested under their own names again (client/commandsuggestions.lua),
    -- so neither belongs in this allowlist anymore. 'k9vision' itself is
    -- KEPT, as an extra optional convenience alongside the two explicit
    -- toggles, not as a replacement for them -- it was never hidden (it IS
    -- the canonical name it names), so it never belonged in this table.
}

--- Identical shape to tests/commandreferenceregistry_spec.lua's own
--- ExtractRegisterCommandNames -- see that file's header "WIDENED, THIS
--- PASS" / "WIDENED TWICE" for why the pattern is `[^']+`, not a narrower
--- character class.
--- @param text string
--- @return table<string, boolean> set
--- Identical shape to tests/commandreferenceregistry_spec.lua's own
--- StripFullLineComments -- see that file for the full WHY (a doc comment in
--- client/hud.lua that wrote `RegisterCommand('...')` inside its own prose
--- made BOTH drift guards report a real, live, undocumented command named
--- `...`) and for why only WHOLE-LINE comments are stripped, never trailing
--- ones.
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

local function ExtractRegisterCommandNames(text)
    local set = {}
    for name in StripFullLineComments(text):gmatch("RegisterCommand%('([^']+)'") do
        set[name] = true
    end
    return set
end

--- @param dir string
--- @param filenames string[]
--- @return table<string, boolean> set
local function RealCommandNamesIn(dir, filenames)
    local set = {}
    for _, filename in ipairs(filenames) do
        local text = ReadFile(dir .. '/' .. filename)
        for name in pairs(ExtractRegisterCommandNames(text)) do
            set[name] = true
        end
    end
    return set
end

--- Extracts every `command = '...'` value inside
--- client/commandsuggestions.lua's own `COMMAND_SUGGESTIONS` table literal,
--- by the same raw-text-pattern technique
--- tests/commandreferenceregistry_spec.lua's own ExtractDocumentedCommandNames
--- uses against html/tablet.js's COMMAND_REFERENCE.
--- @param text string
--- @return table<string, boolean> set
local function ExtractSuggestedCommandNames(text)
    local startPos = text:find('local COMMAND_SUGGESTIONS = {', 1, true)
    assert(startPos, 'local COMMAND_SUGGESTIONS = { not found in client/commandsuggestions.lua -- this file must have changed shape')
    local endPos = text:find('\n}', startPos, true)
    assert(endPos, 'closing "}" for COMMAND_SUGGESTIONS not found in client/commandsuggestions.lua')
    local body = text:sub(startPos, endPos)

    local set = {}
    for name in body:gmatch("command%s*=%s*'([^']+)'") do
        set[name] = true
    end
    return set
end

--- @param set table<string, boolean>
--- @return string[] sortedNames, integer count
local function SortedKeys(set)
    local out = {}
    for key in pairs(set) do out[#out + 1] = key end
    table.sort(out)
    return out, #out
end

t.test('LOAD-BEARING DRIFT GUARD: every real RegisterCommand(...) name across server/*.lua + client/*.lua has a matching entry in client/commandsuggestions.lua\'s COMMAND_SUGGESTIONS, and vice versa', function()
    local realServer = RealCommandNamesIn('../server', SERVER_LUA_FILES)
    local realClient = RealCommandNamesIn('../client', CLIENT_LUA_FILES)
    local real = {}
    for name in pairs(realServer) do real[name] = true end
    for name in pairs(realClient) do real[name] = true end

    local suggested = ExtractSuggestedCommandNames(ReadFile('../client/commandsuggestions.lua'))

    local unsuggested = {}
    for name in pairs(real) do
        -- HIDDEN_ALIAS_COMMANDS (docs/history/COMMAND_CONSOLIDATION_SPEC.md §3): a real,
        -- live command that a family merge deliberately stopped
        -- chat-suggesting is not "undocumented", it's hidden on purpose --
        -- see the allowlist's own header comment and the "every allowlisted
        -- name must still be real" test below for what keeps this from
        -- becoming a laundering mechanism for a genuinely dead command.
        if not suggested[name] and not HIDDEN_ALIAS_COMMANDS[name] then unsuggested[#unsuggested + 1] = name end
    end

    local phantom = {}
    for name in pairs(suggested) do
        if not real[name] then phantom[#phantom + 1] = name end
    end

    if #unsuggested > 0 then
        table.sort(unsuggested)
        error((
            '%d real RegisterCommand(...) name(s) exist in server/*.lua or client/*.lua with NO matching entry in ' ..
            "client/commandsuggestions.lua's COMMAND_SUGGESTIONS: %s.\n\nA player has no chat:addSuggestion for " ..
            'this command at all. FIX THIS BY: adding a { command = \'<name>\', keySuffix = \'<suffix>\' } entry to ' ..
            'COMMAND_SUGGESTIONS in the SAME change that registers the command -- the file list is read from disk, so a ' ..
            'new file is covered automatically and a mismatch here is a real documentation gap, not a stale list. ' ..
            'matching list in this spec instead.'
        ):format(#unsuggested, table.concat(unsuggested, ', ')), 0)
    end

    if #phantom > 0 then
        table.sort(phantom)
        error((
            "%d entr(ies) in client/commandsuggestions.lua's COMMAND_SUGGESTIONS name a command that is NOT a " ..
            'real RegisterCommand(...) call anywhere in server/*.lua or client/*.lua: %s.\n\nEither the command ' ..
            'was renamed/removed and this entry was never updated to match, or it is a typo. FIX THIS BY: deleting ' ..
            'the stale COMMAND_SUGGESTIONS entry, or correcting the spelling.'
        ):format(#phantom, table.concat(phantom, ', ')), 0)
    end

    -- Sanity floor, same "catastrophe detector, not a real limit" reasoning
    -- as tests/commandreferenceregistry_spec.lua's own -- guards against
    -- BOTH extractors silently matching nothing at all (a comment reformat,
    -- a rewritten RegisterCommand/table-literal shape), which would make
    -- the two loops above pass vacuously on two empty sets.
    local _, realCount = SortedKeys(real)
    local _, suggestedCount = SortedKeys(suggested)
    t.isTrue(realCount >= 20, ('sanity: only found %d real RegisterCommand name(s) -- expected at least 20'):format(realCount))
    t.isTrue(suggestedCount >= 20, ('sanity: only found %d COMMAND_SUGGESTIONS entr(ies) -- expected at least 20'):format(suggestedCount))
end)

t.test('HIDDEN_ALIAS_COMMANDS GUARD: every allowlisted name is still a real, live RegisterCommand(...) call somewhere in server/*.lua or client/*.lua', function()
    -- What this catches: a family merge that later deletes an old command
    -- entirely (rather than keeping it as a thin forwarding wrapper) must
    -- be caught by SOME test -- otherwise the allowlist above would quietly
    -- keep excusing a name that no longer does anything, forever, since the
    -- main drift guard above only ever complains about a real command with
    -- no suggestion, never about an allowlisted name that stopped being
    -- real. Deleting my own guard here and re-running (per this task's own
    -- "delete your guard and watch it fail" requirement) is the way to
    -- prove this line actually does something: comment out any one old
    -- '/k9auditxxx' RegisterCommand call in server/admin.lua and this test
    -- goes red while the main drift guard above stays green (since the
    -- allowlist would otherwise silently swallow the gap).
    local realServer = RealCommandNamesIn('../server', SERVER_LUA_FILES)
    local realClient = RealCommandNamesIn('../client', CLIENT_LUA_FILES)
    local real = {}
    for name in pairs(realServer) do real[name] = true end
    for name in pairs(realClient) do real[name] = true end

    local phantomAliases = {}
    for name in pairs(HIDDEN_ALIAS_COMMANDS) do
        if not real[name] then phantomAliases[#phantomAliases + 1] = name end
    end

    if #phantomAliases > 0 then
        table.sort(phantomAliases)
        error((
            '%d name(s) in HIDDEN_ALIAS_COMMANDS are NOT a real RegisterCommand(...) call anywhere in server/*.lua ' ..
            'or client/*.lua: %s.\n\nA genuinely removed command must never keep hiding behind this allowlist -- ' ..
            'FIX THIS BY: removing the stale entry from HIDDEN_ALIAS_COMMANDS (if the command was truly deleted), ' ..
            'or restoring its RegisterCommand call (if it was deleted by mistake).'
        ):format(#phantomAliases, table.concat(phantomAliases, ', ')), 0)
    end
end)

t.test('HIDDEN_ALIAS_COMMANDS names never leak back into COMMAND_SUGGESTIONS (a hidden alias must actually stay hidden, not merely be excused from the "undocumented" check)', function()
    local suggested = ExtractSuggestedCommandNames(ReadFile('../client/commandsuggestions.lua'))

    local leaked = {}
    for name in pairs(HIDDEN_ALIAS_COMMANDS) do
        if suggested[name] then leaked[#leaked + 1] = name end
    end

    if #leaked > 0 then
        table.sort(leaked)
        error((
            '%d name(s) in HIDDEN_ALIAS_COMMANDS still have a COMMAND_SUGGESTIONS entry: %s.\n\nA hidden alias ' ..
            'must not be chat-suggested -- FIX THIS BY: deleting its COMMAND_SUGGESTIONS entry, or removing it ' ..
            'from HIDDEN_ALIAS_COMMANDS if it was actually meant to stay a fully first-class, suggested command.'
        ):format(#leaked, table.concat(leaked, ', ')), 0)
    end
end)

t.test('no duplicate command names within COMMAND_SUGGESTIONS (a copy-pasted entry would silently mask a genuinely missing one)', function()
    local text = ReadFile('../client/commandsuggestions.lua')
    local startPos = text:find('local COMMAND_SUGGESTIONS = {', 1, true)
    local endPos = text:find('\n}', startPos, true)
    local body = text:sub(startPos, endPos)

    local seen = {}
    local duplicates = {}
    for name in body:gmatch("command%s*=%s*'([^']+)'") do
        if seen[name] then duplicates[#duplicates + 1] = name end
        seen[name] = true
    end

    if #duplicates > 0 then
        error('duplicate command entr(ies) in COMMAND_SUGGESTIONS: ' .. table.concat(duplicates, ', '), 0)
    end
end)

-- ============================================================================
-- PART 2: BEHAVIOUR -- load the real file, drive its real dispatcher.
-- ============================================================================

--- @param opts { config: table? }?
--- @return table fixture
local function newFixture(opts)
    opts = opts or {}

    local suggestionCalls = {}
    local function TriggerEvent(eventName, ...)
        suggestionCalls[#suggestionCalls + 1] = { event = eventName, args = { ... } }
    end

    local eventHandlers = {}
    local function AddEventHandler(eventName, handler)
        eventHandlers[eventName] = eventHandlers[eventName] or {}
        eventHandlers[eventName][#eventHandlers[eventName] + 1] = handler
    end
    local function GetCurrentResourceName() return 'qbx_k9unit' end
    local function fireResourceStart(resourceName)
        for _, handler in ipairs(eventHandlers['onResourceStart'] or {}) do
            handler(resourceName)
        end
    end

    local env = Sandbox.newEnv({
        TriggerEvent = TriggerEvent,
        AddEventHandler = AddEventHandler,
        GetCurrentResourceName = GetCurrentResourceName,
    })
    Sandbox.loadInto('../config.lua', env)
    for key, value in pairs(opts.config or {}) do
        env.Config[key] = value
    end
    -- Per-KEY overrides inside an existing sub-table (as opposed to
    -- replacing the whole sub-table, which opts.config does). Needed by the
    -- feature-gate tests below: replacing Config.Features wholesale would
    -- turn off every OTHER feature at the same time and make it impossible
    -- to tell "this one entry was skipped for its own flag" from "the whole
    -- table went quiet."
    for tableName, fields in pairs(opts.configFields or {}) do
        if type(env.Config[tableName]) ~= 'table' then env.Config[tableName] = {} end
        for key, value in pairs(fields) do
            env.Config[tableName][key] = value
        end
    end
    Sandbox.loadInto('../client/commandsuggestions.lua', env)

    return {
        env = env,
        Config = env.Config,
        fireResourceStart = fireResourceStart,
        suggestionCalls = suggestionCalls,
        --- @param command string -- WITHOUT the leading '/'
        --- @return table? call -- { event, args = { name, description, params } }
        findSuggestion = function(command)
            for _, call in ipairs(suggestionCalls) do
                if call.event == 'chat:addSuggestion' and call.args[1] == '/' .. command then
                    return { name = call.args[1], description = call.args[2], params = call.args[3] }
                end
            end
            return nil
        end,
    }
end

t.test('onResourceStart(qbx_k9unit): registers a chat:addSuggestion for every COMMAND_SUGGESTIONS entry, using the SAME description text as html/tablet.js\'s own Commands tab', function()
    local f = newFixture()
    f.fireResourceStart('qbx_k9unit')

    -- Bare, no-arg command.
    local sit = f.findSuggestion('k9sit')
    t.isNotNil(sit, '/k9sit must have a registered suggestion')
    t.equals(sit.description, Sandbox.locale('tablet.cmdref_k9sit_does'), 'k9sit description must match the tablet\'s own Commands tab text verbatim')
    t.equals(#sit.params, 0, 'k9sit takes no arguments -- params must be empty')

    -- Required + optional pair: /k9bonetool <goto|next|...> [value].
    local bonetool = f.findSuggestion('k9bonetool')
    t.isNotNil(bonetool, '/k9bonetool must have a registered suggestion')
    t.equals(#bonetool.params, 2)
    t.equals(bonetool.params[1].help, '', 'a required param carries no "Optional." marker')
    t.equals(bonetool.params[2].name, 'value')
    t.equals(bonetool.params[2].help, 'Optional.', 'an optional param must carry the "Optional." marker')

    -- Admin chat commands are off by default (the tablet does them), so
    -- none of them is suggested.
    for _, admin in ipairs({ 'k9certify', 'k9decertify', 'k9settier', 'k9specialize', 'k9givexp', 'k9permission', 'k9grantpermission', 'k9dog', 'k9audit' }) do
        t.isNil(f.findSuggestion(admin), admin .. ' is admin-only and off by default')
    end

    -- A colon-namespaced keybind-paired command, whose keySuffix is
    -- de-namespaced -- proves the keySuffix indirection actually resolves
    -- to the right locale keys, not just the literal command name.
    local vault = f.findSuggestion('qbx_k9unit:vault')
    t.isNotNil(vault, '/qbx_k9unit:vault must have a registered suggestion')
    t.equals(vault.description, Sandbox.locale('tablet.cmdref_vault_does'))
end)

t.test('onResourceStart(qbx_k9unit): dynamic-name commands (tablet/hq-tablet/compat) are suggested under their REAL, CONFIGURED name, not a hardcoded literal', function()
    local f = newFixture()
    -- Merge onto the real Config.Features/Config.CommandTablet/Config.Compat
    -- rather than replacing either table wholesale (config.lua's own copies
    -- already carry every OTHER flag/field commandsuggestions.lua does not
    -- care about -- this only forces the fields this test actually
    -- exercises).
    f.Config.Features.CommandTablet = true
    f.Config.CommandTablet = { openMode = 'command', command = 'k9customtablet', highCommandCommand = 'k9customhq' }
    f.Config.Compat = { diagnosticCommand = 'k9customcompat' }
    f.fireResourceStart('qbx_k9unit')

    local tablet = f.findSuggestion('k9customtablet')
    t.isNotNil(tablet, 'the tablet command must be suggested under its CONFIGURED name, not the shipped default k9tablet')
    t.isTrue(type(tablet.description) == 'string' and #tablet.description > 0, 'the tablet suggestion must carry a non-empty description')
    t.isNil(f.findSuggestion('k9tablet'), 'the shipped DEFAULT name must NOT also get a suggestion once renamed')

    local hq = f.findSuggestion('k9customhq')
    t.isNotNil(hq, 'the high-command tablet command must be suggested under its CONFIGURED name')

    local compat = f.findSuggestion('k9customcompat')
    t.isNotNil(compat, 'the compat diagnostic command must be suggested under its CONFIGURED name')
end)

t.test('onResourceStart(qbx_k9unit): CommandTablet openMode = \'item\' suppresses the plain tablet command suggestion but NOT the always-on high-command one', function()
    local f = newFixture()
    f.Config.Features.CommandTablet = true
    f.Config.CommandTablet = { openMode = 'item', command = 'k9tablet', highCommandCommand = 'k9hqtablet' }
    f.fireResourceStart('qbx_k9unit')

    t.isNil(f.findSuggestion('k9tablet'), 'openMode = \'item\' means the plain command is never registered by client/tablet.lua itself, so it must not be suggested either')
    t.isNotNil(f.findSuggestion('k9hqtablet'), 'the high-command shortcut is unconditional on openMode, per client/tablet.lua\'s own SECOND ENTRY POINT contract')
end)

t.test('onResourceStart(qbx_k9unit): Config.Features.CommandTablet = false suggests NEITHER tablet command, mirroring client/tablet.lua\'s own file-level early return', function()
    local f = newFixture()
    f.Config.Features.CommandTablet = false
    f.fireResourceStart('qbx_k9unit')

    t.isNil(f.findSuggestion('k9tablet'))
    t.isNil(f.findSuggestion('k9hqtablet'))
end)

t.test('onResourceStart(qbx_k9unit): Config.Compat.diagnosticCommand = false suggests no compat command, mirroring shared/compat/core.lua\'s own "false means disabled" contract', function()
    local f = newFixture()
    f.Config.Compat = { diagnosticCommand = false }
    f.fireResourceStart('qbx_k9unit')

    t.isNil(f.findSuggestion('k9compat'))
end)

t.test('onResourceStart fires for THIS resource and for a "chat" resource restarting, never for an unrelated resource', function()
    local f = newFixture()
    t.equals(#f.suggestionCalls, 0, 'nothing registered before onResourceStart ever fires')

    f.fireResourceStart('some_other_resource')
    t.equals(#f.suggestionCalls, 0, 'an unrelated resource starting must not trigger registration')

    f.fireResourceStart('chat')
    t.isTrue(#f.suggestionCalls > 0, 'a "chat" resource (re)starting must (re-)trigger registration, so a stock chat resource restarting independently does not lose every suggestion this resource ever sent it')
end)

t.test('re-firing onResourceStart is safe -- calls TriggerEvent again for every command with no error, never accumulates state of its own', function()
    local f = newFixture()
    f.fireResourceStart('qbx_k9unit')
    local firstCount = #f.suggestionCalls
    t.isTrue(firstCount > 20, 'sanity: the first pass actually registered a realistic number of suggestions')

    local ok = pcall(f.fireResourceStart, 'qbx_k9unit')
    t.isTrue(ok, 're-firing onResourceStart must not throw')
    t.equals(#f.suggestionCalls, firstCount * 2, 'a second pass calls TriggerEvent again for every command (this file itself holds no dedup state -- the real chat resource\'s own addSuggestion is what replaces-by-name, per this file\'s own header "RE-REGISTRATION SAFETY")')
end)


-- ========================================================================
-- FEATURE-GATED SUGGESTIONS (QA finding, this pass). Every command in
-- COMMAND_SUGGESTIONS carrying a `featureFlag` lives in a file whose own
-- top-level guard is `if not Config.Features.<flag> then return end` -- a
-- FILE-LEVEL early return, so with the flag off that file's RegisterCommand
-- never executes and the command is not registered at all. Advertising it
-- in chat autocomplete then promises something typing it cannot deliver.
-- ========================================================================
t.test('DEAD COMMAND, LIVE ON THE SHIPPED CONFIG: /k9nosehunt is no longer advertised -- Config.Features.ScentTrailHunt was deliberately removed from config.lua, so the client file that used to own it returned at its top and never registered the command on any client', function()
    local f = newFixture()
    f.fireResourceStart('qbx_k9unit')

    t.isNil(f.Config.Features.ScentTrailHunt, 'precondition: the flag really is absent from the shipped config, not merely false')
    t.isNil(f.findSuggestion('k9nosehunt'), 'a command no client ever registers must not appear in autocomplete')
end)

t.test('A REMOVED KEY (nil) SKIPS, not just an explicit false -- nil is the actual shipped ScentTrailHunt case, and `== false` would have missed it entirely', function()
    local f = newFixture()
    -- FetchMechanic ships true, so prove the nil path directly by clearing
    -- it: the gate reads `Config.Features[flag] == true`, which is false for
    -- nil exactly as it is for an explicit false. A `~= false` test would
    -- have passed here and still shipped the bug.
    f.Config.Features.FetchMechanic = nil
    f.fireResourceStart('qbx_k9unit')
    t.isNil(f.findSuggestion('k9fetch'))
end)

t.test('THE SAME PROTECTION COVERS EVERY OTHER GATED FAMILY, not just the one that was broken -- turning a feature off stops advertising all of its commands', function()
    local f = newFixture({ configFields = { Features = { FetchMechanic = false, VehicleEntryExit = false, HandlerPartnership = false } } })
    f.fireResourceStart('qbx_k9unit')

    t.isNil(f.findSuggestion('k9fetch'))
    t.isNil(f.findSuggestion('k9throwfetchball'))
    t.isNil(f.findSuggestion('k9vehicle'))
    t.isNil(f.findSuggestion('k9partner'))
end)

t.test('CONTROL: an UNGATED command is still advertised while other features are off -- proves the skip is per-entry and did not simply silence the whole table', function()
    local f = newFixture({ configFields = { Features = { FetchMechanic = false } } })
    f.fireResourceStart('qbx_k9unit')

    t.isNotNil(f.findSuggestion('k9bitehold') or f.findSuggestion('k9track'),
        'at least one ungated command must still be suggested')
end)

t.test('CONTROL: with a gated feature ON, its commands ARE advertised -- proves these tests can tell the two states apart', function()
    local f = newFixture({ configFields = { Features = { FetchMechanic = true } } })
    f.fireResourceStart('qbx_k9unit')

    t.isNotNil(f.findSuggestion('k9fetch'), 'FetchMechanic on must advertise /k9fetch')
end)

t.test('/k9debug follows the same rule through a DIFFERENT switch: server/diagnostics.lua returns at its top unless Config.DebugDump.enabled is exactly true, and that is not a Config.Features key', function()
    local off = newFixture({ configFields = { DebugDump = { enabled = false } } })
    off.fireResourceStart('qbx_k9unit')
    t.isNil(off.findSuggestion('k9debug'), 'ships off, so the command is never registered -- do not advertise it')

    local on = newFixture({ configFields = { DebugDump = { enabled = true } } })
    on.fireResourceStart('qbx_k9unit')
    t.isNotNil(on.findSuggestion('k9debug'), 'switched on, the command really is registered and should be discoverable')
end)

os.exit(t.summary())
