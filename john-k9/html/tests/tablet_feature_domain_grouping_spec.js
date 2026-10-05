/*
    html/tests/tablet_feature_domain_grouping_spec.js

    Owner-directed, 2026-08-26, verbatim: "same with features and sub
    features" -- Config.Features' 60 flat flags are now grouped into
    eleven domains (server/tablet.lua's FEATURE_DOMAINS), the same way
    commands were grouped. Covers the FRONTEND half of that: My Record's
    own buildMyFeaturesList() must render whatever domain set the server
    sends, in FEATURE_DOMAIN_ORDER's stable declared order, with a real
    heading per group -- DATA-DRIVEN, not the old two-domain (scent/
    vehicle) hardcoded if/else chain.

    Specifically proves:
      1. A brand-new domain this pass added (e.g. 'combat') renders under
         its own real heading, not silently as an unlabelled row.
      2. Several domains present at once render in the DECLARED order,
         not in whatever order the server happened to list features.
      3. A domain string this client's own FEATURE_DOMAIN_ORDER does NOT
         recognize (simulating an out-of-sync client talking to a server
         that grew a newer domain) still renders the feature -- under the
         generic "Other Abilities" heading -- NEVER silently dropped.
      4. scent/vehicle keep their own bespoke styling (colour accent /
         full-sentence text) unchanged; a brand-new domain gets the
         ordinary badge row, not a third invented style nobody asked for.
      5. The SAME data-driven behaviour holds on the Person screen's own
         admin feature table (buildPersonFeaturesSection) -- an
         unrecognized category still renders a normal, unaccented row.
*/
'use strict';

const t = require('./testkit');
const { createHarness, jsonResponse } = require('./tablet-sandbox');
const { findByText, findAll } = require('./tablet-dom-stub');

function routeFetch(handlers) {
    return function (url, init) {
        const name = url.split('/').pop();
        const body = init && init.body ? JSON.parse(init.body) : undefined;
        const h = handlers[name];
        if (!h) return Promise.reject(new Error('tablet_feature_domain_grouping_spec: unhandled NUI callback ' + name));
        return Promise.resolve(jsonResponse(h(body)));
    };
}

async function settle(times) {
    for (let i = 0; i < (times || 3); i++) await new Promise((r) => setImmediate(r));
}

/** Same click-through-the-bubbling-gap helper tablet_home_spec.js already
 * established for buildHomeActionCard()'s own outer-<button> click target. */
function clickActionCard(root, label) {
    var node = findByText(root, label)[0];
    if (!node) throw new Error('tablet_feature_domain_grouping_spec: no element with text ' + JSON.stringify(label));
    while (node && node.tagName !== 'button') node = node.parentNode;
    if (!node) throw new Error('tablet_feature_domain_grouping_spec: no enclosing <button> found for ' + JSON.stringify(label));
    node.click();
}

async function openMyRecord(myFeatures) {
    const h = createHarness({
        fetchImpl: routeFetch({
            'tablet:requestMyRecord': () => ({
                ok: true,
                viewer: { citizenid: 'V1', name: 'Officer V', isHighCommand: false, effectivePermissions: ['k9.access'], allowSelfGrant: false },
                certifications: [], xp: null, tierLabel: null, myFeatures: myFeatures,
            }),
        }),
    });
    h.postMessage('tablet:open', {});
    await settle();
    // NO NAVIGATION. The abilities list is on the landing screen now (plan
    // item A merged Home, My Record and Progression into one), so there is
    // no "View My Record" card to click -- it pointed at the screen the
    // viewer is already on.
    return h;
}

t.test('a "combat" feature (new this pass) renders under its own real "Combat & Restraint" heading, not unlabelled', async () => {
    const h = await openMyRecord([
        { key: 'BiteAndHold', label: 'Bite and Hold', category: 'combat', actionable: true, state: 'available' },
    ]);
    t.isTrue(findByText(h.getRoot(), 'Combat & Restraint').length >= 1);
    t.isTrue(findByText(h.getRoot(), 'Bite and Hold').length >= 1);
});

t.test('several domains present at once render in the DECLARED order (scent, then combat, then movement here), not the server\'s own array order', async () => {
    // Deliberately sent out of declared order (movement, combat, scent) --
    // FEATURE_DOMAIN_ORDER is scent, search, vision, combat, movement, ...
    const h = await openMyRecord([
        { key: 'VehicleEntryExit', label: 'Get In/Out', category: 'movement', actionable: false, state: 'available' },
        { key: 'BiteAndHold', label: 'Bite and Hold', category: 'combat', actionable: false, state: 'available' },
        { key: 'ScentTracking', label: 'Track Scent', category: 'scent', actionable: false, state: 'available' },
    ]);

    const headings = findAll(h.getRoot(), (n) => n.tagName === 'h3' && typeof n._textContent === 'string')
        .map((n) => n._textContent)
        .filter((text) => text === 'Scent & Tracking' || text === 'Combat & Restraint' || text === 'Movement & Control');

    t.equals(headings.length, 3, 'all three headings rendered');
    t.equals(headings[0], 'Scent & Tracking');
    t.equals(headings[1], 'Combat & Restraint');
    t.equals(headings[2], 'Movement & Control');
});

t.test('an UNRECOGNIZED domain string (a newer server, an older client) still renders the feature, under the generic "Other Abilities" heading, never dropped', async () => {
    const h = await openMyRecord([
        { key: 'BiteAndHold', label: 'Bite and Hold', category: 'combat', actionable: false, state: 'available' },
        { key: 'FutureThing', label: 'Some Future Ability', category: 'quantum_teleportation', actionable: false, state: 'available' },
    ]);
    t.isTrue(findByText(h.getRoot(), 'Other Abilities').length >= 1, 'the fallback heading appears since a domain-having section exists alongside it');
    t.isTrue(findByText(h.getRoot(), 'Some Future Ability').length >= 1, 'the row itself is never silently dropped just because its domain string is unrecognized');
});

t.test('scent keeps its colour-accent row class; a brand-new domain (combat) gets the ordinary badge row, no invented third style', async () => {
    const h = await openMyRecord([
        { key: 'ScentTracking', label: 'Track Scent', category: 'scent', actionable: false, state: 'available' },
        { key: 'BiteAndHold', label: 'Bite and Hold', category: 'combat', actionable: false, state: 'available' },
    ]);

    const scentRows = findAll(h.getRoot(), (n) => typeof n.className === 'string' && n.className.indexOf('k9tablet-feature-row--scent') !== -1);
    t.isTrue(scentRows.length >= 1, 'scent still gets its own accent class');

    const combatRows = findAll(h.getRoot(), (n) => typeof n.className === 'string' && n.className.indexOf('k9tablet-feature-row--combat') !== -1);
    t.equals(combatRows.length, 0, 'combat (and every other new domain) gets the ORDINARY row -- no accent class invented for it');
});

t.test('vehicle keeps its own text-forward sentence rendering, unaffected by the new domains existing', async () => {
    const h = await openMyRecord([
        { key: 'VehicleEntryExit', label: 'Get In/Out of Vehicles', category: 'vehicle', actionable: false, state: 'available' },
    ]);
    t.isTrue(findByText(h.getRoot(), 'Get In/Out of Vehicles is currently: Available.').length >= 1, 'the full-sentence vehicle rendering is unchanged');
});

// ------------------------------------------------------------------
// Person screen's own admin feature table (buildPersonFeaturesSection) --
// same data-driven behaviour, a different rendering shape (a flat,
// searchable table rather than headed sections).
// ------------------------------------------------------------------

t.test('Person screen: a feature with an unrecognized domain still renders as a normal row, with no special class and no crash', async () => {
    const h = createHarness({
        fetchImpl: routeFetch({
            'tablet:requestMyRecord': () => ({
                ok: true,
                viewer: { citizenid: 'HC1', name: 'Chief', isHighCommand: true, effectivePermissions: ['k9.access', 'k9.certify', 'k9.audit', 'k9.givexp'], allowSelfGrant: false },
                certifications: [], xp: null, tierLabel: null, myFeatures: [],
            }),
            'tablet:requestRoster': () => ({ ok: true, rows: [{ citizenid: 'TARGET1', name: 'K9 Rex', departmentLabel: 'Police', certified: true, xp: 0, tierLabel: null }], truncated: false }),
            'tablet:requestOnlinePlayers': () => ({ ok: true, rows: [], truncated: false }),
            'tablet:requestPersonSummary': () => ({ ok: true, target: { citizenid: 'TARGET1', name: 'K9 Rex' }, certifications: [], xp: 0, tierLabel: null, permissions: [] }),
            'tablet:requestPersonFeatures': () => ({
                ok: true,
                target: { citizenid: 'TARGET1', name: 'K9 Rex' },
                features: [
                    { key: 'FutureThing', label: 'Some Future Ability', category: 'quantum_teleportation', globallyEnabled: true, requiresGrant: false, granted: false, blocked: false, state: 'available' },
                    { key: 'ScentTracking', label: 'Track Scent', category: 'scent', globallyEnabled: true, requiresGrant: false, granted: false, blocked: false, state: 'available' },
                ],
            }),
        }),
    });
    h.postMessage('tablet:open', {});
    await settle();
    findByText(h.getRoot(), 'Manage')[0].click();
    await settle();

    t.isTrue(findByText(h.getRoot(), 'Some Future Ability').length >= 1, 'the row renders even though its domain is unrecognized');
    const accentedNameCells = findAll(h.getRoot(), (n) => typeof n.className === 'string' && n.className.indexOf('k9tablet-person-feature-name--quantum_teleportation') !== -1);
    t.equals(accentedNameCells.length, 0, 'no class is invented for an unrecognized domain');

    const scentAccentedCells = findAll(h.getRoot(), (n) => typeof n.className === 'string' && n.className.indexOf('k9tablet-person-feature-name--scent') !== -1);
    t.isTrue(scentAccentedCells.length >= 1, 'scent still gets its own accent class here too');
});

t.run();
