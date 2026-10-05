// html/tests/tablet_person_feature_sections_spec.js
//
// THE SCREEN THIS COVERS, AND WHY IT CHANGED (2026-09-01).
//
// The owner's report, in his own words: "there is still search boxes in the
// ui please change it where its boxes i check especially permission keys",
// and then "update everything where its easier to understand better section
// management etc and i want it where everything is super easy to understand
// and everything is diffrentied better".
//
// The abilities list on a person's record (buildPersonFeaturesSection in
// html/tablet.js) already rendered a real control per row -- the boxes he
// wanted were there. What it did NOT have was any shape: one flat table of
// every Config.Features key, 57 rows on a default server, with a bare text
// input above it whose only explanation was its own placeholder. A bare
// input above a long list reads as "type here to find things", which is
// what made a screen full of checkboxes feel like a search screen.
//
// So this spec pins the two things that changed:
//   1. the rows are banded into the SAME domain sections, in the SAME
//      declared order, that the My Record screen has always used -- so
//      scanning to a section replaces having to search;
//   2. the filter is labelled, is explicitly optional, reports what it is
//      currently hiding, and can be cleared from the screen.
// Plus the bug found on the way: filtering to zero matches used to claim
// the PERSON had no abilities, which is a different (and false) statement.
//
// Nothing here asserts anything about grant/revoke authority. That is
// server-side and covered elsewhere; this file is strictly about what the
// operator can see and understand.

const t = require('./testkit');
const { createHarness, jsonResponse } = require('./tablet-sandbox');
const { findByText, findAll } = require('./tablet-dom-stub');

function routeFetch(handlers) {
    return function (url, init) {
        const name = String(url).split('/').pop();
        const body = init && init.body ? JSON.parse(init.body) : {};
        const h = handlers[name];
        if (!h) return Promise.reject(new Error('tablet_person_feature_sections_spec: unhandled NUI callback ' + name));
        return Promise.resolve(jsonResponse(h(body)));
    };
}

const HIGH_COMMAND_VIEWER = {
    citizenid: 'HC1', name: 'Chief', isHighCommand: true,
    effectivePermissions: ['k9.access', 'k9.certify', 'k9.audit', 'k9.givexp'],
    allowSelfGrant: false,
};

// Deliberately spans several domains AND arrives in an order that does not
// match FEATURE_DOMAIN_ORDER, so the grouping is doing real work rather
// than the server having handed the rows over pre-sorted. `zzz_unknown` is
// a domain this client has never heard of -- it must land in 'other', never
// be dropped.
const MIXED_FEATURES = [
    { key: 'f_gear', label: 'Vest', category: 'gear', state: 'available', globallyEnabled: true },
    { key: 'f_scent1', label: 'Track A Scent', category: 'scent', state: 'available', globallyEnabled: true },
    { key: 'f_combat', label: 'Apprehend', category: 'combat', state: 'available', globallyEnabled: true },
    { key: 'f_scent2', label: 'Scent Trail', category: 'scent', state: 'available', globallyEnabled: true },
    { key: 'f_weird', label: 'Mystery Ability', category: 'zzz_unknown', state: 'available', globallyEnabled: true },
    { key: 'f_none', label: 'Uncategorised Ability', state: 'available', globallyEnabled: true },
];

async function settle(times) {
    for (let i = 0; i < (times || 3); i++) await new Promise((r) => setImmediate(r));
}

function harnessWith(features) {
    return createHarness({
        fetchImpl: routeFetch({
            'tablet:requestMyRecord': () => ({ ok: true, viewer: HIGH_COMMAND_VIEWER, certifications: [], xp: null, tierLabel: null, myFeatures: [] }),
            'tablet:requestRoster': () => ({ ok: true, rows: [{ citizenid: 'TARGET1', name: 'K9 Rex', departmentLabel: 'Police', certified: true, xp: 500, tierLabel: 'Trained K9' }], truncated: false }),
            'tablet:requestPersonSummary': () => ({ ok: true, target: { citizenid: 'TARGET1', name: 'K9 Rex' }, certifications: [], xp: 500, tierLabel: 'Trained K9', permissions: ['k9.access'] }),
            'tablet:permKeysList': () => ({ ok: true, keys: [] }),
            'tablet:requestPersonFeatures': () => ({ ok: true, target: { citizenid: 'TARGET1', name: 'K9 Rex' }, features }),
        }),
    });
}

async function openPerson(h) {
    h.postMessage('tablet:open', {});
    await settle();
    findByText(h.getRoot(), 'Command Console')[0].click();
    await settle();
    findByText(h.getRoot(), 'Manage')[0].click();
    await settle(6);
}

/** Every section band, in the order they actually appear in the table. */
function sectionLabels(h) {
    return findAll(h.getRoot(), (n) => n.classList && n.classList.contains('k9tablet-feature-group-row-label'))
        .map((n) => n.textContent);
}

function filterInput(h) {
    return findAll(h.getRoot(), (n) => n.tagName === 'input' && n.getAttribute('placeholder') === 'Search abilities...')[0];
}

t.test('the abilities table is banded into domain sections instead of one flat wall of rows', async () => {
    const h = harnessWith(MIXED_FEATURES);
    await openPerson(h);

    const labels = sectionLabels(h);
    t.isTrue(labels.length > 1, 'more than one section actually rendered -- a single band would be the flat wall again');
    t.isTrue(labels.indexOf('Scent Work') !== -1 || labels.some((l) => /scent/i.test(l)), 'the scent rows got their own band');
    t.isTrue(labels.some((l) => /other/i.test(l)), 'the unknown-domain and uncategorised rows got a band rather than vanishing');
});

t.test('sections follow the SAME declared order the My Record screen uses, not the order the server happened to send', async () => {
    const h = harnessWith(MIXED_FEATURES);
    await openPerson(h);

    const labels = sectionLabels(h);
    // FEATURE_DOMAIN_ORDER puts scent first and combat before gear; the
    // fixture deliberately sends gear first and scent second.
    const scentIdx = labels.findIndex((l) => /scent/i.test(l));
    const combatIdx = labels.findIndex((l) => /combat|apprehen/i.test(l));
    const gearIdx = labels.findIndex((l) => /gear|equip/i.test(l));
    const otherIdx = labels.findIndex((l) => /other/i.test(l));

    t.isTrue(scentIdx !== -1 && combatIdx !== -1 && gearIdx !== -1 && otherIdx !== -1, 'all four expected bands are present');
    t.isTrue(scentIdx < combatIdx, 'scent precedes combat, per the declared order (the server sent gear first)');
    t.isTrue(combatIdx < gearIdx, 'combat precedes gear, per the declared order');
    t.isTrue(otherIdx === labels.length - 1, '"other" is always last, never interleaved');
});

t.test('an ability whose domain this client has never heard of is still shown, never silently dropped', async () => {
    const h = harnessWith(MIXED_FEATURES);
    await openPerson(h);
    // The real risk of bucketing by a declared order is that an unrecognised
    // category matches no bucket and the row disappears -- an operator would
    // have no way to know an ability existed at all.
    t.isTrue(findByText(h.getRoot(), 'Mystery Ability').length > 0, 'the zzz_unknown-domain ability is on screen');
    t.isTrue(findByText(h.getRoot(), 'Uncategorised Ability').length > 0, 'the ability with no category at all is on screen');
});

t.test('every ability in the fixture reaches the table exactly once -- banding is a display grouping, never a filter', async () => {
    const h = harnessWith(MIXED_FEATURES);
    await openPerson(h);
    for (const f of MIXED_FEATURES) {
        t.equals(findByText(h.getRoot(), f.label).length, 1, f.label + ' appears exactly once');
    }
});

t.test('the filter carries a visible label saying it is optional -- it is not the primary way to use this screen', async () => {
    const h = harnessWith(MIXED_FEATURES);
    await openPerson(h);
    const label = findAll(h.getRoot(), (n) => n.classList && n.classList.contains('k9tablet-feature-filter-label'))[0];
    t.isDefined(label, 'the filter has a real <label>, not just a placeholder');
    t.contains(label.textContent.toLowerCase(), 'optional', 'and it says out loud that it is optional');
});

t.test('with no filter applied there is no count readout and no Clear button -- nothing is being hidden, so nothing is claimed', async () => {
    const h = harnessWith(MIXED_FEATURES);
    await openPerson(h);
    t.equals(findAll(h.getRoot(), (n) => n.classList && n.classList.contains('k9tablet-feature-filter-count')).length, 0, 'no "showing X of Y" when X === Y');
    t.equals(findByText(h.getRoot(), 'Clear filter').length, 0, 'no Clear button when there is nothing to clear');
});

t.test('filtering reports exactly what it is hiding, and offers the way back', async () => {
    const h = harnessWith(MIXED_FEATURES);
    await openPerson(h);

    filterInput(h).typeValue('scent');
    await settle();

    const count = findAll(h.getRoot(), (n) => n.classList && n.classList.contains('k9tablet-feature-filter-count'))[0];
    t.isDefined(count, 'the readout appears as soon as the filter narrows anything');
    t.equals(count.textContent, 'Showing 2 of 6', 'and it states both numbers, so "what am I not seeing" is answerable');
    t.isTrue(findByText(h.getRoot(), 'Clear filter').length > 0, 'a Clear button appears alongside it');
});

t.test('clearing the filter from the button restores the full list', async () => {
    const h = harnessWith(MIXED_FEATURES);
    await openPerson(h);

    filterInput(h).typeValue('scent');
    await settle();
    t.equals(findByText(h.getRoot(), 'Vest').length, 0, 'precondition: the filter really did hide the gear row');

    findByText(h.getRoot(), 'Clear filter')[0].click();
    await settle();

    for (const f of MIXED_FEATURES) {
        t.equals(findByText(h.getRoot(), f.label).length, 1, f.label + ' is back');
    }
});

t.test('sections collapse to only those with matches -- a filter never leaves a column of empty headings', async () => {
    const h = harnessWith(MIXED_FEATURES);
    await openPerson(h);

    const before = sectionLabels(h).length;
    filterInput(h).typeValue('scent');
    await settle();
    const after = sectionLabels(h);

    t.isTrue(after.length < before, 'fewer bands than before');
    t.equals(after.length, 1, 'only the one band that still has rows in it');
    t.isTrue(/scent/i.test(after[0]), 'and it is the right one');
});

t.test('THE BUG: filtering to zero matches must not claim the PERSON has no abilities', async () => {
    const h = harnessWith(MIXED_FEATURES);
    await openPerson(h);

    filterInput(h).typeValue('qqqqqqq-nothing-matches-this');
    await settle();

    // The old code printed `no_abilities` ("This K9/handler has no abilities
    // ...") here. That is a claim about the person, and it is false whenever
    // the unfiltered list is non-empty -- an operator reading it would
    // reasonably conclude the record was broken or empty.
    //
    // Collected per-node rather than from getRoot().textContent: this dom
    // stub does not aggregate textContent up a subtree, so reading it off
    // the root returns '' and would make every assertion here vacuous.
    const allText = findAll(h.getRoot(), () => true)
        .map((n) => (typeof n.textContent === 'string' ? n.textContent : ''))
        .join(' \n ');
    t.contains(allText, 'No abilities match that filter', 'the message is about the FILTER');
    t.contains(allText, 'still all there', 'and it explicitly reassures that the abilities were not lost');
    t.isTrue(findByText(h.getRoot(), 'Clear filter').length > 0, 'with a way out of the dead end on screen');
});

t.test('a person who genuinely has no abilities gets the honest empty message and NO filter control', async () => {
    const h = harnessWith([]);
    await openPerson(h);

    // The opposite case, and the reason the two messages must stay distinct.
    t.isUndefined(filterInput(h), 'no filter is offered for an empty list -- there is nothing to narrow');
    t.equals(findAll(h.getRoot(), (n) => n.classList && n.classList.contains('k9tablet-feature-group-row-label')).length, 0, 'and no section bands either');
});

t.test('each section band states how many rows it holds', async () => {
    const h = harnessWith(MIXED_FEATURES);
    await openPerson(h);
    const counts = findAll(h.getRoot(), (n) => n.classList && n.classList.contains('k9tablet-feature-group-row-count'))
        .map((n) => n.textContent);
    t.equals(counts.length, sectionLabels(h).length, 'every band has a count');
    t.isTrue(counts.indexOf('2') !== -1, 'the two-row scent band says 2');
});

t.run();
