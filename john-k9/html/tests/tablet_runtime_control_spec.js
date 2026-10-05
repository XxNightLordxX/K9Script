/*
    html/tests/tablet_runtime_control_spec.js

    Covers the Runtime Control screen (its own tab, high command OR a
    delegated 'k9.runtimecontrol' grant -- server/runtimecontrol.lua's own
    CanManageRuntimeControl(source): IsHighCommand(source) OR
    HasPermission(citizenid, 'k9.runtimecontrol') == true,
    tests/runtimecontrol_spec.lua:523. Client-side gate: html/tablet.js's
    canManageRuntimeControl()) -- server/runtimecontrol.lua PART 1/1B.
    Owner's own words: "Lets high command switch features on and off
    SERVER-WIDE from the tablet, and tune numbers live."

    Server contract verified against server/runtimecontrol.lua directly
    (not assumed): runtimeListFeatures/runtimeListTunables each return
    `{ok, features?/tunables?, reason?}`; runtimeSetFeature/ResetFeature/
    SetTunable/ResetTunable each return `{ok, ..., reason?}` -- `reason`
    renamed to `error` by client/tablet.lua's TranslateReasonResult before
    it ever reaches this page, so every failure fixture below uses `error`,
    never `reason`.

    THE HONESTY REQUIREMENT is this file's main subject: a feature's `tier`
    ('live'|'onstart'|'rawtoplevel'|'clientonly'|'protected'|'unaudited')
    must render a plain-language explanation BEFORE any click, a
    protected/unaudited feature must render NO toggle at all, and a
    tunable's out-of-range refusal must echo the server's REAL min/max, not
    a client-guessed one.

    Every gate below is asserted as a CONVENIENCE, per html/tablet.js's own
    THE SECURITY RULE -- covered server-side in
    tests/runtimecontrol_spec.lua/tests/runtimefeaturetiers_spec.lua/
    tests/clienttabletruntimecontrol_spec.lua.
*/
'use strict';

const t = require('./testkit');
const { createHarness, jsonResponse } = require('./tablet-sandbox');
const { findByText, findAll, openSettingsSection, findByClass } = require('./tablet-dom-stub');

function routeFetch(handlers) {
    return function (url, init) {
        const name = url.split('/').pop();
        const body = init && init.body ? JSON.parse(init.body) : undefined;
        const h = handlers[name];
        if (!h) return Promise.reject(new Error('tablet_runtime_control_spec: unhandled NUI callback ' + name));
        return Promise.resolve(jsonResponse(h(body)));
    };
}

const HIGH_COMMAND_VIEWER = { citizenid: 'HC1', name: 'Chief', isHighCommand: true, effectivePermissions: ['k9.access', 'k9.certify', 'k9.audit', 'k9.givexp'], allowSelfGrant: false };
const CONSOLE_ONLY_VIEWER = { citizenid: 'OFFICER1', name: 'Officer', isHighCommand: false, effectivePermissions: ['k9.certify'], allowSelfGrant: false };
// Holds the delegated capability but is NOT high command -- server/
// runtimecontrol.lua's own CanManageRuntimeControl admits this exact
// citizenid (see this file's header). See canManageRuntimeControl()'s own
// doc comment.
const DELEGATED_RUNTIME_CONTROL_VIEWER = { citizenid: 'DELEGATE1', name: 'Delegate', isHighCommand: false, effectivePermissions: ['k9.certify', 'k9.runtimecontrol'], allowSelfGrant: false };

async function settle(times) {
    for (let i = 0; i < (times || 3); i++) await new Promise((r) => setImmediate(r));
}

function baseHandlers(overrides) {
    return Object.assign({
        'tablet:requestMyRecord': () => ({ ok: true, viewer: HIGH_COMMAND_VIEWER, certifications: [], xp: null, tierLabel: null, myFeatures: [] }),
        'tablet:getTheme': () => ({ ok: true, theme: { primaryColor: '#2563eb', accentColor: '#f59e0b', backgroundColor: '#111827', textColor: '#f9fafb', density: 'comfortable', headerTitle: 'K9 Command Tablet' } }),
    }, overrides || {});
}

async function openTablet(h, extraOpenData) {
    h.postMessage('tablet:open', Object.assign({ runtimeControlEnabled: true }, extraOpenData || {}));
    await settle();
}

function openRuntimeControlTab(h) {
    return openSettingsSection(h.getRoot(), 'Runtime Control');
}

// ======================================================================
// GATING
// ======================================================================

t.test('a non-high-command console user never sees the Runtime Control tab', async () => {
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:requestMyRecord': () => ({ ok: true, viewer: CONSOLE_ONLY_VIEWER, certifications: [], xp: null, tierLabel: null, myFeatures: [] }),
        })),
    });
    await openTablet(h);
    t.equals(findByText(h.getRoot(), 'Runtime Control').length, 0);
});

t.test('a non-high-command officer holding a delegated k9.runtimecontrol grant DOES see the Runtime Control tab, and can open it', async () => {
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:requestMyRecord': () => ({ ok: true, viewer: DELEGATED_RUNTIME_CONTROL_VIEWER, certifications: [], xp: null, tierLabel: null, myFeatures: [] }),
            'tablet:runtimeListFeatures': () => ({ ok: true, features: [] }),
            'tablet:runtimeListTunables': () => ({ ok: true, tunables: [] }),
        })),
    });
    await openTablet(h);
    t.equals(findByText(h.getRoot(), 'Server Settings').length, 1, 'the Server Settings tab is visible to a delegated non-high-command officer');
    openSettingsSection(h.getRoot(), 'Runtime Control');
    t.equals(findByClass(h.getRoot(), 'k9tablet-settings-sections')[0].children.length, 1, 'and holds exactly the one section this delegate may change');
    await settle();
    t.isTrue(findByText(h.getRoot(), 'Runtime Feature Control').length >= 1, 'the real screen renders, not a dead end');
});

t.test('runtimeControlEnabled=false shows the disabled note (lists still fetched/shown regardless)', async () => {
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:runtimeListFeatures': () => ({ ok: true, features: [] }),
            'tablet:runtimeListTunables': () => ({ ok: true, tunables: [] }),
        })),
    });
    h.postMessage('tablet:open', { runtimeControlEnabled: false });
    await settle();
    openRuntimeControlTab(h);
    await settle();
    t.isTrue(findByText(h.getRoot(), 'Runtime feature control is disabled server-wide. Current values are shown for reference only; changes will not save until it is re-enabled.').length >= 1);
});

// ======================================================================
// FEATURES -- DYNAMIC LIST + THE HONESTY REQUIREMENT
// ======================================================================

t.test('DYNAMIC LIST: features rendered come entirely from tablet:runtimeListFeatures, sorted by name', async () => {
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:runtimeListFeatures': () => ({
                ok: true,
                features: [
                    { name: 'ZzyzxInventedFeature', currentValue: true, tier: 'live', overridden: false, protected: false },
                    { name: 'BiteAndHold', currentValue: false, tier: 'live', overridden: false, protected: false },
                ],
            }),
            'tablet:runtimeListTunables': () => ({ ok: true, tunables: [] }),
        })),
    });
    await openTablet(h);
    openRuntimeControlTab(h);
    await settle();

    t.isTrue(findByText(h.getRoot(), 'ZzyzxInventedFeature').length >= 1, 'a feature name this test invented on the fly renders correctly -- proves no hardcoded list');
    t.isTrue(findByText(h.getRoot(), 'BiteAndHold').length >= 1);

    // Sorted alphabetically -- BiteAndHold before ZzyzxInventedFeature.
    const names = findAll(h.getRoot(), (n) => n.tagName === 'td').map((n) => n.textContent).filter((tx) => tx === 'BiteAndHold' || tx === 'ZzyzxInventedFeature');
    t.equals(names[0], 'BiteAndHold');
    t.equals(names[1], 'ZzyzxInventedFeature');
});

// ======================================================================
// TIER BANDS (2026-09-01) -- owner: "better section management ...
// everything is diffrentied better", "super easy to understand".
//
// This table used to be one flat alphabetical list of every
// Config.Features key -- 57 rows on a default server -- with a full copy
// of its tier's explanation sentence repeated on every single row. The one
// question the screen exists to answer, "which of these can I actually
// change right now", could only be answered by reading all of them.
//
// It is now grouped into tier sections in SAFETY order, with the
// explanation stated once per section on a sticky band. These tests pin
// the grouping, the order, the once-not-57-times rule, and the fact that a
// tier string this client has never heard of is still shown rather than
// dropped.
// ======================================================================

/** Every tier band label on screen, in render order. */
function tierBandLabels(h) {
    return findAll(h.getRoot(), (n) => n.classList && n.classList.contains('k9tablet-feature-group-row-label'))
        .map((n) => n.textContent);
}

const MIXED_TIER_FEATURES = [
    // Deliberately NOT in tier order, and alphabetically interleaved, so
    // neither the grouping nor the within-group sort can pass by accident.
    { name: 'AaaProtectedThing', currentValue: true, tier: 'protected', overridden: false, protected: true },
    { name: 'BbbLiveThing', currentValue: true, tier: 'live', overridden: false, protected: false },
    { name: 'CccRestartThing', currentValue: false, tier: 'onstart', overridden: false, protected: false },
    { name: 'DddLiveThing', currentValue: false, tier: 'live', overridden: false, protected: false },
    { name: 'EeeFromTheFuture', currentValue: true, tier: 'a_tier_this_client_has_never_heard_of', overridden: false, protected: false },
];

function mixedTierHarness() {
    return createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:runtimeListFeatures': () => ({ ok: true, features: MIXED_TIER_FEATURES }),
            'tablet:runtimeListTunables': () => ({ ok: true, tunables: [] }),
        })),
    });
}

t.test('TIER BANDS: the features table is still banded, and the ONLY band left is Live -- the others are not listed at all now', async () => {
    const h = mixedTierHarness();
    await openTablet(h);
    openRuntimeControlTab(h);
    await settle();

    // The banding machinery is deliberately kept rather than ripped out:
    // it is what makes a future second actionable tier render correctly
    // without another rewrite, and it is what still states the Live
    // explanation exactly once. What changed is the INPUT -- only live rows
    // reach the table now (splitRuntimeFeaturesByReachability), so on any
    // real server exactly one band survives.
    const labels = tierBandLabels(h);
    t.equals(labels.length, 1, 'exactly one band, because only live rows are listed');
    t.equals(labels[0], 'Live');
    t.isTrue(labels.indexOf('Protected') === -1, 'the untouchable ones are no longer given a section of their own');
});

t.test('TIER BANDS: the surviving band is Live, whatever order the server sent its rows in', async () => {
    const h = mixedTierHarness();
    await openTablet(h);
    openRuntimeControlTab(h);
    await settle();

    // The fixture sends a protected row FIRST and a live row second. The
    // safety-ordered walk still runs; it simply has one populated bucket.
    const labels = tierBandLabels(h);
    t.equals(labels[0], 'Live', 'Live is first, whatever order the server sent');
    t.equals(labels.indexOf('Restart Required'), -1, 'restart-required is not a section any more -- it is a line under the table');
});

t.test('TIER BANDS: each tier explanation is stated ONCE, not repeated on every row of that tier', async () => {
    const h = mixedTierHarness();
    await openTablet(h);
    openRuntimeControlTab(h);
    await settle();

    // Two 'live' features in the fixture. Before this change that sentence
    // rendered twice here -- and 24+ times on a real server.
    const liveSentence = 'Takes effect immediately for every player, and can be switched back at any time.';
    t.equals(findByText(h.getRoot(), liveSentence).length, 1, 'exactly one copy of the live tier explanation, for two live rows');
});

t.test('TIER BANDS: the explanation is still on screen without a hover -- the honesty requirement is met by the band, not dropped', async () => {
    const h = mixedTierHarness();
    await openTablet(h);
    openRuntimeControlTab(h);
    await settle();

    // The rule for this screen (see buildRuntimeFeatureRow) is that the
    // tier explanation must be readable BEFORE a toggle is pressed and
    // never hidden behind a hover or a title attribute. Moving it to the
    // band must not have quietly turned it into a tooltip.
    const desc = findAll(h.getRoot(), (n) => n.classList && n.classList.contains('k9tablet-runtime-tier-band-desc'))[0];
    t.isDefined(desc, 'the explanation is a real, rendered element');
    t.isTrue(desc.textContent.length > 0, 'with real text in it');
    t.isNull(desc.getAttribute('title'), 'and it is not a tooltip');
});

t.test('TIER BANDS: a tier string this client has never heard of is still named on screen, never silently dropped', async () => {
    const h = mixedTierHarness();
    await openTablet(h);
    openRuntimeControlTab(h);
    await settle();

    // THE RISK THIS GUARDS, unchanged in substance from before the filter:
    // an unrecognised tier must never make a feature disappear without
    // trace. It is no longer offered as a toggle (this client cannot know
    // that an unknown tier is safe to flip), but it MUST still be named --
    // now in the config-file-only note rather than in a table band.
    const note = configOnlyNote(h);
    t.isTrue(note !== null, 'the note exists');
    t.isTrue(note.indexOf('EeeFromTheFuture') !== -1, 'and names the unknown-tier feature');
});

t.test('TIER BANDS: every LIVE feature reaches the table exactly once -- banding still groups, it never duplicates', async () => {
    const h = mixedTierHarness();
    await openTablet(h);
    openRuntimeControlTab(h);
    await settle();

    for (const f of MIXED_TIER_FEATURES) {
        if (f.tier !== 'live') continue;
        t.equals(findByText(h.getRoot(), f.name).length, 1, f.name + ' appears exactly once');
    }

    // And nothing non-live leaked into the table as a row. Checked against
    // the table specifically, not the whole screen: these names DO appear
    // once more on screen, inside the config-file-only note, which is the
    // point.
    const cellText = findAll(h.getRoot(), (n) => n.tagName === 'td').map((n) => n.textContent);
    for (const f of MIXED_TIER_FEATURES) {
        if (f.tier === 'live') continue;
        t.isTrue(cellText.indexOf(f.name) === -1, f.name + ' must not be a table row');
    }
});

t.test('TIER BANDS: rows stay alphabetical WITHIN a band -- grouping is a display change, not a re-sort', async () => {
    const h = mixedTierHarness();
    await openTablet(h);
    openRuntimeControlTab(h);
    await settle();

    const names = findAll(h.getRoot(), (n) => n.tagName === 'td')
        .map((n) => n.textContent)
        .filter((tx) => tx === 'BbbLiveThing' || tx === 'DddLiveThing');
    t.equals(names[0], 'BbbLiveThing');
    t.equals(names[1], 'DddLiveThing');
});

t.test('empty features/tunables lists show their own empty-state notes, not a crash', async () => {
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:runtimeListFeatures': () => ({ ok: true, features: [] }),
            'tablet:runtimeListTunables': () => ({ ok: true, tunables: [] }),
        })),
    });
    await openTablet(h);
    openRuntimeControlTab(h);
    await settle();
    t.isTrue(findByText(h.getRoot(), 'No features to show.').length >= 1);
    t.isTrue(findByText(h.getRoot(), 'No tunables to show.').length >= 1);
});

t.test('a load failure shows the error and a Retry button that re-fetches', async () => {
    let calls = 0;
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:runtimeListFeatures': () => {
                calls++;
                return calls === 1 ? { ok: false, error: 'denied' } : { ok: true, features: [] };
            },
            'tablet:runtimeListTunables': () => ({ ok: true, tunables: [] }),
        })),
    });
    await openTablet(h);
    openRuntimeControlTab(h);
    await settle();

    t.isTrue(findByText(h.getRoot(), 'You are not authorized to manage runtime feature control.').length >= 1);
    findByText(h.getRoot(), 'Retry')[0].click();
    await settle();
    t.isTrue(findByText(h.getRoot(), 'No features to show.').length >= 1);
    t.equals(calls, 2);
});

// ---- THE HONESTY REQUIREMENT: every tier renders its own plain-language explanation, BEFORE any click ----

t.test('a "live" feature shows the Live badge + its own honest description, and a toggle button', async () => {
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:runtimeListFeatures': () => ({ ok: true, features: [{ name: 'BiteAndHold', currentValue: true, tier: 'live', overridden: false, protected: false }] }),
            'tablet:runtimeListTunables': () => ({ ok: true, tunables: [] }),
        })),
    });
    await openTablet(h);
    openRuntimeControlTab(h);
    await settle();

    t.isTrue(findByText(h.getRoot(), 'Live').length >= 1);
    t.isTrue(findByText(h.getRoot(), 'Takes effect immediately for every player, and can be switched back at any time.').length >= 1);
    t.isTrue(findByText(h.getRoot(), 'On').length >= 1);
    t.isTrue(findByText(h.getRoot(), 'Disable').length >= 1, 'currently on -- offers Disable');
});

// ======================================================================
// CONFIG-FILE-ONLY FEATURES ARE NOT LISTED AS TOGGLES
//
// Owner directive, verbatim: "ensure anything disabled in the config or
// requires a restart wont show up in the tablet".
//
// WHAT THESE TESTS USED TO PIN, AND WHY IT CHANGED. There was one test per
// non-live tier here, each asserting the row rendered with an honest badge
// and an honest explanation ("Restart Required", "Config Edit + Restart
// Required", "Client-Side Only", "Protected", "Not Yet Classified"). That
// was a defensible design -- the labels really were honest -- but it meant
// roughly two thirds of the rows on a real server were controls that
// cannot control anything from this screen, burying the third that can.
// A toggle that silently needs a restart reads as broken, not documented.
//
// The rows are now filtered out of the table entirely
// (splitRuntimeFeaturesByReachability() in html/tablet.js) and reported
// instead as ONE line naming every one of them. So the pair of properties
// each test below asserts is deliberate and must stay a pair: the feature
// is NOT offered as a control, AND it is still named on screen. Dropping
// the second half would turn this from "moved to config.lua" into
// "silently vanished", which is the failure this whole screen exists to
// avoid.
// ======================================================================

/** The one line that names every feature this screen deliberately does not offer. */
function configOnlyNote(h) {
    const hits = findAll(h.getRoot(), (n) => typeof n.textContent === 'string'
        && n.textContent.indexOf('cannot be changed from the tablet') !== -1
        && (!n.children || n.children.length === 0));
    return hits.length > 0 ? hits[0].textContent : null;
}

function singleFeatureHarness(feature) {
    return createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:runtimeListFeatures': () => ({ ok: true, features: [feature] }),
            'tablet:runtimeListTunables': () => ({ ok: true, tunables: [] }),
        })),
    });
}

const NON_LIVE_TIER_CASES = [
    { tier: 'onstart', name: 'AdminAuditCommands', why: 'saved, but nothing changes until a restart' },
    { tier: 'rawtoplevel', name: 'FetchMechanic', why: 'needs a config.lua edit, not just a restart' },
    { tier: 'clientonly', name: 'RadialMenu', why: 'nothing server-side to flip for a connected client' },
    { tier: 'protected', name: 'HighCommand', why: 'refused outright -- toggling it is a self-lockout' },
    { tier: 'unaudited', name: 'BrandNewFeature', why: 'no confirmed enforcement point' },
];

for (const testCase of NON_LIVE_TIER_CASES) {
    t.test('a "' + testCase.tier + '" feature is NOT offered as a toggle (' + testCase.why + ') but IS named in the config-file-only note', async () => {
        const h = singleFeatureHarness({
            name: testCase.name, currentValue: true, tier: testCase.tier,
            overridden: false, protected: testCase.tier === 'protected',
        });
        await openTablet(h);
        openRuntimeControlTab(h);
        await settle();

        // NO CONTROL. Neither an Enable nor a Disable button exists for it,
        // and the empty-state note stands in for the table, because this
        // server sent exactly one feature and it is not actionable here.
        t.equals(findByText(h.getRoot(), 'Enable').length, 0, 'no Enable button');
        t.equals(findByText(h.getRoot(), 'Disable').length, 0, 'no Disable button');

        // STILL NAMED. This is the half that stops "hidden" from becoming
        // "disappeared" -- an operator looking for this exact switch is told
        // where it lives instead of concluding the tablet is broken.
        const note = configOnlyNote(h);
        t.isTrue(note !== null, 'the config-file-only note is on screen');
        t.isTrue(note.indexOf(testCase.name) !== -1, note + ' must name ' + testCase.name);
        t.isTrue(note.indexOf('config.lua') !== -1, 'and must say where to change it');
    });
}

t.test('CONFIG-FILE-ONLY: with every tier present, the note names every non-live feature and no live one', async () => {
    const h = mixedTierHarness();
    await openTablet(h);
    openRuntimeControlTab(h);
    await settle();

    const note = configOnlyNote(h);
    t.isTrue(note !== null, 'the config-file-only note is on screen');
    for (const f of MIXED_TIER_FEATURES) {
        if (f.tier === 'live') {
            t.isTrue(note.indexOf(f.name) === -1, f.name + ' is live and must NOT be in the note');
        } else {
            t.isTrue(note.indexOf(f.name) !== -1, f.name + ' is not live and must be named in the note');
        }
    }
});

t.test('CONFIG-FILE-ONLY: a server with nothing but live features shows no note at all -- it is a redirection, not decoration', async () => {
    const h = singleFeatureHarness({ name: 'BiteAndHold', currentValue: true, tier: 'live', overridden: false, protected: false });
    await openTablet(h);
    openRuntimeControlTab(h);
    await settle();

    t.isTrue(configOnlyNote(h) === null, 'nothing was hidden, so there is nothing to explain');
});

t.test('a per-feature server-authored `note` (e.g. ScentTracking\'s drop-hook caveat) is shown as supplementary text, alongside the tier explanation', async () => {
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:runtimeListFeatures': () => ({
                ok: true,
                features: [{ name: 'ScentTracking', currentValue: true, tier: 'live', note: 'A very specific caveat about the drop hook.', overridden: false, protected: false }],
            }),
            'tablet:runtimeListTunables': () => ({ ok: true, tunables: [] }),
        })),
    });
    await openTablet(h);
    openRuntimeControlTab(h);
    await settle();

    t.isTrue(findByText(h.getRoot(), 'Takes effect immediately for every player, and can be switched back at any time.').length >= 1, 'primary, locale-driven tier explanation still shown');
    t.isTrue(findByText(h.getRoot(), 'A very specific caveat about the drop hook.').length >= 1, 'server-authored per-feature note shown as supplementary text');
});

// ======================================================================
// FEATURE TOGGLE / RESET
// ======================================================================

t.test('Enable/Disable requires two clicks (confirm), sends {name, value}', async () => {
    let setBody = null;
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:runtimeListFeatures': () => ({ ok: true, features: [{ name: 'BiteAndHold', currentValue: false, tier: 'live', overridden: false, protected: false }] }),
            'tablet:runtimeListTunables': () => ({ ok: true, tunables: [] }),
            'tablet:runtimeSetFeature': (body) => { setBody = body; return { ok: true, appliedLive: true, restartRequired: false, tier: 'live' }; },
        })),
    });
    await openTablet(h);
    openRuntimeControlTab(h);
    await settle();

    const enableBtn = findByText(h.getRoot(), 'Enable')[0];
    enableBtn.click(); // arm confirm
    t.isNull(setBody, 'the first click only arms the confirm -- no request sent yet');
    enableBtn.click(); // confirm
    await new Promise((r) => setTimeout(r, 30));

    t.equals(setBody.name, 'BiteAndHold');
    t.equals(setBody.value, true);
});

t.test('a rejected toggle (protected_feature/unaudited_feature refusal) renders inline on that row using the SAME tier explanation, not a generic failure', async () => {
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:runtimeListFeatures': () => ({ ok: true, features: [{ name: 'SomeFeature', currentValue: false, tier: 'live', overridden: false, protected: false }] }),
            'tablet:runtimeListTunables': () => ({ ok: true, tunables: [] }),
            'tablet:runtimeSetFeature': () => ({ ok: false, error: 'unaudited_feature' }),
        })),
    });
    await openTablet(h);
    openRuntimeControlTab(h);
    await settle();

    const enableBtn = findByText(h.getRoot(), 'Enable')[0];
    enableBtn.click();
    enableBtn.click();
    await new Promise((r) => setTimeout(r, 30));

    t.isTrue(findByText(h.getRoot(), 'This feature has not yet been classified for runtime control, and is refused for safety. Ask a developer to audit it before it can be toggled here.').length >= 1);
});

t.test('Reset to default only appears when overridden, requires two clicks, sends {name}', async () => {
    let resetBody = null;
    let listCalls = 0;
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:runtimeListFeatures': () => {
                listCalls++;
                return { ok: true, features: [{ name: 'BiteAndHold', currentValue: false, tier: 'live', overridden: true, overriddenBy: 'CIT1', overriddenAt: '2026-01-01 00:00:00', protected: false }] };
            },
            'tablet:runtimeListTunables': () => ({ ok: true, tunables: [] }),
            'tablet:runtimeResetFeature': (body) => { resetBody = body; return { ok: true, value: true, restartRequired: false }; },
        })),
    });
    await openTablet(h);
    openRuntimeControlTab(h);
    await settle();

    t.isTrue(findByText(h.getRoot(), 'Overridden by CIT1 at 2026-01-01 00:00:00').length >= 1);

    const resetBtn = findByText(h.getRoot(), 'Reset to default')[0];
    resetBtn.click();
    t.isNull(resetBody);
    resetBtn.click();
    await new Promise((r) => setTimeout(r, 30));

    t.equals(resetBody.name, 'BiteAndHold');
    t.isTrue(listCalls >= 2, 'a successful reset re-pulls the authoritative list rather than optimistically mutating locally');
});

t.test('a non-overridden feature shows no Reset button at all', async () => {
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:runtimeListFeatures': () => ({ ok: true, features: [{ name: 'BiteAndHold', currentValue: true, tier: 'live', overridden: false, protected: false }] }),
            'tablet:runtimeListTunables': () => ({ ok: true, tunables: [] }),
        })),
    });
    await openTablet(h);
    openRuntimeControlTab(h);
    await settle();
    t.equals(findByText(h.getRoot(), 'Reset to default').length, 0);
});

// ======================================================================
// TUNABLES -- EDIT / SAVE / RESET, SERVER IS THE ONLY AUTHORITATIVE RANGE CHECK
// ======================================================================

t.test('DYNAMIC LIST: tunables rendered come entirely from tablet:runtimeListTunables, with range and type shown', async () => {
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:runtimeListFeatures': () => ({ ok: true, features: [] }),
            'tablet:runtimeListTunables': () => ({
                ok: true,
                tunables: [{ key: 'LeashMaxDistance', currentValue: 8.5, min: 3.0, max: 20.0, integer: false, overridden: false }],
            }),
        })),
    });
    await openTablet(h);
    openRuntimeControlTab(h);
    await settle();

    t.isTrue(findByText(h.getRoot(), 'LeashMaxDistance').length >= 1);
    t.isTrue(findByText(h.getRoot(), '8.5').length >= 1);
    t.isTrue(findByText(h.getRoot(), '3 – 20').length >= 1);
    t.isTrue(findByText(h.getRoot(), 'Decimal').length >= 1);
});

t.test('an integer tunable shows "Whole number"', async () => {
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:runtimeListFeatures': () => ({ ok: true, features: [] }),
            'tablet:runtimeListTunables': () => ({
                ok: true,
                tunables: [{ key: 'Tracking.Scent.maxAgeSeconds', currentValue: 300, min: 30, max: 3600, integer: true, overridden: false }],
            }),
        })),
    });
    await openTablet(h);
    openRuntimeControlTab(h);
    await settle();
    t.isTrue(findByText(h.getRoot(), 'Whole number').length >= 1);
});

// ======================================================================
// PLAIN-ENGLISH TUNABLE DESCRIPTIONS -- the fix for the exact confusion
// this resource's own commit history predicted and shipped anyway: this
// row used to show ONLY the raw Config path (tunable.key) with nothing
// explaining what the setting actually does. server/runtimecontrol.lua's
// GetTunableDescription now supplies an OPTIONAL `description` field per
// row; buildRuntimeTunableRow must show it as the row's PRIMARY text,
// the raw key only as secondary detail -- and must never break, hide, or
// otherwise change a row that has no description yet (most rows, in a
// fixture that never sets `description` at all, exactly like every OTHER
// test in this file).
// ======================================================================

t.test('a tunable WITH a server-supplied description shows the description as the primary text and the raw key as secondary detail, not instead of it', async () => {
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:runtimeListFeatures': () => ({ ok: true, features: [] }),
            'tablet:runtimeListTunables': () => ({
                ok: true,
                tunables: [{
                    key: 'Wellbeing.Fatigue.sprintDecayPerTick',
                    currentValue: 2.0, min: 0, max: 20.0, integer: false, overridden: false,
                    description: "How fast a K9's own Fatigue meter (this resource's custom tiredness stat -- NOT the game's Stamina bar) drains while sprinting.",
                }],
            }),
        })),
    });
    await openTablet(h);
    openRuntimeControlTab(h);
    await settle();

    t.isTrue(findByText(h.getRoot(), "How fast a K9's own Fatigue meter (this resource's custom tiredness stat -- NOT the game's Stamina bar) drains while sprinting.").length >= 1, 'the plain-English description is rendered');
    t.isTrue(findByText(h.getRoot(), 'Wellbeing.Fatigue.sprintDecayPerTick').length >= 1, 'the raw key is STILL shown, as secondary detail, never removed entirely');
});

t.test('two similarly-named tunables with different descriptions are told apart at a glance (the exact confusion this fix exists for)', async () => {
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:runtimeListFeatures': () => ({ ok: true, features: [] }),
            'tablet:runtimeListTunables': () => ({
                ok: true,
                tunables: [
                    {
                        key: 'Wellbeing.Fatigue.sprintDecayPerTick',
                        currentValue: 2.0, min: 0, max: 20.0, integer: false, overridden: false,
                        description: "How fast a K9's own Fatigue meter drains while sprinting -- this resource's custom tiredness stat, not the game's Stamina bar.",
                    },
                    {
                        key: 'Wellbeing.Fatigue.nativeStaminaRestorePercent',
                        currentValue: 0.0, min: 0.0, max: 1.0, integer: false, overridden: false,
                        description: "How much of the game engine's own built-in Stamina bar (the HUD meter, a different stat from Fatigue above) is topped up every second.",
                    },
                ],
            }),
        })),
    });
    await openTablet(h);
    openRuntimeControlTab(h);
    await settle();

    const root = h.getRoot();
    t.isTrue(findByText(root, "How fast a K9's own Fatigue meter drains while sprinting -- this resource's custom tiredness stat, not the game's Stamina bar.").length >= 1);
    t.isTrue(findByText(root, "How much of the game engine's own built-in Stamina bar (the HUD meter, a different stat from Fatigue above) is topped up every second.").length >= 1);
    t.isTrue(findByText(root, 'Wellbeing.Fatigue.sprintDecayPerTick').length >= 1);
    t.isTrue(findByText(root, 'Wellbeing.Fatigue.nativeStaminaRestorePercent').length >= 1);
});

t.test('DO NOT LET A MISSING DESCRIPTION BREAK THE ROW: a tunable with no `description` field at all still renders, still shows its key, and is still editable', async () => {
    let setBody = null;
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:runtimeListFeatures': () => ({ ok: true, features: [] }),
            'tablet:runtimeListTunables': () => ({
                ok: true,
                tunables: [{ key: 'LeashMaxDistance', currentValue: 8.5, min: 3.0, max: 20.0, integer: false, overridden: false }],
            }),
            'tablet:runtimeSetTunable': (body) => { setBody = body; return { ok: true, appliedLive: true, restartRequired: false, value: 12 }; },
        })),
    });
    await openTablet(h);
    openRuntimeControlTab(h);
    await settle();

    t.isTrue(findByText(h.getRoot(), 'LeashMaxDistance').length >= 1, 'the raw key alone is shown -- the exact pre-fix behaviour -- never a blank or broken cell');

    // Still fully editable, exactly like every tunable before this
    // description mechanism existed -- a missing description is cosmetic
    // only, never a functional regression.
    findByText(h.getRoot(), 'Edit')[0].click();
    await settle();
    const input = findInput(h.getRoot(), (n) => n.getAttribute('type') === 'number');
    t.isDefined(input);
    input.typeValue('12');
    findByText(h.getRoot(), 'Save Value')[0].click();
    await new Promise((r) => setTimeout(r, 30));
    t.equals(setBody.key, 'LeashMaxDistance');
    t.equals(setBody.value, 12);
});

t.test('an empty-string `description` (server sent "" rather than omitting the field) is treated the same as no description -- never rendered as a blank line', async () => {
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:runtimeListFeatures': () => ({ ok: true, features: [] }),
            'tablet:runtimeListTunables': () => ({
                ok: true,
                tunables: [{ key: 'LeashMaxDistance', currentValue: 8.5, min: 3.0, max: 20.0, integer: false, overridden: false, description: '' }],
            }),
        })),
    });
    await openTablet(h);
    openRuntimeControlTab(h);
    await settle();
    t.isTrue(findByText(h.getRoot(), 'LeashMaxDistance').length >= 1);
});

t.test('the Settings table header reads "Setting", not the raw "Key" label, now that this column shows a plain-English description first', async () => {
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:runtimeListFeatures': () => ({ ok: true, features: [] }),
            'tablet:runtimeListTunables': () => ({
                ok: true,
                tunables: [{ key: 'LeashMaxDistance', currentValue: 8.5, min: 3.0, max: 20.0, integer: false, overridden: false }],
            }),
        })),
    });
    await openTablet(h);
    openRuntimeControlTab(h);
    await settle();
    t.isTrue(findByText(h.getRoot(), 'Setting').length >= 1);
});

function findInput(root, predicate) {
    return findAll(root, (n) => n.tagName === 'input' && predicate(n))[0];
}

t.test('Edit opens an inline number editor pre-filled with the current value; Save sends {key, value}', async () => {
    let setBody = null;
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:runtimeListFeatures': () => ({ ok: true, features: [] }),
            'tablet:runtimeListTunables': () => ({
                ok: true,
                tunables: [{ key: 'LeashMaxDistance', currentValue: 8.5, min: 3.0, max: 20.0, integer: false, overridden: false }],
            }),
            'tablet:runtimeSetTunable': (body) => { setBody = body; return { ok: true, appliedLive: true, restartRequired: false, value: 12 }; },
        })),
    });
    await openTablet(h);
    openRuntimeControlTab(h);
    await settle();

    findByText(h.getRoot(), 'Edit')[0].click();
    await settle();

    const input = findInput(h.getRoot(), (n) => n.getAttribute('type') === 'number');
    t.isDefined(input);
    t.equals(input.value, '8.5', 'pre-filled from the current value');
    input.typeValue('12');

    findByText(h.getRoot(), 'Save Value')[0].click();
    await new Promise((r) => setTimeout(r, 30));

    t.equals(setBody.key, 'LeashMaxDistance');
    t.equals(setBody.value, 12);
});

t.test('Save with a non-numeric value shows a client-side "enter a valid number" note WITHOUT any server round trip', async () => {
    let setCalled = false;
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:runtimeListFeatures': () => ({ ok: true, features: [] }),
            'tablet:runtimeListTunables': () => ({
                ok: true,
                tunables: [{ key: 'LeashMaxDistance', currentValue: 8.5, min: 3.0, max: 20.0, integer: false, overridden: false }],
            }),
            'tablet:runtimeSetTunable': () => { setCalled = true; return { ok: true, value: 1 }; },
        })),
    });
    await openTablet(h);
    openRuntimeControlTab(h);
    await settle();

    findByText(h.getRoot(), 'Edit')[0].click();
    await settle();
    const input = findInput(h.getRoot(), (n) => n.getAttribute('type') === 'number');
    input.typeValue('not-a-number');
    findByText(h.getRoot(), 'Save Value')[0].click();
    await new Promise((r) => setTimeout(r, 30));

    t.isFalse(setCalled, 'a non-numeric value never reaches the server at all');
    t.isTrue(findByText(h.getRoot(), 'Enter a valid number.').length >= 1);
});

t.test('an out-of-range value IS sent to the server unclamped, and the server\'s REAL min/max is echoed back on refusal', async () => {
    let setBody = null;
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:runtimeListFeatures': () => ({ ok: true, features: [] }),
            'tablet:runtimeListTunables': () => ({
                ok: true,
                tunables: [{ key: 'LeashMaxDistance', currentValue: 8.5, min: 3.0, max: 20.0, integer: false, overridden: false }],
            }),
            'tablet:runtimeSetTunable': (body) => { setBody = body; return { ok: false, error: 'out_of_range', min: 3.0, max: 20.0 }; },
        })),
    });
    await openTablet(h);
    openRuntimeControlTab(h);
    await settle();

    findByText(h.getRoot(), 'Edit')[0].click();
    await settle();
    const input = findInput(h.getRoot(), (n) => n.getAttribute('type') === 'number');
    input.typeValue('999999');
    findByText(h.getRoot(), 'Save Value')[0].click();
    await new Promise((r) => setTimeout(r, 30));

    t.equals(setBody.value, 999999, 'this page never clamps a tunable value before sending it -- the server is the only authoritative gate');
    t.isTrue(findByText(h.getRoot(), 'That value must be between 3 and 20.').length >= 1, 'the server\'s own real bounds are shown, not a client-guessed range');
});

t.test('Cancel discards the edit without saving', async () => {
    let setCalled = false;
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:runtimeListFeatures': () => ({ ok: true, features: [] }),
            'tablet:runtimeListTunables': () => ({
                ok: true,
                tunables: [{ key: 'LeashMaxDistance', currentValue: 8.5, min: 3.0, max: 20.0, integer: false, overridden: false }],
            }),
            'tablet:runtimeSetTunable': () => { setCalled = true; return { ok: true, value: 1 }; },
        })),
    });
    await openTablet(h);
    openRuntimeControlTab(h);
    await settle();

    findByText(h.getRoot(), 'Edit')[0].click();
    await settle();
    findInput(h.getRoot(), (n) => n.getAttribute('type') === 'number').typeValue('15');
    findByText(h.getRoot(), 'Cancel')[0].click();
    await settle();

    t.isFalse(setCalled);
    t.isTrue(findByText(h.getRoot(), '8.5').length >= 1, 'the original value is shown again, unchanged');
});

t.test('Reset (tunable) only appears when overridden, requires two clicks, sends {key}', async () => {
    let resetBody = null;
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:runtimeListFeatures': () => ({ ok: true, features: [] }),
            'tablet:runtimeListTunables': () => ({
                ok: true,
                tunables: [{ key: 'LeashMaxDistance', currentValue: 12, min: 3.0, max: 20.0, integer: false, overridden: true, overriddenBy: 'CIT9', overriddenAt: '2026-02-02 00:00:00' }],
            }),
            'tablet:runtimeResetTunable': (body) => { resetBody = body; return { ok: true, value: 8, restartRequired: false }; },
        })),
    });
    await openTablet(h);
    openRuntimeControlTab(h);
    await settle();

    t.isTrue(findByText(h.getRoot(), 'Overridden by CIT9 at 2026-02-02 00:00:00').length >= 1);

    const resetBtn = findByText(h.getRoot(), 'Reset to default')[0];
    resetBtn.click();
    resetBtn.click();
    await new Promise((r) => setTimeout(r, 30));

    t.equals(resetBody.key, 'LeashMaxDistance');
});

// ======================================================================
// STALE-RESPONSE GUARD -- same class of race as tests/tablet_stale_response_spec.js
// and tablet_shop_locations_spec.js's own equivalent, applied here via a
// request-generation counter (this list has no per-request identity like a
// citizenid/query to compare against arrival order).
// ======================================================================

t.test('a late tablet:runtimeListFeatures response for an OLDER request never overwrites what a NEWER request already resolved', async () => {
    let resolveStale = null;
    let callNumber = 0;
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:runtimeListTunables': () => ({ ok: true, tunables: [] }),
            'tablet:runtimeListFeatures': () => {
                callNumber++;
                if (callNumber === 1) {
                    return new Promise((resolve) => {
                        resolveStale = () => resolve({ ok: true, features: [{ name: 'STALE_FIRST_RESULT', currentValue: true, tier: 'live', overridden: false, protected: false }] });
                    });
                }
                return { ok: true, features: [{ name: 'FRESH_SECOND_RESULT', currentValue: true, tier: 'live', overridden: false, protected: false }] };
            },
        })),
    });
    await openTablet(h);

    openRuntimeControlTab(h);
    await settle();
    t.isDefined(resolveStale, 'the first request was sent and is being held unresolved');

    findByText(h.getRoot(), 'My Record')[0].click();
    await settle();
    openRuntimeControlTab(h);
    await settle();

    t.isTrue(findByText(h.getRoot(), 'FRESH_SECOND_RESULT').length >= 1, 'the second (current) request\'s result is showing');
    t.equals(findByText(h.getRoot(), 'STALE_FIRST_RESULT').length, 0, 'the first request has not (yet) resolved at all');

    resolveStale();
    await settle();

    t.isTrue(findByText(h.getRoot(), 'FRESH_SECOND_RESULT').length >= 1, 'the fresh result is still showing after the late first response arrives');
    t.equals(findByText(h.getRoot(), 'STALE_FIRST_RESULT').length, 0, 'the late, OLDER response never replaces the current, NEWER one');
});

// ======================================================================
// LOCKOUT-RISK FEATURES (HighCommand/PermissionGrants/RuntimeFeatureControl/
// TabletTheming/CommandTablet) -- server/runtimecontrol.lua's own
// runtimeListFeatures already returns `lockoutRisk`/`sessionOnly`/
// `lockoutWarning` per row, and runtimeSetFeature/runtimeResetFeature
// already refuse a `lockoutRisk` feature without a `confirm` argument
// matching that feature's own `name` exactly (reason='confirmation_required'
// otherwise) -- this section covers the UI half that lets an operator
// actually satisfy that requirement: THE ROW MUST LOOK DIFFERENT BEFORE ANY
// CLICK, a real read-and-type confirmation (never the ordinary two-click
// mkConfirmButton pattern used for ordinary destructive actions elsewhere
// on this page) showing the server's OWN warning text verbatim, and a
// clear distinction for `sessionOnly` ("a restart puts this back").
// ======================================================================

const LOCKOUT_WARNING_TEXT = 'Disabling this immediately revokes access for EVERY high-command officer, including you. Nobody can use this screen to turn it back on once it is off. RECOVERY: restart this resource.';

t.test('a lockoutRisk + sessionOnly feature (e.g. HighCommand) shows the Lockout Risk AND Session-Only badges, and their own plain-language hints, BEFORE any click', async () => {
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:runtimeListFeatures': () => ({
                ok: true,
                features: [{ name: 'HighCommand', currentValue: true, tier: 'live', overridden: false, protected: false, lockoutRisk: true, sessionOnly: true, lockoutWarning: LOCKOUT_WARNING_TEXT }],
            }),
            'tablet:runtimeListTunables': () => ({ ok: true, tunables: [] }),
        })),
    });
    await openTablet(h);
    openRuntimeControlTab(h);
    await settle();

    t.isTrue(findByText(h.getRoot(), 'Lockout Risk').length >= 1, 'the Lockout Risk badge is visible before any click');
    t.isTrue(findByText(h.getRoot(), 'Session-Only').length >= 1, 'the Session-Only badge is visible before any click');
    t.isTrue(findByText(h.getRoot(), 'Disabling this can immediately lock every administrator, including you, out of this tablet. Changing it requires reading a full warning and typing the feature name to confirm.').length >= 1);
    t.isTrue(findByText(h.getRoot(), 'Not saved to the database -- a restart alone reverts this, even without a config.lua edit.').length >= 1, 'the reassuring session-only explanation is shown, not just the risk warning');
    // The server's own full warning text is NOT shown yet -- only after
    // the operator actually clicks to open the confirmation panel.
    t.equals(findByText(h.getRoot(), LOCKOUT_WARNING_TEXT).length, 0, 'the full server warning is not rendered until the confirmation panel is opened');
});

t.test('a lockoutRisk feature that is NOT sessionOnly (e.g. CommandTablet) shows the Lockout Risk badge but NEVER the Session-Only badge', async () => {
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:runtimeListFeatures': () => ({
                ok: true,
                // tier 'live', deliberately -- this test is about the BADGE
                // pair, not about tiers, and a non-live tier is no longer
                // listed as a row at all (see the CONFIG-FILE-ONLY block
                // above), so a rawtoplevel fixture here would test nothing.
                features: [{ name: 'CommandTablet', currentValue: true, tier: 'live', overridden: false, protected: false, lockoutRisk: true, sessionOnly: false, lockoutWarning: 'Disabling this removes the tablet entirely for every player, immediately.' }],
            }),
            'tablet:runtimeListTunables': () => ({ ok: true, tunables: [] }),
        })),
    });
    await openTablet(h);
    openRuntimeControlTab(h);
    await settle();

    t.isTrue(findByText(h.getRoot(), 'Lockout Risk').length >= 1);
    t.equals(findByText(h.getRoot(), 'Session-Only').length, 0, 'a persisted lockout-risk feature never claims to be session-only');
});

t.test('a non-lockoutRisk feature never shows either badge', async () => {
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:runtimeListFeatures': () => ({ ok: true, features: [{ name: 'BiteAndHold', currentValue: true, tier: 'live', overridden: false, protected: false }] }),
            'tablet:runtimeListTunables': () => ({ ok: true, tunables: [] }),
        })),
    });
    await openTablet(h);
    openRuntimeControlTab(h);
    await settle();

    t.equals(findByText(h.getRoot(), 'Lockout Risk').length, 0);
    t.equals(findByText(h.getRoot(), 'Session-Only').length, 0);
});

// ---- THE SAFETY PROPERTY: a click alone must never mutate; only a MATCHING typed confirmation may ----

t.test('SAFETY: clicking a lockoutRisk toggle opens the confirmation panel and sends NOTHING -- the server\'s own warning is shown verbatim; a non-matching typed value keeps Confirm disabled and still sends nothing; only the EXACT feature name enables Confirm, which then sends {name, value, confirm: name}', async () => {
    let setCalls = [];
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:runtimeListFeatures': () => ({
                ok: true,
                features: [{ name: 'HighCommand', currentValue: true, tier: 'live', overridden: false, protected: false, lockoutRisk: true, sessionOnly: true, lockoutWarning: LOCKOUT_WARNING_TEXT }],
            }),
            'tablet:runtimeListTunables': () => ({ ok: true, tunables: [] }),
            'tablet:runtimeSetFeature': (body) => { setCalls.push(body); return { ok: true, appliedLive: true, restartRequired: false, tier: 'live', sessionOnly: true }; },
        })),
    });
    await openTablet(h);
    openRuntimeControlTab(h);
    await settle();

    // A single click on the toggle for a lockoutRisk feature must ONLY
    // open the confirmation panel -- never the two-click arm/confirm
    // sequence, and never a request.
    const disableBtn = findByText(h.getRoot(), 'Disable')[0];
    disableBtn.click();
    await settle();
    t.equals(setCalls.length, 0, 'opening the confirmation panel alone never sends a request');
    t.isTrue(findByText(h.getRoot(), 'Confirm This Change').length >= 1, 'the read-and-type confirmation panel is now open');
    t.isTrue(findByText(h.getRoot(), LOCKOUT_WARNING_TEXT).length >= 1, 'the server\'s own lockoutWarning text is shown verbatim -- never this page\'s own wording');

    const confirmInput = findAll(h.getRoot(), (n) => n.tagName === 'input' && n.classList.contains('k9tablet-runtime-lockout-confirm-input'))[0];
    t.isDefined(confirmInput, 'the type-to-confirm input is present');

    // Wrong value -- Confirm must stay disabled, and clicking it (a
    // disabled button never fires its handler, see mkButton()) must send
    // nothing.
    confirmInput.typeValue('HighCommnad'); // typo, deliberately close but wrong
    await settle();
    const confirmBtnWrong = findByText(h.getRoot(), 'Confirm and Apply')[0];
    t.equals(confirmBtnWrong.getAttribute('disabled'), 'disabled', 'Confirm stays disabled until the typed value matches exactly');
    confirmBtnWrong.click();
    await settle();
    t.equals(setCalls.length, 0, 'a non-matching typed value never sends a request, even if Confirm is clicked directly');

    // Exact value -- Confirm enables, and the resulting call carries
    // `confirm` set to the feature's own name, exactly.
    confirmInput.typeValue('HighCommand');
    await settle();
    const confirmBtnRight = findByText(h.getRoot(), 'Confirm and Apply')[0];
    t.isTrue(confirmBtnRight.getAttribute('disabled') !== 'disabled', 'Confirm enables once the typed value matches exactly');
    confirmBtnRight.click();
    await new Promise((r) => setTimeout(r, 30));

    t.equals(setCalls.length, 1, 'exactly one request was sent, only after a matching confirmation');
    t.equals(setCalls[0].name, 'HighCommand');
    t.equals(setCalls[0].value, false, 'currently on -- Disable requests newValue=false');
    t.equals(setCalls[0].confirm, 'HighCommand', 'confirm carries the exact feature name');
});

t.test('SAFETY: Cancel on the confirmation panel closes it and sends nothing', async () => {
    let setCalled = false;
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:runtimeListFeatures': () => ({
                ok: true,
                features: [{ name: 'HighCommand', currentValue: true, tier: 'live', overridden: false, protected: false, lockoutRisk: true, sessionOnly: true, lockoutWarning: LOCKOUT_WARNING_TEXT }],
            }),
            'tablet:runtimeListTunables': () => ({ ok: true, tunables: [] }),
            'tablet:runtimeSetFeature': () => { setCalled = true; return { ok: true }; },
        })),
    });
    await openTablet(h);
    openRuntimeControlTab(h);
    await settle();

    findByText(h.getRoot(), 'Disable')[0].click();
    await settle();
    const confirmInput = findAll(h.getRoot(), (n) => n.tagName === 'input' && n.classList.contains('k9tablet-runtime-lockout-confirm-input'))[0];
    confirmInput.typeValue('HighCommand');
    await settle();

    findByText(h.getRoot(), 'Cancel')[0].click();
    await settle();

    t.isFalse(setCalled, 'Cancel never sends a request');
    t.equals(findByText(h.getRoot(), 'Confirm This Change').length, 0, 'the confirmation panel is closed');
    t.isTrue(findByText(h.getRoot(), 'Disable').length >= 1, 'the ordinary toggle button is back');
});

t.test('SAFETY: Reset (config.lua default) on a lockoutRisk feature goes through the SAME read-and-type panel, sending {name, confirm: name} -- never the ordinary two-click Reset', async () => {
    let resetCalls = [];
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:runtimeListFeatures': () => ({
                ok: true,
                features: [{ name: 'TabletTheming', currentValue: false, tier: 'live', overridden: true, overriddenBy: 'CIT1', overriddenAt: '2026-01-01 00:00:00', protected: false, lockoutRisk: true, sessionOnly: true, lockoutWarning: 'Disabling this disables SetTheme/ResetTheme until a restart.' }],
            }),
            'tablet:runtimeListTunables': () => ({ ok: true, tunables: [] }),
            'tablet:runtimeResetFeature': (body) => { resetCalls.push(body); return { ok: true, value: true, restartRequired: false }; },
        })),
    });
    await openTablet(h);
    openRuntimeControlTab(h);
    await settle();

    const resetBtn = findByText(h.getRoot(), 'Reset to default')[0];
    resetBtn.click(); // must NOT arm a two-click confirm -- opens the read-and-type panel instead
    await settle();
    t.equals(resetCalls.length, 0, 'opening the confirmation panel alone never sends a request');
    t.isTrue(findByText(h.getRoot(), 'Confirm This Change').length >= 1, 'the read-and-type panel opened, not an armed two-click button');

    const confirmInput = findAll(h.getRoot(), (n) => n.tagName === 'input' && n.classList.contains('k9tablet-runtime-lockout-confirm-input'))[0];
    t.isDefined(confirmInput, 'the same read-and-type panel is used for Reset');
    confirmInput.typeValue('TabletTheming');
    await settle();
    findByText(h.getRoot(), 'Confirm and Apply')[0].click();
    await new Promise((r) => setTimeout(r, 30));

    t.equals(resetCalls.length, 1);
    t.equals(resetCalls[0].name, 'TabletTheming');
    t.equals(resetCalls[0].confirm, 'TabletTheming');
});

t.test('a `confirmation_required` refusal (the server disagreeing with a stale/bypassed confirm) renders its OWN clear message, not a generic failure', async () => {
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:runtimeListFeatures': () => ({
                ok: true,
                features: [{ name: 'HighCommand', currentValue: true, tier: 'live', overridden: false, protected: false, lockoutRisk: true, sessionOnly: true, lockoutWarning: LOCKOUT_WARNING_TEXT }],
            }),
            'tablet:runtimeListTunables': () => ({ ok: true, tunables: [] }),
            'tablet:runtimeSetFeature': () => ({ ok: false, error: 'confirmation_required', lockoutRisk: true, warning: LOCKOUT_WARNING_TEXT }),
        })),
    });
    await openTablet(h);
    openRuntimeControlTab(h);
    await settle();

    findByText(h.getRoot(), 'Disable')[0].click();
    await settle();
    const confirmInput = findAll(h.getRoot(), (n) => n.tagName === 'input' && n.classList.contains('k9tablet-runtime-lockout-confirm-input'))[0];
    confirmInput.typeValue('HighCommand');
    await settle();
    findByText(h.getRoot(), 'Confirm and Apply')[0].click();
    await new Promise((r) => setTimeout(r, 30));

    t.isTrue(
        findByText(h.getRoot(), 'The confirmation did not match the feature name exactly. Read the warning again and re-type it to confirm.').length >= 1,
        'a dedicated, clear message is shown for confirmation_required -- never a bare/generic failure'
    );
});

// ======================================================================
// THE SERVER'S OWN `note` PROSE (2026-08-31)
//
// server/runtimecontrol.lua writes a plain-English `note` in three places,
// and until this pass no renderer in html/tablet.js read `result.note`, so
// every one of them was discarded on the way to the screen. Two of the
// three are the ONLY explanation the admin would ever get.
// ======================================================================

t.test("parent_disabled renders the server's note naming the blocking config flag, not a bare failure", async () => {
    const NOTE = 'Config.FeatureGroups.Combat.enabled is false in config.lua, so BiteAndHold cannot be turned on from here.';
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:runtimeListFeatures': () => ({ ok: true, features: [{ name: 'BiteAndHold', currentValue: false, tier: 'live', overridden: false }] }),
            'tablet:runtimeListTunables': () => ({ ok: true, tunables: [] }),
            'tablet:runtimeSetFeature': () => ({ ok: false, error: 'parent_disabled', parent: 'Combat', note: NOTE }),
        })),
    });
    await openTablet(h);
    openRuntimeControlTab(h);
    await settle();

    const enableBtn = findByText(h.getRoot(), 'Enable')[0];
    enableBtn.click();
    enableBtn.click();
    await new Promise((r) => setTimeout(r, 30));

    t.isTrue(findByText(h.getRoot(), NOTE).length > 0,
        "the server's own note must be shown -- it names the exact config.lua flag to change, and `parent_disabled` has no case in the switch, so without this the admin saw only the generic failure line");
});

t.test('a SESSION-ONLY success still warns that the change will not survive a restart', async () => {
    const NOTE = 'SESSION-ONLY: this change is NOT persisted -- the next resource restart reverts Config.Features.BiteAndHold.';
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:runtimeListFeatures': () => ({ ok: true, features: [{ name: 'BiteAndHold', currentValue: false, tier: 'live', overridden: false }] }),
            'tablet:runtimeListTunables': () => ({ ok: true, tunables: [] }),
            'tablet:runtimeSetFeature': () => ({ ok: true, appliedLive: true, restartRequired: false, tier: 'live', sessionOnly: true, note: NOTE }),
        })),
    });
    await openTablet(h);
    openRuntimeControlTab(h);
    await settle();

    const enableBtn = findByText(h.getRoot(), 'Enable')[0];
    enableBtn.click();
    enableBtn.click();
    await new Promise((r) => setTimeout(r, 30));

    const shown = findAll(h.getRoot(), (n) => typeof n.textContent === 'string' && n.textContent.indexOf('SESSION-ONLY') !== -1);
    t.isTrue(shown.length > 0,
        'dropping this is worse than dropping a refusal: the admin is told the action SUCCEEDED, watches it take effect, and finds it reverted after a restart with nothing having warned them');
});

t.test('a failure with no note still falls back to the mapped sentence for its code', async () => {
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:runtimeListFeatures': () => ({ ok: true, features: [{ name: 'SomeFeature', currentValue: false, tier: 'live', overridden: false }] }),
            'tablet:runtimeListTunables': () => ({ ok: true, tunables: [] }),
            'tablet:runtimeSetFeature': () => ({ ok: false, error: 'rate_limited' }),
        })),
    });
    await openTablet(h);
    openRuntimeControlTab(h);
    await settle();

    const enableBtn = findByText(h.getRoot(), 'Enable')[0];
    enableBtn.click();
    enableBtn.click();
    await new Promise((r) => setTimeout(r, 30));

    // CONTROL for the two tests above: reading `note` must not shadow the
    // existing switch when the server did not write one. Asserted against
    // the real mapped sentence rather than a whole-tree textContent scrape,
    // which the DOM stub does not aggregate.
    t.isTrue(findByText(h.getRoot(), 'Please wait a moment before trying again.').length > 0,
        'with no note present the switch must still map rate_limited to its own sentence');
    t.equals(findByText(h.getRoot(), 'undefined').length, 0,
        'a missing note must never render as the string "undefined"');
});

t.run();
