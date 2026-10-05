/*
    html/tests/tablet_strings_match_locale_spec.js

    The tablet's built-in English (tablet-catalog.js DEFAULT_STRINGS) must
    say exactly what locales/en.json's `tablet` group says. In game the
    locale text is sent at open and wins, so a stale built-in copy is
    invisible until the locale is missing a key -- which is how
    help_task_get_certified_2 quietly kept pointing players at a removed
    /k9certify command. The key-level check (.github/scripts/
    locale_cross_check.py) only proves both have the same keys; this
    proves they have the same words.
*/
'use strict';

const t = require('./testkit');
const fs = require('fs');
const path = require('path');
const vm = require('vm');

function loadCatalog() {
    const src = fs.readFileSync(path.join(__dirname, '..', 'tablet-catalog.js'), 'utf8');
    const sandbox = { window: {} };
    vm.runInNewContext(src, sandbox);
    return sandbox.window.K9TabletCatalog;
}

t.test('every built-in tablet string matches locales/en.json word for word', () => {
    const catalog = loadCatalog();
    const locale = JSON.parse(fs.readFileSync(path.join(__dirname, '..', '..', 'locales', 'en.json'), 'utf8')).tablet;
    t.isDefined(catalog && catalog.DEFAULT_STRINGS, 'catalog loads');
    const differ = Object.keys(catalog.DEFAULT_STRINGS).filter((k) => k in locale && catalog.DEFAULT_STRINGS[k] !== locale[k]);
    t.equals(differ.join(', '), '', 'strings whose built-in text differs from the locale');
});

t.test('no tablet string tells players to type a chat command that is off by default', () => {
    const locale = JSON.parse(fs.readFileSync(path.join(__dirname, '..', '..', 'locales', 'en.json'), 'utf8')).tablet;
    const removed = /\/k9(certify|decertify|settier|specialize|unspecialize|givexp|grantpermission|revokepermission|suspect|exitkennel)\b/;
    const hits = Object.keys(locale).filter((k) => typeof locale[k] === 'string' && removed.test(locale[k]));
    t.equals(hits.join(', '), '', 'tablet strings naming a removed or admin-only chat command');
});

t.run();
