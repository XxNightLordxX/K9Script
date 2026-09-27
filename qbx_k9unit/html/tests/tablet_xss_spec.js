/*
    html/tests/tablet_xss_spec.js

    Proves (not merely asserts by reading source) that html/tablet.js never
    writes ANY player- or server-controlled string into innerHTML anywhere
    on this page -- same technique as html/tests/xss_spec.js uses for
    app.js, extended to cover the strings THIS page renders that the HUD
    never did: names, citizenids, department labels, feature/capability
    labels, and free-form `message` fields on a mutation response. Per this
    task's own standing instruction ("assume a player can bypass your UI
    entirely and send arbitrary payloads straight to the callback"), every
    one of these is treated as fully attacker-controlled regardless of
    which side of the contract nominally authors it.

    K9 SUPPLY SHOP LOCATIONS (server/equipmentshop.lua, high command only --
    see html/tablet.js's own buildShopLocationsScreen() doc comment) added
    its own coverage below: the three operator-typed free-text fields
    (label, ped model, idle scenario) are exercised across every render
    path that screen has --
      - the location table (buildShopLocationRow(), BOTH a config.lua
        `cfg:` row and a runtime `db:` row -- config-authored text is
        treated as attacker-controlled too, per this file's own header),
      - the Edit draft form pre-filled from an existing STORED (i.e.
        already-persisted, multi-reader) location via `.value`,
      - the Add draft form's OWN operator-typed input via `.value`
        (typeValue(), exactly as a real keystroke would populate it),
      - a Move/Remove/Add mutation-failure `message` field, both inline on
        the affected row and in the top-of-panel banner.
    A dedicated assertion also confirms none of these three fields ever
    leak into an `id`/`title` attribute anywhere in the document while
    they hold a malicious payload -- the specific blind spot a `mk()`-only
    code review (textContent vs innerHTML) does not by itself rule out.
*/
'use strict';

const t = require('./testkit');
const { createHarness, jsonResponse } = require('./tablet-sandbox');
const { findAll, findByText, openSettingsSection } = require('./tablet-dom-stub');

function routeFetch(handlers) {
    return function (url, init) {
        const name = url.split('/').pop();
        const body = init && init.body ? JSON.parse(init.body) : undefined;
        const h = handlers[name];
        if (!h) return Promise.reject(new Error('tablet_xss_spec: unhandled NUI callback ' + name));
        return Promise.resolve(jsonResponse(h(body)));
    };
}

const MALICIOUS_STRINGS = [
    '<img src=x onerror="window.__xss_pwned=true">',
    '<script>window.__xss_pwned=true</script>',
    '"><svg onload=alert(1)>',
    'javascript:alert(1)',
    '</span><b>bold-injected</b>',
    '&lt;already-escaped&gt;',
    'a'.repeat(5000),
    ' ‮​',
];

function everyElementInnerHTMLWriteCount(h) {
    return findAll(h.getRoot(), () => true).reduce((sum, el) => sum + (el.innerHTMLWriteCount || 0), 0);
}

const HIGH_COMMAND_VIEWER = { citizenid: 'HC1', name: 'Chief', isHighCommand: true, effectivePermissions: ['k9.access', 'k9.certify', 'k9.audit', 'k9.givexp'], allowSelfGrant: false };

async function settle(times) {
    for (let i = 0; i < (times || 3); i++) await new Promise((r) => setImmediate(r));
}

for (const malicious of MALICIOUS_STRINGS) {
    const shortLabel = JSON.stringify(malicious.slice(0, 40)) + (malicious.length > 40 ? '...' : '');

    t.test(`home: welcome heading interpolating the viewer's name containing ${shortLabel} reaches the DOM verbatim via textContent, never innerHTML`, async () => {
        const h = createHarness({
            fetchImpl: routeFetch({
                'tablet:requestMyRecord': () => ({
                    ok: true,
                    viewer: { citizenid: 'CIT1', name: malicious, isHighCommand: false, effectivePermissions: [], allowSelfGrant: false },
                    certifications: [],
                    xp: null,
                    tierLabel: null,
                    myFeatures: [],
                }),
            }),
        });
        h.postMessage('tablet:open', {});
        await settle();

        // Home is the DEFAULT screen (this pass) -- no navigation needed.
        // The welcome heading interpolates the viewer's name into a
        // template string (formatTemplate()), so this checks for the
        // payload appearing verbatim WITHIN a node's own textContent
        // (never a bare equality check, since the template also contains
        // fixed "Welcome, "/"." text around it) via `.indexOf`, never
        // parsed as markup.
        const heading = findAll(h.getRoot(), (n) => typeof n._textContent === 'string' && n._textContent.indexOf(malicious) !== -1);
        t.isTrue(heading.length >= 1, "the malicious viewer name appears verbatim (via textContent) inside the Home welcome heading");
        t.equals(everyElementInnerHTMLWriteCount(h), 0, 'innerHTML must never be written anywhere on this page for this payload');
    });

    t.test(`my-record: certification department label + feature label containing ${shortLabel} reach the DOM verbatim via textContent, never innerHTML`, async () => {
        const h = createHarness({
            fetchImpl: routeFetch({
                'tablet:requestMyRecord': () => ({
                    ok: true,
                    viewer: { citizenid: malicious, name: malicious, isHighCommand: false, effectivePermissions: [], allowSelfGrant: false },
                    certifications: [{ departmentKey: 'x', departmentLabel: malicious, active: true, grantedBy: malicious }],
                    xp: 1,
                    tierLabel: malicious,
                    myFeatures: [{ key: 'X', label: malicious, category: malicious, actionable: false, state: 'available' }],
                }),
            }),
        });
        h.postMessage('tablet:open', {});
        await settle();

        // The DEFAULT screen on open is now 'home' (this pass's own
        // landing view), which shows only summary counts, never a raw
        // department/tier/feature label -- navigate to the full My Record
        // screen explicitly, same as every other screen-specific case in
        // this suite (Command Console/Manage/Shop Locations/Certification
        // Tiers below all do the equivalent click before asserting).
        findByText(h.getRoot(), 'My Record')[0].click();
        await settle();

        const matches = findAll(h.getRoot(), (n) => n._textContent === malicious);
        t.isTrue(matches.length >= 3, 'the malicious string appears verbatim as textContent in at least the department label, tier label, and feature label');
        t.equals(everyElementInnerHTMLWriteCount(h), 0, 'innerHTML must never be written anywhere on this page for this payload');
    });

    t.test(`admin roster/person: name/citizenid/department/message/ped-label containing ${shortLabel} reach the DOM verbatim via textContent, never innerHTML`, async () => {
        const h = createHarness({
            fetchImpl: routeFetch({
                'tablet:requestMyRecord': () => ({ ok: true, viewer: HIGH_COMMAND_VIEWER, certifications: [], xp: null, tierLabel: null, myFeatures: [] }),
                'tablet:getTheme': () => ({ ok: true, theme: { primaryColor: '#2563eb', accentColor: '#f59e0b', backgroundColor: '#111827', textColor: '#f9fafb', density: 'comfortable', headerTitle: 'K9 Command Tablet' } }),
                'tablet:requestRoster': () => ({ ok: true, rows: [{ citizenid: malicious, name: malicious, departmentLabel: malicious, certified: true, xp: 1, tierLabel: malicious }], truncated: true, truncatedMessage: malicious }),
                'tablet:requestPersonSummary': () => ({ ok: true, target: { citizenid: malicious, name: malicious }, certifications: [{ departmentKey: 'x', departmentLabel: malicious, active: true, grantedBy: malicious }], xp: 1, tierLabel: malicious, permissions: [] }),
                'tablet:requestPersonFeatures': () => ({ ok: true, target: { citizenid: malicious, name: malicious }, features: [{ key: 'X', label: malicious, category: malicious, globallyEnabled: true, requiresGrant: false, granted: false, blocked: false, state: 'available' }] }),
                'tablet:certify': () => ({ ok: false, message: malicious }),
            }),
        });

        // `peds` (K9 role control's model picker, see html/tablet.js's own
        // header on tablet:assignK9Role) is sent verbatim from the
        // tablet:open payload -- a malicious `label` here is config-authored
        // in a real deployment, not directly player-controlled, but this
        // suite's own header treats every string as attacker-controlled
        // "regardless of which side of the contract nominally authors it".
        h.postMessage('tablet:open', { peds: [{ model: 'a_c_shepherd', label: malicious }] });
        await settle();
        const { findByText } = require('./tablet-dom-stub');
        findByText(h.getRoot(), 'Command Console')[0].click();
        await settle();

        // Roster row + truncation banner.
        t.isTrue(findAll(h.getRoot(), (n) => n._textContent === malicious).length > 0, 'malicious roster/truncation text present verbatim');
        t.equals(everyElementInnerHTMLWriteCount(h), 0);

        findByText(h.getRoot(), 'Manage')[0].click();
        await settle(4);

        t.isTrue(findAll(h.getRoot(), (n) => n._textContent === malicious).length > 0, 'malicious person-summary/feature/ped-label text present verbatim (K9 Role section\'s own model picker option is included in this count)');
        t.equals(everyElementInnerHTMLWriteCount(h), 0);

        // An action-failure `message` field is also attacker/server-adjacent
        // content, per this file's header -- must render via textContent too.
        const certifyBtn = findByText(h.getRoot(), 'Certify')[0];
        if (certifyBtn) {
            certifyBtn.click();
            await new Promise((r) => setTimeout(r, 30));
            t.isTrue(findAll(h.getRoot(), (n) => n._textContent === malicious).length > 0, 'mutation failure message rendered verbatim');
            t.equals(everyElementInnerHTMLWriteCount(h), 0);
        }
    });

    t.test(`tablet theming + cert tier editing: header title / tier label / capability label / reorder warning containing ${shortLabel} reach the DOM verbatim via textContent, never innerHTML`, async () => {
        const h = createHarness({
            fetchImpl: routeFetch({
                'tablet:requestMyRecord': () => ({ ok: true, viewer: HIGH_COMMAND_VIEWER, certifications: [], xp: null, tierLabel: null, myFeatures: [] }),
                'tablet:getTheme': () => ({ ok: true, theme: { primaryColor: '#2563eb', accentColor: '#f59e0b', backgroundColor: '#111827', textColor: '#f9fafb', density: 'comfortable', headerTitle: malicious } }),
                'tablet:certTiersList': () => ({
                    ok: true,
                    tiers: [
                        { key: 'x', label: malicious, ordinal: 1, capabilities: { cap1: true } },
                        { key: 'certified', label: 'Certified', ordinal: 2, capabilities: {} },
                    ],
                    capabilityCatalog: { cap1: { label: malicious } },
                }),
                'tablet:certTiersReorder': () => ({ ok: true, tiers: [], warning: malicious }),
            }),
        });

        // branding.serverName -- config-authored, but per this file's own
        // header, treated as fully attacker-controlled regardless of which
        // side of the contract nominally authors it. No `logo` here so it
        // renders directly (see the separate ped-label/branding coverage
        // in the "admin roster/person" test above and
        // tablet_role_theme_certtiers_spec.js for the logo-present path).
        h.postMessage('tablet:open', { branding: { serverName: malicious } });
        await settle();

        // Theme headerTitle -- rendered directly into the panel's <h1>.
        t.isTrue(findAll(h.getRoot(), (n) => n._textContent === malicious).length >= 1, 'malicious theme headerTitle rendered verbatim in the header');
        t.equals(everyElementInnerHTMLWriteCount(h), 0);

        // branding.serverName -- rendered in the header's own branding slot.
        t.isTrue(findAll(h.getRoot(), (n) => n.classList && n.classList.contains('k9tablet-branding-name') && n._textContent === malicious).length >= 1, 'malicious serverName rendered verbatim in the branding element');
        t.equals(everyElementInnerHTMLWriteCount(h), 0);

        const { findByText } = require('./tablet-dom-stub');
        openSettingsSection(h.getRoot(), 'Catalogs');
        await settle();

        t.isTrue(findAll(h.getRoot(), (n) => n._textContent === malicious).length >= 1, 'malicious cert-tier label AND capability label both rendered verbatim');
        t.equals(everyElementInnerHTMLWriteCount(h), 0);

        // Trigger a reorder (move the second row, "certified", up) to reach
        // the server-supplied `warning` banner.
        const moveUpButtons = findAll(h.getRoot(), (n) => n.tagName === 'button' && n._textContent === '↑');
        const enabledMoveUp = moveUpButtons.filter((b) => b.getAttribute('disabled') !== 'disabled')[0];
        t.isDefined(enabledMoveUp, 'at least one enabled Move Up control exists with two tiers present');
        enabledMoveUp.click();
        await new Promise((r) => setTimeout(r, 30));

        t.isTrue(findAll(h.getRoot(), (n) => n._textContent === malicious).length >= 1, 'malicious reorder warning text rendered verbatim');
        t.equals(everyElementInnerHTMLWriteCount(h), 0);
    });

    t.test(`runtime control: a lockoutRisk feature's server-authored lockoutWarning containing ${shortLabel} reaches the confirmation panel verbatim via textContent, never innerHTML, and a confirmation_required refusal's own message does too`, async () => {
        const h = createHarness({
            fetchImpl: routeFetch({
                'tablet:requestMyRecord': () => ({ ok: true, viewer: HIGH_COMMAND_VIEWER, certifications: [], xp: null, tierLabel: null, myFeatures: [] }),
                'tablet:getTheme': () => ({ ok: true, theme: { primaryColor: '#2563eb', accentColor: '#f59e0b', backgroundColor: '#111827', textColor: '#f9fafb', density: 'comfortable', headerTitle: 'K9 Command Tablet' } }),
                'tablet:runtimeListFeatures': () => ({
                    ok: true,
                    features: [{ name: 'HighCommand', currentValue: true, tier: 'live', overridden: false, protected: false, lockoutRisk: true, sessionOnly: true, lockoutWarning: malicious }],
                }),
                'tablet:runtimeListTunables': () => ({ ok: true, tunables: [] }),
                'tablet:runtimeSetFeature': () => ({ ok: false, error: 'confirmation_required', lockoutRisk: true, warning: malicious }),
            }),
        });
        h.postMessage('tablet:open', { runtimeControlEnabled: true });
        await settle();

        openSettingsSection(h.getRoot(), 'Runtime Control');
        await settle();

        // The server's own lockoutWarning text is only shown once the
        // confirmation panel is open -- see buildRuntimeLockoutConfirmPanel().
        const toggleBtn = findByText(h.getRoot(), 'Disable')[0];
        toggleBtn.click();
        await settle();

        t.isTrue(findAll(h.getRoot(), (n) => n._textContent === malicious).length >= 1, 'the malicious lockoutWarning text is rendered verbatim in the confirmation panel');
        t.equals(everyElementInnerHTMLWriteCount(h), 0, 'innerHTML must never be written anywhere on this page for this payload');

        // Attribute-context check, same posture as the shop-locations
        // operator-typed-field coverage below: the server-authored warning
        // must never leak into an id/title attribute either.
        const leaked = findAll(h.getRoot(), () => true).some((n) => {
            const idVal = n.getAttribute ? n.getAttribute('id') : null;
            const titleVal = n.getAttribute ? n.getAttribute('title') : null;
            return idVal === malicious || titleVal === malicious;
        });
        t.isFalse(leaked, 'the malicious lockoutWarning never appears verbatim as an id or title attribute anywhere in the document');

        // Type the exact feature name (the ONLY way this page's own Confirm
        // button ever enables) and confirm -- the server refuses anyway
        // here (confirmation_required, simulating a stale/bypassed
        // confirm), whose OWN `warning`/error text must also render
        // verbatim, never innerHTML.
        const confirmInput = findAll(h.getRoot(), (n) => n.tagName === 'input' && n.classList.contains('k9tablet-runtime-lockout-confirm-input'))[0];
        confirmInput.typeValue('HighCommand');
        await settle();
        findByText(h.getRoot(), 'Confirm and Apply')[0].click();
        await new Promise((r) => setTimeout(r, 30));

        t.equals(everyElementInnerHTMLWriteCount(h), 0, 'innerHTML must never be written anywhere on this page after the refusal renders either');
    });

    t.test(`shop locations: STORED label/ped-model/idle-scenario (table row, BOTH cfg: and db: sources, plus the Edit draft's own prefill) and a Remove-failure message containing ${shortLabel} reach the DOM verbatim via textContent/.value, never innerHTML`, async () => {
        const h = createHarness({
            fetchImpl: routeFetch({
                'tablet:requestMyRecord': () => ({ ok: true, viewer: HIGH_COMMAND_VIEWER, certifications: [], xp: null, tierLabel: null, myFeatures: [] }),
                'tablet:equipmentShopGetLocations': () => ({
                    ok: true,
                    locations: {
                        // config.lua-sourced entry -- read-only from this
                        // screen, but per this file's own header treated as
                        // attacker-controlled regardless of authorship.
                        'cfg:0': { x: 1, y: 2, z: 3, heading: 0, model: malicious, scenario: malicious, label: malicious },
                        // Runtime entry -- this is the STORED, MULTI-READER
                        // case the task's own threat model calls out: one
                        // operator's saved text, rendered for every later
                        // viewer of this screen.
                        'db:1': { x: 4, y: 5, z: 6, heading: 90, model: malicious, scenario: malicious, label: malicious },
                    },
                }),
                'tablet:equipmentShopRemoveLocation': () => ({ ok: false, message: malicious }),
            }),
        });
        h.postMessage('tablet:open', { shopLocationsEnabled: true });
        await settle();

        const { findByText } = require('./tablet-dom-stub');
        openSettingsSection(h.getRoot(), 'K9 Supply Shop');
        await settle();

        // Table: label + ped model, rendered identically for BOTH the
        // cfg: and db: row by buildShopLocationRow() -- source only
        // changes which action buttons appear, never how label/model text
        // itself reaches the DOM.
        t.isTrue(findAll(h.getRoot(), (n) => n._textContent === malicious).length >= 4, 'malicious label+model text present verbatim for BOTH the cfg: and db: rows');
        t.equals(everyElementInnerHTMLWriteCount(h), 0);

        // Edit draft form -- pre-fills label/model/scenario from the
        // STORED db: entry via `.value` (a DOM property assignment, never
        // markup) -- see openEditShopLocationDraft().
        findByText(h.getRoot(), 'Edit')[0].click();
        await settle();
        const prefilled = findAll(h.getRoot(), (n) => n.tagName === 'input' && n.value === malicious);
        t.isTrue(prefilled.length >= 3, 'label/model/scenario inputs all pre-filled with the stored malicious value via .value, not innerHTML');
        t.equals(everyElementInnerHTMLWriteCount(h), 0);
        findByText(h.getRoot(), 'Cancel')[0].click();
        await settle();

        // A Remove refusal's `message` -- attacker/server-adjacent content
        // per this file's own header -- renders inline on that row (and in
        // the top banner) via textContent, same convention as every other
        // mutation-failure message this suite already covers.
        const removeBtn = findByText(h.getRoot(), 'Remove')[0];
        removeBtn.click(); // arm confirm
        removeBtn.click(); // confirm
        await new Promise((r) => setTimeout(r, 30));
        t.isTrue(findAll(h.getRoot(), (n) => n._textContent === malicious).length >= 1, 'malicious Remove-failure message rendered verbatim');
        t.equals(everyElementInnerHTMLWriteCount(h), 0);
    });

    t.test(`shop locations: OPERATOR-TYPED label/ped-model/idle-scenario in the Add draft form, plus an Add/Move-failure message, containing ${shortLabel}, reach the DOM only via .value/textContent -- never innerHTML, and never leak into any id/title attribute anywhere in the document`, async () => {
        const h = createHarness({
            fetchImpl: routeFetch({
                'tablet:requestMyRecord': () => ({ ok: true, viewer: HIGH_COMMAND_VIEWER, certifications: [], xp: null, tierLabel: null, myFeatures: [] }),
                'tablet:equipmentShopGetLocations': () => ({ ok: true, locations: { 'db:2': { x: 1, y: 2, z: 3, heading: 0, model: 'a_c_husky', scenario: '', label: 'Existing' } } }),
                'tablet:equipmentShopAddLocation': () => ({ ok: false, message: malicious }),
                'tablet:equipmentShopMoveLocation': () => ({ ok: false, message: malicious }),
            }),
        });
        h.postMessage('tablet:open', { shopLocationsEnabled: true });
        await settle();

        const { findByText } = require('./tablet-dom-stub');
        openSettingsSection(h.getRoot(), 'K9 Supply Shop');
        await settle();

        findByText(h.getRoot(), 'Add Location Here')[0].click();
        await settle();

        // Types (not just assigns) the malicious payload into all three
        // draft inputs, exactly as a real keystroke would -- see
        // buildShopLocationDraftForm(): label, then model, then scenario,
        // in that DOM order, and (at this point in the flow) the ONLY
        // three <input> elements on the whole screen.
        const formInputs = findAll(h.getRoot(), (n) => n.tagName === 'input');
        t.equals(formInputs.length, 3, 'exactly the label/model/scenario inputs are present while the Add draft is open');
        formInputs.forEach((inp) => inp.typeValue(malicious));
        t.equals(everyElementInnerHTMLWriteCount(h), 0, 'typing the payload alone never touches innerHTML');

        // ATTRIBUTE-CONTEXT CHECK -- the specific blind spot a textContent-
        // only review can miss: confirm the typed text never reaches an
        // `id` or `title` attribute anywhere in the document (a `mk()`
        // review would not by itself rule this out, since mk() also
        // supports an `attrs`/`title` path -- this screen simply never
        // routes these three fields through it, and this assertion proves
        // that rather than trusting the read).
        const allNodes = findAll(h.getRoot(), () => true);
        const leaked = allNodes.some((n) => {
            var idVal = n.getAttribute ? n.getAttribute('id') : null;
            var titleVal = n.getAttribute ? n.getAttribute('title') : null;
            return idVal === malicious || titleVal === malicious;
        });
        t.isFalse(leaked, 'the operator-typed text never appears verbatim as an id or title attribute anywhere in the document');

        findByText(h.getRoot(), 'Save Location')[0].click();
        await new Promise((r) => setTimeout(r, 30));

        t.isTrue(findAll(h.getRoot(), (n) => n._textContent === malicious).length >= 1, 'Add-failure message rendered verbatim via textContent');
        t.equals(everyElementInnerHTMLWriteCount(h), 0);

        // The Add draft stays open after a failure (see
        // html/tests/tablet_shop_locations_spec.js's own coverage of that
        // behavior) -- the pre-existing db: row's own Move Here control is
        // still reachable at the same time; exercise its failure message
        // too, same treatment.
        const moveBtn = findByText(h.getRoot(), 'Move Here')[0];
        moveBtn.click(); // arm confirm
        moveBtn.click(); // confirm
        await new Promise((r) => setTimeout(r, 30));
        t.isTrue(findAll(h.getRoot(), (n) => n._textContent === malicious).length >= 1, 'Move-Here-failure message rendered verbatim');
        t.equals(everyElementInnerHTMLWriteCount(h), 0);
    });
}

t.test('a full battery of malicious strings across many sequential opens never once touches innerHTML anywhere in the document', async () => {
    const h = createHarness({
        fetchImpl: routeFetch({
            'tablet:requestMyRecord': () => {
                const s = MALICIOUS_STRINGS[Math.floor(Math.random() * MALICIOUS_STRINGS.length)];
                return {
                    ok: true,
                    viewer: { citizenid: s, name: s, isHighCommand: false, effectivePermissions: [], allowSelfGrant: false },
                    certifications: [{ departmentKey: 'x', departmentLabel: s, active: true, grantedBy: s }],
                    xp: 1, tierLabel: s,
                    myFeatures: [{ key: 'X', label: s, category: s, actionable: false, state: 'available' }],
                };
            },
        }),
    });

    for (let i = 0; i < MALICIOUS_STRINGS.length; i++) {
        h.postMessage('tablet:close', {});
        h.postMessage('tablet:open', {});
        await settle();
    }
    t.equals(everyElementInnerHTMLWriteCount(h), 0, 'zero innerHTML writes across the whole document after every malicious payload in this suite, across repeated open/close cycles');
});

t.test('shop locations: a full battery of malicious strings across many sequential Shop Locations tab visits (fresh label/model/scenario each time) never once touches innerHTML anywhere in the document', async () => {
    const h = createHarness({
        fetchImpl: routeFetch({
            'tablet:requestMyRecord': () => ({ ok: true, viewer: HIGH_COMMAND_VIEWER, certifications: [], xp: null, tierLabel: null, myFeatures: [] }),
            'tablet:equipmentShopGetLocations': () => {
                const s = MALICIOUS_STRINGS[Math.floor(Math.random() * MALICIOUS_STRINGS.length)];
                return {
                    ok: true,
                    locations: {
                        'cfg:0': { x: 1, y: 2, z: 3, heading: 0, model: s, scenario: s, label: s },
                        'db:1': { x: 4, y: 5, z: 6, heading: 90, model: s, scenario: s, label: s },
                    },
                };
            },
        }),
    });
    h.postMessage('tablet:open', { shopLocationsEnabled: true });
    await settle();

    const { findByText } = require('./tablet-dom-stub');
    for (let i = 0; i < MALICIOUS_STRINGS.length * 2; i++) {
        // Leave and revisit the tab -- refetches locations each time (see
        // loadShopLocations()'s own stale-response-guard comment), landing
        // a freshly-random malicious payload on every visit.
        findByText(h.getRoot(), 'My Record')[0].click();
        await settle();
        openSettingsSection(h.getRoot(), 'K9 Supply Shop');
        await settle();
    }
    t.equals(everyElementInnerHTMLWriteCount(h), 0, 'zero innerHTML writes across the whole document after every malicious shop-location payload in this suite, across repeated tab-visit cycles');
});

t.test('home: welcome heading falls back to a malicious citizenid, verbatim via textContent, never innerHTML, when the viewer has no name at all', async () => {
    const malicious = MALICIOUS_STRINGS[1]; // '<script>...' -- one representative payload is enough for this one fallback branch
    const h = createHarness({
        fetchImpl: routeFetch({
            'tablet:requestMyRecord': () => ({
                ok: true,
                viewer: { citizenid: malicious, name: '', isHighCommand: false, effectivePermissions: [], allowSelfGrant: false },
                certifications: [],
                xp: null,
                tierLabel: null,
                myFeatures: [],
            }),
        }),
    });
    h.postMessage('tablet:open', {});
    await settle();

    const heading = findAll(h.getRoot(), (n) => typeof n._textContent === 'string' && n._textContent.indexOf(malicious) !== -1);
    t.isTrue(heading.length >= 1, 'the malicious citizenid fallback appears verbatim (via textContent) inside the Home welcome heading');
    t.equals(everyElementInnerHTMLWriteCount(h), 0);
});

t.run();
