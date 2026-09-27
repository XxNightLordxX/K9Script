/*
    html/tests/tablet_role_theme_certtiers_spec.js

    Covers three HIGH-COMMAND-ONLY surfaces landed together:
      1. K9 role control on the person screen (Assign K9 Role / Revert to
         Human) plus the console's own "open by exact citizen ID" box that
         exists specifically so a decertified/never-certified target can
         still be reached at all -- see html/tablet.js's own header note on
         tablet:revertK9Ped's NO-UNBOUNDED-TRAP contract.
      2. Tablet theming (its own tab) -- applied for every viewer, editable
         by high command OR a viewer holding a delegated 'k9.tablettheme'
         grant (server/runtimecontrol.lua's own CanManageTabletTheme(source):
         IsHighCommand(source) OR HasPermission(citizenid,
         'k9.tablettheme') == true, tests/runtimecontrol_spec.lua:523;
         client-side gate: html/tablet.js's canManageTabletTheme()),
         including the live qbx_k9unit:client:themeUpdated push.
      3. Certification tier editing -- server/certtiers.lua. The catalogue
         is asserted to be genuinely DYNAMIC (driven entirely by the
         server's own tablet:certTiersList response, using tier
         keys/labels this test invents on the fly that appear NOWHERE in
         html/tablet.js's own source) rather than merely "looks dynamic".

    Every gate below is asserted as a CONVENIENCE, per html/tablet.js's own
    THE SECURITY RULE -- this suite never treats "the control isn't there"
    as a substitute for "the action is denied"; that is client/tablet.lua's
    and the server's job, covered in tests/clienttablet_spec.lua and
    tests/certtiers_spec.lua/tests/runtimecontrol_spec.lua respectively.
*/
'use strict';

const t = require('./testkit');
const { createHarness, jsonResponse } = require('./tablet-sandbox');
const { findByText, findByTag, findAll, openSettingsSection, findByClass } = require('./tablet-dom-stub');

// Mirrors html/tablet.js's own DEFAULT_STRINGS.action_failed (kept in sync
// with locales/en.json's tablet.action_failed) -- see
// tablet_mutation_error_spec.js's own identical constant for the full
// writeup of why this is hardcoded here rather than a stale literal.
const GENERIC_ACTION_FAILED_TEXT = 'Action failed — try again, and if it keeps happening, tell an admin.';

function routeFetch(handlers) {
    return function (url, init) {
        const name = url.split('/').pop();
        const body = init && init.body ? JSON.parse(init.body) : undefined;
        const h = handlers[name];
        if (!h) return Promise.reject(new Error('tablet_role_theme_certtiers_spec: unhandled NUI callback ' + name));
        return Promise.resolve(jsonResponse(h(body)));
    };
}

const HIGH_COMMAND_VIEWER = { citizenid: 'HC1', name: 'Chief', isHighCommand: true, effectivePermissions: ['k9.access', 'k9.certify', 'k9.audit', 'k9.givexp'], allowSelfGrant: false };
// OWNER'S DECISION, 2026-08-25 (server/tablet.lua's own
// CallerHasConsoleAccess, mirrored client-side by canAccessConsole()):
// console access itself requires high command or an explicit k9.audit
// grant specifically -- a bare k9.certify no longer reaches the console
// tab on its own. 'k9.audit' added here so this constant's own name
// ("console only, not high command") stays true; every non-high-command
// gate this file asserts against (Certification Tiers tab, the K9 Role
// section) is keyed on isHighCommand alone regardless, so adding this does
// not change what any of those tests are actually proving. Tablet Theme is
// the one exception -- see canManageTabletTheme()'s own doc comment -- and
// this viewer deliberately does NOT hold 'k9.tablettheme', so the existing
// "never sees the Tablet Theme tab" test below still proves what its name
// says.
const CONSOLE_ONLY_VIEWER = { citizenid: 'OFFICER1', name: 'Officer', isHighCommand: false, effectivePermissions: ['k9.certify', 'k9.audit'], allowSelfGrant: false };
// Holds the delegated capability but is NOT high command -- server/
// runtimecontrol.lua's own CanManageTabletTheme admits this exact
// citizenid (see this file's header). See canManageTabletTheme()'s own
// doc comment.
const DELEGATED_THEME_VIEWER = { citizenid: 'DELEGATE1', name: 'Delegate', isHighCommand: false, effectivePermissions: ['k9.certify', 'k9.tablettheme'], allowSelfGrant: false };

const DEFAULT_THEME_RESPONSE = { primaryColor: '#2563eb', accentColor: '#f59e0b', backgroundColor: '#111827', textColor: '#f9fafb', density: 'comfortable', headerTitle: 'K9 Command Tablet' };

async function settle(times) {
    for (let i = 0; i < (times || 3); i++) await new Promise((r) => setImmediate(r));
}

function baseHandlers(overrides) {
    return Object.assign({
        'tablet:requestMyRecord': () => ({ ok: true, viewer: HIGH_COMMAND_VIEWER, certifications: [], xp: null, tierLabel: null, myFeatures: [] }),
        'tablet:getTheme': () => ({ ok: true, theme: DEFAULT_THEME_RESPONSE }),
    }, overrides || {});
}

async function openTablet(h) {
    h.postMessage('tablet:open', {});
    await settle();
}

// ======================================================================
// K9 ROLE CONTROL + "open by exact citizen ID"
// ======================================================================

t.test('a non-high-command console user does NOT see the K9 Role section at all', async () => {
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:requestMyRecord': () => ({ ok: true, viewer: CONSOLE_ONLY_VIEWER, certifications: [], xp: null, tierLabel: null, myFeatures: [] }),
            'tablet:requestRoster': () => ({ ok: true, rows: [{ citizenid: 'TARGET1', name: 'K9 Rex', departmentLabel: 'Police', certified: true, xp: 0, tierLabel: 'Recruit K9' }], truncated: false }),
            'tablet:requestPersonSummary': () => ({ ok: true, target: { citizenid: 'TARGET1', name: 'K9 Rex' }, certifications: [], xp: 0, tierLabel: 'Recruit K9', permissions: [] }),
        })),
    });
    await openTablet(h);
    findByText(h.getRoot(), 'Command Console')[0].click();
    await settle();
    findByText(h.getRoot(), 'Manage')[0].click();
    await settle(4);

    t.equals(findByText(h.getRoot(), 'K9 Role').length, 0, 'the section is never constructed for a non-high-command viewer');
    t.equals(findByText(h.getRoot(), 'Revert to Human').length, 0);
});

t.test('high command sees Assign K9 Role (populated from the peds list sent at open) and Revert to Human, and assigning fires the right payload', async () => {
    let assignBody = null;
    let summaryCalls = 0;
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:requestRoster': () => ({ ok: true, rows: [{ citizenid: 'TARGET1', name: 'K9 Rex', departmentLabel: 'Police', certified: true, xp: 0, tierLabel: 'Recruit K9' }], truncated: false }),
            'tablet:requestPersonSummary': () => { summaryCalls++; return { ok: true, target: { citizenid: 'TARGET1', name: 'K9 Rex' }, certifications: [], xp: 0, tierLabel: 'Recruit K9', permissions: [] }; },
            'tablet:requestPersonFeatures': () => ({ ok: true, target: { citizenid: 'TARGET1', name: 'K9 Rex' }, features: [] }),
            'tablet:assignK9Role': (body) => { assignBody = body; return { ok: true }; },
        })),
    });
    h.postMessage('tablet:open', { peds: [{ model: 'a_c_shepherd', label: 'German Shepherd' }, { model: 'a_c_husky', label: 'Husky' }] });
    await settle();
    findByText(h.getRoot(), 'Command Console')[0].click();
    await settle();
    findByText(h.getRoot(), 'Manage')[0].click();
    await settle(4);

    t.equals(findByText(h.getRoot(), 'K9 Role').length, 1);
    t.isTrue(findByText(h.getRoot(), 'German Shepherd').length >= 1, 'ped label from the tablet:open payload is used, not the raw model name');
    t.equals(summaryCalls, 1);

    findByText(h.getRoot(), 'Assign K9 Role')[0].click();
    await new Promise((r) => setTimeout(r, 30));

    t.equals(assignBody.targetCitizenId, 'TARGET1');
    t.equals(assignBody.modelName, 'a_c_shepherd', 'defaults to the FIRST peds entry');
    t.equals(summaryCalls, 2, 'person summary refreshed after assigning');
});

t.test('a pinned dog character shows "Kept as a dog permanently" with the breed name, and Stop sends the unpin', async () => {
    let unpinBody = null;
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:requestRoster': () => ({ ok: true, rows: [{ citizenid: 'TARGET1', name: 'K9 Rex', departmentLabel: 'Police', certified: true, xp: 0, tierLabel: null }], truncated: false }),
            'tablet:requestPersonSummary': () => ({ ok: true, target: { citizenid: 'TARGET1', name: 'K9 Rex' }, certifications: [], xp: 0, tierLabel: null, permissions: [], pinnedDogModel: 'a_c_husky' }),
            'tablet:requestPersonFeatures': () => ({ ok: true, target: { citizenid: 'TARGET1', name: 'K9 Rex' }, features: [] }),
            'tablet:unpinDogCharacter': (body) => { unpinBody = body; return { ok: true }; },
        })),
    });
    h.postMessage('tablet:open', { peds: [{ model: 'a_c_shepherd', label: 'German Shepherd' }, { model: 'a_c_husky', label: 'Husky' }] });
    await settle();
    findByText(h.getRoot(), 'Command Console')[0].click();
    await settle();
    findByText(h.getRoot(), 'Manage')[0].click();
    await settle(4);

    t.equals(findByText(h.getRoot(), 'Kept as a dog permanently: Husky.').length, 1, 'the pin survives the summary normalisation and names the breed');
    t.equals(findByText(h.getRoot(), 'Keep as a Dog Permanently').length, 0, 'no second Pin button while already pinned');
    findByText(h.getRoot(), 'Stop Keeping as a Dog')[0].click();
    await new Promise((r) => setTimeout(r, 30));
    t.equals(unpinBody.targetCitizenId, 'TARGET1');
});

t.test('My Record shows each role as Active or "Unlocks at N XP" against the viewer\'s own XP', async () => {
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:requestMyRecord': () => ({
                ok: true, viewer: CONSOLE_ONLY_VIEWER, xp: 900, tierLabel: null, myFeatures: [], roleXp: 900,
                roleCatalog: [
                    { key: 'patrol', label: 'Patrol / apprehension', xpRequired: 0, unlocks: [] },
                    { key: 'explosives', label: 'Explosives detection', xpRequired: 1250, unlocks: [] },
                ],
                certifications: [{ departmentKey: 'police', departmentLabel: 'Police', active: true, grantedBy: 'HC1', tier: null, expiresAtUnix: null, expired: false, specializations: ['patrol', 'explosives'] }],
            }),
        })),
    });
    await openTablet(h);
    const myRecordTab = findByText(h.getRoot(), 'My Record')[0];
    if (myRecordTab) { myRecordTab.click(); await settle(); }
    t.isTrue(findByText(h.getRoot(), 'Patrol / apprehension').length >= 1, 'the role label comes from the role catalog');
    t.isTrue(findByText(h.getRoot(), 'Active').length >= 1, 'a 0 XP role is active');
    t.isTrue(findByText(h.getRoot(), 'Unlocks at 1250 XP').length >= 1, 'a role above the viewer\'s XP says when it switches on');
});

t.test('Revert to Human is reachable and enabled for a target holding ZERO certifications/permissions -- NO UNBOUNDED TRAP at the UI layer', async () => {
    let revertBody = null;
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            // Deliberately no tablet:requestRoster stub -- this target is
            // reached via "open by exact citizen ID", never the roster,
            // which is the whole point of that control's existence.
            'tablet:requestPersonSummary': () => ({
                ok: true,
                target: { citizenid: 'GHOST1', name: 'GHOST1' },
                certifications: [{ departmentKey: 'police', departmentLabel: 'Police', active: false, grantedBy: null }],
                xp: null, tierLabel: null, permissions: [],
            }),
            'tablet:requestPersonFeatures': () => ({ ok: true, target: { citizenid: 'GHOST1', name: 'GHOST1' }, features: [] }),
            'tablet:revertK9Ped': (body) => { revertBody = body; return { ok: true }; },
        })),
    });
    h.postMessage('tablet:open', { peds: [] }); // no peds configured at all -- Assign section shows its own note, Revert must still work
    await settle();
    findByText(h.getRoot(), 'Command Console')[0].click();
    await settle();

    const idInput = findAll(h.getRoot(), (n) => n.tagName === 'input' && n.getAttribute('placeholder') === 'Name, citizen ID or server ID...')[0];
    t.isDefined(idInput, 'the open-by-ID box exists on the console screen even with an empty roster');
    idInput.typeValue('GHOST1');
    findByText(h.getRoot(), 'Open')[0].click();
    await settle(4);

    t.isTrue(findByText(h.getRoot(), 'No ped models are configured on this server.').length >= 1);

    const revertBtn = findByText(h.getRoot(), 'Revert to Human')[0];
    t.isDefined(revertBtn);
    t.equals(revertBtn.getAttribute('disabled'), null, 'never disabled based on anything about the TARGET (no certification, no access, no grant held)');

    revertBtn.click(); // arm confirm
    revertBtn.click(); // confirm
    await new Promise((r) => setTimeout(r, 30));

    t.equals(revertBody.targetCitizenId, 'GHOST1');
});

// ======================================================================
// SERVER BRANDING (Config.CommandTablet.branding) -- logo + serverName in
// the header, degrading to text-only on a failed/missing image load, and
// seeding the pre-fetch initial palette from branding.theme.
// ======================================================================

t.test('branding: logo renders with serverName as its alt text, and the fallback text node starts hidden', async () => {
    const h = createHarness({ fetchImpl: routeFetch(baseHandlers()) });
    h.postMessage('tablet:open', { branding: { serverName: 'Crimson Roleplay', logo: 'images/logo.png' } });
    await settle();

    const imgs = findAll(h.getRoot(), (n) => n.tagName === 'img' && n.classList.contains('k9tablet-branding-logo'));
    t.equals(imgs.length, 1);
    t.equals(imgs[0].getAttribute('src'), 'images/logo.png');
    t.equals(imgs[0].getAttribute('alt'), 'Crimson Roleplay');

    const names = findAll(h.getRoot(), (n) => n.tagName === 'span' && n.classList.contains('k9tablet-branding-name'));
    t.equals(names.length, 1);
    t.equals(names[0].style.display, 'none', 'fallback text stays hidden while a logo is present and has not (yet) failed to load');
});

t.test('branding: an onerror on the logo <img> hides the image and reveals the serverName text -- never a broken-image icon', async () => {
    const h = createHarness({ fetchImpl: routeFetch(baseHandlers()) });
    h.postMessage('tablet:open', { branding: { serverName: 'Crimson Roleplay', logo: 'images/does-not-exist.png' } });
    await settle();

    const img = findAll(h.getRoot(), (n) => n.tagName === 'img' && n.classList.contains('k9tablet-branding-logo'))[0];
    const name = findAll(h.getRoot(), (n) => n.tagName === 'span' && n.classList.contains('k9tablet-branding-name'))[0];
    t.equals(name.style.display, 'none');

    img._dispatch('error');

    t.equals(img.style.display, 'none', 'the broken image itself is hidden');
    t.equals(name.style.display, '', 'the plain-text fallback is revealed');
});

t.test('branding: no logo configured at all -- serverName renders directly, no <img> element exists', async () => {
    const h = createHarness({ fetchImpl: routeFetch(baseHandlers()) });
    h.postMessage('tablet:open', { branding: { serverName: 'Crimson Roleplay' } });
    await settle();

    t.equals(findAll(h.getRoot(), (n) => n.tagName === 'img').length, 0);
    t.isTrue(findByText(h.getRoot(), 'Crimson Roleplay').length >= 1);
});

t.test('branding: neither serverName nor logo configured -- the branding element renders nothing, no crash', async () => {
    const h = createHarness({ fetchImpl: routeFetch(baseHandlers()) });
    h.postMessage('tablet:open', { branding: {} });
    await settle();
    t.equals(findAll(h.getRoot(), (n) => n.classList && n.classList.contains('k9tablet-branding-logo')).length, 0);
    t.equals(findAll(h.getRoot(), (n) => n.classList && n.classList.contains('k9tablet-branding-name')).length, 0);
});

t.test('branding.theme seeds the FIRST paint before tablet:getTheme resolves, but the real fetch always wins once it lands', async () => {
    let resolveGetTheme;
    const h = createHarness({
        fetchImpl: routeFetch(Object.assign({}, baseHandlers(), {
            // NOTE: routeFetch() below wraps whatever this handler returns
            // via jsonResponse() itself -- this must resolve to the PLAIN
            // body object, never a pre-wrapped jsonResponse() (which would
            // double-wrap and hide `theme` behind an extra `.json()` layer).
            'tablet:getTheme': () => new Promise((resolve) => { resolveGetTheme = resolve; }).then(() => ({ ok: true, theme: DEFAULT_THEME_RESPONSE })),
        })),
    });
    h.postMessage('tablet:open', {
        branding: { serverName: 'Crimson Roleplay', logo: 'images/logo.png', theme: { primaryColor: '#C8102E', accentColor: '#FF2D2D', backgroundColor: '#0B0B0D', textColor: '#F5F5F5' } },
    });
    await settle();

    // Before tablet:getTheme resolves: density defaults to comfortable
    // (branding carries no density/headerTitle of its own), but this is
    // ONLY directly observable via applyThemeToDocument's CSS variables,
    // which this test's stub DOM does not implement (see that function's
    // own comment) -- so this test instead proves the seed took effect via
    // the theme SCREEN's own draft inputs, reachable without waiting on
    // the pending fetch at all.
    openSettingsSection(h.getRoot(), 'Tablet Theme');
    await settle();
    const colorInputs = findAll(h.getRoot(), (n) => n.tagName === 'input' && n.getAttribute('type') === 'color');
    t.isTrue(colorInputs.some((i) => i.value === '#C8102E'), 'the branding-seeded primaryColor pre-fills the draft form before any fetch resolved');

    resolveGetTheme();
    await settle();
    t.isTrue(findByTag(h.getRoot(), 'input').filter((i) => i.getAttribute('type') === 'color').every((i) => i.value !== '#C8102E'), 'once the real tablet:getTheme response lands it fully overwrites the seeded value, per "config is the starting point, the runtime edit wins"');
});

// ======================================================================
// TABLET THEMING
// ======================================================================

t.test('a non-high-command viewer never sees the Tablet Theme tab, but the fetched theme still applies (header title)', async () => {
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:requestMyRecord': () => ({ ok: true, viewer: CONSOLE_ONLY_VIEWER, certifications: [], xp: null, tierLabel: null, myFeatures: [] }),
            'tablet:getTheme': () => ({ ok: true, theme: Object.assign({}, DEFAULT_THEME_RESPONSE, { headerTitle: 'Bark Squad HQ' }) }),
        })),
    });
    await openTablet(h);
    t.equals(findByText(h.getRoot(), 'Tablet Theme').length, 0, 'tab never constructed for a non-high-command viewer');
    await settle();
    t.isTrue(findByText(h.getRoot(), 'Bark Squad HQ').length >= 1, 'the custom header title still applies for a non-editing viewer');
});

t.test('a non-high-command officer holding a delegated k9.tablettheme grant DOES see the Tablet Theme tab, and can open it', async () => {
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:requestMyRecord': () => ({ ok: true, viewer: DELEGATED_THEME_VIEWER, certifications: [], xp: null, tierLabel: null, myFeatures: [] }),
        })),
    });
    await openTablet(h);
    t.equals(findByText(h.getRoot(), 'Server Settings').length, 1, 'the Server Settings tab is visible to a delegated non-high-command officer');
    openSettingsSection(h.getRoot(), 'Tablet Theme');
    t.equals(findByClass(h.getRoot(), 'k9tablet-settings-sections')[0].children.length, 1, 'and holds exactly the one section this delegate may change');
    await settle();
    t.isTrue(findByText(h.getRoot(), 'Tablet Appearance').length >= 1, 'the real editing screen renders, not a dead end');
});

t.test('high command opens the Theme tab, edits fields, and Save submits the working draft verbatim', async () => {
    let setBody = null;
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:setTheme': (body) => { setBody = body; return { ok: true, theme: Object.assign({}, DEFAULT_THEME_RESPONSE, body) }; },
        })),
    });
    h.postMessage('tablet:open', { themingEnabled: true });
    await settle();

    openSettingsSection(h.getRoot(), 'Tablet Theme');
    await settle();
    t.isTrue(findByText(h.getRoot(), 'Tablet Appearance').length >= 1);

    const titleInputs = findAll(h.getRoot(), (n) => n.tagName === 'input' && n.classList.contains('k9tablet-theme-title-input'));
    t.equals(titleInputs.length, 1);
    titleInputs[0].typeValue('New HQ Title');

    const densitySelects = findAll(h.getRoot(), (n) => n.tagName === 'select' && n.classList.contains('k9tablet-theme-density-select'));
    t.equals(densitySelects.length, 1);
    densitySelects[0].value = 'compact';
    densitySelects[0]._dispatch('input');

    findByText(h.getRoot(), 'Save Theme')[0].click();
    await new Promise((r) => setTimeout(r, 30));

    t.equals(setBody.headerTitle, 'New HQ Title');
    t.equals(setBody.density, 'compact');
});

t.test('a rejected save (reason=invalid_field) highlights the offending field and shows an explanatory notice, never silently doing nothing', async () => {
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:setTheme': () => ({ ok: false, error: 'invalid_field', field: 'headerTitle' }),
        })),
    });
    h.postMessage('tablet:open', { themingEnabled: true });
    await settle();
    openSettingsSection(h.getRoot(), 'Tablet Theme');
    await settle();

    findByText(h.getRoot(), 'Save Theme')[0].click();
    await new Promise((r) => setTimeout(r, 30));

    const invalidFields = findAll(h.getRoot(), (n) => n.classList && n.classList.contains('k9tablet-theme-field--invalid'));
    t.isTrue(invalidFields.length >= 1, 'the rejected field is visually marked, not just a generic failure banner');
    t.isTrue(findByText(h.getRoot(), 'That value was rejected by the server.').length >= 1 || findByText(h.getRoot(), GENERIC_ACTION_FAILED_TEXT).length >= 1);
});

t.test('themingEnabled=false shows the disabled note and disables Save/Reset -- the current theme still applies regardless', async () => {
    const h = createHarness({ fetchImpl: routeFetch(baseHandlers()) });
    h.postMessage('tablet:open', { themingEnabled: false });
    await settle();
    openSettingsSection(h.getRoot(), 'Tablet Theme');
    await settle();

    t.isTrue(findByText(h.getRoot(), 'Tablet theming is disabled server-wide. The current theme still applies; these controls will not save.').length >= 1);
    const saveBtn = findByText(h.getRoot(), 'Save Theme')[0];
    t.equals(saveBtn.getAttribute('disabled'), 'disabled');
});

t.test('a Lua-initiated qbx_k9unit:client:themeUpdated push applies live -- header title updates without reopening', async () => {
    const h = createHarness({ fetchImpl: routeFetch(baseHandlers()) });
    await openTablet(h);
    t.isTrue(findByText(h.getRoot(), 'K9 Command Tablet').length >= 1);

    h.postMessage('tablet:themeUpdated', { primaryColor: '#000000', accentColor: '#111111', backgroundColor: '#222222', textColor: '#ffffff', density: 'compact', headerTitle: 'Pushed Title' });
    await settle();

    t.isTrue(findByText(h.getRoot(), 'Pushed Title').length >= 1, 'the header re-renders immediately from the pushed theme, no round trip needed');
});

t.test('a themeUpdated push arriving before the tablet has ever been opened is harmless -- no throw, nothing rendered', async () => {
    const h = createHarness({ fetchImpl: routeFetch(baseHandlers()) });
    // Tablet never opened this test at all -- the page's own postMessage
    // listener is registered unconditionally at init(), independent of
    // state.open, matching client/tablet.lua's own "registered
    // unconditionally, not only while tabletOpen" posture for the Lua side
    // of this same push.
    h.postMessage('tablet:themeUpdated', { primaryColor: '#000000', accentColor: '#111111', backgroundColor: '#222222', textColor: '#ffffff', density: 'compact', headerTitle: 'Pushed While Closed' });
    await settle();

    t.equals(h.getRoot()._children.length, 0, 'a closed tablet renders nothing at all, even right after a live theme push');
});

t.test('a themeUpdated push arriving mid-open (before its own tablet:open fetches have resolved) never throws and never produces a half-themed mix of old and new fields', async () => {
    const h = createHarness({ fetchImpl: routeFetch(baseHandlers()) });
    h.postMessage('tablet:open', {});
    // Deliberately NOT awaiting settle() first -- this fires while
    // requestMyRecord/getTheme are still in flight, exercising the
    // "mid-open" ordering this task's own brief calls out by name.
    //
    // Whichever of the two independent full-theme writers (this push, or
    // getTheme's own in-flight response) resolves LAST simply wins outright
    // -- both client/tablet.lua's push handler and this page's loadTheme()/
    // handleThemeUpdated() always replace the WHOLE theme object, never
    // merge it field-by-field, so no ordering guard is needed for
    // correctness here (nor is a specific winner guaranteed or asserted --
    // that would make this test fragile to unrelated timing changes). The
    // two guarantees that DO actually matter, and that this test checks,
    // are: neither writer ever throws for arriving out of its "expected"
    // order, and the result is always one COMPLETE, self-consistent theme,
    // never a mix of the two (title from one, density from the other).
    h.postMessage('tablet:themeUpdated', { primaryColor: '#123456', accentColor: '#654321', backgroundColor: '#000000', textColor: '#ffffff', density: 'compact', headerTitle: 'Pushed Mid-Open' });
    await settle(6);

    const titleIsPushed = findByText(h.getRoot(), 'Pushed Mid-Open').length >= 1;
    const titleIsFetched = findByText(h.getRoot(), 'K9 Command Tablet').length >= 1;
    t.isTrue(titleIsPushed || titleIsFetched, 'exactly one of the two full themes must have applied -- never blank/neither');
    t.isFalse(titleIsPushed && titleIsFetched, 'never both at once -- the theme is fully replaced, not merged');

    const isCompact = findAll(h.getRoot(), (n) => n.classList && n.classList.contains('k9tablet-density-compact')).length >= 1;
    // The pushed theme's density is 'compact'; the fetched default's is
    // 'comfortable' -- whichever title won must carry ITS OWN density too,
    // never the other theme's field (that would be the half-themed mix this
    // test exists to rule out).
    t.equals(isCompact, titleIsPushed, 'density must come from the SAME theme object as whichever title won -- never a field-level mix of push and fetch');
});

t.test('a partial themeUpdated push (missing most fields) never blanks the UI -- every consumer falls back per-field instead of rendering empty text', async () => {
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:getTheme': () => ({ ok: true, theme: { primaryColor: '#2563eb', accentColor: '#f59e0b', backgroundColor: '#111827', textColor: '#f9fafb', density: 'compact', headerTitle: 'Established Title' } }),
        })),
    });
    await openTablet(h);
    t.isTrue(findByText(h.getRoot(), 'Established Title').length >= 1);
    t.isTrue(findAll(h.getRoot(), (n) => n.classList && n.classList.contains('k9tablet-density-compact')).length >= 1, 'compact density from the initial fetch is applied');

    // Only one field survives the push -- headerTitle/density (among
    // others) are simply ABSENT, not explicitly reset -- the exact
    // "partial or malformed payload" shape this task's own brief warns
    // about.
    h.postMessage('tablet:themeUpdated', { primaryColor: '#abcdef' });
    await settle();

    t.equals(findByText(h.getRoot(), 'Established Title').length, 0, 'the stale title is genuinely replaced, not left stuck');
    t.isTrue(findByText(h.getRoot(), 'K9 Command Tablet').length >= 1, 'a missing headerTitle falls back to the default title text -- never blank/empty');
    t.equals(findAll(h.getRoot(), (n) => n.classList && n.classList.contains('k9tablet-density-compact')).length, 0, 'a missing density falls back to comfortable (no compact class), never left half-applied');
});

t.test('a non-object themeUpdated push (null or a bare string) is ignored entirely -- the previously applied theme is left untouched, and nothing throws', async () => {
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:getTheme': () => ({ ok: true, theme: { primaryColor: '#2563eb', accentColor: '#f59e0b', backgroundColor: '#111827', textColor: '#f9fafb', density: 'comfortable', headerTitle: 'Established Title' } }),
        })),
    });
    await openTablet(h);
    t.isTrue(findByText(h.getRoot(), 'Established Title').length >= 1);

    h.postMessage('tablet:themeUpdated', null);
    await settle();
    h.postMessage('tablet:themeUpdated', 'not-a-theme-object');
    await settle();

    t.isTrue(findByText(h.getRoot(), 'Established Title').length >= 1, 'a malformed push must never blank or replace the previously applied theme');
});

// ======================================================================
// K9 ROLES EDITOR -- server/roles.lua
// Tiers and specializations were merged into one list of roles high
// command creates: a name, the XP it switches on at, and what it unlocks.
// ======================================================================

const ROLE_UNLOCK_OPTIONS = [
    { key: 'track_blood', label: 'Track: blood' },
    { key: 'detect_narcotics', label: 'Detect: narcotics' },
    { key: 'bite_takedown', label: 'Bite / takedown' },
];
const SAMPLE_ROLES = [
    { key: 'zzz_novel_role', label: 'Zzyzx Novel Role', xpRequired: 0, unlocks: ['detect_narcotics'] },
    { key: 'tactical', label: 'Tactical K9', xpRequired: 4000, unlocks: ['track_blood', 'bite_takedown'] },
];

function rolesHandlers(overrides) {
    return baseHandlers(Object.assign({
        'tablet:rolesList': () => ({ ok: true, roles: SAMPLE_ROLES, unlockOptions: ROLE_UNLOCK_OPTIONS, canManage: true }),
        'tablet:permKeysList': () => ({ ok: true, keys: [] }),
        'tablet:xpTiersList': () => ({ ok: true, tiers: [] }),
    }, overrides || {}));
}

async function openRoles(h) {
    await openTablet(h);
    openSettingsSection(h.getRoot(), 'Catalogs');
    await settle();
}

t.test('the old Certification Tiers editor is gone -- the Catalogs section shows Roles instead', async () => {
    const h = createHarness({ fetchImpl: routeFetch(rolesHandlers()) });
    await openRoles(h);
    t.equals(findByText(h.getRoot(), 'Certification Tiers').length, 0);
    t.equals(findByText(h.getRoot(), 'Add New Tier').length, 0);
    t.isTrue(findByText(h.getRoot(), 'Roles').length >= 1);
    t.isFalse(h.fetchCalls.some((c) => c.url.endsWith('tablet:certTiersList')), 'the Catalogs section no longer loads the tier list');
});

t.test('DYNAMIC CATALOGUE: roles come entirely from tablet:rolesList, with their XP and unlock labels', async () => {
    const h = createHarness({ fetchImpl: routeFetch(rolesHandlers()) });
    await openRoles(h);
    t.isTrue(findByText(h.getRoot(), 'Zzyzx Novel Role').length >= 1, 'a role invented by this test renders -- no hardcoded list');
    t.isTrue(findByText(h.getRoot(), '4000').length >= 1, 'its XP requirement is shown');
    t.isTrue(findByText(h.getRoot(), 'Track: blood, Bite / takedown').length >= 1, 'unlock labels come from the fetched unlockOptions');
});

t.test('someone who is not high command sees the roles but no Add / Edit / Delete controls', async () => {
    const h = createHarness({
        fetchImpl: routeFetch(rolesHandlers({
            'tablet:rolesList': () => ({ ok: true, roles: SAMPLE_ROLES, unlockOptions: ROLE_UNLOCK_OPTIONS, canManage: false }),
        })),
    });
    await openRoles(h);
    t.isTrue(findByText(h.getRoot(), 'Tactical K9').length >= 1);
    t.equals(findByText(h.getRoot(), 'Add Role').length, 0);
    t.equals(findByText(h.getRoot(), 'Edit').length, 0);
    t.equals(findByText(h.getRoot(), 'Delete').length, 0);
});

t.test('Add Role: a blank form; Save sends {label, xpRequired as a number, unlocks as an ARRAY} and no key', async () => {
    let saveBody = null;
    const h = createHarness({
        fetchImpl: routeFetch(rolesHandlers({
            'tablet:rolesSave': (body) => { saveBody = body; return { ok: true, key: 'scout', roles: SAMPLE_ROLES.concat([{ key: 'scout', label: 'Scout', xpRequired: 250, unlocks: ['track_blood'] }]) }; },
        })),
    });
    await openRoles(h);
    findByText(h.getRoot(), 'Add Role')[0].click();
    await settle();

    const nameInput = findAll(h.getRoot(), (n) => n.tagName === 'input' && n.classList.contains('k9tablet-role-name-input'))[0];
    const xpInput = findAll(h.getRoot(), (n) => n.tagName === 'input' && n.classList.contains('k9tablet-role-xp-input'))[0];
    t.isDefined(nameInput);
    t.equals(nameInput.value, '');
    nameInput.typeValue('Scout');
    xpInput.typeValue('250');
    const box = findAll(h.getRoot(), (n) => n.tagName === 'input' && n.getAttribute('type') === 'checkbox')[0];
    box.checked = true;
    box._dispatch('change');

    findByText(h.getRoot(), 'Save Role')[0].click();
    await new Promise((r) => setTimeout(r, 30));

    t.equals(saveBody.label, 'Scout');
    t.equals(saveBody.xpRequired, 250);
    t.isTrue(Array.isArray(saveBody.unlocks));
    t.equals(saveBody.unlocks.join(','), 'track_blood');
    t.isTrue(saveBody.key == null, 'a new role has no key -- the server makes one from the name');
    t.isTrue(findByText(h.getRoot(), 'Scout').length >= 1, 'the saved list is shown straight away');
    t.isTrue(findByText(h.getRoot(), 'Role saved.').length >= 1);
});

t.test('Edit keeps the role\'s key and pre-fills its name, XP and unlocks', async () => {
    let saveBody = null;
    const h = createHarness({
        fetchImpl: routeFetch(rolesHandlers({
            'tablet:rolesSave': (body) => { saveBody = body; return { ok: true, key: body.key, roles: SAMPLE_ROLES }; },
        })),
    });
    await openRoles(h);
    findByText(h.getRoot(), 'Edit')[1].click(); // Tactical K9's row
    await settle();
    const nameInput = findAll(h.getRoot(), (n) => n.tagName === 'input' && n.classList.contains('k9tablet-role-name-input'))[0];
    t.equals(nameInput.value, 'Tactical K9');
    const boxes = findAll(h.getRoot(), (n) => n.tagName === 'input' && n.getAttribute('type') === 'checkbox');
    t.equals(boxes.filter((b) => b.checked).length, 2, 'its two unlocks start ticked');
    findByText(h.getRoot(), 'Save Role')[0].click();
    await new Promise((r) => setTimeout(r, 30));
    t.equals(saveBody.key, 'tactical');
    t.equals(saveBody.xpRequired, 4000);
});

t.test('a refused save explains itself in plain words and keeps the form open', async () => {
    const h = createHarness({
        fetchImpl: routeFetch(rolesHandlers({
            'tablet:rolesSave': () => ({ ok: false, error: 'invalid_xp', field: 'xpRequired' }),
        })),
    });
    await openRoles(h);
    findByText(h.getRoot(), 'Add Role')[0].click();
    await settle();
    findAll(h.getRoot(), (n) => n.tagName === 'input' && n.classList.contains('k9tablet-role-name-input'))[0].typeValue('Scout');
    findByText(h.getRoot(), 'Save Role')[0].click();
    await new Promise((r) => setTimeout(r, 30));
    t.isTrue(findByText(h.getRoot(), 'XP needed must be a whole number, 0 or more.').length >= 1);
    t.isTrue(findByText(h.getRoot(), 'Save Role').length >= 1, 'the form stays open to fix');
});

t.test('Delete asks for a second press, then sends the role key and shows the new list', async () => {
    let deleteBody = null;
    const h = createHarness({
        fetchImpl: routeFetch(rolesHandlers({
            'tablet:rolesDelete': (body) => { deleteBody = body; return { ok: true, roles: [SAMPLE_ROLES[1]] }; },
        })),
    });
    await openRoles(h);
    findByText(h.getRoot(), 'Delete')[0].click();
    await settle();
    t.equals(deleteBody, null, 'the first press only arms the button');
    findByText(h.getRoot(), 'Confirm?')[0].click();
    await new Promise((r) => setTimeout(r, 30));
    t.equals(deleteBody.key, 'zzz_novel_role');
    t.equals(findByText(h.getRoot(), 'Zzyzx Novel Role').length, 0);
    t.isTrue(findByText(h.getRoot(), 'Role deleted.').length >= 1);
});

t.test('deleting a role shop items still need is refused, naming those items and what to do', async () => {
    const h = createHarness({
        fetchImpl: routeFetch(rolesHandlers({
            'tablet:rolesDelete': () => ({ ok: false, error: 'role_in_use_by_shop_items', count: 2, items: ['k9_bomb_vest', 'k9_muzzle'] }),
        })),
    });
    await openRoles(h);
    findByText(h.getRoot(), 'Delete')[0].click();
    await settle();
    findByText(h.getRoot(), 'Confirm?')[0].click();
    await new Promise((r) => setTimeout(r, 30));
    t.isTrue(findByText(h.getRoot(), 'Shop items still need this role: k9_bomb_vest, k9_muzzle. Change their Required Role first, then delete it.').length >= 1);
    t.isTrue(findByText(h.getRoot(), 'Zzyzx Novel Role').length >= 1, 'the role is still listed');
});

t.test('a role high command deleted shows "Role deleted" on a record -- never "Active" -- and can still be revoked', async () => {
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:requestMyRecord': () => ({
                ok: true, viewer: CONSOLE_ONLY_VIEWER, xp: 900, tierLabel: null, myFeatures: [], roleXp: 900,
                roleCatalog: [{ key: 'patrol', label: 'Patrol / apprehension', xpRequired: 0, unlocks: [] }],
                certifications: [{ departmentKey: 'police', departmentLabel: 'Police', active: true, grantedBy: 'HC1', tier: null, expiresAtUnix: null, expired: false, specializations: ['patrol', 'old_tactical'] }],
            }),
        })),
    });
    await openTablet(h);
    const myRecordTab = findByText(h.getRoot(), 'My Record')[0];
    if (myRecordTab) { myRecordTab.click(); await settle(); }
    t.equals(findByText(h.getRoot(), 'Role deleted').length, 1, 'the deleted role is labelled as deleted');
    t.equals(findByText(h.getRoot(), 'Active').length, 1, 'only the real role reads Active');
});

t.test('a failed roles load shows the error and a Retry that fetches again', async () => {
    let calls = 0;
    const h = createHarness({
        fetchImpl: routeFetch(rolesHandlers({
            'tablet:rolesList': () => { calls++; return calls === 1 ? { ok: false, error: 'unknown_error' } : { ok: true, roles: SAMPLE_ROLES, unlockOptions: ROLE_UNLOCK_OPTIONS, canManage: true }; },
        })),
    });
    await openRoles(h);
    findByText(h.getRoot(), 'Retry')[0].click();
    await settle();
    t.equals(calls, 2);
    t.isTrue(findByText(h.getRoot(), 'Tactical K9').length >= 1);
});

t.run();
