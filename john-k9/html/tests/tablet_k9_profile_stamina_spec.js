/*
    html/tests/tablet_k9_profile_stamina_spec.js

    Owner-directed, verbatim: "Keep the speed and stamina editing where i
    can edit it to as high as i want and be able to make the stamina as
    high as i want or permanant" / "also edit it where high command can
    have control over how far there scent range is to" / "for high
    command those should be editable on everyone".

    Covers html/tablet.js's K9 individual-override editor
    (server/k9profiles.lua) against the FIVE explicit requirements:
      1. High command only -- no control renders at all for anyone else.
      2. No client-side ceiling re-imposed on speed/scent (the removed
         hardcoded 3.0).
      3. Stamina has a real "never runs out" affordance (a checkbox, not
         a magic number), and round-trips as 0, not coerced/dropped.
      4. Session-only stamina persistence warning is surfaced, not hidden.
      5. Reset actually clears an override (round-trips to "not
         overridden"/tier default).
    Also covers the Person screen embed (buildPersonK9ProfileSection())
    reusing the SAME editor, and the subtle speed-clamp disclosure note.
*/
'use strict';

const t = require('./testkit');
const { createHarness, jsonResponse } = require('./tablet-sandbox');
const { findByText, findByTag, findAll, findByClass } = require('./tablet-dom-stub');

/** findByText() only matches an EXACT textContent string -- several
 * assertions below check for a SUBSTRING within a longer, concatenated
 * sentence (same helper tablet_console_spec.js already established). */
function findByTextContaining(node, substring) {
    return findAll(node, (n) => typeof n._textContent === 'string' && n._textContent.indexOf(substring) !== -1);
}

/**
 * ROUTE CHANGED, NOT THE CAPABILITY (plan item D). Per-dog overrides used
 * to have a tab of their own, with its own citizen-ID lookup box. The
 * editor was always the Person screen's (buildPersonK9ProfileSection); the
 * tab added a duplicate lookup and a second copy of the same panel. The tab
 * is gone, its list of who-holds-an-override moved to the Command Console,
 * and the editor is reached the way everything else about a person is: open
 * the person.
 *
 * So every test below still exercises the identical editor and the
 * identical callbacks -- only the two clicks that get there changed.
 */
const PERSON_ROUTE_DEFAULTS = {
    'tablet:requestRoster': () => ({ ok: true, rows: [], truncated: false }),
    'tablet:requestOnlinePlayers': () => ({ ok: true, rows: [], truncated: false }),
    'tablet:k9ProfilesList': () => ({ ok: true, overrides: [] }),
    'tablet:requestPersonSummary': (body) => ({ ok: true, target: { citizenid: body.targetCitizenId, name: body.targetCitizenId }, certifications: [], xp: 0, tierLabel: null, permissions: [], partnership: null }),
    'tablet:requestPersonFeatures': () => ({ ok: true, target: { citizenid: 'DOG1', name: 'DOG1' }, features: [] }),
    'tablet:permKeysList': () => ({ ok: true, keys: [] }),
    'tablet:certTiersList': () => ({ ok: true, tiers: [] }),
    'tablet:rosterList': () => ({ ok: true, k9: [], handlers: [], unassigned: [] }),
    'tablet:requestPartnershipsForTarget': () => ({ ok: false, error: 'not_stubbed' }),
};

function routeFetch(handlers, calls) {
    const merged = Object.assign({}, PERSON_ROUTE_DEFAULTS, handlers);
    return function (url, init) {
        const name = url.split('/').pop();
        const body = init && init.body ? JSON.parse(init.body) : undefined;
        if (calls) calls.push({ name: name, body: body });
        const h = merged[name];
        if (!h) return Promise.reject(new Error('tablet_k9_profile_stamina_spec: unhandled NUI callback ' + name));
        return Promise.resolve(jsonResponse(h(body)));
    };
}

async function settle(times) {
    for (let i = 0; i < (times || 3); i++) await new Promise((r) => setImmediate(r));
}

const HC_VIEWER = { citizenid: 'HC1', name: 'Chief', isHighCommand: true, effectivePermissions: ['k9.access', 'k9.certify', 'k9.audit', 'k9.givexp'], allowSelfGrant: false };
const ORDINARY_VIEWER = { citizenid: 'OFFICER1', name: 'Officer', isHighCommand: false, effectivePermissions: ['k9.access'], allowSelfGrant: false };

/** The Console's "open by exact citizen ID" box -- the one person-finder
 * this tablet keeps, and the route to the override editor now that the K9
 * Overrides tab and its duplicate lookup are gone. */
function lookupInput(h) {
    return findByTag(h.getRoot(), 'input').filter((i) => i.getAttribute('placeholder') === 'Name, citizen ID or server ID...')[0];
}

/**
 * The override editor's own number fields, in DOM order.
 *
 * SCOPED BY CLASS, not "every number input on screen" -- and that is the
 * whole point of the change, not an inconvenience from it. The editor now
 * renders on the PERSON screen, which also carries the Give XP control (a
 * number input) and the capability list (checkboxes). A bare
 * "first number input" or "first checkbox" lookup would silently grab one
 * of those and the test would pass or fail for entirely the wrong reason.
 */
function overrideNumberInputs(h) {
    return findByTag(h.getRoot(), 'input').filter((i) =>
        i.getAttribute('type') === 'number' && i.getAttribute('step') === 'any');
}

/** The override editor's "Never runs out (permanent)" checkbox -- NOT one of
 * the Person screen's capability checkboxes, which carry their own class. */
function permanentStaminaCheckbox(h) {
    return findByTag(h.getRoot(), 'input').filter((i) =>
        i.getAttribute('type') === 'checkbox'
        && !(i.classList && i.classList.contains('k9tablet-capability-checkbox')))[0];
}

async function openK9OverridesTab(h) {
    h.postMessage('tablet:open', {});
    await settle();
    findByText(h.getRoot(), 'Command Console')[0].click();
    await settle(4);
}

t.test('a NON-high-command viewer gets NO K9 Overrides control rendered at all -- not merely hidden, never constructed', async () => {
    const h = createHarness({
        fetchImpl: routeFetch({
            'tablet:requestMyRecord': () => ({ ok: true, viewer: ORDINARY_VIEWER, certifications: [], xp: null, tierLabel: null, myFeatures: [] }),
        }),
    });
    h.postMessage('tablet:open', {});
    await settle();
    t.equals(findByText(h.getRoot(), 'K9 Overrides').length, 0, 'no such tab exists for anyone any more (plan item D) -- and certainly not for this viewer');
});

t.test('a NON-high-command viewer\'s own Person screen (reached via k9.certify) never shows the K9 Individual Override section either -- the server re-verifies regardless, but this page must not offer a control that will only error', async () => {
    const h = createHarness({
        fetchImpl: routeFetch({
            'tablet:requestMyRecord': () => ({ ok: true, viewer: { citizenid: 'DELEGATE1', name: 'Delegate', isHighCommand: false, effectivePermissions: ['k9.certify', 'k9.audit'], allowSelfGrant: false }, certifications: [], xp: null, tierLabel: null, myFeatures: [] }),
            'tablet:requestRoster': () => ({ ok: true, rows: [{ citizenid: 'TARGET1', name: 'K9 Rex', departmentLabel: 'Police', certified: true, xp: 0, tierLabel: null }], truncated: false }),
            'tablet:requestOnlinePlayers': () => ({ ok: true, rows: [], truncated: false }),
            'tablet:requestPersonSummary': () => ({ ok: true, target: { citizenid: 'TARGET1', name: 'K9 Rex' }, certifications: [], xp: 0, tierLabel: null, permissions: [] }),
        }),
    });
    h.postMessage('tablet:open', {});
    await settle();
    findByText(h.getRoot(), 'Manage')[0].click();
    await settle();
    t.equals(findByText(h.getRoot(), 'K9 Individual Override').length, 0, 'not rendered for a non-high-command viewer, even one with real console access');
});

t.test('NO CLIENT-SIDE CEILING: a speed multiplier far above the old hardcoded 3.0 is accepted and sent to the server verbatim, never blocked client-side', async () => {
    const calls = [];
    const h = createHarness({
        fetchImpl: routeFetch({
            'tablet:requestMyRecord': () => ({ ok: true, viewer: HC_VIEWER, certifications: [], xp: null, tierLabel: null, myFeatures: [] }),
            'tablet:requestRoster': () => ({ ok: true, rows: [], truncated: false }),
            'tablet:k9ProfilesList': () => ({ ok: true, overrides: [] }),
            'tablet:k9ProfileGet': () => ({ ok: true, citizenid: 'DOG1', tierLabel: 'Recruit K9', effective: { speedMultiplier: 1, scentRangeMultiplier: 1, medkitCooldownMultiplier: 1, sprintDecayPerTick: 2, overridden: {} }, override: null }),
            'tablet:k9ProfileUpsert': (body) => ({ ok: true, citizenid: body.citizenid, effective: { speedMultiplier: body.speedMultiplier, scentRangeMultiplier: 1, medkitCooldownMultiplier: 1, sprintDecayPerTick: 2, overridden: { speedMultiplier: true } }, override: { speedMultiplier: body.speedMultiplier } }),
        }, calls),
    });
    await openK9OverridesTab(h);

    lookupInput(h).typeValue('DOG1');
    findByText(h.getRoot(), 'Open')[0].click();
    await settle(6);

    const speedInput = overrideNumberInputs(h)[0];
    t.isDefined(speedInput, 'the speed input exists');
    t.isTrue(speedInput.getAttribute('max') === null, 'and has NO max attribute at all');

    speedInput.typeValue('7.5');
    findByText(h.getRoot(), 'Save Override')[0].click();
    await settle();

    const upsertCall = calls.find((c) => c.name === 'tablet:k9ProfileUpsert');
    t.isDefined(upsertCall, 'the save actually fired -- this page never refused it client-side');
    t.equals(upsertCall.body.speedMultiplier, 7.5, 'the value was sent verbatim, not clamped/rejected client-side');
});

t.test('PERMANENT STAMINA: checking "Never runs out" saves sprintDecayPerTick = 0, a real number, never coerced to blank/omitted', async () => {
    const calls = [];
    const h = createHarness({
        fetchImpl: routeFetch({
            'tablet:requestMyRecord': () => ({ ok: true, viewer: HC_VIEWER, certifications: [], xp: null, tierLabel: null, myFeatures: [] }),
            'tablet:requestRoster': () => ({ ok: true, rows: [], truncated: false }),
            'tablet:k9ProfilesList': () => ({ ok: true, overrides: [] }),
            'tablet:k9ProfileGet': () => ({ ok: true, citizenid: 'DOG2', tierLabel: 'Recruit K9', effective: { speedMultiplier: 1, scentRangeMultiplier: 1, medkitCooldownMultiplier: 1, sprintDecayPerTick: 2, overridden: {} }, override: null }),
            'tablet:k9ProfileUpsert': (body) => ({
                ok: true, citizenid: body.citizenid,
                effective: { speedMultiplier: 1, scentRangeMultiplier: 1, medkitCooldownMultiplier: 1, sprintDecayPerTick: body.sprintDecayPerTick, overridden: { sprintDecayPerTick: true } },
                override: { sprintDecayPerTick: body.sprintDecayPerTick },
                staminaPersistenceWarning: 'This K9\'s stamina drain-per-tick is a SESSION-ONLY override -- it is not saved to the database and will reset to the server default the next time this resource restarts.',
            }),
        }, calls),
    });
    await openK9OverridesTab(h);

    lookupInput(h).typeValue('DOG2');
    findByText(h.getRoot(), 'Open')[0].click();
    await settle(6);

    const permanentCheckbox = permanentStaminaCheckbox(h);
    t.isDefined(permanentCheckbox, 'a real checkbox affordance exists for permanent stamina, not just a number field');
    permanentCheckbox.checked = true;
    permanentCheckbox._dispatch('change', { target: permanentCheckbox });
    await settle();

    findByText(h.getRoot(), 'Save Override')[0].click();
    await settle();

    const upsertCall = calls.find((c) => c.name === 'tablet:k9ProfileUpsert');
    t.isDefined(upsertCall);
    t.equals(upsertCall.body.sprintDecayPerTick, 0, 'permanent must round-trip as the real number 0, never blank/omitted/coerced to a string');

    // SESSION-ONLY WARNING -- shown plainly, not hidden.
    t.isTrue(findByText(h.getRoot(), 'This K9\'s stamina drain-per-tick is a SESSION-ONLY override -- it is not saved to the database and will reset to the server default the next time this resource restarts.').length >= 1);
});

t.test('a stamina override already at 0 reopens with the permanent checkbox CHECKED, not shown as a bare "0" the operator has to interpret', async () => {
    const h = createHarness({
        fetchImpl: routeFetch({
            'tablet:requestMyRecord': () => ({ ok: true, viewer: HC_VIEWER, certifications: [], xp: null, tierLabel: null, myFeatures: [] }),
            'tablet:requestRoster': () => ({ ok: true, rows: [], truncated: false }),
            'tablet:k9ProfilesList': () => ({ ok: true, overrides: [] }),
            'tablet:k9ProfileGet': () => ({
                ok: true, citizenid: 'DOG3', tierLabel: 'Recruit K9',
                effective: { speedMultiplier: 1, scentRangeMultiplier: 1, medkitCooldownMultiplier: 1, sprintDecayPerTick: 0, overridden: { sprintDecayPerTick: true } },
                override: { sprintDecayPerTick: 0 },
                staminaPersistenceWarning: 'This K9\'s stamina drain-per-tick is a SESSION-ONLY override -- it is not saved to the database and will reset to the server default the next time this resource restarts.',
            }),
        }),
    });
    await openK9OverridesTab(h);
    lookupInput(h).typeValue('DOG3');
    findByText(h.getRoot(), 'Open')[0].click();
    await settle(6);

    const permanentCheckbox = permanentStaminaCheckbox(h);
    t.isTrue(permanentCheckbox.checked, 'reopening an existing permanent override shows the checkbox already checked');
    t.isTrue(findByTextContaining(h.getRoot(), 'Never runs out (permanent)').length >= 1, 'the effective-value line reads as "permanent" in plain language, not a bare 0');
});

t.test('RESET actually restores default behaviour -- after resetting, the profile reopens with no live override at all', async () => {
    let resetCalled = false;
    let currentOverride = { speedMultiplier: 5, sprintDecayPerTick: 0 };
    const h = createHarness({
        fetchImpl: routeFetch({
            'tablet:requestMyRecord': () => ({ ok: true, viewer: HC_VIEWER, certifications: [], xp: null, tierLabel: null, myFeatures: [] }),
            'tablet:requestRoster': () => ({ ok: true, rows: [], truncated: false }),
            'tablet:k9ProfilesList': () => ({ ok: true, overrides: currentOverride ? [Object.assign({ citizenid: 'DOG4' }, currentOverride)] : [] }),
            'tablet:k9ProfileGet': () => ({
                ok: true, citizenid: 'DOG4', tierLabel: 'Recruit K9',
                effective: { speedMultiplier: currentOverride ? currentOverride.speedMultiplier : 1, scentRangeMultiplier: 1, medkitCooldownMultiplier: 1, sprintDecayPerTick: currentOverride ? currentOverride.sprintDecayPerTick : 2, overridden: { speedMultiplier: !!currentOverride, sprintDecayPerTick: !!currentOverride } },
                override: currentOverride,
            }),
            'tablet:k9ProfileReset': () => {
                resetCalled = true;
                currentOverride = null;
                return { ok: true, citizenid: 'DOG4', effective: { speedMultiplier: 1, scentRangeMultiplier: 1, medkitCooldownMultiplier: 1, sprintDecayPerTick: 2, overridden: {} } };
            },
        }),
    });
    await openK9OverridesTab(h);
    lookupInput(h).typeValue('DOG4');
    findByText(h.getRoot(), 'Open')[0].click();
    await settle(6);

    t.isTrue(findByText(h.getRoot(), 'Reset All Overrides').length >= 1, 'a live override exists, so Reset is offered');
    // Two-click confirm (mkConfirmButton) -- click twice.
    findByText(h.getRoot(), 'Reset All Overrides')[0].click();
    await settle();
    findByText(h.getRoot(), 'Confirm?')[0].click();
    await settle();

    t.isTrue(resetCalled, 'tablet:k9ProfileReset actually fired');
    t.equals(findByText(h.getRoot(), 'Reset All Overrides').length, 0, 'after a real reset, there is no live override left to reset again');
    t.equals(findByTextContaining(h.getRoot(), 'Never runs out (permanent)').length, 0, 'stamina is back to the plain tier default, not still showing permanent');
});

t.test('Person screen: the K9 Individual Override section reuses the SAME editor, auto-loaded for this person\'s own citizenid', async () => {
    const h = createHarness({
        fetchImpl: routeFetch({
            'tablet:requestMyRecord': () => ({ ok: true, viewer: HC_VIEWER, certifications: [], xp: null, tierLabel: null, myFeatures: [] }),
            'tablet:requestRoster': () => ({ ok: true, rows: [{ citizenid: 'TARGET1', name: 'K9 Rex', departmentLabel: 'Police', certified: true, xp: 0, tierLabel: null }], truncated: false }),
            'tablet:requestOnlinePlayers': () => ({ ok: true, rows: [], truncated: false }),
            'tablet:requestPersonSummary': () => ({ ok: true, target: { citizenid: 'TARGET1', name: 'K9 Rex' }, certifications: [], xp: 0, tierLabel: null, permissions: [] }),
            'tablet:requestPersonFeatures': () => ({ ok: true, target: { citizenid: 'TARGET1', name: 'K9 Rex' }, features: [] }),
            'tablet:permKeysList': () => ({ ok: true, keys: [] }),
            'tablet:certTiersList': () => ({ ok: true, tiers: [] }),
            'tablet:k9ProfileGet': (body) => {
                t.equals(body.citizenid, 'TARGET1', 'auto-loaded for the PERSON currently on screen, no separate lookup needed');
                return { ok: true, citizenid: 'TARGET1', tierLabel: 'Recruit K9', effective: { speedMultiplier: 1, scentRangeMultiplier: 1, medkitCooldownMultiplier: 1, sprintDecayPerTick: 2, overridden: {} }, override: null };
            },
        }),
    });
    h.postMessage('tablet:open', {});
    await settle();
    findByText(h.getRoot(), 'Manage')[0].click();
    await settle(4);

    t.isTrue(findByText(h.getRoot(), 'K9 Individual Override').length >= 1);
    t.isTrue(findByText(h.getRoot(), 'Sprint Speed Multiplier').length >= 1, 'the SAME editable fields render here, not a read-only summary');
    t.equals(findByText(h.getRoot(), 'Close').length, 0, 'no dead-end "Close" button in this embedded context');
});

t.test('NO CLIENT-SIDE CEILING FOR STAMINA EITHER (post migration 0021: the server\'s own ceiling is now owner-editable via Config.MaxStaminaDrainPerTick, unknown to this page): a stamina drain rate far above the old hardcoded 20.0 is accepted and sent to the server verbatim, never blocked client-side', async () => {
    const calls = [];
    const h = createHarness({
        fetchImpl: routeFetch({
            'tablet:requestMyRecord': () => ({ ok: true, viewer: HC_VIEWER, certifications: [], xp: null, tierLabel: null, myFeatures: [] }),
            'tablet:requestRoster': () => ({ ok: true, rows: [], truncated: false }),
            'tablet:k9ProfilesList': () => ({ ok: true, overrides: [] }),
            'tablet:k9ProfileGet': () => ({ ok: true, citizenid: 'DOG5', tierLabel: 'Recruit K9', effective: { speedMultiplier: 1, scentRangeMultiplier: 1, medkitCooldownMultiplier: 1, sprintDecayPerTick: 2, overridden: {} }, override: null }),
            'tablet:k9ProfileUpsert': (body) => ({ ok: true, citizenid: body.citizenid, effective: { speedMultiplier: 1, scentRangeMultiplier: 1, medkitCooldownMultiplier: 1, sprintDecayPerTick: body.sprintDecayPerTick, overridden: { sprintDecayPerTick: true } }, override: { sprintDecayPerTick: body.sprintDecayPerTick } }),
        }, calls),
    });
    await openK9OverridesTab(h);

    lookupInput(h).typeValue('DOG5');
    findByText(h.getRoot(), 'Open')[0].click();
    await settle(6);

    // Speed, scent and stamina all now lack a `max` attribute; medkit
    // keeps its real 1.0 ceiling (`max: '1'`). Stamina is the LAST such
    // input in DOM order (appended after speed/scent/medkit).
    const noMaxNumberInputs = overrideNumberInputs(h).filter((i) => i.getAttribute('max') === null);
    const staminaInput = noMaxNumberInputs[noMaxNumberInputs.length - 1];
    t.isDefined(staminaInput, 'the stamina input has NO max attribute at all');

    staminaInput.typeValue('500');
    findByText(h.getRoot(), 'Save Override')[0].click();
    await settle();

    const upsertCall = calls.find((c) => c.name === 'tablet:k9ProfileUpsert');
    t.isDefined(upsertCall, 'the save actually fired -- this page never refused it client-side');
    t.equals(upsertCall.body.sprintDecayPerTick, 500, 'the value was sent verbatim, not clamped/rejected client-side');
});

t.test('STAMINA PERSISTENCE WARNING IS CONDITIONAL (post migration 0021, commit c938c42): on a DB-backed server the response omits staminaPersistenceWarning entirely, and this page renders NO warning note at all -- it never fabricates one client-side', async () => {
    const h = createHarness({
        fetchImpl: routeFetch({
            'tablet:requestMyRecord': () => ({ ok: true, viewer: HC_VIEWER, certifications: [], xp: null, tierLabel: null, myFeatures: [] }),
            'tablet:requestRoster': () => ({ ok: true, rows: [], truncated: false }),
            'tablet:k9ProfilesList': () => ({ ok: true, overrides: [] }),
            'tablet:k9ProfileGet': () => ({
                ok: true, citizenid: 'DOG6', tierLabel: 'Recruit K9',
                effective: { speedMultiplier: 1, scentRangeMultiplier: 1, medkitCooldownMultiplier: 1, sprintDecayPerTick: 9, overridden: { sprintDecayPerTick: true } },
                override: { sprintDecayPerTick: 9 },
                // NOTE: no staminaPersistenceWarning key at all -- this is
                // exactly what server/k9profiles.lua's own
                // ResolveStaminaPersistenceWarning() returns (nil) on any
                // DB-backed server, now that stamina is persisted exactly
                // like speed/scent/medkit.
            }),
        }),
    });
    await openK9OverridesTab(h);
    lookupInput(h).typeValue('DOG6');
    findByText(h.getRoot(), 'Open')[0].click();
    await settle(6);

    t.equals(findByClass(h.getRoot(), 'k9tablet-warning-note').length, 0, 'no .k9tablet-warning-note element is rendered when the server omits staminaPersistenceWarning');
});

// ======================================================================
// SPEED-OVERRIDE CEILING NOTE (2026-08-31)
//
// server/k9profiles.lua computes `speedOverrideCeilingNote` on k9ProfileGet
// for one stated purpose, in its own comment's words: so an officer opening
// the tablet to INSPECT an already-set high override "gets told the same
// honest truth a fresh save would have told them, not just silence."
// No renderer read the field, so silence is exactly what they got -- the
// one outcome the server went out of its way to prevent.
// ======================================================================

t.test('INSPECTING an already-set high speed override shows the server\'s ceiling note, not silence', async () => {
    const NOTE = 'This K9 is set to 6.00x speed. There is no hard ceiling, but values this far above 1.00x are visibly unnatural and can outrun vehicles.';
    const h = createHarness({
        fetchImpl: routeFetch({
            'tablet:requestMyRecord': () => ({ ok: true, viewer: HC_VIEWER, certifications: [], xp: null, tierLabel: null, myFeatures: [] }),
            'tablet:requestRoster': () => ({ ok: true, rows: [], truncated: false }),
            'tablet:k9ProfilesList': () => ({ ok: true, overrides: [] }),
            'tablet:k9ProfileGet': () => ({
                ok: true, citizenid: 'DOG9', tierLabel: 'Recruit K9',
                effective: { speedMultiplier: 6, scentRangeMultiplier: 1, medkitCooldownMultiplier: 1, overridden: { speedMultiplier: true } },
                override: { speedMultiplier: 6 },
                speedOverrideCeilingNote: NOTE,
            }),
        }),
    });
    await openK9OverridesTab(h);
    lookupInput(h).typeValue('DOG9');
    findByText(h.getRoot(), 'Open')[0].click();
    await settle(6);

    t.isTrue(findByText(h.getRoot(), NOTE).length > 0,
        "the server owns this wording verbatim and computes it precisely so an inspecting officer is not met with silence");
});

t.test('CONTROL: a profile with no ceiling note renders no ceiling note (and never the string "undefined")', async () => {
    const h = createHarness({
        fetchImpl: routeFetch({
            'tablet:requestMyRecord': () => ({ ok: true, viewer: HC_VIEWER, certifications: [], xp: null, tierLabel: null, myFeatures: [] }),
            'tablet:requestRoster': () => ({ ok: true, rows: [], truncated: false }),
            'tablet:k9ProfilesList': () => ({ ok: true, overrides: [] }),
            'tablet:k9ProfileGet': () => ({
                ok: true, citizenid: 'DOG1', tierLabel: 'Recruit K9',
                effective: { speedMultiplier: 1, scentRangeMultiplier: 1, medkitCooldownMultiplier: 1, overridden: {} },
                override: null,
                // no speedOverrideCeilingNote key at all -- the ordinary case
            }),
        }),
    });
    await openK9OverridesTab(h);
    lookupInput(h).typeValue('DOG1');
    findByText(h.getRoot(), 'Open')[0].click();
    await settle(6);

    t.equals(findByText(h.getRoot(), 'undefined').length, 0,
        'an omitted note must render nothing at all, never a placeholder');
});

t.run();
