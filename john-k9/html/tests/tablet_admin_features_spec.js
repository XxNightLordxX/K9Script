/*
    html/tests/tablet_admin_features_spec.js

    Covers the HIGH-COMMAND-ONLY surfaces added for the per-person feature
    control expansion (Config.FeatureControl): the four-capability
    grant/revoke section, and the per-person feature matrix with its two
    DELIBERATELY SEPARATE controls -- Block/Unblock (always offered, unless
    the feature is globally off) and Grant/Revoke (offered only when the
    feature is grant-gated) -- per config.lua's own "steps 2 and 3 are
    different things" instruction. Also covers the one absolute rule: a
    globally-disabled feature renders NO controls at all, never a button
    that would silently do nothing.
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
        if (!h) return Promise.reject(new Error('tablet_admin_features_spec: unhandled NUI callback ' + name));
        return Promise.resolve(jsonResponse(h(body)));
    };
}

const HIGH_COMMAND_VIEWER = { citizenid: 'HC1', name: 'Chief', isHighCommand: true, effectivePermissions: ['k9.access', 'k9.certify', 'k9.audit', 'k9.givexp'], allowSelfGrant: false };

async function settle(h, times) {
    for (let i = 0; i < (times || 2); i++) await new Promise((r) => setImmediate(r));
}

function baseHandlers(overrides) {
    return Object.assign({
        'tablet:requestMyRecord': () => ({ ok: true, viewer: HIGH_COMMAND_VIEWER, certifications: [], xp: null, tierLabel: null, myFeatures: [] }),
        'tablet:requestRoster': () => ({ ok: true, rows: [{ citizenid: 'TARGET1', name: 'K9 Rex', departmentLabel: 'Police', certified: true, xp: 500, tierLabel: 'Trained K9' }], truncated: false }),
        'tablet:requestPersonSummary': () => ({ ok: true, target: { citizenid: 'TARGET1', name: 'K9 Rex' }, certifications: [], xp: 500, tierLabel: 'Trained K9', permissions: ['k9.access'] }),
    }, overrides || {});
}

async function openPersonScreen(h) {
    h.postMessage('tablet:open', {});
    await settle(h);
    findByText(h.getRoot(), 'Command Console')[0].click();
    await settle(h);
    findByText(h.getRoot(), 'Manage')[0].click();
    await settle(h, 3);
}

function capabilityCheckboxes(h) {
    return findAll(h.getRoot(), (n) => n.classList && n.classList.contains('k9tablet-capability-checkbox'));
}

t.test('high command sees the Capabilities section with checkboxes matching held permissions', async () => {
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:requestPersonFeatures': () => ({ ok: true, target: { citizenid: 'TARGET1', name: 'K9 Rex' }, features: [] }),
        })),
    });
    await openPersonScreen(h);

    t.equals(findByText(h.getRoot(), 'Capabilities').length, 1);
    // k9.access is held -> checked; the other three are not held -> unchecked.
    const boxes = capabilityCheckboxes(h);
    t.equals(boxes.length, 4);
    t.equals(boxes.filter((b) => b.checked === true).length, 1, 'exactly one held capability (k9.access) is checked');
    t.equals(boxes.filter((b) => b.checked !== true).length, 3, 'the three un-held capabilities are unchecked');
});

t.test('ticking a capability checkbox fires tablet:grantPermission with the right key and target, then refreshes', async () => {
    let grantBody = null;
    let summaryCalls = 0;
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:requestPersonSummary': () => { summaryCalls++; return { ok: true, target: { citizenid: 'TARGET1', name: 'K9 Rex' }, certifications: [], xp: 500, tierLabel: 'Trained K9', permissions: ['k9.access'] }; },
            'tablet:requestPersonFeatures': () => ({ ok: true, target: { citizenid: 'TARGET1', name: 'K9 Rex' }, features: [] }),
            'tablet:grantPermission': (body) => { grantBody = body; return { ok: true }; },
        })),
    });
    await openPersonScreen(h);
    t.equals(summaryCalls, 1);

    const unheldCheckbox = capabilityCheckboxes(h).filter((b) => b.checked !== true)[0];
    unheldCheckbox.checked = true;
    unheldCheckbox._dispatch('change');
    await new Promise((r) => setTimeout(r, 30));

    t.equals(grantBody.targetCitizenId, 'TARGET1');
    t.isTrue(['k9.certify', 'k9.audit', 'k9.givexp'].indexOf(grantBody.permission) !== -1, 'one of the three un-held capability keys was granted');
    t.equals(summaryCalls, 2, 'person summary refreshed after granting');
});

t.test('a globally-disabled feature is not listed at all -- the strongest possible form of "no control that would silently do nothing"', async () => {
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:requestPersonFeatures': () => ({
                ok: true,
                target: { citizenid: 'TARGET1', name: 'K9 Rex' },
                features: [
                    { key: 'CameraFeedPiP', label: 'Camera Feed PiP', category: null, globallyEnabled: false, requiresGrant: false, granted: false, blocked: false, state: 'global_off' },
                ],
            }),
        })),
    });
    await openPersonScreen(h);

    // BEHAVIOUR CHANGED 2026-09-01 (owner: "if something is turned off in
    // the config nothing on the tablet shows up"). This used to assert the
    // row rendered with a 'Disabled server-wide' note and an empty actions
    // cell. The property it was really protecting -- never offer a control
    // that would silently do nothing -- is now satisfied outright: a
    // feature switched off server-wide is not grantable, blockable or
    // earnable, so it is dropped from this list entirely. See
    // withoutGloballyDisabled() in html/tablet.js. Runtime Control remains
    // the one screen that still shows off features, which is where they are
    // switched back on.
    t.equals(findByText(h.getRoot(), 'Camera Feed PiP').length, 0, 'the globally-off feature is not listed');
    t.equals(findByText(h.getRoot(), 'Disabled server-wide').length, 0, 'and there is no badge for it either -- the row is simply gone');

    // Scoped to the feature matrix's own actions cells -- the page ALSO
    // renders a Capabilities section with its own Grant buttons for the
    // three un-held admin capabilities, which is unrelated and must not be
    // confused with this feature row's (lack of) controls.
    const featureActionsCells = findAll(h.getRoot(), (n) => n.tagName === 'td' && n.classList && n.classList.contains('k9tablet-feature-actions'));
    t.equals(featureActionsCells.length, 0, 'no feature row, therefore no actions cell, therefore no control that could do nothing');
});

t.test('CONTROL: an ENABLED feature in the same position is still listed with its controls -- hiding is scoped to off, not to everything', async () => {
    // Without this, the test above would pass just as well against a change
    // that broke the abilities table entirely.
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:requestPersonFeatures': () => ({
                ok: true,
                target: { citizenid: 'TARGET1', name: 'K9 Rex' },
                features: [
                    { key: 'CameraFeedPiP', label: 'Camera Feed PiP', category: null, globallyEnabled: true, requiresGrant: false, granted: false, blocked: false, state: 'available' },
                ],
            }),
        })),
    });
    await openPersonScreen(h);

    t.isTrue(findByText(h.getRoot(), 'Camera Feed PiP').length >= 1, 'an on feature is listed');
    const featureActionsCells = findAll(h.getRoot(), (n) => n.tagName === 'td' && n.classList && n.classList.contains('k9tablet-feature-actions'));
    t.equals(featureActionsCells.length, 1, 'with its actions cell');
});

t.test('Block and Grant/Revoke are two INDEPENDENT controls on the same feature row -- Block is offered even when the feature is allowed by default (no grant needed)', async () => {
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:requestPersonFeatures': () => ({
                ok: true,
                target: { citizenid: 'TARGET1', name: 'K9 Rex' },
                features: [
                    { key: 'ScentTracking', label: 'Scent Tracking', category: 'Tracking', globallyEnabled: true, requiresGrant: false, granted: false, blocked: false, state: 'available' },
                ],
            }),
        })),
    });
    await openPersonScreen(h);

    t.equals(findByText(h.getRoot(), 'Block').length, 1, 'Block is offered for an allowed-by-default feature -- "block this" is the correct action here, not a greyed-out Revoke');
    // No grant/revoke control for a non-grant-gated feature's OWN row.
    const featureTableActionsCells = findAll(h.getRoot(), (n) => n.tagName === 'td' && n.classList && n.classList.contains('k9tablet-feature-actions'));
    t.equals(featureTableActionsCells.length, 1);
    t.equals(findByText(featureTableActionsCells[0], 'Grant').length, 0, 'requiresGrant=false -> no grant/revoke toggle on this row');
});

t.test('a grant-required feature shows BOTH Block and Grant as separate controls when not yet granted', async () => {
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:requestPersonFeatures': () => ({
                ok: true,
                target: { citizenid: 'TARGET1', name: 'K9 Rex' },
                features: [
                    { key: 'BiteAndHold', label: 'Bite and Hold', category: 'Combat', globallyEnabled: true, requiresGrant: true, granted: false, blocked: false, state: 'requires_grant_missing' },
                ],
            }),
        })),
    });
    await openPersonScreen(h);

    const featureActionsCells = findAll(h.getRoot(), (n) => n.tagName === 'td' && n.classList && n.classList.contains('k9tablet-feature-actions'));
    t.equals(featureActionsCells.length, 1);
    t.equals(findByText(featureActionsCells[0], 'Block').length, 1);
    t.equals(findByText(featureActionsCells[0], 'Grant').length, 1);
    t.equals(findByText(h.getRoot(), 'Requires a grant (not granted)').length, 1);
});

t.test('blocking a feature fires tablet:blockFeature after a confirm click, then refreshes the feature list', async () => {
    let blockCalls = 0;
    let featuresCalls = 0;
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:requestPersonFeatures': () => {
                featuresCalls++;
                return {
                    ok: true,
                    target: { citizenid: 'TARGET1', name: 'K9 Rex' },
                    features: [{ key: 'ScentTracking', label: 'Scent Tracking', category: 'Tracking', globallyEnabled: true, requiresGrant: false, granted: false, blocked: false, state: 'available' }],
                };
            },
            'tablet:blockFeature': () => { blockCalls++; return { ok: true }; },
        })),
    });
    await openPersonScreen(h);
    t.equals(featuresCalls, 1);

    const blockBtn = findByText(h.getRoot(), 'Block')[0];
    blockBtn.click();
    t.equals(blockCalls, 0, 'first click only arms the confirmation');
    blockBtn.click();
    await new Promise((r) => setTimeout(r, 30));
    t.equals(blockCalls, 1);
    t.equals(featuresCalls, 2, 'feature list re-fetched after blocking');
});

t.test('the search box over the feature matrix filters client-side by label/key/category', async () => {
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:requestPersonFeatures': () => ({
                ok: true,
                target: { citizenid: 'TARGET1', name: 'K9 Rex' },
                features: [
                    { key: 'ScentTracking', label: 'Scent Tracking', category: 'Tracking', globallyEnabled: true, requiresGrant: false, granted: false, blocked: false, state: 'available' },
                    { key: 'BiteAndHold', label: 'Bite and Hold', category: 'Combat', globallyEnabled: true, requiresGrant: true, granted: false, blocked: false, state: 'requires_grant_missing' },
                ],
            }),
        })),
    });
    await openPersonScreen(h);
    t.isTrue(findByText(h.getRoot(), 'Scent Tracking').length >= 1);
    t.isTrue(findByText(h.getRoot(), 'Bite and Hold').length >= 1);

    const searchInputs = findAll(h.getRoot(), (n) => n.tagName === 'input' && n.getAttribute('placeholder') === 'Search abilities...');
    t.equals(searchInputs.length, 1);
    searchInputs[0].typeValue('bite');

    t.equals(findByText(h.getRoot(), 'Bite and Hold').length, 1, 'matching row still present');
    t.equals(findByText(h.getRoot(), 'Scent Tracking').length, 0, 'non-matching row filtered out client-side, no new fetch needed');
});

t.run();
