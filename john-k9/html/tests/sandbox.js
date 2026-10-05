/*
    html/tests/sandbox.js

    Loads the REAL html/app.js (unmodified, read straight off disk) into a
    fresh Node `vm` context per test harness instance, stubbing exactly the
    browser globals its own header says it needs: `window`, `document`,
    `fetch`, `GetParentResourceName`, `AudioContext`/`webkitAudioContext`.
    Uses Node's built-in `vm` module ONLY -- no npm dependency (jsdom,
    happy-dom, etc.) -- per this task's "match the Lua suite's zero-
    dependency spirit" instruction. `vm.createContext()` gives each
    instance its own real V8 global object (real Object/Array/Math/JSON/
    Promise/etc. -- nothing reimplemented here), so app.js runs as
    authentic JS, just inside a sandboxed global scope this file controls.

    One instance == one fresh "page load": app.js is an IIFE with
    module-level singleton state (audioCtx, activeSounds,
    soundBufferCache, statEls, ...), exactly like the real page is loaded
    once per client session (see app.js's own header on why one
    AudioContext for the page's whole lifetime is correct there, not a
    leak) -- so createHarness() is called once per test CASE that needs
    isolated state, not once per spec FILE, to avoid one test's leftover
    activeSounds/soundBufferCache bleeding into the next.
*/
'use strict';

const fs = require('fs');
const path = require('path');
const vm = require('vm');
const { buildK9HudDocument } = require('./dom-stub');

const APP_JS_PATH = path.join(__dirname, '..', 'app.js');
const SOUNDS_DIR = path.join(__dirname, '..', 'sounds');

// Compiled once per process, run fresh per harness instance (vm.Script's
// whole point -- compilation is the expensive part, not execution).
const appJsSource = fs.readFileSync(APP_JS_PATH, 'utf8');
const appJsScript = new vm.Script(appJsSource, { filename: 'app.js' });

function arrayBufferFromNodeBuffer(buf) {
    return buf.buffer.slice(buf.byteOffset, buf.byteOffset + buf.byteLength);
}

/**
 * Real-filesystem-backed fetch() for `sounds/<key>.ogg` lookups -- this is
 * what makes the "404 path is live and reachable" claim genuine rather
 * than asserted: it reads the ACTUAL html/sounds/ directory contents
 * so a passing test here is a fact about the real shipped asset
 * directory, not a synthetic stand-in that could quietly drift from it.
 *
 * All five real sound keys now ship. The 404 path is therefore exercised
 * with MISSING_SOUND_KEY below -- a key deliberately chosen never to be a
 * real asset -- rather than by piggy-backing on whichever sounds happened
 * to be unsourced that week. Those tests used to break the moment the
 * missing files were added, which is a fragile way to test a code path
 * that is about fetch() returning 404, not about our asset backlog.
 * @param {string} url
 * @returns {Promise<{ok: boolean, status: number, arrayBuffer: () => Promise<ArrayBuffer>}>}
 */
/**
 * A sound key guaranteed never to exist as a shipped asset, for exercising
 * loadSoundBuffer's 404/degrade-to-silence path. It passes app.js's
 * sanitizeSoundKey (lowercase, [a-z0-9_-]) so it reaches the fetch, and it
 * is asserted absent from html/sounds/ by audio_play_spec.js's sanity test
 * -- so if anyone ever ships a file by this name, the suite says so loudly
 * instead of silently testing nothing.
 * @type {string}
 */
const MISSING_SOUND_KEY = 'nonexistent_test_sound';

function realSoundsFetch(url) {
    const m = /^sounds\/([a-z0-9_-]+)\.ogg$/.exec(url);
    if (!m) return Promise.reject(new Error(`realSoundsFetch: unexpected url ${JSON.stringify(url)}`));
    const file = path.join(SOUNDS_DIR, `${m[1]}.ogg`);
    return new Promise((resolve) => {
        fs.readFile(file, (err, buf) => {
            if (err) {
                resolve({
                    ok: false,
                    status: 404,
                    arrayBuffer: () => Promise.reject(new Error('arrayBuffer() must not be called on a non-ok response')),
                });
                return;
            }
            resolve({
                ok: true,
                status: 200,
                arrayBuffer: () => Promise.resolve(arrayBufferFromNodeBuffer(buf)),
            });
        });
    });
}

/**
 * A fake Web Audio `AudioContext` class -- NOT a real audio decoder (Node
 * has none built in without a native/npm dependency, which this harness
 * deliberately avoids). Decoding success/failure is a `behavior` knob, not
 * a real codec: what this proves is app.js's OWN control flow around
 * decodeAudioData (cache-by-key, silent failure mapping, onended cleanup,
 * gain ramping, double-stop safety) -- not whether Opus/Vorbis decoding
 * itself works, which is a browser/CEF concern outside this file's job.
 * @param {object} [behavior]
 * @returns {Function} a constructable AudioContext-shaped class
 */
function makeFakeAudioContextClass(behavior) {
    behavior = behavior || {};
    let constructCount = 0;
    const instances = [];

    function FakeAudioContext() {
        constructCount++;
        if (behavior.throwOnConstruct) {
            throw new Error('AudioContext construction failed (simulated)');
        }
        this.state = behavior.initialState || 'suspended';
        this.currentTime = 0;
        this.resumeCallCount = 0;
        const self = this;

        this.resume = function () {
            self.resumeCallCount++;
            if (behavior.resumeRejects) return Promise.reject(new Error('resume() failed (simulated)'));
            self.state = 'running';
            return Promise.resolve();
        };

        this.createGain = function () {
            const gainParam = {
                value: 0,
                _setValueAtTimeCalls: [],
                _rampCalls: [],
                _cancelCalls: 0,
                cancelScheduledValues() { gainParam._cancelCalls++; },
                setValueAtTime(v, t) { gainParam.value = v; gainParam._setValueAtTimeCalls.push({ v, t }); },
                linearRampToValueAtTime(v, t) {
                    if (behavior.rampThrows) throw new Error('linearRampToValueAtTime failed (simulated)');
                    gainParam.value = v;
                    gainParam._rampCalls.push({ v, t });
                },
            };
            const node = {
                gain: gainParam,
                _disconnected: false,
                connect() {},
                disconnect() {
                    if (behavior.disconnectThrows) throw new Error('disconnect() failed (simulated)');
                    node._disconnected = true;
                },
            };
            self._lastCreatedGain = node;
            return node;
        };

        this.createBufferSource = function () {
            const src = {
                buffer: null,
                loop: false,
                onended: null,
                _started: false,
                _stopped: false,
                _disconnected: false,
                connect() {},
                disconnect() {
                    src._disconnected = true;
                },
                start(when) {
                    if (behavior.startThrows) throw new Error('start() failed (simulated)');
                    src._started = true;
                },
                stop() {
                    if (behavior.stopThrows) throw new Error('stop() failed (simulated)');
                    // Real browsers throw InvalidStateError calling stop()
                    // twice on an already-stopped source -- handleAudioStop
                    // wraps its own call in try/catch specifically for this
                    // ("Already stopped/ended -- harmless" per its own
                    // comment), so this stub reproduces that real behavior
                    // rather than silently no-op'ing it, to actually
                    // exercise that catch path.
                    if (src._stopped) throw new Error('InvalidStateError (simulated): already stopped');
                    src._stopped = true;
                },
            };
            self._lastCreatedSource = src;
            return src;
        };

        this.decodeAudioData = function (arrayBuffer) {
            if (behavior.decodeRejects) return Promise.reject(new Error('decodeAudioData failed (simulated)'));
            if (!arrayBuffer || arrayBuffer.byteLength === 0) {
                return Promise.reject(new Error('decodeAudioData: empty buffer (simulated)'));
            }
            return Promise.resolve({ __fakeAudioBuffer: true, byteLength: arrayBuffer.byteLength });
        };

        instances.push(this);
    }

    FakeAudioContext._constructCount = () => constructCount;
    // Test-only inspection hook -- lets a spec reach the lazily-constructed
    // singleton app.js builds itself inside ensureAudioContext() (never
    // exposed by app.js directly, by design -- see this file's header:
    // this harness only drives app.js through its real message contract).
    FakeAudioContext._instances = instances;
    return FakeAudioContext;
}

/**
 * Polls `predicate()` until it returns truthy or `timeoutMs` elapses,
 * yielding a real event-loop turn (setImmediate) between attempts --
 * needed because app.js's audio path is genuinely asynchronous (a real
 * fs.readFile-backed fetch behind loadSoundBuffer(), not just a Promise
 * microtask), so a single `await` of one microtask tick is not always
 * enough to observe its effects. Bounded and always resolves/rejects, so a
 * genuine regression in app.js (e.g. a promise chain that silently never
 * settles) fails the test with a clear timeout message rather than hanging
 * the whole spec process forever.
 * @param {() => boolean} predicate
 * @param {{ timeoutMs?: number, label?: string }} [opts]
 * @returns {Promise<void>}
 */
function waitFor(predicate, opts) {
    opts = opts || {};
    const timeoutMs = opts.timeoutMs || 2000;
    const start = Date.now();
    return new Promise((resolve, reject) => {
        (function tick() {
            if (predicate()) { resolve(); return; }
            if (Date.now() - start > timeoutMs) {
                reject(new Error(`waitFor: timed out after ${timeoutMs}ms${opts.label ? ` waiting for: ${opts.label}` : ''}`));
                return;
            }
            setImmediate(tick);
        })();
    });
}

/**
 * Builds one fresh app.js "page load" and returns a harness object for
 * driving it from a test. See this file's header for the one-instance-
 * per-isolated-test-case posture.
 *
 * @param {object} [options]
 * @param {Function|null} [options.fetchImpl] custom fetch(url, init) -> Promise; defaults to realSoundsFetch for 'sounds/*.ogg' and a rejection for anything else (e.g. hud:ready's own URL, unless overridden)
 * @param {Function|undefined|null} [options.AudioContextCtor] pass `undefined` to simulate a runtime with NO Web Audio support at all; defaults to a working makeFakeAudioContextClass()
 * @param {object} [options.audioBehavior] forwarded to makeFakeAudioContextClass() when AudioContextCtor is not explicitly given
 * @param {Function|undefined} [options.getParentResourceName] defaults to `() => 'john-k9'`; pass undefined to simulate this global not existing at all (plain-browser dev-preview case, see app.js's own sendReadyAck() comment)
 * @param {boolean} [options.deferReady] if true, document.readyState starts 'loading' and init() only runs after harness.fireDomContentLoaded() is called -- exercises app.js's other startup branch
 */
function createHarness(options) {
    options = options || {};

    const doc = buildK9HudDocument();
    if (options.deferReady) doc.readyState = 'loading';

    const fetchCalls = [];
    const fetchImpl = options.fetchImpl || ((url) => {
        if (/^sounds\//.test(url)) return realSoundsFetch(url);
        return Promise.reject(new Error(`sandbox.js: no fetchImpl configured for url ${JSON.stringify(url)}`));
    });

    function fetchStub(url, init) {
        const call = { url, init };
        fetchCalls.push(call);
        const p = Promise.resolve().then(() => fetchImpl(url, init));
        // Retain the in-flight promise so settleFetches() below can await
        // the REAL completion of this call instead of a spec guessing at a
        // sleep long enough to cover it. Swallow the rejection here only so
        // an expected failure path (a 404'd sound, an unconfigured url) does
        // not surface as an unhandled rejection just because we kept a
        // second reference to the promise; the original `p` returned to the
        // caller keeps its rejection intact for app.js to handle.
        call.settled = p.then(() => undefined, () => undefined);
        return p;
    }

    /**
     * Resolves once every fetch this harness has handed out has actually
     * settled, plus a drain for the promise chain app.js hangs off it.
     *
     * WHY THIS EXISTS: the default fetchImpl is backed by a real
     * fs.readFile (see realSoundsFetch), so how long a sound takes to load
     * depends on actual disk I/O and on how loaded the machine is. Specs
     * used to cover that with a fixed `setTimeout(r, 200)` -- a guess, and
     * on a busy box an occasionally wrong one, which is a test that fails
     * without the code being broken. Awaiting the real promises is exact:
     * everything downstream of the fetch (arrayBuffer, decodeAudioData) is
     * a resolved promise in this harness, so once the fetches are done a
     * short microtask drain settles the rest.
     *
     * Note this is deliberately NOT a substitute for waitFor() when a spec
     * is asserting that something eventually becomes true -- use waitFor
     * for that. This is for the harder case: asserting that something never
     * happens, where there is no state change to poll for and the only
     * sound basis for "it didn't happen" is "all the async work finished".
     * @returns {Promise<void>}
     */
    async function settleFetches() {
        // A settling fetch can start another (app.js chaining a second
        // load), so loop until the set stops growing rather than awaiting
        // one snapshot of it.
        let seen = -1;
        while (fetchCalls.length !== seen) {
            seen = fetchCalls.length;
            await Promise.all(fetchCalls.map((c) => c.settled));
            for (let i = 0; i < 5; i += 1) await new Promise((r) => setImmediate(r));
        }
    }

    const AudioContextCtor = Object.prototype.hasOwnProperty.call(options, 'AudioContextCtor')
        ? options.AudioContextCtor
        : makeFakeAudioContextClass(options.audioBehavior);

    const sandbox = {
        document: doc,
        fetch: fetchStub,
        console,
        setTimeout,
        clearTimeout,
        queueMicrotask,
    };

    if (Object.prototype.hasOwnProperty.call(options, 'getParentResourceName')) {
        if (options.getParentResourceName !== undefined) {
            sandbox.GetParentResourceName = options.getParentResourceName;
        }
        // else: deliberately omitted from the sandbox entirely, so app.js's
        // own `GetParentResourceName()` call throws a ReferenceError inside
        // sendReadyAck()'s try/catch -- the exact "opened directly in a
        // plain browser" dev-preview scenario its own comment describes.
    } else {
        sandbox.GetParentResourceName = () => 'john-k9';
    }

    if (AudioContextCtor !== undefined) {
        sandbox.AudioContext = AudioContextCtor;
    }
    // else: leave both AudioContext and webkitAudioContext undefined on the
    // sandbox entirely, simulating a runtime with no Web Audio support --
    // ensureAudioContext()'s own `window.AudioContext || window.webkitAudioContext`
    // check must see both as undefined, not throw a ReferenceError; global
    // lookups of an undeclared global inside a vm context resolve to
    // `undefined` via the sandbox's property lookup (not a ReferenceError),
    // exactly like an undeclared global in a real browser `window`.

    sandbox.window = sandbox; // self-reference: `window === globalThis` for this context, as in a real page
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
    appJsScript.runInContext(sandbox);

    if (options.deferReady) {
        // app.js's init() has NOT run yet -- it's parked behind
        // `document.addEventListener('DOMContentLoaded', init)`. Nothing to
        // do here; the harness exposes fireDomContentLoaded() below.
    }

    /**
     * Dispatches a `message` event exactly as SendNUIMessage's delivery
     * does client-side -- `{ data: { action, data } }` on `window`. This is
     * this harness's core driver: every hud:updateVitals/audio:play/
     * audio:setGain/audio:stop test goes through this, not through calling
     * any internal app.js function directly (app.js exposes none -- the
     * IIFE's whole surface area IS this message listener, by design).
     * @param {string} action
     * @param {*} data
     */
    function postMessage(action, data) {
        const listeners = sandbox.__listeners['message'] || [];
        for (const fn of listeners.slice()) {
            fn({ data: { action, data } });
        }
    }

    /** Dispatches an arbitrary raw `message` event payload (bypassing the
     * action/data convenience wrapper above) -- for malformed-message
     * robustness tests (non-object data, missing action, etc). */
    function postRawMessage(rawData) {
        const listeners = sandbox.__listeners['message'] || [];
        for (const fn of listeners.slice()) {
            fn({ data: rawData });
        }
    }

    function fireDomContentLoaded() {
        doc._dispatch('DOMContentLoaded', {});
    }

    function getRoot() {
        return doc.getElementById('k9hud');
    }

    function getBarRow(stat) {
        return {
            row: doc.querySelector(`[data-stat-row="${stat}"]`),
            fill: doc.querySelector(`[data-fill="${stat}"]`),
            value: doc.querySelector(`[data-value="${stat}"]`),
        };
    }

    function getStatusRow(stat) {
        return {
            row: doc.querySelector(`[data-stat-row="${stat}"]`),
            value: doc.querySelector(`[data-status="${stat}"]`),
        };
    }

    /** The HANDLER CONDITION BADGE's own (row, label, value) triple --
     * mirrors getBarRow/getStatusRow above, for the SEPARATE
     * `#k9partner-badge` element (see index.html's own comment on why it
     * is not one more row inside `#k9hud`). */
    function getPartnerBadge() {
        return {
            row: doc.getElementById('k9partner-badge'),
            label: doc.querySelector('[data-partner="label"]'),
            value: doc.querySelector('[data-partner="value"]'),
        };
    }

    /** The K9 ONBOARDING HINT's own (row, title, body, dismiss) quadruple --
     * mirrors getPartnerBadge() above, for the THIRD, separate
     * `#k9onboarding-hint` element. */
    function getOnboardingHint() {
        return {
            row: doc.getElementById('k9onboarding-hint'),
            title: doc.querySelector('[data-onboarding="title"]'),
            body: doc.querySelector('[data-onboarding="body"]'),
            dismiss: doc.querySelector('[data-onboarding="dismiss"]'),
        };
    }

    /** The lazily-constructed AudioContext instance app.js's own
     * ensureAudioContext() built internally (undefined until the first
     * message that needs one, e.g. 'audio:play', has been processed) --
     * only meaningful when AudioContextCtor is the default
     * makeFakeAudioContextClass() (its `_instances` inspection hook). */
    function getAudioContextInstance() {
        return AudioContextCtor && AudioContextCtor._instances ? AudioContextCtor._instances[0] : undefined;
    }

    return {
        sandbox,
        doc,
        postMessage,
        postRawMessage,
        fireDomContentLoaded,
        getRoot,
        getBarRow,
        getStatusRow,
        getPartnerBadge,
        getOnboardingHint,
        getAudioContextInstance,
        fetchCalls,
        settleFetches,
        AudioContextCtor,
    };
}

module.exports = {
    createHarness,
    makeFakeAudioContextClass,
    realSoundsFetch,
    MISSING_SOUND_KEY,
    waitFor,
    SOUNDS_DIR,
};
