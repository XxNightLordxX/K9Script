# Project History

A condensed record of how `john-k9` got to its current state, for
whoever works on this codebase next. This is not the bug list (see
`KNOWN_ISSUES.md`) and not the technical reference (see
`DEVELOPER_REFERENCE.md` for internals, `README.md` for install/config).
It exists so a real lesson learned along the way — a footgun found, an
exploit closed, an idea considered and rejected — isn't lost, without
requiring anyone to read a multi-thousand-line, commit-by-commit log to
find it.

If something below disagrees with the current code or config, the code
wins — this is a history, not a second copy of current behavior.

---

## What shipped

The resource was built in five rough stages, each adding an independently
toggleable feature set on top of the last. Every feature still ships
behind its own `Config.Features.*` flag; all of them currently ship `true`
in the default config (see `README.md` for the current, authoritative
list and any operator action that implies).

**Foundation.** A player's own persistent K9-model character, certified by
a qualifying officer per department, with a real, server-authoritative
access check on every gated action. A consensual two-player leash system,
a radial menu for self-actions (bark, sit, leash, vehicle load), and a
first/third-person camera toggle. Certification lives in its own database
table (not just character metadata) so it survives reconnects, supports
an audit trail, and is automatically revoked the moment someone leaves an
eligible department.

**Tracking and search.** Scent, blood, and gunpowder trail tracking, each
rendering a ground trail that degrades realistically at water crossings.
Contraband search of a vehicle or person, with a real server-side
inventory read (never a client-reported claim), tiered bystander alerts,
and a full search audit log. Thermal and night vision, toggled as the K9's
own innate perception rather than a granted permission. Door interaction:
a cosmetic scratch-to-alert, and a nudge-open that never touches real lock
state (there's no reliable, generic way to query an arbitrary door-lock
resource's state, so nudge-open is deliberately cosmetic-only, gated to
already-unlocked doors).

**Combat and action.** Bite & Hold, Non-Lethal Takedown, and Prop
Dragging — all three can target a player, not just an NPC, subject to a
wanted/suspect gate. This was a deliberate, informed decision, not an
oversight: no other FiveM K9 script surveyed had built player-vs-player K9
combat before, so there was no ecosystem precedent to lean on. Because a
live player's own client is the only thing that can actually apply certain
restrictive effects to itself (there's no way for the server or another
player to force a specific ragdoll/speed-limit/damage-suppression state
onto someone else's client), these three mechanics are honest about being
detection-and-log against a non-cooperating target, never a guaranteed
restraint — see `DEVELOPER_REFERENCE.md` §12.0 item 8 for the full
reasoning. Handler-Down Defense streamlines targeting when a partnered
handler takes damage nearby (the K9 player still confirms and controls
their own actions — this is a UI convenience, never an AI takeover).
Recall lets a handler unconditionally call their K9 off any of the three
mechanics, deliberately without a certification check on either side,
because an escape hatch must never depend on the same permission it might
be recalling someone out of. A DB-backed handler/K9 partnership registry
(mutual consent, survives a restart) underlies both Recall and
Handler-Down Defense.

**Inventory, progression, and wellbeing.** A K9's own `ox_inventory` gear
stash. Server-authoritative XP with tiered speed/scent bonuses. A unified
wellbeing subsystem (Fatigue, Mood, Fear/Stress, Distraction, Injury) — one
shared stat store and tick loop, each stat independently toggleable, all
five feeding one shared client-side "move-rate composer" so they can't
silently overwrite each other's speed effects. A K9 medkit. A contraband
screen effect for the searching officer.

**Audio, props, and polish.** An expanded bark radial (alert/aggressive/
calm variants), proximity-scaled growl audio, cosmetic prop attachments
(vest/harness) via a one-time bone-index sweep tool, a fetch-the-ball
mechanic, and a deployable kennel. A true picture-in-picture partner
camera feed was investigated and found genuinely impossible with FiveM's
current natives (DUI/NUI textures render HTML, not the 3D scene); what
shipped instead is a full-screen switch to your active partner's own
viewpoint, which is a real, working feature, not a placeholder.

**Later additions, after all five stages had landed:** certification
tiers with real, enforceable capabilities (not just labels); per-person
feature blocking widened from nine features to most of the resource;
a compatibility/adapter layer so targeting and inventory auto-detect the
host server's scripts (see `KNOWN_ISSUES.md` for why this does *not*
extend to the underlying framework); several tablet screens (a
permission-key catalog editor, an XP-rank editor, an equipment shop
location manager, and a read-only audit trail viewer); and a pass that
switched every feature flag from its cautious `false` default to `true`,
at the owner's request, once each feature had been reviewed.

**Five more features, built from the ideas backlog below and now shipped
and on by default:** find alerts (the K9 sits and barks on its own the
moment a search resolves, reacting differently to a big find, a small
find, or nothing — no manual trigger, no XP dependency); scent trail
hunts ("follow your nose" — a hidden spot's coordinates never leave the
server, the player only hears a growl that gets louder or quieter as they
search); pursuit sprint (a short, cooldown-gated burst of real extra speed
for a K9 chasing a wanted target, deliberately narrow — every speed
influence in this resource, breed and XP tier included, is clamped to a
combined maximum); scent lineups (a K9 invites several *consenting*
players to stand in a line; the server secretly picks one at random and
tells nobody, not even the K9, until a final guess is committed — no XP,
since the outcome is genuinely random); and search-and-rescue calls (a
hidden missing-person or lost-property target that resolves as a rescue,
never an arrest; the "missing person" is always an NPC, never a real
player who didn't agree to it). See "Ideas that became real features"
below for where these came from.

---

## Security and economy hardening

A resource with an in-game economy attracts farming attempts, and several
were found and closed during development — recorded here because the
*pattern* is worth knowing even where the specific numbers aren't:

- Several XP-farming loops were found and closed: reusing a single logged
  scent/blood/gunpowder source instead of requiring travel time, forging a
  fresh scent source by dropping and picking an item back up, re-taking
  the same Bite & Hold target the instant its cooldown cleared, and two
  separate ways to make a contraband search pay out repeatedly for a
  stash whose actual contents never changed. Each is now rationed by a
  cooldown or a "did this genuinely change" check, applied at the exact
  point XP is minted rather than somewhere upstream of it.
- A family of natives that are real and correct on the client, but simply
  don't exist on the FiveM server, were being called server-side and
  silently no-op'ing — meaning code that looked correct had been doing
  nothing since it shipped (a kennel's spawn offset, a fetch ball's throw
  force, several death checks, and a damage-suppression backstop). None
  of these were security holes; they were quiet correctness bugs, found
  by writing tests that check the *actual resulting state*, not just that
  a function was called.
- A certification-grant race, a partnership-establishment race, and a
  contraband-search race were each closed with the same shape of fix: a
  short-lived in-memory lock around the whole check-then-write sequence,
  on top of (not instead of) a database-level uniqueness constraint as
  the real backstop.
- Several "client proposes, server confirms" handshakes (fetch, kennel
  placement, prop attachment) had branches where a confirmation could be
  rejected without ever telling the client to clean up its own copy of
  the object it had already created — leaving real networked objects
  orphaned. Fixed with a shared rejection path that always pairs a
  server-side refusal with a client-side cleanup instruction.

The recurring lesson across all of these: a security or economy review
that only reads the code for what it's *supposed* to do will miss a bug
where the code does something else entirely. Everything above was found
by either tracing an actual call site to its real, current native
behavior, or by writing a test that exercises the real code path
end-to-end and checking its real output.

---

## Documentation

This resource's documentation went through two rounds of consolidation.
The first collapsed roughly twenty overlapping design/spec/status
documents down to nine (a developer reference, an operator runbook, a
player guide, a README, a changelog, an issues list, a watchdog log, an
ideas backlog, and this history). The second — reflected in what you're
reading now — went further: everything genuinely aimed at a buyer, an
operator, or a player lives in `README.md`; everything a developer
inheriting the code needs lives in `DEVELOPER_REFERENCE.md`; every open
bug, limitation, and owner decision lives in `KNOWN_ISSUES.md`; and the
narrative of how the project got here lives in this file. Nothing that
existed only to help a team of contributors keep track of their own work
in progress made the cut.

### A note on the commit history

For a stretch of this project's development, work was done by many
contributors editing one shared checkout at the same time. A batch of
commits from that period describe their own changes less precisely than
they should — not because anything shipped broken (every commit in that
run parses cleanly and passes the full lint/test suite on its own, in
isolation), but because a commit made with a broad "stage everything"
habit can end up carrying a second contributor's unrelated, half-finished
work along with the one change its message actually describes. If you're
trying to work out exactly which commit introduced a specific line,
`git log -p` or `git blame` against the actual diff is more reliable than
trusting an old commit message's summary. The habit that caused this has
since been corrected (each contributor's changes are staged into an
isolated, private index before committing, so one commit can no longer
silently absorb another's work).

---


The full per-commit accuracy record from that period is kept below
rather than discarded. Nobody needs it to use or maintain the
resource — it is here because the record of a mistake belongs with
the project that made it, not in a deleted file.

#### Per-commit accuracy record

**A** — accurate.
**B** — the headline is true, but the commit silently carries other real work, or
omits a caveat the code itself discloses.
**M** — the message describes work that is not in that commit's diff. "Landed at"
names where it really is.

| SHA | Subject | | Note |
|---|---|---|---|
| `da2fe174` | Let high command block the twelve client-only features per person | A | Wires 9 of 12 and does not overclaim the rest |
| `a259b1e5` | Add wording for a block that is real but weaker than server-enforced | A | |
| `c96629cb` | Close seven server-side per-person block gaps | A | Prose names six but says seven |
| `edadce94` | Stop teleport-biting, and stop biting people sitting in cars | A | |
| `254b47ef` | Assign tiers, renew and specialize from the tablet, on offline people too | A | |
| `0404ed56` | Stop the tablet string test crying wolf on correct work | A | |
| `2857d4ea` | Add live permission-key and XP-rank catalogs | B | Silently ships the whole feature-block push in `server/permissions.lua` |
| `63f24839` | Deliver per-person blocks to the client | M | The push half is not here. Landed at `2857d4ea`. The client listener genuinely is here |
| `5a0d1d9f` | Land eight parallel workstreams | B | Silently adds the two missing `sql/install.sql` tables and the theme-push fix |
| `9e8f141d` | Stop reporting partial database writes as success, and fix the theme push | B | Also carries scent-hunt, appearance, fetch and SAR fixes; re-describes the theme fix `5a0d1d9f` already made |
| `25fb2ff7` | Close a retry-window bypass in the anti-teleport check | B | Named claim verified genuinely closed; also carries a scent-hunt sweep and an appearance write-check |
| `1917cfff` | Add equipment shop denial messages | B | A real fix in `client/proximityaudio.lua` described as "spec and fixture work" |
| `c617165a` | Add two tables a fresh install would never have created | M | Landed at `5a0d1d9f`. This diff instead carries the shop-hook fail-closed fix, unmentioned |
| `b58fdbde` | Fix a broken test fixture and three assertions that could not fail | M | The fixture repair landed at `1917cfff` |
| `5bb63e67` | Stop the tablet telling operators a working feature does nothing | B | Main claim accurate; "the Shop Items screen landed" is a forward reference |
| `bd71a097` | Stop a revoked handler's scent hunt from locking them out permanently | M+B | Landed at `9e8f141d` and `25fb2ff7`. This diff silently ships the 630-line Shop Items screen |
| `f15f44ee` | Correct fourteen config comments | B | Silently ships `WaitForSchemaCheckToSettle()` and the self-promotion accounting |
| `8db1de60` | Close six client-side leaks and traps | M | All six landed earlier, across five commits. Zero overlap with this diff |
| `1fa8db20` | Make a staff self-promotion visible | M | Landed at `f15f44ee` |
| `7e9b4b4f` | Build the Shop Items screen | M+B | Landed at `bd71a097`. This diff instead carries the medkit cooldown fresh-read and a permission-key grant capability |
| `53e366de` | Make the shop hooks deny on error | M | Landed at `c617165a`. This diff is one test file |
| `448024fc` | Close the schema-collision boot race, and stop appearance writes claiming success | M | All four claims landed at `f15f44ee`, `25fb2ff7`, `9e8f141d`, `7e9b4b4f`. This diff is one test file |
| `3dd62a93` | Fold in the tablet server spec updates | A | |
| `278d89b8` | Let a retired permission be revoked, keep the shop alive across a toggle | A | |
| `49416ee3` | Watchdog: first recorded pass | A | |
| `cf47c677` | Land the certification and tier-catalog work that is finished | A | |
| `be230bec` | Unblock two in-flight agents | A | |
| `3ba31f32` | Carry sprint momentum through a vault | A | |
| `ffb405f6` | Make the speed boost and stamina numbers genuinely editable | B | Claim verified end to end; also carries an unrelated 289-line spec addition |
| `93395216` | Add the Commands page, close a partnership XP farm, and stop reset lying | B | See the two overstatements below. Also silently ships the per-K9 override system and a Home/branding overhaul |

**12 accurate, 9 partial, 9 mis-credited.**

Three later commits carry the same fault and are recorded here for
completeness:

- `7752daf` — message covers the licence, offline names and the issues list; also
  carries the ped third-eye icon pass, `server/k9profiles.lua` changes and two
  test fixes.
- `a383b6a` — message covers the tablet string sync; also carries the whole
  world-object third-eye pass.
- `e23d198` — message covers five pieces of work by name; also carries the
  name-resolution pass (`server/tablet.lua` and two specs), which resolves the
  granting officer's citizenid to a real character name across the audit trail
  and certification rows. That commit was made after this file first described
  the problem, which is what finally identified the shared-index cause above.

## Two claims that were overstated

**"The Commands page cannot go stale."** It can. The drift guard compares
registered commands against the page, but only across a hand-maintained list of
filenames. A new file that registers a command and is not added to that list
drifts silently. That gap was real and has since been closed for
`client/keybinds.lua`; the mechanism still depends on someone maintaining the
list.

**The partnership XP farm is "closed".** The fix was real, but for a long time
was held in memory only. A resource restart cleared it, which re-opened the
exploit once, for a pair that breaks up around that restart. The code said this
at length; the commit message did not. **Update:** now genuinely closed —
migration 0018's `k9_partnership_pair_progress` table persists the guard
across a real restart whenever the database is on, closing the gap this entry
used to disclose. Kept here anyway, unmarked as anything other than history,
as the lesson that mattered: state a fix's real scope in the commit message
itself, not only in a comment three files away.

## Ideas that became real features

A backlog of gameplay ideas was written up aimed specifically at what
makes *playing the dog* better — not the more common "officer commands a
computer-controlled dog" style of K9 script, which this resource
deliberately isn't. **All five of its top recommendations were built and,
for a time, all shipped on by default** — worth stating plainly, because the
backlog document itself was never updated to say so, and describing
shipped, working features as unbuilt ideas is exactly the kind of stale
claim this history exists to correct rather than repeat.

THREE OF THE FIVE HAVE SINCE BEEN REMOVED, and the entries below are
kept as a record of what was built rather than a description of what
runs today. Item 2 went first, on 2026-08-26 (owner-approved, judged
redundant with Detection's own "walk toward a fading signal" interaction
shape — see `docs/history/FEATURE_STRUCTURE_SPEC.md` §2.2.1/§9 and
`config.lua`'s own `Config.Features` comment for the full reasoning and
how to bring it back). Items 3 and 4 followed on 2026-09-02, at the
owner's request, along with their files, config, events and tests. Items
1 and 5 are unaffected and still ship on by default.

1. **Real alerts instead of a pop-up** → shipped as **find alerts**
   (`Config.Features.FindAlerts`). The dog sits and barks on its own the
   moment a search or trail resolves, reacting differently depending on
   what was found, reusing sounds and actions this resource already had.
2. REMOVED 2026-08-26. **"Follow your nose"** → shipped as **scent trail hunts**
   (`Config.Features.ScentTrailHunt`). A handler marks a search area; the
   hidden coordinates never leave the server, and the K9 player is only
   ever told how far away they are, which paces a growl that gets louder
   or quieter as they search — there is nothing in the player's own game
   to read the answer out of.
3. REMOVED 2026-09-02. **Missing-person / search-and-rescue calls** →
   shipped as **search and rescue calls** (`Config.Features.SARCalls`). Same hidden-target,
   growl-paced hunt as above, resolving as a rescue rather than an arrest.
   The target is always an NPC that only appears once the call is already
   solved — never a real player who didn't agree to be found.
4. REMOVED 2026-09-02. **Scent lineup** → shipped as **scent lineups**
   (`Config.Features.ScentLineup`). A K9 invites several players to stand
   in a line; every one of them has to explicitly accept. The server
   secretly picks one at random and tells nobody — not even the K9 running
   the drill — until a final guess is committed. No XP is awarded, since
   the outcome is genuinely random and could otherwise be farmed.
5. **Pursuit sprint** → shipped as **pursuit sprint**
   (`Config.Features.PursuitSprint`). A short, cooldown-gated burst of real
   extra speed for a certified K9 chasing a wanted target only. Every
   speed influence in this resource — breed, XP tier, fatigue, and this
   burst — is clamped to a combined maximum, so it can't stack into
   something escape-proof.

**Considered and deliberately not built: crowd-control barking** (a real,
historical police K9 use — bark/lunge at a crowd to disperse it). Left out
for two reasons: the real-world history behind it is genuinely dark, not
just old-fashioned, and it doesn't clear the design bar either — it would
need to affect other players who never consented to it, the same pattern
this resource already treats as its riskiest, least-resolved area in the
existing combat features.

None of the five shipped ideas require any other specific server resource
to exist — dispatch/record-system integration, if ever added, should be
an optional bonus layered on top, not something the feature breaks
without. The original research notes (real K9 procedure, other "play as
an animal" games, and the specific natives involved) cited a number of
external sources; they're preserved in this project's git history if
anyone wants to revisit them, rather than reproduced here.

## The NPC dog, considered and rejected

2026-08-26. A competitive research pass established, with citations, that
every high-adoption K9 script on the FiveM market is NPC-based: the dog is
AI, and one officer commands it. Mato-K9, ND-K9, EVO K9, Big Daddy, Quasar
and the long-running free release thread are all that shape. This resource
is the other kind — a real player becomes the dog — and a genuine but
smaller player-controlled niche exists alongside it (v-k9, UN K9 System,
Reborn's "Police K9 Player", IIS K9 Policer, and mana_policedogs, which is
the closest direct competitor by design).

The obvious commercial argument was put plainly: requiring a second human
to log in as the dog is a hard ceiling. A server that cannot staff that
gets nothing from any of the 58 features, however deep they are. The
research recommended adding an NPC fallback mode alongside the player one,
so a server could run either.

**The owner's decision was no.** Player-controlled only. Recorded here so
nobody re-opens it as though it were an oversight.

The reasoning that supports the decision, for whoever reads this next:

- Nearly every system here exists BECAUSE there is a real person on the
  other end. Handler partnership and its tenure bonus, the mood, fear and
  distraction systems, the partner camera feed — an NPC has no relationship
  to form, no nerve to lose, and no viewpoint to switch to. Those are not
  features that would degrade in an NPC mode; they are features that would
  become meaningless.
- The dominant complaint history for NPC K9 scripts is pathing and AI
  failure: the dog freezing near other players, following the wrong person,
  stopping halfway through a chase, going unresponsive after its handler
  dies. A player-controlled dog cannot have that class of bug at all,
  because there is no navmesh AI to break. That is a real engineering
  advantage, not a marketing line.
- An NPC mode is not a toggle. It is a second implementation of search,
  tracking, apprehension and agility running in parallel to the existing
  ones, and it would inherit exactly the bug class above. Built badly it
  would cost more in support than the two-player ceiling costs in sales.

What was NOT decided, and remains open: the ceiling is real. If it is ever
felt, the answer is more autonomous content for a dog whose handler is
busy — Scent Trail Hunt, Scent Lineup and SAR Calls already exist for
precisely that reason and should be protected as such rather than treated
as filler.

## Watchdog passes

A scheduled check runs over this resource periodically, looking for
regressions in things already fixed and for claims in the documentation
that have quietly stopped being true. Each pass is one line here, so the
next one knows what was already covered. There is deliberately no
separate log file — this is the one place project history lives.

- **2026-08-26** — Clean, with two findings, neither a regression. All
  185 Lua files pass a syntax check; all three gates green. Re-checked
  five previously-fixed items and all five are still in place: the basic
  jump setting is still read in client/movement.lua, leash pairings still
  record which side is the dog, revoking an offline handler's
  certification still refreshes the cache, the vehicle cleanup on
  resource stop still exists, and the radial menu still registers its
  menus and its opener item separately. Dependencies re-checked because
  an earlier audit had flagged their maintenance status as an open
  question: ox_lib is confirmed actively maintained (last change
  2026-08-17, not archived); oxmysql and ox_target show no archive
  notice and normal issue activity. The two findings: the bark audio
  files are real audio now, so html/sounds/CREDITS.md claiming none were
  ever written is stale; and the uninstall script drops this resource's
  tables by name without checking they are actually ours first, which is
  the one place in this resource where a mistake destroys data instead
  of refusing. Both assigned.

- **2026-08-26 (issue-closer sweep)** — Whole-project sweep for flagged
  items never closed out. Closed: the partnership tenure-bonus anti-farm
  guard is now genuinely restart-proof (migration 0018,
  `k9_partnership_pair_progress` — see "Two claims that were overstated"
  and `KNOWN_ISSUES.md`'s "Fixed" section for the full writeup); six stale
  `phase2_notes/...` citations in `sql/install.sql` and `.luacheckrc` (dead
  since the phase-notes merge into `DEVELOPER_REFERENCE.md`) now point at
  the real file and anchor, with the dead sub-section numbers dropped.
  Documented, not coded: `LICENSE.md` §9's dependency-licence identifiers
  are now independently verified against each project's own repository
  (`ox_lib`/`oxmysql` LGPLv3, `ox_inventory` GPLv3, `ox_target` MIT,
  `qbx_core`'s own `LICENSE` file crediting an ESX ancestor rather than
  Qbox-project) — the legal question of whether any of that copyleft
  reaches this Software across FiveM's export boundary is still,
  correctly, left for a lawyer. `LICENSE.md`'s three governing-law/venue/
  contact-address placeholders and the logo placeholder both cross-linked
  into `KNOWN_ISSUES.md` for visibility, not otherwise touched — both are
  the owner's call, not a code fix. Left open, not attempted: wiring
  `handlerTreatK9`/`handlerKennelDeploy`'s per-actor XP mint cooldowns —
  a live concurrent pass was already mid-way through the adjacent
  `handlerCertifyK9` farm-loop fix in the exact same `config.lua` comment
  block and using the exact same mechanism, so this was left for that
  pass rather than risking a duplicate or conflicting edit.
