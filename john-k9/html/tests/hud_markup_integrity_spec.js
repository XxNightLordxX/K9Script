/*
    html/tests/hud_markup_integrity_spec.js

    A STRUCTURAL GUARD ON html/index.html ITSELF, not on any behaviour it
    drives. Every other browser spec in this directory runs against
    dom-stub.js's synthetic DOM, which BUILDS the rows it wants -- so a row
    deleted from the real index.html, or the whole document skeleton
    deleted around it, changes nothing any of them observe. That is exactly
    what happened once: a pass removing four wellbeing rows cut from
    `<!DOCTYPE html>` through the end of the stamina row, taking `<html>`,
    `<head>`, `<body>` and the `#k9hud` container with them and leaving a
    file whose first real element was a stray `</div>`. Every spec stayed
    green, because none of them ever reads this file.

    This spec reads the real file off disk and asserts the things a browser
    needs to be true for the HUD to render at all, plus the row inventory
    app.js and client/hud.lua actually agree on. It is deliberately a
    STRUCTURE check, not a snapshot: adding a row is a one-line addition
    here, while deleting the document skeleton is caught immediately.
*/
'use strict';

const fs = require('fs');
const path = require('path');
const t = require('./testkit');

const html = fs.readFileSync(path.join(__dirname, '..', 'index.html'), 'utf8');

t.test('index.html is a complete HTML document -- doctype, html, head, body, all opened AND closed', () => {
    t.isTrue(/^<!DOCTYPE html>/i.test(html.trim()), 'must start with a doctype');
    for (const tag of ['html', 'head', 'body']) {
        t.isTrue(html.indexOf('<' + tag) !== -1, '<' + tag + '> must be present');
        t.isTrue(html.indexOf('</' + tag + '>') !== -1, '</' + tag + '> must be present');
        t.isTrue(html.indexOf('<' + tag) < html.indexOf('</' + tag + '>'), '<' + tag + '> must open before it closes');
    }
});

t.test('index.html loads style.css -- without it every row renders unstyled and k9hud-row--hidden does nothing', () => {
    t.isTrue(html.indexOf('href="style.css"') !== -1, 'the stylesheet link must survive any edit to this file');
});

t.test('index.html loads app.js -- without it nothing ever handles a hud:updateVitals message', () => {
    t.isTrue(html.indexOf('src="app.js"') !== -1, 'the script tag must survive any edit to this file');
});

t.test('the #k9hud root container exists -- app.js looks it up by id and every row lives inside it', () => {
    t.isTrue(html.indexOf('id="k9hud"') !== -1, '#k9hud is the element app.js shows and hides; without it the HUD can never appear');
});

t.test('the #k9hud root starts hidden -- nothing may flash on screen before the first real push', () => {
    const rootTag = html.slice(html.indexOf('id="k9hud"') - 200, html.indexOf('id="k9hud"') + 200);
    t.isTrue(/class="[^"]*\bhidden\b/.test(rootTag), 'the root must carry the `hidden` class in the markup itself');
});

// The exact row inventory. A row here that app.js never writes to is dead
// markup; a row app.js writes to that is missing here is a silent no-op.
// 'hunger'/'thirst' REMOVED from this list, deliberately (owner directive:
// the hunger/thirst system is one of the subsystems removed completely).
// Their rows are gone from index.html, their fills from style.css, their
// fields from the hud:updateVitals wire contract, and their reads from
// client/hud.lua's ReadVitals(). Putting either name back here would be a
// green test for markup that must no longer exist.
const EXPECTED_BAR_ROWS = ['health', 'stamina', 'fatigue'];
const EXPECTED_STATUS_ROWS = ['xpTier'];

t.test('every expected bar row is present with all three of its data-* hooks', () => {
    for (const stat of EXPECTED_BAR_ROWS) {
        t.isTrue(html.indexOf('data-stat-row="' + stat + '"') !== -1, stat + ' row must exist');
        t.isTrue(html.indexOf('data-fill="' + stat + '"') !== -1, stat + ' must have a data-fill hook for its bar');
        t.isTrue(html.indexOf('data-value="' + stat + '"') !== -1, stat + ' must have a data-value hook for its number');
    }
});

t.test('every expected status row is present with its data-status hook', () => {
    for (const stat of EXPECTED_STATUS_ROWS) {
        t.isTrue(html.indexOf('data-stat-row="' + stat + '"') !== -1, stat + ' row must exist');
        t.isTrue(html.indexOf('data-status="' + stat + '"') !== -1, stat + ' must have a data-status hook');
    }
});

t.test('NO ROW EXISTS FOR A REMOVED SUBSYSTEM -- markup for a stat the server can never send again is dead weight that reads as a live feature', () => {
    for (const stat of ['mood', 'fearStress', 'injury', 'distraction']) {
        t.equals(html.indexOf('data-stat-row="' + stat + '"'), -1, stat + ' was removed on 2026-09-02; its row must not come back');
    }
});

t.test('the handler condition badge element exists and starts hidden -- app.js applyPartnerCondition() is its only writer', () => {
    t.isTrue(html.indexOf('id="k9partner-badge"') !== -1);
    const badge = html.slice(html.indexOf('id="k9partner-badge"') - 100, html.indexOf('id="k9partner-badge"') + 200);
    t.isTrue(/class="[^"]*\bhidden\b/.test(badge), 'the badge must start hidden -- it is only ever unhidden by an explicit visible:true push');
});

t.run();
