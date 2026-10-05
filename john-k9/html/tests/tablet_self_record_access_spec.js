// html/tests/tablet_self_record_access_spec.js
//
// THE BUG (2026-09-01, owner's live testing: "as high command i cant
// certify myself").
//
// Self-certification is a real, config-permitted flow: Config.
// AllowSelfCertification gates it, the server re-checks it on every call,
// and html/tablet.js's refreshPersonAndSelf() was written specifically to
// keep Home and My Record in step after a viewer acts on their own record.
// Every server-side gate passed. The capability was genuinely there.
//
// What was missing was any way to REACH it. The Person screen is opened
// either from the roster (which lists only people who already hold a
// certification -- so never someone about to certify themselves for the
// first time), from the online-players list, or by typing an exact citizen
// ID into a box. And nothing anywhere in this tablet ever shows a viewer
// what their own citizen ID is. So the only path to a permitted action ran
// through a value the UI refused to tell you.
//
// From the outside that is indistinguishable from being refused, which is
// exactly how it was reported. The fix is one button that fills in the
// citizenid this page already holds in state.viewer.
//
// THE SECURITY RULE is untouched and these tests do not pretend otherwise:
// this button decides nothing. It opens a screen. The server re-authorizes
// the certify itself from the caller's own live job and grants, and refuses
// a self-certify outright when Config.AllowSelfCertification is false --
// exactly as it would have if the id were typed by hand.

'use strict';

const t = require('./testkit');
const { createHarness, jsonResponse } = require('./tablet-sandbox');
const { findByText, findAll } = require('./tablet-dom-stub');

function routeFetch(handlers) {
    return function (url, init) {
        const name = String(url).split('/').pop();
        const body = init && init.body ? JSON.parse(init.body) : {};
        const h = handlers[name];
        if (!h) return Promise.reject(new Error('tablet_self_record_access_spec: unhandled NUI callback ' + name));
        return Promise.resolve(jsonResponse(h(body)));
    };
}

async function settle(times) {
    for (let i = 0; i < (times || 4); i++) await new Promise((r) => setImmediate(r));
}

const HIGH_COMMAND_VIEWER = {
    citizenid: 'CHIEF7', name: 'Chief Allday', isHighCommand: true,
    effectivePermissions: ['k9.access', 'k9.certify', 'k9.audit', 'k9.givexp'],
    allowSelfGrant: true,
};

// The roster deliberately does NOT contain the viewer. That is the real
// situation the bug lived in: the roster lists holders of an ACTIVE
// certification, and someone who has never certified themselves is by
// definition not in it.
function harness(viewer) {
    const seenSummaryRequests = [];
    const h = createHarness({
        fetchImpl: routeFetch({
            'tablet:requestMyRecord': () => ({ ok: true, viewer, certifications: [], xp: null, tierLabel: null, myFeatures: [] }),
            'tablet:requestRoster': () => ({ ok: true, rows: [{ citizenid: 'OTHER1', name: 'Someone Else', departmentLabel: 'Police', certified: true, xp: 100, tierLabel: 'Trained K9' }], truncated: false }),
            'tablet:requestOnlinePlayers': () => ({ ok: true, rows: [] }),
            'tablet:requestPersonSummary': (body) => {
                seenSummaryRequests.push(body && body.targetCitizenId);
                return { ok: true, target: { citizenid: (body && body.targetCitizenId) || '?', name: 'Chief Allday' }, certifications: [], xp: 0, tierLabel: null, permissions: [] };
            },
            'tablet:requestPersonFeatures': () => ({ ok: true, target: { citizenid: 'CHIEF7', name: 'Chief Allday' }, features: [] }),
            'tablet:permKeysList': () => ({ ok: true, keys: [] }),
        }),
    });
    return { h, seenSummaryRequests };
}

async function openConsole(h) {
    h.postMessage('tablet:open', {});
    await settle();
    findByText(h.getRoot(), 'Command Console')[0].click();
    await settle();
}

t.test('THE FIX: the Command Console offers a way into the viewer\'s OWN record', async () => {
    const { h } = harness(HIGH_COMMAND_VIEWER);
    await openConsole(h);
    t.isTrue(findByText(h.getRoot(), 'Open my own record').length > 0, 'the button exists at all -- before this, the only path was typing an id nothing on screen shows you');
});

t.test('the viewer is genuinely NOT reachable any other way -- this is why the button had to exist', async () => {
    const { h } = harness(HIGH_COMMAND_VIEWER);
    await openConsole(h);

    // The precondition the whole bug rests on. If the viewer ever DID show
    // up in the roster, the button would be a convenience rather than the
    // only door, and this spec would be overstating its case.
    t.equals(findByText(h.getRoot(), 'Chief Allday').length, 0, 'the viewer is not in the roster (it lists active certification holders, which they are not)');
    t.isTrue(findByText(h.getRoot(), 'Someone Else').length > 0, 'sanity: the roster did render, with somebody else in it');
});

t.test('pressing it opens the Person screen for the VIEWER\'S OWN citizenid, not anyone else\'s', async () => {
    const { h, seenSummaryRequests } = harness(HIGH_COMMAND_VIEWER);
    await openConsole(h);

    findByText(h.getRoot(), 'Open my own record')[0].click();
    await settle(6);

    t.isTrue(seenSummaryRequests.indexOf('CHIEF7') !== -1, 'the person summary was requested for the viewer\'s own citizenid');
    t.equals(seenSummaryRequests.filter((id) => id !== 'CHIEF7').length, 0, 'and for nobody else');
});

t.test('it needs no typing at all -- the citizenid comes from state.viewer, which the operator never has to know', async () => {
    const { h, seenSummaryRequests } = harness(HIGH_COMMAND_VIEWER);
    await openConsole(h);

    // Explicitly NOT touching the "open by exact citizen ID" input. The
    // entire point is that an operator who does not know their own citizen
    // ID -- which is everyone, since this tablet never displays it -- can
    // still get to their own record.
    findByText(h.getRoot(), 'Open my own record')[0].click();
    await settle(6);

    t.equals(seenSummaryRequests[0], 'CHIEF7', 'resolved from state.viewer with an empty id box');
});

t.test('a viewer whose own citizenid is not resolved yet gets no button rather than a broken one', async () => {
    // Defensive: state.viewer exists but carries no citizenid. A button
    // here would fire openPerson(undefined) and land on a dead screen --
    // worse than no button, and precisely the "guided flow that traps
    // someone" shape this resource avoids elsewhere.
    const { h } = harness({ citizenid: '', name: 'Nobody', isHighCommand: true, effectivePermissions: ['k9.access', 'k9.certify'], allowSelfGrant: true });
    await openConsole(h);
    t.equals(findByText(h.getRoot(), 'Open my own record').length, 0, 'no button when there is no id to open');
});

t.test('REGRESSION: adding this button must not steal Enter from the citizen ID box beside it', async () => {
    // findEnterSubmitTarget() in html/tablet.js gives a text field an
    // Enter-to-submit target only while its nearest container holds
    // EXACTLY ONE candidate button, and refuses outright at two -- an
    // ambiguous Enter must never fire something. The first version of this
    // feature put "Open my own record" inside the same toolbar as the
    // citizen ID input and its Open button, which silently took Enter away
    // from that box: two candidates, so no target, so Enter did nothing.
    //
    // The button now lives in a sibling row. This test pins the REASON, so
    // that a future tidy-up that merges the two rows back together fails
    // here with an explanation rather than quietly regressing a keyboard
    // path nobody tests by hand.
    const { h } = harness(HIGH_COMMAND_VIEWER);
    await openConsole(h);

    const idInput = findAll(h.getRoot(), (n) => n.tagName === 'input' && n.getAttribute('placeholder') === 'Name, citizen ID or server ID...')[0];
    t.isDefined(idInput, 'sanity: the citizen ID box is on screen');

    // Walk up from the input to its own toolbar and count candidate
    // buttons there -- exactly what the real heuristic does.
    const toolbar = idInput.parentNode;
    const buttonsBesideTheInput = findAll(toolbar, (n) => n.tagName === 'button' && n.classList && n.classList.contains('k9tablet-btn'));
    t.equals(
        buttonsBesideTheInput.length, 1,
        'exactly one button shares the ID input\'s toolbar -- a second one anywhere in here disables Enter for that field'
    );
    t.equals(buttonsBesideTheInput[0].textContent, 'Open', 'and it is the Open button, so Enter still means "open this id"');

    // And the self-record button really is elsewhere on the screen.
    t.isTrue(findByText(h.getRoot(), 'Open my own record').length > 0, 'the self-record button is still present, just not in that toolbar');
    t.equals(
        findAll(toolbar, (n) => n.textContent === 'Open my own record').length, 0,
        'specifically: not inside the ID toolbar'
    );
});

t.run();
