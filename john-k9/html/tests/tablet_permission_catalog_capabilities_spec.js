/*
    html/tests/tablet_permission_catalog_capabilities_spec.js

    Covers the person screen's Capabilities section (html/tablet.js's
    resolveCapabilityRows()/buildCapabilityList()/buildCapabilityRow())
    rendering the LIVE server/permissionkeycatalog.lua catalog
    (tablet:permKeysList) instead of a hardcoded four-key array -- the "a
    custom permission key can be created but never given to anyone" fix --
    PLUS (owner-directed "roster panel: checkboxes that actually do
    something, one plain-English line per permission" pass) the row's own
    checkbox control, description line, and self-grant disablement.

    Each permission row is now a REAL <input type="checkbox">, checked when
    held, unchecked when not -- ticking fires tablet:grantPermission,
    unticking fires tablet:revokePermission, both via the SAME
    `change` event (see tablet_role_theme_certtiers_spec.js's own
    established `checkbox.checked = ...; checkbox._dispatch('change')`
    convention, reused here rather than inventing a second one). Scenarios:

      1. The four shipped keys render unchanged (same order, same labels,
         same checked/unchecked split) when an operator never touches the
         catalog -- including when the catalog ALSO happens to report
         those same four keys back (no duplicate rows).
      2. A custom (non-default) catalog key appears AFTER the four shipped
         ones and is genuinely grantable via its checkbox.
      3. A key `heldKeys` names but a SUCCESSFUL catalog fetch does not
         (the only way that happens is server/permissionkeycatalog.lua's
         own tombstone behavior -- see that file's header "TOMBSTONE, NOT
         REFERENCE-COUNTED") still renders, labelled retired, CHECKED, and
         still revocable via the same checkbox.
      4. A failed/denied catalog fetch falls back to exactly the four
         shipped keys -- never an empty panel.
      5. An unhandled/network-error catalog fetch ALSO falls back to the
         four shipped keys, never a crash.
      6. Self-grant: viewing your OWN record, an UNHELD row's checkbox is
         disabled with a reason (server/permissions.lua's GrantPermission
         blocks self-grant unconditionally) -- never an enabled control the
         server would refuse -- while a HELD row's checkbox stays enabled
         (revoke carries no such restriction server-side).
      7. Every row shows a VISIBLE plain-English description line (never a
         tooltip-only one) -- falls back to a disclosed "no description on
         file" note when the catalog/DEFAULT_CAPABILITIES entry carries
         none.
      8. A hostile catalog label/description reaches the DOM only via
         textContent, never innerHTML (same proof technique as
         html/tests/tablet_xss_spec.js -- see tablet-dom-stub.js's own
         trapped innerHTML setter).
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
        if (!h) return Promise.reject(new Error('tablet_permission_catalog_capabilities_spec: unhandled NUI callback ' + name));
        return Promise.resolve(jsonResponse(h(body)));
    };
}

const HIGH_COMMAND_VIEWER = { citizenid: 'HC1', name: 'Chief', isHighCommand: true, effectivePermissions: ['k9.access', 'k9.certify', 'k9.audit', 'k9.givexp'], allowSelfGrant: false };

const FOUR_SHIPPED_KEYS_CATALOG = [
    { key: 'k9.access', label: 'Use K9 abilities', description: 'Equivalent to holding a K9 certification.', isConfigDefault: true },
    { key: 'k9.audit', label: 'View the audit records', description: 'Run the read-only audit commands.', isConfigDefault: true },
    { key: 'k9.certify', label: 'Certify and decertify others', description: 'Grant and revoke K9 certifications.', isConfigDefault: true },
    { key: 'k9.givexp', label: 'Grant XP', description: 'Award XP directly to a K9 or handler.', isConfigDefault: true },
];

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

async function openPersonScreen(h, citizenId) {
    h.postMessage('tablet:open', {});
    await settle();
    findByText(h.getRoot(), 'Command Console')[0].click();
    await settle();
    if (citizenId) {
        // "Open by exact citizen ID" -- reaches ANY citizenid, including the
        // viewer's own (see html/tablet.js's own header note on this box)
        // -- used by the self-grant test below to open the viewer's own record.
        const idInput = findAll(h.getRoot(), (n) => n.tagName === 'input' && n.classList.contains('k9tablet-search') && n.getAttribute('placeholder') === 'Name, citizen ID or server ID...')[0];
        idInput.typeValue(citizenId);
        findByText(h.getRoot(), 'Open')[0].click();
    } else {
        findByText(h.getRoot(), 'Manage')[0].click();
    }
    await settle(4);
}

function getCapabilityRows(h) {
    return findAll(h.getRoot(), (n) => n.classList && n.classList.contains('k9tablet-capability-row'));
}

function capabilityLabelText(row) {
    const div = findAll(row, (n) => n.classList && n.classList.contains('k9tablet-capability-label'))[0];
    return div ? div._textContent : undefined;
}

function capabilityDescriptionText(row) {
    const div = findAll(row, (n) => n.classList && n.classList.contains('k9tablet-capability-description'))[0];
    return div ? div._textContent : undefined;
}

function capabilityCheckbox(row) {
    return findAll(row, (n) => n.tagName === 'input' && n.getAttribute('type') === 'checkbox')[0];
}

t.test('the four shipped keys render unchanged (same order, same labels, same checked/unchecked split) when the catalog reports exactly those four back', async () => {
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:requestPersonSummary': () => ({ ok: true, target: { citizenid: 'TARGET1', name: 'K9 Rex' }, certifications: [], xp: 500, tierLabel: 'Trained K9', permissions: ['k9.access'] }),
            'tablet:permKeysList': () => ({ ok: true, keys: FOUR_SHIPPED_KEYS_CATALOG }),
        })),
    });
    await openPersonScreen(h);

    const rows = getCapabilityRows(h);
    t.equals(rows.length, 4, 'exactly the four shipped rows -- the catalog echoing them back must never duplicate a row');
    t.equals(capabilityLabelText(rows[0]), 'Use K9 abilities');
    t.equals(capabilityLabelText(rows[1]), 'Certify and decertify others');
    t.equals(capabilityLabelText(rows[2]), 'View the audit records');
    t.equals(capabilityLabelText(rows[3]), 'Grant XP');

    const checked = rows.filter((r) => capabilityCheckbox(r).checked === true);
    const unchecked = rows.filter((r) => capabilityCheckbox(r).checked !== true);
    t.equals(checked.length, 1, 'k9.access is held -> exactly one checked checkbox');
    t.equals(unchecked.length, 3, 'the other three are un-held -> unchecked');
    t.equals(findByText(h.getRoot(), 'Retired').length, 0, 'no retired badge anywhere for an untouched catalog');
});

t.test('every row shows a VISIBLE plain-English description line, never only a tooltip', async () => {
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:requestPersonSummary': () => ({ ok: true, target: { citizenid: 'TARGET1', name: 'K9 Rex' }, certifications: [], xp: 500, tierLabel: 'Trained K9', permissions: [] }),
            'tablet:permKeysList': () => ({
                ok: true,
                keys: FOUR_SHIPPED_KEYS_CATALOG.concat([
                    { key: 'k9.with_description', label: 'With Description Key', description: 'This is what ticking it actually does.', isConfigDefault: false },
                    { key: 'k9.no_description', label: 'No Description Key', description: '', isConfigDefault: false },
                ]),
            }),
        })),
    });
    await openPersonScreen(h);

    const rows = getCapabilityRows(h);
    t.equals(capabilityDescriptionText(rows[4]), 'This is what ticking it actually does.', 'the real catalog description text is rendered as its own visible line, not merely a title attribute');
    t.equals(capabilityDescriptionText(rows[5]), 'No description on file for this permission.', 'an empty catalog description falls back to a disclosed note, never a blank line that looks broken');
});

t.test('a custom (non-default) catalog key appears AFTER the four shipped ones and fires tablet:grantPermission with its exact key via its checkbox', async () => {
    let grantBody = null;
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:requestPersonSummary': () => ({ ok: true, target: { citizenid: 'TARGET1', name: 'K9 Rex' }, certifications: [], xp: 500, tierLabel: 'Trained K9', permissions: [] }),
            'tablet:permKeysList': () => ({
                ok: true,
                keys: FOUR_SHIPPED_KEYS_CATALOG.concat([
                    { key: 'k9.custom_ability', label: 'Custom Ability', description: 'A brand new ability an operator just invented.', isConfigDefault: false },
                ]),
            }),
            'tablet:grantPermission': (body) => { grantBody = body; return { ok: true }; },
        })),
    });
    await openPersonScreen(h);

    const rows = getCapabilityRows(h);
    t.equals(rows.length, 5, 'the four shipped rows plus the one custom catalog row');
    t.equals(capabilityLabelText(rows[4]), 'Custom Ability', 'the custom key is appended after the four shipped ones, not spliced into their fixed order');

    const checkbox = capabilityCheckbox(rows[4]);
    t.isFalse(checkbox.checked, 'starts unheld/unchecked');
    checkbox.checked = true;
    checkbox._dispatch('change');
    await new Promise((r) => setTimeout(r, 30));

    t.isDefined(grantBody, 'tablet:grantPermission was actually called');
    t.equals(grantBody.targetCitizenId, 'TARGET1');
    t.equals(grantBody.permission, 'k9.custom_ability', 'the custom key name is sent verbatim, not one of the four hardcoded ones');
});

t.test('a held key absent from a successful catalog fetch (tombstoned) still renders, labelled retired, CHECKED and still revocable via the same checkbox', async () => {
    let revokeBody = null;
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            // k9.legacy_ability is held (an active grant row still exists)
            // but deliberately ABSENT from the catalog response below --
            // exactly what a tombstoned key looks like from this page's
            // point of view (server/permissionkeycatalog.lua's own
            // ListPermissionCatalogKeys excludes a tombstoned key entirely).
            'tablet:requestPersonSummary': () => ({ ok: true, target: { citizenid: 'TARGET1', name: 'K9 Rex' }, certifications: [], xp: 500, tierLabel: 'Trained K9', permissions: ['k9.legacy_ability'] }),
            'tablet:permKeysList': () => ({ ok: true, keys: FOUR_SHIPPED_KEYS_CATALOG }),
            'tablet:revokePermission': (body) => { revokeBody = body; return { ok: true }; },
        })),
    });
    await openPersonScreen(h);

    const rows = getCapabilityRows(h);
    t.equals(rows.length, 5, 'the four shipped rows plus the retired-but-held row');
    const retiredRow = rows[4];
    t.contains(capabilityLabelText(retiredRow) || '', 'k9.legacy_ability', 'no catalog entry survives for this key, so its own raw key name is the best available label');
    const retiredBadges = findAll(retiredRow, (n) => typeof n._textContent === 'string' && n._textContent.indexOf('Retired') !== -1);
    t.equals(retiredBadges.length, 1, 'a retired badge is shown exactly once, on the retired row only');
    t.equals(findAll(rows[0], (n) => typeof n._textContent === 'string' && n._textContent.indexOf('Retired') !== -1).length, 0, 'the shipped k9.access row never carries a retired badge');

    const checkbox = capabilityCheckbox(retiredRow);
    t.isTrue(checkbox.checked, 'a held key, retired or not, always renders checked');
    t.isNull(checkbox.getAttribute('disabled'), 'still revocable -- this is exactly what makes it actually revocable');

    checkbox.checked = false;
    checkbox._dispatch('change');
    await new Promise((r) => setTimeout(r, 30));

    t.isDefined(revokeBody, 'tablet:revokePermission was actually called for the retired key');
    t.equals(revokeBody.targetCitizenId, 'TARGET1');
    t.equals(revokeBody.permission, 'k9.legacy_ability');
});

t.test('a failed/denied catalog fetch falls back to exactly the four shipped keys -- never an empty panel', async () => {
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:requestPersonSummary': () => ({ ok: true, target: { citizenid: 'TARGET1', name: 'K9 Rex' }, certifications: [], xp: 500, tierLabel: 'Trained K9', permissions: ['k9.access'] }),
            'tablet:permKeysList': () => ({ ok: false, reason: 'denied' }),
        })),
    });
    await openPersonScreen(h);

    t.equals(findByText(h.getRoot(), 'Capabilities').length, 1, 'the section heading itself still renders');
    const rows = getCapabilityRows(h);
    t.equals(rows.length, 4, 'falls back to exactly the four shipped keys, never zero');
    t.equals(rows.filter((r) => capabilityCheckbox(r).checked === true).length, 1);
    t.equals(rows.filter((r) => capabilityCheckbox(r).checked !== true).length, 3);
});

t.test('an unhandled/network-error catalog fetch (no tablet:permKeysList route at all) ALSO falls back to the four shipped keys, never a crash', async () => {
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:requestPersonSummary': () => ({ ok: true, target: { citizenid: 'TARGET1', name: 'K9 Rex' }, certifications: [], xp: 500, tierLabel: 'Trained K9', permissions: [] }),
            // deliberately no 'tablet:permKeysList' handler -- routeFetch
            // rejects, fetchNui()'s own .catch() turns that into
            // { ok: false, error: 'network_error' }.
        })),
    });
    await openPersonScreen(h);

    const rows = getCapabilityRows(h);
    t.equals(rows.length, 4, 'still exactly the four shipped keys after a hard fetch failure');
    t.equals(rows.filter((r) => capabilityCheckbox(r).checked === true).length, 0, 'none held -> none checked');
});

t.test('SELF-GRANT: viewing your own record, an unheld row is disabled with a reason -- never an enabled checkbox the server would refuse', async () => {
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:requestPersonSummary': () => ({ ok: true, target: { citizenid: 'HC1', name: 'Chief' }, certifications: [], xp: null, tierLabel: null, permissions: ['k9.access'] }),
            'tablet:permKeysList': () => ({ ok: true, keys: FOUR_SHIPPED_KEYS_CATALOG }),
        })),
    });
    await openPersonScreen(h, 'HC1');

    const rows = getCapabilityRows(h);
    const heldRow = rows.filter((r) => capabilityLabelText(r) === 'Use K9 abilities')[0];
    const unheldRow = rows.filter((r) => capabilityLabelText(r) === 'Grant XP')[0];

    const heldCheckbox = capabilityCheckbox(heldRow);
    t.isTrue(heldCheckbox.checked);
    t.isNull(heldCheckbox.getAttribute('disabled'), 'revoking your own already-held permission carries no self-restriction server-side, so this stays enabled');

    const unheldCheckbox = capabilityCheckbox(unheldRow);
    t.isFalse(unheldCheckbox.checked);
    t.equals(unheldCheckbox.getAttribute('disabled'), 'disabled', 'GrantPermission blocks self-grant unconditionally -- this checkbox must never be enabled only to fail server-side');
});

t.test('SHARED RATE LIMIT: after one checkbox mutation fires, every capability checkbox is disabled with an honest reason until the cooldown window passes', async () => {
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:requestPersonSummary': () => ({ ok: true, target: { citizenid: 'TARGET1', name: 'K9 Rex' }, certifications: [], xp: 500, tierLabel: 'Trained K9', permissions: ['k9.access'] }),
            'tablet:permKeysList': () => ({ ok: true, keys: FOUR_SHIPPED_KEYS_CATALOG }),
            'tablet:grantPermission': () => ({ ok: true }),
            // This one test needs the person to have at least one ability.
            // Everywhere else in this file `features: []` is right -- the
            // subject is capabilities, not abilities -- but the ability
            // FILTER is this test's render lever (see below), and as of
            // 2026-09-01 that filter is deliberately not rendered for an
            // empty list: there is nothing to narrow, so offering a control
            // to narrow it is exactly the kind of pointless input the
            // owner asked to be rid of. A person with no abilities at all
            // is also not the realistic case for this screen.
            'tablet:requestPersonFeatures': () => ({
                ok: true,
                target: { citizenid: 'TARGET1', name: 'K9 Rex' },
                features: [{ key: 'k9_bark', label: 'Bark', category: 'combat', state: 'available', globallyEnabled: true }],
            }),
        })),
    });
    await openPersonScreen(h);

    const rows = getCapabilityRows(h);
    const unheldRow = rows.filter((r) => capabilityLabelText(r) === 'Grant XP')[0];

    capabilityCheckbox(unheldRow).checked = true;
    capabilityCheckbox(unheldRow)._dispatch('change');
    await new Promise((r) => setTimeout(r, 30)); // let the mocked grant resolve and the refresh re-render

    const afterFirstGrant = getCapabilityRows(h);
    const stillUnheldRow = afterFirstGrant.filter((r) => capabilityLabelText(r) === 'View the audit records')[0];
    const stillUnheldCheckbox = capabilityCheckbox(stillUnheldRow);
    t.equals(stillUnheldCheckbox.getAttribute('disabled'), 'disabled', 'a SECOND permission change right after the first is disabled client-side, before the server ever has a chance to say rate_limited');
    const toggleLabel = stillUnheldCheckbox.parentNode;
    t.contains(toggleLabel.getAttribute('title') || '', 'cooldown', 'the disabled reason is honest and specific, not silent');

    // NOTE: tablet-sandbox.js caps EVERY sandboxed setTimeout at 15ms (see
    // its own header "TEST-ONLY TIME COMPRESSION") -- this file's own
    // requested PERMISSION_ACTION_MIN_INTERVAL_MS + 50 re-render timer is
    // therefore already long since fired by the time this REAL (uncapped,
    // Node-native) wait below elapses; only the real, unmocked Date.now()
    // this file's cooldown math reads is what actually matters here.
    // Forcing one more ordinary render (via the feature search box's own
    // synchronous 'input' -> render() handler, nothing to do with
    // capabilities) is what proves the disablement is correctly
    // TIME-BOUND from real elapsed time, not merely "cleared once, by
    // coincidence" -- the exact thing this test exists to prove.
    await new Promise((r) => setTimeout(r, 1700)); // past PERMISSION_ACTION_MIN_INTERVAL_MS (1600ms)
    const featureSearch = findAll(h.getRoot(), (n) => n.tagName === 'input' && n.getAttribute('placeholder') === 'Search abilities...')[0];
    t.isDefined(featureSearch, 'sanity: the unrelated ability filter is present to force a render (this test gives the person one ability so that it is -- see the handler override above)');
    featureSearch.typeValue('x');
    featureSearch.typeValue('');

    const afterCooldown = getCapabilityRows(h);
    const reEnabledRow = afterCooldown.filter((r) => capabilityLabelText(r) === 'View the audit records')[0];
    t.isNull(capabilityCheckbox(reEnabledRow).getAttribute('disabled'), 'once the real cooldown window has genuinely passed, the NEXT render re-enables every capability checkbox, never a stuck-disabled control');
});

t.test('a hostile catalog label/description reaches the DOM only via textContent, never innerHTML', async () => {
    const malicious = '<img src=x onerror="window.__xss_pwned=true">';
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:requestPersonSummary': () => ({ ok: true, target: { citizenid: 'TARGET1', name: 'K9 Rex' }, certifications: [], xp: 500, tierLabel: 'Trained K9', permissions: [] }),
            'tablet:permKeysList': () => ({
                ok: true,
                keys: FOUR_SHIPPED_KEYS_CATALOG.concat([
                    { key: 'k9.custom_ability', label: malicious, description: malicious, isConfigDefault: false },
                ]),
            }),
        })),
    });
    await openPersonScreen(h);

    const matches = findAll(h.getRoot(), (n) => n._textContent === malicious);
    t.isTrue(matches.length >= 1, 'the malicious catalog label reaches the DOM verbatim as textContent');

    const innerHTMLWrites = findAll(h.getRoot(), () => true).reduce((sum, el) => sum + (el.innerHTMLWriteCount || 0), 0);
    t.equals(innerHTMLWrites, 0, 'innerHTML must never be written anywhere on this page for a malicious catalog label/description');
});

t.run();
