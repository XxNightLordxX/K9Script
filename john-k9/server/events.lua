--[[
    john-k9/server/events.lua

    Shared outbound-event helper (FireOutboundEvent), extracted from SIX
    independent, byte-for-byte identical `local function FireOutboundEvent`
    copies: server/certifications/, server/search.lua,
    server/partnership.lua, server/progression.lua, and
    server/integrations.lua. Verified by direct grep of every one of those
    six definitions before writing this file -- all six were the exact same
    five-line `pcall(TriggerEvent, eventName, ...)` wrapper.

    server/integrations.lua's own copy of this
    helper each said, verbatim, that duplicating it was a deliberate choice
    at the time, since "that decision belongs to whoever next does a genuine
    cross-file cleanup pass, not to a single new-feature change that does
    not own any of those other existing files." This file is that cleanup:
    all six call sites are repointed to one implementation, with nothing
    added or removed from any payload, name, argument list, order, or
    firing condition at any of them -- a pure extraction.

    THE PRECEDENT THIS FOLLOWS: this codebase already did this exact
    consolidation once, for NotifyPlayer (12 independent copies -> one
    shared function in server/notify.lua). Read that file's header for the
    full reasoning; this file matches its shape deliberately.

    WHY A NEW FILE, NOT FOLDED INTO server/notify.lua: applying that same
    file's own stated rule ("a shared file should be scoped to ONE
    responsibility," the same test server/notify.lua's header uses to
    justify NOT folding itself into server/cooldowns.lua or
    server/entities.lua). "Should this UI toast go out to one of this
    resource's own clients" (NotifyPlayer) and "should a stable, documented
    outbound TriggerEvent go out for OTHER resources to react to" (this
    file's FireOutboundEvent) are two genuinely different responsibilities:
    different transport (TriggerClientEvent vs TriggerEvent), different
    audience (this resource's own connected player vs every OTHER resource
    on the server), and different contract (NotifyPlayer is purely internal
    UI plumbing; FireOutboundEvent is the literal implementation of the
    `john-k9:events:*` stable public API server/exports.lua's header
    documents). Folding the two together would violate the exact rule
    server/notify.lua's own header cites to justify its own existence.

    LOAD ORDER -- CHECKED PER CALL SITE, NOT ASSUMED. All 14 call sites that
    existed AT EXTRACTION TIME (across the six files above) were read
    directly before this extraction: every one is inside the body of
    an event handler, callback, or command handler -- never at any file's
    own top-level file-load time. That makes this file's own position in
    fxmanifest.lua a soft, not hard, ordering requirement, exactly like
    server/notify.lua's NotifyPlayer and server/entities.lua's
    ResolveNetworkEntity: by the time any consumer's handler can actually
    run, every server_scripts file has already finished loading regardless
    of manifest order. It is nonetheless placed early -- alongside
    server/cooldowns.lua, server/entities.lua, and server/notify.lua, the
    resource's other shared-helper files -- to read in the same "shared
    primitive first" order those already established, so no
    `type(FireOutboundEvent) == 'function'` existence guard is needed at
    any consuming file's call sites -- true for the original six and
    unchanged for a later call site added afterward
    (see "COUNT WILL DRIFT, NOT MAINTAINED LIVE HERE" below), for the
    identical load-order reason.

    ZERO BEHAVIOR CHANGE. Unlike server/notify.lua's NotifyPlayer
    extraction (which deliberately fixed a wrong `'inform'` default and
    added a new target-validity guard neither of the 12 originals had),
    this extraction changed NOTHING: the body below is byte-for-byte
    identical to all six originals, and every one of the 14 call sites that
    existed at extraction time was left untouched -- same event name, same
    arguments, same order, same firing condition. This is a pure structural
    move, not a behavior pass; the `john-k9:events:*` names this backs
    are a documented, consumer-facing contract (see server/exports.lua's
    EVENT CONTRACT section) and the entire point of this extraction is that
    it keeps behaving identically, just from one place instead of six.
    COUNT WILL DRIFT, NOT MAINTAINED LIVE HERE: "14" above is the count
    verified at the time of this file's own extraction, not a live total
    this header maintains going forward -- new call sites are expected to
    accumulate in existing and new consumer files as features land, exactly
    as a shared helper should allow. A direct recount
    (`grep -rn "^\s*FireOutboundEvent(" server/`, excluding this file's own
    definition and one backtick-quoted mention in a comment in
    server/integrations.lua) found 23 real call sites across SEVEN files
    (the original six above, plus a later caller, which added its
    own new call site after this extraction landed, calling the shared
    global directly rather than ever having had its own duplicate copy). Do
    not trust either number without recounting; this comment will go stale
    again the next time a feature adds a call site.
    ======================================================================
    FILE-TO-FILE CONTRACT:
    - THIS FILE exposes ONE resource-global (no `local`) function:
        FireOutboundEvent(eventName: string, ...: any)
      pcall-wraps a plain `TriggerEvent(eventName, ...)` and logs (never
      re-throws) if a registered handler in another resource errors.
    - Every one of this resource's `john-k9:events:*` outbound events
      fires through this function. See server/exports.lua's EVENT CONTRACT
      section for the full, authoritative list of event names/payloads and
      which file fires which.
    ======================================================================
]]

--- Fires a stable `john-k9:events:*` outbound event for other resources
--- to react to (dispatch/MDT/evidence/HUD integrations -- see
--- server/exports.lua's header "EVENT CONTRACT" section for the full
--- documented contract this implements). Single shared implementation of
--- the pattern 6 independent local copies hand-rolled across this
--- resource's server files -- see this file's header for the full
--- extraction writeup.
---
--- `TriggerEvent` runs every `AddEventHandler` registered by every OTHER
--- resource on this server, SYNCHRONOUSLY, on this same call stack. A
--- misbehaving/buggy consumer resource's handler throwing must never be
--- able to unwind back into (and abort the remainder of) the
--- certification/partnership/search/progression/SAR-call/integration flow
--- that fired it -- pcall-wrapped so a consumer's exception is swallowed
--- and logged here, never propagated. Every existing call site only ever
--- fires this AFTER its own write has already committed and every
--- eligibility check has already passed, so a pcall failure here can only
--- ever mean "a consumer's own handler broke," never that this resource's
--- own state disagrees with what it just announced -- nothing upstream of
--- any call site is undone or retried based on whether the fire succeeds.
--- @param eventName string
--- @param ... any
function FireOutboundEvent(eventName, ...)
    local ok, err = pcall(TriggerEvent, eventName, ...)
    if not ok then
        print(('[John-K9] outbound event %s: a registered handler in another resource errored: %s'):format(eventName, tostring(err)))
    end
end
