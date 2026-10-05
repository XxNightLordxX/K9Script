# John-K9 database guide — for the server owner, not developers

This page answers three questions in plain English: how do I put this in,
how do I take it back out, and what happens to the rest of my database
(qbx_core, my players, everything else I run) either way.

You do not need to know SQL to follow this. Where a technical word shows
up the first time, it is explained right there.

---

## The short version

- **You may not need any of this yet.** The resource ships with
  `Config.Database.enabled = false`, which means it runs with no database
  at all — drop it in, start it, everything works. This whole page is the
  *opt-in* step you take when you decide to keep the server, because with
  the database off nothing survives a restart: certifications, ranks and
  XP, partnerships, permissions, callsigns and themes all reset. The audit
  trail does still work during a session, but it is capped (the most recent
  500 search entries, 200 of everything else) and resets too — so you can
  check what happened an hour ago, never what happened last week. Set
  `enabled = true` in `config.lua` and follow Part 1 below when you are
  ready.
- **Putting it in touches only this resource's own tables.** It never
  looks at, changes, or deletes a table belonging to qbx_core, your
  player data, or any other resource.
- **Taking it out is safe to not do at all.** The normal way to "turn
  this off" is to stop the resource, not to delete anything from your
  database. Your K9 data just sits there, unused, until you turn it back
  on.
- **If you do want the data gone**, there is one file for that, and it
  refuses to do anything until you take a backup and explicitly arm it
  twice. It will not touch a table that does not look like it belongs to
  this resource, even if another K9-style resource on your server happens
  to use a similar name.

---

## Part 1 — Putting it in (first-time install)

You need two files from this `sql/` folder: `preflight_check.sql` and
`install.sql`. That is it — for a brand-new install, you do **not** need
any of the numbered files inside the `migrations/` folder. Those only
matter later, when you update to a newer version of this resource (see
Part 3). (Verified true as of the 2026-08-27 schema-safety audit:
`install.sql` creates every table AND every column any file under
`migrations/` creates or adds, including migration 0019's
`k9_dog_characters` table, which had been missing from `install.sql` — a
real, shipped gap this exact claim used to be wrong about for anyone who
followed it literally. `tests/schemaconvergence_spec.lua` now checks this
on every commit so it cannot go stale again unnoticed.)

### If you have phpMyAdmin, HeidiSQL, Adminer, or any similar tool

1. Open your database (the same one your FiveM server / `qbx_core` uses)
   in the tool.
2. Find the "Run SQL" / "Query" box.
3. Open `preflight_check.sql` in a text editor, copy everything, paste it
   into the query box, and run it.
4. Read the results. You want every line to say **OK**. If any line
   starts with **`!!`**, stop — it means a table name this resource wants
   to use is already taken by something else on your server. Read that
   line; it tells you exactly what is wrong and how to fix it before you
   go any further. Lines starting with `WARN` are just things worth
   knowing, not a reason to stop.
5. Once every line says OK (or only WARN), open `install.sql`, copy all
   of it, paste it into the same query box, and run it.
6. That's it. You just installed the resource's database. It is safe to
   run `install.sql` again later by accident — running it twice does
   nothing the second time.

Both of these two files are plain, ordinary SQL — no special client-only
tricks — so they work in the plain query box of any of these tools.
(A few of the *other* files in this folder, used only for later upgrades
and for uninstalling, use a special line called `DELIMITER` that a plain
query box does not always understand — if you ever need one of those,
use your tool's "Import a file" feature instead of the query box; that
is built to handle it. `preflight_check.sql` and `install.sql` never
need this — a first-time install has no such gotcha.)

### If you have shell/SSH access to your server

Run this instead, which does everything above for you automatically,
plus takes a full backup of your whole database first, every time,
without exception:

```
cd sql
./k9_setup.sh -d your_database_name -u your_mysql_user
```

It checks for name conflicts, backs up your entire database, runs
`install.sql`, then runs everything in `migrations/` in order (harmless
if you have no upgrades to apply yet), and tells you clearly whether it
succeeded. If anything goes wrong at any step, it stops immediately and
tells you your database has not been changed.

### What this does to the rest of your database

Nothing. `install.sql` only ever creates NEW tables, all of them named
starting with `k9_`. It never edits, reads from, or drops any table it
did not create itself. It has no dependency on `qbx_core`'s tables
existing first, and nothing else on your server can break because this
resource's tables now exist.

---

## Part 2 — Turning it off / taking it back out

There are three different levels here, from "barely doing anything" to
"actually deleting data." Pick the lightest one that gets you what you
want.

### Level 1 — Just stop using it (recommended for "I want to turn this off")

Remove (or comment out) the line `ensure john-k9` in your
`server.cfg`, then restart your server. The resource stops running.
Every one of its tables stays exactly as it is, sitting harmlessly in
your database, doing nothing, using barely any space. If you turn it
back on again later — next week, next year — all your K9 certifications,
XP, partnerships, and settings are still there, waiting.

This is almost always what you actually want when you say "turn it off."

### Level 2 — Turn off one specific feature, keep the rest running

Every optional feature has its own on/off switch in `config.lua`
(`Config.Features.SomeFeature = false`). This does not touch your
database at all — the data for that feature just stops being read or
written until you flip the switch back.

### Level 3 — Actually delete the K9 data from your database

Only do this if you are removing the resource for good and specifically
want its tables gone. **This step cannot be undone except from a
backup.** There are two ways to do it; both take a full backup
automatically first and refuse to proceed if that backup fails.

**Easiest — if you have shell access:**

```
cd sql/rollback
./uninstall.sh -d your_database_name -u your_mysql_user --confirm your_database_name
```

You have to type your database name twice (once as `-d`, once as
`--confirm`) as a safety check. It backs up your entire database first,
then deletes only this resource's own tables.

**If you do not have shell access (phpMyAdmin/HeidiSQL only):**

1. Take a backup of your database using your hosting panel or tool's own
   backup feature. Do not skip this — there is no other way back.
2. Open `sql/rollback/uninstall_all.sql` in a text editor. Read the top
   of the file — it lists, table by table, exactly what you are about to
   lose (certifications, search history, XP, and so on), and which parts
   can never be recomputed from anything else.
3. Find the line that says:
   ```
   -- SET @K9_UNINSTALL_CONFIRM = 'YES-DELETE-ALL-MY-K9-DATA';
   ```
   Delete the two dashes and the space at the start of that one line
   only. That is the "arm it" switch — the file does nothing at all
   until this line is uncommented.
4. Import the whole file using your tool's **Import a file** feature
   (not the plain query box — this file uses the special `DELIMITER`
   line mentioned above, which "Import a file" understands and a bare
   query box may not).
5. Read the output. Before it deletes anything, it now prints, in plain
   English, exactly what it is about to remove and how many rows of it
   you currently have — read that first. If it says **REFUSED**, it
   found a reason not to proceed (something else on your server depends
   on one of these tables, or a table with one of these names does not
   actually look like it belongs to this resource) and changed nothing.
   If it says **UNINSTALLED**, this resource's tables are gone.

### What this does to the rest of your database

Even at Level 3, only this resource's own tables are ever touched.
Before deleting anything, the file checks that every table it is about
to remove actually has this resource's own columns — if a *different*
resource on your server happens to use one of the same table names (this
can genuinely happen — some other K9-themed resource, for example), this
file recognizes that it is not one of its own and refuses to touch it,
loudly, by name, instead of guessing. It never uses a broad "delete
anything starting with k9\_" rule — it only ever acts on an exact,
pre-written list of this resource's own 27 table names, and only after
confirming each one is really this resource's own table.

Running the uninstall file twice in a row is safe — the second time it
finds nothing left to delete and says so.

---

## Part 3 — Updating to a newer version later

If you already have this resource installed and are updating it (not
installing for the first time), after replacing the resource's files:

- If you have shell access, just run `./k9_setup.sh` again (Part 1) — it
  handles everything, including any new database changes the update
  needs, safely, whether you are on the very latest version already or
  several versions behind.
- If you do not, run `install.sql` again (harmless — it never removes or
  overwrites anything you already have), then open every file inside
  `sql/migrations/` **in numeric order** (0001, 0002, 0003, and so on
  through the highest number present) and import each one the same way
  described in Part 1 above, using your tool's "Import a file" feature
  rather than the plain query box (most of these use the special
  `DELIMITER` line). It is always safe to import a migration file again
  even if you already have — each one checks first and does nothing if
  there is nothing left for it to do.

  One number in that sequence is deliberately missing from the plain
  `sql/migrations/` listing: there is no top-level `0012_...sql` file.
  That migration lives one folder deeper, at
  `sql/migrations/optional/0012_convert_charset_collation.sql`, and is
  **not** part of the normal upgrade sequence — do not go looking for it
  or import it "to be safe." It only matters if you write your own SQL
  reports that `JOIN` this resource's tables to `players` and hit a
  "mixed collations" database error; if that has never happened to you,
  skip it. Its own header explains exactly who needs it (and who does
  not) in full — read that before running it, not this page.

### A word about giving your database a "spring clean"

`k9_search_log` (the contraband-search history table) is the one table
in this resource that keeps growing forever on a busy server — everyone
else's tables stay small on their own. If your server has been running
for months and you would like to trim old search history you no longer
need, there is a ready-to-use, already-reviewed statement for that in
`sql/maintenance_prune_k9_search_log.sql`. It is entirely optional,
never runs on its own, and only ever removes old rows from that one
table — never a whole table, never anything from any other resource.
Open the file and read the short instructions at the top before using
it.

---

## Questions this page did not answer?

- `sql/preflight_check.sql` — read before installing; tells you if a
  name conflict exists.
- `sql/rollback/backup_k9_tables.sh` / `sql/rollback/backup_full_database.sh`
  — take a backup by hand, any time, for any reason.
- `sql/rollback/0001_down.sql` through the highest-numbered `*_down.sql` present — undo one
  specific past database change without deleting anything (for advanced/
  troubleshooting use; most owners never need these — see Level 2 above
  for the everyday "turn a feature off" case).

If your server refuses to save K9 data and prints a message starting
with `[John-K9] datastore:` in the console, that message itself says
in plain English what is wrong and exactly which of the steps above
fixes it.
