/*
    html/tests/tablet_person_rank_partnership_spec.js

    Covers the person screen's Rank and Partnership sections
    (html/tablet.js's buildRankSection()/buildPartnershipSection()) --
    owner-directed "roster panel: cert+tier, rank, XP+tier, partnership,
    permissions, all in one screen" pass. Both sections are READ-ONLY
    (server/tablet.lua's PersonSummaryResult.job/.partnership) -- this file
    also proves NO promotion/rank-change control is ever rendered, since
    this resource has no write path for job grade at all today (see
    buildRankSection's own doc comment).
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
        if (!h) return Promise.reject(new Error('tablet_person_rank_partnership_spec: unhandled NUI callback ' + name));
        return Promise.resolve(jsonResponse(h(body)));
    };
}

const HIGH_COMMAND_VIEWER = { citizenid: 'HC1', name: 'Chief', isHighCommand: true, effectivePermissions: ['k9.access', 'k9.certify', 'k9.audit', 'k9.givexp'], allowSelfGrant: false };

async function settle(times) {
    for (let i = 0; i < (times || 3); i++) await new Promise((r) => setImmediate(r));
}

function baseHandlers(overrides) {
    return Object.assign({
        'tablet:requestMyRecord': () => ({ ok: true, viewer: HIGH_COMMAND_VIEWER, certifications: [], xp: null, tierLabel: null, myFeatures: [] }),
        'tablet:requestRoster': () => ({ ok: true, rows: [{ citizenid: 'TARGET1', name: 'K9 Rex', departmentLabel: 'Police', certified: true, xp: 500, tierLabel: 'Trained K9' }], truncated: false }),
        'tablet:requestPersonFeatures': () => ({ ok: true, target: { citizenid: 'TARGET1', name: 'K9 Rex' }, features: [] }),
    }, overrides || {});
}

async function openPersonScreen(h) {
    h.postMessage('tablet:open', {});
    await settle();
    findByText(h.getRoot(), 'Command Console')[0].click();
    await settle();
    findByText(h.getRoot(), 'Manage')[0].click();
    await settle(4);
}

function rankLines(h) {
    return findAll(h.getRoot(), (n) => n.classList && n.classList.contains('k9tablet-rank-line')).map((n) => n._textContent);
}

function partnershipLines(h) {
    return findAll(h.getRoot(), (n) => n.classList && n.classList.contains('k9tablet-partnership-line')).map((n) => n._textContent);
}

t.test('a resolvable job renders department + grade name/level as plain text, with NO promotion control anywhere on the page', async () => {
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:requestPersonSummary': () => ({
                ok: true, target: { citizenid: 'TARGET1', name: 'K9 Rex' }, certifications: [], xp: 500, tierLabel: 'Trained K9', permissions: [],
                job: { departmentLabel: 'Los Santos Police Department', gradeLabel: 'Sergeant', gradeLevel: 4, isBoss: false },
                partnership: null,
            }),
        })),
    });
    await openPersonScreen(h);

    t.equals(findByText(h.getRoot(), 'Rank').length, 1, 'the Rank section heading renders');
    const lines = rankLines(h);
    t.equals(lines[0], 'Department: Los Santos Police Department');
    t.equals(lines[1], 'Grade: Sergeant (4)');

    // NO PROMOTION CONTROL -- this resource has no job-grade write path at
    // all today; there must be no rank-specific <select>/dropdown anywhere
    // on this screen, and no button whose label suggests one.
    const rankSection = findAll(h.getRoot(), (n) => n.classList && n.classList.contains('k9tablet-rank-section'))[0];
    t.isDefined(rankSection);
    t.equals(findAll(rankSection, (n) => n.tagName === 'select' || n.tagName === 'button').length, 0, 'the rank section is plain text only -- no control at all, promotion or otherwise');
    t.equals(findByText(h.getRoot(), 'Promote').length, 0);
    t.equals(findByText(h.getRoot(), 'Set Grade').length, 0);
});

t.test('an isBoss target gets the Boss badge appended to their grade line', async () => {
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:requestPersonSummary': () => ({
                ok: true, target: { citizenid: 'TARGET1', name: 'K9 Rex' }, certifications: [], xp: 500, tierLabel: 'Trained K9', permissions: [],
                job: { departmentLabel: 'Blaine County Sheriff', gradeLabel: 'Sheriff', gradeLevel: 5, isBoss: true },
                partnership: null,
            }),
        })),
    });
    await openPersonScreen(h);

    const lines = rankLines(h);
    t.equals(lines[1], 'Grade: Sheriff (5) (Boss)');
});

t.test('job === null renders the disclosed "not available" note, never a blank section or a guessed value', async () => {
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:requestPersonSummary': () => ({
                ok: true, target: { citizenid: 'TARGET1', name: 'K9 Rex' }, certifications: [], xp: 500, tierLabel: 'Trained K9', permissions: [],
                job: null,
                partnership: null,
            }),
        })),
    });
    await openPersonScreen(h);

    t.equals(findByText(h.getRoot(), 'Rank information is not available for this person right now.').length, 1);
    t.equals(rankLines(h).length, 0);
});

t.test('partnership === null renders "Not currently partnered."', async () => {
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:requestPersonSummary': () => ({
                ok: true, target: { citizenid: 'TARGET1', name: 'K9 Rex' }, certifications: [], xp: 500, tierLabel: 'Trained K9', permissions: [],
                job: null,
                partnership: null,
            }),
        })),
    });
    await openPersonScreen(h);

    t.equals(findByText(h.getRoot(), 'Partnership').length, 1, 'the Partnership section heading renders');
    t.equals(findByText(h.getRoot(), 'Not currently partnered.').length, 1);
});

t.test('an active partnership renders the partner name and this person\'s role in it', async () => {
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:requestPersonSummary': () => ({
                ok: true, target: { citizenid: 'TARGET1', name: 'K9 Rex' }, certifications: [], xp: 500, tierLabel: 'Trained K9', permissions: [],
                job: null,
                partnership: { partnerCitizenid: 'HANDLER1', partnerName: 'Jane Handler', role: 'k9' },
            }),
        })),
    });
    await openPersonScreen(h);

    const lines = partnershipLines(h);
    t.equals(lines[0], 'Partner: Jane Handler');
    t.equals(lines[1], 'Role in partnership: K9');
});

t.test('a hostile department/grade/partner name reaches the DOM only via textContent, never innerHTML', async () => {
    const malicious = '<img src=x onerror="window.__xss_pwned=true">';
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:requestPersonSummary': () => ({
                ok: true, target: { citizenid: 'TARGET1', name: 'K9 Rex' }, certifications: [], xp: 500, tierLabel: 'Trained K9', permissions: [],
                job: { departmentLabel: malicious, gradeLabel: malicious, gradeLevel: 1, isBoss: false },
                partnership: { partnerCitizenid: 'HANDLER1', partnerName: malicious, role: 'handler' },
            }),
        })),
    });
    await openPersonScreen(h);

    const matches = findAll(h.getRoot(), (n) => typeof n._textContent === 'string' && n._textContent.indexOf(malicious) !== -1);
    t.isTrue(matches.length >= 3, 'the malicious department/grade/partner-name strings all reach the DOM verbatim as textContent');

    const innerHTMLWrites = findAll(h.getRoot(), () => true).reduce((sum, el) => sum + (el.innerHTMLWriteCount || 0), 0);
    t.equals(innerHTMLWrites, 0, 'innerHTML must never be written anywhere on this page for a malicious job/partnership field');
});

t.run();

// ----------------------------------------------------------------------
// HANDLER XP -- the second ladder on the person screen.
//
// server/tablet.lua has always sent handlerXp/handlerTierLabel on this
// payload; the state mapping dropped both and nothing rendered them, so
// every person-summary fetch computed a handler's rank and threw it away.
//
// NULL IS NOT ZERO is the whole reason this renders in a branch instead of
// calling xpLine() the way the K9 line does: null means the handler ladder
// is switched off server-wide, 0 means a real handler who has not earned
// anything yet, and xpLine collapses both to "No XP record yet" -- which
// would send someone off to grind a system their server does not run.
// ----------------------------------------------------------------------

function xpLines(h) {
    return findAll(h.getRoot(), (n) => n.classList && n.classList.contains('k9tablet-xp-line')).map((n) => n._textContent);
}

async function openPersonWithSummary(extra) {
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:requestPersonSummary': () => Object.assign({
                ok: true, target: { citizenid: 'TARGET1', name: 'K9 Rex' }, certifications: [],
                xp: 500, tierLabel: 'Trained K9', permissions: [], job: null, partnership: null,
            }, extra || {}),
        })),
    });
    await openPersonScreen(h);
    return h;
}

t.test('HANDLER XP: a handler\'s own rank renders in its own section, separate from the K9 one', async () => {
    const h = await openPersonWithSummary({ handlerXp: 220, handlerTierLabel: 'Senior Handler' });

    t.equals(findByText(h.getRoot(), 'Handler XP').length, 1, 'its own heading -- the two ladders are never merged into one line');
    t.equals(findByText(h.getRoot(), 'K9 XP').length, 1, 'and the K9 heading now says which ladder it means');
    const lines = xpLines(h);
    t.isTrue(lines.indexOf('500 — Trained K9') >= 0, 'the K9 line is unchanged');
    t.isTrue(lines.indexOf('220 — Senior Handler') >= 0, 'and the handler line is genuinely rendered, not computed and discarded');
});

t.test('HANDLER XP: 0 is a real standing on the ladder, NOT "switched off"', async () => {
    const h = await openPersonWithSummary({ handlerXp: 0, handlerTierLabel: 'Rookie Handler' });

    t.isTrue(xpLines(h).indexOf('0 — Rookie Handler') >= 0, 'a handler who has earned nothing yet is still on the ladder');
    t.equals(findByText(h.getRoot(), 'This server does not track handler XP.').length, 0,
        'a falsy-but-real 0 must never be mistaken for the feature being off');
});

t.test('HANDLER XP: null says the ladder is switched off, rather than showing a misleading "no record yet"', async () => {
    const h = await openPersonWithSummary({ handlerXp: null, handlerTierLabel: null });

    t.equals(findByText(h.getRoot(), 'This server does not track handler XP.').length, 1);
    t.equals(findByText(h.getRoot(), 'No XP record yet.').length, 0,
        'that phrasing would send an operator looking for XP a handler can never earn here');
});

t.test('HANDLER XP: the ladders are independent -- a real handler rank shows even with the K9 ladder off', async () => {
    const h = await openPersonWithSummary({ xp: null, tierLabel: null, handlerXp: 500, handlerTierLabel: 'Master Handler' });

    t.isTrue(xpLines(h).indexOf('500 — Master Handler') >= 0, 'one ladder being off must never blank the other');
});

t.test('HANDLER XP: a person whose ONLY record is a handler standing is not written off as "no record found"', async () => {
    // personSummaryLooksLikeNoRecord() predates the handler ladder and only
    // ever considered the K9 one. Everything else about this person is
    // genuinely empty -- no job, no partner, no K9 XP, no certification, no
    // explicit permission -- so before handlerXp was added to that guard the
    // whole screen collapsed to "no record found" and threw away a standing
    // the server had just sent. Narrow, but the guard exists precisely to
    // tell "the server knows nothing" apart from "this person is quiet".
    const h = await openPersonWithSummary({
        xp: null, tierLabel: null, certifications: [], permissions: [], job: null, partnership: null,
        handlerXp: 500, handlerTierLabel: 'Master Handler',
    });

    t.equals(findByText(h.getRoot(), 'No record found for this citizen ID. Double-check the ID -- it may be a typo, or belong to a deleted character.').length, 0,
        'handler XP is something the server knows about them, so the screen must render');
    t.isTrue(xpLines(h).indexOf('500 — Master Handler') >= 0);
});

t.test('HANDLER XP: a genuinely empty person IS still written off as "no record found" -- the control', async () => {
    // The guard must not be defeated wholesale by the change above: a person
    // the server really knows nothing about still gets the honest message.
    const h = await openPersonWithSummary({
        xp: null, tierLabel: null, certifications: [], permissions: [], job: null, partnership: null,
        handlerXp: null, handlerTierLabel: null,
    });

    t.equals(findByText(h.getRoot(), 'No record found for this citizen ID. Double-check the ID -- it may be a typo, or belong to a deleted character.').length, 1);
});

t.test('HANDLER XP: a handler on a genuine 0 also counts as a record -- 0 is not absence', async () => {
    const h = await openPersonWithSummary({
        xp: null, tierLabel: null, certifications: [], permissions: [], job: null, partnership: null,
        handlerXp: 0, handlerTierLabel: 'Rookie Handler',
    });

    t.equals(findByText(h.getRoot(), 'No record found for this citizen ID. Double-check the ID -- it may be a typo, or belong to a deleted character.').length, 0,
        'a falsy-but-real 0 must not be read as an absent record');
    t.isTrue(xpLines(h).indexOf('0 — Rookie Handler') >= 0);
});

t.test('HANDLER XP: there is NO give-handler-XP control -- handler XP is earned, never granted by hand', async () => {
    const h = await openPersonWithSummary({ handlerXp: 220, handlerTierLabel: 'Senior Handler' });

    // The K9 side DOES have a grant control for a viewer holding k9.givexp
    // (HIGH_COMMAND_VIEWER holds it). The handler side deliberately has no
    // equivalent: every handler award is minted by Config.HandlerXP's own
    // actions behind per-actor mint cooldowns, and an admin grant path
    // would route straight around them.
    t.equals(findByText(h.getRoot(), 'Give Handler XP').length, 0);
    t.equals(findByText(h.getRoot(), 'Grant Handler XP').length, 0);
});
