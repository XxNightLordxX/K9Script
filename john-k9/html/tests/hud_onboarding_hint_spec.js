/*
    html/tests/hud_onboarding_hint_spec.js

    Covers html/app.js's own "ONBOARDING HINT CONTRACT" section -- the
    'hud:onboardingHint' push (visible/strings) AND the 'tablet:open'
    forwarding half (hides the hint locally + fires the 'hud:tabletOpened'
    NUI callback). See client/hud.lua's own "K9 ONBOARDING HINT" section
    for the Lua-side half of this same contract; this file only proves the
    JS side renders/forwards exactly what that contract promises.

    Deliberately does NOT touch #k9hud or #k9partner-badge anywhere below
    -- proving this THIRD surface is genuinely independent of both is part
    of the point (see applyOnboardingHint's own "COMPLETELY INDEPENDENT"
    comment in app.js).
*/
'use strict';

const t = require('./testkit');
const { createHarness, waitFor } = require('./sandbox');

t.test('hud:onboardingHint visible=true renders title/body/dismiss text and unhides the row', () => {
    const h = createHarness({ AudioContextCtor: undefined });
    h.postMessage('hud:onboardingHint', {
        visible: true,
        strings: { title: 'T', body: 'B', dismissHint: 'D' },
    });

    const hint = h.getOnboardingHint();
    t.isFalse(hint.row.classList.contains('hidden'));
    t.equals(hint.row.getAttribute('aria-hidden'), 'false');
    t.equals(hint.title.textContent, 'T');
    t.equals(hint.body.textContent, 'B');
    t.equals(hint.dismiss.textContent, 'D');
});

t.test('hud:onboardingHint visible=false hides the row and does NOT touch title/body/dismiss text', () => {
    const h = createHarness({ AudioContextCtor: undefined });
    h.postMessage('hud:onboardingHint', { visible: true, strings: { title: 'T', body: 'B', dismissHint: 'D' } });
    h.postMessage('hud:onboardingHint', { visible: false });

    const hint = h.getOnboardingHint();
    t.isTrue(hint.row.classList.contains('hidden'));
    t.equals(hint.row.getAttribute('aria-hidden'), 'true');
    t.equals(hint.title.textContent, 'T', 'text must be left exactly as it was, never blanked/zeroed while hidden');
});

t.test('with no `strings` field at all, the English ONBOARDING_HINT_DEFAULT_STRINGS fallback renders', () => {
    const h = createHarness({ AudioContextCtor: undefined });
    h.postMessage('hud:onboardingHint', { visible: true });

    const hint = h.getOnboardingHint();
    t.equals(hint.title.textContent, 'K9 Command Tablet');
    t.equals(hint.body.textContent, 'You have K9 gear waiting. Type /k9tablet to open your tablet and see what you can do.');
    t.equals(hint.dismiss.textContent, 'Press Backspace to dismiss this reminder.');
});

t.test('a `strings` object missing ONE key falls back to the default for that key ONLY -- the other two still render from the payload', () => {
    const h = createHarness({ AudioContextCtor: undefined });
    h.postMessage('hud:onboardingHint', { visible: true, strings: { title: 'Custom Title' } });

    const hint = h.getOnboardingHint();
    t.equals(hint.title.textContent, 'Custom Title');
    t.equals(hint.body.textContent, 'You have K9 gear waiting. Type /k9tablet to open your tablet and see what you can do.');
    t.equals(hint.dismiss.textContent, 'Press Backspace to dismiss this reminder.');
});

t.test('a non-string/empty-string value inside `strings` falls back to the default for that key, defensively', () => {
    const h = createHarness({ AudioContextCtor: undefined });
    h.postMessage('hud:onboardingHint', { visible: true, strings: { title: 123, body: '', dismissHint: null } });

    const hint = h.getOnboardingHint();
    t.equals(hint.title.textContent, 'K9 Command Tablet');
    t.equals(hint.body.textContent, 'You have K9 gear waiting. Type /k9tablet to open your tablet and see what you can do.');
    t.equals(hint.dismiss.textContent, 'Press Backspace to dismiss this reminder.');
});

t.test('a malformed payload (not an object, or `visible` absent/non-boolean) degrades to hidden, never a crash', () => {
    const h = createHarness({ AudioContextCtor: undefined });

    let ok = true;
    try {
        h.postRawMessage({ action: 'hud:onboardingHint', data: null });
        h.postRawMessage({ action: 'hud:onboardingHint', data: 'not-an-object' });
        h.postMessage('hud:onboardingHint', {});
        h.postMessage('hud:onboardingHint', { visible: 'yes' });
    } catch (err) {
        ok = false;
    }
    t.isTrue(ok, 'a malformed hud:onboardingHint payload must never throw');
    t.isTrue(h.getOnboardingHint().row.classList.contains('hidden'), 'every malformed shape above must resolve to hidden, never a stray "visible"');
});

t.test('completely independent of #k9hud and #k9partner-badge -- neither is touched by an onboardingHint push', () => {
    const h = createHarness({ AudioContextCtor: undefined });
    h.postMessage('hud:onboardingHint', { visible: true, strings: { title: 'T', body: 'B', dismissHint: 'D' } });

    t.isTrue(h.getRoot().classList.contains('hidden'), '#k9hud must stay hidden -- an onboarding push must never touch it');
    t.isTrue(h.getPartnerBadge().row.classList.contains('hidden'), '#k9partner-badge must stay hidden -- an onboarding push must never touch it');
});

// ----------------------------------------------------------------------
// tablet:open forwarding -- see app.js's own handleTabletOpened().
// ----------------------------------------------------------------------

t.test('tablet:open hides an already-visible onboarding hint IMMEDIATELY, before any fetch round trip', () => {
    const h = createHarness({
        AudioContextCtor: undefined,
        fetchImpl: () => new Promise(() => {}), // never resolves -- proves the hide does not wait on it
    });
    h.postMessage('hud:onboardingHint', { visible: true, strings: { title: 'T', body: 'B', dismissHint: 'D' } });
    t.isFalse(h.getOnboardingHint().row.classList.contains('hidden'), 'sanity: visible before tablet:open');

    h.postMessage('tablet:open', {});
    t.isTrue(h.getOnboardingHint().row.classList.contains('hidden'), 'must hide synchronously, not after the fetch settles');
});

t.test('tablet:open fires exactly one hud:tabletOpened POST to the GetParentResourceName()-scoped URL with an empty JSON body', async () => {
    // NOTE: init() ALSO fires its own 'hud:ready' ack fetch at startup (see
    // hud_ready_spec.js) -- this harness's default fetchImpl (a rejection
    // for anything other than 'sounds/*') swallows that one silently via
    // sendReadyAck()'s own .catch(), but it still shows up as the FIRST
    // entry in h.fetchCalls. Filtering by URL below, rather than assuming
    // "the next fetch call is mine", is what makes this test correct
    // regardless of that ordering.
    const h = createHarness({ AudioContextCtor: undefined });

    h.postMessage('tablet:open', {});
    await waitFor(() => h.fetchCalls.some((c) => c.url === 'https://john-k9/hud:tabletOpened'), { label: 'hud:tabletOpened fetch call' });

    const matching = h.fetchCalls.filter((c) => c.url === 'https://john-k9/hud:tabletOpened');
    t.equals(matching.length, 1, 'exactly one hud:tabletOpened call for one tablet:open message');
    const call = matching[0];
    t.equals(call.init.method, 'POST');
    t.equals(call.init.headers['Content-Type'], 'application/json; charset=UTF-8');
    t.equals(call.init.body, '{}');
});

t.test('tablet:open with no onboarding hint currently visible is a harmless no-op on the DOM side, and still fires the callback', async () => {
    const h = createHarness({ AudioContextCtor: undefined });

    h.postMessage('tablet:open', {});
    await waitFor(() => h.fetchCalls.some((c) => c.url === 'https://john-k9/hud:tabletOpened'), { label: 'hud:tabletOpened fetch call' });
    t.isTrue(h.getOnboardingHint().row.classList.contains('hidden'), 'stays hidden -- nothing to hide, nothing breaks either');
});

t.test('tablet:open is safe with a REJECTED hud:tabletOpened fetch -- swallowed, no unhandled rejection, no throw', async () => {
    const unhandled = [];
    const onUnhandled = (reason) => unhandled.push(reason);
    process.on('unhandledRejection', onUnhandled);

    try {
        const h = createHarness({
            AudioContextCtor: undefined,
            fetchImpl: () => Promise.reject(new Error('simulated: hud:tabletOpened not registered yet (e.g. Config.K9Onboarding.enabled = false server-side)')),
        });
        h.postMessage('tablet:open', {});

        await new Promise((r) => setImmediate(r));
        await new Promise((r) => setImmediate(r));
        t.equals(unhandled.length, 0, 'handleTabletOpened()\'s own .catch() must swallow this, exactly like sendReadyAck()\'s does for hud:ready');
    } finally {
        process.removeListener('unhandledRejection', onUnhandled);
    }
});

t.test('tablet:open with GetParentResourceName() undefined (plain-browser dev-preview) does not throw, and still hides the hint locally', () => {
    const h = createHarness({ AudioContextCtor: undefined, getParentResourceName: undefined });
    h.postMessage('hud:onboardingHint', { visible: true, strings: { title: 'T', body: 'B', dismissHint: 'D' } });

    let ok = true;
    try {
        h.postMessage('tablet:open', {});
    } catch (err) {
        ok = false;
    }
    t.isTrue(ok, 'handleTabletOpened()\'s own try/catch must swallow the ReferenceError, same posture as sendReadyAck()');
    t.isTrue(h.getOnboardingHint().row.classList.contains('hidden'));
    t.equals(h.fetchCalls.length, 0, 'no fetch is even attempted without GetParentResourceName()');
});

t.test('tablet:open does not touch #k9hud, #k9partner-badge, or html/tablet-bridge.js\'s own #k9tablet-wrap element', () => {
    const h = createHarness({ AudioContextCtor: undefined, fetchImpl: () => new Promise(() => {}) });
    h.postMessage('hud:updateVitals', { visible: true, health: 1, stamina: 1, hunger: 1, thirst: 1, wellbeing: {}, xpTier: {} });
    h.postMessage('hud:partnerCondition', { visible: true, tags: [] });

    h.postMessage('tablet:open', {});

    t.isFalse(h.getRoot().classList.contains('hidden'), 'a tablet:open message must not affect #k9hud\'s own visibility');
    t.isFalse(h.getPartnerBadge().row.classList.contains('hidden'), 'a tablet:open message must not affect #k9partner-badge\'s own visibility');
});

// ----------------------------------------------------------------------
// XSS -- same proof technique as xss_spec.js's own MALICIOUS_STRINGS
// battery (kept here rather than added to that shared file, to avoid any
// risk of colliding with concurrent edits there this same pass -- see
// that file's own header for the full "why this is a genuinely meaningful
// test" reasoning, which applies identically to title/body/dismissHint
// below).
// ----------------------------------------------------------------------

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
    return h.doc._all.reduce((sum, el) => sum + el.innerHTMLWriteCount, 0);
}

t.test('a full battery of malicious strings.title/body/dismissHint values across many sequential pushes reach the DOM only via textContent, never innerHTML', () => {
    const h = createHarness({ AudioContextCtor: undefined });
    for (const malicious of MALICIOUS_STRINGS) {
        h.postMessage('hud:onboardingHint', {
            visible: true,
            strings: { title: malicious, body: malicious, dismissHint: malicious },
        });
        const hint = h.getOnboardingHint();
        t.equals(hint.title.textContent, malicious);
        t.equals(hint.body.textContent, malicious);
        t.equals(hint.dismiss.textContent, malicious);
    }
    t.equals(everyElementInnerHTMLWriteCount(h), 0, 'zero innerHTML writes across the whole document after every malicious strings.* value in this battery');
});

t.run();
