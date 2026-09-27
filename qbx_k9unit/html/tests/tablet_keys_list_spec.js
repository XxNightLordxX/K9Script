/*
    html/tests/tablet_keys_list_spec.js

    YOUR KEYS -- the list of every key at the top of the Guide
    (html/tablet.js's buildKeysListSection()). The owner, verbatim: "do not
    remove keybinds just make a list".

    Pins:
      1. The list is there, first on the Guide, with the two gateway keys
         (the K9 menu and the third eye) and the real defaults -- Sit is G,
         not the V the Guide used to claim.
      2. A key for a feature this server has switched off is not listed.
*/
'use strict';

const t = require('./testkit');
const { createHarness, jsonResponse } = require('./tablet-sandbox');
const { findByText, findByClass } = require('./tablet-dom-stub');

function routeFetch(handlers) {
    return function (url, init) {
        const name = url.split('/').pop();
        const body = init && init.body ? JSON.parse(init.body) : undefined;
        const h = handlers[name];
        if (!h) return Promise.reject(new Error('tablet_keys_list_spec: unhandled NUI callback ' + name));
        return Promise.resolve(jsonResponse(h(body)));
    };
}

async function settle(times) {
    for (let i = 0; i < (times || 4); i++) await new Promise((r) => setImmediate(r));
}

const K9_VIEWER = { citizenid: 'DOG1', name: 'Rex', isHighCommand: false, effectivePermissions: ['k9.access'], allowSelfGrant: false };

function feature(key, state) { return { key: key, state: state }; }

async function openGuide(myFeatures) {
    const h = createHarness({
        fetchImpl: routeFetch({
            'tablet:requestMyRecord': () => ({ ok: true, viewer: K9_VIEWER, certifications: [], xp: null, tierLabel: null, myFeatures: myFeatures }),
        }),
    });
    h.postMessage('tablet:open', {});
    await settle();
    findByText(h.getRoot(), 'Guide')[0].click();
    await settle();
    return h;
}

function keyRows(h) {
    const list = findByClass(h.getRoot(), 'k9tablet-keys-list')[0];
    if (!list) return [];
    return list.children.map((li) => li.children[0].textContent + ' = ' + li.children[1].textContent);
}

const ALL_ON = ['RadialMenu', 'BasicBarkSounds', 'ScentVision', 'BiteAndHold', 'NonLethalTakedown', 'PropDragging', 'AgilityAdvanced', 'PursuitSprint', 'CameraFeedPiP', 'ThermalVision', 'NightVision']
    .map((k) => feature(k, 'available'));

t.test('the Guide opens with Your Keys: the K9 menu and third-eye keys first, then every ability key with its REAL default', async () => {
    const h = await openGuide(ALL_ON);

    t.equals(findByText(h.getRoot(), 'Your Keys').length, 1);
    const rows = keyRows(h);
    t.equals(rows[0], 'Z = Open your K9 menu -- every action is in here', 'the menu key comes first');
    t.equals(rows[1], 'Left Alt = Look at a person, vehicle or kennel to see what you can do with it');
    t.isTrue(rows.indexOf('G = Sit') !== -1, 'Sit is G -- the real default, not the V the Guide used to show');
    t.isTrue(rows.indexOf('U = Bark') !== -1);
    t.isTrue(rows.indexOf('[ = Take down a fleeing suspect') !== -1);
    t.isTrue(rows.indexOf('. = Scent vision on / off') !== -1);
    t.isTrue(rows.indexOf('B = Bite & hold / let go') !== -1);
    t.isTrue(rows.indexOf('I = Cycle vision: off, night, thermal') !== -1, 'the one vision key');
    for (const gone of ['O', 'K', 'J', 'H']) {
        t.equals(rows.filter((r) => r.indexOf(gone + ' = ') === 0).length, 0, gone + ' is no longer a K9 key (kennel exit, thermal, night and partner camera moved)');
    }
});

t.test('a key for a feature switched off on this server is not listed -- and nothing else goes with it', async () => {
    const withBiteOff = ALL_ON.map((f) => (f.key === 'BiteAndHold' ? feature('BiteAndHold', 'global_off') : f));
    const h = await openGuide(withBiteOff);

    const rows = keyRows(h);
    t.equals(rows.filter((r) => r.indexOf('Bite & hold') !== -1).length, 0, 'bite & hold is off here, so its key is not offered');
    t.isTrue(rows.indexOf('Y = Drag / let go') !== -1, 'the other combat keys are unaffected');
});

t.run();
