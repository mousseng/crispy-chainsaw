--[[
* batched quad renderer.
*
* components call the draw functions between begin_frame and end_frame. every
* draw becomes textured, coloured quads in one vertex array; consecutive quads
* that share a texture become a single draw call. theme art all lives in one
* atlas, so a whole hud is usually a handful of calls (one per run of text
* between runs of atlas art).
*
* coordinates are screen pixels. paint order is submission order.
*
* d3d state is set once per frame and restored afterwards, so we never leak
* state into the game or other addons.
--]]

local ffi   = require('ffi');
local bit   = require('bit');
local theme = require('ui.theme');

local band, bor, lshift, rshift = bit.band, bit.bor, bit.lshift, bit.rshift;
local floor, max, min = math.floor, math.max, math.min;

pcall(ffi.cdef, [[
    typedef struct {
        float    x, y, z, rhw;
        uint32_t color;
        float    u, v;
    } linhud_vertex_t;
]]);

local render = {};

local VERTEX_SIZE  = ffi.sizeof('linhud_vertex_t');
local MAX_PER_CALL = 16384; -- quads addressable with 16-bit indices

-- vertex storage grows as needed and is reused across frames.
local capacity = 1024;
local verts    = ffi.new('linhud_vertex_t[?]', capacity * 4);
local nquads   = 0;

-- index pattern is identical for every quad, so it is built once.
local indices = ffi.new('uint16_t[?]', MAX_PER_CALL * 6);
for q = 0, MAX_PER_CALL - 1 do
    local i, v = q * 6, q * 4;
    indices[i], indices[i + 1], indices[i + 2] = v, v + 1, v + 2;
    indices[i + 3], indices[i + 4], indices[i + 5] = v + 2, v + 1, v + 3;
end

-- draw commands as parallel arrays to avoid per-frame table garbage: a run of
-- quads on one texture, from cmd_first[i] up to the next run's first quad.
-- every draw starts one (see use()); finish_cmds then merges neighbours that
-- share a texture and fills in the counts, so drawing never compares textures.
local cmd_tex, cmd_first, cmd_count = {}, {}, {};
local ncmds = 0;

-- the clip rect as components set it, and the rects pushed over it (four
-- numbers per level). always set: the whole plane when nothing clips.
local NO_CLIP = 1e9;
local clip_x0, clip_y0, clip_x1, clip_y1 = -NO_CLIP, -NO_CLIP, NO_CLIP, NO_CLIP;
local clip_stack, clip_depth = {}, 0;
local base, opacity = 1, 1; -- base: set by the hud per component; opacity: base * set_opacity()

local last_stats = { quads = 0, calls = 0 };

--[[
* drawing is in two steps, for luajit's trace compiler; in particular ashita's,
* moonjit on 32-bit x86, which has 8 float registers and numbers every value
* it spills in a trace, up to 255 slots.
*
* 1. record: each draw writes its parameters into a flat array of doubles, as
*    it computes them: a nineslice is one record of its grid, a glyph one
*    record of its rect. clip and texture changes are records too. this is
*    all components' traces ever contain of the renderer, so drawing a few
*    dozen shapes in one loop iteration (a party row, a bar) stays small
*    enough to compile. (when quads were built at the call, a few nineslices
*    in one trace ran out of spill slots, and the caller ran interpreted.)
*
* 2. expand (end of frame): one loop turns records into vertices. a loop body
*    is compiled once, so it spills only once however many quads go through
*    it, and it has few live values, so its side traces (one per record kind)
*    compile too.
*
* expansion avoids branches that vary from quad to quad: clipping is min/max,
* a quad clipped away is written with zero area rather than skipped, and the
* per-vertex constants (z, rhw) are written once when the array is allocated.
* `/linhud jit` lists whatever still fails to compile.
--]]

--[[ records ]]--

local K_QUAD, K_NINE, K_VGRAD, K_CLIP, K_TEX, K_HNINE = 1, 2, 3, 4, 5, 6;
local Q_LEN, NINE_LEN, VGRAD_LEN, CLIP_LEN, TEX_LEN = 10, 18, 9, 5, 2; -- doubles per record
local HNINE_LEN = NINE_LEN + 3; -- a nineslice record, then the gradient's left x, right x and right colour

local rcap = 16384;
local rec = ffi.new('double[?]', rcap);
local nrec = 0;
local expanded = false;

local function grow_rec(need)
    local ncap = rcap * 2;
    while (ncap < need) do ncap = ncap * 2; end
    local nr = ffi.new('double[?]', ncap);
    ffi.copy(nr, rec, nrec * 8);
    rec, rcap = nr, ncap;
end

---starts a run of quads on tex, with room for n more record doubles. call
---once per draw, before its records.
local function use(tex, n)
    if (nrec + TEX_LEN + n > rcap) then grow_rec(nrec + TEX_LEN + n); end
    ncmds = ncmds + 1;
    cmd_tex[ncmds] = tex;
    rec[nrec], rec[nrec + 1] = K_TEX, ncmds;
    nrec = nrec + TEX_LEN;
end

---records a quad in a single colour (already faded). use() must have made
---room for it.
local function rec_quad(x0, y0, x1, y1, u0, v0, u1, v1, c)
    local i = nrec;
    rec[i], rec[i + 1], rec[i + 2], rec[i + 3], rec[i + 4] = K_QUAD, x0, y0, x1, y1;
    rec[i + 5], rec[i + 6], rec[i + 7], rec[i + 8], rec[i + 9] = u0, v0, u1, v1, c;
    nrec = i + Q_LEN;
end

local function rec_clip()
    if (nrec + CLIP_LEN > rcap) then grow_rec(nrec + CLIP_LEN); end
    local i = nrec;
    rec[i], rec[i + 1], rec[i + 2], rec[i + 3], rec[i + 4] = K_CLIP, clip_x0, clip_y0, clip_x1, clip_y1;
    nrec = i + CLIP_LEN;
end

--[[ expansion ]]--

local function prefill(from, to)
    for i = from, to - 1 do
        verts[i].z, verts[i].rhw = 0, 1;
    end
end
prefill(0, capacity * 4);

local function grow(need)
    local ncap = capacity * 2;
    while (ncap < need) do ncap = ncap * 2; end
    local nv = ffi.new('linhud_vertex_t[?]', ncap * 4);
    ffi.copy(nv, verts, nquads * 4 * VERTEX_SIZE);
    verts = nv;
    prefill(nquads * 4, ncap * 4);
    capacity = ncap;
end

-- the clip rect while expanding (as recorded).
local ex_x0, ex_y0, ex_x1, ex_y1 = -NO_CLIP, -NO_CLIP, NO_CLIP, NO_CLIP;

---writes one quad, clipped: the rect and its uvs shrink to the part inside the
---clip rect, down to zero area. the caller makes room.
local function quad(x0, y0, x1, y1, u0, v0, u1, v1, c)
    local qx0, qy0 = max(x0, ex_x0), max(y0, ex_y0);
    local qx1, qy1 = max(min(x1, ex_x1), qx0), max(min(y1, ex_y1), qy0);
    -- uv per pixel; the max keeps a zero-size quad from dividing by zero
    local su, sv = (u1 - u0) / max(x1 - x0, 1e-6), (v1 - v0) / max(y1 - y0, 1e-6);
    u1, v1 = u0 + (qx1 - x0) * su, v0 + (qy1 - y0) * sv;
    u0, v0 = u0 + (qx0 - x0) * su, v0 + (qy0 - y0) * sv;
    qx0, qy0, qx1, qy1 = qx0 - 0.5, qy0 - 0.5, qx1 - 0.5, qy1 - 0.5; -- d3d8 texel/pixel centre alignment

    local v = verts + nquads * 4;
    v[0].x, v[0].y, v[0].u, v[0].v, v[0].color = qx0, qy0, u0, v0, c;
    v[1].x, v[1].y, v[1].u, v[1].v, v[1].color = qx1, qy0, u1, v0, c;
    v[2].x, v[2].y, v[2].u, v[2].v, v[2].color = qx0, qy1, u0, v1, c;
    v[3].x, v[3].y, v[3].u, v[3].v, v[3].color = qx1, qy1, u1, v1, c;
    nquads = nquads + 1;
end

local function lerp_channel(a, b, s, t)
    local ca, cb = band(rshift(a, s), 0xFF), band(rshift(b, s), 0xFF);
    return lshift(floor(ca + (cb - ca) * t + 0.5), s);
end

---interpolates two argb colours per channel (unrolled: the compiler would
---unroll a loop here anyway, or give up on it).
local function lerp_color(a, b, t)
    return bor(lerp_channel(a, b, 0, t), lerp_channel(a, b, 8, t), lerp_channel(a, b, 16, t), lerp_channel(a, b, 24, t));
end

---a quad with a vertical gradient (colours already faded), the colours
---interpolated to wherever the clip cuts it.
local function quad_vgrad(x0, y0, x1, y1, u, v, top, bottom)
    local h = max(y1 - y0, 1e-6);
    local t0 = (max(y0, ex_y0) - y0) / h;
    local t1 = (max(min(y1, ex_y1), max(y0, ex_y0)) - y0) / h;
    local ct, cb = lerp_color(top, bottom, t0) % 4294967296, lerp_color(top, bottom, t1) % 4294967296;
    local n = nquads;
    quad(x0, y0, x1, y1, u, v, u, v, ct);
    local q = verts + n * 4;
    q[2].color, q[3].color = cb, cb;
end

---recolours quads from..nquads-1 by x: cl at gl, cr at gr, interpolated
---between and held beyond. vertex x is already clipped, so the colours match
---wherever the clip cut. a loop on its own, so it compiles once.
local function hgrad_quads(from, gl, gr, cl, cr)
    local inv = 1 / max(gr - gl, 1e-6);
    for j = from * 4, nquads * 4 - 1 do
        local v = verts[j];
        local t = max(0, min(1, (v.x + 0.5 - gl) * inv));
        v.color = lerp_color(cl, cr, t) % 4294967296;
    end
end

---the nine quads of a nineslice record at i: its grid lines (x, y), their uvs
---and colour.
local function quad_nine(r, i)
    local x0, x1, x2, x3 = r[i + 1], r[i + 2], r[i + 3], r[i + 4];
    local y0, y1, y2, y3 = r[i + 5], r[i + 6], r[i + 7], r[i + 8];
    local u0, u1, u2, u3 = r[i + 9], r[i + 10], r[i + 11], r[i + 12];
    local v0, v1, v2, v3 = r[i + 13], r[i + 14], r[i + 15], r[i + 16];
    local c = r[i + 17];
    quad(x0, y0, x1, y1, u0, v0, u1, v1, c);
    quad(x1, y0, x2, y1, u1, v0, u2, v1, c);
    quad(x2, y0, x3, y1, u2, v0, u3, v1, c);
    quad(x0, y1, x1, y2, u0, v1, u1, v2, c);
    quad(x1, y1, x2, y2, u1, v1, u2, v2, c);
    quad(x2, y1, x3, y2, u2, v1, u3, v2, c);
    quad(x0, y2, x1, y3, u0, v2, u1, v3, c);
    quad(x1, y2, x2, y3, u1, v2, u2, v3, c);
    quad(x2, y2, x3, y3, u2, v2, u3, v3, c);
end

---turns the frame's records into vertices. runs once per frame.
local function expand()
    if (expanded) then return; end
    expanded = true;
    ex_x0, ex_y0, ex_x1, ex_y1 = -NO_CLIP, -NO_CLIP, NO_CLIP, NO_CLIP;
    local r, i, n = rec, 0, nrec;
    while (i < n) do
        if (nquads + 9 > capacity) then grow(nquads + 9); end
        local k = r[i];
        if (k == K_QUAD) then
            quad(r[i + 1], r[i + 2], r[i + 3], r[i + 4], r[i + 5], r[i + 6], r[i + 7], r[i + 8], r[i + 9]);
            i = i + Q_LEN;
        elseif (k == K_NINE) then
            quad_nine(r, i);
            i = i + NINE_LEN;
        elseif (k == K_TEX) then
            cmd_first[r[i + 1]] = nquads;
            i = i + TEX_LEN;
        elseif (k == K_HNINE) then
            local from = nquads;
            quad_nine(r, i);
            hgrad_quads(from, r[i + 18], r[i + 19], r[i + 17], r[i + 20]);
            i = i + HNINE_LEN;
        elseif (k == K_CLIP) then
            ex_x0, ex_y0, ex_x1, ex_y1 = r[i + 1], r[i + 2], r[i + 3], r[i + 4];
            i = i + CLIP_LEN;
        else -- K_VGRAD
            quad_vgrad(r[i + 1], r[i + 2], r[i + 3], r[i + 4], r[i + 5], r[i + 6], r[i + 7], r[i + 8]);
            i = i + VGRAD_LEN;
        end
    end
end

---merges the frame's runs into draw calls: drops empty ones, joins
---neighbours on the same texture (their quads are contiguous), and counts
---each one's quads. safe to call again.
local function finish_cmds()
    local n = 0;
    for i = 1, ncmds do
        local first = cmd_first[i];
        local count = (i < ncmds and cmd_first[i + 1] or nquads) - first;
        if (count > 0) then
            if (n > 0 and cmd_tex[n] == cmd_tex[i]) then
                cmd_count[n] = cmd_count[n] + count;
            else
                n = n + 1;
                cmd_tex[n], cmd_first[n], cmd_count[n] = cmd_tex[i], first, count;
            end
        end
    end
    for i = n + 1, ncmds do cmd_tex[i] = nil; end
    ncmds = n;
end

--[[ helpers ]]--

---applies the current opacity to a colour and wraps it into 0..2^32-1: bit
---ops return signed int32, so colours with alpha >= 0x80 arrive negative, and
---negative -> uint32_t is undefined in ffi (32-bit luajit, what ashita runs,
---really does mangle it once traces compile). once per draw, not per vertex.
local function fade(c)
    local a = floor(band(rshift(c, 24), 0xFF) * opacity + 0.5);
    return bor(lshift(a, 24), band(c, 0x00FFFFFF)) % 4294967296;
end

local function round(v)
    return floor(v + 0.5);
end

---painted (untinted) art keeps its own colours; only the alpha applies.
local function slot_color(meta, c)
    if (meta.tint) then return c; end
    return bor(band(c, 0xFF000000), 0x00FFFFFF);
end

--[[ frame ]]--

function render.begin_frame()
    nquads, ncmds, nrec, expanded = 0, 0, 0, false;
    clip_x0, clip_y0, clip_x1, clip_y1 = -NO_CLIP, -NO_CLIP, NO_CLIP, NO_CLIP;
    clip_depth, base, opacity = 0, 1, 1;
end

--[[ state ]]--

---intersects with the current clip rect. pairs with pop_clip.
function render.push_clip(x, y, w, h)
    local i = clip_depth * 4;
    clip_stack[i + 1], clip_stack[i + 2], clip_stack[i + 3], clip_stack[i + 4] = clip_x0, clip_y0, clip_x1, clip_y1;
    clip_depth = clip_depth + 1;
    clip_x0, clip_y0, clip_x1, clip_y1 = max(x, clip_x0), max(y, clip_y0), min(x + w, clip_x1), min(y + h, clip_y1);
    rec_clip();
end

function render.pop_clip()
    if (clip_depth == 0) then return; end
    clip_depth = clip_depth - 1;
    local i = clip_depth * 4;
    clip_x0, clip_y0, clip_x1, clip_y1 = clip_stack[i + 1], clip_stack[i + 2], clip_stack[i + 3], clip_stack[i + 4];
    rec_clip();
end

---depth of the clip stack, for restore().
function render.depth()
    return clip_depth;
end

---undoes state left behind by a draw that didn't finish (a component that
---errored mid-draw): pops clips down to depth and resets opacity.
function render.restore(depth)
    while (clip_depth > depth) do render.pop_clip(); end
    opacity = base;
end

---multiplies the alpha of everything drawn afterwards (0..1), on top of the
---base opacity.
function render.set_opacity(a)
    opacity = base * max(0, min(1, a));
end

---the opacity set_opacity works relative to; the hud uses it to fade whole
---components. resets set_opacity.
function render.set_base_opacity(a)
    base = max(0, min(1, a));
    opacity = base;
end

--[[ drawing ]]--

---raw textured quad with explicit uvs (defaults to the whole texture).
function render.image(tex, x, y, w, h, color, u0, v0, u1, v1)
    use(tex, Q_LEN);
    rec_quad(x, y, x + w, y + h, u0 or 0, v0 or 0, u1 or 1, v1 or 1, fade(color or 0xFFFFFFFF));
end

---solid rectangle. pass `bottom` for a vertical gradient.
function render.rect(x, y, w, h, color, bottom)
    local meta = theme.slot('_white');
    if (meta == nil) then return; end
    local r = meta.region;
    local u, v = (r.u0 + r.u1) * 0.5, (r.v0 + r.v1) * 0.5;
    use(theme.texture(), Q_LEN);
    if (bottom == nil or bottom == color) then
        rec_quad(x, y, x + w, y + h, u, v, u, v, fade(color));
    else
        local i = nrec;
        rec[i], rec[i + 1], rec[i + 2], rec[i + 3], rec[i + 4] = K_VGRAD, x, y, x + w, y + h;
        rec[i + 5], rec[i + 6], rec[i + 7], rec[i + 8] = u, v, fade(color), fade(bottom);
        nrec = i + VGRAD_LEN;
    end
end

-- the body of render.nineslice, split out so its locals are gone by the time
-- nineslice returns. nineslice is hot and called from everywhere, so it gets
-- compiled on its own, and its return to each caller needs a side trace that
-- takes over every value still live there; with this many, moonjit can't on
-- 32-bit x86 ("register coalescing too complex"), and retries forever.
local function rec_nine(meta, x, y, w, h, color, flip)
    use(theme.texture(), NINE_LEN);
    local k = theme.active().scale / meta.density; -- texture px -> screen px
    local i = nrec;
    rec[i] = K_NINE;
    rec[i + 17] = fade(slot_color(meta, color or 0xFFFFFFFF));

    local o = round((meta.outset or 0) * k);
    local sl, st, sr, sb = meta.slice[1] * k, meta.slice[2] * k, meta.slice[3] * k, meta.slice[4] * k;
    -- grid lines in x: the rect's edges (rounded, then outset), and the fixed
    -- edges inside them, shrunk to fit when the rect is narrower than they are
    local x0, x3 = round(x) - o, round(x + w) + o;
    local f = (x3 - x0) / max(sl + sr, x3 - x0, 1e-6);
    rec[i + 1], rec[i + 2], rec[i + 3], rec[i + 4] = x0, x0 + sl * f, x3 - sr * f, x3;
    -- and in y; flipped, the bottom edge's texels go on top, sized as it is
    local y0, y3 = round(y) - o, round(y + h) + o;
    f = (y3 - y0) / max(st + sb, y3 - y0, 1e-6);
    if (flip) then
        rec[i + 5], rec[i + 6], rec[i + 7], rec[i + 8] = y0, y0 + sb * f, y3 - st * f, y3;
    else
        rec[i + 5], rec[i + 6], rec[i + 7], rec[i + 8] = y0, y0 + st * f, y3 - sb * f, y3;
    end

    local r, sl_, st_, sr_, sb_ = meta.region, meta.slice[1], meta.slice[2], meta.slice[3], meta.slice[4];
    local du, dv = (r.u1 - r.u0) / r.w, (r.v1 - r.v0) / r.h;
    rec[i + 9], rec[i + 10], rec[i + 11], rec[i + 12] = r.u0, r.u0 + sl_ * du, r.u1 - sr_ * du, r.u1;
    if (flip) then
        rec[i + 13], rec[i + 14], rec[i + 15], rec[i + 16] = r.v1, r.v1 - sb_ * dv, r.v0 + st_ * dv, r.v0;
    else
        rec[i + 13], rec[i + 14], rec[i + 15], rec[i + 16] = r.v0, r.v0 + st_ * dv, r.v1 - sb_ * dv, r.v1;
    end
    nrec = i + NINE_LEN;
end

---draws a nineslice or outset slot stretched to the rect. outset slots extend
---beyond the rect by their outset (shadows, glows). flip mirrors it top to
---bottom (e.g. a tab docked to the top of the screen instead of the bottom).
function render.nineslice(name, x, y, w, h, color, flip)
    local meta = theme.slot(name);
    if (meta == nil) then return; end
    rec_nine(meta, x, y, w, h, color, flip);
end

---a nineslice slot with a horizontal gradient: color at screen x gl, right
---at gr, interpolated between and held beyond them. drawing a long gradient
---as clipped spans of these gives it as many stops as it needs.
function render.nineslice_hgrad(name, x, y, w, h, color, right, gl, gr)
    local meta = theme.slot(name);
    if (meta == nil) then return; end
    if (nrec + TEX_LEN + HNINE_LEN > rcap) then grow_rec(nrec + TEX_LEN + HNINE_LEN); end
    -- through render.nineslice, not rec_nine: a second caller of rec_nine
    -- gives its return a second target, and that side exit has too many live
    -- values for 32-bit moonjit. then turn the record into a gradient one.
    render.nineslice(name, x, y, w, h, color);
    local i = nrec - NINE_LEN;
    rec[i] = K_HNINE;
    rec[nrec], rec[nrec + 1], rec[nrec + 2] = gl, gr, fade(slot_color(meta, right));
    nrec = nrec + 3;
end

---a nineslice slot's fixed edges (left, top, right, bottom) in screen
---pixels, e.g. to keep text clear of a shape's corners.
function render.slot_edges(name)
    local meta = theme.slot(name);
    if (meta == nil or meta.slice == nil) then return 0, 0, 0, 0; end
    local k = theme.active().scale / meta.density;
    local sl = meta.slice;
    return sl[1] * k, sl[2] * k, sl[3] * k, sl[4] * k;
end

---a slot's natural size in screen pixels (its texture at the current scale).
function render.slot_size(name)
    local meta = theme.slot(name);
    if (meta == nil) then return 0, 0; end
    local k = theme.active().scale / meta.density;
    return meta.region.w * k, meta.region.h * k;
end

---draws a sprite slot with its pivot at (x, y). returns the drawn size.
function render.sprite(name, x, y, color, scale)
    local meta = theme.slot(name);
    if (meta == nil) then return 0, 0; end
    local r = meta.region;
    local k = theme.active().scale / meta.density * (scale or 1);
    local w, h = r.w * k, r.h * k;
    local px, py = meta.pivot[1], meta.pivot[2];
    x, y = round(x - w * px), round(y - h * py);
    use(theme.texture(), Q_LEN);
    rec_quad(x, y, x + w, y + h, r.u0, r.v0, r.u1, r.v1, fade(slot_color(meta, color or 0xFFFFFFFF)));
    return w, h;
end

local ALIGN = { left = 0, center = 0.5, right = 1 };

---width of a string in a glyph set, in screen pixels.
function render.glyphs_width(set, str)
    local w, g = 0, set.glyphs;
    for i = 1, #str do
        local gl = g[str:byte(i)];
        if (gl ~= nil) then w = w + gl.adv; end
    end
    return w + set.pad;
end

local function glyph_pass(set, str, x, y, c, which)
    local g = set.glyphs;
    for i = 1, #str do
        local gl = g[str:byte(i)];
        if (gl ~= nil) then
            local meta = gl[which];
            if (meta ~= nil) then
                local r, gx = meta.region, x + gl.off;
                rec_quad(gx, y, gx + r.w, y + r.h, r.u0, r.v0, r.u1, r.v1, c);
            end
            x = x + gl.adv;
        end
    end
end

---draws a string from an atlas glyph set (see ui/text.lua) with its anchor at
---(x, y). all outlines go down before any fill so neighbouring glyphs never
---cover each other. the fill is tinted by color; outlines keep their colour.
---@return number w, number h
function render.glyphs(set, str, x, y, color, align)
    local w = render.glyphs_width(set, str);
    x, y = round(x - w * (ALIGN[align or 'left'] or 0)), round(y);
    local c = color or 0xFFFFFFFF;
    use(theme.texture(), (set.outline and #str * 2 or #str) * Q_LEN);
    if (set.outline) then
        glyph_pass(set, str, x, y, fade(bor(band(c, 0xFF000000), 0x00FFFFFF)), 'outline');
    end
    glyph_pass(set, str, x, y, fade(c), 'fill');
    return w, set.height;
end

-- texture sizes for text, keyed weakly by texture so they go when fonts do.
local tex_dims = setmetatable({}, { __mode = 'k' });

---draws a gdifonts object (manual mode) with its top-left at (x, y). with
---`tint`, color multiplies the glyphs (render them white); otherwise only its
---alpha applies and the font's baked colours show as-is.
---@return number w, number h
function render.text(font, x, y, color, tint)
    local tex, rect = font:get_texture();
    if (tex == nil) then return 0, 0; end

    local dims = tex_dims[tex];
    if (dims == nil) then
        local res, desc = tex:GetLevelDesc(0);
        if (res ~= ffi.C.S_OK) then return 0, 0; end
        dims = { desc.Width, desc.Height };
        tex_dims[tex] = dims;
    end

    local w, h = rect.right, rect.bottom;
    local c = color or 0xFFFFFFFF;
    if (not tint) then c = bor(band(c, 0xFF000000), 0x00FFFFFF); end
    x, y = round(x), round(y);
    use(tex, Q_LEN);
    rec_quad(x, y, x + w, y + h, 0, 0, w / dims[1], h / dims[2], fade(c));
    return w, h;
end

--[[ submission ]]--

local C = ffi.C;
local RS, TSS, FVF; -- built on first submit, once the d3d8 bindings are loaded

-- every state we touch, so it can be captured and restored.
local function build_states()
    RS = {
        { C.D3DRS_ZENABLE,          C.D3DZB_FALSE },
        { C.D3DRS_ZWRITEENABLE,     0 },
        { C.D3DRS_ALPHABLENDENABLE, 1 },
        { C.D3DRS_SRCBLEND,         C.D3DBLEND_SRCALPHA },
        { C.D3DRS_DESTBLEND,        C.D3DBLEND_INVSRCALPHA },
        { C.D3DRS_BLENDOP,          C.D3DBLENDOP_ADD },
        { C.D3DRS_ALPHATESTENABLE,  0 },
        { C.D3DRS_CULLMODE,         C.D3DCULL_NONE },
        { C.D3DRS_LIGHTING,         0 },
        { C.D3DRS_FOGENABLE,        0 },
        { C.D3DRS_SPECULARENABLE,   0 },
        { C.D3DRS_STENCILENABLE,    0 },
        { C.D3DRS_FILLMODE,         C.D3DFILL_SOLID },
        { C.D3DRS_SHADEMODE,        C.D3DSHADE_GOURAUD },
        { C.D3DRS_COLORWRITEENABLE, 0x0F },
    };

    TSS = {
        { 0, C.D3DTSS_COLOROP,               C.D3DTOP_MODULATE },
        { 0, C.D3DTSS_COLORARG1,             C.D3DTA_TEXTURE },
        { 0, C.D3DTSS_COLORARG2,             C.D3DTA_DIFFUSE },
        { 0, C.D3DTSS_ALPHAOP,               C.D3DTOP_MODULATE },
        { 0, C.D3DTSS_ALPHAARG1,             C.D3DTA_TEXTURE },
        { 0, C.D3DTSS_ALPHAARG2,             C.D3DTA_DIFFUSE },
        { 0, C.D3DTSS_MAGFILTER,             C.D3DTEXF_LINEAR },
        { 0, C.D3DTSS_MINFILTER,             C.D3DTEXF_LINEAR },
        { 0, C.D3DTSS_MIPFILTER,             C.D3DTEXF_NONE },
        { 0, C.D3DTSS_ADDRESSU,              C.D3DTADDRESS_CLAMP },
        { 0, C.D3DTSS_ADDRESSV,              C.D3DTADDRESS_CLAMP },
        { 0, C.D3DTSS_TEXCOORDINDEX,         0 },
        { 0, C.D3DTSS_TEXTURETRANSFORMFLAGS, C.D3DTTFF_DISABLE },
        { 1, C.D3DTSS_COLOROP,               C.D3DTOP_DISABLE },
        { 1, C.D3DTSS_ALPHAOP,               C.D3DTOP_DISABLE },
    };

    FVF = bor(C.D3DFVF_XYZRHW, C.D3DFVF_DIFFUSE, C.D3DFVF_TEX1);
end

local saved_rs, saved_tss = {}, {};
local hooks = {};

---fn() runs at the start of every end_frame, before anything is submitted
---(e.g. to write textures the frame's quads use).
function render.before_submit(fn)
    for _, h in ipairs(hooks) do
        if (h == fn) then return; end
    end
    hooks[#hooks + 1] = fn;
end

---submits the frame's quads. call once per frame from d3d_present.
function render.end_frame()
    for i = 1, #hooks do hooks[i](); end
    expand();
    finish_cmds();
    local calls = 0;
    for i = 1, ncmds do calls = calls + math.ceil(cmd_count[i] / MAX_PER_CALL); end
    last_stats.quads, last_stats.calls = nquads, calls;
    if (nquads == 0) then return; end

    local dev = require('d3d8').get_device();
    if (RS == nil) then build_states(); end

    -- capture
    for i, s in ipairs(RS) do
        local _, v = dev:GetRenderState(s[1]);
        saved_rs[i] = v;
    end
    for i, s in ipairs(TSS) do
        local _, v = dev:GetTextureStageState(s[1], s[2]);
        saved_tss[i] = v;
    end
    local _, old_vs  = dev:GetVertexShader();
    local _, old_ps  = dev:GetPixelShader();
    local _, old_tex = dev:GetTexture(0); -- AddRef'd; released below

    -- set
    for _, s in ipairs(RS) do dev:SetRenderState(s[1], s[2]); end
    for _, s in ipairs(TSS) do dev:SetTextureStageState(s[1], s[2], s[3]); end
    dev:SetVertexShader(FVF);
    dev:SetPixelShader(0);

    -- draw
    for i = 1, ncmds do
        local first, left = cmd_first[i], cmd_count[i];
        dev:SetTexture(0, ffi.cast('IDirect3DBaseTexture8*', cmd_tex[i]));
        while (left > 0) do -- 16-bit indices address MAX_PER_CALL quads at a time
            local count = min(left, MAX_PER_CALL);
            dev:DrawIndexedPrimitiveUP(C.D3DPT_TRIANGLELIST, 0, count * 4, count * 2,
                indices, C.D3DFMT_INDEX16, verts + first * 4, VERTEX_SIZE);
            first, left = first + count, left - count;
        end
    end

    -- restore
    for i, s in ipairs(RS) do
        if (saved_rs[i] ~= nil) then dev:SetRenderState(s[1], saved_rs[i]); end
    end
    for i, s in ipairs(TSS) do
        if (saved_tss[i] ~= nil) then dev:SetTextureStageState(s[1], s[2], saved_tss[i]); end
    end
    if (old_vs ~= nil) then dev:SetVertexShader(old_vs); end
    if (old_ps ~= nil) then dev:SetPixelShader(old_ps); end
    dev:SetTexture(0, old_tex);
    if (old_tex ~= nil) then old_tex:Release(); end

    -- don't keep last frame's textures (e.g. stale text) alive.
    for i = 1, ncmds do cmd_tex[i] = nil; end
end

---quads and draw calls submitted last frame.
function render.stats()
    return last_stats;
end

--[[ testing ]]--

---read-only view of the current batch, for offline tests.
function render._batch()
    expand();
    finish_cmds();
    return verts, nquads, { tex = cmd_tex, first = cmd_first, count = cmd_count, n = ncmds };
end

return render;
