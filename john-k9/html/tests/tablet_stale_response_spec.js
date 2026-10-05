/*
    html/tests/tablet_stale_response_spec.js

    Regression coverage for a silent-failure race in html/tablet.js's own
    data loaders: fetchNui() responses are NOT guaranteed to resolve in the
    order their requests were sent (network jitter, server-side load, or --
    for the roster search -- simply a slow response for an OLDER query
    outracing a fast one for a NEWER query the user has since typed). None
    of loadPersonSummary()/loadPersonFeatures()/loadRoster() cancel an
    in-flight request when the viewer navigates on; before this pass, an
    out-of-order response for a target/query no longer on screen was
    applied UNCONDITIONALLY, silently overwriting the CURRENTLY-displayed
    person's name/certifications/XP/permissions (or the current search
    results) with data for someone/something else entirely -- no thrown
    error, no console output, just the wrong record on screen. This is
    exactly the "if (!x) return -- but is it defending against something
    that actually happens?" class of bug this codebase's review passes look
    for, in the opposite direction: here the missing guard was the bug.

    Fixed by comparing the request's own captured target/query against the
    CURRENT state.person.citizenid / state.rosterQuery at the moment each
    response arrives, discarding (not just ignoring the loading flag, but
    the entire result) anything that no longer matches. Both tests below
    hold one request open indefinitely (never resolved by the mock fetch)
    while a second, different request is issued and resolved immediately --
    deliberately never asserting WHICH of "genuinely stale success" or
    "fetchNui's own compressed timeout beat it there first" occurred (both
    are real possible outcomes under this harness's time-compression, see
    tablet-sandbox.js's own header), only the user-facing invariant that
    must hold either way: the screen the viewer actually navigated to is
    never clobbered by a response for the one they left.
*/
'use strict';

const t = require('./testkit');
const { createHarness, jsonResponse } = require('./tablet-sandbox');
const { findByText, findByTag } = require('./tablet-dom-stub');

async function settle(times) {
    for (let i = 0; i < (times || 2); i++) await new Promise((r) => setImmediate(r));
}

const HIGH_COMMAND_MY_RECORD = () => ({
    ok: true,
    viewer: { citizenid: 'VIEWER1', name: 'Chief Viewer', isHighCommand: true, effectivePermissions: ['k9.access', 'k9.certify', 'k9.audit', 'k9.givexp'], allowSelfGrant: false },
    certifications: [],
    xp: null,
    tierLabel: null,
    myFeatures: [],
});

t.test('a late tablet:requestPersonSummary response for a person the viewer already navigated away from never overwrites the CURRENTLY-open person\'s name/record', async () => {
    let resolveStaleA = null;

    const h = createHarness({
        fetchImpl: (url, init) => {
            const name = url.split('/').pop();
            const body = init && init.body ? JSON.parse(init.body) : undefined;

            if (name === 'tablet:requestMyRecord') return Promise.resolve(jsonResponse(HIGH_COMMAND_MY_RECORD()));
            if (name === 'tablet:requestRoster') {
                return Promise.resolve(jsonResponse({
                    ok: true,
                    rows: [
                        { citizenid: 'A', name: 'K9 Ana', departmentLabel: 'Police', certified: true, xp: 0, tierLabel: 'Recruit K9' },
                        { citizenid: 'B', name: 'K9 Bruno', departmentLabel: 'Police', certified: true, xp: 0, tierLabel: 'Recruit K9' },
                    ],
                    truncated: false,
                }));
            }
            if (name === 'tablet:requestPersonFeatures') {
                return Promise.resolve(jsonResponse({ ok: true, target: { citizenid: body.targetCitizenId, name: body.targetCitizenId }, features: [] }));
            }
            if (name === 'tablet:requestPersonSummary' && body.targetCitizenId === 'A') {
                // Held open deliberately -- see this file's header. Resolved
                // manually, LATE, well after the viewer has moved on to B.
                return new Promise((resolve) => {
                    resolveStaleA = () => resolve(jsonResponse({
                        ok: true,
                        target: { citizenid: 'A', name: 'K9 Ana' },
                        certifications: [{ departmentKey: 'police', departmentLabel: 'Police', active: true, grantedBy: null }],
                        xp: 999,
                        tierLabel: 'STALE TIER FOR A',
                        permissions: ['k9.access'],
                    }));
                });
            }
            if (name === 'tablet:requestPersonSummary' && body.targetCitizenId === 'B') {
                return Promise.resolve(jsonResponse({
                    ok: true,
                    target: { citizenid: 'B', name: 'K9 Bruno' },
                    certifications: [{ departmentKey: 'police', departmentLabel: 'Police', active: false, grantedBy: null }],
                    xp: 5,
                    tierLabel: 'Recruit K9',
                    permissions: [],
                }));
            }
            return Promise.reject(new Error('tablet_stale_response_spec: unhandled NUI callback ' + name));
        },
    });

    h.postMessage('tablet:open', {});
    await settle();
    findByText(h.getRoot(), 'Command Console')[0].click();
    await settle();

    // Open A -- fires the request that will be held open.
    findByText(h.getRoot(), 'Manage')[0].click();
    await settle();
    t.isDefined(resolveStaleA, 'A\'s tablet:requestPersonSummary request was sent (and is being held unresolved)');

    // Navigate away from A entirely, to B, WITHOUT A's request ever
    // resolving.
    findByText(h.getRoot(), '← Back to roster')[0].click();
    await settle();
    findByText(h.getRoot(), 'Manage')[1].click();
    await settle();

    t.isTrue(findByText(h.getRoot(), 'K9 Bruno').length >= 1, 'B is now the person on screen');
    t.equals(findByText(h.getRoot(), 'K9 Ana').length, 0, 'A is no longer shown once navigated away from');

    // Only now let A's stale response land.
    resolveStaleA();
    await settle();

    t.isTrue(findByText(h.getRoot(), 'K9 Bruno').length >= 1, 'B\'s record is still on screen after A\'s late response arrives');
    t.equals(findByText(h.getRoot(), 'K9 Ana').length, 0, 'A\'s late response never renders its name over B\'s screen');
    t.equals(findByText(h.getRoot(), 'STALE TIER FOR A').length, 0, 'A\'s stale XP/tier data never leaks into B\'s screen');
});

t.test('a late tablet:requestRoster response for a query the viewer has since changed never replaces the CURRENT search results', async () => {
    let resolveStaleQuery = null;

    const h = createHarness({
        fetchImpl: (url, init) => {
            const name = url.split('/').pop();
            const body = init && init.body ? JSON.parse(init.body) : undefined;

            if (name === 'tablet:requestMyRecord') return Promise.resolve(jsonResponse(HIGH_COMMAND_MY_RECORD()));
            if (name === 'tablet:requestRoster' && body.query === '') {
                // The console screen's own initial load, on tab-open.
                return Promise.resolve(jsonResponse({ ok: true, rows: [], truncated: false }));
            }
            if (name === 'tablet:requestRoster' && body.query === 'ana') {
                // Held open deliberately -- resolved manually, LATE, after
                // the search box has already moved on to a different query.
                return new Promise((resolve) => {
                    resolveStaleQuery = () => resolve(jsonResponse({
                        ok: true,
                        rows: [{ citizenid: 'A', name: 'STALE ANA RESULT', departmentLabel: 'Police', certified: true, xp: 0, tierLabel: 'Recruit K9' }],
                        truncated: false,
                    }));
                });
            }
            if (name === 'tablet:requestRoster' && body.query === 'bruno') {
                return Promise.resolve(jsonResponse({
                    ok: true,
                    rows: [{ citizenid: 'B', name: 'K9 Bruno', departmentLabel: 'Police', certified: true, xp: 0, tierLabel: 'Recruit K9' }],
                    truncated: false,
                }));
            }
            return Promise.reject(new Error('tablet_stale_response_spec: unhandled NUI callback ' + name + ' query=' + (body && body.query)));
        },
    });

    h.postMessage('tablet:open', {});
    await settle();
    findByText(h.getRoot(), 'Command Console')[0].click();
    await settle(); // initial empty-query load

    const search = findByTag(h.getRoot(), 'input').filter((i) => i.getAttribute('placeholder') === 'Name, citizen ID or server ID...')[0];
    t.isDefined(search, 'search input exists');

    // Directly setting rosterQuery + calling the debounced loader's own
    // eventual fetch would require waiting out SEARCH_DEBOUNCE_MS -- instead
    // drive the same path this file's own debounce settles into by typing
    // one query, letting its own debounce fire, THEN typing a second query
    // before the FIRST query's response has arrived.
    search.typeValue('ana');
    await new Promise((r) => setTimeout(r, 20)); // let the (compressed) debounce fire the 'ana' request
    t.isDefined(resolveStaleQuery, '\'ana\' request was sent and is being held unresolved');

    search.typeValue('bruno');
    await new Promise((r) => setTimeout(r, 20)); // let the (compressed) debounce fire the 'bruno' request, which resolves immediately
    await settle();

    t.isTrue(findByText(h.getRoot(), 'K9 Bruno').length >= 1, '\'bruno\' results are showing');
    t.equals(findByText(h.getRoot(), 'STALE ANA RESULT').length, 0, '\'ana\' has not (yet) leaked in -- its request is still held open');

    // Only now let the stale 'ana' response land.
    resolveStaleQuery();
    await settle();

    t.isTrue(findByText(h.getRoot(), 'K9 Bruno').length >= 1, '\'bruno\' results are still showing after the late \'ana\' response arrives');
    t.equals(findByText(h.getRoot(), 'STALE ANA RESULT').length, 0, 'the late \'ana\' response never replaces the current \'bruno\' results');
});

t.test('a late tablet:k9ProfileGet response for a K9 profile the operator has since navigated away from never overwrites the CURRENTLY-open profile', async () => {
    let resolveStaleA = null;

    const h = createHarness({
        fetchImpl: (url, init) => {
            const name = url.split('/').pop();
            const body = init && init.body ? JSON.parse(init.body) : undefined;

            if (name === 'tablet:requestMyRecord') return Promise.resolve(jsonResponse(HIGH_COMMAND_MY_RECORD()));
            if (name === 'tablet:requestRoster') return Promise.resolve(jsonResponse({ ok: true, rows: [], truncated: false }));
            if (name === 'tablet:requestOnlinePlayers') return Promise.resolve(jsonResponse({ ok: true, rows: [], truncated: false }));
            if (name === 'tablet:k9ProfilesList') return Promise.resolve(jsonResponse({ ok: true, overrides: [] }));
            // The override editor now lives on the PERSON screen (plan item
            // D), reached through the Console's one open-by-id box instead
            // of the deleted K9 Overrides tab's own duplicate lookup. These
            // are the extra loads opening a person fires; none of them is
            // what this test is about, so they answer plainly and get out
            // of the way.
            if (name === 'tablet:requestPersonSummary') return Promise.resolve(jsonResponse({ ok: true, target: { citizenid: body.targetCitizenId, name: body.targetCitizenId }, certifications: [], xp: 0, tierLabel: null, permissions: [], partnership: null }));
            if (name === 'tablet:requestPersonFeatures') return Promise.resolve(jsonResponse({ ok: true, target: { citizenid: body.targetCitizenId, name: body.targetCitizenId }, features: [] }));
            if (name === 'tablet:permKeysList') return Promise.resolve(jsonResponse({ ok: true, keys: [] }));
            if (name === 'tablet:certTiersList') return Promise.resolve(jsonResponse({ ok: true, tiers: [] }));
            if (name === 'tablet:rosterList') return Promise.resolve(jsonResponse({ ok: true, k9: [], handlers: [], unassigned: [] }));
            if (name === 'tablet:requestPartnershipsForTarget') return Promise.resolve(jsonResponse({ ok: false, error: 'not_stubbed' }));
            if (name === 'tablet:k9ProfileGet' && body.citizenid === 'CITIZEN_A') {
                // Held open deliberately -- see this file's header. Resolved
                // manually, LATE, well after the operator has moved on to
                // CITIZEN_B via the SAME lookup box.
                return new Promise((resolve) => {
                    resolveStaleA = () => resolve(jsonResponse({
                        ok: true,
                        citizenid: 'CITIZEN_A',
                        tierLabel: 'STALE TIER FOR A',
                        effective: { speedMultiplier: 1.5, scentRangeMultiplier: 1.5, medkitCooldownMultiplier: 0.5, overridden: { speedMultiplier: true, scentRangeMultiplier: true, medkitCooldownMultiplier: true } },
                        override: { speedMultiplier: 1.5, scentRangeMultiplier: 1.5, medkitCooldownMultiplier: 0.5, note: 'STALE NOTE FOR A' },
                    }));
                });
            }
            if (name === 'tablet:k9ProfileGet' && body.citizenid === 'CITIZEN_B') {
                return Promise.resolve(jsonResponse({
                    ok: true,
                    citizenid: 'CITIZEN_B',
                    tierLabel: 'TIER FOR B',
                    effective: { speedMultiplier: 1.0, scentRangeMultiplier: 1.0, medkitCooldownMultiplier: 1.0, overridden: {} },
                    override: null,
                }));
            }
            return Promise.reject(new Error('tablet_stale_response_spec: unhandled NUI callback ' + name));
        },
    });

    h.postMessage('tablet:open', {});
    await settle();
    findByText(h.getRoot(), 'Command Console')[0].click();
    await settle(4);

    /** The Console's open-by-id box -- the one person-finder this tablet
     * keeps, and the route to the override editor since the K9 Overrides
     * tab and its duplicate lookup were removed (plan item D). The
     * stale-response hazard this test exists for is unchanged: the editor
     * still reads the SAME shared state.k9ProfileSelected*, so a late
     * response for a person the operator has navigated away from must
     * still never render over the one now open. */
    function lookupInput() {
        return findByTag(h.getRoot(), 'input').filter((i) => i.getAttribute('placeholder') === 'Name, citizen ID or server ID...')[0];
    }

    // Open A -- fires the request that will be held open.
    lookupInput().typeValue('CITIZEN_A');
    findByText(h.getRoot(), 'Open')[0].click();
    await settle(6);
    t.isDefined(resolveStaleA, 'CITIZEN_A\'s tablet:k9ProfileGet request was sent (and is being held unresolved)');

    // Navigate to a DIFFERENT citizenid via the SAME lookup box, WITHOUT
    // A's request ever resolving.
    findByText(h.getRoot(), 'Command Console')[0].click();
    await settle(4);
    lookupInput().typeValue('CITIZEN_B');
    findByText(h.getRoot(), 'Open')[0].click();
    await settle(6);

    t.isTrue(findByText(h.getRoot(), 'CITIZEN_B').length >= 1, 'CITIZEN_B is now the profile on screen');
    t.equals(findByText(h.getRoot(), 'CITIZEN_A').length, 0, 'CITIZEN_A is no longer shown once navigated away from');

    // Only now let A's stale response land.
    resolveStaleA();
    await settle();

    t.isTrue(findByText(h.getRoot(), 'CITIZEN_B').length >= 1, 'CITIZEN_B\'s profile is still on screen after A\'s late response arrives');
    t.equals(findByText(h.getRoot(), 'CITIZEN_A').length, 0, 'A\'s late response never renders its citizenid over B\'s screen');
    t.equals(findByText(h.getRoot(), 'STALE TIER FOR A').length, 0, 'A\'s stale tier/override data never leaks into B\'s screen');
    t.equals(findByText(h.getRoot(), 'STALE NOTE FOR A').length, 0, 'A\'s stale note never leaks into B\'s screen');
});

t.run();
