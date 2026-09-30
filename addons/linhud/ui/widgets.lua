--[[
* small drawing helpers shared by components.
--]]

local theme = require('ui.theme');

local widgets = {};

---a bar filled to frac (0..1). glow: colour of a glow around the bar, or nil
---for none; callers decide when (full tp, critical hp).
function widgets.bar(r, x, y, w, h, frac, color, glow)
    local c = theme.color;
    r.nineslice('bar_bg', x, y, w, h, c('bar_bg'));
    if (frac > 0) then
        r.push_clip(x, y, w * math.min(frac, 1), h);
        r.nineslice('bar', x, y, w, h, color);
        r.pop_clip();
    end
    if (glow ~= nil) then
        r.nineslice('bar_glow', x, y, w, h, glow);
    end
    r.nineslice('bar_border', x, y, w, h, c('bar_border'));
end

---@param frac number hp fraction, 0..1
function widgets.hp_color(frac)
    if (frac < 0.25) then return theme.color('hp_crit'); end
    if (frac < 0.5) then return theme.color('hp_low'); end
    return theme.color('hp');
end

return widgets;
