--[[
* batched quad renderer.
*
* components call the draw functions between begin_frame and end_frame. every
* draw appends a textured, coloured quad to one vertex array; consecutive quads
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

-- draw commands as parallel arrays to avoid per-frame table garbage.
local cmd_tex, cmd_first, cmd_count = {}, {}, {};
local ncmds = 0;

local clip_stack, clip = {}, nil; -- clip = { x0, y0, x1, y1 } or nil
local base, opacity = 1, 1; -- base: set by the hud per component; opacity: base * set_opacity()

local last_stats = { quads = 0, calls = 0 };

--[[ vertex emission ]]--

local function grow()
    local ncap = capacity * 2;
    local nv = ffi.new('linhud_vertex_t[?]', ncap * 4);
    ffi.copy(nv, verts, nquads * 4 * VERTEX_SIZE);
    verts, capacity = nv, ncap;
end

local function fade(c)
    if (opacity >= 1) then return c; end
    local a = floor(band(rshift(c, 24), 0xFF) * opacity + 0.5);
    return bor(lshift(a, 24), band(c, 0x00FFFFFF));
end

---interpolates two argb colours per channel.
local function lerp_color(a, b, t)
    if (a == b) then return a; end
    local r = 0;
    for s = 0, 24, 8 do
        local ca, cb = band(rshift(a, s), 0xFF), band(rshift(b, s), 0xFF);
        r = bor(r, lshift(floor(ca + (cb - ca) * t + 0.5), s));
    end
    return r;
end

local function set_vertex(v, x, y, u, vv, c)
    v.x, v.y, v.z, v.rhw = x - 0.5, y - 0.5, 0, 1; -- d3d8 texel/pixel centre alignment
    -- bit ops return signed int32, so colours with alpha >= 0x80 arrive negative.
    -- negative -> uint32_t is undefined in ffi and 32-bit luajit (what ashita
    -- runs) really does mangle it once traces compile. wrap into 0..2^32-1.
    v.color, v.u, v.v = c % 4294967296, u, vv;
end

---appends one axis-aligned quad. colours are per corner (tl, tr, bl, br).
local function emit(tex, x0, y0, x1, y1, u0, v0, u1, v1, ctl, ctr, cbl, cbr)
    if (clip ~= nil) then
        local cx0, cy0, cx1, cy1 = max(x0, clip[1]), max(y0, clip[2]), min(x1, clip[3]), min(y1, clip[4]);
        if (cx0 >= cx1 or cy0 >= cy1) then return; end
        if (cx0 ~= x0 or cy0 ~= y0 or cx1 ~= x1 or cy1 ~= y1) then
            local w, h = x1 - x0, y1 - y0;
            local tx0, ty0, tx1, ty1 = (cx0 - x0) / w, (cy0 - y0) / h, (cx1 - x0) / w, (cy1 - y0) / h;
            local du, dv = u1 - u0, v1 - v0;
            if (ctl ~= ctr or ctl ~= cbl or ctl ~= cbr) then
                local l0, l1 = lerp_color(ctl, cbl, ty0), lerp_color(ctl, cbl, ty1);
                local r0, r1 = lerp_color(ctr, cbr, ty0), lerp_color(ctr, cbr, ty1);
                ctl, ctr = lerp_color(l0, r0, tx0), lerp_color(l0, r0, tx1);
                cbl, cbr = lerp_color(l1, r1, tx0), lerp_color(l1, r1, tx1);
            end
            x0, y0, x1, y1 = cx0, cy0, cx1, cy1;
            u0, v0, u1, v1 = u0 + du * tx0, v0 + dv * ty0, u0 + du * tx1, v0 + dv * ty1;
        end
    end
    if (x0 >= x1 or y0 >= y1) then return; end

    if (nquads >= capacity) then grow(); end

    if (ncmds > 0 and cmd_tex[ncmds] == tex and cmd_count[ncmds] < MAX_PER_CALL) then
        cmd_count[ncmds] = cmd_count[ncmds] + 1;
    else
        ncmds = ncmds + 1;
        cmd_tex[ncmds], cmd_first[ncmds], cmd_count[ncmds] = tex, nquads, 1;
    end

    local v = verts + nquads * 4;
    set_vertex(v[0], x0, y0, u0, v0, fade(ctl));
    set_vertex(v[1], x1, y0, u1, v0, fade(ctr));
    set_vertex(v[2], x0, y1, u0, v1, fade(cbl));
    set_vertex(v[3], x1, y1, u1, v1, fade(cbr));
    nquads = nquads + 1;
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
    nquads, ncmds = 0, 0;
    clip, base, opacity = nil, 1, 1;
    for i = #clip_stack, 1, -1 do clip_stack[i] = nil; end
end

--[[ state ]]--

---intersects with the current clip rect. pairs with pop_clip.
function render.push_clip(x, y, w, h)
    clip_stack[#clip_stack + 1] = clip;
    local x1, y1 = x + w, y + h;
    if (clip ~= nil) then
        x, y, x1, y1 = max(x, clip[1]), max(y, clip[2]), min(x1, clip[3]), min(y1, clip[4]);
    end
    clip = { x, y, x1, y1 };
end

function render.pop_clip()
    local n = #clip_stack;
    clip = clip_stack[n];
    clip_stack[n] = nil;
end

---depth of the clip stack, for restore().
function render.depth()
    return #clip_stack;
end

---undoes state left behind by a draw that didn't finish (a component that
---errored mid-draw): pops clips down to depth and resets opacity.
function render.restore(depth)
    while (#clip_stack > depth) do render.pop_clip(); end
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
    color = color or 0xFFFFFFFF;
    emit(tex, x, y, x + w, y + h, u0 or 0, v0 or 0, u1 or 1, v1 or 1, color, color, color, color);
end

---solid rectangle. pass `bottom` for a vertical gradient.
function render.rect(x, y, w, h, color, bottom)
    local meta = theme.slot('_white');
    if (meta == nil) then return; end
    local r = meta.region;
    local u, v = (r.u0 + r.u1) * 0.5, (r.v0 + r.v1) * 0.5;
    bottom = bottom or color;
    emit(theme.texture(), x, y, x + w, y + h, u, v, u, v, color, color, bottom, bottom);
end

local function nine_row(tex, y0, y1, v0, v1, x0, x1, x2, x3, u0, u1, u2, u3, c)
    emit(tex, x0, y0, x1, y1, u0, v0, u1, v1, c, c, c, c);
    emit(tex, x1, y0, x2, y1, u1, v0, u2, v1, c, c, c, c);
    emit(tex, x2, y0, x3, y1, u2, v0, u3, v1, c, c, c, c);
end

---draws a nineslice or outset slot stretched to the rect. outset slots extend
---beyond the rect by their outset (shadows, glows).
function render.nineslice(name, x, y, w, h, color)
    local meta = theme.slot(name);
    if (meta == nil) then return; end
    local tex, r = theme.texture(), meta.region;
    local k = theme.active().scale / meta.density; -- texture px -> screen px
    local c = slot_color(meta, color or 0xFFFFFFFF);

    local x1, y1 = round(x + w), round(y + h);
    x, y = round(x), round(y);
    w, h = x1 - x, y1 - y;
    local o = round((meta.outset or 0) * k);
    x, y, w, h = x - o, y - o, w + o * 2, h + o * 2;

    local sl, st, sr, sb = meta.slice[1], meta.slice[2], meta.slice[3], meta.slice[4];
    local l, t, rr, b = sl * k, st * k, sr * k, sb * k;
    if (l + rr > w) then local f = w / (l + rr); l, rr = l * f, rr * f; end
    if (t + b > h) then local f = h / (t + b); t, b = t * f, b * f; end

    local du, dv = (r.u1 - r.u0) / r.w, (r.v1 - r.v0) / r.h;
    local x0, x1_, x2, x3 = x, x + l, x + w - rr, x + w;
    local u0, u1, u2, u3 = r.u0, r.u0 + sl * du, r.u1 - sr * du, r.u1;
    local y0, y1_, y2, y3 = y, y + t, y + h - b, y + h;
    local v0, v1, v2, v3 = r.v0, r.v0 + st * dv, r.v1 - sb * dv, r.v1;

    nine_row(tex, y0, y1_, v0, v1, x0, x1_, x2, x3, u0, u1, u2, u3, c);
    nine_row(tex, y1_, y2, v1, v2, x0, x1_, x2, x3, u0, u1, u2, u3, c);
    nine_row(tex, y2, y3, v2, v3, x0, x1_, x2, x3, u0, u1, u2, u3, c);
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
    local c = slot_color(meta, color or 0xFFFFFFFF);
    emit(theme.texture(), x, y, x + w, y + h, r.u0, r.v0, r.u1, r.v1, c, c, c, c);
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

local function glyph_pass(tex, set, str, x, y, c, which)
    local g = set.glyphs;
    for i = 1, #str do
        local gl = g[str:byte(i)];
        if (gl ~= nil) then
            local meta = gl[which];
            if (meta ~= nil) then
                local r, gx = meta.region, x + gl.off;
                emit(tex, gx, y, gx + r.w, y + r.h, r.u0, r.v0, r.u1, r.v1, c, c, c, c);
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
    local tex = theme.texture();
    local c = color or 0xFFFFFFFF;
    if (set.outline) then
        glyph_pass(tex, set, str, x, y, bor(band(c, 0xFF000000), 0x00FFFFFF), 'outline');
    end
    glyph_pass(tex, set, str, x, y, c, 'fill');
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
    emit(tex, x, y, x + w, y + h, 0, 0, w / dims[1], h / dims[2], c, c, c, c);
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

---submits the frame's quads. call once per frame from d3d_present.
function render.end_frame()
    last_stats.quads, last_stats.calls = nquads, ncmds;
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
        local count = cmd_count[i];
        dev:SetTexture(0, ffi.cast('IDirect3DBaseTexture8*', cmd_tex[i]));
        dev:DrawIndexedPrimitiveUP(C.D3DPT_TRIANGLELIST, 0, count * 4, count * 2,
            indices, C.D3DFMT_INDEX16, verts + cmd_first[i] * 4, VERTEX_SIZE);
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
    return verts, nquads, { tex = cmd_tex, first = cmd_first, count = cmd_count, n = ncmds };
end

return render;
