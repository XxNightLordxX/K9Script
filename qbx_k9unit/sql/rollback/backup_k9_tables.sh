#!/usr/bin/env bash
#
# qbx_k9unit :: back up every database table this resource owns
# =====================================================================
#
# RUN THIS BEFORE ANY ROLLBACK OR UNINSTALL. It is the only way back.
#
# It saves a copy of every table qbx_k9unit owns:
#     k9_certifications   who is certified, granted/revoked by whom
#     k9_search_log       every contraband search ever performed
#     k9_partnerships     every K9/handler partnership, past and present
#     k9_partnership_pair_progress
#                         the highest partnership-tenure milestone tier each
#                         exact (K9, handler) pair has ever earned -- the
#                         fully durable anti-farm guard table
#     k9_progression      every player's accumulated K9 XP
#     k9_permissions      every named permission grant/revoke, and by whom
#     k9_certification_specializations
#                         every K9 specialization grant/revoke, and by whom
#     k9_runtime_feature_overrides / k9_runtime_override_audit
#                         every live runtime override, and its full history
#     k9_tablet_theme / k9_tablet_theme_audit
#                         the current tablet theme, and its full history
#     k9_ped_assignments  every citizenid's currently-applied K9 ped model
#     k9_certification_tiers / k9_certification_tier_capabilities /
#     k9_certification_tier_audit
#                         the certification tier catalog, what each tier
#                         grants, and the full history of every tier edit
#     k9_equipment_shop_locations / k9_equipment_shop_locations_audit
#                         every tablet-added K9 equipment shop location, and
#                         the full history of every add/move/remove made
#     k9_permission_keys / k9_permission_key_audit
#                         the high-command-editable permission-key catalog
#                         (config defaults plus any custom key added,
#                         relabeled, or tombstoned), and the full history of
#                         every catalog edit made
#     k9_equipment_shop_items / k9_equipment_shop_item_audit
#                         the high-command-editable K9 equipment shop ITEM
#                         catalog (price/label/order/purchase-requirement
#                         overrides and additions on top of config.lua's own
#                         defaults, plus tombstones), and the full history of
#                         every create/edit/reorder/delete made
#     k9_xp_tiers / k9_xp_tier_audit
#                         every high-command-edited XP-rank field override
#                         (threshold/label/multipliers/badge) on top of
#                         config.lua's own Config.XPTiers defaults, and the
#                         full history of every rank edit made
#     k9_individual_overrides / k9_individual_override_audit
#                         every high-command-edited per-INDIVIDUAL-K9
#                         speed/scent/medkit-cooldown override (the "god
#                         mode" layer on top of whichever XP-tier profile a
#                         citizenid otherwise resolves to), and the full
#                         history of every override create/edit/reset made
#     k9_dog_characters   every character an admin has ever pinned as
#                         permanently a dog with /k9setdog (mana_policedogs
#                         feature parity)
#     k9_personnel        every K9/Handler roster assignment and callsign,
#                         past and present (ROSTER_SPEC.md §3/§4)
#     k9_wellbeing        every online K9's current fatigue, mood, fear/
#                         stress, injury, hunger and thirst condition
#                         (server/wellbeing.lua)
#
# ...into a single timestamped .sql file, and prints the one command that
# puts it all back. It touches nothing else in your database, and it makes
# no changes at all -- it only reads.
#
# USAGE (simplest form -- it will ask for your password):
#     ./backup_k9_tables.sh -d your_database_name -u your_mysql_user
#
# OTHER OPTIONS:
#     -d NAME    database name                (required)
#     -u USER    MySQL username               (default: root)
#     -h HOST    server hostname              (default: 127.0.0.1)
#     -P PORT    server port                  (default: 3306)
#     -S PATH    unix socket, instead of -h/-P
#     -o DIR     where to write the backup    (default: current directory)
#     -w PASS    password on the command line (NOT recommended -- other
#                users on the machine can see it; just omit it and let
#                the script prompt you instead)
#
# EXIT CODE: 0 means the backup succeeded and the file is safe to rely on.
# Anything else means it did NOT -- do not proceed with a rollback.
# =====================================================================

set -euo pipefail

DB=""; USER="root"; HOST="127.0.0.1"; PORT="3306"; SOCKET=""; OUTDIR="."; PASS=""

while getopts ":d:u:h:P:S:o:w:" opt; do
    case "$opt" in
        d) DB="$OPTARG" ;;
        u) USER="$OPTARG" ;;
        h) HOST="$OPTARG" ;;
        P) PORT="$OPTARG" ;;
        S) SOCKET="$OPTARG" ;;
        o) OUTDIR="$OPTARG" ;;
        w) PASS="$OPTARG" ;;
        \?) echo "ERROR: unknown option -$OPTARG. Run with no arguments to see usage." >&2; exit 2 ;;
        :)  echo "ERROR: option -$OPTARG needs a value." >&2; exit 2 ;;
    esac
done

if [ -z "$DB" ]; then
    echo "ERROR: you must say which database to back up, with -d" >&2
    echo "" >&2
    echo "   Example:  ./backup_k9_tables.sh -d your_database_name -u your_mysql_user" >&2
    echo "" >&2
    echo "   (Your database name is the same one you ran sql/install.sql against." >&2
    echo "    In txAdmin it is usually shown on the server's Settings page.)" >&2
    exit 2
fi

# --- locate the client binaries (MariaDB renamed them; support both) ----
if command -v mysqldump >/dev/null 2>&1; then DUMP_BIN="mysqldump"
elif command -v mariadb-dump >/dev/null 2>&1; then DUMP_BIN="mariadb-dump"
else
    echo "ERROR: neither 'mysqldump' nor 'mariadb-dump' is installed on this machine." >&2
    echo "       Install your database's client tools, or run this script on the" >&2
    echo "       database server itself." >&2
    exit 3
fi
if command -v mysql >/dev/null 2>&1; then CLI_BIN="mysql"
elif command -v mariadb >/dev/null 2>&1; then CLI_BIN="mariadb"
else
    echo "ERROR: neither 'mysql' nor 'mariadb' is installed on this machine." >&2
    exit 3
fi

# --- password: prompt rather than take it on the command line -----------
if [ -z "$PASS" ]; then
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
    echo "       server is running. Nothing has been changed." >&2
    exit 4
fi

# --- work out which of our tables actually exist ------------------------
# Dumping a table that does not exist makes mysqldump fail outright, so a
# database that only ever ran part of the install still backs up cleanly.
#
# migration 0010 (db-schema foolproofing pass, 2026-08-25): the three
# certification-tier tables below were missing from this list entirely --
# flagged explicitly by sql/rollback/0010_down.sql's own header as needing
# this exact fix, since a backup taken via this script right before an
# uninstall would otherwise silently NOT protect them. migration 0011
# (db-schema pass, 2026-08-26): the same class of gap, this time for the
# two equipment-shop-location tables -- flagged explicitly by
# sql/rollback/0011_down.sql's own header, fixed here the same way. This
# list stays hand-maintained rather than a `k9\_%` INFORMATION_SCHEMA sweep
# for the same reason sql/rollback/uninstall_all.sql's own DROP list does
# (see that file's "OWNED TABLE LIST" comment): this database can
# legitimately contain another K9 resource's own tables (e.g. `k9_units`),
# and a blind sweep would try to dump those too, which is not this script's
# job and may not even be readable by this database user. migration 0013
# (owner-directed "add or remove permissions" pass): the same class of gap,
# this time for the two permission-key-catalog tables -- flagged explicitly
# by sql/rollback/0013_down.sql's own header, fixed here the same way.
# migration 0014 (owner-directed "give high command real control over the
# equipment shop" pass, item-catalog half): the same class of gap, this
# time for the two equipment-shop-item tables -- flagged explicitly by
# sql/rollback/0014_down.sql's own header ("report to the sql/** owner that
# these two table names need adding to that script's own table list"),
# fixed here the same way. SCHEMA-SAFETY AUDIT FIX (db-schema pass,
# 2026-08-27): migration 0019's own table (k9_dog_characters, the
# mana_policedogs feature-parity admin-pinned dog-character record) had
# the exact same gap -- completely absent from this list since the day it
# shipped, so a backup taken via this script right before an uninstall
# would have silently NOT protected it. Fixed here, added below alongside
# migration 0020's k9_personnel (ROSTER_SPEC.md §3/§4, added from the
# start). db-schema pass, 2026-08-27: migration 0022's k9_wellbeing (K9
# fatigue/mood/fear-stress/injury/hunger/thirst persistence,
# server/wellbeing.lua's K9Store.Wellbeing_Get/K9Store.Wellbeing_Upsert)
# added here from the start, same reasoning. The DRIFT GUARD immediately
# below is the backstop for the next table a future migration adds here.
ALL_TABLES=(k9_certifications k9_search_log k9_partnerships k9_partnership_pair_progress
            k9_progression k9_permissions
            k9_certification_specializations k9_runtime_feature_overrides
            k9_runtime_override_audit k9_tablet_theme k9_tablet_theme_audit k9_ped_assignments
            k9_certification_tiers k9_certification_tier_capabilities k9_certification_tier_audit
            k9_equipment_shop_locations k9_equipment_shop_locations_audit
            k9_permission_keys k9_permission_key_audit
            k9_equipment_shop_items k9_equipment_shop_item_audit
            k9_xp_tiers k9_xp_tier_audit
            k9_individual_overrides k9_individual_override_audit
            k9_dog_characters k9_personnel k9_wellbeing k9_roles k9_role_audit)
PRESENT=()
MISSING=()
for t in "${ALL_TABLES[@]}"; do
    # NOTE (sql injection review pass): "$DB" is passed as this query's own
    # trailing argument, the same way every mysqldump/mysql call in this
    # script already does -- that is what actually selects the database.
    # The query itself then asks for DATABASE() instead of splicing the
    # database name a second time into the SQL text as a quoted literal, so
    # a database name containing a quote or backslash has nothing to break
    # out of. "$t" is not user input -- it only ever comes from the fixed
    # ALL_TABLES list this script itself declares above, never from a
    # command-line flag -- so it is left as a literal here.
    n=$("$CLI_BIN" "${CONN[@]}" --batch --skip-column-names -e \
        "SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='$t';" "$DB" 2>/dev/null || echo 0)
    if [ "$n" = "1" ]; then PRESENT+=("$t"); else MISSING+=("$t"); fi
done

# --- DRIFT GUARD -------------------------------------------------------
# Every time a new migration adds a table, that table has to be added to
# ALL_TABLES above or this script silently backs up less than it claims --
# which is the worst possible failure for a backup tool, because you only
# find out when you try to restore. This catches that: anything in the
# database named like one of ours but NOT in the list above gets called
# out loudly. (`k9_units` and similar tables belonging to OTHER K9
# resources will show up here too -- that is correct and expected; they
# are not ours to back up. This is a prompt to check, not an error.)
# Same DATABASE()-instead-of-a-quoted-literal fix as the PRESENT/MISSING
# loop above; "$DB" is passed positionally below instead.
UNKNOWN=$("$CLI_BIN" "${CONN[@]}" --batch --skip-column-names -e \
    "SELECT GROUP_CONCAT(TABLE_NAME) FROM INFORMATION_SCHEMA.TABLES
      WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME LIKE 'k9\\_%'
        AND TABLE_NAME NOT IN ($(printf "'%s'," "${ALL_TABLES[@]}" | sed 's/,$//'))" "$DB" 2>/dev/null)
if [ -n "$UNKNOWN" ] && [ "$UNKNOWN" != "NULL" ]; then
    echo "NOTE: these k9_* tables are NOT backed up by this script: $UNKNOWN" >&2
    echo "      If any of them belong to qbx_k9unit, this script is out of date --" >&2
    echo "      report it before relying on this backup. If they belong to a" >&2
    echo "      different K9 resource, this is expected and you can ignore it." >&2
fi

if [ "${#PRESENT[@]}" -eq 0 ]; then
    echo "ERROR: none of the qbx_k9unit tables exist in database '$DB'." >&2
    echo "       There is nothing to back up. Check you named the right database." >&2
    exit 5
fi

mkdir -p "$OUTDIR"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUTFILE="$OUTDIR/qbx_k9unit-backup-${DB}-${STAMP}.sql"

# NEVER overwrite an existing backup. The timestamp above only has
# one-second resolution, so running this script twice in quick succession
# -- which people do, e.g. when the first run looks like it hung, or just
# to be sure they have a copy -- would otherwise silently replace the
# backup taken moments earlier with a new one. For a file whose entire job
# is to be the last way back, quietly destroying a previous copy is the
# one behaviour that must never happen, so if the name is taken we add
# -2, -3, ... until it is free. Both backups are then kept.
if [ -e "$OUTFILE" ]; then
    n=2
    while [ -e "$OUTDIR/qbx_k9unit-backup-${DB}-${STAMP}-${n}.sql" ]; do
        n=$((n + 1))
    done
    OUTFILE="$OUTDIR/qbx_k9unit-backup-${DB}-${STAMP}-${n}.sql"
fi

echo "Backing up ${#PRESENT[@]} table(s) from '$DB': ${PRESENT[*]}"
if [ "${#MISSING[@]}" -gt 0 ]; then
    echo "  (not present in this database, so not backed up: ${MISSING[*]})"
fi

# --single-transaction : a consistent snapshot without locking the tables,
#                        so a live server keeps running normally throughout.
# --no-tablespaces     : required on MySQL 8 unless the user holds the
#                        PROCESS privilege. Not understood by older
#                        mysqldump builds, hence the retry below.
DUMP_ARGS=(--single-transaction --routines=FALSE --events=FALSE
           --add-drop-table --complete-insert --default-character-set=utf8mb4)

set +e
"$DUMP_BIN" "${CONN[@]}" "${DUMP_ARGS[@]}" --no-tablespaces "$DB" "${PRESENT[@]}" > "$OUTFILE" 2>"$OUTFILE.err"
rc=$?
if [ $rc -ne 0 ] && grep -qi "unknown option\|no-tablespaces" "$OUTFILE.err" 2>/dev/null; then
    "$DUMP_BIN" "${CONN[@]}" "${DUMP_ARGS[@]}" "$DB" "${PRESENT[@]}" > "$OUTFILE" 2>"$OUTFILE.err"
    rc=$?
fi
set -e

if [ $rc -ne 0 ]; then
    echo "ERROR: the backup FAILED. Do not run any rollback or uninstall script." >&2
    echo "       The database itself is unchanged. Error from $DUMP_BIN:" >&2
    sed 's/^/       /' "$OUTFILE.err" >&2
    rm -f "$OUTFILE"
    exit 6
fi

# --- verify the file is real before telling anyone it worked ------------
if [ ! -s "$OUTFILE" ]; then
    echo "ERROR: the backup file came out empty. Treat this as a FAILED backup." >&2
    rm -f "$OUTFILE" "$OUTFILE.err"
    exit 7
fi
for t in "${PRESENT[@]}"; do
    if ! grep -q "CREATE TABLE \`$t\`" "$OUTFILE"; then
        echo "ERROR: table '$t' is missing from the backup file. Treat this as a FAILED backup." >&2
        exit 8
    fi
done
rm -f "$OUTFILE.err"

SIZE="$(du -h "$OUTFILE" | cut -f1)"

echo ""
echo "======================================================================"
echo " BACKUP OK"
echo "======================================================================"
echo " File: $OUTFILE"
echo " Size: $SIZE"
echo ""
echo " Rows saved:"
for t in "${PRESENT[@]}"; do
    c=$("$CLI_BIN" "${CONN[@]}" --batch --skip-column-names -e "SELECT COUNT(*) FROM \`$t\`;" "$DB" 2>/dev/null || echo "?")
    printf "   %-20s %s\n" "$t" "$c"
done
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
echo "  these tables with the versions saved in this file.)"
echo ""
echo " Keep this file somewhere safe -- copy it off the server if you can."
echo "======================================================================"
