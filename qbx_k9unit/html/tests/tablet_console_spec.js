/*
    html/tests/tablet_console_spec.js

    Covers the admin "Command Console" surface: the tab only appearing for
    a viewer with at least one effective capability (or high command),
    roster search/truncation, and drilling into a person's summary
    (certify/decertify, Give XP) -- gated per-control on the viewer's OWN
    effectivePermissions, never on isHighCommand alone unless the control
    is genuinely high-command-exclusive. See html/tablet.js's own header
    "THE SECURITY RULE" -- every one of these gates is a convenience; the
    actual authorization is asserted to live entirely server-side, which
    this suite cannot exercise (that's client/tablet.lua's job) but every
    test below is written as if a hidden control could still be reached by
    a modified client, i.e. this suite never treats "the button isn't
    there" as a substitute for "the action is denied".
*/
'use strict';

const t = require('./testkit');
const { createHarness, jsonResponse } = require('./tablet-sandbox');
const { findByText, findByTag, findAll } = require('./tablet-dom-stub');

/** findByText() only matches an EXACT textContent string -- several of the
 * new hint/notice paragraphs below are full sentences, so substring
 * assertions use this instead of a brittle exact-copy-paste of the whole
 * sentence (same helper tablet_help_tab_spec.js already established). */
function findByTextContaining(node, substring) {
    return findAll(node, (n) => typeof n._textContent === 'string' && n._textContent.indexOf(substring) !== -1);
}

function routeFetch(handlers) {
    return function (url, init) {
        const name = url.split('/').pop();
        const body = init && init.body ? JSON.parse(init.body) : undefined;
        const h = handlers[name];
        if (!h) return Promise.reject(new Error('tablet_console_spec: unhandled NUI callback ' + name));
        return Promise.resolve(jsonResponse(h(body)));
    };
}

const PLAIN_MY_RECORD = () => ({
    ok: true,
    viewer: { citizenid: 'VIEWER1', name: 'Officer Viewer', isHighCommand: false, effectivePermissions: [], allowSelfGrant: false },
    certifications: [],
    xp: null,
    tierLabel: null,
    myFeatures: [],
});

async function settle(h, times) {
    for (let i = 0; i < (times || 2); i++) await new Promise((r) => setImmediate(r));
}

t.test('a viewer with NO effective permissions and not high command never sees a Command Console tab at all', async () => {
    const h = createHarness({ fetchImpl: routeFetch({ 'tablet:requestMyRecord': PLAIN_MY_RECORD }) });
    h.postMessage('tablet:open', {});
    await settle(h);
    t.equals(findByText(h.getRoot(), 'Command Console').length, 0, 'the tab is not merely hidden by CSS -- it is never constructed at all');
});

t.test('a viewer holding k9.certify PLUS the k9.audit grant console access requires sees the console tab and can certify/decertify, but not the capability or feature matrix', async () => {
    // OWNER'S DECISION, 2026-08-25 (server/tablet.lua's own
    // CallerHasConsoleAccess, mirrored client-side by canAccessConsole()):
    // console access itself was NARROWED to high command, or an explicit
    // k9.audit grant specifically -- a bare k9.certify (or k9.access) no
    // longer qualifies on its own. This scenario now needs BOTH: k9.audit
    // to reach the console tab at all, and k9.certify to exercise the
    // Certify/Decertify controls this test is actually about -- see
    // tablet_home_spec.js's own sibling pair of tests for the console-
    // access gate in isolation.
    const rosterRow = { citizenid: 'TARGET1', name: 'K9 Rex', departmentLabel: 'Los Santos Police Department', certified: false, xp: 10, tierLabel: 'Recruit K9' };
    const h = createHarness({
        fetchImpl: routeFetch({
            'tablet:requestMyRecord': () => ({
                ok: true,
                viewer: { citizenid: 'VIEWER1', name: 'Officer Viewer', isHighCommand: false, effectivePermissions: ['k9.certify', 'k9.audit'], allowSelfGrant: false },
                certifications: [], xp: null, tierLabel: null, myFeatures: [],
            }),
            'tablet:requestRoster': () => ({ ok: true, rows: [rosterRow], truncated: false }),
            'tablet:requestPersonSummary': () => ({
                ok: true,
                target: { citizenid: 'TARGET1', name: 'K9 Rex' },
                certifications: [{ departmentKey: 'police', departmentLabel: 'Los Santos Police Department', active: false, grantedBy: null }],
                xp: 10, tierLabel: 'Recruit K9',
                permissions: [],
            }),
        }),
    });

    h.postMessage('tablet:open', {});
    await settle(h);
    t.isTrue(findByText(h.getRoot(), 'Command Console').length >= 1, 'console tab exists for a k9.certify holder who ALSO holds the k9.audit grant console access requires, even without isHighCommand');

    findByText(h.getRoot(), 'Command Console')[0].click();
    await settle(h);
    t.isTrue(findByText(h.getRoot(), 'K9 Rex').length >= 1, 'roster row rendered');

    findByText(h.getRoot(), 'Manage')[0].click();
    await settle(h);

    t.isTrue(findByText(h.getRoot(), 'Certify').length >= 1, 'k9.certify holder sees the Certify control');
    t.equals(findByText(h.getRoot(), 'Capabilities').length, 0, 'capability grant/revoke section is high-command only -- absent here');
    t.equals(findByText(h.getRoot(), 'Abilities').length, 0, 'per-person feature matrix is high-command only -- absent here (heading text is shared with My Record\'s own "Abilities" heading, but that only renders on the my_record screen, not here)');
});

t.test('roster search debounces and re-fetches with the typed query', async () => {
    const queriesSeen = [];
    const h = createHarness({
        fetchImpl: routeFetch({
            'tablet:requestMyRecord': () => ({ ok: true, viewer: { citizenid: 'V', name: 'V', isHighCommand: true, effectivePermissions: ['k9.access', 'k9.certify', 'k9.audit', 'k9.givexp'], allowSelfGrant: false }, certifications: [], xp: null, tierLabel: null, myFeatures: [] }),
            'tablet:requestRoster': (body) => { queriesSeen.push(body ? body.query : undefined); return { ok: true, rows: [], truncated: false }; },
        }),
    });

    h.postMessage('tablet:open', {});
    await settle(h);
    findByText(h.getRoot(), 'Command Console')[0].click();
    await settle(h); // initial load with empty query

    const search = findByTag(h.getRoot(), 'input').filter((i) => i.getAttribute('placeholder') === 'Name, citizen ID or server ID...')[0];
    t.isDefined(search, 'search input exists');

    search.typeValue('r');
    search.typeValue('re');
    search.typeValue('rex');
    // Debounce is compressed but still asynchronous -- see tablet-sandbox.js's header.
    await new Promise((r) => setTimeout(r, 40));

    t.equals(queriesSeen[0], '', 'initial load used an empty query');
    t.equals(queriesSeen[queriesSeen.length - 1], 'rex', 'only the FINAL debounced value was ever sent, not one request per keystroke');
    t.isTrue(queriesSeen.length < 4, 'rapid keystrokes were coalesced by the debounce, not fired individually');
});

t.test('a truncated roster shows the server-provided message when present, else a generic fallback', async () => {
    const h = createHarness({
        fetchImpl: routeFetch({
            'tablet:requestMyRecord': () => ({ ok: true, viewer: { citizenid: 'V', name: 'V', isHighCommand: true, effectivePermissions: ['k9.access', 'k9.certify', 'k9.audit', 'k9.givexp'], allowSelfGrant: false }, certifications: [], xp: null, tierLabel: null, myFeatures: [] }),
            'tablet:requestRoster': () => ({ ok: true, rows: [{ citizenid: 'A', name: 'A', departmentLabel: 'Police', certified: true, xp: 0, tierLabel: 'Recruit K9' }], truncated: true, truncatedMessage: 'Showing the first 100 results.' }),
        }),
    });
    h.postMessage('tablet:open', {});
    await settle(h);
    findByText(h.getRoot(), 'Command Console')[0].click();
    await settle(h);
    t.isTrue(findByText(h.getRoot(), 'Showing the first 100 results.').length >= 1, 'server-provided truncation message rendered verbatim');
});

t.test('Certify/Decertify buttons flip per department based on active status, and firing one re-fetches the person summary', async () => {
    let summaryCalls = 0;
    let lastCertifyBody = null;
    const h = createHarness({
        fetchImpl: routeFetch({
            // k9.audit added alongside k9.certify -- console access itself
            // requires it (server/tablet.lua's CallerHasConsoleAccess,
            // mirrored by canAccessConsole()); see this file's own header
            // comment on the 'a viewer holding k9.certify PLUS...' test
            // above for the full write-up.
            'tablet:requestMyRecord': () => ({ ok: true, viewer: { citizenid: 'V', name: 'V', isHighCommand: false, effectivePermissions: ['k9.certify', 'k9.audit'], allowSelfGrant: false }, certifications: [], xp: null, tierLabel: null, myFeatures: [] }),
            'tablet:requestRoster': () => ({ ok: true, rows: [{ citizenid: 'TARGET1', name: 'K9 Rex', departmentLabel: 'Police', certified: false, xp: 0, tierLabel: 'Recruit K9' }], truncated: false }),
            'tablet:requestPersonSummary': () => {
                summaryCalls++;
                return {
                    ok: true,
                    target: { citizenid: 'TARGET1', name: 'K9 Rex' },
                    certifications: [
                        { departmentKey: 'police', departmentLabel: 'Los Santos Police Department', active: false, grantedBy: null },
                        { departmentKey: 'sheriff', departmentLabel: 'Blaine County Sheriff', active: true, grantedBy: 'GRANTER1' },
                    ],
                    xp: 0, tierLabel: 'Recruit K9', permissions: [],
                };
            },
            'tablet:certify': (body) => { lastCertifyBody = body; return { ok: true }; },
        }),
    });

    h.postMessage('tablet:open', {});
    await settle(h);
    findByText(h.getRoot(), 'Command Console')[0].click();
    await settle(h);
    findByText(h.getRoot(), 'Manage')[0].click();
    await settle(h);

    t.equals(summaryCalls, 1);
    t.equals(findByText(h.getRoot(), 'Certify').length, 1, 'exactly one Certify control -- for the department NOT held');
    t.equals(findByText(h.getRoot(), 'Decertify').length, 1, 'exactly one Decertify control -- for the department already held');
    t.isTrue(findByText(h.getRoot(), 'GRANTER1').length >= 1, 'granted-by citizenid shown for the active certification');

    findByText(h.getRoot(), 'Certify')[0].click();
    await new Promise((r) => setTimeout(r, 30));

    t.equals(lastCertifyBody.targetCitizenId, 'TARGET1');
    t.equals(lastCertifyBody.departmentKey, 'police');
    t.equals(summaryCalls, 2, 'person summary is re-fetched after certifying -- never trusts an optimistic local flip');
});

t.test('Decertify requires a second confirming click before firing the request', async () => {
    let decertifyCalls = 0;
    const h = createHarness({
        fetchImpl: routeFetch({
            // k9.audit added alongside k9.certify -- console access itself
            // requires it; see this file's own header comment on the
            // 'a viewer holding k9.certify PLUS...' test above.
            'tablet:requestMyRecord': () => ({ ok: true, viewer: { citizenid: 'V', name: 'V', isHighCommand: false, effectivePermissions: ['k9.certify', 'k9.audit'], allowSelfGrant: false }, certifications: [], xp: null, tierLabel: null, myFeatures: [] }),
            'tablet:requestRoster': () => ({ ok: true, rows: [{ citizenid: 'TARGET1', name: 'K9 Rex', departmentLabel: 'Police', certified: true, xp: 0, tierLabel: 'Recruit K9' }], truncated: false }),
            'tablet:requestPersonSummary': () => ({ ok: true, target: { citizenid: 'TARGET1', name: 'K9 Rex' }, certifications: [{ departmentKey: 'police', departmentLabel: 'Police', active: true, grantedBy: null }], xp: 0, tierLabel: 'Recruit K9', permissions: [] }),
            'tablet:decertify': () => { decertifyCalls++; return { ok: true }; },
        }),
    });

    h.postMessage('tablet:open', {});
    await settle(h);
    findByText(h.getRoot(), 'Command Console')[0].click();
    await settle(h);
    findByText(h.getRoot(), 'Manage')[0].click();
    await settle(h);

    const decertifyBtn = findByText(h.getRoot(), 'Decertify')[0];
    t.isDefined(decertifyBtn);
    decertifyBtn.click();
    t.equals(decertifyCalls, 0, 'first click only arms the confirmation, does not fire yet');
    t.equals(decertifyBtn._textContent, 'Confirm?', 'button label flips to the confirm prompt');

    decertifyBtn.click();
    await new Promise((r) => setTimeout(r, 30));
    t.equals(decertifyCalls, 1, 'second click within the window fires the actual request');
});

t.test('Give XP is only offered to a viewer holding k9.givexp, and disables self-targeting when allowSelfGrant is false', async () => {
    const h = createHarness({
        fetchImpl: routeFetch({
            'tablet:requestMyRecord': () => ({ ok: true, viewer: { citizenid: 'SELF1', name: 'V', isHighCommand: true, effectivePermissions: ['k9.givexp'], allowSelfGrant: false }, certifications: [], xp: null, tierLabel: null, myFeatures: [] }),
            'tablet:requestRoster': () => ({ ok: true, rows: [{ citizenid: 'SELF1', name: 'Self', departmentLabel: 'Police', certified: true, xp: 0, tierLabel: 'Recruit K9' }], truncated: false }),
            'tablet:requestPersonSummary': () => ({ ok: true, target: { citizenid: 'SELF1', name: 'Self' }, certifications: [], xp: 0, tierLabel: 'Recruit K9', permissions: [] }),
        }),
    });
    h.postMessage('tablet:open', {});
    await settle(h);
    findByText(h.getRoot(), 'Command Console')[0].click();
    await settle(h);
    findByText(h.getRoot(), 'Manage')[0].click();
    await settle(h);

    t.equals(findByText(h.getRoot(), 'Give XP').length, 1, 'give-XP control rendered for a k9.givexp holder');
    const giveBtn = findByText(h.getRoot(), 'Give XP')[0];
    t.equals(giveBtn.getAttribute('disabled'), 'disabled', 'self-targeted Give XP is disabled client-side when allowSelfGrant is false (a UX convenience -- the server independently enforces the real rule)');
});

// ============================================================================
// WORKFLOW AUDIT FINDING #1, 2026-08-26 -- a viewer holding ONLY
// 'k9.certify' or 'k9.givexp' (no 'k9.audit', not high command) now gets a
// NARROWED path into the Console tab: the "open by exact citizen ID" box
// and the Person screen it leads to, never the roster search/listing
// (that stays 'k9.audit'/high-command only -- server/tablet.lua's
// CallerHasConsoleAccess, deliberately unchanged; see this suite's own
// header note on "written as if a hidden control could still be reached").
// ============================================================================

t.test('WORKFLOW AUDIT #1: a viewer holding ONLY k9.certify (no k9.audit, not high command) sees the Console tab, but a NARROWED screen -- no search bar, no roster table -- and can still open and certify a specific person by exact citizen ID', async () => {
    let rosterCalls = 0;
    const h = createHarness({
        fetchImpl: routeFetch({
            'tablet:requestMyRecord': () => ({
                ok: true,
                viewer: { citizenid: 'CERTONLY1', name: 'Sergeant Certifier', isHighCommand: false, effectivePermissions: ['k9.certify'], allowSelfGrant: false },
                certifications: [], xp: null, tierLabel: null, myFeatures: [],
            }),
            'tablet:requestRoster': () => { rosterCalls++; return { ok: true, rows: [], truncated: false }; },
            'tablet:requestPersonSummary': () => ({
                ok: true,
                target: { citizenid: 'TARGET9', name: 'New Recruit' },
                certifications: [{ departmentKey: 'police', departmentLabel: 'Los Santos Police Department', active: false, grantedBy: null }],
                xp: 0, tierLabel: 'Recruit K9', permissions: [],
            }),
        }),
    });

    h.postMessage('tablet:open', {});
    await settle(h);
    t.isTrue(findByText(h.getRoot(), 'Command Console').length >= 1, 'the Console tab is now reachable for a bare k9.certify holder');

    findByText(h.getRoot(), 'Command Console')[0].click();
    await settle(h);

    // NARROWED: no search bar, no roster table, no refresh button -- see
    // buildConsoleScreen()'s own fullAccess branch.
    const searchInputs = findByTag(h.getRoot(), 'input').filter((i) => i.getAttribute('placeholder') && i.getAttribute('placeholder').indexOf('Search by name') !== -1);
    t.equals(searchInputs.length, 0, 'the roster search bar is absent for this viewer');
    t.equals(findByText(h.getRoot(), 'Refresh').length, 0, 'the roster refresh button is absent too -- there is no roster to refresh');
    t.equals(rosterCalls, 0, 'tablet:requestRoster is never called for this viewer -- not even once, on tab open');

    // The narrowed-access notice explains why, in plain language.
    t.isTrue(findByTextContaining(h.getRoot(), 'Browsing or searching the full roster needs the Audit capability or High Command').length >= 1);

    // The "open by exact citizen ID" box is still fully present and usable.
    const idInput = findByTag(h.getRoot(), 'input').filter((i) => i.getAttribute('placeholder') === 'Name, citizen ID or server ID...')[0];
    t.isDefined(idInput, 'the open-by-ID input is present for this viewer');
    idInput.typeValue('TARGET9');
    findByText(h.getRoot(), 'Open')[0].click();
    await settle(h);

    t.isTrue(findByText(h.getRoot(), 'New Recruit').length >= 1, 'the Person screen opened for the typed citizenid');
    t.isTrue(findByText(h.getRoot(), 'Certify').length >= 1, 'this viewer\'s own k9.certify capability still controls what they can DO on the Person screen, unchanged by how they reached it');
    t.equals(rosterCalls, 0, 'still never called tablet:requestRoster, even after opening a person');
});

t.test('WORKFLOW AUDIT #1: a viewer holding ONLY k9.givexp (no k9.audit, not high command) reaches the same narrowed Console and sees Give XP, not Certify', async () => {
    const h = createHarness({
        fetchImpl: routeFetch({
            'tablet:requestMyRecord': () => ({
                ok: true,
                viewer: { citizenid: 'XPONLY1', name: 'XP Granter', isHighCommand: false, effectivePermissions: ['k9.givexp'], allowSelfGrant: false },
                certifications: [], xp: null, tierLabel: null, myFeatures: [],
            }),
            'tablet:requestPersonSummary': () => ({
                ok: true,
                target: { citizenid: 'TARGET10', name: 'Existing K9' },
                certifications: [], xp: 0, tierLabel: 'Recruit K9', permissions: [],
            }),
        }),
    });

    h.postMessage('tablet:open', {});
    await settle(h);
    findByText(h.getRoot(), 'Command Console')[0].click();
    await settle(h);

    const idInput = findByTag(h.getRoot(), 'input').filter((i) => i.getAttribute('placeholder') === 'Name, citizen ID or server ID...')[0];
    idInput.typeValue('TARGET10');
    findByText(h.getRoot(), 'Open')[0].click();
    await settle(h);

    t.equals(findByText(h.getRoot(), 'Give XP').length, 1, 'k9.givexp holder sees the Give XP control on the person they opened');
    t.equals(findByText(h.getRoot(), 'Certify').length, 0, 'but not Certify -- this viewer holds no k9.certify capability');
});

t.test('WORKFLOW AUDIT #1: a viewer with NEITHER k9.certify/k9.givexp NOR k9.audit still never sees the Console tab at all -- the widening is specific, not "any capability"', async () => {
    const h = createHarness({
        fetchImpl: routeFetch({
            'tablet:requestMyRecord': () => ({
                ok: true,
                viewer: { citizenid: 'PLAINHANDLER1', name: 'Plain Handler', isHighCommand: false, effectivePermissions: ['k9.access'], allowSelfGrant: false },
                certifications: [], xp: null, tierLabel: null, myFeatures: [],
            }),
        }),
    });
    h.postMessage('tablet:open', {});
    await settle(h);
    t.equals(findByText(h.getRoot(), 'Command Console').length, 0, 'a bare k9.access holder still gets no Console tab -- unchanged by this pass');
});

// ============================================================================
// WORKFLOW AUDIT FINDING #2, 2026-08-26 -- the roster only ever lists
// people who already hold an active certification, so a brand-new person
// (exactly who "Set Up a New Handler" is for) can never appear there by
// name or partial ID. The empty-results message and the "open by exact
// citizen ID" box now both say so in plain English.
// ============================================================================

t.test('WORKFLOW AUDIT #2: an empty roster search explains that a brand-new (never-certified) person will never show up here, and points at the citizen-ID box instead', async () => {
    const h = createHarness({
        fetchImpl: routeFetch({
            'tablet:requestMyRecord': () => ({ ok: true, viewer: { citizenid: 'V', name: 'V', isHighCommand: true, effectivePermissions: ['k9.access', 'k9.certify', 'k9.audit', 'k9.givexp'], allowSelfGrant: false }, certifications: [], xp: null, tierLabel: null, myFeatures: [] }),
            'tablet:requestRoster': () => ({ ok: true, rows: [], truncated: false }),
        }),
    });
    h.postMessage('tablet:open', {});
    await settle(h);
    findByText(h.getRoot(), 'Command Console')[0].click();
    await settle(h);

    t.isTrue(findByTextContaining(h.getRoot(), 'This list only shows people who already hold a certification').length >= 1, 'explains WHY the search came up empty');
    // Wording updated this pass (Online Players list): still tells the
    // operator exactly what to do, now preferring the new list for an
    // ONLINE target and falling back to the citizen-ID box otherwise --
    // see locales/en.json's own 'tablet.empty_roster' for the full text.
    t.isTrue(findByTextContaining(h.getRoot(), 'type their exact citizen ID in the search box and press Open').length >= 1, 'and tells the operator exactly what to do about it');
});

t.test('WORKFLOW AUDIT #2: the one search box always carries a hint that Open works even for someone never certified, for a full-access viewer', async () => {
    const h = createHarness({
        fetchImpl: routeFetch({
            'tablet:requestMyRecord': () => ({ ok: true, viewer: { citizenid: 'V', name: 'V', isHighCommand: true, effectivePermissions: ['k9.access', 'k9.certify', 'k9.audit', 'k9.givexp'], allowSelfGrant: false }, certifications: [], xp: null, tierLabel: null, myFeatures: [] }),
            'tablet:requestRoster': () => ({ ok: true, rows: [{ citizenid: 'A', name: 'A', departmentLabel: 'Police', certified: true, xp: 0, tierLabel: 'Recruit K9' }], truncated: false }),
        }),
    });
    h.postMessage('tablet:open', {});
    await settle(h);
    findByText(h.getRoot(), 'Command Console')[0].click();
    await settle(h);

    t.isTrue(findByTextContaining(h.getRoot(), 'has never been certified, type their exact citizen ID and press Open').length >= 1);
});

// ----------------------------------------------------------------------
// HANDLER RANK ON THE ROSTER.
//
// server/tablet.lua's rosterList row has always carried handlerXp/
// handlerTierLabel and the table rendered neither, so a handler's rank was
// resolved on every roster fetch and thrown away. Console operators had no
// way to see handler standing at a glance -- the exact "who is my most
// experienced handler" question a roster is for.
// ----------------------------------------------------------------------

t.test('HANDLER RANK: the roster table carries a Handler XP column alongside the K9 one, and renders both per row', async () => {
    const h = createHarness({
        fetchImpl: routeFetch({
            'tablet:requestMyRecord': () => ({
                ok: true,
                viewer: { citizenid: 'VIEWER1', name: 'Officer Viewer', isHighCommand: true, effectivePermissions: ['k9.certify', 'k9.audit'], allowSelfGrant: false },
                certifications: [], xp: null, tierLabel: null, myFeatures: [],
            }),
            'tablet:requestRoster': () => ({
                ok: true,
                rows: [{
                    citizenid: 'TARGET1', name: 'K9 Rex', departmentLabel: 'Police', certified: true,
                    xp: 1250, tierLabel: 'Trained K9',
                    handlerXp: 220, handlerTierLabel: 'Senior Handler',
                }],
                truncated: false,
            }),
        }),
    });

    h.postMessage('tablet:open', {});
    await settle(h);
    findByText(h.getRoot(), 'Command Console')[0].click();
    await settle(h);

    t.isTrue(findByText(h.getRoot(), 'XP / Rank').length >= 1, 'the K9 column header');
    t.isTrue(findByText(h.getRoot(), 'Handler XP / Rank').length >= 1, 'and the handler column header is present');
    t.isTrue(findByText(h.getRoot(), '1250 — Trained K9').length >= 1, 'the K9 cell still renders');
    t.isTrue(findByText(h.getRoot(), '220 — Senior Handler').length >= 1,
        'the handler cell renders too -- the server has always sent this and it was being discarded');
});

t.test('HANDLER RANK: a row the server sent no handler standing for reads as "no record yet", never as a blank cell', async () => {
    const h = createHarness({
        fetchImpl: routeFetch({
            'tablet:requestMyRecord': () => ({
                ok: true,
                viewer: { citizenid: 'VIEWER1', name: 'Officer Viewer', isHighCommand: true, effectivePermissions: ['k9.certify', 'k9.audit'], allowSelfGrant: false },
                certifications: [], xp: null, tierLabel: null, myFeatures: [],
            }),
            'tablet:requestRoster': () => ({
                ok: true,
                rows: [{ citizenid: 'T2', name: 'No Handler XP', departmentLabel: 'Police', certified: true, xp: 5, tierLabel: 'Recruit K9' }],
                truncated: false,
            }),
        }),
    });

    h.postMessage('tablet:open', {});
    await settle(h);
    findByText(h.getRoot(), 'Command Console')[0].click();
    await settle(h);

    // Same xpLine() helper as the K9 column, so an absent standing reads
    // consistently across both rather than leaving one column ragged.
    t.isTrue(findByText(h.getRoot(), 'No XP record yet.').length >= 1);
});

t.run();
