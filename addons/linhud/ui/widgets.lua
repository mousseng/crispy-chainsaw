--[[
* small drawing helpers shared by components.
--]]

local theme = require('ui.theme');

local min, max, abs = math.min, math.max, math.abs;

local widgets = {};

--[[ trails ]]--

-- a bar's trail is the value it shows lagging the real one: on a drop the
-- lost stretch shows in bar_loss, on a rise the gained one in bar_gain, then
-- after TRAIL_HOLD the trail eases to the real value (TRAIL_RATE: fraction of
-- the gap closed per second, exponentially). values are 0..1 fractions.
local TRAIL_HOLD, TRAIL_RATE, TRAIL_SNAP = 0.4, 6, 0.002;

function widgets.trail_new()
    return { shown = 0, last = 0, hold = 0 };
end

---jumps straight to v: a new member in the slot, or back in zone.
function widgets.trail_reset(t, v)
    t.shown, t.last, t.hold = v, v, 0;
end

---advances a trail towards v. gains: whether rises animate too (false: they
---show at once, and only drops trail). each change restarts the hold, so a
---burst of hits builds one stretch rather than several.
function widgets.trail_step(t, v, dt, gains)
    if (v ~= t.last) then
        t.last, t.hold = v, TRAIL_HOLD;
    end
    if (not gains and v > t.shown) then
        t.shown = v;
    end
    if (t.hold > 0) then
        t.hold = t.hold - dt;
        return;
    end
    t.shown = t.shown + (v - t.shown) * min(1, dt * TRAIL_RATE);
    if (abs(v - t.shown) < TRAIL_SNAP) then
        t.shown = v;
    end
end

--[[ bars ]]--

---the bar shape filled to frac in one colour.
local function clip_fill(r, x, y, w, h, frac, color)
    if (frac <= 0) then return; end
    r.push_clip(x, y, w * min(frac, 1), h);
    r.nineslice('bar', x, y, w, h, color);
    r.pop_clip();
end

---the stretch between a fill's real value and its trail: draws it, and
---returns how far the fill itself goes (the lower of the two).
local function trail_fill(r, x, y, w, h, frac, shown)
    if (shown == nil or shown == frac) then return frac; end
    clip_fill(r, x, y, w, h, max(frac, shown), theme.color(shown > frac and 'bar_loss' or 'bar_gain'));
    return min(frac, shown);
end

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
---for none; callers decide when (full tp, critical hp). shown: the fill's
---trail (see trail_step), or nil for none. over: an optional second layer
---filled to over (0..1) on top of the first (tp past 1000), a gradient of
---over_a and over_b scrolling by phase (see scroll_fill), with its own trail
---over_shown.
function widgets.bar(r, x, y, w, h, frac, color, glow, shown, over, over_a, over_b, phase, over_shown)
    local c = theme.color;
    r.nineslice('bar_bg', x, y, w, h, c('bar_bg'));
    clip_fill(r, x, y, w, h, trail_fill(r, x, y, w, h, frac, shown), color);
    if (over ~= nil) then
        local lo = trail_fill(r, x, y, w, h, over, over_shown);
        if (lo > 0) then
            scroll_fill(r, x, y, w, h, lo, over_a, over_b, phase or 0);
        end
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
