/*
    html/tests/testkit.js

    Zero-dependency assertion + test-runner for plain Node.js, mirroring
    tests/testkit.lua's own posture on the Lua side of this codebase (see
    that file's header: "why this exists instead of busted"). Same reasons
    apply here in reverse -- no npm dependency (no jest/mocha/vitest
    install step), runs under any Node the box already has, one process
    per spec file, non-zero exit on any failure.

    USAGE (see any *_spec.js in this directory for a full example):
        const t = require('./testkit');
        t.test('description of one behavior', function () {
            t.equals(1 + 1, 2);
        });
        t.test('an async behavior', async function () {
            const result = await somePromise();
            t.isTrue(result);
        });
        t.run(); // prints summary, calls process.exit(0|1)

    Every t.test() body is queued and run in registration order inside
    t.run()'s own async loop -- a failing assertion (t.equals/t.isTrue/...
    throwing) fails only that one test case, never aborts the rest of the
    file, exactly like testkit.lua's per-test pcall.
*/
'use strict';

const cases = [];
let passed = 0;
let failed = 0;
const failures = [];

/**
 * Registers one named test case. `fn` may be sync or return a Promise
 * (async function) -- t.run() awaits either uniformly. Not executed
 * immediately; queued for t.run().
 * @param {string} name
 * @param {() => (void|Promise<void>)} fn
 */
function test(name, fn) {
    cases.push({ name, fn });
}

function fail(message) {
    const err = new Error(message);
    Error.captureStackTrace && Error.captureStackTrace(err, fail);
    throw err;
}

function formatValue(v) {
    if (typeof v === 'string') return JSON.stringify(v);
    try {
        return JSON.stringify(v);
    } catch (e) {
        return String(v);
    }
}

/** @param {*} actual @param {*} expected @param {string} [message] */
function equals(actual, expected, message) {
    if (!Object.is(actual, expected)) {
        fail(`${message ? message + ': ' : ''}expected ${formatValue(expected)}, got ${formatValue(actual)}`);
    }
}

/** @param {*} actual @param {string} [message] */
function isTrue(actual, message) {
    equals(actual, true, message);
}

/** @param {*} actual @param {string} [message] */
function isFalse(actual, message) {
    equals(actual, false, message);
}

/** @param {*} actual @param {string} [message] */
function isNull(actual, message) {
    if (actual !== null) {
        fail(`${message ? message + ': ' : ''}expected null, got ${formatValue(actual)}`);
    }
}

/** @param {*} actual @param {string} [message] */
function isUndefined(actual, message) {
    if (actual !== undefined) {
        fail(`${message ? message + ': ' : ''}expected undefined, got ${formatValue(actual)}`);
    }
}

/** @param {*} actual @param {string} [message] */
function isDefined(actual, message) {
    if (actual === undefined) {
        fail(`${message ? message + ': ' : ''}expected a defined value`);
    }
}

/** @param {string} haystack @param {string} needle @param {string} [message] */
function contains(haystack, needle, message) {
    haystack = String(haystack);
    if (!haystack.includes(needle)) {
        fail(`${message ? message + ': ' : ''}expected ${formatValue(haystack)} to contain ${formatValue(needle)}`);
    }
}

/** @param {string} haystack @param {string} needle @param {string} [message] */
function notContains(haystack, needle, message) {
    haystack = String(haystack);
    if (haystack.includes(needle)) {
        fail(`${message ? message + ': ' : ''}expected ${formatValue(haystack)} NOT to contain ${formatValue(needle)}`);
    }
}

/** @param {number} actual @param {number} expected @param {number} epsilon @param {string} [message] */
function near(actual, expected, epsilon, message) {
    if (typeof actual !== 'number' || !isFinite(actual) || Math.abs(actual - expected) > epsilon) {
        fail(`${message ? message + ': ' : ''}expected ${formatValue(actual)} to be within ${epsilon} of ${formatValue(expected)}`);
    }
}

/**
 * Fails unless `fn` throws (sync) -- used sparingly; most of app.js is
 * built to never throw (its whole "graceful degradation" contract), so
 * most specs assert the ABSENCE of a throw, not its presence. Kept for the
 * few real "should throw" cases (none currently expected in app.js's own
 * contract, provided for completeness/parity with a normal assertion lib).
 * @param {() => void} fn @param {string} [message]
 */
function throws(fn, message) {
    let didThrow = false;
    try {
        fn();
    } catch (e) {
        didThrow = true;
    }
    if (!didThrow) {
        fail(`${message ? message + ': ' : ''}expected function to throw`);
    }
}

/** Runs every queued case in order, prints PASS/FAIL lines + a summary,
 * and calls process.exit() with 0 (all passed) or 1 (>=1 failed) -- same
 * contract as testkit.lua's M.summary()/os.exit() pairing, so tests/run.sh's
 * sibling in this directory can aggregate exit codes identically. */
async function run() {
    for (const { name, fn } of cases) {
        try {
            await fn();
            passed++;
            console.log(`  [PASS] ${name}`);
        } catch (err) {
            failed++;
            failures.push({ name, err });
            console.log(`  [FAIL] ${name} -- ${err && err.message ? err.message : err}`);
        }
    }

    console.log('');
    console.log(`${passed} passed, ${failed} failed`);
    if (failed > 0) {
        console.log('');
        console.log('Failures:');
        for (const f of failures) {
            console.log(`  - ${f.name}: ${f.err && f.err.message ? f.err.message : f.err}`);
        }
    }

    process.exit(failed === 0 ? 0 : 1);
}

module.exports = {
    test,
    equals,
    isTrue,
    isFalse,
    isNull,
    isUndefined,
    isDefined,
    contains,
    notContains,
    near,
    throws,
    fail,
    run,
};
