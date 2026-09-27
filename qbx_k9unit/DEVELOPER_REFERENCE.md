# qbx_k9unit — Developer Reference

**Consolidated 2026-08-25.** This one file replaces fifteen previously
separate documents: `SPEC.md`, `PHASE3_SPEC.md`, `PHASE4_SPEC.md`,
`PHASE5_SPEC.md`, `REFACTOR_ROADMAP.md`, `phase2_notes/RESEARCH_ARCHIVE.md`,
`PROJECT_STATUS.md`, `WATCHDOG_LOG.md`, `FEATURE_IDEAS.md`, `DOCS_INDEX.md`,
`locales/README.md`, `tests/README.md`, and `shared/compat/README.md` (all
deleted — their content lives below or was cut as superseded decision
history), plus `sql/rollback/README.md` and `sql/README.md` (folded into
`README.md` instead, since removal/day-to-day-operation instructions
belong with the other operator-facing material, not here).

**Section numbers below are preserved from the source documents on
purpose.** Hundreds of code comments across this resource cite a section by
number (e.g. `SPEC.md §4.2`, `PHASE3_SPEC.md §12.5.1`, `PHASE4_SPEC.md
§13.4.2`, `REFACTOR_ROADMAP.md item 1`, `RESEARCH_ARCHIVE.md#tracking`,
`FEATURE_IDEAS.md Part A §2`). Every one of those numbers/anchors still
means the same thing here — only the filename changed, to `DEVELOPER_REFERENCE.md`.
If you're trying to resolve a citation from a code comment, find its
section number below; it hasn't moved.

**What was cut, and why:** these source documents totaled roughly 5,700
lines, most of it decision *history* — rejected alternatives, corrections to
corrections, revision-by-revision narration, "verified again, still true"
audit trails. None of that is reproduced here. What's kept is: a live
constraint the code still depends on, a question that's genuinely still
open, and — where a rejected idea would obviously get re-proposed by
someone who didn't know it had already been tried — a one-line note saying
so. If something below disagrees with `config.lua` or the actual `.lua`
files, **the code wins**; nothing here is a second copy of the code's
current behavior.

**Where to look for what:**

| You want... | Read |
|---|---|
| Why this resource is designed the way it is (goals, hard requirements, certification model) | §1–§10 below |
| The detailed per-feature spec for a phase (config shape, event contracts, open items) | §11 (Phase 2), §12 (Phase 3), §13 (Phase 4), §14 (Phase 5) |
| Confirmed native behavior / security review findings other code relies on | §15 |
| Known technical debt and what's already been fixed | §16 |
| Current live/off status of flags and operator decisions still needed | §17 (superseded day-to-day by `README.md` and `KNOWN_ISSUES.md` — this section is the historical reasoning) |
| Not-yet-built feature ideas | §18, and the roadmap section of `PROJECT_HISTORY.md` |
| How the locale/translation system works | §19 |
| How the automated test suite works | §20 |
| How the `shared/compat` resource-detection layer works | §21 |
| Install steps, current config reference, exports, day-to-day operation, and how to play a K9 | `README.md` |
| Open bugs, limitations, and decisions waiting on the resource owner | `KNOWN_ISSUES.md` |
| What shipped and when, and how the project got to its current state | `PROJECT_HISTORY.md` |

---

## 1. Goal

The K9 is a **player's own persistent character** — someone creates their
character as a dog ped from the start via the server's own
character-creation system (outside this resource's scope; this resource
never spawns, despawns, or possesses a ped on anyone's behalf). That
K9-playing player is **hired** into an eligible department through the
server's normal job-hiring flow (also outside this resource's scope), then a
qualifying officer **certifies** them (§4), granting access to K9-specific
mechanics for as long as they hold both the job and an active certification.
**Getting fired from the department automatically revokes the certification**
(§4.4).

Every subsystem is independently toggleable, and access control is a real,
persistent, server-authoritative permission system, not a hardcoded
job/rank check.

**"Handler" in this document means a partnered human officer** working
alongside the K9 player (leash-together, handler-down defense — §4.4, §9),
never someone who spawns, selects, or remote-controls the K9. The K9 player
controls themselves directly, like any other player character, at all times.

---

## 2. Scope

### In scope (this resource, across all phases)
- Qbox-only (qbx_core, ox_lib, ox_target, ox_inventory, oxmysql). No ESX.
- Multi-department, certification-based access control (hard requirement 2).
- Config-driven ped roster, feature toggles, department list, rank thresholds
  (hard requirement 1).
- K9 model detection, quadruped movement, leash mechanics, radial self-action
  menu, vehicle load/unload, bark sounds (Phase 1).
- Scent/blood/water/gunpowder tracking, search zones, contraband alert tiers,
  thermal/night vision (Phase 2).
- Bite-and-hold, non-lethal takedown, handler-down defense mode, prop
  dragging, agility mode (Phase 3).
- ox_inventory K9 stash, XP/progression, vitality HUD, K9 medkit, contraband
  screen effect (Phase 4).
- Advanced bark radial, proximity audio attenuation, prop attachments, fetch
  mechanic, deployable kennel, K9 camera feed R&D spike (Phase 5).

### Explicit non-goals
- **ESX support, and QBCore support.** `Config.Compat`'s framework
  detection correctly identifies `qb-core` if you run it, but detection was
  never adaptation — the large majority of this resource's server-side call
  sites talk to Qbox (`qbx_core`) directly rather than through the
  framework compat layer (a grep of direct `exports.qbx_core` calls outside
  `shared/compat/` and outside the test suite lands somewhere in the
  160s–190s depending on exactly what's counted), and `qbx_core` is a hard
  `fxmanifest.lua` dependency regardless of what's detected. See
  `README.md`'s own "No QBCore or ESX support" section and `config.lua`'s
  `Config.Compat.Systems.framework` comment for the current, full story.
- **True live-video PiP camera feed** of the dog's point of view. Concluded
  infeasible without new native support — see §7/§15 (`#phase-5-research`).
  Do not re-propose without a real engine-level capability landing in FiveM
  first; only a feasibility spike was ever committed, and it already ran.
- **Permanent scar overlay textures.** Needs a custom ped
  texture/decoration-asset pipeline outside plain scripting.
- **Bespoke mocap animation sets** for bite-hold, agility, and limp gaits.
  Approximated with native anim dictionaries/task natives (§7); true custom
  animation is an art-asset request, not a coding one.
- **AI-controlled/automatic patrol K9s, or any "one active K9 per handler" /
  spawn-despawn concept.** The K9 is always a real player's own persistent
  character.
- **Integration with a specific third-party bodycam/dashcam resource.**
  Exports/events are exposed so integration is *possible*; no particular
  external resource is assumed to exist.

---

## 3. Hard requirement 1 — config-driven, in detail

Every feature area maps to one boolean in `Config.Features`, read at the
point where that feature activates (event registration, thread start, menu
item visibility, command registration) — never cached once at resource
start and then ignored. Setting `Config.Features.X = false` and restarting
must remove that feature's client-visible surface **and** make its
server-side handlers a no-op — a disabled feature must not be triggerable by
a modified client. `Config.Peds` is a recognized K9 **model list**, never a
spawn roster; adding a model needs zero `.lua` changes outside config, and
default ships exactly `a_c_shepherd`, `a_c_rottweiler`, `a_c_huskie`,
`a_c_chop`.

---

## 4. Hard requirement 2 — multi-department certification access

### 4.1 Design decision

**Access rule:** `player.job.name ∈ Config.Departments` **AND** the player
holds an **active** K9 certification for that job, checked **server-side**
on every gated action — never cached client-side as a one-time pass.

**Exception:** K9 vehicle entry/exit (`client/vehicle.lua`) is deliberately
**client-only**, no server-side re-check — it grants no real capability
(it only seats the acting player's own ped into a real, free vehicle seat
via client-side natives, the same kind of thing the player's ordinary
"enter vehicle" control already lets them do to themselves), so a modified
client gains nothing here it couldn't already get by calling the same
client-only natives on itself. Revisit if a later feature ever conditions
something server-authoritative on vehicle state.

**Rank auto-bypass:** by default, **no rank auto-bypasses certification**,
including a department's own chief/boss. `autoAccessGrade` is an optional
per-department config field for a boss-rank bypass, defaulting to `nil`
(disabled).

**Self-certification:** `Config.AllowSelfCertification` (default `true`)
lets a certifier-grade+ officer grant/revoke their own certification, to
bootstrap a fresh server. Settable `false` to force a second-party grant.

### 4.2 Certifier eligibility

A player may grant or revoke a K9 certification for a target if:
1. Granter's `job.name` is a key in `Config.Departments`, AND
2. Granter's `job.grade.level >= Config.Departments[job].certifierGrade` **OR**
   `job.isboss == true`, AND
3. Target's `job.name` is a key in `Config.Departments` (any listed
   department, not necessarily the granter's own — cross-department
   certifying is intentional; see §9 item 2 if this should be narrowed).
4. Granter and target are within **5 meters** at the moment the
   grant/revoke is processed **server-side** (live entity coords, never a
   client "I'm near them" claim) — applies to both the ox_target flow and
   the slash-command flow.
5. Target's *current* ped model — read server-side via `GetEntityModel`,
   never client-reported — hashes to a `Config.Peds` entry. Grant-only; a
   revoke is always possible regardless of the target's current model
   (including via §4.4's automatic path).

### 4.3 Certification data model

**Dedicated DB table is the source of truth**, not qbx_core metadata alone
— revocation must work while the target is offline, an audit trail is a de
facto requirement for a permission this consequential, and a table
trivially supports "list all certified handlers in department X." A
read-only boolean mirror (`metadata.k9certified`) is written for
**client-side HUD display only** — never read by a server-side check: the
client can see its own cert flag, the server never trusts it.

Schema (see `sql/install.sql` for the exact, current DDL):

```sql
CREATE TABLE IF NOT EXISTS `k9_certifications` (
  `id`              INT UNSIGNED NOT NULL AUTO_INCREMENT,
  `citizenid`       VARCHAR(50)  NOT NULL,
  `job`             VARCHAR(50)  NOT NULL,
  `granted_by`      VARCHAR(50)  NOT NULL,
  `granted_at`      DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `revoked_by`      VARCHAR(50)  DEFAULT NULL,  -- or a sentinel like 'system:job_change' for §4.4 auto-revokes
  `revoked_at`      DATETIME     DEFAULT NULL,
  `active`          TINYINT(1)   NOT NULL DEFAULT 1,
  `active_cert_key` VARCHAR(105) GENERATED ALWAYS AS (
    CASE WHEN `active` = 1 THEN CONCAT(`citizenid`, '::', `job`) ELSE NULL END
  ) VIRTUAL,
  PRIMARY KEY (`id`),
  KEY `idx_citizen_job_active` (`citizenid`, `job`, `active`),
  KEY `idx_job_active` (`job`, `active`),
  UNIQUE KEY `uq_one_active_cert_per_job` (`active_cert_key`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
```

**Invariant: at most one `active = 1` row per `(citizenid, job)`**, enforced
at both layers — app-level (grant pre-checks and no-ops if an active row
exists; revoke sets `active = 0` rather than deleting) and DB-level (the
`uq_one_active_cert_per_job` unique index on the generated column closes the
check-then-act race between two near-simultaneous grants; MySQL treats every
`NULL` as distinct, so revoked rows never collide). **Treat a duplicate-key
error (1062) on the grant INSERT as the same "already certified" no-op, not
an unhandled error.**

**Flow summary:**

| Step | Actor | Mechanism |
|---|---|---|
| Grant | Certifier via ox_target or `/k9certify [id]` | eligibility check (§4.2) → INSERT → cache update → notify both |
| Revoke, online | Certifier via ox_target or `/k9decertify [id]` | eligibility check → UPDATE → cache update → notify |
| Revoke, offline | `/k9decertify [citizenid] [job]` — the same command, which routes on the argument's shape (all digits means a server id) | UPDATE by citizenid+job, no proximity/model check possible |
| Revoke, automatic | System, on leaving the department | `QBCore:Server:OnJobUpdate` (§4.4) |
| Check | Any gated action | `hasK9Access` callback: job ∈ Departments AND (cache OR autoAccessGrade) |
| Display only | Client HUD | own `metadata.k9certified` mirror, never used for authorization |

**Security note:** every mechanism above must re-verify server-side,
independent of what the requesting client claims about its own job, rank,
proximity, or ped model. Client-side visibility is a UX convenience only.

### 4.4 Automatic revocation on leaving the department

A certification is only valid while the holder is actually employed by an
eligible department — leaving (including being fired) **automatically
revokes it**, and it does not silently return on rehire without
re-certification.

**Mechanism:** `AddEventHandler('QBCore:Server:OnJobUpdate', function(source, job) ... end)`
— a real, non-networked qbx_core server event covering both legacy-QBCore
and Qbox-native hire/fire flows.
([Qbox server events docs](https://docs.qbox.re/resources/qbx_core/events/server))

**Handler logic:** resolve citizenid → look up the cached *previous* job →
if it held an active cert for that job and the new `job.name` differs, run
the standard revoke with `revoked_by = 'system:job_change'` → refresh cache →
notify if online.

**Load-bearing consequences:** a cert is **job-scoped** (leaving and
rejoining later does not restore it — a fresh grant is required); a
**grade change within the same department must never revoke** (guard on
`job.name` changing, not on `OnJobUpdate` firing at all, or every promotion
silently strips certifications); the automatic path is server-triggered
only, with no client-callable equivalent.

### 4.5 Recognizing a K9 character

No spawn step exists to hang model detection off:

- **Authoritative (server):** wherever the model matters for a security or
  role-assignment decision — §4.2 item 5's certify-eligibility check, and
  leash role-assignment (§6.1) — the server reads it live via
  `GetEntityModel(GetPlayerPed(targetServerId))` against `Config.Peds`
  hashes. Never trust a client-reported model. One shared helper
  (`IsConfiguredK9Model`) backs every such check.
- **Convenience (client):** the client may check its own model purely to
  decide whether to show K9-specific UI. Display optimization only — a
  modified client showing itself the menu still gets rejected server-side.
- **No new persistent storage needed** — the ped model is already part of
  the player's persistent character. If a server's separate
  appearance/customization resource can change the base model mid-session,
  the live check could theoretically race a swap — see §9 item 8, not
  addressed speculatively here.

---

## 5. Config schema (concrete shape)

Phase 1's original schema is illustrated below; Phase 2–5 additions are
specified next to the section that scoped them (§11.2, §12.2, §13.2, §14.2).
**`config.lua` itself, not this section, is the source of truth for the
complete current schema and values** — this is a design-intent snapshot,
not a duplicate maintained in sync.

```lua
Config = {}

Config.Features = {
    -- Phase 1
    LeashMechanics       = true,
    RadialMenu           = true,
    VehicleEntryExit     = true,
    BasicBarkSounds      = true,
    AgilityBasicJump     = true,

    -- Phase 2 (tracking & vision)
    ScentTracking = false, BloodTracking = false, WaterTrackingDecay = false,
    GunpowderSniffing = false, SearchZones = false, ContrabandAlerts = false,
    ThermalVision = false, NightVision = false, DoorInteraction = false,

    -- Phase 3 (combat & action)
    BiteAndHold = false, NonLethalTakedown = false,
    PropDragging = false, AgilityAdvanced = false,

    -- Phase 4 (inventory, progression, vitality)
    K9Inventory = false, XPProgression = false, HealthStaminaHUD = false,
    FatigueSystem = false, K9Medkit = false,
    ContrabandScreenFX = false,

    -- Phase 5 (audio/props/advanced vision R&D)
    AdvancedBarkRadial = false, ProximityAudioFX = false, PropAttachments = false,
    FetchMechanic = false, DeployableKennel = false, CameraFeedPiP = false, -- experimental, see §7
}

Config.Peds = {
    { model = 'a_c_shepherd',   label = 'German Shepherd' },
    { model = 'a_c_rottweiler', label = 'Rottweiler' },
    { model = 'a_c_huskie',     label = 'Husky' },
    { model = 'a_c_chop',       label = 'Chop (K9 Unit)' },
    -- Adding a streamed custom model needs only a new entry here.
}

Config.Departments = {
    ['police']  = { label = 'Los Santos Police Department', certifierGrade = 4, autoAccessGrade = nil },
    ['sheriff'] = { label = 'Blaine County Sheriff',         certifierGrade = 3, autoAccessGrade = nil },
    ['bcso']    = { label = 'Blaine County Sheriff (legacy job name)', certifierGrade = 3, autoAccessGrade = nil },
}

Config.AllowSelfCertification = true   -- §4.1
Config.CertifyProximityMeters = 5.0    -- §4.2 item 4

Config.K9Vehicles = { 'police', 'police2', 'police3', 'police4', 'sheriff', 'sheriff2' }
Config.VehicleInteractMeters = 3.0

Config.LeashMaxDistance = 8.0   -- meters before auto-recall-to-heel

Config.XPTiers = {
    { xp = 0,    label = 'Recruit K9', speedMultiplier = 1.00, scentRange = 5.0  },
    { xp = 500,  label = 'Trained K9', speedMultiplier = 1.05, scentRange = 6.5  },
    { xp = 1500, label = 'Veteran K9', speedMultiplier = 1.10, scentRange = 8.0  },
    { xp = 3500, label = 'Elite K9',   speedMultiplier = 1.15, scentRange = 10.0 },
}

Config.ContrabandAlertTiers = {
    { minWeight = 1,   alert = 'whine' },
    { minWeight = 250, alert = 'aggressive_bark' },
}
```

---

## 6. Acceptance criteria by feature group

Each group is tagged with the phase it ships in. §6.1/§6.6/§6.7 are cited
directly from code and kept in full; §6.2–§6.5 and §6.8 are high-level
anchors only — their real detail lives in §11–§14, which superseded them.

### 6.1 Core Systems & Controls — Phase 1

The K9 player controls themselves at all times; nothing here spawns,
selects, or possesses a ped. "Handler" means a partnered human officer (§1).

- [ ] A player whose character is a K9, whose job is in `Config.Departments`,
      and who holds an active certification (§4) sees K9-specific UI; an
      uncertified K9-model player, or a certified player outside
      `Config.Departments`, does not — enforced server-side on every gated
      action, not just hidden client-side.
- [ ] Player can toggle first/third-person camera at the dog's eye height.
- [ ] Native quadruped run/jump/crouch, no custom animation work required.
- [ ] A "K9 Unit" radial submenu exposes: Bark, Sit, Attach/Detach Leash,
      Enter/Exit Vehicle. Each item's *registration* is gated on its owning
      `Config.Features` flag; the *access check* (`CanShowK9UI()`) is
      re-verified independently at `onSelect` time per item, not by
      live show/hide as access changes.
- [ ] Leash is a **consensual** two-player interaction with a **real
      movement restriction**:
      - **Attach requires consent** (accept/decline prompt on the target of
        the request) from either the K9 or a nearby officer. The non-K9
        side must satisfy `job.name ∈ Config.Departments` too (§9 item 9).
        Server determines which side is the K9 via the live model check
        (§4.5), never a client-asserted role.
      - **While attached, movement is actually restricted** — the leashed
        player is clamped/pulled back on approaching `Config.LeashMaxDistance`
        (soft elastic constraint), not merely notified.
      - **Either party can detach at will, no consent required** — a hard
        requirement: nothing may trap a player leashed with no self-service
        way out.
      - Exceeding the limit despite the pull-back (disconnect, teleport,
        desync) is a distinct safety-valve auto-detach, notifying both.
- [ ] Enter/exit any `Config.K9Vehicles` model via ox_target within
      `Config.VehicleInteractMeters`, self-administered; the K9 is put into
      a real, genuinely free passenger seat (rear seats preferred, never the
      driver's) with that seat's own door opened and closed around it — a
      normal, visible, collidable vehicle occupant like any other passenger,
      never hidden or frozen — and released back out on exit.
- [ ] Basic bark sound plays on radial trigger.
- [ ] Door interaction and full agility mode are **not** required in Phase 1
      — basic jump only.

### 6.2 Combat, Takedowns & Action — Phase 3
High-level anchor only; superseded in full detail by §12.

### 6.3 Scent & Advanced Tracking — Phase 2
High-level anchor only; superseded in full detail by §11.5.

### 6.4 Vision & Tactical Systems — Phase 2 (basic) / Phase 5 (PiP spike)
High-level anchor only; superseded in detail by §11.5 (vision) and §7/§15
`#phase-5-research` (PiP — concluded no PiP work is scheduled).

### 6.5 Qbox Integration, Inventory & Progression — Phase 4
High-level anchor only; superseded in full detail by §13.

### 6.6 Status, Vitality & Vulnerabilities — Phase 4

> **Most of this section describes features that were REMOVED on
> 2026-09-02 at the owner's request.** The unchecked boxes below are NOT
> outstanding work — do not pick them up. Only the HUD, Fatigue and the K9
> medkit still exist; the rest are recorded here because §13.4's detailed
> specs are cited by section number from code comments and must stay
> resolvable. See §13.4.3's own removal notes.

- [x] NUI HUD shows health/stamina for the active K9, gated on
      `Config.Features.HealthStaminaHUD`. (Hunger/thirst were part of the
      removed wellbeing set and no longer appear on it.)
- [x] Fatigue: sustained sprint decays a value that reduces max speed when
      depleted; recovers faster near a configured rest source. **The only
      wellbeing system still shipped.**
- [x] K9 medkit restores health, gated the same way human medkit revives
      already are.
- ~~Mood: drops on damage, restored by pet/feed interactions.~~ **REMOVED.**
- ~~Fear/Stress: rises under sustained nearby gunfire, imposes a hesitation
      state.~~ **REMOVED.**
- ~~Distraction: flashbang immunity; "meat bait"/"ultrasonic whistle"
      items.~~ **REMOVED.**
- ~~Injury/limping: a "leg health" value gating sprint and base speed.~~
      **REMOVED.**
- [ ] Contraband screen effect uses `SetTimecycleModifier` with an existing
      GTA effect — no custom asset.

### 6.7 Audio & Immersion Props — Phase 5
- [ ] Radial bark options each play a distinct sound attached to the K9.
- [ ] Growl/pant volume attenuates by distance to a hiding suspect.
- [ ] Prop attachments (vest, harness, tracking camera) attach a configured
      prop to a configured bone via `AttachEntityToEntity`.
- [ ] Fetch: dog can pick up, carry, and drop a physics prop on command.
- [ ] Deployable kennel: K9 heals at an accelerated rate resting inside its
      radius.

### 6.8 Cross-cutting: config-driven & certification (Hard Requirements 1 & 2)
Covered by §3 and §4 — treat those as authoritative regardless of which
feature-group phase is being reviewed.

---

## 7. Scope reality check — native-only approximation vs. real asset need

| Requested item | Native-only approximation | What would need a custom asset |
|---|---|---|
| K9 camera feed PiP | A full-screen camera *takeover* toggle (`CreateCam`/`RenderScriptCams`) — not a true inset PiP. | A real inset PiP of live 3D world video needs a render-target/texture-capture path FiveM does not expose to plain Lua for a moving in-game camera. Concluded infeasible for a true feed; Phase 5 shipped only a feasibility spike, not a working PiP. |
| Thermal / night vision | `SetSeethrough(true)` for thermal (GTA's built-in heat-vision, highlights peds as heat sources), `SetNightvision(true)` for night — both confirmed, toggle-and-forget natives. | Nothing extra needed. |
| Bite-and-hold "locks onto arm/leg" | Task/animation + a control-disable flag on the target, released on an explicit release or timeout. | A literal physics-attached bite with correct IK needs custom animation work; not attempted. |
| Agility mode (climb fences/windows) | Native jump task + a scripted vault (capsule-sweep obstacle detection, §12.0 item 3) reposition over a detected low obstacle. | A real climbing animation blended to arbitrary fence heights needs a custom clip set. |
| Limping/injury gait | Reduced move-speed via `SetPedMoveRateOverride`, no distinct visual gait. | A visually distinct limping quadruped animation needs a custom clip set (none assumed to exist). |
| Permanent scar overlays | Not attempted. | Custom ped texture/decoration asset + pipeline; out of scope. |
| Contraband screen filter | `SetTimecycleModifier` reusing an existing GTA "drug effect" modifier. | Nothing extra needed. |
| Bark sounds | Achievable but needs **bundled audio asset files** — there is no native "make this canine ped emit a bark voice line on command." A small, easy-to-source asset need, not a scripting blocker. | Higher-fidelity/breed-specific variation needs a larger recorded library. |
| Prop attachments | `AttachEntityToEntity` onto an existing/repurposed prop if a close-enough one exists. | A purpose-built vest/harness/camera-housing model — base GTA doesn't ship one for a quadruped rig. |
| Deployable kennel | An existing GTA prop as a stand-in visual. | A purpose-built kennel model. |
| Gunpowder/blood tracking data sources | Achievable via native game events/polling, but needs authored client→server relay code (§11.6) — not literally free. | Nothing extra beyond that relay code. |
| Door interaction "nudge-open" | Scratch-to-alert (pure sound cue) is fully native-only. Nudge-open needs a real door-lock resource integration (§11.6) — GTA has no generic native lock-state query for arbitrary map doors. | No asset, but a genuine external-resource integration dependency. |

---

## 8. Phased build plan

All five phases have shipped; see `README.md` for current state and
`PROJECT_HISTORY.md` for how each phase built on the last. Kept only as a
one-line map from phase number to detail section:
Phase 1 = vertical slice (§3, §4, §6.1); Phase 2 = tracking & basic vision
(§11); Phase 3 = combat & advanced agility (§12); Phase 4 = inventory,
progression, vitality (§13); Phase 5 = audio/props polish + camera R&D
spike (§14, concluded no PiP work is scheduled — §7).

---

## 9. Open questions / assumptions needing sign-off

Numbering below is fixed — several items are cited by number directly in
code comments (`DEVELOPER_REFERENCE.md §9 item N`, formerly `SPEC.md §9 item
N`). Resolved items are kept, condensed, rather than removed or renumbered,
so those citations keep resolving to something meaningful.

1. ~~DB table vs. metadata for certification.~~ **Resolved** — dedicated
   table, §4.3.
2. **Cross-department certifying (§4.2 item 3).** A certifier from one
   allowed department may certify a target in a *different* allowed
   department. If same-department-only is wanted, that's a one-line change
   in the grant handler — a real behavioral fork, not silently picked
   either way.
3. ~~Does a cert survive a job change and later return?~~ **Resolved** — no,
   §4.4: a fresh grant is required even on rejoining the same department.
3b. ~~Two-player leash/command semantics.~~ **Resolved** — see §6.1's full
    corrected criteria: consent gates getting leashed, never getting free
    of it.
4. **Contraband alert weight thresholds and XP values
   (`Config.XPTiers`, `Config.ContrabandAlertTiers`, and — per §12.6/§13.5 —
   every numeric placeholder added by Phase 3/4) are unreviewed.** Needs an
   economy-balance/config-validator pass against real ox_inventory item
   weights and progression pacing before any owning flag defaults `true` on
   a live server.
5. **PvP-balance review for Phase 3** (cooldowns, interaction with any
   existing restraint/cuff system) — scope widened by §12.6 once PvP
   targeting was decided in scope (§12.0 item 1).
6. ~~Camera feed PiP feasibility.~~ **Resolved as infeasible for a true
   feed** (§7) — do not re-propose without new FiveM engine support.
7. **Bark/vest/harness/kennel audio and prop assets** — small
   asset-sourcing tasks (source, not necessarily commission royalty-free
   sound/prop assets), not zero-asset code-only work.
8. **Live model reliability across an appearance/model swap (§4.5).** If a
   server's separate appearance resource changes a player's base model
   mid-session, the live `GetEntityModel` check could theoretically read a
   stale-relative-to-intent value right around the swap. Not addressed
   speculatively — confirm the target server's actual appearance-system
   behavior before assuming a fix is needed.
9. ~~Must the non-K9 leash partner be in an allowed department too?~~
   **Resolved** — yes, department membership required (not its own K9
   cert) — §6.1.
10. ~~Real event/native availability for tracking data sources.~~
    **Resolved** — blood/gunpowder both need a small authored client→server
    relay (§11.6), not a free native feed; implemented in
    `server/tracking.lua`.
11. **ox_inventory export names/signatures** for search/contraband reading
    and (historically) scent-drop detection — confirmed for search
    (§15 `#contraband-search`) and for scent (item 17 below); K9
    Inventory/K9 Medkit's own export shapes (§13.4.2, §13.4.4) were flagged
    with the same caveat when written — verify against the live
    `overextended/ox_inventory` source before trusting an unconfirmed export
    shape in this document.
12. **Door interaction "nudge-open" needs a real door-lock resource to
    integrate with** — no such resource is in this project's scope, and GTA
    has no generic native for arbitrary map-door lock state. Scoped
    client-only, unlocked-doors-only (§11.6); a richer version needs a real
    per-server integration decision, not a guess.
13. ~~`Config.SearchContrabandItems` is a placeholder list.~~ Same review
    status as item 4 — needs an economy-balance/db-schema pass against the
    real ox_inventory items table.
14. **Whether tracking trail reveal needs a server-side rate-limit/anti-abuse
    surface beyond the per-type cooldown in `Config.Tracking`** — e.g.
    should a K9 be blocked from tracking while leashed-past-limit or during
    an active search-zone cooldown on the same target? Not resolved — a
    judgment call for whoever extends this, not a mandate either way.
15. ~~Did `relayDamageEvent` need an explicit rate limit, at parity with
    `relayWeaponFire`'s?~~ **Resolved** — yes, was a real gap; both trail
    types now have their own `relayCooldownMs` in `Config.Tracking`,
    stamped before any log-append work.
16. ~~Does `relayDoorScratch`'s `doorNetId` need an existence/proximity
    check before broadcasting?~~ **Resolved.** `server/main.lua`'s handler
    resolves the netId, confirms existence, checks live proximity with a
    documented latency margin, verifies entity type (objects only, closing
    a ped/vehicle netId substitution), and enforces both a per-source and a
    door-keyed cooldown — all before broadcasting.
17. **Scent tracking's server-side source resolution — was explicitly
    deferred, then implemented, one verification step still outstanding.**
    `exports.ox_inventory:registerHook('swapItems', ...)` (confirmed real,
    server-side, synchronous on item drop) is the mechanism; implemented in
    `server/tracking.lua`. **One disclosed gap remains:** the hook's exact
    payload shape was confirmed by source-reading, not by an independent
    test against a live `ox_inventory` install — see `README.md`'s
    go-live checklist for the five-minute live check that closes this gap.

---

## 10. One design choice never got a second, independent review

§11.3/§11.4's tracking-event-log design (`server/tracking.lua`) — logging
each blood/gunpowder event in memory only, never persisted to the database
— was never independently reviewed against a real schema-design question
the way §4.3's certification table was. It has shipped and works, but if
this design is ever revisited, confirm the in-memory-only choice against
`LeashPairs`' identical precedent (§10, cited from inside
`server/tracking.lua`) rather than assuming it was already settled by a
review that never actually happened.

---

## 11. Phase 2 Detailed Spec

### 11.1 Sub-phase ordering (dependency graph)

| Sub-phase | Features | Why this order |
|---|---|---|
| 2a — independent, parallelizable | `ThermalVision`, `NightVision`, `DoorInteraction` (scratch-to-alert only) | Pure/near-pure client-side, no shared state. |
| 2b — foundational | `SearchZones` | Must land before `ContrabandAlerts` — alert tiers are computed from a search's weight result. |
| 2c — depends on 2b | `ContrabandAlerts` | Consumes `SearchZones`' weight computation directly. |
| 2d — independent of 2b/2c | `ScentTracking` | Different data source (item-drop location), no hard dependency. |
| 2e — shared infra, land together | `BloodTracking`, `GunpowderSniffing` | Both need the same new relay-and-log infrastructure (`server/tracking.lua`) — avoid two divergent copies. |
| 2f — depends on 2d/2e | `WaterTrackingDecay` | A modifier on an existing rendered trail, not standalone — needs a trail to already exist. |
| Door interaction, nudge-open half | (still `DoorInteraction`) | Split from 2a — depends on confirming a door-lock resource integration (§9 item 12); scratch-to-alert ships regardless. |

### 11.2 Config schema additions

```lua
-- Ranges in meters, ages/windows in seconds. Each trail TYPE is gated by its
-- own Config.Features flag; tables below only take effect for enabled types.
Config.Tracking = {
    Scent     = { maxRange = 40.0, markerSpacing = 3.0, searchCooldownMs = 5000 },
    Blood     = { maxRange = 40.0, maxAgeSeconds = 300, markerSpacing = 3.0, searchCooldownMs = 5000 },
    Gunpowder = { maxRange = 40.0, maxAgeSeconds = 120, markerSpacing = 3.0, searchCooldownMs = 5000 },
    -- Blood/Gunpowder each also carry their own relayCooldownMs (§9 item 15),
    -- and Scent's maxAgeSeconds/relayCooldownMs were added when item 17 shipped.
}

-- Water crossing degrades/breaks a visible trail — not a trackable type of
-- its own, applies to whichever trail (scent/blood/gunpowder) is active.
Config.WaterTrackingDecay = {
    sampleIntervalMeters = 2.0, -- use GetWaterHeightNoWaves, NOT GetWaterHeight -- plain GetWaterHeight's wave-motion jitter causes inconsistent reads between adjacent samples on calm shorelines
    breaksTrail          = true, -- true: hard break, re-search required on far bank. false: fade opacity near/in water instead
}

-- Item names must match real ox_inventory item names on the target server —
-- PLACEHOLDER list (§9 item 13). Item WEIGHT is read live from ox_inventory's
-- own item registry at search time, never duplicated here.
Config.SearchContrabandItems = { 'weed_bud', 'coke_brick', 'meth_bag', 'weapon_pistol' }

Config.SearchZones = {
    vehicleSearchDistance = 2.0, personSearchDistance = 2.0,
    sniffAnimDurationMs   = 4000,
    searchCooldownMs      = 10000, -- per-(K9, target) -- prevents repeat-search spam/harassment
}

-- nudgeRequiresUnlocked is a hard requirement, not a toggle: nudge-open must
-- never function as a lockpick bypass (§11.6).
Config.DoorInteraction = {
    interactDistance = 1.5, nudgeRequiresUnlocked = true, scratchCooldownMs = 3000,
}

Config.Vision = {
    Thermal = { toggleKey = 'K' }, -- drives SetSeethrough (§11.6)
    Night   = { toggleKey = 'J' }, -- drives SetNightvision (§11.6)
}
```

### 11.3 File/module plan

Continuing Phase 1's boundary conventions (thin radial wiring only in
`client/radial.lua`; "own body" self-actions in `client/movement.lua`;
target-entity interactions in their own per-type file; small
server-authority-only actions in `server/main.lua`).

| File | New/extends | Owns |
|---|---|---|
| `client/tracking.lua` | New | Scent/blood/gunpowder self-search radial items, trail marker rendering, water-crossing degrade. Calls `qbx_k9unit:server:findTrackableSource` (§11.4). Separate from `movement.lua` to keep that file's own scope (camera/sit/leash) from growing into an everything-file. |
| `client/search.lua` | New | Search-vehicle/search-person ox_target options; plays the sniff animation, awaits `qbx_k9unit:server:searchTarget` (§11.4). Kept separate from `client/tracking.lua`: tracking reveals a cosmetic trail (no real capability granted), search reveals real server-verified inventory contents (a real capability) — split by trust model, not just by feature name. |
| `client/vision.lua` | New | Thermal/night vision keybinds (`RegisterKeyMapping`) — a cheap, local, free `IsOwnModelK9()` check, not gated behind `CanShowK9UI()` (a perception QoL toggle, not a granted capability, same category as the camera toggle). |
| `client/movement.lua` | Extends | Door interaction (nudge + scratch) — small enough to be a self-action alongside Sit rather than its own file. Nudge-open ships client-only, no server event (§11.6) — mirrors vehicle entry/exit's §4.1 exception. |
| `server/tracking.lua` | New | Event-relay log backing blood/gunpowder: logs a damage-event/weapon-fire coordinate read server-side from the reporter's own live position (never client-supplied), a periodic prune pass, and `qbx_k9unit:server:findTrackableSource`. Ephemeral/in-memory only, mirroring `LeashPairs`' precedent (§10). |
| `server/search.lua` | New | `qbx_k9unit:server:searchTarget` — re-validates flag/access/live proximity, reads real inventory via an ox_inventory server export, cross-references `Config.SearchContrabandItems`, computes weight from live item data, looks up the alert tier, applies cooldown, broadcasts the alert if `ContrabandAlerts` is on. |
| `server/main.lua` | Extends | Door scratch-to-alert only (`relayDoorScratch`) — structurally identical to the existing `relayBark` handler. Nudge-open gets no server entry. |
| `client/radial.lua` | Extends | Three self-action items (Track Scent/Blood/Gunpowder) under the K9 Unit submenu, each gated by its own flag. |
| `config.lua` / `fxmanifest.lua` | Extend | Add §11.2's tables; add the new client/server files to their script lists. |

### 11.4 Event/callback contract (Phase 2)

**Callbacks (ox_lib `lib.callback`):**
1. `qbx_k9unit:server:findTrackableSource(trackType: 'scent'|'blood'|'gunpowder')`
   → `{ found, coords?, breaksAtWater }` [`server/tracking.lua`]. Re-validates
   flag/access; resolves the caller's own live position, never a
   client-supplied coordinate; enforces `Config.Tracking.<Type>.searchCooldownMs`.
2. `qbx_k9unit:server:searchTarget(targetType: 'vehicle'|'person', targetNetId)`
   → `{ ok, reason?, contrabandFound?, totalWeight?, alertTier? }`
   [`server/search.lua`]. **The security-critical one.** Re-validates
   flag/access, resolves `targetNetId` server-side and confirms it exists
   within range of the caller's own live position, cross-checks the
   resolved entity's real type against the client-claimed `targetType`
   (rejects a mismatch with `invalid_target` before any inventory read).
   Reads real inventory contents and real item weights — never a
   client-supplied claim. `totalWeight`/`contrabandFound` return **only to
   the caller**, never broadcast (only `alertTier` is ever sent to anyone
   else). Enforces **two** independent cooldowns — per-`(source,
   targetNetId)` and a flat per-`source` floor — both timestamped **before**
   the awaited ox_inventory call starts, closing a TOCTOU window a
   post-completion timestamp would leave open. Must recurse into container
   items to a bounded depth (else "put the drugs in a bag" defeats the
   feature entirely); must use an in-flight mutex per source (closes a
   same-source concurrent-call race); must treat a failed/errored inventory
   query as a distinct `search_failed` outcome, never collapsed into
   "clean"; `Config.ContrabandAlertTiers` needs an explicit baseline
   `{ minWeight = 0, alert = 'clean' }` entry so a genuinely clean search
   has defined feedback. Full export-signature detail in §15 `#contraband-search`.

**Server events (client→server):**
3. `qbx_k9unit:server:relayDamageEvent()` [`server/tracking.lua`] — from a
   client's own `CEventNetworkEntityDamage` handler when the local player is
   the victim. No meaningful payload — the server logs the reporter's own
   live coordinates.
4. `qbx_k9unit:server:relayWeaponFire()` [`server/tracking.lua`] — from a
   debounced local `IsPedShooting` false→true transition. Same
   own-live-coordinate rule; needs its own tight per-player rate limit,
   independent of the *search*-side cooldown (this is a *logging* cooldown).
5. `qbx_k9unit:server:relayDoorScratch(doorNetId)` [`server/main.lua`] —
   structurally identical to `relayBark`; see §9 item 16 for the
   validation this handler performs before ever broadcasting.

**Client events (server→client):**
6. `qbx_k9unit:client:playDoorScratch(netId)` [`client/movement.lua`] —
   mirrors `playBark` exactly.
7. No dedicated event for tracking/search results — both are
   request/response shaped, so `lib.callback` is the right fit.

**Nudge-open has no event or callback at all** — fully client-local (§11.3,
§11.6), same exception class as vehicle entry/exit.

### 11.5 Acceptance criteria by feature

**Scent tracking** (`ScentTracking`)
- [ ] A qualifying player can trigger "Track Scent"; a non-qualifying
      caller hitting the callback directly gets `found = false` regardless
      of client UI state.
- [ ] Resolves the nearest configured source within `maxRange` of the K9's
      live server-side position.
- [ ] Renders trail markers spaced `markerSpacing` apart on success.
- [ ] Re-triggering before `searchCooldownMs` elapses is rejected
      server-side.
- [ ] With the flag `false`, the radial item is absent and the callback is
      an unconditional server-side no-op.

**Blood trail tracking** (`BloodTracking`)
- [ ] Identical to scent above, but sourced from the most recent logged
      damage-event location within `maxAgeSeconds`, victim's own live
      server-side position at report time, never client-claimed.

**Water tracking / scent degradation** (`WaterTrackingDecay`)
- [ ] Any active trail is sampled every `sampleIntervalMeters` for water.
- [ ] `breaksTrail = true` (default): rendering stops at the water's edge, a
      fresh search is required on the far bank. `false`: reduced-opacity
      markers instead, trail continues.
- [ ] With the flag `false`, trails render through water with no
      degradation.

**Gunpowder residue sniffing** (`GunpowderSniffing`)
- [ ] Identical to scent, sourced from the most recent logged weapon-fire
      location within `Config.Tracking.Gunpowder.maxAgeSeconds`, logged from
      the shooting player's own live position.

**Search vehicle/person + contraband alert tiers** (`SearchZones`, `ContrabandAlerts`)
- [ ] ox_target "Search Vehicle"/"Search Person" appear within configured
      range while passing `CanShowK9UI()`; the sniff animation is purely
      cosmetic pacing — the server computes the real result.
- [ ] The server determines contraband found/weight from the target's real
      live inventory — a spoofed client claim changes nothing.
- [ ] Crossing a `Config.ContrabandAlertTiers` tier plays that tier's alert
      as a broadcast sound/animation audible to nearby players, not just
      the requester.
- [ ] With `ContrabandAlerts = false`, a successful search still reports
      `contrabandFound`/`totalWeight` to the requester, but no broadcast
      alert fires — this flag gates the *alert*, not the *search*.
- [ ] Re-searching the same target before `searchCooldownMs` (per
      `(K9, target)` pair) is rejected, not silently re-rolled.
- [ ] With `SearchZones = false`, neither option appears and the callback
      rejects `ok = false` for any caller.

**Door interaction** (`DoorInteraction`)
- [ ] "Nudge Open" appears only on an already-unlocked door
      (`nudgeRequiresUnlocked = true`) — a hard behavioral guarantee, not
      just a default; fully client-local.
- [ ] "Scratch to Alert" works regardless of lock state, triggers
      `relayDoorScratch`, rejected server-side within `scratchCooldownMs`.
- [ ] With the flag `false`, neither option appears and `relayDoorScratch`
      is a server-side no-op.

**Thermal vision** (`ThermalVision`) / **Night vision** (`NightVision`)
- [ ] Gates on `IsOwnModelK9()` only, **not** `CanShowK9UI()` — the K9's own
      innate perception, same reasoning as the camera toggle, applied
      identically to both.
- [ ] Toggling calls `SetSeethrough`/`SetNightvision` respectively — no
      custom shader/asset.
- [ ] Auto-disables on resource stop (mirrors `client/vehicle.lua`'s
      restart-safety precedent) and on every other exit path (death,
      disconnect, cert auto-revoke mid-session) — nothing else turns these
      global toggles off.
- [ ] Thermal and night vision are mutually exclusive at any given moment
      (a judgment call, not dictated by the original wording).

### 11.6 Reality-check refinements

- **Thermal/night vision — confirmed achievable.** `SetSeethrough(true)`
  (GTA's built-in heat-vision, used by the base game's Predator event and
  Cayo Perico thermal goggles) is the better fit over a generic timecycle
  modifier — it actually highlights peds as heat sources. `SetNightvision(true)`
  is the standard NV effect. Both toggle-and-forget, zero new assets.
- **Gunpowder sniffing — no single free native feed exists.** Each client
  polls its own `IsPedShooting` and relays a debounced event on a
  false→true transition (§11.4 item 4) — small, authored, still 100%
  native-based.
- **Blood trail — same relay caveat.** `CEventNetworkEntityDamage` is real
  and documented, but fires locally per-client — the victim's own client
  relays it (§11.4 item 3).
- **Scent tracking (item-drop location) — resolved.**
  `exports.ox_inventory:registerHook('swapItems', ...)` fires server-side,
  synchronously, on every item drop, carrying `payload.source` — resolvable
  to a live position the same way damage/weapon-fire relays already are.
  Implemented in `server/tracking.lua`; see §9 item 17 for the one
  remaining verification gap.
- **Search vehicle/person contraband reading** — unambiguously possible;
  exact export names confirmed in §15 `#contraband-search`.
- **Door interaction "nudge-open" — a genuine integration dependency.** GTA
  has no generic native to query/set lock state on arbitrary map/interior
  doors; that state lives entirely inside a separate, server-specific
  door-lock resource with no vanilla native surface to query from outside
  it. This is why nudge-open is scoped strictly to "only when already
  unlocked," client-only, with no lock/unlock logic of its own — safe to
  ship without an integration decision, at the cost of being a thin,
  cosmetic-only feature. **GTA's native `CDoor` system must never be
  consulted as a safety check here even as a belt-and-suspenders measure**
  — most real door-lock resources manage state entirely outside `CDoor`, so
  an unregistered door reads as "nothing to say," which risks a
  false-negative "unlocked" read — a concrete way to violate the hard
  `nudgeRequiresUnlocked` guarantee. Implementation must stay purely
  cosmetic (a push animation on a door the K9 can already physically pass).
- **"Scratch to alert" — confirmed, no caveats.** Identical shape to
  `relayBark`.

### 11.7 Cross-reference

New open questions raised during Phase 2 scoping were appended to §9
(items 10–17) rather than duplicated here, so §9 remains the single running
list.

---

## 12.0 — Cross-cutting design forks: resolved and open

Item numbers below are fixed and cited directly by number throughout
`client/combat.lua`, `server/combat.lua`, the handler-down-defense file
pair (since removed), `server/partnership.lua`, `client/partnership.lua`,
`client/radial.lua`, `client/agility.lua`, `client/movement.lua`,
`server/fetch.lua`, the recall server file (since removed), and `config.lua`.

#### 1. PvP vs. PvE target scope — DECIDED: player-vs-player K9 combat is IN SCOPE

All four target-taking mechanics (`BiteAndHold`, `NonLethalTakedown`,
`PropDragging`, `HandlerDownDefense`'s target selection) can target **either
an NPC or a live player**, subject to item 5's eligibility gate for player
targets. This is a direct, explicit, informed product decision — not open
to re-litigation on "no ecosystem precedent for this" or "a modified client
can ignore the instruction" grounds; those tradeoffs were weighed and
accepted knowingly. What item 8 below settles is the concrete, honest
mechanics of that decision, not whether to make it. Player-vs-player K9
combat is **not** a §2 non-goal.

#### 2. HandlerDownDefense's "aggressive state" — DECIDED: UI/auto-targeting convenience, not AI takeover

> **REMOVED 2026-09-02, at the owner's request.** The design below was
> built and shipped, then taken out. It is kept as a record of why it was
> shaped this way -- it does NOT describe anything in the resource today,
> and nothing here should be implemented from without deciding to bring
> the feature back first.


The K9's bite-and-hold/takedown actions become available through a single
simplified, pre-targeted input instead of the radial menu — the K9 player
still steers their own ped and still confirms manually. A fully autonomous,
zero-input AI attack is rejected outright: it would require this resource
to take control of the K9 player's own ped, directly conflicting with §2's
non-goal and §1's "the K9 player controls themselves... at all times."
"Nearest hostile" can resolve to a live player, not only an NPC.

- [ ] A trigger never, by itself, moves the K9's ped, fires a weapon, plays
      a combat animation, or applies any task/control to the K9 player.
- [ ] The K9 player must manually confirm before any action executes.
- [ ] The K9 player retains full manual control of movement/camera at all
      times.
- [ ] Once confirmed, the action goes through the exact same
      `requestBiteHold`/`requestTakedown` server validation path as a
      manually-triggered action, including item 5's eligibility gate.
- [ ] A literal AI-takeover version remains a separately-scoped feature, not
      a configuration of `HandlerDownDefense`.

#### 3. AgilityAdvanced obstacle detection — DECIDED: capsule-sweep raycast (`detectionMethod = 'raycast'`)

`Config.Combat.AgilityAdvanced.detectionMethod = 'raycast'` is the Phase 3
default: a multi-height capsule sweep (`StartShapeTestCapsule`/
`GetShapeTestResult`, confirmed real natives). `'taggedProp'` remains
available as an optional per-server override. Independent of the PvP scope
question — this feature never targets anything.

#### 4. Non-consensual state application posture — RESOLVED

**Resolution: combat is a different category from leash and does not need
leash's consent model — a category difference, not a conflict.** Leash's
consent requirement exists because it's a **cooperative** mechanic;
bite-and-hold/takedown/dragging are **apprehension/enforcement actions** by
design — exactly like every comparable QBCore/Qbox mechanic (cuffing,
tasing, hogtying), none of which gate on the target's consent. Requiring
consent from a combat target would make the feature meaningless.

Because combat gives up consent, the compensating control is item 5 below —
read the two together. The leash's *other* guarantee ("no consent needed to
get free") has a real analog here even without the initiating-consent
carryover: the hard duration caps (`Config.Combat.BiteAndHold.maxDurationMs`,
`NonLethalTakedown`'s ragdoll/damage-suppression window,
`Config.Combat.PropDragging.maxDragDistance`) are this mechanic's version of
"no unbounded trap" — load-bearing for this non-consensual design being
acceptable at all, not just a balance knob.

#### 5. Target-eligibility restriction — RESOLVED: config-driven wanted/suspect gate

**Resolution: yes, restricted — `Config.Combat.RequireWantedStatus` (default
`true`).** A K9 may only initiate `BiteAndHold`/`NonLethalTakedown`/
`PropDragging` against a **player** target currently flagged wanted/suspect
by whatever dispatch system the server runs; an NPC target is unaffected
either way. **There is no native networked "wanted level" concept**, and
unlike item 6's laststand check, there is no single ecosystem-dominant
convention for exposing one — flagged as **lower confidence** than item 6's
default.

Integration point (same shape as item 6): (1) a best-effort default check
against a plausible metadata convention (`metadata.wanted`/`.iswanted`),
(2) `Config.Combat.WantedStatusCheckOverride(playerId) -> boolean` — expected
to be the *normal*, not exceptional, path for a real server, (3)
`RequireWantedStatus = false` remains available for a server that wants
unrestricted PvP K9 combat, but the shipped default is `true`.
Enforcement is server-side only, inside `requestBiteHold`/`requestTakedown`/
`requestDrag`'s validation. **Residual, disclosed gap:** this does not stop
an officer who manipulates their own server's dispatch/wanted system to
flag a colleague deliberately — that's an abuse vector of whatever *other*
resource controls wanted state, not something this resource re-verifies.

#### 6. PropDragging's "is this player downed" integration point — RESTORED, real requirement for the player-target path

NPC-target dragging is fully native (`IsPedDeadOrDying(ped, true)` +
`IsPedRagdoll`) and unaffected by this item. For a **player** target, those
same natives don't answer the actual question needed (this server's own
scripted downed/laststand state) — most QBCore/Qbox laststand
implementations keep the ped's health above zero with no native death state
(a false negative), while an unrelated ragdoll (knocked over by a vehicle)
would satisfy `IsPedRagdoll` without being "downed" in any real sense (a
false positive). This is a category mismatch between what the natives
observe and what the feature needs, not a confidence gap more research
would close.

**Required contract:** (1) a default check against `metadata.isdead`/
`.inlaststand` if present, (2)
`Config.Combat.PropDragging.IsPlayerDownedOverride(playerId) -> boolean` as
a real, wired-in (not commented-out) escape hatch. NPC-target dragging
remains fully unblocked regardless of this item's status; only the
player-target path is gated on step 1 existing in real, tested code.

#### 7. Handler-partnership link — RESOLVED: new persistent registry (Option B), NOT a reuse of `LeashPairs` (Option A, rejected outright)

**Why Option A is rejected, not merely deprioritized:** `LeashPairs` is
explicitly ephemeral, in-memory, session-scoped state for a
movement-restriction mechanic — reusing it as "who is my ongoing combat
partner" would silently repurpose transient state as a durable
relationship it was never designed to be, and it is torn down on distance
safety-valve, either party's own detach, cert revoke, and job change.
Concretely, `HandlerDownDefense`'s own motivating scenario is a foot chase
— a K9 pursuing a fleeing suspect while its handler, now alone and
unleashed (leash is actively counterproductive during a chase), takes
damage. Option A would leave `HandlerDownDefense` **non-functional for the
exact scenario it exists to cover**, working only in the rare case the pair
happens to still be leashed. That is a materially worse gap than this
document's other accepted, disclosed ones (item 5's wanted-status
fragmentation still lets the gate do its job in the common case) — it fails
the primary use case, not an edge case.

**The design, as shipped in `server/partnership.lua`:**
1. **Establishment** mirrors leash's own consent handshake — a "Partner Up"
   action, initiated by either party, requiring the other's explicit
   accept/decline (reusing the `PendingLeashRequests`-style TTL'd
   single-slot pattern). Eligibility re-verified server-side: both parties
   pass `HasK9Access`-equivalent checks for the same department, live
   proximity, and the K9-role party is on a configured model.
2. **Persistence is DB-backed** (`k9_partnerships` table), not ephemeral
   like `LeashPairs` — the entire point is to survive a resource restart
   mid-shift, which no in-memory table could recover from. Modeled on
   `k9_certifications`' conventions (append-mostly audit rows, an `active`
   flag, generated-column unique constraints — here needing **two**, since
   both "one active partnership per K9" and "one active partnership per
   handler" must hold), an in-memory cache refreshed on `PlayerLoaded` plus
   an `onResourceStart` backfill loop mirroring `certifications.lua`'s.
   A lighter "ephemeral but not leash-tied" middle option was considered
   and rejected — it would leave the identical restart-survivability gap,
   just relabeled.
3. **Termination:** either party can break it at will, no consent needed,
   plus automatic teardown on the same triggers that already force-detach a
   leash (added alongside every existing `ForceDetachLeashForSource`/
   `ForceDetachOfficerLeashForSource` call site in `server/certifications/`).
4. **Authorization:** mutual consent only, no certifier-grade hierarchy —
   partnership is a peer relationship between two already-independently-
   eligible parties, unlike certification granting.
5. New flag `Config.Features.HandlerPartnership`, new file
   `server/partnership.lua` — its own flag rather than piggybacking on
   `BiteAndHold`'s or `HandlerDownDefense`'s, so a server can disable
   partner-designation independently.

**Consumers:** `BiteAndHold`'s Recall actor checks
`Partnerships[recallerCitizenid].active and .partner == heldK9Citizenid`
server-side, in addition to (never instead of) an active hold-state entry.
`HandlerDownDefense`'s trigger looks up the handler's active partnership on
a health-threshold crossing; if none exists (never partnered, or broken),
it is a **silent no-op** — a real, disclosed prerequisite: a "Partner Up"
must have happened at least once for a given pair before `HandlerDownDefense`
can ever fire for them. State this explicitly in any player-facing doc.

#### 8. The client-relay architecture problem for a live-player target — RESOLVED

**Two categories of effect this resource applies to another entity:**
- **Category A** — effects an "owning" client can impose on another entity
  from outside it (`AttachEntityToEntity`, already used safely by
  `client/vehicle.lua`) — replicate across the network without the target's
  own client running any code.
- **Category B** — effects only real when the *target's own client*
  executes a local-only native on itself (`DisableControlAction`,
  `SetPedToRagdollWithFall`, `SetPedMoveRateOverride`,
  `SetEntityCanBeDamaged` bracketing). Nothing in FiveM lets the server or
  another client force a *different* client's ped into these states the
  way it can for an NPC.

Bite-and-hold and non-lethal takedown's restrictive effects are **entirely
Category B**. Prop dragging is **mixed**: the initial attach is Category A
(genuinely moves a target's rendered position regardless of cooperation —
the same technique underlying ecosystem cuffing/carry scripts), but the
speed limitation is Category B. **New finding: the attach must be
re-asserted every tick from the K9's own client, never one-shot** —
`AttachEntityToEntity` requires no ownership/authority over the target to
take effect (citizenfx/fivem issue #3726), and by the same evidence
`DetachEntity` isn't gated any differently — a hostile target's own client
can call `DetachEntity` on itself at any moment. A one-shot attach would
silently degrade dragging's Category A half into something as trivially
defeated as a Category B effect.

**Detection (real, buildable) vs. enforcement (not viable) against a
non-cooperating target:**
- **Purely cosmetic, no server-enforced restriction, is rejected as the
  answer** — this resource does not describe a Category B effect as
  "restraining" a player without a best-effort caveat.
- **Detection is real and implementable.** The server already has
  authoritative position for every networked entity, including a player's
  own ped. Add a `compliance` sub-record to the same per-effect state
  `server/combat.lua` already owns (never a second, independently-lifecycled
  table). One shared sampling thread (not one per effect) evaluates every
  active hold/ragdoll/drag entry every
  `Config.Combat.NonComplianceDetection.positionSampleWindowMs`. Per-effect
  threshold logic differs deliberately: `BiteAndHold` flags sustained
  speed over an idle-jitter ceiling across **two or more consecutive
  samples**, not one (`speedTolerance = 1.0` in the shipped placeholder is
  too loose for this specific check — recommend ~0.5 m/s when
  config-validator reviews §12.2); `NonLethalTakedown` uses **net
  displacement across the whole window**, not continuous speed, since a
  genuine ragdoll produces noisy non-directional velocity; `PropDragging`
  compares the target's position against the **K9's own live position**
  (a bounded slack), catching self-detach, a bypassed override, or the K9's
  own client failing to re-assert the attach, all as one signal. On
  violation: `'log'`/`'notify_staff'` only, **never** `'auto_kick'`/
  `'auto_ban'` by default — a server-side heuristic sampled every
  250–500ms over OneSync will produce false positives from ordinary
  lag/desync, and this resource has no standing to auto-punish on that
  basis; `OnViolationOverride(playerId, effectType, evidence)` lets a
  server build its own automated response on top of real evidence.
- **Enforcement (forced network-ownership migration) — evaluated and
  rejected, not "needs a prototype."** The cooperative request path
  (`NetworkRequestControlOfEntity`) is a best-effort ask of the current
  owner, not server-forceable — and a hostile client can opt out of
  incoming requests entirely via a documented native, with zero server-side
  visibility into whether it did (citizenfx/fivem issue #3338). The one
  server-forceable candidate, `NetworkSetEntityOwner`, remains an unmerged
  PR (#2312) that FiveM's own maintainers call "a somewhat undesirable
  command" carrying "risk of side effects," already misbehaving for the
  *easier* case (population entities) before the discussion even reaches a
  live player's own ped. Structurally, a live player's ped's ownership
  isn't a flag that migrates — it's what "being that player's client"
  means; even a successful request leaves a hostile client free to
  re-request immediately. And deliberately fighting another client for
  entity control every frame is, to any anti-cheat heuristic, indistinguishable
  in shape from a teleport/desync exploit — a new anti-cheat exposure this
  project's own false-positive standard would otherwise reject creating.

**Ship decision: ship it, with binding guardrails, not as an unconditional
restraint.** The requester already accepted this specific tradeoff, with
eyes open, when overriding NPC-only scope (item 1) — this is not the same
shape of gap as a genuinely-fixable client-trust hole (like an unvalidated
netId); it's a residual property of what a live player's own ped is in
FiveM's networking model, which no implementation discipline closes.
**Binding guardrails, required before any player-target code path ships:**
1. The detection layer above exists in real, tested code in
   `server/combat.lua`, not merely the config placeholder table.
2. `PropDragging`'s attach is re-asserted every tick, never one-shot.
3. **No server-authoritative consequence of any kind (arrest completion,
   evidence, currency, items, permissions) may ever be conditioned on a
   Category B effect having been applied successfully to a player target**
   — only on things this server independently verifies. This is the
   concrete backstop keeping "detection-plus-log" an acceptable posture
   rather than a fig leaf; do not add this coupling later without
   re-opening this item.
4. Every player-facing string describing these three mechanics' effect on a
   player is worded as best-effort ("attempts to restrain"), never as an
   unconditional guarantee.
5. `RequireWantedStatus` stays `true` by default and
   `NonComplianceDetection.action` stays `'log'`/`'notify_staff'` by
   default in this resource's own shipped config.

**Trust-boundary note:** the `qbx_k9unit:client:apply*` handlers this item
introduces are the first surface in this resource that must run
unconditionally on **any** connected player's client, including one who has
never touched a K9 feature — the server-side validation in
`server/combat.lua` is the *only* thing standing between "any connected
player" and this code firing against them. Review it with the same rigor as
the certification grant path, not less. See also §15 `#trust-boundary` for
the client-event origin-guard this depends on.

---

## 12.1 Sub-phase ordering (dependency graph)

| Sub-phase | Feature(s) | Why this order |
|---|---|---|
| 3a — independent | `AgilityAdvanced` | Pure own-body movement, unaffected by PvP scope. |
| 3b — foundational, depends on `server/partnership.lua` (item 7) | `BiteAndHold` | Establishes the shared hold/incapacitate state + Recall actor every later feature reuses; first feature needing the Category A/B relay split and eligibility gate (items 5/8). |
| 3c — depends on 3b's target infra | `NonLethalTakedown` | Reuses the target-effect shape; additionally needs the server-computed speed gate. |
| 3d — depends on 3b/3c | `PropDragging` | NPC-target path fully unblocked; player-target path blocked on item 6's contract and shares item 8's speed-limit-relay exposure. |
| 3e — depends on Phase 2's tracking infra AND `server/partnership.lua` (item 7) | `HandlerDownDefense` | Pure consumer of 3b/3c's own target-action paths. |

## 12.2 Config schema additions

**Every numeric value below is an unreviewed placeholder** — flagged for a
PvP-balance/config-validator pass (§9 item 5) before any of this is relied
on as tuned. Detection-layer knobs specifically implement item 8's design,
not a separately-invented one.

```lua
Config.Combat = {
    -- Applies to all three player-targeting mechanics. Item 5.
    RequireWantedStatus       = true,
    WantedStatusCheckOverride = nil,  -- function(playerId) -> boolean

    -- Item 8 — DETECTION ONLY, NOT ENFORCEMENT.
    NonComplianceDetection = {
        enabled = true, positionSampleWindowMs = 500,
        speedTolerance = 1.0,  -- UNTUNED -- see item 8: too loose for BiteAndHold specifically, ~0.5 recommended there
        action = 'log',        -- 'log' | 'notify_staff' -- never 'auto_kick'/'auto_ban'
    },

    BiteAndHold = { range = 2.5, maxDurationMs = 15000, cooldownMs = 20000 }, -- maxDurationMs is item 4's "no unbounded trap" guarantee
    NonLethalTakedown = {
        range = 3.0, minTargetSpeed = 4.0, -- server-computed, never client-claimed
        cooldownMs = 25000, targetCooldownMs = 30000, healthFloor = 100, -- backstop only; primary mechanism is the SetEntityCanBeDamaged bracket
    },
    HandlerDownDefense = {
        handlerHealthThreshold = 100, triggerRadius = 15.0, hostileLookbackSeconds = 10, -- "hostile" may resolve to a player, subject to the same RequireWantedStatus gate as a manual trigger
    },
    PropDragging = {
        range = 2.0,
        dragSpeedMultiplier = 0.6, -- via SET_PED_MOVE_RATE_OVERRIDE, must be re-asserted every tick (item 8)
        maxDragDistance = 30.0,    -- unrelated to Config.LeashMaxDistance
        IsPlayerDownedOverride = nil, -- REQUIRED wiring before the player-target path ships, item 6
    },
    AgilityAdvanced = {
        detectionMethod = 'raycast', -- item 3
        maxVaultHeight = 1.2, vaultCooldownMs = 2000,
    },
}
```

## 12.3 File/module plan

| File | New/extends | Owns |
|---|---|---|
| `client/combat.lua` | New | BiteAndHold/NonLethalTakedown self-initiated triggers, PropDragging's client trigger. Registers, **unconditionally for every client** (see item 8's trust-boundary note), the target-side handlers `applyBiteHold`/`forceRagdoll`/`applyDragSpeedLimit`. |
| `server/combat.lua` | New | Server authority for BiteAndHold/NonLethalTakedown: access/range/target-scope validation, `IsPedAPlayer` resolution (never client-claimed), item 5's gate, the server-side speed gate, health-floor + damage-bracket application (direct for NPCs, relayed for players per item 8), the ephemeral hold/drag state, and item 8's `NonComplianceDetection` sampling. |
| the handler-down-defense client file (since removed) | New | HandlerDownDefense's client-side presentation **only** — per item 2, never applies state to or takes control of the K9's own ped; streamlines target selection into `client/combat.lua`'s existing action paths. |
| the handler-down-defense server file (since removed) | New | Hooks Phase 2's damage-event log; on a partnered handler's health crossing threshold, looks up `server/partnership.lua`'s registry (item 7) and notifies the partner K9 if online, silent no-op otherwise. |
| `server/partnership.lua` | New (item 7) | The `k9_partnerships` registry: DB table, in-memory cache, "Partner Up" handshake, teardown wired alongside every `ForceDetachLeashForSource`/`ForceDetachOfficerLeashForSource` call site, `PlayerLoaded`/`onResourceStart` backfill. Own flag, `Config.Features.HandlerPartnership`. |
| `client/movement.lua` | Extends | `AgilityAdvanced`'s vault trigger and capsule-sweep detection (item 3). |
| `config.lua` / `fxmanifest.lua` | Extend | Add §12.2's table; add the new files to their script lists. |

## 12.4 — Per-feature detailed spec

### 12.5.1 Bite-and-Hold (`Config.Features.BiteAndHold`)

Trigger: radial "Bite & Hold" within `range` of an eligible target — NPC or
player (item 1), passing `CanShowK9UI()`. Effect: latch/bite animation; the
target enters a "held" state up to `maxDurationMs` (item 4's "no unbounded
trap" cap), ending early on the K9's own "Release" or the registered
partner's "Recall" (item 7). Against an NPC, suppression applies directly
(`SetBlockingOfNonTemporaryEvents`/`SetPedFleeAttributes`). Against a
player, the restrictive half is relayed via `applyBiteHold` to the target's
own client (item 8 — no guarantee against a non-cooperating client), and
item 5's `RequireWantedStatus` gate must pass. One hold at a time per K9; a
target already held is rejected `already_held`.

Reality check: task/animation plus control-disable/AI-suppression, not a
literal rigid-body bite (§7). Anim candidate:
`creatures@rottweiler@melee@streamed_core@`/`takedown_from_back` — MEDIUM
confidence, needs an in-engine preview.

Event contract: `qbx_k9unit:server:requestBiteHold(targetNetId)`
[client→server] re-validates flag/access/proximity/not-already-held,
resolves player-vs-NPC via `IsPedAPlayer`, applies item 5's gate for a
player target; on success opens the hold-state entry and either suppresses
directly (NPC) or sends `qbx_k9unit:client:applyBiteHold(holderNetId, expiresAt)`
to the target only (player). `qbx_k9unit:server:releaseBiteHold()`
[client→server]. Server-side timeout past `maxDurationMs` auto-clears.
Never client-authoritative: active/expiry/suppressed/eligible state are all
server-held.

Open: item 8's residual gap for the player-target path; exact anim quality;
no damage over the hold duration (recommended, not enforced elsewhere).

### 12.5.2 Non-lethal takedown (`Config.Features.NonLethalTakedown`)

Trigger: same radial pattern, requiring the target's **server-computed**
speed over recent position samples to exceed `minTargetSpeed` — never a
client-reported "I am fleeing" claim; works identically for NPC or player
targets since the server has authoritative position for both. Effect:
`SET_PED_TO_RAGDOLL_WITH_FALL` + a damage bracket
(`SetEntityCanBeDamaged(false)`/`(true)`) — the primary non-lethal
mechanism, not the `healthFloor` backstop. Against a player, both are
Category B, relayed via `forceRagdoll` (item 8's caveat applies); item 5's
gate must pass. `SET_ENTITY_INVINCIBLE` is deliberately not used — it would
fight the ragdoll's own visual convincingness.

Event contract: `qbx_k9unit:server:requestTakedown(targetNetId)`
[client→server] — same validation shape as bite-and-hold plus the speed
gate (`not_fleeing` on failure). `qbx_k9unit:client:forceRagdoll(expiresAt)`
[server→client, target only]. Per-K9 and per-target cooldowns apply to
both target types.

Open: item 8's residual gap; the rolling speed-history state per targetable
entity; whether a takedown should leave a state some other cuff/restraint
resource can consume — not decided here.

### 12.5.3 Handler-down defense (`Config.Features.HandlerDownDefense`)

> **REMOVED 2026-09-02, at the owner's request.** The design below was
> built and shipped, then taken out. It is kept as a record of why it was
> shaped this way -- it does NOT describe anything in the resource today,
> and nothing here should be implemented from without deciding to bring
> the feature back first.


Trigger: a certified handler's health drops below `handlerHealthThreshold`,
detected via Phase 2's damage-event log. "Nearest hostile" = whoever the
log attributes as the source of the handler's most recent damage within
`hostileLookbackSeconds` — may now resolve to a player (item 1), which does
**not** exempt it from item 5's `RequireWantedStatus` gate at the
downstream validation step; an ineligible auto-selected target simply fails
the same way a manual attempt would, and the K9 player falls back to the
normal radial flow. **Partnership-gated (item 7):** its server file
looks up the handler's active partnership; if none exists (never partnered,
or broken), this is a **silent no-op** — state this prerequisite explicitly
in any player-facing doc, since mere certification is no longer sufficient
on its own.

Reality check: needs no new native capability; inherits whatever compliance
posture BiteAndHold/NonLethalTakedown land on for their player-target
paths.

### 12.5.4 Prop dragging (`Config.Features.PropDragging`)

Trigger: radial "Drag" on a nearby target within `range` that is currently
"downed." NPC: native `IsPedDeadOrDying(ped, true)` + `IsPedRagdoll` — fully
unaffected by anything below. Player: item 6's two-part contract
(`metadata.isdead`/`.inlaststand` default + `IsPlayerDownedOverride`), not
the native checks. Effect: `AttachEntityToEntity` near a collar/scruff point
(Category A, per item 8 — re-asserted every tick, not one-shot) at
`dragSpeedMultiplier` of normal speed via `SET_PED_MOVE_RATE_OVERRIDE`
(also re-asserted every tick); for a player target, the speed limitation
specifically is relayed via `applyDragSpeedLimit` (Category B, item 8's
caveat applies to this half only — the attach itself is comparatively
robust). Movement continues up to `maxDragDistance` before auto-release
(distinct from `Config.LeashMaxDistance`). Either the K9 or the dragged
player can end the drag at will, no consent needed either direction —
mirrors leash's "no consent needed to get free" rule, applied to a target
who never consented to entering either (item 4).

Event contract: `qbx_k9unit:server:requestDrag(targetNetId)` [client→server]
— validates flag/access/proximity, the appropriate downed check per target
type, and item 5's gate for a player target.
`qbx_k9unit:client:applyDragSpeedLimit(expiresAt)` [server→client, player
target only]. `qbx_k9unit:server:releaseDrag()` [client→server, either
party]. Distance/expiry safety valve via `maxDragDistance`.

### 12.5.5 Advanced agility — fence/window vault approximation (`Config.Features.AgilityAdvanced`)

Extends `client/movement.lua`'s existing `AgilityBasicJump` precedent
(same "own body" file). A manual radial/keypress trigger fires a scripted
vault (`SetEntityVelocity` reposition, optionally layered with
`TaskPlayAnim`) when moving toward a detected low obstacle under
`maxVaultHeight`, subject to `vaultCooldownMs`. Obstacle detection: item 3's
decided multi-height capsule sweep. There is no generic ped "jump task"
native — jump is native-locomotion/input-driven, not a scriptable task; the
arc is layered on top of or driven independently of that input.

Reality check: native-only mechanical approximation, no real climbing
animation exists or is expected to. Open: in-engine tuning of the sweep's
height bands/capsule radius/forward distance; exact vault
natives/animation pairing for a quadruped skeleton — genuinely unresolved,
no candidate clip found.

---

## 12.6 — Cross-cutting notes carried forward from §9

- §9 item 5 (PvP-balance review) applies to every value in §12.2, widened to
  re-cover items 4/5 now that PvP is in scope, and should weigh in on item
  8's `NonComplianceDetection` knobs once built.
- Recommend a security pass confirming item 5's gate is enforced in all
  three player-targeting validation paths (never trusting a client's claim
  that a target is a player or eligible), item 2's acceptance criteria are
  met exactly, and item 8's guardrails 2/3 are actually implemented (not
  merely documented) once `server/combat.lua` exists.
- Item 7 is resolved — what remains is `server/partnership.lua` existing as
  real, tested code, not further design.
- The `qbx_k9unit:client:apply*` handlers (item 8) are the first
  client-side surface that must run generically on any connected player —
  deserve the same file-boundary/trust-model scrutiny as everywhere else in
  this codebase.

## 12.7 — Quick-reference: decisions

1. PvP vs. PvE scope — **decided in scope** (item 1).
2. HandlerDownDefense's aggressive state — **decided**, UI convenience only
   (item 2).
3. AgilityAdvanced detection — **decided**, capsule-sweep raycast (item 3).
4. Non-consensual application posture — **resolved**, a different category
   from leash, compensated by item 5 (item 4).
5. Target-eligibility — **resolved**, `RequireWantedStatus` config-driven
   gate, default `true` (item 5).
6. PropDragging's downed-check for a player target — **resolved**, a
   required two-part contract; NPC-target path unaffected (item 6).
7. Handler-partnership link — **resolved**, new DB-backed registry, Option A
   (`LeashPairs` reuse) rejected outright (item 7).
8. Client-relay/non-cooperating-target architecture — **resolved**: forced
   network-ownership migration rejected as unviable; ship with detection +
   binding guardrails instead (item 8).
9. Native/animation verification still outstanding: bite/attack anim visual
   quality across breeds, vault animation for a quadruped skeleton —
   unresolved, not design questions.
10. Every numeric placeholder in §12.2, including `NonComplianceDetection`'s,
    needs a PvP-balance/config-validator pass before any flag defaults
    `true` — item 8 specifically flags `speedTolerance = 1.0` as too loose
    for `BiteAndHold`, recommending ~0.5 as a starting point.

---

## 13.0 — Cross-cutting architectural decisions

### Decision 1: the five wellbeing stats are ONE subsystem, not five

> **Four of the five are gone.** `MoodSystem`, `FearStressSystem`,
> `DistractionSystem` and `InjuryLimping` were removed on 2026-09-02 at the
> owner's request. Only `FatigueSystem` remains. The decision below is why
> they shared one table, one file pair and one tick -- which is also why
> removing four of them left the fifth working.


All five ship as one `client/wellbeing.lua` + `server/wellbeing.lua` pair,
one `Config.Wellbeing` table, one per-citizenid stat store — each
`Config.Features.*` flag independently gates only that stat's own tick
logic and gameplay effects. Mirrors `Config.Tracking`'s existing precedent
(three independently-toggleable flags sharing one file pair, one tick/prune
shape, one config table): all five are structurally the same mechanism (a
0–100 value that rises/falls on triggers and gates behavior at a
threshold), four of the five need Phase 2's existing damage/weapon-fire
relay data as their trigger source (new *consumers*, not new detection),
and the gameplay-facing consequences overlap enough that a *composed*
movement effect (Decision 2) needs to exist regardless. This does **not**
weaken the independent-flag requirement (§3) — enabling `MoodSystem` alone
runs only Mood's own logic; the other four never tick or gate anything.

### Decision 2: a single client-side "move-rate composer" is required once Phase 3 + Phase 4 both exist

By the time both phases ship, **at least four independent features** want
to call `SetPedMoveRateOverride` on the K9's own ped: `PropDragging`
(§12.5.4, already flagged there as needing every-tick reassertion),
`FatigueSystem`'s low-fatigue penalty, `InjuryLimping`'s low-leg-health
penalty, and `XPProgression`'s tier bonus. The native is a **single scalar
override, last-caller-wins** — with no coordination, whichever system calls
it last on a given frame silently cancels every other active modifier, a
guaranteed collision (not a rare race) given `PropDragging`'s own
every-tick reassertion.

**Decision:** one resource-global client function, `RecomputeK9MoveRate()`,
owns the **only** call to `SetPedMoveRateOverride` for the K9's own ped.
Every system sets its own named multiplier in a shared table
(`K9MoveRateModifiers.fatigue`/`.injury`/`.xpTier`/`.dragging`, each
defaulting `1.0`) and calls `RecomputeK9MoveRate()`, which multiplies every
active modifier and makes the one real call. Lives in `client/movement.lua`
(the existing "own body" locomotion file). **Disclosed limitation:** this
prevents modifiers *within this resource* from clobbering each other; it
cannot prevent some *other* resource on the same server from independently
calling the same native and clobbering all of it at once — a pre-existing
FiveM limitation (a single scalar override, global per-entity, no stacking
API) no in-resource coordination can close.

### Decision 3 (methodology, reused from §12.0): "does the client's own claimed stat value matter" is answered the same way every time

Every wellbeing stat, and XP, is **server-authoritative state** — the
server, never the client, owns the real number. But the *movement-speed
consequence* of that state is still a client-self-applied native effect
(Decision 2), the same trust-model category §12.5.5 already accepted for
`AgilityAdvanced`'s own-body locomotion. A modified client could ignore its
own pushed value and never call `RecomputeK9MoveRate()`, giving itself no
penalty a legitimate client would suffer — a real, disclosed, but bounded
limitation: it only ever benefits the cheater's own movement speed (the
same category a server's separate anti-cheat already watches for), and it
never extends to any *server-adjudicated* action — every place a stat or XP
tier gates a real capability (e.g. `FearStress`'s hesitation state
rejecting a combat request server-side) is enforced from the server's own
value, independent of the client's local honesty.

---

## 13.1 Sub-phase ordering (dependency graph)

> **Rows naming a wellbeing flag other than `FatigueSystem` describe an
> ordering for features removed on 2026-09-02.** Kept as the record of how
> the sub-phase graph was reasoned about, not as work still to be done.

| Sub-phase | Feature(s) | Why this order |
|---|---|---|
| 4a — independent | `ContrabandScreenFX` | Pure client-local cosmetic off Phase 2's already-built result. |
| 4b — independent | `K9Inventory` | Self-contained ox_inventory stash, no dependency on wellbeing/XP/medkit. |
| 4c — foundational for 4d/4e/4f | Wellbeing skeleton (no flag of its own) | The shared stat store, tick loop, and `RecomputeK9MoveRate()` (Decision 1/2) — must land before any of the five wellbeing flags is meaningful. |
| 4d — depends on 4c | `FatigueSystem`, `InjuryLimping` | Land together: both are decaying/regenerating stats with only a movement-speed effect through the shared composer. |
| 4e — depends on 4c | `MoodSystem`, `FearStressSystem` | Land together: both react to the same relay-log event class and both gate a *behavioral* effect rather than a pure speed modifier. |
| 4f — depends on 4c and `InjuryLimping` (4d) as a concept | `DistractionSystem` | An instant, event-triggered status effect, not a decay stat — still needs the shared store/tick to expire it. |
| 4g — depends on 4c/4d | `K9Medkit` | Restores real health and the `Injury` stat's tracked value — needs `InjuryLimping`'s stat to exist first. |
| 4h — independent, but its speed effect depends on Decision 2 | `XPProgression` | Award/persistence logic has no wellbeing dependency; sequence after 4c/4d for the speed-multiplier effect. |

## 13.2 Config schema additions

**Every numeric value below is an unreviewed placeholder** (§9 item 4's
scope, widened here) — flagged for a config-validator/economy-balance pass
before any owning flag defaults `true`.

```lua
Config.XP = {
    awards = {
        searchContrabandFound = 25, trackSourceResolved = 10,
        biteHoldSuccess = 20, takedownSuccess = 30,
    },
    scopePerCitizenidOrJob = 'citizenid', -- 'citizenid' (default, portable across dept change) vs 'job' (resets like k9_certifications) -- genuinely open, §13.6 item 2
}

-- Backs FatigueSystem/MoodSystem/FearStressSystem/DistractionSystem/
-- InjuryLimping (Decision 1: one shared table, one file pair, five
-- independently-gated flags).
Config.Wellbeing = {
    tickIntervalMs = 5000, -- ONE shared decay/regen tick for all five stats

    Fatigue = {
        max = 100, sprintDecayPerTick = 2.0, idleRegenPerTick = 1.0,
        restRegenPerTick = 4.0, restRadius = 5.0, restSources = { 'water_bowl' }, -- §13.4.3.1 open question on detection mechanism
        speedPenaltyThreshold = 30, speedPenaltyMultiplier = 0.85, -- fed into RecomputeK9MoveRate(), never a standalone override call
    },
    Mood = {
        max = 100, damageDecayAmount = 15, petRegenAmount = 10, petCooldownMs = 30000,
        feedRegenAmount = 20, feedItemName = 'k9_treat', passiveRegenPerTick = 0.2,
        performancePenaltyThreshold = 25, performancePenaltyMultiplier = 0.9, -- §13.4.3.2 open question: what this multiplies
    },
    FearStress = {
        max = 100, gunfireRadius = 20.0, gunfireLookbackSeconds = 15,
        risePerNearbyShotPerTick = 5.0, passiveDecayPerTick = 1.0,
        hesitationThreshold = 70, hesitationDurationMs = 8000, calmDownReduceAmount = 40, calmDownCooldownMs = 15000,
    },
    Distraction = {
        flashbangImmune = true, -- see §13.4.3.4 -- genuinely integration-dependent, NOT guaranteed
        meatBaitItemName = 'k9_meat_bait', meatBaitDurationMs = 6000, meatBaitRadius = 8.0,
        whistleItemName = 'k9_ultrasonic_whistle', whistleDurationMs = 4000, whistleRadius = 15.0,
        perTargetCooldownMs = 20000,
    },
    Injury = {
        max = 100, sprintBlockThreshold = 30, jumpBlockThreshold = 20,
        speedPenaltyMultiplier = 0.7, damageDecayAmount = 10,
        passiveRegenPerTick = 0.1, -- deliberately slow: K9Medkit is the intended primary recovery path, not natural regen
    },
}

Config.K9Inventory = {
    slots = 5, maxWeight = 8000, interactRange = 2.0,
    accessScope = 'department', -- 'department' (default, shared field equipment) vs 'ownerOnly' -- genuinely open, §13.6 item 3
    allowedItems = nil, -- optional whitelist; enforceability unconfirmed, §13.6 item 3
}

Config.K9Medkit = {
    itemName = 'k9_medkit', healthRestore = 50, injuryRestore = 40,
    range = 2.0, cooldownMs = 60000,
    emsJobs = { 'ambulance' }, -- plus any Config.Departments job
    -- IsMedkitUserAuthorizedOverride: function(usingPlayerServerId) -> boolean, optional
}

Config.ContrabandScreenFX = {
    triggerTiers = { 'aggressive_bark' }, -- which Config.ContrabandAlertTiers alert values also trigger this
    modifierName = 'drug_wobbly_shroom',  -- CANDIDATE ONLY, not independently verified -- §13.4.5
    durationMs = 8000,
}
```

## 13.3 File/module plan

| File | New/extends | Owns |
|---|---|---|
| `server/wellbeing.lua` | New | The unified stat store, the single shared tick loop for all five stats, consumption of Phase 2's existing relay logs (a new *reader*, not a second ingestion copy), `qbx_k9unit:server:getWellbeingSnapshot`, the server-side gate `server/combat.lua` must call before honoring a hesitating K9's combat request. Ephemeral/in-memory, mirroring `server/tracking.lua`'s precedent. |
| `client/wellbeing.lua` | New | Receives pushed snapshots, sets `K9MoveRateModifiers.fatigue`/`.injury` and calls `RecomputeK9MoveRate()`, enforces client-local sprint/jump blocks for low Injury, plays the Distraction effect. |
| `client/movement.lua` | Extends | Adds `RecomputeK9MoveRate()` and `K9MoveRateModifiers` (Decision 2) — the "own body" locomotion file is the right home. Also reserves `.xpTier` and `.dragging` slots for XP and `PropDragging` respectively. |
| `server/progression.lua` | New | XP award/persistence: `K9XP[citizenid]` cache (mirrors `Certifications[citizenid]`), atomic `k9_progression` UPSERT, tier lookup, award hooks into Phase 2/3's success paths. |
| `client/inventory.lua` / `server/inventory.lua` | New pair | `K9Inventory`'s stash open + `RegisterStash`/access-scope enforcement. |
| `client/medkit.lua` / `server/medkit.lua` | New pair | `K9Medkit`'s useable-item registration + server-side heal validation, calling `server/wellbeing.lua`'s `RestoreInjury(citizenid, amount)`. |
| `server/search.lua` | Extends (Phase 2 file) | After computing `alertTier`, if `ContrabandScreenFX` is on and the tier is in `triggerTiers`, sends `applyContrabandScreenFx` to the requester only. |
| `client/search.lua` | Extends (Phase 2 file) | Handles `applyContrabandScreenFx` — `SetTimecycleModifier`, wait, clear; must also clear on resource stop/death/disconnect, mirroring `client/vision.lua`'s exit-path discipline. |
| `config.lua` / `fxmanifest.lua` | Extend | Add §13.2's tables; add the new files. |

## 13.4 — Per-feature detailed spec

### 13.4.1 XP Progression (`Config.Features.XPProgression`)

A configured action (Phase 2 search/tracking success, Phase 3 bite-hold/
takedown success, per `Config.XP.awards`) awards flat XP to the acting K9's
citizenid via an atomic UPSERT, updating the in-memory `K9XP[citizenid]`
cache **synchronously**, before the DB write completes. Crossing a
`Config.XPTiers` threshold immediately changes the server's own
authoritative `scentRange` (read by `findTrackableSource` in place of the
Phase 2 default) and notifies the K9's client to set
`K9MoveRateModifiers.xpTier` (Decision 2). On (re)connect, the server loads
real XP from `k9_progression` into `K9XP`, mirroring `certifications.lua`'s
cache-backfill pattern.

Server-authority: total XP, tier lookup, and resulting `scentRange`/
`speedMultiplier` are 100% server-computed and server-cached — a modified
client claiming a higher tier gets nothing. The speed consequence is a
client-self-applied effect (Decision 3), disclosed and bounded.

Event: `qbx_k9unit:client:xpTierChanged(newTier)` [server→client, K9 only]
on any tier crossing.

Open: (1) per-citizenid or per-(citizenid, job) XP scoping — genuinely open,
§13.6 item 2, blocks `server/progression.lua`'s schema; (2) whether a
separate append-only `k9_xp_log` should exist for audit — not decided; (3)
what exactly counts as "the K9 reached the resolved source" for
`trackSourceResolved` — awarding on `found = true` alone would let XP be
farmed by repeatedly triggering searches without completing them; a fix
(server verifies live arrival proximity before awarding) is sketched, not
committed; (4) award values/tier thresholds remain unreviewed placeholders
(§9 item 4).

### 13.4.2 K9 Inventory (`Config.Features.K9Inventory`)

On `PlayerLoaded` (or lazily), the server registers a per-character stash
(`'k9inv-' .. citizenid` — one per K9 character, **keyed to the K9 player's
own citizenid**, correcting §6.5's leftover pre-correction "handler's active
K9 slot" phrasing, which doesn't exist in this resource's model). An
ox_target option opens it via the standard ox_target + ox_inventory
pattern, subject to `slots`/`maxWeight`/`allowedItems`.

Server-authority: stash access is a real ox_inventory-enforced capability —
the `owner`/`groups` arguments at `RegisterStash` time are what actually
restrict access; the ox_target option's visibility is a UX convenience
only. The stash id is derived server-side from the K9's own resolved
citizenid, never client-supplied.

Open: (1) `accessScope` department-shared vs. owner-only — a real
product/security-posture fork, not a formality (§13.6 item 3); (2)
`allowedItems` enforceability — no native ox_inventory whitelist-at-registration
option is confirmed to exist; would need a `registerHook`-style item-move
hook if not; (3) exact dynamic per-player `RegisterStash` call shape not
independently verified against source/a live install; (4) whether opening
the stash should require a "safe" (non-leashed/non-combat) K9 state — a
judgment call, not a mandate.

### 13.4.3 K9 Wellbeing — unified subsystem

Per Decision 1, the five flags below are documented as instances of one
mechanism.

#### 13.4.3.1 Fatigue (`Config.Features.FatigueSystem`)

The shared tick decrements `fatigue` by `sprintDecayPerTick` while
server-computed recent-position-delta speed indicates sprinting (reusing
§12.5.2's exact rolling-sample technique, a second consumer not a new
detection method), increments by `idleRegenPerTick` otherwise or
`restRegenPerTick` within `restRadius` of a rest source. Below
`speedPenaltyThreshold`, the client sets the fatigue move-rate modifier
(Decision 2). Open: exact rest-source detection mechanism (item name?
world-object proximity? both) — should stay extensible since Phase 5's
kennel will likely also want to be a rest source; whether Fatigue should
also gate a Phase 3 combat action (recommend not, without an explicit ask).

#### 13.4.3.2 Mood (`Config.Features.MoodSystem`)

> **REMOVED 2026-09-02, at the owner's request.** The design below was
> built and shipped, then taken out. It is kept as a record of why it was
> shaped this way -- it does NOT describe anything in the resource today,
> and nothing here should be implemented from without deciding to bring
> the feature back first.


Decrements by `damageDecayAmount` on a logged damage event where the K9 is
the victim (a second, independent consumer of Phase 2's relay, not a change
to what `server/tracking.lua` does with it); increments via "Pet K9"
(`petRegenAmount`, `petCooldownMs`) or a configured food item
(`feedRegenAmount`); passively regenerates otherwise. Below
`performancePenaltyThreshold`, a "minor performance penalty" applies.
**Open (real fork, not a naming quibble):** what exactly the penalty
applies to — (a) a movement-speed multiplier through the same composer as
Fatigue/Injury (simplest, tentatively recommended), or (b) a success-chance
penalty on Phase 2/3 rolls (a materially bigger change, requiring a new
parameter into already-designed security-critical callbacks). Not decided
here. Also open: whether petting requires the interactor to hold a
`Config.Departments` job, or is open to any nearby player.

#### 13.4.3.3 Fear/Stress (`Config.Features.FearStressSystem`)

> **REMOVED 2026-09-02, at the owner's request.** The design below was
> built and shipped, then taken out. It is kept as a record of why it was
> shaped this way -- it does NOT describe anything in the resource today,
> and nothing here should be implemented from without deciding to bring
> the feature back first.


Rises by `risePerNearbyShotPerTick` per tick for each weapon-fire event in
Phase 2's existing log within `gunfireRadius`/`gunfireLookbackSeconds` —
the cleanest reuse in the subsystem, zero new detection mechanism. Above
`hesitationThreshold`, the K9 enters a hesitation state for
`hesitationDurationMs` — a real, **server-enforced** refusal of Phase 3's
`BiteAndHold`/`NonLethalTakedown`/`PropDragging` requests, until "Calm Down"
(`calmDownReduceAmount`, `calmDownCooldownMs`) or natural decay.

**The one wellbeing stat with a real, not cosmetic, server-enforced gate:**
unlike Fatigue/Injury's speed-only consequence, `server/combat.lua` must
call a `server/wellbeing.lua`-exposed `IsHesitating(citizenid) -> boolean`
as a pre-check in its own request validation — a modified client ignoring
its own pushed `fearStress` value and firing a request anyway must still be
rejected server-side.

Open: whether the hard-timeout-then-retry shape is right vs. requiring
explicit "Calm Down" every time; whether "Calm Down" should be self-only
(this document assumes self-only, an interpretation not a certainty) or
issuable by a partnered handler on someone else's K9. **See `KNOWN_ISSUES.md`'s
fear/stress entry for the still-open, repeatable-griefing angle on this stat.**

#### 13.4.3.4 Distraction (`Config.Features.DistractionSystem`)

> **REMOVED 2026-09-02, at the owner's request.** The design below was
> built and shipped, then taken out. It is kept as a record of why it was
> shaped this way -- it does NOT describe anything in the resource today,
> and nothing here should be implemented from without deciding to bring
> the feature back first.


Two independent halves. **Item-triggered distraction** (fully native-only):
a thrown "meat bait" or used "ultrasonic whistle" item, within its radius
of one or more K9-model players, sets `distractedUntil` server-side per
affected K9 (subject to `perTargetCooldownMs`) — interpreted as a rejection
of Phase 3 combat-command requests server-side, not a forced animation (the
same non-possession principle as §12.0 item 2). **Flashbang immunity**
(genuinely integration-dependent, **not** guaranteed native-only): flashbang
effects typically come from a separate, server-specific weapon resource,
not one vanilla native this resource can intercept generically — whether
immunity is achievable at all depends on how that other resource applies
its stun effect, which this document cannot responsibly guess at. Ships as
aspirational config pending an ecosystem-verification pass, not a
guaranteed deliverable.

Server-authority: item-triggered distraction is a real capability with real
stakes (could plausibly be used *against* a pursuing K9 by a fleeing
suspect) — the server resolves affected K9s from the using player's own
live position, never a client-claimed target, and consumes the item
server-side via ox_inventory.

Open: flashbang immunity's actual achievability; whether using the item
should require any particular job/permission or be open to anyone
(including, plausibly, an adversarial suspect) — reading the original
wording as intentionally open, not asserted as certain.

#### 13.4.3.5 Injury/Limping (`Config.Features.InjuryLimping`)

> **REMOVED 2026-09-02, at the owner's request.** The design below was
> built and shipped, then taken out. It is kept as a record of why it was
> shaped this way -- it does NOT describe anything in the resource today,
> and nothing here should be implemented from without deciding to bring
> the feature back first.


Decrements by `damageDecayAmount` per logged damage event (same relay reuse
as Mood), regenerates very slowly passively — `K9Medkit` is the intended
primary recovery path, not natural regen. Below `sprintBlockThreshold`/
`jumpBlockThreshold`, the relevant input is blocked
(`DisableControlAction`, the same mechanism `AgilityBasicJump`'s
suppression thread already uses); below either, the composer applies
`speedPenaltyMultiplier`. Server-authority: the `injury` value is
server-tracked; the sprint/jump input blocks are **client-local,
self-applied, not separately server-enforced** — a modified client ignoring
its own low-injury value gains only the same bounded, self-contained
movement advantage every other wellbeing stat's speed effect does (Decision
3).

### 13.4.4 K9 Medkit (`Config.Features.K9Medkit`)

A player holding a `Config.Departments`/`emsJobs` job uses the configured
item on a nearby K9 to restore `healthRestore` to real ped health and
`injuryRestore` to the wellbeing `Injury` value, subject to `cooldownMs`.

**Reality check, honestly flagged:** `SetEntityHealth` restoring a networked
ped's health from server-side script is standard, widely-used FiveM
practice, but was **not independently verified against this codebase's own
natives-research convention** — MEDIUM confidence, not asserted at the same
certainty as e.g. `SetSeethrough`. The recommended, more-consistent-with-
this-codebase's-own-precedent alternative is a `applyMedkitHeal` event to
the target K9's **own** client, which calls `SetEntityHealth` on itself —
same "client self-applies to its own entity" pattern used throughout this
phase — but this is a recommendation, not confirmed necessary; verify
before committing to either approach.

Server-authority, mirroring §15 `#contraband-search`'s established pattern:
(1) feature-flag + eligibility first, (2) **live proximity check before any
state mutation**, never a client-claimed distance — closes the single most
important "map-wide oracle" risk that note flags, applied here to a heal
effect instead of an inventory read, (3) target-type re-verified
server-side via `GetEntityModel`, (4) item consumption is
server-authoritative via ox_inventory (exact export/registration pattern
not independently verified — same caveat class as §9 item
11), (5) cooldown stamped **before** the heal completes, not after, (6)
restoration clamped to each value's own max, never allowed to overheal.

Open: `SetEntityHealth`'s server-vs-client reliability (the single biggest
open implementation question here); exact ox_inventory useable-item
registration API; `emsJobs`'s relationship to whatever real EMS system the
target server runs (a plausible shape, not a confirmed export); whether
treating a K9 should require the K9's own consent (mirrors leash) or not
(mirrors human medkit revives, which typically don't need the downed
player's consent) — this document leans toward **no consent required**, by
analogy to human medical treatment, flagged as an interpretive choice
between two established precedents in this codebase, not an obviously
correct pick.

### 13.4.5 Contraband Screen FX (`Config.Features.ContrabandScreenFX`)

When Phase 2's `searchTarget` resolves an `alertTier` in `triggerTiers`,
the **requesting K9's own client only** (never a broadcast) gets
`SetTimecycleModifier(modifierName)` for `durationMs` — a "contact high"
from close-proximity exposure during a search.

**Genuine open uncertainty, not resolved with false confidence:**
`modifierName = 'drug_wobbly_shroom'` is a **candidate only** (chosen by
family resemblance to GTA's drug-effect timecycle modifiers), unlike
`SetSeethrough`/`SetNightvision` which two independent passes confirmed
against real evidence — no equivalent verification exists for this string.
Needs a native/asset-data verification pass before implementation.

Server-authority: purely cosmetic, self-applied, no new trust surface — the
`alertTier` value it keys off is already 100% server-computed upstream by
`searchTarget`.

Open: exact modifier string; which tiers should trigger this (defaults to
only the most severe, a severity judgment call, not dictated by the
original wording); whether this should also apply to `K9Inventory`
interactions with contraband-adjacent items (out of scope as read here).

---

## 13.5 Cross-cutting notes carried forward to §9

- §9 item 4 widens to cover every numeric value in `Config.XP.awards`,
  `Config.Wellbeing`, `Config.K9Inventory`, `Config.K9Medkit`, and
  `Config.ContrabandScreenFX` — the scope of that item widens, it doesn't
  get a duplicate.
- **Cross-phase dependency:** `server/combat.lua` must call
  `server/wellbeing.lua`'s `IsHesitating(citizenid)` (§13.4.3.3) as part of
  its own request-validation order.
- **Shared-infrastructure requirement:** `RecomputeK9MoveRate()` (Decision
  2) must exist before Phase 3's `PropDragging` and any of this phase's
  speed-affecting features ship together.
- Every ox_inventory export/registration pattern this phase relies on
  beyond what §15 `#contraband-search` already confirmed (dynamic
  per-player `RegisterStash`, useable-item registration, any
  whitelist-enforcement hook) is unverified against real source or a live
  install.
- Flashbang immunity's integration dependency (§13.4.3.4) joins door-lock
  nudge-open (§9 item 12) as the second feature whose native-only
  feasibility is conditioned on an unconfirmed third-party resource.

## 13.6 — Quick-reference: decisions

1. Decision 1 (unify five flags into one subsystem) and Decision 2 (single
   move-rate composer) — both **decided**, following this codebase's own
   `Config.Tracking` precedent.
2. **XP scoping: per-citizenid or per-(citizenid, job)?** — genuinely open,
   blocks `server/progression.lua`'s schema.
3. **`K9Inventory.accessScope`: department-shared or owner-only?** —
   genuinely open, blocks the `RegisterStash` `owner`/`groups` arguments.
4. **Mood's "performance penalty" mechanism** — genuinely open, a real fork
   between a speed multiplier and a heavier change to security-critical
   Phase 2/3 callbacks.
5. **Flashbang immunity's actual achievability** — genuinely open, an
   unconfirmed third-party integration dependency.
6. **`SetEntityHealth`'s server-vs-client reliability for `K9Medkit`** —
   genuinely open, needs a native-verification pass.
7. **ox_inventory export/registration signatures** for dynamic stashes and
   useable items — genuinely open, needs verification against real source.
8. **Every numeric placeholder in §13.2** needs a config-validator/
   economy-balance pass before any of the nine flags in this phase's scope
   defaults to `true`.

---

## 14.0 — Cross-cutting design forks: resolved before any per-feature spec assumes an answer

### Fork 1 — the bone-index dependency (blocks `PropAttachments` and half of `FetchMechanic`)

**Resolved as a bounded, one-time engineering task, not a design decision
left open.** `AttachEntityToEntity`'s bone-index parameter accepts a raw
integer either way — a documented bone *name* was never actually
load-bearing, only convenient. `GetWorldPositionOfEntityBone` is
entity-type-agnostic and works on any raw index regardless of whether a
name is documented for it, converting "find a documented animal-skeleton
bone name" (a task every accessible source has failed at) into "find a
usable numeric index by direct in-engine observation" (completable in one
dev-server sitting).

**Procedure:** a throwaway `dev/bone_sweep.lua` (never added to
`fxmanifest.lua`, deleted/excluded after use) spawns/rides each
`Config.Peds` model in turn (skeleton consistency across breeds is **not**
confirmed, so all four are swept independently), loops bone index 0–199
calling `GetWorldPositionOfEntityBone` and drawing a marker + label per
index (no confirmed sentinel value distinguishes "real" from "invalid" for
this native — visually inspect all 200, don't auto-filter), and a developer
records, per model, a neck/shoulder/back index (`vestBoneIndex`) and a
mouth/jaw index (`mouthBoneIndex`) into `Config.K9BoneIndices`. While
finding the mouth index, also trigger the existing `WORLD_DOG_BARKING_*`
scenario with a test prop attached and watch for clipping — the one extra
check the mouth-carry case needs that the vest case doesn't. If no bone
distinctly separate from root/spine is found for a model, record `nil`
rather than a guess — see §14.4.2/§14.4.3 for each feature's disclosed
fallback. This sweep is a single dev-server task that unlocks both features
at once — not scheduled twice. **The shipped implementation of this
sweep is `client/bonetool.lua`/`server/bonetool.lua`, run via
`Config.Features.BoneSweepDevTool` — see `README.md` for how to run it and
why it must be turned back off afterward.**

### Fork 2 — `ProximityAudioFX`'s missing "hidden suspect" detection primitive

**Resolved: do not build a new live-entity "is this ped hidden" detection
primitive in this pass.** Ship the buildable half (audio delivery) fully
working, with the trigger condition exposed as an explicit, disclosed,
`nil`-by-default integration hook — the same "we cannot resolve this
ourselves, here is the seam" pattern already used twice in §12.0 (items 5,
6). This resource's one existing "find something near the K9" mechanism
(`findTrackableSource`) resolves the nearest still-fresh **logged
coordinate** — a historical event location, pull-based, not a live entity's
continuously-updating position — and no "is this ped currently
hidden/crouching" concept exists anywhere in this codebase. Building one is
genuine, undersized-by-the-original-wording design and implementation work,
not a natives-availability gap.

**Considered and explicitly rejected:** reusing an active tracking trail's
resolved coordinate as a stand-in "suspect" distance target. Rejected
because it's a static historical point, not a live fleeing suspect, and it
would only ever apply while a Phase 2 tracking flag is also on.

**Resolution:** `Config.ProximityAudioFX.SuspectDistanceSource` —
`function() -> number?`, `nil` by default, evaluated client-side on a tick.
Must return the live distance to whatever *this server's own* hidden-suspect
concept considers relevant, or `nil`. There is no ecosystem-dominant
convention to guess at here — **no default implementation at all, only the
seam.** While `nil` (the shipped state), the feature is real, wired, and
inert. Flipping the feature flag on without ever wiring the hook is not a
bug.

### Fork 3 — asset dependency: what ships working with zero assets vs. what needs an operator to supply something

| Feature | Zero-asset? | What an operator must supply |
|---|---|---|
| `ProximityAudioFX` | Audio mechanism: yes (same safe placeholder-soundset convention as `BasicBarkSounds`). Trigger condition, AS SPECCED HERE: no — inert until `SuspectDistanceSource` is wired (fork 2). **NOT WHAT ACTUALLY SHIPPED — see §14.4.1's own correction note.** | Real growl/pant audio (already shipped as `.ogg`, see `README.md`), and a `SuspectDistanceSource` implementation — moot; not what shipped, see §14.4.1. |
| `PropAttachments` | No — unlike `DeployableKennel`, no research pass found any generically-real placeholder prop for a quadruped vest/harness. **UPDATED, verified by reading `config.lua` directly: `propModel` no longer ships `nil`.** It ships `'prop_bodyarmour_02'` (UNVERIFIED, "will very likely not load," per that field's own comment) with `fallbackPropModel = 'prop_tennis_ball'` (the same confirmed-safe model `DeployableKennel` falls back to) — so the feature does not no-op today; it visibly attaches the tennis-ball fallback, deliberately wrong-looking so an operator notices and supplies a real vest model. | A real prop model name to replace the `propModel`/`fallbackPropModel` placeholders — `config.lua`'s own `Config.PropAttachments` comment names the exact tradeoff. |
| `FetchMechanic` | Yes, for the ball itself — `prop_tennis_ball` is the highest-confidence prop name found. Mouth-*carry* fidelity is conditional on fork 1. | Nothing required for a working feature. Optionally a custom "evidence bag" prop reskin (not required for v1). |

### Fork 4 (smaller, but load-bearing for §14.2/§14.3) — where does `ProximityAudioFX`'s automatic growl-relay cooldown live?

**Resolved: a brand-new event and cooldown table, not a reuse of
`relayBark`'s** — mirrors `relayDoorScratch`'s own already-established
precedent of not sharing `BarkCooldown` with an unrelated action. The
growl fires automatically and repeatedly (potentially every ~800ms at the
closest tier); sharing `relayBark`'s 1000ms floor would silently starve
either action purely as an artifact of budget-sharing. Gets its own event
(`relayGrowl`), cooldown table, and length cap.

---

## 14.1 Sub-phase ordering (dependency graph)

| Sub-phase | Feature(s) | Why this order |
|---|---|---|
| 5a — independent | Fork 1's bone-index sweep (throwaway) | Blocks 5c and half of 5d; cheap, bounded, unlocks two features at once. |
| 5b — independent, parallel with 5a | `ProximityAudioFX` | Unrelated to bone attachment; AS SPECCED HERE, ships inert until `SuspectDistanceSource` is wired — not what actually shipped, see §14.4.1's own correction note. |
| 5c — depends on 5a | `PropAttachments` | The attach mechanism needs zero new research (already proven, `client/vehicle.lua`); blocked only on 5a's recorded index existing. |
| 5d — spawn/throw/lifecycle independent of 5a; mouth-carry depends on 5a | `FetchMechanic` | The ball's lifecycle can start immediately with `mouthCarryModeByModel` defaulted to `'fake'`. |

## 14.2 Config schema additions

**Every numeric value below is an unreviewed placeholder** — none of these
three flags default `true`.

```lua
-- Populated ONLY by running dev/bone_sweep.lua (throwaway, not shipped)
-- against each Config.Peds model. nil = "sweep not yet run for this model" --
-- each consuming feature has its own documented fallback, never a guess.
Config.K9BoneIndices = {
    a_c_shepherd   = { vestBoneIndex = nil, mouthBoneIndex = nil },
    a_c_rottweiler = { vestBoneIndex = nil, mouthBoneIndex = nil },
    a_c_husky      = { vestBoneIndex = nil, mouthBoneIndex = nil },
    a_c_chop       = { vestBoneIndex = nil, mouthBoneIndex = nil },
}

-- Fallback offset from bone index 0 (root), used only when a model's
-- Config.K9BoneIndices entry above is still nil.
Config.K9BoneFallbackOffsets = {
    vest  = { x = 0.0, y = 0.15, z = 0.35 },
    mouth = { x = 0.0, y = 0.45, z = 0.15 },
}

Config.ProximityAudioFX = {
    tickMs = 1000,
    SuspectDistanceSource = nil, -- function() -> number?, optional, no default implementation exists -- fork 2
    distanceTiers = {
        { maxDistanceMeters = 5.0,  growlType = 'growl_close', cadenceMs = 800 },
        { maxDistanceMeters = 12.0, growlType = 'growl_near',  cadenceMs = 1500 },
        { maxDistanceMeters = 25.0, growlType = 'growl_far',   cadenceMs = 2500 },
    },
    serverCooldownMs = 500, -- own cooldown, independent of BarkCooldown -- fork 4
}

Config.PropAttachments = {
    {
        id = 'vest', label = 'Equip/Unequip Vest', icon = 'vest',
        propModel = nil, -- OPERATOR-SUPPLIED -- feature safely no-ops while nil, §14.4.2
        boneField = 'vestBoneIndex',
    },
}

Config.FetchMechanic = {
    ballPropModel = 'prop_tennis_ball',
    throwForwardOffsetMeters = 1.0, throwUpOffsetMeters = 1.2,
    throwForceForward = 12.0, throwForceUp = 6.0,
    throwCooldownMs = 5000, pendingThrowTtlMs = 15000,
    maxBallLifetimeMs = 300000,
    pickupInteractDistanceMeters = 2.0,
    mouthCarryModeByModel = {
        a_c_shepherd = 'fake', a_c_rottweiler = 'fake', a_c_husky = 'fake', a_c_chop = 'fake',
    },
}
```

## 14.3 File/module plan

| File | New/extends | Owns |
|---|---|---|
| `dev/bone_sweep.lua` | New, throwaway | Fork 1's raw-index sweep. Not added to `fxmanifest.lua`. |
| `client/proximityaudio.lua` | New | `ProximityAudioFX`'s tick loop, evaluating `SuspectDistanceSource()`, picking a tier, sending `relayGrowl`; also the receiving `playGrowl` handler. |
| `server/main.lua` | Extends | `relayGrowl` handler — a near-identical sibling of `relayBark`, own cooldown table/length cap (fork 4). |
| `client/main.lua` | Extends (small) | New exported `CanActAsK9Handler() -> boolean` — needed because `FetchMechanic`'s "Throw" is a **human handler** action, not necessarily a K9-riding player. |
| `client/propattachment.lua` | New | `PropAttachments`'s client implementation: one radial item per configured slot, tracked local object handles, unequip on model swap/disconnect/`onResourceStop`. Also owns the generic `AttachPropToOwnPed`/`DetachAndDeleteProp` mechanic that `client/bonetool.lua`, `client/fetch.lua` and `client/leashvisual.lua` all reuse. |
| `server/propattachment.lua` | New | The server half this plan originally said would not exist — see the correction note below. |

> **Corrected 2026-08-31 (watchdog pass).** As written, the first row named
> a client file that has never existed, and both rows together asserted
> **"No server file"**. Both were wrong
> against what actually shipped, and the plan around them shipped
> otherwise intact (`Config.Features.PropAttachments` is `true` by default
> and the radial gate is live at `client/radial.lua`), so a reader had
> every reason to trust them. The real files are
> `client/propattachment.lua` and `server/propattachment.lua`, both listed
> in `fxmanifest.lua`. (The wrong filename is deliberately not reproduced
> here: `tests/citationintegrity_spec.lua` sweeps every path written
> anywhere in this repo, so quoting a dead one — even to correct it — puts
> it back.) §14.4.2's trust-model discussion still reads as
> though no server file exists; treat the shipped code as authoritative
> over that section.
| `client/radial.lua` | Extends (small) | An "Equipment" submenu opener, and a "Throw Fetch Ball" item gated via `CanActAsK9Handler()`. |
| `client/fetch.lua` / `server/fetch.lua` | New pair | `FetchMechanic`'s full lifecycle, modeled on `client/kennel.lua`/`server/kennel.lua`'s spawn/confirm/cleanup pattern. |
| `config.lua` / `fxmanifest.lua` | Extend | Add §14.2's tables; add the new files. `dev/bone_sweep.lua` is never added to the manifest. |

## 14.4 — Per-feature detailed spec

### 14.4.1 Proximity Audio FX (`Config.Features.ProximityAudioFX`)

**CORRECTION -- THIS IS NOT WHAT SHIPPED, VERIFIED BY READING
`client/proximityaudio.lua` DIRECTLY.** Everything below this line in this
subsection is the original pre-implementation spec, kept for its design
reasoning; the paragraph immediately below it documents what was actually
built instead. There is no `Config.ProximityAudioFX.SuspectDistanceSource`
field in `config.lua` at all (`Config.ProximityAudioFX` ships only
`scanIntervalMs`/`triggerDistance`/`soundName`), no `relayGrowl`/`playGrowl`
event pair, and no server file changes for this feature. What shipped
instead, per `client/proximityaudio.lua`'s own header ("SCOPE -- WHAT THIS
FILE IS, AND, EXPLICITLY, IS NOT"), is a deliberately narrower, already-
working v1: a self-contained, purely client-local ambient effect that plays
a looping growl (via `client/audio.lua`'s existing NUI/GainNode bridge, not
`PlaySoundFromEntity`) for any live, recognized K9-modeled ped within
`triggerDistance`, with the gain computed from the listening client's own
distance -- no "hidden suspect" concept, no `SuspectDistanceSource` hook,
no server relay, and nothing to wire before it works. It is not inert and
was not blocked on fork 2's deferred detection primitive; it simply solved
a narrower, real problem than this spec originally scoped, and explicitly
does not block a future `SuspectDistanceSource`-driven layer being added on
top of it later.

**ORIGINAL SPEC, KEPT FOR THE DESIGN REASONING, NOT AS A DESCRIPTION OF
CURRENT BEHAVIOUR:** Requires `BasicBarkSounds` also `true`. A tick loop
evaluates `SuspectDistanceSource()`; if `nil` or beyond the farthest tier,
nothing happens. Otherwise it finds the nearest-matching tier and, once
that tier's own `cadenceMs` has elapsed, sends `relayGrowl(growlType)`. The
server re-validates flags/access, length-caps `growlType`, consumes the
independent `GrowlCooldown`, resolves the sender's own ped (never
client-supplied), and broadcasts `playGrowl(netId, growlType)` to everyone
— the same "broadcast wide, let native audio 3D-cull" posture as
`relayBark`/`relayDoorScratch`.

Open: the real "hidden suspect" detection primitive itself (explicitly
deferred, fork 2) — still open; not built by the v1 that shipped either.

### 14.4.2 Prop Attachments (`Config.Features.PropAttachments`)

A config-driven list of "slots," each its own context-sensitive
Equip/Unequip radial item under an "Equipment" submenu. **Self-administered,
purely client-side, zero new server event — a deliberate decision.**
Extends `client/vehicle.lua`'s own already-shipped, already-accepted
precedent — deliberately **not** `DeployableKennel`'s pattern (full
server-computed-coords + registry), because a worn prop has no independent
existence, it lives and dies exactly with the K9's own ped.

On Equip: resolves the model's `Config.K9BoneIndices` entry and attaches via
`AttachEntityToEntity`; if unresolved, falls back to root bone + the
documented fallback offset; if `propModel` is `nil`, notifies "not
configured" and does nothing. On Unequip: `DetachEntity` + `DeleteEntity`,
also on model swap, K9 vehicle entry/exit, disconnect, and
`onResourceStop`. **Disclosed limitation:** no server-side re-check forces
an unequip on later decertification — mirrors `client/vehicle.lua`'s own
existing "no forced eject" posture.

Open: the real prop model(s) (fork 3, operator-supplied); whether nested
attachment (prop on a K9 that then enters a vehicle) renders correctly —
untested.

### 14.4.3 Fetch Mechanic (`Config.Features.FetchMechanic`)

**Throw** (a *handler* action — the thrower need not be K9-riding): radial
item gated by `CanActAsK9Handler()`. Server re-validates flag/access/
cooldown/one-active-ball-per-thrower, computes a spawn point + throw-force
vector from the thrower's own live position/forward vector. **Pursue:**
zero scripting — normal native locomotion, no autonomous pursuit task.
**Pick up:** within `pickupInteractDistanceMeters`, an ox_target option
gated by `CanShowK9UI()`, server re-validated. **Carry:** branches on
`mouthCarryModeByModel[currentModel]` — `'attach'` (only for a model whose
sweep found a usable index) does a one-shot `AttachEntityToEntity` at the
mouth bone (deliberately **not** re-asserted every tick, unlike
`PropDragging` — no adversarial party); `'fake'` (the default for every
model) deletes the world ball and plays a carry animation/scenario
instead. **Drop:** a second radial toggle releases wherever the K9 stands.
**Lifecycle:** `maxBallLifetimeMs` force-despawns an un-dropped ball;
`playerDropped`/`onResourceStop` cleanup mirrors `server/kennel.lua`'s
pattern.

Open: whether `'fake'` mode's animation should reuse the existing
`WORLD_DOG_BARKING_*` scenarios (untested for this intent); fork 1's sweep
outcome per model.

---

## 14.5 — Cross-cutting notes carried forward

- Config-validator pass required before any of these three flags default
  `true` — every numeric value in §14.2 is an unreviewed, reasonable-looking
  guess.
- `SuspectDistanceSource` and `propModel` are both, deliberately,
  "we cannot resolve this ourselves, here is the seam" integration points,
  not partially-implemented features.
- `ProximityAudioFX` is specced against the existing, proven
  `PlaySoundFromEntity` pipeline, reusing `relayBark`'s shape almost
  verbatim.

## 14.6 — Quick-reference: decisions

1. Fork 1 (bone-index sweep) — **resolved** as a concrete, bounded
   procedure; shipped as `client/bonetool.lua`/`server/bonetool.lua`.
2. Fork 2 (`ProximityAudioFX`'s hidden-suspect detection) — **resolved** as
   a deliberate deferral: delivery ships real; the trigger ships as an
   inert, `nil`-by-default hook.
3. Fork 3 (asset dependency) — **resolved** as an explicit per-feature
   disclosure.
4. Fork 4 (`ProximityAudioFX`'s cooldown) — **resolved**: a new,
   independent event/cooldown pair.
5. `PropAttachments`' trust model — **resolved**: purely client-side, no
   server event. Disclosed limitation: no forced unequip on later
   decertification.
6. `FetchMechanic`'s throw-gate — **resolved**: `CanActAsK9Handler()`,
   distinct from `CanShowK9UI()`.
7. `FetchMechanic`'s mouth-carry fidelity — **resolved as a safe default**:
   every model ships `'fake'` until a sweep + clipping check explicitly
   upgrades a specific model.
8. Real growl/pant/vest/harness/camera-housing audio and prop assets — bark
   and growl audio shipped (see `README.md`); vest/harness props remain
   operator-supplied (fork 3).

---

## 15. Research notes (native verification, security review, design research)

Condensed from a research archive that itself had already been consolidated
once from 24 separate per-topic files down to 12 anchors — the load-bearing
finding from each was usually already restated in the `.lua` file it
informed; this section keeps the parts that aren't fully duplicated
elsewhere (native hash/signature facts worth a lookup, and items that are
still open today). **If something here disagrees with the code, the code
wins** — read the cited `.lua` file's own header comment for the
authoritative, current version of anything that shipped. Anchor names
(`#vision`, `#tracking`, etc.) are unchanged from the old
`phase2_notes/RESEARCH_ARCHIVE.md` — only the filename changed.

**A finer-grained pinpoint (e.g. `#tracking §2.4`, `#door-interaction
Finding 3`) cited in a code comment will NOT resolve to anything below.**
The pre-condensation research archive numbered its findings within each of
its 12 topic anchors; that internal numbering was not preserved when this
section was flattened to prose during the 2026-08-25 consolidation — only
the anchor names themselves survived, per the paragraph above. If a comment
cites one of these old pinpoints, treat the anchor name alone as the real
target and read that whole subsection; the appended number is a leftover
address into a document that no longer exists in that shape, not a sign
that this section is missing content. Not corrected comment-by-comment
across the codebase given the volume (100+ sites) — flagged here once,
centrally, instead.

<a id="vision"></a>
### Vision — thermal and night

Implemented in `client/vision.lua`. Two confirmed, dedicated toggle natives
— not the `SetTimecycleModifier` the original spec draft guessed:

| Effect | Native | Hash | Getter |
|---|---|---|---|
| Thermal | `SetSeethrough(BOOL)` | `0x7E08924259E08CE0` | `IsSeethroughActive()` |
| Night | `SetNightvision(BOOL)` | `0x18F621F7A5B1F85D` | `IsNightvisionActive()` |

Both are genuine toggle-and-forget booleans (confirmed via the CitizenFX C#
SDK's `Game.cs`, which wraps them as plain get/set properties). `SetTimecycleModifier`
is a real, separate native correctly reserved for the unrelated contraband
screen-filter effect (`ContrabandScreenFX`) — not used for vision at all.

Access gate is `IsOwnModelK9()` only (not `CanShowK9UI()`): vision is framed
as the K9's own innate perception, not a departmental privilege — the same
reasoning that later informed the [Vitality HUD](#hud-bridge)'s *opposite*
conclusion (a monitoring instrument, gated on `CanShowK9UI()`). Both
natives need an explicit forced-off on every exit path (manual toggle,
resource stop, death, losing K9 access) since neither one resets on its
own.

<a id="tracking"></a>
### Tracking — scent, blood, water, gunpowder

Implemented in `client/tracking.lua` / `server/tracking.lua`. Confirmed
natives (all client-side; the server never runs game-event simulation or
world/water geometry, so all of this is necessarily relayed):

| Purpose | Native | Notes |
|---|---|---|
| Blood-trail source | `gameEventTriggered('CEventNetworkEntityDamage', ...)` | `data[1]` = victim entity handle (confirmed); does **not** fire for script-applied damage, only organic gameplay damage — a real, documented gap, not a bug. |
| Gunpowder-trail source | `IsPedShooting(ped)` (`0x34616828CD07F1A1`), debounced false→true | Per-client self-poll, no nearby-ped scan needed. |
| Breadcrumb rendering | `DrawMarker` | Per-frame, client-only; no native does "reveal a trail" as a concept. |
| Water-crossing check | `GetWaterHeightNoWaves` (`0x8EE6B53CE13A9794`) preferred over `GetWaterHeight` | No-waves variant is frame-stable; plain `GetWaterHeight` is known-unreliable for shallow rivers. |
| In-water state | `IsEntityInWater`, `IsPedSwimming` | Live-position checks only. |

**Deliberate accepted risk, not a bug ("FORGED TRAIL DECISION"):**
`relayDamageEvent`/`relayWeaponFire` are payload-less by design (the server
never trusts a client-claimed coordinate, only re-derives the reporting
client's own live position) — but that also means a modified client can
fire either event with no real damage/shot having occurred, planting a
fabricated trail source. Accepted: tracking grants no real capability, a
false report just wastes an officer's time, and the only two candidate
server-side corroboration checks (health delta, ammo delta) both have real
false-negative risk against legitimate reports. Revisit only if a future
feature ever conditions something server-authoritative on a resolved trail
source. This does **not** apply to scent — see below.

<a id="scent-source-resolution"></a>
### Scent source resolution

`ox_inventory` exposes a real, confirmed, server-to-server hook:
`exports.ox_inventory:registerHook('swapItems', callback)`. It fires
synchronously on every item move ox_inventory processes, including a
ground-drop (`payload.toType == 'drop'`), and carries `payload.source` —
ox_inventory's own resolved source for the request, not a client-relabelable
value. This backs scent-trail source capture in `server/tracking.lua`, and
is a **smaller** trust surface than blood/gunpowder: no client-triggerable
path into this hook exists at all, so scent doesn't need a
`relayCooldownMs`-style rate limit. The hook fires *before* the drop
inventory/coords exist — resolve the dropping player's own live position
instead (`GetEntityCoords(GetPlayerPed(payload.source))`).

<a id="door-interaction"></a>
### Door interaction — nudge-open and scratch-to-alert

Implemented in `client/movement.lua` (both mechanics) and `server/main.lua`
(`relayDoorScratch`).

**GTA's native door system (`DOOR_SYSTEM_*`, `OBJECT` namespace) is real but
narrow** — it only covers doors registered via `AddDoorToSystem`. Most
FiveM door-lock resources do **not** use this system at all — they
implement their own lock flag entirely outside `CDoor`. Reading "not
registered" as "safe to nudge" would be a real way to violate
`nudgeRequiresUnlocked`'s hard guarantee. `SetStateOfClosestDoorOfType` and
`DoorControl` are both confirmed hardcoded to not work in multiplayer at
all — don't reach for either.

**The design that shipped avoids the whole problem deliberately**:
nudge-open never reads or writes native lock state at all. It only plays a
cosmetic push animation as the K9 passes through a door it can already
physically walk through. `Config.DoorInteraction.nudgeRequiresUnlocked` is
enforced by a resource-start `assert()` in `client/movement.lua` (fail
loudly if anyone ever sets it to anything but `true`).

**Scratch-to-alert's `doorNetId` is fully validated server-side** in
`server/main.lua`: resolved, existence-checked, and proximity-checked
against the caller's own live position before ever being broadcast —
closing a confirmed harassment vector (a certified account naming any live
entity's netId, including another player's own ped). There's also a second,
independent cooldown keyed by the resolved `doorNetId` itself.

<a id="contraband-search"></a>
### Contraband search contract and security review

Implemented in `server/search.lua`. Confirmed `ox_inventory` export surface:
`GetInventoryItems`/`GetInventory`/`GetItemCount`/`GetContainerFromSlot`. A
slot's `.weight` is already the *total* weight for that slot (`item.weight
* count`, plus adjustments) — summing it directly across matching slots is
correct; don't re-multiply by count. A vehicle's trunk inventory id is
literally `'trunk' .. plate`, resolved live server-side, never from a
client-supplied plate string.

**Must-handle findings, all implemented in the shipped file:**
- **Container recursion.** `GetInventoryItems` only returns top-level slots
  — contraband hidden in a bag placed in a searched trunk is invisible to a
  naive scan unless the search recurses into container slots to an
  explicit max depth.
- **The contraband-alert broadcast must be distance-filtered, never a
  global `-1` broadcast the way `relayBark` is.** A global broadcast would
  let anyone on the map (including the target's own accomplice) resolve who
  just got flagged. The broadcast also carries `alertTier` only, never
  `totalWeight`/`contrabandFound`.
- **Mandatory, unconditional, first-class proximity check before any
  inventory read** — without it, a modified client could supply any
  vehicle/player's netId anywhere on the map and get back a real result,
  turning the feature into a server-wide search oracle.
- **Entity-type cross-check**: the resolved entity's real type is
  independently re-derived, never trusted from the client's `targetType`
  label.
- **In-flight mutex plus a cooldown timestamp written before the awaited
  ox_inventory call**, not after — closes a check-then-act race a cooldown
  alone can't close once an `await` sits between the check and the result.
- **`search_failed` is a distinct outcome from `contrabandFound = false`.**
  Collapsing "we couldn't check" into "we checked and it's clean" is a
  correctness bug with real in-fiction consequences.

<a id="phase-3-combat"></a>
### Phase 3 combat — natives and ecosystem research

Native verification (against `citizenfx/natives`, cross-checked where a
prior claim turned out wrong):

| Feature | Key correction found |
|---|---|
| Bite-and-Hold | Mechanical hold (`SetBlockingOfNonTemporaryEvents`, `SetPedFleeAttributes`) is real and confirmed. No confirmed sustained "bite and hold" animation exists for any breed — `creatures@rottweiler@melee@streamed_core@`/`takedown_from_back` is a real, Rottweiler-only, **one-shot** takedown pose, not a loop, and needs in-engine preview before being treated as final. |
| Non-Lethal Takedown | The real ragdoll native is `SET_PED_TO_RAGDOLL` (not `TaskRagdollPed`, which doesn't exist under that name). No dedicated fall-damage-suppression native/flag exists — the real, confirmed mechanism is bracketing the forced ragdoll with `SetEntityCanBeDamaged(target, false)` / `(target, true)`. `SetEntityInvincible` is explicitly **not** recommended — it suppresses ragdoll on at least one damage source, fighting the very effect this feature needs. |
| Prop Dragging | `SetPedMoveRateOverride` (unlike the vision toggles above) is **not** fire-and-forget — its own doc text says "Needs to be looped," and must be re-asserted every tick the drag is active. |
| Advanced Agility | No generic ped "jump" task native exists at all. `StartShapeTestCapsule`/`GetShapeTestResult` are the real, confirmed natives for obstacle detection; no quadruped vault/climb animation was found or is expected to exist as a reusable vanilla asset. |

**Ecosystem research, headline finding:** the mainstream FiveM K9-script
ecosystem (v-k9, QB-K9, ND-K9, Mato-K9, Rq-dogs) is built on a
"handler-commands-an-NPC-dog" architecture, not a player playing the dog —
so ecosystem precedent for the *NPC-target* half of every Phase 3 mechanic
is strong, but there is **no existing precedent anywhere surveyed** for a
*player-controlled* companion applying a hostile effect to another real
player. Treat Phase 3's player-target combat work as original design.
Separately: `bonz_parkour` is a concrete, shipped example of the exact
"zero-validation vault" anti-pattern to avoid for Advanced Agility — it
lets a player "vault" into open air or through a wall, with no raycast, no
shape test, no allowlist at all.

<a id="handler-partnership"></a>
### Handler partnership decision (resolved)

Two Phase 3 features (Bite-and-Hold's Recall actor, Handler-Down Defense's
trigger) needed a "who is this K9's handler right now" answer independent
of momentary leash state. Two options were weighed: reuse `LeashPairs`
(cheap, but leaves the off-leash case with no defense support at all — its
own disclosed, named primary use case), or a new, independent, DB-backed
partnership registry. **Resolved: Option B** — `server/partnership.lua`, a
`k9_partnerships` table, and a mutually-consented "Partner Up" action, all
shipped behind `Config.Features.HandlerPartnership`. Reusing the leash table
was rejected outright because it fails the primary use case it was being
asked to serve.

<a id="hud-bridge"></a>
### Vitality HUD — Lua↔JS bridge design

Implemented in `client/hud.lua` + `html/index.html`/`style.css`/`app.js`.

> **Where the `design note §N` citations in `client/hud.lua` point.** That
> file cites this material about twenty-five times as "design note §3",
> "design note §5.4" and so on — numbering from the standalone HUD design
> note folded in here on 2026-08-25. §15's own header already discloses,
> for all twelve anchors, that such pinpoints no longer resolve and that
> the anchor name alone is the real target; it declines to fix them
> comment-by-comment given 100+ sites, which is the right call. This table
> does something different and additive: for this one anchor — the densest
> cluster of those citations in the codebase — it RECOVERS the mapping
> instead of only disclaiming it, so a reader chasing `§5.3` gets the
> actual sentence rather than a whole subsection to re-read. Added
> 2026-08-31.
>
> | Cited as | Now reads as |
> |---|---|
> | §3 | **Payload** (plus the vitals-field details in §6.6 and `client/hud.lua`'s own header) |
> | §4 | **Focus** — passive overlay, no `SetNuiFocus`, nothing to interact with |
> | §5 | **Cadence** |
> | §5.1 | "poll every ~250ms" (`HUD_POLL_TICK_MS`) |
> | §5.2 | "only actually push when a value moved past a small epsilon" (`HUD_CHANGE_EPSILON`) |
> | §5.3 | "force a heartbeat push at least every ~1000ms" (`HUD_HEARTBEAT_MS`) |
> | §5.4 | **No surviving text here.** The idle-backoff rule behind `HUD_IDLE_TICK_MS = 1000`; read `client/hud.lua` at that constant instead |
> | §5.5 | "push immediately on any visibility transition" |
> | §5 point 6 | "push an immediate snapshot the moment `hud:ready` fires" |
> | §6 | **Visibility gate** |
>
> **§1 and §2 have no surviving text either**, and are named here rather
> than quietly dropped — whatever they covered was cut as superseded during
> consolidation. Together with §5.4 in the table above, those are the three
> citations this map cannot resolve to a sentence; for all three, treat
> `client/hud.lua` as authoritative over this document.

**Naming**: NUI callback/message names use a `<surface>:<verbNoun>` shape
(`hud:ready`, `hud:updateVitals`) rather than this resource's
`qbx_k9unit:client:`/`qbx_k9unit:server:` net-event prefix — that prefix
exists to avoid colliding with other *resources'* global event namespace,
which doesn't apply to NUI.

**Payload**: one combined message (`visible` plus all four vitals values
together), not split into separate visibility/update messages — a split
design has two moving parts that can desync if one message is ever dropped.
`visible = false` still carries the last real values, not zeros.

**Focus**: `SetNuiFocus` is never called for this HUD — it's a passive,
non-interactive overlay. The CSS root container needs `pointer-events: none`.

**Cadence**: poll every ~250ms, only actually push when a value moved past
a small epsilon, force a heartbeat push at least every ~1000ms regardless
so a dropped message self-heals, push immediately on any visibility
transition, and push an immediate snapshot the moment `hud:ready` fires (a
message sent before the page's JS has attached its listener is lost, not
buffered).

**Visibility gate: `CanShowK9UI()`, not `IsOwnModelK9()` alone** — the
opposite conclusion from [Vision](#vision) above: the vitality HUD is a
department-issued monitoring instrument, not the K9's own sense organs.

**Still genuinely open:** whether a handler/officer partner should see
*their* K9's vitals while nearby/leashed to them — not blocking; ship
self-vitals first, extend additively later if confirmed in scope.

<a id="xp-schema"></a>
### XP / progression schema design

Implemented in `sql/install.sql` (`k9_progression` table) and
`server/progression.lua`. XP is real, mechanical, capability-adjacent state
— crossing a tier threshold changes a K9's actual movement speed and scent
range — which puts it in the same category as `k9_certifications`: it
needs offline correction, atomic accumulation (`INSERT ... ON DUPLICATE KEY
UPDATE xp = xp + ?`, avoiding a Lua-side read-modify-write race), and
queryability without scanning every player's metadata blob.

Schema: one row per `citizenid` (not per `citizenid, job`) — XP is scoped to
the K9 character itself, deliberately reading "persists per-handler" as
"survives a department change." This is a real, still-open design fork
(`Config.XP.scopePerCitizenidOrJob`, currently only `'citizenid'` is
implemented) — see §13.6 item 2 if this ever needs revisiting. The tier
lookup deliberately is **not** computed in SQL — `Config.XPTiers` is
code-side and config-driven, so baking its thresholds into a SQL `CASE`
would create a second, driftable copy of the same boundaries.

**Still open, not decided:** whether a separate, append-only `k9_xp_log`
table is also worth adding for anti-cheat/dispute auditing, given XP is
arguably more exploit-sensitive than a search.

<a id="phase-5-research"></a>
### Phase 5 features — native and ecosystem research

`AdvancedBarkRadial` and `DeployableKennel` are implemented and shipped
(five real `.ogg` files ship under `html/sounds/`, per
`html/sounds/CREDITS.md`; `prop_doghouse_01` was refuted during
implementation and replaced with the confirmed-real `prop_dog_cage_01`).
**Update: `CameraFeedPiP` has since shipped and no longer ships `false`.**
What was built is exactly the narrower spike described below as
achievable — `client/vision.lua`'s `ToggleCameraFeed()`
(`CreateCam`/`RenderScriptCams`), a full-screen takeover of your active
partner's viewpoint, not an inset. The research below about a true inset
being unachievable is still accurate and was re-confirmed at build time,
not superseded:

A true inset live-3D-video picture-in-picture is **not achievable** with stock FiveM
natives (DUI/NUI textures render HTML, not the 3D scene), corroborated by a
still-open upstream `citizenfx/fivem` GitHub issue (#3835). A full-screen
K9-POV camera **takeover** (not an inset) is fully native-only and
achievable (`CreateCam`/`RenderScriptCams`) — see above, this is what
shipped.

**`PropAttachments`/`FetchMechanic` remain genuinely unresolved** and are
why both still use the root-bone placeholder attach point pending the
dev-only bone-index sweep (`client/bonetool.lua`/`server/bonetool.lua`).
Key finding: a bone does **not** need a documented *name* for
`AttachEntityToEntity` to work, only a numeric *index* —
`GetWorldPositionOfEntityBone(entity, boneIndex)` takes a raw integer and
works on any entity, human-named or not. No open-source FiveM script found
in research ever attached a prop to an animal ped's own skeleton. This
reframes the open item from "find a documented bone name" (blocked
indefinitely) to "run a one-time in-engine sweep."

**`FetchMechanic`'s pursue/carry logic is simpler than its one real
precedent** (`fruitmob/murderface-pets`) once correctly re-scoped for a real
player: the K9 player walks to the thrown ball using their own ordinary
input, then presses an interact prompt, the same self-administered pattern
`client/vehicle.lua`'s `EnterNearestK9Vehicle` already established.
`server/kennel.lua`/`client/kennel.lua`'s existing spawn/track/cleanup
pattern is a closer lifecycle template for the ball than porting the NPC
precedent wholesale.

**`ProximityAudioFX` needs two things that don't exist yet, not one volume
knob**: (1) composing two independent distance factors rather than a single
native call, and (2) a wholly new "hidden suspect" detection primitive —
`server/tracking.lua`'s existing `findTrackableSource` is pull-based and
resolves a historical logged *coordinate*, not a live, continuously-moving
suspect ped. No FiveM script surveyed does proximity-scaled audio toward a
third, hidden entity at all.

<a id="dependencies-and-audio"></a>
### Dependency maintenance and bark-audio sourcing

Both findings here are now folded into `README.md`'s "Dependencies"
section and `html/sounds/CREDITS.md` respectively — recorded here only for
the reasoning behind them. Overextended (not CommunityOx) is the confirmed,
current, actively-maintained home of `ox_lib`/`ox_target`/`oxmysql`/
`ox_inventory`: Overextended briefly went dormant in 2025, CommunityOx
existed as a temporary community fork during that gap, and CommunityOx's
own GitHub org is now itself archived (marked so by GitHub, April 2026).
`fxmanifest.lua`'s `dependencies` block has no version-pinning syntax at
all — this is an engine limitation, not an oversight.

For bark audio: the cheaper path (extending this resource's own
already-working NUI bridge with real `.ogg` files, rather than authoring a
full RAGE `.awc`/REL custom audio bank) was recommended and is the path
that shipped — see `html/sounds/CREDITS.md` for the actual files and their
licensing.

<a id="trust-boundary"></a>
### Client-event trust boundary (`source ~= 65535`)

A client's own `TriggerEvent(name, ...)` call cannot forge a genuine
server-origin marker — confirmed directly from the `TRIGGER_EVENT_INTERNAL`
native declaration, which has no parameter for a caller to specify an
origin. FiveM's own documentation states that the server sends net id
`65535` for a server-originated event on the client — so a
`RegisterNetEvent` handler that should only ever legitimately fire from a
genuine server-sent trigger can and should guard on
`if source ~= 65535 then return end` as its first statement.

This closes a real, concrete gap: without it, a generic "trigger any event"
cheat menu could self-trigger any of this resource's `qbx_k9unit:client:*`
handlers directly — including, for the NPC-relay combat handlers, applying
or removing an effect against an NPC a *different*, legitimately-certified
K9 is mid-action against. This guard is applied to every
`qbx_k9unit:client:*` `RegisterNetEvent` handler across the resource
(`client/combat.lua`, `client/partnership.lua`, `client/wellbeing.lua`,
`client/medkit.lua`, `client/screenfx.lua`, `client/bonetool.lua`,
`client/main.lua`, `client/fetch.lua`, `client/kennel.lua`), each with its
own inline "server-origin guard" comment pointing back to this explanation.

**What this does not, and cannot, close**: a legitimately-targeted player's
own client *honestly receiving* a genuine server-sent event and then simply
choosing not to execute the restriction it applies. That is a structural
property of FiveM — it is detectable, not preventable, and is accepted as a
disclosed, guardrailed risk (§12.0 item 8), not something this guard was
ever meant to address. **See `README.md`'s live-test section for the exact
sequenced live test that checks whether this guard is actually holding on
your server** — a naive one-shot test of this guard is worthless (a fresh
client that has never received a genuine server event will read "clean"
either way and prove nothing).

---

## 16. Technical debt / refactor roadmap

Condensed from two independent audits of the same codebase. Item numbers
below (`item 1`, `item 2`, `item 2b`, `item 3`, and Part B's `item 1`–`item
4`) are cited directly in code and preserved as-is.

**Status as of the last audit — all confirmed DONE and holding under
continued concurrent editing:**
- **Item 1 — shared cooldown/mutex helper (`server/cooldowns.lua`).** Every
  file needing a cooldown or mutex uses `NewCooldown`/`NewNestedCooldown`/
  `NewMutex`. The one item that has survived every subsequent pass without
  regressing, because the helper was extracted early, before competing
  hand-rolled copies had spread.
- **Item 2 — shared netId→entity resolver (`ResolveNetworkEntity`,
  `server/entities.lua` / `client/main.lua`).** Zero raw
  `NetworkGetEntityFromNetworkId` call sites remain outside those two
  files' own function bodies. A fresh regression of this exact pattern did
  appear once, in a brand-new file (`client/propattachment.lua`) written
  mid-audit — fixed; the lesson recorded is that extracting a shared helper
  does not stop the pattern from recurring by itself, since every new
  file's author still needs to know the helper exists.
- **Item 2b — `ResolveConnectedPlayerFromPed` / `ResolvePlayerServerIdFromPed`.**
  Defined once each (`server/entities.lua`, `client/main.lua`), no stray
  local re-definitions remain.
- **Item 3 — `IsEntityModelK9(entity)` / `K9ModelHashes`.** One
  resource-global (`client/main.lua`) replaced six independent client-side
  copies (one, in `client/partnership.lua`, was undocumented until this
  extraction found it). `server/certifications/`'s own server-side
  `K9ModelHashes`/`IsConfiguredK9Model` is correctly left alone — it can't
  cross the realm boundary, and was never a duplicate of the client-side
  version.
- **`NotifyPlayer` extraction.** Was 13 independent hand-rolled copies (not
  the "2, closed" an earlier revision believed), each with its own
  deliberate "duplicated on purpose" comment — reasonable at 2-3 copies, not
  at 13, since real drift had already appeared (a narrower signature in one
  copy, deliberately different toast titles in several others). Extracted
  to `server/notify.lua`; `server/admin.lua` and `server/bonetool.lua` keep
  a thin one-line wrapper (different player-visible title per subsystem),
  each calling `_G.NotifyPlayer(...)` explicitly.
- **Flag-off-safety defect class.** Three client `RegisterNetEvent`
  handlers for a server-issued instruction had no `Config.Features.X` gate
  of their own, meaning a forged local `TriggerEvent` could reach them even
  with the feature shipped disabled (`client/kennel.lua`'s
  `deployKennelAt`/`removeKennel`, `client/medkit.lua`'s `applyMedkitHeal`,
  `client/progression.lua`'s `xpTierChanged`). All three now gate on their
  own flag first. Fixed.

**Part B — items found by a second, independent audit:**
- **Item 1 (near-term, trivial).** `client/tracking.lua`'s `StartTrack` had
  the last raw, un-migrated copy of the `common.no_k9_access` `lib.notify()`
  pattern that `client/main.lua`'s `DenyK9UIAccess()` was extracted to
  replace — one call-site swap.
- **Item 2 (near-term, trivial).** `tests/README.md`'s own coverage table
  and file count were one spec file behind the real suite
  (`tests/exports_spec.lua` existed and passed but wasn't listed anywhere).
  Folded into §20 below; keep this document's own counts current rather
  than trusting an old snapshot.
- **Item 3 (medium-term).** A first, narrowly-scoped client-side test file
  (`tests/main_spec.lua`) targeting `client/main.lua`'s small cluster of
  pure-logic globals (`IsEntityModelK9`, `IsOwnModelK9`, `HasK9Access`,
  `CanShowK9UI`, `DenyK9UIAccess`) — proving the existing sandbox pattern
  generalizes to `client/*.lua`, not just `server/*.lua`. Landed; see §20.
- **Item 4 (medium-term) — RESOLVED, dated 2026-08-25.** `server/tenure.lua`'s
  `TenureFullyCollected` cache header used to claim it avoids re-running a
  SELECT that, by construction (it's keyed on a value only known *after*
  that same SELECT returns), cannot actually be avoided. That header has
  since been corrected to describe what the cache actually short-circuits
  (the cheaper post-SELECT work, not the SELECT itself), and
  `server/tenure.lua` (its own "ITEM 4 CLOSURE" section, ~lines 461-624)
  now carries a dated, fully worked decision: LEAVE IT, do not build a
  `k9Citizenid`-keyed pre-query cache, because the coupling a correct
  invalidation hook into `server/partnership.lua` would require is a
  materially worse risk than one extra already-indexed point-lookup SELECT
  per online, fully-tenured K9 per tick — the real double-grant protection
  remains the separate, persisted, optimistic-UPDATE guard, unaffected
  either way. No longer an open item; re-opening it should require new
  evidence (a measured, reproduced DB load problem), per that section's own
  closing note. (This bullet previously cited a `tests/README.md` file for
  further detail — that file no longer exists, its coverage-table content
  having been folded into this document per Item 2 above; see
  `server/tenure.lua` directly instead.)

**Explicitly not worth doing** (re-confirmed by both audits, still true):
building a generic `ForEachPlayer(fn)` wrapper for the 6-file
`GetPlayers()`/`tonumber` iteration idiom; trimming the 200+-line file
headers on `server/combat.lua`/`client/combat.lua`/`server/partnership.lua`
(they carry a file-to-file contract, design-decision record, and
trust-boundary reasoning that would otherwise live nowhere — a direct check
found zero cases of a header actively lying about current code); splitting
those same three files on line-count grounds alone (each is one cohesive
responsibility along its own already-documented module plan); a
`DistanceBetween(a, b)` wrapper for the 17-site `#(GetEntityCoords(a) -
GetEntityCoords(b))` idiom (no per-site logic to drift, unlike
`NotifyPlayer`'s parameters before extraction).

**The one durable lesson, worth restating for whoever next edits this
section:** the most expensive recurring cost on this codebase has not been
duplicated logic — it's been a correct fix landing in code faster than the
comment/doc describing it gets updated (a fix marked "still open" for
several revisions after it shipped, and, in the other direction, a real
security fix that shipped with no roadmap entry at all for a while). Update
the relevant item's status in the same commit as the fix, not on the next
audit pass.

---

## 17. Status & operational decisions

Condensed from a document that used to track "what's currently live and
what needs a human decision" as a dated snapshot. **`README.md`'s config
reference and `KNOWN_ISSUES.md`'s "Decisions that need the resource owner"
section are the current, maintained versions of "what's live" and "what to
check"; treat everything below as the reasoning that produced today's
defaults, not a substitute for reading those two files.**

**The one-paragraph history:** this resource shipped with 5 of ~40 feature
flags enabled and the rest off pending review. All flags (`CameraFeedPiP`
included at the time — it had no implementing code back then) were later
switched on at once; `CameraFeedPiP` itself gained a real implementation
in a later, separate pass (2026-08-26 — see §"Phase 5 features" above,
which carries its own correction), so it is no longer the exception this
sentence originally carved out. Turning a flag on does not, by itself,
answer an open safety
question about that flag's feature — it just means whatever risk the
question describes is live on a real server now, not hypothetical. Two such
questions remain genuinely open (D3, D13 below); a test suite passing tells
you the code does what its authors intended, not that either of these is
resolved.

### D3 — Does the client-event origin guard (§15 `#trust-boundary`) actually hold under a specific real-world sequence?

**The check:** connect a test client, let it receive one genuine
server-originated event, then — without reconnecting — fire a locally
forged `TriggerEvent` against a guarded handler and see whether `source`
still reads `65535`. Four attempts to settle this by reading FiveM's own
source code have hit the same wall: the part that decides this isn't in any
file readable from outside the engine's private build process. **As of this
writing, nobody has run the live test.** See `README.md`'s live-test
section for the exact, sequenced procedure — running it out of order or
skipping the "receive one genuine event first" step tells you nothing. See
also `KNOWN_ISSUES.md` for the plain-language version of this decision.

**What this blocks:** trusting `BiteAndHold`, `NonLethalTakedown`, and
`PropDragging` as actually secure against a modified client — all three are
enabled by default, leaning on this exact, unverified check.

### D13 — Is a limited, repeatable griefing exploit against `FearStressSystem` acceptable on your server?

> **MOOT since 2026-09-02.** `FearStressSystem` was removed at the owner's
> request, along with the gunfire relay this exploit rode on and the
> combat gate it fed. Kept as the record of a decision that was genuinely
> open at the time, and because the SHAPE of it — a forgeable,
> payload-less client report feeding a hard server-side reject — is worth
> recognising if anything like it is ever built again.

Any player standing near a K9 — no relationship to it or its handler
required — can repeatedly send a "there's gunfire nearby" signal and force
that K9 to refuse `BiteAndHold`/`NonLethalTakedown` for about a minute at a
time, for as long as they want to keep doing it, at essentially no cost to
the attacker. **Fixed:** a single episode can no longer last forever — it
resets after ~64 seconds. **Not fixed, and not fixable in code:** the
*repeatable* version — the underlying "I heard gunfire nearby" signal has
no way to verify who actually fired a gun, by design, the same tradeoff
already accepted for scent tracking (§15 `#tracking`'s "FORGED TRAIL
DECISION"). Whether this is an acceptable cost for the realism it buys is a
judgment call about what kind of server you want to run, not something more
code can answer — see `KNOWN_ISSUES.md` for the plain-language version of
this decision.

### The one setting that should not stay on

**`Config.Features.BoneSweepDevTool`.** Its own code comment says, verbatim,
never to enable this on a production server — it lets a department boss
spawn and attach real objects in the world on demand. It requires both a
boss-rank job check **and** a separate server-startup convar
(`setr qbx_k9unit_enable_bone_dev_tool 1`) to be reachable at all. If this
flag is `true` and/or that convar is set on a server with real players,
turn both off and **restart the resource** (a flag flip alone does not
unregister the `/k9bonetool` command — it stays reachable until the next
restart). See `README.md` for the full procedure.

### Mistakes this project has made before (so the pattern doesn't repeat)

- A config comment once claimed a K9 gear-stash setting restricted access to
  that K9's own player; the check it relied on never looked at identity at
  all. Now structurally impossible to misconfigure this way — the resource
  refuses to start rather than silently grant broader access than
  documented.
- A file's own comment once claimed a certification revoke automatically
  ended that handler's partnership; the code to do that existed, but
  nothing called it, so it silently never happened until someone checked
  the claim against the code.
- A code comment once said a contraband-search screen effect applied to the
  *searched* person's screen; the code has always applied it to the
  *searching* K9's own handler, as feedback, never a penalty on a suspect.
- A shipped feature once referenced a visual effect (a timecycle modifier
  name) that didn't exist in the game's own data — it would have run with
  no error and no visible effect forever. Found by checking the name
  against the game's own data directly, not by trusting the code comment.
- A security bug (an unguarded "delete this object" handler that let a
  forged message delete any object in the world) was fixed once, then
  reappeared in a newer feature that had copied the same pattern —
  including its bug.

The common thread: a claim in a comment or doc is not proof of what the
code does. This is exactly why the citation-repointing discipline in this
document's own banner matters — an unverifiable claim is worse than no
claim at all.

---

## 18. Feature ideation backlog

Condensed from two brainstorm documents (ideation only — nothing below is
approved or built just because it's listed here; the "Ideas considered,
not built" section of `PROJECT_HISTORY.md` is the separate,
closer-to-committed backlog). Section labels (`Part A §N`, `Part A
Tier X §N`, `Part B §N`/`Part B item N`) are cited directly in code and
preserved. Items already shipped are marked so below rather than removed,
since their reasoning is still what a citation is pointing at.

### Part A — cross-phase feature brainstorm

**Tier A (small effort, buildable against Phase 1 as shipped):**
1. **K9 handler roster / admin listing UI** — `/k9roster` or an ox_target
   option listing everyone certified in a department, with one-click
   revoke. Closes a gap `§4.3`'s own rationale implied should exist.
   **Shipped**, as a tablet screen rather than the command this entry
   guessed at — see `server/roster.lua`, the tablet's own roster/person
   screens, and `docs/history/ROSTER_SPEC.md`. Callsigns and an
   "Unassigned" bucket came with it.
2. **Revoke reason code** — an optional `reason` on `/k9decertify`, stored
   in a new nullable column. Deepens the audit trail `§4.3` already
   justifies. **Shipped** — see `sql/migrations/0006_add_k9_certification_lifecycle.sql`.
3. **Leash "Heel"/recall command** for the handler side of an active leash
   pairing — the handler side currently can only detach, never actively
   summon. Still unbuilt, and note the history before rebuilding it: a
   general Recall WAS built and then removed on 2026-09-02 at the owner's
   request, along with the whole "calling your K9 off" category. A
   leash-scoped heel is a narrower idea than the one that was removed, but
   check with the owner before starting.
4. **Give `Config.Peds`' breed data actual mechanical weight** (scent/speed/
   bite bonuses per model) — the config already telegraphed this was
   anticipated (`label` was unused for a long time). **Shipped** — see
   client/movement.lua's own "BREED MOVE-RATE WEIGHT" section, which cites
   this very entry, and the `breed` slot in `K9MoveRateModifiers`.

**Tier B (medium effort, time-sensitive before Phase 3 hard-codes a binary model):**
5. **Tiered certification** (Trainee → Certified → Senior) instead of a
   single active/inactive boolean — cheap to design before Phase 3's
   combat gates all hard-code a flat boolean check in a dozen places,
   expensive to retrofit after. **Shipped** — see `server/certtiers.lua`
   and `Config.CertificationTiers`.
6. **Training-mode/practice sandbox** distinct from live duty, so a search
   or bite-hold's first live use isn't also a rookie's first attempt at the
   mechanic. **Partially shipped**, then removed on 2026-09-02.
7. **K9-down dispatch integration hook** — an event fired when a certified,
   on-duty K9's health crosses a threshold, mirroring the health-monitoring
   logic a since-removed feature used in the opposite direction. **Shipped** — see
   `server/integrations.lua`.

**Tier C (lower urgency):**
8. Long-term handler/K9 partnership *preference* record (flavor, not a new
   access rule).
9. Certification expiry/periodic recertification.
10. Handler leaderboard / `/k9stats` once XP persistence exists. **Shipped**
    — see `server/leaderboard.lua`.

### Part B — ecosystem integration & gameplay-depth ideas

**Already shipped** (kept below as the original reasoning, not an open ask):
1. **Real export/event API** — prerequisite for everything else in this
   section. **Shipped**: `server/exports.lua`/`client/exports.lua`, plus
   the outbound `qbx_k9unit:events:*` events (six when this line was first
   written, fourteen by 2026-08-26, 11 today after the 2026-09-02
   removals). Do not trust a count quoted here or in `README.md` without
   re-measuring: both are hand-maintained prose, they have cited each
   other as authoritative while both were stale, and
   tests/publicapicounts_spec.lua is what actually pins them now.
2. **Dispatch integration** (`ps-dispatch` confirmed real/current;
   `cd_dispatch`/`qs-dispatch` named by convention only, not independently
   verified) — outbound alert on a contraband find; inbound via
   `Config.Combat.WantedStatusCheckOverride`.
3. **MDT/evidence integration** (`ps-mdt` confirmed real/current) — feeding
   a completed search's result into an MDT's evidence/case system, since
   `k9_search_log` today is otherwise only readable by hand-running SQL.
6. **K9 equipment shop** — register a shop selling the item names this
   codebase already invented and left as placeholders
   (`k9_treat`/`k9_meat_bait`/`k9_ultrasonic_whistle`/`k9_medkit`).
   **Shipped** — see `server/equipmentshop.lua`.
7. **Partnership-tenure bonuses** — a passive bonus scaling with how long a
   partnership has existed, reading `server/partnership.lua`'s
   `established_at`. **Shipped** — see `server/tenure.lua`,
   `Config.Features.PartnershipTenureBonus`.
8. **XP tiers with real unlocks**, not just multipliers. **Shipped** — see
   `server/progression.lua`.
9. **In-game admin/audit surface** for certifications/partnerships/search
   log, replacing "an admin runs raw SQL by hand." **Shipped** — see
   `server/admin.lua`, `Config.Features.AdminAuditCommands`.
10. **Cooperative search bonus** for partnered K9s working the same target.
    **Shipped** — see `server/search.lua`'s partnership-aware award path.
11. **Certification specializations** (narcotics/explosives/patrol) beyond
    a single binary certified flag. **Shipped** — see
    `sql/migrations/0006_add_k9_certification_lifecycle.sql`.

**Considered and explicitly not recommended** (recorded so it isn't
re-investigated expecting a different answer): a K9 obstacle-course
leaderboard (defer until `AgilityAdvanced`'s own placeholder tuning gets a
balance pass — building a leaderboard on unsettled numbers means re-tuning
later invalidates it); a dedicated jail/corrections integration (the MDT
integration above already covers the real use case better than a second,
parallel path would); a cosmetic-only "K9 walk" idle activity (Pet/Feed
already covers this ground with a real stat effect).

---

## 19. Locale / translation system

Every player-facing string in this resource — every notification, menu
label, keybind description, command-usage message — goes through `ox_lib`'s
`locale()` function against `locales/en.json`. There are no `.lua` files
with hardcoded English text a player would see (server-console-only
`print()` lines are deliberately left as plain strings — nobody but a
developer/admin ever sees them).

**How the file is organized:** `locales/en.json` is plain JSON (no
comments, no trailing commas — must stay strictly valid), organized as
named top-level groups (mostly named after the `.lua` file whose text they
hold), each holding one or more leaf keys, looked up as `group.key`:

```json
"combat": {
  "no_target_in_range": "No eligible target in range."
}
```

is looked up in Lua as `locale('combat.no_target_in_range')`. A value can
reference another key with `${other.key}`, resolved once at load — used for
`radial.menu_open_label = "${common.notify_title}"`.

**Shared keys — check this list before adding a new one:**
- `common.notify_title` ("K9 Unit") — the title used by nearly every
  notification.
- `common.no_k9_access` ("You cannot use K9 features right now.") — shown
  by `client/main.lua`'s `DenyK9UIAccess()` helper. Most files call that
  helper directly rather than calling `locale()` themselves.
- `common.not_k9_model`, `common.too_far_from_k9` (shared by
  `client/wellbeing.lua`/`client/medkit.lua`), `common.target_no_longer_online`,
  `common.no_k9_party`, `common.k9_not_certified`,
  `common.handler_not_in_department`, `common.unable_to_resolve_citizenid`.
- `defense.already_engaged`, reused as-is by `server/combat.lua`.
- `partnership.partner_up_target_label`, reused by `client/radial.lua`.
- `movement.officer_fallback_name`/`.accept_label`/`.decline_label`, reused
  by `client/partnership.lua`'s leash-style request prompt.

**Similar-but-not-identical sentences are sometimes kept as separate keys
on purpose** (e.g. two different "kennel placement failed" messages for two
genuinely different reasons, or "on"/"off" state words that don't template
safely across every language) — check whether either reason applies before
merging two keys to reduce duplication.

**Adding a new key:** list every piece of text a player would see in the
file you're changing → check the shared-keys list and search `en.json` for
your exact sentence first → add the key under a group named after the
file it belongs to (or `common` if shared), `snake_case`, named after what
the message *means* not its exact wording → replace the hardcoded string
with `locale('group.key', ...)` (use `%s`/`%d` placeholders in the JSON
string for dynamic values, never Lua string concatenation) → confirm
`locales/en.json` is still valid JSON and `luac5.4 -p`/`luacheck` are clean
on any `.lua` file you touched.

**Manifest requirements:** `fxmanifest.lua` already declares `ox_lib
'locale'` and lists `'locales/en.json'` explicitly (not a wildcard — a
wildcard was found to behave unexpectedly here). Adding a second language
file requires its own explicit line in that same `files{}` block; it is
not picked up automatically.

**What was deliberately not touched:** `print()` calls (developer/admin
console output only) and non-text UI data (numbers, booleans).

---

## 20. Test suite

Automated tests for this resource's Lua code — mostly server-side, plus a
growing set of client-side files. Run them from `qbx_k9unit/tests`:

```sh
cd qbx_k9unit/tests
./run.sh
```

Requires `lua5.4` on `PATH` (the same version real FXServer runs); set
`LUA_BIN=/path/to/lua5.4` if it's installed elsewhere. A passing run ends
with `ALL SPEC FILES PASSED (N file(s))`. Anything else needs attention —
but see the two false alarms below before assuming a red run means a code
regression.

**Why plain `lua5.4` and not a framework like `busted`:** the only
`busted` available in this environment targets Lua 5.1, and this resource
runs on 5.4 (its `.luacheckrc` pins `std = "lua54"` to match real FXServer)
— a suite running under a different Lua version than the real server can
pass while hiding a real bug (e.g. `admin_spec.lua`'s `ClampLimit` NaN/
infinity handling depends on this specific Lua build's `tonumber`
behavior). Instead, each spec file is a small, self-contained script using
`testkit.lua` (~100 lines: `test(name, fn)` plus `equals`/`isTrue`/`isNil`/
`contains`-style checks), loads a real, unmodified production `.lua` file
into a sandboxed environment (`fixtures/sandbox.lua` — pre-fills only the
handful of FiveM natives that specific file actually calls), and exits 0/1.

**Two false alarms, read before panicking at a red run:**
1. **A half-finished spec file turns the whole suite red**, not just that
   file — `run.sh` globs `*_spec.lua`. Run the file you actually care about
   directly (`lua5.4 admin_spec.lua`) instead of trusting a full run while
   someone's mid-edit in the folder.
2. **A "locale key missing" failure can mean two different things**: (a)
   `locales/en.json` is mid-edit (a concurrency artifact — re-run once
   finished), or (b) the production code asks for a key that was never
   added or was renamed/removed by mistake (a real bug — this has actually
   happened and been caught this way). Check whether `en.json` looks
   finished before assuming (a).

**`locale()` inside the sandbox is real, not a stub** — it really reads
`locales/en.json`, so every test that checks a notification message is
also, for free, a check that the locale key behind it still exists. Build
expected text with `Sandbox.locale('some.key')` rather than typing the
English sentence by hand, so a test can't silently drift from what
`en.json` actually says. One real limit: a `local function` can only be
reached the way a real caller reaches it (a registered command/event) —
tests never copy a local function's internal logic into the test itself;
where there's genuinely no real way in, that's written up as a gap below,
not worked around.

**What's covered:** the shared cooldown/mutex helpers, entity/player
resolvers, `NotifyPlayer`, the certification grant/revoke/cache/auto-revoke
lifecycle, XP award/tier lookup, admin audit commands, kennel/combat/fetch/
inventory/propattachment/wellbeing request→confirm→end lifecycles, every
export this resource offers (`server/exports.lua`/`client/exports.lua`,
tested against the real, registered functions), and a first slice of
client-side pure logic (`client/main.lua`'s `IsEntityModelK9`/`HasK9Access`/
`CanShowK9UI`, proving the sandbox pattern generalizes past `server/*.lua`
— see §16 Part B item 3). Most spec files reach production code indirectly,
through the real event/command handlers, checking the real observable
result (a fired event, a notification, a SQL string) rather than a
rewritten copy of the logic under test.

**What's NOT covered, and why:**
- Nothing here talks to a real database, `ox_inventory`, or `ox_lib` — every
  boundary is faked, and what's checked is what the production code *does*
  with a given fake response, never whether a real dependency would accept
  it.
- `server/cooldowns.lua`'s background sweep is tested for picking the right
  entries, not for real-world timing accuracy (waiting is faked instantly).
- `server/tenure.lua`'s `TenureFullyCollected` cache doesn't actually skip
  the SELECT it claims to (§16 Part B item 4) — a test locks in this real
  behavior rather than the header's claim; the actual double-grant guard is
  a separate, unaffected DB-level check.
- The larger client files (`client/movement.lua`, `client/combat.lua`,
  `client/radial.lua`) have real logic interleaved with per-frame native
  calls throughout, not segregated into an isolable pure core — a much
  larger stubbing lift than `client/main.lua`'s cluster of pure globals.
  Accepted as a real boundary, not a rewrite target.

**Adding a new spec:** load `testkit.lua` and `fixtures/sandbox.lua` →
build a small stub table for exactly the FiveM functions your target file
calls (start empty; running the spec tells you what's missing) →
`Sandbox.newEnv({...})` then `Sandbox.loadInto('../server/whatever.lua',
env)` (load any real dependency file, e.g. `server/cooldowns.lua`, into the
same sandbox first, in `fxmanifest.lua`'s own load order) → drive the file
through its real functions/handlers and check the real observable result →
end with `os.exit(t.summary())`. **Never change a production file just to
make it easier to test** — write the gap up in "what's NOT covered"
instead.

**On stale counts:** this codebase is edited by several people at once;
any specific file count or test total here will drift. Re-run `./run.sh`
yourself before repeating a number from this section to anyone else,
rather than trusting a snapshot.

---

## 21. Compat/adapter layer (`shared/compat`)

Explains `Config.Compat` (bottom of `config.lua`) and the code that
implements it (`shared/compat/*.lua`).

**For server owners wanting to plug in an unrecognized resource:**

```lua
-- Pin to exactly one resource, no scanning, no fallback if it's not running:
Config.Compat.Systems.inventory.override = 'my-custom-inventory'

-- Or supply your own implementation outright — this wins over everything,
-- including override. One table per system, every required method for
-- BOTH realms in the same table (the running side only checks the half it
-- needs; the other half is ignored, not an error):
Config.Compat.Systems.inventory.custom = {
    OpenStash = function(...) ... end, OpenShop = function(...) ... end,
    UseItem = function(...) ... end, ItemExists = function(...) ... end,
    GetInventoryItems = function(...) ... end, GetContainerFromSlot = function(...) ... end,
    GetItemCount = function(...) ... end, RemoveItem = function(...) ... end,
    RegisterStash = function(...) ... end, RegisterShop = function(...) ... end,
    RegisterHook = function(...) ... end,
}
```

**An incomplete `custom` table is rejected, never a silent partial
success** — the exact missing function name(s) print at startup and in
`/k9compat`, and that one system falls back to a safe "not working" state.
`/k9compat` (restricted to High Command, since it names every script your
server runs) reprints the detection summary and explains every rejected
candidate. Restarting a resource this pack cares about re-runs detection
automatically if `Config.Compat.redetectOnResourceRestart` is `true`
(default).

**For whoever maintains an adapter file** (`inventory.lua`, `target.lua`,
`framework.lua`, `dispatch.lua`, `ambulance.lua` in this same folder): the
one call every adapter makes is
`K9Compat.RegisterAdapter(system, resourceName, factory)`, where `factory`
is `function(realm) -> table | nil` (`realm` is `'client'` or `'server'`).
Return a table shaped for that realm, or `nil` to mean "skip me, try the
next candidate" — never crash. `core.lua` already confirms the named
resource is `'started'` before calling your factory, and wraps every
factory call in `pcall` (a throw is treated exactly like a `nil` return).

**Required methods per system/realm** (the single source of truth is
`K9Compat.RequiredMethods` in `core.lua` — if it and this section ever
disagree, the code wins):

| system | realm | required methods |
|---|---|---|
| `inventory` | `client` | `OpenStash`, `OpenShop`, `UseItem`, `ItemExists` |
| `inventory` | `server` | `GetInventoryItems`, `GetContainerFromSlot`, `GetItemCount`, `RemoveItem`, `RegisterStash`, `RegisterShop`, `RegisterHook`, `ItemExists` |
| `target` | `client` | `AddGlobalPlayer`, `AddGlobalVehicle`, `AddGlobalObject`, `AddModel`, `AddSphereZone`, `Remove`, `AddLocalEntity`, `RemoveLocalEntity` |
| `target` | `server` | *(none)* |
| `framework` | `client` | `GetPlayerData` |
| `framework` | `server` | `GetPlayer`, `GetPlayerByCitizenId`, `GetCitizenId`, `GetJob` |
| `dispatch` | `client` | *(none)* |
| `dispatch` | `server` | `Alert` |
| `ambulance` | `client` | *(none)* |
| `ambulance` | `server` | `IsDowned` |

Parameter shapes and return values for each method are **not** defined by
this layer — `core.lua` is generic plumbing that only knows method names.
Match the calling convention of the reference resource for that system
(`ox_inventory`, `ox_target`, `qbx_core`) so every adapter stays
interchangeable.

**`AddLocalEntity`/`RemoveLocalEntity` (added after the fact — read this
before adding a ninth):** `client/equipmentshop.lua`'s shop-attendant ped
called `exports.ox_target:addLocalEntity`/`removeLocalEntity` directly for
two release cycles because that feature was built *after* this table was
first written, and nothing forced a re-check of the contract against every
call site actually being made. A required-method table does not get told
about a new call site on its own — the only defence is auditing call sites
against it deliberately, the same discipline this resource's own SQL
migration history already learned the hard way (migrations 0010/0011 landing
without a corresponding safety-script/database-layer update). If you add a
new third-party call anywhere in this resource, check it against this table
first, in both directions: does the method you need already exist here, and
does calling the third party directly instead mean this table is now
incomplete for someone else's adapter.

`AddLocalEntity(entity, options)` targets one specific, already-spawned
local (non-networked) entity handle — as opposed to `AddModel`, which
targets *every* entity of a given model. `RemoveLocalEntity(handle)` takes
exactly what `AddLocalEntity` returned and removes every option this
resource itself registered for that entity (a full teardown, never a
partial one — no real call site needs partial removal, so no adapter here
exposes it). Confirmed real per-adapter: `ox_target` (own export), `qb-target`
(`AddTargetEntity`/`RemoveTargetEntity`, keyed by the raw entity handle for a
non-networked entity), `sleepless_interact` (own export, byte-identical
shape to ox_target's). See `shared/compat/target.lua`'s own per-factory
comments for exactly what was confirmed and against what source — an
adapter that cannot get a confirmed answer returns `nil` from its factory
entirely rather than guessing, per this whole layer's research discipline.

**Resolution order (highest priority first):** `custom` (if it verifies) →
`override` (if the named resource is started and verifies) → `.candidates`
walked in array order, only when both `Config.Features.ResourceAutoDetect`
and `Config.Compat.autoDetect` are `true` → the no-op stub (every required
method exists, returns `nil`, logged once).

`K9Compat.Get(system)` never returns `nil`, and every method on it is
already `pcall`-safe — a throwing underlying resource yields `nil` back to
your call instead of propagating an error, logged once per (system,
resource, method).

**Security note:** none of this (`RegisterAdapter`, `Get`, `Which`,
`Report`, `Redetect`) is ever consulted by any rank, certification,
ownership, or XP check anywhere in this resource. If an adapter is tempted
to let a detected resource's answer influence an authorization decision,
that belongs in the file that owns the authorization check, not here.

---

## 22. Config rationale (moved out of `config.lua`)

`config.lua` is what the server owner opens to change a setting. It was 79%
comment -- 4,331 lines of it -- and most of that was not "what this setting
does" but "here is the full history of how we arrived at this number,
including the two times we got it wrong". Both kinds are worth keeping; only
one of them belongs between an owner and the switch they came to flip.

So the split is by AUDIENCE, not by length:

- **Stays in `config.lua`:** what the setting does, what a sane range is, and
  anything that will break if you change it. Every warning stays next to the
  value it warns about -- moving those would make the file shorter and the
  resource more fragile.
- **Moves here:** why the value is what it is, what was tried before, which
  audit found which problem, and the arithmetic behind a tuned number. A
  reader who wants that comes looking; an owner flipping a switch does not.

Each entry below names the `config.lua` setting it belongs to, so the two can
be read together. `tests/featureflagexistence_spec.lua` keeps `config.lua`'s
own index honest; nothing automatically checks the prose here, so if you
change a value, change the reasoning here too.

---

### `Config.Tracking.ScentVision.palette`

One fixed, curated swatch per `maxVisibleTrails` slot, rather than a hash into
an arbitrarily large colour space. Chosen for maximum hue and lightness
separation at a glance -- NOT a rigorous colour-vision-deficiency-optimised
set, which would need its own pass if that guarantee is ever wanted.

Colour is assigned DETERMINISTICALLY from the trail owner's own durable
citizenid (a stable hash into this array), not from a per-observer
first-come slot the way it originally was. The owner asked for this directly:
"hold a colour stable... the same person is the same colour... for every
handler looking." It is stronger than the old behaviour in that the same
person is now the same colour to every observer and across sessions, and
weaker in one: two people can hash to the same slot, where first-come
assignment guaranteed distinctness among however many trails were visible at
once. That trade was the point of the request.

### Keybind defaults, and the collision that shipped

`Config.Tracking.ScentVision.keybind` defaults to `'PERIOD'` (the full stop).
It was `'Z'` until the rework pass found that ox_lib's own radial menu -- the
menu every K9 action lives in -- defaults to Z, so opening the menu toggled
scent vision; tests/keybindcollisions_spec.lua now also checks defaults against
keys ox_lib and ox_target own. Before that it was briefly `'B'`. A first
pass shipped `'B'` without noticing that the bite-and-hold toggle further down
the same file also defaults to `'B'` -- a real, ship-blocking collision found
while wiring the tablet's Commands page.

The reason the file's own header claimed every default had been checked, and
was still wrong, is worth remembering: that check only ever looked at LITERAL
keys typed directly into a `RegisterKeyMapping(...)` call, which are
grep-visible. A config-driven default like this one is not. A config value has
to be RESOLVED, not grepped, to know what key it actually is.

Every `RegisterKeyMapping` default across the resource was then re-checked by
reading its resolved value rather than its call site.

### `Config.ScentVision` -- which edits need a restart, and which do not

Server-side, every field here is read fresh at the point of use rather than
captured once at load, so an edit takes effect on the very next capture pass
or query with no restart. Non-positive millisecond and metre values are never
read as "forever" or "unlimited" -- they are clamped to a safe built-in
default with a loud one-time warning naming the bad field, the same discipline
applied everywhere a threshold is read from an operator-editable field.

**The client-side exception, disclosed.** `pollIntervalMs`,
`fadeStartFraction`, `fadeEnabled` and the 45,000 ms dot-lifetime fallback are
resolved ONCE at the client file's load time, into locals. That does not
contradict the "live, no restart" claim in practice today, because this
codebase has no mechanism anywhere to push a live config value to an
already-connected client -- every client loads its own copy of the shared
script once, at its own resource start. So a client-side value already
requires a reconnect or a resource restart for any edit to reach it,
identically to every other client-only field (see `server/runtimecontrol.lua`'s
`tier = 'clientonly'` classification).

It is written down here so it stops being an implicit assumption the moment
someone adds live client-config push.

**`mode` is the same shape for STARTING, and the one exception for STOPPING.**
Flipping `'keybind'` to `'always'` does not retroactively start rendering for
a player already connected. But `getScentVisionPoints` echoes the server's
live-resolved `mode` (and an outright feature-off) on every poll response
already in flight, and the client treats either as an immediate,
unconditional stop -- never gated behind its own copy of `mode`. So a
currently-rendering player's screen always clears the moment the server says
to, restart or not. The asymmetry is deliberate: failing to start is a
cosmetic delay, failing to stop is a feature that will not switch off.

### `Config.XPTiers` -- the K9 ladder's thresholds and its scent-range bonus

**A bonus that was numerically dead from the day it shipped.**
`scentRangeMultiplier` replaced an absolute `scentRange` field, and the unit
had to change with it. The old values (5.0/6.5/8.0/10.0) were applied as a
`math.max` FLOOR against each track type's own `maxRange` -- and every
`maxRange` defaults to 40.0. Even the Elite tier's 10.0 could never exceed
40.0, so the floor could never raise anything, for any tier. "Scent range
grows with XP" did nothing at all, silently, for as long as it existed. It is
now a multiplier over each type's own `maxRange`, so it scales with whatever
that type is tuned to instead of fighting an absolute ceiling. Base tier is
1.00, so a base-tier K9 is byte-identical to the old behaviour.

**Thresholds retuned 2026-08-25**, from 500/1500/3500, on measured extraction
rates rather than feel. The old top tier was reachable in about 49 minutes of
nonstop optimal play once the combat awards shipped, and roughly 2.3 hours
using only what was closest to shippable -- an evening, not the weeks of duty
the progression is meant to represent. The new numbers keep the old
proportions (14% / 44% / 100% of top); at a realistic ~500 XP/hr, Elite is
about 18 hours total, or 2 to 2.5 weeks at an hour a day.

**The worst-case farm ceiling, and how it was got wrong the first time.** The
figure that used to sit in the config was 4,320 XP/hr, and it was wrong
because it reasoned about the combat awards in isolation. Each of the four XP
mechanics had its own independent mint cooldown and nobody had ever summed
them:

| mechanic | cooldown / award | per hour |
|---|---|---|
| bite-hold | 60s / 20 XP | 1,200 |
| takedown | 60s / 30 XP | 1,800 |
| contraband | 60s / 25 XP | 1,500 |
| track resolved | 30s / 10 XP | 1,200 |

Round-robining all four came to 5,700 XP/hr, putting Elite at about 1h35m --
under the "over 2 hours" floor these tiers were retuned to guarantee. Worse,
none of it required real police work: an ambient, non-wanted pedestrian
qualified for both combat awards.

Closed by a shared cross-mechanic mint budget in `AwardXP` -- a per-citizenid
token bucket of 3,600 XP per rolling hour -- plus
`Config.XP.mintXpForNpcCombatTargets` defaulting off. The four per-mechanic
cooldowns still decide WHICH mechanic may mint; the budget caps the TOTAL.
Real ceiling is 3,600 XP/hr: Trained ~18m, Veteran ~1h04m, Elite ~2h27m,
clearing the floor with about 27 minutes to spare.

Deliberately NOT the order-of-magnitude raise floated earlier. That figure
was anchored to a ~9,000 XP/hr contraband farm that is now closed; reapplying
it against the corrected ceiling would overshoot.

### `Config.Permissions.allowHighCommandSelfGrant`

Whether a high-command officer may grant a permission to themselves. Ships
`true`, on the owner's decision -- his own words: "High command can grant
anything they want to themselves -- xp promotions permissions etc."

**Why it exists at all.** It started as a fix for a genuine day-one deadlock
on the most common topology there is: a server with exactly ONE high-command
officer, on day one, before anyone else is promoted. With self-grant blocked,
nobody could ever grant that officer `feature.AdminAuditCommands` or any
other RequireGrant entry -- permanently locking the tablet's entire Audit
tab, with no way out that did not involve promoting a second officer first.

**What changed.** The original fix covered `feature.<Name>` only. The four
named capabilities and `block.<Name>` were deliberately left out, on the
reasoning that a high-command officer already bypasses those checks through
`IsHighCommand` regardless of any grant, so self-granting them fixed no
deadlock. That reasoning still holds -- it is simply no longer the deciding
factor, because the owner asked for self-service across the board as a matter
of what his server should allow rather than as a bug fix. The flag now governs
every namespace `server/permissions.lua` validates, and
`Config.HighCommand.allowSelfGrant` was flipped to match, for the same reason:
the decision applies uniformly, not per-mechanism.

**What it cannot do.** It only ever changes what an ALREADY-VERIFIED
high-command officer may do to their own citizenid -- never who counts as
high command. `GrantPermission` re-verifies `IsHighCommand` server-side on
every call, from the caller's own live job, never from a client claim.

Every self-grant is audited and distinguishable from an ordinary one:
`LogAuditInvocation` prints an explicit `self=true/false` field on every
grant line, naming the same citizenid as both granter and recipient whenever
it fires. Self-service was the owner's decision; invisible self-service is not
something this resource ships quietly.

### `Config.Combat` -- why bite/takedown/dragging shipped when they did

All three combat mechanics were built before they were switched on, and the
config carried a long record of what was blocking each one. That record is
spent: every blocker named in it was resolved, and all three ship `true`.

The order was deliberate. Shipping the code gated off was never the same
decision as flipping the flag on a live server -- each mechanic got its own
go/no-go (a balance review, and for bite-and-hold an animation preview) after
the implementation landed, and the flags flipped only once
`server/combat.lua` had been through a red-team trust-boundary pass.

One correction worth preserving, because the spec was wrong and a future
editor will otherwise re-derive it: `DEVELOPER_REFERENCE.md` §12.3 assumed
the handler-down defense could reuse an attacker identity from
`relayDamageEvent`. That event is deliberately PAYLOAD-LESS -- there is no
attacker field to reuse. The feature therefore carried its own explicitly
low-trust hint channel, with no server-authoritative consequence depending on
that hint; the K9's confirmation was re-validated from scratch by
`ValidateCombatRequest`. (The handler-down defense itself was removed on
2026-09-02 at the owner's request; the lesson about that event's shape
outlives it.)

### `Config.HandlerXPTiers` -- the reachability gap, and how it closed

For a while the top handler rank was genuinely unreachable for most players,
and the config said so in a paragraph headed "STILL A REAL GAP, DISCLOSED
RATHER THAN PAPERED OVER". A handler who never personally certified anyone
new was hard-capped at Senior Handler: tenure alone tops out at a lifetime
155 XP, and Master sits at 500. Lowering thresholds could not fix it, because
the thresholds were not the problem -- only two of six award actions were
wired, and neither was repeatable, solo and hours-based the way the K9
ladder's search/track/bite/takedown mix is.

That closed when `handlerTreatK9` and `handlerKennelDeploy` were wired with
their own per-actor mint cooldowns. A handler who never certifies anyone is
no longer capped.

**Recomputed time to Master (500 XP)** for exactly that handler, both the
theoretical ceiling (to prove it is not an afternoon farm) and a realistic
pace (to prove it is not a wall):

- *With a normal partnership* -- the 155 XP tenure trickle arrives over 30
  real days at zero effort beyond staying partnered, so 345 XP must come from
  treating and deploying, capped at a combined 32 XP/hr ceiling: **10.78
  hours** of continuous, never-missed action. That means an injured K9 to
  treat every 30 minutes and a kennel to redeploy every 60, without a single
  miss, for nearly eleven straight hours. Not a single sitting.
- *With no partnership at all* -- the worst case, all 500 XP from those two
  actions: **15.6 hours** theoretical ceiling.
- *Realistic pace*, which is the number that actually matters. A handler
  organically treats a genuinely injured K9 a handful of times a shift, not
  once every thirty minutes on the dot, and redeploys a kennel roughly once
  per session (its natural cadence -- a second deploy is blocked while the
  first object exists, and an ordinary logout clears it). A representative
  session of ~3 treats and 1 deploy is 44 XP, so the 345 remainder lands in
  roughly **8 sessions** -- one to a few weeks of regular duty. The same
  order of magnitude as the certifying-handler estimate.

**Thresholds (0/50/150/500) were left unchanged**, deliberately: the
arithmetic puts them in the "reachable in weeks, not an afternoon and not a
lifetime" band already. Wiring the two awards was what closed the gap, not
retuning. A future balance pass may want to revisit them now that a genuine
hours-of-duty mechanic exists -- an optional balance decision, not an open
correctness gap.

### `Config.HandlerXP`

What each handler action pays. `Config.XP` pays the K9 for K9-mechanical
actions; this pays the person, into a separate `k9_progression.handler_xp`
total walked against `Config.HandlerXPTiers`.

**Why each award is safe to pay for.** Every one is something this codebase
can already observe server-side -- none is an invented event.

- `handlerCertifyK9` -- paid at a NEW certification, not a renewal. This is
  the highest single award and was this table's worst farm loop: a
  revoke-then-regrant cycle is an ordinary supported lifecycle, and with
  `Config.AllowSelfCertification` true by default an eligible certifier can
  run it against THEMSELVES with no accomplice. What makes it safe is
  `CertifyXpMintCooldown` -- a dedicated per-(granter, target) MINT cooldown
  of 24 real hours on the AWARD, never on the grant/revoke action itself,
  which always succeeds regardless. A genuinely new target pays immediately;
  the same pair cannot pay again for a day.
- `handlerTreatK9` -- paid to the USING player, never the K9 being healed,
  and only on a genuine restore rather than a no-op top-off of a healthy dog.
  Bounded by the per-TARGET `MedkitCooldown` and by a dedicated per-ACTOR
  mint cooldown (`HandlerTreatXpMintCooldown`, 30 real minutes,
  citizenid-keyed, survives disconnect/reconnect), so a handler roaming
  between several simultaneously injured K9s is still capped at 24 XP/hr.
- `handlerKennelDeploy` -- paid at a CONFIRMED placement only, never the
  earlier request step that can still fail. Bounded by `DeployCooldown` and
  by `HandlerKennelDeployXpMintCooldown` (60 real minutes, citizenid-keyed),
  which closes the loop where a scripted relog would otherwise force a fresh
  deploy and a fresh mint on demand. 8 XP/hr.
- `handlerPartnershipTenure{1,7,30}Day` -- paid by the same milestone check
  `server/tenure.lua` already runs for the K9 side, so it inherits that
  mechanism's one-time-per-partnership CAS guard and same-pair-reform seeding
  for free. No new anti-farm needed.

**One award deliberately NOT moved here.** "Present for a successful
search/track" stays where it is: `server/search.lua`'s `coopSearchBonus` pays
a present, Trained+ partner through the original shared `xp` column. Routing
an already-shipped, already-tested award into this separate total was
considered and rejected. It is one of only two role-agnostic exceptions the
design leaves alone -- the other being `/k9givexp`'s `AwardXPDirect`.

**The budget everything shares.** Every award mints through `AwardHandlerXP`,
which reuses rather than duplicates the existing per-(citizenid, actionKey)
500 ms rate floor and the shared cross-mechanic mint budget: 3,600 XP per
rolling hour PER CITIZENID, shared with `Config.XP`. A citizenid farming both
totals at once still mints 3,600 XP/hr combined, never 3,600 of each.

### `Config.Wellbeing.restSources`

The prop names a K9 must be near to rest. Detection has always been real --
the scan, the radius check and the server-side position resolution all work.
What took the work was establishing which prop names actually EXIST in the
game, because a name that does not exist fails silently: the K9 simply never
rests near it, and nothing says why.

**How each name was established.** `prop_dog_cage_01` (hash 379820688) is
confirmed independently, in two sources, with a rendered screenshot in a
vanilla-prop database. `prop_bench_04` and `prop_couch_01` are one-source
confirmations -- present in a community prop list alongside sibling variants,
picked as the least location-suffixed of each family, but not corroborated by
the second source, which could only be partially read. Treat them as a lower
confidence tier than the cage, not as equals.

`prop_dog_cage_02` exists too and is deliberately NOT listed, for the same
reason `Config.DeployableKennel.fallbackPropModel` ('prop_tennis_ball') is
not: that model collides with the fetch ball and the fallback vest, so
listing it would let an unrelated dropped ball silently grant a rest bonus to
any K9 standing near it.

**`water_bowl`, and why a name that looks plausible is worth doubting.** It
shipped in this list for a long time and does not exist. The tell was a
pattern, not a hunch: every real bowl name either source produced carries a
`prop_` prefix (or a DLC prefix plus a `prop_`-style segment), and
`water_bowl` has neither. Neither source contained any "bed", dog "bowl",
"kennel", "doghouse", "trough", "food_bowl" or "water_bowl" match of any
kind -- only `prop_bowl_crisps` (a snack bowl) and two unidentified
story-mission bowls. It never matched anything, so removing it changed
nothing for any existing server. It has been replaced by three real dog-bowl
models (`m25_1_prop_m51_dog_bowl_full`/`_empty`, `m25_2_int_01_dog_bowl`)
that the same check turned up.

**A tooling note for anyone re-checking this.** Every dedicated GTA/FiveM
prop database was blocked outright by the sandbox's network egress policy
during the audit -- docs.fivem.net, gtahash.ru, forge.plebmasters.de,
vespura.com, gta-objects.xyz, forum.cfx.re and the rest. Two sources were
reachable: DurtyFree's `ObjectList.ini` (a direct dump of the game's own
object data, 21,631 entries, of which only the first ~4,637 loaded, so every
negative from it is partial rather than conclusive) and a community-compiled
gist (~3,000 entries, also truncated). That is a tooling gap to report if a
live re-check is ever needed, not a shortcut taken here.

### `Config.Wellbeing.speedPenaltyMultiplier`

Raised from 0.85 to 0.90 during a review that looked at the speed penalties
TOGETHER rather than one at a time. At the time three of them multiplied --
injury 0.7 x fatigue 0.85 x mood 0.9 = 0.535 -- which is the ordinary
aftermath of one bad gunfight, and at those values an Elite K9 with its 1.15x
tier bonus netted 0.615x: slower than a healthy Recruit. Three independently
reviewed "mild" penalties had compounded into half speed because nobody
reviewed them together.

Only fatigue survives -- the injury and mood systems were removed at the
owner's request on 2026-09-02 -- so there is nothing left to compound with,
and this value is now the whole penalty rather than one factor of three.

### `Config.HandlerXPTiers`

**Why a separate ladder rather than a second reading of `Config.XPTiers`.**
Every effect on the K9 ladder (`speedMultiplier`, `scentRangeMultiplier`,
`medkitCooldownMultiplier`) acts on a K9's own ped and is meaningless applied
to a human. Sharing one ladder would also mean a K9's own combat and search
grinding silently unlocked handler perks, and a handler's certifying and
treating silently unlocked K9 speed and scent -- for the same citizenid
across two unrelated skill tracks. So it is its own ladder, fed by its own
`Config.HandlerXP.awards`, walked the identical way `ResolveTier` already
walks `Config.XPTiers` (ascending, first entry must be `xp = 0`).

Persisted as `k9_progression.handler_xp` -- a second column on the SAME row
the K9 total lives on, not a second table. One citizenid, one row, two
independent totals, so a person who is sometimes the dog and sometimes the
handler keeps two separate standings.

**The dead-field audit, and what happened to each one.** An audit found three
tier effect fields genuinely unread, and required each to be wired or
removed -- "known and disclosed" was not accepted as a third state.

- `medkitTreatCooldownMultiplier` -- WIRED. `GetHandlerXPTierMedkitCooldownMs`
  is consulted by `server/medkit.lua`, keyed on the USING player's citizenid,
  chained on top of the TARGET K9's own `medkitCooldownMultiplier` rather
  than replacing it, so a high-tier handler treating a high-tier K9 gets both.
- `kennelDeployCooldownMultiplier` -- WIRED.
  `GetHandlerXPTierKennelDeployCooldownMs` is consulted by
  `server/kennel.lua`, keyed on the deploying handler's own citizenid.
- `leashRangeMultiplier` -- REMOVED rather than left half-wired.
  `Config.LeashMaxDistance` is read as a raw shared constant in at least four
  places across three files, with no per-citizenid channel anywhere in that
  chain. Wiring a per-handler bonus properly would mean threading a new value
  through the leash consent handshake AND updating the elastic-constraint
  math in `client/movement.lua` to match -- an attach that succeeds at a
  rank-widened range and is then immediately pulled back by a client unaware
  of the widening is exactly the half-wire this resource forbids -- plus
  deciding which of the two leashed parties' rank applies and whether a
  mid-session rank-up needs a live re-push. Real design work; do it in full
  if it is ever reintroduced.

**Feedback-loop check.** Both wired cooldown multipliers shorten an action
that `Config.HandlerXP.awards` also pays for, so in principle the ladder
could get faster to climb the higher you climb it. The dedicated per-actor
mint cooldowns are what stop that: they are sized against the rank-reduced
worst case (31,500 ms combined medkit floor, 3,000 ms kennel-deploy floor),
never derived from `MedkitCooldown`/`DeployCooldown` themselves.
`tests/medkit_spec.lua` and `tests/kennel_spec.lua` each carry a source-audit
test that fails outright if an award is ever wired without its companion mint
cooldown.

**Why the thresholds were rescaled (2026-08-26).** The owner's audit was
blunt: "the handler rank ladder cannot be reached in a human lifetime." The
real problem was worse than slow. Of the six award keys, only certifying and
the three tenure milestones paid at the time. The tenure milestones are a
HARD LIFETIME CAP of 15 + 40 + 100 = 155 XP per partnership -- wall-clock,
not hours-played, so idling a partnership for a year pays exactly what 30
days pays. A handler who never personally certifies anyone new -- most
handlers, most of the time -- could therefore earn at most 155 XP EVER, and
under the old thresholds (750/2500/6000) could not reach even the first rank,
at any amount of played time. The "3.2 years to the top" figure the audit
started from was only right for the other case: a handler certifying ~2 new
candidates a week, at 100 XP/week, needs about 58 weeks to the old Master
threshold, and few servers sustain that pace indefinitely.

That gap is closed. `handlerTreatK9` (12 XP, 30-minute per-actor mint
cooldown) and `handlerKennelDeploy` (8 XP, 60-minute) both pay now, giving
32 XP/hr combined -- small next to a K9's own 500+ XP/hr realistic pace,
because this is a support action rather than the main gameplay loop, but
repeatable, solo, and independent of certifying anyone or holding a
partnership. A handler who never certifies anyone is no longer capped.

The shared 3,600 XP/hr mint budget is not the binding constraint in either
direction and does not shape these numbers: certifying dozens of distinct new
people inside an hour is not realistic, and the largest single tenure
milestone is 100 XP. Re-derive the thresholds from the real award values,
the real cooldowns and the real budget before ever retuning them again --
do not carry this conclusion forward without re-checking its inputs.

### `Config.Features.HandlerXPProgression`

Handler XP is a SEPARATE accumulated total from the K9's own XP: its own
`handler_xp` column on the existing `k9_progression` row, its own
`Config.HandlerXPTiers` ladder, its own `Config.HandlerXP.awards` table. It
pays for what a HUMAN HANDLER does, where `XPProgression` pays for what the
K9 does (search/track/bite/takedown).

**Why it shipped `false` for a while, and why it does not any more.** The flag
was held off first because the code did not exist, then -- once
`AwardHandlerXP`/`GetHandlerXPTier` landed -- because two of the six award
keys could be farmed. `handlerTreatK9` and `handlerKennelDeploy` had no
per-actor MINT cooldown: `MedkitCooldown` is keyed by the TARGET K9's
citizenid rather than the using handler's, and `DeployCooldown` throttles the
action rather than the mint. With `Config.DeployableKennel.deployCooldownMs`
at its 5,000 ms default, a solo handler could mint 8 XP every 5 seconds --
5,760 XP/hr, enough to exhaust the entire shared 3,600 XP/hr budget in under
40 minutes and crowd out every legitimate award.

A correction worth keeping, because the original claim was wrong in a way
that mattered: this section used to say `handlerCertifyK9` was "already gated
by that file's own per-granter `IsCertifyActionOnCooldown` check". It was
not. That check is a flat 1,500 ms fat-finger guard on the grant/revoke
ACTION, not a mint cooldown -- and with `Config.AllowSelfCertification` true
by default, an eligible certifier could `/k9certify <self>` then
`/k9decertify <self>` on repeat at roughly 3 seconds a cycle, for 60,000
XP/hr gross. The fix was a dedicated per-(granter, target)
`CertifyXpMintCooldown` of 24 real hours on the AWARD itself (see
`server/certifications/`, search for "FALSIFIED CLAIM").

**How the two farmable keys were closed.** `server/medkit.lua` declares
`HandlerTreatXpMintCooldown` -- per-ACTOR, citizenid-keyed, 30 real minutes,
entirely separate from `MedkitCooldown` -- and awards `handlerTreatK9` only
through it, and only for a genuine heal rather than a no-op top-off of an
already-healthy K9. `server/kennel.lua` declares
`HandlerKennelDeployXpMintCooldown` -- per-actor, citizenid-keyed, 60 real
minutes -- and awards `handlerKennelDeploy` only at a confirmed new
placement. Both survive the actor's own disconnect/reconnect (citizenid-keyed,
swept, never cleared on `playerDropped`), which closes the relog loop that
would otherwise force a fresh deploy and a fresh mint on demand. Result: 24
XP/hr and 8 XP/hr per actor respectively, 32 combined -- nowhere near the
shared budget, and nowhere near fast enough to reach Master (500 XP) in an
afternoon.

The three `handlerPartnershipTenure{1,7,30}Day` milestones were never part of
this problem: they are one-time-per-partnership-row and never repeat, under
the same CAS guard the K9-side milestones use, and breaking a partnership
LOSES progress rather than re-minting it.

**Why it now ships `true` (2026-08-27).** While it shipped `false`, the entire
handler rank ladder was DEAD. `AwardHandlerXP` hard-returns on this flag
before doing anything and is the only function anywhere that mints Handler
XP, so all six award keys fired, passed their cooldowns, called it, and
minted exactly zero -- while the tablet advertised the ranks. A rank a player
can see and can never earn is worse than no rank at all, and an owner is not
going to find line 481 of a config file to switch it on.

## Keeping this file honest

This resource is checked before every change ships: every `.lua` file must
parse, `luacheck` must report zero warnings, and the full spec suite under
`tests/` must pass (see §20 for how to run it yourself). That check is
mechanical and says nothing about whether this document still matches the
code — the two can drift independently. If you find a place where this
file disagrees with `config.lua` or the actual `.lua` source, the code is
correct and this file is stale; fix the sentence, don't work around it.
`KNOWN_ISSUES.md` is where an unresolved discrepancy like that belongs if
you don't have time to fix it on the spot.
