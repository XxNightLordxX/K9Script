/*
    qbx_k9unit/html/tablet.js

    K9 Command Tablet -- Config.Features.CommandTablet. The in-game roster
    and self-service UI for certifications, XP, the four admin capabilities
    (Config.Permissions: k9.access/k9.certify/k9.audit/k9.givexp), and
    per-person feature enable/disable (Config.FeatureControl). Runs inside
    html/tablet.html, loaded once via an <iframe src="tablet.html"> embedded
    in html/index.html (see that file's own comment, and html/tablet-bridge.js,
    for the isolation mechanism this relies on) -- NOT a panel bolted onto
    the existing HUD document, and NOT touching html/app.js at all.

    ======================================================================
    THE SECURITY RULE -- READ THIS BEFORE CHANGING ANYTHING BELOW.

    THIS PAGE IS A VIEW. IT DECIDES NOTHING. Every single NUI callback this
    file fetches is re-authorized SERVER-SIDE from the caller's own live
    job, grants and blocks, exactly as if they had typed the equivalent
    chat command or pressed the equivalent keybind. A modified client can
    open this resource's dev tools (or skip this page entirely) and fire
    ANY of the fetch() calls below with ANY payload it likes, targeting any
    citizenid, any permission, any feature, any amount -- so a button
    existing on screen, or a section being rendered at all, must NEVER be
    what makes the action it fires permitted. Every `if (canX(...))` check
    in this file exists ONLY to decide what to show as a convenience for a
    legitimate user; deleting all of them would make this file annoying to
    use, never insecure, because the real gate lives entirely in
    client/tablet.lua and the server files behind it. If you are reading
    this because you're about to "simplify" by removing a server-side
    re-check because "the UI already hides that button" -- don't. That is
    exactly the mistake this comment exists to prevent.

    With this page now able to TRIGGER abilities (tablet:triggerFeature)
    and not just view/manage records, that rule matters even more than it
    did for the original grant/revoke/certify surface: a trigger callback
    must do the FULL validation the real command/keybind path already does
    (certification, feature flag, block, grant-if-required, cooldowns,
    target resolution) -- never less, just because the request arrived via
    NUI instead of a RegisterCommand.
    ======================================================================

    ======================================================================
    NUI CONTRACT -- must match client/tablet.lua exactly, byte-for-byte on
    every name and payload shape (this codebase's single most common
    silent-failure point: a mismatched name just hangs the fetch promise or
    drops a push silently, no error on either side). See this repo's
    coordination notes for the full write-up; short form below.

    Every RegisterNUICallback handler below MUST call its cb(...), even for
    a fire-and-forget message -- an uninvoked callback hangs this page's
    fetch() promise forever, which for a couple of these (tablet:ready,
    tablet:close) is harmless only because nothing here awaits them, but is
    the wrong thing to build on the Lua side regardless.

    JS -> Lua (RegisterNUICallback, fetch(`https://${resourceName}/<name>`)):

      tablet:ready {} -> cb({})
        Fired once, immediately after this page attaches its `message`
        listener (same ordering/race-closing purpose as html/app.js's own
        hud:ready). This page's iframe loads ONCE for the whole client
        session (never re-created per open/close), so this fires once per
        session, not once per open.

      tablet:requestMyRecord {} -> cb(MyRecordResult)
        Gated only by Config.FeatureControl.everyoneCanViewOwnRecord (and
        whatever base "are you even a real, loaded player" check makes
        sense) -- EVERY handler/K9 can call this, not just high command.
        MyRecordResult, success:
          {
            ok: true,
            viewer: {
              citizenid: string,
              name: string,
              isHighCommand: boolean,
              // Subset of ['k9.access','k9.certify','k9.audit','k9.givexp']
              // this CALLER currently qualifies for via ANY path (explicit
              // grant, high command bypass, or legacy rank gate) --
              // config.lua's own 4-step resolution order, already fully
              // resolved server-side. Convenience only, see THE SECURITY
              // RULE above.
              effectivePermissions: string[],
              allowSelfGrant: boolean, // mirrors Config.HighCommand.allowSelfGrant, UX hint only
            },
            certifications: [ { departmentKey, departmentLabel, active, grantedBy: string|null,
              // grantedByName: coder-backend's additive display-name sibling
              // for grantedBy (resolved, offline-safe, same ResolveDisplayName
              // this file's own `name`/`target.name` fields already use) --
              // buildCertificationRow() prefers this for display, but
              // grantedBy itself remains the raw value, never replaced.
              grantedByName: string|null,
              // ^ tier/expiresAtUnix/expired/specializations are only ever populated
              // for an ACTIVE row (server/tablet.lua's BuildCertificationsArray) --
              // never guess a value for a department this citizenid has never held.
              tier: string|null, expiresAtUnix: number|null, expired: boolean,
              specializations: string[] } ],
            xp: number|null,       // null if XPProgression is off or no record yet
            tierLabel: string|null,
            // Every Config.Features key this resource considers
            // "actionable" from the tablet, resolved for the CALLER
            // specifically -- see the `state` precedence note below.
            myFeatures: [
              {
                key: string,          // Config.Features key, e.g. 'BiteAndHold'
                label: string,        // human label -- config/locale-authored; falls back to a humanized key client-side if absent
                category: string|null,
                actionable: boolean,  // false = status-only row, no trigger button (most features have no single-button "use it now" action)
                // Precedence, first match wins (mirrors config.lua's own
                // FeatureControl resolution order, PLUS the base
                // certification gate underneath it):
                //   'global_off'              Config.Features.<key> is false
                //   'blocked'                 explicit per-person block row
                //   'not_certified'           lacks the underlying K9 access/certification this feature needs
                //   'requires_grant_missing'  key is in RequireGrant and caller holds no grant
                //   'available'               usable now (actionable buttons only meaningful here)
                state: 'global_off'|'blocked'|'not_certified'|'requires_grant_missing'|'available',
              },
            ],
            // CLIENT-LOCAL role signal (this pass, owner-directed
            // "restructure the tablet around WHO IS HOLDING IT") --
            // ENRICHED ONTO THIS EXACT RESPONSE BY client/tablet.lua'S
            // OWN RegisterNUICallback('tablet:requestMyRecord', ...)
            // HANDLER, not sent by server/tablet.lua at all -- see that
            // handler's own ResolveLocalRoleFlags() doc comment. Cosmetic
            // framing ONLY for buildHomeScreen()'s role badge/partnered
            // indicator -- never read by, or forwarded into, any
            // mutation/trigger callback (see THE SECURITY RULE above).
            isK9Model: boolean,   // IsOwnModelK9() -- is this client currently wearing a K9 model right now
            isPartnered: boolean, // IsPartnered() -- is this client currently in an established handler/K9 partnership right now
          }
        Failure: { ok: false, error: string, message?: string }
        (error is a short machine code -- 'not_authorized'/'server_error'/
        anything else Lua wants to add; this page also synthesizes
        'timeout'/'network_error'/'exception' locally if the fetch itself
        never resolves -- see fetchNui() below. `message`, if present, is
        rendered verbatim via textContent as a human-readable detail.)

      tablet:triggerFeature { feature: string } -> cb({ ok, error?, message? })
        Gated by Config.FeatureControl.allowActionsFromTablet AND the SAME
        full resolution myFeatures[].state already describes -- re-checked
        from scratch server-side, never trusted from this page's own cached
        copy. No extra args in this pass: this fires the exact same
        client-side entry point the feature's existing keybind/command
        already calls, which resolves its own context (nearest target,
        etc.) exactly as it does today -- the tablet is an alternative
        trigger for that same path, not a new mechanism with its own
        targeting model. After ANY response (success or failure) this page
        re-calls tablet:requestMyRecord to refresh (cooldowns, certification
        changes, etc.) -- never assumes the local cached state is still
        accurate.

      tablet:requestRoster { query: string } -> cb(RosterResult)
        Only meaningful for a caller server/tablet.lua's own
        CallerHasConsoleAccess admits: isHighCommand, OR
        effectivePermissions includes 'k9.audit' specifically -- NOT "any
        non-empty effectivePermissions" (narrowed 2026-08-25; a bare
        'k9.access', which resolves true for every ordinary certified
        handler, no longer qualifies -- see that function's own doc
        comment for the full rationale). Per THE SECURITY RULE, the
        SERVER must independently re-verify this on every call; this page
        hiding the "Command Console" tab for everyone else is a
        convenience, not the access control -- see canAccessConsole()
        below, the ONE place this page derives that convenience signal.
        `query` is the raw, untrimmed search box text (name/citizenid/
        department substring match, case-insensitive) -- arbitrary
        player-controlled string, never assume it's been sanitized here.
        Success:
          {
            ok: true,
            rows: [ { citizenid, name, departmentLabel, certified, xp, tierLabel } ],
            truncated: boolean,          // more rows exist beyond Config.CommandTablet.maxRosterRows for this query
            truncatedMessage?: string,   // pre-formatted, locale-resolved (e.g. locale('k9tablet.truncated_notice', rows.length)) -- preferred over this page building its own count text when present
          }
        Failure: { ok: false, error, message? }

      tablet:requestPersonSummary { targetCitizenId: string } -> cb(PersonSummaryResult)
        Same viewer-side gate as tablet:requestRoster (anyone who can see
        the console at all can open a person's summary from it).
        Success:
          {
            ok: true,
            target: { citizenid, name },
            certifications: [ { departmentKey, departmentLabel, active, grantedBy: string|null,
              // grantedByName: coder-backend's additive display-name sibling
              // for grantedBy (resolved, offline-safe, same ResolveDisplayName
              // this file's own `name`/`target.name` fields already use) --
              // buildCertificationRow() prefers this for display, but
              // grantedBy itself remains the raw value, never replaced.
              grantedByName: string|null,
              // ^ tier/expiresAtUnix/expired/specializations are only ever populated
              // for an ACTIVE row (server/tablet.lua's BuildCertificationsArray) --
              // never guess a value for a department this citizenid has never held.
              tier: string|null, expiresAtUnix: number|null, expired: boolean,
              specializations: string[] } ],
            // ^ ONE ROW PER CONFIGURED DEPARTMENT (Config.Departments),
            // including departments this citizenid has never held, so the
            // UI can offer "Certify" for a brand-new department, not only
            // "Decertify" for ones they already hold.
            xp: number|null,
            tierLabel: string|null,
            // Capability keys (Config.Permissions) this TARGET currently
            // holds -- rendered as read-only chips unless viewer.isHighCommand,
            // in which case grant/revoke checkboxes are also shown.
            permissions: string[],
            // READ-ONLY. job.name's Config.Departments label (or job.label,
            // or job.name -- see server/tablet.lua's ResolveJobGradeInfo)
            // plus job.grade off the SAME PlayerData shape every rank gate
            // in this resource already trusts. null if this citizenid has
            // no resolvable PlayerData at all (online AND offline lookup
            // both failed). NO PROMOTION CONTROL EXISTS FOR THIS -- this
            // resource has no SetJobGrade-equivalent write path today, so
            // this page only ever displays it, never a dropdown/button
            // that would imply a capability that is not actually there.
            job: { departmentLabel: string, gradeLabel: string|null, gradeLevel: number|null, isBoss: boolean } | null,
            // READ-ONLY, DB-authoritative (correct for an offline target,
            // not an online-only cache -- see ResolvePartnershipInfo's own
            // doc comment). null if not currently partnered, the
            // HandlerPartnership feature is off, or the read failed.
            partnership: { partnerCitizenid: string, partnerName: string, role: 'k9'|'handler' } | null,
          }
        Failure: { ok: false, error, message? }

      tablet:requestPersonFeatures { targetCitizenId: string } -> cb(PersonFeaturesResult)
        HIGH COMMAND ONLY -- re-verified server-side regardless of what this
        page believes viewer.isHighCommand to be.
        Success:
          {
            ok: true,
            target: { citizenid, name },
            features: [
              {
                key, label, category,
                globallyEnabled: boolean,  // Config.Features.<key> -- if false, EVERYTHING else here is moot; this page renders NO controls at all for such a row, only a "disabled server-wide" note -- never a button that would silently do nothing
                requiresGrant: boolean,    // Config.FeatureControl.RequireGrant[key] === true
                granted: boolean,          // meaningful only if requiresGrant -- does this TARGET currently hold an explicit grant
                blocked: boolean,          // does this TARGET currently have an explicit block row -- ORTHOGONAL to requiresGrant/granted, see config.lua's own "steps 2 and 3 are DIFFERENT THINGS" note
                state: 'global_off'|'blocked'|'not_certified'|'requires_grant_missing'|'available',
                viaHighCommand: boolean,   // DISPLAY-GAP FIX (this pass) -- true ONLY when `state === 'available'` SOLELY because this TARGET's own rank bypasses requiresGrant/certification -- never true for a row they would have earned honestly anyway (a real grant, real K9 access with no grant needed). `granted`/`blocked`/`globallyEnabled`/`requiresGrant` above are NEVER altered by this -- see server/tablet.lua's ResolveFeatureState for the full "displayed state, not the underlying record" contract. appendViaHighCommandMarker() renders this as a small, quiet '(High Command)' suffix, never a prominent badge.
                blockEnforcement?: 'enforced'|'client_enforced'|'not_yet_enforced'|'not_enforceable',
                // ^ NOW LANDED for every Config.Features key (server/tablet.lua's
                // ResolveBlockEnforcement, called from BuildPersonFeaturesArray) --
                // see server/tablet.lua's own `blocked`/`state` fields above: neither
                // one tells the operator whether setting block.<key> actually stops
                // anything. This page cannot answer that itself (Do not invent a
                // client-side list here -- see featureBlockEnforcement() below for
                // why, and THE SECURITY RULE for why a hardcoded guess would rot the
                // moment another feature's own server file gets a real `block.<key>`
                // check wired in). Server-side, FOUR states:
                //   'enforced'         -- some feature-owning server file confirmed,
                //                         by direct code read, to check
                //                         HasPermission(citizenid, 'block.<key>') before
                //                         permitting the actual ability -- mirrors
                //                         server/runtimecontrol.lua's own FEATURE_TIERS
                //                         discipline (a small, explicit, code-read-verified
                //                         registry, not a guess), for the identical reason:
                //                         a manually-derived claim needs a human to have
                //                         actually read the file it's claiming something about.
                //   'client_enforced'  -- STRICTLY WEAKER than 'enforced', and a
                //                         DIFFERENT thing from 'not_enforceable':
                //                         client/featureblocks.lua's twelve purely
                //                         client-rendered/client-local abilities (e.g.
                //                         ThermalVision/NightVision) now DO honour a
                //                         per-person block -- genuinely, for every
                //                         ordinary, unmodified client -- but the check
                //                         runs entirely on the PLAYER'S OWN client, so a
                //                         modified one can always choose to skip it,
                //                         exactly like this resource's other client-side
                //                         gates (IsOwnModelK9/CanShowK9UI). Rendering
                //                         this as bare 'enforced' would falsely claim
                //                         server-side parity; rendering it as
                //                         'not_enforceable' would falsely claim the
                //                         block does nothing. See
                //                         locales/en.json's
                //                         tablet.block_client_enforced_badge/_hint for
                //                         the operator-facing "best-effort, not a
                //                         guarantee" wording -- never soften it.
                //   'not_enforceable'  -- structurally cannot ever take effect, for a
                //                         reason that is NOT "nobody has wired it in
                //                         yet": either there is no per-citizenid ability
                //                         here at all to gate in the first place (a pure
                //                         administrative/infrastructure switch -- e.g.
                //                         HighCommand, CommandTablet), or the feature's
                //                         own owning file documents a DELIBERATE decision
                //                         never to honour one (e.g. a
                //                         block.Recall -- a termination/escape-hatch path
                //                         that must never be gated, by this resource's
                //                         own "no unbounded trap" rule). NOTE: an EARLIER
                //                         version of this comment also named
                //                         K9EquipmentShop here -- that was corrected:
                //                         server/equipmentshop.lua now genuinely enforces
                //                         a block via ox_inventory's own openShop/buyItem
                //                         hooks, so it resolves 'enforced' like any other
                //                         server-gated ability.
                //   'not_yet_enforced' -- (also the FALLBACK for a missing/unrecognized
                //                         value, and for this field being entirely absent
                //                         from an older server response) -- structurally
                //                         possible, simply not read/confirmed yet. THE SAFE
                //                         DEFAULT DIRECTION: this page never renders a
                //                         feature as 'enforced' (or 'client_enforced')
                //                         unless the server explicitly says so.
              },
            ],
          }
        Failure: { ok: false, error, message? }

      tablet:certify { targetCitizenId: string, departmentKey: string, k9Model?: string } -> cb({ ok, error?, message? })
      tablet:decertify { targetCitizenId: string, departmentKey: string } -> cb({ ok, error?, message? })
        Requires effectivePermissions to include 'k9.certify' (which already
        covers high command and legacy-rank certifiers per config.lua's own
        resolution order) -- re-verified server-side. Both work for an
        ONLINE or OFFLINE target (server/certifications/'s
        GrantCertificationForTablet/RevokeCertificationForTablet resolve
        this themselves) -- this page never needs to know or ask which.
        BUGFIX (docs/history/COMMAND_CONSOLIDATION_SPEC.md §6): tablet:decertify used to
        be wired to an offline-only command bridge that always refused an
        online target, contradicting this exact contract -- fixed by giving
        it a real RevokeCertificationForTablet-backed server callback,
        symmetric with tablet:certify.

      tablet:setCertificationTier { targetCitizenId: string, departmentKey: string, tier: string } -> cb({ ok, error?, message? })
      tablet:renewCertification { targetCitizenId: string, departmentKey: string } -> cb({ ok, error?, message? })
      tablet:revokeSpecialization { targetCitizenId: string, departmentKey: string, specialization: string } -> cb({ ok, error?, message? })
        Same 'k9.certify' gate as certify/decertify above, same online-OR-
        offline transparency. `tier` is validated server-side against the
        LIVE tier catalog (server/certtiers.lua) -- this page's own tier
        picker (buildCertificationDetail) is populated from
        tablet:certTiersList, never a hardcoded trainee/certified/senior
        list, but a modified client sending an arbitrary string still gets
        a clean 'invalid_tier' refusal, not a crash or a silent no-op.

      tablet:grantSpecialization { targetCitizenId: string, departmentKey: string, specialization: string } -> cb({ ok, error?, message? })
        Same 'k9.certify' gate -- but, UNLIKE the four calls immediately
        above, ONLINE TARGETS ONLY (server/certifications/'s
        GrantSpecializationForTablet own header explains why: the
        precondition this gates on -- an active, non-expired base
        certification AND a tier-capability check -- is read from
        online-only cached state that cannot be safely reconstructed for a
        disconnected citizenid without weakening the check). A disconnected
        target gets 'target_must_be_online' back, an honest, distinguishable
        refusal -- this page does not attempt to disable the Grant control
        based on the target's online status (it has no reliable way to know
        that live from a person summary that already works offline), it
        simply surfaces whatever error?/message? the server returns.

      tablet:givexp { targetCitizenId: string, amount: number } -> cb({ ok, error?, message? })
        Requires effectivePermissions to include 'k9.givexp'. `amount` is
        whatever numeric value this page's input currently holds --
        Config.HighCommand.maxXpPerGrant/allowSelfGrant/grantCooldownMs are
        ALL re-enforced server-side; this page only clamps the input's
        `max` attribute and disables self-targeting as a typo/UX guard.

      tablet:grantPermission { targetCitizenId: string, permission: string } -> cb({ ok, error?, message? })
      tablet:revokePermission { targetCitizenId: string, permission: string } -> cb({ ok, error?, message? })
        HIGH COMMAND ONLY. Granting/revoking one of the four admin
        capabilities is not itself delegable via any capability -- there is
        no fifth "can manage permissions" key -- so this page shows these
        controls ONLY when viewer.isHighCommand, distinct from the
        effectivePermissions-driven controls above.

      tablet:grantFeature { targetCitizenId: string, feature: string } -> cb({ ok, error?, message? })
      tablet:revokeFeature { targetCitizenId: string, feature: string } -> cb({ ok, error?, message? })
      tablet:blockFeature { targetCitizenId: string, feature: string } -> cb({ ok, error?, message? })
      tablet:unblockFeature { targetCitizenId: string, feature: string } -> cb({ ok, error?, message? })
        HIGH COMMAND ONLY, same reasoning as the permission grant/revoke
        pair above. Grant/Revoke and Block/Unblock are deliberately TWO
        SEPARATE, independent toggles per feature per config.lua's own
        instruction that these are different things -- never collapsed
        into one control.

      tablet:close {} -> cb({})
        Fire-and-forget. Tells Lua the player wants to close (Close button
        or Escape) so it can release SetNuiFocus. MUST be safe to call
        repeatedly / while already closed -- this page fires it from more
        than one path (button click, Escape inside this document, and
        html/tablet-bridge.js's own top-level Escape listener as a second,
        independent path for when keyboard focus is on the parent document
        instead of this iframe) and never waits for its response before
        hiding itself locally (see requestClose() below -- the close path
        must never depend on a round trip succeeding).

      tablet:equipmentShopGetLocations {} -> cb({ ok, locations?, error? })
        HIGH COMMAND OR A DELEGATED 'k9.equipmentshoplocations' GRANT
        screen (server/equipmentshop.lua's own GetLocations callback has no
        such gate -- open to any connected player -- but this page only
        ever shows the management screen to a viewer who passes
        canManageShopLocations(), per THE SECURITY RULE a convenience,
        matching server/equipmentshop.lua's own real CanManageShopLocations
        gate re-verified on every mutating call below regardless of what
        this page shows). `locations` is a map keyed by location key
        (`cfg:<n>` -- defined in config.lua, read-only from here -- or
        `db:<id>` -- added via this screen, editable/removable) to
        `{ x, y, z, heading, model, scenario, label }`, ALL fields already
        resolved against the shop's own defaults server-side (never nil).

      tablet:equipmentShopAddLocation { label?: string, model?: string, scenario?: string } -> cb({ ok, locationKey?, locations?, error? })
        COORDINATES ARE NEVER SENT BY THIS PAGE -- a CEF browser page has no
        native access to GetEntityCoords/GetEntityHeading at all.
        client/tablet.lua captures the OPERATOR'S OWN current position at
        the moment this fires and adds it before forwarding to the server
        -- see this task's own instruction: "Get it client-side and send
        it; do not expect the server to know where they are." A blank
        label/model/scenario field is sent as an EMPTY STRING here and
        OMITTED by client/tablet.lua before forwarding (never sent as `''`,
        which the server would reject) -- meaning "inherit the shop-wide
        default," same as a config.lua location entry with that field
        unset.

      tablet:equipmentShopMoveLocation { locationKey: string, updates?: { label?: string|false, model?: string|false, scenario?: string|false }, useCurrentPosition?: boolean } -> cb({ ok, locations?, error? })
        Serves BOTH this screen's "Edit" (metadata only: `updates` present,
        `useCurrentPosition` absent -- each of label/model/scenario is
        EITHER a non-empty string override OR `false` to reset that field
        back to the shop-wide default; ALWAYS all three, never omitted,
        since the edit form always starts pre-filled from a real,
        already-resolved value) and "Move Here" (`useCurrentPosition: true`,
        `updates` absent -- client/tablet.lua captures the SAME
        GetEntityCoords/GetEntityHeading this page cannot). Only ever valid
        for a `db:<id>` locationKey -- refused (`invalid_key`) for a
        `cfg:<n>` one, which this page never offers Edit/Move Here for.

      tablet:equipmentShopRemoveLocation { locationKey: string } -> cb({ ok, locations?, error? })
        Only ever valid for a `db:<id>` locationKey, same reasoning as Move
        above. CanManageShopLocations (high command OR a delegated
        'k9.equipmentshoplocations' grant, see canManageShopLocations()'s
        own doc comment), re-verified server-side on every one of these
        three mutating calls regardless of what this page shows.

      tablet:runtimeListFeatures {} -> cb({ ok, features?, error? })
        HIGH COMMAND OR A DELEGATED 'k9.runtimecontrol' GRANT screen (this
        page shows the management screen to a viewer who passes
        canManageRuntimeControl(); server/runtimecontrol.lua's own
        runtimeListFeatures re-verifies the real CanManageRuntimeControl
        gate itself regardless of what this page shows). `features` is an
        ARRAY (order NOT guaranteed -- this page sorts it by `name` for a stable
        display), one entry per Config.Features key:
          { name, currentValue: boolean, configLuaDefault: boolean,
            tier: 'live'|'onstart'|'rawtoplevel'|'clientonly'|'protected'|'unaudited',
            note?: string, overridden: boolean, overriddenBy?: string,
            overriddenAt?: string, protected: boolean }
        `tier` is THE HONESTY REQUIREMENT this screen exists to satisfy --
        see runtimeTierLabel()/runtimeTierDescription() below, which turn
        this bare string into the plain-language explanation shown on every
        row BEFORE a toggle is ever pressed. `note`, when present, is
        server-authored SUPPLEMENTARY prose about a specific partial-
        liveness gap for that one feature (e.g. ScentTracking's drop-hook
        caveat) -- rendered as a passthrough, same posture as this page's
        own `message`-field handling elsewhere, never this row's PRIMARY
        (locale-driven) explanation.

      tablet:runtimeSetFeature { name: string, value: boolean } -> cb({ ok, appliedLive?, restartRequired?, configEditRequired?, tier?, error? })
        A `protected`/`unaudited` tier feature is REFUSED outright
        (`error='protected_feature'`/`'unaudited_feature'`) -- this page
        never even renders a toggle for either (see buildRuntimeFeatureRow()
        below), so reaching this refusal at all would mean a modified
        client bypassed this page entirely, exactly the case THE SECURITY
        RULE above already assumes. On success, the post-action notice
        reuses the SAME tier description already shown on the row before
        the click was made (never re-derived from `note`, which this file
        does not forward at all -- see runtimeFeatureListFeatures' own doc
        note above and this page's header THE SECURITY RULE).

      tablet:runtimeResetFeature { name: string } -> cb({ ok, value?, restartRequired?, error? })
        Restores `name` to its config.lua-shipped default. NOTE: this
        page does NOT trust this response's own `restartRequired` (server/
        runtimecontrol.lua's own runtimeResetFeature always reports `false`
        regardless of tier -- a known asymmetry flagged upstream, not
        relied on here); the post-reset notice instead reuses this row's
        OWN, already-known `tier` from the last successful
        tablet:runtimeListFeatures load, same as a successful Set above.

      tablet:runtimeListTunables {} -> cb({ ok, tunables?, error? })
        Same HIGH COMMAND OR A DELEGATED 'k9.runtimecontrol' GRANT posture as runtimeListFeatures above.
        `tunables` is an ARRAY (order not guaranteed -- sorted by `key`
        here), one entry per TUNABLE_REGISTRY key:
          { key, currentValue: number, configLuaDefault: number,
            min: number, max: number, integer: boolean, overridden: boolean,
            overriddenBy?: string, overriddenAt?: string }
        Every tunable is server-confirmed LIVE (server/runtimecontrol.lua's
        own header PART 1B, exclusion rule 3) -- there is no tier concept
        for this list.

      tablet:runtimeSetTunable { key: string, value: number } -> cb({ ok, appliedLive?, restartRequired?, value?, error?, min?, max? })
        `value` is forwarded AS-IS (only a basic "is this even a number"
        guard applies client-side) -- server/runtimecontrol.lua's own
        [min,max]/integer check is the only authoritative gate; a rejection
        (`error='out_of_range'`) carries the REAL `min`/`max` back, echoed
        verbatim by this page's own runtimeTunableErrorText(), never a
        client-guessed range.

      tablet:runtimeResetTunable { key: string } -> cb({ ok, value?, restartRequired?, error? })
        Restores `key` to its config.lua-shipped default. Unlike
        runtimeResetFeature above, `restartRequired` here is always
        correctly `false` (every tunable is live), so no special handling
        is needed on this page for it.

      tablet:auditCert { targetCitizenId: string, limit?: number } -> cb(AuditResult)
      tablet:auditPartner { targetCitizenId: string, limit?: number } -> cb(AuditResult)
      tablet:auditSearch { mode: 'officer'|'plate'|'person'|'recent', value?: string, limit?: number } -> cb(AuditResult)
      tablet:auditXp { targetCitizenId: string } -> cb(AuditResult)
      tablet:auditDept { departmentKey: string, limit?: number } -> cb(AuditResult)
      tablet:auditCatalog { catalogName: string, limit?: number } -> cb(AuditResult)
        The K9 Audit Trail viewer's own tab -- server/admin.lua's SIX
        tabletAudit* callbacks, verified directly against that file's own
        source (not assumed). The first five are each a thin, read-only
        wrapper around the EXACT SAME Query* function/K9Store accessor its
        `/k9audit*` chat command counterpart already calls, gated by the
        SAME IsAuthorizedAdmin(source) and the SAME shared per-source
        cooldown budget. tabletAuditCatalog (the sixth, no chat command
        counterpart at all) is the same shape but reads instead from
        server/admin.lua's own CATALOG_AUDIT_SOURCES table, keyed by
        `catalogName` -- see that table's own trust-boundary header for why
        an adversarial `catalogName` can never reach any table it does not
        explicitly name. AuditResult, success:
          { ok: true, rows: Array<object>, label: string, cap: number, limit?: number, truncated?: boolean }
        `cap`/`limit`/`truncated` (added in a LATER pass than the first
        five bridges -- see server/admin.lua's own ClampLimit and
        CALLBACK SURFACE comments for the authoritative contract): `cap` is
        that file's own HARD_MAX_RESULTS, served back on EVERY success
        response (including tabletAuditXp's, for a uniform shape, even
        though that one query takes no `limit` at all); `limit` is the
        exact, already-clamped value the server actually used for a query
        that DOES take one; `truncated` is `true` only when the caller's
        own request exceeded `cap` and was cut down to it. This page treats
        `cap` as the LIVE, authoritative ceiling from the moment any query
        succeeds (see auditEffectiveCap()/AUDIT_LIMIT_MAX_FALLBACK below) --
        the fallback constant is a last resort only, never assumed correct
        once the server has actually reported a real value. `label` is
        SERVER-AUTHORED, already locale()-resolved prose (this
        resource's `admin` locale group, a DIFFERENT namespace than this
        page's own `strings`/S()) -- rendered verbatim via textContent as
        a result-set caption, same "message-field passthrough" posture
        this page already applies to every other server-authored detail
        string. `rows`'s column shape is DIFFERENT PER MODE, never
        reshaped by this page -- see buildAuditResultTable() below for the
        exact column list each mode renders:
          cert:    { job, granted_by, granted_at, revoked_by, revoked_at, active }
          partner: { k9_citizenid, handler_citizenid, established_by, established_at, ended_by, ended_at, active } (also carries `id`, a sort key only -- never rendered)
          search:  { searcher_citizenid, searcher_job, target_type, target_plate, target_citizenid, result, total_weight, alert_tier, searched_at } (also carries `id`, not rendered)
          xp:      { xp, updated_at } -- 0 or 1 rows, citizenid is k9_progression's own PRIMARY KEY
          dept:    { citizenid, granted_by, granted_at } -- ACTIVE roster only, never revoked history
          catalog: shape depends on WHICH of the 8 `catalogName` values was requested -- see
                   server/admin.lua's own CATALOG_AUDIT_SOURCES table and this file's own
                   auditColumnsForCatalog() for the authoritative per-catalog column list;
                   six share { action, <catalog-specific key>, detail, changed_by, changed_at },
                   shopLocations carries { action, x, y, z, heading, model, scenario, label,
                   changed_by, changed_at } instead, runtimeOverrides carries
                   { override_key, kind, old_value, new_value, changed_by, changed_at }, and
                   tabletThemes carries { primary_color, accent_color, background_color,
                   text_color, density, header_title, changed_by, changed_at }
        Failure: { ok: false, error: 'not_authorized'|'rate_limited'|'invalid_args'|'timeout'|'network_error'|'exception', message?: string }
        -- same generic failure shape/fetchNui() synthesis as every other
        callback on this page; see auditErrorText() below.
        GATING (a CONVENIENCE ONLY, per THE SECURITY RULE -- see canViewAudit()
        below): server/admin.lua's own IsAuthorizedAdmin qualifies a caller
        via job.isboss, job.grade >= Config.Departments[job.name].auditGrade,
        an explicit 'k9.audit' permission grant, OR high command -- the FIRST
        THREE of those are EXACTLY what server/tablet.lua's own
        MeetsDepartmentRank(source, 'auditGrade')/ResolveEffectivePermissions
        already resolve into viewer.effectivePermissions containing
        'k9.audit' (verified directly against that file's source, not
        assumed) -- so this page shows the Audit tab to ANY viewer whose
        effectivePermissions includes 'k9.audit', not only isHighCommand,
        unlike the Theme/Cert Tiers/Shop Locations/Runtime Control tabs
        above. The one thing this client-side signal does NOT reflect is
        server/admin.lua's own PER-PERSON FEATURE CONTROL layer
        (block.AdminAuditCommands / RequireGrant.AdminAuditCommands) --
        exactly why this is a convenience only: a viewer who qualifies by
        rank/grant but is individually blocked still sees this tab, and
        simply gets `error: 'not_authorized'` back on every query, which
        this screen renders as a normal error state, never a blank one.
        `limit`, wherever accepted, is OPTIONAL -- an absent value lets
        server/admin.lua's own ClampLimit apply its configured default;
        this page still clamps whatever it sends into
        [AUDIT_LIMIT_MIN, auditEffectiveCap()] client-side so a typed value
        is never silently truncated server-side with no visible feedback
        here. auditEffectiveCap() prefers the REAL cap the server itself
        reported on the most recent successful query (`result.cap` above)
        -- AUDIT_LIMIT_MAX_FALLBACK (a hardcoded 100, matching
        server/admin.lua's HARD_MAX_RESULTS at the time this fallback was
        written) is used ONLY before that has ever happened (first render
        of a fresh tablet session) or if a response is ever missing `cap`
        entirely (a server build that predates this field) -- see that
        constant's own comment for why it is deliberately never assumed
        correct once a real value is known. Even when this page's own guess
        is stale and sends a `limit` the server ends up clamping further,
        `result.truncated`/`result.limit` on the response tell the operator
        exactly what happened rather than silently showing a short list --
        see buildAuditResults()'s own truncation notice.

    Lua -> JS (SendNUIMessage on the TOP window, relayed into this page's
    OWN window by html/tablet-bridge.js for any action matching /^tablet:/
    -- see that file's header for why a relay is needed at all):

      { action: 'tablet:open', data: {
          capabilities: { 'k9.access': {label,description}, ... },  // verbatim Config.Permissions text -- see html/tablet-bridge... no, see this file's DEFAULT_CAPABILITIES for the exact fallback copy this must match
          strings: { <key>: <resolved locale string>, ... },        // see DEFAULT_STRINGS below for the full key list this page understands
          requestedView: 'highCommand'|'auto'|undefined,             // PRESENTATION HINT ONLY. loadMyRecord() consumes this (see its own comment) strictly AFTER tablet:requestMyRecord's server-verified viewer fields for THIS caller are known. 'auto' (the default, sent by the ordinary command/item/radial -- owner-directed, 2026-08-26, "one command ... based off the rank") lands a canAccessConsole()-qualifying caller on the console tab pre-loaded, and silently leaves everyone else on the ordinary landing screen -- no notice, since they never asked for the console. 'highCommand' (client/tablet.lua's now-OPTIONAL Config.CommandTablet.highCommandCommand shortcut, default disabled) applies the SAME canAccessConsole() check but shows a plain "you don't have access" notice for an insufficient caller who explicitly typed it, exactly as before this pass. Never used to skip, gate, or shortcut any fetch above.
          maxXpPerGrant: number|null,                               // Config.HighCommand.maxXpPerGrant, UX hint only
          shopLocationsEnabled: boolean,                            // Config.Features.K9EquipmentShop -- UX hint only, SAME posture as themingEnabled: shows a disabled-server-wide note rather than hiding the screen; every equipmentShop* callback re-checks this live, server-side, regardless
          runtimeControlEnabled: boolean,                           // Config.Features.RuntimeFeatureControl -- UX hint only, SAME posture as themingEnabled/shopLocationsEnabled: shows a disabled-server-wide note rather than hiding the screen; runtimeListFeatures/ListTunables have no such gate at all (read-only values still load), only the four mutating runtimeSetFeature/runtimeSetTunable/runtimeResetFeature/runtimeResetTunable calls actually refuse ('feature_disabled') when this is off
        } }
        Sent once per open (every time the player runs the command/keybind
        that opens the tablet). This page reacts by becoming visible and
        immediately calling tablet:requestMyRecord.

      { action: 'tablet:close', data: {} }
        Lua-INITIATED close (player death, job change invalidating the
        session, resource stop). This page hides itself and resets ALL
        internal state back to a fresh-open baseline, so a later reopen
        never shows stale data from a previous session.

      { action: 'tablet:equipmentShopLocationsUpdated', data: { <key>: {x,y,z,heading,model,scenario,label}, ... } }
        Lua-INITIATED, NOT tied to this player's own tablet being open --
        fires for EVERY connected client on every successful Add/Move/
        RemoveLocation, so an already-open Shop Locations screen elsewhere
        updates live without a tab-switch or a tablet reopen. Applied
        unconditionally to state.shopLocations; never touches an
        in-progress add/edit draft (see handleShopLocationsUpdated()).
    ======================================================================

    ARCHITECTURE NOTE -- why an iframe, not a panel inside index.html:
    index.html's own `ui_page` is loaded once for the resource's entire
    client session and already hosts the always-on, focus-free HUD
    (html/app.js) -- FiveM's `ui_page` manifest key can only point at ONE
    file, so a genuinely separate document needs a different mechanism.
    This page is embedded via <iframe src="tablet.html"> inside
    index.html, itself unhidden/hidden by html/tablet-bridge.js. That gives
    this page its OWN JS global scope, its OWN DOM, and its OWN stylesheet
    -- a bug here (a global name collision, a CSS rule that would otherwise
    cascade) structurally CANNOT reach app.js's HUD, and vice versa. The
    one thing an iframe does NOT get for free is SendNUIMessage delivery --
    that lands on the top-level window only, never a descendant iframe
    automatically -- which is why tablet-bridge.js exists purely to relay
    tablet:* actions down into this page's own `message` listener below.

    FOCUS: this is the FIRST interactive, focus-taking NUI surface in this
    resource (contrast html/app.js's own "NO SetNuiFocus, ANYWHERE, EVER"
    HUD contract). SetNuiFocus itself is called ONLY from client/tablet.lua
    -- never from this file. This file's job on the closing side is only to
    reliably TELL Lua to release it (tablet:close) through every path a
    player might use to want out (Close button, Escape). Because a fully
    unresponsive/crashed copy of this page could never fire that fetch at
    all, client/tablet.lua should ALSO carry its own independent
    native-level Escape/close-keybind check that force-releases focus
    without depending on any NUI callback ever arriving -- flagged here so
    the requirement travels with the contract, not just in a chat message.
    ======================================================================
*/

(function () {
    'use strict';

    // ------------------------------------------------------------------
    // CONSTANTS
    // ------------------------------------------------------------------

    /** How long fetchNui() waits for a NUI callback response before giving
     * up and synthesizing a 'timeout' failure -- see this file's header
     * "never leave the player looking at an empty tablet with no
     * explanation" requirement. The underlying fetch is NOT aborted (no
     * AbortController dependency); its eventual real result, if any, is
     * simply ignored once this fires. */
    var NUI_TIMEOUT_MS = 8000;

    /** Debounce window for the roster search box -- avoids firing a
     * tablet:requestRoster round trip on every keystroke. */
    var SEARCH_DEBOUNCE_MS = 300;

    /** How long a destructive action button (Decertify/Revoke/Block) shows
     * its "Confirm?" state before reverting, if not clicked again -- see
     * mkConfirmButton() below. Deliberately NOT window.confirm()/alert():
     * FiveM's CEF-based NUI does not reliably support native browser
     * dialogs, so a real, in-DOM two-click confirm is used instead. */
    var CONFIRM_WINDOW_MS = 3000;

    /** THE SHARED RATE LIMIT (owner-directed "roster panel: checkboxes that
     * actually do something" pass) -- server/permissions.lua's
     * GrantPermission/RevokePermission share ONE cooldown per granter
     * (PERMISSION_ACTION_COOLDOWN_MS, currently 1500ms) -- ticking several
     * permission checkboxes for the same person in quick succession is
     * therefore a REAL, foreseeable way to trip it, since each checkbox
     * change is its own separate grant/revoke call. state.pendingAction
     * already guarantees at most one mutation is EVER in flight at a time
     * (a second click while one is pending is a no-op, snapping back to
     * the true state on the next render -- never a false tick); this
     * constant additionally disables the capability checkboxes for a short
     * window AFTER each one settles, with an honest reason shown via
     * title, so a fast operator setting up several permissions in a row is
     * told to slow down BEFORE firing a call the server would refuse,
     * rather than discovering it only via a rate_limited failure. Set
     * slightly above the server's own value (never below it) -- see
     * buildCapabilityRow() below for where this is applied. Deliberately
     * NOT a proposal to weaken or bypass the server's cooldown, which
     * remains the sole real enforcement regardless of this client-side
     * pacing (THE SECURITY RULE). */
    var PERMISSION_ACTION_MIN_INTERVAL_MS = 1600;

    /** Floor this page enforces on every tabletAudit* `limit` input,
     * client-side, BEFORE it is ever sent. This is a UX convenience only,
     * same as every other client-side clamp on this page -- ClampLimit
     * server-side is the only real bound regardless of what this page
     * ever sends. */
    var AUDIT_LIMIT_MIN = 1;

    /** FALLBACK ONLY -- explicitly NOT the authoritative ceiling. This used
     * to be treated as if it were server/admin.lua's own HARD_MAX_RESULTS,
     * hardcoded here and "updated by hand if that server-side constant
     * ever changes" -- exactly the two-copies-of-one-number problem this
     * pass exists to close. server/admin.lua's five tabletAudit* callbacks
     * now serve their real, live ceiling back as `cap` on every successful
     * response (see this file's header NUI CONTRACT note on those five
     * bridges, and server/admin.lua's own ClampLimit/CALLBACK SURFACE
     * comments for the authoritative contract) -- auditEffectiveCap()
     * below is what every clamp/UI-hint on this page actually calls, and
     * it prefers that SERVED value the moment any query has ever
     * succeeded. This constant is used ONLY as a last resort: the very
     * first render of a fresh tablet session, before any audit query has
     * run at all, and as a safety net if a response is ever missing `cap`
     * entirely (a server build predating this pass). Deliberately renamed
     * from the old `AUDIT_LIMIT_MAX` (rather than quietly keeping that name
     * while its meaning changed underneath it) so every remaining use is
     * self-evidently a GUESS, never mistaken for the real bound again. */
    var AUDIT_LIMIT_MAX_FALLBACK = 100;

    /** English fallback UI-chrome strings, keyed exactly as
     * client/tablet.lua's `strings` map in the tablet:open payload uses
     * (see this file's header contract). client/tablet.lua's
     * BuildTabletStrings() sends `strings.title = locale('tablet.title')`
     * (and so on, one locale() call per key here) from locales/en.json's
     * `tablet` group, which is kept byte-identical to this object. Used
     * ONLY when a key is missing from that payload -- a hand-edited or
     * out-of-sync locale file, or a future key added here before
     * locales/*.json catches up -- so this page is never blank/broken for
     * a single missing key -- see S() below. This is a resilience net, not
     * a permanent i18n system: for every key currently in this object,
     * Lua already sends the real, locale()-resolved value, and this
     * fallback is simply never consulted.
     * @type {Record<string,string>} */
    // ------------------------------------------------------------------
    // CATALOG DATA -- moved to html/tablet-catalog.js on 2026-09-02 (1,749
    // lines of pure data that used to sit here, between the state setup and
    // the screen rendering). Re-bound under the SAME names, so every use
    // below is unchanged. tablet.html loads that file BEFORE this one; if it
    // did not, these three would be undefined and the tablet would render
    // nothing. See that file's own header for why only the data moved.
    // ------------------------------------------------------------------
    var DEFAULT_STRINGS = window.K9TabletCatalog.DEFAULT_STRINGS;
    var DEFAULT_CAPABILITIES = window.K9TabletCatalog.DEFAULT_CAPABILITIES;
    var CAPABILITY_ORDER = window.K9TabletCatalog.CAPABILITY_ORDER;
    var DEFAULT_THEME = window.K9TabletCatalog.DEFAULT_THEME;
    var THEME_DENSITY_OPTIONS = window.K9TabletCatalog.THEME_DENSITY_OPTIONS;
    var COMMAND_REFERENCE_CATEGORIES = window.K9TabletCatalog.COMMAND_REFERENCE_CATEGORIES;
    var COMMAND_REFERENCE = window.K9TabletCatalog.COMMAND_REFERENCE;

    /**
     * Best-effort, HONEST-WHEN-UNCERTAIN availability for one COMMAND_REFERENCE
     * entry's `gate`, from data this page ALREADY has (state.viewer,
     * state.myRecord.myFeatures) -- no new NUI callback, no new round trip.
     * NEVER an enforcement decision (THE SECURITY RULE) -- the server
     * independently re-checks everything this predicts, on every real
     * command/callback, regardless of what this returns.
     *
     * Gate kinds, and exactly what each reuses:
     *   'open'       -- no personal certification/permission gate at all in
     *                   the real command (k9dropfetchball, k9lineupcancel,
     *                   etc.) -- always 'available' UNLESS an optional
     *                   `featureKey` names a Config.Features key that is
     *                   globally off (state.myRecord.myFeatures[key].state
     *                   === 'global_off'), the one signal that check is
     *                   accurate for REGARDLESS of this viewer's own
     *                   certification/block status (server/tablet.lua's
     *                   ResolveFeatureState checks Config.Features[key]
     *                   FIRST, before anything person-specific).
     *   'access'     -- the real command requires HasK9Access() (an active
     *                   certification) -- checked via 'k9.access' in
     *                   viewer.effectivePermissions (server/tablet.lua's own
     *                   ResolveEffectivePermissions resolves that key from
     *                   the exact same HasK9Access(source) the real command
     *                   calls). `featureKey` here is REQUIRED and its
     *                   resolved `state` is trusted AS-IS: every command
     *                   using this gate kind (verified by direct read of
     *                   each one's own server handler, not assumed from its
     *                   feature's general purpose) checks Config.Features[key]
     *                   AND a per-person block/RequireGrant AND HasK9Access,
     *                   in the SAME order ResolveFeatureState resolves them,
     *                   so its `state` field is a byte-accurate proxy.
     *   'capability' -- the real command's gate is IsEligibleCertifier-style
     *                   (job.isboss OR a named HasPermission grant OR
     *                   IsHighCommand OR a department rank threshold) rather
     *                   than "any certified handler" -- checked via
     *                   viewer.isHighCommand OR that exact capability key in
     *                   viewer.effectivePermissions (server/tablet.lua's own
     *                   ResolveEffectivePermissions resolves 'k9.certify'/
     *                   'k9.audit'/'k9.givexp' through the SAME
     *                   MeetsDepartmentRank/HasPermission/IsHighCommand calls
     *                   each real command's own eligibility function uses --
     *                   verified by direct read of each, not assumed). An
     *                   optional `featureKey` is used ONLY for its
     *                   'global_off'/'blocked' states (both resolved BEFORE
     *                   ResolveFeatureState's own HasK9Access branch, so
     *                   accurate regardless of whether THIS viewer happens to
     *                   hold a K9 certification too, which the real gate for
     *                   these commands never asks about) -- its
     *                   'not_certified'/'requires_grant_missing'/'available'
     *                   states are NOT trusted here for that same reason (see
     *                   COMMAND_REFERENCE's own header). A KNOWN, DISCLOSED
     *                   GAP: if this viewer both holds the capability AND is
     *                   personally missing a configured feature.<Name> grant
     *                   AND does not otherwise hold an active K9
     *                   certification, this can under-rarely show 'available'
     *                   for what the server would actually refuse as
     *                   'requires_grant_missing' -- narrow, disclosed, and
     *                   never the OTHER direction (never claims available for
     *                   someone who lacks the capability at all).
     *   'highCommandOnly' -- same as 'capability' but for a real gate this
     *                   page has no direct capability-key proxy for
     *                   (k9bonetool's job.isboss-or-IsHighCommand, with no
     *                   matching entry in AdminCapabilityCandidateKeys) --
     *                   deliberately checks viewer.isHighCommand ONLY, a
     *                   CONSERVATIVE under-approximation: a department boss
     *                   who is not ALSO high command may see this marked
     *                   unavailable even though the real command would allow
     *                   them. Disclosed here rather than silently guessed at,
     *                   and safe in the direction that matters (never
     *                   over-promises).
     * @param {{kind:string, capability?:string, featureKey?:string}} gate
     * @returns {string} one of 'available'|'blocked'|'global_off'|'not_certified'|'requires_grant_missing'|'insufficient_authorization'
     */
    function commandReferenceStatus(gate) {
        // "NOT LOADED YET" IS NOT "TURNED OFF" (fixed 2026-08-31, from live
        // testing on a real server). Every gate resolution below ultimately
        // reads state.myRecord.myFeatures, and myFeatureState() deliberately
        // treats a key MISSING from that array as 'global_off' -- correct for
        // a record that really arrived, and the fix its own comment
        // describes. But when the record has not arrived at all the array is
        // empty, so every single key took that path and the whole Command
        // Console rendered "Disabled server-wide" against every feature on a
        // completely healthy server. An owner reads that as "my resource is
        // switched off", and it is indistinguishable from a real shutdown.
        //
        // Answering 'unknown' here is the only honest option. It must NOT be
        // done by returning null from myFeatureState() -- the callers below
        // treat null as "no gate matched, therefore available", which would
        // swap a false "everything is off" for a false "everything works",
        // and that is the worse of the two. One early return, before any gate
        // logic runs, is the whole fix.
        if (!state.myRecord || !Array.isArray(state.myRecord.myFeatures)) return 'unknown';

        var viewer = state.viewer || {};
        var effectivePermissions = Array.isArray(viewer.effectivePermissions) ? viewer.effectivePermissions : [];
        var hasAccess = effectivePermissions.indexOf('k9.access') !== -1;

        function myFeatureState(key) {
            var list = (state.myRecord && Array.isArray(state.myRecord.myFeatures)) ? state.myRecord.myFeatures : [];
            for (var i = 0; i < list.length; i++) {
                if (list[i] && list[i].key === key) return list[i].state;
            }
            // THE FIX: a featureKey not found in myFeatures[] is a key that is
            // entirely ABSENT from Config.Features server-side --
            // BuildMyFeaturesArray (server/tablet.lua) enumerates
            // `pairs(Config.Features)` FRESH on every call, so a key that was
            // never set (not even to `false`) never gets an array entry at
            // all; it does not arrive here as some other falsy state, it
            // simply never shows up. In Lua, that same missing key reads as
            // `nil`, and `Config.Features[key] == true` -- the very first
            // check in ResolveFeatureState, the real server gate every
            // command using this gate kind mirrors -- is false for `nil`
            // exactly the same as for an explicit `false`. So "not found
            // here" MUST resolve the same as an explicit 'global_off', never
            // fall through to "no opinion" -- that fallthrough (returning
            // null, which every caller below then treats as "no gate
            // matched, must be open") is THE bug this closes: it is what let
            // a permanently-removed feature (ScentTrailHunt, removed from
            // config.lua) report 'available' on this screen while being
            // unconditionally OFF for real.
            //
            // This does NOT blur the THREE separate states this file's own
            // callers must keep apart:
            //   1. A command with no featureKey at all -- genuinely ungated,
            //      really available. Never reaches this function: every call
            //      site below is already guarded by `gate.featureKey ? ... :
            //      null`, so an absent featureKey short-circuits to `null`
            //      BEFORE myFeatureState is ever invoked, and that branch is
            //      untouched by this change.
            //   2. A featureKey present and `true` -- ResolveFeatureState
            //      resolves it to a real state (often 'available'), and
            //      BuildMyFeaturesArray gives it a real array entry, so the
            //      loop above finds and returns THAT resolved state,
            //      unaffected by this fallback.
            //   3. A featureKey present and `false`, OR absent entirely --
            //      both mean OFF. `false` was already handled correctly
            //      before this fix (ResolveFeatureState already returns
            //      'global_off' for it, and it DOES get an array entry
            //      because `pairs()` iterates an explicit `false` value just
            //      fine) -- only "entirely absent" was falling through. This
            //      fallback makes the "absent" half of case 3 match the
            //      "present and false" half, which is the one and only
            //      change this function makes.
            return 'global_off';
        }

        if (gate.kind === 'open') {
            if (gate.featureKey && myFeatureState(gate.featureKey) === 'global_off') return 'global_off';
            return 'available';
        }

        if (gate.kind === 'access') {
            if (!hasAccess) return 'not_certified';
            var accessState = gate.featureKey ? myFeatureState(gate.featureKey) : null;
            return accessState || 'available';
        }

        if (gate.kind === 'capability' || gate.kind === 'highCommandOnly') {
            var hasCapability = viewer.isHighCommand === true
                || (gate.kind === 'capability' && effectivePermissions.indexOf(gate.capability) !== -1);
            var gatedFeatureState = gate.featureKey ? myFeatureState(gate.featureKey) : null;
            if (gatedFeatureState === 'global_off') return 'global_off';
            if (gatedFeatureState === 'blocked') return 'blocked';
            if (!hasCapability) return 'insufficient_authorization';
            if (gatedFeatureState === 'requires_grant_missing') return 'requires_grant_missing';
            return 'available';
        }

        return 'available';
    }

    /** @param {string} status @returns {string} localized badge text -- reuses
     * featureStateLabel()'s own four real strings for the states that are
     * genuinely the same concept, and one new key for the one status
     * featureStateLabel() has no honest word for ('insufficient_authorization'
     * -- a rank/permission/High-Command gate, not a certification one; see
     * commandReferenceStatus()'s own doc comment for why these are kept
     * distinct rather than reusing 'state_not_certified', which would be
     * simply WRONG for e.g. /k9audit cert). */
    function commandReferenceStatusLabel(status) {
        if (status === 'unknown') return S('cmdref_status_unknown');
        if (status === 'insufficient_authorization') return S('cmdref_status_insufficient_authorization');
        return featureStateLabel(status);
    }

    /** @param {string} status @returns {string} CSS class SUFFIX -- reuses the
     * existing `.k9tablet-feature-state--*` palette (available=green,
     * blocked=red, global_off/not_certified/requires_grant_missing=amber)
     * with ZERO new CSS: 'insufficient_authorization' maps onto the SAME
     * amber "you don't currently hold what this needs" bucket as
     * 'requires_grant_missing' -- visually identical concern, distinguished
     * only by its own, more precise label text above. */
    function commandReferenceStatusClass(status) {
        // Amber, same bucket as the other "cannot say this is available"
        // states -- deliberately NOT the green 'available' palette, and
        // deliberately not the red 'blocked' one either. Nothing is wrong;
        // we simply do not know yet.
        if (status === 'unknown') return 'requires_grant_missing';
        if (status === 'insufficient_authorization') return 'requires_grant_missing';
        return status;
    }

    // ------------------------------------------------------------------
    // STATE -- single source of truth. Every mutation calls render(),
    // which clears and rebuilds the ENTIRE visible screen from this object.
    // No incremental DOM patching anywhere in this file: given this page's
    // real update frequency (user-driven clicks/searches, not a per-frame
    // HUD), a full rebuild per change is simpler to prove correct/secure
    // than tracking manual DOM diffs, at a perf cost that does not matter
    // here. See render() below.
    // ------------------------------------------------------------------
    var state = {
        open: false,
        screen: 'home', // 'home' (the landing view AND the whole of your own record) | 'guide' | 'console' | 'person' | 'theme' | 'catalogs' | 'shop' | 'runtime_control' | 'settings_overview' | ... -- 'home' is the DEFAULT landing view (see buildHomeScreen()), reset on every open in handleOpen()
        strings: {},
        capabilities: {},
        maxXpPerGrant: null,
        peds: [], // Config.Peds, verbatim -- see tablet:assignK9Role's own NUI contract note; display list only, server re-validates the chosen model regardless
        specializations: {}, // Config.K9Specializations, verbatim -- display list only for the person screen's specialization grant picker; server/certifications/'s GrantSpecialization re-checks this SAME table server-side
        themingEnabled: false, // Config.Features.TabletTheming -- UX hint only, see client/tablet.lua's own NUI CONTRACT note
        shopLocationsEnabled: false, // Config.Features.K9EquipmentShop -- UX hint only, SAME posture as themingEnabled
        branding: {}, // { serverName, logo, theme:{4 colors} } -- Config.CommandTablet.branding, verbatim; see buildBrandingElement()/applyBrandingSeedTheme()
        // 'highCommand' | 'auto' -- set from tablet:open's own
        // `requestedView`, CONSUMED (reset to null) the first time
        // loadMyRecord() resolves after an open -- see that function's own
        // comment. A PRESENTATION HINT ONLY: it never gates a fetch by
        // itself, it only decides which screen loadMyRecord() lands on
        // once the server's own `viewer` fields for THIS caller are known.
        // 'auto' is the default for EVERY ordinary open (the command, the
        // item, the radial menu) -- owner-directed, 2026-08-26: "make it
        // one command that makes it based off the rank in the department"
        // -- a caller canAccessConsole() admits (isHighCommand, or an
        // explicit 'k9.audit' grant -- the SAME gate the Console tab/Home
        // card already use) lands straight on the console; anyone else
        // lands wherever they always have (the 'home' screen), silently,
        // no notice -- they never asked for the console, so refusing one
        // would be a surprise, not a helpful message. 'highCommand' is the
        // OLDER, now-optional Config.CommandTablet.highCommandCommand
        // shortcut, still supported for a server that already has it bound
        // to a key/macro: same canAccessConsole() check, but an
        // insufficient caller who explicitly typed THIS command still sees
        // 'high_command_required_notice' -- they asked, so they get told
        // why not, exactly as before this pass.
        requestedView: null,

        viewer: null, // set once tablet:requestMyRecord resolves successfully
        myRecordLoading: false,
        myRecordError: null, // { error, message }
        myRecord: null, // { certifications, xp, tierLabel, myFeatures }
        // CLIENT-LOCAL "who is holding it" role signal (this pass) --
        // client/tablet.lua's own ResolveLocalRoleFlags() doc comment has
        // the full reasoning. Cosmetic/framing ONLY (buildHomeScreen()'s
        // own role badge), never sent back to any mutation/trigger
        // callback -- see THE SECURITY RULE at the top of this file.
        // Populated from tablet:requestMyRecord's response alongside
        // `viewer` above (same loadMyRecord() call, same lifecycle), and
        // reset to false on every open, same as viewer/myRecord above.
        isK9Model: false,
        isPartnered: false,

        // Partnerships tab (this pass) -- see buildPartnershipsScreen()'s
        // own header comment. myPartnerships/myPartnershipsLoading/
        // myPartnershipsError follow the SAME {loading, error, value}
        // shape as myRecord above; partnershipsAdmin* is the SEPARATE,
        // high-command-only lookup section rendered on top of the same
        // screen, keyed by whichever citizenid the operator last submitted
        // (never auto-populated, matching Console's own "open by ID" box).
        myPartnershipsLoading: false,
        myPartnershipsError: null, // { error, message }
        myPartnerships: null, // { featureEnabled, partnerships: [...], truncated }
        partnershipsAdminLoading: false,
        partnershipsAdminError: null,
        partnershipsAdminResult: null, // { target: {citizenid, name}, featureEnabled, partnerships: [...], truncated }

        // Command Reference screen's own search box -- see
        // buildCommandReferenceScreen() below. A plain client-side filter
        // over the static COMMAND_REFERENCE catalog, never a server round
        // trip (there is nothing server-side to ask -- this whole screen is
        // presentation over data this page already has, see
        // commandReferenceStatus()'s own doc comment), so this needs no
        // loading/error pair the way rosterQuery's server-backed search
        // does just below.
        commandReferenceQuery: '',

        rosterLoading: false,
        rosterError: null,
        roster: null, // { rows, truncated, truncatedMessage }
        rosterQuery: '',
        findPersonQuery: '', // the Console's one search box -- see buildFindPersonBar()
        personOpenSections: {}, // which Person-screen foldouts are open -- see buildPersonFoldout()

        // ONLINE PLAYERS LIST (owner-directed, 2026-08-26: "make the add
        // permission section... where its a list when i choose a player
        // id") -- see buildOnlinePlayersSection()'s own header for the
        // full contract. Server-backed search, same debounced shape as
        // rosterQuery/loadRoster() just above, but a SEPARATE query/
        // loading/error/result set: these are two independent lists on
        // the same screen.
        onlinePlayersLoading: false,
        onlinePlayersError: null,
        onlinePlayers: null, // { rows: [{source,name,jobLabel,hasK9Access,nonce}], truncated, truncatedMessage }
        onlinePlayersQuery: '',
        // Set to the `source` of the row currently being resolved
        // (tablet:openOnlinePlayer in flight) -- disables that ONE row's
        // button (never the whole screen) and guards against a fast
        // double-click firing two resolves for the same row, each trying
        // to consume the SAME single-use nonce (the second would only
        // ever see 'stale_online_list', a confusing failure for something
        // that was never really a problem).
        onlinePlayersOpeningSource: null,

        person: null, // { citizenid, name } -- who the 'person' screen is currently showing
        personSummaryLoading: false,
        personSummaryError: null,
        personSummary: null, // { certifications, xp, tierLabel, permissions }
        personFeaturesLoading: false,
        personFeaturesError: null,
        personFeatures: null, // { features }
        personFeatureQuery: '',
        // Which screen opened the CURRENTLY-showing Person screen --
        // 'console' (the default -- Console tab search, the "open by exact
        // citizen ID" box, or the Online Players picker; ALL of these pass
        // no third argument to openPerson(), so this defaults to 'console'
        // for every one of them, preserving their existing Back behaviour
        // byte-for-byte) | 'roster' (one screen with a K9/Handlers bucket
        // toggle -- it was two screens, 'roster_k9' and 'roster_handlers',
        // that differed only by which array they rendered;
        // docs/history/ROSTER_SPEC.md §0 -- the roster rows are a THIRD entry point into
        // this SAME buildPersonScreen(), never a second person-detail
        // screen; this one field is the entire "mode flag" that entry
        // point needs -- it only ever changes where the Back button
        // returns to, never what the screen shows or does). See
        // openPerson()'s own third parameter and buildPersonScreen()'s own
        // Back button.
        personOpenedFrom: 'console',

        // K9/HANDLER PERSONNEL ROSTERS (docs/history/ROSTER_SPEC.md, Phase B) -- owner,
        // verbatim: "make it in the tablet where there is a roster where we
        // can assign callsigns see list of hired k9s and full menu to fire
        // promote etc" / "Also a separate roster for handlers same thing" /
        // "Also in the roster be able to reorder them by rank." ONE fetch
        // (qbx_k9unit:server:rosterList, server/roster.lua -- Phase A,
        // already committed) backs BOTH the two new roster tabs below AND
        // the Roster Role/Callsign section this pass adds to
        // buildPersonScreen() (via findPersonnelRosterRow()) -- never a
        // second read mechanism, and never re-fetched merely to re-sort
        // (see personnelRosterSort below, and sortedRosterRows()).
        personnelRosterLoading: false,
        personnelRosterError: null, // { error, message? }
        personnelRoster: null, // { k9: RosterRow[], handlers: RosterRow[], unassigned: RosterRow[] } -- null until the first successful load
        // 'tier' (default, matches server/roster.lua's own default sort) |
        // 'grade' | 'xp' -- docs/history/ROSTER_SPEC.md §9: a PURE, client-only re-sort
        // of the already-fetched arrays above, never a second round trip
        // (acceptance criterion #13) and NEVER persisted across a reopen
        // (§9's own explicit scope cut) -- reset to 'tier' in handleOpen(),
        // same as every other per-session-only value on this page.
        personnelRosterSort: 'tier',
        // WHICH ROSTER BUCKET THE ONE Roster TAB IS SHOWING -- 'k9' | 'handler'.
        // This used to be encoded in the SCREEN itself: two tabs, 'roster_k9'
        // and 'roster_handlers', both calling buildPersonnelRosterScreen()
        // with a different argument. It was never two screens, so it is one
        // tab with a toggle now (see buildRosterBucketControls()). Reset to
        // 'k9' on every open, same per-session-only discipline as
        // personnelRosterSort above.
        personnelRosterBucket: 'k9',

        // THE SHARED RATE LIMIT -- see PERMISSION_ACTION_MIN_INTERVAL_MS's
        // own doc comment above. Timestamp (Date.now()) of the last
        // tablet:grantPermission/revokePermission call THIS session fired,
        // reset to 0 on every open (handleOpen()) same as every other
        // per-session value here -- never persisted, never sent anywhere.
        lastPermissionMutationAt: 0,

        // Tablet theming -- applied for EVERY viewer (theme itself is
        // fetched once per open and again live on every
        // qbx_k9unit:client:themeUpdated push, regardless of which screen
        // is showing or whether this viewer is high command at all).
        theme: null, // { primaryColor, accentColor, backgroundColor, textColor, density, headerTitle } -- null until the first tablet:getTheme resolves; DEFAULT_THEME is used to render/apply in the meantime, see applyThemeToDocument()
        themeLoading: false,
        themeError: null,
        themeDraft: null, // a WORKING COPY of `theme` the theme-editor screen's inputs mutate locally before Save -- never sent anywhere until the operator presses Save, and always reset from the authoritative `theme` on load/open/push so a stale edit can never silently linger across a reopen
        themeFieldError: null, // set to e.g. 'primaryColor' when the server's last tabletSetTheme response was reason='invalid_field' -- highlights which of the six inputs it rejected; cleared on the next Save attempt

        // Certification tier editing -- server/certtiers.lua. The
        // catalogue is NEVER hardcoded here (see loadCertTiers()'s own
        // comment): `certTiers` is null until the first successful
        // tablet:certTiersList, exactly like every other server-sourced
        // list on this page (roster/personSummary/personFeatures/theme).
        certTiers: null, // [{ key, label, ordinal, capabilities: {capKey:true} }, ...], already ordinal-sorted by the server
        certTierCapabilityCatalog: {}, // { [capabilityKey]: { label } } -- server/certtiers.lua's own fixed, code-owned CAPABILITY_CATALOG, still FETCHED rather than hardcoded, so a future catalog entry needs no client change here
        certTiersLoading: false,
        certTiersError: null,
        certTierWarning: null, // the non-optional retroactive-rerank warning from the LAST successful reorder (server/certtiers.lua's own HAZARD 3) -- rendered as its own prominent banner, not folded into the generic actionNotice, so it is never missed
        certTierDraft: null, // { key, label, capabilities: {capKey:true}, isNew } -- the add/edit form's own working copy; null = form closed
        certTierFieldError: null, // 'key' | 'label' | 'capabilities' | null -- which of the draft form's own inputs the server's last certTiersUpsert rejected
        certTierActionError: null, // { key, text } -- a delete REFUSAL (tier_in_use/protected_tier) rendered inline on that specific row, not just the generic top-of-panel notice

        // K9 ROLES (server/roles.lua) -- tiers and specializations merged
        // into one catalog high command edits in Server Settings > Catalogs.
        roles: null, // [{ key, label, xpRequired, unlocks: [unlockKey] }] sorted by XP needed
        rolesUnlockOptions: [], // [{ key, label }] -- the closed unlock list, from the server
        rolesLoading: false,
        rolesError: null,
        roleDraft: null, // { key|null, label, xpRequired, unlocks: {unlockKey:true} } -- the add/edit form; null = closed
        roleFieldError: null, // 'label' | 'xpRequired' | 'unlocks' | null

        // Permission-key catalog editing -- server/permissionkeycatalog.lua
        // (owner-directed "...even add or remove permissions" pass). Sits
        // alongside the cert-tier screen above, same "never hardcoded,
        // never preloaded" posture: `permissionKeys` is null until the
        // first successful tablet:permKeysList. No ordinal/capabilities
        // concept exists for a permission key (see that file's own header
        // "WHY NO ORDINAL"), so this state is deliberately simpler than
        // certTier* above -- no warning banner, no reorder.
        permissionKeys: null, // [{ key, label, description, isConfigDefault }, ...], alphabetical (server-sorted)
        permissionKeysLoading: false,
        permissionKeysError: null,
        permissionKeyDraft: null, // { key, label, description, isNew } -- the add/edit form's own working copy; null = form closed
        permissionKeyFieldError: null, // 'key' | 'label' | 'description' | null -- which of the draft form's own inputs the server's last permKeysUpsert rejected
        permissionKeyActionError: null, // { key, text } -- a delete REFUSAL (reserved_namespace/unknown_key) rendered inline on that specific row, same shape as certTierActionError

        // K9 Supply Shop location management -- server/equipmentshop.lua.
        // Owner's own words: "make the shop a dog ped and i can change the
        // locations in the config or add more locations remove locations
        // etc along with in the high command tablet." `shopLocations` is
        // null until the first successful tablet:equipmentShopGetLocations,
        // same "never hardcoded, never preloaded" posture as certTiers.
        shopLocations: null, // { [locationKey]: {x,y,z,heading,model,scenario,label} } -- raw map from the server, keyed 'cfg:<n>' (config.lua, read-only here) or 'db:<id>' (runtime, editable)
        shopLocationsLoading: false,
        shopLocationsError: null,
        // STALE-RESPONSE GUARD counter -- see loadShopLocations()'s own
        // comment. This list has no per-viewer "identity" to compare
        // against arrival order the way loadPersonSummary() compares
        // targetCitizenId, so a monotonically increasing request id is
        // used instead: a response is only applied if it is still the
        // MOST RECENT request issued, discarding an older one that
        // resolves late (tab re-visited, or Refresh pressed twice).
        shopLocationsRequestId: 0,
        shopLocationDraft: null, // { key: string|null, label, model, scenario } -- key===null means "new location"; null = form closed
        shopLocationActionError: null, // { key, text } -- a Move/Remove refusal rendered inline on that specific row, same shape as certTierActionError

        // Runtime feature control + tuning -- server/runtimecontrol.lua
        // PART 1/1B. `runtimeFeatures`/`runtimeTunables` are null until the
        // first successful load, same "never hardcoded, never preloaded"
        // posture as certTiers/shopLocations above -- the registry lives
        // entirely server-side (FEATURE_TIERS/TUNABLE_REGISTRY), never
        // duplicated here.
        runtimeControlEnabled: false, // Config.Features.RuntimeFeatureControl -- UX hint only, see client/tablet.lua's own NUI CONTRACT note
        runtimeFeatures: null, // [{ name, currentValue, configLuaDefault, tier, note, overridden, overriddenBy, overriddenAt, protected }, ...] -- the COMPLETE server inventory; the table below renders only the `live` ones, see splitRuntimeFeaturesByReachability()
        runtimeFeaturesLoading: false,
        runtimeFeaturesError: null,
        runtimeFeaturesRequestId: 0, // STALE-RESPONSE GUARD -- same request-id shape as shopLocationsRequestId above (this list has no per-request identity to compare against arrival order)
        runtimeFeatureActionError: null, // { key: featureName, text } -- a Set/Reset refusal rendered inline on that specific row, same convention as certTierActionError/shopLocationActionError
        runtimeLockoutConfirm: null, // { name, action:'toggle'|'reset', newValue:?boolean, tier, typedValue:string } -- the read-and-type confirmation gate for ONE `lockoutRisk` feature at a time (see buildRuntimeLockoutConfirmPanel()); null = no confirmation panel open. NEVER decides authorization -- see openRuntimeLockoutConfirm()'s own doc comment.
        runtimeTunables: null, // [{ key, currentValue, configLuaDefault, min, max, integer, overridden, overriddenBy, overriddenAt }, ...]
        runtimeTunablesLoading: false,
        runtimeTunablesError: null,
        runtimeTunablesRequestId: 0, // STALE-RESPONSE GUARD, same shape as runtimeFeaturesRequestId
        runtimeTunableDraft: null, // { key, value: string } -- the inline number-editor's own working copy for ONE tunable at a time; null = no editor open
        runtimeTunableFieldError: null, // { key, text } -- a Set refusal (out_of_range/not_integer/etc.) rendered inline on that specific row

        // XP Rank Editor -- server/xptiers.lua (owner-directed "...set
        // experience level for each rank up" pass). Sits alongside the
        // cert-tier/permission-key/shop-location/runtime-control tabs
        // above, same "never hardcoded, never preloaded" posture:
        // `xpTiers` is null until the first successful tablet:xpTiersList
        // -- the four-rank ladder is DB-overlaid config (server/xptiers.lua's
        // own header), never duplicated here. No add/remove/reorder for
        // this ladder (fixed cardinality -- see that file's own header
        // "SCOPE DECISION"), so this state is deliberately simpler than
        // certTiers* above: one draft slot for whichever single rank is
        // currently being edited, no key/ordinal picker.
        xpTiers: null, // [{ ordinal, xp, label, speedMultiplier, scentRangeMultiplier, medkitCooldownMultiplier?, badge?, xpLocked }, ...], ordinal-ordered, straight from the server
        xpTiersLoading: false,
        xpTiersError: null,
        // Non-optional whenever the LAST successful upsert demoted at least
        // one currently-connected K9 -- server/xptiers.lua's own header
        // "THE ALREADY-PROMOTED PLAYER". Rendered as its own prominent
        // banner, SAME posture as certTierWarning above, never folded into
        // the generic actionNotice, so it is never missed.
        xpTierWarning: null,
        xpTierDraft: null, // { ordinal, xp: string, label: string, speedMultiplier: string, scentRangeMultiplier: string, medkitCooldownMultiplier: string, badge: string, xpLocked } -- the ONE open rank's working copy; null = no editor open. `xp` is never user-editable when xpLocked (rank 1) -- always submitted as 0 regardless of this field's own value.
        xpTierFieldError: null, // 'xp' | 'label' | 'speedMultiplier' | 'scentRangeMultiplier' | 'medkitCooldownMultiplier' | 'badge' | null -- which of the open draft's own inputs the last xpTiersUpsert rejected (client-side pre-check OR the server's own refusal, same field either way)
        xpTierActionError: null, // { ordinal, text } -- an upsert REFUSAL rendered inline on that specific rank's own row, same "cannot, and here is why" convention as certTierActionError/permissionKeyActionError/shopLocationActionError/runtimeTunableFieldError above

        // K9 INDIVIDUAL OVERRIDES -- server/k9profiles.lua (owner-directed
        // "god over that tablet with full customization over everything
        // related to that K9" pass). A per-citizenid, per-field override
        // ON TOP OF whichever XP tier that citizenid's K9 already
        // resolves to -- see that file's own header "RESOLUTION ORDER".
        // Two independent pieces on screen: the LIST of every citizenid
        // that currently has a live override (k9Profiles, straight from
        // tablet:k9ProfilesList), and, separately, ONE citizenid's full
        // detail + edit form (k9ProfileSelected/k9ProfileDraft) opened
        // either from that list's own "Manage" button or a fresh
        // citizenid typed into the lookup box.
        k9Profiles: null, // [{ citizenid, speedMultiplier?, scentRangeMultiplier?, medkitCooldownMultiplier?, note? }, ...] -- every citizenid with a LIVE override, straight from the server; null until first successful load
        k9ProfilesLoading: false,
        k9ProfilesError: null,
        k9ProfileLookupInput: '', // the lookup box's own raw text -- a citizenid, never validated until Look Up is pressed
        // STALE-RESPONSE GUARD identity, same shape as state.person.citizenid
        // for loadPersonSummary/loadPersonFeatures: set synchronously by
        // loadK9Profile() itself (the only entry point into this panel)
        // BEFORE its fetch even starts, and nulled by resetAndLoadK9Profiles()
        // on the way in. loadK9Profile()'s own .then() compares its
        // captured citizenid against this field, never against
        // k9ProfileLookupInput (that one keeps changing on every keystroke
        // and would wrongly flag a still-in-flight, still-current request
        // as stale the moment the operator types ahead in the box).
        k9ProfileSelectedCitizenId: null,
        k9ProfileSelected: null, // { citizenid, tierLabel, effective: {speedMultiplier,scentRangeMultiplier,medkitCooldownMultiplier?,overridden:{...}}, override: {...}|null } -- the ONE citizenid currently loaded, straight from tablet:k9ProfileGet
        k9ProfileSelectedLoading: false,
        k9ProfileSelectedError: null,
        // Non-optional whenever the acting officer's OWN citizenid was just
        // edited (server/k9profiles.lua's own "SELF-SERVICE VISIBILITY"
        // section) -- rendered as its own prominent banner, same posture
        // as xpTierWarning/certTierWarning above, never folded into the
        // generic actionNotice.
        k9ProfileWarning: null,
        k9ProfileDraft: null, // { citizenid, speedMultiplier: string, scentRangeMultiplier: string, medkitCooldownMultiplier: string, note: string } -- the open citizenid's working copy; blank field = "leave this field's own current value alone" (server/k9profiles.lua's own per-field-optional contract), never coerced to a number until Save
        k9ProfileFieldError: null, // 'speedMultiplier' | 'scentRangeMultiplier' | 'medkitCooldownMultiplier' | 'note' | null -- which of the open draft's own inputs the last k9ProfileUpsert rejected
        k9ProfileActionError: null, // plain string -- an upsert/reset REFUSAL rendered inline on the open detail panel, same "cannot, and here is why" convention as xpTierActionError above (no per-row addressing needed: only one citizenid's detail is ever open at a time)

        // K9 Supply Shop ITEM CATALOG editing -- server/equipmentshop.lua's
        // own "EQUIPMENT SHOP ITEM CATALOG" section. Sits alongside the
        // Shop Locations tab above -- same "K9 Supply Shop" domain, split
        // into two tabs because WHICH items are sold/at what price/order/
        // purchase-requirement is a SEPARATE server-side authorization key
        // ('k9.equipmentshopitems') from WHERE a shop ped stands
        // ('k9.equipmentshoplocations') -- see that file's own
        // CanManageShopItems/CanManageShopLocations doc comments. Same
        // "never hardcoded, never preloaded" posture as certTiers/
        // shopLocations/xpTiers above: `shopItems` is null until the first
        // successful tablet:equipmentShopItemsList.
        shopItems: null, // [{ key, label, price, currency, sortOrder, requiredTierKey, requiredSpecialization }, ...], already sortOrder-ascending, straight from server/equipmentshop.lua's own ListEquipmentShopItems. A TOMBSTONED item never appears in this array at all (the server's own catalog merge excludes it entirely -- see that file's own "TOMBSTONE, NOT HARD-DELETE" section) -- this screen never has to render a "retired" row for one, only ever fewer rows after a successful delete.
        shopItemsLoading: false,
        shopItemsError: null,
        shopItemDraft: null, // { key, price: string, label: string, currency: string, requiredTierKey: string, requiredSpecialization: string, isNew } -- the add/edit form's own working copy; requiredTierKey/requiredSpecialization are '' for "no requirement" (the draft form's own <select> "None" option), never null, so a plain `.value` read always works; null = form closed
        shopItemFieldError: null, // 'key' | 'price' | 'label' | 'currency' | 'requiredTierKey' | 'requiredSpecialization' | null -- which of the draft form's own inputs the server's last equipmentShopItemsUpsert rejected
        shopItemActionError: null, // { key, text } -- a Delete/Reorder refusal rendered inline on that specific row, same convention as certTierActionError above

        // K9 Audit Trail viewer -- server/admin.lua's six tabletAudit*
        // callbacks (this file's own NUI CONTRACT note on
        // tablet:auditCert/Partner/Search/Xp/Dept/Catalog has the full
        // contract). Gated on canViewAudit() (see buildTabs()), NOT
        // isHighCommand alone, unlike runtimeControlEnabled/
        // shopLocationsEnabled/themingEnabled above -- see that function's
        // own comment.
        auditEnabled: false, // Config.Features.AdminAuditCommands -- UX hint only, but see this file's own NUI CONTRACT note on why this one specifically disables the query controls rather than just showing a note
        auditMode: 'cert', // 'cert' | 'partner' | 'search' | 'xp' | 'dept' | 'catalog' -- which of the six tabletAudit* callbacks the query form below currently targets
        auditCitizenId: '', // shared free-text input for the cert/partner/xp modes
        auditDepartment: '', // tabletAuditDept's own `departmentKey` input -- free text, but pre-offered as a <select> from state.myRecord.certifications' own real departmentKey list (never a hardcoded department list -- see buildAuditForm()'s own 'dept' branch, which offers knownDepartmentKeys() as a datalist)
        auditSearchMode: 'officer', // 'officer' | 'plate' | 'person' | 'recent' -- tabletAuditSearch's own `mode`
        auditSearchValue: '', // citizenid (officer/person) or plate (plate); unused for 'recent'
        auditCatalogName: 'certTiers', // tabletAuditCatalog's own `catalogName` -- one of AUDIT_CATALOG_NAMES' 8 keys; 'certTiers' (that array's first entry) is the default, same "first entry of the fixed list" convention auditSearchMode's own 'officer' default already uses
        auditLimit: 20, // shared numeric input for every mode except 'xp' (which takes none) -- clamped into [AUDIT_LIMIT_MIN, auditEffectiveCap()] before ever being sent, see runAuditQuery()
        auditServerCap: null, // the REAL cap (server/admin.lua's HARD_MAX_RESULTS) as reported by `result.cap` on the most recent successful tabletAudit* response -- null until the FIRST one ever succeeds this session, or if a response is ever missing the field (older server build) -- see auditEffectiveCap()/AUDIT_LIMIT_MAX_FALLBACK
        auditLoading: false,
        auditError: null, // { error, message } -- the LAST failed tabletAudit* response, cleared on the next successful query or mode switch
        auditResult: null, // { rows, label, truncated, requestedLimit, actualLimit } -- the LAST successful response; NOT reset on tab re-entry (same posture as roster/theme -- switching away and back keeps showing the last result), only on mode switch or tablet:open
        auditRequestId: 0, // STALE-RESPONSE GUARD, same request-id shape as shopLocationsRequestId/runtimeFeaturesRequestId above -- a user can switch mode or press Run Query again while an earlier query is still in flight

        lastSettingsScreen: null, // the Server Settings section last open -- the tab returns to it

        pendingAction: false, // true while ANY mutation/trigger fetch is in flight -- disables action buttons to prevent double-submit. Reset on every handleOpen() too (this pass) -- see that function's own comment on this exact field for why a stale true here must never survive a close/reopen
        actionNotice: null, // { kind: 'ok'|'error', text: string } -- transient, cleared on next navigation/reload
    };

    var searchDebounceTimer = null;

    // ------------------------------------------------------------------
    // DOM REFS
    // ------------------------------------------------------------------
    var rootEl = null;

    // ------------------------------------------------------------------
    // NETWORKING
    // ------------------------------------------------------------------

    /**
     * Resolves this resource's name for building an NUI callback URL.
     * Primary path mirrors html/app.js's own GetParentResourceName() use.
     * SECONDARY path (window.parent.GetParentResourceName()) is a defensive
     * fallback ONLY -- this page's own primary assumption, stated plainly
     * rather than silently relied on, is that CitizenFX exposes
     * GetParentResourceName() to every frame of this resource's NUI
     * browser (top document AND iframes alike), not only the top one; this
     * is reasonable and community-precedented (iframe-based multi-page NUI
     * is a known pattern) but was NOT independently verified in-engine
     * this pass. If that assumption ever turns out wrong, the fallback
     * below (same-origin access to the parent window, which this page's
     * whole iframe design already depends on for html/tablet-bridge.js's
     * relay to work at all) covers it.
     * @returns {string}
     */
    function resolveResourceName() {
        try {
            if (typeof GetParentResourceName === 'function') return GetParentResourceName();
        } catch (err) {
            // fall through
        }
        try {
            if (window.parent && typeof window.parent.GetParentResourceName === 'function') {
                return window.parent.GetParentResourceName();
            }
        } catch (err) {
            // cross-origin or otherwise inaccessible -- fall through
        }
        // Last-resort dev-preview literal -- NOT a production fallback path,
        // mirrors app.js's own "opened directly in a plain browser" posture,
        // just made non-throwing here (a hardcoded resource name lets the
        // fetch attempt happen and fail gracefully through fetchNui()'s own
        // error handling below, rather than throwing synchronously).
        return 'qbx_k9unit';
    }

    /**
     * Fetches one NUI callback. NEVER rejects -- always resolves with
     * either the parsed JSON body, or a synthesized `{ ok: false, error }`
     * on timeout/network failure/malformed response, so every caller below
     * can treat this uniformly and this page can always show a clear
     * failure state rather than hang indefinitely (per this file's header
     * "never leave the player looking at an empty tablet" requirement).
     * @param {string} name
     * @param {object} [payload]
     * @returns {Promise<object>}
     */
    function fetchNui(name, payload) {
        return new Promise(function (resolve) {
            var settled = false;
            var timer = setTimeout(function () {
                if (settled) return;
                settled = true;
                resolve({ ok: false, error: 'timeout' });
            }, NUI_TIMEOUT_MS);

            function finish(result) {
                if (settled) return;
                settled = true;
                clearTimeout(timer);
                resolve(result);
            }

            try {
                fetch('https://' + resolveResourceName() + '/' + name, {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json; charset=UTF-8' },
                    body: JSON.stringify(payload || {}),
                }).then(function (resp) {
                    return resp.json().catch(function () { return {}; });
                }).then(function (json) {
                    finish(json && typeof json === 'object' ? json : {});
                }).catch(function () {
                    finish({ ok: false, error: 'network_error' });
                });
            } catch (err) {
                finish({ ok: false, error: 'exception' });
            }
        });
    }

    /** Fire-and-forget variant for messages this page never waits on
     * (tablet:ready, tablet:close) -- same underlying fetch, response
     * ignored entirely, swallows any construction-time throw. */
    function fireAndForget(name, payload) {
        try {
            fetch('https://' + resolveResourceName() + '/' + name, {
                method: 'POST',
                headers: { 'Content-Type': 'application/json; charset=UTF-8' },
                body: JSON.stringify(payload || {}),
            }).catch(function () {});
        } catch (err) {
            // Swallowed -- see resolveResourceName()'s own dev-preview note.
        }
    }

    // ------------------------------------------------------------------
    // STRING / LABEL HELPERS
    // ------------------------------------------------------------------

    /** @param {string} key @returns {string} */
    function S(key) {
        if (state.strings && typeof state.strings[key] === 'string' && state.strings[key].length > 0) {
            return state.strings[key];
        }
        return DEFAULT_STRINGS[key] || key;
    }

    /** @param {string} key @returns {{label:string,description:string}} */
    function capabilityInfo(key) {
        var fromServer = state.capabilities && state.capabilities[key];
        if (fromServer && typeof fromServer.label === 'string' && fromServer.label.length > 0) return fromServer;
        return DEFAULT_CAPABILITIES[key] || { label: key, description: '' };
    }

    /** Turns 'BiteAndHold' into 'Bite And Hold' -- last-resort label for a
     * feature key the server didn't (yet) send a human `label` for, so
     * this page never renders a blank cell. Not a substitute for real,
     * non-technical-officer-facing copy -- see this file's header/this
     * pass's hand-off note for that ask.
     * @param {string} key @returns {string} */
    function humanizeFeatureKey(key) {
        if (typeof key !== 'string' || key.length === 0) return '';
        return key
            .replace(/([a-z0-9])([A-Z])/g, '$1 $2')
            .replace(/([A-Z]+)([A-Z][a-z])/g, '$1 $2')
            .trim();
    }

    /** @param {{key:string,label?:string}} feature @returns {string} */
    function featureLabel(feature) {
        if (feature && typeof feature.label === 'string' && feature.label.length > 0) return feature.label;
        return humanizeFeatureKey(feature ? feature.key : '') || (feature ? String(feature.key) : '');
    }

    /**
     * Human label for a certification tier KEY -- resolved against the
     * LIVE tier catalog (state.certTiers, populated by loadCertTiers(),
     * server/certtiers.lua's own tablet:certTiersList) whenever it has
     * been loaded, falling back to the raw key otherwise -- NEVER a
     * hardcoded trainee/certified/senior map (server/certtiers.lua's own
     * header: an operator can add/rename tiers at runtime, and this page
     * must reflect that with no UI change). state.certTiers can be null
     * (never loaded, or the caller lacks the console-management access
     * tablet:certTiersList requires) -- the raw key fallback keeps this
     * always safe to call.
     * @param {any} tierKey @returns {string} */
    function tierDisplayLabel(tierKey) {
        if (typeof tierKey !== 'string' || tierKey.length === 0) return String(tierKey);
        var tiers = state.certTiers;
        if (Array.isArray(tiers)) {
            for (var i = 0; i < tiers.length; i++) {
                var tier = tiers[i];
                if (tier && tier.key === tierKey) {
                    return (typeof tier.label === 'string' && tier.label.length > 0) ? tier.label : tierKey;
                }
            }
        }
        return tierKey;
    }

    /**
     * Human label for a specialization KEY -- resolved against
     * state.specializations (Config.K9Specializations, sent verbatim in
     * tablet:open's payload -- see client/tablet.lua's own header) whenever
     * that entry carries a `.label`, falling back to the raw key
     * otherwise. NEVER a hardcoded narcotics/explosives/patrol map -- an
     * operator-added specialization key must render correctly with no UI
     * change.
     * @param {any} key @returns {string} */
    /** Replaces the role list with the server's live one (roles high
     * command created included). Ignores anything that is not an array. */
    function applyRoleCatalog(list) {
        if (!Array.isArray(list)) return;
        var map = {};
        for (var i = 0; i < list.length; i++) {
            var r = list[i];
            if (!r || typeof r.key !== 'string') continue;
            map[r.key] = { label: typeof r.label === 'string' ? r.label : r.key, xpRequired: typeof r.xpRequired === 'number' ? r.xpRequired : 0, unlocks: Array.isArray(r.unlocks) ? r.unlocks : [] };
        }
        state.specializations = map;
    }

    /** @param {string} key @returns {number} the XP a role needs (0 if unknown) */
    function roleXpRequired(key) {
        var def = state.specializations && state.specializations[key];
        return (def && typeof def.xpRequired === 'number') ? def.xpRequired : 0;
    }

    function specializationDisplayLabel(key) {
        var catalog = state.specializations;
        if (catalog && typeof catalog === 'object' && catalog[key] && typeof catalog[key].label === 'string' && catalog[key].label.length > 0) {
            return catalog[key].label;
        }
        return String(key);
    }

    /** @param {string} state key @returns {string} localized state badge text */
    function featureStateLabel(s) {
        switch (s) {
            case 'global_off': return S('state_global_off');
            case 'blocked': return S('state_blocked');
            case 'not_certified': return S('state_not_certified');
            case 'requires_grant_missing': return S('state_requires_grant_missing');
            case 'available': return S('state_available');
            default: return S('not_available_short');
        }
    }

    /**
     * The two 'client_enforced' badge/hint strings -- FOLDED into the
     * ordinary DEFAULT_STRINGS/S() mechanism now that the locked key count
     * that used to block this (tests/tabletlocalization_spec.lua hardcoded
     * an EXACT key count) is gone -- see that spec's own "WHY THERE IS NO
     * HARDCODED KEY COUNT ANY MORE". Previously sent as two STANDALONE
     * `tablet:open` fields (`blockClientEnforcedBadge`/`blockClientEnforcedHint`)
     * with their own hand-rolled fallback pair; client/tablet.lua now sends
     * both through the ordinary `strings` payload like every other key, so
     * these two functions are plain S() calls like any other label lookup.
     * @returns {string}
     */
    function clientEnforcedBadgeText() {
        return S('block_client_enforced_badge');
    }

    /** @returns {string} */
    function clientEnforcedHintText() {
        return S('block_client_enforced_hint');
    }

    /**
     * Normalizes `feature.blockEnforcement` (server-reported, see this
     * file's own PersonFeaturesResult doc comment for the four real
     * values and why 'not_yet_enforced' is the safe fallback) -- NEVER
     * derived from `feature.key` here. This page has no hardcoded list of
     * which features honour a block and never will: the whole point of
     * this field is that the server is the only place that answer can
     * come from without rotting the moment another feature gets wired
     * (see server/runtimecontrol.lua's own FEATURE_TIERS for the identical
     * reasoning applied to a different question). An unrecognized or
     * absent value collapses to 'not_yet_enforced', the same direction
     * server/runtimecontrol.lua's own 'unaudited' tier fails closed in --
     * this page must never claim a block works (fully OR client-side-only)
     * when it does not know.
     * @param {{blockEnforcement?: string}} feature
     * @returns {'enforced'|'client_enforced'|'not_enforceable'|'not_yet_enforced'}
     */
    function featureBlockEnforcement(feature) {
        var v = feature && feature.blockEnforcement;
        if (v === 'enforced' || v === 'client_enforced' || v === 'not_enforceable') return v;
        return 'not_yet_enforced';
    }

    /** @param {'enforced'|'client_enforced'|'not_enforceable'|'not_yet_enforced'} enforcement @returns {string} */
    function blockEnforcementBadgeLabel(enforcement) {
        if (enforcement === 'enforced') return S('block_enforced_badge');
        if (enforcement === 'client_enforced') return clientEnforcedBadgeText();
        return S('block_not_yet_enforced_badge');
    }

    /**
     * Hint tooltip for the Block Effect badge -- 'not_yet_enforced' AND
     * 'client_enforced' both carry one (the two states where the operator
     * genuinely needs the extra sentence: "not wired up yet" vs. "works,
     * but only against an unmodified client"); 'enforced' needs no
     * qualifier and 'not_enforceable' shows its own separate note instead
     * of a badge at all (see buildPersonFeatureRow below).
     * @param {'enforced'|'client_enforced'|'not_enforceable'|'not_yet_enforced'} enforcement
     * @returns {string|undefined}
     */
    function blockEnforcementBadgeTitle(enforcement) {
        if (enforcement === 'not_yet_enforced') return S('block_not_yet_enforced_hint');
        if (enforcement === 'client_enforced') return clientEnforcedHintText();
        return undefined;
    }

    // ------------------------------------------------------------------
    // DOM BUILD HELPERS -- every string value below is assigned via
    // `.textContent`, NEVER `.innerHTML` (this page never writes innerHTML
    // anywhere -- see html/tests/tablet_xss_spec.js, which proves this the
    // same way html/tests/xss_spec.js proves it for html/app.js).
    // ------------------------------------------------------------------

    function clearChildren(node) {
        while (node.firstChild) node.removeChild(node.firstChild);
    }

    /**
     * @param {string} tag
     * @param {{class?:string, text?:string, attrs?:Record<string,string>, title?:string}} [opts]
     * @returns {HTMLElement}
     */
    function mk(tag, opts) {
        opts = opts || {};
        var node = document.createElement(tag);
        if (opts.class) node.className = opts.class;
        if (typeof opts.text === 'string' || typeof opts.text === 'number') node.textContent = String(opts.text);
        if (opts.title) node.setAttribute('title', opts.title);
        if (opts.attrs) {
            for (var k in opts.attrs) {
                if (Object.prototype.hasOwnProperty.call(opts.attrs, k)) node.setAttribute(k, opts.attrs[k]);
            }
        }
        return node;
    }

    /**
     * @param {string} text
     * @param {string} cls
     * @param {() => void} onClick
     * @param {{disabled?:boolean,title?:string}} [opts]
     */
    function mkButton(text, cls, onClick, opts) {
        opts = opts || {};
        var btn = mk('button', { class: cls, text: text, title: opts.title });
        btn.setAttribute('type', 'button');
        if (opts.disabled) btn.setAttribute('disabled', 'disabled');
        btn.addEventListener('click', function (e) {
            if (e && typeof e.preventDefault === 'function') e.preventDefault();
            if (btn.getAttribute('disabled')) return;
            onClick();
        });
        return btn;
    }

    /**
     * A two-click confirm button for destructive actions (Decertify,
     * Revoke, Block/Unblock) -- see CONFIRM_WINDOW_MS's own comment for why
     * this exists instead of window.confirm(). First click swaps the label
     * to S('confirm_label') and arms a revert timer; a second click within
     * the window calls onConfirm(); anything else (timeout, or the whole
     * screen re-rendering for an unrelated reason) simply discards the
     * armed state, since render() rebuilds this element from scratch.
     * @param {string} label
     * @param {string} cls
     * @param {() => void} onConfirm
     * @param {{disabled?:boolean,title?:string}} [opts]
     */
    function mkConfirmButton(label, cls, onConfirm, opts) {
        var armed = false;
        var revertTimer = null;
        var btn = mkButton(label, cls, function () {
            if (!armed) {
                armed = true;
                btn.textContent = S('confirm_label');
                // VISUALLY distinct armed state, not just the label swap
                // above -- a same-size/same-colour text change is easy to
                // miss at a glance (exactly the "does the intermediate
                // state look clearly different" gap this class closes),
                // and matters MORE for a keyboard user: Enter/Space on a
                // focused button fires natively with no mouse hover cue at
                // all, so the button's own resting vs. armed appearance is
                // the only signal that a SECOND press is now required.
                // Applied as an ADDITIONAL class (never replaces `cls`) so
                // this reads correctly whether the base button is plain
                // (`k9tablet-btn`) or already `k9tablet-btn--danger` --
                // see tablet.css's own `.k9tablet-btn--armed` rule, which
                // wins the cascade over `--danger`'s background either way.
                btn.classList.add('k9tablet-btn--armed');
                revertTimer = setTimeout(function () {
                    armed = false;
                    btn.textContent = label;
                    btn.classList.remove('k9tablet-btn--armed');
                }, CONFIRM_WINDOW_MS);
                return;
            }
            clearTimeout(revertTimer);
            onConfirm();
        }, opts);
        return btn;
    }

    /**
     * Gate for the Audit Trail tab/screen -- a CONVENIENCE ONLY, per THE
     * SECURITY RULE, same as every other `if (canX(...))` on this page.
     * Deliberately NOT `state.viewer.isHighCommand` alone, unlike the
     * Theme/Cert Tiers/Shop Locations/Runtime Control tabs: server/
     * tablet.lua's own MeetsDepartmentRank(source, 'auditGrade') /
     * ResolveEffectivePermissions already resolve 'k9.audit' into
     * viewer.effectivePermissions for EXACTLY the same job.isboss /
     * job.grade>=auditGrade / explicit-grant / high-command paths
     * server/admin.lua's own IsAuthorizedAdmin checks for its five
     * tabletAudit* callbacks (verified directly against both files'
     * source, not assumed) -- so a senior officer who qualifies by rank
     * but is NOT high command already sees this tab, the same way they
     * would see the Console tab for holding any other capability. The one
     * thing this does NOT reflect is server/admin.lua's own PER-PERSON
     * FEATURE CONTROL layer (an individual block/missing-grant on
     * 'feature.AdminAuditCommands') -- a viewer who passes this client-side
     * check but is blocked there simply gets `error: 'not_authorized'`
     * back on every query, rendered as a normal error state by this
     * screen, never a blank one.
     * @returns {boolean}
     */
    function canViewAudit() {
        return !!(state.viewer && (state.viewer.isHighCommand
            || (Array.isArray(state.viewer.effectivePermissions) && state.viewer.effectivePermissions.indexOf('k9.audit') !== -1)));
    }

    /**
     * Gate for the Command Console tab/screen (roster + person lookup) and
     * the Home "Open Command Console" card -- a CONVENIENCE ONLY, per THE
     * SECURITY RULE, same as canViewAudit() immediately above. Mirrors
     * server/tablet.lua's own CallerHasConsoleAccess() EXACTLY: high
     * command, or an effectivePermissions entry of 'k9.audit' specifically
     * -- NOT "any non-empty effectivePermissions", which is what all three
     * of this gate's call sites checked before this pass (a bare
     * 'k9.access' resolves true for every ordinary certified handler, so
     * every certified handler saw this tab/card, clicked it, and got
     * refused server-side -- exactly the "button exists, does something
     * else" trap this file's own consistency rules forbid; see
     * CallerHasConsoleAccess's own doc comment, dated 2026-08-25, for the
     * full narrowing rationale). Body is IDENTICAL to canViewAudit()
     * because CallerHasConsoleAccess deliberately reuses the same
     * 'k9.audit' capability as its own admission rule ("kept alongside
     * high command deliberately... granted BY high command, to one named
     * person, for exactly this purpose") -- calling straight through
     * rather than re-deriving a fourth independent copy of the same
     * two-line boolean across this file's three call sites.
     * @returns {boolean}
     */
    function canAccessConsole() {
        return canViewAudit();
    }

    /**
     * Gate for the AUDIT tab/screen specifically -- the audit CAPABILITY
     * plus the audit FEATURE actually being on.
     *
     * DELIBERATELY NOT FOLDED INTO canViewAudit() ABOVE, unlike the four
     * delegated gates further down which do fold their own surface check
     * in. canAccessConsole() returns canViewAudit() verbatim (see its own
     * doc comment for why the two deliberately share one body), so folding
     * `surfaceEnabled('audit')` into canViewAudit would also take the
     * Command Console away from every viewer the moment
     * Config.Features.AdminAuditCommands went off -- two unrelated screens,
     * one flag, which is exactly the conflation this pass exists to undo.
     *
     * This tab needed the check MORE than the other four, not less:
     * server/admin.lua registers its tabletAudit* callbacks INSIDE its own
     * `Config.Features.AdminAuditCommands` guard, so with that flag off the
     * callbacks do not exist at all. The tab did not fail with a message --
     * it hung until the callback timed out.
     * @returns {boolean}
     */
    function canOpenAuditScreen() {
        return canViewAudit() && surfaceEnabled('audit');
    }

    /**
     * Gate for the NARROWED path a 'k9.certify'/'k9.givexp' holder gets
     * into the Console tab and the Person screen it leads to -- workflow
     * audit finding #1, 2026-08-26. Mirrors server/tablet.lua's own
     * CallerHasPersonAccess() EXACTLY (canAccessConsole() OR a held
     * 'k9.certify'/'k9.givexp' capability), which is the real enforcement
     * for tabletRequestPersonSummary specifically. Deliberately does NOT
     * widen canAccessConsole() itself, and tabletRequestRoster's own
     * server-side gate is UNCHANGED -- a viewer who qualifies here but not
     * for canAccessConsole() still cannot browse or search the roster by
     * name/department, only open a citizenid they already know (see
     * buildConsoleScreen()'s own narrowed rendering for that case). Before
     * this pass, the two capabilities this exists for were real,
     * server-granted, and completely inert: buildPersonScreen() already
     * gates its own Certify/Give XP controls on exactly these two
     * capabilities, but neither of the screen's only two entry points (the
     * roster's "Manage" button, the "Open by exact citizen ID" box) was
     * ever reachable without canAccessConsole() -- so a delegated
     * certifier/XP-granter had a real permission and no way to use it.
     * Convenience only, per THE SECURITY RULE: CallerHasPersonAccess() is
     * the actual authorization.
     * @returns {boolean}
     */
    function canOpenPersonRecord() {
        return canAccessConsole() || hasDelegatedCapability('k9.certify') || hasDelegatedCapability('k9.givexp');
    }

    /**
     * Shared body for the four capability-delegation gates immediately
     * below (canManageTabletTheme/canManageShopLocations/canManageShopItems/
     * canManageRuntimeControl) -- SAME isHighCommand-OR-specific-capability
     * idiom as canViewAudit() above, just parameterized on which capability
     * key to check, since all four server-side gates share the identical
     * shape (coder-backend's audit, verified directly against source):
     *   server/runtimecontrol.lua CanManageTabletTheme(source):    IsHighCommand(source) OR HasPermission(citizenid, 'k9.tablettheme') == true          (tests/runtimecontrol_spec.lua:523)
     *   server/equipmentshop.lua  CanManageShopLocations(source):  IsHighCommand(source) OR HasPermission(citizenid, 'k9.equipmentshoplocations') == true (tests/equipmentshop_spec.lua:839)
     *   server/equipmentshop.lua  CanManageShopItems(source):      IsHighCommand(source) OR HasPermission(citizenid, 'k9.equipmentshopitems') == true     (tests/equipmentshopitems_spec.lua:616)
     *   server/runtimecontrol.lua CanManageRuntimeControl(source): IsHighCommand(source) OR HasPermission(citizenid, 'k9.runtimecontrol') == true          (tests/runtimecontrol_spec.lua:523)
     * These are ordinary custom permission-catalog keys (server/
     * permissionkeycatalog.lua) -- high command mints them via the
     * Permission Keys screen and grants them via GrantPermission exactly
     * like k9.certify/k9.audit, so ResolveEffectivePermissions already
     * unions a held one into state.viewer.effectivePermissions today (no
     * server change needed for this). None of these four capabilities has
     * a `/k9...` chat-command fallback (unlike a Config.FeatureControl.
     * RequireGrant entry) -- until this client-side gate matched the
     * server's, a delegated officer had literally no way to reach any of
     * these four screens at all: built, authorized server-side, and
     * unreachable. Convenience only, per THE SECURITY RULE, same as
     * canViewAudit(): every one of these four screens' own mutating
     * callbacks re-verifies its real gate server-side regardless of
     * whether this ever returns true.
     * @param {string} capability
     * @returns {boolean}
     */
    function hasDelegatedCapability(capability) {
        return !!(state.viewer && (state.viewer.isHighCommand
            || (Array.isArray(state.viewer.effectivePermissions) && state.viewer.effectivePermissions.indexOf(capability) !== -1)));
    }

    /**
     * Does this server actually HAVE the admin screen `key`, per its own
     * Config.Features flags? Reads `viewer.surfaces`, built server-side by
     * server/tablet.lua's BuildAvailableSurfaces() -- read that function's
     * doc comment for the full writeup of the bug this closes (owner
     * directive: "ensure anything disabled in the config ... wont show up
     * in the tablet").
     *
     * A CAPABILITY AND A SURFACE ARE DIFFERENT QUESTIONS, and every admin
     * tab used to ask only the first. "You hold k9.tablettheme" says you
     * are ALLOWED to re-theme; it says nothing about whether
     * Config.Features.TabletTheming is on. With it off you still got the
     * tab, could open it, could edit every field -- and every save came
     * back refused by a server-side flag check this client never mirrored.
     * Both questions now have to answer yes.
     *
     * FAILS OPEN, DELIBERATELY: an absent key, and an absent `surfaces`
     * object entirely, both read as available. An older server, or a
     * payload that lost this field, must keep every tab it has always had
     * rather than silently shedding admin screens -- hiding is only ever
     * the result of an explicit `false` arriving from the server. This is
     * safe precisely because it is a convenience gate and not a security
     * one, per THE SECURITY RULE: every screen behind it re-verifies its
     * real gate server-side regardless of whether the tab was ever shown.
     * @param {string} key
     * @returns {boolean}
     */
    function surfaceEnabled(key) {
        var surfaces = state.viewer && state.viewer.surfaces;
        if (!surfaces || typeof surfaces !== 'object') return true;
        return surfaces[key] !== false;
    }

    /** Gate for the Theme tab/screen -- mirrors server/runtimecontrol.lua's
     * CanManageTabletTheme. See hasDelegatedCapability()'s own doc comment
     * for the full verified server-side contract this matches.
     * @returns {boolean} */
    function canManageTabletTheme() {
        return hasDelegatedCapability('k9.tablettheme') && surfaceEnabled('theme');
    }

    /** Gate for the Shop Locations tab/screen -- mirrors server/
     * equipmentshop.lua's CanManageShopLocations. See
     * hasDelegatedCapability()'s own doc comment for the full verified
     * server-side contract this matches.
     * @returns {boolean} */
    function canManageShopLocations() {
        return hasDelegatedCapability('k9.equipmentshoplocations') && surfaceEnabled('shop_locations');
    }

    /** Gate for the Shop Items tab/screen -- mirrors server/
     * equipmentshop.lua's CanManageShopItems. See hasDelegatedCapability()'s
     * own doc comment for the full verified server-side contract this
     * matches.
     * @returns {boolean} */
    function canManageShopItems() {
        return hasDelegatedCapability('k9.equipmentshopitems') && surfaceEnabled('shop_items');
    }

    /** Gate for the Runtime Control tab/screen -- mirrors server/
     * runtimecontrol.lua's CanManageRuntimeControl. See
     * hasDelegatedCapability()'s own doc comment for the full verified
     * server-side contract this matches.
     * @returns {boolean} */
    function canManageRuntimeControl() {
        return hasDelegatedCapability('k9.runtimecontrol') && surfaceEnabled('runtime_control');
    }

    // ------------------------------------------------------------------
    // FOCUS + SCROLL CONTINUITY ACROSS render()'s full teardown/rebuild
    // ------------------------------------------------------------------
    // render() below throws away and rebuilds EVERY DOM node under
    // rootEl on every single call (this file's own header: single source
    // of truth, no separate "static HTML vs dynamic JS" text to keep in
    // sync) -- which, unpatched, blurs whatever the operator had focused
    // on every one of those calls: removing the focused element from the
    // document, or (mkButton()'s own `disabled` attribute, set
    // synchronously in the SAME click handler that then calls render() to
    // prevent a double-submit) merely disabling it while it still has
    // focus, both force a real browser to blur it back to <body> with no
    // element focused at all. For a mouse user this is invisible; for a
    // keyboard-only operator it means every save/delete/tab-switch/
    // search-keystroke can silently eject them back to having nothing
    // focused, and typing a live-filter query one keystroke at a time
    // becomes "type one character, re-click the box, type one character,
    // re-click the box" (buildConsoleScreen()'s roster search,
    // buildCommandReferenceScreen()'s filter, and
    // buildPersonFeaturesSection()'s filter all call render() from their
    // own `input` handler for exactly this reason -- live filtering as
    // you type). The helpers below are wired into render() itself
    // (function-scoped just below it) so no individual screen builder
    // needs to know any of this exists -- see that function's own
    // comment for the priority order they are tried in.
    //
    // Everything here is PURELY STRUCTURAL (tag + className, walked
    // fresh every time) -- never an assumption that any specific DOM node
    // survives a render() call, because none ever does.

    var lastRenderedOpen = false;
    var lastRenderedScreen = null;

    /** Pre-order walk of every ELEMENT descendant of `root` (never `root`
     * itself), calling `visit(el)` for each. Plain `.children` recursion,
     * identical against a real browser Element and against
     * html/tests/tablet-dom-stub.js's own Element.
     * @param {Element} root @param {(el:Element) => void} visit */
    function walkElements(root, visit) {
        if (!root || !root.children) return;
        for (var i = 0; i < root.children.length; i++) {
            var child = root.children[i];
            visit(child);
            walkElements(child, visit);
        }
    }

    /** @param {Element} el @returns {string} a purely structural identity
     * ("tagname.className") -- NOT a claim that two elements sharing one
     * are "the same" node, only that they occupy the same structural role
     * (e.g. "input.k9tablet-search"), which is all captureFocusSnapshot()
     * needs for the single-instance-per-screen fields it targets (see its
     * own ordinal tie-break for the rare screen where more than one
     * element could ever share one). */
    function elementSignature(el) {
        return el.tagName + '.' + (el.className || '');
    }

    /** @param {Element} root @param {Element} target @returns {boolean}
     * true if `target` is `root` itself or anywhere in its subtree. */
    function isSameOrDescendant(root, target) {
        var n = target;
        while (n) {
            if (n === root) return true;
            n = n.parentNode;
        }
        return false;
    }

    /** @param {string} cls @returns {?Element} the first descendant of
     * rootEl carrying `cls` in its classList, or null. */
    function findFirstWithClass(cls) {
        var found = null;
        walkElements(rootEl, function (el) {
            if (found) return;
            if (el.classList && el.classList.contains(cls)) found = el;
        });
        return found;
    }

    /**
     * Snapshots the currently-focused element, IF ANY, and IF it is one
     * this page can meaningfully relocate after a full rebuild -- scoped
     * to `<input>`/`<textarea>` ONLY, deliberately never `<button>` (see
     * render()'s own "focusedTabBefore"/action-notice branches for why a
     * button's post-mutation focus is handled as a SEPARATE, more
     * specific case rather than through this generic signature match: too
     * many buttons on a typical screen share one class for a bare
     * tag+className+ordinal match to reliably land on the SAME logical
     * button again).
     * @returns {?{signature:string, ordinal:number, selectionStart:?number, selectionEnd:?number}}
     */
    function captureFocusSnapshot() {
        var active = document.activeElement;
        if (!active || !rootEl || !isSameOrDescendant(rootEl, active)) return null;
        var tag = String(active.tagName || '').toLowerCase();
        if (tag !== 'input' && tag !== 'textarea') return null;

        var signature = elementSignature(active);
        var ordinal = -1;
        var seen = 0;
        walkElements(rootEl, function (el) {
            if (elementSignature(el) !== signature) return;
            if (el === active) ordinal = seen;
            seen++;
        });
        if (ordinal === -1) return null;

        var snapshot = { signature: signature, ordinal: ordinal, selectionStart: null, selectionEnd: null };
        if (typeof active.selectionStart === 'number') snapshot.selectionStart = active.selectionStart;
        if (typeof active.selectionEnd === 'number') snapshot.selectionEnd = active.selectionEnd;
        return snapshot;
    }

    /** Counterpart to captureFocusSnapshot() -- re-finds the Nth
     * (`ordinal`) element sharing `signature` in the FRESHLY rebuilt tree
     * and refocuses it, restoring the text cursor/selection too so an
     * in-progress selection survives a live-filter re-render, not just
     * the caret. A signature that no longer exists this render (the
     * operator navigated away) is silently a no-op, same as every other
     * "state moved on, nothing left to restore" path on this page.
     * @param {?object} snapshot @returns {boolean} true if focus was restored */
    function restoreFocusSnapshot(snapshot) {
        if (!snapshot) return false;
        var matches = [];
        walkElements(rootEl, function (el) {
            if (elementSignature(el) === snapshot.signature) matches.push(el);
        });
        var target = matches[snapshot.ordinal];
        if (!target || typeof target.focus !== 'function') return false;
        target.focus();
        if (snapshot.selectionStart !== null && typeof target.setSelectionRange === 'function') {
            try { target.setSelectionRange(snapshot.selectionStart, snapshot.selectionEnd); } catch (e) { /* some input types (e.g. number) refuse a selection range -- harmless, the focus restore above already succeeded */ }
        }
        return true;
    }

    /** Snapshots `.k9tablet-screen`'s own scrollTop -- the ONE scrollable
     * region every buildXScreen() appends (tablet.css's `overflow-y:auto`
     * on that class) -- so a same-screen re-render (an edit settling, a
     * row being deleted, a live search re-filtering the list) does not
     * throw a long table back to the top. Never applied across an actual
     * screen change (see render()'s own `sameScreen` check) -- landing on
     * a genuinely different screen at ITS OWN top is correct, not a bug.
     * @returns {?number} */
    function captureScreenScrollTop() {
        var screenEl = findFirstWithClass('k9tablet-screen');
        return screenEl ? (screenEl.scrollTop || 0) : null;
    }

    /** @param {?number} scrollTop */
    function restoreScreenScrollTop(scrollTop) {
        if (scrollTop === null || scrollTop === undefined) return;
        var screenEl = findFirstWithClass('k9tablet-screen');
        if (screenEl) screenEl.scrollTop = scrollTop;
    }

    /** @param {Element} container @returns {Element[]} every ENABLED,
     * non-destructive `.k9tablet-btn` inside `container` -- excludes the
     * `--danger` palette class and the separate `.k9tablet-link-btn`
     * family entirely (never merely deprioritized): see
     * findEnterSubmitTarget()'s own header for why a destructive button
     * must never be a candidate here at all, regardless of how unambiguous
     * the match would otherwise be. */
    function collectSubmitCandidates(container) {
        var out = [];
        walkElements(container, function (el) {
            if (String(el.tagName).toLowerCase() !== 'button') return;
            if (!el.classList || !el.classList.contains('k9tablet-btn')) return;
            if (el.classList.contains('k9tablet-btn--danger')) return;
            if (el.getAttribute('disabled')) return;
            out.push(el);
        });
        return out;
    }

    /**
     * Finds the one, unambiguous "press Enter to do the obvious thing"
     * button for a text field the operator is currently typing in.
     * Every screen on this page builds its own toolbar/form with NO
     * `<form>` element and no submit handling at all -- most of it is
     * live-filtered as-you-type, not submitted -- so today Enter visibly
     * does nothing anywhere on this page, in a form field or otherwise;
     * this closes that gap wherever it is safe to.
     *
     * Walks OUTWARD from `input`'s own parent, one container at a time,
     * stopping and returning the single candidate the FIRST time a
     * container's subtree holds EXACTLY one qualifying button
     * (collectSubmitCandidates() above) -- e.g. the "Open by ID"/Give XP
     * toolbars (the button is a direct sibling: found at the very first,
     * narrowest container) or a cert-tier/permission-key/shop-location/
     * shop-item/xp-tier draft form (each field lives in its own row, with
     * the actual Save button two levels up in a shared `actions` div:
     * found once the walk reaches that shared ancestor).
     *
     * SAFETY: the walk stops and returns null (no auto-submit at all) the
     * MOMENT any container holds MORE than one candidate, and never
     * widens past that point -- e.g. buildPersonFeaturesSection()'s
     * search box sits directly alongside a whole list of per-row Grant/
     * Revoke buttons, so this deliberately never resolves there. A
     * capped number of hops guards against ever climbing out of the
     * currently open screen even if some future screen nests unusually
     * deep.
     * @param {Element} input @returns {?Element}
     */
    function findEnterSubmitTarget(input) {
        var node = input.parentNode;
        var hops = 6;
        while (node && hops-- > 0) {
            var candidates = collectSubmitCandidates(node);
            if (candidates.length === 1) return candidates[0];
            if (candidates.length > 1) return null;
            node = node.parentNode;
        }
        return null;
    }

    /** Enter-key handling for the panel's plain text/number inputs -- see
     * findEnterSubmitTarget()'s own header for the full rationale/safety
     * argument. A no-op for anything else focused (a `<select>`, a
     * `<textarea>`, a checkbox, or nothing at all). Called from the SAME
     * keydown listener attachEscapeHandling() below already owns, as a
     * separate branch, rather than a second document listener -- exactly
     * one place this page ever reads a raw keyboard event from. */
    function handleEnterKeydown() {
        var active = document.activeElement;
        if (!active || !rootEl || !isSameOrDescendant(rootEl, active)) return;
        var tag = String(active.tagName || '').toLowerCase();
        if (tag !== 'input') return;
        var type = (active.getAttribute('type') || 'text').toLowerCase();
        if (type !== 'text' && type !== 'number') return;

        var target = findEnterSubmitTarget(active);
        if (target) target.click();
    }

    // ------------------------------------------------------------------
    // RENDER
    // ------------------------------------------------------------------

    function render() {
        if (!rootEl) return;

        var wasOpen = lastRenderedOpen;
        var sameScreen = state.screen === lastRenderedScreen;

        // A stale success/error banner from whatever the operator last did
        // on a DIFFERENT screen has no business following them to a new
        // one -- see state.actionNotice's own doc comment ("transient,
        // cleared on next navigation/reload"), which this is the one,
        // centralized place that promise is actually kept for EVERY
        // navigation path (goToXScreen()/buildTabs()/openPerson()/Back all
        // funnel through a `state.screen = '...'; render();` pair, so
        // catching the transition HERE covers all of them without editing
        // each call site individually).
        if (!sameScreen) state.actionNotice = null;

        var activeBefore = document.activeElement;
        var focusedTabBefore = !!(activeBefore && isSameOrDescendant(rootEl, activeBefore)
            && activeBefore.classList && activeBefore.classList.contains('k9tablet-tab'));

        var scrollSnapshot = sameScreen ? captureScreenScrollTop() : null;
        var focusSnapshot = captureFocusSnapshot();
        var hasNotice = !!state.actionNotice;

        clearChildren(rootEl);
        lastRenderedScreen = state.screen;
        lastRenderedOpen = state.open;

        if (!state.open) return;

        rootEl.appendChild(buildBackdrop());

        restoreScreenScrollTop(scrollSnapshot);

        // Focus, in priority order -- see this section's own header above
        // for the full rationale. Every step is a no-op (never throws)
        // when its target does not exist this render, falling through to
        // the next; the LAST resort still never leaves focus lost to bare
        // document.body.
        if (!wasOpen) {
            // Freshly opened this render (tablet:open, or the very first
            // render after page load) -- the standard modal-dialog
            // pattern: move focus INTO the dialog the instant it appears,
            // never leave it wherever it happened to be (nowhere, for this
            // surface) beforehand. The panel itself (tabindex="-1", set in
            // buildBackdrop()) rather than one specific control inside it,
            // so this works identically whether a resolved viewer, the
            // loading state, or the error/retry gate is what actually
            // rendered.
            var openPanel = findFirstWithClass('k9tablet-panel');
            if (openPanel && typeof openPanel.focus === 'function') openPanel.focus();
        } else if (restoreFocusSnapshot(focusSnapshot)) {
            // Handled -- a live-filter text field kept its focus (and
            // cursor/selection) across this re-render.
        } else if (focusedTabBefore) {
            // The operator was on the tab bar itself. The OLD button is
            // gone (a fresh one is built every render, and selecting a tab
            // changes its OWN className to add k9tablet-tab--active,
            // which deliberately makes it a signature mismatch for
            // restoreFocusSnapshot() above), but the new one is trivially
            // findable and is exactly where a keyboard user expects focus
            // to still be after selecting a tab -- the standard ARIA tabs
            // behavior: focus follows selection.
            var activeTab = findFirstWithClass('k9tablet-tab--active');
            if (activeTab && typeof activeTab.focus === 'function') activeTab.focus();
        } else if (hasNotice) {
            // A mutation just started or settled on THIS SAME screen
            // (runMutation()'s own immediate "Working..." notice, then its
            // final result), very likely having just disabled/removed the
            // very control the operator activated -- mkButton()'s own
            // `disabled` attribute blurs its element the instant it is
            // set, natively, before render() even runs. Land on the
            // notice that just told them what happened (buildActionNotice()
            // gives it role="status"/aria-live, so this also gets
            // announced to a screen reader) rather than losing focus to
            // nothing. Deliberately NOT gated on the notice being "new"
            // this exact render -- onSettled()'s own follow-up reload
            // (loadMyRecord()/loadPersonSummary()/...) fires at least one
            // MORE render() after the notice text last changed, while it
            // is still the most recent, still-accurate thing on screen;
            // gating on freshness let that second, purely incidental
            // render silently steal focus back to the bare panel a moment
            // after this branch had already (correctly) placed it here.
            var noticeEl = findFirstWithClass('k9tablet-notice');
            if (noticeEl && typeof noticeEl.focus === 'function') noticeEl.focus();
        } else {
            // Nothing more specific applied (a Cancel button closing a
            // draft with no server round trip is the common case here) --
            // still never leave focus lost to bare document.body: the
            // dialog panel is always a safe, always-present landing spot a
            // keyboard user can immediately Tab onward from.
            var fallbackPanel = findFirstWithClass('k9tablet-panel');
            if (fallbackPanel && typeof fallbackPanel.focus === 'function') fallbackPanel.focus();
        }
    }

    function buildBackdrop() {
        var backdrop = mk('div', { class: 'k9tablet-backdrop' });
        // Density is COSMETIC ONLY (see server/runtimecontrol.lua's own PART
        // 2 header) -- applied here as a plain class on the panel this
        // render() rebuilds from scratch every time, never persisted on any
        // element across renders, exactly like every other piece of this
        // page's state.
        var density = (state.theme && state.theme.density) || DEFAULT_THEME.density;
        var panelClass = 'k9tablet-panel' + (density === 'compact' ? ' k9tablet-density-compact' : '');
        // tabindex="-1" -- programmatically focusable (never in the Tab
        // order itself) so render()'s own focus-management code always
        // has a safe, always-present landing spot to fall back to: see
        // that function's own header for why every one of its rebuilds
        // otherwise risks losing focus to bare document.body.
        var panel = mk('div', { class: panelClass, attrs: { role: 'dialog', 'aria-modal': 'true', tabindex: '-1' } });
        panel.appendChild(buildHeader());

        if (state.actionNotice) {
            panel.appendChild(buildActionNotice());
        }

        if (!state.viewer) {
            panel.appendChild(buildViewerGate());
            backdrop.appendChild(panel);
            return backdrop;
        }

        // canOpenPersonRecord() -- SAME rule server/tablet.lua's own
        // CallerHasPersonAccess() enforces (canAccessConsole() OR a held
        // 'k9.certify'/'k9.givexp' capability), NOT "any non-empty
        // effectivePermissions" (fixed this pass -- see canAccessConsole()'s
        // own doc comment for why the old, broader expression was a bug:
        // it let every ordinary certified handler see a Console tab/card
        // that the server would then refuse). Widened from canAccessConsole()
        // alone (workflow audit finding #1, 2026-08-26) so a
        // 'k9.certify'/'k9.givexp' holder who is not high command and does
        // not hold 'k9.audit' has SOME path to a person's record -- see
        // canOpenPersonRecord()'s own doc comment for the full writeup and
        // buildConsoleScreen()'s narrowed rendering for what that viewer
        // actually sees (never the full roster).
        // ALWAYS rendered now (this pass) -- previously gated on
        // canManageRoster, which meant a viewer with zero effective
        // permissions (in practice: someone certified nowhere at all, not
        // even the base 'k9.access' HasK9Access() resolves for almost
        // every certified handler/K9 -- see server/tablet.lua's
        // ResolveEffectivePermissions) saw NO navigation at all, not even
        // a way back to 'my_record'. buildTabs() itself now gates its own
        // Command Console entry on this SAME canOpenPersonRecord() gate
        // (see that function) so this widening never exposes a tab that
        // would silently dead-end into the wrong screen -- the Home tab
        // (and, for a resolved viewer, My Record) are the only two every
        // viewer is guaranteed to see.
        panel.appendChild(buildTabs());

        // Every Server Settings section shows the section picker above its
        // own screen -- only for a section this viewer may open (the branch
        // below re-checks the same gate, and falls back to Home otherwise).
        if (isSettingsScreen(state.screen) && settingsSectionAllowed(state.screen)) {
            panel.appendChild(buildSettingsSectionNav());
        }

        if (state.screen === 'home') {
            panel.appendChild(buildHomeScreen());
        } else if (state.screen === 'guide') {
            panel.appendChild(buildGuideScreen());
        } else if (state.screen === 'partnerships') {
            panel.appendChild(buildPartnershipsScreen());
        } else if (state.screen === 'console' && canOpenPersonRecord()) {
            panel.appendChild(buildConsoleScreen());
        } else if (state.screen === 'person' && canOpenPersonRecord()) {
            panel.appendChild(buildPersonScreen());
        } else if (state.screen === 'roster' && state.viewer.isHighCommand) {
            panel.appendChild(buildPersonnelRosterScreen());
        } else if (state.screen === 'theme' && canManageTabletTheme()) {
            panel.appendChild(buildThemeScreen());
        } else if (state.screen === 'catalogs' && state.viewer.isHighCommand) {
            panel.appendChild(buildCatalogsScreen());
        } else if (state.screen === 'shop' && (canManageShopLocations() || canManageShopItems())) {
            panel.appendChild(buildShopScreen());
        } else if (state.screen === 'runtime_control' && canManageRuntimeControl()) {
            panel.appendChild(buildRuntimeControlScreen());
        } else if (state.screen === 'settings_overview' && settingsSectionAllowed('settings_overview')) {
            panel.appendChild(buildSettingsOverviewScreen());
        } else if (state.screen === 'audit' && canOpenAuditScreen()) {
            panel.appendChild(buildAuditScreen());
        } else {
            // buildHomeScreen is the FALLBACK, deliberately -- an
            // unrecognised or no-longer-permitted screen name lands on the
            // viewer's own record rather than a blank panel. Every new
            // branch must therefore be added ABOVE this one; putting it
            // below is unreachable code that silently never renders.
            panel.appendChild(buildHomeScreen());
        }

        backdrop.appendChild(panel);
        return backdrop;
    }

    function buildHeader() {
        var header = mk('div', { class: 'k9tablet-header' });

        var left = mk('div', { class: 'k9tablet-header-left' });
        left.appendChild(buildBrandingElement());
        var titleText = (state.theme && typeof state.theme.headerTitle === 'string' && state.theme.headerTitle.length > 0)
            ? state.theme.headerTitle : S('title');
        left.appendChild(mk('h1', { class: 'k9tablet-title', text: titleText }));
        header.appendChild(left);

        header.appendChild(mkButton('×', 'k9tablet-close-btn', requestClose, { title: S('close_label') }));
        return header;
    }

    /**
     * Server logo + name (Config.CommandTablet.branding, owner-supplied)
     * -- MUST DEGRADE TO TEXT: a missing/failed-to-load image shows
     * `serverName` alone, NEVER a broken-image icon, since the operator
     * hand-swaps html/images/logo.png and may typo/omit it (config.lua's
     * own comment: "It never shows a broken image"). The `error` listener
     * below is the ONLY place this file ever mutates an already-built
     * element's style directly rather than going through state+render() --
     * a deliberate, narrow exception: an <img> load failure is an
     * asynchronous BROWSER event with no corresponding state change this
     * page's own render() cycle would ever naturally re-run for, and the
     * fix (hide the broken image, reveal the plain-text fallback that is
     * ALREADY in the DOM right beside it) is a pure, local, one-way,
     * idempotent visibility flip -- see html/tests/tablet-dom-stub.js's
     * Element.style (`{}`, a plain settable object) for how this stays
     * fully testable without a real image-loading engine: a test can
     * dispatch the SAME 'error' event this real img element would.
     * `serverName`/`logo` are OPERATOR-SUPPLIED, DOM-bound strings --
     * rendered via mk()'s own textContent-only path / an `alt` attribute
     * only, never innerHTML, matching html/tests/tablet_xss_spec.js's own
     * coverage of this exact element.
     */
    function buildBrandingElement() {
        var branding = state.branding || {};
        var serverName = (typeof branding.serverName === 'string' && branding.serverName.length > 0) ? branding.serverName : '';
        var logoPath = (typeof branding.logo === 'string' && branding.logo.length > 0) ? branding.logo : '';

        var wrap = mk('div', { class: 'k9tablet-branding' });
        if (serverName.length === 0 && logoPath.length === 0) return wrap;

        var fallbackText = mk('span', { class: 'k9tablet-branding-name', text: serverName });

        if (logoPath.length > 0) {
            var img = mk('img', { class: 'k9tablet-branding-logo', attrs: { src: logoPath, alt: serverName } });
            // Hidden unless/until the image actually fails -- showing both
            // at once would duplicate the server name for no reason in the
            // ordinary (image loads fine) case.
            fallbackText.style.display = 'none';
            img.addEventListener('error', function () {
                img.style.display = 'none';
                fallbackText.style.display = '';
            });
            wrap.appendChild(img);
        }
        wrap.appendChild(fallbackText);
        return wrap;
    }

    /**
     * Larger, one-off branding badge for the screen a player sees before
     * anything else -- buildViewerGate() below, which covers BOTH the
     * initial loading state (requestMyRecord in flight) and the error/
     * retry state, i.e. the tablet's actual "landing" moment. Deliberately
     * the ONLY other place a logo appears besides the small header mark
     * (buildBrandingElement(), shown in buildHeader() on every single
     * screen already, which is why this is not ALSO repeated on e.g. the
     * My Record tab or as a per-screen title decoration -- a busy, high-
     * contrast crest shown six times on one panel reads worse than once,
     * placed well).
     *
     * Same missing/broken-logo-degrades-to-text discipline as
     * buildBrandingElement() immediately above -- see that function's own
     * doc comment for why the `error` listener is the one place this file
     * mutates an already-built element's style directly instead of going
     * through state+render(). `serverName`/`logo` are OPERATOR-SUPPLIED,
     * DOM-bound strings here too -- textContent / an `attrs.src`+`attrs.alt`
     * pair only, never innerHTML, same as the header mark.
     */
    function buildBrandingMark() {
        var branding = state.branding || {};
        var serverName = (typeof branding.serverName === 'string' && branding.serverName.length > 0) ? branding.serverName : '';
        var logoPath = (typeof branding.logo === 'string' && branding.logo.length > 0) ? branding.logo : '';

        var wrap = mk('div', { class: 'k9tablet-branding-mark' });
        if (serverName.length === 0 && logoPath.length === 0) return wrap;

        var fallbackText = mk('span', { class: 'k9tablet-branding-mark-name', text: serverName });

        if (logoPath.length > 0) {
            var frame = mk('div', { class: 'k9tablet-branding-mark-frame' });
            var img = mk('img', { class: 'k9tablet-branding-mark-logo', attrs: { src: logoPath, alt: serverName } });
            // Same hidden-until-error handshake as buildBrandingElement():
            // the frame (border/background box) hides along with the image
            // it exists to frame, never left behind as an empty outline.
            fallbackText.style.display = 'none';
            img.addEventListener('error', function () {
                frame.style.display = 'none';
                fallbackText.style.display = '';
            });
            frame.appendChild(img);
            wrap.appendChild(frame);
        }
        wrap.appendChild(fallbackText);
        return wrap;
    }

    function buildActionNotice() {
        var isError = state.actionNotice.kind === 'error';
        // role/aria-live announce this to a screen reader the instant it
        // appears, and tabindex="-1" makes it a valid render()-time focus
        // target (see that function's own "noticeIsFresh" branch) -- a
        // keyboard user whose Save/Delete/Grant button was just disabled
        // out from under them (mkButton()'s own double-submit guard blurs
        // it natively) lands HERE, on the very message telling them what
        // happened, instead of losing focus to nothing.
        var notice = mk('div', {
            class: 'k9tablet-notice k9tablet-notice--' + (isError ? 'error' : 'ok'),
            text: state.actionNotice.text,
            attrs: { role: isError ? 'alert' : 'status', 'aria-live': isError ? 'assertive' : 'polite', tabindex: '-1' },
        });
        return notice;
    }

    function buildViewerGate() {
        var wrap = mk('div', { class: 'k9tablet-status-block' });
        wrap.appendChild(buildBrandingMark());
        if (state.myRecordLoading) {
            wrap.appendChild(mk('p', { text: S('loading') }));
        } else if (state.myRecordError) {
            wrap.appendChild(mk('p', { class: 'k9tablet-error-text', text: errorText(state.myRecordError) }));
            wrap.appendChild(mkButton(S('retry_label'), 'k9tablet-btn', loadMyRecord));
        } else {
            wrap.appendChild(mk('p', { text: S('loading') }));
        }
        return wrap;
    }

    function errorText(err) {
        if (!err) return S('error_generic');
        if (typeof err.message === 'string' && err.message.length > 0) return err.message;
        switch (err.error) {
            case 'not_authorized': return S('error_not_authorized');
            case 'timeout': return S('error_timeout');
            case 'network_error': return S('error_network');
            default: return S('error_generic');
        }
    }

    function buildTabs() {
        var tabs = mk('div', { class: 'k9tablet-tabs' });

        // ONE NAVIGATION STRUCTURE, NOT TWO (this pass) -- see
        // html/tablet.css's own ".k9tablet-tab-group--admin" comment for
        // the full reasoning. Every High Command/delegated screen below
        // (Flows, Theme, Cert Tiers, Permission Keys, Shop Locations, Shop
        // Items, Runtime Control, XP Tiers, K9 Profiles, Audit -- NOT
        // Command Console, which stays alongside the five universal tabs
        // as an ordinary, non-administrative capability) is appended into
        // this ONE shared group instead of straight onto the flat tab bar,
        // so the tab row itself visually reads as "your tabs, then a
        // clearly separate High Command group" rather than an
        // undifferentiated wall of up to sixteen buttons. Built LAZILY --
        // never appended at all for a viewer who qualifies for none of
        // these -- and every individual tab inside keeps its EXACT same
        // label/click behaviour as before; only WHERE it is appended
        // changed, never what it does or how it is reached.
        var adminTabGroup = null;
        function appendAdminTab(button) {
            if (!adminTabGroup) {
                adminTabGroup = mk('div', {
                    class: 'k9tablet-tab-group k9tablet-tab-group--admin',
                    attrs: { role: 'group', 'aria-label': S('home_high_command_heading') },
                });
                tabs.appendChild(adminTabGroup);
            }
            adminTabGroup.appendChild(button);
        }

        // HOME -- the new landing view (owner-directed "restructure the
        // tablet around WHO IS HOLDING IT... a first-time player who has
        // read nothing should open this and know what to do within
        // seconds", see buildHomeScreen()). Always first, and, unlike
        // every tab below, ALWAYS shown regardless of canManageRoster --
        // buildBackdrop() now renders this whole tab bar unconditionally
        // for every resolved viewer, and Home is the one screen every
        // single one of them, including a brand-new uncertified arrival,
        // can always usefully land on.
        // STALE-STATE FIX (this pass): every OTHER data-driven tab below
        // (My Record, Console, Theme, Cert Tiers, ...) re-fetches its own
        // data on every click, specifically so navigating away and back
        // never shows a stale copy -- Home used to be the one exception,
        // switching screens with no reload at all, even though it renders
        // the SAME state.myRecord/state.viewer this same tab bar's own My
        // Record tab reloads on every click. A high-command viewer who
        // certifies/renews/grants XP to THEIR OWN citizenid from the Person
        // screen (a real, config-permitted self-action -- see
        // refreshPersonAndSelf()'s own doc comment below), then returns
        // here without ever visiting My Record directly, used to keep
        // seeing the identity card/XP/ready-abilities exactly as they were
        // at tablet:open. Now consistent with every other tab.
        // MY RECORD -- the landing view, and the ONLY screen for your own
        // record (plan item A). It was three tabs -- Home, My Record and
        // Progression -- and they were three views of four things: who you
        // are, your certifications, your XP, your abilities. Progression
        // shared two builders with My Record outright, and Home's "ready
        // abilities" was My Record's own list filtered to the usable ones.
        //
        // The screen id stays 'home' because it is still the landing view,
        // reset to on every open (handleOpen()) and the fallback for an
        // unrecognised screen name. What changed is that it now carries the
        // whole record instead of a preview of it.
        //
        // WHAT MUST NOT BE LOST IN THE MERGE, and is not: the "what do I do
        // next" card stays at the TOP. It is the reason Home existed and
        // the first thing a brand-new, uncertified player sees; burying it
        // under a wall of records would trade one problem for another.
        var myTab = mkButton(S('tab_my_record'), 'k9tablet-tab' + (state.screen === 'home' ? ' k9tablet-tab--active' : ''), function () {
            // Calls goToMyRecordScreen() rather than repeating its body --
            // the same way the Guide, Console and Partnerships tabs below
            // call theirs. This tab inlined the three lines while the
            // helper had other callers: the "View My Record" quick-action
            // cards. The Home/My Record/Progression merge deleted those
            // cards (they pointed at the screen they sat on), which left
            // the helper with no caller at all and the duplication with
            // nothing left to justify it.
            goToMyRecordScreen();
        });
        tabs.appendChild(myTab);

        // PARTNERSHIPS -- owner, verbatim: "a partnership tab should be
        // shown on all tablets as a tab... high command is a handler or a
        // k9 and should have control over it also but the partnership tab
        // should show whos there partners." ALWAYS shown, same as Home/My
        // Record/Commands -- UNCONDITIONAL, deliberately NOT gated on
        // canManageRoster/isHighCommand the way Console below is: high
        // command sees THIS SAME tab (their own partnerships, exactly like
        // anyone else), plus an extra admin lookup section rendered ON TOP
        // of that same screen body (buildPartnershipsScreen()'s own header
        // comment) -- never a second, separate high-command-only screen.
        var partnershipsTab = mkButton(S('tab_partnerships'), 'k9tablet-tab' + (state.screen === 'partnerships' ? ' k9tablet-tab--active' : ''), function () {
            goToPartnershipsScreen();
        });
        tabs.appendChild(partnershipsTab);

        // GUIDE -- ONE tab, the teaching guide and the command reference
        // together (plan item H). They were two tabs holding 265 strings
        // between them, over a quarter of everything this tablet can say,
        // and they answered the same question at two zoom levels: Help
        // explained tasks in prose, Commands listed every command with what
        // it does, what it needs, and whether you can use it right now.
        //
        // Help even rendered its OWN second copy of the command catalog
        // (deleted with this change) -- the same
        // COMMAND_REFERENCE entries in a different table, without the
        // filter or the live status badge. One tab, one table.
        //
        // ALWAYS SHOWN, unchanged: this is presentation over data every
        // resolved viewer already has, never a console-only capability. A
        // brand-new uncertified arrival needs it MORE than anyone -- they
        // can read what there is to earn -- so it is never behind a
        // capability check. loadMyRecord() on entry because the status
        // badges read state.myRecord.myFeatures.
        var guideTab = mkButton(S('tab_guide'), 'k9tablet-tab' + (state.screen === 'guide' ? ' k9tablet-tab--active' : ''), function () {
            state.screen = 'guide';
            render();
            loadMyRecord();
        });
        tabs.appendChild(guideTab);

        // Command Console -- ONLY meaningful for a viewer who actually has
        // SOME access here. Previously appended unconditionally (safe only
        // because buildBackdrop() used to skip calling buildTabs() at all
        // for a canAccessConsole() === false viewer) -- now guarded HERE
        // explicitly, since this pass widens buildBackdrop() to always
        // render this tab bar (so the new Home tab above is reachable by
        // everyone); without this guard a viewer with no console access
        // would see a Console tab that silently dead-ends into My Record
        // instead (buildBackdrop()'s own 'console' branch already requires
        // canOpenPersonRecord()) -- exactly the "button exists, does
        // something else" trap this codebase's own consistency rules
        // forbid. Uses canOpenPersonRecord() (canAccessConsole() OR a held
        // 'k9.certify'/'k9.givexp' capability -- workflow audit finding #1,
        // 2026-08-26) rather than "any non-empty effectivePermissions" --
        // see that function's own doc comment for why the broader check
        // was a bug fixed in an earlier pass, and for why this widening is
        // still deliberately narrower than "any capability at all". A
        // 'k9.certify'/'k9.givexp'-only holder who reaches this tab gets
        // buildConsoleScreen()'s own NARROWED rendering (the "open by
        // exact citizen ID" box only, never the roster search/listing) --
        // this tab is never a dead end for them, just a smaller room than
        // an audit/high-command viewer sees behind the same door.
        if (canOpenPersonRecord()) {
            // Calls goToConsoleScreen() rather than repeating its body: it
            // now also loads the overrides list (plan item D), and a second
            // copy here would have silently missed it.
            var consoleTab = mkButton(S('tab_console'), 'k9tablet-tab' + (state.screen === 'console' || state.screen === 'person' ? ' k9tablet-tab--active' : ''), function () {
                goToConsoleScreen();
            });
            tabs.appendChild(consoleTab);
        }

        // High command only -- no server-side delegation exists for the
        // guided-flow hub itself (it wraps four admin jobs, some of which
        // ARE high-command-only underneath -- see canManageTabletTheme()'s
        // own doc comment for the four capabilities that DO delegate, and
        // Cert Tiers/Permission Keys/XP Tiers/K9 Profiles below, which do
        // not).
        // SERVER SETTINGS -- ONE tab (the owner's rework pass: "make the
        // workflows simpler"). It replaces five: Server Tuning, Tablet
        // Theme, Catalogs, K9 Supply Shop and Runtime Control -- and Server
        // Tuning was itself only a second, step-by-step way into three of
        // the other four. The screens are unchanged; they are now sections
        // of this one tab, picked from a row at the top of it
        // (buildSettingsSectionNav()).
        //
        // EACH SECTION KEEPS ITS OWN GATE. See SETTINGS_SECTIONS: a delegate
        // holding only 'k9.runtimecontrol' sees this tab with one section in
        // it, exactly the one screen they could open before. Merging the
        // tabs must not merge the authorization, and the server re-checks
        // every call regardless.
        if (visibleSettingsSections().length > 0) {
            var settingsTab = mkButton(S('tab_settings'), 'k9tablet-tab' + (isSettingsScreen(state.screen) ? ' k9tablet-tab--active' : ''), function () {
                goToServerSettings();
            });
            appendAdminTab(settingsTab);
        }

        // K9/HANDLER PERSONNEL ROSTERS (docs/history/ROSTER_SPEC.md, Phase B) --
        // HIGH COMMAND ONLY, matching qbx_k9unit:server:rosterList's own
        // re-verified IsHighCommand gate. People, not settings, so it keeps
        // its own tab. Clicking it keeps whichever bucket the operator last
        // had open (see buildRosterBucketControls()).
        if (state.viewer.isHighCommand) {
            var rosterTab = mkButton(S('tab_roster'), 'k9tablet-tab' + (state.screen === 'roster' ? ' k9tablet-tab--active' : ''), function () {
                goToPersonnelRosterScreen();
            });
            appendAdminTab(rosterTab);
        }

        // K9 Audit Trail viewer -- DELIBERATELY its own gate, NOT nested in
        // the `state.viewer.isHighCommand` block above -- see canViewAudit()'s
        // own doc comment for why a rank/grant-qualifying non-high-command
        // officer must see this tab too. No reset-on-click beyond the
        // screen switch itself: unlike the three tabs above, nothing here
        // auto-fetches on entry (every mode needs at least one caller-typed
        // field), so the last query's mode/inputs/result are left exactly
        // as the viewer left them, the same way the Console tab's own
        // rosterQuery persists across a tab switch.
        if (canOpenAuditScreen()) {
            var auditTab = mkButton(S('tab_audit'), 'k9tablet-tab' + (state.screen === 'audit' ? ' k9tablet-tab--active' : ''), function () {
                state.screen = 'audit';
                render();
            });
            appendAdminTab(auditTab);
        }
        return tabs;
    }

    // ------------------------------------------------------------------
    // HOME / LANDING VIEW (this pass -- owner's own words, verbatim:
    // "make the tablet UI for all k9 dogs, k9 handlers, k9 partners and k9
    // high command more fluid, easier to understand, more personal...
    // everything in the tablet more structured... easier to understand
    // where if someone is an idiot they can figure it out very quickly").
    //
    // THE PROBLEM THIS SCREEN SOLVES: every OTHER screen in this file is
    // organised around a SUBSYSTEM (certifications, permissions, the shop,
    // runtime switches, the audit trail) -- correct for someone who already
    // knows what they are looking for, useless as a FIRST thing to see.
    // This screen is organised around the VIEWER instead: it answers "what
    // am I, and what can I do?" in one glance, before asking them to decode
    // a tab bar at all. It is now the DEFAULT screen on every open (see
    // handleOpen()) and the first tab in buildTabs() -- every existing
    // screen/tab is UNCHANGED and still one click away, nothing here
    // deletes or renames anything.
    //
    // FOUR VIEWERS, ONE SCREEN, DIFFERENT CONTENT (never a different
    // screen -- one consistent layout, one consistent set of patterns,
    // per this pass's own "Consistency" requirement):
    //   THE K9 (state.isK9Model true) -- role badge reads 'K9'.
    //   THE HANDLER (certified, not currently wearing a K9 model) -- role
    //     badge reads 'Certified Handler'.
    //   THE PARTNER -- EITHER of the above, PLUS the partnered/no-partner
    //     badge (state.isPartnered, a client-local signal -- see
    //     client/tablet.lua's ResolveLocalRoleFlags() for why this can
    //     never be a THE SECURITY RULE concern: it is read-only framing,
    //     never sent back into any mutation/trigger callback).
    //   HIGH COMMAND (viewer.isHighCommand) -- role badge reads 'High
    //     Command'; ALSO gets the dedicated High Command Tools section
    //     below, which a Handler/K9/Partner viewer never sees at all --
    //     THE PROGRESSIVE-DISCLOSURE REQUIREMENT: high command's own
    //     twelve-ish admin screens are grouped under ONE heading, below
    //     the fold, rather than crowding the two or three actions an
    //     ordinary handler actually wants.
    //
    // STATE AT A GLANCE (this pass's own explicit ask -- "a player should
    // never have to infer"): the identity card's badge row shows certified
    // count, partnered/not, and a blocked-ability count WITHOUT the viewer
    // opening a single other screen, reusing the SAME semantic colour
    // classes (.k9tablet-feature-state--available/--blocked/--global_off)
    // every other screen already uses for the identical good/bad/neutral
    // meaning -- never a new, one-off colour.
    //
    // NO CERTIFICATION IS NOT AN EMPTY SHELL: a viewer with zero active
    // certifications still gets a real, useful screen -- an explicit
    // "you're not certified yet, here is what to do" notice (see
    // buildHomeIdentityCard() below) INSTEAD OF a blank card, and the
    // certification and ability lists further down this same screen
    // still render 'no_certifications'/'no_abilities' honestly rather
    // than going blank (see buildHomeScreen() immediately below this
    // block).
    //
    // There is no longer a "View My Record" quick-action card pointing at
    // those lists: the Home/My Record/Progression merge moved them onto
    // THIS screen, so the card would have sent the viewer to the screen
    // they were already on. tests/tablet_home_spec.js asserts it is gone.
    //
    // NAVIGATION HELPERS immediately below are the SINGLE definition of
    // what entering each of these screens means -- same screen, same
    // fresh-entry draft/error/warning reset, same reload calls.
    //
    // They began as verbatim copies of buildTabs()'s matching tab onClick
    // bodies, duplicated on purpose because several agents were editing
    // this file at once and touching every tab's closure carried more
    // conflict risk than one clearly-labelled duplication. That debt has
    // since been paid off in both directions: buildTabs() now CALLS each
    // of these helpers instead of repeating it, so there is no second
    // copy left to keep in sync, and changing entry behaviour here
    // changes it for the tab too.
    // ------------------------------------------------------------------

    function goToMyRecordScreen() {
        state.screen = 'home';
        render();
        loadMyRecord();
    }

    function goToConsoleScreen() {
        state.screen = 'console';
        render();
        // Guarded on canAccessConsole() (this pass, workflow audit finding
        // #1): a 'k9.certify'/'k9.givexp'-only viewer (canOpenPersonRecord()
        // true, canAccessConsole() false) can still reach this screen --
        // from the Person screen's own "Back" button, reused here (see that
        // call site's own comment) -- but tabletRequestRoster stays
        // k9.audit/high-command only server-side (CallerHasConsoleAccess,
        // untouched). Calling it anyway would just draw a guaranteed
        // 'not_authorized' for a screen that never renders the roster for
        // this viewer in the first place (buildConsoleScreen()'s own
        // narrowed branch) -- pointless network noise, not a real request.
        // SAME reasoning extends to loadOnlinePlayers() below (this pass)
        // -- one more console-only list, one more skipped fetch for a
        // viewer who would just be refused it.
        if (canAccessConsole()) {
            loadRoster(state.rosterQuery);
            loadOnlinePlayers(state.onlinePlayersQuery);
        }
        // THE OVERRIDES LIST (plan item D) -- a third console-only list,
        // gated the same way the tab it replaces was. Deliberately keyed on
        // isHighCommand rather than canAccessConsole(): that is the gate the
        // old K9 Overrides tab used, and server/k9profiles.lua's own
        // CanManageK9Profiles refuses anyone else regardless.
        if (state.viewer && state.viewer.isHighCommand) {
            resetAndLoadK9Profiles();
        }
    }

    /**
     * @returns {boolean} -- gates the Home "Open Command Console" card.
     * FIXED this pass: previously its own local copy of "isHighCommand OR
     * any non-empty effectivePermissions" (a bug -- see canAccessConsole()'s
     * own doc comment), duplicated independently across this function and
     * buildBackdrop()/buildTabs(). Now a thin wrapper over canAccessConsole()
     * (the ONE place this file derives that signal) instead of a fourth
     * independent copy of the same rule.
     */
    function homeCanManageRoster() {
        return canAccessConsole();
    }

    /** @returns {{active:number, total:number}} */
    function homeCertificationCounts() {
        var certs = (state.myRecord && state.myRecord.certifications) || [];
        var active = 0;
        for (var i = 0; i < certs.length; i++) {
            if (certs[i] && certs[i].active) active++;
        }
        return { active: active, total: certs.length };
    }

    /** @returns {number} */
    /** @returns {string} */
    function homeRoleLabel() {
        if (state.viewer.isHighCommand) return S('home_role_high_command');
        // SERVER-TRUSTWORTHY FIRST (this pass): state.viewer.isK9 comes from
        // server/tablet.lua's HasK9Role(source) -- model-independent,
        // DB-backed, re-verified every request (see that field's own doc
        // comment in server/tablet.lua). state.isK9Model (client-local
        // IsOwnModelK9(), "is my own ped CURRENTLY this model") is kept only
        // as a fallback for the instant after open before viewer resolves,
        // and never overrides a definite server answer.
        if (state.viewer.isK9 === true || state.isK9Model) return S('home_role_k9');
        if (homeCertificationCounts().active > 0) return S('home_role_handler');
        return S('home_role_uncertified');
    }

    function buildHomeActionCard(label, hint, onClick) {
        var card = mk('button', { class: 'k9tablet-home-action-card' });
        card.setAttribute('type', 'button');
        card.appendChild(mk('span', { class: 'k9tablet-home-action-label', text: label }));
        if (typeof hint === 'string' && hint.length > 0) {
            card.appendChild(mk('span', { class: 'k9tablet-home-action-hint', text: hint }));
        }
        card.addEventListener('click', function (e) {
            if (e && typeof e.preventDefault === 'function') e.preventDefault();
            onClick();
        });
        return card;
    }

    function buildHomeIdentityCard() {
        var card = mk('div', { class: 'k9tablet-home-card k9tablet-home-identity' });

        var name = (typeof state.viewer.name === 'string' && state.viewer.name.length > 0) ? state.viewer.name : state.viewer.citizenid;
        card.appendChild(mk('h2', { class: 'k9tablet-section-heading', text: formatTemplate(S('home_welcome_template'), { name: String(name) }) }));

        var badges = mk('div', { class: 'k9tablet-home-badges' });
        badges.appendChild(mk('span', { class: 'k9tablet-home-role-badge', text: homeRoleLabel() }));

        // SERVER-TRUSTWORTHY FIRST -- see homeRoleLabel()'s identical
        // preference note just above for why state.viewer.isPartnered
        // (server/tablet.lua's GetActivePartnerCitizenId) leads over the
        // client-local state.isPartnered fallback.
        if (state.viewer.isPartnered === true || state.isPartnered) {
            badges.appendChild(mk('span', { class: 'k9tablet-feature-state k9tablet-feature-state--available', text: S('home_partnered_badge') }));
        } else {
            badges.appendChild(mk('span', { class: 'k9tablet-muted', text: S('home_not_partnered_badge') }));
        }

        var counts = homeCertificationCounts();
        if (counts.total > 0) {
            var certClass = counts.active > 0 ? 'k9tablet-feature-state--available' : 'k9tablet-feature-state--global_off';
            badges.appendChild(mk('span', {
                class: 'k9tablet-feature-state ' + certClass,
                text: formatTemplate(S('home_certified_count_template'), { count: counts.active, total: counts.total }),
            }));
        }

        // No "N blocked" badge: your own screens show only what you can use.

        card.appendChild(badges);

        // NO CERTIFICATION IS NOT AN EMPTY SHELL -- see this block's own
        // header comment. Shown whenever this viewer holds zero ACTIVE
        // certifications but at least one department exists to be
        // certified in at all (a misconfigured zero-department server has
        // nothing useful to say here either way).
        if (counts.active === 0 && counts.total > 0) {
            var notice = mk('div', { class: 'k9tablet-home-notice' });
            notice.appendChild(mk('p', { class: 'k9tablet-home-notice-title', text: S('home_no_certification_title') }));
            notice.appendChild(mk('p', { class: 'k9tablet-muted', text: S('home_no_certification_body') }));
            // THE "PRE-FACE" STATE (this pass) -- a brand-new arrival is
            // not a fourth role, it is the state before any of the three
            // faces applies, and it deserves a concrete next step rather
            // than a single paragraph that only explains the CURRENT state
            // with no path out of it. Points at the two tabs this resource
            // already has for exactly this question -- Help (a walkthrough)
            // and Commands (what there is to earn) -- both always present
            // for every viewer, including this one (see buildTabs()'s own
            // comments on why those two tabs are never gated).
            notice.appendChild(mk('p', { class: 'k9tablet-hint', text: S('home_no_certification_next_steps') }));
            card.appendChild(notice);
        }

        return card;
    }

    function buildHomeQuickActions() {
        var section = mk('div', { class: 'k9tablet-home-section' });
        section.appendChild(mk('h2', { class: 'k9tablet-section-heading', text: S('home_quick_actions_heading') }));

        var grid = mk('div', { class: 'k9tablet-home-actions' });
        grid.appendChild(buildHomeActionCard(S('home_view_partners_label'), S('home_view_partners_hint'), goToPartnershipsScreen));

        if (homeCanManageRoster()) {
            grid.appendChild(buildHomeActionCard(S('home_open_console_label'), S('home_open_console_hint'), goToConsoleScreen));
        }

        section.appendChild(grid);
        return section;
    }

    /** K9-FLAVORED landing body -- see buildHomeScreen()'s own role-split
     * comment for the full reasoning. Leads with progression (xpLine() --
     * the SAME data/format buildHomeScreen() already renders, never a
     * second XP presentation invented for this screen) and the
     * Partnerships link, ahead of the shared quick-actions grid a
     * non-K9 viewer sees instead -- "a K9 sees its own condition, its
     * abilities, its partner, its progression" (owner). Console access is
     * never offered here even for the rare K9 who also holds it -- the
     * Command Console tab itself is still one click away in the tab bar
     * regardless; this body is about being the dog, not about
     * administering.
     * @returns {Element} */
    function buildK9HomeBody() {
        var section = mk('div', { class: 'k9tablet-home-section k9tablet-home-k9' });
        section.appendChild(mk('h2', { class: 'k9tablet-section-heading', text: S('home_k9_progression_heading') }));
        section.appendChild(mk('p', { class: 'k9tablet-xp-line', text: xpLine(state.myRecord.xp, state.myRecord.tierLabel) }));

        var grid = mk('div', { class: 'k9tablet-home-actions' });
        grid.appendChild(buildHomeActionCard(S('home_view_partners_label'), S('home_view_partners_hint'), goToPartnershipsScreen));
        section.appendChild(grid);

        return section;
    }

    /* ==================================================================
     * XP LADDERS (owner-directed: "do progression put in the tablet").
     * Shows BOTH ladders -- the K9's and the handler's -- each
     * with the viewer's own total, their current rank, the next rank, and
     * the exact gap to it.
     *
     * NO LONGER ITS OWN SCREEN (plan item A): these three helpers now
     * render as a section of the one My Record screen, alongside the
     * certifications and abilities they always sat next to conceptually.
     * The Progression tab and buildProgressionScreen() are gone; nothing
     * about the ladders themselves changed.
     *
     * WHY BOTH IN ONE PLACE: one player is usually both. Someone plays
     * the dog on one character and handles on another, and the two ladders
     * advance independently on independent switches. Splitting them across
     * two screens would make the common question -- "where am I on each of
     * these" -- take two clicks and a comparison the player has to hold in
     * their head.
     *
     * NULL IS NOT ZERO, and this screen is the reason the server payload
     * keeps them distinct all the way here. A null total means that ladder
     * is switched off on this server; 0 means you are on it and have not
     * earned anything yet. Those get different text, because telling
     * someone "0 XP" about a system their server does not run would send
     * them off to grind something that does not exist.
     * ================================================================== */

    /** Drops malformed rows and returns a NEW array sorted ascending by xp.
     *
     * The server does already sort (server/progression.lua's
     * LadderForDisplay ends in a table.sort by xp), so this is not fixing a
     * payload seen in practice. It removes a coupling: without it, both the
     * position maths and the rendered list below silently depend on a
     * guarantee made in a different file, in a different language, that
     * nothing on this side asserts or can see. A future ladder assembled
     * from a second source, or a server whose sort is refactored out,
     * would show a rank list in the wrong order and mark the wrong row as
     * current -- with no error anywhere.
     *
     * Copies rather than sorting in place: `ladder` comes straight off
     * `state.myRecord`, and reordering caller-owned state as a side effect
     * of rendering it is its own bug waiting to happen.
     * @param {Array} ladder
     * @returns {Array} */
    function sortedLadderRows(ladder) {
        var rows = [];
        for (var i = 0; i < (ladder || []).length; i++) {
            var row = ladder[i];
            if (row && typeof row.xp === 'number' && typeof row.label === 'string') rows.push(row);
        }
        rows.sort(function (a, b) { return a.xp - b.xp; });
        return rows;
    }

    /** The rank the viewer currently holds, and the next one up, from a
     * ladder and a total. Returns { current, next } where either may be
     * null: current is null below the first threshold, next is null at the
     * top of the ladder.
     *
     * Order-independent: it takes the HIGHEST threshold at or below `total`
     * and the LOWEST above it, rather than relying on the array's order to
     * make each overwrite land correctly. Callers pass a sorted array
     * anyway (see sortedLadderRows), so this costs nothing and means the
     * two are not silently load-bearing on each other.
     * @param {Array} ladder -- [{ xp, label }], any order
     * @param {number} total
     * @returns {{current: Object|null, next: Object|null}} */
    function resolveLadderPosition(ladder, total) {
        var current = null;
        var next = null;
        for (var i = 0; i < ladder.length; i++) {
            var row = ladder[i];
            if (typeof row.xp !== 'number' || typeof row.label !== 'string') continue;
            if (total >= row.xp) {
                if (current === null || row.xp > current.xp) current = row;
            } else if (next === null || row.xp < next.xp) {
                next = row;
            }
        }
        return { current: current, next: next };
    }

    /** One ladder's block: heading, your standing, the gap to the next
     * rank, and the full ladder with your position marked.
     * @param {string} headingKey
     * @param {number|null|undefined} total
     * @param {string|null|undefined} tierLabel
     * @param {Array} ladder
     * @param {string} offKey -- what to say when this ladder is switched off
     * @returns {Element} */
    function buildLadderBlock(headingKey, total, tierLabel, ladder, offKey) {
        var block = mk('div', { class: 'k9tablet-progression-block' });
        block.appendChild(mk('h2', { class: 'k9tablet-section-heading', text: S(headingKey) }));

        // SWITCHED OFF -- said plainly, and never as a number. An empty
        // ladder means the same thing as a null total here (the server
        // returns [] for a ladder whose feature is off), so either alone
        // is enough to take this branch.
        if (total === null || total === undefined || !ladder || ladder.length === 0) {
            block.appendChild(mk('p', { class: 'k9tablet-muted', text: S(offKey) }));
            return block;
        }

        // Sorted once, up front, and used for BOTH the position maths and
        // the rendered list below -- so the two can never disagree about
        // what order the ladder is in.
        var rows = sortedLadderRows(ladder);
        var pos = resolveLadderPosition(rows, total);
        var currentLabel = (typeof tierLabel === 'string' && tierLabel.length > 0)
            ? tierLabel
            : (pos.current ? pos.current.label : S('progression_no_rank_yet'));

        block.appendChild(mk('p', {
            class: 'k9tablet-xp-line',
            // formatTemplate, not chained .replace() -- a rank label
            // containing another token would otherwise be re-scanned by the
            // next replace. See formatTemplate's own header.
            text: formatTemplate(S('progression_standing'), { xp: total, rank: currentLabel })
        }));

        if (pos.next) {
            var remaining = pos.next.xp - total;
            block.appendChild(mk('p', {
                class: 'k9tablet-progression-next',
                text: formatTemplate(S('progression_next_rank'), { rank: pos.next.label, remaining: remaining })
            }));
        } else {
            block.appendChild(mk('p', {
                class: 'k9tablet-progression-next',
                text: S('progression_top_rank')
            }));
        }

        var list = mk('ul', { class: 'k9tablet-progression-ladder' });
        for (var i = 0; i < rows.length; i++) {
            var row = rows[i];
            var reached = total >= row.xp;
            var isCurrent = pos.current && pos.current.label === row.label && pos.current.xp === row.xp;
            var cls = 'k9tablet-progression-rank'
                + (reached ? ' k9tablet-progression-rank--reached' : '')
                + (isCurrent ? ' k9tablet-progression-rank--current' : '');
            list.appendChild(mk('li', {
                class: cls,
                text: formatTemplate(S('progression_rank_row'), { rank: row.label, xp: row.xp })
            }));
        }
        block.appendChild(list);

        return block;
    }

    /**
     * Plain-English "A, B, and C" join -- no Intl.ListFormat dependency
     * (every other list this page hand-builds, e.g. the invalid-department/
     * invalid-specialization hint text server-side, already joins by hand
     * rather than reaching for a locale-aware API for a single-locale
     * page). Only ever called with 1-4 short phrases here.
     * @param {string[]} items
     * @returns {string}
     */
    function joinEnglishList(items) {
        if (items.length === 0) return '';
        if (items.length === 1) return items[0];
        if (items.length === 2) return items[0] + ' ' + S('list_join_and') + ' ' + items[1];
        return items.slice(0, -1).join(', ') + ', ' + S('list_join_and') + ' ' + items[items.length - 1];
    }

    /**
     * HIGH-COMMAND-OR-DELEGATED SIGNPOST (this pass) -- called for the same
     * viewers as before (see buildHomeScreen()'s own call site: high
     * command, or a non-high-command officer holding any one of the four
     * delegable capabilities), but no longer duplicates the twelve admin
     * screens link-for-link. THAT grid used to be a SECOND, differently-
     * organised answer to "how do I reach the Runtime Control screen"
     * existing at the same time as the tab bar's own flat list of the
     * exact same twelve screens -- two competing navigation structures for
     * one set of destinations, with nothing on screen explaining why they
     * differed. Resolved by settling on ONE real navigation surface (the
     * tab bar, now visually grouped into its own band -- see
     * html/tablet.css's own ".k9tablet-tab-group--admin" comment) and
     * turning this section into what its own heading always implied it
     * was: a SIGNPOST, not a second menu. It still names, in plain
     * language, what this viewer's admin access actually covers, and it
     * still marks a real visual boundary between "this is you, the
     * handler/K9" (everything above) and "this is you, the administrator"
     * (this section) -- see .k9tablet-home-highcommand's own CSS comment
     * for that boundary. NEVER decides what to show by itself: the caller
     * (buildHomeScreen()) already re-checks state.viewer.isHighCommand OR
     * one of the four canManageX() capabilities before calling this at
     * all, exactly as before.
     *
     * WORKFLOW AUDIT FINDING #3, 2026-08-26: the heading ("High Command
     * Tools") and body used to be ONE fixed pair of sentences naming EVERY
     * admin capability this resource has (certification ranks, permission
     * keys, the supply shop, feature toggles, XP ranks, the audit trail),
     * shown verbatim to a non-high-command delegate who holds exactly ONE
     * of those -- someone granted only 'k9.equipmentshoplocations', say,
     * would read a promise covering six different admin surfaces and find
     * exactly one real tab. The heading stays the same for every viewer
     * (a real, useful landmark either way), but the BODY now branches: a
     * true high-command viewer keeps the original full-scope text
     * unchanged (accurate for them -- they really do have all of it), and
     * a delegate instead gets a sentence built from ONLY the capabilities
     * canManageTabletTheme()/canManageShopLocations()/canManageShopItems()/
     * canManageRuntimeControl() actually resolve true for them right now.
     */
    function buildHomeHighCommandSignpost() {
        var section = mk('div', { class: 'k9tablet-home-section k9tablet-home-highcommand' });
        section.appendChild(mk('h2', { class: 'k9tablet-section-heading', text: S('home_high_command_heading') }));

        if (state.viewer.isHighCommand) {
            section.appendChild(mk('p', { class: 'k9tablet-muted', text: S('home_high_command_hint') }));
            section.appendChild(mk('p', { class: 'k9tablet-hint', text: S('home_high_command_tabs_pointer') }));
            return section;
        }

        var heldScopePhrases = [];
        if (canManageTabletTheme()) heldScopePhrases.push(S('home_high_command_scope_theme'));
        if (canManageShopLocations()) heldScopePhrases.push(S('home_high_command_scope_shop_locations'));
        if (canManageShopItems()) heldScopePhrases.push(S('home_high_command_scope_shop_items'));
        if (canManageRuntimeControl()) heldScopePhrases.push(S('home_high_command_scope_runtime_control'));

        section.appendChild(mk('p', {
            class: 'k9tablet-muted',
            text: formatTemplate(S('home_high_command_delegate_hint_template'), { scope: joinEnglishList(heldScopePhrases) }),
        }));
        section.appendChild(mk('p', { class: 'k9tablet-hint', text: S('home_high_command_delegate_tabs_pointer') }));
        return section;
    }

    /** THE LANDING VIEW -- see this block's own header comment for the
     * full information-architecture writeup. Same loading/error/empty
     * posture as every other data-driven screen (this file's one
     * consistent loading/error pattern, reused here rather than a second
     * one invented for this screen). */
    function buildHomeScreen() {
        var wrap = mk('div', { class: 'k9tablet-screen k9tablet-home' });

        if (state.myRecordLoading && !state.myRecord) {
            wrap.appendChild(mk('p', { text: S('loading') }));
            return wrap;
        }
        if (state.myRecordError && !state.myRecord) {
            wrap.appendChild(mk('p', { class: 'k9tablet-error-text', text: errorText(state.myRecordError) }));
            wrap.appendChild(mkButton(S('retry_label'), 'k9tablet-btn', loadMyRecord));
            return wrap;
        }
        if (!state.myRecord || !state.viewer) {
            wrap.appendChild(mk('p', { text: S('loading') }));
            return wrap;
        }

        wrap.appendChild(buildHomeIdentityCard());

        // ROLE-DRIVEN LANDING BODY (this pass, coder-ui) -- owner, verbatim,
        // twice: "a handler and the k9 are both separate and if not fix
        // it" / "one deals with the k9 and the other deals with the
        // handler roles etc." SERVER-TRUSTWORTHY split
        // (state.viewer.isK9 -- server/tablet.lua's HasK9Role(source),
        // model-independent, re-verified every request -- see that field's
        // own doc comment server-side), deliberately NEVER the client-local
        // state.isK9Model cosmetic flag for this decision (homeRoleLabel()'s
        // badge text still tolerates that as a same-instant fallback; this
        // structural choice does not). Still ONE screen id ('home'), ONE
        // tab, ONE set of server callbacks feeding both branches -- per
        // this pass's own "no forked entry point" instruction, only the
        // CONTENT differs: a K9 sees its progression and its partner
        // emphasized first (buildK9HomeBody()); everyone else keeps the
        // existing quick-actions body, now also carrying its own
        // Partnerships link (buildHomeQuickActions()). The abilities list
        // (the feature-ready list) is shared by both -- it is the same
        // underlying data and heading for every viewer, not something this
        // split has any reason to fork.
        if (state.viewer.isK9 === true) {
            wrap.appendChild(buildK9HomeBody());
        } else {
            wrap.appendChild(buildHomeQuickActions());
        }

        // THE WHOLE RECORD, below the "what do I do next" card (plan item
        // A). These four sections were the My Record and Progression tabs;
        // they read the SAME state.myRecord this screen already had loaded,
        // so merging them cost no extra fetch and removed two tabs.
        //
        // buildHomeReadyAbilities() is GONE, not moved: it rendered
        // state.myRecord.myFeatures filtered to the currently-usable ones,
        // and buildMyFeaturesList() below renders the same array in full,
        // with each row's real state on it. Keeping both would have shown
        // every ready ability twice on one screen -- and the full list
        // answers the same question plus "what do I still have to earn",
        // which is the more useful half for a landing view.
        //
        // The single plain XP line that My Record used to carry is gone for
        // the same reason: buildLadderBlock() below says everything it said
        // and then where that total sits on the ladder.
        wrap.appendChild(mk('h2', { class: 'k9tablet-section-heading', text: S('my_certifications_heading') }));
        wrap.appendChild(buildCertificationList(state.myRecord.certifications, null, { roleXp: state.myRecord.roleXp }));

        wrap.appendChild(mk('h2', { class: 'k9tablet-section-heading', text: S('my_xp_heading') }));
        wrap.appendChild(mk('p', { class: 'k9tablet-muted', text: S('progression_intro') }));
        wrap.appendChild(buildLadderBlock(
            'progression_k9_heading',
            state.myRecord.xp,
            state.myRecord.tierLabel,
            state.myRecord.xpLadder || [],
            'progression_k9_off'
        ));
        wrap.appendChild(buildLadderBlock(
            'progression_handler_heading',
            state.myRecord.handlerXp,
            state.myRecord.handlerTierLabel,
            state.myRecord.handlerXpLadder || [],
            'progression_handler_off'
        ));

        wrap.appendChild(mk('h2', { class: 'k9tablet-section-heading', text: S('my_abilities_heading') }));
        wrap.appendChild(buildMyFeaturesList());

        // A non-high-command officer holding any ONE of the four delegable
        // capabilities (Theme/Shop Locations/Shop Items/Runtime Control --
        // see canManageTabletTheme()'s own doc comment) still gets this
        // section, same as high command -- it is a signpost naming what
        // admin access this viewer holds, not a gate of its own.
        if (state.viewer.isHighCommand || canManageTabletTheme() || canManageShopLocations()
            || canManageShopItems() || canManageRuntimeControl()) {
            wrap.appendChild(buildHomeHighCommandSignpost());
        }

        return wrap;
    }

    // ------------------------------------------------------------------
    // COMMAND REFERENCE screen (this pass) -- see COMMAND_REFERENCE's own
    // header above for the catalog, its drift guard, and exactly what
    // commandReferenceStatus() does and does not promise. Grouped by
    // COMMAND_REFERENCE_CATEGORIES (what the player is trying to do, never
    // by which server/client file registers the command), filterable by a
    // single client-side search box (36 entries is too many to scan, and
    // there is nothing server-side to ask -- see state.commandReferenceQuery's
    // own doc comment), and every row shows the SAME four things for every
    // viewer: the command with its argument shape, one plain-English line
    // on what it does, one on what it needs, and a live status badge --
    // never hidden for a viewer who cannot use it, per this task's own
    // "that is more useful than hiding it, because it tells them what to
    // go earn" instruction.
    // ------------------------------------------------------------------

    function buildCommandReferenceScreen() {
        var wrap = mk('div', { class: 'k9tablet-home-section' });

        wrap.appendChild(mk('h2', { class: 'k9tablet-section-heading', text: S('cmdref_heading') }));
        wrap.appendChild(mk('p', { class: 'k9tablet-hint', text: S('cmdref_intro') }));
        // Shown ONCE here rather than repeated on every row that carries a
        // `defaultKeybind` (this pass, keybinds handoff) -- load-bearing:
        // without it, a player who rebound one of these keys long ago and
        // then sees a later config change to its listed default would
        // reasonably (and wrongly) expect their own binding to have moved.
        wrap.appendChild(mk('p', { class: 'k9tablet-hint', text: S('cmdref_keybind_caveat') }));

        // WHY THE STATUS COLUMN MIGHT SAY NOTHING USEFUL (2026-09-01) --
        // the second half of the owner's "everything in the command console
        // in the status says disabled" report.
        //
        // Every badge in that column comes from commandReferenceStatus(),
        // which resolves entirely out of state.myRecord.myFeatures. When
        // that record has not arrived, that function answers 'unknown' for
        // every row -- honest, and a large improvement on the "Disabled
        // server-wide" it used to claim, but on its own it just replaces
        // one wall of identical badges with another and still never says
        // WHY, or offers anything to do about it.
        //
        // Home, My Record and Progression have always rendered an explicit
        // loading/error state for exactly this fetch. This screen was the
        // one that did not, so a failed record load left it looking
        // permanently mid-load with no error and no retry anywhere. This
        // banner is that missing state.
        //
        // Deliberately a BANNER, not an early return: the reference itself
        // -- every command, its usage, what it does, what it needs -- is
        // static and just as useful with an unresolved status column. A
        // viewer who came here to look up a command's arguments should not
        // be shown an error page instead because a separate fetch failed.
        // The condition here is deliberately the SAME one
        // commandReferenceStatus() uses to answer 'unknown', not a plain
        // `!state.myRecord`. state.viewer and state.myRecord are assigned
        // together from one response, and buildBackdrop() renders the
        // viewer gate instead of any screen while state.viewer is null --
        // so by the time this screen exists at all, state.myRecord is
        // always set, and a `!state.myRecord` check here would be dead
        // code that never fired. What CAN be true here is a record that
        // arrived without a usable feature list, which is exactly when
        // every badge below reads 'unknown' and the operator is owed an
        // explanation.
        if (!state.myRecord || !Array.isArray(state.myRecord.myFeatures)) {
            if (state.myRecordError) {
                var errBox = mk('div', { class: 'k9tablet-warning-note' });
                errBox.appendChild(mk('p', { class: 'k9tablet-cmdref-status-note', text: S('cmdref_status_unavailable_error') }));
                errBox.appendChild(mk('p', { class: 'k9tablet-cmdref-status-note k9tablet-muted', text: errorText(state.myRecordError) }));
                errBox.appendChild(mkButton(S('retry_label'), 'k9tablet-btn', function () { loadMyRecord(); }));
                wrap.appendChild(errBox);
            } else {
                wrap.appendChild(mk('p', { class: 'k9tablet-hint', text: S('cmdref_status_unavailable_loading') }));
            }
        }

        var query = (state.commandReferenceQuery || '').toLowerCase();

        // Counted up front, before anything renders, so the shared filter
        // bar can state both numbers -- see buildListFilterBar(). The old
        // bare input could not say what it was hiding, which on a list this
        // long is the difference between "there is no such command" and
        // "my filter is still on from a minute ago".
        // Server-disabled commands are excluded from BOTH the count and the
        // rows below -- see commandReferenceIsVisible(). `visibleTotal` is
        // what the filter readout reports as its denominator, so "Showing 3
        // of 28" counts what this server actually has, never a total that
        // includes commands nobody here can ever run.
        var visibleTotal = 0;
        var shownCount = 0;
        for (var pre = 0; pre < COMMAND_REFERENCE.length; pre++) {
            if (!commandReferenceIsVisible(COMMAND_REFERENCE[pre])) continue;
            visibleTotal++;
            if (commandReferenceMatchesQuery(COMMAND_REFERENCE[pre], query)) shownCount++;
        }

        wrap.appendChild(buildListFilterBar({
            id: 'k9tablet-cmdref-filter',
            labelText: S('cmdref_filter_label'),
            placeholder: S('cmdref_search_placeholder'),
            value: state.commandReferenceQuery,
            total: visibleTotal,
            shown: shownCount,
            onChange: function (v) {
                state.commandReferenceQuery = v;
                render();
            },
        }));

        var anyRendered = false;

        for (var c = 0; c < COMMAND_REFERENCE_CATEGORIES.length; c++) {
            var category = COMMAND_REFERENCE_CATEGORIES[c];
            var categoryLabel = S(category.labelKey);

            var rows = [];
            for (var i = 0; i < COMMAND_REFERENCE.length; i++) {
                var entry = COMMAND_REFERENCE[i];
                if (entry.category !== category.key) continue;
                // The SAME two predicates the counts above use --
                // deliberately not a second copy of either, which is how a
                // readout and the rows it describes drift apart.
                if (!commandReferenceIsVisible(entry)) continue;
                if (!commandReferenceMatchesQuery(entry, query)) continue;
                rows.push(entry);
            }
            if (rows.length === 0) continue;

            anyRendered = true;
            wrap.appendChild(mk('h3', { class: 'k9tablet-specializations-heading', text: categoryLabel }));

            var table = mk('table', { class: 'k9tablet-table' });
            var thead = mk('thead');
            var headRow = mk('tr');
            [S('cmdref_column_command'), S('cmdref_column_does'), S('cmdref_column_needs'), S('status_column')].forEach(function (h) {
                headRow.appendChild(mk('th', { text: h }));
            });
            thead.appendChild(headRow);
            table.appendChild(thead);

            var tbody = mk('tbody');
            for (var r = 0; r < rows.length; r++) {
                tbody.appendChild(buildCommandReferenceRow(rows[r]));
            }
            table.appendChild(tbody);
            wrap.appendChild(table);
        }

        if (!anyRendered) {
            // Same distinction buildPersonFeaturesSection() draws: with a
            // filter on, nothing matching is a fact about the FILTER, and
            // `cmdref_empty` ("no commands") would be simply untrue -- this
            // list is a fixed, non-empty constant in this very file.
            if (query.length > 0) {
                // No Clear button here: buildListFilterBar() above is
                // already showing one (it renders whenever the filter is
                // narrowing anything, and narrowing to zero is still
                // narrowing). Two identical buttons a few lines apart is
                // its own small confusion, and the owner asked for less of
                // that, not more.
                wrap.appendChild(mk('p', { class: 'k9tablet-muted', text: S('cmdref_filter_no_matches') }));
            } else {
                wrap.appendChild(mk('p', { class: 'k9tablet-muted', text: S('cmdref_empty') }));
            }
        }

        return wrap;
    }

    /**
     * Does one Command Reference entry match the active filter text?
     * Single source of truth for buildCommandReferenceScreen()'s count and
     * for the rows it actually renders.
     * @param {{command:string, category:string, usageKey:string, doesKey:string, needsKey:string}} entry
     * @param {string} query already lower-cased; '' matches everything
     * @returns {boolean}
     */
    function commandReferenceMatchesQuery(entry, query) {
        if (!query || query.length === 0) return true;
        return commandReferenceHaystack(entry).indexOf(query) !== -1;
    }

    /**
     * Should this command appear on the reference at all? (2026-09-01,
     * owner: "make it where if something is turned off in the config
     * nothing on the tablet shows up".)
     *
     * A command whose gated feature is switched off server-wide cannot be
     * run by anyone, in any circumstance, until an admin turns the feature
     * back on. Listing it with a "Disabled server-wide" badge described a
     * capability nobody on this server has -- see withoutGloballyDisabled()
     * for the same reasoning applied to the two ability lists.
     *
     * ONLY 'global_off' hides a row. Every other status stays listed, and
     * that is the point of this screen: 'not_certified' and
     * 'insufficient_authorization' are exactly what a handler browsing the
     * list should see, because they say what there is to go and earn. This
     * screen's own header calls that out -- "never hidden for a viewer who
     * cannot use it... that is more useful than hiding it, because it tells
     * them what to go earn". A globally-off feature is the one case where
     * there is nothing to earn.
     *
     * 'unknown' also stays listed, deliberately. While the viewer's record
     * is still resolving every gate answers 'unknown', and treating that as
     * "off" would empty the entire screen for a moment on every open -- the
     * same "not loaded is not turned off" confusion this file has already
     * been bitten by once.
     * @param {{gate:object}} entry
     * @returns {boolean}
     */
    function commandReferenceIsVisible(entry) {
        // SHOW ONLY WHAT YOU HAVE (owner: "the things the k9 or the handler
        // should see on their tablet ... is what they have been certified
        // in"). A command this viewer cannot use right now -- switched off,
        // not certified, not granted, blocked, not high command -- is left
        // out entirely instead of listed with a reason.
        // 'unknown' (the record has not loaded yet) still shows, reading
        // "Still loading", so the Guide never goes blank for a moment.
        var status = commandReferenceStatus(entry.gate);
        return status === 'available' || status === 'unknown';
    }

    /**
     * The searchable text for one entry -- split out of
     * commandReferenceMatchesQuery() so the filter and any future reader
     * share one definition rather than each building their own.
     * @param {{command:string, category:string, usageKey:string, doesKey:string, needsKey:string}} entry
     * @returns {string} lower-cased
     */
    function commandReferenceHaystack(entry) {
        var categoryLabel = '';
        for (var c = 0; c < COMMAND_REFERENCE_CATEGORIES.length; c++) {
            if (COMMAND_REFERENCE_CATEGORIES[c].key === entry.category) {
                categoryLabel = S(COMMAND_REFERENCE_CATEGORIES[c].labelKey);
                break;
            }
        }
        return (
            entry.command + ' ' + S(entry.usageKey) + ' ' + S(entry.doesKey) + ' ' +
            S(entry.needsKey) + ' ' + categoryLabel
        ).toLowerCase();
    }

    /** @param {{command:string, adminOnly:boolean, usageKey:string, doesKey:string, needsKey:string, gate:object, defaultKeybind?:string, defaultKeybindConfigurable?:boolean}} entry */
    function buildCommandReferenceRow(entry) {
        var tr = mk('tr');

        var commandTd = mk('td');
        commandTd.appendChild(mk('span', { text: S(entry.usageKey) }));
        if (entry.adminOnly) {
            // Same "(Default)"/"(Retired)" inline-parenthetical convention
            // buildPersonFeaturesSection()/buildPermissionKeysScreen() already
            // use elsewhere on this page (plain text, k9tablet-muted, never a
            // new badge class) -- shown to EVERY viewer, not only high
            // command, per this task's own "high command sees everything,
            // with the admin ones marked as such" instruction: a handler
            // browsing this list should see which commands are the ones to
            // go earn authorization for, not just that they personally
            // can't run them today.
            commandTd.appendChild(mk('span', { class: 'k9tablet-muted', text: ' (' + S('cmdref_admin_badge') + ')' }));
        }
        // Default keybind (this pass, keybinds handoff) -- OPTIONAL, only
        // commands with a real RegisterKeyMapping default carry this field
        // at all. A separate block-level line under the command's own usage
        // text, never appended inline onto it, so it reads as its own fact
        // rather than part of the command syntax. The "only applies if
        // never rebound" caveat is NOT repeated per-row here -- see
        // cmdref_keybind_caveat, shown once in this screen's own intro.
        // `defaultKeybindConfigurable` (this pass, integration-sweep
        // keybinds fix, NEW/OPTIONAL) picks the HONEST second template
        // (cmdref_default_keybind_configurable_template) for a command
        // whose default is read from a config.lua VALUE this server's own
        // operator set, rather than a literal baked into
        // client/keybinds.lua -- see COMMAND_REFERENCE's own doc comment
        // on this field for exactly which entries use it.
        if (typeof entry.defaultKeybind === 'string' && entry.defaultKeybind.length > 0) {
            var keybindTemplateKey = entry.defaultKeybindConfigurable
                ? 'cmdref_default_keybind_configurable_template'
                : 'cmdref_default_keybind_template';
            commandTd.appendChild(mk('div', {
                class: 'k9tablet-muted',
                text: formatTemplate(S(keybindTemplateKey), { key: entry.defaultKeybind }),
            }));
        }
        tr.appendChild(commandTd);

        tr.appendChild(mk('td', { text: S(entry.doesKey) }));
        tr.appendChild(mk('td', { text: S(entry.needsKey) }));

        var status = commandReferenceStatus(entry.gate);
        var statusTd = mk('td');
        statusTd.appendChild(mk('span', {
            class: 'k9tablet-feature-state k9tablet-feature-state--' + commandReferenceStatusClass(status),
            text: commandReferenceStatusLabel(status),
        }));
        tr.appendChild(statusTd);

        return tr;
    }

    // ------------------------------------------------------------------
    // HELP -- owner's own words, verbatim: "a separate tab that teaches
    // you how to use the entire tablet, list all commands and what they
    // do etc, it should be super detailed but dumbed down where if
    // someone is an idiot they would easily be able to understand."
    // DELIBERATELY NOT the Commands Reference screen above -- that page
    // is a lookup table (command in, gate/status out). This page is a
    // WALKTHROUGH: what to do first, what every tab you can see is for,
    // what every command you personally can use actually does in plain
    // English, how to do the handful of things almost everyone needs to
    // do, and what a refusal message really means and who can fix it.
    //
    // ONE SCREEN, ROLE-FILTERED CONTENT -- never a different screen per
    // role (the same "one consistent layout" posture buildHomeScreen()
    // already established). A K9 (state.isK9Model) sees the K9 track;
    // anyone else sees the Handler track. High command is NOT a fourth,
    // separate track -- per this task's own framing, it is a handler or
    // K9 who ALSO administers, so state.viewer.isHighCommand ADDS an
    // extra section on top of whichever base track already applies, it
    // never replaces one. Every visibility check below is the SAME
    // read-only, display-only signal (state.isK9Model, certification
    // count, canAccessConsole(), canViewAudit(), state.viewer.isHighCommand)
    // every other screen on this page already uses to decide what to
    // SHOW, never what to ALLOW -- see THE SECURITY RULE at the top of
    // this file.
    //
    // DERIVE, DON'T RETYPE -- the two sections most likely to rot if
    // hand-typed are instead built directly from data this file already
    // verifies elsewhere, so they can never fall out of sync with the
    // real tablet:
    //   - The command list is not re-described here AT ALL any more: the
    //     Guide screen renders buildCommandReferenceScreen() directly
    //     underneath these sections (plan item H), so there is one table,
    //     one filter and one set of live status badges. The second,
    //     category-grouped copy this section used to build was deleted
    //     with that merge. A command added to COMMAND_REFERENCE
    //     tests/commandreferenceregistry_spec.lua's own drift guard
    //     against the real RegisterCommand(...) names protects this
    //     section for free.
    //   - The list of Server Settings sections quoted in
    //     buildHelpTasksSection() is built live from
    //     visibleSettingsSections(), never a hand-copied list -- and it
    //     only names the sections the reader can actually open.
    //   - Three quoted button labels ({certifyLabel}/{assignLabel}/
    //     {revertLabel} below) are filled from S('certify_label')/
    //     S('role_assign_label')/S('role_revert_label') at render time --
    //     the SAME `tablet` locale group this whole page already
    //     resolves everything else from -- rather than a second, hand-typed
    //     copy of button text that already exists one screen over.
    // "Every Tab, Explained" (HELP_TAB_CATALOG) and the handful of
    // step-by-step task walkthroughs in buildHelpTasksSection() CANNOT be
    // derived the same way (they are prose, not data):
    //   - HELP_TAB_CATALOG's own header names the drift guard
    //     (tests/helptabcoverage_spec.lua) that keeps ITS list honest
    //     against buildTabs()'s own real tab_* labels instead.
    //   - A handful of walkthrough steps below quote real, VERIFIED
    //     button/menu text that lives in a DIFFERENT locale namespace
    //     this page has no run-time access to (client/partnership.lua's
    //     "Partner Up", client/radial.lua's "Break Partnership",
    //     client/vehicle.lua's two vehicle labels, client/search.lua's
    //     two search labels, client/medkit.lua's treat label, and
    //     client/main.lua's DenyK9UIAccess() notify text) --
    //     tests/helpquotedlabels_spec.lua guards those specific
    //     quotes against locales/en.json's real values instead, so a
    //     rename over there fails a named test here rather than quietly
    //     leaving this page wrong. See this task's own report for the
    //     full list.
    // ------------------------------------------------------------------

    function helpAlwaysVisible() { return true; }
    /** @returns {boolean} -- same signal buildTabs() itself gates every
     * high-command-only tab button on (state.viewer.isHighCommand), never
     * a second, independently-derived copy. */
    function helpHighCommandOnly() { return !!(state.viewer && state.viewer.isHighCommand === true); }

    /** @returns {boolean} true when this viewer holds isHighCommand OR the
     * named capability in state.viewer.effectivePermissions -- the SAME
     * "isHighCommand OR the matching effectivePermissions entry" shape
     * hasDelegatedCapability() above already uses for the Theme/Shop/
     * Runtime Control tabs, applied here for the three CAPABILITY-kind
     * admin command groups (certification/audit/xp) instead of a fourth,
     * differently-named copy of the identical check. */
    function helpHasCapability(capability) {
        if (!state.viewer) return false;
        if (state.viewer.isHighCommand === true) return true;
        var perms = state.viewer.effectivePermissions;
        return Array.isArray(perms) && perms.indexOf(capability) !== -1;
    }

    /** @type {Array<{tabLabelKey:string, descKey:string, visible:() => boolean}>}
     * See this block's own header for the drift guard
     * (tests/helptabcoverage_spec.lua) that keeps this list's `tabLabelKey`
     * set matched against every real `tab_*` DEFAULT_STRINGS entry
     * buildTabs() actually uses. */
    var HELP_TAB_CATALOG = [
        { tabLabelKey: 'tab_my_record', descKey: 'help_tab_my_record_desc', visible: helpAlwaysVisible },
        // Partnerships tab (sibling pass, landed concurrently with this
        // one) -- ALWAYS shown, same as every other entry on this line,
        // per that tab's own buildTabs() comment: "high command sees THIS
        // SAME tab... plus an extra admin lookup section rendered ON TOP
        // of that same screen body", the identical additive-not-replacement
        // posture this Help screen already uses throughout.
        { tabLabelKey: 'tab_partnerships', descKey: 'help_tab_partnerships_desc', visible: helpAlwaysVisible },
        // Widened from canAccessConsole to canOpenPersonRecord (workflow
        // audit finding #1, 2026-08-26) -- the SAME real predicate
        // buildTabs() itself now gates this tab on, so a 'k9.certify'/
        // 'k9.givexp' holder who sees the tab also sees it explained here,
        // never a described-but-invisible or visible-but-unexplained tab.
        { tabLabelKey: 'tab_guide', descKey: 'help_tab_guide_desc', visible: function () { return true; } },
        { tabLabelKey: 'tab_console', descKey: 'help_tab_console_desc', visible: canOpenPersonRecord },
        // SERVER SETTINGS -- one tab now, holding the four sections listed
        // right below it (Theme, Catalogs, Shop, Runtime Control) plus an
        // Overview. Each section keeps its own entry and its own gate.
        { tabLabelKey: 'tab_settings', descKey: 'help_tab_settings_desc', visible: function () { return visibleSettingsSections().length > 0; } },
        // Theme/Shop Locations/Shop Items/Runtime Control each moved off a
        // bare state.viewer.isHighCommand check onto their own
        // hasDelegatedCapability()-based gate (sibling gate-bug-fix pass,
        // landed concurrently with this one) -- these four now show up for
        // a NON-high-command delegate who holds the matching capability
        // too, so this catalog reuses the SAME real function buildTabs()
        // itself gates the tab on, never a second, stale copy of "high
        // command only" for a tab that no longer means that.
        { tabLabelKey: 'tab_theme', descKey: 'help_tab_theme_desc', visible: canManageTabletTheme },
        // ONE entry, because the three catalog editors are one tab now
        // (plan item G).
        { tabLabelKey: 'tab_catalogs', descKey: 'help_tab_catalogs_desc', visible: helpHighCommandOnly },
        // Personnel Roster (docs/history/ROSTER_SPEC.md, Phase B) -- SAME
        // high-command-only gate buildTabs() itself uses for this tab (it
        // sits in the same admin tab group as Cert Tiers/Permission Keys
        // immediately above). ONE entry, because there is now one tab: the
        // K9/Handlers split is a control on the screen, not two tabs.
        { tabLabelKey: 'tab_roster', descKey: 'help_tab_roster_desc', visible: helpHighCommandOnly },
        // ONE entry, because there is one K9 Supply Shop tab now (plan item
        // F). Visible to a holder of EITHER shop capability, matching the
        // tab's own gate -- the two sections inside it are still gated
        // separately.
        { tabLabelKey: 'tab_shop', descKey: 'help_tab_shop_desc', visible: function () { return canManageShopLocations() || canManageShopItems(); } },
        { tabLabelKey: 'tab_runtime_control', descKey: 'help_tab_runtime_control_desc', visible: canManageRuntimeControl },
        { tabLabelKey: 'tab_audit', descKey: 'help_tab_audit_desc', visible: canViewAudit },
    ];

    function buildHelpStartHereSection() {
        var wrap = mk('div', { class: 'k9tablet-home-section' });
        wrap.appendChild(mk('h2', { class: 'k9tablet-section-heading', text: S('help_start_heading') }));

        var stepKeys = state.isK9Model
            ? ['help_start_k9_1', 'help_start_k9_2', 'help_start_k9_3', 'help_start_k9_4', 'help_start_k9_5']
            : ['help_start_handler_1', 'help_start_handler_2', 'help_start_handler_3', 'help_start_handler_4', 'help_start_handler_5', 'help_start_handler_6'];
        for (var i = 0; i < stepKeys.length; i++) {
            wrap.appendChild(mk('p', { class: 'k9tablet-hint', text: S(stepKeys[i]) }));
        }

        if (helpHighCommandOnly()) {
            wrap.appendChild(mk('h3', { class: 'k9tablet-specializations-heading', text: S('help_start_high_command_heading') }));
            wrap.appendChild(mk('p', { class: 'k9tablet-hint', text: S('help_start_high_command_intro') }));
            var hcKeys = ['help_start_high_command_1', 'help_start_high_command_2', 'help_start_high_command_3', 'help_start_high_command_4'];
            for (var j = 0; j < hcKeys.length; j++) {
                wrap.appendChild(mk('p', { class: 'k9tablet-hint', text: S(hcKeys[j]) }));
            }
        }

        return wrap;
    }

    function buildHelpTabsSection() {
        var wrap = mk('div', { class: 'k9tablet-home-section' });
        wrap.appendChild(mk('h2', { class: 'k9tablet-section-heading', text: S('help_tabs_heading') }));
        wrap.appendChild(mk('p', { class: 'k9tablet-hint', text: S('help_tabs_intro') }));

        for (var i = 0; i < HELP_TAB_CATALOG.length; i++) {
            var entry = HELP_TAB_CATALOG[i];
            if (!entry.visible()) continue;
            wrap.appendChild(mk('h3', { class: 'k9tablet-specializations-heading', text: S(entry.tabLabelKey) }));
            wrap.appendChild(mk('p', { class: 'k9tablet-hint', text: S(entry.descKey) }));
        }

        return wrap;
    }

    /** @param {Array<{command:string,adminOnly:boolean,usageKey:string,doesKey:string,needsKey:string,gate:object,defaultKeybind?:string,defaultKeybindConfigurable?:boolean}>} entries */
    /** @param {string} heading @param {string[]} paragraphs -- already
     * resolved (S()/formatTemplate()) text, not keys, since several
     * callers below need to interpolate a live label into one line. */
    function buildHelpTaskBlock(heading, paragraphs) {
        var block = mk('div', { class: 'k9tablet-help-task' });
        block.appendChild(mk('h3', { class: 'k9tablet-specializations-heading', text: heading }));
        for (var i = 0; i < paragraphs.length; i++) {
            block.appendChild(mk('p', { class: 'k9tablet-hint', text: paragraphs[i] }));
        }
        return block;
    }

    function buildHelpTasksSection() {
        var wrap = mk('div', { class: 'k9tablet-home-section' });
        wrap.appendChild(mk('h2', { class: 'k9tablet-section-heading', text: S('help_tasks_heading') }));

        wrap.appendChild(buildHelpTaskBlock(S('help_task_get_certified_heading'), [
            S('help_task_get_certified_1'),
            S('help_task_get_certified_2'),
            formatTemplate(S('help_task_get_certified_3_template'), { certifyLabel: S('certify_label') }),
        ]));

        wrap.appendChild(buildHelpTaskBlock(S('help_task_partner_up_heading'), [
            S('help_task_partner_up_1'),
            S('help_task_partner_up_2'),
            S('help_task_partner_up_3'),
            S('help_task_partner_up_4'),
        ]));

        wrap.appendChild(buildHelpTaskBlock(S('help_task_vehicle_heading'), [
            S('help_task_vehicle_1'),
            S('help_task_vehicle_2'),
            S('help_task_vehicle_3'),
        ]));

        wrap.appendChild(buildHelpTaskBlock(S('help_task_search_heading'), [
            S('help_task_search_1'),
            S('help_task_search_2'),
            S('help_task_search_3'),
        ]));

        wrap.appendChild(buildHelpTaskBlock(S('help_task_treat_heading'), [
            S('help_task_treat_1'),
            S('help_task_treat_2'),
            S('help_task_treat_3'),
        ]));

        // ADDED (this pass): Deploy a Kennel / Use Scent Vision -- see
        // these two keys' own DEFAULT_STRINGS comment for why. UNGATED,
        // same posture as every walkthrough above (Get Certified/Partner
        // Up/Vehicle/Search/Treat): none of those check the underlying
        // feature's own Config.Features flag before rendering either --
        // help_trouble_feature_off_body already covers "the option is not
        // there because a High Command officer turned it off" generically,
        // so these two do not need a special case that no other task
        // walkthrough on this screen has.
        wrap.appendChild(buildHelpTaskBlock(S('help_task_kennel_heading'), [
            S('help_task_kennel_1'),
            S('help_task_kennel_2'),
            S('help_task_kennel_3'),
            S('help_task_kennel_4'),
        ]));

        // THE ONE QUESTION A K9 PLAYER ASKS THAT NOTHING USED TO ANSWER.
        // Every string about reverting was written for the high-command
        // reader looking at somebody else ("this target", "this person"),
        // so the player actually wearing the dog had no way to find out
        // that a way back exists, or who to ask for it. They conclude they
        // are stuck, or bugged, and ask in chat.
        //
        // Shown to EVERYONE, not gated on being the K9 right now: the
        // people most likely to look this up are deciding whether to
        // become one, and someone already reverted may want to know how it
        // worked. Nothing here is admin-only information.
        wrap.appendChild(buildHelpTaskBlock(S('help_task_stop_being_k9_heading'), [
            S('help_task_stop_being_k9_1'),
            S('help_task_stop_being_k9_2'),
            S('help_task_stop_being_k9_3'),
            S('help_task_stop_being_k9_4'),
        ]));

        wrap.appendChild(buildHelpTaskBlock(S('help_task_scent_vision_heading'), [
            S('help_task_scent_vision_1'),
            S('help_task_scent_vision_2'),
            S('help_task_scent_vision_3'),
        ]));

        // ADDITIVE ONLY, the same posture the deleted admin command table
        // used to take -- but each of these four gets its OWN real gate
        // rather than one blanket flag, because each is genuinely
        // different. (The blanket helper this block used to share,
        // helpSeesAdminCommands(), was deleted with the last of its
        // callers: four precise gates strictly beat one loose one, since
        // the loose one showed a heading to delegates who could not use a
        // single row underneath it.)
        //   - Certify Someone: isHighCommand OR the k9.certify capability
        //     (server/certifications/'s own rank-based-certifier-or-grant
        //     shape).
        //   - Turn Someone Into a K9: TRUE high command only, verified
        //     directly against server/tablet.lua's tabletAssignK9Role (a
        //     thin wrapper over server/appearance.lua's ApplyK9PedRole,
        //     which "already re-verifies IsHighCommand internally" per
        //     that function's own comment) -- there is no delegated
        //     capability for this action at all, unlike certify/audit/xp.
        //   - Turn a Feature On or Off: canManageRuntimeControl() -- the
        //     SAME hasDelegatedCapability('k9.runtimecontrol') gate the
        //     Runtime Control tab itself now uses.
        //   - Check What Someone Did: canViewAudit() -- the SAME gate the
        //     Audit Trail tab itself uses, already isHighCommand-inclusive.
        if (helpHasCapability('k9.certify')) {
            var certifySomeoneSteps = [
                S('help_task_hc_certify_someone_1'),
                formatTemplate(S('help_task_hc_certify_someone_2_template'), { certifyLabel: S('certify_label') }),
            ];
            // TWO HIGH-COMMAND-ONLY LINES USED TO FOLLOW, pointing at the
            // Guided Flows "Set Up a New Handler" flow and listing its
            // steps. That flow has been retired: every step it sequenced is
            // rendered on the Person screen, in that order, which is where
            // steps 1 and 2 above already send the reader. Dropping them
            // also drops a long-standing split in this walkthrough -- a
            // 'k9.certify' delegate saw a shorter version than high command
            // did, of a task both can do the same way.
            wrap.appendChild(buildHelpTaskBlock(S('help_task_hc_certify_someone_heading'), certifySomeoneSteps));
        }

        if (helpHighCommandOnly()) {
            wrap.appendChild(buildHelpTaskBlock(S('help_task_hc_assign_k9_heading'), [
                S('help_task_hc_assign_k9_1'),
                formatTemplate(S('help_task_hc_assign_k9_2_template'), { assignLabel: S('role_assign_label'), certifyLabel: S('certify_label') }),
                formatTemplate(S('help_task_hc_assign_k9_3_template'), { revertLabel: S('role_revert_label') }),
            ]));
        }

        if (canManageRuntimeControl()) {
            wrap.appendChild(buildHelpTaskBlock(S('help_task_hc_toggle_feature_heading'), [
                S('help_task_hc_toggle_feature_1'),
                S('help_task_hc_toggle_feature_2'),
                formatTemplate(S('help_task_hc_settings_sections_template'), { sections: visibleSettingsSections().map(function (section) { return S(section.labelKey); }).join(', ') }),
            ]));
        }

        if (canViewAudit()) {
            wrap.appendChild(buildHelpTaskBlock(S('help_task_hc_check_history_heading'), [
                S('help_task_hc_check_history_1'),
                S('help_task_hc_check_history_2'),
                S('help_task_hc_check_history_3'),
            ]));
        }

        return wrap;
    }

    /** Every (title, body) pair below is role-agnostic ON PURPOSE -- a
     * high-command viewer can hit a certification-flavored refusal just as
     * easily as an ordinary handler can hit an authorization-flavored one
     * (e.g. attempting an action a colleague's grant covers but theirs
     * does not), so this list is never filtered by role, unlike every
     * other section on this screen. */
    function buildHelpTroubleshootingSection() {
        var wrap = mk('div', { class: 'k9tablet-home-section' });
        wrap.appendChild(mk('h2', { class: 'k9tablet-section-heading', text: S('help_trouble_heading') }));
        wrap.appendChild(mk('p', { class: 'k9tablet-hint', text: S('help_trouble_intro') }));

        var pairs = [
            ['help_trouble_no_k9_access_title', 'help_trouble_no_k9_access_body'],
            ['help_trouble_not_certified_title', 'help_trouble_not_certified_body'],
            ['help_trouble_feature_off_title', 'help_trouble_feature_off_body'],
            ['help_trouble_needs_grant_title', 'help_trouble_needs_grant_body'],
            ['help_trouble_rate_limited_title', 'help_trouble_rate_limited_body'],
            ['help_trouble_self_cert_disabled_title', 'help_trouble_self_cert_disabled_body'],
            ['help_trouble_target_offline_title', 'help_trouble_target_offline_body'],
            ['help_trouble_insufficient_authorization_title', 'help_trouble_insufficient_authorization_body'],
        ];
        for (var i = 0; i < pairs.length; i++) {
            wrap.appendChild(mk('h3', { class: 'k9tablet-specializations-heading', text: S(pairs[i][0]) }));
            wrap.appendChild(mk('p', { class: 'k9tablet-hint', text: S(pairs[i][1]) }));
        }

        return wrap;
    }

    /** THE HELP SCREEN -- see this block's own header for the full design.
     * No loading/error gate on state.myRecord (unlike Home/My Record):
     * every section here is either static teaching prose or already
     * null-safe against a not-yet-loaded state.myRecord (homeCertificationCounts()/
     * commandReferenceStatus() both already tolerate that -- see their own
     * doc comments), the same posture buildCommandReferenceScreen() above
     * already takes for the identical reason. */
    /**
     * THE GUIDE -- how to do things, then every command (plan item H).
     *
     * The teaching sections first (they are what someone who does not know
     * what to do next needs), then the searchable command table underneath
     * for someone who knows roughly what they want and needs the exact
     * command. One tab, one table, one filter.
     * @returns {Element}
     */
    function buildGuideScreen() {
        var wrap = mk('div', { class: 'k9tablet-screen k9tablet-help' });
        var keys = buildKeysListSection();
        if (keys) wrap.appendChild(keys);
        wrap.appendChild(buildHelpScreen());
        wrap.appendChild(buildCommandReferenceScreen());
        return wrap;
    }

    /**
     * YOUR KEYS -- every key in one short list, at the top of the Guide (the
     * owner's rework pass: "do not remove keybinds, just make a list").
     *
     * Built from COMMAND_REFERENCE -- the same entries, and the same
     * "is this feature switched on here" test (commandReferenceIsVisible()),
     * as the full command table further down -- so it never lists a key
     * for something this server has turned off, and never a key that does
     * not exist. tests/keybindreference_spec.lua checks every
     * defaultKeybind against the key the resource actually registers.
     *
     * The first two rows are the gateways to everything else: ox_lib's
     * radial menu (the K9 menu lives in it) and ox_target's third eye. They
     * belong to those resources, not this one, so they are shown as their
     * shipped defaults.
     *
     * Defaults only: FiveM lets each player rebind any of these, and the
     * page cannot see their personal bindings -- the intro line says so.
     * @returns {HTMLElement|null}
     */
    function buildKeysListSection() {
        var rows = [];
        if (commandReferenceIsVisible({ gate: { kind: 'open', featureKey: 'RadialMenu' } })) {
            rows.push({ key: S('keys_name_radial'), label: S('keys_action_radial') });
        }
        rows.push({ key: S('keys_name_third_eye'), label: S('keys_action_third_eye') });
        for (var i = 0; i < COMMAND_REFERENCE.length; i++) {
            var entry = COMMAND_REFERENCE[i];
            if (typeof entry.defaultKeybind !== 'string' || entry.defaultKeybind.length === 0) continue;
            if (typeof entry.keyLabelKey !== 'string') continue;
            if (!commandReferenceIsVisible(entry)) continue;
            rows.push({ key: entry.defaultKeybind, label: S(entry.keyLabelKey) });
        }

        var section = mk('div', { class: 'k9tablet-home-section k9tablet-keys-section' });
        section.appendChild(mk('h2', { class: 'k9tablet-section-heading', text: S('keys_heading') }));
        section.appendChild(mk('p', { class: 'k9tablet-hint', text: S('keys_intro') }));
        var list = mk('ul', { class: 'k9tablet-keys-list' });
        for (var r = 0; r < rows.length; r++) {
            var li = mk('li', { class: 'k9tablet-keys-row' });
            li.appendChild(mk('kbd', { class: 'k9tablet-key', text: rows[r].key }));
            li.appendChild(mk('span', { class: 'k9tablet-keys-label', text: rows[r].label }));
            list.appendChild(li);
        }
        section.appendChild(list);
        return section;
    }

    function buildHelpScreen() {
        var wrap = mk('div', { class: 'k9tablet-help' });
        wrap.appendChild(mk('h2', { class: 'k9tablet-section-heading', text: S('help_heading') }));
        wrap.appendChild(mk('p', { class: 'k9tablet-hint', text: S('help_intro_line1') }));

        var roleNoteKey = state.isK9Model ? 'help_role_note_k9'
            : (homeCertificationCounts().active > 0 ? 'help_role_note_handler' : 'help_role_note_uncertified');
        var roleNoteText = S(roleNoteKey);
        if (helpHighCommandOnly()) {
            roleNoteText = roleNoteText + ' ' + S('help_role_note_high_command_suffix');
        }
        wrap.appendChild(mk('p', { class: 'k9tablet-muted', text: roleNoteText }));

        wrap.appendChild(buildHelpStartHereSection());
        wrap.appendChild(buildHelpTabsSection());
        wrap.appendChild(buildHelpTasksSection());
        wrap.appendChild(buildHelpTroubleshootingSection());

        return wrap;
    }

    // ---- My Record screen ----


    function xpLine(xp, tierLabel) {
        if (xp === null || xp === undefined) return S('xp_tier_unknown');
        var line = String(xp);
        if (typeof tierLabel === 'string' && tierLabel.length > 0) line += ' — ' + tierLabel;
        return line;
    }

    /** Read-only certification list -- used both in My Record (no actions)
     * and, with onAction set, in the admin Person screen. */
    function buildCertificationList(list, onAction, opts) {
        opts = opts || {};
        var wrap = mk('div', { class: 'k9tablet-cert-list' });
        if (!list || list.length === 0) {
            wrap.appendChild(mk('p', { class: 'k9tablet-muted', text: S('no_certifications') }));
            return wrap;
        }
        for (var i = 0; i < list.length; i++) {
            wrap.appendChild(buildCertificationRow(list[i], onAction, opts));
        }
        return wrap;
    }

    /**
     * @param {object} entry
     * @param {((kind:string, departmentKey:string, extra?:string) => void)|null} onAction
     * @param {{showRosterControls?:boolean}} [opts] -- showRosterControls
     *   is set ONLY by buildPersonScreen()'s own call site (docs/history/ROSTER_SPEC.md,
     *   Phase B) -- My Record's read-only call and the guided flows' own
     *   calls never set it, so this stays exactly what it already rendered
     *   for them, byte for byte.
     */
    function buildCertificationRow(entry, onAction, opts) {
        opts = opts || {};
        var row = mk('div', { class: 'k9tablet-cert-row' });
        row.appendChild(mk('span', { class: 'k9tablet-cert-dept', text: entry.departmentLabel }));
        row.appendChild(mk('span', { class: 'k9tablet-cert-status k9tablet-cert-status--' + (entry.active ? 'yes' : 'no'), text: entry.active ? S('certified_yes') : S('certified_no') }));
        if (entry.active && typeof entry.grantedBy === 'string' && entry.grantedBy.length > 0) {
            // Prefers the resolved display name (coder-backend's additive
            // `grantedByName` sibling, server/tablet.lua's
            // BuildCertificationsArray) over the raw citizenid -- readability
            // pass, never a second source of truth: grantedBy itself is
            // still the value every mutation keys off, this only changes
            // what TEXT is shown for it.
            var granterText = (typeof entry.grantedByName === 'string' && entry.grantedByName.length > 0) ? entry.grantedByName : entry.grantedBy;
            row.appendChild(mk('span', { class: 'k9tablet-cert-granter', text: granterText }));
        }

        // TIER / EXPIRY / SPECIALIZATIONS -- only meaningful for an ACTIVE
        // certification (an inactive/never-held row has none of these to
        // show, matching server/tablet.lua's own BuildCertificationsArray
        // contract: tier/expiresAtUnix/specializations are only populated
        // for `active == true` rows). Read-only in My Record (onAction is
        // null); with real controls on the Person screen when the viewer
        // holds k9.certify (see buildCertificationDetail's own doc comment
        // for exactly which controls need which additional preconditions).
        if (entry.active) {
            row.appendChild(buildCertificationDetail(entry, onAction, opts));
        }

        // PERSONNEL ROSTER ROLE + CALLSIGN (docs/history/ROSTER_SPEC.md, Phase B) --
        // high-command-only (matches qbx_k9unit:server:rosterSetPersonnelRole/
        // rosterSetCallsign's own re-verified IsHighCommand gate exactly),
        // and only for an ACTIVE certification (RosterAssignPersonnelRole's
        // own 'not_certified' precondition) -- see buildRosterRoleSection()'s
        // own header.
        if (entry.active && opts.showRosterControls && state.viewer.isHighCommand) {
            row.appendChild(buildRosterRoleSection(entry));
        }

        if (onAction) {
            if (entry.active) {
                // FIRE, in the owner's own vocabulary (this pass) -- SAME
                // Decertify button/action immediately below, never a second
                // control: this is a VISIBLE warning shown directly above
                // it, not a new mutation path. docs/history/ROSTER_SPEC.md §6/§7:
                // "Firing yourself by accident... the roster UI must not
                // hide that this is the same rule" as a self-typed
                // /k9decertify -- shown ONLY here (opts.showRosterControls),
                // so the Console/Online-Players entry points render exactly
                // as before this pass.
                if (opts.showRosterControls && state.viewer.isHighCommand) {
                    var fireNotice = mk('div', { class: 'k9tablet-roster-fire-notice' });
                    fireNotice.appendChild(mk('span', { class: 'k9tablet-roster-fire-label', text: S('roster_fire_label') }));
                    fireNotice.appendChild(mk('p', { class: 'k9tablet-warning', text: S('roster_fire_confirm_prompt') }));
                    if (state.person && state.person.citizenid === state.viewer.citizenid) {
                        fireNotice.appendChild(mk('p', { class: 'k9tablet-warning', text: S('roster_fire_self_warning') }));
                    }
                    row.appendChild(fireNotice);
                }
                row.appendChild(mkConfirmButton(S('decertify_label'), 'k9tablet-btn k9tablet-btn--danger', function () {
                    onAction('decertify', entry.departmentKey);
                }, { disabled: state.pendingAction }));
            } else {
                row.appendChild(buildCertifyAsControl(entry, onAction));
            }
        }
        return row;
    }

    /**
     * CERTIFY AS HANDLER OR AS K9 -- one choice, one button.
     *
     * A certification is held by BOTH halves of a team: the human handler
     * and the player who plays the dog. Certifying used to always turn the
     * person into the first configured dog model, so a new handler got
     * turned into a dog, and a K9 of a particular breed took Certify AND a
     * separate Assign K9 Role. The picker says which is meant: "Handler"
     * (the default) leaves how they look alone; a breed certifies them as a
     * K9 of that breed in the same step. server/certifications/core.lua's
     * GrantCertification re-validates the model either way.
     *
     * No models configured -> no picker, just Certify (a handler).
     * @param {object} entry
     * @param {(kind:string, departmentKey:string, extra?:string) => void} onAction
     */
    function buildCertifyAsControl(entry, onAction) {
        var wrap = mk('div', { class: 'k9tablet-certify-as' });
        var asSelect = null;
        if (state.peds && state.peds.length > 0) {
            asSelect = mk('select', { class: 'k9tablet-certify-as-select', attrs: { 'aria-label': S('certify_as_label') } });
            var handlerOption = mk('option', { text: S('certify_as_handler_option') });
            handlerOption.setAttribute('value', '');
            asSelect.appendChild(handlerOption);
            for (var i = 0; i < state.peds.length; i++) {
                var ped = state.peds[i];
                if (!ped || typeof ped.model !== 'string' || ped.model.length === 0) continue;
                var breed = (typeof ped.label === 'string' && ped.label.length > 0) ? ped.label : ped.model;
                var option = mk('option', { text: formatTemplate(S('certify_as_k9_option_template'), { breed: breed }) });
                option.setAttribute('value', ped.model);
                asSelect.appendChild(option);
            }
            asSelect.value = '';
            wrap.appendChild(asSelect);
        }
        wrap.appendChild(mkButton(S('certify_label'), 'k9tablet-btn', function () {
            var chosen = asSelect ? asSelect.value : '';
            onAction('certify', entry.departmentKey, chosen ? chosen : undefined);
        }, { disabled: state.pendingAction }));
        if (asSelect) {
            wrap.appendChild(mk('p', { class: 'k9tablet-muted k9tablet-hint', text: S('certify_as_hint') }));
        }
        return wrap;
    }

    /**
     * Tier / expiry / specializations detail block for an ACTIVE
     * certification row -- see buildCertificationRow's own call site
     * comment for when this is read-only vs. controlled.
     *
     * TIER ASSIGNMENT IS ADDITIONALLY GATED ON state.certTiers BEING
     * LOADED (loadCertTiers(), called from openPerson() below) -- a real,
     * disclosed scope decision, not an oversight: server/certtiers.lua's
     * own tablet:certTiersList/CanManageCertTiers is HIGH-COMMAND ONLY
     * today (narrower than the k9.certify/IsEligibleCertifier gate that
     * actually authorizes tablet:setCertificationTier server-side -- see
     * that file's own header, "a follow-up pass can widen this... tracked
     * here, not silently done"). Rather than render a tier picker with NO
     * real choices behind it for a plain certifier-grade officer who is
     * not high command (a control that would always fail 'denied' the
     * moment loadCertTiers() itself gets refused), this falls back to
     * read-only tier text for that caller -- honest about what THIS
     * SESSION can actually do, never a button that looks live but cannot
     * work. Renew/specialization controls have no such extra gate (their
     * own server-side authorization is k9.certify, matching
     * certify/decertify already on this same row).
     * @param {object} entry
     * @param {((kind:string, departmentKey:string, extra?:string) => void)|null} onAction
     */
    function buildCertificationDetail(entry, onAction, opts) {
        var wrap = mk('div', { class: 'k9tablet-cert-detail' });

        // TIERS ARE GONE FROM THE TABLET (owner: tiers and specializations
        // merged into roles). Only the expiry is left on this line.
        var tierLine = mk('div', { class: 'k9tablet-cert-tier-line' });
        if (entry.expired) {
            tierLine.appendChild(mk('span', { class: 'k9tablet-cert-expired-badge', text: S('expired_badge') }));
        } else if (typeof entry.expiresAtUnix === 'number') {
            tierLine.appendChild(mk('span', {
                class: 'k9tablet-cert-expiry',
                text: S('expires_label') + ': ' + new Date(entry.expiresAtUnix * 1000).toLocaleDateString(),
            }));
        }
        if (tierLine.children && tierLine.children.length > 0) wrap.appendChild(tierLine);

        if (onAction) {
            wrap.appendChild(mkButton(S('renew_label'), 'k9tablet-btn', function () {
                onAction('renew', entry.departmentKey);
            }, { disabled: state.pendingAction }));
        }

        wrap.appendChild(buildSpecializationsBlock(entry, onAction, opts && opts.roleXp));

        return wrap;
    }

    /**
     * Specializations sub-list for one active certification row -- the
     * held set (entry.specializations, a plain string[] of keys) plus, for
     * a controlled row, a picker over whatever this resource's REAL
     * specialization catalog (state.specializations ==
     * Config.K9Specializations, sent verbatim in tablet:open -- see
     * client/tablet.lua's own header) currently contains that this
     * citizenid does not already hold. Never a hardcoded
     * narcotics/explosives/patrol list.
     * @param {object} entry
     * @param {((kind:string, departmentKey:string, extra?:string) => void)|null} onAction
     */
    function buildSpecializationsBlock(entry, onAction, roleXp) {
        var wrap = mk('div', { class: 'k9tablet-specializations' });
        wrap.appendChild(mk('span', { class: 'k9tablet-specializations-heading', text: S('specializations_heading') }));

        var held = Array.isArray(entry.specializations) ? entry.specializations : [];
        if (held.length === 0) {
            wrap.appendChild(mk('p', { class: 'k9tablet-muted', text: S('no_specializations') }));
        } else {
            for (var i = 0; i < held.length; i++) {
                wrap.appendChild(buildSpecializationRow(held[i], entry, onAction, roleXp));
            }
        }

        if (onAction) {
            var catalog = (state.specializations && typeof state.specializations === 'object') ? state.specializations : {};
            var available = [];
            for (var key in catalog) {
                if (Object.prototype.hasOwnProperty.call(catalog, key) && held.indexOf(key) === -1) {
                    available.push(key);
                }
            }
            if (available.length > 0) {
                var addRow = mk('div', { class: 'k9tablet-specialization-add' });
                var select = mk('select', { class: 'k9tablet-specialization-select k9tablet-role-select' });
                for (var j = 0; j < available.length; j++) {
                    var needXp = roleXpRequired(available[j]);
                    var option = mk('option', { text: specializationDisplayLabel(available[j]) + (needXp > 0 ? ' (' + formatTemplate(S('role_option_xp_template'), { xp: needXp }) + ')' : '') });
                    option.setAttribute('value', available[j]);
                    select.appendChild(option);
                }
                addRow.appendChild(select);
                addRow.appendChild(mkButton(S('grant_label'), 'k9tablet-btn', function () {
                    var chosen = select.value;
                    if (!chosen) return;
                    onAction('grantSpecialization', entry.departmentKey, chosen);
                }, { disabled: state.pendingAction }));
                wrap.appendChild(addRow);
            }
        }

        return wrap;
    }

    /** @param {string} key @param {object} entry @param {((kind:string, departmentKey:string, extra?:string) => void)|null} onAction */
    function buildSpecializationRow(key, entry, onAction, roleXp) {
        var row = mk('div', { class: 'k9tablet-specialization-row' });
        row.appendChild(mk('span', { class: 'k9tablet-specialization-label', text: specializationDisplayLabel(key) }));
        // A role switches on once the holder's XP reaches its requirement.
        if (typeof roleXp === 'number') {
            var need = roleXpRequired(key);
            var active = roleXp >= need;
            row.appendChild(mk('span', {
                class: 'k9tablet-feature-state k9tablet-feature-state--' + (active ? 'available' : 'requires_grant_missing'),
                text: active ? S('role_status_active') : formatTemplate(S('role_status_locked_template'), { xp: need }),
            }));
        }
        if (onAction) {
            row.appendChild(mkConfirmButton(S('revoke_label'), 'k9tablet-btn k9tablet-btn--danger', function () {
                onAction('revokeSpecialization', entry.departmentKey, key);
            }, { disabled: state.pendingAction }));
        }
        return row;
    }

    /**
     * THE ONE DECLARED ORDER every domain-aware feature view in this file
     * renders in -- buildMyFeaturesList() (My Record) reads it directly;
     * personFeatureNameCellClass()/buildPersonFeatureRow() (the Person
     * screen's admin table) read FEATURE_DOMAIN_STYLE below, keyed off the
     * SAME set. Adding a twelfth domain someday is a one-line addition
     * here (plus its own 'feature_group_<domain>_heading' locale key) --
     * never a new `if`/`else if` branch anywhere else in this file.
     * MUST stay a superset of every key server/tablet.lua's own
     * FEATURE_DOMAINS table can send; a domain string NOT in this list
     * still renders (see groupFeaturesByDomain()'s own 'other' bucket),
     * just without its own heading/style, so an out-of-sync client never
     * loses a feature row outright.
     */
    var FEATURE_DOMAIN_ORDER = [
        'scent', 'search', 'vision', 'combat', 'movement', 'wellbeing',
        'progression', 'gear', 'training', 'admin', 'integration', 'vehicle',
    ];

    /**
     * Per-domain rendering STYLE for buildMyFeaturesList()/
     * buildPersonFeatureRow() -- 'color' (a domain-tinted modifier class
     * on an otherwise ordinary badge row) or 'text' (the state badge is
     * replaced entirely by one full, locale-authored sentence -- see
     * buildVehicleFeatureRow()/vehicleFeatureSentence()). Any domain NOT
     * listed here (every one added this pass beyond the original two)
     * defaults to 'plain' -- the ordinary badge row, no accent -- which is
     * also the automatic, safe fallback for a domain string this client
     * has never heard of at all. Owner's own original distinction
     * ("more color based on all scent stuff vehicle related is more text
     * based") was specific to these two; nothing about the newer ten
     * domains asked for a third visual treatment, so they all share the
     * ordinary style rather than inventing one nobody requested.
     */
    var FEATURE_DOMAIN_STYLE = { scent: 'color', vehicle: 'text' };

    /** Optional extra hint paragraph shown under a domain's own heading on
     * the My Record screen -- keyed the same way as FEATURE_DOMAIN_STYLE.
     * Absent for a domain simply means no extra hint line, never an error. */
    var FEATURE_DOMAIN_HINT_KEY = { scent: 'feature_group_scent_hint' };

    /** @param {string} domain @returns {string} the DEFAULT_STRINGS/locale key for this domain's own section heading */
    function featureGroupHeadingKey(domain) {
        return 'feature_group_' + domain + '_heading';
    }

    /**
     * FULL DOMAIN GROUPING (owner-directed, 2026-08-26: "same with
     * features and sub features" -- extending the original, narrower
     * "more color based on all scent stuff vehicle related is more text
     * based" ask to EVERY Config.Features key, not just those two).
     * `feature.category` is a small, hand-maintained tag sent from
     * server/tablet.lua's own FEATURE_DOMAINS table, never guessed here
     * from a feature's name string. DATA-DRIVEN: this file does not
     * hardcode which domain STRINGS exist -- it walks FEATURE_DOMAIN_ORDER
     * below (the client's own STABLE, DECLARED rendering order) and buckets
     * whatever `category` each feature actually carries; a domain string
     * this order does not recognize (an older client talking to a newer
     * server that grew a twelfth domain, or a genuinely unset category)
     * falls into the SAME 'other' bucket as `category === null` always
     * has -- rendered last, under a generic heading, NEVER silently
     * dropped. ORDER-PRESERVING within each bucket, so this is purely a
     * display grouping, never a re-sort of anything the server itself
     * ordered.
     * @param {Array<object>} features
     * @returns {Object<string, Array<object>>} -- keyed by every domain in FEATURE_DOMAIN_ORDER that had at least one match, PLUS 'other'
     */
    function groupFeaturesByDomain(features) {
        var buckets = {};
        var other = [];
        for (var i = 0; i < features.length; i++) {
            var f = features[i];
            var domain = (f && typeof f.category === 'string' && FEATURE_DOMAIN_ORDER.indexOf(f.category) !== -1) ? f.category : null;
            if (domain) {
                if (!buckets[domain]) buckets[domain] = [];
                buckets[domain].push(f);
            } else {
                other.push(f);
            }
        }
        buckets.other = other;
        return buckets;
    }

    /**
     * HIDE WHAT THE SERVER HAS SWITCHED OFF (2026-09-01, owner's own words:
     * "make it where if something is turned off in the config nothing on
     * the tablet shows up").
     *
     * A feature whose Config.Features key is false is not a thing you can
     * be granted, earn, or be blocked from -- it does not exist on this
     * server. Listing it with a "Disabled server-wide" badge told every
     * reader about a capability they can never have, on every screen,
     * forever. On a server that switches a few families off, that is a
     * large fraction of every list being noise.
     *
     * THE ONE PLACE THIS MUST NOT APPLY is Runtime Control. That screen is
     * where high command turns features on and off, so hiding the off ones
     * there would make them unreachable -- you could switch a feature off
     * and then have no way to ever switch it back on. It reads its own
     * separate tablet:runtimeListFeatures payload and never calls this, so
     * that screen keeps showing everything, which is exactly right: it is
     * the inventory, these are the in-use lists.
     *
     * Deliberately keyed on 'global_off' ONLY. 'blocked',
     * 'not_certified' and 'requires_grant_missing' all stay visible --
     * those describe a real feature this person could have, and hiding
     * them would answer "why can't I do X" with silence instead of a
     * reason. 'unknown' also stays: a record that has not resolved yet must
     * never be mistaken for a server that has switched everything off (see
     * commandReferenceStatus()'s own note on exactly that bug).
     * @param {Array<object>} features
     * @returns {Array<object>} the same rows, minus the ones this server has off
     */
    function withoutGloballyDisabled(features) {
        var out = [];
        for (var i = 0; i < features.length; i++) {
            var f = features[i];
            if (!f) continue;
            // Two independent ways a row can say "off server-wide", because
            // the two payloads differ: myFeatures carries only `state`,
            // while the richer person-features rows also carry an explicit
            // `globallyEnabled` boolean. Checking both means one helper
            // serves both lists without either caller having to know which
            // shape it holds.
            if (f.state === 'global_off') continue;
            if (f.globallyEnabled === false) continue;
            out.push(f);
        }
        return out;
    }

    function buildMyFeaturesList() {
        var wrap = mk('div', { class: 'k9tablet-feature-list' });
        // Your own list shows only what you can use right now (owner's
        // choice: show what you are certified in, nothing else). High
        // command's view of SOMEONE ELSE's abilities stays complete, because
        // that screen is where they block and unblock them.
        var features = withoutGloballyDisabled((state.myRecord && state.myRecord.myFeatures) || []).filter(function (f) {
            return f.state === 'available';
        });
        if (features.length === 0) {
            wrap.appendChild(mk('p', { class: 'k9tablet-muted', text: S('no_abilities') }));
            return wrap;
        }

        var grouped = groupFeaturesByDomain(features);
        var hasDomainSections = FEATURE_DOMAIN_ORDER.some(function (domain) { return grouped[domain] && grouped[domain].length > 0; });

        // ONE PASS OVER THE STABLE, DECLARED ORDER -- every real domain
        // renders the SAME way (a heading, then ordinary badge rows)
        // EXCEPT the two the owner originally asked to look different
        // (FEATURE_DOMAIN_STYLE below): 'scent' stays colour-forward,
        // 'vehicle' stays text-forward (a full sentence, no badge). Adding
        // an accent for a FUTURE domain is a one-line addition to that
        // table, never a new `if` branch here.
        FEATURE_DOMAIN_ORDER.forEach(function (domain) {
            var rows = grouped[domain];
            if (!rows || rows.length === 0) return;

            var style = FEATURE_DOMAIN_STYLE[domain] || 'plain';
            wrap.appendChild(mk('h3', { class: 'k9tablet-feature-group-heading k9tablet-feature-group-heading--' + domain, text: S(featureGroupHeadingKey(domain)) }));
            var hintKey = FEATURE_DOMAIN_HINT_KEY[domain];
            if (hintKey) {
                wrap.appendChild(mk('p', { class: 'k9tablet-muted k9tablet-hint', text: S(hintKey) }));
            }

            if (style === 'text') {
                // VEHICLE-STYLE -- text-forward. No colour badge at all: a
                // full, locale-authored sentence carries both what the
                // ability is and its current state, since this content is
                // about what happens rather than about telling several
                // things apart at a glance.
                var textGroup = mk('div', { class: 'k9tablet-feature-group k9tablet-feature-group--' + domain });
                for (var t = 0; t < rows.length; t++) {
                    textGroup.appendChild(buildVehicleFeatureRow(rows[t]));
                }
                wrap.appendChild(textGroup);
            } else {
                // 'color' (scent) and 'plain' (every other real domain) --
                // the SAME ordinary badge row either way; 'color' only
                // adds a domain-tinted modifier class for
                // html/tablet.css's own accent styling (see
                // .k9tablet-feature-group--scent), which a 'plain' domain
                // simply has no CSS rule for, so it renders identically to
                // the pre-grouping default row.
                var group = mk('div', { class: 'k9tablet-feature-group k9tablet-feature-group--' + domain });
                for (var i = 0; i < rows.length; i++) {
                    var row = buildMyFeatureRow(rows[i]);
                    if (style === 'color') row.className += ' k9tablet-feature-row--' + domain;
                    group.appendChild(row);
                }
                wrap.appendChild(group);
            }
        });

        if (grouped.other.length > 0) {
            if (hasDomainSections) {
                wrap.appendChild(mk('h3', { class: 'k9tablet-feature-group-heading', text: S('feature_group_other_heading') }));
            }
            for (var k = 0; k < grouped.other.length; k++) {
                wrap.appendChild(buildMyFeatureRow(grouped.other[k]));
            }
        }

        return wrap;
    }

    function buildMyFeatureRow(feature) {
        var row = mk('div', { class: 'k9tablet-feature-row' });
        row.appendChild(mk('span', { class: 'k9tablet-feature-label', text: featureLabel(feature) }));
        row.appendChild(mk('span', { class: 'k9tablet-feature-state k9tablet-feature-state--' + feature.state, text: featureStateLabel(feature.state) }));
        if (feature.actionable && feature.state === 'available') {
            row.appendChild(mkButton(S('use_label'), 'k9tablet-btn', function () {
                triggerFeature(feature.key);
            }, { disabled: state.pendingAction }));
        }
        return row;
    }

    /** @param {{key:string,label?:string,state:string}} feature @returns {string} a full, plain-language sentence (never a colour badge) describing this vehicle-domain ability and its current state -- see buildMyFeaturesList()'s own "VEHICLE" comment. */
    function vehicleFeatureSentence(feature) {
        return formatTemplate(S('feature_vehicle_sentence_template'), {
            feature: featureLabel(feature),
            state: featureStateLabel(feature.state),
        });
    }

    /** Vehicle-domain equivalent of buildMyFeatureRow() -- same actionable/
     * trigger-button behaviour, but the label+badge pair is replaced with
     * one full sentence (never a colour badge) per the "more text-based"
     * ask. @param {object} feature */
    function buildVehicleFeatureRow(feature) {
        var row = mk('div', { class: 'k9tablet-feature-row k9tablet-feature-row--vehicle' });
        row.appendChild(mk('p', { class: 'k9tablet-feature-vehicle-sentence', text: vehicleFeatureSentence(feature) }));
        if (feature.actionable && feature.state === 'available') {
            row.appendChild(mkButton(S('use_label'), 'k9tablet-btn', function () {
                triggerFeature(feature.key);
            }, { disabled: state.pendingAction }));
        }
        return row;
    }

    // ---- Console (roster) screen ----

    function buildConsoleScreen() {
        var wrap = mk('div', { class: 'k9tablet-screen' });

        // NARROWED-ACCESS NOTICE (workflow audit finding #1, 2026-08-26) --
        // a 'k9.certify'/'k9.givexp' holder who lacks 'k9.audit'/high
        // command reaches this screen via canOpenPersonRecord(), but the
        // listings below stay k9.audit/high-command only (server/tablet.lua's
        // CallerHasConsoleAccess). This tells that viewer why they only get
        // the open-by-citizen-ID half of the search box.
        var fullAccess = canAccessConsole();
        if (!fullAccess) {
            wrap.appendChild(mk('p', { class: 'k9tablet-muted', text: S('console_person_only_notice') }));
        }

        wrap.appendChild(buildFindPersonBar(fullAccess));

        // "OPEN MY OWN RECORD" (2026-09-01, owner's live testing: "as high
        // command i cant certify myself"). Nothing in this tablet shows a
        // viewer their own citizen ID, so self-certification had no door
        // in the UI. Fills in state.viewer.citizenid and opens the same
        // Person screen; the server re-authorizes everything, and refuses a
        // self-certify outright when Config.AllowSelfCertification is off.
        //
        // ITS OWN ROW, NOT INSIDE THE SEARCH BAR -- findEnterSubmitTarget()
        // only gives a text field an Enter-to-submit target while its
        // container holds exactly one button, so a second button beside
        // Open would silently break Enter in the search box.
        if (state.viewer && state.viewer.citizenid) {
            var selfBar = mk('div', { class: 'k9tablet-toolbar k9tablet-self-record-toolbar' });
            selfBar.appendChild(mk('p', { class: 'k9tablet-hint k9tablet-open-by-id-hint', text: S('open_my_own_record_hint') }));
            selfBar.appendChild(mkButton(S('open_my_own_record_label'), 'k9tablet-btn', function () {
                openPerson(state.viewer.citizenid, state.viewer.name || null);
            }));
            wrap.appendChild(selfBar);
        }

        if (fullAccess) {
            // One Refresh for both result lists, in their own row (see the
            // Enter-key note above for why it is not beside Open).
            var refreshBar = mk('div', { class: 'k9tablet-toolbar k9tablet-find-person-refresh' });
            refreshBar.appendChild(mkButton(S('refresh_label'), 'k9tablet-btn', function () {
                loadOnlinePlayers(state.onlinePlayersQuery);
                loadRoster(state.rosterQuery);
            }));
            wrap.appendChild(refreshBar);

            wrap.appendChild(buildOnlinePlayersSection());
            wrap.appendChild(buildRosterResultsSection());
        }

        // WHO HOLDS A PER-DOG OVERRIDE (plan item D) -- the one unique part
        // of the old K9 Overrides tab, beside the other "who has what"
        // lists. High command only, matching the gate that tab had.
        if (state.viewer && state.viewer.isHighCommand) {
            wrap.appendChild(buildK9ProfilesOverviewSection());
        }

        return wrap;
    }

    /**
     * ONE SEARCH BOX TO FIND ANYONE (the owner's rework pass: "make the
     * workflows simpler"). This screen used to have three separate boxes
     * -- search online players, search the certified roster, and open by
     * exact citizen ID -- and the operator had to know which one could
     * find the person they wanted (the roster never finds someone who was
     * never certified; the online list never finds someone offline).
     *
     * Now one box does all of it. Typing searches BOTH lists at once
     * (online players and certified people, shown below it); Open goes
     * straight to whatever citizen ID is typed, which is how you reach a
     * brand-new, never-certified, offline person. Open is the only button
     * in this row, so Enter opens too -- exactly what Enter did in the old
     * citizen-ID box.
     *
     * A narrowed viewer (see buildConsoleScreen()) gets the same box but
     * no listing to search -- Open is their way in, as before.
     * @param {boolean} fullAccess
     * @returns {HTMLElement}
     */
    function buildFindPersonBar(fullAccess) {
        var bar = mk('div', { class: 'k9tablet-toolbar k9tablet-id-toolbar k9tablet-find-person-toolbar' });
        bar.appendChild(mk('label', {
            class: 'k9tablet-feature-filter-label',
            text: S('find_person_label'),
            attrs: { for: 'k9tablet-find-person' },
        }));
        var input = mk('input', { class: 'k9tablet-search', attrs: { type: 'text', id: 'k9tablet-find-person', placeholder: S('find_person_placeholder') } });
        input.value = state.findPersonQuery;
        input.addEventListener('input', function (e) {
            var q = e.target.value;
            state.findPersonQuery = q;
            if (!fullAccess) return;
            // Both loaders' stale-response guards compare against these.
            state.rosterQuery = q;
            state.onlinePlayersQuery = q;
            clearTimeout(searchDebounceTimer);
            searchDebounceTimer = setTimeout(function () {
                loadOnlinePlayers(q);
                loadRoster(q);
            }, SEARCH_DEBOUNCE_MS);
        });
        bar.appendChild(input);
        bar.appendChild(mkButton(S('open_by_id_label'), 'k9tablet-btn', function () {
            var id = (input.value || '').trim();
            if (id.length === 0) return;
            // `name` starts null, deliberately -- the typed string may be a
            // citizen ID or anything else, and tabletRequestPersonSummary's
            // own `target.exists` is what says whether it is a real person
            // (loadPersonSummary()'s "no record found" handling).
            openPerson(id, null);
        }));
        var outer = mk('div', { class: 'k9tablet-find-person' });
        outer.appendChild(bar);
        outer.appendChild(mk('p', { class: 'k9tablet-hint k9tablet-open-by-id-hint', text: fullAccess ? S('find_person_hint') : S('find_person_hint_id_only') }));
        return outer;
    }

    /** The certified-people half of the search results. */
    function buildRosterResultsSection() {
        var section = mk('div', { class: 'k9tablet-roster-results-section' });
        section.appendChild(mk('h3', { class: 'k9tablet-section-heading', text: S('roster_results_heading') }));

        if (state.rosterLoading && !state.roster) {
            section.appendChild(mk('p', { text: S('loading') }));
            return section;
        }
        if (state.rosterError) {
            section.appendChild(mk('p', { class: 'k9tablet-error-text', text: errorText(state.rosterError) }));
            section.appendChild(mkButton(S('retry_label'), 'k9tablet-btn', function () { loadRoster(state.rosterQuery); }));
            return section;
        }
        if (!state.roster || state.roster.rows.length === 0) {
            section.appendChild(mk('p', { class: 'k9tablet-muted', text: S('empty_roster') }));
            return section;
        }
        if (state.roster.truncated) {
            section.appendChild(mk('p', { class: 'k9tablet-truncated-note', text: state.roster.truncatedMessage || S('truncated_notice') }));
        }
        section.appendChild(buildRosterTable(state.roster.rows));
        return section;
    }

    function buildRosterTable(rows) {
        var table = mk('table', { class: 'k9tablet-table' });
        var thead = mk('thead');
        var headRow = mk('tr');
        [S('column_name'), S('column_citizenid'), S('column_department'), S('column_certified'), S('column_xp'), S('column_handler_xp'), S('column_actions')].forEach(function (h) {
            headRow.appendChild(mk('th', { text: h }));
        });
        thead.appendChild(headRow);
        table.appendChild(thead);

        var tbody = mk('tbody');
        for (var i = 0; i < rows.length; i++) {
            tbody.appendChild(buildRosterRow(rows[i]));
        }
        table.appendChild(tbody);
        return table;
    }

    function buildRosterRow(row) {
        var tr = mk('tr');
        tr.appendChild(mk('td', { text: row.name }));
        tr.appendChild(mk('td', { text: row.citizenid }));
        tr.appendChild(mk('td', { text: row.departmentLabel }));
        tr.appendChild(mk('td', { class: row.certified ? 'k9tablet-cert-status--yes' : 'k9tablet-cert-status--no', text: row.certified ? S('certified_yes') : S('certified_no') }));
        tr.appendChild(mk('td', { text: xpLine(row.xp, row.tierLabel) }));
        // The HANDLER ladder, alongside the K9 one and never merged with
        // it. The server has always sent this pair (server/tablet.lua's own
        // rosterList row) and nothing rendered it, so a handler's rank was
        // computed on every roster fetch and thrown away. Same xpLine
        // helper, so an untracked ladder reads as "No XP record yet"
        // exactly like the K9 column does rather than as a blank cell.
        tr.appendChild(mk('td', { text: xpLine(row.handlerXp, row.handlerTierLabel) }));

        var actionsTd = mk('td');
        actionsTd.appendChild(mkButton(S('manage_label'), 'k9tablet-btn', function () {
            openPerson(row.citizenid, row.name);
        }));
        tr.appendChild(actionsTd);
        return tr;
    }

    /**
     * ONLINE PLAYERS LIST -- owner-directed, 2026-08-26, verbatim: "make
     * the add permission section on the ui tablet for the command tablet
     * where its a list when i choose a player id and just click those
     * permissions etc make it easier". The permission checkboxes
     * themselves already exist (buildCapabilityList() on the Person
     * screen) and are untouched by this section -- what did not exist was
     * a way to REACH that screen for someone identifiable in game: the
     * roster above lists only ALREADY-CERTIFIED citizenids, and the "open
     * by exact citizen ID" box needs a citizenid, which nothing in-game
     * ever shows a player -- the pause menu shows a SERVER id instead.
     * This section is a NEW ENTRY POINT ONLY: picking a row calls
     * openOnlinePlayer() -> openPerson(), the EXACT SAME Person screen and
     * EXACT SAME grant controls the roster's Manage button already opens.
     * No second grant mechanism exists here.
     *
     * Searched from the Console's one search box (buildFindPersonBar()),
     * alongside the certified roster -- this section has no box of its own.
     *
     * Same audience as the roster list below it -- `fullAccess`
     * (canAccessConsole()) -- NOT the wider canOpenPersonRecord(): see
     * server/tablet.lua's own CALLBACK 2b/2c header for why a browse/list
     * capability stays at the narrower gate, matching the roster's own
     * OWNER'S DECISION exactly rather than inventing a second rule.
     *
     * REFRESH: a manual button, not a poll -- matching the roster's own
     * established convention (no polling exists anywhere else in this
     * file) for the same reason: this list is read fresh, in full, from
     * GetPlayers() on every request server-side (see that callback's own
     * header), so a poll would mean every open, console-viewing officer's
     * tablet re-running that scan plus a name/job/K9-access resolution
     * per connected player on an interval, multiplied by however many
     * officers keep this screen open at once -- for staleness that only
     * ever matters at the ONE moment an operator is about to click a row,
     * which the search box's live round trip (see loadOnlinePlayers())
     * already re-answers on every keystroke, and the one Refresh button
     * above both lists answers on demand for someone who is not typing.
     * @returns {HTMLElement}
     */
    function buildOnlinePlayersSection() {
        var wrap = mk('div', { class: 'k9tablet-online-players-section' });
        wrap.appendChild(mk('h3', { class: 'k9tablet-section-heading', text: S('online_players_heading') }));

        if (state.onlinePlayersLoading && !state.onlinePlayers) {
            wrap.appendChild(mk('p', { text: S('loading') }));
            return wrap;
        }
        if (state.onlinePlayersError) {
            wrap.appendChild(mk('p', { class: 'k9tablet-error-text', text: errorText(state.onlinePlayersError) }));
            wrap.appendChild(mkButton(S('retry_label'), 'k9tablet-btn', function () { loadOnlinePlayers(state.onlinePlayersQuery); }));
            return wrap;
        }
        if (!state.onlinePlayers || state.onlinePlayers.rows.length === 0) {
            wrap.appendChild(mk('p', { class: 'k9tablet-muted', text: S('online_players_empty') }));
            return wrap;
        }

        if (state.onlinePlayers.truncated) {
            wrap.appendChild(mk('p', { class: 'k9tablet-truncated-note', text: state.onlinePlayers.truncatedMessage || S('truncated_notice') }));
        }

        wrap.appendChild(buildOnlinePlayersTable(state.onlinePlayers.rows));
        return wrap;
    }

    function buildOnlinePlayersTable(rows) {
        var table = mk('table', { class: 'k9tablet-table' });
        var thead = mk('thead');
        var headRow = mk('tr');
        [S('column_server_id'), S('column_name'), S('column_job'), S('column_k9_access'), S('column_actions')].forEach(function (h) {
            headRow.appendChild(mk('th', { text: h }));
        });
        thead.appendChild(headRow);
        table.appendChild(thead);

        var tbody = mk('tbody');
        for (var i = 0; i < rows.length; i++) {
            tbody.appendChild(buildOnlinePlayersRow(rows[i]));
        }
        table.appendChild(tbody);
        return table;
    }

    function buildOnlinePlayersRow(row) {
        var tr = mk('tr');
        tr.appendChild(mk('td', { text: String(row.source) }));
        tr.appendChild(mk('td', { text: row.name }));
        tr.appendChild(mk('td', { text: row.jobLabel }));
        tr.appendChild(mk('td', { class: row.hasK9Access ? 'k9tablet-cert-status--yes' : 'k9tablet-cert-status--no', text: row.hasK9Access ? S('online_k9_access_yes') : S('online_k9_access_no') }));

        var actionsTd = mk('td');
        var opening = state.onlinePlayersOpeningSource === row.source;
        var anyOpening = state.onlinePlayersOpeningSource !== null;
        // openOnlinePlayer() itself only ever allows ONE resolve in flight
        // at a time (see its own state comment) -- every row's button is
        // disabled while any one of them is resolving, not just the row
        // that was clicked, so a click on a DIFFERENT row while one is
        // pending is a visibly-disabled no-op rather than a silent one.
        var manageBtn = mkButton(opening ? S('online_players_opening_label') : S('manage_label'), 'k9tablet-btn', function () {
            openOnlinePlayer(row.source, row.nonce);
        }, { disabled: anyOpening });
        actionsTd.appendChild(manageBtn);
        tr.appendChild(actionsTd);
        return tr;
    }

    /**
     * GHOST-CITIZENID GUARD (this pass) -- tabletRequestPersonSummary has
     * no existence check server-side: it returns `ok = true` for ANY
     * syntactically valid citizenid, online or not, real or not (see
     * server/tablet.lua's ResolveDisplayName/ResolveJobGradeInfo doc
     * comments -- both fall back to "citizenid itself" / `nil`
     * respectively rather than erroring when nothing resolves). That makes
     * a typo'd or deleted-character citizenid indistinguishable, field by
     * field, from a real citizen with genuinely nothing on record -- UNTIL
     * this checks ALL of them together. `job` is the load-bearing field:
     * ResolveJobGradeInfo returns non-null whenever qbx_core finds a
     * PlayerData row AT ALL (online OR offline) -- every real character
     * has SOME job, even 'unemployed' -- so `job === null` already means
     * "no such player row exists". Still required to be true ALONGSIDE
     * every other field being empty, so a real, existing handler who
     * simply holds zero certs/XP/partnership yet is never misclassified
     * (their `job` still resolves).
     *
     * THE REAL FIX IS SERVER-SIDE: this is a frontend-only stopgap.
     * coder-backend/coder-security own the actual contract this needs --
     * an explicit boolean the server computes from a REAL existence check
     * (e.g. `target.exists` on tabletRequestPersonSummary's response,
     * true only when qbx_core actually found a player row for the
     * citizenid), never guessed here from "everything happens to be
     * empty". Swap this heuristic out for that field the day it exists.
     * @param {object} summary -- state.personSummary
     * @returns {boolean}
     */
    function personSummaryLooksLikeNoRecord(summary) {
        if (!summary) return false;
        return !summary.job
            && !summary.partnership
            && summary.xp === null
            // HANDLER XP COUNTS AS A RECORD (progression pass). This guard
            // predates the handler ladder and only ever considered the K9
            // one, so a person the server had genuinely returned a handler
            // standing for -- but who happened to have no resolvable job,
            // no partner, no K9 XP, no certification row and no explicit
            // permission grant -- was shown "no record found" and had that
            // standing thrown away with the rest of the screen. Narrow, but
            // the guard's whole job is to distinguish "the server knows
            // nothing about this person" from "this person is quiet", and
            // handler XP is something the server knows.
            //
            // `=== null` rather than a falsy check, deliberately, matching
            // the `summary.xp` line above: 0 is a real handler standing and
            // must NOT read as an absent one.
            && (summary.handlerXp === null || summary.handlerXp === undefined)
            && (!summary.certifications || summary.certifications.length === 0)
            && (!summary.permissions || summary.permissions.length === 0);
    }

    // ------------------------------------------------------------------
    // K9/HANDLER PERSONNEL ROSTERS (docs/history/ROSTER_SPEC.md, Phase B) -- owner, three
    // messages, verbatim: "make it in the tablet where there is a roster
    // where we can assign callsigns see list of hired k9s and full menu to
    // fire promote etc" / "Also a separate roster for handlers same
    // thing" / "Also in the roster be able to reorder them by rank."
    //
    // docs/history/ROSTER_SPEC.md §0's structural decision, applied here: the "menu" in
    // the owner's second message is NOT a new screen -- it is
    // buildPersonScreen() (below), already reached from the Console tab
    // and the Online Players picker. The two screens in THIS section
    // (buildPersonnelRosterScreen('k9'|'handler')) are pure, read-only
    // LISTS -- each row's own "Manage" button is a THIRD entry point into
    // that SAME person screen, never a second person-detail screen (see
    // openPerson()'s own third `fromScreen` argument). Every actual
    // mutation (assign role, set/clear callsign, hire/fire/promote/demote)
    // lives there, never duplicated onto a row here (docs/history/ROSTER_SPEC.md §5:
    // "Enough to make a personnel decision at a glance; everything else is
    // one click away on the person screen, not duplicated onto the row").
    //
    // ONE fetch (qbx_k9unit:server:rosterList, server/roster.lua) backs
    // BOTH screens below AND buildPersonScreen()'s own embedded Roster
    // Role/Callsign section (buildRosterRoleSection()) -- never a second
    // read mechanism for the same fact.
    // ------------------------------------------------------------------

    function loadPersonnelRoster() {
        state.personnelRosterLoading = true;
        state.personnelRosterError = null;
        render();

        fetchNui('tablet:rosterList', {}).then(function (result) {
            state.personnelRosterLoading = false;
            if (!result || result.ok !== true) {
                state.personnelRosterError = result || { error: 'unknown_error' };
                render();
                return;
            }
            state.personnelRoster = {
                k9: Array.isArray(result.k9) ? result.k9 : [],
                handlers: Array.isArray(result.handlers) ? result.handlers : [],
                unassigned: Array.isArray(result.unassigned) ? result.unassigned : [],
            };
            render();
        });
    }

    function goToPersonnelRosterScreen(bucketKey) {
        // ONE SCREEN, A BUCKET ARGUMENT -- not two screens. `bucketKey` is
        // optional now: omitted (the tab click) keeps whichever bucket the
        // operator last looked at; supplied (returning from a person opened
        // out of a specific bucket) restores that one.
        if (bucketKey === 'k9' || bucketKey === 'handler') {
            state.personnelRosterBucket = bucketKey;
        }
        state.screen = 'roster';
        render();
        loadPersonnelRoster();
    }

    /**
     * Finds THIS citizenid+department's current roster row across all
     * three buckets (k9/handlers/unassigned) of the already-fetched
     * state.personnelRoster -- used by buildPersonScreen()'s own embedded
     * Roster Role/Callsign section to show the CURRENT state for whichever
     * department row is being edited. Returns null when no active
     * personnel row exists yet (an active certification with none --
     * docs/history/ROSTER_SPEC.md §3's "Unassigned", not an error) OR when
     * state.personnelRoster itself has not loaded/is denied -- callers
     * must check state.personnelRoster's own loading/error state
     * separately before treating a null return as "definitely
     * Unassigned".
     * @param {string} citizenid
     * @param {string} departmentKey
     * @returns {object|null}
     */
    function findPersonnelRosterRow(citizenid, departmentKey) {
        if (!state.personnelRoster) return null;
        var buckets = [state.personnelRoster.k9, state.personnelRoster.handlers, state.personnelRoster.unassigned];
        for (var b = 0; b < buckets.length; b++) {
            var list = buckets[b];
            if (!Array.isArray(list)) continue;
            for (var i = 0; i < list.length; i++) {
                var row = list[i];
                if (row && row.citizenid === citizenid && row.departmentKey === departmentKey) return row;
            }
        }
        return null;
    }

    /**
     * Roster-specific mutation error text -- docs/history/ROSTER_SPEC.md's own explicit
     * instruction: "Render a callsign_taken outcome as a specific, useful
     * message naming the problem -- never a generic failure", and "Every
     * outcome code above needs a real message." Tries every outcome code
     * UNIQUE to server/roster.lua's two mutation callbacks first, then
     * falls through to mutationErrorText() (above) for the codes they
     * share with every other mutation on this page (invalid_target/
     * invalid_args, invalid_department, department_mismatch, rate_limited,
     * db_error, not_authorized, timeout, network_error) -- never a second,
     * drifting copy of those.
     * @param {object|undefined} result
     * @returns {string}
     */
    function rosterMutationErrorText(result) {
        if (!result) return S('action_failed');
        if (typeof result.message === 'string' && result.message.length > 0) return result.message;
        switch (result.error) {
            case 'invalid_personnel_role': return S('roster_error_invalid_personnel_role');
            case 'not_certified': return S('roster_error_not_certified');
            case 'already_assigned': return S('roster_error_already_assigned');
            case 'no_active_personnel': return S('roster_error_no_active_personnel');
            case 'invalid_callsign': return S('roster_callsign_invalid_chars_error');
            case 'callsign_taken': return S('roster_callsign_taken_error');
            default: return mutationErrorText(result);
        }
    }

    /**
     * Generic mutation runner for the two roster callbacks -- SAME shape as
     * runMutation() (state.pendingAction/state.actionNotice, always calls
     * onSettled regardless of ok/fail, never optimistically mutates a local
     * copy), duplicated rather than parameterized ONLY because the error
     * text needs rosterMutationErrorText() above, not mutationErrorText()
     * directly -- the SAME "own bespoke flow for a different error shape"
     * precedent saveTheme()/certTiersUpsert()/etc. already establish on
     * this page.
     * @param {string} nuiName
     * @param {object} payload
     * @param {() => void} onSettled
     */
    function runRosterMutation(nuiName, payload, onSettled) {
        if (state.pendingAction) return;
        state.pendingAction = true;
        state.actionNotice = { kind: 'ok', text: S('action_working') };
        render();

        fetchNui(nuiName, payload).then(function (result) {
            state.pendingAction = false;
            if (result && result.ok === true) {
                state.actionNotice = { kind: 'ok', text: S('action_succeeded') };
            } else {
                state.actionNotice = { kind: 'error', text: rosterMutationErrorText(result) };
            }
            onSettled();
        });
    }

    /**
     * Pure client-side re-sort of an ALREADY-FETCHED roster row array --
     * docs/history/ROSTER_SPEC.md §9 / acceptance criterion #13: sorting by tier, grade,
     * or XP re-orders the list this render already has in memory and NEVER
     * triggers a second qbx_k9unit:server:rosterList call. Returns a NEW
     * array (never mutates the one state.personnelRoster itself holds), all
     * three modes descending (highest tier/grade/XP first, matching
     * server/roster.lua's own default-sort direction), ties broken by name
     * -- same tie-break server/roster.lua's own SortRosterRowsDefault
     * uses for its own (tier) default.
     * @param {object[]} rows
     * @returns {object[]}
     */
    function sortedRosterRows(rows) {
        var copy = (Array.isArray(rows) ? rows : []).slice();
        var mode = state.personnelRosterSort;
        copy.sort(function (a, b) {
            if (mode === 'grade') {
                var ag = (typeof a.gradeLevel === 'number') ? a.gradeLevel : -1;
                var bg = (typeof b.gradeLevel === 'number') ? b.gradeLevel : -1;
                if (ag !== bg) return bg - ag;
            } else if (mode === 'xp') {
                var ax = (typeof a.xp === 'number') ? a.xp : -1;
                var bx = (typeof b.xp === 'number') ? b.xp : -1;
                if (ax !== bx) return bx - ax;
            } else {
                var at = (typeof a.tierOrdinal === 'number') ? a.tierOrdinal : 0;
                var bt = (typeof b.tierOrdinal === 'number') ? b.tierOrdinal : 0;
                if (at !== bt) return bt - at;
            }
            var an = (typeof a.name === 'string') ? a.name : '';
            var bn = (typeof b.name === 'string') ? b.name : '';
            return an < bn ? -1 : (an > bn ? 1 : 0);
        });
        return copy;
    }

    function buildRosterSortControls() {
        var wrap = mk('div', { class: 'k9tablet-toolbar k9tablet-roster-sort' });
        wrap.appendChild(mk('span', { class: 'k9tablet-roster-sort-label', text: S('roster_sort_label') }));
        var options = [
            { key: 'tier', label: S('roster_sort_by_tier') },
            { key: 'grade', label: S('roster_sort_by_grade') },
            { key: 'xp', label: S('roster_sort_by_xp') },
        ];
        for (var i = 0; i < options.length; i++) {
            (function (opt) {
                var active = state.personnelRosterSort === opt.key;
                wrap.appendChild(mkButton(opt.label, 'k9tablet-btn' + (active ? ' k9tablet-btn--active' : ''), function () {
                    if (state.personnelRosterSort === opt.key) return;
                    state.personnelRosterSort = opt.key;
                    render();
                }));
            })(options[i]);
        }
        return wrap;
    }

    /**
     * K9 / Handlers, as a control rather than as two tabs.
     *
     * There were two tabs here, and they called the SAME function with a
     * different argument -- the only thing that differed between the two
     * screens was which of the three arrays in the one already-fetched
     * `state.personnelRoster` payload got rendered above the Unassigned
     * section. That is a filter, not a screen, so it is a filter now.
     * Deliberately the same shape as buildRosterSortControls() directly
     * above, which already establishes "a row of buttons that re-render the
     * rows already in hand, with no second round trip".
     *
     * The Unassigned section is the reason this is a strict improvement
     * rather than a lateral move: it was rendered on BOTH old screens (its
     * own comment says so -- "ALWAYS rendered, on BOTH roster screens"), so
     * an operator comparing the two tabs saw the identical list twice.
     * @returns {HTMLElement}
     */
    function buildRosterBucketControls() {
        var wrap = mk('div', { class: 'k9tablet-toolbar k9tablet-roster-bucket' });
        wrap.appendChild(mk('span', { class: 'k9tablet-roster-sort-label', text: S('roster_bucket_label') }));
        var options = [
            // NOT S('tab_roster_k9')/S('tab_roster_handlers') -- those keys
            // are deleted. A `tab_*` key means "this is a tab", and
            // tests/helptabcoverage_spec.lua enforces that every one of them
            // has a Help entry describing the tab it names. These two label a
            // filter inside one tab now, so they get filter names.
            { key: 'k9', label: S('roster_bucket_k9') },
            { key: 'handler', label: S('roster_bucket_handlers') },
        ];
        for (var i = 0; i < options.length; i++) {
            (function (opt) {
                var active = state.personnelRosterBucket === opt.key;
                wrap.appendChild(mkButton(opt.label, 'k9tablet-btn' + (active ? ' k9tablet-btn--active' : ''), function () {
                    if (state.personnelRosterBucket === opt.key) return;
                    state.personnelRosterBucket = opt.key;
                    render();
                }));
            })(options[i]);
        }
        return wrap;
    }

    function buildPersonnelRosterScreen() {
        var wrap = mk('div', { class: 'k9tablet-screen' });
        var bucketKey = state.personnelRosterBucket === 'handler' ? 'handler' : 'k9';
        var fromScreen = 'roster';

        if (state.personnelRosterLoading && !state.personnelRoster) {
            wrap.appendChild(mk('p', { text: S('loading') }));
            return wrap;
        }
        if (state.personnelRosterError && !state.personnelRoster) {
            wrap.appendChild(mk('p', { class: 'k9tablet-error-text', text: errorText(state.personnelRosterError) }));
            wrap.appendChild(mkButton(S('retry_label'), 'k9tablet-btn', function () { loadPersonnelRoster(); }));
            return wrap;
        }
        if (!state.personnelRoster) {
            wrap.appendChild(mk('p', { text: S('loading') }));
            return wrap;
        }

        wrap.appendChild(buildRosterBucketControls());
        wrap.appendChild(buildRosterSortControls());

        var rows = bucketKey === 'k9' ? state.personnelRoster.k9 : state.personnelRoster.handlers;
        rows = Array.isArray(rows) ? rows : [];
        if (rows.length === 0) {
            wrap.appendChild(mk('p', { class: 'k9tablet-muted', text: S('roster_bucket_empty') }));
        } else {
            wrap.appendChild(buildPersonnelRosterTable(sortedRosterRows(rows), fromScreen, bucketKey));
        }

        // UNASSIGNED (docs/history/ROSTER_SPEC.md §3/§5/§8) -- ALWAYS rendered,
        // whichever bucket is selected, even when it (or the bucket above) is
        // empty -- acceptance criterion #3: "never silently omitted from
        // both." It used to render on BOTH roster screens, which meant an
        // operator switching tabs saw the same list a second time; with one
        // screen it appears exactly once, which is what that criterion
        // actually wanted.
        // NOT an error state -- on the day this ships, EVERY certified
        // person is unassigned, and the explainer below says so in plain
        // language rather than let an owner conclude people went missing.
        wrap.appendChild(mk('h3', { class: 'k9tablet-section-heading', text: S('roster_unassigned_heading') }));
        wrap.appendChild(mk('p', { class: 'k9tablet-muted', text: S('roster_unassigned_explainer') }));
        var unassigned = Array.isArray(state.personnelRoster.unassigned) ? state.personnelRoster.unassigned : [];
        if (unassigned.length === 0) {
            wrap.appendChild(mk('p', { class: 'k9tablet-muted', text: S('roster_unassigned_none') }));
        } else {
            wrap.appendChild(buildPersonnelRosterTable(sortedRosterRows(unassigned), fromScreen, bucketKey));
        }

        return wrap;
    }

    function buildPersonnelRosterTable(rows, fromScreen, bucketKey) {
        var table = mk('table', { class: 'k9tablet-table' });
        var thead = mk('thead');
        var headRow = mk('tr');
        [S('column_name'), S('column_citizenid'), S('roster_callsign_column'), S('column_department'), S('column_xp'), S('partnership_partner_label'), S('roster_certified_since_column'), S('column_actions')].forEach(function (h) {
            headRow.appendChild(mk('th', { text: h }));
        });
        thead.appendChild(headRow);
        table.appendChild(thead);

        var tbody = mk('tbody');
        for (var i = 0; i < rows.length; i++) {
            tbody.appendChild(buildPersonnelRosterRow(rows[i], fromScreen, bucketKey));
        }
        table.appendChild(tbody);
        return table;
    }

    /**
     * ONE roster row -- read-only, per docs/history/ROSTER_SPEC.md §5 ("everything else
     * is one click away on the person screen, not duplicated onto the
     * row"). `row` is captured directly from THIS render's own
     * state.personnelRoster arrays -- the Manage button's own closure over
     * `row.citizenid`/`row.name` (never a server id, which this resource's
     * own "RECYCLED SERVER IDS" hazard applies to, not a citizenid --
     * server/roster.lua's own header) resolves to a durable identity at the
     * moment THIS row was fetched, and openPerson() itself re-fetches this
     * exact citizenid's live summary at click time -- a stale row rendered
     * minutes ago can never act on "whoever now holds" anything, because
     * nothing here is ever keyed by anything but this citizenid string.
     * @param {object} row
     * @param {'roster'} fromScreen
     * @param {'k9'|'handler'} bucketKey
     */
    function buildPersonnelRosterRow(row, fromScreen, bucketKey) {
        var tr = mk('tr');

        var nameCell = mk('td');
        nameCell.appendChild(mk('span', { text: row.name }));
        // docs/history/ROSTER_SPEC.md §3 -- informational, NON-AUTHORITATIVE only, K9
        // roster rows only (a handler cosmetically pinned as a dog still
        // functions as a handler in every other respect -- never the thing
        // that decides which roster a citizenid appears on, which this
        // note plays no part in: the row is already on this table because
        // server/roster.lua's own rosterList put it here).
        if (bucketKey === 'k9' && row.pinnedDogModel) {
            nameCell.appendChild(mk('span', { class: 'k9tablet-muted k9tablet-roster-pin-note', text: ' ' + S('roster_dogcharacter_pin_note') }));
        }
        tr.appendChild(nameCell);

        tr.appendChild(mk('td', { text: row.citizenid }));
        tr.appendChild(mk('td', { text: (typeof row.callsign === 'string' && row.callsign.length > 0) ? row.callsign : S('roster_callsign_none') }));
        tr.appendChild(mk('td', { text: row.departmentLabel }));
        tr.appendChild(mk('td', { text: xpLine(row.xp, row.tierLabel) }));
        tr.appendChild(mk('td', { text: (typeof row.partnerName === 'string' && row.partnerName.length > 0) ? row.partnerName : S('partnership_none') }));
        tr.appendChild(mk('td', { text: (typeof row.certifiedSince === 'string' && row.certifiedSince.length > 0) ? row.certifiedSince : S('not_available_short') }));

        var actionsTd = mk('td');
        actionsTd.appendChild(mkButton(S('manage_label'), 'k9tablet-btn', function () {
            openPerson(row.citizenid, row.name, fromScreen);
        }));
        tr.appendChild(actionsTd);
        return tr;
    }

    /**
     * PERSONNEL ROSTER ROLE + CALLSIGN (docs/history/ROSTER_SPEC.md, Phase B) -- owner:
     * "assign roles"/"assign callsigns"/"click their profile and it opens
     * a menu". Lives ONLY on buildPersonScreen() (opts.showRosterControls
     * at buildCertificationRow()'s own call site), never on My Record or a
     * guided flow's own read of the same certification list -- docs/history/ROSTER_SPEC.md
     * §0: extend the ONE person screen, never fork a second one. Reads
     * state.personnelRoster (loaded opportunistically by openPerson() for
     * every high-command viewer -- the SAME payload the two roster tabs
     * render, no second read mechanism) via findPersonnelRosterRow() to
     * find THIS citizenid+department's current role/callsign, defaulting
     * to "Unassigned" when no row is found (an active certification with
     * no k9_personnel row -- docs/history/ROSTER_SPEC.md §3, NOT an error).
     *
     * HIRE, IN THE OWNER'S OWN VOCABULARY -- disclosed limitation, not
     * silently glossed over: docs/history/ROSTER_SPEC.md §3 calls for
     * GrantCertificationForTablet to gain a REQUIRED personnelRole
     * parameter so Hire cannot be submitted without picking K9 or Handler
     * IN THE SAME ACTION. server/roster.lua's own Phase A header
     * explicitly deferred that signature change to "a later, serialized
     * pass" (it lives in server/certifications/, outside this pass's
     * file list) -- and RosterAssignPersonnelRole's own authorization
     * circle (High Command only) is DELIBERATELY NARROWER than
     * IsEligibleCertifier (the wider certifier-grade/k9.certify circle that
     * already authorizes Certify), so fusing them client-side by simply
     * chaining tablet:certify then tablet:rosterSetPersonnelRole from one
     * button would silently fail the second call for any certifier who is
     * not High Command -- a worse, more confusing outcome than what this
     * builds instead: Certify is left completely unchanged (works exactly
     * as it always has, for every certifier), and this section is the
     * very next, one-click, high-command-only step for a citizenid who
     * just got certified (or was certified all along) and is still
     * sitting in "Unassigned" -- visible, obvious, never silently missed
     * (docs/history/ROSTER_SPEC.md §3/§8's own "Unassigned" bucket is exactly this same
     * citizenid, listed).
     * @param {{departmentKey:string}} entry
     */
    function buildRosterRoleSection(entry) {
        var wrap = mk('div', { class: 'k9tablet-roster-role-section' });
        wrap.appendChild(mk('h4', { class: 'k9tablet-subheading', text: S('roster_role_change_label') }));

        if (state.personnelRosterLoading && !state.personnelRoster) {
            wrap.appendChild(mk('p', { class: 'k9tablet-muted', text: S('loading') }));
            return wrap;
        }
        if (state.personnelRosterError && !state.personnelRoster) {
            wrap.appendChild(mk('p', { class: 'k9tablet-error-text', text: errorText(state.personnelRosterError) }));
            wrap.appendChild(mkButton(S('retry_label'), 'k9tablet-btn', function () { loadPersonnelRoster(); }));
            return wrap;
        }
        if (!state.personnelRoster) {
            wrap.appendChild(mk('p', { class: 'k9tablet-muted', text: S('loading') }));
            return wrap;
        }

        var citizenid = state.person.citizenid;
        var departmentKey = entry.departmentKey;
        var existingRow = findPersonnelRosterRow(citizenid, departmentKey);
        var currentRole = existingRow ? existingRow.personnelRole : null;
        var currentCallsign = existingRow ? existingRow.callsign : null;

        var statusLabel = currentRole === 'k9' ? S('roster_hire_role_k9')
            : currentRole === 'handler' ? S('roster_hire_role_handler')
            : S('roster_unassigned_heading');
        wrap.appendChild(mk('p', { class: 'k9tablet-roster-role-status', text: statusLabel }));

        if (currentRole == null) {
            var hireNotice = mk('div', { class: 'k9tablet-roster-hire-notice' });
            hireNotice.appendChild(mk('span', { class: 'k9tablet-roster-hire-label', text: S('roster_hire_label') }));
            hireNotice.appendChild(mk('p', { class: 'k9tablet-hint', text: S('roster_hire_role_prompt') }));
            wrap.appendChild(hireNotice);
        } else {
            // docs/history/ROSTER_SPEC.md §6/acceptance criterion #6: the confirmation
            // copy must say the callsign is being cleared, BEFORE the
            // operator confirms -- visible text, not merely a button
            // title/tooltip.
            wrap.appendChild(mk('p', { class: 'k9tablet-warning', text: S('roster_role_change_confirm_prompt') }));
        }

        ['k9', 'handler'].forEach(function (candidateRole) {
            if (candidateRole === currentRole) return; // never offer switching to the role already held
            var label = candidateRole === 'k9' ? S('roster_hire_role_k9') : S('roster_hire_role_handler');
            var doChange = function () {
                runRosterMutation('tablet:rosterSetPersonnelRole',
                    { citizenid: citizenid, job: departmentKey, personnelRole: candidateRole },
                    function () {
                        loadPersonnelRoster();
                        refreshPersonAndSelf(citizenid);
                    });
            };
            if (currentRole == null) {
                // Assigning from Unassigned -- low-weight, plain button
                // (docs/history/ROSTER_SPEC.md §6: "Plain button, but the confirmation
                // copy must say..." applies to a CHANGE, not this first
                // assignment, which clears nothing).
                wrap.appendChild(mkButton(label, 'k9tablet-btn', doChange, { disabled: state.pendingAction }));
            } else {
                // Changing an EXISTING role clears the callsign -- two-click
                // confirm, with the visible warning paragraph above already
                // shown before either click.
                wrap.appendChild(mkConfirmButton(label, 'k9tablet-btn', doChange, {
                    disabled: state.pendingAction,
                    title: S('roster_role_change_confirm_prompt'),
                }));
            }
        });

        if (currentRole != null) {
            wrap.appendChild(buildRosterCallsignControl(citizenid, departmentKey, currentCallsign));
        }

        return wrap;
    }

    /**
     * @param {string} citizenid
     * @param {string} departmentKey
     * @param {string|null} currentCallsign
     */
    function buildRosterCallsignControl(citizenid, departmentKey, currentCallsign) {
        var wrap = mk('div', { class: 'k9tablet-roster-callsign' });

        var currentLine = mk('p', { class: 'k9tablet-roster-callsign-current' });
        currentLine.appendChild(mk('span', { text: S('roster_callsign_label') + ': ' }));
        currentLine.appendChild(mk('span', {
            class: 'k9tablet-roster-callsign-value',
            text: (typeof currentCallsign === 'string' && currentCallsign.length > 0) ? currentCallsign : S('roster_callsign_none'),
        }));
        wrap.appendChild(currentLine);

        var input = mk('input', {
            class: 'k9tablet-roster-callsign-input',
            attrs: { type: 'text', maxlength: '12' },
            title: S('roster_callsign_label'),
        });
        input.value = (typeof currentCallsign === 'string') ? currentCallsign : '';
        wrap.appendChild(input);

        wrap.appendChild(mkButton(S('roster_callsign_save'), 'k9tablet-btn', function () {
            var value = (input.value || '').trim();
            runRosterMutation('tablet:rosterSetCallsign',
                { citizenid: citizenid, job: departmentKey, callsign: value },
                function () { loadPersonnelRoster(); });
        }, { disabled: state.pendingAction }));

        return wrap;
    }

    // ---- Person detail screen ----

    function buildPersonScreen() {
        var wrap = mk('div', { class: 'k9tablet-screen' });
        // Reuses goToConsoleScreen() (not a fourth copy of the
        // screen-swap+render+loadRoster sequence) specifically so Back never
        // shows a stale roster after an edit made ON this Person screen
        // (certify/tier/XP change) -- every OTHER route into the console
        // (the Console tab, the high-command auto-redirect on open) already
        // reloads via this same helper; Back must not be the one path that
        // diverges from it.
        wrap.appendChild(mkButton(S('back_label'), 'k9tablet-link-btn', function () {
            // docs/history/ROSTER_SPEC.md §0 -- the ONE piece of "mode" this pass adds:
            // Back returns to whichever roster tab actually opened this
            // screen when that's how it was reached, otherwise falls
            // through to the EXACT SAME goToConsoleScreen() every other
            // entry point already used before this pass, unchanged.
            if (state.personOpenedFrom === 'roster') {
                goToPersonnelRosterScreen();
                return;
            }
            goToConsoleScreen();
        }));

        if (!state.person) {
            wrap.appendChild(mk('p', { text: S('opening_person') }));
            return wrap;
        }

        wrap.appendChild(mk('h2', { class: 'k9tablet-person-name', text: state.person.name }));
        wrap.appendChild(mk('p', { class: 'k9tablet-muted', text: state.person.citizenid }));

        if (state.personSummaryLoading && !state.personSummary) {
            wrap.appendChild(mk('p', { text: S('loading') }));
            return wrap;
        }
        if (state.personSummaryError && !state.personSummary) {
            wrap.appendChild(mk('p', { class: 'k9tablet-error-text', text: errorText(state.personSummaryError) }));
            wrap.appendChild(mkButton(S('retry_label'), 'k9tablet-btn', function () { loadPersonSummary(state.person.citizenid); }));
            return wrap;
        }

        if (state.personSummary && personSummaryLooksLikeNoRecord(state.personSummary)) {
            wrap.appendChild(mk('p', { class: 'k9tablet-error-text', text: S('person_no_record_found') }));
            return wrap;
        }

        if (state.personSummary) {
            var canCertify = state.viewer.effectivePermissions.indexOf('k9.certify') !== -1;
            var canGiveXp = state.viewer.effectivePermissions.indexOf('k9.givexp') !== -1;

            wrap.appendChild(mk('h3', { class: 'k9tablet-section-heading', text: S('person_certifications_heading') }));
            // { showRosterControls: true } -- docs/history/ROSTER_SPEC.md, Phase B --
            // the ONLY call site of buildCertificationList() that passes
            // this; My Record (read-only) and the guided flows' own calls
            // are UNCHANGED, so this section only ever appears here, on
            // THIS screen, exactly like the capability/feature/role
            // sections immediately below already do.
            wrap.appendChild(buildCertificationList(state.personSummary.certifications, canCertify ? handlePersonCertAction : null, { showRosterControls: true, roleXp: state.personSummary.roleXp }));

            // K9 ROLE right under Certifications (the owner's rework pass):
            // making someone the K9, changing their breed, and the
            // emergency Revert to Human used to sit at the very bottom of
            // this page, under three long admin sections.
            if (state.viewer.isHighCommand) {
                wrap.appendChild(mk('h3', { class: 'k9tablet-section-heading', text: S('role_heading') }));
                wrap.appendChild(buildRoleControl());
            }

            wrap.appendChild(mk('h3', { class: 'k9tablet-section-heading', text: S('person_xp_heading') }));
            wrap.appendChild(mk('p', { class: 'k9tablet-xp-line', text: xpLine(state.personSummary.xp, state.personSummary.tierLabel) }));
            if (canGiveXp) {
                wrap.appendChild(buildGiveXpControl());
            }

            // HANDLER LADDER -- its own heading, deliberately not folded
            // into the K9 one above. They are separate ladders on separate
            // feature switches, and the same person is routinely high on
            // one and nowhere on the other; a single merged "XP" line would
            // make a Master Handler on a rookie dog unreadable. The server
            // has always sent this pair on this payload and nothing
            // rendered it.
            //
            // NULL IS NOT ZERO, and the distinction is why this branches
            // rather than calling xpLine unconditionally: null means the
            // handler ladder is switched off server-wide, while 0 means a
            // real handler who has not earned anything yet. xpLine collapses
            // both to "No XP record yet", which would tell someone to go
            // grind a system their server does not run. There is NO
            // give-handler-XP control here to match the K9 one: handler XP
            // is earned through the awards in Config.HandlerXP, never
            // granted by hand, and inventing an admin grant path for it is
            // not this change.
            wrap.appendChild(mk('h3', { class: 'k9tablet-section-heading', text: S('person_handler_xp_heading') }));
            if (typeof state.personSummary.handlerXp === 'number') {
                wrap.appendChild(mk('p', {
                    class: 'k9tablet-xp-line',
                    text: xpLine(state.personSummary.handlerXp, state.personSummary.handlerTierLabel)
                }));
            } else {
                wrap.appendChild(mk('p', { class: 'k9tablet-muted', text: S('person_handler_xp_untracked') }));
            }

            wrap.appendChild(mk('h3', { class: 'k9tablet-section-heading', text: S('person_partnership_heading') }));
            wrap.appendChild(buildPartnershipSection(state.personSummary.partnership));

            if (state.viewer.isHighCommand) {
                // The full history plus Force End, moved here off the
                // Partnerships tab (plan item E) so this person's whole
                // record sits on one screen instead of behind a second
                // lookup box. Directly under the CURRENT partnership it
                // expands on.
                wrap.appendChild(buildPersonPartnershipHistorySection());
            }

            wrap.appendChild(mk('h3', { class: 'k9tablet-section-heading', text: S('person_rank_heading') }));
            wrap.appendChild(buildRankSection(state.personSummary.job));

            // THE RARELY-USED, LONG SECTIONS fold away (the owner's rework
            // pass). Special permissions, per-person ability switches and a
            // K9's individual overrides are real, kept, and one click away
            // -- they just no longer make every visit scroll past them. See
            // buildPersonFoldout() for why each remembers being left open.
            if (state.viewer.isHighCommand) {
                wrap.appendChild(buildPersonFoldout('capabilities', S('person_capabilities_heading'), [
                    buildCapabilityList(state.personSummary.permissions),
                ]));
                wrap.appendChild(buildPersonFoldout('features', S('person_features_heading'), [
                    buildPersonFeaturesSection(),
                ]));
                wrap.appendChild(buildPersonFoldout('k9_profile', S('k9_profile_person_section_heading'), [
                    mk('p', { class: 'k9tablet-muted', text: S('k9_profile_person_section_intro') }),
                    buildPersonK9ProfileSection(),
                ]));
            }
        }

        return wrap;
    }

    /**
     * READ-ONLY rank/department display -- server/tablet.lua's
     * ResolveJobGradeInfo. NO PROMOTION CONTROL RENDERED HERE, deliberately:
     * this resource has no write path for job grade at all today (no
     * SetJobGrade-equivalent anywhere in qbx_k9unit, and no per-department
     * "real ranks list" this page could even populate a dropdown from --
     * Config.Departments only carries numeric certifierGrade/auditGrade/
     * highCommandGrade THRESHOLDS, not named ranks). Per THE SECURITY RULE
     * at the top of this file, a disabled dropdown would still be a lie if
     * there is no server capability behind it at all -- so this renders
     * plain text plus an explicit note, never a fake control.
     * @param {{departmentLabel:string,gradeLabel:string|null,gradeLevel:number|null,isBoss:boolean}|null} job
     */
    function buildRankSection(job) {
        var wrap = mk('div', { class: 'k9tablet-rank-section' });
        if (!job) {
            wrap.appendChild(mk('p', { class: 'k9tablet-muted', text: S('rank_unavailable') }));
            return wrap;
        }
        wrap.appendChild(mk('p', { class: 'k9tablet-rank-line', text: S('rank_department_label') + ': ' + job.departmentLabel }));
        var gradeText = (typeof job.gradeLabel === 'string' && job.gradeLabel.length > 0)
            ? job.gradeLabel + (typeof job.gradeLevel === 'number' ? ' (' + job.gradeLevel + ')' : '')
            : (typeof job.gradeLevel === 'number' ? String(job.gradeLevel) : S('not_available_short'));
        wrap.appendChild(mk('p', { class: 'k9tablet-rank-line', text: S('rank_grade_label') + ': ' + gradeText + (job.isBoss ? ' (' + S('rank_is_boss_badge') + ')' : '') }));
        wrap.appendChild(mk('p', { class: 'k9tablet-muted k9tablet-hint', text: S('rank_change_note') }));
        return wrap;
    }

    /**
     * READ-ONLY partnership display -- server/tablet.lua's
     * ResolvePartnershipInfo (DB-authoritative, correct for an offline
     * target). No controls here -- breaking/forming a partnership is a
     * player-initiated, proximity-gated in-world action (server/partnership.lua),
     * not something this console screen offers on someone else's behalf.
     * @param {{partnerCitizenid:string,partnerName:string,role:'k9'|'handler'}|null} partnership
     */
    function buildPartnershipSection(partnership) {
        var wrap = mk('div', { class: 'k9tablet-partnership-section' });
        if (!partnership) {
            wrap.appendChild(mk('p', { class: 'k9tablet-muted', text: S('partnership_none') }));
            return wrap;
        }
        wrap.appendChild(mk('p', { class: 'k9tablet-partnership-line', text: S('partnership_partner_label') + ': ' + partnership.partnerName }));
        var roleText = partnership.role === 'k9' ? S('partnership_role_value_k9') : S('partnership_role_value_handler');
        wrap.appendChild(mk('p', { class: 'k9tablet-partnership-line', text: S('partnership_role_label') + ': ' + roleText }));
        return wrap;
    }

    // ------------------------------------------------------------------
    // PARTNERSHIPS TAB (this pass, coder-ui) -- owner, verbatim, two
    // passes: "both the k9 and handler should be able to pull up a list
    // of there partners and levels etc in a tab... Past partnerships
    // matter too, not just the active one" -- refined -- "a partnership
    // tab should be shown on all tablets as a tab as it entails how many
    // handlers a k9 has or how many k9s a handler has and high command is
    // a handler or a k9 and should have control over it also but the
    // partnership tab should show whos there partners."
    //
    // ONE TAB, EVERYONE, HIGH COMMAND INCLUDED (owner's own correction:
    // "high command is not a fourth species... a handler or a k9... and
    // also administers") -- buildPartnershipsScreen() below renders the
    // SAME personal section for every viewer (their own current + past
    // partnerships), with an EXTRA admin lookup section on top for
    // isHighCommand specifically -- never a separate screen for it (see
    // buildTabs()'s own header comment on this same tab).
    //
    // "HOW MANY... HAS" IS A HISTORICAL COUNT, NEVER A CONCURRENT ONE --
    // VERIFIED, not assumed (qa-tester/ad71ee3115acd466d's audit, this same
    // pass): server/partnership.lua enforces at most one ACTIVE
    // partnership per citizenid, in either role, at a time (two
    // independent UNIQUE keys plus PartnershipEstablishMutex's own
    // pre-INSERT re-check -- traced end to end with no race found). So a
    // live "how many partners right now" count would always be 0 or 1 --
    // meaningless. The count this screen shows is the length of the
    // HISTORICAL list server/tablet.lua's tabletRequestMyPartnerships/
    // tabletRequestPartnershipsForTarget return (every row this citizenid
    // has ever held, active or ended -- k9_partnerships is append-only),
    // exactly matching the owner's own clarified reading ("Past
    // partnerships... is where the count comes from historically").
    //
    // NAMES, NEVER CITIZENIDS -- every partner shown here is
    // `partnerName`/`endedByName`, server/tablet.lua's own ResolveDisplayName,
    // confirmed offline-safe (a3c05728358946da4's contract): most of a
    // citizenid's PAST partners are, by definition, not the person holding
    // the tablet right now, and often not online at all.
    //
    // TENURE LEVEL IS NOT PRESENTED AS TAMPER-PROOF (coordinator-directed):
    // server/partnership.lua's own PairTenureSeed anti-farm guard is
    // disclosed as in-memory-only, reset by a resource restart -- nothing
    // below uses words like "verified"/"certified"/"audited" for
    // tenureTierGranted or the live tenure-progress enrichment; it is
    // shown as plain informational data, same as XP elsewhere on this page.
    // ------------------------------------------------------------------

    function goToPartnershipsScreen() {
        state.screen = 'partnerships';
        render();
        loadMyPartnerships();
    }

    /**
     * One row of partnership HISTORY (active or ended) -- shared by the
     * personal section and the high-command admin lookup below, so an
     * officer never sees a richer/different shape for someone else than
     * for their own history.
     * @param {object} entry -- server/tablet.lua's per-row shape (see
     *   CALLBACKS 7-9's own doc comment): { partnerCitizenid, partnerName,
     *   role, active, establishedAtUnix, endedAtUnix, endedByName,
     *   endedBySystemReason, tenureTierGranted, tenureProgress? }
     * @returns {Element}
     */
    function buildPartnershipHistoryRow(entry) {
        var row = mk('div', { class: 'k9tablet-partnership-row' });
        row.appendChild(mk('span', { class: 'k9tablet-partnership-row-name', text: entry.partnerName }));

        var roleText = entry.role === 'k9' ? S('partnership_role_value_k9') : S('partnership_role_value_handler');
        row.appendChild(mk('span', { class: 'k9tablet-muted', text: S('partnership_role_label') + ': ' + roleText }));

        var stateClass = entry.active ? 'k9tablet-feature-state--available' : 'k9tablet-feature-state--global_off';
        var stateText = entry.active ? S('partnerships_state_active') : S('partnerships_state_ended');
        row.appendChild(mk('span', { class: 'k9tablet-feature-state ' + stateClass, text: stateText }));

        if (typeof entry.establishedAtUnix === 'number') {
            row.appendChild(mk('span', { class: 'k9tablet-muted', text: S('partnerships_established_label') + ': ' + new Date(entry.establishedAtUnix * 1000).toLocaleDateString() }));
        }

        if (!entry.active) {
            if (typeof entry.endedAtUnix === 'number') {
                row.appendChild(mk('span', { class: 'k9tablet-muted', text: S('partnerships_ended_label') + ': ' + new Date(entry.endedAtUnix * 1000).toLocaleDateString() }));
            }
            var endedByText = null;
            if (typeof entry.endedByName === 'string' && entry.endedByName.length > 0) {
                endedByText = entry.endedByName;
            } else if (typeof entry.endedBySystemReason === 'string' && entry.endedBySystemReason.length > 0) {
                endedByText = formatTemplate(S('partnerships_ended_system_template'), { reason: entry.endedBySystemReason });
            }
            if (endedByText) {
                row.appendChild(mk('span', { class: 'k9tablet-muted', text: S('partnerships_ended_by_label') + ': ' + endedByText }));
            }
        }

        var tier = (typeof entry.tenureTierGranted === 'number') ? entry.tenureTierGranted : 0;
        if (tier > 0) {
            row.appendChild(mk('span', { class: 'k9tablet-muted', text: S('partnerships_tier_label') + ': ' + formatTemplate(S('partnerships_tier_value_template'), { tier: tier }) }));
        }

        return row;
    }

    /**
     * Rich tier/duration detail for the CURRENT active partnership only --
     * `entry.tenureProgress`, when present, is client/tablet.lua's own
     * composition (tablet:requestMyPartnerships) with the ALREADY-SHIPPED
     * getPartnershipTenureProgress result (tier/tierTitle/secondsUntilNextTier);
     * absent for the high-command admin lookup (no target argument exists
     * for that self-only server callback -- see server/tablet.lua's own
     * doc comment), in which case this falls back to the plain
     * `tenureTierGranted` number, same as any ended row.
     * @param {object} entry
     * @returns {Element}
     */
    function buildPartnershipTierDetail(entry) {
        var wrap = mk('div', { class: 'k9tablet-partnership-tier' });
        var progress = entry.tenureProgress;

        if (progress && typeof progress === 'object') {
            var tier = (typeof progress.tier === 'number') ? progress.tier : 0;
            var tierText = (typeof progress.tierTitle === 'string' && progress.tierTitle.length > 0)
                ? progress.tierTitle
                : (tier > 0 ? formatTemplate(S('partnerships_tier_value_template'), { tier: tier }) : S('partnerships_tier_none'));
            wrap.appendChild(mk('p', { class: 'k9tablet-partnership-line', text: S('partnerships_tier_label') + ': ' + tierText }));
            if (typeof progress.secondsUntilNextTier === 'number' && progress.secondsUntilNextTier > 0) {
                var days = Math.ceil(progress.secondsUntilNextTier / 86400);
                wrap.appendChild(mk('p', { class: 'k9tablet-muted', text: formatTemplate(S('partnerships_next_tier_countdown_template'), { days: days }) }));
            }
        } else {
            var tenureTier = (typeof entry.tenureTierGranted === 'number') ? entry.tenureTierGranted : 0;
            var text = tenureTier > 0 ? formatTemplate(S('partnerships_tier_value_template'), { tier: tenureTier }) : S('partnerships_tier_none');
            wrap.appendChild(mk('p', { class: 'k9tablet-partnership-line', text: S('partnerships_tier_label') + ': ' + text }));
        }

        if (typeof entry.establishedAtUnix === 'number') {
            wrap.appendChild(mk('p', { class: 'k9tablet-muted', text: S('partnerships_established_label') + ': ' + new Date(entry.establishedAtUnix * 1000).toLocaleDateString() }));
        }
        return wrap;
    }

    /**
     * HIGH COMMAND ONLY -- owner: "high command... should have control over
     * it also." This person's full partnership history, with Force End on
     * the active one.
     *
     * MOVED ONTO THE PERSON SCREEN (plan item E). It used to sit at the top
     * of the Partnerships TAB behind its own "open by exact citizen ID" box
     * -- one of eleven person-finding inputs across this page, all of which
     * end at the same place. The box is gone; this section now renders for
     * whichever person is already open, alongside their certifications,
     * capabilities, abilities and roster role, which is where every other
     * per-person admin control on this page already lives.
     *
     * WHAT THE PLAN GOT WRONG, AND WHY THIS IS A MOVE RATHER THAN A DELETE:
     * docs/TABLET_SIMPLIFICATION_PLAN.md item E said this section was purely
     * a second door to something the Person screen already rendered. It was
     * not. The Person screen shows the CURRENT partnership
     * (buildPartnershipSection) but has never had the history list or the
     * Force End button -- those existed only here. Deleting the section as
     * written would have removed a real capability, so the section moved
     * instead and only the duplicate lookup was removed.
     *
     * THE SECURITY RULE applies here exactly as everywhere else: Force End
     * is shown because state.viewer.isHighCommand made it worth building
     * for this viewer, never because that is what makes
     * tablet:forceEndPartnership permitted -- server/tablet.lua's CALLBACK 9
     * re-verifies IsHighCommand fresh from `source` on every call.
     * @returns {Element}
     */
    function buildPersonPartnershipHistorySection() {
        var wrap = mk('div', { class: 'k9tablet-partnerships-admin' });
        wrap.appendChild(mk('h3', { class: 'k9tablet-section-heading', text: S('partnerships_admin_heading') }));

        if (state.partnershipsAdminLoading && !state.partnershipsAdminResult) {
            wrap.appendChild(mk('p', { text: S('loading') }));
            return wrap;
        }
        if (state.partnershipsAdminError) {
            wrap.appendChild(mk('p', { class: 'k9tablet-error-text', text: errorText(state.partnershipsAdminError) }));
            return wrap;
        }
        if (!state.partnershipsAdminResult) {
            return wrap;
        }

        var result = state.partnershipsAdminResult;

        // GUARD AGAINST A STALE RESULT. This state is filled by an
        // asynchronous load started when the person was opened; if the
        // operator has since opened a DIFFERENT person, a late response for
        // the previous one must never be rendered against this person's
        // name. Compared by citizenid, the durable identity, never by name.
        var openCitizenid = state.person && state.person.citizenid;
        var resultCitizenid = result.target && result.target.citizenid;
        if (typeof openCitizenid === 'string' && typeof resultCitizenid === 'string' && openCitizenid !== resultCitizenid) {
            return wrap;
        }

        if (result.featureEnabled === false) {
            wrap.appendChild(mk('p', { class: 'k9tablet-muted', text: S('partnerships_feature_disabled') }));
            return wrap;
        }

        var list = result.partnerships || [];
        if (list.length === 0) {
            wrap.appendChild(mk('p', { class: 'k9tablet-muted', text: S('partnerships_admin_none') }));
            return wrap;
        }

        wrap.appendChild(mk('p', { class: 'k9tablet-muted', text: formatTemplate(S('partnerships_count_summary_template'), { count: list.length }) }));
        if (result.truncated) {
            wrap.appendChild(mk('p', { class: 'k9tablet-muted', text: formatTemplate(S('partnerships_truncated_notice_template'), { shown: list.length }) }));
        }

        var targetCitizenid = resultCitizenid;
        var historyWrap = mk('div', { class: 'k9tablet-partnership-history-list' });
        for (var i = 0; i < list.length; i++) {
            var entry = list[i];
            var row = buildPartnershipHistoryRow(entry);
            if (entry.active && typeof targetCitizenid === 'string' && targetCitizenid.length > 0) {
                row.appendChild(mkConfirmButton(S('partnerships_force_end_label'), 'k9tablet-btn k9tablet-btn--danger', function () {
                    forceEndPartnership(targetCitizenid);
                }, { disabled: state.pendingAction }));
            }
            historyWrap.appendChild(row);
        }
        wrap.appendChild(historyWrap);

        return wrap;
    }

    /** THE PARTNERSHIPS TAB'S SCREEN -- see this block's own header comment
     * for the full contract/reasoning. Same loading/error/empty posture as
     * every other data-driven screen on this page. */
    function buildPartnershipsScreen() {
        var wrap = mk('div', { class: 'k9tablet-screen' });

        // NO ADMIN SECTION HERE ANY MORE (plan item E). This tab is what the
        // owner asked for and nothing else: your own partnerships. Looking
        // up somebody else's is per-person admin, so it happens on the
        // person -- see buildPersonPartnershipHistorySection().
        if (state.myPartnershipsLoading && !state.myPartnerships) {
            wrap.appendChild(mk('p', { text: S('loading') }));
            return wrap;
        }
        if (state.myPartnershipsError && !state.myPartnerships) {
            wrap.appendChild(mk('p', { class: 'k9tablet-error-text', text: errorText(state.myPartnershipsError) }));
            wrap.appendChild(mkButton(S('retry_label'), 'k9tablet-btn', loadMyPartnerships));
            return wrap;
        }
        if (!state.myPartnerships) {
            wrap.appendChild(mk('p', { text: S('loading') }));
            return wrap;
        }

        if (state.myPartnerships.featureEnabled === false) {
            wrap.appendChild(mk('p', { class: 'k9tablet-muted', text: S('partnerships_feature_disabled') }));
            return wrap;
        }

        var list = state.myPartnerships.partnerships || [];
        var active = null;
        for (var i = 0; i < list.length; i++) {
            if (list[i].active === true) { active = list[i]; break; }
        }

        wrap.appendChild(mk('h2', { class: 'k9tablet-section-heading', text: S('person_partnership_heading') }));
        if (active) {
            wrap.appendChild(buildPartnershipSection({ partnerCitizenid: active.partnerCitizenid, partnerName: active.partnerName, role: active.role }));
            wrap.appendChild(buildPartnershipTierDetail(active));
        } else {
            wrap.appendChild(mk('p', { class: 'k9tablet-muted', text: S('partnership_none') }));
        }

        wrap.appendChild(mk('h2', { class: 'k9tablet-section-heading', text: S('partnerships_history_heading') }));
        if (list.length === 0) {
            wrap.appendChild(mk('p', { class: 'k9tablet-muted', text: S('partnerships_history_empty') }));
        } else {
            wrap.appendChild(mk('p', { class: 'k9tablet-muted', text: formatTemplate(S('partnerships_count_summary_template'), { count: list.length }) }));
            if (state.myPartnerships.truncated) {
                wrap.appendChild(mk('p', { class: 'k9tablet-muted', text: formatTemplate(S('partnerships_truncated_notice_template'), { shown: list.length }) }));
            }
            var historyWrap = mk('div', { class: 'k9tablet-partnership-history-list' });
            for (var j = 0; j < list.length; j++) {
                historyWrap.appendChild(buildPartnershipHistoryRow(list[j]));
            }
            wrap.appendChild(historyWrap);
        }

        return wrap;
    }

    /**
     * K9 role assign / revert-to-human -- owner's own words: "assign de
     * assign give certs remove certs remove k9 ped and reverts them to a
     * human". Reachable for ANY citizenid this screen is currently showing,
     * including one reached via the console's "open by exact citizen ID"
     * box specifically BECAUSE they hold no active certification at all --
     * see this file's THE SECURITY RULE header and tablet:revertK9Ped's own
     * NO-UNBOUNDED-TRAP contract: this button is never disabled or hidden
     * based on anything about the TARGET's own certification/access state,
     * only on state.pendingAction (an unrelated mutation already in
     * flight), exactly like every other action button on this page.
     */
    function buildRoleControl() {
        var wrap = mk('div', { class: 'k9tablet-role-control' });
        var citizenid = state.person.citizenid;

        if (!state.peds || state.peds.length === 0) {
            wrap.appendChild(mk('p', { class: 'k9tablet-muted', text: S('role_no_peds_configured') }));
        } else {
            var row = mk('div', { class: 'k9tablet-role-row' });
            var select = mk('select', { class: 'k9tablet-role-select' });
            var firstModel = null;
            for (var i = 0; i < state.peds.length; i++) {
                var ped = state.peds[i];
                if (!ped || typeof ped.model !== 'string' || ped.model.length === 0) continue;
                if (firstModel === null) firstModel = ped.model;
                var option = mk('option', { text: (typeof ped.label === 'string' && ped.label.length > 0) ? ped.label : ped.model });
                option.setAttribute('value', ped.model);
                select.appendChild(option);
            }
            if (firstModel !== null) select.value = firstModel;
            row.appendChild(select);
            row.appendChild(mkButton(S('role_assign_label'), 'k9tablet-btn', function () {
                var modelName = select.value;
                if (!modelName) return;
                runMutation('tablet:assignK9Role', { targetCitizenId: citizenid, modelName: modelName }, function () {
                    refreshPersonAndSelf(citizenid);
                });
            }, { disabled: state.pendingAction }));
            wrap.appendChild(row);
            wrap.appendChild(mk('p', { class: 'k9tablet-muted k9tablet-hint', text: S('role_assign_hint') }));

            // Dog-character pin: keep this character as a dog whatever
            // happens to their certification (replaces /k9setdog).
            var summary = state.personSummary || {};
            if (summary.pinnedDogModel) {
                var pinnedLabel = summary.pinnedDogModel;
                for (var p = 0; p < state.peds.length; p++) {
                    if (state.peds[p] && state.peds[p].model === summary.pinnedDogModel && state.peds[p].label) pinnedLabel = state.peds[p].label;
                }
                wrap.appendChild(mk('p', { class: 'k9tablet-role-pinned', text: formatTemplate(S('role_pinned_status_template'), { breed: pinnedLabel }) }));
                wrap.appendChild(mkButton(S('role_unpin_label'), 'k9tablet-btn', function () {
                    runMutation('tablet:unpinDogCharacter', { targetCitizenId: citizenid }, function () {
                        refreshPersonAndSelf(citizenid);
                    });
                }, { disabled: state.pendingAction }));
            } else {
                wrap.appendChild(mkButton(S('role_pin_label'), 'k9tablet-btn', function () {
                    var modelName = select.value;
                    if (!modelName) return;
                    runMutation('tablet:pinDogCharacter', { targetCitizenId: citizenid, modelName: modelName }, function () {
                        refreshPersonAndSelf(citizenid);
                    });
                }, { disabled: state.pendingAction }));
                wrap.appendChild(mk('p', { class: 'k9tablet-muted k9tablet-hint', text: S('role_pin_hint') }));
            }
        }

        wrap.appendChild(mkConfirmButton(S('role_revert_label'), 'k9tablet-btn k9tablet-btn--danger', function () {
            runMutation('tablet:revertK9Ped', { targetCitizenId: citizenid }, function () {
                refreshPersonAndSelf(citizenid);
            });
        }, { disabled: state.pendingAction }));
        wrap.appendChild(mk('p', { class: 'k9tablet-muted k9tablet-hint', text: S('role_revert_hint') }));

        return wrap;
    }

    /**
     * A section of the Person screen that folds away (native <details>),
     * closed by default. Its heading is the clickable summary.
     *
     * REMEMBERS BEING LEFT OPEN: every action on this screen re-renders it
     * from scratch (render()), which would snap a <details> shut after
     * every tick of a checkbox inside it. state.personOpenSections keeps the
     * open ones open across those re-renders.
     * @param {string} key
     * @param {string} headingText
     * @param {HTMLElement[]} children
     * @returns {HTMLElement}
     */
    function buildPersonFoldout(key, headingText, children) {
        var details = mk('details', { class: 'k9tablet-person-foldout' });
        if (state.personOpenSections[key]) details.setAttribute('open', '');
        details.addEventListener('toggle', function () {
            state.personOpenSections[key] = details.open === true;
        });
        details.appendChild(mk('summary', { class: 'k9tablet-section-heading k9tablet-person-foldout-summary', text: headingText }));
        for (var i = 0; i < children.length; i++) details.appendChild(children[i]);
        return details;
    }

    /**
     * @param {string} kind -- 'certify' | 'decertify' | 'setTier' | 'renew' | 'grantSpecialization' | 'revokeSpecialization'
     * @param {string} departmentKey
     * @param {string} [extra] -- the chosen tier key (setTier) or specialization key (grant/revokeSpecialization); unused otherwise
     */
    function handlePersonCertAction(kind, departmentKey, extra) {
        var citizenid = state.person.citizenid;
        if (kind === 'certify') {
            var certifyPayload = { targetCitizenId: citizenid, departmentKey: departmentKey };
            if (extra) certifyPayload.k9Model = extra;
            runMutation('tablet:certify', certifyPayload, function () {
                refreshPersonAndSelf(citizenid);
            });
        } else if (kind === 'decertify') {
            runMutation('tablet:decertify', { targetCitizenId: citizenid, departmentKey: departmentKey }, function () {
                refreshPersonAndSelf(citizenid);
            });
        } else if (kind === 'setTier') {
            runMutation('tablet:setCertificationTier', { targetCitizenId: citizenid, departmentKey: departmentKey, tier: extra }, function () {
                refreshPersonAndSelf(citizenid);
            });
        } else if (kind === 'renew') {
            runMutation('tablet:renewCertification', { targetCitizenId: citizenid, departmentKey: departmentKey }, function () {
                refreshPersonAndSelf(citizenid);
            });
        } else if (kind === 'grantSpecialization') {
            runMutation('tablet:grantSpecialization', { targetCitizenId: citizenid, departmentKey: departmentKey, specialization: extra }, function () {
                refreshPersonAndSelf(citizenid);
            });
        } else if (kind === 'revokeSpecialization') {
            runMutation('tablet:revokeSpecialization', { targetCitizenId: citizenid, departmentKey: departmentKey, specialization: extra }, function () {
                refreshPersonAndSelf(citizenid);
            });
        }
    }

    function buildGiveXpControl() {
        var wrap = mk('div', { class: 'k9tablet-givexp' });
        var selfTarget = state.person.citizenid === state.viewer.citizenid;
        var disallowSelf = selfTarget && !state.viewer.allowSelfGrant;

        var input = mk('input', { class: 'k9tablet-givexp-input', attrs: { type: 'number', min: '1', placeholder: S('givexp_placeholder') } });
        if (typeof state.maxXpPerGrant === 'number' && state.maxXpPerGrant > 0) {
            input.setAttribute('max', String(state.maxXpPerGrant));
        }
        if (disallowSelf) {
            input.setAttribute('disabled', 'disabled');
            input.setAttribute('title', S('self_grant_disabled_title'));
        }
        wrap.appendChild(input);

        wrap.appendChild(mkButton(S('givexp_label'), 'k9tablet-btn', function () {
            var amount = Number(input.value);
            if (!isFinite(amount) || amount <= 0) return;
            runMutation('tablet:givexp', { targetCitizenId: state.person.citizenid, amount: amount }, function () {
                refreshPersonAndSelf(state.person.citizenid);
            });
        }, { disabled: state.pendingAction || disallowSelf, title: disallowSelf ? S('self_grant_disabled_title') : undefined }));

        wrap.appendChild(mk('p', { class: 'k9tablet-muted k9tablet-hint', text: S('givexp_max_hint') }));
        return wrap;
    }

    /**
     * Merges the four always-present shipped capabilities with whatever
     * server/permissionkeycatalog.lua's live catalog (state.permissionKeys,
     * populated by loadPermissionKeys() -- see openPerson()'s own
     * opportunistic call) currently reports, plus anything `heldKeys`
     * names that neither source accounts for. THREE buckets, in this
     * fixed order, each key appearing exactly once (first bucket wins):
     *
     *   1. CAPABILITY_ORDER's own four keys, ALWAYS present, in their
     *      existing fixed order, labelled via capabilityInfo() exactly as
     *      before this pass -- an operator who never touches the
     *      Permission Keys tab sees byte-identical output to today.
     *   2. Every OTHER catalog entry from a SUCCESSFUL state.permissionKeys
     *      fetch, in the order the server sent (alphabetical -- see that
     *      file's own ListPermissionCatalogKeys doc comment). A key only
     *      ever reaches this bucket when the catalog fetch actually
     *      confirmed it is currently known and non-tombstoned, so Grant is
     *      never offered for a key this page cannot confirm is real --
     *      state.permissionKeys stays null (or unrelated to this shape) on
     *      a failed/not-yet-run fetch, which simply yields zero rows here,
     *      never a synthesized "maybe grantable" guess.
     *   3. Any `heldKeys` entry bucket 1/2 didn't already cover. The ONLY
     *      way a currently-ACTIVE grant can name a key absent from a
     *      successful catalog fetch is server/permissionkeycatalog.lua's
     *      own tombstone behavior (ListPermissionCatalogKeys/
     *      IsKnownPermissionCatalogKey both exclude a tombstoned key
     *      entirely -- see that file's header "TOMBSTONE, NOT
     *      REFERENCE-COUNTED") -- so this bucket is rendered RETIRED and
     *      revoke-only, never offered a Grant button: a retired key that
     *      became invisible while still granted would otherwise be a
     *      permission nobody could take away. (The same bucket also
     *      quietly covers a held key while the catalog fetch simply
     *      hasn't resolved yet -- indistinguishable from "retired" from
     *      here, and the right action is the same either way: let the
     *      operator revoke it.)
     * @param {string[]} heldKeys
     * @returns {Array<{key:string,label:string,description:string,held:boolean,retired:boolean,grantable:boolean}>}
     */
    function resolveCapabilityRows(heldKeys) {
        heldKeys = Array.isArray(heldKeys) ? heldKeys : [];
        var rows = [];
        var seen = {};

        for (var i = 0; i < CAPABILITY_ORDER.length; i++) {
            var defaultKey = CAPABILITY_ORDER[i];
            seen[defaultKey] = true;
            var defaultInfo = capabilityInfo(defaultKey);
            rows.push({
                key: defaultKey,
                label: defaultInfo.label,
                description: defaultInfo.description || '',
                held: heldKeys.indexOf(defaultKey) !== -1,
                retired: false,
                grantable: true,
            });
        }

        if (Array.isArray(state.permissionKeys)) {
            for (var j = 0; j < state.permissionKeys.length; j++) {
                var entry = state.permissionKeys[j];
                if (!entry || typeof entry.key !== 'string' || seen[entry.key]) continue;
                seen[entry.key] = true;
                rows.push({
                    key: entry.key,
                    label: (typeof entry.label === 'string' && entry.label.length > 0) ? entry.label : entry.key,
                    description: (typeof entry.description === 'string') ? entry.description : '',
                    held: heldKeys.indexOf(entry.key) !== -1,
                    retired: false,
                    grantable: true,
                });
            }
        }

        for (var k = 0; k < heldKeys.length; k++) {
            var heldKey = heldKeys[k];
            if (typeof heldKey !== 'string' || heldKey.length === 0 || seen[heldKey]) continue;
            seen[heldKey] = true;
            var retiredInfo = capabilityInfo(heldKey);
            rows.push({
                key: heldKey,
                label: retiredInfo.label,
                description: retiredInfo.description || '',
                held: true,
                retired: true,
                grantable: false,
            });
        }

        return rows;
    }

    function buildCapabilityList(heldKeys) {
        var rows = resolveCapabilityRows(heldKeys);
        var wrap = mk('div', { class: 'k9tablet-capability-list' });
        var citizenid = state.person.citizenid;
        var selfTarget = citizenid === state.viewer.citizenid;

        for (var i = 0; i < rows.length; i++) {
            wrap.appendChild(buildCapabilityRow(rows[i], citizenid, selfTarget));
        }
        return wrap;
    }

    /**
     * One permission row -- a REAL checkbox (owner: "checkboxes that
     * actually do something... ticking or unticking a permission grants or
     * revokes it"), with a VISIBLE plain-English description line under the
     * label -- never a tooltip-only one, per THE HONESTY REQUIREMENT this
     * task exists to satisfy ("a raw key like k9.audit with a checkbox is
     * not enough"). `rowData.description` already carries the real catalog
     * text (server/permissionkeycatalog.lua, merged with the four shipped
     * capabilities' own DEFAULT_CAPABILITIES copy -- see
     * resolveCapabilityRows() above); this never invents a second source of
     * truth for it.
     *
     * Ticking calls tablet:grantPermission, unticking calls
     * tablet:revokePermission -- both re-verified server-side regardless of
     * this row's own disabled state (THE SECURITY RULE at the top of this
     * file).
     *
     * DISABLED WITH A REASON, never an enabled control the server will
     * refuse: server/permissions.lua's GrantPermission blocks self-grant
     * UNCONDITIONALLY (no config flag gates it, unlike XP's own
     * allowSelfGrant) -- so an UNHELD row is disabled outright when this
     * person IS the viewer, with a title explaining why, rather than
     * rendering a checkbox that would always come back 'self_grant_blocked'.
     * Revoke carries no such restriction server-side, so a HELD row stays
     * enabled even on the viewer's own record.
     *
     * NEVER OPTIMISTIC: `checkbox.checked` is set from `rowData.held` (the
     * last CONFIRMED server state) every render, never flipped locally
     * ahead of the mutation resolving -- runMutation()'s own onSettled
     * always re-pulls the authoritative record via refreshPersonAndSelf(),
     * so a failed grant/revoke simply re-renders back to its real state
     * with the failure reason surfaced through state.actionNotice
     * (mutationErrorText) -- never a tick left sitting there implying a
     * success that did not happen.
     * @param {{key:string,label:string,description:string,held:boolean,retired:boolean,grantable:boolean}} rowData
     * @param {string} citizenid
     * @param {boolean} selfTarget
     */
    function buildCapabilityRow(rowData, citizenid, selfTarget) {
        var row = mk('div', { class: 'k9tablet-capability-row' });

        var textWrap = mk('div', { class: 'k9tablet-capability-text' });
        var labelLine = mk('div', { class: 'k9tablet-capability-label', text: rowData.label });
        if (rowData.retired) {
            labelLine.appendChild(mk('span', { class: 'k9tablet-muted', text: ' (' + S('permission_key_retired_badge') + ')' }));
        }
        textWrap.appendChild(labelLine);
        textWrap.appendChild(mk('div', {
            class: 'k9tablet-capability-description',
            text: (rowData.description && rowData.description.length > 0) ? rowData.description : S('capability_no_description'),
        }));
        row.appendChild(textWrap);

        var disallowSelfGrant = selfTarget && !rowData.held;
        // THE SHARED RATE LIMIT -- see PERMISSION_ACTION_MIN_INTERVAL_MS's
        // own doc comment. Disables every capability checkbox for a short
        // window after any one of them fires, so a fast operator ticking
        // several in a row is told to slow down BEFORE the server would
        // refuse the next one as rate_limited, not only after.
        var msSinceLastMutation = Date.now() - (state.lastPermissionMutationAt || 0);
        var onCooldown = msSinceLastMutation < PERMISSION_ACTION_MIN_INTERVAL_MS;
        var checkboxDisabled = state.pendingAction || (!rowData.held && !rowData.grantable) || disallowSelfGrant || onCooldown;
        var disabledTitle = disallowSelfGrant ? S('capability_self_grant_disabled_title')
            : (onCooldown ? S('capability_rate_limited_wait_title') : undefined);

        var toggle = mk('label', { class: 'k9tablet-capability-toggle', title: disabledTitle });
        var checkbox = mk('input', { class: 'k9tablet-capability-checkbox', attrs: { type: 'checkbox' } });
        checkbox.checked = rowData.held === true;
        if (checkboxDisabled) checkbox.setAttribute('disabled', 'disabled');
        checkbox.addEventListener('change', function () {
            // Marks the cooldown window as starting NOW, before the fetch
            // even resolves -- this is a client-side PACING convenience
            // only (THE SECURITY RULE), never a substitute for the
            // server's own PermissionActionCooldown, which is re-checked
            // regardless and remains the sole real enforcement.
            state.lastPermissionMutationAt = Date.now();
            setTimeout(render, PERMISSION_ACTION_MIN_INTERVAL_MS + 50);
            if (checkbox.checked) {
                runMutation('tablet:grantPermission', { targetCitizenId: citizenid, permission: rowData.key }, function () {
                    refreshPersonAndSelf(citizenid);
                });
            } else {
                runMutation('tablet:revokePermission', { targetCitizenId: citizenid, permission: rowData.key }, function () {
                    refreshPersonAndSelf(citizenid);
                });
            }
        });
        toggle.appendChild(checkbox);
        row.appendChild(toggle);

        return row;
    }

    /**
     * SECTIONED, NOT A WALL (2026-09-01, owner's own words: "update
     * everything where its easier to understand better section management
     * etc and i want it where everything is super easy to understand and
     * everything is diffrentied better", and earlier "there is still
     * search boxes in the ui please change it where its boxes i check").
     *
     * This section already rendered a CHECKBOX per ability -- the boxes the
     * owner wanted were there. What made it read as "a search box" was the
     * shape around them: one flat, unbroken table of every Config.Features
     * key (57 rows on a default server) with a bare text input sitting on
     * top of it and nothing else. A bare input above a long list looks like
     * the thing you are supposed to use; the fact that it was only an
     * OPTIONAL filter over a list you could equally just scroll and tick
     * was never stated anywhere on screen.
     *
     * Two changes, no behaviour change to any grant/revoke path:
     *
     * 1. The rows are grouped into the SAME twelve domain sections, in the
     *    SAME declared order, that the My Record screen has always used
     *    (FEATURE_DOMAIN_ORDER / groupFeaturesByDomain / the
     *    feature_group_*_heading strings). Those two screens list the same
     *    abilities, so showing them in two different shapes -- sectioned
     *    there, one flat wall here -- was itself a thing to have to learn.
     *    Now scanning to the right section replaces having to search, which
     *    is what makes the checkboxes the obvious interaction.
     *
     * 2. The filter is labelled as a filter, is explicitly marked optional,
     *    and reports what it is currently doing ("Showing 6 of 57") with a
     *    Clear button beside it whenever it is narrowing anything.
     *
     * One real bug fixed on the way: filtering down to zero matches printed
     * `no_abilities` -- "This person has no abilities" -- which is a
     * statement about the PERSON, not about the filter, and is false
     * whenever the unfiltered list is non-empty. A filter that finds
     * nothing now says so, and offers the way back.
     */
    function buildPersonFeaturesSection() {
        var wrap = mk('div', { class: 'k9tablet-feature-section' });

        if (state.personFeaturesLoading && !state.personFeatures) {
            wrap.appendChild(mk('p', { text: S('loading') }));
            return wrap;
        }
        if (state.personFeaturesError && !state.personFeatures) {
            wrap.appendChild(mk('p', { class: 'k9tablet-error-text', text: errorText(state.personFeaturesError) }));
            wrap.appendChild(mkButton(S('retry_label'), 'k9tablet-btn', function () { loadPersonFeatures(state.person.citizenid); }));
            return wrap;
        }
        if (!state.personFeatures) {
            wrap.appendChild(mk('p', { text: S('loading') }));
            return wrap;
        }

        // Server-disabled features are dropped before anything else here --
        // see withoutGloballyDisabled(). They are not grantable, blockable
        // or earnable, so on an admin screen whose whole purpose is those
        // three actions they are rows that can never be acted on. Runtime
        // Control remains the one screen that shows them.
        var all = withoutGloballyDisabled(state.personFeatures.features || []);

        // The person genuinely has nothing to show. Say that, and do not
        // render a filter for an empty list -- there is nothing to narrow.
        if (all.length === 0) {
            wrap.appendChild(mk('p', { class: 'k9tablet-muted', text: S('no_abilities') }));
            return wrap;
        }

        var q = (state.personFeatureQuery || '').toLowerCase();
        var filtered = q.length === 0 ? all : all.filter(function (f) {
            var haystack = (featureLabel(f) + ' ' + (f.key || '') + ' ' + (f.category || '')).toLowerCase();
            return haystack.indexOf(q) !== -1;
        });

        wrap.appendChild(buildPersonFeatureFilter(all.length, filtered.length));

        // Filter matched nothing. This is about the FILTER, never about the
        // person -- see this function's own header.
        if (filtered.length === 0) {
            // The filter bar rendered just above is already showing its own
            // Clear button (0 shown of N is still "narrowing"), so this
            // state needs the explanation, not a second identical control.
            wrap.appendChild(mk('p', { class: 'k9tablet-muted', text: S('feature_filter_no_matches') }));
            return wrap;
        }

        var table = mk('table', { class: 'k9tablet-table k9tablet-feature-table' });
        var thead = mk('thead');
        var headRow = mk('tr');
        var columns = [S('feature_column'), S('status_column'), S('column_block_effect'), S('column_actions')];
        columns.forEach(function (h) {
            headRow.appendChild(mk('th', { text: h }));
        });
        thead.appendChild(headRow);
        table.appendChild(thead);

        var tbody = mk('tbody');
        var grouped = groupFeaturesByDomain(filtered);

        // ONE PASS OVER THE SAME STABLE, DECLARED ORDER buildMyFeaturesList()
        // walks, with 'other' last. A domain with no matching rows renders
        // no heading at all, so filtering collapses the sections down to
        // only the ones that still have something in them rather than
        // leaving a column of empty labels.
        var domains = FEATURE_DOMAIN_ORDER.concat(['other']);
        domains.forEach(function (domain) {
            var rows = grouped[domain];
            if (!rows || rows.length === 0) return;

            // A header ROW inside the one table, not a separate table per
            // section: the columns stay aligned all the way down, which is
            // the whole reason this screen is a table and My Record's own
            // list is not.
            var headingTr = mk('tr', { class: 'k9tablet-feature-group-row' });
            var headingTh = mk('th', {
                class: 'k9tablet-feature-group-row-cell k9tablet-feature-group-row-cell--' + domain,
                attrs: { colspan: String(columns.length), scope: 'colgroup' },
            });
            headingTh.appendChild(mk('span', {
                class: 'k9tablet-feature-group-row-label',
                text: domain === 'other' ? S('feature_group_other_heading') : S(featureGroupHeadingKey(domain)),
            }));
            // The per-section count is what makes "did my filter hide
            // something in here" answerable without counting rows by eye.
            headingTh.appendChild(mk('span', {
                class: 'k9tablet-feature-group-row-count',
                text: formatTemplate(S('feature_group_row_count_template'), { count: rows.length }),
            }));
            headingTr.appendChild(headingTh);
            tbody.appendChild(headingTr);

            for (var i = 0; i < rows.length; i++) {
                tbody.appendChild(buildPersonFeatureRow(rows[i]));
            }
        });

        table.appendChild(tbody);
        wrap.appendChild(table);
        return wrap;
    }

    /**
     * ONE FILTER BAR FOR EVERY CLIENT-SIDE FILTERED LIST on this page --
     * a labelled, explicitly optional narrowing tool, never the primary
     * interaction. See buildPersonFeaturesSection()'s own header for the
     * reasoning; this is the shared implementation so the abilities list
     * and the Command Reference cannot drift into looking like two
     * different ideas.
     *
     * DELIBERATELY NOT USED for the roster or the online-players box.
     * Those are SERVER-SIDE searches -- each keystroke re-queries and the
     * server decides what comes back -- so there is no local "total" to
     * be showing a fraction of, and a "Showing 4 of 9" there would be
     * inventing a denominator this page does not have. They keep their
     * plain search input (see their own call sites), and only ever gain
     * the visible label.
     *
     * @param {object} opts
     * @param {string} opts.id DOM id, so the <label> can point at the input
     * @param {string} opts.labelText already-localized caption
     * @param {string} opts.placeholder already-localized placeholder
     * @param {string} opts.value current query
     * @param {number} opts.total every row before filtering
     * @param {number} opts.shown how many survive the current filter
     * @param {function(string):void} opts.onChange
     * @returns {HTMLElement}
     */
    function buildListFilterBar(opts) {
        var bar = mk('div', { class: 'k9tablet-feature-filter' });

        bar.appendChild(mk('label', {
            class: 'k9tablet-feature-filter-label',
            text: opts.labelText,
            attrs: { for: opts.id },
        }));

        var search = mk('input', {
            class: 'k9tablet-search k9tablet-feature-filter-input',
            attrs: { type: 'text', id: opts.id, placeholder: opts.placeholder },
        });
        search.value = opts.value || '';
        search.addEventListener('input', function (e) {
            opts.onChange(e.target.value);
        });
        bar.appendChild(search);

        // Only ever says something when the filter is actually narrowing.
        // An unfiltered list showing all 57 of 57 does not need telling.
        if (opts.shown !== opts.total) {
            bar.appendChild(mk('span', {
                class: 'k9tablet-feature-filter-count',
                text: formatTemplate(S('feature_filter_showing_template'), { count: opts.shown, total: opts.total }),
            }));
            bar.appendChild(mkButton(S('feature_filter_clear_label'), 'k9tablet-btn k9tablet-btn--small', function () {
                opts.onChange('');
            }));
        }

        return bar;
    }

    /**
     * buildPersonFeaturesSection()'s own filter, on the shared bar above.
     * @param {number} totalCount every ability on this person's record
     * @param {number} shownCount how many survive the current filter
     * @returns {HTMLElement}
     */
    function buildPersonFeatureFilter(totalCount, shownCount) {
        return buildListFilterBar({
            id: 'k9tablet-person-feature-filter',
            labelText: S('feature_filter_label'),
            placeholder: S('search_features_placeholder'),
            value: state.personFeatureQuery,
            total: totalCount,
            shown: shownCount,
            onChange: function (v) {
                state.personFeatureQuery = v;
                render();
            },
        });
    }

    /** @param {{category?:string}} feature @returns {string?} name-cell
     * class for this row's domain -- DATA-DRIVEN off FEATURE_DOMAIN_STYLE
     * (shared with buildMyFeaturesList()'s own My Record rendering, single
     * source of truth for which domains get a visual accent at all): only
     * a 'color'-style domain (scent today) gets one; every other domain,
     * known or not, returns null (no class at all, exactly the pre-domain-
     * grouping default row this table has always used). */
    function personFeatureNameCellClass(feature) {
        if (feature && FEATURE_DOMAIN_STYLE[feature.category] === 'color') {
            return 'k9tablet-person-feature-name--' + feature.category;
        }
        return null;
    }

    /**
     * THE HONESTY REQUIREMENT this task exists to satisfy: this row's
     * Block Effect cell renders BEFORE Actions, so an operator sees what a
     * block would actually do to this feature BEFORE deciding whether to
     * press it -- never after. See featureBlockEnforcement() above for the
     * three-state contract this reads and why it is never derived from
     * `feature.key` here.
     */
    /**
     * SUBTLE "why can they do that" MARKER (owner-directed: "why can this
     * person do that" should be answerable at a glance, not by reading
     * two fields -- but a small, quiet marker, never a prominent badge;
     * the owner has said several times he wants less clutter, not more).
     * `feature.viaHighCommand` (server/tablet.lua's own ResolveFeatureState,
     * DISPLAY-GAP FIX pass) is `true` ONLY when this row's `state` came
     * back 'available' SOLELY because of this target's own rank -- never
     * for a row this person would have earned honestly regardless (a real
     * grant, real certification, or a feature that needed neither). Same
     * muted-parenthetical style as the Command Reference screen's own
     * '(Admin)' marker (cmdref_admin_badge) -- deliberately reused, not a
     * new visual language.
     * @param {HTMLElement} td
     * @param {{viaHighCommand?:boolean}} feature
     */
    function appendViaHighCommandMarker(td, feature) {
        if (!feature.viaHighCommand) return;
        td.appendChild(mk('span', { class: 'k9tablet-muted', text: ' (' + S('feature_via_high_command_marker') + ')', title: S('feature_via_high_command_hint') }));
    }

    function buildPersonFeatureRow(feature) {
        var tr = mk('tr');
        var nameCls = personFeatureNameCellClass(feature);
        tr.appendChild(nameCls ? mk('td', { class: nameCls, text: featureLabel(feature) }) : mk('td', { text: featureLabel(feature) }));
        // 'text'-style domain (vehicle today) -- same reasoning as
        // buildVehicleFeatureRow() above: a full sentence replaces the
        // terse state badge entirely, never a colour badge, for admins
        // looking at this same feature on a specific person's record too.
        // DATA-DRIVEN off the SAME FEATURE_DOMAIN_STYLE table
        // buildMyFeaturesList() reads -- every other row (including
        // scent, and every domain added this pass) keeps the ORIGINAL
        // badge cell.
        if (FEATURE_DOMAIN_STYLE[feature.category] === 'text') {
            var vehicleStateTd = mk('td', { class: 'k9tablet-feature-state--' + feature.state });
            vehicleStateTd.appendChild(mk('p', { class: 'k9tablet-feature-vehicle-sentence', text: vehicleFeatureSentence(feature) }));
            appendViaHighCommandMarker(vehicleStateTd, feature);
            tr.appendChild(vehicleStateTd);
        } else {
            var stateTd = mk('td', { class: 'k9tablet-feature-state--' + feature.state, text: featureStateLabel(feature.state) });
            appendViaHighCommandMarker(stateTd, feature);
            tr.appendChild(stateTd);
        }

        var citizenid = state.person.citizenid;
        var key = feature.key;
        var enforcement = featureBlockEnforcement(feature);

        var blockEffectTd = mk('td', { class: 'k9tablet-block-effect' });

        if (!feature.globallyEnabled) {
            // Step 1 is absolute -- see this file's header. NO controls
            // rendered at all for a globally-disabled feature: a grant here
            // would produce a button that silently does nothing, and this
            // page must not offer that. The Block Effect column stays
            // blank/muted for the same reason -- whether a block would be
            // honoured is moot when the feature cannot run at all.
            tr.appendChild(blockEffectTd);
            var offActionsTd = mk('td', { class: 'k9tablet-feature-actions' });
            offActionsTd.appendChild(mk('span', { class: 'k9tablet-muted', text: S('state_global_off') }));
            tr.appendChild(offActionsTd);
            return tr;
        }

        if (enforcement === 'not_enforceable') {
            blockEffectTd.appendChild(mk('span', {
                class: 'k9tablet-block-badge k9tablet-block-badge--unavailable',
                text: S('block_not_enforceable_note'),
            }));
        } else {
            blockEffectTd.appendChild(mk('span', {
                class: 'k9tablet-block-badge k9tablet-block-badge--' + enforcement,
                text: blockEnforcementBadgeLabel(enforcement),
                title: blockEnforcementBadgeTitle(enforcement),
            }));
        }
        tr.appendChild(blockEffectTd);

        var actionsTd = mk('td', { class: 'k9tablet-feature-actions' });

        // Block/Unblock -- offered for every feature EXCEPT one this page
        // has been told, server-side, can never honour one at all
        // (`enforcement === 'not_enforceable'`) -- see this file's own
        // PersonFeaturesResult doc comment above for the two ways that
        // happens (no per-citizenid ability here to gate in the first
        // place, e.g. an administrative switch like CommandTablet; or a
        // deliberate design decision, e.g. a termination path's
        // escape-hatch path). Offering a button that can never do
        // anything is exactly the dishonest control this task exists to
        // remove -- HIDDEN, not merely labeled, for this one case. A
        // 'client_enforced' feature (e.g. ThermalVision/NightVision) is
        // DELIBERATELY NOT included in this hidden case -- its Block
        // button genuinely does something, just with the weaker,
        // client-side-only guarantee the badge above already discloses.
        // `feature.blocked` (a block row may already exist from before
        // this distinction was surfaced) is still shown via the state
        // badge above regardless.
        if (enforcement !== 'not_enforceable') {
            if (feature.blocked) {
                actionsTd.appendChild(mkButton(S('unblock_label'), 'k9tablet-btn', function () {
                    runMutation('tablet:unblockFeature', { targetCitizenId: citizenid, feature: key }, function () {
                        refreshPersonFeaturesAndSelf(citizenid);
                    });
                }, { disabled: state.pendingAction }));
            } else {
                actionsTd.appendChild(mkConfirmButton(S('block_label'), 'k9tablet-btn k9tablet-btn--danger', function () {
                    runMutation('tablet:blockFeature', { targetCitizenId: citizenid, feature: key }, function () {
                        refreshPersonFeaturesAndSelf(citizenid);
                    });
                }, { disabled: state.pendingAction }));
            }
        }

        // Grant/Revoke -- ONLY when this feature is actually grant-gated.
        if (feature.requiresGrant) {
            if (feature.granted) {
                actionsTd.appendChild(mkConfirmButton(S('revoke_label'), 'k9tablet-btn k9tablet-btn--danger', function () {
                    runMutation('tablet:revokeFeature', { targetCitizenId: citizenid, feature: key }, function () {
                        refreshPersonFeaturesAndSelf(citizenid);
                    });
                }, { disabled: state.pendingAction }));
            } else {
                actionsTd.appendChild(mkButton(S('grant_label'), 'k9tablet-btn', function () {
                    runMutation('tablet:grantFeature', { targetCitizenId: citizenid, feature: key }, function () {
                        refreshPersonFeaturesAndSelf(citizenid);
                    });
                }, { disabled: state.pendingAction }));
            }
        }

        tr.appendChild(actionsTd);
        return tr;
    }

    // ---- Tablet theme screen (high command OR a delegated 'k9.tablettheme' grant -- see canManageTabletTheme()) ----

    /**
     * Six inputs, one per field server/runtimecontrol.lua's own
     * ValidateFullTheme accepts -- see this file's header THE SECURITY RULE:
     * every constraint here (the `<input type="color">` picker's own
     * #RRGGBB-only value space, the density `<select>`'s fixed two-option
     * list, the header-title `maxlength`) is a UX convenience only. The
     * server re-validates the FULL merged theme from scratch on every
     * tabletSetTheme call regardless of what this page sends -- a modified
     * client posting an out-of-band value gets back
     * {ok:false, error:'invalid_field', field:...} same as a legitimate
     * request that somehow raced a stricter config change.
     */
    function buildThemeScreen() {
        var wrap = mk('div', { class: 'k9tablet-screen' });
        wrap.appendChild(mk('h2', { class: 'k9tablet-section-heading', text: S('theme_heading') }));

        if (state.themeLoading && !state.themeDraft) {
            wrap.appendChild(mk('p', { text: S('loading') }));
            return wrap;
        }
        if (state.themeError && !state.themeDraft) {
            wrap.appendChild(mk('p', { class: 'k9tablet-error-text', text: errorText(state.themeError) }));
            wrap.appendChild(mkButton(S('retry_label'), 'k9tablet-btn', loadTheme));
            return wrap;
        }
        if (!state.themeDraft) {
            wrap.appendChild(mk('p', { text: S('loading') }));
            return wrap;
        }

        if (!state.themingEnabled) {
            wrap.appendChild(mk('p', { class: 'k9tablet-muted', text: S('theme_disabled_note') }));
        }

        var draft = state.themeDraft;
        var form = mk('div', { class: 'k9tablet-theme-form' });

        form.appendChild(buildThemeColorField('primaryColor', S('theme_primary_label'), draft));
        form.appendChild(buildThemeColorField('accentColor', S('theme_accent_label'), draft));
        form.appendChild(buildThemeColorField('backgroundColor', S('theme_background_label'), draft));
        form.appendChild(buildThemeColorField('textColor', S('theme_text_label'), draft));

        var densityRow = mk('div', { class: 'k9tablet-theme-field' + (state.themeFieldError === 'density' ? ' k9tablet-theme-field--invalid' : '') });
        densityRow.appendChild(mk('label', { class: 'k9tablet-theme-field-label', text: S('theme_density_label') }));
        var densitySelect = mk('select', { class: 'k9tablet-theme-density-select' });
        for (var i = 0; i < THEME_DENSITY_OPTIONS.length; i++) {
            var value = THEME_DENSITY_OPTIONS[i];
            var opt = mk('option', { text: value === 'compact' ? S('theme_density_compact') : S('theme_density_comfortable') });
            opt.setAttribute('value', value);
            densitySelect.appendChild(opt);
        }
        densitySelect.value = draft.density || DEFAULT_THEME.density;
        densitySelect.addEventListener('input', function (e) { draft.density = e.target.value; });
        densityRow.appendChild(densitySelect);
        form.appendChild(densityRow);

        var titleRow = mk('div', { class: 'k9tablet-theme-field' + (state.themeFieldError === 'headerTitle' ? ' k9tablet-theme-field--invalid' : '') });
        titleRow.appendChild(mk('label', { class: 'k9tablet-theme-field-label', text: S('theme_header_title_label') }));
        var titleInput = mk('input', { class: 'k9tablet-theme-title-input', attrs: { type: 'text', maxlength: '40' } });
        titleInput.value = draft.headerTitle || '';
        titleInput.addEventListener('input', function (e) { draft.headerTitle = e.target.value; });
        titleRow.appendChild(titleInput);
        form.appendChild(titleRow);

        wrap.appendChild(form);

        var actions = mk('div', { class: 'k9tablet-theme-actions' });
        actions.appendChild(mkButton(S('theme_save_label'), 'k9tablet-btn', saveTheme, { disabled: state.pendingAction || !state.themingEnabled }));
        actions.appendChild(mkConfirmButton(S('theme_reset_label'), 'k9tablet-btn k9tablet-btn--danger', resetThemeToDefault, { disabled: state.pendingAction || !state.themingEnabled }));
        wrap.appendChild(actions);

        return wrap;
    }

    /** One `<input type="color">` row bound to `draft[field]`, mutating the
     * WORKING COPY directly (never `state.theme` itself, and never sent
     * anywhere until saveTheme() below) -- see state.themeDraft's own
     * comment.
     * @param {string} field @param {string} label @param {object} draft */
    function buildThemeColorField(field, label, draft) {
        var row = mk('div', { class: 'k9tablet-theme-field' + (state.themeFieldError === field ? ' k9tablet-theme-field--invalid' : '') });
        row.appendChild(mk('label', { class: 'k9tablet-theme-field-label', text: label }));
        var input = mk('input', { class: 'k9tablet-theme-color-input', attrs: { type: 'color' } });
        input.value = draft[field] || DEFAULT_THEME[field];
        input.addEventListener('input', function (e) { draft[field] = e.target.value; });
        row.appendChild(input);
        return row;
    }

    // ---- Certification tier editing screen (high command only) ----

    /**
     * Owner's own words: "Allow high command to edit the tiers trainee
     * certified senior etc add more roles edit permissions for those roles
     * etc." Renders the LIVE catalogue from state.certTiers (populated by
     * loadCertTiers() -- see that function's own comment on why this is
     * never a hardcoded list), a per-row Edit/Move Up/Move Down/Delete set
     * of controls, and (when a draft is open) the add/edit form below the
     * table. server/certtiers.lua's own CanManageCertTiers is the real
     * authorization gate, re-checked on every one of the four callbacks
     * this screen calls -- see THE SECURITY RULE.
     */
    /**
     * The three catalogs -- certification tiers, permission keys, XP ranks
     * -- as three sections of one screen (plan item G). Each still asks its
     * own feature-flag question, because two of the three have one and
     * merging the tabs must not merge the gates.
     * @returns {Element}
     */
    function buildCatalogsScreen() {
        var wrap = mk('div', { class: 'k9tablet-screen' });
        wrap.appendChild(buildRolesScreen());
        if (surfaceEnabled('permission_keys')) {
            wrap.appendChild(buildPermissionKeysScreen());
        }
        if (surfaceEnabled('xp_tiers')) {
            wrap.appendChild(buildXpTiersScreen());
        }
        return wrap;
    }

    // ---- K9 Roles editor (Server Settings > Catalogs) ----
    // server/roles.lua. Tiers and specializations merged into one list of
    // roles: a name, the XP it switches on at, and what it unlocks. Anyone
    // may view the list; only high command sees the edit controls (the
    // server checks again on every save and delete).

    function buildRolesScreen() {
        var wrap = mk('div', { class: 'k9tablet-home-section' });
        wrap.appendChild(mk('h2', { class: 'k9tablet-section-heading', text: S('roles_heading') }));
        wrap.appendChild(mk('p', { class: 'k9tablet-muted k9tablet-hint', text: S('roles_intro') }));

        if (state.rolesLoading && !state.roles) {
            wrap.appendChild(mk('p', { text: S('loading') }));
            return wrap;
        }
        if (state.rolesError && !state.roles) {
            wrap.appendChild(mk('p', { class: 'k9tablet-error-text', text: errorText(state.rolesError) }));
            wrap.appendChild(mkButton(S('retry_label'), 'k9tablet-btn', loadRoles));
            return wrap;
        }
        if (!state.roles) {
            wrap.appendChild(mk('p', { text: S('loading') }));
            return wrap;
        }

        var table = mk('table', { class: 'k9tablet-table k9tablet-roles-table' });
        var thead = mk('thead');
        var headRow = mk('tr');
        [S('roles_column_name'), S('roles_column_xp'), S('roles_column_unlocks'), S('column_actions')].forEach(function (h) {
            headRow.appendChild(mk('th', { text: h }));
        });
        thead.appendChild(headRow);
        table.appendChild(thead);
        var tbody = mk('tbody');
        for (var i = 0; i < state.roles.length; i++) tbody.appendChild(buildRoleEditorRow(state.roles[i]));
        table.appendChild(tbody);
        wrap.appendChild(table);

        if (state.rolesCanManage) {
            if (state.roleDraft) {
                wrap.appendChild(buildRoleDraftForm());
            } else {
                wrap.appendChild(mkButton(S('roles_add_label'), 'k9tablet-btn', function () {
                    state.roleDraft = { key: null, label: '', xpRequired: 0, unlocks: {} };
                    state.roleFieldError = null;
                    render();
                }, { disabled: state.pendingAction }));
            }
        }
        return wrap;
    }

    /** @param {string} unlockKey @returns {string} */
    function roleUnlockLabel(unlockKey) {
        for (var i = 0; i < state.rolesUnlockOptions.length; i++) {
            if (state.rolesUnlockOptions[i].key === unlockKey) return state.rolesUnlockOptions[i].label;
        }
        return unlockKey;
    }

    function buildRoleEditorRow(role) {
        var tr = mk('tr');
        tr.appendChild(mk('td', { text: role.label }));
        tr.appendChild(mk('td', { text: String(role.xpRequired) }));
        var unlockLabels = (role.unlocks || []).map(roleUnlockLabel);
        tr.appendChild(mk('td', { class: 'k9tablet-muted', text: unlockLabels.length > 0 ? unlockLabels.join(', ') : S('roles_no_unlocks') }));
        var actions = mk('td', { class: 'k9tablet-cert-tier-actions' });
        if (state.rolesCanManage) {
            actions.appendChild(mkButton(S('roles_edit_label'), 'k9tablet-btn', function () {
                var set = {};
                (role.unlocks || []).forEach(function (u) { set[u] = true; });
                state.roleDraft = { key: role.key, label: role.label, xpRequired: role.xpRequired, unlocks: set };
                state.roleFieldError = null;
                render();
            }, { disabled: state.pendingAction }));
            actions.appendChild(mkConfirmButton(S('roles_delete_label'), 'k9tablet-btn k9tablet-btn--danger', function () {
                deleteRole(role.key);
            }, { disabled: state.pendingAction }));
        }
        tr.appendChild(actions);
        return tr;
    }

    function buildRoleDraftForm() {
        var draft = state.roleDraft;
        var wrap = mk('div', { class: 'k9tablet-cert-tier-form k9tablet-role-form' });

        var nameRow = mk('div', { class: 'k9tablet-theme-field' + (state.roleFieldError === 'label' ? ' k9tablet-theme-field--invalid' : '') });
        nameRow.appendChild(mk('label', { class: 'k9tablet-theme-field-label', text: S('roles_name_label') }));
        var nameInput = mk('input', { class: 'k9tablet-role-name-input', attrs: { type: 'text', maxlength: '60' } });
        nameInput.value = draft.label;
        nameInput.addEventListener('input', function (e) { draft.label = e.target.value; });
        nameRow.appendChild(nameInput);
        wrap.appendChild(nameRow);

        var xpRow = mk('div', { class: 'k9tablet-theme-field' + (state.roleFieldError === 'xpRequired' ? ' k9tablet-theme-field--invalid' : '') });
        xpRow.appendChild(mk('label', { class: 'k9tablet-theme-field-label', text: S('roles_xp_label') }));
        var xpInput = mk('input', { class: 'k9tablet-role-xp-input', attrs: { type: 'number', min: '0', step: '1' } });
        xpInput.value = String(draft.xpRequired);
        xpInput.addEventListener('input', function (e) { draft.xpRequired = e.target.value; });
        xpRow.appendChild(xpInput);
        wrap.appendChild(xpRow);

        var unlocksWrap = mk('div', { class: 'k9tablet-cert-tier-capabilities' + (state.roleFieldError === 'unlocks' ? ' k9tablet-theme-field--invalid' : '') });
        unlocksWrap.appendChild(mk('p', { class: 'k9tablet-theme-field-label', text: S('roles_unlocks_label') }));
        state.rolesUnlockOptions.forEach(function (opt) {
            var row = mk('label', { class: 'k9tablet-cert-tier-capability-row' });
            var box = mk('input', { attrs: { type: 'checkbox' } });
            box.checked = draft.unlocks[opt.key] === true;
            box.addEventListener('change', function (e) { draft.unlocks[opt.key] = !!(e.target && e.target.checked); });
            row.appendChild(box);
            row.appendChild(mk('span', { text: opt.label }));
            unlocksWrap.appendChild(row);
        });
        wrap.appendChild(unlocksWrap);

        var actions = mk('div', { class: 'k9tablet-theme-actions' });
        actions.appendChild(mkButton(S('roles_save_label'), 'k9tablet-btn', saveRoleDraft, { disabled: state.pendingAction }));
        actions.appendChild(mkButton(S('roles_cancel_label'), 'k9tablet-link-btn', function () {
            state.roleDraft = null;
            state.roleFieldError = null;
            render();
        }));
        wrap.appendChild(actions);
        return wrap;
    }

    function loadRoles() {
        state.rolesLoading = true;
        state.rolesError = null;
        render();
        fetchNui('tablet:rolesList', {}).then(function (result) {
            state.rolesLoading = false;
            if (!result || result.ok !== true) {
                state.rolesError = result || { error: 'unknown_error' };
                render();
                return;
            }
            state.roles = Array.isArray(result.roles) ? result.roles : [];
            state.rolesUnlockOptions = Array.isArray(result.unlockOptions) ? result.unlockOptions : [];
            state.rolesCanManage = result.canManage === true;
            applyRoleCatalog(state.roles);
            render();
        });
    }

    /** @param {object} result @returns {string} */
    function roleErrorText(result) {
        switch (result && result.error) {
            case 'invalid_label': return S('roles_error_invalid_label');
            case 'invalid_xp': return S('roles_error_invalid_xp');
            case 'invalid_unlocks': return S('roles_error_invalid_unlocks');
            case 'too_many_roles': return S('roles_error_too_many');
            case 'unknown_role': return S('roles_error_unknown');
            case 'role_in_use_by_shop_items':
                return formatTemplate(S('roles_error_in_use_by_shop_template'), {
                    items: Array.isArray(result.items) ? result.items.join(', ') : '',
                });
            default: return errorText(result);
        }
    }

    function saveRoleDraft() {
        if (state.pendingAction || !state.roleDraft) return;
        var draft = state.roleDraft;
        var unlocks = [];
        for (var k in draft.unlocks) {
            if (Object.prototype.hasOwnProperty.call(draft.unlocks, k) && draft.unlocks[k] === true) unlocks.push(k);
        }
        var xp = Number(draft.xpRequired);
        state.pendingAction = true;
        state.roleFieldError = null;
        state.actionNotice = { kind: 'ok', text: S('action_working') };
        render();
        fetchNui('tablet:rolesSave', { key: draft.key, label: draft.label, xpRequired: xp, unlocks: unlocks }).then(function (result) {
            state.pendingAction = false;
            if (result && result.ok === true) {
                if (Array.isArray(result.roles)) { state.roles = result.roles; applyRoleCatalog(result.roles); }
                state.roleDraft = null;
                state.actionNotice = { kind: 'ok', text: S('roles_saved') };
            } else {
                state.roleFieldError = (result && result.field) || null;
                state.actionNotice = { kind: 'error', text: roleErrorText(result) };
            }
            render();
        });
    }

    function deleteRole(key) {
        if (state.pendingAction) return;
        state.pendingAction = true;
        state.actionNotice = { kind: 'ok', text: S('action_working') };
        render();
        fetchNui('tablet:rolesDelete', { key: key }).then(function (result) {
            state.pendingAction = false;
            if (result && result.ok === true) {
                if (Array.isArray(result.roles)) { state.roles = result.roles; applyRoleCatalog(result.roles); }
                state.actionNotice = { kind: 'ok', text: S('roles_deleted') };
            } else {
                state.actionNotice = { kind: 'error', text: roleErrorText(result) };
            }
            render();
        });
    }

    function buildCertTiersScreen() {
        var wrap = mk('div', { class: 'k9tablet-home-section' });
        wrap.appendChild(mk('h2', { class: 'k9tablet-section-heading', text: S('cert_tiers_heading') }));

        // HAZARD 3, surfaced per the server side's own explicit ask: a
        // successful reorder's `warning` is non-optional and must not be
        // silently discarded -- its own prominent banner, not folded into
        // the generic (and easy-to-miss-amid-other-clicks) actionNotice.
        if (state.certTierWarning) {
            wrap.appendChild(mk('p', { class: 'k9tablet-warning-note', text: state.certTierWarning }));
        }

        if (state.certTiersLoading && !state.certTiers) {
            wrap.appendChild(mk('p', { text: S('loading') }));
            return wrap;
        }
        if (state.certTiersError && !state.certTiers) {
            wrap.appendChild(mk('p', { class: 'k9tablet-error-text', text: errorText(state.certTiersError) }));
            wrap.appendChild(mkButton(S('retry_label'), 'k9tablet-btn', loadCertTiers));
            return wrap;
        }
        if (!state.certTiers) {
            wrap.appendChild(mk('p', { text: S('loading') }));
            return wrap;
        }

        wrap.appendChild(buildCertTiersTable());

        if (state.certTierDraft) {
            wrap.appendChild(buildCertTierDraftForm());
        } else {
            wrap.appendChild(mkButton(S('cert_tiers_add_label'), 'k9tablet-btn', openNewCertTierDraft, { disabled: state.pendingAction }));
        }

        return wrap;
    }

    function buildCertTiersTable() {
        var table = mk('table', { class: 'k9tablet-table' });
        var thead = mk('thead');
        var headRow = mk('tr');
        [S('column_position'), S('column_key'), S('column_label'), S('column_capabilities'), S('column_actions')].forEach(function (h) {
            headRow.appendChild(mk('th', { text: h }));
        });
        thead.appendChild(headRow);
        table.appendChild(thead);

        var tbody = mk('tbody');
        for (var i = 0; i < state.certTiers.length; i++) {
            tbody.appendChild(buildCertTierRow(state.certTiers[i], i));
        }
        table.appendChild(tbody);
        return table;
    }

    /** @param {string} capabilityKey @returns {string} */
    function certTierCapabilityLabel(capabilityKey) {
        var def = state.certTierCapabilityCatalog[capabilityKey];
        return (def && typeof def.label === 'string' && def.label.length > 0) ? def.label : capabilityKey;
    }

    /** @param {object} capabilities @returns {string} */
    function certTierCapabilitiesSummary(capabilities) {
        if (!capabilities || typeof capabilities !== 'object') return S('cert_tier_no_capabilities');
        var labels = [];
        for (var key in capabilities) {
            if (Object.prototype.hasOwnProperty.call(capabilities, key) && capabilities[key] === true) {
                labels.push(certTierCapabilityLabel(key));
            }
        }
        if (labels.length === 0) return S('cert_tier_no_capabilities');
        return labels.join(', ');
    }

    /** @param {object} tier @param {number} index */
    function buildCertTierRow(tier, index) {
        var tr = mk('tr');
        tr.appendChild(mk('td', { text: String(index + 1) }));
        tr.appendChild(mk('td', { text: tier.key }));
        tr.appendChild(mk('td', { text: tier.label }));
        tr.appendChild(mk('td', { class: 'k9tablet-muted', text: certTierCapabilitiesSummary(tier.capabilities) }));

        var actionsTd = mk('td', { class: 'k9tablet-cert-tier-actions' });
        actionsTd.appendChild(mkButton(S('cert_tier_move_up_label'), 'k9tablet-btn', function () {
            moveCertTier(index, -1);
        }, { disabled: state.pendingAction || index === 0, title: S('cert_tier_move_up_title') }));
        actionsTd.appendChild(mkButton(S('cert_tier_move_down_label'), 'k9tablet-btn', function () {
            moveCertTier(index, 1);
        }, { disabled: state.pendingAction || index === state.certTiers.length - 1, title: S('cert_tier_move_down_title') }));
        actionsTd.appendChild(mkButton(S('cert_tier_edit_label'), 'k9tablet-btn', function () {
            openCertTierEditDraft(tier);
        }, { disabled: state.pendingAction }));

        // UX CONVENIENCE ONLY -- see server/certtiers.lua's own
        // PROTECTED_TIER_KEYS/HAZARD 2: 'certified' is UNCONDITIONALLY
        // undeletable server-side regardless of this hint; a modified
        // client sending certTiersDelete for 'certified' anyway still gets
        // refused (reason='protected_tier') by the real gate.
        var isProtected = tier.key === 'certified';
        actionsTd.appendChild(mkConfirmButton(S('cert_tier_delete_label'), 'k9tablet-btn k9tablet-btn--danger', function () {
            deleteCertTier(tier.key);
        }, { disabled: state.pendingAction || isProtected, title: isProtected ? S('cert_tier_error_protected_tier') : undefined }));

        // A delete REFUSAL (tier_in_use/protected_tier) renders inline on
        // THIS specific row -- "cannot, and here is why" -- not merely as
        // an easy-to-miss generic top-of-panel notice (which still also
        // shows, for anyone not looking at this exact row).
        if (state.certTierActionError && state.certTierActionError.key === tier.key) {
            actionsTd.appendChild(mk('p', { class: 'k9tablet-error-text k9tablet-cert-tier-row-error', text: state.certTierActionError.text }));
        }

        tr.appendChild(actionsTd);
        return tr;
    }

    /** Add/edit form -- see openNewCertTierDraft()/openCertTierEditDraft()
     * for how state.certTierDraft is populated. `key` is editable only for
     * a BRAND NEW tier: server/certtiers.lua's own certTiersUpsert treats
     * an existing key's ordinal as fixed (only ReorderTiers ever changes
     * it) and has no "rename" concept -- submitting a DIFFERENT key while
     * editing would create a second, separate tier, not rename this one,
     * so the key input is disabled once a tier already exists under it. */
    function buildCertTierDraftForm() {
        var draft = state.certTierDraft;
        var wrap = mk('div', { class: 'k9tablet-cert-tier-form' });

        var keyRow = mk('div', { class: 'k9tablet-theme-field' + (state.certTierFieldError === 'key' ? ' k9tablet-theme-field--invalid' : '') });
        keyRow.appendChild(mk('label', { class: 'k9tablet-theme-field-label', text: S('cert_tier_key_label') }));
        var keyInput = mk('input', { class: 'k9tablet-cert-tier-key-input', attrs: { type: 'text', placeholder: S('cert_tier_key_placeholder'), maxlength: '20' } });
        keyInput.value = draft.key;
        if (draft.isNew) {
            keyInput.addEventListener('input', function (e) { draft.key = e.target.value; });
        } else {
            keyInput.setAttribute('disabled', 'disabled');
        }
        keyRow.appendChild(keyInput);
        wrap.appendChild(keyRow);

        var labelRow = mk('div', { class: 'k9tablet-theme-field' + (state.certTierFieldError === 'label' ? ' k9tablet-theme-field--invalid' : '') });
        labelRow.appendChild(mk('label', { class: 'k9tablet-theme-field-label', text: S('cert_tier_label_label') }));
        var labelInput = mk('input', { class: 'k9tablet-cert-tier-label-input', attrs: { type: 'text', maxlength: '60' } });
        labelInput.value = draft.label;
        labelInput.addEventListener('input', function (e) { draft.label = e.target.value; });
        labelRow.appendChild(labelInput);
        wrap.appendChild(labelRow);

        var capsWrap = mk('div', { class: 'k9tablet-cert-tier-capabilities' + (state.certTierFieldError === 'capabilities' ? ' k9tablet-theme-field--invalid' : '') });
        capsWrap.appendChild(mk('p', { class: 'k9tablet-theme-field-label', text: S('cert_tier_capabilities_label') }));
        var anyCapability = false;
        for (var capKey in state.certTierCapabilityCatalog) {
            if (!Object.prototype.hasOwnProperty.call(state.certTierCapabilityCatalog, capKey)) continue;
            anyCapability = true;
            capsWrap.appendChild(buildCertTierCapabilityCheckbox(capKey, draft));
        }
        if (!anyCapability) {
            capsWrap.appendChild(mk('p', { class: 'k9tablet-muted', text: S('cert_tier_no_capabilities') }));
        }
        wrap.appendChild(capsWrap);

        var actions = mk('div', { class: 'k9tablet-theme-actions' });
        actions.appendChild(mkButton(S('cert_tier_save_label'), 'k9tablet-btn', saveCertTierDraft, { disabled: state.pendingAction }));
        actions.appendChild(mkButton(S('cert_tier_cancel_label'), 'k9tablet-link-btn', closeCertTierDraft));
        wrap.appendChild(actions);

        return wrap;
    }

    /** One checkbox row bound to `draft.capabilities[capabilityKey]`,
     * mutating the WORKING COPY directly (never sent anywhere until Save)
     * -- same posture as buildThemeColorField's own color inputs.
     * @param {string} capabilityKey @param {object} draft */
    function buildCertTierCapabilityCheckbox(capabilityKey, draft) {
        var row = mk('label', { class: 'k9tablet-cert-tier-capability-row' });
        var checkbox = mk('input', { attrs: { type: 'checkbox' } });
        checkbox.checked = draft.capabilities[capabilityKey] === true;
        checkbox.addEventListener('change', function (e) {
            draft.capabilities[capabilityKey] = !!(e.target && e.target.checked);
        });
        row.appendChild(checkbox);
        row.appendChild(mk('span', { text: certTierCapabilityLabel(capabilityKey) }));
        return row;
    }

    // ---- Permission-key catalog screen (high command only) ----
    // Owner-directed "...even add or remove permissions" pass,
    // server/permissionkeycatalog.lua. Sits alongside the cert-tier screen
    // immediately above -- same structure (table + inline row actions +
    // add/edit form below), deliberately simpler: no ordinal/move-up-down,
    // no capabilities checkboxes (a permission key carries neither -- see
    // that file's own header "WHY NO ORDINAL").

    /**
     * Renders the LIVE catalogue from state.permissionKeys (populated by
     * loadPermissionKeys() -- see that function's own comment on why this
     * is never a hardcoded list: the four admin capability names
     * (k9.access/k9.certify/k9.audit/k9.givexp) are NOT hardcoded here
     * either, since high command can rename or retire any of them at
     * runtime), a per-row Edit/Delete set of controls, and (when a draft is
     * open) the add/edit form below the table.
     * server/permissionkeycatalog.lua's own CanManagePermissionKeys is the
     * real authorization gate, re-checked on every one of the three
     * callbacks this screen calls -- see THE SECURITY RULE.
     */
    function buildPermissionKeysScreen() {
        var wrap = mk('div', { class: 'k9tablet-home-section' });
        wrap.appendChild(mk('h2', { class: 'k9tablet-section-heading', text: S('permission_keys_heading') }));

        if (state.permissionKeysLoading && !state.permissionKeys) {
            wrap.appendChild(mk('p', { text: S('loading') }));
            return wrap;
        }
        if (state.permissionKeysError && !state.permissionKeys) {
            wrap.appendChild(mk('p', { class: 'k9tablet-error-text', text: errorText(state.permissionKeysError) }));
            wrap.appendChild(mkButton(S('retry_label'), 'k9tablet-btn', loadPermissionKeys));
            return wrap;
        }
        if (!state.permissionKeys) {
            wrap.appendChild(mk('p', { text: S('loading') }));
            return wrap;
        }

        wrap.appendChild(buildPermissionKeysTable());

        if (state.permissionKeyDraft) {
            wrap.appendChild(buildPermissionKeyDraftForm());
        } else {
            wrap.appendChild(mkButton(S('permission_keys_add_label'), 'k9tablet-btn', openNewPermissionKeyDraft, { disabled: state.pendingAction }));
        }

        return wrap;
    }

    function buildPermissionKeysTable() {
        var table = mk('table', { class: 'k9tablet-table' });
        var thead = mk('thead');
        var headRow = mk('tr');
        [S('column_key'), S('column_label'), S('column_description'), S('column_actions')].forEach(function (h) {
            headRow.appendChild(mk('th', { text: h }));
        });
        thead.appendChild(headRow);
        table.appendChild(thead);

        var tbody = mk('tbody');
        for (var i = 0; i < state.permissionKeys.length; i++) {
            tbody.appendChild(buildPermissionKeyRow(state.permissionKeys[i]));
        }
        table.appendChild(tbody);
        return table;
    }

    /** @param {object} entry */
    function buildPermissionKeyRow(entry) {
        var tr = mk('tr');
        var keyTd = mk('td', { text: entry.key });
        if (entry.isConfigDefault === true) {
            keyTd.appendChild(mk('span', { class: 'k9tablet-muted', text: ' (' + S('permission_key_default_badge') + ')' }));
        }
        tr.appendChild(keyTd);
        tr.appendChild(mk('td', { text: entry.label }));
        tr.appendChild(mk('td', { class: 'k9tablet-muted', text: (typeof entry.description === 'string' && entry.description.length > 0) ? entry.description : '' }));

        var actionsTd = mk('td', { class: 'k9tablet-cert-tier-actions' });
        actionsTd.appendChild(mkButton(S('permission_key_edit_label'), 'k9tablet-btn', function () {
            openPermissionKeyEditDraft(entry);
        }, { disabled: state.pendingAction }));
        actionsTd.appendChild(mkConfirmButton(S('permission_key_delete_label'), 'k9tablet-btn k9tablet-btn--danger', function () {
            deletePermissionKey(entry.key);
        }, { disabled: state.pendingAction }));

        // A delete REFUSAL (reserved_namespace/unknown_key) renders INLINE
        // on THIS specific row -- "cannot, and here is why" -- same
        // convention as certTierActionError above.
        if (state.permissionKeyActionError && state.permissionKeyActionError.key === entry.key) {
            actionsTd.appendChild(mk('p', { class: 'k9tablet-error-text k9tablet-cert-tier-row-error', text: state.permissionKeyActionError.text }));
        }

        tr.appendChild(actionsTd);
        return tr;
    }

    /** Add/edit form -- see openNewPermissionKeyDraft()/
     * openPermissionKeyEditDraft() for how state.permissionKeyDraft is
     * populated. `key` is editable only for a BRAND NEW key --
     * server/permissionkeycatalog.lua's own permKeysUpsert has no "rename"
     * concept (submitting a DIFFERENT key while editing would create a
     * second, separate entry, not rename this one), same reasoning as the
     * cert-tier form's own key input above. */
    function buildPermissionKeyDraftForm() {
        var draft = state.permissionKeyDraft;
        var wrap = mk('div', { class: 'k9tablet-cert-tier-form' });

        var keyRow = mk('div', { class: 'k9tablet-theme-field' + (state.permissionKeyFieldError === 'key' ? ' k9tablet-theme-field--invalid' : '') });
        keyRow.appendChild(mk('label', { class: 'k9tablet-theme-field-label', text: S('permission_key_key_label') }));
        var keyInput = mk('input', { class: 'k9tablet-cert-tier-key-input', attrs: { type: 'text', placeholder: S('permission_key_key_placeholder'), maxlength: '40' } });
        keyInput.value = draft.key;
        if (draft.isNew) {
            keyInput.addEventListener('input', function (e) { draft.key = e.target.value; });
        } else {
            keyInput.setAttribute('disabled', 'disabled');
        }
        keyRow.appendChild(keyInput);
        wrap.appendChild(keyRow);

        var labelRow = mk('div', { class: 'k9tablet-theme-field' + (state.permissionKeyFieldError === 'label' ? ' k9tablet-theme-field--invalid' : '') });
        labelRow.appendChild(mk('label', { class: 'k9tablet-theme-field-label', text: S('permission_key_label_label') }));
        var labelInput = mk('input', { class: 'k9tablet-cert-tier-label-input', attrs: { type: 'text', maxlength: '60' } });
        labelInput.value = draft.label;
        labelInput.addEventListener('input', function (e) { draft.label = e.target.value; });
        labelRow.appendChild(labelInput);
        wrap.appendChild(labelRow);

        var descriptionRow = mk('div', { class: 'k9tablet-theme-field' + (state.permissionKeyFieldError === 'description' ? ' k9tablet-theme-field--invalid' : '') });
        descriptionRow.appendChild(mk('label', { class: 'k9tablet-theme-field-label', text: S('permission_key_description_label') }));
        var descriptionInput = mk('input', { class: 'k9tablet-cert-tier-label-input', attrs: { type: 'text', placeholder: S('permission_key_description_placeholder'), maxlength: '300' } });
        descriptionInput.value = draft.description || '';
        descriptionInput.addEventListener('input', function (e) { draft.description = e.target.value; });
        descriptionRow.appendChild(descriptionInput);
        wrap.appendChild(descriptionRow);

        var actions = mk('div', { class: 'k9tablet-theme-actions' });
        actions.appendChild(mkButton(S('permission_key_save_label'), 'k9tablet-btn', savePermissionKeyDraft, { disabled: state.pendingAction }));
        actions.appendChild(mkButton(S('permission_key_cancel_label'), 'k9tablet-link-btn', closePermissionKeyDraft));
        wrap.appendChild(actions);

        return wrap;
    }

    // ---- K9 Supply Shop location management screen (high command OR a delegated 'k9.equipmentshoplocations' grant -- see canManageShopLocations()) ----

    /**
     * Owner's own words: "make the shop a dog ped and i can change the
     * locations in the config or add more locations remove locations etc
     * along with in the high command tablet." Renders the LIVE, effective
     * location list from state.shopLocations (populated by
     * loadShopLocations() -- never hardcoded here), each row either a
     * read-only `cfg:<n>` (config.lua) entry or an editable/removable
     * `db:<id>` (runtime) one, plus (when a draft is open) the add/edit
     * form below the table. server/equipmentshop.lua's own
     * CanManageShopLocations is the real authorization gate, re-checked on
     * every one of the three mutating callbacks this screen calls -- see
     * THE SECURITY RULE.
     */
    /**
     * The K9 Supply Shop screen: where the ped stands, then what it sells.
     * Two sections, one tab (plan item F) -- and each section asks its OWN
     * capability question, because server/equipmentshop.lua gates the two
     * independently and a viewer may legitimately hold only one.
     * @returns {Element}
     */
    function buildShopScreen() {
        var wrap = mk('div', { class: 'k9tablet-screen' });
        if (canManageShopLocations()) {
            wrap.appendChild(buildShopLocationsSection());
        }
        if (canManageShopItems()) {
            wrap.appendChild(buildShopItemsSection());
        }
        return wrap;
    }

    function buildShopLocationsSection() {
        var wrap = mk('div', { class: 'k9tablet-home-section' });
        wrap.appendChild(mk('h2', { class: 'k9tablet-section-heading', text: S('shop_locations_heading') }));

        if (!state.shopLocationsEnabled) {
            wrap.appendChild(mk('p', { class: 'k9tablet-muted', text: S('shop_locations_disabled_note') }));
        }

        if (state.shopLocationsLoading && !state.shopLocations) {
            wrap.appendChild(mk('p', { text: S('loading') }));
            return wrap;
        }
        if (state.shopLocationsError && !state.shopLocations) {
            wrap.appendChild(mk('p', { class: 'k9tablet-error-text', text: shopLocationErrorText(state.shopLocationsError) }));
            wrap.appendChild(mkButton(S('retry_label'), 'k9tablet-btn', loadShopLocations));
            return wrap;
        }
        if (!state.shopLocations) {
            wrap.appendChild(mk('p', { text: S('loading') }));
            return wrap;
        }

        wrap.appendChild(buildShopLocationsTable());

        if (state.shopLocationDraft) {
            wrap.appendChild(buildShopLocationDraftForm());
        } else {
            wrap.appendChild(mkButton(S('shop_location_add_here_label'), 'k9tablet-btn', openNewShopLocationDraft, { disabled: state.pendingAction || !state.shopLocationsEnabled }));
            wrap.appendChild(mk('p', { class: 'k9tablet-muted k9tablet-hint', text: S('shop_location_add_hint') }));
        }

        return wrap;
    }

    /**
     * `state.shopLocations` is a MAP (location key -> location), not an
     * array -- server/equipmentshop.lua's own GetLocations response shape
     * (`table<string, ShopLocation>`). Sorted here purely for a stable,
     * predictable display order: config.lua's own `cfg:<n>` entries first
     * (by their numeric config-array index), then runtime `db:<id>` ones
     * (by numeric id) -- never an ordinal the server tracks (there isn't
     * one for this list, unlike certification tiers).
     * @returns {Array<{key: string, loc: object}>}
     */
    function sortedShopLocationEntries() {
        var keys = [];
        for (var k in state.shopLocations) {
            if (Object.prototype.hasOwnProperty.call(state.shopLocations, k)) keys.push(k);
        }
        keys.sort(function (a, b) {
            var aIsConfig = a.indexOf('cfg:') === 0;
            var bIsConfig = b.indexOf('cfg:') === 0;
            if (aIsConfig !== bIsConfig) return aIsConfig ? -1 : 1;
            var aNum = parseInt(a.split(':')[1], 10);
            var bNum = parseInt(b.split(':')[1], 10);
            if (isFinite(aNum) && isFinite(bNum) && aNum !== bNum) return aNum - bNum;
            return a < b ? -1 : (a > b ? 1 : 0);
        });
        var out = [];
        for (var i = 0; i < keys.length; i++) out.push({ key: keys[i], loc: state.shopLocations[keys[i]] });
        return out;
    }

    /** @param {object} loc @returns {string} e.g. "123.4, -456.7, 30.0" */
    function formatShopLocationCoordinates(loc) {
        if (!loc || typeof loc.x !== 'number' || typeof loc.y !== 'number' || typeof loc.z !== 'number') return '';
        return loc.x.toFixed(1) + ', ' + loc.y.toFixed(1) + ', ' + loc.z.toFixed(1);
    }

    function buildShopLocationsTable() {
        var entries = sortedShopLocationEntries();
        if (entries.length === 0) {
            var empty = mk('div', {});
            empty.appendChild(mk('p', { class: 'k9tablet-muted', text: S('shop_locations_empty') }));
            return empty;
        }

        var table = mk('table', { class: 'k9tablet-table' });
        var thead = mk('thead');
        var headRow = mk('tr');
        [S('column_label'), S('column_coordinates'), S('column_model'), S('column_source'), S('column_actions')].forEach(function (h) {
            headRow.appendChild(mk('th', { text: h }));
        });
        thead.appendChild(headRow);
        table.appendChild(thead);

        var tbody = mk('tbody');
        for (var i = 0; i < entries.length; i++) {
            tbody.appendChild(buildShopLocationRow(entries[i].key, entries[i].loc));
        }
        table.appendChild(tbody);
        return table;
    }

    /**
     * @param {string} key -- 'cfg:<n>' (config.lua, read-only) or 'db:<id>' (runtime, editable/removable)
     * @param {object} loc -- {x,y,z,heading,model,scenario,label}, ALL already resolved server-side, never nil
     */
    function buildShopLocationRow(key, loc) {
        var tr = mk('tr');
        tr.appendChild(mk('td', { text: (loc && typeof loc.label === 'string') ? loc.label : '' }));
        tr.appendChild(mk('td', { class: 'k9tablet-muted', text: formatShopLocationCoordinates(loc) }));
        tr.appendChild(mk('td', { class: 'k9tablet-muted', text: (loc && typeof loc.model === 'string') ? loc.model : '' }));

        var isRuntime = key.indexOf('db:') === 0;
        tr.appendChild(mk('td', { text: isRuntime ? S('source_runtime') : S('source_config') }));

        var actionsTd = mk('td', { class: 'k9tablet-cert-tier-actions' });
        if (isRuntime) {
            actionsTd.appendChild(mkButton(S('shop_location_edit_label'), 'k9tablet-btn', function () {
                openEditShopLocationDraft(key, loc);
            }, { disabled: state.pendingAction || !state.shopLocationsEnabled }));
            // Two-click confirm (not styled `--danger`: repositioning is
            // reversible, but consequential enough -- it moves a live shop
            // ped to wherever the operator happens to be standing -- that a
            // stray click deserves a second one, same reasoning as every
            // other mkConfirmButton on this page).
            actionsTd.appendChild(mkConfirmButton(S('shop_location_move_here_label'), 'k9tablet-btn', function () {
                moveShopLocationHere(key);
            }, { disabled: state.pendingAction || !state.shopLocationsEnabled, title: S('shop_location_move_here_hint') }));
            actionsTd.appendChild(mkConfirmButton(S('shop_location_remove_label'), 'k9tablet-btn k9tablet-btn--danger', function () {
                removeShopLocation(key);
            }, { disabled: state.pendingAction || !state.shopLocationsEnabled }));
        } else {
            // config.lua entries are NEVER editable/removable from here --
            // see server/equipmentshop.lua's own SCOPE note: a stored
            // override keyed to config.lua's own array index would silently
            // apply to the wrong location the instant an operator reorders
            // that array.
            actionsTd.appendChild(mk('span', { class: 'k9tablet-muted', text: S('shop_location_config_note') }));
        }

        // A Move/Remove REFUSAL renders INLINE on THIS specific row --
        // "cannot, and here is why" -- same convention as
        // certTierActionError just above.
        if (state.shopLocationActionError && state.shopLocationActionError.key === key) {
            actionsTd.appendChild(mk('p', { class: 'k9tablet-error-text k9tablet-cert-tier-row-error', text: state.shopLocationActionError.text }));
        }

        tr.appendChild(actionsTd);
        return tr;
    }

    /** Opens a BLANK draft for a brand-new location -- `key: null` marks it
     * as "new" for saveShopLocationDraft() below. Deliberately NO x/y/z/
     * heading fields on this draft at all: those are captured entirely
     * client(Lua)-side from the operator's own current position at Save
     * time (see client/tablet.lua's own tablet:equipmentShopAddLocation --
     * this page has no native access to GetEntityCoords to offer them even
     * if it wanted to). */
    function openNewShopLocationDraft() {
        state.shopLocationDraft = { key: null, label: '', model: '', scenario: '' };
        render();
    }

    /** Opens a draft pre-filled from an EXISTING runtime location -- a COPY
     * of its fields, never the live object, so Cancel never mutates
     * state.shopLocations. @param {string} key @param {object} loc */
    function openEditShopLocationDraft(key, loc) {
        state.shopLocationDraft = {
            key: key,
            label: (loc && typeof loc.label === 'string') ? loc.label : '',
            model: (loc && typeof loc.model === 'string') ? loc.model : '',
            scenario: (loc && typeof loc.scenario === 'string') ? loc.scenario : '',
        };
        render();
    }

    function closeShopLocationDraft() {
        state.shopLocationDraft = null;
        render();
    }

    /** Add/Edit form -- label/model/scenario ONLY, reusing the SAME field/
     * form classes as the theme editor / certification tier form (no new
     * CSS introduced for this screen -- see html/tablet.css's own note).
     * Position is NEVER edited here -- see openNewShopLocationDraft()'s own
     * comment and the "Move Here" row action instead. */
    function buildShopLocationDraftForm() {
        var draft = state.shopLocationDraft;
        var wrap = mk('div', { class: 'k9tablet-cert-tier-form' });

        var labelRow = mk('div', { class: 'k9tablet-theme-field' });
        labelRow.appendChild(mk('label', { class: 'k9tablet-theme-field-label', text: S('shop_location_label_label') }));
        var labelInput = mk('input', { class: 'k9tablet-cert-tier-label-input', attrs: { type: 'text', placeholder: S('shop_location_label_placeholder'), maxlength: '100' } });
        labelInput.value = draft.label;
        labelInput.addEventListener('input', function (e) { draft.label = e.target.value; });
        labelRow.appendChild(labelInput);
        wrap.appendChild(labelRow);

        var modelRow = mk('div', { class: 'k9tablet-theme-field' });
        modelRow.appendChild(mk('label', { class: 'k9tablet-theme-field-label', text: S('shop_location_model_label') }));
        var modelInput = mk('input', { class: 'k9tablet-cert-tier-label-input', attrs: { type: 'text', placeholder: S('shop_location_model_placeholder'), maxlength: '64' } });
        modelInput.value = draft.model;
        modelInput.addEventListener('input', function (e) { draft.model = e.target.value; });
        modelRow.appendChild(modelInput);
        wrap.appendChild(modelRow);

        var scenarioRow = mk('div', { class: 'k9tablet-theme-field' });
        scenarioRow.appendChild(mk('label', { class: 'k9tablet-theme-field-label', text: S('shop_location_scenario_label') }));
        var scenarioInput = mk('input', { class: 'k9tablet-cert-tier-label-input', attrs: { type: 'text', placeholder: S('shop_location_scenario_placeholder'), maxlength: '64' } });
        scenarioInput.value = draft.scenario;
        scenarioInput.addEventListener('input', function (e) { draft.scenario = e.target.value; });
        scenarioRow.appendChild(scenarioInput);
        wrap.appendChild(scenarioRow);

        var actions = mk('div', { class: 'k9tablet-theme-actions' });
        actions.appendChild(mkButton(S('shop_location_save_label'), 'k9tablet-btn', saveShopLocationDraft, { disabled: state.pendingAction || !state.shopLocationsEnabled }));
        actions.appendChild(mkButton(S('shop_location_cancel_label'), 'k9tablet-link-btn', closeShopLocationDraft));
        wrap.appendChild(actions);

        if (draft.key === null) {
            wrap.appendChild(mk('p', { class: 'k9tablet-muted k9tablet-hint', text: S('shop_location_add_hint') }));
        }

        return wrap;
    }

    /** @param {object|undefined} result @returns {string} */
    function shopLocationErrorText(result) {
        if (!result) return S('action_failed');
        if (typeof result.message === 'string' && result.message.length > 0) return result.message;
        switch (result.error) {
            case 'denied': return S('shop_location_error_denied');
            case 'rate_limited': return S('shop_location_error_rate_limited');
            case 'invalid_coords': return S('shop_location_error_invalid_coords');
            case 'invalid_heading': return S('shop_location_error_invalid_heading');
            case 'invalid_model': return S('shop_location_error_invalid_model');
            case 'invalid_scenario': return S('shop_location_error_invalid_scenario');
            case 'invalid_label': return S('shop_location_error_invalid_label');
            case 'invalid_key': return S('shop_location_error_invalid_key');
            case 'invalid_payload': return S('shop_location_error_invalid_payload');
            case 'db_error': return S('shop_location_error_db_error');
            case 'feature_disabled': return S('shop_location_error_feature_disabled');
            case 'timeout': return S('error_timeout');
            case 'network_error': return S('error_network');
            default: return S('action_failed');
        }
    }

    // ---- K9 Supply Shop ITEM CATALOG editing screen (high command OR a delegated 'k9.equipmentshopitems' grant -- see canManageShopItems()) ----
    // server/equipmentshop.lua's own "EQUIPMENT SHOP ITEM CATALOG" section
    // -- owner's own words: "give high command real control over the
    // equipment shop." Sits alongside the Shop Locations screen above --
    // same table + inline row actions + add/edit form below shape as the
    // Certification Tier screen (this is the closest analogue: a
    // DB-backed catalog with list/upsert/reorder/tombstone), reusing the
    // SAME field/form/table CSS classes -- no new CSS introduced for this
    // screen either.
    //
    // TOMBSTONE, HANDLED HONESTLY: server/equipmentshop.lua's own
    // ListEquipmentShopItems (tablet:equipmentShopItemsList's response)
    // NEVER includes a tombstoned item_key at all -- the server's own
    // catalog merge excludes it entirely before this page ever sees it
    // (see that file's own "TOMBSTONE, NOT HARD-DELETE" section: a
    // tombstoned row is not a row with a flag, it is simply absent from
    // the merged map). There is therefore no "retired" STATE this screen
    // could render inline for a row still present in `state.shopItems` --
    // a successful delete's own response (`result.items`) is the new,
    // already-tombstone-filtered list, and this screen simply shows one
    // fewer row afterward, exactly like server/certtiers.lua's own
    // DeleteTier/certTiersDelete does for a tier. This is disclosed here
    // rather than silently assumed: existing purchases/grants referencing
    // a retired item key are NEVER affected by this (ox_inventory's own
    // already-granted item stays in whatever bag it is in; nothing in
    // this resource's own schema references an item_key at all -- see
    // that file's header) -- the tombstone protects the SELLING side
    // only, which is exactly the side this screen edits.
    //
    // REORDER VALIDITY BY CONSTRUCTION: moveShopItem() below, like
    // moveCertTier() above, ALWAYS submits the full current key list (via
    // state.shopItems, sortOrder-ascending) with two entries swapped --
    // never a partial list -- so this UI is structurally incapable of
    // sending anything server/equipmentshop.lua's own
    // equipmentShopItemsReorder (which refuses any partial/duplicated
    // permutation) would ever reject for that reason.

    /**
     * Renders the LIVE catalogue from state.shopItems (populated by
     * loadEquipmentShopItems() -- NEVER hardcoded: an operator can
     * add/retire/reprice/reorder items at runtime, and this page must
     * reflect that with no UI change), a per-row Move Up/Move Down/Edit/
     * Delete set of controls, and (when a draft is open) the add/edit
     * form below the table. server/equipmentshop.lua's own
     * CanManageShopItems is the real authorization gate, re-checked on
     * every one of the four callbacks this screen calls -- see THE
     * SECURITY RULE.
     */
    function buildShopItemsSection() {
        var wrap = mk('div', { class: 'k9tablet-home-section' });
        wrap.appendChild(mk('h2', { class: 'k9tablet-section-heading', text: S('shop_items_heading') }));

        if (state.shopItemsLoading && !state.shopItems) {
            wrap.appendChild(mk('p', { text: S('loading') }));
            return wrap;
        }
        if (state.shopItemsError && !state.shopItems) {
            wrap.appendChild(mk('p', { class: 'k9tablet-error-text', text: shopItemErrorText(state.shopItemsError) }));
            wrap.appendChild(mkButton(S('retry_label'), 'k9tablet-btn', loadEquipmentShopItems));
            return wrap;
        }
        if (!state.shopItems) {
            wrap.appendChild(mk('p', { text: S('loading') }));
            return wrap;
        }

        wrap.appendChild(buildShopItemsTable());

        if (state.shopItemDraft) {
            wrap.appendChild(buildShopItemDraftForm());
        } else {
            wrap.appendChild(mkButton(S('shop_items_add_label'), 'k9tablet-btn', openNewShopItemDraft, { disabled: state.pendingAction }));
        }

        return wrap;
    }

    function buildShopItemsTable() {
        if (state.shopItems.length === 0) {
            var empty = mk('div', {});
            empty.appendChild(mk('p', { class: 'k9tablet-muted', text: S('shop_items_empty') }));
            return empty;
        }

        var table = mk('table', { class: 'k9tablet-table' });
        var thead = mk('thead');
        var headRow = mk('tr');
        [S('column_position'), S('column_key'), S('column_label'), S('column_price'), S('column_currency'),
            S('column_required_specialization'), S('column_actions')].forEach(function (h) {
            headRow.appendChild(mk('th', { text: h }));
        });
        thead.appendChild(headRow);
        table.appendChild(thead);

        var tbody = mk('tbody');
        for (var i = 0; i < state.shopItems.length; i++) {
            tbody.appendChild(buildShopItemRow(state.shopItems[i], i));
        }
        table.appendChild(tbody);
        return table;
    }

    /** @param {number|null|undefined} price @returns {string} */
    function formatShopItemPrice(price) {
        if (typeof price !== 'number' || !isFinite(price)) return '';
        return String(price);
    }

    /**
     * One line saying who may buy an item: its required role (with the XP
     * that role switches on at), plus any old tier requirement left over
     * from before tiers were merged into roles.
     * @param {object} item @returns {string}
     */
    function shopItemRequirementText(item) {
        var parts = [];
        if (typeof item.requiredSpecialization === 'string' && item.requiredSpecialization.length > 0) {
            var needXp = roleXpRequired(item.requiredSpecialization);
            parts.push(specializationDisplayLabel(item.requiredSpecialization)
                + (needXp > 0 ? ' (' + formatTemplate(S('role_option_xp_template'), { xp: needXp }) + ')' : ''));
        }
        if (typeof item.requiredTierKey === 'string' && item.requiredTierKey.length > 0) {
            parts.push(formatTemplate(S('shop_item_legacy_tier_template'), { tier: tierDisplayLabel(item.requiredTierKey) }));
        }
        return parts.length > 0 ? parts.join(' · ') : S('shop_item_no_requirement');
    }

    /** @param {object} item @param {number} index */
    function buildShopItemRow(item, index) {
        var tr = mk('tr');
        tr.appendChild(mk('td', { text: String(index + 1) }));
        tr.appendChild(mk('td', { text: item.key }));
        tr.appendChild(mk('td', { text: (typeof item.label === 'string') ? item.label : item.key }));

        var priceTd = mk('td', { text: formatShopItemPrice(item.price) });
        // ZERO IS A LEGAL, DELIBERATE PRICE (a free item) -- see
        // server/equipmentshop.lua's own "PRICE VALIDATION" section. Never
        // hidden or treated as a display bug -- called out with its own
        // small badge so an operator sees at a glance that a 0 is
        // intentional, not a blank/error.
        if (item.price === 0) {
            priceTd.appendChild(mk('span', { class: 'k9tablet-muted', text: ' (' + S('shop_item_price_free_badge') + ')' }));
        }
        tr.appendChild(priceTd);

        tr.appendChild(mk('td', { class: 'k9tablet-muted', text: (typeof item.currency === 'string' && item.currency.length > 0) ? item.currency : S('shop_item_currency_default_note') }));
        tr.appendChild(mk('td', { class: 'k9tablet-muted', text: shopItemRequirementText(item) }));

        var actionsTd = mk('td', { class: 'k9tablet-cert-tier-actions' });
        actionsTd.appendChild(mkButton(S('shop_item_move_up_label'), 'k9tablet-btn', function () {
            moveShopItem(index, -1);
        }, { disabled: state.pendingAction || index === 0, title: S('shop_item_move_up_title') }));
        actionsTd.appendChild(mkButton(S('shop_item_move_down_label'), 'k9tablet-btn', function () {
            moveShopItem(index, 1);
        }, { disabled: state.pendingAction || index === state.shopItems.length - 1, title: S('shop_item_move_down_title') }));
        actionsTd.appendChild(mkButton(S('shop_item_edit_label'), 'k9tablet-btn', function () {
            openEditShopItemDraft(item);
        }, { disabled: state.pendingAction }));
        actionsTd.appendChild(mkConfirmButton(S('shop_item_delete_label'), 'k9tablet-btn k9tablet-btn--danger', function () {
            deleteShopItem(item.key);
        }, { disabled: state.pendingAction }));

        // A delete/reorder REFUSAL renders INLINE on THIS specific row --
        // "cannot, and here is why" -- same convention as
        // certTierActionError/shopLocationActionError above.
        if (state.shopItemActionError && state.shopItemActionError.key === item.key) {
            actionsTd.appendChild(mk('p', { class: 'k9tablet-error-text k9tablet-cert-tier-row-error', text: state.shopItemActionError.text }));
        }

        tr.appendChild(actionsTd);
        return tr;
    }

    /** 1-50 chars, lowercase-start, lowercase/digit/underscore only -- a
     * CLIENT-SIDE MIRROR of server/equipmentshop.lua's own
     * IsValidShopItemKey, a UX convenience only (THE SECURITY RULE: the
     * server re-validates this independently regardless of what this
     * check does or does not catch first).
     * @param {any} key @returns {boolean} */
    function isValidShopItemKeyClient(key) {
        return typeof key === 'string' && key.length >= 1 && key.length <= 50 && /^[a-z][a-z0-9_]*$/.test(key);
    }

    /** CLIENT-SIDE MIRROR of server/equipmentshop.lua's own
     * IsSafeShortString -- same reasoning as isSafeShortStringForXpTier
     * above (this codebase's own convention: each screen keeps its own
     * tiny, self-contained copy rather than a shared cross-screen call).
     * @param {any} value @param {number} maxLen @returns {boolean} */
    function isSafeShortStringForShopItem(value, maxLen) {
        if (typeof value !== 'string') return false;
        var len = value.length;
        if (len === 0 || len > maxLen) return false;
        if (/[<>&"'`\r\n\t]/.test(value)) return false;
        for (var i = 0; i < len; i++) {
            var code = value.charCodeAt(i);
            if (code < 0x20 || code === 0x7F) return false;
        }
        return true;
    }

    // Mirrors server/equipmentshop.lua's own MAX_SHOP_ITEM_PRICE exactly
    // -- see that file's own "PRICE VALIDATION" section. ZERO IS
    // DELIBERATELY NOT excluded by this check (a free item is a real,
    // documented, legitimate price) -- only non-numbers, NaN,
    // +/-infinity, negatives, fractions, and anything above this ceiling
    // are rejected.
    var SHOP_ITEM_MAX_PRICE = 1000000000;

    /** @param {any} value @returns {boolean} */
    function isValidShopItemPriceClient(value) {
        return typeof value === 'number' && isFinite(value) && value >= 0 && value <= SHOP_ITEM_MAX_PRICE && value === Math.floor(value);
    }

    /** Opens a BLANK draft for a brand-new item. requiredTierKey/
     * requiredSpecialization start at '' (the draft form's own "None"
     * option) -- never null -- so a plain `.value` read on the <select>
     * always works. @see buildShopItemDraftForm */
    function openNewShopItemDraft() {
        state.shopItemDraft = { key: '', price: '', label: '', currency: '', requiredTierKey: '', requiredSpecialization: '', isNew: true };
        state.shopItemFieldError = null;
        render();
    }

    /** Opens a draft pre-filled from an EXISTING item row -- a COPY of its
     * fields, never the live object, so Cancel never mutates
     * state.shopItems. Pre-filling EVERY field (not just the ones an
     * operator intends to touch) matters here specifically:
     * server/equipmentshop.lua's own equipmentShopItemsUpsert REPLACES
     * label/currency/requiredTierKey/requiredSpecialization wholesale from
     * whatever this ONE payload sends (never a partial merge with the
     * existing row) -- an edit draft that started blank on, say, currency
     * would silently CLEAR an existing currency override on Save, not
     * leave it untouched. @param {object} item */
    function openEditShopItemDraft(item) {
        state.shopItemDraft = {
            key: item.key,
            price: formatShopItemPrice(item.price),
            label: (typeof item.label === 'string' && item.label !== item.key) ? item.label : '',
            currency: (typeof item.currency === 'string') ? item.currency : '',
            requiredTierKey: (typeof item.requiredTierKey === 'string') ? item.requiredTierKey : '',
            requiredSpecialization: (typeof item.requiredSpecialization === 'string') ? item.requiredSpecialization : '',
            isNew: false,
        };
        state.shopItemFieldError = null;
        render();
    }

    function closeShopItemDraft() {
        state.shopItemDraft = null;
        state.shopItemFieldError = null;
        render();
    }

    /** Add/edit form -- see openNewShopItemDraft()/openEditShopItemDraft()
     * for how state.shopItemDraft is populated. `key` is editable only for
     * a BRAND NEW item: server/equipmentshop.lua's own
     * equipmentShopItemsUpsert has no "rename" concept (submitting a
     * DIFFERENT key while editing would create a second, separate item,
     * not rename this one), same reasoning as the cert-tier/permission-key
     * forms' own key input. */
    function buildShopItemDraftForm() {
        var draft = state.shopItemDraft;
        var wrap = mk('div', { class: 'k9tablet-cert-tier-form' });

        var keyRow = mk('div', { class: 'k9tablet-theme-field' + (state.shopItemFieldError === 'key' ? ' k9tablet-theme-field--invalid' : '') });
        keyRow.appendChild(mk('label', { class: 'k9tablet-theme-field-label', text: S('shop_item_key_label') }));
        var keyInput = mk('input', { class: 'k9tablet-cert-tier-key-input', attrs: { type: 'text', placeholder: S('shop_item_key_placeholder'), maxlength: '50' } });
        keyInput.value = draft.key;
        if (draft.isNew) {
            keyInput.addEventListener('input', function (e) { draft.key = e.target.value; });
        } else {
            keyInput.setAttribute('disabled', 'disabled');
        }
        keyRow.appendChild(keyInput);
        wrap.appendChild(keyRow);

        var priceRow = mk('div', { class: 'k9tablet-theme-field' + (state.shopItemFieldError === 'price' ? ' k9tablet-theme-field--invalid' : '') });
        priceRow.appendChild(mk('label', { class: 'k9tablet-theme-field-label', text: S('shop_item_price_label') }));
        var priceInput = mk('input', { class: 'k9tablet-cert-tier-label-input', attrs: { type: 'number', step: '1', min: '0', max: String(SHOP_ITEM_MAX_PRICE) } });
        priceInput.value = draft.price;
        priceInput.addEventListener('input', function (e) { draft.price = e.target.value; });
        priceRow.appendChild(priceInput);
        wrap.appendChild(priceRow);

        var labelRow = mk('div', { class: 'k9tablet-theme-field' + (state.shopItemFieldError === 'label' ? ' k9tablet-theme-field--invalid' : '') });
        labelRow.appendChild(mk('label', { class: 'k9tablet-theme-field-label', text: S('shop_item_label_label') }));
        var labelInput = mk('input', { class: 'k9tablet-cert-tier-label-input', attrs: { type: 'text', placeholder: S('shop_item_label_placeholder'), maxlength: '60' } });
        labelInput.value = draft.label;
        labelInput.addEventListener('input', function (e) { draft.label = e.target.value; });
        labelRow.appendChild(labelInput);
        wrap.appendChild(labelRow);

        var currencyRow = mk('div', { class: 'k9tablet-theme-field' + (state.shopItemFieldError === 'currency' ? ' k9tablet-theme-field--invalid' : '') });
        currencyRow.appendChild(mk('label', { class: 'k9tablet-theme-field-label', text: S('shop_item_currency_label') }));
        var currencyInput = mk('input', { class: 'k9tablet-cert-tier-label-input', attrs: { type: 'text', placeholder: S('shop_item_currency_placeholder'), maxlength: '50' } });
        currencyInput.value = draft.currency;
        currencyInput.addEventListener('input', function (e) { draft.currency = e.target.value; });
        currencyRow.appendChild(currencyInput);
        wrap.appendChild(currencyRow);

        // Old tier requirement -- tiers were merged into roles, so a NEW
        // tier requirement can no longer be picked. An item saved before
        // that may still carry one (it is still enforced at purchase), so
        // it is shown here, pre-selected, with None beside it: saving
        // untouched keeps it, choosing None removes it. Never silently
        // dropped by an unrelated edit.
        if (draft.requiredTierKey.length > 0) {
            var tierRow = mk('div', { class: 'k9tablet-theme-field' + (state.shopItemFieldError === 'requiredTierKey' ? ' k9tablet-theme-field--invalid' : '') });
            tierRow.appendChild(mk('label', { class: 'k9tablet-theme-field-label', text: S('shop_item_required_tier_label') }));
            var tierSelect = mk('select', { class: 'k9tablet-role-select k9tablet-shop-legacy-tier-select' });
            var noneTierOption = mk('option', { text: S('shop_item_no_requirement') });
            noneTierOption.setAttribute('value', '');
            tierSelect.appendChild(noneTierOption);
            var legacyTierOption = mk('option', { text: tierDisplayLabel(draft.requiredTierKey) });
            legacyTierOption.setAttribute('value', draft.requiredTierKey);
            tierSelect.appendChild(legacyTierOption);
            tierSelect.value = draft.requiredTierKey;
            tierSelect.addEventListener('input', function (e) { draft.requiredTierKey = e.target.value; });
            tierRow.appendChild(tierSelect);
            tierRow.appendChild(mk('p', { class: 'k9tablet-muted k9tablet-hint', text: S('shop_item_legacy_tier_hint') }));
            wrap.appendChild(tierRow);
        }

        // Required Role -- the item sells only to someone holding this role
        // whose XP has reached it (server/equipmentshop.lua's buyItem hook).
        // RETIRED REFERENCE safeguard: a role deleted since this item was
        // saved stays listed and pre-selected, marked "(retired)", so a
        // plain Save never silently clears it. Populated from
        // state.specializations (Config.K9Specializations, sent verbatim
        // at tablet:open -- always available with no separate fetch,
        // unlike the tier catalog, but an operator can still rename/remove
        // a specialization key in config.lua between this item's last
        // save and now, so the same hazard applies).
        var specRow = mk('div', { class: 'k9tablet-theme-field' + (state.shopItemFieldError === 'requiredSpecialization' ? ' k9tablet-theme-field--invalid' : '') });
        specRow.appendChild(mk('label', { class: 'k9tablet-theme-field-label', text: S('shop_item_required_specialization_label') }));
        var specCatalog = (state.specializations && typeof state.specializations === 'object') ? state.specializations : {};
        var specSelect = mk('select', { class: 'k9tablet-role-select' });
        var noneSpecOption = mk('option', { text: S('shop_item_no_requirement') });
        noneSpecOption.setAttribute('value', '');
        specSelect.appendChild(noneSpecOption);
        var knownSpecKeys = {};
        for (var specKey in specCatalog) {
            if (!Object.prototype.hasOwnProperty.call(specCatalog, specKey)) continue;
            knownSpecKeys[specKey] = true;
            var specNeedXp = roleXpRequired(specKey);
            var specOption = mk('option', { text: specializationDisplayLabel(specKey) + (specNeedXp > 0 ? ' (' + formatTemplate(S('role_option_xp_template'), { xp: specNeedXp }) + ')' : '') });
            specOption.setAttribute('value', specKey);
            specSelect.appendChild(specOption);
        }
        if (draft.requiredSpecialization.length > 0 && !knownSpecKeys[draft.requiredSpecialization]) {
            var retiredSpecOption = mk('option', { text: specializationDisplayLabel(draft.requiredSpecialization) + ' ' + S('shop_item_retired_reference_badge') });
            retiredSpecOption.setAttribute('value', draft.requiredSpecialization);
            specSelect.appendChild(retiredSpecOption);
        }
        specSelect.value = draft.requiredSpecialization;
        specSelect.addEventListener('input', function (e) { draft.requiredSpecialization = e.target.value; });
        specRow.appendChild(specSelect);
        wrap.appendChild(specRow);

        var actions = mk('div', { class: 'k9tablet-theme-actions' });
        actions.appendChild(mkButton(S('shop_item_save_label'), 'k9tablet-btn', saveShopItemDraft, { disabled: state.pendingAction }));
        actions.appendChild(mkButton(S('shop_item_cancel_label'), 'k9tablet-link-btn', closeShopItemDraft));
        wrap.appendChild(actions);

        return wrap;
    }

    /** @param {object|undefined} result @returns {string} */
    function shopItemErrorText(result) {
        if (!result) return S('action_failed');
        if (typeof result.message === 'string' && result.message.length > 0) return result.message;
        switch (result.error) {
            case 'denied': return S('shop_item_error_denied');
            case 'rate_limited': return S('shop_item_error_rate_limited');
            case 'invalid_payload': return S('shop_item_error_invalid_payload');
            // Same partial-failure gap as certTierErrorText's own
            // ordinal_write_failed case above -- server/equipmentshop.lua
            // names the items whose new order did not persist, and nothing
            // here read them.
            case 'sort_order_write_failed': return formatTemplate(S('shop_item_error_sort_order_write_failed'), {
                keys: Array.isArray(result.failedKeys) ? result.failedKeys.join(', ') : '?',
            });
            case 'invalid_key': return S('shop_item_error_invalid_key');
            case 'invalid_price': return S('shop_item_error_invalid_price');
            case 'invalid_label': return S('shop_item_error_invalid_label');
            case 'invalid_currency': return S('shop_item_error_invalid_currency');
            case 'invalid_required_tier': return S('shop_item_error_invalid_required_tier');
            case 'invalid_required_specialization': return S('shop_item_error_invalid_required_specialization');
            case 'busy': return S('shop_item_error_busy');
            case 'too_many_items': return S('shop_item_error_too_many_items');
            case 'unknown_item': return S('shop_item_error_unknown_item');
            case 'must_include_every_item': return S('shop_item_error_must_include_every_item');
            case 'invalid_key_set': return S('shop_item_error_invalid_key_set');
            case 'db_error': return S('shop_item_error_db_error');
            case 'timeout': return S('error_timeout');
            case 'network_error': return S('error_network');
            default: return S('action_failed');
        }
    }

    /** @param {string|undefined} errorCode @returns {string|null} */
    function shopItemFieldFromError(errorCode) {
        if (errorCode === 'invalid_key') return 'key';
        if (errorCode === 'invalid_price') return 'price';
        if (errorCode === 'invalid_label') return 'label';
        if (errorCode === 'invalid_currency') return 'currency';
        if (errorCode === 'invalid_required_tier') return 'requiredTierKey';
        if (errorCode === 'invalid_required_specialization') return 'requiredSpecialization';
        return null;
    }

    /**
     * Fetched fresh every time the Shop Items tab is opened (see
     * buildTabs()) -- NEVER a hardcoded list, same posture as
     * loadCertTiers()/loadShopLocations() above. High command OR a
     * delegated 'k9.equipmentshopitems' grant (server-side gate --
     * server/equipmentshop.lua's own CanManageShopItems; client-side
     * display gate -- canManageShopItems()).
     */
    function loadEquipmentShopItems() {
        state.shopItemsLoading = true;
        state.shopItemsError = null;
        render();

        fetchNui('tablet:equipmentShopItemsList', {}).then(function (result) {
            state.shopItemsLoading = false;
            if (!result || result.ok !== true) {
                state.shopItemsError = result || { error: 'unknown_error' };
                render();
                return;
            }
            state.shopItems = Array.isArray(result.items) ? result.items : [];
            render();
        });
    }

    /**
     * Saves the shop-item draft form's current working copy. NOT the
     * generic runMutation() helper: a rejected save carries a `field`
     * naming which of the six inputs failed, which runMutation's own
     * message-only handling has no slot for, same reasoning as
     * saveCertTierDraft()/savePermissionKeyDraft() above. Every check
     * below mirrors server/equipmentshop.lua's own validators
     * (IsValidShopItemKey/IsValidShopItemPrice/IsSafeShortString) as a UX
     * CONVENIENCE ONLY -- THE SECURITY RULE: the server independently
     * re-validates every one of these fields regardless of what this
     * function does or does not catch first. Blank
     * label/currency/requiredTierKey/requiredSpecialization are sent as
     * `undefined` (omitted), never `''` -- matching
     * server/equipmentshop.lua's own "nil means no override" optional-field
     * contract for every one of those four fields.
     */
    function saveShopItemDraft() {
        if (state.pendingAction || !state.shopItemDraft) return;
        var draft = state.shopItemDraft;

        if (!isValidShopItemKeyClient(draft.key)) {
            failShopItemDraft('key', S('shop_item_error_invalid_key'));
            return;
        }

        var priceNum = Number(draft.price);
        if (!isValidShopItemPriceClient(priceNum)) {
            failShopItemDraft('price', S('shop_item_error_invalid_price'));
            return;
        }

        var label;
        if (typeof draft.label === 'string' && draft.label.trim().length > 0) {
            if (!isSafeShortStringForShopItem(draft.label, 60)) {
                failShopItemDraft('label', S('shop_item_error_invalid_label'));
                return;
            }
            label = draft.label;
        }

        var currency;
        if (typeof draft.currency === 'string' && draft.currency.trim().length > 0) {
            if (!isValidShopItemKeyClient(draft.currency)) {
                failShopItemDraft('currency', S('shop_item_error_invalid_currency'));
                return;
            }
            currency = draft.currency;
        }

        var requiredTierKey;
        if (typeof draft.requiredTierKey === 'string' && draft.requiredTierKey.length > 0) {
            requiredTierKey = draft.requiredTierKey;
        }

        var requiredSpecialization;
        if (typeof draft.requiredSpecialization === 'string' && draft.requiredSpecialization.length > 0) {
            requiredSpecialization = draft.requiredSpecialization;
        }

        state.pendingAction = true;
        state.shopItemFieldError = null;
        state.actionNotice = { kind: 'ok', text: S('action_working') };
        render();

        var payload = { key: draft.key, price: priceNum };
        if (label !== undefined) payload.label = label;
        if (currency !== undefined) payload.currency = currency;
        if (requiredTierKey !== undefined) payload.requiredTierKey = requiredTierKey;
        if (requiredSpecialization !== undefined) payload.requiredSpecialization = requiredSpecialization;

        fetchNui('tablet:equipmentShopItemsUpsert', payload).then(function (result) {
            state.pendingAction = false;
            if (result && result.ok === true) {
                state.shopItems = Array.isArray(result.items) ? result.items : state.shopItems;
                state.shopItemDraft = null;
                state.actionNotice = { kind: 'ok', text: S('action_succeeded') };
            } else {
                state.shopItemFieldError = shopItemFieldFromError(result && result.error);
                state.actionNotice = { kind: 'error', text: shopItemErrorText(result) };
            }
            render();
        });
    }

    /** Sets the field-highlight/top-banner error pair for the CURRENTLY
     * open shop-item draft in one place -- shared by every client-side
     * pre-check branch in saveShopItemDraft() above, so a pre-check
     * failure and a server refusal for the SAME reason render
     * byte-identically. @param {string} field @param {string} text */
    function failShopItemDraft(field, text) {
        state.shopItemFieldError = field;
        state.actionNotice = { kind: 'error', text: text };
        render();
    }

    /**
     * Swaps item `index` with its immediate neighbour (`direction` is -1
     * for up / +1 for down) and submits the FULL resulting key order --
     * server/equipmentshop.lua's own equipmentShopItemsReorder REFUSES any
     * partial reorder (must be an exact permutation of every currently-known
     * item), so this always sends every key, never just the two that moved.
     * A no-op past either end of the list -- also enforced by each row's
     * own `disabled` state in buildShopItemRow, this is the real,
     * server-call-blocking guard, that being a convenience only.
     * @param {number} index @param {number} direction -1 | 1
     */
    function moveShopItem(index, direction) {
        if (state.pendingAction || !state.shopItems) return;
        var targetIndex = index + direction;
        if (targetIndex < 0 || targetIndex >= state.shopItems.length) return;

        var orderedKeys = [];
        for (var i = 0; i < state.shopItems.length; i++) orderedKeys.push(state.shopItems[i].key);
        var moved = orderedKeys[index];
        orderedKeys[index] = orderedKeys[targetIndex];
        orderedKeys[targetIndex] = moved;

        state.pendingAction = true;
        state.actionNotice = { kind: 'ok', text: S('action_working') };
        render();

        fetchNui('tablet:equipmentShopItemsReorder', { orderedKeys: orderedKeys }).then(function (result) {
            state.pendingAction = false;
            if (result && result.ok === true) {
                state.shopItems = Array.isArray(result.items) ? result.items : state.shopItems;
                state.actionNotice = { kind: 'ok', text: S('action_succeeded') };
            } else {
                state.actionNotice = { kind: 'error', text: shopItemErrorText(result) };
            }
            render();
        });
    }

    /**
     * Deletes (tombstones) item `key`. server/equipmentshop.lua's own
     * ShopItemsDelete carries NO reference-count refusal (unlike
     * deleteCertTier()'s own tier_in_use -- see that file's own
     * "TOMBSTONE, NOT HARD-DELETE" section for exactly why this schema has
     * nothing an item_key delete could ever strand), so any failure here
     * is a plain refusal/error, rendered INLINE on that item's own row
     * (state.shopItemActionError), same "cannot, and here is why"
     * convention as deleteCertTier()/deletePermissionKey() above.
     * @param {string} key
     */
    function deleteShopItem(key) {
        if (state.pendingAction) return;
        state.pendingAction = true;
        state.shopItemActionError = null;
        state.actionNotice = { kind: 'ok', text: S('action_working') };
        render();

        fetchNui('tablet:equipmentShopItemsDelete', { key: key }).then(function (result) {
            state.pendingAction = false;
            if (result && result.ok === true) {
                state.shopItems = Array.isArray(result.items) ? result.items : state.shopItems;
                state.actionNotice = { kind: 'ok', text: S('action_succeeded') };
            } else {
                var text = shopItemErrorText(result);
                state.shopItemActionError = { key: key, text: text };
                state.actionNotice = { kind: 'error', text: text };
            }
            render();
        });
    }

    // ---- Runtime feature control + tuning screen (high command OR a delegated 'k9.runtimecontrol' grant -- see canManageRuntimeControl()) ----

    /**
     * Owner's own words: "Lets high command switch features on and off
     * SERVER-WIDE from the tablet, and tune numbers live."
     * server/runtimecontrol.lua's own CanManageRuntimeControl is the real
     * authorization gate, re-checked on every one of the six callbacks
     * this screen calls -- see THE SECURITY RULE. Renders TWO independent
     * sections (Features, Tunables) on one screen -- same "several headed
     * sections, one screen" shape buildHomeScreen() already uses for
     * Certifications/XP/Abilities.
     */
    function buildRuntimeControlScreen() {
        var wrap = mk('div', { class: 'k9tablet-screen' });
        wrap.appendChild(mk('h2', { class: 'k9tablet-section-heading', text: S('runtime_control_heading') }));
        wrap.appendChild(mk('p', { class: 'k9tablet-muted', text: S('runtime_control_intro') }));

        if (!state.runtimeControlEnabled) {
            wrap.appendChild(mk('p', { class: 'k9tablet-muted', text: S('runtime_control_disabled_note') }));
        }

        wrap.appendChild(mk('h2', { class: 'k9tablet-section-heading', text: S('runtime_features_heading') }));
        wrap.appendChild(buildRuntimeFeaturesSection());

        wrap.appendChild(mk('h2', { class: 'k9tablet-section-heading', text: S('runtime_tunables_heading') }));
        wrap.appendChild(buildRuntimeTunablesSection());

        return wrap;
    }

    /** @param {string} tier @returns {string} plain-language badge text -- NEVER server/runtimecontrol.lua's own raw `note` prose, see this screen's own header note. */
    function runtimeTierLabel(tier) {
        switch (tier) {
            case 'live': return S('runtime_tier_live');
            case 'onstart': return S('runtime_tier_onstart');
            case 'rawtoplevel': return S('runtime_tier_rawtoplevel');
            case 'clientonly': return S('runtime_tier_clientonly');
            case 'protected': return S('runtime_tier_protected');
            default: return S('runtime_tier_unaudited');
        }
    }

    /** @param {string} tier @returns {string} one-sentence, locale-driven explanation of what this tier actually means -- rendered BEFORE a toggle is ever pressed (always visible on the row) and reused as the post-action notice text (see toggleRuntimeFeature()/resetRuntimeFeature() below), so the SAME honest explanation is shown before and after. */
    function runtimeTierDescription(tier) {
        switch (tier) {
            case 'live': return S('runtime_tier_live_desc');
            case 'onstart': return S('runtime_tier_onstart_desc');
            case 'rawtoplevel': return S('runtime_tier_rawtoplevel_desc');
            case 'clientonly': return S('runtime_tier_clientonly_desc');
            case 'protected': return S('runtime_tier_protected_desc');
            default: return S('runtime_tier_unaudited_desc');
        }
    }

    /** `state.runtimeFeatures` arrives as a Lua array built from `pairs()`
     * traversal order (server/runtimecontrol.lua's own runtimeListFeatures),
     * which is NOT a stable/predictable order across boots -- sorted here
     * purely for a stable display, same reasoning as
     * sortedShopLocationEntries() above. @returns {Array<object>} */
    function sortedRuntimeFeatures() {
        var list = (state.runtimeFeatures || []).slice();
        list.sort(function (a, b) { return a.name < b.name ? -1 : (a.name > b.name ? 1 : 0); });
        return list;
    }

    /**
     * The runtime features this screen actually renders as toggles, and the
     * ones it deliberately does not.
     *
     * OWNER DIRECTIVE, VERBATIM: "ensure anything disabled in the config or
     * requires a restart wont show up in the tablet". Of the ~70
     * Config.Features keys the server sends, only the `live` tier can be
     * changed from here and mean anything this session. The other five were
     * all rendered as ordinary, clickable toggles, and not one of them
     * controls anything from this screen:
     *   'rawtoplevel' -- gated before this resource finishes loading. A
     *                    restart is NOT enough; config.lua must be edited.
     *   'onstart'     -- saved, but nothing changes until a restart.
     *   'clientonly'  -- nothing server-side to flip; an already-connected
     *                    client read its own copy of config.lua at ITS own
     *                    start and never re-reads the server's.
     *   'protected'   -- runtimeSetFeature refuses these outright
     *                    (HighCommand/PermissionGrants -- toggling the gate
     *                    this very tool depends on is a self-lockout).
     *   'unaudited'   -- no confirmed enforcement point; the server cannot
     *                    promise the value does anything at all.
     * Listing them was defensible while the screen's claim was "here is the
     * whole inventory, honestly labelled" -- the tier band and its
     * description did say so. But two thirds of the rows being things you
     * cannot actually change buries the third you can, and a toggle that
     * silently needs a restart reads as broken, not as documented.
     *
     * FILTERED HERE, NOT SERVER-SIDE, DELIBERATELY. runtimeListFeatures'
     * complete output is the source of truth for three drift guards
     * (tests/runtimefeaturetiers_spec.lua, customizationregistry_spec.lua,
     * runtimecontrol_spec.lua) that exist to catch a Config.Features key
     * with no tier classification or no per-person block path. Narrowing
     * the payload would have blinded exactly the tests whose job is to
     * notice a misclassified feature. This is a DISPLAY decision, so it
     * belongs on the display side; the server keeps telling the whole
     * truth.
     *
     * NOT THE SAME AS HIDING AN OFF FEATURE. This filters on TIER, never on
     * `currentValue` -- a `live` feature that is currently OFF still
     * appears, so this screen remains the place to switch it back on and
     * the lockout withoutGloballyDisabled()'s own comment warns about
     * ("you could switch a feature off and then have no way to ever switch
     * it back on") is impossible here.
     * @returns {{ live: Array<object>, configOnly: Array<object> }}
     */
    function splitRuntimeFeaturesByReachability() {
        var live = [];
        var configOnly = [];
        var list = sortedRuntimeFeatures();
        for (var i = 0; i < list.length; i++) {
            if (list[i] && list[i].tier === 'live') live.push(list[i]);
            else if (list[i]) configOnly.push(list[i]);
        }
        return { live: live, configOnly: configOnly };
    }

    /** @returns {Array<object>} same reasoning as sortedRuntimeFeatures() above, sorted by `key`. */
    function sortedRuntimeTunables() {
        var list = (state.runtimeTunables || []).slice();
        list.sort(function (a, b) { return a.key < b.key ? -1 : (a.key > b.key ? 1 : 0); });
        return list;
    }

    function buildRuntimeFeaturesSection() {
        var wrap = mk('div', {});
        if (state.runtimeFeaturesLoading && !state.runtimeFeatures) {
            wrap.appendChild(mk('p', { text: S('loading') }));
            return wrap;
        }
        if (state.runtimeFeaturesError && !state.runtimeFeatures) {
            wrap.appendChild(mk('p', { class: 'k9tablet-error-text', text: runtimeListErrorText(state.runtimeFeaturesError) }));
            wrap.appendChild(mkButton(S('retry_label'), 'k9tablet-btn', loadRuntimeFeatures));
            return wrap;
        }
        if (!state.runtimeFeatures) {
            wrap.appendChild(mk('p', { text: S('loading') }));
            return wrap;
        }
        // BETTER DISTINCTION FOR DANGEROUS SETTINGS -- read this ONCE,
        // before scanning any individual row, so the warning-triangle
        // icon on a lockout-risk row (buildRuntimeFeatureRow() below)
        // means something the very first time it is seen, not only after
        // clicking into a row and reading its own hint text.
        if (splitRuntimeFeaturesByReachability().live.length > 0) {
            wrap.appendChild(mk('p', { class: 'k9tablet-runtime-legend', text: S('runtime_lockout_legend') }));
        }
        wrap.appendChild(buildRuntimeFeaturesTable());

        // WHERE THE REST WENT. server/runtimecontrol.lua now sends only the
        // features that can genuinely be changed from here and take effect
        // this session; everything that needs a config.lua edit, a restart,
        // or has no server-side switch at all is excluded (read that
        // function's own comment for the full tier-by-tier reasoning). One
        // honest line naming them beats either a silent gap -- an operator
        // hunting a switch they know exists and concluding the tablet is
        // broken -- or the old behaviour, where two thirds of the rows were
        // controls that quietly did nothing.
        //
        // textContent only, via mk()'s own `text` (never innerHTML), same
        // as every other string on this page: `configOnlyNames` are
        // Config.Features KEYS, not player input, but this page's rule has
        // no exceptions.
        var configOnly = splitRuntimeFeaturesByReachability().configOnly;
        if (configOnly.length > 0) {
            var names = [];
            for (var c = 0; c < configOnly.length; c++) names.push(configOnly[c].name);
            wrap.appendChild(mk('p', {
                class: 'k9tablet-muted',
                text: formatTemplate(S('runtime_config_only_note'), {
                    count: String(configOnly.length),
                    names: names.join(', '),
                }),
            }));
        }
        return wrap;
    }

    /**
     * The order the tier sections are rendered in -- SAFETY ORDER, not
     * alphabetical: what you can freely change first, what cannot be
     * changed from here at all last, with the increasingly conditional
     * middle in between. An operator reading top-down therefore meets the
     * settings that will actually do something before the ones that will
     * quietly do nothing until a restart, or nothing ever.
     *
     * A tier string not listed here (a newer server than this client, or
     * an unclassified feature) falls into the SAME 'unaudited' bucket
     * runtimeTierLabel()'s own `default:` branch already maps it to --
     * grouped, labelled and refused, never silently dropped from the table.
     */
    var RUNTIME_TIER_ORDER = ['live', 'onstart', 'rawtoplevel', 'clientonly', 'unaudited', 'protected'];

    /**
     * SECTIONS BY TIER (2026-09-01, owner: "better section management ...
     * everything is diffrentied better", "super easy to understand").
     *
     * This table was one flat alphabetical list of every Config.Features
     * key -- 57 rows on a default server -- and every single row carried a
     * full copy of its tier's explanation sentence. That is 57 long
     * paragraphs, most of them identical to the one above them, in a panel
     * 640px tall. The one question this screen exists to answer -- "which
     * of these can I actually change right now?" -- could only be answered
     * by reading every row.
     *
     * Grouped by tier, the sentence is stated ONCE per section instead of
     * once per row, and the answer is the shape of the screen itself.
     *
     * THE HONESTY REQUIREMENT IS PRESERVED, NOT TRADED AWAY. See
     * buildRuntimeFeatureRow()'s own note: the tier explanation must be
     * visible BEFORE a toggle is pressed, and never hidden behind a hover
     * or tooltip. Moving it to a section heading alone would have weakened
     * that -- a 24-row section scrolls its own heading off screen. So the
     * heading is sticky within the scroll container (see
     * .k9tablet-runtime-tier-band in html/tablet.css), which keeps the
     * sentence on screen for whichever section is being looked at: strictly
     * more visible than before, not less. Each row also keeps its own tier
     * badge, so a row is still self-describing when read in isolation.
     * (I could not render this to confirm the sticky behaviour from here;
     * if it ever fails to stick, the result is one heading above the
     * section, which is still no worse than the per-row repetition it
     * replaced -- it is not a case where the requirement silently breaks.)
     * @returns {HTMLElement}
     */
    function buildRuntimeFeaturesTable() {
        var list = splitRuntimeFeaturesByReachability().live;
        if (list.length === 0) {
            return mk('p', { class: 'k9tablet-muted', text: S('runtime_features_empty') });
        }

        var table = mk('table', { class: 'k9tablet-table' });
        var thead = mk('thead');
        var headRow = mk('tr');
        var columns = [S('column_name'), S('column_tier'), S('column_current_value'), S('column_actions')];
        columns.forEach(function (h) {
            headRow.appendChild(mk('th', { text: h }));
        });
        thead.appendChild(headRow);
        table.appendChild(thead);

        // Bucket by tier, preserving sortedRuntimeFeatures()'s own stable
        // alphabetical order WITHIN each bucket -- this is a display
        // grouping, never a re-sort of the rows themselves.
        var buckets = {};
        for (var i = 0; i < list.length; i++) {
            var tier = list[i].tier;
            var bucket = RUNTIME_TIER_ORDER.indexOf(tier) !== -1 ? tier : 'unaudited';
            if (!buckets[bucket]) buckets[bucket] = [];
            buckets[bucket].push(list[i]);
        }

        var tbody = mk('tbody');
        RUNTIME_TIER_ORDER.forEach(function (tier) {
            var rows = buckets[tier];
            if (!rows || rows.length === 0) return;

            var bandTr = mk('tr', { class: 'k9tablet-runtime-tier-band' });
            var bandTh = mk('th', {
                class: 'k9tablet-feature-group-row-cell k9tablet-runtime-tier-band-cell k9tablet-runtime-tier-band-cell--' + tier,
                attrs: { colspan: String(columns.length), scope: 'colgroup' },
            });
            bandTh.appendChild(mk('span', { class: 'k9tablet-feature-group-row-label', text: runtimeTierLabel(tier) }));
            bandTh.appendChild(mk('span', {
                class: 'k9tablet-feature-group-row-count',
                text: formatTemplate(S('feature_group_row_count_template'), { count: rows.length }),
            }));
            // The tier's own explanation -- once, here, instead of on every
            // row below it. Same locale-driven sentence as before, same
            // runtimeTierDescription() source.
            bandTh.appendChild(mk('p', { class: 'k9tablet-muted k9tablet-hint k9tablet-runtime-tier-band-desc', text: runtimeTierDescription(tier) }));
            bandTr.appendChild(bandTh);
            tbody.appendChild(bandTr);

            for (var r = 0; r < rows.length; r++) tbody.appendChild(buildRuntimeFeatureRow(rows[r]));
        });

        table.appendChild(tbody);
        return table;
    }

    /**
     * @param {{name:string,currentValue:boolean,tier:string,note?:string,overridden:boolean,overriddenBy?:string,overriddenAt?:string,lockoutRisk?:boolean,sessionOnly?:boolean,lockoutWarning?:string}} feature
     */
    function buildRuntimeFeatureRow(feature) {
        var isLockoutRisk = feature.lockoutRisk === true;
        var tr = isLockoutRisk ? mk('tr', { class: 'k9tablet-runtime-lockout-row' }) : mk('tr');
        // BETTER DISTINCTION FOR DANGEROUS SETTINGS -- the warning triangle
        // sits on the FIRST column a viewer reads (Name), not only on the
        // Effect column further right, so a viewer scanning down the Name
        // column alone still sees which rows need extra care. The icon is
        // pure CSS (::before on .k9tablet-runtime-name-cell--risk, see
        // html/tablet.css), deliberately NOT a second DOM node inside this
        // cell: this cell's `text` must stay feature.name and NOTHING else
        // -- html/tests/tablet_runtime_control_spec.js and others locate a
        // row by its EXACT feature name (a single element's own
        // textContent, including a plain child-text concatenation in a
        // real browser), and generated CSS content is never part of
        // textContent in any browser, so this reads identically to a
        // non-risk row's name cell while still painting the icon.
        tr.appendChild(mk('td', { class: isLockoutRisk ? 'k9tablet-runtime-name-cell k9tablet-runtime-name-cell--risk' : 'k9tablet-runtime-name-cell', text: feature.name }));

        var tierTd = mk('td');
        tierTd.appendChild(mk('span', { class: 'k9tablet-runtime-tier k9tablet-runtime-tier--' + feature.tier, text: runtimeTierLabel(feature.tier) }));
        // THE HONESTY REQUIREMENT still holds, and is still met without a
        // hover or a tooltip -- but the sentence now lives on this
        // section's own sticky band rather than being repeated on all 57
        // rows. See buildRuntimeFeaturesTable()'s doc comment for why that
        // is more visible rather than less. The badge above stays on the
        // row, so the row remains self-describing on its own.
        // A per-feature caveat (e.g. ScentTracking's drop-hook gap) is
        // server-authored, dynamic supplementary text -- rendered as a
        // passthrough, same posture as errorText()'s own `message` field,
        // NEVER treated as this row's PRIMARY (locale-driven) explanation.
        if (typeof feature.note === 'string' && feature.note.length > 0) {
            tierTd.appendChild(mk('p', { class: 'k9tablet-muted k9tablet-hint', text: feature.note }));
        }
        // LOCKOUT-RISK / SESSION-ONLY, satisfied BEFORE any click, SAME
        // posture as the tier explanation above: a row this dangerous must
        // look different before it is ever clicked, not only after a
        // refusal. `runtime_lockout_row_hint`/`runtime_session_only_hint`
        // are THIS PAGE'S OWN plain-language rendering of the two booleans
        // (never a substitute for the server's own `lockoutWarning`, which
        // is shown verbatim only once the confirmation panel below opens).
        if (isLockoutRisk) {
            tierTd.appendChild(mk('span', { class: 'k9tablet-runtime-lockout-badge', text: S('runtime_lockout_badge') }));
            tierTd.appendChild(mk('p', { class: 'k9tablet-muted k9tablet-hint', text: S('runtime_lockout_row_hint') }));
            // sessionOnly is GENUINELY REASSURING, and reads very
            // differently from a lockout-risk feature with no such escape
            // hatch (CommandTablet is the one lockoutRisk feature that is
            // NOT sessionOnly) -- always its own, visually distinct badge,
            // never folded into the risk badge above.
            if (feature.sessionOnly === true) {
                tierTd.appendChild(mk('span', { class: 'k9tablet-runtime-session-badge', text: S('runtime_session_only_badge') }));
                tierTd.appendChild(mk('p', { class: 'k9tablet-muted k9tablet-hint', text: S('runtime_session_only_hint') }));
            }
        }
        tr.appendChild(tierTd);

        var valueTd = mk('td');
        valueTd.appendChild(mk('span', { class: 'k9tablet-runtime-value k9tablet-runtime-value--' + (feature.currentValue ? 'on' : 'off'), text: feature.currentValue ? S('runtime_value_on') : S('runtime_value_off') }));
        if (feature.overridden) {
            valueTd.appendChild(mk('p', { class: 'k9tablet-muted', text: formatTemplate(S('runtime_overridden_by_at'), { who: feature.overriddenBy || '?', when: feature.overriddenAt || '?' }) }));
        }
        tr.appendChild(valueTd);

        var actionsTd = mk('td', { class: 'k9tablet-cert-tier-actions' });
        // At most ONE lockout confirmation panel open at a time, keyed by
        // feature name -- see openRuntimeLockoutConfirm()'s own doc comment.
        var lockoutConfirm = (isLockoutRisk && state.runtimeLockoutConfirm && state.runtimeLockoutConfirm.name === feature.name)
            ? state.runtimeLockoutConfirm : null;
        if (feature.tier === 'protected' || feature.tier === 'unaudited') {
            // NO TOGGLE RENDERED AT ALL for these two -- server/runtimecontrol.lua
            // refuses both unconditionally (reason='protected_feature'/
            // 'unaudited_feature'); offering a button that always comes
            // back refused would be exactly the "switch that appears to
            // work" problem this task exists to fix.
            actionsTd.appendChild(mk('p', { class: 'k9tablet-muted', text: runtimeTierDescription(feature.tier) }));
        } else if (lockoutConfirm) {
            actionsTd.appendChild(buildRuntimeLockoutConfirmPanel(feature, lockoutConfirm));
        } else {
            var toggleLabel = feature.currentValue ? S('runtime_feature_toggle_off_label') : S('runtime_feature_toggle_on_label');
            if (isLockoutRisk) {
                // MORE FRICTION THAN mkConfirmButton's ordinary two-click
                // pattern (see that function's own header) -- this single
                // click only OPENS the read-and-type confirmation panel
                // below; it never itself arms or sends anything. This page
                // NEVER decides authorization either way -- the server
                // refuses without a matching `confirm` regardless of what
                // this click does (see toggleRuntimeFeature() below).
                actionsTd.appendChild(mkButton(toggleLabel, 'k9tablet-btn' + (feature.currentValue ? ' k9tablet-btn--danger' : ''), function () {
                    openRuntimeLockoutConfirm(feature, 'toggle', !feature.currentValue);
                }, { disabled: state.pendingAction || !state.runtimeControlEnabled }));
            } else {
                actionsTd.appendChild(mkConfirmButton(toggleLabel, 'k9tablet-btn' + (feature.currentValue ? ' k9tablet-btn--danger' : ''), function () {
                    toggleRuntimeFeature(feature.name, !feature.currentValue, feature.tier);
                }, { disabled: state.pendingAction || !state.runtimeControlEnabled }));
            }

            if (feature.overridden) {
                if (isLockoutRisk) {
                    actionsTd.appendChild(mkButton(S('runtime_feature_reset_label'), 'k9tablet-link-btn', function () {
                        openRuntimeLockoutConfirm(feature, 'reset', null);
                    }, { disabled: state.pendingAction || !state.runtimeControlEnabled }));
                } else {
                    actionsTd.appendChild(mkConfirmButton(S('runtime_feature_reset_label'), 'k9tablet-link-btn', function () {
                        resetRuntimeFeature(feature.name, feature.tier);
                    }, { disabled: state.pendingAction || !state.runtimeControlEnabled }));
                }
            }
        }

        // A Set/Reset REFUSAL renders INLINE on THIS specific row --
        // "cannot, and here is why" -- same convention as
        // certTierActionError/shopLocationActionError above. Covers
        // `reason='confirmation_required'` too (see runtimeFeatureErrorText()
        // below) for the rare case the server refuses anyway (e.g. the
        // feature's own `name` changed between load and click) -- this
        // page's own Confirm button is disabled until the typed value
        // matches, but the SERVER'S check is the one that actually matters.
        if (state.runtimeFeatureActionError && state.runtimeFeatureActionError.key === feature.name) {
            actionsTd.appendChild(mk('p', { class: 'k9tablet-error-text k9tablet-cert-tier-row-error', text: state.runtimeFeatureActionError.text }));
        }

        tr.appendChild(actionsTd);
        return tr;
    }

    /**
     * THE read-and-type lockout confirmation gate -- see
     * buildRuntimeFeatureRow() above and this task's own brief: "this is
     * not the two-click confirm used elsewhere in this page... the operator
     * should have to read something, not just click twice." Renders the
     * server's OWN `lockoutWarning` text VERBATIM (`.textContent` only --
     * see this file's own DOM BUILD HELPERS header; a hostile/malformed
     * string arriving over the wire here can never become markup) --
     * NEVER this file's own wording, per server/runtimecontrol.lua's own
     * header: "the server's text is the authoritative description of what
     * will happen." The Confirm button stays disabled until the typed
     * value equals `feature.name` exactly -- THIS PAGE NEVER DECIDES
     * AUTHORIZATION: that disabled check is a UX convenience only, never
     * the real gate -- the typed value is sent back as `confirm` and the
     * SERVER independently refuses anything that does not match `name`
     * exactly (server/runtimecontrol.lua's runtimeSetFeature/
     * runtimeResetFeature), regardless of what this panel does or whether
     * it was bypassed entirely by a hand-crafted NUI message.
     * @param {object} feature @param {{name:string,action:'toggle'|'reset',newValue:?boolean,typedValue:string}} confirmState
     */
    function buildRuntimeLockoutConfirmPanel(feature, confirmState) {
        var wrap = mk('div', { class: 'k9tablet-runtime-lockout-confirm' });
        wrap.appendChild(mk('h3', { class: 'k9tablet-section-heading', text: S('runtime_lockout_confirm_heading') }));
        wrap.appendChild(mk('p', {
            class: 'k9tablet-runtime-lockout-warning',
            text: typeof feature.lockoutWarning === 'string' ? feature.lockoutWarning : '',
        }));
        if (feature.sessionOnly === true) {
            wrap.appendChild(mk('p', { class: 'k9tablet-muted k9tablet-hint', text: S('runtime_session_only_hint') }));
        }
        wrap.appendChild(mk('p', { class: 'k9tablet-muted k9tablet-hint', text: S('runtime_lockout_confirm_instruction') }));

        wrap.appendChild(mk('label', { class: 'k9tablet-cert-tier-label', text: formatTemplate(S('runtime_lockout_confirm_input_label'), { name: feature.name }) }));
        var input = mk('input', { class: 'k9tablet-runtime-lockout-confirm-input', attrs: { type: 'text', placeholder: S('runtime_lockout_confirm_input_placeholder') } });
        input.value = confirmState.typedValue;
        // Re-renders on every keystroke (same "live filter" posture as the
        // roster/command-reference search boxes -- see this file's own
        // FOCUS + SCROLL CONTINUITY header) so the Confirm button's
        // `disabled` state updates as the operator types, without this
        // page ever needing to mutate an already-built button directly.
        input.addEventListener('input', function (e) {
            confirmState.typedValue = e.target.value;
            render();
        });
        wrap.appendChild(input);

        var matches = confirmState.typedValue === feature.name;
        var actionsRow = mk('div', { class: 'k9tablet-cert-tier-actions' });
        actionsRow.appendChild(mkButton(S('runtime_lockout_confirm_button'), 'k9tablet-btn k9tablet-btn--danger', confirmRuntimeLockoutAction, { disabled: state.pendingAction || !matches }));
        actionsRow.appendChild(mkButton(S('runtime_lockout_cancel_label'), 'k9tablet-link-btn', closeRuntimeLockoutConfirm, { disabled: state.pendingAction }));
        wrap.appendChild(actionsRow);

        return wrap;
    }

    /**
     * Opens the read-and-type confirmation for `feature` -- sends NOTHING
     * to the server yet, only records what the eventual call should look
     * like once the operator actually confirms. See
     * buildRuntimeLockoutConfirmPanel() above for the full contract.
     * @param {object} feature @param {'toggle'|'reset'} action
     * @param {?boolean} newValue -- only meaningful for 'toggle'
     */
    function openRuntimeLockoutConfirm(feature, action, newValue) {
        state.runtimeLockoutConfirm = { name: feature.name, action: action, newValue: newValue, tier: feature.tier, typedValue: '' };
        state.runtimeFeatureActionError = null;
        render();
    }

    function closeRuntimeLockoutConfirm() {
        state.runtimeLockoutConfirm = null;
        render();
    }

    /** Fires the actual mutation, WITH `confirm` set to the typed value --
     * only when that value already matches the feature's own name (a
     * defensive re-check mirroring the Confirm button's own `disabled`
     * gate, NEVER the real one: the server re-checks this exact match
     * itself, independently, regardless of what this function does). */
    function confirmRuntimeLockoutAction() {
        var confirmState = state.runtimeLockoutConfirm;
        if (!confirmState || confirmState.typedValue !== confirmState.name) return;
        if (confirmState.action === 'toggle') {
            toggleRuntimeFeature(confirmState.name, confirmState.newValue, confirmState.tier, confirmState.typedValue);
        } else {
            resetRuntimeFeature(confirmState.name, confirmState.tier, confirmState.typedValue);
        }
    }

    function buildRuntimeTunablesSection() {
        var wrap = mk('div', {});
        if (state.runtimeTunablesLoading && !state.runtimeTunables) {
            wrap.appendChild(mk('p', { text: S('loading') }));
            return wrap;
        }
        if (state.runtimeTunablesError && !state.runtimeTunables) {
            wrap.appendChild(mk('p', { class: 'k9tablet-error-text', text: runtimeListErrorText(state.runtimeTunablesError) }));
            wrap.appendChild(mkButton(S('retry_label'), 'k9tablet-btn', loadRuntimeTunables));
            return wrap;
        }
        if (!state.runtimeTunables) {
            wrap.appendChild(mk('p', { text: S('loading') }));
            return wrap;
        }
        wrap.appendChild(buildRuntimeTunablesTable());
        return wrap;
    }

    function buildRuntimeTunablesTable() {
        var list = sortedRuntimeTunables();
        if (list.length === 0) {
            return mk('p', { class: 'k9tablet-muted', text: S('runtime_tunables_empty') });
        }

        var table = mk('table', { class: 'k9tablet-table' });
        var thead = mk('thead');
        var headRow = mk('tr');
        [S('runtime_tunable_column_setting'), S('column_current_value'), S('column_range'), S('column_type'), S('column_actions')].forEach(function (h) {
            headRow.appendChild(mk('th', { text: h }));
        });
        thead.appendChild(headRow);
        table.appendChild(thead);

        var tbody = mk('tbody');
        for (var i = 0; i < list.length; i++) tbody.appendChild(buildRuntimeTunableRow(list[i]));
        table.appendChild(tbody);
        return table;
    }

    /**
     * @param {{key:string,currentValue:number,min:number,max:number,integer:boolean,overridden:boolean,overriddenBy?:string,overriddenAt?:string,description?:string}} tunable
     */
    function buildRuntimeTunableRow(tunable) {
        var tr = mk('tr');
        // PLAIN-ENGLISH DESCRIPTION FIRST, RAW KEY SECOND -- the fix for
        // this exact row USED to show ONLY tunable.key (e.g.
        // "Wellbeing.Fatigue.sprintDecayPerTick"), which told a
        // non-technical server owner nothing about what the setting
        // actually does, or how to tell two similarly-named settings
        // apart (this resource's own custom Fatigue stat vs. the game's
        // built-in Stamina bar, to name the pair that started this fix).
        // `tunable.description` is server-authored (see
        // server/runtimecontrol.lua's GetTunableDescription) and OPTIONAL
        // by design: a tunable with no description yet must still render,
        // still be editable, and never throw -- it just falls back to
        // showing the raw key alone, exactly as every row used to.
        //
        // The raw key is kept as its OWN text node (never concatenated
        // into the description's own node) in BOTH branches below, so a
        // lookup by that exact key's textContent (html/tests/
        // tablet_runtime_control_spec.js's own `findByText(root,
        // 'LeashMaxDistance')`, e.g.) keeps working unchanged whether or
        // not a description exists for that row.
        var keyTd = mk('td');
        if (typeof tunable.description === 'string' && tunable.description.length > 0) {
            keyTd.appendChild(mk('p', { text: tunable.description }));
            keyTd.appendChild(mk('p', { class: 'k9tablet-muted k9tablet-hint', text: tunable.key }));
        } else {
            keyTd.appendChild(mk('span', { text: tunable.key }));
        }
        tr.appendChild(keyTd);

        var isEditing = state.runtimeTunableDraft && state.runtimeTunableDraft.key === tunable.key;

        var valueTd = mk('td');
        if (isEditing) {
            // A plain number-input HINT only (min/max/step) -- NOT an
            // authoritative gate: this page never blocks Save based on
            // these attributes, and reads `.value` directly rather than
            // relying on native form validation to enforce them (see
            // saveRuntimeTunableDraft() below and this screen's own header
            // note: "do not duplicate the validation client-side as if it
            // were authoritative").
            var input = mk('input', { class: 'k9tablet-cert-tier-label-input', attrs: { type: 'number', min: String(tunable.min), max: String(tunable.max), step: tunable.integer ? '1' : 'any' } });
            input.value = state.runtimeTunableDraft.value;
            input.addEventListener('input', function (e) { state.runtimeTunableDraft.value = e.target.value; });
            valueTd.appendChild(input);
        } else {
            valueTd.appendChild(mk('span', { text: String(tunable.currentValue) }));
            if (tunable.overridden) {
                valueTd.appendChild(mk('p', { class: 'k9tablet-muted', text: formatTemplate(S('runtime_overridden_by_at'), { who: tunable.overriddenBy || '?', when: tunable.overriddenAt || '?' }) }));
            }
        }
        tr.appendChild(valueTd);

        tr.appendChild(mk('td', { class: 'k9tablet-muted', text: tunable.min + ' – ' + tunable.max }));
        tr.appendChild(mk('td', { class: 'k9tablet-muted', text: tunable.integer ? S('runtime_tunable_type_integer') : S('runtime_tunable_type_decimal') }));

        var actionsTd = mk('td', { class: 'k9tablet-cert-tier-actions' });
        if (isEditing) {
            actionsTd.appendChild(mkButton(S('runtime_tunable_save_label'), 'k9tablet-btn', function () {
                saveRuntimeTunableDraft(tunable);
            }, { disabled: state.pendingAction }));
            actionsTd.appendChild(mkButton(S('runtime_tunable_cancel_label'), 'k9tablet-link-btn', closeRuntimeTunableDraft));
        } else {
            actionsTd.appendChild(mkButton(S('runtime_tunable_edit_label'), 'k9tablet-btn', function () {
                openRuntimeTunableDraft(tunable);
            }, { disabled: state.pendingAction || !state.runtimeControlEnabled }));
            if (tunable.overridden) {
                actionsTd.appendChild(mkConfirmButton(S('runtime_tunable_reset_label'), 'k9tablet-link-btn', function () {
                    resetRuntimeTunable(tunable.key);
                }, { disabled: state.pendingAction || !state.runtimeControlEnabled }));
            }
        }

        if (state.runtimeTunableFieldError && state.runtimeTunableFieldError.key === tunable.key) {
            actionsTd.appendChild(mk('p', { class: 'k9tablet-error-text k9tablet-cert-tier-row-error', text: state.runtimeTunableFieldError.text }));
        }

        tr.appendChild(actionsTd);
        return tr;
    }

    /** Shared by both the Features and Tunables LIST loaders below -- their
     * only failure mode beyond fetchNui()'s own synthetic timeout/network
     * codes is `reason='denied'` (CanManageRuntimeControl), renamed to
     * `error` by client/tablet.lua's TranslateReasonResult.
     * @param {object|undefined} result @returns {string} */
    function runtimeListErrorText(result) {
        if (!result) return S('error_generic');
        if (typeof result.message === 'string' && result.message.length > 0) return result.message;
        if (result.error === 'denied') return S('runtime_error_denied');
        return errorText(result);
    }

    /** @param {object|undefined} result @returns {string} */
    /**
     * The server's own `note` field, when it set one.
     *
     * server/runtimecontrol.lua attaches `note` as PLAIN, PLAYER-FACING
     * ENGLISH PROSE -- not a code to look up -- in three places, and until
     * 2026-08-31 no renderer in this file read it, so all three were
     * silently discarded:
     *
     *   1. `parent_disabled` (a REFUSAL). The note names the exact
     *      `Config.FeatureGroups.<X>.enabled` flag that is blocking the
     *      toggle and says the change would be forced back off on the next
     *      restart. Without it this refusal fell to `default:` and rendered
     *      as the bare "action failed" line -- the single least useful
     *      thing an admin tool can say, and actively misleading here, since
     *      the fix is one line in config.lua.
     *   2. `sessionOnly` (a SUCCESS). "this change is NOT persisted -- the
     *      next resource restart reverts it". Dropping this is worse than
     *      dropping a refusal: the admin is told the action SUCCEEDED, sees
     *      it take effect, and finds it reverted after a restart with
     *      nothing anywhere having warned them.
     *   3. The no-confirmed-enforcement-point caveat, same shape as 2.
     *
     * Safe to render as-is: mk() assigns through `textContent`, never
     * innerHTML, so this is inert text even though it is server-authored
     * English rather than a locale key.
     * @param {object|undefined} result @returns {string} '' when absent
     */
    function serverNoteText(result) {
        if (!result || typeof result.note !== 'string') return '';
        var note = result.note.trim();
        return note.length > 0 ? note : '';
    }

    /** Joins a locale sentence with the server's own note, when there is one. */
    function withServerNote(baseText, result) {
        var note = serverNoteText(result);
        if (note === '') return baseText;
        if (!baseText) return note;
        return baseText + ' ' + note;
    }

    function runtimeFeatureErrorText(result) {
        if (!result) return S('action_failed');
        if (typeof result.message === 'string' && result.message.length > 0) return result.message;
        // Checked BEFORE the switch: when the server wrote a note it is
        // strictly more specific than any code this switch could map,
        // and for `parent_disabled` it is the only explanation there is.
        var note = serverNoteText(result);
        if (note !== '') return note;
        switch (result.error) {
            case 'denied': return S('runtime_error_denied');
            case 'rate_limited': return S('runtime_error_rate_limited');
            case 'invalid_feature': return S('runtime_feature_error_invalid_feature');
            case 'invalid_value': return S('runtime_feature_error_invalid_value');
            // A refusal ("cannot, and here is why"), not a generic failure --
            // this page's own Confirm button is disabled until the typed
            // value matches, so this is only expected to fire for a genuine
            // race (the feature's own `name` changing between load and
            // click) or a caller bypassing this page entirely -- either
            // way, told plainly rather than as a bare "action failed".
            case 'confirmation_required': return S('runtime_feature_error_confirmation_required');
            // REFUSALS ("cannot, and here is why"), not generic failures --
            // per this task's own explicit instruction -- reuse the SAME
            // tier description this row already shows before the click,
            // so the reason given here is never a DIFFERENT story than the
            // one already on screen.
            case 'protected_feature': return S('runtime_tier_protected_desc');
            case 'unaudited_feature': return S('runtime_tier_unaudited_desc');
            case 'feature_disabled': return S('runtime_control_disabled_note');
            case 'db_error': return S('runtime_error_db_error');
            case 'timeout': return S('error_timeout');
            case 'network_error': return S('error_network');
            default: return S('action_failed');
        }
    }

    /** @param {object|undefined} result @returns {string} */
    function runtimeTunableErrorText(result) {
        if (!result) return S('action_failed');
        if (typeof result.message === 'string' && result.message.length > 0) return result.message;
        // Checked BEFORE the switch: when the server wrote a note it is
        // strictly more specific than any code this switch could map,
        // and for `parent_disabled` it is the only explanation there is.
        var note = serverNoteText(result);
        if (note !== '') return note;
        switch (result.error) {
            case 'denied': return S('runtime_error_denied');
            case 'rate_limited': return S('runtime_error_rate_limited');
            case 'invalid_key': return S('runtime_tunable_error_invalid_key');
            // The server's OWN real min/max, echoed back verbatim -- see
            // this file's header NUI CONTRACT note: never a client-guessed
            // range.
            case 'out_of_range': return formatTemplate(S('runtime_tunable_error_out_of_range'), {
                min: (result && result.min !== undefined && result.min !== null) ? result.min : '?',
                max: (result && result.max !== undefined && result.max !== null) ? result.max : '?',
            });
            case 'not_integer': return S('runtime_tunable_error_not_integer');
            case 'feature_disabled': return S('runtime_control_disabled_note');
            case 'db_error': return S('runtime_error_db_error');
            case 'timeout': return S('error_timeout');
            case 'network_error': return S('error_network');
            default: return S('action_failed');
        }
    }

    /** @param {object} tunable */
    function openRuntimeTunableDraft(tunable) {
        state.runtimeTunableDraft = { key: tunable.key, value: String(tunable.currentValue) };
        state.runtimeTunableFieldError = null;
        render();
    }

    function closeRuntimeTunableDraft() {
        state.runtimeTunableDraft = null;
        state.runtimeTunableFieldError = null;
        render();
    }

    // ---- K9 Audit Trail viewer screen (see canViewAudit()) ----

    /** Fixed order the first five mode buttons render in -- matches
     * server/admin.lua's own COMMAND SURFACE listing (k9audit cert,
     * k9audit partner, k9audit search, k9audit xp, k9audit dept). 'catalog' is
     * the SIXTH mode (this pass), appended rather than interleaved -- it
     * has no k9audit* command counterpart at all (bridges
     * tabletAuditCatalog directly, see this file's own NUI CONTRACT note),
     * so it does not belong inside that five-command ordering. */
    var AUDIT_MODES = ['cert', 'partner', 'search', 'xp', 'dept', 'catalog'];

    /** @param {string} mode @returns {string} */
    function auditModeLabel(mode) {
        switch (mode) {
            case 'cert': return S('audit_mode_cert');
            case 'partner': return S('audit_mode_partner');
            case 'search': return S('audit_mode_search');
            case 'xp': return S('audit_mode_xp');
            case 'dept': return S('audit_mode_dept');
            case 'catalog': return S('audit_mode_catalog');
            default: return mode;
        }
    }

    /**
     * Owner's own framing (relayed): the audit trail this resource
     * carefully writes -- certification grants/revokes, partnership
     * history, the search log, XP totals, department rosters -- was
     * invisible to anyone without server console/SQL access, even though
     * server/admin.lua's own five commands already existed to query it.
     * This screen is that surface. server/admin.lua's own IsAuthorizedAdmin
     * is the ONLY real gate (see canViewAudit()'s own doc comment); every
     * control here is a convenience, per THE SECURITY RULE.
     */
    function buildAuditScreen() {
        var wrap = mk('div', { class: 'k9tablet-screen' });
        wrap.appendChild(mk('h2', { class: 'k9tablet-section-heading', text: S('audit_heading') }));
        wrap.appendChild(mk('p', { class: 'k9tablet-muted', text: S('audit_intro') }));

        if (!state.auditEnabled) {
            wrap.appendChild(mk('p', { class: 'k9tablet-muted', text: S('audit_disabled_note') }));
        }

        wrap.appendChild(buildAuditModeSwitch());
        wrap.appendChild(buildAuditForm());
        wrap.appendChild(buildAuditResults());
        return wrap;
    }

    function buildAuditModeSwitch() {
        var row = mk('div', { class: 'k9tablet-audit-modes' });
        AUDIT_MODES.forEach(function (mode) {
            row.appendChild(mkButton(auditModeLabel(mode), 'k9tablet-tab' + (state.auditMode === mode ? ' k9tablet-tab--active' : ''), function () {
                // Switching mode changes which fields/columns even apply --
                // the LAST mode's result would be the wrong shape to keep
                // showing under a different mode's table columns, so it (and
                // any leftover error) is cleared here. The typed field
                // VALUES themselves (citizenid/department/search value/limit)
                // are deliberately left alone -- several modes share the
                // same citizenid input, and there is no reason to make an
                // officer retype it just for glancing between Certifications
                // and Partnerships for the same person.
                state.auditMode = mode;
                state.auditError = null;
                state.auditResult = null;
                render();
            }, { disabled: state.auditLoading }));
        });
        return row;
    }

    /**
     * @returns {string[]} the REAL, configured department keys this VIEWER
     * currently holds a certification row for -- server/tablet.lua's own
     * tabletRequestMyRecord returns "ONE ROW PER CONFIGURED DEPARTMENT",
     * so this is never a hardcoded department list, and needs no extra
     * round trip: loadMyRecord() already runs on every tablet:open. Used
     * ONLY as `<datalist>` autocomplete suggestions for the Department
     * Roster mode's free-text input, never as the sole way to enter one
     * -- server/admin.lua's own IsValidDepartment is the real gate, and an
     * operator may legitimately want to audit a department this VIEWER
     * personally holds no certification in at all (that file's own header:
     * "NOT SCOPED TO THE CALLER'S OWN DEPARTMENT").
     */
    function knownDepartmentKeys() {
        if (!state.myRecord || !Array.isArray(state.myRecord.certifications)) return [];
        var out = [];
        state.myRecord.certifications.forEach(function (c) {
            if (c && typeof c.departmentKey === 'string' && c.departmentKey.length > 0) out.push(c.departmentKey);
        });
        return out;
    }

    /**
     * The 8 real catalog names server/admin.lua's own CATALOG_AUDIT_SOURCES
     * table names, in that table's own declared order -- a DISPLAY
     * convenience only, never the real allowlist (that table itself is;
     * see tablet:auditCatalog's own doc comment in client/tablet.lua for
     * why this file does not re-check it). Each pair is
     * [catalogName, an EXISTING heading-locale-key already naming this
     * exact catalog/screen elsewhere on this page] -- reused rather than
     * a brand-new key per catalog, so this dropdown's option text can
     * never drift from what that screen already calls itself.
     * runtimeOverrides has no dedicated catalog SCREEN of its own (it
     * spans both the Runtime Feature Control screen's tunables AND its
     * feature toggles) -- runtime_control_heading is that screen's own
     * heading and the closest real match.
     */
    var AUDIT_CATALOG_NAMES = [
        ['certTiers', 'cert_tiers_heading'],
        ['permissionKeys', 'permission_keys_heading'],
        ['xpTiers', 'xp_tiers_heading'],
        ['shopItems', 'shop_items_heading'],
        ['shopLocations', 'shop_locations_heading'],
        ['k9Profiles', 'k9_profiles_heading'],
        ['runtimeOverrides', 'runtime_control_heading'],
        ['tabletThemes', 'theme_heading'],
    ];

    function buildAuditForm() {
        var form = mk('div', { class: 'k9tablet-audit-form' });

        if (state.auditMode === 'cert' || state.auditMode === 'partner' || state.auditMode === 'xp') {
            form.appendChild(mk('span', { class: 'k9tablet-audit-label', text: S('audit_citizenid_label') }));
            var idInput = mk('input', { class: 'k9tablet-search', attrs: { type: 'text', placeholder: S('audit_citizenid_placeholder') } });
            idInput.value = state.auditCitizenId;
            idInput.addEventListener('input', function (e) { state.auditCitizenId = e.target.value; });
            form.appendChild(idInput);
        } else if (state.auditMode === 'dept') {
            form.appendChild(mk('span', { class: 'k9tablet-audit-label', text: S('audit_department_label') }));
            var deptInput = mk('input', { class: 'k9tablet-search', attrs: { type: 'text', placeholder: S('audit_department_placeholder'), list: 'k9tablet-audit-dept-options' } });
            deptInput.value = state.auditDepartment;
            deptInput.addEventListener('input', function (e) { state.auditDepartment = e.target.value; });
            form.appendChild(deptInput);

            var knownDepts = knownDepartmentKeys();
            if (knownDepts.length > 0) {
                var dataList = mk('datalist', { attrs: { id: 'k9tablet-audit-dept-options' } });
                knownDepts.forEach(function (key) {
                    var opt = mk('option', {});
                    opt.setAttribute('value', key);
                    dataList.appendChild(opt);
                });
                form.appendChild(dataList);
            } else {
                form.appendChild(mk('p', { class: 'k9tablet-muted k9tablet-hint', text: S('audit_department_hint') }));
            }
        } else if (state.auditMode === 'search') {
            form.appendChild(mk('span', { class: 'k9tablet-audit-label', text: S('audit_search_mode_label') }));
            var modeSelect = mk('select', { class: 'k9tablet-audit-select' });
            [
                ['officer', S('audit_search_mode_officer')],
                ['plate', S('audit_search_mode_plate')],
                ['person', S('audit_search_mode_person')],
                ['recent', S('audit_search_mode_recent')],
            ].forEach(function (pair) {
                var opt = mk('option', { text: pair[1] });
                opt.setAttribute('value', pair[0]);
                modeSelect.appendChild(opt);
            });
            modeSelect.value = state.auditSearchMode;
            modeSelect.addEventListener('input', function (e) {
                state.auditSearchMode = e.target.value;
                render(); // the Value field below only applies to 3 of the 4 sub-modes -- must appear/disappear immediately, unlike a plain text field's own deferred-render convention elsewhere on this page
            });
            form.appendChild(modeSelect);

            if (state.auditSearchMode !== 'recent') {
                form.appendChild(mk('span', { class: 'k9tablet-audit-label', text: S('audit_value_label') }));
                var valueInput = mk('input', {
                    class: 'k9tablet-search',
                    attrs: {
                        type: 'text',
                        placeholder: state.auditSearchMode === 'plate' ? S('audit_value_placeholder_plate') : S('audit_value_placeholder_citizenid'),
                    },
                });
                valueInput.value = state.auditSearchValue;
                valueInput.addEventListener('input', function (e) { state.auditSearchValue = e.target.value; });
                form.appendChild(valueInput);
            }
        } else if (state.auditMode === 'catalog') {
            form.appendChild(mk('span', { class: 'k9tablet-audit-label', text: S('audit_catalog_label') }));
            var catalogSelect = mk('select', { class: 'k9tablet-audit-select' });
            AUDIT_CATALOG_NAMES.forEach(function (pair) {
                var opt = mk('option', { text: S(pair[1]) });
                opt.setAttribute('value', pair[0]);
                catalogSelect.appendChild(opt);
            });
            catalogSelect.value = state.auditCatalogName;
            catalogSelect.addEventListener('input', function (e) { state.auditCatalogName = e.target.value; });
            form.appendChild(catalogSelect);
        }

        if (state.auditMode !== 'xp') {
            form.appendChild(mk('span', { class: 'k9tablet-audit-label', text: S('audit_limit_label') }));
            // max is the REAL, server-reported cap once known -- see
            // auditEffectiveCap()'s own comment for why this is only ever
            // AUDIT_LIMIT_MAX_FALLBACK's hardcoded guess before the FIRST
            // successful query this session (or if a response is ever
            // missing `cap`, an older server build). This attribute is a
            // UX hint only, same as every other client-side clamp on this
            // page -- server/admin.lua's own ClampLimit is the real bound.
            var limitInput = mk('input', {
                class: 'k9tablet-audit-limit-input',
                attrs: { type: 'number', min: String(AUDIT_LIMIT_MIN), max: String(auditEffectiveCap()) },
            });
            limitInput.value = String(state.auditLimit);
            limitInput.addEventListener('input', function (e) { state.auditLimit = e.target.value; });
            form.appendChild(limitInput);
        }

        form.appendChild(mkButton(S('audit_run_label'), 'k9tablet-btn', runAuditQuery, { disabled: state.auditLoading || !state.auditEnabled }));
        return form;
    }

    /** @param {*} v @returns {string} S('audit_na') for null/undefined/'' -- never a raw 'null'/'undefined' string on screen. */
    function auditText(v) {
        if (v === null || v === undefined || v === '') return S('audit_na');
        return String(v);
    }

    /** @param {*} v @returns {string} */
    function auditBoolText(v) {
        return v ? S('audit_boolean_yes') : S('audit_boolean_no');
    }

    /**
     * Pairs a raw audit citizenid column with its resolved `_name` sibling
     * (server/admin.lua's EnrichCertHistoryRows/EnrichPartnershipHistoryRows/
     * EnrichSearchLogRows/EnrichDeptRosterRows). This is a forensic table --
     * the id must stay on screen and traceable, but a bare id where a name
     * belongs was the actual complaint, so both are shown together. Mirrors
     * server/admin.lua's own NameWithCitizenId format EXACTLY so the tablet
     * never disagrees with the '/k9audit cert' etc. chat-command output for
     * the same row: id missing/blank -> auditText's S('audit_na'); name
     * resolved to something OTHER than the id -> "Name (id)"; name nil OR
     * (per ResolveAuditDisplayName's own documented "nothing resolved"
     * fallback) identical to the id -> the bare id, same as before this
     * pass. Never invents a name, never hides the id.
     * @param {string|null|undefined} id
     * @param {string|null|undefined} name
     * @returns {string}
     */
    function auditIdWithName(id, name) {
        if (typeof id !== 'string' || id.length === 0) return auditText(id);
        if (typeof name === 'string' && name.length > 0 && name !== id) {
            return name + ' (' + id + ')';
        }
        return id;
    }

    /** @param {object|undefined} result @returns {string} */
    function auditErrorText(result) {
        if (!result) return S('action_failed');
        if (typeof result.message === 'string' && result.message.length > 0) return result.message;
        switch (result.error) {
            case 'not_authorized': return S('audit_error_not_authorized');
            case 'rate_limited': return S('audit_error_rate_limited');
            case 'invalid_args': return S('audit_error_invalid_args');
            case 'timeout': return S('error_timeout');
            case 'network_error': return S('error_network');
            default: return S('action_failed');
        }
    }

    /**
     * "You asked for 500, here are the first 100" -- this pass's own
     * explicit requirement: a caller finding out their result set was
     * silently cut short is the bug, not the cutting itself (the cap is a
     * real, necessary DoS guard -- see server/admin.lua's own header). Only
     * ever called when `result.truncated === true` (see buildAuditResults()
     * above), so `result.actualLimit` is always a real server-reported
     * number here -- `result.requestedLimit` is the value THIS PAGE sent
     * for the request that produced `result` (closured at the call site in
     * runAuditQuery(), never re-derived from the CURRENT `state.auditLimit`,
     * which may already have moved on to a different typed value by the
     * time this renders).
     * @param {{requestedLimit:number, actualLimit:number}} result
     * @returns {string}
     */
    function auditTruncatedText(result) {
        return formatTemplate(S('audit_truncated_notice'), {
            requested: (typeof result.requestedLimit === 'number') ? result.requestedLimit : '?',
            shown: (typeof result.actualLimit === 'number') ? result.actualLimit : '?',
        });
    }

    /**
     * Per-mode column definitions -- see this file's own NUI CONTRACT note
     * on tablet:auditCert/Partner/Search/Xp/Dept for the authoritative row
     * shape each mode returns; every citizenid-identified column pairs its
     * raw id with its resolved `_name` sibling via auditIdWithName() (see
     * that function's own doc comment) -- the id is never dropped, a name
     * is shown alongside it when one resolves. Nothing else is reshaped or
     * renamed. `id` (partner/search rows' own sort key) is deliberately
     * never a column here -- it is a MergeSortedByIdDesc implementation
     * detail server-side, meaningless to an officer reading the table.
     * Does NOT cover the SIXTH mode, 'catalog' -- that one has no single
     * fixed row shape (it depends on which of 8 catalogs was queried), so
     * it gets its own auditColumnsForCatalog() immediately below instead;
     * `buildAuditResultTable()` is what decides which of the two to call.
     * @param {'cert'|'partner'|'search'|'xp'|'dept'} mode
     * @returns {Array<{header:string, render:(row:object)=>string}>}
     */
    function auditColumnsForMode(mode) {
        switch (mode) {
            case 'cert':
                return [
                    { header: S('column_department'), render: function (r) { return auditText(r.job); } },
                    { header: S('column_active'), render: function (r) { return auditBoolText(r.active); } },
                    { header: S('column_granted_by'), render: function (r) { return auditIdWithName(r.granted_by, r.granted_by_name); } },
                    { header: S('column_granted_at'), render: function (r) { return auditText(r.granted_at); } },
                    { header: S('column_revoked_by'), render: function (r) { return auditIdWithName(r.revoked_by, r.revoked_by_name); } },
                    { header: S('column_revoked_at'), render: function (r) { return auditText(r.revoked_at); } },
                ];
            case 'partner':
                return [
                    { header: S('column_k9'), render: function (r) { return auditIdWithName(r.k9_citizenid, r.k9_citizenid_name); } },
                    { header: S('column_handler'), render: function (r) { return auditIdWithName(r.handler_citizenid, r.handler_citizenid_name); } },
                    { header: S('column_active'), render: function (r) { return auditBoolText(r.active); } },
                    { header: S('column_established_by'), render: function (r) { return auditIdWithName(r.established_by, r.established_by_name); } },
                    { header: S('column_established_at'), render: function (r) { return auditText(r.established_at); } },
                    { header: S('column_ended_by'), render: function (r) { return auditIdWithName(r.ended_by, r.ended_by_name); } },
                    { header: S('column_ended_at'), render: function (r) { return auditText(r.ended_at); } },
                ];
            case 'search':
                return [
                    { header: S('column_searched_at'), render: function (r) { return auditText(r.searched_at); } },
                    { header: S('column_searcher'), render: function (r) { return auditIdWithName(r.searcher_citizenid, r.searcher_citizenid_name); } },
                    { header: S('column_searcher_job'), render: function (r) { return auditText(r.searcher_job); } },
                    { header: S('column_target_type'), render: function (r) { return auditText(r.target_type); } },
                    { header: S('column_target'), render: function (r) { return r.target_type === 'vehicle' ? auditText(r.target_plate) : auditIdWithName(r.target_citizenid, r.target_citizenid_name); } },
                    { header: S('column_result'), render: function (r) { return auditText(r.result); } },
                    { header: S('column_weight'), render: function (r) { return auditText(r.total_weight); } },
                    { header: S('column_alert_tier'), render: function (r) { return auditText(r.alert_tier); } },
                ];
            case 'xp':
                return [
                    { header: S('column_audit_xp'), render: function (r) { return auditText(r.xp); } },
                    { header: S('column_updated_at'), render: function (r) { return auditText(r.updated_at); } },
                ];
            case 'dept':
                return [
                    { header: S('column_citizenid'), render: function (r) { return auditIdWithName(r.citizenid, r.citizenid_name); } },
                    { header: S('column_granted_by'), render: function (r) { return auditIdWithName(r.granted_by, r.granted_by_name); } },
                    { header: S('column_granted_at'), render: function (r) { return auditText(r.granted_at); } },
                ];
            default:
                return [];
        }
    }

    /**
     * Column definitions for the 'catalog' mode's own 8 possible
     * catalogs -- unlike every other mode above, 'catalog' has no single
     * fixed row shape of its own; it depends entirely on WHICH catalog was
     * queried (server/admin.lua's own CATALOG_AUDIT_SOURCES table and the
     * eight distinct K9Store.*Audit_GetRecent accessors it names are the
     * authoritative source for every shape below -- see that table's own
     * trust-boundary header comment). Every citizenid-identified column
     * still pairs its raw id with its resolved `_name` sibling via
     * auditIdWithName(), same convention as auditColumnsForMode() above.
     *
     * REUSE MAP (why so few of these headers are brand-new keys): six of
     * the eight catalogs (certTiers/permissionKeys/xpTiers/shopItems/
     * k9Profiles, plus shopLocations' own wider shape) share the exact
     * same `action`/`detail`/`changed_by`/`changed_at` envelope server-side
     * (server/datastore.lua's own K9Store.*Audit_Append writers all share
     * this shape) around ONE catalog-specific "what changed" column --
     * that one column's header is reused from whichever EXISTING screen
     * already edits that exact field (cert_tier_key_label, etc. -- see
     * each case below for which), never a new key. tabletThemes reuses
     * the Tablet Appearance screen's own six field labels verbatim, for
     * the identical reason.
     * @param {'certTiers'|'permissionKeys'|'xpTiers'|'shopItems'|'shopLocations'|'k9Profiles'|'runtimeOverrides'|'tabletThemes'} catalogName
     * @returns {Array<{header:string, render:(row:object)=>string}>}
     */
    function auditColumnsForCatalog(catalogName) {
        var changedByColumn = { header: S('column_changed_by'), render: function (r) { return auditIdWithName(r.changed_by, r.changed_by_name); } };
        var changedAtColumn = { header: S('column_changed_at'), render: function (r) { return auditText(r.changed_at); } };
        var actionColumn = { header: S('column_action'), render: function (r) { return auditText(r.action); } };
        var detailColumn = { header: S('column_detail'), render: function (r) { return auditText(r.detail); } };

        switch (catalogName) {
            case 'certTiers':
                return [actionColumn, { header: S('cert_tier_key_label'), render: function (r) { return auditText(r.tier_key); } }, detailColumn, changedByColumn, changedAtColumn];
            case 'permissionKeys':
                return [actionColumn, { header: S('permission_key_key_label'), render: function (r) { return auditText(r.permission_key); } }, detailColumn, changedByColumn, changedAtColumn];
            case 'xpTiers':
                // 'ordinal' is that rank's own position in the ladder --
                // xp_tier_error_invalid_ordinal's own vocabulary -- shown
                // via column_rank, the SAME word the Person screen already
                // uses for a handler's own current rank (person_rank_heading's
                // neighbour), never a new 'ordinal' key for the same concept.
                return [actionColumn, { header: S('column_rank'), render: function (r) { return auditText(r.ordinal); } }, detailColumn, changedByColumn, changedAtColumn];
            case 'shopItems':
                return [actionColumn, { header: S('shop_item_key_label'), render: function (r) { return auditText(r.item_key); } }, detailColumn, changedByColumn, changedAtColumn];
            case 'k9Profiles':
                // citizenid doubles as this catalog's own "what changed"
                // key (which K9/handler override) -- column_citizenid,
                // paired with its resolved name exactly like every other
                // citizenid column on this page, never a bare id.
                return [actionColumn, { header: S('column_citizenid'), render: function (r) { return auditIdWithName(r.citizenid, r.citizenid_name); } }, detailColumn, changedByColumn, changedAtColumn];
            case 'shopLocations':
                // The one catalog with NO `detail` column at all -- its own
                // K9Store.ShopLocationAudit_GetRecent instead carries the
                // real position/model/scenario/label fields directly (see
                // that accessor's own doc comment). Coordinates reuse
                // formatShopLocationCoordinates() -- the EXACT same x/y/z
                // formatter the live Shop Locations editor screen already
                // uses, so a coordinate never renders differently in the
                // audit trail than it does on the screen that sets it.
                // `heading` has no editor-table column of its own to reuse
                // (that screen never lists it in a table), hence the one
                // brand-new column_heading key.
                return [
                    actionColumn,
                    { header: S('column_coordinates'), render: function (r) { return auditText(formatShopLocationCoordinates(r)); } },
                    { header: S('column_heading'), render: function (r) { return auditText(r.heading); } },
                    { header: S('shop_location_model_label'), render: function (r) { return auditText(r.model); } },
                    { header: S('shop_location_scenario_label'), render: function (r) { return auditText(r.scenario); } },
                    { header: S('shop_location_label_label'), render: function (r) { return auditText(r.label); } },
                    changedByColumn, changedAtColumn,
                ];
            case 'runtimeOverrides':
                // The only catalog shaped as a real before/after DIFF
                // (K9Store.OverrideAudit_GetRecent's own `old_value`/
                // `new_value` pair) rather than an action + free-text
                // detail -- no `action`/`detail` columns here at all.
                return [
                    { header: S('column_override_key'), render: function (r) { return auditText(r.override_key); } },
                    { header: S('column_kind'), render: function (r) { return auditText(r.kind); } },
                    { header: S('column_old_value'), render: function (r) { return auditText(r.old_value); } },
                    { header: S('column_new_value'), render: function (r) { return auditText(r.new_value); } },
                    changedByColumn, changedAtColumn,
                ];
            case 'tabletThemes':
                // The Tablet Appearance screen's own six field labels,
                // verbatim -- this catalog's row shape IS that screen's
                // own save payload (K9Store.ThemeAudit_GetRecent mirrors
                // K9Store.Theme_Upsert's columns exactly), so reusing its
                // labels here is the same field, not merely a similar one.
                return [
                    { header: S('theme_primary_label'), render: function (r) { return auditText(r.primary_color); } },
                    { header: S('theme_accent_label'), render: function (r) { return auditText(r.accent_color); } },
                    { header: S('theme_background_label'), render: function (r) { return auditText(r.background_color); } },
                    { header: S('theme_text_label'), render: function (r) { return auditText(r.text_color); } },
                    { header: S('theme_density_label'), render: function (r) { return auditText(r.density); } },
                    { header: S('theme_header_title_label'), render: function (r) { return auditText(r.header_title); } },
                    changedByColumn, changedAtColumn,
                ];
            default:
                return [];
        }
    }

    /**
     * @param {'cert'|'partner'|'search'|'xp'|'dept'|'catalog'} mode
     * @param {Array<object>} rows
     * @param {string} [catalogName] -- REQUIRED when mode === 'catalog' (see
     *   auditColumnsForCatalog()'s own doc comment for why that one mode has
     *   no single fixed column set of its own); ignored otherwise.
     */
    function buildAuditResultTable(mode, rows, catalogName) {
        var columns = (mode === 'catalog') ? auditColumnsForCatalog(catalogName) : auditColumnsForMode(mode);
        var table = mk('table', { class: 'k9tablet-table' });
        var thead = mk('thead');
        var headRow = mk('tr');
        columns.forEach(function (c) { headRow.appendChild(mk('th', { text: c.header })); });
        thead.appendChild(headRow);
        table.appendChild(thead);

        var tbody = mk('tbody');
        rows.forEach(function (row) {
            var tr = mk('tr');
            columns.forEach(function (c) { tr.appendChild(mk('td', { text: c.render(row) })); });
            tbody.appendChild(tr);
        });
        table.appendChild(tbody);
        return table;
    }

    /**
     * Renders exactly ONE of: a loading line, an error (with NO further
     * explanation lost -- see auditErrorText()), a first-visit prompt (never
     * a blank panel before the officer has run anything), an explicit empty-
     * result note, or the results table -- per this task's own "a failed
     * callback must not leave the screen blank with no explanation"
     * requirement.
     */
    function buildAuditResults() {
        var wrap = mk('div', {});

        if (state.auditLoading) {
            wrap.appendChild(mk('p', { text: S('loading') }));
            return wrap;
        }
        if (state.auditError) {
            wrap.appendChild(mk('p', { class: 'k9tablet-error-text', text: auditErrorText(state.auditError) }));
            return wrap;
        }
        if (!state.auditResult) {
            wrap.appendChild(mk('p', { class: 'k9tablet-muted', text: S('audit_result_prompt') }));
            return wrap;
        }
        if (state.auditResult.label) {
            wrap.appendChild(mk('p', { class: 'k9tablet-muted', text: state.auditResult.label }));
        }
        // TRUNCATION NOTICE (this pass) -- "you asked for 500, here are the
        // first 100" is information the operator needs; a silently short
        // list is the bug this pass exists to fix. `truncated` comes
        // straight from the server's own tabletAudit* response (see this
        // file's header NUI CONTRACT note) -- never inferred client-side
        // from rows.length, which cannot tell "there were exactly `cap`
        // matching rows" apart from "there were more than that".
        if (state.auditResult.truncated) {
            wrap.appendChild(mk('p', { class: 'k9tablet-warning-note', text: auditTruncatedText(state.auditResult) }));
        }
        if (state.auditResult.rows.length === 0) {
            wrap.appendChild(mk('p', { class: 'k9tablet-muted', text: S('audit_result_empty') }));
            return wrap;
        }
        wrap.appendChild(buildAuditResultTable(state.auditMode, state.auditResult.rows, state.auditResult.catalogName));
        return wrap;
    }

    // ---- XP Rank Editor screen (high command only) ----
    // Owner-directed "...set experience level for each rank up" pass,
    // server/xptiers.lua -- the OTHER half of the same quote the
    // permission-key catalog screen above answers for permission keys.
    // Renders the LIVE four-rank ladder from state.xpTiers (populated by
    // loadXpTiers() below -- never hardcoded here, see that function's own
    // comment), a per-row Edit control, and (when a draft is open) the
    // single open rank's edit form below the table. There is no add/
    // remove/reorder for this ladder (server/xptiers.lua's own header
    // "SCOPE DECISION" -- fixed cardinality, four ranks, edited in place),
    // so this screen is deliberately simpler than buildCertTiersScreen()
    // above: no "Add New" button, no move-up/down, no delete.
    // server/xptiers.lua's own CanManageXPTiers is the real authorization
    // gate, re-checked on every one of the two callbacks this screen
    // calls -- see THE SECURITY RULE.

    /** Mirrors server/xptiers.lua's own MAX_SPEED_SCENT_MULTIPLIER exactly
     * -- a UX convenience only (THE SECURITY RULE): kept in exact lockstep
     * with that file's own constant so this page's own pre-check can never
     * be looser OR tighter than what the server will actually accept, but
     * the server's own re-check of the CURRENT live ladder is what
     * actually matters regardless of what this page allows through. */
    var XP_TIER_MAX_SPEED_SCENT_MULTIPLIER = 3.0;

    /** Mirrors server/xptiers.lua's own MAX_MEDKIT_COOLDOWN_MULTIPLIER
     * exactly -- same posture as XP_TIER_MAX_SPEED_SCENT_MULTIPLIER above. */
    var XP_TIER_MAX_MEDKIT_COOLDOWN_MULTIPLIER = 1.0;

    function buildXpTiersScreen() {
        var wrap = mk('div', { class: 'k9tablet-home-section' });
        wrap.appendChild(mk('h2', { class: 'k9tablet-section-heading', text: S('xp_tiers_heading') }));

        // THE ALREADY-PROMOTED PLAYER -- surfaced per the server side's own
        // explicit ask: a successful upsert's `warning` (present whenever
        // at least one currently-connected K9 was just re-ranked LOWER by
        // this exact edit -- server/xptiers.lua's own header) is
        // non-optional and must not be silently discarded -- its own
        // prominent banner, SAME treatment certTiersReorder's own warning
        // already gets above, never folded into the generic
        // (easy-to-miss-amid-other-clicks) actionNotice.
        if (state.xpTierWarning) {
            wrap.appendChild(mk('p', { class: 'k9tablet-warning-note', text: state.xpTierWarning }));
        }

        if (state.xpTiersLoading && !state.xpTiers) {
            wrap.appendChild(mk('p', { text: S('loading') }));
            return wrap;
        }
        if (state.xpTiersError && !state.xpTiers) {
            wrap.appendChild(mk('p', { class: 'k9tablet-error-text', text: xpTierErrorText(state.xpTiersError) }));
            wrap.appendChild(mkButton(S('retry_label'), 'k9tablet-btn', loadXpTiers));
            return wrap;
        }
        if (!state.xpTiers) {
            wrap.appendChild(mk('p', { text: S('loading') }));
            return wrap;
        }

        wrap.appendChild(buildXpTiersTable());

        if (state.xpTierDraft) {
            wrap.appendChild(buildXpTierDraftForm());
        }

        return wrap;
    }

    function buildXpTiersTable() {
        if (state.xpTiers.length === 0) {
            return mk('p', { class: 'k9tablet-muted', text: S('xp_tiers_empty') });
        }

        var table = mk('table', { class: 'k9tablet-table' });
        var thead = mk('thead');
        var headRow = mk('tr');
        [S('column_rank'), S('column_xp_threshold'), S('column_label'), S('column_speed_multiplier'),
            S('column_scent_range_multiplier'), S('column_medkit_cooldown_multiplier'), S('column_badge'), S('column_actions')].forEach(function (h) {
            headRow.appendChild(mk('th', { text: h }));
        });
        thead.appendChild(headRow);
        table.appendChild(thead);

        var tbody = mk('tbody');
        for (var i = 0; i < state.xpTiers.length; i++) {
            tbody.appendChild(buildXpTierRow(state.xpTiers[i]));
        }
        table.appendChild(tbody);
        return table;
    }

    /** @param {{ordinal:number,xp:number,label:string,speedMultiplier:number,scentRangeMultiplier:number,medkitCooldownMultiplier?:number,badge?:string,xpLocked:boolean}} tier */
    function buildXpTierRow(tier) {
        var tr = mk('tr');
        tr.appendChild(mk('td', { text: String(tier.ordinal) }));
        tr.appendChild(mk('td', { text: String(tier.xp) }));
        tr.appendChild(mk('td', { text: tier.label }));
        tr.appendChild(mk('td', { class: 'k9tablet-muted', text: String(tier.speedMultiplier) }));
        tr.appendChild(mk('td', { class: 'k9tablet-muted', text: String(tier.scentRangeMultiplier) }));
        tr.appendChild(mk('td', { class: 'k9tablet-muted', text: (tier.medkitCooldownMultiplier === undefined || tier.medkitCooldownMultiplier === null) ? '' : String(tier.medkitCooldownMultiplier) }));
        tr.appendChild(mk('td', { class: 'k9tablet-muted', text: (typeof tier.badge === 'string' && tier.badge.length > 0) ? tier.badge : '' }));

        var actionsTd = mk('td', { class: 'k9tablet-cert-tier-actions' });
        actionsTd.appendChild(mkButton(S('xp_tier_edit_label'), 'k9tablet-btn', function () {
            openXpTierEditDraft(tier);
        }, { disabled: state.pendingAction }));

        // An upsert REFUSAL (any of the 12 reasons server/xptiers.lua's own
        // xpTiersUpsert can return, INCLUDING a client-side pre-check
        // failure caught before the round trip -- see saveXpTierDraft()
        // below) renders INLINE on THIS specific rank's own row -- "cannot,
        // and here is why" -- same convention as certTierActionError/
        // permissionKeyActionError/shopLocationActionError above, alongside
        // the same text in the generic top-of-panel notice for visibility.
        if (state.xpTierActionError && state.xpTierActionError.ordinal === tier.ordinal) {
            actionsTd.appendChild(mk('p', { class: 'k9tablet-error-text k9tablet-cert-tier-row-error', text: state.xpTierActionError.text }));
        }

        tr.appendChild(actionsTd);
        return tr;
    }

    /** Edit form for the SINGLE open rank (state.xpTierDraft) -- see
     * openXpTierEditDraft() for how it is populated. `xp` renders GENUINELY
     * read-only (a `disabled` input, exactly matching the cert-tier form's
     * own disabled key input for an existing tier) whenever
     * `draft.xpLocked` is true (rank 1 only, server/xptiers.lua's own
     * mandatory `xp == 0` baseline) -- saveXpTierDraft() below never even
     * reads this field's own value for a locked rank, always submitting 0,
     * so there is no path through this form that could ever send an edit
     * this server will always refuse anyway. Label/multipliers/badge stay
     * fully editable regardless of xpLocked. */
    function buildXpTierDraftForm() {
        var draft = state.xpTierDraft;
        var wrap = mk('div', { class: 'k9tablet-cert-tier-form' });

        var xpRow = mk('div', { class: 'k9tablet-theme-field' + (state.xpTierFieldError === 'xp' ? ' k9tablet-theme-field--invalid' : '') });
        xpRow.appendChild(mk('label', { class: 'k9tablet-theme-field-label', text: S('xp_tier_xp_label') }));
        var xpInput = mk('input', { class: 'k9tablet-cert-tier-label-input', attrs: { type: 'number', step: '1', min: '0' } });
        xpInput.value = draft.xp;
        if (draft.xpLocked) {
            xpInput.setAttribute('disabled', 'disabled');
        } else {
            xpInput.addEventListener('input', function (e) { draft.xp = e.target.value; });
        }
        xpRow.appendChild(xpInput);
        wrap.appendChild(xpRow);
        if (draft.xpLocked) {
            wrap.appendChild(mk('p', { class: 'k9tablet-muted k9tablet-hint', text: S('xp_tier_xp_locked_hint') }));
        }

        var labelRow = mk('div', { class: 'k9tablet-theme-field' + (state.xpTierFieldError === 'label' ? ' k9tablet-theme-field--invalid' : '') });
        labelRow.appendChild(mk('label', { class: 'k9tablet-theme-field-label', text: S('xp_tier_label_label') }));
        var labelInput = mk('input', { class: 'k9tablet-cert-tier-label-input', attrs: { type: 'text', maxlength: '60' } });
        labelInput.value = draft.label;
        labelInput.addEventListener('input', function (e) { draft.label = e.target.value; });
        labelRow.appendChild(labelInput);
        wrap.appendChild(labelRow);

        var speedRow = mk('div', { class: 'k9tablet-theme-field' + (state.xpTierFieldError === 'speedMultiplier' ? ' k9tablet-theme-field--invalid' : '') });
        speedRow.appendChild(mk('label', { class: 'k9tablet-theme-field-label', text: S('xp_tier_speed_multiplier_label') }));
        var speedInput = mk('input', { class: 'k9tablet-cert-tier-label-input', attrs: { type: 'number', step: 'any', min: '0' } });
        speedInput.value = draft.speedMultiplier;
        speedInput.addEventListener('input', function (e) { draft.speedMultiplier = e.target.value; });
        speedRow.appendChild(speedInput);
        wrap.appendChild(speedRow);

        var scentRow = mk('div', { class: 'k9tablet-theme-field' + (state.xpTierFieldError === 'scentRangeMultiplier' ? ' k9tablet-theme-field--invalid' : '') });
        scentRow.appendChild(mk('label', { class: 'k9tablet-theme-field-label', text: S('xp_tier_scent_range_multiplier_label') }));
        var scentInput = mk('input', { class: 'k9tablet-cert-tier-label-input', attrs: { type: 'number', step: 'any', min: '0' } });
        scentInput.value = draft.scentRangeMultiplier;
        scentInput.addEventListener('input', function (e) { draft.scentRangeMultiplier = e.target.value; });
        scentRow.appendChild(scentInput);
        wrap.appendChild(scentRow);

        var medkitRow = mk('div', { class: 'k9tablet-theme-field' + (state.xpTierFieldError === 'medkitCooldownMultiplier' ? ' k9tablet-theme-field--invalid' : '') });
        medkitRow.appendChild(mk('label', { class: 'k9tablet-theme-field-label', text: S('xp_tier_medkit_cooldown_multiplier_label') }));
        var medkitInput = mk('input', { class: 'k9tablet-cert-tier-label-input', attrs: { type: 'number', step: 'any', min: '0', placeholder: S('xp_tier_medkit_cooldown_multiplier_placeholder') } });
        medkitInput.value = draft.medkitCooldownMultiplier;
        medkitInput.addEventListener('input', function (e) { draft.medkitCooldownMultiplier = e.target.value; });
        medkitRow.appendChild(medkitInput);
        wrap.appendChild(medkitRow);

        var badgeRow = mk('div', { class: 'k9tablet-theme-field' + (state.xpTierFieldError === 'badge' ? ' k9tablet-theme-field--invalid' : '') });
        badgeRow.appendChild(mk('label', { class: 'k9tablet-theme-field-label', text: S('xp_tier_badge_label') }));
        var badgeInput = mk('input', { class: 'k9tablet-cert-tier-label-input', attrs: { type: 'text', maxlength: '30', placeholder: S('xp_tier_badge_placeholder') } });
        badgeInput.value = draft.badge;
        badgeInput.addEventListener('input', function (e) { draft.badge = e.target.value; });
        badgeRow.appendChild(badgeInput);
        wrap.appendChild(badgeRow);

        var actions = mk('div', { class: 'k9tablet-theme-actions' });
        actions.appendChild(mkButton(S('xp_tier_save_label'), 'k9tablet-btn', saveXpTierDraft, { disabled: state.pendingAction }));
        actions.appendChild(mkButton(S('xp_tier_cancel_label'), 'k9tablet-link-btn', closeXpTierDraft));
        wrap.appendChild(actions);

        return wrap;
    }

    // ------------------------------------------------------------------
    // K9 INDIVIDUAL OVERRIDES -- server/k9profiles.lua, high command only
    // (owner-directed "god over that tablet with full customization over
    // everything related to that K9" pass). Renders the LIVE list of every
    // citizenid with a hand-tuned override (state.k9Profiles, populated by
    // loadK9ProfilesList() below), plus a single citizenid's full detail +
    // edit form (state.k9ProfileSelected/state.k9ProfileDraft) opened
    // either from that list's own "Manage" button or a freshly typed
    // citizenid in the lookup box. server/k9profiles.lua's own
    // CanManageK9Profiles is the real authorization gate, re-checked on
    // every one of the four callbacks this screen calls -- see THE
    // SECURITY RULE.
    //
    // HONESTY NOTE (verified directly against server/progression.lua's own
    // source, not assumed): GetXPTierMedkitCooldownMs and
    // BuildEffectiveTierSnapshot/PushTierSnapshot there both now consult
    // GetK9EffectiveMultipliers(citizenid), so an override saved here IS a
    // real, live change to that K9's medkit cooldown and (via the
    // 'qbx_k9unit:client:xpTierChanged' push) its speed/scent range. It
    // does NOT push an immediate refresh to an already-connected K9 on its
    // own, though -- the new value applies the next time that citizenid's
    // tier is naturally re-resolved (earning XP, reconnecting, or a
    // server restart). k9_profiles_intro/k9_profile_not_yet_live_hint
    // below state that caveat plainly; this screen must never claim a
    // stronger, more-instant effect than that.
    // ------------------------------------------------------------------

    /** NO CLIENT-SIDE CEILING FOR SPEED/SCENT (owner-directed, this pass:
     * "keep the speed... editing where i can edit it to as high as i
     * want"). server/k9profiles.lua's own MAX_SPEED_SCENT_MULTIPLIER is
     * now OWNER-EDITABLE (Config.MaxSpeedScentMultiplier, 10.0 default,
     * replacing the previous hardcoded 3.0) -- this page has no reliable
     * way to know that live configured value (no callback exposes it),
     * and even if it did, mirroring a number that can change server-side
     * without a matching client update is exactly the "quietly
     * re-imposes a limit he just asked removed" trap this pass exists to
     * close. THE SERVER REFUSES an out-of-range value -- see
     * saveK9ProfileDraft()'s own comment: this page's own pre-check for
     * speed/scent is now ONLY "is this a positive, finite number", never
     * an upper bound. A PREVIOUS PASS had this hardcoded to 3.0 (both
     * here and as the speed/scent inputs' own HTML `max` attribute) --
     * REMOVED, deliberately, do not reintroduce either form. */

    /** Mirrors server/k9profiles.lua's own MAX_MEDKIT_COOLDOWN_MULTIPLIER
     * exactly -- UNRELATED to the speed/scent ceiling removal above: this
     * multiplier can only SHORTEN the medkit cooldown below its tier
     * default, never lengthen it past 1.0 -- a real, permanent business
     * rule (a cooldown reduction "as high as i want" would mean an
     * INSTANT medkit, not a faster one), never a placeholder the owner
     * asked to have raised. Kept as a UX convenience pre-check only (THE
     * SECURITY RULE): the server's own unchanged 1.0 ceiling is what
     * actually matters. */
    var K9_PROFILE_MAX_MEDKIT_COOLDOWN_MULTIPLIER = 1.0;

    /** NO CLIENT-SIDE CEILING FOR STAMINA EITHER, as of this pass -- the
     * owner's own ask was "as high as i want OR permanent" (permanent is
     * 0, the FLOOR here, not an unbounded top). server/k9profiles.lua's
     * own MAX_STAMINA_DRAIN_PER_TICK is now OWNER-EDITABLE
     * (Config.MaxStaminaDrainPerTick, its own setting, deliberately NOT
     * reusing Config.MaxSpeedScentMultiplier -- different quantity,
     * inverted direction: bigger stamina-drain is WORSE, so that config
     * setting is a ceiling on how bad it is allowed to get, not a floor
     * on how good). Exactly the same trap as the speed/scent comment
     * above describes applies here: this page has no way to know that
     * live configured value, so a hardcoded client mirror would silently
     * re-impose a limit the server no longer enforces at that number.
     * THE SERVER REFUSES an out-of-range value (`invalid_sprint_decay_per_tick`)
     * -- this page's own pre-check for stamina is only "is this a finite
     * number >= 0" (0 stays valid at any ceiling -- it is the permanent
     * sentinel). A PREVIOUS PASS had this hardcoded to 20.0 (both here and
     * as the stamina input's own HTML `max` attribute) -- REMOVED,
     * deliberately, do not reintroduce either form. */

    /** Mirrors server/k9profiles.lua's own MAX_NOTE_LENGTH exactly. */
    var K9_PROFILE_MAX_NOTE_LENGTH = 120;

    /**
     * Clears every per-person override draft/refusal and reloads the
     * overview list.
     *
     * WAS goToK9ProfilesScreen() -- it navigated to a tab that no longer
     * exists (plan item D). The reset it performs is still needed, and for
     * the same reason it always was: state.k9ProfileSelected* is SHARED
     * between the overview list and the Person screen's own embedded
     * editor, so a citizenid opened earlier must never bleed into the next
     * thing that reads it. Called when the Console screen is entered.
     */
    function resetAndLoadK9Profiles() {
        state.k9ProfileSelectedCitizenId = null;
        state.k9ProfileSelected = null;
        state.k9ProfileSelectedError = null;
        state.k9ProfileDraft = null;
        state.k9ProfileFieldError = null;
        state.k9ProfileActionError = null;
        state.k9ProfileWarning = null;
        state.k9ProfileStaminaWarning = null;
        state.k9ProfileSpeedCeilingNote = null;
        render();
        loadK9ProfilesList();
    }

    function loadK9ProfilesList() {
        state.k9ProfilesLoading = true;
        state.k9ProfilesError = null;
        render();
        fetchNui('tablet:k9ProfilesList', {}).then(function (result) {
            state.k9ProfilesLoading = false;
            if (!result || result.ok !== true) {
                state.k9ProfilesError = result || { error: 'unknown_error' };
                render();
                return;
            }
            state.k9Profiles = Array.isArray(result.overrides) ? result.overrides : [];
            render();
        });
    }

    /** @param {object|undefined} result @returns {string} */
    function k9ProfileErrorText(result) {
        if (!result) return S('action_failed');
        if (typeof result.message === 'string' && result.message.length > 0) return result.message;
        switch (result.error) {
            case 'denied': return S('k9_profile_error_denied');
            case 'rate_limited': return S('k9_profile_error_rate_limited');
            case 'busy': return S('k9_profile_error_busy');
            case 'invalid_citizenid': return S('k9_profile_error_invalid_citizenid');
            case 'invalid_payload': return S('k9_profile_error_invalid_payload');
            case 'no_fields_to_set': return S('k9_profile_error_no_fields_to_set');
            case 'invalid_speed_multiplier': return S('k9_profile_error_invalid_speed_multiplier');
            case 'invalid_scent_range_multiplier': return S('k9_profile_error_invalid_scent_range_multiplier');
            case 'invalid_medkit_cooldown_multiplier': return S('k9_profile_error_invalid_medkit_cooldown_multiplier');
            case 'invalid_sprint_decay_per_tick': return S('k9_profile_error_invalid_stamina');
            case 'invalid_note': return S('k9_profile_error_invalid_note');
            case 'too_many_overrides': return S('k9_profile_error_too_many_overrides');
            case 'db_error': return S('k9_profile_error_db_error');
            case 'timeout': return S('error_timeout');
            case 'network_error': return S('error_network');
            default: return S('action_failed');
        }
    }

    /** @param {string} citizenid */
    function loadK9Profile(citizenid) {
        if (typeof citizenid !== 'string' || citizenid.trim().length === 0) return;
        citizenid = citizenid.trim();
        // STALE-RESPONSE GUARD identity capture -- same shape as
        // loadPersonSummary/loadPersonFeatures capturing state.person's own
        // citizenid before their fetch starts. Set HERE, synchronously,
        // before the fetch even goes out, so a later call to this SAME
        // function for a DIFFERENT citizenid (a different "Manage" row, a
        // new lookup-box submit) updates it immediately -- the .then()
        // below compares against whatever this field holds AT RESPONSE
        // TIME, not what it held when this particular request was sent.
        state.k9ProfileSelectedCitizenId = citizenid;
        state.k9ProfileSelectedLoading = true;
        state.k9ProfileSelectedError = null;
        state.k9ProfileSelected = null;
        state.k9ProfileDraft = null;
        state.k9ProfileFieldError = null;
        state.k9ProfileActionError = null;
        render();
        fetchNui('tablet:k9ProfileGet', { citizenid: citizenid }).then(function (result) {
            // STALE-RESPONSE GUARD: the lookup box or a different row's
            // "Manage" button can request a DIFFERENT citizenid while this
            // fetch is still in flight -- nothing here cancels the
            // underlying request. Without this check, an out-of-order
            // response for a citizenid the operator has since navigated
            // away from would silently overwrite whatever profile is
            // CURRENTLY on screen (wrong dog's numbers, no visible error) --
            // same class of bug loadPersonSummary/loadPersonFeatures guard
            // against for the Person screen. Discarding here leaves
            // whatever the CURRENT request already wrote (or is still
            // loading) untouched.
            if (state.k9ProfileSelectedCitizenId !== citizenid) return;

            state.k9ProfileSelectedLoading = false;
            if (!result || result.ok !== true) {
                state.k9ProfileSelectedError = result || { error: 'unknown_error' };
                render();
                return;
            }
            state.k9ProfileSelected = result;
            openK9ProfileDraft(result);
            render();
        });
    }

    /** Opens a working copy pre-filled from the citizenid's OWN STORED
     * override only (never the composed `effective` values) -- a blank
     * field here genuinely means "no override for this field, defers to
     * this K9's XP tier", matching server/k9profiles.lua's own per-field-
     * optional contract exactly. A COPY, never the live object, so
     * cancelling never mutates state.k9ProfileSelected.
     * @param {object} profile -- tablet:k9ProfileGet's own result */
    function openK9ProfileDraft(profile) {
        var override = profile.override || {};
        state.k9ProfileDraft = {
            citizenid: profile.citizenid,
            speedMultiplier: (typeof override.speedMultiplier === 'number') ? String(override.speedMultiplier) : '',
            scentRangeMultiplier: (typeof override.scentRangeMultiplier === 'number') ? String(override.scentRangeMultiplier) : '',
            medkitCooldownMultiplier: (typeof override.medkitCooldownMultiplier === 'number') ? String(override.medkitCooldownMultiplier) : '',
            // STAMINA -- pre-filled from the citizenid's OWN STORED
            // session-only override ONLY, same "blank means no override"
            // contract as every field above -- '0' here is a REAL,
            // meaningful value (permanent), never confused with blank.
            sprintDecayPerTick: (typeof override.sprintDecayPerTick === 'number') ? String(override.sprintDecayPerTick) : '',
            note: (typeof override.note === 'string') ? override.note : '',
        };
        state.k9ProfileFieldError = null;
        state.k9ProfileActionError = null;
        // DISCLOSED, NOT HIDDEN, WHEN IT MATTERS (post migration 0021,
        // commit c938c42): staminaPersistenceWarning is now CONDITIONAL,
        // not always present -- server/k9profiles.lua's own
        // ResolveStaminaPersistenceWarning() returns nil on any DB-backed
        // server (stamina is persisted there exactly like speed/scent/
        // medkit) and only returns a real warning string on a memory-only
        // one. This page never fabricates or hardcodes that wording --
        // the server owns it verbatim, and this field renders nothing at
        // all (see buildK9ProfileDetail() below) when the server omits it.
        state.k9ProfileStaminaWarning = (typeof profile.staminaPersistenceWarning === 'string' && profile.staminaPersistenceWarning.length > 0)
            ? profile.staminaPersistenceWarning : null;
        // SAME TREATMENT, SAME REASON (added 2026-08-31).
        // server/k9profiles.lua computes speedOverrideCeilingNote for one
        // stated purpose, in its own words: so an officer opening the tablet
        // to INSPECT an already-set high override "gets told the same honest
        // truth a fresh save would have told them, not just silence". No
        // renderer read the field, so silence is exactly what they got. The
        // server owns the wording verbatim; this page never fabricates it,
        // and renders nothing at all when the server omits it.
        state.k9ProfileSpeedCeilingNote = (typeof profile.speedOverrideCeilingNote === 'string' && profile.speedOverrideCeilingNote.length > 0)
            ? profile.speedOverrideCeilingNote : null;
    }

    function clearK9ProfileSelection() {
        state.k9ProfileSelected = null;
        state.k9ProfileSelectedError = null;
        state.k9ProfileDraft = null;
        state.k9ProfileFieldError = null;
        state.k9ProfileActionError = null;
        state.k9ProfileStaminaWarning = null;
        state.k9ProfileSpeedCeilingNote = null;
        render();
    }

    /** Mirrors server/k9profiles.lua's own IsValidNote exactly -- a UX
     * convenience only (THE SECURITY RULE), same "duplicated, not shared"
     * precedent isSafeShortStringForXpTier's own comment already
     * establishes for the identical situation in a different domain.
     * @param {*} value @returns {boolean} */
    function isSafeNoteForK9Profile(value) {
        if (typeof value !== 'string') return false;
        var len = value.length;
        if (len === 0 || len > K9_PROFILE_MAX_NOTE_LENGTH) return false;
        if (/[<>&"'`\r\n\t]/.test(value)) return false;
        for (var i = 0; i < len; i++) {
            var code = value.charCodeAt(i);
            if (code < 0x20 || code === 0x7F) return false;
        }
        return true;
    }

    /** @param {string} field @param {string} text */
    function failK9ProfileDraft(field, text) {
        state.k9ProfileFieldError = field;
        state.k9ProfileActionError = text;
        state.actionNotice = { kind: 'error', text: text };
        render();
    }

    /**
     * Saves the open citizenid's draft. Every numeric field's blank/typed
     * distinction mirrors server/k9profiles.lua's own per-field-optional
     * contract EXACTLY: a field left blank is OMITTED from the payload
     * (leaves whatever that citizenid's override already held for that
     * field untouched -- it is NEVER sent as "clear this"), and a typed
     * value is validated against the SAME bounds server/k9profiles.lua's
     * own IsValidMultiplier enforces before ever reaching the network --
     * a UX convenience only (THE SECURITY RULE): the server independently
     * re-validates every field against the CURRENT LIVE row before writing
     * anything, so a modified client sending an out-of-range value is
     * refused there regardless of what this function does or does not
     * catch first.
     */
    function saveK9ProfileDraft() {
        if (state.pendingAction || !state.k9ProfileDraft) return;
        var draft = state.k9ProfileDraft;
        var payload = { citizenid: draft.citizenid };
        var hasAnyField = false;

        // NO UPPER BOUND HERE -- see the "NO CLIENT-SIDE CEILING" comments
        // above (both the speed/scent one and stamina's own sibling): only
        // "is this a positive, finite number" is checked; the server
        // enforces its own owner-configured ceiling and refuses anything
        // past it with 'invalid_speed_multiplier'/'invalid_scent_range_multiplier'.
        var speedRaw = (typeof draft.speedMultiplier === 'string') ? draft.speedMultiplier.trim() : '';
        if (speedRaw.length > 0) {
            var speedNum = Number(speedRaw);
            if (!isFinite(speedNum) || speedNum <= 0) {
                failK9ProfileDraft('speedMultiplier', S('k9_profile_error_invalid_speed_multiplier'));
                return;
            }
            payload.speedMultiplier = speedNum;
            hasAnyField = true;
        }

        var scentRaw = (typeof draft.scentRangeMultiplier === 'string') ? draft.scentRangeMultiplier.trim() : '';
        if (scentRaw.length > 0) {
            var scentNum = Number(scentRaw);
            if (!isFinite(scentNum) || scentNum <= 0) {
                failK9ProfileDraft('scentRangeMultiplier', S('k9_profile_error_invalid_scent_range_multiplier'));
                return;
            }
            payload.scentRangeMultiplier = scentNum;
            hasAnyField = true;
        }

        var medkitRaw = (typeof draft.medkitCooldownMultiplier === 'string') ? draft.medkitCooldownMultiplier.trim() : '';
        if (medkitRaw.length > 0) {
            var medkitNum = Number(medkitRaw);
            if (!isFinite(medkitNum) || medkitNum <= 0 || medkitNum > K9_PROFILE_MAX_MEDKIT_COOLDOWN_MULTIPLIER) {
                failK9ProfileDraft('medkitCooldownMultiplier', S('k9_profile_error_invalid_medkit_cooldown_multiplier'));
                return;
            }
            payload.medkitCooldownMultiplier = medkitNum;
            hasAnyField = true;
        }

        // STAMINA (owner-directed, this pass: "be able to make the
        // stamina as high as i want and be able to make the stamina...
        // permanant") -- `sprintDecayPerTick`, DELIBERATELY `>= 0`, NOT
        // `> 0`: ZERO IS THE VALID "NEVER RUNS OUT" SENTINEL
        // (buildK9ProfileStaminaField()'s own permanent checkbox writes
        // '0' into this exact field -- there is no separate boolean sent
        // to the server, this IS how "permanent" is expressed on the
        // wire, matching server/k9profiles.lua's own IsValidStaminaDrain
        // contract exactly). NO UPPER BOUND HERE either, same reasoning as
        // speed/scent above -- see the "NO CLIENT-SIDE CEILING FOR STAMINA
        // EITHER" comment near this file's other K9_PROFILE_MAX_* constants;
        // the server enforces its own owner-configured
        // Config.MaxStaminaDrainPerTick ceiling and refuses anything past
        // it with 'invalid_sprint_decay_per_tick'.
        var staminaRaw = (typeof draft.sprintDecayPerTick === 'string') ? draft.sprintDecayPerTick.trim() : '';
        if (staminaRaw.length > 0) {
            var staminaNum = Number(staminaRaw);
            if (!isFinite(staminaNum) || staminaNum < 0) {
                failK9ProfileDraft('sprintDecayPerTick', S('k9_profile_error_invalid_stamina'));
                return;
            }
            payload.sprintDecayPerTick = staminaNum;
            hasAnyField = true;
        }

        var noteRaw = (typeof draft.note === 'string') ? draft.note.trim() : '';
        if (noteRaw.length > 0) {
            if (!isSafeNoteForK9Profile(noteRaw)) {
                failK9ProfileDraft('note', S('k9_profile_error_invalid_note'));
                return;
            }
            payload.note = noteRaw;
            hasAnyField = true;
        }

        if (!hasAnyField) {
            failK9ProfileDraft(null, S('k9_profile_error_no_fields_to_set'));
            return;
        }

        state.pendingAction = true;
        state.k9ProfileFieldError = null;
        state.k9ProfileActionError = null;
        state.actionNotice = { kind: 'ok', text: S('action_working') };
        render();

        fetchNui('tablet:k9ProfileUpsert', payload).then(function (result) {
            state.pendingAction = false;
            if (result && result.ok === true) {
                state.k9ProfileSelected = result;
                openK9ProfileDraft(result);
                state.k9ProfileWarning = (typeof result.warning === 'string' && result.warning.length > 0) ? result.warning : null;
                state.actionNotice = { kind: 'ok', text: S('action_succeeded') };
                loadK9ProfilesList();
            } else {
                var text = k9ProfileErrorText(result);
                var field = null;
                switch (result && result.error) {
                    case 'invalid_speed_multiplier': field = 'speedMultiplier'; break;
                    case 'invalid_scent_range_multiplier': field = 'scentRangeMultiplier'; break;
                    case 'invalid_medkit_cooldown_multiplier': field = 'medkitCooldownMultiplier'; break;
                    case 'invalid_sprint_decay_per_tick': field = 'sprintDecayPerTick'; break;
                    case 'invalid_note': field = 'note'; break;
                }
                state.k9ProfileFieldError = field;
                state.k9ProfileActionError = text;
                state.actionNotice = { kind: 'error', text: text };
            }
            render();
        });
    }

    /** Clears EVERY override field for the open citizenid in one action --
     * there is no per-field reset, only whole-row (see
     * server/k9profiles.lua's own k9ProfileReset). Confirmed via
     * mkConfirmButton, same "two clicks, not window.confirm()" posture as
     * every other destructive action on this page. */
    function resetK9Profile() {
        if (state.pendingAction || !state.k9ProfileDraft) return;
        var citizenid = state.k9ProfileDraft.citizenid;
        state.pendingAction = true;
        state.k9ProfileActionError = null;
        state.actionNotice = { kind: 'ok', text: S('action_working') };
        render();

        fetchNui('tablet:k9ProfileReset', { citizenid: citizenid }).then(function (result) {
            state.pendingAction = false;
            if (result && result.ok === true) {
                loadK9Profile(citizenid);
                state.actionNotice = { kind: 'ok', text: S('action_succeeded') };
                loadK9ProfilesList();
            } else {
                var text = k9ProfileErrorText(result);
                state.k9ProfileActionError = text;
                state.actionNotice = { kind: 'error', text: text };
            }
            render();
        });
    }

    /**
     * WHO CURRENTLY HOLDS A PER-DOG OVERRIDE -- a section on the Command
     * Console, not a tab of its own any more (plan item D).
     *
     * The K9 Overrides tab contributed three things, and two of them were
     * already somewhere else. Its EDITOR is buildK9ProfileDetail(), which
     * the Person screen has rendered all along through
     * buildPersonK9ProfileSection(). Its LOOKUP BOX was one of the several
     * person-finding inputs this pass is collapsing, and it reached exactly
     * the same Person screen the Console's own box reaches. Only the LIST
     * was unique -- "who has an override at all", which nothing else
     * answers -- so the list is what survives, and it moved here beside the
     * roster and the online-players list, where this page's other "who has
     * what" answers already live.
     *
     * Each row's Manage button now opens the PERSON rather than an inline
     * detail panel, so editing an override happens in the same place as
     * everything else about that person: certifications, capabilities,
     * abilities, roster role, partnership history.
     * @returns {Element}
     */
    function buildK9ProfilesOverviewSection() {
        var wrap = mk('div', { class: 'k9tablet-home-section' });
        wrap.appendChild(mk('h3', { class: 'k9tablet-section-heading', text: S('k9_profiles_list_heading') }));
        wrap.appendChild(mk('p', { class: 'k9tablet-muted', text: S('k9_profiles_intro') }));

        if (state.k9ProfileWarning) {
            wrap.appendChild(mk('p', { class: 'k9tablet-warning-note', text: state.k9ProfileWarning }));
        }

        if (state.k9ProfilesLoading && !state.k9Profiles) {
            wrap.appendChild(mk('p', { text: S('loading') }));
            return wrap;
        }
        if (state.k9ProfilesError && !state.k9Profiles) {
            wrap.appendChild(mk('p', { class: 'k9tablet-error-text', text: k9ProfileErrorText(state.k9ProfilesError) }));
            wrap.appendChild(mkButton(S('retry_label'), 'k9tablet-btn', loadK9ProfilesList));
            return wrap;
        }
        if (!state.k9Profiles) {
            wrap.appendChild(mk('p', { text: S('loading') }));
            return wrap;
        }

        wrap.appendChild(buildK9ProfilesTable());
        return wrap;
    }

    function buildK9ProfilesTable() {
        if (state.k9Profiles.length === 0) {
            return mk('p', { class: 'k9tablet-muted', text: S('k9_profiles_empty') });
        }

        var table = mk('table', { class: 'k9tablet-table' });
        var thead = mk('thead');
        var headRow = mk('tr');
        [S('column_citizenid'), S('column_speed_multiplier'), S('column_scent_range_multiplier'),
            S('column_medkit_cooldown_multiplier'), S('column_stamina_drain'), S('column_note'), S('column_actions')].forEach(function (h) {
            headRow.appendChild(mk('th', { text: h }));
        });
        thead.appendChild(headRow);
        table.appendChild(thead);

        var tbody = mk('tbody');
        for (var i = 0; i < state.k9Profiles.length; i++) {
            tbody.appendChild(buildK9ProfileRow(state.k9Profiles[i]));
        }
        table.appendChild(tbody);
        return table;
    }

    /**
     * STAMINA IS A DRAIN RATE, NOT A RAW NUMBER A VIEWER SHOULD HAVE TO
     * INTERPRET (owner-directed honesty requirement: a bigger number
     * drains stamina FASTER, the opposite of what "stamina: 8" would
     * suggest to anyone reading it as a stat). This is the ONE place that
     * turns `sprintDecayPerTick` into plain language, reused by both the
     * list table and the detail panel so the two can never disagree.
     * `undefined`/`null` means "no override" (defers to the K9's tier/
     * global default) -- distinct from `0`, the real, valid "never runs
     * out" sentinel.
     * @param {number|null|undefined} value
     * @returns {string}
     */
    function k9ProfileStaminaDisplayText(value) {
        if (typeof value !== 'number') return S('k9_profile_field_not_overridden');
        if (value === 0) return S('k9_profile_stamina_permanent_label');
        return formatTemplate(S('k9_profile_stamina_drain_rate_template'), { rate: String(value) });
    }

    /** @param {{citizenid:string,speedMultiplier?:number,scentRangeMultiplier?:number,medkitCooldownMultiplier?:number,sprintDecayPerTick?:number,note?:string}} row */
    function buildK9ProfileRow(row) {
        var tr = mk('tr');
        tr.appendChild(mk('td', { text: row.citizenid }));
        tr.appendChild(mk('td', { class: 'k9tablet-muted', text: (typeof row.speedMultiplier === 'number') ? String(row.speedMultiplier) : S('k9_profile_field_not_overridden') }));
        tr.appendChild(mk('td', { class: 'k9tablet-muted', text: (typeof row.scentRangeMultiplier === 'number') ? String(row.scentRangeMultiplier) : S('k9_profile_field_not_overridden') }));
        tr.appendChild(mk('td', { class: 'k9tablet-muted', text: (typeof row.medkitCooldownMultiplier === 'number') ? String(row.medkitCooldownMultiplier) : S('k9_profile_field_not_overridden') }));
        // PERSISTENCE STATUS IS NO LONGER IMPLIED BY "THIS FIELD IS SET"
        // (post migration 0021, commit c938c42): stamina now lives in the
        // same persisted `k9_individual_overrides` row as speed/scent/
        // medkit on any DB-backed server, and is only ever session-only on
        // a memory-only one. There is no reliable per-row signal for that
        // here (the list endpoint doesn't carry staminaPersistenceWarning
        // per-row), so this list simply shows the value -- the
        // authoritative, server-worded persistence warning is surfaced
        // once the operator opens a specific citizenid's detail panel
        // (see state.k9ProfileStaminaWarning below), never guessed here.
        tr.appendChild(mk('td', { class: 'k9tablet-muted', text: k9ProfileStaminaDisplayText(row.sprintDecayPerTick) }));
        tr.appendChild(mk('td', { class: 'k9tablet-muted', text: (typeof row.note === 'string' && row.note.length > 0) ? row.note : '' }));
        var actionsTd = mk('td');
        actionsTd.appendChild(mkButton(S('k9_profile_manage_label'), 'k9tablet-btn', function () {
            // OPENS THE PERSON (plan item D), not an inline detail panel.
            // The editor lives on the Person screen and always has
            // (buildPersonK9ProfileSection); opening it there puts this
            // person's override beside everything else about them instead
            // of in a second, parallel place.
            openPerson(row.citizenid, null);
        }, { disabled: state.pendingAction }));
        tr.appendChild(actionsTd);
        return tr;
    }

    /** Detail + edit panel for the ONE currently-open citizenid
     * (state.k9ProfileSelected/state.k9ProfileDraft). Every field states,
     * per this pass's own "make every customization screen legible"
     * requirement: a plain-English name, one sentence on what it actually
     * changes in the game, its allowed range, and its default -- never a
     * bare key with a number box. */
    /**
     * STAMINA (`sprintDecayPerTick`) -- owner-directed, this pass: "be
     * able to make the stamina as high as i want and be able to make the
     * stamina as high as i want or permanant". A REAL AFFORDANCE for
     * "permanent", not a magic number the owner has to remember: a
     * checkbox that writes/clears '0' in `draft.sprintDecayPerTick`
     * itself -- there is no separate boolean sent to the server (0 IS the
     * wire value for "never runs out", matching
     * server/k9profiles.lua's own IsValidStaminaDrain contract exactly),
     * so checking/unchecking this box can never drift out of sync with
     * what actually gets saved. The numeric input is disabled (not
     * hidden) while checked, so the '0' it represents stays visible
     * rather than disappearing into an unlabelled toggle.
     * HONESTY REQUIREMENT: labelled "Stamina Drain Rate", never bare
     * "Stamina" -- a bigger number here drains stamina FASTER, the
     * opposite of what an ordinary stat reads as.
     * PERSISTENCE (post migration 0021, commit c938c42): stamina is now
     * written/read/tombstoned exactly like speed/scent/medkit on any
     * DB-backed server -- NOT unconditionally session-only any more. This
     * field never hardcodes a persistence claim; state.k9ProfileStaminaWarning
     * (set from the server's own conditional `staminaPersistenceWarning`,
     * present only on a memory-only server) is rendered separately, once,
     * in buildK9ProfileDetail() below -- see that field's own comment.
     * @param {object} draft
     * @returns {HTMLElement}
     */
    function buildK9ProfileStaminaField(draft) {
        var row = mk('div', { class: 'k9tablet-theme-field' + (state.k9ProfileFieldError === 'sprintDecayPerTick' ? ' k9tablet-theme-field--invalid' : '') });
        row.appendChild(mk('label', { class: 'k9tablet-theme-field-label', text: S('k9_profile_stamina_label') }));
        row.appendChild(mk('p', { class: 'k9tablet-hint', text: S('k9_profile_stamina_hint') }));

        var isPermanent = draft.sprintDecayPerTick === '0';

        var permanentRow = mk('label', { class: 'k9tablet-checkbox-row' });
        var permanentCheckbox = mk('input', { attrs: { type: 'checkbox' } });
        permanentCheckbox.checked = isPermanent;
        permanentCheckbox.addEventListener('change', function (e) {
            draft.sprintDecayPerTick = e.target.checked ? '0' : '';
            render();
        });
        permanentRow.appendChild(permanentCheckbox);
        permanentRow.appendChild(mk('span', { text: ' ' + S('k9_profile_stamina_permanent_checkbox_label') }));
        row.appendChild(permanentRow);

        // NO `max` ATTRIBUTE -- see this file's own "NO CLIENT-SIDE
        // CEILING FOR STAMINA EITHER" comment above (near the other
        // K9_PROFILE_MAX_* constants): the server's own ceiling is now
        // owner-editable (Config.MaxStaminaDrainPerTick) and unknown to
        // this page, so only `min: '0'` (the real, permanent floor) is
        // enforced here; the server refuses anything past its own ceiling.
        var staminaInput = mk('input', {
            class: 'k9tablet-cert-tier-label-input',
            attrs: {
                type: 'number', step: 'any', min: '0',
                placeholder: S('k9_profile_blank_means_no_override_placeholder'),
            },
        });
        staminaInput.value = isPermanent ? '0' : draft.sprintDecayPerTick;
        staminaInput.disabled = isPermanent;
        staminaInput.addEventListener('input', function (e) { draft.sprintDecayPerTick = e.target.value; });
        row.appendChild(staminaInput);

        return row;
    }

    /**
     * K9 INDIVIDUAL OVERRIDE, ON THE PERSON SCREEN (owner-directed, this
     * pass: "Keep the speed and stamina editing where i can edit it..."
     * -- coordinator's own instruction: "one place that acts on a
     * citizenid, extended, never forked"). Reuses the EXACT SAME
     * loadK9Profile()/state.k9ProfileDraft/saveK9ProfileDraft()/
     * resetK9Profile()/buildK9ProfileDetail() the standalone "K9
     * Overrides" tab already uses -- there is only ONE K9-profile-editing
     * implementation in this file, now reachable from a SECOND entry
     * point, never a second copy that could drift from the first.
     * Auto-loaded by openPerson() (see that function's own
     * opportunistic-load block) exactly like loadPersonFeatures/
     * loadPermissionKeys/loadCertTiers already are for a high-command
     * viewer -- this function itself never triggers a fetch (render
     * functions in this file never do), only a Retry button does, same
     * posture as every other screen's own error state.
     * @returns {HTMLElement}
     */
    function buildPersonK9ProfileSection() {
        var wrap = mk('div', { class: 'k9tablet-k9-profile-section' });
        var citizenid = state.person.citizenid;

        // STALE-CITIZENID GUARD -- same class of bug loadPersonSummary/
        // loadPersonFeatures/loadK9Profile itself already guard against:
        // state.k9ProfileSelected*/Draft is SHARED with the standalone K9
        // Overrides tab, so a citizenid looked up there earlier (or a
        // still-in-flight fetch for a DIFFERENT person this screen was
        // just opened for) must never be shown here as if it belonged to
        // the person currently on screen.
        if (state.k9ProfileSelectedCitizenId !== citizenid) {
            wrap.appendChild(mk('p', { text: S('loading') }));
            return wrap;
        }
        if (state.k9ProfileSelectedLoading) {
            wrap.appendChild(mk('p', { text: S('loading') }));
            return wrap;
        }
        if (state.k9ProfileSelectedError) {
            wrap.appendChild(mk('p', { class: 'k9tablet-error-text', text: k9ProfileErrorText(state.k9ProfileSelectedError) }));
            wrap.appendChild(mkButton(S('retry_label'), 'k9tablet-btn', function () { loadK9Profile(citizenid); }));
            return wrap;
        }
        if (!state.k9ProfileSelected || !state.k9ProfileDraft) {
            wrap.appendChild(mk('p', { text: S('loading') }));
            return wrap;
        }

        wrap.appendChild(buildK9ProfileDetail(true));
        return wrap;
    }

    /**
     * @param {boolean} [embedded] -- true when rendered INSIDE
     * buildPersonScreen() (buildPersonK9ProfileSection() below) rather
     * than the standalone K9 Overrides tab: suppresses the citizenid
     * heading (the Person screen already shows name+citizenid at the top
     * of the page) and the "Close" button (there is nothing to close
     * back to in this context -- see buildPersonK9ProfileSection()'s own
     * header for why a bare `clearK9ProfileSelection()` there would leave
     * the section stuck rather than genuinely closed).
     */
    function buildK9ProfileDetail(embedded) {
        var profile = state.k9ProfileSelected;
        var draft = state.k9ProfileDraft;
        var wrap = mk('div', { class: 'k9tablet-cert-tier-form' });

        if (!embedded) {
            wrap.appendChild(mk('h3', { class: 'k9tablet-section-heading', text: profile.citizenid }));
        }
        if (typeof profile.tierLabel === 'string' && profile.tierLabel.length > 0) {
            wrap.appendChild(mk('p', { class: 'k9tablet-muted', text: S('k9_profile_tier_label_prefix') + profile.tierLabel }));
        }

        var effective = profile.effective || {};
        var overridden = effective.overridden || {};
        wrap.appendChild(mk('p', { class: 'k9tablet-muted', text: S('k9_profile_effective_speed_prefix') + String(effective.speedMultiplier) + (overridden.speedMultiplier ? S('k9_profile_overridden_suffix') : S('k9_profile_from_tier_suffix')) }));
        wrap.appendChild(mk('p', { class: 'k9tablet-muted', text: S('k9_profile_effective_scent_prefix') + String(effective.scentRangeMultiplier) + (overridden.scentRangeMultiplier ? S('k9_profile_overridden_suffix') : S('k9_profile_from_tier_suffix')) }));
        wrap.appendChild(mk('p', { class: 'k9tablet-muted', text: S('k9_profile_effective_medkit_prefix') + ((typeof effective.medkitCooldownMultiplier === 'number') ? String(effective.medkitCooldownMultiplier) : S('k9_profile_field_not_overridden')) + (overridden.medkitCooldownMultiplier ? S('k9_profile_overridden_suffix') : S('k9_profile_from_tier_suffix')) }));
        wrap.appendChild(mk('p', { class: 'k9tablet-muted', text: S('k9_profile_effective_stamina_prefix') + k9ProfileStaminaDisplayText(effective.sprintDecayPerTick) + (overridden.sprintDecayPerTick ? S('k9_profile_overridden_suffix') : S('k9_profile_from_tier_suffix')) }));

        wrap.appendChild(mk('p', { class: 'k9tablet-hint', text: S('k9_profile_not_yet_live_hint') }));

        if (state.k9ProfileSpeedCeilingNote) {
            wrap.appendChild(mk('p', { class: 'k9tablet-warning-note', text: state.k9ProfileSpeedCeilingNote }));
        }
        if (state.k9ProfileStaminaWarning) {
            wrap.appendChild(mk('p', { class: 'k9tablet-warning-note', text: state.k9ProfileStaminaWarning }));
        }

        // Speed. NO `max` ATTRIBUTE (owner-directed, this pass -- "as high
        // as i want"): server/k9profiles.lua's own MAX_SPEED_SCENT_MULTIPLIER
        // is now owner-editable server-side; a hardcoded HTML ceiling here
        // would silently reintroduce the exact 3.0 cap he asked removed.
        var speedRow = mk('div', { class: 'k9tablet-theme-field' + (state.k9ProfileFieldError === 'speedMultiplier' ? ' k9tablet-theme-field--invalid' : '') });
        speedRow.appendChild(mk('label', { class: 'k9tablet-theme-field-label', text: S('k9_profile_speed_multiplier_label') }));
        speedRow.appendChild(mk('p', { class: 'k9tablet-hint', text: S('k9_profile_speed_multiplier_hint') }));
        // HONESTY REQUIREMENT (owner-directed): a real finding against
        // client/movement.lua -- the FINAL composed move rate is clamped to
        // [0.1, 2.0] there regardless of what this override says, so an
        // override above ~2x is genuinely accepted and saved but produces
        // no VISIBLE further speed increase in-game. Never silently
        // capped here (the value is still real, still saved, and may
        // matter again if that clamp is ever changed) -- just disclosed.
        speedRow.appendChild(mk('p', { class: 'k9tablet-hint', text: S('k9_profile_speed_clamp_note') }));
        var speedInput = mk('input', { class: 'k9tablet-cert-tier-label-input', attrs: { type: 'number', step: 'any', min: '0', placeholder: S('k9_profile_blank_means_no_override_placeholder') } });
        speedInput.value = draft.speedMultiplier;
        speedInput.addEventListener('input', function (e) { draft.speedMultiplier = e.target.value; });
        speedRow.appendChild(speedInput);
        wrap.appendChild(speedRow);

        // Scent. Same "no max attribute" reasoning as Speed above.
        var scentRow = mk('div', { class: 'k9tablet-theme-field' + (state.k9ProfileFieldError === 'scentRangeMultiplier' ? ' k9tablet-theme-field--invalid' : '') });
        scentRow.appendChild(mk('label', { class: 'k9tablet-theme-field-label', text: S('k9_profile_scent_range_multiplier_label') }));
        scentRow.appendChild(mk('p', { class: 'k9tablet-hint', text: S('k9_profile_scent_range_multiplier_hint') }));
        var scentInput = mk('input', { class: 'k9tablet-cert-tier-label-input', attrs: { type: 'number', step: 'any', min: '0', placeholder: S('k9_profile_blank_means_no_override_placeholder') } });
        scentInput.value = draft.scentRangeMultiplier;
        scentInput.addEventListener('input', function (e) { draft.scentRangeMultiplier = e.target.value; });
        scentRow.appendChild(scentInput);
        wrap.appendChild(scentRow);

        // Medkit cooldown -- UNRELATED to the speed/scent ceiling removal
        // above, see K9_PROFILE_MAX_MEDKIT_COOLDOWN_MULTIPLIER's own
        // comment for why this one keeps its real 1.0 ceiling.
        var medkitRow = mk('div', { class: 'k9tablet-theme-field' + (state.k9ProfileFieldError === 'medkitCooldownMultiplier' ? ' k9tablet-theme-field--invalid' : '') });
        medkitRow.appendChild(mk('label', { class: 'k9tablet-theme-field-label', text: S('k9_profile_medkit_cooldown_multiplier_label') }));
        medkitRow.appendChild(mk('p', { class: 'k9tablet-hint', text: S('k9_profile_medkit_cooldown_multiplier_hint') }));
        var medkitInput = mk('input', { class: 'k9tablet-cert-tier-label-input', attrs: { type: 'number', step: 'any', min: '0', max: '1', placeholder: S('k9_profile_blank_means_no_override_placeholder') } });
        medkitInput.value = draft.medkitCooldownMultiplier;
        medkitInput.addEventListener('input', function (e) { draft.medkitCooldownMultiplier = e.target.value; });
        medkitRow.appendChild(medkitInput);
        wrap.appendChild(medkitRow);

        wrap.appendChild(buildK9ProfileStaminaField(draft));

        // Note
        var noteRow = mk('div', { class: 'k9tablet-theme-field' + (state.k9ProfileFieldError === 'note' ? ' k9tablet-theme-field--invalid' : '') });
        noteRow.appendChild(mk('label', { class: 'k9tablet-theme-field-label', text: S('k9_profile_note_label') }));
        noteRow.appendChild(mk('p', { class: 'k9tablet-hint', text: S('k9_profile_note_hint') }));
        var noteInput = mk('input', { class: 'k9tablet-cert-tier-label-input', attrs: { type: 'text', maxlength: String(K9_PROFILE_MAX_NOTE_LENGTH), placeholder: S('k9_profile_blank_means_no_override_placeholder') } });
        noteInput.value = draft.note;
        noteInput.addEventListener('input', function (e) { draft.note = e.target.value; });
        noteRow.appendChild(noteInput);
        wrap.appendChild(noteRow);

        wrap.appendChild(mk('p', { class: 'k9tablet-hint', text: S('k9_profile_field_clear_hint') }));

        if (state.k9ProfileActionError) {
            wrap.appendChild(mk('p', { class: 'k9tablet-error-text', text: state.k9ProfileActionError }));
        }

        var actions = mk('div', { class: 'k9tablet-theme-actions' });
        actions.appendChild(mkButton(S('k9_profile_save_label'), 'k9tablet-btn', saveK9ProfileDraft, { disabled: state.pendingAction }));
        var hasLiveOverride = !!(profile.override && (typeof profile.override.speedMultiplier === 'number' || typeof profile.override.scentRangeMultiplier === 'number' || typeof profile.override.medkitCooldownMultiplier === 'number' || typeof profile.override.sprintDecayPerTick === 'number' || (typeof profile.override.note === 'string' && profile.override.note.length > 0)));
        if (hasLiveOverride) {
            actions.appendChild(mkConfirmButton(S('k9_profile_reset_label'), 'k9tablet-btn k9tablet-btn--danger', resetK9Profile, { disabled: state.pendingAction }));
        }
        if (!embedded) {
            actions.appendChild(mkButton(S('k9_profile_close_label'), 'k9tablet-link-btn', clearK9ProfileSelection));
        }
        wrap.appendChild(actions);

        return wrap;
    }

    // ------------------------------------------------------------------
    // SERVER SETTINGS -- one tab, one section picker (the owner's rework
    // pass). Every whole-server setting this tablet can change lives here:
    // the at-a-glance Overview, features and their numbers (Runtime
    // Control), the three catalogs, the supply shop and the tablet theme.
    //
    // It replaced five tabs, one of which -- Server Tuning -- was a guided
    // Back/Next pass over three of the others. The picker makes every
    // section one click away instead, so the sequenced pass had nothing
    // left to add; its one unique part, the Overview, is the last section
    // (Summary).
    //
    // Each section is the SAME screen, with the SAME gate, it had as a
    // tab: `visible` below is exactly the predicate buildTabs() and
    // buildBackdrop() used for it. No section adds a callback or an
    // authorization path (THE SECURITY RULE).
    //
    // ORDER IS THE LANDING CHOICE: the tab opens the first section this
    // viewer may see (or the one they last had open), so the most common
    // job -- switching a feature or changing its number -- comes first,
    // and the read-only Summary comes last rather than costing every
    // visit an extra click.
    // ------------------------------------------------------------------

    var SETTINGS_SECTIONS = [
        { screen: 'runtime_control', labelKey: 'tab_runtime_control', visible: function () { return canManageRuntimeControl(); }, go: function () { goToRuntimeControlScreen(); } },
        { screen: 'catalogs', labelKey: 'tab_catalogs', visible: function () { return !!(state.viewer && state.viewer.isHighCommand); }, go: function () { goToCatalogsScreen(); } },
        { screen: 'shop', labelKey: 'tab_shop', visible: function () { return canManageShopLocations() || canManageShopItems(); }, go: function () { goToShopScreen(); } },
        { screen: 'theme', labelKey: 'tab_theme', visible: function () { return canManageTabletTheme(); }, go: function () { goToThemeScreen(); } },
        { screen: 'settings_overview', labelKey: 'settings_section_overview', visible: function () { return !!(state.viewer && state.viewer.isHighCommand); }, go: function () { goToSettingsOverview(); } },
    ];

    /** @returns {Array} the sections this viewer may open, in order. */
    function visibleSettingsSections() {
        if (!state.viewer) return [];
        var out = [];
        for (var i = 0; i < SETTINGS_SECTIONS.length; i++) {
            if (SETTINGS_SECTIONS[i].visible()) out.push(SETTINGS_SECTIONS[i]);
        }
        return out;
    }

    /** @param {string} screen @returns {boolean} */
    function isSettingsScreen(screen) {
        for (var i = 0; i < SETTINGS_SECTIONS.length; i++) {
            if (SETTINGS_SECTIONS[i].screen === screen) return true;
        }
        return false;
    }

    /** @param {string} screen @returns {boolean} */
    function settingsSectionAllowed(screen) {
        if (!state.viewer) return false;
        for (var i = 0; i < SETTINGS_SECTIONS.length; i++) {
            if (SETTINGS_SECTIONS[i].screen === screen) return SETTINGS_SECTIONS[i].visible();
        }
        return false;
    }

    /** The tab: back to the section last open, or the first one this
     * viewer may see. */
    function goToServerSettings() {
        var sections = visibleSettingsSections();
        if (sections.length === 0) return;
        for (var i = 0; i < sections.length; i++) {
            if (sections[i].screen === state.lastSettingsScreen) {
                sections[i].go();
                return;
            }
        }
        sections[0].go();
    }

    /** The row of section buttons at the top of every settings screen --
     * the same nested-tab look buildAuditModeSwitch() uses. */
    function buildSettingsSectionNav() {
        var nav = mk('div', { class: 'k9tablet-tabs k9tablet-settings-sections', attrs: { role: 'group', 'aria-label': S('tab_settings') } });
        var sections = visibleSettingsSections();
        for (var i = 0; i < sections.length; i++) {
            (function (section) {
                var cls = 'k9tablet-tab' + (section.screen === state.screen ? ' k9tablet-tab--active' : '');
                nav.appendChild(mkButton(S(section.labelKey), cls, section.go));
            }(sections[i]));
        }
        return nav;
    }

    // Each go-to below is what that section's tab used to do on click:
    // switch screen, clear the screen's own leftover drafts/refusals, and
    // load only what this viewer will be shown.

    function goToSettingsOverview() {
        state.screen = 'settings_overview';
        state.lastSettingsScreen = state.screen;
        render();
        loadRuntimeFeatures();
        loadRuntimeTunables();
        loadCertTiers();
        loadXpTiers();
        loadEquipmentShopItems();
    }

    function goToRuntimeControlScreen() {
        state.screen = 'runtime_control';
        state.lastSettingsScreen = state.screen;
        state.runtimeFeatureActionError = null;
        state.runtimeLockoutConfirm = null;
        state.runtimeTunableDraft = null;
        state.runtimeTunableFieldError = null;
        render();
        loadRuntimeFeatures();
        loadRuntimeTunables();
    }

    // CATALOGS -- three sections (Certification Tiers, Permission Keys, XP
    // Ranks), two of which also answer to a feature flag; those checks stay
    // per-section inside buildCatalogsScreen(), and only the catalogs this
    // viewer will be shown are fetched.
    function goToCatalogsScreen() {
        state.screen = 'catalogs';
        state.lastSettingsScreen = state.screen;
        state.certTierDraft = null;
        state.certTierFieldError = null;
        state.certTierActionError = null;
        state.certTierWarning = null;
        state.permissionKeyDraft = null;
        state.permissionKeyFieldError = null;
        state.permissionKeyActionError = null;
        state.xpTierDraft = null;
        state.xpTierFieldError = null;
        state.xpTierActionError = null;
        state.xpTierWarning = null;
        state.roleDraft = null;
        state.roleFieldError = null;
        render();
        loadRoles();
        if (surfaceEnabled('permission_keys')) loadPermissionKeys();
        if (surfaceEnabled('xp_tiers')) loadXpTiers();
    }

    // K9 SUPPLY SHOP -- two sections behind two separately-delegable keys
    // (CanManageShopLocations / CanManageShopItems), each still gated on
    // its own inside buildShopScreen(). loadCertTiers() rides along for the
    // Items section's "Required Tier" picker.
    function goToShopScreen() {
        state.screen = 'shop';
        state.lastSettingsScreen = state.screen;
        state.shopLocationDraft = null;
        state.shopLocationActionError = null;
        state.shopItemDraft = null;
        state.shopItemFieldError = null;
        state.shopItemActionError = null;
        render();
        if (canManageShopLocations()) loadShopLocations();
        if (canManageShopItems()) {
            loadEquipmentShopItems();
            loadCertTiers();
        }
    }

    function goToThemeScreen() {
        state.screen = 'theme';
        state.lastSettingsScreen = state.screen;
        render();
        loadTheme();
    }

    /** @param {Array|null} list @param {string} templateKey @returns {HTMLElement} one line reporting `{overridden} of {total}`, or the honest "not loaded yet" line when `list` is still null. */
    function buildSettingsOverriddenLine(list, templateKey) {
        if (!Array.isArray(list)) {
            return mk('p', { class: 'k9tablet-muted', text: S('settings_overview_not_loaded') });
        }
        var overridden = 0;
        for (var i = 0; i < list.length; i++) {
            if (list[i] && list[i].overridden) overridden++;
        }
        return mk('p', { text: formatTemplate(S(templateKey), { overridden: overridden, total: list.length }) });
    }

    /** @param {Array|null} list @param {string} templateKey @returns {HTMLElement} one line reporting `{count}` configured, or the honest "not loaded yet" line when `list` is still null. */
    function buildSettingsCountLine(list, templateKey) {
        if (!Array.isArray(list)) {
            return mk('p', { class: 'k9tablet-muted', text: S('settings_overview_not_loaded') });
        }
        return mk('p', { text: formatTemplate(S(templateKey), { count: list.length }) });
    }

    /** OVERVIEW -- REAL, server-confirmed counts, read from the
     * `overridden` field every runtime feature/tunable already carries,
     * never from a client-side change log. */
    function buildSettingsOverviewScreen() {
        var wrap = mk('div', { class: 'k9tablet-screen' });
        wrap.appendChild(mk('h3', { class: 'k9tablet-section-heading', text: S('settings_overview_heading') }));
        wrap.appendChild(mk('p', { class: 'k9tablet-muted', text: S('settings_overview_intro') }));

        wrap.appendChild(buildSettingsOverriddenLine(state.runtimeFeatures, 'settings_overview_features_template'));
        wrap.appendChild(buildSettingsOverriddenLine(state.runtimeTunables, 'settings_overview_tunables_template'));
        wrap.appendChild(buildSettingsCountLine(state.certTiers, 'settings_overview_tiers_template'));
        wrap.appendChild(buildSettingsCountLine(state.xpTiers, 'settings_overview_xp_template'));
        wrap.appendChild(buildSettingsCountLine(state.shopItems, 'settings_overview_shop_template'));
        return wrap;
    }

    // ------------------------------------------------------------------
    // DATA LOADERS
    // ------------------------------------------------------------------

    function loadMyRecord() {
        state.myRecordLoading = true;
        state.myRecordError = null;
        render();

        fetchNui('tablet:requestMyRecord', {}).then(function (result) {
            state.myRecordLoading = false;
            if (!result || result.ok !== true) {
                state.myRecordError = result || { error: 'unknown_error' };
                render();
                return;
            }
            state.viewer = result.viewer || null;
            applyRoleCatalog(result.roleCatalog);
            state.myRecord = {
                certifications: result.certifications || [],
                roleXp: typeof result.roleXp === 'number' ? result.roleXp : null,
                xp: typeof result.xp === 'number' ? result.xp : null,
                tierLabel: typeof result.tierLabel === 'string' ? result.tierLabel : null,
                // HANDLER LADDER + BOTH LADDER SHAPES (owner-directed
                // progression pass). Normalised the SAME way as the K9 pair
                // directly above -- a wrong-typed value becomes null, never
                // a rendered "undefined".
                //
                // `typeof === 'number'` is load-bearing here, not
                // defensive habit: `result.handlerXp || null` would turn a
                // genuine 0 into null, and 0-versus-null is exactly the
                // distinction this whole screen rests on (0 means "on this
                // ladder, nothing earned yet"; null means "this server does
                // not run this ladder"). Those get different sentences.
                handlerXp: typeof result.handlerXp === 'number' ? result.handlerXp : null,
                handlerTierLabel: typeof result.handlerTierLabel === 'string' ? result.handlerTierLabel : null,
                xpLadder: Array.isArray(result.xpLadder) ? result.xpLadder : [],
                handlerXpLadder: Array.isArray(result.handlerXpLadder) ? result.handlerXpLadder : [],
                // ABSENT AND EMPTY ARE NOT THE SAME THING (2026-09-01) --
                // this line used to read `result.myFeatures || []`, which
                // collapsed them, and that collapse is the remaining half
                // of the owner's "everything in the command console in the
                // status says disabled" report.
                //
                // commandReferenceStatus() resolves every command's badge
                // out of this array, and treats a key it cannot find as
                // 'global_off' -- correct, and deliberate: server-side, a
                // key absent from Config.Features really is off (see that
                // function's own comment). But that reasoning only holds
                // if the array genuinely IS the server's feature list. If
                // the field never arrived -- an older server that does not
                // send it, a partially-composed response -- `|| []`
                // manufactured an empty list, every single key was then
                // "not found", and the whole screen reported "Disabled
                // server-wide" on a completely healthy server. That is
                // indistinguishable from a real shutdown to anyone reading
                // it.
                //
                // Keeping it null preserves the one distinction that
                // matters: null means "the server did not tell us", where
                // the honest answer is "unknown"; [] means "the server told
                // us there are none", where "off" really is correct. Every
                // reader of this field already guards with
                // `(state.myRecord && state.myRecord.myFeatures) || []`, so
                // null is safe for all of them.
                myFeatures: Array.isArray(result.myFeatures) ? result.myFeatures : null,
            };
            // CLIENT-LOCAL role signal -- client/tablet.lua's own
            // ResolveLocalRoleFlags() enriches this exact response with
            // these two fields; see state.isK9Model's own doc comment
            // above for why this is cosmetic/framing only.
            state.isK9Model = result.isK9Model === true;
            state.isPartnered = result.isPartnered === true;

            // AUTO-LANDING BY RANK (owner-directed, 2026-08-26: "make it
            // one command that makes it based off the rank in the
            // department" -- instead of a separate command just for a
            // different landing screen). CONSUMED here, exactly once per
            // open, strictly AFTER the server's own viewer fields for THIS
            // caller are known -- never before: handleOpen() already left
            // `state.screen` at the ordinary 'home' default the instant
            // the tablet opened, so if this fetch is slow, times out, or
            // fails outright, the caller sits on that same ordinary
            // landing screen the whole time, NEVER the console -- fail
            // toward the normal view, never toward the admin one. This is
            // presentation only: it decides which screen to land on, never
            // whether the request above succeeded or what data it
            // returned -- see THE SECURITY RULE at the top of this file.
            //
            // Reuses canAccessConsole() -- the EXACT SAME gate the Console
            // tab/Home card already use (isHighCommand, or an explicit
            // 'k9.audit' grant) -- deliberately not a second, parallel
            // notion of "is this person important enough". This is a
            // LANDING SCREEN choice only: canAccessConsole() itself grants
            // nothing, and every server-side callback the console screen
            // goes on to call (tabletRequestRoster, etc.) re-verifies its
            // own authorization from scratch regardless of how this
            // caller arrived there -- see server/tablet.lua's
            // CallerHasConsoleAccess.
            //
            // 'auto' (the ordinary command/item/radial, every day): a
            // qualifying caller lands on the console, pre-loaded; anyone
            // else stays on the SAME 'home' screen everyone always lands
            // on -- silently, no notice, since they never asked for the
            // console at all.
            // 'highCommand' (the OPTIONAL, opt-in Config.CommandTablet.
            // highCommandCommand shortcut, default disabled): identical
            // qualifying check, but an insufficient caller who explicitly
            // typed THIS command still sees a plain, visible refusal
            // notice rather than being silently left on their own record,
            // exactly as before this pass -- they asked, so they are told
            // why not.
            if (state.requestedView === 'highCommand' || state.requestedView === 'auto') {
                var requestedExplicitly = state.requestedView === 'highCommand';
                state.requestedView = null;
                if (canAccessConsole()) {
                    state.screen = 'console';
                    render();
                    loadRoster(state.rosterQuery);
                    loadOnlinePlayers(state.onlinePlayersQuery);
                    return;
                }
                if (requestedExplicitly) {
                    state.actionNotice = { kind: 'error', text: S('high_command_required_notice') };
                }
            }

            render();
        });
    }

    /** Partnerships tab -- self, everyone (see that screen's own header
     * comment). */
    function loadMyPartnerships() {
        state.myPartnershipsLoading = true;
        state.myPartnershipsError = null;
        render();

        fetchNui('tablet:requestMyPartnerships', {}).then(function (result) {
            state.myPartnershipsLoading = false;
            if (!result || result.ok !== true) {
                state.myPartnershipsError = result || { error: 'unknown_error' };
                render();
                return;
            }
            state.myPartnerships = {
                featureEnabled: result.featureEnabled !== false,
                partnerships: result.partnerships || [],
                truncated: result.truncated === true,
            };
            render();
        });
    }

    /** Partnerships tab admin lookup -- high command only (server-side
     * re-verified; see buildPersonPartnershipHistorySection()'s own doc comment).
     * @param {string} citizenid */
    function loadPartnershipsForTarget(citizenid) {
        state.partnershipsAdminLoading = true;
        state.partnershipsAdminError = null;
        render();

        fetchNui('tablet:requestPartnershipsForTarget', { targetCitizenId: citizenid }).then(function (result) {
            state.partnershipsAdminLoading = false;
            if (!result || result.ok !== true) {
                state.partnershipsAdminError = result || { error: 'unknown_error' };
                state.partnershipsAdminResult = null;
                render();
                return;
            }
            state.partnershipsAdminResult = {
                target: result.target || { citizenid: citizenid, name: citizenid },
                featureEnabled: result.featureEnabled !== false,
                partnerships: result.partnerships || [],
                truncated: result.truncated === true,
            };
            render();
        });
    }

    /** Partnerships tab admin control -- high command only. Re-pulls the
     * same target's lookup afterward (runMutation()'s own "never trust a
     * local optimistic copy" contract) rather than assuming success means
     * the row is now gone.
     * @param {string} citizenid */
    function forceEndPartnership(citizenid) {
        runMutation('tablet:forceEndPartnership', { targetCitizenId: citizenid }, function () {
            loadPartnershipsForTarget(citizenid);
        });
    }

    function loadRoster(query) {
        state.rosterLoading = true;
        state.rosterError = null;
        render();

        fetchNui('tablet:requestRoster', { query: query || '' }).then(function (result) {
            // STALE-RESPONSE GUARD: the search box's debounce only SPACES
            // requests out, it does not cancel one already sent -- a fast
            // retype (or a slow/lagged server response) can let an OLDER
            // query's fetch resolve AFTER a newer one already has, or while
            // a newer one is still in flight. Without this check, an
            // out-of-order response for a query the user has since moved on
            // from would silently overwrite the currently-displayed roster
            // with results for text no longer in the search box -- a
            // silent-failure path, not a visible error, exactly the class
            // of bug this file's own header warns loudest about. Discarding
            // here leaves whatever the CURRENT (matching) request already
            // wrote to rosterLoading/rosterError/roster untouched, which is
            // correct either way (still in flight, or already settled).
            if (query !== state.rosterQuery) return;

            state.rosterLoading = false;
            if (!result || result.ok !== true) {
                state.rosterError = result || { error: 'unknown_error' };
                state.roster = null;
                render();
                return;
            }
            state.roster = {
                rows: result.rows || [],
                truncated: result.truncated === true,
                truncatedMessage: typeof result.truncatedMessage === 'string' ? result.truncatedMessage : null,
            };
            render();
        });
    }

    /**
     * ONLINE PLAYERS LIST -- see buildOnlinePlayersSection()'s own header.
     * SAME shape as loadRoster() immediately above (server-backed search,
     * identical stale-response guard), a SEPARATE query/result pair.
     * @param {string} query
     */
    function loadOnlinePlayers(query) {
        state.onlinePlayersLoading = true;
        state.onlinePlayersError = null;
        render();

        fetchNui('tablet:requestOnlinePlayers', { query: query || '' }).then(function (result) {
            // STALE-RESPONSE GUARD -- see loadRoster()'s own identical
            // comment just above; same reasoning, applied to this
            // independent query/result pair.
            if (query !== state.onlinePlayersQuery) return;

            state.onlinePlayersLoading = false;
            if (!result || result.ok !== true) {
                state.onlinePlayersError = result || { error: 'unknown_error' };
                state.onlinePlayers = null;
                render();
                return;
            }
            state.onlinePlayers = {
                rows: result.rows || [],
                truncated: result.truncated === true,
                truncatedMessage: typeof result.truncatedMessage === 'string' ? result.truncatedMessage : null,
            };
            render();
        });
    }

    /**
     * Resolves ONE online-players row (server id + its opaque, single-use
     * nonce) to the citizenid it belonged to, freshly, at the moment of
     * THIS click -- then opens the Person screen for it, exactly as the
     * roster's Manage button or the "open by exact citizen ID" box
     * already do (reuses openPerson() verbatim -- this is a NEW ENTRY
     * POINT into that screen, not a second grant mechanism).
     *
     * NEVER guesses a citizenid client-side and never reuses one from an
     * earlier fetch of this same list -- see server/tablet.lua's
     * tabletResolveOnlinePlayer for the RECYCLED-SOURCE-ID guard this
     * round trip exists to close (the person who was at this server id
     * when the list was drawn may have disconnected, or even been
     * replaced by someone else entirely, by the time this click lands).
     * A failure here (the row's own person is no longer there, or the
     * list has simply gone stale) surfaces a plain, visible notice and
     * does NOT navigate anywhere -- never a guess at who to open instead.
     * @param {number} source
     * @param {string} nonce
     */
    function openOnlinePlayer(source, nonce) {
        if (state.onlinePlayersOpeningSource !== null) return; // one resolve in flight at a time -- see this field's own state comment
        state.onlinePlayersOpeningSource = source;
        render();

        fetchNui('tablet:openOnlinePlayer', { source: source, nonce: nonce }).then(function (result) {
            state.onlinePlayersOpeningSource = null;
            if (!result || result.ok !== true || typeof result.citizenid !== 'string' || result.citizenid === '') {
                // errorText() already prefers `result.message` when present
                // (see its own definition) -- server/tablet.lua's
                // tabletResolveOnlinePlayer always supplies one for both
                // refusal codes this call can return
                // ('target_disconnected'/'stale_online_list'), so this
                // renders that exact, honest explanation rather than a
                // generic failure notice.
                state.actionNotice = { kind: 'error', text: errorText(result) };
                render();
                return;
            }
            var resolvedName = typeof result.name === 'string' && result.name !== '' ? result.name : null;
            openPerson(result.citizenid, resolvedName);
        });
    }

    function openPerson(citizenid, name, fromScreen) {
        state.screen = 'person';
        // docs/history/ROSTER_SPEC.md §0's "mode flag", the only one this pass needs --
        // see state.personOpenedFrom's own declaration comment. Every
        // EXISTING call site (Console tab, "open by exact citizen ID",
        // Online Players picker) passes no third argument at all, so this
        // defaults to 'console' for every one of them, unchanged.
        state.personOpenedFrom = fromScreen === 'roster' ? 'roster' : 'console';
        state.person = { citizenid: citizenid, name: name };
        state.personSummary = null;
        state.personFeatures = null;
        state.personFeatureQuery = '';
        // Cleared, never left stale: buildPersonPartnershipHistorySection()
        // renders off this state, and a result loaded for a PREVIOUS person
        // must not be shown against this one, even for the single frame
        // before the new load resolves. That function ALSO compares the
        // result's citizenid against the open person -- belt and braces,
        // because a late response for the previous person can still land
        // after this point.
        state.partnershipsAdminResult = null;
        state.partnershipsAdminError = null;
        render();
        loadPersonSummary(citizenid);
        if (state.viewer && state.viewer.isHighCommand) {
            loadPersonFeatures(citizenid);
            // Partnership history + Force End, moved onto this screen with
            // plan item E. Same opportunistic, best-effort posture as
            // loadPersonFeatures directly above: a refusal leaves the
            // section empty rather than breaking the screen.
            loadPartnershipsForTarget(citizenid);
            // Opportunistic, best-effort: populates state.permissionKeys
            // for buildCapabilityList()'s own merged rendering (the
            // Permission Keys tab shares this exact same state -- see
            // that tab's loadPermissionKeys() doc comment). Gated on
            // isHighCommand, unlike loadCertTiers() just below, because
            // ONLY a high-command viewer ever reaches buildCapabilityList
            // at all (see buildPersonScreen()) -- a non-high-command
            // caller has nothing here to populate. A failed/denied fetch
            // leaves state.permissionKeys exactly as it was (usually
            // null); resolveCapabilityRows() falls back to rendering just
            // the four shipped capabilities in that case, never an empty
            // panel.
            loadPermissionKeys();
            // Opportunistic, best-effort: populates state.k9ProfileSelected/
            // Draft for buildPersonK9ProfileSection()'s own embedded
            // speed/scent/medkit/stamina editor -- see that function's own
            // header. A failed/denied fetch leaves the section showing its
            // own error state with a Retry button, never breaking the
            // rest of this screen.
            loadK9Profile(citizenid);
            // Opportunistic, best-effort: populates state.personnelRoster
            // for this screen's OWN Roster Role/Callsign section
            // (buildRosterRoleSection(), docs/history/ROSTER_SPEC.md Phase B) --
            // the EXACT SAME qbx_k9unit:server:rosterList payload the two
            // roster tabs render, never a second read mechanism. A
            // failed/denied fetch leaves that section showing its own
            // error state with a Retry button, never breaking the rest of
            // this screen (same posture as loadK9Profile immediately
            // above).
            loadPersonnelRoster();
        }
        // Opportunistic, best-effort: populates state.certTiers for this
        // screen's tier-assignment picker (buildCertificationDetail).
        // loadCertTiers() is target-independent and safe to call
        // regardless of arrival order (same note already on this
        // function's own definition) -- a caller who is not high command
        // simply gets `error:'denied'` back, state.certTiers stays
        // whatever it was (usually null), and the tier control falls back
        // to read-only text; see buildCertificationDetail's own doc
        // comment for why that fallback, rather than a second gate, is the
        // right call here.
        loadCertTiers();
    }

    function loadPersonSummary(citizenid) {
        // STUCK-LOADING FIX (this pass, focus-and-state audit finding #5) --
        // this ENTRY guard is the SAME identity check the .then() callback
        // below already runs, moved to run BEFORE the loading/error prelude
        // that follows it, not just before the state this function's own
        // fetch eventually writes. Without it: refreshPersonAndSelf()
        // (called from every Person-screen mutation's onSettled, to catch a
        // self-certify/self-XP-grant) can call loadPersonSummary(citizenid)
        // again for a citizenid the operator has SINCE navigated away from
        // (they opened a different person, or left the Person screen
        // entirely, while that earlier mutation was still in flight). That
        // stale call's own prelude used to run unconditionally --
        // clobbering whatever loading/error state the CURRENTLY-displayed
        // person's own, unrelated fetch had already settled into (including
        // a real, retryable error) with a fresh "loading" flag -- and
        // because the .then() callback's own guard then correctly bails out
        // for that mismatched citizenid, personSummaryLoading was left
        // stuck at `true` forever, with no code path left to ever clear it:
        // a permanently-stuck loading skeleton with no retry button,
        // silently replacing a real error the operator could otherwise have
        // retried. Bailing out HERE, before either the prelude or the fetch
        // even starts, means a call for a citizenid no longer on screen
        // touches NOTHING.
        if (!state.person || state.person.citizenid !== citizenid) return;

        state.personSummaryLoading = true;
        state.personSummaryError = null;
        render();

        fetchNui('tablet:requestPersonSummary', { targetCitizenId: citizenid }).then(function (result) {
            // STALE-RESPONSE GUARD: openPerson()/the console's "open by
            // exact citizen ID" box can navigate to a DIFFERENT person (or
            // back to the console/my-record screen entirely) while this
            // request is still in flight -- nothing here cancels the
            // underlying fetch. Without this check, an out-of-order
            // response for a citizenid no longer on screen would silently
            // apply THAT person's certifications/XP/permissions under the
            // CURRENTLY-displayed person's name/header -- a wrong-data bug
            // with no visible error, not merely a stale-but-harmless retry
            // (contrast loadMyRecord/loadTheme/loadCertTiers, which have no
            // target parameter and are safe to apply regardless of arrival
            // order). Discarding here leaves whatever the CURRENT
            // navigation's own request already wrote untouched.
            if (!state.person || state.person.citizenid !== citizenid) return;

            state.personSummaryLoading = false;
            if (!result || result.ok !== true) {
                state.personSummaryError = result || { error: 'unknown_error' };
                render();
                return;
            }
            applyRoleCatalog(result.roleCatalog);
            state.personSummary = {
                certifications: result.certifications || [],
                roleXp: typeof result.roleXp === 'number' ? result.roleXp : null,
                // The dog-character pin's breed, or null (server/tablet.lua).
                pinnedDogModel: typeof result.pinnedDogModel === 'string' && result.pinnedDogModel.length > 0 ? result.pinnedDogModel : null,
                xp: typeof result.xp === 'number' ? result.xp : null,
                tierLabel: typeof result.tierLabel === 'string' ? result.tierLabel : null,
                // HANDLER ladder, carried alongside the K9 pair above and
                // never merged with it -- separate ladders, separate feature
                // switches, either can be null while the other has a value.
                // The typeof check is load-bearing, not a defensive habit:
                // `result.handlerXp || null` would turn a genuine 0 (a real
                // handler who has earned nothing yet) into null (the ladder
                // is switched off server-wide), which are different facts
                // that must reach the screen as different sentences.
                handlerXp: typeof result.handlerXp === 'number' ? result.handlerXp : null,
                handlerTierLabel: typeof result.handlerTierLabel === 'string' ? result.handlerTierLabel : null,
                permissions: result.permissions || [],
                // READ-ONLY rank/partnership (owner-directed "roster panel
                // shows everything about a person" pass) -- both null-safe,
                // never guessed when the server itself sent nothing usable.
                job: (result.job && typeof result.job === 'object') ? result.job : null,
                partnership: (result.partnership && typeof result.partnership === 'object') ? result.partnership : null,
            };
            if (result.target && typeof result.target.name === 'string' && state.person) {
                state.person.name = result.target.name;
            }
            render();
        });
    }

    function loadPersonFeatures(citizenid) {
        // STUCK-LOADING FIX (this pass) -- SAME entry guard, SAME reasoning,
        // SAME "moved before the prelude" fix as loadPersonSummary()'s
        // identical comment just above -- this function has the exact same
        // shape (a stale refreshPersonFeaturesAndSelf() call for a
        // citizenid the operator has since navigated away from) and the
        // exact same "prelude wipes a real error into a permanently stuck
        // skeleton" failure mode.
        if (!state.person || state.person.citizenid !== citizenid) return;

        state.personFeaturesLoading = true;
        state.personFeaturesError = null;
        render();

        fetchNui('tablet:requestPersonFeatures', { targetCitizenId: citizenid }).then(function (result) {
            // STALE-RESPONSE GUARD -- see loadPersonSummary()'s identical
            // comment just above; same race, same fix, applied to the
            // Abilities table instead of the certifications/XP/permissions
            // block.
            if (!state.person || state.person.citizenid !== citizenid) return;

            state.personFeaturesLoading = false;
            if (!result || result.ok !== true) {
                state.personFeaturesError = result || { error: 'unknown_error' };
                render();
                return;
            }
            state.personFeatures = { features: result.features || [] };
            render();
        });
    }

    /**
     * STALE-STATE FIX (this pass) -- every Person-screen mutation
     * (certify/decertify/setTier/renew/grantSpecialization/
     * revokeSpecialization/givexp/grantPermission/revokePermission/
     * assignK9Role/revertK9Ped) used to refresh ONLY state.personSummary
     * via onSettled's own bare `loadPersonSummary(citizenid)` call --
     * correct for an ordinary target, but self-certification
     * (Config.AllowSelfCertification) and self-XP-grant
     * (Config.HighCommand.allowSelfGrant) are both REAL, config-permitted
     * flows an operator can trigger by opening THEIR OWN citizenid on the
     * Person screen (the Console's own "open by exact citizen ID" box
     * places no restriction on whose id is typed there). state.myRecord/
     * state.viewer (read by the Home AND My Record screens) describe the
     * EXACT SAME underlying certifications/XP/permissions/features for
     * that one citizenid, fetched over a SEPARATE round trip
     * (tablet:requestMyRecord vs. tablet:requestPersonSummary) -- so a
     * self-action used to leave Home/My Record showing a stale copy until
     * the viewer happened to click one of those two tabs directly
     * (My Record already reloads on every click; Home now does too, see
     * buildTabs()'s own homeTab handler). Every Person-screen mutation
     * below now calls this instead of `loadPersonSummary` directly so a
     * self-action refreshes its own identity screens automatically, in the
     * same tick, without waiting on that tab click. A no-op extra fetch for
     * the (overwhelmingly common) case of acting on someone else -- never
     * skipped or short-circuited, since that would itself be a "did this
     * actually re-check" trap.
     * @param {string} citizenid
     */
    function refreshPersonAndSelf(citizenid) {
        loadPersonSummary(citizenid);
        if (state.viewer && citizenid === state.viewer.citizenid) loadMyRecord();
    }

    /** SAME fix, applied to the Abilities table's own grant/revoke/block/
     * unblock actions (buildPersonFeatureRow) -- see refreshPersonAndSelf()
     * immediately above for the full write-up; state.myRecord.myFeatures is
     * the identical underlying data My Record's/Home's own "My Abilities"/
     * "Ready Abilities" sections read.
     * @param {string} citizenid
     */
    function refreshPersonFeaturesAndSelf(citizenid) {
        loadPersonFeatures(citizenid);
        if (state.viewer && citizenid === state.viewer.citizenid) loadMyRecord();
    }

    /**
     * Applies the four colour slots to CSS custom properties on
     * `document.documentElement` so tablet.css's own `var(--k9tablet-*, ...)`
     * rules pick them up immediately, independent of render()'s own
     * clear-and-rebuild cycle (this survives every subsequent render()
     * automatically via normal CSS inheritance/cascade, rather than needing
     * to be re-applied to a freshly built panel element every time -- see
     * buildBackdrop()'s own density-class handling for the ONE piece of
     * theming that DOES need to be re-applied per render, and why).
     *
     * Guarded, not assumed: `document.documentElement` does not exist in
     * this project's own test stub (html/tests/tablet-dom-stub.js builds
     * only the one static `#k9tablet-root` div tablet.html actually ships,
     * matching that file's own "everything else is built by tablet.js"
     * design) -- this silently no-ops there rather than throwing, which is
     * correct: nothing under test ever asserts on real CSS cascade, only on
     * the DOM nodes/text/classes this page itself builds.
     * @param {object} theme
     */
    function applyThemeToDocument(theme) {
        theme = theme || DEFAULT_THEME;
        var docEl = (typeof document !== 'undefined') ? document.documentElement : null;
        var styleTarget = (docEl && docEl.style && typeof docEl.style.setProperty === 'function') ? docEl.style : null;
        if (!styleTarget) return;
        styleTarget.setProperty('--k9tablet-primary', theme.primaryColor || DEFAULT_THEME.primaryColor);
        styleTarget.setProperty('--k9tablet-accent', theme.accentColor || DEFAULT_THEME.accentColor);
        styleTarget.setProperty('--k9tablet-bg', theme.backgroundColor || DEFAULT_THEME.backgroundColor);
        styleTarget.setProperty('--k9tablet-text', theme.textColor || DEFAULT_THEME.textColor);
    }

    /**
     * Seeds state.theme/applies it, from Config.CommandTablet.branding's
     * own `theme` (four colours only -- density/headerTitle are NOT part
     * of branding, see config.lua's own comment: branding.theme is only
     * "starting colours, matched to the shipped logo"). Called ONLY when
     * state.theme is still null (see handleOpen()) -- i.e. this page's
     * very first open this session, before tablet:getTheme has EVER
     * resolved even once. Purely a first-paint cosmetic improvement so
     * the tablet does not flash the generic code-level DEFAULT_THEME
     * before the real fetch lands; the real tablet:getTheme response
     * (server/runtimecontrol.lua's own CurrentTheme -- config default,
     * DB override wins, the SAME precedence this function mirrors for the
     * brief window before that fetch resolves) is what actually matters
     * and OVERWRITES this the moment it arrives, every time, unconditionally
     * -- see loadTheme() below, which never checks "do I already have a
     * seeded value" before applying its own result.
     */
    function applyBrandingSeedTheme() {
        var brandingTheme = state.branding && state.branding.theme;
        if (!brandingTheme || typeof brandingTheme !== 'object') return;
        var seeded = assignShallow({}, DEFAULT_THEME);
        // Only the four colour keys -- an unexpected extra key on
        // branding.theme (a config mistake) is silently ignored here, not
        // propagated; server/runtimecontrol.lua's own ValidateFullTheme is
        // still the only check that actually matters once the real fetch
        // lands regardless.
        if (typeof brandingTheme.primaryColor === 'string') seeded.primaryColor = brandingTheme.primaryColor;
        if (typeof brandingTheme.accentColor === 'string') seeded.accentColor = brandingTheme.accentColor;
        if (typeof brandingTheme.backgroundColor === 'string') seeded.backgroundColor = brandingTheme.backgroundColor;
        if (typeof brandingTheme.textColor === 'string') seeded.textColor = brandingTheme.textColor;
        state.theme = seeded;
        state.themeDraft = assignShallow({}, seeded);
        applyThemeToDocument(seeded);
    }

    /** Fetched once per open (see handleOpen()) and again on the theme tab
     * being opened directly (see buildTabs()) -- APPLIED FOR EVERY VIEWER
     * regardless of role (tablet:getTheme itself has no authorization gate,
     * see this file's header THE SECURITY RULE / NUI CONTRACT), even though
     * only high command ever sees buildThemeScreen()'s own edit controls. */
    function loadTheme() {
        state.themeLoading = true;
        state.themeError = null;
        render();

        fetchNui('tablet:getTheme', {}).then(function (result) {
            state.themeLoading = false;
            if (!result || result.ok !== true) {
                state.themeError = result || { error: 'unknown_error' };
                render();
                return;
            }
            state.theme = result.theme || DEFAULT_THEME;
            state.themeDraft = assignShallow({}, state.theme);
            state.themeFieldError = null;
            applyThemeToDocument(state.theme);
            render();
        });
    }

    /** IE11-free shallow-copy helper -- this file otherwise targets very
     * old-JS syntax throughout (`var`, no arrow functions, no template
     * literals -- see this page's existing style), so `Object.assign` is
     * avoided here for the same reason, not because it is unavailable in
     * CEF specifically.
     * @param {object} target @param {object} source @returns {object} */
    function assignShallow(target, source) {
        for (var k in source) {
            if (Object.prototype.hasOwnProperty.call(source, k)) target[k] = source[k];
        }
        return target;
    }

    /** Substitutes `{key}`-style tokens in `template` from `replacements`
     * -- this file's own lightweight string-formatting need (used by
     * several *_template-suffixed locale keys throughout this file, e.g.
     * cert_tier_error_tier_in_use's `{count}`), so a tiny token replace is
     * used rather than pulling in a template-literal/sprintf dependency.
     *
     * SINGLE PASS, DELIBERATELY. This used to loop the keys and run one
     * `split().join()` per key, which meant every value substituted by an
     * earlier key was still sitting in the string when a LATER key's pass
     * scanned it -- so a value that happened to contain another key's token
     * got replaced in turn. Not hypothetical: several of this file's own
     * templates interpolate operator- or player-supplied text into a
     * template that has a second token. A supply shop item named
     * `{count}` corrupts cert_tier_error_tier_in_use_by_shop_items (whose
     * `{items}` value is a joined list of item names), and a rank renamed
     * to contain `{xp}` or `{remaining}` in the live Rank Editor corrupts
     * the progression ladder -- server/xptiers.lua's own label validator
     * rejects `<>&"'` but has no reason to reject braces.
     *
     * A single regex pass fixes the whole class: the replacer's return
     * value is never re-scanned, so a substituted value can never be
     * treated as a token no matter what it contains, and the order of keys
     * stops mattering. Cosmetic corruption only, never an injection route
     * -- every consumer puts the result through mk()'s textContent, never
     * innerHTML -- but a rank label reading "reach {remaining} XP" instead
     * of a number is still a bug a player would report.
     *
     * A token with no matching key is left verbatim, which is both what the
     * old implementation did and far better than rendering "undefined" over
     * a typo. Every key this file actually passes is `[A-Za-z0-9_]+` (the
     * pattern below is the enforcement, not just a description) -- a future
     * key with a dot or dash would silently stop resolving, so keep to
     * that shape.
     * @param {string} template @param {Record<string, string|number>} replacements @returns {string} */
    function formatTemplate(template, replacements) {
        var map = replacements || {};
        return String(template).replace(/\{([A-Za-z0-9_]+)\}/g, function (token, key) {
            if (!Object.prototype.hasOwnProperty.call(map, key)) return token;
            return String(map[key]);
        });
    }

    /** Fetched fresh every time the Cert Tiers tab is opened (see
     * buildTabs()) -- NEVER a hardcoded list. server/certtiers.lua's own
     * header: the catalogue is Config.CertificationTiers defaults merged
     * with database overrides (database wins), and high command can add
     * tiers at runtime -- a list captured once here would already be stale
     * the moment anyone adds/renames/deletes a tier. High command only
     * (server/certtiers.lua's own CanManageCertTiers re-verifies this on
     * every one of the four callbacks regardless of whether this ever
     * loads). */
    function loadCertTiers() {
        state.certTiersLoading = true;
        state.certTiersError = null;
        render();

        fetchNui('tablet:certTiersList', {}).then(function (result) {
            state.certTiersLoading = false;
            if (!result || result.ok !== true) {
                state.certTiersError = result || { error: 'unknown_error' };
                render();
                return;
            }
            state.certTiers = Array.isArray(result.tiers) ? result.tiers : [];
            state.certTierCapabilityCatalog = (result.capabilityCatalog && typeof result.capabilityCatalog === 'object') ? result.capabilityCatalog : {};
            render();
        });
    }

    /** Fetched fresh every time the Permission Keys tab is opened (see
     * buildTabs()) -- NEVER a hardcoded list, same posture as
     * loadCertTiers() just above: the four admin capability names are
     * Config.Permissions defaults merged with database overrides (database
     * wins, per server/permissionkeycatalog.lua's own header), and high
     * command can add/relabel/retire keys at runtime -- a list captured
     * once here would already be stale the moment anyone does. High
     * command only (server/permissionkeycatalog.lua's own
     * CanManagePermissionKeys re-verifies this on every one of the three
     * callbacks regardless of whether this ever loads). */
    function loadPermissionKeys() {
        state.permissionKeysLoading = true;
        state.permissionKeysError = null;
        render();

        fetchNui('tablet:permKeysList', {}).then(function (result) {
            state.permissionKeysLoading = false;
            if (!result || result.ok !== true) {
                state.permissionKeysError = result || { error: 'unknown_error' };
                render();
                return;
            }
            state.permissionKeys = Array.isArray(result.keys) ? result.keys : [];
            render();
        });
    }

    /** Fetched fresh every time the Shop Locations tab is opened (see
     * buildTabs()) -- NEVER a hardcoded list, same posture as
     * loadCertTiers() just above. High command OR a delegated
     * 'k9.equipmentshoplocations' grant (server-side gate -- see this
     * section's own buildShopLocationsSection() doc comment; client-side
     * display gate -- canManageShopLocations()). */
    function loadShopLocations() {
        state.shopLocationsLoading = true;
        state.shopLocationsError = null;
        // STALE-RESPONSE GUARD: this tab can be left and revisited (or
        // Refresh -- via Retry after an error -- pressed twice) while an
        // earlier tablet:equipmentShopGetLocations request is still in
        // flight; nothing here cancels the underlying fetch. Unlike
        // loadPersonSummary()/loadRoster() (which compare the in-flight
        // request's own captured target/query against current state at
        // resolution time), this list has no such per-request identity to
        // key off -- so a plain, monotonically increasing request id is
        // used instead: only the response for the MOST RECENTLY issued
        // request is ever applied, exactly the same class of fix, applied
        // the only way it CAN be applied when every request asks the exact
        // same question.
        var requestId = ++state.shopLocationsRequestId;
        render();

        fetchNui('tablet:equipmentShopGetLocations', {}).then(function (result) {
            if (requestId !== state.shopLocationsRequestId) return;

            state.shopLocationsLoading = false;
            if (!result || result.ok !== true) {
                state.shopLocationsError = result || { error: 'unknown_error' };
                render();
                return;
            }
            state.shopLocations = (result.locations && typeof result.locations === 'object') ? result.locations : {};
            render();
        });
    }

    /** Fetched fresh every time the Runtime Control tab is opened (see
     * buildTabs()) -- NEVER a hardcoded list, same posture as
     * loadCertTiers()/loadShopLocations() above. High command OR a
     * delegated 'k9.runtimecontrol' grant (server-side gate -- see
     * buildRuntimeControlScreen()'s own doc comment; client-side display
     * gate -- canManageRuntimeControl()). STALE-RESPONSE GUARD: same
     * request-id shape as loadShopLocations() above -- this list has no
     * per-request identity (like a citizenid/query) to compare against
     * arrival order. */
    function loadRuntimeFeatures() {
        state.runtimeFeaturesLoading = true;
        state.runtimeFeaturesError = null;
        var requestId = ++state.runtimeFeaturesRequestId;
        render();

        fetchNui('tablet:runtimeListFeatures', {}).then(function (result) {
            if (requestId !== state.runtimeFeaturesRequestId) return;

            state.runtimeFeaturesLoading = false;
            if (!result || result.ok !== true) {
                state.runtimeFeaturesError = result || { error: 'unknown_error' };
                render();
                return;
            }
            state.runtimeFeatures = Array.isArray(result.features) ? result.features : [];
            render();
        });
    }

    /** Same posture as loadRuntimeFeatures() immediately above, for the
     * Tunables section on the same screen. */
    function loadRuntimeTunables() {
        state.runtimeTunablesLoading = true;
        state.runtimeTunablesError = null;
        var requestId = ++state.runtimeTunablesRequestId;
        render();

        fetchNui('tablet:runtimeListTunables', {}).then(function (result) {
            if (requestId !== state.runtimeTunablesRequestId) return;

            state.runtimeTunablesLoading = false;
            if (!result || result.ok !== true) {
                state.runtimeTunablesError = result || { error: 'unknown_error' };
                render();
                return;
            }
            state.runtimeTunables = Array.isArray(result.tunables) ? result.tunables : [];
            render();
        });
    }

    /** @param {object|undefined} result @returns {string} */
    function certTierErrorText(result) {
        if (!result) return S('action_failed');
        if (typeof result.message === 'string' && result.message.length > 0) return result.message;
        switch (result.error) {
            case 'denied': return S('cert_tier_error_denied');
            case 'rate_limited': return S('cert_tier_error_rate_limited');
            case 'invalid_key': return S('cert_tier_error_invalid_key');
            case 'invalid_label': return S('cert_tier_error_invalid_label');
            case 'invalid_capabilities': return S('cert_tier_error_invalid_capabilities');
            case 'busy': return S('cert_tier_error_busy');
            case 'too_many_tiers': return S('cert_tier_error_too_many_tiers');
            case 'unknown_tier': return S('cert_tier_error_unknown_tier');
            // PARTIAL-FAILURE CASES (added 2026-08-31). server/certtiers.lua
            // returns these with `failedKeys` / `failedCapabilities` naming
            // exactly what did not persist, plus a `warning`. Neither had a
            // case here, so both fell to `default:` and rendered the bare
            // "action failed" line -- the worst possible copy for a PARTIAL
            // write, where the admin's real question is "what actually got
            // saved?" and the honest answer is "reopen and look".
            case 'ordinal_write_failed': return formatTemplate(S('cert_tier_error_ordinal_write_failed'), {
                keys: Array.isArray(result.failedKeys) ? result.failedKeys.join(', ') : '?',
            });
            case 'capability_write_failed': return S('cert_tier_error_capability_write_failed');
            // 'protected_tier'/'tier_in_use'/'tier_in_use_by_shop_items' are
            // REFUSALS ("cannot, and here is why"), not generic failures --
            // per this task's own instruction, given their own explanatory
            // copy rather than a bare machine code or S('action_failed').
            case 'protected_tier': return S('cert_tier_error_protected_tier');
            case 'tier_in_use': return formatTemplate(S('cert_tier_error_tier_in_use'), { count: typeof result.referenceCount === 'number' ? result.referenceCount : '' });
            // The OTHER referrer DeleteTier checks (server/certtiers.lua,
            // commit a32a554) -- a supply shop item requiring this tier.
            // Kept in the SAME category as 'tier_in_use' immediately above
            // (a real refusal with its own explanatory copy), never folded
            // into that same message: "N certification records" and "N
            // shop items" need different actions from the reader, and one
            // combined count would send them to the wrong screen.
            case 'tier_in_use_by_shop_items': return formatTemplate(S('cert_tier_error_tier_in_use_by_shop_items'), {
                count: typeof result.referenceCount === 'number' ? result.referenceCount : '',
                items: Array.isArray(result.shopItemKeys) ? result.shopItemKeys.join(', ') : '',
            });
            case 'must_include_every_tier': return S('cert_tier_error_must_include_every_tier');
            case 'invalid_key_set': return S('cert_tier_error_invalid_key_set');
            case 'invalid_payload': return S('cert_tier_error_invalid_payload');
            case 'db_error': return S('cert_tier_error_db_error');
            case 'timeout': return S('error_timeout');
            case 'network_error': return S('error_network');
            default: return S('action_failed');
        }
    }

    /** @param {string|undefined} errorCode @returns {string|null} */
    function certTierFieldFromError(errorCode) {
        if (errorCode === 'invalid_key') return 'key';
        if (errorCode === 'invalid_label') return 'label';
        if (errorCode === 'invalid_capabilities') return 'capabilities';
        return null;
    }

    /** Opens a BLANK draft for a brand-new tier. @see buildCertTierDraftForm */
    function openNewCertTierDraft() {
        state.certTierDraft = { key: '', label: '', capabilities: {}, isNew: true };
        state.certTierFieldError = null;
        render();
    }

    /** Opens a draft pre-filled from an EXISTING tier row -- a COPY of its
     * capabilities set, never the live object, so cancelling never mutates
     * state.certTiers. @param {object} tier */
    function openCertTierEditDraft(tier) {
        var capabilities = {};
        if (tier.capabilities && typeof tier.capabilities === 'object') {
            for (var k in tier.capabilities) {
                if (Object.prototype.hasOwnProperty.call(tier.capabilities, k) && tier.capabilities[k] === true) capabilities[k] = true;
            }
        }
        state.certTierDraft = { key: tier.key, label: tier.label, capabilities: capabilities, isNew: false };
        state.certTierFieldError = null;
        render();
    }

    function closeCertTierDraft() {
        state.certTierDraft = null;
        state.certTierFieldError = null;
        render();
    }

    /** @param {object|undefined} result @returns {string} */
    function permissionKeyErrorText(result) {
        if (!result) return S('action_failed');
        if (typeof result.message === 'string' && result.message.length > 0) return result.message;
        switch (result.error) {
            case 'denied': return S('permission_key_error_denied');
            case 'rate_limited': return S('permission_key_error_rate_limited');
            case 'invalid_key': return S('permission_key_error_invalid_key');
            case 'invalid_label': return S('permission_key_error_invalid_label');
            case 'invalid_description': return S('permission_key_error_invalid_description');
            case 'busy': return S('permission_key_error_busy');
            case 'too_many_keys': return S('permission_key_error_too_many_keys');
            case 'unknown_key': return S('permission_key_error_unknown_key');
            // 'reserved_namespace'/'unknown_key' are REFUSALS ("cannot, and
            // here is why"), not generic failures -- same posture as
            // certTierErrorText's own 'protected_tier'/'tier_in_use' above.
            case 'reserved_namespace': return S('permission_key_error_reserved_namespace');
            case 'invalid_payload': return S('permission_key_error_invalid_payload');
            case 'db_error': return S('permission_key_error_db_error');
            case 'timeout': return S('error_timeout');
            case 'network_error': return S('error_network');
            default: return S('action_failed');
        }
    }

    /** @param {string|undefined} errorCode @returns {string|null} */
    function permissionKeyFieldFromError(errorCode) {
        if (errorCode === 'invalid_key' || errorCode === 'reserved_namespace') return 'key';
        if (errorCode === 'invalid_label') return 'label';
        if (errorCode === 'invalid_description') return 'description';
        return null;
    }

    /** Opens a BLANK draft for a brand-new permission key. @see buildPermissionKeyDraftForm */
    function openNewPermissionKeyDraft() {
        state.permissionKeyDraft = { key: '', label: '', description: '', isNew: true };
        state.permissionKeyFieldError = null;
        render();
    }

    /** Opens a draft pre-filled from an EXISTING catalog row. @param {object} entry */
    function openPermissionKeyEditDraft(entry) {
        state.permissionKeyDraft = { key: entry.key, label: entry.label, description: entry.description || '', isNew: false };
        state.permissionKeyFieldError = null;
        render();
    }

    function closePermissionKeyDraft() {
        state.permissionKeyDraft = null;
        state.permissionKeyFieldError = null;
        render();
    }

    /**
     * Saves the permission-key draft form's current working copy. NOT the
     * generic runMutation() helper: a rejected save carries a `field`
     * naming which input failed (key/label/description), which
     * runMutation's own message-only handling has no slot for, same
     * reasoning as saveCertTierDraft() above. An empty description is sent
     * as `undefined` (omitted), never `''` -- matching
     * server/permissionkeycatalog.lua's own "nil is stored as SQL NULL"
     * optional-field contract.
     */
    function savePermissionKeyDraft() {
        if (state.pendingAction || !state.permissionKeyDraft) return;
        var draft = state.permissionKeyDraft;

        state.pendingAction = true;
        state.permissionKeyFieldError = null;
        state.actionNotice = { kind: 'ok', text: S('action_working') };
        render();

        var payload = { key: draft.key, label: draft.label };
        if (typeof draft.description === 'string' && draft.description.length > 0) {
            payload.description = draft.description;
        }

        fetchNui('tablet:permKeysUpsert', payload).then(function (result) {
            state.pendingAction = false;
            if (result && result.ok === true) {
                state.permissionKeys = Array.isArray(result.keys) ? result.keys : state.permissionKeys;
                state.permissionKeyDraft = null;
                state.actionNotice = { kind: 'ok', text: S('action_succeeded') };
            } else {
                state.permissionKeyFieldError = permissionKeyFieldFromError(result && result.error);
                state.actionNotice = { kind: 'error', text: permissionKeyErrorText(result) };
            }
            render();
        });
    }

    /**
     * Deletes permission key `key`. A REFUSAL (reserved_namespace --
     * should be unreachable through this UI, since this screen never lets
     * anyone create such a key in the first place; unknown_key) is
     * rendered INLINE on that key's own row (state.permissionKeyActionError),
     * same convention as deleteCertTier() above. Unlike that function,
     * this delete NEVER carries a reference-count refusal -- see
     * server/permissionkeycatalog.lua's own header "TOMBSTONE, NOT
     * REFERENCE-COUNTED" -- so there is no equivalent of tier_in_use here.
     * @param {string} key
     */
    function deletePermissionKey(key) {
        if (state.pendingAction) return;
        state.pendingAction = true;
        state.permissionKeyActionError = null;
        state.actionNotice = { kind: 'ok', text: S('action_working') };
        render();

        fetchNui('tablet:permKeysDelete', { key: key }).then(function (result) {
            state.pendingAction = false;
            if (result && result.ok === true) {
                state.permissionKeys = Array.isArray(result.keys) ? result.keys : state.permissionKeys;
                state.actionNotice = { kind: 'ok', text: S('action_succeeded') };
            } else {
                var text = permissionKeyErrorText(result);
                state.permissionKeyActionError = { key: key, text: text };
                state.actionNotice = { kind: 'error', text: text };
            }
            render();
        });
    }

    /**
     * ONE PER-CODE MESSAGE, NOT ONE GENERIC LINE (state-handling/error-
     * reporting consistency sweep, this pass) -- runMutation() below is the
     * SINGLE shared path every certify/decertify/setCertificationTier/
     * renewCertification/grantSpecialization/revokeSpecialization/givexp/
     * grantPermission/revokePermission/grantFeature/revokeFeature/
     * blockFeature/unblockFeature/assignK9Role/revertK9Ped/triggerFeature
     * mutation on the Person (and My Record) screen goes through. Before
     * this pass it rendered EVERY ONE of the ~30 distinct `error` codes
     * those server callbacks/*ForTablet wrappers can return (confirmed by
     * reading server/certifications/'s GrantCertificationForTablet/
     * SetCertificationTierForTablet/RenewCertificationForTablet/
     * GrantSpecializationForTablet/RevokeSpecializationForTablet, server/
     * permissions.lua's GrantPermission/RevokePermission, server/
     * highcommand.lua's tabletGiveXp, and server/tablet.lua's
     * tabletAssignK9Role/tabletRevertK9Ped doc comments directly) as the
     * SAME generic S('action_failed') line -- exactly the "collapses a
     * dozen reasons into one generic line" failure mode this pass exists to
     * fix: an operator whose certify attempt was refused for being too far
     * away saw byte-identical text to one refused for the target already
     * holding an active certification, or the target's live job having
     * changed since the roster was last fetched.
     *
     * `result.message` (an already server-localized, more specific string
     * some of these callbacks attach -- e.g. tabletGiveXp's denied/
     * invalid_amount/self_grant_blocked/xp_unavailable, or
     * ReasonToJsResult's own 'still has access via rank'/'target offline'
     * revoke notes) is ALWAYS preferred first when present; this switch is
     * the fallback for every callback that returns a bare `error` code with
     * no accompanying message. Every sentence below says what to do next
     * wherever there is a next step (move closer, wait, use the other
     * action, contact an administrator) rather than only naming what went
     * wrong -- and reveals nothing the ACTING viewer could not already see
     * about their own attempt (THE SECURITY RULE: this is UX only, never a
     * new information disclosure -- every one of these codes describes a
     * precondition of the viewer's OWN just-submitted action, not another
     * player's private data).
     * @param {object|undefined} result
     * @returns {string}
     */
    function mutationErrorText(result) {
        if (!result) return S('action_failed');
        if (typeof result.message === 'string' && result.message.length > 0) return result.message;
        switch (result.error) {
            case 'invalid_args':
            case 'invalid_target': return S('mutation_error_invalid_target');
            case 'invalid_department': return S('mutation_error_invalid_department');
            case 'department_mismatch': return S('mutation_error_department_mismatch');
            case 'not_eligible': return S('mutation_error_not_eligible');
            case 'denied': return S('mutation_error_denied');
            case 'rate_limited':
            case 'on_cooldown': return S('mutation_error_rate_limited');
            case 'busy': return S('mutation_error_busy');
            case 'self_certification_disabled': return S('mutation_error_self_certification_disabled');
            case 'self_grant_blocked': return S('mutation_error_self_grant_blocked');
            case 'target_must_be_online': return S('mutation_error_target_must_be_online');
            case 'target_not_in_department': return S('mutation_error_target_not_in_department');
            case 'target_too_far': return S('mutation_error_target_too_far');
            case 'target_not_k9_model': return S('mutation_error_target_not_k9_model');
            case 'model_check_requires_online': return S('mutation_error_model_check_requires_online');
            case 'target_online_use_online_action': return S('mutation_error_target_online_use_online_action');
            case 'already_certified': return S('mutation_error_already_certified');
            case 'target_not_actively_certified': return S('mutation_error_target_not_actively_certified');
            case 'requires_active_cert': return S('mutation_error_requires_active_cert');
            case 'requires_tier_capability': return S('mutation_error_requires_tier_capability');
            case 'already_granted': return S('mutation_error_already_granted');
            case 'not_granted': return S('mutation_error_not_granted');
            case 'invalid_specialization': return S('mutation_error_invalid_specialization');
            case 'invalid_tier': return S('mutation_error_invalid_tier');
            case 'tier_already_set': return S('mutation_error_tier_already_set');
            case 'target_offline': return S('mutation_error_target_offline');
            case 'target_no_department_cert': return S('mutation_error_target_no_department_cert');
            case 'feature_disabled': return S('mutation_error_feature_disabled');
            case 'invalid_permission': return S('mutation_error_invalid_permission');
            case 'invalid_model': return S('mutation_error_invalid_model');
            case 'not_available': return S('mutation_error_not_available');
            case 'no_active_assignment': return S('mutation_error_no_active_assignment');
            case 'no_fallback_configured': return S('mutation_error_no_fallback_configured');
            case 'invalid_granter': return S('mutation_error_invalid_granter');
            case 'db_error': return S('mutation_error_db_error');
            case 'actions_disabled': return S('mutation_error_actions_disabled');
            case 'not_partnered': return S('mutation_error_not_partnered');
            case 'not_authorized': return S('error_not_authorized');
            case 'timeout': return S('error_timeout');
            case 'network_error': return S('error_network');
            default: return S('action_failed');
        }
    }

    /**
     * Generic mutation runner -- every grant/revoke/certify/decertify/
     * givexp/block/unblock action shares this shape. Disables further
     * actions while in flight (state.pendingAction), shows a transient
     * notice from the result, and always calls `onSettled` (regardless of
     * ok/fail) so callers can refresh whatever data the mutation might have
     * changed -- this page NEVER optimistically mutates its own local copy
     * of server state; every action re-pulls the authoritative version.
     * Every mutation, tablet:decertify included, answers from a real server
     * callback with a genuine `{ ok, error? }` outcome, so `ok: true` always
     * means the change actually happened.
     * @param {string} nuiName
     * @param {object} payload
     * @param {() => void} onSettled
     */
    function runMutation(nuiName, payload, onSettled) {
        if (state.pendingAction) return;
        state.pendingAction = true;
        state.actionNotice = { kind: 'ok', text: S('action_working') };
        render();

        fetchNui(nuiName, payload).then(function (result) {
            state.pendingAction = false;
            if (result && result.ok === true) {
                var successText = (typeof result.message === 'string' && result.message.length > 0) ? result.message
                    : S('action_succeeded');
                state.actionNotice = { kind: 'ok', text: successText };
            } else {
                state.actionNotice = { kind: 'error', text: mutationErrorText(result) };
            }
            onSettled();
        });
    }

    function triggerFeature(key) {
        runMutation('tablet:triggerFeature', { feature: key }, function () {
            loadMyRecord();
        });
    }

    /**
     * Saves the theme editor's current WORKING COPY (state.themeDraft) --
     * NOT the generic runMutation() helper above, because a rejected save
     * here carries a `field` (which of the six inputs failed) that
     * runMutation's own `result.message`-only handling has no slot for, and
     * because a successful save must apply the server's CANONICAL returned
     * theme immediately (applyThemeToDocument) rather than merely re-pull
     * an unrelated screen the way every other mutation's `onSettled` does.
     * Shares state.pendingAction with every other action on this page
     * regardless (same "at most one mutation in flight" invariant).
     */
    function saveTheme() {
        if (state.pendingAction || !state.themeDraft) return;
        state.pendingAction = true;
        state.themeFieldError = null;
        state.actionNotice = { kind: 'ok', text: S('action_working') };
        render();

        fetchNui('tablet:setTheme', state.themeDraft).then(function (result) {
            state.pendingAction = false;
            if (result && result.ok === true) {
                state.theme = result.theme || state.theme;
                state.themeDraft = assignShallow({}, state.theme || DEFAULT_THEME);
                applyThemeToDocument(state.theme);
                state.actionNotice = { kind: 'ok', text: S('action_succeeded') };
            } else {
                state.themeFieldError = (result && typeof result.field === 'string') ? result.field : null;
                var failText = (result && result.error === 'invalid_field') ? S('theme_field_invalid') : S('action_failed');
                state.actionNotice = { kind: 'error', text: failText };
            }
            render();
        });
    }

    /** Restores the SERVER's own built-in default (server/runtimecontrol.lua's
     * DEFAULT_THEME) -- a destructive action from an operator's point of
     * view (discards every customization), hence mkConfirmButton's two-click
     * guard at its own call site, same posture as Decertify/Revoke/Block. */
    function resetThemeToDefault() {
        if (state.pendingAction) return;
        state.pendingAction = true;
        state.themeFieldError = null;
        state.actionNotice = { kind: 'ok', text: S('action_working') };
        render();

        fetchNui('tablet:resetTheme', {}).then(function (result) {
            state.pendingAction = false;
            if (result && result.ok === true) {
                state.theme = result.theme || DEFAULT_THEME;
                state.themeDraft = assignShallow({}, state.theme);
                applyThemeToDocument(state.theme);
                state.actionNotice = { kind: 'ok', text: S('action_succeeded') };
            } else {
                // Was a blanket S('action_failed') regardless of
                // result.error -- server/runtimecontrol.lua's own
                // tablet:resetTheme can refuse with 'denied' (not high
                // command -- unreachable through this button, but not
                // through a modified client) or 'feature_disabled'
                // (Config.Features.TabletTheming off), both already
                // mapped by mutationErrorText().
                state.actionNotice = { kind: 'error', text: mutationErrorText(result) };
            }
            render();
        });
    }

    /**
     * Saves the cert-tier draft form's current working copy. Converts
     * `draft.capabilities` (a {capKey:true} SET, convenient for the
     * checkbox UI) into the ARRAY shape server/certtiers.lua's own
     * NormalizeCapabilitiesInput expects (`ipairs`-iterated) immediately
     * before sending -- the set shape never leaves this function.
     * NOT the generic runMutation() helper: a rejected save carries a
     * `field` naming which of the three inputs failed (key/label/
     * capabilities), which runMutation's own message-only handling has no
     * slot for, same reasoning as saveTheme() above.
     */
    function saveCertTierDraft() {
        if (state.pendingAction || !state.certTierDraft) return;
        var draft = state.certTierDraft;
        var capabilities = [];
        for (var capKey in draft.capabilities) {
            if (Object.prototype.hasOwnProperty.call(draft.capabilities, capKey) && draft.capabilities[capKey] === true) {
                capabilities.push(capKey);
            }
        }

        state.pendingAction = true;
        state.certTierFieldError = null;
        state.actionNotice = { kind: 'ok', text: S('action_working') };
        render();

        fetchNui('tablet:certTiersUpsert', { key: draft.key, label: draft.label, capabilities: capabilities }).then(function (result) {
            state.pendingAction = false;
            if (result && result.ok === true) {
                state.certTiers = Array.isArray(result.tiers) ? result.tiers : state.certTiers;
                if (result.capabilityCatalog && typeof result.capabilityCatalog === 'object') state.certTierCapabilityCatalog = result.capabilityCatalog;
                state.certTierDraft = null;
                state.actionNotice = { kind: 'ok', text: S('action_succeeded') };
            } else {
                state.certTierFieldError = certTierFieldFromError(result && result.error);
                state.actionNotice = { kind: 'error', text: certTierErrorText(result) };
            }
            render();
        });
    }

    /**
     * Swaps tier `index` with its immediate neighbour (`direction` is -1
     * for up / +1 for down) and submits the FULL resulting key order --
     * server/certtiers.lua's own certTiersReorder REFUSES any partial
     * reorder (must be an exact permutation of every known tier, see its
     * own HAZARD 3), so this always sends every key, never just the two
     * that moved. A no-op past either end of the list (nothing to swap
     * with) -- also enforced by each row's own `disabled` state in
     * buildCertTierRow, this is the real, server-call-blocking guard,
     * that being a convenience only.
     * @param {number} index @param {number} direction -1 | 1
     */
    function moveCertTier(index, direction) {
        if (state.pendingAction || !state.certTiers) return;
        var targetIndex = index + direction;
        if (targetIndex < 0 || targetIndex >= state.certTiers.length) return;

        var orderedKeys = [];
        for (var i = 0; i < state.certTiers.length; i++) orderedKeys.push(state.certTiers[i].key);
        var moved = orderedKeys[index];
        orderedKeys[index] = orderedKeys[targetIndex];
        orderedKeys[targetIndex] = moved;

        state.pendingAction = true;
        state.certTierWarning = null;
        state.actionNotice = { kind: 'ok', text: S('action_working') };
        render();

        fetchNui('tablet:certTiersReorder', { orderedKeys: orderedKeys }).then(function (result) {
            state.pendingAction = false;
            if (result && result.ok === true) {
                state.certTiers = Array.isArray(result.tiers) ? result.tiers : state.certTiers;
                // Non-optional per server/certtiers.lua's own HAZARD 3 --
                // ALWAYS present on a successful reorder; forwarded as-is
                // regardless, so a future wording change needs no client
                // edit.
                state.certTierWarning = (typeof result.warning === 'string' && result.warning.length > 0) ? result.warning : null;
                state.actionNotice = { kind: 'ok', text: S('action_succeeded') };
            } else {
                state.actionNotice = { kind: 'error', text: certTierErrorText(result) };
            }
            render();
        });
    }

    /**
     * Deletes tier `key`. A REFUSAL (tier_in_use -- still referenced by at
     * least one k9_certifications row; protected_tier -- 'certified',
     * unconditionally) is rendered INLINE on that tier's own row
     * (state.certTierActionError) as "cannot, and here is why", per this
     * task's own explicit instruction, alongside the same text in the
     * generic top-of-panel notice for visibility.
     * @param {string} key
     */
    function deleteCertTier(key) {
        if (state.pendingAction) return;
        state.pendingAction = true;
        state.certTierActionError = null;
        state.actionNotice = { kind: 'ok', text: S('action_working') };
        render();

        fetchNui('tablet:certTiersDelete', { key: key }).then(function (result) {
            state.pendingAction = false;
            if (result && result.ok === true) {
                state.certTiers = Array.isArray(result.tiers) ? result.tiers : state.certTiers;
                state.actionNotice = { kind: 'ok', text: S('action_succeeded') };
            } else {
                var text = certTierErrorText(result);
                state.certTierActionError = { key: key, text: text };
                state.actionNotice = { kind: 'error', text: text };
            }
            render();
        });
    }

    /**
     * Saves the shop-location draft form -- either creating a brand-new
     * location (draft.key === null, via tablet:equipmentShopAddLocation)
     * or editing an existing runtime one's metadata (via
     * tablet:equipmentShopMoveLocation's `updates` shape). NOT the generic
     * runMutation() helper: this page never optimistically mutates its own
     * shopLocations map for anything other than the server's own returned
     * `locations` (same "re-pull the authoritative version" posture as
     * every other mutation on this page), and needs its OWN post-success
     * handling (close the draft) rather than a generic reload callback.
     *
     * A blank field means two DIFFERENT things depending on isNew -- see
     * client/tablet.lua's own tablet:equipmentShopAddLocation/
     * MoveLocation doc comments for the full reasoning:
     *   - Add (isNew): OMITTED entirely (empty string is never sent) --
     *     "inherit the shop-wide default".
     *   - Edit: sent as `false` -- "reset this field back to the shop-wide
     *     default", since an edit draft always starts pre-filled from a
     *     real, already-resolved value (label/model are never blank; a
     *     blank scenario CAN legitimately mean "already resolved to no
     *     scenario" -- sending `false` for one that is already blank is a
     *     harmless no-op either way), so a blank field here is always
     *     either a DELIBERATE clear or a value that was already effectively
     *     the default, never silent data loss.
     */
    function saveShopLocationDraft() {
        if (state.pendingAction || !state.shopLocationDraft) return;
        var draft = state.shopLocationDraft;
        var isNew = draft.key === null;

        state.pendingAction = true;
        state.actionNotice = { kind: 'ok', text: S('action_working') };
        render();

        var nuiName, payload;
        if (isNew) {
            payload = {};
            if (draft.label.trim().length > 0) payload.label = draft.label.trim();
            if (draft.model.trim().length > 0) payload.model = draft.model.trim();
            if (draft.scenario.trim().length > 0) payload.scenario = draft.scenario.trim();
            nuiName = 'tablet:equipmentShopAddLocation';
        } else {
            var toUpdateValue = function (value) {
                var trimmed = value.trim();
                return trimmed.length > 0 ? trimmed : false;
            };
            payload = {
                locationKey: draft.key,
                updates: {
                    label: toUpdateValue(draft.label),
                    model: toUpdateValue(draft.model),
                    scenario: toUpdateValue(draft.scenario),
                },
            };
            nuiName = 'tablet:equipmentShopMoveLocation';
        }

        fetchNui(nuiName, payload).then(function (result) {
            state.pendingAction = false;
            if (result && result.ok === true) {
                if (result.locations && typeof result.locations === 'object') state.shopLocations = result.locations;
                state.shopLocationDraft = null;
                state.actionNotice = { kind: 'ok', text: S('action_succeeded') };
            } else {
                state.actionNotice = { kind: 'error', text: shopLocationErrorText(result) };
            }
            render();
        });
    }

    /**
     * "Move Here" -- repositions an EXISTING runtime location to the
     * operator's own CURRENT in-game position. `useCurrentPosition: true`
     * is the ONLY thing sent for coordinates -- this page has no native
     * access to GetEntityCoords at all; client/tablet.lua captures the
     * real values at the moment this callback fires (see that file's own
     * tablet:equipmentShopMoveLocation doc comment).
     * @param {string} key
     */
    function moveShopLocationHere(key) {
        if (state.pendingAction) return;
        state.pendingAction = true;
        state.shopLocationActionError = null;
        state.actionNotice = { kind: 'ok', text: S('action_working') };
        render();

        fetchNui('tablet:equipmentShopMoveLocation', { locationKey: key, useCurrentPosition: true }).then(function (result) {
            state.pendingAction = false;
            if (result && result.ok === true) {
                if (result.locations && typeof result.locations === 'object') state.shopLocations = result.locations;
                state.actionNotice = { kind: 'ok', text: S('action_succeeded') };
            } else {
                var text = shopLocationErrorText(result);
                state.shopLocationActionError = { key: key, text: text };
                state.actionNotice = { kind: 'error', text: text };
            }
            render();
        });
    }

    /** Deletes runtime location `key`. A refusal renders INLINE on that
     * row (state.shopLocationActionError), same "cannot, and here is why"
     * convention as deleteCertTier() above.
     * @param {string} key */
    function removeShopLocation(key) {
        if (state.pendingAction) return;
        state.pendingAction = true;
        state.shopLocationActionError = null;
        state.actionNotice = { kind: 'ok', text: S('action_working') };
        render();

        fetchNui('tablet:equipmentShopRemoveLocation', { locationKey: key }).then(function (result) {
            state.pendingAction = false;
            if (result && result.ok === true) {
                if (result.locations && typeof result.locations === 'object') state.shopLocations = result.locations;
                state.actionNotice = { kind: 'ok', text: S('action_succeeded') };
            } else {
                var text = shopLocationErrorText(result);
                state.shopLocationActionError = { key: key, text: text };
                state.actionNotice = { kind: 'error', text: text };
            }
            render();
        });
    }

    /**
     * Toggles feature `name` to `newValue` -- NOT the generic runMutation()
     * helper: this page never optimistically mutates its own runtimeFeatures
     * copy (the response carries no full, refreshed list the way
     * certTiersUpsert's own `tiers` does), so a successful set/reset always
     * re-pulls via loadRuntimeFeatures() instead, same "re-pull the
     * authoritative version" posture as saveShopLocationDraft() above.
     *
     * THE HONESTY REQUIREMENT, satisfied AFTER the click too: the post-action
     * notice reuses the SAME tier description already shown on the row
     * BEFORE this was pressed (the `tier` argument here is this row's own,
     * already-known tier -- never trusted from the mutation response, since
     * server/runtimecontrol.lua's own runtimeResetFeature always reports
     * `restartRequired = false` regardless of tier, a known asymmetry
     * flagged to main rather than relied upon here).
     * @param {string} name @param {boolean} newValue @param {string} tier
     * @param {string} [confirm] -- REQUIRED, and must equal `name` EXACTLY,
     * for a `lockoutRisk` feature (see buildRuntimeLockoutConfirmPanel()/
     * confirmRuntimeLockoutAction() above) -- omitted entirely for every
     * other feature, so the request body carries no `confirm` key at all
     * (matches client/tablet.lua's own "ignored entirely" contract for a
     * non-lockout-risk feature). THIS FUNCTION NEVER DECIDES AUTHORIZATION:
     * it forwards whatever the caller already confirmed, exactly as given,
     * and the server re-checks the match independently regardless.
     */
    function toggleRuntimeFeature(name, newValue, tier, confirm) {
        if (state.pendingAction) return;
        state.pendingAction = true;
        state.runtimeFeatureActionError = null;
        state.actionNotice = { kind: 'ok', text: S('action_working') };
        render();

        var payload = { name: name, value: newValue };
        if (confirm !== undefined) payload.confirm = confirm;

        fetchNui('tablet:runtimeSetFeature', payload).then(function (result) {
            state.pendingAction = false;
            if (result && result.ok === true) {
                // Only close a lockout confirmation panel that is still
                // open for THIS SAME feature -- never someone else's.
                if (state.runtimeLockoutConfirm && state.runtimeLockoutConfirm.name === name) state.runtimeLockoutConfirm = null;
                state.actionNotice = { kind: 'ok', text: withServerNote(runtimeTierDescription(tier), result) };
                loadRuntimeFeatures();
            } else {
                var text = runtimeFeatureErrorText(result);
                state.runtimeFeatureActionError = { key: name, text: text };
                state.actionNotice = { kind: 'error', text: text };
                render();
            }
        });
    }

    /** Restores feature `name` to its config.lua-shipped default -- a
     * destructive action from an operator's point of view (discards an
     * override), hence mkConfirmButton's two-click guard at its own call
     * site, same posture as resetThemeToDefault()/deleteCertTier() above
     * (or, for a `lockoutRisk` feature, the read-and-type panel instead --
     * see buildRuntimeFeatureRow()).
     * @param {string} name @param {string} tier -- this row's own,
     * already-known tier, see toggleRuntimeFeature()'s own doc comment on
     * why the response is not trusted for this.
     * @param {string} [confirm] -- see toggleRuntimeFeature()'s own doc
     * comment -- identical contract. */
    function resetRuntimeFeature(name, tier, confirm) {
        if (state.pendingAction) return;
        state.pendingAction = true;
        state.runtimeFeatureActionError = null;
        state.actionNotice = { kind: 'ok', text: S('action_working') };
        render();

        var payload = { name: name };
        if (confirm !== undefined) payload.confirm = confirm;

        fetchNui('tablet:runtimeResetFeature', payload).then(function (result) {
            state.pendingAction = false;
            if (result && result.ok === true) {
                if (state.runtimeLockoutConfirm && state.runtimeLockoutConfirm.name === name) state.runtimeLockoutConfirm = null;
                state.actionNotice = { kind: 'ok', text: withServerNote(runtimeTierDescription(tier), result) };
                loadRuntimeFeatures();
            } else {
                var text = runtimeFeatureErrorText(result);
                state.runtimeFeatureActionError = { key: name, text: text };
                state.actionNotice = { kind: 'error', text: text };
                render();
            }
        });
    }

    /**
     * Saves the inline number-editor's current working copy for ONE
     * tunable. Only a basic "is this even parseable as a number" guard is
     * applied HERE (see this file's header NUI CONTRACT note) -- the real
     * [min,max]/integer check is server/runtimecontrol.lua's own
     * runtimeSetTunable, whose exact bounds are echoed back verbatim on a
     * rejection (see runtimeTunableErrorText() above) rather than guessed
     * or re-derived client-side.
     * @param {{key:string}} tunable
     */
    function saveRuntimeTunableDraft(tunable) {
        if (state.pendingAction || !state.runtimeTunableDraft || state.runtimeTunableDraft.key !== tunable.key) return;

        var numericValue = parseFloat(state.runtimeTunableDraft.value);
        if (!isFinite(numericValue)) {
            state.runtimeTunableFieldError = { key: tunable.key, text: S('runtime_tunable_error_not_a_number') };
            render();
            return;
        }

        state.pendingAction = true;
        state.runtimeTunableFieldError = null;
        state.actionNotice = { kind: 'ok', text: S('action_working') };
        render();

        fetchNui('tablet:runtimeSetTunable', { key: tunable.key, value: numericValue }).then(function (result) {
            state.pendingAction = false;
            if (result && result.ok === true) {
                state.runtimeTunableDraft = null;
                state.actionNotice = { kind: 'ok', text: S('action_succeeded') };
                loadRuntimeTunables();
            } else {
                var text = runtimeTunableErrorText(result);
                state.runtimeTunableFieldError = { key: tunable.key, text: text };
                state.actionNotice = { kind: 'error', text: text };
                render();
            }
        });
    }

    /** Restores tunable `key` to its config.lua-shipped default -- same
     * two-click destructive-action posture as resetRuntimeFeature() above.
     * @param {string} key */
    function resetRuntimeTunable(key) {
        if (state.pendingAction) return;
        state.pendingAction = true;
        state.runtimeTunableFieldError = null;
        state.actionNotice = { kind: 'ok', text: S('action_working') };
        render();

        fetchNui('tablet:runtimeResetTunable', { key: key }).then(function (result) {
            state.pendingAction = false;
            if (result && result.ok === true) {
                state.actionNotice = { kind: 'ok', text: S('action_succeeded') };
                loadRuntimeTunables();
            } else {
                var text = runtimeTunableErrorText(result);
                state.runtimeTunableFieldError = { key: key, text: text };
                state.actionNotice = { kind: 'error', text: text };
                render();
            }
        });
    }

    /** @returns {number} the REAL effective ceiling server/admin.lua
     * enforces (that file's own HARD_MAX_RESULTS), learned from the `cap`
     * field of the most recent successful tabletAudit* response
     * (state.auditServerCap) -- falls back to AUDIT_LIMIT_MAX_FALLBACK's
     * hardcoded guess ONLY before any query has ever succeeded this
     * session, or if a response is ever missing `cap` entirely (a server
     * build predating this pass). See AUDIT_LIMIT_MAX_FALLBACK's own
     * comment for why that fallback is never assumed correct once a real
     * value is known, and this file's header NUI CONTRACT note on
     * tablet:auditCert/Partner/Search/Xp/Dept for where `cap` comes from. */
    function auditEffectiveCap() {
        return (typeof state.auditServerCap === 'number' && isFinite(state.auditServerCap) && state.auditServerCap >= AUDIT_LIMIT_MIN)
            ? state.auditServerCap
            : AUDIT_LIMIT_MAX_FALLBACK;
    }

    /** @param {*} value @returns {number} floored + clamped into
     * [AUDIT_LIMIT_MIN, auditEffectiveCap()]. Never lets an unclamped value
     * reach fetchNui(), even though server/admin.lua's own ClampLimit would
     * independently catch it anyway -- this page's own "make the UI agree
     * with what the server enforces" duty, per this task's instruction.
     * `Number('')` is NaN, `Number(undefined)` is NaN, `Math.floor(NaN)` is
     * NaN, and `NaN < x`/`NaN > x` are both false for any x -- so a
     * blank/garbage input falls through both clamp branches below unless
     * caught first, exactly the failure shape server/admin.lua's own
     * ClampLimit doc comment names for the identical reason; guarded here
     * the same way, once, via `isFinite`. */
    function clampAuditLimit(value) {
        var n = Math.floor(Number(value));
        var max = auditEffectiveCap();
        if (!isFinite(n)) return AUDIT_LIMIT_MIN;
        if (n < AUDIT_LIMIT_MIN) return AUDIT_LIMIT_MIN;
        if (n > max) return max;
        return n;
    }

    /**
     * Submits the CURRENT audit form's fields to whichever tabletAudit*
     * callback state.auditMode selects. The blank-required-field checks
     * below are a UX CONVENIENCE ONLY, per THE SECURITY RULE -- they
     * synthesize the SAME `{error: 'invalid_args'}` shape server/admin.lua's
     * own IsValidCitizenId/IsValidDepartment/VALID_SEARCH_LOG_MODES would
     * refuse with anyway, rendered through the exact same auditErrorText(),
     * purely to avoid a pointless round trip for an obviously-incomplete
     * form -- a modified client skipping this check entirely still gets
     * refused, just one network hop later, by the real gate.
     * STALE-RESPONSE GUARD: same request-id shape as
     * shopLocationsRequestId/runtimeFeaturesRequestId elsewhere on this
     * page -- an officer can switch mode or press Run Query again while an
     * earlier query is still in flight; only the MOST RECENTLY issued
     * request's response is ever applied.
     */
    function runAuditQuery() {
        if (state.auditLoading || !state.auditEnabled) return;

        var limit = clampAuditLimit(state.auditLimit);
        state.auditLimit = limit; // reflect the clamp back into the input itself, so a typed 500 visibly becomes 100, never silently

        var name, payload, catalogName;
        switch (state.auditMode) {
            case 'cert':
            case 'partner': {
                var certOrPartnerId = state.auditCitizenId.trim();
                if (certOrPartnerId.length === 0) {
                    state.auditError = { error: 'invalid_args' };
                    render();
                    return;
                }
                name = (state.auditMode === 'cert') ? 'tablet:auditCert' : 'tablet:auditPartner';
                payload = { targetCitizenId: certOrPartnerId, limit: limit };
                break;
            }
            case 'xp': {
                var xpId = state.auditCitizenId.trim();
                if (xpId.length === 0) {
                    state.auditError = { error: 'invalid_args' };
                    render();
                    return;
                }
                name = 'tablet:auditXp';
                payload = { targetCitizenId: xpId };
                break;
            }
            case 'dept': {
                var dept = state.auditDepartment.trim();
                if (dept.length === 0) {
                    state.auditError = { error: 'invalid_args' };
                    render();
                    return;
                }
                name = 'tablet:auditDept';
                payload = { departmentKey: dept, limit: limit };
                break;
            }
            case 'search': {
                var searchMode = state.auditSearchMode;
                var searchValue = state.auditSearchValue.trim();
                if (searchMode !== 'recent' && searchValue.length === 0) {
                    state.auditError = { error: 'invalid_args' };
                    render();
                    return;
                }
                name = 'tablet:auditSearch';
                payload = { mode: searchMode, limit: limit };
                if (searchMode !== 'recent') payload.value = searchValue;
                break;
            }
            case 'catalog': {
                // No blank-field check here, unlike every branch above --
                // state.auditCatalogName always holds a real value from
                // AUDIT_CATALOG_NAMES (the <select> in buildAuditForm()
                // always has one selected; there is no free-text/blank
                // state for this field to be in), so there is nothing to
                // reject client-side before the round trip.
                catalogName = state.auditCatalogName;
                name = 'tablet:auditCatalog';
                payload = { catalogName: catalogName, limit: limit };
                break;
            }
            default:
                return;
        }

        state.auditLoading = true;
        state.auditError = null;
        var requestId = ++state.auditRequestId;
        render();

        fetchNui(name, payload).then(function (result) {
            if (requestId !== state.auditRequestId) return; // STALE-RESPONSE GUARD -- a newer query has since been issued

            state.auditLoading = false;
            if (!result || result.ok !== true) {
                state.auditError = result || { error: 'unknown_error' };
                state.auditResult = null;
                render();
                return;
            }
            // Server-reported effective cap (server/admin.lua's own
            // HARD_MAX_RESULTS) -- learned here so the NEXT render's limit
            // input/clamp reflects the REAL ceiling rather than this page's
            // own AUDIT_LIMIT_MAX_FALLBACK guess. Absent on a response from
            // a server build predating this field -- silently keeps
            // whatever was already known (or the fallback) rather than
            // clobbering a good value with an invalid one.
            if (typeof result.cap === 'number' && isFinite(result.cap) && result.cap >= AUDIT_LIMIT_MIN) {
                state.auditServerCap = result.cap;
            }
            state.auditResult = {
                rows: Array.isArray(result.rows) ? result.rows : [],
                label: (typeof result.label === 'string') ? result.label : '',
                // TRUNCATION (this pass) -- see auditTruncatedText() above.
                // `truncated`/`actualLimit` are the server's OWN account of
                // what happened to THIS request; `requestedLimit` is the
                // `limit` THIS PAGE sent for it (closured from above --
                // always defined, even for 'xp', which simply never sets
                // `truncated` true since server/admin.lua's tabletAuditXp
                // never reports it).
                truncated: result.truncated === true,
                requestedLimit: limit,
                actualLimit: (typeof result.limit === 'number') ? result.limit : null,
                // Which catalog produced THESE rows (closured from the
                // request that produced this exact response, same "never
                // re-derived from CURRENT state" reasoning as
                // requestedLimit above) -- undefined for every mode except
                // 'catalog'. buildAuditResultTable() needs this because,
                // unlike every other mode, 'catalog' rows have a DIFFERENT
                // column shape per catalogName, not one fixed shape for
                // the whole mode -- state.auditMode alone is not enough to
                // pick auditColumnsForCatalog()'s own column set.
                catalogName: catalogName,
            };
            render();
        });
    }

    /** Fetched fresh every time the XP Ranks tab is opened (see
     * buildTabs()) -- NEVER a hardcoded list, same posture as
     * loadCertTiers()/loadPermissionKeys() above: the four-rank ladder is
     * Config.XPTiers shipped defaults merged with k9_xp_tiers database
     * overrides (database wins, per server/xptiers.lua's own header), and
     * high command can retune any rank at runtime -- a list captured once
     * here would already be stale the moment anyone does. High command
     * only (server/xptiers.lua's own CanManageXPTiers re-verifies this on
     * every one of the two callbacks regardless of whether this ever
     * loads). */
    function loadXpTiers() {
        state.xpTiersLoading = true;
        state.xpTiersError = null;
        render();

        fetchNui('tablet:xpTiersList', {}).then(function (result) {
            state.xpTiersLoading = false;
            if (!result || result.ok !== true) {
                state.xpTiersError = result || { error: 'unknown_error' };
                render();
                return;
            }
            state.xpTiers = Array.isArray(result.tiers) ? result.tiers : [];
            render();
        });
    }

    /** @param {object|undefined} result @returns {string} */
    function xpTierErrorText(result) {
        if (!result) return S('action_failed');
        if (typeof result.message === 'string' && result.message.length > 0) return result.message;
        switch (result.error) {
            case 'denied': return S('xp_tier_error_denied');
            case 'rate_limited': return S('xp_tier_error_rate_limited');
            case 'busy': return S('xp_tier_error_busy');
            case 'invalid_ordinal': return S('xp_tier_error_invalid_ordinal');
            case 'invalid_xp': return S('xp_tier_error_invalid_xp');
            // A REFUSAL ("cannot, and here is why" -- rank 1 must always be
            // exactly 0 XP), not a generic failure -- per this task's own
            // instruction, same posture as certTierErrorText's own
            // 'protected_tier'/'tier_in_use' above.
            case 'base_tier_xp_fixed': return S('xp_tier_error_base_tier_xp_fixed');
            case 'invalid_label': return S('xp_tier_error_invalid_label');
            case 'invalid_speed_multiplier': return S('xp_tier_error_invalid_speed_multiplier');
            case 'invalid_scent_range_multiplier': return S('xp_tier_error_invalid_scent_range_multiplier');
            case 'invalid_medkit_cooldown_multiplier': return S('xp_tier_error_invalid_medkit_cooldown_multiplier');
            case 'invalid_badge': return S('xp_tier_error_invalid_badge');
            case 'invalid_order': return S('xp_tier_error_invalid_order');
            case 'db_error': return S('xp_tier_error_db_error');
            case 'invalid_payload': return S('xp_tier_error_invalid_payload');
            case 'timeout': return S('error_timeout');
            case 'network_error': return S('error_network');
            default: return S('action_failed');
        }
    }

    /** @param {string|undefined} errorCode @returns {string|null} */
    function xpTierFieldFromError(errorCode) {
        if (errorCode === 'invalid_xp' || errorCode === 'base_tier_xp_fixed') return 'xp';
        if (errorCode === 'invalid_label') return 'label';
        if (errorCode === 'invalid_speed_multiplier') return 'speedMultiplier';
        if (errorCode === 'invalid_scent_range_multiplier') return 'scentRangeMultiplier';
        if (errorCode === 'invalid_medkit_cooldown_multiplier') return 'medkitCooldownMultiplier';
        if (errorCode === 'invalid_badge') return 'badge';
        return null;
    }

    /** Opens a draft pre-filled from an EXISTING rank row -- a COPY of its
     * own values, never the live object, so cancelling never mutates
     * state.xpTiers. Numeric fields are stored as STRINGS in the draft
     * (same posture as state.runtimeTunableDraft.value above) so a
     * partially-typed value never gets silently coerced mid-edit.
     * @param {object} tier */
    function openXpTierEditDraft(tier) {
        state.xpTierDraft = {
            ordinal: tier.ordinal,
            xp: String(tier.xp),
            label: tier.label,
            speedMultiplier: String(tier.speedMultiplier),
            scentRangeMultiplier: String(tier.scentRangeMultiplier),
            medkitCooldownMultiplier: (tier.medkitCooldownMultiplier === undefined || tier.medkitCooldownMultiplier === null) ? '' : String(tier.medkitCooldownMultiplier),
            badge: (typeof tier.badge === 'string') ? tier.badge : '',
            xpLocked: tier.xpLocked === true,
        };
        state.xpTierFieldError = null;
        state.xpTierActionError = null;
        render();
    }

    function closeXpTierDraft() {
        state.xpTierDraft = null;
        state.xpTierFieldError = null;
        state.xpTierActionError = null;
        render();
    }

    /** Mirrors server/xptiers.lua's own IsSafeShortString exactly -- a UX
     * convenience only (THE SECURITY RULE): catches an obviously-invalid
     * label/badge before a round trip, but the server's own identical
     * check is what actually matters; this page's own check being wrong in
     * either direction only ever costs an extra network round trip, never
     * a false sense of safety.
     * @param {*} value @param {number} maxLen @returns {boolean} */
    function isSafeShortStringForXpTier(value, maxLen) {
        if (typeof value !== 'string') return false;
        var len = value.length;
        if (len === 0 || len > maxLen) return false;
        if (/[<>&"'`\r\n\t]/.test(value)) return false;
        for (var i = 0; i < len; i++) {
            var code = value.charCodeAt(i);
            if (code < 0x20 || code === 0x7F) return false;
        }
        return true;
    }

    /** Sets the field-highlight/row-inline/top-banner error trio for the
     * CURRENTLY open xp-tier draft in one place -- shared by every
     * client-side pre-check branch in saveXpTierDraft() below AND its own
     * server-rejection branch, so a pre-check failure and a server refusal
     * for the SAME reason render byte-identically.
     * @param {string} field @param {string} text */
    function failXpTierDraft(field, text) {
        state.xpTierFieldError = field;
        state.xpTierActionError = { ordinal: state.xpTierDraft.ordinal, text: text };
        state.actionNotice = { kind: 'error', text: text };
        render();
    }

    /**
     * Saves the xp-rank draft form's current working copy. Every check
     * below mirrors server/xptiers.lua's own validators
     * (IsValidXpThreshold/IsSafeShortString/IsValidMultiplier/
     * IsStrictlyAscending) as a UX CONVENIENCE ONLY -- THE SECURITY RULE:
     * the server independently re-validates every one of these fields
     * against the CURRENT LIVE ladder (not this page's own possibly-stale
     * state.xpTiers) before writing anything, so a modified client sending
     * an out-of-range value straight to tablet:xpTiersUpsert is refused
     * there regardless of what this function does or does not catch first.
     * NOT the generic runMutation() helper: a rejected save carries a
     * `field` naming which of the six inputs failed, which runMutation's
     * own message-only handling has no slot for, same reasoning as
     * saveCertTierDraft()/saveTheme() above.
     */
    function saveXpTierDraft() {
        if (state.pendingAction || !state.xpTierDraft) return;
        var draft = state.xpTierDraft;

        // xp -- SKIPPED entirely for a locked rank (rank 1): always
        // submitted as 0, never this field's own (disabled, unreachable)
        // value. See server/xptiers.lua's own header "SCOPE DECISION"
        // point 1.
        var xp = 0;
        if (!draft.xpLocked) {
            var xpNum = Number(draft.xp);
            if (!isFinite(xpNum) || xpNum < 0 || Math.floor(xpNum) !== xpNum) {
                failXpTierDraft('xp', S('xp_tier_error_invalid_xp'));
                return;
            }
            xp = xpNum;
        }

        if (!isSafeShortStringForXpTier(draft.label, 60)) {
            failXpTierDraft('label', S('xp_tier_error_invalid_label'));
            return;
        }

        var speedMultiplier = Number(draft.speedMultiplier);
        if (!isFinite(speedMultiplier) || speedMultiplier <= 0 || speedMultiplier > XP_TIER_MAX_SPEED_SCENT_MULTIPLIER) {
            failXpTierDraft('speedMultiplier', S('xp_tier_error_invalid_speed_multiplier'));
            return;
        }

        var scentRangeMultiplier = Number(draft.scentRangeMultiplier);
        if (!isFinite(scentRangeMultiplier) || scentRangeMultiplier <= 0 || scentRangeMultiplier > XP_TIER_MAX_SPEED_SCENT_MULTIPLIER) {
            failXpTierDraft('scentRangeMultiplier', S('xp_tier_error_invalid_scent_range_multiplier'));
            return;
        }

        // OPTIONAL -- blank means "omit entirely" (server treats a missing
        // field as "not configured"), same posture as
        // savePermissionKeyDraft()'s own description field above.
        var medkitCooldownMultiplier;
        var medkitRaw = (typeof draft.medkitCooldownMultiplier === 'string') ? draft.medkitCooldownMultiplier.trim() : '';
        if (medkitRaw.length > 0) {
            var medkitNum = Number(medkitRaw);
            if (!isFinite(medkitNum) || medkitNum <= 0 || medkitNum > XP_TIER_MAX_MEDKIT_COOLDOWN_MULTIPLIER) {
                failXpTierDraft('medkitCooldownMultiplier', S('xp_tier_error_invalid_medkit_cooldown_multiplier'));
                return;
            }
            medkitCooldownMultiplier = medkitNum;
        }

        // OPTIONAL -- same "blank means omit" posture as
        // medkitCooldownMultiplier immediately above.
        var badge;
        var badgeRaw = (typeof draft.badge === 'string') ? draft.badge.trim() : '';
        if (badgeRaw.length > 0) {
            if (!isSafeShortStringForXpTier(badgeRaw, 30)) {
                failXpTierDraft('badge', S('xp_tier_error_invalid_badge'));
                return;
            }
            badge = badgeRaw;
        }

        // THE WALK-INTO-INVALID-STATE HAZARD, client-side mirror -- see
        // server/xptiers.lua's own header of the identical name. Built
        // from state.xpTiers (this page's own LAST KNOWN live ladder, not
        // necessarily still current -- another high-command session could
        // have edited a different rank since this page's last load), so
        // this check can occasionally be wrong in EITHER direction; the
        // server's own re-check against the ACTUAL current ladder inside
        // its mutex-held critical section is what actually decides, this
        // is purely to avoid an obviously-doomed round trip for the common
        // single-editor case.
        if (Array.isArray(state.xpTiers)) {
            var thresholds = state.xpTiers.map(function (t) { return (t.ordinal === draft.ordinal) ? xp : t.xp; });
            for (var i = 1; i < thresholds.length; i++) {
                if (!(thresholds[i] > thresholds[i - 1])) {
                    failXpTierDraft('xp', S('xp_tier_error_invalid_order'));
                    return;
                }
            }
        }

        state.pendingAction = true;
        state.xpTierFieldError = null;
        state.xpTierActionError = null;
        state.actionNotice = { kind: 'ok', text: S('action_working') };
        render();

        var payload = {
            ordinal: draft.ordinal, xp: xp, label: draft.label,
            speedMultiplier: speedMultiplier, scentRangeMultiplier: scentRangeMultiplier,
        };
        if (medkitCooldownMultiplier !== undefined) payload.medkitCooldownMultiplier = medkitCooldownMultiplier;
        if (badge !== undefined) payload.badge = badge;

        fetchNui('tablet:xpTiersUpsert', payload).then(function (result) {
            state.pendingAction = false;
            if (result && result.ok === true) {
                state.xpTiers = Array.isArray(result.tiers) ? result.tiers : state.xpTiers;
                // Non-optional whenever this edit demoted at least one
                // currently-connected K9 -- server/xptiers.lua's own header
                // "THE ALREADY-PROMOTED PLAYER". Forwarded as-is regardless,
                // so a future wording change needs no client edit, same
                // posture as moveCertTier()'s own certTierWarning above.
                state.xpTierWarning = (typeof result.warning === 'string' && result.warning.length > 0) ? result.warning : null;
                state.xpTierDraft = null;
                state.actionNotice = { kind: 'ok', text: S('action_succeeded') };
                render();
            } else {
                var text = xpTierErrorText(result);
                state.xpTierFieldError = xpTierFieldFromError(result && result.error);
                state.xpTierActionError = { ordinal: draft.ordinal, text: text };
                state.actionNotice = { kind: 'error', text: text };
                render();
            }
        });
    }

    // ------------------------------------------------------------------
    // OPEN / CLOSE
    // ------------------------------------------------------------------

    function handleOpen(data) {
        data = data || {};
        state.open = true;
        state.strings = (data.strings && typeof data.strings === 'object') ? data.strings : {};
        state.capabilities = (data.capabilities && typeof data.capabilities === 'object') ? data.capabilities : {};
        // See this file's header NUI CONTRACT note on `requestedView` --
        // presentation hint only, consumed once by loadMyRecord() below
        // (called a few lines down this same function) once the server's
        // own viewer fields for this caller are known. Defaults to 'auto'
        // (every ordinary open -- command/item/radial all send no explicit
        // value, or 'auto' outright) rather than null: the single command
        // now auto-routes a qualifying caller to the console on its own,
        // see loadMyRecord()'s own comment.
        state.requestedView = data.requestedView === 'highCommand' ? 'highCommand' : 'auto';
        state.maxXpPerGrant = typeof data.maxXpPerGrant === 'number' ? data.maxXpPerGrant : null;
        state.peds = Array.isArray(data.peds) ? data.peds : [];
        state.specializations = (data.specializations && typeof data.specializations === 'object') ? data.specializations : {};
        state.themingEnabled = data.themingEnabled === true;
        state.shopLocationsEnabled = data.shopLocationsEnabled === true;
        state.runtimeControlEnabled = data.runtimeControlEnabled === true;
        state.auditEnabled = data.auditEnabled === true;
        state.branding = (data.branding && typeof data.branding === 'object') ? data.branding : {};

        // First-open ONLY, cosmetic seeding -- see applyBrandingSeedTheme()'s
        // own comment: gives this page an immediately correct-looking
        // palette before tablet:getTheme's real, authoritative response
        // (loaded a few lines below) has had a chance to land, WITHOUT ever
        // overwriting an already-loaded/edited theme on a later re-open.
        if (!state.theme) applyBrandingSeedTheme();

        // Fresh baseline every open -- never show stale data from a
        // previous session (see this file's header contract note on
        // tablet:close resetting state; opening does the same reset, since
        // either one could be the first message this page ever sees after
        // a long idle period with a job/grant change in between).
        // DEFAULT SCREEN IS 'home' (this pass) -- see buildHomeScreen()'s
        // own header for why the landing view now comes before every
        // existing tab, including 'my_record'. requestedView === 'highCommand'
        // (handled a few lines below by loadMyRecord()) still overrides this
        // to 'console' for a genuine high-command caller, exactly as it
        // already overrode the previous 'my_record' default.
        state.screen = 'home';
        // STALE-LOCK FIX (this pass, focus-and-state audit finding #3) --
        // state.pendingAction disables nearly every action button on this
        // page while a mutation/trigger fetch is in flight (see its own
        // declaration comment below). handleClose() only ever sets
        // state.open = false -- it never touched this flag -- so closing
        // the tablet mid-action (Escape, death, a K9 takedown, the Close
        // button) and reopening it left every control dead until the
        // ORIGINAL, now-irrelevant request's promise finally settled (or
        // AwaitServerCallback's own synthetic timeout fired), even though
        // the fetch that set it belongs to a session the operator already
        // left. A fresh open is a fresh start for every OTHER piece of
        // per-session state reset in this block; this flag was simply
        // missed. See html/tests/tablet_open_close_spec.js's own
        // regression test for the exact repro this fixes.
        state.pendingAction = false;
        state.viewer = null;
        state.myRecord = null;
        state.myRecordError = null;
        state.isK9Model = false;
        state.isPartnered = false;
        state.myPartnershipsLoading = false;
        state.myPartnershipsError = null;
        state.myPartnerships = null;
        state.partnershipsAdminLoading = false;
        state.partnershipsAdminError = null;
        state.partnershipsAdminResult = null;
        state.commandReferenceQuery = '';
        state.roster = null;
        state.rosterError = null;
        state.rosterQuery = '';
        state.onlinePlayersQuery = '';
        state.findPersonQuery = '';
        state.person = null;
        state.personSummary = null;
        state.personFeatures = null;
        state.personOpenedFrom = 'console';
        state.personnelRosterLoading = false;
        state.personnelRosterError = null;
        state.personnelRoster = null;
        state.personnelRosterSort = 'tier';
        state.personnelRosterBucket = 'k9';
        state.lastPermissionMutationAt = 0;
        state.actionNotice = null;
        state.auditMode = 'cert';
        state.auditCitizenId = '';
        state.auditDepartment = '';
        state.auditSearchMode = 'officer';
        state.auditSearchValue = '';
        state.auditCatalogName = 'certTiers';
        state.auditError = null;
        state.auditResult = null;
        // state.auditServerCap is DELIBERATELY NOT reset here -- same
        // exception, same reasoning, as state.theme just below: it is a
        // resource-wide server constant (server/admin.lua's own
        // HARD_MAX_RESULTS), not per-viewer data that could go stale
        // across a job/grant change, so forgetting it on every reopen
        // would only force this page back to guessing via
        // AUDIT_LIMIT_MAX_FALLBACK until the next query succeeds, for no
        // correctness benefit.

        // Theme is DELIBERATELY NOT reset to null/defaults here, unlike
        // everything above -- see loadTheme()'s own comment: it is applied
        // for every viewer independent of this player's own open/close
        // cycle (server/runtimecontrol.lua's PART 2 header: "applied for
        // everyone... an already-open tablet updates without the viewer
        // having to close and reopen it"), and the qbx_k9unit:client:themeUpdated
        // push already keeps it current while this page is open OR closed.
        // Resetting it here would only manufacture a visible flash back to
        // DEFAULT_THEME on every single open for no correctness benefit.
        render();
        loadMyRecord();
        loadTheme();
    }

    function handleClose() {
        state.open = false;
        render();
    }

    /** User-initiated close (Close button or Escape) -- see this file's
     * header: hides this page's own UI IMMEDIATELY and unconditionally,
     * never waiting on the tablet:close fetch's result, so a slow/failed
     * network round trip can never leave the player staring at a stuck-open
     * tablet. Also best-effort hides the parent wrapper directly (this
     * page's iframe design already relies on same-origin access to
     * window.parent for tablet-bridge.js's relay to exist at all, so this
     * is not a new assumption) -- belt-and-suspenders alongside Lua's own
     * tablet:close push, not a replacement for it: only Lua's
     * SetNuiFocus(false, false) actually restores game input. */
    function requestClose() {
        fireAndForget('tablet:close', {});
        handleClose();
        try {
            if (window.parent && window.parent.document) {
                var wrap = window.parent.document.getElementById('k9tablet-wrap');
                if (wrap && wrap.classList) wrap.classList.add('hidden');
            }
        } catch (err) {
            // Cross-origin or otherwise inaccessible -- Lua's own
            // tablet:close push (relayed back down) is still the
            // authoritative path; this is a same-tick UX nicety only.
        }
    }

    // ------------------------------------------------------------------
    // INIT
    // ------------------------------------------------------------------

    function attachEscapeHandling() {
        document.addEventListener('keydown', function (e) {
            if (!state.open) return;
            if (e && (e.key === 'Escape' || e.key === 'Esc' || e.keyCode === 27)) {
                requestClose();
                return;
            }
            // Enter-to-submit for the panel's own text/number inputs --
            // see findEnterSubmitTarget()'s own header (defined with this
            // page's other FOCUS + SCROLL CONTINUITY helpers, above
            // render()) for the full rationale and, more importantly, the
            // safety argument for why this can never fire a destructive
            // action. Kept as a second branch on this SAME listener
            // (rather than a second document-level one) so there is
            // exactly one place this page ever reads a raw keydown from.
            if (e && e.key === 'Enter') {
                handleEnterKeydown();
            }
        });
    }

    function sendReadyAck() {
        fireAndForget('tablet:ready', {});
    }

    /** qbx_k9unit:client:themeUpdated relayed push -- see client/tablet.lua's
     * own NUI CONTRACT note: fires for EVERY connected client on every
     * successful tabletSetTheme/tabletResetTheme, not only the officer who
     * triggered it, and NOT gated on this page's own open/closed state on
     * either side of the bridge -- applies live immediately, and updates the
     * theme editor's own working copy so it never overwrites the fresh
     * server value with a stale local edit the NEXT time Save is pressed.
     * @param {object} theme */
    function handleThemeUpdated(theme) {
        if (!theme || typeof theme !== 'object') return;
        state.theme = theme;
        state.themeDraft = assignShallow({}, theme);
        state.themeFieldError = null;
        applyThemeToDocument(theme);
        render();
    }

    /** qbx_k9unit:client:equipmentShopLocationsUpdated relayed push -- SAME
     * posture as handleThemeUpdated() just above: fires for EVERY connected
     * client on every successful Add/Move/RemoveLocation, not only the
     * officer who triggered it, and NOT gated on this page's own open/
     * closed state. Applied unconditionally to state.shopLocations so an
     * already-open Shop Locations screen updates live; deliberately never
     * touches state.shopLocationDraft -- an in-progress add/edit form is
     * left alone, same as the theme editor's own working copy is (there)
     * intentionally overwritten but this one is not, since a location
     * DRAFT's own key may not even be present in the pushed map yet (a new,
     * unsaved one) and forcibly closing it out from under the operator
     * would discard work in progress for no correctness benefit.
     * @param {object} locations */
    function handleShopLocationsUpdated(locations) {
        if (!locations || typeof locations !== 'object') return;
        state.shopLocations = locations;
        render();
    }

    /** qbx_k9unit:client:featureBlocksSync relayed push (THIS PASS,
     * focus-and-state audit finding #4) -- see client/tablet.lua's own NUI
     * CONTRACT note on tablet:featureBlocksSync: fires ONLY at THIS
     * client's own connection (server/permissions.lua's own
     * PushFeatureBlocksToSource never broadcasts), on join/reconnect, a
     * server-restart backfill, or a `block.<Name>` grant/revoke against
     * THIS citizenid specifically -- so an arriving push always means
     * "your own entitlements, as this tablet already knows them, may now
     * be stale", never someone else's. NOT gated on state.open, SAME
     * posture as handleThemeUpdated()/handleShopLocationsUpdated() above --
     * a no-op-looking re-fetch while hidden is still worth doing (the
     * result is ready and current the moment this page is next opened,
     * rather than only after the next such push happens to land AFTER
     * reopening).
     *
     * THE TABLET IS A VIEW. IT DECIDES NOTHING (this file's header THE
     * SECURITY RULE) -- deliberately does NOT read `blockedKeys` at all,
     * let alone try to merge it into state.myRecord.myFeatures/
     * state.personFeatures itself: client/featureblocks.lua's own twelve
     * CLIENT_ENFORCED_FEATURES are a narrower, differently-keyed catalog
     * than tablet:requestMyRecord's own server-composed `myFeatures` rows,
     * and reconciling the two client-side would be exactly the kind of
     * client-side authorization guess THE SECURITY RULE forbids. Instead
     * this simply RE-FETCHES the authoritative record -- the SAME
     * "re-pull the source of truth rather than patch state locally"
     * posture refreshPersonAndSelf()/refreshPersonFeaturesAndSelf() already
     * establish for the analogous post-mutation case -- so the Home/My
     * Record screens' abilities list catches up live instead of staying
     * stale until the next full close/reopen. If the Person screen is
     * ALSO currently open on the viewer's own citizenid (self-service via
     * "open by exact citizen ID"), that screen is refreshed the same way,
     * for the identical reason.
     * @param {Array} blockedKeys -- unused by design, see above; accepted only so this handler's signature matches the push */
    function handleFeatureBlocksSync(blockedKeys) {
        loadMyRecord();
        if (state.screen === 'person' && state.person && state.viewer && state.person.citizenid === state.viewer.citizenid) {
            loadPersonSummary(state.person.citizenid);
            loadPersonFeatures(state.person.citizenid);
        }
    }

    function init() {
        rootEl = document.getElementById('k9tablet-root');

        window.addEventListener('message', function (event) {
            var msg = event.data;
            if (!msg || typeof msg.action !== 'string') return;
            switch (msg.action) {
                case 'tablet:open':
                    handleOpen(msg.data);
                    break;
                case 'tablet:close':
                    handleClose();
                    break;
                case 'tablet:themeUpdated':
                    handleThemeUpdated(msg.data);
                    break;
                case 'tablet:equipmentShopLocationsUpdated':
                    handleShopLocationsUpdated(msg.data);
                    break;
                case 'tablet:featureBlocksSync':
                    handleFeatureBlocksSync(msg.data);
                    break;
                default:
                    break;
            }
        });

        attachEscapeHandling();
        sendReadyAck();
    }

    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', init);
    } else {
        init();
    }

    // Test-only hook -- NOT used by production code anywhere in this file,
    // and never relied upon by client/tablet.lua. Exposed solely so
    // html/tests/tablet_*.js can drive internals (triggerFeature,
    // resolveResourceName's fallback chain) that have no other externally
    // observable entry point, mirroring html/tests/sandbox.js's own
    // message-driven-only posture for app.js wherever possible and falling
    // back to this only where app.js's own IIFE truly exposes nothing
    // equivalent (this page's mutation buttons are reachable via the DOM
    // the same way a real click would drive them, so this hook is kept
    // minimal on purpose).
    if (typeof window !== 'undefined') {
        window.__k9tabletTestHook = { state: state };
    }
})();
