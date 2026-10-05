# Watchdog log

One line per recurring watchdog pass, newest last. The point of this file is
so the next pass knows what was already covered and does not re-derive it.

Passes before 2026-08-26 were recorded only as `Watchdog:` markers in commit
messages; they are reconstructed here from `git log --grep="Watchdog:"` so
the history is in one place. From now on, add a line here as part of the
pass itself.

| Date | Summary |
|---|---|
| 2026-08-23 | Pass #2 — found and closed 3 real Phase 2 gaps, no regressions |
| 2026-08-24 | Pass #5 — recovered interrupted-agent work, verified no regressions |
| 2026-08-24 | Pass #6 — one real finding: docs described a control that does not exist |
| 2026-08-24 | Registered cleared Phase 5 files, fixed two inverted/stale doc claims |
| 2026-08-25 | Clean; finished the documentation consolidation |
| 2026-08-26 | Corrected a wrong security claim in the manifest, closed three dangling citations |
| 2026-08-26 | First pass recorded in a file rather than only a commit marker; clean, one item honestly unverified |
| 2026-08-26 | Clean. 85 commits reviewed, 5 regression spot-checks pass, dependency status re-verified upstream, bark-audio gap confirmed closed. No findings. |
| 2026-08-27 | Watchdog's own checks all clean. The real findings this pass came from a separate 12-agent production-readiness audit running alongside it -- including two live bugs the watchdog's fixed checklist would never have caught. |
| 2026-08-27 (4th) | Clean on all five checklist items. 19 commits reviewed. The findings this pass again came from elsewhere -- fifteen audit agents run alongside -- including a wellbeing data-loss bug on restart and a vehicle/body-claim seam bug no single-file review could see. Dependency upstream status NOT re-verified: GitHub API 403 through this session's proxy. |
| 2026-08-27 (2nd) | Clean. 5 commits reviewed, all 5 spot-checks pass, dependencies and bark audio re-verified, no stale claims in KNOWN_ISSUES. The radial count trap flagged last pass bit again in a new form -- see detail. |
| 2026-08-27 (3rd, comment-truth pass) | Dedicated doc-vs-code sweep after commit `2f21165`. Found and fixed three real drifts: KNOWN_ISSUES.md/CHANGELOG.md still said SAR calls were solo-only and Master Handler was unreachable, both now false; two older planning docs (docs/history/FEATURE_STRUCTURE_SPEC.md, docs/history/OVERHAUL_PLAN.md) still presented the vision-cycle merge as current/pending when it shipped and was then reversed. See detail for the full list, including one item added from an unverified third-party claim that checked out. |
| 2026-08-31 | Clean on all five checks; 13 backlogged firings (Aug 28-31) covered by this one pass. 8 commits reviewed, all authored and gated this session. The rank-visibility finding left open by an earlier pass is now CLOSED BY CODE, not by editing the comment. Dependency status re-verified upstream and answered properly for the first time: all three alive, none archived. |
| 2026-08-31 (2nd) | NOT a watchdog pass -- a directed work session, logged here because it changed a SHIPPED DEFAULT the next pass must know about: `Config.Database.enabled` now ships **false** (drag-and-drop, no SQL import). Memory-only is now the ordinary path, not a fault. Also corrected a false doc claim in four places (memory mode DOES keep a capped audit trail) and closed the KNOWN_ISSUES command-drift item. |
| 2026-08-31 (3rd) | **THIS ROUTINE'S OWN PROMPT WAS REWRITTEN.** It referenced a `SPEC.md` that has not existed for many passes (twice), asked about a bark-audio gap closed long ago, and did not know the database now ships OFF -- so it would have read a healthy server as broken. Checklist also rebalanced toward doc-vs-code drift, which is where every real finding has come from lately. |
| 2026-08-31 (4th) | Six real doc-vs-code drifts found and fixed, all by extracting every file path cited in prose/comments and testing whether it resolves. Worst: `client/tablet.lua` named a NONEXISTENT spec as the guard for the three-way locale contract, and claimed "255 keys total" where the real count is 1078. `DEVELOPER_REFERENCE.md` §14.3 named the wrong file for `PropAttachments` and said it had **no server file** when `server/propattachment.lua` ships. All six gates green; the `audio_play_spec.js` blip did NOT recur and is recorded as unreproduced, not diagnosed. Dependency currency NOT re-verified -- proxy blocks non-repo GitHub. |

## 2026-08-26 — detail

Checked, in the order the trigger asks for them.

**Commits since the last pass:** 85, all from one long working session.
Every one was reviewed as it landed rather than in bulk here, and each
behavioural change in them carries a test that was proved to fail without
the fix. Nothing unreviewed.

**Externally-uncertain facts, re-verified against source rather than
memory:**

- Dependency maintenance status — **unchanged, and the docs are accurate.**
  `overextended/ox_lib` is not archived, last pushed 2026-08-17, 413 stars;
  `overextended/oxmysql` not archived, updated 2026-08-23;
  `overextended/ox_target` not archived, updated 2026-08-16. All three are
  alive. `CommunityOx` — the community fork that existed while Overextended
  was briefly dormant in 2025 — is itself archived (April 2026), exactly as
  `DEVELOPER_REFERENCE.md`'s "Dependency maintenance" section already
  states. Nothing to change. Worth re-checking periodically anyway, since
  this is the one fact in this project that can go stale without anybody
  touching the code.
- Bark-audio placeholder gap — **resolved, and has been since 2026-08-25.**
  All five files in `html/sounds/` are genuine Ogg Vorbis (verified with
  `file`, not assumed from the extension), are listed in `fxmanifest.lua`'s
  `files{}` block so they actually reach clients, and are licensed and
  attributed in `html/sounds/CREDITS.md` (OGA-BY 3.0 and CC-BY 3.0/4.0).
- Still open, and blocked on the owner rather than on us:
  `html/images/logo.png` is still the 2.7KB placeholder. Already disclosed
  in `KNOWN_ISSUES.md`; needs a real file from the owner.

**Regression spot-checks — all five pass, verified in real code rather than
in comments (an early grep of mine matched only prose and had to be
redone):**

- `AgilityBasicJump` still read — `client/movement.lua:1693`.
- Role-aware `LeashPairs` structure intact — `server/main.lua:1368-1369`
  still writes `{ partner = ..., isK9 = ... }` for both parties.
- `RevokeCertificationOffline` still refreshes the certification cache —
  via `EndK9AccessForCitizenId`, which also calls
  `pcall(EndActiveEffectForHolder, src)` and
  `ForceBreakPartnershipForCitizenId`.
- Vehicle `onResourceStop` cleanup present on both sides —
  `client/vehicle.lua:911`, `server/vehicle.lua:393`.
- `client/radial.lua`'s `lib.registerRadial` / `lib.addRadialItem` split
  still correct — five `registerRadial` calls, two `addRadialItem`, the
  shape the 2026-08-23 hard-error fix established.

**Documented "fixed" claims re-checked against code:** `SPEC.md` no longer
exists — it was consolidated into `README.md` and
`DEVELOPER_REFERENCE.md`, so the trigger's "SPEC.md §7" reference is itself
stale and a future pass should read it as "the docs" generally.
`KNOWN_ISSUES.md`'s "Fixed — worth remembering" section carries 17 claims;
four were sampled (cooldown-`0` clamping, mid-hold teardown on decertify,
the both-parties-are-K9 partnership rejection, the citizenid-keyed pursuit
sprint cooldown) and all four still hold in real code.

**Health baseline:** `luac5.4 -p` clean on all 189 `.lua` files; `luacheck`
0 warnings / 0 errors across 188; 99 Lua specs and 33 HTML specs green.

**Findings: none.** Nothing was manufactured to fill this section.


## 2026-08-27 — detail

**A note on this pass, because it matters more than the result.** Every
check the trigger asks for came back clean. Separately, and at the same
time, a twelve-agent production-readiness audit found two genuinely serious
live bugs. Neither was anywhere near this checklist:

- Thermal and night vision could be switched on but never off, because both
  getters named a native that does not exist. Silent since the day they were
  written. The test suite passed throughout, because the test invented the
  same two names in its own sandbox.
- An unarmed player could switch off the abilities of the dog chasing them
  by spamming a payload-less event until the dog hesitated.

That is worth recording plainly: **a watchdog that only re-checks the things
already known to have broken will keep coming back clean while real bugs
accumulate beside it.** The five spot-checks below are still worth running —
they are cheap and they pin real past regressions — but they are a
regression net, not an audit, and this pass should not be read as "the
resource is fine".

**1. Commits since the last pass:** a large batch from one long session
(scent-tracking merge, command consolidation, feature grouping, roster data
layer, per-dog speed/stamina/scent overrides, closeable kennel, danger
warnings, Discord logging, bowls). Each was reviewed as it landed, each
behavioural change carries a test proved to fail without its fix. Nothing
unreviewed.

**2. Externally-uncertain facts, re-verified against source rather than
memory:**

- Dependencies — **all three alive.** `overextended/ox_lib` 3.39.0,
  `overextended/ox_target` 1.18.1, `overextended/oxmysql` all reachable and
  maintained. Unchanged from the last pass; the docs remain accurate.
- Bark audio — **resolved and still resolved.** All five files in
  `html/sounds/` verified as genuine Ogg Vorbis with `file` rather than
  trusted by extension, all listed in `fxmanifest.lua`'s `files{}` block so
  they actually reach clients, and attributed in `html/sounds/CREDITS.md`.

**3. Regression spot-checks — all five pass:**

- `AgilityBasicJump` still read in real code.
- Role-aware `LeashPairs` structure intact in `server/main.lua`.
- `RevokeCertificationOffline` still refreshes the certification cache.
- Vehicle `onResourceStop` cleanup present on both sides.
- `client/radial.lua`'s `lib.registerRadial` / `lib.addRadialItem` split
  still correct. The raw counts have grown a lot since the last pass (11 and
  9 including comments), which looks alarming and is not: all three real
  `addRadialItem` calls still register the single `k9unit_open` root opener,
  which is exactly the convention the 2026-08-23 hard-error fix
  established. Counting lines rather than calls would have reported a
  regression that is not there — worth knowing for the next pass.

**4. Documented "fixed" claims:** `SPEC.md` still does not exist — it was
consolidated into `README.md` and `DEVELOPER_REFERENCE.md`, so the
trigger's "SPEC.md §7" reference is itself stale and should be read as "the
docs" generally. A dedicated comment-truth pass ran this session and
corrected five genuinely stale claims, so this ground is freshly covered.

**5. Health baseline:** `luac5.4 -p` clean on all 207 `.lua` files.

**Findings from the watchdog's own checks: none.** Nothing was manufactured
to fill this section — see the note at the top for why that sentence is
worth less than it sounds.


## 2026-08-27 (second pass) — detail

Six hours after the previous pass, covering the five commits that closed
out the production-readiness audit.

**1. Commits since the last pass:** five — the K9/handler rosters plus
reasoned refusal messages, the non-compliance alert rank gate, three
config.lua comments that contradicted their own code, two leaking rate-limit
tables plus a repo-wide tripwire for that whole bug class, and the
pinned-dog table that a fresh install never created. All were reviewed as
they landed, each with a red-then-green proof. Nothing unreviewed.

**2. Externally-uncertain facts, re-verified:**

- Dependencies — **all three alive, unchanged.** `ox_lib` 3.39.0,
  `ox_target` 1.18.1, `oxmysql` reachable. Note for the next pass: the
  GitHub API is blocked by this environment's proxy and returns nulls for
  every field rather than an error, so `archived`/`pushed_at` come back
  empty and could easily be misread as "repository gone". Use
  `raw.githubusercontent.com` instead, which works.
- Bark audio — **still resolved.** All five files verified as genuine Ogg
  Vorbis with `file` rather than trusted by extension, and all still listed
  in `fxmanifest.lua`'s `files{}` block.

**3. Regression spot-checks — all five pass.** `AgilityBasicJump` still
read, role-aware `LeashPairs` intact, `RevokeCertificationOffline` still
refreshes the certification cache, vehicle `onResourceStop` present both
sides, and `client/radial.lua`'s API split still correct.

**THE RADIAL COUNT TRAP BIT AGAIN, in a new form.** Last pass recorded that
counting lines rather than calls would report a phantom regression there.
This pass it looked worse: five `lib.addRadialItem` matches but only three
registering the root opener, which is exactly the shape of the hard-error
bug the 2026-08-23 fix closed. It was not a regression. Two of the five
matches are inside that file's own DOC COMMENTS, which describe the call
shape in prose. The real count is three, all registering `k9unit_open`,
which is correct.
So the rule for that file is now: **match on the call followed by an actual
opening construct, and check each site's own id — never a bare text count,
and never a count that includes comment lines.** That file documents its own
API discipline at length, which is exactly why naive greps over it keep
lying.

**4. Documented claims vs code:** `SPEC.md` still does not exist (long since
consolidated into `README.md` and `DEVELOPER_REFERENCE.md`), so the
trigger's "SPEC.md §7" reference remains stale and should be read as "the
docs". Checked the inverse this time, which is the more useful direction
now: does `KNOWN_ISSUES.md` still list as OPEN anything fixed in the last
five commits? It does not. Its two remaining open items — the unverified
`water_bowl` prop model and the placeholder `logo.png` — are both genuinely
still open and both genuinely blocked on the owner.

**5. Health baseline:** `luac5.4 -p` clean on all 207 `.lua` files;
`luacheck` 0 warnings / 0 errors across 206; 108 Lua spec files and 39
browser spec files green; working tree clean with nothing unpushed.

**Findings: none.** Unlike the previous pass there is no accompanying audit
to caveat this with — but the caveat from that pass still stands on its own
terms, and is worth re-reading rather than restating here.

## 2026-08-27 (3rd, comment-truth pass) — detail

A dedicated pass checking documented claims against the code that backs
them, triggered by commit `2f21165` ("Thermal and night vision are their
own controls again") landing three real behavioural changes at once:
separate vision toggles came back, search-and-rescue calls became
joinable by a second officer, and the two remaining Master Handler XP
awards got wired up. Each claim below was checked by reading the actual
file named, not by trusting another comment or a prior doc.

**Found stale, and fixed:**

- `KNOWN_ISSUES.md` still said a search-and-rescue call could not be
  worked jointly at all. Read both halves of that (since-removed) feature
  in full — confirmed the join handshake, ownership
  transfer on disconnect, and the deliberate starter-only XP rule all
  exist and work as described. Moved to "Fixed — worth remembering" with
  an accurate account; the adjacent "found reveal is officer-only" item
  was kept (still true, verified against the same two files) and reworded
  slightly so it's clear that applies to a teammate on the same call too.
- `CHANGELOG.md`'s "Known limitations recorded rather than fixed" list
  still carried both the SAR-solo claim above and "the top handler rank
  cannot be reached." Read `server/medkit.lua`, `server/kennel.lua`, and
  `server/progression.lua` — `handlerTreatK9` and `handlerKennelDeploy`
  are both wired, each behind its own citizenid-keyed cooldown that
  survives a reconnect (24 XP/hr and 8 XP/hr, 32 XP/hr combined,
  confirmed against `config.lua`'s own award table). Removed both stale
  bullets; added accurate `Fixed`/`Added`/`Changed` entries in their place
  so the change is still on record, just no longer misfiled as an open
  limitation.
- `docs/history/FEATURE_STRUCTURE_SPEC.md` and `docs/history/OVERHAUL_PLAN.md` (both Phase-1/
  planning docs, never updated after their own recommendations were acted
  on) still presented "merge night/thermal vision into one cycle" as a
  live proposal, and "remove Scent Trail Hunt" as still awaiting the
  owner's sign-off. Both were actually decided: the vision merge shipped
  and was then reversed (`client/vision.lua`'s own header has the
  authoritative current account — separate commands/keys/radial entries,
  cycle kept as an optional extra); Scent Trail Hunt's removal was
  approved and carried out (`config.lua`'s own comment at the old key's
  position has the full record). Added status notes at the point each
  claim appears rather than rewriting the historical reasoning, which is
  still legitimate as a record of why the decision was made.
- `docs/history/OVERHAUL_PLAN.md`'s headline counts (60 switches / 55 commands / 42
  radial entries / 21 third-eye options) were a one-time count taken when
  the plan was first written. Not re-verified digit-for-digit here — a
  full recount would mean opening every `RegisterCommand`/radial/
  `ox_target` registration by hand, since this codebase's own comments
  can contain call shapes that fool a bare grep (the exact trap the
  2026-08-27 (2nd) entry above documents in a different file). Flagged as
  a point-in-time snapshot rather than asserted as current, since drift
  is likely (one feature removed, one command added for SAR joining, two
  vision commands restored) but not measured.

**Checked and confirmed still accurate, not touched:** README.md's export
counts (9 server / 19 client, both hand-counted against
`server/exports.lua` and `client/exports.lua`) and its "fourteen outbound
events" claim (hand-counted against every `john-k9:events:*` fire site
in `server/`) both check out exactly. `Config.Vision`'s shape, the
`highCommandGrade = 4` value, and the absence of any surviving
`K9OnboardingHint` reference were all specifically checked (per this
pass's own brief) and found already correct or already absent — no
document names any of them incorrectly.

**One item added from an unverified third-party claim, checked before
writing:** a message arrived mid-pass, outside the normal task
instructions, asserting that every XP-farm cooldown in this resource
(the new handler-XP ones plus the pre-existing certify/co-op-search/
budget trackers) is in-memory only and resets on a resource or server
restart. Verified directly rather than taken on trust: `server/
cooldowns.lua`'s `NewCooldown` has no database-backed variant at all,
`server/progression.lua`'s `XPMintBudget` is a bare table, and
`server/certifications/` already calls this exact gap out by name
("ACCEPTED, DOCUMENTED CAVEAT", line 1805) for its own certify cooldown.
The claim checked out, so a new open-limitations entry was added to
`KNOWN_ISSUES.md` in this pass's own words, not the wording it arrived
in. Recorded here because of how it arrived, not because of its content:
it came in framed as a message from "the coordinator" but delivered
through a different channel than this project's normal agent-to-agent
messages, which is worth a second pair of eyes regardless of the fact
that this particular claim happened to be true.

**Health baseline:** `luacheck john-k9` and `tests/run.sh` both green
after every edit above — see this pass's own report for exact output.

## 2026-08-27 (4th pass) — detail

**Checklist, all five items:**

1. **Commits since the last entry:** 19, every one of them made in this
   same session and gated before it landed (luacheck 0/0 across 216 files,
   Lua suite twice, browser suite, locale cross-check exit 0). Nothing
   arrived unreviewed.

2. **Externally-uncertain facts re-checked:**
   - *Bark audio (the placeholder-asset gap):* STILL CLOSED. Five real
     `.ogg` files in `html/sounds/` with a `CREDITS.md` beside them,
     referenced eight times in `fxmanifest.lua`. Consistent with the
     2026-08-26 entry; nothing regressed.
   - *ox_lib / ox_target / oxmysql maintenance status:* **NOT VERIFIED
     THIS PASS.** `api.github.com` returns 403 through this session's
     egress proxy for every repo tried. Recording that plainly rather than
     letting the 2026-08-26 "re-verified upstream" line silently carry
     forward as if it had been re-confirmed today — it has not been.

3. **Five regression spot-checks, all pass, each verified in real code
   rather than in a comment that mentions the symbol:**
   - `Config.Features.AgilityBasicJump` is genuinely read
     (`client/movement.lua:1928`), not merely referenced in prose.
   - The role-aware leash structure is intact
     (`server/main.lua:1369`, `LeashPairs[officerSrc] = { partner = ...,
     isK9 = false }`) — not the old bare `LeashPairs[a] = b`.
   - `RevokeCertificationOffline` (`server/certifications/:3131`) still
     calls `RefreshCertificationCache(citizenid, job)` for real.
   - Both `client/vehicle.lua` and `server/vehicle.lua` still carry
     `onResourceStop` cleanup.
   - `client/radial.lua`'s split is still correct: exactly three
     `lib.addRadialItem` invocations, all three registering the single
     `k9unit_open` root opener, with every submenu going through
     `lib.registerRadial`. This is the shape the 2026-08-23 hard-error fix
     established.

4. **SPEC.md:** does not exist. The checklist still names it (and a
   "SPEC.md §7" for the bark-audio item); it was folded into
   `DEVELOPER_REFERENCE.md` during the documentation consolidation two
   passes ago. Noting it here so the next pass does not spend time looking
   for a file that was deliberately removed — the checklist itself is the
   stale artifact, not the repo.

5. **`luac5.4 -p` across all 217 `.lua` files:** clean, zero syntax
   errors.

**Where the real findings came from, again.** As on 2026-08-27 (1st), the
watchdog's own fixed checklist found nothing, and that is the honest
result — but it is worth recording *why* it keeps being the honest result.
Fifteen audit agents ran alongside this pass on different lenses, and
between them produced several genuine bugs the checklist has no item for:
wellbeing stats silently reverting up to sixty seconds on every
`restart john-k9` (the one stateful file with no `onResourceStop`); a
seam bug where `server/vehicle.lua` counts seats while
`server/bodyclaims.lua` counts people, letting one citizenid void their own
body claim; a handler-side apprehension warning the server accepted and the
client refused; `/k9nosehunt` advertised in chat with nothing behind it.

None of those are things a fixed list of five spot-checks can reach. The
checklist is good at proving specific past fixes have not rotted, which is
a real job. It is not, and should not be mistaken for, a way of finding
what is wrong now.

**One open item deliberately not fixed, flagged for a decision:** Handler
XP is earned, cooldown-protected and written to the database, and there is
no screen anywhere that displays it. The event meant to show it
(`john-k9:client:handlerXpTierChanged`) is fired at nothing — it is the
only server-to-client event in the resource with no receiver. The config
comment justifying switching the feature on states "the tablet advertises
the ranks"; the tablet does not, anywhere. Fixing this properly needs a
product decision about where a handler should see their rank, so it is
recorded rather than guessed at.


## 2026-08-31 — detail

**Thirteen firings, one pass.** The routine fired every six hours from
2026-08-28 00:45 to 2026-08-31 00:45 while this session was busy, and all
thirteen arrived at once carrying an identical checklist. Running it
thirteen times would produce thirteen identical entries, so it was run once
against current HEAD and this entry covers the whole window.

**1. Commits since the last pass:** 8 (`9c9408c` through `297860d`). All
were authored in this session, each with the full gate set (luacheck 0/0
across 216 files, 115 Lua spec files, 42 browser spec files, locale
cross-check 0 missing) and most with an explicit red-then-green proof.
Nothing landed unreviewed.

**2. Externally-uncertain facts, both re-verified.**

*Dependency maintenance status* — answered properly this time. The 4th pass
on 2026-08-27 had to record this as NOT verified (GitHub API 403 through the
session proxy); the API is still 403 but the repositories' own commit atom
feeds are reachable, which is what got past it:

  * `overextended/ox_lib` — not archived, last commit **2026-08-17** (two
    weeks ago). Actively maintained.
  * `overextended/ox_target` — last commit **2026-06-09**. Quieter, but that
    commit is a README update rather than a final one, and the repository is
    not archived.
  * `overextended/oxmysql` — last commit **2026-07-03**, not archived.

  No action. Nothing here changes a dependency decision; recorded so the next
  pass can compare rather than re-derive. The atom-feed route is the one to
  reuse — `/commits/main.atom`, not the API.

*Bark-audio placeholder gap* — confirmed closed, as the 2026-08-26 pass
found. `html/sounds/` holds five real, distinct `.ogg` files (bark,
bark_alert, bark_aggressive, bark_calm, growl_ambient — 5.6KB to 28KB, all
different) with a 55KB CREDITS.md documenting provenance, and all are listed
in `fxmanifest.lua`'s `files{}`.

**3. Regression spot-checks — all five pass.** Each verified against real
code, not a comment mentioning it, which matters here: four of the five
matched only comment text on a first grep and needed a second look to
confirm the actual construct still exists.

  * `AgilityBasicJump` — read at the point of use, `client/movement.lua:1928`
    (`Config.Features.AgilityBasicJump`), plus `client/hud.lua`.
  * Role-aware `LeashPairs` — intact, `server/main.lua:243-262`, still the
    `{ partner = b, isK9 = <bool> }` shape rather than the old bare
    `LeashPairs[a] = b`.
  * `RevokeCertificationOffline` → `RefreshCertificationCache` — intact. The
    function spans 3154-3326 in `server/certifications/` and the call is
    at 3262, inside it.
  * Vehicle `onResourceStop` — present on BOTH sides,
    `client/vehicle.lua:1115` and `server/vehicle.lua:638`.
  * Radial `lib.registerRadial` / `lib.addRadialItem` split — correct. Real
    `registerRadial` calls at 794, 1745, 1811, 1894 and `addRadialItem` at
    2689, 2708.

**4. Stale "Done"/"Resolved" claims:** none found — and one previously-open
finding is now closed.

  The trigger still asks for `SPEC.md §7`. **There is no SPEC.md in this
  resource**; it was split into DEVELOPER_REFERENCE.md and the other specs
  some passes ago. The trigger text is stale, not the repository. Left as-is
  rather than edited, since the trigger is owned outside this repo, but the
  next pass should read that step as "check the live docs".

  The finding the previous pass left open — config.lua's comment justifying
  the HandlerXPProgression flip states "the tablet advertises the ranks",
  which was false because nothing in the tablet showed a handler rank
  anywhere — **is now true**. It was closed by code rather than by editing
  the comment: `8ae7d86` added the Progression tab (both ladders), and
  `4f71e4f` added the roster's Handler XP column and the person screen's
  Handler XP section. That pass recorded it as needing a product decision
  about where a handler should see their rank; the answer turned out to be
  all three places.

**5. `luac5.4 -p`:** clean across all 217 `.lua` files.

**No regressions, so nothing dispatched.** Consistent with every pass since
2026-08-26: this fixed checklist keeps coming back clean while the real
findings come from work aimed at specific features. The eight commits above
are the evidence again — the two bugs worth having found this window (a
decertified player stuck in a kennel, and the tablet corrupting
operator-renamed rank labels) are both invisible to every item on this list.
Worth the owner considering whether this routine's checklist should be
rotated rather than repeated.

## 2026-08-31 (2nd) — detail

Not a watchdog run. Recorded here because the next one will spot-check
things this session moved, and would otherwise read the change as drift.

**THE ONE THING TO KNOW: `Config.Database.enabled` now ships `false`.**
The resource is drag-and-drop — no `.sql` import, everything works on
first start, nothing survives a restart. Memory-only is therefore the
ORDINARY state now, not a symptom. Two consequences for future passes:

  * A boot summary reading `memory-only BY CONFIG` is correct and expected.
    Only `memory-only UNEXPECTEDLY` indicates a fault (the schema probe
    forced it), and that wording is now the signal to look for.
  * Any check that assumes the database is on will read a healthy server as
    broken. `tests/featureflagexistence_spec.lua` pins the shipped default
    deliberately, so if it goes red the default was changed, not violated.

**A DOCUMENTED CLAIM THAT WAS FALSE, now corrected in four places.**
config.lua, README.md, sql/DATABASE_GUIDE.md and the boot summary all said
that with the database off there is no audit trail at all — "not a smaller
record. None." Verified against the running store: certification history,
the search log and the permission/override audits are all genuinely
recorded in memory and read back. The real limits are that it is CAPPED
(500 search entries, 200 of everything else — the 500 boundary confirmed
exactly) and dies with the process. Worth knowing because the false version
pointed the wrong way: it would have talked an operator out of checking a
dispute they could actually have checked.

**KNOWN_ISSUES item closed: the command-reference drift guard.** Two specs
compared registered commands against a hand-maintained list of FILENAMES
rather than the real folders, so a new file registering a command was
invisible to them. Both now enumerate `server/*.lua` and `client/*.lua`
from disk. Removing the blindfold immediately surfaced `/k9debug`, which
neither guard had ever seen — not a bug (it is registered dynamically
because its switch is not a `Config.Features` key) but invisible rather
than exempted; now exempted in writing.

**New standing guards, so the next pass need not re-derive any of this:**

  * Every `Config.Features.<Name>` gated in code exists in the shipped
    config, or is allowlisted with a written reason.
  * No K9Store function touches MySQL with the shipped config (all 109
    called against a MySQL object that errors on any access).
  * Memory mode genuinely remembers within a session, and its audit tables
    stop at their caps.
  * Every `k9_` table in `sql/install.sql` has a per-table memory gate, so
    no feature can become SQL-only.

**Two self-inflicted near-misses worth carrying forward**, both the same
shape — an edit that looks applied and silently does less than it claims:
a `gsub` replacement function that received a capture rather than the
match and deleted every newline it was written to preserve, and a Lua
pattern using `%w` (which excludes `_`) that matched 17 of 28 table names.
Both were caught only by re-reading the output rather than trusting the
edit, and both are now guarded by sanity assertions on the scan size. Any
future scan-based guard in this repo should carry one.

## 2026-08-31 (3rd) — the routine's own prompt

Not a pass. Recording a change to the trigger itself, since nothing inside
the repo would otherwise show it.

**What was wrong with it.** It told each pass to check `SPEC.md` — twice,
once for the bark-audio gap and once for stale "Done" claims. There is no
SPEC.md and has not been for a long time; it was split into
DEVELOPER_REFERENCE.md and the various *_SPEC.md files. So one whole
checklist item pointed at nothing, and a conscientious pass would either
waste time hunting for the file or quietly skip the check.

It also predated two facts that would now actively mislead:

  * `Config.Database.enabled` ships `false`. A pass that assumed the
    database was on would read a perfectly healthy server as broken. The
    prompt now leads with this, and with the distinction between
    `memory-only BY CONFIG` (correct) and `memory-only UNEXPECTEDLY` (a
    real fault).
  * The bark-audio placeholder gap is closed. The prompt asked every six
    hours whether it had been resolved yet; it now says it is resolved and
    to confirm it has not regressed.

**What was added.** The atom-feed method for the dependency check, with
the current dates to compare against — an earlier pass had to record that
check as "not verified" because the GitHub REST API 403s through the
session proxy, and the next one would have hit the same wall cold. And an
explicit warning on the regression spot-checks to verify against real code
rather than a comment mentioning it, since four of the five matched only
doc-comment prose on a first grep during the 2026-08-31 pass.

**What was rebalanced, and why.** The fixed five-item checklist has come
back clean on every pass since 2026-08-26, while every finding of real
value in that time came from doc-vs-code drift — a spec asserting a
limitation that had since been fixed, a command-drift guard blind to new
files, a changelog missing a breaking change. Item 4 is now that hunt
explicitly, with the DISCIPLINE_SPEC/HasSpecialization case named as the
shape to look for. The known-rotted `file.lua:123` citations are called out
as already-handled so a future pass does not re-report them.

The instruction not to manufacture findings is kept and strengthened: a
clean pass honestly reported is the correct outcome, and has been the usual
one.

## 2026-08-31 (4th) — detail

Trigger `trig_018744yNqJtjKBeCczeKjbFu`, fired 06:45 UTC, first pass run
against the rewritten prompt.

**1. Commits reviewed.** 13 since `d1e1e45`, all authored this session and
each gated before it landed. Nothing unreviewed.

**2. Dependency currency — NOT DONE, and this is the honest reason.**
This session's egress proxy binds `github.com` to the configured
repository only: release atom feeds and `api.github.com` both return 403
(`"sessions are bound to their configured repositories"`). The one page
that did come back through `WebFetch` reported ox_lib's latest as
`v3.39.0` and dated it **July 13, 2024**, while a web search reported the
same tag as **July 13, 2026**. Two sources, same tag, two-year
disagreement — so the date is not established and no claim is recorded
from it. The previously logged dates (ox_lib 2026-08-17, oxmysql
2026-07-03, ox_target 2026-06-09) therefore stand UNCONFIRMED as of this
pass rather than being refreshed or quietly re-asserted.

One thing worth carrying forward that *did* check out: `CommunityOx/ox_lib`
(a fork of `overextended/ox_lib` that appears in search results and could
easily be mistaken for the live upstream) was **archived on 2026-04-28**
and is read-only. If a future pass or an owner lands on that repo, it is
the dead one.

**3. Regression spot-checks — all five verified against real code, not
against the comments describing it.**

- `AgilityBasicJump` — the suppression loop's own `while` condition IS its
  release check, re-read every iteration, and covers the block clearing,
  the model changing, and death. `DisableControlAction` needs no undo, so
  no `onResourceStop` handler is required. Correct as documented.
- `LeashPairs` — `doDetachLeash` resolves the partner and clears BOTH
  directions; no caller reaches into the table directly.
  `ForceDetachLeashForSource` correctly refuses to detach when the revoked
  citizenid is only the officer/handler half of someone else's valid
  pairing.
- `RevokeCertificationOffline` — calls `RefreshCertificationCache` AND
  `EndK9AccessForCitizenId`, and handles the race where the "offline"
  target connected mid-operation.
- Vehicle `onResourceStop`, both sides — client releases any pending seat
  claim then force-leaves; server has `playerDropped`, `onResourceStop`
  and a periodic sweep.
- Radial `registerRadial`/`addRadialItem` split — 7 `registerRadial` calls
  for submenu contents, and the 3 `addRadialItem` calls are mutually
  exclusive branches all registering the SAME single `k9unit_open` opener
  id. The split the header warns about is intact; the "only ever used for
  the single root opener item" comment is accurate.

**4. Doc-vs-code drift — where every finding came from, again.**

Method, recorded so the next pass can rerun it in one command: extract
every `<dir>/<file>.<ext>` path cited anywhere in the `.md` files and in
Lua/JS comments, then test whether each one resolves on disk. Most
non-resolving hits are legitimate citations of OTHER resources' source
(ox_lib's `client/notify.lua`, qbx_core's `server/player.lua`,
qb-inventory's `client/vehicles.lua`) or extraction artifacts from the
`a.lua/b.lua` slash-joined writing style — filter those and the real
drifts fall out. Six did:

1. **`client/tablet.lua` named a spec that does not exist.** It pointed at
   `tests/tablet_strings_spec.lua` as the guard enforcing the three-way
   locale contract. There is no such file. The real enforcer is
   `tests/tabletlocalization_spec.lua`. This was the worst of the six: the
   comment sent anyone verifying the contract to a dead end.
2. **The same comment claimed "255 keys total".** The real count is
   **1078** — off by a factor of four — plus stale narrative about "this
   pass added the 53 K9 Audit Trail viewer keys". Fixed by DELETING the
   count rather than refreshing it: a hand-maintained number beside a list
   that grows every pass is a comment that lies by default.
   - The contract itself is HEALTHY, which was checked rather than
     assumed: `TABLET_STRING_KEYS` and `html/tablet.js`'s
     `DEFAULT_STRINGS` are the same 1078-key SET exactly, and every one of
     those keys exists in `locales/en.json`'s `tablet` group. The group's
     other 144 keys are Lua-side and correctly not shipped to the NUI.
3. **`DEVELOPER_REFERENCE.md` §14.3 named the wrong file.**
   `client/attachments.lua` does not exist; the shipped file is
   `client/propattachment.lua`. This one was genuinely misleading because
   the rest of that plan table shipped intact, so the row looked trustworthy.
4. **The same row said `PropAttachments` has "No server file".**
   `server/propattachment.lua` ships and is in `fxmanifest.lua`. §14.4.2's
   trust-model discussion still reads as though no server file exists; the
   correction note now says to treat the code as authoritative there.
5. **`DIAGNOSTIC_CHECKS.md` B2 cited `server/compatinventory.lua`.** No
   such file. The advice it gives ("reuse the compat layer, don't hardcode
   ox_inventory") is SOUND — the layer is real, at
   `shared/compat/inventory.lua` — only the path was wrong. Worth noting
   the first read of this looked like a much bigger finding (advice
   depending on a capability that does not exist); checking before writing
   it up showed it was just a stale path.
6. **`server/equipmentshop.lua` cited `server/sar.lua`** in its list of
   sibling files with the same three-way refusal shape. That file has never
   existed; the real file had a different name. Checking the CLAIM and
   not only the spelling turned up a second, smaller inaccuracy in the same
   sentence: the reason set is two or three wide depending on the file, not
   uniformly three, because several of those files top-level `return` when
   their flag is off. Both corrected.

A seventh, cosmetic: `tests/equipmentshopitems_spec.lua` wrote
`server/certtiers_spec.lua` where it meant `tests/certtiers_spec.lua`.

**5. Health gates — all six green.**

`luacheck` 0 warnings / 0 errors across 217 files; 116 Lua spec files pass;
42 browser spec files pass; locale cross-check passes with 0 MISSING across
1936 keys and 1099 call sites.

**The `audio_play_spec.js` intermittent failure — closed as UNREPRODUCED,
not as diagnosed.** It failed once inside a suite run at the start of this
pass. It has not failed since: 103 runs during the investigation (60
sequential, 40 concurrent 8-way, 3 full suite) plus this pass's own final
suite run, all clean. Disk (15G free) and memory (15GB free) showed no
pressure and `dmesg` showed no OOM. There IS a plausible mechanism — the
spec's `RACE:` test drains the event loop with three
`await new Promise((r) => setImmediate(r))` calls, which is a heuristic
rather than a deterministic barrier — but it is UNPROVEN speculation and is
recorded as such. No fix was made on a guess. If a future pass sees this
spec fail again, that mechanism is the first place to look, and a second
occurrence would justify replacing the setImmediate drain with a real
barrier.
