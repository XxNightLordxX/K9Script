/*
    html/tests/shipped_asset_integrity_spec.js

    THE BLIND SPOT THIS CLOSES. Every other browser spec runs against a
    synthetic DOM built by dom-stub.js / tablet-dom-stub.js, and the two
    sandboxes read only the JS files off disk. So the files a player's
    client actually FETCHES -- the two HTML documents, the HUD stylesheet,
    the images and sounds fxmanifest.lua ships -- had nothing reading them
    at all. A file could be truncated, deleted, or renamed and all 46 specs
    stayed green.

    That is not hypothetical: html/index.html was once cut from
    `<!DOCTYPE html>` through the end of a bar row, taking `<html>`,
    `<head>`, `<body>` and the `#k9hud` container with it. The HUD rendered
    nothing and every gate passed. hud_markup_integrity_spec.js now guards
    that one document; this file guards everything else the manifest ships.

    WHY THESE CHECKS AND NOT A SNAPSHOT: a byte-for-byte snapshot of an
    asset fails on every legitimate edit and teaches people to regenerate
    it without looking. Each assertion below instead pins a CONTRACT that,
    if broken, produces a silent failure in-game -- a 404 that degrades to
    silence, an unstyled element, a script order that renders nothing, or a
    click that lands on an element with pointer-events disabled.
*/
'use strict';

const fs = require('fs');
const path = require('path');
const t = require('./testkit');

const ROOT = path.join(__dirname, '..', '..');
const read = (rel) => fs.readFileSync(path.join(ROOT, rel), 'utf8');

const manifest = read('fxmanifest.lua');

// fxmanifest.lua is Lua, and a commented-out path must not count as shipped.
// Strip whole-line and trailing comments before matching quoted paths.
const manifestCode = manifest
    .split('\n')
    .map((line) => (line.trim().startsWith('--') ? '' : line.split('--')[0]))
    .join('\n');

const SHIPPED = Array.from(new Set(
    (manifestCode.match(/'(?:html|locales|sql)\/[^']+'/g) || []).map((s) => s.slice(1, -1))
)).sort();

t.test('fxmanifest.lua ships at least the core web assets -- a manifest that matched nothing would make every check below vacuous', () => {
    t.isTrue(SHIPPED.length >= 10, 'expected the manifest to list the HUD, tablet, styles, sounds and locale; found ' + SHIPPED.length);
    for (const required of ['html/index.html', 'html/app.js', 'html/style.css', 'html/tablet.html', 'html/tablet.js']) {
        t.isTrue(SHIPPED.indexOf(required) !== -1, required + ' must be listed in files{} or clients never receive it');
    }
});

t.test('EVERY file fxmanifest.lua ships exists on disk and is non-empty -- a listed-but-missing asset 404s on the client with no error saying why', () => {
    const broken = [];
    for (const rel of SHIPPED) {
        const abs = path.join(ROOT, rel);
        if (!fs.existsSync(abs)) { broken.push(rel + ' (missing)'); continue; }
        if (fs.statSync(abs).size === 0) broken.push(rel + ' (empty)');
    }
    t.equals(broken.join(', '), '', 'every shipped path must resolve to a real, non-empty file');
});

// ----------------------------------------------------------------------
// html/tablet.html -- the tablet's own document. Same class of asset as
// index.html, and until this file existed nothing read it either.
// ----------------------------------------------------------------------

const tabletHtml = read('html/tablet.html');

t.test('tablet.html is a complete HTML document -- doctype, html, head, body, all opened AND closed', () => {
    t.isTrue(/^<!DOCTYPE html>/i.test(tabletHtml.trim()), 'must start with a doctype');
    for (const tag of ['html', 'head', 'body']) {
        t.isTrue(tabletHtml.indexOf('<' + tag) !== -1, '<' + tag + '> must be present');
        t.isTrue(tabletHtml.indexOf('</' + tag + '>') !== -1, '</' + tag + '> must be present');
        t.isTrue(tabletHtml.indexOf('<' + tag) < tabletHtml.indexOf('</' + tag + '>'), '<' + tag + '> must open before it closes');
    }
});

t.test('tablet.html contains #k9tablet-root -- tablet.js\'s render() looks this up by id and has nowhere to draw without it', () => {
    t.isTrue(tabletHtml.indexOf('id="k9tablet-root"') !== -1);
});

t.test('tablet.html loads tablet.css -- it deliberately does NOT share style.css, which forces pointer-events:none for the passive HUD', () => {
    t.isTrue(tabletHtml.indexOf('href="tablet.css"') !== -1, 'the tablet needs real mouse input; style.css would disable it');
    t.equals(tabletHtml.indexOf('href="style.css"'), -1, 'tablet.html must never pull in the HUD stylesheet');
});

t.test('SCRIPT ORDER IS LOAD-BEARING: tablet-catalog.js must load BEFORE tablet.js -- swapped, the catalog globals tablet.js re-binds at its top are undefined and the tablet renders nothing', () => {
    const catalogAt = tabletHtml.indexOf('src="tablet-catalog.js"');
    const tabletAt = tabletHtml.indexOf('src="tablet.js"');
    t.isTrue(catalogAt !== -1, 'tablet-catalog.js must be loaded');
    t.isTrue(tabletAt !== -1, 'tablet.js must be loaded');
    t.isTrue(catalogAt < tabletAt, 'tablet-catalog.js must come first -- this order is stated in tablet.html\'s own comment as load-bearing');
});

// ----------------------------------------------------------------------
// index.html <-> style.css <-> app.js: the styling contract. A class the
// JS toggles that the CSS never defines is a toggle that does nothing.
// ----------------------------------------------------------------------

const indexHtml = read('html/index.html');
const styleCss = read('html/style.css').replace(/\/\*[\s\S]*?\*\//g, '');

function definedInCss(name) {
    return new RegExp('[.#]' + name.replace(/[-]/g, '\\-') + '(?![A-Za-z0-9_-])').test(styleCss);
}

t.test('every class app.js and tablet-bridge.js toggle at runtime is actually defined in style.css -- an undefined class makes classList.toggle() a silent no-op', () => {
    const sources = [read('html/app.js'), read('html/tablet-bridge.js')].join('\n')
        .replace(/\/\*[\s\S]*?\*\//g, '')
        .replace(/\/\/[^\n]*/g, '');
    const toggled = new Set();
    const re = /classList\.(?:add|remove|toggle)\(\s*'([A-Za-z0-9_-]+)'/g;
    let m;
    while ((m = re.exec(sources)) !== null) toggled.add(m[1]);

    t.isTrue(toggled.size > 0, 'CONTROL: the scan must find real toggled classes, or this test proves nothing');
    const undefinedClasses = Array.from(toggled).filter((c) => !definedInCss(c)).sort();
    t.equals(undefinedClasses.join(', '), '', 'every runtime-toggled class needs a rule in style.css');
});

t.test('every TOP-LEVEL HUD surface in index.html has its own rule in style.css -- each is absolutely positioned, so one without a rule flows into the page as raw text over the game', () => {
    // Only direct children of <body> are checked. Each of those is an
    // independently-positioned overlay that MUST carry its own rule. A
    // nested element may legitimately be styled through a descendant
    // selector on its parent instead (see the separate assertion below for
    // the one such case), which is why this is scoped rather than applied
    // to every id in the document.
    const body = indexHtml.slice(indexHtml.indexOf('<body>'), indexHtml.indexOf('</body>'));
    const topLevel = new Set();
    let depth = 0;
    for (const tok of body.match(/<div\b[^>]*>|<\/div>/g) || []) {
        if (tok === '</div>') { depth -= 1; continue; }
        const id = (tok.match(/\sid="([A-Za-z0-9_-]+)"/) || [])[1];
        if (depth === 0 && id) topLevel.add(id);
        depth += 1;
    }

    t.isTrue(topLevel.size >= 3, 'CONTROL: index.html must actually carry several top-level surfaces; found ' + topLevel.size);
    const unstyled = Array.from(topLevel).filter((id) => !definedInCss(id)).sort();
    t.equals(unstyled.join(', '), '', 'every top-level HUD surface needs its own rule in style.css');
});

t.test('the tablet iframe is styled through its wrapper\'s descendant rule -- it carries no id rule of its own, deliberately, and that rule is what gives it its size', () => {
    t.isTrue(indexHtml.indexOf('id="k9tablet-frame"') !== -1, 'the iframe must exist');
    t.isTrue(/\.k9tablet-wrap\s+iframe/.test(styleCss), 'without `.k9tablet-wrap iframe` the frame renders at its default 300x150 size');
});

t.test('THE TABLET IFRAME IS NOT INSIDE #k9hud -- style.css sets `pointer-events: none` on #k9hud AND every descendant, so nesting the tablet there would make it completely unclickable', () => {
    t.isTrue(/#k9hud\s*\*/.test(styleCss), 'CONTROL: this test only means something while the `#k9hud *` rule exists');

    const hudAt = indexHtml.indexOf('id="k9hud"');
    const wrapAt = indexHtml.indexOf('id="k9tablet-wrap"');
    t.isTrue(hudAt !== -1 && wrapAt !== -1, 'both elements must exist');

    // Count div nesting between #k9hud's opening tag and the wrap. If the
    // wrap is a sibling, #k9hud's own </div> closes before we reach it.
    const between = indexHtml.slice(hudAt, wrapAt);
    const opened = (between.match(/<div\b/g) || []).length;
    const closed = (between.match(/<\/div>/g) || []).length;
    t.isTrue(closed >= opened, '#k9tablet-wrap must be a SIBLING of #k9hud, never a descendant of it');
});

t.run();
