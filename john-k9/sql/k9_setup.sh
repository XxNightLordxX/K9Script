#!/usr/bin/env bash
#
# john-k9 :: THE single entry point -- check, back up, install/upgrade,
#               report. If you only remember one file in sql/, remember
#               this one.
# =====================================================================
#
# WHAT THIS DOES, IN ORDER, EVERY TIME YOU RUN IT:
#
#   1. Connects and runs the same checks as preflight_check.sql (right
#      server version, no table-name conflicts, a sanity check that this
#      looks like a real qbx_core database). Stops here, before touching
#      anything, if any of those come back bad.
#   2. Takes a FULL backup of your ENTIRE database automatically --
#      not just john-k9's own tables -- and verifies it before
#      continuing. THIS STEP IS MANDATORY AND CANNOT BE SKIPPED. If the
#      backup fails for any reason, this script stops immediately and
#      makes NO changes to your database. A backup you believe you have
#      but do not is worse than no backup at all, so failure here is
#      always fatal to the run.
#   3. Runs `install.sql`, then every file in `sql/migrations/` in order.
#      Each one is individually safe to run twice, so this is exactly as
#      safe whether this is your first install or your fiftieth upgrade.
#   4. Reports plainly what happened: which files ran, current row counts
#      for every john-k9 table, and one final line that says SUCCESS
#      or FAILED -- never a silent, ambiguous finish.
#
# USAGE:
#     ./k9_setup.sh -d your_database_name -u your_mysql_user
#     ./k9_setup.sh -d your_database_name -u your_mysql_user --dry-run
#
# OPTIONS:
#     -d NAME       database name                (required)
#     -u USER       MySQL username               (default: root)
#     -h HOST       server hostname              (default: 127.0.0.1)
#     -P PORT       server port                  (default: 3306)
#     -S PATH       unix socket, instead of -h/-P
#     -o DIR        where to write the automatic full-database backup
#                   (default: sql/rollback/backups next to this script)
#     -w PASS       password on the command line (NOT recommended)
#     -f            skip the backup's free-disk-space check (advanced --
#                   see backup_full_database.sh's own header)
#     -n, --dry-run show exactly what WOULD happen and change nothing --
#                   no backup is taken (nothing is being written, so
#                   there is nothing yet to protect)
#
# EXIT CODE: 0 means everything that ran, ran successfully. Anything else
# means something failed -- read the last few lines of output; they say
# what, and whether your database was touched.
#
# WHAT THIS DOES **NOT** DO, ON PURPOSE:
#   * It never runs sql/rollback/uninstall_all.sql. Uninstalling is a
#     separate, harder-to-reach decision -- see sql/rollback/uninstall.sh,
#     which has the same mandatory-backup guarantee for that path.
#   * It never edits your server.cfg or restarts your FiveM server. It
#     only touches the database.
# =====================================================================

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

DB=""; USER="root"; HOST="127.0.0.1"; PORT="3306"; SOCKET=""; PASS=""
BACKUP_OUTDIR=""; SKIP_SPACE_CHECK=0; DRY_RUN=0

while [ $# -gt 0 ]; do
    case "$1" in
        -d) DB="$2"; shift 2 ;;
        -u) USER="$2"; shift 2 ;;
        -h) HOST="$2"; shift 2 ;;
        -P) PORT="$2"; shift 2 ;;
        -S) SOCKET="$2"; shift 2 ;;
        -o) BACKUP_OUTDIR="$2"; shift 2 ;;
        -w) PASS="$2"; shift 2 ;;
        -f) SKIP_SPACE_CHECK=1; shift ;;
        -n|--dry-run) DRY_RUN=1; shift ;;
        --help)
            sed -n '2,58p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) echo "ERROR: unknown option '$1'. Run with --help to see usage." >&2; exit 2 ;;
    esac
done

if [ -z "$DB" ]; then
    echo "ERROR: you must say which database to operate on, with -d" >&2
    echo "" >&2
    echo "   Example:  ./k9_setup.sh -d your_database_name -u your_mysql_user" >&2
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
    echo "ERROR: could not connect to database '$DB' as user '$USER'." >&2
    echo "       Check the database name, username and password, and that the" >&2
    echo "       server is running. Nothing has been changed." >&2
    exit 4
fi

# --- translate a raw mysql/mariadb error blob into a plain sentence ------
# This is the layer that keeps a non-DBA from ever having to stare at a
# bare "ERROR 1146 (42S02)" with no idea what to do about it. The raw
# error is ALWAYS shown too (never hidden) -- this just adds a plain-
# English line above it.
translate_error() {
    local blob="$1"
    if echo "$blob" | grep -qi "Duplicate entry"; then
        echo "  PLAIN ENGLISH: your database already has two rows that this schema"
        echo "  change says should never both exist at once (most commonly: the"
        echo "  same officer certified twice for the same job, at the same time)."
        echo "  See sql/migrations/0004_add_k9_certifications_active_cert_key.sql's"
        echo "  own OPERATOR NOTE for the exact fix, then run this script again --"
        echo "  it will pick up from here safely."
    elif echo "$blob" | grep -qi "command denied to user\|alter routine command denied"; then
        echo "  PLAIN ENGLISH: your database user is missing the CREATE ROUTINE"
        echo "  privilege, which some migrations briefly need. Ask your database"
        echo "  host to grant it, or ask them to run this for you. A fresh install"
        echo "  on a brand-new database does not need this privilege at all."
    elif echo "$blob" | grep -qi "doesn't exist"; then
        echo "  PLAIN ENGLISH: something expected a table that is not there yet."
        echo "  This should not happen when running files in order through this"
        echo "  script -- if you see this, something ran out of order. Re-run this"
        echo "  script from the start rather than any individual file by hand."
    elif echo "$blob" | grep -qi "Access denied"; then
        echo "  PLAIN ENGLISH: your username/password (or that user's permissions)"
        echo "  are not enough. Nothing has been changed by this specific step."
    elif echo "$blob" | grep -qi "Unknown database"; then
        echo "  PLAIN ENGLISH: the database name '$DB' does not exist on this"
        echo "  server. Check for a typo, or create the database first."
    else
        echo "  PLAIN ENGLISH: an unexpected database error occurred. Copy the raw"
        echo "  error above exactly if you ask for help with it. Whatever ran"
        echo "  successfully before this step is unaffected and does not need to"
        echo "  be repeated -- this script is safe to run again from the start."
    fi
}

# --- run one .sql file through the CLI, print a translated failure, and
#     return its real exit code untouched ---------------------------------
run_sql_file() {
    local label="$1" file="$2"
    local out rc
    set +e
    out="$("$CLI_BIN" "${CONN[@]}" "$DB" < "$file" 2>&1)"
    rc=$?
    set -e
    if [ -n "$out" ]; then echo "$out"; fi
    if [ $rc -ne 0 ]; then
        echo ""
        echo "FAILED: $label"
        translate_error "$out"
        return $rc
    fi
    echo "OK: $label"
    return 0
}

echo "======================================================================"
echo " john-k9 -- database setup / upgrade"
echo " Database: $DB"
echo "======================================================================"
echo ""

# ---------------------------------------------------------------------
# STEP 1: safety checks (same content as sql/preflight_check.sql). Any
# line starting with "!!" is a hard stop -- printed in full either way.
# ---------------------------------------------------------------------
echo "--- Step 1 of 4: safety checks ---------------------------------------"
set +e
CHECK_OUT="$("$CLI_BIN" "${CONN[@]}" "$DB" < "$SCRIPT_DIR/preflight_check.sql" 2>&1)"
CHECK_RC=$?
set -e
echo "$CHECK_OUT"
if [ $CHECK_RC -ne 0 ]; then
    echo ""
    echo "ERROR: the safety-check query itself failed to run (see the raw error"
    echo "above) -- this is unusual, since preflight_check.sql only reads."
    echo "Nothing has been changed. Fix the problem above (commonly a dropped"
    echo "connection mid-check), then run this script again."
    exit 5
fi
if echo "$CHECK_OUT" | grep -q '!!'; then
    echo ""
    echo "REFUSED - one or more safety checks above failed (look for the lines"
    echo "starting with '!!'). Nothing has been changed. Fix what is flagged,"
    echo "then run this script again."
    exit 5
fi
echo "All safety checks OK."
echo ""

if [ "$DRY_RUN" -eq 1 ]; then
    echo "--- DRY RUN: showing the plan instead of applying it -----------------"
    set +e
    "$CLI_BIN" "${CONN[@]}" "$DB" < "$SCRIPT_DIR/migration_status.sql"
    PLAN_RC=$?
    set -e
    if [ $PLAN_RC -ne 0 ]; then
        echo ""
        echo "ERROR: the dry-run report itself failed partway through (see above)."
        echo "Nothing was changed either way -- migration_status.sql never writes."
        exit 5
    fi
    echo ""
    echo "======================================================================"
    echo " DRY RUN COMPLETE -- nothing was changed and nothing was backed up"
    echo " (a dry run writes nothing, so there is nothing yet to protect)."
    echo " Run this script again without --dry-run to actually apply the plan"
    echo " above; the mandatory full-database backup happens automatically"
    echo " before anything is written."
    echo "======================================================================"
    exit 0
fi

# ---------------------------------------------------------------------
# STEP 2: MANDATORY full-database backup. Not optional, not skippable.
# If this fails, NOTHING below it ever runs.
# ---------------------------------------------------------------------
echo "--- Step 2 of 4: mandatory full-database backup -----------------------"
# No -w here on purpose: MYSQL_PWD is already exported above, and the child
# script prefers an inherited MYSQL_PWD over prompting again -- this keeps
# the password out of this process's own argv (never visible to `ps` on a
# shared machine), which putting it on -w here would defeat.
BACKUP_ARGS=(-d "$DB" -u "$USER")
if [ -n "$SOCKET" ]; then BACKUP_ARGS+=(-S "$SOCKET"); else BACKUP_ARGS+=(-h "$HOST" -P "$PORT"); fi
if [ -n "$BACKUP_OUTDIR" ]; then BACKUP_ARGS+=(-o "$BACKUP_OUTDIR"); fi
if [ "$SKIP_SPACE_CHECK" -eq 1 ]; then BACKUP_ARGS+=(-f); fi

set +e
BACKUP_OUT="$("$SCRIPT_DIR/rollback/backup_full_database.sh" "${BACKUP_ARGS[@]}" 2>&1)"
BACKUP_RC=$?
set -e
echo "$BACKUP_OUT"

if [ $BACKUP_RC -ne 0 ]; then
    echo ""
    echo "======================================================================"
    echo " REFUSING TO PROCEED -- the mandatory backup did not succeed (see"
    echo " above). NO install.sql, migration, or schema change has been run."
    echo " Your database has not been touched. Fix the problem reported above,"
    echo " then run this script again."
    echo "======================================================================"
    exit 6
fi
BACKUP_FILE="$(echo "$BACKUP_OUT" | grep '^BACKUP_FILE=' | tail -n1 | cut -d= -f2- || true)"
echo ""
echo "Backup verified. Proceeding."
echo ""

# ---------------------------------------------------------------------
# STEP 3: install.sql, then every migration in sql/migrations/, in
# filename order (which is numeric order, since they are zero-padded).
# Stops immediately on the first failure -- everything before that point
# already succeeded and does not need to be re-run.
# ---------------------------------------------------------------------
echo "--- Step 3 of 4: install.sql + migrations ------------------------------"
FAILED=0
if ! run_sql_file "install.sql" "$SCRIPT_DIR/install.sql"; then
    FAILED=1
fi
if [ "$FAILED" -eq 0 ]; then
    for f in "$SCRIPT_DIR"/migrations/*.sql; do
        [ -e "$f" ] || continue
        if ! run_sql_file "migrations/$(basename "$f")" "$f"; then
            FAILED=1
            break
        fi
    done
fi
echo ""

if [ "$FAILED" -ne 0 ]; then
    echo "======================================================================"
    echo " FAILED -- see the error above. Your data is safe: the full backup"
    echo " taken in Step 2 is at:"
    echo "   $BACKUP_FILE"
    echo " Everything that printed \"OK:\" above already succeeded and is"
    echo " unaffected -- you do not need to restore anything just because of"
    echo " this. Fix the problem described above, then run this script again;"
    echo " every file here is safe to re-run, including the ones that already"
    echo " succeeded."
    echo "======================================================================"
    exit 7
fi

# ---------------------------------------------------------------------
# STEP 4: report -- table names + row counts, discovered dynamically so
# this never goes stale when a future migration adds another table.
# ---------------------------------------------------------------------
echo "--- Step 4 of 4: final report ------------------------------------------"
set +e
"$CLI_BIN" "${CONN[@]}" --table -e \
    "SELECT TABLE_NAME AS \`john-k9 table\`, TABLE_ROWS AS approx_rows
     FROM INFORMATION_SCHEMA.TABLES
     WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME LIKE 'k9\\_%'
     ORDER BY TABLE_NAME;" "$DB"
     # NOTE (sql injection review pass): "$DB" is passed as the trailing
     # argument above, which is how the mysql/mariadb client actually
     # picks which database to use -- so the query itself asks for
     # DATABASE() (the database that connection is already on) instead of
     # rebuilding the database name a second time as literal text inside
     # the SQL string. A database name typed with a quote or backslash in
     # it could otherwise break out of the WHERE clause; this way there is
     # no name to break out of in the first place.
REPORT_RC=$?
set -e
if [ $REPORT_RC -ne 0 ]; then
    echo "(could not print the row-count summary -- this does NOT mean the"
    echo " install/upgrade itself failed; every file above already printed"
    echo " its own \"OK:\" line. Run this again, or query INFORMATION_SCHEMA"
    echo " yourself, to see current table state.)"
fi
echo ""
echo "======================================================================"
echo " SUCCESS -- install.sql and every migration ran cleanly."
echo " Full-database backup taken before any change: $BACKUP_FILE"
echo "======================================================================"
exit 0
