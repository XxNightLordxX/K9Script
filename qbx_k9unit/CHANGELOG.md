# Changelog

What changed, in the order it changed, written for the person running the
server rather than the person who wrote the code.

This file covers **what you would notice**. It is not a commit log — there
are several hundred commits behind the entries below and most of them are
internal. For why a decision was made, see `PROJECT_HISTORY.md`; for what
is still wrong, see `KNOWN_ISSUES.md`.

Version numbers follow [semantic versioning](https://semver.org) and match
the `version` field in `fxmanifest.lua`. A **breaking change** means one
that needs you to do something — edit your config, import SQL, or change
how your staff work. Those are always called out under their own heading,
never buried in a list.

---

## Unreleased

**The version in `fxmanifest.lua` has never moved off `0.1.0`.** Nothing
here has been through a numbered release yet, so everything below is
"since the beginning" rather than "since the last version". The first
tagged release will draw a line under this section.

### Breaking changes — you need to do something

- **The database now ships switched OFF, and if you are already running
  this resource that will cost you everything you have saved.**

  `Config.Database.enabled` used to default to `true`. It now defaults to
  `false`, so a fresh install is drag-and-drop: drop the folder in, start
  the server, and every feature works with no `.sql` file to import. That
  is the point of the change, and for a brand-new install there is nothing
  to do.

  **If you are UPGRADING and you already run the database, read this
  twice.** Taking the new `config.lua` without editing it will silently
  switch your server to memory-only. Nothing errors and nothing is deleted
  — your tables sit there untouched — but from that moment the resource
  stops reading and writing them, and every certification, rank, XP total,
  partnership, permission grant, callsign and theme resets on your next
  restart. You would most likely discover this the morning after.

  **What to do:** after upgrading, open `config.lua` and set

  ```lua
  Config.Database = {
      enabled = true,
  }
  ```

  Nothing else changes. Your existing tables and data are picked up exactly
  as before — this only ever stopped the resource looking at them, it never
  touched them.

  Worth knowing either way: with the database off, the audit trail still
  works during a session (certification history, the search log, permission
  and override audits are all recorded in memory and readable from the
  tablet), but it is capped at the most recent 500 search entries and 200 of
  everything else, and it resets with the restart like everything else.

### Fixed — things that were broken for players

- **Server start-up messages that were wrong or alarming for no reason**
  (found in a live boot log). Supply-shop warnings printed twice. Start-up
  claimed `/k9givexp` and `/k9audit` were registered when chat commands are
  switched off. The blood and gunpowder tracking note still pointed at the
  retired `/k9specialize` command instead of roles on the tablet. The prop
  dragging warning fired even though your ambulance script (sc-ambulance)
  was already being used to check who is down. The bone tool showed a
  WARNING for its normal, safe "off" state.
- **A decertified handler stayed stuck in their kennel or vehicle seat.**
  Losing K9 access tore down the leash, any bite in progress and the
  partnership, but not a kennel you were resting in or a seat you were
  holding — you stayed physically attached while the server had stopped
  tracking you, and the spot could be handed to somebody else.
- **The tablet mangled rank names that contained certain characters.**
  Renaming a rank to something with `{xp}` or `{remaining}` in it — which
  the Rank Editor lets you do — corrupted the progression screen. The same
  fault hit the "tier in use" warning if a supply shop item was named with
  a matching word.
- **A search could take four seconds and then tell you nothing.** If your
  K9 was still on cooldown, or already searching, the dog played the full
  sniff animation and then produced no result and no message at all —
  indistinguishable from the feature being broken. Both cases now say which
  one it was.
- **Scent vision answered a keypress with silence.** Thermal and night
  vision each announce themselves; scent vision just flipped state. Turn it
  on with nothing in range — the ordinary case, since you turn it on to go
  looking — and nothing at all happened on screen. It now confirms both on
  and off, and the "on" message says outright that nothing will show until
  there is a scent nearby.
- **A training drill's refusal always said "wait".** Being too far from a
  training area, or not being certified, both produced "wait for the
  current one to finish" — advice that cannot work. Each reason now names
  itself.
- **A supply shop ped could leak its interaction prompt.** If the ped
  vanished before the resource cleaned it up, its third-eye option was
  never removed and could not be removed afterwards.

- **Thermal and night vision could be switched on but never off.** Both
  "is it currently on" checks asked the game a question it has never had an
  answer to — the two names were invented and had been there since the
  feature was written. An unknown question is not an error in FiveM; it just
  answers nothing, forever. So the toggle always believed vision was off,
  turned it on again, and left you stuck looking through walls until you
  reconnected. The tests passed the whole time, because the test invented
  the same two names in its own sandbox.
- **An unarmed player could switch off the dog chasing them.** Reporting
  "gunfire happened near me" required nothing at all — no weapon, no
  gunfire, just the ability to send it. Doing it repeatedly near a dog drove
  its fear up until it hesitated, and a hesitating dog refuses to bite, take
  down or drag. A suspect being chased could therefore disable their pursuer
  on demand, at no risk. Reporting it now requires actually holding a
  weapon, checked on the server rather than taken on trust.
- **A vest could not be taken off once your certification lapsed.** Every
  route to removing one — command, radial, tablet — ran through a single
  check meant to stop you putting one ON. And because the model swap refuses
  to run while a vest is attached, you could not undo it that way either.
  There was no way out short of dying.
- **The tablet's Decertify button silently did nothing to anyone online.**
  It routed through a command that explicitly refuses whenever the target is
  connected, so it worked only on people who were logged off — the opposite
  of what the button's own documentation promised.
- **Pinning a character as a permanent dog had never worked on a new
  server.** The table it writes to was only created by a numbered migration,
  while the setup guide tells first-time owners they need only two files and
  none of the numbered ones. Follow those instructions and that one table is
  skipped forever, so the feature looked wired and quietly failed every
  time.
- **High command's rank threshold asked for a rank most servers do not
  have.** A stock police job stops at grade 4 and this shipped asking for 6,
  so no rank qualified and the only thing letting anyone in was the "is this
  person the boss" fallback. It looked configured and did nothing.
- **Firing somebody left their roster row behind**, so re-hiring them
  brought back their old role and their old callsign instead of putting
  them back in Unassigned.
- **The top handler rank (Master Handler) could not be reached by anyone
  who never personally certified a new handler.** Two of the six actions
  configured to pay handler XP — treating your own dog, deploying the
  kennel — were switched on in name only and never actually paid, because
  paying them without a farming guard would have let XP be minted at
  thousands per hour. Both now pay for real, each behind its own
  per-person cooldown that survives a disconnect and reconnect: 24 XP an
  hour for treating your dog, 8 XP an hour for deploying the kennel, 32
  XP an hour combined. A handler on ordinary duty now reaches Master
  Handler in roughly a week instead of never.

- **A certified dog was invisible.** Changing to a dog model gives you a
  new body with none of its parts switched on. A human survives that; a
  dog does not, because every part of the dog is one of those parts. Nobody
  had told the new body to use its own defaults, so it drew nothing at all
  — solid, targetable, and invisible to everyone including the player.
- **The bark on a contraband find never played, on any install.** The
  setting named a sound one way round and the shipped file was named the
  other. An unknown sound is ignored rather than reported, so nobody ever
  found out.
- **A dog could be teleported across the map inside a kennel.** Anyone can
  climb into a deployed kennel for a ride, and picking a kennel up brings
  whatever is inside along with it — but your own kennel could be picked up
  from any distance, because before dogs could ride in them there was
  nothing inside to move. An occupied kennel now has to be walked to.
- **Being dragged could not be ended by the person being dragged.** The
  server always accepted it; the key they would press asked "am I the dog
  doing the dragging", got no, and told them they were not certified for K9
  duty. The way out existed and could not be reached from anywhere.
- **Two dogs could be put in the same seat of the same car.** Each player's
  game picked a seat and checked only its own copy of the world.
- **A specialization could land on somebody who had just been decertified**,
  leaving a record that silently came back to life if they were ever
  certified again.
- **Switching XP progression off left the speed bonus running** for every
  dog already on duty until they reconnected.

### Changed — things that behave differently now

- **Every K9 and handler rank now gives something you can feel.** The
  ladders were placeholder numbers: the first K9 promotion cost 1250 XP —
  hours of work — and paid five percent more speed and scent range, which
  nobody could notice. Elite, the most expensive rank, was the only one
  that unlocked nothing new at all: bigger numbers than Veteran, but where
  Veteran gained a medkit cooldown reduction, Elite's one distinguishing
  reward was a cosmetic badge that nothing in the resource actually
  displays.

  Scent range now carries most of the weight — roughly 40 / 46 / 54 / 64
  metres across the four ranks — because a dog fast enough to run anyone
  down flattens every pursuit, while a dog that tracks further is felt
  every time you use it. Elite gains a real medkit cooldown reduction of
  its own. On the handler side the first promotion now unlocks two things
  instead of shaving a tenth off one cooldown.

  **Nothing anyone has earned is affected, and nobody's rank moves.** Not a
  single XP threshold changed on either ladder — only what each rank gives
  you once you reach it.
- **Handler rank is now visible where you would look for it.** The roster
  has a Handler XP column beside the K9 one, and a person's screen has its
  own Handler XP section. The server had always been working this out and
  then throwing it away. It is kept separate from K9 rank deliberately: the
  same person is routinely high on one and nowhere on the other.
- **Scent Vision and the K9 Camera Feed are on the radial menu.** Both had
  a command and a keybind from the day they shipped and no wheel entry, so
  only players who read the keybind list ever found them.

- **Dragging has cooldowns.** It had none, per-dog or per-person, while the
  documentation said it had both. The per-person one matters most: without
  it, letting go bought you nothing, because the dog could grab you again
  the same second.
- **The contraband alert's loudest tier now takes a genuinely large find.**
  It triggered at 250 weight; a single handgun is about a thousand. One gun
  and a car boot full of drugs produced the same alert.
- **Barking and door-scratching now reach people within 300 metres**
  instead of every player on the server. If the distance check is ever
  unavailable it falls back to telling everyone, because a bark you cannot
  hear is worse than the waste.
- **Handler ranks are reachable.** The first rank needed 750 XP; a handler
  who does not personally certify others can earn at most 155, ever. So
  most handlers could never leave the bottom rung at any number of hours.
  Now 50 / 150 / 500.
- **Handlers can see their own rank and XP.** It was tracked, it shortened
  their cooldowns, and nothing ever told them it existed.
- **A dog cannot search while it is in a car or already holding somebody**,
  and cannot start a bite, takedown or drag while a search is running.
  Both were previously refused only on the player's own machine.
- **Scent vision's off switch is a rule, not a request.** With it off, the
  server no longer answers the question at all.
- **Thermal Vision and Night Vision are two separate controls again**, each
  with its own key (K and J by default), its own radial menu entry, and
  its own row on the tablet's Commands tab — reversing an earlier pass
  that merged them into one cycling control. The one-key cycle
  (`/k9vision`, default I) is kept as an optional extra alongside the two
  explicit toggles, not a replacement for them.

### Added

- **sc-dispatch support.** When a K9 goes down, sc-dispatch now gets a
  top-priority call for that K9's department automatically. Nothing to
  set up.
- **`docs/ox_inventory_items.lua`**: every K9 item (medkit, treat, meat
  bait, ultrasonic whistle, tablet) ready to paste into ox_inventory, with
  step-by-step instructions.
- **A K9 roster and a handler roster.** Two lists, sortable by rank, showing
  callsign, department, tier, XP and current partner. Clicking Manage opens
  the person screen that already existed rather than a second one that would
  drift from it. Roles and callsigns are set there; changing somebody's role
  warns you their callsign will be cleared before you commit to it, not
  after. Everyone certified starts under "Unassigned" until you sort them,
  and both lists say so plainly — on day one that is everybody, and an empty
  screen would read as broken.
- **Refusals say why.** One sentence — "You cannot use K9 features right
  now" — used to answer about a hundred different situations: not certified,
  wrong department, certification lapsed, feature switched off, deliberately
  blocked. It was the most-seen message in the whole resource and told you
  nothing, which made it the largest single reason to go and ask an admin.
  Where the game knows the reason, it now gives it.

- **Every command now appears in your chat autocomplete.** Before this
  there were none at all — the tablet's Commands tab was the only place any
  of the resource's commands were written down. Type `/` and they are
  there.
- **One tablet command instead of two.** `/k9tablet` now opens whichever
  view your rank in the department actually gives you, rather than needing
  a separate high-command command you had to know existed.
- **High command holds everything implicitly** — every permission, every
  feature, every upgrade — without anyone having to grant it row by row.
  One deliberate exception: an explicit **block** on a person still beats
  their rank. That is the only way to restrain one individual without
  demoting them, so it was kept.
- **A K9's player can warn their handler of danger**, and a handler can be
  warned before an apprehension. The warning carries only a rough compass
  direction and a distance band, both worked out on the server from real
  positions — so it can never be repeated over and over to narrow down
  exactly where someone is. Ships **off** until it has been reviewed.
- **Events can be posted to a Discord channel.** Messages are batched
  rather than sent one per event, because Discord rate-limits hard enough
  that a busy shift would trip it within seconds. The queue has a ceiling
  and drops rather than growing forever; the next message tells you how
  many were lost. The busiest event by far — a completed search — ships
  off. **A webhook URL is a password.** Anyone who has it can post to that
  channel forever.
- **A second officer can now join an active search-and-rescue call.** They
  ask to join, and the officer running the call accepts or declines — the
  same request-and-accept handshake already used for the leash and for
  partnering up. Once accepted, the joining officer genuinely searches on
  their own: their own position counts, they get their own warmer/colder
  hints, and they can be the one who actually finds the person. If
  whoever started the call disconnects, the call passes to whichever
  remaining officer joined earliest instead of ending, and it only ends
  for good once the last person on it leaves. XP for finishing the call
  still only ever goes to whoever started it — deliberate, so two people
  can't trade turns starting and joining calls to split extra reward for
  the same amount of real searching.
- **Dogs can eat and drink from bowls.**
- **A character can be pinned as a dog permanently**, so they load in as
  the same dog every time, independently of any certification.

- **Someone granted a single permission can now use it.** Granting only
  "may certify" left that person with no way to reach a person's record —
  the permission was real everywhere except the screen they would use it
  on, and the help text sent them to two tabs they could not see.
- **High command can make a dog's stamina last longer, or never run out.**
- **The startup log names which of your `config.lua` edits are being
  overridden** by a change made from the tablet, instead of printing a
  count. A setting changed on the tablet keeps winning over the file until
  it is reset there — correct, deliberate, and previously invisible.
- **Every combat setting says which way makes the dog stronger.** Two of
  them are counter-intuitive: lowering a cooldown makes the dog stronger,
  and the "maximum duration" settings are rare-case ceilings that look like
  they do nothing.

### Known limitations recorded rather than fixed

- `html/images/logo.png` is still a placeholder.
- **Setting a dog faster than about double speed is accepted, saved and
  shown, and will not look any faster.** The movement code clamps the final
  figure, so the number you typed is real everywhere except in the game. The
  setting says so where you set it; raising that clamp is a deliberate
  decision nobody has taken yet, because it is also what keeps a dog's speed
  inside what anti-cheat software considers normal.
- **Blood and gunpowder tracking now need a specialization**, where any
  certified dog could do them before. That is the change that was asked for,
  but an existing server does lose those two until specializations are
  granted. The startup check says so rather than letting you find out
  mid-shift.
- **High command in one department can certify and decertify people in
  another.** Deliberate, and right if you treat police and sheriff as one K9
  programme — wrong if you want them separate. It is a one-line change
  either way, and it needs an owner's decision rather than a guess.
- **`water_bowl` is an unverified prop name.** If it does not match a real
  model on your server the "Drink from Bowl" option simply never appears,
  with nothing in the console. Thirst still works through the item.

See `KNOWN_ISSUES.md` for the full list, including the ones that are
deliberate.

---

## 0.1.0

Not yet released.
