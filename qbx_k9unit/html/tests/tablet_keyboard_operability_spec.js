/*
    html/tests/tablet_keyboard_operability_spec.js

    Covers operating this panel WITHOUT A MOUSE -- a dozen-plus screens of
    forms, tables, and destructive actions that had never been exercised
    for keyboard reachability, focus continuity across html/tablet.js's
    own full-teardown-and-rebuild render() (see that function's own
    "FOCUS + SCROLL CONTINUITY" header for the full rationale), or
    double-submit safety before this pass. Every assertion here proves a
    REAL, load-bearing behavior via html/tests/tablet-dom-stub.js's own
    document.activeElement/.focus()/.scrollTop support (added alongside
    this spec, for this exact purpose) -- never merely that a function was
    called.

    Specifically proves, per this pass's own task list:
      1. A destructive action (Decertify) is a real, focusable, keyboard-
         activatable <button> gated behind a genuinely different-looking
         two-click confirm, not merely a different label.
      2. Escape closes the tablet from a DEEP screen (Console -> a specific
         Person), not only from the Home landing screen every other
         open/close spec already covers.
      3. Focus lands somewhere deliberate after a mutation settles (never
         lost to nothing), and a live-filter text field keeps its own
         focus AND cursor position across the re-render it triggers on
         every keystroke.
      4. A rapid double "click" (or a stray double Enter) on a mutating
         action fires its NUI callback exactly once.
      5. render()'s own scroll-position preservation: a same-screen
         re-render (e.g. a live search re-filtering the list) never resets
         `.k9tablet-screen`'s scrollTop, but navigating to a genuinely
         different screen correctly starts that screen at the top -- the
         DOM-testable half of "a long table shouldn't throw the operator
         back to the top on every edit" (the OTHER half -- that wide
         content visually scrolls inside its own container rather than
         pushing the whole panel sideways -- is a CSS behavior with no
         layout engine in this stub to exercise; see tablet.css's own
         `.k9tablet-screen`/`.k9tablet-table` comments for that half).
      6. Enter in a text field fires the one, unambiguous "obvious" button
         nearby (a small toolbar's own action, or a draft form's own
         Save) -- and safety-checked in the OTHER direction too: Enter
         inside a section that has more than one plausible button (a
         features list with several Grant buttons) fires NOTHING, rather
         than guessing.
*/
'use strict';

const t = require('./testkit');
const { createHarness, jsonResponse } = require('./tablet-sandbox');
const { findByText, findAll, findByTag, openSettingsSection } = require('./tablet-dom-stub');

function routeFetch(handlers) {
    return function (url, init) {
        const name = url.split('/').pop();
        const body = init && init.body ? JSON.parse(init.body) : undefined;
        const h = handlers[name];
        if (!h) return Promise.reject(new Error('tablet_keyboard_operability_spec: unhandled NUI callback ' + name));
        return Promise.resolve(jsonResponse(h(body)));
    };
}

async function settle(times) {
    for (let i = 0; i < (times || 3); i++) await new Promise((r) => setImmediate(r));
}

const HIGH_COMMAND_VIEWER = { citizenid: 'HC1', name: 'Chief', isHighCommand: true, effectivePermissions: ['k9.access', 'k9.certify', 'k9.audit', 'k9.givexp'], allowSelfGrant: false };

function findFirstButtonByText(root, text) {
    return findByText(root, text).filter((n) => n.tagName === 'button')[0];
}

// ======================================================================
// 1. DESTRUCTIVE ACTIONS: REAL <button>, TWO-CLICK CONFIRM, VISUALLY
//    DISTINCT ARMED STATE
// ======================================================================

t.test('Decertify is a real, focusable <button> requiring a SECOND click, and the armed state is visually distinct (own CSS class), not just relabeled', async () => {
    const h = createHarness({
        fetchImpl: routeFetch({
            'tablet:requestMyRecord': () => ({ ok: true, viewer: HIGH_COMMAND_VIEWER, certifications: [], xp: null, tierLabel: null, myFeatures: [] }),
            'tablet:requestRoster': () => ({ ok: true, rows: [{ citizenid: 'TARGET1', name: 'K9 Rex', departmentLabel: 'Police', certified: true, xp: 0, tierLabel: 'Recruit K9' }], truncated: false }),
            'tablet:requestPersonSummary': () => ({ ok: true, target: { citizenid: 'TARGET1', name: 'K9 Rex' }, certifications: [{ departmentKey: 'police', departmentLabel: 'Police', active: true, grantedBy: 'Chief' }], xp: 0, tierLabel: 'Recruit K9', permissions: [] }),
            'tablet:requestPersonFeatures': () => ({ ok: true, target: { citizenid: 'TARGET1', name: 'K9 Rex' }, features: [] }),
            'tablet:decertify': () => ({ ok: true }),
        }),
    });
    h.postMessage('tablet:open', {});
    await settle();
    findFirstButtonByText(h.getRoot(), 'Command Console').click();
    await settle();
    findFirstButtonByText(h.getRoot(), 'Manage').click();
    await settle(6);

    const decertifyBtn = findFirstButtonByText(h.getRoot(), 'Decertify');
    t.isDefined(decertifyBtn, 'Decertify renders as a <button>');
    t.equals(decertifyBtn.tagName, 'button', 'a real <button> -- natively Tab-reachable and Enter/Space-activatable, never a div with an onclick');
    t.isFalse(decertifyBtn.classList.contains('k9tablet-btn--armed'), 'resting state carries no armed styling');

    // Reachable and activatable exactly like a mouse click: this stub's
    // own .click() is what a real Enter/Space keypress on a focused
    // button also fires (both dispatch the element's 'click' listeners --
    // this page never distinguishes the input device a click came from).
    decertifyBtn.focus();
    decertifyBtn.click();
    t.equals(decertifyBtn._textContent, 'Confirm?', 'first press only arms the confirmation');
    t.isTrue(decertifyBtn.classList.contains('k9tablet-btn--armed'), 'the armed state carries its OWN distinct class -- a keyboard user has no mouse-hover cue at all, so the visual difference cannot rely on :hover');

    decertifyBtn.click();
    await settle(4);
    t.isTrue(h.fetchCalls.some((c) => c.url.endsWith('tablet:decertify')), 'the second press actually fires the request');
});

// ======================================================================
// 2. ESCAPE CLOSES FROM A DEEP SCREEN, NOT ONLY FROM HOME
// ======================================================================

t.test('Escape closes the tablet from deep inside Console -> a specific Person screen, exactly like from Home', async () => {
    const h = createHarness({
        fetchImpl: routeFetch({
            'tablet:requestMyRecord': () => ({ ok: true, viewer: HIGH_COMMAND_VIEWER, certifications: [], xp: null, tierLabel: null, myFeatures: [] }),
            'tablet:requestRoster': () => ({ ok: true, rows: [{ citizenid: 'TARGET1', name: 'K9 Rex', departmentLabel: 'Police', certified: true, xp: 0, tierLabel: 'Recruit K9' }], truncated: false }),
            'tablet:requestPersonSummary': () => ({ ok: true, target: { citizenid: 'TARGET1', name: 'K9 Rex' }, certifications: [], xp: 0, tierLabel: 'Recruit K9', permissions: [] }),
            'tablet:requestPersonFeatures': () => ({ ok: true, target: { citizenid: 'TARGET1', name: 'K9 Rex' }, features: [] }),
            'tablet:close': () => ({}),
        }),
    });
    h.postMessage('tablet:open', {});
    await settle();
    findFirstButtonByText(h.getRoot(), 'Command Console').click();
    await settle();
    findFirstButtonByText(h.getRoot(), 'Manage').click();
    await settle(6);

    t.isTrue(findByText(h.getRoot(), 'K9 Rex').length >= 1, 'sanity: really is deep on the Person screen before Escape');
    h.dispatchKeydown('Escape');
    t.equals(h.getRoot().children.length, 0, 'Escape closes from the Person screen exactly like from Home');
    t.isTrue(h.fetchCalls.some((c) => c.url.endsWith('tablet:close')), 'and still notifies Lua');
});

// ======================================================================
// 3. FOCUS AFTER A MUTATION, AND ACROSS A LIVE-FILTER RE-RENDER
// ======================================================================

t.test('after a mutation settles, focus lands on the result notice -- never lost to nothing', async () => {
    const h = createHarness({
        fetchImpl: routeFetch({
            'tablet:requestMyRecord': () => ({
                ok: true,
                viewer: { citizenid: 'A', name: 'A', isHighCommand: false, effectivePermissions: [], allowSelfGrant: false },
                certifications: [], xp: null, tierLabel: null,
                myFeatures: [{ key: 'Recall', label: 'Recall your K9', category: null, actionable: true, state: 'available' }],
            }),
            'tablet:triggerFeature': () => ({ ok: true, message: 'Recall sent.' }),
        }),
    });
    h.postMessage('tablet:open', {});
    await settle();

    const useBtn = findFirstButtonByText(h.getRoot(), 'Use');
    t.isDefined(useBtn, 'sanity: the Home screen\'s own "ready abilities" Use button exists');
    useBtn.focus();
    useBtn.click();
    await settle(4);

    const active = h.doc.activeElement;
    t.isDefined(active, 'something is focused -- not lost to bare document.body');
    t.isTrue(!!(active && active.classList && active.classList.contains('k9tablet-notice')), 'focus landed on the action notice, which just told the operator what happened');
    t.equals(active._textContent, 'Recall sent.', 'and it is announced -- role="status"/aria-live on this exact element, see buildActionNotice()');
    t.equals(active.getAttribute('role'), 'status');
    t.equals(active.getAttribute('aria-live'), 'polite');
});

t.test('an error notice is announced assertively, and still receives focus', async () => {
    const h = createHarness({
        fetchImpl: routeFetch({
            'tablet:requestMyRecord': () => ({
                ok: true,
                viewer: { citizenid: 'A', name: 'A', isHighCommand: false, effectivePermissions: [], allowSelfGrant: false },
                certifications: [], xp: null, tierLabel: null,
                myFeatures: [{ key: 'Recall', label: 'Recall your K9', category: null, actionable: true, state: 'available' }],
            }),
            'tablet:triggerFeature': () => ({ ok: false, message: 'On cooldown.' }),
        }),
    });
    h.postMessage('tablet:open', {});
    await settle();
    findFirstButtonByText(h.getRoot(), 'Use').click();
    await settle(4);

    const active = h.doc.activeElement;
    t.isTrue(!!(active && active.classList && active.classList.contains('k9tablet-notice--error')), 'error notice receives focus too');
    t.equals(active.getAttribute('role'), 'alert');
    t.equals(active.getAttribute('aria-live'), 'assertive');
});

t.test('a live-filter search box keeps its OWN focus and cursor position across the re-render it triggers on every keystroke', async () => {
    const h = createHarness({
        fetchImpl: routeFetch({
            'tablet:requestMyRecord': () => ({ ok: true, viewer: { citizenid: 'A', name: 'A', isHighCommand: false, effectivePermissions: [], allowSelfGrant: false }, certifications: [], xp: null, tierLabel: null, myFeatures: [] }),
        }),
    });
    h.postMessage('tablet:open', {});
    await settle();
    findFirstButtonByText(h.getRoot(), 'Guide').click();
    await settle();

    const search = findAll(h.getRoot(), (n) => n.tagName === 'input' && n.classList.contains('k9tablet-search'))[0];
    t.isDefined(search, 'the command reference\'s own live-filter box exists');

    // Before this pass, render()'s own clearChildren(rootEl) destroyed and
    // rebuilt this exact input on EVERY keystroke (buildCommandReferenceScreen()
    // calls render() synchronously from its own `input` handler), which a
    // real browser blurs back to <body> -- the "type one character,
    // re-click the box, type one character" bug this proves is fixed.
    search.focus();
    search.value = 'k9';
    search.setSelectionRange(2, 2);
    search._dispatch('input', { target: search });

    const active = h.doc.activeElement;
    t.isDefined(active, 'focus was not lost to the rebuild');
    t.isTrue(!!(active && active.classList && active.classList.contains('k9tablet-search')), 'the (freshly rebuilt) search box itself kept the focus');
    t.equals(active.value, 'k9', 'and its typed value');
    t.equals(active.selectionStart, 2, 'and its cursor position -- not reset to the start/end');
});

t.test('opening the tablet moves focus INTO the dialog panel, never leaving it wherever it happened to be beforehand', async () => {
    const h = createHarness({
        fetchImpl: routeFetch({
            'tablet:requestMyRecord': () => ({ ok: true, viewer: { citizenid: 'A', name: 'A', isHighCommand: false, effectivePermissions: [], allowSelfGrant: false }, certifications: [], xp: null, tierLabel: null, myFeatures: [] }),
        }),
    });
    t.isNull(h.doc.activeElement, 'sanity: nothing focused before tablet:open');
    h.postMessage('tablet:open', {});
    await settle();

    const active = h.doc.activeElement;
    t.isDefined(active, 'something is focused immediately on open');
    t.isTrue(!!(active && active.classList && active.classList.contains('k9tablet-panel')), 'specifically the dialog panel itself (role="dialog"/aria-modal, tabindex="-1")');
    t.equals(active.getAttribute('role'), 'dialog');
});

// ======================================================================
// 4. DOUBLE-SUBMIT: A RAPID SECOND ACTIVATION NEVER FIRES TWICE
// ======================================================================

t.test('rapidly activating a mutating button twice (double-click, or a stray repeat keypress) fires its NUI callback exactly once', async () => {
    let triggerCalls = 0;
    const h = createHarness({
        fetchImpl: routeFetch({
            'tablet:requestMyRecord': () => ({
                ok: true,
                viewer: { citizenid: 'A', name: 'A', isHighCommand: false, effectivePermissions: [], allowSelfGrant: false },
                certifications: [], xp: null, tierLabel: null,
                myFeatures: [{ key: 'Recall', label: 'Recall your K9', category: null, actionable: true, state: 'available' }],
            }),
            'tablet:triggerFeature': () => { triggerCalls++; return { ok: true, message: 'Recall sent.' }; },
        }),
    });
    h.postMessage('tablet:open', {});
    await settle();

    const useBtn = findFirstButtonByText(h.getRoot(), 'Use');
    // Two activations back-to-back, synchronously, exactly as two fast
    // clicks (or two Enter keypresses landing on the same still-focused
    // button) would arrive before either promise has settled.
    useBtn.click();
    useBtn.click();
    await settle(4);

    t.equals(triggerCalls, 1, 'the second activation was refused (state.pendingAction + the disabled attribute mkButton() sets synchronously) -- never two grants/triggers for one double-press');
});

// ======================================================================
// 5. SCROLL POSITION SURVIVES A SAME-SCREEN RE-RENDER, RESETS ON A
//    GENUINE SCREEN CHANGE (the DOM-testable half of "long content")
// ======================================================================

t.test('a same-screen re-render preserves .k9tablet-screen scrollTop; navigating to a different screen starts it at the top', async () => {
    const h = createHarness({
        fetchImpl: routeFetch({
            'tablet:requestMyRecord': () => ({
                ok: true,
                viewer: { citizenid: 'A', name: 'A', isHighCommand: false, effectivePermissions: [], allowSelfGrant: false },
                certifications: [], xp: null, tierLabel: null, myFeatures: [],
            }),
        }),
    });
    h.postMessage('tablet:open', {});
    await settle();
    findFirstButtonByText(h.getRoot(), 'Guide').click();
    await settle();

    function screenEl() {
        return findAll(h.getRoot(), (n) => n.classList && n.classList.contains('k9tablet-screen'))[0];
    }

    t.isDefined(screenEl(), 'sanity: the Commands screen has the one scrollable wrapper every screen uses');
    screenEl().scrollTop = 240;

    // Same-screen re-render (the live filter re-render, exactly like the
    // focus-preservation test above triggers) -- scrollTop must survive it.
    const search = findAll(h.getRoot(), (n) => n.tagName === 'input' && n.classList.contains('k9tablet-search'))[0];
    search.typeValue('k9');
    await settle();
    t.equals(screenEl().scrollTop, 240, 'scrollTop survived a same-screen re-render (a fresh scroll container element, but render() restores its position)');

    // A genuine screen change (a different tab) is a DIFFERENT screen --
    // starting at the top there is correct, not a bug.
    findFirstButtonByText(h.getRoot(), 'My Record').click();
    await settle();
    t.equals(screenEl().scrollTop, 0, 'a real navigation starts the new screen at the top, never carrying over an unrelated scroll position');
});

// ======================================================================
// 6. ENTER SUBMITS THE ONE OBVIOUS ACTION -- AND ONLY WHEN THERE IS ONE
// ======================================================================

t.test('Enter in a lone toolbar field fires the one nearby button (Open by ID)', async () => {
    const h = createHarness({
        fetchImpl: routeFetch({
            'tablet:requestMyRecord': () => ({ ok: true, viewer: HIGH_COMMAND_VIEWER, certifications: [], xp: null, tierLabel: null, myFeatures: [] }),
            'tablet:requestRoster': () => ({ ok: true, rows: [], truncated: false }),
            'tablet:requestPersonSummary': () => ({ ok: true, target: { citizenid: 'TARGET9', name: 'K9 Nine' }, certifications: [], xp: null, tierLabel: null, permissions: [] }),
            'tablet:requestPersonFeatures': () => ({ ok: true, target: { citizenid: 'TARGET9', name: 'K9 Nine' }, features: [] }),
        }),
    });
    h.postMessage('tablet:open', {});
    await settle();
    findFirstButtonByText(h.getRoot(), 'Command Console').click();
    await settle();

    const idInput = findAll(h.getRoot(), (n) => n.tagName === 'input' && n.getAttribute('placeholder') === 'Name, citizen ID or server ID...')[0];
    t.isDefined(idInput, 'the "open by ID" box exists');
    idInput.focus();
    idInput.value = 'TARGET9';
    idInput._dispatch('input', { target: idInput });

    h.dispatchKeydown('Enter');
    await settle(4);

    t.isTrue(findByText(h.getRoot(), 'K9 Nine').length >= 1, 'Enter opened the person exactly like clicking the Open button would have');
});

t.test('Enter in a draft form field fires the form\'s own Save, when Save is the ONLY button in scope', async () => {
    const h = createHarness({
        fetchImpl: routeFetch({
            'tablet:requestMyRecord': () => ({ ok: true, viewer: HIGH_COMMAND_VIEWER, certifications: [], xp: null, tierLabel: null, myFeatures: [] }),
            'tablet:certTiersList': () => ({ ok: true, tiers: [], capabilityCatalog: {} }),
            'tablet:certTiersUpsert': (body) => ({ ok: true, tiers: [{ key: body.key, label: body.label, ordinal: 1, capabilities: body.capabilities }] }),
        }),
    });
    h.postMessage('tablet:open', {});
    await settle();
    openSettingsSection(h.getRoot(), 'Catalogs');
    await settle();
    findFirstButtonByText(h.getRoot(), 'Add New Tier').click();
    await settle();

    const labelInput = findAll(h.getRoot(), (n) => n.tagName === 'input' && n.classList.contains('k9tablet-cert-tier-label-input'))[0];
    t.isDefined(labelInput, 'the new-tier draft\'s own Label field exists');
    labelInput.focus();
    labelInput.value = 'Elite';
    labelInput._dispatch('input', { target: labelInput });
    const keyInput = findAll(h.getRoot(), (n) => n.tagName === 'input' && n.classList.contains('k9tablet-cert-tier-key-input'))[0];
    keyInput.value = 'elite';
    keyInput._dispatch('input', { target: keyInput });

    h.dispatchKeydown('Enter');
    await settle(4);

    t.isTrue(h.fetchCalls.some((c) => c.url.endsWith('tablet:certTiersUpsert') && c.body.key === 'elite' && c.body.label === 'Elite'), 'Enter fired the SAME tablet:certTiersUpsert callback the Save button uses, with the real drafted fields');
});

t.test('Enter is a safe no-op when more than one button is in scope -- never guesses, never fires a destructive one', async () => {
    const h = createHarness({
        fetchImpl: routeFetch({
            'tablet:requestMyRecord': () => ({ ok: true, viewer: HIGH_COMMAND_VIEWER, certifications: [], xp: null, tierLabel: null, myFeatures: [] }),
            'tablet:requestRoster': () => ({ ok: true, rows: [{ citizenid: 'TARGET1', name: 'K9 Rex', departmentLabel: 'Police', certified: false, xp: 0, tierLabel: null }], truncated: false }),
            'tablet:requestPersonSummary': () => ({ ok: true, target: { citizenid: 'TARGET1', name: 'K9 Rex' }, certifications: [], xp: 0, tierLabel: null, permissions: [] }),
            'tablet:requestPersonFeatures': () => ({
                ok: true,
                target: { citizenid: 'TARGET1', name: 'K9 Rex' },
                features: [
                    { key: 'FeatureA', label: 'Feature A', category: null, globallyEnabled: true, requiresGrant: true, granted: false, blocked: false, state: 'requires_grant_missing' },
                    { key: 'FeatureB', label: 'Feature B', category: null, globallyEnabled: true, requiresGrant: true, granted: false, blocked: false, state: 'requires_grant_missing' },
                ],
            }),
            'tablet:grantFeature': () => ({ ok: true }),
        }),
    });
    h.postMessage('tablet:open', {});
    await settle();
    findFirstButtonByText(h.getRoot(), 'Command Console').click();
    await settle();
    findFirstButtonByText(h.getRoot(), 'Manage').click();
    await settle(6);

    // Scoped to the feature section itself, not the whole Person screen --
    // a high-command viewer's Person screen ALSO renders capability
    // Grant/Revoke chips elsewhere on the same page (buildCapabilityList()),
    // which is exactly why findEnterSubmitTarget()'s own ambiguity check
    // must stay narrowly scoped rather than searching the whole screen; a
    // page-wide count would be a coincidence of fixture data, not what
    // this test is actually proving.
    const featureSection = findAll(h.getRoot(), (n) => n.classList && n.classList.contains('k9tablet-feature-section'))[0];
    t.isDefined(featureSection, 'sanity: the per-person feature section exists');
    t.equals(findByText(featureSection, 'Grant').length, 2, 'sanity: two equally-plausible Grant buttons are on screen at once, in the SAME section as the search box');

    const featureSearch = findAll(featureSection, (n) => n.tagName === 'input' && n.getAttribute('placeholder') === 'Search abilities...')[0];
    t.isDefined(featureSearch, 'the per-person feature search box exists');
    featureSearch.focus();

    h.dispatchKeydown('Enter');
    await settle(4);

    t.isFalse(h.fetchCalls.some((c) => c.url.endsWith('tablet:grantFeature')), 'Enter fired NOTHING -- with two candidates in scope, guessing which Grant was meant is exactly the "does the wrong thing" failure mode this must never produce');
});

t.run();
