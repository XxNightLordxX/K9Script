/*
    html/tests/tablet_certification_granter_name_spec.js

    Covers buildCertificationRow()'s use of `grantedByName` -- coder-backend's
    additive display-name sibling for `grantedBy` on server/tablet.lua's
    BuildCertificationsArray rows (readability pass: "Certified by: Jane
    Handler" instead of a raw citizenid on the person screen). `grantedBy`
    itself is never replaced -- this only changes what TEXT is rendered for
    it, and falls back to the raw citizenid exactly as before when no name
    is present, so every pre-existing caller that never sends
    `grantedByName` keeps its old behavior unchanged.
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
        if (!h) return Promise.reject(new Error('tablet_certification_granter_name_spec: unhandled NUI callback ' + name));
        return Promise.resolve(jsonResponse(h(body)));
    };
}

const HIGH_COMMAND_VIEWER = { citizenid: 'HC1', name: 'Chief', isHighCommand: true, effectivePermissions: ['k9.access', 'k9.certify', 'k9.audit', 'k9.givexp'], allowSelfGrant: false };

async function settle(times) {
    for (let i = 0; i < (times || 3); i++) await new Promise((r) => setImmediate(r));
}

function baseHandlers(overrides) {
    return Object.assign({
        'tablet:requestMyRecord': () => ({ ok: true, viewer: HIGH_COMMAND_VIEWER, certifications: [], xp: null, tierLabel: null, myFeatures: [] }),
        'tablet:requestRoster': () => ({ ok: true, rows: [{ citizenid: 'TARGET1', name: 'K9 Rex', departmentLabel: 'Police', certified: true, xp: 500, tierLabel: 'Trained K9' }], truncated: false }),
        'tablet:requestPersonFeatures': () => ({ ok: true, target: { citizenid: 'TARGET1', name: 'K9 Rex' }, features: [] }),
    }, overrides || {});
}

async function openPersonScreen(h) {
    h.postMessage('tablet:open', {});
    await settle();
    findByText(h.getRoot(), 'Command Console')[0].click();
    await settle();
    findByText(h.getRoot(), 'Manage')[0].click();
    await settle(4);
}

t.test('a grantedByName sibling is shown instead of the raw grantedBy citizenid', async () => {
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:requestPersonSummary': () => ({
                ok: true, target: { citizenid: 'TARGET1', name: 'K9 Rex' },
                certifications: [{ departmentKey: 'police', departmentLabel: 'Los Santos Police Department', active: true, grantedBy: 'GRANTER1', grantedByName: 'Sergeant Alice', tier: null, expiresAtUnix: null, expired: false, specializations: [] }],
                xp: 500, tierLabel: 'Trained K9', permissions: [],
            }),
        })),
    });
    await openPersonScreen(h);

    t.equals(findByText(h.getRoot(), 'Sergeant Alice').length, 1, 'the resolved name is shown');
    t.equals(findByText(h.getRoot(), 'GRANTER1').length, 0, 'the raw citizenid is not shown when a name is available');
});

t.test('missing grantedByName falls back to the raw grantedBy citizenid unchanged', async () => {
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:requestPersonSummary': () => ({
                ok: true, target: { citizenid: 'TARGET1', name: 'K9 Rex' },
                certifications: [{ departmentKey: 'police', departmentLabel: 'Los Santos Police Department', active: true, grantedBy: 'GRANTER1', tier: null, expiresAtUnix: null, expired: false, specializations: [] }],
                xp: 500, tierLabel: 'Trained K9', permissions: [],
            }),
        })),
    });
    await openPersonScreen(h);

    t.equals(findByText(h.getRoot(), 'GRANTER1').length, 1, 'falls back to the raw citizenid exactly as before this pass');
});

t.test('a hostile grantedByName reaches the DOM only via textContent, never innerHTML', async () => {
    const malicious = '<img src=x onerror="window.__xss_pwned=true">';
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:requestPersonSummary': () => ({
                ok: true, target: { citizenid: 'TARGET1', name: 'K9 Rex' },
                certifications: [{ departmentKey: 'police', departmentLabel: 'Los Santos Police Department', active: true, grantedBy: 'GRANTER1', grantedByName: malicious, tier: null, expiresAtUnix: null, expired: false, specializations: [] }],
                xp: 500, tierLabel: 'Trained K9', permissions: [],
            }),
        })),
    });
    await openPersonScreen(h);

    const matches = findAll(h.getRoot(), (n) => n._textContent === malicious);
    t.isTrue(matches.length >= 1, 'the malicious grantedByName reaches the DOM verbatim as textContent');

    const innerHTMLWrites = findAll(h.getRoot(), () => true).reduce((sum, el) => sum + (el.innerHTMLWriteCount || 0), 0);
    t.equals(innerHTMLWrites, 0, 'innerHTML must never be written anywhere on this page for a malicious grantedByName');
});

t.run();
