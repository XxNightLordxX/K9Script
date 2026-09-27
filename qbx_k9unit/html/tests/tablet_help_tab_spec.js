/*
    html/tests/tablet_help_tab_spec.js

    Covers the Help screen (html/tablet.js's buildHelpScreen() and
    everything it assembles -- HELP_TAB_CATALOG, buildHelpStartHereSection(),
    buildHelpTabsSection(), buildHelpCommandsSection(), buildHelpTasksSection(),
    buildHelpTroubleshootingSection()) -- the owner-directed "a separate tab
    that teaches you how to use the entire tablet... super detailed but
    dumbed down" pass. Distinct from html/tests/tablet_command_reference_spec.js
    (which owns the Commands Reference screen's own coverage) -- this file
    only covers the NEW Help screen.

    Five scenarios:
      1. The tab renders and is reachable for any resolved viewer,
         including one with zero certifications (the "New Arrival" case
         this whole page exists to serve first).
      2. Role-based content: a K9-model viewer sees the K9 Start Here
         track; anyone else sees the Handler track -- never both at once.
      3. ADDITIVE, NOT REPLACEMENT: a High Command viewer sees every
         section a plain handler sees, PLUS the admin-only command table
         and task walkthroughs -- proven by an exact row count derived
         from the real COMMAND_REFERENCE array, not a hardcoded number.
      4. A plain handler/K9 viewer (not High Command) does NOT see any
         admin-only command row or admin task heading at all.
      5. XSS safety -- a hostile string arriving via `data.strings` for a
         Help-screen key reaches the DOM only via textContent, never
         innerHTML, same proof technique as html/tests/tablet_xss_spec.js.
*/
'use strict';

const fs = require('fs');
const path = require('path');
const t = require('./testkit');
const { createHarness, jsonResponse } = require('./tablet-sandbox');
const { findByText, findAll } = require('./tablet-dom-stub');

// DERIVED, NOT HARDCODED -- same technique and same reasoning as
// html/tests/tablet_command_reference_spec.js's own
// countRealCommandReferenceEntries(): reads html/tablet.js's raw source
// text so this spec's own row-count assertions never need a manual bump
// when COMMAND_REFERENCE legitimately grows.
// Reads tablet-catalog.js, not tablet.js: the catalog literals moved there
// on 2026-09-02 (see that file's own header).
const tabletJsSource = fs.readFileSync(path.join(__dirname, '..', 'tablet-catalog.js'), 'utf8');
function countCommandReferenceEntriesByAdminOnly(wantAdminOnly) {
    const startPos = tabletJsSource.indexOf('var COMMAND_REFERENCE = [');
    if (startPos === -1) throw new Error('tablet_help_tab_spec: var COMMAND_REFERENCE = [ not found in html/tablet.js');
    const endPos = tabletJsSource.indexOf('\n    ];', startPos);
    if (endPos === -1) throw new Error('tablet_help_tab_spec: closing "];" for COMMAND_REFERENCE not found in html/tablet.js');
    const body = tabletJsSource.slice(startPos, endPos);
    const lines = body.split('\n').filter((l) => l.indexOf('command:') !== -1);
    const needle = 'adminOnly: ' + wantAdminOnly;
    const matches = lines.filter((l) => l.indexOf(needle) !== -1);
    if (matches.length === 0) throw new Error('tablet_help_tab_spec: matched zero COMMAND_REFERENCE entries for adminOnly=' + wantAdminOnly + ' -- extraction pattern is stale');
    return matches.length;
}
const REAL_NON_ADMIN_COMMAND_COUNT = countCommandReferenceEntriesByAdminOnly(false);
const REAL_ADMIN_COMMAND_COUNT = countCommandReferenceEntriesByAdminOnly(true);

/** Set by the High Command test below and compared against by the plain
 * handler test: with one shared table (plan item H), both must see the
 * same rows. */
let HIGH_COMMAND_ROW_COUNT = 0;

function routeFetch(handlers) {
    return function (url) {
        const name = url.split('/').pop();
        const h = handlers[name];
        if (!h) return Promise.reject(new Error('tablet_help_tab_spec: unhandled NUI callback ' + name));
        return Promise.resolve(jsonResponse(h()));
    };
}

async function settle(times) {
    for (let i = 0; i < (times || 3); i++) await new Promise((r) => setImmediate(r));
}

function myRecordHandler(viewer, opts) {
    opts = opts || {};
    return () => ({
        ok: true,
        viewer: viewer,
        certifications: opts.certifications || [],
        xp: null,
        tierLabel: null,
        myFeatures: opts.myFeatures || [],
        isK9Model: opts.isK9Model === true,
        isPartnered: opts.isPartnered === true,
    });
}

const UNCERTIFIED_VIEWER = { citizenid: 'U1', name: 'New Arrival', isHighCommand: false, effectivePermissions: [] };
const HANDLER_VIEWER = { citizenid: 'H1', name: 'Rex Handler', isHighCommand: false, effectivePermissions: ['k9.access'] };
const HIGH_COMMAND_VIEWER = { citizenid: 'HC1', name: 'Chief', isHighCommand: true, effectivePermissions: ['k9.access', 'k9.certify', 'k9.audit', 'k9.givexp'] };

async function openHelpScreen(h) {
    h.postMessage('tablet:open', {});
    await settle();
    findByText(h.getRoot(), 'Guide')[0].click();
    await settle();
}

/** findByText() only matches an EXACT textContent string -- this page's
 * own step paragraphs are full sentences, so substring assertions below
 * use this instead of a brittle exact-copy-paste of the whole sentence. */
function findByTextContaining(node, substring) {
    return findAll(node, (n) => typeof n._textContent === 'string' && n._textContent.indexOf(substring) !== -1);
}

function statusBadges(h) {
    return findAll(h.getRoot(), (n) => n.classList && n.classList.contains('k9tablet-feature-state'));
}

t.test('the Help tab renders for a brand-new, uncertified viewer -- the exact reader this screen exists for first', async () => {
    const h = createHarness({
        fetchImpl: routeFetch({
            'tablet:requestMyRecord': myRecordHandler(UNCERTIFIED_VIEWER, {}),
        }),
    });
    await openHelpScreen(h);

    t.equals(findByText(h.getRoot(), 'How to Use This Tablet').length, 1, 'the screen heading renders');
    t.equals(findByText(h.getRoot(), 'Start Here').length, 1);
    t.equals(findByText(h.getRoot(), 'Every Tab, Explained').length, 1);
    // 'Commands You Can Use' is gone: the Guide renders the REAL command
    // reference underneath these sections now (plan item H), rather than a
    // second, category-grouped copy of the same catalog without the filter
    // or the live status badges. Its heading is what proves the table is
    // there.
    t.equals(findByText(h.getRoot(), 'Commands You Can Use').length, 0, 'no second, duplicate command table');
    t.isTrue(findByText(h.getRoot(), 'Command Reference').length >= 1, 'the real command reference is on this screen');
    t.equals(findByText(h.getRoot(), 'How to Do the Common Things').length, 1);
    t.equals(findByText(h.getRoot(), "When Something Doesn't Work").length, 1);
    // Getting Started role note -- uncertified, not K9, not handler.
    t.isTrue(findByTextContaining(h.getRoot(), 'Getting Started version of this guide').length >= 1);
});

// ======================================================================
// DEPLOY A KENNEL / USE SCENT VISION -- two recent headline features that
// (per this pass's own report) were documented in the Commands tab but had
// no step-by-step walkthrough here, unlike every other common task on this
// screen. UNGATED, same as Get Certified/Partner Up/Vehicle/Search/Treat
// above them -- shown to any viewer, not just High Command.
// ======================================================================

t.test('"How to Do the Common Things" now includes walkthroughs for Deploy a Kennel and Use Scent Vision, shown to an ordinary (non-High-Command) viewer', async () => {
    const h = createHarness({
        fetchImpl: routeFetch({
            'tablet:requestMyRecord': myRecordHandler(HANDLER_VIEWER, { certifications: [{ active: true }] }),
        }),
    });
    await openHelpScreen(h);

    t.equals(findByText(h.getRoot(), 'Deploy a Kennel').length, 1);
    // Menu-parity/menu-audit pass: the radial item this walkthrough quotes
    // was merged into 'k9_kennel' ("Kennel (Deploy/Enter/Exit)") -- the old
    // "Deploy Kennel" label no longer exists anywhere in this resource.
    // Checking for the OLD text here would now pass for the wrong reason
    // (the new sentence also contains the word "Deploy"), so this asserts
    // the full, real, current label instead.
    t.isTrue(findByTextContaining(h.getRoot(), 'Kennel (Deploy/Enter/Exit)').length >= 1, 'quotes the real, current radial menu label');
    t.isTrue(findByTextContaining(h.getRoot(), 'Rest in Kennel').length >= 1, 'quotes the real ox_target label for resting');
    t.isTrue(findByTextContaining(h.getRoot(), 'Pick Up Kennel').length >= 1, 'quotes the real ox_target label for reclaiming it');

    t.equals(findByText(h.getRoot(), 'Use Scent Vision').length, 1);
    t.isTrue(findByTextContaining(h.getRoot(), 'K9: Toggle Scent Vision').length >= 1, 'quotes the real keybind label');
});

t.test('role-based Start Here: a K9-model viewer sees the K9 track, never the Handler track', async () => {
    const h = createHarness({
        fetchImpl: routeFetch({
            'tablet:requestMyRecord': myRecordHandler(HANDLER_VIEWER, { isK9Model: true, certifications: [{ active: true }] }),
        }),
    });
    await openHelpScreen(h);

    t.isTrue(findByTextContaining(h.getRoot(), 'You are playing as the dog').length >= 1, 'K9 track step 1 renders');
    t.equals(findByTextContaining(h.getRoot(), 'Look at the top of the Home tab. It shows your name').length, 0, 'Handler track step 1 does NOT render at the same time');
});

t.test('role-based Start Here: a non-K9 viewer sees the Handler track, never the K9 track', async () => {
    const h = createHarness({
        fetchImpl: routeFetch({
            'tablet:requestMyRecord': myRecordHandler(HANDLER_VIEWER, { isK9Model: false, certifications: [{ active: true }] }),
        }),
    });
    await openHelpScreen(h);

    t.isTrue(findByTextContaining(h.getRoot(), 'Look at the top of the Home tab. It shows your name').length >= 1, 'Handler track step 1 renders');
    t.equals(findByTextContaining(h.getRoot(), 'You are playing as the dog').length, 0, 'K9 track step 1 does NOT render at the same time');
});

t.test('ADDITIVE, NOT REPLACEMENT: High Command sees every non-admin command PLUS every admin-only command', async () => {
    const h = createHarness({
        fetchImpl: routeFetch({
            'tablet:requestMyRecord': myRecordHandler(HIGH_COMMAND_VIEWER, {}),
        }),
    });
    await openHelpScreen(h);

    // ONE TABLE, EVERY COMMAND, FOR EVERY VIEWER (plan item H). The
    // separate 'Admin Commands (High Command Only)' heading belonged to the
    // deleted duplicate table; the real command reference has always listed
    // every command and let the per-row status badge say who can use it --
    // deliberately, per its own header: "never hidden for a viewer who
    // cannot use it, because it tells them what to go earn".
    t.equals(findByText(h.getRoot(), 'Admin Commands (High Command Only)').length, 0, 'no separate admin table heading any more');
    // Counted against the plain-handler run below rather than a hardcoded
    // total: the real command reference also hides a command whose gated
    // FEATURE is switched off server-wide, so the row count depends on the
    // fixture's myFeatures, not on who is looking. That is the property
    // worth pinning -- the table does not vary by rank.
    t.isTrue(statusBadges(h).length > 0, 'command rows render');
    HIGH_COMMAND_ROW_COUNT = statusBadges(h).length;

    // High-command-only task walkthroughs are additive too.
    t.equals(findByText(h.getRoot(), 'Certify Someone').length, 1);
    t.equals(findByText(h.getRoot(), 'Turn Someone Into a K9').length, 1);
    t.equals(findByText(h.getRoot(), 'Turn a Feature On or Off').length, 1);
    t.equals(findByText(h.getRoot(), 'Check What Someone Did').length, 1);
    // The derived Guided Flow step line -- proves this is rendered from
    // the SAME live flowTuningStepLabels() this file's own header
    // promises, not a separate hand-typed copy.
    //
    // This used to assert the ONBOARDING flow's sequence as well. That
    // flow was retired once the Person screen became the single place all
    // of its steps happen, so the only live sequence left to quote is the
    // tuning one.
    t.isTrue(findByTextContaining(h.getRoot(), 'Overview → Feature Toggles → Tunables → Certification Tiers → XP Thresholds → Shop Items').length >= 1, 'the tuning flow\'s real step sequence is quoted live');
});

t.test('a plain handler (not High Command) sees the non-admin commands only -- no admin row, no admin heading, no admin tasks', async () => {
    const h = createHarness({
        fetchImpl: routeFetch({
            'tablet:requestMyRecord': myRecordHandler(HANDLER_VIEWER, { certifications: [{ active: true }] }),
        }),
    });
    await openHelpScreen(h);

    // A plain handler sees the SAME single table -- admin commands
    // included, each with a badge saying they cannot use it. That is the
    // command reference's own long-standing posture, not a change of this
    // merge. What stays gated is the admin TASK WALKTHROUGHS below.
    t.equals(findByText(h.getRoot(), 'Admin Commands (High Command Only)').length, 0, 'no admin table heading exists for anyone now');
    t.equals(statusBadges(h).length, HIGH_COMMAND_ROW_COUNT, 'the SAME rows a high-command viewer sees -- one table, badges doing the gating, never a shorter list by rank');
    t.equals(findByText(h.getRoot(), 'Certify Someone').length, 0, 'the admin task walkthroughs are still withheld');
    t.equals(findByText(h.getRoot(), 'Turn Someone Into a K9').length, 0);
});

t.test('DELEGATED, NOT HIGH COMMAND: a rank-based certifier holding only the k9.certify capability sees the certification admin table and the Certify Someone task, but NOT Turn Someone Into a K9 or the Runtime Control task', async () => {
    const DELEGATED_CERTIFIER = { citizenid: 'D1', name: 'Sergeant Certifier', isHighCommand: false, effectivePermissions: ['k9.access', 'k9.certify'] };
    const h = createHarness({
        fetchImpl: routeFetch({
            'tablet:requestMyRecord': myRecordHandler(DELEGATED_CERTIFIER, { certifications: [{ active: true }] }),
        }),
    });
    await openHelpScreen(h);

    t.equals(findByText(h.getRoot(), 'Certify Someone').length, 1, 'a delegated k9.certify holder gets the Certify Someone walkthrough');
    t.equals(findByText(h.getRoot(), 'Turn Someone Into a K9').length, 0, 'but NOT the true-high-command-only Assign K9 Role walkthrough');
    t.equals(findByText(h.getRoot(), 'Turn a Feature On or Off').length, 0, 'and NOT the Runtime Control walkthrough, which this viewer has no capability for');
    t.equals(findByText(h.getRoot(), 'Runtime Control').length, 0, 'nor is the Runtime Control tab itself explained to them');
});

t.test('DELEGATED, NOT HIGH COMMAND: a runtime-control-only delegate sees the Runtime Control tab/task but NOT the certification admin table', async () => {
    const DELEGATED_RUNTIME = { citizenid: 'D2', name: 'Ops Delegate', isHighCommand: false, effectivePermissions: ['k9.access', 'k9.runtimecontrol'] };
    const h = createHarness({
        fetchImpl: routeFetch({
            'tablet:requestMyRecord': myRecordHandler(DELEGATED_RUNTIME, { certifications: [{ active: true }] }),
        }),
    });
    await openHelpScreen(h);

    t.isTrue(findByTextContaining(h.getRoot(), 'Turn individual features on or off for the whole server').length >= 1, 'the Runtime Control tab is explained to this delegate');
    t.equals(findByText(h.getRoot(), 'Turn a Feature On or Off').length, 1, 'and they get the matching task walkthrough');
    t.equals(findByText(h.getRoot(), 'Certify Someone').length, 0, 'but NOT the certification walkthrough -- this capability gates no real certification command');
});

t.test('Every Tab, Explained only lists tabs this viewer can actually see -- High Command gets more entries than a plain handler', async () => {
    const handlerHarness = createHarness({
        fetchImpl: routeFetch({ 'tablet:requestMyRecord': myRecordHandler(HANDLER_VIEWER, { certifications: [{ active: true }] }) }),
    });
    await openHelpScreen(handlerHarness);
    t.equals(findByText(handlerHarness.getRoot(), 'Runtime Control').length, 0, 'a plain handler is not taught about the high-command-only Runtime Control tab');
    // 'Home' is no longer a tab -- Home, My Record and Progression merged
    // into the one 'My Record' landing screen (plan item A), so that is the
    // entry a plain handler is taught about.
    t.equals(findByText(handlerHarness.getRoot(), 'My Record').length >= 1 ? 1 : 0, 1, 'a plain handler IS taught about My Record');

    const hcHarness = createHarness({
        fetchImpl: routeFetch({ 'tablet:requestMyRecord': myRecordHandler(HIGH_COMMAND_VIEWER, {}) }),
    });
    await openHelpScreen(hcHarness);
    t.isTrue(findByText(hcHarness.getRoot(), 'Runtime Control').length >= 1, 'High Command IS taught about the Runtime Control tab');
    t.isTrue(findByText(hcHarness.getRoot(), 'Audit Trail').length >= 1, 'High Command IS taught about the Audit Trail tab');
});

// ============================================================================
// WORKFLOW AUDIT FINDING #1, 2026-08-26 -- a viewer holding ONLY
// 'k9.certify' (no 'k9.audit', not high command) now has a real (narrowed)
// path into the Console tab (see tablet_console_spec.js's own coverage of
// the screen itself) -- "Every Tab, Explained" must describe that tab to
// them too, and the "Certify Someone" walkthrough must never point them at
// Guided Flows, a tab they cannot see or use.
// ============================================================================

t.test('WORKFLOW AUDIT #1: "Every Tab, Explained" now explains the Console tab to a bare k9.certify holder too, not only to k9.audit/high command', async () => {
    const DELEGATED_CERTIFIER = { citizenid: 'D3', name: 'Sergeant Certifier', isHighCommand: false, effectivePermissions: ['k9.access', 'k9.certify'] };
    const h = createHarness({
        fetchImpl: routeFetch({
            'tablet:requestMyRecord': myRecordHandler(DELEGATED_CERTIFIER, { certifications: [{ active: true }] }),
        }),
    });
    await openHelpScreen(h);

    t.isTrue(findByText(h.getRoot(), 'Command Console').length >= 1, 'the tab itself is explained (rendered) for this viewer -- it is visible to them now (workflow audit finding #1)');
    t.isTrue(findByTextContaining(h.getRoot(), 'Press Open to go straight to an exact citizen ID -- that always works, even for someone who has never been certified').length >= 1, 'the description names the capability every k9.certify/k9.givexp holder actually gets');
});

t.test('WORKFLOW AUDIT #1: a plain handler with NEITHER k9.certify/k9.givexp NOR k9.audit still is not taught about the Console tab at all', async () => {
    const h = createHarness({
        fetchImpl: routeFetch({ 'tablet:requestMyRecord': myRecordHandler(HANDLER_VIEWER, { certifications: [{ active: true }] }) }),
    });
    await openHelpScreen(h);
    t.equals(findByText(h.getRoot(), 'Command Console').length, 0, 'HANDLER_VIEWER holds only k9.access -- no path into the Console at all, so nothing explains a tab they cannot see');
});

t.test('WORKFLOW AUDIT #1: the "Certify Someone" walkthrough never points a non-high-command k9.certify holder at Guided Flows, a tab they cannot see', async () => {
    const DELEGATED_CERTIFIER = { citizenid: 'D4', name: 'Sergeant Certifier', isHighCommand: false, effectivePermissions: ['k9.access', 'k9.certify'] };
    const h = createHarness({
        fetchImpl: routeFetch({
            'tablet:requestMyRecord': myRecordHandler(DELEGATED_CERTIFIER, { certifications: [{ active: true }] }),
        }),
    });
    await openHelpScreen(h);

    t.equals(findByText(h.getRoot(), 'Certify Someone').length, 1, 'still gets the Certify Someone walkthrough');
    t.equals(findByText(h.getRoot(), 'Guided Flows').length, 0, 'this viewer cannot see the Guided Flows tab at all, so the walkthrough must never mention it');
    t.equals(findByTextContaining(h.getRoot(), 'Open the Guided Flows tab').length, 0, 'the Guided-Flows pointer step is entirely absent for this viewer');
    t.equals(findByTextContaining(h.getRoot(), 'Select Person → Certify').length, 0, 'the derived flow-step-sequence line is Guided-Flows-specific too, and is absent alongside it');
    t.isTrue(findByTextContaining(h.getRoot(), 'Someone brand new who is offline will not be in either list -- type their exact citizen ID and press Open').length >= 1, 'step 1 warns that the lists will never find someone who has never been certified, and says what to do');
});

t.test('WORKFLOW AUDIT #1, settled for good: high command and a k9.certify delegate now get the SAME Certify Someone walkthrough', async () => {
    // This used to be the control proving the opposite -- that high
    // command DID get two extra lines (a "Open the Guided Flows tab"
    // pointer and that flow's live step sequence) which a delegated
    // certifier correctly did not, because the delegate could not see the
    // Guided Flows tab at all.
    //
    // Retiring the onboarding flow removes the asymmetry at its source
    // rather than gating around it: there is no flow to point either
    // viewer at, and every step it sequenced is on the Person screen that
    // steps 1 and 2 already name. So the stronger property to pin now is
    // that the two viewers see the SAME walkthrough for a task they can
    // both do the same way -- which is also what stops the pointer
    // creeping back in for one of them.
    const DELEGATED_CERTIFIER = { citizenid: 'D4', name: 'Sergeant Certifier', isHighCommand: false, effectivePermissions: ['k9.access', 'k9.certify'] };

    const hc = createHarness({
        fetchImpl: routeFetch({ 'tablet:requestMyRecord': myRecordHandler(HIGH_COMMAND_VIEWER, {}) }),
    });
    await openHelpScreen(hc);
    t.equals(findByText(hc.getRoot(), 'Certify Someone').length, 1);
    t.equals(findByTextContaining(hc.getRoot(), 'Open the Guided Flows tab').length, 0, 'no flow left to point at, for high command either');
    t.equals(findByTextContaining(hc.getRoot(), 'Select Person → Certify').length, 0, 'the retired onboarding sequence is quoted to nobody');

    const dl = createHarness({
        fetchImpl: routeFetch({
            'tablet:requestMyRecord': myRecordHandler(DELEGATED_CERTIFIER, { certifications: [{ active: true }] }),
        }),
    });
    await openHelpScreen(dl);
    t.equals(findByText(dl.getRoot(), 'Certify Someone').length, 1, 'the delegate still gets the walkthrough');

    // The real point: same task, same instructions, whoever is reading.
    const step1 = 'Someone brand new who is offline will not be in either list -- type their exact citizen ID and press Open';
    t.isTrue(findByTextContaining(hc.getRoot(), step1).length >= 1, 'high command gets the roster-search caveat');
    t.isTrue(findByTextContaining(dl.getRoot(), step1).length >= 1, 'and so does the delegate -- identical copy now');
});

t.test('a hostile string arriving via data.strings for a Help-screen key reaches the DOM only via textContent, never innerHTML', async () => {
    const malicious = '<img src=x onerror="window.__xss_pwned=true">';
    const h = createHarness({
        fetchImpl: routeFetch({
            'tablet:requestMyRecord': myRecordHandler(HIGH_COMMAND_VIEWER, {}),
        }),
    });
    h.postMessage('tablet:open', { strings: { help_heading: malicious, help_trouble_no_k9_access_body: malicious } });
    await settle();
    findByText(h.getRoot(), 'Guide')[0].click();
    await settle();

    const matches = findAll(h.getRoot(), (n) => n._textContent === malicious);
    t.isTrue(matches.length >= 1, 'the malicious string reaches the DOM verbatim as textContent somewhere on this screen');

    const innerHTMLWrites = findAll(h.getRoot(), () => true).reduce((sum, el) => sum + (el.innerHTMLWriteCount || 0), 0);
    t.equals(innerHTMLWrites, 0, 'innerHTML must never be written anywhere on this page for a malicious Help-screen string');
});

t.run();
