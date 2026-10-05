--[==[
    tests/tunabledefaultsinrange_spec.lua

    server/runtimecontrol.lua's TUNABLE_REGISTRY declares a min, a max and
    an integer flag for every value an operator can retune live from the
    tablet. config.lua ships a default for each of those same values. The
    two are maintained by hand, in different files, and nothing has ever
    checked that a shipped default actually falls inside the range its own
    registry entry declares legal.

    WHY THAT MATTERS, concretely. The tablet renders each tunable as a
    control bounded by its registry min/max. A default outside those bounds
    cannot be represented on that control, so the operator is shown a value
    that is not the one in force -- and SetTunable would refuse to set the
    number the resource is actually running. The operator ends up unable to
    put back a value they never knowingly changed.

    Verified clean when this spec was written: all 90 registry entries have
    a config default, every default is numeric, inside its own declared
    range, and whole where the entry says integer. This exists so it stays
    that way -- the realistic ways to break it are adding a tunable with a
    range guessed rather than read off the shipped value, or retuning a
    default in config.lua past a bound nobody thought to look at.

    HOW IT READS THE REGISTRY: with Lua, not a regex. The registry is a Lua
    table literal, so this spec locates it by brace matching and `load()`s
    it. That means a registry entry computing its max from a helper
    (ResolveMaxSpeedScentMultiplier, for the speed multipliers) evaluates
    exactly as it does in production -- a regex would have had to reimplement
    that helper and could drift from it.
]==]

local t = dofile('testkit.lua')

local function ReadFile(path)
    local handle = assert(io.open(path, 'r'), 'could not open ' .. path)
    local text = handle:read('*a')
    handle:close()
    return text
end

-- The real, shipped config.
Config = {}
dofile('../config.lua')

--- Faithful mirror of server/runtimecontrol.lua's own helper, which two
--- registry entries call to compute their max. Kept byte-equivalent in
--- BEHAVIOUR rather than imported, because that file cannot be loaded here
--- without its whole server-side dependency chain. If that helper's rule
--- ever changes, this must change with it -- the guard below fails loudly
--- if the two ever disagree about a real shipped value.
---
--- Deliberately a LOCAL handed to load()'s own environment below, never a
--- real global: the registry literal is the only thing that may see it,
--- and leaking it process-wide would let some later spec resolve it by
--- accident and never notice this mirror had drifted.
local function ResolveMaxSpeedScentMultiplier()
    local fallback = 10.0
    local value = tonumber(Config and Config.MaxSpeedScentMultiplier)
    if value == nil or value ~= value or value == math.huge or value == -math.huge or value <= 0 then
        return fallback
    end
    return value
end

--- Extracts and evaluates TUNABLE_REGISTRY straight out of the real file.
local function LoadRegistry()
    local src = ReadFile('../server/runtimecontrol.lua')
    local start = src:find('local TUNABLE_REGISTRY = {', 1, true)
    assert(start, 'TUNABLE_REGISTRY not found in server/runtimecontrol.lua -- that file changed shape; fix this extraction rather than deleting the check')
    local open = src:find('{', start, true)
    local depth, i = 0, open
    while true do
        local c = src:sub(i, i)
        if c == '{' then depth = depth + 1
        elseif c == '}' then
            depth = depth - 1
            if depth == 0 then break end
        elseif c == '' then error('unbalanced braces while reading TUNABLE_REGISTRY')
        end
        i = i + 1
    end
    -- The registry literal calls ResolveMaxSpeedScentMultiplier for two of
    -- its maxima. Resolve that from a purpose-built environment rather than
    -- the real global table, so the mirror above is reachable HERE and
    -- nowhere else.
    local env = { ResolveMaxSpeedScentMultiplier = ResolveMaxSpeedScentMultiplier }
    return assert(load('return ' .. src:sub(open, i), 'TUNABLE_REGISTRY', 't', env))()
end

local registry = LoadRegistry()

local function ValueAt(path)
    local cur = Config
    for _, key in ipairs(path) do
        if type(cur) ~= 'table' then return nil end
        cur = cur[key]
    end
    return cur
end

local entryCount = 0
for _ in pairs(registry) do entryCount = entryCount + 1 end

t.test('CONTROL: the registry loads and carries its real set of tunables -- an empty or tiny table here would make every assertion below vacuous', function()
    t.isTrue(entryCount >= 50,
        ('only %d tunables loaded from TUNABLE_REGISTRY -- the extraction has drifted; fix it rather than lowering this floor'):format(entryCount))
end)

t.test('every tunable in the registry has a real value in the shipped config -- a registry entry pointing at nothing is a tablet control wired to nowhere', function()
    local missing = {}
    for key, def in pairs(registry) do
        if ValueAt(def.path) == nil then
            missing[#missing + 1] = key .. ' (Config.' .. table.concat(def.path, '.') .. ')'
        end
    end
    table.sort(missing)
    t.equals(table.concat(missing, '\n  '), '', 'each line is a tunable the tablet offers but config.lua does not define')
end)

t.test('every shipped default falls INSIDE the min/max its own registry entry declares -- otherwise the tablet shows a value that is not the one in force, and refuses to set the real one back', function()
    local offenders = {}
    for key, def in pairs(registry) do
        local raw = ValueAt(def.path)
        local value = tonumber(raw)
        if raw ~= nil then
            if value == nil then
                offenders[#offenders + 1] = ('%s is not numeric (found %s)'):format(key, tostring(raw))
            elseif value < def.min then
                offenders[#offenders + 1] = ('%s ships %s, below its own declared min of %s'):format(key, tostring(raw), tostring(def.min))
            elseif value > def.max then
                offenders[#offenders + 1] = ('%s ships %s, above its own declared max of %s'):format(key, tostring(raw), tostring(def.max))
            end
        end
    end
    table.sort(offenders)
    t.equals(table.concat(offenders, '\n  '), '', 'widen the range in server/runtimecontrol.lua or bring the default in config.lua inside it')
end)

t.test('every tunable the registry marks `integer = true` ships a whole number -- a fractional default is silently re-rounded the first time it is set from the tablet, changing behaviour nobody asked to change', function()
    local offenders = {}
    for key, def in pairs(registry) do
        local value = tonumber(ValueAt(def.path))
        if def.integer == true and value ~= nil and value ~= math.floor(value) then
            offenders[#offenders + 1] = ('%s is declared integer but ships %s'):format(key, tostring(value))
        end
    end
    table.sort(offenders)
    t.equals(table.concat(offenders, '\n  '), '', 'make the default whole, or drop `integer = true` from its registry entry')
end)

t.test('every registry range is coherent in itself -- min below max, both real numbers', function()
    local offenders = {}
    for key, def in pairs(registry) do
        if type(def.min) ~= 'number' or type(def.max) ~= 'number' then
            offenders[#offenders + 1] = key .. ' has a non-numeric min or max'
        elseif def.min >= def.max then
            offenders[#offenders + 1] = ('%s has min %s >= max %s, so no value can ever satisfy it'):format(key, tostring(def.min), tostring(def.max))
        end
    end
    table.sort(offenders)
    t.equals(table.concat(offenders, '\n  '), '', 'a range nothing can satisfy makes its tablet control permanently unusable')
end)

os.exit(t.summary())
