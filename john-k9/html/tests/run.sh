#!/usr/bin/env bash
# html/tests/run.sh
#
# Runs every *_spec.js file in this directory under plain Node.js -- no
# npm dependency, no install step, no framework (jest/mocha/vitest) --
# mirroring tests/run.sh's own posture one directory up in this same repo
# (see that file's own header, and DEVELOPER_REFERENCE.md, for the "why not
# busted" reasoning this applies in reverse for the JS side: no
# node_modules to install, runs on whatever Node the box already has).
#
# Each spec file is a self-contained Node process: it requires
# ./testkit.js, runs its own test cases via testkit's queued t.test()
# calls, and t.run() calls process.exit(0|1) itself (all passed / at least
# one failure). This script aggregates those exit codes into one overall
# pass/fail and prints a final summary line, exiting non-zero if ANY spec
# file failed.
#
# THIS IS WHAT CI RUNS. .github/workflows/lua-check.yml's `js-tests` job
# calls this script directly, exactly as its `lua-tests` job calls
# tests/run.sh -- so a local run and a CI run execute the same code, and
# "it passes on my machine" means the same thing as "it passes in CI".
# (That job used to inline its own copy of this glob-and-aggregate loop,
# written before this file existed; the duplicate is gone.)
#
# IMPORTANT: this directory is html/tests/, NOT tests/ -- tests/run.sh
# glob-discovers *_spec.lua in ITS OWN directory only, so these *_spec.js
# files here are never at risk of being picked up (and misinterpreted) by
# that script, and vice versa.

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"

NODE_BIN="${NODE_BIN:-node}"

if ! command -v "$NODE_BIN" >/dev/null 2>&1; then
    echo "html/tests/run.sh: '$NODE_BIN' not found on PATH -- install Node.js (any reasonably recent version; no npm packages are required by this suite) to run it." >&2
    exit 2
fi

overall_status=0
total_files=0
failed_files=()

for spec in *_spec.js; do
    [ -e "$spec" ] || continue
    total_files=$((total_files + 1))
    echo "==> $spec"
    if ! "$NODE_BIN" "$spec"; then
        overall_status=1
        failed_files+=("$spec")
    fi
    echo ""
done

echo "============================================================"
if [ "$total_files" -eq 0 ]; then
    echo "html/tests/run.sh: no *_spec.js files found -- nothing ran."
    exit 2
fi

if [ "$overall_status" -eq 0 ]; then
    echo "ALL SPEC FILES PASSED ($total_files file(s))."
else
    echo "SPEC FILE(S) FAILED: ${failed_files[*]}"
fi

exit "$overall_status"
