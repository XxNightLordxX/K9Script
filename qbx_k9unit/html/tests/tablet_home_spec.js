/*
    html/tests/tablet_home_spec.js

    Covers the Home / landing view (html/tablet.js's own buildHomeScreen()
    -- see that function's own header for the full information-architecture
    writeup this pass introduced): the tablet is now organised around WHO
    IS HOLDING IT rather than which subsystem a screen belongs to, and this
    is the ONE screen every viewer type lands on first.

    Specifically proves:
      1. Home is the DEFAULT screen for every viewer type who does NOT
         auto-route straight to the Console on open -- see "ONE COMMAND,
         ROUTED BY RANK", 2026-08-26: a canAccessConsole()-qualifying
         viewer (high command, or an explicit 'k9.audit' grant) now lands
         on the Console automatically instead (goHome() below is how a
         test in THIS file still inspects what Home itself renders for
         such a viewer -- a different question from where they land by
         default, which html/tests/tablet_auto_console_landing_spec.js
         covers on its own).
      2. Each viewer type gets the right ROLE BADGE and the right set of
         screens reachable from Home (progressive disclosure: High Command
         Tools appears for state.viewer.isHighCommand === true, OR for a
         non-high-command viewer holding one of the four delegable
         capabilities -- Theme/K9 Supply Shop/Runtime Control,
         see html/tablet.js's own canManageTabletTheme() doc comment --
         in which case only THAT capability's own shortcut shows, never
         the high-command-only ones alongside it).
      3. A viewer with ZERO active certifications gets a real, useful
         screen (an explicit guidance notice) instead of an empty shell,
         and still has a working path to their own (empty) record -- never
         a dead end.
      4. State-at-a-glance: the certified-department count and the
         blocked-ability count badges reflect the real numbers, and the
         blocked badge is absent entirely when the count is zero (never a
         "0 blocked" badge nobody needs to see).

    Escaping of the Home screen's one attacker-controlled surface (the
    welcome heading's interpolated viewer name/citizenid) is covered in
    html/tests/tablet_xss_spec.js, alongside every other screen this
    resource renders, per that file's own "keep this the one XSS suite"
    posture -- not duplicated here.
*/
'use strict';

const t = require('./testkit');
const { createHarness, jsonResponse } = require('./tablet-sandbox');
const { findByText, findAll, openSettingsSection, findByClass } = require('./tablet-dom-stub');

function routeFetch(handlers) {
    return function (url, init) {
        const name = url.split('/').pop();
        const body = init && init.body ? JSON.parse(init.body) : undefined;
        const h = handlers[name];
        if (!h) return Promise.reject(new Error('tablet_home_spec: unhandled NUI callback ' + name));
        return Promise.resolve(jsonResponse(h(body)));
    };
}

async function settle(times) {
    for (let i = 0; i < (times || 3); i++) await new Promise((r) => setImmediate(r));
}

/**
 * buildHomeActionCard() puts its click listener on the OUTER <button>,
 * with the visible label/hint as two SEPARATE child <span> elements (see
 * that function's own doc comment) -- correct in a real browser (a click
 * on either span bubbles up to the button's own listener), but this
 * stub's own `_dispatch` deliberately does NOT implement bubbling (see
 * tablet-dom-stub.js's own header). Finds the label text via findByText
 * as usual, then walks UP to the enclosing <button> and clicks THAT node
 * -- exactly what a real click-then-bubble would already deliver to.
 * @param {object} root @param {string} label
 */
function clickActionCard(root, label) {
    var node = findByText(root, label)[0];
    if (!node) throw new Error('tablet_home_spec: no element with text ' + JSON.stringify(label));
    while (node && node.tagName !== 'button') node = node.parentNode;
    if (!node) throw new Error('tablet_home_spec: no enclosing <button> found for ' + JSON.stringify(label));
    node.click();
}

async function openTablet(myRecordResult, extraHandlers) {
    const h = createHarness({
        fetchImpl: routeFetch(Object.assign({
            'tablet:requestMyRecord': () => myRecordResult,
        }, extraHandlers || {})),
    });
    h.postMessage('tablet:open', {});
    await settle();
    return h;
}

/**
 * ONE COMMAND, ROUTED BY RANK (this pass, 2026-08-26) -- openTablet()
 * above posts a bare `{}` payload, which handleOpen() now defaults to
 * `requestedView: 'auto'` (see client/tablet.lua's own NUI CONTRACT), so
 * loadMyRecord() auto-lands any canAccessConsole()-qualifying viewer
 * (high command, or an explicit 'k9.audit' grant) straight on the
 * Console screen instead of Home -- see
 * html/tests/tablet_auto_console_landing_spec.js for that ROUTING
 * behavior's own dedicated coverage. This file is about what HOME
 * renders for each viewer type, a different question from where a viewer
 * lands by default -- so any test here that needs to inspect Home's own
 * content for a console-qualifying viewer navigates there explicitly via
 * the Home tab, exactly as tablet_console_spec.js already navigates to
 * Console explicitly for its own subject matter.
 * @param {object} h
 */
async function goHome(h) {
    findByText(h.getRoot(), 'My Record')[0].click();
    await settle();
}

// ======================================================================
// THE FOUR VIEWER TYPES -- role badge + right screens, all on the DEFAULT
// (no-click) Home screen.
// ======================================================================

t.test('HIGH COMMAND: Home shows role badge "High Command" and the High Command signpost names its own access in plain language (this pass: high command now auto-lands on Console instead, so this test navigates to Home explicitly to inspect it)', async () => {
    const h = await openTablet({
        ok: true,
        viewer: { citizenid: 'HC1', name: 'Chief Hopps', isHighCommand: true, effectivePermissions: ['k9.access', 'k9.certify', 'k9.audit', 'k9.givexp'], allowSelfGrant: false },
        certifications: [{ departmentKey: 'police', departmentLabel: 'Police', active: true, grantedBy: 'X', tier: 'senior', expiresAtUnix: null, expired: false, specializations: [] }],
        xp: 500, tierLabel: 'Veteran K9', myFeatures: [],
    }, {
        // Auto-landed on Console by this pass's own routing change --
        // loadRoster() fires in the background before this test navigates
        // back to Home; harmless either way (fetchNui never rejects), but
        // an explicit ok:true response keeps this test's own console.log
        // noise-free rather than resolving through the generic
        // 'network_error' fallback.
        'tablet:requestRoster': () => ({ ok: true, rows: [], truncated: false }),
    });
    await goHome(h);

    t.isTrue(findByText(h.getRoot(), 'Welcome, Chief Hopps.').length >= 1, 'welcome heading shown once navigated to Home');
    t.equals(findByText(h.getRoot(), 'High Command').length, 1, 'role badge reads High Command');
    // No "View My Record" card any more: it pointed at the screen the
    // viewer is already on once Home, My Record and Progression merged
    // (plan item A). The record itself is right below this card grid.
    t.equals(findByText(h.getRoot(), 'View My Record').length, 0);
    t.equals(findByText(h.getRoot(), 'Open Command Console').length, 1, 'high command also gets the console quick action');
    t.equals(findByText(h.getRoot(), 'High Command Tools').length, 1, 'the signpost heading is present');

    // ONE NAVIGATION STRUCTURE, NOT TWO (this pass) -- the signpost no
    // longer duplicates every admin screen as its own shortcut; it points
    // at the tab row instead. Every real tab still appears exactly once,
    // grouped into its own band (see html/tablet.css's own
    // ".k9tablet-tab-group--admin" comment) -- checked here as "exactly
    // one occurrence", never a second, arrow-suffixed copy on Home.
    // 'K9 Supply Shop' is ONE tab covering both shop sections (plan item
    // F), and 'K9 Overrides' is no longer a tab at all (plan item D).
    // 'Catalogs' is ONE tab covering certification tiers, permission keys and
    // XP ranks (plan item G).
    // SERVER SETTINGS (the rework pass): Theme, Catalogs, the Shop and
    // Runtime Control are sections of ONE tab now, not four tabs -- and the
    // Server Tuning flow that duplicated three of them is gone.
    for (const label of ['Server Settings', 'Personnel Roster', 'Audit Trail']) {
        t.equals(findByText(h.getRoot(), label).length, 1, `"${label}" tab appears exactly once -- no competing Home shortcut`);
    }
    for (const label of ['Tablet Theme', 'Catalogs', 'K9 Supply Shop', 'Runtime Control', 'Server Tuning']) {
        t.equals(findByText(h.getRoot(), label).length, 0, `"${label}" is a Server Settings section now, not a tab of its own`);
    }

    // The signpost's own plain-language pointer -- proves the section
    // explains where to go instead of re-listing every destination itself.
    t.isTrue(findByText(h.getRoot(), 'The whole-server settings are under the Server Settings tab at the top of the screen, one click per section. The personnel roster and the audit trail have their own tabs beside it.').length >= 1);

    // The admin tab cluster is a real, labelled group in the DOM (not just
    // a visual illusion) -- a screen reader announces it as one.
    const adminGroups = findAll(h.getRoot(), (n) => n.getAttribute && n.getAttribute('role') === 'group');
    t.equals(adminGroups.length, 1, 'exactly one admin tab group exists');
});

t.test('HIGH COMMAND: the real Certification Tiers tab (now grouped into the High Command tab band) still opens the real screen', async () => {
    const h = await openTablet({
        ok: true,
        viewer: { citizenid: 'HC1', name: 'Chief', isHighCommand: true, effectivePermissions: ['k9.access', 'k9.certify', 'k9.audit', 'k9.givexp'], allowSelfGrant: false },
        certifications: [], xp: null, tierLabel: null, myFeatures: [],
    }, {
        'tablet:getTheme': () => ({ ok: true, theme: { primaryColor: '#2563eb', accentColor: '#f59e0b', backgroundColor: '#111827', textColor: '#f9fafb', density: 'comfortable', headerTitle: 'K9 Command Tablet' } }),
    });

    openSettingsSection(h.getRoot(), 'Tablet Theme');
    await settle();

    t.isTrue(findByText(h.getRoot(), 'Tablet Appearance').length >= 1, 'the grouped tab opened the real Tablet Theme screen');
    t.isTrue(h.fetchCalls.some((c) => c.url.endsWith('tablet:getTheme')), 'clicking the tab fired the real server round trip');
});

t.test('DELEGATED NON-HIGH-COMMAND (holds only k9.runtimecontrol): High Command signpost appears, and only that ONE capability\'s tab is grouped into the admin band', async () => {
    const h = await openTablet({
        ok: true,
        viewer: { citizenid: 'DELEGATE1', name: 'Delegate', isHighCommand: false, effectivePermissions: ['k9.access', 'k9.certify', 'k9.runtimecontrol'], allowSelfGrant: false },
        certifications: [{ departmentKey: 'police', departmentLabel: 'Police', active: true, grantedBy: 'X', tier: 'certified', expiresAtUnix: null, expired: false, specializations: [] }],
        xp: 100, tierLabel: 'Trained K9', myFeatures: [],
    }, {
        'tablet:runtimeListFeatures': () => ({ ok: true, features: [] }),
        'tablet:runtimeListTunables': () => ({ ok: true, tunables: [] }),
    });

    t.equals(findByText(h.getRoot(), 'Certified Handler').length, 1, 'not high command, so the ordinary role badge shows');
    t.equals(findByText(h.getRoot(), 'High Command').length, 0);
    t.equals(findByText(h.getRoot(), 'High Command Tools').length, 1, 'signpost still built for a delegated non-high-command viewer too');
    t.equals(findByText(h.getRoot(), 'Server Settings').length, 1, 'the ONE capability this viewer actually holds is reachable, under Server Settings');

    // Every high-command-only tab (no delegation exists for any of these)
    // and every OTHER delegable one this viewer does NOT hold stays
    // absent -- never a wider admin band than this viewer's own real
    // access, exactly as buildTabs() itself already gates.
    for (const label of ['Guided Flows', 'Tablet Theme', 'Catalogs', 'K9 Supply Shop', 'K9 Overrides', 'Audit Trail']) {
        t.equals(findByText(h.getRoot(), label).length, 0, `"${label}" tab must NOT appear for this viewer`);
    }

    openSettingsSection(h.getRoot(), 'Runtime Control');
    await settle();
    t.isTrue(findByText(h.getRoot(), 'Runtime Feature Control').length >= 1, 'the section opens the real screen, not a dead end');
    t.equals(findByClass(h.getRoot(), 'k9tablet-settings-sections')[0].children.length, 1, 'Server Settings holds only the one section this viewer may change');
});

// ============================================================================
// WORKFLOW AUDIT FINDING #3, 2026-08-26 -- buildHomeHighCommandSignpost()'s
// BODY (not its heading, which stays "High Command Tools" for everyone who
// sees the section at all -- see the sibling tests above/below still
// asserting that exact heading text) now describes ONLY what a
// non-high-command delegate actually holds, never the full six-item list a
// true high-command viewer sees.
// ============================================================================

t.test('WORKFLOW AUDIT #3: a delegate holding ONLY k9.runtimecontrol sees a signpost body naming ONLY that capability, never the full high-command list', async () => {
    const h = await openTablet({
        ok: true,
        viewer: { citizenid: 'DELEGATE2', name: 'Ops Delegate', isHighCommand: false, effectivePermissions: ['k9.access', 'k9.runtimecontrol'], allowSelfGrant: false },
        certifications: [], xp: null, tierLabel: null, myFeatures: [],
    }, {
        'tablet:runtimeListFeatures': () => ({ ok: true, features: [] }),
        'tablet:runtimeListTunables': () => ({ ok: true, tunables: [] }),
    });

    t.equals(findByText(h.getRoot(), 'High Command Tools').length, 1, 'the heading is unchanged for every viewer who sees this section at all');
    t.equals(findByText(h.getRoot(), "You've been granted access to: which features are turned on.").length, 1, 'the body names ONLY the one capability this viewer actually holds');
    t.equals(findByText(h.getRoot(), 'Settings that affect the whole server: how the tablet looks, certification ranks, permission keys, the supply shop, which features are turned on, XP ranks, and the audit trail.').length, 0, 'the full high-command-only promise text is absent for this delegate');
    t.equals(findByText(h.getRoot(), 'The whole-server settings are under the Server Settings tab at the top of the screen, one click per section. The personnel roster and the audit trail have their own tabs beside it.').length, 0, 'the high-command-only pointer sentence is absent too');
    t.equals(findByText(h.getRoot(), "You'll find these under the Server Settings tab at the top of the screen.").length, 1, 'a delegate-specific pointer is shown instead');
});

t.test('WORKFLOW AUDIT #3: a delegate holding TWO of the four capabilities gets both named in the signpost body, joined in plain English', async () => {
    const h = await openTablet({
        ok: true,
        viewer: { citizenid: 'DELEGATE3', name: 'Multi Delegate', isHighCommand: false, effectivePermissions: ['k9.access', 'k9.tablettheme', 'k9.equipmentshoplocations'], allowSelfGrant: false },
        certifications: [], xp: null, tierLabel: null, myFeatures: [],
    }, {
        'tablet:getTheme': () => ({ ok: true, theme: { primaryColor: '#2563eb', accentColor: '#f59e0b', backgroundColor: '#111827', textColor: '#f9fafb', density: 'comfortable', headerTitle: 'K9 Command Tablet' } }),
    });

    t.equals(findByText(h.getRoot(), "You've been granted access to: how the tablet looks and which supply shop locations are active.").length, 1, 'both held capabilities are named, joined with "and" -- neither the other two unheld ones nor the full high-command list appear');
});

t.test('WORKFLOW AUDIT #3 control: a TRUE high-command viewer keeps the original, unabridged signpost body -- this pass never touches the accurate case (navigated to Home explicitly -- this pass auto-lands high command on Console by default, a separate concern from what Home itself renders)', async () => {
    const h = await openTablet({
        ok: true,
        viewer: { citizenid: 'HC3', name: 'Chief', isHighCommand: true, effectivePermissions: ['k9.access', 'k9.certify', 'k9.audit', 'k9.givexp'], allowSelfGrant: false },
        certifications: [], xp: null, tierLabel: null, myFeatures: [],
    }, {
        'tablet:requestRoster': () => ({ ok: true, rows: [], truncated: false }),
    });
    await goHome(h);

    t.equals(findByText(h.getRoot(), 'Settings that affect the whole server: how the tablet looks, certification ranks, permission keys, the supply shop, which features are turned on, XP ranks, and the audit trail.').length, 1, 'high command still sees the full, accurate promise -- they really do have all of it');
    t.equals(findByText(h.getRoot(), "You've been granted access to: which features are turned on.").length, 0, 'the delegate-scoped phrasing never leaks into the high-command path');
});

t.test('CERTIFIED HANDLER (not high command, not a K9 model, k9.access only): role badge reads "Certified Handler", NO console quick action, NO High Command Tools section', async () => {
    const h = await openTablet({
        ok: true,
        viewer: { citizenid: 'OFFICER1', name: 'Officer Rex', isHighCommand: false, effectivePermissions: ['k9.access'], allowSelfGrant: false },
        certifications: [{ departmentKey: 'police', departmentLabel: 'Police', active: true, grantedBy: 'X', tier: 'certified', expiresAtUnix: null, expired: false, specializations: [] }],
        xp: 100, tierLabel: 'Trained K9',
        myFeatures: [{ key: 'Recall', label: 'Recall your K9', category: 'Combat', actionable: true, state: 'available' }],
    });

    t.equals(findByText(h.getRoot(), 'Certified Handler').length, 1);
    t.equals(findByText(h.getRoot(), 'High Command').length, 0, 'no High Command role badge for this viewer');
    t.equals(findByText(h.getRoot(), 'High Command Tools').length, 0, 'admin section never renders for a non-high-command viewer');
    // OWNER'S DECISION, 2026-08-25 (server/tablet.lua's own
    // CallerHasConsoleAccess): console access was NARROWED from "any
    // non-empty effectivePermissions" to "high command, or an explicit
    // k9.audit grant" specifically, because a bare 'k9.access' resolves
    // true for every ordinary certified handler -- letting rank-and-file
    // enumerate every other citizenid's certification history/XP/who
    // holds admin capabilities. html/tablet.js's own canAccessConsole()
    // mirrors that server-side gate exactly (see its own doc comment) --
    // this test used to assert the OLD, now-incorrect contract ("k9.access
    // alone already grants console access"); see the sibling test just
    // below for the handler who DOES still qualify (an explicit k9.audit
    // grant, kept deliberately per that same server-side comment).
    t.equals(findByText(h.getRoot(), 'Open Command Console').length, 0, 'a bare k9.access holder no longer gets the console quick action -- see server/tablet.lua CallerHasConsoleAccess, OWNER\'S DECISION 2026-08-25');
    t.isTrue(findByText(h.getRoot(), 'Recall your K9').length >= 1, 'an actionable, available ability shows on Home\'s own "ready to use" list, not only on My Record');
});

t.test('CERTIFIED HANDLER holding an explicit k9.audit grant (not high command): console quick action IS present -- the one non-high-command path server/tablet.lua\'s CallerHasConsoleAccess still admits (navigated to Home explicitly -- this pass auto-lands a k9.audit holder on Console by default)', async () => {
    const h = await openTablet({
        ok: true,
        viewer: { citizenid: 'OFFICER2', name: 'Officer Bell', isHighCommand: false, effectivePermissions: ['k9.access', 'k9.audit'], allowSelfGrant: false },
        certifications: [{ departmentKey: 'police', departmentLabel: 'Police', active: true, grantedBy: 'X', tier: 'certified', expiresAtUnix: null, expired: false, specializations: [] }],
        xp: 100, tierLabel: 'Trained K9', myFeatures: [],
    }, {
        'tablet:requestRoster': () => ({ ok: true, rows: [], truncated: false }),
    });
    await goHome(h);

    t.equals(findByText(h.getRoot(), 'Certified Handler').length, 1);
    t.equals(findByText(h.getRoot(), 'High Command Tools').length, 0, 'k9.audit alone is still not high command -- no admin section');
    t.equals(findByText(h.getRoot(), 'Open Command Console').length, 1, 'an explicit k9.audit grant is the one deliberately-kept non-high-command path to console access');
});

t.test('K9 (isK9Model true, not high command): role badge reads "K9"', async () => {
    const h = await openTablet({
        ok: true,
        viewer: { citizenid: 'K9DOG1', name: 'Rex', isHighCommand: false, effectivePermissions: ['k9.access'], allowSelfGrant: false },
        certifications: [{ departmentKey: 'police', departmentLabel: 'Police', active: true, grantedBy: 'X', tier: 'certified', expiresAtUnix: null, expired: false, specializations: [] }],
        xp: 0, tierLabel: null, myFeatures: [],
        // Simulates client/tablet.lua's ResolveLocalRoleFlags() enrichment
        // of this exact response (see that function's own doc comment) --
        // this suite mocks the round trip at the fetch layer the same way
        // every other spec in this directory already mocks the
        // server-authoritative fields.
        isK9Model: true,
    });

    t.equals(findByText(h.getRoot(), 'K9').length, 1, 'role badge reads K9, not Certified Handler, when this client is currently wearing a K9 model');
});

t.test('PARTNERED viewer shows the Partnered badge; a non-partnered viewer shows No Partner', async () => {
    const partnered = await openTablet({
        ok: true,
        viewer: { citizenid: 'P1', name: 'A', isHighCommand: false, effectivePermissions: [], allowSelfGrant: false },
        certifications: [], xp: null, tierLabel: null, myFeatures: [],
        isPartnered: true,
    });
    t.equals(findByText(partnered.getRoot(), 'Partnered').length, 1);
    t.equals(findByText(partnered.getRoot(), 'No Partner').length, 0);

    const unpartnered = await openTablet({
        ok: true,
        viewer: { citizenid: 'P2', name: 'B', isHighCommand: false, effectivePermissions: [], allowSelfGrant: false },
        certifications: [], xp: null, tierLabel: null, myFeatures: [],
        isPartnered: false,
    });
    t.equals(findByText(unpartnered.getRoot(), 'No Partner').length, 1);
    t.equals(findByText(unpartnered.getRoot(), 'Partnered').length, 0);
});

// ======================================================================
// NO CERTIFICATION IS NOT AN EMPTY SHELL
// ======================================================================

t.test('a viewer with ZERO active certifications and no console access sees real guidance, not a blank screen -- and still has a working path to their own record', async () => {
    const h = await openTablet({
        ok: true,
        viewer: { citizenid: 'NEW1', name: 'New Recruit', isHighCommand: false, effectivePermissions: [], allowSelfGrant: false },
        certifications: [{ departmentKey: 'police', departmentLabel: 'Police', active: false, grantedBy: null, tier: null, expiresAtUnix: null, expired: false, specializations: [] }],
        xp: null, tierLabel: null, myFeatures: [],
    });

    t.equals(findByText(h.getRoot(), 'New Arrival').length, 1, 'role badge for a not-yet-certified viewer');
    t.equals(findByText(h.getRoot(), "You're not certified yet").length, 1, 'the explicit no-certification notice title is shown');
    t.isTrue(findByText(h.getRoot(), 'Ask a certifier or a High Command officer to certify you in a department. Once certified, your abilities and record will appear here.').length >= 1);
    // THE "PRE-FACE" STATE (this pass) -- a concrete next step, not just an
    // explanation of the current state, naming the two tabs this resource
    // already has for exactly this question.
    t.isTrue(findByText(h.getRoot(), 'Not sure how to get started? The Help tab walks you through it, and the Commands tab shows everything there is to earn.').length >= 1);
    t.equals(findByText(h.getRoot(), 'Open Command Console').length, 0, 'no console access for this viewer -- the quick action is correctly absent, never a dead-click');
    t.equals(findByText(h.getRoot(), 'Command Console').length, 0, 'the Console TAB is also absent for the same reason');

    // Still not a dead end: "My Record" is always reachable, and its own
    // screen already renders 'no_certifications'/'no_abilities' honestly
    // (see tests/... buildMyRecordScreen coverage elsewhere) rather than
    // erroring.
    t.equals(findByText(h.getRoot(), 'My Record').length, 1, 'the My Record tab is still present for every viewer, even this one');
    // Already on it -- one screen now (plan item A), so the department
    // renders honestly not-yet-certified without navigating anywhere.
    t.isTrue(findByText(h.getRoot(), 'Not certified').length >= 1, 'the record renders this department as honestly not-yet-certified, never an error or a blank screen');
});

t.test('a viewer with zero certifications who IS high command still sees the High Command Tools section (the notice is additive, never a replacement screen) -- navigated to Home explicitly, this pass auto-lands high command on Console by default', async () => {
    const h = await openTablet({
        ok: true,
        viewer: { citizenid: 'HC2', name: 'Overseer', isHighCommand: true, effectivePermissions: ['k9.access', 'k9.certify', 'k9.audit', 'k9.givexp'], allowSelfGrant: false },
        certifications: [], xp: null, tierLabel: null, myFeatures: [],
    }, {
        'tablet:requestRoster': () => ({ ok: true, rows: [], truncated: false }),
    });
    await goHome(h);
    t.equals(findByText(h.getRoot(), 'New Arrival').length, 0, 'isHighCommand takes priority over the uncertified role label');
    t.equals(findByText(h.getRoot(), 'High Command').length, 1);
    t.equals(findByText(h.getRoot(), 'High Command Tools').length, 1, 'still gets full admin access despite holding no certification personally');
    // certifications is an empty array here (zero departments configured
    // in this mock), so the certified-count chip is correctly omitted
    // entirely -- "0 of 0" would be meaningless noise, not a real state.
    t.equals(findAll(h.getRoot(), (n) => typeof n._textContent === 'string' && n._textContent.indexOf('of 0 departments') !== -1).length, 0);
});

// ======================================================================
// STATE AT A GLANCE
// ======================================================================

t.test('the certified-department count badge reflects the real numbers, and turns from the neutral to the positive colour class once at least one is active', async () => {
    const zeroActive = await openTablet({
        ok: true,
        viewer: { citizenid: 'C1', name: 'A', isHighCommand: false, effectivePermissions: [], allowSelfGrant: false },
        certifications: [
            { departmentKey: 'police', departmentLabel: 'Police', active: false, grantedBy: null, tier: null, expiresAtUnix: null, expired: false, specializations: [] },
            { departmentKey: 'fire', departmentLabel: 'Fire', active: false, grantedBy: null, tier: null, expiresAtUnix: null, expired: false, specializations: [] },
        ],
        xp: null, tierLabel: null, myFeatures: [],
    });
    t.equals(findByText(zeroActive.getRoot(), 'Certified in 0 of 2 departments').length, 1);
    t.equals(findAll(zeroActive.getRoot(), (n) => n._textContent === 'Certified in 0 of 2 departments' && n.classList && n.classList.contains('k9tablet-feature-state--global_off')).length, 1, 'zero-active state uses the SAME neutral/warning colour class every other screen uses for this meaning');

    const oneActive = await openTablet({
        ok: true,
        viewer: { citizenid: 'C2', name: 'B', isHighCommand: false, effectivePermissions: ['k9.access'], allowSelfGrant: false },
        certifications: [
            { departmentKey: 'police', departmentLabel: 'Police', active: true, grantedBy: 'X', tier: 'certified', expiresAtUnix: null, expired: false, specializations: [] },
            { departmentKey: 'fire', departmentLabel: 'Fire', active: false, grantedBy: null, tier: null, expiresAtUnix: null, expired: false, specializations: [] },
        ],
        xp: null, tierLabel: null, myFeatures: [],
    });
    t.equals(findByText(oneActive.getRoot(), 'Certified in 1 of 2 departments').length, 1);
    t.equals(findAll(oneActive.getRoot(), (n) => n._textContent === 'Certified in 1 of 2 departments' && n.classList && n.classList.contains('k9tablet-feature-state--available')).length, 1, 'at-least-one-active state uses the SAME positive colour class every other screen uses for this meaning');
});

t.test('the blocked-ability count badge shows the real count and the correct colour, and is entirely ABSENT when nothing is blocked', async () => {
    const blocked = await openTablet({
        ok: true,
        viewer: { citizenid: 'C3', name: 'A', isHighCommand: false, effectivePermissions: [], allowSelfGrant: false },
        certifications: [],
        xp: null, tierLabel: null,
        myFeatures: [
            { key: 'X', label: 'X', category: null, actionable: true, state: 'blocked' },
            { key: 'Y', label: 'Y', category: null, actionable: false, state: 'blocked' },
            { key: 'Z', label: 'Z', category: null, actionable: true, state: 'available' },
        ],
    });
    t.equals(findByText(blocked.getRoot(), '2 of your abilities are currently blocked').length, 1);
    t.equals(findAll(blocked.getRoot(), (n) => n._textContent === '2 of your abilities are currently blocked' && n.classList && n.classList.contains('k9tablet-feature-state--blocked')).length, 1);

    const notBlocked = await openTablet({
        ok: true,
        viewer: { citizenid: 'C4', name: 'B', isHighCommand: false, effectivePermissions: [], allowSelfGrant: false },
        certifications: [], xp: null, tierLabel: null,
        myFeatures: [{ key: 'Z', label: 'Z', category: null, actionable: true, state: 'available' }],
    });
    t.equals(findAll(notBlocked.getRoot(), (n) => typeof n._textContent === 'string' && n._textContent.indexOf('currently blocked') !== -1).length, 0, 'no blocked-count badge at all when the count is zero -- never a "0 blocked" badge nobody needs');
});

t.test('the abilities list on the landing screen shows EVERY ability with its own state -- not only the ready ones', async () => {
    // WAS: "the ready to use right now list shows ONLY actionable+available
    // abilities... and always offers a way to see the full list".
    //
    // That list was a filtered preview of the full one, with a link to the
    // screen carrying the full one. Plan item A merged those screens, so
    // keeping both would have shown every ready ability twice on a single
    // screen, and the link would have pointed at the screen the viewer is
    // already on. The preview is gone; the full list answers the same
    // question plus "what do I still have to earn", which is the more
    // useful half for a landing view.
    //
    // What must NOT be lost, and is asserted here: a not-yet-usable ability
    // is still visible AND still says why. Hiding it would answer "why
    // can't I do this" with silence -- the rule this plan's own
    // "deliberately left alone" section keeps.
    const h = await openTablet({
        ok: true,
        viewer: { citizenid: 'C5', name: 'A', isHighCommand: false, effectivePermissions: [], allowSelfGrant: false },
        certifications: [], xp: null, tierLabel: null,
        myFeatures: [
            { key: 'Ready1', label: 'Ready Ability', category: null, actionable: true, state: 'available' },
            { key: 'NotActionable', label: 'Status Only Ability', category: null, actionable: false, state: 'available' },
            { key: 'Blocked1', label: 'Blocked Ability', category: null, actionable: true, state: 'blocked' },
        ],
    });
    t.equals(findByText(h.getRoot(), 'Ready Ability').length, 1, 'a ready ability appears exactly once -- never twice, which a preview plus the full list would have caused');
    t.equals(findByText(h.getRoot(), 'Status Only Ability').length, 1, 'a status-only ability is listed too, with its own state');
    t.equals(findByText(h.getRoot(), 'Blocked Ability').length, 1, 'and so is a blocked one -- hiding it would answer "why can I not do this" with silence');
    t.equals(findByText(h.getRoot(), 'View all abilities').length, 0, 'no link to a separate full list: this IS the full list');
});

t.test('the landing screen carries the whole record -- certifications, both XP ladders, and abilities -- with no second tab to visit', async () => {
    // The merge itself (plan item A). Three tabs became one, so all four
    // sections must be on this one screen.
    const h = await openTablet({
        ok: true,
        viewer: { citizenid: 'C6', name: 'A', isHighCommand: false, effectivePermissions: [], allowSelfGrant: false },
        certifications: [], xp: 120, tierLabel: 'Veteran K9', handlerXp: null, handlerTierLabel: null,
        xpLadder: [{ label: 'Recruit K9', xp: 0 }, { label: 'Veteran K9', xp: 100 }],
        handlerXpLadder: [],
        myFeatures: [],
    });

    t.isTrue(findByText(h.getRoot(), 'Certifications').length >= 1, 'certifications section');
    t.isTrue(findByText(h.getRoot(), 'K9 Rank').length >= 1, 'the K9 ladder block');
    t.isTrue(findByText(h.getRoot(), 'Handler Rank').length >= 1, 'and the handler ladder block, both on this one screen');
    t.isTrue(findByText(h.getRoot(), 'This server does not track handler XP, so there is no rank to show here.').length >= 1,
        'the handler ladder says plainly that it is switched off -- null is not zero');
    t.isTrue(findByText(h.getRoot(), 'Abilities').length >= 1, 'abilities section');

    // And the two tabs that used to carry them are gone.
    t.equals(findByText(h.getRoot(), 'Home').length, 0, 'no separate Home tab');
    t.equals(findByText(h.getRoot(), 'Progression').length, 0, 'no separate Progression tab');
});

t.run();
