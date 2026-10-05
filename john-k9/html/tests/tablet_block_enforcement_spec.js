/*
    html/tests/tablet_block_enforcement_spec.js

    Covers featureBlockEnforcement()/buildPersonFeatureRow()'s Block Effect
    column -- the fix for the owner's headline finding this pass: clicking
    Block on most Config.Features entries wrote a permanent k9_permissions
    row and rendered "Blocked" while changing nothing in-game, because
    server/tablet.lua's own `blocked`/`state` fields have never told the
    operator whether ANY feature-owning server file actually reads
    `block.<key>` before permitting the ability.

    This page never hardcodes which features honour a block (see
    featureBlockEnforcement()'s own doc comment in html/tablet.js) --
    everything here is driven entirely by the `blockEnforcement` field this
    test's own fixtures supply, exactly the way the real server response
    will once server/tablet.lua exposes it (requested, not yet landed --
    see this file's own PersonFeaturesResult doc comment). The FALLBACK
    path (field absent/unrecognized -> 'not_yet_enforced') is what a real,
    not-yet-updated server response looks like today, and is covered
    explicitly below so that gap can never silently regress into an
    over-claim of 'enforced'.
*/
'use strict';

const t = require('./testkit');
const { createHarness, jsonResponse } = require('./tablet-sandbox');
const { findByText, findAll, findByClass } = require('./tablet-dom-stub');

function routeFetch(handlers) {
    return function (url, init) {
        const name = url.split('/').pop();
        const body = init && init.body ? JSON.parse(init.body) : undefined;
        const h = handlers[name];
        if (!h) return Promise.reject(new Error('tablet_block_enforcement_spec: unhandled NUI callback ' + name));
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

function featureActionsCell(h) {
    const cells = findAll(h.getRoot(), (n) => n.tagName === 'td' && n.classList && n.classList.contains('k9tablet-feature-actions'));
    t.equals(cells.length, 1);
    return cells[0];
}

t.test('blockEnforcement "enforced" shows the Enforced badge and still offers Block', async () => {
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:requestPersonFeatures': () => ({
                ok: true,
                target: { citizenid: 'TARGET1', name: 'K9 Rex' },
                features: [
                    { key: 'K9Medkit', label: 'K9 Medkit', category: null, globallyEnabled: true, requiresGrant: false, granted: false, blocked: false, state: 'available', blockEnforcement: 'enforced' },
                ],
            }),
        })),
    });
    await openPersonScreen(h);

    t.equals(findByText(h.getRoot(), 'Enforced').length, 1);
    t.equals(findByText(featureActionsCell(h), 'Block').length, 1, 'Block is still offered when it actually works');
});

t.test('blockEnforcement "not_yet_enforced" shows a warning badge (with an explanatory title) and STILL offers Block -- the control is real, just not wired in-game yet', async () => {
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:requestPersonFeatures': () => ({
                ok: true,
                target: { citizenid: 'TARGET1', name: 'K9 Rex' },
                features: [
                    { key: 'DoorInteraction', label: 'Door Interaction', category: null, globallyEnabled: true, requiresGrant: false, granted: false, blocked: false, state: 'available', blockEnforcement: 'not_yet_enforced' },
                ],
            }),
        })),
    });
    await openPersonScreen(h);

    const badge = findByText(h.getRoot(), 'Not enforced yet');
    t.equals(badge.length, 1);
    t.isTrue(badge[0].getAttribute('title').length > 0, 'the badge carries an explanatory tooltip, not just a bare label');
    t.equals(findByText(featureActionsCell(h), 'Block').length, 1, 'the control is not hidden -- it can be wired to work later, and clicking it now is harmless');
});

t.test('an ABSENT blockEnforcement field (an older/not-yet-updated server response) falls back to "not_yet_enforced" -- never silently claims a block works', async () => {
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

    t.equals(findByText(h.getRoot(), 'Not enforced yet').length, 1, 'missing field -> safe default, never "Enforced"');
    t.equals(findByText(h.getRoot(), 'Enforced').length, 0);
});

t.test('an unrecognized blockEnforcement string also falls back safely to "not_yet_enforced"', async () => {
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:requestPersonFeatures': () => ({
                ok: true,
                target: { citizenid: 'TARGET1', name: 'K9 Rex' },
                features: [
                    { key: 'SomeNewFeature', label: 'Some New Feature', category: null, globallyEnabled: true, requiresGrant: false, granted: false, blocked: false, state: 'available', blockEnforcement: 'something_unexpected' },
                ],
            }),
        })),
    });
    await openPersonScreen(h);

    t.equals(findByText(h.getRoot(), 'Not enforced yet').length, 1);
});

t.test('blockEnforcement "not_enforceable" HIDES the Block/Unblock control entirely and shows the explanatory note instead -- offering a control that can never work is the exact dishonesty this exists to remove', async () => {
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:requestPersonFeatures': () => ({
                ok: true,
                target: { citizenid: 'TARGET1', name: 'K9 Rex' },
                features: [
                    { key: 'ThermalVision', label: 'Thermal Vision', category: null, globallyEnabled: true, requiresGrant: false, granted: false, blocked: false, state: 'available', blockEnforcement: 'not_enforceable' },
                ],
            }),
        })),
    });
    await openPersonScreen(h);

    const actionsCell = featureActionsCell(h);
    t.equals(findByText(actionsCell, 'Block').length, 0, 'no Block button');
    t.equals(findByText(actionsCell, 'Unblock').length, 0, 'no Unblock button either');
    t.isTrue(findByClass(h.getRoot(), 'k9tablet-block-badge--unavailable').length === 1, 'the not-enforceable note is rendered in its own Block Effect cell');
});

t.test('blockEnforcement "not_enforceable" still allows Grant/Revoke -- hiding Block must not hide the UNRELATED grant control on the same row', async () => {
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:requestPersonFeatures': () => ({
                ok: true,
                target: { citizenid: 'TARGET1', name: 'K9 Rex' },
                features: [
                    { key: 'SomeGrantGatedButUnenforceableFeature', label: 'Odd Feature', category: null, globallyEnabled: true, requiresGrant: true, granted: false, blocked: false, state: 'requires_grant_missing', blockEnforcement: 'not_enforceable' },
                ],
            }),
        })),
    });
    await openPersonScreen(h);

    const actionsCell = featureActionsCell(h);
    t.equals(findByText(actionsCell, 'Block').length, 0);
    t.equals(findByText(actionsCell, 'Grant').length, 1, 'Grant/Revoke is a separate, independent control and still renders');
});

t.test('a feature that already has a stored block row (feature.blocked=true) but is not_enforceable shows Unblock nowhere -- the row is still visible via its state badge, but no dead control is offered', async () => {
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:requestPersonFeatures': () => ({
                ok: true,
                target: { citizenid: 'TARGET1', name: 'K9 Rex' },
                features: [
                    { key: 'NightVision', label: 'Night Vision', category: null, globallyEnabled: true, requiresGrant: false, granted: false, blocked: true, state: 'blocked', blockEnforcement: 'not_enforceable' },
                ],
            }),
        })),
    });
    await openPersonScreen(h);

    const actionsCell = featureActionsCell(h);
    t.equals(findByText(actionsCell, 'Unblock').length, 0);
    t.equals(findByText(actionsCell, 'Block').length, 0);
    // The state column still honestly reports the stored row exists.
    t.equals(findByText(h.getRoot(), 'Blocked').length, 1);
});

t.test('a globally-disabled feature renders no row at all, so no Block Effect cell and no block badge', async () => {
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:requestPersonFeatures': () => ({
                ok: true,
                target: { citizenid: 'TARGET1', name: 'K9 Rex' },
                features: [
                    { key: 'CameraFeedPiP', label: 'Camera Feed PiP', category: null, globallyEnabled: false, requiresGrant: false, granted: false, blocked: false, state: 'global_off', blockEnforcement: 'not_enforceable' },
                ],
            }),
        })),
    });
    await openPersonScreen(h);

    // BEHAVIOUR CHANGED 2026-09-01 (owner: "if something is turned off in
    // the config nothing on the tablet shows up"). This used to assert one
    // blank Block Effect cell, to prove the column count stayed consistent
    // for a globally-off row. There is no such row any more --
    // withoutGloballyDisabled() drops it before the table is built -- so
    // column consistency is moot here and is covered by every other row in
    // this file. What still matters, and is asserted, is that nothing about
    // a switched-off feature leaks onto this screen.
    t.equals(findByClass(h.getRoot(), 'k9tablet-block-effect').length, 0, 'no Block Effect cell -- there is no row');
    t.equals(findByClass(h.getRoot(), 'k9tablet-block-badge').length, 0, 'and no badge either');
    t.equals(findByText(h.getRoot(), 'Camera Feed PiP').length, 0, 'the feature is not named anywhere on the screen');
});

t.test('CONTROL: the same feature ENABLED does render its Block Effect cell -- the row machinery is intact, only off features are dropped', async () => {
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:requestPersonFeatures': () => ({
                ok: true,
                target: { citizenid: 'TARGET1', name: 'K9 Rex' },
                features: [
                    { key: 'CameraFeedPiP', label: 'Camera Feed PiP', category: null, globallyEnabled: true, requiresGrant: false, granted: false, blocked: false, state: 'available', blockEnforcement: 'not_enforceable' },
                ],
            }),
        })),
    });
    await openPersonScreen(h);

    t.equals(findByClass(h.getRoot(), 'k9tablet-block-effect').length, 1, 'one Block Effect cell for the one on feature');
    t.isTrue(findByText(h.getRoot(), 'Camera Feed PiP').length >= 1, 'and the feature is listed');
});

t.run();
