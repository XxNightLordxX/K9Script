--[[
    tests/helptabcoverage_spec.lua

    DRIFT GUARD for the K9 Command Tablet's Help screen (this pass) --
    specifically its "Every Tab, Explained" section (html/tablet.js's
    HELP_TAB_CATALOG / buildHelpTabsSection()) -- the exact same trap
    tests/commandreferenceregistry_spec.lua already guards against for
    COMMAND_REFERENCE, applied here to the OTHER hand-maintained catalog
    this pass adds: "a tab gets added to buildTabs() and the Help screen
    silently never mentions it."

    THIS FILE'S JOB, AND ONLY THIS FILE'S JOB: prove that the SET of
    `tab_*`-named keys in html/tablet.js's own DEFAULT_STRINGS (every real
    tab button's own label, by this codebase's own established naming
    convention -- see buildTabs(): every tab button's label is
    `S('tab_x')` for exactly one such key) is byte-identical, in both
    directions, to the SET of `tabLabelKey` values HELP_TAB_CATALOG
    documents. It does not check the EXPLANATION text itself (wording,
    accuracy) or the `visible` predicate wiring -- only that nothing is
    ever silently added to one side without the other.

    WHY THE `tab_*` NAMING CONVENTION IS A SAFE PROXY FOR "REAL TAB", NOT
    A GUESS: every existing tab button in buildTabs() already follows it
    (tab_home, tab_my_record, tab_commands, tab_help, tab_console,
    tab_flows, tab_theme, tab_cert_tiers, tab_permission_keys,
    tab_shop_locations, tab_shop_items, tab_runtime_control, tab_xp_tiers,
    tab_k9_profiles, tab_audit -- verified directly against
    html/tablet.js's own buildTabs() body before this file was written,
    not assumed). A future tab that broke this convention would ALSO
    break buildTabs()'s own established pattern, which is a repo-wide
    convention question for whoever adds it, not something this one spec
    can single-handedly enforce -- see tests/commandreferenceregistry_spec.lua's
    own "WHY THIS CANNOT BE... INSTEAD" section for the identical
    trade-off already accepted for COMMAND_REFERENCE.

    WHY TEXT-PATTERN EXTRACTION, NOT A LOADED/EXECUTED FILE: html/tablet.js
    is a browser NUI page with DOM globals this plain-Lua sandbox does not
    provide -- reading the real source text directly is this suite's
    already-established way to check a fact about that file (see
    tests/commandreferenceregistry_spec.lua's own header, and
    tests/customizationregistry_spec.lua's).
]]

local t = dofile('testkit.lua')

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

--- Every `tab_*` key name in html/tablet.js's own `var DEFAULT_STRINGS = {
--- ... };` block -- same start/end anchors and same accept-both-quote-styles
--- line pattern as tests/tabletlocalization_spec.lua's own
--- ExtractDefaultStringsKeys(), narrowed here to the `tab_` prefix this
--- codebase's own tab-button labels already use.
--- @param text string
--- @return table<string, boolean> set
local function ExtractRealTabKeys(text)
    local startPos = text:find('var DEFAULT_STRINGS = {', 1, true)
    assert(startPos, 'var DEFAULT_STRINGS = { not found in html/tablet.js or html/tablet-catalog.js -- this file must have changed shape')
    local endPos = text:find('\n    };', startPos, true)
    assert(endPos, 'closing "};" for DEFAULT_STRINGS not found in html/tablet.js or html/tablet-catalog.js')
    local body = text:sub(startPos, endPos)

    local set = {}
    for line in body:gmatch('[^\n]+') do
        local key = line:match("^%s+(tab_[%a_][%w_]*):%s*['\"]")
        if key then set[key] = true end
    end
    return set
end

--- Every `tabLabelKey: '...'` value inside html/tablet.js's own
--- `var HELP_TAB_CATALOG = [ ... ];` array literal, by the same raw-text
--- pattern tests/commandreferenceregistry_spec.lua's own
--- ExtractDocumentedCommandNames() uses for COMMAND_REFERENCE.
--- @param text string
--- @return table<string, boolean> set
local function ExtractHelpCatalogTabKeys(text)
    local startPos = text:find('var HELP_TAB_CATALOG = [', 1, true)
    assert(startPos, 'var HELP_TAB_CATALOG = [ not found in html/tablet.js or html/tablet-catalog.js -- this file must have changed shape')
    local endPos = text:find('\n    ];', startPos, true)
    assert(endPos, 'closing "];" for HELP_TAB_CATALOG not found in html/tablet.js or html/tablet-catalog.js')
    local body = text:sub(startPos, endPos)

    local set = {}
    for name in body:gmatch("tabLabelKey:%s*'(tab_[%a%d_]+)'") do
        set[name] = true
    end
    return set
end

--- @param set table<string, boolean>
--- @return string[] sortedNames, integer count
local function SortedKeys(set)
    local out = {}
    for key in pairs(set) do out[#out + 1] = key end
    table.sort(out)
    return out, #out
end

t.test('LOAD-BEARING DRIFT GUARD: every tab_* DEFAULT_STRINGS key has a matching HELP_TAB_CATALOG entry, and vice versa', function()
    local text = (ReadFile('../html/tablet.js') .. ReadFile('../html/tablet-catalog.js'))
    local realTabs = ExtractRealTabKeys(text)
    local documented = ExtractHelpCatalogTabKeys(text)

    local undocumented = {}
    for name in pairs(realTabs) do
        if not documented[name] then undocumented[#undocumented + 1] = name end
    end

    local phantom = {}
    for name in pairs(documented) do
        if not realTabs[name] then phantom[#phantom + 1] = name end
    end

    if #undocumented > 0 then
        table.sort(undocumented)
        error((
            '%d real tab_* label key(s) exist in html/tablet.js\'s DEFAULT_STRINGS with NO matching entry in ' ..
            "HELP_TAB_CATALOG: %s.\n\nA tab was added (or renamed) without teaching the Help screen about it -- " ..
            'a player reading "Every Tab, Explained" would never learn this tab exists. FIX THIS BY: adding a ' ..
            "{ tabLabelKey: '<name>', descKey: '...', visible: ... } entry to HELP_TAB_CATALOG (plus its own " ..
            'descKey string to DEFAULT_STRINGS, client/tablet.lua\'s TABLET_STRING_KEYS, and locales/en.json\'s ' ..
            '`tablet` group) in the SAME change that adds the tab.'
        ):format(#undocumented, table.concat(undocumented, ', ')), 0)
    end

    if #phantom > 0 then
        table.sort(phantom)
        error((
            "%d entr(ies) in html/tablet.js's HELP_TAB_CATALOG name a tab_* key that is NOT a real DEFAULT_STRINGS " ..
            'entry: %s.\n\nEither the tab was renamed/removed and this catalog entry was never updated to match, ' ..
            'or it is a typo. FIX THIS BY: deleting the stale HELP_TAB_CATALOG entry (and its now-orphaned ' ..
            'descKey string in DEFAULT_STRINGS/TABLET_STRING_KEYS/locales/en.json), or correcting the spelling.'
        ):format(#phantom, table.concat(phantom, ', ')), 0)
    end

    -- Sanity floor -- a catastrophe detector, not a real limit (same
    -- established convention as tests/commandreferenceregistry_spec.lua's
    -- own): guards against BOTH extractors silently matching nothing at
    -- all, which would make the two loops above pass vacuously on two
    -- empty sets. Deliberately NOT the real count (15 as of this pass).
    local _, realCount = SortedKeys(realTabs)
    local _, documentedCount = SortedKeys(documented)
    t.isTrue(realCount >= 10, ('sanity: only found %d real tab_* key(s) in DEFAULT_STRINGS -- expected at least 10; an extraction pattern may be out of date'):format(realCount))
    t.isTrue(documentedCount >= 10, ('sanity: only found %d documented tab(s) in HELP_TAB_CATALOG -- expected at least 10'):format(documentedCount))
end)

t.test('no duplicate tabLabelKey entries within HELP_TAB_CATALOG (a copy-pasted entry would silently mask a genuinely undocumented tab)', function()
    local text = (ReadFile('../html/tablet.js') .. ReadFile('../html/tablet-catalog.js'))
    local startPos = text:find('var HELP_TAB_CATALOG = [', 1, true)
    assert(startPos, 'var HELP_TAB_CATALOG = [ not found in html/tablet.js or html/tablet-catalog.js')
    local endPos = text:find('\n    ];', startPos, true)
    assert(endPos, 'closing "];" for HELP_TAB_CATALOG not found in html/tablet.js or html/tablet-catalog.js')
    local body = text:sub(startPos, endPos)

    local seen = {}
    local duplicates = {}
    for name in body:gmatch("tabLabelKey:%s*'(tab_[%a%d_]+)'") do
        if seen[name] then duplicates[#duplicates + 1] = name end
        seen[name] = true
    end

    if #duplicates > 0 then
        error('duplicate tabLabelKey entr(ies) in HELP_TAB_CATALOG: ' .. table.concat(duplicates, ', '), 0)
    end
end)

os.exit(t.summary())
