/*
    html/tests/hud_partner_condition_spec.js

    Covers the HANDLER CONDITION BADGE extension to html/app.js
    (applyPartnerCondition(), the `hud:partnerCondition` message handler) --
    see server/wellbeing.lua's own "HANDLER CONDITION BADGE" header
    section for the full server-side design this renders, and this file's
    own "HANDLER CONDITION BADGE CONTRACT" header section for the wire
    contract.

    WHAT THIS FILE PROVES:
      1. `#k9partner-badge` is a SEPARATE element from `#k9hud` -- a
         `hud:partnerCondition` push never touches `#k9hud`'s own
         visibility, and a `hud:updateVitals` push never touches
         `#k9partner-badge`'s.
      2. `visible: true` shows the badge and renders `tags` -> resolved
         words, joined; `visible: false` hides it and touches nothing
         else.
      3. An empty `tags` array (while visible) renders the `fine` string.
      4. `data.strings` (once client/hud.lua sends one, per its own
         locale()-resolved contract) overrides PARTNER_CONDITION_DEFAULT_STRINGS
         per-key, with the English fallback used for any key `strings`
         does not cover.
      5. Defensive handling: malformed/missing `tags`, an unrecognized tag
         code (dropped, never rendered as "undefined"), non-string tag
         entries, a null/undefined data payload -- none of these throw.
      6. NEVER innerHTML -- every string this handler ever writes goes
         through textContent only (the same standing rule/proof technique
         xss_spec.js already applies to the Distraction/xpTier rows).
*/
'use strict';

const t = require('./testkit');
const { createHarness } = require('./sandbox');

function freshHarnessNoAudio() {
    return createHarness({ AudioContextCtor: undefined });
}

t.test('#k9partner-badge starts hidden before any message arrives', () => {
    const h = freshHarnessNoAudio();
    t.isTrue(h.getPartnerBadge().row.classList.contains('hidden'));
});

t.test('visible: true shows the badge and renders the label plus every tag word, comma-joined, in server-sent order', () => {
    const h = freshHarnessNoAudio();
    // TWO TAGS, DELIBERATELY, so the comma-join and the server-sent order
    // this test names are actually exercised. 'tired' is now the only tag
    // the server can emit on its own (mood/fear-stress/injury/hunger/thirst
    // were removed by owner directive, and their tag codes went with them),
    // so the second word is supplied the only way a second word can still
    // legitimately arrive: a `strings` entry from a server that knows a tag
    // this client build does not. Rendering it proves the join, the order,
    // and the forward-compatibility path in one.
    h.postMessage('hud:partnerCondition', {
        visible: true,
        tags: ['tired', 'some_future_tag'],
        strings: { some_future_tag: 'Restless' },
    });

    const badge = h.getPartnerBadge();
    t.isFalse(badge.row.classList.contains('hidden'));
    t.equals(badge.row.getAttribute('aria-hidden'), 'false');
    t.equals(badge.label.textContent, 'K9 Partner');
    t.equals(badge.value.textContent, 'Tired, Restless');
});

t.test('visible: true with an EMPTY tags array renders the "fine" string, not a blank value', () => {
    const h = freshHarnessNoAudio();
    h.postMessage('hud:partnerCondition', { visible: true, tags: [] });

    t.equals(h.getPartnerBadge().value.textContent, 'Fine');
});

t.test('visible: false hides the badge and sets aria-hidden back to true, regardless of what tags carried', () => {
    const h = freshHarnessNoAudio();
    h.postMessage('hud:partnerCondition', { visible: true, tags: ['tired'] });
    t.isFalse(h.getPartnerBadge().row.classList.contains('hidden'));

    h.postMessage('hud:partnerCondition', { visible: false, tags: [] });
    const badge = h.getPartnerBadge();
    t.isTrue(badge.row.classList.contains('hidden'));
    t.equals(badge.row.getAttribute('aria-hidden'), 'true');
});

t.test('COMPLETE INDEPENDENCE FROM #k9hud: a hud:partnerCondition push never touches #k9hud\'s own visibility or bar DOM, in either direction', () => {
    const h = freshHarnessNoAudio();
    // #k9hud starts hidden (CanShowK9UI false by default in this harness's
    // world -- no hud:updateVitals push has ever been sent).
    t.isTrue(h.getRoot().classList.contains('hidden'));

    h.postMessage('hud:partnerCondition', { visible: true, tags: ['tired'] });
    t.isTrue(h.getRoot().classList.contains('hidden'), '#k9hud must stay exactly as it was -- this message must never show it');

    // And the reverse: showing #k9hud via hud:updateVitals must never
    // touch the partner badge.
    h.postMessage('hud:partnerCondition', { visible: false, tags: [] });
    t.isTrue(h.getPartnerBadge().row.classList.contains('hidden'));
    h.postMessage('hud:updateVitals', { visible: true, health: 100, stamina: 100, wellbeing: {}, xpTier: {} });
    t.isFalse(h.getRoot().classList.contains('hidden'));
    t.isTrue(h.getPartnerBadge().row.classList.contains('hidden'), 'hud:updateVitals must never show the partner badge');
});

t.test('data.strings overrides the English fallback per-key, falling back to the default only for keys strings does not cover', () => {
    const h = freshHarnessNoAudio();
    h.postMessage('hud:partnerCondition', {
        visible: true,
        tags: ['tired', 'fine'],
        strings: { tired: 'Fatigado', label: 'Mi Perro' },
    });

    const badge = h.getPartnerBadge();
    t.equals(badge.label.textContent, 'Mi Perro');
    t.equals(badge.value.textContent, 'Fatigado, Fine', "'fine' falls back to the English default since strings.fine was not sent");
});

t.test('an unrecognized tag code (present in neither strings nor the default table) is dropped, never rendered as "undefined"', () => {
    const h = freshHarnessNoAudio();
    h.postMessage('hud:partnerCondition', { visible: true, tags: ['tired', 'some_future_tag_this_build_does_not_know'] });

    t.equals(h.getPartnerBadge().value.textContent, 'Tired');
});

t.test('non-string entries in tags are ignored defensively rather than rendered', () => {
    const h = freshHarnessNoAudio();
    h.postMessage('hud:partnerCondition', { visible: true, tags: ['tired', 42, null, 'fine'] });

    t.equals(h.getPartnerBadge().value.textContent, 'Tired, Fine');
});

t.test('a missing/non-array tags field on a visible:true payload renders "fine", never throwing', () => {
    const h = freshHarnessNoAudio();
    const ok1 = (() => { try { h.postMessage('hud:partnerCondition', { visible: true }); return true; } catch (e) { return false; } })();
    t.isTrue(ok1);
    t.equals(h.getPartnerBadge().value.textContent, 'Fine');

    const ok2 = (() => { try { h.postMessage('hud:partnerCondition', { visible: true, tags: 'not-an-array' }); return true; } catch (e) { return false; } })();
    t.isTrue(ok2);
    t.equals(h.getPartnerBadge().value.textContent, 'Fine');
});

t.test('a null/undefined data payload is a silent no-op, never touching the badge\'s current state', () => {
    const h = freshHarnessNoAudio();
    h.postMessage('hud:partnerCondition', { visible: true, tags: ['tired'] });
    t.equals(h.getPartnerBadge().value.textContent, 'Tired');

    h.postMessage('hud:partnerCondition', null);
    h.postMessage('hud:partnerCondition', undefined);
    t.equals(h.getPartnerBadge().value.textContent, 'Tired', 'a malformed follow-up push must not clobber the last real state');
});

t.test('NEVER innerHTML: a battery of malicious tag/strings values never once touches innerHTML on the badge label or value elements', () => {
    const h = freshHarnessNoAudio();
    const malicious = [
        '<img src=x onerror="window.__xss_pwned=true">',
        '<script>window.__xss_pwned=true</script>',
        '"><svg onload=alert(1)>',
        '</span><b>bold-injected</b>',
    ];

    for (const payload of malicious) {
        h.postMessage('hud:partnerCondition', {
            visible: true,
            tags: ['tired'],
            strings: { label: payload, tired: payload },
        });
        const badge = h.getPartnerBadge();
        t.equals(badge.label.textContent, payload, 'malicious label reaches the DOM verbatim via textContent');
        t.equals(badge.value.textContent, payload, 'malicious tag word reaches the DOM verbatim via textContent');
    }

    t.equals(h.getPartnerBadge().label.innerHTMLWriteCount, 0);
    t.equals(h.getPartnerBadge().value.innerHTMLWriteCount, 0);
    t.isFalse(global.__xss_pwned === true, 'no injected script/handler ever actually ran');
});

t.run();
