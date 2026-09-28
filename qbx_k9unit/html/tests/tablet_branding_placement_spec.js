/*
    html/tests/tablet_branding_placement_spec.js

    Covers the "logo everywhere, not just the header corner" pass:
    html/tablet.js's buildBrandingMark(), the larger one-off badge shown on
    buildViewerGate() (the screen a player sees before their own record has
    loaded -- both the tablet's true "landing" moment and its loading
    state, covered together on purpose; see that function's own doc
    comment for why this is the ONLY other place a logo appears besides
    the small, already-everywhere header mark covered in
    tablet_role_theme_certtiers_spec.js).

    Deliberately a SEPARATE file from that spec (which already owns the
    header-mark branding coverage) rather than appended to it, to keep
    this pass's diff isolated in a file nobody else is mid-edit on.

    Does NOT re-cover ground tablet_role_theme_certtiers_spec.js already
    owns (header logo renders/degrades, branding.theme seeds the first
    paint) except where this pass's own change touches it directly.
*/
'use strict';

const fs = require('fs');
const path = require('path');
const t = require('./testkit');
const { createHarness, jsonResponse } = require('./tablet-sandbox');
const { findAll, findByText, openSettingsSection } = require('./tablet-dom-stub');

function routeFetch(handlers) {
    return function (url, init) {
        const name = url.split('/').pop();
        const body = init && init.body ? JSON.parse(init.body) : undefined;
        const h = handlers[name];
        if (!h) return Promise.reject(new Error('tablet_branding_placement_spec: unhandled NUI callback ' + name));
        return Promise.resolve(jsonResponse(h(body)));
    };
}

// requestMyRecord never resolves -- keeps state.viewer null and
// state.myRecordLoading true forever, i.e. buildViewerGate() stays on
// screen for the whole test, exactly like html/tests/tablet_open_close_spec.js's
// own NEVER_RESOLVING_MY_RECORD fixture.
const NEVER_RESOLVING_MY_RECORD = {
    'tablet:requestMyRecord': () => new Promise(() => {}),
};

async function settle(times) {
    for (let i = 0; i < (times || 3); i++) await new Promise((r) => setImmediate(r));
}

/** Every element anywhere under `node` that ever had innerHTML written to
 * it -- html/tests/tablet-dom-stub.js's Element.innerHTML setter records
 * every write rather than executing it, so a non-empty result here would
 * mean SOME code path used innerHTML instead of textContent/setAttribute. */
function anyInnerHTMLWrites(node) {
    return findAll(node, (n) => n.innerHTMLWriteCount > 0).length;
}

// ======================================================================
// LANDING / LOADING BADGE
// ======================================================================

t.test('landing/loading screen: logo + serverName render as a framed badge while requestMyRecord is in flight', async () => {
    const h = createHarness({ fetchImpl: routeFetch(NEVER_RESOLVING_MY_RECORD) });
    h.postMessage('tablet:open', { branding: { serverName: 'Crimson Roleplay', logo: 'images/logo.png' } });
    await settle();

    const frames = findAll(h.getRoot(), (n) => n.classList && n.classList.contains('k9tablet-branding-mark-frame'));
    t.equals(frames.length, 1, 'exactly one badge, on the landing/loading screen only');

    const imgs = findAll(h.getRoot(), (n) => n.tagName === 'img' && n.classList.contains('k9tablet-branding-mark-logo'));
    t.equals(imgs.length, 1);
    t.equals(imgs[0].getAttribute('src'), 'images/logo.png');
    t.equals(imgs[0].getAttribute('alt'), 'Crimson Roleplay', 'alt text carries the server name, never the raw path');

    // Still exactly one SMALL header mark too -- the badge is additive to
    // the existing header logo, not a replacement for it.
    const headerLogos = findAll(h.getRoot(), (n) => n.tagName === 'img' && n.classList.contains('k9tablet-branding-logo'));
    t.equals(headerLogos.length, 1);

    const markNames = findAll(h.getRoot(), (n) => n.classList && n.classList.contains('k9tablet-branding-mark-name'));
    t.equals(markNames.length, 1);
    t.equals(markNames[0].style.display, 'none', 'fallback text stays hidden while the badge logo has not (yet) failed to load');

    // Still shown exactly once elsewhere in this codebase's own tests
    // (tablet_open_close_spec.js): the loading text itself is untouched.
    t.isTrue(findByText(h.getRoot(), 'Loading...').length >= 1);
});

t.test('landing/loading screen: no logo configured at all -- serverName text renders directly on the badge, no <img> or frame built', async () => {
    const h = createHarness({ fetchImpl: routeFetch(NEVER_RESOLVING_MY_RECORD) });
    h.postMessage('tablet:open', { branding: { serverName: 'Crimson Roleplay' } });
    await settle();

    t.equals(findAll(h.getRoot(), (n) => n.classList && n.classList.contains('k9tablet-branding-mark-frame')).length, 0);
    t.equals(findAll(h.getRoot(), (n) => n.tagName === 'img' && n.classList.contains('k9tablet-branding-mark-logo')).length, 0);

    const markNames = findAll(h.getRoot(), (n) => n.classList && n.classList.contains('k9tablet-branding-mark-name'));
    t.equals(markNames.length, 1);
    t.equals(markNames[0]._textContent, 'Crimson Roleplay');
    t.isFalse(markNames[0].style.display === 'none', 'no logo at all means the text is visible immediately, never hidden waiting on an image that was never requested');
});

t.test('landing/loading screen: neither serverName nor logo configured -- badge wrapper is empty, no crash', async () => {
    const h = createHarness({ fetchImpl: routeFetch(NEVER_RESOLVING_MY_RECORD) });
    h.postMessage('tablet:open', { branding: {} });
    await settle();

    t.equals(findAll(h.getRoot(), (n) => n.classList && n.classList.contains('k9tablet-branding-mark-frame')).length, 0);
    t.equals(findAll(h.getRoot(), (n) => n.classList && n.classList.contains('k9tablet-branding-mark-name')).length, 0);
    t.isTrue(findByText(h.getRoot(), 'Loading...').length >= 1, 'still degrades to the ordinary loading text, never a blank screen');
});

t.test('landing/loading screen: missing/broken logo file -- an onerror hides the frame and reveals serverName, never a broken-image icon', async () => {
    const h = createHarness({ fetchImpl: routeFetch(NEVER_RESOLVING_MY_RECORD) });
    h.postMessage('tablet:open', { branding: { serverName: 'Crimson Roleplay', logo: 'images/does-not-exist.png' } });
    await settle();

    const frame = findAll(h.getRoot(), (n) => n.classList && n.classList.contains('k9tablet-branding-mark-frame'))[0];
    const img = findAll(h.getRoot(), (n) => n.tagName === 'img' && n.classList.contains('k9tablet-branding-mark-logo'))[0];
    const name = findAll(h.getRoot(), (n) => n.classList && n.classList.contains('k9tablet-branding-mark-name'))[0];
    t.isDefined(frame);
    t.isDefined(img);
    t.equals(name.style.display, 'none', 'hidden before the failure fires');

    img._dispatch('error');

    t.equals(frame.style.display, 'none', 'the whole frame (border/background box) hides with the broken image, not just the <img> -- no empty outline left behind');
    t.equals(name.style.display, '', 'serverName text is revealed');
});

t.test('landing/loading screen: a hostile/typo\'d logo path is set as a literal attribute value, never interpolated into markup, and never crashes the page', async () => {
    const hostilePath = '" onerror="alert(1)"><img src=x onerror=alert(2)//';
    const h = createHarness({ fetchImpl: routeFetch(NEVER_RESOLVING_MY_RECORD) });
    h.postMessage('tablet:open', { branding: { serverName: 'Crimson Roleplay', logo: hostilePath } });
    await settle();

    // The page did not crash and rendered its normal structure.
    t.isTrue(findByText(h.getRoot(), 'Loading...').length >= 1);

    const img = findAll(h.getRoot(), (n) => n.tagName === 'img' && n.classList.contains('k9tablet-branding-mark-logo'))[0];
    t.isDefined(img, 'a single <img> element is still built -- the hostile string is DATA, not markup');
    t.equals(img.getAttribute('src'), hostilePath, 'the raw string is preserved verbatim as an attribute value (setAttribute), never parsed as HTML');

    // No second, injected <img> anywhere -- exactly one image-like element
    // for this badge, proving the "><img ...> fragment never became real
    // markup.
    t.equals(findAll(h.getRoot(), (n) => n.tagName === 'img').length, 2, 'exactly the header logo + the badge logo -- no extra element was injected');

    t.equals(anyInnerHTMLWrites(h.getRoot()), 0, 'innerHTML was never written to by any element on the page for this open');
});

t.test('landing/loading screen: a hostile serverName string renders verbatim as text, never executed/escaped into markup', async () => {
    const malicious = '<img src=x onerror=alert(1)>';
    const h = createHarness({ fetchImpl: routeFetch(NEVER_RESOLVING_MY_RECORD) });
    h.postMessage('tablet:open', { branding: { serverName: malicious } });
    await settle();

    const names = findAll(h.getRoot(), (n) => n.classList && n.classList.contains('k9tablet-branding-mark-name'));
    t.equals(names.length, 1);
    t.equals(names[0]._textContent, malicious, 'rendered as plain text content, exactly like the header\'s own branding-name element');
    t.equals(anyInnerHTMLWrites(h.getRoot()), 0);
});

// ======================================================================
// THEME STILL APPLIES ALONGSIDE THE NEW BADGE
// ======================================================================

t.test('branding.theme still seeds the theme screen\'s draft colours when a logo/serverName badge is also configured', async () => {
    const HIGH_COMMAND_VIEWER = { citizenid: 'HC1', name: 'Chief', isHighCommand: true, effectivePermissions: ['k9.access'], allowSelfGrant: false };
    // tablet:getTheme is fetched once automatically at open AND again the
    // moment the Theme tab is clicked (html/tablet.js's own loadTheme()
    // doc comment) -- left permanently unresolved here (same technique as
    // tablet_open_close_spec.js's NEVER_RESOLVING_MY_RECORD) so this test
    // only ever observes the SEEDED draft (applyBrandingSeedTheme(), applied
    // synchronously at open, before either fetch could resolve), exactly
    // like tablet_role_theme_certtiers_spec.js's own seeding test does
    // before it separately resolves the fetch to prove the override.
    const h = createHarness({
        fetchImpl: routeFetch({
            'tablet:requestMyRecord': () => ({ ok: true, viewer: HIGH_COMMAND_VIEWER, certifications: [], xp: null, tierLabel: null, myFeatures: [] }),
            'tablet:getTheme': () => new Promise(() => {}),
        }),
    });
    h.postMessage('tablet:open', {
        branding: {
            serverName: 'Crimson Roleplay',
            logo: 'images/logo.png',
            theme: { primaryColor: '#C8102E', accentColor: '#FF2D2D', backgroundColor: '#0B0B0D', textColor: '#F5F5F5' },
        },
    });
    await settle();

    // requestMyRecord resolves here (unlike the other tests in this file),
    // so the viewer gate/badge has already been replaced by the tabbed
    // screen by this point -- this test is only about theme seeding still
    // working correctly with a logo/serverName configured alongside it,
    // not about the badge's own visibility.
    openSettingsSection(h.getRoot(), 'Tablet Theme');
    await settle();
    const colorInputs = findAll(h.getRoot(), (n) => n.tagName === 'input' && n.getAttribute('type') === 'color');
    t.isTrue(colorInputs.length > 0, 'theme screen still builds normally with a badge configured alongside it');
    t.isTrue(colorInputs.some((i) => i.value === '#C8102E'), 'the branding-seeded primaryColor still pre-fills the draft with the badge also configured');
});

// ======================================================================
// CSS: SHAPE-AGNOSTIC, NEVER-DISTORT RULES (a very wide wordmark and a
// very tall crest must both render without distortion) -- the dom stub
// has no CSS engine (see tablet-dom-stub.js's own header), so this reads
// html/tablet.css's actual source text and checks the specific rules that
// make this true for BOTH logo classes, rather than asserting computed
// pixels no stub here can produce.
// ======================================================================

const tabletCssSource = fs.readFileSync(path.join(__dirname, '..', 'tablet.css'), 'utf8');

function ruleBlockFor(selector) {
    const idx = tabletCssSource.indexOf(selector + ' {');
    t.isTrue(idx !== -1, 'selector "' + selector + '" exists in tablet.css');
    const close = tabletCssSource.indexOf('}', idx);
    return tabletCssSource.slice(idx, close);
}

t.test('CSS: the header logo never gets a fixed width paired with a fixed height (the actual squash/stretch risk for a non-square image)', () => {
    const block = ruleBlockFor('.k9tablet-branding-logo');
    t.isTrue(/height:\s*28px/.test(block), 'row height is constrained');
    t.isTrue(/width:\s*auto/.test(block), 'width follows the image\'s own ratio, never forced to match height');
    t.isTrue(/max-width:/.test(block), 'an extreme wordmark is still capped so it cannot overrun the header');
    t.isTrue(/object-fit:\s*contain/.test(block), 'contain is the actual distortion guard even once max-width clips the box');
});

t.test('CSS: the landing/loading badge logo has the same shape-agnostic, never-distort rules as the header logo', () => {
    const block = ruleBlockFor('.k9tablet-branding-mark-logo');
    t.isTrue(/height:\s*\d+px/.test(block));
    t.isTrue(/width:\s*auto/.test(block));
    t.isTrue(/max-width:/.test(block));
    t.isTrue(/object-fit:\s*contain/.test(block));
});

t.test('CSS: both logo placements use the four existing theme custom properties (or theme-neutral greys), never a new hardcoded brand colour', () => {
    const headerBlock = ruleBlockFor('.k9tablet-branding-logo');
    const markBlock = ruleBlockFor('.k9tablet-branding-mark-logo');
    const frameBlock = ruleBlockFor('.k9tablet-branding-mark-frame');
    const nameBlock = ruleBlockFor('.k9tablet-branding-name');
    const markNameBlock = ruleBlockFor('.k9tablet-branding-mark-name');

    // The boundary/background treatment is deliberately theme-neutral grey
    // (readable against an operator-chosen dark OR light backgroundColor),
    // not a hardcoded brand hue -- this asserts no brand-specific hex
    // (e.g. crimson) was hardcoded into the layout rules themselves.
    [headerBlock, markBlock, frameBlock].forEach((block) => {
        t.isFalse(/#[0-9a-fA-F]{3,6}/.test(block), 'no hardcoded hex colour in a logo/frame rule');
    });

    // The two branding NAME labels reuse the existing accent custom
    // property (with its existing fallback), same as every other themed
    // element in this file -- never a second, parallel colour system.
    [nameBlock, markNameBlock].forEach((block) => {
        t.isTrue(/var\(--k9tablet-accent/.test(block), 'branding name colour comes from the shared theme custom property');
    });
});

t.run();
