--[[
    qbx_k9unit/server/partnership.lua

    DEVELOPER_REFERENCE.md §12.0 item 7 / §12.3's file-plan entry.
    Owns the "K9 partnership" registry -- a persistent, DB-backed,
    mutually-consented "who is my ongoing handler/K9 partner" relationship,
    independent of momentary leash state (server/main.lua's `LeashPairs`).
    This file was originally a FOUNDATION ONLY: it established, persisted
    and tore down a partnership and exposed read accessors, wiring no combat
    consequence of its own. The two features it was built to unblock -- the
    recall actor and the handler-down defense -- were both built, then
    REMOVED on 2026-09-02 at the owner's request.

    The registry outlived them, and is load-bearing today: server/tenure.lua
    reads it for the partnership tenure bonus, and the tablet reads it to
    show who is partnered with whom. See each accessor's own doc comment for
    the current wiring.

    ======================================================================
    WHY OPTION B (THIS FILE), NOT LeashPairs -- one-paragraph restatement,
    full reasoning in DEVELOPER_REFERENCE.md §12.0 item 7: `LeashPairs` is
    explicitly ephemeral, session-scoped state for a movement-restriction
    mechanic (server/main.lua's own header: "a live session mechanic, not
    part of the certification/permission system"). The motivating scenario
    was an off-leash foot chase -- the pair is DELIBERATELY unleashed at
    exactly the moment a defense trigger would matter most -- so reusing
    `LeashPairs` would have left that feature non-functional for its own
    primary use case. This registry exists
    specifically to answer "who is this K9's handler right now" at moments
    `LeashPairs` cannot, including across a resource restart (no leash's own
    game state could ever hint at reconstructing a partnership the way it
    hints at nothing today either -- there is no physical/game state to
    recover a partnership from, hence DB-backed rather than in-memory-only).
    ======================================================================

    SCHEMA-TO-CODE MAPPING (sql/install.sql's `k9_partnerships`, read in
    full, in real column order, before this file was written -- see that
    table's own header comment for the schema rationale from the other
    direction):
      id                         -> never referenced by citizenid-keyed
                                    application code below except as the
                                    row handle passed straight through a
                                    SELECT-then-UPDATE-by-id pair (avoids a
                                    second WHERE-by-citizenid race window
                                    between the two statements).
      k9_citizenid               -> the K9-role party at establishment time
                                    (live model check via IsConfiguredK9Model,
                                    never re-checked after establishment --
                                    see "ROLE IS FROZEN AT ESTABLISHMENT"
                                    below).
      handler_citizenid          -> the officer/handler-role party.
      established_by             -> the INITIATOR's own citizenid (whoever's
                                    client sent requestPartnerUp), resolved
                                    here from `fromServerId`, never the
                                    accepter's -- see respondPartnerUp.
      established_at             -> DB default (CURRENT_TIMESTAMP), never
                                    written by this file directly.
      ended_by                   -> either the ENDING party's own citizenid
                                    (self-initiated breakPartnership, zero
                                    consent) or a `'system:<reason>'`
                                    sentinel (automatic teardown via
                                    ForceBreakPartnershipForCitizenId),
                                    mirroring `k9_certifications.revoked_by`'s
                                    identical convention.
      ended_at                   -> DB write (CURRENT_TIMESTAMP), same shape
                                    as `k9_certifications.revoked_at`.
      active                     -> 1 while live, flipped to 0 on any
                                    teardown path; never deleted, matching
                                    this resource's append-mostly-audit-row
                                    convention.
      active_partner_k9_key /
      active_partner_handler_key -> generated columns, NEVER written by
                                    this file directly (VIRTUAL, DB-derived
                                    from `active`+the two citizenid columns).
                                    Their only role in this file is as the
                                    THING the two UNIQUE KEYs below are
                                    declared on -- this file only ever reads
                                    `active`+`k9_citizenid`/`handler_citizenid`
                                    directly, never these two columns by name.

    ======================================================================
    THE TWO UNIQUE CONSTRAINTS -- WHAT THEY ACTUALLY GUARANTEE, AND WHAT
    THEY DON'T (read before touching the establish flow below):
    `uq_one_active_partnership_per_k9` and `uq_one_active_partnership_per_handler`
    are two INDEPENDENT constraints, one per COLUMN
    (`active_partner_k9_key` / `active_partner_handler_key`), not one
    constraint scoped to "this citizenid, regardless of role." Concretely:
    they guarantee no citizenid can simultaneously be the ACTIVE K9-role
    party of two different rows, and (independently) that no citizenid can
    simultaneously be the ACTIVE handler-role party of two different rows.
    They do NOT, by themselves, guarantee a single citizenid can't hold an
    active row as k9_citizenid in one partnership AND, at the same time, an
    active row as handler_citizenid in a completely different one -- those
    are two different columns, so MySQL's per-column unique-index
    enforcement never sees them as conflicting. This resource's own design
    intent (the flat `Partnerships[citizenid] = { partner, isK9, active }`
    cache shape DEVELOPER_REFERENCE.md §12.0 item 7 itself specifies -- ONE entry
    per citizenid, not a list) assumes a citizenid holds AT MOST ONE active
    partnership TOTAL, in either role, at a time -- a real player controls
    one character at a time, and "you have one partner" is the intended
    invariant, not "you have one partner per role you've ever played." The
    DB schema alone does not enforce that broader invariant; this file
    enforces it at the APPLICATION layer instead (the pre-INSERT existence
    checks in respondPartnerUp below, checking BOTH citizenid columns for
    EITHER party before ever inserting), backstopped by
    `PartnershipEstablishMutex` (a single, resource-wide critical-section
    lock around every establish attempt -- see that mutex's own comment)
    rather than by a DB constraint, precisely because no single DB
    constraint can express "these two independent unique columns must also
    be mutually exclusive for the same citizenid value." This is a REAL,
    DISCLOSED residual gap versus a database-level guarantee: a citizenid
    already the k9_citizenid of one PARTNERSHIP could, in a version of this
    file WITHOUT the mutex/pre-check discipline below, race to establish a
    SECOND partnership as handler_citizenid of an unrelated row, since the
    two unique keys would not conflict with each other. `PartnershipEstablishMutex`
    closes this in-process (every establish attempt, for BOTH roles,
    serializes through the same single critical section before any INSERT),
    which is sufficient for this resource (a single FXServer process, no
    horizontal scaling of this resource's own server-side state) -- it is
    not a claim that the DB schema itself would reject this on its own, and
    is flagged here explicitly so a future schema change doesn't
    accidentally rely on a guarantee the two existing UNIQUE KEYs don't
    actually provide.
    ======================================================================

    ROLE IS FROZEN AT ESTABLISHMENT, NEVER RE-DERIVED: unlike leash (which
    re-checks `IsConfiguredK9Model` on every attach attempt, since a leash
    pairing is transient and reformed constantly), a partnership's
    `k9_citizenid`/`handler_citizenid` columns are decided ONCE, at
    establishment time, and never re-validated against the parties' CURRENT
    ped model while the partnership stays active. This is intentional, not
    an oversight: the entire point of this registry (per DEVELOPER_REFERENCE.md
    §12.0 item 7's own framing) is to answer "who is my partner"
    independent of momentary state -- re-deriving role from a live model
    check on every read would reintroduce exactly the "goes stale the
    moment either party isn't currently in the expected state" problem this
    registry exists to solve for leash. A citizenid who switches away from
    a K9 model mid-partnership keeps their `k9_citizenid`-role row exactly
    the way a decertified-but-not-yet-revoked handler keeps their
    certification per server/certifications/'s own documented tradeoff
    (see that file's header) -- this is the same category of accepted
    staleness, not a new one invented here.

    ======================================================================
    HOW TO CONSUME THIS REGISTRY. Never reach into `Partnerships` directly
    -- it is `local` to this file, mirroring the certification system's own
    `Certifications` table. Two accessors:

    - `IsActivePartnerOf(citizenidA, citizenidB)` -- the boolean "are these
      two actively partnered", for validating an ALLEGED partner.
    - `GetActivePartnerCitizenId(citizenid)` -- returns
      `(partnerCitizenid, isK9)`, or `(nil, nil)` when no active partnership
      exists, for deriving a target directly. The caller is still
      responsible for separately checking that citizenid is CURRENTLY
      ONLINE before notifying: this file answers "who", never "are they
      online right now".

    The two features this section was originally written for -- the
    bite-and-hold recall actor and the handler-down defense trigger -- were
    both built against these accessors and then removed on 2026-09-02. The
    accessors are unchanged and still in use by server/tenure.lua and the
    tablet.
    ======================================================================

    EVENT/CALLBACK CONTRACT:

    Server events (RegisterNetEvent, client->server), THIS FILE:
    - 'qbx_k9unit:server:requestPartnerUp' (targetServerId: number)
      Mirrors server/main.lua's requestLeashAttach exactly, including its
      single-slot-per-target pending-request discipline (see
      PendingPartnershipRequests below) -- initiator asks; does NOT
      establish anything by itself, only relays a consent prompt.
    - 'qbx_k9unit:server:respondPartnerUp' (fromServerId: number, accepted: boolean)
      Mirrors respondLeashAttach's exact verified-match + TTL re-check
      discipline. On acceptance, RE-VALIDATES eligibility (TOCTOU, same as
      leash) and then runs the DB establish flow under
      PartnershipEstablishMutex -- and, inside that mutex-protected critical
      section, RE-VALIDATES HasK9Access/department membership a SECOND
      time, immediately before the INSERT (a TOCTOU fix; see that critical
      section's own comment for the exact race this closes that the
      earlier, pre-mutex re-check alone could not).
    - 'qbx_k9unit:server:breakPartnership' ()
      Either party, at any time, ZERO consent needed -- mirrors leash's
      detachLeash exactly (DEVELOPER_REFERENCE.md §12.0 item 7 point 3's own "no
      unbounded trap" restatement, now applied to a persistent relationship
      rather than only a transient one).

    Callbacks (ox_lib lib.callback), THIS FILE:
    - 'qbx_k9unit:server:getPartnershipState' () -> isPartnered: boolean, partnerServerId: number?, isK9: boolean?
      Server-authoritative "am I currently partnered, and with whom" read
      for the CALLING player, resolved via a fresh RefreshPartnershipCache
      call (never a stale read, never a client claim) -- modeled directly
      on server/certifications/'s 'qbx_k9unit:server:hasK9Access'
      callback, this resource's own established precedent for exactly this
      "client-triggerable, server-authoritative status read" shape. Added
      specifically to close client/partnership.lua's own documented
      cache-staleness gap for a client that reconnects (or whose own
      resource restarts) while already genuinely partnered per the DB --
      see that file's header for the full writeup of why a purely local
      read cannot be trusted at that moment, and why this callback is the
      fix rather than a client-side workaround.

    Client events (server->client), registered by client/partnership.lua:
    - 'qbx_k9unit:client:partnerUpRequest' (fromServerId: number)
      Shown to the target as an accept/decline prompt, mirroring
      leashAttachRequest.
    - 'qbx_k9unit:client:partnershipEstablished' (partnerServerId: number, isK9: boolean)
      Sent individually to BOTH parties once accepted, each with their OWN
      role flag -- mirrors leashAttached's exact per-party-role-flag shape.
    - 'qbx_k9unit:client:partnershipEnded' (reason: string)
      Sent to whichever of the two parties are CURRENTLY ONLINE (unlike
      leash's leashDetached, which can assume both are online since a
      leash pairing cannot exist with either party disconnected -- a
      partnership very much can; see "OFFLINE-CAPABLE BY DESIGN" below).

    Resource-global (no `local`) functions exposed for OTHER files:
    - RefreshPartnershipCache(citizenid: string) -> partnerCitizenid: string?, isK9: boolean?
      Modeled on server/certifications/'s RefreshCertificationCache --
      SAME pcall/fail-closed discipline, for the SAME reason: this function
      is called from this file's own onResourceStart backfill loop (see
      below), and an unguarded read there would abort that loop for every
      player after the first one processed, exactly the bug class
      RefreshCertificationCache was hardened against. Exposed globally (not
      `local`) for the same "documented reuse hook" reason
      IsConfiguredK9Model was -- no other file calls this today, but a
      future admin command forcing a resync for one citizenid without a
      full resource restart is a plausible, cheap reuse.
    - GetActivePartnerCitizenId(citizenid: string) -> partnerCitizenid: string?, isK9: boolean?
    - IsActivePartnerOf(citizenid: string, allegedPartnerCitizenid: string) -> boolean
      Both read-only accessors over the `local` `Partnerships` cache -- see
      "FUTURE CONSUMERS" above.
    - ForceBreakPartnershipForCitizenId(citizenid: string, reason: string) -> boolean
      Citizenid-keyed (NOT source-keyed, unlike server/main.lua's
      ForceDetachLeashForSource) -- see "OFFLINE-CAPABLE BY DESIGN" below
      for why this is a required divergence, not a style choice. Called
      from server/certifications/ alongside every existing
      ForceDetachLeashForSource/ForceDetachOfficerLeashForSource call site
      (K9-role cert revocation, either party's department change) --
      DEVELOPER_REFERENCE.md §12.0 item 7 point 3's exact instruction: "the exact
      call-site list that file already maintains for leash, extended with
      one more line per site rather than a new independent mechanism."
      Returns `false` (no-op, not an error) if `citizenid` has no active
      partnership to end.

    ======================================================================
    OFFLINE-CAPABLE BY DESIGN -- the one place this file's shape MUST
    diverge from leash's, not just could: `ForceDetachLeashForSource`
    (server/main.lua) is source-keyed and is a genuine no-op for an
    offline citizenid, because `LeashPairs` is in-memory/ephemeral and an
    offline citizenid cannot have an active pairing in it by construction
    (server/certifications/'s own `ForceDetachLeashIfOnline` wrapper
    exists specifically to make this no-op explicit at the call site). A
    K9 partnership is the OPPOSITE by design intent -- DB-backed
    specifically so it survives a disconnect (DEVELOPER_REFERENCE.md §12.0 item 7
    point 2: "session-spanning, plausibly shift-spanning"). This means
    `RevokeCertificationOffline` (server/certifications/) revoking a
    GENUINELY OFFLINE K9-role citizenid's certification must still be able
    to tear down a real, currently-active, persisted partnership row for
    them -- an online-only teardown function would silently leave that
    partnership standing indefinitely for an offline K9 revoked while
    off-shift, exactly the gap this registry was built to not have.
    `ForceBreakPartnershipForCitizenId` is therefore citizenid-keyed and
    works identically online or offline (it operates on the DB row
    directly; `TellCitizenIdPartnershipEnded` below is the only piece that
    cares whether either party happens to be connected right now, and it
    only affects whether a live client gets notified, never whether the
    DB teardown itself succeeds).

    Symmetric consequence, also intentional: THIS FILE's own `playerDropped`
    handler does NOT tear down a partnership on disconnect (unlike
    server/main.lua's `LeashPairs` cleanup, which unconditionally ends a
    leash pairing on either side disconnecting, since a disconnected party
    cannot remain leashed to anything meaningful). Only the disconnecting
    citizenid's in-memory CACHE entry is dropped -- mirroring
    server/certifications/'s own unbounded-growth fix for `Certifications`
    (harmless, cheaply rebuilt from a fresh DB query on that citizenid's
    next PlayerLoaded) -- the underlying persisted partnership, and the
    still-online partner's own view of it, are left completely untouched.
    See that handler's own comment below for the full writeup.
    ======================================================================

    ======================================================================
    ANTI-FARM GUARD EXTENSION: server/tenure.lua's partnership-tenure
    milestones reset to zero on every brand-new row, by design (see that
    file's header, design question 4) -- correct for "partner with someone
    ELSE," but NOT sufficient on its own against the SAME two citizenids
    breaking (zero consent, no cooldown -- this file's own `breakPartnership`
    below) and immediately reforming with each other, which would otherwise
    let a pair re-earn an already-earned milestone tier indefinitely. This
    file now captures, via `K9Store.PairProgress_UpsertHighestTenureTier`
    (`CaptureTenureSeedForPair`, called from `DoBreakPartnership` -- the
    single shared teardown core for self-breaks AND every forced-teardown
    path, including decertification and job/department changes), the
    highest tier any exact (k9, handler) pair has ever confirmed-earned at
    the moment either of their rows ends, into `k9_partnership_pair_progress`
    (migration 0018) -- and seeds a BRAND NEW row back to that same floor
    the instant that exact pair re-establishes (`respondPartnerUp`'s
    critical section, reading it back via
    `K9Store.PairProgress_GetHighestTenureTier` and re-applying it via the
    SAME `K9Store.Partner_SetTenureTierCAS` optimistic-CAS primitive
    server/tenure.lua's own tick already uses). FULLY DURABLE, not merely
    an in-process cache: `K9Store.PairProgress_*` goes through
    `Config.Database.enabled` exactly like every other K9Store accessor, so
    this guard survives a genuine resource restart when the database is on
    -- this used to be a real-but-partial (restart-bounded) in-memory-only
    stand-in (`PairTenureSeed`, kept in this file itself); see
    server/datastore.lua's own `k9_partnership_pair_progress` section and
    server/tenure.lua's own closing comment block ("TENURE PROGRESSION
    EXTENSIONS -- FURTHER PROPOSED ADDITIONS", item 3, now LANDED) for the
    full design this table implements.
    ======================================================================

    FILE-TO-FILE CONTRACT:
    - THIS FILE calls `IsConfiguredK9Model(modelHash)` and
      `HasK9Access(source)`, both resource-global functions exposed by
      server/certifications/ -- do not re-implement either check here
      (mirrors server/main.lua's own leash-eligibility reuse of both).
    - THIS FILE calls `NewCooldown`/`NewMutex`, resource-global constructors
      exposed by server/cooldowns.lua, at THIS file's own file-load time --
      per that file's own header, THIS FILE must load after
      server/cooldowns.lua in fxmanifest.lua's server_scripts (confirmed
      there).
    - server/certifications/ calls `ForceBreakPartnershipForCitizenId`
      from three places (RevokeCertification's online branch,
      RevokeCertificationOffline, and the QBCore:Server:OnJobUpdate
      handler's TWO branches -- department-loss and cert-revoke-due-to-
      job-change) -- each guarded by a `type(...) == 'function'` runtime
      existence check per this resource's established "runtime existence
      guard, not a load-order assumption" convention (see fxmanifest.lua's
      own comment on server/search.lua's AwardXP reuse for the same
      precedent), since THIS FILE is loaded AFTER server/certifications/
      in fxmanifest.lua (see that file's own header for why: this file
      also needs `IsConfiguredK9Model`/`HasK9Access` at RUNTIME, inside the
      eligibility check below, which certifications.lua already guarantees
      exist unconditionally without its own guard -- the two files'
      dependencies on each other are both real, but only one direction
      needs a guard, since only one direction is a call made from a file
      loaded BEFORE its callee).
    - client/partnership.lua is the ONLY client file that should register
      handlers for the three partnership client events above, or trigger
      the three partnership server events above -- same "keep the full
      subsystem confined to one client/one server file" discipline
      server/main.lua's own header establishes for leash.
    - DELIBERATELY NO CALL INTO server/wellbeing.lua FROM DoBreakPartnership
      (THIS PASS, coder-backend, "handler condition badge" feature -- see
      that file's own header section of the same name): a genuine reverse
      dependency here (server/wellbeing.lua loads AFTER this file in
      fxmanifest.lua's server_scripts) would need a brand-new resource-
      global name added to the repo-root .luacheckrc's `globals` allow-list,
      a shared file this pass does not own (other agents are concurrently
      editing it). Not needed anyway: server/wellbeing.lua's own
      PushHandlerConditionUpdate already re-resolves
      GetActivePartnerCitizenId(k9Citizenid) fresh on its own very next
      tick and clears a stale badge itself the moment it finds no active
      partnership -- self-healing, bounded to one
      Config.Wellbeing.tickIntervalMs (default 5000ms), not "forever." A
      direct hook here would only shave that bound down to "immediate,"
      never fix a case that would otherwise go unfixed.
]]

-- Partnerships[citizenid] = { partner = partnerCitizenid, isK9 = boolean,
-- active = true } -- ONE entry per citizenid, per DEVELOPER_REFERENCE.md §12.0 item
-- 7's own cache shape (see the "THE TWO UNIQUE CONSTRAINTS" header section
-- above for the gap between this single-entry assumption and what the DB
-- schema alone actually enforces). `local`, exactly like
-- server/certifications/'s `Certifications` -- nothing outside this file
-- should read it directly; always go through RefreshPartnershipCache /
-- GetActivePartnerCitizenId / IsActivePartnerOf below. Populated ONLY by
-- RefreshPartnershipCache (a fresh DB read each time), never hand-written
-- elsewhere in this file, so there is exactly one place cache entries are
-- ever constructed -- avoids the cache and the DB ever drifting out of sync
-- from two independent write paths.
local Partnerships = {}

-- Ephemeral pending partner-up requests: PendingPartnershipRequests[targetSrc]
-- = { from = initiatorSrc, expiresAt = <GetGameTimer() timestamp> }. Exact
-- same shape, TTL, and single-slot-per-target discipline as
-- server/main.lua's `PendingLeashRequests` -- including that file's own
-- fix for the request-clobbering bug (a second incoming request for a
-- target with a live, unexpired pending entry is REJECTED outright, not
-- silently overwritten with no notice to the superseded initiator, and not
-- resolved by notifying a third party). See requestPartnerUp below for
-- where that rejection happens, mirroring requestLeashAttach's own comment
-- almost verbatim. Local: nothing outside this file needs it.
local PendingPartnershipRequests = {}

-- ======================================================================
-- ANTI-FARM GUARD EXTENSION. See CaptureTenureSeedForPair below (and
-- respondPartnerUp's own establish critical section, the read/consume
-- side) for the actual mechanism; this comment records WHY it exists,
-- since the gap it closes is not obvious from server/tenure.lua's own
-- header alone.
--
-- THE GAP: server/tenure.lua's own header, design question 4 ("RESET OR
-- PERSIST ACROSS A BREAK + RE-FORM?"), reasons at length that resetting
-- `tenure_bonus_tier_granted` to 0 on every brand-new `k9_partnerships` row
-- is SAFE, because a NEW row always requires a full, fresh, real-wall-clock
-- wait before any milestone can pay out again. That reasoning is correct
-- for "break up, partner with someone ELSE, come back later" (a genuinely
-- new relationship, correctly starting over) -- but it does not, on its
-- own, cover break-then-IMMEDIATELY-reform with the EXACT SAME PARTNER,
-- which either party can trigger at will and at zero cost
-- (`breakPartnership` below requires no consent, no cooldown of its own,
-- and no eligibility check). Concretely: a pair who earns the 1-day
-- milestone (row A, 15 XP), then breaks and reforms with each other, gets
-- a BRAND NEW row B with tenure_bonus_tier_granted starting back at 0 --
-- meaning that SAME pair can earn the 1-day milestone AGAIN, roughly every
-- 24-25 real hours, indefinitely, for as long as they keep repeating the
-- cycle. server/tenure.lua's own safety argument for a wall-clock-driven,
-- non-activity-gated clock rests specifically on the total being
-- "hard-capped, ever, per partnership" (that file's header, design
-- question 3a) -- a repeatable-via-reform milestone is not that; it is a
-- small but genuinely UNBOUNDED trickle over real calendar time, using a
-- mechanism (self-serve, zero-consent break) this resource deliberately
-- keeps ungated for good reasons (the "no unbounded trap" guarantee) that
-- have nothing to do with tenure farming.
-- A flat "cannot reform with the same partner for N minutes/hours" cooldown
-- does NOT close this: since the smallest configured milestone threshold
-- (86400s = 24h) already dominates any cooldown short enough to not be a
-- real annoyance for legitimate re-pairing, a farmer simply waits slightly
-- longer between cycles and the exploit is unaffected. The only fix that
-- actually closes it is preventing the SAME (k9, handler) pair from ever
-- being credited for a milestone tier more than once, EVER -- which is
-- exactly what `tenure_bonus_tier_granted` already does WITHIN one row;
-- this section extends that same guarantee ACROSS rows, for the same pair,
-- using the SAME primitive (K9Store.Partner_SetTenureTierCAS -- the
-- identical optimistic-CAS UPDATE server/tenure.lua's own tick already
-- uses to write this column), rather than inventing a second, parallel
-- anti-farm mechanism.
--
-- FULLY DURABLE, NOT MERELY IN-PROCESS: this guard is backed by
-- `k9_partnership_pair_progress` (migration 0018) via
-- `K9Store.PairProgress_GetHighestTenureTier`/
-- `K9Store.PairProgress_UpsertHighestTenureTier` -- the same
-- `Config.Database.enabled` branch every other K9Store accessor already
-- goes through, so this guard survives a genuine resource restart
-- whenever the database is on. THIS USED TO BE THE ONE DISCLOSED GAP HERE
-- (an in-memory-only `PairTenureSeed` table, cleared on every restart --
-- see git history for that version's own "why in-memory, why not TTL'd"
-- writeup, now superseded): a fully restart-proof version needed a
-- persisted per-(k9_citizenid, handler_citizenid) record, proposed in
-- server/tenure.lua's own closing comment block ("TENURE PROGRESSION
-- EXTENSIONS -- FURTHER PROPOSED ADDITIONS", item 3) and built exactly as
-- specified there. `Config.Database.enabled = false` (memory mode, e.g.
-- every test in this suite) still degrades to an equivalent in-process
-- table (`server/datastore.lua`'s own `PairProgressRows`) for the life of
-- that process -- the K9Store abstraction already gives every other
-- accessor in this file that same dual-mode behavior, so this guard needs
-- no special-casing of its own to get it.
-- ======================================================================

--- Best-effort capture of "how far this exact pair had gotten" at the
--- moment their partnership row is torn down -- called from
--- DoBreakPartnership below (the SHARED core for BOTH the player-initiated
--- `breakPartnership` event AND `ForceBreakPartnershipForCitizenId`, so this
--- single call site covers self-initiated breaks, decertification-forced
--- breaks, AND department-change-forced breaks alike). Read-only against
--- K9Store.Partner_GetTenureRow (server/tenure.lua's own accessor,
--- unmodified, already exposed) -- never mutates anything, and can NEVER
--- abort or delay the break itself: every exit path below is a silent
--- (except for the logged write-failure case, matching this file's own
--- "EVERY WRITE'S RETURN IS CHECKED" discipline in respondPartnerUp's own
--- establish critical section below), best-effort no-op on any failure,
--- which only ever COSTS a future legitimate carry-forward, never grants
--- an extra one -- preserving this file's own "no unbounded trap" rule
--- that a teardown path is never gated on any check (see
--- DoBreakPartnership's own call site: this function's return value, if
--- any, is never inspected/branched on).
--- @param k9Citizenid string
--- @param handlerCitizenid string
local function CaptureTenureSeedForPair(k9Citizenid, handlerCitizenid)
    -- Same three-flag gate server/tenure.lua's own tick uses -- if any is
    -- off, tenure_bonus_tier_granted can never be > 0 under this config in
    -- the first place, so there is structurally nothing to capture; skip
    -- the read entirely rather than spend a query that can only ever
    -- return "nothing granted" (keeps this addition's footprint at ZERO
    -- extra queries on any server that has this experimental feature off,
    -- which is most installs, since it defaults false).
    if not (Config.Features.HandlerPartnership and Config.Features.XPProgression and Config.Features.PartnershipTenureBonus) then
        return
    end

    local ok, tenureRow = pcall(K9Store.Partner_GetTenureRow, k9Citizenid)
    if not ok or not tenureRow then return end -- row already gone, or the read failed -- fail SAFE (never seeds), see this function's own doc comment

    local grantedTier = tonumber(tenureRow.tenure_bonus_tier_granted) or 0
    if grantedTier <= 0 then return end -- nothing earned yet by this row -- nothing to protect

    -- Write-through to the durable pair-progress table -- see this
    -- section's own header for why this table, not a column. A GREATEST()
    -- upsert (server/datastore.lua) means this can never regress an
    -- already-higher stored tier, so a thrown error or a lost race here
    -- only ever costs THIS capture, never corrupts an earlier one.
    local upsertOk, upsertErr = pcall(K9Store.PairProgress_UpsertHighestTenureTier, k9Citizenid, handlerCitizenid, grantedTier)
    if not upsertOk then
        print(('[qbx_k9unit] partnership: tenure anti-farm pair-progress UPSERT threw for k9=%s handler=%s (tier=%d): %s'):format(k9Citizenid, handlerCitizenid, grantedTier, tostring(upsertErr)))
    end
end

--- Single, resource-wide critical-section lock around every "establish a
--- partnership" attempt, from the moment eligibility is re-validated
--- (TOCTOU-safe) through the INSERT completing. See "THE TWO UNIQUE
--- CONSTRAINTS" in this file's header for exactly what race this closes
--- that the two DB-level UNIQUE KEYs alone cannot (a citizenid racing to
--- become the K9-role party of one partnership AND the handler-role party
--- of a different one at the same instant, which hits two INDEPENDENT
--- unique columns and so would not conflict at the DB level).
---
--- DELIBERATELY A SINGLE GLOBAL KEY, NOT PER-CITIZENID: a per-citizenid
--- locking scheme would need a fixed acquisition ORDER across both
--- citizenids in a pair to avoid a classic two-lock deadlock (initiator A
--- accepting B's request while, in the same instant, some other pairing
--- acquires B-then-A) -- solvable, but real added complexity for an action
--- that is: (a) gated by mutual consent + a TTL'd single-slot pending
--- request + a per-source rate limit already, making genuine contention
--- vanishingly rare in practice, and (b) cheap to just ask the loser to
--- retry (their PendingPartnershipRequests entry is already consumed by
--- the time this mutex is even reached -- see respondPartnerUp -- so a
--- rejected acquisition here simply means "send a fresh request," not any
--- loss of a real in-flight guarantee). A single global lock is the
--- simplest correct answer for an action this infrequent; per-citizenid
--- lock ordering would be solving a contention problem that does not
--- exist here.
---
--- The establish flow below (respondPartnerUp) wraps its ENTIRE critical
--- section in `pcall` and unconditionally releases this mutex in a
--- `finally`-equivalent (Release called right after the pcall returns,
--- before branching on its result) specifically so a thrown DB error can
--- never leave this global lock permanently held -- an unreleased global
--- mutex would be a self-inflicted, resource-wide denial of the ENTIRE
--- partnership-establish feature until the next resource restart, which
--- would be a strictly worse failure mode than the rare race it exists to
--- prevent.
local PartnershipEstablishMutex = NewMutex()
local PARTNERSHIP_ESTABLISH_MUTEX_KEY = 'establish'

-- Mirrors server/main.lua's LeashRequestCooldown exactly -- same
-- UI-harassment-vector rationale (an eligible nearby party spamming
-- accept/decline prompts at a target with no rate limit), same
-- NewCooldown()-backed, per-INITIATOR-source keying, same
-- :RegisterPlayerDropped() cleanup.
--
-- ResolveConfiguredThresholdMs (server/cooldowns.lua — see that file's
-- header ADDENDUM) wraps the raw Config read below rather than handing it
-- straight to NewCooldown: an uncaught non-positive value there would
-- abort THIS FILE's load from that line onward instead of just disabling
-- this one cooldown. Fallback matches config.lua's own shipped default.
local PartnerRequestCooldown = NewCooldown(ResolveConfiguredThresholdMs(
    Config.Partnership.RequestCooldownMs, 1000, 'Config.Partnership.RequestCooldownMs'))
PartnerRequestCooldown.RegisterPlayerDropped()

-- NotifyPlayer used to be defined here as its own local copy (one of 12
-- independent hand-rolled copies across this resource). It is now
-- server/notify.lua's single shared resource-global implementation -- see
-- that file's own header for the extraction writeup. Every call site below
-- is unchanged: this file never passed a custom title, which is
-- server/notify.lua's own default.

--- Sends the `partnershipEnded` client event to `citizenid` ONLY if they
--- currently resolve to a connected server id -- silent no-op otherwise
--- (an offline party has no client to tell, and will see the correct,
--- already-updated state the next time RefreshPartnershipCache runs for
--- them at their own next PlayerLoaded). Mirrors
--- server/certifications/'s `ForceDetachLeashIfOnline`'s own
--- online-resolution pattern, applied here to a notification instead of a
--- state mutation (the mutation -- the DB UPDATE -- already happened
--- unconditionally by the time this is called; this only decides whether
--- there's a live client worth telling about it).
--- @param citizenid string
--- @param reason string
local function TellCitizenIdPartnershipEnded(citizenid, reason)
    local player = exports.qbx_core:GetPlayerByCitizenId(citizenid)
    local src = player and player.PlayerData and player.PlayerData.source
    if not src then return end
    TriggerClientEvent('qbx_k9unit:client:partnershipEnded', src, reason)
end

--- Fires a stable `qbx_k9unit:events:*` outbound event for other resources
--- (dispatch/MDT/evidence integrations — see server/exports.lua's header
--- "EVENT CONTRACT" section for the full documented contract this
--- implements). MOVED to server/events.lua: this file's own
--- `FireOutboundEvent` copy — byte-for-byte identical to the five other
--- copies that existed alongside it — is now the single shared
--- resource-global implementation in that file. See server/events.lua's
--- header for the full extraction writeup. Every call site below is
--- unchanged: same event names, arguments, order, and firing conditions.

--- Re-queries the active-partnership row for `citizenid` (in EITHER role)
--- and updates the in-memory cache. Exposed globally (no `local`) -- see
--- this file's header for the full pcall/fail-closed rationale, mirroring
--- server/certifications/'s `RefreshCertificationCache` for the exact
--- same reason (this file's own onResourceStart backfill loop below calls
--- this once per already-connected player; an unguarded error on the
--- first iteration would otherwise abort the whole loop for every
--- subsequent player, per this resource's own confirmed and fixed
--- regression on the certification side of the same pattern).
--- @param citizenid string
--- @return string? partnerCitizenid -- nil if no active partnership
--- @return boolean? isK9 -- true if `citizenid` is the K9-role party; nil if no active partnership
function RefreshPartnershipCache(citizenid)
    if type(citizenid) ~= 'string' or citizenid == '' then return nil, nil end

    local queryOk, rowOrErr = pcall(K9Store.Partner_GetActiveRowByParty, citizenid)

    if not queryOk then
        print(('[qbx_k9unit] RefreshPartnershipCache query failed for %s: %s'):format(citizenid, tostring(rowOrErr)))
        -- FAIL CLOSED: an unreadable partnership row must never be treated
        -- as an active partnership -- same discipline as
        -- RefreshCertificationCache, for the same disclosed reason (see
        -- that function's own doc comment in server/certifications/).
        Partnerships[citizenid] = nil
        return nil, nil
    end

    if not rowOrErr then
        Partnerships[citizenid] = nil
        return nil, nil
    end

    local isK9 = rowOrErr.k9_citizenid == citizenid
    local partner = isK9 and rowOrErr.handler_citizenid or rowOrErr.k9_citizenid
    Partnerships[citizenid] = { partner = partner, isK9 = isK9, active = true }
    return partner, isK9
end

--- Read-only accessor over the `local` `Partnerships` cache -- see
--- "HOW TO CONSUME THIS REGISTRY" in this file's header. Callers reach it
--- behind a `type(GetActivePartnerCitizenId) == 'function'` runtime guard,
--- never a load-order assumption.
--- @param citizenid string
--- @return string? partnerCitizenid
--- @return boolean? isK9
function GetActivePartnerCitizenId(citizenid)
    local cached = Partnerships[citizenid]
    if not cached or not cached.active then return nil, nil end
    return cached.partner, cached.isK9
end

--- Read-only accessor over the `local` `Partnerships` cache, expressing
--- exactly the boolean check DEVELOPER_REFERENCE.md §12.0 item 7 specifies for
--- See "HOW TO CONSUME THIS REGISTRY" in this file's
--- header for the originally-intended caller. Called by server/main.lua's
--- requestLeashAttach, which lets two partners leash without a prompt, and
--- reachable by other resources via server/exports.lua's `IsActivePartnerOf`
--- export.
--- @param citizenid string
--- @param allegedPartnerCitizenid string
--- @return boolean
function IsActivePartnerOf(citizenid, allegedPartnerCitizenid)
    local cached = Partnerships[citizenid]
    return cached ~= nil and cached.active == true and cached.partner == allegedPartnerCitizenid
end

--- @param citizenid string
--- @return boolean
local function IsAlreadyPartnered(citizenid)
    local cached = Partnerships[citizenid]
    return cached ~= nil and cached.active == true
end

--- Deliberately NARROWER than the model-OR-role widened check
--- (initiatorIsK9/targetIsK9) CheckPartnershipEligibility computes below --
--- used ONLY to decide the "both parties are a K9" rejection, never the
--- "neither party is a K9" one. See that function's own "BOTH-ARE-K9 CASE"
--- comment for the exact gap this closes: two K9s could partner with each
--- other, with one silently cast as the handler, since the widened check
--- only ever rejects "neither."
---
--- WHY ROLE, NOT MODEL, NOT THE SAME WIDENED OR THIS FUNCTION USES
--- ELSEWHERE: server/appearance.lua's own header defines "HOLDS THE K9
--- ROLE" precisely as HasK9Role's own OR (an active cert for the CURRENT
--- job, or an active k9.access grant) -- deliberately EXCLUDING both ped
--- model AND the autoAccessGrade/High-Command bypasses baked into
--- HasK9Access, "since those grant broad, blanket access to K9
--- *features*... without making that officer's own character *be* the
--- K9." That is exactly the distinction this rejection needs:
---   - Ped MODEL is NOT evidence of "genuinely a K9" here. A
---     Config.Peds-listed species can be worn by an ordinary department
---     officer for reasons that have nothing to do with K9 access -- a
---     legitimate HANDLER can be standing on a dog model (this resource's
---     own K9 role/model decoupling: "everything works on any ped" is a
---     two-way guarantee, not just "a K9 can look human"). Folding model
---     into this specific check would misclassify that officer as a
---     second K9 and wrongly refuse an otherwise-legitimate pairing --
---     exactly the "strict direction" mistake that is worse than the bug
---     this check exists to close.
---   - HasK9Access is NOT evidence either, for the opposite reason: it is
---     deliberately WIDER than "is the K9" (a High Command or
---     autoAccessGrade bypass can make it true for a citizenid who has
---     never held the K9 role at all). Using it here would flag a High
---     Command officer merely anchoring/overseeing as a second K9 and,
---     again, wrongly refuse the pairing.
--- HasK9Role is this resource's own existing, documented answer to "does
--- this citizenid actually hold the K9 identity" -- independent of
--- current appearance and independent of any blanket access bypass -- so
--- it is the one primitive that is neither too narrow nor too wide for
--- this specific question.
---
--- FALLBACK, mirroring this file's own established soft-dependency
--- discipline for HasK9Role (see initiatorIsK9/targetIsK9's identical
--- `type(...) == 'function'` guard below): if server/appearance.lua is
--- ever removed, "the K9 role" does not exist as a model-independent
--- concept in that world either -- IsConfiguredK9Model was this
--- resource's ONLY signal for "is this citizenid a K9" pre-decoupling, so
--- that is what this degrades to, rather than unconditionally returning
--- `false` (which would silently disable the both-are-K9 rejection
--- entirely instead of degrading to the same pre-decoupling behavior
--- every other check in this file already degrades to).
--- @param src number
--- @param ped number
--- @return boolean
local function IsGenuinelyK9Party(src, ped)
    if type(HasK9Role) == 'function' then
        return HasK9Role(src)
    end
    return IsConfiguredK9Model(GetEntityModel(ped))
end

--- Returns true if `err` (the value pcall caught around the establishing
--- INSERT) represents a MySQL/MariaDB duplicate-key error (1062) on either
--- of this table's two UNIQUE KEYs. Duplicated from
--- server/certifications/'s `IsDuplicateKeyError` rather than shared --
--- same tiny, self-contained, no-shared-state helper (unlike NotifyPlayer
--- above, which WAS one of 12 duplicated copies of the same UI-plumbing
--- helper across this resource, now consolidated into server/notify.lua --
--- see that file's own header). See that function's own
--- doc comment for why every shape checked here (table with
--- .errno/.code/.message/.sqlMessage, or a plain string) is checked rather
--- than assuming one specific oxmysql error shape.
--- @param err any
--- @return boolean
local function IsDuplicateKeyError(err)
    if type(err) == 'table' then
        if err.errno == 1062 or err.code == 1062 then return true end
        local message = err.message or err.sqlMessage
        if type(message) == 'string' and (message:find('1062', 1, true) or message:find('ER_DUP_ENTRY', 1, true)) then
            return true
        end
    elseif type(err) == 'string' then
        if err:find('1062', 1, true) or err:find('ER_DUP_ENTRY', 1, true) or err:find('Duplicate entry', 1, true) then
            return true
        end
    end
    return false
end

--- Human-readable rejection messages for CheckPartnershipEligibility's
--- `reason` return value. Mirrors server/main.lua's LEASH_REJECT_MESSAGES
--- shape exactly.
-- 'not_granted' (PER-PERSON FEATURE CONTROL, see
-- IsHandlerPartnershipPermittedForCitizenId below) is DELIBERATELY NOT given
-- its own entry here -- PartnershipRejectReasonMessage's own `or
-- locale('partnership.reject_fallback')` fallback already covers it with an
-- existing, already-shipped, already-tested locale key ("Unable to set up
-- partnership."), so no NEW locale key is needed (and none is added here --
-- locales/en.json is not edited directly by this file, and the test
-- sandbox's own `locale()` hard-asserts every key it's asked for actually
-- exists, so introducing an unshipped key here would redden tests/run.sh
-- for every spec that loads this file, not just fail silently at runtime).
--
-- 'both_k9' (see CheckPartnershipEligibility's own "BOTH-ARE-K9 CASE"
-- comment, and IsGenuinelyK9Party's doc comment, above) DOES get its own
-- entry, deliberately NOT reusing 'no_k9_party's message: "neither of you
-- is a K9" and "you are both K9s" are different problems with different
-- remedies, and telling the wrong one sends someone looking in the wrong
-- place. common.both_k9 (shared with server/main.lua's identical
-- LEASH_REJECT_MESSAGES entry, same as common.no_k9_party/
-- common.k9_not_certified/common.handler_not_in_department above) shipped
-- to locales/en.json for exactly this reason.
local PARTNERSHIP_REJECT_MESSAGES = {
    feature_disabled          = locale('partnership.feature_disabled'),
    invalid_target            = locale('partnership.invalid_target'),
    already_partnered         = locale('partnership.reject_already_partnered'),
    offline                   = locale('common.target_no_longer_online'),
    too_far                   = locale('partnership.too_far'),
    no_k9_party               = locale('common.no_k9_party'),
    both_k9                   = locale('common.both_k9'),
    not_certified             = locale('common.k9_not_certified'),
    officer_not_in_department = locale('common.handler_not_in_department'),
}

--- @param reason string?
--- @return string
local function PartnershipRejectReasonMessage(reason)
    return PARTNERSHIP_REJECT_MESSAGES[reason] or locale('partnership.reject_fallback')
end

-- ======================================================================
-- PER-PERSON FEATURE CONTROL (Config.FeatureControl -- config.lua's own
-- header documents the 4-step resolution; step 1, Config.Features.
-- HandlerPartnership, is already checked separately by
-- CheckPartnershipEligibility below before this function is ever reached).
-- Mirrors server/pursuitsprint.lua's IsPursuitSprintPermittedForCitizenId
-- shape verbatim (that file's own header says to read it before writing
-- another variant). Checked against BOTH the K9-role and officer-role
-- citizenid before a NEW partnership may ESTABLISH (either party being
-- blocked/ungranted refuses formation) -- this is the ENTRY POINT this
-- feature has (mutual consent to FORM a partnership); breakPartnership
-- below is DELIBERATELY NEVER gated by this check, or by anything else --
-- see that handler's own comment for why (the "no unbounded trap"
-- guarantee this file's header already states for that path).
-- ======================================================================
--- @param citizenid string
--- @return boolean allowed
local function IsHandlerPartnershipPermittedForCitizenId(citizenid)
    -- Soft dependency, this resource's established convention -- see
    -- server/pursuitsprint.lua's own identical comment on its own copy of
    -- this guard.
    local hasPermissionAvailable = type(HasPermission) == 'function'

    if hasPermissionAvailable and HasPermission(citizenid, 'block.HandlerPartnership') == true then
        return false -- step 2: an explicit block always wins, even over an active grant
    end

    local featureControl = Config.FeatureControl
    local requiresGrant = type(featureControl) == 'table'
        and type(featureControl.RequireGrant) == 'table'
        and featureControl.RequireGrant.HandlerPartnership == true

    if requiresGrant then
        -- step 3: listed in RequireGrant -> ALLOW only with an active grant.
        return hasPermissionAvailable and HasPermission(citizenid, 'feature.HandlerPartnership') == true
    end

    return true -- step 4: not listed in RequireGrant at all -- default allow (matches config.lua's own documented default)
end

--- Shared eligibility/proximity checks for establishing a partnership, run
--- at BOTH request time and accept time (mirrors server/main.lua's
--- CheckLeashEligibility exact TOCTOU discipline -- re-run at accept time
--- so nothing that changed in between slips through).
---
--- AUTHORIZATION MODEL (DEVELOPER_REFERENCE.md §12.0 item 7 point 4 -- "mutual
--- consent only, no certifier-grade hierarchy"): deliberately reuses
--- LEASH's own asymmetric eligibility shape, not a stricter
--- both-need-HasK9Access reading of that item's own point 1 prose ("both
--- parties currently pass HasK9Access-equivalent checks for the same
--- department"). CONFIDENCE NOTE, disclosed rather than silently resolved:
--- that phrase is genuinely ambiguous between (a) "both parties go through
--- an eligibility check styled after HasK9Access" (satisfied by the
--- leash-mirroring shape below) and (b) "the handler must ALSO hold an
--- active HasK9Access-passing certification, in the SAME department as the
--- K9." Reading (b) literally would mean a handler who has never
--- personally certified (the overwhelmingly common real case for an
--- officer who only ever anchors/partners, never plays the K9 role
--- themselves) could never be anyone's partner at all, which contradicts
--- point 4's own "peer relationship between two parties who are each
--- already independently eligible (department membership / K9 model)" --
--- that later, more precisely-scoped sentence matches leash's actual
--- shipped, reviewed model exactly (K9-role needs HasK9Access, officer-role
--- needs mere department membership, no same-department cross-check).
--- This function follows point 4's precise wording and
--- CheckLeashEligibility's shipped precedent over point 1's looser prose,
--- since DEVELOPER_REFERENCE.md §12.0 item 7 point 1 itself says this design
--- "reuses `CheckLeashEligibility`" as its own stated model. Flagged
--- honestly as a judgment call on an ambiguous spec phrase, not asserted
--- as the only possible reading.
--- @param initiatorSrc number
--- @param targetSrc number
--- @return boolean ok
--- @return number? k9Src
--- @return number? officerSrc
--- @return string? reason -- present when ok == false
--- @return string? k9Citizenid -- present when ok == true
--- @return string? officerCitizenid -- present when ok == true
local function CheckPartnershipEligibility(initiatorSrc, targetSrc)
    if not Config.Features.HandlerPartnership then
        return false, nil, nil, 'feature_disabled'
    end

    if type(initiatorSrc) ~= 'number' or type(targetSrc) ~= 'number' or initiatorSrc == targetSrc then
        return false, nil, nil, 'invalid_target'
    end

    local initiatorPed = GetPlayerPed(initiatorSrc)
    local targetPed = GetPlayerPed(targetSrc)
    if initiatorPed == 0 or targetPed == 0 then
        return false, nil, nil, 'offline'
    end

    local initiatorPlayer = exports.qbx_core:GetPlayer(initiatorSrc)
    local targetPlayer = exports.qbx_core:GetPlayer(targetSrc)
    local initiatorCitizenid = initiatorPlayer and initiatorPlayer.PlayerData and initiatorPlayer.PlayerData.citizenid
    local targetCitizenid = targetPlayer and targetPlayer.PlayerData and targetPlayer.PlayerData.citizenid
    if not initiatorCitizenid or not targetCitizenid then
        return false, nil, nil, 'offline'
    end

    -- SAME-IDENTITY GUARD, BY CITIZENID: the `initiatorSrc == targetSrc`
    -- check above only rejects self-targeting by SERVER ID -- but a server
    -- id is a per-connection number FiveM recycles, not a stable identity
    -- (see e.g. the playerDropped handler below scanning
    -- PendingPartnershipRequests specifically because a freed id can be
    -- reassigned to an unrelated citizenid before a pending request's own
    -- TTL expires). The citizenid, resolved above from each party's OWN
    -- current session, is this resource's actual identity boundary (every
    -- persisted row, every cache entry, every per-person feature-control
    -- check in this file is keyed by it, never by source) -- so this is
    -- the check that actually matters if a reconnect, a stale pending
    -- request resolving against a NEW session for the citizenid it used to
    -- name, or any other path ever produces two distinct server ids that
    -- both resolve to the same citizenid at once. Checked here, after both
    -- citizenids are already resolved, rather than duplicating the
    -- resolution just to check it earlier.
    if initiatorCitizenid == targetCitizenid then
        return false, nil, nil, 'invalid_target'
    end

    -- Cache-based pre-check only -- a fast, early, honest rejection before
    -- either party goes through a consent prompt for a request that could
    -- never complete. NOT the final authority: the establish flow itself
    -- (respondPartnerUp) re-checks this against the DB directly, under
    -- PartnershipEstablishMutex, immediately before the INSERT -- see this
    -- file's "THE TWO UNIQUE CONSTRAINTS" header section for exactly why a
    -- cache-only check here would not be sufficient on its own.
    if IsAlreadyPartnered(initiatorCitizenid) or IsAlreadyPartnered(targetCitizenid) then
        return false, nil, nil, 'already_partnered'
    end

    local dist = #(GetEntityCoords(initiatorPed) - GetEntityCoords(targetPed))
    if dist > Config.Partnership.ProximityMeters then
        return false, nil, nil, 'too_far'
    end

    -- Roles via live model check (never client-claimed) -- see this file's
    -- header "ROLE IS FROZEN AT ESTABLISHMENT" note for why this is the
    -- ONLY point in this partnership's lifetime role is derived this way.
    -- WIDENED (K9 role/model decoupling, server/appearance.lua) with the
    -- same `or HasK9Role(...)` shape as server/main.lua's identical
    -- CheckLeashEligibility check -- see that file's own comment on this
    -- line for the full "why OR, why guarded, why not touching
    -- IsConfiguredK9Model itself" reasoning, which applies verbatim here.
    local initiatorIsK9 = IsConfiguredK9Model(GetEntityModel(initiatorPed))
        or (type(HasK9Role) == 'function' and HasK9Role(initiatorSrc))
    local targetIsK9 = IsConfiguredK9Model(GetEntityModel(targetPed))
        or (type(HasK9Role) == 'function' and HasK9Role(targetSrc))

    if not initiatorIsK9 and not targetIsK9 then
        return false, nil, nil, 'no_k9_party'
    end

    -- BOTH-ARE-K9 CASE (owner-reported gap): the check above only ever
    -- rejects "NEITHER party is a K9" -- when initiatorIsK9 AND targetIsK9
    -- are both true, the tie-break just below silently assigns one of two
    -- genuine K9s the OFFICER/handler role instead of rejecting outright,
    -- and that establishment then actually SUCCEEDS, since a K9
    -- role-holder is typically ALSO a department member and so trivially
    -- clears officer_not_in_department too -- there is nothing downstream
    -- that would otherwise catch this. "Neither of you is a K9" and "you
    -- are both K9s" are different problems with different remedies, so
    -- this gets its own reason rather than being folded into either
    -- 'no_k9_party' or the ordinary success path.
    --
    -- Deliberately does NOT reuse initiatorIsK9/targetIsK9 (the widened
    -- model-OR-role check immediately above) for THIS decision -- see
    -- IsGenuinelyK9Party's own doc comment for exactly why model must not
    -- be read as proof the OTHER party can't legitimately be the handler
    -- (a real handler's ped can coincidentally be a Config.Peds-listed
    -- species for reasons that have nothing to do with them holding K9
    -- access) and why HasK9Access alone is too WIDE for this question in
    -- the opposite direction (High Command / autoAccessGrade bypasses).
    if IsGenuinelyK9Party(initiatorSrc, initiatorPed) and IsGenuinelyK9Party(targetSrc, targetPed) then
        return false, nil, nil, 'both_k9'
    end

    -- Same tie-break as server/main.lua's CheckLeashEligibility when BOTH
    -- are K9-modeled: the REQUEST TARGET defaults to the K9 role.
    local k9Src, officerSrc, k9Citizenid, officerCitizenid
    if targetIsK9 then
        k9Src, officerSrc = targetSrc, initiatorSrc
        k9Citizenid, officerCitizenid = targetCitizenid, initiatorCitizenid
    else
        k9Src, officerSrc = initiatorSrc, targetSrc
        k9Citizenid, officerCitizenid = initiatorCitizenid, targetCitizenid
    end

    -- NOT the final authority for either check below, same disclosed
    -- caveat as the already-partnered pre-check above: at REQUEST time
    -- (called from requestPartnerUp) this is only ever an early, honest
    -- rejection. At ACCEPT time (called from respondPartnerUp) it is a
    -- TOCTOU re-check of what was true when the request was first sent --
    -- but it still runs BEFORE PartnershipEstablishMutex.TryAcquire, so a
    -- revoke landing between THIS check returning true and the INSERT
    -- actually committing would otherwise slip through uncaught. See
    -- respondPartnerUp's critical-section comment (search for "TOCTOU
    -- FIX") for where both of these are re-run a SECOND time, inside the
    -- mutex, immediately before the INSERT, to close that specific window.
    if not HasK9Access(k9Src) then
        return false, nil, nil, 'not_certified'
    end

    -- Officer/handler-role party: mere department membership, no
    -- certification of their own required -- see this function's own
    -- AUTHORIZATION MODEL doc comment above.
    local officerPlayer = (officerSrc == initiatorSrc) and initiatorPlayer or targetPlayer
    local officerJob = officerPlayer and officerPlayer.PlayerData and officerPlayer.PlayerData.job
    if not officerJob or not Config.Departments[officerJob.name] then
        return false, nil, nil, 'officer_not_in_department'
    end

    -- PER-PERSON FEATURE CONTROL -- see IsHandlerPartnershipPermittedForCitizenId
    -- above. Checked LAST (cheapest/most-defensive checks first, matching
    -- this function's own established discipline) and against BOTH parties --
    -- either one being blocked/ungranted refuses the SAME establishment
    -- attempt. NOT the final authority any more than the checks above it are
    -- (see this function's own doc comment on the TOCTOU re-check inside
    -- respondPartnerUp's critical section below).
    if not IsHandlerPartnershipPermittedForCitizenId(k9Citizenid)
        or not IsHandlerPartnershipPermittedForCitizenId(officerCitizenid) then
        return false, nil, nil, 'not_granted'
    end

    return true, k9Src, officerSrc, nil, k9Citizenid, officerCitizenid
end

--- Step 1 of the consent handshake: initiator asks to partner with target.
--- Does NOT establish anything -- only relays a prompt if the request
--- itself is currently valid. Mirrors server/main.lua's requestLeashAttach
--- almost line-for-line, including its exact fix for the request-
--- clobbering bug (see that handler's own comment for the full writeup;
--- restated briefly here since this is a near-verbatim mirror, not a
--- reference to it).
--- @param targetServerId number
RegisterNetEvent('qbx_k9unit:server:requestPartnerUp', function(targetServerId)
    local src = source

    if type(targetServerId) ~= 'number' then
        NotifyPlayer(src, locale('partnership.invalid_target'), 'error')
        return
    end

    local ok, _, _, reason = CheckPartnershipEligibility(src, targetServerId)
    if not ok then
        NotifyPlayer(src, PartnershipRejectReasonMessage(reason), 'error')
        return
    end

    -- SECURITY FIX PRECEDENT APPLIED HERE (mirrors server/main.lua's
    -- requestLeashAttach): reject a SECOND request outright while a live,
    -- unexpired one is already pending for this target, rather than
    -- silently overwriting it -- that shape previously let a second
    -- initiator silently clobber a first initiator's pending request with
    -- no notice to the superseded party (a denial-of-service/UX-integrity
    -- gap, not a consent-guarantee weakening, since respondPartnerUp's own
    -- match+TTL check below still requires the correct initiator either
    -- way). Reject the SECOND caller with a notice to THEMSELVES (the same
    -- "notify the caller of their own rejected action" convention
    -- CheckPartnershipEligibility's rejection path above already uses)
    -- rather than trying to notify a THIRD party (the first initiator)
    -- about an action they themselves didn't take. Checked BEFORE consuming
    -- the rate limit below so a legitimately-rejected duplicate doesn't
    -- burn the caller's own cooldown allowance.
    local existingPending = PendingPartnershipRequests[targetServerId]
    if existingPending and GetGameTimer() <= existingPending.expiresAt then
        NotifyPlayer(src, locale('partnership.pending_request_exists'), 'error')
        return
    end

    if not PartnerRequestCooldown.Consume(src) then
        return -- silent no-op: rate-limited, not an error worth notifying about (matches this resource's bark/leash-request/certify-action convention)
    end

    PendingPartnershipRequests[targetServerId] = { from = src, expiresAt = GetGameTimer() + Config.Partnership.RequestTTLMs }

    TriggerClientEvent('qbx_k9unit:client:partnerUpRequest', targetServerId, src)
    NotifyPlayer(src, locale('partnership.partner_request_sent'), 'inform')
end)

--- Step 2 of the consent handshake: target's response. Mirrors
--- server/main.lua's respondLeashAttach's exact validate-before-notify
--- discipline (restated briefly here since this is a near-verbatim
--- mirror): the pending request is verified genuine (matching initiator +
--- unexpired) BEFORE any TriggerClientEvent/NotifyPlayer referencing the
--- client-supplied `fromServerId` fires, so a spoofed/expired/mismatched
--- claim only ever results in an error notice to the CALLER themselves,
--- never an arbitrary-target notification.
--- @param fromServerId number
--- @param accepted boolean
RegisterNetEvent('qbx_k9unit:server:respondPartnerUp', function(fromServerId, accepted)
    local src = source -- the target, responding

    if type(fromServerId) ~= 'number' then return end

    local pending = PendingPartnershipRequests[src]
    local verifiedMatch = pending ~= nil and pending.from == fromServerId

    if not verifiedMatch or GetGameTimer() > pending.expiresAt then
        PendingPartnershipRequests[src] = nil -- drop a stale/expired entry, if any
        NotifyPlayer(src, locale('partnership.request_no_longer_valid_self'), 'error')
        if verifiedMatch then
            NotifyPlayer(fromServerId, locale('partnership.request_no_longer_valid_initiator'), 'error')
        end
        return
    end

    PendingPartnershipRequests[src] = nil -- consumed either way, accept or decline, now that it's confirmed genuine

    if not accepted then
        NotifyPlayer(fromServerId, locale('partnership.request_declined'), 'inform')
        return
    end

    -- RE-VALIDATE -- do not trust that nothing changed since the request
    -- was sent (classic TOCTOU: either party could have disconnected,
    -- moved out of range, gotten partnered with someone else, or lost
    -- eligibility in the meantime).
    local ok, k9Src, officerSrc, reason, k9Citizenid, officerCitizenid = CheckPartnershipEligibility(fromServerId, src)
    if not ok then
        NotifyPlayer(fromServerId, PartnershipRejectReasonMessage(reason), 'error')
        NotifyPlayer(src, PartnershipRejectReasonMessage(reason), 'error')
        return
    end

    if not PartnershipEstablishMutex.TryAcquire(PARTNERSHIP_ESTABLISH_MUTEX_KEY) then
        -- Genuinely rare in practice (see PartnershipEstablishMutex's own
        -- doc comment) -- both PendingPartnershipRequests entries for this
        -- pair are already consumed at this point either way, so the only
        -- recovery is a fresh request; tell both parties plainly rather
        -- than silently dropping the accept.
        NotifyPlayer(fromServerId, locale('partnership.setup_busy'), 'error')
        NotifyPlayer(src, locale('partnership.setup_busy'), 'error')
        return
    end

    -- Everything from here through Release() below is the critical
    -- section PartnershipEstablishMutex protects -- wrapped in pcall so a
    -- thrown DB error can never leave the mutex permanently held (see that
    -- mutex's own doc comment for why this matters more here than an
    -- ordinary single-request failure would).
    local ranOk, outcomeOrErr = pcall(function()
        -- TOCTOU FIX (MEDIUM severity; eligibility, not just "already
        -- partnered"): CheckPartnershipEligibility above re-ran
        -- HasK9Access(k9Src) and the officer's department check, but it ran
        -- BEFORE PartnershipEstablishMutex.TryAcquire and before this
        -- pcall's own critical section even began -- a real, exploitable
        -- window, not a theoretical one. Concretely: RevokeCertification's
        -- online branch (server/certifications/) runs its UPDATE,
        -- refreshes ITS OWN certification cache, then calls
        -- ForceBreakPartnershipForCitizenId for the now-decertified
        -- citizenid -- and THAT call's own SELECT (inside
        -- DoBreakPartnership) can complete BEFORE the INSERT below commits,
        -- since oxmysql pools connections and gives no completion-order
        -- guarantee across these two independent call chains. If that
        -- SELECT runs first, it finds no active partnership row yet (this
        -- one doesn't exist until the INSERT below runs), no-ops, and the
        -- INSERT then lands anyway -- establishing a live partnership for a
        -- citizenid that was just decertified a moment earlier. Nothing
        -- re-validates an established partnership afterwards, by this
        -- file's own documented "role frozen at establishment, never
        -- re-derived" design (see this file's header), so a race landing
        -- this way would otherwise stand indefinitely.
        --
        -- CORRECTION (this re-check was previously placed BEFORE the two
        -- already-partnered SELECTs below, which are themselves two more
        -- `await` suspension points a concurrent revoke could complete
        -- underneath -- the window this comment block claimed to close
        -- ("immediately before the INSERT") did not actually match the
        -- code order that shipped. HasK9Access/department membership are
        -- both synchronous, in-memory, non-yielding reads (no MySQL round
        -- trip), so re-ordered here to run as the LAST checks before the
        -- INSERT itself, with nothing else in this coroutine yielding in
        -- between -- the only remaining window is the INSERT's own await,
        -- which is exactly the DB-level UNIQUE KEY / duplicate-key-error
        -- backstop already handles below. Same fix shape as
        -- server/search.lua's HandleSearchTarget re-checking
        -- HasK9Access(source) immediately after its own genuinely-yielding
        -- await (see that file's own doc comment, validation step 8: "the
        -- earlier callback-registration check only proves access at
        -- REQUEST time... re-check immediately before computing/
        -- broadcasting anything"), applied here to an establishment instead
        -- of a search.
        --
        -- Fresh, AUTHORITATIVE re-check of "already partnered" -- the
        -- cache-based check inside CheckPartnershipEligibility above is a
        -- fast early-reject only, not the final word (see this file's
        -- header "THE TWO UNIQUE CONSTRAINTS" section for exactly which
        -- race this closes that the DB's own two independent UNIQUE KEYs
        -- cannot). Checks EACH citizenid against BOTH DB columns, not just
        -- their own expected role's column, since the whole point of this
        -- check is catching a citizenid who raced into the OTHER role
        -- somewhere else. Run BEFORE the HasK9Access/department re-check
        -- below on purpose (see the CORRECTION note above) -- these two
        -- SELECTs are the only remaining `await` points before the INSERT,
        -- so the synchronous eligibility re-check must come AFTER them,
        -- not before, to sit truly adjacent to the INSERT.
        local k9AlreadyPartnered = K9Store.Partner_GetActiveIdByParty(k9Citizenid)
        if k9AlreadyPartnered then return 'already_partnered' end

        local officerAlreadyPartnered = K9Store.Partner_GetActiveIdByParty(officerCitizenid)
        if officerAlreadyPartnered then return 'already_partnered' end

        -- Genuinely last checks before the INSERT -- see the CORRECTION
        -- note above for why these moved here.
        if not HasK9Access(k9Src) then
            return 'not_certified'
        end

        local officerPlayerNow = exports.qbx_core:GetPlayer(officerSrc)
        local officerJobNow = officerPlayerNow and officerPlayerNow.PlayerData and officerPlayerNow.PlayerData.job
        if not officerJobNow or not Config.Departments[officerJobNow.name] then
            return 'officer_not_in_department'
        end

        -- PER-PERSON FEATURE CONTROL, RE-CHECKED (same TOCTOU race window
        -- this critical section's own CORRECTION note above already
        -- documents for HasK9Access/department membership -- high command
        -- can grant/revoke a block/grant during the exact same await-laden
        -- window a certification revoke can land in). Ordered here,
        -- alongside those two, as the last synchronous check before the
        -- INSERT.
        if not IsHandlerPartnershipPermittedForCitizenId(k9Citizenid)
            or not IsHandlerPartnershipPermittedForCitizenId(officerCitizenid) then
            return 'not_granted'
        end

        -- established_by = the INITIATOR's own citizenid (whoever's client
        -- sent requestPartnerUp), never the accepter's -- see this file's
        -- header "SCHEMA-TO-CODE MAPPING" for why.
        local initiatorCitizenid = (fromServerId == k9Src) and k9Citizenid or officerCitizenid

        local insertOk, insertResultOrErr = pcall(K9Store.Partner_Insert, k9Citizenid, officerCitizenid, initiatorCitizenid)

        if not insertOk then
            if IsDuplicateKeyError(insertResultOrErr) then
                -- Another request won a check-then-act race between the
                -- pre-check above and this INSERT (the DB-level backstop,
                -- one of the two UNIQUE KEYs) -- treat identically to the
                -- normal "already partnered" rejection.
                RefreshPartnershipCache(k9Citizenid)
                RefreshPartnershipCache(officerCitizenid)
                return 'already_partnered'
            end

            print(('[qbx_k9unit] Partnership establish INSERT failed for k9=%s handler=%s: %s'):format(k9Citizenid, officerCitizenid, tostring(insertResultOrErr)))
            return 'insert_failed'
        end

        -- ANTI-FARM GUARD EXTENSION -- see this file's own "ANTI-FARM
        -- GUARD EXTENSION" header comment above for the full "why"
        -- writeup. If this
        -- EXACT (k9, handler) pair has previously earned any
        -- partnership-tenure milestone tier (on a NOW-ENDED row -- this is
        -- always a BRAND NEW row, id `insertResultOrErr`, whose own
        -- tenure_bonus_tier_granted column just defaulted to 0), seed it
        -- immediately to that same floor via the SAME optimistic-CAS
        -- primitive server/tenure.lua's own tick uses to write this
        -- column -- extending that existing guard across a reform, not
        -- replacing it with a separate mechanism.
        --
        -- EVERY READ/WRITE'S RETURN IS CHECKED: `readOk` distinguishes a
        -- thrown error reading the durable pair-progress table
        -- (`K9Store.PairProgress_GetHighestTenureTier`, migration 0018)
        -- from a clean call; `seedOk` distinguishes a thrown error from a
        -- clean call on the seed-CAS write; `seedAffectedRows`
        -- distinguishes the CAS actually applying from a lost race / a
        -- schema not yet migrated (0 or nil). No failure path aborts,
        -- retries, or blocks establishment -- a brand-new partnership
        -- succeeding is already the correct, independent outcome; failing
        -- to read or seed only costs this specific anti-farm improvement
        -- for this one instance (fail SAFE, never fail OPEN toward an
        -- extra grant -- the row's own column simply stays at its true
        -- default, 0, exactly like today's shipped behaviour), so every
        -- failure here is logged and treated as non-fatal.
        local readOk, seedTierOrErr = pcall(K9Store.PairProgress_GetHighestTenureTier, k9Citizenid, officerCitizenid)
        if not readOk then
            print(('[qbx_k9unit] partnership: tenure anti-farm pair-progress read threw for new partnership id=%s (k9=%s handler=%s): %s'):format(tostring(insertResultOrErr), k9Citizenid, officerCitizenid, tostring(seedTierOrErr)))
        else
            local seedTier = tonumber(seedTierOrErr)
            if seedTier and seedTier > 0 then
                local seedOk, seedAffectedRows = pcall(K9Store.Partner_SetTenureTierCAS, insertResultOrErr, seedTier, 0)
                if not seedOk then
                    print(('[qbx_k9unit] partnership: tenure anti-farm seed CAS threw for new partnership id=%s (k9=%s handler=%s, seed tier=%d): %s'):format(tostring(insertResultOrErr), k9Citizenid, officerCitizenid, seedTier, tostring(seedAffectedRows)))
                elseif not seedAffectedRows or seedAffectedRows == 0 then
                    print(('[qbx_k9unit] partnership: tenure anti-farm seed CAS did not apply for new partnership id=%s (k9=%s handler=%s, seed tier=%d) -- row may not have its own tenure_bonus_tier_granted column yet (pre-migration schema), or the row changed underneath; new row keeps the default tier 0'):format(tostring(insertResultOrErr), k9Citizenid, officerCitizenid, seedTier))
                end
            end
        end

        RefreshPartnershipCache(k9Citizenid)
        RefreshPartnershipCache(officerCitizenid)
        return 'ok'
    end)

    -- ALWAYS release before branching on the result -- see
    -- PartnershipEstablishMutex's own doc comment for why this must happen
    -- unconditionally, even (especially) when `ranOk` is false.
    PartnershipEstablishMutex.Release(PARTNERSHIP_ESTABLISH_MUTEX_KEY)

    if not ranOk then
        print(('[qbx_k9unit] Partnership establish critical section errored for k9=%s handler=%s: %s'):format(k9Citizenid, officerCitizenid, tostring(outcomeOrErr)))
        NotifyPlayer(fromServerId, locale('partnership.establish_error'), 'error')
        NotifyPlayer(src, locale('partnership.establish_error'), 'error')
        return
    end

    if outcomeOrErr == 'insert_failed' then
        NotifyPlayer(fromServerId, locale('partnership.establish_error'), 'error')
        NotifyPlayer(src, locale('partnership.establish_error'), 'error')
        return
    elseif outcomeOrErr ~= 'ok' then
        -- Covers 'already_partnered' plus the TOCTOU-fix critical-section
        -- outcomes above ('not_certified', 'officer_not_in_department') --
        -- all three are ordinary eligibility rejections that already have a
        -- correct message in PARTNERSHIP_REJECT_MESSAGES, so this handles
        -- any of them generically rather than needing a new named `elseif`
        -- arm (and a second place to keep in sync) every time the critical
        -- section gains one more re-check.
        NotifyPlayer(fromServerId, PartnershipRejectReasonMessage(outcomeOrErr), 'error')
        NotifyPlayer(src, PartnershipRejectReasonMessage(outcomeOrErr), 'error')
        return
    end

    -- outcomeOrErr == 'ok' -- both parties are online by construction here
    -- (the consent handshake requires it), unlike DoBreakPartnership below,
    -- which must tolerate either side being offline.
    TriggerClientEvent('qbx_k9unit:client:partnershipEstablished', k9Src, officerSrc, true)  -- isK9 = true
    TriggerClientEvent('qbx_k9unit:client:partnershipEstablished', officerSrc, k9Src, false) -- isK9 = false

    -- Outbound integration event (server/exports.lua's EVENT CONTRACT §3) --
    -- fired only once `outcomeOrErr == 'ok'`, i.e. strictly after the INSERT
    -- above committed AND RefreshPartnershipCache already ran, mirroring the
    -- two TriggerClientEvent calls directly above. Not gated on
    -- Config.Features.HandlerPartnership: this branch is only reachable at
    -- all if CheckPartnershipEligibility (and the re-check inside the mutex
    -- above) already confirmed the flag was on, so there is no path here
    -- with the feature disabled to additionally gate against.
    FireOutboundEvent('qbx_k9unit:events:partnershipEstablished', k9Citizenid, officerCitizenid)
end)

--- Internal teardown core, keyed by CITIZENID (not source) so it works
--- identically whether `citizenid` is currently online or not -- see this
--- file's header "OFFLINE-CAPABLE BY DESIGN" section for why this is a
--- required divergence from server/main.lua's source-keyed
--- `doDetachLeash`, not a style choice. Shared by the player-initiated
--- breakPartnership event below and by ForceBreakPartnershipForCitizenId
--- (server-triggered, e.g. cert revocation) so there is exactly one place
--- that mutates a partnership row on teardown.
--- @param citizenid string -- either party's citizenid; the OTHER side is resolved from the row itself
--- @param endedByValue string -- either `citizenid` itself (self-initiated) or a 'system:<reason>' sentinel (automatic teardown)
--- @param broadcastReason string -- sent to whichever party/parties are online via partnershipEnded
--- @return boolean ended -- false if `citizenid` wasn't actively partnered (no-op, not an error)
local function DoBreakPartnership(citizenid, endedByValue, broadcastReason)
    -- Wrapped in its own pcall purely to log which specific query failed
    -- (mirrors RefreshPartnershipCache's identical query above) before
    -- propagating -- both of this function's own call sites (the
    -- breakPartnership event and ForceBreakPartnershipForCitizenId below)
    -- already wrap this entire function in their own pcall and degrade
    -- sensibly on a thrown error. Re-raising here (rather than swallowing)
    -- is correct: nothing has been written yet at this point, so there is
    -- no state to reconcile -- the caller-level pcall already knows how to
    -- report "the break failed" to whichever audience it has.
    local selectOk, rowOrErr = pcall(K9Store.Partner_GetActiveRowByParty, citizenid)
    if not selectOk then
        print(('[qbx_k9unit] DoBreakPartnership SELECT failed for %s: %s'):format(citizenid, tostring(rowOrErr)))
        error(rowOrErr, 0)
    end

    local row = rowOrErr
    if not row then return false end -- no-op: this citizenid isn't currently partnered

    -- ANTI-FARM GUARD EXTENSION -- see this file's own "ANTI-FARM GUARD
    -- EXTENSION" header comment above for the full "why" writeup. Captured
    -- HERE, before the UPDATE below flips `active` to 0, since
    -- Partner_GetTenureRow (called inside
    -- CaptureTenureSeedForPair) requires the row to still be active=1 to
    -- find it at all. This is the SINGLE shared teardown core for every
    -- break path this resource has (self-initiated breakPartnership below
    -- AND ForceBreakPartnershipForCitizenId, itself called from
    -- server/certifications/'s decertification AND department-change/
    -- job-switch call sites) -- one call site here covers all of them.
    -- Best-effort, never throws, never aborts/delays this break (see that
    -- function's own doc comment) -- this is a capture for the NEXT
    -- establishment of this exact pair, not a condition of THIS one
    -- completing.
    CaptureTenureSeedForPair(row.k9_citizenid, row.handler_citizenid)

    local partnerCitizenid = (row.k9_citizenid == citizenid) and row.handler_citizenid or row.k9_citizenid

    -- STATE-CONSISTENCY DESIGN NOTE (a partnership break that
    -- "half-succeeds", the SELECT above having worked and this UPDATE then
    -- throwing, is a real, distinct risk from mere error *propagation*):
    -- the SELECT is read-only and can never leave partial state behind on
    -- its own -- this UPDATE is the ONLY write in this function, and a
    -- single UPDATE statement is already atomic at the storage-engine
    -- level (InnoDB commits it whole or not at all) regardless of whether
    -- it is additionally wrapped in an explicit `MySQL.transaction`.
    -- Wrapping this SELECT+UPDATE pair in a SQL transaction would add NO
    -- additional atomicity here -- there is no SECOND write that needs to
    -- commit-or-roll-back together with this one, so a transaction is
    -- deliberately NOT used. What a transaction genuinely could NOT fix
    -- either -- because nothing running on this side of the connection
    -- can, for the same reason a distributed commit-ack is fundamentally
    -- ambiguous -- is the narrow case where this UPDATE actually commits
    -- on the DB server but the success acknowledgment is lost before this
    -- callback ever sees it (e.g. a connection drop in exactly that
    -- window): the identical ambiguity would exist at a transaction's own
    -- COMMIT step. Rather than guessing "assume success" or "assume
    -- failure" for that window, this reconciles with an independent, fresh
    -- read of the SAME row below and acts on whatever the DB actually
    -- says, so neither the in-memory cache nor any notification sent can
    -- ever diverge from the persisted row, no matter which way the
    -- ambiguous case actually landed.
    local updateOk, affectedRowsOrErr = pcall(K9Store.Partner_EndById, row.id, endedByValue)

    if not updateOk then
        print(('[qbx_k9unit] DoBreakPartnership UPDATE failed for partnership id=%s (citizenid=%s): %s -- reconciling against a fresh read before reporting an outcome'):format(tostring(row.id), citizenid, tostring(affectedRowsOrErr)))

        -- Independent, directly-pcall'd re-read -- deliberately NOT via
        -- RefreshPartnershipCache's own return value: that function's
        -- fail-closed contract collapses "confirmed not partnered" and
        -- "the read itself failed" into the same nil, which is correct
        -- for the ACCESS-checking callers it normally serves but wrong
        -- here, where "confirmed ended" and "unknown" must be told apart
        -- before deciding whether to report success.
        local reconcileOk, activeValueOrErr = pcall(K9Store.Partner_GetActiveFlagById, row.id)

        if reconcileOk and activeValueOrErr == 0 then
            -- Confirmed against the DB itself: the UPDATE actually
            -- committed despite this call's own client-side error.
            -- Refresh both caches to match the now-confirmed truth and
            -- report/broadcast the success that genuinely happened,
            -- rather than a failure that would otherwise leave every
            -- consumer of this cache believing an already-ended
            -- partnership is still active.
            RefreshPartnershipCache(citizenid)
            RefreshPartnershipCache(partnerCitizenid)
            TellCitizenIdPartnershipEnded(citizenid, broadcastReason)
            TellCitizenIdPartnershipEnded(partnerCitizenid, broadcastReason)
            FireOutboundEvent('qbx_k9unit:events:partnershipEnded', row.k9_citizenid, row.handler_citizenid, broadcastReason)
            return true
        end

        if not reconcileOk then
            print(('[qbx_k9unit] DoBreakPartnership reconciliation read ALSO failed for partnership id=%s -- true outcome unknown, manual DB check required: %s'):format(tostring(row.id), tostring(activeValueOrErr)))
        end

        -- Either confirmed still active (the UPDATE genuinely never
        -- committed -- a consistent, honest failure, nothing to
        -- reconcile) or the reconciliation read itself failed (true
        -- outcome unknown) -- in BOTH cases, fail closed: never claim a
        -- break succeeded that this code cannot confirm against the DB,
        -- and leave both caches untouched rather than guess. Re-raise so
        -- this function's own call sites report failure exactly like any
        -- other query error here.
        error(affectedRowsOrErr, 0)
    end

    local affectedRows = affectedRowsOrErr

    -- Refresh BOTH citizenids' cache unconditionally, regardless of whether
    -- this specific call actually flipped the row: either this call won a
    -- race against a concurrent teardown of the SAME row (e.g. both
    -- parties call breakPartnership in the same instant, or a manual break
    -- races an automatic cert-revoke teardown) and the cache was stale, or
    -- it lost that race and some OTHER call already refreshed it -- either
    -- way, re-reading here is correct and, in the loss case, a harmless
    -- redundant read.
    RefreshPartnershipCache(row.k9_citizenid)
    RefreshPartnershipCache(row.handler_citizenid)

    if not affectedRows or affectedRows == 0 then
        return false -- lost the race above -- someone else already ended this exact row
    end

    TellCitizenIdPartnershipEnded(citizenid, broadcastReason)
    TellCitizenIdPartnershipEnded(partnerCitizenid, broadcastReason)

    -- Outbound integration event (server/exports.lua's EVENT CONTRACT §4) --
    -- fired only once `affectedRows` confirmed above that THIS call actually
    -- won the race and flipped the row (the early `return false` paths above
    -- never reach here). This one function backs both the player-initiated
    -- breakPartnership event and ForceBreakPartnershipForCitizenId (the
    -- automatic teardown on cert revoke/department change), so wiring it
    -- here covers both paths in one place, exactly as documented. Not gated
    -- on Config.Features.HandlerPartnership: an existing, already-persisted
    -- partnership row must be reported as torn down regardless of the
    -- flag's CURRENT value (mirrors server/exports.lua's own reasoning for
    -- GetActivePartnerCitizenId/IsActivePartnerOf -- a real DB row does not
    -- stop being real just because an operator toggled the flag off after
    -- it was created).
    FireOutboundEvent('qbx_k9unit:events:partnershipEnded', row.k9_citizenid, row.handler_citizenid, broadcastReason)

    return true
end

--- Either party ends the partnership unilaterally, no consent required --
--- mirrors server/main.lua's detachLeash exactly (DEVELOPER_REFERENCE.md §12.0
--- item 7 point 3's "no unbounded trap" guarantee, now applied to a
--- persistent relationship). No-op if the caller isn't currently
--- partnered with anyone.
RegisterNetEvent('qbx_k9unit:server:breakPartnership', function()
    local src = source
    local Player = exports.qbx_core:GetPlayer(src)
    local citizenid = Player and Player.PlayerData and Player.PlayerData.citizenid
    if not citizenid then return end

    local ok, brokeOrErr = pcall(DoBreakPartnership, citizenid, citizenid, 'broken')
    if not ok then
        print(('[qbx_k9unit] breakPartnership failed for %s: %s'):format(citizenid, tostring(brokeOrErr)))
        NotifyPlayer(src, locale('partnership.break_error'), 'error')
        return
    end
    if not brokeOrErr then
        NotifyPlayer(src, locale('partnership.not_partnered_with_anyone'), 'inform')
    end
    -- On success, TriggerClientEvent already fired inside DoBreakPartnership
    -- (via TellCitizenIdPartnershipEnded) -- no separate NotifyPlayer here,
    -- mirroring leash's own "state-change broadcasts show their own
    -- notification client-side, only error/ack paths use server-side
    -- NotifyPlayer directly" convention (compare doDetachLeash, which never
    -- calls NotifyPlayer itself either).
end)

--- Server-authoritative "am I currently partnered, and with whom" read for
--- the CALLING player -- modeled directly on server/certifications/'s
--- `qbx_k9unit:server:hasK9Access` callback (this resource's own
--- established precedent for a client-triggerable, server-authoritative
--- status read). Added specifically to close the gap client/partnership.lua's
--- own header discloses ("KNOWN CACHE-STALENESS GAP"): that file's local
--- `PartnershipState` is populated ONLY by the `partnershipEstablished`
--- client event, which nothing in this file's contract re-sends to a
--- client that reconnects (or whose own resource restarts) while already
--- genuinely partnered per this table -- a future consumer that decides
--- between "Partner Up" and "Break Partnership" purely from that local
--- cache could therefore offer the wrong one at exactly the moment it
--- matters. Calls RefreshPartnershipCache (a fresh DB read, same
--- fail-closed discipline as every other caller of it in this file) rather
--- than reading the `Partnerships` cache directly, so a caller of this
--- callback never has to separately reason about whether the SERVER's own
--- cache might itself be stale.
--- @param source number (implicit, ox_lib callback convention)
--- @return boolean isPartnered
--- @return number? partnerServerId -- nil if not partnered, OR partnered but the partner isn't currently online
--- @return boolean? isK9 -- true if the CALLER is the K9-role party; nil if not partnered
lib.callback.register('qbx_k9unit:server:getPartnershipState', function(source)
    local Player = exports.qbx_core:GetPlayer(source)
    local citizenid = Player and Player.PlayerData and Player.PlayerData.citizenid
    if not citizenid then return false, nil, nil end

    local partnerCitizenid, isK9 = RefreshPartnershipCache(citizenid)
    if not partnerCitizenid then return false, nil, nil end

    local partnerPlayer = exports.qbx_core:GetPlayerByCitizenId(partnerCitizenid)
    local partnerServerId = partnerPlayer and partnerPlayer.PlayerData and partnerPlayer.PlayerData.source
    return true, partnerServerId, isK9
end)

--- Resource-global (no `local`) -- exposed for server/certifications/ to
--- call alongside every existing ForceDetachLeashForSource/
--- ForceDetachOfficerLeashForSource call site (K9-role cert revocation,
--- either party's department change) -- DEVELOPER_REFERENCE.md §12.0 item 7 point
--- 3's exact instruction. CITIZENID-keyed, not source-keyed -- works
--- whether `citizenid` is online or offline right now (see this file's
--- header "OFFLINE-CAPABLE BY DESIGN" section for why this is required,
--- not optional, for the RevokeCertificationOffline call site
--- specifically). No-op (returns false) if `citizenid` has no active
--- partnership, in EITHER role -- unlike leash's role-gated
--- ForceDetachLeashForSource/ForceDetachOfficerLeashForSource pair, a
--- SINGLE function covers both roles here, since certification revocation
--- and department loss both end a partnership regardless of which side
--- `citizenid` happens to be on (a K9-role citizenid loses HasK9Access on
--- revoke; a handler/officer-role citizenid loses department membership on
--- the same triggers -- either one invalidates the partnership).
--- @param citizenid string
--- @param reason string -- plain reason (e.g. 'certification_revoked', 'department_changed') -- this function prefixes it with 'system:' for the DB's ended_by column, and passes it unprefixed to partnershipEnded
--- @param actorCitizenid string|nil -- WHO ended it, when a person did. See below.
--- @return boolean ended
---
--- `actorCitizenid` IS FOR A PERSON'S DECISION, NOT A SYSTEM'S. When high
--- command force-ends a partnership from the tablet, that is an officer's
--- choice about two other players, and the partnership history must say
--- which officer made it. Before this parameter existed every such row was
--- written as `system:admin_forced_from_tablet` -- so the history showed
--- "ended by the system" and there was no way to tell who had done it.
---
--- When present it is written as ended_by verbatim -- the SAME shape a
--- player-initiated break already writes (the ending party's own
--- citizenid), so server/tablet.lua's BuildPartnershipRowsForCitizenId
--- resolves it to a display name with no change on the reading side.
---
--- Omitted by every automatic caller (a revoked certification, a
--- department change), which keep the `system:<reason>` sentinel: nobody
--- chose those, so naming a person would be false.
function ForceBreakPartnershipForCitizenId(citizenid, reason, actorCitizenid)
    if type(citizenid) ~= 'string' or citizenid == '' then return false end

    local endedBy = (type(actorCitizenid) == 'string' and actorCitizenid ~= '')
        and actorCitizenid
        or ('system:%s'):format(reason or 'unknown')
    local ok, result = pcall(DoBreakPartnership, citizenid, endedBy, reason or 'ended')
    if not ok then
        print(('[qbx_k9unit] ForceBreakPartnershipForCitizenId failed for %s: %s'):format(citizenid, tostring(result)))
        return false
    end
    return result
end

--- Cleans up ephemeral request state on disconnect, and drops this
--- citizenid's in-memory cache entry -- does NOT tear down an actual
--- partnership. See this file's header "OFFLINE-CAPABLE BY DESIGN" section
--- for the full reasoning on why this handler's shape is a deliberate,
--- disclosed divergence from server/main.lua's LeashPairs cleanup
--- (restated briefly inline below since this is the load-bearing part of
--- this file most likely to be "fixed" back toward leash's shape by a
--- future editor skimming server/main.lua's own playerDropped handler
--- without reading this file's header first).
AddEventHandler('playerDropped', function(_reason)
    local src = source

    -- Target-side: a request aimed AT the disconnecting player.
    PendingPartnershipRequests[src] = nil

    -- Initiator-side: scan for a still-open request the disconnecting
    -- player themselves sent to someone else -- same reasoning as
    -- server/main.lua's identical scan for PendingLeashRequests (FiveM
    -- recycles numeric server ids, so an unscanned stale `.from` entry
    -- could otherwise resolve to a different, unrelated player who
    -- happens to reconnect with the same id before this entry's TTL
    -- expires). Table is small and short-lived (Config.Partnership.RequestTTLMs),
    -- so a linear scan here is not a performance concern.
    for targetSrc, pending in pairs(PendingPartnershipRequests) do
        if pending.from == src then
            PendingPartnershipRequests[targetSrc] = nil
        end
    end

    -- DELIBERATELY DOES NOT CALL DoBreakPartnership / ForceBreakPartnershipForCitizenId
    -- HERE. A K9 partnership is explicitly designed to SURVIVE a
    -- disconnect/reconnect -- that is the entire reason it is DB-backed
    -- rather than ephemeral (DEVELOPER_REFERENCE.md §12.0 item 7 point 2:
    -- "session-spanning, plausibly shift-spanning"). Only this citizenid's
    -- in-memory CACHE entry is dropped below -- mirroring
    -- server/certifications/'s own unbounded-growth fix for its
    -- `Certifications` table (see that file's own playerDropped handler
    -- and comment) -- harmless, since it's cheaply rebuilt from a fresh DB
    -- query on this citizenid's next PlayerLoaded, and the underlying
    -- persisted row plus the still-online partner's own cache entry are
    -- left completely untouched.
    local Player = exports.qbx_core:GetPlayer(src)
    local citizenid = Player and Player.PlayerData and Player.PlayerData.citizenid
    if citizenid then
        Partnerships[citizenid] = nil
    end
end)

-- STRUCTURAL GAP backfill, mirroring server/main.lua's own identical-purpose
-- onResourceStart loop for RefreshCertificationCache: server/certifications/'s
-- (and this file's own) cache populates per-player on a player-loaded
-- event, which only fires for players who connect/load AFTER that handler
-- is registered. On a `/restart qbx_k9unit` (or a crash-restart) while
-- players are already online, nobody re-fires that event for them, so
-- their partnership cache entry would sit empty (= "no active partnership
-- known") until their next reconnect -- a genuinely-partnered pair could
-- silently be treated as unpartnered by every reader of this cache for the
-- remainder of their session.
-- GetPlayers() returns connected player ids as strings; tonumber'd
-- below, same pattern as server/main.lua's own loop.
--
-- CONFIDENCE NOTE: uses 'QBCore:Server:PlayerLoaded' below with the SAME
-- MEDIUM-HIGH confidence server/certifications/'s own identical-purpose
-- hook already carries (see that file's own CONFIDENCE NOTE near its
-- bottom) -- not re-derived independently here, since it's the exact same
-- event, already relied on elsewhere in this resource.
AddEventHandler('onResourceStart', function(resourceName)
    if GetCurrentResourceName() ~= resourceName then return end

    -- PERFORMANCE FIX: a partnership row can only ever be CREATED while
    -- Config.Features.HandlerPartnership is true (CheckPartnershipEligibility
    -- above is the only creation path and gates on this same flag), so on a
    -- server where the flag has never been enabled this loop was doing a
    -- real MySQL.single.await per connected player (RefreshPartnershipCache)
    -- to warm a cache that no code path can ever populate with a real row
    -- and that nothing can be online to consume anyway.
    -- Gated here the same way the creation path already is.
    --
    -- KNOWN TRADE-OFF, disclosed rather than silently accepted: this cache
    -- also backs server/exports.lua's GetActivePartnerCitizenId/
    -- IsActivePartnerOf, which are deliberately NOT gated on this flag (see
    -- that file's own reasoning: a partnership row created while the flag
    -- was on remains real, queryable state even after the flag is later
    -- flipped off). If an operator enables this flag, lets a partnership
    -- form, then disables it again WITHOUT tearing the partnership down,
    -- and restarts this resource while the still-partnered players remain
    -- online, this gate reintroduces this loop's own original "sits empty
    -- until next reconnect" gap for that narrow case. Accepted here because
    -- forming a row at all already required the flag to have been
    -- deliberately turned on once; the common "flag has always been false"
    -- default-install case this fix targets cannot exhibit it.
    if not Config.Features.HandlerPartnership then return end

    -- WAITS FOR THE SCHEMA-COLLISION PROBE TO SETTLE FIRST (boot-order-race
    -- audit, this pass -- same fix already shipped for
    -- server/certtiers.lua/server/permissionkeycatalog.lua/server/xptiers.lua/
    -- server/k9profiles.lua, simply missed here when it landed for those
    -- four -- see server/datastore.lua's own "BOOT-ORDER SETTLEMENT" header
    -- for the exact race this closes, and K9Store.WaitForSchemaCheckToSettle's
    -- own doc comment for the full contract). Without this,
    -- RefreshPartnershipCache below (K9Store.Partner_GetActiveRowByParty --
    -- a narrower SELECT than the columns server/datastore.lua's own
    -- EXPECTED_TABLE_COLUMNS checks k9_partnerships against) could run
    -- against a foreign `k9_partnerships` the full probe would correctly
    -- reject as a collision, during the one window before that probe's own
    -- yielding query has returned -- merging a stranger's rows straight
    -- into a live partnership cache that other features read as truth.
    -- On a `false` return (the probe genuinely had not settled within the
    -- wait budget), this loop skips every citizenid below rather than trust
    -- an unconfirmed database state -- their cache entry simply stays
    -- unset for this backfill pass, identical to what already happens
    -- today whenever RefreshPartnershipCache's own read fails or finds
    -- nothing -- the next PlayerLoaded, or a restart once the check has had
    -- time to finish, re-syncs it as normal.
    if not K9Store.WaitForSchemaCheckToSettle() then
        print('[qbx_k9unit] partnership: the schema-collision check had not finished within its wait budget -- skipping this restart\'s partnership-cache backfill for every already-connected officer (no database read attempted, exactly like Config.Database.enabled = false) rather than trust a database state that is not yet confirmed safe. The next PlayerLoaded (or a restart once the check has had time to finish) re-syncs it as normal.')
        return
    end

    for _, playerId in ipairs(GetPlayers()) do
        local src = tonumber(playerId)
        if src then
            local Player = exports.qbx_core:GetPlayer(src)
            if Player and Player.PlayerData and Player.PlayerData.citizenid then
                RefreshPartnershipCache(Player.PlayerData.citizenid)
            end
        end
    end
end)

AddEventHandler('QBCore:Server:PlayerLoaded', function(Player)
    if not Player or not Player.PlayerData then return end
    local citizenid = Player.PlayerData.citizenid
    if citizenid then
        RefreshPartnershipCache(citizenid)
    end
end)
