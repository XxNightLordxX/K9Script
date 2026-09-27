--[[
    qbx_k9unit/config.lua

    Transcribed verbatim from DEVELOPER_REFERENCE.md §5 ("Config schema (concrete shape)"),
    which is unchanged by the post-draft correction (§1/§2/§4.4/§4.5) — no
    additions or removals beyond what's noted inline below. If DEVELOPER_REFERENCE.md §5
    is revised again, re-diff this file against it before trusting it as
    still in sync.

    HISTORY: an earlier draft of this file added a Config.K9DespawnGraceSeconds
    field for a handler->K9 spawn-registry grace timer. That concept was
    removed entirely once DEVELOPER_REFERENCE.md's post-draft correction established the
    K9 is a player's own persistent character with no spawn/despawn/registry
    at all (see the NOTE further down where that field used to live).
]]

Config = {}

-- ======================================================================
-- FEATURE TOGGLES — every leaf feature independently switchable.
-- The code must gate on these at the point of activation, not just declare
-- them (see §3 acceptance criteria).
-- ======================================================================
-- WHAT IS IN THIS FILE  --  a map, so you can stop scrolling.
--
-- This file is long. It is deliberately ONE file rather than several,
-- because hunting through five config files is worse than scrolling
-- through one. What it was missing is an index. This is it.
--
-- HOW TO USE IT: find the thing you want below, then search this file for
-- the name in `backticks`. No line numbers here on purpose -- they go stale
-- the moment anything is added, and a wrong line number is worse than none.
--
-- ONE TRAP WORTH KNOWING BEFORE YOU EDIT ANYTHING: every field in this
-- file whose name ends in `CooldownMs`. In most FiveM scripts, setting a
-- cooldown to 0 means "no cooldown". **HERE IT DOES NOT.** This resource's
-- cooldown system fails CLOSED on zero or a negative number, which would
-- block the action permanently rather than allow it freely -- the exact
-- opposite of what you would expect.
--
-- You will not break anything by trying: a bad value is now caught at
-- startup, quietly swapped for a sensible built-in number, and a warning
-- naming the exact setting is printed to your server console. But it will
-- never do what "0 = off" does elsewhere.
--
-- There is no value that disables a cooldown. If you genuinely want a
-- mechanic to have none, that is not a cooldown setting -- turn the whole
-- feature off in `Config.Features` instead, or set the cooldown to
-- something very small like 1.
--
-- HEARD A PLAYER SAY "THE DOG'S ENERGY RUNS OUT TOO FAST"? Search this file
-- for `Fatigue` -- that is this resource's own tiredness stat, inside
-- Config.Wellbeing below. If what they actually mean is that the dog cannot
-- SPRINT for as long as they would like, that same block also controls the
-- game's own separate Stamina bar -- search for `nativeStaminaRestorePercent`.
-- Two different systems, deliberately living in the same table; the comments
-- there explain which is which.
--
-- ANOTHER TRAP WORTH KNOWING BEFORE YOU EDIT ANYTHING: a setting that high
-- command has EVER changed from the K9 Command Tablet's Settings screen
-- keeps winning over whatever you type into THIS file, across every future
-- restart, until someone resets that exact setting from the tablet. This
-- file is only the STARTING point the first time a feature or number is
-- ever touched from the tablet; after that, the tablet's saved value is
-- what the server actually uses, and editing config.lua for that one
-- setting again silently does nothing.
--
-- WHY: deliberate, not a bug. It is what lets high command tune the server
-- live without a restart, and it stops a routine config update quietly
-- undoing a change they made on purpose. But it does mean a config.lua edit
-- can look like it "did not work" for a reason that has nothing to do with
-- a typo or a bad value.
--
-- HOW TO TELL: the server console says so at startup. Any setting where a
-- saved tablet change disagrees with this file is named there by name, with
-- both values. You can also open the tablet's Settings screen (high command
-- only) and look at the row itself.
--
-- HOW TO UNDO IT: on that Settings screen, reset that one setting. That
-- removes the saved change and makes config.lua authoritative for it again.
-- No tablet access yourself? Ask whoever holds High Command to reset it.
--
-- THE ONE TO KNOW ABOUT: `Config.Features` is the master list of on/off
-- switches, right below this. Almost every entry there has its own settings
-- table further down with the same name -- turn something on there, then
-- search for its name to tune it.
--
-- TURNING THINGS ON AND OFF  (start here)
--   Config.Features ................. the on/off switch for every single
--                                     feature -- ONE switch each, and this
--                                     is the one that decides
--   Config.FeatureGroups ............ a master cut-off per capability
--                                     family; `enabled = false` forces
--                                     everything in that family off, and
--                                     `true` changes nothing
--
-- WHO CAN DO WHAT
--   Config.Departments .............. which jobs count as police, and the
--                                     rank numbers that unlock things
--   Config.HighCommand .............. the senior rank that outranks every
--                                     other check here
--   Config.Permissions .............. the four things high command can hand
--                                     to one person
--   Config.FeatureControl ........... which features need a personal grant
--                                     before someone can use them
--   Config.CommandTablet ............ the K9 tablet: item, command, or both
--
-- BECOMING AND BEING A K9
--   Config.Peds ..................... which models can be a K9. ANY model
--                                     works -- it does not have to be a dog
--   Config.K9Appearance ............. what happens to someone's character
--                                     when they are made a K9
--   Config.CertificationTiers ....... trainee / certified / senior, and how
--                                     to add more
--   Config.K9Specializations ........ narcotics, explosives, patrol
--   Config.SpecializationTracking ... which of those specializations unlock
--                                     which Track <Type> trail (owner
--                                     decluttering pass, 2026-08-26)
--   Config.AllowSelfCertification ... whether an officer may certify
--                                     themselves
--   Config.CertifyProximityMeters ... how close you must stand to certify
--   Config.CertifyMaxNewGranteesPerDay . the daily cap on how many
--                                     DIFFERENT people one officer can be
--                                     paid handler XP for certifying
--   Config.CertificationExpiryDays .. whether certifications lapse, and the
--                                     warning before they do
--
-- EARNING AND RANKING UP
--   Config.XP ....................... what each action pays (the K9)
--   Config.XPTiers .................. the four K9 ranks and what they unlock
--   Config.HandlerXP ................ what each HANDLER action pays -- a
--                                     separate total from Config.XP, above
--   Config.HandlerXPTiers ........... the handler ranks and what they unlock
--   Config.Leaderboard .............. the /k9stats table
--   Config.CertificationExpiryWarningDays . how long before a certification
--                                     lapses that the handler is warned
--   Config.CertificationExpiryCheckIntervalMs . how often lapses are checked
--
-- THE JOB ITSELF
--   Config.Tracking ................. scent, blood and gunpowder trails
--   Config.WaterTrackingDecay ....... trails going cold in water
--   Config.SearchZones .............. searching vehicles and people
--   Config.SearchContrabandItems .... what counts as a find
--   Config.ContrabandAlertTiers ..... how big a find has to be to matter
--   Config.FindAlerts ............... the dog sitting and barking on a find
--   Config.Combat ................... bite and hold, takedowns, dragging
--   Config.PursuitSprint ............ the short burst of real speed
--   Config.Partnership .............. handler and K9 pairing
--   Config.DoorInteraction .......... scratching at doors
--
-- KIT AND PLACES
--   Config.K9Vehicles ............... which vehicles a K9 can ride in
--   Config.VehicleInteractMeters .... how close to stand to load up
--   Config.LeashMaxDistance ......... how far the leash stretches
--   Config.K9Inventory .............. the dog's own storage
--   Config.K9Medkit ................. patching the dog up
--   Config.K9EquipmentShop .......... the supply shop and its shop dogs
--   Config.K9Identity ............... the dog's name, breed and callsign
--   Config.K9Onboarding ............. what a brand-new handler is walked through
--   Config.K9VehicleRide ............ how the dog rides along
--   Config.LeashVisual .............. what the leash looks like
--   Config.CameraFeed ............... the K9 camera picture-in-picture
--   Config.DeployableKennel ......... putting down a portable kennel
--   Config.PropAttachments .......... vests and gear on the dog
--   Config.FetchMechanic ............ fetch
--
-- LOOK, SOUND AND FEEL
--   Config.Wellbeing ................ tiredness (players may say "energy",
--                                   "stamina" or "sprint"), mood, fear,
--                                   injury. TWO separate energy systems
--                                   live inside this one block: this
--                                   resource's own Fatigue stat, and the
--                                   game's own built-in Stamina bar
--                                   (search this file for
--                                   nativeStaminaRestorePercent). Both are
--                                   explained where they live -- search for
--                                   Fatigue to start.
--   Config.AdvancedBarkRadial ....... the bark menu
--   Config.ProximityAudioFX ......... hearing the dog from a distance
--   Config.ContrabandScreenFX ....... the screen effect on a find
--
-- PLUMBING AND SAFETY
--   Config.Compat ................... auto-detecting which other scripts
--                                     your server runs
--   Config.Database ................. running with or without a database
--   Config.K9DownDispatch ........... announcing a K9 going down
--   Config.AdminAudit ............... the read-only audit commands
--   Config.DiscordWebhook ........... where K9 events are posted (ships off
--                                     until you paste in a URL)
--   Config.DebugDump ................ the /k9debug report (ships off)
--   Config.MaxSpeedScentMultiplier .. the ceiling on per-person speed and
--                                     scent-range boosts
--   Config.MaxStaminaDrainPerTick ... the ceiling on stamina drain
--   Config.BoneSweepTool ............ a developer-only tool; the flag ships
--                                     `true` but stays unreachable without an
--                                     operator-set convar -- see
--                                     Config.Features.BoneSweepDevTool
-- ======================================================================

-- ======================================================================
Config.Features = {
    -- Phase 1 (vertical slice)
    LeashMechanics       = true,
    RadialMenu           = true,
    VehicleEntryExit     = true,
    BasicBarkSounds      = true,
    AgilityBasicJump     = true,  -- native jump/crouch only, no fence-vault logic yet

    -- Phase 2 (tracking & vision)
    ScentTracking        = true,
    BloodTracking        = true,
    WaterTrackingDecay   = true,
    GunpowderSniffing    = true,

    -- client/tracking.lua + server/tracking.lua (owner-directed pass:
    -- "make scent tracking... a keybind that makes a colour dot appear
    -- where players['] blood etc have walked"). A K9 handler presses a
    -- keybind (RegisterKeyMapping, Config.Tracking.ScentVision.keybind) and
    -- sees a live overlay of ground-level coloured dots marking where
    -- OTHER connected players have recently walked -- each dot expires on
    -- its OWN individual timer from the moment it was recorded (never a
    -- whole-trail timer), so a trail visibly eats itself from the tail end
    -- while its fresh end keeps growing. Distinct from Track Scent/Blood/
    -- Gunpowder above (client/tracking.lua's existing Start*Track()
    -- trio): those resolve and walk toward exactly ONE nearest logged
    -- event (a damage hit, a gunshot, an item drop); this instead shows
    -- several people's general walked paths at once, colour-coded per
    -- person so multiple trails through the same area can be told apart.
    -- Server-authoritative throughout: the server samples every connected
    -- player's own position on its own timer (never a value the client
    -- supplies), and a querying K9's client is only ever handed the
    -- nearest HANDFUL of trails within range, pre-coloured, never raw
    -- identity and never the whole server's positions -- see
    -- Config.Tracking.ScentVision below and server/tracking.lua's own
    -- header for the full design (including why "handful", not
    -- "everyone", is also what keeps this cheap on a populated server).
    ScentVision          = true,

    SearchZones          = true,
    ContrabandAlerts     = true,

    -- server/findalert.lua + client/findalert.lua (PROJECT_HISTORY.md §1, "Make
    -- finds feel like a real alert, not a pop-up message"). A pure REACTION
    -- layer over the search outcome server/search.lua already computes --
    -- it adds no detection logic of its own. When a search comes back
    -- positive, the searching K9's own character automatically sits (a real
    -- detection dog's "trained final response") and barks. The text message
    -- you already get is unchanged; this is on top of it, not instead of it.
    FindAlerts           = true,

    -- REMOVED (owner-approved, "Overhaul all the features if they are
    -- redundant... remove it" -- see docs/history/FEATURE_STRUCTURE_SPEC.md §2.2.1 and
    -- docs/history/OVERHAUL_PLAN.md's "Stage 7" for the full reasoning and the
    -- dependency check that cleared it). Was `ScentTrailHunt` ("follow
    -- your nose" -- PROJECT_HISTORY.md §2): the K9 sets off after a hidden, made-up spot,
    -- guided only by a growl that pulses faster as they get warmer.
    -- Judged genuinely redundant, not merely thin: it duplicates
    -- Detection's own "walk toward a fading signal" interaction shape
    -- (see Config.FeatureGroups.Detection below) against a fake
    -- destination instead of a real one, feeds no other system (no XP, no
    -- search/contraband/rescue tie-in), and owns no database table (this
    -- was a live, in-memory session only -- nothing was left behind to
    -- preserve). The files that owned it went away with it, so this key is
    -- absent rather than merely false.
    --
    -- HOW TO BRING THIS BACK, exactly, either flavour:
    --   1. AS-IS: add the line `ScentTrailHunt = true,` back here (or set
    --      it under a Config.FeatureGroups family below, see that table's
    --      own header for how to wire a new key into it).
    --   2. AS A PRACTICE DRILL INSTEAD (the alternative
    --      docs/history/OVERHAUL_PLAN.md offered and the owner may still
    --      take -- a nose-following practice exercise):
    --      same step 1, but add it to STANDALONE_FEATURE_KEYS
    --      instead of Config.FeatureGroups.Detection, and update
    --      server/tablet.lua's FEATURE_DOMAINS entry from 'training' (it
    --      is still there, harmless and unused while this key is absent --
    --      see tests/runtimefeaturetiers_spec.lua's own documented "an
    --      orphaned entry has zero behavioural consequence" guarantee) to
    --      match wherever it actually ends up.
    -- No other file needs editing to remove OR restore this -- this was a
    -- single-key, config-only change on both ends.

    -- client/pursuitsprint.lua + server/pursuitsprint.lua (PROJECT_HISTORY.md §5).
    -- A short burst where the dog is genuinely faster than the person it is
    -- chasing. Only usable against a WANTED target, only in short bursts,
    -- and on a cooldown -- it ends a foot chase, it does not remove them.
    PursuitSprint        = true,


    ThermalVision        = true,
    NightVision          = true,
    DoorInteraction      = true, -- nudge-open / scratch-to-alert

    -- Phase 3 (combat & action)
    BiteAndHold          = true,
    NonLethalTakedown    = true,
    PropDragging         = true,
    AgilityAdvanced      = true, -- fence/window vault approximation


    -- DEVELOPER_REFERENCE.md §12.0 item 7 (Revision 5, coder-architect) /
    -- server/partnership.lua (coder-backend, this pass). Gates the
    -- mutually-consented "Partner Up" registry ONLY. The two features this
    -- registry was originally built to unblock -- handler-down defense and
    -- the recall actor -- were both REMOVED on 2026-09-02 at the owner's
    -- request, so neither exists to gate any more. The registry itself is
    -- still load-bearing: server/tenure.lua reads it for the tenure bonus,
    -- and the tablet reads it to show who is partnered with whom.
    -- DEFAULT ONCE DIVERGED FROM DEVELOPER_REFERENCE.md §12.0 item 7 point 5's
    -- OWN "recommended default true" text -- that was deliberate at the
    -- time, not an oversight: that recommendation predated any real code
    -- existing, and this resource's then-shipped convention for every
    -- other Phase 3 mechanic was that a newly-landed mechanic stays off by
    -- default until its own balance/security go-live review, independent
    -- of implementation completeness. This flag was directed to default
    -- `false` for exactly that reason. That go-live review has SINCE
    -- happened -- see server/partnership.lua's own header for what was
    -- independently verified -- and this flag now ships `true` above,
    -- consistent with BiteAndHold/NonLethalTakedown/PropDragging/
    -- shipping `true` too.
    HandlerPartnership   = true,
    -- ALSO gates the "handler condition badge" (server/wellbeing.lua) --
    -- turning this off means a partnered handler's HUD never shows their
    -- own dog's condition, on top of everything else this flag already
    -- controls.

    -- server/tenure.lua (DEVELOPER_REFERENCE.md Part B §7). Grants a one-time,
    -- flat XP bonus to the K9-role party when a partnership's CONTINUOUS
    -- tenure crosses a configured threshold -- the first gameplay
    -- consequence wired to the HandlerPartnership registry, which landed as
    -- a foundation with none. Has NO effect unless HandlerPartnership AND
    -- XPProgression are ALSO true (server/tenure.lua re-checks both at point
    -- of use). REQUIRES the k9_partnerships.tenure_bonus_tier_granted
    -- column -- present in sql/install.sql for fresh installs, and in
    -- sql/migrations/0003_*.sql for existing databases. Without that column
    -- the milestone bonus would re-grant on every restart; tenure.lua's
    -- queries are pcall-wrapped and degrade to a silent no-op until it
    -- exists, so an un-migrated database is inert rather than exploitable.
    PartnershipTenureBonus = true,

    -- Phase 4 (inventory, progression, vitality)
    K9Inventory          = true,
    XPProgression        = true,

    -- Handler XP: a SEPARATE total from the K9's own XP above, for what the
    -- HANDLER does rather than what the dog does. Its own ladder
    -- (Config.HandlerXPTiers) and its own award table (Config.HandlerXP).
    --
    -- SHIPS ON. Every award key that can be farmed is throttled by a
    -- per-actor mint cooldown that survives a disconnect/reconnect, so this
    -- is safe to leave on -- see DEVELOPER_REFERENCE.md §22 for which key is
    -- capped at what, and the arithmetic behind each number.
    --
    -- TO TURN IT OFF: set this to `false`. That is the whole revert. No data
    -- is lost -- already-earned Handler XP stays in the database and simply
    -- stops accruing. Note that with this off the handler rank ladder is
    -- completely dead (nothing else mints Handler XP) while the tablet still
    -- advertises the ranks.
    HandlerXPProgression = true,

    HealthStaminaHUD     = true,
    FatigueSystem        = true,
    K9Medkit             = true,
    ContrabandScreenFX   = true,


    -- server/admin.lua. A read-only, JOB-RANK-gated in-game audit surface
    -- over the three tables this resource already writes (k9_certifications,
    -- k9_partnerships, k9_search_log) -- five commands, nine hardcoded SQL
    -- templates, zero mutation paths of any kind. Replaces "documented raw
    -- SQL an admin runs by hand" (DEVELOPER_REFERENCE.md Part B item 2). This one
    -- exposes WHO SEARCHED WHOM, so it is a privacy boundary as well as a
    -- security one: set `auditGrade` on each Config.Departments entry below
    -- deliberately. There is no ACE permission to grant -- that gate was
    -- removed on 2026-08-25.
    AdminAuditCommands   = true,

    -- server/integrations.lua. Announces a K9 going down so YOUR dispatch
    -- can react to it. Read-only detection -- it fires a generic
    -- 'qbx_k9unit:events:k9Down' event and nothing more.
    -- Deliberately NOT tied to any particular dispatch resource: this
    -- resource never calls into a named third party, it announces a fact
    -- and anything listening can act on it. A server with no dispatch at
    -- all sees a clean no-op, no errors, no log spam. That is what makes it
    -- work with a custom dispatch as readily as an off-the-shelf one.
    K9DownDispatch       = true,

    -- shared/compat/*.lua. AUTO-DETECT WHAT YOU ACTUALLY RUN. Turn this on
    -- (it is on) and this resource works out which inventory, targeting,
    -- dispatch and ambulance script YOUR server runs, at startup, and talks
    -- to whichever one it finds -- instead of assuming everyone runs the
    -- same handful of scripts. Set it to `false` only if you want to pin
    -- every system by hand in Config.Compat below.
    --
    -- ONE HONEST EXCEPTION: your core FRAMEWORK is detected but not
    -- actually adapted to. This resource requires Qbox and will not run on
    -- qb-core or ESX regardless of what detection reports. The full
    -- explanation is on Config.Compat.Systems.framework further down --
    -- read it before assuming otherwise.
    -- Run /k9compat in game (see Config.Compat.diagnosticCommand) to print
    -- exactly what it found and what it could not find.
    ResourceAutoDetect   = true,
    DiscordWebhook       = false,  -- post K9 events to a Discord channel. Needs a webhook URL set in Config.DiscordWebhook below; does nothing at all until then.

    -- server/leaderboard.lua. The /k9stats command: a ranked list of the
    -- top K9 handlers by XP. PRIVACY NOTE, decide this deliberately: it
    -- shows other people's citizen ids alongside their XP. The audience is
    -- bounded -- only someone who passes the same K9 access check as every
    -- other feature here can run it, not the whole server -- which is why
    -- it ships on. Set it to `false` if you would rather nobody saw anyone
    -- else's numbers, or leave it on and let high command switch it off for
    -- individuals from the tablet.
    K9Leaderboard        = true,


    -- server/equipmentshop.lua + client/equipmentshop.lua. A "K9 Supply"
    -- shop selling the K9 items this resource uses. Without it those items
    -- exist in the code with nowhere on the map to buy them, which is how
    -- the wellbeing system currently ships. The shop itself, and every
    -- price and permission decision in it, lives inside your inventory
    -- script; this resource only registers it and puts a walk-up point on
    -- the map. If Config.K9EquipmentShop below is missing or every item in
    -- it is unknown to your inventory, the shop is simply not registered
    -- and one clear console line says so.
    K9EquipmentShop      = true,

    -- server/highcommand.lua. A senior-rank tier, defined per department by
    -- `highCommandGrade` in Config.Departments, that is exempt from EVERY
    -- other rank check in this resource and can mint XP directly via
    -- /k9givexp. See the Config.HighCommand block below for what it
    -- deliberately does NOT do (run arbitrary server commands) and why.
    -- This is the most powerful switch in this file: it is the only one
    -- that grants an in-game job rank write access to the XP economy.
    HighCommand          = true,

    -- server/permissions.lua. Lets high command grant a NAMED capability
    -- to one specific handler or K9, instead of everything being gated on
    -- job rank alone. Purely additive: grants widen access, never narrow
    -- it, so nothing that works on rank today stops working. See the
    -- Config.Permissions block below for the capability list and the
    -- exact resolution order.
    PermissionGrants     = true,

    -- client/tablet.lua + html/tablet.*. The in-game roster and control
    -- UI for certifications, XP and permission grants. It is a VIEW only
    -- -- every action is re-authorized server-side, so the tablet showing
    -- a button never makes an action allowed.
    CommandTablet        = true,

    -- server/bonetool.lua + client/bonetool.lua. A DEV-SERVER-ONLY sweep that
    -- attaches a marker prop to bone indices in sequence so a human can
    -- visually identify the right one for a quadruped skeleton -- the
    -- question that blocked PropAttachments and FetchMechanic through three
    -- research passes. This flag ALONE does not make the tool reachable: as
    -- of 2026-08-25 it also requires a replicated convar an operator must
    -- set on purpose (`setr qbx_k9unit_enable_bone_dev_tool 1`), and the
    -- caller must be a boss of a configured Config.Departments job. That
    -- second opt-in exists precisely because this flag was once flipped true
    -- alongside 39 others with nothing to distinguish it.
    -- Its real blast radius is narrow -- every effect is local to the
    -- caller's own client (a debug marker, and one non-networked prop on
    -- their own ped), and the server never accepts an entity or netId from
    -- the client -- but it is still a dev tool. Leave the convar unset on a
    -- production server.
    BoneSweepDevTool     = true,
    -- OPERATIONAL CAVEAT, and it matters most for THIS flag specifically.
    -- Nothing in this resource flips a Config.Features.* flag while running:
    -- every feature gates its RegisterCommand/RegisterNetEvent calls ONCE, at
    -- file-load or onResourceStart time. That is deliberate ("gate at
    -- registration, not inside the handler") and it is what makes a disabled
    -- feature genuinely inert rather than merely hidden.
    -- The consequence: turning this flag ON, restarting, then turning it back
    -- OFF does NOT unregister /k9bonetool. It stays reachable until the NEXT
    -- restart. For most features that is harmless. For this one it is not --
    -- it spawns and attaches props on command. RESTART AFTER DISABLING IT.
    -- (The ACE check still applies in that window; this is about not leaving
    -- a dev tool registered on a production server at all.)

    -- Phase 5 (audio/props/advanced vision R&D)
    AdvancedBarkRadial   = true,
    ProximityAudioFX     = true,
    PropAttachments      = true,
    FetchMechanic        = true,
    DeployableKennel     = true,
    -- client/vision.lua. CAMERA FEED — see what your partner sees.
    --
    -- A true picture-in-picture, two live views on screen at once, is
    -- genuinely impossible in FiveM. That was re-confirmed on 2026-08-26 by
    -- enumerating the entire camera namespace (202 calls) plus every
    -- render-target call against the live native list: nothing renders a
    -- camera into a texture. So it was not built, and no amount of asking
    -- will produce it.
    --
    -- What IS built, and works: press a key and your WHOLE screen switches
    -- to your partner's viewpoint, until you press it again. You need an
    -- active partnership. Honest limits, written up in full in
    -- client/vision.lua's own header: the eye height is an approximation
    -- per role rather than read off the skeleton, it follows their body
    -- rather than where they are looking, and it cuts out at normal
    -- streaming range.
    --
    -- Switched ON: real code now exists behind it, gated the same way every
    -- other departmental ability is, and it does nothing at all for someone
    -- with no partner. The name still says PiP for compatibility with
    -- anything referencing it.
    CameraFeedPiP        = true,

    -- server/certifications/. Opt-in periodic recertification: new
    -- grants get an expiry date and lapse unless renewed. OFF by default,
    -- and deliberately so -- but NOT because turning it on is destructive.
    -- It is not: every certification that already exists keeps no expiry
    -- date at all, forever, unless a certifier explicitly renews it. This
    -- comment used to say the opposite -- that switching it on started a
    -- clock retroactively on everyone -- and that was simply wrong, which
    -- would have scared an operator off a safe change. Only NEW grants and
    -- explicit renewals ever get an expiry.
    --
    -- Starting a recertification cadence at all is a policy decision, not
    -- a safety default -- so this shipped off and was left for the owner to
    -- make on purpose. TURNED ON 2026-09-01 at the owner's explicit
    -- instruction ("turn on everything in the config that does not need the
    -- database"). Handlers get warned ahead of expiry; nobody finds out by
    -- an ability silently refusing to work.
    --
    -- READ THIS IF YOU ARE STILL RUNNING WITH Config.Database.enabled =
    -- false: this feature does not REQUIRE the database, and nothing about
    -- it errors without one -- but it cannot do anything visible either.
    -- Certifications live in memory only while the database is off, so they
    -- are wiped by every restart, and Config.CertificationExpiryDays is 90.
    -- Nothing can survive long enough to expire. Switching the database on
    -- is what makes this setting start to matter, and at that point the
    -- 90-day clock becomes real for every NEW grant (never retroactively
    -- for one that already exists).
    CertificationExpiry  = true,

    -- server/runtimecontrol.lua. Lets high command switch features on and
    -- off SERVER-WIDE from the tablet, and tune numbers live, without
    -- editing config.lua or restarting.
    -- READ THE ASYMMETRY BEFORE ENABLING, because it is a genuine engine
    -- constraint and not a bug: every feature in this resource gates its
    -- RegisterCommand and RegisterNetEvent calls ONCE, at load time. That
    -- is what makes a disabled feature genuinely inert instead of merely
    -- hidden. The consequence is that a runtime toggle can reliably turn a
    -- feature OFF (handlers re-check the live value and refuse), but
    -- turning one back ON cannot retroactively register handlers that were
    -- never registered at start -- that needs a restart. The tablet says
    -- so plainly rather than pretending otherwise.
    RuntimeFeatureControl = true,

    -- Lets high command restyle the tablet -- colours, density, header
    -- text -- from inside the tablet itself, saved server-side and applied
    -- for everyone. Cosmetic only: theming can never change what anyone is
    -- authorized to do or see.
    TabletTheming        = true,


}

-- ======================================================================
-- FEATURE GROUPS -- the nested capability tree an operator actually edits
-- day to day. Full design rationale (family boundaries; the four-bucket
-- classification -- real feature / sub-feature / behaviour / removed --
-- of every flag above; why six flags sit outside every parent; the
-- lineup/recall/admin-split reasoning) lives in docs/history/FEATURE_STRUCTURE_SPEC.md
-- -- this comment is the short version, not a duplicate of it.
--
-- HOW THIS WORKS: each capability below has an `enabled` switch. Turning
-- it OFF forces every one of its listed children OFF too, regardless of
-- that child's own value here or Config.Features' own value above -- a
-- parent's `false` always wins (a real, structural effect this pass
-- landed for the first time; the group boundaries drawn a pass earlier,
-- commit d00fd60, were labelling only). Turning a child on/off here
-- OVERRIDES the shipped default in Config.Features above; LEAVING a child
-- out of a family entirely here means "use whatever Config.Features
-- already says for it" -- you never have to list every child just to
-- change one.
--
-- BACKWARD COMPATIBILITY, EXACTLY: delete this whole table (or never add
-- it, e.g. an old copy of this file) and NOTHING below changes -- every
-- flag in Config.Features above is used exactly as written, exactly like
-- every version of this resource before this table existed. A console
-- line at boot says which mode is active. Every value below was chosen to
-- be a NO-OP against Config.Features' own shipped defaults above --
-- tests/featuregroups_spec.lua pins this for every key, including the
-- ones that ship `false` -- so simply adding this table to an
-- existing install changes nothing on its own; only editing a value in it
-- does.
--
-- ADDING A NEW Config.Features KEY LATER: add it to the flat table above
-- as always, THEN add it to exactly one of FEATURE_GROUP_MEMBERS or
-- STANDALONE_FEATURE_KEYS just below this table (whichever family it
-- belongs to, or the standalone list if it genuinely has no parent -- see
-- docs/history/FEATURE_STRUCTURE_SPEC.md §3 for how that call was made for the
-- existing six). tests/featuregroups_spec.lua fails loudly, naming the
-- key, if this step is skipped -- this is deliberate: a feature landing
-- mid-session with no home in this tree is exactly the kind of silent gap
-- this table exists to prevent (this happened for real, once, while this
-- table was being designed).
-- ======================================================================
Config.FeatureGroups = {
    -- ONE MASTER SWITCH PER CAPABILITY FAMILY. That is all this table holds.
    --
    -- It used to also carry a duplicate on/off slot for every individual
    -- feature, so 36 of the 49 features in Config.Features above were
    -- controlled from TWO places that had to agree -- and when they
    -- disagreed, this table won, silently, with no error and no console
    -- line. That is not a hypothetical: Config.Features.HandlerXPProgression
    -- was set to `true` while this table said `false`, and the entire
    -- handler rank ladder was dead -- no XP, no rank-ups -- while config.lua
    -- said in plain sight that it was switched on. Thirteen of those
    -- duplicate slots were also spelled DIFFERENTLY from the feature they
    -- controlled (`HUD` for HealthStaminaHUD, `Blood` for BloodTracking,
    -- and so on), so searching this file for a feature's real name found
    -- the switch that did nothing and missed the switch that decided.
    --
    -- The duplicate slots are gone (2026-09-02, at the owner's request).
    -- Config.Features above is now the ONE place a feature is turned on or
    -- off, and this table only answers a different question: "is this whole
    -- capability available at all?"
    --
    -- HOW A FAMILY SWITCH BEHAVES. `enabled = false` forces every feature in
    -- that family off, whatever Config.Features says, and says so in the
    -- server console at boot by name. `enabled = true` changes nothing --
    -- each feature keeps exactly the value you gave it above. So this is a
    -- one-way master cut-off, never a second opinion.
    --
    -- Which features belong to which family is defined once, in
    -- FEATURE_GROUP_MEMBERS below, and never hand-maintained here.
    Detection    = { enabled = true }, -- scent tracking and everything built on it (blood, gunpowder, water decay, scent vision)
    Search       = { enabled = true }, -- searching vehicles and people, and the alerts a find produces
    Sensory      = { enabled = true }, -- night vision, thermal, the camera feed, proximity audio
    Combat       = { enabled = true }, -- bite and hold, non-lethal takedowns, dragging, pursuit sprint
    Movement     = { enabled = true }, -- leash, barks, agility, vehicle entry, door scratching
    Wellbeing    = { enabled = true }, -- fatigue, the health/stamina HUD, K9-down dispatch, the medkit
    Progression  = { enabled = true }, -- K9 XP, handler XP, certification expiry, the leaderboard
    Partnership  = { enabled = true }, -- handler/K9 pairing and the tenure bonus
    Gear         = { enabled = true }, -- inventory, the equipment shop, deployable kennels, prop attachments
    Tablet       = { enabled = true }, -- the command tablet, its live feature control and its theming
    Integrations = { enabled = true }, -- the Discord webhook and resource auto-detection
}

-- ======================================================================
-- FEATURE GROUPS RESOLVER -- narrows Config.Features (above) using
-- Config.FeatureGroups (also above). Runs exactly once, synchronously, at
-- the ResolveFeatureGroups() call immediately below this comment block --
-- every other file in this resource is loaded by fxmanifest.lua AFTER
-- config.lua finishes running top to bottom, so every other file only
-- ever observes the FINAL, resolved Config.Features, never an
-- intermediate state.
--
-- CLAMP AND WARN ON ANYTHING MALFORMED. NEVER ASSERT: one family's typo
-- must never take down every other feature in this resource. Every
-- malformed shape below prints one line naming the exact table/field and
-- this file, then falls back to the safest available value (the family's
-- own existing Config.Features value, or `true`/on for a missing
-- `enabled`) and keeps going.
--
-- `ResolveFeatureGroups`, `GetFeatureGroupFamily`, `IsStandaloneFeatureFlag`,
-- and `IsFeatureGroupParentEnabled` are deliberately GLOBAL (no `local`),
-- an intentional, commented exception to this codebase's usual "don't
-- export a local just for a test to poke at" convention (see
-- tests/tabletfeaturedomains_spec.lua's own header for that convention
-- stated in full) -- both have a REAL production caller beyond the test
-- suite: server/runtimecontrol.lua calls IsFeatureGroupParentEnabled to
-- refuse a tablet override that a disabled parent would make inert (see
-- that file's own "PARENT-OFF REFUSES CHILD-ON" section), and
-- ResolveFeatureGroups/GetFeatureGroupFamily are the two hooks
-- tests/featuregroups_spec.lua uses to prove the drift guard, the no-op-
-- on-defaults pin, and the clamp-and-warn behaviour all actually work
-- against the REAL function, not a hand-typed duplicate of it.
-- ======================================================================
--- Which features belong to which capability family. The ONLY place this is
--- written down. Each family lists its member Config.Features keys by their
--- REAL names -- there are no nicknames here any more, because there is no
--- second on/off slot for a nickname to label.
---
--- `base` is the one special member: a family whose `enabled` switch IS that
--- feature (turning Detection off IS turning ScentTracking off). A family
--- without a `base` -- Sensory, Combat, Integrations -- is an ordinary
--- supported shape; its `enabled` switch simply sits above its members
--- without being any one of them.
local FEATURE_GROUP_MEMBERS = {
    Detection    = { base = 'ScentTracking', 'BloodTracking', 'GunpowderSniffing', 'WaterTrackingDecay', 'ScentVision' },
    Search       = { base = 'SearchZones', 'ContrabandAlerts', 'FindAlerts', 'ContrabandScreenFX' },
    Sensory      = { 'NightVision', 'ThermalVision', 'CameraFeedPiP', 'ProximityAudioFX' },
    Combat       = { 'BiteAndHold', 'NonLethalTakedown', 'PropDragging', 'PursuitSprint' },
    Movement     = { base = 'LeashMechanics', 'BasicBarkSounds', 'AdvancedBarkRadial', 'AgilityBasicJump', 'AgilityAdvanced', 'VehicleEntryExit', 'DoorInteraction' },
    Wellbeing    = { base = 'FatigueSystem', 'HealthStaminaHUD', 'K9DownDispatch', 'K9Medkit' },
    Progression  = { base = 'XPProgression', 'HandlerXPProgression', 'CertificationExpiry', 'K9Leaderboard' },
    Partnership  = { base = 'HandlerPartnership', 'PartnershipTenureBonus' },
    Gear         = { base = 'K9Inventory', 'K9EquipmentShop', 'DeployableKennel', 'PropAttachments' },
    Tablet       = { base = 'CommandTablet', 'RuntimeFeatureControl', 'TabletTheming' },
    Integrations = { 'DiscordWebhook', 'ResourceAutoDetect' },
}

local STANDALONE_FEATURE_KEYS = {
    'HighCommand', 'PermissionGrants', 'AdminAuditCommands', 'BoneSweepDevTool', 'RadialMenu',
    -- FetchMechanic was the sole member of a `Training` family until
    -- 2026-09-02. With family switches reduced to a one-way cut-off, a
    -- family holding exactly one feature is just a second switch that does
    -- the same job as the first -- so the family is gone and fetch is
    -- turned on or off in Config.Features like any other standalone
    -- feature. (The family's other members were removed earlier at the
    -- owner's request; that is what left it with one.)
    'FetchMechanic',
}

-- Reverse index (flat Config.Features name -> family name), built once
-- below, right after FEATURE_GROUP_MEMBERS -- never hand-maintained
-- separately from it, so the two can never drift apart.
local FLAT_KEY_TO_FAMILY = {}
for familyName, members in pairs(FEATURE_GROUP_MEMBERS) do
    if members.base then FLAT_KEY_TO_FAMILY[members.base] = familyName end
    for _, flatName in ipairs(members) do
        FLAT_KEY_TO_FAMILY[flatName] = familyName
    end
end

--- @param flatName string -- a Config.Features key
--- @return string? -- the Config.FeatureGroups family name it belongs to, or nil if it is standalone (see IsStandaloneFeatureFlag) or genuinely unrecognized
function GetFeatureGroupFamily(flatName)
    return FLAT_KEY_TO_FAMILY[flatName]
end

--- @param flatName string -- a Config.Features key
--- @return boolean
function IsStandaloneFeatureFlag(flatName)
    for _, key in ipairs(STANDALONE_FEATURE_KEYS) do
        if key == flatName then return true end
    end
    return false
end

--- Whether `flatName`'s own parent capability, if it has one, currently
--- resolves `enabled`. A flag with no parent (standalone, or genuinely
--- unrecognized) always reports true here -- there is nothing to be
--- blocked BY. Also true whenever Config.FeatureGroups itself is absent
--- (old flat shape -- there is no parent concept to consult at all) or the
--- family entry is malformed (already clamped to "on" by
--- ResolveFeatureGroups itself, so this stays consistent with that).
--- @param flatName string
--- @return boolean
function IsFeatureGroupParentEnabled(flatName)
    local family = GetFeatureGroupFamily(flatName)
    if not family then return true end
    if type(Config.FeatureGroups) ~= 'table' then return true end
    local familyTable = Config.FeatureGroups[family]
    if type(familyTable) ~= 'table' then return true end
    return familyTable.enabled ~= false
end

-- The flat-versus-grouped disagreement reporter that used to live here is
-- GONE, along with the disagreement it reported. Config.FeatureGroups no
-- longer carries a second on/off value for any feature, so there is nothing
-- left that can quietly say something different from Config.Features. The
-- bug class it existed to surface cannot occur any more.


--- Runs the resolution described in this section's own header comment.
--- Safe to call more than once (tests do; production calls it exactly
--- once, below). Genuinely idempotent against its own prior output --
--- re-running it against an unchanged Config.FeatureGroups reproduces the
--- same Config.Features values, never compounds -- because every
--- "not overridden here" default below is read from
--- Config.FeaturesBeforeGrouping (captured ONCE, on the first call ever,
--- and never overwritten again), NOT from Config.Features' own live,
--- already-narrowed value. Reading the live value instead would be a real
--- bug, not a style choice: a second call, after a family's `enabled` had
--- been flipped false then back to true between calls, would find its
--- unset children already forced false by the FIRST call with nothing left
--- to recover the true original default from, silently losing it forever
--- rather than genuinely re-resolving.
function ResolveFeatureGroups()
    -- Snapshot Config.Features EXACTLY as authored above, before any
    -- narrowing -- but ONLY ONCE, ever (the `if` guard below), so a
    -- second-or-later call can never capture an already-narrowed value as
    -- if it were the original. Real use beyond the test suite: an operator
    -- can inspect this table to see what Config.Features would be with
    -- every family switch ignored, without editing anything.
    if type(Config.FeaturesBeforeGrouping) ~= 'table' then
        Config.FeaturesBeforeGrouping = {}
        for key, value in pairs(Config.Features) do
            Config.FeaturesBeforeGrouping[key] = value
        end
    end

    if type(Config.FeatureGroups) ~= 'table' then
        print('[qbx_k9unit] config.lua: Config.FeatureGroups not found -- every family is treated as enabled and Config.Features is used exactly as authored.')
        return
    end

    for familyName, members in pairs(FEATURE_GROUP_MEMBERS) do
        local family = Config.FeatureGroups[familyName]
        if family ~= nil and type(family) ~= 'table' then
            print(('[qbx_k9unit] config.lua: Config.FeatureGroups.%s is not a table (got %s) -- treating this family as enabled, so Config.Features keeps the values you authored. Fix Config.FeatureGroups.%s in config.lua.'):format(familyName, type(family), familyName))
            family = nil
        end

        -- Also the correct value when the family is omitted entirely: "not
        -- mentioned" means "on, nothing overridden", never "off".
        local enabled = true
        if family ~= nil then
            if family.enabled == nil then
                enabled = true
            elseif type(family.enabled) ~= 'boolean' then
                print(('[qbx_k9unit] config.lua: Config.FeatureGroups.%s.enabled is not a boolean (got %s) -- using true. Fix Config.FeatureGroups.%s.enabled in config.lua.'):format(familyName, type(family.enabled), familyName))
                enabled = true
            else
                enabled = family.enabled
            end
        end

        -- A family switch is a ONE-WAY CUT-OFF. enabled = true changes
        -- nothing at all -- every member keeps exactly the value authored in
        -- Config.Features. Only `false` does anything, and when it does, it
        -- names every feature it took down, by name, in the server console.
        if not enabled then
            local forcedOff = {}

            local function narrow(flatName)
                if Config.Features[flatName] == true then
                    forcedOff[#forcedOff + 1] = flatName
                end
                Config.Features[flatName] = false
            end

            if members.base then narrow(members.base) end
            for _, flatName in ipairs(members) do narrow(flatName) end

            if forcedOff[1] then
                table.sort(forcedOff)
                print(('[qbx_k9unit] config.lua: Config.FeatureGroups.%s.enabled is false, so the following features are OFF no matter what Config.Features says: %s. This is not a bug; it is what a family switch does. Set Config.FeatureGroups.%s.enabled = true if any of these should be reachable.'):format(familyName, table.concat(forcedOff, ', '), familyName))
            end
        end
    end
end

ResolveFeatureGroups()

-- ======================================================================
-- PED ROSTER — extensible, no code changes needed to add a streamed model.
--
-- ANY ped model works here. Nothing in this resource assumes a dog: every
-- check is a hash lookup against this list, so a custom streamed model --
-- a K9 pig, a bear, whatever your server streams -- is as valid as
-- a_c_shepherd. The ONLY requirement is that the model actually exists on
-- your server, streamed by some resource, before someone is assigned it.
--
-- Each entry may carry an optional `label`, which is what an officer sees
-- in the K9 Command Tablet when choosing a model. Without one the tablet
-- shows the raw model name, which is functional but ugly for a custom ped.
-- ======================================================================
-- Each entry may also carry an optional `speedMultiplier`, scaling how fast
-- that breed moves. Leave it out and the ped runs at a neutral 1.0 -- the
-- code reads it defensively, so an entry without it is not a bug. The
-- spread below is deliberately small: these are flavour, not a power
-- ranking. A number far above 1.0 turns breed choice into a required pick
-- rather than a preference, which is the opposite of what a roster is for.
-- ======================================================================
-- CERTIFICATION TIERS (Config.CertificationTiers) -- server/certtiers.lua.
--
-- The ranks WITHIN a K9 certification: trainee, certified, senior. High
-- command can add more, rename them, reorder them, and change what each
-- one grants -- from inside the K9 Command Tablet, while the server is
-- running. What is below is only the STARTING POINT. Anything high command
-- changes in the tablet is saved to the database and wins over this list.
--
-- DO NOT DELETE OR RENAME THESE THREE KEYS. Every certification already in
-- your database holds one of these three words. Changing them here would
-- orphan those records. Add new tiers freely; leave these three alone.
--
-- `capabilities` is empty on purpose, and as of 2026-08-26 that emptiness is
-- load-bearing rather than cosmetic. TWO capabilities now gate real mechanics:
-- ticking `bite_hold_and_takedown` on a tier means ONLY handlers in that tier
-- can bite or take down, and `specializations_eligible` means only that tier
-- can be given specializations. The other three gate nothing and say so.
--
-- Nothing is enforced until you tick the first box for a given capability. So
-- leaving these empty keeps every existing handler exactly as they are today
-- — and ticking one is a real restriction on everyone NOT in that tier, not a
-- preference. An operator who never opens the tablet sees no change at all.
-- ======================================================================
Config.CertificationTiers = {
    { key = 'trainee',   label = 'Trainee',   ordinal = 1, capabilities = {} },
    { key = 'certified', label = 'Certified', ordinal = 2, capabilities = {} },
    { key = 'senior',    label = 'Senior',    ordinal = 3, capabilities = {} },
}

Config.Peds = {
    { model = 'a_c_shepherd',   speedMultiplier = 1.00 },
    { model = 'a_c_rottweiler', speedMultiplier = 0.98 },
    { model = 'a_c_husky',      speedMultiplier = 1.03 },
    { model = 'a_c_chop',       speedMultiplier = 1.00 },
    -- Example custom streamed model (requires the model to exist in a
    -- streamed resource elsewhere on the server; adding this line is the
    -- *only* change needed to make it selectable):
    -- { model = 'a_c_k9_malinois', label = 'Belgian Malinois' },
    --
    -- A custom model does not have to be a dog. This is a real, supported
    -- configuration -- the resource never checks the species:
    -- { model = 'a_c_pig', label = 'K9 Pig' },
}

-- ======================================================================
-- K9 APPEARANCE — what happens to a player's own character when they are
-- made a K9.
--
-- Until now this resource only ever DETECTED whether someone was already
-- playing a K9 model; it never set one. With this on, making someone a K9
-- actually turns their character INTO the ped, and revoking turns them
-- back. "Making someone a K9" is: the tablet's Certify with a breed picked
-- (instead of "Handler"), or Assign K9 Role, or a k9.access grant.
-- Certifying a HANDLER never changes how they look.
--
-- THIS CHANGES A PLAYER'S CHARACTER, so it is worth understanding before
-- switching it on:
--   * The change is server-authoritative. A client cannot make itself a
--     K9; it asks, and the server decides from the same certification and
--     permission checks everything else in this resource uses.
--   * It persists. The assignment is stored against the citizenid, so a
--     relog, a crash or a server restart brings them back as the K9 --
--     otherwise every K9 would silently turn back into a person on the
--     next disconnect.
--   * The player's ORIGINAL appearance is recorded before the swap, so
--     revoking restores what they actually looked like rather than a
--     default. If that record is missing (an install where someone was
--     already a K9 before this feature existed), revoking falls back to a
--     configured model rather than leaving them stuck as an animal.
-- ======================================================================
Config.K9Appearance = {
    -- Master switch. With this false the resource behaves exactly as it did
    -- before: it detects K9 models but never assigns one, and an operator
    -- handles appearance through whatever character system they already run.
    applyPedModelOnCertify = true,

    -- DOES HOLDING THE K9 ROLE REQUIRE BEING A K9 MODEL?
    --
    -- false (the default) decouples the two completely: the K9 ROLE is an
    -- assignment the server holds against a citizenid, and the ped model is
    -- just what that character happens to look like. Someone on a model
    -- that is not in Config.Peds -- including an ordinary human ped, or a
    -- custom one you never listed -- can still be given the K9 role and use
    -- every K9 ability.
    --
    -- Why this is the default: the model check was only ever a convenience,
    -- and tying a role to an appearance breaks the moment someone uses a
    -- character system this resource does not control, streams a model that
    -- was not on the list, or is mid-swap when a check runs. The role is
    -- the fact; the model is cosmetic.
    --
    -- true restores the older, stricter behaviour: only a configured K9
    -- model may hold the role. Use it if you want the appearance to be the
    -- enforcement, and accept that anyone on an unlisted model is locked
    -- out until you add it to Config.Peds.
    --
    -- Either way this is a CONVENIENCE gate, never a security one. Every
    -- server-side action re-checks certification and permissions
    -- independently of what anyone looks like.
    requireK9ModelForRole = false,

    -- Whether the assignment survives a relog. Almost always true -- with
    -- it false a K9 reverts to their normal character on every disconnect,
    -- which reads as the feature being broken.
    persistAcrossSessions = true,

    -- Whether revoking a certification restores the player's previous
    -- appearance. Leaving this false strands them as an animal with no way
    -- back, so turn it off only if your own character system takes over
    -- that job.
    restoreOriginalPedOnRevoke = true,

    -- Fallback model used ONLY when someone's original appearance was never
    -- recorded and cannot be restored. Set it to something harmless that
    -- definitely exists on your server.
    fallbackHumanModel = 'a_m_m_business_01',

    -- How long to wait for a model to stream in before giving up, in ms.
    -- A custom addon ped can be slower to load than a vanilla one. On
    -- timeout the swap is abandoned and the player is left as they were --
    -- never half-applied, and never stuck invisible.
    modelLoadTimeoutMs = 10000,
}

-- ======================================================================
-- K9 IDENTITY — makes a K9 recognisable to the people standing near it.
--
-- Right now a K9 is just a dog to anyone who isn't already in on it OOC —
-- other players see a dog, and this resource's own targeting menu never
-- said whose dog it was. With this on, an officer who targets a K9 gets an
-- "Identify K9" option: it shows the character's own name, their callsign
-- if the K9 Command Tablet roster has given them one, and (optionally)
-- their partnered handler's name.
--
-- WHAT THIS NEVER SHOWS, on purpose: health, fatigue, mood/fear, what the
-- K9 is certified to detect, or anyone's position. This is an identity
-- check, not a status readout — see server/appearance.lua's own
-- k9Identity callback for the exact, narrow payload shape.
--
-- SERVER-RESOLVED, the same as everything else in this file: the name and
-- callsign shown always come from the server's own records for whoever is
-- actually standing there, never from the viewer's or the K9's own client.
-- It also only ever works on a K9 you can already see and are standing
-- next to — this is not a way to locate a K9 anywhere else on the map.
-- ======================================================================
Config.K9Identity = {
    -- Master switch. Set this false if you don't want K9s identifiable
    -- this way at all — everything else in this resource keeps working
    -- exactly the same either way.
    enabled = true,

    -- Also show the K9's partnered handler's name, when they have one.
    -- Turn this off to show only the K9's own name/callsign.
    showHandlerName = true,
}

-- ======================================================================
-- DEPARTMENTS — admin-editable list of job names with K9 access, plus the
-- rank threshold required to grant/revoke certifications for that job.
-- ======================================================================
Config.Departments = {
    ['police'] = {
        label           = 'Los Santos Police Department',
        certifierGrade  = 4,    -- job.grade.level required to grant/revoke certs (job.isboss always qualifies too)
        -- job.grade.level required to run the read-only /k9audit* commands.
        -- These were ACE-gated until 2026-08-25 and are now gated on police
        -- rank instead, at the project owner's request: auditing K9
        -- certifications is a senior-officer function, not a server-admin
        -- one. Set at or above certifierGrade -- someone trusted to grant a
        -- certification should be able to see who holds one. job.isboss
        -- always qualifies, same as certifierGrade.
        auditGrade      = 4,
        -- HIGH COMMAND. A caller at or above this grade -- job.isboss also
        -- always qualifies -- BYPASSES EVERY OTHER RANK GATE IN THIS
        -- RESOURCE: certifierGrade, auditGrade, the bone dev tool's
        -- boss-only check, and the K9 certification requirement itself. It
        -- is the single "senior command can do anything this resource
        -- offers" switch, and it is what unlocks /k9givexp.
        --
        -- SET THIS DELIBERATELY, AND HIGHER THAN auditGrade. Unlike every
        -- other threshold here it grants WRITE power over the economy: a
        -- high command officer can mint XP out of nothing. Every use is
        -- logged to the server console with who granted what to whom.
        --
        -- nil disables the tier entirely for this department. nil means
        -- "no such rank exists here", NEVER "everybody qualifies" -- the
        -- check fails closed on a nil, a non-number, or a malformed grade.
        --
        -- THE NUMBER MUST EXIST ON YOUR OWN RANK LADDER. This used to
        -- default to 6, and a stock qbx_core police job only goes up to
        -- grade 4 -- so on a default install NO numeric grade qualified and
        -- the only thing getting anyone in was the job.isboss bypass just
        -- below. It looked configured and did nothing. Check your own
        -- qbx_core jobs file for the highest grade your department has, and
        -- set this to the rank you actually mean.
        --
        -- ANYONE FLAGGED job.isboss ALWAYS QUALIFIES, whatever this says.
        -- That is deliberate and it is what stops a brand-new server
        -- locking its own owner out on the first boot -- but do not rely on
        -- it as your only route in, because a senior officer who is not
        -- flagged isboss would then have no way to reach this tier at all.
        highCommandGrade = 4,
        -- job.grade.level required to RECEIVE non-compliance alerts (a K9's
        -- target resisting or fleeing). Deliberately a separate, much lower
        -- bar than auditGrade: an audit pull exposes who searched whom and
        -- is a privacy boundary, whereas this alert carries no
        -- citizen-identifying data at all -- just a source id and a speed or
        -- displacement number. It is closer to a dispatch broadcast than to
        -- a records lookup, so it defaults to 0, meaning every sworn member
        -- of a configured department sees them. job.isboss always qualifies.
        -- nil disables the alerts entirely for this department; it never
        -- means "everybody".
        nonComplianceAlertGrade = 0,
        autoAccessGrade = nil,  -- nil = no auto-bypass; set an integer to let that grade+ skip certification (see §4.1 assumption)
    },
    ['sheriff'] = {
        label           = 'Blaine County Sheriff',
        certifierGrade  = 3,
        auditGrade      = 3,
        highCommandGrade = 4, -- see police.highCommandGrade above -- and check this number exists on YOUR ladder
        nonComplianceAlertGrade = 0, -- see police.nonComplianceAlertGrade above
        autoAccessGrade = nil,
    },
    ['bcso'] = {
        label           = 'Blaine County Sheriff (legacy job name)',
        certifierGrade  = 3,
        auditGrade      = 3,
        highCommandGrade = 4, -- see police.highCommandGrade above -- and check this number exists on YOUR ladder
        nonComplianceAlertGrade = 0, -- see police.nonComplianceAlertGrade above
        autoAccessGrade = nil,
    },

    -- ADDED 2026-08-31 at the owner's request: this server runs a `fib`
    -- job alongside police and bcso. Without an entry here, EVERY K9 gate
    -- refuses that job -- IsEligibleCertifier, High Command, and the
    -- tablet all test `Config.Departments[job.name]` first -- so a fib
    -- officer sees a resource that appears completely dead. Grades are
    -- copied from bcso; change them to match your real fib rank ladder.
    ['fib'] = {
        label           = 'Federal Investigation Bureau',
        certifierGrade  = 3,
        auditGrade      = 3,
        highCommandGrade = 4, -- see police.highCommandGrade above -- and check this number exists on YOUR ladder
        nonComplianceAlertGrade = 0, -- see police.nonComplianceAlertGrade above
        autoAccessGrade = nil,
    },
}

-- ======================================================================
-- HIGH COMMAND (Config.Features.HighCommand) -- server/highcommand.lua.
--
-- What it is: a single senior-rank tier, defined per department by
-- `highCommandGrade` above, that is exempt from every other rank check in
-- this resource and can additionally mint XP directly.
--
-- WHAT IT DELIBERATELY IS **NOT**: a way to run arbitrary server commands.
-- "High command can run any command" was requested, and within this
-- resource that is exactly what this delivers -- every qbx_k9unit command
-- and every gated action becomes available. It stops at this resource's
-- boundary on purpose. A generic passthrough that let an in-game job rank
-- execute arbitrary server commands would turn a promotion into full
-- server control across EVERY resource installed, including ACE and
-- permission management -- so one social-engineered promotion, or one
-- compromised officer account, would own the server with no way to walk
-- it back. That is a server-admin capability (txAdmin, ACE) and it should
-- stay one. If you want it anyway it is your server and your call -- say
-- so and it can be added, but it should be a deliberate decision rather
-- than a side effect of a rank number.
-- ======================================================================
Config.HighCommand = {
    -- Max XP a single /k9givexp invocation may grant. This is a typo
    -- guard, not a trust boundary -- high command is already trusted, but
    -- an accidental extra zero should not silently mint a fortune. Raise
    -- it if your progression curve is larger; a non-positive or
    -- non-number value here disables the command rather than meaning
    -- "unlimited", matching this resource's fail-closed convention.
    maxXpPerGrant = 5000,

    -- Anti-fat-finger cooldown between grants from the same officer, in ms.
    -- Deliberately short: this is not a rate limit against abuse (high
    -- command is trusted by definition), it is protection against a held
    -- key or a double-submitted chat line.
    grantCooldownMs = 1500,

    -- Whether high command may grant XP to THEMSELVES. OWNER DECISION:
    -- "High command can grant anything they want to themselves -- xp
    -- promotions permissions etc" -- so this now DEFAULTS TRUE, matching
    -- Config.FeatureControl.allowHighCommandSelfGrant below (self-grant of
    -- a permission/feature/block entry), which this pass also widened and
    -- defaults true. The self-grant is never invisible either way:
    -- server/highcommand.lua audits every '/k9givexp' invocation with an
    -- explicit `self_grant=true/false` field naming the SAME citizenid as
    -- both granter and recipient whenever it fires, so "high command gave
    -- themselves XP" is always a distinguishable, greppable line, not a
    -- silent mint. Set this to `false` if your server wants the STRICTER,
    -- pre-owner-decision behaviour back -- a self-grant is the one case
    -- with no second person in the audit trail, and some operators may
    -- still want a peer to be the one who presses the button even though
    -- nothing stops that peer from being asked. Read as `~= false`
    -- wherever this is consulted, never `x or default`, so an explicit
    -- `false` is never misread as "not set".
    allowSelfGrant = true,
}

-- ======================================================================
-- GRANTABLE PERMISSIONS (Config.Features.PermissionGrants) --
-- server/permissions.lua.
--
-- The problem this solves: until now every capability in this resource
-- was gated on JOB RANK alone. That works for "all sergeants may certify"
-- but not for "this one officer may certify, and nobody else at their
-- rank may". High command can now grant a named permission to a specific
-- person -- a handler OR a K9, since both are just citizenids -- and
-- revoke it later, with the whole history recorded.
--
-- HOW A CAPABILITY CHECK RESOLVES, in order. First match wins:
--   1. an active, explicitly granted permission for that citizenid  -> ALLOW
--   2. the caller is high command (Config.Departments highCommandGrade) -> ALLOW
--   3. the caller meets the legacy rank gate (certifierGrade etc.)   -> ALLOW
--   4. otherwise                                                     -> DENY
-- This is purely ADDITIVE. Nothing that works on rank today stops
-- working; grants only ever widen access, never narrow it. If you want
-- to take a capability away from someone who qualifies by RANK, change
-- their rank -- revoking a grant they never had does nothing, and the
-- UI says so rather than pretending it worked.
--
-- Keys are the capability names. Do not rename one after granting it:
-- the grant rows store this string, so a rename silently orphans every
-- existing grant. Add a new key and migrate instead.
-- ======================================================================
Config.Permissions = {
    -- The label is what a non-technical officer sees in the tablet, so
    -- write it as a sentence about what the person can DO.
    ['k9.access']  = { label = 'Use K9 abilities',              description = 'Equivalent to holding a K9 certification. Grant this to let someone work as a K9 without going through a certifying officer.' },
    ['k9.certify'] = { label = 'Certify and decertify others',  description = 'Grant and revoke K9 certifications. Normally requires a senior rank; this hands it to one specific person.' },
    ['k9.audit']   = { label = 'View the audit records',        description = 'Run the read-only audit commands. PRIVACY-SENSITIVE: this reveals who searched whom, and when.' },
    ['k9.givexp']  = { label = 'Grant XP',                      description = 'Award XP directly to a K9 or handler. This mints economy value -- every use is logged.' },
}

-- ======================================================================
-- PER-PERSON FEATURE CONTROL --
--
-- The four capabilities above are about ADMIN powers. This block is about
-- the K9 abilities themselves: high command can turn an individual
-- feature on or off for ONE specific K9 or handler, rather than only
-- globally for the whole server.
--
-- HOW A FEATURE RESOLVES FOR A GIVEN PERSON. First match wins:
--   1. Config.Features.<Name> is false      -> DENY, always, no exceptions
--   2. an explicit BLOCK row for them       -> DENY
--   3. <Name> is listed in RequireGrant     -> ALLOW only if they hold a grant
--   4. otherwise                            -> ALLOW
--
-- Step 1 is deliberately absolute. A per-person grant can NEVER switch on
-- something an operator turned off server-wide: if the global flag is
-- false the code behind it may not even be registered, so "granting" it
-- would produce a button that silently does nothing. Global off means off.
--
-- Step 2 exists because "disable it for this one person" is a real need
-- (a handler under review, a K9 abusing a mechanic) and is NOT the same
-- as revoking a grant. Revoking only removes a grant they were given;
-- a block overrides everything below it, including step 4's default-allow.
--
-- Grants and blocks live in the same k9_permissions table as the
-- capabilities above, keyed `feature.<Name>` and `block.<Name>` -- so they
-- inherit the same audit trail, the same one-active-row-per-key
-- guarantee, and the same revoke-never-delete rule for free.
-- ======================================================================
Config.FeatureControl = {
    -- Features that need an explicit per-person grant even when their
    -- global flag is on. Anything not listed here stays available to
    -- everyone, which is the behaviour before this feature existed --
    -- so an empty table changes nothing.
    --
    -- HOW TO ACTUALLY GRANT ONE OF THESE: normally the K9 tablet (below).
    -- If Config.Features.CommandTablet is off, or Config.CommandTablet.openMode
    -- is 'item' with no chat-command fallback, the tablet cannot do this --
    -- but everything listed here can STILL be granted/revoked with the
    -- '/k9grantpermission [citizenid] [permissionKey]' and
    -- '/k9revokepermission [citizenid] [permissionKey]' chat commands
    -- (server/permissions.lua), which require the exact same High Command
    -- authorization the tablet does and work regardless of the tablet's
    -- own on/off state. A startup warning (also server/permissions.lua)
    -- names the affected features and points at these commands whenever
    -- both conditions above are true at once.
    --
    -- SHIPS EMPTY, ON PURPOSE: a K9 that high command has made a K9 can use
    -- every ability straight away. Before, bite & hold, takedown, dragging,
    -- pursuit sprint, find alerts and the audit commands were all listed
    -- here, so every new K9 needed up to six separate per-person grants
    -- before they could do their job -- and nothing told them why the keys
    -- did nothing.
    --
    -- Taking an ability away from ONE person does not need this list: block
    -- it for them from their record on the tablet. That works whatever is
    -- (or is not) listed here.
    --
    -- Want "only the people I hand it to" for something? Add it back, one
    -- line each -- the names are the Config.Features keys:
    --     BiteAndHold = true,
    --     NonLethalTakedown = true,
    --     PropDragging = true,
    --     PursuitSprint = true,
    --     FindAlerts = true,
    --     AdminAuditCommands = true,
    RequireGrant = {},

    -- Whether high command can grant permissions to THEMSELVES. Ships on,
    -- at the owner's request.
    --
    -- This only changes what someone who is ALREADY high command may do to
    -- their own record -- it can never make anyone high command, and every
    -- self-grant is written to the audit log marked `self=true`, naming the
    -- same person as both granter and recipient.
    --
    -- SET IT TO false for stricter behaviour: a second high-command officer
    -- must action every grant. Know the cost first -- a server with exactly
    -- ONE high-command officer then has no way to grant that officer any
    -- permission at all, the tablet's Audit tab included, until a second one
    -- is promoted. That deadlock is why this flag exists; see
    -- DEVELOPER_REFERENCE.md §22.
    --
    -- Read as `~= false` wherever it is consulted, never `x or default`, so
    -- an explicit `false` is never misread as "not set".
    allowHighCommandSelfGrant = true,

    -- Whether a handler/K9 may open the tablet and see what they hold.
    -- Everyone gets the read-only view of their own record by default --
    -- that is the point of it. Turning this off leaves the tablet as a
    -- high-command-only tool.
    everyoneCanViewOwnRecord = true,

    -- Whether the tablet may TRIGGER an ability, as an alternative to the
    -- keybind or chat command. The tablet never grants permission to do
    -- anything -- it fires exactly the same server-validated path the
    -- command does, so a person can only trigger what they could already
    -- trigger by typing it.
    allowActionsFromTablet = true,
}

-- ======================================================================
-- K9 COMMAND TABLET (Config.Features.CommandTablet) --
-- client/tablet.lua + html/tablet.*. The in-game UI for everything
-- above: a roster of handlers and K9s with their certifications, XP and
-- granted permissions, and the controls to grant or revoke.
--
-- SECURITY NOTE, because a UI makes this easy to get wrong: the tablet
-- is a VIEW. It decides nothing. Every action it offers is re-authorized
-- server-side from the caller's own live job and grants, exactly as if
-- they had typed the command -- a modified client can send any NUI
-- callback it likes, so the tablet showing a button must never be what
-- makes the action allowed. It only hides what you cannot do, as a
-- convenience.
--
-- BUT: turning Config.Features.CommandTablet off below does not just
-- remove that "VIEW" -- it also removes the ONLY way this tablet offers to
-- grant/revoke a Config.FeatureControl.RequireGrant feature (above) or any
-- Config.Permissions capability. See Config.FeatureControl's own header
-- above for the chat-command fallback ('/k9grantpermission'/
-- '/k9revokepermission') that keeps working regardless of this flag.
-- ======================================================================
Config.CommandTablet = {
    -- HOW PLAYERS OPEN THE TABLET. Pick one:
    --   'command' -- a chat command only. No item needed. Simplest, and the
    --                right choice if you do not want another inventory item
    --                to manage.
    --   'item'    -- using an ox_inventory item opens it. The command is not
    --                registered at all in this mode, so there is no way to
    --                open it without the item in hand.
    --   'both'    -- either works. The item is a convenience, not a gate.
    -- Any other value is treated as 'command' and warns loudly at startup,
    -- rather than silently leaving players with no way in at all.
    openMode = 'both',

    -- The chat command, used by 'command' and 'both'. Also reachable from
    -- the K9 radial menu in every mode -- the radial is a UI affordance, not
    -- a third open mode, and it honours the same authorization either way.
    command = 'k9tablet',

    -- A SECOND, separate chat command that opens the SAME tablet, but goes
    -- straight to the High Command console screen instead of the player's
    -- own record -- a shortcut for your senior staff so they don't have to
    -- open the tablet and click across to the console tab every time.
    --
    -- This is only ever a shortcut to a SCREEN, never a way to grant
    -- access: someone who is not High Command and types this command still
    -- gets refused the console (with a message explaining why) and simply
    -- sees their own record instead, exactly as the regular command above
    -- would show them. Always available (regardless of `openMode` above)
    -- whenever this tablet feature is turned on at all. Rename it to
    -- whatever fits your server, or leave it as the default below.
    highCommandCommand = 'k9hqtablet',

    -- The ox_inventory item, used by 'item' and 'both'.
    --
    -- READ THIS BEFORE SETTING openMode = 'item': the item must already
    -- exist in YOUR ox_inventory items table. This resource cannot create
    -- it, and an unregistered name resolves to a count of zero forever --
    -- which, in 'item' mode, means NOBODY can open the tablet and nothing
    -- explains why. A startup warning fires if the name cannot be resolved,
    -- and in 'item' mode that warning is escalated, because there is no
    -- command to fall back on. Four other placeholder item names in this
    -- config have the same requirement (k9_medkit, k9_treat, k9_meat_bait,
    -- k9_ultrasonic_whistle); see README.md's "Before real players touch
    -- this" checklist for the full list and what each one is for.
    itemName = 'k9_tablet',

    -- WHETHER THE TABLET ITEM IS CONSUMED WHEN USED IS SET IN YOUR OWN
    -- OX_INVENTORY ITEMS.LUA, NOT HERE (second dead-config-field audit
    -- pass: a `consumeItemOnUse = false` field used to sit on this line and
    -- read exactly like a real on/off switch. It was not one -- nothing in
    -- this resource ever read it, so editing it changed nothing in game.
    -- Removed outright, rather than left as a field nobody could safely
    -- trust, so there is nothing here left to mistake for a working
    -- control). k9_tablet is consumed (or not) purely per that item's own
    -- `consume` field in YOUR ox_inventory items.lua, which this resource
    -- does not own and cannot set -- set it to 0/false there for a reusable
    -- tablet, which is almost certainly what you want. See
    -- client/tablet.lua's own useTabletItem handler for the full mechanism
    -- this note describes.

    -- Max roster rows returned in one query. Clamped server-side; a
    -- non-positive or non-number value falls back to the default rather
    -- than meaning "unlimited".
    maxRosterRows = 100,

    -- Which features get a one-click "use" button in the tablet.
    --
    -- Everything in your Config.Features list is SHOWN in the tablet with
    -- its current state. This much smaller list is the subset that can also
    -- be TRIGGERED from there -- the ones where a single button press has an
    -- obvious meaning ("bark", "toggle night vision"). A feature not listed
    -- here still appears and still works; it just has no button, because
    -- there is nothing sensible for one press to do.
    --
    -- These 20 are exactly the features the tablet actually knows how to
    -- fire today. Setting one to false removes its button. Adding a key
    -- that has no wiring behind it gives you a button that does nothing,
    -- so only add one alongside the code that makes it work.
    --
    -- This table did not exist until 2026-08-26, and the tablet read it
    -- anyway -- which meant NO feature got a button, on any server. If you
    -- delete this table, that is the behaviour you go back to.
    ActionableFeatures = {
        LeashMechanics    = true,
        VehicleEntryExit  = true,
        BasicBarkSounds   = true,
        ScentTracking     = true,
        BloodTracking     = true,
        GunpowderSniffing = true,
        ThermalVision     = true,
        NightVision       = true,
        CameraFeedPiP     = true, -- the only place the partner camera is opened
        BiteAndHold       = true,
        NonLethalTakedown = true,
        PropDragging      = true,
        HandlerPartnership = true,
        FetchMechanic     = true,
        PropAttachments   = true,
        DeployableKennel  = true,
        K9Inventory       = true,
        K9Medkit          = true,
    },
    -- ==================================================================
    -- YOUR SERVER'S BRANDING ON THE TABLET. The tablet now shows this logo
    -- in several places (the header on every screen, plus a larger badge
    -- on the opening/loading screen) -- you do not choose where; it is
    -- placed automatically everywhere it makes sense.
    --
    -- TO USE YOUR OWN LOGO: save it as html/images/logo.png, replacing the
    -- placeholder that ships there. That is the only step -- you do not
    -- need to edit anything else in this file or in fxmanifest.lua, and
    -- you do not need to restart anything other than the resource.
    --
    -- WHAT IMAGE TO USE: a SQUARE image (same width and height, e.g.
    -- 512x512 or 1024x1024) looks best -- that is the shape the tablet's
    -- layout is built around. A non-square image (a wide banner or a tall
    -- crest) still displays correctly and is never stretched or squashed,
    -- but a square badge is the recommended shape.
    --
    -- WHAT NOT TO USE: a web address (anything starting with http:// or
    -- https://). The tablet's security settings only allow it to load
    -- files shipped with this resource, so a web address will silently
    -- fail to load -- it will not show an error, it will just fall back
    -- to showing `serverName` as plain text below, exactly as if the file
    -- were missing. Always use a local file under html/images/.
    --
    -- If the file is missing, unreadable, or otherwise fails to load, the
    -- tablet falls back to showing `serverName` as text everywhere the
    -- logo would have appeared. It never shows a broken-image icon and
    -- never leaves an empty gap.
    -- ==================================================================
    branding = {
        -- Shown beside the logo, and instead of it if the image cannot
        -- load. Keep it short -- it sits in a header, not a paragraph.
        serverName = 'Crimson Roleplay',

        -- Where the logo lives. Change this only if you also add the new
        -- path to fxmanifest.lua's files{} block -- an image the manifest
        -- does not list is simply not sent to players, and shows as
        -- nothing with no error to explain why. Must be a local path
        -- under html/ -- see the "WHAT NOT TO USE" note above.
        logo = 'images/logo.png',

        -- Starting colours, matched to the shipped logo (crimson red on
        -- near-black). High command can change all of these live from the
        -- tablet itself; these are just what a fresh install looks like.
        -- Hex, six digits, with the #.
        theme = {
            primaryColor    = '#C8102E', -- crimson: headers, active tabs
            accentColor     = '#FF2D2D', -- brighter red: buttons, highlights
            backgroundColor = '#0B0B0D', -- near-black panel background
            textColor       = '#F5F5F5', -- off-white body text
        },
    },

}

-- ======================================================================
-- K9 ONBOARDING HINT (Config.K9Onboarding.enabled) -- client/hud.lua.
-- Tuning for the small, dismissible on-screen nudge that reminds a
-- brand-new K9 or handler where the tablet is and how to open it. NOT a
-- Config.Features entry -- this is a purely client-side, cosmetic
-- discovery aid with no server-side decision behind it at all, so it does
-- not need (and deliberately skips) the runtime-control/tablet-domain/
-- per-person-block machinery every Config.Features entry carries. Same
-- "extra, independent kill-switch" posture as Config.LeashVisual.enabled
-- elsewhere in this file.
-- ======================================================================
Config.K9Onboarding = {
    -- Turn the nudge off entirely if you would rather rely on the one-time
    -- chat line a player already gets the moment their K9 role is granted
    -- (locales/en.json's appearance.apply_success_target). Leaving this on
    -- is a SECOND chance at that same message for anyone who missed it --
    -- tabbed out, mid-conversation, chat scrolled -- with no other way to
    -- ever learn the tablet exists.
    enabled = true,

    -- How many minutes the nudge stays on screen, once shown, before it
    -- automatically hides itself for the rest of that play session.
    -- HIGHER = more time for someone who is tabbed out or mid-conversation
    -- to notice it. It is not gone for good after this -- as long as they
    -- still have not opened the tablet even once, and have not dismissed
    -- it themselves (see dismissControl below), it comes back and shows
    -- again the next time they reconnect, so someone who missed the whole
    -- window is not permanently out of luck either. A non-positive or
    -- non-number value falls back to the default below rather than
    -- meaning "forever" or "never".
    nudgeDurationMinutes = 5,

    -- The key/button that dismisses the nudge for good, as a raw game
    -- control number rather than a key name -- this is NOT the same kind
    -- of setting as the letter keys elsewhere in this file, so you cannot
    -- just type a letter here. Leave this at its default (202,
    -- Backspace on keyboard / B on a controller) unless you already know
    -- it clashes with something else on your server. A missing or invalid
    -- number falls back to 202.
    dismissControl = 202,

    -- Plain-English name of the key/button above, shown to the player in
    -- the nudge text itself (e.g. "Press Backspace to dismiss this
    -- reminder."). Purely cosmetic -- this does not change which key
    -- actually works, it only changes what the on-screen text SAYS the
    -- key is. If you change dismissControl above, update this to match,
    -- or the hint will tell players the wrong key name.
    dismissControlLabel = 'Backspace',
}

-- ======================================================================
-- CERTIFICATION DEPTH -- tiers, expiry and specializations.
--
-- CORRECTED: this used to say tiers were "deliberately HARDCODED... rather
-- than configured here" and to send you to specializations if you wanted
-- more of them. That was wrong, and it contradicted Config.CertificationTiers'
-- own heading a few hundred lines above, which correctly tells you that you
-- can add tiers. server/certtiers.lua really does read that table -- it is
-- where tiers come from. Somebody who wanted a fourth rank and read only
-- this paragraph would have gone off and built it out of specializations,
-- which are a different tool for a different job.
--
-- So: the three shipped tiers (trainee / certified / senior) are a DEFAULT,
-- not a fixture. Add or reorder them in Config.CertificationTiers. Do not
-- rename the three that ship -- existing records refer to them by name.
--
-- Specializations are still the right tool for a different question: tiers
-- are how FAR through training somebody is, specializations are WHAT they
-- were trained to find.
-- ======================================================================

-- Days from grant or renewal until a certification is treated as expired.
-- Only consulted when Config.Features.CertificationExpiry is true. A
-- non-positive or non-number value disables expiry-setting rather than
-- meaning "immediately" or "never" -- this resource's usual fail-safe
-- convention for a boundary value.
Config.CertificationExpiryDays = 90

-- How many days ahead of expiry an online handler starts getting a
-- one-per-session warning. Nobody should discover their certification
-- lapsed by an ability silently refusing to work.
Config.CertificationExpiryWarningDays = 7

-- How often the background sweep re-checks online handlers for an
-- upcoming or just-passed expiry. NOT the enforcement point: HasK9Access
-- and RefreshCertificationCache always compute the true state fresh on
-- login, grant and revoke regardless of this interval. This only drives
-- the courtesy notifications.
Config.CertificationExpiryCheckIntervalMs = 300000

-- Named K9 training specializations a certifier can grant on top of an
-- existing active certification. Add freely -- but the keys are stored in
-- the database, so never RENAME one that has already been granted; add a
-- new key and migrate, the same rule Config.Permissions carries.
Config.K9Specializations = {
    narcotics  = { label = 'Narcotics detection' },
    explosives = { label = 'Explosives detection' },
    patrol     = { label = 'Patrol / apprehension' },
}

-- ======================================================================
-- SPECIALIZATION-SCOPED TRACKING (owner-directed decluttering pass,
-- 2026-08-26 -- "merge all the scent tracking stuff into one thing... when
-- certed for extra stuff it just does it"). server/tracking.lua reads this
-- to decide which Track <Type> trail(s) a K9's single merged "search"
-- action (client/tracking.lua's StartCertifiedTrack, one radial item, one
-- chat command) is allowed to resolve for, without the client ever
-- choosing the type itself.
--
-- 'scent' -- the generic dropped-item scent trail (server/tracking.lua's
-- TrackableLog.scent, fed by the ox_inventory swapItems hook) -- is
-- DELIBERATELY ABSENT from this table and can NEVER be listed here. It is
-- the BASE capability every K9-access handler already has today, not a
-- narcotics-detection mechanic. Two removed minigames narratively shared
-- the word "scent" with it and neither ever called into this file's
-- findTrackableSource/TrackableLog.scent at all. Listing 'scent' under any
-- specialization here would gate
-- a base capability behind a narrow one for no reason connected to what
-- 'scent' actually is -- do not "fix" this by adding it back.
--
-- MONOTONIC BY DESIGN (owner-directed follow-up, same pass -- "make it
-- more fluid... [no state where] training a dog makes it worse at its
-- job"): a specialization only ever ADDS a trail type to what a K9 can
-- already track; there is no "generalist fallback" that grants everything
-- to an uncertified dog and then takes types away the moment a
-- specialization is granted. That means, in plain English for a
-- non-technical owner reading this:
--
--   BLOOD AND GUNPOWDER TRACKING NOW REQUIRE A SPECIALIZATION GRANT. This
--   is a REAL, INTENTIONAL CHANGE, not a bug: today, every K9-certified
--   handler can already Track Blood / Track Gunpowder with no extra grant
--   at all. After this config takes effect, a handler can ONLY track
--   blood if their K9 holds the 'patrol' specialization, and can ONLY
--   track gunpowder residue if it holds 'explosives' -- exactly the "if
--   certed for X it does X" behavior that was asked for. If you have NOT
--   granted ANY specializations on your server yet (the shipped default),
--   your K9s can still track generic scent (scent vision and everything
--   unrelated to this table are completely unaffected), but NONE of them can Track Blood or Track
--   Gunpowder until you grant 'patrol'/'explosives' to them via the
--   certification tablet. server/diagnostics.lua prints a one-line boot
--   warning naming this exact situation so it is never a silent surprise
--   discovered mid-shift. HIGH COMMAND OFFICERS ARE UNAFFECTED --
--   HasSpecialization's own High Command bypass (server/certifications/)
--   already grants every specialization automatically, so a high-command
--   officer keeps both Track Blood and Track Gunpowder with nothing to
--   grant.
--
-- Format: [Config.K9Specializations key] = { one or more of 'blood' |
-- 'gunpowder' -- never 'scent', see above }. A key that is not a real
-- Config.K9Specializations key, or a value that is not an array of valid
-- track type strings, is CLAMPED AND WARNED at boot (never asserted) and
-- simply ignored -- see server/tracking.lua's own validation block.
Config.SpecializationTracking = {
    explosives = { 'gunpowder' },
    patrol     = { 'blood' },
}

-- ======================================================================
-- K9 DOWN ALERT (Config.Features.K9DownDispatch) -- server/integrations.lua.
-- Tuning for OUR OWN detection of a K9 going down. This is not an
-- integration surface: there is nothing here naming another resource,
-- because the alert is a broadcast event any system can listen for.
-- ======================================================================
-- ======================================================================
-- DISCORD WEBHOOK LOGGING (Config.Features.DiscordWebhook, ships OFF) --
-- server/webhook.lua. Posts K9 events into a Discord channel, so staff can
-- keep an eye on things without anyone logging into the tablet.
--
-- A WEBHOOK URL IS A PASSWORD. Anyone who has it can post to that channel
-- forever. Do not put a real one in a config file you share, upload, or
-- commit anywhere public. This resource never prints it, never sends it to
-- a player, and never puts it in an error message -- but it cannot stop you
-- pasting it somewhere public yourself.
--
-- Nothing happens until `url` is set. The feature flag alone does nothing.
-- ======================================================================
Config.DiscordWebhook = {
    -- Paste your channel's webhook URL here. Discord makes one for you
    -- under Channel Settings -> Integrations -> Webhooks.
    url = nil,

    -- Optional. What the messages appear to be posted BY. Leave both nil to
    -- use whatever the webhook itself is named in Discord.
    username = nil,
    avatarUrl = nil,

    -- How often messages are sent, in milliseconds (8000 = eight seconds).
    -- Events are collected up and posted together rather than one message
    -- per event -- Discord rate-limits hard, and a busy shift would trip it
    -- within seconds otherwise. LOWER = more up to date, more requests.
    -- HIGHER = fewer requests, slightly behind.
    batchIntervalMs = 8000,

    -- The most events that can be waiting to send at once. If more arrive
    -- than this while Discord is slow or down, the extra ones are DROPPED
    -- and the next successful message tells you how many were lost. That is
    -- deliberate: a queue with no limit would grow until the server ran out
    -- of memory, and losing a few log lines is much better than that.
    maxQueueSize = 40,

    -- If Discord tells us we are sending too fast, wait this long before
    -- trying again (60000 = one minute).
    rateLimitBackoffMs = 60000,

    -- Which events get posted. Turn off anything that is just noise for
    -- your server. `searchCompleted` is the busiest one by a long way --
    -- it fires every time any dog searches anybody -- so it ships off.
    events = {
        certificationGranted     = true,
        certificationRevoked     = true,
        certificationTierChanged = true,
        certificationRenewed     = true,
        specializationGranted    = true,
        specializationRevoked    = true,
        k9Down                   = true,
        searchCompleted          = false,
        partnershipEstablished   = false,
        partnershipEnded         = false,
        xpTierReached            = false,
    },
}

Config.K9DownDispatch = {
    -- Health at or below which a K9 counts as down. Mirrors the same
    -- threshold server/wellbeing.lua uses. Raise it to get an earlier
    -- "going critical" warning instead of an "already down" one.
    healthThreshold  = 100,

    -- How long they must stay down before the alert fires, in ms. This is
    -- the debounce: without it, a momentary dip through the threshold
    -- during an ordinary firefight would page dispatch. 0 disables it.
    minDurationMs    = 3000,

    -- Background poll interval, in ms.
    pollIntervalMs   = 2000,

    -- Minimum gap between two alerts for the SAME K9, in ms. Stops a
    -- handler bleeding out from generating a stream of alerts. Must be
    -- positive -- a non-positive value here is caught by cooldowns.lua's
    -- own guard. Setting this to 0 or a negative number does NOT mean "no
    -- cooldown" and never did -- but as of 2026-08-26 it no longer breaks
    -- anything either. It used to abort server/integrations.lua at startup,
    -- silently killing K9-down dispatch for the rest of that server's
    -- uptime. Now a bad value is clamped back to the 30000 below and warned
    -- about loudly in your console, naming this exact key. A suppressed
    -- episode is DEFERRED, not dropped.
    reFireCooldownMs = 30000,
}

Config.AllowSelfCertification = true   -- see §4.1
Config.CertifyProximityMeters = 5.0    -- server-enforced max distance for grant/revoke (§4.2 item 4)

-- FARM FIX (audit finding, this pass) -- Config.CertifyProximityMeters and
-- CertifyXpMintCooldown (server/certifications/, 24h, per person you
-- certify) stop someone from farming XP off the SAME person over and over.
-- Neither one stops a certifier from farming XP by certifying a large
-- number of DIFFERENT people instead -- real alt characters made and
-- deleted cheaply, or (through /k9certifyoffline) simply typed citizenid
-- strings that do not even need to belong to a real character. This
-- setting is the backstop for that: the most people, in total, one
-- certifying officer can be PAID handler XP for certifying in any rolling
-- 24-hour day. It never stops anyone from certifying someone -- the
-- certification itself always works -- it only stops the BONUS XP from
-- paying out past this many NEW people in one day; anyone certified past
-- the limit simply is not paid for it until the next day.
--
-- HOW TO SET THIS: picture the busiest a real training officer would
-- plausibly get -- a big recruitment night, not an ordinary one -- and set
-- this a little above that. LOWER is STRICTER (closes this gap tighter, at
-- the cost of your busiest trainers occasionally having to wait until
-- tomorrow for the bonus XP on their last few certifications of the
-- night). HIGHER is more LENIENT (a farmer using fake or throwaway people
-- can collect more XP per day before this stops them). The certifications
-- themselves are never affected either way.
Config.CertifyMaxNewGranteesPerDay = 8

-- ======================================================================
-- VEHICLES — which vehicle models expose the "Load K9" / "Release K9"
-- ox_target option on their trunk/rear door.
-- ======================================================================
-- ======================================================================
-- RIDING IN A VEHICLE -- how a K9 gets in, where it sits, and how it sits
-- (owner-directed, this pass: "if a k9 gets in any vehicle it will position
-- the dog where it sits appropriately like laying down in the back seat or
-- sitting down in the back seat or if it sits up front it sits in the
-- passenger seat... make it where its part of the normal getting in a
-- vehicle... disable it where it trys to get in a driver seat of a vehicle
-- it wont allow it or attempt to get in a driver seat... i want it to be
-- fluid").
-- ======================================================================
Config.K9VehicleRide = {
    -- THE NORMAL ENTER KEY WORKS. With this on, a K9 pressing the game's
    -- own "enter vehicle" key (F by default) near a K9-eligible vehicle
    -- loads up exactly as any player would expect -- no command, no radial,
    -- no third-eye. That was the owner's specific correction: this belongs
    -- on the ordinary control, not on a separate menu.
    --
    -- HOW IT WORKS, and why it is a capture rather than a replacement: the
    -- game's own enter-vehicle behaviour is DISABLED for a K9 only while
    -- one is genuinely in reach of an eligible vehicle, and that keypress
    -- is routed into this resource's own seating flow instead. Outside that
    -- moment the control is left completely alone, so nothing else about
    -- being on foot changes.
    captureNativeEnterKey = true,

    -- Control 23 is INPUT_ENTER, the game's own enter/exit-vehicle action.
    -- Exposed rather than hardcoded so an operator running a control-remap
    -- resource can point this at whatever their players actually press.
    enterControl = 23,

    -- NEVER THE DRIVER'S SEAT. Two independent mechanisms, because one is
    -- not enough:
    --
    --   1. The seat picker never offers seat -1 in the first place (see
    --      client/vehicle.lua's SEAT_PREFERENCE_ORDER, which starts at the
    --      rear and has no -1 entry at all).
    --   2. This flag additionally EJECTS a K9 that ends up in the driver's
    --      seat by any route this resource does not control -- an admin
    --      teleport, another resource seating them, a vehicle whose driver
    --      left while they were inside, or simply pressing enter before
    --      this resource loaded.
    --
    -- (1) alone would leave the dog able to end up driving via routes this
    -- script never sees, which is exactly the "it wont allow it or attempt
    -- to get in a driver seat" the owner asked for. Turning this off leaves
    -- (1) intact -- the dog still will not be SEATED there by this
    -- resource -- but stops policing seats it did not assign.
    preventDriverSeat = true,

    -- How the dog actually sits once it is in. GTA has no "dog riding in a
    -- car" animation -- a quadruped in a car seat plays the human sit-in,
    -- which reads badly. These play a real dog scenario on the seated ped
    -- instead, which is what makes it look like a dog in a car rather than
    -- a dog wearing a seatbelt.
    --
    -- REAR SEATS get the lying-down look by default (a working dog rides
    -- lying down in the back); the FRONT PASSENGER seat gets the sitting
    -- look (a dog up front sits up and watches the road). Both are
    -- per-breed, resolved the same way every other dog pose in this
    -- resource is.
    --
    -- CONFIDENCE, stated rather than assumed: the WORLD_DOG_SITTING_* names
    -- are the same verified family used everywhere else here (two
    -- independent community scenario dumps agree they exist). There is NO
    -- verified generic "dog lying down" scenario name -- so `rearPose`
    -- ships as 'sit' rather than inventing a lie-down name that would be a
    -- silent no-op. Set it to 'lie' only once you have a confirmed
    -- lying-down scenario or anim for your own server, and put that name in
    -- `lieScenarioOverride` below.
    rearPose = 'sit',   -- 'sit' | 'lie' | 'none'
    frontPose = 'sit',  -- 'sit' | 'lie' | 'none'

    -- Left empty on purpose. If you have a confirmed lying-down dog
    -- scenario or anim on your server, name it here and set a pose above to
    -- 'lie'. Empty plus 'lie' falls back to the sit pose rather than
    -- playing nothing, so a half-finished setting never leaves the dog
    -- standing bolt upright in a car seat.
    lieScenarioOverride = '',

    -- Milliseconds after seating before the pose is applied. The engine's
    -- own get-in animation has to finish first, or it overrides the pose
    -- the instant it plays. Untuned but deliberately chosen to sit just
    -- past the door-shut delay this file's own VEHICLE_DOOR_SHUT_DELAY_MS
    -- already waits out.
    poseDelayMs = 900,
}

Config.K9Vehicles = {
    'police', 'police2', 'police3', 'police4', 'sheriff', 'sheriff2',
}
Config.VehicleInteractMeters = 3.0

-- ======================================================================
-- LEASH — Phase 1
-- ======================================================================
-- Base/reference leash range in meters (§6.1 — two-player leash, not a
-- recall; see server/main.lua and client/movement.lua headers for the
-- corrected model). NOT itself the auto-detach threshold — that's a
-- common misreading of this field's old comment. Three different
-- call sites derive or reuse this single value for three distinct
-- purposes, each documented in full where it's used:
--   - client/movement.lua derives the elastic pull-back START (75% of
--     this value, LEASH_PULL_ZONE_FACTOR) and the actual hard-cap
--     safety-valve auto-detach (150% of this value, LEASH_HARD_CAP_FACTOR)
--     from it — for the default below, real auto-detach fires around 12m,
--     not 8m.
--   - server/main.lua's CheckLeashEligibility reuses this raw value
--     directly as the max range to even INITIATE a leash request (a
--     separate "too far to request" check, distinct from auto-detach).
--   - client/radial.lua's FindNearestLeashCandidate reuses this raw value
--     directly as its nearby-partner search radius.
-- Reusing the raw value (rather than dedicated constants) for the latter
-- two is a deliberate Phase 1 default, not an oversight — see server/
-- main.lua's header for the open question on whether a separate,
-- smaller "attach range" constant would be worth adding later.
Config.LeashMaxDistance = 8.0

-- ======================================================================
-- LEASH VISUAL (client/leashvisual.lua) -- makes the leash mechanic above
-- actually VISIBLE: a rendered rope between the handler and the K9 for the
-- whole duration of an active leash, plus a leash-handle prop on the
-- handler's own hand. Rides entirely on top of Config.Features.LeashMechanics
-- above rather than being its own togglable feature area -- there is no
-- separate Config.Features entry for this, since with LeashMechanics off
-- the leashAttached/leashDetached events this file reacts to never fire at
-- all, and it is automatically fully inert either way. `enabled` below is
-- purely an extra operator kill-switch for the VISUAL specifically (e.g. a
-- very high-population server that wants the mechanic but not the extra
-- rope/prop entities), independent of that.
--
-- BONE INDICES -- SAME HONEST DEFAULT AS Config.PropAttachments BELOW (read
-- that block's own header first; this is the exact same situation, not a
-- new one). AttachEntitiesToRope takes bone-relative OFFSETS derived from
-- these indices (client/leashvisual.lua's GetBoneLocalOffset), never a bone
-- NAME string -- this resource's research has never found a confirmed bone
-- NAME for the a_c_* K9 skeleton (see Config.PropAttachments/
-- client/bonetool.lua), and never went looking for one on the human
-- skeleton for this feature either, so both indices below default to 0
-- (root -- always valid, never crashes, looks wrong: the rope anchors near
-- each ped's own center rather than precisely a collar/hand point).
-- Refine with Config.Features.BoneSweepDevTool (works on ANY currently-worn
-- ped model, human or K9 -- it is not K9-specific) and set the real values
-- here once found.
Config.LeashVisual = {
    enabled = true,

    -- Bone index the rope's K9-side endpoint offsets from (the K9's own
    -- ped).
    k9BoneIndex = 0,
    -- Bone index the rope's officer-side endpoint offsets from (the
    -- handler's own ped) -- ALSO reused as the attach bone for
    -- handleModel/handleFallbackModel below, since both represent the same
    -- "where on the handler's body does the leash line originate" point.
    officerBoneIndex = 0,

    -- Rope look/feel. ropeType is a zero-based index into ropedata.xml
    -- (AddRope's own documented set, game build 3258): 0 = RopeThin, the
    -- thinnest and most leash-like of the 8 shipped types (1/2/7 are
    -- steel-cable textured, meant for tow cables). AddRope's own docs state
    -- an out-of-range ropeType CRASHES THE GAME -- client/leashvisual.lua
    -- clamps this to [0, 7] defensively rather than trusting it blindly,
    -- but this should still never be hand-edited outside that range.
    ropeType = 0,
    -- The rope's maximum droop/extend length, in meters. Deliberately
    -- LARGER than Config.LeashMaxDistance above rather than equal to it: a
    -- rope whose max length exactly matched the real enforced range would
    -- look taut/rigid at all times, right up to the exact moment
    -- client/movement.lua's own elastic pull-back (LEASH_HARD_CAP_FACTOR =
    -- 1.5) kicks in. Sized to roughly that same 1.5x factor here (8.0 * 1.5
    -- = 12.0) so the rope only looks genuinely taut right around where the
    -- real mechanic starts correcting distance, and hangs with a natural
    -- droop well inside that. Kept as its OWN independent field (not a
    -- computed `Config.LeashMaxDistance * 1.5` expression) so an operator
    -- can retune the cosmetic droop without touching the mechanic's own
    -- range, or vice versa.
    ropeMaxLengthMeters = 12.0,
    -- The rope's minimum length, in meters -- how slack it can go when the
    -- two peds are close together. 0.0 lets it go fully slack, the correct
    -- look for two people standing close.
    ropeMinLengthMeters = 0.0,

    -- Bounded wait for RopeAreTexturesLoaded() before giving up on ever
    -- rendering a rope for the rest of THIS client's session
    -- (client/leashvisual.lua's EnsureRopeTexturesLoaded) -- same
    -- "generous ceiling, then fail loudly rather than hang forever"
    -- reasoning as REQUEST_MODEL_TIMEOUT_MS elsewhere in this resource
    -- (client/kennel.lua, client/propattachment.lua).
    ropeTextureTimeoutMs = 5000,

    -- Leash-handle prop attached to the HANDLER's (officer-role party's)
    -- own hand for the leash's duration -- UNVERIFIED, same honest
    -- disclosure as Config.PropAttachments.propModel below: no confirmed
    -- GTA V leash-handle prop model was found this pass. There is no
    -- native-decls-equivalent registry of PROP MODEL NAMES to check the way
    -- there is for natives -- a model's existence can only be confirmed
    -- empirically against a live client, which this pass did not have.
    -- Survivable by design: fallbackPropModel below is the SAME
    -- confirmed-safe placeholder this resource already uses elsewhere
    -- (Config.PropAttachments.fallbackPropModel / Config.DeployableKennel's
    -- own fallback) specifically because an obviously-wrong prop tells an
    -- operator to go find a real one, where a silent no-op would just look
    -- like the feature is broken.
    handleModel = 'p_ing_dogleash01x', -- UNVERIFIED GUESS, not sourced from any confirmed model list -- replace with a real leash-handle prop once one is found
    handleFallbackModel = 'prop_tennis_ball',
}

-- ======================================================================
-- NOTE (coder-architect, Phase 1 rewrite): Config.K9DespawnGraceSeconds
-- was added in the first scaffolding pass for a handler->K9 netId
-- registry that no longer exists — DEVELOPER_REFERENCE.md's post-draft correction
-- established the K9 is a player's own persistent character (§1, §4.5),
-- with no spawn/despawn/registry concept at all. Removed; do not re-add
-- without a new documented reason, since nothing currently consumes it.
-- ======================================================================

-- ======================================================================
-- OWNER-EDITABLE CEILING for speedMultiplier/scentRangeMultiplier, read by
-- server/xptiers.lua (per-XP-tier speed/scent, Config.XPTiers below),
-- server/k9profiles.lua (per-INDIVIDUAL-K9 override, "god mode over one
-- dog"), and server/runtimecontrol.lua's PursuitSprint.speedMultiplier
-- tunable. Owner's own words: "Keep the speed and stamina editing where i
-- can edit it to as high as i want." Each of those three files reads this
-- through its OWN local resolver (this resource's established "no
-- cross-file `local` import mechanism" convention -- see
-- server/k9profiles.lua's own header, "BOUNDS -- REUSED, NOT REINVENTED")
-- that CLAMPS AND WARNS rather than asserts: a missing, non-numeric, NaN,
-- infinite, zero, or negative value here falls back to the 10.0 default
-- below with a loud console warning naming this exact setting, rather than
-- aborting that file's own script chunk (a bare top-level `assert` on an
-- operator-reachable config value would silently disable every
-- registration below it in that file for the rest of this resource's
-- uptime -- see server/cooldowns.lua's own ResolveConfiguredThresholdMs
-- doc comment for the incident this mirrors).
--
-- PLAIN-ENGLISH HEADS-UP, so raising this is not a "why did nothing
-- happen" mystery: this setting controls what a K9's speed/scent
-- multiplier is genuinely ACCEPTED AND SAVED as. It does NOT change the
-- separate, hardcoded safety clamp in client/movement.lua that caps the
-- FINAL, all-modifiers-combined move rate a player actually SEES at 2.0x
-- (twice normal speed) -- that clamp is intentionally outside this
-- setting's reach. Concretely: setting this to 8.0 and then setting a K9's
-- speedMultiplier to 8.0 will be accepted, saved, and shown as 8.0
-- everywhere in the tablet, but the K9 will still only move at the same
-- visible top speed as an accepted value of 2.0 or higher would already
-- produce, because every other active modifier (tier, mood, fatigue,
-- injury, ...) multiplies together with it before that final 2.0x cap is
-- applied. Raising this setting is still meaningful for VALUES BELOW that
-- visible ceiling and for scentRangeMultiplier (which has no such client
-- clamp at all), but if you raise speedMultiplier expecting to SEE a dog
-- run faster than 2x normal past that point, you will not -- that is a
-- separate, deliberate decision left to you, not a bug in this setting.
Config.MaxSpeedScentMultiplier = 10.0

-- ======================================================================
-- OWNER-EDITABLE CEILING for sprintDecayPerTick (server/k9profiles.lua's
-- per-INDIVIDUAL-K9 stamina override, "god mode over one dog"). Owner's own
-- words, same breath as the speed/scent ask above: "be able to make the
-- stamina as high as i want and be able to make the stamina as high as i
-- want or permanant."
--
-- THE DIRECTION IS INVERTED FROM Config.MaxSpeedScentMultiplier ABOVE --
-- READ THIS BEFORE CHANGING EITHER ONE. speedMultiplier/scentRangeMultiplier
-- are GOOD when bigger (a faster, longer-ranged dog), so that setting is a
-- ceiling on how good you can make one. sprintDecayPerTick is a DRAIN
-- RATE -- a BIGGER number drains a K9's stamina FASTER while sprinting, a
-- WORSE dog, not a better one. So this setting is a ceiling on how BAD you
-- can make one, not how good. Do not reuse Config.MaxSpeedScentMultiplier
-- for this value -- they are different quantities measuring opposite
-- things, and an owner raising one should never silently move the other.
--
-- ZERO IS ALWAYS VALID REGARDLESS OF THIS CEILING -- it is the "never runs
-- out" permanent-stamina sentinel the owner explicitly asked for (a real,
-- distinct value from "unset", never confused with it), and this setting
-- only ever bounds how HIGH a drain rate can be set, never how LOW one
-- (server/k9profiles.lua's own IsValidStaminaDrain accepts `>= 0`, not
-- `> 0`, specifically so this ceiling can never catch it).
--
-- Read by server/k9profiles.lua's own ResolveMaxStaminaDrainPerTick,
-- which CLAMPS AND WARNS rather than asserts -- same shape as
-- Config.MaxSpeedScentMultiplier's own resolver immediately above: a
-- missing, non-numeric, NaN, infinite, zero, or negative value here falls
-- back to the 20.0 default below with a loud console warning naming this
-- exact setting, never a silently-broken tablet.
Config.MaxStaminaDrainPerTick = 20.0

-- ======================================================================
-- XP TIERS — Phase 4, placeholder numbers pending economy-balance-agent review
-- ======================================================================
-- REBALANCED (owner-directed: "make the xp progression actually do things
-- to help improve the k9 experience... make it actually mean something").
--
-- EVERY RANK NOW GIVES SOMETHING YOU CAN FEEL. The old first step was +5%
-- speed and +5% scent range, awarded after 1250 XP -- hours of real work
-- for a change no player could perceive. A reward nobody notices is the
-- same as no reward, and it made the whole early ladder read as
-- decorative.
--
-- SCENT RANGE CARRIES MORE OF THE WEIGHT THAN SPEED, deliberately. Speed
-- is the dangerous lever: a K9 fast enough to run down any suspect on foot
-- flattens every pursuit it touches, so the top of the ladder stops well
-- short of that. Scent range is where a veteran dog SHOULD outclass a
-- rookie -- it makes tracking work at distances a new dog cannot reach,
-- which is felt every single time you track, without letting the dog win
-- fights on its own. Base tracking range is 40m, so the ladder now reads
-- as roughly 40 / 46 / 54 / 64 metres.
--
-- ELITE NO LONGER GETS ONLY A BADGE. It previously had no cooldown unlock
-- at all -- Veteran was the only rank that got one -- so the final, most
-- expensive rank was the one that changed the least. It now deepens medkit
-- recovery as well.
--
-- TUNE THESE. They are gameplay balance for YOUR server, not physics. The
-- ceiling is Config.MaxSpeedScentMultiplier (10.0), so there is headroom
-- for a far more dramatic ladder -- but read the speed warning above before
-- pushing speedMultiplier much past 1.20.
Config.XPTiers = {
    -- The four K9 ranks. Each row is a threshold plus the bonuses that rank
    -- unlocks; the first MUST be xp = 0.
    --
    -- speedMultiplier and scentRangeMultiplier are multipliers over the base
    -- value, so 1.00 means no bonus and only a number above 1.0 does
    -- anything.
    --
    -- PACING, so the thresholds mean something: at a realistic ~500 XP/hr
    -- Elite is about 18 hours of duty -- two to two and a half weeks at an
    -- hour a day. The absolute fastest anyone can reach it, farming
    -- flat out against the shared 3,600 XP/hr budget, is about 2h27m. That
    -- floor is deliberate; raising these numbers without re-checking it just
    -- moves the wall. Full derivation, and the farm that forced the retune:
    -- DEVELOPER_REFERENCE.md §22.
    { xp = 0,    label = 'Recruit K9', speedMultiplier = 1.00, scentRangeMultiplier = 1.00 },
    { xp = 1250, label = 'Trained K9', speedMultiplier = 1.06, scentRangeMultiplier = 1.15 },
    -- Veteran unlocks a shorter K9 medkit cooldown. A multiplier, not an
    -- absolute: 0.75 means "three quarters of the configured wait".
    -- Deliberately a NUMBER and never a boolean -- it is consulted only
    -- AFTER an existing gate has already allowed the action, so reaching a
    -- tier can shorten a wait but can never grant access to anything.
    { xp = 4000, label = 'Veteran K9', speedMultiplier = 1.12, scentRangeMultiplier = 1.35, medkitCooldownMultiplier = 0.75 },
    -- Elite gets the deepest K9-side medkit cooldown reduction (0.60 --
    -- deeper than Veteran's 0.75, and cumulative in the same
    -- already-gated, never-granting sense that field's note above
    -- describes), PLUS a cosmetic HUD badge.
    --
    -- HONEST NOTE ON THAT BADGE: `badge = 'elite'` is read by nothing.
    -- No HUD, tablet or nameplate code in this resource looks the field
    -- up (grep `badge` -- the only hits are this line and its own
    -- comments). It is kept because it costs nothing and documents the
    -- intent for whoever wires a rank badge later, but DO NOT read it as
    -- a reward a player can currently see -- that is exactly why this
    -- rank needed a real mechanical unlock of its own. Before this
    -- rebalance, Elite -- the most expensive rank on the ladder -- was
    -- the ONLY rank whose entire distinguishing reward was that dead
    -- field.
    { xp = 9000, label = 'Elite K9',   speedMultiplier = 1.18, scentRangeMultiplier = 1.60, medkitCooldownMultiplier = 0.60, badge = 'elite' },
}

-- ======================================================================
-- HANDLER XP TIERS -- the ranks a HANDLER climbs, separate from the K9's own
-- ladder (Config.XPTiers above). Switched on by
-- Config.Features.HandlerXPProgression.
--
-- Two totals, one row per person: a player who is sometimes the dog and
-- sometimes the handler keeps two separate standings, each earned only by
-- that role's own actions.
--
-- TUNING RULES, THE ONLY TWO THAT MATTER:
--   * The first entry MUST be `xp = 0`. The ladder is walked ascending and
--     that entry is the baseline everyone starts on.
--   * Each tier restates every lower tier's bonus fields plus its own, on
--     purpose -- a handler's benefits should only ever grow with rank, never
--     drop out at a higher one.
--
-- Every bonus field here can only shorten a wait or lengthen a distance. It
-- is read AFTER an existing permission check has already allowed the action,
-- so no rank can ever grant access to something a handler could not
-- otherwise do.
--
-- WHAT A HANDLER CAN ACTUALLY EARN, so these thresholds mean something:
-- certifying a genuinely new person (50 XP, once per person per day), three
-- one-time partnership milestones worth 155 XP total for the life of a
-- partnership, and two repeatable support actions -- treating the K9 and
-- deploying a kennel -- worth 32 XP/hr combined. Full derivation, the audit
-- that forced the rescale, and the three tier effect fields that were wired
-- or removed: DEVELOPER_REFERENCE.md §22.
-- ======================================================================
Config.HandlerXPTiers = {
    { xp = 0,   label = 'Rookie Handler' }, -- everyone starts here -- day one on the job, no XP earned yet
    -- CERTIFIED HANDLER (medkitTreatCooldownMultiplier -- WIRED,
    -- server/medkit.lua, via GetHandlerXPTierMedkitCooldownMs -- see this
    -- table's own header above for the full field-by-field resolution).
    -- WHAT IT TAKES: about ONE genuinely new K9 candidate you personally
    -- certify (handlerCertifyK9, 50 XP) -- OR roughly a week of simply
    -- staying partnered with your own K9 and playing together normally
    -- (the 1-day + 7-day tenure milestones alone already total 55 XP, with
    -- zero certifying). Reachable within a handler's first few real
    -- shifts either way -- this is the "first promotion" rung.
    { xp = 50,  label = 'Certified Handler', medkitTreatCooldownMultiplier = 0.80, kennelDeployCooldownMultiplier = 0.85 },
    -- SENIOR HANDLER (kennelDeployCooldownMultiplier -- WIRED,
    -- server/kennel.lua, via GetHandlerXPTierKennelDeployCooldownMs. Same
    -- header, same note). WHAT IT TAKES: the full 30-day tenure trickle
    -- (155 XP -- this ladder's own hard ceiling for a handler who never
    -- certifies anyone) reaches this rank ON ITS OWN, with zero certifying
    -- required -- about a month of ordinary, regular partnered play. A
    -- handler who DOES certify gets here faster (three certifications, 150
    -- XP, is already enough by itself).
    { xp = 150, label = 'Senior Handler',    medkitTreatCooldownMultiplier = 0.65, kennelDeployCooldownMultiplier = 0.65 },
    -- MASTER HANDLER -- deliberately ABOVE the 155-XP tenure ceiling: this
    -- rank cannot be reached by tenure alone, on purpose (a genuine
    -- long-term goal, not a passive one). WHAT IT TAKES: actually being
    -- part of bringing new K9 handlers onto the force -- roughly seven to
    -- ten personally-granted certifications (50 XP each, capped at one per
    -- unique new person per 24 real hours) on top of a long-standing
    -- partnership, spread across several weeks to a couple of months of
    -- regular duty. Weeks of real, active involvement -- not a single
    -- evening, and not the 3.2-YEAR WALL the old 6000 threshold produced
    -- for anyone who does not personally recruit others.
    --
    -- Master Handler's own combined MULTIPLIER worst-case floors (both
    -- cooldowns stack with any lower tier already earned, by design -- see
    -- "cumulative by design" above). RECOMPUTED FOR THE REBALANCED
    -- MULTIPLIERS (0.70 -> 0.50 and 0.60 -> 0.45 on this line, and Elite K9
    -- gaining a medkitCooldownMultiplier of 0.60 it did not previously
    -- have): medkit 60000ms * 0.50 = 30000ms alone; 22500ms combined with a
    -- Veteran-tier K9 TARGET's own 0.75, and 18000ms -- the true worst case
    -- now -- combined with an ELITE-tier K9 target's 0.60 (Config.XPTiers);
    -- kennel deploy 5000ms * 0.45 = 2250ms.
    --
    -- WHY DEEPENING THESE IS STILL ANTI-FARM SAFE, checked rather than
    -- assumed: both handlerTreatK9 and handlerKennelDeploy mint their XP
    -- through DEDICATED per-actor mint cooldowns
    -- (TREAT_XP_MINT_COOLDOWN_MS = 30 real minutes, server/medkit.lua;
    -- KENNEL_DEPLOY_XP_MINT_COOLDOWN_MS = 60 real minutes,
    -- server/kennel.lua), never through the ACTION cooldowns these
    -- multipliers shorten. That separation is precisely the
    -- climbing-the-ladder-makes-the-ladder-faster loop server/progression.lua's
    -- BINDING REQUIREMENT note exists to rule out, and it holds here: these
    -- multipliers change how often a handler may ACT, and cannot change how
    -- often they EARN. Anyone re-tuning them should re-verify that
    -- separation still holds before assuming it.
    --
    -- These are the exact numbers server/progression.lua's own doc comment
    -- and the SOURCE AUDIT tests cite -- if you retune either MULTIPLIER
    -- here, that comment and those tests go stale and need updating too
    -- (the xp threshold itself is not referenced by either).
    { xp = 500, label = 'Master Handler',    medkitTreatCooldownMultiplier = 0.50, kennelDeployCooldownMultiplier = 0.45 },
}
-- HOW LONG THESE THRESHOLDS ACTUALLY TAKE, so you can judge them: a handler
-- who never certifies anyone reaches Master in roughly eight ordinary
-- sessions -- one to a few weeks of regular duty. The theoretical floor is
-- about 11 hours of flawless, back-to-back action, which is not a realistic
-- single sitting. A handler who does certify people gets there sooner.
--
-- These were left at 0/50/150/500 on purpose: they sit in the "weeks, not an
-- afternoon and not a lifetime" band already. Full arithmetic, and the
-- reachability gap that used to make Master impossible for most players:
-- DEVELOPER_REFERENCE.md §22.

-- ======================================================================
-- XP PROGRESSION (Config.Features.XPProgression, server/progression.lua).
-- Per-action award VALUES that accumulate toward Config.XPTiers' thresholds
-- above (that table was drafted early and sat unused until this pass).
-- DEVELOPER_REFERENCE.md §13.4.1 — the exact award-action list (searchContrabandFound/
-- trackSourceResolved/biteHoldSuccess/takedownSuccess) is taken verbatim from
-- that section, not invented here. Every value below is an unreviewed
-- placeholder pending economy-balance-agent/config-validator review
-- (DEVELOPER_REFERENCE.md §9 item 4), same status Config.XPTiers itself already carries.
-- ======================================================================
Config.XP = {
    -- Whether an NPC bite-hold or takedown target MINTS XP. Defaults false.
    --
    -- This does NOT change whether NPC combat is allowed -- that is a
    -- separate, settled decision and this key does not touch it. It only
    -- decides whether an NPC target PAYS.
    --
    -- Why it defaults off: Config.Combat.RequireWantedStatus applies to
    -- player targets only, so with this on, any ambient pedestrian
    -- qualified for both combat awards. That made the largest share of the
    -- farmable XP ceiling reachable with no police work at all -- provoke a
    -- passer-by into running and take them down, on repeat. Turning it on
    -- is a legitimate choice for a server that wants NPC K9 work to
    -- progress a handler; just know it is the single biggest lever on how
    -- fast XP can be farmed without doing anything real.
    mintXpForNpcCombatTargets = false,

    awards = {
        -- server/search.lua's HandleSearchTarget, at the point
        -- `contrabandFound == true` is already known (existing Phase 2
        -- success path — this is a new CONSUMER of that outcome, no change
        -- to search.lua's own validation order/cooldowns).
        searchContrabandFound = 25,
        -- server/tracking.lua's findTrackableSource resolving `found = true`
        -- is NOT, by itself, the award trigger — see trackArrivalRadius/
        -- trackArrivalTTLMs below. DEVELOPER_REFERENCE.md §13.4.1 open question 3
        -- explicitly flags that awarding on `found = true` alone lets a K9
        -- farm XP by repeatedly triggering a search without ever completing
        -- it; this implementation closes that by requiring the K9's own
        -- client to subsequently arrive within trackArrivalRadius of the
        -- SERVER's resolved coordinate before this amount is granted.
        trackSourceResolved   = 10,
        -- server/combat.lua's requestBiteHold success (DEVELOPER_REFERENCE.md
        -- §12.5.1). WIRED. The note that stood here -- "NOT YET WIRED:
        -- server/combat.lua does not exist in this codebase" -- predated
        -- Phase 3 combat landing and had gone stale; that file exists and
        -- calls AwardXP(citizenid, 'biteHoldSuccess') from its success
        -- path. See server/progression.lua's header for the call contract.
        biteHoldSuccess       = 20,
        -- server/combat.lua's requestTakedown success (DEVELOPER_REFERENCE.md
        -- §12.5.2) -- same stale-note correction as biteHoldSuccess above;
        -- this one is wired too.
        takedownSuccess       = 30,
        -- server/search.lua, awarded to a partnered handler/K9 who was
        -- ONLINE and physically within 15m of the search TARGET's own
        -- coordinates (not the searcher's) when a contraband find landed,
        -- with both parties at Trained tier or above. Minted through the
        -- same AwardXP chokepoint as everything else, so it draws on the
        -- shared 3,600 XP/hr budget rather than adding to it.
        --
        -- THE ARITHMETIC, because this codebase has closed eight XP farms
        -- and every new award has to show its working: uncapped, a 60s
        -- per-receiving-partner cooldown at 10 XP is 600 XP/hr, which
        -- pushes the uncapped five-mechanic sum to 6,300 XP/hr -- over the
        -- budget, which is exactly why it must route through it and does.
        -- Simulated as a fifth competing draw over a real hour, the total
        -- came to 3,665 XP, LOWER than the four-mechanic figure of 3,810:
        -- more demand divides a fixed supply, it does not enlarge it.
        -- Elite is still unreached at the two-hour mark.
        coopSearchBonus       = 10,

        -- server/tenure.lua's partnership-tenure milestones. Each is a
        -- ONE-TIME award per partnership row -- never repeating, never
        -- per-tick. That distinction is the whole safety argument: this is
        -- the only award in this table driven by a WALL CLOCK rather than a
        -- player action, so a recurring trickle would be a pure idle-XP
        -- farm. The hard cap (15+40+100 = 155 XP ever, per partnership) is
        -- what makes awarding from a non-activity-gated clock safe at all.
        -- UNTUNED PLACEHOLDERS, same review status as every other value
        -- here. For scale: the top XP tier is reached at 3500.
        partnershipTenure1Day  = 15,  -- 24 real-world hours of continuous active partnership
        partnershipTenure7Day  = 40,  -- 7 days
        partnershipTenure30Day = 100, -- 30 days
    },

    -- 'citizenid' (default, per DEVELOPER_REFERENCE.md §13.2's own default and
    -- DEVELOPER_REFERENCE.md#xp-schema §4's schema sketch, which
    -- assumes this): XP belongs to the K9 character itself and is portable
    -- across a department change (k9_progression is keyed by citizenid
    -- alone, no job column). 'job' would need a composite (citizenid, job)
    -- primary key instead, mirroring k9_certifications — NOT implemented by
    -- this pass; DEVELOPER_REFERENCE.md §13.6 item 2 flags this as a genuinely open
    -- product call still needing explicit sign-off. Left at the documented
    -- default rather than silently guessed differently.
    scopePerCitizenidOrJob = 'citizenid',

    -- EXTENSION beyond DEVELOPER_REFERENCE.md §13.2's own sketch (that section only
    -- specified `awards`/`scopePerCitizenidOrJob`) — added to actually
    -- resolve open question 3 above rather than leave the farm exploit it
    -- flags unresolved. The `findTrackableSource` reveal itself stays
    -- purely client-cosmetic (no XP consequence at that point, per §11.6);
    -- `trackSourceResolved` XP is only granted once the K9's own client
    -- reports arrival within this radius of the coordinate the SERVER
    -- resolved — server/tracking.lua re-measures live distance itself
    -- against its own server-held pending-arrival state, never a
    -- client-supplied coordinate or distance claim.
    trackArrivalRadius = 3.0,    -- meters
    trackArrivalTTLMs  = 60000,  -- how long a resolved-but-unreached source stays eligible for a late arrival report before expiring — prevents a stale pending-arrival slot from awarding XP for a long-abandoned search
}

-- ======================================================================
-- HANDLER XP -- what each HANDLER action pays. Config.XP above pays the dog;
-- this pays the person, into a separate total with its own ladder
-- (Config.HandlerXPTiers).
--
-- Five things earn handler XP: certifying someone new, treating an injured
-- K9, deploying a kennel, and three one-time partnership milestones.
--
-- BEFORE YOU RAISE ANY OF THESE. Each award is throttled by its own mint
-- cooldown, and the numbers below were chosen against those throttles --
-- certifying is the largest because the same pair cannot pay again for 24
-- hours, treating and deploying are small because they are repeatable. They
-- also share ONE budget with the K9's own XP: 3,600 XP per hour per person,
-- combined, not each. Raising a number here does not raise that ceiling; it
-- just means fewer actions reach it.
--
-- Which cooldown guards which award, and the farm loop each one closes:
-- DEVELOPER_REFERENCE.md §22.
-- ======================================================================
Config.HandlerXP = {
    awards = {
        handlerCertifyK9              = 50,
        handlerTreatK9                = 12,
        handlerKennelDeploy           = 8,
        handlerPartnershipTenure1Day  = 15,
        handlerPartnershipTenure7Day  = 40,
        handlerPartnershipTenure30Day = 100,
    },
}

-- ======================================================================
-- THE REAL CEILING ON HOW MUCH XP ANYONE CAN EARN -- AND WHY IT IS NOT A
-- SETTING IN THIS FILE.
--
-- Every award above, in both Config.XP.awards and Config.HandlerXP.awards,
-- is ALSO capped by one shared "no more than this much per hour, no matter
-- where it came from" limit per person -- currently 3,600 XP in any rolling
-- hour, counted across both tables together. That number is not a setting
-- here. It lives in the code, in server/progression.lua, as the constant
-- XP_MINT_BUDGET_CAP_XP.
--
-- WHY THIS MATTERS TO YOU: if you raise an award above and a player who is
-- already busy does not seem to earn any faster, this hidden ceiling is
-- very likely why. They have already hit their hourly limit, and no single
-- award number can push them past it. That is intentional -- it exists so
-- that no one source of XP (including one you raise later) can outrun every
-- other one and turn into a farm.
--
-- SHOULD IT BE A SETTING? Deliberately left as a code constant for now.
-- Several of the rank thresholds and award amounts in this file were worked
-- out by hand against this exact figure -- Config.XPTiers' own comment shows
-- the arithmetic. Raising it from the tablet, with nothing warning you what
-- it is attached to, could quietly invalidate all of that at once. If it is
-- ever exposed as a setting it needs a plain warning saying so, not just a
-- minimum and a maximum.
-- ======================================================================

-- ======================================================================
-- CONTRABAND ALERT THRESHOLDS — Phase 2, placeholder pending
-- config-validator/economy review against actual ox_inventory item weights.
-- Order matters: server/search.lua walks this list and keeps the LAST tier
-- whose minWeight the total contraband weight meets or exceeds, so entries
-- must stay sorted ascending by minWeight. The 'clean' baseline is
-- mandatory (DEVELOPER_REFERENCE.md §11.4) so a zero-contraband result always resolves to
-- a real tier instead of falling through unhandled.
-- ======================================================================
Config.ContrabandAlertTiers = {
    { minWeight = 0,   alert = 'clean' },           -- nothing found / below any threshold
    { minWeight = 1,   alert = 'whine' },           -- small personal-use amount
    -- RAISED 250 -> 3000. At 250 this tier was below a SINGLE handgun or a
    -- single kilo brick (each roughly 1000 in ox_inventory's own weight
    -- units, which are grams -- its own shipped examples put a bulletproof
    -- vest at 3000 and a bottle of water at 500). So one gun found on one
    -- person, and a car boot with five kilos in it, produced the identical
    -- loudest alert. The top tier carried no information about how big the
    -- find actually was, which is the entire point of having tiers.
    -- 3000 is a genuinely large haul -- roughly three kilo bricks, or
    -- several weapons together -- so a single item no longer maxes it out.
    -- These item weights come from YOUR server's own inventory, read live,
    -- never copied here; if your contraband items weigh very differently,
    -- this is the number to move.
    { minWeight = 3000, alert = 'aggressive_bark' }, -- large stash
}

-- ======================================================================
-- FIND ALERTS (Config.Features.FindAlerts) -- PROJECT_HISTORY.md §1. A reaction
-- layer over the tier names Config.ContrabandAlertTiers above already
-- defines. It adds no new tiers; it only says how the SEARCHING K9's own
-- character should react to each existing one.
--
-- THERE IS DELIBERATELY NO 'clean' ROW, and that is not an oversight. A
-- real detection dog's trained final response only fires on a genuine
-- positive. A tier with no row here -- 'clean', or any new tier you add to
-- Config.ContrabandAlertTiers above without adding a row here -- means "no
-- automatic reaction". It fails closed to silence; it never guesses.
--
-- `sit` plays the same sit animation the manual Sit radial option uses.
-- `sound` is a sound name, and both below resolve to a real file that
-- actually ships (html/sounds/bark_alert.ogg and bark_aggressive.ogg). A
-- sound name with no file behind it degrades to silence, which looks
-- exactly like the feature being switched off -- so if you change these,
-- check html/sounds/ for what is actually there.
-- ======================================================================
Config.FindAlerts = {
    reactionsByAlertTier = {
        whine           = { sit = true, sound = 'Bark_Alert' },
        aggressive_bark = { sit = true, sound = 'Bark_Aggressive' },
    },

    -- Also react when the K9 reaches the end of a scent, blood or gunpowder
    -- trail, with the same strength as a big find.
    --
    -- THAT LIMITATION IS GONE (this pass). This block used to warn that the
    -- reaction stayed silent whenever Config.Features.XPProgression was
    -- switched off, because the event behind it began life as the XP
    -- trigger and was gated on that flag. It is not any more --
    -- client/tracking.lua now reports arrival unconditionally, and the
    -- server still mints no XP while the flag is off. So this works with
    -- XP progression on or off, exactly like the search reaction above.
    -- The warning is kept here, corrected rather than deleted, because an
    -- owner who read the old text may have turned this off believing it
    -- did nothing.
    reactOnTrackArrival = true,
}

-- ======================================================================
-- TRACKING (scent / blood / gunpowder). Ranges in meters, ages/
-- time windows in seconds. Each trail TYPE is independently gated by its
-- own Config.Features flag (ScentTracking / BloodTracking /
-- GunpowderSniffing) — these tuning tables only take effect for whichever
-- types are enabled; read at the point of use (search command execution),
-- not cached at resource start, per §3's acceptance criteria applied here.
-- ======================================================================
Config.Tracking = {
    Scent = {
        maxRange         = 40.0,  -- max distance from the K9's current position to a valid scent source at search time
        maxAgeSeconds    = 900,   -- how long a dropped item stays trackable as a scent source (§9 item 17 close-out, 2026-08-23). Deliberately longer than Blood/Gunpowder's 300s/120s -- a physical dropped item sitting on the ground doesn't decay the way a damage/gunfire event does. Judgment call, not independently confirmed against real gameplay balance -- DEVELOPER_REFERENCE.md#scent-source-resolution §4 flags this as worth a product-manager/config-validator/economy-balance-agent pass; revisit if playtesting says otherwise.
        markerSpacing    = 3.0,   -- meters between rendered trail markers/checkpoints
        searchCooldownMs = 5000,  -- per-player cooldown on re-issuing a "search" command of this type
        relayCooldownMs  = 1000,  -- per-dropping-player cap on how often the ox_inventory 'swapItems' hook (server/tracking.lua) logs a new scent-source entry. UNLIKE Blood/Gunpowder's field of the same name, this is NOT closing an anti-forgery gap -- the hook is server-to-server, so `payload.source` cannot be spoofed to claim a drop that didn't happen. It's defense-in-depth against a rapid drop/pickup/drop loop growing the server-side scent log unbounded between prune passes. Placeholder pending tuning.

        -- HARD CEILING on the total number of scent entries held in memory
        -- AT ONCE, across every player combined -- completely independent
        -- of maxAgeSeconds above. maxAgeSeconds only ever throws away an
        -- entry once it gets OLD; it says nothing about how many can pile
        -- up before then. The arithmetic, worked from this table's own
        -- numbers: relayCooldownMs (1000ms) lets one dropping player add at
        -- most one entry per second, and maxAgeSeconds (900s) keeps each
        -- one around for 15 minutes -- so ONE player sustaining that rate
        -- for the entire window logs up to 900 entries
        -- (900,000ms / 1000ms). At 128 players doing that at once -- a
        -- genuinely normal busy evening of full-server activity, not an
        -- attack -- that is up to 115,200 entries in this table alone.
        -- Once the log hits this many entries, adding a new one drops the
        -- OLDEST entry to make room (never the newest -- a dog is most
        -- likely to be tracking whatever was JUST logged). 6,000 is
        -- deliberately generous: it holds roughly 6-7 players' worth of
        -- continuous worst-case dropping for the ENTIRE 15-minute window,
        -- all at once, which is already far beyond what real play produces
        -- (nobody drops and picks an item back up once a second, nonstop,
        -- for 15 minutes). Raise it if your server is bigger than 128 slots
        -- or busier than this -- there is no reason to lower it on a normal
        -- server.
        maxLoggedEntries = 6000,
    },
    Blood = {
        maxRange         = 40.0,
        maxAgeSeconds    = 300,   -- damage events older than this are no longer trackable (pruned from the server-side log, §11.4)
        markerSpacing    = 3.0,
        searchCooldownMs = 5000,
        relayCooldownMs  = 500,   -- per-victim cap on how often relayDamageEvent may log a new entry — distinct from searchCooldownMs (a query-side cooldown); guards the ingest side against a flood of legitimate rapid hits (multiple pellets/DoT ticks) or a modified client bypassing the client-side debounce. Placeholder pending an economy/perf tuning pass.

        -- HARD CEILING, same idea as Scent.maxLoggedEntries above -- read
        -- that field's own comment first for the full "why this exists and
        -- why eviction takes the oldest entry" explanation; only the
        -- arithmetic differs here. At this table's own relayCooldownMs
        -- (500ms) and maxAgeSeconds (300s), one continuously-bleeding
        -- player can log up to 600 entries (300,000ms / 500ms) before their
        -- own oldest one ages out. At 128 players doing that simultaneously
        -- -- a genuinely normal, busy full-server firefight, not an
        -- adversarial edge case -- that is up to 76,800 entries in this
        -- table alone (this is the largest of the three worst cases,
        -- because Blood has both the shortest relayCooldownMs and a longer
        -- window than Gunpowder). 8,000 is deliberately generous: it holds
        -- roughly 13 players' worth of continuous worst-case bleeding for
        -- the ENTIRE 5-minute window all at once -- a genuinely enormous,
        -- sustained multi-officer firefight -- while still cutting this
        -- table's own worst-case memory footprint from tens of megabytes
        -- down to roughly 1-2MB. Raise it for a bigger/busier server; there
        -- is no reason to lower it on a normal one.
        maxLoggedEntries = 8000,
    },
    Gunpowder = {
        maxRange         = 40.0,
        maxAgeSeconds    = 120,   -- shorter window than blood -- residue is time-sensitive
        markerSpacing    = 3.0,
        searchCooldownMs = 5000,
        relayCooldownMs  = 300,   -- per-shooter cap on how often relayWeaponFire may log a new entry, same rationale as Blood.relayCooldownMs above. Placeholder pending tuning.

        -- HARD CEILING, same idea as Scent.maxLoggedEntries/Blood.maxLoggedEntries
        -- above -- read Scent's own comment first for the full "why this
        -- exists and why eviction takes the oldest entry" explanation. At
        -- this table's own relayCooldownMs (300ms) and maxAgeSeconds
        -- (120s), one continuously-firing player can log up to 400 entries
        -- (120,000ms / 300ms) before their own oldest one ages out. At 128
        -- players doing that simultaneously -- again, a normal busy
        -- server's full-scale shootout, not an attack -- that is up to
        -- 51,200 entries in this table alone. 6,000 is deliberately
        -- generous: it holds roughly 15 players' worth of continuous
        -- worst-case firing for the ENTIRE 2-minute window all at once,
        -- while cutting this table's own worst-case memory footprint from
        -- several megabytes down to roughly 1MB. Raise it for a
        -- bigger/busier server; there is no reason to lower it on a normal
        -- one.
        --
        -- Combined with Scent's and Blood's own ceilings above, these three
        -- caps bring the resource-wide worst case for ALL THREE logs
        -- together down from roughly 243,000 entries / 35-50MB
        -- (uncapped, at 128 players sustaining every type at once) to
        -- 20,000 entries / roughly 3-4MB -- still by far the largest
        -- in-memory structure this resource holds, but no longer an
        -- unbounded one.
        maxLoggedEntries = 6000,
    },

    -- ==================================================================
    -- ScentVision -- the coloured dots a handler follows.
    --
    -- Editing a SERVER-side value below takes effect on the next capture,
    -- no restart. Editing a CLIENT-side one (pollIntervalMs, the fade
    -- settings) needs the player to reconnect or the resource to restart --
    -- that is true of every client-side setting in this resource, not just
    -- these. Turning the feature OFF is the one thing that always takes
    -- effect immediately, even mid-render.
    --
    -- Setting any *Ms or *Meters field to 0 or a negative number does NOT
    -- mean "forever" -- it is refused, clamped to a safe default, and warned
    -- about by name in the server console.
    --
    -- Why the start/stop asymmetry is deliberate: DEVELOPER_REFERENCE.md §22.
    -- ==================================================================
    ScentVision = {
        -- CAPTURE (server/tracking.lua's position-sampling thread):
        sampleIntervalMs        = 4000, -- how often EACH connected player's own live position is sampled into their own trail. Lower = a denser, more continuous-looking trail at a higher per-tick native-call cost across the whole population; higher = cheaper but coarser. 4s at typical on-foot speed spaces dots a few metres apart, matching the "well-spaced dots, not a photograph of every footstep" brief.
        minSampleMovementMeters  = 2.0, -- a new point is only recorded if the player has moved at least this far since their OWN last recorded point -- keeps a stationary/AFK player from stacking redundant, visually-overlapping dots at one spot.
        maxPointsPerPerson       = 15,  -- hard per-person ring-buffer ceiling, enforced on every capture (oldest evicted first) independent of the age-based expiry below -- this is the real worst-case bound the memory math in this pass's own report is computed from; a misconfigured tiny sampleIntervalMs can never exceed it.
        dotLifetimeMs            = 45000, -- EACH DOT'S OWN age-out timer (45s shipped default), timestamped at the moment that specific dot was recorded -- never a single timer for the whole trail. The oldest dot vanishes first; the trail's remaining length is itself the "how long ago did they pass" signal. Non-positive is refused (never "forever") -- see this table's own header note above.
        fadeEnabled              = true,  -- true: a dot's opacity ramps down to 0 over the tail end of its own dotLifetimeMs rather than blinking out; false: full opacity until the instant it expires, then gone. Client-only cosmetic -- flip off for hard edges.
        fadeStartFraction        = 0.5,   -- fadeEnabled only: a dot stays fully opaque until this fraction of ITS OWN lifetime has elapsed (0.5 = halfway, ~22.5s in at the shipped default), then fades linearly the rest of the way to exactly 0 at expiry. Clamped to [0, 1) at read time.

        -- REVEAL (server/tracking.lua's getScentVisionPoints callback) --
        -- see server/tracking.lua's own header for why colours are scoped
        -- to a small "handful" of nearby trails rather than the whole
        -- server, and why that is also what keeps a query cheap at a large
        -- population.
        queryRangeMeters         = 40.0, -- how far from the QUERYING K9's own live position a dot must be to be revealed at all.
        maxVisibleTrails         = 5,    -- "a handful" (the owner's own word) -- how many DISTINCT people's trails one K9 is ever shown at once, nearest-first. This is also the exact ceiling on genuinely distinguishable colours this feature promises -- see `palette` below and server/tracking.lua's header. Raising this past #palette below reuses colours (a loud one-time warning is printed) rather than silently doing nothing.
        queryMaxPointsPerTrail   = 12,   -- per shown trail, at most this many of that person's own dots are revealed, nearest-to-the-K9-first -- a second cap on top of maxPointsPerPerson so a single trail's own on-screen density can be tuned independently of the storage-side cap.
        queryCooldownMs          = 1000, -- server-enforced FLOOR between one caller's queries, independent of the client's own poll cadence below -- defense-in-depth against a modified client polling faster than intended.
        pollIntervalMs           = 1500, -- the CLIENT's own target poll cadence while the ability is toggled on.

        -- ==================================================================
        -- MODE -- owner-directed pass: "make the scent tracking a keybind
        -- and choose always active or [not]". READ THIS EVEN IF YOU DO NOT
        -- CODE -- it decides whether your handlers have to press a button to
        -- see this at all, and what that choice costs.
        --
        -- Three plain-English choices, typed exactly as shown (in quotes,
        -- lowercase):
        --
        --   'keybind' (RECOMMENDED, and the default) -- a handler presses
        --   the key below (. -- the full stop / period -- by default, rebindable per-player in their own
        --   FiveM Settings) to see the coloured dots, and presses it again
        --   to stop. This is the original brief exactly as asked for, and
        --   costs nothing extra: nobody sees anything on their screen until
        --   they deliberately ask for it.
        --
        --   'always' -- every eligible handler (certified, controlling
        --   their own K9, same access check as the keybind uses) sees the
        --   dots on their screen all the time, automatically, from the
        --   moment they are eligible, with nothing to press. Nobody has to
        --   remember a key, but nobody can turn it off for themselves
        --   either -- it is a server-wide decision, not a per-player
        --   preference. THE COST IS PURELY VISUAL, NOT PERFORMANCE: the
        --   server was already doing the population-wide work of recording
        --   everyone's recent footsteps whenever this feature is on at all
        --   (see the CAPTURE section above) -- 'always' does not make the
        --   server do one bit more of that work than 'keybind' already
        --   does. The only difference is who is looking at the results and
        --   when. The real cost is screen clutter: a handler mid-firefight
        --   or mid-conversation gets coloured dots on their screen whether
        --   they wanted them right then or not.
        --
        --   'off' -- nobody sees this at all, ever, and the key does
        --   nothing if pressed. Different from turning the whole
        --   Config.Features.ScentVision switch off further up this file:
        --   THAT stops the server from recording anyone's footsteps in the
        --   first place, so turning it back on later starts from nothing
        --   and needs a few minutes to build up trails again. `mode = 'off'`
        --   keeps that recording running quietly in the background the
        --   whole time -- so if you switch to 'keybind' or 'always' later,
        --   there is already a trail waiting, with no warm-up wait.
        --
        -- WHAT "CHOOSE" MEANS HERE, IN PRACTICE: this is a config.lua
        -- setting, not (yet) a high-command-tablet dial like the numeric
        -- settings above it -- change the value, save the file, and restart
        -- this resource (`restart qbx_k9unit`) for it to take effect, the
        -- same as almost every other setting in this file. (The handful of
        -- settings that skip the restart and apply the instant you save
        -- them from the tablet are the ones server/runtimecontrol.lua's own
        -- registry explicitly lists -- this is deliberately not one of
        -- them THIS PASS, because that registry only understands a number
        -- with a min and a max today, not a choice of words like this one;
        -- see that file's own comment next to `Tracking.ScentVision.*` for
        -- the honest "not built yet, not silently dropped" note.) One thing
        -- that IS instant, with no restart at all: if a handler is already
        -- looking at dots (from 'always', or from having pressed the key)
        -- the moment Config.Features.ScentVision itself gets switched off
        -- from the tablet, their screen clears immediately -- turning THAT
        -- switch off always wins, live, over whatever this `mode` says.
        --
        -- A typo or an unrecognised word here (anything other than the
        -- three exact strings above) is never a crash and never silently
        -- becomes 'always' by accident -- it falls back to 'keybind' (the
        -- safest, most conservative choice) and prints one clear warning to
        -- the server console naming this exact setting, the same
        -- clamp-and-warn promise every other setting in this file makes.
        mode = 'keybind',

        -- KEYBIND. A DEFAULT only -- a player who rebinds this in their own
        -- FiveM Settings keeps their choice across a config edit or an
        -- update.
        --
        -- IF YOU CHANGE IT: check it does not collide with another default
        -- in this file. Reading the RegisterKeyMapping calls is not enough,
        -- because several defaults live in config values rather than in the
        -- call -- a collision shipped here once for exactly that reason.
        -- The resolved defaults in use are listed in
        -- DEVELOPER_REFERENCE.md §22.
        --
        -- NOT 'Z': ox_lib's radial menu -- the menu every K9 action here
        -- lives in -- defaults to Z, so a Z default toggled scent vision
        -- every time a K9 opened their menu. tests/keybindcollisions_spec.lua
        -- now checks defaults against the keys ox_lib and ox_target own.
        keybind = 'PERIOD',

        -- One colour per visible trail. A person's colour is derived from
        -- their own citizenid, so the same person looks the same to every
        -- handler and across sessions -- at the cost that two people can
        -- occasionally draw the same colour. Chosen for separation at a
        -- glance, not tested for colour blindness. See
        -- DEVELOPER_REFERENCE.md §22.
        palette = {
            { r = 230, g = 25,  b = 75  }, -- red
            { r = 60,  g = 180, b = 75  }, -- green
            { r = 255, g = 225, b = 25  }, -- yellow
            { r = 0,   g = 130, b = 200 }, -- blue
            { r = 245, g = 130, b = 48  }, -- orange
        },

        -- ==================================================================
        -- CONTRABAND BODY HIGHLIGHT (owner-directed follow-up, 2026-08-26 --
        -- "diffrent colors on there body if they have explosives drugs
        -- etc"). While a handler is looking at scent vision, a person
        -- standing right next to the K9 ALSO gets a small stack of coloured
        -- marks near their body if they are CURRENTLY carrying contraband --
        -- one colour per contraband CATEGORY (a Config.K9Specializations
        -- key, e.g. narcotics/explosives), gated by the EXACT SAME
        -- specialization rule a real search already uses
        -- (Config.SearchContrabandItems' categorised entries,
        -- server/search.lua): a dog with no narcotics certification never
        -- sees a drug highlight, the same way it can never actually FIND
        -- drugs on a real search. Uncategorised contraband (the shared
        -- baseline every K9 with search access can already find, e.g. this
        -- file's own shipped Config.SearchContrabandItems placeholder list,
        -- which is 100% this shape today) shows its OWN single generic
        -- colour below regardless of specialization, matching search's own
        -- "found by everyone" baseline exactly.
        --
        -- THIS IS DELIBERATELY NOT A SUBSTITUTE FOR A REAL SEARCH, ON
        -- PURPOSE, NOT AS AN OVERSIGHT. It only ever tells a handler THAT
        -- something in a matching category is present on that person RIGHT
        -- NOW -- never what item, never how many, never how much it weighs
        -- -- and it never fires the ContrabandAlerts broadcast and never
        -- mints any XP (same "cosmetic reveal, no real capability granted"
        -- framing this whole ScentVision feature already carries). Only an
        -- actual "Search Person" (Config.SearchZones below) reveals any of
        -- that detail, and remains the one and only action that mints XP,
        -- logs to k9_search_log, and can trigger a bystander alert. Think of
        -- this as a nose twitch that tells the handler to go run the real
        -- search -- it does not replace running it, and a handler who never
        -- searches never learns anything more than "something's there".
        contrabandHighlight = {
            -- false: footprint trails above still show exactly as before,
            -- but nobody's body is ever recoloured for contraband on this
            -- server, for anybody, regardless of specialization. A
            -- deliberately SEPARATE on/off switch from Config.Features.
            -- ScentVision itself, so an operator who wants the coloured
            -- footprint trails WITHOUT the contraband half can turn just
            -- this off without losing the other.
            enabled = true,

            -- HOW CLOSE the K9 must actually be to a person before this
            -- ever checks what they are carrying. Deliberately SHORT --
            -- capped in code (server/tracking.lua) at
            -- Config.SearchZones.personSearchDistance below (2.0m, the same
            -- distance a real "Search Person" interaction already
            -- requires): raising this past that ceiling is refused and
            -- CLAMPED back down to it, with a console warning, rather than
            -- honoured. This is deliberately NOT the same number as
            -- `queryRangeMeters` above (40m, how far away a footprint trail
            -- is still visible) -- a wide range here would turn this
            -- feature into exactly the "scan a whole crowd from 40m away"
            -- x-ray it must never become. Lower = the K9 has to be closer
            -- (stronger guardrail, more like a real sniff); this file's own
            -- ceiling is the strongest this can ever be turned up to.
            rangeMeters = 2.0,

            -- One colour per Config.K9Specializations key, assigned the
            -- SAME deterministic-hash way `palette` above assigns a trail
            -- colour per citizenid (see that field's own updated comment
            -- for the honest collision-odds writeup, which applies here
            -- too) -- so a given category (e.g. narcotics) always renders
            -- the same colour for every handler, every session, and
            -- colours repeat only once there are more specializations than
            -- swatches here. Deliberately a SEPARATE palette from the trail
            -- one above, so a category highlight can never be mistaken for
            -- a person's own footprint-trail colour at a glance.
            categoryPalette = {
                { r = 155, g = 89,  b = 182 }, -- purple
                { r = 230, g = 126, b = 34  }, -- orange
                { r = 26,  g = 188, b = 156 }, -- teal
                { r = 231, g = 76,  b = 60  }, -- red
                { r = 52,  g = 152, b = 219 }, -- light blue
            },

            -- The ONE colour used for UNCATEGORISED contraband -- the
            -- shared baseline every K9 with search access already finds
            -- regardless of specialization (see this table's own header
            -- above). Deliberately a single FIXED colour, never drawn from
            -- `categoryPalette` above, so a handler can always tell
            -- "generic contraband, no specialization needed" apart from a
            -- specialization-specific category at a glance.
            baselineColor = { r = 241, g = 196, b = 15 }, -- amber/yellow
        },
    },
}

-- Water crossing degrades/breaks a visible trail (§6.3, §11.5). Applied by
-- client/tracking.lua while rendering ANY active trail (scent, blood, or
-- gunpowder) -- not a separate trackable type of its own, which is why it
-- has no maxRange/searchCooldownMs of its own above.
Config.WaterTrackingDecay = {
    sampleIntervalMeters = 2.0,  -- how often the rendered path is sampled for water while drawing it. Use GetWaterHeightNoWaves (0x8EE6B53CE13A9794), NOT plain GetWaterHeight -- confirmed by two independent native-verification passes that the wave-motion jitter in plain GetWaterHeight can cause inconsistent water/no-water reads between adjacent samples on calm shorelines; NoWaves gives a frame-stable read appropriate for a fixed-step poll like this.
    breaksTrail          = true, -- true: water fully breaks the trail, handler must re-search on the far bank (§6.3's stated behavior); false: only fades marker opacity near/in water instead of a hard break -- a softer alternative flagged here as a one-line config choice, not a spec mandate either way
}

-- ======================================================================
-- SEARCH ZONES & CONTRABAND. Item names below must match real
-- ox_inventory item names on the target server -- PLACEHOLDER list, needs
-- a config-validator/economy review before this ships for real. Item
-- WEIGHT for tier computation is read live from ox_inventory's own item
-- registry at search time, never duplicated into this config, so there is
-- exactly one source of truth for item weight and it can never drift out
-- of sync with a server's real items.lua.
--
-- OPTIONAL SPECIALIZATION CATEGORIES (owner-directed decluttering pass,
-- 2026-08-26 -- "if i am certed in drugs... it will only search for
-- drugs"). Two entry shapes now live in this SAME table, and BOTH are
-- always supported at once -- this is a plain Lua array with some keys
-- filled in, not a format switch, so an existing owner's plain array
-- config (below) keeps working completely unmodified:
--   1. A bare string, e.g. 'weed_bud' -- UNCATEGORISED. Found by EVERY K9
--      with search access, regardless of specialization. This is the
--      BASELINE and it is monotonic: specializing a dog never takes an
--      uncategorised item away from it (owner-directed follow-up, same
--      pass -- "make it more fluid... training a dog [must never make]
--      it worse at its job"). The shipped list below is 100% this shape,
--      so a fresh install finds every placeholder item exactly as it does
--      today, with nothing to grant.
--   2. `itemName = 'specializationKey'`, e.g. `coke_brick = 'narcotics'`
--      -- CATEGORISED. Found only by a K9 whose citizenid currently holds
--      that Config.K9Specializations key (server/certifications/'s
--      HasSpecialization, which carries its own High Command bypass --
--      see server/search.lua's own resolution comment). A dog with NO
--      matching specialization simply never finds this one specific item;
--      it still finds every uncategorised item normally. `'specializationKey'`
--      MUST be a real Config.K9Specializations key -- an entry naming
--      anything else is CLAMPED AND WARNED at boot (never asserted) and
--      degrades to shape 1 (uncategorised, found by everyone) -- see
--      server/search.lua's own validation block for the exact warning
--      text.
-- Example of BOTH shapes in one table (NOT what ships below -- illustrative
-- only): `{ 'weed_bud', coke_brick = 'narcotics', weapon_pistol = 'explosives' }`
-- -- weed_bud stays findable by every K9; coke_brick only by a
-- narcotics-specialized one; weapon_pistol only by an explosives-specialized
-- one.
-- ======================================================================
Config.SearchContrabandItems = {
    'weed_bud', 'coke_brick', 'meth_bag', 'weapon_pistol', -- placeholder examples only -- all UNCATEGORISED (shape 1) so an upgrading server's search results do not change until an owner deliberately opts an item into shape 2
}

Config.SearchZones = {
    vehicleSearchDistance = 2.0,   -- ox_target zone radius for "Search Vehicle"
    personSearchDistance  = 2.0,   -- ox_target zone radius for "Search Person"
    sniffAnimDurationMs   = 4000,  -- how long the sniff interaction takes before the result is revealed
    -- CORRECTED: this is a per-TARGET cooldown, SHARED ACROSS EVERY
    -- SEARCHER. It has no K9/searcher dimension at all -- see
    -- server/search.lua's TargetSearchCooldown, which keys only on the
    -- resolved plate or citizenid. The old comment here claimed
    -- "per-(K9, target)", which is what made the contraband XP farm look
    -- bounded when it was not: two officers alternating never wait, and one
    -- officer toggling a stash they control was throttled only by this.
    -- The XP award is now separately gated by a per-searcher mint cooldown
    -- in server/search.lua. (The mood system this used to contrast with was
    -- removed on 2026-09-02.)
    -- whose "per-(interactor, target)" claim IS accurate.
    searchCooldownMs      = 10000, -- prevents repeat-search spam against the same vehicle/person to fish for a different roll or just to harass
    alertBroadcastRadius  = 15.0,  -- max distance from the searched target's own live coordinates for a bystander to receive the ContrabandAlerts sound/reaction broadcast. Deliberately NOT a global TriggerClientEvent(-1, ...) like relayBark -- unlike a bark, this payload identifies a specific vehicle/person just flagged for contraband, so broadcasting it map-wide would leak that fact to an accomplice anywhere on the server. server/search.lua must iterate connected players and filter by this radius before sending. HARD CEILING: 200.0m, enforced in code (server/search.lua's own onResourceStart guard) -- a value above that is clamped back down to 200.0 rather than honored, specifically so this can never be raised high enough to functionally become a map-wide broadcast.
}

-- ======================================================================
-- DOOR INTERACTION (nudge-open / scratch-to-alert). See §11.6
-- for why "nudge-open" is conditioned on the target server having a
-- separate door-lock resource, and why it's scoped client-only (mirrors
-- the vehicle-entry-exit "no real capability granted" exception in §4.1).
-- ======================================================================
Config.DoorInteraction = {
    interactDistance      = 1.5,  -- max distance to a door entity to show either option
    nudgeRequiresUnlocked = true, -- hard requirement, not a toggle: nudge-open must never function as a lockpick bypass -- see §11.6
    scratchCooldownMs     = 3000, -- per-player cooldown on the scratch-to-alert sound cue, same rationale as Config.Features.BasicBarkSounds' server-side cooldown in server/main.lua
}

-- ======================================================================
-- VISION (thermal / night). Both are native-toggle keybinds, no
-- custom shader/asset -- see §11.6 for the exact natives confirmed/refined
-- against DEVELOPER_REFERENCE.md §7's original claim.
-- ======================================================================
-- client/vision.lua. Tuning for the partner camera feed above.
Config.CameraFeed = {
    -- No key: the partner camera is opened from the tablet only.
    fov                    = 50.0,  -- field of view, degrees. Lower = more zoomed in.
    k9EyeHeightOffset      = 0.65,  -- metres above a dog-shaped partner's feet. Approximate, not read off the model — tune it for the breeds you actually use.
    handlerEyeHeightOffset = 1.6,   -- metres above a human-shaped partner's feet. Same caveat.
}

-- VISION: there is one vision key, I ("/k9vision"), which steps Off ->
-- Night -> Thermal -> Off in one press, skipping whichever of ThermalVision/
-- NightVision you turn off above in Config.Features. The K9 menu's Senses
-- group also has a button for each mode. The separate K and J keys were
-- removed at the owner's request. Turn both flags off and the cycle just
-- tells the player nothing is available right now.

-- ======================================================================
-- COMBAT & ADVANCED AGILITY -- bite and hold, non-lethal takedowns, dragging.
-- All three ship on. Why each was held back until it was reviewed, and one
-- correction to the spec worth knowing: DEVELOPER_REFERENCE.md §22.
-- ======================================================================
-- IF YOU CAME HERE BECAUSE SOMEONE SAID "YOUR K9s ARE TOO STRONG" (or too
-- weak): this is one of only TWO places in this file that complaint usually
-- means. The other is Config.PursuitSprint, a long way further down --
-- search this file for `Config.PursuitSprint`. That one is the short burst
-- of extra running speed a dog gets while chasing a wanted suspect.
--
-- Which one you want depends on what people are actually complaining about:
--   "the dog runs people down too easily, nobody can outrun it"
--        -> Config.PursuitSprint, not anything below.
--   "once the dog has hold of you, you can never get away"
--        -> you are in the right place. Read on.
--
-- Every number below now says which way makes the dog stronger and which
-- way makes it weaker, because several of them are not intuitive -- lowering
-- a cooldown makes the dog STRONGER, and the two maxDuration settings are
-- rare-case safety ceilings that will look like they do nothing.
Config.Combat = {
    -- Can a K9 bite, take down or drag someone who is SITTING IN A
    -- VEHICLE? Default false -- a dog physically biting a person through
    -- a car door is almost certainly not what you want, and nothing was
    -- stopping it before this setting existed.
    --
    -- This is a game-design call as much as a safety one, so it is a
    -- switch rather than a decision made for you. The case for turning it
    -- ON is dragging: pulling a downed driver out of a car is a plausible
    -- thing to want, and this one setting currently covers all three
    -- actions together. If you want dragging allowed but biting not, say
    -- so and it can be split per action.
    ExcludeVehicleSeatedTargets = true,


    -- Applies to BiteAndHold and NonLethalTakedown's player-target paths
    -- below (and would apply to PropDragging's, if/when that's built).
    -- DEVELOPER_REFERENCE.md §12.0 item 5 — RESOLVED, secure-by-default.
    -- OFF: a K9 can bite, take down, drag and pursuit-sprint ANY player
    -- (owner: "the dog should be able to do that whether someone is marked
    -- or not"). Turn it on only if you want those moves limited to players
    -- your own setup flags as wanted -- WantedStatusCheckOverride below, or
    -- metadata.wanted / metadata.iswanted. NPC targets are never affected.
    RequireWantedStatus = false,

    -- THE SNIFF CHECKS FOR WARRANTS. When a K9 sniffs a person (third eye >
    -- Sniff Person) and the resource named here is running, the sniff also
    -- looks them up in its MDT and tells the K9 and its partner about an
    -- ACTIVE, APPROVED warrant -- information for the roleplay; it does not
    -- change what the K9 may do. Built for sc-dispatch (it reads
    -- sc-dispatch's own mdt_warrants table, and like sc-dispatch only
    -- approved warrants count -- pending and denied never).
    --   warrantTypes: a warrant is reported when its type contains one of
    --     these words (not case-sensitive). "Arrest Warrant" and "Bench
    --     Warrant" are; a "Search Warrant" is for a place, not a person, so
    --     it is not.
    -- Set resource = nil to turn this off.
    WantedFromDispatch = {
        resource = 'sc-dispatch',
        warrantTypes = { 'arrest', 'bench' },
    },

    -- function(playerId: number) -> boolean, OPTIONAL, nil by default.
    -- Expected to be the NORMAL path for a real server, not the exceptional
    -- one — DEVELOPER_REFERENCE.md §12.0 item 5's own fragmentation note flags the
    -- default metadata guess below as LOWER CONFIDENCE than
    -- PropDragging's equivalent (`IsPlayerDownedOverride`, not yet added —
    -- see this file's PropDragging note above), because there is no single
    -- ecosystem-dominant convention for exposing a networked player's
    -- "wanted" state the way there is for a downed/laststand flag. Wire
    -- this directly to your dispatch resource's own export/state
    -- (cd_dispatch/ps-dispatch/qs-dispatch/in-house all differ). If this
    -- errors when called, server/combat.lua FAILS CLOSED (treats the
    -- target as NOT eligible) rather than falling back to the default
    -- metadata guess below — a broken override must never silently widen
    -- who can be targeted.
    WantedStatusCheckOverride = nil,
    -- Default best-effort check used ONLY when the override above is nil:
    -- reads `metadata.wanted` / `metadata.iswanted` off the target's own
    -- qbx_core PlayerData if present. See the confidence note above before
    -- relying on this in production — most real servers are expected to
    -- supply the override instead.

    -- DEVELOPER_REFERENCE.md §12.0 item 8 — DETECTION ONLY, NEVER ENFORCEMENT (see
    -- that item's guardrail 3: no server-authoritative consequence may ever
    -- be conditioned on one of these signals firing). Real, implemented
    -- sampling in `server/combat.lua`, not a sketch — see that file's own
    -- "NON-COMPLIANCE DETECTION" section for the full design writeup this
    -- table's fields map onto.
    NonComplianceDetection = {
        -- DEFAULT CHANGED true -> false, and the reason recorded here used
        -- to be wrong in a way worth correcting rather than deleting.
        --
        -- It used to say this flag is independent of BiteAndHold/
        -- NonLethalTakedown/PropDragging "which all
        -- default false", so leaving it on would spin a 500ms thread
        -- sweeping a table that stays empty on a default install. Those four
        -- actually default TRUE (see Config.Features above), so on a default
        -- install that table is NOT empty and the thread would have had real
        -- work to do. The stated reasoning was backwards.
        --
        -- The setting itself is still correctly false, for a different and
        -- better reason: this is DETECTION ONLY and never enforcement (see
        -- guardrail 3 above), its thresholds below are openly marked
        -- UNTUNED, and its output is a log line nobody has asked for. An
        -- untuned detector running on every install produces noise a server
        -- owner then has to learn to ignore, which is worse than no detector
        -- at all. Turn it on when you actually intend to read what it
        -- reports, and expect to tune the numbers below against your own
        -- server before trusting them.
        enabled                = false,
        positionSampleWindowMs = 500,   -- how often the shared sampling thread re-reads every active hold/ragdoll's target position
        biteHoldIdleCeiling    = 0.3,   -- m/s -- a compliant BiteAndHold target is near-stationary (may turn in place); observed speed above (idleCeiling + biteHoldSpeedTolerance) is a candidate violation. UNTUNED placeholder, per item 8's own numbers.
        biteHoldSpeedTolerance = 0.5,   -- m/s -- item 8's own tightened recommendation for BiteAndHold specifically. Item 8's generic speedTolerance=1.0 baseline was flagged as too loose stacked on a 0.3 m/s idle ceiling, and has been deleted from this table entirely -- an audit confirmed it had no reader anywhere in the resource, under any feature flag; every effect type carries its own dedicated threshold instead. UNTUNED.
        biteHoldViolationSamples = 2,   -- consecutive over-threshold samples required before flagging — never a single noisy sample, per item 8's "never auto-punish/flag on one sample" instinct (mirrors server/tracking.lua's own FORGED TRAIL DECISION reasoning).
        takedownNetDisplacementMeters = 3.0, -- meters -- NonLethalTakedown uses NET DISPLACEMENT from the ragdoll-start position over the whole window as its primary signal instead of a continuous speed check (a genuine ragdoll produces noisy per-tick velocity from falling/sliding that a speed check would false-positive on) — see server/combat.lua's own comment for the disclosed simplification versus item 8's fuller "sustained consistent heading, not random tumbling drift" framing. UNTUNED.
        action                 = 'log', -- 'log' | 'notify_staff' -- deliberately NEVER 'auto_kick'/'auto_ban': a false positive from lag/desync must not itself become a punitive action without human review.
        -- function(playerId: number, effectType: string, evidence: table) -> nil, OPTIONAL, nil by default.
        -- A server that wants automated response beyond log/notify_staff
        -- builds it here, on top of real evidence — this resource never
        -- takes a punitive action on its own initiative. Any error raised
        -- by this callback is caught and logged; it never interrupts the
        -- sampling thread for other active holds.
        OnViolationOverride    = nil,
        -- PropDragging's own compliance slack, in METERS. Distinct from the
        -- speed-based thresholds above BY DESIGN: a drag's compliance
        -- signal compares the target's live position against the DRAGGING
        -- K9's own live position, not against an absolute speed ceiling,
        -- because DEVELOPER_REFERENCE.md §12.0 item 8's corollary is that a hostile
        -- target can simply self-detach (DetachEntity is very likely not
        -- ownership-gated). A target that has broken free reads as a
        -- growing gap, which an absolute speed ceiling would miss entirely.
        -- Log-only like every other field here — the ACTUAL enforcement for
        -- a runaway drag is Config.Combat.PropDragging.maxDragDistance
        -- below, which is checked unconditionally and is never gated behind
        -- `enabled`.
        dragComplianceSlackMeters = 4.0,
    },

    -- DEVELOPER_REFERENCE.md §12.5.4. MIXED Category A/B per §12.0 item 8, and the
    -- only Phase 3 mechanic that is: the ATTACH is Category A (server-side
    -- authoritative, robust against a hostile target client) while the
    -- SPEED LIMIT is Category B (SetPedMoveRateOverride is local-only, so a
    -- modified target client can ignore it). client/combat.lua re-asserts
    -- the attach EVERY TICK rather than once, specifically because a target
    -- can self-detach — see that file's own guardrail comments.
    -- ALL NUMERIC VALUES BELOW ARE UNREVIEWED PLACEHOLDERS pending a
    -- balance pass, same status as every other Phase 3 tuning number here.
    PropDragging = {
        -- HIGHER = a drag can be started from farther away (stronger). LOWER =
        -- the dog has to be closer (weaker).
        range              = 2.5,    -- meters, self-initiated trigger range (matches BiteAndHold's)
        -- HOW LONG THIS K9 MUST WAIT BEFORE STARTING ANOTHER DRAG, in
        -- milliseconds (1000 = one second). Counts from the moment a drag
        -- STARTS. Deliberately shorter than Bite & Hold's 20 seconds or a
        -- Takedown's 25: moving several downed people at one scene is the
        -- normal, intended use of this, and a long wait between bodies
        -- would punish exactly the thing the feature is for. What this
        -- number stops is a K9 firing the same request over and over.
        -- LOWER = the dog can start drags more often. HIGHER = less often.
        cooldownMs         = 8000,
        -- HOW LONG THE SAME PERSON IS LEFT ALONE, in milliseconds, counted
        -- from the moment a drag on them starts. This is the one that
        -- matters for fairness rather than spam.
        --
        -- A dragged person can let go themselves at any time (their own
        -- Drag / Release key). Without this number that escape would be
        -- worthless: the dog could simply grab them again the same second,
        -- forever, and a downed player would have no way out of the loop
        -- short of disconnecting. Set to the same 20 seconds as
        -- maxDragDurationMs below, so a drag that is allowed to run its
        -- full length can be followed straight away by another one (the
        -- legitimate "keep moving them further" case), while a drag the
        -- person escaped from two seconds in buys them the remaining
        -- eighteen.
        --
        -- LOWER = the same person can be re-grabbed sooner. HIGHER = they
        -- get longer between drags. Setting this to 0 or a negative number
        -- is refused and this default is used instead, with a warning.
        targetCooldownMs   = 20000,
        -- HIGHER = the dog can drag somebody farther before the server steps in
        -- and ends it (stronger). LOWER = a shorter leash on the whole drag
        -- (weaker).
        maxDragDistance    = 30.0,   -- meters from the drag's start point before the server force-ends it. THIS is the real "no unbounded trap" enforcement — checked unconditionally in the maintenance loop, never gated behind NonComplianceDetection.enabled.
        -- SAME CAVEAT AS Bite & Hold's maxDurationMs: a worst-case ceiling, not
        -- the usual length of a drag -- most end when the dog lets go. Raising
        -- it mainly affects the rare drag nobody ends manually.
        maxDragDurationMs  = 20000,  -- hard timeout if never manually released, same role as BiteAndHold's maxDurationMs
        -- LOWER (towards 0) = the person moves even slower while being dragged,
        -- so the dog has a firmer hold (stronger). HIGHER (towards 1.0) = they
        -- keep more of their normal speed (weaker). 1.0 means no slowdown at all.
        dragSpeedMultiplier = 0.4,   -- Category B: applied to the TARGET's move rate while dragged. A modified client may ignore this; that is disclosed, not solved.
        -- function(targetServerId: number) -> boolean|nil, OPTIONAL.
        -- DEVELOPER_REFERENCE.md §12.0 item 6 made this a REQUIRED active config
        -- surface rather than a commented-out placeholder, because the
        -- native-only fallback is genuinely unreliable for players:
        -- IsPedDeadOrDying/IsPedRagdoll measure raw physics state, not a
        -- server's scripted laststand, so they both false-positive (a
        -- ragdolling but conscious player) and false-negative (a player in
        -- a scripted laststand that keeps the ped "alive"). Point this at
        -- your own ambulance/laststand resource. server/combat.lua FAILS
        -- CLOSED if this errors — treats the target as NOT downed — and
        -- only falls back to a best-effort metadata.isdead/.inlaststand
        -- guess when this is nil, exactly like WantedStatusCheckOverride
        -- above.
        IsPlayerDownedOverride = nil,
        -- Default keyboard key for the "Drag / Release" TOGGLE keybind
        -- (client/keybinds.lua registers `k9dragtoggle` + this as its
        -- RegisterKeyMapping default). Always rebindable client-side, same
        -- disclosure the since-removed handler-down defense carried -- and the same
        -- REAL CONSTRAINT: RegisterKeyMapping only sets a DEFAULT. Once a
        -- player has rebound this in Settings > Key Bindings > FiveM,
        -- changing this value in a later config update does NOT move their
        -- existing binding -- it only changes what a BRAND NEW player (or
        -- one who never touched this specific binding) starts with.
        toggleKeybind = 'Y',
    },


    BiteAndHold = {
        -- HIGHER = the dog can start a bite hold from farther away (stronger,
        -- easier to reach a target). LOWER = it has to be closer (weaker).
        range         = 2.5,    -- meters, self-initiated trigger range
        -- PROBABLY NOT THE SETTING YOU WANT. This is a safety ceiling, not the
        -- usual length of a hold: nearly every hold ends long before it, when
        -- the dog lets go. Raising it only affects the rare hold nobody ends
        -- manually (that one runs longer -- stronger, but you will seldom see
        -- it). Lowering it shortens that same rare case (weaker) and changes an
        -- ordinary hold not at all. If "the dog is too strong", cooldownMs and
        -- targetCooldownMs below are the settings that will actually move it.
        maxDurationMs = 15000,  -- hard timeout if never manually released — THIS IS the "no unbounded trap" guarantee for a non-consensual mechanic, DEVELOPER_REFERENCE.md §12.0 item 4. Never remove without an equally-hard replacement cap.
        -- LOWER = the dog can start another bite hold sooner, so it is STRONGER.
        -- This catches people out: reaching for a smaller number here to weaken
        -- the dog does the opposite. HIGHER = a longer wait between attempts,
        -- which is what actually makes it WEAKER.
        cooldownMs    = 20000,  -- per-K9 cooldown between attempts
        -- Per-target cooldown, mirroring NonLethalTakedown.targetCooldownMs
        -- below. Without it the per-K9 cooldown is the only bound, and the
        -- `already_held` check does not help -- that only blocks a second
        -- CONCURRENT hold by a DIFFERENT K9, not the same K9 re-taking the
        -- same target once its own cooldown clears. A compliant or AFK
        -- target could therefore be bite-held every 20s indefinitely, each
        -- hold over MIN_BITE_HOLD_XP_DURATION_MS paying biteHoldSuccess --
        -- roughly 60 XP/min against one stationary target with no travel
        -- and no variety. Set slightly above NonLethalTakedown's 30000 on
        -- purpose: a bite hold can pay out every 3s of a 15s window,
        -- whereas a takedown is a single discrete event.
        --
        -- What this bounds, precisely: 35000 exceeds the 20000 per-K9
        -- cooldown, so against ONE target the per-target gate binds and the
        -- ceiling is about 2057 XP/hr. With two or more targets available
        -- the per-K9 cooldown binds instead and the ceiling rises to about
        -- 3600 XP/hr. That second number is the honest one for a populated
        -- server -- the per-target gate closes the degenerate
        -- single-stationary-target farm, it does not cap the mechanic
        -- overall, and the per-K9 cooldown was always the intended throttle
        -- for legitimate repeated use.
        -- LOWER = the same person can be bitten again sooner (STRONGER for the
        -- dog, rougher for them). HIGHER = they get longer between holds
        -- (WEAKER for the dog, kinder to the person on the receiving end).
        targetCooldownMs = 35000,
        -- Default keyboard key for the "Bite & Hold / Release" TOGGLE
        -- keybind (client/keybinds.lua registers `k9bitehold` + this as its
        -- RegisterKeyMapping default). Always rebindable client-side -- see
        -- PropDragging.toggleKeybind above for the full disclosure of the
        -- REAL CONSTRAINT: RegisterKeyMapping only sets a DEFAULT and
        -- cannot move a player's own already-rebound key.
        toggleKeybind = 'B',
    },
    NonLethalTakedown = {
        -- HIGHER = a takedown can be started from farther away (stronger).
        -- LOWER = the dog has to be closer (weaker).
        range               = 3.0,
        -- HIGHER = the target must be running even faster before a takedown is
        -- allowed at all, so fewer people qualify (WEAKER, harder to use).
        -- LOWER = a slower or nearly stationary person also qualifies
        -- (STRONGER, easier to use).
        minTargetSpeed      = 4.0,   -- m/s, SERVER-COMPUTED from a short position-sample window at request time (see server/combat.lua's own note on why this is a bounded two-sample measurement, not a continuously-running per-ped tracker) — never a client-claimed "I am sprinting" flag. Applies identically whether the target is an NPC or a player.
        -- NOT a strength setting. This only changes how quickly, and how
        -- forgivingly, the speed check above makes up its mind. Leave it alone
        -- unless you are chasing a specific case where the check fires when it
        -- should not, or refuses when it should.
        speedSampleWindowMs = 250,   -- how long the server waits between its two position samples to compute the target's speed for the check above — UNTUNED, and itself re-validates everything (existence, proximity, already-held, eligibility) again after the wait, same TOCTOU discipline as this resource's other yielding server calls.
        -- THIS is the real "how long does a takedown last" setting. Unlike Bite
        -- & Hold's maxDurationMs above, this one IS the usual length, not just a
        -- rare-case ceiling. HIGHER = the suspect stays down, and unable to be
        -- hurt, for longer (STRONGER). LOWER = shorter (WEAKER).
        ragdollDurationMs   = 4000,  -- hard cap on BOTH the forced-ragdoll hold and the SetEntityCanBeDamaged(false) bracket — THIS IS the "no unbounded trap" guarantee for this mechanic, DEVELOPER_REFERENCE.md §12.0 item 4 (named there explicitly as "the ragdoll/damage-suppression window in NonLethalTakedown"). UNTUNED.
        -- Cosmetic timing only -- changes how the fall LOOKS, not how strong a
        -- takedown is.
        ragdollFallTimeMs   = 1000,  -- how long the suspect is driven into the fall animation, in ms. Source-confirmed as the duration parameter of the underlying game call. Keep it below ragdollDurationMs above -- the fall should finish inside the damage-immunity window, not outlive it. UNTUNED: dimensionally sane, but how it FEELS needs a live test.
        -- Also not a strength setting, on top of the "may do nothing at all"
        -- warning below.
        ragdollFallTimeP2   = 1500,  -- a second timing value the same game call takes. Honest warning: the game's own documentation says testers could not work out what it does ("didn't seem to affect anything"), so changing this may do literally nothing. Exposed anyway because it costs nothing and a live test on your build might disagree. If tuning it changes nothing, that is the expected result, not a bug.
        -- LOWER = the dog can take somebody down again sooner (STRONGER -- not
        -- the direction to reach for if you want a weaker dog). HIGHER = a
        -- longer wait between takedowns (WEAKER).
        cooldownMs          = 25000, -- per-K9 cooldown
        -- LOWER = the same person can be taken down again sooner (STRONGER).
        -- HIGHER = they get longer in between (WEAKER).
        targetCooldownMs    = 30000, -- per-target cooldown -- stops repeat takedowns of the same already-downed target by multiple K9s in quick succession
        -- A safety backstop, not a strength setting -- changing it will not make
        -- takedowns feel stronger or weaker.
        healthFloor         = 100,   -- backstop only, NOT the primary non-lethal mechanism -- primary mechanism is the SetEntityCanBeDamaged bracket above
        -- Default keyboard key for the (non-toggle, one-shot) "Non-Lethal
        -- Takedown" keybind (client/keybinds.lua registers `k9takedown` +
        -- this as its RegisterKeyMapping default). Always rebindable
        -- client-side -- see PropDragging.toggleKeybind above for the full
        -- disclosure of the REAL CONSTRAINT: RegisterKeyMapping only sets a
        -- DEFAULT and cannot move a player's own already-rebound key.
        -- MOVED OFF 'T' (live-bug fix, owner report -- see the "DEFAULT
        -- KEYS AND CONTROL COLLISIONS" note in client/keybinds.lua's
        -- header): 'T' is the key that opens the FiveM chat box on every
        -- server, and a FiveM key mapping fires ALONGSIDE the game's/
        -- framework's own binding rather than replacing it -- so a K9 who
        -- typed anything in chat also threw a non-lethal takedown at
        -- whoever happened to be in front of them. 'LBRACKET' ( the `[`
        -- key ) is deliberately unglamorous: it is one of the few keys
        -- vanilla GTA V leaves unbound, and every letter key that is both
        -- free in GTA V and unused elsewhere in this resource was already
        -- taken by the sit/bark moves in the same fix. PICK YOUR OWN if
        -- `[` is awkward for your players -- that is exactly what this
        -- setting is for. Just do not put it back on 'T', 'V' (Change
        -- Camera View) or 'C' (Look Behind).
        keybind             = 'LBRACKET',
    },

    AgilityAdvanced = {
        -- DECIDED (DEVELOPER_REFERENCE.md §12.0 item 3, Revision 2, unaffected by
        -- the Revision 3 PvP reversal): multi-height capsule-sweep raycast
        -- is the Phase 3 default. 'taggedProp' remains a documented,
        -- theoretical per-server override shape but has NO implementation
        -- in this codebase — client/movement.lua asserts loudly at
        -- resource start if this is ever set to anything other than
        -- 'raycast', rather than silently no-op'ing.
        detectionMethod = 'raycast',
        maxVaultHeight  = 1.2,   -- meters -- DEVELOPER_REFERENCE.md §12.2 sketch value, UNTUNED (see client/movement.lua's own tuning-constants note: DEVELOPER_REFERENCE.md §12.5.5 lists exact height bands/capsule radius/forward distance as in-engine tuning work, not a design fork)
        vaultCooldownMs = 2000,  -- ms, UNTUNED placeholder, same status as above
    },
}

-- ======================================================================
-- HANDLER/K9 PARTNERSHIP REGISTRY (Config.Features.HandlerPartnership,
-- server/partnership.lua + client/partnership.lua). DEVELOPER_REFERENCE.md §12.0
-- item 7 (Revision 5, coder-architect) / §12.3's file-plan entry.
--
-- OWN TOP-LEVEL BLOCK, DELIBERATELY NOT NESTED UNDER Config.Combat: this
-- mechanic has its OWN file, its OWN feature flag (independent of
-- BiteAndHold per the resolved design's explicit
-- "one-flag-per-mechanic" reasoning), and its own owner (server/
-- partnership.lua, not server/combat.lua) — nesting its tuning knobs inside
-- Config.Combat (a different file's config namespace) would blur that
-- ownership split for no benefit. Mirrors this file's own established
-- convention of one dedicated top-level table per Phase 2/3 feature
-- (Config.Tracking, Config.SearchZones, Config.DoorInteraction, Config.Combat
-- above) rather than a single everything-table.
--
-- This registry started as a FOUNDATION ONLY, with no combat consequence
-- wired to it. The two combat mechanics DEVELOPER_REFERENCE.md 12.0 item 7
-- named as blocked on it -- the handler-down defense trigger and the recall
-- actor -- were built, then REMOVED on 2026-09-02 at the owner's request.
-- The registry outlived them: server/tenure.lua reads it for the tenure
-- bonus, and the tablet reads it to show who is partnered with whom. Both
-- call `GetActivePartnerCitizenId`/`IsActivePartnerOf` directly rather than
-- re-deriving their own partner lookup, per this registry's accessor
-- contract (see server/partnership.lua's header).
-- ======================================================================
Config.Partnership = {
    -- DEVELOPER_REFERENCE.md §12.0 item 7 point 1 explicitly leaves "reuse
    -- Config.CertifyProximityMeters or a dedicated
    -- Config.Combat.PartnerProximityMeters" as an implementer's call, not a
    -- design fork. A DEDICATED constant is used here (not a direct reuse of
    -- Config.CertifyProximityMeters, and not nested under Config.Combat --
    -- see this block's own header above) so this mechanic's own proximity
    -- rule can be tuned independently of certification's without an
    -- unrelated cross-feature edit. Same 5.0m default as
    -- Config.CertifyProximityMeters purely because it's a reasonable
    -- starting point for the same class of "stand near each other and
    -- confirm" interaction, not because the two are meant to stay coupled.
    ProximityMeters   = 5.0,

    -- Mirrors server/main.lua's LEASH_REQUEST_TTL_MS / LEASH_REQUEST_COOLDOWN_MS
    -- exactly (same "a request nobody answers shouldn't linger indefinitely
    -- available for a stale accept" / "stop UI-harassment via repeat
    -- prompts" reasoning as the leash consent handshake this mechanic
    -- deliberately mirrors — DEVELOPER_REFERENCE.md §12.0 item 7 point 1).
    RequestTTLMs      = 30000,
    RequestCooldownMs = 1000,

    -- server/tenure.lua (Config.Features.PartnershipTenureBonus). Nested
    -- here rather than given its own top-level block because it tunes THIS
    -- mechanic's payoff, not a subsystem of its own.
    TenureBonus = {
        -- server/tenure.lua's poll cadence, independent of
        -- Config.Wellbeing.tickIntervalMs (an unrelated subsystem).
        -- Milestones are hours-to-days away, so a coarse interval costs
        -- nothing in perceived responsiveness and keeps the one indexed
        -- SELECT this adds per online, actively-partnered K9 effectively
        -- free.
        checkIntervalMs = 300000, -- 5 minutes

        -- MUST stay sorted ascending by afterSeconds -- server/tenure.lua's
        -- tier walk breaks on the first unmet threshold, mirroring
        -- Config.ContrabandAlertTiers' identical documented ordering
        -- requirement. Each actionKey must have a matching entry in
        -- Config.XP.awards above, or the award silently resolves to nothing.
        --
        -- `handlerActionKey` -- OPTIONAL. WIRED (dead-config-field audit
        -- correction: this comment used to claim it was "NOT YET READ by
        -- server/tenure.lua" and "inert data with no consumer" -- false,
        -- and had been false since server/tenure.lua's own
        -- CheckTenureMilestonesForK9 was written; re-verified by reading
        -- that function directly before writing this note, not assumed).
        -- server/tenure.lua's `for tier = alreadyGranted + 1, targetTier do`
        -- loop already calls, immediately after its
        -- `AwardXP(k9Citizenid, milestone.actionKey)` line:
        --     if type(AwardHandlerXP) == 'function' and milestone and type(milestone.handlerActionKey) == 'string' then
        --         AwardHandlerXP(row.handler_citizenid, milestone.handlerActionKey)
        --     end
        -- paying the matching entry in Config.HandlerXP.awards above to
        -- `row.handler_citizenid` the SAME tick `actionKey` is paid to
        -- `k9Citizenid`. Same soft-dependency guard shape that call site
        -- already uses for AwardXP itself. Inherits that loop's existing
        -- one-time-per-row CAS guard and same-pair-reform seeding for free
        -- -- no separate anti-farm state needed for this half. Leaving a
        -- milestone entry's own `handlerActionKey` unset (or blank) simply
        -- pays no handler XP for that tier -- it does not error, and it is
        -- the only way left to opt a custom milestone OUT of paying handler
        -- XP at all.
        milestones = {
            { afterSeconds = 86400,   actionKey = 'partnershipTenure1Day',  handlerActionKey = 'handlerPartnershipTenure1Day'  },
            { afterSeconds = 604800,  actionKey = 'partnershipTenure7Day',  handlerActionKey = 'handlerPartnershipTenure7Day'  },
            { afterSeconds = 2592000, actionKey = 'partnershipTenure30Day', handlerActionKey = 'handlerPartnershipTenure30Day' },
        },
    },
}


-- ======================================================================
-- CONTRABAND SCREEN FX (Config.Features.ContrabandScreenFX) --
-- client/screenfx.lua. A brief timecycle effect on the SEARCHING K9 player's
-- own screen when their search turns up contraband -- sensory feedback for the
-- dog, not a penalty applied to the suspect.
--
-- An earlier version of THIS COMMENT said "the SEARCHED player's own screen",
-- which never matched the code: server/search.lua fires this at `source`, the
-- searcher. The code is the intended behaviour and the comment was wrong.
-- Worth stating rather than silently editing, because a future maintainer
-- reading only the old comment would have "fixed" the code to match it and
-- turned a cosmetic self-effect into something applied to another player.
-- ======================================================================
Config.ContrabandScreenFX = {
    -- Which Config.ContrabandAlertTiers tier(s) trigger the effect. Only
    -- the most severe by default -- firing on every tier would make this
    -- constant rather than notable.
    triggerTiers = { 'aggressive_bark' },

    -- VERIFIED. The candidate that shipped here first, 'drug_wobbly_shroom',
    -- DOES NOT EXIST -- a native audit checked every `drug_`-prefixed entry in
    -- a real game-data extraction of 2806+ timecycle modifiers and found only
    -- 'drug_wobbly' (56 modifications, "Drug" category, base game). The wrong
    -- name would have been a silent no-op forever: the feature would have
    -- shipped, been enabled, and simply never shown anything, with nothing in
    -- the logs to say why.
    modifierName = 'drug_wobbly',

    -- Deliberately well below DEVELOPER_REFERENCE.md 13.2's 8000ms sketch: this is
    -- meant to be feedback, not a screen-blocking penalty, and the
    -- modifier family is a disorienting one. client/screenfx.lua clamps its
    -- own effective ceiling to 4000ms regardless of what is set here.
    durationMs = 3000,
}

-- ======================================================================
-- ADMIN AUDIT SURFACE (Config.Features.AdminAuditCommands) --
-- server/admin.lua. Read-only SELECTs over the three tables this resource
-- writes. No mutation path exists in that file at all.
-- ======================================================================
Config.AdminAudit = {
    -- WHO CAN RUN THESE: police job rank, not an ACE permission. A caller
    -- must hold a job listed in Config.Departments below, and either be a
    -- boss of that job (job.isboss) or sit at or above that department's
    -- own `auditGrade`. There is no ACE grant to configure -- the old
    -- AcePermission key was removed on 2026-08-25 when server/admin.lua
    -- switched to job rank. SET auditGrade DELIBERATELY: these commands
    -- expose who searched whom and when, so it is a privacy boundary as
    -- well as an admin one.

    -- Whether a `source == 0` caller bypasses the rank check. DEFAULTS OFF,
    -- and think before turning it on: in FiveM `source == 0` is not only the
    -- server console. It is also an RCON client (authenticated by
    -- rcon_password alone) and ANY other resource on this server calling
    -- ExecuteCommand -- these commands are registered unrestricted, so a
    -- compromised or buggy co-located resource could otherwise read the whole
    -- audit trail with no rank at all. Turning this on accepts all three.
    -- A genuine console operator can instead be given a job grade at or
    -- above auditGrade, or simply query the database directly.
    TrustConsole = false,

    -- Shared across all three commands, keyed by caller.
    CommandCooldownMs = 3000,

    -- Per-command result caps. server/admin.lua additionally clamps every
    -- one of these into [1, 100] in code regardless of what is set here, so
    -- a careless edit cannot turn an audit command into a table dump.
    MaxResults = {
        Certifications = 25,
        Partnerships   = 25,
        SearchLog      = 25,
        -- GAP 2 closure (owner-directed "full control ... accountability"
        -- pass): backs the new qbx_k9unit:server:tabletAuditCatalog
        -- callback, which reads the eight previously write-only catalog-edit
        -- audit tables (cert tiers, permission keys, XP tiers, shop items,
        -- shop locations, per-K9 overrides, runtime overrides, tablet
        -- themes) -- server/admin.lua additionally clamps this into
        -- [1, 100] in code regardless of what is set here, same as every
        -- other key in this table.
        CatalogAudit   = 25,
    },
}

-- ======================================================================
-- PHASE 5 (R&D) — DEPLOYABLE KENNEL (Config.Features.DeployableKennel).
-- This shipped `false` by default when this section was written, pending
-- its own go-live review; that review has since happened and the flag now
-- ships `true` above.
-- DEVELOPER_REFERENCE.md#phase-5-research §5: "handler places a world...
-- kennel object... server-authoritative validation (proximity,
-- certification, one-per-handler limit), with cleanup on resource stop/
-- handler disconnect." See client/kennel.lua and server/kennel.lua for the
-- full implementation and their own file-header contracts.
--
-- PROP MODEL CONFIDENCE — read before changing `propModel` below:
-- `DEVELOPER_REFERENCE.md#phase-5-research` §5 found exactly ONE lead for a real
-- vanilla GTA doghouse/kennel prop name (`prop_doghouse_01`, sourced from
-- a DIFFERENT, unrelated FiveM resource's config default —
-- `fruitmob/murderface-pets`), and explicitly could NOT cross-verify it
-- against a second independent source this session (gtax.dev/gtahash.com/
-- a GTA Wiki "Doghouse" page were all blocked by this environment's
-- egress proxy). Per this project's established two-independent-source
-- confidence convention (see client/hud.lua's own stamina-native
-- confidence note for the same discipline applied to a native, applied
-- here to an asset name instead): PLAUSIBLE, NOT VERIFIED. Confirm it
-- actually streams/loads in-engine before treating it as settled — do not
-- silently upgrade this comment's confidence just because the feature
-- shipped without incident in one test session.
-- ======================================================================
Config.DeployableKennel = {
    -- Try this first. Single-source, unconfirmed lead — see the note
    -- above. client/kennel.lua's LoadModelWithTimeout() falls back to
    -- `fallbackPropModel` below if this model hash never loads within
    -- REQUEST_MODEL_TIMEOUT_MS, rather than silently placing nothing or
    -- erroring the whole feature out.
    -- `prop_dog_cage_01` (hash 379820688) is CONFIRMED REAL, high
    -- confidence: present in the full 21,631-entry DurtyFree
    -- gta-v-data-dumps ObjectList.ini, and corroborated independently by
    -- Forge/Pleb Masters' data-dump-derived object browser, which returns a
    -- real base-game record for it. The kennel does NOT silently degrade to
    -- the fallback in practice -- and if it ever did, `prop_tennis_ball` is
    -- confirmed real too, so even the degraded case renders something.
    --
    -- CORRECTION, and read this before picking a different model. This
    -- comment used to claim `prop_doghouse_01` had been "REFUTED" because it
    -- "does NOT appear in a 5,171-entry live object database". THAT CLAIM
    -- WAS WRONG. The pass that made it could only reach a partial slice of
    -- the very same file; a later full fetch of ObjectList.ini (21,631
    -- entries) finds `prop_doghouse_01` at line 9528, sitting immediately
    -- beside prop_dog_cage_01/prop_dog_cage_02, and Forge returns a real
    -- record for it: base game, Sep 2013, categorised under Beds and
    -- Bedroom / Decorations. It is a genuine, base-game, doghouse-shaped
    -- prop.
    --
    -- Nothing about the current behaviour depends on that correction --
    -- propModel is prop_dog_cage_01 and nothing calls the other name. It is
    -- corrected because a confident false negative is worse than no note at
    -- all: the next person who wants the kennel to look like an actual
    -- DOGHOUSE rather than a metal cage would have read the old paragraph
    -- and ruled out the one asset that does exactly that. If you want that
    -- look, `prop_doghouse_01` is a legitimate choice -- it is a different
    -- shape and size from the cage, so re-check restOffsetX/Y/Z below once
    -- you can see it in-engine.
    propModel = 'prop_dog_cage_01',

    -- Deliberately NOT a second guess at a "kennel-shaped" model name — a
    -- second unverified guess would carry the exact same single-source
    -- risk this fallback exists to avoid. Reuses `prop_tennis_ball`, the
    -- ONE prop name this same research pass (§4, FetchMechanic) rated
    -- highest-confidence "confirmed real and available" of any prop
    -- mentioned anywhere in that document — it traces to a real, working,
    -- source-read community script's shipped config default, not just a
    -- bare name reference. It is NOT thematically a kennel; it exists
    -- purely as a safe, visible, definitely-real placeholder so a bad
    -- `propModel` lead degrades to "an oddly-shaped but real object
    -- appears" rather than a silent failure or a broken/invisible entity.
    -- Swap for a real doghouse/kennel asset (custom-modeled or a
    -- confirmed vanilla prop) once one is verified in-engine.
    fallbackPropModel = 'prop_tennis_ball',

    -- Meters in front of the handler's own live server-side position
    -- (server/kennel.lua computes this from GetEntityForwardVector, never
    -- a client-claimed coordinate — see that file's header) where the
    -- kennel spawns before PlaceObjectOnGroundProperly snaps it to the
    -- ground. UNTUNED placeholder, same status as DEVELOPER_REFERENCE.md's own
    -- vault-tuning constants (client/movement.lua) — a reasonable-looking
    -- default, not a playtested value.
    placementForwardOffsetMeters = 2.0,

    -- ox_target interaction range for the "Pick Up Kennel" option
    -- (client/kennel.lua). Reuses the same order of magnitude as
    -- Config.VehicleInteractMeters's role for vehicle entry/exit rather
    -- than inventing an unrelated scale.
    interactDistanceMeters = 2.5,

    -- Per-source rate limit on *requesting* a new placement (server/
    -- kennel.lua's DeployCooldown) — spam defense only, distinct from the
    -- one-active-kennel-per-handler limit below (a handler who already has
    -- an active kennel is refused regardless of this cooldown; this only
    -- throttles how fast repeated requests can even reach that check).
    deployCooldownMs = 5000,

    -- How long server/kennel.lua holds a "waiting for the client to
    -- confirm it actually created the object" slot open before it expires
    -- and frees up for a new attempt — mirrors LEASH_REQUEST_TTL_MS's exact
    -- reasoning in server/main.lua (a request nobody ever answers must not
    -- linger indefinitely).
    pendingPlacementTtlMs = 15000,

    -- CARRY VISUAL (K9-can-ride-along pass -- "make the pickup feel real,"
    -- later corrected by the owner to "the SAME kennel, occupant and all,
    -- must move with the handler" -- see server/kennel.lua's own header
    -- CRITICAL SAFETY section for the full redesign this forced). Purely
    -- cosmetic bone/offset/rotation client/kennel.lua uses to
    -- AttachEntityToEntity the EXISTING, real, already-deployed kennel
    -- object onto a carrying handler's own ped -- NOT a freshly created
    -- prop (client/propattachment.lua's AttachPropToOwnPed is deliberately
    -- NOT used for this -- see client/kennel.lua's own header for why).
    -- UNTUNED placeholder, same disclosed-confidence status as
    -- placementForwardOffsetMeters above — boneIndex 0 (the root/pelvis
    -- bone) is deliberately used instead of a hand-specific bone: it is
    -- guaranteed valid on every ped skeleton (this resource's own
    -- client/combat.lua PropDragging attach already uses bone 0 for the
    -- same reason), whereas a specific hand-bone index could not be
    -- confirmed against a second independent source this session (the same
    -- egress-proxy blocker propModel's own confidence note above already
    -- discloses) and an invalid bone index is a real visual-placement risk,
    -- not just a cosmetic nitpick. The offsets below place the carried prop
    -- roughly in front of the handler's chest instead.
    carryBoneIndex = 0,
    carryOffsetX = 0.0,
    carryOffsetY = 0.3,
    carryOffsetZ = 0.35,
    carryRotX = 0.0,
    carryRotY = 0.0,
    carryRotZ = 0.0,

    -- REST VISUAL (K9-can-ride-along pass). Purely cosmetic offset
    -- client/kennel.lua uses to AttachEntityToEntity an occupant's OWN ped
    -- (a real, currently-connected player -- see server/kennel.lua's own
    -- header for why this is never a spawned ped) onto the kennel object
    -- itself. Defaults to the prop's own origin (0,0,0) rather than a
    -- guessed interior offset -- this feature's own propModel confidence
    -- note above already discloses that `prop_dog_cage_01`'s exact
    -- in-engine dimensions were never independently confirmed this
    -- session, so a guessed interior offset carries the identical
    -- unverified-asset risk the model name itself already carries; the
    -- origin is the one point guaranteed not to place the occupant
    -- floating outside the model's own bounds regardless of its real
    -- size.
    restOffsetX = 0.0,
    restOffsetY = 0.0,
    restOffsetZ = 0.0,
}
-- ONE-KENNEL-PER-HANDLER LIMIT (not a config knob — see server/kennel.lua's
-- header for the full "your call, documented" reasoning): the server-side
-- registry is a single-slot `Kennels[citizenid]`, not an array, so this is
-- a hardcoded invariant, not something a `maxActivePerHandler` field here
-- could raise without a real code change to the registry shape itself.
-- Deliberately NOT modeled as a per-area/spatial limit — see that file's
-- header for why.

-- ======================================================================
-- PHASE 5 (R&D) — ADVANCED BARK RADIAL (Config.Features.AdvancedBarkRadial —
-- layered on top of Config.Features.BasicBarkSounds per this resource's
-- existing Phase-5-on-Phase-1 convention, see client/radial.lua's Bark item
-- for the enforcement of that layering). This shipped `false` by default
-- when this section was written, pending its own go-live review; that
-- review has since happened and the flag now ships `true` above.
-- DEVELOPER_REFERENCE.md §6.7 names the variant set explicitly: "Radial bark options
-- (aggressive/alert/calm) each play a distinct sound asset attached to the
-- K9 entity" — that's the exact set shipped here, not an arbitrary pick
-- (DEVELOPER_REFERENCE.md#phase-5-research §1 confirms no other count is
-- named anywhere in the spec).
--
-- `sound` is still the SAME placeholder posture as client/main.lua's
-- BARK_SOUND_NAME/K9_SOUND_SET (see that file's header comment in full) —
-- none of these resolve to real, distinct authored audio yet.
-- DEVELOPER_REFERENCE.md#phase-5-research §1 confirms a real per-variant soundset needs
-- authored `.awc`/`dat151`/`dat54` RAGE-audio-bank assets, not just a
-- different string here — this table only carries the plumbing (which
-- placeholder name maps to which radial item/barkType), not the asset
-- itself. PlaySoundFromEntity with an unrecognized name/set combination is
-- a harmless no-op, so this ships safely with zero real audio, same as
-- Phase 1's single bark.
--
-- `barkType` is the exact string sent over the EXISTING
-- 'qbx_k9unit:server:relayBark' event (client/radial.lua) and echoed back
-- opaquely by server/main.lua's handler, which enforces
-- `BARK_TYPE_MAX_LENGTH = 16` — keep every `barkType` value below at or
-- under that length. server/main.lua itself is NOT modified for this
-- feature; it already accepts any opaque, length-capped string with no
-- enum validation.
-- ======================================================================
Config.AdvancedBarkRadial = {
    { barkType = 'bark_alert',      label = 'Alert Bark',      icon = 'triangle-exclamation', sound = 'Bark_Alert' },
    { barkType = 'bark_aggressive', label = 'Aggressive Bark', icon = 'skull',                sound = 'Bark_Aggressive' },
    { barkType = 'bark_calm',       label = 'Calm Bark',       icon = 'moon',                 sound = 'Bark_Calm' },
}

-- ======================================================================
-- K9 INVENTORY (ox_inventory stash). Backs
-- Config.Features.K9Inventory (still `false` above, per this resource's
-- "ship disabled until acceptance criteria are fully met" convention).
-- See DEVELOPER_REFERENCE.md §13.4.2 for the full security-critical integration
-- writeup this table backs, and server/inventory.lua's own header for the
-- concrete implementation (RegisterStash owner/groups derivation,
-- confidence-graded ox_inventory export notes). Transcribed from
-- DEVELOPER_REFERENCE.md §13.2's sketch, with `accessScope`'s Open Question (§13.4.2
-- item 1 / §13.6 item 3) RESOLVED below rather than left as a placeholder.
-- Every numeric value is still an unreviewed placeholder pending a
-- config-validator/economy-balance-agent pass (DEVELOPER_REFERENCE.md §9 item 4,
-- DEVELOPER_REFERENCE.md §13.5), same status every other Phase 3/4 sketch table in
-- this file carries — do not default Config.Features.K9Inventory to `true`
-- before that pass happens.
-- ======================================================================
Config.K9Inventory = {
    slots         = 5,
    maxWeight     = 8000,  -- grams-equivalent, same units ox_inventory's own item .weight fields use (unit convention confirmed: DEVELOPER_REFERENCE.md#contraband-search §1)
    interactRange = 2.0,

    -- 'department' is the ONLY supported value (coder-security finding,
    -- this pass — see server/inventory.lua's header "RESOLVED DESIGN
    -- DECISION" section for the full reasoning): any player whose job is a
    -- key in Config.Departments (any grade) may open a given K9's gear
    -- stash, shared-field-equipment framing, the same posture
    -- Config.K9Vehicles already gives patrol-vehicle trunk access.
    -- 'ownerOnly' was previously documented here as an equally-supported
    -- alternative -- it was NOT: ox_inventory's RegisterStash `owner`
    -- argument is never checked against the calling player's identity
    -- anywhere in ox_inventory's own open-inventory path (only `groups`
    -- is), so 'ownerOnly' provided no real access control at all.
    --
    -- CORRECTED (dead-config-field audit finding): this comment used to
    -- claim changing this value away from 'department' "will crash the
    -- resource on startup by design (assert, server/inventory.lua)". False
    -- -- server/inventory.lua's ResolveConfiguredAccessScope was
    -- deliberately changed from a hard assert to a WARN-AND-FORCE guard
    -- (see that file's own header "RESOLVED DESIGN DECISION" section) and
    -- explicitly "NEVER throws, NEVER aborts the caller". Setting this to
    -- anything other than 'department' does NOT crash this resource: at
    -- `onResourceStart` it prints one loud warning naming the bad value,
    -- silently forces this field back to 'department' for that session,
    -- and every K9 stash stays gated to department membership regardless.
    -- The old wording would have led an owner to believe a misconfigured
    -- value takes their server down; it actually self-corrects quietly.
    accessScope   = 'department',

    -- nil = no item whitelist enforced (ox_inventory's own slot/weight
    -- limits are the only restriction).
    --
    -- NOW ENFORCED. The note that stood here said this was deliberately not
    -- built, and warned an owner not to assume setting it did anything. That
    -- warning was correct when written and is now obsolete:
    -- server/inventory.lua enforces the list through ox_inventory's own
    -- `swapItems` hook.
    --
    -- Expects a plain array of item-name strings (same convention as
    -- Config.SearchContrabandItems). `nil` means no filtering, which stays the
    -- default -- an empty table would mean "allow nothing", a very different
    -- and much worse default to ship by accident.
    --
    -- Filters only what goes IN. Nothing is ever filtered on the way OUT, so a
    -- tightened list can never strand an item already in a stash -- that would
    -- be the unbounded trap this resource forbids.
    --
    -- The enforcement point was verified against ox_inventory's real source
    -- rather than assumed, because this resource has already shipped one
    -- illusory access control (an `accessScope` setting documented as
    -- restricting access that provided none). A hook returning false genuinely
    -- aborts before any mutation. If `registerHook` is unavailable on a given
    -- install, the stash still works unfiltered and logs one warning rather
    -- than silently pretending to filter.
    allowedItems  = nil,
}

-- ======================================================================
-- K9 MEDKIT (Config.Features.K9Medkit).
-- DEVELOPER_REFERENCE.md §13.4.4/§13.2. Item consumption + heal validation live in
-- server/medkit.lua; see that file's header for the full security-critical
-- writeup (mirrors server/search.lua's contraband-search trust boundary,
-- per that document's own explicit direction to reuse it as the template).
-- This shipped `false` by default when this section was written, pending
-- its own go-live review; that review has since happened and the flag now
-- ships `true` above. NUMERIC VALUES BELOW WERE UNREVIEWED PLACEHOLDERS at
-- that time, pending a config-validator/economy-balance-agent pass
-- (DEVELOPER_REFERENCE.md §9 item 4's scope, widened by DEVELOPER_REFERENCE.md §13.5) —
-- confirm that pass has actually happened before trusting these numbers on
-- a live server; this comment does not independently verify that it has.
-- ======================================================================
Config.K9Medkit = {
    itemName      = 'k9_medkit', -- PLACEHOLDER item name — must exist in the target server's ox_inventory items table; NOT registered as a hotbar-"useable" item by this resource, see server/medkit.lua's header for why
    healthRestore = 50,          -- native health units restored to the K9's REAL ped health, clamped to GetEntityMaxHealth server-side, never allowed to overheal
    range         = 2.0,         -- meters — server-enforced max distance between the using player and the target K9's own live positions, checked BEFORE any item consumption or health mutation
    cooldownMs    = 60000,       -- per-target (K9 citizenid) cooldown, prevents repeated instant-heal spam against the same K9
    -- Job names, in addition to any job ∈ Config.Departments, allowed to use
    -- this item on a K9 — mirrors DEVELOPER_REFERENCE.md §12.0 item 4's resolved
    -- "default metadata/job convention + override hook" pattern for the
    -- identical class of external-EMS-integration problem.
    emsJobs       = { 'ambulance' },
    -- IsMedkitUserAuthorizedOverride: function(usingPlayerServerId) -> boolean,
    -- OPTIONAL. Forward-looking override hook for a server whose EMS/
    -- qualification system isn't captured by a flat job-name list — left
    -- commented out until a server actually needs it, so it isn't mistaken
    -- for an active default. See server/medkit.lua's IsMedkitUserAuthorized.
    -- IsMedkitUserAuthorizedOverride = function(usingPlayerServerId) return false end,
}

-- ======================================================================
-- K9 WELLBEING (Config.Features.FatigueSystem). DEVELOPER_REFERENCE.md
-- §13.0 Decision 1 / §13.2 / §13.4.3: ONE shared config table, ONE shared
-- server/wellbeing.lua + client/wellbeing.lua pair, ONE shared per-citizenid
-- stat store and tick loop. This section once backed five independently
-- gated stats; the other four were removed on 2026-09-02 at the owner's
-- request and fatigue is all that remains. Its owning flag shipped `false`
-- by default when this section was written, pending its own go-live/balance
-- review; that review has since happened and it now ships `true` above.
-- NUMERIC VALUES BELOW WERE UNREVIEWED
-- PLACEHOLDERS at that time, pending a config-validator/economy-balance-agent
-- pass (DEVELOPER_REFERENCE.md §9 item 4's scope, widened by
-- DEVELOPER_REFERENCE.md §13.5) -- individual fields below that have since
-- been confirmed wired/tuned say so in their own comment; treat any field
-- without such a note as still an unreviewed placeholder.
-- ======================================================================
Config.Wellbeing = {
    tickIntervalMs = 5000, -- ONE shared server-side decay/regen tick for all five stats -- see server/wellbeing.lua's header for why this beats five independent timers

    Fatigue = {
        max                     = 100,
        sprintDecayPerTick      = 2.0,  -- applied per tick while server-computed speed indicates sprinting
        idleRegenPerTick        = 1.0,  -- per tick while not sprinting
        restRegenPerTick        = 4.0,  -- WIRED. server/wellbeing.lua scans GetAllObjects()/GetAllVehicles() once per tick (shared across all K9s, not per-K9) for restSources models and applies this instead of idleRegenPerTick when a K9 is within restRadius and not sprinting. Positions are resolved server-side; a client can never claim to be resting. The "NOT WIRED THIS PASS" note that stood here was true when written.
        restRadius              = 5.0,
        -- The prop names a K9 must be standing near to rest. A name that does
        -- not exist in the game fails SILENTLY -- the dog simply never rests
        -- near it and nothing says why -- so every entry here has been
        -- checked against a real prop database. Confidence is not uniform:
        -- 'prop_dog_cage_01' is confirmed in two independent sources; the
        -- bench, the couch and the three dog bowls in one. See
        -- DEVELOPER_REFERENCE.md §22 before adding to this list, and note
        -- that a plausible-looking name is not evidence -- 'water_bowl'
        -- shipped here for a long time and turned out never to have matched
        -- anything at all.
        restSources             = {
            'prop_dog_cage_01', 'prop_bench_04', 'prop_couch_01',
            'm25_1_prop_m51_dog_bowl_full',
            'm25_1_prop_m51_dog_bowl_empty',
            'm25_2_int_01_dog_bowl',
        },
        speedPenaltyThreshold   = 30,   -- fatigue below this value triggers the penalty. Also the exact line where a bonded handler's HUD badge starts calling their dog "Tired" -- raise it and that word appears sooner (a lower tolerance for tiredness), lower it and it appears later
        -- How much a tired K9 is slowed. This is now the ONLY speed penalty
        -- wellbeing applies -- the injury and mood penalties it used to
        -- compound with were removed on 2026-09-02 -- so the number you set
        -- here is the whole effect, not one factor of three. See
        -- DEVELOPER_REFERENCE.md §22 for why it was raised from 0.85.
        speedPenaltyMultiplier  = 0.90, -- fed into RecomputeK9MoveRate() (client/movement.lua, K9MoveRateModifiers.fatigue), never a standalone SetPedMoveRateOverride call
        -- NOT in DEVELOPER_REFERENCE.md §13.2's sketch verbatim -- added here
        -- because "sprinting" needs a concrete speed cutoff to classify
        -- from a server-side rolling position-sample (meters travelled per
        -- tick / tickIntervalMs). This file's own independent
        -- implementation of the general technique DEVELOPER_REFERENCE.md §12.5.2
        -- describes for NonLethalTakedown's speed gate (that document was
        -- not re-read this pass, per this session's file-scope boundary --
        -- reconcile against server/combat.lua's real implementation once
        -- Phase 3 lands, if the two ever need to agree exactly). Unreviewed
        -- placeholder like every other numeric value in this table.
        sprintSpeedThreshold    = 4.0,  -- meters/second, averaged over one tick interval

        -- NATIVE SPRINT STAMINA ASSIST (owner directive: "make sure high
        -- command can edit the ability to make stamina last longer or even
        -- permanently"). This is DELIBERATELY SEPARATE from the
        -- sprintDecayPerTick/speedPenaltyThreshold/speedPenaltyMultiplier
        -- fields above, which govern ONLY this resource's own custom
        -- Fatigue stat/speed-penalty. There is a SECOND, independent thing
        -- that limits how long a K9 can keep running: GTA/FiveM's own
        -- built-in player sprint-stamina mechanic (the same value
        -- client/hud.lua's "Stamina" HUD row displays via
        -- GetPlayerSprintStaminaRemaining) -- a real engine limit on the
        -- underlying Player, independent of ped model, that this resource
        -- previously never touched at all (confirmed: client/hud.lua only
        -- ever READ that native, nowhere in this resource was it ever
        -- restored/extended). Left at 0 (below), nothing about this changes
        -- -- vanilla stamina behaves exactly as it always has.
        -- Above 0, client/wellbeing.lua periodically calls the official
        -- RESTORE_PLAYER_STAMINA native (`RestorePlayerStamina(PlayerId(),
        -- percentage)` -- confirmed against FiveM's own natives.json,
        -- "Adds a percentage to a players stamina", officially documented
        -- with an example that calls it on a repeating timer for exactly
        -- this "keep it topped up" purpose) at this fraction, while the
        -- local player is an accessible K9. [0.0, 1.0] is this native's OWN
        -- documented valid range (1.0 = 100%) -- not an arbitrary ceiling
        -- picked for this task, the native's own contract. At 1.0, stamina
        -- is restored to full on every check interval, fast enough that it
        -- never has a real chance to visibly deplete -- effectively
        -- unlimited sprint for as long as this stays 1.0.
        nativeStaminaRestorePercent = 0.0,
    },



    -- ==================================================================
    -- PERSISTENCE (this pass, coder-backend) -- see server/wellbeing.lua's
    -- own header "DATABASE PERSISTENCE" section for the full design. Fixes
    -- a real, confirmed gap: the stat above used to live ONLY in that
    -- file's own in-memory table, with no database write of any kind ever
    -- existing for it -- a routine restart silently reset every K9's
    -- fatigue to fresh, every time, no matter what happened in-game
    -- before it. Routed
    -- through the SAME K9Store/Config.Database.enabled machinery every
    -- other persisted table in this resource already uses -- `enabled =
    -- false` here (or resource-wide) degrades to exactly the OLD
    -- behaviour (memory for this session only), never an error.
    -- ==================================================================
    Persistence = {
        -- Master switch for THIS feature specifically -- only a literal
        -- `false` turns it off; leave this alone (`true`, the default) on
        -- an ordinary server. Independent of Config.Database.enabled
        -- above: turning THAT off already makes every write here a no-op
        -- (session-memory only, same as every other K9Store-backed table
        -- in this resource) -- this flag exists for the rarer case where
        -- an operator wants the database on for every OTHER feature but
        -- specifically does not want K9 wellbeing saved (e.g. a server
        -- that intentionally treats every dog's condition as a fresh
        -- daily reset).
        enabled = true,

        -- How often unsaved wellbeing changes are written to the
        -- database, in milliseconds. Deliberately NOT every tick
        -- (tickIntervalMs above, 5000ms by default) -- that would mean a
        -- real database write per online K9 every 5 seconds, a rate this
        -- resource has never asked a database to sustain for anything
        -- else. 60000 (one minute) means a crash loses at most one
        -- minute's worth of drift for a K9 that never disconnected
        -- cleanly -- an ordinary clean disconnect (a relog, a server
        -- restart initiated normally) saves immediately regardless, via a
        -- separate write-on-disconnect this value does not affect.
        flushIntervalMs = 60000,

        -- How long a citizenid must have been OFFLINE before its
        -- in-memory wellbeing entry is dropped, in milliseconds. Only
        -- ever applies to an entry with NOTHING unsaved (this file's own
        -- server/wellbeing.lua never drops a change that has not been
        -- confirmed written) -- raising this only delays reclaiming
        -- memory for a player who is genuinely gone; it can never cause a
        -- returning player to lose progress, since a reconnect always
        -- reloads from the database regardless of whether this window has
        -- elapsed. 900000 (15 minutes) comfortably outlasts an ordinary
        -- reconnect (a crash, a relog, a brief disconnect) without ever
        -- holding memory for a player who is truly done for the day.
        evictAfterMs = 900000,

        -- How often the eviction check above actually runs, in
        -- milliseconds. A larger number here means slightly slower memory
        -- reclamation, never a correctness difference (a citizenid is
        -- only ever evicted once it has ALREADY been offline for at least
        -- evictAfterMs, however late this check happens to run). 300000
        -- (5 minutes) keeps this cheap without leaving evictable memory
        -- sitting around for hours.
        evictSweepIntervalMs = 300000,
    },
}

-- ======================================================================
-- PROP ATTACHMENTS (Config.Features.PropAttachments) --
-- client/propattachment.lua, server/propattachment.lua. A visible prop
-- (vest/harness) attached to the K9 ped.
--
-- ABOUT boneIndex, because this is the part everyone gets wrong:
-- AttachEntityToEntity takes a bone INDEX, not a bone NAME, and the docs note
-- the index is "different to boneID". Three earlier research passes stalled
-- searching for a quadruped bone NAME, which does not exist to be found.
-- GetWorldPositionOfEntityBone is declared over a generic Entity (ENTITY
-- namespace, not PED), so it works against a dog ped -- but a dog skeleton's
-- layout differs from a human's, so the specific index has to be found by
-- looking. That is what Config.Features.BoneSweepDevTool exists for.
-- Default 0 is the root bone: always valid, never crashes, looks wrong.
-- ======================================================================
Config.PropAttachments = {
    -- UNVERIFIED. No confirmed lead for a K9 vest/harness prop was found, so
    -- this is a placeholder that will very likely not load. That is survivable
    -- by design: the fallback below is the one this actually degrades to.
    propModel         = 'prop_bodyarmour_02',
    -- The SAME model Config.DeployableKennel already falls back to, chosen for
    -- exactly that reason -- it is the one prop in this resource with a
    -- confirmed-safe track record rather than a second unverified guess. It
    -- will look wrong (a K9 wearing a tennis ball), which is the point: an
    -- obviously-wrong visible prop tells an operator to go find a real vest
    -- model, where a silent no-op would just look like the feature is broken.
    fallbackPropModel = 'prop_tennis_ball',
    boneIndex         = 0,                    -- root; replace after a dev-server sweep
    offsetX = 0.0, offsetY = 0.0, offsetZ = 0.0,
    rotX    = 0.0, rotY    = 0.0, rotZ    = 0.0,
    toggleCooldownMs         = 2000,
    pendingConfirmTtlMs      = 15000,
    confirmDistanceTolerance = 5.0,
}

-- ======================================================================
-- BONE SWEEP DEV TOOL (Config.Features.BoneSweepDevTool) -- see that flag's
-- own comment. Dev servers only.
-- ======================================================================
Config.BoneSweepTool = {
    -- Authorization is deliberately a SEPARATE, stricter principal from the
    -- audit commands' own `auditGrade`: granting someone read-only audit
    -- access must not also hand them a tool that spawns and attaches props.
    -- server/bonetool.lua therefore grants on `job.isboss` ONLY -- no numeric
    -- grade branch -- so there is no key to set here. The former
    -- `AcePermission = 'k9unit.bonesweep'` was removed on 2026-08-25 when
    -- that file dropped IsPlayerAceAllowed.
    TestPropModel     = 'prop_tennis_ball',
    MaxBoneIndex      = 200,
    TestOffsetX = 0.0, TestOffsetY = 0.0, TestOffsetZ = 0.0,
    CommandCooldownMs = 500,
}

-- ======================================================================
-- FETCH (Config.Features.FetchMechanic) -- client/fetch.lua, server/fetch.lua.
--
-- Note what this feature is NOT: the K9 does not walk the ball back on its
-- own. It cannot -- the K9 is a connected player's own character, and nothing
-- in this resource's architecture scripts a player's ped movement. The return
-- leg is a real player action ("Deliver to Handler", server-validated for
-- identity and live proximity) instead of a scripted walk.
-- ======================================================================
Config.FetchMechanic = {
    ballPropModel                = 'prop_tennis_ball',
    throwForwardOffsetMeters     = 1.0,
    throwUpOffsetMeters          = 1.2,
    throwForceForward            = 12.0,
    throwForceUp                 = 6.0,
    throwCooldownMs              = 5000,
    pendingThrowTtlMs            = 15000,
    maxBallLifetimeMs            = 300000, -- absolute ceiling; no ball outlives this
    -- ENFORCED SERVER-SIDE, not just as an ox_target radius. A red-team pass
    -- found this value was previously only the client's ox_target `distance`
    -- field -- pure UI -- so requestPickupFetchBall accepted a pickup from
    -- anywhere on the map. Any player with K9 access could take another
    -- player's ball remotely and then re-drop it at their own position.
    -- server/fetch.lua now re-measures live distance against this, the way
    -- requestDeliverFetchBall always did.
    pickupInteractDistanceMeters = 2.0,

    -- Pickup had NO rate limit before; only the initial throw did, which is
    -- what made the remote-steal loop freely repeatable. server/fetch.lua
    -- falls back to 500 if this is absent, so removing it degrades safely
    -- rather than removing the throttle.
    -- There is deliberately no releaseCooldownMs counterpart: voluntary
    -- release is an escape hatch, and NewCooldown treats a non-positive
    -- threshold as permanently-on rather than off, so a `0` here meant to
    -- disable the throttle would instead disable releasing. See
    -- server/fetch.lua's releaseFetchBall doc comment.
    pickupCooldownMs             = 500,
    deliverProximityMeters       = 3.0,
    maintenanceIntervalMs        = 2000,

    -- 'fake' (delete + animate) or 'attach' (real mouth-carried prop).
    -- Ships 'fake' deliberately: 'attach' is only honest once a dev-server
    -- sweep has found a real mouth/jaw index AND confirmed it does not clip
    -- during the bark/pant carry pose. The feature is fully playable in
    -- 'fake' mode without that step.
    mouthCarryMode = 'fake',
    mouthBoneIndex = 0, -- root; replace from a sweep, then set mouthCarryMode
    mouthOffsetX = 0.0, mouthOffsetY = 0.4, mouthOffsetZ = 0.15,
}

-- ======================================================================
-- PROXIMITY AUDIO (Config.Features.ProximityAudioFX) -- client/proximityaudio.lua.
-- Distance-scaled K9 audio over the NUI bridge's Web Audio gain node.
-- UPDATED 2026-08-25: this used to say no audio ships with this resource.
-- That is no longer true. html/sounds/growl_ambient.ogg -- the sound THIS
-- feature plays -- ships, is listed in fxmanifest.lua's files{} block, and
-- is credited with its licence in html/sounds/CREDITS.md. A sound key with
-- no file still degrades to silence rather than erroring, which looks
-- exactly like the feature being off, so keep that list complete.
-- ======================================================================
Config.ProximityAudioFX = {
    scanIntervalMs  = 2500,  -- discovery cadence; never a per-frame loop
    triggerDistance = 25.0,  -- meters; must stay <= client/audio.lua's own 30.0 ceiling
    soundName       = 'Growl_Ambient', -- resolves to html/sounds/growl_ambient.ogg
}


-- ======================================================================
-- RESOURCE AUTO-DETECTION / COMPATIBILITY (Config.Features.ResourceAutoDetect)
-- shared/compat/*.lua
--
-- PLAIN ENGLISH, READ THIS FIRST:
-- Every server runs a different mix of scripts. One runs ox_inventory,
-- another runs qb-inventory, another wrote their own from scratch. The same
-- goes for dispatch, for the ambulance/downed script, and for the "press E"
-- targeting script. This block is how this resource stops guessing and
-- starts ASKING your server what it actually runs.
--
-- HOW IT WORKS, IN THREE STEPS:
--   1. When the server starts, this resource walks the `candidates` list for
--      each system below IN ORDER and picks the FIRST one that is actually
--      started on your server. First match wins, so put your preferred one
--      earlier in the list.
--   2. It then checks that the one it picked really has the functions this
--      resource needs. A resource that is running but is an old/renamed
--      version fails this check and is SKIPPED, and detection moves on to
--      the next candidate rather than silently half-working.
--   3. Whatever it settled on is printed to your server console once, at
--      startup, and can be reprinted at any time in game with /k9compat.
--
-- THE THREE THINGS YOU CAN SET, per system:
--   * `override`   -- a resource name, as a string. Skips detection entirely
--                     and uses THIS one. Use it when you run two of
--                     something and want to be certain which one is used.
--                     Setting the INVENTORY system's override (or letting
--                     auto-detect pick it) to 'qb-inventory' specifically
--                     has two real gaps that print no warning -- read the
--                     INVENTORY section below before you choose it.
--   * `candidates` -- the search order. ADD YOUR OWN NAME TO THIS LIST if
--                     you run something not listed. It is a plain list of
--                     strings; there is nothing magic about the ones that
--                     ship here.
--   * `custom`     -- YOUR OWN CODE. A table of functions, written by you,
--                     that beats everything above -- override included. This
--                     is the escape hatch for a fully custom, in-house
--                     script that nothing else could possibly know about.
--                     See DEVELOPER_REFERENCE.md §21 for the exact function
--                     list each system expects, with a copy-paste template.
--
-- WHAT HAPPENS IF NOTHING IS FOUND: the feature that needed that system
-- degrades to a clean no-op -- one clear console line naming the system and
-- what it disabled, then silence. It never errors in a loop, never blocks
-- resource start, and never takes the rest of the resource down with it.
-- Nothing here is a hard dependency EXCEPT what fxmanifest.lua's own
-- `dependencies` block already lists.
--
-- SECURITY NOTE, do not undo this: detection NEVER grants permission.
-- Every rank, certification and ownership check in this resource runs on
-- the server and is completely independent of which external script was
-- detected. A hostile or broken third-party inventory can make a feature
-- stop working; it cannot make a player a K9, mint XP, or bypass a rank.
-- ======================================================================
Config.Compat = {
    -- Master switch for the whole detection pass. `false` means "use only
    -- what I set by hand in `override`/`custom` below, detect nothing."
    autoDetect = true,

    -- Print one summary block to the server console at startup listing what
    -- was found for each system. Recommended: leave this on. It is the
    -- single fastest way to answer "why is X not working on my server".
    logDetectionOnStart = true,

    -- In-game command that reprints that same summary on demand, to whoever
    -- runs it, plus WHY each candidate was skipped. Gated to the same high
    -- command rank as the rest of the admin surface (Config.Departments
    -- `highCommandGrade`) -- it names the scripts your server runs, which is
    -- not something to hand to every player. Set to `false` to not register
    -- the command at all.
    diagnosticCommand = 'k9compat',

    -- Re-run detection when a resource starts or stops while the server is
    -- already up, so `restart ox_inventory` (or swapping inventories on a
    -- live server) is picked up without a full server restart.
    redetectOnResourceRestart = true,

    -- How long to wait, at startup, for a candidate that is still starting
    -- before giving up on it. Resource start order is not guaranteed, so a
    -- flat zero here would make detection a coin flip on a busy server.
    startupGraceMs = 10000,

    Systems = {
        -- ==============================================================
        -- INVENTORY -- items, stashes, the contraband search, the K9 supply
        -- shop, and the tablet item. The most-used system in this list.
        --
        -- IF YOU PICK (OR AUTO-DETECT) qb-inventory, READ THIS FIRST. Two
        -- specific things behave differently on qb-inventory than on
        -- ox_inventory (the one this resource is built and tested against),
        -- and neither one prints a warning or an error when it happens:
        --   * The K9 supply shop does not open for players. A handler who
        --     clicks "Buy K9 Gear" gets nothing at all -- no menu, no
        --     message, nothing in the server console. qb-inventory has no
        --     way for this resource to open a shop screen from the
        --     PLAYER's side, only from the server's side, so this one
        --     action is a permanent dead end on qb-inventory -- not
        --     something a restart or a different setting fixes.
        --   * A search cannot see contraband hidden inside a bag or
        --     backpack item. It still correctly finds anything sitting
        --     loose in someone's own inventory ("pockets"); only the
        --     INSIDE of a separate bag item is invisible to it on this
        --     backend. A "clean" result can mean "actually clean" or
        --     "hidden in a bag" on qb-inventory -- there is no way to tell
        --     which.
        -- Everything else -- including the K9 medkit and finding
        -- contraband sitting loose (not in a bag) -- works normally on
        -- qb-inventory. If you need the supply shop to work for players,
        -- or need bag-searching to be reliable, use ox_inventory instead.
        -- ==============================================================
        inventory = {
            override = nil,
            candidates = {
                'ox_inventory',      -- the one this resource was built against
                'qs-inventory',
                'qb-inventory',
                'ps-inventory',
                'origen_inventory',
                'codem-inventory',
                'core_inventory',
                'tgiann-inventory',
            },
            custom = nil,
        },

        -- ==============================================================
        -- TARGET -- the "look at a thing and press E" menus. Every walk-up
        -- interaction this resource adds goes through here.
        -- ==============================================================
        target = {
            override = nil,
            candidates = {
                'ox_target',
                'qb-target',
                'qtarget',
                'interact',
                'sleepless_interact',
            },
            custom = nil,
        },

        -- ==============================================================
        -- FRAMEWORK -- who a player is: their citizen id, their job, their
        -- rank. This is the one system this resource genuinely cannot run
        -- without, because every permission check in it reads a job rank.
        --
        -- READ THIS BEFORE YOU TRUST THE LIST BELOW. Auto-detection is real
        -- and works for your inventory and your targeting script -- swap
        -- either of those and this resource adapts. **Framework is the
        -- exception, and right now it does not work that way.** The
        -- qb-core and es_extended entries below are researched and correct
        -- as far as they go, but only one file in this entire resource
        -- actually routes through them. Everything else -- certifications,
        -- permissions, the tablet, XP, combat -- calls Qbox directly, at an
        -- ESTIMATED number of places that this comment does not keep
        -- current (a single `grep -rn 'exports\.qbx_core'` already turns up
        -- 200+ and counting as the resource grows -- do not cite a fixed
        -- number here again; recount at the time you need it). Qbox is also
        -- a hard requirement in fxmanifest.lua, so FiveM will not start
        -- this resource without it.
        --
        -- What that means in practice: if you run qb-core or ESX, detection
        -- will correctly identify it, and the resource still will not work.
        -- Do not read this list as a compatibility promise.
        --
        -- This is written down rather than quietly fixed because making it
        -- true is a large job (converting every one of those direct-call
        -- sites, whatever the current count is), not a small one, and it is
        -- your call whether it is worth doing. It is recorded in KNOWN_ISSUES.md
        -- as a decision waiting on you.
        -- ==============================================================
        framework = {
            override = nil,
            candidates = {
                'qbx_core',
                'qb-core',
                'es_extended',
            },
            custom = nil,
        },

        -- ==============================================================
        -- DISPATCH -- OUTBOUND ONLY. This resource ANNOUNCES things (for
        -- example, "a K9 went down"); it never asks dispatch a question.
        -- Even with nothing detected here, every announcement still fires
        -- as a plain `qbx_k9unit:events:*` event that your own dispatch can
        -- listen for with one line of code -- so a fully custom dispatch
        -- needs NOTHING in this block.
        --
        -- READ THIS BEFORE YOU ASSUME EVERYTHING SHOWS UP ON YOUR DISPATCH
        -- BOARD. Detection here only lights up a real, no-setup-needed
        -- board alert for ONE thing today: a K9 going down. A
        -- search-and-rescue call being completed, and a contraband search
        -- finishing, both still fire their own plain event (so something
        -- IS available to listen for), but neither one automatically posts
        -- to a detected dispatch board the way a K9 going down does. This
        -- is a deliberate, narrower scope, not a bug that got missed. If
        -- you want search-and-rescue calls or search results to show up on
        -- your dispatch board too, someone needs to write a small bridge
        -- that listens for that event and posts it to your dispatch
        -- script -- this resource does not do that step for you today.
        -- ==============================================================
        dispatch = {
            override = nil,
            candidates = {
                'ps-dispatch',
                'cd_dispatch',
                'qs-dispatch',
                'rcore_dispatch',
                'core_dispatch',
                'linden_outlawalert',
            },
            custom = nil,
        },

        -- ==============================================================
        -- AMBULANCE / DOWNED -- INBOUND. Answers one question: "is this
        -- player dead or downed right now?" Used so a K9 cannot bite or
        -- drag someone who is already on the floor.
        --
        -- NOTE: `Config.Combat.PropDragging.IsPlayerDownedOverride` still
        -- exists and still WINS over anything detected here. That hook was
        -- the original answer to this problem and is not being retired --
        -- if you already wrote one, it keeps working exactly as before.
        -- ==============================================================
        ambulance = {
            override = nil,
            candidates = {
                -- FIRST on purpose (added 2026-09-02): this is the ambulance
                -- script this server actually runs, and it is CONFIRMED --
                -- the adapter was written against the resource's own source,
                -- not a secondhand citation. It is also the reason the
                -- ambulance signal used to resolve to "unknown" here:
                -- sc-ambulance is a qbx_medical compatibility layer and
                -- writes the same metadata, but the qbx_medical adapter is
                -- gated on qbx_medical itself being started, which it is
                -- not on this server. Order matters only in that the first
                -- STARTED candidate with a working adapter wins, so putting
                -- the confirmed, actually-installed one first costs nothing
                -- and skips four probes that cannot match.
                'sc-ambulance',
                'qbx_medical',
                'qb-ambulancejob',
                'ps-ambulancejob',
                'wasabi_ambulance',
                'esx_ambulancejob',
            },
            custom = nil,
        },
    },
}


-- ======================================================================
-- K9 LEADERBOARD (Config.Features.K9Leaderboard) -- server/leaderboard.lua.
-- The /k9stats command. Both values below have built-in fallbacks, so a
-- missing or nonsensical entry prints one clear console line and keeps
-- working rather than breaking the command.
-- ======================================================================
Config.Leaderboard = {
    -- How many places to show. server/leaderboard.lua enforces its own hard
    -- ceiling on top of this, so raising it past that ceiling is capped
    -- rather than obeyed -- the query reads exactly this many rows off an
    -- index, so it stays cheap no matter how big the table gets.
    MaxRows = 20,

    -- Minimum gap between one player's own /k9stats runs, in milliseconds.
    -- MUST BE POSITIVE. Zero or negative does NOT mean "no cooldown" in
    -- this codebase -- the shared cooldown helper treats a non-positive
    -- threshold as PERMANENTLY ON, which would lock the command out for
    -- everyone, forever, with nothing logged to explain why.
    CommandCooldownMs = 5000,
}



-- ======================================================================
-- K9 SUPPLY SHOP (Config.Features.K9EquipmentShop) -- server/equipmentshop.lua
-- and client/equipmentshop.lua.
--
-- THE ITEMS BELOW MUST ALREADY EXIST IN YOUR INVENTORY SCRIPT. This
-- resource cannot create items -- only your inventory's own items list
-- can. Any name here that your inventory does not know is skipped with a
-- clear console warning naming it, and if every item is unknown the shop
-- is not registered at all rather than appearing empty.
--
-- YOU ALMOST CERTAINLY NEED TO EDIT `locations`. The coordinate that ships
-- is a placeholder near Mission Row PD, not a surveyed spot on your map.
-- Stand where you want the counter, note your coordinates, replace it. An
-- empty `locations` list means the shop is registered but has nowhere to
-- be opened from, which reads as the feature being broken.
--
-- WHO CAN SHOP: everyone in a department listed in Config.Departments, at
-- any grade. That is derived automatically -- there is no separate job
-- list to keep in sync here.
-- ======================================================================
Config.K9EquipmentShop = {
    -- The internal key your inventory files this shop under. Change it
    -- only if it collides with a shop you already run.
    shopType = 'k9supply',

    -- What officers see as the shop's name. Also the default prompt label
    -- for every location below that does not set its own.
    label = 'K9 Supply',

    -- Which ITEM is spent as money. This is an item name your inventory
    -- already tracks -- conventionally 'money' -- NOT a banking resource.
    -- Nothing here ever calls a bank.
    currencyItem = 'money',

    -- ==================================================================
    -- THE SHOP ATTENDANT. The walk-up point is a real, visible ped you
    -- approach, not an invisible patch of ground. The four fields below are
    -- the defaults for every location; any single location can override
    -- them. ANY streamed model works, including one that never appears in
    -- Config.Peds.
    --
    -- WHY THIS IS A PERSON AND NOT A DOG (changed 2026-08-31, and please
    -- keep it that way). This shipped as `a_c_shepherd` with a sitting-dog
    -- scenario -- an NPC German Shepherd sat at the K9 supply point. The
    -- old comment here argued it was "a shop attendant, not a K9", but that
    -- distinction only exists in the config file. To anyone playing, it is
    -- a dog that is not a person, standing in the one place K9 handlers
    -- gather -- which is exactly what this server's K9s are never allowed
    -- to be. Every K9 here is a real player; nothing about a dog should
    -- read as scenery. A human quartermaster issuing gear carries no such
    -- confusion, and the shop behaves identically either way.
    --
    -- If you do set a dog model here, set pedScenario to a dog animation
    -- too (the two must match) -- but the intent above is the reason not to.
    -- ==================================================================

    -- Default model for the shop attendant. A uniformed officer handing out
    -- K9 gear reads correctly at a police/sheriff supply point.
    pedModel = 's_m_y_cop_01',

    -- Default direction it faces, in degrees.
    pedHeading = 0.0,

    -- What it does while standing there. Set to false and it just stands.
    -- A clipboard suits someone issuing equipment; it must match pedModel's
    -- species (a human scenario on a dog model, or the reverse, plays wrong).
    pedScenario = 'WORLD_HUMAN_CLIPBOARD',

    -- How long to wait for a shop ped's model to load before giving up, in
    -- milliseconds. On timeout that ONE location is skipped with a console
    -- warning -- the shop does not hang and the other locations still work.
    pedModelLoadTimeoutMs = 10000,

    -- Where the shop attendants stand. PLACEHOLDER -- see the note above. Add,
    -- remove or reorder entries freely; no code change is needed, and high
    -- command can also do it live from the tablet. Any entry may set its
    -- own `model`, `heading`, `scenario` or `label` to override the
    -- defaults above for that one spot only.
    locations = {
        { x = 452.1, y = -980.1, z = 30.7 },
        -- { x = ..., y = ..., z = ..., model = 'a_c_husky', heading = 180.0, label = 'K9 Supply (Vespucci)' },
    },

    -- Prices are in whatever `currencyItem` is. Tune freely; these are
    -- starting numbers, not balance guidance.
    items = {
        { name = 'k9_medkit',             price = 250 },
        { name = 'k9_treat',              price = 25 },
        { name = 'k9_meat_bait',          price = 40 },
        { name = 'k9_ultrasonic_whistle', price = 150 },
    },
}


-- ======================================================================
-- DATABASE (Config.Database) -- whether this resource is allowed to talk
-- to a database at all.
--
-- READ THIS EVEN IF YOU DO NOT CODE. With `enabled = false` you do NOT
-- need to run ANY of the .sql files in the sql/ folder -- not
-- install.sql, not a single migration. Every feature still works
-- tonight, for everyone on the server right now. The trade is memory,
-- not features: certifications, XP, partnerships, permission grants,
-- tablet theming and K9 appearance are held in the server's memory only,
-- for as long as it keeps running. The moment it restarts -- a crash, an
-- update, a scheduled reboot -- all of it is gone and everyone starts
-- over. Dogs forget who trained them, handlers lose their rank and XP,
-- partners are un-paired, the tablet theme resets. Nothing is corrupted
-- and nothing crashes. It simply never remembers past today.
--
-- ONE THING THIS DOES NOT TURN OFF: `oxmysql` must still be installed and
-- started as its own resource. This resource declares it as a hard
-- dependency, and FXServer refuses to START qbx_k9unit without it --
-- that check happens before this file is ever read, so no setting here
-- can route around it. `enabled = false` means this resource never sends
-- oxmysql a single query and needs none of its own tables to exist. If
-- you run no database at all, you still need the oxmysql resource
-- present, pointed at any reachable database.
--
-- THIS SHIPS OFF, SO THE RESOURCE IS DRAG-AND-DROP (owner-directed).
-- Drop the folder in, start it, and everything works with no database
-- import at all. That is a deliberate choice about the FIRST RUN, not a
-- recommendation for the long run.
--
-- TURN IT ON ONCE YOU ARE KEEPING THE SERVER. Set `enabled = true` below
-- and run sql/install.sql (one file, one time -- see sql/DATABASE_GUIDE.md).
-- Nothing else in this config changes, and nothing you do in the meantime
-- is wasted except the session's own memory. If you run with it off for a
-- week and then switch it on, you start persisting from that moment; the
-- week's certifications and XP are simply not there, because they were
-- never written anywhere.
--
-- WHAT "OFF" ACTUALLY COSTS YOU, in one line each, so this is a decision
-- and not a surprise: every certification, rank and XP total, partnership,
-- permission grant, callsign, tablet theme and pinned dog appearance is
-- gone on the next restart -- crash, update or scheduled reboot alike --
-- and the audit trail, which DOES still work during the session, is capped
-- (500 search entries, 200 of everything else) and goes with it. See the
-- audit paragraph further down for exactly what that means in a dispute.
--
-- THE AUDIT TRAIL STILL EXISTS, BUT ONLY FOR TODAY. This paragraph used
-- to say the opposite -- "no record of who certified whom, no search log,
-- no permission-grant history... not a smaller record. None." That was
-- wrong, and checked against the running code rather than re-read: with
-- the database off, server/datastore.lua's memory backend genuinely
-- records certification history, the search log and the permission-grant
-- and override audits, and the tablet's Audit screens genuinely read them
-- back. A dispute about something that happened this session CAN be
-- checked.
--
-- What is actually true, which is a smaller claim and a different one:
--   * It is CAPPED, not complete. The search log keeps the most recent
--     500 entries and every other audit table the most recent 200; older
--     entries fall off the end as new ones arrive. On a busy night the
--     search log can turn over in hours.
--   * It dies with the process, like everything else here. After a
--     restart there is nothing to check about yesterday, ever.
-- So: fine for "what happened an hour ago", useless for "what happened
-- last week". Most police servers want the second, and that alone is
-- usually worth running the database for.
--
-- A SAFETY RULE THE CODE FOLLOWS SO YOU DO NOT HAVE TO THINK ABOUT IT:
-- with this off, nobody ever ends up with MORE access than they would
-- have on a database-backed server. A memory-only grant can only be
-- easier to LOSE than a saved one, never easier to get.
-- ======================================================================
Config.Database = {
    -- SHIPS false (owner-directed, so the resource is drag-and-drop): none
    -- of this resource's state is ever read from or written to a database,
    -- no .sql file needs importing, and everything lives in memory for this
    -- server session only.
    --
    -- Set this to `true` -- and run sql/install.sql once -- to save
    -- certifications, XP, partnerships, permissions, runtime overrides,
    -- tablet theming and K9 appearance so they survive a restart. That is
    -- the right setting for a server you intend to keep; this default is
    -- about making the first run work with no setup, not about which mode
    -- is better. See the block above for exactly what "off" costs.
    --
    -- Changing this is the ONLY edit required either way. Every feature
    -- behaves identically in both modes (server/datastore.lua's K9Store is
    -- the single seam, with one branch per function); the difference is
    -- solely whether anything is remembered past a restart.
    enabled = false,
}

-- ======================================================================
-- PURSUIT SPRINT (Config.Features.PursuitSprint) -- PROJECT_HISTORY.md §5.
-- client/pursuitsprint.lua + server/pursuitsprint.lua.
--
-- A short burst where the dog is genuinely faster than the person running
-- from it. This is the most PvP-affecting thing in this resource, so it is
-- deliberately narrow: a wanted target only, a few seconds only, and a
-- cooldown between bursts. It is meant to END a foot chase that was
-- already going the K9's way, not to make escape impossible.
--
-- ON THE SPEED NUMBER: the game clamps the COMBINED effect of every speed
-- influence -- breed, XP tier, tiredness, and this burst -- to at most
-- twice normal. So even a wildly mis-set number here cannot produce
-- something faster than that ceiling. Raise it if you like; you will hit
-- the ceiling before you break anything. At the numbers below a K9 is
-- sprinting roughly 11% of the time -- a burst that finishes a chase
-- already going their way, not a standing speed advantage.
-- ======================================================================
-- IF YOU CAME HERE FOR "YOUR K9s ARE TOO STRONG", THIS MAY BE THE WRONG
-- BLOCK. This one covers ONLY a dog's short burst of extra running speed
-- while chasing a wanted suspect. If what actually feels too strong is
-- somebody being bitten, taken down or dragged and unable to escape, that
-- is Config.Combat, a long way further up this file -- search for
-- `Config.Combat`. Bite & Hold, Non-Lethal Takedown and Prop Dragging all
-- live there.
Config.PursuitSprint = {
    -- How much faster than normal, during the burst. 1.0 is no change.
    speedMultiplier = 1.4,

    -- How long a burst lasts, in milliseconds.
    durationMs = 5000,

    -- Minimum gap between one burst and the next, per player, in
    -- milliseconds. MUST BE POSITIVE -- a non-positive value does NOT mean
    -- "no cooldown" here; the shared cooldown helper treats it as
    -- PERMANENTLY ON and the ability locks out for everyone, forever.
    cooldownMs = 45000,

    -- How close the K9 must be to the target to start a burst, in meters.
    requestRangeMeters = 20.0,
}




-- ======================================================================
-- DEBUG DUMP (server/diagnostics.lua, client/diagnostics.lua) -- owner's own
-- words: "I want a debug mode setup... so that way when I am testing I can
-- give you the information for fixes etc", later extended twice in the
-- same conversation: "I also want that debug super comprehensive so it
-- helps you a lot when finding bugs etc" and "This debug mode for if you
-- as Claude turn it on will help you drastically in finding and fixing all
-- issues."
--
-- WHAT `/k9debug` DOES: a caller-owned diagnostic. It never inspects
-- anyone but the player who ran it, re-runs this resource's OWN
-- already-tested boot-time checks (the Config.Features/Config.FeatureGroups
-- disagreement detector immediately above ResolveFeatureGroups() in this
-- file, server/diagnostics.lua's dependency-version check) on demand instead
-- of only once at boot to a console nobody is watching, and writes ONE
-- timestamped file per run under this resource's own `diagnostics/` folder
-- -- never the chat box, never the F8 console -- so it can be attached
-- whole rather than scrolled and retyped. See server/diagnostics.lua's own
-- header for the full three-tier report shape (findings, worth-checking,
-- full state) and DIAGNOSTIC_CHECKS.md for exactly which checks this
-- performs and why each one is scoped the way it is.
--
-- NOT A Config.Features ENTRY, ON PURPOSE -- same "extra, independent
-- kill-switch" posture as Config.LeashVisual.enabled/Config.K9Onboarding.
-- enabled elsewhere in this file: this is a standalone diagnostic tool with
-- no runtime-control-tablet exposure, no feature-group family, and no
-- per-person block/grant of its own (see server/diagnostics.lua's own header
-- for why "own state only" makes a permission gate unnecessary rather than
-- adding one). Putting it in Config.Features would require the full
-- governance wiring (Config.FeatureGroups membership, FEATURE_TIERS in
-- server/runtimecontrol.lua, tests/runtimefeaturetiers_spec.lua's drift
-- guard) for a tool that is deliberately NOT part of the runtime-feature
-- system it exists to help debug.
Config.DebugDump = {
    -- SHIPS OFF. This whole subsystem -- the `/k9debug` command, its
    -- server callback, and (at the verbose level below) the decision-log
    -- wrapping around HasK9Access/IsHighCommand/HasPermission -- does
    -- NOTHING AT ALL while this is anything other than exactly `true`.
    -- Turn it on only while you are actively testing and plan to hand the
    -- resulting files to a developer; there is no reason to leave it on
    -- for a live server nobody is actively diagnosing.
    enabled = false,

    -- 'normal' or 'verbose'. Any other value falls back to 'normal' with a
    -- console warning naming the bad value (clamp-and-warn, never a bare
    -- assert -- see server/diagnostics.lua's own header).
    --
    -- 'normal' costs nothing beyond the command itself running: no
    -- wrapping of any other file's functions, no ongoing bookkeeping
    -- between runs. Safe to leave on for an entire testing session.
    --
    -- 'verbose' additionally keeps a rolling, in-memory trail of DECISIONS
    -- this resource makes -- every HasK9Access/IsHighCommand/HasPermission
    -- call, its result, and (best-effort) why -- included in full in every
    -- dump file written while verbose is active. This is genuinely more
    -- expensive (one extra function-call layer and a small table write on
    -- every one of those checks, which this resource calls very
    -- frequently) -- turn it on only for the specific session where you
    -- are chasing a "why did this refuse me" bug, and back to 'normal'
    -- afterwards.
    level = 'normal',

    -- Every `/k9debug` run writes ONE new file under this resource's own
    -- `diagnostics/` folder. This is a testing tool an owner may run many
    -- times in one session, so this caps how many of those files this
    -- resource keeps meaningful content in before it starts clearing out
    -- the oldest ones to make room -- see server/diagnostics.lua's own
    -- header "WHY EMPTYING, NOT DELETING" for exactly what "clearing out"
    -- means (there is no native this resource could verify for deleting a
    -- resource file outright). A non-positive or non-number value falls
    -- back to 200 with a console warning.
    maxRetainedDumps = 200,

    -- If true, this resource ALSO writes one dump automatically, right
    -- after it finishes its own boot-time checks -- but ONLY when at least
    -- one of those checks actually found something wrong (a feature
    -- switch disagreement, a database table that isn't there). A clean
    -- boot writes nothing extra. This exists because an owner will not
    -- think to run `/k9debug` before he has noticed a problem, and the
    -- state at the exact moment of boot is often the most useful moment to
    -- have captured. Has no effect at all unless `enabled` above is also
    -- `true`.
    autoOnBoot = true,
}
