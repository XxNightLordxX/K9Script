/*
    html/tests/tablet_roster_spec.js

    Covers the K9/Handler Personnel Rosters (docs/history/ROSTER_SPEC.md, Phase B) --
    owner, three messages, verbatim: "make it in the tablet where there is
    a roster where we can assign callsigns see list of hired k9s and full
    menu to fire promote etc" / "Also a separate roster for handlers same
    thing" / "The roster should be able to be where we can also assign
    roles sub features features permissions etc... Like click there
    profile and it opens a menu" / "Also in the roster be able to reorder
    them by rank."

    docs/history/ROSTER_SPEC.md §0's structural decision: the roster tabs are pure,
    read-only lists; every mutation (assign role, set/clear callsign, hire/
    fire/promote/demote) lives on buildPersonScreen(), the SAME screen the
    Console tab and Online Players picker already open -- these tests
    exercise both the list screens AND that shared person screen's own new
    Roster Role/Callsign section, never a second person-detail screen.

    Specifically proves:
      1. A non-high-command viewer never sees the Personnel Roster tab,
         nor the Roster Role/Callsign section on a person they CAN still
         open (via their own k9.certify/k9.audit capability) -- "no roster
         mutation controls" is a client-side convenience only; the SAME
         re-verified IsHighCommand gate this suite cannot exercise directly
         is covered server-side by tests/roster_spec.lua's own
         'not_authorized' coverage, and tests/clienttablet_spec.lua proves
         this file's own NUI bridges add no authorization of their own
         (forward verbatim, regardless of viewer).
      2. callsign_taken renders ITS OWN specific message, never a generic
         failure notice.
      3. Changing an already-assigned roster role shows the callsign-will-
         be-cleared warning VISIBLY, before either confirm click.
      4. The "Unassigned" section renders (with its own explainer) even
         when BOTH the K9 and Handler buckets are empty -- never silently
         omitted.
      5. Sorting by grade/XP re-orders the ALREADY-FETCHED rows with NO
         second qbx_k9unit:server:rosterList round trip.
      6. A roster row built from an OLDER fetch still targets its OWN
         citizenid when clicked, even after a NEWER fetch has since put a
         completely different person in the identical list position
         (server ids are recycled; this resource's whole roster feature is
         citizenid-keyed specifically to make that not matter).
      7. A malicious name/callsign/department label reaches the roster
         table AND the person screen's own Roster Role/Callsign section
         verbatim via textContent, never innerHTML -- the exhaustive
         payload battery lives in tablet_xss_spec.js; this is a
         representative sample proving THIS new surface participates in
         that same discipline.
*/
'use strict';

const t = require('./testkit');
const { createHarness, jsonResponse } = require('./tablet-sandbox');
const { findByText, findByTag, findAll } = require('./tablet-dom-stub');

// Mirrors html/tablet.js's own DEFAULT_STRINGS.action_failed (kept in sync
// with locales/en.json's tablet.action_failed) -- see
// tablet_mutation_error_spec.js's own identical constant for the full
// writeup of why this is hardcoded here rather than a stale literal.
const GENERIC_ACTION_FAILED_TEXT = 'Action failed — try again, and if it keeps happening, tell an admin.';

function findByTextContaining(node, substring) {
    return findAll(node, (n) => typeof n._textContent === 'string' && n._textContent.indexOf(substring) !== -1);
}

function routeFetch(handlers, calls) {
    return function (url, init) {
        const name = url.split('/').pop();
        const body = init && init.body ? JSON.parse(init.body) : undefined;
        if (calls) calls.push({ name: name, body: body });
        const h = handlers[name];
        if (!h) return Promise.resolve(jsonResponse({ ok: false, error: 'not_found_in_test' }));
        return Promise.resolve(jsonResponse(h(body)));
    };
}

const HC_VIEWER = { citizenid: 'HC1', name: 'Chief Ward', isHighCommand: true, effectivePermissions: ['k9.access', 'k9.certify', 'k9.audit', 'k9.givexp'], allowSelfGrant: true };
const CERTIFIER_ONLY_VIEWER = { citizenid: 'SGT1', name: 'Sergeant Vale', isHighCommand: false, effectivePermissions: ['k9.certify', 'k9.audit'], allowSelfGrant: false };

function rosterRow(overrides) {
    return Object.assign({
        citizenid: 'A1',
        name: 'Alice Handler',
        departmentKey: 'police',
        departmentLabel: 'Los Santos Police Department',
        personnelRole: 'k9',
        callsign: null,
        tierKey: 'certified',
        tierLabel: 'Certified',
        tierOrdinal: 2,
        xp: 100,
        partnerCitizenid: null,
        partnerName: null,
        gradeLabel: 'Officer',
        gradeLevel: 1,
        certifiedSince: '2026-01-01 00:00:00',
        pinnedDogModel: null,
    }, overrides || {});
}

async function settle(h, times) {
    for (let i = 0; i < (times || 3); i++) await new Promise((r) => setImmediate(r));
}

// ============================================================================
// 1. NON-HIGH-COMMAND: no roster tabs, no Roster Role/Callsign section on a
//    person screen this viewer CAN still open through their own capability.
// ============================================================================

t.test('a non-high-command viewer never sees the Personnel Roster tab, even holding k9.certify + k9.audit', async () => {
    const h = createHarness({
        fetchImpl: routeFetch({
            'tablet:requestMyRecord': () => ({ ok: true, viewer: CERTIFIER_ONLY_VIEWER, certifications: [], xp: null, tierLabel: null, myFeatures: [] }),
        }),
    });
    h.postMessage('tablet:open', {});
    await settle(h);
    // ONE tab now ('Personnel Roster'), not two -- the K9/Handlers split is
    // a filter inside the screen. The old labels must not appear either:
    // they were deleted outright rather than repurposed as tab names.
    t.equals(findByText(h.getRoot(), 'Personnel Roster').length, 0, 'tab is not merely hidden by CSS -- it is never constructed at all');
    t.equals(findByText(h.getRoot(), 'K9 Roster').length, 0, 'and the old two-tab labels are gone entirely');
    t.equals(findByText(h.getRoot(), 'Handler Roster').length, 0);
});

t.test('a non-high-command viewer opening a person via Console still sees NO Roster Role/Callsign section, only their own ordinary Certify/Decertify controls -- the server-side IsHighCommand gate (tests/roster_spec.lua) is the real refusal, this is only the convenience', async () => {
    const h = createHarness({
        fetchImpl: routeFetch({
            'tablet:requestMyRecord': () => ({ ok: true, viewer: CERTIFIER_ONLY_VIEWER, certifications: [], xp: null, tierLabel: null, myFeatures: [] }),
            'tablet:requestPersonSummary': () => ({
                ok: true,
                target: { citizenid: 'TARGET1', name: 'K9 Rex' },
                certifications: [{ departmentKey: 'police', departmentLabel: 'Los Santos Police Department', active: true, grantedBy: null }],
                xp: 10, tierLabel: 'Recruit K9', permissions: [],
            }),
        }),
    });
    h.postMessage('tablet:open', {});
    await settle(h);
    findByText(h.getRoot(), 'Command Console')[0].click();
    await settle(h);
    const idInput = findByTag(h.getRoot(), 'input').filter((i) => i.getAttribute('placeholder') === 'Name, citizen ID or server ID...')[0];
    idInput.typeValue('TARGET1');
    findByText(h.getRoot(), 'Open')[0].click();
    await settle(h);

    t.isTrue(findByText(h.getRoot(), 'Decertify').length >= 1, "this viewer's own k9.certify capability still works, unchanged");
    t.equals(findByText(h.getRoot(), 'Roster Role').length, 0, 'the roster role section never renders for a non-high-command viewer');
    t.equals(findByText(h.getRoot(), 'Save Callsign').length, 0, 'nor the callsign control');
});

// ============================================================================
// 2. callsign_taken renders its OWN specific message.
// ============================================================================

t.test('callsign_taken renders a specific, useful message naming the problem -- never a generic failure notice', async () => {
    const personnelRoster = { ok: true, k9: [rosterRow({ citizenid: 'TARGET1', personnelRole: 'k9', callsign: '4-Adam-1' })], handlers: [], unassigned: [] };
    const h = createHarness({
        fetchImpl: routeFetch({
            'tablet:requestMyRecord': () => ({ ok: true, viewer: HC_VIEWER, certifications: [], xp: null, tierLabel: null, myFeatures: [] }),
            'tablet:requestPersonSummary': () => ({
                ok: true,
                target: { citizenid: 'TARGET1', name: 'K9 Rex' },
                certifications: [{ departmentKey: 'police', departmentLabel: 'Los Santos Police Department', active: true, grantedBy: null }],
                xp: 10, tierLabel: 'Recruit K9', permissions: [],
            }),
            'tablet:rosterList': () => personnelRoster,
            'tablet:rosterSetCallsign': () => ({ ok: false, error: 'callsign_taken' }),
        }),
    });
    h.postMessage('tablet:open', {});
    await settle(h);
    findByText(h.getRoot(), 'Command Console')[0].click();
    await settle(h);
    const idInput = findByTag(h.getRoot(), 'input').filter((i) => i.getAttribute('placeholder') === 'Name, citizen ID or server ID...')[0];
    idInput.typeValue('TARGET1');
    findByText(h.getRoot(), 'Open')[0].click();
    await settle(h, 4);

    const callsignInput = findByTag(h.getRoot(), 'input').filter((i) => i.className.indexOf('k9tablet-roster-callsign-input') !== -1)[0];
    t.isDefined(callsignInput, 'the callsign input renders for a high-command viewer on an already-assigned department row');
    callsignInput.typeValue('4-Adam-1');
    findByText(h.getRoot(), 'Save Callsign')[0].click();
    await settle(h, 4);

    t.isTrue(
        findByTextContaining(h.getRoot(), 'K9 and Handler callsigns share one namespace').length >= 1,
        'the specific callsign_taken message rendered, not a generic failure'
    );
    // Check the actual mutation notice banner specifically (NOT a
    // page-wide text search) -- an unrelated, unmocked-in-this-test
    // section (e.g. the K9 Profile block, opportunistically loaded for
    // every high-command viewer) legitimately shows its OWN generic
    // "Action failed." for a completely different reason, and that must
    // not be confused with THIS mutation's own notice.
    const notice = findAll(h.getRoot(), (n) => n.classList && n.classList.contains('k9tablet-notice--error'))[0];
    t.isDefined(notice, 'an error notice banner rendered for this mutation');
    t.isTrue(notice._textContent !== GENERIC_ACTION_FAILED_TEXT, 'the mutation notice itself is the specific callsign message, never the generic fallback');
});

// ============================================================================
// 3. Role change warns about the callsign clear BEFORE either confirm click.
// ============================================================================

t.test('changing an already-assigned roster role shows the callsign-will-be-cleared warning visibly before the operator confirms, and the mutation only fires on the SECOND click', async () => {
    const personnelRoster = { ok: true, k9: [rosterRow({ citizenid: 'TARGET1', personnelRole: 'k9', callsign: '4-Adam-1' })], handlers: [], unassigned: [] };
    const mutationCalls = [];
    const h = createHarness({
        fetchImpl: routeFetch({
            'tablet:requestMyRecord': () => ({ ok: true, viewer: HC_VIEWER, certifications: [], xp: null, tierLabel: null, myFeatures: [] }),
            'tablet:requestPersonSummary': () => ({
                ok: true,
                target: { citizenid: 'TARGET1', name: 'K9 Rex' },
                certifications: [{ departmentKey: 'police', departmentLabel: 'Los Santos Police Department', active: true, grantedBy: null }],
                xp: 10, tierLabel: 'Recruit K9', permissions: [],
            }),
            'tablet:rosterList': () => personnelRoster,
            'tablet:rosterSetPersonnelRole': (body) => { mutationCalls.push(body); return { ok: true, outcome: 'role_changed' }; },
        }, mutationCalls.length ? undefined : undefined),
    });
    h.postMessage('tablet:open', {});
    await settle(h);
    findByText(h.getRoot(), 'Command Console')[0].click();
    await settle(h);
    const idInput = findByTag(h.getRoot(), 'input').filter((i) => i.getAttribute('placeholder') === 'Name, citizen ID or server ID...')[0];
    idInput.typeValue('TARGET1');
    findByText(h.getRoot(), 'Open')[0].click();
    await settle(h, 4);

    t.isTrue(
        findByTextContaining(h.getRoot(), "clears their current callsign").length >= 1,
        'the warning is visible BEFORE either click, not merely a tooltip'
    );

    const handlerBtn = findByText(h.getRoot(), 'Handler')[0];
    t.isDefined(handlerBtn, 'the "switch to Handler" control is offered (current role is K9)');
    handlerBtn.click();
    t.equals(mutationCalls.length, 0, 'first click only arms the confirmation, no mutation fired yet');
    t.equals(handlerBtn._textContent, 'Confirm?', 'button flips to the confirm prompt, same mechanism every other destructive action on this page uses');

    handlerBtn.click();
    await settle(h, 4);
    t.equals(mutationCalls.length, 1, 'second click within the window fires the actual request');
    t.equals(mutationCalls[0].personnelRole, 'handler');
    t.equals(mutationCalls[0].citizenid, 'TARGET1');
    t.equals(mutationCalls[0].job, 'police');
});

t.test('assigning a role to an UNASSIGNED person (no existing role) is a plain, one-click button -- no callsign-clear warning, since nothing is being cleared', async () => {
    const personnelRoster = { ok: true, k9: [], handlers: [], unassigned: [rosterRow({ citizenid: 'TARGET1', personnelRole: null, callsign: null })] };
    const h = createHarness({
        fetchImpl: routeFetch({
            'tablet:requestMyRecord': () => ({ ok: true, viewer: HC_VIEWER, certifications: [], xp: null, tierLabel: null, myFeatures: [] }),
            'tablet:requestPersonSummary': () => ({
                ok: true,
                target: { citizenid: 'TARGET1', name: 'K9 Rex' },
                certifications: [{ departmentKey: 'police', departmentLabel: 'Los Santos Police Department', active: true, grantedBy: null }],
                xp: 10, tierLabel: 'Recruit K9', permissions: [],
            }),
            'tablet:rosterList': () => personnelRoster,
            'tablet:rosterSetPersonnelRole': () => ({ ok: true, outcome: 'assigned' }),
        }),
    });
    h.postMessage('tablet:open', {});
    await settle(h);
    findByText(h.getRoot(), 'Command Console')[0].click();
    await settle(h);
    const idInput = findByTag(h.getRoot(), 'input').filter((i) => i.getAttribute('placeholder') === 'Name, citizen ID or server ID...')[0];
    idInput.typeValue('TARGET1');
    findByText(h.getRoot(), 'Open')[0].click();
    await settle(h, 4);

    t.equals(findByTextContaining(h.getRoot(), 'clears their current callsign').length, 0, 'no clear-warning for a first-time assignment');
    const k9Btn = findByText(h.getRoot(), 'K9')[0];
    t.isDefined(k9Btn);
    k9Btn.click();
    t.equals(k9Btn._textContent, 'K9', 'a first-time assignment is a PLAIN button (label unchanged after one click), not a two-click confirm that would flip to "Confirm?"');
});

// ============================================================================
// 4. The Unassigned section renders even when BOTH rosters are empty.
// ============================================================================

t.test('the Unassigned section renders, with its explainer, when BOTH the K9 and Handler buckets are empty -- never silently omitted', async () => {
    const personnelRoster = {
        ok: true,
        k9: [],
        handlers: [],
        unassigned: [rosterRow({ citizenid: 'U1', name: 'Waiting Wendy', personnelRole: null, callsign: null })],
    };
    const h = createHarness({
        fetchImpl: routeFetch({
            'tablet:requestMyRecord': () => ({ ok: true, viewer: HC_VIEWER, certifications: [], xp: null, tierLabel: null, myFeatures: [] }),
            'tablet:rosterList': () => personnelRoster,
        }),
    });
    h.postMessage('tablet:open', {});
    await settle(h);
    findByText(h.getRoot(), 'Personnel Roster')[0].click();
    await settle(h, 4);

    t.isTrue(findByText(h.getRoot(), 'Nobody is currently on this roster.').length >= 1, 'the empty K9 bucket says so plainly');
    t.isTrue(findByText(h.getRoot(), 'Unassigned').length >= 1, 'the Unassigned heading is present');
    t.isTrue(findByTextContaining(h.getRoot(), 'this is normal, not an error').length >= 1, 'the explainer frames this as expected, not a bug');
    t.isTrue(findByText(h.getRoot(), 'Waiting Wendy').length >= 1, 'the one truly-unassigned person is actually listed');

    // Same guarantee with the Handlers bucket selected. Unassigned is
    // SHARED, never a K9-only section -- and with one screen it now renders
    // ONCE rather than being duplicated across two tabs, which is the whole
    // reason the two tabs became one.
    t.equals(findByText(h.getRoot(), 'Unassigned').length, 1, 'the shared section appears exactly once, not once per bucket');
    findByText(h.getRoot(), 'Handlers')[0].click();
    await settle(h, 4);
    t.isTrue(findByText(h.getRoot(), 'Waiting Wendy').length >= 1, 'Unassigned renders with the Handlers bucket too');
    t.equals(findByText(h.getRoot(), 'Unassigned').length, 1, 'and still exactly once');
});

// ============================================================================
// 5. Sorting is a PURE client re-sort -- no second server round trip.
// ============================================================================

t.test('sorting by Department Grade or XP re-orders the already-fetched rows with NO additional qbx_k9unit:server:rosterList call', async () => {
    const rosterCalls = [];
    const personnelRoster = {
        ok: true,
        k9: [
            rosterRow({ citizenid: 'LOW', name: 'Rookie Rex', tierOrdinal: 1, gradeLevel: 0, xp: 5 }),
            rosterRow({ citizenid: 'HIGH', name: 'Veteran Vex', tierOrdinal: 3, gradeLevel: 9, xp: 900 }),
            rosterRow({ citizenid: 'MID', name: 'Middle Max', tierOrdinal: 2, gradeLevel: 4, xp: 400 }),
        ],
        handlers: [],
        unassigned: [],
    };
    const h = createHarness({
        fetchImpl: routeFetch({
            'tablet:requestMyRecord': () => ({ ok: true, viewer: HC_VIEWER, certifications: [], xp: null, tierLabel: null, myFeatures: [] }),
            'tablet:rosterList': () => personnelRoster,
        }, rosterCalls),
    });
    h.postMessage('tablet:open', {});
    await settle(h);
    findByText(h.getRoot(), 'Personnel Roster')[0].click();
    await settle(h, 4);

    const callsAfterOpen = rosterCalls.filter((c) => c.name === 'tablet:rosterList').length;
    t.isTrue(callsAfterOpen >= 1, 'sanity: the tab load itself did fetch once');

    // Row names render inside a <span> (not the <td> itself -- the K9
    // "cosmetically pinned" note is an optional SIBLING span in the same
    // cell, see buildPersonnelRosterRow()), so this looks for the name
    // text directly rather than a <td>'s own textContent. findAll() walks
    // depth-first, so this returns names in on-screen (row) order.
    function nameOrder() {
        return findAll(h.getRoot(), (n) => ['Rookie Rex', 'Veteran Vex', 'Middle Max'].indexOf(n._textContent) !== -1).map((n) => n._textContent);
    }

    t.equals(nameOrder().join(','), 'Veteran Vex,Middle Max,Rookie Rex', 'default sort is tier ordinal descending');

    findByText(h.getRoot(), 'XP')[0].click();
    t.equals(nameOrder().join(','), 'Veteran Vex,Middle Max,Rookie Rex', 'XP sort, descending, happens to agree with tier order here too');

    findByText(h.getRoot(), 'Department Grade')[0].click();
    t.equals(nameOrder().join(','), 'Veteran Vex,Middle Max,Rookie Rex', 'grade sort, descending');

    findByText(h.getRoot(), 'Certification Tier')[0].click();
    await settle(h, 4);

    const callsAfterSorting = rosterCalls.filter((c) => c.name === 'tablet:rosterList').length;
    t.equals(callsAfterSorting, callsAfterOpen, 'sorting three times fired ZERO additional qbx_k9unit:server:rosterList calls');
});

// ============================================================================
// 6. RECYCLED SERVER ID: a row built from an OLDER fetch still targets its
//    OWN citizenid, even after a newer fetch replaces the same list slot
//    with a different person entirely.
// ============================================================================

t.test('a roster row rendered from an OLDER fetch still opens/acts on its OWN citizenid, even after a NEWER fetch has since put someone else in the identical list position', async () => {
    const personSummaryCalls = [];
    let currentRoster = { ok: true, k9: [rosterRow({ citizenid: 'OLD1', name: 'Old Alice' })], handlers: [], unassigned: [] };
    const h = createHarness({
        fetchImpl: routeFetch({
            'tablet:requestMyRecord': () => ({ ok: true, viewer: HC_VIEWER, certifications: [], xp: null, tierLabel: null, myFeatures: [] }),
            'tablet:rosterList': () => currentRoster,
            'tablet:requestPersonSummary': (body) => {
                personSummaryCalls.push(body);
                return { ok: true, target: { citizenid: body.targetCitizenId, name: 'whoever' }, certifications: [], xp: 0, tierLabel: null, permissions: [] };
            },
        }),
    });
    h.postMessage('tablet:open', {});
    await settle(h);
    findByText(h.getRoot(), 'Personnel Roster')[0].click();
    await settle(h, 4);

    // Capture the row's OWN "Manage" button object -- its onClick closure
    // was built over THIS render's row.citizenid ('OLD1'), a plain string,
    // never a server id.
    const staleManageButton = findByText(h.getRoot(), 'Manage')[0];
    t.isDefined(staleManageButton, 'the Manage button for OLD1 exists');

    // Simulate the exact hazard this resource's own "server ids are
    // recycled" note describes: a completely different person now occupies
    // the SAME array position a later fetch would return -- e.g. OLD1
    // logged off, and a server id (or, here, "whoever now holds this UI
    // slot") got reassigned to someone new by the time the operator
    // actually clicks. Re-render the WHOLE roster screen fresh with that
    // new data (a real Refresh/tab re-entry would do exactly this).
    currentRoster = { ok: true, k9: [rosterRow({ citizenid: 'NEW2', name: 'New Bob' })], handlers: [], unassigned: [] };
    findByText(h.getRoot(), 'Personnel Roster')[0].click();
    await settle(h, 4);
    t.isTrue(findByText(h.getRoot(), 'New Bob').length >= 1, 'sanity: the screen now genuinely shows the NEW person');
    t.equals(findByText(h.getRoot(), 'Old Alice').length, 0, 'and the old one is gone from the CURRENT render');

    // The STALE button object -- built for OLD1, now detached from the live
    // tree entirely -- must still act on OLD1 if invoked, never NEW2 (and
    // never silently no-op into acting on "whoever is current" instead).
    staleManageButton.click();
    await settle(h, 4);

    t.equals(personSummaryCalls.length, 1);
    t.equals(personSummaryCalls[0].targetCitizenId, 'OLD1', 'the stale row acted on the citizenid it was built for, never the new occupant of the same slot');
});

// ============================================================================
// 7. XSS discipline -- a representative sample, not the exhaustive battery
//    (that lives in tablet_xss_spec.js). Proves this NEW surface uses the
//    same .textContent-only rendering every other screen on this page does.
// ============================================================================

function everyElementInnerHTMLWriteCount(h) {
    return findAll(h.getRoot(), () => true).reduce((sum, el) => sum + (el.innerHTMLWriteCount || 0), 0);
}

t.test('a malicious name/callsign/department label reaches the roster table AND the person screen\'s own Roster Role/Callsign section verbatim via textContent, never innerHTML', async () => {
    const malicious = '<img src=x onerror=alert(1)>';
    const personnelRoster = {
        ok: true,
        k9: [rosterRow({
            citizenid: 'TARGET1',
            name: malicious,
            departmentLabel: malicious,
            callsign: malicious,
            partnerName: malicious,
        })],
        handlers: [],
        unassigned: [],
    };
    const h = createHarness({
        fetchImpl: routeFetch({
            'tablet:requestMyRecord': () => ({ ok: true, viewer: HC_VIEWER, certifications: [], xp: null, tierLabel: null, myFeatures: [] }),
            'tablet:rosterList': () => personnelRoster,
            'tablet:requestPersonSummary': () => ({
                ok: true,
                target: { citizenid: 'TARGET1', name: malicious },
                certifications: [{ departmentKey: 'police', departmentLabel: malicious, active: true, grantedBy: null }],
                xp: 10, tierLabel: 'Recruit K9', permissions: [],
            }),
        }),
    });
    h.postMessage('tablet:open', {});
    await settle(h);
    findByText(h.getRoot(), 'Personnel Roster')[0].click();
    await settle(h, 4);

    t.isTrue(findByTextContaining(h.getRoot(), malicious).length >= 1, 'the malicious string appears verbatim in the roster table (name/callsign/department/partner cells)');
    t.equals(everyElementInnerHTMLWriteCount(h), 0, 'innerHTML must never be written anywhere on this page for the roster table');

    // Now open that same citizenid's profile (the person screen's own
    // Roster Role/Callsign section, docs/history/ROSTER_SPEC.md Phase B) and prove the
    // SAME discipline holds there too.
    findByText(h.getRoot(), 'Manage')[0].click();
    await settle(h, 4);

    t.isTrue(findByTextContaining(h.getRoot(), malicious).length >= 1, 'the malicious string also appears verbatim on the person screen (current callsign display, department label)');
    t.equals(everyElementInnerHTMLWriteCount(h), 0, 'innerHTML must never be written anywhere on this page for the person screen either');
});

t.run();
