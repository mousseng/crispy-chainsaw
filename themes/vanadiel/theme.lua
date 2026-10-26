--[[
* vanadiel theme: closer to the game's own windows. see-through indigo panels
* with a pale lavender frame and square corners. still procedural; anything not
* set here comes from the default theme.
--]]

return {
    palette = {
        panel_bg      = 0xD0231F46, -- sampled from an in-game window over a dark scene, pinstripes averaged in
        popup_bg      = 0xE8231F46,
        panel_border  = 0xD0B0B0D8, -- the frame: grey on top, lavender below; this sits between
        shadow        = 0x6000000C,
        glow          = 0xC0C8C8FF,

        bar_bg        = 0xC00C0A20,
        bar_border    = 0x60A0A0D0,

        hover         = 0x30B0B0FF,
        cell_bg       = 0x24B0B0FF,
        accent        = 0xFFB0C0FF,
        text_dim      = 0xFFB0B0CC,
    },

    slots = {
        panel                = { gen = 'rounded_rect', radius = 0 },
        panel_border         = { gen = 'rounded_rect', radius = 0, stroke = 1, fill = false },
        panel_shadow         = { gen = 'shadow', radius = 0, blur = 6, knockout = true },
        panel_glow           = { gen = 'glow', radius = 0, blur = 6 },
        row_highlight        = { gen = 'rounded_rect', radius = 0, stroke = 1, fill = false },

        bar                  = { gen = 'chamfer_rect', corner = 0 },
        bar_bg               = { gen = 'chamfer_rect', corner = 0 },
        bar_border           = { gen = 'chamfer_rect', corner = 0, stroke = 1, fill = false },
        bar_glow             = { gen = 'glow', shape = 'chamfer', corner = 0, blur = 5 },

        cell                 = { gen = 'rounded_rect', radius = 0 },
    },
};
