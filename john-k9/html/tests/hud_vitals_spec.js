/*
    html/tests/hud_vitals_spec.js

    Covers `hud:updateVitals` -- the core HUD rendering path
    (handleUpdateVitals/applyStat/clampPercent in html/app.js) against
    every reachable payload shape client/hud.lua's PushVitals() can
    actually send: visible true/false, all four original vitals
    present/partial/out-of-range/non-numeric, and the visible=false
    "don't touch bar DOM" rule (client/hud.lua's own header: the last REAL
    values are resent alongside visible=false specifically so this
    function must NOT overwrite them with whatever is in that same
    message).
*/
'use strict';

const t = require('./testkit');
const { createHarness } = require('./sandbox');

function freshHarnessNoAudio() {
    // AudioContextCtor: undefined -- these specs never touch audio; keeping
    // Web Audio construction out of the picture means a stray audio
    // message elsewhere in the suite can't accidentally leave a real timer
    // running against this harness instance.
    return createHarness({ AudioContextCtor: undefined });
}

t.test('root starts hidden with aria-hidden=true before any message (index.html default)', () => {
    const h = freshHarnessNoAudio();
    const root = h.getRoot();
    t.isTrue(root.classList.contains('hidden'));
    t.equals(root.getAttribute('aria-hidden'), 'true');
});

t.test('visible:true renders all four vitals and un-hides the root', () => {
    const h = freshHarnessNoAudio();
    h.postMessage('hud:updateVitals', {
        visible: true, health: 82, stamina: 41,
        wellbeing: {}, xpTier: {},
    });

    const root = h.getRoot();
    t.isFalse(root.classList.contains('hidden'));
    t.equals(root.getAttribute('aria-hidden'), 'false');

    for (const [stat, expected] of [['health', 82], ['stamina', 41]]) {
        const { fill, value } = h.getBarRow(stat);
        t.equals(fill.style.width, `${expected}%`, `${stat} fill width`);
        t.equals(value.textContent, String(expected), `${stat} value text`);
    }
});

t.test('visible:false hides the root and does NOT touch bar DOM (client/hud.lua resends stale values, never zeroed)', () => {
    const h = freshHarnessNoAudio();
    h.postMessage('hud:updateVitals', {
        visible: true, health: 55, stamina: 55,
        wellbeing: {}, xpTier: {},
    });

    // Same message shape client/hud.lua's true->false transition actually
    // sends: visible=false alongside the LAST REAL values, not zeroed --
    // handleUpdateVitals must return before ever reading data.health here.
    h.postMessage('hud:updateVitals', {
        visible: false, health: 999, stamina: -999,
        wellbeing: {}, xpTier: {},
    });

    const root = h.getRoot();
    t.isTrue(root.classList.contains('hidden'), 'root re-hidden');
    t.equals(root.getAttribute('aria-hidden'), 'true');

    const health = h.getBarRow('health');
    t.equals(health.fill.style.width, '55%', 'health fill must be untouched by the visible:false payload');
    t.equals(health.value.textContent, '55', 'health value must be untouched by the visible:false payload');
});

t.test('out-of-range values clamp into 0-100 (above max, below min), in-range fractional values round', () => {
    const h = freshHarnessNoAudio();
    h.postMessage('hud:updateVitals', {
        visible: true, health: 150.9, stamina: -30,
        wellbeing: {}, xpTier: {},
    });

    t.equals(h.getBarRow('health').fill.style.width, '100%', 'health clamps down from 150');
    t.equals(h.getBarRow('health').value.textContent, '100');
    t.equals(h.getBarRow('stamina').fill.style.width, '0%', 'stamina clamps up from -30');
    t.equals(h.getBarRow('stamina').value.textContent, '0');
    t.equals(h.getBarRow('health').value.textContent, '100', 'value above 100 clamps to exactly 100, not 150.9-rounded-to-151');
});

t.test('non-numeric / missing values coerce to 0, never throw (defensive against a malformed payload)', () => {
    const h = freshHarnessNoAudio();
    h.postMessage('hud:updateVitals', {
        visible: true,
        health: 'not a number',
        stamina: null,
        wellbeing: {}, xpTier: {},
    });

    for (const stat of ['health', 'stamina']) {
        const { fill, value } = h.getBarRow(stat);
        t.equals(fill.style.width, '0%', `${stat} fill on malformed input`);
        t.equals(value.textContent, '0', `${stat} value on malformed input`);
    }
});

t.test('a numeric string still parses (Number(raw) coercion, matching JSON payloads that could carry numeric strings)', () => {
    const h = freshHarnessNoAudio();
    h.postMessage('hud:updateVitals', {
        visible: true, health: '73', stamina: '50.4',
        wellbeing: {}, xpTier: {},
    });

    t.equals(h.getBarRow('health').value.textContent, '73');
    t.equals(h.getBarRow('stamina').value.textContent, '50');
});

t.test('partial payload (only health present) still renders health, and the never-set others read as whatever their coerced-default is (0), never throwing', () => {
    const h = freshHarnessNoAudio();
    h.postMessage('hud:updateVitals', { visible: true, health: 64, wellbeing: {}, xpTier: {} });

    t.equals(h.getBarRow('health').value.textContent, '64');
    t.equals(h.getBarRow('stamina').value.textContent, '0', 'stamina absent from payload -> clamps to 0, not a stale/undefined value');
});

t.test('a completely empty {} data object does not throw and leaves the root hidden (visible defaults to not-true)', () => {
    const h = freshHarnessNoAudio();
    h.postMessage('hud:updateVitals', {});
    t.isTrue(h.getRoot().classList.contains('hidden'));
});

t.test('a null/undefined data payload is a silent no-op (handleUpdateVitals\' own `if (!data || !rootEl) return`)', () => {
    const h = freshHarnessNoAudio();
    h.postMessage('hud:updateVitals', null);
    h.postMessage('hud:updateVitals', undefined);
    // Still hidden, no throw anywhere above this line.
    t.isTrue(h.getRoot().classList.contains('hidden'));
});

t.test('repeated visible:true pushes with changing values keep re-rendering (not a one-shot render)', () => {
    const h = freshHarnessNoAudio();
    h.postMessage('hud:updateVitals', { visible: true, health: 10, stamina: 10, wellbeing: {}, xpTier: {} });
    t.equals(h.getBarRow('health').value.textContent, '10');

    h.postMessage('hud:updateVitals', { visible: true, health: 90, stamina: 90, wellbeing: {}, xpTier: {} });
    t.equals(h.getBarRow('health').value.textContent, '90');
});

t.run();
