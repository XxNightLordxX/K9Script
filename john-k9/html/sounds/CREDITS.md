# john-k9/html/sounds — bark audio sourcing brief

Author: technology-scout pass, 2026-08-24, jlwood17190665@gmail.com.

## Current status (read this first)

**All five required files exist in `html/sounds/`, are genuine Ogg Vorbis
audio (not placeholders), and are listed in `fxmanifest.lua`'s `files{}`
block, so they actually reach clients today.** The sections below are kept
in the order they were written and include two early passes that correctly
concluded nothing could be shipped yet — that history is real and is left
in place, but it describes a state this resource is no longer in. Skip to
"AUDIO SHIP PASS — 2026-08-25" and "AUDIO SHIP PASS 2 — 2026-08-25" further
down for the full sourcing/verification record behind each file; the table
below is only a summary of that record, not a replacement for it.

| File | License | Attribution required |
|---|---|---|
| `bark.ogg` | OGA-BY 3.0 (OpenGameArt) | "Dog barking mono" by Brandon Morris (HaelDB), https://opengameart.org/content/dog-barking-mono, licensed under OGA-BY 3.0. |
| `bark_alert.ogg` | OGA-BY 3.0 (OpenGameArt) | Same as `bark.ogg` — same source submission. |
| `bark_aggressive.ogg` | OGA-BY 3.0 (OpenGameArt) | Same as `bark.ogg` — same source submission. |
| `bark_calm.ogg` | OGA-BY 3.0 (OpenGameArt) | Same as `bark.ogg` — same source submission. |
| `growl_ambient.ogg` | CC-BY 3.0 (OpenGameArt) + CC-BY 4.0 (Freesound, upstream original) | "Dog growls" by congusbongus, https://opengameart.org/content/dog-growls, licensed under CC-BY 3.0; derived from "Dogs growling.wav" by juskiddink, https://freesound.org/people/juskiddink/sounds/121565/, licensed under CC-BY 4.0. |

All four bark files are different trims of the same single OpenGameArt
submission (`dog-barking-mono`), each individually verified as genuine Ogg
Vorbis and measured for clipping/DC offset/loop-seam quality — see "Source 1"
and each file's own dated entry below for the exact commands and numbers.
None of this attribution or licensing text was invented for this summary —
every line above is copied from the fully-sourced entries later in this
file.

**Two loose ends from the sourcing record itself, not something this pass
resolved:** (1) the OpenGameArt "Dog barking mono" submission is offered
under both OGA-BY 3.0 and CC0 — this file deliberately credits it under the
stricter OGA-BY 3.0 rather than assuming the lighter CC0 option applies;
see "AUDIO SHIP PASS 2"'s "Correction... independently reproduced" section
if that choice is ever revisited. (2) whether CC BY-SA-style share-alike
terms could ever reach into this resource's own code was reasoned about,
not confirmed against primary licence text, in "On CC BY-SA's share-alike
scope" below — moot for what's actually shipped (none of the five shipped
files carry a share-alike term), but worth reading before ever adding a
Wikimedia Commons file to this folder.

**Merge note, docs-consolidation pass, 2026-08-25:** the separate
`AUDIO_SOURCING.md` (root of the resource) has been folded into this file.
That document was a second, corroborating pass over the same licensing
question — it could not reach this file's own curl-verified sources
directly (its `WebFetch` tool was egress-blocked against the same audio
hosts), so it cross-checked this file's findings with independent
`WebSearch` queries and reached the same conclusions (see "Independent
corroboration" under the licence section below), plus it caught one real
gap this file had missed: a fifth required sound file, `growl_ambient.ogg`
(now added to the table below), and a legal-reasoning note on the scope of
CC BY-SA's share-alike clause (see "On CC BY-SA's share-alike scope" further
down). No licence statement from either source document was reworded in
this merge — every licence name below is quoted exactly as the source page
or API returned it. `AUDIO_SOURCING.md` itself has been deleted; this file
is now the single, authoritative record for every sound asset this resource
ships or needs.

**Status: NO audio files were added in this pass** (2026-08-24, the
original brief below). This file is a sourcing brief, not a credits log —
there was nothing to credit yet at that point. That was a deliberate,
honest outcome, not an oversight: see "Why no files shipped" below before
assuming this was unfinished work someone forgot to do. **This has since
changed — see "AUDIO SHIP PASS — 2026-08-25" and "AUDIO SHIP PASS 2 —
2026-08-25" further down: all five files (`bark.ogg`, `bark_alert.ogg`,
`bark_aggressive.ogg`, `bark_calm.ogg`, `growl_ambient.ogg`) are now
sourced, shipped, and credited — see "Current status" at the top of this
file for the summary.**

**Confidence convention** (same standard `DEVELOPER_REFERENCE.md#dependencies-and-audio`
already uses in this resource): a claim below is marked CONFIRMED only when
independently corroborated; anything resting on a single, unverifiable
source is marked UNCONFIRMED/PLAUSIBLE and flagged as such.

---

## What is actually needed

Four short, one-shot Ogg Vorbis (`.ogg`) files, at these exact paths and
filenames — read directly from `client/audio.lua`'s `SOUND_NAME_TO_FILE_KEY`
table and `html/app.js`'s `loadSoundBuffer()` (`fetch('sounds/' + key + '.ogg')`,
resolved relative to `html/index.html`, i.e. under `html/sounds/`):

| Filename (place at `html/sounds/`) | Sound name in code | Tone guidance |
|---|---|---|
| `bark.ogg` | `'Bark'` — `client/main.lua`'s `BARK_SOUND_NAME`, the Phase 1 generic bark | Generic/neutral single bark |
| `bark_alert.ogg` | `'Bark_Alert'` — `config.lua`'s `Config.AdvancedBarkRadial` | Sharper, attention-getting bark |
| `bark_aggressive.ogg` | `'Bark_Aggressive'` — `config.lua`'s `Config.AdvancedBarkRadial` | Growl-tinged / threatening bark |
| `bark_calm.ogg` | `'Bark_Calm'` — `config.lua`'s `Config.AdvancedBarkRadial` | Soft, single low bark/chuff |
| `growl_ambient.ogg` | `'Growl_Ambient'` — `client/proximityaudio.lua`'s `PROXIMITY_SOUND_NAME`, sourced from `Config.ProximityAudioFX.soundName` | **Not a one-shot** — played with `loop = true` (`client/proximityaudio.lua` calls `PlayK9Sound(netId, PROXIMITY_SOUND_NAME, { loop = true })`). Needs a seamlessly-loopable ambient growl/breathing bed, not a single bark — a different sourcing target than the four rows above, not a byproduct of whichever bark clip gets picked. Added to this table 2026-08-25 (folded in from `AUDIO_SOURCING.md`, which caught that this file's original four-row table omitted it) — sourcing not yet done. |

**The one duration/size rule above that does not apply to `growl_ambient.ogg`:** "well under 2 seconds, not a loop" is correct for the four bark files only. `growl_ambient.ogg` is deliberately a loop — see its own row above.

Practical constraints, from reading `client/audio.lua` directly (it plays
these as one-shot, non-looping sounds today — nothing in this resource
passes `loop=true` yet):
- **Duration:** a single bark, not a barking sequence or ambience loop —
  realistically well under 2 seconds each.
- **Size:** should be well under 1 MB each; a short mono/stereo bark SFX at
  a normal game-audio bitrate is typically tens to a couple hundred KB. A
  file anywhere near a megabyte for a one-shot bark is a sign the wrong
  asset (e.g. a long ambience track) was picked.
- **Format:** must actually be Ogg Vorbis, not just `.ogg`-named. Verify by
  checking the file's magic bytes (`OggS` as the first four ASCII bytes of
  the file) — do not trust the extension alone. This resource's own
  `html/app.js` (`ctx.decodeAudioData`) will simply fail silently on a
  wrong-format file (by design, per that file's "GRACEFUL DEGRADATION"
  contract), so a bad file wouldn't even throw a visible error — it would
  just look like a normal not-yet-supplied file. Checking the header
  yourself before committing is the only way to catch that.
- Four *distinct* tones are the ideal end state, but are not a hard
  blocker: `client/audio.lua`'s header states a not-yet-mapped/duplicate
  sound name degrades to a harmless resolved key, so shipping the same
  generic `bark.ogg` bytes under all four filenames as an honest first pass
  (better than no audio, clearly worse than four real distinct takes) is a
  legitimate incremental option if only one clean, well-licensed bark can
  be sourced initially.

## Why no files shipped this pass

Two independent blockers, either one of which alone would already justify
not shipping anything real:

1. **Tooling:** this pass's available tools are web search/fetch (which
   fetches a page and returns an AI-summarized markdown/text rendering of
   it — not a raw byte stream) and a text file writer. Neither is capable
   of downloading and faithfully preserving the exact binary bytes of a
   remote audio file. Attempting to "write" audio bytes through a
   text-oriented tool risks silently producing a corrupt or fabricated
   file that merely has a `.ogg` name — exactly the "placeholder that
   looks like a real asset" outcome this task explicitly rules out. Rather
   than risk that, no file was written.
2. **Egress:** even setting tooling aside, this session's network egress
   proxy actively blocked every candidate audio-hosting/reference domain
   tried directly: `freesound.org`, `opengameart.org`, `kenney.nl`,
   `pixabay.com`, and `commons.wikimedia.org` all returned an explicit
   `EGRESS_BLOCKED` error on fetch. (`github.com`/`raw.githubusercontent.com`
   were reachable, for contrast — this looks like a narrow allowlist, not a
   total network outage.) So even a tool that *could* download bytes
   would not have reached most of the sources below this session anyway.

This matches the task's own anticipated "egress blocked / cannot obtain
assets meeting the bar" outcome — treated here as the legitimate result it
is, not something to work around by fabricating a file.

## Candidate CC0 / public-domain sources for whoever sources these next

None of these were independently opened and read this session (blocked, see
above) — each is carried here as a **named, single-source lead from a web
search snippet only**, i.e. UNCONFIRMED/PLAUSIBLE, not verified first-hand.
Whoever pulls from these must open the asset's own page and confirm the
license stated *on that specific asset* before use — do not treat this
list itself as a license clearance.

1. **OpenGameArt.org — "Dog barking mono"** by uploader HaelDB.
   `https://opengameart.org/content/dog-barking-mono`
   Search-snippet description: CC0-licensed, 4 barks recorded at 48kHz,
   mono, background ambiance removed by the uploader. If the license page
   confirms CC0 on this specific submission, this is close to an ideal
   source — already isolated single-bark clips, already processed.
2. **Kenney.nl — "Animal Pack"**.
   `https://kenney.nl/assets/animal-pack`
   Kenney's asset packs are broadly known to be released under CC0 as a
   blanket studio policy, and this pack was returned by search as
   containing animal sounds — but whether it specifically contains a dog
   bark (vs. other animals only) was not confirmed this session; open the
   pack listing and check its actual file list before assuming it has one.
3. **Freesound.org — filter by CC0 specifically.**
   `https://freesound.org/search/?q=dog+bark&f=license%3A%22Creative+Commons+0%22`
   (or manually filter the license facet to "Creative Commons 0" on any
   freesound search) — Freesound hosts a mix of CC0, CC-BY, and
   CC-BY-NC-licensed sounds side by side on the same site, so the license
   filter (or a per-sound license check) is mandatory, not optional, here.
   A specific lead surfaced by search this session:
   `https://freesound.org/people/Juan_Merie_Venter/sounds/327666/`
   ("Dog Bark.wav") — its exact license tag was not independently
   confirmed (page unreachable this session); check it directly.
4. **Wikimedia Commons — "File:Barking of a dog.ogg".**
   `https://commons.wikimedia.org/wiki/File:Barking_of_a_dog.ogg`
   Search snippet describes this as a public-domain `.ogg` file — notably
   already in the exact target format if confirmed. Commons pages
   typically carry an explicit, individually-stated license/author block
   per file, which is exactly the kind of "license stated on the asset
   itself" this task requires — but that block was not independently read
   this session (page unreachable); confirm it directly before use.

## Sources actively checked and ruled out this pass — do not reuse without re-checking the specific caveat

- **`github.com/suzuki256/dog-dataset`** — its `LICENSE` file was read
  directly this session. It is a **mixed-license aggregate**: some
  component sources are `CC BY-NC` (non-commercial), explicitly
  disqualified by this task's constraint (a game server can be monetized).
  Since the file-level license within the dataset isn't uniformly
  CC0/CC-BY at a glance, do not pull an individual file from this repo
  without independently re-confirming that specific file's own license,
  not just the repo's blended summary.
- **`github.com/lavenderdotpet/CC0-Public-Domain-Sounds`** — the repo
  itself carries a CC0 `LICENSE` file, and search suggested it may contain
  a folder resembling dog sounds. **Not used regardless**: it is a
  personal "collection ... over some time" with no stated per-file
  original source or original author for its contents. A CC0 declaration
  by whoever aggregated the files does not establish that the *original*
  recording was theirs to relicense, and this task requires being able to
  cite an actual source URL and license for the asset itself — an
  aggregator's own blanket relicensing claim over unattributed collected
  content does not clear that bar. Flagging this explicitly so it isn't
  reused later on the strength of its LICENSE file alone.

## Checklist before actually dropping files into `html/sounds/`

1. Open the asset's own original page (not an aggregator/mirror) and
   confirm the license stated there is CC0, public domain, or CC-BY.
2. If CC-BY: add an entry to *this* file recording the exact attribution
   text the license requires, verbatim.
3. Confirm the file is genuinely Ogg Vorbis (check the `OggS` magic bytes),
   not merely named `.ogg`.
4. Confirm it's a short, single bark and not a loop/ambience/multi-bark
   sequence; confirm the file size is well under 1 MB.
5. Record filename, source URL, author, license, and retrieval date as a
   new entry in this file for every file actually added.
6. Update `fxmanifest.lua`'s `files{}` block so the new files are actually
   shipped to clients — see the note below; explicit entries are the safe
   default regardless of what glob support turns out to allow.

## `fxmanifest.lua` `files{}` — glob support finding (for whoever owns that file)

**This resource's current `files{}` block already lists every entry
explicitly** (`html/index.html`, `html/style.css`, `html/app.js` — no
glob today), so adding four explicit lines
(`'html/sounds/bark.ogg'`, `'html/sounds/bark_alert.ogg'`,
`'html/sounds/bark_aggressive.ogg'`, `'html/sounds/bark_calm.ogg'`) is a
same-pattern, zero-risk change requiring no new investigation.

On whether a glob would also work (e.g. `'html/sounds/*.ogg'` instead):
the primary CFX documentation pages (`docs.fivem.net`,
`docs-backend.fivem.net`) were unreachable this session (egress-blocked),
so this could not be confirmed first-hand against the authoritative source.
From what could be reached:
- `github.com/citizenfx/fivem` issue **#1406** ("Bash Glob for resource
  file matching") was read directly. It is a live proposal to *replace*
  fxmanifest's existing glob behavior, and in doing so describes today's
  behavior as already having "a current glob pattern system" where a
  single `*` behaves recursively (roughly equivalent to `**/**`, not
  scoped to just the immediate folder) — i.e. **some glob support already
  exists**, but its exact matching semantics are non-obvious and are
  themselves the subject of an open compatibility-breaking change request.
- Multiple independent web-search summaries (not independently opened
  pages, so PLAUSIBLE rather than CONFIRMED to this project's own
  two-primary-source bar) describe the `files` directive specifically as
  glob-capable, one quoting what reads like a docs example:
  `files { 'html/index.html', 'html/**/*', 'data/handling.meta' }`.
- Net assessment: a glob such as `'html/sounds/*.ogg'` is **plausibly
  supported**, but not confirmed against the primary doc this session, and
  its precise matching behavior is under active upstream discussion.
  **Recommendation: use explicit filenames**, matching this manifest's own
  existing convention and sidestepping any ambiguity in current-vs-future
  glob semantics, rather than adopting a mechanism whose exact behavior
  this pass could not verify against the authoritative source.

## Files actually added this pass

`bark.ogg` was added in the 2026-08-25 "AUDIO SHIP PASS" below. **Update:**
the remaining four files (`bark_alert.ogg`, `bark_aggressive.ogg`,
`bark_calm.ogg`, `growl_ambient.ogg`) were subsequently added in "AUDIO SHIP
PASS 2 — 2026-08-25" further down this file — all five now exist in
`html/sounds/`. Use this template for any future file added to
`html/sounds/`:

```
### <filename>
- Source URL:
- Author:
- License:
- Date retrieved:
- Verified Ogg Vorbis (OggS magic bytes): yes/no
- File size:
```


---

# AUDIO SHIP PASS — 2026-08-25

Author: jlwood17190665@gmail.com. Downloaded and shipped the one file that
gates default-on behavior (`bark.ogg`); the other four (`bark_alert.ogg`,
`bark_aggressive.ogg`, `bark_calm.ogg`, `growl_ambient.ogg`) sit behind
features that ship `false` and were left for a later pass, per
`AUDIO_SOURCING.md`'s recommendation.

## Re-verification of the licence, this pass, against the live page

Fetched `https://opengameart.org/content/dog-barking-mono` directly with curl
(HTTP 200) and read the page's own `field-name-field-art-licenses` block
(the structured "License(s):" taxonomy field, not the "Collections:" field
that carries collection titles like "CC0 Audio - Uploader: HaelDB").

**Important correction to the record left by the prior two research passes
(this file's own 2026-08-25 "LICENCE VERIFICATION PASS" section and the
sibling `AUDIO_SOURCING.md`):** both describe the page's "CC0" string as
appearing *only* as a collection name, with the actual License(s) field
containing OGA-BY 3.0 alone. Reading the raw HTML directly, the License(s)
field on this page in fact lists **two** field-items:

```
field-name-field-art-licenses ("License(s):")
  1. <a href='http://opengameart.org/content/oga-by-30-faq'>  license-name: OGA-BY 3.0
  2. <a href='http://creativecommons.org/publicdomain/zero/1.0/'>  license-name: CC0
```

The second entry links to the actual CC0 legal code, not to a collection
page, and sits inside the same taxonomy field as the first — this is
OpenGameArt's standard mechanism for an author offering a submission under
either of two licenses (the downloader's choice), not a stray keyword. I
confirmed this is a genuine structural difference (not a parsing artifact
of mine) by fetching a second, unrelated OGA asset known to be single-licensed
(`content/rpg-sound-pack`, CC0 only) as a control: its License(s) field
contains exactly one `field-item`, where this page's contains two.

This is recorded here for the next person who reads this file, but it does
**not** change what's shipped below: the task constraint this file operates
under only requires "verifiably CC0/public-domain **or** permissively-licensed
(attribution-only)", and **OGA-BY 3.0 alone already clears that bar** —
attribution-only, no share-alike, no NC. So this file is credited under
OGA-BY 3.0, the license this pass can defend with full confidence regardless
of how the CC0 field-item is ultimately read, and no attribution obligation
is skipped by doing so. If a future pass wants to rely on the CC0 option
instead (dropping the attribution requirement below), that reading of the
page should be independently confirmed first, since it revises what two
prior passes concluded.

## `bark.ogg`

- **Source URL:** https://opengameart.org/content/dog-barking-mono (submission page); direct file: https://opengameart.org/sites/default/files/dog_barking_mono.wav
- **Author:** Brandon Morris (submitted by OpenGameArt user HaelDB)
- **License:** OGA-BY 3.0 (attribution-only; see http://opengameart.org/content/oga-by-30-faq). Per the page's own License(s) field this asset is also offered under CC0 — see the correction note above — but this credit is made under OGA-BY 3.0 only, which requires the attribution line below regardless.
- **Attribution text (as OGA-BY 3.0 requires):** "Dog barking mono" by Brandon Morris (HaelDB), https://opengameart.org/content/dog-barking-mono, licensed under OGA-BY 3.0.
- **Date retrieved / verified:** 2026-08-25
- **Verification commands run, and their output:**
  - `curl -sS -L "https://opengameart.org/content/dog-barking-mono" -o oga_page.html -w "HTTP_CODE:%{http_code}\n"` -> `HTTP_CODE:200`; confirmed page identity via `<link rel="canonical" href="https://opengameart.org/content/dog-barking-mono" />` and `<title>Dog barking mono | OpenGameArt.org</title>`.
  - `curl -sS -L "https://opengameart.org/sites/default/files/dog_barking_mono.wav" -o dog_barking_mono.wav -w "HTTP_CODE:%{http_code} SIZE:%{size_download}\n"` -> `HTTP_CODE:200 SIZE:179848`, matching the page's own `<a ... type="audio/x-wav; length=179848">` byte count exactly.
  - `file dog_barking_mono.wav` -> `RIFF (little-endian) data, WAVE audio, Microsoft PCM, 16 bit, mono 44100 Hz` — confirms a real WAV container, mono as the page's own tags claim.
  - `python3 -c "import wave; ..."` on the downloaded file -> `channels 1, sampwidth 2, framerate 44100, nframes 89902, duration_sec 2.0386`. The source file is the uploader's full "4 pitched barks" take (matching the page's own `4`/`barks`/`pitch` tags), not a single one-shot bark.
  - `ffmpeg -i dog_barking_mono.wav -af silencedetect=noise=-30dB:d=0.05 -f null -` -> found four separate audible segments separated by silence, the first spanning ~0.000s-0.195s. **Trimmed to the first bark only** (`-ss 0 -t 0.35`, with a 50ms fade-out from 0.30s to avoid a hard cut) so the shipped one-shot file is actually one bark, matching how `client/audio.lua` plays it (`PlayK9Sound` with no `loop`, per `AUDIO_SOURCING.md`'s own table) — the full 4-bark take would not have been a faithful one-shot bark sound. This is a straightforward trim of an unmodified excerpt, permitted under an attribution-only license.
  - `ffmpeg -y -i dog_barking_mono.wav -ss 0 -t 0.35 -af "afade=t=out:st=0.30:d=0.05" -c:a libvorbis -qscale:a 5 -ac 1 bark.ogg` -> encoded to Ogg Vorbis, mono, 44100 Hz.
  - `head -c4 bark.ogg | od -c` -> `O g g S` (confirmed `OggS` magic bytes; genuinely Ogg container, not just `.ogg`-named).
  - `ffprobe -v error -show_format -show_streams bark.ogg` -> `codec_name=vorbis`, `sample_rate=44100`, `channels=1`, `duration=0.350000`, `size=6951`, `probe_score=100`.
- **Verified Ogg Vorbis (OggS magic bytes):** yes
- **Duration:** 0.35 seconds (well under 2s)
- **File size:** 6,951 bytes (well under 1 MB)
- **Filename and path, derived from code (not assumed):** `html/sounds/bark.ogg`. `client/audio.lua`'s `SOUND_NAME_TO_FILE_KEY` maps sound name `'Bark'` (`client/main.lua`'s `BARK_SOUND_NAME`) to file key `'bark'`; `html/app.js`'s `loadSoundBuffer()` does `fetch('sounds/' + key + '.ogg')`, resolved relative to `html/index.html` — i.e. `html/sounds/bark.ogg`.

## Outstanding follow-up — corrected, docs-consolidation pass, 2026-08-25

**This section previously said `fxmanifest.lua`'s `files{}` block did not
yet list `html/sounds/bark.ogg`. That is no longer true, and re-checking it
directly just now confirms it hasn't been true for a while:**
`fxmanifest.lua`'s `files{}` block lists `'html/sounds/bark.ogg'` explicitly,
alongside `html/index.html`, `html/style.css`, `html/app.js`, and
`locales/en.json` — this resource's manifest convention is explicit
entries, not globs, and this file follows it. `bark.ogg` reaches clients
today. Nothing outstanding here.

The four remaining sound files (`bark_alert.ogg`, `bark_aggressive.ogg`,
`bark_calm.ogg`, `growl_ambient.ogg`) are **not yet in `fxmanifest.lua`**
because they don't exist yet — add each one's `'html/sounds/<name>.ogg'`
line to that block at the same time it's actually dropped into this
folder, not before.

# LICENCE VERIFICATION PASS — 2026-08-25

The leads listed above were recorded from search snippets and explicitly marked
UNCONFIRMED. They have now been checked directly against each asset's own page
or API. **Two of the four were mislicensed in the brief above.** Nothing was
downloaded and nothing was added to this resource.

Why this pass could go further than the last one: earlier attempts had only a
fetch tool that returns an AI summary of a page, and every audio host came back
blocked. Plain `curl` through the environment's proxy reaches all of them. The
hosts were never the obstacle — the tool was.

## Verified findings

| Candidate | Brief claimed | **Actually licensed** | Verified how |
|---|---|---|---|
| `File:Barking of a dog.ogg` (Wikimedia) | public domain | **CC BY-SA 3.0** | Commons API `extmetadata.LicenseShortName` |
| `File:Barking of a dog 2.ogg` | — | **CC BY-SA 3.0** | same |
| `File:Perro ladrando.ogg` | — | **CC BY-SA 4.0** | same |
| `File:Rottweiler Barking.oga` | — | **CC BY-SA 4.0** | same |
| `File:Barking dog in Rome.ogg` | — | **CC BY-SA 3.0** | same |
| OpenGameArt "Dog barking mono" (HaelDB) | CC0 | **OGA-BY 3.0** | the asset page's own licence field |
| Kenney animal/audio pack | CC0, dog unconfirmed | **no animal or dog audio pack found** | site asset search |
| Commons `incategory:CC-Zero` + dog audio | — | **no genuine bark** | every hit is either the London place name "Barking" or a spoken-word pronunciation |

## The OpenGameArt one is a trap, and worth understanding before re-checking it

Searching that page for "CC0" **does** return a hit — because the file belongs
to a user-curated collection *named* "CC0 Audio - Uploader: HaelDB". The
licence field itself says OGA-BY 3.0. Anyone confirming the brief's claim with a
quick text search, human or otherwise, gets a false positive and ships an
attribution-licensed asset believing it is public domain.

That is almost certainly how the original snippet-sourced claim went wrong.

## Where this leaves the decision

Real, usable dog-bark audio is obtainable. **None of it is public domain.**
Every candidate found carries an obligation:

- **CC BY-SA** (the Wikimedia files) — attribution *plus share-alike*. Share-alike
  is the significant one: it is a copyleft term, and applying it to audio
  shipped inside a resource distributed to server owners is a licensing
  commitment about this project, not a formality.
- **OGA-BY 3.0** (OpenGameArt) — attribution only, no share-alike. Materially
  lighter than CC BY-SA, and the more likely fit.

This is the owner's call, not one to make on their behalf, which is why nothing
was downloaded. Whichever way it goes, the four filenames
`html/sounds/{bark,bark_alert,bark_aggressive,bark_calm}.ogg` and the pre-drop
checklist above still apply, and the attribution must be recorded in this file.

Note the format gap: every verified candidate is `.ogg`/`.oga`/`.wav`, while the
NUI bridge expects `.ogg`. The Wikimedia files already qualify; the OpenGameArt
ones are `.wav` and would need converting.

---

# On CC BY-SA's share-alike scope (carried over from `AUDIO_SOURCING.md`, 2026-08-25)

A second, independent pass (unable to reach these hosting sites directly
this session; corroborated the licence findings above via separate
`WebSearch` queries instead — see "Independent corroboration" note below)
raised one point worth keeping even though it did not change what's
shipped: whether CC BY-SA's share-alike clause would actually reach into
this resource's own code if the Wikimedia files were ever used.

**Independent corroboration, for the record:** a `WebSearch` for `"Barking
of a dog.ogg" wikimedia commons license`, run without first reading this
file's own text, independently returned "Creative Commons
Attribution-Share Alike 3.0 Unported" — matching the Commons-API-verified
finding above. The same pass's search for the OpenGameArt asset returned a
snippet claiming "OGA-BY 3.0 **and** CC0" in the same sentence — i.e. it
independently reproduced the exact name-vs-licence-field trap described
above, from a different tool and a differently-worded query. Treat this as
corroboration, not a fresh independent proof.

**The reasoning itself, stated with the same hedge its author gave it —
this is reasoning about how CC BY-SA is structured, not a claim verified
against the primary licence text:**

> CC BY-SA's ShareAlike clause (as CC licenses are generally structured)
> attaches to the *Licensed Material* and *Adapted Material* — i.e., it
> requires anything you *modify and redistribute* to carry the same
> licence. It does not require unrelated software that is merely
> *aggregated alongside* an unmodified copy of the licensed file (a
> "Collection," in Creative Commons' own terminology) to be relicensed.
> Bundling an unmodified `.ogg` into this resource's `html/sounds/` folder
> reads like the "Collection" case, not the "Adapted Material" case —
> which would mean CC BY-SA's copyleft does not reach into `john-k9`'s
> own code at all, only into the audio file itself (and only bites if the
> audio file is later remixed/re-edited and redistributed as a
> modification). **The CC BY-SA 3.0/4.0 legal code itself was not fetched
> to confirm this reading against the primary licence text** —
> `creativecommons.org` was not tried — so this is reasoning about how
> CC BY-SA is structured, not a verified claim. It should be confirmed
> against the actual licence text before relying on it for the Wikimedia
> files specifically.

**Net effect on the recommendation above: none.** `bark.ogg` is already
shipped under OGA-BY 3.0, which carries no such open question at all — this
section only matters if a future pass considers the Wikimedia CC BY-SA
files for one of the four still-missing sounds, in which case confirm this
reading against the primary licence text first rather than assuming it.

## Routes flagged as "don't pursue casually" for whoever sources the remaining four files

Carried over from `AUDIO_SOURCING.md` so this caution isn't lost:

- **Freesound.org, filtered to the CC0 licence facet**, surfaced several
  named candidates (e.g. AleXZavesa's "Dog Bark" pack, nick121087's "Dog
  Barking") — the filter mechanism is legitimate, but no specific result
  page has been opened to confirm a per-file licence tag. Do not treat any
  Freesound URL as cleared without opening its page directly.
- **OpenGameArt collections literally titled "CC0 Sound Effects" / "80 CC0
  creature SFX"** — unverified leads only. The `dog-barking-mono` case
  above is a direct demonstration that a collection *title* containing
  "CC0" is not proof of the *licence field* being CC0 — open and check the
  licence field on each specific asset page before use.
- **Internet Archive 78rpm-era "dog effects" recordings** — not recommended
  as a route at all, not just "unconfirmed." US pre-1972 sound recordings
  have their own copyright timeline (pre-1923 recordings entered the public
  domain 2022-01-01 under the Music Modernization Act; 1923-1946 recordings
  have a longer, staggered term) that is independent of whether
  Archive.org hosts the file — hosting is not itself evidence of
  public-domain status, and confirming it needs the specific recording's
  real production date. Not a quick win; don't pursue without dedicated
  recording-date research.

---

# AUDIO SHIP PASS 2 — 2026-08-25 — the four remaining files

Author: jlwood17190665@gmail.com. This pass ships `bark_alert.ogg`,
`bark_aggressive.ogg`, `bark_calm.ogg` and `growl_ambient.ogg` — the four
keys that were still 404ing. Every section above is preserved unchanged;
this section is additive.

**Nothing in this pass is synthesized or fabricated.** Every byte descends
from one of two OpenGameArt submissions, both of whose pages were fetched
with `curl` and whose licence fields were read out of the **raw HTML**
this pass, not from a search summary and not from the record left in this
file by earlier passes.

## Correction to the "LICENCE VERIFICATION PASS" section above — independently reproduced

That section states, under "The OpenGameArt one is a trap", that
`dog-barking-mono`'s CC0 string appears *only* as a collection name and
that "The licence field itself says OGA-BY 3.0". **That is not what the
page says, and this pass reproduced the earlier "AUDIO SHIP PASS"
correction independently before reading either section's conclusion.**

Raw bytes of the page's own `field-name-field-art-licenses` block, fetched
2026-08-25 (`curl -sS -L https://opengameart.org/content/dog-barking-mono`,
HTTP 200), reformatted here only by inserting line breaks — no words
changed, nothing removed:

```html
<div class="field field-name-field-art-licenses field-type-taxonomy-term-reference field-label-above">
  <div class="field-label">License(s):&nbsp;</div>
  <div class="field-items">
    <div class="field-item even"><div class='license-icon'>
      <a href='http://opengameart.org/content/oga-by-30-faq' target='_blank'>
      <img src='.../license_images/oga-by.png' alt='' title=''>
      <div class='license-name'>OGA-BY 3.0</div></a></div></div>
    <div class="field-item odd"><div class='license-icon'>
      <a href='http://creativecommons.org/publicdomain/zero/1.0/' target='_blank'>
      <img src='.../license_images/cc0.png' alt='' title=''>
      <div class='license-name'>CC0</div></a></div></div>
  </div>
</div>
```

The `Collections:` field is a **separate** `<div class="field
field-name-collect ...">` immediately after it, and *that* is where the
string "CC0 Audio - Uploader: HaelDB" lives. So both things are true at
once: there IS a collection whose title contains "CC0", *and* the
`License(s):` taxonomy field independently lists CC0 as a second licence
alongside OGA-BY 3.0, linking to the actual CC0 legal code.

**This changes nothing about what is credited.** Following this project's
rule that a dual-licensed asset is credited under the STRICTER of the two
offered licences — valid under either reading — everything derived from
this submission below is credited under **OGA-BY 3.0** and carries its
attribution line, exactly as `bark.ogg` already does.

## Correction to "Outstanding follow-up — corrected, docs-consolidation pass"

That section says the four remaining files are "**not yet in
`fxmanifest.lua`** because they don't exist yet". As of this pass they DO
exist, in this folder. They are still not in `fxmanifest.lua`, which is
owned by someone else — the four lines needed are recorded at the bottom
of this section. **Until those lines are added the four new files 404 on
the client exactly as if they were still missing.**

## Source 1 — the three barks

- **Submission page:** https://opengameart.org/content/dog-barking-mono
- **Direct file:** https://opengameart.org/sites/default/files/dog_barking_mono.wav
- **Author (page's own `Author:` field):** `Brandon Morris` — the page renders
  this as "Brandon Morris<br/>(Submitted by HaelDB)".
- **Licence, quoted from the page's `License(s):` field:** `OGA-BY 3.0`
  (linking `http://opengameart.org/content/oga-by-30-faq`) **and** `CC0`
  (linking `http://creativecommons.org/publicdomain/zero/1.0/`).
  **Credited under OGA-BY 3.0**, the stricter of the two.
- **Attribution text (as OGA-BY 3.0 requires):** "Dog barking mono" by
  Brandon Morris (HaelDB),
  https://opengameart.org/content/dog-barking-mono, licensed under
  OGA-BY 3.0.
- **Date retrieved:** 2026-08-25
- **Downloaded file:** `HTTP 200`, 179848 bytes — matching the page's own
  `type="audio/x-wav; length=179848"` exactly.
  `sha256 bbd0f908b3514dd3bd7d2bc04dcf64f8d360a161e7f43cac5d6761e7add79451`
- **`file`:** `RIFF (little-endian) data, WAVE audio, Microsoft PCM, 16 bit, mono 44100 Hz`
- This is the SAME submission `bark.ogg` above already ships from, so its
  licence was already cleared for this resource — re-verified from the raw
  page this pass regardless rather than trusted from this file's own record.

**Why this source, for three different-sounding barks:** the file is a
single take containing **four separate barks** (the page's own tags say
`4`, `barks`, `pitch`). `bark.ogg` above uses the **first**. This pass uses
the **other three**, so all four shipped barks are genuinely different
recorded barks by the same dog, not one bark copied four times:

| File | Source region of `dog_barking_mono.wav` | Measured f0 |
|---|---|---|
| `bark.ogg` (already shipped) | bark 1, 0.000–0.350s | ~233 Hz |
| `bark_aggressive.ogg` | bark 2, 0.508–0.838s — the loudest, fullest of the four | ~222 Hz |
| `bark_alert.ogg` | bark 3, 1.105–1.435s — a natural double bark, the highest-pitched | ~387 Hz |
| `bark_calm.ogg` | bark 4, 1.653–1.858s — first hump only | ~210 Hz |

Segment boundaries were read off a 10 ms RMS envelope of the source, not
guessed: each bark's onset and its decay back to the recording's −83 dBFS
noise floor were located, and every trim starts in that noise floor rather
than on a waveform edge. Bark 4 is the exception and is documented as such
below — the source file ends mid-decay at 2.0386 s, so bark 4 has no
natural end in the recording.

## Source 2 — the ambient growl

- **Submission page:** https://opengameart.org/content/dog-growls
- **Direct file:** https://opengameart.org/sites/default/files/archive_1.zip
  (the page displays the filename as `archive.zip`; the actual href is
  `archive_1.zip`). `HTTP 200`, 70374 bytes.
  `sha256 d5776044754a63705688d0efa44fa294531f25a816b65a8525906b080033527c`
- **Author (page's own `Author:` field):** `congusbongus`
- **Licence, quoted from the page's `License(s):` field:** `CC-BY 3.0`
  (linking `http://creativecommons.org/licenses/by/3.0/`). This field
  contains exactly **one** licence item — checked the same way as the
  two-item case above, so the single-item reading is a measured
  difference, not an assumption.
- **The page also carries a `Copyright/Attribution Notice:` field, quoted
  verbatim:**

  > Derived from Dogs growling.wav by juskiddink
  > https://freesound.org/people/juskiddink/sounds/121565/
  > http://creativecommons.org/licenses/by/3.0/

- **Date retrieved:** 2026-08-25
- **Page body:** "6 clips of medium-large dog growls" — delivered as
  `0.ogg`–`5.ogg`, all already **Ogg Vorbis, mono, 44100 Hz**, i.e. already
  this bridge's exact target format.

### The upstream link in that notice was followed and verified, not assumed

Because this OpenGameArt submission declares itself a *derivative*, the
original was checked directly rather than taking the derivative's word for
the chain:

- **Upstream page:** https://freesound.org/people/juskiddink/sounds/121565/
  (`curl`, HTTP 200; `<title>Freesound - Dogs growling.wav by juskiddink</title>`)
- **Upstream author:** juskiddink
- **Upstream licence, quoted verbatim from that page:** "Attribution 4.0 —
  You are free to share (to copy, distribute and transmit) and to remix
  (to adapt and modify) as long as you credit the author", linking
  `http://creativecommons.org/licenses/by/4.0/`.
- Note the version difference and that it is harmless here: the OGA
  derivative's notice cites CC-BY **3.0** (the version in force when
  congusbongus derived it); Freesound displays the original as CC-BY **4.0**
  today. Both are attribution-only — **no NonCommercial, no ShareAlike in
  either** — so the whole chain clears this project's licence bar, and
  neither version's obligation is skipped: both parties are credited below.

**Attribution text for `growl_ambient.ogg` (both links in the chain, as
CC-BY requires):** "Dog growls" by congusbongus,
https://opengameart.org/content/dog-growls, licensed under CC-BY 3.0;
derived from "Dogs growling.wav" by juskiddink,
https://freesound.org/people/juskiddink/sounds/121565/, licensed under
CC-BY 4.0.

## Ruled out this pass, with the reason, so nobody re-tries it

- **OpenGameArt "Dog sounds" by pauliuw** —
  https://opengameart.org/content/dog-sounds — licence field reads `CC0`
  (single item, verified in raw HTML), which would have been the simplest
  possible licence outcome. **Rejected on provenance and on quality.**
  Provenance: the page body says, in the author's own words, "9 dog
  sounds(barking, growling, squalling). **Some of the sounds are recordced
  through mp3 player.**" A CC0 grant over material the uploader
  re-recorded from someone else's playback does not establish it was
  theirs to release — the same objection this file already records against
  `lavenderdotpet/CC0-Public-Domain-Sounds`. Quality, independently:
  `Dog Bark 1.wav` measures peak 1.0000 with **4 clipped samples** and a
  **DC offset of −0.0623**; `Dog Bark.wav` has DC +0.0225. Its barks also
  sit at f0 ≈ 500–630 Hz (a small dog), wrong for a police K9.
- **OpenGameArt "Dog Grunt" by qubodup** —
  https://opengameart.org/content/dog-grunt — licence field `CC0`, clean
  provenance (the author's own dog), technically clean audio. Not used
  only because the submission is a **single 0.58 s grunt**: looping one
  short grunt as a continuous ambient bed would read as an obvious
  repeating artefact. Kept here as a genuinely CC0 fallback if the CC-BY
  attribution above ever becomes unwelcome.

---

## `bark_alert.ogg`

- **Source URL:** https://opengameart.org/content/dog-barking-mono (see "Source 1" above)
- **Author:** Brandon Morris (submitted by OpenGameArt user HaelDB)
- **License:** OGA-BY 3.0 — credited under the stricter of the two licences the page's `License(s):` field offers (the other being CC0). Attribution line as given in "Source 1" above.
- **Date retrieved:** 2026-08-25
- **Derivation:** bark 3 of the source take (1.105–1.435 s) — a natural double bark and the highest-pitched of the four. DC-blocking high-pass at 70 Hz; pitched **up 5 %** (`asetrate=46305` then resampled back to 44100 with soxr) to sharpen it further into an attention-getting alert; 4 ms fade-in, 50 ms fade-out; gain ×1.519 to a 0.42 peak.
- **Exact commands:**
  - `ffmpeg -y -ss 1.1050 -t 0.3300 -i dog_barking_mono.wav -af "highpass=f=70,asetrate=46305,aresample=44100:resampler=soxr,afade=t=in:st=0:d=0.004,afade=t=out:st=0.2643:d=0.050" -ac 1 -ar 44100 -c:a pcm_f32le bark_alert_raw.wav`
  - `ffmpeg -y -i bark_alert_raw.wav -af volume=1.519000 -c:a libvorbis -qscale:a 5 -ac 1 -ar 44100 bark_alert.ogg`
- **Measured (not intended) properties:** `file` -> `Ogg data, Vorbis audio, mono, 44100 Hz, ~96000 bps`; `ffprobe` -> `codec_name=vorbis`, `sample_rate=44100`, `channels=1`, `channel_layout=mono`, `duration=0.314286`, `size=6721`, `probe_score=100`. `head -c4 | od -c` -> `O g g S`.
- **Quality measurements:** peak **0.4234** (no sample reaches 1.0; **0 clipped samples**), RMS 0.0522, **DC offset +0.000038** (bark.ogg's own is −0.003701, so this is cleaner than the reference file), first 2 ms at **−64.3 dBFS** and last 2 ms at −180 dBFS (digital silence) — no click at either edge.
- **Verified Ogg Vorbis (OggS magic bytes):** yes
- **File size:** 6,721 bytes
- `sha256 cd26297a4e9d7a464164cb27f531966ef19c8f96cf1984bd853065649fa94f37`

## `bark_aggressive.ogg`

- **Source URL:** https://opengameart.org/content/dog-barking-mono (see "Source 1" above)
- **Author:** Brandon Morris (submitted by OpenGameArt user HaelDB)
- **License:** OGA-BY 3.0 — credited under the stricter of the two licences the page's `License(s):` field offers (the other being CC0). Attribution line as given in "Source 1" above.
- **Date retrieved:** 2026-08-25
- **Derivation:** bark 2 of the source take (0.508–0.838 s), the loudest and fullest of the four. DC-blocking high-pass at 70 Hz; pitched **down 6 %** (`asetrate=41454` then resampled back to 44100 with soxr) to suggest a heavier dog; 4 ms fade-in, 50 ms fade-out; gain ×1.031 to a 0.46 peak — deliberately the hottest of the four one-shots.
- **Exact commands:**
  - `ffmpeg -y -ss 0.5080 -t 0.3300 -i dog_barking_mono.wav -af "highpass=f=70,asetrate=41454,aresample=44100:resampler=soxr,afade=t=in:st=0:d=0.004,afade=t=out:st=0.3011:d=0.050" -ac 1 -ar 44100 -c:a pcm_f32le bark_aggressive_raw.wav`
  - `ffmpeg -y -i bark_aggressive_raw.wav -af volume=1.031000 -c:a libvorbis -qscale:a 5 -ac 1 -ar 44100 bark_aggressive.ogg`
- **Measured (not intended) properties:** `file` -> `Ogg data, Vorbis audio, mono, 44100 Hz, ~96000 bps`; `ffprobe` -> `codec_name=vorbis`, `sample_rate=44100`, `channels=1`, `channel_layout=mono`, `duration=0.351066`, `size=7119`, `probe_score=100`. `head -c4 | od -c` -> `O g g S`.
- **Quality measurements:** peak **0.4564** (**0 clipped samples**), RMS 0.0672, **DC offset −0.000048**, first 2 ms at **−84.3 dBFS**, last 2 ms at −180 dBFS — no click at either edge. Spectral centroid over the audible span measures 865 Hz against `bark.ogg`'s 861 Hz, confirming the downward pitch shift introduced no high-frequency resampling artefact.
- **Verified Ogg Vorbis (OggS magic bytes):** yes
- **File size:** 7,119 bytes
- `sha256 261d3141f0333924de9af926c450dd08e7a3199c8e79ffec5b772b14407d25f5`

## `bark_calm.ogg`

- **Source URL:** https://opengameart.org/content/dog-barking-mono (see "Source 1" above)
- **Author:** Brandon Morris (submitted by OpenGameArt user HaelDB)
- **License:** OGA-BY 3.0 — credited under the stricter of the two licences the page's `License(s):` field offers (the other being CC0). Attribution line as given in "Source 1" above.
- **Date retrieved:** 2026-08-25
- **Derivation:** bark 4 of the source take, **first hump only** (1.653–1.858 s). DC-blocking high-pass at 70 Hz; pitched **down 10 %** (`asetrate=39690` then resampled back to 44100 with soxr); gentle **3.8 kHz low-pass** to take the bite off the transient; 4 ms fade-in, 50 ms fade-out; gain ×0.640 to a 0.24 peak — deliberately the quietest of the four, so a calm bark reads as calm even at full proximity gain.
- **Known caveat, stated plainly:** bark 4 is the one bark in the source that has **no natural end** — the recording stops at 2.0386 s while this bark is still decaying, and it is followed by a second hump this file deliberately excludes. The 50 ms fade-out ending at 1.858 s is therefore doing real work rather than merely tidying an already-silent tail. Measured result is a smooth decay to −62.4 dBFS in the final 2 ms with no discontinuity, but this is an edited ending, not the recording's own.
- **Exact commands:**
  - `ffmpeg -y -ss 1.6530 -t 0.2050 -i dog_barking_mono.wav -af "highpass=f=70,asetrate=39690,aresample=44100:resampler=soxr,lowpass=f=3800,afade=t=in:st=0:d=0.004,afade=t=out:st=0.1778:d=0.050" -ac 1 -ar 44100 -c:a pcm_f32le bark_calm_raw.wav`
  - `ffmpeg -y -i bark_calm_raw.wav -af volume=0.640000 -c:a libvorbis -qscale:a 5 -ac 1 -ar 44100 bark_calm.ogg`
- **Measured (not intended) properties:** `file` -> `Ogg data, Vorbis audio, mono, 44100 Hz, ~96000 bps`; `ffprobe` -> `codec_name=vorbis`, `sample_rate=44100`, `channels=1`, `channel_layout=mono`, `duration=0.227800`, `size=5680`, `probe_score=100`. `head -c4 | od -c` -> `O g g S`.
- **Quality measurements:** peak **0.2407** (**0 clipped samples**), RMS 0.0508, **DC offset −0.000024**, first 2 ms at **−90.3 dBFS**, last 2 ms at −62.4 dBFS (inaudible, and the tail of a smooth fade rather than a cut).
- **Verified Ogg Vorbis (OggS magic bytes):** yes
- **File size:** 5,680 bytes
- `sha256 cdcda486602d2161aca6c75f40ab351c39ecc8ebc5f19ecb361fc69f760de972`

## `growl_ambient.ogg`

- **Source URL:** https://opengameart.org/content/dog-growls (see "Source 2" above)
- **Author:** congusbongus (OpenGameArt), derived from a recording by juskiddink (Freesound)
- **License:** **CC-BY 3.0** for the OpenGameArt submission, quoted from its `License(s):` field; the upstream original it declares itself derived from is **CC-BY 4.0**, quoted from Freesound as: "Attribution 4.0 — You are free to share (to copy, distribute and transmit) and to remix (to adapt and modify) as long as you credit the author". Attribution-only at both links in the chain; no NonCommercial and no ShareAlike anywhere in it.
- **Attribution text (required — both links in the chain):** "Dog growls" by congusbongus, https://opengameart.org/content/dog-growls, licensed under CC-BY 3.0; derived from "Dogs growling.wav" by juskiddink, https://freesound.org/people/juskiddink/sounds/121565/, licensed under CC-BY 4.0.
- **Date retrieved:** 2026-08-25
- **This is the one LOOPING file.** `client/proximityaudio.lua` starts it via `PlayK9Sound(netId, 'Growl_Ambient', { loop = true })`, and `client/audio.lua` re-polls its gain every 500 ms up to a 60 s ceiling. A loop must therefore be seamless at its wrap point; it must NOT be faded in or out at its edges, because an edge fade produces an audible gap on every single repeat. The high edge amplitudes measured below (0.2568 / 0.3444) are correct and intentional for that reason.
- **Derivation, in full:**
  1. All six source clips (`0.ogg`–`5.ogg`) DC-blocked with a one-pole filter (R = 0.9995, ≈7 Hz corner) — well below the ~110 Hz growl fundamental, so it removes drift without touching the growl.
  2. Each clip trimmed to its **sustained plateau**: the span between the first and last 20 ms window within 8 dB of that clip's loudest window. This discards each clip's attack ramp and decay tail so that every crossfade below joins full-level material to full-level material — the thing that stops a loop from audibly "pumping".
  3. The six plateaus concatenated in the order `3, 1, 4, 2, 5, 0` (varied deliberately so the loop does not read as one growl repeating), joined by **120 ms equal-power (sin/cos) crossfades**. Equal-power rather than linear because a growl is noise-like, where a linear crossfade dips about 3 dB mid-cross.
  4. A **180 ms wrap-around crossfade** applied so the file loops seamlessly: the first 180 ms blends the head of the bed with the material that *follows* the loop end, which makes the last-sample-to-first-sample transition exactly the continuous transition that already existed inside the source bed.
  5. Normalized to a 0.55 peak — below the one-shot barks, since this is a continuous bed that plays underneath them.
  6. Encoded `-c:a libvorbis -qscale:a 4 -ac 1 -ar 44100` (q4 rather than the barks' q5: the content is low-frequency and noise-like, and q5 bought no measurable benefit while costing size on the one file long enough for size to matter).
- **Measured (not intended) properties:** `file` -> `Ogg data, Vorbis audio, mono, 44100 Hz, ~86000 bps`; `ffprobe` -> `codec_name=vorbis`, `sample_rate=44100`, `channels=1`, `channel_layout=mono`, `duration=2.700000`, `size=28386`, `probe_score=100`. `head -c4 | od -c` -> `O g g S`.
- **Quality measurements:** peak **0.5511** (**0 clipped samples**), RMS 0.1616, **DC offset −0.000087**. Level across the whole loop stays within an 11.3 dB spread (−22.6 to −11.3 dBFS) with **no dropout to silence anywhere** — it is a continuous bed, not a series of separated growls.
- **Loop seam verified empirically, on the ENCODED file, against a control:** the `.ogg` was decoded back to PCM, concatenated with itself (what a looping `AudioBufferSourceNode` actually plays), and the wrap point measured.
  - The decoded file is **119070 samples = exactly 2.700000 s**, i.e. the Vorbis round-trip preserved the sample count exactly and introduced no decoder padding gap at the loop point.
  - **Exact single-sample step across the wrap: 0.019623 — the 87.1st percentile** of all sample-to-sample steps in the file. In other words the wrap transition is an entirely ordinary transition within this growl, not an edge.
  - **Level step across the wrap: 1.41 dB — the 62.4th percentile** of the file's own 20 ms window-to-window level changes (median 1.01 dB, p95 3.19 dB). Well inside the growl's own natural variation.
  - High-frequency (first-difference) energy in a 4 ms window centred on the seam measures 0.01552 against a median of 0.01288 and a p95 of 0.01911 elsewhere in the file — i.e. **below** the 95th percentile, so no click.
  - **Control, to prove those numbers can actually detect a bad seam:** the identical bed truncated to the identical length with the wrap crossfade **omitted** was built and measured the same way. Its seam step is 0.045166, at the **99.42nd percentile** — flagged as a discontinuity by the same test that passes the shipped file. The test discriminates; it is not vacuously passing.
- **Verified Ogg Vorbis (OggS magic bytes):** yes
- **File size:** 28,386 bytes
- `sha256 2e85bd00bdd2fe46049506ceed0f4788122ebbebd5d07792d214ae5ba3f3f380`

---

## Required follow-up in `fxmanifest.lua` — RESOLVED

**Update:** this has since been done. `fxmanifest.lua`'s `files{}` block now
lists all five files (`html/sounds/bark.ogg`, `bark_alert.ogg`,
`bark_aggressive.ogg`, `bark_calm.ogg`, `growl_ambient.ogg`) as explicit
entries, matching this manifest's existing convention rather than a glob —
the reasoning for that is in the "glob support finding" section above and
is unchanged. Nothing outstanding here; the paragraph below is left for
context on why the fix mattered.

The four new files **would have 404'd exactly as before** until those four
lines joined `'html/sounds/bark.ogg'` in that file's `files{}` block — which
they now have.

## Heads-up: `html/tests/` no longer encodes "these four files do not exist" as a fixture — RESOLVED

**Update:** `html/tests/sandbox.js`'s `realSoundsFetch()` now reads whatever
is genuinely present in `html/sounds/` (all five real files, today), and the
suite's 404-path tests use a dedicated `MISSING_SOUND_KEY =
'nonexistent_test_sound'` — a key guaranteed never to be a shipped asset —
instead of piggy-backing on a real filename that used to be absent. That is
exactly the robust fix this section used to ask whoever owns `html/tests/`
to make; it has been made. The paragraph below is left for context on the
problem it fixed.

Before that fix, `html/tests/sandbox.js`'s `realSoundsFetch()` deliberately
read the **real** `html/sounds/` directory, and its own comment said so:
"(bark.ogg exists; bark_alert/bark_aggressive/bark_calm/growl_ambient do
not, as of this task's own setup)". Shipping the four files would have
flipped those tests' 404 path to a 200 path, breaking `audio_play_spec.js`
and `audio_setgain_stop_spec.js` for that reason alone — including the
regression test for the `stoppedBeforeStart` leak, which needs a
genuinely-absent file to exercise the leak path at all.

Worth noting what those failures actually prove, though: the sandbox
reported decoding buffers of **6721** and **28386** bytes for `bark_alert`
and `growl_ambient` — byte-for-byte the sizes of the files shipped above.
The resource really does now find, fetch and decode the new audio through
its own real code path.
