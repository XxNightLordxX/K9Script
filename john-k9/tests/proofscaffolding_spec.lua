--[[
    tests/proofscaffolding_spec.lua

    THIS FILE'S JOB, AND ONLY THIS FILE'S JOB: refuse to let a deliberately
    broken line reach a commit. It scans every PRODUCTION source file and
    fails if any of them still carries a temporary-break marker of the kind
    an author leaves behind while proving one of their own tests can
    actually fail.

    WHY THIS EXISTS -- twice, not once, and the second time defeated the
    very check written after the first.

      1. An agent mid-red-proof had replaced a real line with a hardcoded
         value. A commit staged by path swept it up. Lint was clean and every
         test passed, because a hardcoded string is perfectly valid code that
         happens to be a lie. Shipped.

      2. The lesson from (1) was "scan the staged diff for markers before
         committing". That scan looked for `RED PROOF` and `TEMP REVERT`.
         The next marker read `TEMP RED-PROOF BREAK` -- hyphenated -- and
         went straight through a check written specifically to catch it,
         into a commit whose own message described the very line it broke as
         fixed. Running a widened pattern immediately found a SECOND live
         break sitting in a different file at that same moment.

    So the durable answer is not a better habit. A human (or agent) grepping
    a diff by hand is exactly the part that failed, twice. This runs on every
    single suite run, sees the whole tree rather than one diff, and cannot be
    forgotten under time pressure.

    WHY IT SCANS THE TREE, NOT THE DIFF: a marker can arrive in one change
    and be committed by a different change minutes later -- which is
    precisely what happened both times. A diff-scoped check cannot see a
    break that was already sitting in the working tree when an unrelated
    commit ran.

    WHAT IT DELIBERATELY DOES NOT SCAN, and why that is not a hole:
      - tests/ -- spec files legitimately discuss these markers in prose,
        document the grep commands that hunt for them, and (correctly) name
        them in comments explaining a red-then-green proof that has already
        been reverted. Scanning tests/ would make honest documentation fail
        the suite, and the pressure that creates is to weaken the pattern --
        the exact failure mode of incident (2). Production code has no
        legitimate reason to contain any of these words.
      - sql/ and *.md -- no executable behaviour to break.
    A marker parked in a test fixture is a far smaller problem than one in a
    live code path: the fixture's own assertions fail loudly, whereas a
    broken production line passes every test that does not happen to cover
    it. That asymmetry is the whole reason this scans one and not the other.

    THE SELF-REFERENCE TRAP, WHICH THIS FILE HAD TO SOLVE TO EXIST AT ALL.
    A guard that names the strings it hunts for contains those strings. That
    is not hypothetical here: earlier the same day this file was written, a
    doc comment in client/hud.lua containing the literal text
    `RegisterCommand('...')` made two separate drift guards report a live
    command named `...` that does not exist -- a guard accusing a sentence.
    This file avoids repeating that in two independent ways: it never scans
    tests/ (so it cannot read itself), and every marker below is BUILT BY
    CONCATENATION so the complete literal never appears anywhere in this
    file. Do not "tidy" those into plain strings.
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

--- Every marker is assembled from fragments, never written whole -- see the
--- SELF-REFERENCE TRAP note in this file's header before changing this.
--- Matched case-insensitively, and tolerant of the separator an author
--- happens to use between words (space, hyphen or underscore), because the
--- one that got through was distinguished from the pattern hunting it by a
--- single hyphen.
local SEP = '[ _%-]'
local MARKER_PATTERNS = {
    { name = 'red-proof break',  pattern = 'RED' .. SEP .. '?PROOF' },
    { name = 'temporary break',  pattern = 'TEMP' .. SEP .. 'BREAK' },
    { name = 'temporary revert', pattern = 'TEMP' .. SEP .. 'REVERT' },
    { name = 'injected bug',     pattern = 'BUG' .. SEP .. 'INJECTED' },
    { name = 'forced failure',   pattern = 'FORCE' .. SEP .. 'RED' },
    { name = 'debug break',      pattern = 'DEBUG' .. SEP .. 'BREAK' },
    { name = 'do-not-commit',    pattern = 'DO' .. SEP .. 'NOT' .. SEP .. 'COMMIT' },
    { name = 'deliberate sabotage', pattern = 'SABOTAG' },
}

--- @param text string
--- @return table[] findings -- { line = number, marker = string, text = string }
local function FindMarkers(text)
    local findings = {}
    local lineNumber = 0
    for line in (text .. '\n'):gmatch('([^\n]*)\n') do
        lineNumber = lineNumber + 1
        local upper = line:upper()
        for _, marker in ipairs(MARKER_PATTERNS) do
            if upper:find(marker.pattern) then
                findings[#findings + 1] = {
                    line = lineNumber,
                    marker = marker.name,
                    text = line:gsub('^%s+', ''):sub(1, 120),
                }
                break -- one finding per line is enough to fail and to point at it
            end
        end
    end
    return findings
end

--- Production directories only -- see this file's header for why tests/ is
--- excluded and why that exclusion is deliberate rather than an oversight.
local function ProductionFiles()
    local paths = {}
    local pipe = io.popen([[find .. -type f \( -name '*.lua' -o -name '*.js' \) ]]
        .. [[-not -path '*/tests/*' -not -path '*/node_modules/*' 2>/dev/null]])
    if not pipe then return paths end
    for line in pipe:lines() do
        paths[#paths + 1] = line
    end
    pipe:close()
    table.sort(paths)
    return paths
end

-- ============================================================================
-- CONTROL TESTS FIRST. A scanner that silently matches nothing would pass the
-- headline test below forever while protecting exactly nothing -- the "fixture
-- never reaches the code under test" failure this codebase has been bitten by
-- more than once. These prove the detector really detects before the headline
-- test's clean result is allowed to mean anything.
-- ============================================================================

t.test('CONTROL: the detector catches the exact line that actually shipped -- the hyphenated marker that defeated the hand-written grep', function()
    local realOffender = '    local ceiling = MOVE_RATE_MAX -- ' .. 'TEMP RED' .. '-PROOF BREAK'
    local findings = FindMarkers(realOffender)
    t.equals(#findings, 1, 'the real committed offender must be caught')
    t.equals(findings[1].line, 1)
end)

t.test('CONTROL: the detector catches the OTHER real shape -- an inline block comment mid-expression, which is far easier to miss by eye than a trailing comment', function()
    local realOffender = '        if --[[' .. 'TEMPORARY RED' .. '-PROOF BREAK]] not IsOnCooldown(id) then'
    t.equals(#FindMarkers(realOffender), 1, 'an inline block-comment marker must be caught')
end)

t.test('CONTROL: every separator an author might use is caught -- space, hyphen and underscore alike, since a single hyphen is what defeated the previous check', function()
    for _, variant in ipairs({ 'RED PROOF', 'RED-PROOF', 'RED_PROOF' }) do
        local line = '-- ' .. variant .. ' break here'
        t.equals(#FindMarkers(line), 1, ('variant %q must be caught'):format(variant))
    end
end)

t.test('CONTROL: case does not matter -- a lowercase marker is just as much a broken line as a shouted one', function()
    t.equals(#FindMarkers('local x = 1 -- ' .. 'temp re' .. 'vert, restore before commit'), 1)
end)

t.test('CONTROL: ordinary production code is NOT flagged -- a scanner that fails on everything would be reverted within a day and protect nothing thereafter', function()
    local ordinary = table.concat({
        'local function ToggleThermalVision()',
        '    if not IsOwnModelK9() then return end',
        '    -- Temporarily disabled effects are restored by the maintenance thread.',
        '    SetSeethrough(true)',
        'end',
    }, '\n')
    t.equals(#FindMarkers(ordinary), 0, 'clean code, including the ordinary word "Temporarily", must not trip this')
end)

t.test('CONTROL: the scanner actually reaches real files on disk -- proving the headline test below is reading the tree, not an empty list', function()
    local paths = ProductionFiles()
    t.isTrue(#paths >= 80, ('expected to find at least 80 production files, found %d -- if this drops, the find command or the layout changed and the headline test may be scanning nothing'):format(#paths))

    local sawServer, sawClient = false, false
    for _, path in ipairs(paths) do
        if path:find('/server/', 1, true) then sawServer = true end
        if path:find('/client/', 1, true) then sawClient = true end
    end
    t.isTrue(sawServer, 'server/ must be in scope')
    t.isTrue(sawClient, 'client/ must be in scope')

    for _, path in ipairs(paths) do
        t.isTrue(not path:find('/tests/', 1, true), ('tests/ must never be scanned (self-reference trap) -- found %s'):format(path))
    end
end)

-- ============================================================================
-- THE HEADLINE GUARD
-- ============================================================================

t.test('LOAD-BEARING TRIPWIRE: no production source file carries a temporary-break marker -- a deliberately broken line must never reach a commit', function()
    local offenders = {}
    for _, path in ipairs(ProductionFiles()) do
        for _, finding in ipairs(FindMarkers(ReadFile(path))) do
            offenders[#offenders + 1] = ('%s:%d (%s): %s'):format(path, finding.line, finding.marker, finding.text)
        end
    end

    if #offenders > 0 then
        error(('%d production line(s) still carry a temporary-break marker:\n  %s\n\n')
            :format(#offenders, table.concat(offenders, '\n  '))
            .. 'THIS IS ALMOST CERTAINLY A DELIBERATELY BROKEN LINE SOMEBODY FORGOT TO PUT BACK.\n'
            .. 'It happens while proving a test can genuinely fail: break the real line, watch the\n'
            .. 'test go red, restore it, watch it go green. If the restore is missed, the broken\n'
            .. 'line looks like ordinary valid code -- lint passes, and every test that does not\n'
            .. 'happen to cover that exact line passes too. It has shipped twice.\n\n'
            .. 'FIX THIS BY restoring the real line the marker replaced. Do NOT fix it by deleting\n'
            .. 'the marker and leaving the broken line, and do NOT fix it by narrowing the patterns\n'
            .. 'above -- narrowing is how the second one got through a check written to catch the\n'
            .. 'first.\n\n'
            .. 'If a production file genuinely needs one of these words in prose, rephrase the prose.\n'
            .. 'Production code has no legitimate need for any of them, which is exactly what makes\n'
            .. 'this guard cheap to keep.', 0)
    end

    t.equals(#offenders, 0)
end)

os.exit(t.summary())
