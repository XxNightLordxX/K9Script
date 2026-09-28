# K9 Command Tablet — Simplification Plan

Author: audit pass · Date: 2026-09-03
Scope: `html/tablet.js`, `html/tablet-catalog.js`, `html/tablet.css`,
`client/tablet.lua`, `server/tablet.lua`.

> **STATUS: items A–H are DONE.** The owner asked for all eight
> recommendations and for none of the five §6 "deliberately NOT
> recommended" items. Both were honoured. Item I was never a
> recommendation — it asked for a re-measure and an owner decision, and
> that measurement is now in §8 below, still awaiting that decision.
>
> Two of this document's own claims turned out to be wrong when the code
> was read properly, and both are corrected in place below rather than
> quietly executed: the §3 search-bar inventory over-counted by two, and
> item E's premise was false. See §8.

**This was a planning document. Sections 1–7 describe the tablet as it was
before the work; §8 records what actually landed.**

**Nothing in here adds a feature, a command, an export, an event, or a
config option.** Every item is a merge, a removal, or a re-route to
something that already exists. Where a recommendation would cost the owner
something real, that cost is stated plainly rather than buried.

---

## 1. What the tablet looks like today, measured

Not estimated — counted directly from the source.

| Thing | Count | How it was counted |
|---|---|---|
| Tabs a High Command officer sees | **19** | `mkButton(S('tab_*'))` in `buildTabs()` |
| Screens | **21** | `build*Screen()` functions |
| Text inputs | **44** | `mk('input'` |
| …of those, person-finding boxes | **~11** | see §3 |
| …of those, list filters | **2** | Commands, My Record abilities |
| Player-visible strings | **~1,000** | `DEFAULT_STRINGS` entries |

Where the text sits, by prefix:

| Area | Strings | Screens |
|---|---|---|
| Command reference | 150 | 1 |
| Help | 115 | 1 |
| Guided Flows | 90 | 5 |
| Shop (locations + items) | 69 | 2 |
| Runtime control | 54 | 1 |
| K9 profiles | 50 | 1 |
| Audit | 34 | 1 |
| Home | 32 | 1 |
| Cert tiers | 32 | 1 |
| Roster | 30 | 2 |
| XP tiers | 29 | 1 |
| Permission keys | 24 | 1 |
| Partnerships | 24 | 1 |
| Theme | 13 | 1 |
| Person | 9 | 1 |

Two facts stand out. **Reference text (Help + Commands) is 265 strings —
over a quarter of everything the tablet can say.** And **Guided Flows is
90 strings across 5 screens that contain no logic of their own** — every
step calls the same builders the Person screen already uses.

---

## 2. The core problem: one record, many doors

The tablet is not big because it does many things. It is big because it
does a few things in several places each.

There is really only **one record** — a person, their department, their
certification, their rank, their XP, their abilities, their partner, their
per-dog overrides. `buildPersonScreen()` already shows all of it in one
place. Nine other screens show a slice of that same record, each with its
own way in.

Proof, from the code rather than from impression:

- `buildMyRecordScreen()` and `buildProgressionScreen()` both call
  `buildCertificationList()` and `buildLadderBlock()`. Progression is
  largely My Record with the abilities removed.
- `buildHomeScreen()`'s "ready abilities" is `myFeatures` filtered to the
  usable ones. My Record shows the same array unfiltered.
- Both Roster tabs call the **same function**:
  `buildPersonnelRosterScreen('k9')` and `('handler')`.
- The K9 Profiles tab's editing is `buildPersonK9ProfileSection()` — which
  the Person screen already renders.
- The Partnerships tab's admin half opens the same Person screen its own
  lookup box points at.
- Every Guided Flow step body is `buildCertificationList()`,
  `buildCertificationDetail()`, `buildPersonFeaturesSection()`,
  `buildRoleControl()` — the Person screen's own parts, wrapped in a step
  navigator.

So the simplification is not "cut features". It is **stop building the
same screen six times**.

---

## 3. The search boxes

The owner's specific complaint. There are about eleven inputs whose job is
"find a person", and **every single one of them ends at the same Person
screen**:

| # | Where | Line | Placeholder |
|---|---|---|---|
| 1 | Console — roster search | 4858 | `search_placeholder` |
| 2 | Console — open by exact citizen ID | 4894 | `open_by_id_placeholder` |
| 3 | Console — online players search | 5080 | `online_players_search_placeholder` |
| 4 | Partnerships — admin lookup | 5994 | `search_placeholder` |
| 5 | Roster — open by ID bar | ~10680 | `open_by_id_placeholder` |
| 6 | Roster — search | 10690 | `search_placeholder` |
| 7 | K9 Profiles — citizen ID lookup | 10001 | `k9_profile_lookup_placeholder` |
| 8 | Audit — citizen ID | 8969 | `audit_citizenid_placeholder` |
| 9 | Audit — department | 8975 | `audit_department_placeholder` |
| 10–11 | Guided Flows — person picker | — | both of the above shapes |

Three of them sit **on the same screen at the same time** (Console). Two
more are on the Roster screen, which is itself reachable from Console.

**Recommendation: one person-finder, on Console, reached from everywhere
else.** Any screen that currently asks "which person?" links to Console
instead of re-implementing a box. That removes 8 of the 11 without losing
a single path — the destination was always identical.

The two remaining query boxes stay because they are genuinely different
questions: the **Audit** query (a log search over time, plate and officer,
not a person lookup) and the **list filters** on Commands and abilities.

---

## 4. Recommendations, highest payoff first

Each is scored on what it removes and what it risks.

### A. Merge Home + My Record + Progression into one screen
**19 → 17 tabs. −32 strings. Removes 1 of the 2 list filters.**

These are three views of four things: who you are, your certifications,
your XP, your abilities. Progression shares two builders with My Record
outright; Home shows a filtered copy of My Record's ability list.

One screen, top to bottom: who you are and what to do next → your
certifications → your XP on both ladders → your abilities.

**Keep:** the "what do I do next" card at the top. It is the reason Home
exists and it is the first thing a brand-new player sees. Merging must not
turn the landing screen into a wall of records.
**Cost:** one longer screen instead of three short ones. Acceptable — most
of its length today is the same data repeated.

### B. Merge the two Roster tabs into one
**17 → 16 tabs. −0 strings (pure structure).**

They already call one function with a different argument, and they already
share the "Unassigned" section — which currently renders twice, once under
each tab. One Roster tab with a K9 / Handlers / Unassigned toggle is the
same code with the argument moved into a control.

**Cost:** none identified. This is the cleanest item on the list.

### C. Collapse the person-finders to one
**−8 inputs.** See §3. No tab change; this is what makes the tablet feel
smaller without removing anything.

**Cost:** one extra click on the screens that lose their inline box
(Partnerships admin, K9 Profiles, Flows). Worth it — those boxes are the
main reason the tablet reads as cluttered.

### D. Fold the K9 Profiles tab into the Person screen
**16 → 15 tabs. −1 input. −~40 of its 50 strings.**

The editing is already on Person. The tab contributes a duplicate lookup
plus one thing that is genuinely its own: the **list of who currently has
an override**. Keep that list — as a section on Console, where the other
"who has what" lists live — and drop the tab.

**Cost:** losing a dedicated home for a rarely-used admin screen. Small.

### E. Drop the Partnerships tab's admin half
**−1 input. −a few strings.** No tab change.

The Partnerships tab exists because of a direct owner instruction: it
should show who is partnered with whom. That stays, unchanged. What goes
is its separate admin lookup box, which opens the Person screen — where
`buildPartnershipSection()` already renders the same thing.

**Cost:** none. The capability is not removed, only its second door.

### F. Merge Shop Locations + Shop Items into one Shop tab
**15 → 14 tabs. −~10 strings.**

One feature flag (`K9EquipmentShop`), one shop, two tabs. "Where the ped
stands" and "what it sells" are two sections of one screen, not two
screens.

**Cost:** none identified.

### G. Merge Cert Tiers + XP Ranks + Permission Keys into one Catalogs tab
**14 → 12 tabs. −~20 strings.**

All three are the same shape: a list of catalog entries with add, rename
and remove. They are already gated identically (High Command). Three
sections on one screen.

**Cost:** the merged screen is long. Mitigated by the fact that each
section is short and an operator visits one at a time.

### H. Merge Help + Commands into one Guide tab
**12 → 11 tabs. −~30 strings of overlap.**

265 strings between them — over a quarter of everything the tablet says —
and they answer the same question at two zoom levels. Commands already
tells you, per command, what it does, what you need, and whether you can
use it right now. Help explains the same tasks in prose.

One Guide tab: the task walkthroughs on top, the searchable command table
under them, using the filter box that already exists.

**Cost:** this is the largest single body of text to re-thread, and the
most likely to introduce a stale sentence. Do it last, and do it with the
locale cross-check running.

### I. Re-measure Guided Flows after A–E, then decide
**Potentially 11 → 10 tabs and −90 strings — the biggest single reduction
left, and the only one I am not recommending outright.**

The five flow screens contain no logic of their own; they sequence the
Person screen's own parts and add a person picker. Once the Person screen
is the one place everything happens (A–E), each flow becomes roughly
"Console → find person → do it".

But Flows exists to answer "what do I do first", and a non-technical
operator who has never certified anyone may still want to be walked
through it. **This is the owner's call, not a technical one.** The honest
recommendation: land A–E, open the flows, and if a flow is now just two
clicks with a heading on top, retire it. If it still teaches something the
Person screen does not, keep it.

---

## 5. Where this lands

| | Today | After A–H | After I too |
|---|---|---|---|
| Tabs (High Command) | 19 | **11** | **10** |
| Tabs (ordinary handler) | 6 | **3** | 3 |
| Person-finding inputs | ~11 | **1** | 1 |
| Total inputs | 44 | **~34** | ~32 |

The ordinary handler's tablet — six tabs today (Home, My Record,
Progression, Partnerships, Commands, Help), and what most players actually
see — becomes **three: My Record, Partnerships, Guide.** A seventh tab,
Command Console, appears only for someone holding the audit capability, and
is unaffected.

That is the number the owner's "less stuff on there" is really asking
about. Everything else on this list is High Command housekeeping.

---

## 6. Things deliberately NOT recommended

Listed so they are decisions, not oversights.

- **Do not remove the two-click confirm on destructive actions.** It is
  tedious by design. There is a case for keeping it only where
  `lockoutRisk` is set, but that is a safety trade, not a tidiness one,
  and it should be decided on its own.
- **Do not hide a feature that is off but switchable.** Already settled:
  the Runtime Control screen must keep showing a `live` feature that is
  currently off, or there would be no way to switch it back on.
- **Do not merge the Audit tab into anything.** It is the one screen whose
  query is genuinely not a person lookup, and it is privacy-sensitive —
  keeping it visibly separate is a feature of its own.
- **Do not remove the "why can't I use this" states.** `blocked`,
  `not_certified` and `requires_grant_missing` rows must stay visible.
  Hiding them answers "why can't I do this" with silence.
- **Do not touch the server-side gates.** Every one of these items is a
  display change. No merge below may remove or widen an authorization
  check; the server re-authorizes every action regardless of which screen
  fired it, and that must stay true.

---

## 7. Suggested order

Ordered so each step makes the next one smaller, and so the riskiest text
work happens last.

1. **B** (roster merge) — smallest, zero risk, proves the pattern.
2. **E** (partnerships admin lookup) — one box, no tab change.
3. **C** (collapse the person-finders) — the biggest visible win.
4. **D** (K9 profiles into Person) — depends on C.
5. **F** (shop merge) — independent, easy.
6. **G** (catalogs merge) — independent, easy.
7. **A** (Home + My Record + Progression) — the most-seen screen, so do it
   once the pattern is established.
8. **H** (Help + Commands) — most text, most chance of a stale line.
9. **I** (flows decision) — re-measure, then ask the owner.

Every step should keep all four gates green: `luacheck`, the Lua spec
suite, the browser spec suite, and the locale cross-check. The locale
cross-check in particular is what will catch a merged screen that left a
string behind, and the three-way string contract means every removal has
to happen in `tablet-catalog.js`, `client/tablet.lua` and
`locales/en.json` together.

---

## 8. What actually landed, and what this document got wrong

Written after implementing A–H, against the real tree.

### Measured again, the same way as §1

| | Before | After |
|---|---|---|
| Tabs (High Command) | 19 | **11** |
| Tabs (ordinary handler) | 6 | **3** |
| Screens | 21 | 15 |
| Text inputs | 44 | 42 |
| Player-visible strings | ~1,000 | **976** |

The eleven tabs an administrator now sees: My Record, Partnerships, Guide,
Command Console, Guided Flows, Tablet Theme, Catalogs, Personnel Roster,
K9 Supply Shop, Runtime Control, Audit Trail.

An ordinary handler sees three: **My Record, Partnerships, Guide.**

### Two things this document got wrong

Both were found by reading the code before acting on the recommendation,
and both are recorded here rather than quietly fixed, because a plan that
hides its own errors is worse than one that never made them.

**§3's inventory over-counted the search boxes.** Two of the eleven, listed
as "Roster — open by ID bar" and "Roster — search", do not exist: the
Roster screen has no input at all. Those two line numbers were the Guided
Flows person picker, counted twice. The true figure was nine, of which two
are the Audit log query that §3 itself excluded.

**Item E's premise was false.** It said the Partnerships tab's admin
section was purely a second door to something the Person screen already
rendered, so the whole section could go. It was not: the Person screen
shows the CURRENT partnership, but the history list and the Force End
button existed only in that admin section. Executing the item as written
would have removed a real capability. The section was moved onto the Person
screen instead, and only the duplicate lookup was deleted — which is what
the item was actually after.

One consequence for §3's arithmetic: after E and D, the only duplicate
person-finders left are the Guided Flows picker's two, and removing those
while keeping Flows would leave the flows unable to select a person at all.
So they are bound to item I. The Command Console keeps its three, because
each reaches a genuinely different set — the certified roster, any citizen
id (the only door for a narrowed `k9.certify`/`k9.givexp` viewer), and the
online-players list — and merging them needs guessing logic that does not
exist today.

### A regression this work introduced, and caught

Merging Help and Commands spliced out the router branch between them, which
was the Partnerships screen — the tab dead-ended into the fallback. Caught
by `tablet_partnerships_spec.js` in the same change and fixed before the
commit. Recorded because it is the exact hazard of this kind of work.

### Item I: the re-measure this plan asked for

Now that A–H have landed, here is what each Guided Flow actually contains,
read from the source:

| Flow | What it is built from |
|---|---|
| Set Up a New Handler | person picker → certification list/detail → role control → person features → summary |
| Offboard | person picker → certification list → access controls → audit → summary |
| Problem Player | person picker → access controls → audit → summary |
| Tune the Server | runtime features → runtime tunables → cert tiers → XP ranks → shop items |

**The first three are now, step for step, the Person screen.** Every part
they sequence is rendered on that one screen, in that order, for whoever is
open on it. They amount to "open the person from Console, then work down
the page" — with their own person picker bolted on, which is the last pair
of duplicate search boxes on the tablet.

**The fourth is thinner but not empty.** Its five steps used to span five
tabs; after F and G they span three (Runtime Control, Catalogs, K9 Supply
Shop). It still sequences work across tabs, which the other three no longer
do.

**This remains the owner's call, as §4's item I said.** Retiring the three
person-shaped flows would remove the last two duplicate search boxes, one
tab and roughly 90 strings, and would cost a walkthrough that a
never-certified-anyone operator might still want. Keeping the Tuning flow
alone is a coherent middle: it is the one that still crosses screens.

## 9. Item I, decided and done

The owner's answer, in full: *"continue i trust your decision."*

**Decision: retire the three person-shaped flows, keep Tune the Server.**
Reasoning is §8's re-measure, unchanged — Set Up a New Handler, Offboard and
Problem Player had each become the Person screen's own sections, in that same
order, reached through a second person-search box. Tuning is the one that
still sequences work no single screen holds.

Two things followed from having one flow left, neither of which §4 anticipated:

- **The hub went too.** It existed to choose between four cards. A hub holding
  one card is a click that asks no question, so the tab now opens the flow
  directly.
- **The tab was renamed** from "Guided Flows" to **Server Tuning**. A tab named
  after a plural category, holding exactly one thing, misdescribes itself.

### Measured, before and after, the same way both times

| | Before (`e978ae3`) | After |
|---|---|---|
| `build*Screen()` functions | 21 | **17** |
| `mk('input'` call sites | 42 | **40** |
| Tabs (High Command) | 11 | 11 |
| Keys in the `tablet` locale group | 1,085 | **1,011** |
| Lines in `html/tablet.js` | 13,895 | **12,916** |

Note the tab count did **not** move: §8 guessed "one tab" would go, which was
only ever true if all four flows went. Keeping Tuning keeps the tab. What did
move is **979 lines** and **74 strings**, and the last two duplicate person
search boxes on the tablet are gone — which was item C's actual goal all along.

### What the retirement surfaced

Three player-facing help strings still described the retired flows, and were
rewritten rather than deleted:

- `help_start_high_command_1` told a new administrator to *"Open the Guided
  Flows tab first"* — the first instruction a new owner reads. It now points at
  the Command Console.
- `help_start_high_command_2` told them to use *"Set Up a New Handler"*. It now
  describes working down the Person screen.
- `help_task_hc_toggle_feature_3` named the old tab. It now names Server Tuning.

This is the same defect class as the README's stale "Help tab" references, and
it is worth naming as a pattern: **retiring a screen is never just deleting the
screen.** The instructions pointing at it are the part players actually read.

### What was deliberately *not* lost

`tablet_guided_flows_spec.js` had two escaping proofs that went through the
retired flows (a malicious person name / department / feature label, and a
malicious ped label). Those vectors are still covered — `tablet_xss_spec.js`
exercises them directly against the Person screen, which is where those strings
are actually rendered now. The flow-shaped copies were duplicates of that
coverage, not the coverage itself. **Confirmed before deleting them, not
assumed.**

One test guard needed moving: `citationintegrity_spec.lua` asserted the tablet
carried `> 900` string keys as a "did the scan silently break" floor. Removing
74 keys landed it on exactly 900. The floor is now 800, with a comment saying
what it is for — a floor set just under the current total turns every honest
removal into a red build. The real contract it sits next to (same size, same
keys, both directions, across all three files) is untouched and still passing.
