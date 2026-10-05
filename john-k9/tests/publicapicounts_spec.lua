--[==[
    tests/publicapicounts_spec.lua

    README.md's "Public API for developers" section quotes three numbers to
    anyone deciding whether to integrate against this resource: how many
    exports each side has, and how many outbound events it fires. Those
    numbers are hand-maintained prose in a file nothing reads.

    Two of the three were wrong. README said 19 client exports (17 real,
    after two dead ones were removed) and fourteen outbound events (11
    real, after the 2026-09-02 removals). Worse, DEVELOPER_REFERENCE.md's
    own entry for the export API deferred to README as "the current,
    authoritative list and count" while README was stale -- two documents
    citing each other, both wrong, neither checkable.

    A wrong count here is not cosmetic. It is the first thing another
    server owner reads when deciding whether this resource exposes enough
    to integrate with, and the number they will quote back when something
    they expected to exist does not.

    This spec measures all three off the real source and fails if README's
    prose disagrees. It deliberately does NOT check DEVELOPER_REFERENCE.md,
    which now says outright that any count in either document is
    untrustworthy without re-measuring and points here instead -- one
    authority, not two.
]==]

local t = dofile('testkit.lua')

local function ReadFile(path)
    local handle = assert(io.open(path, 'r'), 'could not open ' .. path)
    local text = handle:read('*a')
    handle:close()
    return text
end

local function StripComments(text)
    text = text:gsub('%-%-%[=*%[.-%]=*%]', '')   -- block comments first
    text = text:gsub('%-%-[^\n]*', '')
    return text
end

local function CountExports(path)
    local code = StripComments(ReadFile(path))
    local seen, n = {}, 0
    for name in code:gmatch("exports%(%s*'([%w_]+)'") do
        if not seen[name] then seen[name] = true; n = n + 1 end
    end
    return n
end

local function CountOutboundEvents()
    local seen, n = {}, 0
    local handle = assert(io.popen('find ../client ../server -name "*.lua" 2>/dev/null'))
    for path in handle:lines() do
        for name in StripComments(ReadFile(path)):gmatch("'john%-k9:events:([%w]+)'") do
            if not seen[name] then seen[name] = true; n = n + 1 end
        end
    end
    handle:close()
    return n
end

local serverExports = CountExports('../server/exports.lua')
local clientExports = CountExports('../client/exports.lua')
local outboundEvents = CountOutboundEvents()
local readme = ReadFile('../README.md')

t.test('CONTROL: all three measurements find real surface -- a zero here means the extraction drifted and every assertion below is vacuous', function()
    t.isTrue(serverExports >= 5, ('server exports measured: %d'):format(serverExports))
    t.isTrue(clientExports >= 5, ('client exports measured: %d'):format(clientExports))
    t.isTrue(outboundEvents >= 5, ('outbound events measured: %d'):format(outboundEvents))
end)

t.test('README.md\'s stated SERVER export count matches the real number of exports() calls in server/exports.lua', function()
    local stated = tonumber(readme:match('API:%s*(%d+)%s*\n?exports server%-side'))
        or tonumber(readme:match('(%d+)%s*\n?exports server%-side'))
    t.isNotNil(stated, 'could not find the server-export count in README\'s Public API section -- if that sentence was reworded, update this pattern rather than deleting the check')
    t.equals(stated, serverExports,
        ('README says %s server exports, server/exports.lua really registers %d'):format(tostring(stated), serverExports))
end)

t.test('README.md\'s stated CLIENT export count matches the real number of exports() calls in client/exports.lua', function()
    local stated = tonumber(readme:match('(%d+)%s*client%-side'))
    t.isNotNil(stated, 'could not find the client-export count in README\'s Public API section')
    t.equals(stated, clientExports,
        ('README says %s client exports, client/exports.lua really registers %d'):format(tostring(stated), clientExports))
end)

t.test('README.md\'s stated OUTBOUND EVENT count matches the real number of distinct john-k9:events:* names fired anywhere', function()
    local stated = tonumber(readme:match('plus%s+(%d+)%s+outbound events'))
    t.isNotNil(stated, 'could not find a numeric outbound-event count in README\'s Public API section -- note this was spelled "fourteen" in words while it was wrong, which is exactly why this now requires a digit')
    t.equals(stated, outboundEvents,
        ('README says %s outbound events, the source really fires %d'):format(tostring(stated), outboundEvents))
end)

os.exit(t.summary())
