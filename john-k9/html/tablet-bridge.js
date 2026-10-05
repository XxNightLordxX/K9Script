/*
    john-k9/html/tablet-bridge.js

    Loaded by html/index.html (the resource's one `ui_page`, alongside the
    existing HUD's app.js -- see this file's own note there). Its ONLY job
    is to bridge the K9 Command Tablet's isolated <iframe src="tablet.html">
    (html/tablet.js) to the SendNUIMessage pushes Lua sends on the TOP
    window -- nothing here renders anything, decides anything, or calls
    SetNuiFocus. See html/tablet.js's own header for the full NUI contract
    this relays, and its "ARCHITECTURE NOTE" for why an iframe needs this
    at all: SendNUIMessage's delivery targets the top-level window only, it
    does not automatically reach a descendant iframe's own `message`
    listener, so this file exists purely to forward it down.

    Deliberately does NOT touch html/app.js in any way -- a second,
    independent `window.addEventListener('message', ...)` here coexists
    with app.js's own listener with zero interference (DOM listeners
    stack; neither removes nor blocks the other), and this file ignores
    every action that isn't its own ('tablet:' prefix), leaving 'hud:'/
    'audio:' traffic exactly as untouched as it already was.

    Also carries a SECOND, independent Escape-key listener on the TOP
    document (belt-and-suspenders alongside html/tablet.js's own Escape
    listener inside the iframe's document) -- see the comment on
    handleTopLevelEscape() below for why keyboard-focus ambiguity between
    the top document and the iframe's document makes this worth having
    twice rather than once.
*/
(function () {
    'use strict';

    var wrapEl = null;
    var frameEl = null;

    function isTabletAction(action) {
        return typeof action === 'string' && action.indexOf('tablet:') === 0;
    }

    function setVisible(visible) {
        if (!wrapEl) return;
        wrapEl.classList.toggle('hidden', !visible);
        wrapEl.setAttribute('aria-hidden', visible ? 'false' : 'true');
    }

    function relayToFrame(msg) {
        if (!frameEl || !frameEl.contentWindow) return;
        try {
            frameEl.contentWindow.postMessage(msg, '*');
        } catch (err) {
            // Iframe not ready / navigated away -- nothing to relay to.
        }
    }

    function handleTopLevelMessage(event) {
        var msg = event.data;
        if (!msg || !isTabletAction(msg.action)) return;

        if (msg.action === 'tablet:open') {
            setVisible(true);
        } else if (msg.action === 'tablet:close') {
            setVisible(false);
        }

        relayToFrame(msg);
    }

    /**
     * Independent Escape handler on the TOP document. SetNuiFocus routes
     * ALL keyboard input to this resource's NUI browser while the tablet is
     * open, but WHICH document within that browser actually receives a
     * given keydown depends on which element currently holds DOM focus --
     * html/tablet.js focuses its own search input on open and listens for
     * Escape in its OWN document, which is the expected common case, but
     * this resource has no independent confirmation that a focus-mgmt bug,
     * a click outside any input, or an engine quirk could never leave focus
     * sitting on the TOP document instead. Given how much this task's own
     * brief stresses "ESC must always work" / "a stuck NUI focus locks the
     * player out of their own game", a second, independent listener here
     * costs nothing and removes that single point of failure -- both paths
     * end up calling the exact same tablet:close fetch, which
     * client/tablet.lua must treat as idempotent/safe to receive more than
     * once for the same close.
     */
    function handleTopLevelEscape(e) {
        if (!wrapEl || wrapEl.classList.contains('hidden')) return;
        if (!(e && (e.key === 'Escape' || e.key === 'Esc' || e.keyCode === 27))) return;

        setVisible(false);
        try {
            fetch('https://' + resolveResourceNameForEscape() + '/tablet:close', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json; charset=UTF-8' },
                body: JSON.stringify({}),
            }).catch(function () {});
        } catch (err) {
            // Swallowed -- see html/tablet.js's own resolveResourceName() note.
        }
        relayToFrame({ action: 'tablet:close', data: {} });
    }

    function resolveResourceNameForEscape() {
        try {
            if (typeof GetParentResourceName === 'function') return GetParentResourceName();
        } catch (err) {
            // fall through
        }
        return 'john-k9';
    }

    function init() {
        wrapEl = document.getElementById('k9tablet-wrap');
        frameEl = document.getElementById('k9tablet-frame');
        window.addEventListener('message', handleTopLevelMessage);
        document.addEventListener('keydown', handleTopLevelEscape);
    }

    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', init);
    } else {
        init();
    }
})();
