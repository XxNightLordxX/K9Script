> **HISTORICAL RECORD — NOT CURRENT GUIDANCE.**
>
> This document is the plan for merging the command surface into families. The work it describes has been
> built, and in places has since been changed or removed. It is kept because
> it explains WHY things are shaped the way they are, which the code alone
> cannot say — but it does not describe how the resource works today, and it
> is not a specification anyone should implement from.
>
> For how the resource actually works now, see `README.md` (setup and
> features), `DEVELOPER_REFERENCE.md` (the code), and `DIAGNOSTIC_CHECKS.md`
> (the `/k9debug` report). Archived 2026-09-02.

---

# Command Consolidation Spec

Owner's request, restated as the hard constraint: fewer commands to remember,
**identical permission/certification requirements**. Every design decision
below is judged against "does this widen who can do what" first, "is it
simpler for the owner" second.

Survey basis: 55 `RegisterCommand` calls read directly from `server/*.lua` +
`client/*.lua` (matching the two drift-guard specs' own file lists), plus the
actual gate logic inside each command handler / the function it calls. Where
I quote a gate below I read the real `if not X(source) then ... end` line,
not a comment describing one.

---

## 0. Verdict up front

All 8 proposed families are workable. None gets dropped. Two need
non-obvious handling:

- **lineup** — the three members do NOT share a gate at all (by design,
  correctly). This is the single riskiest merge in the batch if done
  carelessly. See §1.
- **kennel** — both members are pinned to their literal names by
  `RegisterKeyMapping` (rebindable keybinds). This isn't a blocker, but it
  changes what "merge" should mean here. See §1.

One pre-existing bug, unrelated to any specific family but naturally fixed
as part of the online/offline merge work: the tablet's "Decertify" button
is wired to a command path that structurally cannot succeed against an
online target. See §6.

---

## 1. Per-family gate tabulation (THE THING THAT MATTERS MOST)

For every family, the table below is the real gate, read from the real
handler. "Shared" means literally the same gate function call; "OWN" means
that member's gate is different in kind, not just threshold, from its
siblings.

### audit (5 -> 1) — `server/admin.lua`
| command | gate |
|---|---|
| k9auditcert | `IsAuthorizedAdmin(source)` |
| k9auditpartner | `IsAuthorizedAdmin(source)` |
| k9auditsearch | `IsAuthorizedAdmin(source)` |
| k9auditxp | `IsAuthorizedAdmin(source)` |
| k9auditdept | `IsAuthorizedAdmin(source)` |

**Identical gate on all 5**, plus the identical shared `AuditCooldown`
instance. Safe to merge with ONE top-of-handler gate check, no
per-subcommand branching needed for authorization (only for argument shape).
Lowest-risk family in the batch.

### online/offline certification pairs (10 -> 5) — `server/certifications/`
| pair | online gate | offline gate |
|---|---|---|
| k9certify / k9certifyoffline | `IsEligibleCertifier` | `IsEligibleCertifier` |
| k9decertify / k9decertifyoffline | `IsEligibleCertifier` | `IsEligibleCertifier` |
| k9settier / k9settieroffline | `IsEligibleCertifier` | `IsEligibleCertifier` |
| k9recertify / k9recertifyoffline | `IsEligibleCertifier` | `IsEligibleCertifier` |
| k9unspecialize / k9unspecializeoffline | `IsEligibleCertifier` | `IsEligibleCertifier` |

Explicitly checked the thing the brief asked me to check: **the offline
variants do NOT have a higher permission bar.** All 11 grant/revoke/
tier/renew/specialization functions in this file (including plain
`k9specialize`, which has no offline counterpart) call the exact same
`IsEligibleCertifier(granterSrc)` and the exact same `IsCertifyActionOnCooldown`
budget. There is no widening risk from merging on the authorization axis —
the only real design work is argument resolution (§2).

What DOES differ, consistently, across all 5 pairs, and must survive the
merge: the **online function infers the target's department from their live
`PlayerData.job`**; the **offline function cannot do that (no live
PlayerData) and requires an explicit `job` argument instead**. Concretely:
- online: `k9certify <server id>`, `k9decertify <server id> [reason]`,
  `k9settier <server id> <tier>`, `k9recertify <server id>`,
  `k9unspecialize <server id> <specializationKey>`
- offline: `k9certifyoffline <citizenid> <job>`, `k9decertifyoffline
  <citizenid> <job> [reason]`, `k9settieroffline <citizenid> <job> <tier>`,
  `k9recertifyoffline <citizenid> <job>`, `k9unspecializeoffline <citizenid>
  <job> <specializationKey>`

So a merged command's argument list has a **different shape** depending on
which branch it resolves to, not just a different first argument. The usage
string must show both shapes (see §4).

### fetch (3 -> 1) — `client/fetch.lua`
| command | gate |
|---|---|
| k9throwfetchball | `HasK9Access()` (client courtesy check; `DenyK9UIAccess()` on failure) |
| k9dropfetchball | none — deliberately unconditional |
| k9recallfetchball | none — deliberately unconditional |

Real authorization for drop/recall lives server-side (`server/fetch.lua`'s
ownership check: only the actual thrower's `src` may recall/release), by
design, per that file's own comment ("must still be able to call it off").
This is a real, intentional "gate the start, never the stop" pattern, not
an oversight — preserve it exactly: only `throw` gets the `HasK9Access()`
pre-check in the merged dispatcher.

### lineup (3 -> 1) — `the removed scent-lineup server file`
| command | gate |
|---|---|
| k9lineup | `Config.Features.ScentLineup` + `HasK9Access(src)` + `CanUseScentLineup(src)` permission grant |
| k9lineuppick | **none** — only requires an active session (`Sessions[src]` truthy) |
| k9lineupcancel | **none** — only requires being conductor or participant in a live session |

This is the family the brief's warning is about. `k9lineup` (starting a
lineup) is a K9-handler action. `k9lineuppick`/`k9lineupcancel` are actions
performed by the **lineup participant** — frequently a civilian with zero K9
access, who is being asked to point someone out. If a merged command applied
`k9lineup`'s own gate (`HasK9Access`) as one top-level check before
dispatching to a subcommand, it would not widen access — it would **break
the feature outright** for the exact people who are supposed to use
`pick`/`cancel`. This is the concrete, worked example of "check the gate of
the specific subcommand invoked, never a single gate at the top."
Still worth merging — just: dispatch on the subcommand keyword FIRST, then
run that subcommand's own original gate (or lack thereof) unchanged, with
zero shared pre-check.

### training (3 -> 1) — `the removed training client file`
| command | gate |
|---|---|
| k9training on | `HasK9Access()` client courtesy check |
| k9training off | none — deliberately unconditional ("never gate the stop") |
| k9trainsearch | `trainingModeActive` (local client STATE, not a permission) |
| k9trainbite | `trainingModeActive` (same) |

Same "gate the start, not the stop" shape as fetch. `trainingModeActive` is
a precondition, not an authorization check — real server-side authorization
for the drill events lives in `the removed training server file` (re-checks
`HasK9Access(src)` + a per-person feature grant). Client-only merge, low
risk: worst case of a mistake here is a UX regression, not a privilege
escalation, because the server re-validates independently either way.

### permissions (2 -> 1) — `server/permissions.lua`
| command | gate |
|---|---|
| k9grantpermission | `Config.Features.PermissionGrants` + `IsHighCommand(source)` |
| k9revokepermission | `Config.Features.PermissionGrants` + `IsHighCommand(source)` |

Identical gate, identical cooldown (`PermissionActionCooldown`). Same
argument shape both ways (`<citizenid> <permission>`) — no argument-shape
asymmetry to design around, just an explicit `grant`/`revoke` verb since
there's no way to infer intent from argument shape or type the way the
online/offline pairs allow.

### dog record (2 -> 1) — `server/dogcharacter.lua`
| command | gate |
|---|---|
| k9setdog | `IsHighCommand(source)` |
| k9removedog | `IsHighCommand(source)` |

Identical gate. Bonus finding: this file's own `ResolveTargetCitizenId`
helper (line 300) is **already** the exact online/offline resolution
pattern §2 needs elsewhere: `tonumber(rawArg)` succeeds -> treat as a live
server id and resolve via `GetPlayer`; fails -> treat the raw string as a
citizenid directly. This is a live, shipped precedent for "numeric always
means server id, never a citizenid" — reuse this rule, don't reinvent one.

### kennel (2 -> 1) — `client/kennel.lua` + `client/keybinds.lua`
| command | gate |
|---|---|
| k9deploykennel | "put it back down" branch is unconditional (checked first); otherwise `CanShowK9UI()` |
| k9exitkennel | none — deliberately unconditional |

Same "gate the start, not the stop" shape again. The complication is
structural, not a permissions one: **`k9exitkennel` has a live
`RegisterKeyMapping('k9exitkennel', ...)` bound to it** (`client/keybinds.lua`
line ~406, default key `O`), and `k9deploykennel` is the radial menu's
literal target too. `RegisterKeyMapping` requires a real, independently
registered command under that exact name for FiveM's own rebinding UI to
work — a player who rebound their kennel-exit key would have that binding
silently stop working if `k9exitkennel` stopped being a real command.
This is fully compatible with the hidden-alias design in §3 (the alias IS
still a real `RegisterCommand` call, just unlisted) — but it means this
"merge" is better framed as **additive**: keep `k9deploykennel`/
`k9exitkennel` exactly as they are today (both keybind-critical), and add a
new `k9kennel <deploy|exit>` wrapper purely for discoverability, calling
the exact same `RequestDeployKennel()`/`ExitKennelRest()` globals the
existing commands already call. Don't try to make the keybind-bound names
into thin wrappers around a new canonical name — keep the dependency
direction the way it already is.

---

## 2. The online/offline merge — resolution rule

**Rule:** `tonumber(args[1])` succeeds -> the argument is a server id, call
the ONLINE function, unchanged, exactly as today. It fails -> the argument
is a citizenid string, call the OFFLINE function, unchanged, exactly as
today. This is not a new invention — it is `server/dogcharacter.lua`'s own
`ResolveTargetCitizenId` rule, already shipped and load-bearing elsewhere in
this same resource. No new helper function is even required: each of the 10
existing functions already does its own `tonumber(args[1])` (online) or
`type(args[1]) == 'string'` (offline) parsing internally — the merged
command only needs the ONE `tonumber()` branch to decide which existing
function to call, then forward the rest of `args` unchanged.

**On ambiguity** (a purely numeric string that is actually meant as a
citizenid): this codebase's own citizenid values come from qbx_core and are
alphanumeric in the shipped convention (not independently verified against
this exact qbx_core install — flagged the same way this codebase's own
`GetPlayerByCitizenId` call sites already flag that class of assumption).
A genuinely all-digit citizenid is the one case this rule cannot resolve
automatically. This is why §3's hidden aliases are not merely a transition
convenience: `/k9certifyoffline <digits-only-citizenid> <job>` stays live,
unlisted, forever, as the explicit escape hatch for exactly this case.

**Recycled server ids:** not a new problem this merge introduces. The
numeral is forwarded, unchanged, straight into the existing online function,
which already resolves it to a live `Player`/citizenid synchronously, in
the same tick, via `exports.qbx_core:GetPlayer(targetServerId)` — nothing
is ever cached or persisted keyed on the raw numeral, before or after this
change. If the numeral doesn't currently resolve to a connected player, the
online function's own existing "target must be online" refusal fires,
exactly as it does today when `/k9certify` is run against a disconnected id
— behavior unchanged, just reachable from one name instead of two.

**Argument-shape note (see §1 table):** because the offline branch needs an
explicit `job` argument the online branch infers instead, the merged
command's arg positions shift depending which branch was resolved. This
must be visible in the usage string (§4), not just in code comments.

**Permission bar:** identical both ways for all 5 pairs (§1) — nothing to
reconcile, no risk of widening.

---

## 3. Backward compatibility — hidden aliases

Proposal stands: keep every old name registered (`RegisterCommand` still
called, same handler body, now usually just forwarding into the new merged
dispatcher), but stop giving it a `chat:addSuggestion` entry
(`client/commandsuggestions.lua`) and stop listing it in
`html/tablet.js`'s `COMMAND_REFERENCE`. Old macros/keybinds/cheat-sheets
keep working; autocomplete clutter drops.

Both drift-guard specs currently do strict bidirectional set equality
(`tests/commandsuggestions_spec.lua`, `tests/commandreferenceregistry_spec.lua`)
— a real, registered command with no suggestion/reference entry is
currently a hard failure ("undocumented"/"unsuggested"). Both need a third
category added, and it must be a small explicit allowlist, not a wildcard:

- `HIDDEN_ALIAS_COMMANDS = { k9certifyoffline = true, k9decertifyoffline = true, k9settieroffline = true, k9recertifyoffline = true, k9unspecializeoffline = true, k9auditcert = true, k9auditpartner = true, k9auditsearch = true, k9auditxp = true, k9auditdept = true, k9throwfetchball = true, k9dropfetchball = true, k9recallfetchball = true, k9lineup = true, k9lineuppick = true, k9lineupcancel = true, k9trainsearch = true, k9trainbite = true, k9grantpermission = true, k9revokepermission = true, k9setdog = true, k9removedog = true }`
  (exact final membership depends on what each family's new canonical name
  ends up being — this list is illustrative of shape, not final; `k9training`,
  `k9deploykennel`/`k9exitkennel` are deliberately NOT in it per §1's kennel
  carve-out and because `k9training on/off` keeps its own name as the
  canonical one, only `k9trainsearch`/`k9trainbite` fold under it).
- In each spec, the "unsuggested"/"undocumented" loop skips any name present
  in this allowlist.
- **New test, both specs:** every name IN the allowlist must still be a real
  `RegisterCommand(...)` call somewhere — i.e. run the exact same "phantom"
  check against the allowlist itself. This is what stops a genuinely
  removed command from hiding in the allowlist forever instead of getting
  flagged: the allowlist can only ever excuse a name that's still live,
  never launder a truly dead one.
- The allowlist is a small, hand-maintained, committed-in-the-same-change
  list, exactly like `COMMAND_SUGGESTIONS`/`COMMAND_REFERENCE` themselves
  already are — consistent with this codebase's own established "hand-
  maintained table, drift-guarded, not derived" convention, not a new
  pattern.

---

## 4. Discoverability for a non-technical owner

**No-argument (or unrecognized-subcommand) behaviour:** print that
command's own usage string, using the exact convention already shipped in
`server/admin.lua`'s `k9auditsearch` handler:
```lua
if source == 0 then print('[John-K9] ' .. usage) else NotifyPlayer(source, usage, 'error') end
```
Apply this verbatim to every merged command's no-arg / bad-subcommand path.
Nothing new to invent.

**Usage-string format:** this codebase already has the exact "enumerate the
choices" shape in production — `admin.usage_auditsearch`: `"Usage:
/k9auditsearch <officer|plate|person|recent> [value] [limit]"`. Reuse it
verbatim for every merged family, e.g.:
- `/k9audit <cert|partner|search|xp|dept> ...`
- `/k9certify <server id>` (unchanged) — no enumeration needed, it's not a
  verb-family, see §2
- `/k9decertify <server id> [reason]  |  /k9decertify <citizenid> <job> [reason]`
  (both shapes shown — see §2's argument-shape note)
- `/k9fetch <throw|drop|recall>`
- `/k9lineup <start|pick <index>|cancel>`
- `/k9training <on|off|search|bite>`
- `/k9permission <grant|revoke> <citizenid> <permission>`
- `/k9dog <set|remove> <citizenid> [model]`

**Locale contract (three-way, per the brief):** every NEW canonical command
name needs a `tablet.cmdref_<name>_usage` / `_does` / `_needs` triple added
to all three of:
1. `html/tablet.js` — `DEFAULT_STRINGS`
2. `client/tablet.lua` — `TABLET_STRING_KEYS`
3. `locales/en.json` — the `tablet` group

`tests/tabletlocalization_spec.lua` only fails on a KEY-SET mismatch between
`DEFAULT_STRINGS` and `locales/en.json`'s `tablet` group — it does not fail
if a key is simply missing from BOTH, and `tests/commandreferenceregistry_spec.lua`
enforces `client/tablet.lua`'s `TABLET_STRING_KEYS` separately again. Adding
all three in the same commit that adds the new `RegisterCommand` call (same
discipline `COMMAND_SUGGESTIONS`'s own header already demands) is the only
thing that keeps this from silently rotting — there is no single check that
catches "forgot all three at once."

Existing hidden-alias commands (§3) reuse their OWN existing
`cmdref_<oldname>_*` keys unchanged — they still need a `_does`/`_usage` pair
for `client/commandsuggestions.lua`'s own `pendingLocale` lookups even
though they're no longer chat-suggested (that file's `RegisterSuggestion`
is simply never called for an aliased name at all once it's removed from
`COMMAND_SUGGESTIONS`, so no orphaned lookup — but the locale keys
themselves are harmless, inert leftovers, not something to delete).

---

## 5. Sequencing

Files an item touches are listed explicitly so a reviewer can see the blast
radius. Families touching any of `client/tablet.lua`, `server/tablet.lua`,
`html/tablet.js`, `client/wellbeing.lua`, `server/wellbeing.lua`,
`server/permissions.lua`, `server/certifications/`, `server/certtiers.lua`,
`server/progression.lua` are marked **LAST** and pushed to the end
regardless of their own risk profile, per instruction — other agents are
live in those files right now.

| # | Family | Files touched | Hot-file? | Notes |
|---|---|---|---|---|
| 1 | audit (5->1) | `server/admin.lua`, `client/commandsuggestions.lua`, `html/tablet.js`, `locales/en.json`, `tests/commandsuggestions_spec.lua`, `tests/commandreferenceregistry_spec.lua` | No | Uniform gate, no client dependency on old names. Safest first commit — also proves out the hidden-alias allowlist mechanism (§3) once, cheaply, before reusing it 7 more times. |
| 2 | dog record (2->1) | `server/dogcharacter.lua` + the same 4 shared support files as #1 | No | Uniform gate, ships the `ResolveTargetCitizenId`-style rule §2 leans on elsewhere. |
| 3 | fetch (3->1) | `client/fetch.lua` + shared support files | No | Client-only, server re-validates independently either way. |
| 4 | training (3->1) | `the removed training client file` + shared support files | No | Client-only, same reasoning as #3. |
| 5 | kennel (additive, not a replace) | `client/kennel.lua`, `client/keybinds.lua` (comment/doc only, no removal), + shared support files | No | Do this AFTER #3/#4 land cleanly once, since it's the one family whose "merge" shape is genuinely different (§1) — easier to get right once the pattern for the others is proven. |
| 6 | lineup (3->1) | `the removed scent-lineup server file` + shared support files | No | Highest in-family risk (§1's mismatched-gate warning) — sequence after #1-#5 so the hidden-alias + per-subcommand-gate pattern is already well-exercised before tackling the one family where getting it wrong breaks (not widens) access. |
| 7 | permissions (2->1) | `server/permissions.lua` + shared support files | **YES** (`server/permissions.lua`) | Uniform gate, low design risk — held back purely because the file is hot. |
| 8 | online/offline pairs (10->5) + the tablet:decertify fix (§6) | `server/certifications/`, `client/tablet.lua` + shared support files | **YES** (both) | Biggest win, and now also carries the decertify bugfix. Do this last, in its own commit(s) separate from the bugfix if possible, once `server/certifications/`/`client/tablet.lua` are free. |

Do #1-#6 as six separate small commits (one family each), landing the
hidden-alias allowlist mechanism in #1's commit and reusing it unchanged
afterward. #7 and #8 land only once the hot files are clear, in that order
(permissions first — smaller, uniform-gate change — then the certification
pairs, the largest and most valuable single item).

---

## 6. The dead "Decertify" button

Confirmed, and it's slightly different from "no server callback exists" —
worth being precise about what's actually broken:

- `html/tablet.js` calls `runMutation('tablet:decertify', { targetCitizenId, departmentKey }, ...)`
  and its own header comment (line ~305) documents this as working "for an
  ONLINE or OFFLINE target," the same as `tablet:certify`.
- `client/tablet.lua` DOES register `RegisterNUICallback('tablet:decertify', ...)`
  (line 2247) — so it's not literally unhandled. But instead of calling a
  `john-k9:server:tabletDecertify` `lib.callback` (the shape `tablet:certify`
  uses, via `john-k9:server:tabletCertify` and a real `GrantCertificationForTablet`
  wrapper in `server/certifications/`), it fires the OFFLINE-ONLY chat
  command directly: `SubmitAllowlistedCommand('k9decertifyoffline', { targetCitizenId, departmentKey })`.
- `RevokeCertificationOffline` (the function `k9decertifyoffline` calls)
  explicitly **refuses** when the target citizenid resolves to a currently
  connected player (`certifications.target_online_use_decertify_command`) —
  by design, for the online path's own proximity-check integrity (§1/§2).
- Net effect: clicking "Decertify" in the tablet against an ONLINE person
  always hits that refusal and does nothing, contradicting the tablet's own
  documented contract. There is no `GrantCertificationForTablet`-style
  `RevokeCertificationForTablet` wrapper, and no
  `john-k9:server:tabletDecertify` callback, anywhere in
  `server/certifications/`.

**Where this belongs:** bundled into sequencing item #8 (online/offline
pairs), not fixed separately or earlier. The exact resolution logic §2
specifies (numeric-vs-string -> online-vs-offline function) is precisely
the logic a real `RevokeCertificationForTablet` wrapper needs — build it
once, as part of that commit, mirroring `GrantCertificationForTablet`'s
existing shape, and swap `client/tablet.lua`'s `tablet:decertify` handler
from the `SubmitAllowlistedCommand` workaround to a direct
`john-k9:server:tabletDecertify` callback. Both files it touches
(`server/certifications/`, `client/tablet.lua`) are already the hot
files item #8 has to wait for anyway — no separate wait needed.

---

## 7. Watch, don't act yet

- **`k9eat`/`k9drink`** (`client/wellbeing.lua`) — a plausible small pair,
  but the file is hot (`server/wellbeing.lua`/`client/wellbeing.lua` are
  both on the excluded list) and the two actions are not variants of one
  verb the way e.g. throw/drop/recall are — low payoff for the disruption
  right now. Revisit once `wellbeing.lua` is quiet.
- **The 7 `john-k9:`-namespaced keybind commands** (vault, pursuitsprint,
  the 3 vision toggles, movement camera toggle, defense confirm) — all are
  `RegisterKeyMapping`-bound and essentially never typed by a player (they
  exist for rebinding, not chat entry). Merging keybind-only commands
  doesn't reduce the clutter the owner is actually complaining about (chat
  autocomplete / the tablet's command list) and adds the same
  keybind-pinning constraint §1 flags for kennel, for zero discoverability
  benefit. Leave alone.
