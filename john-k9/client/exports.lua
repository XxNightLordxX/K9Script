--[[
    john-k9/client/exports.lua

    PUBLIC API SURFACE (client half). Companion to server/exports.lua —
    read that file's header first, it covers the shared design principles
    (read-only, re-derive/never trust, no raw internal tables,
    wrap-don't-reimplement, fail closed) which apply here identically. This
    file exists because a client-side justification is genuinely different
    from the server one, not by default symmetry:

    JUSTIFICATION FOR A CLIENT COUNTERPART: the server surface answers "is
    this player allowed/what is their state," which is what dispatch/MDT/
    evidence-style integrations need. A client-side integration need is
    narrower but real — another CLIENT resource running in the SAME
    player's game session may need to read this resource's LOCAL,
    already-computed UI/interaction state to avoid stepping on it, without
    standing up its own server round-trip:
      - A vision/goggle-item resource activating its OWN screen effect has
        a concrete reason to check IsThermalVisionActive()/
        IsNightVisionActive() first — client/vision.lua's own
        EnsureOnlyOneVisionEffectActive already enforces "only one vision
        effect active" WITHIN this resource; a second resource's effect
        stacking on top of this resource's is exactly the kind of visual
        conflict that check cannot see across resource boundaries.
      - A phone/tablet/HUD resource may want to hide/disable itself while
        the local player is CanShowK9UI() (actively controlling a K9 with
        this resource's own UI live) or IsLeashed()/IsInK9Vehicle(), the
        same way it already reasonably would for e.g. being restrained.
      - An animation/ragdoll-management resource may want IsBiteHoldEngaged()/
        IsDragEngaged() before doing something that would visibly conflict
        with a K9 action already in progress on the same ped.
    Every export below is a zero-argument (or citizenid-echoing) read of
    state this file's own client scripts already compute for their own use
    — no new logic, same "thin wrapper" posture as the server file.

    ======================================================================
    TRUST MODEL NOTE, DISTINCT FROM THE SERVER FILE: client-side state is
    never a security boundary in this resource (nor in FiveM generally — a
    modified client can always lie to itself), so "re-derive, never trust"
    does not carry the same authorization weight here it does server-side.
    These exports are DISPLAY/COORDINATION state, not permission checks —
    HasK9Access() below still round-trips to the server-authoritative
    check (it's the same function client/main.lua's own UI gating already
    calls), but a caller relying on it for anything security-relevant
    should use the SERVER export (server/exports.lua's HasK9Access(source))
    instead, which cannot be affected by a compromised client. This file's
    HasK9Access() is exposed for the coordination use case above (a local
    UI decision), not as a substitute authorization check.
    ======================================================================

    Config.Features GATING: same reasoning as server/exports.lua — none of
    the exports below gate on a Config.Features flag beyond what the
    wrapped client function itself already does internally (e.g.
    IsThermalVisionActive()/IsNightVisionActive() already return false
    outright if their owning feature was never enabled, since the
    underlying vision-effect natives are simply never toggled on in that
    case — this file adds no separate gate on top of that).

    VERSIONING: GetAPIVersion() returns this file's own version,
    independent of server/exports.lua's GetAPIVersion() — the two are
    separate contracts (a consumer resource may use only one, or use them
    at different points in its own lifecycle), each describing a different
    set of reads over a different realm's state. A consumer that reads
    both files' versions must not assume they are ever numerically equal;
    each should be checked independently via its own GetAPIVersion() call.
    Current value: 1.2.0 (see API_VERSION below) — every export in this
    file is additive over the original 1.0.0 surface, so each addition
    bumps MINOR only, per this resource's documented semver posture (see
    server/exports.lua's VERSIONING paragraph for the shared policy
    statement).

    NOT IN THIS FILE: RequestPartnerUp/BreakPartnership/RequestLeashAttach/
    DetachLeash/RequestBiteHold/ReleaseBiteHold/RequestTakedown/RequestDrag/
    ReleaseDrag/ToggleThermalVision/ToggleNightVision and every other
    self-initiated ACTION this resource's client files expose. Same
    "mutations are a trust boundary, read-only first" posture as the server
    file's own exclusion list — none of these are queries, and every one of
    them already has its own consent/proximity/cooldown context tied to
    THIS resource's own UI flow (radial menu selection, ox_target option,
    etc.) that an external resource driving them directly would bypass.
    This also names the self-initiated actions added by the features
    audited below (same exclusion, not a new category):
    `RequestThrowFetchBall`/`ReleaseFetchBall`/`RequestRecallFetchBall`
    (client/fetch.lua) and `RequestToggleK9PropAttachment`
    (client/propattachment.lua). Neither gained a read-only counterpart
    worth exporting — see PROPATTACHMENT / PROXIMITY AUDIO note below for
    why those two features contribute no exports here at all.

    PropAttachments (client/propattachment.lua): `IsPropAttachmentEngaged()`
    is a genuine, purpose-built, zero-argument resource-global read
    predicate — added specifically so client/appearance.lua's own
    K9-model-swap guard could ask "does this client currently have a vest
    attached right now," the exact same shape/role as
    IsBiteHoldEngaged()/IsDragEngaged()/IsFetchCarryEngaged() below, all
    three of which ARE exported — closed below as `IsPropAttachmentEngaged`
    (see PROP ATTACHMENT ENGAGEMENT STATE). `AttachPropToOwnPed`/
    `DetachAndDeleteProp` (internal plumbing shared with FetchMechanic, not
    domain state — same exclusion class server/exports.lua's header already
    applies to `ResolveNetworkEntity`/`NewCooldown`) and the
    `RequestToggleK9PropAttachment` action (this file's header "NOT IN THIS
    FILE" list) are both correctly excluded.

    ProximityAudioFX (client/proximityaudio.lua) contributes NOTHING to
    this file (full reasoning in server/exports.lua's "SIX-FEATURE COVERAGE
    AUDIT" section, which covers both realms even though it lives in the
    server file): client/audio.lua's `IsK9SoundActive(id)` (added alongside
    ProximityAudioFX) takes an opaque `id` minted only by `PlayK9Sound`,
    which is itself correctly not exported (an unbounded external
    NUI-message trigger with no proximity/cost context, the same category
    of concern as a mutation) — an external caller could never obtain a
    valid `id` to pass it, making it unexportable on its own.
    ======================================================================
]]

--- Copies a tier-shaped table (xp/label/speedMultiplier/scentRangeMultiplier) into a
--- fresh table — same rationale as server/exports.lua's CopyTier:
--- never hand out a live reference to this file's own cached state.
--- @param tier table
--- @return table copy
local function CopyTier(tier)
    -- WHY THIS RECURSES, given Config.XPTiers is flat today: the whole point
    -- of copying is that GetXPTier() internally returns the SHARED
    -- Config.XPTiers[n] reference, so handing it out raw would let any
    -- consumer mutate movement speed for every K9 in that tier, server-wide
    -- and for the rest of this resource's uptime. A shallow copy closes that
    -- for the current flat shape (xp/label/speedMultiplier/scentRangeMultiplier, all
    -- scalars) -- but it would SILENTLY STOP protecting the moment anyone
    -- adds a nested field, e.g. a per-tier perks list. Nothing would error,
    -- no test would fail, and the hole would just be open again. That
    -- "a control quietly stops working and says nothing" failure mode has
    -- bitten this resource repeatedly, so this recurses instead of relying
    -- on a shape assumption a future editor has no reason to know about.
    local copy = {}
    for key, value in pairs(tier) do
        if type(value) == 'table' then
            copy[key] = CopyTier(value)
        else
            copy[key] = value
        end
    end
    return copy
end

-- ======================================================================
-- VERSIONING
-- ======================================================================

local API_VERSION = { major = 1, minor = 2, patch = 0, string = '1.2.0' }

--- @return table { major: number, minor: number, patch: number, string: string }
exports('GetAPIVersion', function()
    return { major = API_VERSION.major, minor = API_VERSION.minor, patch = API_VERSION.patch, string = API_VERSION.string }
end)

-- ======================================================================
-- LOCAL PLAYER / UI STATE (wraps client/main.lua)
-- ======================================================================

--- YIELDS on a server round-trip the first call in any ~1000ms window (see
--- client/main.lua's own HAS_K9_ACCESS_CACHE_TTL_MS) — the wrapped
--- HasK9Access() is a debounced read of the server-authoritative check for
--- THIS client's own local player, not a permission decision this resource
--- makes locally. See this file's header TRUST MODEL NOTE — prefer
--- server/exports.lua's HasK9Access(source) for anything security-relevant.
--- @return boolean
exports('HasK9Access', function()
    if type(HasK9Access) ~= 'function' then return false end

    local ok, result = pcall(HasK9Access)
    if not ok then return false end
    return result == true
end)

--- Pure client-side, display-only check: is the local player's own
--- character currently a recognized K9 model? Wraps IsOwnModelK9() 1:1.
--- @return boolean
exports('IsOwnModelK9', function()
    if type(IsOwnModelK9) ~= 'function' then return false end

    local ok, result = pcall(IsOwnModelK9)
    if not ok then return false end
    return result == true
end)

--- The combinator client/main.lua's own header calls "every other client
--- file should call for K9 UI/feature gating decisions" (IsOwnModelK9() AND
--- HasK9Access()) — extended across the resource boundary here for the
--- same reason. YIELDS, for the same reason HasK9Access() above does.
--- @return boolean
exports('CanShowK9UI', function()
    if type(CanShowK9UI) ~= 'function' then return false end

    local ok, result = pcall(CanShowK9UI)
    if not ok then return false end
    return result == true
end)

--- @return boolean
exports('IsLeashed', function()
    if type(IsLeashed) ~= 'function' then return false end

    local ok, result = pcall(IsLeashed)
    if not ok then return false end
    return result == true
end)

--- @return boolean
exports('IsInK9Vehicle', function()
    if type(IsInK9Vehicle) ~= 'function' then return false end

    local ok, result = pcall(IsInK9Vehicle)
    if not ok then return false end
    return result == true
end)

-- ======================================================================
-- PARTNERSHIP STATE (wraps client/partnership.lua)
-- ======================================================================

--- Local, non-yielding cache read — see client/partnership.lua's own
--- "KNOWN CACHE-STALENESS GAP" note (that file's header) for the one case
--- this can under-report (a reconnect before the client's own
--- RefreshPartnershipStateFromServer has run). Not wrapping that refresh
--- function here deliberately — this file stays non-yielding-by-default
--- for its partnership reads, consistent with IsPartnered()/
--- GetPartnerServerId() being this resource's own designed-for-reuse
--- surface (see client/partnership.lua's own FILE-TO-FILE CONTRACT).
--- @return boolean
exports('IsPartnered', function()
    if type(IsPartnered) ~= 'function' then return false end

    local ok, result = pcall(IsPartnered)
    if not ok then return false end
    return result == true
end)

--- @return number? partnerServerId
exports('GetPartnerServerId', function()
    if type(GetPartnerServerId) ~= 'function' then return nil end

    local ok, result = pcall(GetPartnerServerId)
    if not ok then return nil end
    return result
end)

-- ======================================================================
-- XP / PROGRESSION STATE (wraps client/progression.lua)
-- ======================================================================

--- The last server-pushed tier snapshot for the local player, or nil
--- before the first 'john-k9:client:xpTierChanged' event has arrived
--- this session — ALWAYS a fresh copy (see CopyTier above), never
--- client/progression.lua's own cached table reference.
--- @return table? { xp: number, label: string, speedMultiplier: number, scentRangeMultiplier: number }
exports('GetCurrentXPTier', function()
    if type(GetCurrentXPTier) ~= 'function' then return nil end

    local ok, tier = pcall(GetCurrentXPTier)
    if not ok or type(tier) ~= 'table' then return nil end
    return CopyTier(tier)
end)

-- ======================================================================
-- TRACKING STATE (wraps client/tracking.lua)
-- ======================================================================

--- @return boolean
exports('IsTracking', function()
    if type(IsTracking) ~= 'function' then return false end

    local ok, result = pcall(IsTracking)
    if not ok then return false end
    return result == true
end)

--- @return 'scent'|'blood'|'gunpowder'|nil
exports('GetActiveTrackType', function()
    if type(GetActiveTrackType) ~= 'function' then return nil end

    local ok, result = pcall(GetActiveTrackType)
    if not ok then return nil end
    return result
end)

-- ======================================================================
-- VISION STATE (wraps client/vision.lua)
-- ======================================================================

--- @return boolean
exports('IsThermalVisionActive', function()
    if type(IsThermalVisionActive) ~= 'function' then return false end

    local ok, result = pcall(IsThermalVisionActive)
    if not ok then return false end
    return result == true
end)

--- @return boolean
exports('IsNightVisionActive', function()
    if type(IsNightVisionActive) ~= 'function' then return false end

    local ok, result = pcall(IsNightVisionActive)
    if not ok then return false end
    return result == true
end)

-- ======================================================================
-- COMBAT ENGAGEMENT STATE (wraps client/combat.lua)
-- ======================================================================

--- @return boolean
exports('IsBiteHoldEngaged', function()
    if type(IsBiteHoldEngaged) ~= 'function' then return false end

    local ok, result = pcall(IsBiteHoldEngaged)
    if not ok then return false end
    return result == true
end)

--- @return boolean
exports('IsDragEngaged', function()
    if type(IsDragEngaged) ~= 'function' then return false end

    local ok, result = pcall(IsDragEngaged)
    if not ok then return false end
    return result == true
end)

-- ======================================================================
-- FETCH ENGAGEMENT STATE (wraps client/fetch.lua)
-- (Config.Features.FetchMechanic, still `false` by default). Same shape
-- and justification as IsBiteHoldEngaged/IsDragEngaged above (an
-- animation/ragdoll-management resource may want to know a K9 is
-- currently mid-fetch-carry before doing something that would visibly
-- conflict with it on the same ped) — extended here to the fourth
-- engagement type this resource now has. Not gated beyond what the
-- wrapped global itself already does, same reasoning as the defense
-- exports above. Deliberately NOT exported:
-- RequestThrowFetchBall/ReleaseFetchBall/RequestRecallFetchBall — all
-- three are self-initiated actions, same exclusion class as this file's
-- header "NOT IN THIS FILE" list.
-- ======================================================================

--- @return boolean
exports('IsFetchCarryEngaged', function()
    if type(IsFetchCarryEngaged) ~= 'function' then return false end

    local ok, result = pcall(IsFetchCarryEngaged)
    if not ok then return false end
    return result == true
end)

-- ======================================================================
-- PROP ATTACHMENT ENGAGEMENT STATE (wraps client/propattachment.lua) --
-- `IsPropAttachmentEngaged()` is a zero-argument, resource-global read
-- predicate ("does this client currently have a vest/prop attached to its
-- own ped via this feature right now"), the same shape/role as
-- IsBiteHoldEngaged/IsDragEngaged/IsFetchCarryEngaged above (an
-- animation/ragdoll-management resource has the identical reason to check
-- this before doing something that would visibly conflict with an attached
-- prop on the same ped). Config.Features.PropAttachments is `true` by
-- default; not gated separately here beyond what the wrapped global itself
-- already does — with the feature off, client/propattachment.lua's own
-- myVestEntity is simply never set, so IsPropAttachmentEngaged() always
-- reads false on its own, same reasoning as every other wrapped predicate
-- in this file. Deliberately NOT exported: RequestToggleK9PropAttachment —
-- a self-initiated action, same exclusion class as this file's header "NOT
-- IN THIS FILE" list.
-- ======================================================================

--- @return boolean
exports('IsPropAttachmentEngaged', function()
    if type(IsPropAttachmentEngaged) ~= 'function' then return false end

    local ok, result = pcall(IsPropAttachmentEngaged)
    if not ok then return false end
    return result == true
end)
