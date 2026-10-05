--[[
    tests/localecallsites_spec.lua

    Cross-references, in BOTH directions, every `locale(...)` call site in
    every PRODUCTION .lua file this resource ships (client/, server/,
    shared/, config.lua, fxmanifest.lua -- NOT tests/, see "WHY tests/ IS
    OUT OF SCOPE" below) against locales/en.json's flattened key set:

      1. A call site whose key this scan can PROVE resolves to a specific
         string, that string is NOT a key in locales/en.json -- FAILURE.
         This is the gap a locale-keeper pass found by hand this week:
         `combat.blocked_while_searching` and
         `equipmentshop.cannot_open_on_this_inventory` were both called by
         shipped code and both missing from en.json, and nothing caught
         either until a spec happened to walk that exact line. Fixtures'
         own `locale()` (tests/fixtures/sandbox.lua) already hard-asserts a
         missing key -- but ONLY for a code path some OTHER spec's fixture
         actually reaches. This file does not depend on any other spec
         reaching anything; it reads the .lua source directly.

      2. A key in locales/en.json this scan can prove NOTHING reaches is a
         WARNING/report, printed for a human to review, NEVER a failure --
         see "DEAD-KEY REPORTING" below for why.

    THE HARD PART: not every call site is `locale('literal.key')`. Every
    call site found below falls into exactly one of three buckets, and the
    boundary between them is deliberate, not an accident of what regex
    happened to match:

      LITERAL       -- `locale('a.b')` / `pcall(locale, 'a.b', ...)`, key
                        known outright.
      RESOLVABLE     -- the key isn't a literal at the call site, but this
                        scan can still enumerate every value it could ever
                        be, EXACTLY, from other literals in the SAME file:
                          - `COND and 'lit1' or 'lit2'` (this codebase's own
                            ternary idiom, e.g. server/appearance.lua)
                          - `TABLE.field` / `TABLE[expr]` against a local
                            table whose entries are plain literal locale-key
                            strings (server/permissions.lua's
                            GRANT_COMMAND_OUTCOME_KEYS, server/admin.lua's
                            CATALOG_AUDIT_SOURCES) -- NOT tables like
                            server/main.lua's LEASH_REJECT_MESSAGES or
                            client/inventory.lua's K9_INVENTORY_REASON_
                            MESSAGES, whose VALUES are themselves
                            `locale(...)` calls -- those need no special
                            handling at all, since the plain literal scan
                            below already walks into every table
                            constructor and finds each one on its own.
                          - a bare identifier whose value can be traced,
                            in the SAME file, back to a literal assignment,
                            a table alias one hop up (`sourceDef.labelKey`
                            where `sourceDef = CATALOG_AUDIT_SOURCES[x]`),
                            the (literal) return values of the named
                            function that produced it (client/search.lua's
                            `local busy, reasonKey = IsBusyWithSomethingElse()`),
                            or the literal arguments passed at every call
                            site of the named function it is a PARAMETER of
                            (server/tablet.lua and client/tablet.lua's own
                            `SafeLocale(fullKey, ...)`, client/kennel.lua's
                            `ReleaseKennelRest(notifyLocaleKey)`,
                            client/vision.lua's `StopCameraFeed(notifyLocaleKey)`).
                        Every mechanism above only ever ADDS candidate keys
                        it can prove are real possible values -- it never
                        guesses, so checking all of them against en.json can
                        only find a real problem, never invent one.
      DYNAMIC        -- genuinely computed, e.g. client/tablet.lua's
                        `pcall(locale, 'tablet.' .. key)` (a literal PREFIX
                        concatenated with a runtime value -- the exact shape
                        this task's own brief calls out, `locale('kennel.'
                        .. x)`) or server/runtimecontrol.lua's
                        `TunableDescriptionLocaleKey(key)` (a computed
                        string transform). NEVER resolved, NEVER силently
                        dropped either -- every one found must be on the
                        reviewed KNOWN_DYNAMIC_CALL_SITES allowlist below,
                        or the "no new unreviewed dynamic call sites" test
                        fails and names it. A check that fails on a dynamic
                        call site it cannot resolve is worse than none (see
                        that file's own header comment on this
                        exact hazard) -- so dynamic sites are disclosed, not
                        forced into a wrong answer.

    Run this file's own diagnostic test (below) to see today's real counts
    in each bucket.

    NOT A LITERAL-STRING GREP: comments and doc-blocks in this codebase
    quote `locale('...')` in prose constantly (this exact hazard is why
    the locale-keeper pass that requested this file had to be careful) --
    a naive grep over raw text counts every one of those as a call site.
    This scan strips ALL comments (line and long-bracket) AND blanks out
    the CONTENTS of every string literal before doing any keyword/bracket
    structural analysis (see StripComments/BlankStrings) -- the second of
    those two matters just as much as the first: `type(x) == 'function'`
    is real, common code in this resource (client/search.lua's own
    IsBusyWithSomethingElse), and the word "function" inside that STRING
    is not a block-opening keyword, but a naive scan that only strips
    comments still counts it as one, unbalancing every nested-function
    lookup after it. `locale(` itself is matched against the (comment-
    stripped, string-PRESERVING) source directly, so a real call inside a
    real string is never lost -- only the STRUCTURAL keyword/bracket scan
    (used for the RESOLVABLE-bucket tracing above) blanks string contents.

    ALSO MATCHES `pcall(locale, key, ...)`, not just `locale(key, ...)` --
    this resource's own SafeLocale()-style wrappers (server/tablet.lua,
    client/tablet.lua) and several one-off soft-dependency reads
    (server/runtimecontrol.lua, server/tenure.lua) call `locale` this way
    specifically so a missing/renamed key degrades instead of throwing. A
    scan that only recognizes `locale(` would silently miss every one of
    these -- a real, live gap this file's own prototype had until it was
    checked against the real corpus.

    GUARDED (pcall) vs UNGUARDED (bare) CALLS ARE NOT THE SAME SEVERITY,
    AND THIS FILE DOES NOT TREAT THEM THE SAME:
    A bare `locale(key)` call with a missing key is exactly the
    `combat.blocked_while_searching` bug -- ox_lib's real locale() returns
    the raw key text itself on a miss (see tests/fixtures/sandbox.lua's own
    header on this), so the player sees literal text like
    "search.blocked_while_engaged" instead of a real sentence, at the exact
    moment something needed explaining. That is a FAILURE here.
    A `pcall(locale, key, ...)` call with a missing key is, by this
    resource's OWN established and repeatedly-documented convention
    (server/tenure.lua, server/tablet.lua, client/tablet.lua,
    server/runtimecontrol.lua all say so explicitly at each such call
    site), a DELIBERATE soft dependency: "pcall is the only way to probe
    for an optional key's existence without risking [a] hard assert"
    (tests/fixtures/sandbox.lua's own doc comment, restated by
    server/tenure.lua verbatim). Proof this is not theoretical: AT THE TIME
    THIS FILE WAS WRITTEN, `tenure.milestone_reached_named` was exactly
    such a still-proposed, pcall-guarded key with zero player-facing gap
    (TenureMilestoneNotificationText's own fallback is the byte-identical,
    already-shipped, already-tested `tenure.milestone_reached` text) -- a
    hard FAILURE here would have blocked a concurrently in-flight,
    deliberately-staged content rollout for a key that was never broken.
    So: an UNGUARDED call site with a missing/unresolvable-but-provable key
    is this file's one FAILING test. A GUARDED (pcall) call site with the
    same is listed in a separate, clearly-labelled, NEVER-FAILING report,
    exactly like the dead-key report below -- informational, for a human
    deciding whether a proposed key is ready to land, not a bug signal.

    WHY tests/ IS OUT OF SCOPE (both directions):
    (a) MISSING-KEY direction: tests/fixtures/sandbox.lua's own `locale()`
        already hard-asserts on any key a spec resolves at runtime, and
        every *_spec.lua in this directory runs on every `tests/run.sh`
        invocation -- a spec file's own `locale('some.key')` call is
        therefore ALREADY self-checking, on every run, with no help from
        this file. Scanning tests/ here would just re-detect the same
        thing a second, slower way.
    (b) DEAD-KEY direction: this is the one that actually matters. The
        certifications.* keys this pass's own dead-key sweep confirmed
        below are reached by NOTHING except a handful of specs still
        asserting on the pre-restoration wording (this task's own
        assignment says as much: "zero NON-TEST references"). Counting a
        test's own reference as "reachable" would launder an orphaned
        production string as alive forever, defeating the one thing the
        dead-key report exists to catch. Reachability, for this file,
        means "a real PRODUCTION code path can ask for this," full stop.

    THE `tablet` GROUP HAS ITS OWN, SEPARATE, ALREADY-CORRECT CONTRACT --
    tests/tabletlocalization_spec.lua -- and this file does not duplicate
    or fight it:
      - html/tablet.js's DEFAULT_STRINGS, client/tablet.lua's
        TABLET_STRING_KEYS, and locales/en.json's `tablet` group are a
        three-way key-SET contract that spec already enforces end-to-end
        (including running the REAL OpenTablet() and inspecting its actual
        NUI payload). This file does not re-derive that set from either
        source.
      - client/tablet.lua's `BuildTabletStrings()` resolves each
        TABLET_STRING_KEYS entry via `pcall(locale, 'tablet.' .. key)` --
        a literal PREFIX concatenated with an enumerated (not free-form)
        runtime value. This file could, in principle, re-parse
        TABLET_STRING_KEYS to fully resolve it too -- but that means a
        SECOND, independently-written enumeration of the exact same key
        set tabletlocalization_spec.lua already owns via a different
        extraction (JS-side DEFAULT_STRINGS), which is precisely the
        "don't duplicate, don't fight" the assignment for this file
        warned against: two independently-maintained extractions of one
        set WILL drift, and then which one is "right" becomes its own bug.
        So this exact call site is deliberately left on the DYNAMIC
        allowlist below, not resolved -- and it already has its own
        resilience net regardless (pcall-guarded, tolerates a miss, and
        html/tablet.js's DEFAULT_STRINGS is the documented, TESTED English
        fallback for exactly that case).
      - Because of the point above, the `tablet` group is EXCLUDED from
        this file's dead-key report (a real key reached ONLY through that
        one dynamic enumeration would otherwise be flagged as dead here by
        mistake -- a false positive in a domain a different, correct spec
        already owns).
      - Everything else involving the `tablet` group is IN scope and
        checked exactly like any other group: every LITERAL
        `locale('tablet.xxx')` call (SafeLocale-wrapped or not, e.g.
        server/tablet.lua's `SafeLocale('tablet.console_not_authorized')`,
        client/tablet.lua's `locale('radial.no_leash_candidate')`-style
        neighbours) is still checked here like any other literal call.
]]

local t = dofile('testkit.lua')

-- ======================================================================
-- SECTION 1: comment/string-aware source text handling
-- ======================================================================

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

--- @param s string
--- @return string
local function Trim(s)
    return (s:gsub('^%s*(.-)%s*$', '%1'))
end

--- Blanks out every comment (line `--` and long-bracket `--[[ ]]`/`--[=[ ]=]`
--- etc.) while leaving STRING LITERAL CONTENTS untouched (so a real
--- `locale('x.y')` call, wherever it lives, survives byte-for-byte) and
--- the character COUNT and every newline exactly preserved (so every
--- position computed against this text is still a valid index/line number
--- into the ORIGINAL file). Long strings (`[[ ... ]]`/`[=[ ... ]=]`, not
--- preceded by `--`) are correctly left alone rather than mistaken for a
--- comment.
--- @param text string
--- @return string
local function StripComments(text)
    local out = {}
    local i, n = 1, #text
    while i <= n do
        local c = text:sub(i, i)
        if c == '-' and text:sub(i + 1, i + 1) == '-' then
            local bs, be, eqs = text:find('^%[(=*)%[', i + 2)
            if bs then
                local closePat = ']' .. eqs .. ']'
                local _, ce = text:find(closePat, be + 1, true)
                local stop = ce or n
                for j = i, stop do out[#out + 1] = (text:sub(j, j) == '\n') and '\n' or ' ' end
                i = stop + 1
            else
                local lineEnd = text:find('\n', i + 2) or (n + 1)
                for _ = i, lineEnd - 1 do out[#out + 1] = ' ' end
                i = lineEnd
            end
        elseif c == '"' or c == "'" then
            local quote = c
            out[#out + 1] = c
            local j = i + 1
            while j <= n do
                local cj = text:sub(j, j)
                if cj == '\\' then
                    out[#out + 1] = cj
                    j = j + 1
                    if j <= n then out[#out + 1] = text:sub(j, j); j = j + 1 end
                elseif cj == quote then
                    out[#out + 1] = cj
                    j = j + 1
                    break
                elseif cj == '\n' then
                    break -- unterminated on this line; bail out, let Lua's own parser be the real judge
                else
                    out[#out + 1] = cj
                    j = j + 1
                end
            end
            i = j
        elseif c == '[' then
            local bs, be, eqs = text:find('^%[(=*)%[', i)
            if bs then
                local closePat = ']' .. eqs .. ']'
                local _, ce = text:find(closePat, be + 1, true)
                local stop = ce or n
                for j = i, stop do out[#out + 1] = text:sub(j, j) end
                i = stop + 1
            else
                out[#out + 1] = c
                i = i + 1
            end
        else
            out[#out + 1] = c
            i = i + 1
        end
    end
    return table.concat(out)
end

--- Same length/newline-preserving contract as StripComments, but for
--- STRING CONTENTS instead of comments: every character between a pair of
--- quotes (not the quotes themselves) becomes a space. Used ONLY to build
--- the keyword/bracket-structural view of the file (ComputeBlockTokens) --
--- see this file's own header for why a string like `'function'` (a real,
--- common `type(x) == 'function'` check in this resource) must not be
--- allowed to unbalance the nested-block scan the RESOLVABLE-bucket
--- tracing below depends on.
--- @param text string
--- @return string
local function BlankStrings(text)
    local out = {}
    local i, n = 1, #text
    while i <= n do
        local c = text:sub(i, i)
        if c == '"' or c == "'" then
            local quote = c
            out[#out + 1] = ' '
            local j = i + 1
            while j <= n do
                local cj = text:sub(j, j)
                if cj == '\\' then
                    out[#out + 1] = ' '
                    j = j + 1
                    if j <= n then out[#out + 1] = (text:sub(j, j) == '\n') and '\n' or ' '; j = j + 1 end
                elseif cj == quote then
                    out[#out + 1] = ' '
                    j = j + 1
                    break
                elseif cj == '\n' then
                    break
                else
                    out[#out + 1] = (cj == '\n') and '\n' or ' '
                    j = j + 1
                end
            end
            i = j
        else
            out[#out + 1] = c
            i = i + 1
        end
    end
    return table.concat(out)
end

-- ======================================================================
-- SECTION 2: generic balanced-bracket / top-level-split helpers
-- ======================================================================

local OPENERS = { ['('] = true, ['{'] = true, ['['] = true }
local CLOSERS = { [')'] = true, ['}'] = true, [']'] = true }

--- Given `text` and the position of an OPENING (, { or [, returns the
--- position of its matching closer -- correctly skipping over quoted
--- string CONTENTS (a `)` inside a locale string must never look like the
--- call's own closing paren).
--- @param text string
--- @param openPos integer
--- @return integer? closePos
local function FindMatchingClose(text, openPos)
    local depth = 0
    local i, n = openPos, #text
    while i <= n do
        local c = text:sub(i, i)
        if c == '"' or c == "'" then
            local quote = c
            i = i + 1
            while i <= n do
                local cj = text:sub(i, i)
                if cj == '\\' then i = i + 2
                elseif cj == quote then i = i + 1; break
                else i = i + 1 end
            end
        elseif OPENERS[c] then
            depth = depth + 1
            i = i + 1
        elseif CLOSERS[c] then
            depth = depth - 1
            i = i + 1
            if depth == 0 then return i - 1 end
        else
            i = i + 1
        end
    end
    return nil
end

--- Splits `text` on top-level occurrences of `sepChar` -- depth 0 relative
--- to (), {}, [] nesting, and never inside a quoted string. Used to split
--- a call's argument list, and a table constructor's entries, on commas.
--- @param text string
--- @param sepChar string
--- @return string[]
local function SplitTopLevel(text, sepChar)
    local parts = {}
    local depth = 0
    local start = 1
    local i, n = 1, #text
    while i <= n do
        local c = text:sub(i, i)
        if c == '"' or c == "'" then
            local quote = c
            i = i + 1
            while i <= n do
                local cj = text:sub(i, i)
                if cj == '\\' then i = i + 2
                elseif cj == quote then i = i + 1; break
                else i = i + 1 end
            end
        elseif OPENERS[c] then
            depth = depth + 1; i = i + 1
        elseif CLOSERS[c] then
            depth = depth - 1; i = i + 1
        elseif c == sepChar and depth == 0 then
            parts[#parts + 1] = text:sub(start, i - 1)
            i = i + 1
            start = i
        else
            i = i + 1
        end
    end
    parts[#parts + 1] = text:sub(start, n)
    return parts
end

-- ======================================================================
-- SECTION 3: block-keyword depth tracking (locates a NAMED function's
-- body range, for the function-return-trace and function-parameter-trace
-- RESOLVABLE mechanisms).
--
-- Openers, each closed by EXACTLY one closer: `if`, `function`, `do`,
-- `repeat` (closed by `until` instead of `end`). `for` and `while`
-- deliberately contribute NOTHING themselves -- their own `do` is the
-- real, sole opener for that block (counting `for`/`while` AND their `do`
-- would double-count every for/while loop in the file and never balance).
-- Verified empirically against every one of this resource's 88 production
-- .lua files: every one balances to depth 0 with this exact keyword set,
-- once string CONTENTS are blanked (see BlankStrings above).
-- ======================================================================

local BLOCK_DELTA = { ['if'] = 1, ['function'] = 1, ['do'] = 1, ['repeat'] = 1, ['end'] = -1, ['until'] = -1 }

--- @param text string -- must be BlankStrings'd already
--- @return { s: integer, e: integer, delta: integer }[]
local function ComputeBlockTokens(text)
    local tokens = {}
    local pos = 1
    while true do
        local s, e, word = text:find('%f[%a](%a+)%f[%A]', pos)
        if not s then break end
        local delta = BLOCK_DELTA[word]
        if delta then tokens[#tokens + 1] = { s = s, e = e, delta = delta } end
        pos = e + 1
    end
    return tokens
end

--- @param tokens table
--- @param openIndex integer
--- @return integer? closeIndex
local function MatchCloserIndex(tokens, openIndex)
    local depth = 0
    for i = openIndex, #tokens do
        depth = depth + tokens[i].delta
        if depth == 0 then return i end
    end
    return nil
end

--- Finds the innermost `function NAME(...)` (bare or `local function`)
--- whose body textually contains `pos`.
--- @param text string
--- @param tokens table
--- @param pos integer
--- @return { name: string, bodyStart: integer, bodyEnd: integer, paramsStart: integer }?
local function EnclosingFunction(text, tokens, pos)
    local best = nil
    local searchPos = 1
    while true do
        local s, e, name, paramsStart = text:find('function%s+([%a_][%w_]*)%s*()%(', searchPos)
        if not s then break end
        local tokenIndex
        for i, tok in ipairs(tokens) do
            if tok.s == s then tokenIndex = i; break end
        end
        if tokenIndex then
            local closeIndex = MatchCloserIndex(tokens, tokenIndex)
            if closeIndex then
                local bodyStart, bodyEnd = e, tokens[closeIndex].s - 1
                if pos >= bodyStart and pos <= bodyEnd and (not best or bodyStart > best.bodyStart) then
                    best = { name = name, bodyStart = bodyStart, bodyEnd = bodyEnd, paramsStart = paramsStart }
                end
            end
        end
        searchPos = e + 1
    end
    return best
end

-- ======================================================================
-- SECTION 4: literal-expression classifier
-- ======================================================================

--- Parses ONE leading quoted string literal at the start of `text`.
--- Returns (content, restText), restText = everything after the closing
--- quote (trimmed), or nil if `text` does not start with a quote (or the
--- string is unterminated). Character-level, NOT a `^(['"])(.-)%1$`-style
--- regex: that anchored-both-ends shape silently matches "one bare
--- literal" against `'a' .. var .. 'b'` too (the FIRST and LAST quote in
--- the WHOLE expression, with `.. var ..` swallowed as "content") -- it
--- manufactured a phantom locale key out of an entire dynamic expression
--- the one time this corpus actually has that shape
--- (server/runtimecontrol.lua's `'tablet.runtime_lockout_warning_' .. key
--- .. '_template'`) during this file's own development. Exactly the kind
--- of false positive that makes a check worse than none.
--- @param text string
--- @return string? content, string? rest
local function ParseLeadingLiteral(text)
    local quote = text:sub(1, 1)
    if quote ~= "'" and quote ~= '"' then return nil end
    local buf = {}
    local j, n = 2, #text
    while j <= n do
        local cj = text:sub(j, j)
        if cj == '\\' then
            buf[#buf + 1] = text:sub(j + 1, j + 1)
            j = j + 2
        elseif cj == quote then
            return table.concat(buf), Trim(text:sub(j + 1))
        else
            buf[#buf + 1] = cj
            j = j + 1
        end
    end
    return nil
end

--- True (and returns the string) only if `text` is ENTIRELY one bare
--- string literal -- nothing at all before or after it.
--- @param text string
--- @return string?
local function AsBareLiteral(text)
    local content, rest = ParseLeadingLiteral(Trim(text))
    if content and rest == '' then return content end
    return nil
end

--- Finds the LAST top-level (outside quotes/()/{}/[]) occurrence of a
--- whole-word keyword, so a quote or paren inside COND can never be
--- mistaken for the ternary's own `and`/`or` separator.
--- @param text string
--- @param keyword string
--- @return { before: string, after: string }?
local function SplitLastTopLevelKeyword(text, keyword)
    local depth = 0
    local i, n = 1, #text
    local lastSplit = nil
    while i <= n do
        local c = text:sub(i, i)
        if c == '"' or c == "'" then
            local quote = c
            i = i + 1
            while i <= n do
                local cj = text:sub(i, i)
                if cj == '\\' then i = i + 2
                elseif cj == quote then i = i + 1; break
                else i = i + 1 end
            end
        elseif OPENERS[c] then
            depth = depth + 1; i = i + 1
        elseif CLOSERS[c] then
            depth = depth - 1; i = i + 1
        elseif depth == 0 then
            local s, e = text:find('%f[%a]' .. keyword .. '%f[%A]', i)
            if s == i then
                lastSplit = { before = text:sub(1, s - 1), after = text:sub(e + 1) }
                i = e + 1
            else
                i = i + 1
            end
        else
            i = i + 1
        end
    end
    return lastSplit
end

--- Recognizes exactly two shapes: a bare literal, or this codebase's own
--- ternary idiom `COND and 'lit1' or 'lit2'` (both branches TRUE bare
--- literals -- COND itself is never inspected/evaluated, e.g.
--- server/appearance.lua's `pending.kind == 'apply' and '...target' or
--- '...target'`, server/runtimecontrol.lua's `(name == '...') and '...'
--- or '...'`, split across lines with a leading `and`/`or` on the
--- continuation line -- this codebase's own multi-line ternary style).
--- Anything else, including a literal-PREFIX concatenation like
--- `'kennel.' .. suffix`, returns nil -- deliberately NOT resolved (see
--- this file's own header for why: pretending to resolve a genuinely
--- dynamic expression just relocates the false-positive/negative risk
--- instead of removing it).
--- @param exprText string
--- @return string[]?
local function ClassifyLiteralExpr(exprText)
    exprText = Trim(exprText)
    local bare = AsBareLiteral(exprText)
    if bare then return { bare } end

    local orSplit = SplitLastTopLevelKeyword(exprText, 'or')
    if orSplit then
        local lit2 = AsBareLiteral(orSplit.after)
        if lit2 then
            local andSplit = SplitLastTopLevelKeyword(orSplit.before, 'and')
            if andSplit then
                local lit1 = AsBareLiteral(andSplit.after)
                if lit1 then return { lit1, lit2 } end
            end
        end
    end
    return nil
end

-- ======================================================================
-- SECTION 5: Registry A -- named local tables whose entries are PLAIN
-- literal strings (NOT `locale(...)` calls), e.g.
-- server/permissions.lua's GRANT_COMMAND_OUTCOME_KEYS/
-- REVOKE_COMMAND_OUTCOME_KEYS and server/admin.lua's CATALOG_AUDIT_SOURCES
-- (recursed into: each row's own `labelKey = '...'` is picked up too).
-- Tables whose VALUES are `locale(...)` calls (server/main.lua's
-- LEASH_REJECT_MESSAGES, client/inventory.lua's
-- K9_INVENTORY_REASON_MESSAGES) need NO entry here -- the plain literal
-- `locale(` scan in ScanFile below walks straight into their constructors
-- and finds each call as its own ordinary literal site.
-- ======================================================================

--- @param bodyText string -- a table constructor's body, braces already stripped
--- @param out string[]?
--- @return string[]
local function ExtractPlainLiteralValues(bodyText, out)
    out = out or {}
    for _, part in ipairs(SplitTopLevel(bodyText, ',')) do
        local entry = Trim(part)
        if entry ~= '' then
            local _, valueText = entry:match('^([%a_][%w_]*)%s*=%s*(.+)$')
            local value = Trim(valueText or entry) -- array-style entries have no `name =`
            local literal = AsBareLiteral(value)
            if literal then
                out[#out + 1] = literal
            elseif value:sub(1, 1) == '{' and value:sub(-1) == '}' then
                ExtractPlainLiteralValues(value:sub(2, -2), out)
            end
        end
    end
    return out
end

--- @param text string -- comment-stripped, string-content-PRESERVED source
--- @return table<string, string[]>
local function BuildTableRegistry(text)
    local registry = {}
    local pos = 1
    while true do
        local s, e, name = text:find('local%s+([%a_][%w_]*)%s*=%s*{', pos)
        if not s then break end
        local openPos = e -- '{' is the final char of the match
        local closePos = FindMatchingClose(text, openPos)
        if closePos then
            local values = ExtractPlainLiteralValues(text:sub(openPos + 1, closePos - 1))
            if #values > 0 then
                registry[name] = registry[name] or {}
                for _, v in ipairs(values) do registry[name][#registry[name] + 1] = v end
            end
            pos = closePos + 1
        else
            pos = e + 1
        end
    end
    return registry
end

-- ======================================================================
-- SECTION 6: per-file scan
-- ======================================================================

--- @param path string
--- @return table[] sites -- { file, line, raw, kind, keys, mechanism, guarded }
local function ScanFile(path)
    local raw = ReadFile(path)
    local text = StripComments(raw)
    local tokens = ComputeBlockTokens(BlankStrings(text))
    local tableRegistry = BuildTableRegistry(text)

    --- @param pos integer
    --- @return integer
    local function LineOf(pos)
        local n = 0
        for _ in text:sub(1, pos):gmatch('\n') do n = n + 1 end
        return n + 1
    end

    --- Scans the WHOLE file for every assignment to `ident` and collects
    --- every literal locale-key candidate its right-hand side could ever
    --- be: a bare/ternary literal directly, OR (possibly through a guard,
    --- `cond and TABLE[expr]`) an alias of a Registry-A key-table, in
    --- which case ALL of that table's known literal values are added --
    --- imprecise about WHICH field/index is picked at runtime, but safe:
    --- every one of those values is a real candidate this call site could
    --- resolve to, so checking all of them can only ever find a real
    --- problem, never invent one. Used both for a bare `locale(ident)`
    --- call and for the head of `locale(ident.field)` /
    --- `locale(ident[expr])`.
    --- @param ident string
    --- @return string[]?
    local function ResolveVariableAlias(ident)
        local pos = 1
        local collected = {}
        while true do
            local s, e = text:find('%f[%a_]' .. ident .. '%f[%A_]%s*=%s*', pos)
            if not s then break end
            -- avoid matching `==` (equality) -- require the char right
            -- after the consumed `=` run is not itself `=`
            local afterEq = e
            if text:sub(afterEq, afterEq) ~= '=' then
                -- Capture the RHS, extending across lines while the NEXT
                -- line opens with a leading continuation operator (this
                -- codebase's own ternary style: `cond\n  and 'a'\n  or 'b'`,
                -- see server/runtimecontrol.lua's GetActiveUsageWarning).
                local curEnd = text:find('\n', afterEq) or (#text + 1)
                local exprText = text:sub(afterEq, curEnd - 1)
                while true do
                    local nextLineEnd = text:find('\n', curEnd + 1) or (#text + 1)
                    local nextLine = text:sub(curEnd + 1, nextLineEnd - 1)
                    local nextTrimmed = Trim(nextLine)
                    if nextTrimmed:match('^and%f[%A]') or nextTrimmed:match('^or%f[%A]') or nextTrimmed:match('^%.%.') then
                        exprText = exprText .. ' ' .. nextLine
                        curEnd = nextLineEnd
                    else
                        break
                    end
                end
                local literals = ClassifyLiteralExpr((exprText:gsub('%f[%a]then%f[%A].*$', ''):gsub('%s*$', '')))
                if literals then
                    for _, l in ipairs(literals) do collected[#collected + 1] = l end
                else
                    -- Table-alias form: IDENT = TABLE.field / TABLE[expr],
                    -- possibly guarded (`cond and TABLE[expr]`) -- look for
                    -- ANY known key-table name appearing anywhere in the
                    -- RHS, not just at its very start.
                    for tableName, values in pairs(tableRegistry) do
                        if exprText:find('%f[%a_]' .. tableName .. '%f[%A_]%s*[%.%[]') then
                            for _, l in ipairs(values) do collected[#collected + 1] = l end
                        end
                    end
                end
            end
            pos = e + 1
        end
        if #collected > 0 then return collected end
        return nil
    end

    --- Resolves a bare identifier `ident` used as `locale(ident)` (or the
    --- head of `pcall(locale, ident, ...)`) at file position `callPos`.
    --- @param ident string
    --- @param callPos integer
    --- @return string[]? keys, string? mechanism
    local function ResolveIdentifier(ident, callPos)
        local aliasKeys = ResolveVariableAlias(ident)
        if aliasKeys then return aliasKeys, 'var: literal/ternary/table-alias assignment' end

        -- function-return trace: `local A, ident = FUNC(...)` (or the
        -- reverse order) -- client/search.lua's own
        -- `local busy, reasonKey = IsBusyWithSomethingElse()`.
        do
            local pos = 1
            while true do
                local s, e, first, second, funcName = text:find(
                    'local%s+([%a_][%w_]*)%s*,%s*([%a_][%w_]*)%s*=%s*([%a_][%w_]*)%s*%(', pos)
                if not s then break end
                if first == ident or second == ident then
                    local retIndex = (first == ident) and 1 or 2
                    local fs, fe = text:find('local%s+function%s+' .. funcName .. '%s*%(')
                    if fs then
                        local funcInfo = EnclosingFunction(text, tokens, fe + 1)
                        if funcInfo and funcInfo.name == funcName then
                            local collected = {}
                            local searchPos = funcInfo.bodyStart
                            while true do
                                local rs, re = text:find('%f[%a]return%f[%A]', searchPos)
                                if not rs or rs > funcInfo.bodyEnd then break end
                                local retLineEnd = text:find('\n', re) or funcInfo.bodyEnd
                                local retText = text:sub(re + 1, math.min(retLineEnd - 1, funcInfo.bodyEnd))
                                local retParts = SplitTopLevel(retText, ',')
                                local lit = retParts[retIndex] and AsBareLiteral(retParts[retIndex])
                                if lit then collected[#collected + 1] = lit end
                                searchPos = re + 1
                            end
                            if #collected > 0 then
                                return collected, ('var: function-return trace (%s)'):format(funcName)
                            end
                        end
                    end
                end
                pos = e + 1
            end
        end

        -- function-parameter trace: `ident` is a parameter of the
        -- enclosing named function -- collect the literal argument at
        -- that same position across every OTHER call site of that
        -- function in this file (server/tablet.lua and
        -- client/tablet.lua's own `SafeLocale(fullKey, ...)`,
        -- client/kennel.lua's `ReleaseKennelRest(notifyLocaleKey)`,
        -- client/vision.lua's `StopCameraFeed(notifyLocaleKey)`).
        do
            local funcInfo = EnclosingFunction(text, tokens, callPos)
            if funcInfo then
                local ps = text:find('%(', funcInfo.paramsStart)
                local closeP = FindMatchingClose(text, ps)
                local paramIndex
                for i, p in ipairs(SplitTopLevel(text:sub(ps + 1, closeP - 1), ',')) do
                    if Trim(p) == ident then paramIndex = i; break end
                end
                if paramIndex then
                    local collected = {}
                    local searchPos = 1
                    while true do
                        local cs, ce = text:find('%f[%a_]' .. funcInfo.name .. '%s*%(', searchPos)
                        if not cs then break end
                        -- skip the definition occurrence itself
                        if not (cs >= funcInfo.paramsStart - 60 and cs <= funcInfo.paramsStart) then
                            local closeCall = FindMatchingClose(text, ce)
                            if closeCall then
                                local callArgs = SplitTopLevel(text:sub(ce + 1, closeCall - 1), ',')
                                local argText = callArgs[paramIndex] and Trim(callArgs[paramIndex])
                                if argText and argText ~= 'nil' then
                                    local lit = AsBareLiteral(argText)
                                    if lit then collected[#collected + 1] = lit end
                                end
                            end
                        end
                        searchPos = ce + 1
                    end
                    if #collected > 0 then
                        return collected, ('var: function-parameter trace (%s)'):format(funcInfo.name)
                    end
                end
            end
        end

        return nil, nil
    end

    local sites = {}
    local pos = 1
    while true do
        local ds, de = text:find('%f[%a]locale%s*%(', pos)
        local ps, pe = text:find('pcall%s*%(%s*locale%s*[,)]', pos)
        local useDirect
        if ds and (not ps or ds <= ps) then useDirect = true
        elseif ps then useDirect = false
        else break end

        local openPos, keyArgIndex, callPos
        if useDirect then
            openPos, keyArgIndex, callPos = de, 1, ds
        else
            openPos, keyArgIndex, callPos = text:find('%(', ps), 2, ps
        end

        local closePos = FindMatchingClose(text, openPos)
        if not closePos then
            pos = (useDirect and de or pe) + 1
        else
            local args = SplitTopLevel(text:sub(openPos + 1, closePos - 1), ',')
            local keyExprRaw = args[keyArgIndex] and Trim(args[keyArgIndex])
            local line = LineOf(callPos)

            if keyExprRaw then
                local site = { file = path, line = line, raw = keyExprRaw, guarded = not useDirect }
                local literals = ClassifyLiteralExpr(keyExprRaw)
                if literals then
                    site.kind = (#literals == 1) and 'literal' or 'resolvable'
                    site.keys = literals
                    site.mechanism = (#literals == 1) and 'literal' or 'ternary-of-literals'
                else
                    local headName, rest = keyExprRaw:match('^([%a_][%w_]*)(.*)$')
                    if headName and tableRegistry[headName] and rest ~= '' then
                        site.kind, site.keys, site.mechanism = 'resolvable', tableRegistry[headName],
                            ('table field/index (%s)'):format(headName)
                    elseif headName and rest ~= '' and rest:match('^[%.%[]') then
                        -- headName is a VARIABLE (not itself a registered
                        -- table) holding a table alias one hop up, e.g.
                        -- `sourceDef.labelKey` where `sourceDef =
                        -- CATALOG_AUDIT_SOURCES[catalogName]`.
                        local aliasKeys = ResolveVariableAlias(headName)
                        if aliasKeys then
                            site.kind, site.keys, site.mechanism = 'resolvable', aliasKeys,
                                ('table field/index via alias (%s)'):format(headName)
                        else
                            site.kind, site.keys, site.mechanism = 'dynamic', {}, 'unresolved expression'
                        end
                    elseif headName and rest == '' then
                        local keys, mechanism = ResolveIdentifier(headName, callPos)
                        if keys then
                            site.kind, site.keys, site.mechanism = 'resolvable', keys, mechanism
                        else
                            site.kind, site.keys, site.mechanism = 'dynamic', {}, 'unresolved bare identifier'
                        end
                    else
                        site.kind, site.keys, site.mechanism = 'dynamic', {}, 'unresolved expression'
                    end
                end
                sites[#sites + 1] = site
            end
            pos = closePos + 1
        end
    end
    return sites
end

-- ======================================================================
-- SECTION 7: locales/en.json reader (mirrors tests/fixtures/sandbox.lua's
-- own minimal JSON-object reader/technique -- duplicated here, not
-- imported, because this file needs the FULL flattened key SET for the
-- dead-key direction, not single-key resolve-or-throw, which is all
-- Sandbox exposes; tests/schemaconvergence_spec.lua makes the same
-- "each spec is a self-contained extraction" call for its own reasons).
-- ======================================================================

--- @param text string
--- @param pos integer
--- @return table out, integer pos
local function ParseJsonObject(text, pos)
    local out = {}
    pos = text:find('%S', pos)
    assert(text:sub(pos, pos) == '{', 'expected { at ' .. pos)
    pos = pos + 1
    while true do
        pos = text:find('%S', pos)
        assert(pos, 'unterminated object')
        local char = text:sub(pos, pos)
        if char == '}' then return out, pos + 1 end
        if char == ',' then
            pos = pos + 1
        else
            assert(char == '"', 'expected key string at ' .. pos)
            local keyStart = pos
            local key
            key, pos = text:match('^"([^"\\]*)"()', pos)
            assert(key, 'unsupported escape in object key at ' .. keyStart)
            pos = text:find('%S', pos)
            assert(text:sub(pos, pos) == ':', 'expected : after key ' .. key)
            pos = text:find('%S', pos + 1)
            if text:sub(pos, pos) == '{' then
                out[key], pos = ParseJsonObject(text, pos)
            else
                assert(text:sub(pos, pos) == '"', 'locale leaves must be strings; got non-string for ' .. key)
                local buf, index = {}, pos + 1
                while true do
                    local c = text:sub(index, index)
                    assert(c ~= '', 'unterminated string for ' .. key)
                    if c == '\\' then
                        local nextChar = text:sub(index + 1, index + 1)
                        if nextChar == 'u' then
                            buf[#buf + 1] = text:sub(index, index + 5)
                            index = index + 6
                        else
                            local simple = ({ n = '\n', t = '\t', r = '\r', b = '\b', f = '\f',
                                              ['"'] = '"', ['\\'] = '\\', ['/'] = '/' })[nextChar]
                            assert(simple, 'unsupported escape \\' .. nextChar .. ' in ' .. key)
                            buf[#buf + 1] = simple
                            index = index + 2
                        end
                    elseif c == '"' then
                        index = index + 1
                        break
                    else
                        buf[#buf + 1] = c
                        index = index + 1
                    end
                end
                out[key] = table.concat(buf)
                pos = index
            end
        end
    end
end

--- @return table<string, boolean> flatKeys
local function LoadFlattenedLocaleKeys()
    local dict = ParseJsonObject(ReadFile('../locales/en.json'), 1)
    local flat = {}
    for group, entries in pairs(dict) do
        if type(entries) == 'table' then
            for leaf, v in pairs(entries) do
                if type(v) == 'string' then flat[group .. '.' .. leaf] = true end
            end
        end
    end
    return flat
end

-- ======================================================================
-- SECTION 8: run the scan over every production .lua file
-- ======================================================================

--- Every .lua file this resource ships, EXCLUDING tests/ -- see this
--- file's own header, "WHY tests/ IS OUT OF SCOPE", for why. Enumerated
--- with `find` (via io.popen) rather than a hand-maintained list: a
--- hand-maintained file list is exactly the kind of drift risk this whole
--- assignment exists to replace with an automated check, and a NEW file
--- with a locale() call site that this list forgot to mention would be
--- the silent gap all over again, just moved one level up.
--- @return string[]
local function ListProductionLuaFiles()
    local handle = assert(io.popen('find .. -type f -name "*.lua"'),
        'localecallsites_spec.lua requires `find` on PATH to enumerate production .lua files')
    local listing = handle:read('a')
    handle:close()
    local files = {}
    for line in listing:gmatch('[^\r\n]+') do
        if not line:find('/tests/', 1, true) then files[#files + 1] = line end
    end
    table.sort(files)
    return files
end

local allSites = {}
for _, path in ipairs(ListProductionLuaFiles()) do
    for _, site in ipairs(ScanFile(path)) do
        allSites[#allSites + 1] = site
    end
end

local flatKeys = LoadFlattenedLocaleKeys()

-- ======================================================================
-- SECTION 9: reviewed allowlist of genuinely dynamic call sites.
--
-- Matched by (file, raw key-expression text) rather than line number, so
-- an unrelated edit shifting line numbers elsewhere in the file never
-- trips this. Every entry here is a call site this scan CANNOT prove
-- resolves to any specific finite set of keys -- see this file's own
-- header for the resolution mechanisms that WERE tried and how far each
-- one reaches. A NEW dynamic call site this scan finds that is not on
-- this list fails the "no new unreviewed dynamic call sites" test below
-- BY NAME, so growing this list always requires a reviewed line in this
-- file, never happens silently.
-- ======================================================================

local KNOWN_DYNAMIC_CALL_SITES = {
    {
        file = '../client/tablet.lua',
        raw = "'tablet.' .. key",
        note = "BuildTabletStrings() resolving one TABLET_STRING_KEYS entry per iteration -- " ..
               'the key SET is already the tabletlocalization_spec.lua three-way contract\'s job; ' ..
               're-deriving it here would duplicate that spec\'s own extraction. Already pcall-guarded ' ..
               '(a miss is silently omitted from `strings`) with html/tablet.js\'s DEFAULT_STRINGS as the ' ..
               'documented, tested English fallback.',
    },
    {
        file = '../server/runtimecontrol.lua',
        raw = "'tablet.runtime_lockout_warning_' .. key .. '_template'",
        note = 'A literal prefix/suffix around an enumerated tunable-registry key -- the exact ' ..
               "`locale('kennel.' .. x)` shape this task's own brief named as genuinely dynamic. " ..
               'pcall-guarded with an explicit, already-shipped, byte-identical English fallback ' ..
               '(GetActiveUsageWarning\'s own `templateKey` ternary two lines above IS resolved -- ' ..
               'this is the OTHER lockout-warning call site in the same file, not that one).',
    },
    {
        file = '../server/runtimecontrol.lua',
        raw = 'TunableDescriptionLocaleKey(key)',
        note = 'A fully computed key (TUNABLE_REGISTRY key -> lower-cased, dot-to-underscore locale ' ..
               'leaf) -- see TunableDescriptionLocaleKey\'s own doc comment. Enumerable only by walking ' ..
               'TUNABLE_REGISTRY at runtime and replicating its string transform, which is what ' ..
               "tests/runtimecontrol_spec.lua's own targeted coverage already does; not this file's job.",
    },
    {
        file = '../client/main.lua',
        raw = 'reasonLocaleKey',
        note = "DenyK9UIAccess(reasonLocaleKey) (ease-of-use audit pass) -- reasonLocaleKey is an " ..
               'already-valid, ALREADY-RESOLVED locale() key a CALLER passes in (this function does ' ..
               "the locale() lookup on the caller's behalf, exactly like every other string this " ..
               'function has always shown), never a raw suffix/prefix this file itself assembles. Not ' ..
               'enumerable by walking a fixed registry the way TunableDescriptionLocaleKey(key) above ' ..
               'is: any client file that gates on CanShowK9UI()/HasK9Access() may pass its own reason ' ..
               'key here, by design (that is the whole point of the parameter), so the real set grows ' ..
               "with every future call site, not just this pass's own. Every value actually passed " ..
               'today resolves to a REAL key confirmed present in locales/en.json (combat.no_access, ' ..
               'common.no_k9_role_or_access, common.no_k9_access_unknown -- tests/main_spec.lua\'s own ' ..
               'DenyK9UIAccess tests exercise all three plus the omitted-argument default), and the ' ..
               "function's own `type(reasonLocaleKey) == \"string\"` guard means a non-string/absent " ..
               'value never reaches locale() at all -- it falls back to the fixed, resolved ' ..
               "common.no_k9_access_unknown default instead, which this scan already finds on its own.",
    },
}

--- @param site table
--- @return boolean
local function IsKnownDynamicSite(site)
    for _, known in ipairs(KNOWN_DYNAMIC_CALL_SITES) do
        if known.file == site.file and known.raw == site.raw then return true end
    end
    return false
end

-- ======================================================================
-- SECTION 10: tests
-- ======================================================================

local literalCount, resolvableCount, dynamicCount = 0, 0, 0
for _, site in ipairs(allSites) do
    if site.kind == 'literal' then literalCount = literalCount + 1
    elseif site.kind == 'resolvable' then resolvableCount = resolvableCount + 1
    else dynamicCount = dynamicCount + 1 end
end

t.test(('diagnostic: %d call sites scanned across every production .lua file (%d literal, %d resolvable, %d genuinely dynamic)')
    :format(#allSites, literalCount, resolvableCount, dynamicCount), function()
    -- A deliberately loose floor -- not a pinned count (see
    -- tests/tabletlocalization_spec.lua's own header for why this
    -- resource does not pin exact counts: every ordinary addition would
    -- cost a manual bump, training people to bump-without-reading, which
    -- is exactly how a real drop sails through). This is a catastrophe
    -- detector only, for a scanner that silently starts matching nothing
    -- (a `find`/StripComments regression) or a file-enumeration bug that
    -- suddenly sees only a handful of files.
    local MIN_PLAUSIBLE_CALL_SITES = 400
    t.isTrue(#allSites >= MIN_PLAUSIBLE_CALL_SITES,
        ('found only %d locale() call sites across every production .lua file, below the %d floor -- ' ..
         'either a large block of call sites was lost, or this scan\'s file enumeration/comment-stripping ' ..
         'no longer matches the resource\'s real shape'):format(#allSites, MIN_PLAUSIBLE_CALL_SITES))
end)

t.test('every UNGUARDED locale()/pcall(locale, ...) call site this scan can resolve has its key(s) present in locales/en.json', function()
    local missingByKey = {}
    for _, site in ipairs(allSites) do
        if not site.guarded then
            for _, key in ipairs(site.keys) do
                if not flatKeys[key] then
                    missingByKey[key] = missingByKey[key] or {}
                    local loc = site.file:gsub('^%.%./', '') .. ':' .. site.line
                    local already = false
                    for _, l in ipairs(missingByKey[key]) do if l == loc then already = true; break end end
                    if not already then missingByKey[key][#missingByKey[key] + 1] = loc end
                end
            end
        end
    end

    local missingKeys = {}
    for k in pairs(missingByKey) do missingKeys[#missingKeys + 1] = k end
    table.sort(missingKeys)

    if #missingKeys > 0 then
        local lines = {
            ('%d locale key(s) referenced by production code do not exist in locales/en.json:'):format(#missingKeys),
        }
        for _, key in ipairs(missingKeys) do
            table.sort(missingByKey[key])
            lines[#lines + 1] = ('  - %q -- wanted by %s'):format(key, table.concat(missingByKey[key], ', '))
        end
        t.isTrue(false, table.concat(lines, '\n'))
    end
end)

t.test('every GUARDED (pcall) call site with a not-yet-landed key is listed here for awareness -- never a failure (see this file\'s own header)', function()
    local missingByKey = {}
    for _, site in ipairs(allSites) do
        if site.guarded then
            for _, key in ipairs(site.keys) do
                if not flatKeys[key] then
                    missingByKey[key] = missingByKey[key] or {}
                    local loc = site.file:gsub('^%.%./', '') .. ':' .. site.line
                    local already = false
                    for _, l in ipairs(missingByKey[key]) do if l == loc then already = true; break end end
                    if not already then missingByKey[key][#missingByKey[key] + 1] = loc end
                end
            end
        end
    end
    local keys = {}
    for k in pairs(missingByKey) do keys[#keys + 1] = k end
    table.sort(keys)
    if #keys > 0 then
        print('')
        print(('  INFO (not a failure): %d pcall-guarded locale key(s) are not yet in locales/en.json:'):format(#keys))
        for _, key in ipairs(keys) do
            table.sort(missingByKey[key])
            print(('    - %q -- wanted by %s'):format(key, table.concat(missingByKey[key], ', ')))
        end
    end
end)

t.test('every genuinely dynamic call site this scan finds is on the reviewed KNOWN_DYNAMIC_CALL_SITES allowlist', function()
    local unreviewed = {}
    for _, site in ipairs(allSites) do
        if site.kind == 'dynamic' and not IsKnownDynamicSite(site) then
            unreviewed[#unreviewed + 1] = site
        end
    end
    if #unreviewed > 0 then
        local lines = {
            ('%d dynamic (unresolvable) locale() call site(s) are NOT on the reviewed allowlist:'):format(#unreviewed),
        }
        for _, site in ipairs(unreviewed) do
            lines[#lines + 1] = ('  - %s:%d  %s'):format(site.file:gsub('^%.%./', ''), site.line, site.raw)
        end
        lines[#lines + 1] = 'Either resolve it (see this file\'s header for the mechanisms already implemented), ' ..
            'or add it to KNOWN_DYNAMIC_CALL_SITES with a comment explaining why it cannot be resolved.'
        t.isTrue(false, table.concat(lines, '\n'))
    end

    -- Soft, non-failing hygiene note: an allowlist entry no longer found
    -- means the call site was resolved, rewritten, or removed -- good
    -- news, but the entry is now stale and should be deleted by hand.
    for _, known in ipairs(KNOWN_DYNAMIC_CALL_SITES) do
        local stillPresent = false
        for _, site in ipairs(allSites) do
            if site.kind == 'dynamic' and site.file == known.file and site.raw == known.raw then stillPresent = true; break end
        end
        if not stillPresent then
            print(('  INFO (not a failure): KNOWN_DYNAMIC_CALL_SITES entry %s %q no longer matches any dynamic call site -- prune it.')
                :format(known.file, known.raw))
        end
    end
end)

t.test('report: keys in locales/en.json with no reaching production call site (informational only, never fails)', function()
    local reachable = {}
    for _, site in ipairs(allSites) do
        for _, key in ipairs(site.keys) do reachable[key] = true end
    end

    -- The `tablet` group is excluded -- see this file's own header,
    -- "THE `tablet` GROUP HAS ITS OWN, SEPARATE, ALREADY-CORRECT
    -- CONTRACT": its real reachability runs through a dynamic
    -- `'tablet.' .. key` enumeration this file deliberately does not
    -- re-derive (KNOWN_DYNAMIC_CALL_SITES above), so flagging tablet.*
    -- keys as dead here would be a false positive in a domain
    -- tests/tabletlocalization_spec.lua already owns correctly.
    local dead = {}
    for key in pairs(flatKeys) do
        if not key:match('^tablet%.') and not reachable[key] then
            dead[#dead + 1] = key
        end
    end
    table.sort(dead)

    if #dead > 0 then
        print('')
        print(('  INFO (not a failure): %d locales/en.json key(s) have no reaching production call site:'):format(#dead))
        for _, key in ipairs(dead) do print('    - ' .. key) end
    end
end)

os.exit(t.summary())
