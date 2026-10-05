--[[
    tests/configpathexistence_spec.lua

    ONE GUARANTEE: no production code indexes into a `Config.<A>.<B>` table
    that does not exist in the shipped config.lua.

    WHY THIS FILE EXISTS. Removing a feature usually means deleting its
    config table. Any code still reading `Config.Wellbeing.Mood.max` then
    indexes a nil, and Lua raises a hard error at that line -- not a
    degraded feature, a crash. luacheck cannot see it (a table lookup is
    valid Lua whatever the key), and no other spec loads the REAL config and
    resolves the REAL paths production code uses.

    FOUND THE HARD WAY, 2026-09-02. After the mood, fear/stress,
    distraction, injury and hunger/thirst systems were removed at the
    owner's request, server/wellbeing.lua still read
    `Config.Wellbeing.Mood.performancePenaltyThreshold` and four siblings
    inside `SnapshotOf`, plus five more inside `EnsureStats`. Both run on
    every wellbeing tick for every connected K9. Every one of those reads
    would have thrown, every tick, on a live server -- while the whole
    resource's test suite, luacheck and the locale cross-check all passed
    green, because none of them resolve a config path against the real file.

    NOTE ON WHAT THIS DOES AND DOES NOT CHECK. It checks the TABLE being
    indexed exists, not that the final field does. Reading a missing FIELD
    off a table that exists is ordinary, intentional Lua -- that is how every
    optional override in this resource works (`Config.K9Inventory.allowedItems`,
    `Config.Combat.WantedStatusCheckOverride`), and flagging those would make
    this guard noise. Only indexing a nil TABLE is a crash, so only that is
    an error here.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

local env = Sandbox.newEnv({ print = function() end })
Sandbox.loadInto('../config.lua', env)

--- Every dotted path in the shipped config whose value is a TABLE.
--- @return table<string, boolean>
local function ConfigTablePaths()
    local seen = {}
    local function walk(tbl, prefix)
        for key, value in pairs(tbl) do
            if type(value) == 'table' then
                local path = prefix .. '.' .. tostring(key)
                seen[path] = true
                walk(value, path)
            end
        end
    end
    walk(env.Config, 'Config')
    return seen
end

--- Non-comment lines of a Lua file, with true line numbers. Block comments
--- are handled by level so a nested example inside one cannot end it early.
--- @param path string
--- @return table[] -- { line = number, text = string }
local function CodeLines(path)
    local handle = io.open(path, 'r')
    if not handle then return {} end
    local out, inBlock, level, lineNo = {}, false, '', 0
    for line in handle:lines() do
        lineNo = lineNo + 1
        local trimmed = line:match('^%s*(.-)%s*$')
        if inBlock then
            if line:find(']' .. level .. ']', 1, true) then inBlock = false end
        else
            local openStart, openEnd, lvl = line:find('%-%-%[(=*)%[')
            if openStart then
                level = lvl
                if not line:sub(openEnd + 1):find(']' .. level .. ']', 1, true) then inBlock = true end
            elseif trimmed:sub(1, 2) ~= '--' then
                out[#out + 1] = { line = lineNo, text = line:gsub('%-%-.*$', '') }
            end
        end
    end
    handle:close()
    return out
end

t.test('SANITY: the real config.lua loaded and produced a populated table map (an empty map would make the scan below pass vacuously)', function()
    local paths = ConfigTablePaths()
    local count = 0
    for _ in pairs(paths) do count = count + 1 end
    t.isTrue(count >= 100, ('expected 100+ config table paths, found %d'):format(count))
end)

t.test('NO CRASHING CONFIG READS: production code never indexes into a Config.<A>.<B> table that does not exist -- the exact defect that survived a full green suite after the wellbeing removals', function()
    -- CONTROL PERFORMED: restoring `Config.Wellbeing.Mood.max` to
    -- server/wellbeing.lua's EnsureStats turns this red, naming that file
    -- and line. Removing it again makes it green.
    local tables = ConfigTablePaths()

    local listing = assert(io.popen('find ../client ../server ../shared -name "*.lua" 2>/dev/null'))
    local files = {}
    for line in listing:lines() do files[#files + 1] = line end
    listing:close()
    t.isTrue(#files > 30, ('sanity: expected to scan many source files, found %d'):format(#files))

    local crashes = {}
    for _, path in ipairs(files) do
        for _, entry in ipairs(CodeLines(path)) do
            -- A read of Config.A.B.C indexes Config.A.B, which must be a table.
            for a, b in entry.text:gmatch('Config%.([A-Za-z0-9_]+)%.([A-Za-z0-9_]+)%.[A-Za-z0-9_]+') do
                local owner = ('Config.%s.%s'):format(a, b)
                -- A `type(...) == 'table'` guard on the same line is the
                -- documented way to read an optional sub-table safely.
                if not tables[owner] and not entry.text:find('type(', 1, true) then
                    crashes[#crashes + 1] = ('%s:%d indexes %s, which does not exist')
                        :format(path:gsub('^%.%./', ''), entry.line, owner)
                end
            end
        end
    end
    table.sort(crashes)

    t.equals(#crashes, 0,
        'production code indexes a config table that is not in config.lua:\n    ' .. table.concat(crashes, '\n    ')
        .. '\n  Each of these throws a hard Lua error the moment that line runs. Either restore the table, guard the'
        .. " read with `type(Config.X.Y) == 'table'`, or delete the code along with the feature it belonged to.")
end)

print(('configpathexistence_spec.lua: %d passed, %d failed'):format(t.passed, t.failed))
os.exit(t.failed == 0 and 0 or 1)
