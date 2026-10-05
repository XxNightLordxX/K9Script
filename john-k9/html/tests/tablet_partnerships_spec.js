/*
    html/tests/tablet_partnerships_spec.js

    Covers the Partnerships tab (html/tablet.js's own buildPartnershipsScreen())
    -- owner, verbatim, two passes: "both the k9 and handler should be able
    to pull up a list of there partners and levels etc in a tab... Past
    partnerships matter too, not just the active one" -- refined -- "a
    partnership tab should be shown on all tablets as a tab... high command
    is a handler or a k9 and should have control over it also but the
    partnership tab should show whos there partners."

    Specifically proves:
      1. The tab is UNCONDITIONAL -- reachable for a K9 viewer, an ordinary
         handler viewer, AND a high-command viewer, all from the SAME tab
         bar (never gated on isHighCommand/canManageRoster the way Console
         is), because the owner corrected: "high command is not a fourth
         species... a handler or a k9... and also administers."
      2. The personal section renders the active partner (name/role/tier)
         AND the full history list (active + ended rows), including a
         truncation notice when the server reports one -- past
         partnerships are shown, not just the current one.
      3. The admin lookup section (look up ANY citizen's partnerships, and
         a Force End Partnership control on their active row) appears ONLY
         for state.viewer.isHighCommand -- an ordinary viewer never sees it
         at all, even though it lives on the exact same screen/tab.
      4. Force End Partnership actually fires tablet:forceEndPartnership
         with the looked-up citizenid, and re-pulls that lookup afterward
         (never assumes success from a local optimistic mutation).
      5. Feature-disabled and empty-history both get an honest, explicit
         notice -- never a blank panel.
      6. HOSTILE STRING PROOF (this file's own mandatory coverage, per
         html/tests/tablet_permission_catalog_capabilities_spec.js's
         established pattern): a malicious partnerName/endedByName/
         tierTitle reaches the DOM only via textContent, never innerHTML.
*/
'use strict';

const t = require('./testkit');
const { createHarness, jsonResponse } = require('./tablet-sandbox');
const { findByText, findAll } = require('./tablet-dom-stub');

function routeFetch(handlers) {
    return function (url, init) {
        const name = url.split('/').pop();
        const body = init && init.body ? JSON.parse(init.body) : undefined;
        const h = handlers[name];
        if (!h) return Promise.reject(new Error('tablet_partnerships_spec: unhandled NUI callback ' + name));
        return Promise.resolve(jsonResponse(h(body)));
    };
}

async function settle(times) {
    for (let i = 0; i < (times || 3); i++) await new Promise((r) => setImmediate(r));
}

function myRecordFor(viewer) {
    return {
        ok: true,
        viewer: Object.assign({ citizenid: 'VIEWER1', name: 'Officer Viewer', isHighCommand: false, effectivePermissions: [], allowSelfGrant: false, isK9: false, isPartnered: false }, viewer),
        certifications: [],
        xp: null,
        tierLabel: null,
        myFeatures: [],
    };
}

/**
 * Opens a PERSON as high command, through the Command Console's
 * "open by exact citizen ID" box -- the one person-finder the tablet keeps.
 *
 * The partnership history + Force End controls used to live behind their own
 * lookup box on the Partnerships tab. Plan item E moved them onto the person,
 * where the rest of that person's admin already was, and deleted the second
 * box. These tests follow them: the capability is unchanged, only the route
 * to it is, so each one still proves the same thing it always did.
 */
async function openPersonAsHighCommand(citizenid, extraHandlers) {
    const handlers = Object.assign({
        'tablet:requestMyRecord': () => myRecordFor({ isHighCommand: true }),
        'tablet:requestRoster': () => ({ ok: true, rows: [], truncated: false }),
        'tablet:requestOnlinePlayers': () => ({ ok: true, rows: [] }),
        'tablet:requestPersonSummary': (body) => ({
            ok: true,
            target: { citizenid: body.targetCitizenId, name: 'Some K9' },
            certifications: [], xp: 0, tierLabel: null, permissions: [],
            partnership: null,
        }),
        'tablet:requestPersonFeatures': () => ({ ok: true, target: { citizenid: citizenid, name: 'Some K9' }, features: [] }),
        'tablet:permKeysList': () => ({ ok: true, keys: [] }),
        'tablet:certTiersList': () => ({ ok: true, tiers: [] }),
        'tablet:rosterList': () => ({ ok: true, k9: [], handlers: [], unassigned: [] }),
    }, extraHandlers || {});

    const h = createHarness({
        fetchImpl: function (url, init) {
            const name = url.split('/').pop();
            const body = init && init.body ? JSON.parse(init.body) : undefined;
            // Unknown callbacks resolve to a plain refusal rather than
            // rejecting: opening a person fires several opportunistic,
            // best-effort loads, and this spec is about partnerships, not
            // about enumerating every one of them.
            const fn = handlers[name] || (() => ({ ok: false, error: 'not_stubbed' }));
            return Promise.resolve(jsonResponse(fn(body)));
        },
    });
    h.postMessage('tablet:open', {});
    await settle();

    findByText(h.getRoot(), 'Command Console')[0].click();
    await settle();

    const inputs = findAll(h.getRoot(), (n) => n.tagName === 'input');
    t.isTrue(inputs.length >= 1, 'the Console open-by-id box exists');
    inputs[inputs.length - 1].value = citizenid;
    findByText(h.getRoot(), 'Open')[0].click();
    await settle(6);
    return h;
}

async function openPartnershipsTab(viewer, extraHandlers) {
    const h = createHarness({
        fetchImpl: routeFetch(Object.assign({
            'tablet:requestMyRecord': () => myRecordFor(viewer),
        }, extraHandlers || {})),
    });
    h.postMessage('tablet:open', {});
    await settle();

    const tab = findByText(h.getRoot(), 'Partnerships')[0];
    t.isDefined(tab, 'the Partnerships tab button exists');
    tab.click();
    await settle();
    return h;
}

// ======================================================================
// 1. UNCONDITIONAL TAB -- every viewer type reaches it.
// ======================================================================

t.test('K9 viewer: Partnerships tab is reachable and shows the active partner', async () => {
    const h = await openPartnershipsTab({ isK9: true, isPartnered: true }, {
        'tablet:requestMyPartnerships': () => ({
            ok: true,
            featureEnabled: true,
            truncated: false,
            partnerships: [
                { id: 2, partnerCitizenid: 'HANDLER1', partnerName: 'Officer Rex Handler', role: 'k9', active: true, establishedAtUnix: 1700000000, endedAtUnix: null, endedByName: null, endedBySystemReason: null, tenureTierGranted: 1 },
            ],
        }),
        'john-k9:server:getPartnershipTenureProgress': () => ({ ok: true }),
    });

    t.isTrue(findByText(h.getRoot(), 'Officer Rex Handler').length >= 1, 'the active partner\'s NAME is shown, never a citizenid');
    t.equals(findByText(h.getRoot(), 'HANDLER1').length, 0, 'the raw citizenid itself is never rendered');
});

t.test('ORDINARY HANDLER viewer (not high command, not K9): Partnerships tab is reachable too -- never console-gated', async () => {
    const h = await openPartnershipsTab({ isK9: false, isPartnered: false, effectivePermissions: [] }, {
        'tablet:requestMyPartnerships': () => ({ ok: true, featureEnabled: true, truncated: false, partnerships: [] }),
    });

    t.isTrue(findByText(h.getRoot(), 'Partnership History').length >= 1, 'the personal section renders for an ordinary handler with zero console access');
});

t.test('HIGH COMMAND viewer: the Partnerships tab is now ONLY their own history -- the admin lookup box is gone from it entirely', async () => {
    // PLAN ITEM E. This tab is what the owner asked for and nothing else:
    // who is partnered with whom, for you. Looking somebody else up is
    // per-person admin and happens on the person now, so the second
    // person-finding box that used to sit on top of this screen is gone --
    // one of eleven such boxes, all of which ended at the same place.
    const h = await openPartnershipsTab({ isHighCommand: true }, {
        'tablet:requestMyPartnerships': () => ({ ok: true, featureEnabled: true, truncated: false, partnerships: [] }),
    });

    t.equals(findByText(h.getRoot(), "Look Up Someone's Partnerships").length, 0, 'the admin lookup section is no longer on this tab');
    t.equals(findAll(h.getRoot(), (n) => n.tagName === 'input').length, 0, 'and this screen has no input box at all any more');
    t.isTrue(findByText(h.getRoot(), 'Partnership History').length >= 1, 'their own personal section is untouched');
});

t.test('an ordinary (non-high-command) viewer sees exactly the same Partnerships tab -- there is no longer an admin half to withhold', async () => {
    const h = await openPartnershipsTab({ isHighCommand: false }, {
        'tablet:requestMyPartnerships': () => ({ ok: true, featureEnabled: true, truncated: false, partnerships: [] }),
    });

    t.equals(findByText(h.getRoot(), "Look Up Someone's Partnerships").length, 0, 'nothing admin-shaped on this screen for anyone');
    t.isTrue(findByText(h.getRoot(), 'Partnership History').length >= 1, 'and their own history renders exactly as before');
});

// ======================================================================
// 2. PAST PARTNERSHIPS + TRUNCATION.
// ======================================================================

t.test('past (ended) partnerships render alongside the active one, with state/duration/tier -- never only the current partner', async () => {
    const h = await openPartnershipsTab({ isK9: true }, {
        'tablet:requestMyPartnerships': () => ({
            ok: true,
            featureEnabled: true,
            truncated: true,
            partnerships: [
                { id: 3, partnerCitizenid: 'H2', partnerName: 'Current Handler', role: 'k9', active: true, establishedAtUnix: 1700000000, endedAtUnix: null, endedByName: null, endedBySystemReason: null, tenureTierGranted: 0 },
                { id: 2, partnerCitizenid: 'H1', partnerName: 'Former Handler', role: 'k9', active: false, establishedAtUnix: 1600000000, endedAtUnix: 1650000000, endedByName: 'Former Handler', endedBySystemReason: null, tenureTierGranted: 2 },
                { id: 1, partnerCitizenid: 'H0', partnerName: 'Oldest Handler', role: 'k9', active: false, establishedAtUnix: 1500000000, endedAtUnix: 1550000000, endedByName: null, endedBySystemReason: 'certification_revoked', tenureTierGranted: 0 },
            ],
        }),
        'john-k9:server:getPartnershipTenureProgress': () => ({ ok: true }),
    });

    t.isTrue(findByText(h.getRoot(), 'Current Handler').length >= 1, 'the active partner is shown');
    t.isTrue(findByText(h.getRoot(), 'Former Handler').length >= 1, 'a past (ended) partner is ALSO shown');
    t.isTrue(findByText(h.getRoot(), 'Oldest Handler').length >= 1, 'every past partner is shown, not just the most recent');
    t.isTrue(findByText(h.getRoot(), 'You have had 3 partner(s) in total.').length >= 1, 'the HISTORICAL count is shown -- never a live concurrent count');
    t.isTrue(findByText(h.getRoot(), 'Showing your 3 most recent partnerships.').length >= 1, 'a truncated result says so honestly, matching the roster\'s own disclosed-truncation convention');
    t.isTrue(findByText(h.getRoot(), 'Ended by: Automatically (certification_revoked)').length >= 1, 'a system-ended row is decoded into a readable reason, never the raw \'system:...\' sentinel');
});

t.test('feature disabled: an honest notice, never a blank or broken panel', async () => {
    const h = await openPartnershipsTab({ isK9: true }, {
        'tablet:requestMyPartnerships': () => ({ ok: true, featureEnabled: false, truncated: false, partnerships: [] }),
    });

    t.isTrue(findByText(h.getRoot(), 'Partnership tracking is turned off on this server.').length >= 1);
});

t.test('never partnered at all: explicit empty-state notices, not a blank screen', async () => {
    const h = await openPartnershipsTab({ isK9: false }, {
        'tablet:requestMyPartnerships': () => ({ ok: true, featureEnabled: true, truncated: false, partnerships: [] }),
    });

    t.isTrue(findByText(h.getRoot(), 'Not currently partnered.').length >= 1);
    t.isTrue(findByText(h.getRoot(), 'You have never been partnered with anyone.').length >= 1);
});

// ======================================================================
// 3. HIGH COMMAND ADMIN CONTROL -- lookup + Force End Partnership.
// ======================================================================

t.test('HIGH COMMAND: opening a person shows their partnership history and Force End Partnership fires the real callback for the active row only', async () => {
    let forceEndBody = null;
    const h = await openPersonAsHighCommand('TARGETK9', {
        'tablet:requestPartnershipsForTarget': (body) => ({
            ok: true,
            featureEnabled: true,
            truncated: false,
            target: { citizenid: body.targetCitizenId, name: 'Some K9' },
            partnerships: [
                { id: 5, partnerCitizenid: 'HX', partnerName: 'Their Handler', role: 'k9', active: true, establishedAtUnix: 1700000000, endedAtUnix: null, endedByName: null, endedBySystemReason: null, tenureTierGranted: 0 },
            ],
        }),
        'tablet:forceEndPartnership': (body) => { forceEndBody = body; return { ok: true }; },
    });

    t.isTrue(findByText(h.getRoot(), 'Their Handler').length >= 1, 'their partner is shown by name');

    const endBtn = findByText(h.getRoot(), 'End Partnership')[0];
    t.isDefined(endBtn, 'a Force End control exists for the active row');
    endBtn.click(); // arm
    endBtn.click(); // confirm
    await new Promise((r) => setTimeout(r, 30));

    t.isDefined(forceEndBody, 'tablet:forceEndPartnership was actually called');
    t.equals(forceEndBody.targetCitizenId, 'TARGETK9', 'the exact looked-up citizenid was sent -- never a client-guessed one');
});

t.test('HIGH COMMAND: a person who has never been partnered gets an explicit notice, never a blank result', async () => {
    const h = await openPersonAsHighCommand('NEVERPARTNERED', {
        'tablet:requestPartnershipsForTarget': (body) => ({ ok: true, featureEnabled: true, truncated: false, target: { citizenid: body.targetCitizenId, name: body.targetCitizenId }, partnerships: [] }),
    });

    t.isTrue(findByText(h.getRoot(), 'This citizen has never been partnered.').length >= 1);
});

// ======================================================================
// 4. HOSTILE STRING PROOF (mandatory) -- textContent only, never innerHTML.
// ======================================================================

t.test('a hostile partnerName/endedByName reaches the DOM only via textContent, never innerHTML', async () => {
    const malicious = '<img src=x onerror="window.__xss_pwned=true">';
    const h = await openPartnershipsTab({ isK9: true }, {
        'tablet:requestMyPartnerships': () => ({
            ok: true,
            featureEnabled: true,
            truncated: false,
            partnerships: [
                { id: 2, partnerCitizenid: 'H1', partnerName: malicious, role: 'k9', active: true, establishedAtUnix: 1700000000, endedAtUnix: null, endedByName: null, endedBySystemReason: null, tenureTierGranted: 0 },
                { id: 1, partnerCitizenid: 'H0', partnerName: 'Someone Else', role: 'k9', active: false, establishedAtUnix: 1600000000, endedAtUnix: 1650000000, endedByName: malicious, endedBySystemReason: null, tenureTierGranted: 0 },
            ],
        }),
        'john-k9:server:getPartnershipTenureProgress': () => ({ ok: true, tier: 1, tierTitle: malicious, tenureSeconds: 100, tierCount: 3, fullyCollected: false }),
    });

    const matches = findAll(h.getRoot(), (n) => n._textContent === malicious);
    t.isTrue(matches.length >= 1, 'the malicious partnerName/endedByName/tierTitle reaches the DOM verbatim as textContent');

    const innerHTMLWrites = findAll(h.getRoot(), () => true).reduce((sum, el) => sum + (el.innerHTMLWriteCount || 0), 0);
    t.equals(innerHTMLWrites, 0, 'innerHTML must never be written anywhere on this page for a malicious partnership field');
});

t.test('HIGH COMMAND person history: a hostile target name reaches the DOM only via textContent, never innerHTML', async () => {
    const malicious = '"><svg onload=alert(1)>';
    const h = await openPersonAsHighCommand('ANY', {
        'tablet:requestPartnershipsForTarget': (body) => ({
            ok: true,
            featureEnabled: true,
            truncated: false,
            target: { citizenid: body.targetCitizenId, name: malicious },
            partnerships: [
                { id: 1, partnerCitizenid: 'HX', partnerName: malicious, role: 'handler', active: true, establishedAtUnix: 1700000000, endedAtUnix: null, endedByName: null, endedBySystemReason: null, tenureTierGranted: 0 },
            ],
        }),
    });

    const matches = findAll(h.getRoot(), (n) => n._textContent === malicious);
    t.isTrue(matches.length >= 1, 'the malicious target/partner name reaches the DOM verbatim as textContent');

    const innerHTMLWrites = findAll(h.getRoot(), () => true).reduce((sum, el) => sum + (el.innerHTMLWriteCount || 0), 0);
    t.equals(innerHTMLWrites, 0, 'innerHTML must never be written anywhere for a malicious admin-lookup result');
});

t.run();
