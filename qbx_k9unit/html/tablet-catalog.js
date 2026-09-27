/*
    qbx_k9unit/html/tablet-catalog.js

    THE TABLET'S CATALOG DATA, and nothing else. Seven tables, no logic:

      DEFAULT_STRINGS              -- the English fallback for every string
                                      the tablet can show, used when the
                                      server has not supplied a translated
                                      one. Part of the three-way locale
                                      contract with client/tablet.lua's
                                      TABLET_STRING_KEYS and locales/en.json's
                                      `tablet` group -- all three must agree,
                                      and .github/scripts/locale_cross_check.py
                                      is what proves they do.
      COMMAND_REFERENCE_CATEGORIES -- the headings the command list is grouped
                                      under, in display order.
      COMMAND_REFERENCE            -- every command the tablet documents, with
                                      the gate that decides whether a given
                                      viewer may run it.
      DEFAULT_CAPABILITIES,        -- the capability list and its display
      CAPABILITY_ORDER                order, used when the server has not
                                      sent the viewer's real set.
      DEFAULT_THEME,               -- the tablet's own look, and the density
      THEME_DENSITY_OPTIONS           choices an operator may pick from.

    SPLIT OUT OF tablet.js 2026-09-02. It was 1,749 lines of pure data sitting
    in the middle of a 15,500-line file, between the state setup and the
    screen rendering -- so anyone reading the rendering code scrolled through
    the entire string table to get there, and anyone changing one string
    opened a file where every screen also lives.

    WHY ONLY THE DATA MOVED. The rest of tablet.js is one IIFE whose parts
    reference each other in both directions -- function declarations hoist,
    so nothing there ever had to care about order. Cutting it into separate
    <script> files would break roughly 175 of those references and mean
    rewriting them all to go through a shared object. This block has no such
    problem: it is three literals, referenced BY the code and referencing
    none of it, so it moves with nothing rewritten at all.

    LOAD ORDER IS LOAD-BEARING: tablet.html loads this BEFORE tablet.js, which
    re-binds the three names at its top. Loaded after, they would be
    undefined and the tablet would render nothing.
*/
(function () {
    'use strict';

    var DEFAULT_STRINGS = {
        title: 'K9 Command Tablet',
        close_label: 'Close',
        tab_guide: "Guide",
        help_tab_guide_desc: "How to do things, and then every command. The top half walks you through getting started, what each tab is for, the jobs you will do most often, and what to try when something is not working. The bottom half is a searchable list of every command this resource has, grouped by what you are trying to do, each with a live yes/no on whether you personally can use it right now and why.",
        tab_console: 'Command Console',
        tab_my_record: 'My Record',
        // PROGRESSION SCREEN (owner-directed: "do progression put in the
        // tablet"). {xp}/{rank}/{remaining} are replaced in buildLadderBlock
        // -- deliberately named placeholders rather than %s ordering, since
        // a translator reordering a sentence must not silently swap which
        // number means what.
        progression_intro: "Your rank on each ladder. The K9 ladder is earned by working as the dog; the handler ladder is earned by working with one. They advance separately, and your server can run either without the other.",
        progression_k9_heading: "K9 Rank",
        progression_handler_heading: "Handler Rank",
        progression_k9_off: "This server does not track K9 XP, so there is no rank to show here.",
        progression_handler_off: "This server does not track handler XP, so there is no rank to show here.",
        progression_standing: "{xp} XP -- {rank}",
        progression_no_rank_yet: "Unranked",
        progression_next_rank: "Next: {rank}, {remaining} XP away.",
        progression_top_rank: "You are at the top of this ladder.",
        progression_rank_row: "{rank} -- {xp} XP",
        loading: 'Loading...',
        error_generic: 'Something went wrong. Try again.',
        error_not_authorized: 'You are not authorized to view this.',
        error_timeout: 'The server did not respond in time.',
        error_network: 'Could not reach the server.',
        high_command_required_notice: 'You don\'t have High Command access, so here is your own record instead.',
        retry_label: 'Retry',
        refresh_label: 'Refresh',
        empty_roster: "No results. This list only shows people who already hold a certification, so someone never certified before (for example, a brand-new handler) will not appear here. If they are online, they are in the Online Players list above; otherwise type their exact citizen ID in the search box and press Open.",
        column_name: 'Name',
        column_citizenid: 'Citizen ID',
        column_department: 'Department',
        column_certified: 'Certified',
        column_xp: 'XP / Tier',
        // The HANDLER ladder, kept visibly distinct from column_xp above:
        // they are two separate ladders on two separate feature switches
        // and a person can be high on one and nowhere on the other.
        column_handler_xp: 'Handler XP / Rank',
        column_actions: 'Actions',
        // ONLINE PLAYERS LIST (owner-directed, 2026-08-26: "make the add
        // permission section... where its a list when i choose a player
        // id") -- see buildOnlinePlayersSection()'s own header for the
        // full contract.
        online_players_heading: 'Online Players',
        online_players_empty: 'Nobody matching that search is online right now.',
        online_players_opening_label: 'Opening...',
        column_server_id: 'Server ID',
        column_job: 'Job',
        column_k9_access: 'K9 Access',
        online_k9_access_yes: 'Has Access',
        online_k9_access_no: 'No Access',
        certified_yes: 'Certified',
        certified_no: 'Not certified',
        certify_label: 'Certify',
        certify_as_label: 'Certify as',
        certify_as_handler_option: 'Handler (looks stay the same)',
        certify_as_k9_option_template: 'K9: {breed}',
        certify_as_hint: 'Handler keeps their character as it is. Picking a breed certifies them as the K9 and turns them into that dog in the same step.',
        decertify_label: 'Decertify',
        confirm_label: 'Confirm?',
        grant_label: 'Grant',
        revoke_label: 'Revoke',
        block_label: 'Block',
        unblock_label: 'Unblock',
        column_block_effect: 'Block Effect',
        block_enforced_badge: 'Enforced',
        block_not_yet_enforced_badge: 'Not enforced yet',
        block_not_yet_enforced_hint: 'Blocking this here will not currently stop the feature in-game -- the server does not enforce this block yet.',
        block_not_enforceable_note: 'Cannot be blocked per-person -- there is no server-side enforcement point for this feature.',
        block_client_enforced_badge: 'Enforced (client-side)',
        block_client_enforced_hint: "Blocking this stops the ability on the player's own game client. Unlike a server-enforced block, a modified or cheating client can bypass it -- treat this as best-effort, not a guarantee.",
        manage_label: 'Manage',
        back_label: '← Back to roster',
        givexp_label: 'Give XP',
        givexp_placeholder: 'Amount',
        givexp_max_hint: 'Max per grant applies -- enforced by the server.',
        self_grant_disabled_title: 'High command cannot grant XP to themselves on this server.',
        truncated_notice: 'Showing a limited number of results. Refine your search to find someone not listed.',
        action_working: 'Working...',
        action_failed: 'Action failed — try again, and if it keeps happening, tell an admin.',
        action_succeeded: 'Done.',
        no_certifications: 'Not certified in any department.',
        my_certifications_heading: 'Certifications',
        my_xp_heading: 'XP',
        my_abilities_heading: 'Abilities',
        no_abilities: 'Nothing to show yet.',
        search_features_placeholder: 'Search abilities...',
        // DOMAIN GROUPING (owner: "more color based on all scent stuff
        // vehicle related is more text based") -- see buildMyFeaturesList()'s
        // own header comment for the full mechanism these five strings
        // support.
        feature_group_scent_heading: 'Scent & Tracking',
        feature_group_scent_hint: 'These abilities help your K9 follow a scent trail, and pick up on blood or gunpowder.',
        feature_group_vehicle_heading: 'Vehicles',
        feature_group_other_heading: 'Other Abilities',
        // THE ABILITY FILTER (2026-09-01) -- see buildPersonFeaturesSection()
        // for why this stopped being one bare input with only a placeholder
        // to explain it. Every string here exists to say, on screen, what
        // that placeholder alone was leaving the operator to infer.
        feature_filter_label: 'Filter this list (optional -- you can also just scroll and tick)',
        feature_filter_showing_template: 'Showing {count} of {total}',
        feature_filter_clear_label: 'Clear filter',
        feature_filter_no_matches: 'No abilities match that filter. Clear it to see the full list again -- this person\'s abilities are still all there.',
        feature_group_row_count_template: '{count}',
        feature_vehicle_sentence_template: '{feature} is currently: {state}.',
        // FULL DOMAIN GROUPING (owner-directed, 2026-08-26: "same with
        // features and sub features") -- one heading per
        // server/tablet.lua FEATURE_DOMAINS group, in
        // FEATURE_DOMAIN_ORDER's own declared order. Only 'scent'/
        // 'vehicle' above get bespoke hint text/row styling (the owner's
        // original "colour vs. text" ask was specific to those two); every
        // other domain below gets an ordinary heading over ordinary
        // badge-style rows -- see groupFeaturesByDomain()'s own header.
        feature_group_search_heading: 'Search & Contraband',
        feature_group_vision_heading: 'Vision & Sensory',
        feature_group_combat_heading: 'Combat & Restraint',
        feature_group_movement_heading: 'Movement & Control',
        feature_group_wellbeing_heading: 'Wellbeing',
        feature_group_progression_heading: 'Progression & Records',
        feature_group_gear_heading: 'Gear & Inventory',
        feature_group_training_heading: 'Training & Games',
        feature_group_admin_heading: 'Admin & Oversight',
        feature_group_integration_heading: 'Integrations',
        state_global_off: 'Disabled server-wide',
        state_blocked: 'Blocked',
        state_not_certified: 'Not certified',
        state_requires_grant_missing: 'Requires a grant (not granted)',
        state_available: 'Available',
        // DISPLAY-GAP FIX (this pass, server/tablet.lua's ResolveFeatureState) --
        // subtle "why can they do that" marker, only for a row that is
        // available SOLELY because of this person's own high-command
        // rank -- see appendViaHighCommandMarker()'s own header for the
        // "quiet, not a badge" requirement this satisfies.
        feature_via_high_command_marker: 'High Command',
        feature_via_high_command_hint: 'Available because this person is High Command -- they hold no personal grant or certification for this.',
        feature_column: 'Ability',
        status_column: 'Status',
        person_features_heading: 'Abilities',
        person_capabilities_heading: 'Capabilities',
        capability_no_description: 'No description on file for this permission.',
        capability_self_grant_disabled_title: 'You cannot grant a permission to yourself.',
        capability_rate_limited_wait_title: 'Please wait a moment before changing another permission -- grants and revokes share one cooldown.',
        person_certifications_heading: 'Certifications',
        person_xp_heading: 'K9 XP',
        person_handler_xp_heading: 'Handler XP',
        person_handler_xp_untracked: 'This server does not track handler XP.',
        xp_tier_unknown: 'No XP record yet.',
        use_label: 'Use',
        not_available_short: 'Unavailable',
        opening_person: 'Loading record...',
        person_no_record_found: 'No record found for this citizen ID. Double-check the ID -- it may be a typo, or belong to a deleted character.',

        // ---- Open-by-citizen-ID (console screen) -- see this file's
        // header note on why the roster search box alone cannot reach a
        // decertified/never-certified citizenid.
        open_by_id_label: 'Open',
        find_person_label: "Find a person",
        find_person_placeholder: "Name, citizen ID or server ID...",
        find_person_hint: "Type to search everyone online and everyone certified at once. For someone who is offline and has never been certified, type their exact citizen ID and press Open.",
        find_person_hint_id_only: "Type their exact citizen ID and press Open.",
        roster_results_heading: "Certified People",
        open_my_own_record_label: 'Open my own record',
        open_my_own_record_hint: 'Opens your own record, without needing to know your citizen ID. This is how you certify yourself, set your own tier, or grant yourself an ability -- if the server config permits it, which it re-checks every time.',
        // Workflow audit finding #1, 2026-08-26 -- shown on the Console
        // screen to a viewer who reaches it holding only 'k9.certify'/
        // 'k9.givexp' (canOpenPersonRecord() true, canAccessConsole()
        // false): explains why the search bar and roster table an
        // audit/high-command viewer would see are simply not here, so a
        // smaller screen reads as a deliberate boundary, not a bug.
        console_person_only_notice: 'You can open a specific handler or K9\'s record below if you already know their exact citizen ID. Browsing or searching the full roster needs the Audit capability or High Command.',

        // ---- K9 role control (person screen, high command only) --
        // owner's own words: "assign de assign give certs remove certs
        // remove k9 ped and reverts them to a human".
        role_heading: 'K9 Role',
        role_assign_label: 'Assign K9 Role',
        role_assign_hint: 'Turns this person into the selected model. Their current appearance is preserved for a later revert.',
        role_revert_label: 'Revert to Human',
        role_revert_hint: 'Forces this person back to human immediately -- works even if they hold no certification, no access, and no grant at all.',
        role_no_peds_configured: 'No ped models are configured on this server.',

        // ---- Rank/department (person screen, read-only -- see
        // buildRankSection's own doc comment for why there is no promotion
        // control: this resource has no job-grade write path today).
        person_rank_heading: 'Rank',
        rank_department_label: 'Department',
        rank_grade_label: 'Grade',
        rank_is_boss_badge: 'Boss',
        rank_unavailable: 'Rank information is not available for this person right now.',
        rank_change_note: 'Rank changes are made through your department\'s normal promotion process -- this tablet does not change job rank.',

        // ---- Partnership (person screen, read-only -- see
        // buildPartnershipSection's own doc comment).
        person_partnership_heading: 'Partnership',
        partnership_none: 'Not currently partnered.',
        partnership_partner_label: 'Partner',
        partnership_role_label: 'Role in partnership',
        partnership_role_value_k9: 'K9',
        partnership_role_value_handler: 'Handler',

        // ---- Tablet theming (its own tab, high command only to edit;
        // the resulting colours/density/title apply for every viewer).
        tab_theme: 'Tablet Theme',
        theme_heading: 'Tablet Appearance',
        theme_primary_label: 'Primary colour',
        theme_accent_label: 'Accent colour',
        theme_background_label: 'Background colour',
        theme_text_label: 'Text colour',
        theme_density_label: 'Density',
        theme_density_comfortable: 'Comfortable',
        theme_density_compact: 'Compact',
        theme_header_title_label: 'Header title',
        theme_save_label: 'Save Theme',
        theme_reset_label: 'Reset to Default',
        theme_disabled_note: 'Tablet theming is disabled server-wide. The current theme still applies; these controls will not save.',
        theme_field_invalid: 'That value was rejected by the server.',

        // ---- Certification tier editing (its own tab, high command
        // only). Owner's own words: "Allow high command to edit the
        // tiers trainee certified senior etc add more roles edit
        // permissions for those roles etc." The catalogue itself is
        // NEVER hardcoded here -- see loadCertTiers()'s own comment.
        cert_tiers_heading: 'Certification Tiers',
        cert_tiers_add_label: 'Add New Tier',
        cert_tier_key_label: 'Key',
        cert_tier_key_placeholder: 'e.g. master',
        cert_tier_label_label: 'Label',
        cert_tier_capabilities_label: 'Capabilities',
        cert_tier_no_capabilities: 'No capabilities selected.',
        cert_tier_save_label: 'Save Tier',
        cert_tier_cancel_label: 'Cancel',
        cert_tier_edit_label: 'Edit',
        cert_tier_delete_label: 'Delete',
        cert_tier_move_up_label: '↑',
        cert_tier_move_up_title: 'Move up (higher rank)',
        cert_tier_move_down_label: '↓',
        cert_tier_move_down_title: 'Move down (lower rank)',
        column_position: 'Position',
        column_key: 'Key',
        column_label: 'Label',
        column_capabilities: 'Capabilities',
        cert_tier_error_denied: 'You are not authorized to manage certification tiers.',
        cert_tier_error_rate_limited: 'Please wait a moment before trying again.',
        cert_tier_error_invalid_key: 'That key is invalid -- use 2-20 lowercase letters, numbers, or underscores, starting with a letter.',
        cert_tier_error_invalid_label: 'That label is invalid or too long (max 60 characters, no special markup characters).',
        cert_tier_error_invalid_capabilities: 'One or more selected capabilities is not recognized.',
        cert_tier_error_busy: 'This tier is being edited elsewhere right now -- try again in a moment.',
        cert_tier_error_too_many_tiers: 'The maximum number of certification tiers has been reached.',
        cert_tier_error_unknown_tier: 'That tier no longer exists.',
        cert_tier_error_ordinal_write_failed: "The new order could not be saved for these tiers: {keys}. Nothing else was changed \u2014 reopen this screen to see the order that is actually stored, then try again.",
        cert_tier_error_capability_write_failed: "Some capability changes could not be saved. Reopen this screen to see what is actually stored before changing anything else.",
        shop_item_error_sort_order_write_failed: "The new order could not be saved for these items: {keys}. Nothing else was changed \u2014 reopen this screen to see the order that is actually stored, then try again.",
        cert_tier_error_protected_tier: '"Certified" is a protected tier and can never be deleted.',
        cert_tier_error_tier_in_use: 'This tier cannot be deleted -- {count} certification record(s) still reference it. Move them to a different tier first, then delete.',
        // Deliberately a SEPARATE key/message from cert_tier_error_tier_in_use
        // above -- see server/certtiers.lua's own DeleteTier doc comment for
        // why: "3 certification records use this" and "2 shop items require
        // this" need different actions from the reader, and one combined
        // number would send them to the wrong screen (Cert Tiers vs. Shop
        // Items).
        cert_tier_error_tier_in_use_by_shop_items: 'This tier cannot be deleted -- {count} supply shop item(s) still require it: {items}. Change or clear those items\' tier requirement on the Shop Items screen first, then delete the tier.',
        cert_tier_error_must_include_every_tier: 'The new order must include every existing tier, with none missing or duplicated.',
        cert_tier_error_invalid_key_set: 'The new order must include every existing tier, with none missing or duplicated.',
        cert_tier_error_db_error: 'A database error occurred. Try again.',
        cert_tier_error_invalid_payload: 'That request was malformed. Try again.',

        // ---- K9 Supply Shop location management (its own tab, high
        // command only). Owner's own words: "make the shop a dog ped and i
        // can change the locations in the config or add more locations
        // remove locations etc along with in the high command tablet."
        // config.lua's own locations stay editable only by hand (shown
        // here read-only, source_config); this tab manages the runtime,
        // database-backed pool ONLY (source_runtime) -- see
        // server/equipmentshop.lua's own SCOPE note.
        shop_locations_heading: 'K9 Supply Shop Locations',
        shop_locations_disabled_note: 'The K9 Supply Shop is disabled server-wide. Existing locations are shown for reference only.',
        shop_locations_empty: 'No shop locations configured yet.',
        column_coordinates: 'Coordinates',
        column_model: 'Ped Model',
        column_source: 'Source',
        source_config: 'Config',
        source_runtime: 'Runtime',
        shop_location_add_here_label: 'Add Location Here',
        shop_location_add_hint: 'Adds a new shop location at your CURRENT in-game position. Walk to the spot first, then press this button.',
        shop_location_label_label: 'Label',
        shop_location_label_placeholder: 'e.g. Downtown K9 Supply',
        shop_location_model_label: 'Ped model',
        shop_location_model_placeholder: 'Leave blank to use the shop default',
        shop_location_scenario_label: 'Idle scenario',
        shop_location_scenario_placeholder: 'Leave blank to use the shop default',
        shop_location_save_label: 'Save Location',
        shop_location_cancel_label: 'Cancel',
        shop_location_edit_label: 'Edit',
        shop_location_move_here_label: 'Move Here',
        shop_location_move_here_hint: 'Moves this location to your CURRENT in-game position.',
        shop_location_remove_label: 'Remove',
        shop_location_config_note: 'Defined in config.lua -- edit that file and restart the resource to change or remove this one.',
        shop_location_error_denied: 'You are not authorized to manage shop locations.',
        shop_location_error_rate_limited: 'Please wait a moment before trying again.',
        shop_location_error_invalid_coords: 'Your current position could not be used. Try again.',
        shop_location_error_invalid_heading: 'That heading was rejected by the server.',
        shop_location_error_invalid_model: 'That ped model is invalid. Use a plain model name with no special characters.',
        shop_location_error_invalid_scenario: 'That scenario name is invalid. Use a plain name with no special characters.',
        shop_location_error_invalid_label: 'That label is invalid or too long.',
        shop_location_error_invalid_key: 'That location no longer exists, or cannot be edited from here.',
        shop_location_error_invalid_payload: 'That request was malformed. Try again.',
        shop_location_error_db_error: 'A database error occurred. Try again.',
        shop_location_error_feature_disabled: 'The K9 Supply Shop is disabled server-wide.',

        // ---- Runtime feature control + tuning (its own tab, high command
        // only) -- server/runtimecontrol.lua PART 1/1B. Owner's own words:
        // "Lets high command switch features on and off SERVER-WIDE from
        // the tablet, and tune numbers live." THE HONESTY REQUIREMENT: the
        // six `runtime_tier_*`/`runtime_tier_*_desc` pairs below are this
        // page's OWN plain-language rendering of server/runtimecontrol.lua's
        // `tier` field (see runtimeTierLabel()/runtimeTierDescription()) --
        // that file's raw English `note` prose is NEVER rendered verbatim,
        // per its own header ("LOCALE KEYS THIS FILE NEEDS: none... never
        // player-facing prose").
        tab_shop: "K9 Supply Shop",
        help_tab_shop_desc: "Everything about the K9 supply shop, in two sections: where its ped stands in the world for each department, and what it sells -- at what price, and which certification tier is required to buy each item. You may see only one of the two sections: they are separate permissions, so someone can be trusted with the catalog without being trusted to move the shop, or the other way round.",
        tab_catalogs: "Catalogs",
        help_tab_catalogs_desc: "The three lists this resource lets you edit yourself, in one place: certification tiers (like Trainee, Certified, Senior, and which extra abilities each unlocks), permission keys (the named capabilities you can grant one specific person), and XP ranks (how much XP each rank needs, on both the K9 and handler ladders). Open it before certifying anyone if the default tiers do not match how your server is organised, or when a permission you want to grant does not exist yet. You may see fewer than three sections: permission keys and XP ranks each disappear when their own feature is switched off.",
        tab_runtime_control: 'Runtime Control',
        runtime_control_heading: 'Runtime Feature Control',
        runtime_control_intro: 'These settings apply server-wide, for every player. Check the Effect column before changing anything — not every switch takes effect immediately.',
        runtime_control_disabled_note: 'Runtime feature control is disabled server-wide. Current values are shown for reference only; changes will not save until it is re-enabled.',
        runtime_features_heading: 'Features',
        runtime_features_empty: 'No features to show.',
        runtime_tunables_heading: 'Tunables',
        runtime_tunables_empty: 'No tunables to show.',
        column_tier: 'Effect',
        column_current_value: 'Current Value',
        column_range: 'Range',
        column_type: 'Type',
        runtime_tier_live: 'Live',
        runtime_tier_live_desc: 'Takes effect immediately for every player, and can be switched back at any time.',
        runtime_tier_onstart: 'Restart Required',
        runtime_tier_onstart_desc: 'Saved now, but only takes effect after this resource is restarted. Nothing changes for players in this session.',
        runtime_tier_rawtoplevel: 'Config Edit + Restart Required',
        runtime_tier_rawtoplevel_desc: 'Saved, but a restart of this resource alone is NOT enough -- config.lua itself must also be edited to match, and the server restarted, for this to actually take effect.',
        runtime_tier_clientonly: 'Client-Side Only',
        runtime_tier_clientonly_desc: 'This feature has no confirmed server-side effect. Saving this value cannot be confirmed to change anything for a connected player.',
        runtime_tier_protected: 'Protected',
        runtime_tier_protected_desc: 'This feature protects the authorization system this panel itself depends on, and can never be toggled from here. Change it in config.lua and restart if you are certain.',
        runtime_tier_unaudited: 'Not Yet Classified',
        runtime_tier_unaudited_desc: 'This feature has not yet been classified for runtime control, and is refused for safety. Ask a developer to audit it before it can be toggled here.',
        runtime_value_on: 'On',
        runtime_value_off: 'Off',
        runtime_overridden_by_at: 'Overridden by {who} at {when}',
        runtime_feature_toggle_on_label: 'Enable',
        runtime_feature_toggle_off_label: 'Disable',
        runtime_feature_reset_label: 'Reset to default',
        runtime_error_denied: 'You are not authorized to manage runtime feature control.',
        runtime_error_rate_limited: 'Please wait a moment before trying again.',
        runtime_error_db_error: 'A database error occurred. Try again.',
        runtime_feature_error_invalid_feature: 'That feature no longer exists.',
        runtime_feature_error_invalid_value: 'That value was rejected by the server.',
        // BETTER DISTINCTION FOR DANGEROUS SETTINGS (this pass) -- the data
        // already told the truth (lockoutRisk/sessionOnly/lockoutWarning,
        // see the comment block just below), but nothing summarised it
        // BEFORE a viewer started reading individual rows. This legend is
        // shown once, above the Features table, in the same plain language
        // as the row-level hint immediately below it.
        runtime_config_only_note: '{count} further feature(s) are not shown here because they cannot be changed from the tablet: they need an edit to config.lua and/or a server restart to take effect. Change these in config.lua: {names}',
        runtime_lockout_legend: "A warning triangle means extra care is needed: some settings can lock High Command out of the tablet entirely, others only warn while a player is doing that thing right now. Either way, you'll need to read the warning and type the setting's name before anything changes.",
        // LOCKOUT-RISK CONFIRMATION (this pass) -- server/runtimecontrol.lua's
        // own runtimeListFeatures already returned `lockoutRisk`/`sessionOnly`/
        // `lockoutWarning` per row, and runtimeSetFeature/runtimeResetFeature
        // already refused a `lockoutRisk` feature without a `confirm`
        // argument matching that feature's own `name` exactly -- see
        // buildRuntimeLockoutConfirmPanel()/openRuntimeLockoutConfirm() below
        // for the actual UI this unlocks. `runtime_lockout_row_hint`/
        // `runtime_session_only_hint` are THIS PAGE'S OWN plain-language
        // rendering of the two booleans (same posture as the tier
        // labels/descriptions above) -- NEVER a substitute for the server's
        // own `lockoutWarning` text, which is rendered VERBATIM, unmodified,
        // in the confirmation panel itself.
        runtime_lockout_badge: 'Lockout Risk',
        runtime_lockout_row_hint: 'Disabling this can immediately lock every administrator, including you, out of this tablet. Changing it requires reading a full warning and typing the feature name to confirm.',
        runtime_session_only_badge: 'Session-Only',
        runtime_session_only_hint: 'Not saved to the database -- a restart alone reverts this, even without a config.lua edit.',
        runtime_lockout_confirm_heading: 'Confirm This Change',
        runtime_lockout_confirm_instruction: 'Read the warning above carefully, then type the feature name exactly as shown to confirm.',
        runtime_lockout_confirm_input_label: 'Type "{name}" to confirm',
        runtime_lockout_confirm_input_placeholder: 'Feature name',
        runtime_lockout_confirm_button: 'Confirm and Apply',
        runtime_lockout_cancel_label: 'Cancel',
        runtime_feature_error_confirmation_required: 'The confirmation did not match the feature name exactly. Read the warning again and re-type it to confirm.',
        runtime_tunable_edit_label: 'Edit',
        runtime_tunable_save_label: 'Save Value',
        runtime_tunable_cancel_label: 'Cancel',
        runtime_tunable_reset_label: 'Reset to default',
        runtime_tunable_type_integer: 'Whole number',
        runtime_tunable_type_decimal: 'Decimal',
        runtime_tunable_error_invalid_key: 'That tunable no longer exists.',
        runtime_tunable_error_out_of_range: 'That value must be between {min} and {max}.',
        runtime_tunable_error_not_integer: 'This value must be a whole number.',
        runtime_tunable_error_not_a_number: 'Enter a valid number.',
        // Column header for the Settings table's first column, now that a
        // row shows a plain-English description first and the raw Config
        // path only as secondary detail (buildRuntimeTunableRow) -- see
        // server/runtimecontrol.lua's own GetTunableDescription for where
        // that description text actually comes from (a SEPARATE, dynamic
        // per-tunable locale lookup, not a DEFAULT_STRINGS entry -- only
        // this fixed column header is one).
        runtime_tunable_column_setting: 'Setting',

        // ---- K9 Audit Trail viewer (its own tab) -- server/admin.lua's
        // five tabletAudit* callbacks. Shown to any viewer whose
        // effectivePermissions includes 'k9.audit' (isHighCommand also
        // qualifies), NOT high-command-only like the four tabs above --
        // see canViewAudit()/buildTabs()'s own comment for why.
        tab_audit: 'Audit Trail',
        audit_heading: 'K9 Audit Trail',
        audit_intro: 'Read-only history from this resource\'s own certification, partnership, search, XP, department and catalog-change records. Every query here is rate-limited and logged, the same as running the equivalent chat command where one exists.',
        audit_disabled_note: 'The audit command surface is disabled server-wide. Queries cannot be run until it is re-enabled.',
        audit_mode_cert: 'Certifications',
        audit_mode_partner: 'Partnerships',
        audit_mode_search: 'Search Log',
        audit_mode_xp: 'XP Snapshot',
        audit_mode_dept: 'Department Roster',
        // catalog (this pass) -- the SIXTH mode, bridging server/admin.lua's
        // own 'qbx_k9unit:server:tabletAuditCatalog' (see this file's own
        // NUI CONTRACT note near the top for the full six-bridge list).
        audit_mode_catalog: 'Catalog Changes',
        audit_citizenid_label: 'Citizen ID',
        audit_citizenid_placeholder: 'e.g. ABC12345',
        audit_department_label: 'Department',
        audit_department_placeholder: 'e.g. police',
        audit_department_hint: 'Must match a configured department key -- pick one of your own certified departments below, or type another.',
        audit_catalog_label: 'Catalog',
        audit_search_mode_label: 'Search by',
        audit_search_mode_officer: 'Officer (searches performed by)',
        audit_search_mode_plate: 'Vehicle plate',
        audit_search_mode_person: 'Person (searches of)',
        audit_search_mode_recent: 'Most recent (any)',
        audit_value_label: 'Value',
        audit_value_placeholder_citizenid: 'e.g. ABC12345',
        audit_value_placeholder_plate: 'e.g. ABC123',
        audit_limit_label: 'Max results',
        audit_run_label: 'Run Query',
        // {requested}/{shown} filled in via formatTemplate() -- see
        // auditTruncatedText() for the exact contract (both are real,
        // server-reported numbers, never a client-side guess). Kept
        // byte-identical to locales/en.json's `tablet.audit_truncated_notice`.
        audit_truncated_notice: 'You asked for {requested} results; the server limit is {shown}, so only the first {shown} are shown.',
        audit_result_empty: 'No matching records found.',
        audit_result_prompt: 'Fill in the fields above and press "Run Query".',
        audit_error_not_authorized: 'You are not authorized to view the audit trail.',
        audit_error_rate_limited: 'Please wait a moment before running another audit query.',
        audit_error_invalid_args: 'That query is invalid -- check the required field and try again.',
        audit_boolean_yes: 'Yes',
        audit_boolean_no: 'No',
        audit_na: 'N/A',
        // column_department (roster's own, above) is reused verbatim for
        // the audit dept-roster table -- same word, same meaning, no
        // separate key needed. column_xp (also above, 'XP / Tier') is
        // NOT reused here -- the audit XP snapshot shows a raw, undecorated
        // total (server/admin.lua's own "COMPUTES NOTHING NEW" rule; no
        // derived tier), so it gets its own distinct column_audit_xp key
        // instead of silently redefining column_xp's text out from under
        // the roster table that key already serves.
        column_active: 'Active',
        column_granted_by: 'Granted By',
        column_granted_at: 'Granted At',
        column_revoked_by: 'Revoked By',
        column_revoked_at: 'Revoked At',
        column_k9: 'K9',
        column_handler: 'Handler',
        column_established_by: 'Established By',
        column_established_at: 'Established At',
        column_ended_by: 'Ended By',
        column_ended_at: 'Ended At',
        column_searched_at: 'Searched At',
        column_searcher: 'Searcher',
        column_searcher_job: 'Searcher Job',
        column_target_type: 'Target Type',
        column_target: 'Target',
        column_result: 'Result',
        column_weight: 'Weight',
        column_alert_tier: 'Alert Tier',
        column_audit_xp: 'XP',
        column_updated_at: 'Updated At',
        // Catalog Changes mode's own new column concepts (this pass) --
        // every OTHER column its 8 possible catalogs need reuses an
        // EXISTING key already serving the exact same field elsewhere on
        // this page (see auditColumnsForCatalog()'s own doc comment for
        // the full per-catalog reuse map) -- these six are the ones with
        // no prior equivalent. column_changed_by/column_changed_at are
        // deliberately their OWN keys, not a reuse of column_granted_by/
        // column_updated_at above -- "changed" is a catalog EDIT audit's
        // own vocabulary (server/datastore.lua's own `changed_by`/
        // `changed_at` columns, shared by all eight catalog audit tables),
        // distinct from a certification's "granted" or a live row's own
        // "updated", same reasoning column_audit_xp above already applies
        // to column_xp.
        column_action: 'Action',
        column_detail: 'Detail',
        column_changed_by: 'Changed By',
        column_changed_at: 'Changed At',
        column_old_value: 'Old Value',
        column_new_value: 'New Value',
        column_kind: 'Kind',
        column_override_key: 'Override Key',
        column_heading: 'Heading',
        // CERTIFICATION TIER / RENEWAL / SPECIALIZATION (this pass) -- see
        // client/tablet.lua's own TABLET_STRING_KEYS comment on this exact
        // 7-key set for the "not yet in locales/en.json" disclosure.
        tier_label: 'Tier',
        tier_set_label: 'Set Tier',
        renew_label: 'Renew',
        specializations_heading: 'Specializations',
        no_specializations: 'No specializations held.',
        expires_label: 'Expires',
        expired_badge: 'Expired',
        // PERMISSION-KEY CATALOG (owner-directed "add or remove permissions"
        // pass, server/permissionkeycatalog.lua) -- see
        // client/tablet.lua's own TABLET_STRING_KEYS comment: NOT YET in
        // locales/en.json (report filed with this pass), same disclosed-gap
        // posture as the tier_label..expired_badge block above.
        permission_keys_heading: 'Permission Key Catalog',
        permission_keys_add_label: 'Add Permission Key',
        permission_key_key_label: 'Key',
        permission_key_key_placeholder: 'e.g. k9.custom_ability',
        permission_key_label_label: 'Label',
        permission_key_description_label: 'Description (optional)',
        permission_key_description_placeholder: 'What this permission lets someone do',
        permission_key_save_label: 'Save',
        permission_key_cancel_label: 'Cancel',
        permission_key_edit_label: 'Edit',
        permission_key_delete_label: 'Delete',
        permission_key_default_badge: 'Default',
        permission_key_retired_badge: 'Retired',
        column_description: 'Description',
        permission_key_error_denied: 'You are not authorized to manage the permission-key catalog.',
        permission_key_error_rate_limited: 'Please wait a moment before trying again.',
        permission_key_error_invalid_key: 'Key must be 2-40 lowercase letters, numbers, underscores and dots (e.g. k9.custom_ability).',
        permission_key_error_invalid_label: 'Label must be 1-60 characters with no special markup.',
        permission_key_error_invalid_description: 'Description must be 300 characters or fewer, with no special markup.',
        permission_key_error_reserved_namespace: 'That key name is reserved for per-feature grants and blocks and cannot be used here.',
        permission_key_error_busy: 'Another edit to this key is in progress -- try again in a moment.',
        permission_key_error_too_many_keys: 'The permission-key catalog is full.',
        permission_key_error_unknown_key: 'That permission key does not exist.',
        permission_key_error_db_error: 'A database error occurred. Please try again.',
        permission_key_error_invalid_payload: 'The request was malformed.',
        // XP RANK EDITOR (owner-directed "...set experience level for each
        // rank up" pass, server/xptiers.lua) -- sits alongside the
        // cert-tier/permission-key/shop-location/runtime-control tabs
        // above, same high-command gate, same disclosed-gap posture: NOT
        // YET in locales/en.json's `tablet` group as of this pass (report
        // filed with this pass's own hand-off) -- BuildTabletStrings()'s
        // own pcall-per-key guard in client/tablet.lua simply omits each of
        // these from `strings` until added there, and this block covers
        // that exact gap in the meantime, same resilience-net role every
        // other DEFAULT_STRINGS key already documents.
        xp_tiers_heading: 'XP Rank Editor',
        xp_tiers_empty: 'No XP ranks are configured.',
        column_rank: 'Rank',
        column_xp_threshold: 'XP Threshold',
        column_speed_multiplier: 'Speed Multiplier',
        column_scent_range_multiplier: 'Scent Range Multiplier',
        column_medkit_cooldown_multiplier: 'Medkit Cooldown Multiplier',
        column_badge: 'Badge',
        xp_tier_edit_label: 'Edit',
        xp_tier_save_label: 'Save Rank',
        xp_tier_cancel_label: 'Cancel',
        xp_tier_xp_label: 'XP Threshold',
        xp_tier_xp_locked_hint: 'Rank 1 is the starting rank -- its XP threshold is fixed at 0 and cannot be changed here.',
        xp_tier_label_label: 'Label',
        xp_tier_speed_multiplier_label: 'Speed Multiplier',
        xp_tier_scent_range_multiplier_label: 'Scent Range Multiplier',
        xp_tier_medkit_cooldown_multiplier_label: 'Medkit Cooldown Multiplier (optional)',
        xp_tier_medkit_cooldown_multiplier_placeholder: 'Not configured',
        xp_tier_badge_label: 'Badge (optional)',
        xp_tier_badge_placeholder: 'None',
        xp_tier_error_denied: 'You are not authorized to edit XP ranks.',
        xp_tier_error_rate_limited: 'Please wait a moment before trying again.',
        xp_tier_error_busy: 'Another XP rank edit is in progress -- try again in a moment.',
        xp_tier_error_invalid_ordinal: 'That rank could not be found.',
        xp_tier_error_invalid_xp: 'XP threshold must be a whole number of 0 or more.',
        xp_tier_error_base_tier_xp_fixed: 'Rank 1 must always start at 0 XP -- this field cannot be changed.',
        xp_tier_error_invalid_label: 'Enter a valid label (1-60 characters, no special symbols).',
        xp_tier_error_invalid_speed_multiplier: 'Speed multiplier must be greater than 0 and no more than 3.',
        xp_tier_error_invalid_scent_range_multiplier: 'Scent range multiplier must be greater than 0 and no more than 3.',
        xp_tier_error_invalid_medkit_cooldown_multiplier: 'Medkit cooldown multiplier must be greater than 0 and no more than 1, or left blank.',
        xp_tier_error_invalid_badge: 'Enter a valid badge (up to 30 characters, no special symbols) or leave it blank.',
        xp_tier_error_invalid_order: 'That XP threshold would put this rank out of order with the rank above or below it.',
        xp_tier_error_db_error: 'The rank could not be saved due to a database error. Try again.',
        xp_tier_error_invalid_payload: 'That request was malformed. Try again.',
        // K9 INDIVIDUAL OVERRIDES (this pass, coder-ui, server/k9profiles.lua,
        // owner-directed "god over that tablet with full customization over
        // everything related to that K9" pass) -- buildK9ProfilesScreen()
        // below. Sits alongside the xp_tier_*/tab_xp_tiers keys above, same
        // "compose on top of the XP ladder, per-citizenid" domain.
        k9_profiles_intro: "Hand-tune one dog's sprint speed, scent range, medkit cooldown, and stamina drain rate beyond what its handler's XP rank already gives it, without moving the whole rank.",
        k9_profiles_list_heading: 'Currently Overridden K9s',
        k9_profiles_empty: 'No K9 currently has a hand-tuned override.',
        column_note: 'Note',
        k9_profile_manage_label: 'Manage',
        k9_profile_field_not_overridden: 'Not overridden',
        k9_profile_tier_label_prefix: "This K9's XP rank: ",
        k9_profile_effective_speed_prefix: 'Speed right now: ',
        k9_profile_effective_scent_prefix: 'Scent range right now: ',
        k9_profile_effective_medkit_prefix: 'Medkit cooldown multiplier right now: ',
        k9_profile_effective_stamina_prefix: 'Stamina drain rate right now: ',
        k9_profile_overridden_suffix: ' (hand-tuned override)',
        k9_profile_from_tier_suffix: " (from this K9's rank, no override)",
        k9_profile_not_yet_live_hint: "Changes here take effect the next time this K9's rank is recalculated -- earning XP, the handler reconnecting, or a server restart -- not necessarily this instant if the K9 is already active right now.",
        k9_profile_speed_multiplier_label: 'Sprint Speed Multiplier',
        // NO FIXED NUMBER CLAIMED (owner-directed, this pass) -- the real
        // ceiling is now an owner-editable server setting, so this page
        // never states a specific figure it cannot promise is still true.
        k9_profile_speed_multiplier_hint: "Multiplies this K9's movement and sprint speed. Must be greater than 0 -- there is no fixed upper limit here; an extremely high value may still be refused if it exceeds what your server allows. Default: 1.0, meaning no change from its rank.",
        k9_profile_speed_clamp_note: "This value genuinely applies in-game, all the way up to your server's speed ceiling -- that is Config.MaxSpeedScentMultiplier in config.lua, 10 by default, which is also the highest the game engine itself accepts. There is no hidden lower cap. This note used to say the opposite, and it was right at the time: anything above 2x saved, showed here, and silently never happened. That is fixed.",
        k9_profile_scent_range_multiplier_label: 'Scent Range Multiplier',
        k9_profile_scent_range_multiplier_hint: "Multiplies how far this K9 can pick up a scent trail or search target. Must be greater than 0 -- there is no fixed upper limit here; an extremely high value may still be refused if it exceeds what your server allows. Default: 1.0, meaning no change from its rank.",
        k9_profile_medkit_cooldown_multiplier_label: 'Medkit Cooldown Multiplier',
        k9_profile_medkit_cooldown_multiplier_hint: 'Multiplies the wait time between medkit uses on this K9 -- a SMALLER number means a SHORTER wait. Range: above 0 up to 1.0 (1.0 = no change; this can only shorten the cooldown, never lengthen it). Default: whatever its rank already gives it.',
        k9_profile_note_label: 'Note (optional)',
        k9_profile_note_hint: 'A short, plain-text reason for this override, visible to any high-command officer who looks this K9 up later. Up to 120 characters, no special formatting characters.',
        k9_profile_blank_means_no_override_placeholder: 'Leave blank to keep the current value',
        k9_profile_field_clear_hint: 'Leaving a field blank leaves it exactly as it already was -- it does not clear it. To remove every override on this K9 at once, use Reset All Overrides below; there is no way to clear a single field on its own.',
        k9_profile_save_label: 'Save Override',
        k9_profile_reset_label: 'Reset All Overrides',
        k9_profile_close_label: 'Close',
        k9_profile_error_denied: 'You are not authorized to manage K9 overrides.',
        k9_profile_error_rate_limited: 'Please wait a moment before trying again.',
        k9_profile_error_busy: 'Another edit to this K9 is in progress -- try again in a moment.',
        k9_profile_error_invalid_citizenid: 'Enter a valid citizen ID.',
        k9_profile_error_invalid_payload: 'That request was malformed. Try again.',
        k9_profile_error_no_fields_to_set: 'Enter at least one value to save.',
        k9_profile_error_invalid_speed_multiplier: "Sprint speed multiplier must be a number above 0.1 and no higher than your server's speed ceiling -- that is Config.MaxSpeedScentMultiplier in config.lua, 10 by default, and never more than 10 whatever you set it to, because that is the game engine's own maximum. Or leave it blank.",
        k9_profile_error_invalid_scent_range_multiplier: 'Scent range multiplier must be a number greater than 0, or left blank.',
        k9_profile_error_invalid_medkit_cooldown_multiplier: 'Medkit cooldown multiplier must be greater than 0 and no more than 1, or left blank.',
        k9_profile_error_invalid_stamina: 'Stamina drain rate must be 0 (permanent) or a positive number, or left blank.',
        k9_profile_error_invalid_note: 'Enter a valid note (1-120 characters, no special symbols) or leave it blank.',
        k9_profile_error_too_many_overrides: 'Too many K9s already have a hand-tuned override -- remove one before adding another.',
        k9_profile_error_db_error: 'The override could not be saved due to a database error. Try again.',
        // STAMINA (owner-directed, this pass: "be able to make the
        // stamina as high as i want and be able to make the stamina...
        // permanant") -- see buildK9ProfileStaminaField()'s own header.
        column_stamina_drain: 'Stamina Drain Rate',
        k9_profile_stamina_label: 'Stamina Drain Rate',
        k9_profile_stamina_hint: "How fast this K9's stamina drains while sprinting. HIGHER means it runs out of stamina FASTER, not slower -- this is a drain rate, not a stamina amount. Must be 0 or greater (0 means it never runs out); there is no fixed upper limit here, but a very high value may still be refused if it exceeds what your server allows. Default: whatever the server's own base setting already gives it.",
        k9_profile_stamina_permanent_checkbox_label: 'Never runs out (permanent stamina)',
        k9_profile_stamina_permanent_label: 'Never runs out (permanent)',
        k9_profile_stamina_drain_rate_template: '{rate} per tick',
        // PERSON SCREEN EMBED (coordinator-directed: "one place that acts
        // on a citizenid, extended, never forked") -- see
        // buildPersonK9ProfileSection()'s own header.
        k9_profile_person_section_heading: 'K9 Individual Override',
        k9_profile_person_section_intro: "Hand-tune THIS K9's sprint speed, scent range, medkit cooldown, and stamina drain rate beyond what its rank already gives it. Everyone holding an override is also listed on the Command Console.",
        // K9 SUPPLY SHOP ITEM CATALOG (this pass, coder-ui,
        // server/equipmentshop.lua's own "EQUIPMENT SHOP ITEM CATALOG"
        // section) -- sits alongside the shop_location_*/tab_shop_locations
        // keys above, same "K9 Supply Shop" domain. SAME disclosed-gap
        // posture as the 'tab_audit'/'tier_label'/'tab_xp_tiers' blocks
        // above: these 44 keys are NOT YET present in locales/en.json's
        // `tablet` group as of this pass -- flagged to that file's owner
        // (see this pass's own report for the exact key -> English-string
        // list). BuildTabletStrings()'s own pcall-per-key guard means each
        // is simply omitted from `strings` until added there, and this
        // very DEFAULT_STRINGS table covers that exact gap in the
        // meantime, same resilience-net role it already documents for
        // every other key.
        shop_items_heading: 'K9 Supply Shop Items',
        shop_items_add_label: 'Add New Item',
        shop_items_empty: 'No shop items configured yet.',
        column_price: 'Price',
        column_currency: 'Currency',
        column_required_tier: 'Required Tier',
        column_required_specialization: 'Required Specialization',
        shop_item_key_label: 'Item Key',
        shop_item_key_placeholder: 'e.g. k9_medkit',
        shop_item_price_label: 'Price',
        shop_item_label_label: 'Display Label',
        shop_item_label_placeholder: "Leave blank to use the item's own name",
        shop_item_currency_label: 'Currency Item',
        shop_item_currency_placeholder: 'Leave blank to use the shop default',
        shop_item_required_tier_label: 'Required Certification Tier',
        shop_item_required_specialization_label: 'Required Specialization',
        shop_item_no_requirement: 'None',
        shop_item_retired_reference_badge: '(retired)',
        shop_item_save_label: 'Save Item',
        shop_item_cancel_label: 'Cancel',
        shop_item_edit_label: 'Edit',
        shop_item_delete_label: 'Delete',
        shop_item_move_up_label: '↑',
        shop_item_move_up_title: 'Move up (earlier in the shop)',
        shop_item_move_down_label: '↓',
        shop_item_move_down_title: 'Move down (later in the shop)',
        shop_item_price_free_badge: 'Free',
        shop_item_currency_default_note: 'Shop default',
        shop_item_error_denied: 'You are not authorized to manage the K9 Supply Shop item catalog.',
        shop_item_error_rate_limited: 'Please wait a moment before trying again.',
        shop_item_error_invalid_payload: 'That request was malformed. Try again.',
        shop_item_error_invalid_key: 'That item key is invalid -- use 1-50 lowercase letters, numbers, or underscores, starting with a letter.',
        shop_item_error_invalid_price: 'That price is invalid -- enter a whole number from 0 up to 1,000,000,000. Zero is allowed for a free item.',
        shop_item_error_invalid_label: 'That label is invalid or too long (max 60 characters, no special markup characters).',
        shop_item_error_invalid_currency: 'That currency item key is invalid -- use 1-50 lowercase letters, numbers, or underscores, starting with a letter.',
        shop_item_error_invalid_required_tier: 'That required certification tier does not exist.',
        shop_item_error_invalid_required_specialization: 'That required specialization does not exist.',
        shop_item_error_busy: 'This item is being edited elsewhere right now -- try again in a moment.',
        shop_item_error_too_many_items: 'The maximum number of shop items has been reached.',
        shop_item_error_unknown_item: 'That item no longer exists in the catalog.',
        shop_item_error_must_include_every_item: 'The new order must include every existing item, with none missing or duplicated.',
        shop_item_error_invalid_key_set: 'The new order must include every existing item, with none missing or duplicated.',
        shop_item_error_db_error: 'A database error occurred. Try again.',

        // ---- HOME / LANDING VIEW (this pass, owner-directed "restructure
        // the tablet around WHO IS HOLDING IT... a first-time player who
        // has read nothing should open this and know what to do within
        // seconds"). See buildHomeScreen() below for the full writeup --
        // this is now the DEFAULT screen on open, ahead of every existing
        // tab; nothing below removes or renames an existing screen.
        home_welcome_template: 'Welcome, {name}.',
        home_role_high_command: 'High Command',
        home_role_k9: 'K9',
        home_role_handler: 'Certified Handler',
        home_role_uncertified: 'New Arrival',
        home_partnered_badge: 'Partnered',
        home_not_partnered_badge: 'No Partner',
        home_certified_count_template: 'Certified in {count} of {total} departments',
        home_quick_actions_heading: 'What do you want to do?',
        home_open_console_label: 'Open Command Console',
        home_open_console_hint: 'Look up and manage handlers and K9s.',
        home_high_command_heading: 'High Command Tools',
        home_high_command_hint: 'Settings that affect the whole server: how the tablet looks, certification ranks, permission keys, the supply shop, which features are turned on, XP ranks, and the audit trail.',
        home_high_command_tabs_pointer: "The whole-server settings are under the Server Settings tab at the top of the screen, one click per section. The personnel roster and the audit trail have their own tabs beside it.",
        // Workflow audit finding #3, 2026-08-26 -- a delegate holding one
        // (or more) of the four delegable capabilities below gets a
        // version of this section describing ONLY what they actually
        // hold, never the full high-command list above. See
        // buildHomeHighCommandSignpost()'s own doc comment for the full
        // writeup.
        home_high_command_scope_theme: 'how the tablet looks',
        home_high_command_scope_shop_locations: 'which supply shop locations are active',
        home_high_command_scope_shop_items: 'what the supply shop sells',
        home_high_command_scope_runtime_control: 'which features are turned on',
        home_high_command_delegate_hint_template: "You've been granted access to: {scope}.",
        home_high_command_delegate_tabs_pointer: "You'll find these under the Server Settings tab at the top of the screen.",
        list_join_and: 'and',
        home_no_certification_title: "You're not certified yet",
        home_no_certification_body: 'Ask a certifier or a High Command officer to certify you in a department. Once certified, your abilities and record will appear here.',
        home_no_certification_next_steps: "Not sure how to get started? The Guide tab walks you through it, and lists everything there is to earn.",
        home_blocked_count_template: '{count} of your abilities are currently blocked',

        // ---- COMMAND REFERENCE (this pass -- "dozens of commands, no way
        // for a player to discover them in-game"). See COMMAND_REFERENCE/
        // buildCommandReferenceScreen() below for the full design. Every
        // one of these keys is NOT YET present in locales/en.json's
        // `tablet` group as of this pass -- flagged to that file's owner
        // (see this pass's own report for the exact key -> English-string
        // list). BuildTabletStrings()'s own pcall-per-key guard means each
        // is simply omitted from `strings` until added there, and this
        // DEFAULT_STRINGS table covers that exact gap in the meantime,
        // same resilience-net role it already plays for every other key.
        // ---- YOUR KEYS -- html/tablet.js's buildKeysListSection(), the list at
        // the top of the Guide. keys_name_* are the two gateway keys owned by
        // ox_lib (radial menu) and ox_target (third eye), shown as their defaults.
        keys_heading: "Your Keys",
        keys_intro: "The default key for everything you can do. Change any of them in Settings > Key Bindings > FiveM -- a key you have already changed keeps your choice.",
        keys_action_radial: "Open your K9 menu -- every action is in here",
        keys_action_third_eye: "Look at a person, vehicle or kennel to see what you can do with it",
        keys_action_sit: "Sit",
        keys_action_bark: "Bark",
        keys_action_scent_vision: "Scent vision on / off",
        keys_action_bite_hold: "Bite & hold / let go",
        keys_action_takedown: "Take down a fleeing suspect",
        keys_action_drag: "Drag / let go",
        keys_action_vault: "Jump a low obstacle",
        keys_action_pursuit_sprint: "Pursuit sprint",
        keys_action_toggle_camera: "First-person view on / off",
        keys_action_camera_feed: "Partner camera on / off",
        keys_action_thermal: "Thermal vision on / off",
        keys_action_night: "Night vision on / off",
        keys_action_vision_cycle: "Cycle vision: off, night, thermal",
        keys_action_exit_kennel: "Leave the kennel",
        keys_name_radial: "Z",
        keys_name_third_eye: "Left Alt",
        cmdref_heading: 'Command Reference',
        cmdref_intro: 'Every command this resource registers, grouped by what you are trying to do. A command you cannot currently use is marked, with the reason why -- the server still decides what actually works; this list only tells you the truth about it.',
        cmdref_search_placeholder: 'Search commands...',
        cmdref_status_unavailable_loading: 'Still loading your record -- the Status column will fill in once it arrives.',
        cmdref_status_unavailable_error: 'Your record could not be loaded, so the Status column cannot say what you personally can and cannot use right now. Everything else on this screen is still accurate, and the commands themselves are unaffected -- this is only the status readout.',
        cmdref_filter_label: 'Filter these commands (optional -- the full list is grouped below)',
        cmdref_filter_no_matches: 'No commands match that filter. Clear it to see the full list again.',
        cmdref_status_unknown: 'Still loading\u2026',
        cmdref_empty: 'No commands match your search.',
        cmdref_column_command: 'Command',
        cmdref_column_does: 'What It Does',
        cmdref_column_needs: 'What It Needs',
        cmdref_admin_badge: 'Admin',
        cmdref_status_insufficient_authorization: 'Requires higher authorization',
        // Shown once, not per-row -- see buildCommandReferenceRow()'s own
        // comment on `defaultKeybind` for why the per-row line never
        // repeats this (this pass, keybinds handoff, client/keybinds.lua).
        cmdref_default_keybind_template: 'Default key: {key} — rebindable in Settings > Key Bindings > FiveM.',
        // Same shape as cmdref_default_keybind_template above, for the
        // subset of commands whose default is read from a config.lua VALUE
        // this server's own operator set, not a literal baked into
        // client/keybinds.lua -- see COMMAND_REFERENCE's own
        // `defaultKeybindConfigurable` doc comment for exactly which
        // entries use this one instead of the plain template above.
        cmdref_default_keybind_configurable_template: 'Default key: {key} — this server chose that value, so another server running this same resource could have a different one. Still rebindable in Settings > Key Bindings > FiveM.',
        cmdref_keybind_caveat: "A default keybind only applies to a player who has never set that key themselves. Changing a default later never moves anyone's existing binding.",

        cmdref_category_basic_commands: 'Basic K9 Commands',
        cmdref_category_combat: 'Combat & Restraint',
        cmdref_category_vision: 'Cameras & Vision',
        cmdref_category_field_gear: 'Field Gear & Equipment',
        cmdref_category_records: 'Records & Progress',
        cmdref_category_certification: 'Certification Management',
        cmdref_category_xp: 'XP Management',
        cmdref_category_audit: 'Audit & Oversight',
        cmdref_category_devtools: 'Developer Tools',
        cmdref_category_permissions: 'Permission Management',

        cmdref_k9sit_usage: '/k9sit',
        cmdref_k9sit_does: 'Commands your K9 to sit in place.',
        cmdref_k9sit_needs: 'K9 access.',
        cmdref_k9bark_usage: '/k9bark',
        cmdref_k9bark_does: 'Plays a basic bark.',
        cmdref_k9bark_needs: 'K9 access, and Basic Bark Sounds enabled on this server.',
        cmdref_k9scentvision_usage: '/k9scentvision',
        cmdref_k9scentvision_does: 'Toggles Scent Vision: coloured dots on the ground showing where nearby people recently walked. Each dot fades on its own timer, so a longer trail means someone passed more recently.',
        cmdref_k9scentvision_needs: 'K9 access, and Scent Vision enabled on this server.',
        cmdref_k9bitehold_usage: '/k9bitehold',
        cmdref_k9bitehold_does: 'Toggles Bite & Hold on the nearest eligible target, or releases it if your K9 is already holding one.',
        cmdref_k9bitehold_needs: 'K9 access, and Bite & Hold enabled on this server.',
        cmdref_k9takedown_usage: '/k9takedown',
        cmdref_k9takedown_does: 'Attempts a non-lethal takedown on the nearest fleeing eligible target.',
        cmdref_k9takedown_needs: 'K9 access, and Non-Lethal Takedown enabled on this server.',
        cmdref_k9dragtoggle_usage: '/k9dragtoggle',
        cmdref_k9dragtoggle_does: 'Toggles dragging the nearest downed target, or releases it if your K9 is already dragging one.',
        cmdref_k9dragtoggle_needs: 'K9 access, and Prop Dragging enabled on this server.',

        // k9leash/k9vehicle/k9partner/k9gear/k9treat -- menu-parity pass,
        // see this file's own COMMAND_REFERENCE entries for these five for
        // the full "why this gate" writeup.
        cmdref_k9leash_usage: '/k9leash',
        cmdref_k9leash_does: 'Attaches a leash to the nearest eligible player, or detaches your current leash if you already have one.',
        cmdref_k9leash_needs: 'K9 access to attach a leash to someone. Detaching is always available, with no certification needed. Leash Mechanics must be turned on for your server.',
        cmdref_k9vehicle_usage: '/k9vehicle',
        cmdref_k9vehicle_does: 'Gets your K9 into the nearest K9 vehicle\'s free seat, or gets it back out if it is already riding in one.',
        cmdref_k9vehicle_needs: 'K9 access to get in. Getting out is always available. Vehicle Entry/Exit must be turned on for your server.',
        cmdref_k9partner_usage: '/k9partner',
        cmdref_k9partner_does: 'Sends a Partner Up request to the nearest eligible player, or breaks your current partnership if you already have one.',
        cmdref_k9partner_needs: 'K9 access to send a Partner Up request. Breaking a partnership is always available, even right after a reconnect. Handler Partnership must be turned on for your server.',
        cmdref_k9gear_usage: '/k9gear',
        cmdref_k9gear_does: 'Opens your own K9 gear stash.',
        cmdref_k9gear_needs: 'An active K9 certification, and you must currently be controlling your K9. This feature must be turned on for your server.',
        cmdref_k9treat_usage: '/k9treat',
        cmdref_k9treat_does: 'Treats the nearest eligible K9 using a medkit from your own inventory.',
        cmdref_k9treat_needs: 'Your job must be permitted to use K9 medkits (not K9 access or certification of your own), and on some servers an individual grant for this feature too. You must be holding the item this server has configured as a K9 medkit, and there must be an eligible K9 nearby. This feature must be turned on for your server.',
        cmdref_k9deploykennel_usage: '/k9deploykennel',
        cmdref_k9deploykennel_does: 'Places a portable kennel at your feet.',
        cmdref_k9deploykennel_needs: 'An active K9 certification, and you must currently be controlling your K9. This feature must be turned on for your server.',
        cmdref_k9exitkennel_usage: '/k9exitkennel',
        cmdref_k9exitkennel_does: 'Gets you out of a kennel you are resting in.',
        cmdref_k9exitkennel_needs: 'Nothing -- always available while resting in a kennel, so you can never get stuck inside one.',
        // k9kennel -- docs/history/COMMAND_CONSOLIDATION_SPEC.md #5's merged entry point.
        // does/usage text from client/commandsuggestions.lua's own
        // PENDING_LOCALE_KEYS (the exact interim text already shipped
        // client-side for this command); needs mirrors k9deploykennel's own
        // above (the START half this command's gate documents).
        cmdref_k9kennel_usage: '/k9kennel',
        cmdref_k9kennel_does: 'Deploys, enters, or exits your kennel -- whichever one makes sense right now. Old names /k9deploykennel and /k9exitkennel still work too.',
        cmdref_k9kennel_needs: 'An active K9 certification, and you must currently be controlling your K9, to deploy or enter. Exiting is always available. This feature must be turned on for your server.',
        // k9debug -- server/diagnostics.lua. The one command whose gate is
        // NOT a Config.Features key: it is switched by Config.DebugDump
        // .enabled, which the tablet's predictive-availability logic has no
        // way to read, so its COMMAND_REFERENCE row below is deliberately
        // gate 'open' and the `needs` text carries the real precondition in
        // words instead of a live yes/no.
        cmdref_k9debug_usage: "/k9debug [normal|verbose]",
        cmdref_k9debug_does: "Writes a diagnostic report about your own K9 state to a file inside the script folder, for you to hand to a developer. Nothing is printed to the console.",
        cmdref_k9debug_needs: "Your server owner must switch this on first (Config.DebugDump.enabled). It reports only on you -- never on anyone else.",
        cmdref_k9propattach_usage: '/k9propattach',
        cmdref_k9propattach_does: 'Attaches or removes a prop (for example a vest) on your K9.',
        cmdref_k9propattach_needs: 'An active K9 certification, and you must currently be controlling your K9. This feature must be turned on for your server.',
        cmdref_k9throwfetchball_usage: '/k9throwfetchball',
        cmdref_k9throwfetchball_does: 'Throws a fetch ball for your K9 to chase.',
        cmdref_k9throwfetchball_needs: 'An active K9 certification. Only one ball may be in play for you at a time. This feature must be turned on for your server.',
        cmdref_k9dropfetchball_usage: '/k9dropfetchball',
        cmdref_k9dropfetchball_does: 'Drops the fetch ball you are currently carrying.',
        cmdref_k9dropfetchball_needs: 'Nothing -- always available while you are carrying a ball, so you can never get stuck holding one.',
        cmdref_k9recallfetchball_usage: '/k9recallfetchball',
        cmdref_k9recallfetchball_does: 'Cancels your own fetch throw in progress.',
        cmdref_k9recallfetchball_needs: 'Nothing -- always available, so a throw can always be called off.',
        // k9fetch -- docs/history/COMMAND_CONSOLIDATION_SPEC.md #3's merged entry point.
        // does/usage from client/commandsuggestions.lua's own
        // PENDING_LOCALE_KEYS; needs mirrors k9throwfetchball's own above.
        cmdref_k9fetch_usage: '/k9fetch',
        cmdref_k9fetch_does: 'Throws, recalls, or drops the fetch ball -- whichever one makes sense right now. Old names /k9throwfetchball, /k9recallfetchball and /k9dropfetchball still work too.',
        cmdref_k9fetch_needs: 'An active K9 certification to throw. Recalling or dropping is always available. Only one ball may be in play for you at a time. This feature must be turned on for your server.',




        cmdref_k9stats_usage: '/k9stats [limit]',
        cmdref_k9stats_does: 'Shows the server\'s K9 XP leaderboard.',
        cmdref_k9stats_needs: 'An active K9 certification. This feature must be turned on for your server.',

        cmdref_k9certify_usage: '/k9certify <server id>  |  /k9certify <citizenid> <job>',
        cmdref_k9certify_does: 'Makes a handler\'s certification current for their department -- certifies them if they are new, renews their expiry if they already hold one. Works whether they are online (first form) or offline (second form).',
        cmdref_k9certify_needs: 'High Command, the certify permission, or your department\'s certifier rank. An ONLINE target must be in a configured department and within certifying distance (unless you are certifying yourself and self-certification is allowed). An OFFLINE target is refused if your server requires an on-model check, since that can only happen while they are online -- use the online form once they log in instead.',
        cmdref_k9decertify_usage: '/k9decertify <server id> [reason]  |  /k9decertify <citizenid> <job> [reason]',
        cmdref_k9decertify_does: 'Revokes a player\'s current department certification -- works whether they are online (first form) or offline (second form).',
        cmdref_k9decertify_needs: 'Same as /k9certify. Proximity is required for an ONLINE target unless you are revoking your own.',
        cmdref_k9settier_usage: '/k9settier <server id> <tier>  |  /k9settier <citizenid> <job> <tier>',
        cmdref_k9settier_does: 'Changes an actively-certified handler\'s certification tier -- works whether they are online (first form) or offline (second form).',
        cmdref_k9settier_needs: 'Same as /k9certify. The target must already hold an active certification.',
        cmdref_k9specialize_usage: '/k9specialize <server id> <specialization>',
        cmdref_k9specialize_does: 'Grants an online, actively-certified handler a specialization.',
        cmdref_k9specialize_needs: 'Same as /k9certify. The target\'s certification tier must be allowed to hold specializations. There is no offline version of this command -- granting a specialization always requires the target to be online.',
        cmdref_k9unspecialize_usage: '/k9unspecialize <server id> <specialization>  |  /k9unspecialize <citizenid> <job> <specialization>',
        cmdref_k9unspecialize_does: 'Revokes a handler\'s specialization -- works whether they are online (first form) or offline (second form).',
        cmdref_k9unspecialize_needs: 'Same as /k9certify.',
        // k9dog -- docs/history/COMMAND_CONSOLIDATION_SPEC.md #2's merged entry point.
        // does/usage from client/commandsuggestions.lua's own
        // PENDING_LOCALE_KEYS; needs is new (this pass) -- gated on
        // IsHighCommand(source) alone, no Config.Features flag exists for
        // this file at all (confirmed by reading server/dogcharacter.lua
        // directly), unlike k9certify's own capability-based gate above.
        cmdref_k9dog_usage: '/k9dog <target>',
        cmdref_k9dog_does: 'Shows or changes whether a character is permanently pinned as a K9. One command for both: /k9setdog and /k9removedog still work too.',
        cmdref_k9dog_needs: 'High Command only.',

        cmdref_k9givexp_usage: '/k9givexp <server id> <amount>',
        cmdref_k9givexp_does: 'Awards XP directly to an online player.',
        cmdref_k9givexp_needs: 'High Command or the grant-XP permission. The amount is capped by this server\'s configured maximum per grant, and repeated use is rate-limited.',

        cmdref_k9audit_usage: '/k9audit <cert|partner|search|xp|dept>',
        cmdref_k9audit_does: 'Shows a K9 audit report. One command for all five: certifications, partnerships, searches, XP and department totals.',
        cmdref_k9audit_needs: 'High Command, the audit permission, or your department\'s audit rank. The Audit Trail feature must be turned on for your server.',
        cmdref_k9track_usage: '/k9track',
        cmdref_k9track_does: "Starts a track; use it again to stop. Your dog follows whichever trail it is trained to find -- you do not pick the type.",
        cmdref_k9track_needs: 'K9 access. Which trails your dog can follow depends on its specializations.',

        cmdref_k9bonetool_usage: '/k9bonetool <goto|next|prev|test|stop|known|help> [value]',
        cmdref_k9bonetool_does: 'Developer tool for sweeping through a test prop\'s skeleton bones, to find the right one for attaching a leash, vest, or prop.',
        cmdref_k9bonetool_needs: 'Your department\'s boss rank or High Command, AND a server operator must have explicitly turned this dev tool on -- it is off by default, and unsafe to leave on in production.',

        cmdref_k9permission_usage: '/k9permission <grant|revoke> <citizenid> <permissionKey>',
        cmdref_k9permission_does: 'Grants or revokes a named permission key (a capability like certifying others, or a specific feature/block override) directly to/from a citizen. Old names /k9grantpermission and /k9revokepermission still work too.',
        cmdref_k9permission_needs: 'High Command only. This feature must be turned on for your server. You cannot grant a permission to yourself.',
        cmdref_k9grantpermission_usage: '/k9grantpermission <citizenid> <permissionKey>',
        cmdref_k9grantpermission_does: 'Old, still-working name for /k9permission grant.',
        cmdref_k9grantpermission_needs: 'High Command only. This feature must be turned on for your server. You cannot grant a permission to yourself.',
        cmdref_k9revokepermission_usage: '/k9revokepermission <citizenid> <permissionKey>',
        cmdref_k9revokepermission_does: 'Old, still-working name for /k9permission revoke.',
        cmdref_k9revokepermission_needs: 'High Command only. This feature must be turned on for your server.',

        // ---- Integration-sweep fix (this pass): seven REAL, working
        // keybind commands (RegisterCommand + RegisterKeyMapping, both
        // confirmed in client/agility.lua, client/pursuitsprint.lua,
        // client/movement.lua, client/vision.lua) that
        // had ZERO COMMAND_REFERENCE entry -- see
        // tests/commandreferenceregistry_spec.lua's own header "WIDENED,
        // THIS PASS" for why the drift guard never caught this. Named
        // cmdref_<shortname>_* rather than cmdref_<full command name>_* the
        // way every entry above does, because these seven commands are
        // namespaced under this resource's own `qbx_k9unit:` prefix (a
        // colon is not a valid bareword object-key character) -- see each
        // COMMAND_REFERENCE entry's own `command` field for the real,
        // exact RegisterCommand name each of these keys backs. ----
        cmdref_vault_usage: '/qbx_k9unit:vault',
        cmdref_vault_does: 'Makes your K9 hop over a low obstacle right in front of it, like a fence or a low wall.',
        cmdref_vault_needs: 'K9 access, and Advanced Agility enabled on this server. You must be controlling your K9, and the obstacle has to be low enough to clear.',
        cmdref_pursuitsprint_usage: '/qbx_k9unit:pursuitsprint',
        cmdref_pursuitsprint_does: 'Gives your K9 a short burst of real speed so it can catch up with a fleeing suspect it is already chasing.',
        cmdref_pursuitsprint_needs: 'K9 access, and Pursuit Sprint enabled on this server. There must be a fleeing suspect nearby for your K9 to chase.',
        cmdref_toggle_camera_usage: '/qbx_k9unit:toggleCamera',
        cmdref_toggle_camera_does: 'Switches your view between looking through your K9\'s own eyes (first-person) and the normal camera behind it (third-person). Press again to switch back.',
        cmdref_toggle_camera_needs: 'You must be controlling your K9. Nothing else -- no certification and no server setting can turn this off.',
        cmdref_toggle_camera_feed_usage: '/qbx_k9unit:toggleCameraFeed',
        cmdref_toggle_camera_feed_does: 'Opens a small picture-in-picture window showing what your partner (K9 or handler) can currently see. Press again to close it.',
        cmdref_toggle_camera_feed_needs: 'K9 access, an online partner within range, and Partner Camera Feed enabled on this server.',
        cmdref_toggle_thermal_vision_usage: '/qbx_k9unit:toggleThermalVision',
        cmdref_toggle_thermal_vision_does: 'Turns on heat vision: people and animals glow so they are easier to spot, even in the dark or through smoke. Press again to turn it off. Turning this on switches Night Vision off automatically.',
        cmdref_toggle_thermal_vision_needs: 'You must be controlling your K9, and Thermal Vision enabled on this server. No certification needed.',
        cmdref_toggle_night_vision_usage: '/qbx_k9unit:toggleNightVision',
        cmdref_toggle_night_vision_does: 'Turns on night vision so you can see clearly in the dark. Press again to turn it off. Turning this on switches Thermal Vision off automatically.',
        cmdref_toggle_night_vision_needs: 'You must be controlling your K9, and Night Vision enabled on this server. No certification needed.',
        cmdref_k9vision_usage: '/k9vision',
        cmdref_k9vision_does: 'Cycles your K9 vision: off, then Night Vision, then Thermal Vision, then back off -- skipping whichever of those two your server has turned off. Old names /qbx_k9unit:toggleThermalVision and /qbx_k9unit:toggleNightVision still jump straight to one specific mode, if that\'s what you want instead.',
        cmdref_k9vision_needs: 'You must be controlling your K9. No certification needed. Does nothing but notify you if both Night Vision and Thermal Vision are turned off on this server.',

        // ---- SERVER SETTINGS -- the one admin settings tab and its
        // Summary section (html/tablet.js's SETTINGS_SECTIONS). UI chrome
        // only: every section is an existing screen calling the same
        // tablet:* callbacks it always did.
        tab_settings: "Server Settings",
        settings_section_overview: "Summary",
        help_tab_settings_desc: "Every whole-server setting in one tab, picked from the row of sections at the top: Runtime Control (features and their numbers), Catalogs, the K9 Supply Shop, the Tablet Theme, and a Summary of what has been changed. You only see the sections you are allowed to change.",
        help_task_hc_settings_sections_template: "Server Settings holds: {sections}.",
        settings_overview_heading: 'Current configuration at a glance',
        settings_overview_intro: "A live summary of the sections next to this one -- nothing here is tracked separately, so it always matches what those screens show.",
        settings_overview_features_template: '{overridden} of {total} feature toggle(s) overridden from their config.lua default.',
        settings_overview_tunables_template: '{overridden} of {total} tunable(s) overridden from their config.lua default.',
        settings_overview_tiers_template: '{count} certification tier(s) configured.',
        settings_overview_xp_template: '{count} XP rank(s) configured.',
        settings_overview_shop_template: '{count} shop item(s) configured.',
        settings_overview_not_loaded: "Not loaded yet -- open that section to load it.",

        // ---- MUTATION ERROR TEXT (this pass, state-handling/error-
        // reporting consistency sweep) -- see mutationErrorText()'s own
        // header for the full write-up. runMutation() is the ONE shared
        // path every certify/decertify/tier/renewal/specialization/givexp/
        // permission/feature/role mutation on the Person screen (and
        // triggerFeature on My Record) goes through -- before this pass it
        // rendered every one of the ~30 distinct refusal reasons those
        // server callbacks can return as the SAME generic 'action_failed'
        // line, exactly the "collapses a dozen reasons into one generic
        // line" problem this pass exists to fix. Each key below is one
        // server-returned `error` code, one distinct sentence, phrased to
        // say what to do next wherever there is a next step (never just
        // restating the code) -- never anything the ACTING viewer could not
        // already see about their own attempt.
        mutation_error_invalid_target: 'That target could not be resolved. Refresh this screen and try again.',
        mutation_error_invalid_department: 'That department is not configured on this server.',
        mutation_error_department_mismatch: 'This person\'s live job no longer matches this department. Refresh their record and try again.',
        mutation_error_not_eligible: 'You are not currently an eligible certifier for this. You need the right rank or an explicit certifier grant.',
        mutation_error_denied: 'You are not authorized to do this. You need a High Command grant.',
        mutation_error_rate_limited: 'You\'re doing that too quickly. Wait a few seconds and try again.',
        mutation_error_busy: 'Someone else is editing this right now. Wait a moment and try again.',
        mutation_error_self_certification_disabled: 'Self-certification is turned off on this server.',
        mutation_error_self_grant_blocked: 'You cannot grant this to yourself.',
        mutation_error_target_must_be_online: 'This target must be online for this action. Try again once they are connected.',
        mutation_error_target_not_in_department: 'This target is not currently in a configured K9 department.',
        mutation_error_target_too_far: 'You are too far from the target. Move closer and try again.',
        mutation_error_target_not_k9_model: 'This target\'s current appearance is not a configured K9 model. Have them switch to a K9 ped first.',
        mutation_error_model_check_requires_online: 'This server requires the K9 model check, which only works for an online target. Try again while they are connected.',
        mutation_error_target_online_use_online_action: 'This target is currently online. Reopen their record and use the live action instead of the offline one.',
        mutation_error_already_certified: 'This target already holds an active certification for this department.',
        mutation_error_target_not_actively_certified: 'This target does not hold an active certification for this department.',
        mutation_error_requires_active_cert: 'This target needs an active, unexpired certification for this department before a specialization can be granted.',
        mutation_error_requires_tier_capability: 'This target\'s current certification tier does not allow specializations. Assign a tier that permits them first.',
        mutation_error_already_granted: 'This is already granted to the target.',
        mutation_error_not_granted: 'This target does not currently hold this.',
        mutation_error_invalid_specialization: 'That is not a recognized specialization.',
        mutation_error_invalid_tier: 'That is not a recognized certification tier.',
        mutation_error_tier_already_set: 'This target is already on that tier.',
        mutation_error_target_offline: 'The target disconnected mid-action. Refresh and try again.',
        mutation_error_target_no_department_cert: 'This target holds no certification for a configured department.',
        mutation_error_feature_disabled: 'This feature is turned off on this server.',
        mutation_error_invalid_permission: 'That is not a recognized permission key.',
        mutation_error_invalid_model: 'That is not a recognized K9 ped model.',
        mutation_error_not_available: 'This action is not available on this server right now.',
        mutation_error_no_active_assignment: 'This target has no active K9 appearance to revert.',
        mutation_error_no_fallback_configured: 'No fallback human model is configured on this server. Contact an administrator before reverting this target.',
        mutation_error_invalid_granter: 'Your own account could not be resolved. Try again, or contact an administrator.',
        mutation_error_db_error: 'A database error occurred. Try again; if this persists, contact an administrator.',
        mutation_error_actions_disabled: 'Tablet actions are currently turned off on this server.',
        mutation_error_not_partnered: 'That citizen is not currently partnered.',
        // ---- Help tab (owner-directed: "a separate tab that teaches you how
        // to use the entire tablet... super detailed but dumbed down") --
        // see buildHelpScreen()'s own header for the full design. ----
        help_heading: "How to Use This Tablet",
        help_intro_line1: "This page walks you through using the tablet from scratch, in plain language. Just need a quick lookup? The command list at the bottom of this page shows every command with a live yes/no on whether you can use it right now.",
        help_role_note_k9: "You are seeing the K9 version of this guide because you are currently playing as a dog.",
        help_role_note_handler: "You are seeing the Handler version of this guide because you are not currently playing as a dog.",
        help_role_note_uncertified: "You are seeing the Getting Started version of this guide because you do not hold an active certification yet.",
        help_role_note_high_command_suffix: "Because you are also High Command, the extra admin sections below are showing too.",
        help_start_heading: "Start Here",
        help_start_k9_1: "1. You are playing as the dog. A separate player -- your handler -- plays the human half of the team.",
        help_start_k9_2: "2. High command makes you the K9 from their tablet: they certify you as a K9 and pick your breed, in one step. From then on you have the role and the dog's body together.",
        help_start_k9_3: "3. Check the top of the My Record tab. It shows \"Partnered\" or \"No Partner\" -- that tells you whether a handler is currently paired with you.",
        help_start_k9_4: "4. If it says \"No Partner\", wait for a handler to walk up to you and choose \"Partner Up\" from their interact menu. You will get an accept-or-decline prompt -- accept it.",
        help_start_k9_5: "5. Scroll to the command list at the bottom of this page and read \"Basic K9 Commands\" and \"Combat & Restraint\" first -- those are your everyday moves and the keys already bound to them. Whatever you have started, you can always stop it with the same key that started it -- letting go is never blocked, even if your certification lapses mid-bite.",
        help_start_handler_1: "1. Look at the top of the My Record tab. It shows your name and, right under it, whether you are certified yet.",
        help_start_handler_2: "2. If it says you are not certified, find a supervisor -- someone with the right rank in your department, or a High Command officer -- and ask them to certify you. They do this from their own tablet's Command Console tab.",
        help_start_handler_3: "3. Once certified, the My Record tab's \"Ready to use right now\" list shows exactly which abilities you can use today. That list changes as your certification, tier, and server settings change -- check back after anything changes.",
        help_start_handler_4: "4. The command list at the bottom of this page shows the exact command and key for everything on that list.",
        help_start_handler_5: "5. If you want a K9 partner, find someone playing as a K9 and use \"Partner Up\" from your interact menu while standing near them. They get an accept-or-decline prompt.",
        help_start_handler_6: "6. If you want to become the K9 yourself instead of staying the handler, that is a separate role change -- see \"Turn Someone Into a K9\" further down this page.",
        help_start_high_command_heading: "Also: Because You Are High Command",
        help_start_high_command_intro: "Everything above still applies to you -- High Command is not a separate job, it is a handler or K9 who also has admin tools. Here is where to start with those tools specifically.",
        help_start_high_command_1: "1. Open the Command Console tab first and type the person's name, citizen ID or server ID into the one search box -- it searches everyone online and everyone certified at once. Someone offline and never certified? Type their exact citizen ID and press Open. Their whole record opens on one screen: certifications, role, XP, access and abilities, in the order you normally work down them.",
        help_start_high_command_2: "2. To set someone up, open them from the Command Console and press Certify under their department. Leave the choice on Handler for a handler, or pick a breed to make them the K9 -- that one press is the whole setup. Tier and specializations are optional extras on the same screen.",
        help_start_high_command_3: "3. If you need to know what someone has actually been doing, use the Audit Trail tab -- it is read-only and shows real history, not a guess.",
        help_start_high_command_4: "4. Every whole-server setting -- feature switches and their numbers, certification tiers, permission keys, XP ranks, the supply shop and the tablet theme -- is under one tab, Server Settings, one click per section. See \"Every Tab, Explained\" below for what each section does.",
        help_tabs_heading: "Every Tab, Explained",
        help_tabs_intro: "Only the tabs you can actually use are listed below -- if a tab is not shown here, you cannot see it on your own tablet either.",
        help_tab_my_record_desc: "Everything about you, in one place, and the first screen you land on: who you are and what to do next, then your certifications, then where you stand on both XP ladders, then every ability with its exact status -- the ones you can use now and the ones you still have to earn.",
        help_tab_console_desc: "One search box finds anyone: type a name, citizen ID or server ID and it searches everyone online and everyone certified at once (browsing those lists needs the Audit capability or High Command). Press Open to go straight to an exact citizen ID -- that always works, even for someone who has never been certified.",
        help_tab_theme_desc: "Change the tablet's own colors and title for every player on the server. Open it to re-brand the tablet, not to fix anything broken.",
        help_tab_roster_desc: "Everyone currently hired, across every configured department, with their callsign, certification tier, XP, and active partner if any. Switch between K9s and Handlers at the top; both share one \"Unassigned\" section -- certified people who have not been assigned to either roster yet, which is not an error, just people still waiting to be sorted. Open a row to hire, fire, promote, demote, change someone's roster role, or set a callsign -- all from their profile, the same one the Command Console opens.",
        help_tab_runtime_control_desc: "Turn individual features on or off for the whole server, and adjust the numeric settings behind them, without editing config files or restarting. Open it when a feature needs to change right now, or when you need to know whether one is currently on.",
        help_tab_audit_desc: "A read-only history of who certified whom, who partnered with whom, who searched whom, XP grants, and department-wide activity. This is privacy-sensitive -- it shows real names and real actions. Open it to investigate something that already happened.",
        help_tasks_heading: "How to Do the Common Things",
        help_task_get_certified_heading: "Get Certified",
        help_task_get_certified_1: "1. Find someone who can certify you: a supervisor at the right rank in your department, or anyone in High Command.",
        help_task_get_certified_2: "2. Ask them in person or over the radio. If YOU are a supervisor and your server allows it, you can also certify yourself from the Console tab, or with /k9certify and your own ID.",
        help_task_get_certified_3_template: "3. They open their own tablet's Command Console tab, find your name or citizen ID, open your record, and press {certifyLabel} for your department. You will see the change on your own My Record tab the next time you open it.",
        help_task_partner_up_heading: "Partner Up With a Handler or K9",
        help_task_partner_up_1: "1. Stand close to the other player -- handler or K9, either side can start this.",
        help_task_partner_up_2: "2. Open your interact menu on them and choose \"Partner Up\" -- if you are the K9, your K9 Unit radial menu has the same option.",
        help_task_partner_up_3: "3. The other player gets an accept-or-decline prompt. Once they accept, the My Record tab for both of you shows \"Partnered\" instead of \"No Partner\".",
        help_task_partner_up_4: "4. To split up later, open your K9 Unit radial menu and choose \"Break Partnership\" -- either side can end it, any time, even if the other player is offline.",
        help_task_vehicle_heading: "Put Your K9 In the Car",
        help_task_vehicle_1: "1. As the K9, walk up to the vehicle your handler is using. Only vehicles set up to carry a K9 will show this option -- ask High Command if you think one is missing it.",
        help_task_vehicle_2: "2. Open your interact menu on the vehicle and choose \"Get in the Back Seat\".",
        help_task_vehicle_3: "3. To let your K9 back out, open the interact menu on the vehicle again and choose \"Get Out of the Vehicle\".",
        help_task_search_heading: "Search a Suspect or Vehicle",
        help_task_search_1: "1. As the K9, walk up to a person or a vehicle.",
        help_task_search_2: "2. Open your interact menu and choose \"Search Person for Contraband\" or \"Search Vehicle for Contraband\". Your K9 plays a sniffing animation while the server checks the result.",
        help_task_search_3: "3. This only works while you are playing as the K9 -- a handler cannot search on the K9's behalf.",
        help_task_treat_heading: "Treat an Injured K9",
        help_task_treat_1: "1. This is not limited to handlers -- anyone whose job is set up for it (usually EMS) can do this, as long as they are carrying a K9 medkit item.",
        help_task_treat_2: "2. Walk up to the injured K9 and open your interact menu on them. Choose \"Treat This K9's Injuries (Uses a K9 Medkit)\".",
        help_task_treat_3: "3. The medkit item is used up. If the option is not there at all, either this feature is turned off on this server, or you do not have a K9 medkit.",
        // ADDED (this pass): Deploy a Kennel / Use Scent Vision -- both are
        // recent headline features already documented in the Commands tab
        // (COMMAND_REFERENCE), but had no step-by-step walkthrough here,
        // unlike every other common task on this screen -- reported as a
        // gap in this same pass's own report and closed here to match this
        // section's existing shape. Quoted button/menu/keybind labels below
        // ("Kennel (Deploy/Enter/Exit)", "Rest in Kennel", "Pick Up Kennel",
        // "K9: Toggle Scent Vision") are each drift-guarded against their
        // real radial/target/keybind locale values by
        // tests/helpquotedlabels_spec.lua, same posture as every other
        // quoted label already on this screen.
        //
        // RENAMED, THIS PASS (menu-parity/menu-audit fix): the radial item
        // this walkthrough describes used to be a standalone "Deploy Kennel"
        // action with a separate, ungated "Exit Kennel" item beside it. An
        // owner-directed decluttering pass merged BOTH (plus enter/close/
        // open) into the ONE 'k9_kennel' item, whose real label is now
        // "Kennel (Deploy/Enter/Exit)" (locale('radial.kennel_label')) --
        // see client/radial.lua's own "MERGED, owner-directed decluttering
        // pass" comment. This walkthrough kept quoting the old, pre-merge
        // name -- exactly the "guide names a button that does not exist"
        // bug class this pass's own task flagged by name (the same class as
        // the tablet-reporting-dead-commands-as-available bug fixed
        // earlier). Fixed below to quote the real, current label;
        // tests/helpquotedlabels_spec.lua's own QUOTED_LABEL_CHECKS row was
        // repointed at 'radial.kennel_label' (the live key) in the same
        // change -- 'radial.deploy_kennel_label' (the now fully orphaned old
        // key, still present in locales/en.json's `radial` group, which
        // this file's own owner cannot edit this pass) has no code or test
        // reference left anywhere and is reported for removal by whoever
        // owns that group.
        help_task_kennel_heading: "Deploy a Kennel",
        help_task_kennel_1: "1. As the K9, open your K9 Unit radial menu and choose \"Kennel (Deploy/Enter/Exit)\". It is placed on the ground just in front of you.",
        help_task_kennel_2: "2. You can only have one active kennel at a time -- pick it back up (walk up to it and use the \"Pick Up Kennel\" option) before deploying another.",
        help_task_kennel_3: "3. Any K9 can use a deployed kennel to rest: walk up to it and choose \"Rest in Kennel\". Choose \"Exit Kennel\" (or use its own keybind) to get back out.",
        help_task_kennel_4: "4. This same \"Kennel (Deploy/Enter/Exit)\" option always appears in the radial menu, even when deploying is turned off -- if choosing it does nothing while you have no kennel out, this feature is disabled on this server -- ask High Command.",
        help_task_stop_being_k9_heading: "Go Back to Being Human",
        help_task_stop_being_k9_1: "1. There is no self-service way to turn yourself back -- and that is deliberate, not a bug. Being the K9 is a role high command puts you in, so high command is who takes you back out of it.",
        help_task_stop_being_k9_2: "2. Ask any High Command officer to open their tablet, find you on the Command Console, and press \"Revert to Human\". It takes them about ten seconds.",
        help_task_stop_being_k9_3: "3. It always works. They can do it even if your certification has lapsed, your access was revoked, or you hold no grants at all -- there is no state you can end up in where the button stops working.",
        help_task_stop_being_k9_4: "4. Your original appearance was saved when you were turned into the K9, so you get your own character back, not a default one. Logging out and back in does NOT revert you: you stay the K9 across sessions until someone presses that button.",
        help_task_scent_vision_heading: "Use Scent Vision",
        help_task_scent_vision_1: "1. As the K9, press the \"K9: Toggle Scent Vision\" key (. -- the full stop -- by default, rebindable in Settings > Key Bindings > FiveM) to show coloured dots marking where nearby people have recently walked. Press it again to turn it off.",
        help_task_scent_vision_2: "2. Only a handful of the closest people's trails are shown at once, each its own colour, and the dots fade out and disappear as they get older.",
        help_task_scent_vision_3: "3. If pressing the key does nothing, either this feature is turned off on this server, or this server has set it to run for everyone automatically instead of needing the key -- ask High Command.",
        help_task_hc_certify_someone_heading: "Certify Someone",
        help_task_hc_certify_someone_1: "1. Go to the Console tab and type their name, citizen ID or server ID into the search box. Someone brand new who is offline will not be in either list -- type their exact citizen ID and press Open. Most certification actions require the target to be online.",
        help_task_hc_certify_someone_2_template: "2. Open their record. Next to {certifyLabel}, leave it on Handler or pick a K9 breed, then press it. Tier and specializations are optional, on the same screen.",
        help_task_hc_toggle_feature_heading: "Turn a Feature On or Off",
        help_task_hc_toggle_feature_1: "1. Open Server Settings, pick Runtime Control, and find the feature by name.",
        help_task_hc_toggle_feature_2: "2. Flip its switch. Most features take effect immediately for every player -- but not all of them do. Read the small note under the switch: some only apply after a restart, and a few (protected or not-yet-audited features) cannot be changed from here at all.",
        help_task_hc_assign_k9_heading: "Turn Someone Into a K9",
        help_task_hc_assign_k9_1: "1. Go to the Command Console tab, find the person, and open their record.",
        help_task_hc_assign_k9_2_template: "2. Next to {certifyLabel} under their department, pick their breed instead of Handler and press it -- they are certified and turned into that dog at once. Already certified? Use \"{assignLabel}\" in the K9 Role section to pick or change their breed.",
        help_task_hc_assign_k9_3_template: "3. To undo it, press \"{revertLabel}\" -- this works even if they hold no certification or access at all, so it is always available as an emergency undo.",
        help_task_hc_check_history_heading: "Check What Someone Did",
        help_task_hc_check_history_1: "1. Open the Audit Trail tab.",
        help_task_hc_check_history_2: "2. Pick what you are looking for -- certifications, partnerships, searches, XP grants, or department-wide activity -- and type the citizen ID.",
        help_task_hc_check_history_3: "3. This is privacy-sensitive: it shows real names, real actions, and real timestamps. Only use it when you actually need to investigate something.",
        help_trouble_heading: "When Something Doesn't Work",
        help_trouble_intro: "Every refusal on this tablet tells you the real reason -- here is what the most common ones actually mean and what to do about them.",
        help_trouble_no_k9_access_title: "\"You cannot use K9 features right now.\" (a red notification in the game, not on the tablet)",
        help_trouble_no_k9_access_body: "This means one of two things: you are not currently wearing a K9 model, or you do not hold an active K9 certification (or access grant). Check the My Record tab -- if it does not show you as certified, see \"Get Certified\" above. If it does, ask a High Command officer to check whether you are actually set as a K9 (\"Assign K9 Role\" on your record in their Command Console).",
        help_trouble_not_certified_title: "\"Not certified\"",
        help_trouble_not_certified_body: "You do not hold an active certification for whatever this needs. See \"Get Certified\" above -- ask a supervisor or High Command.",
        help_trouble_feature_off_title: "\"Disabled server-wide\" or \"This feature is turned off on this server\"",
        help_trouble_feature_off_body: "A High Command officer switched this off for the whole server, from Server Settings (Runtime Control). It can usually be turned back on the same way -- ask them. A small number of features are marked protected or not-yet-audited and genuinely cannot be turned on from the tablet at all; Runtime Control says so directly when that is the case.",
        help_trouble_needs_grant_title: "\"Requires a grant (not granted)\" or \"Requires higher authorization\"",
        help_trouble_needs_grant_body: "The feature itself is on, and you are certified, but this specific extra permission has not been given to you personally. Only High Command can grant it, from your record in their Command Console (or Server Settings > Catalogs, if the permission itself does not exist yet).",
        help_trouble_rate_limited_title: "\"You're doing that too quickly\"",
        help_trouble_rate_limited_body: "Wait a few seconds and try again. This is a safety limit, not a permission problem -- nobody needs to grant you anything to fix it.",
        help_trouble_self_cert_disabled_title: "\"Self-certification is turned off on this server\"",
        help_trouble_self_cert_disabled_body: "You cannot certify yourself on this server. Ask someone else who can certify -- a supervisor or High Command.",
        help_trouble_target_offline_title: "\"This target must be online\"",
        help_trouble_target_offline_body: "The person you are trying to act on needs to be connected to the server. Ask them to log in, then try again.",
        help_trouble_insufficient_authorization_title: "\"You are not authorized to do this. You need a High Command grant.\"",
        help_trouble_insufficient_authorization_body: "This action is High Command only. If you believe you should have it, ask an existing High Command officer to raise your department rank, or grant you the specific permission it needs.",

        // ---- Partnerships tab (this pass, coder-ui) -- owner, verbatim:
        // "a partnership tab should be shown on all tablets as a tab...
        // high command is a handler or a k9 and should have control over
        // it also but the partnership tab should show whos there
        // partners." ONE tab, shown to every viewer including high
        // command (never gated on isHighCommand/canManageRoster) --
        // see buildTabs()/buildPartnershipsScreen()'s own header comments.
        tab_partnerships: 'Partnerships',
        home_k9_progression_heading: 'Your Progression',
        home_view_partners_label: 'View Partnerships',
        home_view_partners_hint: 'See your current and past partners.',
        partnerships_feature_disabled: 'Partnership tracking is turned off on this server.',
        partnerships_history_heading: 'Partnership History',
        partnerships_history_empty: 'You have never been partnered with anyone.',
        // {count} -- HISTORICAL total (this citizenid's own row count across
        // every partnership they have ever held, active or ended), NEVER a
        // live concurrent count -- server/partnership.lua enforces at most
        // one ACTIVE partnership per citizenid at a time (verified this
        // pass), so "how many handlers has this k9 had" is always this
        // historical number, never a simultaneous one.
        partnerships_count_summary_template: 'You have had {count} partner(s) in total.',
        partnerships_truncated_notice_template: 'Showing your {shown} most recent partnerships.',
        partnerships_state_active: 'Active',
        partnerships_state_ended: 'Ended',
        partnerships_established_label: 'Partnered since',
        partnerships_ended_label: 'Ended',
        partnerships_ended_by_label: 'Ended by',
        partnerships_ended_system_template: 'Automatically ({reason})',
        // "Tenure Level," never "XP Tier" -- deliberately distinct
        // vocabulary from the K9's own XP tier (my_xp_heading/xpLine
        // elsewhere): this is server/tenure.lua's PARTNERSHIP tenure-bonus
        // tier, a property of the PAIR, not of either individual's own K9
        // progression -- see server/tablet.lua's CALLBACKS 7-9 header for
        // why this file never presents it as tamper-proof (the anti-farm
        // guard behind it is disclosed as in-memory-only).
        partnerships_tier_label: 'Tenure Level',
        partnerships_tier_none: 'No tenure milestone reached yet',
        partnerships_tier_value_template: 'Tier {tier}',
        partnerships_next_tier_countdown_template: '{days} day(s) until the next tenure milestone',
        // ---- High command admin lookup, shown ON TOP of the personal
        // section on this SAME tab (owner: "high command... should have
        // control over it also... not a separate screen").
        partnerships_admin_heading: "Look Up Someone's Partnerships",
        partnerships_admin_none: 'This citizen has never been partnered.',
        partnerships_force_end_label: 'End Partnership',
        help_tab_partnerships_desc: "Shows who you are currently partnered with, or that you have no partner right now. If you are High Command, this same tab also lets you look up anyone else's partnership. Open it to check a pairing -- partnering up and breaking up both happen out in the world (interact menu or K9 Unit radial menu), not on this screen.",

        // ---- K9/HANDLER PERSONNEL ROSTERS (docs/history/ROSTER_SPEC.md, Phase B) ----
        // owner, verbatim: "make it in the tablet where there is a roster
        // where we can assign callsigns see list of hired k9s and full
        // menu to fire promote etc" / "Also a separate roster for
        // handlers same thing" / "The roster should be able to be where
        // we can also assign roles sub features features permissions
        // etc" / "Like click there profile and it opens a menu" / "Also
        // in the roster be able to reorder them by rank." The 24 keys
        // docs/history/ROSTER_SPEC.md §10 names, plus a small number this pass found it
        // genuinely needed beyond that list (each commented individually
        // below) -- every key here is also in client/tablet.lua's
        // TABLET_STRING_KEYS and locales/en.json's `tablet` group, per this
        // file's own three-way locale contract (tests/tabletlocalization_spec.lua).
        tab_roster: "Personnel Roster",
        roster_bucket_label: "Show:",
        roster_bucket_k9: 'K9s',
        roster_bucket_handlers: 'Handlers',
        roster_unassigned_heading: 'Unassigned',
        roster_unassigned_explainer: "Certified, but not yet assigned to a roster -- this is normal, not an error. On the day this feature ships, everyone certified starts here. Nothing about anyone's in-game abilities changes while they sit in this list; open their profile and assign them as a K9 or a Handler when you're ready.",
        roster_callsign_column: 'Callsign',
        roster_callsign_none: 'No callsign',
        roster_callsign_label: 'Callsign',
        roster_callsign_save: 'Save Callsign',
        roster_callsign_taken_error: 'That callsign is already in use by someone else in this department -- K9 and Handler callsigns share one namespace here, so two units can never answer to the same call. Pick a different one.',
        roster_callsign_invalid_chars_error: 'Callsigns must be 1-12 characters long, using only letters, digits, spaces, and hyphens.',
        roster_hire_label: 'Hire',
        roster_hire_role_prompt: 'This person holds an active certification but has not been assigned to a roster yet. Choose one:',
        roster_hire_role_k9: 'K9',
        roster_hire_role_handler: 'Handler',
        roster_fire_label: 'Fire',
        roster_fire_confirm_prompt: "Firing ends this person's working status immediately -- click twice to confirm.",
        roster_fire_self_warning: 'You are about to fire yourself. If self-certification changes are disabled on this server, this will be refused exactly like a self-typed /k9decertify.',
        roster_role_change_label: 'Roster Role',
        roster_role_change_confirm_prompt: "Changing this person's roster role clears their current callsign -- a K9 callsign and a Handler callsign mean different things, so it is never carried over automatically. You will need to set a new one afterward.",
        roster_sort_label: 'Sort by',
        roster_sort_by_tier: 'Certification Tier',
        roster_sort_by_grade: 'Department Grade',
        roster_sort_by_xp: 'XP',
        roster_dogcharacter_pin_note: '(cosmetically pinned as a dog)',
        // ---- Beyond docs/history/ROSTER_SPEC.md §10's own list -- needed once this
        // pass actually built the screens: every outcome code
        // qbx_k9unit:server:rosterSetPersonnelRole/rosterSetCallsign can
        // return needs a REAL message (this file's own task brief), and
        // mutationErrorText() above does not already cover these four
        // (unlike invalid_target/invalid_department/department_mismatch/
        // rate_limited/db_error/not_authorized, which it already does --
        // see rosterMutationErrorText()'s own doc comment).
        roster_error_invalid_personnel_role: 'That is not a recognized roster role -- pick K9 or Handler.',
        roster_error_not_certified: 'This person does not currently hold an active certification in this department, so they cannot be added to a roster yet.',
        roster_error_already_assigned: 'Someone already changed this roster assignment a moment ago -- refresh to see the current state.',
        roster_error_no_active_personnel: 'This person is not currently on a roster, so they have no callsign to set. Assign them as a K9 or a Handler first.',
        roster_bucket_empty: 'Nobody is currently on this roster.',
        roster_unassigned_none: 'Nobody is waiting to be assigned right now.',
        roster_certified_since_column: 'Certified Since',
        // HELP_TAB_CATALOG entries for the two new tabs above (tests/helptabcoverage_spec.lua's
        // own drift guard: every real tab_* key needs a matching catalog entry).
    };

    /** English fallback for Config.Permissions -- MUST be kept byte-identical
     * to config.lua's own Config.Permissions label/description text (copied
     * verbatim from there, not invented here). Used only when
     * tablet:open's `capabilities` payload is missing or incomplete --
     * exactly the same fallback posture as DEFAULT_STRINGS above.
     * @type {Record<string,{label:string,description:string}>} */
    var DEFAULT_CAPABILITIES = {
        'k9.access': { label: 'Use K9 abilities', description: 'Equivalent to holding a K9 certification. Grant this to let someone work as a K9 without going through a certifying officer.' },
        'k9.certify': { label: 'Certify and decertify others', description: 'Grant and revoke K9 certifications. Normally requires a senior rank; this hands it to one specific person.' },
        'k9.audit': { label: 'View the audit records', description: 'Run the read-only audit commands. PRIVACY-SENSITIVE: this reveals who searched whom, and when.' },
        'k9.givexp': { label: 'Grant XP', description: 'Award XP directly to a K9 or handler. This mints economy value -- every use is logged.' },
    };

    /** Canonical order the four capability keys are rendered in, wherever
     * they're listed (my record, person summary) -- otherwise object key
     * order would depend on whatever order the server happens to send. */
    var CAPABILITY_ORDER = ['k9.access', 'k9.certify', 'k9.audit', 'k9.givexp'];

    /** English fallback theme -- MUST be kept byte-identical to
     * server/runtimecontrol.lua's own DEFAULT_THEME, so this page looks
     * right even before tablet:getTheme's own response lands (or if it
     * never does -- see loadTheme() below). Never itself sent anywhere;
     * this is a local rendering fallback only, same posture as
     * DEFAULT_STRINGS/DEFAULT_CAPABILITIES above.
     * @type {{primaryColor:string,accentColor:string,backgroundColor:string,textColor:string,density:string,headerTitle:string}} */
    var DEFAULT_THEME = {
        primaryColor: '#2563eb',
        accentColor: '#f59e0b',
        backgroundColor: '#111827',
        textColor: '#f9fafb',
        density: 'comfortable',
        headerTitle: 'K9 Command Tablet',
    };

    /** The exact, fixed density enum server/runtimecontrol.lua's own
     * IsValidDensity accepts -- rendered as a `<select>`, never free text,
     * matching that file's own "a fixed lookup table, never free text"
     * comment. This page enforces the SAME set purely so the dropdown
     * cannot even offer a value the server would reject -- the server's own
     * re-check is still what actually matters (see THE SECURITY RULE). */
    var THEME_DENSITY_OPTIONS = ['comfortable', 'compact'];

    // ------------------------------------------------------------------
    // COMMAND REFERENCE (this pass) -- "the resource registers dozens of
    // commands, a player has no way to discover them in-game". This is
    // the single, HAND-MAINTAINED catalog that screen renders from --
    // see buildCommandReferenceScreen() below for the UI itself.
    //
    // DRIFT GUARD, NOT A PROMISE THIS NEVER ROTS BY ITSELF: nothing on
    // this page derives COMMAND_REFERENCE from the real RegisterCommand
    // calls (there is no shared runtime registry the commands themselves
    // feed -- they are plain `RegisterCommand(name, ...)` calls scattered
    // across two dozen-plus server/client files with nothing to
    // introspect from a browser sandbox). What keeps this list honest
    // instead is tests/commandreferenceregistry_spec.lua: it greps the
    // REAL server/*.lua + client/*.lua source for every literal
    // `RegisterCommand('...')` name (the
    // `RegisterCommand\('[a-zA-Z0-9_:]+'` shape -- widened this pass to
    // also catch a command namespaced under this resource's own
    // `qbx_k9unit:` prefix, the exact gap that let six real keybind
    // commands -- qbx_k9unit:vault/pursuitsprint/toggleCamera/
    // toggleCameraFeed/toggleThermalVision/toggleNightVision -- go
    // undocumented here until that pass)
    // and fails LOUDLY, naming the exact command, if that set and this
    // catalog's own `command` field set ever diverge in EITHER direction
    // -- a command added here with no real RegisterCommand behind it, or a
    // real command with no entry here. Deliberately not naming an exact
    // count here -- a hardcoded total is one more place to go stale every
    // time a command is added, exactly what this task's own accuracy pass
    // fixed for the "36 commands" phrasing this comment used to carry --
    // add the next command to this array in the SAME change that
    // registers it, or that spec turns red.
    //
    // Each entry:
    //   command    string   -- the exact RegisterCommand name, e.g. 'k9audit cert'
    //   category   string   -- a COMMAND_REFERENCE_CATEGORIES key, grouping by
    //                          WHAT THE PLAYER IS TRYING TO DO, never by which
    //                          file registers it
    //   adminOnly  boolean  -- true for a command whose real gate is a
    //                          rank/permission/High-Command check rather than
    //                          "any certified handler" -- rendered with the
    //                          (Admin) badge for EVERY viewer, high command
    //                          included, per this task's own "high command
    //                          sees everything, with the admin ones marked as
    //                          such" instruction
    //   usageKey/doesKey/needsKey  string -- DEFAULT_STRINGS/locales keys for
    //                          the argument shape, the one-line plain-English
    //                          description, and the plain-English requirement
    //                          text, respectively
    //   gate       object   -- see commandReferenceStatus() below for exactly
    //                          how each `kind` is resolved; NEVER an
    //                          enforcement decision, only this screen's own
    //                          best-effort, honest-when-uncertain PRESENTATION
    //                          of what the server would decide -- the server
    //                          re-checks everything independently regardless
    //                          of what this badge says (THE SECURITY RULE).
    // ------------------------------------------------------------------
    var COMMAND_REFERENCE_CATEGORIES = [
        // Listed FIRST, ahead of every other category (this pass, keybinds
        // handoff): these are the everyday, split-second actions a brand
        // new handler is most likely to look for first -- see
        // client/keybinds.lua's own header for why these are the ones
        // that got a rebindable key at all.
        { key: 'basic_commands', labelKey: 'cmdref_category_basic_commands' },
        { key: 'combat', labelKey: 'cmdref_category_combat' },
        // Camera/vision keybinds (this pass, integration-sweep undocumented-
        // keybinds fix) -- toggleCamera/toggleCameraFeed/toggleThermalVision/
        // toggleNightVision all change what you SEE, never a command TO your
        // K9, which is why these four get their own category rather than
        // folding into Basic K9 Commands or Combat & Restraint above.
        { key: 'vision', labelKey: 'cmdref_category_vision' },
        { key: 'field_gear', labelKey: 'cmdref_category_field_gear' },
        { key: 'records', labelKey: 'cmdref_category_records' },
        { key: 'certification', labelKey: 'cmdref_category_certification' },
        { key: 'xp', labelKey: 'cmdref_category_xp' },
        { key: 'audit', labelKey: 'cmdref_category_audit' },
        { key: 'devtools', labelKey: 'cmdref_category_devtools' },
        { key: 'permissions', labelKey: 'cmdref_category_permissions' },
    ];

    var COMMAND_REFERENCE = [
        // ---- Basic K9 Commands -- the owner's own named "fast" examples
        // (client/keybinds.lua). `defaultKeybind` (this pass) is a NEW,
        // OPTIONAL field: the RegisterKeyMapping default this exact command
        // ships with, verified directly against client/keybinds.lua/
        // config.lua source, not assumed -- rendered by
        // buildCommandReferenceRow() below as "Default key: X", with a
        // load-bearing caveat (cmdref_keybind_caveat, shown once in this
        // screen's own intro) that a default only applies to a player who
        // has never rebound that key, and never moves an existing one. ----
        { command: 'k9sit', category: 'basic_commands', adminOnly: false, usageKey: 'cmdref_k9sit_usage', doesKey: 'cmdref_k9sit_does', needsKey: 'cmdref_k9sit_needs', gate: { kind: 'access' }, defaultKeybind: 'G', keyLabelKey: 'keys_action_sit' },
        { command: 'k9bark', category: 'basic_commands', adminOnly: false, usageKey: 'cmdref_k9bark_usage', doesKey: 'cmdref_k9bark_does', needsKey: 'cmdref_k9bark_needs', gate: { kind: 'access', featureKey: 'BasicBarkSounds' }, defaultKeybind: 'U', keyLabelKey: 'keys_action_bark' },
        { command: 'k9scentvision', category: 'basic_commands', adminOnly: false, usageKey: 'cmdref_k9scentvision_usage', doesKey: 'cmdref_k9scentvision_does', needsKey: 'cmdref_k9scentvision_needs', gate: { kind: 'access', featureKey: 'ScentVision' }, defaultKeybind: '.', keyLabelKey: 'keys_action_scent_vision' },

        // ---- Combat & Restraint (client/keybinds.lua) -- same
        // `defaultKeybind` provenance note as Basic K9 Commands above.
        { command: 'k9bitehold', category: 'combat', adminOnly: false, usageKey: 'cmdref_k9bitehold_usage', doesKey: 'cmdref_k9bitehold_does', needsKey: 'cmdref_k9bitehold_needs', gate: { kind: 'access', featureKey: 'BiteAndHold' }, defaultKeybind: 'B', keyLabelKey: 'keys_action_bite_hold' },
        { command: 'k9takedown', category: 'combat', adminOnly: false, usageKey: 'cmdref_k9takedown_usage', doesKey: 'cmdref_k9takedown_does', needsKey: 'cmdref_k9takedown_needs', gate: { kind: 'access', featureKey: 'NonLethalTakedown' }, defaultKeybind: '[', keyLabelKey: 'keys_action_takedown' },
        { command: 'k9dragtoggle', category: 'combat', adminOnly: false, usageKey: 'cmdref_k9dragtoggle_usage', doesKey: 'cmdref_k9dragtoggle_does', needsKey: 'cmdref_k9dragtoggle_needs', gate: { kind: 'access', featureKey: 'PropDragging' }, defaultKeybind: 'Y', keyLabelKey: 'keys_action_drag' },
        // qbx_k9unit:vault/qbx_k9unit:pursuitsprint (integration-sweep
        // fix): two REAL, working keybind commands that had ZERO
        // COMMAND_REFERENCE entry before that pass -- see
        // tests/commandreferenceregistry_spec.lua's own header "WIDENED,
        // THIS PASS" for exactly why the drift guard never caught this.
        // Grouped into Combat & Restraint, not a new category, because
        // config.lua's own "COMBAT & ADVANCED AGILITY" section already
        // groups AgilityAdvanced alongside BiteAndHold/NonLethalTakedown/
        // PropDragging as one family, and Pursuit Sprint is a chase-support
        // ability for the same apprehension workflow. Both command names
        // use this resource's OWN `qbx_k9unit:` prefix, not a bare `k9x`
        // name -- both RegisterCommand calls in client/agility.lua and
        // client/pursuitsprint.lua pair a RegisterKeyMapping, whose own id
        // must be globally unique across every resource a server loads,
        // unlike a chat-only command.
        { command: 'qbx_k9unit:vault', category: 'combat', adminOnly: false, usageKey: 'cmdref_vault_usage', doesKey: 'cmdref_vault_does', needsKey: 'cmdref_vault_needs', gate: { kind: 'access', featureKey: 'AgilityAdvanced' }, defaultKeybind: 'X', keyLabelKey: 'keys_action_vault' },
        { command: 'qbx_k9unit:pursuitsprint', category: 'combat', adminOnly: false, usageKey: 'cmdref_pursuitsprint_usage', doesKey: 'cmdref_pursuitsprint_does', needsKey: 'cmdref_pursuitsprint_needs', gate: { kind: 'access', featureKey: 'PursuitSprint' }, defaultKeybind: 'N', keyLabelKey: 'keys_action_pursuit_sprint' },
        { command: 'qbx_k9unit:toggleCamera', category: 'vision', adminOnly: false, usageKey: 'cmdref_toggle_camera_usage', doesKey: 'cmdref_toggle_camera_does', needsKey: 'cmdref_toggle_camera_needs', gate: { kind: 'open' }, defaultKeybind: 'L', keyLabelKey: 'keys_action_toggle_camera' },
        { command: 'qbx_k9unit:toggleCameraFeed', category: 'vision', adminOnly: false, usageKey: 'cmdref_toggle_camera_feed_usage', doesKey: 'cmdref_toggle_camera_feed_does', needsKey: 'cmdref_toggle_camera_feed_needs', gate: { kind: 'access', featureKey: 'CameraFeedPiP' }, defaultKeybind: 'H', keyLabelKey: 'keys_action_camera_feed', defaultKeybindConfigurable: true },
        // qbx_k9unit:toggleThermalVision / qbx_k9unit:toggleNightVision --
        // OWNER REVERSAL (coder-architect, this pass): an earlier pass had
        // folded these two into a single 'k9vision' cycle entry and removed
        // their own Commands-tab rows. The owner has since asked for
        // thermal and night vision to be separate, first-class controls
        // again ("I want the thermal and night vision separate") -- both
        // get their own row back here, unchanged commands underneath (still
        // real RegisterCommand + RegisterKeyMapping calls in
        // client/vision.lua, still bound to K/J by default, never actually
        // removed even while this pass's rows were gone). See
        // tests/commandreferenceregistry_spec.lua's HIDDEN_ALIAS_COMMANDS
        // ('vision' family, now empty) / COMMANDS_TAB_CLEANUP_COMPLETE
        // (vision reverted to not-complete).
        { command: 'qbx_k9unit:toggleThermalVision', category: 'vision', adminOnly: false, usageKey: 'cmdref_toggle_thermal_vision_usage', doesKey: 'cmdref_toggle_thermal_vision_does', needsKey: 'cmdref_toggle_thermal_vision_needs', gate: { kind: 'open', featureKey: 'ThermalVision' }, defaultKeybind: 'K', keyLabelKey: 'keys_action_thermal', defaultKeybindConfigurable: true },
        { command: 'qbx_k9unit:toggleNightVision', category: 'vision', adminOnly: false, usageKey: 'cmdref_toggle_night_vision_usage', doesKey: 'cmdref_toggle_night_vision_does', needsKey: 'cmdref_toggle_night_vision_needs', gate: { kind: 'open', featureKey: 'NightVision' }, defaultKeybind: 'J', keyLabelKey: 'keys_action_night', defaultKeybindConfigurable: true },
        // 'k9vision' (Off -> Night -> Thermal -> Off) is KEPT as an extra,
        // optional convenience alongside the two explicit toggles above --
        // owner's own steer ("keep it as an extra... someone may prefer
        // it"), same additive shape as 'k9kennel' alongside
        // k9deploykennel/k9exitkennel (docs/history/COMMAND_CONSOLIDATION_SPEC.md #5).
        { command: 'k9vision', category: 'vision', adminOnly: false, usageKey: 'cmdref_k9vision_usage', doesKey: 'cmdref_k9vision_does', needsKey: 'cmdref_k9vision_needs', gate: { kind: 'open' }, defaultKeybind: 'I', keyLabelKey: 'keys_action_vision_cycle' },

        // ---- Field Gear & Equipment ----
        // k9leash/k9vehicle/k9partner/k9gear/k9treat -- menu-parity pass
        // ("chat commands, 3rd eye, and radial menus" -- every feature
        // reachable from all three, a menu audit found these five reachable
        // only via ox_target and/or the radial menu). Each is a single,
        // contextual-dispatch command reaching the SAME resource-global(s)
        // its client/radial.lua item already calls -- see each command's own
        // RegisterCommand in its owning client/*.lua file for the full
        // writeup. Grouped here with kennel/propattach/fetch ball/eat/drink
        // above and below: self-service field actions with no keybind of
        // their own, the same bucket those already live in.
        { command: 'k9leash', category: 'field_gear', adminOnly: false, usageKey: 'cmdref_k9leash_usage', doesKey: 'cmdref_k9leash_does', needsKey: 'cmdref_k9leash_needs', gate: { kind: 'access', featureKey: 'LeashMechanics' } },
        { command: 'k9vehicle', category: 'field_gear', adminOnly: false, usageKey: 'cmdref_k9vehicle_usage', doesKey: 'cmdref_k9vehicle_does', needsKey: 'cmdref_k9vehicle_needs', gate: { kind: 'access', featureKey: 'VehicleEntryExit' } },
        { command: 'k9partner', category: 'field_gear', adminOnly: false, usageKey: 'cmdref_k9partner_usage', doesKey: 'cmdref_k9partner_does', needsKey: 'cmdref_k9partner_needs', gate: { kind: 'access', featureKey: 'HandlerPartnership' } },
        { command: 'k9gear', category: 'field_gear', adminOnly: false, usageKey: 'cmdref_k9gear_usage', doesKey: 'cmdref_k9gear_does', needsKey: 'cmdref_k9gear_needs', gate: { kind: 'access', featureKey: 'K9Inventory' } },
        // k9treat -- gate: 'open', NOT 'access': server/medkit.lua's real
        // authorization for the TREATER is job/department membership alone
        // (IsMedkitUserAuthorized), never k9.access -- see
        // client/medkit.lua's own header. 'access' would show a wrong badge
        // (a certified K9 with the wrong job would read "Available"; a
        // non-K9 EMS officer with the right job would read "Not certified").
        { command: 'k9treat', category: 'field_gear', adminOnly: false, usageKey: 'cmdref_k9treat_usage', doesKey: 'cmdref_k9treat_does', needsKey: 'cmdref_k9treat_needs', gate: { kind: 'open', featureKey: 'K9Medkit' } },
        { command: 'k9deploykennel', category: 'field_gear', adminOnly: false, usageKey: 'cmdref_k9deploykennel_usage', doesKey: 'cmdref_k9deploykennel_does', needsKey: 'cmdref_k9deploykennel_needs', gate: { kind: 'access', featureKey: 'DeployableKennel' } },
        // k9exitkennel -- trap-hunt fix. UNCONDITIONAL (gate: 'open', no
        // featureKey at all) on purpose, matching k9dropfetchball/
        // k9recallfetchball above: client/keybinds.lua registers this
        // command with NO Config.Features wrapper, and client/kennel.lua's
        // ExitKennelRest() never gates on DeployableKennel, HasK9Access, or
        // certification -- this is a confining-mechanic escape hatch, never
        // gated on the way out.
        { command: 'k9exitkennel', category: 'field_gear', adminOnly: false, usageKey: 'cmdref_k9exitkennel_usage', doesKey: 'cmdref_k9exitkennel_does', needsKey: 'cmdref_k9exitkennel_needs', gate: { kind: 'open' }, defaultKeybind: 'O', keyLabelKey: 'keys_action_exit_kennel' },
        // k9kennel -- docs/history/COMMAND_CONSOLIDATION_SPEC.md #5's merged, ADDITIVE
        // entry point (client/kennel.lua) -- reported as
        // PENDING_NEW_CANONICAL_COMMANDS while html/tablet.js was a hot
        // file; added here now that it is not. Contextual dispatch over
        // deploy/enter/exit/close/open -- gate mirrors k9deploykennel's own
        // (the START half; exit/close/open all stay reachable ungated via
        // this same command exactly as they already are via the two rows
        // above, per this file's own "never gate the stop" convention).
        { command: 'k9kennel', category: 'field_gear', adminOnly: false, usageKey: 'cmdref_k9kennel_usage', doesKey: 'cmdref_k9kennel_does', needsKey: 'cmdref_k9kennel_needs', gate: { kind: 'access', featureKey: 'DeployableKennel' } },
        // gate 'open', deliberately -- see this command's own DEFAULT_STRINGS
        // comment above. Every other row's gate resolves against a real
        // Config.Features key the tablet already knows the live value of;
        // Config.DebugDump.enabled is not one, so claiming a live yes/no
        // here would be a guess. 'open' plus an honest `needs` string is the
        // truthful shape.
        { command: 'k9debug', category: 'field_gear', adminOnly: false, usageKey: 'cmdref_k9debug_usage', doesKey: 'cmdref_k9debug_does', needsKey: 'cmdref_k9debug_needs', gate: { kind: 'open' } },
        { command: 'k9propattach', category: 'field_gear', adminOnly: false, usageKey: 'cmdref_k9propattach_usage', doesKey: 'cmdref_k9propattach_does', needsKey: 'cmdref_k9propattach_needs', gate: { kind: 'access', featureKey: 'PropAttachments' } },
        { command: 'k9throwfetchball', category: 'field_gear', adminOnly: false, usageKey: 'cmdref_k9throwfetchball_usage', doesKey: 'cmdref_k9throwfetchball_does', needsKey: 'cmdref_k9throwfetchball_needs', gate: { kind: 'access', featureKey: 'FetchMechanic' } },
        { command: 'k9dropfetchball', category: 'field_gear', adminOnly: false, usageKey: 'cmdref_k9dropfetchball_usage', doesKey: 'cmdref_k9dropfetchball_does', needsKey: 'cmdref_k9dropfetchball_needs', gate: { kind: 'open' } },
        { command: 'k9recallfetchball', category: 'field_gear', adminOnly: false, usageKey: 'cmdref_k9recallfetchball_usage', doesKey: 'cmdref_k9recallfetchball_does', needsKey: 'cmdref_k9recallfetchball_needs', gate: { kind: 'open' } },
        // k9fetch -- docs/history/COMMAND_CONSOLIDATION_SPEC.md #3's merged entry point
        // (client/fetch.lua) -- reported as PENDING_NEW_CANONICAL_COMMANDS
        // in tests/commandreferenceregistry_spec.lua while html/tablet.js
        // was a hot file; added here now that it is not. Contextual
        // dispatch over the SAME three resource-globals the three old names
        // above already call -- gate mirrors k9throwfetchball's own (the
        // one branch of the three with a real access gate; drop/recall stay
        // ungated release paths the same way k9leash/k9partner's own toggle
        // entries above document).
        { command: 'k9fetch', category: 'field_gear', adminOnly: false, usageKey: 'cmdref_k9fetch_usage', doesKey: 'cmdref_k9fetch_does', needsKey: 'cmdref_k9fetch_needs', gate: { kind: 'access', featureKey: 'FetchMechanic' } },
        { command: 'k9track', category: 'basic_commands', adminOnly: false, usageKey: 'cmdref_k9track_usage', doesKey: 'cmdref_k9track_does', needsKey: 'cmdref_k9track_needs', gate: { kind: 'access', featureKey: 'ScentTracking' } },
        { command: 'k9stats', category: 'records', adminOnly: false, usageKey: 'cmdref_k9stats_usage', doesKey: 'cmdref_k9stats_does', needsKey: 'cmdref_k9stats_needs', gate: { kind: 'access', featureKey: 'K9Leaderboard' } },

        // ---- Certification Management (admin) ----
        { command: 'k9certify', category: 'certification', adminOnly: true, usageKey: 'cmdref_k9certify_usage', doesKey: 'cmdref_k9certify_does', needsKey: 'cmdref_k9certify_needs', gate: { kind: 'capability', capability: 'k9.certify' } },
        { command: 'k9decertify', category: 'certification', adminOnly: true, usageKey: 'cmdref_k9decertify_usage', doesKey: 'cmdref_k9decertify_does', needsKey: 'cmdref_k9decertify_needs', gate: { kind: 'capability', capability: 'k9.certify' } },
        { command: 'k9settier', category: 'certification', adminOnly: true, usageKey: 'cmdref_k9settier_usage', doesKey: 'cmdref_k9settier_does', needsKey: 'cmdref_k9settier_needs', gate: { kind: 'capability', capability: 'k9.certify' } },
        { command: 'k9specialize', category: 'certification', adminOnly: true, usageKey: 'cmdref_k9specialize_usage', doesKey: 'cmdref_k9specialize_does', needsKey: 'cmdref_k9specialize_needs', gate: { kind: 'capability', capability: 'k9.certify' } },
        { command: 'k9unspecialize', category: 'certification', adminOnly: true, usageKey: 'cmdref_k9unspecialize_usage', doesKey: 'cmdref_k9unspecialize_does', needsKey: 'cmdref_k9unspecialize_needs', gate: { kind: 'capability', capability: 'k9.certify' } },
        // k9dog -- docs/history/COMMAND_CONSOLIDATION_SPEC.md #2's merged entry point
        // (server/dogcharacter.lua) -- reported as
        // PENDING_NEW_CANONICAL_COMMANDS while html/tablet.js was a hot
        // file; added here now that it is not. Its two folded-away
        // originals, k9setdog/k9removedog, deliberately have NO entry of
        // their own and never will -- see
        // tests/commandreferenceregistry_spec.lua's own HIDDEN_ALIAS_COMMANDS
        // ('dog_record' family, already flagged COMMANDS_TAB_CLEANUP_COMPLETE)
        // -- do not add rows for those two. Gated on IsHighCommand(source)
        // alone, confirmed by reading server/dogcharacter.lua's
        // RegisterCommand('k9dog', ...) handler directly -- no
        // Config.Features flag exists for this file at all, so no featureKey
        // (unlike k9bonetool/k9permission's highCommandOnly rows, which each
        // carry a real one). 'set'/'remove' stay explicit words (never
        // auto-inferred -- see that file's own header on why this specific
        // family keeps the destructive-action carve-out); the bare
        // '/k9dog <target>' form is read-only.
        { command: 'k9dog', category: 'certification', adminOnly: true, usageKey: 'cmdref_k9dog_usage', doesKey: 'cmdref_k9dog_does', needsKey: 'cmdref_k9dog_needs', gate: { kind: 'highCommandOnly' } },

        // ---- XP Management (admin) ----
        { command: 'k9givexp', category: 'xp', adminOnly: true, usageKey: 'cmdref_k9givexp_usage', doesKey: 'cmdref_k9givexp_does', needsKey: 'cmdref_k9givexp_needs', gate: { kind: 'capability', capability: 'k9.givexp' } },

        // ---- Audit & Oversight (admin) ----
        { command: 'k9audit', category: 'audit', adminOnly: true, usageKey: 'cmdref_k9audit_usage', doesKey: 'cmdref_k9audit_does', needsKey: 'cmdref_k9audit_needs', gate: { kind: 'capability', capability: 'k9.audit', featureKey: 'AdminAuditCommands' } },

        // ---- Developer Tools (admin) ----
        { command: 'k9bonetool', category: 'devtools', adminOnly: true, usageKey: 'cmdref_k9bonetool_usage', doesKey: 'cmdref_k9bonetool_does', needsKey: 'cmdref_k9bonetool_needs', gate: { kind: 'highCommandOnly', featureKey: 'BoneSweepDevTool' } },

        // ---- Permission Management (admin) -- server/permissions.lua's
        // console/chat "CONSOLE/CHAT COMMAND GRANT PATH" section: the same
        // authorization tablet:grantPermission/tablet:revokePermission
        // already require (IsHighCommand ONLY -- no rank/permission-grant
        // bypass, unlike certification's IsEligibleCertifier), reachable
        // without the tablet too.
        { command: 'k9permission', category: 'permissions', adminOnly: true, usageKey: 'cmdref_k9permission_usage', doesKey: 'cmdref_k9permission_does', needsKey: 'cmdref_k9permission_needs', gate: { kind: 'highCommandOnly', featureKey: 'PermissionGrants' } },
    ];
    window.K9TabletCatalog = {
        DEFAULT_STRINGS: DEFAULT_STRINGS,
        DEFAULT_CAPABILITIES: DEFAULT_CAPABILITIES,
        CAPABILITY_ORDER: CAPABILITY_ORDER,
        DEFAULT_THEME: DEFAULT_THEME,
        THEME_DENSITY_OPTIONS: THEME_DENSITY_OPTIONS,
        COMMAND_REFERENCE_CATEGORIES: COMMAND_REFERENCE_CATEGORIES,
        COMMAND_REFERENCE: COMMAND_REFERENCE,
    };
})();
