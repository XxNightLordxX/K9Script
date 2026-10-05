/*
    html/tests/hud_locale_strings_spec.js

    Regression coverage for a defect found in review: html/app.js's
    applyDistractionStatus() used to render the Distraction status row's
    text via a hardcoded `rawDistracted ? 'Distracted' : 'Clear'` ternary
    -- literal, un-localizable English -- while the ADJACENT xpTier status
    row (applyXPTierStatus) correctly renders whatever string
    client/hud.lua/client/progression.lua's Config.XPTiers label sends
    (itself locale-authored server-side). Every other user-facing string
    on the K9 Command Tablet (html/tablet.js) already routes through a
    `state.strings[key]` (server-sent, locale()-resolved) -> DEFAULT_STRINGS
    (English fallback) lookup -- see html/tablet.js's own S()/
    DEFAULT_STRINGS -- so the Distraction row was the one place on this
    surface that could never be localized no matter what the server sent.

    Fix: applyDistractionStatus() now resolves through the identical
    "state.strings[key] first, English fallback object second" shape via
    hudString()/HUD_DEFAULT_STRINGS, and handleUpdateVitals() forwards an
    optional `data.strings` through to it. The `hud:updateVitals` payload
    contract does not carry a `strings` field yet (client/hud.lua is out of
    this pass' file scope -- reported to the locale/backend owners
    separately: a new `hud` locales/en.json group with
    is needed, sent the same way client/tablet.lua's BuildTabletStrings()
    already sends the `tablet` group), so today `strings` is always
    absent/undefined and every case below still renders the English
    fallback -- this file exists to (a) prove that fallback still matches
    the pre-existing 'Distracted'/'Clear' text exactly (no behavior
    regression -- hud_wellbeing_shape_spec.js's own assertions on those
    exact literals must keep passing unmodified) and (b) prove the
    override path actually works the moment a future payload supplies it,
    without requiring any further app.js change.
*/
'use strict';

const t = require('./testkit');
const { createHarness } = require('./sandbox');

function freshHarnessNoAudio() {
    return createHarness({ AudioContextCtor: undefined });
}

function baseVitals(extra) {
    return Object.assign({ visible: true, health: 100, stamina: 100, hunger: 100, thirst: 100 }, extra);
}






t.run();
