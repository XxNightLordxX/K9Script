/*
    html/tests/message_routing_spec.js

    Covers the top-level `message` event dispatcher in html/app.js's
    init() -- the switch(msg.action) block routing to the four known
    actions, and its explicit "ignore, don't throw" default branch for
    anything else (a THIRD, not-yet-built NUI surface's messages, per its
    own comment) plus defensive handling of a malformed/foreign `message`
    event body entirely (window can receive `message` events from sources
    this page never intended to listen to, in a real browser -- postMessage
    is a shared-namespace API).
*/
'use strict';

const t = require('./testkit');
const { createHarness } = require('./sandbox');

t.test('an unknown action is silently ignored -- no throw, no DOM change', () => {
    const h = createHarness({ AudioContextCtor: undefined });
    h.postMessage('hud:updateVitals', { visible: true, health: 44, stamina: 44, hunger: 44, thirst: 44, wellbeing: {}, xpTier: {} });

    h.postMessage('some:futureSurfaceAction', { anything: 'goes here' });

    t.equals(h.getBarRow('health').value.textContent, '44', 'unrelated action must not disturb existing HUD state');
});

t.test('a message with no `data` property at all (event.data undefined) is ignored, not thrown', () => {
    const h = createHarness({ AudioContextCtor: undefined });
    h.postRawMessage(undefined);
    h.postRawMessage(null);
    t.isTrue(true, 'no throw for either');
});

t.test('a message whose action is not a string (number, object, missing) is ignored', () => {
    const h = createHarness({ AudioContextCtor: undefined });
    h.postRawMessage({ action: 5, data: {} });
    h.postRawMessage({ action: {}, data: {} });
    h.postRawMessage({ data: {} }); // action entirely missing
    t.isTrue(true, 'no throw for any of the three');
});

t.test('a message whose `data` is a string/number/array instead of an object does not throw for hud:updateVitals (handleUpdateVitals\' own `if (!data) return` plus property access on primitives)', () => {
    const h = createHarness({ AudioContextCtor: undefined });
    h.postMessage('hud:updateVitals', 'not an object');
    h.postMessage('hud:updateVitals', 12345);
    h.postMessage('hud:updateVitals', []);
    t.isTrue(true, 'no throw for any of the three malformed data shapes');
});

t.test('a message whose `data` is a string/number instead of an object does not throw for audio:play/setGain/stop', () => {
    const h = createHarness({ AudioContextCtor: undefined });
    h.postMessage('audio:play', 'not an object');
    h.postMessage('audio:setGain', 12345);
    h.postMessage('audio:stop', true);
    t.isTrue(true, 'no throw for any of these');
});

t.test('all four known actions are routed to distinct, correct handlers (a smoke-level cross-check that the switch/case names match this task\'s own contract exactly)', async () => {
    const h = createHarness();

    h.postMessage('hud:updateVitals', { visible: true, health: 20, stamina: 20, hunger: 20, thirst: 20, wellbeing: {}, xpTier: {} });
    t.equals(h.getBarRow('health').value.textContent, '20', 'hud:updateVitals routed to handleUpdateVitals');

    h.postMessage('audio:play', { id: 1, sound: 'bark', gain: 1, loop: false });
    await new Promise((r) => setTimeout(r, 100));
    t.isDefined(h.getAudioContextInstance(), 'audio:play routed to handleAudioPlay (constructed an AudioContext)');

    h.postMessage('audio:setGain', { id: 1, gain: 0.1 });
    h.postMessage('audio:stop', { id: 1 });
    await new Promise((r) => setImmediate(r));
    t.isTrue(true, 'audio:setGain/audio:stop routed without throwing');
});

t.run();
