#!/usr/bin/env bash
# tests/run.sh
#
# Runs every *_spec.lua file in this directory under plain lua5.4 (no
# framework/dependency beyond the Lua 5.4 interpreter itself -- see
# DEVELOPER_REFERENCE.md for why busted was not used). Each spec file is a
# self-contained process: it loads tests/testkit.lua, runs its own test
# cases, and os.exit()s 0 (all passed) or 1 (at least one failure). This
# script aggregates those exit codes into one overall pass/fail and prints a
# final summary line, and exits non-zero if ANY spec file failed -- suitable
# for both local use and the CI job in .github/workflows/lua-check.yml.

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"

LUA_BIN="${LUA_BIN:-lua5.4}"

if ! command -v "$LUA_BIN" >/dev/null 2>&1; then
    echo "tests/run.sh: '$LUA_BIN' not found on PATH -- install Lua 5.4 (the same runtime this resource ships against) to run this suite." >&2
    exit 2
fi

overall_status=0
total_files=0
failed_files=()

for spec in *_spec.lua; do
    [ -e "$spec" ] || continue
    total_files=$((total_files + 1))
    echo "==> $spec"
    if ! "$LUA_BIN" "$spec"; then
        overall_status=1
        failed_files+=("$spec")
    fi
    echo ""
done

echo "============================================================"
if [ "$total_files" -eq 0 ]; then
    echo "tests/run.sh: no *_spec.lua files found -- nothing ran."
    exit 2
fi

if [ "$overall_status" -eq 0 ]; then
    echo "ALL SPEC FILES PASSED ($total_files file(s))."
else
    echo "SPEC FILE(S) FAILED: ${failed_files[*]}"
fi

exit "$overall_status"
