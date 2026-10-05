#!/usr/bin/env bash
#
# john-k9 :: back up the ENTIRE database (every table, every resource)
# =====================================================================
#
# This is NOT the same tool as backup_k9_tables.sh. Read the difference:
#
#   backup_k9_tables.sh        backs up ONLY our own john-k9 tables (see
#                               that script's own ALL_TABLES list for the
#                               current, authoritative count). Use it before
#                               an uninstall/rollback of THIS resource.
#
#   backup_full_database.sh    (this file) backs up EVERY table in your
#                               database -- players, other resources,
#                               everything. Use it before an INSTALL or
#                               MIGRATION, because a schema change touches
#                               the database as a whole (the SQL client
#                               you run it through can abort partway
#                               through, mid-ALTER, on this table or any
#                               other) and the safety net for that has to
#                               cover the whole database, not just ours.
#
# `sql/k9_setup.sh` calls this automatically before it writes anything, and
# refuses to proceed at all if this script fails. `sql/rollback/uninstall.sh`
# does the same before it uninstalls. You do not have to remember to run
# this yourself if you use either of those.
#
# WHERE BACKUPS GO: this folder's own `backups/` subfolder
# (`sql/rollback/backups/`) by default -- kept right next to the k9-only
# backups so there is exactly one place to look, but named
# `john-k9-FULLDB-backup-...` (note "FULLDB") so the two kinds can never
# be confused for each other in a directory listing.
#
# USAGE (simplest form -- it will ask for your password):
#     ./backup_full_database.sh -d your_database_name -u your_mysql_user
#
# OTHER OPTIONS:
#     -d NAME    database name                (required)
#     -u USER    MySQL username               (default: root)
#     -h HOST    server hostname              (default: 127.0.0.1)
#     -P PORT    server port                  (default: 3306)
#     -S PATH    unix socket, instead of -h/-P
#     -o DIR     where to write the backup    (default: sql/rollback/backups
#                                               next to this script)
#     -w PASS    password on the command line (NOT recommended -- other
#                users on the machine can see it; just omit it and let
#                the script prompt you instead)
#     -f         skip the free-disk-space check (see "SIZE" below --
#                only use this if you have already checked space yourself)
#
# EXIT CODE: 0 means the backup succeeded, was verified, and the file is
# safe to restore from. ANYTHING ELSE means it did NOT, and no write should
# proceed. This script's whole reason to exist is that callers can rely on
# that exit code to gate a write -- see `sql/k9_setup.sh`.
#
# =====================================================================
# THINGS THIS CANNOT FULLY PROTECT AGAINST -- READ BEFORE YOU TRUST IT
#
# SIZE: a long-running server's database can be many gigabytes. Dumping it
# takes real time and real disk space, proportional to how much data you
# have, not to how small john-k9's own handful of tables are. This
# script estimates your database's size from INFORMATION_SCHEMA before
# starting and checks it against the free space in the backup directory --
# see "CHECK: is there enough disk space?" below. It refuses rather than
# risk filling your disk mid-dump (a full disk can crash the database
# server itself, which is a strictly worse outcome than the migration you
# were trying to protect against). If you have already verified you have
# space and the estimate is wrong for your situation, `-f` skips this
# check -- but nothing here can shrink how much space the dump itself
# actually needs.
#
# LOCKING: this uses `--single-transaction`, which takes a consistent
# snapshot WITHOUT holding a lock, so a live server with connected players
# keeps running normally throughout -- no stall. The tradeoff, disclosed
# rather than hidden: `--single-transaction` only guarantees a consistent
# snapshot for InnoDB (transactional) tables. If your database contains
# any NON-InnoDB table (MyISAM is the common case -- some older FiveM
# resources still use it), that specific table is read without a lock and
# a write landing on it mid-dump could produce a slightly inconsistent
# copy of THAT table. This script detects and lists any non-InnoDB table
# it finds so you know whether this applies to you (virtually all modern
# qbx_core/QBox/ESX resources are InnoDB by default, so most installs see
# nothing here) -- if it does and you need a guaranteed-consistent copy of
# those specific tables, stop your server (or pause writes) before running
# this, or add `--lock-tables` yourself with a copy of this script's
# DUMP_ARGS. This script does not force a server-wide lock by default,
# because stalling every connected player is a worse default than a
# disclosed, narrow edge case.
#
# PERMISSIONS: a full dump needs SELECT on every table (and SHOW VIEW /
# TRIGGER if you have any). A restricted managed-hosting account may not
# have that on databases/tables outside what it normally uses. This script
# cannot reliably predict a per-table permission denial ahead of time (grant
# systems vary too much host to host) -- if `mysqldump` hits one, it fails
# outright and this script reports that failure and refuses to let a write
# proceed, exactly the same as any other backup failure. It does NOT
# produce a silently truncated dump that looks fine and is not.
#
# PARTIAL DUMP: if this script (or its connection) is interrupted partway
# through, the output file could exist on disk without being a real,
# restorable backup. This script never lets that reach you as a false
# success -- see "verify the dump actually finished" below, which checks
# both the process exit code AND mysqldump's own "-- Dump completed on"
# completion marker before declaring success.
# =====================================================================

set -euo pipefail

DB=""; USER="root"; HOST="127.0.0.1"; PORT="3306"; SOCKET=""; OUTDIR=""; PASS=""; SKIP_SPACE_CHECK=0
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

while getopts ":d:u:h:P:S:o:w:f" opt; do
    case "$opt" in
        d) DB="$OPTARG" ;;
        u) USER="$OPTARG" ;;
        h) HOST="$OPTARG" ;;
        P) PORT="$OPTARG" ;;
        S) SOCKET="$OPTARG" ;;
        o) OUTDIR="$OPTARG" ;;
        w) PASS="$OPTARG" ;;
        f) SKIP_SPACE_CHECK=1 ;;
        \?) echo "ERROR: unknown option -$OPTARG. Run with no arguments to see usage." >&2; exit 2 ;;
        :)  echo "ERROR: option -$OPTARG needs a value." >&2; exit 2 ;;
    esac
done

if [ -z "$OUTDIR" ]; then OUTDIR="$SCRIPT_DIR/backups"; fi

if [ -z "$DB" ]; then
    echo "ERROR: you must say which database to back up, with -d" >&2
    echo "" >&2
    echo "   Example:  ./backup_full_database.sh -d your_database_name -u your_mysql_user" >&2
    exit 2
fi

# --- locate the client binaries (MariaDB renamed them; support both) ----
if command -v mysqldump >/dev/null 2>&1; then DUMP_BIN="mysqldump"
elif command -v mariadb-dump >/dev/null 2>&1; then DUMP_BIN="mariadb-dump"
else
    echo "ERROR: neither 'mysqldump' nor 'mariadb-dump' is installed on this machine." >&2
    echo "       Install your database's client tools, or run this script on the" >&2
    echo "       database server itself. NO BACKUP WAS TAKEN -- do not proceed with" >&2
    echo "       any install/migration/uninstall until this is fixed." >&2
    exit 3
fi
if command -v mysql >/dev/null 2>&1; then CLI_BIN="mysql"
elif command -v mariadb >/dev/null 2>&1; then CLI_BIN="mariadb"
else
    echo "ERROR: neither 'mysql' nor 'mariadb' is installed on this machine." >&2
    exit 3
fi

# --- password: prefer an already-exported MYSQL_PWD (e.g. this script was
#     invoked by sql/k9_setup.sh or sql/rollback/uninstall.sh, which already
#     collected it once and export it for exactly this reason) over -w, and
#     -w over prompting again. Never require a caller to put a password we
#     already have on this process's own argv, where a `ps` from another
#     user on a shared machine could see it. -----------------------------
if [ -z "$PASS" ] && [ -n "${MYSQL_PWD:-}" ]; then
    PASS="$MYSQL_PWD"
elif [ -z "$PASS" ]; then
    printf "MySQL password for user '%s' (leave blank if there is none): " "$USER" >&2
    read -r -s PASS
    echo "" >&2
fi
export MYSQL_PWD="$PASS"   # keeps the password out of the process list

if [ -n "$SOCKET" ]; then CONN=(--socket="$SOCKET" --user="$USER")
else                      CONN=(--host="$HOST" --port="$PORT" --user="$USER"); fi

# --- check we can actually connect before promising anything ------------
if ! "$CLI_BIN" "${CONN[@]}" --batch --skip-column-names -e "SELECT 1" "$DB" >/dev/null 2>&1; then
    echo "ERROR: could not connect to database '$DB' as user '$USER'." >&2
    echo "       Check the database name, username and password, and that the" >&2
    echo "       server is running. NO BACKUP WAS TAKEN. Nothing has been changed." >&2
    exit 4
fi

# --- how many real (base) tables does this database actually have? ------
# NOTE (sql injection review pass): "$DB" is passed as the query's own
# trailing argument below, the same way every mysqldump/mysql call in this
# script already does -- that is what actually tells the client which
# database to use. The query itself then asks for DATABASE() (the database
# that connection is already on) instead of splicing the database name a
# second time into the middle of the SQL text as a quoted literal. A
# database name containing a quote or backslash could otherwise break out
# of that literal; asking for DATABASE() instead removes the literal
# entirely, so there is nothing for an odd name to break out of.
TABLE_COUNT=$("$CLI_BIN" "${CONN[@]}" --batch --skip-column-names -e \
    "SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA=DATABASE() AND TABLE_TYPE='BASE TABLE';" "$DB" 2>/dev/null || echo 0)

if [ "$TABLE_COUNT" = "0" ]; then
    echo "ERROR: database '$DB' has no tables at all. There is nothing to back up." >&2
    echo "       Check you named the right database. NO BACKUP WAS TAKEN." >&2
    exit 5
fi

# --- CHECK: is there enough disk space? ----------------------------------
# Estimate: sum of data+index bytes across every table in this schema, per
# INFORMATION_SCHEMA -- an ESTIMATE, not an exact figure (a text SQL dump is
# often smaller than raw InnoDB storage, since indexes are not dumped as
# separate bytes -- but compression, fragmentation and utf8mb4 widths all
# push the other way for some databases). Refuse outright if the backup
# directory's filesystem does not even have room for the raw data size
# with no margin at all; warn (but proceed) if it has less than 1.5x that.
if [ "$SKIP_SPACE_CHECK" -eq 0 ]; then
    # Same DATABASE()-instead-of-a-quoted-literal fix as TABLE_COUNT above.
    DB_SIZE_KB=$("$CLI_BIN" "${CONN[@]}" --batch --skip-column-names -e \
        "SELECT IFNULL(ROUND(SUM(data_length+index_length)/1024),0) FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA=DATABASE();" "$DB" 2>/dev/null || echo 0)
    mkdir -p "$OUTDIR"
    FREE_KB=$(df -Pk "$OUTDIR" 2>/dev/null | awk 'NR==2 {print $4}' || echo "")
    if [ -n "$DB_SIZE_KB" ] && [ -n "$FREE_KB" ] && [ "$DB_SIZE_KB" -gt 0 ]; then
        if [ "$FREE_KB" -lt "$DB_SIZE_KB" ]; then
            echo "ERROR: not enough free disk space to safely back up database '$DB'." >&2
            echo "       Estimated database size:  $((DB_SIZE_KB / 1024)) MB" >&2
            echo "       Free space in $OUTDIR:  $((FREE_KB / 1024)) MB" >&2
            echo "       Refusing to start the dump rather than risk filling your disk" >&2
            echo "       partway through -- a full disk can crash the database server" >&2
            echo "       itself, which is worse than the problem you were trying to" >&2
            echo "       avoid. Free up space, or point -o at a directory on a bigger" >&2
            echo "       disk, then try again. NO BACKUP WAS TAKEN." >&2
            exit 9
        elif [ "$FREE_KB" -lt "$((DB_SIZE_KB * 3 / 2))" ]; then
            echo "WARNING: disk space is tight. Estimated DB size ~$((DB_SIZE_KB / 1024)) MB," \
                 "free space ~$((FREE_KB / 1024)) MB in $OUTDIR. Proceeding, but watch this." >&2
        fi
    fi
fi

# --- inform about any non-InnoDB tables (single-transaction caveat) -----
# Same DATABASE()-instead-of-a-quoted-literal fix as TABLE_COUNT/DB_SIZE_KB above.
NON_INNODB=$("$CLI_BIN" "${CONN[@]}" --batch --skip-column-names -e \
    "SELECT GROUP_CONCAT(CONCAT(TABLE_NAME,' (',ENGINE,')') SEPARATOR ', ') FROM INFORMATION_SCHEMA.TABLES
      WHERE TABLE_SCHEMA=DATABASE() AND TABLE_TYPE='BASE TABLE' AND ENGINE IS NOT NULL AND ENGINE <> 'InnoDB';" "$DB" 2>/dev/null || echo "")
if [ -n "$NON_INNODB" ] && [ "$NON_INNODB" != "NULL" ]; then
    echo "NOTE: these tables are NOT InnoDB, so --single-transaction cannot" >&2
    echo "      guarantee a perfectly consistent snapshot of them if something" >&2
    echo "      writes to them during the dump: $NON_INNODB" >&2
    echo "      (Everything else in this database IS covered.) See this script's" >&2
    echo "      own header, section LOCKING, if you need a guaranteed-consistent" >&2
    echo "      copy of these specific tables." >&2
fi

mkdir -p "$OUTDIR"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUTFILE="$OUTDIR/john-k9-FULLDB-backup-${DB}-${STAMP}.sql"

# NEVER overwrite an existing backup -- same reasoning as backup_k9_tables.sh.
if [ -e "$OUTFILE" ]; then
    n=2
    while [ -e "$OUTDIR/john-k9-FULLDB-backup-${DB}-${STAMP}-${n}.sql" ]; do
        n=$((n + 1))
    done
    OUTFILE="$OUTDIR/john-k9-FULLDB-backup-${DB}-${STAMP}-${n}.sql"
fi

echo "Backing up ALL $TABLE_COUNT table(s) in database '$DB' (not just john-k9's)..."

# --single-transaction : consistent InnoDB snapshot without locking, so a
#                        live server with connected players is not stalled.
#                        See the LOCKING section in this file's header for
#                        the disclosed non-InnoDB tradeoff.
# --no-tablespaces     : required on MySQL 8 unless the user holds the
#                        PROCESS privilege. Not understood by older
#                        mysqldump builds, hence the retry below.
# (no table list given -> mysqldump dumps every table in the database)
DUMP_ARGS=(--single-transaction --routines=TRUE --events=TRUE --triggers=TRUE
           --add-drop-table --complete-insert --default-character-set=utf8mb4)

set +e
"$DUMP_BIN" "${CONN[@]}" "${DUMP_ARGS[@]}" --no-tablespaces "$DB" > "$OUTFILE" 2>"$OUTFILE.err"
rc=$?
if [ $rc -ne 0 ] && grep -qi "unknown option\|no-tablespaces" "$OUTFILE.err" 2>/dev/null; then
    "$DUMP_BIN" "${CONN[@]}" "${DUMP_ARGS[@]}" "$DB" > "$OUTFILE" 2>"$OUTFILE.err"
    rc=$?
fi
set -e

if [ $rc -ne 0 ]; then
    echo "ERROR: the full database backup FAILED. Do not run install.sql, any" >&2
    echo "       migration, or uninstall.sql. The database itself is unchanged." >&2
    echo "       Error from $DUMP_BIN:" >&2
    sed 's/^/       /' "$OUTFILE.err" >&2
    if grep -qi "access denied\|command denied" "$OUTFILE.err" 2>/dev/null; then
        echo "" >&2
        echo "       This looks like a PERMISSIONS problem: the user '$USER' may be" >&2
        echo "       missing SELECT (and possibly SHOW VIEW / TRIGGER / PROCESS) on" >&2
        echo "       one or more tables. Ask your database host to grant it, or run" >&2
        echo "       this script as a user that already has it." >&2
    fi
    rm -f "$OUTFILE"
    exit 6
fi

# --- verify the dump actually finished, not just that the process exited
#     with code 0 (a partial dump is a trap -- it looks like a real backup
#     file and is not one) --------------------------------------------
if [ ! -s "$OUTFILE" ]; then
    echo "ERROR: the backup file came out empty. Treat this as a FAILED backup." >&2
    rm -f "$OUTFILE" "$OUTFILE.err"
    exit 7
fi
if ! tail -n 5 "$OUTFILE" | grep -q -- "-- Dump completed on"; then
    echo "ERROR: the backup file does not end with mysqldump's own completion" >&2
    echo "       marker ('-- Dump completed on ...'). Treat this as an INCOMPLETE," >&2
    echo "       UNRESTORABLE backup -- it may look fine but is not safe to rely" >&2
    echo "       on. This usually means the connection was interrupted partway" >&2
    echo "       through. The partial file has been renamed with a .INCOMPLETE" >&2
    echo "       suffix so it cannot be mistaken for a real backup; do not use it." >&2
    mv -f "$OUTFILE" "$OUTFILE.INCOMPLETE"
    exit 10
fi
CREATE_COUNT=$(grep -c '^CREATE TABLE `' "$OUTFILE" || true)
if [ "$CREATE_COUNT" -lt "$TABLE_COUNT" ]; then
    echo "ERROR: expected $TABLE_COUNT table(s) but only found $CREATE_COUNT" >&2
    echo "       CREATE TABLE statement(s) in the backup file. Treat this as a" >&2
    echo "       FAILED/INCOMPLETE backup. The file has been renamed with a" >&2
    echo "       .INCOMPLETE suffix so it cannot be mistaken for a real one." >&2
    mv -f "$OUTFILE" "$OUTFILE.INCOMPLETE"
    exit 8
fi
rm -f "$OUTFILE.err"

SIZE="$(du -h "$OUTFILE" | cut -f1)"

echo ""
echo "======================================================================"
echo " FULL DATABASE BACKUP OK"
echo "======================================================================"
echo " File:   $OUTFILE"
echo " Size:   $SIZE"
echo " Tables: $CREATE_COUNT of $TABLE_COUNT verified present in the dump"
echo ""
echo " THIS IS YOUR WHOLE DATABASE -- not just john-k9. Restoring it rolls"
echo " back EVERY resource's data to this exact moment, not only ours."
echo ""
echo " TO PUT IT ALL BACK, run exactly this one line:"
echo ""
if [ -n "$SOCKET" ]; then
    echo "   $CLI_BIN --socket=$SOCKET -u $USER -p $DB < $OUTFILE"
else
    echo "   $CLI_BIN -h $HOST -P $PORT -u $USER -p $DB < $OUTFILE"
fi
echo ""
echo " (It will ask for the same password you just typed. Restoring REPLACES"
echo "  every table in '$DB' with the version saved in this file.)"
echo ""
echo " Keep this file somewhere safe -- copy it off the server if you can."
echo "======================================================================"

# Machine-readable line for wrapper scripts (sql/k9_setup.sh,
# sql/rollback/uninstall.sh) to pick up the exact file path without
# re-parsing the pretty output above.
echo "BACKUP_FILE=$OUTFILE"
