> **HISTORICAL RECORD — NOT CURRENT GUIDANCE.**
>
> This document is the design for the capability-family structure above Config.Features. The work it describes has been
> built, and in places has since been changed or removed. It is kept because
> it explains WHY things are shaped the way they are, which the code alone
> cannot say — but it does not describe how the resource works today, and it
> is not a specification anyone should implement from.
>
> For how the resource actually works now, see `README.md` (setup and
> features), `DEVELOPER_REFERENCE.md` (the code), and `DIAGNOSTIC_CHECKS.md`
> (the `/k9debug` report). Archived 2026-09-02.

---

# Feature Structure Spec

Phase 1 (design only). Nothing outside this file has been touched. This
document absorbed four escalations from the owner while it was being
written, in order:

1. "Merge on a fundamental basis" — `Config.Features` becomes a real nested
   tree (parent capabilities with real sub-features), not just a `category`
   label (commit `d00fd60`) glued onto 60 still-independent flat flags.
2. "Consolidate chat commands, 3rd-eye and radial menus too" — a parent is
   not only a config master switch, it is also (where safe) ONE command +
   ONE radial entry + ONE `ox_target` option, with the specific sub-action
   resolved automatically from context.
3. "The features themselves are too thin" — nesting alone is not enough;
   some of the 60 should stop existing as independent flags at all and
   become plain behaviour inside a bigger capability.
4. "Remove it if redundant or not much applicable" — deletion is now
   explicitly authorised, as a fourth bucket, with its own much stricter
   rules (§2.2). A companion document, `docs/history/OVERHAUL_PLAN.md`, restates all of
   this for the owner directly, in plain language, as a set of
   independently-approvable stages. This document stays the engineering
   reference; that one is the thing to hand him.

A companion correction, since it matters for anyone reading both documents:
an earlier claim (not made in this document, but circulated in this task's
own coordination) that the tablet's "Decertify" button was dead code has
since been traced end-to-end by another agent and found to be **wrong** —
it routes through a chat-command bridge deliberately. Nothing in this
document relied on that claim, but flagging it here so it is not
accidentally carried forward by anyone reading this file next to that
conversation.

All three are addressed below, in that order of consequence: §1–2 answer
"what are the real capabilities", §3–4 answer "what does the owner edit",
§5–7 answer "what does the player click/type/target", §8–13 answer "how do
we ship this without breaking or silently changing anyone's live server".

Command-name mechanics (exact merged command, argument shape, hidden-alias
allowlist, per-subcommand gate wording) are **owned by
`docs/history/COMMAND_CONSOLIDATION_SPEC.md`, not this document** — referenced, not
re-derived, everywhere the two overlap. This document owns: which of the 60
flags are real, which are sub-features, which retire; which capability
family each belongs to (corrected against `server/tablet.lua`'s
`FEATURE_DOMAINS`, which was built for a settings screen, not this); and
which family gets a merged radial/target entry point and by what resolution
rule.

---

## 1. The four buckets, and what "retire" vs. "remove" honestly mean here

- **(a) Real feature** — substantial enough to deserve its own switch, its
  own entry point, its own place in the owner's head.
- **(b) Sub-feature** — genuinely optional inside a parent, with an
  *articulable* reason an owner would want the parent on and this part off
  (tone/content, privacy, performance, cosmetic preference, policy — not
  "someone might want it").
- **(c) Behaviour** — folded into the parent, flag retired, **the thing
  still happens**. The owner loses a switch, not a capability. Everything
  in this bucket is covered by §1's own hard constraint below.
- **(d) Removed** — deleted outright, **the thing stops happening**, no
  replacement. This is a capability loss, not a config simplification, and
  is covered by its own, much stricter rule in §2.2 — **nothing in this
  bucket is a decision this document makes**; every (d) item below is a
  named recommendation awaiting the owner's explicit, per-item sign-off in
  `docs/history/OVERHAUL_PLAN.md`. None are implemented, or should be treated as
  implied-approved, by anything in this file.

**The hard constraint on (c):** this task's file scope is `config.lua`,
`server/runtimecontrol.lua`, and the tests. The ~200 call sites that read a
flat `Config.Features.X` key today live in files this task must not touch
(several — `server/tracking.lua`, `client/tracking.lua`,
`the removed scent-lineup server file`, `the removed scent-trail client file`, `client/radial.lua`,
`server/tablet.lua`, `client/tablet.lua` — are explicitly off-limits and/or
hot right now). That means **true behavioural retirement — deleting the
`if Config.Features.X` check from the code that implements it — is out of
scope for this pass, for every one of the 60, no exceptions.**

### 1.1 The (c) vs. (d) line, and why it matters more than any other line in this document

These two look identical to a non-technical owner reading a checklist —
both remove a toggle — and they are not the same action:

- **(c)**: the flag disappears from what he edits; the code behind it
  keeps running exactly as it does today (matching whatever the default,
  or his own existing value, already was — §9). Nothing he could do in
  game before stops working.
- **(d)**: the flag AND the capability disappear. Something he or his
  players could do before, they no longer can, ever, until someone writes
  it back in.

Every item below states which of the two it is, in those terms, not just a
letter.

### 1.2 The rule for (d), specifically

Three checks, all required, before any key is even proposed for (d):
1. **What reads it.** Grepped every other file for the flag's name and for
   its implementing globals before proposing removal — not just the file
   that owns it. Documented per item below.
2. **What it would cost if I'm wrong.** If I cannot establish confidently
   that nothing depends on a flag, I say that explicitly rather than
   asserting "nothing depends on this" — a wrong "nothing" is worse than
   an honest "I don't know."
3. **Data outlives the flag.** If a candidate for removal owns any
   database table or column, the recommendation is always to leave the
   data in place and remove only the code path that used it — deleting
   code is reversible (write it back), dropping data is not. None of the
   candidates below turned out to own persisted data (checked against
   `sql/`), but this rule stands for any future candidate too.

What Phase 2 *can* honestly retire (bucket c) is the **owner-facing
surface**: a
retired key stops being a field the owner sets in the clean nested
template, and the resolver (§8) derives its value automatically. The flat
key itself keeps existing internally, unchanged, because the ~200 call
sites still read it. This is a real, meaningful retirement (one less thing
in the owner's head) — it is just not a code deletion. Anywhere below that
says "retire", this is what it means. Full behavioural folding (e.g.
actually merging `the removed scent-trail client file`'s hunt logic into the tracking
query) is named explicitly as separate, larger, future work outside this
file scope.

---

## 2. Classification of all 60 keys

Grouped by the corrected family (§3 explains every place this differs from
`FEATURE_DOMAINS`), not the original 11 domains — several keys moved.

**STATUS NOTE, added after two of this section's own recommendations were
actually decided (this is Phase 1 design output; it was never updated
after the fact, so it still reads as an open recommendation in both
places below):**
- **`ScentTrailHunt`'s removal (§2.2.1) was approved and carried out.**
  `config.lua` no longer has a `Config.Features.ScentTrailHunt` key at
  all — see that file's own comment at the old key's former position for
  the full record and for exactly how to restore it (as-is, or as a
  Training-family drill) if a future owner wants it back. Neither
  `the removed scent-trail client file` nor `the removed scent-trail server file` was deleted; both
  are untouched and simply go inert with the key absent, same as any
  other feature file reading a missing flag as off.
- **The Sensory/Vision recommendation below (`NightVision`/`ThermalVision`
  folding into one shared vision-cycle entry point) was implemented, and
  then reversed at the owner's own request.** Thermal Vision and Night
  Vision are separate, first-class controls again — each with its own
  command, its own key (K and J), its own radial entry, and its own row
  on the tablet's Commands tab. The cycle this section recommends
  (`CycleVision()`/`k9vision`) still exists and still works, but only as
  an optional extra alongside the two explicit toggles, never as their
  replacement. `client/vision.lua`'s own header carries the authoritative,
  current account of this reversal — read that file before trusting
  anything about vision's entry-point shape in this document.

### Detection (was `scent`, plus 2 keys pulled in from `training` — see §3.1)

| Key | Bucket | Why |
|---|---|---|
| `ScentTracking` | **a**, and collapses into the family's own `enabled` (§3.5) | The unconditional baseline — the merged tracking code itself treats scent as "never gated," so a separate `Detection.enabled` *and* a separate `Detection.ScentTracking` would always be equal. One field, not two. |
| `BloodTracking` | b | Real content/tone control (some owners don't want a blood-trail mechanic) independent of whether tracking exists at all. |
| `GunpowderSniffing` | b | Same axis, different content category (weapons-discharge evidence). |
| `WaterTrackingDecay` | **c — behaviour, not a switch** | Revised from an earlier draft (b): it's a passive modifier the core tracking tick already applies automatically, never a decision anyone but this document made repeatedly. Folds into "how tracking behaves"; resolves to today's default (`true`) unless a migrating owner had it set otherwise (§9's hidden-override mechanism applies the same way). |
| `ScentVision` | a | Different interaction shape entirely — a persistent keybind-toggled overlay with its own performance/privacy design, not a one-shot query. Cannot merge into the single Track action without conflating a toggle-mode UI with a single-fire UI. Keeps its own entry point. |
| `ScentLineup` | **b — kept, explicitly NOT recommended for (d)** | Directly answering the owner's own question about this one: I considered removal and rejected it. Reasoning in §2.2.1. Genuinely optional (consent/complexity concern: it recruits a bystander). Its *start* action can fold into Detection's merged entry point; its *pick*/*cancel* actions cannot — different actor, no rank gate at all, see §7.2. |
| `ScentTrailHunt` | **d — recommended for removal, not just retirement (§2.2.1)** | No XP, no tie to any operational system (search/contraband/rescue), and — the deciding fact — it duplicates Detection's own interaction shape (walk toward a diminishing signal to a point) with a fake destination instead of a real one. Not "thin," genuinely redundant with a capability that already exists one entry point over. Dependency check in §2.2.1. |

Honest count against the owner's own hypothesis: **1 collapses into the
master switch, 1 stays a real feature with its own entry point (Vision), 3
stay genuine sub-features, 1 folds to pure behaviour, 1 is recommended for
outright removal.** Not "one real feature, five behaviours" — see §2.1 for
why Vision and Lineup resisted going further, and §2.2.1 for the removal
reasoning on the other two.

### 2.2.1 The two keys the owner asked me to answer directly

> **BOTH DECIDED SINCE THIS WAS WRITTEN — read the recommendations below as
> history, not as open questions.**
>
> - **`ScentTrailHunt`: removed.** The owner signed off and the removal
>   shipped. `Config.Features.ScentTrailHunt` no longer exists at all, so
>   the key reads `nil` and `the removed scent-trail client file` /
>   `the removed scent-trail server file` return at the top — both files are kept intact
>   and inert on purpose, so restoring it is a one-line config change.
>   See `Config.Features`' own "REMOVED" block, `README.md`, and
>   `tests/featureflagexistence_spec.lua`, which allowlists this key as
>   deliberately absent precisely so nobody later mistakes it for a flag
>   somebody forgot to define.
>
>   The onboarding alternative raised below — keeping it as a nose-following
>   *training drill* under `TrainingMode` — was **not** taken, and remains a
>   genuinely open option if the owner ever wants it back in that shape.
>
> - **`ScentLineup`: kept.** The recommendation against removal was
>   accepted; it still ships `true`.
>
> The reasoning underneath is left exactly as written, because it is the
> record of *why* those two calls went the way they did, and that is worth
> more than a tidied-up summary.

**`ScentTrailHunt` — recommend (d), removal, pending his sign-off.**
Dependency check (§1.2): grepped every `.lua` file for `ScentTrailHunt`/
`scenttrail`/`ScentHunt` outside its own two implementing files. Every
other hit is a **registry entry** (tablet display list, the permissions
grant-eligible list, `runtimecontrol.lua`'s tier table, command-suggestion/
reference lists, tests) or a **comment** listing it alongside similar
features for a pattern comparison (`server/pursuitsprint.lua`,
`server/permissions.lua`) — nothing else's runtime *logic* branches on its
value. No `sql/` table or column references it at all (it's a live,
in-memory hunt session — nothing to persist, so §1.2's data-preservation
rule doesn't even apply here, there's no data to preserve). I'm confident,
not just hopeful, that removing it costs nothing else — but removing the
registry entries listed above is real, if small, cleanup work that comes
with it. One honest alternative I want on the table alongside the removal
recommendation: `TrainingMode`'s practice sandbox drills bite-and-hold and
search against a dummy, but has no nose-following drill at all —
`ScentTrailHunt` is the only thing that lets a new handler practice
following a trail without a real one existing yet. If that's a capability
worth keeping for onboarding new players, it survives as (a), nested under
Training rather than Detection, instead of being removed. This is the
owner's call, not mine, precisely because it depends on how his players
actually use it.

**`ScentLineup` — recommend against (d), keep as (b).** This is not the
same shape of feature as `ScentTrailHunt` at all: it's a real multiplayer
mechanic (a conductor and one or more bystander participants, a secret
server-side pick, one guess), it doesn't duplicate anything else in the
codebase's interaction shape, and — per §7.2 — its `pick`/`cancel` actions
are load-bearing for people who hold no K9 access whatsoever. Removing it
would remove a capability (letting bystanders be involved in an
identification, deliberately consent-gated) rather than tidying up a
duplicate. If the owner still wants it gone after reading this, that's his
call to make explicitly — I'm not defaulting to it.

#### 2.1 Why Vision and Lineup resisted going to (c)

- **ScentVision** has its own keybind and a materially different cost
  profile (a live per-tick nearest-trails scan vs. a cooldown-gated single
  query) — collapsing it into "just what Detection does" would make it
  either always-on (a real performance regression risk on a busy server, a
  thing the owner never asked for) or silently absent, neither of which is
  "plain behaviour."
- **ScentLineup** structurally involves a *second, often-unprivileged
  player* (§7.2). Folding a multi-actor mechanic into a single-actor
  entry point's "automatic resolution" isn't a config simplification, it's
  a permission-model change, and the owner's own rule ("never guess
  destructively... resolution decides which, never whether") argues
  against doing it silently.

If the owner wants these pushed further into bucket (c) anyway, say so and
I will design that (it needs `client/radial.lua` and `server/tablet.lua`,
both currently off-limits/hot — a later pass).

### Search (was `search` domain, unchanged membership)

| Key | Bucket | Why |
|---|---|---|
| `SearchZones` | a, collapses into `enabled` | The base search action itself. |
| `ContrabandAlerts` | b | One of three genuinely different *reactions* to a positive search (this one: bystander-audible broadcast). Real, distinct reason to run one without the others (metagaming concerns). |
| `FindAlerts` | b | Second reaction: the K9's own auto-sit-and-bark. Independent of the bystander broadcast above. |
| `ContrabandScreenFX` | b | Third reaction: the finder's own screen effect. Cosmetic/tone preference, independent of the other two. |
| `SARCalls` | a | Distinct capability (missing-person/rescue calls, no arrest, no real player at risk) with its own file and its own entry point. |

I checked whether `ContrabandAlerts`/`FindAlerts`/`ContrabandScreenFX` are
really three names for one thing before writing this — they are not; each
is read from a different file (`server/search.lua`, `server/findalert.lua`,
`client/screenfx.lua`) reacting to the same event in three independent
ways. Keeping them separate is not thin-slicing, it's three real dials.

### Sensory / Vision (was `vision`)

| Key | Bucket | Why |
|---|---|---|
| `NightVision` | b | A *mode* the family's single vision-cycle entry point can offer (§5), not its own entry point. |
| `ThermalVision` | b | Same — second mode in the same cycle. |
| `CameraFeedPiP` | a | Structurally different mechanic (viewing through a partnered K9's own eyes; requires an active partnership) — cannot share the night/thermal cycle. Own entry point. |
| `ProximityAudioFX` | **c — behaviour, not a switch** | Revised from an earlier draft (b): purely ambient, never had a player-facing entry point, and nobody manages it independently of the rest of the sensory suite in practice. Folds into Sensory's own behaviour, defaults to today's shipped value. |

### Combat (unchanged membership — and the family that resists collapsing entry points, §7.1)

| Key | Bucket | Why |
|---|---|---|
| `BiteAndHold` | a | Own entry point, deliberately never merged with the others — see §7.1. |
| `NonLethalTakedown` | a | Same. |
| `PropDragging` | a | Same, and targets a prop rather than a person, a different target class besides. |
| `PursuitSprint` | a | Distinct mechanic (movement burst vs. an bite outcome), own entry point. |
| `HandlerDownDefense` | b | Automatic server-triggered behaviour, never player-invoked — no entry point at all, real reason to want it off while keeping the player-invoked combat actions on. |
| `DangerWarn` | b | Real feature today, but it is functionally "a K9-initiated alert bark" — a strong future-fold candidate into `AdvancedBarkRadial` (§14). Not folded this pass: that touches `client/radial.lua`, off-limits. |

### Movement (unchanged membership minus `Recall`, which moves to standalone — §3.2)

| Key | Bucket | Why |
|---|---|---|
| `LeashMechanics` | a, collapses into `enabled` | Foundational "you have a dog on a lead" capability. |
| `BasicBarkSounds` | a | Own entry point (the bark radial button itself). |
| `AdvancedBarkRadial` | **c — behaviour, not a switch** | Revised from an earlier draft (b): adds more options *inside the same entry point* `BasicBarkSounds` already owns (confirmed in `client/radial.lua` — already one entry point today, offering more/fewer bark variants by flag). Nobody chooses this repeatedly the way they choose whether Wellbeing's sub-systems run; it's "does the bark button have extra options," which is a behaviour, not a decision. |
| `AgilityBasicJump` | a | Base movement capability — driven by the native jump input itself, not a command/radial/target; "own entry point" here is the player's own movement key. |
| `AgilityAdvanced` | **c — behaviour, not a switch** | Revised from an earlier draft (b): extends what the same jump input does (adds vault approximation); no entry point of its own, same reasoning as `AdvancedBarkRadial` above. |
| `VehicleEntryExit` | a | Own target options (`enterVehicle`/`exitVehicle`) — genuinely different actions at different times, not the same fact restated twice (unlike leash, §5.1). No change recommended here. |
| `DoorInteraction` | b | Narrow, real (`nudgeDoor`/`scratchDoor` are two different actions, not duplicates — no merge recommended). |

### Wellbeing (unchanged domain plus `K9Medkit`, pulled in from `gear` — §3.3)

| Key | Bucket | Why |
|---|---|---|
| `FatigueSystem` | a, collapses into `enabled` | The core energy system. |
| `MoodSystem` | b | Independent complexity layer. |
| `FearStressSystem` | b | Independent complexity layer. |
| `DistractionSystem` | b | Independent complexity layer. |
| `InjuryLimping` | b | Independent realism preference (some owners find perma-limp frustrating, want fatigue without it). |
| `HealthStaminaHUD` | b | Purely a display preference — doesn't gate any mechanic, only whether the bars are drawn. |
| `K9DownDispatch` | b | A background signal to third-party dispatch resources, no entry point, real reason to differ from the rest of wellbeing (do you even run a dispatch resource). |
| `K9Medkit` | a | Ties the wellbeing state to an inventory item and a real entry point (`treatK9`). Moved here from `gear` for entry-point purposes — it belongs with feed/pet/drink, not with kennels/shop/attachments. |

### Progression (split from `progression` — see §3.4)

| Key | Bucket | Why |
|---|---|---|
| `XPProgression` | a, collapses into `enabled` | The master economy switch. No entry point of its own — earned passively. |
| `HandlerXPProgression` | b — **must stay `false` by default, no exceptions** | Config.lua's own header explains two of its six award keys still lack a real per-actor mint cooldown. Retiring or defaulting this to anything but its current value would be a live economy exploit. |
| `CertificationExpiry` | b | Independent policy decision (recertification cadence), off by default deliberately. |
| `K9Leaderboard` | b | Privacy-sensitive, independent of whether XP itself is tracked. Small own entry point (`/k9stats`), already minimal — no change recommended. |

### Partnership (new — split out of `progression`, §3.4)

| Key | Bucket | Why |
|---|---|---|
| `HandlerPartnership` | a, collapses into `enabled` | Own entry point (`partnerUp`/`revokeHandler` targets, partner-up/break-partnership radial items) — a relationship mechanic, not really "progression." |
| `PartnershipTenureBonus` | b | Automatic milestone bonus, no entry point, already requires `HandlerPartnership` AND `XPProgression` both true today — a natural sub-feature. |

### Gear (unchanged domain minus `K9Medkit`, moved to Wellbeing)

| Key | Bucket | Why |
|---|---|---|
| `K9Inventory` | a, collapses into `enabled` | Own entry point (`openK9Inventory`). |
| `K9EquipmentShop` | b | A shop existing at all is meaningless without `K9Inventory`; naturally nests under it. |
| `DeployableKennel` | a | Own entry point — see `docs/history/COMMAND_CONSOLIDATION_SPEC.md`'s own kennel section for why its command merge is *additive*, not a replace (keybind pinning). Deferring to that document for the command row; this doc places it as a child of Gear for config purposes only. |
| `PropAttachments` | a | Own entry point, substantial R&D history (the bone-sweep tool exists specifically to support it). |

### Training (unchanged domain minus the 2 keys moved to Detection)

| Key | Bucket | Why |
|---|---|---|
| `TrainingMode` | a, collapses into `enabled` | Own entry point, per `docs/history/COMMAND_CONSOLIDATION_SPEC.md`'s training family. |
| `FetchMechanic` | a | Own entry point, per that spec's fetch family. |

Only two keys left here once the scent-flavoured training minigames move
to Detection (§3.1) — a small family is an honest outcome, not a problem.

### Tablet (new — split out of `admin`, §3.6)

| Key | Bucket | Why |
|---|---|---|
| `CommandTablet` | a, collapses into `enabled` | The tablet itself — own entry point (the item/command that opens it). |
| `RuntimeFeatureControl` | b | A *screen inside* the tablet, no entry point of its own. |
| `TabletTheming` | b | Cosmetic, same reasoning. |

### Integrations (new — narrowed from `admin` + `integration`, §3.6/§3.7)

| Key | Bucket | Why |
|---|---|---|
| `DiscordWebhook` | b | Off by default, background poster, no entry point. |
| `ResourceAutoDetect` | b | Background auto-detection, no entry point. |

### Standalone — genuinely do not belong under any parent (§3.2/§3.6)

| Key | Bucket | Why |
|---|---|---|
| `Recall` | a | The universal termination path for THREE Combat sub-features (bite/takedown/drag) — see §3.2 for why nesting it under `Movement` (its display domain) would be a real stranding bug. |
| `HighCommand` | a | Proven independent in the code and already carries its own `lockoutRisk`/`sessionOnly` protection in `server/runtimecontrol.lua` — the single highest-blast-radius flag in the resource; must never share fate with anything else. |
| `PermissionGrants` | a | Proven independent — `server/permissions.lua`'s grant/revoke command path is gated on `IsHighCommand`, not `CommandTablet` (confirmed by direct read and by `docs/history/COMMAND_CONSOLIDATION_SPEC.md`'s own permissions family table). |
| `AdminAuditCommands` | a | **Explicitly, deliberately independent of `CommandTablet`** — `server/admin.lua`'s own comment: *"an operator can ship `CommandTablet = false` with `AdminAuditCommands = true`, a real, plausible config, not a contrived one."* This is the single strongest piece of evidence in the whole codebase that a shared "admin" parent would be actively wrong. |
| `BoneSweepDevTool` | b | Dev-only, must never share fate with `CommandTablet` or anything else; already double-gated by its own convar + ACE check, independent of every other flag. |
| `RadialMenu` | a | It is the delivery mechanism for most *other* families' entry points, not a member of any one capability — grouping it with `DiscordWebhook`/`ResourceAutoDetect` under "integration" (its current display domain) was a display-only convenience; as a parent it would be actively strange (turning off "integration" for Discord reasons would also kill the bark/leash/vehicle/track radial for everyone). |

**Tally (revised after the (d) pass): 25 (a), 30 (b), 4 (c), 1 (d).**
`WaterTrackingDecay`, `ProximityAudioFX`, `AdvancedBarkRadial`,
`AgilityAdvanced` moved from (b) to (c) on a second, more ruthless pass
(none of them is ever chosen repeatedly by an owner independent of its
parent — they're behaviour, not decisions); `ScentTrailHunt` moved from
(c) to (d) once the dependency check (§2.2.1) showed it was safe to
recommend outright rather than merely folding.

This still does **not** match the owner's own hypothesis ("one real
feature and five behaviours") for the worked scent example, and (b) is
still the largest bucket overall, not (c) or (d). I want to be direct about
that rather than force a tidier-looking number: most of the 60 flags I
checked turned out to gate a *real, articulable, different* concern (tone,
privacy, performance, or policy) from their siblings — the bar in §1
explicitly rules out "someone might want it" as a justification, and I
held every (b) to that bar on both passes, not just the ones that were
convenient to keep. Only 1 of the 60 met the higher bar for outright
removal, on the specific evidence in §2.2.1 — I did not pad bucket (d) to
make the plan look more thorough than the evidence supports. The
redundancy the owner is actually feeling is concentrated in the
**entry-point layer** (§6), where the count really is dramatic (118 → far
fewer) — that is where nearly all of the "less clutter" win comes from,
and where `docs/history/OVERHAUL_PLAN.md` puts most of its weight.

---

## 3. Where the 11 `FEATURE_DOMAINS` diverge from a real capability family

`server/tablet.lua`'s `FEATURE_DOMAINS` (lines 1280–1382) was built to
colour-code a settings screen. Used as-is for parent switches, four of its
11 groupings would be wrong:

### 3.1 `scent` and `training` both hold "the scent stuff"

The owner's own example ("scent tracking and scent lineup") spans two
different display domains: `ScentTracking`/`BloodTracking`/
`GunpowderSniffing`/`ScentVision`/`WaterTrackingDecay` sit in `scent`;
`ScentLineup`/`ScentTrailHunt` sit in `training`. His mental model of "one
family" does not match the display split. **Correction: `Detection` pulls
`ScentLineup` and `ScentTrailHunt` in from `training`.**

### 3.2 `movement` holds `Recall`, which is Combat's escape hatch

`Recall` (`the removed recall server file`) ends whatever active effect a partnered K9
holds — bite, takedown, *or* drag — "generalised beyond §12.5.1's bite-only
text... a strictly worse unbounded-trap posture" per its own header. It
lives in `movement` for display purposes only. If `Movement.enabled` forced
its children off (as every other parent's `enabled` does), turning off
Movement while Combat stays on would silently remove the ONLY way to call
off an active bite/takedown/drag — a real stranding bug, and exactly the
class of thing rule 4 asked me to audit for. **Correction: `Recall` stays
standalone, ungated by any parent, full stop.**

### 3.3 `gear` holds `K9Medkit`, which belongs with wellbeing's other care actions

`K9Medkit` is grouped with `K9Inventory`/`K9EquipmentShop`/
`DeployableKennel`/`PropAttachments` in `gear` — all "carry/deploy
equipment" actions. But its actual entry point (`treatK9`) is one of four
near-identical wellbeing interactions (`feedK9`/`petK9`/`treatK9`/
`drinkFromBowl`, §6) that the owner would naturally want to reach the same
way. **Correction: `K9Medkit` moves to `Wellbeing`.**

### 3.4 `progression` bundles three unrelated capabilities

`XPProgression`/`HandlerXPProgression`/`K9Leaderboard`/`CertificationExpiry`
(economy/policy), `HandlerPartnership`/`PartnershipTenureBonus`
(relationship registry) share a domain only because a settings screen
needed *a* label for both. `HandlerPartnership` has its own real entry
point (Partner Up) unrelated to XP; nothing requires XP tracking to be on
for a partnership to exist. **Correction: split into `Progression` and
`Partnership`.**

### 3.5 `scent`'s "one flag becomes the master switch" pattern, generalised

Where one existing key was already the unconditional baseline of its
family (`ScentTracking` for Detection, `SearchZones` for Search,
`LeashMechanics` for Movement, `FatigueSystem` for Wellbeing,
`XPProgression` for Progression, `HandlerPartnership` for Partnership,
`K9Inventory` for Gear, `TrainingMode` for Training, `CommandTablet` for
Tablet), that key *becomes* `family.enabled` rather than sitting alongside
a redundant new `enabled` boolean that would always equal it. **Combat**
and **Sensory** have no such natural baseline among their existing
members (their members are parallel siblings, not a base+variants
relationship) — those two families get a genuinely new `enabled` field
that has no old-shape equivalent (see §8.3 for what that means for
backward compatibility).

### 3.6 `admin` is the worst-fitting domain of the 11 — do not give it one switch

Covered in the standalone table above. The decisive evidence:
`server/admin.lua`'s own comment documents `CommandTablet = false` +
`AdminAuditCommands = true` as "a real, plausible config, not a contrived
one." A shared `Admin.enabled` would make that documented, intentional
combination impossible to express, and would additionally force
`HighCommand`/`PermissionGrants`/`BoneSweepDevTool` off the instant an
owner wanted just the tablet off (or vice versa) — none of which the code
treats as coupled. **Correction: split into `Tablet` (`CommandTablet` +
its two intrinsic screens) and four standalone flags.**

### 3.7 `integration` conflates "talks to Discord/detects other resources" with "the radial menu exists"

`RadialMenu` sits in `integration` only because its own comment says the
grouping needed *somewhere* to put "the radial menu's own UI mechanism."
Functionally it gates the entry-point delivery surface for most of the
other families. **Correction: `RadialMenu` goes standalone; `Integrations`
keeps just `DiscordWebhook`/`ResourceAutoDetect`, which genuinely do share
one "background plumbing" concern.**

The remaining domains (`search`, `vision`→renamed `Sensory`, `combat`,
`gear` minus the one move, `training` minus the two moves) hold up as real
capability families as-is.

---

## 4. The tree (owner-facing shape)

```
Config.Features = {
    Detection    = { enabled = true, Blood = true, Gunpowder = true, Water = true, Vision = true, Lineup = true },
    Search       = { enabled = true, ContrabandAlerts = true, FindAlerts = true, ScreenFX = true, SARCalls = true },
    Sensory      = { enabled = true, NightVision = true, ThermalVision = true, CameraFeedPiP = true, ProximityAudio = true },
    Combat       = { enabled = true, BiteAndHold = true, NonLethalTakedown = true, PropDragging = true, PursuitSprint = true, HandlerDownDefense = true, DangerWarn = false },
    Movement     = { enabled = true, BasicBarkSounds = true, AdvancedBarkRadial = true, AgilityBasicJump = true, AgilityAdvanced = true, VehicleEntryExit = true, DoorInteraction = true },
    Wellbeing    = { enabled = true, Mood = true, FearStress = true, Distraction = true, InjuryLimping = true, HUD = true, K9DownDispatch = true, Medkit = true },
    Progression  = { enabled = true, HandlerXP = false, CertificationExpiry = false, Leaderboard = true },
    Partnership  = { enabled = true, TenureBonus = true },
    Gear         = { enabled = true, EquipmentShop = true, DeployableKennel = true, PropAttachments = true },
    Training     = { enabled = true, FetchMechanic = true },
    Tablet       = { enabled = true, RuntimeFeatureControl = true, Theming = true },
    Integrations = { enabled = true, DiscordWebhook = false, ResourceAutoDetect = true },

    -- Standalone -- deliberately outside every parent, see §3:
    Recall              = true,
    HighCommand         = true,
    PermissionGrants    = true,
    AdminAuditCommands  = true,
    BoneSweepDevTool    = true,
    RadialMenu          = true,
}
```

Sub-key names are shortened from the flat originals for readability in the
nested form (e.g. `Detection.Blood` not `Detection.BloodTracking`) — the
resolver (§8) maps them back to the exact flat names every existing call
site reads. **Exact sub-key naming is a bikeshed; the family membership and
bucket classification above are the load-bearing decisions.**

**Note on the four (c) keys** (`Water`, `ProximityAudio`,
`AdvancedBarkRadial`, `AgilityAdvanced` — reclassified from (b) to (c) in
§2's revision pass): the tree above shows them as visible fields for
illustration. Per §1's own rule, a true "clean" template would omit them
entirely (§9's hidden-override mechanism still accepts them if an owner
needs to set a non-default value); whether the shipped example config
shows them as commented-out/hidden fields or omits them completely is a
documentation-formatting detail, not a behavioural one, and is left open
for Phase 2.

18 top-level things (12 families + 6 standalone) instead of 60, each family
holding 1–8 children instead of an undifferentiated flat list of up to 60.

---

## 5. Per-family entry points

`—` means unchanged from today (no merge recommended, reason given above
in §2). Families whose command row is already fully specified in
`docs/history/COMMAND_CONSOLIDATION_SPEC.md` say so instead of repeating it.

| Family | Command | Radial | Target | Resolution rule |
|---|---|---|---|---|
| **Detection** | in-flight `k9track` (another agent, live now) | `k9_track_certified` (landed) | none today | **Already built, reference implementation.** Server resolves scent/blood/gunpowder from certification + what's logged nearby; re-checks each candidate type's own flat flag before offering it (`server/tracking.lua`'s `findNearestTrackableSource`, confirmed by direct read — `Config.Features[TRACK_TYPE_FEATURE_FLAGS[trackType]]` is checked per candidate, exactly the "gate is re-checked against the resolved action's own gate" rule). `ScentLineup`'s *start* could plausibly become a further resolved outcome of this same entry point later (e.g. offered when several people stand in a line and nothing is logged nearby) — not attempted this pass. `ScentVision` keeps its own keybind (§2.1). |
| **Search** | `docs/history/COMMAND_CONSOLIDATION_SPEC.md` doesn't cover search commands — none identified needing a merge | 1 today, no change | `searchPerson`/`searchVehicle` — different target *types* (person vs. vehicle), keep separate | n/a — reactions (`ContrabandAlerts`/`FindAlerts`/`ContrabandScreenFX`) are automatic, not separately invoked. |
| **Sensory** | none today | 1 new "K9 Vision" cycle item replacing separate night/thermal toggles if any exist today (need to confirm current entry shape before implementing) — **SUPERSEDED, see the status note at the top of §2: this shipped, then the owner asked for separate toggles back. Thermal/Night are their own commands, keys, and radial entries again; the cycle survives only as an additional, optional item, not a replacement.** | none | **Not certification-based** — a plain "next enabled mode" cycle (off→night→thermal→off, skipping any mode whose own flag is off). Flagging explicitly that this is a *different resolution shape* from Detection's, not forcing it into the same mold. `CameraFeedPiP` keeps its own separate keybind/command (different mechanic, requires partnership). |
| **Combat** | — (see §7.1, deliberately not merged) | — | — | n/a |
| **Movement** | — | Leash: — (1 item today) | `attachLeashAsHandler`/`attachLeashAsK9` → **recommend one registered option**, `canInteract` already resolves which role is looking via `IsOwnModelK9()` (confirmed, `client/movement.lua:847,881`) so each player only ever sees one of the two today anyway. Correction to the coordinator's framing: this is not currently confusing the *player* — it is two `RegisterTargetOption` blocks in the code for what is, from any one viewer's side, always exactly one option. Collapsing to one registration is a code-duplication win, not a player-confusion fix. Additive/reversible either way. | Pick the label/icon from `IsOwnModelK9()`, same predicate already in use. |
| **Wellbeing** | `k9eat`/`k9drink` — flagged but deferred in `docs/history/COMMAND_CONSOLIDATION_SPEC.md` §7 (file hot); revisit together once `wellbeing.lua` is quiet | 1 today, no change | `feedK9`/`petK9`/`treatK9`/`drinkFromBowl` → candidate to merge into one "Care for K9" option | Additive and reversible (feeding/petting/treating a K9 is never destructive) — safe for full contextual resolution (nearest bowl → drink; item in hand matches a feed/treat item → that action; else → pet). **Exact current semantics of each of the four target options need a confirm-read of `client/wellbeing.lua` before Phase 2 implements this** — shape given here, not fabricated in detail. |
| **Progression / Partnership** | `/k9stats` unchanged; Partner Up unchanged | unchanged | `partnerUp`/`revokeHandler` — different actions (start vs. end a partnership with a *specific* other person), not the same fact twice, no merge recommended | n/a |
| **Gear** | Kennel: additive per `docs/history/COMMAND_CONSOLIDATION_SPEC.md` §1 (keybind-pinned, not a true merge) | Kennel: 2 today → recommend 1 (no `RegisterKeyMapping` constraint applies to a radial item, unlike the commands) | `enterKennel`/`exitKennel`/`pickupKennel` → recommend 1, resolved by whether a kennel is already deployed at this spot | Additive/reversible (deploying, entering, exiting, picking up a kennel is never destructive to another player) — safe for contextual resolution. `openK9Inventory` unchanged (different action, opening inventory vs. managing the kennel object). |
| **Training** | `docs/history/COMMAND_CONSOLIDATION_SPEC.md` training family (3→1) | unchanged | none | n/a, that spec is authoritative |
| **Tablet** | — | — | none | n/a — opening the tablet is already one action |
| **Integrations / standalone** | `AdminAuditCommands`: `docs/history/COMMAND_CONSOLIDATION_SPEC.md` audit family — **explicitly proven non-mergeable further** (5 variants share one gate but each needs a different mandatory target — no context to infer from). `PermissionGrants`: that spec's permissions family (2→1). `HighCommand`: no command family identified. | n/a | n/a | n/a |

---

## 6. Entry-point count-down (the 118, worked examples)

Using the coordinator's own counted baselines:

| Capability | Today | After (command layer, per `docs/history/COMMAND_CONSOLIDATION_SPEC.md`) | After (+ this doc's target/radial layer) |
|---|---|---|---|
| Kennel | 7 (3 target + 2 radial + 2 cmd) | 3 commands (additive — 2 kept for keybind reasons + 1 new wrapper, **not a reduction at the command layer, by that spec's own explicit design**) | 3 cmd + 1 radial + 1 target = **5** |
| Fetch | 7 (2 target + 2 radial + 3 cmd) | 1 command | Target/radial merge plausible but not yet confirmed against `client/fetch.lua`'s exact semantics — directional estimate **~3–4**, not asserted precisely |
| Wellbeing | 7 (4 target + 1 radial + 2 cmd) | Deferred (file hot) | Target merge plausible (§5) — directional estimate **~3–4** once commands land too |
| Leash | 3 (2 target + 1 radial) | n/a (no command exists) | 1 target (code dedup, not a player-facing change, §5) + 1 radial = **2** |
| Scent (Detection) | was 3 radial + likely 3 cmd before the in-flight merge | **Already done, live in the tree**: 1 radial (`k9_track_certified`), 1 command (`k9track`) | Already at the target state — **2** |

I'm giving exact numbers only where I've confirmed the underlying code
(kennel, leash, the in-flight scent merge); fetch and wellbeing get
directional estimates because collapsing their target options correctly
needs a same-file semantic check I haven't done in Phase 1 (that's
implementation-level work, not design). Total-118 endpoint isn't a number
I'll assert without doing that check for every family — false precision
here would be worse than an honest range.

---

## 7. Families that genuinely cannot collapse to one entry point

### 7.1 Combat — deliberately NOT merged

`BiteAndHold`/`NonLethalTakedown`/`PropDragging` each end with a real,
different, consequence for another player, and getting the wrong one is
not reversible the way a wrong fetch-ball click is. This is exactly the
owner's own "never guess destructively" rule: contextual dispatch is for
additive/reversible actions, and biting a real person is neither. Keeping
three separate, explicit entry points here is not leftover redundancy —
it's the one family where the redundancy is the safety feature.

### 7.2 Lineup — start folds in, pick/cancel cannot

`docs/history/COMMAND_CONSOLIDATION_SPEC.md` §1 already worked this out at the command
layer and it applies identically here: starting a lineup needs K9 access
plus a permission grant; picking and cancelling are participant actions
with **no rank gate at all**, because the person being asked to point
somebody out is usually a civilian. If Detection's single entry point ever
grows to offer "start a lineup" as a resolved outcome, that offer must
still carry its own full gate check at the point of dispatch — never
inherit a coarser "you already passed Detection's gate" assumption. Pick
and cancel must keep their own, completely separate, ungated surface
forever; there is no version of "merge everything" that is safe for them.

### 7.3 Audit — proven non-mergeable, deferring entirely

`docs/history/COMMAND_CONSOLIDATION_SPEC.md`'s own audit-family analysis: all five
variants share one gate but each needs a different *mandatory* target —
there is no context to resolve from. Restating that finding here rather
than re-deriving it; this document adds nothing to it.

### 7.4 Kennel — keybind-pinned, additive not replace

Also fully specified in `docs/history/COMMAND_CONSOLIDATION_SPEC.md` §1: `k9exitkennel`
is bound by a live `RegisterKeyMapping`, so it cannot stop being a real,
independently registered command without silently breaking anyone who
rebound that key. This document's only addition is the target/radial layer
(§5, §6), which has no equivalent keybind constraint.

---

## 8. The resolver

Runs once in `config.lua`, immediately after the `Config.Features` table
literal, before anything else reads it.

### 8.1 Shape detection

- If `Config.Features` contains any of the 12 known family keys
  (`Detection`, `Search`, `Sensory`, `Combat`, `Movement`, `Wellbeing`,
  `Progression`, `Partnership`, `Gear`, `Training`, `Tablet`,
  `Integrations`) as a **table** → NEW shape.
- Else if it contains any of the 60 known flat keys as a **boolean** at the
  top level → OLD shape.
- Ambiguous/empty → **assume OLD shape.** Never assume the more aggressive
  new behaviour by default; the safer wrong guess is the one that changes
  nothing.

### 8.2 OLD shape — byte-for-byte unchanged

Read every one of the 60 keys exactly as today. No family-enabled logic
runs at all — there is nothing to run it against. Print once at startup:
`[John-K9] Config.Features is in the classic flat format — loaded
unchanged. See docs/history/FEATURE_STRUCTURE_SPEC.md if you want the new grouped
format.` This is a no-op by construction, not by testing after the fact:
the OLD-shape branch does not share code paths with the NEW-shape branch.

### 8.3 NEW shape — augment, never replace

For each family: read `family.enabled` (default `true` if omitted; clamp
to that default with a warning if present but not boolean). For each
child, resolved flat value = `family.enabled AND childValue` (default
child value = today's shipped default, same clamp-and-warn rule). For a
family whose `enabled` has **no old-shape equivalent** (`Combat`,
`Sensory` — see §3.5), the field only exists in the new shape; an OLD-shape
config never has one, so §8.2 is untouched by its existence.

**Critical: the resolver adds flat keys onto `Config.Features`, it does
not delete or replace the nested tables.** After resolution,
`Config.Features.Detection = { enabled = true, ... }` AND
`Config.Features.ScentTracking = true` both exist as siblings. This is
required for two things: every existing call site keeps reading the exact
flat name it reads today, and `server/runtimecontrol.lua` can still look up
a key's parent for the override-refusal rule in §11.

Retired key (`ScentTrailHunt`, §1/§9): resolved value = `family.enabled`,
UNLESS a hidden override child is explicitly present (§9) — never a bare
mirror with no escape hatch.

### 8.4 Clamp-and-warn, concretely

Every malformed-input path prints one line naming the family, the key, and
`config.lua`, then falls back to the shipped default and keeps loading —
no assert, anywhere, in this code:

```
[John-K9] Config.Features.Combat.enabled is not a boolean (got table) — using the default (true). Fix Config.Features.Combat.enabled in config.lua.
```

A `family` key that exists but isn't a table gets the same treatment,
substituting all-defaults for that entire family rather than aborting.

---

## 9. Retirement mechanics for `ScentTrailHunt` (the one bucket-(c) key)

The owner's own hard constraint, stated exactly as given: retiring a flag
must never silently change what a server does today.

- **OLD shape**: nothing changes — §8.2 means `ScentTrailHunt` is read
  exactly as it is today, custom value and all. No migration needed,
  because nothing has moved.
- **NEW shape, fresh config (no prior flat file to migrate)**: there is no
  existing custom value to protect — a brand-new nested config is a
  deliberate new setup, same as any other default in a fresh install.
  Resolves to `Detection.enabled`, matching today's shipped default
  (`true`).
- **NEW shape, an owner manually migrating from flat**: this is the one
  case that can actually hurt somebody, if they had `ScentTrailHunt =
  false` and the new template gives them no field for it. **Resolution: a
  hidden, undocumented-in-the-clean-template override key is still
  accepted** — `Detection.TrailHunt = false` — read if present, silently
  defaulting to mirror `Detection.enabled` if absent. Same discipline as
  `docs/history/COMMAND_CONSOLIDATION_SPEC.md` §3's hidden command aliases, applied to a
  config key instead of a command name: the surface is retired (not
  advertised, not in the clean example), the capability to express a
  non-default value is not. A migration guide printed once when NEW shape
  + this key differs from default would say so explicitly, never assume
  silently.

---

## 10. Never-silently-re-enable

**Correction to the original brief:** it named `DiscordWebhook`,
`DangerWarn`, and `BoneSweepDevTool` as ships-off examples. Direct read of
`config.lua` shows `BoneSweepDevTool` actually ships `true` — its
real-world inertness comes from a separate operator-set convar + ACE gate,
not this flag. The genuine ships-`false` set, requiring the strongest
protection, is: **`HandlerXPProgression`, `DiscordWebhook`,
`CertificationExpiry`, `DangerWarn`.**

Phase 2 test (goes in `tests/`): pin all 60 resolved flat values against
today's actual shipped `config.lua` values, twice —
1. Feed the resolver today's real flat table (OLD shape) → assert identity
   with itself (trivial by §8.2's construction, but written explicitly so
   a future edit to the resolver can't accidentally break it).
2. Feed the resolver the proposed NEW nested default template (§4) →
   assert every one of the 60 resolved values equals today's shipped flat
   default, **including all four ships-false keys resolving to `false`**.

This is the test that proves the restructure is a no-op on defaults, not
just an assertion that it is.

---

## 11. Runtime/tablet override semantics

`server/runtimecontrol.lua`'s `SetFeature`/`ResetFeature` continue to
operate on **flat keys only** — no change to that mechanism. The new rule:

**If an operator calls `SetFeature(childKey, true)` while
`Config.Features[FEATURE_PARENTS[childKey]].enabled == false` (NEW shape
only — see below), refuse loudly**, reason `parent_disabled`, naming the
parent. Agreeing with the owner's instinct over my own original brief:
accepting the override would store a value that can never take effect
(the resolved flat flag is forced false at load time regardless), which is
exactly the invisible-state bug class this codebase already fixed for
`RuntimeFeatureControl`/`TabletTheming`'s own lockout protection. A small
new `FEATURE_PARENTS` lookup table in `runtimecontrol.lua` (mirrors §4's
tree) drives this check.

**For OLD-shape configs this refusal path never triggers** — there is no
parent table to consult, `FEATURE_PARENTS[childKey]` resolves to nothing,
and `SetFeature` behaves exactly as it does today. Zero behaviour change
for an existing owner who hasn't adopted nesting.

**Boot-time re-apply loop** (the one `HighCommand`'s own comment already
describes): must also skip re-applying a stored override for a child whose
parent currently resolves `false`, logging it, rather than writing a value
that will have no observable effect. Keep the stored row for a future
boot where the parent might be on again — do not delete it.

**Scope limit, stated explicitly, not an oversight:** `family.enabled` is
**not** independently toggleable live from the tablet in this phase. It
only takes effect via a `config.lua` edit + restart — the same tier
today's `rawtoplevel` keys already use. A parent that can force up to
eight `live`-tier children off simultaneously (Movement, Wellbeing) is a
strictly bigger single click than anything that exists today, and making
that live safely needs its own confirmation UI in `server/tablet.lua` /
`html/tablet.js` — both off-limits this pass. Recommending this as
explicit future work requiring its own owner sign-off, not doing it
silently by omission.

---

## 12. Gate-the-start audit

Because §11 makes every `family.enabled` restart-only, the live-stranding
risk rule 4 warned about is substantially defused by construction — a
restart already safely drains all active state in this codebase's existing
model (confirmed for `VehicleEntryExit`: "anyone already sitting in a
vehicle stays there and can always get out"; for Combat: the expiry and
position-history threads already run unconditionally and re-check their
flags fresh every tick specifically so a *live* flip never stops release
logic, per `server/runtimecontrol.lua`'s own `BiteAndHold` entry). Two
things needed independent attention beyond "don't make it live":

- **`Recall`** — fixed structurally by never nesting it under any parent
  (§3.2), not by any resolver logic.
- **Lineup pick/cancel** — fixed by never letting them inherit a coarser
  gate from a merged entry point (§7.2), not by anything about parents.

Everything else audited (fetch/training/kennel's unconditional stop paths)
is already correctly designed and documented in
`docs/history/COMMAND_CONSOLIDATION_SPEC.md` — restating it here would be duplicating,
not adding.

---

## 13. Test plan, summarised

New/updated in `tests/` (Phase 2):
1. §10's 60-key no-op-on-defaults pin, both shapes.
2. Malformed-nested-block clamp-and-warn (one test per failure shape:
   non-table family, non-boolean `enabled`, non-boolean child) — assert a
   warning fires and a safe default is used, never an error thrown.
3. `FEATURE_PARENTS`-driven override refusal (§11): `SetFeature` on a
   child whose parent resolves `false` in NEW shape → refused,
   `parent_disabled`; same call against an OLD-shape config → succeeds
   exactly as today.
4. Boot-reapply skip-when-parent-off (§11).
5. Retired-key hidden override (§9): NEW shape with
   `Detection.TrailHunt = false` present → resolves `false` despite
   `Detection.enabled = true`; absent → mirrors `Detection.enabled`.

---

## 14. Explicitly out of scope for Phase 2, named so nobody assumes it happened

- Actual behavioural folding of `ScentTrailHunt` into the tracking query
  (needs `the removed scent-trail client file`, off-limits).
- Folding `DangerWarn` into the bark radial (needs `client/radial.lua`,
  off-limits/hot).
- The shared `ox_target` registration helper the coordinator flagged as a
  precondition for "one option per family" staying maintainable —
  registration is hand-rolled per file today (`client/fetch.lua`,
  `client/movement.lua` ×2, `client/search.lua`, `client/vehicle.lua`,
  `client/wellbeing.lua` ×2, none shared). This is real, necessary
  groundwork that touches files well outside `config.lua`/
  `runtimecontrol.lua`/tests — recommending it be tracked as its own item,
  likely coder-frontend or coder-ui's lens, before the target-layer merges
  in §5/§6 get implemented.
- Making `family.enabled` live/tablet-controllable (§11) — needs
  `server/tablet.lua`/`html/tablet.js`, both off-limits, and its own
  confirmation-UI design.
- Confirming exact current `client/wellbeing.lua`/`client/fetch.lua` target
  semantics precisely enough to finalize their merged resolution rules
  (§5/§6) — flagged, not fabricated.

---

## 15. Sign-offs needed before Phase 2 starts

1. Sub-key naming in §4 is a placeholder — confirm or rename before I wire
   the resolver to it.
2. Confirm the 4-way split correction to `FEATURE_DOMAINS` (§3) is wanted
   in the actual nested config, not just documented here — it means
   `Config.Features` in the shipped file will not have exactly 11 top-level
   groups.
3. Confirm the §1 scope limit (owner-facing retirement only, not code
   deletion) is acceptable for `ScentTrailHunt`, given the alternative is
   waiting for `the removed scent-trail client file` to come off the do-not-touch list.
4. Confirm §11's restart-only scope limit for `family.enabled` is
   acceptable, given the alternative is a `server/tablet.lua`/
   `html/tablet.js` change this task cannot make.
5. **`ScentTrailHunt`'s removal (bucket d) is not approved by anything in
   this document.** It is a named recommendation. See `docs/history/OVERHAUL_PLAN.md`
   for the plain-language version of this same item, which is where the
   owner's actual sign-off belongs.

Phase 1 stops here.
