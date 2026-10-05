/*
    html/tests/tablet_server_settings_spec.js

    SERVER SETTINGS -- one admin tab with a row of sections at the top
    (html/tablet.js's SETTINGS_SECTIONS / buildSettingsSectionNav()). It
    replaced five tabs: Server Tuning, Tablet Theme, Catalogs, K9 Supply
    Shop and Runtime Control -- and Server Tuning was itself a Back/Next
    walk through three of the other four.

    What this pins:
      1. A viewer who may change no setting sees no trace of it.
      2. High command gets ONE tab; the old tab names are sections of it,
         and the Server Tuning flow (its heading, Next/Back) is gone.
      3. The tab lands on Runtime Control -- the most common job -- and
         after that on whichever section was last open.
      4. The Summary section still reports REAL, server-confirmed override
         counts (the `overridden` field the server sends), never a
         client-side change log.
      5. Each section is the same screen firing the same callback it did
         as a tab -- no new authorization path.
*/
'use strict';

const t = require('./testkit');
const { createHarness, jsonResponse } = require('./tablet-sandbox');
const { findByText, findByClass, openSettingsSection } = require('./tablet-dom-stub');

function routeFetch(handlers) {
    return function (url, init) {
        const name = url.split('/').pop();
        const body = init && init.body ? JSON.parse(init.body) : undefined;
        const h = handlers[name];
        if (!h) return Promise.reject(new Error('tablet_server_settings_spec: unhandled NUI callback ' + name));
        return Promise.resolve(jsonResponse(h(body)));
    };
}

async function settle(times) {
    for (let i = 0; i < (times || 4); i++) await new Promise((r) => setImmediate(r));
}

const HIGH_COMMAND_VIEWER = { citizenid: 'HC1', name: 'Chief', isHighCommand: true, effectivePermissions: ['k9.access', 'k9.certify', 'k9.audit', 'k9.givexp'], allowSelfGrant: false };
const CERTIFIER_ONLY_VIEWER = { citizenid: 'OFFICER1', name: 'Officer Rex', isHighCommand: false, effectivePermissions: ['k9.certify'], allowSelfGrant: false };

function baseHandlers(viewer, overrides) {
    return Object.assign({
        'tablet:requestMyRecord': () => ({ ok: true, viewer: viewer, certifications: [], xp: null, tierLabel: null, myFeatures: [] }),
        'tablet:requestRoster': () => ({ ok: true, rows: [], truncated: false }),
        'tablet:requestOnlinePlayers': () => ({ ok: true, rows: [], truncated: false }),
        'tablet:runtimeListFeatures': () => ({ ok: true, features: [] }),
        'tablet:runtimeListTunables': () => ({ ok: true, tunables: [] }),
        'tablet:certTiersList': () => ({ ok: true, tiers: [], capabilityCatalog: {} }),
        'tablet:permKeysList': () => ({ ok: true, keys: [] }),
        'tablet:xpTiersList': () => ({ ok: true, tiers: [] }),
        'tablet:equipmentShopItemsList': () => ({ ok: true, items: [] }),
        'tablet:equipmentShopGetLocations': () => ({ ok: true, locations: [] }),
        'tablet:getTheme': () => ({ ok: true, theme: { primaryColor: '#2563eb', accentColor: '#f59e0b', backgroundColor: '#111827', textColor: '#f9fafb', density: 'comfortable', headerTitle: 'K9 Command Tablet' } }),
    }, overrides || {});
}

async function openTablet(handlers) {
    const h = createHarness({ fetchImpl: routeFetch(handlers) });
    h.postMessage('tablet:open', { runtimeControlEnabled: true });
    await settle();
    return h;
}

function sectionLabels(h) {
    const nav = findByClass(h.getRoot(), 'k9tablet-settings-sections')[0];
    return nav ? nav.children.map((b) => b.textContent) : [];
}

t.test('a certified viewer who may change no server setting sees no Server Settings tab, and none of its sections', async () => {
    const h = await openTablet(baseHandlers(CERTIFIER_ONLY_VIEWER));
    for (const label of ['Server Settings', 'Runtime Control', 'Catalogs', 'K9 Supply Shop', 'Tablet Theme', 'Server Tuning']) {
        t.equals(findByText(h.getRoot(), label).length, 0, label + ' must not be offered');
    }
});

t.test('high command: ONE Server Settings tab; the old tab names are its sections, and the Server Tuning flow is gone', async () => {
    const h = await openTablet(baseHandlers(HIGH_COMMAND_VIEWER));

    t.equals(findByText(h.getRoot(), 'Server Settings').length, 1, 'one tab');
    for (const label of ['Runtime Control', 'Catalogs', 'K9 Supply Shop', 'Tablet Theme', 'Server Tuning']) {
        t.equals(findByText(h.getRoot(), label).length, 0, label + ' is not a tab of its own any more');
    }

    findByText(h.getRoot(), 'Server Settings')[0].click();
    await settle();

    t.equals(JSON.stringify(sectionLabels(h)), JSON.stringify(['Runtime Control', 'Catalogs', 'K9 Supply Shop', 'Tablet Theme', 'Summary']), 'every section, in order');
    t.isTrue(findByText(h.getRoot(), 'Runtime Feature Control').length >= 1, 'it lands on Runtime Control -- the most common job -- not on a summary');
    t.equals(findByText(h.getRoot(), 'Tune the Server').length, 0, 'no guided-flow heading');
    t.equals(findByText(h.getRoot(), 'Next').length, 0, 'no Next button');
    t.equals(findByText(h.getRoot(), 'Finish').length, 0, 'no Finish button');
});

t.test('the tab returns to whichever section was last open', async () => {
    const h = await openTablet(baseHandlers(HIGH_COMMAND_VIEWER));
    openSettingsSection(h.getRoot(), 'Tablet Theme');
    await settle();
    t.isTrue(findByText(h.getRoot(), 'Tablet Appearance').length >= 1);

    findByText(h.getRoot(), 'My Record')[0].click();
    await settle();
    findByText(h.getRoot(), 'Server Settings')[0].click();
    await settle();

    t.isTrue(findByText(h.getRoot(), 'Tablet Appearance').length >= 1, 'back on Tablet Theme, not reset to the first section');
});

t.test('Summary reports REAL, server-confirmed override counts, read from the `overridden` field the server sends', async () => {
    const h = await openTablet(baseHandlers(HIGH_COMMAND_VIEWER, {
        'tablet:runtimeListFeatures': () => ({
            ok: true,
            features: [
                { name: 'BiteAndHold', currentValue: true, configLuaDefault: true, tier: 'live', overridden: false, protected: false },
                { name: 'K9Leaderboard', currentValue: false, configLuaDefault: true, tier: 'live', overridden: true, overriddenBy: 'Chief', overriddenAt: '2026-01-01', protected: false },
            ],
        }),
        'tablet:xpTiersList': () => ({ ok: true, tiers: [{ ordinal: 1, xp: 0, label: 'Trainee', speedMultiplier: 1, scentRangeMultiplier: 1, xpLocked: true }] }),
    }));

    openSettingsSection(h.getRoot(), 'Summary');
    await settle(6);

    t.equals(findByText(h.getRoot(), '1 of 2 feature toggle(s) overridden from their config.lua default.').length, 1);
    t.equals(findByText(h.getRoot(), '1 XP rank(s) configured.').length, 1);
});

t.test('a section is the same screen firing the same callback it did as a tab -- toggling a feature from Runtime Control', async () => {
    const h = await openTablet(baseHandlers(HIGH_COMMAND_VIEWER, {
        'tablet:runtimeListFeatures': () => ({
            ok: true,
            features: [{ name: 'K9Leaderboard', currentValue: false, configLuaDefault: true, tier: 'live', overridden: true, overriddenBy: 'Chief', overriddenAt: '2026-01-01', protected: false }],
        }),
        'tablet:runtimeSetFeature': () => ({ ok: true, appliedLive: true, tier: 'live' }),
    }));

    openSettingsSection(h.getRoot(), 'Runtime Control');
    await settle();
    const enableBtn = findByText(h.getRoot(), 'Enable')[0];
    enableBtn.click(); // arm
    enableBtn.click(); // confirm
    await settle(6);

    t.isTrue(h.fetchCalls.some((c) => c.url.endsWith('tablet:runtimeSetFeature') && c.body.name === 'K9Leaderboard' && c.body.value === true), 'the identical tablet:runtimeSetFeature call and payload');
});

t.run();
