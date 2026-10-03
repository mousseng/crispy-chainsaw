--[[
* default theme: fully procedural, no image files.
*
* every other theme inherits from this one, so it must define every slot in
* theme.SLOTS. sizes are logical pixels (multiplied by ui scale). art is white
* and tinted per draw with palette colours.
--]]

return {
    palette = {
        panel_bg      = 0xD8101318,
        popup_bg      = 0xF4101318, -- tooltips and menus, over busier things
        panel_border  = 0x40FFFFFF,
        shadow        = 0x80000000,
        glow          = 0xC0FFD878,

        bar_bg        = 0xB0000000,
        bar_border    = 0x30FFFFFF,
        hp            = 0xFF7FD35F,
        hp_low        = 0xFFE0C050,
        hp_crit       = 0xFFE05A4A,
        mp            = 0xFFE0C35F,
        bar_loss      = 0xFF8A2A2A, -- a bar's trail after a drop; dark, to stand apart from every fill (hp_crit too)
        bar_gain      = 0xFFCCFFB0, -- and after a rise; pale, to stand apart from hp
        tp            = 0xFFFFFFFF, -- white until 1000, so a ready weaponskill (tp_full) stands out
        tp_full       = 0xFF9CD2FF,
        tp_over       = 0xFFF07AC8, -- the second layer, 1000..3000: a scrolling gradient of these two
        tp_over_alt   = 0xFF9A6AF0,
        pet           = 0xFFC08FE0,
        exp           = 0xFFB89AF0,

        target        = 0xFFFFFFFF,
        subtarget     = 0xFF7FC8FF,
        party_target  = 0xFFFFB060,
        row_target_spin = 0xFF9CD2FF, -- the two stretches chasing round the target's outline

        leader        = 0xFFFFD860,
        alliance_lead = 0xFF5FA8FF,
        sync          = 0xFF9AE0A0,

        -- target names, by what the target is / who has claim
        name_party         = 0xFF8FD8FF,
        name_player        = 0xFFF0F0F0,
        name_npc           = 0xFF9AE0A0,
        name_mob           = 0xFFF0E070,
        name_claimed       = 0xFFFF7A6A,
        name_claimed_other = 0xFFD08FE0,
        target_lock        = 0xC0FF6A5A,

        text          = 0xFFF0F0F0,
        text_dim      = 0xFFA0A4AC,
        accent        = 0xFF8FC0FF,
        hover         = 0x30FFFFFF,

        -- inventory item cells
        cell_bg       = 0x18FFFFFF,

        -- treasure pool: an item the player is winning
        loot_win      = 0xFFFFD860,
    },

    -- mapped onto gdifonts settings by ui/text.lua. sizes are logical pixels.
    font = {
        family  = 'Arial',
        size    = 13,
        bold    = true,
        outline = 2,
        outline_color = 0xFF000000,
    },

    -- glyph sets pre-rendered into the atlas for fast-changing values (hp, tp,
    -- timers). each merges over `font`; `chars` limits what can be drawn.
    glyphs = {
        number = { size = 12, chars = '0123456789,.%/-+: ' },
        -- job/level labels (e.g. WHM75/SCH37): only the letters job
        -- abbreviations use.
        job    = { size = 10, chars = 'ABCDEFGHIKLMNOPRSTUW0123456789/' },
        -- exp bar: "12,345 / 21,000" and "8,400/hr".
        exp    = { size = 12, chars = '0123456789,./hr ' },
        -- inventory: stack counts on icons, and gil / space used.
        count  = { size = 10, chars = '0123456789' },
        inv    = { size = 12, chars = '0123456789,/ gil' },
    },

    slots = {
        panel                = { gen = 'rounded_rect', radius = 6 },
        panel_border         = { gen = 'rounded_rect', radius = 6, stroke = 1, fill = false },
        panel_shadow         = { gen = 'shadow', radius = 6, blur = 10, knockout = true },
        panel_glow           = { gen = 'glow', radius = 6, blur = 6 },
        row_highlight        = { gen = 'rounded_rect', radius = 5, stroke = 1, fill = false },

        bar                  = { gen = 'chamfer_rect', corner = 3 },
        bar_bg               = { gen = 'chamfer_rect', corner = 3 },
        bar_border           = { gen = 'chamfer_rect', corner = 3, stroke = 1, fill = false },
        bar_glow             = { gen = 'glow', shape = 'chamfer', corner = 3, blur = 5 },

        -- edge-docked tabs (the exp bar). long side down; drawn flipped at the top.
        tab                  = { gen = 'trapezoid', height = 18, slant = 14 },
        tab_border           = { gen = 'trapezoid', height = 18, slant = 14, stroke = 1, fill = false },

        arrow_target         = { gen = 'arrow', width = 14, height = 9, dir = 'down' },
        arrow_subtarget      = { gen = 'arrow', width = 10, height = 7, dir = 'down' },
        arrow_party          = { gen = 'arrow', width = 8, height = 10, dir = 'right' },

        mark_leader          = { gen = 'star', radius = 6, points = 5, inner = 0.45 },
        mark_alliance_leader = { gen = 'star', radius = 6, points = 5, inner = 0.45 },
        mark_sync            = { gen = 'circle', radius = 5, stroke = 1.5, fill = false },
        dot                  = { gen = 'circle', radius = 1.5 },

        -- inventory item cells
        cell                 = { gen = 'rounded_rect', radius = 3 },
    },
};
