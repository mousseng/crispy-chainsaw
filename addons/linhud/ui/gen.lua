--[[
* procedural texture generators.
*
* every generator is `fn(spec, scale) -> image, meta`:
*   spec  - the slot table from a theme (sizes in logical pixels)
*   scale - ui scale; sizes are multiplied by this so output stays crisp
*   meta  - { type, slice = {l,t,r,b}, outset, pivot = {x,y} }, in texture pixels
*
* shapes are signed distance functions (negative inside) sampled at pixel
* centres; coverage = clamp(0.5 - d) gives one pixel of anti-aliasing.
* output is white with alpha so it can be tinted per draw.
--]]

local image = require('ui.image');

local abs, ceil, max, min, sqrt, exp = math.abs, math.ceil, math.max, math.min, math.sqrt, math.exp;
local cos, sin, pi = math.cos, math.sin, math.pi;

local gen = {};

--[[ helpers ]]--

local function clamp01(v)
    return v < 0 and 0 or (v > 1 and 1 or v);
end

local function coverage(d)
    return clamp01(0.5 - d);
end

---turns a filled shape distance into an inward stroke of width w.
local function stroke(d, w)
    return abs(d + w * 0.5) - w * 0.5;
end

---abramowitz & stegun 7.1.26; max error ~1.5e-7.
local function erf(x)
    local s = x < 0 and -1 or 1;
    x = abs(x);
    local t = 1 / (1 + 0.3275911 * x);
    local y = 1 - (((((1.061405429 * t - 1.453152027) * t) + 1.421413741) * t - 0.284496736) * t + 0.254829592) * t * exp(-x * x);
    return s * y;
end

---box with rounded corners centred at (cx, cy) with half extents (hw, hh).
local function sd_round_rect(px, py, cx, cy, hw, hh, r)
    local qx = abs(px - cx) - (hw - r);
    local qy = abs(py - cy) - (hh - r);
    local ox, oy = max(qx, 0), max(qy, 0);
    return sqrt(ox * ox + oy * oy) + min(max(qx, qy), 0) - r;
end

---box with 45-degree corner cuts of size c.
local function sd_chamfer_rect(px, py, cx, cy, hw, hh, c)
    local ax, ay = abs(px - cx), abs(py - cy);
    local box = max(ax - hw, ay - hh);
    if (c <= 0) then return box; end
    local cut = (ax + ay - (hw + hh - c)) * 0.70710678;
    return max(box, cut);
end

---exact signed distance to a simple polygon (inigo quilez).
local function sd_polygon(px, py, v)
    local n = #v;
    local dx, dy = px - v[1][1], py - v[1][2];
    local d, s = dx * dx + dy * dy, 1;
    local j = n;
    for i = 1, n do
        local vi, vj = v[i], v[j];
        local ex, ey = vj[1] - vi[1], vj[2] - vi[2];
        local wx, wy = px - vi[1], py - vi[2];
        local t = clamp01((wx * ex + wy * ey) / (ex * ex + ey * ey));
        local bx, by = wx - ex * t, wy - ey * t;
        d = min(d, bx * bx + by * by);
        local c1, c2, c3 = py >= vi[2], py < vj[2], ex * wy > ey * wx;
        if ((c1 and c2 and c3) or (not c1 and not c2 and not c3)) then
            s = -s;
        end
        j = i;
    end
    return s * sqrt(d);
end

---applies spec.fill / spec.stroke to a filled-shape distance.
local function shade(d, fill, sw)
    if (sw > 0 and not fill) then
        return coverage(stroke(d, sw));
    end
    return coverage(d);
end

--[[ nine-slice shapes ]]--

---panels and borders. spec: radius, stroke (0 = filled), fill (default true)
function gen.rounded_rect(spec, scale)
    local r  = (spec.radius or 6) * scale;
    local sw = (spec.stroke or 0) * scale;
    local fill = spec.fill ~= false;

    -- corners need `m` pixels; the 2px middle strip is what stretches.
    local m = ceil(max(r, sw)) + 1;
    local size = m * 2 + 2;
    local c = size * 0.5;

    local img = image.new(size, size):fill(function (x, y)
        return shade(sd_round_rect(x, y, c, c, c, c, r), fill, sw);
    end);
    return img, { type = 'nineslice', slice = { m, m, m, m } };
end

---bars. spec: corner (cut size, 0 = square), stroke, fill
function gen.chamfer_rect(spec, scale)
    local cut = (spec.corner or 3) * scale;
    local sw  = (spec.stroke or 0) * scale;
    local fill = spec.fill ~= false;

    local m = ceil(max(cut, sw)) + 1;
    local size = m * 2 + 2;
    local c = size * 0.5;

    local img = image.new(size, size):fill(function (x, y)
        return shade(sd_chamfer_rect(x, y, c, c, c, c, cut), fill, sw);
    end);
    return img, { type = 'nineslice', slice = { m, m, m, m } };
end

---a trapezoid, long side down: tabs docked to a screen edge (draw it flipped
---for the top edge). spec: height, slant (how far in the short side's ends
---sit), stroke, fill.
---
---only the ends are fixed; the middle stretches to any width. there are no
---fixed rows, so the texture is exactly `height` tall and should be drawn at
---that height (render.slot_size) - stretched, its slants would change angle.
function gen.trapezoid(spec, scale)
    local h  = math.floor((spec.height or 18) * scale + 0.5);
    local sl = (spec.slant or 12) * scale;
    local sw = (spec.stroke or 0) * scale;
    local fill = spec.fill ~= false;

    local m = ceil(sl + sw) + 1;
    local w = m * 2 + 2;
    local verts = { { 0, h }, { sl, 0 }, { w - sl, 0 }, { w, h } };

    local img = image.new(w, h):fill(function (x, y)
        return shade(sd_polygon(x, y, verts), fill, sw);
    end);
    return img, { type = 'nineslice', slice = { m, 0, m, 0 } };
end

---soft shadow around a rounded or chamfered rect. drawn behind the element,
---extended by `outset` on every side.
---spec: radius | corner, blur (falloff distance), knockout (clear the interior
---so translucent panels don't darken through), shape ('round' | 'chamfer')
function gen.shadow(spec, scale)
    local blur  = max(spec.blur or 8, 0.5) * scale;
    local sigma = blur / 3;
    local chamfer = spec.shape == 'chamfer';
    local r = ((chamfer and spec.corner or spec.radius) or 6) * scale;
    local knockout = spec.knockout == true;

    local e = ceil(blur);
    local m = e + ceil(r) + 1;
    local size = m * 2 + 2;
    local c = size * 0.5;
    local h = c - e; -- half extent of the element itself
    local k = 1 / (sigma * 1.41421356);

    local img = image.new(size, size):fill(function (x, y)
        local d = chamfer and sd_chamfer_rect(x, y, c, c, h, h, r) or sd_round_rect(x, y, c, c, h, h, r);
        local a = 0.5 * (1 - erf(d * k));
        if (knockout) then
            a = a * (1 - coverage(d));
        end
        return a;
    end);
    return img, { type = 'outset', slice = { m, m, m, m }, outset = e };
end

---a glow is a knocked-out shadow; tint decides which it looks like.
function gen.glow(spec, scale)
    local s = setmetatable({ knockout = spec.knockout ~= false }, { __index = spec });
    return gen.shadow(s, scale);
end

--[[ sprites ]]--

local function sprite(w, h, verts_fn, spec, scale, pivot)
    local sw = (spec.stroke or 0) * scale;
    local fill = spec.fill ~= false;
    local pad = 1;
    local tw, th = ceil(w) + pad * 2, ceil(h) + pad * 2;
    local ox, oy = (tw - w) * 0.5, (th - h) * 0.5;
    local verts = verts_fn(ox, oy);

    local img = image.new(tw, th):fill(function (x, y)
        return shade(sd_polygon(x, y, verts), fill, sw);
    end);
    return img, { type = 'sprite', pivot = pivot };
end

---target markers. spec: width, height, dir ('down' | 'up' | 'left' | 'right'),
---stroke, notch (0..1: how far the base is cut in towards the tip, making an
---arrowhead), pivot ('tip' | 'center').
---pivot is the tip by default, so the arrow can be placed pointing at a
---coordinate; 'center' suits arrows that get rotated in place.
function gen.arrow(spec, scale)
    local dir = spec.dir or 'down';
    local w = (spec.width or 12) * scale;
    local h = (spec.height or 8) * scale;
    local n = spec.notch or 0;
    if (dir == 'left' or dir == 'right') then
        w, h = h, w;
    end

    local tri = {
        down  = function (x, y) return { { x, y }, { x + w * 0.5, y + h * n }, { x + w, y }, { x + w * 0.5, y + h } }; end,
        up    = function (x, y) return { { x + w * 0.5, y }, { x + w, y + h }, { x + w * 0.5, y + h * (1 - n) }, { x, y + h } }; end,
        right = function (x, y) return { { x, y }, { x + w, y + h * 0.5 }, { x, y + h }, { x + w * n, y + h * 0.5 } }; end,
        left  = function (x, y) return { { x + w, y }, { x + w * (1 - n), y + h * 0.5 }, { x + w, y + h }, { x, y + h * 0.5 } }; end,
    };
    local pivots = { down = { 0.5, 1 }, up = { 0.5, 0 }, right = { 1, 0.5 }, left = { 0, 0.5 } };
    if (tri[dir] == nil) then
        error(('arrow: unknown dir "%s"'):format(tostring(dir)));
    end

    return sprite(w, h, tri[dir], spec, scale, spec.pivot == 'center' and { 0.5, 0.5 } or pivots[dir]);
end

---regular star / diamond (points = 2) / polygon marks.
---spec: radius, points, inner (inner radius ratio; 1 = regular polygon), stroke
function gen.star(spec, scale)
    local r = (spec.radius or 6) * scale;
    local n = spec.points or 5;
    local inner = spec.inner or 0.45;
    local size = r * 2;

    return sprite(size, size, function (ox, oy)
        local cx, cy, v = ox + r, oy + r, {};
        for i = 0, n * 2 - 1 do
            local a = -pi * 0.5 + i * pi / n;
            local rr = (i % 2 == 0) and r or r * inner;
            v[#v + 1] = { cx + cos(a) * rr, cy + sin(a) * rr };
        end
        return v;
    end, spec, scale, { 0.5, 0.5 });
end

---discs and rings. spec: radius, stroke (> 0 with fill = false for a ring)
function gen.circle(spec, scale)
    local r  = (spec.radius or 6) * scale;
    local sw = (spec.stroke or 0) * scale;
    local fill = spec.fill ~= false;
    local size = ceil(r * 2) + 2;
    local c = size * 0.5;

    local img = image.new(size, size):fill(function (x, y)
        local dx, dy = x - c, y - c;
        return shade(sqrt(dx * dx + dy * dy) - r, fill, sw);
    end);
    return img, { type = 'sprite', pivot = { 0.5, 0.5 } };
end

return gen;
