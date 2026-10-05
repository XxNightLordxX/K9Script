> **HISTORICAL RECORD — NOT CURRENT GUIDANCE.**
>
> This document is the design for the command tablet rework. The work it describes has been
> built, and in places has since been changed or removed. It is kept because
> it explains WHY things are shaped the way they are, which the code alone
> cannot say — but it does not describe how the resource works today, and it
> is not a specification anyone should implement from.
>
> For how the resource actually works now, see `README.md` (setup and
> features), `DEVELOPER_REFERENCE.md` (the code), and `DIAGNOSTIC_CHECKS.md`
> (the `/k9debug` report). Archived 2026-09-02.

---

# K9 Command Tablet — Full UI Rework Spec

Author: product (spec pass) · Date: 2026-08-26
Scope: `john-k9` — `html/tablet.js`, `html/tablet.css`, `html/tablet.html`,
`client/tablet.lua`, `server/tablet.lua`, and every file those two already
delegate to (`server/runtimecontrol.lua`, `server/certtiers.lua`,
`server/permissionkeycatalog.lua`, `server/equipmentshop.lua`,
`server/xptiers.lua`, `server/k9profiles.lua`, `server/admin.lua`).

This is a planning document only. No implementation code was written or
changed while producing it.

---

## 0. The owner's request, restated

Verbatim: *"make the tablet more easier to understand and make it one
tablet that changes based off handler k9 or high command with the Crimson
Roleplay logo all over the ui make all the features ability to stay always
active or not more color based on all scent stuff vehicle related is more
text based full rework of the ui to make it more professional and easier
to understand."*

Unpacked into six separable asks, each addressed in its own section below:

1. Reduce the tablet to one coherent, role-driven experience instead of a
   flat wall of tabs (§2).
2. Brand it with the real Crimson Roleplay logo, throughout (§5).
3. Give every feature an explicit on/off switch, exposed from the tablet
   (§3).
4. Make scent-related tablet content more colour-driven, vehicle-related
   content more text-driven (§4).
5. A "full rework" — not a patch — but one that must not regress anything
   already shipped and tested (§6).
6. "More professional and easier to understand" is the thread running
   through all of the above, not a separate line item.

**Headline finding, stated up front because it changes the shape of the
whole plan:** this resource's tablet already went through one owner-directed
"restructure around who is holding it" pass. A role-aware Home screen with
four viewer bodies (K9 / Handler / Partner / High Command), a universal
Partnerships tab, a universal Help tab with role-aware copy, and a fully
dynamic, drift-tested "every feature has a live/needs-restart/config-only/
client-only tier" runtime-control system all exist today, are covered by
tests, and are current as of **today's date** (`server/runtimecontrol.lua`'s
own audit trail is dated 2026-08-26). Several of the six asks above are
therefore **exposure and information-architecture problems on top of a
working backend**, not "build this from nothing" problems — and I've tried
to be precise below about which is which, because treating an
already-solved backend problem as a from-scratch build would be a real
waste of the effort already spent, and treating an unsolved UI problem as
"just re-skin it" would under-deliver on what the owner is actually asking
for.

---

## 1. What exists now — honest inventory

### 1.1 Tabs, screens, and who can see each one

The tab bar (`html/tablet.js` `buildTabs()`, lines 3538–3863) renders a flat,
single-row list. Every viewer who can open the tablet at all sees the first
five tabs; everything after that is added conditionally, and the
conditions are evaluated independently of each other (a viewer can qualify
for any combination):

| Tab | Screen function | Who sees it | Gate (client-side convenience) | Real server-side gate |
|---|---|---|---|---|
| Home | `buildHomeScreen` | Everyone, always | none | n/a (read-only) |
| My Record | `buildMyRecordScreen` | Everyone, always | none | `Config.FeatureControl.everyoneCanViewOwnRecord` |
| Partnerships | `buildPartnershipsScreen` | Everyone, always | none | own row always; admin lookup re-gated server-side |
| Commands | `buildCommandReferenceScreen` | Everyone, always | none | n/a (static reference) |
| Help | `buildHelpScreen` | Everyone, always | none | n/a (static reference) |
| Command Console | `buildConsoleScreen` / `buildPersonScreen` | High command, or a named `k9.audit` grant holder | `canAccessConsole()` | `CallerHasConsoleAccess` (`server/tablet.lua`) |
| Guided Flows | `buildFlowsHubScreen` + 4 flow screens | High command only | `state.viewer.isHighCommand` | each underlying job's own gate (mixed) |
| Tablet Theme | `buildThemeScreen` | High command, or `k9.tablettheme` grant | `canManageTabletTheme()` | `CanManageTabletTheme` (`server/runtimecontrol.lua`) |
| Cert Tiers | `buildCertTiersScreen` | High command only | `state.viewer.isHighCommand` | `CanManageCertTiers` (`server/certtiers.lua`) |
| Permission Keys | `buildPermissionKeysScreen` | High command only | `state.viewer.isHighCommand` | `CanManagePermissionKeys` |
| Shop Locations | `buildShopLocationsScreen` | High command, or `k9.equipmentshoplocations` grant | `canManageShopLocations()` | `CanManageShopLocations` |
| Shop Items | `buildShopItemsScreen` | High command, or `k9.equipmentshopitems` grant | `canManageShopItems()` | `CanManageShopItems` |
| Runtime Control | `buildRuntimeControlScreen` | High command, or `k9.runtimecontrol` grant | `canManageRuntimeControl()` | `CanManageRuntimeControl` |
| XP Tiers | `buildXpTiersScreen` | High command only | `state.viewer.isHighCommand` | `CanManageXPTiers` |
| K9 Profiles | `buildK9ProfilesScreen` | High command only | `state.viewer.isHighCommand` | `CanManageK9Profiles` |
| Audit Trail | `buildAuditScreen` | High command, or `k9.audit` grant | `canViewAudit()` | `IsAuthorizedAdmin` (`server/admin.lua`) |

Every gate above is a **UI convenience only** — every mutating callback
behind it re-verifies server-side from the caller's live job/grants
(`THE SECURITY RULE`, stated at the top of both `html/tablet.js` and
`client/tablet.lua`, and enforced by dozens of `*_spec.lua`/`*_spec.js`
files that assert a hidden button's action still gets refused server-side).
This matters for the rework: **hiding a tab is presentation, not
protection** — the rework can reorganize freely without touching
authorization at all.

**Concretely, a high-command officer who also holds all four delegable
grants sees 16 tabs in one horizontal row** (Home, My Record, Partnerships,
Commands, Help, Console, Flows, Theme, Cert Tiers, Permission Keys, Shop
Locations, Shop Items, Runtime Control, XP Tiers, K9 Profiles, Audit). An
ordinary certified handler with no admin grants sees 5. A brand-new,
uncertified arrival also sees 5 (Home explicitly renders a "you're not
certified yet, here's what to do" notice rather than an empty shell —
`buildHomeIdentityCard`, lines 4125–4136 — so a zero-role viewer is already
handled, just not put front-and-center as its own "face").

### 1.2 What is genuinely confusing (specific, not "cluttered")

1. **Two competing navigation structures for the same twelve admin
   screens, at the same time.** `buildTabs()` puts all twelve high-command/
   delegated screens in one flat row with the five universal tabs, no
   visual grouping. `buildHomeScreen()`'s own `buildHomeHighCommandTools()`
   (lines 4218–4284) *already* groups the exact same twelve screens under
   one "High Command Tools" heading, below the fold, specifically to avoid
   crowding — its own doc comment calls this "THE PROGRESSIVE-DISCLOSURE
   REQUIREMENT". So the tablet currently ships two different answers to
   "how should twelve admin screens be organized" simultaneously: a flat
   list (tab bar) and a grouped list (Home). A rework has to pick one
   information architecture and apply it consistently, not keep both.

2. **Three different screens present overlapping "what can I do"
   information with three different names and three different subsets**,
   and nothing on screen explains why they differ:
   - Home → "Ready Abilities": actionable-only, `state === 'available'` only.
   - My Record → "My Abilities": every feature, every state.
   - Console → Person → per-feature admin table: every `Config.Features`
     key including pure infrastructure switches (`HighCommand`,
     `CommandTablet`, `PermissionGrants`, …), because
     `server/tablet.lua`'s own header states this is a deliberate
     "breadth over curation" choice for the *admin* view specifically.
   A first-time reader has no way to know these three lists are related
   without being told; the rework's role-based framing (§2) is the natural
   place to make that relationship explicit instead of implicit.

3. **Screens are named after the Lua/config concept that implements them,
   not the task a person is trying to do** — "Cert Tiers", "Runtime
   Control", "K9 Profiles", "Permission Keys", "Tablet Theme". These are
   accurate to a coder and opaque to the "make it easier to understand"
   ask; a non-technical owner or officer has to already know what a "tier"
   or "runtime control" is in this codebase's vocabulary to guess what's
   behind the tab.

4. **The five feature states shown on My Record/Console/Person
   (`global_off` / `blocked` / `not_certified` / `requires_grant_missing` /
   `available`) are named after which internal gate rejected the feature**,
   not what the viewer should do about it. The actual English copy
   (`locales/en.json` lines 448–452: "Disabled server-wide", "Blocked",
   "Not certified", "Requires a grant (not granted)", "Available") is
   already plain-language, so this is not as bad as the internal names
   suggest — but it is five states with no colour-coding hierarchy beyond
   green/amber/grey/red, applied identically whether the row is a K9
   ability, an infrastructure switch, or a vehicle interaction. Nothing
   currently tells a viewer "this row is about scent" vs "this row is about
   vehicles" at all — see finding 6 below.

5. **No persistent "you are viewing this as: ___" framing exists in the
   chrome.** Role is only expressed as (a) a badge string on the Home
   identity card and (b) which tabs happen to be visible. A dual-role
   viewer (a high-command officer who is also a certified handler with an
   active K9 partnership — explicitly *not* an edge case, see §2) sees the
   K9/Handler content on Home *and* the High Command Tools section *and*
   every admin tab, all folded into the one screen, with no visual
   separation announcing "you are seeing more than one role's worth of
   content at once." This is the single biggest concrete gap against "make
   it one tablet that changes based off role" — the switching already
   happens, but it happens silently.

6. **There is no dedicated scent screen or vehicle screen to apply
   colour/text treatment to.** Scent-family content
   (`ScentTracking`, `ScentVision`, `ScentLineup`, `ScentTrailHunt`,
   `BloodTracking`, `GunpowderSniffing` — six of `Config.Features`' ~56
   flags) and vehicle content (`VehicleEntryExit` — effectively the only
   vehicle-specific flag; vehicle *search* shares a generic
   `SearchZones`/`ContrabandAlerts` mechanic with person search, per
   `help_task_search_2`'s own copy) exist today only as: (a) ordinary rows
   in the generic Features list, (b) entries in the Commands tab's
   `COMMAND_REFERENCE` catalogue (which *does* already have a category
   taxonomy — `scent_games`, `basic_commands`, etc. — but only for the
   handful of features that are triggered by a slash command; `ScentTracking`,
   `BloodTracking`, `GunpowderSniffing`, and `VehicleEntryExit` are not
   command-driven and carry no category tag anywhere), and (c) walkthrough
   prose in Help. **This means §4's request cannot be satisfied by
   re-skinning two existing screens — those screens do not exist yet.**
   Flagged plainly, not quietly downsized.

7. **The logo is a placeholder** — see §5. Everything currently wrapping it
   (header mark, landing badge, fallback-to-text-on-load-failure) is real
   and tested; only the image asset itself is not.

---

## 2. One tablet, three faces

### 2.1 What already exists to build on

- `buildHomeScreen()` already branches on **four** viewer shapes: K9
  (`state.isK9Model` / server-verified `viewer.isK9`), Handler (certified,
  not currently a K9), Partner (an orthogonal badge, not a fourth body —
  it decorates either of the above), and High Command
  (`viewer.isHighCommand`, additive: gets everything a Handler/K9 gets
  *plus* the admin tools section). This is already extremely close to "K9 /
  Handler / High Command" — the owner's "K9 or handler or high command"
  maps almost directly onto the existing K9/Handler/HighCommand split, with
  Partner correctly modeled as an overlay rather than a fourth mode.
- Role signals are **server-verified**, not guessed: `viewer.isHighCommand`
  (`IsHighCommand(source)`), `viewer.isK9` (`HasK9Role(source)` —
  model-independent, DB-backed), `viewer.isPartnered`
  (`GetActivePartnerCitizenId`) are all resolved fresh, server-side, on
  every `tablet:requestMyRecord` call (`server/tablet.lua` lines
  1378–1379). The only client-local fallback (`state.isK9Model`,
  `state.isPartnered`) exists purely to avoid a flash-of-wrong-content in
  the instant before the first server response lands, and is explicitly
  documented as never authoritative and never sent back into any mutating
  call. **The rework does not need a new role-resolution mechanism — it
  already exists, is trustworthy, and is already wired into every screen
  that needs it.**
- The Partnerships tab is **already** universal by explicit owner
  instruction, already implemented that way: *"a partnership tab should be
  shown on all tablets as a tab... high command is a handler or a k9 and
  should have control over it also but the partnership tab should show
  whos there partners"* (`buildTabs()` comment, lines 3577–3586). High
  command gets the same personal partnership row as everyone else, plus an
  admin lookup section rendered on the *same* screen, never a second
  screen. This is the existing precedent for how "shared across all three
  faces, with an admin extra layered on top" should look — the rework
  should follow this exact pattern for anything else that needs to be
  both personal and administrable (Home's identity card is a candidate).
- Help is already role-aware at the copy level: `buildHelpScreen()`
  chooses `help_role_note_k9` / `help_role_note_handler` /
  `help_role_note_uncertified`, with a `help_role_note_high_command_suffix`
  appended when relevant (lines 4889–4895) — additive, matching the "High
  Command is also a Handler/K9" model, not a fourth exclusive branch.

### 2.2 The proposed role model

Three **faces**, not three separate tablets and not three exclusive modes:

- **K9 face** — shown when `viewer.isK9 === true`. Leads with the K9's own
  condition/progression/partner, matching the existing
  `buildK9HomeBody()`'s intent. A K9 with no certification is a
  contradiction under this resource's data model (K9 role requires an
  active certification or `k9.access` grant) and does not need a separate
  "uncertified K9" case.
- **Handler face** — shown when `viewer.isK9 !== true` and at least one
  active certification exists. Leads with certifications, abilities ready
  to use, and partner status.
- **High Command face** — an **overlay**, not a replacement: added on top
  of whichever of the above two applies (a high-command officer is always
  also either a K9 or a Handler in this resource's own data model — nobody
  holds high command without a job/grade in a configured department). Adds
  the admin tools section and the extra tabs from §1.1's table.
- **No role at all** (a brand-new arrival, zero certifications, not high
  command) — already handled by `buildHomeIdentityCard`'s "you're not
  certified yet" notice. The rework should make this the explicit fourth
  documented case (not a face, a *state* — "pre-face"), reusing the
  existing notice, expanded to visibly point at the Help tab and the
  Commands tab as the two "how do I get a role" answers this resource
  already has, rather than leaving it as a single paragraph.

### 2.3 Dual-role handling — the explicit design decision

A high-command officer who is also a certified handler with an active K9
partnership is **the common case for anyone senior enough to reach the
admin screens at all**, not an edge case, and the spec has to say plainly
what they see:

- Their Home screen shows the Handler (or K9) body **first**, exactly as
  an ordinary Handler/K9 would see it — same layout, same vocabulary, same
  position on the page. This preserves "one tablet, not three" and the
  existing "Consistency" requirement already documented in
  `buildHomeScreen()`'s own header.
- Below that, a single, clearly-labelled section change (not a tab
  switch, not a different screen) announces the High Command layer and
  contains everything from §1.1's admin-tab table, reusing
  `buildHomeHighCommandTools()`'s existing grouping.
- **The open question this section cannot resolve unilaterally**: today
  that boundary is a heading with no visual separator beyond whitespace.
  "Easier to understand" plausibly wants a real visual break (a rule, a
  colour band, a distinct background) between "this is you, the
  handler/K9" and "this is you, the administrator" — different enough
  that nobody mistakes an admin control for a personal one. This is a
  *design* decision (§7 assigns it to coder-ui), not a product ambiguity,
  so it is not listed as an open question in §9.

### 2.4 Acceptance criteria

- [ ] A K9-role viewer's Home screen leads with K9-flavoured content
      (progression, partner, ready abilities) before anything else, using
      the existing `viewer.isK9` server-verified signal — never
      `state.isK9Model` alone.
- [ ] A Handler-role viewer (certified, not K9) sees the equivalent
      Handler-flavoured leading content.
- [ ] A High Command viewer sees their own Handler/K9 content **first**,
      unchanged in position and wording from a non-high-command viewer's
      equivalent screen, followed by one clearly-delineated High Command
      section containing every admin capability they hold (server-verified
      per capability, exactly matching §1.1's table — no capability is
      shown as available and then refused).
- [ ] A zero-role viewer sees an explicit "not certified yet" state that
      names at least one concrete next step (pointing at Help and/or
      Commands), never a blank or broken screen.
- [ ] The Partnerships tab remains universal and unconditional, and a
      High Command viewer's own partnership row renders identically to an
      ordinary viewer's — the admin lookup stays an addition, never a
      replacement.
- [ ] No new authorization logic is introduced anywhere in this pass —
      every gate the rework relies on already exists in
      `server/tablet.lua`/`server/runtimecontrol.lua`/etc., and every
      existing `canX()` convenience function in `html/tablet.js` keeps
      matching its real server-side counterpart (this is what
      `tests/*_spec.lua`'s "verified directly against source" comments,
      cited throughout `html/tablet.js`, currently guarantee — the rework
      must not silently break one of those pairings while reorganizing the
      UI around it).
- [ ] `tests/helptabcoverage_spec.lua` and `tests/commandreferenceregistry_spec.lua`
      still pass — a rework that renames or restructures tabs must update
      `HELP_TAB_CATALOG`/`COMMAND_REFERENCE` in the same change, not after.

---

## 3. Always active or not

### 3.1 What already exists — read this before proposing new plumbing

`server/runtimecontrol.lua` already implements exactly the mechanism this
ask needs, and it is **complete, current, and drift-tested as of today**:

- Every one of `Config.Features`' ~56 flags now has a `FEATURE_TIERS`
  entry (`tests/runtimefeaturetiers_spec.lua` fails the whole suite if
  `Config.Features` and `FEATURE_TIERS` ever drift apart — the file's own
  header records that eleven features shipped without one and were closed
  out in the 2026-08-26 pass, i.e. today).
- Each entry is tagged with one of five tiers, each an honest statement of
  what flipping it from the tablet actually does:
  - `live` — takes effect immediately, no restart (most gameplay
    features: `BiteAndHold`, `ScentTracking`, `XPProgression`, etc.).
  - `onstart` — takes effect on the *next* restart only (e.g.
    `AdminAuditCommands`, `K9EquipmentShop`).
  - `rawtoplevel` — cannot be changed short of an operator editing
    `config.lua` and restarting (e.g. `Recall`, `CommandTablet`,
    `PropAttachments`) — the tablet records the request but is honest that
    it did nothing yet.
  - `clientonly` — a pure client-rendered toggle with **no server
    enforcement point at all** (`RadialMenu`, `VehicleEntryExit`,
    `AgilityBasicJump`, `ThermalVision`, `NightVision`,
    `HealthStaminaHUD`, `ContrabandScreenFX`, `AdvancedBarkRadial`,
    `ProximityAudioFX`, `WaterTrackingDecay`, `AgilityAdvanced` — eleven
    features, confirmed by direct grep against every `server/*.lua` file).
    The tablet greys these out rather than pretending a server-side toggle
    reaches an already-connected client.
  - As of today, **no feature is permanently un-toggleable** —
    `HighCommand` and `PermissionGrants` (the two self-lockout risks) were
    moved from an outright-refused `protected` tier to `live` +
    `lockoutRisk = true` + a typed-confirmation gate (§6.5), rather than
    being hidden from the operator entirely.
- A dedicated confirmation flow already exists for anything genuinely
  dangerous to flip (§6.5) — this is the "are you sure" the owner's "always
  active or not" plausibly implies should exist for anything risky, and it
  already does.
- `Config.CommandTablet.ActionableFeatures` already distinguishes features
  that have a single "use it now" trigger button from ones that are purely
  status rows — this is the existing, correct place to decide which
  features can even have an "activate" concept at all (see §3.2).

### 3.2 Two different things could be meant by "always active or not" — and the cost difference is large

**Reading A — an on/off switch per feature, server-wide, honestly labelled
by what it actually does when flipped.** This is what `Config.Features` +
`RuntimeFeatureControl` already *is*, end to end, today. Under this
reading, the remaining work is entirely UI/exposure: make the existing
Runtime Control screen the obvious, well-organized home for this (see §7
Stage 3), rather than a wall of ~56 unsorted rows behind an admin-only tab.

**Reading B — a per-feature *behaviour* switch: does this ability run
continuously/passively in the background (e.g. thermal vision just stays
on) versus require the player to manually trigger it each time (a keybind
press, a command)?** This is a materially different, much larger feature:
it requires a new persisted per-player (or per-feature-default) setting,
UI to set it, and — critically — **engineering work inside each
feature-owning file** to check that new setting and auto-engage the
ability instead of waiting for a keybind/command, for every feature this
would plausibly apply to (candidates: `ThermalVision`, `NightVision`,
`HealthStaminaHUD`, `ScentVision`, `ContrabandScreenFX`,
`ProximityAudioFX`, `AdvancedBarkRadial` — notably, the same set that is
already `clientonly` tier, i.e. exactly the set the server currently has
**no reach into at all**). This reading would also need a design decision
about *whose* preference it is — the K9's, the handler's, or a
server-wide default — which the owner's sentence does not specify.

**Recommendation**: build for Reading A. It is consistent with the
sentence's own wording ("make all the features ability to stay always
active or not" reads naturally as "give every feature an on/off switch"),
it reuses a system that already exists, is tested, and is current as of
today, and it costs an order of magnitude less than Reading B. This is
flagged as an explicit open question for the owner in §9 rather than
decided silently, because the cost difference between the two readings is
too large to guess past.

### 3.3 Which features "always active or not" does and does not apply to

- **Applies cleanly**: every status-gated ability with an ongoing
  on/off existence — certification-gated abilities, HUD/vision toggles,
  tracking mechanics, the shop, theming, admin tooling. This is the
  large majority of `Config.Features`.
- **Does not apply, and should be stated as a non-goal**: genuine one-shot
  actions with no "stay on" concept — `k9recall` (call the dog off *now*),
  `k9takedown` (a single takedown attempt), fetch-ball throw/drop/recall,
  certifying/decertifying a person, granting XP. These are commands/
  triggers, not standing capabilities; `Config.Features.<X> = true/false`
  already correctly governs *whether the trigger exists at all*, and that
  is the only "on/off" that ever applied to them. `FEATURE_TIERS` already
  reflects this correctly (they're tiered exactly like every other
  feature) — nothing new is needed for this half.

### 3.4 Acceptance criteria

- [ ] Every `Config.Features` key the tablet's on/off screen lists shows
      its real tier (`live`/`onstart`/`rawtoplevel`/`clientonly`) in
      plain, non-jargon language a non-technical operator can act on
      without reading this codebase's own comments (e.g. "changes apply
      immediately" / "takes effect after the next restart" / "an operator
      must edit the config file and restart" / "cannot be forced off for
      players already connected — only the player's own settings/client
      controls this").
    - **This is a copy/labelling task on top of data the server already
      returns** (`runtimeListFeatures`'s `tier` field) — not a new backend
      field.
- [ ] The two lockout-risk infrastructure switches (`HighCommand`,
      `PermissionGrants`) remain reachable and toggleable (with their
      existing typed-confirmation gate, §6.5) — the rework must not
      quietly re-hide them behind a "protected, cannot be changed here"
      wall now that the product decision has already been made to expose
      them instead.
- [ ] One-shot trigger actions (certify/decertify/give XP/recall/etc.) are
      never presented with an "always active" toggle of their own — only
      their governing `Config.Features` flag (if any) gets one.
- [ ] The owner has confirmed which reading (§3.2 A or B) is intended
      before any work beyond UI reorganization of the existing Runtime
      Control screen begins.

---

## 4. Colour versus text

### 4.1 The existing in-world palette — the tablet must agree with it, not invent a second one

`Config.Tracking.ScentVision.palette` (`config.lua` lines 1862–1868) is the
**one and only** person-to-colour scheme already shown to players in the
world today:

```
{ r = 230, g = 25,  b = 75  }  -- red
{ r = 60,  g = 180, b = 75  }  -- green
{ r = 255, g = 225, b = 25  }  -- yellow
{ r = 0,   g = 130, b = 200 }  -- blue
{ r = 245, g = 130, b = 48  }  -- orange
```

One fixed swatch per visible trail slot (`maxVisibleTrails = 5`), assigned
per **person**, never per permission or feature — explicitly not a
"colour-vision-deficiency-optimised set" by the config's own comment, just
maximum hue/lightness separation. **Any tablet colour scheme applied to
scent content must reuse this exact five-colour swatch for anything that
represents a specific tracked person**, and must not introduce a second,
different "scent colour language" the player would have to learn on top of
the one already burned into the HUD overlay. Where the tablet needs
colour for something that is *not* per-person (e.g. a status badge,
"fresh" vs "fading"), it should draw from the tablet's own existing
four-variable theme system (`--k9tablet-primary/accent/bg/text`,
`html/tablet.css` `:root`), not a third, unrelated palette.

### 4.2 There is currently nothing to re-skin

As found in §1.2 (finding 6): no dedicated scent screen and no dedicated
vehicle screen exist. `ScentTracking`/`ScentVision`/`ScentLineup`/
`ScentTrailHunt`/`BloodTracking`/`GunpowderSniffing` and `VehicleEntryExit`
are today ordinary rows, styled identically to every other feature row,
inside My Record / Console-Person's generic feature list. This means §4's
request is really two asks bundled together:

1. Give scent-family and vehicle-family content **somewhere to live** that
   is recognizably its own (at minimum: a labelled section within an
   existing screen; at most: dedicated tabs).
2. Style that content differently — colour-forward for scent, text-forward
   for vehicle.

### 4.3 Concrete proposal

- **Tag features by domain**, reusing and extending the taxonomy that
  already exists for a *subset* of features via `COMMAND_REFERENCE`'s
  `category` field (`scent_games`, `basic_commands`, etc.) — that tagging
  only covers command-triggered features today; it needs a small,
  explicit, hand-maintained table extending domain tags to every
  scent-family and vehicle-family `Config.Features` key, mirroring this
  codebase's own established pattern for exactly this kind of "small,
  explicit, code-owner-maintained registry" (`NOT_ENFORCEABLE_FEATURES`/
  `CLIENT_ENFORCED_FEATURES` in `server/tablet.lua` are the precedent to
  copy, not a new mechanism).
- **Scent section** (on My Record for a Handler/K9, and as its own grouped
  block on Console/Person for admins): each tracked-person or trail-state
  row gets a colour swatch pulled from §4.1's real palette where a specific
  person is represented (e.g. "you are currently able to see: [red dot]
  Officer Smith's trail, fading"); ability rows (Scent Vision on/off,
  Scent Lineup certified-or-not) get colour-coded status badges reusing
  the tablet's existing available/blocked/global_off classes rather than a
  new colour meaning.
- **Vehicle section**: given there is genuinely only one vehicle-specific
  feature flag today, "more text-based" concretely means: when
  `VehicleEntryExit` (and any future vehicle feature) is shown, prefer a
  plain sentence describing what it does and its current state over a
  colour badge — e.g. the existing Help walkthrough style
  (`help_task_vehicle_3`'s prose) rather than the badge-and-swatch
  treatment scent gets. This is a low-cost styling rule (a CSS
  modifier + a "verbose" text template), not a new screen, and should be
  scoped that way rather than over-built into a dashboard that has almost
  nothing to show yet.
- **Recommendation on scope**: build the domain-tagging table and the two
  section groupings (§7 Stage 4) before committing to two brand-new
  full-screen dashboards. If, after that lands, scent content still feels
  too small a section to justify its own tab, that is a legitimate reason
  to stop there rather than manufacture a bigger screen than the feature
  set supports.

### 4.4 Acceptance criteria

- [ ] Every tablet element representing a *specific tracked person's*
      scent trail uses one of the five real `Config.Tracking.ScentVision.palette`
      RGB values, sourced from that config table (or a value the server
      sends derived from it) — never a hardcoded, independently-invented
      hex value.
- [ ] No new person-to-colour mapping is introduced anywhere in the
      tablet that could disagree with what the in-world ScentVision
      overlay shows for the same person.
- [ ] Vehicle-related rows/sections use plain-sentence status text as the
      primary presentation, with colour reserved for the same
      available/blocked/disabled semantic classes every other screen
      already uses — not a new vehicle-specific colour language either.
- [ ] A feature's domain tag (scent / vehicle / neither) is derived from
      one small, explicit, reviewable table — never guessed from the
      feature's name string at render time.
- [ ] Scent-family and vehicle-family content is visually and structurally
      distinguishable from the generic feature list on at least one screen
      a Handler/K9 actually uses (Home or My Record), not only on an
      admin-only screen.

---

## 5. The logo — blocking dependency on the owner

**Verified directly**: `john-k9/html/images/logo.png` is a 512×512 PNG
showing a plain crimson-red filled circle with a brighter red ring, on a
solid near-black background — no wordmark, no crest, no text, no
Crimson-Roleplay-specific imagery of any kind. This is a placeholder, not
the real server logo, and the surrounding code already treats it as such:
`config.lua`'s own comment (line 1135) says the starting theme colours were
"matched to the shipped logo (crimson red on near-black)" — i.e. the
placeholder's colour was chosen to *not clash* with itself, which is a
strong signal nobody currently believes this is final art.

**Everything that will render the real logo already exists and is
tested**: the header mark (`.k9tablet-branding-logo`), the larger
one-off landing badge (`.k9tablet-branding-mark-logo`), and the
text-fallback-on-load-failure behaviour (`html/tests/tablet_branding_placement_spec.js`)
are all shipped and shape-agnostic by design — `html/tablet.css`'s own
comment block (lines 137–145) is explicit that "the operator drops in a
replacement file at the SAME path with no code change on either side," and
that nothing in the CSS may assume a square, a wide wordmark, or a tall
crest.

**This is a blocking dependency on the owner, not on any coder:**

- **Path**: `john-k9/html/images/logo.png` (referenced by
  `Config.CommandTablet.branding.logo = 'images/logo.png'`, `config.lua`
  line 1133) — replace the file in place, at the exact same path and
  filename. No config or code change is needed to pick up a new file.
- **Format**: PNG (the existing fallback/error-listener logic is written
  against an `<img>` `error` event; any browser-renderable raster the
  `<img>` tag accepts would technically work, but PNG is what the path and
  every comment assume — stick with PNG unless there's a reason not to).
- **Size/shape constraints, from the CSS that will render it**:
  - Header mark: rendered at a fixed **28px height**, `width: auto`,
    capped at **64px max-width**, `object-fit: contain` (never cropped or
    stretched — a wide wordmark letterboxes inside that width cap rather
    than distorting).
  - Landing badge: rendered at a fixed **96px height**, `width: auto`,
    capped at **240px max-width**, same `contain` behaviour.
  - **No particular aspect ratio is required or assumed** — square, wide
    wordmark, or tall crest all work identically; the constraints above
    exist only to stop an extreme ratio from overrunning the header row or
    distorting.
  - A near-black or edge-to-edge logo with no transparent margin will get
    a faint theme-neutral ring/tint applied around it automatically (so it
    doesn't blend invisibly into the header) — this happens regardless of
    what the source image looks like, no special preparation needed on
    the owner's side for that.
- **What happens if it's never replaced**: nothing breaks. The existing
  fallback renders the server name as text instead of a broken image
  icon. The rework can and should ship with the placeholder still in
  place; "the logo is everywhere" (§0 ask #2) will visually read as "the
  placeholder circle is everywhere" until the owner supplies the real
  file — flagged here so nobody on the build side is surprised by that, or
  tempted to invent a logo themselves. **Do not invent a logo.**

### 5.1 Acceptance criteria

- [ ] No code change is required for the owner to swap the logo — replacing
      the file at `john-k9/html/images/logo.png` is sufficient.
- [ ] The spec's "logo all over the UI" ask is interpreted as: header mark
      (every screen, already shipped), landing badge (already shipped),
      and — new, if within scope of a given build stage — repeated as a
      watermark/accent on additional screens the rework adds, always via
      the same shape-agnostic, `object-fit: contain`, text-fallback-safe
      pattern, never a raw `<img>` with no fallback.
- [ ] `html/tests/tablet_branding_placement_spec.js` continues to pass
      unmodified in its assertions about fallback behaviour; new
      placements get new test coverage in the same file or a sibling,
      never untested.

---

## 6. What not to break

Every guarantee below is real, currently enforced by a named test file,
and must still hold after the rework. None of these should need to change
shape for anything in §2–§5 above — the rework is a presentation/
information-architecture change, not a contract change.

### 6.1 The three-way locale contract

`html/tablet.js`'s `DEFAULT_STRINGS`, `client/tablet.lua`'s
`TABLET_STRING_KEYS`, and `locales/en.json`'s `tablet` group must all carry
the exact same set of keys — a key added to one without the other two
silently degrades to the English fallback forever, no error either side.
Enforced by **`tests/tabletlocalization_spec.lua`**. Any new string the
rework needs (new tab labels, new section headings, new plain-language
tier descriptions from §3.4) must land in all three places in the same
change.

### 6.2 The command-reference drift guard

Every real `RegisterCommand(...)` call across `server/*.lua` and
`client/*.lua` must have a matching entry in `html/tablet.js`'s
`COMMAND_REFERENCE`, and vice versa — enforced by
**`tests/commandreferenceregistry_spec.lua`**. A related guard,
**`tests/helptabcoverage_spec.lua`**, keeps every real tab's `tab_*` label
key mentioned in the Help screen's own tab catalogue. A third,
**`tests/helpquotedlabels_spec.lua`**, keeps Help's verbatim quotes of
real in-game button text in sync with the actual locale strings they
quote. If the rework renames or merges any tab, or any command's
availability changes, all three of these must be updated in the same
change, not after.

### 6.3 XSS discipline — textContent only, never innerHTML

`html/tablet.js` writes every dynamic value (names, citizenids, notes,
labels — including the operator-supplied `serverName`/logo path) via
`.textContent` or an `alt`/`src` attribute, **never** `.innerHTML` —
confirmed directly: the only three `innerHTML` mentions in the file are
comments documenting this discipline, not actual writes. Proven by
**`html/tests/tablet_xss_spec.js`**. Any new screen the rework adds must
build its DOM through the same `mk()`/`mkButton()` helpers this file
already uses, which enforce this by construction — never string-concatenate
HTML for a new component.

### 6.4 The tablet decides nothing — server-side re-check on every request

Stated identically at the top of `html/tablet.js`, `client/tablet.lua`, and
`server/tablet.lua`: every mutating action is re-authorized server-side
from the caller's live job/grants/blocks on every single call, never from
a client-supplied flag or a cached `viewer.isHighCommand`. This is not
enforced by one file but by the consistent shape of dozens of specs —
**`tests/tabletserver_spec.lua`**, **`tests/tabletblockenforcement_spec.lua`**,
**`tests/runtimecontrol_spec.lua`**, **`tests/certtiers_spec.lua`**,
**`tests/permissionkeycatalog_spec.lua`**, **`tests/equipmentshop_spec.lua`**,
**`tests/equipmentshopitems_spec.lua`**, **`tests/k9profiles_spec.lua`**,
**`tests/xptiereditor_spec.lua`** each assert that hiding a UI control
never changes what the server refuses. A UI reorganization that changes
*which* controls are shown to *which* role (§2) never gets to skip or
soften a server-side check to make the new layout "work" — if a face's
layout implies a capability, the server-side gate for that capability must
already exist and be re-verified, exactly as it is today.

### 6.5 Typed confirmation for lockout-risk settings

`server/runtimecontrol.lua`'s `FEATURE_TIERS` marks `HighCommand`,
`PermissionGrants`, `RuntimeFeatureControl`, `TabletTheming`, and
`CommandTablet` as `lockoutRisk = true` — flipping any of them off refuses
outright (`reason = 'confirmation_required'`) unless the caller's request
carries a `confirm` string matching that feature's own name **exactly**,
checked **server-side, independently, on every call**, never trusted from
what the tablet UI happened to show. `html/tablet.js`'s Runtime Control
screen requires the operator to read the server's own warning text and
type the feature's name before it will even send that second call. Proven
by **`html/tests/tablet_runtime_control_spec.js`** (asserts the server's
own `lockoutWarning` text is shown verbatim, and that a stale/bypassed
confirm gets its own distinct refusal message) and
**`tests/runtimefeaturetiers_spec.lua`** (keeps every `Config.Features` key
tiered, so nothing new can silently ship without this classification
being decided). The rework must not build a second, simpler "toggle"
control anywhere that bypasses this gate for a `lockoutRisk` feature —
including inside any new role-based Home section from §2.

### 6.6 Other drift guards worth knowing about while touching this file

- **`tests/runtimefeaturetiers_spec.lua`** — `Config.Features` and
  `FEATURE_TIERS` must stay 1:1; relevant to §3's on/off exposure work.
- Extensive per-screen behavioural coverage already exists and must keep
  passing unmodified in intent (though selectors/exact copy may need
  updating alongside a genuine rename): `html/tests/tablet_home_spec.js`,
  `tablet_partnerships_spec.js`, `tablet_help_tab_spec.js`,
  `tablet_command_reference_spec.js`, `tablet_role_theme_certtiers_spec.js`,
  `tablet_guided_flows_spec.js`, `tablet_console_spec.js`,
  `tablet_person_rank_partnership_spec.js`,
  `tablet_certification_granter_name_spec.js`,
  `tablet_permission_catalog_capabilities_spec.js`,
  `tablet_shop_locations_spec.js`, `tablet_shop_items_spec.js`,
  `tablet_admin_features_spec.js`, `tablet_block_enforcement_spec.js`,
  `tablet_client_enforced_spec.js`, `tablet_xp_tiers_spec.js`,
  `tablet_mutation_error_spec.js`, `tablet_stale_response_spec.js`,
  `tablet_open_close_spec.js`, `tablet_bridge_spec.js`,
  `tablet_keyboard_operability_spec.js`.
- **Keyboard operability** (`tablet_keyboard_operability_spec.js`) and the
  **focus/close discipline** documented at length in `client/tablet.lua`'s
  own header (four independent close paths, all funneling through one
  `CloseTablet()`, cross-resource focus interop, downed-by-takedown
  force-close) are not visual concerns but must survive a DOM
  restructuring untouched — a rework that changes *what* is rendered must
  not change *how* focus/escape/close are wired.

---

## 7. Staged plan

Each stage is independently buildable, testable, and shippable — the
tablet must remain fully functional after every stage, never left broken
mid-rework. Ordered by dependency; stages marked **[parallel]** have no
dependency on each other and can run concurrently across multiple
coders/agents.

**Stage 0 — Owner decisions (blocking, no code).**
Resolve the two items in §9 (the "always active or not" reading, and the
visual-separation question for dual-role Home content is a design call,
not listed in §9, but flag it to coder-ui before Stage 2 starts). Owner
supplies (or explicitly defers) the real logo file per §5.

**Stage 1 — Domain tagging table [parallel with Stage 2].**
Add the small, explicit scent/vehicle (and, if useful, other domains)
feature-tagging table proposed in §4.3, plus the corresponding
`myFeatures[].category`/`features[].category` population server-side
(currently always `nil` — see `server/tablet.lua`'s
`BuildMyFeaturesArray`/`BuildPersonFeaturesArray`). Backend-only; no UI
change yet. Testable in isolation against `server/tablet.lua`'s own specs.

**Stage 2 — Role-face restructuring of Home [depends on Stage 0's design call].**
Rebuild `buildHomeScreen()`'s layout per §2.2–§2.3: K9/Handler leading
content unchanged in substance, a visually distinct High Command section
boundary, explicit "pre-face" (no-role) state expanded per §2.4. No tab
bar changes yet — this stage only touches Home's own body.

**Stage 3 — Runtime Control exposure/relabelling [parallel with Stage 2 and Stage 4].**
Apply §3.4's plain-language tier labelling to the existing Runtime Control
screen; group rows (e.g. gameplay vs. infrastructure) rather than one flat
table of ~56. No backend change — `FEATURE_TIERS` and its API already
provide everything needed (§3.1).

**Stage 4 — Scent/vehicle sectioning [depends on Stage 1].**
Using Stage 1's domain tags, add the scent-colour and vehicle-text
sections to My Record (Handler/K9 view) and to Console/Person (admin
view), per §4.3. Reuses `Config.Tracking.ScentVision.palette` directly —
no new colour data.

**Stage 5 — Tab bar reorganization [depends on Stage 2 and Stage 3 both landing, to avoid restructuring around a layout that's about to change twice].**
Resolve finding 1 from §1.2 (flat tab bar vs. grouped Home both existing
today) by picking one structure — most likely: keep the five universal
tabs plus Console top-level, and collapse the twelve admin screens under a
single "High Command" entry point that opens Home's existing grouped
section rather than adding eleven more top-level tabs. Requires updating
`tests/helptabcoverage_spec.lua`'s and `tests/commandreferenceregistry_spec.lua`'s
expectations in the same change (§6.2).

**Stage 6 — Logo/branding pass [parallel with everything else once Stage 0's asset is available; can also ship with the placeholder still in place and be revisited later at zero cost].**
Apply the real logo per §5 wherever "throughout the UI" is scoped to reach
in a given build; no code changes needed for the swap itself, only for any
*new* placements the rework adds (each needs the same fallback-safe
pattern, §5.1).

**Stage 7 — Full regression pass [sequential, last].**
Run every test file named in §6 plus the full existing suite; confirm no
locale-key drift, no command/tab drift, no XSS-discipline regression, no
authorization-check softening, and that the lockout-risk confirmation flow
is untouched. This is correctness-overseer's stage, checked directly
against this document's acceptance-criteria checklists.

---

## 8. Tensions and scope honesty

- **"One tablet, three faces" vs. "high command has 12 extra screens" is a
  real tension**, not a contradiction to paper over: a High Command face
  that stays visually consistent with the Handler/K9 face it's layered on
  top of will necessarily feel *less* like "twelve dedicated tools" and
  *more* like "one tool with a big options section." Recommended
  resolution: lean into that — collapse the twelve admin tabs into fewer,
  better-organized entry points (Stage 5) rather than preserving all
  twelve as equally-weighted top-level tabs just because they exist today.
  This is the direction `buildHomeHighCommandTools()` already points; the
  rework should finish that thought rather than leave both structures in
  place.
- **"More colour for scent" vs. "agree with the existing in-world
  palette" is a soft tension**: a five-colour, hue-separated swatch
  designed for telling five *simultaneous* trails apart on a 3D minimap is
  not automatically also a good *UI accent palette* for badges, headings,
  and section dividers. Recommended resolution: use the real five-colour
  swatch strictly for per-person trail identity (the one place it must
  match the world exactly), and let everything else scent-related lean on
  the tablet's own existing theme accent colour more heavily than other
  sections do — "more colourful" without minting a second, disagreeing
  meaning for the same five colours.
- **"Full rework of the UI" vs. "do not break the locale/XSS/authorization/
  drift-guard contracts" is not actually a tension** — every one of those
  contracts is about *what data crosses which boundary safely*, not about
  layout, wording, or navigation structure, all of which are exactly what
  a UI rework changes. The size of the test suite in §6 should be read as
  a sign the tablet is safe to restructure aggressively, not as a reason
  to be timid — as long as every renamed tab/string/command is updated in
  the same tests, not left to drift.
- **Scope honesty on "always active or not" (§3)**: if Reading B (§3.2) is
  what's actually wanted, that is a genuinely large, separate piece of
  work — new persisted per-feature-or-per-player behaviour state, plus
  code changes inside every feature file that would need to auto-engage —
  and should be scoped, staffed, and tested as its own project, not folded
  into "the tablet rework" as if it were a UI change. Said plainly here so
  it isn't quietly shrunk to "relabel the existing Runtime Control screen"
  if that isn't actually what was meant.
- **Scope honesty on scent/vehicle screens (§4)**: vehicle-related content
  is currently one feature flag. "More text-based" for vehicle is a real,
  small, doable ask; it is not, on its own, enough content to justify a
  full dedicated vehicle *tab* the way scent's six features might justify
  a scent section. Building an oversized vehicle dashboard to match
  scent's would be scope creep in the other direction — recommended
  against in §4.3.

---

## 9. Open questions for the owner

1. **"Always active or not" (§3.2)** — is this asking for (A) a visible
   on/off switch per feature, honestly labelled by whether it applies
   instantly, on next restart, or not at all from the tablet (already
   ~95% built, mostly a labelling/exposure task) — or (B) a
   continuous-vs-manually-triggered *behaviour* setting per ability (a
   substantial new feature touching many files)? The cost difference is
   roughly an order of magnitude; please confirm before Stage 3/anything
   beyond it begins.
2. **Tab bar collapse (§7 Stage 5)** — is collapsing the twelve admin
   screens into a smaller number of top-level entry points (relying on
   Home's existing grouped section as the real navigation) an acceptable
   reading of "easier to understand," or is keeping every current
   capability as its own always-visible top-level tab (just reorganized)
   preferred? This changes how aggressively Stage 5 can restructure
   `buildTabs()`.
3. **Logo timeline** — can the real Crimson Roleplay logo file be supplied
   before Stage 6, or should that stage proceed against the current
   placeholder and be revisited later at no extra cost (the code needs no
   change either way, per §5)?
