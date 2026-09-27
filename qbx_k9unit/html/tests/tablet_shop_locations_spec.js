/*
    html/tests/tablet_shop_locations_spec.js

    Covers the K9 Supply Shop location management screen (its own tab, high
    command OR a delegated 'k9.equipmentshoplocations' grant --
    server/equipmentshop.lua's own CanManageShopLocations(source):
    IsHighCommand(source) OR HasPermission(citizenid,
    'k9.equipmentshoplocations') == true, tests/equipmentshop_spec.lua:839.
    Client-side gate: html/tablet.js's canManageShopLocations()). Owner's
    own words: "make the shop a dog ped and i can change the locations in
    the config or add more locations remove locations etc along with in
    the high command tablet."

    Server contract verified against server/equipmentshop.lua directly (not
    assumed): GetLocations returns `{ok, locations: table<string,
    ShopLocation>}` keyed 'cfg:<n>' (config.lua, read-only) or 'db:<id>'
    (runtime, editable/removable); Add/Move/RemoveLocation each return
    `{ok, locations?, reason?}`, `reason` renamed to `error` by
    client/tablet.lua's TranslateReasonResult before it ever reaches this
    page -- so every failure fixture below uses `error`, never `reason`.

    COORDINATES are asserted to NEVER be requested of or sent BY this page
    at all -- see the "Add"/"Move Here" tests below, which only ever send
    label/model/scenario or a bare `useCurrentPosition: true` flag,
    confirming client/tablet.lua (not this file) is the one capturing the
    operator's real position, per this task's own instruction.

    Every gate below is asserted as a CONVENIENCE, per html/tablet.js's own
    THE SECURITY RULE -- covered server-side in
    tests/clienttabletequipmentshop_spec.lua/tests/equipmentshop_spec.lua.
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
        if (!h) return Promise.reject(new Error('tablet_shop_locations_spec: unhandled NUI callback ' + name));
        return Promise.resolve(jsonResponse(h(body)));
    };
}

const HIGH_COMMAND_VIEWER = { citizenid: 'HC1', name: 'Chief', isHighCommand: true, effectivePermissions: ['k9.access', 'k9.certify', 'k9.audit', 'k9.givexp'], allowSelfGrant: false };
const CONSOLE_ONLY_VIEWER = { citizenid: 'OFFICER1', name: 'Officer', isHighCommand: false, effectivePermissions: ['k9.certify'], allowSelfGrant: false };
// Holds the delegated capability but is NOT high command -- server/
// equipmentshop.lua's own CanManageShopLocations admits this exact
// citizenid (see this file's header). ResolveEffectivePermissions unions a
// held custom key into effectivePermissions today, no server change
// needed -- see canManageShopLocations()'s own doc comment.
const DELEGATED_SHOP_LOCATIONS_VIEWER = { citizenid: 'DELEGATE1', name: 'Delegate', isHighCommand: false, effectivePermissions: ['k9.certify', 'k9.equipmentshoplocations'], allowSelfGrant: false };

async function settle(times) {
    for (let i = 0; i < (times || 3); i++) await new Promise((r) => setImmediate(r));
}

function baseHandlers(overrides) {
    return Object.assign({
        'tablet:requestMyRecord': () => ({ ok: true, viewer: HIGH_COMMAND_VIEWER, certifications: [], xp: null, tierLabel: null, myFeatures: [] }),
        'tablet:getTheme': () => ({ ok: true, theme: { primaryColor: '#2563eb', accentColor: '#f59e0b', backgroundColor: '#111827', textColor: '#f9fafb', density: 'comfortable', headerTitle: 'K9 Command Tablet' } }),
    }, overrides || {});
}

async function openTablet(h, extraOpenData) {
    h.postMessage('tablet:open', Object.assign({ shopLocationsEnabled: true }, extraOpenData || {}));
    await settle();
}

function findInput(root, predicate) {
    return findAll(root, (n) => n.tagName === 'input' && predicate(n))[0];
}

// ======================================================================
// GATING + DYNAMIC LIST
// ======================================================================

t.test('a non-high-command console user never sees the Shop Locations tab', async () => {
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:requestMyRecord': () => ({ ok: true, viewer: CONSOLE_ONLY_VIEWER, certifications: [], xp: null, tierLabel: null, myFeatures: [] }),
        })),
    });
    await openTablet(h);
    t.equals(findByText(h.getRoot(), 'K9 Supply Shop').length, 0);
});

t.test('a non-high-command officer holding a delegated k9.equipmentshoplocations grant DOES see the Shop Locations tab, and can open it', async () => {
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:requestMyRecord': () => ({ ok: true, viewer: DELEGATED_SHOP_LOCATIONS_VIEWER, certifications: [], xp: null, tierLabel: null, myFeatures: [] }),
            'tablet:equipmentShopGetLocations': () => ({ ok: true, locations: {} }),
        })),
    });
    await openTablet(h);
    t.equals(findByText(h.getRoot(), 'Server Settings').length, 1, 'the Server Settings tab is visible to a delegated non-high-command officer');
    openSettingsSection(h.getRoot(), 'K9 Supply Shop');
    t.equals(findByClass(h.getRoot(), 'k9tablet-settings-sections')[0].children.length, 1, 'and holds exactly the one section this delegate may change');
    await settle();
    t.isTrue(findByText(h.getRoot(), 'Add Location Here').length >= 1, 'the real screen renders, not a dead end');
});

t.test('DYNAMIC LIST: locations rendered come entirely from tablet:equipmentShopGetLocations -- a cfg: row shows Config/no controls, a db: row shows Runtime/Edit+Move+Remove', async () => {
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:equipmentShopGetLocations': () => ({
                ok: true,
                locations: {
                    'cfg:1': { x: 100.123, y: 200.456, z: 30, heading: 90, model: 'a_c_shepherd', scenario: '', label: 'Downtown K9 Supply' },
                    'db:7': { x: -50, y: 60, z: 25, heading: 180, model: 'a_c_husky', scenario: '', label: 'Zzyzx Novel Outpost' },
                },
            }),
        })),
    });
    await openTablet(h);
    openSettingsSection(h.getRoot(), 'K9 Supply Shop');
    await settle();

    t.isTrue(findByText(h.getRoot(), 'Downtown K9 Supply').length >= 1);
    t.isTrue(findByText(h.getRoot(), 'Zzyzx Novel Outpost').length >= 1, 'a location this test invented on the fly renders correctly -- proves no hardcoded list');
    t.isTrue(findByText(h.getRoot(), '100.1, 200.5, 30.0').length >= 1, 'coordinates formatted to one decimal place');
    t.isTrue(findByText(h.getRoot(), 'a_c_husky').length >= 1);

    t.isTrue(findByText(h.getRoot(), 'Config').length >= 1);
    t.isTrue(findByText(h.getRoot(), 'Runtime').length >= 1);

    // cfg: row: no Edit/Move Here/Remove -- only the config.lua note.
    t.equals(findByText(h.getRoot(), 'Edit').length, 1, 'only the db: row offers Edit');
    t.equals(findByText(h.getRoot(), 'Move Here').length, 1, 'only the db: row offers Move Here');
    t.equals(findByText(h.getRoot(), 'Remove').length, 1, 'only the db: row offers Remove');
    t.isTrue(findByText(h.getRoot(), 'Defined in config.lua -- edit that file and restart the resource to change or remove this one.').length >= 1);
});

t.test('empty list shows the empty-state note, not a crash', async () => {
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:equipmentShopGetLocations': () => ({ ok: true, locations: {} }),
        })),
    });
    await openTablet(h);
    openSettingsSection(h.getRoot(), 'K9 Supply Shop');
    await settle();
    t.isTrue(findByText(h.getRoot(), 'No shop locations configured yet.').length >= 1);
});

t.test('shopLocationsEnabled=false shows the disabled note (list still fetched/shown regardless)', async () => {
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:equipmentShopGetLocations': () => ({ ok: true, locations: {} }),
        })),
    });
    h.postMessage('tablet:open', { shopLocationsEnabled: false });
    await settle();
    openSettingsSection(h.getRoot(), 'K9 Supply Shop');
    await settle();
    t.isTrue(findByText(h.getRoot(), 'The K9 Supply Shop is disabled server-wide. Existing locations are shown for reference only.').length >= 1);
});

t.test('a load failure shows the error and a Retry button that re-fetches', async () => {
    let calls = 0;
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:equipmentShopGetLocations': () => {
                calls++;
                return calls === 1 ? { ok: false, error: 'feature_disabled' } : { ok: true, locations: {} };
            },
        })),
    });
    await openTablet(h);
    openSettingsSection(h.getRoot(), 'K9 Supply Shop');
    await settle();

    t.isTrue(findByText(h.getRoot(), 'The K9 Supply Shop is disabled server-wide.').length >= 1);
    findByText(h.getRoot(), 'Retry')[0].click();
    await settle();
    t.isTrue(findByText(h.getRoot(), 'No shop locations configured yet.').length >= 1);
    t.equals(calls, 2);
});

// ======================================================================
// ADD -- COORDINATES NEVER SENT BY THIS PAGE
// ======================================================================

t.test('Add Location Here: blank fields send an EMPTY payload -- no x/y/z/heading, no label/model/scenario', async () => {
    let addBody = null;
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:equipmentShopGetLocations': () => ({ ok: true, locations: {} }),
            'tablet:equipmentShopAddLocation': (body) => { addBody = body; return { ok: true, locationKey: 'db:1', locations: { 'db:1': { x: 1, y: 2, z: 3, heading: 0, model: 'a_c_shepherd', scenario: '', label: 'K9 Supply' } } }; },
        })),
    });
    await openTablet(h);
    openSettingsSection(h.getRoot(), 'K9 Supply Shop');
    await settle();

    findByText(h.getRoot(), 'Add Location Here')[0].click();
    await settle();
    findByText(h.getRoot(), 'Save Location')[0].click();
    await new Promise((r) => setTimeout(r, 30));

    t.isDefined(addBody, 'tablet:equipmentShopAddLocation was called');
    t.isUndefined(addBody.x, 'this page never sends coordinates -- client/tablet.lua captures them');
    t.isUndefined(addBody.label);
    t.isUndefined(addBody.model);
    t.isUndefined(addBody.scenario);

    // The form closes and the table now shows the server's own returned location.
    t.isTrue(findByText(h.getRoot(), 'K9 Supply').length >= 1);
});

t.test('Add Location Here: filled fields are sent TRIMMED, blank ones still omitted', async () => {
    let addBody = null;
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:equipmentShopGetLocations': () => ({ ok: true, locations: {} }),
            'tablet:equipmentShopAddLocation': (body) => { addBody = body; return { ok: true, locationKey: 'db:2', locations: {} }; },
        })),
    });
    await openTablet(h);
    openSettingsSection(h.getRoot(), 'K9 Supply Shop');
    await settle();
    findByText(h.getRoot(), 'Add Location Here')[0].click();
    await settle();

    const labelInput = findInput(h.getRoot(), (n) => n.getAttribute('placeholder') === 'e.g. Downtown K9 Supply');
    t.isDefined(labelInput);
    labelInput.typeValue('  Riverside Outpost  ');

    findByText(h.getRoot(), 'Save Location')[0].click();
    await new Promise((r) => setTimeout(r, 30));

    t.equals(addBody.label, 'Riverside Outpost', 'trimmed before sending');
    t.isUndefined(addBody.model, 'left blank -- still omitted, not sent as an empty string');
});

t.test('Add Location Here: a denied add shows a failure notice and keeps the form open', async () => {
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:equipmentShopGetLocations': () => ({ ok: true, locations: {} }),
            'tablet:equipmentShopAddLocation': () => ({ ok: false, error: 'denied' }),
        })),
    });
    await openTablet(h);
    openSettingsSection(h.getRoot(), 'K9 Supply Shop');
    await settle();
    findByText(h.getRoot(), 'Add Location Here')[0].click();
    await settle();
    findByText(h.getRoot(), 'Save Location')[0].click();
    await new Promise((r) => setTimeout(r, 30));

    t.isTrue(findByText(h.getRoot(), 'You are not authorized to manage shop locations.').length >= 1);
    t.isTrue(findByText(h.getRoot(), 'Save Location').length >= 1, 'the form stays open after a failure -- work is not discarded');
});

// ======================================================================
// EDIT (metadata only, no position) vs MOVE HERE (position only)
// ======================================================================

t.test('Edit: pre-fills from the current row, Save sends ALL THREE fields, `false` for the one blanked out', async () => {
    let moveBody = null;
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:equipmentShopGetLocations': () => ({
                ok: true,
                locations: { 'db:9': { x: 1, y: 2, z: 3, heading: 0, model: 'a_c_husky', scenario: 'WORLD_HUMAN_GUARD_STAND', label: 'Old Label' } },
            }),
            'tablet:equipmentShopMoveLocation': (body) => { moveBody = body; return { ok: true, locations: {} }; },
        })),
    });
    await openTablet(h);
    openSettingsSection(h.getRoot(), 'K9 Supply Shop');
    await settle();

    findByText(h.getRoot(), 'Edit')[0].click();
    await settle();

    const labelInput = findInput(h.getRoot(), (n) => n.getAttribute('placeholder') === 'e.g. Downtown K9 Supply');
    t.equals(labelInput.value, 'Old Label', 'pre-filled from the row');
    labelInput.typeValue(''); // deliberately blanked -- reset to shop default

    findByText(h.getRoot(), 'Save Location')[0].click();
    await new Promise((r) => setTimeout(r, 30));

    t.equals(moveBody.locationKey, 'db:9');
    t.equals(moveBody.updates.label, false, 'blanked field resets to the shop default via `false`, never an empty string');
    t.equals(moveBody.updates.model, 'a_c_husky', 'untouched field re-sent as its current value');
    t.equals(moveBody.updates.scenario, 'WORLD_HUMAN_GUARD_STAND');
    t.isTrue(moveBody.useCurrentPosition === undefined || moveBody.useCurrentPosition === false, 'Edit never touches position');
});

t.test('Move Here: sends ONLY {locationKey, useCurrentPosition:true} -- no label/model/scenario, no coordinates', async () => {
    let moveBody = null;
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:equipmentShopGetLocations': () => ({
                ok: true,
                locations: { 'db:9': { x: 1, y: 2, z: 3, heading: 0, model: 'a_c_husky', scenario: '', label: 'Outpost' } },
            }),
            'tablet:equipmentShopMoveLocation': (body) => { moveBody = body; return { ok: true, locations: {} }; },
        })),
    });
    await openTablet(h);
    openSettingsSection(h.getRoot(), 'K9 Supply Shop');
    await settle();

    const moveBtn = findByText(h.getRoot(), 'Move Here')[0];
    moveBtn.click(); // arm confirm
    moveBtn.click(); // confirm
    await new Promise((r) => setTimeout(r, 30));

    t.equals(moveBody.locationKey, 'db:9');
    t.equals(moveBody.useCurrentPosition, true);
    t.isUndefined(moveBody.updates, 'Move Here never sends an `updates` object at all');
});

t.test('Move Here refusal renders inline on that row (cannot, and here is why), not just the generic banner', async () => {
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:equipmentShopGetLocations': () => ({
                ok: true,
                locations: { 'db:3': { x: 1, y: 2, z: 3, heading: 0, model: 'a_c_husky', scenario: '', label: 'Outpost' } },
            }),
            'tablet:equipmentShopMoveLocation': () => ({ ok: false, error: 'rate_limited' }),
        })),
    });
    await openTablet(h);
    openSettingsSection(h.getRoot(), 'K9 Supply Shop');
    await settle();

    const moveBtn = findByText(h.getRoot(), 'Move Here')[0];
    moveBtn.click();
    moveBtn.click();
    await new Promise((r) => setTimeout(r, 30));

    t.isTrue(findByText(h.getRoot(), 'Please wait a moment before trying again.').length >= 1);
});

// ======================================================================
// REMOVE
// ======================================================================

t.test('Remove: only db: rows offer it, requires two clicks (confirm), sends {locationKey}', async () => {
    let removeBody = null;
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:equipmentShopGetLocations': () => ({
                ok: true,
                locations: { 'db:4': { x: 1, y: 2, z: 3, heading: 0, model: 'a_c_husky', scenario: '', label: 'To Be Removed' } },
            }),
            'tablet:equipmentShopRemoveLocation': (body) => { removeBody = body; return { ok: true, locations: {} }; },
        })),
    });
    await openTablet(h);
    openSettingsSection(h.getRoot(), 'K9 Supply Shop');
    await settle();

    const removeBtn = findByText(h.getRoot(), 'Remove')[0];
    removeBtn.click(); // arm confirm
    t.isNull(removeBody, 'the first click only arms the confirm -- no request sent yet');
    removeBtn.click(); // confirm
    await new Promise((r) => setTimeout(r, 30));

    t.equals(removeBody.locationKey, 'db:4');
    t.isTrue(findByText(h.getRoot(), 'No shop locations configured yet.').length >= 1, 'the removed location is gone from the (now empty) table');
});

// ======================================================================
// LIVE PUSH -- qbx_k9unit:client:equipmentShopLocationsUpdated
// ======================================================================

t.test('a Lua-initiated equipmentShopLocationsUpdated push applies live to an already-open Shop Locations screen', async () => {
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:equipmentShopGetLocations': () => ({ ok: true, locations: {} }),
        })),
    });
    await openTablet(h);
    openSettingsSection(h.getRoot(), 'K9 Supply Shop');
    await settle();
    t.isTrue(findByText(h.getRoot(), 'No shop locations configured yet.').length >= 1);

    h.postMessage('tablet:equipmentShopLocationsUpdated', {
        'db:5': { x: 1, y: 2, z: 3, heading: 0, model: 'a_c_shepherd', scenario: '', label: 'Pushed Live' },
    });
    await settle();

    t.isTrue(findByText(h.getRoot(), 'Pushed Live').length >= 1, 'the screen re-renders immediately from the pushed map, no round trip needed');
});

// ======================================================================
// STALE-RESPONSE GUARD -- same class of race
// tests/tablet_stale_response_spec.js already covers for roster/person
// screens, applied here via a request-generation counter (this list has no
// per-request identity like a citizenid/query to compare against arrival
// order).
// ======================================================================

t.test('a late tablet:equipmentShopGetLocations response for an OLDER request never overwrites what a NEWER request already resolved', async () => {
    let resolveStale = null;
    let callNumber = 0;
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:equipmentShopGetLocations': () => {
                callNumber++;
                if (callNumber === 1) {
                    // Held open deliberately -- resolved manually, LATE,
                    // after the second (fast) request has already landed.
                    // Resolves to the PLAIN body (never pre-wrapped via
                    // jsonResponse() here) -- routeFetch()'s own
                    // `jsonResponse(h(body))` wrapping already handles a
                    // handler that returns a Promise-for-a-plain-object.
                    return new Promise((resolve) => {
                        resolveStale = () => resolve({
                            ok: true,
                            locations: { 'db:1': { x: 0, y: 0, z: 0, heading: 0, model: 'a', scenario: '', label: 'STALE FIRST RESULT' } },
                        });
                    });
                }
                return { ok: true, locations: { 'db:2': { x: 0, y: 0, z: 0, heading: 0, model: 'a', scenario: '', label: 'FRESH SECOND RESULT' } } };
            },
        })),
    });
    await openTablet(h);

    // First visit -- fires the request that will be held open.
    openSettingsSection(h.getRoot(), 'K9 Supply Shop');
    await settle();
    t.isDefined(resolveStale, 'the first request was sent and is being held unresolved');

    // Leave the tab, then come back -- fires a SECOND request, which
    // resolves immediately (fast), all while the FIRST is still pending.
    findByText(h.getRoot(), 'My Record')[0].click();
    await settle();
    openSettingsSection(h.getRoot(), 'K9 Supply Shop');
    await settle();

    t.isTrue(findByText(h.getRoot(), 'FRESH SECOND RESULT').length >= 1, 'the second (current) request\'s result is showing');
    t.equals(findByText(h.getRoot(), 'STALE FIRST RESULT').length, 0, 'the first request has not (yet) resolved at all');

    // Only now let the stale FIRST response land.
    resolveStale();
    await settle();

    t.isTrue(findByText(h.getRoot(), 'FRESH SECOND RESULT').length >= 1, 'the fresh result is still showing after the late first response arrives');
    t.equals(findByText(h.getRoot(), 'STALE FIRST RESULT').length, 0, 'the late, OLDER response never replaces the current, NEWER one');
});

t.run();
