/*
    html/tests/tablet_audit_spec.js

    Covers the K9 Audit Trail viewer screen (its own tab) -- server/
    admin.lua's six tabletAudit* callbacks (Cert/Partner/Search/Xp/Dept/
    Catalog), bridged one-to-one by client/tablet.lua's tablet:auditCert/
    Partner/Search/Xp/Dept/Catalog NUI callbacks. See
    tests/clienttablet_spec.lua for the Lua-side half of this same contract
    (validation + forwarding); this file covers only the JS half: gating,
    per-mode form fields, result rendering, and error/empty states.

    Server contract verified directly against server/admin.lua (not
    assumed): every tabletAudit* callback returns
    `{ok:true, rows, label, cap, limit?, truncated?}` on success (cap/limit/
    truncated added in a later pass than the rest of this file -- see the
    "cap / limit / truncated" section below) or
    `{ok:false, error:'not_authorized'|'rate_limited'|'invalid_args', message?}`
    otherwise -- never a formatted string -- and `rows`' column shape is
    DIFFERENT PER MODE (see server/datastore.lua's own K9Store.Cert_GetHistory,
    Partner_GetHistoryByK9, Partner_GetHistoryByHandler,
    SearchLog_GetByOfficer/ByPlate/ByPerson/Recent, XP_GetSnapshotRows and
    Cert_GetActiveRosterByJob for the authoritative column list of each of
    the first five, reflected in html/tablet.js's own auditColumnsForMode()).
    tabletAuditCatalog (the sixth, added in a LATER pass than the rest of
    this file, see its own "CATALOG CHANGES MODE" section below) has no
    single row shape of its own at all -- it depends on which of 8 real
    `catalogName` values was requested; see server/admin.lua's own
    CATALOG_AUDIT_SOURCES table and html/tablet.js's own
    auditColumnsForCatalog() for the authoritative per-catalog list.

    GATING is asserted as a CONVENIENCE, per html/tablet.js's own THE
    SECURITY RULE -- the real gate (server/admin.lua's IsAuthorizedAdmin)
    is covered by tests/admin_spec.lua, not exercised here. What THIS file
    asserts about gating is narrower and specific to this screen: the
    Audit tab is shown to a viewer holding 'k9.audit' in
    effectivePermissions even when NOT high command -- unlike every other
    admin tab on this page, which is isHighCommand-only.
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
        if (!h) return Promise.reject(new Error('tablet_audit_spec: unhandled NUI callback ' + name));
        return Promise.resolve(jsonResponse(h(body)));
    };
}

const RANK_QUALIFIED_VIEWER = { citizenid: 'SGT1', name: 'Sergeant Rank', isHighCommand: false, effectivePermissions: ['k9.audit'], allowSelfGrant: false };
const NO_AUDIT_VIEWER = { citizenid: 'OFFICER1', name: 'Plain Officer', isHighCommand: false, effectivePermissions: ['k9.certify'], allowSelfGrant: false };
const HIGH_COMMAND_VIEWER = { citizenid: 'HC1', name: 'Chief', isHighCommand: true, effectivePermissions: ['k9.access', 'k9.certify', 'k9.audit', 'k9.givexp'], allowSelfGrant: false };

async function settle(times) {
    for (let i = 0; i < (times || 3); i++) await new Promise((r) => setImmediate(r));
}

function baseHandlers(overrides) {
    return Object.assign({
        'tablet:getTheme': () => ({ ok: true, theme: { primaryColor: '#2563eb', accentColor: '#f59e0b', backgroundColor: '#111827', textColor: '#f9fafb', density: 'comfortable', headerTitle: 'K9 Command Tablet' } }),
    }, overrides || {});
}

async function openTablet(h, extraOpenData) {
    h.postMessage('tablet:open', Object.assign({ auditEnabled: true }, extraOpenData || {}));
    await settle();
}

function findAllTag(root, tag) {
    return findAll(root, (n) => n.tagName === tag);
}

function findInputByPlaceholder(root, placeholder) {
    return findAll(root, (n) => n.tagName === 'input' && n.getAttribute('placeholder') === placeholder)[0];
}

/** Case-insensitive substring search across every element's OWN text node
 * (mirrors findByText's exact-match shape, but for asserting an absence/
 * presence of a phrase inside a longer, templated sentence whose exact
 * numbers vary per test -- e.g. the truncation notice). */
function findByTextIncluding(root, substring) {
    const needle = substring.toLowerCase();
    return findAll(root, (n) => typeof n._textContent === 'string' && n._textContent.toLowerCase().includes(needle));
}

// ======================================================================
// GATING -- unlike every other admin tab, this one is NOT isHighCommand-only
// ======================================================================

t.test('a viewer holding k9.audit but NOT high command still sees the Audit Trail tab', async () => {
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:requestMyRecord': () => ({ ok: true, viewer: RANK_QUALIFIED_VIEWER, certifications: [], xp: null, tierLabel: null, myFeatures: [] }),
        })),
    });
    await openTablet(h);
    t.equals(findByText(h.getRoot(), 'Audit Trail').length, 1);
});

t.test('a viewer with no k9.audit and not high command never sees the tab at all', async () => {
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:requestMyRecord': () => ({ ok: true, viewer: NO_AUDIT_VIEWER, certifications: [], xp: null, tierLabel: null, myFeatures: [] }),
        })),
    });
    await openTablet(h);
    t.equals(findByText(h.getRoot(), 'Audit Trail').length, 0, 'not merely hidden by CSS -- never constructed at all');
});

t.test('high command sees the tab too (qualifies via isHighCommand, same as every other admin tab)', async () => {
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:requestMyRecord': () => ({ ok: true, viewer: HIGH_COMMAND_VIEWER, certifications: [], xp: null, tierLabel: null, myFeatures: [] }),
        })),
    });
    await openTablet(h);
    t.equals(findByText(h.getRoot(), 'Audit Trail').length, 1);
});

// ======================================================================
// FORM SHAPE PER MODE
// ======================================================================

t.test('default mode is Certifications: shows a citizenid input and a limit input, no department/search fields', async () => {
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:requestMyRecord': () => ({ ok: true, viewer: HIGH_COMMAND_VIEWER, certifications: [], xp: null, tierLabel: null, myFeatures: [] }),
        })),
    });
    await openTablet(h);
    findByText(h.getRoot(), 'Audit Trail')[0].click();
    await settle();

    t.isDefined(findInputByPlaceholder(h.getRoot(), 'e.g. ABC12345'), 'citizenid input present');
    t.equals(findAllTag(h.getRoot(), 'select').length, 0, 'no mode/department select for the cert mode');
    const numberInput = findAll(h.getRoot(), (n) => n.tagName === 'input' && n.getAttribute('type') === 'number')[0];
    t.isDefined(numberInput, 'limit input present');
    t.equals(numberInput.value, '20', 'default limit');
});

t.test('XP mode: citizenid input only, NO limit input (single-row point lookup)', async () => {
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:requestMyRecord': () => ({ ok: true, viewer: HIGH_COMMAND_VIEWER, certifications: [], xp: null, tierLabel: null, myFeatures: [] }),
        })),
    });
    await openTablet(h);
    findByText(h.getRoot(), 'Audit Trail')[0].click();
    await settle();
    findByText(h.getRoot(), 'XP Snapshot')[0].click();
    await settle();

    t.isDefined(findInputByPlaceholder(h.getRoot(), 'e.g. ABC12345'));
    t.equals(findAll(h.getRoot(), (n) => n.tagName === 'input' && n.getAttribute('type') === 'number').length, 0);
});

t.test('Department Roster mode: a department text input, pre-offered from the VIEWER\'S OWN certifications -- never hardcoded', async () => {
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:requestMyRecord': () => ({
                ok: true, viewer: HIGH_COMMAND_VIEWER,
                certifications: [
                    { departmentKey: 'a_brand_new_department_key', departmentLabel: 'Made Up PD', active: true, grantedBy: 'X' },
                ],
                xp: null, tierLabel: null, myFeatures: [],
            }),
        })),
    });
    await openTablet(h);
    findByText(h.getRoot(), 'Audit Trail')[0].click();
    await settle();
    findByText(h.getRoot(), 'Department Roster')[0].click();
    await settle();

    t.isDefined(findInputByPlaceholder(h.getRoot(), 'e.g. police'), 'department text input');
    const options = findAll(h.getRoot(), (n) => n.tagName === 'option' && n.getAttribute('value') === 'a_brand_new_department_key');
    t.isTrue(options.length >= 1, 'a department this test invented on the fly appears as a suggestion -- proves no hardcoded list');
});

t.test('Search mode: sub-mode select with 4 options; the Value field hides for "recent" only', async () => {
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:requestMyRecord': () => ({ ok: true, viewer: HIGH_COMMAND_VIEWER, certifications: [], xp: null, tierLabel: null, myFeatures: [] }),
        })),
    });
    await openTablet(h);
    findByText(h.getRoot(), 'Audit Trail')[0].click();
    await settle();
    findByText(h.getRoot(), 'Search Log')[0].click();
    await settle();

    const select = findAllTag(h.getRoot(), 'select')[0];
    t.isDefined(select, 'search sub-mode select present');
    t.isDefined(findInputByPlaceholder(h.getRoot(), 'e.g. ABC12345'), 'value field shown for the default sub-mode (officer)');

    select.value = 'recent';
    select._dispatch('input', { target: select });
    await settle();
    t.isUndefined(findInputByPlaceholder(h.getRoot(), 'e.g. ABC12345'), 'value field hidden for recent');
    t.isUndefined(findInputByPlaceholder(h.getRoot(), 'e.g. ABC123'), 'plate placeholder also hidden for recent');

    select.value = 'plate';
    select._dispatch('input', { target: select });
    await settle();
    t.isDefined(findInputByPlaceholder(h.getRoot(), 'e.g. ABC123'), 'plate-shaped placeholder for the plate sub-mode');
});

// ======================================================================
// VALIDATION (client-side convenience -- see this file's own header)
// ======================================================================

t.test('Run Query with a blank citizenid shows invalid_args WITHOUT ever calling the server', async () => {
    let calls = 0;
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:requestMyRecord': () => ({ ok: true, viewer: HIGH_COMMAND_VIEWER, certifications: [], xp: null, tierLabel: null, myFeatures: [] }),
            'tablet:auditCert': () => { calls++; return { ok: true, rows: [], label: 'x' }; },
        })),
    });
    await openTablet(h);
    findByText(h.getRoot(), 'Audit Trail')[0].click();
    await settle();
    findByText(h.getRoot(), 'Run Query')[0].click();
    await settle();

    t.equals(calls, 0, 'no round trip for an obviously-incomplete form');
    t.isTrue(findByText(h.getRoot(), 'That query is invalid -- check the required field and try again.').length >= 1);
});

// ======================================================================
// SUBMIT PAYLOAD SHAPE PER MODE
// ======================================================================

t.test('Certifications: sends {targetCitizenId, limit}, renders rows with Yes/No and N/A', async () => {
    let sentBody = null;
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:requestMyRecord': () => ({ ok: true, viewer: HIGH_COMMAND_VIEWER, certifications: [], xp: null, tierLabel: null, myFeatures: [] }),
            'tablet:auditCert': (body) => {
                sentBody = body;
                return {
                    ok: true,
                    label: 'Certification history for ABC123',
                    rows: [
                        { job: 'police', active: 1, granted_by: 'SGT1', granted_at: '2026-01-01 00:00:00', revoked_by: null, revoked_at: null },
                    ],
                };
            },
        })),
    });
    await openTablet(h);
    findByText(h.getRoot(), 'Audit Trail')[0].click();
    await settle();

    findInputByPlaceholder(h.getRoot(), 'e.g. ABC12345').typeValue('ABC123');
    findByText(h.getRoot(), 'Run Query')[0].click();
    await settle();

    t.isDefined(sentBody);
    t.equals(sentBody.targetCitizenId, 'ABC123');
    t.equals(sentBody.limit, 20);

    t.isTrue(findByText(h.getRoot(), 'Certification history for ABC123').length >= 1, 'server label rendered verbatim');
    t.isTrue(findByText(h.getRoot(), 'police').length >= 1);
    t.isTrue(findByText(h.getRoot(), 'Yes').length >= 1, 'active=1 renders as Yes');
    t.isTrue(findByText(h.getRoot(), 'N/A').length >= 2, 'null revoked_by/revoked_at both render as N/A, never "null"');
});

t.test('a typed limit above the server hard cap is clamped to 100 client-side before sending', async () => {
    let sentBody = null;
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:requestMyRecord': () => ({ ok: true, viewer: HIGH_COMMAND_VIEWER, certifications: [], xp: null, tierLabel: null, myFeatures: [] }),
            'tablet:auditCert': (body) => { sentBody = body; return { ok: true, rows: [], label: '' }; },
        })),
    });
    await openTablet(h);
    findByText(h.getRoot(), 'Audit Trail')[0].click();
    await settle();

    findInputByPlaceholder(h.getRoot(), 'e.g. ABC12345').typeValue('ABC123');
    const numberInput = findAll(h.getRoot(), (n) => n.tagName === 'input' && n.getAttribute('type') === 'number')[0];
    numberInput.typeValue('500');
    findByText(h.getRoot(), 'Run Query')[0].click();
    await settle();

    t.equals(sentBody.limit, 100, 'clamped to AUDIT_LIMIT_MAX, never sent as the raw 500');
});

t.test('XP mode: sends {targetCitizenId} only, no limit key at all', async () => {
    let sentBody = null;
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:requestMyRecord': () => ({ ok: true, viewer: HIGH_COMMAND_VIEWER, certifications: [], xp: null, tierLabel: null, myFeatures: [] }),
            'tablet:auditXp': (body) => { sentBody = body; return { ok: true, rows: [{ xp: 1234, updated_at: '2026-01-01 00:00:00' }], label: 'XP snapshot for ABC123' }; },
        })),
    });
    await openTablet(h);
    findByText(h.getRoot(), 'Audit Trail')[0].click();
    await settle();
    findByText(h.getRoot(), 'XP Snapshot')[0].click();
    await settle();

    findInputByPlaceholder(h.getRoot(), 'e.g. ABC12345').typeValue('ABC123');
    findByText(h.getRoot(), 'Run Query')[0].click();
    await settle();

    t.isDefined(sentBody);
    t.equals(sentBody.targetCitizenId, 'ABC123');
    t.isUndefined(sentBody.limit, 'no limit key sent for the xp mode');
    t.isTrue(findByText(h.getRoot(), '1234').length >= 1);
});

t.test('Department Roster: sends {departmentKey, limit}', async () => {
    let sentBody = null;
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:requestMyRecord': () => ({ ok: true, viewer: HIGH_COMMAND_VIEWER, certifications: [], xp: null, tierLabel: null, myFeatures: [] }),
            'tablet:auditDept': (body) => { sentBody = body; return { ok: true, rows: [{ citizenid: 'ABC123', granted_by: 'SGT1', granted_at: '2026-01-01' }], label: 'Roster for police' }; },
        })),
    });
    await openTablet(h);
    findByText(h.getRoot(), 'Audit Trail')[0].click();
    await settle();
    findByText(h.getRoot(), 'Department Roster')[0].click();
    await settle();

    findInputByPlaceholder(h.getRoot(), 'e.g. police').typeValue('police');
    findByText(h.getRoot(), 'Run Query')[0].click();
    await settle();

    t.equals(sentBody.departmentKey, 'police');
    t.equals(sentBody.limit, 20);
});

t.test('Search mode "recent": sends {mode, limit} with NO value key at all', async () => {
    let sentBody = null;
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:requestMyRecord': () => ({ ok: true, viewer: HIGH_COMMAND_VIEWER, certifications: [], xp: null, tierLabel: null, myFeatures: [] }),
            'tablet:auditSearch': (body) => { sentBody = body; return { ok: true, rows: [], label: 'Most recent searches' }; },
        })),
    });
    await openTablet(h);
    findByText(h.getRoot(), 'Audit Trail')[0].click();
    await settle();
    findByText(h.getRoot(), 'Search Log')[0].click();
    await settle();

    const select = findAllTag(h.getRoot(), 'select')[0];
    select.value = 'recent';
    select._dispatch('input', { target: select });
    await settle();

    findByText(h.getRoot(), 'Run Query')[0].click();
    await settle();

    t.equals(sentBody.mode, 'recent');
    t.equals(sentBody.limit, 20);
    t.isUndefined(sentBody.value, 'no value key sent for recent -- client/tablet.lua fills the wire value itself');
});

t.test('Search mode "plate": sends {mode:"plate", value, limit}', async () => {
    let sentBody = null;
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:requestMyRecord': () => ({ ok: true, viewer: HIGH_COMMAND_VIEWER, certifications: [], xp: null, tierLabel: null, myFeatures: [] }),
            'tablet:auditSearch': (body) => { sentBody = body; return { ok: true, rows: [], label: '' }; },
        })),
    });
    await openTablet(h);
    findByText(h.getRoot(), 'Audit Trail')[0].click();
    await settle();
    findByText(h.getRoot(), 'Search Log')[0].click();
    await settle();

    const select = findAllTag(h.getRoot(), 'select')[0];
    select.value = 'plate';
    select._dispatch('input', { target: select });
    await settle();

    findInputByPlaceholder(h.getRoot(), 'e.g. ABC123').typeValue('ABC 123');
    findByText(h.getRoot(), 'Run Query')[0].click();
    await settle();

    t.equals(sentBody.mode, 'plate');
    t.equals(sentBody.value, 'ABC 123');
    t.equals(sentBody.limit, 20);
});

// ======================================================================
// CATALOG CHANGES MODE -- the sixth mode, bridging server/admin.lua's own
// 'qbx_k9unit:server:tabletAuditCatalog' via tablet:auditCatalog. Unlike
// the five modes above, this one has NO single fixed row shape -- it
// depends on which of the 8 real catalogName values was selected (see
// html/tablet.js's own auditColumnsForCatalog()). These tests cover the
// mode switch/select itself, the {catalogName, limit} payload shape, and
// two representative column shapes (the shared action/key/detail/changed-by/
// changed-at envelope six of the eight catalogs share, and tabletThemes'
// genuinely different one) -- not all eight, which would only be
// re-testing auditColumnsForCatalog()'s own per-case column list rather
// than this screen's actual behavior.
// ======================================================================

t.test('Catalog Changes mode: a catalog select with 9 options, defaulting to Roles; no citizenid/department/search fields', async () => {
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:requestMyRecord': () => ({ ok: true, viewer: HIGH_COMMAND_VIEWER, certifications: [], xp: null, tierLabel: null, myFeatures: [] }),
        })),
    });
    await openTablet(h);
    findByText(h.getRoot(), 'Audit Trail')[0].click();
    await settle();
    findByText(h.getRoot(), 'Catalog Changes')[0].click();
    await settle();

    const select = findAllTag(h.getRoot(), 'select')[0];
    t.isDefined(select, 'catalog select present');
    t.equals(select.value, 'roles', 'defaults to the first entry (Roles), same convention as auditSearchMode\'s own default');
    t.equals(findAll(select, (n) => n.tagName === 'option').length, 9, 'all 9 real catalogs offered');
    t.isUndefined(findInputByPlaceholder(h.getRoot(), 'e.g. ABC12345'), 'no citizenid field for this mode');
});

t.test('Catalog Changes mode: sends {catalogName, limit}, renders the shared action/key/detail/changed-by/changed-at columns for roles', async () => {
    let sentBody = null;
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:requestMyRecord': () => ({ ok: true, viewer: HIGH_COMMAND_VIEWER, certifications: [], xp: null, tierLabel: null, myFeatures: [] }),
            'tablet:auditCatalog': (body) => {
                sentBody = body;
                return {
                    ok: true,
                    label: 'Role changes (created, edited, deleted)',
                    rows: [
                        { action: 'role_update', role_key: 'master', detail: 'label=Master xp=1200 unlocks=bite_takedown', changed_by: 'HC1', changed_by_name: 'Chief', changed_at: '2026-01-01 00:00:00' },
                    ],
                };
            },
        })),
    });
    await openTablet(h);
    findByText(h.getRoot(), 'Audit Trail')[0].click();
    await settle();
    findByText(h.getRoot(), 'Catalog Changes')[0].click();
    await settle();
    findByText(h.getRoot(), 'Run Query')[0].click();
    await settle();

    t.isDefined(sentBody);
    t.equals(sentBody.catalogName, 'roles');
    t.equals(sentBody.limit, 20);
    t.isTrue(findByText(h.getRoot(), 'Role changes (created, edited, deleted)').length >= 1, 'server label rendered verbatim');
    t.isTrue(findByText(h.getRoot(), 'role_update').length >= 1);
    t.isTrue(findByText(h.getRoot(), 'master').length >= 1);
    t.isTrue(findByText(h.getRoot(), 'label=Master xp=1200 unlocks=bite_takedown').length >= 1);
    t.isTrue(findByText(h.getRoot(), 'Chief (HC1)').length >= 1, 'changed_by pairs the raw id with its resolved name, same as every other audit mode');
});

t.test('Catalog Changes mode: selecting a different catalog sends that catalogName and renders ITS OWN column shape (tabletThemes, not the action/key/detail shape)', async () => {
    let sentBody = null;
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:requestMyRecord': () => ({ ok: true, viewer: HIGH_COMMAND_VIEWER, certifications: [], xp: null, tierLabel: null, myFeatures: [] }),
            'tablet:auditCatalog': (body) => {
                sentBody = body;
                return {
                    ok: true,
                    label: 'Tablet theme audit trail',
                    rows: [
                        { primary_color: '#2563eb', accent_color: '#f59e0b', background_color: '#111827', text_color: '#f9fafb', density: 'comfortable', header_title: 'Bark Squad HQ', changed_by: 'HC1', changed_at: '2026-01-02 00:00:00' },
                    ],
                };
            },
        })),
    });
    await openTablet(h);
    findByText(h.getRoot(), 'Audit Trail')[0].click();
    await settle();
    findByText(h.getRoot(), 'Catalog Changes')[0].click();
    await settle();

    const select = findAllTag(h.getRoot(), 'select')[0];
    select.value = 'tabletThemes';
    select._dispatch('input', { target: select });
    await settle();

    findByText(h.getRoot(), 'Run Query')[0].click();
    await settle();

    t.equals(sentBody.catalogName, 'tabletThemes');
    t.isTrue(findByText(h.getRoot(), 'Bark Squad HQ').length >= 1, 'theme-specific field rendered');
    t.isTrue(findByText(h.getRoot(), 'comfortable').length >= 1);
    t.equals(findByText(h.getRoot(), 'update').length, 0, 'no leftover certTiers-shaped column data from the previous test\'s row shape');
});

t.test('Catalog Changes mode: an empty result still shows the shared empty-state note, not a blank/broken table', async () => {
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:requestMyRecord': () => ({ ok: true, viewer: HIGH_COMMAND_VIEWER, certifications: [], xp: null, tierLabel: null, myFeatures: [] }),
            'tablet:auditCatalog': () => ({ ok: true, rows: [], label: 'Certification tier catalog audit trail' }),
        })),
    });
    await openTablet(h);
    findByText(h.getRoot(), 'Audit Trail')[0].click();
    await settle();
    findByText(h.getRoot(), 'Catalog Changes')[0].click();
    await settle();
    findByText(h.getRoot(), 'Run Query')[0].click();
    await settle();

    t.isTrue(findByText(h.getRoot(), 'No matching records found.').length >= 1);
});

// ======================================================================
// EMPTY / ERROR STATES -- a failed callback must never leave the screen blank
// ======================================================================

t.test('an empty result set shows the empty-state note, not a blank panel', async () => {
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:requestMyRecord': () => ({ ok: true, viewer: HIGH_COMMAND_VIEWER, certifications: [], xp: null, tierLabel: null, myFeatures: [] }),
            'tablet:auditCert': () => ({ ok: true, rows: [], label: 'Certification history for ZZZ999' }),
        })),
    });
    await openTablet(h);
    findByText(h.getRoot(), 'Audit Trail')[0].click();
    await settle();
    findInputByPlaceholder(h.getRoot(), 'e.g. ABC12345').typeValue('ZZZ999');
    findByText(h.getRoot(), 'Run Query')[0].click();
    await settle();

    t.isTrue(findByText(h.getRoot(), 'No matching records found.').length >= 1);
});

t.test('not_authorized renders a clear message, not a blank screen or a raw error code', async () => {
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:requestMyRecord': () => ({ ok: true, viewer: RANK_QUALIFIED_VIEWER, certifications: [], xp: null, tierLabel: null, myFeatures: [] }),
            'tablet:auditCert': () => ({ ok: false, error: 'not_authorized', message: 'You are not authorized to view this.' }),
        })),
    });
    await openTablet(h);
    findByText(h.getRoot(), 'Audit Trail')[0].click();
    await settle();
    findInputByPlaceholder(h.getRoot(), 'e.g. ABC12345').typeValue('ABC123');
    findByText(h.getRoot(), 'Run Query')[0].click();
    await settle();

    t.isTrue(findByText(h.getRoot(), 'You are not authorized to view this.').length >= 1, 'server message forwarded verbatim');
});

t.test('rate_limited (no message) falls back to this screen\'s own explanatory copy', async () => {
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:requestMyRecord': () => ({ ok: true, viewer: HIGH_COMMAND_VIEWER, certifications: [], xp: null, tierLabel: null, myFeatures: [] }),
            'tablet:auditCert': () => ({ ok: false, error: 'rate_limited' }),
        })),
    });
    await openTablet(h);
    findByText(h.getRoot(), 'Audit Trail')[0].click();
    await settle();
    findInputByPlaceholder(h.getRoot(), 'e.g. ABC12345').typeValue('ABC123');
    findByText(h.getRoot(), 'Run Query')[0].click();
    await settle();

    t.isTrue(findByText(h.getRoot(), 'Please wait a moment before running another audit query.').length >= 1);
});

t.test('before any query has ever been run, this screen shows a prompt, never a blank panel', async () => {
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:requestMyRecord': () => ({ ok: true, viewer: HIGH_COMMAND_VIEWER, certifications: [], xp: null, tierLabel: null, myFeatures: [] }),
        })),
    });
    await openTablet(h);
    findByText(h.getRoot(), 'Audit Trail')[0].click();
    await settle();
    t.isTrue(findByText(h.getRoot(), 'Fill in the fields above and press "Run Query".').length >= 1);
});

// ======================================================================
// auditEnabled=false -- disables the query controls rather than a confusing generic timeout
// ======================================================================

t.test('auditEnabled=false shows the disabled note and disables Run Query', async () => {
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:requestMyRecord': () => ({ ok: true, viewer: HIGH_COMMAND_VIEWER, certifications: [], xp: null, tierLabel: null, myFeatures: [] }),
        })),
    });
    h.postMessage('tablet:open', { auditEnabled: false });
    await settle();
    findByText(h.getRoot(), 'Audit Trail')[0].click();
    await settle();

    t.isTrue(findByText(h.getRoot(), 'The audit command surface is disabled server-wide. Queries cannot be run until it is re-enabled.').length >= 1);
    const runBtn = findByText(h.getRoot(), 'Run Query')[0];
    t.isDefined(runBtn.getAttribute('disabled'));
});

// ======================================================================
// cap / limit / truncated (this pass) -- server/admin.lua's five
// tabletAudit* callbacks now serve their real HARD_MAX_RESULTS back as
// `cap` on every success response (plus `limit`/`truncated` on the four
// that take a limit argument), closing the gap where this page used to
// carry its own hardcoded, driftable guess of that same number
// (AUDIT_LIMIT_MAX_FALLBACK, now used ONLY before any query has ever
// succeeded, or when a response is missing the field entirely).
// ======================================================================

t.test('a served cap reaches the page: the limit input\'s max attribute adopts the server-reported cap, not the hardcoded fallback', async () => {
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:requestMyRecord': () => ({ ok: true, viewer: HIGH_COMMAND_VIEWER, certifications: [], xp: null, tierLabel: null, myFeatures: [] }),
            'tablet:auditCert': () => ({ ok: true, rows: [], label: '', cap: 60, limit: 20, truncated: false }),
        })),
    });
    await openTablet(h);
    findByText(h.getRoot(), 'Audit Trail')[0].click();
    await settle();

    let numberInput = findAll(h.getRoot(), (n) => n.tagName === 'input' && n.getAttribute('type') === 'number')[0];
    t.equals(numberInput.getAttribute('max'), '100', 'before any query has ever succeeded, the max hint is still the hardcoded fallback');

    findInputByPlaceholder(h.getRoot(), 'e.g. ABC12345').typeValue('ABC123');
    findByText(h.getRoot(), 'Run Query')[0].click();
    await settle();

    numberInput = findAll(h.getRoot(), (n) => n.tagName === 'input' && n.getAttribute('type') === 'number')[0];
    t.equals(numberInput.getAttribute('max'), '60', 'the REAL served cap (60) now drives the max hint, not the old hardcoded 100');
});

t.test('the served cap also drives the CLIENT-SIDE clamp, not only the input\'s max hint: a typed value above the served cap is clamped to it before being sent', async () => {
    let sentBody = null;
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:requestMyRecord': () => ({ ok: true, viewer: HIGH_COMMAND_VIEWER, certifications: [], xp: null, tierLabel: null, myFeatures: [] }),
            'tablet:auditCert': (body) => { sentBody = body; return { ok: true, rows: [], label: '', cap: 60, limit: Math.min(body.limit, 60), truncated: body.limit > 60 }; },
        })),
    });
    await openTablet(h);
    findByText(h.getRoot(), 'Audit Trail')[0].click();
    await settle();

    findInputByPlaceholder(h.getRoot(), 'e.g. ABC12345').typeValue('ABC123');
    findByText(h.getRoot(), 'Run Query')[0].click(); // first query: learns cap=60 (default limit 20 is well under both 60 and 100, so this call itself is not truncated)
    await settle();

    findInputByPlaceholder(h.getRoot(), 'e.g. ABC12345').typeValue('ABC123');
    let numberInput = findAll(h.getRoot(), (n) => n.tagName === 'input' && n.getAttribute('type') === 'number')[0];
    numberInput.typeValue('90'); // above the served cap (60) but below the old hardcoded fallback (100)
    findByText(h.getRoot(), 'Run Query')[0].click();
    await settle();

    t.equals(sentBody.limit, 60, 'clamped client-side to the SERVED cap (60), never the stale 100 fallback');
});

t.test('TRUNCATION NOTICE: "you asked for X, here are the first Y" is shown to the operator when the server reports truncated=true', async () => {
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:requestMyRecord': () => ({ ok: true, viewer: HIGH_COMMAND_VIEWER, certifications: [], xp: null, tierLabel: null, myFeatures: [] }),
            'tablet:auditCert': () => ({ ok: true, rows: [{ job: 'police', active: 1, granted_by: 'SGT1', granted_at: 't', revoked_by: null, revoked_at: null }], label: 'Certification history for ABC123', cap: 60, limit: 60, truncated: true }),
        })),
    });
    await openTablet(h);
    findByText(h.getRoot(), 'Audit Trail')[0].click();
    await settle();

    findInputByPlaceholder(h.getRoot(), 'e.g. ABC12345').typeValue('ABC123');
    const numberInput = findAll(h.getRoot(), (n) => n.tagName === 'input' && n.getAttribute('type') === 'number')[0];
    numberInput.typeValue('20'); // the actual number THIS PAGE sent -- the notice must echo the request THIS PAGE made, not the server's clamped result
    findByText(h.getRoot(), 'Run Query')[0].click();
    await settle();

    t.isTrue(findByText(h.getRoot(), 'You asked for 20 results; the server limit is 60, so only the first 60 are shown.').length >= 1, 'the operator is told the truncation happened, not left with a silently short list');
});

t.test('no truncation notice appears when the server does not report truncated=true', async () => {
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:requestMyRecord': () => ({ ok: true, viewer: HIGH_COMMAND_VIEWER, certifications: [], xp: null, tierLabel: null, myFeatures: [] }),
            'tablet:auditCert': () => ({ ok: true, rows: [], label: 'Certification history for ABC123', cap: 100, limit: 20, truncated: false }),
        })),
    });
    await openTablet(h);
    findByText(h.getRoot(), 'Audit Trail')[0].click();
    await settle();
    findInputByPlaceholder(h.getRoot(), 'e.g. ABC12345').typeValue('ABC123');
    findByText(h.getRoot(), 'Run Query')[0].click();
    await settle();

    t.equals(findByTextIncluding(h.getRoot(), 'you asked for').length, 0);
});

t.test('FALLBACK, MADE OBVIOUS: a response predating this pass (no cap/limit/truncated fields at all) does not crash, and the input keeps using the hardcoded fallback (100), not some derived garbage value', async () => {
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:requestMyRecord': () => ({ ok: true, viewer: HIGH_COMMAND_VIEWER, certifications: [], xp: null, tierLabel: null, myFeatures: [] }),
            'tablet:auditCert': () => ({ ok: true, rows: [], label: 'Certification history for ABC123' }), // no cap, no limit, no truncated -- an old server build
        })),
    });
    await openTablet(h);
    findByText(h.getRoot(), 'Audit Trail')[0].click();
    await settle();
    findInputByPlaceholder(h.getRoot(), 'e.g. ABC12345').typeValue('ABC123');
    findByText(h.getRoot(), 'Run Query')[0].click();
    await settle();

    t.isTrue(findByText(h.getRoot(), 'Certification history for ABC123').length >= 1, 'the rest of the response still renders fine with the new fields absent');
    t.equals(findByTextIncluding(h.getRoot(), 'you asked for').length, 0, 'no truncation notice fabricated from a response that never claimed one');

    const numberInput = findAll(h.getRoot(), (n) => n.tagName === 'input' && n.getAttribute('type') === 'number')[0];
    t.equals(numberInput.getAttribute('max'), '100', 'still the disclosed hardcoded fallback -- never silently broken by a missing field');
});

t.test('SECURITY: a spurious `cap` field on a not_authorized (failure) response is never adopted -- an unauthorized caller\'s response cannot be used to learn or change the served cap', async () => {
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:requestMyRecord': () => ({ ok: true, viewer: HIGH_COMMAND_VIEWER, certifications: [], xp: null, tierLabel: null, myFeatures: [] }),
            // ok:false but WITH a cap field anyway -- simulates a hostile or buggy
            // server; this page must never read fields off a failure response.
            'tablet:auditCert': () => ({ ok: false, error: 'not_authorized', message: 'You are not authorized to view this.', cap: 5 }),
        })),
    });
    await openTablet(h);
    findByText(h.getRoot(), 'Audit Trail')[0].click();
    await settle();
    findInputByPlaceholder(h.getRoot(), 'e.g. ABC12345').typeValue('ABC123');
    findByText(h.getRoot(), 'Run Query')[0].click();
    await settle();

    t.isTrue(findByText(h.getRoot(), 'You are not authorized to view this.').length >= 1);
    const numberInput = findAll(h.getRoot(), (n) => n.tagName === 'input' && n.getAttribute('type') === 'number')[0];
    t.equals(numberInput.getAttribute('max'), '100', 'the spurious cap=5 on a failure response must never be adopted -- still the fallback, not 5');
});

// ======================================================================
// Bad `limit` shapes -- client-side clampAuditLimit() must agree with
// server/admin.lua's own ClampLimit: every shape below is neutralized to
// something in [AUDIT_LIMIT_MIN, effective cap], never sent raw, and never
// throws.
// ======================================================================

t.test('BAD LIMIT SHAPES: negative, fractional, non-numeric, and (+/-)Infinity are all clamped client-side before being sent, never raw', async () => {
    let sentBody = null;
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:requestMyRecord': () => ({ ok: true, viewer: HIGH_COMMAND_VIEWER, certifications: [], xp: null, tierLabel: null, myFeatures: [] }),
            'tablet:auditCert': (body) => { sentBody = body; return { ok: true, rows: [], label: '', cap: 100, limit: body.limit, truncated: false }; },
        })),
    });
    await openTablet(h);
    findByText(h.getRoot(), 'Audit Trail')[0].click();
    await settle();

    const cases = [
        ['-5', 1],
        ['0', 1],
        ['3.9', 3],
        ['abc', 1],
        ['Infinity', 1],
        ['-Infinity', 1],
        ['', 1],
    ];
    for (const [typed, expected] of cases) {
        findInputByPlaceholder(h.getRoot(), 'e.g. ABC12345').typeValue('ABC123');
        const numberInput = findAll(h.getRoot(), (n) => n.tagName === 'input' && n.getAttribute('type') === 'number')[0];
        numberInput.typeValue(typed);
        findByText(h.getRoot(), 'Run Query')[0].click();
        await settle();
        t.equals(sentBody.limit, expected, 'typed ' + JSON.stringify(typed) + ' must clamp to ' + expected);
    }
});

t.run();
