--[[
* small drawing helpers shared by components.
--]]

local theme = require('ui.theme');

local min = math.min;

local widgets = {};

---the bar shape filled to frac with a gradient cycling a -> b -> a once per
---bar width, scrolled right by phase (0..1 of a cycle). drawn as four
---half-cycle spans, enough to cover the bar at any phase.
local function scroll_fill(r, x, y, w, h, frac, a, b, phase)
    local half = w * 0.5;
    local s = x - w + phase * w; -- start of the cycle that covers x
    r.push_clip(x, y, w * min(frac, 1), h);
    for k = 0, 3 do
        local s0 = s + k * half;
        local c0, c1 = a, b;
        if (k % 2 == 1) then c0, c1 = b, a; end
        r.push_clip(s0, y, half, h);
        r.nineslice_hgrad('bar', x, y, w, h, c0, c1, s0, s0 + half);
        r.pop_clip();
    end
    r.pop_clip();
end

---a bar filled to frac (0..1). glow: colour of a glow around the bar, or nil
---for none; callers decide when (full tp, critical hp). over: an optional second
---layer filled to over (0..1) on top of the first (tp past 1000), a gradient
---of over_a and over_b scrolling by phase (see scroll_fill).
function widgets.bar(r, x, y, w, h, frac, color, glow, over, over_a, over_b, phase)
    local c = theme.color;
    r.nineslice('bar_bg', x, y, w, h, c('bar_bg'));
    if (frac > 0) then
        r.push_clip(x, y, w * math.min(frac, 1), h);
        r.nineslice('bar', x, y, w, h, color);
        r.pop_clip();
    end
    if (over ~= nil and over > 0) then
        scroll_fill(r, x, y, w, h, over, over_a, over_b, phase or 0);
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
