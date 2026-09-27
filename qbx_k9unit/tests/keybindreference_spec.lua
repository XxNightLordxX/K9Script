--[[
    tests/keybindreference_spec.lua

    THIS FILE'S JOB: the keys the tablet TELLS players (html/tablet-catalog.js
    COMMAND_REFERENCE `defaultKeybind`, shown in the Guide's "Your Keys" list
    and in the command table) must be the keys the resource actually
    REGISTERS (every RegisterKeyMapping default in client/, resolved through
    config.lua where the default is a config value).

    WHY: they had drifted. The Guide told players Sit was V, Bark was C and
    Takedown was T; the real defaults were G, U and [. A key list that is
    wrong is worse than none -- a player presses what it says and nothing
    happens, or something else does.

    Also checks every keybound command has a short label for the list, and
    that no registered key is missing from the reference.
--]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

local function ReadFile(path)
    local handle = assert(io.open(path, 'r'), 'could not open ' .. path)
    local text = handle:read('a')
    handle:close()
    return text
end

local function StripFullLineComments(text)
    local kept = {}
    for line in (text .. '\n'):gmatch('([^\n]*)\n') do
        if not line:match('^%s*%-%-') then kept[#kept + 1] = line end
    end
    return table.concat(kept, '\n')
end

local CLIENT_FILES = {}
do
    local p = io.popen('ls ../client/*.lua')
    for path in p:lines() do CLIENT_FILES[#CLIENT_FILES + 1] = path end
    p:close()
end

local function LoadRealConfig()
    local env = Sandbox.newEnv({})
    Sandbox.loadInto('../config.lua', env)
    return env.Config
end

--- How the tablet writes a FiveM key name. Letters and digits are shown as
--- themselves; named keys as the character on the key cap.
local DISPLAY = { LBRACKET = '[', RBRACKET = ']', PERIOD = '.', COMMA = ',', SEMICOLON = ';', SLASH = '/', MINUS = '-', EQUALS = '=' }
local function Display(fivemKey)
    return DISPLAY[fivemKey] or fivemKey
end

--- @return table<string, string> command -> resolved FiveM key name
local function RegisteredDefaults()
    local Config = LoadRealConfig()
    local out = {}
    for _, path in ipairs(CLIENT_FILES) do
        local text = StripFullLineComments(ReadFile(path))
        for command, arg in text:gmatch("RegisterKeyMapping%(%s*'([^']+)'%s*,%s*locale%b()%s*,%s*'keyboard'%s*,%s*([^\n]-)%)%s*\n") do
            local literal = arg:match("^'([^']+)'$")
            local key
            if literal then
                key = literal
            elseif arg == 'GetCameraFeedConfig().toggleKey' then
                key = Config.CameraFeed.toggleKey
            elseif arg:match('^Config%.') then
                local node = Config
                for part in arg:sub(8):gmatch('[^%.]+') do node = node and node[part] end
                key = node
            end
            assert(type(key) == 'string', ('%s: could not resolve the default key for %s from %q'):format(path, command, arg))
            out[command] = key
        end
    end
    return out
end

--- @return table<string, {key:string, labelKey:string?}>
local function ReferenceDefaults()
    local out = {}
    local text = ReadFile('../html/tablet-catalog.js')
    for line in text:gmatch('[^\n]+') do
        local command = line:match("^%s*{ command: '([^']+)'")
        local key = line:match("defaultKeybind: '([^']*)'")
        if command and key then
            out[command] = { key = key, labelKey = line:match("keyLabelKey: '([^']+)'") }
        end
    end
    return out
end

t.test('CONTROL: the scanners find the real registrations and the real reference entries', function()
    local registered, reference = RegisteredDefaults(), ReferenceDefaults()
    local nReg, nRef = 0, 0
    for _ in pairs(registered) do nReg = nReg + 1 end
    for _ in pairs(reference) do nRef = nRef + 1 end
    t.isTrue(nReg >= 12, 'expected at least 12 RegisterKeyMapping defaults, found ' .. nReg)
    t.isTrue(nRef >= 12, 'expected at least 12 reference entries with a defaultKeybind, found ' .. nRef)
    t.equals(registered.k9takedown, 'LBRACKET', 'a config-driven default resolves through config.lua')
    t.equals(registered.k9sit, 'G', 'a literal default is read as written')
end)

t.test('every key the tablet shows is the key the resource actually registers', function()
    local registered, reference = RegisteredDefaults(), ReferenceDefaults()
    local wrong = {}
    for command, entry in pairs(reference) do
        local real = registered[command]
        if not real then
            wrong[#wrong + 1] = ('  %s: the tablet shows %q but nothing registers a key for it'):format(command, entry.key)
        elseif Display(real) ~= entry.key then
            wrong[#wrong + 1] = ('  %s: the tablet shows %q, the real default is %q'):format(command, entry.key, Display(real))
        end
    end
    table.sort(wrong)
    if #wrong > 0 then
        error('the tablet tells players the wrong key:\n' .. table.concat(wrong, '\n') .. '\n\nFix defaultKeybind in html/tablet-catalog.js.', 0)
    end
    t.equals(#wrong, 0)
end)

t.test('every registered key is in the tablet\'s list, with a short label -- no key a player cannot find', function()
    local registered, reference = RegisteredDefaults(), ReferenceDefaults()
    local strings = ReadFile('../html/tablet-catalog.js')
    local missing = {}
    for command in pairs(registered) do
        local entry = reference[command]
        if not entry then
            missing[#missing + 1] = '  ' .. command .. ': no defaultKeybind in COMMAND_REFERENCE'
        elseif not entry.labelKey then
            missing[#missing + 1] = '  ' .. command .. ': no keyLabelKey for the Your Keys list'
        elseif not strings:find('\n%s+' .. entry.labelKey .. ': ') then
            missing[#missing + 1] = '  ' .. command .. ': keyLabelKey ' .. entry.labelKey .. ' has no string'
        end
    end
    table.sort(missing)
    if #missing > 0 then error('keys missing from the list:\n' .. table.concat(missing, '\n'), 0) end
    t.equals(#missing, 0)
end)

os.exit(t.summary())
