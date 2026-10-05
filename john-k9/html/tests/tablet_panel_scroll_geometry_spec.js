// html/tests/tablet_panel_scroll_geometry_spec.js
//
// THE BUG THIS EXISTS FOR (2026-09-01, owner's live testing: "guided flows
// is cut off on the ui").
//
// html/tablet.html builds one fixed-size dialog: `.k9tablet-panel` is a
// `display: flex; flex-direction: column` box of a FIXED height
// (`min(640px, 88vh)`) with `overflow: hidden`. Into it, tablet.js's
// buildBackdrop() appends, in order: the header, an optional action
// notice, the tab bar, and then exactly ONE screen element
// (`.k9tablet-screen`) -- see that function for the full list of screens.
//
// `.k9tablet-screen` is the only one of those that is meant to scroll, and
// it carries `flex: 1 1 auto; overflow-y: auto` to say so. That was not
// enough. A flex item's initial `min-height` is `auto`, which for a scroll
// container resolves to its own CONTENT height -- so the screen refused to
// shrink below whatever it contained. On any screen taller than the panel
// it grew past the bottom edge rather than scrolling, the panel's
// `overflow: hidden` clipped the excess, and because no scrollbar ever
// appeared there was no way to reach the clipped part. It was simply gone.
//
// It was reported against Guided Flows because that is the tallest screen,
// but nothing about the bug was specific to it: every long roster, feature
// list and help page lost its bottom by exactly however much it overflowed.
//
// WHY THIS SPEC READS CSS TEXT RATHER THAN ASSERTING PIXELS: the dom stub
// these specs run against has no CSS engine and no layout at all (see
// tablet-dom-stub.js's own header), so there is no computed height here to
// assert on. The honest guard available at this level is over the
// stylesheet's own source: the four rules below are exactly what make the
// panel's one scroll region actually scroll, and this file fails if any of
// them is removed. This is a weaker check than a real browser would give
// -- it proves the rules are present, not that the rendered result is
// right -- and it is recorded as such rather than claimed as more.

const fs = require('fs');
const path = require('path');
const t = require('./testkit');

// COMMENTS ARE STRIPPED BEFORE ANY MATCHING, and that is not a detail.
// This stylesheet documents itself heavily, so the rule that fixes a bug
// and the comment explaining the fix sit inside the same block and contain
// the same words. The first draft of this spec matched raw source, and its
// control -- deleting the real `min-height: 0` declaration -- still passed,
// because the phrase "`min-height: 0` is the standard fix" in the comment
// two lines above satisfied the regex. A guard that a comment can satisfy
// is not guarding anything. Matching declarations only is what makes the
// control below actually go red.
const cssRaw = fs.readFileSync(path.join(__dirname, '..', 'tablet.css'), 'utf8');
const css = cssRaw.replace(/\/\*[\s\S]*?\*\//g, '');

/**
 * Returns the declaration block for the TOP-LEVEL rule whose selector is
 * exactly `selector`, failing if it is absent or ambiguous.
 *
 * Anchored to the start of a line on purpose. A plain indexOf(selector)
 * finds the first textual occurrence, and several of these selectors also
 * appear as the tail of a more specific rule earlier in the file --
 * `.k9tablet-panel.k9tablet-density-compact .k9tablet-screen {` contains
 * `.k9tablet-screen {`. Matching that instead reads the density override's
 * two padding lines and concludes the base rule has no overflow-y, which
 * is how the first draft of this spec failed against a stylesheet that was
 * already correct.
 * @param {string} selector
 * @returns {string}
 */
function ruleBlockFor(selector) {
    const anchored = '\n' + selector + ' {';
    const idx = css.indexOf(anchored);
    t.isTrue(idx !== -1, 'a top-level rule for "' + selector + '" exists in tablet.css');
    if (idx === -1) return '';
    t.isTrue(
        css.indexOf(anchored, idx + 1) === -1,
        'exactly one top-level rule for "' + selector + '" -- two would mean this spec is only ever checking the first'
    );
    const close = css.indexOf('}', idx);
    return css.slice(idx, close);
}

t.test('the panel is still the fixed-height, clipping flex column this whole spec is premised on', () => {
    // If this ever stops being true the bug below cannot happen -- and the
    // rest of this file would be guarding rules that no longer matter. Fail
    // loudly here rather than let the other tests pass for the wrong reason.
    const block = ruleBlockFor('.k9tablet-panel');
    t.isTrue(/flex-direction:\s*column/.test(block), 'panel lays its children out in a column');
    t.isTrue(/overflow:\s*hidden/.test(block), 'panel clips (which is what turned an overflow into lost content)');
    t.isTrue(/height:\s*min\(/.test(block), 'panel height is capped, so a tall screen genuinely has to scroll');
});

t.test('THE FIX: the scrolling screen may shrink below its own content height, so overflow-y actually engages', () => {
    const block = ruleBlockFor('.k9tablet-screen');
    t.isTrue(/overflow-y:\s*auto/.test(block), 'the screen is the scroll container');
    t.isTrue(
        /min-height:\s*0/.test(block),
        'min-height:0 -- WITHOUT this, flex min-height:auto pins the item to its content height, '
        + 'overflow-y:auto never engages, and .k9tablet-panel silently clips the bottom off every long screen'
    );
});

t.test('the fixed chrome around the screen is never squeezed instead', () => {
    // Once the screen CAN shrink, the flex algorithm is free to shrink its
    // siblings too. None of these three scroll, so shrinking them does not
    // hide content behind a scrollbar -- it crops the title, the tab labels
    // or an action notice outright.
    for (const selector of ['.k9tablet-header', '.k9tablet-tabs', '.k9tablet-notice']) {
        const block = ruleBlockFor(selector);
        t.isTrue(
            /flex-shrink:\s*0/.test(block),
            selector + ' must not shrink -- it is fixed chrome with nothing to give'
        );
    }
});

t.test('no other direct child of the panel quietly became a second scroll region', () => {
    // The panel is meant to have exactly ONE scrollable area. A second one
    // is how you get two nested scrollbars and content reachable only by
    // scrolling the right one -- the same class of "I cannot see it" the
    // original bug produced.
    const screenBlock = ruleBlockFor('.k9tablet-screen');
    t.isTrue(/overflow-y:\s*auto/.test(screenBlock), 'the screen is one');
    for (const selector of ['.k9tablet-header', '.k9tablet-tabs', '.k9tablet-notice']) {
        const block = ruleBlockFor(selector);
        t.isFalse(
            /overflow-y:\s*(auto|scroll)/.test(block),
            selector + ' must not also scroll'
        );
    }
});

t.run();
