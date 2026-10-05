> **HISTORICAL RECORD — NOT CURRENT GUIDANCE.**
>
> This document is the engineering discipline rules this resource was built under. The work it describes has been
> built, and in places has since been changed or removed. It is kept because
> it explains WHY things are shaped the way they are, which the code alone
> cannot say — but it does not describe how the resource works today, and it
> is not a specification anyone should implement from.
>
> For how the resource actually works now, see `README.md` (setup and
> features), `DEVELOPER_REFERENCE.md` (the code), and `DIAGNOSTIC_CHECKS.md`
> (the `/k9debug` report). Archived 2026-09-02.

---

# K9 Discipline Gating — Spec

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


Status: DRAFT for coder review. No production code accompanies this file.
Author: product (this pass). Scope: `john-k9` only.

## 0. Finding, verified

Confirmed by direct read of the current tree (2026-08-26):

- `Config.K9Specializations` (`config.lua:1258`) defines exactly three keys:
  `narcotics`, `explosives`, `patrol`, each `{ label = '...' }`. A certifier
  grants them via the tablet; they persist in `k9_certification_specializations`
  (`sql/install.sql:271`, `sql/migrations/0006_add_k9_certification_lifecycle.sql:345`);
  `HasSpecialization(citizenid, jobName, key)` (`server/certifications/:4325`)
  is the one real server-side read.
- The **only** production consumer of `HasSpecialization` outside
  plumbing (certtiers.lua/certifications.lua/datastore.lua) is
  `server/equipmentshop.lua:2329`, gating a single optional
  `requiredSpecialization` field on a shop catalog item.
- ~~`server/search.lua` never calls `HasSpecialization` at all.~~
  **OUT OF DATE — this was fixed by the specialization-categories pass
  (2026-08-26), after this document was written.** `server/search.lua` now
  does call `HasSpecialization`, resolves the searcher's held categories,
  and `SumContrabandWeight` takes those categories and skips any item whose
  `category` the dog does not hold. Search by name rather than line number:
  the call site and `SumContrabandWeight`'s `heldCategories` parameter are
  both in `server/search.lua`.

  `Config.SearchContrabandItems` now accepts **two entry shapes in one
  table**: a plain array entry (`'weed_bud'`) meaning UNCATEGORISED, and a
  keyed entry (`coke_brick = 'narcotics'`) meaning categorised. An
  uncategorised item is found by every dog; a categorised one only by a dog
  holding that specialization.

  `ContrabandItemSet` no longer exists under that name at all — do not go
  looking for it.
- **The observable behaviour on a stock install is still what the next
  bullet described, but for a different reason, and it is now the owner's
  choice rather than a limitation.** The shipped
  `Config.SearchContrabandItems` deliberately lists all four placeholder
  items as UNCATEGORISED (shape 1), specifically so an upgrading server's
  search results do not change until somebody opts an item in. So yes — out
  of the box, an "Explosives detection" dog and a "Narcotics detection" dog
  still produce identical search results. The difference is that the
  mechanism is now real and wired: categorise an item in config and the
  specializations immediately start mattering. It is no longer "a label
  with no gameplay behind it"; it is a label whose gameplay the default
  config does not yet switch on.
- Separately, `bite_hold_and_takedown` — a **capability on
  `Config.CertificationTiers`** (`config.lua:630-645`), not a
  specialization — is the one real, enforced gate on bite/takedown, wired
  in `server/combat.lua:1576` via `TierCapabilityPermits`. `patrol`
  ("Patrol / apprehension") gates nothing anywhere in the codebase.
- `Config.FindAlerts.reactionsByAlertTier` (`config.lua:2022`) already
  carries a `{ sit, sound }` shape per **size** tier (`whine`,
  `aggressive_bark`) — consumed by `client/findalert.lua:140` and
  `server/findalert.lua:274` (`DispatchFindAlertReaction`). It has no
  discipline dimension.
- `BroadcastContrabandAlert` (`server/search.lua:659`, called at
  `server/search.lua:1726`) plays the alert-tier string **directly as a
  sound name** on the searched entity, to every player within
  `Config.SearchZones.alertBroadcastRadius` (hard-ceilinged at 200m). It
  also has no discipline dimension and no specialization check.

Everything below is designed against this confirmed baseline.

## 1. Goal

Make the three K9 disciplines mean something distinct and real:

- Which contraband items belong to which discipline (config, owner-editable).
- What a discipline actually grants the handler who holds it (gate design).
- How the K9's own body reacts differently per discipline (passive vs
  active alert).
- Whether apprehension access should route through `patrol` instead of
  (or in addition to) certification tier.

...without breaking a single server that upgrades and touches nothing.

## 2. Scope

**In scope:**
- New config shape mapping contraband items to a discipline.
- Server-side enforcement of what a discipline gates (search alert layer
  only — see §4 for exactly what is and isn't touched).
- Discipline-aware reaction shape (`sit`/`sound`) with a defined rule for
  a multi-discipline find.
- A decision on `patrol` vs `bite_hold_and_takedown`, plus what happens to
  servers already using the tier capability.
- Migration/compatibility behavior and the first-boot operator experience.
- Locale keys for any new framework-owned player-facing copy.

**Out of scope (non-goals for this pass):**
- Replacing the placeholder item names in `Config.SearchContrabandItems`
  with real server economy items — that is a separate config-validator/
  economy pass (`DEVELOPER_REFERENCE.md:544`), unaffected by this spec.
- Adding new specializations beyond the existing three.
- Any new admin command or tablet screen beyond the roster/picker copy
  called out in §7.
- ESX/QBCore support — this resource is Qbox-only already; not reopened here.
- Redesigning `bite_hold_and_takedown` itself, beyond the routing decision
  in §5.
- A visual (non-audio) bystander cue for a passive/explosives alert — see
  §4.4, flagged as a future idea, not required here.

## 3. Config shape — `Config.ContrabandDisciplines`

Add a **new**, optional table. `Config.SearchContrabandItems` (the flat
list) is not removed, not renamed, and not deprecated in the sense of
"stop using it" — it remains the authoritative list of *which item names
count as contraband at all*. The new table only answers a second,
independent question: *which discipline (if any) does this item belong
to.*

```lua
-- Config.ContrabandDisciplines -- OPTIONAL. Maps an item name to a
-- discipline key. A discipline key must be either the literal string
-- 'general' (see below) or a key that exists in Config.K9Specializations
-- at the time this file loads.
--
-- An item name may appear here WITHOUT also appearing in
-- Config.SearchContrabandItems, and vice versa -- the CONTRABAND set at
-- boot is the UNION of both tables' item names. You do not need to list
-- an item twice.
--
-- Add freely. Nothing here is stored in the database -- unlike
-- Config.K9Specializations' keys, an item name here is never referenced
-- by a saved row, so renaming or removing an entry is always safe.
Config.ContrabandDisciplines = {
    weed_bud    = 'narcotics',
    coke_brick  = 'narcotics',
    meth_bag    = 'narcotics',
    -- c4_device   = 'explosives',
    -- ied_device  = 'explosives',

    -- weapon_pistol deliberately left OUT of this table below -- it stays
    -- 'general' (see the rule immediately under this block) until you
    -- decide it belongs to a real discipline on your server.
}
```

**What happens to an item with no category (this is the load-bearing rule
for backward compatibility):**

Any contraband item name — whether from `Config.SearchContrabandItems`,
from `Config.ContrabandDisciplines` itself with no explicit gate applying
to it, or simply never mentioned in `Config.ContrabandDisciplines` at
all — is treated as discipline **`'general'`**. `'general'` is not a real
specialization, cannot be granted, requires no certification, and is
**always** alert-eligible for any K9 who currently has ordinary K9 search
access (`HasK9Access`, unchanged). This is exactly today's behavior for
every item, preserved byte-for-byte as the default.

**A server that adds `Config.ContrabandDisciplines` = `nil` / an empty
table / never touches this file at all sees zero behavior change from
this feature, for any item, for any K9, ever.** This is acceptance
criterion §8.1 below and is the single hardest constraint on this design.

**Validation (clamp-and-warn, never assert):** at resource start, for
every `Config.ContrabandDisciplines[item] = disciplineKey` entry, if
`disciplineKey` is not `'general'` and not a live key in
`Config.K9Specializations`, clamp that single entry to `'general'` and
print one console warning naming the item and the bad key. This must
never raise and must never prevent any other config table below it in
`config.lua` from loading — the exact "clamp-and-warn, never a bare
assert" convention this codebase already applies everywhere else (see
e.g. `client/agility.lua:96`, `server/xptiers.lua:598`,
`client/pursuitsprint.lua:198`).

**Reserved word:** `'general'` is owned by this feature. If an owner ever
defines `Config.K9Specializations.general`, that entry is invalid — warn
once at boot, and do not let it shadow the built-in `'general'` bucket
(the built-in one always wins). This should never come up in practice,
but a hand-edited config is exactly the place a collision like this
happens by accident.

## 4. What a discipline actually buys — recommendation

### 4.1 The two options as posed, and why I am rejecting hard gate

**Hard gate** (uncertified dog finds nothing in that category) is
rejected. Concretely, on a server with exactly one K9 handler who has
never been given the `explosives` specialization (the literal, guaranteed
starting state of every server that adopts this feature — nobody starts
pre-specialized), hard-gating explosives means **no bomb is ever found on
that server, full stop, for as long as nobody happens to hold that
specialization.** That is not "an unspecialized dog is less useful," it
is "a whole category of RP content is silently undetectable," and it
fails this task's own constraint from §A: *"a server that never touches
[the config] must not break, and must not silently start finding
nothing."* Hard-gating a discipline the moment an owner opts into
categorizing items is exactly that failure, just one config edit removed
instead of zero.

### 4.2 Recommendation: soft gate, precisely scoped

Soft gate, but I want to be exact about *what* "finds it" and "actionable
alert" mean, because the current code has **three separate outputs** from
one search, and they should not all move together:

1. **The requester's own private result** — `{ ok, contrabandFound,
   totalWeight, alertTier }`, returned only to the officer who performed
   the search (`server/search.lua:1837`), already gated by `HasK9Access`
   and live proximity. **Unaffected by discipline, always.** This channel
   already reports the true number regardless of specialization today,
   and discipline gating must not change that — an officer who searches a
   car is never told "clean" when it is not, no matter what their dog is
   or isn't certified in. Weakening this would literally recreate the
   "silently finding nothing" failure from §A, just moved one layer down.

2. **The bystander broadcast** (`BroadcastContrabandAlert`, currently
   fires unconditionally for any non-clean tier) — **this is the
   "actionable alert" the task is asking about.** Gated by discipline:
   only fires for the portion of a find whose discipline the searching K9
   currently holds (`'general'` always counts, same as today).

3. **The K9's own physical reaction** (`DispatchFindAlertReaction`,
   `server/findalert.lua:263`) — gated identically to (2), for the same
   reason: an untrained dog does not perform a trained final response for
   an odor it was never conditioned on, but its handler (the officer
   holding the search result) still sees what's actually there.

**What this means for a brand-new dog on day one:** identical to today.
A freshly certified handler with zero specializations still finds and
gets alerted on every `'general'`-category item exactly as before. The
only change is for items an owner has *deliberately* categorized as
`narcotics`/`explosives` — for those, the new dog's search still succeeds
and still reports the true result to them, but the bark/sit and the
bystander broadcast wait until they earn the specialization. This is an
incentive, not a lockout.

**What this means for a server with exactly one K9:** nothing changes
unless the owner (a) populates `Config.ContrabandDisciplines` and (b)
that one handler is not certified in the discipline they used. Even then,
the handler still completes every search correctly and privately knows
the truth — they just don't get the ceremony until they train up, which
an owner running a one-K9 server can grant to that one handler in under a
minute from the tablet if they don't want the friction at all. Nothing is
ever permanently undetectable, unlike hard gate.

### 4.3 Multi-discipline find — precedence rule

`SumContrabandWeight` must be extended to accumulate **per-discipline**
subtotals during the same recursive scan it already performs (narcotics
weight, explosives weight, general weight), not just the one grand total
it computes today. The grand total (sum of all three) keeps being what
channel (1) above reports — unchanged.

For channels (2) and (3), define **eligible weight** = the sum of every
discipline's subtotal where that discipline is `'general'` **or** the
searching K9 currently holds it. Then:

- If **eligible explosives weight > 0**: the reaction/broadcast use the
  **explosives passive shape** (§5), regardless of how much narcotics or
  general weight is also present, and regardless of which discipline has
  the larger weight. **This is a firm rule, not a tiebreak by size.**
  Rationale: the entire reason a passive discipline exists is that an
  active response (bark/scratch) near a device is dangerous — letting a
  bigger narcotics haul in the same trunk override that into an audible
  bark defeats the reason the passive discipline exists at all. This is a
  design opinion I'm making explicitly, not something the current code
  implies — argue with it if it's wrong for your server, but I think it's
  the only defensible default.
- Else if **eligible narcotics weight > 0**: use the narcotics active
  shape (today's existing `whine`/`aggressive_bark` sound mapping,
  unchanged).
- Else if **eligible general weight > 0** (i.e. nothing discipline-gated
  was eligible, but plain uncategorized contraband was still found): use
  today's unmodified default `reactionsByAlertTier` shape, computed from
  general weight only.
- Else (contraband exists — `contrabandFound = true` in the private
  result — but every bit of it belongs to a discipline this K9 does not
  hold, and there is no general-category weight): **no broadcast, no
  physical reaction, at all.** This is the "no actionable alert" case the
  soft gate exists to produce. The requester still privately knows.

The **tier** (`whine` vs `aggressive_bark`) used for whichever shape wins
above is computed from the *eligible* weight only — an uncertified K9's
presence in the trunk must never leak how much of the discipline-gated
material is actually there via reaction intensity.

### 4.4 The broadcast must not un-do the point of "passive"

One thing not called out in the original ask, and I think it's a real
gap if left alone: `BroadcastContrabandAlert` plays the alert-tier string
**as an audible sound** to every player within the broadcast radius
(`server/search.lua:659`, `client's PlaySoundOnNetworkEntity` in
`client/search.lua:537`). If explosives' reaction is passive (no sound,
per §5) but the bystander broadcast still plays a bark sound for the
exact same explosives find, the feature contradicts itself one layer up —
everyone within 15m still audibly hears "the dog found something," which
is precisely the noise a real EDD's passive alert is trained to avoid
producing.

**Recommendation:** when the winning discipline for a find is explosives
(per §4.3's rule), suppress the bystander sound broadcast entirely rather
than inventing a new "silent alert" sound asset this pass. The broadcast
call itself can still fire for future extensibility (e.g. a future
dispatch blip), but it must not call `PlaySoundOnNetworkEntity` with any
of the existing bark-family sound names for this case. A visual-only
bystander cue for a passive alert is a reasonable future idea but is
explicitly a non-goal here (§2) — don't build it as a side effect of this
pass.

## 5. Passive vs active alert shape

Add `Config.FindAlerts.reactionsByDiscipline`, layered **on top of** the
existing `reactionsByAlertTier` (which stays exactly as-is and remains
the fallback for `'general'` and for any discipline with no override
here):

```lua
Config.FindAlerts.reactionsByDiscipline = {
    explosives = {
        -- Passive final response. NEVER a sound, at any tier, no matter
        -- how large the find -- a real EDD does not escalate to noise
        -- for a bigger device. `sit = true` alone (freeze/stare) is the
        -- entire trained response.
        whine           = { sit = true, sound = nil },
        aggressive_bark = { sit = true, sound = nil },
    },
    narcotics = {
        -- Active final response -- same shape as today's shared default,
        -- restated explicitly here so a future change to the SHARED
        -- default table cannot accidentally also change narcotics'
        -- behavior when that wasn't the intent.
        whine           = { sit = true, sound = 'Bark_Alert' },
        aggressive_bark = { sit = true, sound = 'Bark_Aggressive' },
    },
    -- 'patrol' and 'general' deliberately absent -- they fall through to
    -- Config.FindAlerts.reactionsByAlertTier, unchanged.
}
```

`DispatchFindAlertReaction` (`server/findalert.lua:263`) is extended to
take the winning discipline computed in §4.3 and look up
`reactionsByDiscipline[discipline][alertTier]` first, falling back to
`reactionsByAlertTier[alertTier]` when there's no per-discipline row —
never the reverse, and never a silent guess when a discipline resolves to
`nil` (same "fails closed to silence, never guesses" posture the existing
header for this table already documents, `config.lua:2009-2013`).

## 6. `patrol` vs `bite_hold_and_takedown` — recommendation

**Recommendation: retire `patrol` as a gate candidate entirely. Keep
`bite_hold_and_takedown` on `Config.CertificationTiers` as the one and
only apprehension gate, unchanged.**

Reasoning: this is already the *only* one of the two that is real and
enforced (`server/combat.lua:1576`). More importantly, the two systems
model genuinely different things and tier is the correct one for this
question:

- `Config.K9Specializations`' own header describes specializations as
  trained abilities granted **"on top of an existing active
  certification"** — optional, additive, orthogonal skills (narcotics
  odor, explosives odor). Apprehension is not that: it is not a scent a
  dog is trained on top of its base competency, it's a liability/
  competency escalation tied to how experienced and trusted the handler-
  dog team is — which is exactly what a **rank/tier ladder** (trainee →
  certified → senior) already models, and is precisely what
  `CertificationTiers`' own header says it's for.
- Making `patrol` **also** gate bite/takedown (AND with tier) adds a
  second certifier step for zero behavioral benefit and is the "two
  systems answering one question" bug the task itself flags as the
  likely real problem — I agree with that read.
- Making `patrol` **replace** tier as the sole gate is worse: any server
  that has already ticked `bite_hold_and_takedown` on a tier
  (`Config.CertificationTiers[n].capabilities`) would have that
  configuration go inert on upgrade with **no warning**, silently
  changing who can bite/take down — a direct violation of §7's migration
  constraint.

**What happens to `patrol` itself:** it is not removed, renamed, or
stripped from anyone who already holds it — `K9Specializations` keys are
explicitly never-rename-once-granted (`config.lua:1256`), and this spec
respects that fully. It simply continues to exist as a grantable,
displayed, stored label that gates nothing, exactly as it does today —
this spec does not change its behavior at all, only documents plainly
(§7, tablet copy) that it isn't wired to anything, so nobody mistakes it
for a live gate going forward.

If a future pass wants `patrol` to mean something, that's a separate,
deliberate design decision — not a side effect of this one.

## 7. Migration and first-boot experience

**A server that changes nothing:** zero behavior change, anywhere,
including for handlers who already hold `narcotics`/`explosives`/`patrol`
specializations under the current (non-functional) system. Their grants
remain exactly as stored; they simply begin to matter the moment (and
only the moment) the owner populates `Config.ContrabandDisciplines`.

**On resource start**, print one console line (matching this codebase's
existing `print('[John-K9] ...')` convention for operator diagnostics,
e.g. `server/certifications/`'s own `QueryCertificationRecord` failure
print) — **not** a chat message or tablet toast, since this is boot-time
operator information, not a player-facing event:

- If `Config.ContrabandDisciplines` is absent or empty: print that every
  contraband item is being treated as `'general'`, exactly like before
  this feature existed, and that specializations remain purely
  informational until the owner opts in — point at the README section
  covering this.
- For each invalid discipline key found during validation (§3): one
  console warning per bad entry, naming the item and the key, stating it
  was clamped to `'general'`.

This print is a console/operator diagnostic, not player-facing copy, so
it is **not** required to go through `locales/en.json` — consistent with
every other `print('[John-K9] ...')` call already in this codebase.

**Player-facing copy that IS new** and does need locale keys — proposed
names and text, to be added under a new top-level `"disciplines"`
namespace in `locales/en.json` (matching the existing per-file namespace
convention, e.g. `"findalert"`, `"search"`):

- `disciplines.tablet_gate_note_soft` — shown next to a discipline in the
  tablet's specialization picker/roster (wherever `narcotics`/
  `explosives` are already listed): *"Only a handler certified in this
  discipline triggers an official alert on a matching find. Any K9 can
  still complete the search itself."*
- `disciplines.tablet_non_detection_note` — shown for any specialization
  key that no item in `Config.ContrabandDisciplines` currently maps to
  (this covers `patrol` today, without hardcoding its name — a future
  owner-added specialization that also isn't wired to detection gets the
  same honest note for free): *"This specialization is not tied to
  contraband detection."*

Both are computed from config state (which keys are actually referenced
in `Config.ContrabandDisciplines`), never hardcoded to the literal string
`'patrol'` — matching this codebase's existing philosophy of never
special-casing an operator-named value.

**Database:** no schema migration required. `k9_certification_specializations`,
its keys, and `HasSpecialization`/`GrantSpecialization` are entirely
unchanged by this spec. `Config.ContrabandDisciplines` keys are item
names, never persisted, so they carry none of the "never rename" risk
`K9Specializations` keys do.

**Equipment shop:** `requiredSpecialization` (`server/equipmentshop.lua:2329`)
is a pre-existing, independent consumer of `HasSpecialization` and is not
touched by this spec at all.

## 8. Acceptance criteria

Numbered so a reviewer can check each independently. Negative
("must NOT") items are included deliberately — do not skip them.

1. A server with no `Config.ContrabandDisciplines` table (or an empty
   one) produces byte-identical search, alert-broadcast, and reaction
   behavior to the pre-change code, for every item and every K9,
   regardless of any specialization anyone holds.
2. An item present in neither `Config.SearchContrabandItems` nor
   `Config.ContrabandDisciplines` is not contraband (unchanged from
   today). An item present in `Config.ContrabandDisciplines` but not in
   `Config.SearchContrabandItems` IS still treated as contraband (the
   union rule, §3).
3. An item with no entry in `Config.ContrabandDisciplines`, or an entry
   whose value is invalid, resolves to discipline `'general'`.
4. `'general'` is always alert-eligible for a K9 with basic search
   access, with no specialization requirement, unconditionally.
5. An invalid discipline key in `Config.ContrabandDisciplines` is
   clamped to `'general'` and produces exactly one console warning naming
   the item — it must never raise/assert, and must never prevent any
   other config table from loading.
6. `Config.K9Specializations.general`, if ever defined by an owner, is
   invalid, warned about once, and never shadows the built-in `'general'`
   bucket.
7. The requesting officer's own search result (`ok`, `contrabandFound`,
   `totalWeight`, `alertTier` as returned by
   `john-k9:server:searchTarget`) reflects the true, full,
   cross-discipline weight, unconditionally — **must NOT** vary with the
   searching K9's specializations, ever.
8. The `k9_search_log` audit row records the true, full weight/tier for
   every completed search, regardless of discipline eligibility —
   **must NOT** be filtered or reduced by discipline.
9. The bystander broadcast (`BroadcastContrabandAlert`) and the K9's own
   physical reaction (`DispatchFindAlertReaction`) fire only for
   discipline-eligible weight (`'general'` plus any discipline the
   searching K9 currently holds). A find composed entirely of
   discipline-gated weight the K9 does NOT hold produces **no** broadcast
   and **no** reaction, even though the private result in (7) still
   correctly reports `contrabandFound = true`.
10. When eligible weight spans multiple disciplines, the reaction/
    broadcast tier is computed from the sum of eligible weight only —
    **must NOT** include a discipline the K9 isn't certified in, even
    when computing tier size.
11. Whenever eligible explosives weight > 0 for a find, the reaction uses
    the passive shape (`sit = true`, `sound = nil`) at every tier — this
    **must NOT** be overridden by a larger eligible narcotics/general
    weight also present in the same find.
12. The bystander broadcast for an explosives-winning find **must NOT**
    play any bark-family sound (`Bark_Alert`, `Bark_Aggressive`, or the
    literal `whine`/`aggressive_bark` tier names as sound names).
13. A narcotics-only-eligible find (no eligible explosives weight) uses
    the existing active bark/sit shape, unchanged from today.
14. A general-only-eligible find uses today's unmodified
    `reactionsByAlertTier` shape, unchanged.
15. `patrol` continues to exist, continues to be grantable/displayed, and
    no existing grant of it is altered or revoked by this change — it
    gates nothing, exactly as today.
16. Bite/takedown access continues to be governed exclusively by the
    `bite_hold_and_takedown` tier capability (`server/combat.lua:1576`) —
    **must NOT** additionally require, or be replaceable by, the `patrol`
    specialization.
17. No termination path (releasing a bite, ending a search, standing
    down, etc.) is gated by a discipline or specialization check under
    any part of this spec — only the *start* of a search's ceremonial
    layer is ever gated.
18. Every discipline check that affects a broadcast or a reaction is
    enforced server-side (`server/search.lua` / `server/findalert.lua`) —
    **must NOT** rely on a client-reported discipline or client-only
    suppression as the actual gate.
19. All new framework-owned player-facing copy is added under
    `locales/en.json` (proposed: a new `"disciplines"` namespace, §7) —
    **must NOT** introduce a new inline English string literal in any
    `.lua` file for player-visible text. Console-only operator
    diagnostics (§7) are exempt, consistent with existing
    `print('[John-K9] ...')` calls elsewhere in this codebase.
20. On an update where the owner changes no config, resource start
    produces exactly the one documented console advisory (§7) and no
    other observable change — no new chat message, no new toast, no
    change to any live search/certification/shop flow.
21. `requiredSpecialization` gating in `server/equipmentshop.lua` and its
    existing tests are unmodified and continue to pass unchanged.
22. No schema migration is required against `k9_certification_specializations`,
    `HasSpecialization`, or `GrantSpecialization` for this feature to work.
23. No code path may cause `contrabandFound` to be `false`, or
    `totalWeight` to be reduced, solely because the searching K9 lacks a
    specialization (this is the explicit rejection of hard gate — see
    §4.1 — restated as a checkable negative).

## 9. Open questions (flagging, not deciding silently)

1. **Probable-cause record-keeping.** The task's own framing ("the thing
   that gives an officer probable cause") implies RP/court integrations
   may care whether a given search's alert was discipline-qualified, not
   just whether contraband existed. I'd recommend adding a boolean (e.g.
   `alertEligible`) to both the `searchTarget` callback's return and the
   `k9_search_log` row, so this is queryable later without a second
   migration. This touches `sql/` schema, which isn't mine to spec
   unilaterally — flagging for config-validator / whoever owns the DB
   migrations before a coder commits to a column shape.
2. **`'general'` as the sentinel name.** Plain enough for a non-programmer
   to read, but it's a naming choice — `'uncategorized'` or `nil` are
   viable alternatives. I picked `'general'` because it reads naturally
   in the tablet copy ("General / no discipline required"); not a hill to
   die on.
3. **Explosives-always-wins precedence (§4.3).** This is my judgment call,
   not something derivable from the existing code, and it does mean a
   dual-certified (narcotics + explosives) K9's reaction is always
   passive the instant ANY eligible explosives weight is present, even a
   trivial amount next to a huge drug haul. I think that's correct and
   safety-motivated, but it's exactly the kind of call this task asked me
   to flag rather than bury — argue with it before a coder builds it.
4. **Silent-alert bystander cue (§4.4).** I'm recommending "no sound, no
   replacement visual" as the simplest correct behavior for this pass. A
   later pass could add a dispatch-only silent ping; explicitly a
   non-goal here so it doesn't sneak in as a side effect.
5. **Whether `patrol` should eventually be repurposed** (rather than
   staying permanently inert) is a legitimate future idea, but is a
   separate decision from this spec and shouldn't be decided as a side
   effect of closing this finding.

## 10. Files this touches (for implementers)

- `config.lua` — new `Config.ContrabandDisciplines` table (§3); new
  `Config.FindAlerts.reactionsByDiscipline` table (§5). No existing key
  renamed or removed.
- `server/search.lua` — `SumContrabandWeight` gains per-discipline
  subtotals; `HandleSearchTarget`'s alert-broadcast call site
  (`server/search.lua:1724-1727`) gains the eligibility computation from
  §4.3; `BroadcastContrabandAlert` (`server/search.lua:659`) gains the
  suppression rule from §4.4.
- `server/findalert.lua` — `DispatchFindAlertReaction`
  (`server/findalert.lua:263`) gains the discipline-aware lookup from §5,
  fed by the same eligibility computation as the broadcast (should be one
  shared helper, not two independently-maintained copies of the same
  logic — the existing codebase's own "extracted... so the invariant
  lives next to the code" convention, see `server/search.lua:618`,
  applies here too).
- `client/findalert.lua` — reads the same `alertTier`/reaction shape it
  already does; no discipline-specific client logic needed since the
  server already resolves which shape to send (server-side enforcement,
  criterion §8 item 18).
- `client/tablet.lua` / `html/tablet.js` — surfaces
  `disciplines.tablet_gate_note_soft` / `disciplines.tablet_non_detection_note`
  next to each specialization, computed from whether
  `Config.ContrabandDisciplines` references that key (§7).
- `locales/en.json` — new `"disciplines"` namespace (§7).
- No changes required to `server/certifications/`, `server/certtiers.lua`,
  `server/equipmentshop.lua`, `server/combat.lua`, or any `sql/` file
  (pending the open question in §9 item 1).
