/*
    html/tests/tablet_mutation_error_spec.js

    Regression coverage for this pass's state-handling/error-reporting
    consistency sweep, scoped to the Person (Command Console "Manage") and
    Home screens -- the two places found to still be collapsing distinct
    server refusal reasons into one generic line, and showing a stale copy
    of the viewer's own record after a self-targeted action:

      1. runMutation()'s new mutationErrorText() -- every certify/permission
         refusal reason the server can actually return (confirmed against
         server/certifications/'s GrantCertificationForTablet/
         GrantCertificationOffline and server/permissions.lua's
         GrantPermission/RevokePermission doc comments) now renders its own
         distinct sentence, never the generic "Action failed." this page
         used to show for all of them. Mirrors this suite's own existing
         convention for the SAME kind of check on the Shop Items/XP Tiers
         screens (see tablet_shop_items_spec.js/tablet_xp_tiers_spec.js).
      2. The Home tab now re-fetches tablet:requestMyRecord on every click,
         consistent with every other data-driven tab (My Record, Console,
         Theme, ...) already doing so -- it used to be the one exception.
      3. A self-targeted Person-screen mutation (the acting officer opening
         THEIR OWN citizenid via the Console -- a real, config-permitted
         flow for self-certification/self-XP-grant) now ALSO refreshes
         state.myRecord, so Home/My Record never keep showing a stale copy
         of the SAME underlying data until the viewer happens to click one
         of those two tabs directly.
      4. tablet:decertify answers from a real server callback, like
         tablet:certify, so its success notice is the same confirmed
         "Done." -- there is no weaker "submitted" state left to show.
*/
'use strict';

const t = require('./testkit');
const { createHarness, jsonResponse } = require('./tablet-sandbox');
const { findByText } = require('./tablet-dom-stub');

// Mirrors html/tablet.js's own DEFAULT_STRINGS.action_failed (kept in sync
// with locales/en.json's tablet.action_failed -- see that key's own doc
// comment / the three-way contract tests/tabletlocalization_spec.lua
// enforces). None of these tests ever supply a `strings` payload on
// `tablet:open`, so S('action_failed') always falls through to this exact
// DEFAULT_STRINGS value -- hardcoded here, not derived, matching this
// file's own established convention of spelling out every other expected
// sentence (CERTIFY_REASON_TEXT below) literally rather than importing it.
const GENERIC_ACTION_FAILED_TEXT = 'Action failed — try again, and if it keeps happening, tell an admin.';

function routeFetch(handlers) {
    return function (url, init) {
        const name = url.split('/').pop();
        const body = init && init.body ? JSON.parse(init.body) : undefined;
        const h = handlers[name];
        if (!h) return Promise.reject(new Error('tablet_mutation_error_spec: unhandled NUI callback ' + name));
        return Promise.resolve(jsonResponse(h(body)));
    };
}

async function settle(times) {
    for (let i = 0; i < (times || 2); i++) await new Promise((r) => setImmediate(r));
}

const HIGH_COMMAND_VIEWER = (citizenid, allowSelfGrant) => ({
    citizenid: citizenid || 'HC1', name: 'Chief', isHighCommand: true,
    effectivePermissions: ['k9.access', 'k9.certify', 'k9.audit', 'k9.givexp'],
    allowSelfGrant: allowSelfGrant === true,
});

function baseHandlers(overrides) {
    return Object.assign({
        'tablet:requestMyRecord': () => ({ ok: true, viewer: HIGH_COMMAND_VIEWER(), certifications: [], xp: null, tierLabel: null, myFeatures: [] }),
        'tablet:requestRoster': () => ({ ok: true, rows: [{ citizenid: 'TARGET1', name: 'K9 Rex', departmentLabel: 'Police', certified: false, xp: 0, tierLabel: null }], truncated: false }),
        'tablet:requestPersonSummary': () => ({
            ok: true,
            target: { citizenid: 'TARGET1', name: 'K9 Rex' },
            certifications: [{ departmentKey: 'police', departmentLabel: 'Los Santos Police Department', active: false, grantedBy: null }],
            xp: 0, tierLabel: null, permissions: [],
        }),
    }, overrides || {});
}

async function openPersonScreen(h) {
    h.postMessage('tablet:open', {});
    await settle();
    findByText(h.getRoot(), 'Command Console')[0].click();
    await settle();
    findByText(h.getRoot(), 'Manage')[0].click();
    await settle(3);
}

// ======================================================================
// EVERY DISTINCT tablet:certify REFUSAL REASON GETS ITS OWN MESSAGE
// (every outcome server/certifications/'s own GrantCertificationForTablet/
// GrantCertificationOffline doc comments list, confirmed by direct read)
// ======================================================================

const CERTIFY_REASON_TEXT = {
    invalid_target: 'That target could not be resolved. Refresh this screen and try again.',
    invalid_department: 'That department is not configured on this server.',
    department_mismatch: 'This person\'s live job no longer matches this department. Refresh their record and try again.',
    not_eligible: 'You are not currently an eligible certifier for this. You need the right rank or an explicit certifier grant.',
    rate_limited: 'You\'re doing that too quickly. Wait a few seconds and try again.',
    on_cooldown: 'You\'re doing that too quickly. Wait a few seconds and try again.',
    self_certification_disabled: 'Self-certification is turned off on this server.',
    target_must_be_online: 'This target must be online for this action. Try again once they are connected.',
    target_not_in_department: 'This target is not currently in a configured K9 department.',
    target_too_far: 'You are too far from the target. Move closer and try again.',
    target_not_k9_model: 'This target\'s current appearance is not a configured K9 model. Have them switch to a K9 ped first.',
    model_check_requires_online: 'This server requires the K9 model check, which only works for an online target. Try again while they are connected.',
    target_online_use_online_action: 'This target is currently online. Reopen their record and use the live action instead of the offline one.',
    already_certified: 'This target already holds an active certification for this department.',
    invalid_granter: 'Your own account could not be resolved. Try again, or contact an administrator.',
    db_error: 'A database error occurred. Try again; if this persists, contact an administrator.',
};

for (const [reason, expectedText] of Object.entries(CERTIFY_REASON_TEXT)) {
    t.test(`tablet:certify refusal '${reason}' renders its OWN distinct message, never a generic "Action failed."`, async () => {
        const h = createHarness({
            fetchImpl: routeFetch(baseHandlers({
                'tablet:certify': () => ({ ok: false, error: reason }),
            })),
        });
        await openPersonScreen(h);

        findByText(h.getRoot(), 'Certify')[0].click();
        await new Promise((r) => setTimeout(r, 30));

        t.isTrue(findByText(h.getRoot(), expectedText).length >= 1, `expected distinct text for '${reason}': ${JSON.stringify(expectedText)}`);
        // PERMISSION AUDIT FOLLOW-UP, SMALLER JOB (this pass): the generic
        // fallback's own text was improved (locales/en.json's
        // tablet.action_failed / html/tablet.js's own DEFAULT_STRINGS.
        // action_failed, kept in sync) -- this must keep searching for
        // whatever that generic text CURRENTLY is, not a stale literal, or
        // this assertion would trivially pass for the wrong reason (the old
        // literal simply never appearing any more, regardless of whether
        // the code actually fell back to the new generic line).
        t.equals(findByText(h.getRoot(), GENERIC_ACTION_FAILED_TEXT).length, 0, `'${reason}' must not fall back to the generic failure line`);
    });
}

t.test('every tablet:certify refusal reason above renders a DIFFERENT message from every other -- no two reasons collapse to the same generic text (except the two genuinely-synonymous rate_limited/on_cooldown codes, which share one sentence on purpose)', async () => {
    const distinctTexts = new Set(Object.values(CERTIFY_REASON_TEXT));
    // 16 codes, 15 distinct sentences: rate_limited/on_cooldown are the one
    // deliberate pair sharing text (see mutationErrorText()'s own doc
    // comment -- both mean "you are rate-limited," just from two different
    // server-side gates).
    t.equals(Object.keys(CERTIFY_REASON_TEXT).length, 16);
    t.equals(distinctTexts.size, 15);
});

// ======================================================================
// THE SAME MAPPING GENERALIZES BEYOND CERTIFY -- grantPermission/
// revertK9Ped go through the identical mutationErrorText(), proving this
// is not a certify-only special case.
// ======================================================================

t.test('tablet:grantPermission refusal \'self_grant_blocked\' renders its own distinct message', async () => {
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:requestPersonFeatures': () => ({ ok: true, target: { citizenid: 'TARGET1', name: 'K9 Rex' }, features: [] }),
            // NOTE: the REAL server (server/permissions.lua) returns
            // `{ok:false, reason:'self_grant_blocked'}`; client/tablet.lua's
            // own ReasonToJsResult() renames that to `error` BEFORE html/
            // tablet.js ever sees it (see that function's own doc comment)
            // -- this mock, like every other one in this file, supplies the
            // ALREADY-TRANSLATED `{ok, error?, message?}` shape html/
            // tablet.js's own contract expects, not the raw Lua one.
            'tablet:grantPermission': () => ({ ok: false, error: 'self_grant_blocked' }),
        })),
    });
    await openPersonScreen(h);

    // Capabilities section: a single checkbox per capability (checked ->
    // tablet:grantPermission, unchecked -> tablet:revokePermission), not a
    // separate Grant/Revoke button pair -- see buildCapabilityRow()'s own
    // doc comment. Ticking an unheld one is what fires the grant.
    const { findAll } = require('./tablet-dom-stub');
    const checkbox = findAll(h.getRoot(), (n) => n.tagName === 'input' && n.classList && n.classList.contains('k9tablet-capability-checkbox') && n.checked !== true)[0];
    t.isDefined(checkbox, 'an unheld capability checkbox exists in the Capabilities section');
    checkbox.checked = true;
    checkbox._dispatch('change');
    await new Promise((r) => setTimeout(r, 30));

    t.isTrue(findByText(h.getRoot(), 'You cannot grant this to yourself.').length >= 1);
    t.equals(findByText(h.getRoot(), GENERIC_ACTION_FAILED_TEXT).length, 0);
});

t.test('tablet:revertK9Ped refusal \'no_fallback_configured\' renders its own distinct, actionable message', async () => {
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:requestPersonFeatures': () => ({ ok: true, target: { citizenid: 'TARGET1', name: 'K9 Rex' }, features: [] }),
            'tablet:revertK9Ped': () => ({ ok: false, error: 'no_fallback_configured' }),
        })),
    });
    await openPersonScreen(h);

    const revertBtn = findByText(h.getRoot(), 'Revert to Human')[0] || findByText(h.getRoot(), 'Remove K9 Role')[0];
    t.isDefined(revertBtn, 'the revert-to-human control exists on the Person screen for a high-command viewer');
    revertBtn.click(); // arm the two-click confirm
    revertBtn.click(); // confirm
    await new Promise((r) => setTimeout(r, 30));

    t.isTrue(
        findByText(h.getRoot(), 'No fallback human model is configured on this server. Contact an administrator before reverting this target.').length >= 1
    );
    t.equals(findByText(h.getRoot(), GENERIC_ACTION_FAILED_TEXT).length, 0);
});

// ======================================================================
// STALE-STATE FIX: the Home tab now re-fetches on every click, matching
// every other data-driven tab.
// ======================================================================

t.test('clicking the Home tab re-fetches tablet:requestMyRecord, consistent with every other tab', async () => {
    let myRecordCalls = 0;
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:requestMyRecord': () => { myRecordCalls++; return { ok: true, viewer: HIGH_COMMAND_VIEWER(), certifications: [], xp: null, tierLabel: null, myFeatures: [] }; },
        })),
    });

    h.postMessage('tablet:open', {});
    await settle();
    t.equals(myRecordCalls, 1, 'tablet:open itself fetches once');

    findByText(h.getRoot(), 'Command Console')[0].click();
    await settle();
    findByText(h.getRoot(), 'My Record')[0].click();
    await settle();

    t.isTrue(myRecordCalls >= 2, 'returning to Home re-fetched the viewer\'s own record instead of showing whatever was cached at tablet:open');
});

// ======================================================================
// STALE-STATE FIX: a self-targeted Person-screen mutation also refreshes
// state.myRecord, so Home/My Record never show a stale copy of the exact
// same underlying data.
// ======================================================================

t.test('certifying YOURSELF from the Person screen also re-fetches tablet:requestMyRecord (Home/My Record would otherwise stay stale)', async () => {
    let myRecordCalls = 0;
    const h = createHarness({
        fetchImpl: routeFetch({
            'tablet:requestMyRecord': () => { myRecordCalls++; return { ok: true, viewer: HIGH_COMMAND_VIEWER('SELF1'), certifications: [], xp: null, tierLabel: null, myFeatures: [] }; },
            'tablet:requestRoster': () => ({ ok: true, rows: [{ citizenid: 'SELF1', name: 'Self', departmentLabel: 'Police', certified: false, xp: 0, tierLabel: null }], truncated: false }),
            'tablet:requestPersonSummary': () => ({
                ok: true, target: { citizenid: 'SELF1', name: 'Self' },
                certifications: [{ departmentKey: 'police', departmentLabel: 'Police', active: false, grantedBy: null }],
                xp: 0, tierLabel: null, permissions: [],
            }),
            'tablet:certify': () => ({ ok: true }),
        }),
    });

    h.postMessage('tablet:open', {});
    await settle();
    t.equals(myRecordCalls, 1);

    findByText(h.getRoot(), 'Command Console')[0].click();
    await settle();
    findByText(h.getRoot(), 'Manage')[0].click();
    await settle(3);

    findByText(h.getRoot(), 'Certify')[0].click();
    await new Promise((r) => setTimeout(r, 30));

    t.isTrue(myRecordCalls >= 2, 'a self-targeted certify re-pulled the viewer\'s own record, not just the Person screen\'s personSummary copy of the identical data');
});

t.test("a refusal's server-written `message` is shown verbatim, never collapsed into a generic code", async () => {
    // FOUND BY MUTATION TESTING (2026-08-31): making every error renderer
    // ignore `result.message` left all 42 browser specs green. Fourteen
    // renderers in html/tablet.js open with that passthrough, and it is not
    // decorative -- server/highcommand.lua attaches a real sentence to the
    // XP-grant refusals that matter most to an admin (self_grant_disabled,
    // invalid_amount, not_authorized, xp_system_unavailable), and
    // server/tablet.lua does the same for an unresolvable citizenid.
    //
    // Without the passthrough the admin gets a bare code for all of them --
    // the exact "collapses a dozen reasons into one generic line" failure
    // html/tablet.js's own error-handling was written to prevent, and the
    // same class fixed twice already this session for the `note` field.
    const SERVER_SENTENCE = 'You cannot grant XP to yourself on this server.';
    const h = createHarness({
        fetchImpl: routeFetch({
            'tablet:requestMyRecord': () => ({ ok: true, viewer: HIGH_COMMAND_VIEWER('SELF1', true), certifications: [], xp: 0, tierLabel: null, myFeatures: [] }),
            'tablet:requestRoster': () => ({ ok: true, rows: [{ citizenid: 'SELF1', name: 'Self', departmentLabel: 'Police', certified: true, xp: 0, tierLabel: 'Recruit K9' }], truncated: false }),
            'tablet:requestPersonSummary': () => ({ ok: true, target: { citizenid: 'SELF1', name: 'Self' }, certifications: [], xp: 0, tierLabel: 'Recruit K9' }),
            'tablet:givexp': () => ({ ok: false, error: 'self_grant_blocked', message: SERVER_SENTENCE }),
        }),
    });

    h.postMessage('tablet:open', {});
    await settle();
    findByText(h.getRoot(), 'Command Console')[0].click();
    await settle();
    findByText(h.getRoot(), 'Manage')[0].click();
    await settle(3);

    const input = require('./tablet-dom-stub').findByTag(h.getRoot(), 'input').find((n) => n.getAttribute('type') === 'number' && n.getAttribute('placeholder'));
    t.isDefined(input, 'the Give XP amount input exists');
    input.typeValue('50');
    findByText(h.getRoot(), 'Give XP')[0].click();
    await new Promise((r) => setTimeout(r, 30));

    t.isTrue(findByText(h.getRoot(), SERVER_SENTENCE).length > 0,
        "the server's own sentence must be rendered verbatim -- it is more specific than any code the client could map, and for several refusals it is the only explanation that exists");
});

t.test('giving XP to YOURSELF (allowSelfGrant on) also re-fetches tablet:requestMyRecord', async () => {
    let myRecordCalls = 0;
    const h = createHarness({
        fetchImpl: routeFetch({
            'tablet:requestMyRecord': () => { myRecordCalls++; return { ok: true, viewer: HIGH_COMMAND_VIEWER('SELF1', true), certifications: [], xp: null, tierLabel: null, myFeatures: [] }; },
            'tablet:requestRoster': () => ({ ok: true, rows: [{ citizenid: 'SELF1', name: 'Self', departmentLabel: 'Police', certified: true, xp: 0, tierLabel: 'Recruit K9' }], truncated: false }),
            'tablet:requestPersonSummary': () => ({ ok: true, target: { citizenid: 'SELF1', name: 'Self' }, certifications: [], xp: 0, tierLabel: 'Recruit K9', permissions: [] }),
            'tablet:givexp': () => ({ ok: true, message: 'Granted.' }),
        }),
    });

    h.postMessage('tablet:open', {});
    await settle();
    findByText(h.getRoot(), 'Command Console')[0].click();
    await settle();
    findByText(h.getRoot(), 'Manage')[0].click();
    await settle(3);

    const input = require('./tablet-dom-stub').findByTag(h.getRoot(), 'input').find((n) => n.getAttribute('type') === 'number' && n.getAttribute('placeholder'));
    t.isDefined(input, 'the Give XP amount input exists (self-target, allowSelfGrant true, so it is not disabled)');
    input.typeValue('50');
    findByText(h.getRoot(), 'Give XP')[0].click();
    await new Promise((r) => setTimeout(r, 30));

    t.isTrue(myRecordCalls >= 2, 'a self-targeted XP grant re-pulled the viewer\'s own record too');
});

// ======================================================================
// CONFIRMED SUCCESS: tablet:decertify is a real server callback, so a
// success is shown exactly like every other confirmed mutation.
// ======================================================================

t.test('tablet:decertify success renders the same confirmed "Done." notice as tablet:certify', async () => {
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:requestPersonSummary': () => ({
                ok: true, target: { citizenid: 'TARGET1', name: 'K9 Rex' },
                certifications: [{ departmentKey: 'police', departmentLabel: 'Police', active: true, grantedBy: null }],
                xp: 0, tierLabel: null, permissions: [],
            }),
            'tablet:decertify': () => ({ ok: true }),
        })),
    });
    await openPersonScreen(h);

    // SAME reference clicked twice (mkConfirmButton's own arm/confirm
    // handshake mutates THIS node's textContent directly, in place, rather
    // than triggering a full render() -- see that function's own doc
    // comment) -- a fresh findByText('Decertify') after the first click
    // would find nothing, since the button no longer reads "Decertify" once
    // armed. Mirrors tablet_console_spec.js's own identical two-click
    // pattern exactly.
    const decertifyBtn = findByText(h.getRoot(), 'Decertify')[0];
    t.isDefined(decertifyBtn);
    decertifyBtn.click(); // arm
    decertifyBtn.click(); // confirm
    await new Promise((r) => setTimeout(r, 30));

    t.isTrue(h.fetchCalls.some((c) => c.url.endsWith('tablet:decertify') && c.body.targetCitizenId === 'TARGET1'), 'the decertify callback was really fired for this person');
    t.isTrue(findByText(h.getRoot(), 'Done.').length >= 1, 'a confirmed decertify says Done., like any confirmed mutation');
});

t.test('tablet:certify success shows the normal "Done." success notice', async () => {
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:certify': () => ({ ok: true }),
        })),
    });
    await openPersonScreen(h);

    findByText(h.getRoot(), 'Certify')[0].click();
    await new Promise((r) => setTimeout(r, 30));

    t.isTrue(findByText(h.getRoot(), 'Done.').length >= 1);
});

t.run();
