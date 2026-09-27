--[[
    qbx_k9unit/client/tablet.lua

    Config.Features.CommandTablet. Client-side bridge for the K9 Command
    Tablet. Owner's own words (relayed by the coordinator, scope expanded
    twice mid-pass): high command gets a control console over every
    feature/handler/K9; every certified handler or K9 gets a read-only
    view of their own record plus the ability to TRIGGER what they hold,
    as an alternative to keybinds/commands; opening is command- or
    item-based, operator's choice.

    THIS FILE OWNS: opening/closing the NUI + its focus lifecycle,
    resolving Config.CommandTablet.openMode, and routing every NUI
    callback to either (a) an EXISTING client resource-global the
    keybind/radial already calls, (b) the SAME chat-command handler a
    typed command would hit (via ExecuteCommand), or (c) a server
    callback -- proposed ones flagged explicitly below, since not every
    piece of server support this needs exists yet (server/permissions.lua's
    own header already names the roster/record aggregation as "a genuine
    cross-file architecture question... reported to coder-frontend/
    coder-ui/coder-architect rather than decided unilaterally" -- picked up
    here from the client side and relayed onward, not solved unilaterally
    by this file either).

    ======================================================================
    RIGHT-VS-WRONG (coordinator's own framing, verbatim): "route each
    tablet action to the SAME client function the keybind and command
    already call. One code path, one set of guards, one place to fix a
    bug... if one is a local rather than a global, report exactly which
    file and function needs a seam opened rather than duplicating its
    body." Named precedent: ScratchAtDoor/NudgeDoor checked vehicle state
    in ox_target's canInteract but not inside the function itself, so one
    entry point was guarded and the other was not.

    Applied here:
      - SECTION 2 (tablet:triggerFeature) calls the exact same
        resource-global every keybind/radial item already calls, mirroring
        client/radial.lua's own per-item gate CHOICE for that action
        line-for-line (cited per entry). FindNearestLeashCandidate/
        FindNearestPartnerCandidate were `local` in client/radial.lua --
        the coordinator has since opened that seam (dropped `local`,
        allowlisted both) rather than this file duplicating the search.
        Guarded with `type(fn) == 'function'` regardless (radial.lua
        returns early with neither defined when its own flag is off --
        this is not optional).
      - tablet:decertify used to call `ExecuteCommand` directly (a small
        "SECTION 3" command-bridge helper, `SubmitAllowlistedCommand`), the
        SAME mechanism the chat box itself uses to submit a typed command --
        REMOVED THIS PASS (docs/history/COMMAND_CONSOLIDATION_SPEC.md §6 bugfix): that
        bridge always submitted the OFFLINE-ONLY '/k9decertifyoffline
        <citizenid> <job>' command regardless of the target's real online
        state, and that command's own server-side guard explicitly refuses
        an actually-online target -- so the button silently did nothing
        against anyone currently connected. tablet:decertify now calls a
        real `qbx_k9unit:server:tabletDecertify` server callback, exactly
        like tablet:certify already did (server/certifications/'s new
        RevokeCertificationForTablet resolves online-vs-offline itself and
        delegates to the correct, UNCHANGED underlying function either way).
        (A prior, broader 'tablet:runCommand' generic command-bridge --
        allowlisting k9certify/k9decertify/k9givexp plus five k9audit*
        commands -- was REMOVED in an earlier pass: it had no caller
        anywhere in html/, was never part of this file's own documented NUI
        CONTRACT below, and at the time the five k9audit* commands it
        existed to reach were chat/console-notify oriented at the server
        layer with no callback that returned structured data. STATUS UPDATE
        (later pass): server/admin.lua has since grown the exact
        `lib.callback.register` surface that gap named
        (tabletAuditCert/Partner/Search/Xp/Dept, each returning
        `{ok, rows, label}` -- see its own header CALLBACK SURFACE section),
        and this file's own NUI CONTRACT below now lists the five
        tablet:audit* bridges built against it, plus the real Audit Trail
        tab in html/tablet.js that consumes them -- the "real audit tab"
        this note originally deferred. Left here, corrected rather than
        deleted, so the reasoning for the ORIGINAL removal (a generic
        passthrough is not how this file exposes new server capability)
        still reads accurately for whoever finds this comment. STATUS
        UPDATE (later pass, 2): server/admin.lua grew a SIXTH callback,
        `qbx_k9unit:server:tabletAuditCatalog` (its own header: "the GAP 2
        read side"), the same pass that closed its own eight
        `*Audit_Append` writers' matching read side -- it shipped with full
        test coverage but, unlike the five above, no `tablet:auditCatalog`
        bridge and no consuming screen, which is exactly the seam this note
        exists to flag. That gap is now closed too: `tablet:auditCatalog`
        is the sixth bridge in the NUI CONTRACT below, and the Audit Trail
        tab's own Catalog Changes mode is what consumes it -- see
        auditColumnsForCatalog() in html/tablet.js.)
    ======================================================================

    ======================================================================
    SECURITY NOTE. THE TABLET IS A VIEW. IT DECIDES NOTHING. Every action
    it offers -- viewing a record, granting a permission, triggering an
    ability, certifying, running an admin command -- is re-authorized
    server-side from the caller's own live job/grants/blocks, exactly as
    if they had typed the command or pressed the keybind. A modified
    client can fire any NUI callback with any payload, so nothing in this
    file may ever be the thing that actually authorizes an action.
    `Config.FeatureControl.allowActionsFromTablet` (checked before
    SECTION 2 dispatch and inside tablet:decertify's own handler) is a
    pure UX toggle, not an authorization boundary -- turning it off only
    removes the tablet's trigger buttons,
    it cannot and does not change what a keybind/command/radial item can
    still do.
    ======================================================================

    ======================================================================
    OPENING -- Config.CommandTablet.openMode ('command' | 'item' | 'both').
    An unrecognised value falls back to 'command' with a loud console
    warning -- never leaves a player with NO way in at all.
      'command' -- RegisterCommand only. No item involvement.
      'item'    -- the command is NOT registered at all. The ox_inventory
                   item (Config.CommandTablet.itemName) is the only way in.
      'both'    -- both paths work; the item is a convenience, not a gate.
    THE TRAP (config.lua's own words): the item must already exist in the
    OPERATOR'S OWN ox_inventory items table -- this resource cannot create
    it, and an unregistered name resolves to a "no such item" callback
    that never fires, which in 'item' mode means NOBODY can open the
    tablet with nothing to explain why. server/wellbeing.lua's
    WarnIfItemMissing is the established SERVER-side pattern for this
    exact class of placeholder-item check (exports.ox_inventory:Items());
    this file cannot run that check itself (no server-side export access),
    so it is requested from whoever owns the tablet's server-side glue
    (this pass's own report), with escalated wording in 'item' mode per
    the coordinator's own instruction. This file's OWN, client-side
    defence is narrower but real: IsInventoryUseCapable() below guards the
    K9Compat-routed `UseItem` call itself (asks shared/compat/core.lua's own
    detection result, not `exports.ox_inventory` directly -- see that
    function's own doc comment), so a missing/outdated/undetected inventory
    degrades to a logged warning + a player-facing notify, never an
    uncaught error out of an item-use event.
    The radial entry point (this pass's own report names the exact item)
    stays available in EVERY mode -- a UI affordance, not a third open
    mode, honouring the same OpenTablet() gate either way.

    ONE COMMAND, ROUTED BY RANK (owner-directed, 2026-08-26, verbatim:
    "instead of having /k9tablet and k9hqtablet make it one command that
    makes it based off the rank in the department"). The ORIGINAL command/
    item/radial entry point above now ALWAYS calls OpenTablet() with no
    argument, which resolves to `requestedView = 'auto'` in the tablet:open
    payload -- html/tablet.js's loadMyRecord() reads that hint, strictly
    AFTER the server's own viewer fields for this specific caller come
    back, and lands a canAccessConsole()-qualifying caller (high command,
    OR an explicit 'k9.audit' grant -- the SAME gate the Console tab/Home
    card already use, REUSED here rather than a second, parallel notion of
    "rank") straight on the console; everyone else lands exactly where the
    ordinary command always landed them, silently, no notice. This is a
    LANDING SCREEN choice only, never a second grant: OpenTablet() itself
    is unchanged (same tabletOpen-already-true no-op guard, same single
    SetNuiFocus(true, true), same SendNUIMessage), and `requestedView`
    rides along in the payload purely as a presentation hint -- see the NUI
    CONTRACT's own note on that field.

    OPTIONAL SECOND ENTRY POINT -- Config.CommandTablet.highCommandCommand.
    Now that the single command auto-routes by rank on its own, this
    second command is no longer required for anyone -- DEFAULT DISABLED
    (`false`) on a fresh install, per config.lua's own comment. It exists
    ONLY for a server that already had this bound to a separate key/macro
    and wants to keep that muscle memory working: when configured to a
    non-empty string, it registers a SEPARATE RegisterCommand, always
    registered whenever Config.Features.CommandTablet is on (independent of
    openMode above, which only governs the ORIGINAL command's/item's
    reachability), that calls the exact same OpenTablet(), just passing
    'highCommand' as its `requestedView` argument. It is STILL a SHORTCUT
    TO A SCREEN, never a second grant of access -- same canAccessConsole()
    check as the 'auto' path above, the only difference being that an
    insufficient caller who explicitly typed THIS command sees a visible
    "you don't have access" notice instead of silently staying on their own
    record (they asked, so they are told why not). `false`/missing/blank
    config registers nothing and prints no warning (this is now the
    ordinary, intended state, not a misconfiguration) -- the ORIGINAL
    command/item stay fully reachable regardless, since this was always,
    and remains, a pure addition on top of them.
    ======================================================================

    ======================================================================
    NUI CONTRACT -- authoritative source is html/tablet.js's own header
    (coder-ui); condensed here, byte-exact on names/payload keys (a
    mismatch just hangs the fetch promise or drops a push, no error either
    side). SendNUIMessage targets the TOP window; html/tablet-bridge.js
    relays any '/^tablet:/' action down into the tablet's own iframe.

    JS -> Lua (RegisterNUICallback, every path calls cb(...) unconditionally):
      tablet:ready {}                                             -> cb({})
      tablet:close {}                                             -> cb({})
      tablet:requestMyRecord {}                                   -> cb(MyRecordResult)
      tablet:requestRoster {query}                                -> cb(RosterResult)          [console audience]
      tablet:requestOnlinePlayers {query}                         -> cb(OnlinePlayersResult)    [console audience -- SAME gate as requestRoster, not the wider person-lookup one]
      tablet:openOnlinePlayer {source,nonce}                      -> cb({ok,citizenid?,name?,error?,message?}) [console audience -- resolves ONE online-players row to a citizenid, freshly, at click time; see server/tablet.lua's tabletResolveOnlinePlayer for the recycled-source-id guard]
      tablet:requestPersonSummary {targetCitizenId}               -> cb(PersonSummaryResult)    [console audience]
      tablet:requestPersonFeatures {targetCitizenId}               -> cb(PersonFeaturesResult)   [high command only]
      tablet:rosterList {}                                        -> cb({ok,k9?,handlers?,unassigned?,error?})  [high command only -- server/roster.lua's qbx_k9unit:server:rosterList, docs/history/ROSTER_SPEC.md Phase B; forwarded VERBATIM, no ReasonToJsResult]
      tablet:rosterSetPersonnelRole {citizenid,job,personnelRole}  -> cb({ok,outcome?,error?})    [high command only -- server/roster.lua's qbx_k9unit:server:rosterSetPersonnelRole]
      tablet:rosterSetCallsign {citizenid,job,callsign?}           -> cb({ok,outcome?,error?})    [high command only -- server/roster.lua's qbx_k9unit:server:rosterSetCallsign; callsign omitted or '' clears it]
        These three are a THIRD entry point into the SAME buildPersonScreen()
        Console/Online-Players already open (docs/history/ROSTER_SPEC.md §0) -- not a
        second roster/person mechanism. rosterList's rows are the shared
        payload BOTH the two new roster tabs AND the Person screen's own
        embedded Roster Role/Callsign section read; sorting by tier/grade/XP
        is a PURE client-side re-sort of that one payload in html/tablet.js,
        never a second call to this callback.
      tablet:requestMyPartnerships {}                             -> cb(PartnershipsResult)      [Partnerships tab, everyone -- server/tablet.lua's tabletRequestMyPartnerships, enriched here with the caller's own active row's getPartnershipTenureProgress]
      tablet:requestPartnershipsForTarget {targetCitizenId}       -> cb(PartnershipsResult)      [Partnerships tab admin lookup, high command only]
      tablet:forceEndPartnership {targetCitizenId}                -> cb({ok,error?})             [Partnerships tab admin control, high command only -- server/partnership.lua's existing ForceBreakPartnershipForCitizenId]
      tablet:triggerFeature {feature}                             -> cb({ok,error?})            [SECTION 2]
      tablet:certify {targetCitizenId, departmentKey, k9Model?}   -> cb({ok,error?,message?})   [server/certifications/'s tabletCertify -- online OR offline, see GrantCertificationForTablet's own header]
      tablet:decertify {targetCitizenId, departmentKey}           -> cb({ok,error?,message?})   [server/certifications/'s tabletDecertify -- online OR offline, see RevokeCertificationForTablet's own header]
      tablet:setCertificationTier {targetCitizenId, departmentKey, tier}     -> cb({ok,error?})  [server/certifications/'s tabletSetCertificationTier -- online OR offline]
      tablet:renewCertification {targetCitizenId, departmentKey}            -> cb({ok,error?})  [tabletRenewCertification -- online OR offline]
      tablet:grantSpecialization {targetCitizenId, departmentKey, specialization}  -> cb({ok,error?})  [tabletGrantSpecialization -- ONLINE ONLY, see that function's own header for why]
      tablet:revokeSpecialization {targetCitizenId, departmentKey, specialization} -> cb({ok,error?})  [tabletRevokeSpecialization -- online OR offline]
      tablet:givexp {targetCitizenId, amount}                     -> cb({ok,error?,message?})   [proposed]
      tablet:grantPermission {targetCitizenId, permission}        -> cb({ok,error?,message?})   [server/permissions.lua]
      tablet:revokePermission {targetCitizenId, permission}       -> cb({ok,error?,message?})
      tablet:grantFeature {targetCitizenId, feature}              -> cb(...)  -- same callback as grantPermission, key = 'feature.'..feature
      tablet:revokeFeature {targetCitizenId, feature}             -> cb(...)  -- revokePermission, key = 'feature.'..feature
      tablet:blockFeature {targetCitizenId, feature}              -> cb(...)  -- grantPermission, key = 'block.'..feature
      tablet:unblockFeature {targetCitizenId, feature}            -> cb(...)  -- revokePermission, key = 'block.'..feature
        (config.lua's own header: grants and blocks share the k9_permissions
        table and revoke semantics -- revoking a 'block.<Name>' row is how
        it's lifted. Nothing new needed server-side for these four.)
      tablet:assignK9Role {targetCitizenId, modelName}            -> cb({ok,error?,message?})   [high command -- server/tablet.lua's tabletAssignK9Role]
        Forwarded VERBATIM -- server/appearance.lua's ApplyK9PedRole (via
        that callback) already re-checks IsHighCommand itself and already
        accepts ANY Config.Peds entry; this file adds no authorization and
        no second appearance-mutation path. `modelName` is display-chosen
        from the `peds` list this file sends in the tablet:open payload
        below, but the SERVER'S OWN IsValidPedModelName re-check against
        its OWN Config.Peds is what actually matters -- a modified client
        sending an arbitrary string gets 'invalid_model' back, nothing more.
      tablet:revertK9Ped {targetCitizenId}                        -> cb({ok,error?,message?})   [high command -- server/tablet.lua's tabletRevertK9Ped]
        THE NO-UNBOUNDED-TRAP ACTION -- forwarded verbatim, gated
        server-side on the GRANTER's own authorization ONLY, never on
        anything about the target (see server/tablet.lua's own header): a
        target who already lost every certification/grant/feature check
        must still be revertible, or revoking someone first would strand
        them as an animal permanently. This file's OWN contribution to that
        guarantee is UI-side, not authorization-side: html/tablet.js's
        "open by citizen ID" control (its own header) exists specifically
        so high command can reach a person screen for a citizenid who no
        longer appears in tablet:requestRoster's own certified-only rows,
        and therefore still has a path to press this button on them at all.
      tablet:getTheme {}                                          -> cb({ok,theme?,error?})     [Config.Features.TabletTheming -- server/runtimecontrol.lua]
      tablet:setTheme {primaryColor?,accentColor?,backgroundColor?,textColor?,density?,headerTitle?} -> cb({ok,theme?,error?,field?})  [high command]
      tablet:resetTheme {}                                        -> cb({ok,theme?,error?})     [high command]
        All three forwarded through TranslateReasonResult (below), which
        only renames server/runtimecontrol.lua's `reason` field to this
        contract's `error` (and forwards `field`, set only on
        error='invalid_field', naming which of the six theme inputs failed)
        -- COSMETIC ONLY, see that file's own PART 2 header: nothing a
        theme value carries is ever consulted by an authorization check,
        here or anywhere else in this resource. getTheme has no
        authorization gate at all (applied for every viewer); setTheme/
        resetTheme re-check high command server-side regardless of what
        this page shows.
      tablet:certTiersList {}                                     -> cb({ok,tiers?,capabilityCatalog?,error?})   [high command -- server/certtiers.lua]
      tablet:certTiersUpsert {key,label,capabilities:string[]}    -> cb({ok,tiers?,capabilityCatalog?,error?})   [high command]
      tablet:certTiersReorder {orderedKeys:string[]}              -> cb({ok,tiers?,warning?,error?})             [high command]
      tablet:certTiersDelete {key}                                -> cb({ok,tiers?,error?,referenceCount?,shopItemKeys?}) [high command]
        `referenceCount`/`shopItemKeys` are BOTH only ever populated
        together, and only for error='tier_in_use_by_shop_items' (the
        supply-shop-item referrer, server/certtiers.lua's DeleteTier,
        commit a32a554) -- error='tier_in_use' (the certification-record
        referrer, checked FIRST) populates `referenceCount` alone, with no
        `shopItemKeys` at all. See html/tablet.js's certTierErrorText()
        for how each is rendered.
        All four forwarded through the SAME TranslateReasonResult --
        server/certtiers.lua's own header states its response shape
        "mirrors server/runtimecontrol.lua's own `{ ok, reason, ... }`
        convention exactly", so it needs the identical `reason` -> `error`
        bridge, done HERE (client-side), not in that file, so it can keep
        matching its sibling's convention without also learning this
        contract's `error`-keyed shape. `tiers` (every list/mutation
        response) is the FULL, current, DYNAMIC catalog -- html/tablet.js
        must never hardcode a tier list, see ListCertificationTiers's own
        doc comment. A successful reorder's `warning` is non-optional and
        MUST be surfaced prominently (server/certtiers.lua's own header
        "HAZARD 3": a reorder re-ranks every citizenid already holding one
        of the reordered tiers, retroactively). `tier_in_use`/
        `protected_tier` on a failed delete are REFUSALS ("cannot, and
        here is why" -- a referenced or protected tier), not failures in
        the "something went wrong" sense; `referenceCount` (delete only)
        names how many k9_certifications rows still reference the tier.
      tablet:permKeysList {}                                      -> cb({ok,keys?,error?})        [high command -- server/permissionkeycatalog.lua]
      tablet:permKeysUpsert {key,label,description?}              -> cb({ok,keys?,error?})         [high command]
      tablet:permKeysDelete {key}                                 -> cb({ok,keys?,error?,activeGrantCount?}) [high command]
        Same TranslateReasonResult bridge as the cert-tier trio above --
        server/permissionkeycatalog.lua's own header states its response
        shape mirrors server/certtiers.lua's own convention exactly. `keys`
        (every list/mutation response) is the FULL, current, DYNAMIC
        catalog -- html/tablet.js must never hardcode the four admin
        capability names, see ListPermissionCatalogKeys's own doc comment.
        `reserved_namespace` (create/rename) and `unknown_key` (delete) are
        REFUSALS ("cannot, and here is why" -- the key collides with the
        feature./block. per-person-feature-control namespace, or does not
        exist), not failures in the "something went wrong" sense.
        `activeGrantCount` (delete only, may be nil on a degraded read)
        names how many k9_permissions rows currently hold the deleted key
        -- INFORMATIONAL ONLY, unlike certTiersDelete's `referenceCount`:
        this delete is NEVER refused because of it (see that file's own
        header "TOMBSTONE, NOT REFERENCE-COUNTED" for why a permission key
        has no equivalent hazard to server/certtiers.lua's own
        'tier_in_use' refusal). There is no reorder counterpart -- a
        permission key carries no ordinal.
      tablet:equipmentShopGetLocations {}                         -> cb({ok,locations?,error?})   [high command -- server/equipmentshop.lua]
      tablet:equipmentShopAddLocation {label?,model?,scenario?}   -> cb({ok,locationKey?,locations?,error?})
        COORDINATES ARE NEVER SENT BY html/tablet.js -- a CEF browser page
        has no native access to GetEntityCoords at all (see this task's own
        instruction: "Get it client-side and send it; do not expect the
        server to know where they are"). THIS FILE captures the caller's
        own current position/heading (GetEntityCoords/GetEntityHeading on
        PlayerPedId()) at the moment this callback fires and adds it to the
        `location` table sent to the server -- the ONLY point in this whole
        round trip that has that information. `label`/`model`/`scenario`
        are each OMITTED entirely when blank (never sent as `''`, which the
        server's own IsSafeShortString would reject outright) -- meaning
        "inherit the shop-wide default", exactly like a config.lua location
        entry with that field left unset.
      tablet:equipmentShopMoveLocation {locationKey,updates?:{label?,model?,scenario?},useCurrentPosition?} -> cb({ok,locations?,error?})
        Serves BOTH this screen's "Edit" (metadata only: `updates.label`/
        `.model`/`.scenario`, ALWAYS all three, each either a non-empty
        string override or `false` to reset that field back to the
        shop-wide default -- never omitted here, unlike Add above, since an
        edit's draft always starts pre-filled from a real, already-resolved
        value) and its "Move Here" (`useCurrentPosition = true`, no
        label/model/scenario at all) -- ONE server callback, so both flow
        through here. `useCurrentPosition` triggers the SAME THIS-FILE
        GetEntityCoords/GetEntityHeading capture as AddLocation above,
        merged into `updates.x/.y/.z/.heading` -- never requested of, or
        assumed by, the server.
      tablet:equipmentShopRemoveLocation {locationKey}             -> cb({ok,locations?,error?})
        All four forwarded through the SAME TranslateReasonResult as the
        theme/cert-tier callbacks above -- server/equipmentshop.lua's own
        header states its response shape is a plain `{ ok, reason, ... }`
        outcome table, "never player-facing prose", same convention. High
        command only (`CanManageShopLocations` re-verified server-side on
        every one of the three mutating calls; GetLocations itself has NO
        such gate server-side -- open to any connected player, matching
        that file's own header note that this only needs to be true for
        someone who has not yet earned any special trust) -- this page
        still only ever shows the MANAGEMENT screen to high command, a
        convenience per THE SECURITY RULE, not the real gate. A `db:<n>`
        location key may be moved/removed; a `cfg:<n>` one (defined in
        config.lua) is refused outright (`invalid_key`) by the server on
        purpose -- see that file's own SCOPE note -- and this page never
        offers Move/Remove controls for one, only a note pointing at
        config.lua.
      tablet:equipmentShopItemsList {}                             -> cb({ok,items?,error?})   [high command -- server/equipmentshop.lua]
      tablet:equipmentShopItemsUpsert {key,price,label?,currency?,requiredTierKey?,requiredSpecialization?} -> cb({ok,items?,error?})
      tablet:equipmentShopItemsReorder {orderedKeys:string[]}      -> cb({ok,items?,error?})
      tablet:equipmentShopItemsDelete {key}                        -> cb({ok,items?,error?})
        The shop's INVENTORY half (WHICH items are sold, at what price, in
        what order, and under what certification-tier/specialization
        purchase requirement) -- the RUNTIME SHOP LOCATIONS callbacks above
        manage WHERE a shop ped stands, never what it sells. All four
        forwarded through the SAME TranslateReasonResult as every other
        surface on this page. High command only for ALL FOUR, including
        the list read (`CanManageShopItems` re-verified server-side on
        every call) -- unlike equipmentShopGetLocations above, this list
        exposes admin-only state (tombstoned/database-vs-config sourcing)
        an ordinary player has no need to see; the price/availability a
        player DOES need is already public through ox_inventory's own shop
        UI regardless. `items` is `{ key, label, price, currency?,
        sortOrder, requiredTierKey?, requiredSpecialization? }[]`, already
        sortOrder-ascending. A price edit/reorder/delete takes effect for
        every already-connected player IMMEDIATELY (server/equipmentshop.lua
        live-refreshes the registered shop after every successful edit) --
        no restart needed, unlike a raw config.lua edit.
      tablet:runtimeListFeatures {}                               -> cb({ok,features?,error?})   [high command -- server/runtimecontrol.lua]
        THIS PASS: each row in `features` now also carries `lockoutRisk`
        (boolean), `sessionOnly` (boolean), and `lockoutWarning` (string,
        present only when `lockoutRisk` is true) -- server/runtimecontrol.lua
        already returned all three (its own runtimeListFeatures doc comment,
        unchanged), this file merely stopped being the reason html/tablet.js
        never read them. Forwarded verbatim, same as every other field on
        this row.
      tablet:runtimeSetFeature {name,value:boolean,confirm?:string}   -> cb({ok,appliedLive?,restartRequired?,configEditRequired?,tier?,lockoutRisk?,sessionOnly?,error?,warning?})
      tablet:runtimeResetFeature {name,confirm?:string}               -> cb({ok,value?,restartRequired?,lockoutRisk?,sessionOnly?,error?,warning?})
      tablet:runtimeListTunables {}                                -> cb({ok,tunables?,error?})
      tablet:runtimeSetTunable {key,value:number}                 -> cb({ok,appliedLive?,restartRequired?,value?,error?,min?,max?})
      tablet:runtimeResetTunable {key}                            -> cb({ok,value?,restartRequired?,error?})
        All six forwarded through the SAME TranslateReasonResult as the
        theme/cert-tier/shop-location callbacks above --
        server/runtimecontrol.lua's own callbacks return the identical
        `{ ok, reason, ... }` outcome shape (that file's own header states
        it explicitly). High command only (`CanManageRuntimeControl`
        re-verified server-side on every one of the six calls regardless of
        what this page shows) -- server/runtimecontrol.lua's own header:
        "LOCALE KEYS THIS FILE NEEDS: none... outcome tags, never
        player-facing prose" -- meaning the `tier`/`note` fields that file
        returns are DELIBERATELY NOT forwarded to the player as-is by
        html/tablet.js: that page derives its OWN locale-driven plain-
        language explanation from the `tier` string alone (see that file's
        own header on the five tiers: 'live'/'onstart'/'rawtoplevel'/
        'clientonly'/'protected', plus the client-side-only 'unaudited'
        fallback for a feature GetFeatureTier could not classify), never
        the server's own raw English `note` prose. `reason='unaudited_feature'`
        and `reason='protected_feature'` are REFUSALS ("cannot, and here is
        why"), not generic failures, per this task's own instruction --
        html/tablet.js's own runtimeFeatureErrorText() gives each its own
        explanatory copy rather than a bare code. `reason='out_of_range'`
        on a rejected tunable set carries the server's own real `min`/`max`
        back (TUNABLE_REGISTRY's own bounds) -- forwarded verbatim so the
        tablet can tell the operator the exact range, never a guess of its
        own; this page does NOT independently enforce that range as if it
        were authoritative (server/runtimecontrol.lua's own SetTunable is
        the only real gate), only uses it as an `<input type="number">`
        min/max HINT that does not block submission.

        THE LOCKOUT-RISK CONFIRMATION GATE, bridged, NOT DECIDED, HERE
        (this pass): server/runtimecontrol.lua's own runtimeSetFeature/
        runtimeResetFeature refuse to change a `lockoutRisk` feature
        (HighCommand, PermissionGrants, RuntimeFeatureControl,
        TabletTheming, CommandTablet) without a `confirm` argument equal to
        that feature's own `name` EXACTLY -- `reason='confirmation_required'`
        otherwise, carrying that feature's own `lockoutWarning` text back.
        `data.confirm`, if present, is forwarded to the THIRD (SetFeature)
        or SECOND (ResetFeature) argument, exactly as received, with NO
        validation of its value beyond "is this even a string or nil"
        below -- THIS FILE NEVER DECIDES AUTHORIZATION: it does not check
        `confirm == data.name` itself before forwarding, and does not
        synthesize/default a `confirm` value for a caller that omitted one.
        The server's own exact-match check is the only real gate, run
        again, independently, on every single call, regardless of what
        html/tablet.js sent -- a hand-crafted NUI message bypassing that
        page entirely gets refused by the server the same way. html/tablet.js's
        own runtime-control screen is what actually shows the operator the
        `lockoutWarning` text and requires them to type the feature's name
        before ever sending this second call -- see that file's own header
        note on its lockout-risk confirmation panel for the full UI
        contract.
      tablet:auditCert {targetCitizenId, limit?}    -> cb(AuditResult)  [server/admin.lua's tabletAuditCert]
      tablet:auditPartner {targetCitizenId, limit?} -> cb(AuditResult)  [tabletAuditPartner]
      tablet:auditSearch {mode, value?, limit?}     -> cb(AuditResult)  [tabletAuditSearch -- mode in {'officer','plate','person','recent'}]
      tablet:auditXp {targetCitizenId}              -> cb(AuditResult)  [tabletAuditXp -- no limit, single-row point lookup]
      tablet:auditDept {departmentKey, limit?}      -> cb(AuditResult)  [tabletAuditDept]
      tablet:auditCatalog {catalogName, limit?}     -> cb(AuditResult)  [tabletAuditCatalog -- catalogName MUST be an exact key of server/admin.lua's own CATALOG_AUDIT_SOURCES (certTiers/permissionKeys/xpTiers/shopItems/shopLocations/k9Profiles/runtimeOverrides/tabletThemes); forwarded VERBATIM, never whitelist-checked a second time here -- same THE SECURITY RULE as tablet:auditSearch's own `mode` immediately below, and for the identical reason: that file's own CATALOG_AUDIT_SOURCES lookup is the ONLY real gate, a second copy of its key list here could only drift from it, never make it safer]
        AuditResult = { ok:true, rows:table, label:string, cap:number, limit?:number, truncated?:boolean } |
                      { ok:false, error:'not_authorized'|'rate_limited'|'invalid_args', message?:string }
        `cap` (server/admin.lua's own HARD_MAX_RESULTS, added in a LATER
        pass than the first five bridges below) is present on every
        success response, including tabletAuditXp's -- a uniform shape
        across all six, even though that one callback takes no `limit` at
        all. `limit`/`truncated` are present on the other five (the ones
        that DO take a `limit`): `limit` is the exact, already-clamped
        value the server actually used, and `truncated` is `true` only when
        the caller's own request exceeded `cap` and was cut down to it --
        see server/admin.lua's own ClampLimit doc comment for the full
        contract these two mirror verbatim. NEVER present on a failure --
        an unauthorized/rate-limited/malformed caller learns nothing new
        from these fields. The first five bridges originally closed the gap
        server/admin.lua's own header once named by name: "no NUI callback
        and no client/tablet.lua change are part of this pass; this is the
        server-side contract a follow-up tablet screen builds against" --
        THIS file is that follow-up (that sentence has since been corrected
        in server/admin.lua's own header to say so). tablet:auditCatalog is
        the SIXTH, closing the identical gap server/admin.lua's own
        CATALOG_AUDIT_SOURCES header named separately, later ("the GAP 2
        read side") -- see this file's own header STATUS UPDATE (later
        pass, 2) note above. Forwarded VERBATIM --
        that file's own CALLBACK SURFACE header states its response shape
        mirrors THIS file's established `{ok, error, message}` convention
        DIRECTLY, so AwaitServerCallback's own synthetic
        `{ok=false, error='timeout'}` (a thrown/unregistered callback)
        already matches without a translator, same as every other
        passthrough bridge above. `rows`'s exact column shape differs PER
        CALLBACK -- see server/admin.lua's own Query* functions
        (QueryCertificationHistory/QueryPartnershipHistory/
        QuerySearchLogBy{Officer,Plate,Person}/Recent/
        QueryProgressionSnapshot/QueryDepartmentRoster) for the
        authoritative column list of each of the first five; tabletAuditCatalog's
        own `rows` shape instead depends on WHICH `catalogName` was
        requested -- see server/admin.lua's own CATALOG_AUDIT_SOURCES table
        and the eight `K9Store.*Audit_GetRecent` accessors it names for the
        authoritative column list per catalog, mirrored one-to-one by
        html/tablet.js's own auditColumnsForCatalog(). This file does not
        reshape or rename a single field for any of the six. `limit` is
        always OPTIONAL: an absent or non-number value is dropped to `nil`
        here (see OptionalNumericLimit below), letting server/admin.lua's own
        ClampLimit apply ITS configured default/hard cap (HARD_MAX_RESULTS
        = 100) rather than this file guessing one. GATING: that file's own
        IsAuthorizedAdmin (job.isboss, job.grade >=
        Config.Departments[job.name].auditGrade, an explicit 'k9.audit'
        permission grant, or high command) is the ONLY real gate,
        re-verified from the caller's own live `source` on every single
        invocation -- same THE SECURITY RULE as every other callback in
        this file.

    Lua -> JS (SendNUIMessage):
      { action = 'tablet:open', data = { capabilities = Config.Permissions,
          strings = BuildTabletStrings() (locales/en.json's `tablet` group -- see LOCALIZATION below),
          requestedView = 'highCommand' | 'auto', -- PRESENTATION HINT ONLY, threaded straight through from the OpenTablet(requestedView) argument the caller passed (see OPENING above -- the ORIGINAL command/item/radial always pass nil, which resolves to 'auto' here). Decides NOTHING by itself: html/tablet.js's loadMyRecord() only switches to the console screen once tablet:requestMyRecord's own viewer fields for THIS caller are known, and it does so via canAccessConsole() (isHighCommand OR an explicit 'k9.audit' grant -- the SAME gate the Console tab itself uses), not isHighCommand alone. 'auto' (every ordinary open) silently leaves a non-qualifying caller on their own record, exactly as tabletRequestMyRecord already returns it; 'highCommand' (the optional, opt-in highCommandCommand shortcut) shows an explicit "you don't have access" notice above that same record instead.
          -- The Block Effect column's 'client_enforced' badge/hint text
          -- (block_client_enforced_badge/_hint) used to be sent as two
          -- STANDALONE fields here, resolved via a dedicated SafeLocale()
          -- helper, specifically to dodge a now-removed hardcoded key count
          -- in tests/tabletlocalization_spec.lua. That blocker is gone, so
          -- both are ordinary TABLET_STRING_KEYS entries now, resolved by
          -- BuildTabletStrings() into `strings` like every other key --
          -- html/tablet.js reads them via its normal S() helper.
          maxXpPerGrant = Config.HighCommand.maxXpPerGrant,
          peds = Config.Peds,               -- shared config, no round trip -- display list only for tablet:assignK9Role's model picker; server/appearance.lua's IsValidPedModelName is the real gate
          specializations = Config.K9Specializations, -- shared config, no round trip -- display list only for the person screen's specialization grant picker (buildCertificationRow); server/certifications/'s GrantSpecialization re-checks this SAME table server-side, the real gate
          themingEnabled = Config.Features.TabletTheming == true, -- UX hint only -- hides the theme editor's Save/Reset controls when off rather than offering ones that would always come back 'feature_disabled'; the CURRENT theme is still fetched/applied for every viewer regardless (tablet:getTheme has no such gate)
          shopLocationsEnabled = Config.Features.K9EquipmentShop == true, -- UX hint only, SAME shape as themingEnabled just above -- shows a disabled-server-wide note on the Shop Locations screen rather than one that would always come back 'feature_disabled'; tablet:equipmentShopGetLocations/Add/Move/RemoveLocation all re-check this live, server-side, regardless of what this flag says
          runtimeControlEnabled = Config.Features.RuntimeFeatureControl == true, -- UX hint only, SAME shape as themingEnabled/shopLocationsEnabled -- runtimeListFeatures/ListTunables have NO such gate server-side (open to any high-command caller regardless), only the four mutating runtimeSet*/Reset* calls actually refuse with `reason='feature_disabled'` when this is off; this page still shows the disabled note and the (read-only) current values regardless
          auditEnabled = Config.Features.AdminAuditCommands == true, -- UX hint only, but UNLIKE the three flags above: server/admin.lua gates its five tabletAudit* callbacks at REGISTRATION TIME behind this same flag, so a query made while it is false hangs until a generic 'timeout' synthesizes, not a clean 'feature_disabled' refusal -- html/tablet.js disables the Audit screen's query controls (and shows a disabled note) whenever this is false, specifically to avoid that confusing dead end
          branding = Config.CommandTablet.branding,  -- shared config, no round trip -- { serverName: string, logo: string (relative to html/), theme: {primaryColor,accentColor,backgroundColor,textColor} }. Owner-supplied server identity (name/logo) PLUS the operator's chosen starting palette for a fresh install -- COSMETIC ONLY, same as tablet:getTheme's own theme, never consulted by any authorization check. html/tablet.js renders `logo` with a `serverName`-text fallback on load failure (never a broken-image icon -- the operator hand-swaps this file and may typo it) and seeds its OWN pre-fetch initial paint from `branding.theme`'s four colours ONLY until the real, authoritative tablet:getTheme response lands (which always wins once it does, same "config is the starting point, the runtime edit wins" precedence server/runtimecontrol.lua's own DEFAULT_THEME->k9_tablet_theme-DB-override chain already establishes for that file's own default).
      } }
      { action = 'tablet:close', data = {} }
      { action = 'tablet:themeUpdated', data = Theme }
        Lua-INITIATED, NOT tied to this player's own tablet being open --
        relayed verbatim from server/runtimecontrol.lua's
        qbx_k9unit:client:themeUpdated broadcast (see that file's own PART 2
        header: "an already-open tablet updates without the viewer having
        to close and reopen it"), which fires for EVERY connected client on
        every successful SetTheme/ResetTheme, not only the officer who
        triggered it. This file registers that event UNCONDITIONALLY (not
        only while tabletOpen) and does nothing more than relay it into the
        SAME SendNUIMessage channel tablet:open/tablet:close already use --
        html/tablet-bridge.js's existing `/^tablet:/` relay picks it up with
        no further change on that file's side; html/tablet.js's own header
        documents what it does with a push arriving while hidden.
      { action = 'tablet:equipmentShopLocationsUpdated', data = table<string,ShopLocation> }
        Lua-INITIATED, SAME shape/posture as tablet:themeUpdated immediately
        above -- relayed verbatim from server/equipmentshop.lua's
        qbx_k9unit:client:equipmentShopLocationsUpdated broadcast (that
        file's own header: "an already-connected player's own shop-ped
        thread AND any already-open tablet screen updates live"), fired for
        EVERY connected client on every successful Add/Move/RemoveLocation.
        client/equipmentshop.lua ALSO listens for this exact event
        independently (to respawn/reposition shop peds) -- AddEventHandler
        supports any number of handlers per event name, so this is a
        second, additive listener, not a replacement for that one.
      { action = 'tablet:featureBlocksSync', data = string[] }
        THIS PASS (focus-and-state audit finding #4) -- Lua-INITIATED, NOT
        tied to this player's own tablet being open, SAME registration
        posture as tablet:themeUpdated -- relayed verbatim from
        server/permissions.lua's own qbx_k9unit:client:featureBlocksSync
        push (that file's own header "FEATURE-BLOCK PUSH": fires ONLY at
        the one affected citizenid's own connection -- join/reconnect,
        server-restart backfill, or a `block.<Name>` grant/revoke against
        THAT citizenid -- never a broadcast). `data` is the raw array of
        currently-blocked feature-name strings client/featureblocks.lua's
        own twelve-feature CLIENT_ENFORCED_FEATURES catalog already
        consumes independently (a SECOND, additive listener on the same
        server event, not a replacement). html/tablet.js's own
        handleFeatureBlocksSync() does not read this payload at all --
        THE TABLET IS A VIEW, IT DECIDES NOTHING -- it only uses the
        push's ARRIVAL as a cue to re-fetch tablet:requestMyRecord (the
        SAME "re-pull the source of truth, never patch state from a
        payload" posture refreshPersonAndSelf() already establishes), so a
        viewer whose own block set just changed sees their Home/My Record
        screens' abilities list catch up live instead of staying stale
        until their next full close/reopen.
        STILL OPEN, REPORTED, NOT BUILT THIS PASS: this closes the
        FEATURE-BLOCK half of "the viewer's entitlements changed under an
        open tablet" -- it does NOT address a JOB CHANGE (e.g. losing high
        command mid-session), because no server-side push for that exists
        yet. See this pass's own report for the proposed contract
        (piggybacking on the existing, extensively-consumed
        QBCore:Server:OnJobUpdate handler server/certifications/
        already owns) rather than this file inventing one unilaterally.

    LOCALIZATION: `strings` ships the FULL, real, locale()-resolved set --
    EVERY key currently in html/tablet.js's own DEFAULT_STRINGS, one-for-
    one (deliberately not stated as a literal count here -- that number
    grows every time either file gains a string, and a hardcoded count in
    a comment is just a future lie waiting to happen; see
    tests/tabletlocalization_spec.lua's own "WHY THERE IS NO HARDCODED KEY
    COUNT HERE ANY MORE" for the identical reasoning applied to that
    spec's own assertions, which are what actually enforces this 1:1
    match -- not this comment), built by BuildTabletStrings() below from
    locales/en.json's `tablet` group (keyed identically to DEFAULT_STRINGS,
    no `tablet.` prefix inside that group). DEFAULT_STRINGS itself is KEPT,
    unchanged, in
    html/tablet.js -- it remains the resilience net for a key this payload
    ever fails to resolve (a misconfigured/hand-edited locale file, or a
    future key added to one side and not the other), never removed just
    because Lua now sends the real thing.
    ======================================================================

    ======================================================================
    FOCUS/CLOSE DISCIPLINE -- first focus-taking surface in this resource.
    A stuck focus locks a player out of their own character with no way
    back except a reconnect. FOUR close paths, ALL funneling through the
    ONE CloseTablet() (the only site that ever calls SetNuiFocus(false,
    false)):
      1. JS calls 'tablet:close' (button, or its own in-iframe Escape
         listener, or html/tablet-bridge.js's independent TOP-DOCUMENT
         Escape listener -- see that file's own header for why it keeps a
         second one).
      2. ESC handled ENTIRELY Lua-side, independent of any NUI callback --
         EnsureTabletWatchThreadRunning() below. A crashed/unresponsive
         tablet page can never fire tablet:close; this is what closes it
         anyway.
      3. Own death -- same thread as ESC. FiveM's respawn REUSES the same
         ped handle (this resource has already shipped this exact bug once
         -- a K9 that died mid-vehicle-load respawned frozen/invisible/
         still-attached, client/vehicle.lua's header), so a focus grab
         would otherwise survive a respawn with nothing to release it.
      4. onResourceStop (this resource only).
    CloseTablet() has NO access/state gate beyond "is it even open" -- the
    "no unbounded trap" rule this codebase applies to every release path.
    ======================================================================

    ======================================================================
    CROSS-RESOURCE FOCUS INTEROP (this pass, focus-and-state audit finding
    #1). PRIOR BEHAVIOUR: OpenTablet() called SetNuiFocus(true, true)
    unconditionally, with no check for whether some OTHER resource already
    held NUI focus (an inventory, a phone, another menu) -- silently
    stealing it -- and CloseTablet() then called SetNuiFocus(false, false)
    unconditionally on the way out, releasing focus GLOBALLY rather than
    returning it to whoever held it before. This is a well-known FiveM
    cross-resource hazard: SetNuiFocus is one flat, engine-global flag, not
    a per-resource stack, so there is no native way to ask "whose focus is
    this" or to hand it back to a specific other resource by name.

    THE JUDGEMENT CALL, spelled out: refusing to open the tablet outright
    whenever IsNuiFocused() is already true was considered and REJECTED as
    the primary fix. It would have been the simpler answer, but it fails
    this file's own "no unbounded trap" rule in spirit -- a player who
    genuinely needs their tablet (the owner's own framing: "a player
    mid-emergency should probably still reach their tablet") would get a
    silent refusal instead, for a condition entirely outside this file's
    control (some OTHER resource's menu, possibly one that never even
    releases its own focus correctly). OpenTablet() therefore still ALWAYS
    opens -- no new gate on the open path at all.

    THE ACTUAL FIX is at CLOSE time, not open time: OpenTablet() now
    captures `IsNuiFocused()` -- was focus ALREADY held by someone else --
    the instant before it calls SetNuiFocus(true, true) itself, into
    `tabletHadForeignFocusOnOpen`, the same single-owner-variable pattern
    `tabletOpen` already establishes for this file's own lifecycle state.
    CloseTablet() then calls SetNuiFocus(true, true) again (RESTORING the
    pre-existing focus, never blanking it) when that was true, or
    SetNuiFocus(false, false) (the original, full release) when it was not
    -- see CloseTablet()'s own updated doc comment. This is the closest
    approximation the engine's own API allows to "give it back": if focus
    was already true before this file ever touched it, the global flag
    simply ends up back at the SAME value it held before OpenTablet() ran,
    rather than being forced to false out from under whoever set it. This
    is NOT a full fix for the underlying ecosystem-wide hazard -- if the
    ORIGINAL holder itself calls SetNuiFocus(false, false) while the K9
    tablet is still open on top of it, that still clears focus for both
    (there is still no real stack) -- but that failure mode already exists,
    symmetrically, for ANY two focus-taking resources on this engine, is
    not introduced by this file, and is not something a single resource
    can fix unilaterally.

    NON-NEGOTIABLE, unchanged: the close path stays completely
    unconditional. `tabletHadForeignFocusOnOpen` only changes WHICH two
    boolean arguments CloseTablet()'s one SetNuiFocus call passes -- it
    never skips that call, never adds a new guard in front of it, and
    every one of the four close paths above still funnels through the same
    unconditional CloseTablet().

    ANOTHER DISCLOSED RESIDUAL LIMITATION, named explicitly rather than
    left implicit: if the ORIGINAL foreign focus-holder itself has since
    STOPPED (crashed, was stopped, or otherwise went away) without ever
    calling its own SetNuiFocus(false, false) while this file's tablet was
    open on top of it, CloseTablet() restoring SetNuiFocus(true, true)
    hands focus back to a resource that is no longer there to ever release
    it -- there is no native that lets this file ask "is resource X still
    running" without already knowing X's name, which SetNuiFocus's flat,
    ownerless boolean never reveals. This is strictly no worse than the
    PRE-EXISTING behavior for that same scenario (the original
    SetNuiFocus(false, false) already left that stopped resource's own
    focus-consuming page nowhere either way), and it is the deliberately
    ACCEPTED trade-off against the alternative of guessing wrong the other
    direction and stranding a player who legitimately still had a menu
    open underneath.
    ======================================================================

    ======================================================================
    DOWNED-BY-TAKEDOWN ALSO FORCE-CLOSES (this pass, focus-and-state audit
    finding #2). PRIOR BEHAVIOUR: EnsureTabletWatchThreadRunning() below
    force-closed the tablet on IsEntityDead(PlayerPedId()), but a
    non-lethal K9 takedown (client/combat.lua's forceRagdoll, the
    RegisterNetEvent('qbx_k9unit:client:forceRagdoll', ...) handler) never
    kills the target -- SetPedToRagdollWithFall leaves them ragdolled, not
    dead, by design (the whole point of a NON-lethal takedown) -- so
    IsEntityDead stayed false throughout, and a K9-taken-down player kept
    their tablet open (and NUI focus) while genuinely unable to act, the
    exact same "cannot act" condition death already force-closes for.

    DECISION: yes, this inconsistency is closed -- a player who cannot act
    should not keep sitting on an open, focus-holding tablet either way,
    death or takedown, and there is no reason the two should behave
    differently. THE SIGNAL USED IS THE EXISTING ONE, not a new one:
    client/combat.lua already tracks whether THIS client is currently the
    TARGET of an active forced ragdoll in its own file-local
    `ActiveForcedRagdoll` state (set the instant forceRagdoll's own
    RegisterNetEvent handler fires, cleared on endForceRagdoll or its own
    maintenance-thread deadline) -- exactly the "am I currently downed via
    non-lethal takedown" signal server/combat.lua's own IsTargetDowned
    header already reasons about from the SERVER side. Rather than this
    file re-deriving that state a second way (a second, driftable source of
    truth), client/combat.lua now exposes a narrow, read-only
    IsLocalPlayerForceRagdolled() resource-global (see that function's own
    doc comment) -- the SAME seam-opening precedent this file's own header
    already cites for FindNearestLeashCandidate/FindNearestPartnerCandidate:
    open a seam in the file that owns the state, never duplicate the check.
    Guarded here with `type(fn) == 'function'` regardless (client/combat.lua
    returns early, defining nothing, when NONE of BiteAndHold/
    NonLethalTakedown/PropDragging are enabled -- this is not optional, same
    reasoning as every other cross-file `type(fn) == 'function'` guard in
    this file). NOT extended to ActiveBiteHold (being bitten-and-held) --
    out of scope for this pass, flagged in this pass's own report, not
    fixed here.
    ======================================================================

    ======================================================================
    XP-RANK EDITOR (owner-directed "set experience level for each rank up"
    pass, server/xptiers.lua):
      tablet:xpTiersList {}                                       -> cb({ok,tiers?,error?})   [high command -- server/xptiers.lua]
      tablet:xpTiersUpsert {ordinal,xp,label,speedMultiplier,scentRangeMultiplier,medkitCooldownMultiplier?,badge?} -> cb({ok,tiers?,warning?,error?})
        Same TranslateReasonResult bridge as the theme/cert-tier/permission-
        key callbacks above -- server/xptiers.lua's own header states its
        response shape mirrors server/certtiers.lua's own convention
        exactly. `tiers` (both calls) is the FULL, current, live ladder
        (four entries as shipped -- this pass edits existing ranks only,
        never adds/removes/reorders one, see that file's own header
        "SCOPE DECISION"); each entry's `xpLocked` flag (true for rank 1
        only) tells this page which one field to render read-only. A
        successful edit's `warning` (non-optional whenever at least one
        currently-connected K9 was just re-ranked LOWER by this exact edit)
        MUST be surfaced prominently, identical posture to certTiersReorder's
        own warning above -- see server/xptiers.lua's own header "THE
        ALREADY-PROMOTED PLAYER" for why this can happen from a single
        threshold edit (no reorder concept exists for this ladder at all).
        `base_tier_xp_fixed` (rank 1 only) is a REFUSAL ("cannot, and here
        is why" -- rank 1 must always be exactly 0 XP), not a generic
        failure -- html/tablet.js's own error-text mapping should give it
        distinct copy, the same way certTierErrorText() already does for
        'tier_in_use'/'protected_tier'.
    ======================================================================

    ======================================================================
    K9 INDIVIDUAL OVERRIDES (owner-directed "god over that tablet with
    full customization over everything related to that K9" pass,
    server/k9profiles.lua):
      tablet:k9ProfilesList {}                                     -> cb({ok,overrides?,error?})   [high command only]
        `overrides`: array of every citizenid with a LIVE override --
        { citizenid, speedMultiplier?, scentRangeMultiplier?,
        medkitCooldownMultiplier?, note? }. A field absent from one entry
        means that field defers to the citizenid's own XP tier.
      tablet:k9ProfileGet {citizenid}                              -> cb({ok,citizenid?,tierLabel?,effective?,override?,error?})
        `effective`: { speedMultiplier, scentRangeMultiplier,
        medkitCooldownMultiplier?, overridden: {speedMultiplier,
        scentRangeMultiplier,medkitCooldownMultiplier} (booleans) } -- the
        REAL composed values (tier, then override on top -- see that
        file's own header "RESOLUTION ORDER"). `override` is the raw
        stored row (or null if this citizenid has none yet).
      tablet:k9ProfileUpsert {citizenid,speedMultiplier?,scentRangeMultiplier?,medkitCooldownMultiplier?,note?} -> cb({ok,citizenid?,effective?,override?,warning?,error?})
        Every field independently optional -- omitted means "leave
        whatever this citizenid's override already had for that field
        alone," never "clear it." `speedMultiplier`/`scentRangeMultiplier`
        must be in (0, 3.0]; `medkitCooldownMultiplier` must be in
        (0, 1.0] (it can only shorten the cooldown, never lengthen it
        past the tier default); `note` is a plain, markup-free string,
        1-120 characters. `warning` is set (and MUST be surfaced, same
        posture as xpTiersUpsert's own) whenever the edit targets the
        ACTING officer's own citizenid, so a high-command account tuning
        their own dog is disclosed loudly rather than folded into an
        identical-looking ordinary edit.
      tablet:k9ProfileReset {citizenid}                            -> cb({ok,citizenid?,effective?,error?})
        Clears every override field for this citizenid in one action
        (there is no per-field reset) -- idempotent, a citizenid with no
        override already succeeds with no error.
        Same TranslateReasonResult bridge as every catalog above.
        UPDATE (coder-backend, same day): server/progression.lua now
        consults `GetK9EffectiveMultipliers(citizenid)` from both
        GetXPTierMedkitCooldownMs (medkit cooldown) and
        BuildEffectiveTierSnapshot/PushTierSnapshot (the
        'qbx_k9unit:client:xpTierChanged' push client/progression.lua's
        own K9MoveRateModifiers consumes for speed/scent range) -- verified
        directly against that file's source, not assumed. An override
        saved here IS a real, live gameplay change, not merely stored.
        ONE REMAINING CAVEAT, still true: k9ProfileUpsert/k9ProfileReset
        do NOT themselves push a fresh snapshot to an already-connected
        target -- the new value takes effect the next time that
        citizenid's tier is naturally re-resolved (earning XP,
        reconnecting, or this resource's own onResourceStart backfill
        loop), not necessarily the instant this callback returns for a
        currently-connected K9. html/tablet.js's own screen states this
        plainly rather than imply an instantaneous effect this callback
        chain does not have.
    ======================================================================

    FILE-TO-FILE CONTRACT: exposes OpenTablet()/CloseTablet() as resource-
    globals (both already allowlisted) -- CloseTablet() deliberately IS
    global, not file-private, so no future call site is ever tempted to
    call SetNuiFocus a second time itself; it should always call this
    instead. Calls client/main.lua's HasK9Access()/CanShowK9UI()/
    DenyK9UIAccess() and client/radial.lua's FindNearestLeashCandidate()/
    FindNearestPartnerCandidate() (both guarded with
    `type(fn) == 'function'`).
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
if not Config.Features.CommandTablet then return end

-- ----------------------------------------------------------------------
-- PART 0 -- open/close + focus lifecycle
-- ----------------------------------------------------------------------

local tabletOpen = false -- single source of truth for CloseTablet()'s no-op guard and the watch thread's loop condition

--- Whether some OTHER resource already held NUI focus the instant BEFORE
--- OpenTablet() last grabbed it -- captured fresh on every real open (see
--- OpenTablet() below), consulted ONLY by CloseTablet() to decide which
--- two SetNuiFocus arguments to pass on the way out. See this file's
--- header "CROSS-RESOURCE FOCUS INTEROP" for the full reasoning -- this is
--- the "give it back rather than blank it" half of that fix, never a gate
--- on whether the tablet opens or closes.
local tabletHadForeignFocusOnOpen = false

--- Pcall-wrapped, fail-closed wrapper around every server callback this
--- file awaits. `lib.callback.await` THROWS (never returns nil) on a
--- timeout or an unregistered callback -- see client/main.lua's
--- HasK9Access() doc comment for the exact ox_lib/FiveM source citation;
--- duplicated here rather than shared, matching this codebase's per-file
--- convention for this exact guard. Every caller gets back a plain table
--- either way, never a propagating error that could abort a
--- RegisterNUICallback mid-way and leave its `cb` uninvoked (client/hud.lua:
--- "an uninvoked NUI callback hangs the frontend's fetch promise forever").
--- The synthetic failure shape (`error = 'timeout'`) matches html/tablet.js's
--- OWN `{ ok:false, error, message? }` contract directly -- every endpoint
--- that forwards this result verbatim needs no further translation.
--- @param name string
--- @return table result -- always a table
local function AwaitServerCallback(name, ...)
    local ok, result = pcall(lib.callback.await, name, K9_CALLBACK_TIMEOUT_MS, ...)
    if not ok or type(result) ~= 'table' then
        return { ok = false, error = 'timeout' }
    end
    return result
end

--- Every DEFAULT_STRINGS key from html/tablet.js, in that file's own
--- declared order -- kept as an explicit list (rather than derived from
--- anything at runtime) so BuildTabletStrings() below and
--- tests/tabletlocalization_spec.lua both iterate the SAME set, and so a
--- key added to html/tablet.js without a matching addition here/in
--- locales/en.json's `tablet` group is caught by that spec instead of
--- silently falling back to English forever.
---
--- DELIBERATELY NOT STATING A KEY COUNT HERE. An earlier version of this
--- comment stated an exact total, plus a narrative about which keys "this
--- pass" had just added. By the 2026-08-31 watchdog pass the stated total
--- was wrong by a factor of four (it read a few hundred; the real figure
--- was over a thousand), and the narrative had long since stopped meaning
--- anything. A count
--- maintained by hand next to a list that grows every pass is a comment
--- that lies by default, so it is gone rather than merely refreshed. The
--- spec named above is the count's real keeper: it compares this list
--- against html/tablet.js's DEFAULT_STRINGS as SETS and fails on any
--- disagreement, which is the property that actually matters. To see the
--- current number, count the list -- do not re-enshrine one here.
local TABLET_STRING_KEYS = {
    'title', 'close_label', 'tab_console', 'tab_my_record', 'loading',
    'error_generic', 'error_not_authorized', 'error_timeout', 'error_network',
    -- K9 HIGH COMMAND TABLET COMMAND (this pass, config.lua's
    -- Config.CommandTablet.highCommandCommand) -- the ONE new UI-chrome
    -- string this pass adds. Shown by html/tablet.js's loadMyRecord() when
    -- someone who is NOT high command types the new shortcut command:
    -- server/tablet.lua's tabletRequestMyRecord still resolves and returns
    -- their own record exactly as it does for the ordinary command (this
    -- flag changes presentation only, never authorization -- see this
    -- file's OPENING section), so they still see their own record beneath
    -- this notice rather than a blank or broken screen.
    'high_command_required_notice',
    'retry_label', 'refresh_label', 'empty_roster',
    'column_name', 'column_citizenid', 'column_department', 'column_certified',
    'column_xp', 'column_handler_xp', 'column_actions', 'certified_yes', 'certified_no',
    -- ONLINE PLAYERS LIST (owner-directed, 2026-08-26: "make the add
    -- permission section... where its a list when i choose a player id")
    -- -- see html/tablet.js's buildOnlinePlayersSection() for the full
    -- contract this new entry point implements.
    'online_players_heading',     'online_players_empty', 'online_players_opening_label',
    'column_server_id', 'column_job', 'column_k9_access',
    'online_k9_access_yes', 'online_k9_access_no',
    'certify_label', 'certify_as_label', 'certify_as_handler_option', 'certify_as_k9_option_template', 'certify_as_hint', 'decertify_label', 'confirm_label', 'grant_label',
    'revoke_label', 'block_label', 'unblock_label', 'manage_label',
    -- Block Effect column (html/tablet.js's featureBlockEnforcement()) --
    -- THE HONESTY REQUIREMENT: server/tablet.lua's own `blocked`/`state`
    -- fields never told the operator whether a block does anything; these
    -- four keys are this page's plain-language rendering of the new,
    -- REQUESTED `blockEnforcement` field (see html/tablet.js's own
    -- PersonFeaturesResult doc comment for the full three-state contract
    -- and why it is never guessed client-side).
    'column_block_effect', 'block_enforced_badge', 'block_not_yet_enforced_badge',
    'block_not_yet_enforced_hint', 'block_not_enforceable_note',
    -- CLIENT-ENFORCED badge/hint (html/tablet.js's clientEnforcedBadgeText()/
    -- clientEnforcedHintText()) -- folded into the ordinary TABLET_STRING_KEYS/
    -- DEFAULT_STRINGS mechanism now that tests/tabletlocalization_spec.lua no
    -- longer hardcodes an exact key count (see that file's own "WHY THERE IS
    -- NO HARDCODED KEY COUNT ANY MORE"). These two used to be sent as two
    -- STANDALONE OpenTablet() fields via the now-removed SafeLocale() helper
    -- specifically to avoid tripping that count; that blocker is gone, so
    -- they are ordinary `strings` entries like every other key here.
    'block_client_enforced_badge', 'block_client_enforced_hint',
    'back_label', 'givexp_label', 'givexp_placeholder', 'givexp_max_hint',
    'self_grant_disabled_title', 'truncated_notice', 'action_working',
    'action_failed', 'action_succeeded', 'no_certifications',
    'my_certifications_heading', 'my_xp_heading', 'my_abilities_heading',
    -- DOMAIN GROUPING (owner: "more color based on all scent stuff
    -- vehicle related is more text based") -- see html/tablet.js's
    -- buildMyFeaturesList()/server/tablet.lua's FEATURE_DOMAINS for the
    -- full mechanism these five keys support.
    'feature_group_scent_heading', 'feature_group_scent_hint', 'feature_group_vehicle_heading',
    'feature_group_other_heading', 'feature_vehicle_sentence_template',
    'feature_filter_label', 'feature_filter_showing_template',
    'feature_filter_clear_label', 'feature_filter_no_matches',
    'feature_group_row_count_template',
    -- FULL DOMAIN GROUPING (owner-directed, 2026-08-26: "same with
    -- features and sub features") -- one heading per remaining
    -- server/tablet.lua FEATURE_DOMAINS group; see html/tablet.js's own
    -- FEATURE_DOMAIN_ORDER for the full, stable rendering order these
    -- belong to.
    'feature_group_search_heading', 'feature_group_vision_heading',
    'feature_group_combat_heading', 'feature_group_movement_heading',
    'feature_group_wellbeing_heading', 'feature_group_progression_heading',
    'feature_group_gear_heading', 'feature_group_training_heading',
    'feature_group_admin_heading', 'feature_group_integration_heading',
    'no_abilities', 'search_features_placeholder', 'state_global_off',
    'state_blocked', 'state_not_certified', 'state_requires_grant_missing',
    'state_available',
    -- DISPLAY-GAP FIX (this pass) -- subtle "why can they do that" marker
    -- for a PersonFeaturesResult row available solely via high command --
    -- see html/tablet.js's appendViaHighCommandMarker() for the full
    -- contract.
    'feature_via_high_command_marker', 'feature_via_high_command_hint',
    'feature_column', 'status_column',
    'person_features_heading', 'person_capabilities_heading',
    'capability_no_description', 'capability_self_grant_disabled_title',
    'capability_rate_limited_wait_title',
    'person_certifications_heading', 'person_xp_heading', 'xp_tier_unknown',
    'person_handler_xp_heading', 'person_handler_xp_untracked',
    'use_label', 'not_available_short', 'opening_person',
    'person_no_record_found',
    'open_by_id_label', 'find_person_label', 'find_person_placeholder', 'find_person_hint', 'find_person_hint_id_only', 'roster_results_heading', 'open_my_own_record_label', 'open_my_own_record_hint',
    -- Workflow audit finding #1/#2, 2026-08-26 (html/tablet.js's
    -- canOpenPersonRecord()/buildConsoleScreen() narrowed rendering, and
    -- the "open by exact citizen ID" box's own new explanatory hint --
    -- see each string's own doc comment in DEFAULT_STRINGS for the full
    -- writeup).
    'console_person_only_notice',
    'role_heading', 'role_assign_label',
    'role_assign_hint', 'role_revert_label', 'role_revert_hint',
    'role_no_peds_configured',
    -- Rank/department + partnership (person screen, read-only -- owner-
    -- directed "roster panel shows everything about a person" pass). See
    -- html/tablet.js's buildRankSection/buildPartnershipSection doc
    -- comments for exactly what each does and does not do -- in
    -- particular, no promotion control exists anywhere in this resource.
    'person_rank_heading', 'rank_department_label', 'rank_grade_label',
    'rank_is_boss_badge', 'rank_unavailable', 'rank_change_note',
    'person_partnership_heading', 'partnership_none', 'partnership_partner_label',
    'partnership_role_label', 'partnership_role_value_k9', 'partnership_role_value_handler',
    'tab_theme', 'theme_heading',
    'theme_primary_label', 'theme_accent_label', 'theme_background_label',
    'theme_text_label', 'theme_density_label', 'theme_density_comfortable',
    'theme_density_compact', 'theme_header_title_label', 'theme_save_label',
    'theme_reset_label', 'theme_disabled_note', 'theme_field_invalid',
    'cert_tiers_heading', 'cert_tiers_add_label',
    'cert_tier_key_label', 'cert_tier_key_placeholder', 'cert_tier_label_label',
    'cert_tier_capabilities_label', 'cert_tier_no_capabilities',
    'cert_tier_save_label', 'cert_tier_cancel_label', 'cert_tier_edit_label',
    'cert_tier_delete_label', 'cert_tier_move_up_label', 'cert_tier_move_up_title',
    'cert_tier_move_down_label', 'cert_tier_move_down_title', 'column_position',
    'column_key', 'column_label', 'column_capabilities', 'cert_tier_error_denied',
    'cert_tier_error_rate_limited', 'cert_tier_error_invalid_key',
    'cert_tier_error_invalid_label', 'cert_tier_error_invalid_capabilities',
    'cert_tier_error_busy', 'cert_tier_error_too_many_tiers',
    'cert_tier_error_unknown_tier', 'cert_tier_error_protected_tier',
    'cert_tier_error_ordinal_write_failed', 'cert_tier_error_capability_write_failed',
    'shop_item_error_sort_order_write_failed',
    'cert_tier_error_tier_in_use',
    -- The OTHER referrer a tier delete can be blocked by -- a supply shop
    -- item requiring the tier (server/certtiers.lua's DeleteTier, commit
    -- a32a554). Deliberately a separate key from cert_tier_error_tier_in_use
    -- immediately above -- see that server-side doc comment for why one
    -- combined count would send the reader to the wrong screen.
    'cert_tier_error_tier_in_use_by_shop_items',
    'cert_tier_error_must_include_every_tier',
    'cert_tier_error_invalid_key_set', 'cert_tier_error_db_error',
    'cert_tier_error_invalid_payload',
    -- Permission-key catalog editing (high command only, sits alongside the
    -- cert-tier screen above) -- see this file's own header NUI CONTRACT
    -- section on the three tablet:permKeys* callbacks.
    'permission_keys_heading', 'permission_keys_add_label',
    'permission_key_key_label', 'permission_key_key_placeholder',
    'permission_key_label_label', 'permission_key_description_label',
    'permission_key_description_placeholder', 'permission_key_save_label',
    'permission_key_cancel_label', 'permission_key_edit_label',
    'permission_key_delete_label', 'permission_key_default_badge',
    'permission_key_retired_badge',
    'column_description', 'permission_key_error_denied',
    'permission_key_error_rate_limited', 'permission_key_error_invalid_key',
    'permission_key_error_invalid_label', 'permission_key_error_invalid_description',
    'permission_key_error_reserved_namespace', 'permission_key_error_busy',
    'permission_key_error_too_many_keys', 'permission_key_error_unknown_key',
    'permission_key_error_db_error', 'permission_key_error_invalid_payload',
    -- K9 Supply Shop location management (high command only) -- see this
    -- file's own header NUI CONTRACT section on the four
    -- tablet:equipmentShop*Location(s) callbacks.
    'shop_locations_heading', 'shop_locations_disabled_note',
    'shop_locations_empty', 'column_coordinates', 'column_model', 'column_source',
    'source_config', 'source_runtime', 'shop_location_add_here_label',
    'shop_location_add_hint', 'shop_location_label_label', 'shop_location_label_placeholder',
    'shop_location_model_label', 'shop_location_model_placeholder',
    'shop_location_scenario_label', 'shop_location_scenario_placeholder',
    'shop_location_save_label', 'shop_location_cancel_label', 'shop_location_edit_label',
    'shop_location_move_here_label', 'shop_location_move_here_hint',
    'shop_location_remove_label', 'shop_location_config_note',
    'shop_location_error_denied', 'shop_location_error_rate_limited',
    'shop_location_error_invalid_coords', 'shop_location_error_invalid_heading',
    'shop_location_error_invalid_model', 'shop_location_error_invalid_scenario',
    'shop_location_error_invalid_label', 'shop_location_error_invalid_key',
    'shop_location_error_invalid_payload', 'shop_location_error_db_error',
    'shop_location_error_feature_disabled',
    -- Runtime feature control + tuning (its own tab, high command only) --
    -- server/runtimecontrol.lua PART 1/1B. Owner's own words: "Lets high
    -- command switch features on and off SERVER-WIDE from the tablet, and
    -- tune numbers live." The five tier labels/descriptions below are this
    -- page's OWN plain-language rendering of that file's `tier` field --
    -- see this file's own NUI CONTRACT note on why the server's raw `note`
    -- prose is never forwarded/rendered verbatim.
    'tab_shop', 'help_tab_shop_desc',
    'tab_guide', 'help_tab_guide_desc',
    'tab_catalogs', 'help_tab_catalogs_desc',
    'tab_runtime_control', 'runtime_control_heading', 'runtime_control_intro',
    'runtime_control_disabled_note', 'runtime_features_heading',
    'runtime_features_empty', 'runtime_tunables_heading', 'runtime_tunables_empty',
    'column_tier', 'column_current_value', 'column_range', 'column_type',
    'runtime_tier_live', 'runtime_tier_live_desc',
    'runtime_tier_onstart', 'runtime_tier_onstart_desc',
    'runtime_tier_rawtoplevel', 'runtime_tier_rawtoplevel_desc',
    'runtime_tier_clientonly', 'runtime_tier_clientonly_desc',
    'runtime_tier_protected', 'runtime_tier_protected_desc',
    'runtime_tier_unaudited', 'runtime_tier_unaudited_desc',
    'runtime_value_on', 'runtime_value_off', 'runtime_overridden_by_at',
    'runtime_feature_toggle_on_label', 'runtime_feature_toggle_off_label',
    'runtime_feature_reset_label',
    'runtime_error_denied', 'runtime_error_rate_limited', 'runtime_error_db_error',
    'runtime_feature_error_invalid_feature', 'runtime_feature_error_invalid_value',
    -- LOCKOUT-RISK CONFIRMATION (this pass) -- server/runtimecontrol.lua's
    -- `lockoutRisk`/`sessionOnly`/`lockoutWarning` fields (runtimeListFeatures)
    -- and the `confirm` argument (runtimeSetFeature/runtimeResetFeature),
    -- previously landed server-side with zero reads on this page -- see
    -- this file's own NUI CONTRACT note "THE LOCKOUT-RISK CONFIRMATION
    -- GATE" above. `runtime_feature_error_confirmation_required` is this
    -- page's own copy for `reason='confirmation_required'` -- NEVER the
    -- server's raw `lockoutWarning` text, which is instead shown VERBATIM
    -- (never paraphrased) in html/tablet.js's own confirmation panel.
    'runtime_config_only_note',
    'runtime_lockout_legend',
    'runtime_lockout_badge', 'runtime_lockout_row_hint',
    'runtime_session_only_badge', 'runtime_session_only_hint',
    'runtime_lockout_confirm_heading', 'runtime_lockout_confirm_instruction',
    'runtime_lockout_confirm_input_label', 'runtime_lockout_confirm_input_placeholder',
    'runtime_lockout_confirm_button', 'runtime_lockout_cancel_label',
    'runtime_feature_error_confirmation_required',
    'runtime_tunable_edit_label', 'runtime_tunable_save_label',
    'runtime_tunable_cancel_label', 'runtime_tunable_reset_label',
    'runtime_tunable_type_integer', 'runtime_tunable_type_decimal',
    'runtime_tunable_error_invalid_key', 'runtime_tunable_error_out_of_range',
    'runtime_tunable_error_not_integer', 'runtime_tunable_error_not_a_number',
    -- RUNTIME TUNABLE ROW READABILITY (this pass): the Runtime Control ->
    -- Settings table used to show ONLY a tunable's raw Config path as its
    -- one and only label -- see server/runtimecontrol.lua's own
    -- GetTunableDescription for the per-tunable plain-English text this
    -- fixes it with (a separate, DYNAMIC locale lookup, NOT a
    -- TABLET_STRING_KEYS entry -- there are 100+ of those, one per
    -- tunable, fetched the same way runtime_lockout_warning_*/
    -- runtime_active_usage_warning_* already are). This ONE key is
    -- different: a fixed column header, same static-string shape as every
    -- other TABLET_STRING_KEYS entry, so it belongs here.
    'runtime_tunable_column_setting',
    -- K9 Audit Trail viewer (its own tab -- see this file's own NUI
    -- CONTRACT section on tablet:auditCert/Partner/Search/Xp/Dept). LANDED
    -- (verified directly against locales/en.json's `tablet` group): this
    -- comment used to say these keys were NOT YET present as of the pass
    -- that added them, flagged to that file's owner -- they have since
    -- been added, so BuildTabletStrings() now resolves every one of them
    -- for real instead of falling through to html/tablet.js's own
    -- DEFAULT_STRINGS fallback.
    'tab_audit', 'audit_heading', 'audit_intro', 'audit_disabled_note',
    'audit_mode_cert', 'audit_mode_partner', 'audit_mode_search', 'audit_mode_xp',
    'audit_mode_dept', 'audit_citizenid_label', 'audit_citizenid_placeholder',
    'audit_department_label', 'audit_department_placeholder', 'audit_department_hint',
    'audit_search_mode_label', 'audit_search_mode_officer', 'audit_search_mode_plate',
    'audit_search_mode_person', 'audit_search_mode_recent', 'audit_value_label',
    'audit_value_placeholder_citizenid', 'audit_value_placeholder_plate',
    'audit_limit_label', 'audit_run_label', 'audit_result_empty', 'audit_result_prompt',
    -- 'audit_truncated_notice' (this LATER pass, cap/limit/truncated added
    -- to server/admin.lua's tabletAudit* responses): {requested}/{shown}
    -- placeholders filled in by html/tablet.js's own formatTemplate().
    'audit_truncated_notice',
    'audit_error_not_authorized', 'audit_error_rate_limited', 'audit_error_invalid_args',
    'audit_boolean_yes', 'audit_boolean_no', 'audit_na', 'column_active',
    'column_granted_by', 'column_granted_at', 'column_revoked_by', 'column_revoked_at',
    'column_k9', 'column_handler', 'column_established_by', 'column_established_at',
    'column_ended_by', 'column_ended_at', 'column_searched_at', 'column_searcher',
    'column_searcher_job', 'column_target_type', 'column_target', 'column_result',
    'column_weight', 'column_alert_tier', 'column_audit_xp', 'column_updated_at',
    -- 'catalog' -- the SIXTH Audit Trail mode (this pass), bridging
    -- server/admin.lua's own 'qbx_k9unit:server:tabletAuditCatalog' (see
    -- this file's own NUI CONTRACT note and header STATUS UPDATE (later
    -- pass, 2)). 'audit_mode_catalog'/'audit_catalog_label' are the only
    -- two brand-new strings this mode needs beyond the shared audit_*
    -- chrome above -- every column header its 8 possible catalogs need is
    -- either a brand-new 'column_*' key immediately below (the concepts
    -- genuinely new to this mode: action/detail/changed-by/changed-at/
    -- override-key/kind/old-new-value/heading) or an EXISTING key already
    -- serving the exact same field elsewhere on this page (cert_tier_key_label,
    -- permission_key_key_label, shop_item_key_label, column_rank,
    -- column_citizenid, column_coordinates, shop_location_model_label,
    -- shop_location_scenario_label, shop_location_label_label,
    -- theme_primary_label, theme_accent_label, theme_background_label,
    -- theme_text_label, theme_density_label, theme_header_title_label,
    -- cert_tiers_heading, permission_keys_heading, xp_tiers_heading,
    -- shop_items_heading, shop_locations_heading, k9_profiles_heading,
    -- runtime_control_heading, theme_heading -- see
    -- html/tablet.js's own auditColumnsForCatalog()/AUDIT_CATALOG_NAMES
    -- for exactly which key backs which column/option), so none of those
    -- are duplicated here.
    'audit_mode_catalog', 'audit_catalog_label', 'column_action', 'column_detail',
    'column_changed_by', 'column_changed_at', 'column_old_value', 'column_new_value',
    'column_kind', 'column_override_key', 'column_heading',
    -- CERTIFICATION TIER / RENEWAL / SPECIALIZATION (this pass) -- the
    -- person screen's certification row grows a tier control, a renew
    -- button, and a specializations sub-list (buildCertificationRow).
    -- LANDED (verified directly against locales/en.json's `tablet` group,
    -- same as the 'tab_audit'/'audit_*' block immediately above): these 7
    -- keys used to be NOT YET present as of the pass that added them,
    -- flagged to that file's owner -- they have since been added, so
    -- BuildTabletStrings() now resolves every one of them for real.
    'tier_label', 'tier_set_label', 'renew_label', 'specializations_heading',
    'no_specializations', 'expires_label', 'expired_badge',
    -- XP RANK EDITOR (owner-directed "...set experience level for each
    -- rank up" pass, server/xptiers.lua) -- sits alongside the
    -- cert-tier/permission-key/shop-location/runtime-control tabs above.
    -- LANDED (verified directly against locales/en.json's `tablet` group,
    -- same as the 'tab_audit'/'audit_*' and 'tier_label'..'expired_badge'
    -- blocks above): these 35 keys used to be NOT YET present as of the
    -- pass that added them, flagged to that file's owner -- they have
    -- since been added, so BuildTabletStrings() now resolves every one of
    -- them for real.
    'xp_tiers_heading', 'xp_tiers_empty', 'column_rank',
    'column_xp_threshold', 'column_speed_multiplier', 'column_scent_range_multiplier',
    'column_medkit_cooldown_multiplier', 'column_badge', 'xp_tier_edit_label',
    'xp_tier_save_label', 'xp_tier_cancel_label', 'xp_tier_xp_label',
    'xp_tier_xp_locked_hint', 'xp_tier_label_label', 'xp_tier_speed_multiplier_label',
    'xp_tier_scent_range_multiplier_label', 'xp_tier_medkit_cooldown_multiplier_label',
    'xp_tier_medkit_cooldown_multiplier_placeholder', 'xp_tier_badge_label',
    'xp_tier_badge_placeholder', 'xp_tier_error_denied', 'xp_tier_error_rate_limited',
    'xp_tier_error_busy', 'xp_tier_error_invalid_ordinal', 'xp_tier_error_invalid_xp',
    'xp_tier_error_base_tier_xp_fixed', 'xp_tier_error_invalid_label',
    'xp_tier_error_invalid_speed_multiplier', 'xp_tier_error_invalid_scent_range_multiplier',
    'xp_tier_error_invalid_medkit_cooldown_multiplier', 'xp_tier_error_invalid_badge',
    'xp_tier_error_invalid_order', 'xp_tier_error_db_error', 'xp_tier_error_invalid_payload',
    -- K9 INDIVIDUAL OVERRIDES (owner-directed "god over that tablet with
    -- full customization over everything related to that K9" pass,
    -- server/k9profiles.lua) -- html/tablet.js's own
    -- buildK9ProfilesScreen(). Sits alongside the XP Rank Editor block
    -- immediately above (this pass composes ON TOP OF that ladder, see
    -- server/k9profiles.lua's own header "RESOLUTION ORDER").
    'k9_profiles_intro', 'k9_profiles_list_heading',
    'k9_profiles_empty', 'column_note',
    'k9_profile_manage_label', 'k9_profile_field_not_overridden', 'k9_profile_tier_label_prefix', 'k9_profile_effective_speed_prefix',
    'k9_profile_effective_scent_prefix', 'k9_profile_effective_medkit_prefix', 'k9_profile_overridden_suffix', 'k9_profile_from_tier_suffix',
    'k9_profile_not_yet_live_hint', 'k9_profile_speed_multiplier_label', 'k9_profile_speed_multiplier_hint', 'k9_profile_scent_range_multiplier_label',
    'k9_profile_scent_range_multiplier_hint', 'k9_profile_medkit_cooldown_multiplier_label', 'k9_profile_medkit_cooldown_multiplier_hint', 'k9_profile_note_label',
    'k9_profile_note_hint', 'k9_profile_blank_means_no_override_placeholder', 'k9_profile_field_clear_hint', 'k9_profile_save_label',
    'k9_profile_reset_label', 'k9_profile_close_label', 'k9_profile_error_denied', 'k9_profile_error_rate_limited',
    'k9_profile_error_busy', 'k9_profile_error_invalid_citizenid', 'k9_profile_error_invalid_payload', 'k9_profile_error_no_fields_to_set',
    'k9_profile_error_invalid_speed_multiplier', 'k9_profile_error_invalid_scent_range_multiplier', 'k9_profile_error_invalid_medkit_cooldown_multiplier', 'k9_profile_error_invalid_note',
    'k9_profile_error_too_many_overrides', 'k9_profile_error_db_error',
    -- STAMINA (owner-directed, this pass: "be able to make the stamina as
    -- high as i want and be able to make the stamina as high as i want or
    -- permanant") -- see html/tablet.js's buildK9ProfileStaminaField() for
    -- the full "0 means permanent, drain-rate-not-a-stat" contract these
    -- support. Persistence wording is NOT in this list: it comes from
    -- the server's own conditional staminaPersistenceWarning field
    -- (present only on a memory-only server, post migration 0021), never
    -- a client-hardcoded string.
    'column_stamina_drain', 'k9_profile_effective_stamina_prefix', 'k9_profile_speed_clamp_note',
    'k9_profile_stamina_label', 'k9_profile_stamina_hint',
    'k9_profile_stamina_permanent_checkbox_label', 'k9_profile_stamina_permanent_label',
    'k9_profile_stamina_drain_rate_template', 'k9_profile_error_invalid_stamina',
    -- PERSON SCREEN EMBED (coordinator-directed: "one place that acts on
    -- a citizenid, extended, never forked") -- see html/tablet.js's own
    -- buildPersonK9ProfileSection().
    'k9_profile_person_section_heading', 'k9_profile_person_section_intro',
    -- K9 SUPPLY SHOP ITEM CATALOG (owner-directed "give high command real
    -- control over the equipment shop" pass, server/equipmentshop.lua's
    -- own "EQUIPMENT SHOP ITEM CATALOG" section) -- sits alongside the
    -- shop_location_*/tab_shop_locations keys above, same "K9 Supply
    -- Shop" domain, split into its own tab since WHICH items are sold is
    -- a separate server-side authorization key from WHERE the shop ped
    -- stands. LANDED (verified directly against locales/en.json's
    -- `tablet` group, same as the 'tab_audit'/'audit_*' and
    -- 'tab_xp_tiers'/'xp_tier_*' blocks above): these 44 keys used to be
    -- NOT YET present as of the pass that added them, flagged to that
    -- file's owner -- they have since been added, so BuildTabletStrings()
    -- now resolves every one of them for real.
    'shop_items_heading', 'shop_items_add_label', 'shop_items_empty',
    'column_price', 'column_currency', 'column_required_tier', 'column_required_specialization',
    'shop_item_key_label', 'shop_item_key_placeholder', 'shop_item_price_label',
    'shop_item_label_label', 'shop_item_label_placeholder', 'shop_item_currency_label',
    'shop_item_currency_placeholder', 'shop_item_required_tier_label',
    'shop_item_required_specialization_label', 'shop_item_no_requirement',
    'shop_item_retired_reference_badge',
    'shop_item_save_label', 'shop_item_cancel_label', 'shop_item_edit_label',
    'shop_item_delete_label', 'shop_item_move_up_label', 'shop_item_move_up_title',
    'shop_item_move_down_label', 'shop_item_move_down_title', 'shop_item_price_free_badge',
    'shop_item_currency_default_note', 'shop_item_error_denied', 'shop_item_error_rate_limited',
    'shop_item_error_invalid_payload', 'shop_item_error_invalid_key', 'shop_item_error_invalid_price',
    'shop_item_error_invalid_label', 'shop_item_error_invalid_currency',
    'shop_item_error_invalid_required_tier', 'shop_item_error_invalid_required_specialization',
    'shop_item_error_busy', 'shop_item_error_too_many_items', 'shop_item_error_unknown_item',
    'shop_item_error_must_include_every_item', 'shop_item_error_invalid_key_set',
    'shop_item_error_db_error',
    -- HOME / LANDING VIEW (this pass, owner-directed "restructure the
    -- tablet around WHO IS HOLDING IT... a first-time player who has read
    -- nothing should open this and know what to do within seconds") --
    -- see html/tablet.js's own buildHomeScreen() for the full writeup on
    -- why this is now the DEFAULT screen on open, ahead of every existing
    -- tab, none of which this pass removed or renamed. LANDED (verified
    -- directly against locales/en.json's `tablet` group, same posture as
    -- every other block above): these 22 keys used to be NOT YET present
    -- as of the pass that added them, flagged to that file's owner -- they
    -- have since been added, so BuildTabletStrings() now resolves every
    -- one of them for real.
    'home_welcome_template', 'home_role_high_command', 'home_role_k9',
    'home_role_handler', 'home_role_uncertified', 'home_partnered_badge',
    'home_not_partnered_badge', 'home_certified_count_template',
    'home_quick_actions_heading',
    'home_open_console_label', 'home_open_console_hint', 'home_high_command_heading',
    'home_high_command_hint', 'home_high_command_tabs_pointer',
    -- Workflow audit finding #3, 2026-08-26 -- see
    -- buildHomeHighCommandSignpost()'s own doc comment (html/tablet.js)
    -- for why a non-high-command delegate now gets a description of ONLY
    -- what they actually hold, instead of the full high-command list
    -- above.
    'home_high_command_scope_theme', 'home_high_command_scope_shop_locations',
    'home_high_command_scope_shop_items', 'home_high_command_scope_runtime_control',
    'home_high_command_delegate_hint_template', 'home_high_command_delegate_tabs_pointer',
    'list_join_and',
    'home_no_certification_title', 'home_no_certification_body', 'home_no_certification_next_steps',

    'home_blocked_count_template',
    -- COMMAND REFERENCE (this pass -- "the resource registers 36 commands,
    -- a player has no way to discover them in-game"). See
    -- html/tablet.js's own COMMAND_REFERENCE/buildCommandReferenceScreen()
    -- for the full catalog, its drift guard
    -- (tests/commandreferenceregistry_spec.lua), and exactly what each
    -- entry's `gate` does and does not promise. LANDED (verified directly
    -- against locales/en.json's `tablet` group, same posture as every
    -- other block above): these 135 keys used to be NOT YET present as of
    -- the pass that added them, flagged to that file's owner -- they have
    -- since been added, so BuildTabletStrings() now resolves every one of
    -- them for real. (k9grantpermission/k9revokepermission and their own
    -- their own "permissions" category, at the end of this list, were added
    -- mid-pass -- server/permissions.lua registered both concurrently
    -- while this list was being written; tests/commandreferenceregistry_spec.lua
    -- is what actually caught the gap.)
    'keys_heading', 'keys_intro', 'keys_action_radial', 'keys_action_third_eye', 'keys_action_sit', 'keys_action_bark', 'keys_action_scent_vision', 'keys_action_bite_hold', 'keys_action_takedown', 'keys_action_drag', 'keys_action_vault', 'keys_action_pursuit_sprint', 'keys_action_toggle_camera', 'keys_action_camera_feed', 'keys_action_thermal', 'keys_action_night', 'keys_action_vision_cycle', 'keys_action_exit_kennel', 'keys_name_radial', 'keys_name_third_eye', 'cmdref_heading', 'cmdref_intro', 'cmdref_search_placeholder', 'cmdref_status_unknown',
    'cmdref_filter_label', 'cmdref_filter_no_matches',
    'cmdref_status_unavailable_loading', 'cmdref_status_unavailable_error',
        'cmdref_empty', 'cmdref_column_command', 'cmdref_column_does', 'cmdref_column_needs',
    'cmdref_admin_badge', 'cmdref_status_insufficient_authorization',
    -- Keybinds handoff (this pass, client/keybinds.lua's five new
    -- RegisterCommand entries + the new `defaultKeybind` display field on
    -- these five) -- shown once, not per-row, see
    -- html/tablet.js's own buildCommandReferenceRow() comment.
    'cmdref_default_keybind_template', 'cmdref_keybind_caveat',
    'cmdref_category_basic_commands', 'cmdref_category_combat',
    'cmdref_category_field_gear',
    'cmdref_category_records',
    'cmdref_category_certification', 'cmdref_category_xp', 'cmdref_category_audit',
    'cmdref_category_devtools', 'cmdref_category_permissions',
    'cmdref_k9sit_usage', 'cmdref_k9sit_does', 'cmdref_k9sit_needs',
    'cmdref_k9bark_usage', 'cmdref_k9bark_does', 'cmdref_k9bark_needs',
    'cmdref_k9scentvision_usage', 'cmdref_k9scentvision_does', 'cmdref_k9scentvision_needs',
    'cmdref_k9bitehold_usage', 'cmdref_k9bitehold_does', 'cmdref_k9bitehold_needs',
    'cmdref_k9takedown_usage', 'cmdref_k9takedown_does', 'cmdref_k9takedown_needs',
    'cmdref_k9dragtoggle_usage', 'cmdref_k9dragtoggle_does', 'cmdref_k9dragtoggle_needs',
    'cmdref_k9deploykennel_usage', 'cmdref_k9deploykennel_does', 'cmdref_k9deploykennel_needs',
    'cmdref_k9exitkennel_usage', 'cmdref_k9exitkennel_does', 'cmdref_k9exitkennel_needs',
    -- k9kennel -- docs/history/COMMAND_CONSOLIDATION_SPEC.md #5's merged, ADDITIVE entry
    -- point. Landed here in the SAME change as html/tablet.js's own
    -- DEFAULT_STRINGS entry and locales/en.json's `tablet` group entry --
    -- all three sides of this contract, or none: the enforcing test only
    -- fails when two sides DISAGREE, so a key missing from TWO of them
    -- passes silently forever.
    'cmdref_k9kennel_usage', 'cmdref_k9kennel_does', 'cmdref_k9kennel_needs',
    -- k9debug -- server/diagnostics.lua's diagnostic dump command.
    'cmdref_k9debug_usage', 'cmdref_k9debug_does', 'cmdref_k9debug_needs',
    -- Progression screen (owner-directed progression pass).

    'progression_intro',
    'progression_k9_heading',
    'progression_handler_heading',
    'progression_k9_off',
    'progression_handler_off',
    'progression_standing',
    'progression_no_rank_yet',
    'progression_next_rank',
    'progression_top_rank',
    'progression_rank_row',

    -- k9dog (family #2, dog record) and k9train (family #4, training) --
    -- the remaining two merged entry points from the same spec. Grouped
    -- here with k9kennel rather than beside their own old per-command
    -- siblings purely because these four landed as one change; the list
    -- itself is order-insensitive (it is read as a set).
    'cmdref_k9dog_usage', 'cmdref_k9dog_does', 'cmdref_k9dog_needs',
    'cmdref_k9propattach_usage', 'cmdref_k9propattach_does', 'cmdref_k9propattach_needs',
    'cmdref_k9throwfetchball_usage', 'cmdref_k9throwfetchball_does', 'cmdref_k9throwfetchball_needs',
    'cmdref_k9dropfetchball_usage', 'cmdref_k9dropfetchball_does', 'cmdref_k9dropfetchball_needs',
    'cmdref_k9recallfetchball_usage', 'cmdref_k9recallfetchball_does', 'cmdref_k9recallfetchball_needs',
    -- k9fetch -- docs/history/COMMAND_CONSOLIDATION_SPEC.md #3's merged entry point.
    'cmdref_k9fetch_usage', 'cmdref_k9fetch_does', 'cmdref_k9fetch_needs',
    'cmdref_k9stats_usage', 'cmdref_k9stats_does', 'cmdref_k9stats_needs',
    'cmdref_k9certify_usage', 'cmdref_k9certify_does', 'cmdref_k9certify_needs',
    'cmdref_k9decertify_usage', 'cmdref_k9decertify_does', 'cmdref_k9decertify_needs',
    'cmdref_k9settier_usage', 'cmdref_k9settier_does', 'cmdref_k9settier_needs',
    'cmdref_k9specialize_usage', 'cmdref_k9specialize_does', 'cmdref_k9specialize_needs',
    'cmdref_k9unspecialize_usage', 'cmdref_k9unspecialize_does', 'cmdref_k9unspecialize_needs',
    'cmdref_k9givexp_usage', 'cmdref_k9givexp_does', 'cmdref_k9givexp_needs',
    -- Threat, added 2026-08-27 alongside its new command. Alert had a
    -- command AND a keybind while Threat had neither, so the two halves of
    -- one feature were reachable in completely different ways -- Threat is
    -- now a command, and deliberately NOT a keybind, because every letter
    -- this resource ships is already taken and the gap that mattered was
    -- discoverability rather than a missing key.
    'cmdref_k9audit_usage', 'cmdref_k9audit_does', 'cmdref_k9audit_needs',
    'cmdref_k9track_usage', 'cmdref_k9track_does', 'cmdref_k9track_needs',
    -- ADDED 2026-08-27, for the five commands that close the owner's
    -- "chat commands 3rd eye and radial menus" requirement. Leash,
    -- vehicle, partnership, gear and treating a K9 were reachable ONLY by
    -- the radial menu and the third eye -- an audit of all three surfaces
    -- found they had no chat command at all, so they never appeared in
    -- this reference either.
    --
    -- This side of the three-way string contract is the one that is easy
    -- to forget, and forgetting it is silent in the worst way: the
    -- enforcing test only fails when two sides DISAGREE, so a key missing
    -- from TWO sides passes forever and a player sees the raw key name on
    -- screen. html/tablet.js carried these first; this list and the
    -- `tablet` group in locales/en.json are the other two sides.
    'cmdref_k9leash_usage', 'cmdref_k9leash_does', 'cmdref_k9leash_needs',
    'cmdref_k9vehicle_usage', 'cmdref_k9vehicle_does', 'cmdref_k9vehicle_needs',
    'cmdref_k9partner_usage', 'cmdref_k9partner_does', 'cmdref_k9partner_needs',
    'cmdref_k9gear_usage', 'cmdref_k9gear_does', 'cmdref_k9gear_needs',
    'cmdref_k9treat_usage', 'cmdref_k9treat_does', 'cmdref_k9treat_needs',
    'cmdref_k9bonetool_usage', 'cmdref_k9bonetool_does', 'cmdref_k9bonetool_needs',
    'cmdref_k9permission_usage', 'cmdref_k9permission_does', 'cmdref_k9permission_needs',
    'cmdref_k9grantpermission_usage', 'cmdref_k9grantpermission_does', 'cmdref_k9grantpermission_needs',
    'cmdref_k9revokepermission_usage', 'cmdref_k9revokepermission_does', 'cmdref_k9revokepermission_needs',
    -- Integration-sweep fix (this pass): seven REAL, working keybind
    -- commands (RegisterCommand + RegisterKeyMapping, confirmed in
    -- client/agility.lua, client/pursuitsprint.lua, client/movement.lua,
    -- client/vision.lua) that had ZERO
    -- COMMAND_REFERENCE entry in html/tablet.js before this pass -- see
    -- tests/commandreferenceregistry_spec.lua's own header "WIDENED, THIS
    -- PASS" for why the drift guard never caught this, and
    -- html/tablet.js's own DEFAULT_STRINGS for these same 21 keys' English
    -- text plus one new shared template
    -- (cmdref_default_keybind_configurable_template) and one new category
    -- label (cmdref_category_vision) this same fix also added.
    'cmdref_vault_usage', 'cmdref_vault_does', 'cmdref_vault_needs',
    'cmdref_pursuitsprint_usage', 'cmdref_pursuitsprint_does', 'cmdref_pursuitsprint_needs',
    'cmdref_toggle_camera_usage', 'cmdref_toggle_camera_does', 'cmdref_toggle_camera_needs',
    'cmdref_toggle_camera_feed_usage', 'cmdref_toggle_camera_feed_does', 'cmdref_toggle_camera_feed_needs',
    'cmdref_toggle_thermal_vision_usage', 'cmdref_toggle_thermal_vision_does', 'cmdref_toggle_thermal_vision_needs',
    'cmdref_toggle_night_vision_usage', 'cmdref_toggle_night_vision_does', 'cmdref_toggle_night_vision_needs',
    -- OWNER REVERSAL (coder-architect, this pass): a prior "vision merge"
    -- pass folded the two entries directly above into a single 'k9vision'
    -- cycle and left their keys here only as "harmless inert leftovers"
    -- (their COMMAND_REFERENCE row had been removed from html/tablet.js).
    -- The owner has since asked for thermal and night vision to be
    -- separate, first-class controls again -- both keys ABOVE are back to
    -- backing a real COMMAND_REFERENCE row again (html/tablet.js), not
    -- inert. 'k9vision' below is KEPT too, as an extra optional
    -- convenience alongside the two explicit toggles (not a replacement for
    -- them) -- its own COMMAND_REFERENCE triple.
    'cmdref_k9vision_usage', 'cmdref_k9vision_does', 'cmdref_k9vision_needs',
    'cmdref_default_keybind_configurable_template', 'cmdref_category_vision',
    -- SERVER SETTINGS -- html/tablet.js's one admin settings tab
    -- (buildSettingsSectionNav()/buildSettingsOverviewScreen()). It replaced
    -- five tabs, including the Server Tuning guided flow whose Back/Next
    -- labels and step names went with it; the Overview section kept that
    -- flow's live summary lines.
    'tab_settings', 'settings_section_overview', 'help_tab_settings_desc', 'help_task_hc_settings_sections_template', 'settings_overview_heading', 'settings_overview_intro', 'settings_overview_features_template', 'settings_overview_tunables_template',
    'settings_overview_tiers_template', 'settings_overview_xp_template', 'settings_overview_shop_template', 'settings_overview_not_loaded',
    -- MUTATION ERROR TEXT (this pass, state-handling/error-reporting
    -- consistency sweep) -- html/tablet.js's own mutationErrorText(), the
    -- per-`error`-code mapping runMutation() now uses instead of a single
    -- generic 'action_failed' line for every certify/decertify/tier/
    -- renewal/specialization/givexp/permission/feature/role-mutation
    -- refusal. LANDED (verified directly against locales/en.json's
    -- `tablet` group, same posture as the SERVER SETTINGS block just above):
    -- these keys used to be NOT YET present as of the pass that added
    -- them, flagged to that file's owner -- they have since been added, so
    -- BuildTabletStrings() now resolves every one of them for real.
    'mutation_error_invalid_target', 'mutation_error_invalid_department', 'mutation_error_department_mismatch',
    'mutation_error_not_eligible', 'mutation_error_denied', 'mutation_error_rate_limited', 'mutation_error_busy',
    'mutation_error_self_certification_disabled', 'mutation_error_self_grant_blocked', 'mutation_error_target_must_be_online', 'mutation_error_target_not_in_department',
    'mutation_error_target_too_far', 'mutation_error_target_not_k9_model', 'mutation_error_model_check_requires_online', 'mutation_error_target_online_use_online_action',
    'mutation_error_already_certified', 'mutation_error_target_not_actively_certified', 'mutation_error_requires_active_cert', 'mutation_error_requires_tier_capability',
    'mutation_error_already_granted', 'mutation_error_not_granted', 'mutation_error_invalid_specialization', 'mutation_error_invalid_tier',
    'mutation_error_tier_already_set', 'mutation_error_target_offline', 'mutation_error_target_no_department_cert', 'mutation_error_feature_disabled',
    'mutation_error_invalid_permission', 'mutation_error_invalid_model', 'mutation_error_not_available', 'mutation_error_no_active_assignment',
    'mutation_error_no_fallback_configured', 'mutation_error_invalid_granter', 'mutation_error_db_error', 'mutation_error_actions_disabled',
    -- Help tab (owner-directed teaching guide) -- see
    -- html/tablet.js's buildHelpScreen()/HELP_TAB_CATALOG for the full
    -- design; kept in the SAME order as that file's own DEFAULT_STRINGS
    -- addition so the two stay easy to diff against each other.
    'help_heading', 'help_intro_line1', 'help_role_note_k9',
    'help_role_note_handler', 'help_role_note_uncertified', 'help_role_note_high_command_suffix', 'help_start_heading',
    'help_start_k9_1', 'help_start_k9_2', 'help_start_k9_3', 'help_start_k9_4',
    'help_start_k9_5', 'help_start_handler_1', 'help_start_handler_2', 'help_start_handler_3',
    'help_start_handler_4', 'help_start_handler_5', 'help_start_handler_6', 'help_start_high_command_heading',
    'help_start_high_command_intro', 'help_start_high_command_1', 'help_start_high_command_2', 'help_start_high_command_3',
    'help_start_high_command_4', 'help_tabs_heading', 'help_tabs_intro',
    'help_tab_my_record_desc', 'help_tab_console_desc',
    'help_tab_theme_desc',
    'help_tab_runtime_control_desc',
    'help_tab_audit_desc',
    'help_tasks_heading', 'help_task_get_certified_heading',
    'help_task_get_certified_1', 'help_task_get_certified_2', 'help_task_get_certified_3_template', 'help_task_partner_up_heading',
    'help_task_partner_up_1', 'help_task_partner_up_2', 'help_task_partner_up_3', 'help_task_partner_up_4',
    'help_task_vehicle_heading', 'help_task_vehicle_1', 'help_task_vehicle_2', 'help_task_vehicle_3',
    'help_task_search_heading', 'help_task_search_1', 'help_task_search_2', 'help_task_search_3',
    'help_task_treat_heading', 'help_task_treat_1', 'help_task_treat_2', 'help_task_treat_3',
    -- ADDED (this pass): Deploy a Kennel / Use Scent Vision walkthroughs --
    -- see html/tablet.js's own DEFAULT_STRINGS comment at these same keys.
    'help_task_kennel_heading', 'help_task_kennel_1', 'help_task_kennel_2', 'help_task_kennel_3', 'help_task_kennel_4',
    'help_task_stop_being_k9_heading', 'help_task_stop_being_k9_1', 'help_task_stop_being_k9_2',
    'help_task_stop_being_k9_3', 'help_task_stop_being_k9_4',
    'help_task_scent_vision_heading', 'help_task_scent_vision_1', 'help_task_scent_vision_2', 'help_task_scent_vision_3',
    'help_task_hc_certify_someone_heading', 'help_task_hc_certify_someone_1', 'help_task_hc_certify_someone_2_template',
    'help_task_hc_toggle_feature_heading', 'help_task_hc_toggle_feature_1', 'help_task_hc_toggle_feature_2',
    'help_task_hc_assign_k9_heading', 'help_task_hc_assign_k9_1', 'help_task_hc_assign_k9_2_template',
    'help_task_hc_assign_k9_3_template', 'help_task_hc_check_history_heading', 'help_task_hc_check_history_1', 'help_task_hc_check_history_2',
    'help_task_hc_check_history_3', 'help_trouble_heading', 'help_trouble_intro', 'help_trouble_no_k9_access_title',
    'help_trouble_no_k9_access_body', 'help_trouble_not_certified_title', 'help_trouble_not_certified_body', 'help_trouble_feature_off_title',
    'help_trouble_feature_off_body', 'help_trouble_needs_grant_title', 'help_trouble_needs_grant_body', 'help_trouble_rate_limited_title',
    'help_trouble_rate_limited_body', 'help_trouble_self_cert_disabled_title', 'help_trouble_self_cert_disabled_body', 'help_trouble_target_offline_title',
    'help_trouble_target_offline_body', 'help_trouble_insufficient_authorization_title', 'help_trouble_insufficient_authorization_body',
    'help_tab_partnerships_desc',

    -- Partnerships tab (this pass, coder-ui) -- see html/tablet.js's own
    -- "PARTNERSHIPS TAB" header comment for the full contract. Added here,
    -- to locales/en.json's `tablet` group, and to html/tablet.js's
    -- DEFAULT_STRINGS in the SAME change, per this file's own
    -- BuildTabletStrings/tabletlocalization_spec.lua three-way contract.
    'tab_partnerships', 'home_k9_progression_heading', 'home_view_partners_label', 'home_view_partners_hint',
    'mutation_error_not_partnered', 'partnerships_feature_disabled', 'partnerships_history_heading', 'partnerships_history_empty',
    'partnerships_count_summary_template', 'partnerships_truncated_notice_template', 'partnerships_state_active', 'partnerships_state_ended',
    'partnerships_established_label', 'partnerships_ended_label', 'partnerships_ended_by_label', 'partnerships_ended_system_template',
    'partnerships_tier_label', 'partnerships_tier_none', 'partnerships_tier_value_template', 'partnerships_next_tier_countdown_template',
    'partnerships_admin_heading', 'partnerships_admin_none', 'partnerships_force_end_label',

    -- K9/HANDLER PERSONNEL ROSTERS (docs/history/ROSTER_SPEC.md, Phase B) -- owner's own
    -- words, this file's own NUI CONTRACT note on tablet:rosterList/
    -- rosterSetPersonnelRole/rosterSetCallsign above. The 24 keys
    -- docs/history/ROSTER_SPEC.md §10 names, plus a small number html/tablet.js's own
    -- DEFAULT_STRINGS comment at this exact same point names individually
    -- (outcome codes server/roster.lua can return that no existing generic
    -- mutation-error key already covered) -- added here, to locales/en.json's
    -- `tablet` group, and to html/tablet.js's DEFAULT_STRINGS in the SAME
    -- change, per this file's own BuildTabletStrings/
    -- tabletlocalization_spec.lua three-way contract.
    'tab_roster', 'roster_bucket_label', 'roster_bucket_k9', 'roster_bucket_handlers',
    'roster_unassigned_heading', 'roster_unassigned_explainer',
    'roster_callsign_column', 'roster_callsign_none', 'roster_callsign_label', 'roster_callsign_save',
    'roster_callsign_taken_error', 'roster_callsign_invalid_chars_error', 'roster_hire_label', 'roster_hire_role_prompt',
    'roster_hire_role_k9', 'roster_hire_role_handler', 'roster_fire_label', 'roster_fire_confirm_prompt',
    'roster_fire_self_warning', 'roster_role_change_label', 'roster_role_change_confirm_prompt', 'roster_sort_label',
    'roster_sort_by_tier', 'roster_sort_by_grade', 'roster_sort_by_xp', 'roster_dogcharacter_pin_note',
    'roster_error_invalid_personnel_role', 'roster_error_not_certified', 'roster_error_already_assigned', 'roster_error_no_active_personnel',
    'roster_bucket_empty', 'roster_unassigned_none', 'roster_certified_since_column',
    'help_tab_roster_desc',
}

--- Builds the FULL, localized `strings` payload for tablet:open, one
--- locale() call per TABLET_STRING_KEYS entry against locales/en.json's
--- `tablet` group (e.g. `locale('tablet.title')`). Pcall-wrapped PER KEY,
--- matching AwaitServerCallback's own fail-safe posture just below -- a
--- single missing/misconfigured key must never abort the whole payload or
--- throw out of OpenTablet(); it is simply omitted, and html/tablet.js's
--- own DEFAULT_STRINGS (kept, unchanged, in that file) covers exactly that
--- gap for that one key, same "resilience net" role it already documents.
--- @return table<string,string>
--- Single-key pcall-wrapped locale() resolution -- the SAME fail-safe
--- shape as BuildTabletStrings()'s own per-key guard above, for any
--- locale() call OUTSIDE the TABLET_STRING_KEYS/`strings` mechanism (a
--- one-off value resolved directly at its own call site, e.g. an optional
--- `message`/`description` field on a specific response, rather than a
--- fixed UI-chrome string sent on every tablet:open). A missing/renamed
--- key here must never throw out of the caller -- it degrades to `nil`,
--- exactly like an omitted `strings` entry, so the caller can fall back to
--- an unlocalized default or simply omit the optional field, instead of
--- erroring out of an otherwise-successful action.
--- @param fullKey string -- e.g. 'tablet.open_failed_generic'
--- @return string?
local function SafeLocale(fullKey)
    local ok, value = pcall(locale, fullKey)
    if ok and type(value) == 'string' and value ~= '' then return value end
    return nil
end

local function BuildTabletStrings()
    local strings = {}
    for i = 1, #TABLET_STRING_KEYS do
        local key = TABLET_STRING_KEYS[i]
        local ok, value = pcall(locale, 'tablet.' .. key)
        if ok and type(value) == 'string' then
            strings[key] = value
        end
    end
    return strings
end

--- The ONE place this file ever calls SetNuiFocus -- see FOCUS/CLOSE
--- DISCIPLINE and, for the two arguments themselves, "CROSS-RESOURCE FOCUS
--- INTEROP" above. No access/state check beyond "is it open" -- a
--- close/termination path must never be gated (this codebase's "no
--- unbounded trap" rule) -- that rule is
--- unchanged and unconditional; only WHICH two booleans this one call
--- passes depends on `tabletHadForeignFocusOnOpen`, captured once per open
--- by OpenTablet() below. `true` -- another resource already held focus
--- when this file opened over it -- RESTORES that pre-existing focus
--- (SetNuiFocus(true, true)) rather than blanking it out from under
--- whoever set it; `false` -- the common case, nobody else had focus --
--- releases it fully, exactly as before this pass. Idempotent --
--- html/tablet-bridge.js's own header documents firing tablet:close from
--- more than one path and expects Lua to treat a repeat as a safe no-op.
function CloseTablet()
    if not tabletOpen then return end

    tabletOpen = false
    SetNuiFocus(tabletHadForeignFocusOnOpen, tabletHadForeignFocusOnOpen)
    SendNUIMessage({ action = 'tablet:close', data = {} })
end

--- ESC-close + own-death watch -- one thread for both, mirrors
--- client/vision.lua's maintenance-thread lifecycle guard exactly:
--- started only from OpenTablet(), a no-op while already running,
--- self-resetting the instant `tabletOpen` goes false.
---
--- Wait(0) is correct here, not a "no tight loop" violation:
--- DisableControlAction must be re-asserted every frame to suppress the
--- native pause menu (it does not persist across frames on its own), and
--- this thread's lifetime is already bounded to "while the tablet is
--- open," never a perpetual idle poll.
local tabletWatchThreadRunning = false
local function EnsureTabletWatchThreadRunning()
    if tabletWatchThreadRunning then return end
    tabletWatchThreadRunning = true

    CreateThread(function()
        while tabletOpen do
            -- INPUT_FRONTEND_PAUSE (200) -- standard FiveM ESC-closeable-NUI
            -- idiom: DisableControlAction suppresses the native pause menu;
            -- IsDisabledControlJustPressed (the DISABLED variant -- plain
            -- IsControlJustPressed stops reporting a press once a control
            -- is disabled) detects the keypress in that same frame.
            DisableControlAction(0, 200, true)

            if IsDisabledControlJustPressed(0, 200) then
                CloseTablet()
            elseif IsEntityDead(PlayerPedId()) then
                -- Same IsEntityDead(PlayerPedId()) polling shape already
                -- established by client/vision.lua/screenfx.lua/
                -- propattachment.lua/fetch.lua/vehicle.lua for "clean up
                -- per-ped state on death, since respawn reuses the ped
                -- handle" -- applied here to a focus grab.
                CloseTablet()
            elseif type(IsLocalPlayerForceRagdolled) == 'function' and IsLocalPlayerForceRagdolled() then
                -- THIS PASS -- see this file's header "DOWNED-BY-TAKEDOWN
                -- ALSO FORCE-CLOSES". A non-lethal K9 takedown never sets
                -- IsEntityDead true, so without this branch a taken-down
                -- player kept their tablet (and NUI focus) open while
                -- genuinely unable to act. `type(fn) == 'function'` guard
                -- because client/combat.lua defines nothing at all when
                -- BiteAndHold/NonLethalTakedown/PropDragging are ALL off --
                -- same non-optional guard convention this file's header
                -- already documents for FindNearestLeashCandidate/
                -- FindNearestPartnerCandidate.
                CloseTablet()
            end

            Wait(0)
        end

        tabletWatchThreadRunning = false
    end)
end

--- Opens the K9 Command Tablet for the LOCAL player. Exposed globally for
--- a future client/radial.lua entry (this pass's report names it).
---
--- NO server round trip before opening -- html/tablet.js's own design
--- opens immediately and shows a loading/error state INSIDE the tablet
--- while tablet:requestMyRecord resolves (its buildViewerGate()), rather
--- than this file deciding "authorized enough to even open" itself. That
--- is also what makes "every k9 or handler can open the tablet and see
--- whatever they've been certified in" true for someone not yet
--- certified: they still open it and see why, instead of never opening
--- at all.
---
--- @param requestedView string? -- 'highCommand' | nil (nil resolves to
--- 'auto' in the payload below). PRESENTATION HINT ONLY, forwarded as
--- `requestedView` in the tablet:open payload (see NUI CONTRACT above) --
--- it changes NOTHING about what this function does: same tabletOpen
--- no-op guard, same single SetNuiFocus(true, true) call, same
--- SendNUIMessage. Real authorization still happens entirely server-side
--- -- html/tablet.js's loadMyRecord() only ever picks a LANDING SCREEN
--- from this hint plus the server-verified viewer fields tablet:requestMyRecord
--- returns; it never skips or shortcuts a single fetch or check because of
--- it. Callers: the original tablet command, the ox_inventory item, and
--- the K9 radial menu entry all call OpenTablet() with no argument (nil,
--- which becomes 'auto' -- every ordinary open auto-routes a qualifying
--- caller to the console by their own rank, owner-directed 2026-08-26);
--- the OPTIONAL, opt-in Config.CommandTablet.highCommandCommand below is
--- the only caller that ever passes 'highCommand' explicitly.
--- @return nil
function OpenTablet(requestedView)
    if tabletOpen then return end

    tabletOpen = true
    -- THIS PASS -- see header "CROSS-RESOURCE FOCUS INTEROP". Captured
    -- BEFORE this file's own SetNuiFocus(true, true) call below touches
    -- anything, so it reflects whatever some OTHER resource left the
    -- engine-global flag at -- CloseTablet() reads this back to decide
    -- whether to restore that pre-existing focus or release it fully.
    --
    -- Pcall-wrapped and normalized to a REAL boolean (`== true`, never a
    -- bare truthy value, and never nil) -- same fail-safe posture as
    -- AwaitServerCallback/BuildTabletStrings' own per-call pcall guards in
    -- this file. If IS_NUI_FOCUSED ever throws, or returns anything other
    -- than a clean boolean, this MUST collapse to `false` (nobody else had
    -- it), never `nil` or a propagating error: `nil` reaching
    -- CloseTablet()'s SetNuiFocus call below would either misbehave or
    -- error against a native that expects a real boolean argument, and
    -- letting the error propagate out of OpenTablet() at all would abort
    -- the open entirely -- either outcome is strictly worse than the
    -- "wrongly assume nobody else had focus" fallback this collapses to.
    -- Concretely: `false` here means CloseTablet() later releases focus
    -- fully (SetNuiFocus(false, false)), which is EXACTLY this file's
    -- ENTIRE pre-existing behavior before this pass -- a failed capture
    -- degrades to the old, always-safe posture, never to a new, untested
    -- one. The close path itself is never skipped or gated by this value
    -- either way -- see CloseTablet()'s own doc comment.
    local nuiFocusCheckOk, nuiFocusCheckResult = pcall(IsNuiFocused)
    tabletHadForeignFocusOnOpen = (nuiFocusCheckOk and nuiFocusCheckResult == true)
    SendNUIMessage({
        action = 'tablet:open',
        data = {
            capabilities = Config.Permissions, -- shared config, no round trip
            strings = BuildTabletStrings(), -- locales/en.json's `tablet` group, one key per html/tablet.js's own DEFAULT_STRINGS -- see this file's header LOCALIZATION note
            requestedView = (requestedView == 'highCommand') and 'highCommand' or 'auto', -- see NUI CONTRACT above and this function's own @param doc -- presentation hint only. 'auto' (not nil) by default so html/tablet.js's loadMyRecord() auto-routes EVERY ordinary open by the caller's own rank, not just the opt-in highCommandCommand shortcut -- owner-directed, 2026-08-26.
            -- The Block Effect column's 'client_enforced' badge/hint text
            -- (block_client_enforced_badge/_hint) used to be sent as two
            -- standalone fields here -- folded into the ordinary
            -- TABLET_STRING_KEYS/`strings` mechanism above now that the
            -- hardcoded key count that blocked it is gone (see
            -- TABLET_STRING_KEYS' own comment at those two keys).
            maxXpPerGrant = (type(Config.HighCommand) == 'table' and type(Config.HighCommand.maxXpPerGrant) == 'number')
                and Config.HighCommand.maxXpPerGrant or nil,
            peds = Config.Peds, -- shared config, no round trip -- see this file's header NUI CONTRACT note on tablet:assignK9Role
            themingEnabled = Config.Features and Config.Features.TabletTheming == true, -- UX hint only, see NUI CONTRACT
            shopLocationsEnabled = Config.Features and Config.Features.K9EquipmentShop == true, -- UX hint only, SAME shape as themingEnabled -- see NUI CONTRACT
            runtimeControlEnabled = Config.Features and Config.Features.RuntimeFeatureControl == true, -- UX hint only, SAME shape as themingEnabled/shopLocationsEnabled -- see NUI CONTRACT
            -- UX hint only, but a MEANINGFULLY DIFFERENT shape from the
            -- three above: server/admin.lua gates its five tabletAudit*
            -- callbacks at REGISTRATION TIME behind this SAME flag (if not
            -- `true`, none of them are ever registered at all, not merely a
            -- runtime no-op) -- so unlike themingEnabled/shopLocationsEnabled/
            -- runtimeControlEnabled (whose underlying read callbacks stay
            -- live either way), a tabletAudit* call made while this is
            -- false would hang until AwaitServerCallback's own pcall
            -- synthesizes a generic 'timeout', not a clean 'feature_disabled'
            -- refusal. html/tablet.js disables the Audit screen's query
            -- controls (and shows a disabled-server-wide note) whenever this
            -- is false, precisely to avoid surfacing that confusing generic
            -- timeout for an officer who otherwise qualifies.
            auditEnabled = Config.Features and Config.Features.AdminAuditCommands == true,
            -- CERTIFICATION SPECIALIZATIONS -- shared config, no round trip,
            -- SAME "no hardcoded list" posture as `peds` above:
            -- Config.K9Specializations (server/certifications/'s
            -- GrantSpecialization is the real, server-side gate on this
            -- exact same table) is the resource's ONE real specialization
            -- catalog -- html/tablet.js's specialization picker populates
            -- from this, never a hardcoded narcotics/explosives/patrol
            -- list, so an operator-added specialization key appears with
            -- zero UI change the moment it's added to config.lua.
            specializations = (type(Config.K9Specializations) == 'table') and Config.K9Specializations or {},
            branding = (type(Config.CommandTablet) == 'table' and type(Config.CommandTablet.branding) == 'table')
                and Config.CommandTablet.branding or {}, -- shared config, no round trip -- { serverName, logo, theme:{4 colors} } -- see this file's header NUI CONTRACT note
        },
    })
    SetNuiFocus(true, true)
    EnsureTabletWatchThreadRunning()
end

-- ----------------------------------------------------------------------
-- OPENING -- Config.CommandTablet.openMode resolution + registration. See
-- this file's header "OPENING" section for the full trap writeup.
-- ----------------------------------------------------------------------
local cfgTablet = type(Config.CommandTablet) == 'table' and Config.CommandTablet or {}
local openMode = cfgTablet.openMode
if openMode ~= 'command' and openMode ~= 'item' and openMode ~= 'both' then
    print(('[qbx_k9unit] WARNING: Config.CommandTablet.openMode (%s) is not \'command\'/\'item\'/\'both\' -- ' ..
        'falling back to \'command\' so the tablet is not left completely unreachable.'):format(tostring(openMode)))
    openMode = 'command'
end

if openMode == 'command' or openMode == 'both' then
    local tabletCommand = cfgTablet.command
    if type(tabletCommand) == 'string' and tabletCommand ~= '' then
        RegisterCommand(tabletCommand, function() OpenTablet() end, false)
    else
        print('[qbx_k9unit] WARNING: Config.CommandTablet.command is missing or not a valid string -- the K9 Command Tablet will not be reachable by command this session.')
    end
end

-- ----------------------------------------------------------------------
-- OPTIONAL SECOND ENTRY POINT -- Config.CommandTablet.highCommandCommand.
-- See this file's header "ONE COMMAND, ROUTED BY RANK" / "OPTIONAL SECOND
-- ENTRY POINT" notes above for the full writeup. DEFAULT DISABLED
-- (`false`, or simply absent) as of this pass -- the ORIGINAL command
-- above now auto-routes a qualifying caller to the console on its own
-- (requestedView = 'auto'), so this second command is no longer needed on
-- a fresh install. `false`/nil/blank is therefore the ORDINARY, INTENDED
-- state now, not a misconfiguration -- registers nothing, warns nothing.
-- Only a genuinely INVALID value (present, but neither `false` nor a
-- usable string -- e.g. a stray number or `true` left over from a hand
-- edit) still warns, matching this resource's usual "silently doing
-- nothing is worse than a loud, ignorable log line" posture for an actual
-- mistake. When configured to a real command name, registered
-- UNCONDITIONALLY here (not gated on `openMode`, which governs only the
-- ORIGINAL command's/item's reachability) -- a wholly separate,
-- always-available shortcut whenever Config.Features.CommandTablet is on
-- at all (the file-level early return above already covers the flag being
-- off, exactly like the original command). Calls the SAME OpenTablet()/
-- CloseTablet() pair, so it shares the one focus lifecycle and the one
-- tabletOpen no-op guard -- typing this while the tablet is already open
-- (via either command) is a safe no-op, identical to typing the original
-- command twice.
-- ----------------------------------------------------------------------
local hqTabletCommand = cfgTablet.highCommandCommand
if type(hqTabletCommand) == 'string' and hqTabletCommand ~= '' then
    RegisterCommand(hqTabletCommand, function() OpenTablet('highCommand') end, false)
elseif hqTabletCommand ~= nil and hqTabletCommand ~= false then
    print(('[qbx_k9unit] WARNING: Config.CommandTablet.highCommandCommand (%s) is set but is not a valid command string or `false` -- ' ..
        'the K9 High Command Tablet shortcut will not be reachable by command this session (the original ' ..
        'tablet command/item, if configured, is unaffected; the single tablet command already auto-routes ' ..
        'a qualifying caller to the console on its own regardless).'):format(tostring(hqTabletCommand)))
end
-- else: `false` or nil -- deliberately disabled, the new default. No
-- warning: this is not a missing config, it is the intended "one command"
-- state the owner asked for.

if openMode == 'item' or openMode == 'both' then
    --- Runtime existence guard for the K9Compat-detected inventory's
    --- UseItem method -- same PURPOSE as the pre-compat-layer
    --- `IsOxInventoryUseCapable` this replaces (mirrors
    --- client/inventory.lua's IsOxInventoryOpenCapable's GetResourceState +
    --- pcall'd export-access shape at the adapter-build layer), but now
    --- asks the compat layer's own detection result instead of probing
    --- `exports.ox_inventory` directly, so this guard -- and its warning --
    --- are correct for WHATEVER inventory Config.Compat resolved, not only
    --- ox_inventory. `K9Compat.Which('inventory')` returns a non-nil
    --- resourceName only when a real, verified adapter is currently active
    --- for this realm; `K9Compat.Get('inventory')` itself is NEVER nil (see
    --- shared/compat/core.lua's own header) so it cannot be used for this
    --- existence check on its own -- its no-op stub would silently satisfy
    --- a bare `type(...) == 'table'` test.
    --- @return boolean
    local function IsInventoryUseCapable()
        return K9Compat.Which('inventory') ~= nil
    end

    -- Purely LOCAL client event (never networked -- no `source`, no
    -- forgery surface beyond "another local script on this same client
    -- opening the tablet early," which is harmless), matching ox_inventory's
    -- own real, documented `item.client.event` dispatch mechanism
    -- (verified against overextended/ox_inventory's modules/items/client.lua
    -- this pass: item definitions carry a `client = { export=... } |
    -- { event=... }` field, dispatched via a plain, non-networked
    -- TriggerEvent). THE OPERATOR'S OWN ox_inventory items.lua entry for
    -- Config.CommandTablet.itemName must set `client = { event =
    -- 'qbx_k9unit:client:useTabletItem' }` for this to ever fire at all --
    -- this resource cannot create or edit that entry (same "cannot create
    -- the item itself" limitation config.lua's own comment already states
    -- for the item's mere EXISTENCE); documented here, and in this pass's
    -- own report, not assumed silently.
    AddEventHandler('qbx_k9unit:client:useTabletItem', function(data, slot)
        if not IsInventoryUseCapable() then
            print('[qbx_k9unit] WARNING: the K9 Command Tablet item was used, but no usable inventory adapter is currently detected (Config.Compat) -- cannot open. Run /k9compat (if enabled) to see why.')
            lib.notify({ title = locale('common.notify_title'), description = SafeLocale('tablet.open_failed_generic'), type = 'error' })
            return
        end

        -- useItem's own callback tells us whether the SERVER actually
        -- approved this use (still holds the item, etc.) -- OpenTablet()
        -- only runs on a truthy result, never optimistically before that
        -- confirmation lands. Config.CommandTablet.consumeItemOnUse is NOT
        -- something this call can override -- ox_inventory consumes (or
        -- doesn't) per the item's OWN `consume` field in the operator's
        -- items.lua, which this resource does not own; consumeItemOnUse is
        -- a documented EXPECTATION for what that field should be set to
        -- (0/false for a reusable tablet), not an enforced override -- see
        -- this pass's own report. Routed through K9Compat.Get('inventory')
        -- rather than `exports.ox_inventory:useItem` directly this pass
        -- (shared/compat/core.lua) -- the adapter's own UseItem is already
        -- pcall-safe and guarantees `cb` fires exactly once even if the
        -- underlying export throws (see shared/compat/inventory.lua's own
        -- UseItem doc comment), so no additional guard is needed here
        -- beyond the IsInventoryUseCapable() check above.
        K9Compat.Get('inventory').UseItem(data, function(approved)
            if approved then OpenTablet() end
        end)
    end)
end

-- ----------------------------------------------------------------------
-- SECTION 2 -- tablet:triggerFeature. Keyed by Config.Features NAME
-- (e.g. 'BiteAndHold'), matching html/tablet.js's `myFeatures[].key`
-- exactly -- the SERVER decides which keys are even sent/actionable
-- (tabletRequestMyRecord's own resolution), this file only needs an
-- entry for a key it might be asked to fire. Each `run()` mirrors
-- client/radial.lua's own onSelect gate CHOICE for that action
-- line-for-line (cited per entry) -- see RIGHT-VS-WRONG above.
--
-- DISCLOSED SIMPLIFICATION: three Config.Features keys cover MORE than
-- one distinct action in client/radial.lua (HandlerPartnership: Partner
-- Up vs Break Partnership; FetchMechanic: throw/release vs recall) -- this
-- contract's `{feature}`-only payload (no extra args) has room for
-- exactly ONE behavior per key. Each is given the single most defensible
-- default below (documented per entry) rather than left unreachable; a
-- future JS revision that wants the explicit choice back would need an
-- `args` addition to the trigger payload, which is this file's call to
-- make once asked for, not assumed here.
-- 'Sit' has no Config.Features key of its own (radial.lua's own comment:
-- "bundled under the general RadialMenu flag") and so has no entry here
-- -- the server-driven myFeatures list has nothing to key it under either.
-- ----------------------------------------------------------------------
local FEATURE_TRIGGERS = {
    -- radial.lua 'k9_leash': Detach UNGATED, Attach gated + nearest candidate.
    -- NOT WIDENED (permission audit finding, this pass, considered and
    -- rejected -- matches radial.lua's own 'k9_leash' Attach branch
    -- verbatim): server/main.lua's CheckLeashEligibility does NOT gate on
    -- HasK9Access() alone -- it requires AT LEAST ONE of the two parties to
    -- be a real K9 by model OR the decoupled K9 role
    -- (IsConfiguredK9Model(...) or HasK9Role(...)), a check that itself
    -- EXCLUDES the High Command/autoAccessGrade bypass, BEFORE
    -- HasK9Access(k9Src) is ever consulted for whichever party ends up cast
    -- as "the K9". A bypass-only holder with no model and no role can never
    -- be treated as the K9 side of a pairing regardless of what this file
    -- shows, so widening this gate would offer something the server would
    -- then genuinely refuse ('no_k9_party'). Left on the broader combinator
    -- on purpose.
    LeashMechanics = function()
        if type(IsLeashed) == 'function' and IsLeashed() then
            if type(DetachLeash) == 'function' then DetachLeash() end
            return true
        end
        if not CanShowK9UI() then DenyK9UIAccess('common.no_k9_role_or_access'); return false, 'not_available' end
        if type(FindNearestLeashCandidate) ~= 'function' then return false, 'not_available' end
        local candidateServerId = FindNearestLeashCandidate()
        if not candidateServerId then
            lib.notify({ title = locale('common.notify_title'), description = locale('radial.no_leash_candidate'), type = 'error' })
            return false, 'not_available'
        end
        if type(RequestLeashAttach) == 'function' then RequestLeashAttach(candidateServerId) end
        return true
    end,
    -- radial.lua 'k9_vehicle': Exit checked FIRST, UNGATED; Enter gated on
    -- HasK9Access() ALONE.
    --
    -- ORDERING FIX (this pass -- the header comment here previously read
    -- "BOTH directions gated," which was true of the code below it and was
    -- exactly the "gate the START of a thing, never the STOP" trap this
    -- file's own header warns about, already found and fixed once in THIS
    -- file (see the PropAttachments entry below) and once in
    -- client/radial.lua's own 'k9_vehicle' item ("ORDERING FIX, THIS PASS"
    -- -- see that item's own comment). client/vehicle.lua's ExitK9Vehicle()
    -- own doc comment states it is "Deliberately NOT gated behind
    -- CanShowK9UI() -- a K9 whose certification lapses mid-ride must always
    -- be able to get out"; this wrapper did not honor that, refusing the
    -- WHOLE toggle (exit included) for anyone who failed CanShowK9UI()
    -- before ever reaching the IsInK9Vehicle() check below. Fixed by
    -- checking IsInK9Vehicle() FIRST, ungated, exactly mirroring
    -- LeashMechanics/BiteAndHold/PropDragging above and below.
    --
    -- GATE WIDENED TO HasK9Access() ALONE ON THE ENTER BRANCH (permission
    -- audit finding, this pass): server/vehicle.lua's
    -- requestVehicleSeatClaim gates on `HasK9Access(src)` alone (confirmed
    -- by reading it directly -- no model/role check on the REQUESTER
    -- anywhere in that handler; only the VEHICLE itself is re-verified as a
    -- real K9 vehicle model), matching client/radial.lua's own 'k9_vehicle'
    -- Enter branch and client/vehicle.lua's own EnterNearestK9Vehicle()
    -- (both already widened -- see each one's own doc comment). This wrapper
    -- was the one remaining caller still gating stricter than both the
    -- callee and the server it ultimately reaches.
    VehicleEntryExit = function()
        if type(IsInK9Vehicle) == 'function' and IsInK9Vehicle() then
            if type(ExitK9Vehicle) == 'function' then ExitK9Vehicle() end
            return true
        end
        if not HasK9Access() then DenyK9UIAccess('combat.no_access'); return false, 'not_available' end
        if type(EnterNearestK9Vehicle) == 'function' then EnterNearestK9Vehicle() end
        return true
    end,
    -- radial.lua 'k9_bark' (non-AdvancedBarkRadial literal only -- no
    -- variant arg in this contract, see DISCLOSED SIMPLIFICATION above).
    --
    -- GATE WIDENED TO HasK9Access() ALONE, NOT CanShowK9UI() (permission
    -- audit finding, this pass): server/main.lua's relayBark handler gates
    -- on `HasK9Access(src)` alone (confirmed by reading it directly, no
    -- model/role check anywhere in that handler), matching
    -- client/radial.lua's own 'k9_bark' item exactly (see that item's own
    -- "GATE WIDENED TO HasK9Access() ALONE" comment) -- a High Command/
    -- autoAccessGrade-bypass holder now reaches the server end-to-end
    -- through this button too.
    BasicBarkSounds = function()
        if not HasK9Access() then DenyK9UIAccess('combat.no_access'); return false, 'not_available' end
        TriggerServerEvent('qbx_k9unit:server:relayBark', 'bark')
        return true
    end,
    -- radial.lua 'k9_track_certified' (merged): each of these three keys
    -- stops itself if already the active type, else starts its own single
    -- type via the OLDER, still-live StartScentTrack()/StartBloodTrack()/
    -- StartGunpowderTrack() globals (client/tracking.lua's own doc comment:
    -- "kept as resource-globals... even though nothing in this resource's
    -- own UI calls them anymore" except, per this file's own
    -- DISCLOSED SIMPLIFICATION above, this contract, which cannot express
    -- radial.lua's merged "search for whatever I'm certified for" action
    -- without an `args` addition to the trigger payload).
    --
    -- GATE WIDENED TO HasK9Access() ALONE (permission audit finding, this
    -- pass): every real server-side track callback
    -- (findTrackableSource/findNearestTrackableSource, server/tracking.lua)
    -- gates on `HasK9Access(source)` alone (confirmed by reading them
    -- directly), and the shared StartTrack() these three globals all funnel
    -- through (client/tracking.lua) already gates on HasK9Access() alone
    -- internally (see that function's own "ANY-PED SWEEP FIX" comment) --
    -- this wrapper's outer CanShowK9UI() check ran BEFORE that already-
    -- correct callee, refusing a High Command/autoAccessGrade-bypass holder
    -- a search the callee itself would have granted. Matches
    -- client/radial.lua's own merged 'k9_track_certified' item's identical
    -- fix.
    ScentTracking = function()
        if type(GetActiveTrackType) == 'function' and GetActiveTrackType() == 'scent' then
            if type(StopTracking) == 'function' then StopTracking() end
            return true
        end
        if not HasK9Access() then DenyK9UIAccess('combat.no_access'); return false, 'not_available' end
        if type(StartScentTrack) == 'function' then StartScentTrack() end
        return true
    end,
    BloodTracking = function()
        if type(GetActiveTrackType) == 'function' and GetActiveTrackType() == 'blood' then
            if type(StopTracking) == 'function' then StopTracking() end
            return true
        end
        if not HasK9Access() then DenyK9UIAccess('combat.no_access'); return false, 'not_available' end
        if type(StartBloodTrack) == 'function' then StartBloodTrack() end
        return true
    end,
    GunpowderSniffing = function()
        if type(GetActiveTrackType) == 'function' and GetActiveTrackType() == 'gunpowder' then
            if type(StopTracking) == 'function' then StopTracking() end
            return true
        end
        if not HasK9Access() then DenyK9UIAccess('combat.no_access'); return false, 'not_available' end
        if type(StartGunpowderTrack) == 'function' then StartGunpowderTrack() end
        return true
    end,
    -- NOT in client/radial.lua at all (keybind-only by design). Both
    -- Toggle*Vision() already gate + notify internally (IsOwnModelK9()
    -- only, per client/vision.lua's own RESOLVED ACCESS-GATING DECISION)
    -- -- call straight through.
    ThermalVision = function()
        if type(ToggleThermalVision) == 'function' then ToggleThermalVision(); return true end
        return false, 'not_available'
    end,
    NightVision = function()
        if type(ToggleNightVision) == 'function' then ToggleNightVision(); return true end
        return false, 'not_available'
    end,
    -- radial.lua 'k9_bite_hold': Release UNGATED, Attempt gated on
    -- HasK9Access() ALONE.
    --
    -- GATE WIDENED TO HasK9Access() ALONE (permission audit finding, this
    -- pass): server/combat.lua's shared ValidateCombatRequest (backing
    -- requestBiteHold/requestTakedown/requestDrag alike) gates on
    -- `HasK9Access(src)` alone (confirmed by reading it directly -- no
    -- model/role check on the K9 anywhere in that validator), and
    -- client/combat.lua's own RequestBiteHold() was already widened to
    -- match (see that function's own doc comment) -- this wrapper's outer
    -- CanShowK9UI() check ran BEFORE that already-correct callee, refusing
    -- a High Command/autoAccessGrade-bypass holder a bite-and-hold the
    -- callee itself would have granted. Matches client/radial.lua's own
    -- 'k9_bite_hold' item's identical fix. The Release branch above is
    -- UNCHANGED and stays UNGATED -- gate the START of a thing, never the
    -- STOP (see the VehicleEntryExit entry above for the fuller version of
    -- this rule, and ReleaseBiteHold()'s own doc comment for why gating the
    -- release would strand an engaged K9 who loses access mid-hold).
    BiteAndHold = function()
        if type(IsBiteHoldEngaged) == 'function' and IsBiteHoldEngaged() then
            if type(ReleaseBiteHold) == 'function' then ReleaseBiteHold() end
            return true
        end
        if not HasK9Access() then DenyK9UIAccess('combat.no_access'); return false, 'not_available' end
        if type(RequestBiteHold) == 'function' then RequestBiteHold() end
        return true
    end,
    -- radial.lua 'k9_takedown': one-shot, gated on HasK9Access() ALONE, no
    -- release counterpart.
    --
    -- WIDENED TO HasK9Access() ALONE, SAME RESIDUAL GAP CLOSED AS BITE &
    -- HOLD ABOVE -- see that entry's own header comment for the full
    -- writeup (shared ValidateCombatRequest, and client/combat.lua's own
    -- RequestTakedown() ALSO widened from CanShowK9UI() to HasK9Access()
    -- alone); applies here verbatim, not repeated in full. Matches
    -- client/radial.lua's own 'k9_takedown' item.
    NonLethalTakedown = function()
        if not HasK9Access() then DenyK9UIAccess('combat.no_access'); return false, 'not_available' end
        if type(RequestTakedown) == 'function' then RequestTakedown() end
        return true
    end,
    -- radial.lua 'k9_drag': Release UNGATED, Attempt gated on HasK9Access()
    -- ALONE. TWO release branches -- being dragged is asked first, being
    -- the dragger second -- see client/combat.lua's IsDragTargetEngaged()
    -- for why the target's own release was previously unreachable from
    -- every one of its call sites.
    --
    -- START BRANCH WIDENED TO HasK9Access() ALONE, SAME RESIDUAL GAP CLOSED
    -- AS BITE & HOLD/TAKEDOWN ABOVE -- see Bite & Hold's own header comment
    -- above for the full writeup; applies here verbatim (shared
    -- ValidateCombatRequest, and client/combat.lua's own RequestDrag() ALSO
    -- widened from CanShowK9UI() to HasK9Access() alone). Both release
    -- branches below are UNCHANGED and stay UNGATED -- same "no unbounded
    -- trap" reasoning as every other release/termination branch in this
    -- table.
    PropDragging = function()
        if type(IsDragTargetEngaged) == 'function' and IsDragTargetEngaged() then
            if type(ReleaseDrag) == 'function' then ReleaseDrag() end
            return true
        end
        if type(IsDragEngaged) == 'function' and IsDragEngaged() then
            if type(ReleaseDrag) == 'function' then ReleaseDrag() end
            return true
        end
        if not HasK9Access() then DenyK9UIAccess('combat.no_access'); return false, 'not_available' end
        if type(RequestDrag) == 'function' then RequestDrag() end
        return true
    end,
    -- Partner Up / Break Partnership: client/partnership.lua's
    -- TogglePartnership(), the same one action /k9partner and the radial
    -- use. It asks the server whether you are partnered before choosing,
    -- so a reconnected player is offered Break, not a refused Partner Up.
    -- The break branch is ungated; the partner-up branch keeps its checks.
    HandlerPartnership = function()
        if type(TogglePartnership) ~= 'function' then return false, 'not_available' end
        return TogglePartnership()
    end,
    -- DISCLOSED SIMPLIFICATION: throw/release toggle only (radial.lua's
    -- own Throw item shape) -- Recall Fetch Ball is a separate action in
    -- radial.lua with no feature key of its own to hang off here.
    -- Gated on HasK9Access() ONLY, matching RequestThrowFetchBall()'s own
    -- doc comment verbatim (a human-handler action).
    FetchMechanic = function()
        if type(IsFetchCarryEngaged) == 'function' and IsFetchCarryEngaged() then
            if type(ReleaseFetchBall) == 'function' then ReleaseFetchBall() end
            return true
        end
        if not HasK9Access() then DenyK9UIAccess(); return false, 'not_available' end
        if type(RequestThrowFetchBall) == 'function' then RequestThrowFetchBall() end
        return true
    end,
    -- NOT GATED HERE, DELIBERATELY. This wrapper used to check CanShowK9UI()
    -- first, with a comment calling that "redundant with the callee". It was
    -- the opposite of redundant, and it reintroduced a trap that had already
    -- been found and fixed one layer down.
    --
    -- RequestToggleK9PropAttachment resolves INTENT before it gates: if a vest
    -- is already on, the removal request goes through unconditionally, because
    -- taking off a vest you are already wearing is not a capability. Checking
    -- access up here ran before that resolution, so a handler who lost their
    -- certification while wearing one was refused by this wrapper and the vest
    -- stayed welded on. There is no server-side safety net either --
    -- decertification tears down leashes, holds and partnerships, but not prop
    -- attachments -- so this WAS the way out, and it was shut.
    --
    -- The callee still gates the ADD path and still calls DenyK9UIAccess()
    -- itself, so nothing is widened and no message is lost by removing the
    -- check here. Do not "restore" it for consistency: the consistent rule is
    -- gate the START of a thing, never the STOP, and this call site cannot
    -- tell which one it is.
    PropAttachments = function()
        if type(RequestToggleK9PropAttachment) == 'function' then RequestToggleK9PropAttachment() end
        return true
    end,
    -- NOT GATED HERE, same reasoning as PropAttachments directly above.
    -- RequestDeployKennel resolves "am I already carrying one" BEFORE any
    -- flag or access check, so gating up here stopped a handler who lost
    -- access from putting a carried kennel back down. Less severe than the
    -- vest (a carried kennel restrains an object, not the player) and there
    -- are other routes out, but it is the same mistake and it goes the same
    -- way.
    DeployableKennel = function()
        if type(RequestDeployKennel) == 'function' then RequestDeployKennel() end
        return true
    end,
    -- radial.lua 'k9_open_inventory': gated (redundant with the callee, kept
    -- for consistency).
    --
    -- NOT WIDENED (permission audit finding, this pass, checked and
    -- rejected -- matches client/radial.lua's own 'k9_open_inventory' item
    -- verbatim): server/inventory.lua's own openK9Inventory (self-targeted
    -- here, targetServerId == source) requires HasK9Access(targetServerId)
    -- AND (a real K9 model OR the decoupled K9 role) for the K9 whose gear
    -- is being opened -- confirmed by reading it directly, and that file's
    -- own comment explicitly rejects dropping the model/role half ("HasK9Access
    -- is deliberately BROADER than the K9 role... neither of whom is
    -- actually the K9"). Same class as LeashMechanics/HandlerPartnership
    -- above; left on the broader combinator.
    K9Inventory = function()
        if not CanShowK9UI() then DenyK9UIAccess('common.no_k9_role_or_access'); return false, 'not_available' end
        if type(RequestOpenOwnK9Inventory) == 'function' then RequestOpenOwnK9Inventory() end
        return true
    end,
    -- radial.lua 'k9_treat_nearest': UNGATED here too, this pass.
    --
    -- CanShowK9UI() PRE-CHECK REMOVED (permission audit finding, this
    -- pass): "Treat K9" is a HUMAN HANDLER action, not a K9 ability --
    -- server/medkit.lua's own header states this by name ("Does NOT call
    -- HasK9Access -- eligibility to USE a medkit ON a K9 is job-only, never
    -- HasK9Access -- not the K9 being treated") and its real gate,
    -- IsMedkitUserAuthorized(source), checks Config.Departments/EmsJobSet
    -- job membership ONLY, never HasK9Access, model, or role for the USING
    -- player (confirmed by reading it directly). This wrapper used to gate
    -- that human-officer action behind CanShowK9UI() -- "must yourself
    -- currently be an on-duty, certified K9" -- which is not what the
    -- server asks of the treater at all: a plain PD/EMS officer with ZERO
    -- K9 certification of their own was refused a mechanic the server would
    -- have granted, the same "checks whether a player is SHAPED like a dog
    -- where it should check whether they HOLD the job" pattern this sweep
    -- exists to close. Matches client/radial.lua's own 'k9_treat_nearest'
    -- item, whose identical pre-check was removed in the same pass -- and
    -- matches client/medkit.lua's own RequestTreatNearestK9(), which has
    -- never had a CanShowK9UI() check of its own (confirmed by reading it
    -- directly) -- removing only the gate on ONE of the two call sites
    -- would have left the other blocking exactly what this fix exists to
    -- unblock. The server (IsMedkitUserAuthorized, per-target proximity/
    -- model/aliveness/cooldown checks) remains the real, independent
    -- authority regardless.
    K9Medkit = function()
        if type(RequestTreatNearestK9) == 'function' then RequestTreatNearestK9() end
        return true
    end,
}

RegisterNUICallback('tablet:triggerFeature', function(data, cb)
    -- Pure UX toggle, not an authorization boundary -- see SECURITY NOTE.
    if not (Config.FeatureControl and Config.FeatureControl.allowActionsFromTablet == true) then
        cb({ ok = false, error = 'actions_disabled' })
        return
    end
    if type(data) ~= 'table' or type(data.feature) ~= 'string' then
        cb({ ok = false, error = 'invalid_args' })
        return
    end

    local trigger = FEATURE_TRIGGERS[data.feature]
    if not trigger then
        cb({ ok = false, error = 'unknown_action' })
        return
    end

    local ok, errorCode = trigger()
    cb({ ok = ok == true, error = (ok ~= true) and (errorCode or 'not_available') or nil })
end)

-- ----------------------------------------------------------------------
-- PART 1 -- VIEW + mutation callbacks matching html/tablet.js's own
-- contract exactly. See this file's header NUI CONTRACT for the full
-- name/payload table.
-- ----------------------------------------------------------------------

RegisterNUICallback('tablet:ready', function(_, cb)
    cb({})
end)

RegisterNUICallback('tablet:close', function(_, cb)
    CloseTablet()
    cb({})
end)

--- CLIENT-LOCAL "who is holding it" role signal (this pass, owner-directed
--- "restructure the tablet around WHO IS HOLDING IT"). Computed ENTIRELY
--- from this player's own already-existing local state -- IsOwnModelK9()
--- (client/main.lua) and IsPartnered() (client/partnership.lua), both
--- already-allowlisted resource-globals this file calls elsewhere (SECTION
--- 2/3) -- NEVER a new server round trip, and NEVER authoritative for
--- anything: html/tablet.js uses this pair PURELY to choose which framing
--- its new Home/landing screen shows a viewer (K9 vs. handler vs.
--- partnered) ahead of the rest of MyRecordResult's own server-authoritative
--- fields (isHighCommand, certifications, myFeatures) painting the rest of
--- the picture. THE SECURITY RULE is untouched by this: neither flag is
--- ever read by, or sent back into, any mutation/trigger callback -- see
--- every RegisterNUICallback below, none of which accepts or trusts an
--- `isK9Model`/`isPartnered` argument from the client. Guarded with
--- `type(fn) == 'function'`, this resource's standard soft-dependency
--- convention -- degrades to `false` (never a crash, never a stale cached
--- guess) if either owning file is ever unavailable.
--- @return boolean isK9Model
--- @return boolean isPartnered
local function ResolveLocalRoleFlags()
    local isK9Model = type(IsOwnModelK9) == 'function' and IsOwnModelK9() == true
    local isPartnered = type(IsPartnered) == 'function' and IsPartnered() == true
    return isK9Model, isPartnered
end

--- PROPOSED server callback (not yet built -- see this pass's own
--- report). Forwarded verbatim: AwaitServerCallback's own failure shape
--- (`{ok=false, error='timeout'}`) already matches html/tablet.js's
--- `{ok:false, error, message?}` contract directly, and the proposed
--- server side is asked to return the SAME JS-shaped object on success
--- too, so this file needs zero translation logic for these.
---
--- ENRICHED THIS PASS with the two CLIENT-LOCAL role fields above --
--- ResolveLocalRoleFlags()'s own doc comment has the full reasoning.
--- Applied to the result table regardless of `ok` (a failure response
--- gains the same two fields, harmlessly ignored by a caller that only
--- ever reads them after `ok === true`) so this stays a single, simple
--- mutate-then-forward, never a second branch to keep in sync with
--- server/tablet.lua's own response shape.
RegisterNUICallback('tablet:requestMyRecord', function(_, cb)
    local result = AwaitServerCallback('qbx_k9unit:server:tabletRequestMyRecord')
    if type(result) == 'table' then
        result.isK9Model, result.isPartnered = ResolveLocalRoleFlags()
    end
    cb(result)
end)

RegisterNUICallback('tablet:requestRoster', function(data, cb)
    local query = (type(data) == 'table' and type(data.query) == 'string') and data.query or ''
    cb(AwaitServerCallback('qbx_k9unit:server:tabletRequestRoster', query))
end)

--- ONLINE PLAYERS LIST (this pass, coder-ui) -- see server/tablet.lua's
--- own "CALLBACK 2b/2c" doc comment for the full contract/reasoning.
--- Thin forward, matching tablet:requestRoster immediately above -- same
--- shape, same (server-side) audience.
RegisterNUICallback('tablet:requestOnlinePlayers', function(data, cb)
    local query = (type(data) == 'table' and type(data.query) == 'string') and data.query or ''
    cb(AwaitServerCallback('qbx_k9unit:server:tabletRequestOnlinePlayers', query))
end)

--- Resolves ONE online-players row (a server id + the opaque nonce that
--- row was minted with) to the citizenid it belonged to, freshly, at the
--- moment of this call -- see tabletResolveOnlinePlayer's own doc comment
--- (server/tablet.lua) for the RECYCLED-SOURCE-ID reasoning this exists
--- to close. `data.source` is validated as a number here ONLY as a
--- shape/type guard before the round trip -- it is never treated as an
--- authorization decision either here or server-side; the server's own
--- nonce lookup is the real check.
RegisterNUICallback('tablet:openOnlinePlayer', function(data, cb)
    if type(data) ~= 'table' or type(data.source) ~= 'number' or type(data.nonce) ~= 'string' or data.nonce == '' then
        cb({ ok = false, error = 'invalid_args' })
        return
    end
    cb(AwaitServerCallback('qbx_k9unit:server:tabletResolveOnlinePlayer', data.source, data.nonce))
end)

RegisterNUICallback('tablet:requestPersonSummary', function(data, cb)
    if type(data) ~= 'table' or type(data.targetCitizenId) ~= 'string' or data.targetCitizenId == '' then
        cb({ ok = false, error = 'invalid_args' })
        return
    end
    cb(AwaitServerCallback('qbx_k9unit:server:tabletRequestPersonSummary', data.targetCitizenId))
end)

RegisterNUICallback('tablet:requestPersonFeatures', function(data, cb)
    if type(data) ~= 'table' or type(data.targetCitizenId) ~= 'string' or data.targetCitizenId == '' then
        cb({ ok = false, error = 'invalid_args' })
        return
    end
    cb(AwaitServerCallback('qbx_k9unit:server:tabletRequestPersonFeatures', data.targetCitizenId))
end)

-- ----------------------------------------------------------------------
-- K9/HANDLER PERSONNEL ROSTERS (docs/history/ROSTER_SPEC.md, Phase B) -- owner, three
-- messages, verbatim: "make it in the tablet where there is a roster where
-- we can assign callsigns see list of hired k9s and full menu to fire
-- promote etc" / "Also a separate roster for handlers same thing" / "Also
-- in the roster be able to reorder them by rank." Three thin forwards
-- straight onto server/roster.lua's OWN `qbx_k9unit:server:roster*`
-- lib.callback registrations (Phase A, already committed) -- that file's
-- own header is explicit that it registers its OWN endpoints rather than
-- adding anything to server/tablet.lua, so these three bridges call it
-- DIRECTLY, matching that instruction exactly; no new server code, no
-- second roster-mutation path.
--
-- Every one of these three server callbacks independently re-verifies
-- IsHighCommand(source) on every call (server/roster.lua's own header,
-- THE SECURITY RULE) -- this file adds no authorization of its own, same
-- posture as every other bridge in this section.
--
-- RESULT SHAPE, forwarded VERBATIM (no ReasonToJsResult translation
-- needed -- server/roster.lua already returns THIS file's own
-- `{ok, error?}`/`{ok, outcome?}` convention directly, unlike the
-- `reason`-keyed callbacks elsewhere in this file):
--   rosterList: success   { ok = true, k9 = RosterRow[], handlers = RosterRow[], unassigned = RosterRow[] }
--               failure   { ok = false, error = 'not_authorized' | 'rate_limited' }
--   rosterSetPersonnelRole/rosterSetCallsign:
--               success   { ok = true, outcome = string }  -- see server/roster.lua's own doc comment for the exact outcome codes per callback
--               failure   { ok = false, error = string }
-- ----------------------------------------------------------------------
RegisterNUICallback('tablet:rosterList', function(_, cb)
    cb(AwaitServerCallback('qbx_k9unit:server:rosterList'))
end)

RegisterNUICallback('tablet:rosterSetPersonnelRole', function(data, cb)
    if type(data) ~= 'table' or type(data.citizenid) ~= 'string' or data.citizenid == ''
        or type(data.job) ~= 'string' or data.job == ''
        or type(data.personnelRole) ~= 'string' or data.personnelRole == '' then
        cb({ ok = false, error = 'invalid_args' })
        return
    end
    cb(AwaitServerCallback('qbx_k9unit:server:rosterSetPersonnelRole',
        { citizenid = data.citizenid, job = data.job, personnelRole = data.personnelRole }))
end)

--- `data.callsign` may be a non-empty string (set), an empty string, or
--- omitted entirely (both of the latter two CLEAR the callsign --
--- server/roster.lua's own RosterSetCallsign already normalizes '' to nil
--- itself; this bridge does not duplicate that normalization, it only
--- checks the TYPE is safe to forward -- a non-string, non-nil value is
--- the one shape rejected here).
RegisterNUICallback('tablet:rosterSetCallsign', function(data, cb)
    if type(data) ~= 'table' or type(data.citizenid) ~= 'string' or data.citizenid == ''
        or type(data.job) ~= 'string' or data.job == ''
        or (data.callsign ~= nil and type(data.callsign) ~= 'string') then
        cb({ ok = false, error = 'invalid_args' })
        return
    end
    cb(AwaitServerCallback('qbx_k9unit:server:rosterSetCallsign',
        { citizenid = data.citizenid, job = data.job, callsign = data.callsign }))
end)

--- THE PARTNERSHIPS TAB (this pass, coder-ui) -- see server/tablet.lua's
--- own "CALLBACKS 7-9" doc comment for the full contract/reasoning; three
--- thin forwards below, matching this file's own established shape for
--- every other read (requestRoster/requestPersonSummary above).
---
--- tabletRequestMyPartnerships alone gets ONE extra step: tier richness
--- for the caller's own ACTIVE row (if any) is composed in HERE from the
--- ALREADY-SHIPPED 'qbx_k9unit:server:getPartnershipTenureProgress'
--- (server/tenure.lua), a second, cheap, already-client-triggerable
--- AwaitServerCallback -- never a new query shape on the server, and never
--- attempted for tablet:requestPartnershipsForTarget's admin lookup below
--- (that callback has no target argument, so it can only ever answer for
--- THIS caller, exactly like every other self-only tenure read in this
--- file).
RegisterNUICallback('tablet:requestMyPartnerships', function(_, cb)
    local result = AwaitServerCallback('qbx_k9unit:server:tabletRequestMyPartnerships')
    if type(result) == 'table' and result.ok == true and type(result.partnerships) == 'table' then
        for _, row in ipairs(result.partnerships) do
            if row.active == true then
                local progress = AwaitServerCallback('qbx_k9unit:server:getPartnershipTenureProgress')
                if type(progress) == 'table' then
                    row.tenureProgress = progress
                end
                break -- at most one active row -- server/partnership.lua's own verified one-active-partnership-per-citizenid invariant
            end
        end
    end
    cb(result)
end)

--- HIGH COMMAND ONLY (re-verified server-side, this page decides nothing
--- -- see this file's own header). Owner: "high command... should have
--- control over it also."
RegisterNUICallback('tablet:requestPartnershipsForTarget', function(data, cb)
    if type(data) ~= 'table' or type(data.targetCitizenId) ~= 'string' or data.targetCitizenId == '' then
        cb({ ok = false, error = 'invalid_args' })
        return
    end
    cb(AwaitServerCallback('qbx_k9unit:server:tabletRequestPartnershipsForTarget', data.targetCitizenId))
end)

--- HIGH COMMAND ONLY -- the "control" write half, over server/partnership.lua's
--- EXISTING ForceBreakPartnershipForCitizenId (server/tablet.lua's own
--- CALLBACK 9 doc comment has the full "not a new teardown mechanism"
--- writeup).
RegisterNUICallback('tablet:forceEndPartnership', function(data, cb)
    if type(data) ~= 'table' or type(data.targetCitizenId) ~= 'string' or data.targetCitizenId == '' then
        cb({ ok = false, error = 'invalid_args' })
        return
    end
    cb(AwaitServerCallback('qbx_k9unit:server:tabletForceEndPartnership', data.targetCitizenId))
end)

RegisterNUICallback('tablet:certify', function(data, cb)
    -- UPDATED THIS PASS (coordinator-directed follow-up): this comment
    -- used to say certify has "no offline-capable equivalent to reuse,
    -- unlike decertify below" -- that was true when it was written, but
    -- server/certifications/'s own GrantCertificationForTablet now
    -- resolves an offline `targetCitizenId` to GrantCertificationOffline
    -- internally (see that function's own header for the full "why this
    -- is now safe on the shipped Config.K9Appearance.requireK9ModelForRole
    -- default, and when it deliberately still refuses" writeup). NO CHANGE
    -- NEEDED HERE: this callback was already citizenid-keyed and already
    -- forwarded verbatim, so it transparently gained offline support the
    -- moment the server side did -- exactly like decertify below already
    -- worked this way for revoke.
    if type(data) ~= 'table' or type(data.targetCitizenId) ~= 'string' or data.targetCitizenId == ''
        or type(data.departmentKey) ~= 'string' or data.departmentKey == '' then
        cb({ ok = false, error = 'invalid_args' })
        return
    end
    -- k9Model is optional: absent certifies a handler, a model name
    -- certifies them as a K9 of that breed. Anything else is refused here
    -- rather than silently treated as "handler".
    if data.k9Model ~= nil and (type(data.k9Model) ~= 'string' or data.k9Model == '') then
        cb({ ok = false, error = 'invalid_args' })
        return
    end
    cb(AwaitServerCallback('qbx_k9unit:server:tabletCertify', data.targetCitizenId, data.departmentKey, data.k9Model))
end)

RegisterNUICallback('tablet:decertify', function(data, cb)
    -- BUGFIX (this pass, docs/history/COMMAND_CONSOLIDATION_SPEC.md §6): this callback
    -- used to shell out to the OFFLINE-ONLY '/k9decertifyoffline <citizenid>
    -- <job>' command via a SubmitAllowlistedCommand/ExecuteCommand bridge,
    -- for EVERY target regardless of online state. That command's own
    -- RevokeCertificationOffline (server/certifications/) explicitly
    -- REFUSES when the citizenid resolves to a currently connected player
    -- (its own proximity-check-integrity guard) -- so clicking Decertify
    -- against an ONLINE person always hit that refusal and did nothing,
    -- contradicting this button's own documented "works for an ONLINE or
    -- OFFLINE target" contract (see tablet:certify immediately above, which
    -- always worked this way). Now calls the SAME kind of real server
    -- callback tablet:certify already uses -- server/certifications/'s
    -- new RevokeCertificationForTablet (via qbx_k9unit:server:tabletDecertify)
    -- resolves online-vs-offline itself and runs the online path's REAL,
    -- UNCHANGED proximity/self-cert/eligibility rules when the target is
    -- online, exactly like a live '/k9decertify [server id]' would -- never
    -- weakened to make this button easier than the command it now mirrors.
    if not (Config.FeatureControl and Config.FeatureControl.allowActionsFromTablet == true) then
        cb({ ok = false, error = 'actions_disabled' })
        return
    end
    if type(data) ~= 'table' or type(data.targetCitizenId) ~= 'string' or data.targetCitizenId == ''
        or type(data.departmentKey) ~= 'string' or data.departmentKey == '' then
        cb({ ok = false, error = 'invalid_args' })
        return
    end
    cb(AwaitServerCallback('qbx_k9unit:server:tabletDecertify', data.targetCitizenId, data.departmentKey))
end)

-- ----------------------------------------------------------------------
-- CERTIFICATION TIER / RENEWAL / SPECIALIZATION -- closing this file's own
-- biggest remaining "reachable only via net event/command, no tablet path
-- at all" gap (server/certifications/'s SetCertificationTier/
-- RenewCertification/GrantSpecialization/RevokeSpecialization). Forwarded
-- VERBATIM, mirroring tablet:certify/tablet:grantPermission's own shape
-- EXACTLY: each server callback (server/certifications/'s
-- tabletSetCertificationTier/tabletRenewCertification/
-- tabletGrantSpecialization/tabletRevokeSpecialization) already returns
-- this contract's `{ok, error?}` shape directly (no `reason` field to
-- translate, unlike TranslateReasonResult's targets below), already
-- re-verifies IsEligibleCertifier/the shared cooldown/TierEditMutex
-- internally, and already resolves online-vs-offline targets itself --
-- this file adds no authorization, no online/offline branching, and no
-- second mutation path of its own. `departmentKey` selects WHICH of the
-- target's per-department certification rows to act on (the tablet
-- already renders one row per configured department, see
-- buildCertificationRow) -- never used to override the target's actual
-- live job when online (server-side `department_mismatch` handles that).
-- ----------------------------------------------------------------------
RegisterNUICallback('tablet:setCertificationTier', function(data, cb)
    if type(data) ~= 'table' or type(data.targetCitizenId) ~= 'string' or data.targetCitizenId == ''
        or type(data.departmentKey) ~= 'string' or data.departmentKey == ''
        or type(data.tier) ~= 'string' or data.tier == '' then
        cb({ ok = false, error = 'invalid_args' })
        return
    end
    cb(AwaitServerCallback('qbx_k9unit:server:tabletSetCertificationTier', data.targetCitizenId, data.departmentKey, data.tier))
end)

RegisterNUICallback('tablet:renewCertification', function(data, cb)
    if type(data) ~= 'table' or type(data.targetCitizenId) ~= 'string' or data.targetCitizenId == ''
        or type(data.departmentKey) ~= 'string' or data.departmentKey == '' then
        cb({ ok = false, error = 'invalid_args' })
        return
    end
    cb(AwaitServerCallback('qbx_k9unit:server:tabletRenewCertification', data.targetCitizenId, data.departmentKey))
end)

RegisterNUICallback('tablet:grantSpecialization', function(data, cb)
    if type(data) ~= 'table' or type(data.targetCitizenId) ~= 'string' or data.targetCitizenId == ''
        or type(data.departmentKey) ~= 'string' or data.departmentKey == ''
        or type(data.specialization) ~= 'string' or data.specialization == '' then
        cb({ ok = false, error = 'invalid_args' })
        return
    end
    cb(AwaitServerCallback('qbx_k9unit:server:tabletGrantSpecialization', data.targetCitizenId, data.departmentKey, data.specialization))
end)

RegisterNUICallback('tablet:revokeSpecialization', function(data, cb)
    if type(data) ~= 'table' or type(data.targetCitizenId) ~= 'string' or data.targetCitizenId == ''
        or type(data.departmentKey) ~= 'string' or data.departmentKey == ''
        or type(data.specialization) ~= 'string' or data.specialization == '' then
        cb({ ok = false, error = 'invalid_args' })
        return
    end
    cb(AwaitServerCallback('qbx_k9unit:server:tabletRevokeSpecialization', data.targetCitizenId, data.departmentKey, data.specialization))
end)

RegisterNUICallback('tablet:givexp', function(data, cb)
    -- PROPOSED server callback -- see this pass's own report.
    -- server/highcommand.lua's AwardXPDirect(citizenid, amount, reason)
    -- already takes a citizenid directly; this needs that same file's
    -- IsHighCommand/maxXpPerGrant/allowSelfGrant/cooldown/audit checks
    -- wrapped for a citizenid target instead of '/k9givexp's server-id one
    -- -- that file has a live owner, so not built here.
    if type(data) ~= 'table' or type(data.targetCitizenId) ~= 'string' or data.targetCitizenId == ''
        or type(data.amount) ~= 'number' then
        cb({ ok = false, error = 'invalid_args' })
        return
    end
    cb(AwaitServerCallback('qbx_k9unit:server:tabletGiveXp', data.targetCitizenId, data.amount))
end)

--- Translates server/permissions.lua's REAL, already-built response shape
--- (`{ok=true}` | `{ok=true, reason=stillHasAccess}` | `{ok=false,
--- reason=outcome}`) into html/tablet.js's `{ok, error?, message?}`
--- contract. The two `reason` values a successful revoke can still carry
--- (permissions.lua's header: "the tablet is expected to render THREE
--- distinct messages, not two") get real, locale-resolved text; anything
--- else on a failure path is forwarded as an opaque `error` code (JS's
--- own errorText() falls back to a generic message for a code it doesn't
--- specifically recognize -- acceptable today, no player-facing meaning
--- is lost, just not maximally specific).
--- @param serverResult table
--- @return table
local function ReasonToJsResult(serverResult)
    if type(serverResult) ~= 'table' then return { ok = false, error = 'server_error' } end
    if serverResult.ok ~= true then
        return { ok = false, error = serverResult.error or serverResult.reason or 'server_error' }
    end
    if serverResult.reason == 'rank_or_high_command' then
        return { ok = true, message = SafeLocale('tablet.revoke_still_has_access') }
    elseif serverResult.reason == 'unknown_target_offline' then
        return { ok = true, message = SafeLocale('tablet.revoke_target_offline') }
    end
    return { ok = true }
end

--- Shared shape guard for every grant/revoke/feature/block mutation below.
--- @param data any
--- @return boolean
local function IsValidTargetKeyPayload(data, keyField)
    return type(data) == 'table'
        and type(data.targetCitizenId) == 'string' and data.targetCitizenId ~= ''
        and type(data[keyField]) == 'string' and data[keyField] ~= ''
end

RegisterNUICallback('tablet:grantPermission', function(data, cb)
    if not IsValidTargetKeyPayload(data, 'permission') then
        cb({ ok = false, error = 'invalid_args' })
        return
    end
    cb(ReasonToJsResult(AwaitServerCallback('qbx_k9unit:server:tabletGrantPermission', data.targetCitizenId, data.permission)))
end)

RegisterNUICallback('tablet:revokePermission', function(data, cb)
    if not IsValidTargetKeyPayload(data, 'permission') then
        cb({ ok = false, error = 'invalid_args' })
        return
    end
    cb(ReasonToJsResult(AwaitServerCallback('qbx_k9unit:server:tabletRevokePermission', data.targetCitizenId, data.permission)))
end)

-- Feature grant/revoke/block/unblock all reuse the SAME two, already-built
-- server callbacks with the 'feature.<Name>'/'block.<Name>' key namespace
-- server/permissions.lua's own header documents -- no new server code.
RegisterNUICallback('tablet:grantFeature', function(data, cb)
    if not IsValidTargetKeyPayload(data, 'feature') then
        cb({ ok = false, error = 'invalid_args' })
        return
    end
    cb(ReasonToJsResult(AwaitServerCallback('qbx_k9unit:server:tabletGrantPermission', data.targetCitizenId, 'feature.' .. data.feature)))
end)

RegisterNUICallback('tablet:revokeFeature', function(data, cb)
    if not IsValidTargetKeyPayload(data, 'feature') then
        cb({ ok = false, error = 'invalid_args' })
        return
    end
    cb(ReasonToJsResult(AwaitServerCallback('qbx_k9unit:server:tabletRevokePermission', data.targetCitizenId, 'feature.' .. data.feature)))
end)

RegisterNUICallback('tablet:blockFeature', function(data, cb)
    if not IsValidTargetKeyPayload(data, 'feature') then
        cb({ ok = false, error = 'invalid_args' })
        return
    end
    cb(ReasonToJsResult(AwaitServerCallback('qbx_k9unit:server:tabletGrantPermission', data.targetCitizenId, 'block.' .. data.feature)))
end)

RegisterNUICallback('tablet:unblockFeature', function(data, cb)
    if not IsValidTargetKeyPayload(data, 'feature') then
        cb({ ok = false, error = 'invalid_args' })
        return
    end
    cb(ReasonToJsResult(AwaitServerCallback('qbx_k9unit:server:tabletRevokePermission', data.targetCitizenId, 'block.' .. data.feature)))
end)

-- ----------------------------------------------------------------------
-- K9 ROLE ASSIGN / REVERT-TO-HUMAN -- owner's own words: "assign de
-- assign give certs remove certs remove k9 ped and reverts them to a
-- human". Both forwarded VERBATIM -- server/tablet.lua's own
-- tabletAssignK9Role/tabletRevertK9Ped already return this exact
-- {ok,error?,message?} shape and already re-verify IsHighCommand
-- themselves (see that file's own header); this file adds no
-- authorization and no second appearance-mutation path. THE TABLET IS A
-- VIEW. IT DECIDES NOTHING -- same rule as every other mutation above.
-- ----------------------------------------------------------------------
RegisterNUICallback('tablet:assignK9Role', function(data, cb)
    if type(data) ~= 'table' or type(data.targetCitizenId) ~= 'string' or data.targetCitizenId == ''
        or type(data.modelName) ~= 'string' or data.modelName == '' then
        cb({ ok = false, error = 'invalid_args' })
        return
    end
    cb(AwaitServerCallback('qbx_k9unit:server:tabletAssignK9Role', data.targetCitizenId, data.modelName))
end)

--- NO UNBOUNDED TRAP: server/tablet.lua's tabletRevertK9Ped gates purely on
--- the CALLER's own IsHighCommand, never on anything about the target, so
--- this must work for a target who has already lost every certification/
--- grant/feature check -- see this file's own header NUI CONTRACT note.
RegisterNUICallback('tablet:revertK9Ped', function(data, cb)
    if type(data) ~= 'table' or type(data.targetCitizenId) ~= 'string' or data.targetCitizenId == '' then
        cb({ ok = false, error = 'invalid_args' })
        return
    end
    cb(AwaitServerCallback('qbx_k9unit:server:tabletRevertK9Ped', data.targetCitizenId))
end)

-- ----------------------------------------------------------------------
-- TABLET THEMING -- Config.Features.TabletTheming. COSMETIC ONLY (see
-- server/runtimecontrol.lua's own PART 2 header): nothing a theme value
-- carries is ever consulted by an authorization check, here or anywhere
-- else in this resource. getTheme has no authorization gate server-side
-- at all (applied for every viewer); setTheme/resetTheme re-check high
-- command server-side regardless of what this page shows or hides.
-- ----------------------------------------------------------------------

--- SHARED translator for every tablet-facing surface that mirrors
--- server/runtimecontrol.lua's own raw `{ok, reason?, ...}` response shape
--- DIRECTLY, rather than this contract's own `{ok, error?, message?}`
--- shape -- currently server/runtimecontrol.lua's own tabletGetTheme/
--- tabletSetTheme/tabletResetTheme (Config.Features.TabletTheming) AND
--- server/certtiers.lua's certTiersList/certTiersUpsert/certTiersReorder/
--- certTiersDelete, whose OWN header says so explicitly: "Response shape
--- mirrors server/runtimecontrol.lua's own `{ ok, reason, ... }` convention
--- exactly, for consistency across this resource's tablet-facing surfaces."
---
--- THE ASYMMETRY THIS FIXES (flagged by the server side, bridged here --
--- CLIENT/coder-ui owns this translation, not server/certtiers.lua, so
--- that file's own response shape can keep matching its sibling
--- server/runtimecontrol.lua's convention without also having to know
--- anything about html/tablet.js's separate, older `error`-keyed
--- contract): every OTHER tablet mutation in this resource already
--- resolves to `{ok, error?, message?}` by the time it reaches
--- html/tablet.js -- ReasonToJsResult above performs the identical
--- `reason` -> `error` rename for server/permissions.lua's grant/revoke
--- pair. Left unbridged, a rejected cert-tier/theme edit would arrive at
--- the NUI as `{ok:false, reason:'...'}` with NO `error` key at all --
--- html/tablet.js's own errorText()/generic failure-notice paths only ever
--- read `.error`/`.message`, so the tablet would render nothing, the
--- single worst outcome for an admin tool (a click that visibly does
--- nothing is indistinguishable from a hang).
---
--- Deliberately GENERIC, not hand-listing each surface's own extra fields
--- (theme/field/tiers/capabilityCatalog/warning/referenceCount, ...): every
--- key from `serverResult` is forwarded verbatim except `reason` itself,
--- which is renamed to `error` (only when `ok` is not `true`, and only if
--- `error` was not already set some other way) and then removed, since the
--- JS-facing contract has no `reason` field of its own to leave dangling
--- alongside it. A future fifth surface built the same way needs no edit
--- here at all.
--- @param serverResult table
--- @return table
local function TranslateReasonResult(serverResult)
    if type(serverResult) ~= 'table' then return { ok = false, error = 'server_error' } end
    local out = {}
    for k, v in pairs(serverResult) do out[k] = v end
    if out.ok ~= true and out.error == nil then
        out.error = out.reason or 'server_error'
    end
    out.reason = nil
    return out
end

RegisterNUICallback('tablet:getTheme', function(_, cb)
    cb(TranslateReasonResult(AwaitServerCallback('qbx_k9unit:server:tabletGetTheme')))
end)

RegisterNUICallback('tablet:setTheme', function(data, cb)
    -- Deliberately NO field-by-field re-validation here beyond "is this
    -- even a table" -- server/runtimecontrol.lua's ValidateFullTheme is
    -- the real, strict gate (exact #RRGGBB match, a fixed density enum, a
    -- <=40-char/no-markup header title) and this file must never re-derive
    -- or loosen that; a modified client sending a bogus payload gets back
    -- {ok=false, error='invalid_field', field=...} same as a legitimate one
    -- that somehow raced a config change.
    if type(data) ~= 'table' then
        cb({ ok = false, error = 'invalid_args' })
        return
    end
    cb(TranslateReasonResult(AwaitServerCallback('qbx_k9unit:server:tabletSetTheme', data)))
end)

RegisterNUICallback('tablet:resetTheme', function(_, cb)
    cb(TranslateReasonResult(AwaitServerCallback('qbx_k9unit:server:tabletResetTheme')))
end)

-- ----------------------------------------------------------------------
-- CERTIFICATION TIER EDITING -- server/certtiers.lua, high command only
-- (CanManageCertTiers re-checked there on every call; this file adds no
-- authorization of its own). Every payload shape below is forwarded
-- EXACTLY as that file's own callbacks expect -- see its own header
-- "CALLBACKS" section: certTiersUpsert takes the WHOLE {key,label,
-- capabilities:string[]} table as one argument (mirrors tablet:setTheme's
-- own whole-table forwarding just above), certTiersReorder takes a bare
-- array of tier key strings, certTiersDelete takes a bare key string.
-- ----------------------------------------------------------------------

RegisterNUICallback('tablet:certTiersList', function(_, cb)
    cb(TranslateReasonResult(AwaitServerCallback('qbx_k9unit:server:certTiersList')))
end)

RegisterNUICallback('tablet:certTiersUpsert', function(data, cb)
    if type(data) ~= 'table' or type(data.key) ~= 'string' or data.key == '' then
        cb({ ok = false, error = 'invalid_args' })
        return
    end
    cb(TranslateReasonResult(AwaitServerCallback('qbx_k9unit:server:certTiersUpsert', data)))
end)

RegisterNUICallback('tablet:certTiersReorder', function(data, cb)
    if type(data) ~= 'table' or type(data.orderedKeys) ~= 'table' then
        cb({ ok = false, error = 'invalid_args' })
        return
    end
    cb(TranslateReasonResult(AwaitServerCallback('qbx_k9unit:server:certTiersReorder', data.orderedKeys)))
end)

RegisterNUICallback('tablet:certTiersDelete', function(data, cb)
    if type(data) ~= 'table' or type(data.key) ~= 'string' or data.key == '' then
        cb({ ok = false, error = 'invalid_args' })
        return
    end
    -- 'tier_in_use'/'protected_tier' are REFUSALS ("cannot, and here is
    -- why"), not errors -- forwarded through the SAME translation
    -- regardless (TranslateReasonResult does not distinguish a refusal
    -- from a failure; html/tablet.js's own certTierErrorText() is what
    -- renders 'tier_in_use' with its own explanatory copy instead of a
    -- generic failure message -- see that function for the full list).
    cb(TranslateReasonResult(AwaitServerCallback('qbx_k9unit:server:certTiersDelete', data.key)))
end)

-- ----------------------------------------------------------------------
-- PERMISSION-KEY CATALOG EDITING -- server/permissionkeycatalog.lua, high
-- command only (CanManagePermissionKeys re-checked there on every call;
-- this file adds no authorization of its own). Owner's own words for this
-- pass: "...even add or remove permissions" -- the second half of the same
-- ask server/certtiers.lua's own tier-editing screen above already
-- answers for certification ROLES. Sits alongside that screen in
-- html/tablet.js, not in a new unrelated place. Same "CALLBACKS" shape as
-- certTiers* above: permKeysUpsert takes the WHOLE {key,label,description?}
-- table as one argument, permKeysDelete takes a bare key string. There is
-- no reorder counterpart -- a permission key carries no ordinal (see
-- server/permissionkeycatalog.lua's own header "WHY NO ORDINAL").
-- ----------------------------------------------------------------------

RegisterNUICallback('tablet:permKeysList', function(_, cb)
    cb(TranslateReasonResult(AwaitServerCallback('qbx_k9unit:server:permKeysList')))
end)

RegisterNUICallback('tablet:permKeysUpsert', function(data, cb)
    if type(data) ~= 'table' or type(data.key) ~= 'string' or data.key == '' then
        cb({ ok = false, error = 'invalid_args' })
        return
    end
    cb(TranslateReasonResult(AwaitServerCallback('qbx_k9unit:server:permKeysUpsert', data)))
end)

RegisterNUICallback('tablet:permKeysDelete', function(data, cb)
    if type(data) ~= 'table' or type(data.key) ~= 'string' or data.key == '' then
        cb({ ok = false, error = 'invalid_args' })
        return
    end
    -- 'reserved_namespace'/'unknown_key' are REFUSALS ("cannot, and here is
    -- why"), not failures -- forwarded through the SAME translation
    -- regardless, same posture as certTiersDelete's own 'tier_in_use'/
    -- 'protected_tier' immediately above.
    cb(TranslateReasonResult(AwaitServerCallback('qbx_k9unit:server:permKeysDelete', data.key)))
end)

-- ----------------------------------------------------------------------
-- XP-RANK EDITOR -- server/xptiers.lua, high command only
-- (CanManageXPTiers re-checked there on every call; this file adds no
-- authorization of its own). Owner's own words for this pass: "...set
-- experience level for each rank up etc." -- the OTHER half of the same
-- quote server/permissionkeycatalog.lua's own screen above answers for
-- permission keys. Same "CALLBACKS" shape as certTiers*/permKeys* above:
-- xpTiersUpsert takes the WHOLE payload table as one argument. There is no
-- delete/create/reorder counterpart -- see server/xptiers.lua's own header
-- "SCOPE DECISION" for why this pass edits existing ranks only.
-- ----------------------------------------------------------------------

RegisterNUICallback('tablet:xpTiersList', function(_, cb)
    cb(TranslateReasonResult(AwaitServerCallback('qbx_k9unit:server:xpTiersList')))
end)

RegisterNUICallback('tablet:xpTiersUpsert', function(data, cb)
    if type(data) ~= 'table' or type(data.ordinal) ~= 'number' then
        cb({ ok = false, error = 'invalid_args' })
        return
    end
    -- 'base_tier_xp_fixed' is a REFUSAL ("cannot, and here is why" -- rank
    -- 1 must always be exactly 0 XP), not a failure -- forwarded through
    -- the SAME translation regardless, same posture as certTiersDelete's
    -- own 'tier_in_use'/'protected_tier' above.
    cb(TranslateReasonResult(AwaitServerCallback('qbx_k9unit:server:xpTiersUpsert', data)))
end)

-- ----------------------------------------------------------------------
-- K9 INDIVIDUAL OVERRIDES -- server/k9profiles.lua, high command only
-- (CanManageK9Profiles re-checked there on every one of the four calls
-- below; this file adds no authorization of its own). Owner's own words
-- for this pass: high command should be "a god over that tablet with
-- full customization over everything related to that K9." Lets high
-- command hand-tune ONE dog's speed/scent-range/medkit-cooldown
-- multipliers above and beyond whatever its handler's XP tier already
-- gives it, without moving the whole tier (see that file's own header
-- "RESOLUTION ORDER"). Same `{ ok, reason, ... }` outcome shape as every
-- other tablet-facing catalog above -- routed through the SAME
-- TranslateReasonResult.
--
-- UPDATE (coder-backend, same day as the note this replaces):
-- server/progression.lua's GetXPTierMedkitCooldownMs and
-- BuildEffectiveTierSnapshot/PushTierSnapshot now both consult
-- `GetK9EffectiveMultipliers(citizenid)` -- verified directly against
-- that file's source. An override saved here is a REAL, live gameplay
-- change (medkit cooldown, and the speed/scent values pushed to the
-- target's own client via 'qbx_k9unit:client:xpTierChanged'), not merely
-- stored. It does NOT push an immediate refresh to an already-connected
-- target on its own, though -- the new value applies the next time that
-- citizenid's tier is naturally re-resolved (XP award, reconnect, or this
-- resource's own onResourceStart backfill). html/tablet.js's own K9
-- profile screen states that caveat plainly.
-- ----------------------------------------------------------------------

RegisterNUICallback('tablet:k9ProfilesList', function(_, cb)
    cb(TranslateReasonResult(AwaitServerCallback('qbx_k9unit:server:k9ProfilesList')))
end)

RegisterNUICallback('tablet:k9ProfileGet', function(data, cb)
    if type(data) ~= 'table' or type(data.citizenid) ~= 'string' or data.citizenid == '' then
        cb({ ok = false, error = 'invalid_args' })
        return
    end
    cb(TranslateReasonResult(AwaitServerCallback('qbx_k9unit:server:k9ProfileGet', data.citizenid)))
end)

RegisterNUICallback('tablet:k9ProfileUpsert', function(data, cb)
    if type(data) ~= 'table' or type(data.citizenid) ~= 'string' or data.citizenid == '' then
        cb({ ok = false, error = 'invalid_args' })
        return
    end
    cb(TranslateReasonResult(AwaitServerCallback('qbx_k9unit:server:k9ProfileUpsert', data)))
end)

RegisterNUICallback('tablet:k9ProfileReset', function(data, cb)
    if type(data) ~= 'table' or type(data.citizenid) ~= 'string' or data.citizenid == '' then
        cb({ ok = false, error = 'invalid_args' })
        return
    end
    cb(TranslateReasonResult(AwaitServerCallback('qbx_k9unit:server:k9ProfileReset', data.citizenid)))
end)

-- ----------------------------------------------------------------------
-- K9 EQUIPMENT SHOP LOCATIONS -- server/equipmentshop.lua, high command
-- only (CanManageShopLocations re-checked there on every mutating call;
-- GetLocations itself has no gate server-side at all -- see this file's
-- header NUI CONTRACT note). Owner's own words: "make the shop a dog ped
-- and i can change the locations in the config or add more locations
-- remove locations etc along with in the high command tablet."
--
-- COORDINATES: html/tablet.js (a CEF browser page) has NO native access to
-- GetEntityCoords/GetEntityHeading -- this file is the ONLY place in the
-- whole round trip that can capture "where is the caller standing right
-- now," so both mutating callbacks below do it themselves, at the moment
-- each fires, rather than trusting anything the NUI payload claims (which
-- could not even supply it in the first place). Every response is routed
-- through the SAME TranslateReasonResult already used for theme/cert-tier
-- calls above -- server/equipmentshop.lua's own header states its response
-- shape is a plain `{ ok, reason, ... }` outcome table, identical
-- convention.
-- ----------------------------------------------------------------------

RegisterNUICallback('tablet:equipmentShopGetLocations', function(_, cb)
    cb(TranslateReasonResult(AwaitServerCallback('qbx_k9unit:server:equipmentShopGetLocations')))
end)

--- DISCLOSED SIMPLIFICATION: a blank label/model/scenario field in the NUI
--- payload is OMITTED here entirely (never forwarded as `''`, which the
--- server's own IsSafeShortString would reject as invalid) -- meaning
--- "inherit the shop-wide default," exactly like a config.lua location
--- entry with that field left unset. This contract has no way to ADD a
--- location with an EXPLICIT "no scenario even though the shop default has
--- one" override in one step (unlike editing one afterward, just below,
--- which can via `false`) -- an operator who needs that reaches for Edit
--- immediately after adding. See html/tablet.js's own comment on its Add
--- form for the matching client-side half of this choice.
RegisterNUICallback('tablet:equipmentShopAddLocation', function(data, cb)
    data = type(data) == 'table' and data or {}

    local ped = PlayerPedId()
    local coords = GetEntityCoords(ped)
    local location = {
        x = coords.x,
        y = coords.y,
        z = coords.z,
        heading = GetEntityHeading(ped),
    }
    if type(data.label) == 'string' and data.label ~= '' then location.label = data.label end
    if type(data.model) == 'string' and data.model ~= '' then location.model = data.model end
    if type(data.scenario) == 'string' and data.scenario ~= '' then location.scenario = data.scenario end

    cb(TranslateReasonResult(AwaitServerCallback('qbx_k9unit:server:equipmentShopAddLocation', location)))
end)

--- Serves BOTH this screen's "Edit" (metadata only) and "Move Here"
--- (position only) actions -- ONE server callback, so both flow through
--- here rather than each inventing its own. See this file's header NUI
--- CONTRACT note for the full `updates`/`useCurrentPosition` shape.
RegisterNUICallback('tablet:equipmentShopMoveLocation', function(data, cb)
    if type(data) ~= 'table' or type(data.locationKey) ~= 'string' or data.locationKey == '' then
        cb({ ok = false, error = 'invalid_key' })
        return
    end

    local updates = {}
    if type(data.updates) == 'table' then
        -- ALWAYS forwarded when present (never omitted for being blank,
        -- unlike Add above) -- an edit draft always starts pre-filled from
        -- a real, already-resolved value (server/equipmentshop.lua's own
        -- ShopLocation class: model/label are "already resolved ... never
        -- nil/empty"; scenario's OWN doc comment there is narrower --
        -- "'' means 'no scenario', never nil" -- so a blank scenario field
        -- can legitimately mean "already resolved to no scenario," not
        -- only "untouched"), so html/tablet.js sends `false` for a field
        -- the operator deliberately blanked out (reset to the shop-wide
        -- default -- a genuine no-op if that field already resolved to
        -- empty/default) and a non-empty string for a real override --
        -- both are meaningful values this file must not silently drop.
        if data.updates.label ~= nil then updates.label = data.updates.label end
        if data.updates.model ~= nil then updates.model = data.updates.model end
        if data.updates.scenario ~= nil then updates.scenario = data.updates.scenario end
    end

    if data.useCurrentPosition == true then
        local ped = PlayerPedId()
        local coords = GetEntityCoords(ped)
        updates.x, updates.y, updates.z = coords.x, coords.y, coords.z
        updates.heading = GetEntityHeading(ped)
    end

    cb(TranslateReasonResult(AwaitServerCallback('qbx_k9unit:server:equipmentShopMoveLocation', data.locationKey, updates)))
end)

RegisterNUICallback('tablet:equipmentShopRemoveLocation', function(data, cb)
    if type(data) ~= 'table' or type(data.locationKey) ~= 'string' or data.locationKey == '' then
        cb({ ok = false, error = 'invalid_key' })
        return
    end
    cb(TranslateReasonResult(AwaitServerCallback('qbx_k9unit:server:equipmentShopRemoveLocation', data.locationKey)))
end)

-- ----------------------------------------------------------------------
-- K9 EQUIPMENT SHOP ITEM CATALOG -- server/equipmentshop.lua's own
-- "EQUIPMENT SHOP ITEM CATALOG" section, high command only
-- (CanManageShopItems re-checked there on every one of these four calls;
-- this file adds no authorization of its own). Owner's own words: "give
-- high command real control over the equipment shop" -- which items are
-- sold, at what price, in what order, and under what certification-tier/
-- specialization purchase requirement. Mirrors the CERTIFICATION TIER
-- EDITING bridge immediately above in EVERY respect (same
-- TranslateReasonResult response translation, same "forward the whole
-- payload table verbatim for Upsert, a bare array for Reorder, a bare
-- string key for Delete" shapes) -- see that section's own comment for
-- why each shape is what it is; not repeated here.
--
-- equipmentShopItemsUpsert payload: { key: string, price: number,
--   label?: string, currency?: string, requiredTierKey?: string,
--   requiredSpecialization?: string } -- forwarded to
--   server/equipmentshop.lua's own ShopItemsUpsert EXACTLY as received;
--   every field is re-validated server-side regardless of what this file
--   does or does not check first (this file's own checks below are a UX
--   convenience only -- an early, cheap rejection before a round trip for
--   the one shape server/equipmentshop.lua's own validator could never
--   accept anyway).
-- ----------------------------------------------------------------------

RegisterNUICallback('tablet:equipmentShopItemsList', function(_, cb)
    cb(TranslateReasonResult(AwaitServerCallback('qbx_k9unit:server:equipmentShopItemsList')))
end)

RegisterNUICallback('tablet:equipmentShopItemsUpsert', function(data, cb)
    if type(data) ~= 'table' or type(data.key) ~= 'string' or data.key == '' or type(data.price) ~= 'number' then
        cb({ ok = false, error = 'invalid_args' })
        return
    end
    cb(TranslateReasonResult(AwaitServerCallback('qbx_k9unit:server:equipmentShopItemsUpsert', data)))
end)

RegisterNUICallback('tablet:equipmentShopItemsReorder', function(data, cb)
    if type(data) ~= 'table' or type(data.orderedKeys) ~= 'table' then
        cb({ ok = false, error = 'invalid_args' })
        return
    end
    cb(TranslateReasonResult(AwaitServerCallback('qbx_k9unit:server:equipmentShopItemsReorder', data.orderedKeys)))
end)

RegisterNUICallback('tablet:equipmentShopItemsDelete', function(data, cb)
    if type(data) ~= 'table' or type(data.key) ~= 'string' or data.key == '' then
        cb({ ok = false, error = 'invalid_args' })
        return
    end
    cb(TranslateReasonResult(AwaitServerCallback('qbx_k9unit:server:equipmentShopItemsDelete', data.key)))
end)

-- ----------------------------------------------------------------------
-- RUNTIME FEATURE CONTROL + TUNING -- server/runtimecontrol.lua PART 1/1B,
-- high command only (CanManageRuntimeControl re-checked there on every one
-- of these six calls; this file adds no authorization of its own). Owner's
-- own words: "Lets high command switch features on and off SERVER-WIDE
-- from the tablet, and tune numbers live." Every response is routed
-- through the SAME TranslateReasonResult already used for theme/cert-tier/
-- shop-location calls above -- server/runtimecontrol.lua's own header
-- states its response shape is the identical `{ ok, reason, ... }` outcome
-- table convention.
--
-- THE ENGINE CONSTRAINT, bridged honestly: server/runtimecontrol.lua's own
-- header classifies every feature into one of five tiers
-- (live/onstart/rawtoplevel/clientonly/protected, plus 'unaudited' for a
-- feature its own FEATURE_TIERS table has never classified) describing
-- whether a toggle takes effect immediately, needs a restart, needs a
-- config.lua edit AND a restart, has no confirmed server-side effect at
-- all, or cannot be toggled through this system at all. THIS FILE forwards
-- `tier` (and, on a rejected set, the tunable's real `min`/`max`) VERBATIM
-- -- but per that file's own "LOCALE KEYS THIS FILE NEEDS: none... never
-- player-facing prose" header note, it never sends a human-readable
-- sentence of its own; html/tablet.js's own runtimeTierLabel()/
-- runtimeTierDescription() are what turn a bare `tier` string into the
-- locale-driven plain-language explanation the operator actually reads --
-- see this file's header NUI CONTRACT note for the full reasoning.
-- ----------------------------------------------------------------------

RegisterNUICallback('tablet:runtimeListFeatures', function(_, cb)
    cb(TranslateReasonResult(AwaitServerCallback('qbx_k9unit:server:runtimeListFeatures')))
end)

--- `data.confirm`, when present, MUST equal the feature's own `name`
--- EXACTLY for server/runtimecontrol.lua to accept a change to a
--- `lockoutRisk` feature -- see this file's own NUI CONTRACT note "THE
--- LOCKOUT-RISK CONFIRMATION GATE" above. `nil` for every other feature
--- (ignored entirely server-side) -- this file does not require it, does
--- not check it against `data.name` itself, and does not decide
--- authorization here; it only forwards whatever the page sent, exactly as
--- received, to the one real gate.
RegisterNUICallback('tablet:runtimeSetFeature', function(data, cb)
    if type(data) ~= 'table' or type(data.name) ~= 'string' or data.name == '' or type(data.value) ~= 'boolean' then
        cb({ ok = false, error = 'invalid_args' })
        return
    end
    if data.confirm ~= nil and type(data.confirm) ~= 'string' then
        cb({ ok = false, error = 'invalid_args' })
        return
    end
    cb(TranslateReasonResult(AwaitServerCallback('qbx_k9unit:server:runtimeSetFeature', data.name, data.value, data.confirm)))
end)

--- Same `confirm` contract as tablet:runtimeSetFeature above.
RegisterNUICallback('tablet:runtimeResetFeature', function(data, cb)
    if type(data) ~= 'table' or type(data.name) ~= 'string' or data.name == '' then
        cb({ ok = false, error = 'invalid_args' })
        return
    end
    if data.confirm ~= nil and type(data.confirm) ~= 'string' then
        cb({ ok = false, error = 'invalid_args' })
        return
    end
    cb(TranslateReasonResult(AwaitServerCallback('qbx_k9unit:server:runtimeResetFeature', data.name, data.confirm)))
end)

RegisterNUICallback('tablet:runtimeListTunables', function(_, cb)
    cb(TranslateReasonResult(AwaitServerCallback('qbx_k9unit:server:runtimeListTunables')))
end)

--- `value` is FORWARDED AS-IS, never clamped/rounded here -- see this
--- file's header NUI CONTRACT note: server/runtimecontrol.lua's own
--- SetTunable is the only real, authoritative [min,max]/integer check;
--- this file's own type(data.value) ~= 'number' guard below rejects only
--- something that could not possibly be a valid tunable value at all
--- (missing, a string, NaN would still pass `type(...) == 'number'` in
--- Lua, but the SERVER's own `newValue == newValue` NaN test -- see that
--- file's own SetTunable comment -- is what actually catches that; this
--- file duplicating it would be exactly the "treat client-side validation
--- as authoritative" mistake this task's own brief warns against).
RegisterNUICallback('tablet:runtimeSetTunable', function(data, cb)
    if type(data) ~= 'table' or type(data.key) ~= 'string' or data.key == '' or type(data.value) ~= 'number' then
        cb({ ok = false, error = 'invalid_args' })
        return
    end
    cb(TranslateReasonResult(AwaitServerCallback('qbx_k9unit:server:runtimeSetTunable', data.key, data.value)))
end)

RegisterNUICallback('tablet:runtimeResetTunable', function(data, cb)
    if type(data) ~= 'table' or type(data.key) ~= 'string' or data.key == '' then
        cb({ ok = false, error = 'invalid_args' })
        return
    end
    cb(TranslateReasonResult(AwaitServerCallback('qbx_k9unit:server:runtimeResetTunable', data.key)))
end)

-- Lua-INITIATED push, SAME shape/posture as tablet:themeUpdated just below
-- -- see this file's header NUI CONTRACT note on
-- tablet:equipmentShopLocationsUpdated. client/equipmentshop.lua ALSO
-- listens for this exact event independently (to respawn/reposition shop
-- peds) -- AddEventHandler supports any number of handlers per event name,
-- so this is a second, additive listener, not a replacement for that one.
AddEventHandler('qbx_k9unit:client:equipmentShopLocationsUpdated', function(locations)
    SendNUIMessage({ action = 'tablet:equipmentShopLocationsUpdated', data = locations })
end)

-- Lua-INITIATED push, NOT tied to this player's own tablet being open --
-- see this file's header NUI CONTRACT note on tablet:themeUpdated.
-- Registered UNCONDITIONALLY (not only while tabletOpen) so an
-- already-open tablet elsewhere on the server updates live the instant
-- high command saves a change, matching server/runtimecontrol.lua's own
-- "applied for everyone" broadcast intent. No listener/interval is started
-- here that would ever need cleanup on close -- this is a single,
-- session-lifetime handler, registered once at file load.
--
-- MUST be RegisterNetEvent, NOT AddEventHandler: server/runtimecontrol.lua
-- fires this via TriggerClientEvent(..., -1, theme), and FiveM only
-- delivers a network-originated TriggerClientEvent to handlers registered
-- with RegisterNetEvent -- a plain AddEventHandler-only registration (as
-- this was before this fix) never runs for it at all, so an already-open
-- tablet never saw a live theme change; only closing and reopening it
-- (which re-fetches via tablet:getTheme) ever picked one up. Contrast the
-- ADDITIVE, display-only qbx_k9unit:client:equipmentShopLocationsUpdated
-- AddEventHandler just above, which is correct as AddEventHandler because
-- client/equipmentshop.lua already owns the one real RegisterNetEvent for
-- that name -- this event has no such sibling registration anywhere else
-- in the client realm, so THIS registration itself must be the networked
-- one.
--
-- No extra validation added here beyond what already existed: the payload
-- is forwarded to the NUI verbatim, same as the
-- equipmentShopLocationsUpdated handler above. That is safe because (a)
-- server/runtimecontrol.lua's own ValidateFullTheme is the real, strict
-- gate before this ever fires, and (b) html/tablet.js's own
-- handleThemeUpdated already guards against a non-table payload and every
-- individual field already falls back to DEFAULT_THEME/the locale title
-- per-key when missing, so a partial or malformed push cannot blank the
-- UI on the JS side either.
RegisterNetEvent('qbx_k9unit:client:themeUpdated', function(theme)
    SendNUIMessage({ action = 'tablet:themeUpdated', data = theme })
end)

-- THIS PASS (focus-and-state audit finding #4) -- server/permissions.lua's
-- own "FEATURE-BLOCK PUSH" section already fires
-- TriggerClientEvent('qbx_k9unit:client:featureBlocksSync', targetSrc,
-- blockedFeatureNames) at four points (PlayerLoaded, its own
-- onResourceStart backfill, and the tails of GrantPermission/
-- RevokePermission on the `block.<Name>` namespace), always at the ONE
-- affected citizenid's own connection, never a broadcast -- so an arriving
-- push always describes THIS client's own, current viewer's own
-- entitlements changing, never someone else's. client/featureblocks.lua
-- already owns the REAL consumer of this event (the twelve
-- CLIENT_ENFORCED_FEATURES it gates) -- this is a SECOND, additive
-- listener, same posture as qbx_k9unit:client:equipmentShopLocationsUpdated
-- above, not a replacement for that one.
--
-- MUST be RegisterNetEvent, NOT AddEventHandler -- same reasoning as
-- qbx_k9unit:client:themeUpdated's own note just above: this is a
-- network-originated TriggerClientEvent, and FiveM only delivers one of
-- those to a RegisterNetEvent-registered handler. No `source ~= 65535`
-- origin guard is added here (unlike client/combat.lua's handlers) --
-- deliberately: this handler applies zero side effects of its own beyond
-- relaying into the SendNUIMessage channel below, which html/tablet.js's
-- own handleFeatureBlocksSync() then uses ONLY as a cue to RE-FETCH the
-- authoritative record (loadMyRecord(), never a local recomputation from
-- this payload -- see that function's own doc comment for why: THE TABLET
-- IS A VIEW, IT DECIDES NOTHING). A spoofed local TriggerEvent reaching
-- this handler could, at most, cause one extra harmless re-fetch of the
-- caller's own already-authoritative record -- the same "no origin guard
-- needed, nothing here can be abused" posture this file's own two sibling
-- push relays (themeUpdated/equipmentShopLocationsUpdated) already apply.
--
-- Forwarded VERBATIM (the raw blocked-feature-name array) even though
-- html/tablet.js's own handler does not read it -- kept in the payload
-- anyway so a future consumer never has to touch this Lua-side relay to
-- gain access to it.
RegisterNetEvent('qbx_k9unit:client:featureBlocksSync', function(blockedKeys)
    SendNUIMessage({ action = 'tablet:featureBlocksSync', data = blockedKeys })
end)

-- ----------------------------------------------------------------------
-- K9 AUDIT TRAIL VIEWER -- server/admin.lua's five tabletAudit* callbacks
-- (Cert/Partner/Search/Xp/Dept), added this pass to close the gap that
-- file's own header names by name: "no NUI callback and no
-- client/tablet.lua change are part of this pass; this is the
-- server-side contract a follow-up tablet screen builds against." This
-- IS that follow-up -- see this file's own header NUI CONTRACT note on
-- these five names for the full AuditResult contract.
--
-- THE TABLET IS A VIEW. IT DECIDES NOTHING -- same rule as every other
-- callback in this file. server/admin.lua's own IsAuthorizedAdmin is the
-- ONLY real gate, re-verified from the CALLER's own live `source` on
-- every single invocation; this file adds no authorization of its own
-- and no second query path.
-- ----------------------------------------------------------------------

--- Shared helper for the five bridges below: an optional numeric `limit`
--- field, dropped to `nil` (never forwarded as anything else) unless it
--- is already a plain Lua number. A trailing `nil` argument is always
--- safe here (indistinguishable, on the receiving Lua function, from the
--- argument simply being omitted -- true whether or not the ox_lib wire
--- transport itself preserves the trailing slot) precisely BECAUSE
--- `limit` is always the LAST positional argument passed to
--- AwaitServerCallback at every one of this section's five call sites --
--- server/admin.lua's own ClampLimit already treats an absent/non-number
--- rawArg identically to this file passing `nil` outright (falls back to
--- its own configured default, then still floor+range-clamps into
--- [1, HARD_MAX_RESULTS]), so this file need not guess a default itself.
--- @param data table
--- @return number? limit
local function OptionalNumericLimit(data)
    return (type(data.limit) == 'number') and data.limit or nil
end

--- 'tablet:auditCert' -- mirrors server/admin.lua's '/k9audit cert'. `rows`
--- shape: one row per k9_certifications grant/revoke event for this
--- citizenid, across every department (job, granted_by, granted_at,
--- revoked_by, revoked_at, active) -- see that file's own
--- QueryCertificationHistory doc comment for the authoritative column
--- list.
RegisterNUICallback('tablet:auditCert', function(data, cb)
    if type(data) ~= 'table' or type(data.targetCitizenId) ~= 'string' or data.targetCitizenId == '' then
        cb({ ok = false, error = 'invalid_args' })
        return
    end
    cb(AwaitServerCallback('qbx_k9unit:server:tabletAuditCert', data.targetCitizenId, OptionalNumericLimit(data)))
end)

--- 'tablet:auditPartner' -- mirrors '/k9audit partner'. `rows` shape: this
--- citizenid's full partnership history in EITHER role (id, k9_citizenid,
--- handler_citizenid, established_by, established_at, ended_by, ended_at,
--- active) -- see QueryPartnershipHistory's own doc comment.
RegisterNUICallback('tablet:auditPartner', function(data, cb)
    if type(data) ~= 'table' or type(data.targetCitizenId) ~= 'string' or data.targetCitizenId == '' then
        cb({ ok = false, error = 'invalid_args' })
        return
    end
    cb(AwaitServerCallback('qbx_k9unit:server:tabletAuditPartner', data.targetCitizenId, OptionalNumericLimit(data)))
end)

--- 'tablet:auditSearch' -- mirrors '/k9audit search'. `data.mode` is
--- forwarded VERBATIM, unchecked against server/admin.lua's own
--- VALID_SEARCH_LOG_MODES whitelist here -- that file's own callback
--- already whitelist-checks it before `value` is even inspected and
--- returns 'invalid_args' for anything else, so a second copy of that
--- whitelist here would only be able to drift from the real one, never
--- make it any safer (THE SECURITY RULE). `rows` shape is IDENTICAL
--- across all four modes (searcher_citizenid, searcher_job, target_type,
--- target_plate, target_citizenid, result, total_weight, alert_tier,
--- searched_at, id) -- see QuerySearchLogByOfficer/ByPlate/ByPerson/
--- Recent's own doc comments.
RegisterNUICallback('tablet:auditSearch', function(data, cb)
    if type(data) ~= 'table' or type(data.mode) ~= 'string' or data.mode == '' then
        cb({ ok = false, error = 'invalid_args' })
        return
    end
    -- `value` is sent as an empty string, NEVER Lua `nil`, when absent or
    -- not already a string -- unlike `limit` above, `value` is NOT this
    -- call's last positional argument (`limit` follows it), and an
    -- explicit nil in a NON-TRAILING position risks the wire transport
    -- misaligning every argument after it. An empty string is safe here
    -- regardless: server/admin.lua's own IsValidCitizenId/
    -- NormalizePlateArg both already reject '' as invalid input for
    -- every mode that inspects `value` at all, and 'recent' never reads
    -- it either way.
    local value = (type(data.value) == 'string') and data.value or ''
    cb(AwaitServerCallback('qbx_k9unit:server:tabletAuditSearch', data.mode, value, OptionalNumericLimit(data)))
end)

--- 'tablet:auditXp' -- mirrors '/k9audit xp'. NO `limit` argument --
--- citizenid is k9_progression's own PRIMARY KEY, so `rows` is always 0
--- or 1 elements ({ xp, updated_at }) regardless of what any caller
--- supplies -- see QueryProgressionSnapshot's own doc comment.
RegisterNUICallback('tablet:auditXp', function(data, cb)
    if type(data) ~= 'table' or type(data.targetCitizenId) ~= 'string' or data.targetCitizenId == '' then
        cb({ ok = false, error = 'invalid_args' })
        return
    end
    cb(AwaitServerCallback('qbx_k9unit:server:tabletAuditXp', data.targetCitizenId))
end)

--- 'tablet:auditDept' -- mirrors '/k9audit dept'. `departmentKey` is
--- forwarded VERBATIM as the server's own `job` argument -- server-side
--- IsValidDepartment (a `Config.Departments[job] ~= nil` lookup) is the
--- real gate; this file does not hardcode or duplicate the configured
--- department list. `rows` shape: this department's CURRENT active-only
--- certified-handler roster (citizenid, granted_by, granted_at) -- see
--- QueryDepartmentRoster's own doc comment, including why revoked rows
--- are deliberately excluded.
RegisterNUICallback('tablet:auditDept', function(data, cb)
    if type(data) ~= 'table' or type(data.departmentKey) ~= 'string' or data.departmentKey == '' then
        cb({ ok = false, error = 'invalid_args' })
        return
    end
    cb(AwaitServerCallback('qbx_k9unit:server:tabletAuditDept', data.departmentKey, OptionalNumericLimit(data)))
end)

--- 'tablet:auditCatalog' -- mirrors NO chat command (there is no
--- '/k9auditcatalog' -- this catalog-change audit was only ever reachable
--- from a chat command's log/toast for the ORIGINAL eight `*Audit_Append`
--- writes themselves, never a read command); the sixth bridge, closing
--- server/admin.lua's own separately-named "GAP 2 read side" gap (see this
--- file's own header STATUS UPDATE (later pass, 2) note). `catalogName` is
--- forwarded VERBATIM, NOT whitelist-checked against
--- CATALOG_AUDIT_SOURCES' eight real keys here -- same THE SECURITY RULE
--- as `tablet:auditSearch`'s own `mode` above: that file's own lookup
--- already refuses anything else with `invalid_args` before running a
--- single query, so a second copy of that allowlist here could only drift
--- from the real one. `rows` shape depends on WHICH catalog was requested
--- -- see html/tablet.js's own auditColumnsForCatalog() and
--- server/admin.lua's own CATALOG_AUDIT_SOURCES table for the authoritative
--- per-catalog column list; this file reshapes nothing.
RegisterNUICallback('tablet:auditCatalog', function(data, cb)
    if type(data) ~= 'table' or type(data.catalogName) ~= 'string' or data.catalogName == '' then
        cb({ ok = false, error = 'invalid_args' })
        return
    end
    cb(AwaitServerCallback('qbx_k9unit:server:tabletAuditCatalog', data.catalogName, OptionalNumericLimit(data)))
end)

-- ----------------------------------------------------------------------
-- Resource-stop safety net -- see FOCUS/CLOSE DISCIPLINE point 4.
-- ----------------------------------------------------------------------
AddEventHandler('onResourceStop', function(resourceName)
    if resourceName ~= GetCurrentResourceName() then return end
    CloseTablet()
end)
