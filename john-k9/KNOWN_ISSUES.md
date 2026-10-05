# Known Issues

This is the one place bugs, limitations, and open decisions for
`john-k9` are recorded. Every item below has been checked against the
current code, not carried over from an old note — where something couldn't
be confirmed, that's said plainly instead of guessed at.

This file is not the changelog (see `PROJECT_HISTORY.md` for what happened
and when) and not the reference manual (see `README.md` for install/config,
`DEVELOPER_REFERENCE.md` for internals). It's the honest "here's what's
still rough" list.

---

## 1. Decisions that need the resource owner

Three things genuinely need a decision from whoever runs this server,
rather than more code. All three are about features that ship **on** in
the default config, so they're live today, not hypothetical.

### Is the bite/takedown trust boundary good enough?

Three features — Bite & Hold, Non-Lethal Takedown, and Prop Dragging — are
protected against a player running a modified game client by a guard that
checks where the instruction came from (the server only honors an event
that genuinely came from itself, never one a local client faked). The
guard is written and has been reviewed, but nobody has ever actually
attacked it on a running server, which is the only way to know for certain
it holds. All three features ship **on**.

Options: run a live test (someone deliberately trying to break it), accept
the risk as-is, or switch these three off until it's been tested.

### The fear/stress griefing tradeoff

The K9 Fear/Stress system is on by default, and a player can repeatedly
send a fake "there's gunfire nearby" signal to force someone else's K9
into a temporary refusal state (it won't bite or take down a suspect for
about a minute) — repeatably, at no cost to the person doing it. A single
episode can no longer last forever (it resets after roughly a minute), but
the *repeatable* part can't be closed in code: there's no way to verify
who actually fired a shot, the same tradeoff already accepted for scent
tracking.

This is a call about the kind of server you want to run, not a bug: some
servers want the emergent chaos of an unreliable K9 under fire, others
don't. Leave it on, turn it off, or ask for the cooldowns to be tightened
further.

### The framework-conversion decision

Auto-detection genuinely works for **inventory** and **targeting** — change
either script on your server and this resource adapts. It does **not**
work for the underlying framework, and that's worth being direct about:
adapters exist for `qb-core` and ESX, but only one file in the entire
resource actually uses them. Everything else — certifications,
permissions, the tablet, XP, combat — calls Qbox (`qbx_core`) directly.
The count of direct call sites depends on exactly how you count (grepping
production files outside the compat layer gives numbers from the mid-160s
to the mid-180s depending on what's excluded), but the substance is not in
doubt: it's a large majority of the codebase. `qbx_core` is also a hard
dependency in the manifest, so the resource will not start without it
regardless of what's detected.

If you run `qb-core` or ESX, detection will correctly identify it and the
resource will still not work.

Two honest options: **say so plainly** wherever this gets documented
(cheap, and the current recommendation), or **commit to converting those
call sites to go through the existing adapters** — a large job, not a
quick fix.

### Three blanks in LICENSE.md that only you can fill in

`LICENSE.md` §12 and §14 ship with three placeholders, deliberately left
blank rather than guessed at: **governing law** (which country/state's
law a dispute over this licence would be judged under), **venue** (which
court a dispute would actually be brought in), and a **contact address**
for licence questions and legal notices (including DMCA counter-notices).
None of these are code changes — they're one-sitting decisions that need
your own answer, then a lawyer's confirmation that the wording holds up:

- **Governing law** — without it, a court would fall back to its own
  jurisdiction's conflict-of-laws rules to work out which law applies,
  which is exactly the uncertainty naming one removes. Usually: wherever
  you (the Licensor) are based, or wherever you'd want to have to fight a
  dispute.
- **Venue** — a separate question from governing law: even once you know
  *which* law applies, you still need to say *where* (which city's/
  country's courts) a case would actually be heard. Matters practically
  because it decides how far you — or someone infringing your licence —
  has to travel to show up.
- **Contact address** — where someone sends a licensing question, an
  additional-server request, or a takedown counter-notice. Needs to be an
  address you'll actually check, since §12 makes it the official channel
  for legal notices.

See LICENSE.md's own notice at the top and §14 for the exact placeholder
text and more detail. Not legal advice, and not resolved by more code —
these three lines are the entire remaining gap between this document and
one a lawyer could sign off on.

### An unconfirmed dependency-licence question, now with real facts attached

This resource depends on five other FiveM resources it does not ship code
from (`qbx_core`, `ox_lib`, `ox_target`, `oxmysql`, `ox_inventory`).
LICENSE.md §9 now records, checked directly against each project's own
repository (2026-08-26): `ox_lib` and `oxmysql` ship under the GNU Lesser
General Public License v3 (LGPLv3); `ox_inventory` ships under the
stronger, non-"Lesser" GNU General Public License v3 (GPLv3); `ox_target`
ships under the MIT License; and `qbx_core`'s own `LICENSE` file is the
full GPLv3 text, but headed with a copyright line crediting it to
"es_extended — ESX framework for FiveM" (an ancestor project this
framework forked from), not to Qbox-project itself — genuinely unclear
whether that's an intentional licensing statement for qbx_core's current
code or an inherited artifact nobody updated.

**The facts are now established; the legal question is not, and isn't
answered here on purpose:** does any of these copyleft terms — LGPLv3's
weaker one, or GPLv3's stronger one — reach across FiveM's
`fxmanifest.lua`-dependency/export boundary into this Software's own
proprietary code? That's a real question for a lawyer familiar with both
software licensing and how FiveM resources actually interoperate at
runtime (shared-process Lua scripts calling each other's exports, not
statically linked or compiled together) — not one this project is
positioned to guess at. See LICENSE.md §9 for the full table of sources
and citations.

---

## 2. Open bugs and limitations

Things that are either genuinely broken in a narrow way, or work as
designed but have an edge worth knowing about before you rely on them.


- **High command can now grant almost anything to themselves, by owner
  decision, not a bug.** A high-command officer can self-grant a
  feature-control permission, a `block.<Name>` entry, one of the four
  named capabilities (`k9.access`/`k9.certify`/`k9.audit`/`k9.givexp`), or
  an XP award — all governed by two config switches
  (`Config.FeatureControl.allowHighCommandSelfGrant` and
  `Config.HighCommand.allowSelfGrant`), both defaulting `true`. This
  intentionally removes the "someone else has to witness this" property a
  self-grant used to lack. Every self-grant is still fully audited and
  explicitly marked as a self-grant (the log line names the same citizenid
  as both granter and recipient, not disguised as an ordinary grant) — set
  either switch to `false` if you'd rather require a second high-command
  officer's action, including for a lone owner's own account.

- **A dragged player can always let go by force.** Prop Dragging's attach
  is real (it's re-applied every tick specifically so this can't be
  trivially defeated), but nothing stops a dragged player's own client
  from detaching itself at any moment — that's a property of how FiveM's
  networking model works, not something this resource can close. There's
  a hard maximum drag distance and duration as the real backstop.

- **Client-relayed combat effects: re-checked after a real second look —
  only the visible restraint on a PLAYER target is unenforceable, not the
  decision to grant it, and the practical exposure is narrower than "trust
  boundary gap" suggests.** Precise scope, traced against the actual code:
  *whether* a Bite & Hold, Non-Lethal Takedown, or drag is granted at all —
  K9 access, per-person feature grants/blocks, certification-tier
  capability, an anti-teleport speed check against independently-sampled
  server-side position history, live server-measured proximity, target
  liveness, a vehicle-seated exclusion (checked at grant time AND
  re-checked continuously for the life of the hold), the target's wanted
  status, and every cooldown (per-K9 and per-target on all three, plus a
  separate flat XP-mint cooldown on the two that actually pay XP — dragging
  awards none, so it has none) — is decided and re-verified by the server
  alone;
  none of it is ever taken on a client's word. The one piece that genuinely
  is client-relayed is the *mechanical* effect on a PLAYER target's own
  screen (`DisableControlAction` during a bite hold, `SetPedToRagdollWithFall`/
  `SetEntityCanBeDamaged` during a takedown, `SetPedMoveRateOverride` while
  dragged) — that code runs on the target's own client, and a modified
  client can simply not run it. There is no way to force another player's
  client to do anything; that is a property of FiveM's own peer-ownership
  networking model, the identical limit already documented above for Prop
  Dragging's self-detach, not a gap in this file's own checks. An NPC
  target is not exposed by this at all — an NPC has no "own client" to lie
  to; the requesting K9's own already-trusted client drives an NPC's
  suppression directly.

  What a cheater running the modified client actually gains: the ability
  to make a restraint on **themselves** cosmetic and keep moving, fighting,
  or fleeing despite an active hold — nothing more. It does not let them
  affect anyone else, and this resource has no arrest/evidence workflow of
  its own wired to "did the effect visibly land" — XP is the only reward
  this file grants, and it is timed and gated independently of compliance
  (a minimum held-duration floor, a per-target cooldown, a per-holder
  cooldown, and a separate flat per-holder XP-mint cooldown, all already
  hardened against exactly this class of farming). A non-compliant or even
  actively-colluding target does not raise that ceiling above what an
  honestly-compliant one already allows, so this is not a new exploit on
  top of the one already priced into this resource's own XP-economy audit
  — it is the same ceiling, reached a different way. Non-compliance
  detection (`Config.Combat.NonComplianceDetection`, **off by default**)
  samples the target's own server-read position and only ever logs or
  notifies staff — deliberately never auto-punishes, since a false
  positive here is lag or desync, not proof.

  Ranked plainly: the real cost is an evading suspect, not a compromised
  server-authoritative outcome — closer in kind to "a dragged player can
  always let go by force" two entries above than to an actual trust-boundary
  hole. There is nothing left to harden on the request-granting side (it is
  already this thorough); the only way to truly force a player's own ped
  state would be a real redesign this resource does not have today — a
  third client, already positioned near both peds, corroborating the effect
  from outside, the same shape already ruled out below for the
  line-of-sight gap, for the same reason (no single participant's own claim
  can be trusted). Accepted as-is; not a decision this note is asking for.

- **Bite & Hold, Non-Lethal Takedown, and Prop Dragging have no
  line-of-sight check at all.** A K9 within range on the far side of a thin
  wall or door can start any of the three exactly as if standing in the
  open — confirmed, not assumed: FXServer loads no collision/physics world
  server-side, so there is nothing to query even in principle (checked
  directly against the game server's own native-registration source, not
  inferred from a missing doc page). A client-reported "I have line of
  sight" flag was deliberately not added as a stand-in: the one client with
  an incentive to lie about it (the K9's own) could simply always claim
  true, which would look fixed on the next read while adding zero real
  protection. The only shape that could genuinely close this is a third
  client, already positioned near both peds, corroborating the check from
  outside — a materially larger design, not a narrow fix, and out of scope
  here. Every other check (distance, access, cooldowns, wanted status,
  vehicle exclusion) is unaffected and still applies in full; this is
  specifically the missing line-of-sight leg, previously disclosed only in
  `server/combat.lua`'s own header, not here.

- **Five of the eight inventory scripts this resource recognizes are paid
  scripts with no readable source.** They're listed in the compatibility
  layer but stay inert, and the console says why rather than pretending
  to support them. Confirming any of the five would need a live install to
  test against, not more reading.

- **The tenure check does a small lookup every five minutes for
  every fully-tenured partnership**, rather than skipping it entirely.
  This is deliberate and tested — the alternative (a cache that could go
  stale relative to a broken partnership) was judged the worse tradeoff.
  Not something to "optimize" without re-reading why first.

  *Reworded from "runs a small database query": it goes through
  `K9Store.Partner_GetTenureRow`, so on the shipped configuration
  (`Config.Database.enabled = false`) it is a plain in-memory table read
  and touches no database at all. It only becomes a real query on a server
  that has turned persistence on.*

- **Every XP anti-farm cooldown in this resource lives in memory only, so
  restarting the resource (or the whole server) resets all of them at
  once.** Confirmed by reading each one directly: the per-person cooldowns
  behind treating your dog and deploying the kennel (the two Master
  Handler awards described above), behind personally certifying someone,
  behind the co-op search bonus, and the shared hourly XP budget every
  mechanic in this resource draws from — all of them are plain in-memory
  trackers with no database backing, and `server/certifications/`'s own
  comment on its certification cooldown already calls this out by name as
  an accepted, deliberate gap. **This is not something a player can
  trigger** — it takes an admin actually restarting the resource or the
  server. The practical effect is narrow: a handler who was, say, 20
  minutes into a 30-minute cooldown gets it cleared early by a restart,
  so an owner who restarts very often is quietly a little more generous
  with XP than the stated hourly ceilings promise. Not a security hole,
  just worth knowing if your ceilings need to be exact.

  *Smaller than it reads on the shipped configuration. With
  `Config.Database.enabled = false` (the default) the XP TOTALS reset on
  restart too, so a cleared cooldown cannot help anyone accumulate past a
  ceiling — there is no surviving total to accumulate into. The concern
  above is really about a server that has turned persistence on, where the
  totals survive a restart and the cooldowns guarding them do not.*

- **`html/images/logo.png` is a placeholder, not a real logo.** It's a
  plain crimson circle on a near-black background — matched to the
  shipped theme colours so nothing looks broken, but not an actual
  Crimson Roleplay logo/crest. Replacing it is the one step needed (save
  your own square, e.g. 512x512 or 1024x1024, image over that exact file);
  `config.lua`'s own `Config.CommandTablet.branding` block, right next to
  where you'd set your server name, documents the full "what image to
  use" / "what not to use" contract already — nothing else in this
  section needs to change to pick it up.
- **`Config.Features.BoneSweepDevTool` looks more alarming than it is.**
  Its own comment says never to enable it on a production server, and it's
  `true` in the shipped config — but that flag alone does nothing. The
  `/k9bonetool` command only registers if you've *also* explicitly set
  `john_k9_enable_bone_dev_tool 1` in your server config, which defaults
  off. If you've never heard of that convar, this tool isn't running on
  your server.

---

## 3. Fixed — worth remembering

- **The tablet's "Commands" reference page could silently go out of
  date.** Two specs compared every real, registered command against what
  the tablet documents — but each did it against a *hand-maintained list of
  filenames* rather than the real folders, so a new file registering a
  command was invisible to them: the command would work in-game, never show
  up on the tablet, and nothing would warn you. The lists had already
  drifted repeatedly -- several files were each found missing after the
  fact. Both specs now enumerate
  `server/*.lua` and `client/*.lua` from disk, so a new file is covered the
  moment it exists. Verified by dropping a throwaway file that registers an
  undocumented command into each folder and watching both guards name it.

  Two things worth keeping from the fix. The old justification — "this
  plain-Lua suite has no directory-listing primitive anywhere, by design" —
  had stopped being true; two other specs already enumerate files with
  `io.popen`. And the old header's reassurance that a missing file could
  only cause a *loud* "documented but not real" failure was backwards: an
  unlisted file has its commands never discovered at all, so a real command
  with no documentation is exactly what went unnoticed.

  Removing the blindfold immediately surfaced one command the guard had
  never seen — `/k9debug`, which is registered dynamically because its
  switch (`Config.DebugDump.enabled`) is not a `Config.Features` key. The
  code was right; it is now exempted deliberately and in writing, rather
  than being invisible.

Kept short on purpose. These aren't a changelog entry each — they're here
because each one taught a rule worth not re-learning.

- **The top handler rank (Master Handler) used to be effectively out of
  reach for anyone who never personally certified a new handler.** Two of
  the six actions that were supposed to pay handler XP — treating your own
  dog and deploying the kennel — were configured but never actually paid
  out, because paying them without a farming guard would have made XP
  mintable at thousands per hour. Both now pay: treating your dog is
  capped at 24 XP per hour per person, deploying the kennel at 8 XP per
  hour per person, 32 XP per hour combined, each behind its own per-person
  cooldown that survives a disconnect/reconnect rather than resetting. A
  handler on ordinary duty now reaches Master Handler in roughly a week
  instead of never.
- **A file that isn't registered in `fxmanifest.lua` never loads, and
  nothing in the toolchain catches it.** This has happened five separate
  times — a file written, tested, and silently never running in-game.
  Register a new file in the same change that adds it.
- **Setting a cooldown to `0` used to disable the feature it belonged to,
  permanently, instead of meaning "no cooldown."** Zero reads as "off" in
  most other scripts, so it was the most likely value an operator would
  try. Cooldown construction now warns loudly and falls back to a safe
  default instead of silently bricking a feature.
- **Decertifying someone mid-hold used to leave their dog still holding
  the suspect** for up to twenty seconds — leash and partnership were both
  released on revoke, the active hold wasn't. Fixed; the rule now is to
  check every related state, not just the ones that come to mind first.
- **The uninstall script had a one-character shell quoting bug that
  stopped it from ever completing** (backups still ran fine, so nothing
  was ever at risk, but the actual removal step never worked).
- **Two things written off as "impossible" on a competing inventory script
  were not.** qb-inventory's scent-tracking and vehicle-search support
  were documented as permanent gaps; re-reading that project's actual
  source found both were achievable, and both now work.
- **A dependency was reported as abandoned that wasn't.** An archived fork
  was mistaken for the real, actively-maintained project. Always check the
  actual repository the manifest names, not a search result about it.
- **Two K9s could partner with each other**, with one silently and
  incorrectly treated as the "handler" side. Partnering now requires an
  actual K9 and an actual handler on the two ends.
- **The partnership tenure-bonus anti-farm guard used to be in-memory
  only.** Two K9s partnering, breaking up, and re-partnering repeatedly
  used to farm XP; that was fixed, but the fix lived in a table that reset
  on every resource restart, re-opening the exploit once per pair around
  each restart. Now backed by a real database table
  (`k9_partnership_pair_progress`, migration 0018) keyed by the exact
  (K9, handler) pair rather than by any one partnership row, so it
  survives both a break/reform cycle and a genuine resource restart
  whenever the database is on — installs running with the database off
  keep the previous, disclosed, running-uptime-only protection, since
  there's no real database standing behind them to persist to.
- **A config comment said a contraband screen effect applied to the
  searched person's screen.** It always applied to the searching officer's
  own screen, as feedback — the code was right, the comment wasn't.
- **Certification tier capabilities now actually gate something.** They
  used to be a control panel wired to nothing; they now gate granting a
  specialization and the three combat abilities. If the capability lookup
  itself can't answer, the action is allowed rather than refused — a
  deliberate choice, since a permission system that can lock out an entire
  department because of a lookup hiccup is worse than one that occasionally
  lets something through.
- **Looking up another handler's record now requires high command, or an
  explicit audit grant** — ordinary certification alone no longer lets a
  handler enumerate everyone else's permissions. Everyone can still see
  their own record.
- **New installs get a consistent database character encoding**; existing
  installs get an optional, non-mandatory migration for it, kept out of
  the automatic upgrade path since it rewrites potentially very large
  tables for a cosmetic fix.
- **A K9 played on a human body (or any custom ped) now works properly.**
  It keeps jump and crouch, and — as of a later fix — gets the same
  fatigue penalty a dog-modeled K9 gets, closing a gap where "everything
  works with any ped" quietly didn't apply to the wellbeing system.
- **The Audit tab used to be permanently unreachable on the single most
  common server setup: exactly one high-command officer, day one.** The
  permission it needs could only be granted by high command, and
  self-granting was blocked outright — so a lone owner had no path to it
  at all. High command can now grant themselves that specific permission,
  which is on by default (see "High command can now grant almost anything
  to themselves," above, for how far that now extends). If you
  deliberately want a second officer's sign-off before anyone gets that
  access, there's a config switch to turn this back off.
- **`RenewCertification` used to report a renewal succeeded even when its
  own UPDATE matched zero rows.** It checked whether the write *threw an
  error*, never whether it actually matched a row — a certification
  revoked or changed in the moment between an officer starting a renewal
  and the write completing could report success and notify both people
  even though nothing was actually renewed. Same shape as the
  `SetCertificationTier` fix above it in this file, mirrored here and in
  its offline counterpart (`RenewCertificationOffline`): both now check
  the affected-row count, and reconcile a *thrown* write against a fresh
  DB read (comparing the new expiry against the pre-write one, since a
  renewal extends a value rather than setting a fixed target) before ever
  reporting an outcome — never a guessed success, and never a false
  failure when the write actually landed.
- **A K9/handler partnership's client-side status used to lag after a
  reconnect with no way for a caller to force a fresh answer.** The
  server's own record was always correct; a reconnecting client's local
  cache could read "not partnered" for a genuinely still-partnered player
  until a fresh Partner Up/consent event happened to arrive. Closed by a
  server-authoritative `john-k9:server:getPartnershipState` callback
  and a client-side `RefreshPartnershipStateFromServer()` wrapper around
  it — every consequential decision point (the radial menu's Partner
  Up/Break Partnership choice, starting a partner camera feed) now
  re-verifies against the server before acting, instead of trusting the
  local cache cold. The cheap, synchronous `IsPartnered()`/
  `GetPartnerServerId()` reads themselves are unchanged by design (no
  round trip on every call) and remain a display-only convenience for
  callers that already tolerate a bounded, server-corrected "already
  partnered"/"not partnered" rejection either way — not a caller that
  needs a live answer, which must call the refresh function first.
- **Pursuit sprint's cooldown used to reset on disconnect/reconnect** — and
  an earlier pass at this entry overstated why that mattered before this
  one narrowed it back down, so both drafts are worth being honest about.
  The cooldown was keyed by the player's numeric server id and cleared via
  a `playerDropped` handler; reconnecting always produced a fresh id with no
  cooldown history. For the mechanic's own stated purpose — a burst that
  ends a foot chase already going the K9's way — this bought almost
  nothing: the request handler re-checks live proximity and re-resolves the
  target on every attempt regardless of cooldown state, and a suspect who
  is genuinely fleeing will be out of range or gone by the time anyone
  reconnects. The real gap was narrower and different: a **stationary or
  engaged target** — cornered, mid-shootout, downed-but-not-arrested,
  anyone who stays in range and wanted for well over the cooldown's own
  length. Nothing else in this mechanic limited re-bursting against that
  same target faster than this one cooldown, unlike its closest siblings:
  Bite & Hold/Non-Lethal Takedown each have an independent per-target
  cooldown behind their per-K9 one, and the XP-mint cooldowns are all
  backstopped by the shared, citizenid-keyed XP budget — both already
  immune to a reconnect for the identical reason. Pursuit sprint had no
  second gate, so it's now keyed by citizenid (never a server id, which
  never survives a reconnect) and cleaned up by a periodic sweep instead of
  the connection-drop handler — same fix shape this resource already uses
  for every other cooldown keyed by something other than a live connection.
