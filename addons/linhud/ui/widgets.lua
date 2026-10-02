--[[
* small drawing helpers shared by components.
--]]

local bit   = require('bit');
local theme = require('ui.theme');

local band, bor, lshift, rshift = bit.band, bit.bor, bit.lshift, bit.rshift;
local floor = math.floor;

local widgets = {};

---a bar filled to frac (0..1). glow: colour of a glow around the bar, or nil
---for none; callers decide when (full tp, critical hp). over / over_color: an
---optional second layer filled to over (0..1) on top of the first (tp past
---1000).
function widgets.bar(r, x, y, w, h, frac, color, glow, over, over_color)
    local c = theme.color;
    r.nineslice('bar_bg', x, y, w, h, c('bar_bg'));
    if (frac > 0) then
        r.push_clip(x, y, w * math.min(frac, 1), h);
        r.nineslice('bar', x, y, w, h, color);
        r.pop_clip();
    end
    if (over ~= nil and over > 0) then
        r.push_clip(x, y, w * math.min(over, 1), h);
        r.nineslice('bar', x, y, w, h, over_color);
        r.pop_clip();
    end
    if (glow ~= nil) then
        r.nineslice('bar_glow', x, y, w, h, glow);
    end
    r.nineslice('bar_border', x, y, w, h, c('bar_border'));
end

local function lerp_channel(a, b, s, t)
    local ca, cb = band(rshift(a, s), 0xFF), band(rshift(b, s), 0xFF);
    return lshift(floor(ca + (cb - ca) * t + 0.5), s);
end

---blends two argb colours, t 0..1.
function widgets.lerp_color(a, b, t)
    return bor(lerp_channel(a, b, 0, t), lerp_channel(a, b, 8, t), lerp_channel(a, b, 16, t), lerp_channel(a, b, 24, t));
end

---@param frac number hp fraction, 0..1
function widgets.hp_color(frac)
    if (frac < 0.25) then return theme.color('hp_crit'); end
    if (frac < 0.5) then return theme.color('hp_low'); end
    return theme.color('hp');
end

return widgets;
