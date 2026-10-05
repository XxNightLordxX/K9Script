> **HISTORICAL RECORD — NOT CURRENT GUIDANCE.**
>
> This document is the staged plan for the resource-wide overhaul. The work it describes has been
> built, and in places has since been changed or removed. It is kept because
> it explains WHY things are shaped the way they are, which the code alone
> cannot say — but it does not describe how the resource works today, and it
> is not a specification anyone should implement from.
>
> For how the resource actually works now, see `README.md` (setup and
> features), `DEVELOPER_REFERENCE.md` (the code), and `DIAGNOSTIC_CHECKS.md`
> (the `/k9debug` report). Archived 2026-09-02.

---

# K9 Unit Overhaul Plan — Cutting the Redundancy

Written for you, not for the other agents. No code, no jargon you didn't
already use yourself. If you want the engineering version, it's
`docs/history/FEATURE_STRUCTURE_SPEC.md`; you shouldn't need it.

## You already found the real problem

You said it yourself: **"the scent tracking and scent lineup etc are
redundant as it really doesn't do much."** That's exactly right, and it's
the whole thesis of this plan. I went and checked every one of your 60
feature switches against that same standard — not just the scent ones —
and here's the honest answer, including the parts of your instinct that
turned out right and the one part that turned out wrong (details below,
you asked for both).

## The numbers, because they make the case better than I can

**A snapshot, not a live count:** the four numbers just below were counted
once, when this plan was first written, to make the case for it. Real
work has landed since — a feature was removed (Scent Trail Hunt, see
below), search-and-rescue calls gained a join command, and vision's two
toggles came back as their own commands and radial entries after briefly
being merged into one — so these exact figures have almost certainly
drifted by now in both directions. Nobody has re-counted them since, and
they're left as-is here as the historical basis for this plan's argument,
not re-asserted as today's truth. If you want current figures, they'd
need a fresh count against the actual `client`/`server` folders, the same
way this first count was done.

Right now, across the whole K9 script, there are:

- **60 separate on/off switches** in your settings.
- **55 chat commands** your handlers have to remember.
- **42 radial menu entries** (the pie-wheel menu).
- **21 third-eye options** (the ones you get by looking at something and
  hitting the interact key).

That's roughly **118 different things a player can click or type** to
operate a K9 unit. A lot of that is one capability wearing three or four
different hats:

- **Kennels** cost a player 7 separate things to know: 3 third-eye
  options, 2 radial menu entries, 2 chat commands — to do what is really
  one job (put the kennel down, get in, get out, pick it back up).
- **Fetch** is also 7: 2 third-eye options, a 2-item radial menu, 3
  commands — for throwing a ball, dropping it, and recalling it.
- **Feeding/caring for the dog** is also 7: 4 third-eye options (feed,
  pet, treat, drink), 1 radial entry, 2 commands.
- **The leash** has two third-eye options — one for "I'm the handler,"
  one for "I'm the dog" — and the game already knows which one you are
  the instant you look at the leash. The player is being asked a question
  the code can already answer itself.

That last one is the cleanest example of what's wrong, and it generalizes:
a lot of this script's "choices" aren't real choices at all.

## What the 60 switches actually are, once I checked each one

I didn't just count them — I went through every single one and asked:
*is this a real, separate thing you'd want to control on its own, or is it
just noise?* Being blunt about the results, because a report that just
tidies things up without saying "no, this one's actually fine" isn't
worth much:

| What I found | How many | What it means for you |
|---|---|---|
| **Real features** — worth their own switch and their own way to trigger them | 25 | These stay, unchanged in what they do. |
| **Real add-ons inside a bigger feature** — a genuine reason to want the big feature on but this one specific part off | 30 | These stay too, just grouped under the feature they belong to instead of sitting loose in one long list. |
| **Just behaviour now** — the switch goes away, the thing it does keeps happening exactly as it does today | 4 | You get 4 fewer things to think about. Nothing changes in game. |
| **Recommended for outright removal** — the capability itself goes away | 1 (**approved and done** — see below) | Covered on its own below — this was the one that needed your answer; you gave it. |

So: **60 switches become roughly 18 things at the top of your settings**
(the real features, each with its smaller add-ons tucked inside it,
instead of one flat list of 60), **not** "one real feature and five
behaviours" the way you guessed for the scent example specifically — I'll
explain why below, because I think it's worth you knowing where I disagree
with your own read and why, rather than just agreeing to be agreeable.

## Your scent example, answered directly

You named six things: scent tracking, blood tracking, gunpowder sniffing,
scent vision, the scent trail hunt game, and the scent lineup game. Here's
where each one honestly landed:

- **Scent tracking** — this is the real feature. It becomes the one
  on/off switch for "can my K9s detect things at all."
- **Blood tracking** and **gunpowder sniffing** — these stay as their own
  small on/off switches *inside* scent tracking, because they're real,
  separate content decisions (some servers don't want a blood-trail
  mechanic at all for tone reasons; that's a real reason to turn one off
  and keep the other on, not just clutter).
- **Scent vision** (the "see everyone's recent footprints" mode) — I kept
  this as its own real feature. It's a genuinely different thing to use
  (you leave it running, rather than firing it once), and merging it into
  the main scent button would make both worse. This is one place I'd
  push back gently on "just make it all one thing."
- **The scent trail hunt game** — **I recommend removing this one
  outright.** See below.
- **The scent lineup game** — **I recommend keeping this one, and NOT
  merging it away.** Also see below. You named it as an example of
  something that "doesn't do much," and on this one I think you're wrong,
  for a reason worth hearing.

Already-in-progress, good news: another agent is right now building the
scent tracking merge itself — one radial menu button that automatically
figures out whether your K9 is tracking scent, blood, or gunpowder based
on what it's trained for, instead of three separate buttons. That part is
real, tested, and happening regardless of this plan.

## The one item I'm asking you to sign off on removing

**STATUS: decided — approved, and done.** You said yes to removing it.
`config.lua` no longer has the switch for this feature; the console has
the full record of what changed and exactly how to bring it back (as-is,
or as a training drill instead — see below) if you ever change your mind.
The rest of this section is kept as the record of what you were asked and
why, not as an open question any more.

Here it is, with everything you'd want to know
before saying yes or no:

**☐ Remove "Scent Trail Hunt" (the K9 hide-and-seek/growl-guided game)
entirely.**
- **What it does today:** your K9 gets sent after a hidden spot nearby,
  guided only by a growl that gets faster as it gets closer. No reward, no
  connection to any other system.
- **Why I think it should go:** it's not just "thin," it's a genuine
  duplicate — it's the exact same "walk toward a fading signal" mechanic
  as regular scent tracking, except aimed at a made-up spot instead of a
  real one. It doesn't feed into search, evidence, or rescue work anywhere
  else in the script.
- **What you'd notice if it went:** that specific hide-and-seek game
  disappears from the radial menu and command list. Nothing else changes.
- **Does anything else depend on it:** I checked every other file in the
  script for a reference to it. Everything I found was either a listing
  entry (the settings menu, the permissions list, the tablet) or a comment
  mentioning it in passing — nothing else's behaviour is driven by whether
  this one is on or off. It also doesn't store anything in your database,
  so there's no history to lose either way.
- **One thing to consider before you answer:** the only training exercise
  your handlers can currently practice is bite-and-hold and searching,
  against a dummy. This hunt game is the *only* thing that lets a new
  handler practice following a scent trail without a real one existing
  yet. If you think that's worth keeping as a training tool, tell me and
  it stays — just moved under "Training" instead of living next to real
  scent tracking, where it never really belonged.

**Why I'm NOT recommending removal of "Scent Lineup"** (the one you named
directly): it's a genuinely different mechanic from anything else in the
script — it needs a second, often-uninvolved player (a bystander gets
lined up and asked to be picked out), it's not duplicating any other
feature's shape, and its "pick" and "cancel" actions are deliberately
open to anyone, K9 handler or not, because the person being asked to point
someone out usually has nothing to do with the police. Removing it would
take away something your players can currently do, not tidy up a
duplicate. If, after reading this, you still want it gone, say so
explicitly and I'll add it to the removal list — I'm just not defaulting
to it.

## The rule that keeps this whole plan from breaking your server

Two promises, both non-negotiable, no matter which stages below you
approve:

**1. Nothing switches itself back on without asking you.** Right now, a
few things ship turned off on purpose — extra XP for handlers, Discord
posting, certification expiry, and the "danger warning" bark, specifically.
If any switch disappears into "just happens now" behaviour, and you
currently have it turned off, it *stays off* for you. The new setup checks
your existing file first; if it sees your old-style settings, it changes
nothing at all and tells you so once when the server starts. You will
never end up with something quietly turned on that you deliberately turned
off.

**2. A merged button can only ever do what the separate buttons could
already do — never more.** When one action automatically figures out
"which of these three things should this actually be," it is only ever
deciding *which* thing to do, never *whether* you're allowed to do it. The
clearest example is the lineup game above: starting one needs a
certified handler with permission; picking someone out or cancelling needs
neither, on purpose, because that's usually a civilian's job. If those two
ever got combined behind one "are you a certified handler" check, it
wouldn't make the feature simpler — it would break it for the exact people
who are supposed to use it. Every merge in this plan gets checked
individually against this rule before it ships, family by family, not
assumed safe because a similar-looking merge worked somewhere else.

## The stages — approve, decline, or ask questions on each independently

### Stage 1 — Fix how the settings are organized (no player-visible change)
Reorganize the 60 switches into logical groups instead of one long list,
and fix a couple of groupings that were actually wrong (for example: the
tablet, the audit commands, and the "give someone extra permissions"
switch currently look like they belong together, but your own script's
comments say plainly that people run them independently — turning off the
audit commands should never risk also turning off the tablet, and the new
setup makes sure it can't).
**Risk: none.** Nothing a player does or sees changes. This is pure
bookkeeping and a safety fix.

### Stage 2 — Let 4 small settings just happen instead of needing a switch
The "extra bark sounds," "advanced jumping," "hear the dog from a
distance," and "trails break at water crossings" switches disappear;
what they do keeps happening exactly as it does for you today (or exactly
as you'd set it, if you'd changed it from default — see the promise
above).
**Risk: very low.** You get 4 fewer things to manage; literally nothing in
game changes.

### Stage 3 — Merge the leash's two third-eye options into one
The game already knows whether you're the handler or the dog; it should
stop asking.
**Risk: very low.** This is a code cleanup, not a player-facing change —
whichever one a player already saw, they'll keep seeing; there's just one
option in the underlying list instead of two.

### Stage 4 — Merge kennels, feeding, and fetch down to one entry point each
Instead of choosing between "enter kennel / exit kennel / pick up kennel,"
one option figures out which one makes sense from whether a kennel is
already sitting there. Same idea for feed/pet/treat/give water, and for
throw/drop/recall the fetch ball. Some of the underlying chat commands
stay as they are today on purpose (a couple of them are tied to rebindable
keyboard shortcuts, and changing their names would break anyone who
customized their keybinds) — the cleanup there is adding one easier
command, not replacing the old ones.
**Risk: medium.** These are genuinely fewer choices for a player to make,
and I want to be honest about the trade: a merged action is guessing what
you meant from context, and I have not yet double-checked the exact
current behaviour of every one of those third-eye options closely enough
to promise the guess will always be right on day one. I'd want a quick
verification pass before this one goes live, not a "trust me."

### Stage 5 — One button that cycles night vision and thermal vision
Instead of two separate toggles, one press cycles through whichever vision
modes you've left turned on.
**Risk: low-medium.** Slightly different feel from a straight on/off
toggle (press-to-cycle instead of press-to-toggle), worth a heads-up to
your handlers when it ships, not just a silent swap.

**STATUS: done, then undone at your request.** This stage was built
exactly as described above. After trying it, you asked for the two
separate toggles back, so that's what's shipped now: Thermal Vision and
Night Vision are each their own command, their own key (K and J by
default), and their own radial entry again. The one-button cycle from
this stage wasn't thrown away — it's still there as an extra option
(`/k9vision`, default key I) for anyone who prefers it, it just isn't the
only way to reach either mode any more.

### Stage 6 — Leave combat alone, on purpose
Bite-and-hold, non-lethal takedown, and prop dragging **stay as three
separate, explicit actions.** This is the one place I am actively
recommending against merging, even though it would technically cut the
number of buttons: these are the actions where guessing wrong actually
hurts someone else, and your own instinct on "getting a firing wrong
doesn't undo" applies exactly here. Fewer buttons isn't worth it where a
wrong guess isn't reversible.

### Stage 7 — Remove "Scent Trail Hunt"
Covered above in full. Entirely your call, entirely separable from every
other stage — you can take all of stages 1–6 and decline this one with
zero effect on anything else.

## What you're trading away, plainly

- Fewer things to learn and remember, in exchange for a few actions
  (kennel, feeding, fetch, vision) being decided *for* your players by
  context instead of chosen *by* them. For the reversible, low-stakes
  ones (feeding the dog, throwing a ball, entering a kennel) that's a
  clean win. For anything with real consequences for another player
  (combat), I'm recommending you keep the explicit choice.
- One real capability goes away entirely if you approve Stage 7 — a
  hide-and-seek minigame with no other use in the script. Nothing else on
  this list removes a capability; everything else either stays exactly as
  it is or keeps working with one fewer switch to manage.

## What I'm not doing in this plan, and why

- I'm not touching anything yet. This is still just the plan — nothing
  changes until you say go, and you can approve stages piecemeal ("do 1,
  2, and 4, skip 3 for now").
- A couple of pieces of groundwork this plan leans on (a shared way of
  registering third-eye options, so future merges don't re-create the same
  mess; making the "danger warning" bark share code with the regular bark
  system instead of duplicating it) are real, worthwhile follow-ups I'd
  recommend doing before or alongside Stage 4/5, but they touch parts of
  the script other people are actively working in right now, so they're
  not part of this round.
- I'm not making the master switches for each feature group toggleable
  live from the tablet in this round — only from the settings file, with
  a restart. Making a switch that can turn off six things at once safe to
  flip *while the server is running* needs its own confirmation screen in
  the tablet, and that's a bigger, separate piece of work.

## Decisions taken on your behalf

You said: *"Do whatever you need to do your best judgement i trust you."*
Combined with *"Overhaul all the features if they are redudant or have not
much applicable remove it"*, that's enough authority to stop asking and
start. Here's what was decided and why, so you can reverse any of it.

**Stage 7 — Scent Trail Hunt is being removed.** You told me twice to
remove what's redundant, the dependency check came back clean (nothing
else reads it, no database table, no history to lose), and it is a genuine
duplicate of real scent tracking pointed at a made-up spot. The one
argument against — that it's currently the only way a new handler
practises following a trail — is real but thin: they can practise on a
real trail instead. **This is one commit to undo.** If you want it back as
a training drill, say so and it returns under Training rather than next to
real tracking, which is where it should have been all along.

**Stages 1–6 all proceed**, in that order, because they're independent and
the early ones are risk-free. Stage 6 remains a deliberate decision to
change nothing about combat.

**Stages 4 and 5 get the verification pass** before they ship. Merging the
kennel, feeding and fetch options means guessing intent from context, and
guessing wrong on a reversible action is an annoyance rather than a
disaster — but it's still worth ten minutes of checking rather than
shipping on assumption.

Nothing about the two safety promises above changes: nothing currently
switched off turns itself on, and a merged action never grants what the
separate one didn't.

Nothing here has been built yet. Say the word on any of the above and I'll
start.
