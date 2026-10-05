/*
    html/tests/tablet_command_reference_spec.js

    Covers the Command Reference screen (html/tablet.js's COMMAND_REFERENCE /
    buildCommandReferenceScreen() / commandReferenceStatus()) -- the
    "every command, no way for a player to discover them in-game" screen,
    shown to EVERY resolved viewer (handler or high command alike -- see
    buildTabs()'s own comment on why the Commands tab is unconditional,
    same as Home/My Record). The catalog's own size is intentionally never
    named here as a literal number (see this file's REAL_COMMAND_REFERENCE_COUNT
    below for why).

    Six scenarios, matching this pass's own acceptance criteria:
      1. The screen renders -- every catalog entry appears,
         grouped under its own category heading, with a live status badge.
      2. Filtering -- typing in the search box narrows the visible rows (and
         hides a category heading entirely once none of its rows match),
         typing something matching nothing shows the empty-state message.
      3. A HANDLER (certified, no special capability) sees a restricted
         admin-tier command marked unavailable, with a status distinct from
         (never confused with) an ordinary "not certified" reading.
      4. HIGH COMMAND sees every admin-tier command marked with the (Admin)
         badge -- shown to high command too, not hidden from them, per this
         task's own "high command sees everything, with the admin ones
         marked as such" instruction -- and available when nothing else
         blocks it.
      5. A feature that is blocked for this viewer, or switched off
         server-wide, overrides an otherwise-qualifying capability (proves
         `global_off`/`blocked` are checked BEFORE the capability check, not
         instead of it).
      6. Escaping -- a hostile string arriving via `data.strings` for one of
         this screen's own keys reaches the DOM only via textContent, never
         innerHTML, same proof technique as html/tests/tablet_xss_spec.js.
*/
'use strict';

const fs = require('fs');
const path = require('path');
const t = require('./testkit');
const { createHarness, jsonResponse } = require('./tablet-sandbox');
const { findByText, findAll, findByTag } = require('./tablet-dom-stub');

// DERIVED, NOT HARDCODED: the real COMMAND_REFERENCE array is declared
// `var` inside html/tablet.js's own top-level IIFE (see that file's header
// "THE SECURITY RULE"), so it is not reachable as a property on
// tablet-sandbox.js's vm context -- there is no live handle to read
// `.length` off of. Rather than hardcode the catalog's current size (which
// silently goes stale the moment a command is added or removed, exactly
// the "someone adds command #37 and the reference silently lies" trap
// tests/commandreferenceregistry_spec.lua's own header names), this reads
// html/tablet.js's raw source text and counts real `command: '...'`
// entries the SAME way tests/commandreferenceregistry_spec.lua's own
// "no duplicate command names" test already does on the Lua side, and the
// same raw-text-read convention tablet_branding_placement_spec.js and
// tablet_bridge_spec.js already use elsewhere in this directory. This
// keeps the "every catalog entry renders" assertion below tied to the
// SAME array buildCommandReferenceScreen() reads, so a real rendering bug
// (dropping or duplicating rows) still fails it -- it just never needs a
// manual bump when the catalog itself legitimately grows.
//
// WIDENED, THIS PASS: the character class below used to be `[a-z0-9_]+`,
// which silently missed every command namespaced under this resource's own
// `john-k9:` prefix (a `:`, and for several of them, camelCase letters
// too -- both outside that class) -- the exact same blind spot
// tests/commandreferenceregistry_spec.lua's own Lua-side extractor had,
// fixed in the same pass. `[a-zA-Z0-9_:-]+` (the hyphen is for john-k9:) matches both the plain `k9x`
// shape and the namespaced one.
// Reads tablet-catalog.js, not tablet.js: the catalog literals moved there
// on 2026-09-02 (see that file's own header).
const tabletJsSourceForCommandCount = fs.readFileSync(path.join(__dirname, '..', 'tablet-catalog.js'), 'utf8');
function countRealCommandReferenceEntries() {
    const startPos = tabletJsSourceForCommandCount.indexOf('var COMMAND_REFERENCE = [');
    if (startPos === -1) throw new Error('tablet_command_reference_spec: var COMMAND_REFERENCE = [ not found in html/tablet.js');
    const endPos = tabletJsSourceForCommandCount.indexOf('\n    ];', startPos);
    if (endPos === -1) throw new Error('tablet_command_reference_spec: closing "];" for COMMAND_REFERENCE not found in html/tablet.js');
    const body = tabletJsSourceForCommandCount.slice(startPos, endPos);
    const matches = body.match(/command:\s*'[a-zA-Z0-9_:-]+'/g);
    if (!matches) throw new Error('tablet_command_reference_spec: matched zero command entries -- extraction pattern is stale');
    return matches.length;
}
const REAL_COMMAND_REFERENCE_COUNT = countRealCommandReferenceEntries();

// DERIVED, NOT HARDCODED (docs/history/COMMAND_CONSOLIDATION_SPEC.md merges keep moving
// this number -- a hardcoded count here has already gone stale once this
// same session, which is exactly the trap REAL_COMMAND_REFERENCE_COUNT
// above exists to avoid; this is the identical fix applied to the
// admin-tier subset). Counts `adminOnly: true` entries within the SAME
// COMMAND_REFERENCE array body countRealCommandReferenceEntries() already
// isolates -- tied to the real source, so a future merge/split of an
// admin-tier command changes this count automatically, with no comment to
// remember to update.
function countAdminOnlyCommandReferenceEntries() {
    const startPos = tabletJsSourceForCommandCount.indexOf('var COMMAND_REFERENCE = [');
    if (startPos === -1) throw new Error('tablet_command_reference_spec: var COMMAND_REFERENCE = [ not found in html/tablet.js');
    const endPos = tabletJsSourceForCommandCount.indexOf('\n    ];', startPos);
    if (endPos === -1) throw new Error('tablet_command_reference_spec: closing "];" for COMMAND_REFERENCE not found in html/tablet.js');
    const body = tabletJsSourceForCommandCount.slice(startPos, endPos);
    const matches = body.match(/adminOnly:\s*true/g);
    if (!matches) throw new Error('tablet_command_reference_spec: matched zero adminOnly entries -- extraction pattern is stale');
    return matches.length;
}
const ADMIN_TIER_COMMAND_REFERENCE_COUNT = countAdminOnlyCommandReferenceEntries();

function routeFetch(handlers) {
    return function (url, init) {
        const name = url.split('/').pop();
        const h = handlers[name];
        if (!h) return Promise.reject(new Error('tablet_command_reference_spec: unhandled NUI callback ' + name));
        return Promise.resolve(jsonResponse(h()));
    };
}

async function settle(times) {
    for (let i = 0; i < (times || 3); i++) await new Promise((r) => setImmediate(r));
}

// ======================================================================
// "EVERY GATED FEATURE IS ON" -- DERIVED FROM tablet.js, NOT HAND-TYPED.
//
// From 2026-09-01 this screen HIDES a command whose gated feature is off
// server-wide (owner: "if something is turned off in the config nothing on
// the tablet shows up" -- see commandReferenceIsVisible()). A missing key
// in myFeatures[] resolves to 'global_off', so the `myFeatures: []` these
// fixtures used to pass now hides almost the entire catalog, and the tests
// that simply want the reference rendered would be asserting against 17
// rows instead of 64.
//
// So the default fixture now says every gated feature is on. Built by
// reading the REAL gate.featureKey values out of html/tablet.js -- the same
// raw-source technique countRealCommandReferenceEntries() above already
// uses -- so a gate added or renamed later is covered with no edit here,
// which is the whole reason that convention exists in this file.
//
// Tests that care about a feature being OFF still pass their own explicit
// myFeatures and are unaffected.
// ======================================================================
function everyGatedFeatureAvailable() {
    const startPos = tabletJsSourceForCommandCount.indexOf('var COMMAND_REFERENCE = [');
    if (startPos === -1) throw new Error('tablet_command_reference_spec: var COMMAND_REFERENCE = [ not found in html/tablet.js');
    const endPos = tabletJsSourceForCommandCount.indexOf('\n    ];', startPos);
    const body = tabletJsSourceForCommandCount.slice(startPos, endPos);

    const keys = new Set();
    for (const m of body.matchAll(/featureKey:\s*'([^']+)'/g)) keys.add(m[1]);
    if (keys.size === 0) throw new Error('tablet_command_reference_spec: matched zero gate featureKeys -- extraction pattern is stale');

    return Array.from(keys).map((key) => ({ key, category: null, actionable: true, state: 'available' }));
}
const ALL_FEATURES_ON = everyGatedFeatureAvailable();

/**
 * ALL_FEATURES_ON with named keys changed or removed.
 *
 * A test about ONE feature being off should not accidentally be a test
 * about forty others being off too -- which is what passing a one-element
 * myFeatures now means, since an absent key resolves to 'global_off' and a
 * globally-off command is hidden entirely.
 *
 * @param {Object<string, ?string>} overrides key -> new state, or key ->
 *        null to drop the entry completely (the "removed from
 *        Config.Features" shape, e.g. real production ScentTrailHunt)
 * @returns {Array<object>}
 */
function featuresOn(overrides) {
    const dropped = new Set();
    const restated = new Map();
    for (const [key, value] of Object.entries(overrides || {})) {
        if (value === null) dropped.add(key); else restated.set(key, value);
    }
    return ALL_FEATURES_ON
        .filter((f) => !dropped.has(f.key))
        .map((f) => (restated.has(f.key) ? Object.assign({}, f, { state: restated.get(f.key) }) : f));
}

function myRecordHandler(viewer, myFeatures) {
    return () => ({
        ok: true,
        viewer: viewer,
        certifications: [],
        xp: null,
        tierLabel: null,
        myFeatures: myFeatures || [],
    });
}

const HANDLER_VIEWER = { citizenid: 'H1', name: 'Rex Handler', isHighCommand: false, effectivePermissions: ['k9.access'] };
const UNCERTIFIED_VIEWER = { citizenid: 'U1', name: 'New Arrival', isHighCommand: false, effectivePermissions: [] };
const HIGH_COMMAND_VIEWER = { citizenid: 'HC1', name: 'Chief', isHighCommand: true, effectivePermissions: ['k9.access', 'k9.certify', 'k9.audit', 'k9.givexp'] };

async function openCommandsScreen(h) {
    h.postMessage('tablet:open', {});
    await settle();
    findByText(h.getRoot(), 'Guide')[0].click();
    await settle();
}

function statusBadges(h) {
    return findAll(h.getRoot(), (n) => n.classList && n.classList.contains('k9tablet-feature-state'));
}

function statusBadgeFor(h, commandText) {
    // The command's own <span> (its usage text, e.g. "/k9deploykennel")
    // sits in the first <td> of its row; the status badge is the last
    // <span> in that same <tr>.
    const cmdSpan = findByText(h.getRoot(), commandText)[0];
    t.isDefined(cmdSpan, 'expected to find a rendered command span for ' + commandText);
    let row = cmdSpan;
    while (row && row.tagName !== 'tr') row = row.parentNode;
    t.isDefined(row, 'expected an ancestor <tr> for ' + commandText);
    const badges = findAll(row, (n) => n.classList && n.classList.contains('k9tablet-feature-state'));
    t.equals(badges.length, 1, 'exactly one status badge in the row for ' + commandText);
    return badges[0];
}

t.test('screen rendering: every catalog entry renders, one status badge each, under category headings', async () => {
    const h = createHarness({
        fetchImpl: routeFetch({
            'tablet:requestMyRecord': myRecordHandler(HIGH_COMMAND_VIEWER, ALL_FEATURES_ON),
        }),
    });
    await openCommandsScreen(h);

    t.equals(findByText(h.getRoot(), 'Command Reference').length, 1, 'the screen heading renders');
    t.isTrue(findByText(h.getRoot(), 'Combat & Restraint').length >= 1, 'a category heading renders');
    t.isTrue(findByText(h.getRoot(), 'Field Gear & Equipment').length >= 1, 'another category heading renders');
    t.equals(statusBadges(h).length, REAL_COMMAND_REFERENCE_COUNT, 'one status badge per real COMMAND_REFERENCE entry (derived from html/tablet.js itself, not a hardcoded count -- see this file\'s own header)');
    t.isTrue(findByText(h.getRoot(), '/k9sit').length === 1, 'a specific command\'s exact usage string renders verbatim');
    t.equals(findByText(h.getRoot(), 'Certification Management').length, 0, 'certifying is on the tablet only -- no certification commands are listed');
});

t.test('filtering: typing in the search box narrows to matching rows and hides an emptied category heading; a non-matching query shows the empty-state message', async () => {
    const h = createHarness({
        fetchImpl: routeFetch({
            'tablet:requestMyRecord': myRecordHandler(HIGH_COMMAND_VIEWER, ALL_FEATURES_ON),
        }),
    });
    await openCommandsScreen(h);

    const search = findByTag(h.getRoot(), 'input')[0];
    t.isDefined(search, 'the search box renders');

    search.typeValue('bonetool');
    await settle();
    t.equals(statusBadges(h).length, 1, 'only the one matching command remains');
    t.equals(findByText(h.getRoot(), 'Developer Tools').length, 1, 'its own category heading still shows');
    t.equals(findByText(h.getRoot(), 'Certification Management').length, 0, 'an emptied category heading is not shown at all');

    search.typeValue('this-matches-absolutely-nothing-xyz');
    await settle();
    t.equals(statusBadges(h).length, 0, 'no rows remain');
    // The message is about the FILTER, not about the command list. That
    // list is a fixed, non-empty constant in html/tablet.js, so "there are
    // no commands" could never be true here -- and an operator who had left
    // a filter on from a minute ago needs to be told which of the two they
    // are looking at. Changed 2026-09-01 alongside the same fix on the
    // abilities list; the old text was `cmdref_empty`.
    t.equals(
        findByText(h.getRoot(), 'No commands match that filter. Clear it to see the full list again.').length, 1,
        'the empty state names the filter as the reason'
    );
    t.equals(findByText(h.getRoot(), 'Clear filter').length, 1, 'and puts the way out of the dead end on screen');
});

t.test('the command filter is labelled as optional, and reports what it is hiding only while it hides something', async () => {
    // Companion to the test above -- see buildListFilterBar() in
    // html/tablet.js. A bare input above a long grouped list reads as "type
    // here to find things"; this list is meant to be browsed by section.
    const h = createHarness({
        fetchImpl: routeFetch({
            'tablet:requestMyRecord': myRecordHandler(HIGH_COMMAND_VIEWER, ALL_FEATURES_ON),
        }),
    });
    await openCommandsScreen(h);

    const label = findAll(h.getRoot(), (n) => n.classList && n.classList.contains('k9tablet-feature-filter-label'))[0];
    t.isDefined(label, 'the filter has a real <label>, not only a placeholder');
    t.contains(label.textContent.toLowerCase(), 'optional', 'and it says so out loud');

    t.equals(
        findAll(h.getRoot(), (n) => n.classList && n.classList.contains('k9tablet-feature-filter-count')).length, 0,
        'unfiltered, it claims nothing -- showing all of them needs no readout'
    );

    const search = findByTag(h.getRoot(), 'input')[0];
    search.typeValue('bonetool');
    await settle();

    const count = findAll(h.getRoot(), (n) => n.classList && n.classList.contains('k9tablet-feature-filter-count'))[0];
    t.isDefined(count, 'filtered, the readout appears');
    t.isTrue(/^Showing 1 of \d+$/.test(count.textContent), 'and states both numbers: ' + count.textContent);
});

t.test('a HANDLER (certified, no special capability) does not see a high-command-only command at all -- only what they can use is listed', async () => {
    const h = createHarness({
        fetchImpl: routeFetch({
            'tablet:requestMyRecord': myRecordHandler(HANDLER_VIEWER, featuresOn({ DeployableKennel: 'available', BoneSweepDevTool: 'available' })),
        }),
    });
    await openCommandsScreen(h);
    t.equals(findByText(h.getRoot(), '/k9bonetool <goto|next|prev|test|stop|known|help> [value]').length, 0, 'the high-command-only dev tool is left out for a handler');
    t.equals(statusBadgeFor(h, '/k9deploykennel')._textContent, 'Available', 'what they can use is listed and says so');
});

t.test('an UNCERTIFIED viewer (no k9.access at all) does not see handler-tier commands; an open command with no personal gate is still listed', async () => {
    const h = createHarness({
        fetchImpl: routeFetch({
            'tablet:requestMyRecord': myRecordHandler(UNCERTIFIED_VIEWER, ALL_FEATURES_ON),
        }),
    });
    await openCommandsScreen(h);
    t.equals(findByText(h.getRoot(), '/k9deploykennel').length, 0, 'a certification-gated command is left out');
    t.equals(statusBadgeFor(h, '/k9dropfetchball')._textContent, 'Available', 'an open-tier command (no HasK9Access check in its real handler) is listed for anyone');
});

t.test('HIGH COMMAND sees every admin-tier command, marked with the (Admin) badge and Available when nothing else blocks it', async () => {
    const h = createHarness({
        fetchImpl: routeFetch({
            'tablet:requestMyRecord': myRecordHandler(HIGH_COMMAND_VIEWER, featuresOn({ BoneSweepDevTool: 'available' })),
        }),
    });
    await openCommandsScreen(h);
    const adminBadges = findAll(h.getRoot(), (n) => n._textContent === ' (Admin)');
    t.equals(adminBadges.length, ADMIN_TIER_COMMAND_REFERENCE_COUNT, 'every admin-tier command carries the (Admin) marker');
    t.equals(statusBadgeFor(h, '/k9bonetool <goto|next|prev|test|stop|known|help> [value]')._textContent, 'Available');
});

t.test('a server-wide-disabled feature is HIDDEN outright, even from a high-command viewer who otherwise qualifies', async () => {
    const h = createHarness({
        fetchImpl: routeFetch({
            'tablet:requestMyRecord': myRecordHandler(HIGH_COMMAND_VIEWER, featuresOn({ BoneSweepDevTool: 'global_off' })),
        }),
    });
    await openCommandsScreen(h);
    t.equals(findByText(h.getRoot(), '/k9bonetool <goto|next|prev|test|stop|known|help> [value]').length, 0, 'the globally-off command is gone');
    t.isTrue(findByText(h.getRoot(), '/k9sit').length > 0, 'commands whose features are still on are unaffected');
});

t.test('a per-person block hides a command even for a high-command viewer', async () => {
    const h = createHarness({
        fetchImpl: routeFetch({
            'tablet:requestMyRecord': myRecordHandler(HIGH_COMMAND_VIEWER, featuresOn({ BoneSweepDevTool: 'blocked' })),
        }),
    });
    await openCommandsScreen(h);
    t.equals(findByText(h.getRoot(), '/k9bonetool <goto|next|prev|test|stop|known|help> [value]').length, 0, 'a personal block wins, and the command is left out');
});

t.test('a blocked handler-tier feature is left out for a certified handler who otherwise holds k9.access', async () => {
    const h = createHarness({
        fetchImpl: routeFetch({
            'tablet:requestMyRecord': myRecordHandler(HANDLER_VIEWER, featuresOn({ PropAttachments: 'blocked' })),
        }),
    });
    await openCommandsScreen(h);
    t.equals(findByText(h.getRoot(), '/k9propattach').length, 0);
});

t.test('THE ABSENT-KEY BUG (regression): a featureKey entirely MISSING from myFeatures[] -- the real shape of a Config.Features key that was removed or never added, e.g. real production ScentTrailHunt -- must report unavailable, never fall through to Available', async () => {
    // THE SHAPE THAT MATTERS, per this bug's own root cause: server/tablet.lua's
    // BuildMyFeaturesArray enumerates `pairs(Config.Features)` fresh every
    // call, so a key that does not exist in Config.Features AT ALL (not
    // even set to `false`) never gets an array entry -- it is not sent as
    // some other falsy value, it is simply ABSENT from the array. That is
    // reproduced here by omitting 'ScentTrailHunt' from myFeatures
    // entirely -- NOT by adding an entry with `state: false`
    // or `state: 'global_off'` (a synthetic Config table with the key
    // manually set, which is exactly the shape every prior test for this
    // command used, and exactly why none of them ever caught this).
    //
    // A HANDLER_VIEWER (real K9 access) is used deliberately: the bug only
    // ever manifested when `hasAccess` is true -- commandReferenceStatus's
    // own 'access' branch already returns 'not_certified' before ever
    // consulting a featureKey when the viewer lacks access, so an
    // uncertified viewer could never have exposed this fallthrough.
    // Everything on EXCEPT the key under test, which is dropped from
    // the array entirely -- the precise shape described above. Using
    // featuresOn() rather than a one-element array keeps this a test about
    // one absent key, instead of accidentally also being a test about
    // every other feature being off.
    const h = createHarness({
        fetchImpl: routeFetch({
            'tablet:requestMyRecord': myRecordHandler(HANDLER_VIEWER, featuresOn({
                ScentTrailHunt: null,
                // CONTROL 1 -- a featureKey that IS present and true. Proves
                // this test's own harness can still show 'Available' for a
                // real on switch, so a change that hid or disabled EVERY
                // command (not just an absent-key one) fails here.
                DeployableKennel: 'available',
            })),
        }),
    });
    await openCommandsScreen(h);

    // CONTROL 2 -- an ungated command (no featureKey at all) must stay
    // Available regardless of anything myFeatures does or does not contain.
    // Without this control, a fix that collapsed "no featureKey" and
    // "featureKey absent from config" into the same "unavailable" answer
    // would pass every assertion below it and still be a real, different bug.
    const dropBadge = statusBadgeFor(h, '/k9dropfetchball');
    t.equals(dropBadge._textContent, 'Available', 'CONTROL: an ungated (no featureKey) command stays Available no matter what myFeatures contains');

    // CONTROL 1's assertion.
    const kennelBadge = statusBadgeFor(h, '/k9deploykennel');
    t.equals(kennelBadge._textContent, 'Available', 'CONTROL: a featureKey present and available in myFeatures still reports Available');

    // THE BUG ITSELF. Before the original fix, myFeatureState(key) returned
    // null for a key not found in myFeatures[], and both the 'access' and
    // 'capability'/'highCommandOnly' branches of commandReferenceStatus
    // treated that null as "no gate matched" and fell through to
    // 'available' -- the tablet's own trusted Command Reference reporting
    // a permanently, unconditionally off command as usable.
    //
    // WHAT CHANGED 2026-09-01: an absent key still resolves to 'global_off'
    // exactly as before -- that resolution is the fix and it is untouched --
    // but a globally-off command is now HIDDEN rather than listed with a
    // 'Disabled server-wide' badge (owner: "if something is turned off in
    // the config nothing on the tablet shows up"). Absent from the screen
    // is strictly further from the bug than 'Disabled server-wide' was:
    // the failure being guarded against is this row reading as AVAILABLE,
    // and a row that does not exist cannot claim anything.
    //
    // The fixture simulates absence by dropping the key from myFeatures,
    // which is the exact wire shape a genuinely-missing Config.Features key
    // produces, whatever config.lua happens to say today. ScentTrailHunt is
    // genuinely absent from config.lua.
    t.equals(
        findByText(h.getRoot(), '/k9nosehunt [stop]').length, 0,
        'THE BUG: /k9nosehunt\'s gate.featureKey (ScentTrailHunt) is absent from Config.Features -- it must never read as Available; it is now hidden outright'
    );
});

t.test('a hostile string arriving via data.strings for a Command Reference key reaches the DOM only via textContent, never innerHTML', async () => {
    const malicious = '<img src=x onerror="window.__xss_pwned=true">';
    const h = createHarness({
        fetchImpl: routeFetch({
            'tablet:requestMyRecord': myRecordHandler(HIGH_COMMAND_VIEWER, ALL_FEATURES_ON),
        }),
    });
    h.postMessage('tablet:open', { strings: { cmdref_k9audit_does: malicious, cmdref_heading: malicious } });
    await settle();
    findByText(h.getRoot(), 'Guide')[0].click();
    await settle();

    const matches = findAll(h.getRoot(), (n) => n._textContent === malicious);
    t.isTrue(matches.length >= 1, 'the malicious string reaches the DOM verbatim as textContent somewhere on this screen');

    const innerHTMLWrites = findAll(h.getRoot(), () => true).reduce((sum, el) => sum + (el.innerHTMLWriteCount || 0), 0);
    t.equals(innerHTMLWrites, 0, 'innerHTML must never be written anywhere on this page for a malicious Command Reference string');
});

// ======================================================================
// THE STATUS COLUMN WHEN THE SERVER SENDS NO FEATURE LIST (2026-09-01) --
// the remaining half of the owner's "everything in the command console in
// the status says disabled" report.
//
// Every badge resolves out of state.myRecord.myFeatures, and a key not
// found in that array reads as 'global_off' -- correct, because a key
// absent from Config.Features really is off server-side.
//
// But loadMyRecord() used to normalise the field as `result.myFeatures ||
// []`, which collapsed "the server did not send a list" into "the server
// sent an empty list". Every key was then "not found", and the whole screen
// reported "Disabled server-wide" on a completely healthy server -- which
// to anyone reading it is indistinguishable from the resource being off.
//
// It now keeps null for absent, [] for genuinely-empty, and the badges
// answer 'unknown' for the first. These tests pin that, plus the banner
// that explains it -- because 'unknown' on every row, with no reason given
// and nothing to press, is only marginally better than the wrong answer.
//
// NOTE ON REACHABILITY: state.viewer and state.myRecord are assigned
// together from one response, and the whole panel renders a viewer gate
// while state.viewer is null. So "no record at all" never reaches this
// screen -- the case that does is a record that arrived WITHOUT a usable
// feature list, which is what these fixtures produce.
// ======================================================================

/** A viewer that resolves normally, with a myFeatures field we control. */
function recordWithFeatures(myFeatures) {
    return () => {
        const payload = { ok: true, viewer: HIGH_COMMAND_VIEWER, certifications: [], xp: null, tierLabel: null };
        if (myFeatures !== undefined) payload.myFeatures = myFeatures;
        return payload;
    };
}

async function openCommandsWith(myFeatures) {
    const h = createHarness({ fetchImpl: routeFetch({ 'tablet:requestMyRecord': recordWithFeatures(myFeatures) }) });
    await openCommandsScreen(h);
    return h;
}

function allText(h) {
    return findAll(h.getRoot(), () => true)
        .map((n) => (typeof n.textContent === 'string' ? n.textContent : ''))
        .join(' \n ');
}

t.test('THE BUG: a record that arrives with NO myFeatures field must not report every command "Disabled server-wide"', async () => {
    const h = await openCommandsWith(undefined);

    const badges = statusBadges(h).map((n) => n._textContent);
    t.isTrue(badges.length > 0, 'sanity: the command rows rendered');
    t.equals(
        badges.filter((b) => b === 'Disabled server-wide').length, 0,
        'not one badge claims the feature is switched off server-wide -- the server never said that, it said nothing'
    );
});

t.test('...it says the status is not known yet instead, which is the only honest answer', async () => {
    const h = await openCommandsWith(undefined);
    const badges = statusBadges(h).map((n) => n._textContent);
    t.isTrue(badges.indexOf('Still loading…') !== -1, 'the badges read as unresolved rather than as a verdict');
});

t.test('...and the screen explains WHY, with something to press -- not a silent wall of identical badges', async () => {
    const h = await openCommandsWith(undefined);
    const texts = allText(h);
    // Without this the fix only swaps one uniform wall of badges for
    // another: still no reason given, still nothing to do about it.
    t.isTrue(
        /Still loading your record|Your record could not be loaded/.test(texts),
        'the screen states why the Status column is not answering'
    );
});

t.test('a record that genuinely reports an EMPTY feature list reads as off -- absent and empty stay different', async () => {
    // The other side of the distinction, and it is still a real one -- it
    // just shows up differently since 2026-09-01. An empty array is the
    // server actually saying "there are none", so every gated command
    // resolves to 'global_off', and a globally-off command is now HIDDEN
    // rather than badged. An ABSENT field resolves to 'unknown' instead,
    // and unknown is never hidden (see commandReferenceIsVisible) -- so the
    // two cases are still told apart, and told apart more visibly than
    // before: one empties the gated rows, the other shows them all as
    // still-loading.
    const h = await openCommandsWith([]);

    const badges = statusBadges(h).map((n) => n._textContent);
    t.isTrue(badges.length > 0, 'sanity: the UNGATED commands still render -- an empty list must not blank the whole screen');
    t.equals(
        badges.filter((b) => b === 'Still loading…').length, 0,
        'an explicitly empty list is an ANSWER, not a missing one -- nothing may read as still loading'
    );

    // The gated commands are gone, which is what "off" now looks like.
    t.equals(
        findByText(h.getRoot(), '/k9nosehunt [stop]').length, 0,
        'a gated command resolves to off against an empty list, and an off command is hidden'
    );

    // And the contrast with the absent case, asserted in the same test so
    // the two can never quietly converge.
    const absent = await openCommandsWith(undefined);
    const absentBadges = statusBadges(absent).map((n) => n._textContent);
    t.isTrue(
        absentBadges.indexOf('Still loading…') !== -1,
        'an ABSENT list still reads as unknown, never as off -- so it hides nothing'
    );
    t.isTrue(
        statusBadges(absent).length > badges.length,
        'and therefore still lists the gated commands the empty-list case hid'
    );
});

t.test('a normal record with real features resolves real statuses -- the guard never fires on a healthy server', async () => {
    // The control that matters most: none of the above may cost a working
    // server its real status column.
    const h = await openCommandsWith([
        { key: 'BiteAndHold', category: 'combat', state: 'available' },
        { key: 'DeployableKennel', category: 'gear', state: 'available' },
    ]);
    const badges = statusBadges(h).map((n) => n._textContent);
    t.isTrue(badges.indexOf('Available') !== -1, 'real statuses still resolve');
    t.equals(badges.filter((b) => b === 'Still loading…').length, 0, 'nothing is stuck on unknown');
    t.equals(
        allText(h).indexOf('Still loading your record'), -1,
        'and no banner is shown on a healthy load'
    );
});

t.run();
