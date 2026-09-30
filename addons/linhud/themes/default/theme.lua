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
        panel_border  = 0x40FFFFFF,
        shadow        = 0x80000000,
        glow          = 0xC0FFD878,

        bar_bg        = 0xB0000000,
        bar_border    = 0x30FFFFFF,
        hp            = 0xFF7FD35F,
        hp_low        = 0xFFE0C050,
        hp_crit       = 0xFFE05A4A,
        mp            = 0xFF5FA2E0,
        tp            = 0xFFE0C35F,
        tp_full       = 0xFFFFE89A,
        pet           = 0xFFC08FE0,

        target        = 0xFFFFFFFF,
        subtarget     = 0xFF7FC8FF,
        party_target  = 0xFFFFB060,

        leader        = 0xFFFFD860,
        alliance_lead = 0xFFB0E0FF,
        sync          = 0xFF9AE0A0,

        text          = 0xFFF0F0F0,
        text_dim      = 0xFFA0A4AC,
    },

    -- passed through to gdifonts.
    font = {
        family  = 'Arial',
        size    = 12,
        weight  = 600,
        outline = 2,
        outline_color = 0xFF000000,
    },

    slots = {
        panel                = { gen = 'rounded_rect', radius = 6 },
        panel_border         = { gen = 'rounded_rect', radius = 6, stroke = 1, fill = false },
        panel_shadow         = { gen = 'shadow', radius = 6, blur = 10, knockout = true },
        panel_glow           = { gen = 'glow', radius = 6, blur = 6 },

        bar                  = { gen = 'chamfer_rect', corner = 3 },
        bar_bg               = { gen = 'chamfer_rect', corner = 3 },
        bar_border           = { gen = 'chamfer_rect', corner = 3, stroke = 1, fill = false },
        bar_glow             = { gen = 'glow', shape = 'chamfer', corner = 3, blur = 5 },

        arrow_target         = { gen = 'arrow', width = 14, height = 9, dir = 'down' },
        arrow_subtarget      = { gen = 'arrow', width = 10, height = 7, dir = 'down' },
        arrow_party          = { gen = 'arrow', width = 8, height = 10, dir = 'right' },

        mark_leader          = { gen = 'star', radius = 6, points = 5, inner = 0.45 },
        mark_alliance_leader = { gen = 'star', radius = 6, points = 2, inner = 0.55 },
        mark_sync            = { gen = 'circle', radius = 5, stroke = 1.5, fill = false },
    },
};
