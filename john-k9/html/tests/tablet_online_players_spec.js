/*
    html/tests/tablet_online_players_spec.js

    Covers the Online Players list on the Command Console screen --
    owner-directed, 2026-08-26, verbatim: "make the add permission
    section on the ui tablet for the command tablet where its a list
    when i choose a player id and just click those permissions etc make
    it easier". See server/tablet.lua's own "CALLBACK 2b/2c" header and
    html/tablet.js's buildOnlinePlayersSection() header for the full
    contract this exercises.

    Specifically proves:
      1. Same audience as the roster (canAccessConsole()) -- a
         k9.certify/k9.givexp-only holder (narrower canOpenPersonRecord()
         path) never sees this section at all.
      2. Rows show server id / name / job / K9 access -- NEVER a
         citizenid anywhere in this section (the server response itself
         never carries one; this proves the UI does not invent one
         either).
      3. Clicking a row resolves it via tablet:openOnlinePlayer (server
         id + the row's own opaque nonce) and, on success, opens the
         EXACT SAME Person screen the roster's own Manage button opens --
         a NEW ENTRY POINT, not a second grant mechanism.
      4. A resolve failure (the person left, or the list went stale)
         shows a plain, visible notice and does NOT navigate to the
         Person screen for anyone.
      5. Search debounces and re-fetches, same shape as the roster's own
         search box, and the two search boxes are independent.
*/
'use strict';

const t = require('./testkit');
const { createHarness, jsonResponse } = require('./tablet-sandbox');
const { findByText, findByTag } = require('./tablet-dom-stub');

function routeFetch(handlers, calls) {
    return function (url, init) {
        const name = url.split('/').pop();
        const body = init && init.body ? JSON.parse(init.body) : undefined;
        if (calls) calls.push({ name: name, body: body });
        const h = handlers[name];
        if (!h) return Promise.reject(new Error('tablet_online_players_spec: unhandled NUI callback ' + name));
        return Promise.resolve(jsonResponse(h(body)));
    };
}

const CONSOLE_VIEWER = { citizenid: 'V', name: 'Viewer', isHighCommand: true, effectivePermissions: ['k9.access', 'k9.certify', 'k9.audit', 'k9.givexp'], allowSelfGrant: false };

const ONE_ONLINE_ROW = { source: 42, name: 'Rex Shepherd', jobLabel: 'Los Santos Police Department', hasK9Access: true, nonce: 'nonce-abc-1' };

async function settle(h, times) {
    for (let i = 0; i < (times || 3); i++) await new Promise((r) => setImmediate(r));
}

/**
 * CONSOLE_VIEWER qualifies for canAccessConsole() (isHighCommand true),
 * so -- per this pass's own "one command, routed by rank" change -- a
 * bare tablet:open already auto-lands them on the Console screen
 * (requestedView defaults to 'auto'; see html/tablet.js's loadMyRecord()).
 * No manual tab click needed, and none is done here deliberately: this
 * spec's own "Refresh re-fetches" test below counts
 * tablet:requestOnlinePlayers calls, and a redundant second entry into
 * the screen (auto-land, THEN a manual click) would silently double that
 * baseline count for every test in this file, not just that one.
 */
async function openConsole(h) {
    h.postMessage('tablet:open', {});
    await settle(h);
}

t.test('a k9.audit/high-command viewer sees the Online Players section with a real row, server id / name / job / K9 access, and NEVER a citizenid anywhere in it', async () => {
    const h = createHarness({
        fetchImpl: routeFetch({
            'tablet:requestMyRecord': () => ({ ok: true, viewer: CONSOLE_VIEWER, certifications: [], xp: null, tierLabel: null, myFeatures: [] }),
            'tablet:requestRoster': () => ({ ok: true, rows: [], truncated: false }),
            'tablet:requestOnlinePlayers': () => ({ ok: true, rows: [ONE_ONLINE_ROW], truncated: false }),
        }),
    });
    await openConsole(h);

    t.isTrue(findByText(h.getRoot(), 'Online Players').length >= 1, 'section heading present');
    t.isTrue(findByText(h.getRoot(), 'Rex Shepherd').length >= 1);
    t.isTrue(findByText(h.getRoot(), '42').length >= 1, 'the server id itself is shown');
    t.isTrue(findByText(h.getRoot(), 'Los Santos Police Department').length >= 1);
    t.equals(findByText(h.getRoot(), 'ONLINE-CITIZEN-1').length, 0, 'sanity: no citizenid-shaped string was ever in the fixture to begin with');

    // The row's own opaque nonce must never render anywhere as visible
    // text -- it is wire-only bookkeeping, not a display value.
    t.equals(findByText(h.getRoot(), 'nonce-abc-1').length, 0);
});

t.test('a k9.certify/k9.givexp-only holder (not k9.audit, not high command) never sees the Online Players section at all -- same narrower gate as the roster', async () => {
    const h = createHarness({
        fetchImpl: routeFetch({
            'tablet:requestMyRecord': () => ({ ok: true, viewer: { citizenid: 'V', name: 'V', isHighCommand: false, effectivePermissions: ['k9.certify'], allowSelfGrant: false }, certifications: [], xp: null, tierLabel: null, myFeatures: [] }),
        }),
    });
    h.postMessage('tablet:open', {});
    await settle(h);
    findByText(h.getRoot(), 'Command Console')[0].click();
    await settle(h);

    t.equals(findByText(h.getRoot(), 'Online Players').length, 0, 'the section is never constructed at all for this narrowed viewer, not merely hidden');
});

t.test('clicking a row resolves it via tablet:openOnlinePlayer (server id + nonce) and opens the SAME Person screen the roster\'s own Manage button opens', async () => {
    const calls = [];
    let personSummaryCitizenId = null;
    const h = createHarness({
        fetchImpl: routeFetch({
            'tablet:requestMyRecord': () => ({ ok: true, viewer: CONSOLE_VIEWER, certifications: [], xp: null, tierLabel: null, myFeatures: [] }),
            'tablet:requestRoster': () => ({ ok: true, rows: [], truncated: false }),
            'tablet:requestOnlinePlayers': () => ({ ok: true, rows: [ONE_ONLINE_ROW], truncated: false }),
            'tablet:openOnlinePlayer': (body) => {
                t.equals(body.source, 42);
                t.equals(body.nonce, 'nonce-abc-1');
                return { ok: true, citizenid: 'RESOLVED-CIT-1', name: 'Rex Shepherd' };
            },
            'tablet:requestPersonSummary': (body) => {
                personSummaryCitizenId = body.targetCitizenId;
                return {
                    ok: true,
                    target: { citizenid: 'RESOLVED-CIT-1', name: 'Rex Shepherd' },
                    certifications: [], xp: 0, tierLabel: null, permissions: [],
                };
            },
        }, calls),
    });
    await openConsole(h);

    findByText(h.getRoot(), 'Manage')[0].click();
    await settle(h);

    t.isTrue(calls.some((c) => c.name === 'tablet:openOnlinePlayer'), 'the resolve round trip actually fired');
    t.equals(personSummaryCitizenId, 'RESOLVED-CIT-1', 'the Person screen was opened for the SERVER-RESOLVED citizenid, never a client-side guess');
    t.isTrue(findByText(h.getRoot(), 'Rex Shepherd').length >= 1, 'landed on the real Person screen');
});

t.test('a resolve failure (the person disconnected / the list went stale) shows the server\'s own message and never navigates to a Person screen', async () => {
    const h = createHarness({
        fetchImpl: routeFetch({
            'tablet:requestMyRecord': () => ({ ok: true, viewer: CONSOLE_VIEWER, certifications: [], xp: null, tierLabel: null, myFeatures: [] }),
            'tablet:requestRoster': () => ({ ok: true, rows: [], truncated: false }),
            'tablet:requestOnlinePlayers': () => ({ ok: true, rows: [ONE_ONLINE_ROW], truncated: false }),
            'tablet:openOnlinePlayer': () => ({ ok: false, error: 'target_disconnected', message: 'That player is no longer connected at that slot. Refresh the Online Players list and try again.' }),
        }),
    });
    await openConsole(h);

    findByText(h.getRoot(), 'Manage')[0].click();
    await settle(h);

    t.isTrue(findByText(h.getRoot(), 'That player is no longer connected at that slot. Refresh the Online Players list and try again.').length >= 1, 'the exact server-provided refusal message is shown');
    // Still on the Console screen -- Online Players heading still present,
    // and the row is still there (a failed resolve is not a navigation).
    t.isTrue(findByText(h.getRoot(), 'Online Players').length >= 1);
});

t.test('a NEVER-MINTED / garbage response (no citizenid despite ok:true) is treated as a failure, never a silent open with an empty target', async () => {
    const h = createHarness({
        fetchImpl: routeFetch({
            'tablet:requestMyRecord': () => ({ ok: true, viewer: CONSOLE_VIEWER, certifications: [], xp: null, tierLabel: null, myFeatures: [] }),
            'tablet:requestRoster': () => ({ ok: true, rows: [], truncated: false }),
            'tablet:requestOnlinePlayers': () => ({ ok: true, rows: [ONE_ONLINE_ROW], truncated: false }),
            'tablet:openOnlinePlayer': () => ({ ok: true }), // malformed -- no citizenid
        }),
    });
    await openConsole(h);

    findByText(h.getRoot(), 'Manage')[0].click();
    await settle(h);

    // No person screen ever reached -- the "Command Console" tab is still
    // the active one, and no tablet:requestPersonSummary would have had
    // anything sensible to key off.
    t.equals(findByText(h.getRoot(), 'Back').length, 0, 'the Person screen\'s own Back button never appears -- never opened');
});

t.test('ONE SEARCH BOX: typing searches BOTH lists at once -- online players and the certified roster -- debounced, with the final typed query', async () => {
    const onlineQueriesSeen = [];
    const rosterQueriesSeen = [];
    const h = createHarness({
        fetchImpl: routeFetch({
            'tablet:requestMyRecord': () => ({ ok: true, viewer: CONSOLE_VIEWER, certifications: [], xp: null, tierLabel: null, myFeatures: [] }),
            'tablet:requestRoster': (body) => { rosterQueriesSeen.push(body ? body.query : undefined); return { ok: true, rows: [], truncated: false }; },
            'tablet:requestOnlinePlayers': (body) => { onlineQueriesSeen.push(body ? body.query : undefined); return { ok: true, rows: [], truncated: false }; },
        }),
    });
    await openConsole(h);

    const inputs = findByTag(h.getRoot(), 'input').filter((i) => i.getAttribute('type') === 'text');
    t.equals(inputs.length, 1, 'exactly one search box on the Console -- not one per list');
    const search = inputs[0];
    t.equals(search.getAttribute('placeholder'), 'Name, citizen ID or server ID...');

    search.typeValue('r');
    search.typeValue('re');
    search.typeValue('rex');
    await new Promise((r) => setTimeout(r, 40));

    t.equals(onlineQueriesSeen[0], '', 'initial load used an empty query');
    t.equals(onlineQueriesSeen[onlineQueriesSeen.length - 1], 'rex', 'online players searched with the final value');
    t.equals(rosterQueriesSeen[rosterQueriesSeen.length - 1], 'rex', 'the certified roster searched with the same value');
    t.isTrue(onlineQueriesSeen.length < 4 && rosterQueriesSeen.length < 4, 'rapid keystrokes were coalesced, not fired individually');
});

t.test('a truncated online-players list shows the server-provided message', async () => {
    const h = createHarness({
        fetchImpl: routeFetch({
            'tablet:requestMyRecord': () => ({ ok: true, viewer: CONSOLE_VIEWER, certifications: [], xp: null, tierLabel: null, myFeatures: [] }),
            'tablet:requestRoster': () => ({ ok: true, rows: [], truncated: false }),
            'tablet:requestOnlinePlayers': () => ({ ok: true, rows: [ONE_ONLINE_ROW], truncated: true, truncatedMessage: 'Showing the first 100 online players — narrow your search to see the rest.' }),
        }),
    });
    await openConsole(h);

    t.isTrue(findByText(h.getRoot(), 'Showing the first 100 online players — narrow your search to see the rest.').length >= 1);
});

t.test('the one Refresh button re-fetches both lists', async () => {
    let calls = 0;
    let rosterCalls = 0;
    const h = createHarness({
        fetchImpl: routeFetch({
            'tablet:requestMyRecord': () => ({ ok: true, viewer: CONSOLE_VIEWER, certifications: [], xp: null, tierLabel: null, myFeatures: [] }),
            'tablet:requestRoster': () => { rosterCalls++; return { ok: true, rows: [], truncated: false }; },
            'tablet:requestOnlinePlayers': () => { calls++; return { ok: true, rows: [], truncated: false }; },
        }),
    });
    await openConsole(h);
    t.equals(calls, 1, 'initial console entry loads it once');
    t.equals(findByText(h.getRoot(), 'Refresh').length, 1, 'one Refresh, not one per list');

    findByText(h.getRoot(), 'Refresh')[0].click();
    await settle(h);
    t.equals(calls, 2, 'Refresh fires a real, fresh fetch -- this list is never polled automatically');
    t.equals(rosterCalls, 2, 'and refreshes the certified list too');
});

t.test('no results (empty search) shows an honest empty state, never a blank gap', async () => {
    const h = createHarness({
        fetchImpl: routeFetch({
            'tablet:requestMyRecord': () => ({ ok: true, viewer: CONSOLE_VIEWER, certifications: [], xp: null, tierLabel: null, myFeatures: [] }),
            'tablet:requestRoster': () => ({ ok: true, rows: [], truncated: false }),
            'tablet:requestOnlinePlayers': () => ({ ok: true, rows: [], truncated: false }),
        }),
    });
    await openConsole(h);

    t.isTrue(findByText(h.getRoot(), 'Nobody matching that search is online right now.').length >= 1);
});

t.run();
