--[[
    tests/helpquotedlabels_spec.lua

    DRIFT GUARD for a small, named set of exceptions the Help screen's own
    header (html/tablet.js, the block starting "HELP -- owner's own words")
    discloses up front: a handful of its step-by-step walkthrough sentences
    quote REAL in-game button/menu text VERBATIM (so a player can match
    what they read here against what they actually see), but that text
    lives in a DIFFERENT locale namespace (`partnership`, `radial`,
    `vehicle`, `search`, `medkit`, `common`) than the `tablet` group this
    whole screen otherwise resolves everything from -- client/tablet.lua's
    BuildTabletStrings() only ever sends the `tablet` group to the
    frontend (see TABLET_STRING_KEYS), so these specific quotes cannot be
    derived live via S(...) the way this same pass derives
    {certifyLabel}/{assignLabel}/{revertLabel} (all three ARE in the
    `tablet` group, and ARE filled from S('certify_label')/
    S('role_assign_label')/S('role_revert_label') at render time -- see
    buildHelpTasksSection()).

    THIS FILE'S JOB, AND ONLY THIS FILE'S JOB: for each of those quotes,
    prove the `tablet.<help key>` string in locales/en.json still CONTAINS
    the REAL, live value of the OTHER namespace's key it quotes. No
    expected English text is hardcoded anywhere below -- the "expected"
    value on each row IS whatever locales/en.json's real key currently
    says, read fresh every run, so this test never needs a manual bump
    when the quoted copy is deliberately reworded elsewhere; it only ever
    fails when the two go OUT OF SYNC with each other, which is exactly
    the drift this file exists to catch (a real button/menu label renamed
    without this screen's own copy of it being updated to match, leaving
    a play reading confidently wrong instructions -- the exact
    "confidently tells people the wrong thing" failure mode this task's
    own brief calls out by name).

    Reads locales/en.json via tests/fixtures/sandbox.lua's own
    Sandbox.locale() (the same reader tests/tabletlocalization_spec.lua
    already relies on) rather than html/tablet.js's DEFAULT_STRINGS: this
    is a check about two REAL locales/en.json entries agreeing with each
    other, so that is the one file this spec needs to read.
]]

local t = dofile('testkit.lua')

-- Reuses tests/fixtures/sandbox.lua's own Sandbox.locale() -- the SAME
-- `locales/en.json` reader tests/tabletlocalization_spec.lua already
-- relies on -- rather than a second, independent JSON parser: one parsed
-- copy of `en.json` per spec RUN either way (Sandbox.locale caches it
-- internally), so there is no cost to reusing it, and any future change
-- to how this suite reads locale files only ever needs fixing in one
-- place.
local Sandbox = dofile('fixtures/sandbox.lua')
local locale = Sandbox.locale

-- Every row: the `tablet` group help key(s) that quote a real button/menu
-- label verbatim, and the (namespace, key) the real label actually lives
-- at. `helpKeys` is a list because the SAME quoted phrase legitimately
-- appears in more than one walkthrough sentence (e.g. "Partner Up" is
-- mentioned in both the K9 track's own Start Here step and the Partner Up
-- task walkthrough) -- every one of them must stay in sync, not just one.
local QUOTED_LABEL_CHECKS = {
    { helpKeys = { 'help_start_k9_4', 'help_task_partner_up_2' }, namespace = 'partnership', key = 'partner_up_target_label' },
    { helpKeys = { 'help_task_partner_up_4' }, namespace = 'radial', key = 'partner_toggle_label' },
    { helpKeys = { 'help_task_vehicle_2' }, namespace = 'vehicle', key = 'target_enter_label' },
    { helpKeys = { 'help_task_vehicle_3' }, namespace = 'vehicle', key = 'target_exit_label' },
    { helpKeys = { 'help_task_search_2' }, namespace = 'search', key = 'person_target_label' },
    { helpKeys = { 'help_task_search_2' }, namespace = 'search', key = 'vehicle_target_label' },
    { helpKeys = { 'help_task_treat_2' }, namespace = 'medkit', key = 'treat_target_label' },
    { helpKeys = { 'help_trouble_no_k9_access_title' }, namespace = 'common', key = 'no_k9_access' },
    -- ADDED (this pass): Deploy a Kennel / Use Scent Vision walkthroughs --
    -- see html/tablet.js's own DEFAULT_STRINGS comment at these same keys.
    -- REPOINTED (menu-parity/menu-audit pass): the radial item this
    -- walkthrough quotes was merged into 'k9_kennel'
    -- (locale('radial.kennel_label'), "Kennel (Deploy/Enter/Exit)") --
    -- see html/tablet.js's own comment at help_task_kennel_1/_4 for the
    -- full writeup. This row now checks against the LIVE key; the old
    -- 'radial.deploy_kennel_label' this used to point at is fully orphaned
    -- (no code or test reference left anywhere) and reported for removal to
    -- whoever owns the `radial` locale group.
    { helpKeys = { 'help_task_kennel_1', 'help_task_kennel_4' }, namespace = 'radial', key = 'kennel_label' },
    { helpKeys = { 'help_task_kennel_2' }, namespace = 'kennel', key = 'pickup_target_label' },
    { helpKeys = { 'help_task_kennel_3' }, namespace = 'kennel', key = 'enter_target_label' },
    { helpKeys = { 'help_task_kennel_3' }, namespace = 'kennel', key = 'exit_target_label' },
    { helpKeys = { 'help_task_scent_vision_1' }, namespace = 'tracking', key = 'scent_vision_keybind_label' },
}

t.test('every Help-screen quoted button/menu label still contains the REAL, live text from the namespace it quotes', function()
    for _, check in ipairs(QUOTED_LABEL_CHECKS) do
        local realKey = check.namespace .. '.' .. check.key
        local ok, realValue = pcall(locale, realKey)
        t.isTrue(ok and type(realValue) == 'string' and #realValue > 0,
            ('locale(\'%s\') should resolve to a non-empty string'):format(realKey))

        for _, helpKey in ipairs(check.helpKeys) do
            local helpFullKey = 'tablet.' .. helpKey
            local helpOk, helpValue = pcall(locale, helpFullKey)
            t.isTrue(helpOk and type(helpValue) == 'string' and #helpValue > 0,
                ('locale(\'%s\') should resolve to a non-empty string'):format(helpFullKey))
            if ok and helpOk then
                t.isTrue(helpValue:find(realValue, 1, true) ~= nil,
                    ('%s should quote the CURRENT real text of %s (%q) verbatim, but does not -- either %s was ' ..
                     'renamed and this Help sentence was not updated to match, or the quote in %s was mistyped'
                    ):format(helpFullKey, realKey, realValue, realKey, helpFullKey))
            end
        end
    end
end)

os.exit(t.summary())
