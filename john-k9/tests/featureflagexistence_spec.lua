--[[
    tests/featureflagexistence_spec.lua

    ONE GUARANTEE: every `Config.Features.<Name>` that real code gates on
    either EXISTS in the shipped config.lua, or is on the small allowlist
    below of keys that are absent on purpose.

    WHY THIS FILE EXISTS. A feature flag that code reads but config never
    defines resolves to `nil`. `if not Config.Features.Foo then return end`
    then fires on every client, forever, and the entire feature goes dark --
    silently. No error, no warning, no failing test. luacheck cannot see it
    (a table lookup is valid Lua whatever the key). server/diagnostics.lua
    catches the OPPOSITE direction (a config key nothing recognises) but not
    this one. Every spec in this suite that touches feature flags builds its
    own fixture Config, so none of them read the shipped file to find out
    whether the key is really there.

    That gap was found the honest way: a maintenance pass resolved every
    `Config.*` path referenced anywhere in client/ and server/ against the
    real config table and found `Config.Features.ScentTrailHunt` missing --
    which turned out to be INTENTIONAL (the feature was removed
    owner-approved as redundant; see Config.Features' own "REMOVED" block).
    But nothing anywhere distinguished "deliberately removed" from
    "renamed/typo'd last week and now silently dead", and the second case
    looks exactly like the first from the outside.

    WHAT MAKES THIS A REAL GUARD AND NOT A RESTATEMENT. The allowlist is
    the whole point. Adding a key to it is a deliberate, reviewable act with
    a written reason; forgetting to define a flag you just started gating on
    is not. So a rename that kills a feature goes RED here, while an
    intentional removal stays green only once someone says so in writing.

    The allowlist is also checked in the other direction: an entry that is
    no longer absent (someone restored the flag) fails too, so this file
    cannot rot into a list of stale exemptions that quietly permits real
    breakage.

    WHY THIS CHECKS THE RESOLVED TABLE, NOT THE LITERAL IN config.lua.
    Config.Features is not the last word on its own contents: the
    FeatureGroups resolution at the bottom of config.lua WRITES BACK into
    it, both for family children (`Config.Features[flatName] = enabled`)
    and for standalone/base keys (`Tablet = { base = 'CommandTablet' }`
    means Config.FeatureGroups.Tablet.enabled decides
    Config.Features.CommandTablet, whatever the literal above says).

    So for any grouped flag, the literal in the Config.Features table is
    only a pre-grouping default -- config.lua keeps the originals in
    Config.FeaturesBeforeGrouping precisely because they are not the final
    answer. Renaming such a key in the literal table does NOT kill the
    feature; the resolver puts it straight back, and the feature keeps
    working. That is correct behaviour and this test must not flag it.

    Loading the real config and reading what survives resolution is
    therefore the only check that matches what a running server actually
    sees. Found the hard way: an early version of this file was
    "red-proven" by renaming a flag in the literal table, stayed green, and
    looked broken -- it was measuring the right thing all along.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

--- Keys that real code gates on and config.lua deliberately does NOT
--- define. Each entry must say why, and must be a decision someone
--- actually made -- never a parking space for "we'll get to it".
---
--- A nil flag means the feature is OFF, not broken: every consumer of these
--- keys is written to no-op cleanly when the lookup returns nil (that is
--- what makes the removal safe in the first place). If you add a key here,
--- confirm that is true of its consumers before you do.
local INTENTIONALLY_ABSENT = {
}

--- Every distinct `Config.Features.<Name>` referenced from real source.
--- Reads the files off disk rather than taking a curated list, which is the
--- only version of this test worth having: a hand-maintained list would
--- need updating by the same person who forgot to define the flag.
---
--- Scans client/ and server/ only. Deliberately NOT tests/ (fixtures invent
--- flag names freely, by design) and NOT config.lua itself (its own
--- FeatureGroups map and prose mention names that are not gates).
---
--- Comments are stripped before matching -- see the note inside.
--- @return table<string, string[]> name -> list of "file:line" citations
local function ReferencedFeatureFlags()
    local found = {}

    local listing = assert(io.popen('ls ../client/*.lua ../server/*.lua 2>/dev/null'))
    local paths = {}
    for line in listing:lines() do paths[#paths + 1] = line end
    listing:close()

    for _, path in ipairs(paths) do
        local handle = io.open(path, 'r')
        if handle then
            local text = handle:read('a')
            handle:close()

            -- STRIP COMMENTS BEFORE MATCHING, both kinds, and block
            -- comments FIRST. This is the difference between a guard and a
            -- noise generator: this codebase's doc-comments are enormous
            -- and routinely NAME feature flags while discussing them, and
            -- several use `Config.Features.X` as a literal placeholder in
            -- prose. A scan that misses block comments reports those as
            -- undefined flags, which is exactly how a test like this gets
            -- muted by the first person who trusts it.
            --
            -- Long-bracket forms (--[[ ]], --[==[ ]==]) are handled by
            -- level, so a nested example inside a comment cannot end it
            -- early. Line comments go second, once block spans are gone.
            -- NEWLINES ARE PRESERVED when a span is removed, so the line
            -- numbers in the citations below stay true to the real file.
            -- Collapsing a 40-line block comment to one space renumbers
            -- everything after it, and this test's whole output is a list
            -- of "go look at file:line" pointers -- sending someone to the
            -- wrong line is most of the way to sending them nowhere.
            -- The pattern captures the WHOLE match as capture 1, because
            -- gsub hands a replacement function its CAPTURES, never the
            -- match itself. An earlier attempt captured only the bracket
            -- level `(=*)`, so the function received an empty string,
            -- returned an empty string, and silently deleted every newline
            -- it was written to preserve -- the fix looked applied and
            -- changed nothing. Caught by re-reading the emitted citations
            -- rather than trusting the edit.
            local function blankKeepingLines(whole)
                return (whole:gsub('[^\n]', ''))
            end
            text = text:gsub('(%-%-%[(=*)%[.-%]%2%])', blankKeepingLines)
            text = text:gsub('%-%-[^\n]*', '')

            local lineNo = 1
            for line in (text .. '\n'):gmatch('([^\n]*)\n') do
                for name in line:gmatch('Config%.Features%.([A-Za-z0-9_]+)') do
                    found[name] = found[name] or {}
                    local citation = path:gsub('^%.%./', '') .. ':' .. lineNo
                    local already = false
                    for _, c in ipairs(found[name]) do
                        if c == citation then already = true break end
                    end
                    if not already then found[name][#found[name] + 1] = citation end
                end
                lineNo = lineNo + 1
            end
        end
    end

    return found
end

local env = Sandbox.newEnv({ print = function() end })
Sandbox.loadInto('../config.lua', env)
local shipped = env.Config and env.Config.Features

t.test('sanity: the real config.lua loads and Config.Features is a populated table', function()
    -- Without this, every assertion below would pass vacuously against an
    -- empty table -- the exact failure mode a guard like this must not have.
    t.equals(type(shipped), 'table')
    local count = 0
    for _ in pairs(shipped) do count = count + 1 end
    t.isTrue(count > 40, 'expected the full shipped flag set, got ' .. tostring(count) .. ' keys')
end)

t.test('sanity: the scan finds real gates, so a silent scan failure cannot make this file pass vacuously', function()
    local refs = ReferencedFeatureFlags()
    local count = 0
    for _ in pairs(refs) do count = count + 1 end
    t.isTrue(count > 30,
        'expected to find Config.Features.<Name> references across client/ and server/, found ' .. tostring(count)
        .. ' -- if this dropped to zero the grep or the paths are wrong and every check below is meaningless')
end)

t.test('every Config.Features flag that code gates on is DEFINED in the shipped config.lua', function()
    local refs = ReferencedFeatureFlags()
    local missing = {}

    for name, citations in pairs(refs) do
        if shipped[name] == nil and INTENTIONALLY_ABSENT[name] == nil then
            missing[#missing + 1] = name .. ' (read at ' .. table.concat(citations, ', ') .. ')'
        end
    end
    table.sort(missing)

    t.equals(#missing, 0,
        'These Config.Features keys are gated on in real code but do not exist in config.lua, so they read nil '
        .. 'and every feature behind them is silently OFF on a stock install:\n  - '
        .. table.concat(missing, '\n  - ')
        .. '\nIf that is a mistake (a rename, a typo, a flag someone forgot to add), define the key in '
        .. 'config.lua. If it is deliberate, add it to INTENTIONALLY_ABSENT at the top of this file with the '
        .. 'reason -- that is the whole point of this test: making the difference between the two explicit.')
end)

t.test('every INTENTIONALLY_ABSENT entry is still genuinely absent -- the allowlist cannot rot into stale exemptions', function()
    local stale = {}
    for name in pairs(INTENTIONALLY_ABSENT) do
        if shipped[name] ~= nil then stale[#stale + 1] = name end
    end
    table.sort(stale)

    t.equals(#stale, 0,
        'These keys are on the INTENTIONALLY_ABSENT allowlist but config.lua now DOES define them: '
        .. table.concat(stale, ', ')
        .. '. The feature was restored -- remove the allowlist entry so this file goes back to actually '
        .. 'guarding it, rather than carrying a permanent exemption nobody re-reads.')
end)

t.test('every INTENTIONALLY_ABSENT entry is still referenced by real code -- an exemption for a key nothing reads is dead weight', function()
    local refs = ReferencedFeatureFlags()
    local orphaned = {}
    for name in pairs(INTENTIONALLY_ABSENT) do
        if refs[name] == nil then orphaned[#orphaned + 1] = name end
    end
    table.sort(orphaned)

    t.equals(#orphaned, 0,
        'These keys are allowlisted as intentionally absent, but no code in client/ or server/ gates on them '
        .. 'any more: ' .. table.concat(orphaned, ', ')
        .. '. The consuming code was deleted or renamed; drop the allowlist entry too.')
end)

t.test('every INTENTIONALLY_ABSENT entry carries a real written reason, not a placeholder', function()
    -- An allowlist whose entries say "TODO" would pass every check above
    -- while defeating the purpose of having one.
    for name, reason in pairs(INTENTIONALLY_ABSENT) do
        t.equals(type(reason), 'string', name .. ' must have a string reason')
        t.isTrue(#reason >= 60,
            name .. "'s reason is too short to be a real justification -- say what was decided and where it is "
            .. 'written down, so the next reader does not have to re-derive it')
        t.isFalse(reason:upper():find('TODO', 1, true) ~= nil, name .. "'s reason is a placeholder, not a decision")
    end
end)

-- ======================================================================
-- SHIPPED DEFAULT: Config.Database.enabled
--
-- Pinned here because nothing else pinned it, and the whole suite stayed
-- green when the default was flipped -- every datastore test builds its
-- own fixture Config (correctly: it tests BOTH backends), so none of them
-- read the shipped file. A default this consequential should not be
-- changeable without a test saying so out loud.
--
-- It is not a correctness constraint. Both values are fully supported and
-- exercised: server/datastore.lua's K9Store has one branch per function
-- and tests/datastore_spec.lua runs both. This is a "say it deliberately"
-- guard on a product decision, in the same spirit as INTENTIONALLY_ABSENT
-- above.
-- ======================================================================

t.test('Config.Database.enabled ships FALSE -- the resource is drag-and-drop out of the box', function()
    t.equals(type(env.Config.Database), 'table', 'the Config.Database block must exist at all')
    t.isFalse(env.Config.Database.enabled,
        'The shipped default was deliberately set to false so the resource runs with no .sql import: drop it in, '
        .. 'start it, everything works. If you are flipping this to true, that is a real product decision -- the '
        .. 'trade is that with it OFF nothing survives a restart (certifications, XP, partnerships, permissions, '
        .. 'callsigns, themes) and no audit trail is written at all. Update this test, config.lua\'s own '
        .. 'Config.Database block, README.md\'s Installing section, and sql/DATABASE_GUIDE.md together -- all four '
        .. 'state the default in prose and will otherwise contradict each other.')
end)

t.test('DatabaseEnabled fails SAFE to true on a missing Config.Database -- an operator who deletes the block gets persistence, not silent data loss', function()
    -- The one asymmetry worth pinning about this flag: only a LITERAL
    -- false turns the database off. A missing or malformed block means
    -- "on", so a config edit that accidentally removes it cannot quietly
    -- stop writing everyone's progress to disk -- the failure mode is a
    -- loud missing-table error, never silent amnesia.
    local probe = Sandbox.newEnv({ print = function() end })
    Sandbox.loadInto('../config.lua', probe)
    probe.Config.Database = nil

    local store = Sandbox.newEnv({ Config = probe.Config, MySQL = {}, print = function() end })
    Sandbox.loadInto('../server/datastore.lua', store)
    t.isTrue(store.K9Store.IsDatabaseEnabled(),
        'with Config.Database absent entirely, the store must report ENABLED -- failing safe toward persistence')
end)

t.test('DRAG-AND-DROP IS REAL: with the shipped config, NO K9Store function touches MySQL at all', function()
    -- The guarantee the shipped default rests on. server/datastore.lua's
    -- architecture is "one `if DatabaseEnabled() then <SQL> else <memory>
    -- end` branch per function" -- 100+ functions, each of which has to
    -- remember the branch. One function added without it would issue a
    -- real query on a server that has no tables, and the operator would
    -- see a missing-table error for a feature they never set up.
    --
    -- Rather than eyeball 100+ branches, this hands the store a MySQL
    -- object that ERRORS on any field access whatsoever and then calls
    -- every function it exposes. Nothing may reach it.
    local cfgEnv = Sandbox.newEnv({ print = function() end })
    Sandbox.loadInto('../config.lua', cfgEnv)
    t.isFalse(cfgEnv.Config.Database.enabled, 'sanity: this test only means something with the DB off')

    local touched = {}
    local trapMySQL = setmetatable({}, { __index = function(_, key)
        touched[#touched + 1] = tostring(key)
        error('MySQL.' .. tostring(key) .. ' was accessed with the database OFF', 2)
    end })

    local store = Sandbox.newEnv({ Config = cfgEnv.Config, MySQL = trapMySQL, print = function() end })
    Sandbox.loadInto('../server/datastore.lua', store)

    local names = {}
    for name, value in pairs(store.K9Store) do
        if type(value) == 'function' then names[#names + 1] = name end
    end
    table.sort(names)
    t.isTrue(#names > 90, 'sanity: expected the full K9Store surface, found ' .. #names)

    -- Benign args. A function that rejects them returns early or raises on
    -- its own arithmetic -- either way it has already passed the branch
    -- point, which is the only thing being measured here.
    for _, name in ipairs(names) do
        pcall(store.K9Store[name], 'CID_TEST', 'police', 1)
    end

    t.equals(#touched, 0,
        'These MySQL fields were accessed with Config.Database.enabled = false: ' .. table.concat(touched, ', ')
        .. '. A K9Store function is missing its `if DatabaseEnabled() then ... else ... end` branch, so a '
        .. 'drag-and-drop server with no tables would hit a real query. Add the memory-mode branch.')
end)

t.test('DRAG-AND-DROP IS REAL: memory mode actually REMEMBERS within the session -- it is not a silent no-op', function()
    -- The other half, and the easier one to get wrong: a store that
    -- discarded every write would also pass the test above. Memory mode
    -- has to behave like a database that simply forgets on restart, not
    -- like a black hole -- otherwise XP is unearnable rather than
    -- unsaved, and the mode is broken in a way nobody notices until a
    -- player asks why their rank never moves.
    local cfgEnv = Sandbox.newEnv({ print = function() end })
    Sandbox.loadInto('../config.lua', cfgEnv)
    local store = Sandbox.newEnv({ Config = cfgEnv.Config, MySQL = {}, print = function() end })
    Sandbox.loadInto('../server/datastore.lua', store)
    local K9 = store.K9Store

    t.isNil(K9.XP_Get('CID_FRESH'), 'a citizenid with no history reads as nil, exactly as it would from an empty table')

    K9.XP_UpsertAdd('CID_FRESH', 25)
    t.equals(K9.XP_Get('CID_FRESH'), 25, 'a write must be readable back in the same session')
    K9.XP_UpsertAdd('CID_FRESH', 10)
    t.equals(K9.XP_Get('CID_FRESH'), 35, 'and must ACCUMULATE, not overwrite')

    K9.HandlerXP_UpsertAdd('CID_FRESH', 10)
    t.equals(K9.HandlerXP_Get('CID_FRESH'), 10, 'the handler ladder is stored independently of the K9 one')
    t.equals(K9.XP_Get('CID_FRESH'), 35, 'and writing one must not disturb the other')
end)

t.test('MEMORY MODE KEEPS AN AUDIT TRAIL -- capped and session-scoped, but genuinely there', function()
    -- Pinned because the documentation said the exact opposite in four
    -- places at once ("no record of who certified whom, no search log, no
    -- permission-grant history... not a smaller record. None."). It was
    -- wrong, and it mattered: it would have talked an operator out of
    -- checking a dispute they could actually have checked.
    --
    -- The real limits are different and smaller -- capped, and lost on
    -- restart -- and that is what the docs now say. This test is what stops
    -- either claim drifting again.
    local cfgEnv = Sandbox.newEnv({ print = function() end })
    Sandbox.loadInto('../config.lua', cfgEnv)
    local store = Sandbox.newEnv({ Config = cfgEnv.Config, MySQL = {}, print = function() end })
    Sandbox.loadInto('../server/datastore.lua', store)
    local K9 = store.K9Store
    t.isFalse(K9.IsDatabaseEnabled(), 'sanity: memory mode')

    K9.Cert_Insert('CID_AUDIT', 'police', 'GRANTER1', nil)
    t.equals(#K9.Cert_GetHistory('CID_AUDIT', 10), 1, 'certification history is recorded and readable')

    K9.SearchLog_Insert('CID_AUDIT', 'police', 'vehicle', 'PLATE1', nil, 'clean', 0, nil)
    t.equals(#K9.SearchLog_GetRecent(10), 1, 'the search log is recorded and readable')
    t.equals(#K9.SearchLog_GetByOfficer('CID_AUDIT', 10), 1, 'and is queryable by officer, as the tablet does')

    K9.OverrideAudit_Append('FeatureX', 'grant', 'ADMIN1', 'Chief', 'reason')
    t.equals(#K9.OverrideAudit_GetRecent(10), 1, 'the override audit is recorded and readable')
end)

t.test('MEMORY MODE audit growth is CAPPED, so a long-running drag-and-drop server cannot leak memory through it', function()
    -- The other half of the corrected claim, and the reason "capped" is
    -- the honest word rather than "complete". With the database off now
    -- being the shipped default, an unbounded audit table would be a slow
    -- memory leak on exactly the servers least likely to notice.
    local cfgEnv = Sandbox.newEnv({ print = function() end })
    Sandbox.loadInto('../config.lua', cfgEnv)
    local store = Sandbox.newEnv({ Config = cfgEnv.Config, MySQL = {}, print = function() end })
    Sandbox.loadInto('../server/datastore.lua', store)
    local K9 = store.K9Store

    for i = 1, 520 do
        K9.SearchLog_Insert('CID_CAP', 'police', 'vehicle', 'P' .. i, nil, 'clean', 0, nil)
    end

    -- Asked for far more than the cap, so the number returned is the
    -- store's own ceiling rather than the query limit.
    t.equals(#K9.SearchLog_GetRecent(100000), 500,
        'the search log must stop at its 500-row memory cap, discarding oldest-first, not grow without bound')
end)

t.test('DRAG-AND-DROP IS REAL: every table the schema creates has a memory-mode gate, so no feature is SQL-only', function()
    -- The structural half of the drag-and-drop guarantee. The other tests
    -- above prove no K9Store function reaches MySQL and that memory mode
    -- remembers -- but both only cover tables K9Store already knows about.
    -- A table added to sql/install.sql with a real-SQL accessor and no
    -- memory branch would slip past them entirely: its own feature would
    -- query a table the operator never created, on the SHIPPED default,
    -- and fail for them alone.
    --
    -- So this walks the schema itself and requires each table to be gated
    -- somewhere. Almost all of them are gated inside server/datastore.lua;
    -- k9_dog_characters is a disclosed exception gated in
    -- server/dogcharacter.lua instead (that file could not edit datastore
    -- when the table was added, and uses the same public
    -- K9Store.IsDatabaseEnabled(tableName) check). Both shapes count --
    -- what must never happen is a table gated NOWHERE.
    local function stripComments(text)
        text = text:gsub('(%-%-%[(=*)%[.-%]%2%])', function(w) return (w:gsub('[^\n]', '')) end)
        return (text:gsub('%-%-[^\n]*', ''))
    end

    local function readStripped(path)
        local handle = assert(io.open(path, 'r'), 'could not open ' .. path)
        local text = handle:read('a')
        handle:close()
        return stripComments(text)
    end

    local schema = readStripped('../sql/install.sql')
    -- `[%w_]+`, NOT `%w+`: Lua's %w is alphanumeric and does NOT include
    -- the underscore, so `k9_%w+` matched only single-underscore names and
    -- silently found 17 of the 28 tables. The sanity assertion below is
    -- what caught it -- without it this test would have passed while
    -- checking well under half the schema.
    local tables = {}
    for name in schema:gmatch('CREATE TABLE%s+IF NOT EXISTS%s+`?(k9_[%w_]+)`?') do tables[name:lower()] = true end
    for name in schema:gmatch('CREATE TABLE%s+`?(k9_[%w_]+)`?') do tables[name:lower()] = true end

    local sorted = {}
    for name in pairs(tables) do sorted[#sorted + 1] = name end
    table.sort(sorted)
    t.isTrue(#sorted >= 25, 'sanity: expected the full shipped schema, found ' .. #sorted .. ' k9_ tables')

    -- Every server file may hold a gate, not just datastore.lua -- see the
    -- k9_dog_characters exception above.
    local listing = assert(io.popen('ls ../server/*.lua 2>/dev/null'))
    local gateText = {}
    for path in listing:lines() do gateText[#gateText + 1] = readStripped(path) end
    listing:close()
    local allServer = table.concat(gateText, '\n')

    local ungated = {}
    for _, name in ipairs(sorted) do
        if not allServer:find("DatabaseEnabled('" .. name .. "')", 1, true) then
            ungated[#ungated + 1] = name
        end
    end

    t.equals(#ungated, 0,
        'These tables exist in sql/install.sql but nothing anywhere calls DatabaseEnabled(\'<table>\') for them: '
        .. table.concat(ungated, ', ')
        .. '. On the shipped default (Config.Database.enabled = false) their feature would query a table the '
        .. 'operator never created. Add the memory-mode branch, gated per-table, in server/datastore.lua -- or, '
        .. 'if that file genuinely cannot own it, via K9Store.IsDatabaseEnabled(\'<table>\') where it does live, '
        .. 'the way server/dogcharacter.lua does.')
end)


-- ======================================================================
-- STATUS CLAIMS: a comment that says what a flag SHIPS AS must be right
--
-- FOUND BY THIS CHECK, 2026-08-31: server/tenure.lua's header stated
-- "config.lua carries `Config.Features.PartnershipTenureBonus = false`
-- (still off by default...)". It ships TRUE (config.lua:362), and has for
-- some time -- the flag was flipped on and the header was not updated. So
-- the file that OWNS the tenure bonus told anyone reading it the feature
-- was inert, while it was quietly awarding 15/40/100 XP at the 1/7/30-day
-- milestones. An owner auditing why their XP economy pays out more than
-- expected would read that and rule it out.
--
-- WHY THIS IS NARROW ON PURPOSE. Only sentences that ASSERT a default are
-- checked -- "ships", "by default", "defaults to", "off by default". A bare
-- `Config.X = false` in a comment is almost always conditional prose ("the
-- Config.Features.RadialMenu=false path") or an instruction to the operator
-- ("Set `Config.Database.enabled = true`"), both correct and neither a
-- claim. A first draft of this check without that filter reported 24
-- disagreements, every one of them a false positive.
-- ======================================================================

t.test('every comment that asserts what a config flag SHIPS AS matches the shipped value', function()
    local shippedConfig = env.Config
    t.isNotNil(shippedConfig, 'shipped Config must load')

    --- Flattens Config into dotted paths -> stringified scalar values.
    local flat = {}
    local function flatten(tbl, prefix)
        for key, value in pairs(tbl) do
            local path = prefix .. '.' .. tostring(key)
            if type(value) == 'table' then
                flatten(value, path)
            elseif type(value) == 'boolean' then
                flat[path] = tostring(value)
            end
        end
    end
    flatten(shippedConfig, 'Config')

    local STATUS_WORDS = {
        'ships', 'shipped', 'by default', 'defaults to', 'default is',
        'off by default', 'on by default', 'still off', 'still on',
    }
    local function assertsADefault(text)
        local lowered = text:lower()
        for _, word in ipairs(STATUS_WORDS) do
            if lowered:find(word, 1, true) then return true end
        end
        return false
    end

    local files = {}
    local pipe = io.popen([[cd .. && find client server shared -name '*.lua' | sort]])
    if pipe then
        for line in pipe:lines() do files[#files + 1] = line end
        pipe:close()
    end
    t.isTrue(#files > 50, ('expected >50 lua files to scan, found %d'):format(#files))

    local wrong = {}
    for _, rel in ipairs(files) do
        local fh = io.open('../' .. rel, 'r')
        if fh then
            local lines = {}
            for line in fh:lines() do lines[#lines + 1] = line end
            fh:close()
            -- BLOCK COMMENTS COUNT TOO. The first draft of this check only
            -- matched `^%s*%-%-` line comments, and stayed GREEN against the
            -- very defect that motivated it: server/tenure.lua's wrong claim
            -- lives inside a `--[[ ]]` header block, whose lines start with
            -- plain text. Caught by running the check against the reverted
            -- defect instead of trusting a passing run.
            local inBlock = false
            for i, line in ipairs(lines) do
                local opensBlock = line:find('%-%-%[%[')
                local closesBlock = line:find('%]%]')
                local isComment = inBlock or line:match('^%s*%-%-') ~= nil
                if opensBlock and not closesBlock then inBlock = true end
                if closesBlock then inBlock = false end
                if isComment then
                    -- Neighbour lines included: these are wrapped comment
                    -- blocks, so the asserting phrase and the flag routinely
                    -- sit on different lines.
                    local ctx = table.concat({ lines[i - 1] or '', line, lines[i + 1] or '' }, ' ')
                    if assertsADefault(ctx) then
                        for path, claimed in line:gmatch('(Config%.[%a_][%w_.]*)%s*=%s*`?(%a+)`?') do
                            if (claimed == 'true' or claimed == 'false')
                                and flat[path] ~= nil and flat[path] ~= claimed then
                                wrong[#wrong + 1] = ('%s:%d  %s -- comment says %s, ships %s')
                                    :format(rel, i, path, claimed, flat[path])
                            end
                        end
                    end
                end
            end
        end
    end
    table.sort(wrong)
    t.equals(#wrong, 0,
        'these comments state a shipped default that is wrong:\n    ' .. table.concat(wrong, '\n    ') ..
        '\n  Fix the sentence to match config.lua, or reword it so it is not asserting a default.')
end)


-- ======================================================================
-- THE K9 IS ALWAYS A REAL PLAYER, NEVER AN NPC
--
-- This server's single standing rule about dogs, restated by the owner
-- across sessions: every K9 is a person playing one. No NPC fallback, ever.
--
-- FOUND BY THIS CHECK, 2026-08-31: Config.K9EquipmentShop.pedModel shipped
-- as 'a_c_shepherd' -- the first entry in Config.Peds -- with pedScenario
-- 'WORLD_DOG_SITTING_SHEPHERD'. The K9 supply point had an NPC German
-- Shepherd sitting at it. config.lua argued the ped was "a shop attendant,
-- not a K9", but that distinction only exists in the config file: to a
-- player it is a dog that is not a person, standing exactly where K9
-- handlers gather. Now a uniformed quartermaster.
--
-- WHAT THIS GUARDS, precisely: any ped this resource SPAWNS as scenery must
-- not use a model that Config.Peds lists as a K9. It does not care what
-- model a real K9 player wears -- that is the whole point of Config.Peds
-- and is checked nowhere here.
-- ======================================================================

-- ========================================================================
-- COMMENT ROT GUARD -- every Config.<Something> path a COMMENT names must
-- still resolve in the real, shipped config.
-- ========================================================================
--
-- WHY THIS EXISTS. The citation guard (tests/citationintegrity_spec.lua)
-- checks that every FILE PATH a comment names exists on disk, and it works
-- -- it caught the merged-away diagnostics files within minutes. Nothing
-- checked that a CONFIG BLOCK a comment names still exists. That is how
-- four comments describing `Config.Recall` as a live setting survived three
-- separate removal sweeps: one of them listed it in config.lua's own table
-- of contents, and two told a reader that features deleted at the owner's
-- request were "now built and consuming" the partnership registry. They
-- were found by hand, and partly by luck.
--
-- A comment that names a config block that no longer exists is worse than
-- no comment: it sends a reader looking for a setting they will never find,
-- and it reads as current documentation rather than as history.
--
-- HISTORY IS STILL ALLOWED, and often valuable -- "the since-removed recall
-- feature hit this same footgun" is a real lesson. The rule is only that
-- history must not be written as a live path. Say what happened in prose;
-- do not name `Config.Thing` as though a reader could go look at it.
--
-- SCOPE. Lua comments in config.lua, client/, server/ and shared/. Only
-- top-level `Config.<Name>` blocks are resolved -- deeper paths
-- (`Config.XP.searchFind`) are not walked, because a comment naming a
-- sub-key that moved is a much weaker signal than one naming a whole block
-- that is gone, and walking them would trade this guard's precision for
-- noise. `Config.Features.<Flag>` is covered by the tests above.

--- Names a comment may use that are not real config blocks, each with a
--- written reason -- same convention, and same anti-rot checks, as
--- INTENTIONALLY_ABSENT above.
local COMMENT_CONFIG_ALLOWLIST = {
    X                      = 'generic placeholder in server/cooldowns.lua prose ("Config.X = 0"), never a real block',
    Y                      = 'generic placeholder in server/cooldowns.lua prose, never a real block',
    lua                    = 'the string "Config.lua" -- the filename with a capital C at the start of a sentence, not a table path',
    Diagnostics            = 'named in server/diagnostics.lua only to say the block is NOT called this, as the example of a rename that would silently disable the feature',
    FeaturesBeforeGrouping = 'real, but created at runtime by ResolveFeatureGroups rather than authored in config.lua, so it never appears as a `Config.X =` assignment',
    K9DespawnGraceSeconds  = 'explicitly described as an earlier draft that was superseded -- config.lua and server/certifications/ both say so in the same sentence',
    K9BoneIndices          = 'explicitly described as an earlier, more elaborate sketch that was superseded -- client/fetch.lua and server/fetch.lua both say so in the same sentence',
}

--- Sub-tables that were REMOVED from a config block that still exists, so
--- the top-level check cannot catch a comment still naming one. Add to this
--- when a subsystem is deleted but its parent block stays.
local REMOVED_SUBTABLES = {
    Wellbeing = { Mood = true, FearStress = true, Distraction = true, Injury = true, Hunger = true, Thirst = true },
}

--- Top-level `Config.<Name> =` assignments in the shipped config.
--- @return table<string, boolean>
local function ShippedConfigBlocks()
    local handle = assert(io.open('../config.lua', 'r'))
    local text = handle:read('a')
    handle:close()
    local blocks = {}
    for name in text:gmatch('\nConfig%.([A-Za-z0-9_]+)%s*=') do blocks[name] = true end
    return blocks
end

--- The inverse of ReferencedFeatureFlags' stripper: keeps ONLY comment
--- text, with true line numbers, so this guard reads exactly what the other
--- one throws away.
--- @param text string
--- @return table[] -- { line = number, text = string }
local function CommentLines(text)
    local out = {}
    local inBlock, level = false, ''
    local lineNo = 0
    for line in (text .. '\n'):gmatch('([^\n]*)\n') do
        lineNo = lineNo + 1
        if inBlock then
            out[#out + 1] = { line = lineNo, text = line }
            if line:find(']' .. level .. ']', 1, true) then inBlock = false end
        else
            local openStart, openEnd, lvl = line:find('%-%-%[(=*)%[')
            if openStart then
                out[#out + 1] = { line = lineNo, text = line }
                level = lvl
                if not line:sub(openEnd + 1):find(']' .. level .. ']', 1, true) then inBlock = true end
            else
                local dashes = line:find('%-%-')
                if dashes then out[#out + 1] = { line = lineNo, text = line:sub(dashes) } end
            end
        end
    end
    return out
end

t.test('COMMENT ROT: every Config.<block> a comment names still exists in the shipped config.lua -- the guard that would have caught the four stale Config.Recall comments', function()
    -- CONTROL PERFORMED: re-adding the deleted "Config.ScentTrailHunt ...
    -- follow-your-nose hunts" line to config.lua's own table of contents
    -- turns this red, naming config.lua and the line. Removing it again
    -- makes it green.
    local blocks = ShippedConfigBlocks()

    local listing = assert(io.popen('ls ../config.lua ../client/*.lua ../server/*.lua ../shared/*.lua 2>/dev/null'))
    local paths = {}
    for line in listing:lines() do paths[#paths + 1] = line end
    listing:close()
    t.isTrue(#paths > 20, 'sanity: the file scan must actually find files, or this test passes vacuously')

    local stale = {}
    for _, path in ipairs(paths) do
        local handle = io.open(path, 'r')
        if handle then
            local text = handle:read('a')
            handle:close()
            for _, entry in ipairs(CommentLines(text)) do
                -- The `[^%w_]` prefix matters: without it this matches the
                -- tail of `trackingConfig.maxRange` and reports `maxRange`
                -- as a missing top-level block. Three real comments hit
                -- that during development of this guard.
                for name, sub in (' ' .. entry.text):gmatch('[^%w_]Config%.([A-Za-z0-9_]+)%.?([A-Za-z0-9_]*)') do
                    if not blocks[name] and not COMMENT_CONFIG_ALLOWLIST[name] then
                        stale[#stale + 1] = ('%s:%d names Config.%s'):format(path:gsub('^%.%./', ''), entry.line, name)
                    elseif sub ~= '' and REMOVED_SUBTABLES[name] and REMOVED_SUBTABLES[name][sub] then
                        -- ONE LEVEL DEEPER, for removed SUB-tables only. The
                        -- top-level check above cannot see these: the parent
                        -- block still exists, so `Config.Wellbeing.Mood` reads
                        -- as valid while `Mood` itself was deleted. Two such
                        -- comments survived the guard's first version --
                        -- Config.Wellbeing.Mood.petCooldownMs and
                        -- Config.Wellbeing.Thirst.bowlSources -- which is why
                        -- this second pass exists. Deliberately NOT a general
                        -- walk of every sub-key: that would need the whole
                        -- config loaded and resolved, and would fire on every
                        -- comment naming a field in passing. Only names that
                        -- were genuinely REMOVED are listed.
                        stale[#stale + 1] = ('%s:%d names Config.%s.%s, which was removed'):format(
                            path:gsub('^%.%./', ''), entry.line, name, sub)
                    end
                end
            end
        end
    end
    table.sort(stale)

    t.equals(#stale, 0,
        'comment(s) naming a config block that no longer exists:\n    ' .. table.concat(stale, '\n    ')
        .. '\n  Either the block was removed and the comment was never updated (say what happened in prose instead of'
        .. ' naming a path a reader cannot go look at), or add the name to COMMENT_CONFIG_ALLOWLIST with a written reason.')
end)

t.test('COMMENT ROT ALLOWLIST HYGIENE: no allowlist entry has quietly become a real config block, and none is dead weight', function()
    local blocks = ShippedConfigBlocks()

    local listing = assert(io.popen('ls ../config.lua ../client/*.lua ../server/*.lua ../shared/*.lua 2>/dev/null'))
    local allText = {}
    for line in listing:lines() do
        local handle = io.open(line, 'r')
        if handle then allText[#allText + 1] = handle:read('a'); handle:close() end
    end
    listing:close()
    local haystack = table.concat(allText, '\n')

    for name, reason in pairs(COMMENT_CONFIG_ALLOWLIST) do
        t.isTrue(type(reason) == 'string' and #reason > 20,
            name .. ' needs a real written reason, not a placeholder')
        t.isFalse(blocks[name] == true,
            name .. ' is now a REAL config block -- remove its exemption, the guard should be checking it')
        t.isTrue(haystack:find('Config%.' .. name) ~= nil,
            name .. ' is no longer named by any comment -- the exemption is dead weight, remove it')
    end
end)

t.test('TABLE OF CONTENTS: config.lua\'s own index lists every Config block in the file, and names no block that is not there -- the index is the one navigation aid a non-technical owner has', function()
    -- WHY THIS IS A REAL GUARD. config.lua is 5,000+ lines and opens with a
    -- hand-written index ("WHAT IS IN THIS FILE -- a map, so you can stop
    -- scrolling"). An index that silently misses a block is worse than no
    -- index: the reader concludes the setting does not exist. Thirteen
    -- blocks were missing when this was written, INCLUDING Config.Features
    -- and Config.FeatureGroups -- the two an owner looks for first.
    --
    -- CONTROL PERFORMED: deleting the Config.Features line from the index
    -- turns this red naming Config.Features; adding a line for a
    -- Config.Nonexistent turns it red the other way.
    local handle = assert(io.open('../config.lua', 'r'))
    local text = handle:read('a')
    handle:close()

    local blocks, order = {}, {}
    for name in text:gmatch('\nConfig%.([A-Za-z0-9_]+)%s*=') do
        if not blocks[name] then blocks[name] = true; order[#order + 1] = name end
    end
    t.isTrue(#order > 40, ('sanity: expected to find many Config blocks, found %d'):format(#order))

    -- The index sits above the first real assignment.
    local indexText = text:sub(1, (text:find('\nConfig%.Features%s*=')) or #text)
    local listed = {}
    for name in indexText:gmatch('\n%-%-   Config%.([A-Za-z0-9_]+)') do listed[name] = true end

    local unlisted = {}
    for _, name in ipairs(order) do
        if not listed[name] then unlisted[#unlisted + 1] = name end
    end
    table.sort(unlisted)
    t.equals(#unlisted, 0, 'config.lua block(s) missing from the file\'s own index: ' .. table.concat(unlisted, ', ')
        .. '. Add a line for each under the right heading, or an owner searching the index will conclude the setting does not exist.')

    local ghosts = {}
    for name in pairs(listed) do
        if not blocks[name] then ghosts[#ghosts + 1] = name end
    end
    table.sort(ghosts)
    t.equals(#ghosts, 0, 'the index names block(s) that are not in the file: ' .. table.concat(ghosts, ', ')
        .. '. This is how four removed features stayed listed as live settings.')
end)

t.test('CONSTRAINT: no scenery ped this resource spawns may use a K9 model', function()
    local shippedCfg = env.Config
    t.isNotNil(shippedCfg, 'shipped Config must load')

    local k9Models = {}
    local k9Count = 0
    for _, entry in ipairs(shippedCfg.Peds or {}) do
        if type(entry) == 'table' and type(entry.model) == 'string' then
            k9Models[entry.model:lower()] = true
            k9Count = k9Count + 1
        end
    end
    t.isTrue(k9Count > 0, 'Config.Peds must list at least one K9 model for this check to mean anything')

    -- Every config path that feeds a CreatePed call in this resource.
    -- Keep this list in step with the CreatePed sites in client/*.lua.
    local sceneryPedPaths = {
        { path = 'Config.K9EquipmentShop.pedModel',
          value = shippedCfg.K9EquipmentShop and shippedCfg.K9EquipmentShop.pedModel,
          what  = 'the equipment-shop attendant (client/equipmentshop.lua)' },
    }

    local offenders = {}
    for _, entry in ipairs(sceneryPedPaths) do
        if type(entry.value) == 'string' and k9Models[entry.value:lower()] then
            offenders[#offenders + 1] = ('%s = %q -- %s'):format(entry.path, entry.value, entry.what)
        end
    end
    -- Per-location overrides get the same treatment as the default.
    local locations = shippedCfg.K9EquipmentShop and shippedCfg.K9EquipmentShop.locations
    if type(locations) == 'table' then
        for key, loc in pairs(locations) do
            if type(loc) == 'table' and type(loc.model) == 'string' and k9Models[loc.model:lower()] then
                offenders[#offenders + 1] = ('a shop location (%s) overrides model = %q'):format(tostring(key), loc.model)
            end
        end
    end

    table.sort(offenders)
    t.equals(#offenders, 0,
        'these spawn an NPC using a model this resource calls a K9:\n    ' .. table.concat(offenders, '\n    ') ..
        '\n  Every K9 on this server is a real player. A dog-shaped NPC standing in the world ' ..
        'breaks that on sight, whatever role the config assigns it. Use a human model (and a ' ..
        'matching human pedScenario).')
end)

t.test('CONSTRAINT: the shop attendant scenario matches a human, not a dog', function()
    local shippedCfg = env.Config
    local scenario = shippedCfg.K9EquipmentShop and shippedCfg.K9EquipmentShop.pedScenario
    if scenario == false or scenario == nil then return end -- "just stand there" is fine
    t.isTrue(type(scenario) == 'string', 'pedScenario must be a string or false')
    -- Paired with the model check above: a dog scenario on a human model
    -- plays wrong, and is also the tell-tale of a reverted model change.
    t.isNil(scenario:upper():match('DOG'),
        ('Config.K9EquipmentShop.pedScenario is %q -- a dog animation. Either the attendant ')
            :format(scenario) .. 'model was reverted to a dog (see the check above), or the two are out of step.')
end)

os.exit(t.summary())
