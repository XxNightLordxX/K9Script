--[==[
    tests/neteventwiring_spec.lua

    Several specs already count the net events ONE file registers ("every
    net event this file documents must still register"). Nothing checks the
    other half of the wire: that an event one side FIRES has a handler on
    the side that receives it.

    Both directions fail silently. A client firing
    TriggerServerEvent('john-k9:server:foo') at a handler that no longer
    exists gets no error, no notify, no log -- the player presses the key
    and nothing happens. A server firing TriggerClientEvent at a missing
    client handler is the same in reverse: the state change never lands and
    the client keeps rendering whatever it had.

    This matters most right after a feature is deleted, which is exactly
    what this session spent its length doing -- the SAR, scent-lineup and
    wellbeing removals took a large number of paired events with them. They
    were removed in matched pairs, but nothing verified that; the wiring
    being intact today was established by reading, once, by hand.

    SCOPE: this resource's OWN `john-k9:client:` / `john-k9:server:`
    namespace only. The `john-k9:events:` namespace is deliberately
    excluded -- those are the documented OUTBOUND contract for other
    resources (server/exports.lua), so having no handler inside this
    resource is their normal, correct state.

    COMMENT STRIPPING ORDER, same hard-won note as
    tests/softdependencyguards_spec.lua: block comments must go BEFORE line
    comments, or a `--[[` opener is eaten as a line comment and every event
    name quoted in a file header counts as real wiring.
]==]

local t = dofile('testkit.lua')

--- Client handlers with no TriggerClientEvent behind them that are
--- nonetheless correct. Each is fired by something this scan cannot see,
--- and each entry says by what -- a handler that cannot name its firer
--- does not belong here, it belongs deleted.
local CLIENT_HANDLERS_FIRED_LOCALLY = {
    -- Fired by client/featureblocks.lua's own TriggerEvent (same client,
    -- crosses no network boundary) so client/movement.lua and
    -- client/radial.lua can re-evaluate after a block set is applied.
    ['john-k9:client:featureBlocksApplied'] = 'client/featureblocks.lua TriggerEvent',
    -- Fired by client/movement.lua's own TriggerEvent whenever leashState
    -- flips, so client/radial.lua can refresh its Attach/Detach item.
    ['john-k9:client:leashStateChanged'] = 'client/movement.lua TriggerEvent',
    -- Fired by the OPERATOR'S OWN ox_inventory items.lua entry
    -- (`client = { event = '...' }`) for the tablet item. This resource
    -- cannot create or edit that entry -- see client/tablet.lua's own
    -- comment at the handler for the full disclosure.
    ['john-k9:client:useTabletItem'] = 'operator ox_inventory item definition',
}

local function ReadFile(path)
    local handle = assert(io.open(path, 'r'), 'could not open ' .. path)
    local text = handle:read('*a')
    handle:close()
    return text
end

local function StripComments(text)
    text = text:gsub('%-%-%[=*%[.-%]=*%]', '')   -- block comments, any bracket level, FIRST
    text = text:gsub('%-%-[^\n]*', '')           -- then line comments
    return text
end

local function FilesUnder(dir)
    local paths = {}
    local handle = assert(io.popen(('find %s -name "*.lua" 2>/dev/null'):format(dir)))
    for line in handle:lines() do paths[#paths + 1] = line end
    handle:close()
    return paths
end

--- @return table<string, string> event name -> comma-joined files it appears in
local function Scan(paths, pattern)
    local found = {}
    for _, path in ipairs(paths) do
        local code = StripComments(ReadFile(path))
        for name in code:gmatch(pattern) do
            local short = path:gsub('^%.%./', '')
            found[name] = found[name] and (found[name] .. ', ' .. short) or short
        end
    end
    return found
end

local clientFiles = FilesUnder('../client')
local serverFiles = FilesUnder('../server')

local serverFires    = Scan(serverFiles, "TriggerClientEvent%(%s*'(john%-k9:client:[%w_]+)'")
local clientHandles  = Scan(clientFiles, "RegisterNetEvent%(%s*'(john%-k9:client:[%w_]+)'")
local clientHandles2 = Scan(clientFiles, "AddEventHandler%(%s*'(john%-k9:client:[%w_]+)'")
for name, where in pairs(clientHandles2) do clientHandles[name] = clientHandles[name] or where end

local clientFires    = Scan(clientFiles, "TriggerServerEvent%(%s*'(john%-k9:server:[%w_]+)'")
local serverHandles  = Scan(serverFiles, "RegisterNetEvent%(%s*'(john%-k9:server:[%w_]+)'")
local serverHandles2 = Scan(serverFiles, "AddEventHandler%(%s*'(john%-k9:server:[%w_]+)'")
for name, where in pairs(serverHandles2) do serverHandles[name] = serverHandles[name] or where end

local function Count(tbl)
    local n = 0
    for _ in pairs(tbl) do n = n + 1 end
    return n
end

local function SortedKeys(tbl)
    local keys = {}
    for k in pairs(tbl) do keys[#keys + 1] = k end
    table.sort(keys)
    return keys
end

t.test('CONTROL: the scan finds this resource\'s real net-event traffic in both directions -- if any of these four counts collapses, the extraction has drifted and every assertion below is vacuous', function()
    t.isTrue(Count(serverFires) >= 30, ('server->client fires found: %d'):format(Count(serverFires)))
    t.isTrue(Count(clientHandles) >= 30, ('client handlers found: %d'):format(Count(clientHandles)))
    t.isTrue(Count(clientFires) >= 30, ('client->server fires found: %d'):format(Count(clientFires)))
    t.isTrue(Count(serverHandles) >= 30, ('server handlers found: %d'):format(Count(serverHandles)))
end)

t.test('every john-k9:client: event the SERVER fires has a handler on the client -- without one the push lands nowhere and the client silently keeps stale state', function()
    local dangling = {}
    for _, name in ipairs(SortedKeys(serverFires)) do
        if not clientHandles[name] then
            dangling[#dangling + 1] = ('%s fired from %s, no client handler'):format(name, serverFires[name])
        end
    end
    t.equals(table.concat(dangling, '\n  '), '', 'each line is a server push nothing receives')
end)

t.test('every john-k9:server: event the CLIENT fires has a handler on the server -- without one the action silently does nothing at all', function()
    local dangling = {}
    for _, name in ipairs(SortedKeys(clientFires)) do
        if not serverHandles[name] then
            dangling[#dangling + 1] = ('%s fired from %s, no server handler'):format(name, clientFires[name])
        end
    end
    t.equals(table.concat(dangling, '\n  '), '', 'each line is a player action that reaches nothing')
end)

t.test('every client handler either has a real server-side firer or is a named, justified local/external case -- an orphan handler is dead code that reads as a live feature', function()
    local orphans = {}
    for _, name in ipairs(SortedKeys(clientHandles)) do
        if not serverFires[name] and not CLIENT_HANDLERS_FIRED_LOCALLY[name] then
            orphans[#orphans + 1] = ('%s registered in %s, nothing fires it'):format(name, clientHandles[name])
        end
    end
    t.equals(table.concat(orphans, '\n  '), '',
        'add a CLIENT_HANDLERS_FIRED_LOCALLY entry naming what fires it, or delete the handler')
end)

t.test('the local/external allowlist carries no stale entry -- an event that gained a real server-side firer must not keep claiming it is fired locally', function()
    local stale = {}
    for _, name in ipairs(SortedKeys(CLIENT_HANDLERS_FIRED_LOCALLY)) do
        if not clientHandles[name] then
            stale[#stale + 1] = ('%s is allowlisted but no client handler registers it any more'):format(name)
        elseif serverFires[name] then
            stale[#stale + 1] = ('%s is allowlisted as locally-fired but the server genuinely fires it from %s'):format(name, serverFires[name])
        end
    end
    t.equals(table.concat(stale, '\n  '), '', 'remove the stale allowlist entry')
end)

os.exit(t.summary())
