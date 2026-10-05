/*
    html/tests/tablet_certify_as_spec.js

    CERTIFY AS HANDLER OR AS K9 -- the Person screen's Certify button has a
    picker beside it: "Handler" (the default, looks stay the same) or a K9
    breed (certified AND turned into that dog, one step). Before this, every
    certify turned the person into the first configured dog, so a new
    handler got turned into a dog, and a K9 of a chosen breed took Certify
    plus a separate Assign K9 Role.

    What this pins, through the real tablet:certify payload:
      1. Handler is the default -- a straight click sends no k9Model.
      2. Picking a breed sends exactly that model.
      3. No models configured -> no picker, Certify still works as Handler.
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
        if (!h) return Promise.reject(new Error('tablet_certify_as_spec: unhandled NUI callback ' + name));
        return Promise.resolve(jsonResponse(h(body)));
    };
}

async function settle(times) {
    for (let i = 0; i < (times || 3); i++) await new Promise((r) => setImmediate(r));
}

const VIEWER = {
    citizenid: 'HC1', name: 'Chief', isHighCommand: true,
    effectivePermissions: ['k9.access', 'k9.certify', 'k9.audit', 'k9.givexp'],
    allowSelfGrant: false,
};

const PEDS = [
    { model: 'a_c_shepherd', label: 'German Shepherd' },
    { model: 'a_c_rottweiler' },
];

function handlers(certifyCalls) {
    return {
        'tablet:requestMyRecord': () => ({ ok: true, viewer: VIEWER, certifications: [], xp: null, tierLabel: null, myFeatures: [] }),
        'tablet:requestRoster': () => ({ ok: true, rows: [{ citizenid: 'TARGET1', name: 'Sam Newhire', departmentLabel: 'Police', certified: false, xp: 0, tierLabel: null }], truncated: false }),
        'tablet:requestOnlinePlayers': () => ({ ok: true, players: [], truncated: false }),
        'tablet:requestPersonSummary': () => ({
            ok: true,
            target: { citizenid: 'TARGET1', name: 'Sam Newhire', exists: true },
            certifications: [{ departmentKey: 'police', departmentLabel: 'Police', active: false, grantedBy: null }],
            xp: 0, tierLabel: null, permissions: [],
        }),
        'tablet:certify': (body) => { certifyCalls.push(body); return { ok: true }; },
    };
}

async function openPerson(peds) {
    const certifyCalls = [];
    const h = createHarness({ fetchImpl: routeFetch(handlers(certifyCalls)) });
    h.postMessage('tablet:open', { peds: peds });
    await settle();
    findByText(h.getRoot(), 'Command Console')[0].click();
    await settle();
    findByText(h.getRoot(), 'Manage')[0].click();
    await settle(4);
    return { h, certifyCalls };
}

function certifyAsSelect(h) {
    return findAll(h.getRoot(), (n) => n.tagName === 'select' && /k9tablet-certify-as-select/.test(n.className || ''))[0];
}

t.test('Handler is the default: the picker offers Handler first, then every breed, and a straight click certifies a handler (no k9Model sent)', async () => {
    const { h, certifyCalls } = await openPerson(PEDS);

    const select = certifyAsSelect(h);
    t.isDefined(select, 'a Certify-as picker sits beside Certify');
    t.equals(select.value, '', 'Handler is preselected');
    t.equals(findByText(h.getRoot(), 'Handler (looks stay the same)').length, 1);
    t.equals(findByText(h.getRoot(), 'K9: German Shepherd').length, 1, 'a configured label is used when there is one');
    t.equals(findByText(h.getRoot(), 'K9: a_c_rottweiler').length, 1, 'otherwise the model name');

    findByText(h.getRoot(), 'Certify')[0].click();
    await settle();

    t.equals(certifyCalls.length, 1);
    t.equals(certifyCalls[0].targetCitizenId, 'TARGET1');
    t.equals(certifyCalls[0].departmentKey, 'police');
    t.isUndefined(certifyCalls[0].k9Model, 'a handler certify carries no breed, so the server leaves their looks alone');
});

t.test('Picking a breed certifies them as the K9 of exactly that breed, in the same click', async () => {
    const { h, certifyCalls } = await openPerson(PEDS);

    const select = certifyAsSelect(h);
    select.value = 'a_c_rottweiler';
    select._dispatch('input', { target: select });
    findByText(h.getRoot(), 'Certify')[0].click();
    await settle();

    t.equals(certifyCalls.length, 1);
    t.equals(certifyCalls[0].k9Model, 'a_c_rottweiler');
});

t.test('No dog models configured: no picker, and Certify still certifies a handler', async () => {
    const { h, certifyCalls } = await openPerson([]);

    t.isUndefined(certifyAsSelect(h), 'nothing to choose from, so no picker');
    findByText(h.getRoot(), 'Certify')[0].click();
    await settle();

    t.equals(certifyCalls.length, 1);
    t.isUndefined(certifyCalls[0].k9Model);
});

t.run();
