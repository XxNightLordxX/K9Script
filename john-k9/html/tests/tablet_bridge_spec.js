/*
    html/tests/tablet_bridge_spec.js

    Covers html/tablet-bridge.js in isolation -- the relay that runs inside
    html/index.html's own document (NOT inside the tablet's iframe) and
    forwards `tablet:*` SendNUIMessage pushes down into that iframe's own
    `message` listener, since delivery otherwise only ever reaches the
    top-level window (see that file's own header). Also covers its
    independent top-level Escape listener -- the second, belt-and-suspenders
    close path alongside html/tablet.js's own Escape handling inside the
    iframe (see tablet_open_close_spec.js for that half).

    Deliberately a small, self-contained harness rather than reusing
    tablet-sandbox.js -- this file runs a DIFFERENT script
    (tablet-bridge.js, not tablet.js) against a DIFFERENT document shape
    (a `#k9tablet-wrap`/`#k9tablet-frame` pair, not `#k9tablet-root`), so
    sharing a harness would just mean overloading one module with two
    unrelated DOM shapes.
*/
'use strict';

const fs = require('fs');
const path = require('path');
const vm = require('vm');
const t = require('./testkit');
const { FakeDocument } = require('./tablet-dom-stub');

const BRIDGE_JS_PATH = path.join(__dirname, '..', 'tablet-bridge.js');
const bridgeSource = fs.readFileSync(BRIDGE_JS_PATH, 'utf8');
const bridgeScript = new vm.Script(bridgeSource, { filename: 'tablet-bridge.js' });

function createHarness(options) {
    options = options || {};

    const doc = new FakeDocument();
    const wrap = doc.createElement('div', { id: 'k9tablet-wrap', class: 'k9tablet-wrap hidden' });
    const frame = doc.createElement('iframe', { id: 'k9tablet-frame' });
    const postMessageCalls = [];
    frame.contentWindow = { postMessage: (msg, origin) => postMessageCalls.push({ msg, origin }) };

    const fetchCalls = [];
    const sandbox = {
        document: doc,
        console,
        setTimeout,
        clearTimeout,
        fetch: (url, init) => {
            fetchCalls.push({ url, init });
            return Promise.resolve({ ok: true, json: () => Promise.resolve({}) });
        },
    };
    sandbox.GetParentResourceName = Object.prototype.hasOwnProperty.call(options, 'getParentResourceName')
        ? options.getParentResourceName
        : () => 'john-k9';
    sandbox.window = sandbox;
    sandbox.__listeners = {};
    sandbox.addEventListener = function (type, fn) {
        (sandbox.__listeners[type] = sandbox.__listeners[type] || []).push(fn);
    };

    vm.createContext(sandbox);
    bridgeScript.runInContext(sandbox);

    function postMessage(action, data) {
        const listeners = sandbox.__listeners['message'] || [];
        for (const fn of listeners.slice()) fn({ data: { action, data } });
    }

    function postRawMessage(rawData) {
        const listeners = sandbox.__listeners['message'] || [];
        for (const fn of listeners.slice()) fn({ data: rawData });
    }

    function dispatchKeydown(key) {
        doc._dispatch('keydown', { key });
    }

    return { doc, wrap, frame, postMessageCalls, fetchCalls, postMessage, postRawMessage, dispatchKeydown };
}

t.test('tablet:open unhides the wrapper and relays the exact message into the iframe\'s contentWindow', () => {
    const h = createHarness();
    t.isTrue(h.wrap.classList.contains('hidden'), 'starts hidden');

    h.postMessage('tablet:open', { capabilities: {}, strings: {}, maxXpPerGrant: 500 });

    t.isFalse(h.wrap.classList.contains('hidden'), 'wrapper unhidden');
    t.equals(h.wrap.getAttribute('aria-hidden'), 'false');
    t.equals(h.postMessageCalls.length, 1);
    t.equals(h.postMessageCalls[0].msg.action, 'tablet:open');
    t.equals(h.postMessageCalls[0].msg.data.maxXpPerGrant, 500);
});

t.test('tablet:close re-hides the wrapper and relays into the iframe', () => {
    const h = createHarness();
    h.postMessage('tablet:open', {});
    t.isFalse(h.wrap.classList.contains('hidden'));

    h.postMessage('tablet:close', {});
    t.isTrue(h.wrap.classList.contains('hidden'), 'wrapper re-hidden');
    t.equals(h.wrap.getAttribute('aria-hidden'), 'true');
    t.equals(h.postMessageCalls[h.postMessageCalls.length - 1].msg.action, 'tablet:close');
});

t.test('hud:*/audio:* actions (the existing HUD\'s own messages) are completely ignored -- not relayed, wrapper untouched', () => {
    const h = createHarness();
    h.postMessage('hud:updateVitals', { visible: true, health: 50, stamina: 50, hunger: 50, thirst: 50 });
    h.postMessage('audio:play', { id: 1, sound: 'bark', gain: 1, loop: false });

    t.equals(h.postMessageCalls.length, 0, 'nothing relayed into the tablet iframe for non-tablet: actions');
    t.isTrue(h.wrap.classList.contains('hidden'), 'wrapper untouched -- still hidden');
});

t.test('a malformed message (no action, non-string action, null data) does not throw and is ignored', () => {
    const h = createHarness();
    h.postRawMessage(undefined);
    h.postRawMessage(null);
    h.postRawMessage({ action: 5 });
    h.postRawMessage({ action: {} });
    t.equals(h.postMessageCalls.length, 0);
    t.isTrue(true, 'no throw for any of the four');
});

t.test('a future tablet:* action this file does not special-case is still relayed verbatim (forward-compatible, no per-action allowlist)', () => {
    const h = createHarness();
    h.postMessage('tablet:someFutureAction', { anything: 'goes here' });
    t.equals(h.postMessageCalls.length, 1);
    t.equals(h.postMessageCalls[0].msg.action, 'tablet:someFutureAction');
});

t.test('pressing Escape while the wrapper is visible hides it, fires a tablet:close fetch, and relays a synthetic close into the iframe', async () => {
    const h = createHarness();
    h.postMessage('tablet:open', {});
    h.postMessageCalls.length = 0; // clear the tablet:open relay so we only observe what Escape itself does

    h.dispatchKeydown('Escape');
    await new Promise((r) => setImmediate(r));

    t.isTrue(h.wrap.classList.contains('hidden'), 'Escape hides the wrapper immediately');
    t.isTrue(h.fetchCalls.some((c) => c.url === 'https://john-k9/tablet:close'), 'Escape independently notifies Lua via tablet:close');
    t.isTrue(h.postMessageCalls.some((c) => c.msg.action === 'tablet:close'), 'Escape also relays a close down into the iframe\'s own document');
});

t.test('Escape is a no-op while the wrapper is already hidden -- no fetch, no relay', async () => {
    const h = createHarness();
    h.dispatchKeydown('Escape');
    await new Promise((r) => setImmediate(r));
    t.equals(h.fetchCalls.length, 0);
    t.equals(h.postMessageCalls.length, 0);
});

t.test('a non-Escape keydown while the wrapper is visible does nothing', () => {
    const h = createHarness();
    h.postMessage('tablet:open', {});
    h.postMessageCalls.length = 0;
    h.fetchCalls.length = 0;

    h.dispatchKeydown('a');
    t.isFalse(h.wrap.classList.contains('hidden'));
    t.equals(h.fetchCalls.length, 0);
    t.equals(h.postMessageCalls.length, 0);
});

t.run();
