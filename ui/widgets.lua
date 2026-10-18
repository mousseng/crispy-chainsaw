--[[
* small drawing helpers shared by components.
--]]

local bit   = require('bit');
local theme = require('ui.theme');

local min, max, abs, floor = math.min, math.max, math.abs, math.floor;
local band, bor, lshift, rshift = bit.band, bit.bor, bit.lshift, bit.rshift;

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
---show at once, and only drops trail). hold: seconds to wait before easing,
---default TRAIL_HOLD. each change restarts the hold, so a burst of hits
---builds one stretch rather than several.
function widgets.trail_step(t, v, dt, gains, hold)
    if (v ~= t.last) then
        t.last, t.hold = v, hold or TRAIL_HOLD;
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


--[[ spinners ]]--

-- the spinner being drawn, for tail_edge. upvalues rather than arguments, so
-- few values are live at its exits (32-bit moonjit can't coalesce many).
local sp_r, sp_name, sp_color = nil, nil, 0;
local sp_x, sp_y, sp_w, sp_h = 0, 0, 0, 0;
local sp_t0, sp_t1 = 0, 0;

---color with its alpha scaled by k (0..1).
local function faded(color, k)
    local a = floor(band(rshift(color, 24), 0xFF) * k + 0.5);
    return bor(band(color, 0x00FFFFFF), lshift(a, 24));
end

---the part of the spinner's tail (outline distance sp_t0, faded out, to sp_t1,
---the head) on one edge. the edge runs from e0 to e1, where it is at screen
---coordinate p0 and moves dir (1 or -1) per unit; q0..q1 is its band on the
---other axis, which the drawing is clipped to. horiz: 1 for the top and
---bottom edges, 0 for the sides. branch free: a tail that misses the edge is
---drawn clipped to nothing, so the trace doesn't fork on where it is.
local function tail_edge(e0, e1, p0, dir, q0, q1, horiz)
    local d0 = max(sp_t0, e0);
    local d1 = max(min(sp_t1, e1), d0);
    local pa, pb = p0 + (d0 - e0) * dir, p0 + (d1 - e0) * dir;
    local a, b = min(pa, pb), max(pa, pb);
    -- outline distance at each end, from the screen coordinate
    local inv = 1 / max(sp_t1 - sp_t0, 1e-6);
    local ca = faded(sp_color, min(1, max(0, ((a - p0) * dir + e0 - sp_t0) * inv)));
    local cb = faded(sp_color, min(1, max(0, ((b - p0) * dir + e0 - sp_t0) * inv)));
    local v = 1 - horiz;
    sp_r.push_clip(a * horiz + q0 * v, q0 * horiz + a * v, (b - a) * horiz + (q1 - q0) * v, (q1 - q0) * horiz + (b - a) * v);
    if (horiz == 1) then
        sp_r.nineslice_hgrad(sp_name, sp_x, sp_y, sp_w, sp_h, ca, cb, a, b);
    else
        sp_r.nineslice_vgrad(sp_name, sp_x, sp_y, sp_w, sp_h, ca, cb, a, b);
    end
    sp_r.pop_clip();
end

---a stretch of a nineslice slot chasing round its outline, fading out behind
---its head. pos (0..1): how far round the head is, clockwise from the top
---left; len (0..0.5): the tail's share of the outline. the corners go with
---the top and bottom edges, so the sides are only their straight parts.
function widgets.spinner(r, name, x, y, w, h, color, pos, len)
    local el, et, er, eb = r.slot_edges(name);
    -- the nineslice snaps its edges to whole pixels; match it
    local x1, y1 = floor(x + w + 0.5), floor(y + h + 0.5);
    x, y = floor(x + 0.5), floor(y + 0.5);
    w, h = x1 - x, y1 - y;
    local side = max(h - et - eb, 0);
    local per = 2 * w + 2 * side;
    sp_r, sp_name, sp_color = r, name, color;
    sp_x, sp_y, sp_w, sp_h = x, y, w, h;
    sp_t1 = pos % 1 * per;
    sp_t0 = sp_t1 - min(len, 0.5) * per;
    tail_edge(0, w, x, 1, y, y + et, 1);                                       -- top
    tail_edge(w, w + side, y + et, 1, x1 - er, x1, 0);                         -- right
    tail_edge(w + side, 2 * w + side, x1, -1, y1 - eb, y1, 1);                 -- bottom
    tail_edge(2 * w + side, per, y1 - eb, -1, x, x + el, 0);                   -- left
    -- a tail behind the start wraps onto the end: at most half the outline
    -- back, so the bottom and left edges again, a lap earlier
    tail_edge(w + side - per, 2 * w + side - per, x1, -1, y1 - eb, y1, 1);
    tail_edge(2 * w + side - per, 0, y1 - eb, -1, x, x + el, 0);
end

-- the stretch of outline_gradient being drawn: its colours, sp_c0 at outline
-- distance sp_t0 to sp_c1 at sp_t1 (the rest as for the spinner)
local sp_c0, sp_c1 = 0, 0;

---the part of the stretch on one edge (arguments as for tail_edge). the
---gradient's ends are put where the stretch's ends would be along the edge's
---line, even off the edge, so a stretch round a corner stays one gradient.
local function grad_edge(e0, e1, p0, dir, q0, q1, horiz)
    local d0, d1 = max(sp_t0, e0), min(sp_t1, e1);
    if (d1 <= d0) then return; end
    local pa, pb = p0 + (d0 - e0) * dir, p0 + (d1 - e0) * dir;
    local g0, g1 = p0 + (sp_t0 - e0) * dir, p0 + (sp_t1 - e0) * dir;
    local c0, c1 = sp_c0, sp_c1;
    if (dir < 0) then
        pa, pb, g0, g1, c0, c1 = pb, pa, g1, g0, c1, c0;
    end
    local v = 1 - horiz;
    sp_r.push_clip(pa * horiz + q0 * v, q0 * horiz + pa * v, (pb - pa) * horiz + (q1 - q0) * v, (q1 - q0) * horiz + (pb - pa) * v);
    if (horiz == 1) then
        sp_r.nineslice_hgrad(sp_name, sp_x, sp_y, sp_w, sp_h, c0, c1, g0, g1);
    else
        sp_r.nineslice_vgrad(sp_name, sp_x, sp_y, sp_w, sp_h, c0, c1, g0, g1);
    end
    sp_r.pop_clip();
end

---a nineslice slot in a gradient running round its outline through colors[1]
---to colors[n] and back to colors[1], spaced evenly, clockwise from the top
---left, turned clockwise by pos (0..1 of a lap). edges split as for the
---spinner. outset slots (glows) work too: the outline is the drawn one, past
---the rect.
function widgets.outline_gradient(r, name, x, y, w, h, colors, n, pos)
    if (n <= 1) then
        r.nineslice(name, x, y, w, h, colors[1]);
        return;
    end
    local el, et, er, eb = r.slot_edges(name);
    local x1, y1 = floor(x + w + 0.5), floor(y + h + 0.5);
    x, y = floor(x + 0.5), floor(y + 0.5);
    sp_r, sp_name = r, name;
    sp_x, sp_y, sp_w, sp_h = x, y, x1 - x, y1 - y;
    local o = r.slot_outset(name);
    x, y, x1, y1 = x - o, y - o, x1 + o, y1 + o;
    w, h = x1 - x, y1 - y;
    local side = max(h - et - eb, 0);
    local per = 2 * w + 2 * side;
    local turn = (pos or 0) % 1;
    for k = 1, n do
        sp_c0, sp_c1 = colors[k], colors[k % n + 1];
        -- turned, a stretch can run past the end of the outline: draw it a
        -- lap earlier too, for the part that wraps onto the start
        for lap = 0, 1 do
            sp_t0, sp_t1 = ((k - 1) / n + turn - lap) * per, (k / n + turn - lap) * per;
            grad_edge(0, w, x, 1, y, y + et, 1);                       -- top
            grad_edge(w, w + side, y + et, 1, x1 - er, x1, 0);         -- right
            grad_edge(w + side, 2 * w + side, x1, -1, y1 - eb, y1, 1); -- bottom
            grad_edge(2 * w + side, per, y1 - eb, -1, x, x + el, 0);   -- left
        end
    end
end

---@param frac number hp fraction, 0..1
function widgets.hp_color(frac)
    if (frac < 0.25) then return theme.color('hp_crit'); end
    if (frac < 0.5) then return theme.color('hp_low'); end
    return theme.color('hp');
end

--[[ text ]]--

-- element -> its palette key
widgets.ELEMENT = {
    Fire = 'el_fire', Ice = 'el_ice', Wind = 'el_wind', Earth = 'el_earth',
    Thunder = 'el_thunder', Water = 'el_water', Light = 'el_light', Dark = 'el_dark',
};

---draws a text object split left to right into n equal bands, band i in
---colors[i] (e.g. a resonance in the colours of its elements).
---@return number w, number h
function widgets.split_text(r, label, x, y, colors, n)
    local w, h = label:size();
    if (n <= 1) then
        label:draw(x, y, colors[1]);
        return w, h;
    end
    -- only the joins between bands clip: the outer edges reach well past the
    -- text, so overhangs past its advance (an italic's last letter) survive.
    local band_w = w / n;
    for i = 1, n do
        local x0 = i == 1 and x - h or x + band_w * (i - 1);
        local x1 = i == n and x + w + h or x + band_w * i;
        r.push_clip(x0, y - h, x1 - x0, h * 3);
        label:draw(x, y, colors[i]);
        r.pop_clip();
    end
    return w, h;
end

return widgets;
