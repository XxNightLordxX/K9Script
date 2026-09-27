/*
    html/tests/tablet_xp_tiers_spec.js

    Covers the XP Rank Editor screen (its own tab, high command only) --
    server/xptiers.lua. Owner's own words: "...or even add or remove
    permissions, set experience level for each rank up etc." -- this screen
    answers the SECOND half of that quote (the permission-key catalog
    answers the first, see html/tests/... permission-key coverage in
    tablet_role_theme_certtiers_spec.js).

    Server contract verified against server/xptiers.lua directly (not
    assumed):
      tablet:xpTiersList {}       -> cb({ok, tiers?, error?})
      tablet:xpTiersUpsert {...}  -> cb({ok, tiers?, warning?, error?})
    `tiers` is the full four-rank ladder, `{ ordinal, xp, label,
    speedMultiplier, scentRangeMultiplier, medkitCooldownMultiplier?,
    badge?, xpLocked }`, xpLocked true for rank 1 ONLY. `reason` is renamed
    to `error` by client/tablet.lua's TranslateReasonResult before it ever
    reaches this page, so every failure fixture below uses `error`, never
    `reason`.

    TWO THINGS THIS FILE EXISTS SPECIFICALLY TO PROVE:
      1. Rank 1's XP field is GENUINELY read-only -- not merely visually
         disabled while the submitted value still comes from the input.
         The "typing into it does nothing" case below proves this the same
         way tablet_role_theme_certtiers_spec.js proves the cert-tier key
         input is disabled for an existing tier: by attempting the disallowed
         interaction and checking the RESULT, not just the attribute.
      2. Every one of the 12 documented failure reasons renders its OWN
         distinct message -- a generic "something went wrong" would leave
         an operator guessing which of six numeric fields they got wrong,
         per this task's own explicit instruction.

    Every gate below is asserted as a CONVENIENCE, per html/tablet.js's own
    THE SECURITY RULE -- this suite never treats "the control isn't there"
    as a substitute for "the action is denied"; that is client/tablet.lua's
    and server/xptiers.lua's own job, covered in tests/xptiereditor_spec.lua.
*/
'use strict';

const t = require('./testkit');
const { createHarness, jsonResponse } = require('./tablet-sandbox');
const { findByText, findAll, openSettingsSection } = require('./tablet-dom-stub');

function routeFetch(handlers) {
    return function (url, init) {
        const name = url.split('/').pop();
        const body = init && init.body ? JSON.parse(init.body) : undefined;
        const h = handlers[name];
        if (!h) return Promise.reject(new Error('tablet_xp_tiers_spec: unhandled NUI callback ' + name));
        return Promise.resolve(jsonResponse(h(body)));
    };
}

function findInput(root, predicate) {
    return findAll(root, (n) => n.tagName === 'input' && predicate(n))[0];
}

const HIGH_COMMAND_VIEWER = { citizenid: 'HC1', name: 'Chief', isHighCommand: true, effectivePermissions: ['k9.access', 'k9.certify', 'k9.audit', 'k9.givexp'], allowSelfGrant: false };
const CONSOLE_ONLY_VIEWER = { citizenid: 'OFFICER1', name: 'Officer', isHighCommand: false, effectivePermissions: ['k9.certify'], allowSelfGrant: false };

async function settle(times) {
    for (let i = 0; i < (times || 3); i++) await new Promise((r) => setImmediate(r));
}

function baseHandlers(overrides) {
    return Object.assign({
        'tablet:requestMyRecord': () => ({ ok: true, viewer: HIGH_COMMAND_VIEWER, certifications: [], xp: null, tierLabel: null, myFeatures: [] }),
        'tablet:getTheme': () => ({ ok: true, theme: { primaryColor: '#2563eb', accentColor: '#f59e0b', backgroundColor: '#111827', textColor: '#f9fafb', density: 'comfortable', headerTitle: 'K9 Command Tablet' } }),
        // XP Ranks is a SECTION of the Catalogs tab now (plan item G), so
        // opening it also loads the other two catalogs. Both answer
        // successfully and empty: this file is about the XP ladder, and a
        // failure in a neighbouring section would put a second Retry button
        // on screen and make the error assertions below ambiguous.
        'tablet:certTiersList': () => ({ ok: true, tiers: [] }),
        'tablet:permKeysList': () => ({ ok: true, keys: [] }),
    }, overrides || {});
}

async function openTablet(h) {
    h.postMessage('tablet:open', {});
    await settle();
}

function openXpTiersTab(h) {
    return openSettingsSection(h.getRoot(), 'Catalogs');
}

/** The real four-rank shape server/xptiers.lua's own ListXPTiersSnapshot
 * returns -- rank 1 always xpLocked, invented labels this test controls so
 * a hardcoded-list regression would be caught the same way
 * tablet_role_theme_certtiers_spec.js's own DYNAMIC CATALOGUE test catches
 * one for certification tiers. */
const FOUR_RANK_LADDER = [
    { ordinal: 1, xp: 0, label: 'Recruit K9', speedMultiplier: 1.0, scentRangeMultiplier: 1.0, xpLocked: true },
    { ordinal: 2, xp: 1250, label: 'Trained K9', speedMultiplier: 1.05, scentRangeMultiplier: 1.1, xpLocked: false },
    { ordinal: 3, xp: 4000, label: 'Veteran K9', speedMultiplier: 1.1, scentRangeMultiplier: 1.2, medkitCooldownMultiplier: 0.9, xpLocked: false },
    { ordinal: 4, xp: 9000, label: 'Zzyzx Apex K9', speedMultiplier: 1.15, scentRangeMultiplier: 1.3, badge: 'APEX', xpLocked: false },
];

// ======================================================================
// GATING
// ======================================================================

t.test('a non-high-command console user never sees the Catalogs tab (which is where XP Ranks now lives)', async () => {
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:requestMyRecord': () => ({ ok: true, viewer: CONSOLE_ONLY_VIEWER, certifications: [], xp: null, tierLabel: null, myFeatures: [] }),
        })),
    });
    await openTablet(h);
    t.equals(findByText(h.getRoot(), 'Catalogs').length, 0);
});

t.test('high command sees the Catalogs tab, and XP Ranks is a section inside it (plan item G)', async () => {
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:xpTiersList': () => ({ ok: true, tiers: FOUR_RANK_LADDER }),
        })),
    });
    await openTablet(h);
    openSettingsSection(h.getRoot(), 'Catalogs');
    t.equals(findByText(h.getRoot(), 'Catalogs').length, 1, 'one Catalogs section, not three separate screens');
});

// ======================================================================
// LADDER RENDERING
// ======================================================================

t.test('DYNAMIC LADDER: ranks rendered come ENTIRELY from tablet:xpTiersList -- an invented label appearing nowhere in tablet.js source renders correctly', async () => {
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:xpTiersList': () => ({ ok: true, tiers: FOUR_RANK_LADDER }),
        })),
    });
    await openTablet(h);
    openXpTiersTab(h);
    await settle();

    t.isTrue(findByText(h.getRoot(), 'Zzyzx Apex K9').length >= 1, 'a label this test invented on the fly renders correctly -- proves no hardcoded ladder');
    t.isTrue(findByText(h.getRoot(), '1250').length >= 1, 'rank 2\'s xp threshold is shown');
    t.isTrue(findByText(h.getRoot(), '4000').length >= 1, 'rank 3\'s xp threshold is shown');
    t.isTrue(findByText(h.getRoot(), 'APEX').length >= 1, 'rank 4\'s optional badge is shown');
});

t.test('loading state renders before the first tablet:xpTiersList resolves -- never a blank screen', async () => {
    let resolveList;
    const h = createHarness({
        // A raw fetchImpl (not routeFetch's own auto-jsonResponse wrapper)
        // so the underlying fetch() call itself -- not just its resolved
        // body -- stays pending until resolveList() is invoked below.
        fetchImpl: (url) => {
            const name = url.split('/').pop();
            if (name === 'tablet:requestMyRecord') {
                return Promise.resolve(jsonResponse({ ok: true, viewer: HIGH_COMMAND_VIEWER, certifications: [], xp: null, tierLabel: null, myFeatures: [] }));
            }
            if (name === 'tablet:getTheme') {
                return Promise.resolve(jsonResponse({ ok: true, theme: { primaryColor: '#2563eb', accentColor: '#f59e0b', backgroundColor: '#111827', textColor: '#f9fafb', density: 'comfortable', headerTitle: 'K9 Command Tablet' } }));
            }
            if (name === 'tablet:xpTiersList') {
                return new Promise((resolve) => { resolveList = () => resolve(jsonResponse({ ok: true, tiers: FOUR_RANK_LADDER })); });
            }
            return Promise.reject(new Error('tablet_xp_tiers_spec: unhandled NUI callback ' + name));
        },
    });
    await openTablet(h);
    openXpTiersTab(h);
    await settle();

    t.isTrue(findByText(h.getRoot(), 'Loading...').length >= 1, 'a loading state is shown while the request is in flight');
    resolveList();
    await settle(4);
    t.isTrue(findByText(h.getRoot(), 'Recruit K9').length >= 1, 'the real ladder renders once the request resolves');
});

t.test('an empty ladder shows its own empty-state note, not a crash', async () => {
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:xpTiersList': () => ({ ok: true, tiers: [] }),
        })),
    });
    await openTablet(h);
    openXpTiersTab(h);
    await settle();

    t.isTrue(findByText(h.getRoot(), 'No XP ranks are configured.').length >= 1);
});

t.test('a load failure shows the error and a Retry button that re-fetches', async () => {
    let calls = 0;
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:xpTiersList': () => {
                calls++;
                return calls === 1 ? { ok: false, error: 'denied' } : { ok: true, tiers: FOUR_RANK_LADDER };
            },
        })),
    });
    await openTablet(h);
    openXpTiersTab(h);
    await settle();

    t.isTrue(findByText(h.getRoot(), 'You are not authorized to edit XP ranks.').length >= 1);
    findByText(h.getRoot(), 'Retry')[0].click();
    await settle();
    t.isTrue(findByText(h.getRoot(), 'Recruit K9').length >= 1);
    t.equals(calls, 2);
});

// ======================================================================
// RANK 1'S XP FIELD IS GENUINELY READ-ONLY
// ======================================================================

t.test('Rank 1 (xpLocked): the XP input is disabled, and typing into it has NO effect on what is submitted -- always 0', async () => {
    let upsertBody = null;
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:xpTiersList': () => ({ ok: true, tiers: FOUR_RANK_LADDER }),
            'tablet:xpTiersUpsert': (body) => { upsertBody = body; return { ok: true, tiers: FOUR_RANK_LADDER }; },
        })),
    });
    await openTablet(h);
    openXpTiersTab(h);
    await settle();

    const editButtons = findByText(h.getRoot(), 'Edit');
    t.equals(editButtons.length, 4);
    editButtons[0].click(); // rank 1's own row
    await settle();

    const xpInput = findInput(h.getRoot(), (n) => n.value === '0');
    t.isDefined(xpInput, 'the xp input pre-fills from the live value (0)');
    t.equals(xpInput.getAttribute('disabled'), 'disabled', 'genuinely read-only, not merely styled to look that way');

    // Attempt the disallowed interaction anyway -- a bypassed/scripted
    // client could still call .typeValue() on this same element; since no
    // 'input' listener was ever attached for a locked field, this has NO
    // effect on the working copy that Save actually reads.
    xpInput.typeValue('999999');

    findByText(h.getRoot(), 'Save Rank')[0].click();
    await new Promise((r) => setTimeout(r, 30));

    t.equals(upsertBody.ordinal, 1);
    t.equals(upsertBody.xp, 0, 'rank 1 always submits xp=0 regardless of any attempted edit to the disabled field');
});

t.test('Rank 1: label and multipliers remain fully editable -- only the XP threshold is fixed', async () => {
    let upsertBody = null;
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:xpTiersList': () => ({ ok: true, tiers: FOUR_RANK_LADDER }),
            'tablet:xpTiersUpsert': (body) => { upsertBody = body; return { ok: true, tiers: FOUR_RANK_LADDER }; },
        })),
    });
    await openTablet(h);
    openXpTiersTab(h);
    await settle();

    findByText(h.getRoot(), 'Edit')[0].click();
    await settle();

    const labelInput = findInput(h.getRoot(), (n) => n.value === 'Recruit K9');
    t.isDefined(labelInput);
    t.isNull(labelInput.getAttribute('disabled'), 'label stays editable for the locked rank');
    labelInput.typeValue('New Recruit K9');

    findByText(h.getRoot(), 'Save Rank')[0].click();
    await new Promise((r) => setTimeout(r, 30));

    t.equals(upsertBody.label, 'New Recruit K9');
    t.equals(upsertBody.xp, 0);
});

// ======================================================================
// EDIT + SAVE -- non-locked rank, optional-field contract
// ======================================================================

t.test('Edit on a non-locked rank pre-fills every field; Save sends the full payload, OMITTING optional fields left blank', async () => {
    let upsertBody = null;
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:xpTiersList': () => ({ ok: true, tiers: FOUR_RANK_LADDER }),
            'tablet:xpTiersUpsert': (body) => { upsertBody = body; return { ok: true, tiers: FOUR_RANK_LADDER }; },
        })),
    });
    await openTablet(h);
    openXpTiersTab(h);
    await settle();

    // Rank 2 -- no medkitCooldownMultiplier/badge configured.
    findByText(h.getRoot(), 'Edit')[1].click();
    await settle();

    const xpInput = findInput(h.getRoot(), (n) => n.value === '1250');
    t.isDefined(xpInput);
    t.isNull(xpInput.getAttribute('disabled'), 'not locked -- rank 2 is a normal editable rank');
    xpInput.typeValue('1500');

    findByText(h.getRoot(), 'Save Rank')[0].click();
    await new Promise((r) => setTimeout(r, 30));

    t.equals(upsertBody.ordinal, 2);
    t.equals(upsertBody.xp, 1500);
    t.equals(upsertBody.label, 'Trained K9');
    t.equals(upsertBody.speedMultiplier, 1.05);
    t.equals(upsertBody.scentRangeMultiplier, 1.1);
    t.isFalse(Object.prototype.hasOwnProperty.call(upsertBody, 'medkitCooldownMultiplier'), 'left blank -- omitted entirely, never sent as null/0');
    t.isFalse(Object.prototype.hasOwnProperty.call(upsertBody, 'badge'), 'left blank -- omitted entirely');
});

t.test('Edit on a rank that already has optional fields set: badge/medkitCooldownMultiplier pre-fill and round-trip unchanged if left alone', async () => {
    let upsertBody = null;
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:xpTiersList': () => ({ ok: true, tiers: FOUR_RANK_LADDER }),
            'tablet:xpTiersUpsert': (body) => { upsertBody = body; return { ok: true, tiers: FOUR_RANK_LADDER }; },
        })),
    });
    await openTablet(h);
    openXpTiersTab(h);
    await settle();

    // Rank 4 -- badge already 'APEX'.
    findByText(h.getRoot(), 'Edit')[3].click();
    await settle();

    const badgeInput = findInput(h.getRoot(), (n) => n.value === 'APEX');
    t.isDefined(badgeInput, 'badge pre-fills from the live value');

    findByText(h.getRoot(), 'Save Rank')[0].click();
    await new Promise((r) => setTimeout(r, 30));

    t.equals(upsertBody.badge, 'APEX');
});

t.test('Cancel discards the edit without saving', async () => {
    let upsertCalled = false;
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:xpTiersList': () => ({ ok: true, tiers: FOUR_RANK_LADDER }),
            'tablet:xpTiersUpsert': () => { upsertCalled = true; return { ok: true, tiers: FOUR_RANK_LADDER }; },
        })),
    });
    await openTablet(h);
    openXpTiersTab(h);
    await settle();

    findByText(h.getRoot(), 'Edit')[1].click();
    await settle();
    findByText(h.getRoot(), 'Cancel')[0].click();
    await settle();

    t.isFalse(upsertCalled);
    t.equals(findByText(h.getRoot(), 'Save Rank').length, 0, 'the draft form is gone');
});

// ======================================================================
// CLIENT-SIDE PRE-CHECKS -- mirror the server's own rules, never the only gate
// ======================================================================

t.test('an out-of-range speed multiplier is rejected client-side, with NO server round trip', async () => {
    let upsertCalled = false;
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:xpTiersList': () => ({ ok: true, tiers: FOUR_RANK_LADDER }),
            'tablet:xpTiersUpsert': () => { upsertCalled = true; return { ok: true, tiers: FOUR_RANK_LADDER }; },
        })),
    });
    await openTablet(h);
    openXpTiersTab(h);
    await settle();

    findByText(h.getRoot(), 'Edit')[1].click();
    await settle();
    const speedInput = findInput(h.getRoot(), (n) => n.value === '1.05');
    speedInput.typeValue('99');
    findByText(h.getRoot(), 'Save Rank')[0].click();
    await new Promise((r) => setTimeout(r, 30));

    t.isFalse(upsertCalled, 'never reaches the server -- caught client-side first');
    t.isTrue(findByText(h.getRoot(), 'Speed multiplier must be greater than 0 and no more than 3.').length >= 1);
});

t.test('a non-integer XP threshold on a non-locked rank is rejected client-side, with NO server round trip', async () => {
    let upsertCalled = false;
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:xpTiersList': () => ({ ok: true, tiers: FOUR_RANK_LADDER }),
            'tablet:xpTiersUpsert': () => { upsertCalled = true; return { ok: true, tiers: FOUR_RANK_LADDER }; },
        })),
    });
    await openTablet(h);
    openXpTiersTab(h);
    await settle();

    findByText(h.getRoot(), 'Edit')[1].click();
    await settle();
    const xpInput = findInput(h.getRoot(), (n) => n.value === '1250');
    xpInput.typeValue('1250.5');
    findByText(h.getRoot(), 'Save Rank')[0].click();
    await new Promise((r) => setTimeout(r, 30));

    t.isFalse(upsertCalled);
    t.isTrue(findByText(h.getRoot(), 'XP threshold must be a whole number of 0 or more.').length >= 1);
});

t.test('an edit that would invert the ladder against the LAST KNOWN live thresholds is rejected client-side, with NO server round trip', async () => {
    let upsertCalled = false;
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:xpTiersList': () => ({ ok: true, tiers: FOUR_RANK_LADDER }),
            'tablet:xpTiersUpsert': () => { upsertCalled = true; return { ok: true, tiers: FOUR_RANK_LADDER }; },
        })),
    });
    await openTablet(h);
    openXpTiersTab(h);
    await settle();

    // Rank 2 (currently 1250) raised above rank 3's own live 4000 -- would invert.
    findByText(h.getRoot(), 'Edit')[1].click();
    await settle();
    const xpInput = findInput(h.getRoot(), (n) => n.value === '1250');
    xpInput.typeValue('5000');
    findByText(h.getRoot(), 'Save Rank')[0].click();
    await new Promise((r) => setTimeout(r, 30));

    t.isFalse(upsertCalled);
    t.isTrue(findByText(h.getRoot(), 'That XP threshold would put this rank out of order with the rank above or below it.').length >= 1);
});

// ======================================================================
// SERVER REFUSALS -- each of the 12 documented reasons renders its OWN message
// ======================================================================

const FAILURE_REASON_TEXT = {
    denied: 'You are not authorized to edit XP ranks.',
    rate_limited: 'Please wait a moment before trying again.',
    busy: 'Another XP rank edit is in progress -- try again in a moment.',
    invalid_ordinal: 'That rank could not be found.',
    invalid_xp: 'XP threshold must be a whole number of 0 or more.',
    base_tier_xp_fixed: 'Rank 1 must always start at 0 XP -- this field cannot be changed.',
    invalid_label: 'Enter a valid label (1-60 characters, no special symbols).',
    invalid_speed_multiplier: 'Speed multiplier must be greater than 0 and no more than 3.',
    invalid_scent_range_multiplier: 'Scent range multiplier must be greater than 0 and no more than 3.',
    invalid_medkit_cooldown_multiplier: 'Medkit cooldown multiplier must be greater than 0 and no more than 1, or left blank.',
    invalid_badge: 'Enter a valid badge (up to 30 characters, no special symbols) or leave it blank.',
    invalid_order: 'That XP threshold would put this rank out of order with the rank above or below it.',
    db_error: 'The rank could not be saved due to a database error. Try again.',
};

for (const [reason, expectedText] of Object.entries(FAILURE_REASON_TEXT)) {
    t.test(`server refusal '${reason}' renders its own distinct message, inline on the edited rank's row`, async () => {
        const h = createHarness({
            fetchImpl: routeFetch(baseHandlers({
                'tablet:xpTiersList': () => ({ ok: true, tiers: FOUR_RANK_LADDER }),
                'tablet:xpTiersUpsert': () => ({ ok: false, error: reason }),
            })),
        });
        await openTablet(h);
        openXpTiersTab(h);
        await settle();

        // Rank 3 -- a normal, non-locked rank every reason above can plausibly apply to.
        findByText(h.getRoot(), 'Edit')[2].click();
        await settle();
        findByText(h.getRoot(), 'Save Rank')[0].click();
        await new Promise((r) => setTimeout(r, 30));

        const matches = findByText(h.getRoot(), expectedText);
        t.isTrue(matches.length >= 1, `expected distinct text for '${reason}' to render, got none. Full text list present: ` + JSON.stringify(findAll(h.getRoot(), (n) => n.tagName === 'p').map((n) => n._textContent)));
    });
}

t.test('every failure reason above renders a DIFFERENT message from every other -- no two reasons collapse to the same generic text', () => {
    const texts = Object.values(FAILURE_REASON_TEXT);
    const unique = new Set(texts);
    t.equals(unique.size, texts.length, 'every documented failure reason must have its own distinct copy');
});

// ======================================================================
// THE ALREADY-PROMOTED PLAYER -- the demotion warning is shown PROMINENTLY
// ======================================================================

t.test('a successful save carrying a demotion `warning` renders it as its OWN prominent banner, not folded into the generic notice', async () => {
    const WARNING_TEXT = 'This change immediately RE-RANKS every currently-connected K9 against the new thresholds. 2 currently-connected K9(s) just moved to a LOWER rank as a direct result of this edit.';
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:xpTiersList': () => ({ ok: true, tiers: FOUR_RANK_LADDER }),
            'tablet:xpTiersUpsert': () => ({ ok: true, tiers: FOUR_RANK_LADDER, warning: WARNING_TEXT }),
        })),
    });
    await openTablet(h);
    openXpTiersTab(h);
    await settle();

    findByText(h.getRoot(), 'Edit')[2].click();
    await settle();
    findByText(h.getRoot(), 'Save Rank')[0].click();
    await new Promise((r) => setTimeout(r, 30));

    const warningNodes = findAll(h.getRoot(), (n) => n.classList && n.classList.contains('k9tablet-warning-note'));
    t.isTrue(warningNodes.some((n) => n._textContent === WARNING_TEXT), 'the warning renders in its own dedicated banner element, using the exact server-provided text');
});

t.test('a successful save carrying NO `warning` shows no warning banner at all', async () => {
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:xpTiersList': () => ({ ok: true, tiers: FOUR_RANK_LADDER }),
            'tablet:xpTiersUpsert': () => ({ ok: true, tiers: FOUR_RANK_LADDER }),
        })),
    });
    await openTablet(h);
    openXpTiersTab(h);
    await settle();

    findByText(h.getRoot(), 'Edit')[2].click();
    await settle();
    findByText(h.getRoot(), 'Save Rank')[0].click();
    await new Promise((r) => setTimeout(r, 30));

    const warningNodes = findAll(h.getRoot(), (n) => n.classList && n.classList.contains('k9tablet-warning-note'));
    t.equals(warningNodes.length, 0);
});

t.test('a stale warning from a PREVIOUS visit is cleared when the tab is freshly re-entered', async () => {
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:xpTiersList': () => ({ ok: true, tiers: FOUR_RANK_LADDER }),
            'tablet:xpTiersUpsert': () => ({ ok: true, tiers: FOUR_RANK_LADDER, warning: 'Some rank(s) were just demoted.' }),
        })),
    });
    await openTablet(h);
    openXpTiersTab(h);
    await settle();

    findByText(h.getRoot(), 'Edit')[2].click();
    await settle();
    findByText(h.getRoot(), 'Save Rank')[0].click();
    await new Promise((r) => setTimeout(r, 30));
    t.isTrue(findByText(h.getRoot(), 'Some rank(s) were just demoted.').length >= 1);

    // Re-entering the SAME tab (its own onClick handler resets
    // xpTierWarning unconditionally, same reset discipline every other
    // admin tab on this page already applies to its own leftover state)
    // clears the stale banner -- deliberately not routed through the
    // Console screen, which has its own unrelated NUI callbacks this spec
    // does not stub.
    openXpTiersTab(h);
    await settle();

    t.equals(findByText(h.getRoot(), 'Some rank(s) were just demoted.').length, 0, 'a fresh tab entry resets the leftover warning from the previous visit');
});

t.run();
