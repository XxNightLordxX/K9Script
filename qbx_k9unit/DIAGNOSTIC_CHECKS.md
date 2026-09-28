# Diagnostic Checks — a catalogue mined from this project's own history

> **A NOTE ON THE `file.lua:123` REFERENCES BELOW — READ BEFORE FOLLOWING ONE.**
> The line numbers are **historical and no longer reliable.** They were
> accurate when written; the files have since grown by hundreds of lines
> and every one checked during a later audit pointed at the wrong place.
>
> They fail in the worst way available: not by pointing past the end of a
> file, which would be obvious, but by landing on real, plausible-looking
> code that simply is not the code meant.
>
> **Search by the NAME instead** — the function, config key or table named
> alongside each citation is stable and greppable, and is what the citation
> is really identifying. The numbers are left in place rather than
> renumbered because renumbering buys nothing: the next edit to any of
> these files invalidates them all again, and a fresh set of wrong numbers
> is worse than an admitted set of wrong ones.


This file is input for whoever builds `server/diagnostics.lua` /
`client/diagnostics.lua`. It is not a generic "is the server healthy"
checklist. Every check below is either (a) tied to a bug that actually
shipped in this resource — cited by commit, file, or `KNOWN_ISSUES.md`
entry — or (b) explicitly marked speculative because I could not tie it to
a real failure. The goal is a command the owner runs when something feels
wrong, that names the *actual* shape of wrong things this project has
produced before, not a database ping.

Every grep-based check below was hand-verified by opening the file, not
trusted from a match count — this codebase's own comments quote call
shapes and marker words in prose specifically to explain past bugs, and a
bare count over those comments has already produced false regressions
twice in this project's own `WATCHDOG_LOG.md` (the radial-menu call count,
and the `RegisterCommand('...')` doc-comment that fooled two drift guards
on 2026-08-27). Any implementation of a text-scanning check below must
exclude comment lines and match on the real call shape, not a substring.

If only ten of these get built, build the ones marked **[TOP 10]**, in the
order they appear.

---

## Section A — Re-surface checks that already exist but only fire once, at boot, to a console nobody is watching

This is the single highest-value, lowest-risk thing `debugdump` can do.
This project has independently built at least four real, working,
well-tested diagnostic checks — and every one of them only ever runs once
at `onResourceStart` and prints to the server console. The owner is
non-technical and tests on a live server; he is never going to be tailing
console output at the exact second the resource boots. These checks are
not hypothetical value — they are proven, they already caught real bugs
in this project's own history, and they are currently invisible to the
one person they're for. Re-running/re-reading them on demand costs almost
nothing and has near-zero false-positive risk, because the logic is
already written and tested.

### A1. Config.Features vs Config.FeatureGroups disagreement [TOP 10]
- **What it detects, in plain English:** "You changed a setting in
  `config.lua`, but it's not actually taking effect, because a second
  place in the same file is overriding it without telling you."
- **The real bug it comes from:** commit `8240608` ("Turn the handler rank
  ladder on -- it was minting nothing at all"): flipping
  `Config.Features.HandlerXP` to `true` did nothing, because
  `Config.FeatureGroups` is resolved *after* `Config.Features` and
  silently overrides it — "the value went true and came back out false
  with no error anywhere." Commit `c874cc1` independently hit the same
  shape on another switch: "All three places that have to agree for a
  setting to take effect now carry it, because two of them silently
  override the first and one alone does nothing".
- **How to detect it, concretely:** `config.lua` already keeps the
  pre-override snapshot on a real global: `Config.FeaturesBeforeGrouping`
  (set once, in `ResolveFeatureGroups()`, `config.lua:1118` onward — see
  the doc comment directly above it). At any time, for every key `k` in
  `Config.Features`, compare `Config.FeaturesBeforeGrouping[k]` (what the
  flat switch says) against `Config.Features[k]` (what's actually in
  effect right now). Any key where they differ is a live, current
  disagreement — this is exactly the condition `ReportFlatGroupedDisagreement`
  (`config.lua`, right above `ResolveFeatureGroups`) already builds a
  human-readable sentence for; reuse that sentence-building logic rather
  than re-inventing the wording.
- **Tier:** FINDING. If the two values differ, the flat switch is not in
  effect — that is not a judgment call, it is what the code itself does.
- **False-positive risk:** effectively none. This is a direct read of two
  already-existing globals, not a heuristic — if they don't have to
  disagree, and they do, the resource really is using the grouped value.

### A2. Runtime tablet overrides silently outliving a config.lua edit [TOP 10]
- **What it detects, in plain English:** "You edited a setting in
  `config.lua` and restarted, but it's still not changing anything —
  because someone (possibly you) changed it from the in-game tablet
  earlier, and a tablet change always wins until it's reset from the
  tablet."
- **The real bug it comes from:** not a bug exactly, but a real, disclosed
  trap: `server/runtimecontrol.lua`'s own `onResourceStart` handler already
  computes a `clobbered` list (around line 2494) and prints, once, at
  boot: *"HEADS UP -- N of those override(s) DISAGREE with what config.lua
  currently says... your edit is NOT in effect."* (`server/runtimecontrol.lua:2650`).
  This is the exact mechanism KNOWN_ISSUES and CHANGELOG both call out
  ("the startup log names which of your config.lua edits are being
  overridden... instead of printing a count").
- **How to detect it, concretely:** re-run the same comparison this
  boot-time code already does — for every row in `ActiveOverrides`
  (module-local in `server/runtimecontrol.lua`, or the equivalent DB table
  `k9_tablet_runtime_overrides`/whatever `K9Store` calls it), compare the
  stored `value` against what `config.lua` currently says for that key.
  If the diagnostic command runs in a separate file, it will need either
  an export added to `server/runtimecontrol.lua` or to re-query the same
  DB table directly — flag this as an implementation dependency between
  the two writer agents.
- **Tier:** FINDING. Same reasoning as A1 — this is a factual read of two
  known values, not a guess.
- **False-positive risk:** none — a tablet override is *supposed* to win;
  the point is only to make the current, factual state visible on demand
  instead of only in a boot log line the owner never sees.

### A3. Database schema state: is any table currently running memory-only? [TOP 10]
- **What it detects, in plain English:** "Something you set — a dog's
  stamina, a pinned dog, XP, whatever — isn't surviving a server restart,
  and here's exactly why: this specific table isn't in your database, so
  this specific feature can't save anything, even though everything else
  looks fine."
- **The real bug it comes from:** this exact failure shape shipped at
  least three separate times and is the single most common "why did my
  setting revert" complaint pattern in this project's history: the
  pinned-dog table never created on a fresh install (commit `d08fe8a`,
  "Create the pinned-dog table on a fresh install, where it was never
  created" — "Every /k9setdog runs a real query against a table that is
  not there, fails, and reports a generic database error that points at
  nothing"), the stamina column missing until migration 0021 (commit
  `c938c42`), and the wellbeing/condition table not wired until commit
  `66b70f7`. `server/datastore.lua`'s own "SCHEMA COLLISION SAFETY NET"
  (around line 3969, `VerifyTableShapesAgainstKnownSchema`) already
  detects exactly this at boot and sets `SCHEMA_COLLISION_DETECTED`
  (whole-resource) and `TABLE_MISSING_THIS_SESSION[tableName]` (per-table)
  — then prints it once and never again.
- **How to detect it, concretely:** read `TABLE_MISSING_THIS_SESSION` and
  `SCHEMA_COLLISION_DETECTED` (both module-locals in
  `server/datastore.lua` — will need an export or a debugdump-specific
  accessor added). Report, in plain English per KNOWN_ISSUES' own model:
  which named features are currently running in memory-only mode and will
  lose their data on the next restart, and whether that's because a table
  is simply missing (owner needs to run migrations) versus a genuine name
  collision with another resource (owner needs to rename/remove the other
  resource's table).
- **Tier:** FINDING. This is a direct, factual read of a flag this
  resource already computed for exactly this purpose.
- **False-positive risk:** none for the flag itself. The only risk is
  under-explaining *why* a table is missing (partial install vs. genuine
  collision) — reuse the existing message text in `server/datastore.lua`
  rather than writing new wording, since that text has already been
  reviewed for owner-facing clarity.

### A4. Dependency version / native-name check re-surfaced [WORTH CHECKING]
- **What it detects, in plain English:** "One of the other scripts this
  resource depends on (`ox_lib`, `ox_target`, `oxmysql`, `qbx_core`) is
  older than the version this was tested against, which can cause odd,
  hard-to-explain behavior."
- **The real bug it comes from:** `server/diagnostics.lua`'s own header
  ("PART 1 -- DEPENDENCY VERSION CHECK") — written specifically because
  "A server running an older dependency got no warning at all; just
  divergent behaviour somewhere downstream, later, with nothing pointing
  at the cause." This is a real, tested mechanism (`tests/diagnostics_selfcheck_spec.lua`),
  again boot-time-only.
- **How to detect it, concretely:** call the same `K9SelfCheck` functions
  (`ParseSemver`/`CompareSemver`, `server/diagnostics.lua`) against
  currently-installed resource metadata (`GetResourceMetadata`) on demand
  instead of only at boot.
- **Tier:** STATE. A slightly old dependency is not necessarily broken —
  report it as a fact ("ox_lib is 3.2.0, this was last checked against
  3.39.0") rather than a red flag.
- **False-positive risk:** low, but genuinely possible — a newer,
  compatible dependency version would be reported as "older than tested"
  only if the comparison is backwards; double check `CompareSemver`'s
  actual direction before wiring this up.

---

## Section B — Enabled but silently inert (the single most common shape here)

### B1. World-prop-model features that have never matched anything, live [TOP 10]
- **What it detects, in plain English:** "The 'drink from a water bowl' /
  'rest on X' options are switched on, but no dog has ever actually found
  a matching bowl or rest spot anywhere on your server — which almost
  certainly means the prop name is wrong, and the option is invisible to
  everyone."
- **The real bug it comes from:** this is not hypothetical, it is
  disclosed, live, and unresolved right now: `config.lua:4893`,
  `Config.Wellbeing.Thirst.bowlSources = { 'water_bowl' }`, is an
  unverified guess (`config.lua:4848-4893`, and `KNOWN_ISSUES.md` §2,
  "Hunger/Thirst's 'Drink from Bowl' world-prop model... is an unverified
  guess, and if it's wrong the option just never appears — with no error,
  anywhere"). `Config.Wellbeing.Fatigue.restSources`
  (`config.lua:4616`) carries the identical disclosed risk. The config's
  own comment (`config.lua:4885-4892`) proposes *exactly this diagnostic*
  and explicitly says it was never built: "a periodic... or
  first-player-connect-gated check in `server/wellbeing.lua`, reusing its
  existing `GetAllObjects()` scan, that warns only once it has NEVER once
  seen a `bowlSources`/`restSources` model match."
- **How to detect it, concretely:** `server/wellbeing.lua:2943` already
  runs `for _, obj in ipairs(GetAllObjects()) do` and hashes against
  `restSources`/`bowlSources` once per tick server-wide. Add a persistent
  counter (or re-use one if `debugdump` can hook the same scan): has this
  scan matched *any* object, ever, since the resource started? Report
  "0 matches found in N ticks" as the finding. **Important caveat to flag
  for the implementer:** `GetAllObjects()` only sees networked/spawned
  object entities, not static map (`.ymap`) decoration props — if a real
  in-world water bowl is a static map prop rather than a spawned entity,
  this scan will report zero matches *forever*, correctly, even with the
  right model name. That distinction itself is worth reporting to the
  owner rather than just a bare "0 matches" count, since it changes what
  fixing this actually requires.
- **Tier:** WORTH CHECKING — zero matches strongly suggests the config
  problem KNOWN_ISSUES already names, but a legitimate innocent
  explanation exists (no player has been near a real bowl yet, or the
  server has been up only briefly).
- **False-positive risk:** moderate on a freshly-restarted server (not
  enough time/players near a bowl yet) — only report this after some
  minimum elapsed time or player-count threshold, exactly as the config's
  own unbuilt proposal suggests ("warns only once it has NEVER once seen a
  match" — i.e., accumulate, don't sample once).

### B3. `Config.Features.X = true` with no config anywhere else agreeing it should run [WORTH CHECKING]
- **What it detects, in plain English:** "A feature switch is on, but a
  second switch it depends on is off, silently blocking it" — the same
  shape as A1 but for feature-to-sub-config dependencies rather than
  flat/grouped duplication (e.g., `Config.Features.BoneSweepDevTool`
  needing a convar most owners have never heard of).
- **The real bug it comes from:** `KNOWN_ISSUES.md` §2,
  "`Config.Features.BoneSweepDevTool` looks more alarming than it is" —
  ships `true`, but the actual command "only registers if you've *also*
  explicitly set `qbx_k9unit_enable_bone_dev_tool 1`" — a convar, not a
  config value, so nothing in `config.lua` itself would ever show the
  disagreement.
- **How to detect it, concretely:** for each known two-part gate
  (BoneSweepDevTool + its convar is the one confirmed case), read both
  the config flag and `GetConvar(...)` and report the combined, real
  state in plain English: "this dev tool is NOT active on your server,
  even though config.lua says true, because the convar isn't set" or vice
  versa.
- **Tier:** STATE. This one is not actually a bug — the comment explicitly
  says this alarming-looking combination is correct and safe. Report it
  as a fact so the owner isn't left wondering, not as a problem.
- **False-positive risk:** none, since this is reporting the literal
  combined state — the risk is only in wording it so it doesn't read as
  an alarm when KNOWN_ISSUES explicitly says it isn't one.

---

## Section C — Wired but never called

### C1. Every named "safety feature" boolean actually reachable from a real code path [TOP 10]
- **What it detects, in plain English:** "A safety feature you've turned
  on (like 'warn a suspect before releasing the dog') might be fully
  built and completely inert — nothing in the game actually enforces it,
  even though the switch says on."
- **The real bug it comes from:** commit `2727293` — a since-removed
  safety feature had "a function deciding whether a warning had been
  given, and nothing anywhere called it... Every reference to it in the
  whole resource was a comment or a test... an owner who turns it on
  believing their server now requires a warning before force gets
  enforcement that does not exist." This is about as bad as this class of
  bug gets: the feature looked completely real (switch, key, command,
  tests) and did nothing.
- **How to detect it, concretely:** this is hard to generalize safely
  (see false-positive risk below), so scope it narrowly to features that
  match this project's own past pattern: a boolean in `Config.Features`
  whose corresponding gate-function (named in the feature's own file
  header) is never referenced from `server/combat.lua`'s bite/takedown
  *opening* functions. This needs a maintained, hand-built list of
  {feature flag -> function name -> expected caller file(s)} rather than
  a generic "is this function called anywhere" scan, because Lua
  functions are frequently called only via `RegisterNetEvent`/exports,
  which a naive call-graph scan will not see and will misreport as dead.
- **Tier:** WORTH CHECKING, and only for the specific, hand-maintained
  list — not a general dead-code scanner.
- **False-positive risk:** HIGH if implemented as a generic "grep for the
  function name elsewhere in the codebase" check — a comment or test
  referencing the function name would satisfy a bare grep while the real
  bug (nothing in the *production bite path* calls it) goes right through,
  which is exactly what happened here in real life before this was found
  by a red-team pass, not a grep. If built at all, this must trace an
  actual call chain from the real entry point (the bite/takedown open
  function), not a text search.

### C2. Config settings that do nothing, but aren't labeled as such [WORTH CHECKING]
- **What it detects, in plain English:** "You can change this number in
  the settings file, but changing it currently has zero effect on
  anything — and the file doesn't say so."
- **The real bug it comes from:** commit `5d7f593` ("Stop config.lua
  telling three lies to the person who edits it") — the medkit's injury
  healing setting was described as "a no-op today" after it had actually
  been wired up (stale in the *other* direction — see H-section below),
  and separately, "Two settings that do nothing are now labelled as doing
  nothing, rather than deleted" (the scent-trail-hunt tuning table,
  inert since the switch was removed).
- **How to detect it, concretely:** this genuinely requires a
  hand-maintained list — there is no reliable automated way to prove a
  config value is unused across ~360KB of `config.lua` and ~200 Lua
  files without a real call-graph tool this project doesn't have. Scope
  this to a short, explicit list the debugdump author maintains by hand
  (starting from the ones already known: the scent-trail-hunt tuning
  block) and revisit it each time a feature is removed.
- **Tier:** STATE (for the known, already-disclosed ones) — just repeat
  the config file's own disclosure so the owner sees it without having to
  find the comment in a 360KB file.
- **False-positive risk:** none for the hand-maintained, already-confirmed
  list. Do not attempt to generalize this into an automated "unused
  config key" scanner — it would need a real static-analysis pass this
  project doesn't have the tooling for, and a wrong "this does nothing"
  claim is actively harmful (an owner would stop trying to use a setting
  that actually works).

---

## Section D — A gate stricter on the client than the server would allow

### D1. Tablet/radial action refused for a High-Command-by-rank officer who the server would actually allow [TOP 10]
- **What it detects, in plain English:** "An officer whose access comes
  from their rank (not a certification) gets refused by a button in the
  game, in exactly the kind of emergency where that matters most — even
  though the server itself would say yes."
- **The real bug it comes from:** this happened **at least four separate
  times** in this project's own recent history, which makes it the
  best-evidenced repeat-failure class in the whole codebase:
  - commit `7bd1f29`: handler-down defense and kennel deployment both
    refused a rank-based High Command officer through every route.
  - commit `c1ac5fc`: eight separate tablet actions (barking, tracking,
    bite/hold, takedown, dragging, vehicle entry) refused a rank-based
    officer while the identical action worked from the radial menu.
  - commit `a4c3167`: "A CORRECTION TO WHAT I SAID LAST TIME" — the
    *previous* fix for this exact bug was itself incomplete; the tablet
    button and radial items ran their own stricter check *before* ever
    reaching the shared, correctly-widened function.
  - commit `9f4b225`: "THE GATES... the functions those entries CALL still
    re-checked the narrower gate one layer down, so the widening did
    nothing" (vision, bite/takedown/drag).
  This is explicitly called out in this project's own commits as
  recurring: "This is the same mistake this resource has now made three
  times: a correct function re-gated by its caller."
- **How to detect it, concretely:** for each of the client-side gate
  functions listed in `client/tablet.lua` (the "records which server file
  and line its check was matched against" table added in commit
  `c1ac5fc` — search `client/tablet.lua` for its access-check dispatch
  table), simulate a High-Command-by-rank actor (`HasK9Access` returning
  true via rank rather than certification) against both the client-side
  gate and the corresponding server-side check, and flag any pair where
  the client refuses but the server would allow. This needs actual code
  reading, not a live runtime probe (the diagnostic can't safely fake
  being a different officer on someone's live server) — so this is best
  built as a **static cross-check the debugdump command runs against the
  resource's own source files it's shipped alongside**, comparing the
  known list of gate call-sites against the known list of server
  functions' actual conditions, flagged whenever a future edit touches
  one without the other. This is closer to a build-time test than a
  live-server probe.
- **Tier:** FINDING, if built as the static cross-check above (a real
  code fact) — but this is genuinely the hardest one to build well, and
  may be better served by a dedicated Lua-spec test (`tests/*_spec.lua`)
  than the debugdump command itself, given it needs source-level
  comparison rather than live-state inspection. Recommend flagging this
  to the debugdump author as "consider whether this belongs in the test
  suite instead of the live diagnostic," since the live server has no
  safe way to actually attempt the gated action as a fake rank-based
  officer.
- **False-positive risk:** low if the static comparison is done carefully
  file-by-file (this project has done it three times already and each
  time found new instances, which says the check is real, not noisy) —
  but building the automated version risks missing a gate hidden behind
  an unusual call shape, the same way the human passes did the first
  three times.

### D2. "Gate the start, never the stop" violated somewhere new [WORTH CHECKING]
- **What it detects, in plain English:** "A dog or player got stuck unable
  to turn something OFF (a vest, a vehicle, thermal vision, a kennel)
  because turning it off was, wrongly, gated on the same permission
  needed to turn it on."
- **The real bug it comes from:** this is this project's own
  most-frequently-invoked named rule, appearing in `server/wellbeing.lua`,
  `server/tracking.lua`, `server/certifications/`,
  `server/runtimecontrol.lua`, `client/vehicle.lua`,
  `client/tracking.lua`, `client/vision.lua`, `client/radial.lua`, and
  documented as violated and fixed in commits `3a1aafe` (vest could not be
  removed after decertification), `ee4c8c0`/`9f4b225` (vision stuck on),
  `c1ac5fc` (K9 shut in a vehicle), `c22342d`/`53c45c3` (kennel exit).
- **How to detect it, concretely:** genuinely hard to check live/generically
  — the fix pattern is architectural (a release/exit code path must never
  call the same access-check function the corresponding start path calls).
  Best served as a maintained list, re-verified after each new feature: for
  every mechanic with a start/stop pair (vest, vehicle entry/exit, vision
  on/off, kennel enter/exit, leash attach/detach, bite/takedown/drag
  start/release), confirm the release/stop function does not call the
  access-gate function the start function calls. This is a source-reading
  exercise for a human/test, not something `debugdump` can observe live.
- **Tier:** WORTH CHECKING, as a periodic manual/test-suite audit rather
  than a live diagnostic-command check — flagging this mainly so the
  debugdump author doesn't try to force it into a live check where it
  doesn't fit.
- **False-positive risk:** N/A if kept out of the live tool; high if
  attempted as an automated live probe (there is no safe way to test
  "can this be turned off" without actually turning something off on a
  live server).

---

## Section E — A value accepted, saved, displayed, and silently clamped

### E1. Per-dog speed/stamina overrides that exceed what will actually show in-game [TOP 10]
- **What it detects, in plain English:** "A dog's speed was set to a
  number that the game engine can't actually reach — so it saved
  correctly, shows correctly on the tablet, but the dog won't actually run
  that fast, and there's no other way to notice."
- **The real bug it comes from:** commit `7bd1f29` ("THE PER-DOG SPEED
  SETTING WAS LYING" — "High command could set a dog's speed up to ten
  times normal... Anything above two times silently never happened: it
  saved, it showed in the tablet, it went in the audit log, and the dog
  ran at two"). This exact shape is called out by name in the task brief
  as a failure class, and this project has already hit it for real. The
  *ceiling itself* is now fixed to genuinely reach the engine's real max
  (`client/movement.lua:1473`, `MOVE_RATE_ENGINE_MAX = 10.0`), but the
  general shape — "a value this resource lets you set higher than
  something else will actually apply" — is exactly the kind of thing
  worth a standing check rather than trusting it never regresses.
- **How to detect it, concretely:** for every K9 currently loaded with a
  speed override (read from the same table `server/k9profiles.lua`'s
  `RefreshOverrideCache` populates), report the stored value alongside
  `DescribeSpeedOverrideCeiling`'s own math (`server/k9profiles.lua:632`) —
  this function already exists and already knows the real ceiling; just
  surface its answer for every currently-configured dog rather than only
  when someone changes the value on the tablet.
- **Tier:** STATE. A value above the display-realistic bound is not
  automatically wrong (the code was fixed to genuinely honor it) — this
  is just useful, otherwise-invisible information for an owner wondering
  why a dog with speed "9" doesn't look 9x faster than a normal dog.
- **False-positive risk:** none — this reads a real, already-computed
  function's output; the only risk is presenting an intentional value as
  if it were a mistake.

### E2. Any XP/rank ceiling reachable far faster than its own documented pace [WORTH CHECKING]
- **What it detects, in plain English:** "Someone (a certifier, an admin)
  could realistically max out the top handler rank in minutes instead of
  the weeks the settings file describes, using a legitimate-looking
  action repeated many times."
- **The real bug it comes from:** commit `12a9e0c` ("Stop a certifier
  reaching the top handler rank in fifteen seconds") — every individual
  guard (per-pair daily cap, per-action cooldown, shared hourly budget)
  was working correctly, but their *combination* with the budget's
  one-time starting allowance let a certifier mint ten certifications back
  to back and reach Master Handler (500 XP) in about fifteen seconds,
  using invented offline-certify names, "no accomplice, no character
  creation, nothing to notice."
- **How to detect it, concretely:** this needs a live arithmetic check
  against the *current* config values, not the ones that existed when
  `12a9e0c` was written — the specific numbers (certify payout, daily cap,
  budget size) could all be changed independently by an owner editing
  `config.lua`, silently re-opening the same class of gap with different
  numbers. Compute, from the current config: the maximum XP a single
  citizenid could mint in one hour by chaining every legitimately-payable
  action at its fastest legal rate, and compare that against the XP
  needed for the top rank. If a single hour's worth of maximum legitimate
  minting can reach or exceed the top rank, flag it.
- **Tier:** WORTH CHECKING — this is an economy-design question as much
  as a bug, and a server that genuinely wants fast progression might
  configure it this way on purpose.
- **False-positive risk:** moderate — the arithmetic has to account for
  every real interacting cap (per-pair, per-actor, shared budget,
  cooldown windows) correctly or it will either cry wolf on a safe
  configuration or miss a genuinely exploitable one; this is exactly the
  kind of multi-guard interaction analysis that fooled the original
  audit ("An earlier audit rated this low and reasoned it was bounded. It
  was not").

---

## Section F — State that should be impossible

### F1. Asymmetric leash/partnership pairs [TOP 10]
- **What it detects, in plain English:** "A dog and an officer are
  recorded as leashed/partnered to each other, but only one side of that
  pairing agrees — which should never happen and usually means someone
  is stuck in a broken state until they reconnect."
- **The real bug it comes from:** not a shipped bug by name, but this is
  exactly the structural shape this project has repeatedly found bugs in
  around disconnect/state-cleanup (e.g., "Decertifying someone mid-hold
  used to leave their dog still holding the suspect for up to twenty
  seconds" — `KNOWN_ISSUES.md` "Fixed" section — and the entire
  `LeashPairs` design in `server/main.lua:243-247` is explicitly
  documented as a strictly mutual, symmetric structure:
  `LeashPairs[a] = { partner = b, isK9 = ... }` and
  `LeashPairs[b] = { partner = a, isK9 = ... }`, "with no record of which
  server id is the K9-role" implied by asymmetry).
- **How to detect it, concretely:** iterate `LeashPairs` (module-local in
  `server/main.lua` — needs an export or debug hook) and flag any entry
  `LeashPairs[a] = { partner = b }` where `LeashPairs[b]` is nil, or
  where `LeashPairs[b].partner ~= a`, or where both sides claim `isK9 =
  true` (the exact bug this project already fixed once: "Two K9s could
  partner with each other, with one silently and incorrectly treated as
  the 'handler' side" — `KNOWN_ISSUES.md` "Fixed" section).
- **Tier:** FINDING. A leash/partnership structure is documented as
  strictly symmetric by design; any asymmetry found live is a real bug in
  progress, not a judgment call.
- **False-positive risk:** low — the only legitimate transient window is
  the handful of ticks during attach/detach itself, so this should only
  fire if the asymmetry persists across two consecutive diagnostic runs a
  few seconds apart, not on a single snapshot.

### F3. An active Bite & Hold / Takedown / Drag whose hard expiry has already passed [WORTH CHECKING]
- **What it detects, in plain English:** "A dog is supposedly still
  holding, restraining, or dragging someone past the maximum time this is
  ever allowed to last — which should be structurally impossible."
- **The real bug it comes from:** `server/combat.lua` repeatedly cites
  `DEVELOPER_REFERENCE.md §12.0` item 4's "no unbounded trap" guarantee
  (`server/combat.lua:91,464,559,2080,2194,2459`) — every active hold
  carries an `expiresAt` hard cap specifically so this can never run
  forever, and this guarantee is treated as important enough to be
  restated at nearly every touch point in that file.
- **How to detect it, concretely:** iterate whatever active-hold table
  `server/combat.lua` maintains and flag any entry where
  `GetGameTimer() > entry.expiresAt` — if the hard-cap sweep is working,
  this should be structurally impossible to observe; finding one means
  the sweep itself has stopped running.
- **Tier:** FINDING — the code's own repeatedly-cited invariant says this
  cannot happen; observing it live means the invariant is currently
  violated.
- **False-positive risk:** low, but there is a narrow legitimate race
  between the expiry timestamp passing and the sweep tick actually
  running — only report this if it persists across two consecutive runs
  a few seconds apart, same caveat as F1.

---

## Section G — A comment or on-screen string that stopped being true

### G1. Cross-check every hand-written "the tablet says X" claim against the actual current behavior [WORTH CHECKING]
- **What it detects, in plain English:** nothing generic here — this
  needs to be the specific, already-known list, re-verified live.
- **The real bug it comes from:** this happened repeatedly and recently
  enough that it reads as a pattern, not a one-off: the tablet's speed
  note claimed a cap that had been removed (commit `66b70f7`), a rollback
  script's own printed message still claimed wiring was missing after it
  landed (commit `8314726`, "the string is the product... when they
  disagree, the string is the one doing harm"), a stamina warning claimed
  a reset-on-restart that had stopped being true (commit `a19c2ce`), and
  the tablet advertised commands as available when their feature switch
  was simply absent from config entirely (commit `7bd1f29`).
- **How to detect it, concretely:** this is a maintained list, not a
  generic scanner (a generic "compare every UI string against code" check
  is exactly the kind of thing that produced the 1,222-false-positive
  locale checker fixed in commit `54b8fa3` — see G2 below for why that
  matters). Maintain a short list of "load-bearing" owner-facing claims
  (the speed-cap note, the stamina-reset note, any "command X is
  available" indicator) and have `debugdump` re-derive the true current
  answer for each and compare it against what the UI currently shows,
  rather than attempting to parse arbitrary UI strings.
- **Tier:** WORTH CHECKING, scoped to the specific hand-picked list above.
- **False-positive risk:** very high if generalized. Do not attempt a
  broad "every string vs every code path" scan — see G2.

### G2. Do not rebuild the 1,222-false-positive locale checker's mistake [STATE — a warning for the implementer, not a check to build]
- **What it detects, in plain English:** N/A — this is a warning about
  method, not a check.
- **The real bug it comes from:** commit `54b8fa3` ("Stop the locale check
  crying wolf twelve hundred times a build") — a real, well-intentioned
  cross-reference check "failing every single run, with 1,222 errors,"
  because it didn't know about the tablet's separate text-resolution
  mechanism or about text whose lookup key is assembled at runtime or
  stored as data. The commit's own words are the exact principle this
  whole document opened with: "A permanently failing check is worse than
  no check. Nobody reads the thousand-and-first line."
- **Recommendation for the implementer:** any text-cross-reference check
  built into `debugdump` must be scoped as narrowly as this project's own
  now-fixed locale checker eventually was (excluding tablet-owned text,
  recognizing runtime-assembled names, recognizing data-driven lookups) —
  or simply not built as a generic scanner at all, in favor of the
  specific hand-picked list in G1.
- **Tier:** N/A (methodology note).
- **False-positive risk:** this note exists specifically because the
  false-positive risk of getting this wrong is proven, at scale, in this
  project's own recent history.

---

## Section H — Two switches, one silently winning (beyond A1/A2/B3)

### H1. The two independent self-grant switches, reported together [WORTH CHECKING]
- **What it detects, in plain English:** "There are two separate settings
  that both affect whether High Command can grant things to themselves,
  and they don't automatically agree with each other — an owner who
  changes one, expecting to close the door, might not realize the other
  one is a separate door."
- **The real bug it comes from:** `KNOWN_ISSUES.md` §2, "High command can
  now grant almost anything to themselves... governed by two config
  switches (`Config.FeatureControl.allowHighCommandSelfGrant` and
  `Config.HighCommand.allowSelfGrant`), both defaulting `true`" — these
  are two genuinely different keys (confirmed: `config.lua:1565` and
  `config.lua:1733`, consumed independently in `server/highcommand.lua:531`
  and `server/permissions.lua:820`) governing different kinds of
  self-grant (rank-based bypass vs. explicit permission rows). This is
  disclosed as intentional, not a bug — but it is exactly the "two
  switches, one thing, easy to think it's one switch" trap this task
  description names.
- **How to detect it, concretely:** report both current values together,
  in plain English, naming what each one actually controls, always — not
  only when they disagree (unlike A1, disagreement here is a completely
  valid, sensible configuration, e.g. an owner who wants one type of
  self-grant open and the other closed).
- **Tier:** STATE. Both switches defaulting the same way is normal;
  report the fact, not a judgment.
- **False-positive risk:** none — this is a factual read of two documented
  config values.

---

## Section I — Lower-confidence / speculative (marked as such because I could not tie them to a real shipped failure here)

### I1. Command reference page (tablet "Commands" tab) drift against real registrations [SPECULATIVE, but see below]
- **What it detects, in plain English:** "The tablet's list of commands
  might be missing one that actually works in-game, or listing one that
  doesn't."
- **Why it's here despite being speculative:** this is explicitly
  disclosed as a *known, open, unfixed* risk rather than a past bug:
  `KNOWN_ISSUES.md` §2, "The tablet's 'Commands' reference page can
  silently go out of date... it does this by checking a hand-maintained
  list of filenames, not by scanning the actual `server`/`client`
  folders." `tests/commandreferenceregistry_spec.lua` already confirms
  this hand-maintained-list weakness in its own comments (lines 121, 143:
  commands "missing from this hand-maintained snapshot"). So this is not
  speculative that the *gap* exists — it's speculative only in that no
  drift has been caught by it yet, as far as this pass could confirm.
- **How to detect it, concretely:** re-scan `fxmanifest.lua`'s declared
  `server_scripts`/`client_scripts` for `RegisterCommand(` calls (careful:
  exclude comment lines — this project's own `client/hud.lua` doc comment
  containing the literal text `RegisterCommand('...')` already fooled two
  separate guards into reporting a phantom command named `...`, per commit
  `2f21165`) and compare the resulting list against whatever the tablet's
  Guide tab actually renders in its command table.
- **Tier:** WORTH CHECKING.
- **False-positive risk:** proven high if built naively (see the `'...'`
  incident above) — must match on the real call shape (`RegisterCommand`
  followed by a string literal, not inside a `--` or `--[[]]` comment
  block) and should cross-check its own output against
  `tests/commandreferenceregistry_spec.lua`'s existing, tested logic
  rather than reimplementing the extraction from scratch.

### I2. Rate-limit / lock tables growing without bound on this specific live server [SPECULATIVE]
- **What it detects, in plain English:** "Some internal counter that
  should reset for each player is instead accumulating forever, which can
  eventually slow the server down or cause a reconnecting player to
  inherit a stranger's leftover cooldown."
- **Why it's speculative here:** the *general class* of bug is real and
  recent (commit `f28875a`, two roster cooldown tables "kept an entry for
  every player who ever used them and never dropped any of them"), and
  this project already built a whole-repo static test for it (reads all
  49 server files from the manifest, finds "83 rate-limit and lock
  tables," requires each to declare its own cleanup). But that test
  already runs on every suite execution — it is not something a live
  `debugdump` command would independently discover better than the
  existing test already does at build time. I could not find evidence
  this is currently a live, undetected problem (the whole-repo test
  passing is exactly why).
- **How it could be checked live, if built anyway:** report the current
  row-count of a small number of named in-memory tables the owner would
  actually care about (e.g., `XPMintBudget`), flagged only if it exceeds
  some multiple of current concurrent player count — but this requires
  exports/hooks into module-locals across many files, which is a real
  implementation cost for a check whose static-analysis sibling already
  exists and passes.
- **Tier:** STATE, low priority — recommend building this only after the
  Top 10, if there's implementation budget left.
- **False-positive risk:** speculative by definition here; not
  recommended as an early build target.

---

## If only ten get built, build these ten, in this order

1. **A1** — Config.Features vs Config.FeatureGroups disagreement (near-zero effort, near-zero false positives, proven bug shape hit twice)
2. **A3** — Which database tables are currently memory-only, and why (explains the single most confusing class of "my setting didn't save" reports)
3. **B1** — Has the bowl/rest-prop scan ever matched anything, live (this is the example named directly in the brief, and the exact mechanism was already designed in a config comment, just never built)
4. **A2** — Runtime tablet override vs. current config.lua disagreement
5. **B2** — Do the configured food/water item names actually exist in the live inventory
6. **F1** — Asymmetric leash/partnership pairs (cheap, high-confidence, matches this project's own "Two K9s could partner with each other" precedent)
7. **F3** — Any active bite/takedown/drag past its own hard expiry (cheap, the code's own repeatedly-cited invariant makes this a clean FINDING if it ever fires)
8. **E1** — Per-dog overrides that exceed what the movement engine will actually show
9. **H1** — Report both self-grant switches together, plainly
10. **A4** — Re-surface the dependency version check on demand

Everything past this line is real, cited, and worth building eventually —
but these ten are the ones that are cheap, tied to confirmed real bugs
(not speculation), and unlikely to produce the kind of noise that gets a
whole check ignored.
