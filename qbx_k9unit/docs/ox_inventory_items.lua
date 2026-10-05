--[[
    K9 ITEMS FOR OX_INVENTORY -- copy and paste, then restart.

    This file is NOT loaded by qbx_k9unit. It is a ready-made list of the
    items this resource expects your inventory to have. Until they exist,
    the K9 Supply shop has nothing to sell and the K9 Medkit never works
    (the server console says so at every start).

    HOW TO ADD THEM
      1. Open  resources/[ox]/ox_inventory/data/items.lua
         (the folder name may differ on your server; the file is
         ox_inventory/data/items.lua).
      2. That file is one big list that starts with  return {  and ends
         with a single  }  on the last line.
      3. Copy everything between the two "COPY FROM HERE" / "COPY TO HERE"
         lines below and paste it just ABOVE that last  }.
      4. Save, then restart the server (or at least ox_inventory, then
         qbx_k9unit).
      5. Optional: put a picture for each item in
         ox_inventory/web/images/ named after the item, e.g.
         k9_medkit.png. Without one the item shows a blank square but
         still works.

    Already have one of these items (for example a tablet item with the
    same name)? Skip that entry -- two entries with the same name break
    ox_inventory's item list. Changed an item name in config.lua? Use your
    name here instead.

    WHAT EACH ONE IS FOR
      k9_medkit              Handler heals an injured K9 partner (K9 menu >
                             "Treat This K9's Injuries"). Used up on each use.
      k9_treat               Reward treat, sold in the K9 Supply shop.
      k9_meat_bait           Bait, sold in the K9 Supply shop.
      k9_ultrasonic_whistle  Training whistle, sold in the K9 Supply shop.
      k9_tablet              Opens the K9 Command Tablet when used. Only
                             needed if Config.CommandTablet.openMode is
                             'item' or 'both' (the default is 'both').
                             Reusable: consume = 0 means it is never
                             used up.
]]

return {
    -- ===================== COPY FROM HERE =====================
    ['k9_medkit'] = {
        label = 'K9 Medkit',
        weight = 500,
        stack = true,
        close = true,
        description = 'Field medical kit for a police dog.',
    },

    ['k9_treat'] = {
        label = 'K9 Treat',
        weight = 50,
        stack = true,
        close = true,
        description = 'A reward treat for a working dog.',
    },

    ['k9_meat_bait'] = {
        label = 'Meat Bait',
        weight = 200,
        stack = true,
        close = true,
        description = 'Strong-smelling bait used in K9 training.',
    },

    ['k9_ultrasonic_whistle'] = {
        label = 'Ultrasonic Whistle',
        weight = 100,
        stack = false,
        close = true,
        description = 'A training whistle only dogs can hear.',
    },

    ['k9_tablet'] = {
        label = 'K9 Command Tablet',
        weight = 750,
        stack = false,
        close = true,
        consume = 0,
        description = 'K9 unit records, roles and settings.',
        client = {
            event = 'qbx_k9unit:client:useTabletItem',
        },
    },
    -- ====================== COPY TO HERE ======================
}
