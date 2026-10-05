// html/tests/tablet_hide_disabled_features_spec.js
//
// THE RULE (2026-09-01, owner's own words: "Also make it where if something
// is turned off in the config nothing on the tablet shows up").
//
// A feature whose Config.Features key is false does not exist on this
// server. Nobody can be granted it, earn it, or be blocked from it. The
// tablet used to list it anyway, with a "Disabled server-wide" badge, on
// every screen that shows abilities or commands -- telling every reader
// about a capability they can never have. On a server that switches a few
// families off, that is a large share of every list being noise.
//
// So off features are now dropped from the in-use lists:
//   - My Record's own abilities list
//   - a person's abilities table on the admin Person screen
//   - the Command Reference (a command whose gated feature is off)
//
// THE ONE DELIBERATE EXCEPTION IS RUNTIME CONTROL, and it is not an
// oversight -- it is the screen where high command turns features on and
// off. Hiding the off ones there would mean switching a feature off and
// then having no way ever to switch it back on. It reads its own separate
// tablet:runtimeListFeatures payload and must keep showing everything. That
// screen is the inventory; the others are the in-use lists.
//
// WHAT IS NOT HIDDEN, and why it matters just as much: 'blocked',
// 'not_certified' and 'requires_grant_missing' all stay visible. Those
// describe a real feature this person could have, and hiding them would
// answer "why can't I do this" with silence instead of a reason. 'unknown'
// stays visible too -- a record that has not resolved yet must never be
// mistaken for a server with everything switched off.

'use strict';

const t = require('./testkit');
const { createHarness, jsonResponse } = require('./tablet-sandbox');
const { findByText, findAll, openSettingsSection } = require('./tablet-dom-stub');

function routeFetch(handlers) {
    return function (url, init) {
        const name = String(url).split('/').pop();
        const body = init && init.body ? JSON.parse(init.body) : {};
        const h = handlers[name];
        if (!h) return Promise.reject(new Error('tablet_hide_disabled_features_spec: unhandled NUI callback ' + name));
        return Promise.resolve(jsonResponse(h(body)));
    };
}

async function settle(times) {
    for (let i = 0; i < (times || 4); i++) await new Promise((r) => setImmediate(r));
}

// Derived from html/tablet.js itself, the same raw-source convention
// tablet_command_reference_spec.js uses -- needed only so the count test
// below can prove its fixture actually hid something, rather than comparing
// the full catalog against itself and passing for the wrong reason.
const fs = require('fs');
const path = require('path');
const REAL_COMMAND_REFERENCE_COUNT = (function () {
    // Reads tablet-catalog.js -- the catalog literals moved there 2026-09-02.
    const src = fs.readFileSync(path.join(__dirname, '..', 'tablet-catalog.js'), 'utf8');
    const startPos = src.indexOf('var COMMAND_REFERENCE = [');
    if (startPos === -1) throw new Error('tablet_hide_disabled_features_spec: COMMAND_REFERENCE not found in html/tablet.js');
    const body = src.slice(startPos, src.indexOf('\n    ];', startPos));
    const matches = body.match(/command:\s*'[a-zA-Z0-9_:-]+'/g);
    if (!matches) throw new Error('tablet_hide_disabled_features_spec: matched zero command entries -- extraction pattern is stale');
    return matches.length;
})();

const HIGH_COMMAND_VIEWER = {
    citizenid: 'HC1', name: 'Chief', isHighCommand: true,
    effectivePermissions: ['k9.access', 'k9.certify', 'k9.audit', 'k9.givexp', 'k9.runtimecontrol'],
    allowSelfGrant: true,
};

// One of each state that matters, so every assertion below has both a
// positive and a negative case in the same fixture.
const MIXED_STATES = [
    { key: 'OnFeature', label: 'On Feature', category: 'combat', state: 'available' },
    { key: 'OffFeature', label: 'Off Feature', category: 'combat', state: 'global_off' },
    { key: 'BlockedFeature', label: 'Blocked Feature', category: 'combat', state: 'blocked' },
    { key: 'UncertifiedFeature', label: 'Uncertified Feature', category: 'gear', state: 'not_certified' },
    { key: 'UngrantedFeature', label: 'Ungranted Feature', category: 'gear', state: 'requires_grant_missing' },
];

function harness(extra) {
    return createHarness({
        fetchImpl: routeFetch(Object.assign({
            'tablet:requestMyRecord': () => ({
                ok: true, viewer: HIGH_COMMAND_VIEWER, certifications: [], xp: null, tierLabel: null,
                myFeatures: MIXED_STATES,
            }),
            'tablet:requestRoster': () => ({ ok: true, rows: [{ citizenid: 'TARGET1', name: 'K9 Rex', departmentLabel: 'Police', certified: true, xp: 100, tierLabel: 'Trained K9' }], truncated: false }),
            'tablet:requestPersonSummary': () => ({ ok: true, target: { citizenid: 'TARGET1', name: 'K9 Rex' }, certifications: [], xp: 0, tierLabel: null, permissions: [] }),
            'tablet:permKeysList': () => ({ ok: true, keys: [] }),
            'tablet:requestPersonFeatures': () => ({
                ok: true,
                target: { citizenid: 'TARGET1', name: 'K9 Rex' },
                features: MIXED_STATES.map((f) => Object.assign({}, f, {
                    globallyEnabled: f.state !== 'global_off',
                    requiresGrant: false, granted: false, blocked: f.state === 'blocked',
                })),
            }),
        }, extra || {})),
    });
}

async function openMyRecord(h) {
    h.postMessage('tablet:open', {});
    await settle();
    findByText(h.getRoot(), 'My Record')[0].click();
    await settle();
}

async function openPerson(h) {
    h.postMessage('tablet:open', {});
    await settle();
    findByText(h.getRoot(), 'Command Console')[0].click();
    await settle();
    findByText(h.getRoot(), 'Manage')[0].click();
    await settle(6);
}

// ---------------------------------------------------------------- My Record

t.test('MY RECORD: a feature switched off server-wide is not listed', async () => {
    const h = harness();
    await openMyRecord(h);
    t.equals(findByText(h.getRoot(), 'Off Feature').length, 0, 'the off feature is gone');
});

t.test('MY RECORD: only what you can use right now is listed -- blocked, not certified and not granted are left out too (owner: show what they are certified in)', async () => {
    const h = harness();
    await openMyRecord(h);
    t.isTrue(findByText(h.getRoot(), 'On Feature').length >= 1, 'available is listed');
    t.equals(findByText(h.getRoot(), 'Blocked Feature').length, 0, 'blocked is not listed');
    t.equals(findByText(h.getRoot(), 'Uncertified Feature').length, 0, 'not-certified is not listed');
    t.equals(findByText(h.getRoot(), 'Ungranted Feature').length, 0, 'requires-grant is not listed');
});

t.test('MY RECORD: the "Disabled server-wide" badge no longer appears anywhere', async () => {
    const h = harness();
    await openMyRecord(h);
    t.equals(findByText(h.getRoot(), 'Disabled server-wide').length, 0, 'nothing is badged as off, because nothing off is shown');
});

// ------------------------------------------------------------ Person screen

t.test('PERSON SCREEN: an off feature is dropped from the admin abilities table too', async () => {
    const h = harness();
    await openPerson(h);
    t.equals(findByText(h.getRoot(), 'Off Feature').length, 0, 'not listed for an admin either');
});

t.test('PERSON SCREEN: the states an admin can actually act on all remain', async () => {
    const h = harness();
    await openPerson(h);
    t.isTrue(findByText(h.getRoot(), 'On Feature').length >= 1);
    t.isTrue(findByText(h.getRoot(), 'Blocked Feature').length >= 1);
    t.isTrue(findByText(h.getRoot(), 'Ungranted Feature').length >= 1, 'still grantable, so still shown');
});

// -------------------------------------------------------- Command Reference

t.test('COMMAND REFERENCE: a command whose gated feature is off is not listed', async () => {
    // The third of the three in-use lists this file's header names. Uses
    // real COMMAND_REFERENCE entries and real gate featureKeys: BiteAndHold
    // gates /k9bite, and is switched off here while DeployableKennel (which
    // gates /k9deploykennel) stays on.
    const h = createHarness({
        fetchImpl: routeFetch({
            'tablet:requestMyRecord': () => ({
                ok: true, viewer: HIGH_COMMAND_VIEWER, certifications: [], xp: null, tierLabel: null,
                myFeatures: [
                    { key: 'BiteAndHold', category: 'combat', actionable: true, state: 'global_off' },
                    { key: 'DeployableKennel', category: 'gear', actionable: true, state: 'available' },
                ],
            }),
        }),
    });
    h.postMessage('tablet:open', {});
    await settle();
    findByText(h.getRoot(), 'Guide')[0].click();
    await settle();

    t.equals(findByText(h.getRoot(), '/k9bite').length, 0, 'the command for a switched-off feature is gone from the reference');
    t.isTrue(findByText(h.getRoot(), '/k9deploykennel').length >= 1, 'CONTROL: a command whose feature is on is still listed');
});

t.test('COMMAND REFERENCE: the filter readout counts only what this server actually has', async () => {
    // "Showing 3 of 28" must not use a denominator that includes commands
    // nobody on this server can ever run -- that would be a number the
    // operator cannot reconcile with what is on screen.
    const h = createHarness({
        fetchImpl: routeFetch({
            'tablet:requestMyRecord': () => ({
                ok: true, viewer: HIGH_COMMAND_VIEWER, certifications: [], xp: null, tierLabel: null,
                myFeatures: [{ key: 'DeployableKennel', category: 'gear', actionable: true, state: 'available' }],
            }),
        }),
    });
    h.postMessage('tablet:open', {});
    await settle();
    findByText(h.getRoot(), 'Guide')[0].click();
    await settle();

    const visibleRows = findAll(h.getRoot(), (n) => n.classList && n.classList.contains('k9tablet-feature-state')).length;

    const search = findAll(h.getRoot(), (n) => n.tagName === 'input' && n.getAttribute('placeholder') === 'Search commands...')[0];
    t.isDefined(search, 'sanity: the filter is on screen');
    search.typeValue('deploykennel');
    await settle();

    const count = findAll(h.getRoot(), (n) => n.classList && n.classList.contains('k9tablet-feature-filter-count'))[0];
    t.isDefined(count, 'the readout appeared');
    // Asserting the DENOMINATOR, which is what this test is about. The
    // numerator is whatever happens to match the search term -- more than
    // one command's usage text mentions the kennel, and pinning that number
    // would make this a brittle test about the catalog's wording rather
    // than about the count being scoped to visible commands.
    const denominator = Number(String(count.textContent).replace(/^Showing \d+ of /, ''));
    t.equals(
        denominator, visibleRows,
        'the denominator is the number of commands actually listed, not the whole catalog: ' + count.textContent
    );
    t.isTrue(
        visibleRows < REAL_COMMAND_REFERENCE_COUNT,
        'sanity: this fixture really did hide some commands (' + visibleRows + ' of ' + REAL_COMMAND_REFERENCE_COUNT
        + ' listed), so the assertion above is not comparing two copies of the same full total'
    );
});

// ------------------------------------------------- Runtime Control exception

t.test('RUNTIME CONTROL STILL SHOWS OFF FEATURES -- otherwise nothing could ever be switched back on', async () => {
    // The exception that makes the whole rule survivable. If this ever
    // starts hiding off features, an owner who switches something off loses
    // the only control that could switch it on again, and the fix would be
    // editing config.lua by hand. That is a trap, not a tidy-up.
    const h = harness({
        'tablet:runtimeListFeatures': () => ({
            ok: true,
            features: [
                { name: 'OffFeature', currentValue: false, tier: 'live', overridden: false, protected: false },
                { name: 'OnFeature', currentValue: true, tier: 'live', overridden: false, protected: false },
            ],
        }),
        'tablet:runtimeListTunables': () => ({ ok: true, tunables: [] }),
    });
    h.postMessage('tablet:open', {});
    await settle();
    openSettingsSection(h.getRoot(), 'Runtime Control');
    await settle(6);

    t.isTrue(findByText(h.getRoot(), 'OffFeature').length >= 1, 'the switched-OFF feature is still listed here, and must stay listed');
    t.isTrue(findByText(h.getRoot(), 'OnFeature').length >= 1, 'alongside the on one');
});

// ------------------------------------------------------------ not-loaded case

t.test('A RECORD THAT HAS NOT RESOLVED HIDES NOTHING -- "not loaded" must never be mistaken for "switched off"', async () => {
    // The failure this guards against is the one the owner already hit once
    // from the other direction ("everything in the command console in the
    // status says disabled"). If an unresolved record were treated as off,
    // this change would empty the entire tablet for a moment on every open,
    // which is a far worse version of the same bug.
    const h = createHarness({
        fetchImpl: routeFetch({
            'tablet:requestMyRecord': () => ({ ok: true, viewer: HIGH_COMMAND_VIEWER, certifications: [], xp: null, tierLabel: null }),
        }),
    });
    h.postMessage('tablet:open', {});
    await settle();
    findByText(h.getRoot(), 'Guide')[0].click();
    await settle();

    const badges = findAll(h.getRoot(), (n) => n.classList && n.classList.contains('k9tablet-feature-state'));
    t.isTrue(badges.length > 0, 'the Command Reference is NOT emptied while the record is unresolved');
    t.isTrue(
        badges.map((n) => n._textContent).indexOf('Still loading…') !== -1,
        'those rows read as still loading, not as off'
    );
});


// ======================================================================
// ADMIN SURFACES -- a TAB for a feature this server has switched off
//
// Owner directive, verbatim: "ensure anything disabled in the config or
// requires a restart wont show up in the tablet".
//
// The rule above ("a feature whose Config.Features key is false does not
// exist on this server") was implemented for the in-use LISTS -- abilities,
// person abilities, the command reference -- and never for the TABS. Every
// admin tab was gated on the viewer's CAPABILITY alone: do they hold
// 'k9.tablettheme', 'k9.runtimecontrol', and so on. A capability says "you
// are allowed to use this screen"; it says nothing about whether the
// screen's feature is on. So Config.Features.TabletTheming = false still
// produced a Theme tab you could open and edit, with every save refused by
// a server-side flag check the tab never mirrored -- and the Audit tab was
// worse: server/admin.lua does not even REGISTER its tabletAudit* callbacks
// with AdminAuditCommands off, so that tab did not fail, it hung.
//
// server/tablet.lua's BuildAvailableSurfaces() now resolves this from the
// same flags those callbacks enforce and ships it as `viewer.surfaces`;
// html/tablet.js's surfaceEnabled() reads it.
//
// FAIL-OPEN IS PART OF THE CONTRACT, not a loophole: an absent key, and an
// absent `surfaces` object entirely, both mean available. An older server,
// or a payload that lost the field, must keep every tab it has always had
// rather than silently shedding admin screens. That is safe because this
// is a convenience gate, never a security one -- every screen behind it
// re-authorizes server-side regardless of whether its tab was shown.
// ======================================================================

const ADMIN_SURFACE_TABS = [
    { surface: 'theme', tab: 'Tablet Theme' },
    { surface: 'runtime_control', tab: 'Runtime Control' },
    { surface: 'audit', tab: 'Audit Trail' },
];

/** A high-command viewer holding every delegated capability, with `surfaces` overridden. */
function surfacesHarness(surfaces) {
    const viewer = Object.assign({}, HIGH_COMMAND_VIEWER, {
        effectivePermissions: [
            'k9.access', 'k9.certify', 'k9.audit', 'k9.givexp',
            'k9.runtimecontrol', 'k9.tablettheme',
            'k9.equipmentshoplocations', 'k9.equipmentshopitems',
        ],
    });
    if (surfaces !== undefined) viewer.surfaces = surfaces;
    return createHarness({
        fetchImpl: routeFetch({
            'tablet:requestMyRecord': () => ({
                ok: true, viewer: viewer, certifications: [], xp: null, tierLabel: null,
                myFeatures: MIXED_STATES,
            }),
        }),
    });
}

/** Opens the tablet and, when this viewer has one, the Server Settings tab
 * -- whose section row is where Theme, Runtime Control, Catalogs and the
 * Shop are offered now. Everything else (Audit Trail, Command Console) is
 * still on the tab bar, which stays visible on every screen. */
async function openTabletOnly(h) {
    h.postMessage('tablet:open', {});
    await settle();
    const settingsTab = findByText(h.getRoot(), 'Server Settings')[0];
    if (settingsTab) {
        settingsTab.click();
        await settle();
    }
}

t.test('ADMIN SURFACES: with everything on, a fully-capable viewer sees every admin tab -- the baseline the hiding tests are measured against', async () => {
    const all = {};
    for (const entry of ADMIN_SURFACE_TABS) all[entry.surface] = true;
    const h = surfacesHarness(all);
    await openTabletOnly(h);

    for (const entry of ADMIN_SURFACE_TABS) {
        t.isTrue(findByText(h.getRoot(), entry.tab).length >= 1, entry.tab + ' tab is present when its feature is on');
    }
});

for (const entry of ADMIN_SURFACE_TABS) {
    t.test('ADMIN SURFACES: the ' + entry.tab + ' tab is hidden when its feature is off in the config, even for a viewer who holds the capability', async () => {
        // Every OTHER surface stays on, so a failure here cannot be "all
        // tabs vanished" -- it has to be this one specifically.
        const surfaces = {};
        for (const other of ADMIN_SURFACE_TABS) surfaces[other.surface] = other.surface !== entry.surface;
        const h = surfacesHarness(surfaces);
        await openTabletOnly(h);

        t.equals(findByText(h.getRoot(), entry.tab).length, 0, entry.tab + ' must not be offered');

        for (const other of ADMIN_SURFACE_TABS) {
            if (other.surface === entry.surface) continue;
            t.isTrue(findByText(h.getRoot(), other.tab).length >= 1, other.tab + ' must be unaffected');
        }
    });
}

t.test('ADMIN SURFACES: turning AdminAuditCommands off does NOT also take away the Command Console -- two screens, one flag, kept apart', async () => {
    // canAccessConsole() returns canViewAudit() verbatim (the two share the
    // 'k9.audit' capability by design), so folding the audit SURFACE check
    // into canViewAudit would have removed the Console too. That is exactly
    // the conflation this pass exists to undo, which is why the audit gate
    // is its own canOpenAuditScreen().
    const h = surfacesHarness({ audit: false });
    await openTabletOnly(h);

    t.equals(findByText(h.getRoot(), 'Audit Trail').length, 0, 'the Audit tab is gone');
    t.isTrue(findByText(h.getRoot(), 'Command Console').length >= 1, 'the Command Console is not');
});

t.test('ADMIN SURFACES: the Catalogs tab survives with its optional sections off -- certification tiers has no feature flag, so there is always something behind it', async () => {
    // Three catalog editors became one tab (plan item G). Two of the three
    // answer to a feature flag; certification tiers does not. So unlike the
    // shop tab, this one is never hidden by a surface -- the sections
    // inside it disappear individually, which is where those checks moved.
    const h = surfacesHarness({ permission_keys: false, xp_tiers: false });
    await openTabletOnly(h);
    t.isTrue(findByText(h.getRoot(), 'Catalogs').length >= 1, 'the tab stays -- certification tiers is always editable');
});

t.test('ADMIN SURFACES: the ONE K9 Supply Shop tab needs only ONE of its two surfaces -- it is two sections behind two independent permissions', async () => {
    // The two shop screens became one tab (plan item F), but the two
    // server-side keys did NOT merge: 'k9.equipmentshoplocations' and
    // 'k9.equipmentshopitems' stay independently delegable, and the
    // sections inside the tab are gated separately. So the tab survives as
    // long as EITHER half is available -- hiding it because one went off
    // would take away the half that still works.
    const onlyLocations = surfacesHarness({ shop_locations: true, shop_items: false });
    await openTabletOnly(onlyLocations);
    t.isTrue(findByText(onlyLocations.getRoot(), 'K9 Supply Shop').length >= 1, 'locations alone keeps the tab');

    const onlyItems = surfacesHarness({ shop_locations: false, shop_items: true });
    await openTabletOnly(onlyItems);
    t.isTrue(findByText(onlyItems.getRoot(), 'K9 Supply Shop').length >= 1, 'items alone keeps the tab');
});

t.test('ADMIN SURFACES: with BOTH shop surfaces off the K9 Supply Shop tab is gone entirely', async () => {
    const h = surfacesHarness({ shop_locations: false, shop_items: false });
    await openTabletOnly(h);
    t.equals(findByText(h.getRoot(), 'K9 Supply Shop').length, 0, 'nothing left in it, so nothing to offer');
});

t.test('ADMIN SURFACES: FAILS OPEN -- a payload with no `surfaces` object at all keeps every tab', async () => {
    const h = surfacesHarness(undefined);
    await openTabletOnly(h);

    for (const entry of ADMIN_SURFACE_TABS) {
        t.isTrue(findByText(h.getRoot(), entry.tab).length >= 1, entry.tab + ' survives a payload that never mentions surfaces');
    }
    t.isTrue(findByText(h.getRoot(), 'K9 Supply Shop').length >= 1, 'and so does the shop tab, whose two surfaces are checked separately');
    t.isTrue(findByText(h.getRoot(), 'Catalogs').length >= 1, 'and the catalogs tab, whose sections are checked separately');
});

t.test('ADMIN SURFACES: FAILS OPEN -- a `surfaces` object that simply omits a key keeps that tab', async () => {
    // A newer tab shipping before the server learns to describe it must not
    // disappear. Only an explicit `false` hides anything.
    const h = surfacesHarness({ theme: true });
    await openTabletOnly(h);

    for (const entry of ADMIN_SURFACE_TABS) {
        t.isTrue(findByText(h.getRoot(), entry.tab).length >= 1, entry.tab + ' survives an incomplete surfaces map');
    }
});

t.run();
