/*
    html/tests/tablet_progression_spec.js

    Covers the Progression screen (owner-directed: "do progression put in
    the tablet") -- both ladders, the position maths, and the one
    distinction the whole feature rests on.

    NULL IS NOT ZERO. The server sends null for a ladder whose feature is
    switched off, and 0 for a player genuinely on that ladder with nothing
    earned yet. Those are different facts and must reach the screen as
    different sentences: telling someone "0 XP" about a system their server
    does not run sends them off to grind something that does not exist.
    Several tests below exist purely to pin that apart, because a
    `if (!total)` written anywhere in the render path would collapse the
    two and pass every other test in this file.
*/
'use strict';

const t = require('./testkit');
const { createHarness, jsonResponse } = require('./tablet-sandbox');
const { findByText, findAll } = require('./tablet-dom-stub');

function routeFetch(handlers) {
    return function (url) {
        const name = url.split('/').pop();
        const h = handlers[name];
        if (!h) return Promise.reject(new Error('tablet_progression_spec: unhandled NUI callback ' + name));
        return Promise.resolve(jsonResponse(h()));
    };
}

const K9_LADDER = [
    { xp: 0, label: 'Green K9' },
    { xp: 1000, label: 'Trained K9' },
    { xp: 3000, label: 'Veteran K9' },
    { xp: 9000, label: 'Elite K9' },
];

const HANDLER_LADDER = [
    { xp: 0, label: 'Rookie Handler' },
    { xp: 50, label: 'Certified Handler' },
    { xp: 150, label: 'Senior Handler' },
    { xp: 500, label: 'Master Handler' },
];

function record(over) {
    return Object.assign({
        ok: true,
        viewer: { citizenid: 'ABC123', name: 'Rex', isHighCommand: false, effectivePermissions: [], allowSelfGrant: false },
        certifications: [],
        xp: 1250,
        tierLabel: 'Trained K9',
        handlerXp: 60,
        handlerTierLabel: 'Certified Handler',
        xpLadder: K9_LADDER,
        handlerXpLadder: HANDLER_LADDER,
        myFeatures: [],
    }, over || {});
}

/**
 * NO NAVIGATION -- the ladders are on the LANDING screen now.
 *
 * Progression was its own tab, and it shared two builders with My Record
 * outright while Home showed a filtered copy of the same abilities list.
 * Plan item A merged the three into one 'My Record' screen, which is what
 * the tablet opens on. Every assertion in this file is unchanged; only the
 * two clicks that used to be needed to reach the ladders are gone.
 */
async function openProgression(over) {
    const h = createHarness({
        fetchImpl: routeFetch({ 'tablet:requestMyRecord': () => record(over) }),
    });
    h.postMessage('tablet:open', { capabilities: {}, strings: {}, maxXpPerGrant: 500 });
    await new Promise((r) => setImmediate(r));
    t.equals(findByText(h.getRoot(), 'Progression').length, 0, 'there is no separate Progression tab any more');
    return h;
}

t.test('both ladders are on the landing screen, reachable without any permission at all -- a read of your own record, not an admin surface', async () => {
    const h = await openProgression();
    t.isTrue(findByText(h.getRoot(), 'K9 Rank').length >= 1);
    t.isTrue(findByText(h.getRoot(), 'Handler Rank').length >= 1);
});

t.test('BOTH ladders render on the one screen -- a player is usually both, and the common question is where they stand on each', async () => {
    const h = await openProgression();
    t.isTrue(findByText(h.getRoot(), '1250 XP -- Trained K9').length >= 1, 'the K9 standing');
    t.isTrue(findByText(h.getRoot(), '60 XP -- Certified Handler').length >= 1, 'the handler standing');
});

t.test('the next rank and the exact gap are shown, computed from the real ladder rather than guessed', async () => {
    const h = await openProgression();
    // 1250 -> Veteran K9 at 3000 is 1750 away.
    t.isTrue(findByText(h.getRoot(), 'Next: Veteran K9, 1750 XP away.').length >= 1);
    // 60 -> Senior Handler at 150 is 90 away.
    t.isTrue(findByText(h.getRoot(), 'Next: Senior Handler, 90 XP away.').length >= 1);
});

t.test('at the top of a ladder there is no "next rank" line -- it says so instead of showing a negative gap', async () => {
    const h = await openProgression({ xp: 12000, tierLabel: 'Elite K9' });
    t.isTrue(findByText(h.getRoot(), 'You are at the top of this ladder.').length >= 1);
    const negatives = findByText(h.getRoot(), '-').filter((n) => /-\d+ XP away/.test(n.textContent || ''));
    t.equals(negatives.length, 0, 'a negative remaining value must never render');
});

t.test('NULL IS NOT ZERO: a switched-off ladder says so plainly and shows no number at all', async () => {
    const h = await openProgression({ handlerXp: null, handlerTierLabel: null, handlerXpLadder: [] });
    t.isTrue(findByText(h.getRoot(), 'This server does not track handler XP, so there is no rank to show here.').length >= 1);
    t.equals(findByText(h.getRoot(), '0 XP -- Rookie Handler').length, 0, 'an off ladder must never be rendered as a zero total');
});

t.test('NULL IS NOT ZERO, the other half: a real 0 total renders as a genuine standing on the ladder, not as "switched off"', async () => {
    const h = await openProgression({ handlerXp: 0, handlerTierLabel: 'Rookie Handler' });
    t.isTrue(findByText(h.getRoot(), '0 XP -- Rookie Handler').length >= 1, 'a handler who has earned nothing yet is still ON the ladder');
    t.equals(findByText(h.getRoot(), 'This server does not track handler XP, so there is no rank to show here.').length, 0);
    t.isTrue(findByText(h.getRoot(), 'Next: Certified Handler, 50 XP away.').length >= 1, 'and still has a next rank to aim at');
});

t.test('CONTROL: the two ladders are independent -- the K9 side switched off leaves the handler side fully rendered', async () => {
    const h = await openProgression({ xp: null, tierLabel: null, xpLadder: [] });
    t.isTrue(findByText(h.getRoot(), 'This server does not track K9 XP, so there is no rank to show here.').length >= 1);
    t.isTrue(findByText(h.getRoot(), '60 XP -- Certified Handler').length >= 1, 'one ladder being off must never blank the other');
});

t.test('the full ladder is listed so a player can see what is ahead, not only the next step', async () => {
    const h = await openProgression();
    t.isTrue(findByText(h.getRoot(), 'Elite K9 -- 9000 XP').length >= 1, 'a rank two steps away is still visible');
    t.isTrue(findByText(h.getRoot(), 'Master Handler -- 500 XP').length >= 1);
});

t.test('a total sitting exactly ON a threshold counts as having reached that rank, not as still below it', async () => {
    const h = await openProgression({ xp: 3000, tierLabel: 'Veteran K9' });
    t.isTrue(findByText(h.getRoot(), '3000 XP -- Veteran K9').length >= 1);
    t.isTrue(findByText(h.getRoot(), 'Next: Elite K9, 6000 XP away.').length >= 1, 'and the next rank is the one ABOVE it, never itself');
});

t.test('a malformed ladder row is skipped rather than crashing the screen or rendering "undefined"', async () => {
    const h = await openProgression({
        xpLadder: [{ xp: 0, label: 'Green K9' }, { xp: 'not-a-number', label: 'Broken' }, { label: 'No XP' }, { xp: 1000, label: 'Trained K9' }],
    });
    t.isTrue(findByText(h.getRoot(), '1250 XP -- Trained K9').length >= 1, 'the good rows still render');
    t.equals(findByText(h.getRoot(), 'undefined').length, 0);
});

t.test('an empty record still renders the screen with both off-messages, never a blank panel', async () => {
    const h = await openProgression({ xp: null, tierLabel: null, xpLadder: [], handlerXp: null, handlerTierLabel: null, handlerXpLadder: [] });
    t.isTrue(findByText(h.getRoot(), 'This server does not track K9 XP, so there is no rank to show here.').length >= 1);
    t.isTrue(findByText(h.getRoot(), 'This server does not track handler XP, so there is no rank to show here.').length >= 1);
});

// ------------------------------------------------------------------
// PLACEHOLDER COLLISION -- a rank LABEL that itself contains a token.
//
// Rank labels are not fixed strings: high command renames them live
// through the Rank Editor, and server/xptiers.lua's label validator
// rejects `<>&"'` but has no reason to reject braces. The render path
// used to substitute tokens one at a time with chained .replace(), so a
// label substituted by the FIRST replace was still sitting in the string
// when the SECOND one scanned it -- and got eaten. Cosmetic only (every
// value goes through textContent, never innerHTML) but a rank reading
// "reach {remaining} XP" instead of a number is a bug a player reports.
//
// The fix is a single-pass formatTemplate, so these also stand as the
// regression guard for every other template in the file that interpolates
// operator- or player-supplied text next to a second token.
// ------------------------------------------------------------------

t.test('PLACEHOLDER COLLISION: a rank named with another token in it renders that name verbatim, and the real number still lands', async () => {
    const h = await openProgression({
        xp: 500,
        tierLabel: 'Rookie {remaining} K9',
        xpLadder: [{ xp: 0, label: 'Rookie {remaining} K9' }, { xp: 2000, label: 'Trained K9' }],
    });
    t.isTrue(findByText(h.getRoot(), '500 XP -- Rookie {remaining} K9').length >= 1,
        'the label must survive intact -- the second replace must not reach into what the first one substituted');
    t.isTrue(findByText(h.getRoot(), 'Next: Trained K9, 1500 XP away.').length >= 1,
        'and the genuine token still resolves to the real number');
});

t.test('PLACEHOLDER COLLISION: a NEXT-rank name containing {remaining} does not swallow the countdown', async () => {
    const h = await openProgression({
        xp: 100,
        tierLabel: 'Green K9',
        xpLadder: [{ xp: 0, label: 'Green K9' }, { xp: 900, label: 'Almost {remaining} There' }],
    });
    t.isTrue(findByText(h.getRoot(), 'Next: Almost {remaining} There, 800 XP away.').length >= 1,
        'the countdown a player is actually reading must not be replaced by a number pulled out of the rank name');
});

t.test('PLACEHOLDER COLLISION: an {xp} inside a ladder row label leaves that row\'s real threshold intact', async () => {
    const h = await openProgression({
        xp: 0,
        tierLabel: 'Green K9',
        xpLadder: [{ xp: 0, label: 'Green K9' }, { xp: 7500, label: 'Elite {xp} Unit' }],
    });
    t.isTrue(findByText(h.getRoot(), 'Elite {xp} Unit -- 7500 XP').length >= 1,
        'the row must show the rank name AND its own real threshold, not the threshold twice');
});

t.test('PLACEHOLDER COLLISION: an unknown token in a template is left verbatim rather than rendering "undefined"', async () => {
    const h = await openProgression({ xp: 300, tierLabel: 'Some {nosuchtoken} Rank' });
    t.equals(findByText(h.getRoot(), 'undefined').length, 0,
        'a typo in a template must never surface to a player as the word undefined');
    t.isTrue(findByText(h.getRoot(), '300 XP -- Some {nosuchtoken} Rank').length >= 1);
});

// ------------------------------------------------------------------
// LADDER ORDER. The server does sort ascending
// (server/progression.lua's LadderForDisplay), so these are not fixing a
// payload seen in practice -- they pin that this screen no longer DEPENDS
// on that, because the dependency was invisible from this side: a ladder
// arriving unsorted would have rendered in the wrong order and marked the
// wrong row as current, with no error anywhere.
// ------------------------------------------------------------------

t.test('LADDER ORDER: an out-of-order ladder still resolves the correct current rank and the correct next one', async () => {
    const h = await openProgression({
        xp: 2500,
        tierLabel: null, // force the label to come from the position maths, not the server's own string
        xpLadder: [
            { xp: 9000, label: 'Elite K9' },
            { xp: 0, label: 'Green K9' },
            { xp: 3000, label: 'Veteran K9' },
            { xp: 1000, label: 'Trained K9' },
        ],
    });

    t.isTrue(findByText(h.getRoot(), '2500 XP -- Trained K9').length >= 1,
        'current must be the HIGHEST threshold at or below the total (1000), not whichever row happened to come last');
    t.isTrue(findByText(h.getRoot(), 'Next: Veteran K9, 500 XP away.').length >= 1,
        'next must be the LOWEST threshold above the total (3000), not the first one encountered');
});

t.test('LADDER ORDER: the rendered rank list is displayed ascending regardless of the order it arrived in', async () => {
    const h = await openProgression({
        xp: 0,
        tierLabel: 'Green K9',
        xpLadder: [
            { xp: 9000, label: 'Elite K9' },
            { xp: 0, label: 'Green K9' },
            { xp: 3000, label: 'Veteran K9' },
        ],
    });

    const items = findAll(h.getRoot(), (n) => n.classList && n.classList.contains('k9tablet-progression-rank'))
        .map((n) => n._textContent);
    const order = ['Green K9', 'Veteran K9', 'Elite K9'].map((name) => items.findIndex((txt) => txt.indexOf(name) >= 0));
    t.isTrue(order[0] >= 0 && order[1] >= 0 && order[2] >= 0, 'all three ranks render');
    t.isTrue(order[0] < order[1] && order[1] < order[2],
        'a rank list shown out of order is unreadable as a progression -- the whole point is seeing what is ahead');
});

t.test('LADDER ORDER: an out-of-order ladder with a malformed row in it still drops only the malformed row', async () => {
    const h = await openProgression({
        xp: 5000,
        tierLabel: null,
        xpLadder: [
            { xp: 9000, label: 'Elite K9' },
            { xp: 'not-a-number', label: 'Broken' },
            { xp: 3000, label: 'Veteran K9' },
            { label: 'No XP' },
            { xp: 0, label: 'Green K9' },
        ],
    });

    t.isTrue(findByText(h.getRoot(), '5000 XP -- Veteran K9').length >= 1);
    t.isTrue(findByText(h.getRoot(), 'Next: Elite K9, 4000 XP away.').length >= 1);
    t.equals(findByText(h.getRoot(), 'undefined').length, 0);
});

t.run();
