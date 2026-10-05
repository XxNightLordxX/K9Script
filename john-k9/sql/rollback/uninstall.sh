#!/usr/bin/env bash
#
# john-k9 :: uninstall wrapper -- mandatory full backup, then arm and
#               run uninstall_all.sql
# =====================================================================
#
# WHAT THIS IS: an additional, safer path to the same destination as
# `uninstall_all.sql`. It does not replace that file or weaken it in any
# way -- uninstall_all.sql is still, on its own, completely inert until
# someone hand-edits it (see that file's own header). This wrapper adds
# TWO things on top of it, both mandatory:
#
#   1. A FULL, VERIFIED backup of your ENTIRE database, taken automatically,
#      BEFORE anything is armed or dropped. If the backup fails for any
#      reason, this script stops immediately and uninstall_all.sql is
#      never even invoked -- nothing is deleted.
#   2. You must type your database's name back, exactly, as a second,
#      explicit confirmation -- on top of uninstall_all.sql's own arming
#      line. Two separate "yes, I mean it"s, not one.
#
# You can still use uninstall_all.sql directly by hand (edit + run) exactly
# as documented in sql/DATABASE_GUIDE.md's "Part 2 -- Turning it off / taking
# it back out" (Level 3) -- this script is an alternative, not a requirement.
# CORRECTED: this used to point at "README.md STEP 7", a numbered-step
# section that no longer exists in either doc (verified by grepping both --
# README.md's own uninstall coverage is the unnumbered "Uninstalling /
# rolling back" section instead, which links to sql/DATABASE_GUIDE.md for the
# full walkthrough this comment means). Either path is equally safe; this one
# just also backs up your whole database for you automatically, and asks you
# to confirm twice.
#
# USAGE:
#     ./uninstall.sh -d your_database_name -u your_mysql_user \
#         --confirm your_database_name
#
# The --confirm value MUST match -d exactly (case-sensitive), or this
# script refuses before taking any backup or touching anything.
#
# OPTIONS: same as backup_full_database.sh (-d -u -h -P -S -o -w -f), plus:
#     --confirm NAME   required; must equal the -d value exactly
#
# EXIT CODE: 0 means the uninstall ran (which may itself mean "REFUSED" or
# "UNINSTALLED" -- read the output; both are documented, successful runs
# of uninstall_all.sql). Any non-zero exit means this wrapper itself
# stopped before ever reaching uninstall_all.sql -- e.g. a missing/wrong
# --confirm value, or a failed backup. In every non-zero case, nothing in
# your database has been touched.
# =====================================================================

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

DB=""; USER="root"; HOST="127.0.0.1"; PORT="3306"; SOCKET=""; PASS=""
OUTDIR=""; SKIP_SPACE_CHECK=0; CONFIRM=""

while [ $# -gt 0 ]; do
    case "$1" in
        -d) DB="$2"; shift 2 ;;
        -u) USER="$2"; shift 2 ;;
        -h) HOST="$2"; shift 2 ;;
        -P) PORT="$2"; shift 2 ;;
        -S) SOCKET="$2"; shift 2 ;;
        -o) OUTDIR="$2"; shift 2 ;;
        -w) PASS="$2"; shift 2 ;;
        -f) SKIP_SPACE_CHECK=1; shift ;;
        --confirm) CONFIRM="$2"; shift 2 ;;
        *) echo "ERROR: unknown option '$1'." >&2; exit 2 ;;
    esac
done

if [ -z "$DB" ]; then
    echo "ERROR: you must say which database to uninstall from, with -d" >&2
    exit 2
fi

if [ -z "$CONFIRM" ]; then
    echo "REFUSED: this deletes data permanently, so it requires you to type" >&2
    echo "your database name back as an explicit second confirmation:" >&2
    echo "" >&2
    echo "   ./uninstall.sh -d $DB -u your_mysql_user --confirm $DB" >&2
    echo "" >&2
    echo "Nothing has been touched. No backup has even been attempted yet --" >&2
    echo "there is no point backing up a database we are not going to uninstall." >&2
    exit 2
fi

if [ "$CONFIRM" != "$DB" ]; then
    echo "REFUSED: --confirm ('$CONFIRM') does not exactly match -d ('$DB')." >&2
    echo "Nothing has been touched. Try again with the exact same name in both." >&2
    exit 2
fi

if command -v mysql >/dev/null 2>&1; then CLI_BIN="mysql"
elif command -v mariadb >/dev/null 2>&1; then CLI_BIN="mariadb"
else
    echo "ERROR: neither 'mysql' nor 'mariadb' is installed on this machine." >&2
    exit 3
fi

if [ -z "$PASS" ]; then
    printf "MySQL password for user '%s' (leave blank if there is none): " "$USER" >&2
    read -r -s PASS
    echo "" >&2
fi
export MYSQL_PWD="$PASS"

if [ -n "$SOCKET" ]; then CONN=(--socket="$SOCKET" --user="$USER")
else                      CONN=(--host="$HOST" --port="$PORT" --user="$USER"); fi

if ! "$CLI_BIN" "${CONN[@]}" --batch --skip-column-names -e "SELECT 1" "$DB" >/dev/null 2>&1; then
    echo "ERROR: could not connect to database '$DB' as user '$USER'. Nothing" >&2
    echo "       has been changed." >&2
    exit 4
fi

echo "======================================================================"
echo " john-k9 -- uninstall (database: $DB)"
echo "======================================================================"
echo ""
echo "--- Step 1 of 2: mandatory full-database backup ------------------------"

# No -w here on purpose: MYSQL_PWD is already exported above, and the
# child script prefers an inherited MYSQL_PWD over prompting again -- this
# keeps the password out of this process's own argv.
BACKUP_ARGS=(-d "$DB" -u "$USER")
if [ -n "$SOCKET" ]; then BACKUP_ARGS+=(-S "$SOCKET"); else BACKUP_ARGS+=(-h "$HOST" -P "$PORT"); fi
if [ -n "$OUTDIR" ]; then BACKUP_ARGS+=(-o "$OUTDIR"); fi
if [ "$SKIP_SPACE_CHECK" -eq 1 ]; then BACKUP_ARGS+=(-f); fi

set +e
BACKUP_OUT="$("$SCRIPT_DIR/backup_full_database.sh" "${BACKUP_ARGS[@]}" 2>&1)"
BACKUP_RC=$?
set -e
echo "$BACKUP_OUT"

if [ $BACKUP_RC -ne 0 ]; then
    echo ""
    echo "======================================================================"
    echo " REFUSING TO UNINSTALL -- the mandatory backup did not succeed (see"
    echo " above). uninstall_all.sql was NEVER invoked. Nothing in your"
    echo " database has been touched. Fix the problem reported above, then run"
    echo " this script again."
    echo "======================================================================"
    exit 6
fi
BACKUP_FILE="$(echo "$BACKUP_OUT" | grep '^BACKUP_FILE=' | tail -n1 | cut -d= -f2- || true)"
echo ""
echo "Backup verified: $BACKUP_FILE"
echo ""

echo "--- Step 2 of 2: running uninstall_all.sql, armed ----------------------"
echo ""

# Arm it the SAME WAY the manual instructions in sql/DATABASE_GUIDE.md's
# "Part 2" (Level 3) do: uncomment the specific commented-out SET line inside
# uninstall_all.sql
# itself. This is NOT optional cosmetics -- uninstall_all.sql's own very
# first statement resets @K9_UNINSTALL_CONFIRM to NULL every single time it
# runs (that is its safety catch, see that file's own STEP 1 comment), so
# a SET prepended BEFORE the file's content would just get overwritten by
# that reset line a few statements later and silently produce "REFUSED"
# every time -- this must arm the line the file checks AFTER its own
# reset, not before it.
#
# The file ON DISK is never modified -- `sed` only transforms the copy
# piped into this one mysql connection, so uninstall_all.sql remains
# exactly as inert-by-default as ever for anyone who opens or runs it
# directly.
ARM_LINE="-- SET @K9_UNINSTALL_CONFIRM = 'YES-DELETE-ALL-MY-K9-DATA';"
# NOTE the `--` before the pattern. $ARM_LINE begins with "--", so without
# it grep parses the pattern as an option string and exits 2 ("unrecognized
# option") rather than 1 ("no match"). This `if ! grep` treats every nonzero
# exit the same, so the wrapper took its own dead-man's-switch refusal branch
# on EVERY run, on every database, even though the arming line was present and
# byte-identical. The backup still ran first, so nothing was ever at risk --
# but the uninstall could never proceed through this script, and the operator
# was pushed to hand-edit uninstall_all.sql instead, which is exactly the
# riskier path this wrapper exists to spare them.
if ! grep -qF -- "$ARM_LINE" "$SCRIPT_DIR/uninstall_all.sql"; then
    echo "ERROR: this wrapper could not find the exact arming line it expects" >&2
    echo "       inside uninstall_all.sql -- that file must have changed shape." >&2
    echo "       Refusing to guess. Your backup is safe at:" >&2
    echo "         $BACKUP_FILE" >&2
    echo "       Arm and run sql/rollback/uninstall_all.sql BY HAND instead" >&2
    echo "       (see sql/DATABASE_GUIDE.md's \"Part 2\", Level 3), or report" >&2
    echo "       this mismatch." >&2
    exit 9
fi

set +e
sed "s/^${ARM_LINE//\//\\/}\$/${ARM_LINE#-- }/" "$SCRIPT_DIR/uninstall_all.sql" \
    | "$CLI_BIN" "${CONN[@]}" "$DB"
RC=$?
set -e

echo ""
echo "======================================================================"
if [ $RC -eq 0 ]; then
    echo " uninstall_all.sql ran. Read its own output above for the real"
    echo " result (UNINSTALLED, or REFUSED if something still depends on our"
    echo " tables -- see the dependency report above)."
else
    echo " uninstall_all.sql exited with an error (code $RC) -- see above."
fi
echo " Your full-database backup, taken before this ran, is at:"
echo "   $BACKUP_FILE"
echo "======================================================================"
exit $RC
