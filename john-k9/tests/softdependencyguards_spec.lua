--[==[
    tests/softdependencyguards_spec.lua

    This resource leans on ONE convention for every cross-file call it does
    not want to make load-order-dependent:

        if type(SomeGlobal) == 'function' then SomeGlobal(...) end

    The convention is sound. Its failure mode is not loud. When the function
    behind the guard stops existing -- deleted with its feature, renamed,
    moved into a `local` -- the guard simply stops being true, forever. The
    branch never runs, nothing errors, no log line appears, and every test
    that does not specifically inject the missing global keeps passing.

    THIS HAS HAPPENED TWICE, both found by hand rather than by any gate:

      - server/medkit.lua called RestoreInjury(citizenid,
        Config.K9Medkit.injuryRestore) behind this guard. RestoreInjury went
        away with the injury system, so the call stopped happening -- and
        `Config.K9Medkit.injuryRestore` became an operator dial documented
        in config.lua as "THIS IS LIVE... read by server/medkit.lua on every
        use" that did nothing at all.
      - server/combat.lua's ValidateCombatRequest ran a 53-line block behind
        `type(IsHesitating) == 'function' or type(IsDistracted) ==
        'function'`. Both were gone, so every combat request fell straight
        past a gate two locale strings and 32 lines of header still
        described as live.

    Neither showed up as a failure anywhere. This spec is the gate that
    would have caught both on the commit that broke them.

    WHAT IT DOES: reads every real .lua file under client/, server/ and
    shared/, plus config.lua, extracts the bare global name from each
    `type(X) == 'function'` guard, and asserts that name is either defined
    as a global function somewhere in this resource, bound as a local or a
    parameter at the guard's own site, or a known FiveM runtime native.
    Anything else is a guard that can never be true.

    COMMENT STRIPPING ORDER IS LOAD-BEARING, and getting it wrong is how
    the first hand-run version of this scan produced four false positives:
    BLOCK comments (`--[[ ... ]]`) must be removed BEFORE line comments. Do
    it the other way round and the `--[[` opener is eaten as a line
    comment, the block never matches, and every guard quoted in a file
    header reads as live code.
]==]

local t = dofile('testkit.lua')

--- Known FiveM runtime natives and framework globals. A guard on one of
--- these is defensive against a test sandbox that does not provide it, not
--- a cross-file dependency inside this resource -- this resource cannot
--- define them and is not expected to.
local RUNTIME_PROVIDED = {
    AddEventHandler = true, RegisterNetEvent = true, RegisterCommand = true,
    RegisterKeyMapping = true, TriggerEvent = true, TriggerServerEvent = true,
    TriggerClientEvent = true, CreateThread = true, SetTimeout = true,
    GetCurrentResourceName = true, GetResourceState = true,
    GetResourceMetadata = true, GetGameTimer = true, GetPlayers = true,
    GetPlayerPed = true, GetEntityCoords = true, GetEntityModel = true,
    GetEntityHealth = true, IsPedInAnyVehicle = true, GetHashKey = true,
    GetAllObjects = true, GetAllVehicles = true, GetPlayerName = true,
    exports = true, MySQL = true, lib = true,
}

local function ReadFile(path)
    local handle = assert(io.open(path, 'r'), 'could not open ' .. path)
    local text = handle:read('*a')
    handle:close()
    return text
end

--- BLOCK comments first, then line comments -- see this file's header for
--- why the reverse order silently breaks the whole scan.
--- @param text string
--- @return string
local function StripComments(text)
    text = text:gsub('%-%-%[%[.-%]%]', '')
    text = text:gsub('%-%-[^\n]*', '')
    return text
end

local function SourceFiles()
    local paths = {}
    local handle = assert(io.popen('find ../client ../server ../shared -name "*.lua" 2>/dev/null'))
    for line in handle:lines() do paths[#paths + 1] = line end
    handle:close()
    paths[#paths + 1] = '../config.lua'
    return paths
end

local files = SourceFiles()

-- Every global function this resource defines.
local definedGlobals = {}
for _, path in ipairs(files) do
    local text = ReadFile(path)
    for name in text:gmatch('\n%s*function%s+([%a_][%w_]*)%s*%(') do definedGlobals[name] = true end
    for name in text:gmatch('\n%s*([%a_][%w_]*)%s*=%s*function%s*%(') do definedGlobals[name] = true end
end

t.test('CONTROL: the scan finds a substantial number of real global function definitions -- if this drops, the extraction has drifted and every assertion below is vacuous', function()
    local count = 0
    for _ in pairs(definedGlobals) do count = count + 1 end
    t.isTrue(count >= 50, ('only found %d global function definitions across this resource -- fix the extraction rather than lowering this floor'):format(count))
end)

t.test('every `type(X) == \'function\'` guard names something that can actually exist -- a guard on a name nothing defines is a branch that never runs again, silently, forever', function()
    local guardCount = 0
    local offenders = {}

    for _, path in ipairs(files) do
        local raw = ReadFile(path)
        local code = StripComments(raw)

        -- Names bound as a local or a parameter ANYWHERE in this file. A
        -- guard on one of those is checking a value in hand, not a
        -- cross-file global, so it can never be the dead-branch shape this
        -- spec exists to catch. Scoped per-file deliberately: a local in
        -- one file must not excuse a dangling global guard in another.
        local fileLocals = {}
        for names in code:gmatch('local%s+([%a_][%w_,%s]*)=') do
            for name in names:gmatch('([%a_][%w_]*)') do fileLocals[name] = true end
        end
        for name in code:gmatch('local%s+function%s+([%a_][%w_]*)') do fileLocals[name] = true end
        for params in code:gmatch('function%s*%(([^)]*)%)') do
            for name in params:gmatch('([%a_][%w_]*)') do fileLocals[name] = true end
        end
        for params in code:gmatch('function%s+[%a_][%w_.:]*%s*%(([^)]*)%)') do
            for name in params:gmatch('([%a_][%w_]*)') do fileLocals[name] = true end
        end

        for name in code:gmatch("type%(%s*([%a_][%w_]*)%s*%)%s*==%s*'function'") do
            guardCount = guardCount + 1
            if not definedGlobals[name] and not RUNTIME_PROVIDED[name] and not fileLocals[name] then
                offenders[#offenders + 1] = ('%s guards type(%s) but nothing defines %s'):format(
                    path:gsub('^%.%./', ''), name, name)
            end
        end
    end

    -- CONTROL: this resource uses the convention heavily. If the guard
    -- extraction ever stops matching, the offender list is empty for the
    -- wrong reason and this test passes while checking nothing.
    t.isTrue(guardCount >= 100,
        ('only found %d type(...) == \'function\' guards -- the extraction pattern has drifted; fix it rather than deleting this check'):format(guardCount))

    t.equals(table.concat(offenders, '\n  '), '',
        'each line below is a soft-dependency guard that can never be true, so the code it protects is unreachable')
end)

os.exit(t.summary())
