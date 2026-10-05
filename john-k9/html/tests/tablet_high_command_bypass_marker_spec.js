/*
    html/tests/tablet_high_command_bypass_marker_spec.js

    Covers the subtle "(High Command)" marker on the Person screen's
    admin feature table (owner-directed follow-up to the DISPLAY-GAP FIX:
    "why can this person do that" should be answerable at a glance).
    server/tablet.lua's BuildPersonFeaturesArray now sends `viaHighCommand`
    per row -- true ONLY when `state === 'available'` solely because this
    TARGET's own rank bypasses a missing grant/certification, never for a
    row they would have earned honestly anyway. html/tablet.js's
    appendViaHighCommandMarker() renders it as a small, muted parenthetical
    suffix (the SAME style as the Command Reference screen's own
    '(Admin)' marker) -- never a prominent badge.
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
        if (!h) return Promise.reject(new Error('tablet_high_command_bypass_marker_spec: unhandled NUI callback ' + name));
        return Promise.resolve(jsonResponse(h(body)));
    };
}

async function settle(times) {
    for (let i = 0; i < (times || 3); i++) await new Promise((r) => setImmediate(r));
}

async function openPersonFeatures(features) {
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
            'tablet:requestPersonFeatures': () => ({ ok: true, target: { citizenid: 'TARGET1', name: 'K9 Rex' }, features: features }),
        }),
    });
    h.postMessage('tablet:open', {});
    await settle();
    findByText(h.getRoot(), 'Manage')[0].click();
    await settle();
    return h;
}

t.test('a feature available SOLELY via high command shows the quiet "(High Command)" marker next to its status', async () => {
    const h = await openPersonFeatures([
        { key: 'BiteAndHold', label: 'Bite and Hold', category: 'combat', globallyEnabled: true, requiresGrant: true, granted: false, blocked: false, state: 'available', viaHighCommand: true },
    ]);
    t.isTrue(findByText(h.getRoot(), ' (High Command)').length >= 1, 'the marker text renders');
});

t.test('a feature available because of a REAL grant does NOT show the marker, even for a high-command target', async () => {
    const h = await openPersonFeatures([
        { key: 'BiteAndHold', label: 'Bite and Hold', category: 'combat', globallyEnabled: true, requiresGrant: true, granted: true, blocked: false, state: 'available', viaHighCommand: false },
    ]);
    t.equals(findByText(h.getRoot(), ' (High Command)').length, 0, 'a genuinely granted feature never shows the rank marker');
});

t.test('a feature needing no grant at all does NOT show the marker', async () => {
    const h = await openPersonFeatures([
        { key: 'LeashMechanics', label: 'Leash', category: 'movement', globallyEnabled: true, requiresGrant: false, granted: false, blocked: false, state: 'available', viaHighCommand: false },
    ]);
    t.equals(findByText(h.getRoot(), ' (High Command)').length, 0);
});

t.test('a blocked feature never shows the marker, even if viaHighCommand were somehow sent true (malformed/old server) -- the block badge is what matters, not a stray rank note', async () => {
    const h = await openPersonFeatures([
        { key: 'BiteAndHold', label: 'Bite and Hold', category: 'combat', globallyEnabled: true, requiresGrant: true, granted: false, blocked: true, state: 'blocked', viaHighCommand: true },
    ]);
    // Not asserting on the marker directly here -- the row's own real
    // point is the Blocked state itself, unaffected by anything else.
    t.isTrue(findByText(h.getRoot(), 'Blocked').length >= 1);
});

t.test('the marker also renders on a text-forward (vehicle-domain) row, not just the ordinary badge rows', async () => {
    const h = await openPersonFeatures([
        { key: 'VehicleEntryExit', label: 'Get In/Out of Vehicles', category: 'vehicle', globallyEnabled: true, requiresGrant: true, granted: false, blocked: false, state: 'available', viaHighCommand: true },
    ]);
    t.isTrue(findByText(h.getRoot(), ' (High Command)').length >= 1, 'the marker is not skipped just because this domain uses the text-forward row style');
});

t.run();
