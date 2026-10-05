> **HISTORICAL RECORD — NOT CURRENT GUIDANCE.**
>
> This document is the design for the K9 and handler rosters. The work it describes has been
> built, and in places has since been changed or removed. It is kept because
> it explains WHY things are shaped the way they are, which the code alone
> cannot say — but it does not describe how the resource works today, and it
> is not a specification anyone should implement from.
>
> For how the resource actually works now, see `README.md` (setup and
> features), `DEVELOPER_REFERENCE.md` (the code), and `DIAGNOSTIC_CHECKS.md`
> (the `/k9debug` report). Archived 2026-09-02.

---

# K9 Command Tablet — Rosters Spec

Author: product (spec pass) · Date: 2026-08-26
Scope: `john-k9` — new roster surfaces on the K9 Command Tablet, plus the
existing Console/Person screen they must open into.

This is a planning document only. No implementation code was written or
changed while producing it. Every claim below about what exists today was
checked directly against the named file/line, not assumed.

---

## 0. The ask, restated, across three messages

1. *"make it in the tablet where there is a roster where we can assign
   callsigns see list of hired k9s and full menu to fire promote etc"* /
   *"Also a separate roster for handlers same thing"* — two lists (K9s,
   Handlers), each showing who's on it, with callsign assignment and a full
   personnel-action menu (hire/fire/promote/demote) reachable from the list.
2. *"The roster should be able to be where we can also assign roles sub
   features features permissions etc"* / *"Like click there profile and it
   opens a menu"* — clicking a roster row must open ONE menu that covers
   everything you might do to that person, not send the operator hunting
   across screens.
3. *"Also in the roster be able to reorder them by rank."*

**The single most important structural decision this spec makes, up front:**
the "menu" in #2 is not a new screen. It is `buildPersonScreen()`
(`html/tablet.js` line 5717), already reached from the Console tab's search
today, and about to gain a second entry point from the in-flight
online-players picker (per the coordinator: another agent is wiring a
connected-players list that opens this same screen). **The roster rows are a
third entry point into that same screen, not a fourth screen of their own.**
Building a second person-detail screen for the roster would mean two places
that both act on a citizenid, which will drift — one gets a guard the other
doesn't, one shows a field the other doesn't. Extend `buildPersonScreen()`;
do not fork it. If a future pass finds a real reason a roster-opened view
needs to differ from a console-opened one, that is a reason to add a mode
flag to the one screen, not to duplicate it.

---

## 1. What exists today — read this before writing anything

Verified directly, file/line:

- **The roster today is a search, not a personnel list.**
  `tablet:requestRoster` (`server/tablet.lua` line 1539, handler body from
  1556) does one bounded, indexed query per configured department
  (`Config.Departments`), filtered by free-text query, returning `{
  citizenid, name, departmentLabel, certified, xp, tierLabel }`. It has no
  concept of K9-vs-Handler, no callsign, and no action buttons of its own —
  clicking a result opens `buildPersonScreen()`.
- **Hire/fire/promote/demote already exist as certification primitives**,
  but are not evenly wired to the tablet:
  - Hire = `GrantCertificationForTablet` (`server/certifications/:2510`)
    → `tablet:certify` → **fully wired**, works online and offline.
  - Promote/demote = `SetCertificationTierForTablet` (`:3376`) →
    `tablet:setCertificationTier` → **fully wired**, works online and
    offline, tiers are `Config.CertificationTiers` (`trainee` → `certified`
    → `senior`, ordinal 1/2/3, `config.lua:641`).
  - Renew = `RenewCertificationForTablet` (`:3719`) → `tablet:renewCertification`
    → **fully wired**.
  - Specializations = `GrantSpecializationForTablet`/`RevokeSpecializationForTablet`
    (`:4010`/`:4204`) → `tablet:grantSpecialization`/`tablet:revokeSpecialization`
    → **fully wired**, online-only by design (no offline grant path — see
    `cmdref_k9specialize_needs` in `locales/en.json`).
  - **Fire = genuinely broken today, not just unexposed.**
    `html/tablet.js`'s `handlePersonCertAction()` (line 6168) already has a
    `'decertify'` branch that calls `runMutation('tablet:decertify', ...)`
    — but **no server-side callback named `john-k9:server:tabletDecertify`
    exists anywhere in this resource** (confirmed by a resource-wide grep).
    Clicking Decertify on the person screen today calls a callback nobody
    ever registered. This spec's Fire action is not new scope — it's
    finishing a button that already ships, by adding the one missing
    `RevokeCertificationForTablet` wrapper, built the same way every other
    `*ForTablet` wrapper already is (resolve online-vs-offline, delegate to
    `RevokeCertification`/`RevokeCertificationOffline` unchanged, no
    duplicated authority).
- **The person screen already has three of the four things the second ask
  names**, all high-command-gated (`buildPersonScreen`, lines 5770–5779):
  - **Permissions** = `buildCapabilityList` / `person_capabilities_heading`
    — the four named `Config.Permissions` keys (`k9.access`, `k9.certify`,
    `k9.audit`, `k9.givexp`) plus the live permission-key catalog, real
    checkboxes wired to `tablet:grantPermission`/`tablet:revokePermission`.
  - **Features** = `buildPersonFeaturesSection` / `person_features_heading`
    — per-person `Config.FeatureControl.RequireGrant` grants
    (`feature.<Name>`) and blocks (`block.<Name>`), already a full
    searchable table with grant/revoke actions.
  - **A different "role"** = `buildRoleControl` / `role_heading` — **this is
    NOT the K9-vs-Handler roster role this spec introduces.** It assigns/
    reverts the *ped model* (`tablet:assignK9Role` → `ApplyK9PedRole`,
    `tablet:revertK9Ped`) — i.e. whether this citizenid is currently walking
    around with a dog body and `k9.access`. **Naming collision, called out
    explicitly so nobody builds against the wrong "role":** this resource
    already uses the word "role" for two different things
    (`HasK9Role`/`ApplyK9PedRole`'s ped-and-access role, existing; the
    roster's K9-vs-Handler personnel role, new). §3 below names the new one
    something else in code (`personnelRole`) specifically to avoid this
    colliding with `role_heading`/`buildRoleControl` in the UI or the API.
  - **"Sub-features"** — not an existing term in this codebase. Two real
    candidates exist; they are not interchangeable, and the ask doesn't say
    which:
    1. **Specializations** (`GrantSpecializationForTablet` above) — a named,
       per-PERSON unlock within their certification (e.g. a scent
       specialty). Already has full tablet-callback plumbing
       (`tablet:grantSpecialization`/`revokeSpecialization`) and locale
       strings (`specializations_heading`, `no_specializations`) — but no
       rendering call site exists in `buildPersonScreen()` today (only
       referenced in the wire-protocol comments and a shop-item-requirement
       field). This is per-person, changes only the one citizenid clicked,
       and its plumbing already exists end to end.
    2. **Tier capabilities** (`server/certtiers.lua`, e.g.
       `advanced_tracking`, `bite_hold_and_takedown`, `mentor_trainees`) —
       named unlocks attached to a **tier** (trainee/certified/senior), not
       a person. Changing one changes it for every person at that tier,
       server-wide. This already has its own dedicated screen ("Cert
       Tiers", high-command-only) and does not belong on a per-person menu
       at all — editing it from a roster row would silently reach past the
       one citizenid clicked.
    - **Assumption made here, flagged rather than silently picked:**
      "sub-features" means (1), specializations. It is the only one of the
      two that is actually a per-person fact, matches "assign roles sub
      features features permissions" reading as a list of four per-person
      things, and the backend for it is already fully built and unused.
      **Confirm with the owner before building** — if (2) is what was
      meant, the correct answer is "no, don't put that on a person's menu,
      it isn't a property of a person" and the ask should be pointed at
      making the existing Cert Tiers screen easier to reach instead.
- **Sort/rank inputs that already exist, verified:**
  - Certification tier: `Config.CertificationTiers[].ordinal` (1/2/3) —
    already resolved per roster row today (`tierLabel`), the ordinal itself
    is not currently sent but is a one-line addition since the tier key is
    already known server-side per row.
  - Department job grade: `ResolveJobGradeInfo` (used by
    `tabletRequestPersonSummary`, line 1724) already returns
    `{ gradeLabel, gradeLevel, isBoss }` per citizenid — not currently
    included in the roster row payload, but the function already exists and
    is already called once per person elsewhere; adding it to each roster
    row is additive, not new plumbing.
  - Handler/K9 XP: already on every roster row today (`xp`,
    `ResolveXpAndTierLabel`).
- **High-command status is a THIRD, independent axis, unaffected by
  anything in this spec.** `IsHighCommand` (`server/highcommand.lua:382`)
  is derived from the citizenid's live `job.grade.level` against
  `Config.Departments[job].highCommandGrade` — a QBox job/grade fact this
  resource never writes to. Certification tier, roster role, and callsign
  cannot promote, demote, or otherwise touch High Command status, and firing
  someone's K9/handler certification does not touch their job or grade
  either. **This removes an entire category of guard-rail this spec would
  otherwise need**: there is no way for any action in this spec to lock
  out the last High Command member, because none of these actions can
  change who holds High Command. Said explicitly so nobody builds a
  protection against a scenario that structurally cannot occur.
- **The mana_policedogs `k9_dog_characters` pin (`server/dogcharacter.lua`,
  migration `0019`) is the WRONG basis for the roster's K9-vs-Handler split
  — arguing against the brief's own suggestion, as invited.** That table is
  a purely cosmetic admin override ("this citizenid IS a dog until an admin
  says otherwise"), explicitly decoupled from role by its own header:
  `HasK9Role` is "completely untouched by this file", and pinning someone
  cosmetically grants no ability. Building the roster split on it would be
  wrong in both directions: (a) it would MISS every real K9 who holds an
  active certification/`k9.access` grant but never had `/k9setdog` run on
  them — which, since that command requires an explicit, separate
  high-command action per citizenid, is very likely most K9s on a normal
  server; (b) it would WRONGLY put a handler cosmetically pinned as a dog
  (a costume, an event) onto the K9 roster despite them functioning as a
  handler in every other respect. §3 below explains what the roster uses
  instead. `IsPinnedDogCharacter`/`GetPinnedDogCharacterModel` remain useful
  as one **extra, informational, non-authoritative** fact shown on a K9's
  roster row ("cosmetically pinned: yes/no") — never as the thing that
  decides which roster a citizenid appears on.
- **The three-way locale contract, the XSS discipline, and THE SECURITY
  RULE (server re-verifies everything, always) all apply unchanged — see
  `docs/history/TABLET_REWORK_SPEC.md` §6 for the full, already-written list of tests
  this feature must not regress** (`tests/tabletlocalization_spec.lua`,
  `html/tests/tablet_xss_spec.js`, `tests/tabletserver_spec.lua`, etc.). Not
  repeated here; that section is the standing contract for every tablet
  change, this one included.

---

## 2. Goal

Give high command one place — the existing K9 Command Tablet, the existing
person screen — to see who is currently hired as a K9 or a Handler, assign
each of them a callsign, and act on them (hire, fire, promote, demote,
change their roster role, grant/revoke specializations, features, and
permissions) without leaving that screen. Two roster **lists** (K9s,
Handlers) feed into that one person screen; they are not two separate
personnel-management systems.

## 3. Decision A — where "K9 or Handler" comes from

**New fact, new table.** Nothing in this schema currently distinguishes the
two, and (per §1) the dog-character pin is the wrong source. Add one new
table, `k9_personnel` (exact migration number to be chosen at
implementation time — check `sql/migrations/` for the current highest
number first; several other agents are adding migrations concurrently),
shaped like `k9_certifications`' own lifecycle, not like
`k9_dog_characters`' current-state-only shape — because, like a
certification, a personnel record needs to preserve history across a
fire-and-rehire cycle, not just overwrite in place:

- `id` (PK, auto-increment) — append-only history, one row per hire cycle,
  mirroring how `Cert_Insert` makes a new row every grant rather than
  reviving an old one.
- `citizenid`, `job` — scoped exactly like a certification (per
  department), so a citizenid certified in two departments can hold two
  independent roster roles.
- `role` — `'k9'` or `'handler'`. Called `personnelRole` in code/API,
  deliberately not `role`, to avoid colliding with the existing
  `role_heading`/`buildRoleControl`/`HasK9Role` "role" (§1).
- `callsign` — nullable string; see §4.
- `granted_by`, `granted_at`, `cleared_by`, `cleared_at`, `active` — same
  shape/semantics as `k9_certifications`.
- Exactly one **active** row per `(citizenid, job)`, enforced the same way
  `k9_certifications`/`k9_partnerships` already enforce their own
  single-active-row invariants (a duplicate-active check before insert,
  raising the identical `ER_DUP_ENTRY`-shaped error `ThrowDuplicateActiveRow`
  already standardizes in `server/datastore.lua` for the memory-mode
  backend).
- Lives behind `K9Store` like every other table in this schema (not a
  second `server/dogcharacter.lua`-style flagged exception) — this is a
  brand-new table with no pre-existing accessor anywhere, so there's no
  reason to duplicate `dogcharacter.lua`'s temporary workaround.

**Written at hire time, required, not optional.** `GrantCertificationForTablet`
gains one new required parameter (`personnelRole`); the Hire action on the
tablet cannot be submitted without picking K9 or Handler. This is the
natural point to decide it — it is, definitionally, the moment someone is
being hired *as* one or the other.

**Neither / both:**
- **Neither** (an active certification with no `k9_personnel` row —
  guaranteed to be every certified citizenid on every server the day this
  ships, see §7) is not hidden. Both roster screens show a third, small,
  clearly-labelled **"Unassigned"** bucket for exactly this case, so an
  owner sees it and fixes it rather than silently missing people. Nothing
  about the citizenid's actual abilities changes while unassigned — every
  existing check (`HasK9Role`, feature/permission grants) is untouched by
  this table's existence.
- **Both** is prevented by construction (one active row per `(citizenid,
  job)`, one `role` column, not a set) — not a state that needs handling,
  because it cannot occur.
- A citizenid holding active certifications in two different departments
  can legitimately be `k9` in one and `handler` in another — that is two
  independent roster rows in two different departments' rosters, not a
  conflict.

## 4. Decision B — callsigns

- **Storage**: the `callsign` column on the same `k9_personnel` active row
  (§3) — attached to the **role**, not the bare citizenid. If a handler
  with callsign `12-Adam-1` later has their personnel role changed to K9
  (§6), the callsign is cleared, not carried over — a K9 callsign and a
  handler callsign mean different things, and silently relabelling one as
  the other would misrepresent what the new callsign is supposed to
  communicate over dispatch/radio. The operator must set a new one.
- **Survives fire/re-hire? No.** Firing (§6) clears the active
  `k9_personnel` row (mirrors how a fresh certification grant after a
  revoke always starts at the default tier, never resurrecting the old
  one — `Cert_Insert` always inserts `tier = 'certified'` regardless of
  history). A re-hire starts in the "Unassigned" bucket with no callsign,
  requiring a deliberate high-command decision again. History is preserved
  in the old, now-inactive row for audit purposes, not deleted — an owner
  who wants the old callsign back can still see it there and re-type it.
- **Format**: plain text, clamped 1–12 characters (clamp-and-warn if
  `Config` ever exposes this as configurable — not asserted), restricted to
  letters, digits, spaces, and hyphens server-side. Rendered exclusively via
  `.textContent` per this file's existing XSS discipline (§1) — the
  character restriction is a sanity/display bound, not the thing preventing
  script injection, which the existing `mk()`/`mkButton()` helpers already
  guarantee structurally.
- **Who may assign**: high command only, same gate as every other roster
  mutation (`IsHighCommand`, re-verified server-side, never from a client
  flag). Not self-assignable by a non-high-command handler/K9 — this is an
  administrative record, not a personal preference field.
- **Uniqueness — open question, recommendation given.** Enforce uniqueness
  **per department, across both rosters combined** (a K9's callsign and a
  handler's callsign in the same department share one namespace) by
  default, matching how real dispatch callsigns work — two units on the
  same channel don't reuse an identifier regardless of unit type. This is
  cheap to narrow later (to per-roster-within-department) if the owner
  disagrees; flagged in §9 rather than silently assumed, because the two
  readings have different validation queries and are worth confirming
  before building either.
- **Collision handling**: reject with a specific outcome
  (`callsign_taken`), case-insensitively compared, never silently overwrite
  the other holder.

## 5. Decision C — what each roster row shows

Enough to make a personnel decision at a glance; everything else is one
click away on the person screen, not duplicated onto the row.

**K9 roster row**: name, citizenid (high command only — matches existing
person-screen display), callsign (or an explicit "no callsign" state, never
blank-and-ambiguous), department, certification tier, XP, active partner's
name if partnered (already resolved server-side via
`ResolvePartnershipInfo`), certified-since date.

**Handler roster row**: identical shape — name, citizenid, callsign,
department, certification tier, XP, active partner's name if partnered,
certified-since date.

Both share one **"Unassigned"** section (§3) for active-certification-holders
with no `k9_personnel` row: name, citizenid, department, certified-since —
no callsign/tier framing implied since neither roster owns them yet.

Not shown on the row (available one click into the person screen instead,
per §1's "one menu" decision): permissions, features, specializations,
job grade detail, full certification history. Putting all of that on the
row would recreate the "wall of text" the row is supposed to avoid.

## 6. Decision D — actions and their guard rails

All of the below are re-verified server-side on every call
(`IsHighCommand(source)`, live, never a cached/client-claimed value) — no
new authorization mechanism, reusing exactly what `server/tablet.lua`/
`server/certifications/`/`server/permissions.lua` already enforce.

| Action | Backend | Who | Confirm? | Audit |
|---|---|---|---|---|
| **Hire** | `GrantCertificationForTablet` + new `personnelRole` param + new `k9_personnel` insert | High command | Plain button (low-weight: creates a new, easily-reversible record) | `LogTabletCertAuditInvocation`, existing shape |
| **Fire** (decertify) | **New** `RevokeCertificationForTablet` (closes the dead-button gap, §1) + best-effort `k9_personnel` row clear | High command | **Two-click (`mkConfirmButton`)** — ends someone's working status; matches the existing weight given to `role_revert_label` (also `mkConfirmButton`) | same |
| **Promote/Demote** | `SetCertificationTierForTablet` (unchanged) | High command | Plain button (already how it works today; not being made heavier) | same |
| **Change roster role** (K9↔Handler) | New: updates `k9_personnel.role` on the active row, clears `callsign` (§4) | High command | Plain button, but the confirmation copy must say the callsign is being cleared, so this isn't a surprise | New audit line, same print-based format |
| **Assign/change callsign** | New: updates `k9_personnel.callsign` | High command | Plain button (routine, low-weight, easily corrected) | New audit line |
| **Grant/revoke specialization** | `GrantSpecializationForTablet`/`RevokeSpecializationForTablet` (unchanged, online-only) | High command, target must be online | Plain button (already how it works today) | same |
| **Grant/revoke feature, permission** | Existing `person_features_heading`/`person_capabilities_heading` sections (unchanged) | High command | Plain button (already how it works today) | same |

**Confirmation is deliberately not uniform** — per the coordinator's own
caution, confirming everything trains people to click through all of it.
Only Fire gets the two-click treatment, because it's the one action here
that ends someone's working status outright; everything else here is
either already low-weight by existing precedent (promote/demote,
features/permissions) or newly introduced at the same weight as its closest
existing analog (hire ≈ a new record; callsign/role-change ≈ routine
editing). None of these are `lockoutRisk` in the `runtimecontrol.lua` sense
(§1's High Command finding: nothing here can lock command out of anything),
so the typed-confirmation mechanism that exists for `HighCommand`/
`PermissionGrants` does not apply and must not be copied in here — that
mechanism is reserved for genuine self-lockout risk, which this feature
does not carry.

**Self-targeting** (acting on your own citizenid from the roster): reuses
the existing pattern already in `buildCapabilityList` (`selfTarget`
detection, disabled-with-a-title for self-grant where the server
unconditionally blocks it). Fire specifically inherits `RevokeCertification`'s
existing `Config.AllowSelfCertification` gate unchanged — if a server has
that off, self-fire from the roster is refused server-side exactly like a
self-`/k9decertify` is today; the roster UI must not hide that this is the
same rule, and should show the same self-target warning styling as the
existing self-grant-disabled rows.

## 7. Decision E — what must not be possible

- **A roster action must never leave someone worse off than before the
  click if the server call fails partway.** Fire clears the
  `k9_personnel` role/callsign only *after* `RevokeCertificationForTablet`
  itself reports success — and if the personnel-row cleanup step fails on
  its own, that failure is logged and reported honestly (mirrors
  `dogcharacter.lua`'s `pin_db_error` pattern) but never rolls back the
  revoke that already succeeded. **Never gate a termination path**: a
  citizenid whose certification was just revoked is guaranteed to stop
  appearing on either roster the moment the certification's own `active`
  flag flips, regardless of whether the `k9_personnel` cleanup step itself
  succeeded — both roster queries must filter on "active certification
  AND (personnel row, if any, also active)", so a stray stale personnel row
  can never keep a fired citizenid visible as still-hired.
- **Acting on someone who disconnected mid-click.** Every action in §6 is
  already citizenid-keyed, not server-id-keyed (`GrantCertificationForTablet`/
  `SetCertificationTierForTablet`/the new `RevokeCertificationForTablet`
  all resolve online-vs-offline internally from the citizenid at the moment
  of the call) — this is already this resource's established fix for
  exactly the "server ids get recycled" hazard the brief calls out by name.
  The two genuinely new actions (role-change, callsign) must be built the
  same way: resolve online state fresh, from the citizenid, at call time,
  never from a server id captured when the roster/person screen was opened.
- **A callsign field that accepts anything and gets rendered unsafely.**
  Covered structurally by the existing `.textContent`-only discipline
  (§1) — the character-set clamp in §4 is a UX/sanity bound on top of that,
  not a substitute for it.
- **Demoting/firing the only High Command member out of their access.**
  Structurally impossible (§1's High Command finding) — nothing in this
  spec touches job grade.
- **Firing yourself by accident.** Covered by the two-click confirm (§6)
  plus the existing `AllowSelfCertification` gate (§6) — both apply
  identically whether reached from the roster or from `/k9decertify`.
- **A stale roster view retargeting the wrong department.** Every write
  here validates the target's *live* department against the roster's
  `departmentKey` server-side and refuses with `department_mismatch` on a
  mismatch, exactly like `GrantCertificationForTablet`/
  `SetCertificationTierForTablet` already do — the new `k9_personnel`
  writes must adopt the identical check, not a weaker one.
- **Misrepresenting an implicit High Command capability as an explicit
  grant, or vice versa.** Flagged as a live coordination dependency, not
  solved here: another agent is implementing "High Command implicitly
  holds every permission/feature/tier/XP unlock, but an explicit block on
  one person still applies." Once that lands, the person screen's
  permissions/features sections **must** render three visually distinct
  states per row — held because explicitly granted, held because the
  viewer is implicitly covered by High Command, and denied because an
  explicit block overrides even High Command — never collapse the middle
  case into an identical checked box next to an explicitly-granted one.
  This spec does not design that mechanism (out of scope, owned elsewhere)
  but the roster/person-screen acceptance criteria in §9 require the
  distinction be visible once it exists — do not ship a roster read of
  "permissions" that silently regresses to a true/false checkbox against
  that richer contract when it lands.

## 8. Decision F — migration / first boot / memory-only mode

**Nothing changes for an existing server's already-certified people the
moment this ships.** Every currently-active certification simply has no
`k9_personnel` row yet — no data is migrated, converted, or guessed, because
there is no reliable signal in the existing schema to guess K9-vs-Handler
from (§1's argument against using the dog-character pin applies here too:
there is no safe inference, only an explicit assignment).

**What an owner sees on first boot after updating**: both roster tabs open
to mostly-empty K9/Handler lists and one populated **"Unassigned"** section
listing every currently-certified person, department by department, with a
short, plain-language explanation ("These people are certified but have not
been assigned as a K9 or a Handler yet — pick one for each to add them to a
roster.") High command works through that list once, at their own pace;
nothing forces it, nothing times out, and nobody's actual in-game
abilities change while they sit in "Unassigned" — every existing
certification/permission/feature check is completely untouched by whether
a `k9_personnel` row exists.

**Idempotent migration**: the new `k9_personnel` table's own migration file
follows this schema's established convention exactly (`CREATE TABLE IF NOT
EXISTS`, no `ALTER`, no `DROP`, safe to run any number of times, in any
order relative to `install.sql` or any other migration — same pattern as
`0019_create_k9_dog_characters.sql`).

**`Config.Database.enabled = false` (memory-only mode)**: `k9_personnel`
gets a `K9Store`-backed accessor following the exact same
`if DatabaseEnabled('k9_personnel') then <real SQL> else <plain Lua table>`
shape every other table in `server/datastore.lua` already uses — hire,
fire, promote, demote, role-change, and callsign assignment all keep working
for the life of the process, with nothing remembered past a restart. This
is the same honest trade-off every other table in this schema already
documents, not a new one. Both rosters, and the "Unassigned" bucket, read
correctly in memory mode from the moment the process starts (empty, exactly
like every other table's memory-mode start state) — there is no special
case for this feature under a disabled database.

## 9. Sort/rank (coordinator addition)

- **Default sort, both rosters: certification tier ordinal, descending**
  (senior → certified → trainee → unassigned last), ties broken by name.
  Chosen because it's the one "rank" concept both rosters already share
  identically (unlike job grade, which is department-specific numeric
  ranks with no shared meaning between e.g. police and a second configured
  department; unlike XP, which is a progress metric, not a standing/rank
  one).
- **Alternate sorts, offered as a cheap toggle, not a new query**: by
  department job grade (`gradeLevel`, needs one additive field on the
  roster row payload — `ResolveJobGradeInfo` already exists and is already
  called elsewhere per citizenid, so this is exposing an existing read, not
  building one) and by XP (already on every row today). Both are pure
  client-side re-sorts of the already-fetched row list — no new server
  round trip.
- **Display-only, not persisted per viewer**, in this pass — a viewer's
  chosen sort resets on reopen. Flagged as a deliberate scope cut rather
  than an oversight: persisting it needs a place to store a per-officer UI
  preference this resource has nowhere established for anything else on
  this tablet today, and is cheap to add later if requested.

## 10. Locale keys needed (three-way contract, §1)

New keys must land in `locales/en.json`'s `tablet` group, `client/tablet.lua`'s
`TABLET_STRING_KEYS`, and `html/tablet.js`'s `DEFAULT_STRINGS` in the same
change (`tests/tabletlocalization_spec.lua` fails otherwise). Naming below
follows this file's existing bare-key convention (no `tablet.` prefix
inside the array itself):

`tab_roster_k9`, `tab_roster_handlers`, `roster_unassigned_heading`,
`roster_unassigned_explainer`, `roster_callsign_column`,
`roster_callsign_none`, `roster_callsign_label`, `roster_callsign_save`,
`roster_callsign_taken_error`, `roster_callsign_invalid_chars_error`,
`roster_hire_label`, `roster_hire_role_prompt`, `roster_hire_role_k9`,
`roster_hire_role_handler`, `roster_fire_label`, `roster_fire_confirm_prompt`,
`roster_fire_self_warning`, `roster_role_change_label`,
`roster_role_change_confirm_prompt`, `roster_sort_label`,
`roster_sort_by_tier`, `roster_sort_by_grade`, `roster_sort_by_xp`,
`roster_dogcharacter_pin_note` (the §3 "cosmetically pinned" informational
line).

## 11. Acceptance criteria

1. [ ] `k9_personnel` exists as a new, idempotent migration
       (`CREATE TABLE IF NOT EXISTS`, no destructive statement), following
       `server/datastore.lua`'s established `K9Store` accessor shape,
       memory-mode included.
2. [ ] Hiring someone requires picking K9 or Handler in the same action —
       there is no way to grant a certification through the roster's Hire
       flow without a `personnelRole` being recorded.
3. [ ] A person with an active certification and no `k9_personnel` row
       appears in an explicit "Unassigned" section on both rosters, never
       silently omitted from both.
4. [ ] It is structurally impossible for a citizenid to hold both `k9` and
       `handler` `personnelRole` values on the same active row (single
       column, single active row per `(citizenid, job)`).
5. [ ] Firing someone (a) works even when they are offline, (b) requires a
       two-click confirmation, (c) is refused server-side for a self-target
       exactly when `Config.AllowSelfCertification` is off, identically to
       `/k9decertify`, (d) guarantees the citizenid stops appearing as
       hired on either roster immediately, even if the secondary
       `k9_personnel` cleanup write fails.
6. [ ] Changing a person's roster role clears their callsign in the same
       action, and the UI states this before the operator confirms.
7. [ ] Callsign assignment is high-command-only, rejects duplicates within
       its configured scope with a specific error (never silently
       overwrites another holder), and is rendered exclusively via
       `.textContent` (no `innerHTML` introduced anywhere in this feature).
8. [ ] No action in this feature can change who holds High Command, a
       person's job, or their job grade — verified by the fact that none of
       the new/changed code paths touch `qbx_core` job-grade state at all.
9. [ ] Every mutation added or changed re-verifies `IsHighCommand(source)`
       server-side on every call, never trusting a client-supplied flag or
       a cached viewer state (`THE SECURITY RULE`, unchanged).
10. [ ] Roster rows and the person screen open from three entry points
       (Console search, the online-players picker, the new roster rows)
       and all three land on the same `buildPersonScreen()` — no second
       person-detail screen is introduced.
11. [ ] The existing `tablet:decertify` button (already shipped, currently
        dead) becomes functional through the new
        `RevokeCertificationForTablet`/`john-k9:server:tabletDecertify`
        wrapper, built the same way every other `*ForTablet` wrapper is.
12. [ ] `tests/tabletlocalization_spec.lua`, `html/tests/tablet_xss_spec.js`,
        and every test named in `docs/history/TABLET_REWORK_SPEC.md` §6 continue to pass
        unmodified in intent.
13. [ ] Sorting the roster by tier, grade, or XP re-orders the already-
        fetched row list client-side with no additional server round trip.
14. [ ] Once the in-flight "High Command implicit access" work lands, the
        permissions/features sections reachable from a roster row render
        explicit-grant, implicit-via-High-Command, and explicit-block as
        three visually distinct states, never collapsed into one checkbox.

## 12. Non-goals (this pass)

- Persisting a viewer's chosen sort order across sessions.
- A global, cross-department callsign namespace (scoped to one department
  per §4 unless the open question below is answered otherwise).
- Any change to `k9_dog_characters`/`/k9setdog` — it remains a separate,
  purely cosmetic mechanism, only ever read informationally by the K9
  roster row (§3).
- Building the "High Command implicit access" display mechanism itself —
  owned by another in-flight pass; this spec only states what the roster
  must do once it exists (§7, §11 item 14).
- Editing tier-level capabilities (`server/certtiers.lua`) from a person's
  menu — that is a server-wide, tier-scoped setting, not a per-person one
  (§1).

## 13. Open questions for the owner

1. **Callsign uniqueness scope (§4)** — shared across both rosters within a
   department (recommended), or a separate namespace per roster? Cheap to
   build either way; expensive to guess wrong and have to re-validate every
   existing callsign later.
2. **"Sub-features" (§1)** — confirm this means per-person specializations,
   not tier-level capabilities. If tier capabilities were actually meant,
   the right answer is likely "make the existing Cert Tiers screen easier
   to reach," not "put it on a person's menu."
3. **Should the "Unassigned" bucket be sorted/highlighted more aggressively**
   (e.g. a badge/count on the roster tab itself) so a busy high-command
   officer notices it on day one rather than only when they open the tab?
   Low-cost either way; flagged so it's a deliberate choice, not an
   oversight.
