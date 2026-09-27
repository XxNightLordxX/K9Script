--[[
    qbx_k9unit/client/partnership.lua

    Phase 3 (HandlerPartnership registry, DEVELOPER_REFERENCE.md §12.0 item 7 /
    §12.3's file-plan entry) — the client half of server/partnership.lua
    (read in full before this file was written; that file's header is the
    authoritative contract for everything below). This file provides the
    Partner Up consent prompt, an ox_target option, and
    IsPartnered()/GetPartnerServerId()/RefreshPartnershipStateFromServer()
    as resource-globals; client/radial.lua's own "Partner Up"/"Break
    Partnership" item calls them directly (see "KNOWN CACHE-STALENESS GAP,
    AND ITS FIX" below for RefreshPartnershipStateFromServer()'s own
    reasoning).

    This mirrors client/movement.lua's leash subsystem shape wherever the
    two mechanics are actually alike (the consent handshake), and
    deliberately diverges where server/partnership.lua's own header says a
    partnership must diverge from leash (its "OFFLINE-CAPABLE BY DESIGN" /
    "no unbounded trap" sections) — see "WHY BreakPartnership() DOES NOT
    MIRROR DetachLeash()'S LOCAL PRE-CHECK" below for the one place this
    file's shape is NOT a straight copy of client/movement.lua's.

    ======================================================================
    EVENT/CALLBACK CONTRACT — verified against server/partnership.lua's own
    header (its "EVENT/CALLBACK CONTRACT" section), not re-derived from
    DEVELOPER_REFERENCE.md prose alone:

    Server events (client->server), THIS FILE triggers:
    - 'qbx_k9unit:server:requestPartnerUp' (targetServerId: number)
    - 'qbx_k9unit:server:respondPartnerUp' (fromServerId: number, accepted: boolean)
    - 'qbx_k9unit:server:breakPartnership' () -- no arguments; server
      resolves the caller's own citizenid from `source`.

    Client events (server->client), THIS FILE registers:
    - 'qbx_k9unit:client:partnerUpRequest' (fromServerId: number)
      Shown as an accept/decline prompt -- mirrors client/movement.lua's
      leashAttachRequest handler almost line-for-line.
    - 'qbx_k9unit:client:partnershipEstablished' (partnerServerId: number, isK9: boolean)
      Sent individually to EACH party with their OWN role flag (per
      server/partnership.lua's header: "each with their OWN role flag,
      never assume both clients receive the same boolean").
    - 'qbx_k9unit:client:partnershipEnded' (reason: string)
      Sent to whichever party/parties are CURRENTLY ONLINE -- unlike
      leash's leashDetached, server/partnership.lua's header is explicit
      that a partnership can outlive a disconnect, so THIS side must not
      assume the other party is online, and must not assume this is the
      only event that will ever inform this client its partnership ended
      (see the cache-staleness note below).
    ======================================================================

    FILE-TO-FILE CONTRACT:
    - THIS FILE exposes five resource-global (no `local`) functions:
        RequestPartnerUp(targetServerId: number)
            Step 1 of the consent handshake, self-initiated side.
            Re-checks eligibility itself (never trusts the caller already
            did), then only ever sends a request -- never establishes
            anything locally. NOT a straight CanShowK9UI() gate like
            RequestLeashAttach() -- see this function's own doc comment
            ("BUG FIX") for why an unconditional CanShowK9UI() check would
            silently deny every officer-initiated request.
        BreakPartnership()
            Ends the current partnership, zero consent, always available.
            Exposed for client/radial.lua's context-sensitive "Partner
            Up"/"Break Partnership" entry, the same dual-mode shape that
            file's existing Attach/Detach Leash item already uses (see
            that file's own header for the precedent) -- client/radial.lua
            calls this behind a `type(BreakPartnership) == 'function'`
            guard, this codebase's established soft-dependency convention,
            exactly like every other conditionally-defined resource-global
            here (e.g. AwardXP/GetXPTier).
        IsPartnered() -> boolean
        GetPartnerServerId() -> number?
            Read-only, SYNCHRONOUS (never yields) accessors over this
            file's local `PartnershipState` cache, for that same radial
            entry to decide which of the two above to call. See
            "KNOWN CACHE-STALENESS GAP, AND ITS FIX" below for exactly when
            these two are safe to read directly and when a caller MUST call
            RefreshPartnershipStateFromServer() first instead.
        RefreshPartnershipStateFromServer() -> isPartnered: boolean, partnerServerId: number?
            YIELDS (awaits an ox_lib callback round-trip to
            server/partnership.lua's `qbx_k9unit:server:getPartnershipState`)
            to re-sync `PartnershipState` from server-authoritative truth,
            then returns the now-fresh IsPartnered()/GetPartnerServerId()
            values. This is the fix for "KNOWN CACHE-STALENESS GAP, AND ITS
            FIX" below -- call this FIRST, at any decision point where a stale answer
            from the two synchronous accessors above could strand a player
            (e.g. a radial item deciding between "Partner Up" and
            "Break Partnership" -- see below).
    - THIS FILE calls client/main.lua's CanShowK9UI()/DenyK9UIAccess() for
      the REQUEST side only (see "TERMINATION MUST NEVER BE GATED" below
      for why BreakPartnership() itself does not call either).
    - THIS FILE is the ONLY client file that registers a handler for the
      three partnership client events above, triggers the three
      partnership server events above, or calls the
      'qbx_k9unit:server:getPartnershipState' callback above (always
      through RefreshPartnershipStateFromServer(), never directly) --
      server/partnership.lua's own header states this explicitly ("keep
      the full subsystem confined to one client/one server file",
      mirroring server/main.lua's own leash convention). Do not let a
      second partnership code path grow in
      client/radial.lua or elsewhere.
    ======================================================================

    TOP-OF-FILE FEATURE GATE -- WHY THE WHOLE FILE, NOT A PER-HANDLER CHECK:
    `if not Config.Features.HandlerPartnership then return end` immediately
    below means this file registers NOTHING at all (no ox_target option, no
    RegisterNetEvent, none of the five resource-globals above are even
    defined) when the flag is false, its default. This is deliberately
    STRONGER than the per-handler gating this resource uses elsewhere (e.g.
    server/kennel.lua's `if not Config.Features.DeployableKennel then return
    end` INSIDE each handler, not at that file's top) -- appropriate here
    specifically because this ENTIRE file is one single feature area with
    no other responsibility to preserve if disabled (unlike
    client/movement.lua, which owns several independently-flagged
    mechanics in one file and could never be gated this bluntly without
    also killing Sit/camera/door-interaction/certify-ox_target along with
    leash). A file-wide top gate is the concrete fix for the exact gap
    found in client/combat.lua (handlers registered unconditionally
    regardless of that file's own feature flags) -- applied here from the
    start rather than retrofitted.
    Server-side safety net this relies on: server/partnership.lua's own
    CheckPartnershipEligibility rejects with 'feature_disabled' whenever
    this flag is false, so no partnership can ever be ESTABLISHED while
    disabled -- this file being fully inert while disabled therefore never
    strands an established pairing with no way to end it. The one
    disclosed edge case that statement does NOT cover (a partnership
    established while the flag was true, then the flag flipped false on a
    later restart) is covered in "KNOWN CACHE-STALENESS GAP" below.
    ======================================================================

    TERMINATION MUST NEVER BE GATED -- BreakPartnership() below calls
    NEITHER CanShowK9UI() NOR DenyK9UIAccess(), and does NOT pre-check
    IsPartnered() before sending. This mirrors client/movement.lua's
    DetachLeash() in spirit (no access-gate on the way out, matching
    DEVELOPER_REFERENCE.md §12.0 item 7 point 3's "no unbounded trap" guarantee,
    now applied to a persistent relationship) but goes one step further
    than DetachLeash() by also skipping the LOCAL state pre-check --
    see the next section for exactly why that extra step is required here
    specifically, not optional style.

    WHY BreakPartnership() DOES NOT MIRROR DetachLeash()'S LOCAL PRE-CHECK
    (`if not IsLeashed() then return end`): DetachLeash() can safely
    early-return locally because `leashState` can never be stale --
    a leash pairing is ephemeral, session-scoped state
    (server/main.lua's own framing) that cannot survive this client's own
    resource restart or a reconnect, so `leashState == nil` on this client
    is always an accurate reflection of "not currently leashed."
    `PartnershipState` below has NO such guarantee: server/partnership.lua
    is explicitly DB-backed so a partnership SURVIVES a disconnect/
    reconnect and a resource restart (its own header: "session-spanning,
    plausibly shift-spanning"), but nothing in server/partnership.lua's
    current contract re-sends 'qbx_k9unit:client:partnershipEstablished'
    (or any other event) to a client that reconnects, or whose OWN
    resource restarts, while already genuinely partnered per the DB --
    RefreshPartnershipCache (server-side) silently repopulates the SERVER's
    own cache on PlayerLoaded/onResourceStart but never tells the client
    anything. That means `PartnershipState` can legitimately be `nil` on
    this client immediately after a reconnect/restart EVEN THOUGH the
    player is still actively partnered server-side. If BreakPartnership()
    pre-checked `IsPartnered()` the way DetachLeash() checks `IsLeashed()`,
    a player in exactly that state could never break their own real,
    active, DB-persisted partnership at all -- precisely the "unbounded
    trap" DEVELOPER_REFERENCE.md §12.0 item 7 point 3 forbids. Sending
    'qbx_k9unit:server:breakPartnership' UNCONDITIONALLY instead costs
    nothing: server/partnership.lua's own handler is already a safe no-op
    for a citizenid with no active partnership (`DoBreakPartnership`
    returns false, and the caller is told "You are not currently partnered
    with anyone." via NotifyPlayer) -- the server, not this file's cache,
    is the only party that can actually answer "am I partnered right now,"
    exactly this codebase's own "client is never the source of truth"
    principle applied to the one place a stale local cache could otherwise
    strand a player.

    KNOWN CACHE-STALENESS GAP, AND ITS FIX (previously disclosed as an open
    gap this file could not close on its own; NOW CLOSED -- see
    RefreshPartnershipStateFromServer() above): the two synchronous
    accessors, IsPartnered()/GetPartnerServerId(), CAN under-report (return
    "not partnered" / nil for a player who genuinely IS still partnered per
    the DB) immediately after this client's own reconnect or resource
    restart, for the exact reason the paragraph above this one explains:
    nothing in server/partnership.lua's contract re-sends
    'qbx_k9unit:client:partnershipEstablished' (or any other event) to a
    reconnecting client's view of an already-established partnership --
    RefreshPartnershipCache (server-side) silently repopulates the
    SERVER's own cache on PlayerLoaded/onResourceStart but never tells the
    client anything on its own. Reading `PartnershipState` directly at that
    moment is therefore still unsafe. What CLOSES this gap for real is
    server/partnership.lua's `qbx_k9unit:server:getPartnershipState`
    lib.callback (added specifically for this, modeled on
    client/main.lua's existing 'qbx_k9unit:server:hasK9Access' callback,
    the established precedent for exactly this "client-triggerable,
    server-authoritative status read" shape) and this file's own
    RefreshPartnershipStateFromServer() wrapper around it. A future
    consumer that needs a genuinely fresh answer (a radial item deciding
    between "Partner Up" and "Break Partnership" is the concrete case this
    was built for -- see below) MUST call
    RefreshPartnershipStateFromServer() and use ITS return values, not
    IsPartnered()/GetPartnerServerId() read cold -- those two remain
    correct only as a synchronous, no-round-trip convenience for callers
    that don't need freshness at that exact instant (e.g. the ox_target
    "Partner Up" predicate below, which is display-only and already
    tolerates the server's own CheckPartnershipEligibility rejecting a
    stale-looking request with a clear notification either way -- see the
    predicate's own comment).

    THE CONCRETE CASE THIS WAS BUILT FOR: a dual-mode radial item that
    picks "Partner Up" vs. "Break Partnership" purely from IsPartnered()
    would, without the fix above, read stale `false` for a player who
    reconnected while genuinely still partnered, offer them "Partner Up",
    and never offer the one control that actually works unconditionally
    (BreakPartnership() -- see "TERMINATION MUST NEVER BE GATED" above).
    That player would hit a server-side 'already_partnered' rejection
    instead of an exit -- exactly the "unbounded trap" DEVELOPER_REFERENCE.md
    §12.0 item 7 point 3 forbids, reintroduced through a stale read rather
    than a missing control. Calling RefreshPartnershipStateFromServer()
    before that decision is what avoids it.

    PREVIOUSLY-DISCLOSED FINDING, NOW CORRECTED (this project has twice
    shipped a header describing a control that did not actually exist --
    `accessScope`'s owner-only mode was one instance; this paragraph, as
    originally written, was the second, and both were only caught by
    someone verifying the claim against the actual code rather than
    trusting the header): this section previously stated that
    server/partnership.lua's header claim -- "server/certifications/
    calls `ForceBreakPartnershipForCitizenId` from three places
    (RevokeCertification's online branch, RevokeCertificationOffline, and
    the QBCore:Server:OnJobUpdate handler's TWO branches)" -- was false,
    because a grep of server/certifications/ at the time this file was
    first written found ZERO call sites. That was accurate when written.
    It is NOT accurate anymore: commit 94fbc4e added four real call sites
    in server/certifications/ (RevokeCertification's online branch;
    RevokeCertificationOffline; and the QBCore:Server:OnJobUpdate handler's
    two branches, department-loss and cert-revoke-due-to-job-change) --
    re-verified directly against that file's current contents, not assumed
    from the header alone. A certification revoke or department change
    NOW DOES automatically tear down an active partnership server-side.
    BreakPartnership() remains unconditionally available regardless (see
    "TERMINATION MUST NEVER BE GATED" above) -- that was never contingent
    on whether the automatic teardown existed, and stays correct either
    way -- but it is no longer the ONLY path off a partnership; it is the
    manual, self-initiated one alongside four automatic ones. A future
    reader should not conclude from any stale copy of this paragraph that
    BreakPartnership() is still the only teardown path -- verify against
    server/certifications/ directly, as this correction did, rather than
    trusting either this file's or that file's header claim on its own.
    ======================================================================
]]


-- SERVER-CALLBACK TIMEOUT (added 2026-08-31, from live testing).
-- Every lib.callback.await in this file previously passed `false` here.
-- Each call is wrapped in a pcall written on the stated assumption that
-- await "THROWS on a timeout" -- but `false` is the timeout argument, and
-- passing it is what disables the timeout. So nothing ever threw: a server
-- callback that does not answer left the caller waiting indefinitely rather
-- than failing cleanly. On the tablet that means a fetch promise that never
-- resolves, which is exactly the "I have to keep clicking Retry on almost
-- everything" the owner reported.
--
-- An explicit number is correct whichever way ox_lib treats `false` (I could
-- not reach its source from this environment to confirm): if false disabled
-- the timeout, this restores it; if false was already ignored, this only
-- makes the value explicit. Ten seconds is far longer than any call here
-- needs -- with Config.Database.enabled false everything is in-memory -- and
-- still bounded, so a wedged callback surfaces as a clear error instead of a
-- hang.
local K9_CALLBACK_TIMEOUT_MS = 10000
if not Config.Features.HandlerPartnership then return end

--- Local-only cached view of the CURRENT partnership, if any. The
--- partnership's existence is server-authoritative
--- (server/partnership.lua's DB-backed registry); this is just this
--- client's own last-known view of it, populated ONLY by the
--- partnershipEstablished handler below (see this file's header "KNOWN
--- CACHE-STALENESS GAP" for why it is not backfilled on reconnect/
--- restart). Not exposed directly -- always go through
--- IsPartnered()/GetPartnerServerId().
--- @type { partnerServerId: number, isK9: boolean }|nil
local PartnershipState = nil

--- @return boolean
function IsPartnered()
    return PartnershipState ~= nil
end

--- @return number?
function GetPartnerServerId()
    return PartnershipState and PartnershipState.partnerServerId or nil
end

--- Re-syncs `PartnershipState` from server-authoritative truth via
--- server/partnership.lua's `qbx_k9unit:server:getPartnershipState`
--- lib.callback -- the fix for this file's header "KNOWN CACHE-STALENESS
--- GAP, AND ITS FIX" (read that section before calling this from anywhere
--- new). YIELDS (an ox_lib callback round-trip) -- unlike
--- IsPartnered()/GetPartnerServerId() above, which stay synchronous,
--- local-only reads for every caller that doesn't need freshness at that
--- exact instant. Deliberately the ONLY call site in this codebase for
--- that callback -- a future radial item should call THIS function, not
--- `lib.callback.await('qbx_k9unit:server:getPartnershipState', ...)`
--- directly, so client/partnership.lua stays the one file that owns every
--- partnership-related client/server round trip (this file's own
--- FILE-TO-FILE CONTRACT above); a second, independent call site in
--- client/radial.lua would be exactly the "second partnership code path"
--- that discipline exists to prevent.
--- @return boolean isPartnered -- the now-fresh value, same as IsPartnered() immediately after this returns
--- @return number? partnerServerId -- the now-fresh value, same as GetPartnerServerId() immediately after this returns
function RefreshPartnershipStateFromServer()
    -- FAIL-CLOSED GUARD (dependency-verification finding): `lib.callback.await`
    -- throws rather than returning nil on a timeout or unregistered-callback
    -- response (confirmed against ox_lib's `imports/callback/client.lua` and
    -- FiveM's `scheduler.lua` `Citizen.Await` directly -- see
    -- client/main.lua's HasK9Access() for the full citation). pcall it and
    -- treat a throw the same as an authoritative "not partnered" response,
    -- rather than leaving a stale PartnershipState in place or letting the
    -- throw escape uncaught.
    local ok, isPartneredNow, partnerServerId, isK9 = pcall(lib.callback.await, 'qbx_k9unit:server:getPartnershipState', K9_CALLBACK_TIMEOUT_MS)
    if not ok then
        isPartneredNow, partnerServerId, isK9 = false, nil, nil
    end
    PartnershipState = isPartneredNow and { partnerServerId = partnerServerId, isK9 = isK9 } or nil
    return IsPartnered(), GetPartnerServerId()
end

--- Step 1 of the consent handshake, self-initiated side. Does NOT
--- establish anything by itself -- see the partnershipEstablished handler
--- below for where the pairing actually activates, after the target
--- accepts.
--- @param targetServerId number
function RequestPartnerUp(targetServerId)
    -- Re-check, don't trust the caller (ox_target predicate or a future
    -- radial item) already verified this -- cheap client-side sanity
    -- check before bothering the server, which re-validates authoritatively
    -- regardless (server/partnership.lua's CheckPartnershipEligibility).
    --
    -- BUG FIX: the original version of this check was a straight,
    -- unconditional `if not CanShowK9UI() then` -- mirroring
    -- client/movement.lua's RequestLeashAttach() literally, per this
    -- function's own former doc comment. That is wrong FOR THIS FILE
    -- SPECIFICALLY: CanShowK9UI() == IsOwnModelK9() AND HasK9Access(), so
    -- it is false for EVERY officer-role player by construction (an
    -- officer is never modeled as a K9), regardless of that officer's own
    -- department membership. Unlike leash (where this same shape is only
    -- reached from a K9-only radial "self actions" menu per DEVELOPER_REFERENCE.md's own
    -- item on that submenu, so the officer-initiated direction goes
    -- through a different code path there), this file's RequestPartnerUp()
    -- is the ONE AND ONLY entry point for the "Partner Up" ox_target
    -- option below, whose own canInteract predicate
    -- (`IsOwnModelK9() or IsEntityModelK9(entity)`) and this resource's own
    -- DEVELOPER_REFERENCE.md §12.0 item 7 point 1 ("initiated by either party
    -- (K9-role or officer-role) against the other") both explicitly
    -- require an officer-initiated request to work. The unconditional gate
    -- therefore silently denied 100% of officer-initiated "Partner Up"
    -- attempts with a "you cannot use K9 features right now" notice,
    -- before the request ever reached the server -- never a security hole
    -- (server/partnership.lua's CheckPartnershipEligibility is the real
    -- authority either way), but a real, total functional break of half
    -- the documented handshake.
    --
    -- FIX: only apply the K9-shaped CanShowK9UI() pre-check when the LOCAL
    -- player would actually be the prospective K9-role party
    -- (IsOwnModelK9() true) -- mirrors CheckPartnershipEligibility's own
    -- asymmetric eligibility model (K9-role needs HasK9Access-equivalent
    -- certification; officer-role needs mere department membership, no
    -- certification of their own -- see that function's own AUTHORIZATION
    -- MODEL doc comment). An officer-role initiator has no cheap
    -- client-side department-membership equivalent exposed as a
    -- resource-global to pre-check locally -- same "no cheap client-side
    -- equivalent, let the server answer with a specific reason" tradeoff
    -- client/movement.lua's own "Certify K9 Handler" ox_target option
    -- already documents for IsEligibleCertifier -- so this simply defers
    -- that branch to the server's own CheckPartnershipEligibility, which
    -- notifies the caller either way.
    if IsOwnModelK9() and not CanShowK9UI() then
        DenyK9UIAccess()
        return
    end

    if IsPartnered() then
        lib.notify({ title = locale('common.notify_title'), description = locale('partnership.already_partnered'), type = 'error' })
        return
    end

    TriggerServerEvent('qbx_k9unit:server:requestPartnerUp', targetServerId)
    -- The target's client is the one that shows the actual accept/decline
    -- prompt (see partnerUpRequest below), not this one.
    lib.notify({ title = locale('common.notify_title'), description = locale('partnership.partner_request_sent'), type = 'info' })
end

--- Ends the current partnership, zero consent required from the other
--- party, at ANY time -- see this file's header "TERMINATION MUST NEVER
--- BE GATED" / "WHY BreakPartnership() DOES NOT MIRROR DetachLeash()'S
--- LOCAL PRE-CHECK" for why this deliberately has NO gate of any kind
--- (not CanShowK9UI(), not a local IsPartnered() pre-check) before sending.
--- Safe to call unconditionally -- server/partnership.lua's own handler is
--- a no-op (with its own notification) for a citizenid with no active
--- partnership.
function BreakPartnership()
    TriggerServerEvent('qbx_k9unit:server:breakPartnership')
end

--- ONE ACTION FOR PARTNERING (the owner's rework pass): break it if you
--- are partnered, otherwise partner up with whoever is nearest. Shared by
--- /k9partner, the radial menu's single "Partner Up / Break Partnership"
--- item and the tablet's HandlerPartnership button, so all three behave
--- the same.
---
--- ASKS THE SERVER FIRST. The local PartnershipState cache can under-report
--- after a reconnect (this file's header, "KNOWN CACHE-STALENESS GAP") --
--- which is why the radial used to show Partner Up AND Break Partnership
--- side by side, all the time. RefreshPartnershipStateFromServer() answers
--- from the server's own record, so the toggle can pick the right branch
--- instead of offering both. If that round trip fails it reads as "not
--- partnered" and the Partner Up request is refused by the server with
--- its own "already partnered" message -- bounded, and pressing again
--- retries.
---
--- The break branch is never gated ("gate the start, never the stop"); the
--- partner-up branch keeps CanShowK9UI(), and RequestPartnerUp() plus the
--- server re-check everything regardless.
---
--- Yields (a server callback). Every caller is already in a context that
--- may yield: a command handler, a NUI callback, or a thread.
--- @return boolean acted
--- @return string? reason -- 'not_available' when nothing was sent
function TogglePartnership()
    local partnered = RefreshPartnershipStateFromServer()
    if partnered then
        BreakPartnership()
        return true
    end

    if not CanShowK9UI() then
        DenyK9UIAccess('common.no_k9_role_or_access')
        return false, 'not_available'
    end

    if type(FindNearestPartnerCandidate) ~= 'function' then return false, 'not_available' end
    local candidateServerId = FindNearestPartnerCandidate()
    if not candidateServerId then
        lib.notify({ title = locale('common.notify_title'), description = locale('radial.no_partner_candidate'), type = 'error' })
        return false, 'not_available'
    end

    RequestPartnerUp(candidateServerId)
    return true
end

-- ======================================================================
-- CHAT COMMAND -- Partner Up / Break Partnership. ONE command, not two
-- (the owner: a family like this "should all work together like the
-- scen[t] command does"). All of the logic is TogglePartnership() above,
-- shared with the radial item and the tablet button.
-- ======================================================================
RegisterCommand('k9partner', function()
    TogglePartnership()
end, false)

--- Step 1 of the consent handshake, received on the TARGET's client.
--- Mirrors client/movement.lua's leashAttachRequest handler exactly.
--- @param fromServerId number
RegisterNetEvent('qbx_k9unit:client:partnerUpRequest', function(fromServerId)
    -- SOURCE-ORIGIN GUARD (see client/combat.lua's "SOURCE-ORIGIN GUARD"
    -- header block and DEVELOPER_REFERENCE.md#trust-boundary for the full
    -- writeup; not re-derived here). Without this, a forged local
    -- `TriggerEvent('qbx_k9unit:client:partnerUpRequest', <any server id>)`
    -- would pop this client's real accept/decline prompt with zero server
    -- contact -- annoying/spoofable UX even though accepting still routes
    -- through server/partnership.lua's own re-validated
    -- CheckPartnershipEligibility. Confidence: MEDIUM-HIGH, the official
    -- documented pattern for distinguishing a genuine server-sent event
    -- from a local self-trigger, not independently verified in-engine.
    if source ~= 65535 then return end

    local fromPlayer = GetPlayerFromServerId(fromServerId)
    -- locale('movement.officer_fallback_name', ...) is a deliberate
    -- cross-group reuse, not a typo: client/movement.lua's leash-request
    -- handler has the byte-for-byte identical "Officer #%d" fallback (same
    -- for accept_label/decline_label below, "Accept"/"Decline") -- reusing
    -- those existing keys here rather than minting
    -- partnership.officer_fallback_name/accept_label/decline_label
    -- duplicates, per this resource's "reuse existing key, don't mint a
    -- near-duplicate" locale convention. Left under the movement.* group
    -- (not promoted to common.*) because promoting would require also
    -- editing client/movement.lua to point at the new common.* key, and
    -- that file is owned elsewhere, outside this file's scope.
    local fromName = (fromPlayer ~= -1 and GetPlayerName(fromPlayer)) or locale('movement.officer_fallback_name', fromServerId)

    -- If the local player partners/breaks/disconnects mid-prompt, or
    -- either side is no longer eligible by the time they answer, the
    -- server re-validates everything at accept time regardless (see
    -- server/partnership.lua's CheckPartnershipEligibility TOCTOU note) --
    -- this client just needs to send the response and handle a later
    -- rejection gracefully, not assume acceptance always succeeds.
    local response = lib.alertDialog({
        header = locale('partnership.partner_request_header'),
        content = locale('partnership.partner_request_content', fromName),
        centered = true,
        cancel = true,
        labels = { confirm = locale('movement.accept_label'), cancel = locale('movement.decline_label') },
    })

    TriggerServerEvent('qbx_k9unit:server:respondPartnerUp', fromServerId, response == 'confirm')
end)

--- Step 2 of the consent handshake: the server has confirmed the pairing
--- and told THIS client its role. Sent individually to each party with
--- their own `isK9` value -- do not assume both clients receive the same
--- boolean (server/partnership.lua's own header is explicit about this).
--- @param partnerServerId number
--- @param isK9 boolean -- true only on the client whose OWN character is the K9-role party
RegisterNetEvent('qbx_k9unit:client:partnershipEstablished', function(partnerServerId, isK9)
    -- SOURCE-ORIGIN GUARD (see client/combat.lua's "SOURCE-ORIGIN GUARD"
    -- header block and DEVELOPER_REFERENCE.md#trust-boundary for the full
    -- writeup; not re-derived here). Without this, a forged local
    -- `TriggerEvent('qbx_k9unit:client:partnershipEstablished', <any
    -- server id>, true)` would make this client BELIEVE it is partnered
    -- with an arbitrary player, with zero server contact -- no
    -- server-side capability is granted by this alone today, but
    -- PartnershipState is becoming a capability input for
    -- the features that consumed it, which makes closing this now rather than
    -- after those land the right order. Confidence: MEDIUM-HIGH, the
    -- official documented pattern for distinguishing a genuine
    -- server-sent event from a local self-trigger, not independently
    -- verified in-engine.
    if source ~= 65535 then return end

    PartnershipState = { partnerServerId = partnerServerId, isK9 = isK9 }
    lib.notify({
        title = locale('common.notify_title'),
        description = isK9 and locale('partnership.now_partnered_as_handler') or locale('partnership.now_partnered_as_k9'),
        type = 'success',
    })
end)

--- The partnership has ended -- self-initiated break by either side, or a
--- server-triggered teardown (e.g. certification revoke, department
--- change -- server/certifications/ calls ForceBreakPartnershipForCitizenId
--- from four call sites as of commit 94fbc4e; see this file's header
--- "PREVIOUSLY-DISCLOSED FINDING, NOW CORRECTED" for the verified detail).
--- Sent to whichever client(s) are still online -- server/partnership.lua's
--- header is explicit this side must NOT assume the other party is
--- connected, unlike leash's leashDetached.
--- @param reason string -- e.g. 'broken' (self-initiated) or a plain reason like 'certification_revoked'/'department_changed' (server-triggered); never the raw 'system:<reason>' DB sentinel, which stays server-internal
RegisterNetEvent('qbx_k9unit:client:partnershipEnded', function(reason)
    -- WORKFLOW CLARITY FIX (this pass -- same shape as this file's own
    -- leash.lua sibling's `leashDetached` handler): every reason the
    -- server can actually send needs its OWN sentence here. Before this
    -- fix, any reason other than 'broken' was interpolated raw into
    -- 'Partnership ended (%s).', so a real player saw literal internal
    -- text like "Partnership ended (certification_revoked)." or
    -- "Partnership ended (admin_forced_from_tablet)." -- the exact
    -- machine-readable tag server/certifications//server/permissions.lua/
    -- server/tablet.lua pass to ForceBreakPartnershipForCitizenId, never
    -- translated. This is sent to BOTH parties with the SAME string (see
    -- server/partnership.lua's TellCitizenIdPartnershipEnded), so each
    -- sentence below is worded neutrally enough to be true for either side
    -- (never "your certification", since the officer/handler-role party
    -- holds no certification of their own -- see this file's header on
    -- that asymmetry).
    -- SOURCE-ORIGIN GUARD (see client/combat.lua's "SOURCE-ORIGIN GUARD"
    -- header block and DEVELOPER_REFERENCE.md#trust-boundary for the full
    -- writeup; not re-derived here). Without this, a forged local
    -- `TriggerEvent('qbx_k9unit:client:partnershipEnded', 'anything')`
    -- would desync this client's PartnershipState from the server's real
    -- state with zero server contact (e.g. a player faking their own
    -- teardown to dodge a future partnership-gated obligation, or an
    -- attacker resetting a target's cached state ahead of
    -- its former consumers). Confidence: MEDIUM-HIGH,
    -- the official documented pattern for distinguishing a genuine
    -- server-sent event from a local self-trigger, not independently
    -- verified in-engine.
    if source ~= 65535 then return end

    PartnershipState = nil

    local description = locale('partnership.ended_generic')
    if reason == 'certification_revoked' then
        description = locale('partnership.ended_certification_revoked')
    elseif reason == 'department_changed' then
        description = locale('partnership.ended_department_changed')
    elseif reason == 'k9_access_lost' or reason == 'k9_access_revoked' then
        description = locale('partnership.ended_k9_access_lost')
    elseif reason == 'admin_forced_from_tablet' then
        description = locale('partnership.ended_admin_action')
    end
    -- Anything else (including 'broken', the self-initiated case, and any
    -- reason this list does not yet know about) stays the plain generic
    -- message above -- never the raw tag itself. A future new reason
    -- degrades to "Partnership ended." rather than leaking its own
    -- internal name; add it to the list above rather than reaching for a
    -- %s template again.
    lib.notify({ title = locale('common.notify_title'), description = description, type = 'info' })
end)

-- The "Partner Up" ox_target option's canInteract below calls
-- client/main.lua's resource-global IsEntityModelK9(entity)
-- (DEVELOPER_REFERENCE.md item 3) directly for its display-only plausibility
-- check, rather than keeping this file's own small local copy of the same
-- Config.Peds-driven hash table -- client/main.lua loads first
-- (fxmanifest.lua's client_scripts order) and this call only ever happens
-- at canInteract-invocation time, never at this file's own load time, so
-- no runtime existence guard is needed here, same as this file's existing
-- IsOwnModelK9()/CanShowK9UI() call-time-only calls elsewhere. NOT a
-- security check -- server/partnership.lua's CheckPartnershipEligibility
-- independently re-derives the real, live model.

-- Derived from Config.Partnership.ProximityMeters (the REAL server-side
-- range check for establishing a partnership, both at request time and
-- again at accept time -- server/partnership.lua's
-- CheckPartnershipEligibility) rather than a bare magic number, so an
-- installer who tunes that value sees this option's visible range move
-- with it. Kept at HALF that value, same "display-only UI gate,
-- deliberately tighter than the server bound to leave margin against a
-- player drifting between opening ox_target and the server processing the
-- resulting event" reasoning client/movement.lua's own
-- LEASH_TARGET_DISTANCE_FACTOR / CERTIFY_TARGET_DISTANCE_FACTOR already
-- document in full -- not repeated verbatim here, see that file for the
-- complete writeup of this exact tradeoff.
local PARTNER_TARGET_DISTANCE_FACTOR = 0.5

-- Register the "Partner Up" target option on nearby player peds. This
-- is a DISPLAY optimization only -- the server independently re-validates
-- everything for real in CheckPartnershipEligibility
-- (server/partnership.lua), so this predicate doesn't need to be perfect
-- (see this file's header "KNOWN CACHE-STALENESS GAP" for the one honest
-- limitation of the IsPartnered() check below).
--
-- ROUTED THROUGH K9Compat.Get('target') (shared/compat/target.lua), never
-- a direct `exports.ox_target` call -- this option's `canInteract(entity,
-- distance, coords, name)`/`onSelect(data)` shapes are unchanged (still
-- authored against ox_target's own convention, per that file's contract);
-- an operator running qb-target/qtarget/sleepless_interact gets this
-- option translated automatically instead of losing it outright.
--
-- LIFECYCLE FIX: extracted into a named function, sole call site the
-- AddEventHandler('onResourceStart', ...) below, so this option comes
-- back after a bare restart of whatever resource actually backs the
-- 'target' system, not just after this resource's own restart -- ox_target
-- (and, per each adapter's own header in shared/compat/target.lua, every
-- other supported target script too) keeps its own registry in a
-- plain file-local Lua table inside its own client chunk, reloaded empty
-- on THAT resource's own restart with nothing else prompting a re-add.
-- Mirrors server/tracking.lua's RegisterScentInventoryHook /
-- server/inventory.lua's RegisterK9InventoryItemFilterHook fixes for the
-- identical bug class against ox_inventory. DUPLICATE-VS-REPLACE: the
-- option below always sets `name`, and every adapter's own registration
-- primitive dedups/replaces by that same name (or label, for the target
-- scripts that key on label instead -- see shared/compat/target.lua's own
-- per-adapter notes), so re-running this never duplicates the entry.
local function RegisterPartnerUpOxTargetOption()
    K9Compat.Get('target').AddGlobalPlayer({
        {
            name = 'qbx_k9unit:partnerUp',
            icon = 'fas fa-handshake',
            label = locale('partnership.partner_up_target_label'),
            distance = PARTNER_TARGET_DISTANCE_FACTOR * Config.Partnership.ProximityMeters,
            canInteract = function(entity, distance, coords, name)
                if IsPartnered() then return false end
                if NetworkGetPlayerIndexFromPed(entity) == PlayerId() then return false end -- can't target self

                -- At least one side should plausibly be a K9 (either us, or
                -- the target's live model) -- cheap client-side plausibility
                -- only, mirrors client/movement.lua's "Attach Leash" predicate.
                -- WIDENED (K9 role/model decoupling) with IsK9RoleForPlayer(...)
                -- -- client/appearance.lua's own per-target-cached (1s TTL)
                -- server round trip for "does THAT player hold the K9 role" --
                -- so a target on a human/custom model who already holds the
                -- role is offered too. Short-circuited last: only reached on
                -- a cache miss for the (rare) case neither IsOwnModelK9() nor
                -- IsEntityModelK9(entity) already answered this.
                return IsOwnModelK9() or IsEntityModelK9(entity) or IsK9RoleForPlayer(ResolvePlayerServerIdFromPed(entity))
            end,
            onSelect = function(data)
                local targetPlayer = NetworkGetPlayerIndexFromPed(data.entity)
                if not targetPlayer or targetPlayer == -1 then return end

                RequestPartnerUp(GetPlayerServerId(targetPlayer))
            end,
        },
    })
end

AddEventHandler('onResourceStart', function(resourceName)
    if resourceName == GetCurrentResourceName() then
        RegisterPartnerUpOxTargetOption()
        return
    end

    -- This file never names a third-party target resource directly (see
    -- shared/compat/target.lua) -- whichever one actually backs the
    -- 'target' system is asked of K9Compat itself. Redetect() is forced
    -- here rather than relying on shared/compat/core.lua's own
    -- onResourceStart/onClientResourceStart redetect hook having already
    -- run for this SAME event, so this check is correct regardless of
    -- relative handler-registration order between the two files.
    K9Compat.Redetect()
    if resourceName == K9Compat.Which('target') then
        RegisterPartnerUpOxTargetOption()
    end
end)
