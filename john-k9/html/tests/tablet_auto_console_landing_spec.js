/*
    html/tests/tablet_auto_console_landing_spec.js

    Covers the "one command, routed by rank" pass (owner, 2026-08-26,
    verbatim: "instead of having /k9tablet and k9hqtablet make it one
    command that makes it based off the rank in the department"):
    tablet:open's `requestedView` now defaults to 'auto' (sent by the
    single command/item/radial entry point -- see client/tablet.lua's own
    NUI CONTRACT), and html/tablet.js's loadMyRecord() must land a
    canAccessConsole()-qualifying caller (high command, OR an explicit
    'k9.audit' grant -- the SAME gate the Console tab/Home card already
    use) straight on the Console screen, and leave everyone else exactly
    where the ordinary command always landed them (the Home screen) --
    silently, no notice, since an ordinary open never asked for the
    console.

    The OLDER, now-optional 'highCommand' explicit shortcut
    (Config.CommandTablet.highCommandCommand) keeps its OWN, different
    behavior for an insufficient caller: a visible refusal notice, proven
    here too so this pass has not silently broken it.

    Landing on the console is asserted TWO ways per scenario, deliberately
    -- not just "the fetch fired" (which could pass on a naive `render()`
    typo that fires the request but never actually switches screens), and
    not just "the tab looks active" (which could pass if fetching were
    accidentally skipped): tablet:requestRoster must actually be called
    (loadRoster() only runs from the console-landing branch or a manual
    tab click, and no test here ever clicks a tab), AND the roster row
    tablet:requestRoster resolves with must actually render.
*/
'use strict';

const t = require('./testkit');
const { createHarness, jsonResponse } = require('./tablet-sandbox');
const { findByText } = require('./tablet-dom-stub');

function routeFetch(handlers, calls) {
    return function (url, init) {
        const name = url.split('/').pop();
        const body = init && init.body ? JSON.parse(init.body) : undefined;
        if (calls) calls.push(name);
        const h = handlers[name];
        if (!h) return Promise.reject(new Error('tablet_auto_console_landing_spec: unhandled NUI callback ' + name));
        return Promise.resolve(jsonResponse(h(body)));
    };
}

const ROSTER_ROW = { citizenid: 'TARGET1', name: 'K9 Rex', departmentLabel: 'Los Santos Police Department', certified: true, xp: 40, tierLabel: 'Trained K9' };

function myRecordHandler(viewerOverrides) {
    return () => ({
        ok: true,
        viewer: Object.assign({ citizenid: 'VIEWER1', name: 'Officer Viewer', isHighCommand: false, effectivePermissions: [], allowSelfGrant: false }, viewerOverrides),
        certifications: [],
        xp: null,
        tierLabel: null,
        myFeatures: [],
    });
}

async function settle(h, times) {
    for (let i = 0; i < (times || 3); i++) await new Promise((r) => setImmediate(r));
}

// ----------------------------------------------------------------------
// requestedView = 'auto' (the single command/item/radial's default)
// ----------------------------------------------------------------------

t.test('auto: a genuinely high-command caller lands on the Console screen automatically, no second command needed', async () => {
    const calls = [];
    const h = createHarness({
        fetchImpl: routeFetch({
            'tablet:requestMyRecord': myRecordHandler({ isHighCommand: true }),
            'tablet:requestRoster': () => ({ ok: true, rows: [ROSTER_ROW], truncated: false }),
        }, calls),
    });
    h.postMessage('tablet:open', { requestedView: 'auto' });
    await settle(h);

    t.isTrue(calls.indexOf('tablet:requestRoster') !== -1, 'landing on the console must actually call tablet:requestRoster, not just look active');
    t.isTrue(findByText(h.getRoot(), 'K9 Rex').length >= 1, 'the roster the console fetched must actually be visible');
});

t.test('auto: a caller holding ONLY the k9.audit grant (not high command) also lands on the Console -- the SAME canAccessConsole() gate the Console tab itself uses', async () => {
    const calls = [];
    const h = createHarness({
        fetchImpl: routeFetch({
            'tablet:requestMyRecord': myRecordHandler({ isHighCommand: false, effectivePermissions: ['k9.audit'] }),
            'tablet:requestRoster': () => ({ ok: true, rows: [ROSTER_ROW], truncated: false }),
        }, calls),
    });
    h.postMessage('tablet:open', { requestedView: 'auto' });
    await settle(h);

    t.isTrue(calls.indexOf('tablet:requestRoster') !== -1, 'a k9.audit holder qualifies for the console exactly like the Console tab already admits them');
    t.isTrue(findByText(h.getRoot(), 'K9 Rex').length >= 1);
});

t.test('auto: an ordinary handler (no high command, no k9.audit) stays on the ordinary landing screen -- silently, no refusal notice', async () => {
    const calls = [];
    const h = createHarness({
        fetchImpl: routeFetch({
            'tablet:requestMyRecord': myRecordHandler({ isHighCommand: false, effectivePermissions: ['k9.access', 'k9.certify'] }),
        }, calls),
    });
    h.postMessage('tablet:open', { requestedView: 'auto' });
    await settle(h);

    t.isTrue(calls.indexOf('tablet:requestRoster') === -1, 'a non-qualifying caller must never trigger the console fetch just because the tablet auto-checks rank');
    t.equals(findByText(h.getRoot(), 'You don\'t have High Command access, so here is your own record instead.').length, 0, 'an ordinary open must never show the explicit-shortcut refusal notice -- it never asked for the console');
});

t.test('auto is also what a bare tablet:open with NO requestedView field at all resolves to (older/partial payloads degrade the same safe way)', async () => {
    const calls = [];
    const h = createHarness({
        fetchImpl: routeFetch({
            'tablet:requestMyRecord': myRecordHandler({ isHighCommand: true }),
            'tablet:requestRoster': () => ({ ok: true, rows: [ROSTER_ROW], truncated: false }),
        }, calls),
    });
    h.postMessage('tablet:open', {});
    await settle(h);

    t.isTrue(calls.indexOf('tablet:requestRoster') !== -1, 'an absent requestedView must still auto-route a qualifying caller, matching client/tablet.lua always sending a real value');
});

// ----------------------------------------------------------------------
// requestedView = 'highCommand' (the OPTIONAL, opt-in shortcut) --
// UNCHANGED behavior: still auto-lands a qualifying caller, but an
// insufficient one sees an explicit, visible refusal instead of silence.
// ----------------------------------------------------------------------

t.test('highCommand (explicit shortcut): a qualifying caller lands on the console exactly like auto does', async () => {
    const calls = [];
    const h = createHarness({
        fetchImpl: routeFetch({
            'tablet:requestMyRecord': myRecordHandler({ isHighCommand: true }),
            'tablet:requestRoster': () => ({ ok: true, rows: [ROSTER_ROW], truncated: false }),
        }, calls),
    });
    h.postMessage('tablet:open', { requestedView: 'highCommand' });
    await settle(h);

    t.isTrue(calls.indexOf('tablet:requestRoster') !== -1);
    t.isTrue(findByText(h.getRoot(), 'K9 Rex').length >= 1);
});

t.test('highCommand (explicit shortcut): an insufficient caller still sees the explicit refusal notice, unchanged from before this pass', async () => {
    const calls = [];
    const h = createHarness({
        fetchImpl: routeFetch({
            'tablet:requestMyRecord': myRecordHandler({ isHighCommand: false, effectivePermissions: [] }),
        }, calls),
    });
    h.postMessage('tablet:open', { requestedView: 'highCommand' });
    await settle(h);

    t.isTrue(calls.indexOf('tablet:requestRoster') === -1, 'refused -- never reaches the console fetch');
    t.isTrue(findByText(h.getRoot(), 'You don\'t have High Command access, so here is your own record instead.').length >= 1, 'an EXPLICIT ask that is refused must still tell the caller why, unlike the silent auto path');
});

// ----------------------------------------------------------------------
// FAIL TOWARD THE ORDINARY SCREEN, NEVER TOWARD THE CONSOLE -- the rank
// answer comes from the server and is not known instantly.
// ----------------------------------------------------------------------

t.test('while tablet:requestMyRecord is still in flight, the caller sits on the ordinary landing screen, never the console, even for a caller who will turn out to be high command', async () => {
    const h = createHarness({
        fetchImpl: routeFetch({ 'tablet:requestMyRecord': () => new Promise(() => {}) }),
    });
    h.postMessage('tablet:open', { requestedView: 'auto' });
    await settle(h);

    t.equals(findByText(h.getRoot(), 'Command Console').length, 0, 'the console tab/screen must not appear before the server has actually answered who this caller is');
});

t.test('a THROWN/failed tablet:requestMyRecord never lands the caller on the console either, regardless of requestedView', async () => {
    const h = createHarness({
        fetchImpl: routeFetch({ 'tablet:requestMyRecord': () => ({ ok: false, error: 'timeout' }) }),
    });
    h.postMessage('tablet:open', { requestedView: 'highCommand' });
    await settle(h);

    t.equals(findByText(h.getRoot(), 'K9 Rex').length, 0, 'no roster ever rendered');
});

t.run();
