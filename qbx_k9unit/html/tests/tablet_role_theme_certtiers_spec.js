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
const { findByText, findByTag, findAll } = require('./tablet-dom-stub');

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
    findByText(h.getRoot(), 'Tablet Theme')[0].click();
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
    const tab = findByText(h.getRoot(), 'Tablet Theme')[0];
    t.isTrue(!!tab, 'the tab itself is visible to a delegated non-high-command officer');
    tab.click();
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

    findByText(h.getRoot(), 'Tablet Theme')[0].click();
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
    findByText(h.getRoot(), 'Tablet Theme')[0].click();
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
    findByText(h.getRoot(), 'Tablet Theme')[0].click();
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
// CERTIFICATION TIER EDITING -- server/certtiers.lua
// ======================================================================

t.test('a non-high-command viewer never sees the Certification Tiers tab', async () => {
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:requestMyRecord': () => ({ ok: true, viewer: CONSOLE_ONLY_VIEWER, certifications: [], xp: null, tierLabel: null, myFeatures: [] }),
        })),
    });
    await openTablet(h);
    t.equals(findByText(h.getRoot(), 'Certification Tiers').length, 0);
});

t.test('DYNAMIC CATALOGUE: tiers rendered come ENTIRELY from tablet:certTiersList -- invented keys/labels appearing nowhere in tablet.js source render correctly', async () => {
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:certTiersList': () => ({
                ok: true,
                tiers: [
                    { key: 'zzz_novel_tier', label: 'Zzyzx Novel Rank', ordinal: 1, capabilities: { specializations_eligible: true } },
                    { key: 'certified', label: 'Certified', ordinal: 2, capabilities: {} },
                ],
                capabilityCatalog: { specializations_eligible: { label: 'Eligible to hold K9 specializations' } },
            }),
        })),
    });
    await openTablet(h);
    findByText(h.getRoot(), 'Catalogs')[0].click();
    await settle();

    t.isTrue(findByText(h.getRoot(), 'Zzyzx Novel Rank').length >= 1, 'a tier this test invented on the fly renders correctly -- proves no hardcoded tier list');
    t.isTrue(findByText(h.getRoot(), 'zzz_novel_tier').length >= 1);
    t.isTrue(findByText(h.getRoot(), 'Eligible to hold K9 specializations').length >= 1, 'capability label resolved from the FETCHED capabilityCatalog, not hardcoded');
});

t.test('Add New Tier: opens a blank form, and Save submits {key,label,capabilities} with capabilities as an ARRAY', async () => {
    let upsertBody = null;
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:certTiersList': () => ({
                ok: true,
                tiers: [{ key: 'certified', label: 'Certified', ordinal: 1, capabilities: {} }],
                capabilityCatalog: { advanced_tracking: { label: 'Advanced tracking' } },
            }),
            'tablet:certTiersUpsert': (body) => { upsertBody = body; return { ok: true, tiers: [], capabilityCatalog: {} }; },
        })),
    });
    await openTablet(h);
    findByText(h.getRoot(), 'Catalogs')[0].click();
    await settle();

    findByText(h.getRoot(), 'Add New Tier')[0].click();
    await settle();

    const keyInput = findAll(h.getRoot(), (n) => n.tagName === 'input' && n.classList.contains('k9tablet-cert-tier-key-input'))[0];
    const labelInput = findAll(h.getRoot(), (n) => n.tagName === 'input' && n.classList.contains('k9tablet-cert-tier-label-input'))[0];
    t.isDefined(keyInput);
    t.equals(keyInput.getAttribute('disabled'), null, 'key is editable for a BRAND NEW tier');
    keyInput.typeValue('master');
    labelInput.typeValue('Master Handler');

    const checkbox = findAll(h.getRoot(), (n) => n.tagName === 'input' && n.getAttribute('type') === 'checkbox')[0];
    t.isDefined(checkbox);
    checkbox.checked = true;
    checkbox._dispatch('change');

    findByText(h.getRoot(), 'Save Tier')[0].click();
    await new Promise((r) => setTimeout(r, 30));

    t.equals(upsertBody.key, 'master');
    t.equals(upsertBody.label, 'Master Handler');
    t.isTrue(Array.isArray(upsertBody.capabilities));
    t.equals(upsertBody.capabilities[0], 'advanced_tracking');
});

t.test('Edit an existing tier: the key input is DISABLED (no rename concept), label/capabilities remain editable', async () => {
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:certTiersList': () => ({
                ok: true,
                tiers: [{ key: 'senior', label: 'Senior', ordinal: 3, capabilities: {} }],
                capabilityCatalog: {},
            }),
        })),
    });
    await openTablet(h);
    findByText(h.getRoot(), 'Catalogs')[0].click();
    await settle();

    findByText(h.getRoot(), 'Edit')[0].click();
    await settle();

    const keyInput = findAll(h.getRoot(), (n) => n.tagName === 'input' && n.classList.contains('k9tablet-cert-tier-key-input'))[0];
    t.equals(keyInput.value, 'senior');
    t.equals(keyInput.getAttribute('disabled'), 'disabled');
});

t.test('Move Up/Down submits the FULL reordered key list (not just the two swapped) and surfaces the retroactive-rerank warning prominently', async () => {
    let reorderBody = null;
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:certTiersList': () => ({
                ok: true,
                tiers: [
                    { key: 'trainee', label: 'Trainee', ordinal: 1, capabilities: {} },
                    { key: 'certified', label: 'Certified', ordinal: 2, capabilities: {} },
                    { key: 'senior', label: 'Senior', ordinal: 3, capabilities: {} },
                ],
                capabilityCatalog: {},
            }),
            'tablet:certTiersReorder': (body) => {
                reorderBody = body;
                return {
                    ok: true,
                    tiers: [
                        { key: 'certified', label: 'Certified', ordinal: 1, capabilities: {} },
                        { key: 'trainee', label: 'Trainee', ordinal: 2, capabilities: {} },
                        { key: 'senior', label: 'Senior', ordinal: 3, capabilities: {} },
                    ],
                    warning: 'Reordering tiers changes rank comparisons RETROACTIVELY.',
                };
            },
        })),
    });
    await openTablet(h);
    findByText(h.getRoot(), 'Catalogs')[0].click();
    await settle();

    // Move the SECOND row ("certified", index 1) up, ahead of "trainee".
    const moveUpButtons = findAll(h.getRoot(), (n) => n.tagName === 'button' && n._textContent === '↑');
    t.equals(moveUpButtons.length, 3);
    t.equals(moveUpButtons[0].getAttribute('disabled'), 'disabled', 'the FIRST row cannot move up');
    moveUpButtons[1].click();
    await new Promise((r) => setTimeout(r, 30));

    t.isTrue(Array.isArray(reorderBody.orderedKeys));
    t.equals(reorderBody.orderedKeys.length, 3, 'the FULL permutation is sent, never a partial reorder');
    t.equals(reorderBody.orderedKeys[0], 'certified');
    t.equals(reorderBody.orderedKeys[1], 'trainee');
    t.equals(reorderBody.orderedKeys[2], 'senior');

    t.isTrue(findByText(h.getRoot(), 'Reordering tiers changes rank comparisons RETROACTIVELY.').length >= 1, 'the non-optional warning is actually rendered, not discarded');
});

t.test('Delete: "certified" is disabled client-side as a UX hint, but a normal tier can be deleted after confirm', async () => {
    let deleteBody = null;
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:certTiersList': () => ({
                ok: true,
                tiers: [
                    { key: 'certified', label: 'Certified', ordinal: 1, capabilities: {} },
                    { key: 'trainee', label: 'Trainee', ordinal: 2, capabilities: {} },
                ],
                capabilityCatalog: {},
            }),
            'tablet:certTiersDelete': (body) => { deleteBody = body; return { ok: true, tiers: [{ key: 'certified', label: 'Certified', ordinal: 1, capabilities: {} }] }; },
        })),
    });
    await openTablet(h);
    findByText(h.getRoot(), 'Catalogs')[0].click();
    await settle();

    const deleteButtons = findByText(h.getRoot(), 'Delete');
    t.equals(deleteButtons.length, 2);
    // Row order matches server ordinal order: certified first, trainee second.
    t.equals(deleteButtons[0].getAttribute('disabled'), 'disabled', '"certified" is disabled client-side (UX hint only -- server refuses unconditionally regardless)');
    t.equals(deleteButtons[1].getAttribute('disabled'), null);

    deleteButtons[1].click(); // arm confirm
    deleteButtons[1].click(); // confirm
    await new Promise((r) => setTimeout(r, 30));

    t.equals(deleteBody.key, 'trainee');
});

t.test('Delete refusal "tier_in_use" renders "cannot, and here is why" WITH the reference count, inline on that row -- never a bare failure message', async () => {
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:certTiersList': () => ({
                ok: true,
                tiers: [{ key: 'trainee', label: 'Trainee', ordinal: 1, capabilities: {} }],
                capabilityCatalog: {},
            }),
            'tablet:certTiersDelete': () => ({ ok: false, error: 'tier_in_use', referenceCount: 12 }),
        })),
    });
    await openTablet(h);
    findByText(h.getRoot(), 'Catalogs')[0].click();
    await settle();

    const deleteBtn = findByText(h.getRoot(), 'Delete')[0];
    deleteBtn.click();
    deleteBtn.click();
    await new Promise((r) => setTimeout(r, 30));

    const matches = findAll(h.getRoot(), (n) => typeof n._textContent === 'string' && n._textContent.indexOf('12 certification record(s)') !== -1);
    t.isTrue(matches.length >= 1, 'the specific reference count is interpolated into the refusal text, rendered inline on the row');
});

// coordinator hand-off, 2026-08-26 (server/certtiers.lua commit a32a554):
// a tier a supply shop item still requires is the OTHER referrer
// DeleteTier now checks -- a SEPARATE refusal reason from 'tier_in_use'
// (certification records) on purpose, since "N certification records" and
// "N shop items" send the reader to two different screens to actually fix
// it.
t.test('Delete refusal "tier_in_use_by_shop_items" renders its own "cannot, and here is why" text WITH the count and the actual item keys, distinct from the certification-record refusal', async () => {
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:certTiersList': () => ({
                ok: true,
                tiers: [{ key: 'senior', label: 'Senior', ordinal: 1, capabilities: {} }],
                capabilityCatalog: {},
            }),
            'tablet:certTiersDelete': () => ({ ok: false, error: 'tier_in_use_by_shop_items', referenceCount: 2, shopItemKeys: ['k9_vest', 'k9_muzzle'] }),
        })),
    });
    await openTablet(h);
    findByText(h.getRoot(), 'Catalogs')[0].click();
    await settle();

    const deleteBtn = findByText(h.getRoot(), 'Delete')[0];
    deleteBtn.click();
    deleteBtn.click();
    await new Promise((r) => setTimeout(r, 30));

    const matches = findAll(h.getRoot(), (n) => typeof n._textContent === 'string' && n._textContent.indexOf('2 supply shop item(s) still require it: k9_vest, k9_muzzle') !== -1);
    t.isTrue(matches.length >= 1, 'the count AND the real, comma-joined item keys are interpolated into the refusal text, rendered inline on the row');
    t.equals(findAll(h.getRoot(), (n) => typeof n._textContent === 'string' && n._textContent.indexOf('certification record(s)') !== -1).length, 0, 'never confused with the certification-record refusal text -- these are two different reasons with two different fixes');
});

t.test('a PARTIAL tier-reorder write names the tiers that did not save, instead of a bare failure', async () => {
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:certTiersList': () => ({
                ok: true,
                tiers: [
                    { key: 'trainee', label: 'Trainee', ordinal: 1, capabilities: {} },
                    { key: 'certified', label: 'Certified', ordinal: 2, capabilities: {} },
                ],
                capabilityCatalog: {},
            }),
            // server/certtiers.lua's real partial-failure shape. Until
            // 2026-08-31 `ordinal_write_failed` had no case in
            // certTierErrorText, so it fell to the generic "action failed"
            // line and `failedKeys` was thrown away -- on a PARTIAL write,
            // where knowing what did NOT save is the whole point.
            'tablet:certTiersReorder': () => ({
                ok: false, reason: undefined, error: 'ordinal_write_failed',
                failedKeys: ['certified'],
                tiers: [
                    { key: 'trainee', label: 'Trainee', ordinal: 1, capabilities: {} },
                    { key: 'certified', label: 'Certified', ordinal: 2, capabilities: {} },
                ],
            }),
        })),
    });
    await openTablet(h);
    findByText(h.getRoot(), 'Catalogs')[0].click();
    await settle();

    const moveDown = findAll(h.getRoot(), (n) => n.tagName === 'button' && n._textContent === '\u2193');
    moveDown[0].click();
    await new Promise((r) => setTimeout(r, 30));

    // Asserted against the full rendered sentence, never a bare search for
    // 'certified' -- that key is already on screen in its own tier row, so a
    // substring search would pass with or without the fix.
    const expected = 'The new order could not be saved for these tiers: certified. Nothing else was changed'
        + ' \u2014 reopen this screen to see the order that is actually stored, then try again.';
    t.isTrue(findByText(h.getRoot(), expected).length > 0,
        'the failing tier key must be named IN THE ERROR, not collapsed into a generic failure');
});

t.run();
