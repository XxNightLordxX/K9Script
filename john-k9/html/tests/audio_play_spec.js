/*
    html/tests/audio_play_spec.js

    Covers `audio:play` (handleAudioPlay/loadSoundBuffer/ensureAudioContext/
    sanitizeSoundKey/clampGain in html/app.js) against the REAL
    html/sounds/ directory contents, not a synthetic always-ok/always-404
    stand-in -- see sandbox.js's realSoundsFetch().

    All five real sound keys now ship (bark, bark_alert, bark_aggressive,
    bark_calm from client/audio.lua's SOUND_NAME_TO_FILE_KEY, plus
    growl_ambient from Config.ProximityAudioFX.soundName via
    ToAudioFileKey's lowercase fallback), so every one of them exercises
    the 200/decode-success path.

    The 404 / degrade-to-silence path is exercised with
    sandbox.js's MISSING_SOUND_KEY instead. This spec previously drove
    that path using whichever sounds were unsourced at the time, which
    meant shipping the missing audio turned four green tests red without
    anything actually regressing. The path under test is "fetch returned
    404", not "our asset backlog is non-empty" -- so it is now tested with
    a key chosen never to exist, and the sanity test below asserts both
    halves of that assumption so neither can drift unnoticed.
*/
'use strict';

const fs = require('fs');
const t = require('./testkit');
const { createHarness, waitFor, SOUNDS_DIR, MISSING_SOUND_KEY } = require('./sandbox');

t.test('sanity: every real sound key ships, and MISSING_SOUND_KEY genuinely does not', () => {
    for (const shipped of ['bark', 'bark_alert', 'bark_aggressive', 'bark_calm', 'growl_ambient']) {
        t.isTrue(fs.existsSync(`${SOUNDS_DIR}/${shipped}.ogg`), `${shipped}.ogg must exist -- app.js can request this key, and a missing file is a silent 404 in play, indistinguishable from the feature being off`);
    }
    t.isFalse(fs.existsSync(`${SOUNDS_DIR}/${MISSING_SOUND_KEY}.ogg`), `${MISSING_SOUND_KEY}.ogg must NOT exist, or every 404-path test below silently stops testing the 404 path`);
});

t.test('audio:play against a real, existing file (bark.ogg) actually starts playback', async () => {
    const h = createHarness();
    h.postMessage('audio:play', { id: 1, sound: 'bark', gain: 0.6, loop: false });

    await waitFor(() => {
        const ctx = h.getAudioContextInstance();
        return !!(ctx && ctx._lastCreatedSource && ctx._lastCreatedSource._started);
    }, { label: 'bark.ogg to start playing' });

    const ctx = h.getAudioContextInstance();
    t.isTrue(ctx._lastCreatedSource._started);
    t.isFalse(ctx._lastCreatedSource.loop, 'loop:false passed through');
    t.near(ctx._lastCreatedGain.gain.value, 0.6, 0.0001, 'initial gain applied to the GainNode');
});

t.test('audio:play against a missing file (the live 404 path) degrades to silence -- no source ever created, no throw', async () => {
    const h = createHarness();
    h.postMessage('audio:play', { id: 2, sound: MISSING_SOUND_KEY, gain: 1, loop: false });

    // Wait for the real (async) fetch/404 round-trip to ACTUALLY settle,
    // rather than sleeping a fixed 200ms and hoping that covered it. This
    // assertion is about something never happening, so there is no state
    // change to poll for with waitFor -- the only sound basis for "no
    // source was created" is "all the async work is finished". The default
    // fetchImpl is a real fs.readFile, so its duration depends on disk and
    // machine load; a fixed sleep here is a test that can fail without the
    // code being broken.
    await h.settleFetches();

    const ctx = h.getAudioContextInstance();
    t.isDefined(ctx, 'AudioContext IS still constructed (ensureAudioContext runs before the fetch resolves)');
    t.isUndefined(ctx._lastCreatedSource, 'no BufferSourceNode is ever created for a 404\'d sound');
});

t.test('every real sound key now decodes and plays -- the shipped asset set is complete end to end', async () => {
    // The inverse of the old "four missing keys stay silent" test. Now that
    // all five ship, the meaningful assertion is that each one actually
    // reaches a playing BufferSourceNode through app.js's real fetch/decode
    // path -- a file that is present but unreadable, or registered under the
    // wrong name, would show up here rather than as silence in play.
    for (const sound of ['bark', 'bark_alert', 'bark_aggressive', 'bark_calm', 'growl_ambient']) {
        const h = createHarness();
        h.postMessage('audio:play', { id: 100, sound, gain: 1, loop: false });
        // Poll for the source to start instead of sleeping a fixed 200ms.
        // This is a positive assertion, so waitFor is the right tool: it
        // returns the instant the load lands (usually far under 200ms) and
        // still fails with a clear message if it genuinely never does,
        // instead of silently depending on real fs.readFile I/O beating an
        // arbitrary deadline on a loaded machine.
        await waitFor(() => {
            const c = h.getAudioContextInstance();
            return !!(c && c._lastCreatedSource && c._lastCreatedSource._started);
        }, { timeoutMs: 3000, label: `${sound}.ogg to load, decode and start playing` });
        const ctx = h.getAudioContextInstance();
        t.isDefined(ctx._lastCreatedSource, `${sound}.ogg must reach a playing source`);
        t.isTrue(ctx._lastCreatedSource._started, `${sound}.ogg's source must actually be started`);
        t.isTrue(ctx._lastCreatedSource.buffer.byteLength > 0, `${sound}.ogg must decode to a non-empty buffer`);
    }
});

t.test('repeated plays of the SAME missing sound key only fetch once (soundBufferCache caches the negative result too)', async () => {
    const fetchUrls = [];
    const h = createHarness({
        fetchImpl: (url) => {
            fetchUrls.push(url);
            return Promise.resolve({ ok: false, status: 404, arrayBuffer: () => Promise.reject(new Error('must not be called')) });
        },
    });

    h.postMessage('audio:play', { id: 1, sound: MISSING_SOUND_KEY, gain: 1, loop: false });
    h.postMessage('audio:play', { id: 2, sound: MISSING_SOUND_KEY, gain: 1, loop: false });
    h.postMessage('audio:play', { id: 3, sound: MISSING_SOUND_KEY, gain: 1, loop: false });
    await new Promise((r) => setImmediate(r));
    await new Promise((r) => setImmediate(r));

    t.equals(fetchUrls.filter((u) => u === `sounds/${MISSING_SOUND_KEY}.ogg`).length, 1, 'exactly one fetch for three plays of the same missing key');
});

t.test('a decode failure (corrupt/unsupported file) also degrades silently, distinct from a 404, same observable outcome', async () => {
    const h = createHarness({
        audioBehavior: { decodeRejects: true },
        fetchImpl: () => Promise.resolve({ ok: true, status: 200, arrayBuffer: () => Promise.resolve(new ArrayBuffer(8)) }),
    });

    h.postMessage('audio:play', { id: 1, sound: 'bark', gain: 1, loop: false });
    await new Promise((r) => setImmediate(r));
    await new Promise((r) => setImmediate(r));

    const ctx = h.getAudioContextInstance();
    t.isUndefined(ctx._lastCreatedSource, 'a decode failure never reaches source creation');
});

t.test('Web Audio unavailable in this runtime (no window.AudioContext/webkitAudioContext) -- silent no-op, and never even attempts the fetch', async () => {
    const h = createHarness({ AudioContextCtor: undefined });
    h.postMessage('audio:play', { id: 1, sound: 'bark', gain: 1, loop: false });
    await new Promise((r) => setImmediate(r));

    const soundFetches = h.fetchCalls.filter((c) => c.url.startsWith('sounds/'));
    t.equals(soundFetches.length, 0, 'ensureAudioContext() returning null must short-circuit BEFORE loadSoundBuffer/fetch is ever reached');
});

t.test('AudioContext construction throwing degrades silently AND is sticky (never retried on a later audio:play)', async () => {
    const h = createHarness({ audioBehavior: { throwOnConstruct: true } });

    h.postMessage('audio:play', { id: 1, sound: 'bark', gain: 1, loop: false });
    h.postMessage('audio:play', { id: 2, sound: 'bark', gain: 1, loop: false });
    await new Promise((r) => setImmediate(r));

    t.equals(h.AudioContextCtor._constructCount(), 1, 'construction is attempted once, then the sticky failure flag prevents any retry');
    const soundFetches = h.fetchCalls.filter((c) => c.url.startsWith('sounds/'));
    t.equals(soundFetches.length, 0);
});

t.test('id undefined/null is rejected before any Web Audio work happens at all', async () => {
    const h = createHarness();
    h.postMessage('audio:play', { id: undefined, sound: 'bark', gain: 1, loop: false });
    h.postMessage('audio:play', { id: null, sound: 'bark', gain: 1, loop: false });
    await new Promise((r) => setImmediate(r));

    t.isUndefined(h.getAudioContextInstance(), 'ensureAudioContext() must never even be called for a payload with no usable id');
});

t.test('id:0 (falsy but valid) IS accepted -- the guard must check `undefined`/`null` specifically, not general falsiness', async () => {
    const h = createHarness();
    h.postMessage('audio:play', { id: 0, sound: 'bark', gain: 1, loop: false });

    await waitFor(() => {
        const ctx = h.getAudioContextInstance();
        return !!(ctx && ctx._lastCreatedSource && ctx._lastCreatedSource._started);
    }, { label: 'id:0 to still start playback' });
});

t.test('a non-string `sound` (missing/number/object) is rejected with no fetch attempted', async () => {
    const h = createHarness();
    h.postMessage('audio:play', { id: 1, sound: undefined, gain: 1, loop: false });
    h.postMessage('audio:play', { id: 2, sound: 42, gain: 1, loop: false });
    h.postMessage('audio:play', { id: 3, sound: {}, gain: 1, loop: false });
    await new Promise((r) => setImmediate(r));

    const soundFetches = h.fetchCalls.filter((c) => c.url.startsWith('sounds/'));
    t.equals(soundFetches.length, 0);
});

t.test('an empty or whitespace-only sound key sanitizes to nothing and is rejected (no fetch)', async () => {
    const h = createHarness();
    h.postMessage('audio:play', { id: 1, sound: '', gain: 1, loop: false });
    h.postMessage('audio:play', { id: 2, sound: '!!!///...', gain: 1, loop: false });
    await new Promise((r) => setImmediate(r));

    const soundFetches = h.fetchCalls.filter((c) => c.url.startsWith('sounds/'));
    t.equals(soundFetches.length, 0, '"!!!///..." sanitizes to an empty string (every char stripped), same as sound:\'\'');
});

t.test('SANITIZATION: a path-traversal-shaped sound value can never escape html/sounds/ -- non [a-z0-9_-] characters are stripped, not encoded/escaped', async () => {
    const h = createHarness({
        // Note: this fetchImpl also serves the automatic hud:ready ack
        // fired at init -- filter to 'sounds/' below rather than asserting
        // on the raw call count, same posture as the other specs in this
        // file that check `.filter((c) => c.url.startsWith('sounds/'))`.
        fetchImpl: () => Promise.resolve({ ok: false, status: 404, arrayBuffer: () => Promise.reject(new Error('unused')) }),
    });

    h.postMessage('audio:play', { id: 1, sound: '../../etc/passwd', gain: 1, loop: false });
    await new Promise((r) => setImmediate(r));

    const soundUrls = h.fetchCalls.map((c) => c.url).filter((u) => u.startsWith('sounds/'));
    t.equals(soundUrls.length, 1);
    t.equals(soundUrls[0], 'sounds/etcpasswd.ogg', 'every "." and "/" character is stripped entirely, never percent-decoded/traversed');
    t.notContains(soundUrls[0], '..');
    t.notContains(soundUrls[0], '/etc/');
});

t.test('SANITIZATION: uppercase/mixed-case sound names are lowercased to match the on-disk file (case-sensitive filesystems)', async () => {
    const h = createHarness({
        fetchImpl: () => Promise.resolve({ ok: true, status: 200, arrayBuffer: () => Promise.resolve(new ArrayBuffer(4)) }),
    });

    h.postMessage('audio:play', { id: 1, sound: 'BARK', gain: 1, loop: false });
    await new Promise((r) => setImmediate(r));

    const soundUrls = h.fetchCalls.map((c) => c.url).filter((u) => u.startsWith('sounds/'));
    t.equals(soundUrls[0], 'sounds/bark.ogg');
});

t.test('GAIN CLAMPING: values outside [0,1] and non-numeric values all clamp/coerce correctly on audio:play', async () => {
    const cases = [
        [2, 1], [-5, 0], ['abc', 0], [undefined, 0], [null, 0], [0.35, 0.35], [1, 1], [0, 0],
    ];

    for (const [rawGain, expectedGain] of cases) {
        const h = createHarness();
        h.postMessage('audio:play', { id: 1, sound: 'bark', gain: rawGain, loop: false });
        await waitFor(() => {
            const ctx = h.getAudioContextInstance();
            return !!(ctx && ctx._lastCreatedGain);
        }, { label: `gain ${JSON.stringify(rawGain)} to produce a GainNode` });

        const ctx = h.getAudioContextInstance();
        t.near(ctx._lastCreatedGain.gain.value, expectedGain, 0.0001, `raw gain ${JSON.stringify(rawGain)} -> ${expectedGain}`);
    }
});

t.test('loop:true is passed through to the BufferSourceNode\'s .loop property', async () => {
    const h = createHarness();
    h.postMessage('audio:play', { id: 1, sound: 'bark', gain: 1, loop: true });
    await waitFor(() => {
        const ctx = h.getAudioContextInstance();
        return !!(ctx && ctx._lastCreatedSource && ctx._lastCreatedSource._started);
    }, { label: 'looping bark to start' });

    t.isTrue(h.getAudioContextInstance()._lastCreatedSource.loop);
});

t.test('a construction/start failure inside the async continuation (e.g. an exhausted AudioContext) degrades silently, no unhandled rejection', async () => {
    const unhandled = [];
    const onUnhandled = (r) => unhandled.push(r);
    process.on('unhandledRejection', onUnhandled);

    try {
        const h = createHarness({ audioBehavior: { startThrows: true } });
        h.postMessage('audio:play', { id: 1, sound: 'bark', gain: 1, loop: false });

        await waitFor(() => {
            const ctx = h.getAudioContextInstance();
            // start() throws synchronously inside the try block -- the
            // source object still gets constructed via createBufferSource
            // before .start() is called and throws.
            return !!(ctx && ctx._lastCreatedSource);
        }, { label: 'source construction attempt' });

        await new Promise((r) => setImmediate(r));
        t.equals(unhandled.length, 0, 'the try/catch inside handleAudioPlay\'s async continuation must itself catch this, not leak it as an unhandled rejection');
    } finally {
        process.removeListener('unhandledRejection', onUnhandled);
    }
});

t.test('RACE: an audio:stop for the same id arriving WHILE the fetch/decode is still in flight prevents playback from ever starting', async () => {
    let releaseFetch;
    const gate = new Promise((resolve) => { releaseFetch = resolve; });

    const h = createHarness({
        fetchImpl: async (url) => {
            await gate; // held open until the test explicitly releases it, simulating a slow load
            return { ok: true, status: 200, arrayBuffer: () => Promise.resolve(new ArrayBuffer(8)) };
        },
    });

    h.postMessage('audio:play', { id: 42, sound: 'bark', gain: 1, loop: false });
    // The fetch is still pending (gated) -- 'audio:stop' for the SAME id
    // arrives before there is anything yet to stop, per app.js's own
    // documented stoppedBeforeStart mechanism.
    h.postMessage('audio:stop', { id: 42 });

    releaseFetch();

    // SETTLE THE WHOLE ASYNC CHAIN, rather than guessing its length.
    //
    // This used three fixed `setImmediate` drains. That is a guess at how
    // many hops the code under test needs after the gate opens (resume from
    // `await gate`, then arrayBuffer(), then decodeAudioData, then the
    // stoppedBeforeStart check), and the guess held up under a quiet machine
    // and not under load: this spec failed inside a full 42-file suite run
    // twice -- 2026-08-31 and again on the pass that wrote this -- while
    // passing 130+ times standalone, which is the signature of a
    // timing-sensitive wait, not a real defect.
    //
    // Draining both queue kinds, repeatedly, covers a chain of any plausible
    // length: setImmediate flushes the check phase, and a real setTimeout(0)
    // yields a full macrotask turn, which setImmediate alone does not
    // guarantee under contention. Twenty rounds is far more than the four
    // hops this needs and still costs under a millisecond.
    for (let i = 0; i < 20; i += 1) {
        await new Promise((r) => setImmediate(r));
        await new Promise((r) => setTimeout(r, 0));
    }

    const ctx = h.getAudioContextInstance();
    t.isDefined(ctx, 'AudioContext was still constructed (ensureAudioContext runs synchronously before the async load)');
    t.isUndefined(ctx._lastCreatedSource, 'playback must never start once a stop raced ahead of the load finishing');
});

t.run();
