/*
    html/tests/tablet_person_layout_spec.js

    PERSON SCREEN LAYOUT (the owner's rework pass): the everyday sections
    first -- Certifications, then K9 Role (Assign / Revert to Human, which
    used to be at the very bottom), XP, Partnership, Rank -- and the three
    rarely used, long sections (special permissions, per-person ability
    switches, individual K9 overrides) folded away behind their headings.

    Pins:
      1. The section order.
      2. The foldouts are closed by default but their controls are really
         there (one click away, not removed).
      3. A foldout left open stays open when the screen re-renders -- every
         action re-renders it, so without this it would snap shut after
         every checkbox tick.
*/
'use strict';

const t = require('./testkit');
const { createHarness, jsonResponse } = require('./tablet-sandbox');
const { findByText, findAll } = require('./tablet-dom-stub');

async function settle(times) {
    for (let i = 0; i < (times || 8); i++) await new Promise((r) => setImmediate(r));
}

const VIEWER = { citizenid: 'HC1', name: 'Chief', isHighCommand: true, effectivePermissions: ['k9.access', 'k9.certify', 'k9.audit', 'k9.givexp'], allowSelfGrant: false };

const HANDLERS = {
    'tablet:requestMyRecord': () => ({ ok: true, viewer: VIEWER, certifications: [], xp: null, tierLabel: null, myFeatures: [] }),
    'tablet:requestRoster': () => ({ ok: true, rows: [{ citizenid: 'DOG1', name: 'Rex Dog', departmentLabel: 'Police', certified: true, xp: 120, tierLabel: 'Trainee' }], truncated: false }),
    'tablet:requestPersonSummary': () => ({
        ok: true, target: { citizenid: 'DOG1', name: 'Rex Dog', exists: true },
        job: { departmentLabel: 'Police', gradeLabel: 'Officer', gradeLevel: 1 },
        certifications: [{ departmentKey: 'police', departmentLabel: 'Police', active: false, grantedBy: null }],
        xp: 120, tierLabel: 'Trainee', handlerXp: 0, partnership: null, permissions: [],
    }),
};

async function openPerson() {
    const h = createHarness({
        fetchImpl: (url, init) => {
            const name = url.split('/').pop();
            const body = init && init.body ? JSON.parse(init.body) : {};
            const handler = HANDLERS[name];
            return Promise.resolve(jsonResponse(handler ? handler(body) : { ok: true }));
        },
    });
    h.postMessage('tablet:open', { peds: [{ model: 'a_c_shepherd' }] });
    await settle();
    findByText(h.getRoot(), 'Command Console')[0].click();
    await settle();
    findByText(h.getRoot(), 'Manage')[0].click();
    await settle();
    return h;
}

function headingOrder(h) {
    return findAll(h.getRoot(), (n) => (n.tagName === 'h3' || n.tagName === 'summary') && /k9tablet-section-heading/.test(n.className || ''))
        .map((n) => n.textContent);
}

function foldouts(h) {
    return findAll(h.getRoot(), (n) => n.tagName === 'details');
}

t.test('everyday sections come first: Certifications, then K9 Role, then XP, Partnership and Rank; the long admin sections come last', async () => {
    const h = await openPerson();
    const order = headingOrder(h);
    const at = (label) => order.indexOf(label);

    t.equals(at('Certifications'), 0);
    t.equals(at('K9 Role'), 1, 'Assign K9 Role / Revert to Human sit right under Certifications');
    t.isTrue(at('K9 XP') > at('K9 Role'));
    t.isTrue(at('Partnership') > at('K9 XP'));
    t.isTrue(at('Rank') > at('Partnership'));
    for (const advanced of ['Capabilities', 'Abilities', 'K9 Individual Override']) {
        t.isTrue(at(advanced) > at('Rank'), advanced + ' comes after the everyday sections');
    }
});

t.test('the three long admin sections are folded away, closed by default -- and their controls are really there, one click away', async () => {
    const h = await openPerson();
    const folds = foldouts(h);
    t.equals(folds.length, 3);
    for (const d of folds) t.isFalse(d.hasAttribute('open'), 'closed by default');
    t.isTrue(findByText(h.getRoot(), 'Revert to Human').length >= 1, 'the emergency revert is NOT folded away');
    t.isTrue(findByText(h.getRoot(), 'Save Override').length >= 1, 'the override form still exists inside its foldout');
});

t.test('a foldout left open stays open after the screen re-renders', async () => {
    const h = await openPerson();
    const capabilities = foldouts(h)[0];
    capabilities.open = true;
    capabilities._dispatch('toggle');

    // Leaving and coming back re-renders the whole screen from scratch.
    findByText(h.getRoot(), 'My Record')[0].click();
    await settle();
    findByText(h.getRoot(), 'Command Console')[0].click();
    await settle();
    findByText(h.getRoot(), 'Manage')[0].click();
    await settle();

    const again = foldouts(h);
    t.isTrue(again[0].hasAttribute('open'), 'the section left open is still open');
    t.isFalse(again[1].hasAttribute('open'), 'the others stay closed');
});

t.run();
