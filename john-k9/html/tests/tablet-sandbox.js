/*
    html/tests/tablet-sandbox.js

    Loads the REAL html/tablet.js (unmodified, read straight off disk) into
    a fresh Node `vm` context per test harness instance -- same technique
    as html/tests/sandbox.js uses for app.js (see that file's own header),
    kept as a SEPARATE module rather than extended from it: tablet.js's DOM
    surface, event model, and NUI callback set are all wider than app.js's,
    and this way a change here can never affect the HUD's own passing
    suite.

    TEST-ONLY TIME COMPRESSION, disclosed plainly rather than silently
    baked in: this harness overrides the sandboxed `setTimeout` to cap
    every requested delay at COMPRESSED_DELAY_MS, regardless of what
    tablet.js actually asked for (its real constants -- NUI_TIMEOUT_MS=8000,
    SEARCH_DEBOUNCE_MS=300, CONFIRM_WINDOW_MS=3000 -- are unmodified in the
    real file). This is what makes it possible to exercise the
    fetchNui() timeout path, the search debounce, and the two-click
    confirm's revert-after-window behavior in milliseconds instead of
    several real seconds per test. It does NOT change tablet.js's own
    ordering/cancellation logic (clearTimeout still really cancels a
    pending compressed timer) -- only how long a real, uncancelled one
    takes to fire.
*/
'use strict';

const fs = require('fs');
const path = require('path');
const vm = require('vm');
const { buildTabletDocument } = require('./tablet-dom-stub');

// Loaded in the SAME ORDER tablet.html loads them: the catalog defines the
// three data tables tablet.js re-binds at its top, so a swap here would make
// every spec fail on undefined rather than on anything real.
const TABLET_CATALOG_PATH = path.join(__dirname, '..', 'tablet-catalog.js');
const tabletCatalogSource = fs.readFileSync(TABLET_CATALOG_PATH, 'utf8');
const tabletCatalogScript = new vm.Script(tabletCatalogSource, { filename: 'tablet-catalog.js' });

const TABLET_JS_PATH = path.join(__dirname, '..', 'tablet.js');
const tabletJsSource = fs.readFileSync(TABLET_JS_PATH, 'utf8');
const tabletJsScript = new vm.Script(tabletJsSource, { filename: 'tablet.js' });

/** See this file's header -- caps every sandboxed setTimeout delay so
 * tablet.js's real-file constants (seconds-scale) settle in milliseconds
 * under test. */
const COMPRESSED_DELAY_MS = 15;

/** Builds a fetch Response-like object exposing only what fetchNui() in
 * tablet.js ever calls (`.json()`) -- not a spec-complete Response stub.
 * @param {object} body
 * @returns {{ok: true, json: () => Promise<object>}}
 */
function jsonResponse(body) {
    return { ok: true, json: () => Promise.resolve(body) };
}

/**
 * @param {object} [options]
 * @param {(url: string, init: object) => Promise<object>} [options.fetchImpl]
 *   Defaults to rejecting every URL -- most specs override this per NUI
 *   callback name via a small router (see specs for the pattern).
 * @param {Function|undefined} [options.getParentResourceName] defaults to `() => 'john-k9'`
 * @param {boolean} [options.deferReady]
 */
function createHarness(options) {
    options = options || {};

    const doc = buildTabletDocument();
    if (options.deferReady) doc.readyState = 'loading';

    const fetchCalls = [];
    const fetchImpl = options.fetchImpl || (() => Promise.reject(new Error('tablet-sandbox: no fetchImpl configured')));

    function fetchStub(url, init) {
        const call = { url, init, body: init && init.body ? JSON.parse(init.body) : undefined };
        fetchCalls.push(call);
        return Promise.resolve().then(() => fetchImpl(url, init));
    }

    const sandbox = {
        document: doc,
        fetch: fetchStub,
        console,
        setTimeout: (fn, ms) => setTimeout(fn, Math.min(typeof ms === 'number' ? ms : 0, COMPRESSED_DELAY_MS)),
        clearTimeout,
        queueMicrotask,
    };

    if (Object.prototype.hasOwnProperty.call(options, 'getParentResourceName')) {
        if (options.getParentResourceName !== undefined) {
            sandbox.GetParentResourceName = options.getParentResourceName;
        }
        // else: deliberately omitted, exercising resolveResourceName()'s own fallback chain.
    } else {
        sandbox.GetParentResourceName = () => 'john-k9';
    }

    sandbox.window = sandbox; // window === globalThis for this context, same simplification as html/tests/sandbox.js
    sandbox.window.parent = sandbox.window; // same-origin self-reference -- exercises requestClose()'s window.parent.document path without throwing (real DOM would be a distinct object; this proves the code path is reachable/non-throwing, not the cross-document behavior itself)
    sandbox.__listeners = {};
    sandbox.addEventListener = function (type, fn) {
        (sandbox.__listeners[type] = sandbox.__listeners[type] || []).push(fn);
    };
    sandbox.removeEventListener = function (type, fn) {
        const list = sandbox.__listeners[type];
        if (!list) return;
        const idx = list.indexOf(fn);
        if (idx !== -1) list.splice(idx, 1);
    };

    vm.createContext(sandbox);
    tabletCatalogScript.runInContext(sandbox);
    tabletJsScript.runInContext(sandbox);

    function postMessage(action, data) {
        const listeners = sandbox.__listeners['message'] || [];
        for (const fn of listeners.slice()) fn({ data: { action, data } });
    }

    function postRawMessage(rawData) {
        const listeners = sandbox.__listeners['message'] || [];
        for (const fn of listeners.slice()) fn({ data: rawData });
    }

    function fireDomContentLoaded() {
        doc._dispatch('DOMContentLoaded', {});
    }

    function dispatchKeydown(key) {
        doc._dispatch('keydown', { key });
    }

    function getRoot() {
        return doc.getElementById('k9tablet-root');
    }

    return {
        sandbox,
        doc,
        postMessage,
        postRawMessage,
        fireDomContentLoaded,
        dispatchKeydown,
        getRoot,
        fetchCalls,
    };
}

module.exports = { createHarness, jsonResponse, COMPRESSED_DELAY_MS };
