--[[
    tests/schemaconvergence_spec.lua

    Regression guard for the exact bug class an earlier db-schema pass found
    and fixed by hand: `sql/migrations/0011_create_k9_equipment_shop_locations.sql`
    created two real tables that were never added to `sql/install.sql`,
    `sql/preflight_check.sql`, `sql/rollback/uninstall_all.sql` or
    `sql/rollback/backup_k9_tables.sh` -- so a fresh install landed FOURTEEN
    tables instead of sixteen, and a backup taken right before an uninstall
    would silently not have protected the two missing ones. Every one of
    those files says, in its own header, that this is a hand-maintained list
    with a real drift risk every time a migration adds a table -- this spec
    is the automated backstop those headers ask for, run on every commit
    instead of only when a human happens to re-read five files side by side.

    WHAT THIS DOES NOT DO: it does not connect to a database, and it does not
    parse full SQL grammar. Like tests/tabletlocalization_spec.lua (same
    technique, applied to html/tablet.js's DEFAULT_STRINGS instead of a k9_*
    table list), it extracts the SET OF TABLE NAMES each file commits to
    knowing about, using a narrow pattern matched against each file's own
    real, already-established text shape -- precise enough to catch a table
    completely missing from one of these files (the actual historical bug),
    not a substitute for `sql/preflight_check.sql`'s own live
    INFORMATION_SCHEMA drift checks, which need a real database connection
    this spec deliberately does not require.

    TABLE NAMES ARE NOT THE WHOLE STORY, so this spec also extracts and
    compares the identifying-COLUMN lists carried inside `sql/preflight_check
    .sql`'s CHECK 1, BOTH per-table signature blocks inside
    `sql/rollback/uninstall_all.sql` (the SHAPE GATE and its own internal
    duplicate in the DEPENDENCY REPORT's DRIFT CHECK branch), and
    `server/datastore.lua`'s `EXPECTED_TABLE_COLUMNS` -- see the "COLUMN-LEVEL
    EXTRACTION"/"COLUMN-LEVEL CONVERGENCE" sections further down. A table
    NAME agreeing everywhere says nothing about whether these four places
    agree on WHICH COLUMNS make that table "ours" on a real name collision;
    a silent disagreement there is the gap a second, independent review of
    this resource's uninstall safety work found and flagged as the one that
    matters most, since these four lists have no way to `require()`/import a
    shared source of truth and are, by every one of their own header
    comments, hand-maintained copies that must be kept in sync by hand.

    `sql/install.sql` is treated as the ONE authoritative source of "every
    table this resource owns" -- its own top-of-file header states the
    number in English every time a table is added specifically so a count
    like this can be checked against it. Every other file below is asserted
    to know about EXACTLY that same set: no table missing (the historical
    bug), and no stale table name left behind after a rename (the mirror-image
    mistake, just as real -- a script that thinks it is protecting/dropping a
    table that no longer exists is giving an operator false confidence).
]]

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

--- Every `k9_<name>` token matched by `pattern` (which must contain exactly
--- one capture group around the table name), collected into a set.
--- @param text string
--- @param pattern string
--- @return table<string, boolean> set, integer count
local function ExtractTableSet(text, pattern)
    local set, count = {}, 0
    for name in text:gmatch(pattern) do
        if not set[name] then
            set[name] = true
            count = count + 1
        end
    end
    return set, count
end

--- @param set table<string, boolean>
--- @return string[] -- sorted, for stable/readable failure messages
local function SortedKeys(set)
    local out = {}
    for k in pairs(set) do out[#out + 1] = k end
    table.sort(out)
    return out
end

--- @param set table<string, boolean>
--- @return string
local function Describe(set)
    local keys = SortedKeys(set)
    if #keys == 0 then return '(none)' end
    return table.concat(keys, ', ')
end

--- Fails with a readable diff (not just "false") the same way every other
--- structural-equality helper in this suite (e.g. tests/tabletlocalization_spec.lua's
--- own key-set comparisons) already reports mismatches.
--- @param actual table<string, boolean>
--- @param expected table<string, boolean>
--- @param label string
local function AssertSameTableSet(actual, expected, label)
    local missing, extra = {}, {}
    for name in pairs(expected) do
        if not actual[name] then missing[#missing + 1] = name end
    end
    for name in pairs(actual) do
        if not expected[name] then extra[#extra + 1] = name end
    end
    table.sort(missing)
    table.sort(extra)
    if #missing > 0 or #extra > 0 then
        error(('%s does not match install.sql\'s table set -- missing: [%s]; unexpected/stale: [%s]'):format(
            label, table.concat(missing, ', '), table.concat(extra, ', ')), 2)
    end
end

-- ----------------------------------------------------------------------
-- COLUMN-LEVEL EXTRACTION -- everything above this line compares only the
-- SET OF TABLE NAMES each file knows about. That is not the whole story:
-- sql/preflight_check.sql's CHECK 1, BOTH per-table column-signature
-- blocks inside sql/rollback/uninstall_all.sql (the SHAPE GATE itself and
-- the near-identical block inside its DEPENDENCY REPORT's DRIFT CHECK
-- branch -- see that file's own "OWNED TABLE LIST" comment, which admits
-- outright that these are independently hand-typed and can drift), and
-- server/datastore.lua's EXPECTED_TABLE_COLUMNS do not just need to agree
-- on WHICH tables they know about -- they need to agree on WHICH COLUMNS
-- identify each one of those tables as "ours" on a real name collision.
-- Two files that both list `k9_permission_keys` but disagree on its
-- identifying columns can give a real operator a different verdict --
-- "OK, safe to install" from one file, "!! CONFLICT" from the other -- on
-- the exact same foreign table. That disagreement is invisible to every
-- test above this line, which only ever checks that a table NAME appears
-- somewhere in each file, never what its signature there actually is.
--
-- All four of these locations share (or, for server/datastore.lua's Lua
-- table, closely mirror) the same textual shape they were hand-written
-- in: a per-table `SELECT 'k9_x' AS table_name, N AS cols_expected, ...,
-- COLUMN_NAME IN ('c1','c2',...)` block for the three .sql locations, and
-- a `k9_x = { 'c1', 'c2', ... }` entry for the one Lua location. The
-- functions below extract the REAL column set each one commits to, from
-- each file's own real text, same technique as ExtractTableSet above --
-- not a fifth hand-typed copy of the answer.
-- ----------------------------------------------------------------------

--- Matches one `SELECT 'k9_x'[ AS table_name], N[ AS cols_expected], ...,
--- COLUMN_NAME IN ('c1','c2',...)` block, in either of the two real
--- shapes this resource's .sql files use for it (the FIRST row in a
--- UNION ALL chain spells out `AS table_name`/`AS cols_expected`; every
--- row after it does not, since those column aliases only need stating
--- once per query) -- capturing the table name, the declared
--- `cols_expected` number, and the raw text inside `COLUMN_NAME IN (...)`.
--- The two `.-` gaps are Lua's lazy "as few characters as possible"
--- quantifier, which is what lets one pattern match both row shapes: each
--- walks forward only as far as the next literal comma/`COLUMN_NAME IN`,
--- never past it, so it cannot accidentally swallow a later table's row.
local SQL_SIGNATURE_PATTERN = "SELECT%s+'(k9_[%w_]+)'.-,%s*(%d+).-,.-COLUMN_NAME IN %(([^%)]+)%)"

--- @param text string
--- @return table<string, {columns: table<string,boolean>, count: integer, expected: integer}>
local function ExtractSqlColumnSignatures(text)
    local signatures = {}
    for tableName, expected, columnListText in text:gmatch(SQL_SIGNATURE_PATTERN) do
        local columns, count = {}, 0
        for column in columnListText:gmatch("'([^']+)'") do
            if not columns[column] then
                columns[column] = true
                count = count + 1
            end
        end
        signatures[tableName] = { columns = columns, count = count, expected = tonumber(expected) }
    end
    return signatures
end

--- server/datastore.lua's EXPECTED_TABLE_COLUMNS uses plain Lua table
--- syntax, not SQL -- `k9_x = { 'c1', 'c2', ... },` -- so it needs its own
--- extraction shape, but the same idea: pull the real column list out of
--- the file's own text rather than retyping it.
--- @param tableBody string -- already isolated to the `{ ... }` body, the
--- same substring the existing EXPECTED_TABLE_COLUMNS name-set test above
--- computes from `local EXPECTED_TABLE_COLUMNS = {` through the closing `}`
--- @return table<string, {columns: table<string,boolean>, count: integer}>
local function ExtractLuaColumnSignatures(tableBody)
    local signatures = {}
    for tableName, columnListText in tableBody:gmatch("(k9_[%w_]+)%s*=%s*{([^}]*)}") do
        local columns, count = {}, 0
        for column in columnListText:gmatch("'([^']+)'") do
            if not columns[column] then
                columns[column] = true
                count = count + 1
            end
        end
        signatures[tableName] = { columns = columns, count = count }
    end
    return signatures
end

--- sql/rollback/uninstall_all.sql contains the signature block TWICE (see
--- that file's own "OWNED TABLE LIST" comment) -- the SHAPE GATE itself
--- (`shape_blockers`) and the near-identical block inside the DEPENDENCY
--- REPORT's DRIFT CHECK branch (`shp2`). Both open with the shared
--- `FROM (` a per-table UNION ALL chain opens with, and each is closed by
--- its own uniquely-spelled subquery alias -- `) shp` for the first
--- block, `) shp2` for the second. Matching the closing alias literally
--- (rather than, say, counting balanced parentheses) is deliberate: the
--- literal bytes `) shp` followed by a newline are NOT a substring of
--- `) shp2` (the character right after "shp" differs -- newline vs "2"),
--- so searching for `) shp\n` specifically can never accidentally stop
--- early inside the second block's own close.
--- @param text string -- the whole file's text
--- @param afterAnchor string -- unique literal text appearing once, shortly before this block's own "FROM ("
--- @param closeMarker string -- unique literal text this block's own "FROM (...)" closes with
--- @return string -- the block's own text, `FROM (` through the close marker inclusive
local function SliceUninstallSignatureBlock(text, afterAnchor, closeMarker)
    local anchorPos = text:find(afterAnchor, 1, true)
    assert(anchorPos, ('could not find %q in sql/rollback/uninstall_all.sql -- this file must have changed shape'):format(afterAnchor))
    local fromPos = text:find('FROM (', anchorPos, true)
    assert(fromPos, ('could not find "FROM (" after %q in sql/rollback/uninstall_all.sql'):format(afterAnchor))
    local closePos = text:find(closeMarker, fromPos, true)
    assert(closePos, ('could not find %q after %q in sql/rollback/uninstall_all.sql'):format(closeMarker, afterAnchor))
    return text:sub(fromPos, closePos)
end

--- Fails with a message naming the table, naming BOTH files, and showing
--- which columns are on which side of the disagreement -- the "what do I
--- change" an operator or agent needs at 2am, not just "these two
--- disagree".
--- @param signaturesA table<string, {columns: table<string,boolean>}>
--- @param labelA string
--- @param signaturesB table<string, {columns: table<string,boolean>}>
--- @param labelB string
local function AssertSameColumnSignatures(signaturesA, labelA, signaturesB, labelB)
    local tableNames, seen = {}, {}
    for name in pairs(signaturesA) do
        if not seen[name] then seen[name] = true; tableNames[#tableNames + 1] = name end
    end
    for name in pairs(signaturesB) do
        if not seen[name] then seen[name] = true; tableNames[#tableNames + 1] = name end
    end
    table.sort(tableNames)

    local problems = {}
    for _, tableName in ipairs(tableNames) do
        local a, b = signaturesA[tableName], signaturesB[tableName]
        if not a then
            problems[#problems + 1] = ('  %s: %s has a signature for this table, but %s has none at all'):format(tableName, labelB, labelA)
        elseif not b then
            problems[#problems + 1] = ('  %s: %s has a signature for this table, but %s has none at all'):format(tableName, labelA, labelB)
        else
            local onlyInA, onlyInB = {}, {}
            for column in pairs(a.columns) do
                if not b.columns[column] then onlyInA[#onlyInA + 1] = column end
            end
            for column in pairs(b.columns) do
                if not a.columns[column] then onlyInB[#onlyInB + 1] = column end
            end
            if #onlyInA > 0 or #onlyInB > 0 then
                table.sort(onlyInA)
                table.sort(onlyInB)
                problems[#problems + 1] = ('  %s: %s has [%s] that %s does not; %s has [%s] that %s does not'):format(
                    tableName, labelA, table.concat(onlyInA, ', '), labelB, labelB, table.concat(onlyInB, ', '), labelA)
            end
        end
    end

    if #problems > 0 then
        error(('%s and %s disagree on the identifying-column signature for %d table(s) -- a real name collision could get a different verdict from each:\n%s'):format(
            labelA, labelB, #problems, table.concat(problems, '\n')), 2)
    end
end

-- ----------------------------------------------------------------------
-- GROUND TRUTH: every `CREATE TABLE IF NOT EXISTS \`k9_...\`` in
-- sql/install.sql. This file's own header states the count in English
-- ("sixteen tables") for exactly this reason -- a human or a test can check
-- the real count against that sentence.
-- ----------------------------------------------------------------------
local installText = ReadFile('../sql/install.sql')
local installTables, installCount = ExtractTableSet(installText, 'CREATE TABLE IF NOT EXISTS `(k9_[%w_]+)`')

t.test('sql/install.sql creates at least sixteen k9_* tables (the documented floor)', function()
    t.isTrue(installCount >= 16, ('expected >= 16 CREATE TABLE statements in install.sql, found %d: %s'):format(installCount, Describe(installTables)))
end)

t.test('sql/install.sql\'s own header sentence names the real table count', function()
    -- Loose on purpose (a plain substring search over the whole file, not a
    -- hardcoded literal "sixteen" compared for exact equality): this only
    -- needs to catch install.sql growing a 17th table with nobody updating
    -- the header prose at all, not police exact wording or exact placement.
    t.isTrue(installText:find('sixteen', 1, true) ~= nil or installText:find(tostring(installCount), 1, true) ~= nil,
        'install.sql no longer mentions a table count consistent with its own real CREATE TABLE statements -- update the header prose in the same change that adds/removes a table')
end)

-- ----------------------------------------------------------------------
-- sql/preflight_check.sql -- CHECK 1's per-table `SELECT 'k9_x' AS
-- table_name, N AS cols_expected, ...` block. This is the exact file/shape
-- migration 0011's two tables were missing from before the earlier
-- db-schema pass added them.
-- ----------------------------------------------------------------------
t.test('sql/preflight_check.sql\'s CHECK 1 knows about exactly install.sql\'s table set', function()
    local text = ReadFile('../sql/preflight_check.sql')
    local tables = ExtractTableSet(text, "SELECT '(k9_[%w_]+)'")
    AssertSameTableSet(tables, installTables, 'sql/preflight_check.sql (CHECK 1)')
end)

-- ----------------------------------------------------------------------
-- sql/migration_status.sql -- the dry-run report's own per-table
-- `SELECT 'k9_x' AS table_name, ...` blocks (PART 1's fresh-install plan
-- plus every per-migration PART 2 continuation -- all draw from the same
-- `SELECT 'k9_x'` shape, so one pattern covers the whole file).
-- ----------------------------------------------------------------------
t.test('sql/migration_status.sql knows about exactly install.sql\'s table set', function()
    local text = ReadFile('../sql/migration_status.sql')
    local tables = ExtractTableSet(text, "SELECT '(k9_[%w_]+)'")
    AssertSameTableSet(tables, installTables, 'sql/migration_status.sql')
end)

-- ----------------------------------------------------------------------
-- sql/rollback/uninstall_all.sql -- the actual DROP TABLE list at the
-- bottom of the procedure. This is the list whose own header explicitly
-- says "this must be hand-maintained -- if you add a table in a migration,
-- add it here in the SAME change".
-- ----------------------------------------------------------------------
t.test('sql/rollback/uninstall_all.sql\'s DROP TABLE list matches exactly install.sql\'s table set', function()
    local text = ReadFile('../sql/rollback/uninstall_all.sql')
    local tables = ExtractTableSet(text, 'DROP TABLE IF EXISTS `(k9_[%w_]+)`')
    AssertSameTableSet(tables, installTables, 'sql/rollback/uninstall_all.sql (DROP TABLE list)')
end)

-- ----------------------------------------------------------------------
-- sql/rollback/backup_k9_tables.sh -- the ALL_TABLES bash array. A table
-- missing here does not fail loudly -- it just silently is not in the next
-- backup, which is precisely the failure mode this whole spec exists to
-- catch before it reaches a production operator relying on that backup.
-- ----------------------------------------------------------------------
t.test('sql/rollback/backup_k9_tables.sh\'s ALL_TABLES array matches exactly install.sql\'s table set', function()
    local text = ReadFile('../sql/rollback/backup_k9_tables.sh')
    local startPos = text:find('ALL_TABLES=(', 1, true)
    assert(startPos, 'ALL_TABLES=( declaration not found in backup_k9_tables.sh -- this script must have changed shape')
    local closePos = text:find(')', startPos, true)
    assert(closePos, 'no closing ")" found for ALL_TABLES=( in backup_k9_tables.sh')
    local arrayBody = text:sub(startPos, closePos)
    local tables = ExtractTableSet(arrayBody, '(k9_[%w_]+)')
    AssertSameTableSet(tables, installTables, 'sql/rollback/backup_k9_tables.sh (ALL_TABLES)')
end)

-- ----------------------------------------------------------------------
-- server/datastore.lua -- the SCHEMA COLLISION SAFETY NET's own
-- EXPECTED_TABLE_COLUMNS table (see that file's own header, "THE COLUMN
-- LIST BELOW MUST STAY IN SYNC WITH sql/preflight_check.sql's CHECK 1").
-- A table missing here is not a cosmetic gap: VerifyTableShapesAgainstKnownSchema
-- only ever inspects a table it knows to look for, so a table absent from
-- this list can never trip the collision safety net at all -- a different
-- resource's incompatible table squatting that name would go completely
-- undetected, and every K9Store.* accessor for that table would silently
-- write into a table this resource does not own. This is a REAL bug this
-- spec caught by hand once already (k9_permission_keys /
-- k9_permission_key_audit were named by this file's own PermKey_*
-- accessors since migration 0013 landed, but were never added to
-- EXPECTED_TABLE_COLUMNS at all) -- this test is the automated backstop so
-- the next migration cannot reintroduce the exact same gap silently.
-- ----------------------------------------------------------------------
t.test('server/datastore.lua\'s EXPECTED_TABLE_COLUMNS (schema collision safety net) knows about exactly install.sql\'s table set', function()
    local text = ReadFile('../server/datastore.lua')
    local startPos = text:find('local EXPECTED_TABLE_COLUMNS = {', 1, true)
    assert(startPos, 'local EXPECTED_TABLE_COLUMNS = { not found in server/datastore.lua -- this file must have changed shape')
    local closePos = text:find('\n}', startPos, true)
    assert(closePos, 'closing "}" for EXPECTED_TABLE_COLUMNS not found in server/datastore.lua')
    local tableBody = text:sub(startPos, closePos)
    local tables = ExtractTableSet(tableBody, '(k9_[%w_]+)%s*=%s*{')
    AssertSameTableSet(tables, installTables, 'server/datastore.lua (EXPECTED_TABLE_COLUMNS)')
end)

-- ----------------------------------------------------------------------
-- COLUMN-LEVEL CONVERGENCE -- the gap the table-name checks above cannot
-- see: every "knows about exactly install.sql's table set" test above
-- only checked that (say) `k9_permission_keys` appears in CHECK 1
-- SOMEWHERE, never that CHECK 1's own idea of "these are
-- k9_permission_keys' identifying columns" agrees with
-- sql/rollback/uninstall_all.sql's (either of its own two internal
-- copies) or server/datastore.lua's idea of the same thing. If a future
-- migration widens which columns identify a table as ours in ONE of
-- these places without doing the same in the others -- exactly the
-- "change all three [places] in the same commit" instruction each of
-- these files already gives by hand, in prose, and which this resource
-- has been bitten by before (see e.g. sql/preflight_check.sql's own
-- "BOOT-CHECK SYNC" comments on its `k9_individual_overrides`,
-- `k9_equipment_shop_items` and `k9_xp_tiers` rows, each documenting a
-- real, already-happened drift against server/datastore.lua fixed by
-- hand) -- the two files then disagree about what "this table is ours"
-- means. On a real name collision with some other resource's table, that
-- disagreement can hand the operator a clean "OK, safe to install" from
-- one file and a "!! CONFLICT, do not install" from the other for the
-- SAME foreign table, or let an armed uninstall drop a table its own
-- second internal copy of this same check would have refused. Compared
-- here by parsing each file's own real text (see the extraction helpers
-- above this file's GROUND TRUTH section), not by re-hardcoding the
-- answer a fifth time.
-- ----------------------------------------------------------------------

local preflightColumnSignatures = ExtractSqlColumnSignatures(ReadFile('../sql/preflight_check.sql'))

local uninstallAllText = ReadFile('../sql/rollback/uninstall_all.sql')
local uninstallShapeGateColumnSignatures = ExtractSqlColumnSignatures(
    SliceUninstallSignatureBlock(uninstallAllText, 'INTO shape_blockers', ') shp\n'))
local uninstallDriftCheckColumnSignatures = ExtractSqlColumnSignatures(
    SliceUninstallSignatureBlock(uninstallAllText, 'BLOCKS UNINSTALL - table name is not ours', ') shp2'))

local datastoreTextForColumns = ReadFile('../server/datastore.lua')
local datastoreBodyStart = datastoreTextForColumns:find('local EXPECTED_TABLE_COLUMNS = {', 1, true)
assert(datastoreBodyStart, 'local EXPECTED_TABLE_COLUMNS = { not found in server/datastore.lua -- this file must have changed shape')
local datastoreBodyClose = datastoreTextForColumns:find('\n}', datastoreBodyStart, true)
assert(datastoreBodyClose, 'closing "}" for EXPECTED_TABLE_COLUMNS not found in server/datastore.lua')
local datastoreColumnSignatures = ExtractLuaColumnSignatures(datastoreTextForColumns:sub(datastoreBodyStart, datastoreBodyClose))

-- Sanity check on the three SQL sources' OWN internal consistency, a
-- precondition for the cross-file comparisons below to mean anything:
-- each row's hand-typed `N AS cols_expected` should equal the real length
-- of that same row's own `COLUMN_NAME IN (...)` list. If it does not,
-- that row's own `COUNT(*) = N` comparison at query time is already wrong
-- before any cross-file comparison even happens -- either it reports a
-- genuine one-of-ours table as a false CONFLICT because N is too high, or
-- accepts a foreign table as ours because N is too low.
local SQL_SIGNATURE_SOURCES_FOR_SELF_CHECK = {
    { label = 'sql/preflight_check.sql (CHECK 1)', signatures = preflightColumnSignatures },
    { label = 'sql/rollback/uninstall_all.sql (SHAPE GATE)', signatures = uninstallShapeGateColumnSignatures },
    { label = 'sql/rollback/uninstall_all.sql (DRIFT CHECK)', signatures = uninstallDriftCheckColumnSignatures },
}

for _, source in ipairs(SQL_SIGNATURE_SOURCES_FOR_SELF_CHECK) do
    t.test(("%s's own declared cols_expected matches its own COLUMN_NAME IN (...) list length, for every table"):format(source.label), function()
        local mismatches = {}
        for tableName, signature in pairs(source.signatures) do
            if signature.count ~= signature.expected then
                mismatches[#mismatches + 1] = ('%s (declared %d, found %d)'):format(tableName, signature.expected, signature.count)
            end
        end
        table.sort(mismatches)
        t.isTrue(#mismatches == 0, ('%s: cols_expected does not match the real column list length for: %s'):format(source.label, table.concat(mismatches, '; ')))
    end)
end

-- Every distinct pair of the four real signature-bearing locations, so a
-- drift between ANY two of them fails with a direct, specific message
-- naming exactly that pair -- including sql/rollback/uninstall_all.sql's
-- own two internal copies against each other, the "easiest kind to let
-- drift" pair because both live in one file and a reviewer's eye slides
-- past the second copy assuming it must match the first.
local COLUMN_SIGNATURE_SOURCES = {
    { label = 'sql/preflight_check.sql (CHECK 1)', signatures = preflightColumnSignatures },
    { label = 'sql/rollback/uninstall_all.sql (SHAPE GATE)', signatures = uninstallShapeGateColumnSignatures },
    { label = 'sql/rollback/uninstall_all.sql (DRIFT CHECK)', signatures = uninstallDriftCheckColumnSignatures },
    { label = 'server/datastore.lua (EXPECTED_TABLE_COLUMNS)', signatures = datastoreColumnSignatures },
}

for i = 1, #COLUMN_SIGNATURE_SOURCES do
    for j = i + 1, #COLUMN_SIGNATURE_SOURCES do
        local sourceA, sourceB = COLUMN_SIGNATURE_SOURCES[i], COLUMN_SIGNATURE_SOURCES[j]
        t.test(('%s and %s agree on every table\'s identifying-column signature'):format(sourceA.label, sourceB.label), function()
            AssertSameColumnSignatures(sourceA.signatures, sourceA.label, sourceB.signatures, sourceB.label)
        end)
    end
end


-- ----------------------------------------------------------------------
-- sql/migrations/*.sql -- every table this resource's UPGRADE path (as
-- opposed to a fresh install) knows how to create for an existing
-- database. `k9_certifications` and `k9_search_log` are the two founding
-- tables install.sql has shipped with since before the migrations/ folder
-- existed -- by design there is no dedicated "0000_create_..." file for
-- either, so they are excluded from this specific comparison rather than
-- reported as a false "missing from migrations" failure.
--
-- HAND-MAINTAINED LIST, SAME TRADEOFF THIS RESOURCE'S OWN SQL FILES ALREADY
-- ACCEPT (see e.g. sql/rollback/uninstall_all.sql's own "OWNED TABLE LIST"
-- comment): a plain Lua spec has no INFORMATION_SCHEMA to sweep for a
-- pattern-based drift check the way the real SQL files do against a live
-- database, so a brand-new sql/migrations/0012_*.sql that CREATEs a table
-- must be added to this list in the same change, or this test will not
-- know to look at it. This is disclosed here rather than silently assumed.
-- ----------------------------------------------------------------------
local MIGRATION_FILES_THAT_CREATE_TABLES = {
    '0001_create_k9_partnerships.sql',
    '0002_create_k9_progression.sql',
    '0005_create_k9_permissions.sql',
    '0006_add_k9_certification_lifecycle.sql',
    '0007_create_k9_runtime_control.sql',
    '0008_create_k9_ped_assignments.sql',
    '0010_create_k9_certification_tiers.sql',
    '0011_create_k9_equipment_shop_locations.sql',
    '0013_create_k9_permission_keys.sql',
    '0014_create_k9_equipment_shop_items.sql',
    '0015_create_k9_xp_tiers.sql',
    '0016_create_k9_individual_overrides.sql',
    '0018_create_k9_partnership_pair_progress.sql',
    -- SCHEMA-SAFETY AUDIT FIX (db-schema pass, 2026-08-27): this migration
    -- was missing from this exact list -- meaning this test, whose whole
    -- job is to prove "every table sql/migrations/*.sql can CREATE is also
    -- in install.sql", was never even looking at the one migration file
    -- that had actually drifted (its table, k9_dog_characters, was absent
    -- from install.sql from the day migration 0019 shipped). This is the
    -- automated backstop the next missing entry in this list needs: see
    -- this list's own header comment above for the "why hand-maintained"
    -- tradeoff, and note this incident as proof that a hand-maintained list
    -- like this one is still only as good as its own maintenance.
    '0019_create_k9_dog_characters.sql',
    '0020_create_k9_personnel.sql',
    -- db-schema pass, 2026-08-27 (wellbeing persistence wiring): added from
    -- the start this time, rather than found missing by a later audit --
    -- see this list's own header comment above for why a hand-maintained
    -- list like this one needs every new migration added in the SAME
    -- change that adds the migration file itself.
    '0022_create_k9_wellbeing.sql',
    -- the K9 role catalog (server/roles.lua), listed from the start.
    '0023_create_k9_roles.sql',
    -- role edit history (server/roles.lua), listed from the start.
    '0024_create_k9_role_audit.sql',
}

local FOUNDING_TABLES_WITH_NO_DEDICATED_MIGRATION = {
    k9_certifications = true,
    k9_search_log = true,
}

t.test('every table sql/migrations/*.sql can CREATE for an existing database is also in install.sql (and vice versa, founding tables aside)', function()
    local migrationTables = {}
    for _, filename in ipairs(MIGRATION_FILES_THAT_CREATE_TABLES) do
        local text = ReadFile('../sql/migrations/' .. filename)
        for name in text:gmatch('CREATE TABLE IF NOT EXISTS `(k9_[%w_]+)`') do
            migrationTables[name] = true
        end
    end

    local expected = {}
    for name in pairs(installTables) do
        if not FOUNDING_TABLES_WITH_NO_DEDICATED_MIGRATION[name] then
            expected[name] = true
        end
    end

    AssertSameTableSet(migrationTables, expected, 'sql/migrations/*.sql (CREATE TABLE union, founding tables excluded)')
end)

-- ----------------------------------------------------------------------
-- k9_permissions.permission is VARCHAR(50) and is now also the storage
-- shape for PER-PERSON FEATURE CONTROL grants/blocks
-- (server/permissions.lua's IsValidPermissionKey: 'feature.<Name>' /
-- 'block.<Name>' where <Name> is a real Config.Features key) -- not just
-- the four short Config.Permissions capability strings this column was
-- originally sized for. This is the schema-side half of that design: the
-- column must stay wide enough for the LONGEST real Config.Features key,
-- under BOTH prefixes, or a future long feature name would either be
-- silently rejected by IsValidPermissionKey's own `#value > 50` guard or
-- (if that guard were ever loosened without checking this) truncated by
-- the database instead. Verified here against config.lua's REAL feature
-- list, not a guessed worst case.
-- ----------------------------------------------------------------------
t.test('k9_permissions.permission (VARCHAR(50)) fits "feature."/"block." + the longest real Config.Features key', function()
    local configText = ReadFile('../config.lua')
    local startPos = configText:find('Config.Features = {', 1, true)
    assert(startPos, 'Config.Features = { not found in config.lua -- this file must have changed shape')
    local endPos = configText:find('\n}', startPos, true)
    assert(endPos, 'closing "}" for Config.Features not found')
    local block = configText:sub(startPos, endPos)

    local maxLen, maxKey, keyCount = 0, nil, 0
    for line in block:gmatch('[^\n]+') do
        local key = line:match('^%s*([A-Z][%w]*)%s*=%s*true') or line:match('^%s*([A-Z][%w]*)%s*=%s*false')
        if key then
            keyCount = keyCount + 1
            if #key > maxLen then maxLen, maxKey = #key, key end
        end
    end
    t.isTrue(keyCount >= 20, ('expected at least 20 Config.Features keys, found %d -- extraction pattern may be out of date'):format(keyCount))

    -- Pull the real column width out of install.sql's own k9_permissions
    -- block, rather than hardcoding "50" a second time here.
    local permStart = installText:find('CREATE TABLE IF NOT EXISTS `k9_permissions`', 1, true)
    assert(permStart, 'k9_permissions CREATE TABLE not found in install.sql')
    local permEnd = installText:find('\n) ENGINE=InnoDB', permStart, true)
    assert(permEnd, 'end of k9_permissions CREATE TABLE not found in install.sql')
    local permBlock = installText:sub(permStart, permEnd)
    local columnWidth = tonumber(permBlock:match('`permission`%s+VARCHAR%((%d+)%)'))
    assert(columnWidth, 'could not read k9_permissions.permission\'s VARCHAR width from install.sql')

    for _, prefix in ipairs({ 'feature.', 'block.' }) do
        local needed = #prefix + maxLen
        t.isTrue(needed <= columnWidth,
            ('"%s%s" is %d chars, which does not fit k9_permissions.permission VARCHAR(%d) -- widen the column in install.sql AND a new migration before shipping a Config.Features key this long'):format(prefix, maxKey, needed, columnWidth))
    end
end)

-- ----------------------------------------------------------------------
-- THE DIRECTION EVERY TEST ABOVE MISSES: all of them compare one
-- DECLARATION of the table set against another (install.sql, the
-- migrations, preflight, rollback, EXPECTED_TABLE_COLUMNS). None of them
-- looks at the SQL this resource actually executes. A query naming a
-- table nobody creates is a different, worse failure than a drifted list:
-- it does not show up as a missing row or an unprotected backup, it
-- throws at runtime, on the first player who triggers that code path, on
-- a live server.
--
-- The reverse is worth catching too, though it is only a tidiness
-- finding: a table install.sql creates that no query ever names is dead
-- schema an operator is asked to carry for nothing.
--
-- SCOPE, DELIBERATELY NARROW: this reads real SQL keywords (FROM / INTO /
-- UPDATE / JOIN / TABLE) followed by a `k9_`-prefixed name, with
-- whole-line Lua comments stripped first so a table named only in prose
-- never counts. It does not parse SQL, and it cannot see a table name
-- built by concatenation at runtime -- server/datastore.lua's own header
-- rule ("THE ONLY PLACE IN THIS RESOURCE THAT MAY NAME A `k9_*` TABLE OR
-- CALL `MySQL.*` DIRECTLY") is what keeps that from mattering, and the
-- CONTROL below fails loudly if this extraction ever stops finding
-- anything.
-- ----------------------------------------------------------------------
t.test('every k9_* table named in real SQL anywhere under server/ is created by install.sql, and every table install.sql creates is named by at least one query', function()
    local queried = {}
    local queriedCount = 0

    local handle = assert(io.popen('find ../server -name "*.lua"'))
    local fileList = handle:read('*a')
    handle:close()

    for path in fileList:gmatch('[^\n]+') do
        local text = ReadFile(path:gsub('^%.%./', '../'))
        -- Drop whole-line Lua comments so a table named in a header or a
        -- doc comment is never mistaken for a real query.
        local code = text:gsub('\n%s*%-%-[^\n]*', '\n')
        for keyword, name in code:gmatch('(%a+)%s+`?(k9_[%w_]+)`?') do
            local kw = keyword:upper()
            if kw == 'FROM' or kw == 'INTO' or kw == 'UPDATE' or kw == 'JOIN' or kw == 'TABLE' then
                if not queried[name] then
                    queried[name] = true
                    queriedCount = queriedCount + 1
                end
            end
        end
    end

    -- CONTROL: if the extraction above ever silently stops matching, every
    -- assertion below becomes vacuously true. This is the tripwire.
    t.isTrue(queriedCount >= 20,
        ('only found %d k9_* tables in real SQL under server/ -- the extraction pattern has probably drifted; fix it rather than deleting this check'):format(queriedCount))

    AssertSameTableSet(queried, installTables, 'real SQL executed under server/')
end)

os.exit(t.summary())
