/*
    html/tests/hud_ready_spec.js

    Covers sendReadyAck()/init()'s handshake -- the `hud:ready`
    RegisterNUICallback fetch() call html/app.js fires once, immediately
    after attaching its `message` listener (app.js's own comment: listener
    FIRST, ack SECOND -- reversing this order reintroduces the exact race
    the handshake exists to close, so this is asserted directly here too,
    not just the ack's own shape).
*/
'use strict';

const t = require('./testkit');
const { createHarness } = require('./sandbox');

t.test('fires exactly one hud:ready POST at startup, to the GetParentResourceName()-scoped URL, with an empty JSON body', async () => {
    let resolvedFetch;
    const fetchPromise = new Promise((resolve) => { resolvedFetch = resolve; });

    const h = createHarness({
        AudioContextCtor: undefined,
        fetchImpl: (url, init) => {
            resolvedFetch({ url, init });
            return Promise.resolve({ ok: true, status: 200, json: () => Promise.resolve({}) });
        },
    });

    const call = await fetchPromise;
    t.equals(call.url, 'https://john-k9/hud:ready');
    t.equals(call.init.method, 'POST');
    t.equals(call.init.headers['Content-Type'], 'application/json; charset=UTF-8');
    t.equals(call.init.body, '{}');

    // Only ever the one ack for this page's whole lifetime, not re-fired by
    // any subsequent hud:updateVitals/audio:* traffic.
    h.postMessage('hud:updateVitals', { visible: true, health: 1, stamina: 1, hunger: 1, thirst: 1, wellbeing: {}, xpTier: {} });
    await new Promise((r) => setImmediate(r));
    t.equals(h.fetchCalls.length, 1, 'exactly one fetch call total (the one hud:ready ack)');
});

t.test('the message listener is attached BEFORE the ready ack fires (init()\'s own documented ordering)', async () => {
    // If this were reversed, a hud:updateVitals message arriving in the
    // same synchronous tick as the ack (as a real Lua handler's immediate
    // PushVitals() call inside RegisterNUICallback('hud:ready', ...) does)
    // would already have a listener ready to receive it -- this test
    // proves that by dispatching a message from INSIDE the fetch stub
    // itself, synchronously, the instant the ack fires.
    let messageWasHandled = false;
    const h = createHarness({
        AudioContextCtor: undefined,
        fetchImpl: (url) => {
            h.postMessage('hud:updateVitals', { visible: true, health: 7, stamina: 7, hunger: 7, thirst: 7, wellbeing: {}, xpTier: {} });
            messageWasHandled = true;
            return Promise.resolve({ ok: true, status: 200 });
        },
    });

    await new Promise((r) => setImmediate(r));
    t.isTrue(messageWasHandled);
    t.equals(h.getBarRow('health').value.textContent, '7', 'a message dispatched synchronously inside the ack fetch is still handled -- listener was already attached');
});

t.test('a rejected hud:ready fetch (e.g. client/hud.lua not yet registered) is swallowed -- no unhandled rejection, no throw', async () => {
    const unhandled = [];
    const onUnhandled = (reason) => unhandled.push(reason);
    process.on('unhandledRejection', onUnhandled);

    try {
        createHarness({
            AudioContextCtor: undefined,
            fetchImpl: () => Promise.reject(new Error('simulated: no RegisterNUICallback listening yet')),
        });

        // Let the rejection's own .catch() (inside sendReadyAck) and any
        // errant unhandledRejection both have a chance to fire.
        await new Promise((r) => setImmediate(r));
        await new Promise((r) => setImmediate(r));

        t.equals(unhandled.length, 0, 'app.js\'s own .catch() on the ack fetch must swallow this, not leak an unhandled rejection');
    } finally {
        process.removeListener('unhandledRejection', onUnhandled);
    }
});

t.test('GetParentResourceName() not existing at all (plain-browser dev-preview, per app.js\'s own comment) does not throw and sends no fetch', async () => {
    const h = createHarness({
        AudioContextCtor: undefined,
        getParentResourceName: undefined, // omitted from the sandbox entirely -- see sandbox.js's own handling of this option
    });

    await new Promise((r) => setImmediate(r));
    t.equals(h.fetchCalls.length, 0, 'sendReadyAck()\'s own try/catch must swallow the ReferenceError before ever calling fetch()');

    // The rest of the page must still work normally -- this is a
    // dev-preview convenience path, not a broken page.
    h.postMessage('hud:updateVitals', { visible: true, health: 33, stamina: 33, hunger: 33, thirst: 33, wellbeing: {}, xpTier: {} });
    t.equals(h.getBarRow('health').value.textContent, '33');
});

t.test('init() also runs correctly when document.readyState starts \'loading\' (DOMContentLoaded-deferred path)', async () => {
    const h = createHarness({ AudioContextCtor: undefined, deferReady: true });

    // Before DOMContentLoaded fires, init() has not run -- no ready ack yet.
    await new Promise((r) => setImmediate(r));
    t.equals(h.fetchCalls.length, 0, 'no ack before DOMContentLoaded fires');

    h.fireDomContentLoaded();
    await new Promise((r) => setImmediate(r));
    t.equals(h.fetchCalls.length, 1, 'ack fires once DOMContentLoaded fires');
    t.equals(h.fetchCalls[0].url, 'https://john-k9/hud:ready');
});

t.run();
