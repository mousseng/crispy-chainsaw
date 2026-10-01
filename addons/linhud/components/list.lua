--[[
* every component, in paint order (later entries draw on top), with its
* settings defaults.
*
* defaults live here rather than in the component so settings can be built
* without loading any component: a component's module is only required once
* it is enabled (see ui/hud.lua). enabled, anchor, x, y, grow_x and grow_y
* are managed by the hud; anything else is the component's own.
--]]

return {
    { name = 'exp',    defaults = { enabled = true, anchor = 'top', x = 0, y = 0, width = 640 } },
    { name = 'party',  defaults = { enabled = true, anchor = 'left', x = 20, y = -120, grow_y = 'down', hide_solo = false, status_lines = 2 } },
    { name = 'target', defaults = { enabled = true, anchor = 'top', x = 0, y = 80, grow_y = 'down' } },
    { name = 'inv',    defaults = { enabled = false, anchor = 'right', x = -20, y = 0, columns = 10, rows = 8, unified = true } },
    { name = 'demo',   defaults = { enabled = false, anchor = 'topleft', x = 200, y = 200 } },
};
