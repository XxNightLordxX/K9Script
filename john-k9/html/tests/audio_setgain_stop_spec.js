/*
    html/tests/audio_setgain_stop_spec.js

    Covers `audio:setGain` (handleAudioSetGain) and `audio:stop`
    (handleAudioStop) in html/app.js -- both only ever reachable in a
    meaningful way AFTER a prior `audio:play` has actually started
    something (client/audio.lua's own PlayK9Sound/StopK9Sound contract:
    `id` addresses "the exact playback instance", so both a not-yet-started
    and an already-ended id must be silent no-ops, never an error).

    LEAK FIX REGRESSION TESTS (bottom of this file, before t.run()) --
    app.js's own `stoppedBeforeStart` map used to be written to
    UNCONDITIONALLY by handleAudioStop for ANY id with no currently-active
    sound, including an id whose 'audio:play' had already fully resolved (or
    that never had a matching 'audio:play' at all). Since Lua-side ids
    (client/audio.lua's `nextSoundId`) are a monotonically-increasing
    counter NEVER reused for the life of the page, no future 'audio:play'
    for that same id could ever arrive to clean such an entry back out --
    it sat in memory forever. The dominant real-world trigger:
    client/audio.lua's own AUDIO_MAX_LOOP_MS (60s) safety-ceiling calls
    StopK9Sound() -- sending 'audio:stop' -- on EVERY long-lived
    ProximityAudioFX loop sound whether or not it ever actually started
    (a 404 leaves loadSoundBuffer resolving to a null buffer, so
    activeSounds[id] is never populated at all -- these tests drive that
    with sandbox.js's MISSING_SOUND_KEY, since growl_ambient.ogg now
    genuinely ships and would take the success path); with
    Config.Features.ProximityAudioFX now on, client/proximityaudio.lua's
    discovery thread re-triggers a BRAND NEW id for the same nearby K9
    roughly every 60 seconds it stays in range, so this leaked one
    permanent key per nearby K9 roughly once a minute for the entire
    session -- unbounded for as long as any K9 stayed near any player.

    app.js exposes NO internal state for a test to read directly (by
    design -- see sandbox.js's own header: "app.js exposes none... the
    IIFE's whole surface area IS this message listener"), so the tests
    below prove boundedness BEHAVIORALLY rather than by reading
    stoppedBeforeStart's size: they drive the exact leak-triggering
    sequence many times over many distinct ids, then reuse one of those
    exact ids for a brand-new, entirely unrelated, legitimate audio:play.
    Reusing a real Lua-issued id never actually happens in production (the
    counter never wraps), but it is precisely what makes this a real
    regression guard: if EVEN ONE of the prior late-arriving audio:stop
    calls had left a stale stoppedBeforeStart[id] entry behind (the pre-fix
    bug), handleAudioPlay's own `if (!buffer || wasStoppedEarly) return;`
    would wrongly treat this brand-new play as "stopped before it started"
    and silently refuse to ever start it -- a real, observable, provable
    consequence of the leak, not just an abstract memory-growth number.
*/
'use strict';

const t = require('./testkit');
const { createHarness, waitFor, MISSING_SOUND_KEY } = require('./sandbox');

async function playAndWaitStarted(h, id, opts) {
    h.postMessage('audio:play', Object.assign({ id, sound: 'bark', gain: 0.5, loop: false }, opts));
    await waitFor(() => {
        const ctx = h.getAudioContextInstance();
        return !!(ctx && ctx._lastCreatedSource && ctx._lastCreatedSource._started);
    }, { label: `id ${id} to start playing` });
}

t.test('audio:setGain before any audio:play has ever run is a total no-op (audioCtx is still null -- never even constructed)', async () => {
    const h = createHarness();
    h.postMessage('audio:setGain', { id: 1, gain: 0.9 });
    await new Promise((r) => setImmediate(r));

    t.isUndefined(h.getAudioContextInstance(), 'handleAudioSetGain\'s own `if (!data || !audioCtx) return` must short-circuit before ever touching Web Audio');
});

t.test('audio:setGain for an unknown id (after Web Audio IS already in use) is a silent no-op, does not touch the wrong sound', async () => {
    const h = createHarness();
    await playAndWaitStarted(h, 1);
    const ctx = h.getAudioContextInstance();
    const originalRampCalls = ctx._lastCreatedGain.gain._rampCalls.length;

    h.postMessage('audio:setGain', { id: 999, gain: 0.1 });
    await new Promise((r) => setImmediate(r));

    t.equals(ctx._lastCreatedGain.gain._rampCalls.length, originalRampCalls, 'no ramp scheduled for an id that is not active');
});

t.test('audio:setGain for the active id schedules a linearRampToValueAtTime toward the (clamped) target gain', async () => {
    const h = createHarness();
    await playAndWaitStarted(h, 7);
    const ctx = h.getAudioContextInstance();

    h.postMessage('audio:setGain', { id: 7, gain: 0.2 });
    await new Promise((r) => setImmediate(r));

    const ramps = ctx._lastCreatedGain.gain._rampCalls;
    t.equals(ramps.length, 1);
    t.near(ramps[0].v, 0.2, 0.0001);
    t.isTrue(ctx._lastCreatedGain.gain._cancelCalls >= 1, 'cancelScheduledValues called before scheduling the new ramp');
});

t.test('audio:setGain clamps out-of-range/non-numeric gain the same way audio:play does', async () => {
    const cases = [[5, 1], [-1, 0], ['nope', 0]];
    for (const [rawGain, expectedGain] of cases) {
        const h = createHarness();
        await playAndWaitStarted(h, 1);
        const ctx = h.getAudioContextInstance();

        h.postMessage('audio:setGain', { id: 1, gain: rawGain });
        await new Promise((r) => setImmediate(r));

        const ramps = ctx._lastCreatedGain.gain._rampCalls;
        t.equals(ramps.length, 1, `one ramp scheduled for gain ${JSON.stringify(rawGain)}`);
        t.near(ramps[0].v, expectedGain, 0.0001, `raw gain ${JSON.stringify(rawGain)} -> ${expectedGain}`);
    }
});

t.test('audio:setGain swallows a linearRampToValueAtTime failure silently (no throw reaches the message dispatcher)', async () => {
    const h = createHarness({ audioBehavior: { rampThrows: true } });
    await playAndWaitStarted(h, 1);

    // If handleAudioSetGain's own try/catch were missing, this postMessage
    // call itself would throw synchronously (linearRampToValueAtTime
    // throws synchronously inside handleAudioSetGain, unlike the async
    // handleAudioPlay path) -- reaching the next line at all is the test.
    h.postMessage('audio:setGain', { id: 1, gain: 0.5 });
    t.isTrue(true, 'postMessage returned normally despite the simulated ramp failure');
});

t.test('audio:stop before any audio:play has ever run for that id is a silent no-op (also true when Web Audio is already active for OTHER ids)', async () => {
    const h = createHarness();
    await playAndWaitStarted(h, 1);
    h.postMessage('audio:stop', { id: 999 });
    await new Promise((r) => setImmediate(r));
    // The real (id:1) sound must be entirely unaffected.
    const ctx = h.getAudioContextInstance();
    t.isFalse(ctx._lastCreatedSource._stopped, 'stopping an unrelated id must not stop id 1\'s own source');
});

t.test('audio:stop for an active id actually stops the source and disconnects both nodes', async () => {
    const h = createHarness();
    await playAndWaitStarted(h, 5);
    const ctx = h.getAudioContextInstance();

    h.postMessage('audio:stop', { id: 5 });
    await new Promise((r) => setImmediate(r));

    t.isTrue(ctx._lastCreatedSource._stopped, 'source.stop() was called');
    t.isTrue(ctx._lastCreatedSource._disconnected, 'source.disconnect() was called');
    t.isTrue(ctx._lastCreatedGain._disconnected, 'gain.disconnect() was called');
});

t.test('a second audio:stop for the same (already-stopped) id is a harmless no-op, never a double-stop/double-disconnect throw reaching the caller', async () => {
    const h = createHarness();
    await playAndWaitStarted(h, 5);

    h.postMessage('audio:stop', { id: 5 });
    await new Promise((r) => setImmediate(r));
    // Second stop for the same id: by now activeSounds[5] has already been
    // deleted by the first call, so this is the "unknown id" no-op branch,
    // NOT a second real source.stop() call -- exercised directly here to
    // prove it doesn't throw either.
    h.postMessage('audio:stop', { id: 5 });
    await new Promise((r) => setImmediate(r));
    t.isTrue(true, 'no throw from either stop call');
});

t.test('source.stop() itself throwing (e.g. the sound already ended naturally at the exact moment stop arrives) is caught -- disconnect is still attempted', async () => {
    const h = createHarness({ audioBehavior: { stopThrows: true } });
    await playAndWaitStarted(h, 1);
    const ctx = h.getAudioContextInstance();

    h.postMessage('audio:stop', { id: 1 });
    await new Promise((r) => setImmediate(r));

    t.isFalse(ctx._lastCreatedSource._stopped, 'the simulated stop() failure means _stopped never actually flips true');
    t.isTrue(ctx._lastCreatedSource._disconnected, 'disconnect() is attempted in its OWN try/catch, independent of whether stop() succeeded');
    t.isTrue(ctx._lastCreatedGain._disconnected);
});

t.test('gain.disconnect() itself throwing is also caught (the second, independent try/catch in handleAudioStop)', async () => {
    const h = createHarness({ audioBehavior: { disconnectThrows: true } });
    await playAndWaitStarted(h, 1);

    h.postMessage('audio:stop', { id: 1 });
    // No throw should escape to here.
    t.isTrue(true, 'postMessage returned normally despite the simulated gain.disconnect() failure');
});

t.test('audio:setGain and audio:stop both no-op cleanly on a null/undefined data payload', async () => {
    const h = createHarness();
    h.postMessage('audio:setGain', null);
    h.postMessage('audio:setGain', undefined);
    h.postMessage('audio:stop', null);
    h.postMessage('audio:stop', undefined);
    await new Promise((r) => setImmediate(r));
    t.isTrue(true, 'no throw for any of the four calls above');
});

// ------------------------------------------------------------------
// LEAK FIX REGRESSION TESTS -- see this file's header for the full
// characterization of the bug and why the proof below is behavioral.
// ------------------------------------------------------------------

t.test('LEAK FIX: an audio:stop that arrives AFTER its id\'s own audio:play already resolved (missing file, never started) leaves nothing behind -- proven by reusing that exact id for a brand-new legitimate play afterward', async () => {
    const h = createHarness();
    const N = 200;

    // Reproduces client/audio.lua's real leak-triggering shape: N distinct
    // loop=true 'audio:play' requests for a sound key that 404s, so
    // activeSounds[id] is NEVER populated for any of them (handleAudioPlay's
    // own `if (!buffer || wasStoppedEarly) return;`). MISSING_SOUND_KEY is
    // used rather than a real key because the leak needs a genuine 404 --
    // all five shipped keys now decode successfully.
    for (let id = 1; id <= N; id++) {
        h.postMessage('audio:play', { id, sound: MISSING_SOUND_KEY, gain: 1, loop: true });
    }

    // Let every one of the N loads fully settle (all real 404s) BEFORE any
    // stop arrives -- this is deliberately the "already resolved" case
    // (client/audio.lua's AUDIO_MAX_LOOP_MS ceiling firing a full 60
    // simulated seconds after its own async load finished), not the
    // legitimate in-flight race already covered by audio_play_spec.js's
    // own 'RACE:' test.
    //
    // Awaiting the real fetch promises, not a fixed 300ms sleep: these are
    // N real fs.readFile round-trips, so how long they take is a property
    // of the machine, not of the code under test. If the sleep ever came up
    // short the stops would land DURING the loads -- quietly turning this
    // into the in-flight race case it explicitly says it is not testing.
    await h.settleFetches();

    for (let id = 1; id <= N; id++) {
        h.postMessage('audio:stop', { id });
    }
    await new Promise((r) => setImmediate(r));

    // THE PROOF: reuse one id from smack in the middle of that batch for a
    // brand-new, totally unrelated, legitimate play against a REAL file
    // (bark.ogg). Before this fix, id 100's late 'audio:stop' above would
    // have left a permanent stoppedBeforeStart[100] = true entry with
    // nothing left to ever clear it, and this new play would silently
    // never start.
    const reusedId = 100;
    h.postMessage('audio:play', { id: reusedId, sound: 'bark', gain: 1, loop: false });

    await waitFor(() => {
        const ctx = h.getAudioContextInstance();
        return !!(ctx && ctx._lastCreatedSource && ctx._lastCreatedSource._started);
    }, { timeoutMs: 3000, label: 'reused id 100 to still start a brand-new legitimate play' });

    t.isTrue(h.getAudioContextInstance()._lastCreatedSource._started, 'no stale stoppedBeforeStart entry survived from any of the 200 prior late-stop cycles');
    t.isTrue(h.getAudioContextInstance()._lastCreatedSource.loop === false, 'the NEW play\'s own loop:false was applied -- this is genuinely the reused-id play, not some leftover state from the id-100 loop attempt');
});

t.test('LEAK FIX: the SAME check holds for the very first and very last id of a large batch, not just one lucky id in the middle', async () => {
    const h = createHarness();
    const N = 50;

    for (let id = 1; id <= N; id++) {
        h.postMessage('audio:play', { id, sound: MISSING_SOUND_KEY, gain: 1, loop: true });
    }
    // Real fetch completion, not a fixed sleep -- see the sibling test above
    // for why this must be the "already resolved" case and not a race.
    await h.settleFetches();
    for (let id = 1; id <= N; id++) {
        h.postMessage('audio:stop', { id });
    }
    await new Promise((r) => setImmediate(r));

    for (const reusedId of [1, N]) {
        h.postMessage('audio:play', { id: reusedId, sound: 'bark', gain: 1, loop: false });
        await waitFor(() => {
            const ctx = h.getAudioContextInstance();
            return !!(ctx && ctx._lastCreatedSource && ctx._lastCreatedSource._started);
        }, { timeoutMs: 3000, label: `reused id ${reusedId} to start a brand-new legitimate play` });
        // Stop it again immediately so the next iteration's waitFor is
        // checking a FRESH _lastCreatedSource, not the previous one.
        h.postMessage('audio:stop', { id: reusedId });
        await new Promise((r) => setImmediate(r));
    }
    t.isTrue(true, 'both the first and last id of the batch were reusable without being poisoned by a stale entry');
});

t.test('LEAK FIX: a stray audio:stop for an id that NEVER had any matching audio:play at all is a true no-op and does not poison that id for a later real play either', async () => {
    const h = createHarness();

    // No audio:play for id 777 has ever been sent -- this is the
    // "stale/unknown id" case handleAudioStop's own comment already
    // documents as a no-op; the leak fix additionally guarantees it adds
    // nothing to stoppedBeforeStart (pendingPlayIds[777] was never true).
    for (let i = 0; i < 50; i++) {
        h.postMessage('audio:stop', { id: 777 });
    }
    await new Promise((r) => setImmediate(r));

    h.postMessage('audio:play', { id: 777, sound: 'bark', gain: 1, loop: false });
    await waitFor(() => {
        const ctx = h.getAudioContextInstance();
        return !!(ctx && ctx._lastCreatedSource && ctx._lastCreatedSource._started);
    }, { timeoutMs: 2000, label: 'id 777 to play normally despite 50 prior stray stops' });

    t.isTrue(h.getAudioContextInstance()._lastCreatedSource._started);
});

t.run();
