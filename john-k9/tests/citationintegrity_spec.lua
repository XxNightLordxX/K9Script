--[[
    tests/citationintegrity_spec.lua

    ONE GUARANTEE: every citation this resource writes about ITSELF points
    at something that exists. Two kinds are checked:

      1. FILE PATHS -- a `client/foo.lua` / `tests/bar_spec.lua` /
         `sql/baz.sql` written in any comment or doc resolves on disk.
      2. SECTION REFERENCES -- a `§4.2` written anywhere resolves to a real
         markdown heading in one of this resource's own .md files.

    WHY THIS FILE EXISTS. Two consecutive watchdog passes (2026-08-31)
    found real drift here, and both times the same method found it: extract
    every path, test whether it resolves. Doing that by hand once a week is
    not a guard, it is a habit, and habits lapse. What the two passes found:

      - `client/tablet.lua` named `tests/tablet_strings_spec.lua` as the
        spec enforcing the three-way locale contract. No such file has ever
        existed (the real one is tests/tabletlocalization_spec.lua), so
        anyone trying to verify that contract hit a dead end.
      - `DEVELOPER_REFERENCE.md` §14.3 named `client/attachments.lua` for
        PropAttachments. The shipped file is `client/propattachment.lua`.
      - `DIAGNOSTIC_CHECKS.md` cited `server/compatinventory.lua`; the real
        compat layer is `shared/compat/inventory.lua`.
      - `server/equipmentshop.lua` cited `server/sar.lua`; the SAR file is
        a file that no longer exists.
      - Twenty separate `§4.2.3` / `§4.2.4` / `§4.2.5` / `§9.2` references
        across seven files, all inventing subsection numbers for what are
        really NUMBERED LIST ITEMS inside `### 4.2` and `## 9`. The rules
        they cite (cross-department certifying, the 5m proximity check, the
        grant-only model check) are real and correctly described -- but a
        reader searching the doc for "4.2.3" finds nothing and concludes
        the rule is undocumented.

    WHY THIS FAILURE MODE IS WORSE THAN IT LOOKS. A wrong citation does not
    break the game, so nothing catches it: not luacheck, not any behavioural
    spec, not a play session. It costs the NEXT reader instead -- the person
    trying to confirm a security rule is really enforced, or to find the
    test that guards a contract before changing it. The cost is paid quietly
    and repeatedly, by whoever is least equipped to absorb it.

    WHAT MAKES THIS A REAL GUARD AND NOT A RESTATEMENT. Both allowlists
    below are checked in BOTH directions. An entry that stops being needed
    (someone created the file, or the citation was removed) fails just as
    loudly as a new dangling citation. So this file cannot rot into a pile
    of stale exemptions that quietly permits real breakage -- the same
    discipline tests/featureflagexistence_spec.lua applies to its own
    allowlist, and for the same reason.

    WHAT IS DELIBERATELY NOT CHECKED. `file.lua:123` line numbers. They are
    known-rotten and admitted as such at the top of docs/history/DISCIPLINE_SPEC.md and
    DIAGNOSTIC_CHECKS.md; renumbering them buys nothing because the next
    edit invalidates them all again. The NAME in each citation is the stable
    part, and the name is what this file checks.
]]

local t = dofile('testkit.lua')

-- ======================================================================
-- Helpers
-- ======================================================================

--- Every file in the resource this spec should scan for citations, found
--- from disk rather than from a hand-kept list -- a snapshot list would
--- itself be a citation that rots, which is the exact bug this file exists
--- to prevent. `..` is the resource root (this spec runs from tests/).
local function ScannedFiles()
    local out = {}
    local pipe = io.popen([[cd .. && find . -type f \( -name '*.lua' -o -name '*.js' -o -name '*.md' \) ]] ..
        [[-not -path './.git/*' -not -path './node_modules/*' | sort]])
    if not pipe then return out end
    for line in pipe:lines() do
        out[#out + 1] = (line:gsub('^%./', ''))
    end
    pipe:close()
    return out
end

local function ReadFile(relPath)
    local fh = io.open('../' .. relPath, 'r')
    if not fh then return nil end
    local body = fh:read('a')
    fh:close()
    return body
end

local function FileExists(relPath)
    -- A trailing slash means the citation names a DIRECTORY, not a file.
    -- That became a real shape on 2026-09-02, when server/certifications/
    -- was split into server/certifications/{core,depth,accessors,commands}
    -- .lua: dozens of comments across the resource point at "the
    -- certification code" as a whole rather than at one of its four parts,
    -- and rewriting each to guess a specific part would have made most of
    -- them less accurate, not more. `io.open` on a directory succeeds on
    -- some systems and fails on others, so this is checked explicitly
    -- instead of relied on.
    if relPath:sub(-1) == '/' then
        local probe = io.popen('test -d "../' .. relPath .. '" && echo yes')
        if not probe then return false end
        local answer = probe:read('l')
        probe:close()
        return answer == 'yes'
    end
    local fh = io.open('../' .. relPath, 'r')
    if not fh then return false end
    fh:close()
    return true
end

--- Files excluded from the SWEEPS (they are still checked by the targeted
--- regression tests at the bottom, where the assertion is precise).
---
--- Both are documents whose JOB is to quote wrong citations verbatim: this
--- spec quotes `client/foo.lua` and `§4.2.3` as examples of the very
--- mistakes it forbids, and WATCHDOG_LOG.md records, as history, the exact
--- dead paths each pass found. Scanning them makes the guard flag its own
--- documentation forever. This is a real tension and worth naming: the
--- exclusion is narrow (two files, both non-shipping) and neither can hide
--- a live wrong citation, because neither is a place any reader looks to
--- find out where code lives.
local SELF_QUOTING_FILES = {
    ['tests/citationintegrity_spec.lua'] = true,
    ['WATCHDOG_LOG.md'] = true,
}

--- Extensions that name a real file in this resource. Deliberately a
--- closed list: an open `%a+` pattern matches the tail of a bare domain
--- name too, and `dev/gtahash.com` (a URL in config.lua) was reported as a
--- missing file before this existed.
local REAL_EXTENSIONS = {
    lua = true, js = true, json = true, sql = true,
    html = true, css = true, sh = true, md = true,
}

local SCANNED = ScannedFiles()

-- ======================================================================
-- PART 1 -- file paths cited in prose and comments
-- ======================================================================

--- Paths that legitimately do not resolve inside this repository. Every
--- entry needs a reason, and every entry is re-verified below to still be
--- absent AND still be cited -- a stale exemption fails.
---
--- The overwhelming majority are citations of OTHER resources' source,
--- which is a good practice this resource uses deliberately: when a claim
--- rests on ox_lib's or qbx_core's real behavior, the comment names the
--- upstream file it was verified against. Those must stay citable without
--- vendoring the file.
local EXTERNAL_PATH_ALLOWLIST = {
    -- ox_lib / ox_target upstream source, cited where this resource's
    -- behavior depends on having read it.
    --
    -- Only bare `<dir>/<file>` forms need listing. A citation written with
    -- its full upstream prefix (ox_lib's `resource/interface/client/notify.lua`)
    -- is read whole, does not start with an owned prefix, and is ignored --
    -- which is why writing the fuller path is the better habit.
    ['client/api.lua']       = "ox_target's own client/api.lua (addEntity signature)",
    -- qbx_core / qb-core upstream source.
    ['server/player.lua']    = "qbx_core's server/player.lua",
    ['client/functions.lua'] = 'QBCore/ESX client-side player-data accessor, compat-layer citation',
    ['server/functions.lua'] = 'QBCore/ESX server-side Player object accessor, compat-layer citation',
    ['shared/functions.lua'] = "qbx_core's shared/functions.lua (HasPlayerGotGroup)",
    ['shared/main.lua']      = "es_extended's shared/main.lua (getSharedObject)",
    -- qb-inventory upstream source, cited by shared/compat/inventory.lua.
    ['client/drops.lua']     = 'qb-inventory ground-drop file',
    ['client/vehicles.lua']  = 'qb-inventory vehicle-storage file',
    ['server/commands.lua']  = 'qb-inventory server/commands.lua',
    ['server/hooks.lua']     = 'qb-inventory server/hooks.lua',
    -- Other resources.
    ['client/dead.lua']      = "an ambulance resource's client/dead.lua (statebag origin)",
    -- Planning-document placeholders that are deliberately not real files.
    -- Documents deleted by the 2026-08-25 consolidation. DEVELOPER_REFERENCE.md's
    -- own opening paragraph lists them BY NAME as the files it replaced, which
    -- is a record of a deletion, not a live pointer -- naming them is the
    -- whole point of that paragraph.
    ['locales/README.md']    = 'deleted in the 2026-08-25 consolidation; named in DEVELOPER_REFERENCE.md as one of the files it replaced',
    ['tests/README.md']      = 'deleted in the 2026-08-25 consolidation; its coverage table became DEVELOPER_REFERENCE.md §20',
    ['sql/README.md']        = 'deleted in the 2026-08-25 consolidation; folded into README.md',
    ['dev/bone_sweep.lua']   = 'throwaway dev tool, never added to fxmanifest.lua (see DEVELOPER_REFERENCE.md §14.3)',
    -- Files consumed by the 2026-09-02 diagnostics merge. server/diagnostics.lua
    -- is the two of them joined; its header, its two section banners and
    -- fxmanifest.lua's own entry for it name the originals BY NAME so a reader
    -- of a five-year-old comment can still tell where a paragraph came from.
    -- Same category as the 2026-08-25 entries above: a record of a merge, not a
    -- live pointer.
    ['server/selfcheck.lua'] = 'merged into server/diagnostics.lua on 2026-09-02; named in that file and in fxmanifest.lua as one of its two origins',
    ['server/debugdump.lua'] = 'merged into server/diagnostics.lua on 2026-09-02; named in that file and in fxmanifest.lua as one of its two origins',
}

--- Directory prefixes worth scanning for. Anything outside these is not a
--- path into this resource and is not this file's business.
local OWNED_PREFIXES = {
    'client/', 'server/', 'shared/', 'html/', 'locales/', 'sql/', 'tests/', 'dev/',
}

local function LooksLikeOwnedPath(path)
    for _, prefix in ipairs(OWNED_PREFIXES) do
        if path:sub(1, #prefix) == prefix then return true end
    end
    return false
end

--- Collects every `<dir>/<file>.<ext>` written anywhere in the scanned
--- files, mapped to the files that cite it.
---
--- NOTE ON THE PATTERN. `[%w_.-]` deliberately EXCLUDES `/` after the
--- first separator, so the `a.lua/b.lua` slash-joined writing style this
--- codebase uses everywhere ("client/kennel.lua/client/vehicle.lua")
--- yields two atomic paths rather than one composite that resolves to
--- nothing. An earlier draft of this scan allowed `/` and produced ~100
--- phantom "missing" paths, all artifacts. Lua `%w` also excludes the
--- underscore, hence the explicit `_` in the class -- the same trap that
--- made tests/featureflagexistence_spec.lua's schema scan silently miss
--- eleven tables before it was caught.
---
--- RESOLUTION IS RELATIVE TO THE CITING FILE FIRST, then to the resource
--- root. `html/tests/audio_play_spec.js` cites its siblings as
--- `tests/audio_play_spec.js`, which is correct FROM html/ and nonsense
--- from the root -- an earlier draft of this scan reported all 42 browser
--- specs as missing for exactly that reason.
local function CollectCitedPaths()
    local cited = {}
    for _, file in ipairs(SCANNED) do
        if not SELF_QUOTING_FILES[file] then
            local dir = file:match('^(.*)/[^/]*$')
            local body = ReadFile(file)
            if body then
                -- The leading `[^%w_/.-]` boundary matters: without it, gmatch
                -- happily starts mid-path and pulls `tests/foo.js` out of a
                -- perfectly correct `html/tests/foo.js`, then reports the
                -- fragment as missing. Found by this spec's own red-green
                -- proof run. `\n%s*` also admits a path at the very start of
                -- a line, and the body is prefixed with a newline below so a
                -- path in byte 1 of a file is not skipped.
                for _, path, ext in ('\n' .. body):gmatch('([^%w_/.-])([%a][%w_]*/[%w_.-]+%.(%a+))') do
                    if REAL_EXTENSIONS[ext:lower()] and LooksLikeOwnedPath(path) then
                        -- Try the citing file's own directory, then each
                        -- ancestor, then the resource root. html/tests/*.js
                        -- cite their siblings as `tests/foo.js`, which is
                        -- right FROM html/ -- one level up from the citing
                        -- file. Root-only resolution reported all 42 browser
                        -- specs as missing.
                        local resolved = path
                        local base = dir
                        while base do
                            if FileExists(base .. '/' .. path) then
                                resolved = base .. '/' .. path
                                break
                            end
                            base = base:match('^(.*)/[^/]*$')
                        end
                        cited[resolved] = cited[resolved] or {}
                        cited[resolved][#cited[resolved] + 1] = file
                    end
                end
            end
        end
    end
    return cited
end

local CITED_PATHS = CollectCitedPaths()

t.test('SANITY: the citation scan actually found citations (a silently-empty scan would pass every test below)', function()
    local count = 0
    for _ in pairs(CITED_PATHS) do count = count + 1 end
    t.isTrue(count > 150,
        ('expected the scan to find >150 distinct cited paths across %d files, found %d -- ' ..
         'the scan itself is broken, not the citations'):format(#SCANNED, count))
    t.isTrue(#SCANNED > 100,
        ('expected to scan >100 files, scanned %d'):format(#SCANNED))
end)

t.test('Every file path this resource cites about itself resolves on disk', function()
    local broken = {}
    for path, citers in pairs(CITED_PATHS) do
        if not EXTERNAL_PATH_ALLOWLIST[path] and not FileExists(path) then
            table.sort(citers)
            broken[#broken + 1] = ('%s (cited in %s)'):format(path, citers[1])
        end
    end
    table.sort(broken)
    t.equals(#broken, 0,
        'these cited paths do not exist:\n    ' .. table.concat(broken, '\n    ') ..
        '\n  Either fix the citation to name the real file, or -- if it names another ' ..
        "resource's source on purpose -- add it to EXTERNAL_PATH_ALLOWLIST with a reason.")
end)

t.test('ALLOWLIST HYGIENE: no path allowlist entry has quietly become real or unused', function()
    local stale = {}
    for path, reason in pairs(EXTERNAL_PATH_ALLOWLIST) do
        if FileExists(path) then
            stale[#stale + 1] = ('%s -- now EXISTS in this repo, so the exemption (%s) is wrong'):format(path, reason)
        elseif not CITED_PATHS[path] then
            stale[#stale + 1] = ('%s -- no longer cited anywhere, so the exemption is dead weight'):format(path)
        end
    end
    table.sort(stale)
    t.equals(#stale, 0, 'stale allowlist entries:\n    ' .. table.concat(stale, '\n    '))
end)

-- ======================================================================
-- PART 2 -- section references
-- ======================================================================

--- `§N` / `§N.N` references that point at something outside this
--- resource's own docs. Same both-directions hygiene check as above.
local EXTERNAL_SECTION_ALLOWLIST = {
    ['3.4.1'] = 'the Lua 5.4 reference manual §3.4.1 (arithmetic coercion), cited in server/tracking.lua',
    ['0.5']   = 'native_natives.md §0.5, an external natives document',
}

--- Text that marks a §ref as an ANCHORED PINPOINT rather than a citation of
--- a numbered heading. These are deliberately unresolvable and this
--- resource says so in writing.
---
--- DEVELOPER_REFERENCE.md §15's own header: "A finer-grained pinpoint (e.g.
--- `#tracking §2.4`, `#door-interaction Finding 3`) cited in a code comment
--- will NOT resolve to anything below." The pre-2026-08-25 research archive
--- numbered findings inside each of its twelve topic anchors; the flattening
--- to prose kept the anchor names and dropped the internal numbering, and
--- §15 declines to rewrite 100+ comment sites over it, flagging it centrally
--- instead. That is a reasoned position, so this guard respects it rather
--- than fighting it: a §ref reached through an anchor is exempt, a bare one
--- is not.
---
--- Kept deliberately narrow. It matches only the two markers that really
--- introduce an anchored pinpoint, and only on the SAME LINE, so an ordinary
--- dangling §ref elsewhere in the same file is still caught.
local ANCHORED_PINPOINT_MARKERS = { '#[%w-]+', 'design note' }

local function IsAnchoredPinpoint(line)
    for _, marker in ipairs(ANCHORED_PINPOINT_MARKERS) do
        if line:find(marker) then return true end
    end
    return false
end

--- Every heading number that really exists across this resource's own .md
--- files -- e.g. `## 4. Hard requirement 2` and `### 4.2 Certifier
--- eligibility` both contribute.
local function RealHeadingNumbers()
    local heads = {}
    for _, file in ipairs(SCANNED) do
        if file:match('%.md$') then
            local body = ReadFile(file)
            if body then
                for line in body:gmatch('[^\n]+') do
                    local num = line:match('^#+%s+([%d.]+)')
                    if num then
                        heads[(num:gsub('%.$', ''))] = true
                    end
                    -- A markdown table row whose FIRST cell is just a §ref
                    -- DEFINES that ref rather than citing it. §15's
                    -- hud-bridge anchor carries exactly such a table,
                    -- mapping the old design-note numbering onto the prose
                    -- that survived consolidation -- so `| §5.3 |` is the
                    -- thing a `§5.3` citation now resolves TO.
                    local defined = line:match('^[>%s]*|%s*§([%d][%d.]*)%s*|')
                    if defined then
                        heads[(defined:gsub('%.+$', ''))] = true
                    end
                end
            end
        end
    end
    return heads
end

local REAL_HEADINGS = RealHeadingNumbers()

local function CollectCitedSections()
    local cited = {}
    for _, file in ipairs(SCANNED) do
        if not SELF_QUOTING_FILES[file] then
            local body = ReadFile(file)
            if body then
                local prev = ''
                for line in body:gmatch('[^\n]*') do
                    -- The marker is checked on the previous line too: these
                    -- are wrapped comment blocks, so "DEVELOPER_REFERENCE.md#tracking"
                    -- routinely ends one line and its "§0.1 item 2" begins
                    -- the next.
                    if not (IsAnchoredPinpoint(line) or IsAnchoredPinpoint(prev)) then
                        for num in line:gmatch('§([%d]+[%d.]*)') do
                            -- Strip ALL trailing dots, not one: "§3.." (a §3
                            -- ending a sentence) yielded a literal "§3." key.
                            num = (num:gsub('%.+$', ''))
                            cited[num] = cited[num] or {}
                            cited[num][#cited[num] + 1] = file
                        end
                    end
                    prev = line
                end
            end
        end
    end
    return cited
end

local CITED_SECTIONS = CollectCitedSections()

t.test('SANITY: the section scan found section references', function()
    local count = 0
    for _ in pairs(CITED_SECTIONS) do count = count + 1 end
    t.isTrue(count > 50,
        ('expected >50 distinct §refs, found %d -- the scan is broken'):format(count))
end)

t.test('Every §section reference resolves to a real heading in this resource\'s docs', function()
    local broken = {}
    for num, citers in pairs(CITED_SECTIONS) do
        if not REAL_HEADINGS[num] and not EXTERNAL_SECTION_ALLOWLIST[num] then
            table.sort(citers)
            broken[#broken + 1] = ('§%s (cited in %s)'):format(num, citers[1])
        end
    end
    table.sort(broken)
    t.equals(#broken, 0,
        'these §references point at no heading that exists:\n    ' .. table.concat(broken, '\n    ') ..
        '\n  Most often this is a NUMBERED LIST ITEM being written as though it were a subsection: ' ..
        '"§4.2.3" for item 3 of the list under `### 4.2`. This resource\'s own convention for that ' ..
        'is "§4.2 item 3" -- DEVELOPER_REFERENCE.md §9 uses it and states plainly that its numbering ' ..
        'is fixed BECAUSE code comments cite it by number.')
end)

t.test('ALLOWLIST HYGIENE: no section allowlist entry has quietly become real or unused', function()
    local stale = {}
    for num, reason in pairs(EXTERNAL_SECTION_ALLOWLIST) do
        if REAL_HEADINGS[num] then
            stale[#stale + 1] = ('§%s -- a heading with this number now exists, so the exemption (%s) is wrong'):format(num, reason)
        elseif not CITED_SECTIONS[num] then
            stale[#stale + 1] = ('§%s -- no longer cited anywhere, so the exemption is dead weight'):format(num)
        end
    end
    table.sort(stale)
    t.equals(#stale, 0, 'stale section-allowlist entries:\n    ' .. table.concat(stale, '\n    '))
end)

-- ======================================================================
-- PART 3 -- regression pins for the specific drifts that motivated this file
--
-- These are not redundant with the sweeps above. A sweep proves "nothing is
-- broken right now"; these prove the SPECIFIC corrections are still in
-- place and were not reverted, and they name the real file so the next
-- reader can find it. They are cheap and they are the actual bugs found.
-- ======================================================================

t.test('REGRESSION: client/tablet.lua names the spec that really enforces the locale contract', function()
    local body = ReadFile('client/tablet.lua')
    t.isNotNil(body, 'client/tablet.lua unreadable')
    t.notContains(body, 'tests/tablet_strings_spec.lua',
        'client/tablet.lua is again naming tests/tablet_strings_spec.lua, which has never existed')
    t.contains(body, 'tests/tabletlocalization_spec.lua',
        'client/tablet.lua should name tests/tabletlocalization_spec.lua as the enforcing spec')
end)

t.test('REGRESSION: client/tablet.lua states no hand-maintained key count (it rotted from 255 to 1078 once)', function()
    local body = ReadFile('client/tablet.lua')
    local header = body:match('(.-)local TABLET_STRING_KEYS')
    t.isNotNil(header, 'could not isolate the TABLET_STRING_KEYS header')
    t.isNil(header:match('%d+ keys total'),
        'a "<N> keys total" count is back in the TABLET_STRING_KEYS header. That number is ' ..
        'maintained by hand beside a list that grows every pass, so it rots by default -- it ' ..
        'was wrong by a factor of four last time. tests/tabletlocalization_spec.lua compares ' ..
        'the two sides as SETS, which is the property that actually matters.')
end)

t.test('REGRESSION: the three-way locale contract itself is intact (the count comment was wrong, the contract was not)', function()
    local lua = ReadFile('client/tablet.lua')
    local js = (ReadFile('html/tablet.js') .. ReadFile('html/tablet-catalog.js'))
    t.isNotNil(lua)
    t.isNotNil(js)

    local luaBlock = lua:match('local TABLET_STRING_KEYS = (%b{})')
    t.isNotNil(luaBlock, 'could not find the TABLET_STRING_KEYS table')
    luaBlock = luaBlock:gsub('%-%-[^\n]*', '')
    local luaKeys, luaCount = {}, 0
    for key in luaBlock:gmatch("'([%w_]+)'") do
        luaKeys[key] = true
        luaCount = luaCount + 1
    end

    local jsBlock = js:match('var DEFAULT_STRINGS = (%b{})')
    t.isNotNil(jsBlock, 'could not find DEFAULT_STRINGS')
    jsBlock = jsBlock:gsub('//[^\n]*', '')
    local jsKeys, jsCount = {}, 0
    for key in jsBlock:gmatch('\n%s*([%w_]+)%s*:') do
        jsKeys[key] = true
        jsCount = jsCount + 1
    end

    -- A "did the scan silently break" floor, NOT a policy that the tablet
    -- must carry a given number of strings. It has to sit comfortably
    -- below the real count: a pattern that stopped matching returns single
    -- digits, which any sane floor catches, while a floor set just under
    -- the current total turns every honest removal into a red build.
    --
    -- Was >900, which the tablet cleared until the three person-shaped
    -- guided flows were retired and took 74 keys with them, landing it on
    -- exactly 900 and tripping a guard that was never about them. The real
    -- contract -- same size, same keys, both directions -- is asserted
    -- immediately below and is what actually protects this.
    t.isTrue(luaCount > 800, ('expected >800 tablet string keys, found %d -- the scan is broken'):format(luaCount))
    t.equals(luaCount, jsCount, 'TABLET_STRING_KEYS and DEFAULT_STRINGS differ in size')

    local onlyLua = {}
    for key in pairs(luaKeys) do if not jsKeys[key] then onlyLua[#onlyLua + 1] = key end end
    local onlyJs = {}
    for key in pairs(jsKeys) do if not luaKeys[key] then onlyJs[#onlyJs + 1] = key end end
    table.sort(onlyLua); table.sort(onlyJs)
    t.equals(#onlyLua, 0, 'in TABLET_STRING_KEYS but not DEFAULT_STRINGS: ' .. table.concat(onlyLua, ', '))
    t.equals(#onlyJs, 0, 'in DEFAULT_STRINGS but not TABLET_STRING_KEYS: ' .. table.concat(onlyJs, ', '))
end)

t.test('REGRESSION: the §4.2 certifier rules are cited as list items, not as invented subsections', function()
    local offenders = {}
    for _, file in ipairs(SCANNED) do
        if file ~= 'tests/citationintegrity_spec.lua' then
            local body = ReadFile(file)
            if body and body:match('§4%.2%.%d') then offenders[#offenders + 1] = file end
        end
    end
    table.sort(offenders)
    t.equals(#offenders, 0,
        '§4.2.N is back in: ' .. table.concat(offenders, ', ') ..
        '. DEVELOPER_REFERENCE.md `### 4.2` is a NUMBERED LIST, not a set of subsections. ' ..
        'Write "§4.2 item 3" -- the form §9 item 2 of that same doc already uses.')
end)

t.test('REGRESSION: PropAttachments is documented under the filenames that actually ship', function()
    local ref = ReadFile('DEVELOPER_REFERENCE.md')
    t.isNotNil(ref)
    t.notContains(ref, 'client/attachments.lua',
        'DEVELOPER_REFERENCE.md is again naming client/attachments.lua, which has never existed')
    t.isTrue(FileExists('client/propattachment.lua'), 'client/propattachment.lua should exist')
    t.isTrue(FileExists('server/propattachment.lua'),
        'server/propattachment.lua should exist -- §14.3 once claimed PropAttachments had no server file at all')
end)

-- ======================================================================
-- PART 4 -- function names written in comments
--
-- A comment that says `FooBar()` is a citation like any other, and it rots
-- the same way -- except worse, because a deleted function leaves no trace
-- and the comment keeps reading as current.
--
-- FOUND BY THIS CHECK, 2026-08-31: `IsOxInventoryHookCapable` was cited
-- NINETEEN times across NINE files as a live capability probe gating
-- ox_inventory hook registration. It had been deleted in the compat-layer
-- migration and its job moved into the boolean
-- `K9Compat.Get('inventory').RegisterHook` returns. Four sites recorded
-- that correctly; fifteen still described it in the present tense, so a
-- reader would hunt for a function long gone and could reasonably conclude
-- the ox_inventory version guard had been lost.
-- ======================================================================

--- Names that are written as `Something()` in a comment but are correctly
--- not defined here. Both-directions hygiene, as above.
local EXTERNAL_FUNCTION_ALLOWLIST = {
    -- The two most valuable entries in this file. Both are cited PRECISELY
    -- because they do not exist: an earlier pass assumed these natives were
    -- real, and an unregistered native returns nil forever while logging
    -- nothing, so thermal/night vision silently never worked. The comments
    -- naming them are the record of that finding and must stay.
    -- DELETED, and the comments that still name it do so in the PAST tense,
    -- as the history of a refactor. That is correct content, so the name
    -- stays exempt here -- but the dedicated regression test at the bottom
    -- of this file separately forbids describing it as CURRENT again, which
    -- is the failure this whole entry exists to prevent from recurring.
    IsOxInventoryHookCapable = 'deleted in the compat-layer migration; its job is now the boolean K9Compat.Get(\'inventory\').RegisterHook returns',
    -- The single most valuable entry here. It is cited PRECISELY because it
    -- does not exist: an earlier pass assumed this native was real, and an
    -- unregistered native returns nil forever while logging nothing, so
    -- thermal vision silently never worked. The comment naming it IS the
    -- record of that finding and must stay. (Its sibling
    -- IsNightvisionActive is named without parentheses everywhere, so this
    -- scan never sees it and it needs no entry.)
    IsSeethroughActive = 'a native that does NOT exist -- cited as the documented finding, see client/vision.lua',
    Await              = 'prose in client/combat.lua describing a yield, not a call to anything',
    -- Named in a comment explaining why it was deliberately NOT added.
    CanActAsK9Handler = 'server/fetch.lua explains why this combinator was not added; naming it is the point',
    -- Other resources / other languages.
    GetCoreObject = "es_extended's shared/main.lua export, cited by shared/compat/framework.lua",
    GREATEST      = 'a SQL function, not Lua -- appears in a query in server/partnership.lua',
    -- Illustrative placeholder names inside spec prose.
    DoThing = 'placeholder in tests/commandreferenceregistry_spec.lua prose, not a real function',
}

--- Every function name this resource defines, in any form the codebase uses.
local function DefinedFunctionNames()
    local names = {}
    for _, file in ipairs(SCANNED) do
        if file:match('%.lua$') then
            local body = ReadFile(file)
            if body then
                for name in body:gmatch('\n%s*function%s+([%w_.:]+)') do
                    -- `Foo.Bar` / `Foo:Bar` -> `Bar`. Guarded: a trailing
                    -- separator (`function Foo.`) makes the match nil, and
                    -- `names[nil] = true` is a hard error, not a skip.
                    local bare = name:match('([%w_]+)$')
                    if bare then names[bare] = true end
                end
                for name in body:gmatch('\n%s*local%s+function%s+([%w_]+)') do
                    names[name] = true
                end
                for name in body:gmatch('\n%s*local%s+([%w_]+)%s*=%s*function') do
                    names[name] = true
                end
                for name in body:gmatch('\n%s*([%w_]+)%s*=%s*function') do
                    names[name] = true
                end
                -- `exports('Name', fn)` and table fields `Name = function`
                for name in body:gmatch("exports%(%s*['\"]([%w_]+)['\"]") do
                    names[name] = true
                end
            end
        end
    end
    return names
end

local DEFINED_FUNCTIONS = DefinedFunctionNames()

local function CitedFunctionNames()
    local cited = {}
    for _, file in ipairs(SCANNED) do
        if file:match('%.lua$') and not SELF_QUOTING_FILES[file] then
            local body = ReadFile(file)
            if body then
                local prevEndsMidWord = false
                for line in body:gmatch('[^\n]+') do
                    -- Comment lines only. A real call is the compiler's
                    -- problem (and luacheck's); only prose can lie.
                    if line:match('^%s*%-%-') then
                        local text = line:match('^%s*%-%-+%s*(.*)$') or ''
                        for pre, name in ('\1' .. text):gmatch('([^%w_*])([A-Z][%w]+)%(%)') do
                            -- WRAP-FRAGMENT GUARD. A long identifier split
                            -- across two comment lines leaves its tail alone
                            -- at the start of the second one, so
                            -- `...newFixtureWith\n-- Access()` looks exactly
                            -- like a citation of `Access()`. If the previous
                            -- comment line ended mid-word and this candidate
                            -- is the first thing on this one, it is a
                            -- continuation, not a citation. Without this the
                            -- scan reported ~40 phantom names.
                            local atLineStart = (pre == '\1')
                            if #name >= 5 and not (atLineStart and prevEndsMidWord) then
                                cited[name] = cited[name] or {}
                                cited[name][#cited[name] + 1] = file
                            end
                        end
                        prevEndsMidWord = text:match('[%w_]$') ~= nil
                    else
                        prevEndsMidWord = false
                    end
                end
            end
        end
    end
    return cited
end

local CITED_FUNCTIONS = CitedFunctionNames()

t.test('SANITY: the function-name scan found both definitions and citations', function()
    local defs, cites = 0, 0
    for _ in pairs(DEFINED_FUNCTIONS) do defs = defs + 1 end
    for _ in pairs(CITED_FUNCTIONS) do cites = cites + 1 end
    t.isTrue(defs > 1000, ('expected >1000 defined function names, found %d'):format(defs))
    t.isTrue(cites > 100, ('expected >100 function names cited in comments, found %d'):format(cites))
end)

t.test('Every FooBar() named in a comment is a function that exists', function()
    local broken = {}
    for name, citers in pairs(CITED_FUNCTIONS) do
        if not DEFINED_FUNCTIONS[name] and not EXTERNAL_FUNCTION_ALLOWLIST[name] then
            table.sort(citers)
            broken[#broken + 1] = ('%s() -- cited in %s (%d site(s))'):format(name, citers[1], #citers)
        end
    end
    table.sort(broken)
    t.equals(#broken, 0,
        'these functions are named in comments but do not exist:\n    ' .. table.concat(broken, '\n    ') ..
        '\n  A deleted function leaves no trace, so the comment keeps reading as current. ' ..
        'Either repoint the comment at what replaced it, or -- if the name is external, or is ' ..
        'cited precisely BECAUSE it does not exist -- add it to EXTERNAL_FUNCTION_ALLOWLIST with a reason.')
end)

t.test('ALLOWLIST HYGIENE: no function allowlist entry has quietly become real or unused', function()
    local stale = {}
    for name, reason in pairs(EXTERNAL_FUNCTION_ALLOWLIST) do
        if DEFINED_FUNCTIONS[name] then
            stale[#stale + 1] = ('%s -- now DEFINED in this repo, so the exemption (%s) is wrong'):format(name, reason)
        elseif not CITED_FUNCTIONS[name] then
            stale[#stale + 1] = ('%s -- no longer cited in any comment, so the exemption is dead weight'):format(name)
        end
    end
    table.sort(stale)
    t.equals(#stale, 0, 'stale function-allowlist entries:\n    ' .. table.concat(stale, '\n    '))
end)

t.test('REGRESSION: no comment describes IsOxInventoryHookCapable as a thing that currently exists', function()
    -- Words that mark a mention as HISTORY rather than a live description.
    -- Checked on the mentioning line AND the one above it, because these are
    -- wrapped comment blocks: the framing ("...has since been deleted") and
    -- the name routinely land on different lines.
    local PAST_TENSE = {
        'deleted', 'used to', 'was once', 'migration', 'originally',
        'WAS a', 'since', 'no longer', 'replaced',
    }
    local function marksHistory(line)
        if not line then return false end
        -- Case-insensitive: this codebase shouts its section headers, so the
        -- marker is as likely to read "COMPAT-LAYER MIGRATION:" as "migration".
        local lowered = line:lower()
        for _, word in ipairs(PAST_TENSE) do
            if lowered:find(word:lower(), 1, true) then return true end
        end
        return false
    end

    local offenders = {}
    for _, file in ipairs(SCANNED) do
        if not SELF_QUOTING_FILES[file] and file:match('%.lua$') then
            local body = ReadFile(file)
            if body then
                local prev = ''
                for line in body:gmatch('[^\n]*') do
                    if line:find('IsOxInventoryHookCapable', 1, true)
                        and not marksHistory(line) and not marksHistory(prev) then
                        offenders[#offenders + 1] = ('%s: %s'):format(file, (line:gsub('^%s+', '')):sub(1, 90))
                    end
                    prev = line
                end
            end
        end
    end
    table.sort(offenders)
    t.equals(#offenders, 0,
        'IsOxInventoryHookCapable is being described in the present tense again:\n    ' ..
        table.concat(offenders, '\n    ') ..
        '\n  That function was deleted in the compat-layer migration. Its job is now the boolean ' ..
        "K9Compat.Get('inventory').RegisterHook returns. Nineteen comments across nine files once " ..
        'described it as live, which would send a reader hunting for a version guard they would ' ..
        'not find. Naming it as HISTORY is fine; naming it as CURRENT is the bug.')
end)

os.exit(t.summary())
