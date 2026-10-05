/*
    html/tests/tablet_open_close_spec.js

    Covers html/tablet.js's open/close lifecycle: the tablet:ready
    handshake, tablet:open making the page visible and kicking off
    tablet:requestMyRecord, the loading/error/timeout states for that
    fetch, and every path back to closed (Close button, Escape inside this
    document, and a Lua-initiated tablet:close push) -- per this file's own
    header, the close path is the single most safety-critical thing here
    (a stuck NUI focus locks the player out of their own game), so every
    close trigger is proven independently, not just one of them.
*/
'use strict';

const t = require('./testkit');
const { createHarness, jsonResponse } = require('./tablet-sandbox');
const { findByText, findByTag } = require('./tablet-dom-stub');

function routeFetch(handlers) {
    return function (url) {
        const name = url.split('/').pop();
        const h = handlers[name];
        if (!h) return Promise.reject(new Error('tablet_open_close_spec: unhandled NUI callback ' + name));
        return Promise.resolve(jsonResponse(h()));
    };
}

const NEVER_RESOLVING_MY_RECORD = {
    'tablet:requestMyRecord': () => new Promise(() => {}),
};

t.test('fires exactly one tablet:ready POST at startup, to the GetParentResourceName()-scoped URL, with an empty JSON body', async () => {
    let resolvedFetch;
    const fetchPromise = new Promise((resolve) => { resolvedFetch = resolve; });

    createHarness({
        fetchImpl: (url, init) => {
            resolvedFetch({ url, init });
            return Promise.resolve(jsonResponse({}));
        },
    });

    const call = await fetchPromise;
    t.equals(call.url, 'https://john-k9/tablet:ready');
    t.equals(call.init.method, 'POST');
    t.equals(call.init.body, '{}');
});

t.test('before any tablet:open message, the page renders nothing at all', async () => {
    const h = createHarness({ fetchImpl: routeFetch({}) });
    await new Promise((r) => setImmediate(r));
    t.equals(h.getRoot().children.length, 0, 'root stays empty until tablet:open arrives');
});

t.test('tablet:open makes the page visible immediately and shows a loading state while requestMyRecord is in flight', async () => {
    const h = createHarness({ fetchImpl: routeFetch(NEVER_RESOLVING_MY_RECORD) });
    h.postMessage('tablet:open', { capabilities: {}, strings: {}, maxXpPerGrant: 500 });
    await new Promise((r) => setImmediate(r));

    t.isTrue(findByText(h.getRoot(), 'K9 Command Tablet').length >= 1, 'title renders even before viewer data arrives');
    t.isTrue(findByText(h.getRoot(), 'Loading...').length >= 1, 'a loading message is shown, never a blank screen');
});

t.test('a successful tablet:requestMyRecord renders certifications, XP/tier, and the abilities list', async () => {
    const h = createHarness({
        fetchImpl: routeFetch({
            'tablet:requestMyRecord': () => ({
                ok: true,
                viewer: { citizenid: 'ABC123', name: 'Rex', isHighCommand: false, effectivePermissions: [], allowSelfGrant: false },
                certifications: [{ departmentKey: 'police', departmentLabel: 'Los Santos Police Department', active: true, grantedBy: 'XYZ999' }],
                xp: 1250,
                tierLabel: 'Trained K9',
                // The ladder is part of the real tabletRequestMyRecord
                // payload and is now needed here: the XP standing is
                // rendered by the ladder block that came from the old
                // Progression tab (plan item A), and an EMPTY ladder
                // legitimately means "this server does not track XP" and
                // renders that instead of a total.
                xpLadder: [{ xp: 0, label: 'Green K9' }, { xp: 1000, label: 'Trained K9' }],
                handlerXpLadder: [],
                myFeatures: [
                    { key: 'Recall', label: 'Recall your K9', category: 'Combat', actionable: true, state: 'available' },
                    { key: 'BiteAndHold', label: 'Bite and Hold', category: 'Combat', actionable: true, state: 'requires_grant_missing' },
                ],
            }),
        }),
    });

    h.postMessage('tablet:open', { capabilities: {}, strings: {}, maxXpPerGrant: null });
    await new Promise((r) => setImmediate(r));
    await new Promise((r) => setImmediate(r));

    // NO NAVIGATION NEEDED ANY MORE. The landing screen used to show only
    // summary counts, with the department label / XP line / abilities on a
    // separate My Record tab; plan item A merged Home, My Record and
    // Progression into this one screen, so everything this test asserts is
    // already on it.

    const root = h.getRoot();
    t.isTrue(findByText(root, 'Los Santos Police Department').length >= 1, 'certification department label rendered');
    // The plain "1250 — Trained K9" line is gone: the ladder block that
    // came from the Progression tab says the same thing and then where that
    // total sits on the ladder, so keeping both would have printed the
    // viewer's XP twice on one screen.
    t.isTrue(findByText(root, '1250 XP -- Trained K9').length >= 1, 'XP + rank standing rendered');
    t.isTrue(findByText(root, 'Recall your K9').length >= 1, 'available feature label rendered');
    t.equals(findByText(root, 'Bite and Hold').length, 0, 'an ability still needing a grant is not listed -- only what you can use is');
    t.equals(findByText(root, 'Requires a grant (not granted)').length, 0, 'no "not granted" row either');

    // Only the AVAILABLE + actionable feature gets a trigger button.
    const useButtons = findByText(root, 'Use');
    t.equals(useButtons.length, 1, 'exactly one Use button -- only for the available+actionable feature');
});

t.test('clicking Use on an available ability fires tablet:triggerFeature with the right key, then refreshes myRecord', async () => {
    let triggerCalls = 0;
    let myRecordCalls = 0;
    const h = createHarness({
        fetchImpl: routeFetch({
            'tablet:requestMyRecord': () => {
                myRecordCalls++;
                return {
                    ok: true,
                    viewer: { citizenid: 'ABC123', name: 'Rex', isHighCommand: false, effectivePermissions: [], allowSelfGrant: false },
                    certifications: [],
                    xp: null,
                    tierLabel: null,
                    myFeatures: [{ key: 'Recall', label: 'Recall your K9', category: null, actionable: true, state: 'available' }],
                };
            },
            'tablet:triggerFeature': () => {
                triggerCalls++;
                return { ok: true, message: 'Recall sent.' };
            },
        }),
    });

    h.postMessage('tablet:open', {});
    await new Promise((r) => setImmediate(r));
    await new Promise((r) => setImmediate(r));

    const useBtn = findByText(h.getRoot(), 'Use')[0];
    t.isDefined(useBtn, 'Use button exists');
    useBtn.click();

    const lastTriggerBody = () => h.fetchCalls.filter((c) => c.url.endsWith('tablet:triggerFeature')).slice(-1)[0].body;
    await new Promise((r) => setTimeout(r, 30));

    t.equals(triggerCalls, 1);
    t.equals(lastTriggerBody().feature, 'Recall');
    t.isTrue(myRecordCalls >= 2, 'myRecord is re-fetched after the trigger settles (never trusts local cached state)');
});

t.test('a fetch that never resolves eventually shows the synthesized timeout error, with a working Retry', async () => {
    let attempts = 0;
    const h = createHarness({
        fetchImpl: routeFetch({
            'tablet:requestMyRecord': () => {
                attempts++;
                if (attempts === 1) return new Promise(() => {}); // first attempt hangs forever
                return { ok: true, viewer: { citizenid: 'A', name: 'A', isHighCommand: false, effectivePermissions: [], allowSelfGrant: false }, certifications: [], xp: null, tierLabel: null, myFeatures: [] };
            },
        }),
    });

    h.postMessage('tablet:open', {});
    // Compressed NUI_TIMEOUT_MS -- see tablet-sandbox.js's own header.
    await new Promise((r) => setTimeout(r, 60));

    t.isTrue(findByText(h.getRoot(), 'The server did not respond in time.').length >= 1, 'synthetic timeout renders a clear, specific failure state, never a blank screen');
    const retryBtn = findByText(h.getRoot(), 'Retry')[0];
    t.isDefined(retryBtn);
    retryBtn.click();
    await new Promise((r) => setImmediate(r));
    await new Promise((r) => setImmediate(r));
    t.equals(attempts, 2, 'Retry re-issues the request');
});

t.test('an explicit ok:false response with a message renders that message verbatim', async () => {
    const h = createHarness({
        fetchImpl: routeFetch({ 'tablet:requestMyRecord': () => ({ ok: false, error: 'server_error', message: 'Database unavailable.' }) }),
    });
    h.postMessage('tablet:open', {});
    await new Promise((r) => setImmediate(r));
    await new Promise((r) => setImmediate(r));
    t.isTrue(findByText(h.getRoot(), 'Database unavailable.').length >= 1);
});

t.test('the Close button hides the page immediately and fires tablet:close, even if that fetch hangs forever', async () => {
    const h = createHarness({
        fetchImpl: routeFetch({
            'tablet:requestMyRecord': () => ({ ok: true, viewer: { citizenid: 'A', name: 'A', isHighCommand: false, effectivePermissions: [], allowSelfGrant: false }, certifications: [], xp: null, tierLabel: null, myFeatures: [] }),
            'tablet:close': () => new Promise(() => {}), // must never block the local close
        }),
    });
    h.postMessage('tablet:open', {});
    await new Promise((r) => setImmediate(r));
    await new Promise((r) => setImmediate(r));
    t.isTrue(h.getRoot().children.length > 0, 'sanity: page is open first');

    const closeBtn = findByTag(h.getRoot(), 'button').filter((b) => b._textContent === '×')[0];
    t.isDefined(closeBtn, 'close button (×) exists');
    closeBtn.click();

    t.equals(h.getRoot().children.length, 0, 'root is cleared SYNCHRONOUSLY on click -- never waits on the tablet:close round trip');
    t.isTrue(h.fetchCalls.some((c) => c.url.endsWith('tablet:close')), 'tablet:close was still fired (fire-and-forget)');
});

t.test('pressing Escape inside this document closes the tablet and notifies Lua', async () => {
    const h = createHarness({
        fetchImpl: routeFetch({
            'tablet:requestMyRecord': () => ({ ok: true, viewer: { citizenid: 'A', name: 'A', isHighCommand: false, effectivePermissions: [], allowSelfGrant: false }, certifications: [], xp: null, tierLabel: null, myFeatures: [] }),
            'tablet:close': () => ({}),
        }),
    });
    h.postMessage('tablet:open', {});
    await new Promise((r) => setImmediate(r));
    await new Promise((r) => setImmediate(r));

    h.dispatchKeydown('Escape');
    t.equals(h.getRoot().children.length, 0, 'Escape closes exactly like the Close button');
    t.isTrue(h.fetchCalls.some((c) => c.url.endsWith('tablet:close')));
});

t.test('Escape is a no-op while the tablet is already closed -- no throw, no spurious tablet:close call', async () => {
    const h = createHarness({ fetchImpl: routeFetch({}) });
    await new Promise((r) => setImmediate(r));
    h.dispatchKeydown('Escape');
    t.equals(h.fetchCalls.filter((c) => c.url.endsWith('tablet:close')).length, 0);
});

t.test('a Lua-initiated tablet:close push hides the page and fully resets state for the next open', async () => {
    let myRecordCalls = 0;
    const h = createHarness({
        fetchImpl: routeFetch({
            'tablet:requestMyRecord': () => {
                myRecordCalls++;
                return { ok: true, viewer: { citizenid: 'A', name: 'A', isHighCommand: false, effectivePermissions: [], allowSelfGrant: false }, certifications: [], xp: null, tierLabel: null, myFeatures: [] };
            },
        }),
    });

    h.postMessage('tablet:open', {});
    await new Promise((r) => setImmediate(r));
    await new Promise((r) => setImmediate(r));
    t.isTrue(h.getRoot().children.length > 0);

    h.postMessage('tablet:close', {});
    t.equals(h.getRoot().children.length, 0, 'Lua-initiated close also hides the page');

    // Reopening fetches fresh data again rather than reusing anything stale.
    h.postMessage('tablet:open', {});
    await new Promise((r) => setImmediate(r));
    await new Promise((r) => setImmediate(r));
    t.equals(myRecordCalls, 2, 'myRecord is re-fetched from scratch on the second open');
});

t.test('an unknown message action is ignored -- no throw, no state change', async () => {
    const h = createHarness({ fetchImpl: routeFetch({}) });
    await new Promise((r) => setImmediate(r));
    h.postMessage('some:futureAction', { anything: true });
    h.postRawMessage(undefined);
    h.postRawMessage({ action: 5 });
    t.equals(h.getRoot().children.length, 0, 'still closed, no throw for any of the three');
});

// ======================================================================
// REGRESSION (focus-and-state audit finding #3) -- closing the tablet
// mid-action, then reopening it, must not leave state.pendingAction stuck
// true forever. The existing double-submit coverage
// (html/tests/tablet_keyboard_operability_spec.js, "DOUBLE-SUBMIT" section)
// only proves a rapid SAME-SESSION second click is refused; it never closes
// and reopens the tablet, so it could not have caught handleClose() setting
// only state.open = false while handleOpen() left state.pendingAction
// untouched from whatever a prior, now-abandoned mutation left it at.
// ======================================================================

t.test('closing the tablet while a mutation is still in flight, then reopening it, un-sticks every action button (state.pendingAction is reset on open)', async () => {
    let triggerCalls = 0;
    const h = createHarness({
        fetchImpl: routeFetch({
            'tablet:requestMyRecord': () => ({
                ok: true,
                viewer: { citizenid: 'A', name: 'A', isHighCommand: false, effectivePermissions: [], allowSelfGrant: false },
                certifications: [], xp: null, tierLabel: null,
                myFeatures: [{ key: 'Recall', label: 'Recall your K9', category: null, actionable: true, state: 'available' }],
            }),
            // Never resolves -- simulates a mutation whose promise outlives
            // the tablet being closed and reopened (a slow/lagged server, or
            // one the operator simply stopped waiting on).
            'tablet:triggerFeature': () => { triggerCalls++; return new Promise(() => {}); },
        }),
    });

    h.postMessage('tablet:open', {});
    await new Promise((r) => setImmediate(r));
    await new Promise((r) => setImmediate(r));

    const findUseButton = () => findByText(h.getRoot(), 'Use')[0];

    const useBtn = findUseButton();
    t.isDefined(useBtn, 'Use button exists on the default Home screen');
    useBtn.click();
    // render() rebuilds every button from scratch synchronously inside the
    // click handler -- `useBtn` itself is now a detached, stale node, so the
    // NEWLY rendered one (carrying `disabled` from the now-true
    // pendingAction) has to be looked up again, same as after any other
    // render() cycle in this suite.
    const disabledUseBtn = findUseButton();
    t.equals(disabledUseBtn.getAttribute('disabled'), 'disabled', 'sanity: pendingAction disabled the button while the (never-resolving) fetch is in flight');
    // fetchStub's own Promise.resolve().then(...) wrapper (tablet-sandbox.js)
    // defers the actual fetchImpl call by one microtask -- await one before
    // checking that it fired.
    await Promise.resolve();
    t.equals(triggerCalls, 1, 'the mutation fetch fired and is now hung, in flight');

    // Close mid-action -- the hung tablet:triggerFeature promise is simply
    // abandoned, exactly like html/tablet.js's own header describes for
    // requestClose(): the local UI hides immediately, never waiting on any
    // in-flight fetch's result.
    h.postMessage('tablet:close', {});
    t.equals(h.getRoot().children.length, 0, 'tablet is closed');

    // Reopen -- a fresh session. Without this pass's fix, state.pendingAction
    // would still be true from the abandoned click above, and every action
    // button (including this same Use button) would render permanently
    // disabled until the original hung promise eventually settled (it never
    // does, in this test, by construction).
    h.postMessage('tablet:open', {});
    await new Promise((r) => setImmediate(r));
    await new Promise((r) => setImmediate(r));

    const reopenedUseBtn = findUseButton();
    t.isDefined(reopenedUseBtn, 'Use button exists again after reopening');
    t.isNull(reopenedUseBtn.getAttribute('disabled'), 'the button is NOT disabled on a fresh open -- pendingAction was reset');

    reopenedUseBtn.click();
    await Promise.resolve();
    t.equals(triggerCalls, 2, 'a fresh click after reopening fires the mutation again -- the control is genuinely usable, not just visually enabled');
});

t.run();
