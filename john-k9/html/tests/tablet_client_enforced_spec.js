/*
    html/tests/tablet_client_enforced_spec.js

    Covers the FOURTH `blockEnforcement` state, 'client_enforced' -- see
    server/tablet.lua's own "BLOCK ENFORCEMENT CLASSIFICATION" section and
    html/tablet.js's own PersonFeaturesResult doc comment for the full
    four-state contract this file exercises.

    THE BUG THIS STATE FIXES: twelve client-only features
    (client/featureblocks.lua) now have a REAL, WORKING per-person block,
    enforced by the PLAYER'S OWN CLIENT -- but before this state existed,
    html/tablet.js's featureBlockEnforcement() only allow-listed 'enforced'
    and 'not_enforceable', so these twelve fell through to the
    'not_yet_enforced' fallback ("Not enforced yet"), telling an operator a
    working block does nothing. This is the INVERSE of the usual
    dishonest-badge bug (claiming a block works when it does not) and is
    just as costly: it discourages an operator from using a control that
    genuinely works, just more weakly than a server-side block.

    Sibling file html/tests/tablet_block_enforcement_spec.js covers
    'enforced'/'not_enforceable'/'not_yet_enforced' (including the
    fallback-on-absent/unrecognized-value cases) -- not repeated here.
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
        if (!h) return Promise.reject(new Error('tablet_client_enforced_spec: unhandled NUI callback ' + name));
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

/** @param {object} h @param {object} [openData] -- forwarded verbatim as tablet:open's `data` */
async function openPersonScreen(h, openData) {
    h.postMessage('tablet:open', openData || {});
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

function personFeaturesHandlers(feature) {
    return baseHandlers({
        'tablet:requestPersonFeatures': () => ({
            ok: true,
            target: { citizenid: 'TARGET1', name: 'K9 Rex' },
            features: [feature],
        }),
    });
}

const THERMAL_VISION_FEATURE = {
    key: 'ThermalVision', label: 'Thermal Vision', category: null,
    globallyEnabled: true, requiresGrant: false, granted: false, blocked: false,
    state: 'available', blockEnforcement: 'client_enforced',
};

t.test('blockEnforcement "client_enforced": renders the server-sent client-enforced badge text (NOT the generic "Enforced" or "Not enforced yet" text)', async () => {
    const h = createHarness({ fetchImpl: routeFetch(personFeaturesHandlers(THERMAL_VISION_FEATURE)) });
    await openPersonScreen(h, {
        strings: {
            block_client_enforced_badge: 'Enforced (client-side)',
            block_client_enforced_hint: "Blocking this stops the ability on the player's own game client. Unlike a server-enforced block, a modified or cheating client can bypass it -- treat this as best-effort, not a guarantee.",
        },
    });

    t.equals(findByText(h.getRoot(), 'Enforced (client-side)').length, 1, 'the client-enforced badge text is rendered');
    t.equals(findByText(h.getRoot(), 'Not enforced yet').length, 0, 'must never fall through to the generic not-yet-enforced text');
    t.equals(findAll(h.getRoot(), (n) => n.classList && n.classList.contains('k9tablet-block-badge') && !n.classList.contains('k9tablet-block-badge--client_enforced')).length, 0, 'no OTHER block-badge variant class is used for this row');
});

t.test('blockEnforcement "client_enforced": the badge carries the server-sent hint as its title, and Block is still offered -- the control genuinely works, just client-side only', async () => {
    const h = createHarness({ fetchImpl: routeFetch(personFeaturesHandlers(THERMAL_VISION_FEATURE)) });
    await openPersonScreen(h, {
        strings: {
            block_client_enforced_badge: 'Enforced (client-side)',
            block_client_enforced_hint: 'A modified client can bypass this -- best-effort only.',
        },
    });

    const badge = findByText(h.getRoot(), 'Enforced (client-side)');
    t.equals(badge.length, 1);
    t.equals(badge[0].getAttribute('title'), 'A modified client can bypass this -- best-effort only.');
    t.equals(findByText(featureActionsCell(h), 'Block').length, 1, 'Block is still offered -- this is a working control, unlike not_enforceable');
});

t.test('blockEnforcement "client_enforced": with NO block_client_enforced_badge/_hint in `strings` (an older locales/en.json, or a locale() failure), the page falls back to its own hardcoded English text via S() -- never a raw key, never blank', async () => {
    const h = createHarness({ fetchImpl: routeFetch(personFeaturesHandlers(THERMAL_VISION_FEATURE)) });
    await openPersonScreen(h, {}); // no `strings` at all -- S() falls through to DEFAULT_STRINGS

    const badge = findByText(h.getRoot(), 'Enforced (client-side)');
    t.equals(badge.length, 1, 'falls back to the hardcoded English badge text');
    t.isTrue(badge[0].getAttribute('title').length > 0, 'falls back to the hardcoded English hint text as the tooltip, not a blank title');
});

t.test('blockEnforcement "client_enforced": a stored block row (feature.blocked=true) still offers Unblock -- this is a real, reversible control, not a dead one like not_enforceable', async () => {
    const h = createHarness({
        fetchImpl: routeFetch(personFeaturesHandlers(Object.assign({}, THERMAL_VISION_FEATURE, { blocked: true, state: 'blocked' }))),
    });
    await openPersonScreen(h, {});

    t.equals(findByText(featureActionsCell(h), 'Unblock').length, 1);
    t.equals(findByText(featureActionsCell(h), 'Block').length, 0);
});

t.test('blockEnforcement "client_enforced" is applied per-row, independently of feature.key -- every one of the twelve client-only features renders identically given the same field value', async () => {
    const clientOnlyKeys = [
        'RadialMenu', 'VehicleEntryExit', 'AgilityBasicJump', 'AgilityAdvanced',
        'ThermalVision', 'NightVision', 'HealthStaminaHUD', 'ContrabandScreenFX',
        'AdvancedBarkRadial', 'ProximityAudioFX', 'WaterTrackingDecay', 'CameraFeedPiP',
    ];
    for (const key of clientOnlyKeys) {
        const feature = Object.assign({}, THERMAL_VISION_FEATURE, { key, label: key });
        const h = createHarness({ fetchImpl: routeFetch(personFeaturesHandlers(feature)) });
        await openPersonScreen(h, { strings: { block_client_enforced_badge: 'Enforced (client-side)' } });
        t.equals(findByText(h.getRoot(), 'Enforced (client-side)').length, 1, key + ' should render the client-enforced badge');
    }
});

t.test('featureBlockEnforcement() allow-lists "client_enforced" alongside "enforced"/"not_enforceable" -- an unrelated unrecognized string still falls back safely', async () => {
    const h = createHarness({
        fetchImpl: routeFetch(personFeaturesHandlers({
            key: 'SomeFeature', label: 'Some Feature', category: null,
            globallyEnabled: true, requiresGrant: false, granted: false, blocked: false,
            state: 'available', blockEnforcement: 'some_future_value_nobody_recognizes',
        })),
    });
    await openPersonScreen(h, { strings: { block_client_enforced_badge: 'Enforced (client-side)' } });

    t.equals(findByText(h.getRoot(), 'Not enforced yet').length, 1, 'an unrecognized value still falls back to not_yet_enforced, never client_enforced by accident');
    t.equals(findByText(h.getRoot(), 'Enforced (client-side)').length, 0);
});

t.run();
