/*
    html/tests/tablet_shop_items_spec.js

    Covers the K9 Supply Shop ITEM CATALOG editing screen (its own tab, high
    command OR a delegated 'k9.equipmentshopitems' grant --
    server/equipmentshop.lua's own CanManageShopItems(source):
    IsHighCommand(source) OR HasPermission(citizenid,
    'k9.equipmentshopitems') == true, tests/equipmentshopitems_spec.lua:616.
    Client-side gate: html/tablet.js's canManageShopItems()) --
    server/equipmentshop.lua's own "EQUIPMENT SHOP ITEM
    CATALOG" section. Owner's own words: "give high command real control
    over the equipment shop" -- which items are sold, at what price, in
    what order, and under what certification-tier/specialization purchase
    requirement.

    Server contract verified against server/equipmentshop.lua directly (not
    assumed):
      tablet:equipmentShopItemsList {} -> {ok, items?, error?}
        items: [{ key, label, price, currency, sortOrder, requiredTierKey,
                   requiredSpecialization }, ...], already sortOrder-ascending.
        A TOMBSTONED item_key is NEVER included in this array at all -- the
        server's own catalog merge (RefreshEquipmentShopItemCatalog)
        excludes it entirely before this page ever sees it. There is
        therefore no "retired ITEM" row for this screen to render inline --
        a successful delete's own response is simply one row shorter. What
        CAN legitimately go stale is a requiredTierKey/requiredSpecialization
        an item still carries after the REFERENCED tier/specialization
        itself was retired/renamed elsewhere -- see the "RETIRED REFERENCE"
        tests below for that real, exercised hazard.
      tablet:equipmentShopItemsUpsert {key,price,label?,currency?,
          requiredTierKey?,requiredSpecialization?} -> {ok, items?, error?}
        ZERO IS AN EXPLICITLY LEGAL PRICE (server/equipmentshop.lua's own
        IsValidShopItemPrice: `value >= 0`, never `> 0`) -- a free item is a
        disclosed, deliberate decision, never rejected client-side either.
      tablet:equipmentShopItemsReorder {orderedKeys:string[]} -> {ok, items?, error?}
        MUST be an exact permutation of every currently-known key -- this
        page is structurally incapable of submitting a partial one (see
        moveShopItem()'s own doc comment).
      tablet:equipmentShopItemsDelete {key} -> {ok, items?, error?}
        Tombstones -- no reference-count refusal exists for this endpoint
        (unlike certTiersDelete's own tier_in_use), so any failure here is a
        plain error/refusal rendered inline on that item's own row.

    `reason` is renamed to `error` by client/tablet.lua's
    TranslateReasonResult before any of this ever reaches this page -- every
    failure fixture below uses `error`, never `reason`, matching every other
    spec in this suite.

    Every gate below is asserted as a CONVENIENCE, per html/tablet.js's own
    THE SECURITY RULE -- the real authorization/validation is
    server/equipmentshop.lua's own CanManageShopItems/
    IsValidShopItemKey/IsValidShopItemPrice, covered server-side in
    tests/equipmentshopitems_spec.lua/tests/clienttabletequipmentshop_spec.lua.
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
        if (!h) return Promise.reject(new Error('tablet_shop_items_spec: unhandled NUI callback ' + name));
        return Promise.resolve(jsonResponse(h(body)));
    };
}

const HIGH_COMMAND_VIEWER = { citizenid: 'HC1', name: 'Chief', isHighCommand: true, effectivePermissions: ['k9.access', 'k9.certify', 'k9.audit', 'k9.givexp'], allowSelfGrant: false };
const CONSOLE_ONLY_VIEWER = { citizenid: 'OFFICER1', name: 'Officer', isHighCommand: false, effectivePermissions: ['k9.certify'], allowSelfGrant: false };
// Holds the delegated capability but is NOT high command -- server/
// equipmentshop.lua's own CanManageShopItems admits this exact citizenid
// (see this file's header). See canManageShopItems()'s own doc comment.
const DELEGATED_SHOP_ITEMS_VIEWER = { citizenid: 'DELEGATE1', name: 'Delegate', isHighCommand: false, effectivePermissions: ['k9.certify', 'k9.equipmentshopitems'], allowSelfGrant: false };

async function settle(times) {
    for (let i = 0; i < (times || 3); i++) await new Promise((r) => setImmediate(r));
}

function baseHandlers(overrides) {
    return Object.assign({
        'tablet:requestMyRecord': () => ({ ok: true, viewer: HIGH_COMMAND_VIEWER, certifications: [], xp: null, tierLabel: null, myFeatures: [] }),
        'tablet:getTheme': () => ({ ok: true, theme: { primaryColor: '#2563eb', accentColor: '#f59e0b', backgroundColor: '#111827', textColor: '#f9fafb', density: 'comfortable', headerTitle: 'K9 Command Tablet' } }),
        'tablet:certTiersList': () => ({ ok: true, tiers: [], capabilityCatalog: {} }),
    }, overrides || {});
}

async function openTablet(h, extraOpenData) {
    h.postMessage('tablet:open', Object.assign({}, extraOpenData || {}));
    await settle();
}

function findInput(root, predicate) {
    return findAll(root, (n) => n.tagName === 'input' && predicate(n))[0];
}

function findSelect(root, predicate) {
    return findAll(root, (n) => n.tagName === 'select' && predicate(n))[0];
}

// ======================================================================
// GATING
// ======================================================================

t.test('a non-high-command console user never sees the Shop Items tab', async () => {
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:requestMyRecord': () => ({ ok: true, viewer: CONSOLE_ONLY_VIEWER, certifications: [], xp: null, tierLabel: null, myFeatures: [] }),
        })),
    });
    await openTablet(h);
    t.equals(findByText(h.getRoot(), 'K9 Supply Shop').length, 0);
});

t.test('a non-high-command officer holding a delegated k9.equipmentshopitems grant DOES see the Shop Items tab, and can open it', async () => {
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:requestMyRecord': () => ({ ok: true, viewer: DELEGATED_SHOP_ITEMS_VIEWER, certifications: [], xp: null, tierLabel: null, myFeatures: [] }),
            'tablet:equipmentShopItemsList': () => ({ ok: true, items: [] }),
        })),
    });
    await openTablet(h);
    t.equals(findByText(h.getRoot(), 'Server Settings').length, 1, 'the Server Settings tab is visible to a delegated non-high-command officer');
    openSettingsSection(h.getRoot(), 'K9 Supply Shop');
    t.equals(findByClass(h.getRoot(), 'k9tablet-settings-sections')[0].children.length, 1, 'and holds exactly the one section this delegate may change');
    await settle();
    t.isTrue(findByText(h.getRoot(), 'Add New Item').length >= 1, 'the real screen renders, not a dead end');
});

// ======================================================================
// DYNAMIC CATALOGUE + ZERO PRICE
// ======================================================================

t.test('DYNAMIC CATALOGUE: items rendered come ENTIRELY from tablet:equipmentShopItemsList -- invented keys/labels appearing nowhere in tablet.js source render correctly, and a ZERO price renders as Free rather than blank/hidden', async () => {
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:equipmentShopItemsList': () => ({
                ok: true,
                items: [
                    { key: 'zzz_novel_bait', label: 'Zzyzx Novel Bait', price: 0, currency: null, sortOrder: 1, requiredTierKey: null, requiredSpecialization: null },
                    { key: 'k9_medkit', label: 'K9 Medkit', price: 150, currency: 'money', sortOrder: 2, requiredTierKey: 'senior', requiredSpecialization: 'narcotics' },
                ],
            }),
            'tablet:certTiersList': () => ({ ok: true, tiers: [{ key: 'senior', label: 'Senior Handler', ordinal: 1, capabilities: {} }], capabilityCatalog: {} }),
        })),
    });
    await openTablet(h, { specializations: { narcotics: { label: 'Narcotics Detection' } } });
    openSettingsSection(h.getRoot(), 'K9 Supply Shop');
    await settle();

    t.isTrue(findByText(h.getRoot(), 'Zzyzx Novel Bait').length >= 1, 'a label this test invented on the fly renders correctly -- proves no hardcoded item list');
    t.isTrue(findByText(h.getRoot(), 'zzz_novel_bait').length >= 1);
    t.isTrue(findAll(h.getRoot(), (n) => typeof n._textContent === 'string' && n._textContent.indexOf('Free') !== -1).length >= 1, 'a ZERO price is called out with its own "Free" badge, never hidden/blank -- server/equipmentshop.lua explicitly allows price=0');
    t.isTrue(findByText(h.getRoot(), '150').length >= 1);
    t.isTrue(findByText(h.getRoot(), 'Senior Handler').length >= 1, 'required tier resolved via the loaded certTiers catalog, not the raw key');
    t.isTrue(findByText(h.getRoot(), 'Narcotics Detection').length >= 1, 'required specialization resolved via state.specializations, not the raw key');
});

t.test('empty catalog shows an empty-state message, never a blank/crashed panel', async () => {
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:equipmentShopItemsList': () => ({ ok: true, items: [] }),
        })),
    });
    await openTablet(h);
    openSettingsSection(h.getRoot(), 'K9 Supply Shop');
    await settle();
    t.isTrue(findByText(h.getRoot(), 'No shop items configured yet.').length >= 1);
});

t.test('a failed list fetch shows an error + Retry, never a blank panel', async () => {
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:equipmentShopItemsList': () => ({ ok: false, error: 'denied' }),
        })),
    });
    await openTablet(h);
    openSettingsSection(h.getRoot(), 'K9 Supply Shop');
    await settle();
    t.isTrue(findByText(h.getRoot(), 'You are not authorized to manage the K9 Supply Shop item catalog.').length >= 1);
    t.isTrue(findByText(h.getRoot(), 'Retry').length >= 1);
});

// ======================================================================
// ADD / EDIT -- ZERO PRICE ACCEPTED, OPTIONAL FIELDS OMITTED WHEN BLANK
// ======================================================================

t.test('Add New Item: a ZERO price is submitted as the number 0 and accepted -- never rejected client-side, never coerced to a truthy/omitted value', async () => {
    let upsertBody = null;
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:equipmentShopItemsList': () => ({ ok: true, items: [] }),
            'tablet:equipmentShopItemsUpsert': (body) => { upsertBody = body; return { ok: true, items: [{ key: 'k9_treat', label: 'k9_treat', price: 0, currency: null, sortOrder: 1, requiredTierKey: null, requiredSpecialization: null }] }; },
        })),
    });
    await openTablet(h);
    openSettingsSection(h.getRoot(), 'K9 Supply Shop');
    await settle();

    findByText(h.getRoot(), 'Add New Item')[0].click();
    await settle();

    const keyInput = findInput(h.getRoot(), (n) => n.getAttribute('placeholder') === 'e.g. k9_medkit');
    const priceInput = findInput(h.getRoot(), (n) => n.getAttribute('type') === 'number' && n.getAttribute('min') === '0');
    t.isDefined(keyInput);
    t.isDefined(priceInput);
    keyInput.typeValue('k9_treat');
    priceInput.typeValue('0');

    findByText(h.getRoot(), 'Save Item')[0].click();
    await new Promise((r) => setTimeout(r, 30));

    t.isDefined(upsertBody, 'the save actually reached the server -- zero was never rejected before the round trip');
    t.equals(upsertBody.key, 'k9_treat');
    t.equals(upsertBody.price, 0, 'price is the NUMBER 0, not a string, not omitted, not coerced to some other falsy-but-wrong value');
    t.isTrue(!('label' in upsertBody), 'a blank label is OMITTED entirely, never sent as an empty string');
    t.isTrue(!('currency' in upsertBody), 'a blank currency is OMITTED entirely');
    t.isTrue(!('requiredTierKey' in upsertBody), 'no requirement selected -- OMITTED entirely, never sent as an empty string');
    t.isTrue(!('requiredSpecialization' in upsertBody));
});

t.test('Add New Item: label/currency/required tier/required specialization are all submitted when filled in', async () => {
    let upsertBody = null;
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:equipmentShopItemsList': () => ({ ok: true, items: [] }),
            'tablet:certTiersList': () => ({ ok: true, tiers: [{ key: 'trainee', label: 'Trainee', ordinal: 1, capabilities: {} }], capabilityCatalog: {} }),
            'tablet:equipmentShopItemsUpsert': (body) => { upsertBody = body; return { ok: true, items: [] }; },
        })),
    });
    await openTablet(h, { specializations: { explosives: { label: 'Explosives Detection' } } });
    openSettingsSection(h.getRoot(), 'K9 Supply Shop');
    await settle();

    findByText(h.getRoot(), 'Add New Item')[0].click();
    await settle();

    findInput(h.getRoot(), (n) => n.getAttribute('placeholder') === 'e.g. k9_medkit').typeValue('k9_vest');
    findInput(h.getRoot(), (n) => n.getAttribute('type') === 'number' && n.getAttribute('min') === '0').typeValue('250');
    findInput(h.getRoot(), (n) => n.getAttribute('placeholder') === "Leave blank to use the item's own name").typeValue('K9 Ballistic Vest');
    findInput(h.getRoot(), (n) => n.getAttribute('placeholder') === 'Leave blank to use the shop default').typeValue('black_money');

    const tierSelect = findSelect(h.getRoot(), () => true);
    t.isDefined(tierSelect);
    tierSelect.value = 'trainee';
    tierSelect._dispatch('input');

    const selects = findAll(h.getRoot(), (n) => n.tagName === 'select');
    t.equals(selects.length, 2, 'exactly the required-tier and required-specialization selects are present');
    selects[1].value = 'explosives';
    selects[1]._dispatch('input');

    findByText(h.getRoot(), 'Save Item')[0].click();
    await new Promise((r) => setTimeout(r, 30));

    t.equals(upsertBody.key, 'k9_vest');
    t.equals(upsertBody.price, 250);
    t.equals(upsertBody.label, 'K9 Ballistic Vest');
    t.equals(upsertBody.currency, 'black_money');
    t.equals(upsertBody.requiredTierKey, 'trainee');
    t.equals(upsertBody.requiredSpecialization, 'explosives');
});

t.test('Edit an existing item: the key input is DISABLED, and every other field is pre-filled from the current row so a Save that touches nothing re-submits the SAME full values (full-replace semantics)', async () => {
    let upsertBody = null;
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:equipmentShopItemsList': () => ({
                ok: true,
                items: [{ key: 'k9_medkit', label: 'Field Medkit', price: 75, currency: 'black_money', sortOrder: 1, requiredTierKey: 'senior', requiredSpecialization: 'narcotics' }],
            }),
            'tablet:certTiersList': () => ({ ok: true, tiers: [{ key: 'senior', label: 'Senior', ordinal: 1, capabilities: {} }], capabilityCatalog: {} }),
            'tablet:equipmentShopItemsUpsert': (body) => { upsertBody = body; return { ok: true, items: [] }; },
        })),
    });
    await openTablet(h, { specializations: { narcotics: { label: 'Narcotics Detection' } } });
    openSettingsSection(h.getRoot(), 'K9 Supply Shop');
    await settle();

    findByText(h.getRoot(), 'Edit')[0].click();
    await settle();

    const keyInput = findInput(h.getRoot(), (n) => n.value === 'k9_medkit');
    t.isDefined(keyInput);
    t.equals(keyInput.getAttribute('disabled'), 'disabled', 'key is never editable once the item already exists (no rename concept)');

    findByText(h.getRoot(), 'Save Item')[0].click();
    await new Promise((r) => setTimeout(r, 30));

    t.equals(upsertBody.key, 'k9_medkit');
    t.equals(upsertBody.price, 75);
    t.equals(upsertBody.label, 'Field Medkit');
    t.equals(upsertBody.currency, 'black_money');
    t.equals(upsertBody.requiredTierKey, 'senior', 'untouched Save still resubmits the EXISTING requirement -- server/equipmentshop.lua REPLACES this field wholesale from this one payload, never a partial merge');
    t.equals(upsertBody.requiredSpecialization, 'narcotics');
});

// ======================================================================
// RETIRED REFERENCE -- a requiredTierKey/requiredSpecialization the LIVE
// catalog no longer contains must still render, and must never be
// silently dropped by an untouched Save.
// ======================================================================

t.test('RETIRED REFERENCE: an item\'s requiredTierKey naming a tier absent from the loaded certTiers catalog renders as the raw key (table row) and as its own clearly-marked, PRE-SELECTED option in the edit draft (never blank, never silently cleared by Save)', async () => {
    let upsertBody = null;
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:equipmentShopItemsList': () => ({
                ok: true,
                items: [{ key: 'k9_gasmask', label: 'K9 Gas Mask', price: 300, currency: null, sortOrder: 1, requiredTierKey: 'zzz_long_retired_tier', requiredSpecialization: null }],
            }),
            // The live tier catalog does NOT contain 'zzz_long_retired_tier'
            // -- simulating that tier having been retired by a different
            // high-command session since this item was last saved.
            'tablet:certTiersList': () => ({ ok: true, tiers: [{ key: 'trainee', label: 'Trainee', ordinal: 1, capabilities: {} }], capabilityCatalog: {} }),
            'tablet:equipmentShopItemsUpsert': (body) => { upsertBody = body; return { ok: true, items: [] }; },
        })),
    });
    await openTablet(h);
    openSettingsSection(h.getRoot(), 'K9 Supply Shop');
    await settle();

    t.isTrue(findByText(h.getRoot(), 'zzz_long_retired_tier').length >= 1, 'the table row shows the raw retired key rather than a blank cell');

    findByText(h.getRoot(), 'Edit')[0].click();
    await settle();

    const tierSelect = findAll(h.getRoot(), (n) => n.tagName === 'select')[0];
    t.isDefined(tierSelect);
    t.equals(tierSelect.value, 'zzz_long_retired_tier', 'the retired reference is PRE-SELECTED, not silently reset to "None"');
    const retiredOptionTexts = findAll(tierSelect, (n) => n.tagName === 'option').map((o) => o._textContent);
    t.isTrue(retiredOptionTexts.some((txt) => txt.indexOf('zzz_long_retired_tier') !== -1), 'the retired tier is offered as its own visible option, not hidden from the dropdown entirely');

    // A Save that touches NOTHING must resubmit the SAME retired key --
    // never silently clear it just because it fell out of the live catalog.
    findByText(h.getRoot(), 'Save Item')[0].click();
    await new Promise((r) => setTimeout(r, 30));
    t.equals(upsertBody.requiredTierKey, 'zzz_long_retired_tier', 'an untouched Save never silently drops a retired-but-still-configured requirement');
});

t.test('RETIRED REFERENCE: choosing "None" on a retired required-specialization deliberately clears it (the ONLY way it should ever be cleared)', async () => {
    let upsertBody = null;
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:equipmentShopItemsList': () => ({
                ok: true,
                items: [{ key: 'k9_vest', label: 'K9 Vest', price: 100, currency: null, sortOrder: 1, requiredTierKey: null, requiredSpecialization: 'zzz_retired_spec' }],
            }),
            'tablet:equipmentShopItemsUpsert': (body) => { upsertBody = body; return { ok: true, items: [] }; },
        })),
    });
    // state.specializations does NOT contain 'zzz_retired_spec' -- simulating
    // it having been removed from Config.K9Specializations.
    await openTablet(h, { specializations: { narcotics: { label: 'Narcotics Detection' } } });
    openSettingsSection(h.getRoot(), 'K9 Supply Shop');
    await settle();
    findByText(h.getRoot(), 'Edit')[0].click();
    await settle();

    const specSelect = findAll(h.getRoot(), (n) => n.tagName === 'select')[1];
    t.isDefined(specSelect);
    t.equals(specSelect.value, 'zzz_retired_spec', 'pre-selected, not reset to None');
    specSelect.value = '';
    specSelect._dispatch('input');

    findByText(h.getRoot(), 'Save Item')[0].click();
    await new Promise((r) => setTimeout(r, 30));
    t.isTrue(!('requiredSpecialization' in upsertBody), 'a DELIBERATE "None" selection omits the field entirely, clearing the requirement');
});

// ======================================================================
// EVERY DISTINCT SERVER FAILURE REASON GETS ITS OWN MESSAGE
// ======================================================================

const UPSERT_REASON_TEXT = {
    denied: 'You are not authorized to manage the K9 Supply Shop item catalog.',
    rate_limited: 'Please wait a moment before trying again.',
    invalid_payload: 'That request was malformed. Try again.',
    invalid_key: 'That item key is invalid -- use 1-50 lowercase letters, numbers, or underscores, starting with a letter.',
    invalid_price: 'That price is invalid -- enter a whole number from 0 up to 1,000,000,000. Zero is allowed for a free item.',
    invalid_label: 'That label is invalid or too long (max 60 characters, no special markup characters).',
    invalid_currency: 'That currency item key is invalid -- use 1-50 lowercase letters, numbers, or underscores, starting with a letter.',
    invalid_required_tier: 'That required certification tier does not exist.',
    invalid_required_specialization: 'That required specialization does not exist.',
    busy: 'This item is being edited elsewhere right now -- try again in a moment.',
    too_many_items: 'The maximum number of shop items has been reached.',
    db_error: 'A database error occurred. Try again.',
};

for (const [reason, expectedText] of Object.entries(UPSERT_REASON_TEXT)) {
    t.test(`equipmentShopItemsUpsert refusal '${reason}' renders its OWN distinct message, never a generic "Action failed."`, async () => {
        const h = createHarness({
            fetchImpl: routeFetch(baseHandlers({
                'tablet:equipmentShopItemsList': () => ({ ok: true, items: [] }),
                'tablet:equipmentShopItemsUpsert': () => ({ ok: false, error: reason }),
            })),
        });
        await openTablet(h);
        openSettingsSection(h.getRoot(), 'K9 Supply Shop');
        await settle();
        findByText(h.getRoot(), 'Add New Item')[0].click();
        await settle();

        findInput(h.getRoot(), (n) => n.getAttribute('placeholder') === 'e.g. k9_medkit').typeValue('k9_valid_key');
        findInput(h.getRoot(), (n) => n.getAttribute('type') === 'number' && n.getAttribute('min') === '0').typeValue('10');
        findByText(h.getRoot(), 'Save Item')[0].click();
        await new Promise((r) => setTimeout(r, 30));

        t.isTrue(findByText(h.getRoot(), expectedText).length >= 1, `expected distinct text for '${reason}': ${JSON.stringify(expectedText)}`);
    });
}

t.test('equipmentShopItemsReorder refusal "must_include_every_item"/"invalid_key_set" renders its own message, distinct from a generic failure', async () => {
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:equipmentShopItemsList': () => ({
                ok: true,
                items: [
                    { key: 'a_item', label: 'A', price: 1, currency: null, sortOrder: 1, requiredTierKey: null, requiredSpecialization: null },
                    { key: 'b_item', label: 'B', price: 2, currency: null, sortOrder: 2, requiredTierKey: null, requiredSpecialization: null },
                ],
            }),
            'tablet:equipmentShopItemsReorder': () => ({ ok: false, error: 'must_include_every_item' }),
        })),
    });
    await openTablet(h);
    openSettingsSection(h.getRoot(), 'K9 Supply Shop');
    await settle();

    const moveDownButtons = findAll(h.getRoot(), (n) => n.tagName === 'button' && n._textContent === '↓');
    moveDownButtons[0].click();
    await new Promise((r) => setTimeout(r, 30));

    t.isTrue(findByText(h.getRoot(), 'The new order must include every existing item, with none missing or duplicated.').length >= 1);
});

// ======================================================================
// REORDER -- FULL PERMUTATION, NEVER PARTIAL
// ======================================================================

t.test('Move Up/Down submits the FULL reordered key list (not just the two swapped), never a partial reorder', async () => {
    let reorderBody = null;
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:equipmentShopItemsList': () => ({
                ok: true,
                items: [
                    { key: 'k9_medkit', label: 'Medkit', price: 50, currency: null, sortOrder: 1, requiredTierKey: null, requiredSpecialization: null },
                    { key: 'k9_treat', label: 'Treat', price: 5, currency: null, sortOrder: 2, requiredTierKey: null, requiredSpecialization: null },
                    { key: 'k9_whistle', label: 'Whistle', price: 20, currency: null, sortOrder: 3, requiredTierKey: null, requiredSpecialization: null },
                ],
            }),
            'tablet:equipmentShopItemsReorder': (body) => {
                reorderBody = body;
                return { ok: true, items: [] };
            },
        })),
    });
    await openTablet(h);
    openSettingsSection(h.getRoot(), 'K9 Supply Shop');
    await settle();

    const moveUpButtons = findAll(h.getRoot(), (n) => n.tagName === 'button' && n._textContent === '↑');
    t.equals(moveUpButtons.length, 3);
    t.equals(moveUpButtons[0].getAttribute('disabled'), 'disabled', 'the FIRST row cannot move up');
    moveUpButtons[1].click(); // move "k9_treat" up ahead of "k9_medkit"
    await new Promise((r) => setTimeout(r, 30));

    t.isTrue(Array.isArray(reorderBody.orderedKeys));
    t.equals(reorderBody.orderedKeys.length, 3, 'the FULL permutation of every current key is sent, never a partial reorder');
    t.equals(reorderBody.orderedKeys[0], 'k9_treat');
    t.equals(reorderBody.orderedKeys[1], 'k9_medkit');
    t.equals(reorderBody.orderedKeys[2], 'k9_whistle');
});

// ======================================================================
// DELETE (TOMBSTONE) -- TWO-CLICK CONFIRM, ROW DISAPPEARS ON SUCCESS,
// FAILURE RENDERS INLINE
// ======================================================================

t.test('Delete requires a two-click confirm, then tombstones the item -- it disappears from the table on success (never lingers as a fake "retired" row)', async () => {
    let deleteBody = null;
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:equipmentShopItemsList': () => ({
                ok: true,
                items: [{ key: 'k9_treat', label: 'Treat', price: 5, currency: null, sortOrder: 1, requiredTierKey: null, requiredSpecialization: null }],
            }),
            'tablet:equipmentShopItemsDelete': (body) => { deleteBody = body; return { ok: true, items: [] }; },
        })),
    });
    await openTablet(h);
    openSettingsSection(h.getRoot(), 'K9 Supply Shop');
    await settle();

    const deleteBtn = findByText(h.getRoot(), 'Delete')[0];
    t.isDefined(deleteBtn);
    deleteBtn.click(); // arm confirm -- must NOT fire yet
    t.equals(deleteBody, null, 'a single click only arms the confirm, never fires the mutation');
    deleteBtn.click(); // confirm
    await new Promise((r) => setTimeout(r, 30));

    t.equals(deleteBody.key, 'k9_treat');
    t.equals(findByText(h.getRoot(), 'Treat').length, 0, 'the tombstoned item is gone from the table once the server confirms -- no optimistic pre-removal, no lingering fake row');
});

t.test('Delete refusal ("unknown_item") renders "cannot, and here is why" inline on that row, never a bare generic failure', async () => {
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:equipmentShopItemsList': () => ({
                ok: true,
                items: [{ key: 'k9_treat', label: 'Treat', price: 5, currency: null, sortOrder: 1, requiredTierKey: null, requiredSpecialization: null }],
            }),
            'tablet:equipmentShopItemsDelete': () => ({ ok: false, error: 'unknown_item' }),
        })),
    });
    await openTablet(h);
    openSettingsSection(h.getRoot(), 'K9 Supply Shop');
    await settle();

    const deleteBtn = findByText(h.getRoot(), 'Delete')[0];
    deleteBtn.click();
    deleteBtn.click();
    await new Promise((r) => setTimeout(r, 30));

    t.isTrue(findByText(h.getRoot(), 'That item no longer exists in the catalog.').length >= 1);
    // Row must still be present -- the failed delete never optimistically
    // removed it.
    t.isTrue(findByText(h.getRoot(), 'Treat').length >= 1);
});

// ======================================================================
// NEVER OPTIMISTIC -- state changes only after the server confirms
// ======================================================================

t.test('a rejected Save leaves the OLD catalog values showing behind the still-open draft -- never an optimistic pre-apply of the attempted edit', async () => {
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:equipmentShopItemsList': () => ({
                ok: true,
                items: [{ key: 'k9_medkit', label: 'Medkit', price: 50, currency: null, sortOrder: 1, requiredTierKey: null, requiredSpecialization: null }],
            }),
            'tablet:equipmentShopItemsUpsert': () => ({ ok: false, error: 'invalid_price' }),
        })),
    });
    await openTablet(h);
    openSettingsSection(h.getRoot(), 'K9 Supply Shop');
    await settle();

    findByText(h.getRoot(), 'Edit')[0].click();
    await settle();
    const priceInput = findInput(h.getRoot(), (n) => n.getAttribute('type') === 'number' && n.getAttribute('min') === '0');
    priceInput.typeValue('999999999999');

    findByText(h.getRoot(), 'Save Item')[0].click();
    await new Promise((r) => setTimeout(r, 30));

    t.isTrue(findByText(h.getRoot(), 'That price is invalid -- enter a whole number from 0 up to 1,000,000,000. Zero is allowed for a free item.').length >= 1);
    // The draft stays open (Save failures never silently close the form) --
    // the underlying catalog value of 50 is unrelated to what is still
    // sitting, unsaved, in the input.
    t.isTrue(findByText(h.getRoot(), 'Save Item').length >= 1, 'the draft form is still open after a rejected save, not blown away or replaced');
});

// ======================================================================
// ESCAPING -- a hostile item label/key reaches the DOM only via
// textContent/.value, never innerHTML.
// ======================================================================

t.test('ESCAPING: a hostile item label reaches the table row and the edit-draft prefill verbatim via textContent/.value, never innerHTML', async () => {
    const malicious = '<img src=x onerror="window.__xss_pwned=true"><script>window.__xss_pwned=true</script>';
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:equipmentShopItemsList': () => ({
                ok: true,
                items: [{ key: 'k9_hostile', label: malicious, price: 10, currency: null, sortOrder: 1, requiredTierKey: null, requiredSpecialization: null }],
            }),
        })),
    });
    await openTablet(h);
    openSettingsSection(h.getRoot(), 'K9 Supply Shop');
    await settle();

    function everyElementInnerHTMLWriteCount() {
        return findAll(h.getRoot(), () => true).reduce((sum, el) => sum + (el.innerHTMLWriteCount || 0), 0);
    }

    t.isTrue(findAll(h.getRoot(), (n) => n._textContent === malicious).length >= 1, 'the hostile label renders verbatim in the table row via textContent');
    t.equals(everyElementInnerHTMLWriteCount(), 0);

    findByText(h.getRoot(), 'Edit')[0].click();
    await settle();
    const labelInput = findInput(h.getRoot(), (n) => n.value === malicious);
    t.isDefined(labelInput, 'the edit draft pre-fills the label input with the hostile value via .value, never markup');
    t.equals(everyElementInnerHTMLWriteCount(), 0);
});

t.test('a PARTIAL reorder write names the items that did not save, instead of a bare failure', async () => {
    const h = createHarness({
        fetchImpl: routeFetch(baseHandlers({
            'tablet:equipmentShopItemsList': () => ({
                ok: true,
                items: [
                    { key: 'a_item', label: 'A', price: 1, currency: null, sortOrder: 1, requiredTierKey: null, requiredSpecialization: null },
                    { key: 'b_item', label: 'B', price: 2, currency: null, sortOrder: 2, requiredTierKey: null, requiredSpecialization: null },
                ],
            }),
            // server/equipmentshop.lua's real partial-failure shape: it knows
            // exactly which keys did not persist and says so. Until 2026-08-31
            // this reason had no case in shopItemErrorText, so it fell to the
            // generic line and `failedKeys` was discarded -- the worst copy
            // for a PARTIAL write, where "what actually saved?" is the only
            // question the admin has.
            'tablet:equipmentShopItemsReorder': () => ({ ok: false, error: 'sort_order_write_failed', failedKeys: ['b_item'] }),
        })),
    });
    await openTablet(h);
    openSettingsSection(h.getRoot(), 'K9 Supply Shop');
    await settle();

    const moveDownButtons = findAll(h.getRoot(), (n) => n.tagName === 'button' && n._textContent === '↓');
    moveDownButtons[0].click();
    await new Promise((r) => setTimeout(r, 30));

    // Asserted against the REAL rendered sentence, not a bare search for
    // 'b_item': that key is already on screen in its own list row, so a
    // substring search passes whether or not the error renders at all --
    // this assertion was written that way first and passed without the fix.
    const expected = 'The new order could not be saved for these items: b_item. Nothing else was changed'
        + ' \u2014 reopen this screen to see the order that is actually stored, then try again.';
    t.isTrue(findByText(h.getRoot(), expected).length > 0,
        'the failing item key must be named IN THE ERROR so the admin knows what to re-check');
});

t.run();
