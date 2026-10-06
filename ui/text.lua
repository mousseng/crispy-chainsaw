--[[
* text on top of gdifonts, drawn through the batched renderer.
*
* two kinds of text:
*
*   text.new    - a gdifonts object. the string is rasterised to its own texture
*                 whenever it changes, so use it for text that rarely changes
*                 (names, labels). each object is one draw call.
*
*   text.number - drawn from glyph sets pre-rendered into the theme atlas at
*                 theme load. changing the string is free and it batches with
*                 the rest of the atlas, so use it for values that tick (hp, mp,
*                 tp, timers). only covers the characters in the set.
*
* glyphs are rendered white and tinted per draw: white fill * tint = tint,
* black outline * tint = black, so changing colour never re-rasterises.
--]]

local bit    = require('bit');
local gdi    = require('gdifonts.include');
local atlas  = require('ui.atlas');
local image  = require('ui.image');
local render = require('ui.render');
local theme  = require('ui.theme');

-- we draw manual objects ourselves; don't let gdifonts run its own sprite pass.
gdi:set_auto_render(false);

local text = {};

-- live objects, restyled when the theme or scale changes.
local objects = setmetatable({}, { __mode = 'k' });

local DEFAULT_CHARS = '0123456789,.%/-+: ';

local function active_scale()
    local a = theme.active();
    return a and a.scale or 1;
end

---maps a theme font + overrides onto gdifonts settings.
local function style(opts, font, scale)
    local bold = opts.bold;
    if (bold == nil) then bold = font.bold; end
    return {
        font_family   = opts.family or font.family or 'Arial',
        font_height   = math.floor((opts.size or font.size or 12) * scale + 0.5),
        font_flags    = bold and gdi.FontFlags.Bold or gdi.FontFlags.None,
        outline_width = (opts.outline or font.outline or 2) * scale,
        outline_color = opts.outline_color or font.outline_color or 0xFF000000,
        font_color    = opts.tint == false and (opts.color or 0xFFFFFFFF) or 0xFFFFFFFF,
    };
end

local function apply(obj, st)
    obj:set_font_family(st.font_family);
    obj:set_font_height(st.font_height);
    obj:set_font_flags(st.font_flags);
    obj:set_outline_width(st.outline_width);
    obj:set_outline_color(st.outline_color);
    obj:set_font_color(st.font_color);
end

--[[ baselines ]]--

-- gdifonttexture trims each texture to its ink on the left, right and bottom
-- but never the top, so every capture starts at the line top. a capture of "H"
-- (flat bottom, no descender) then ends at the baseline plus the outline below
-- it. text in one style shares that, so lining up those offsets lines up
-- baselines whatever the ascenders and descenders of the strings themselves.
-- likewise "Hgjpqy" ends at the deepest descender: the full line's height.
local baselines, depths, probe = {}, {}, nil;

local function probe_height(st, str)
    if (probe == nil) then
        probe = gdi:create_object(st, true);
    else
        apply(probe, st);
    end
    probe:set_text(str);
    local _, rect = probe:get_texture();
    return rect and rect.bottom or st.font_height;
end

---top-of-line to baseline (outline included), and top-of-line to the bottom
---of the deepest descender, for gdifonts style `st`.
local function measure_baseline(st)
    local key = ('%s|%d|%d|%s'):format(st.font_family, st.font_height, st.font_flags, st.outline_width);
    local b = baselines[key];
    if (b == nil) then
        b = probe_height(st, 'H');
        baselines[key], depths[key] = b, math.max(b, probe_height(st, 'Hgjpqy'));
    end
    return b, depths[key];
end

--[[ gdifonts text ]]--

local label = {};
label.__index = label;

---@param opts table|nil { text, size, family, bold, outline, outline_color, color, tint }
---sizes are logical pixels; omitted values come from the theme's font.
function text.new(opts)
    opts = opts or {};
    local st = style(opts, theme.font(), active_scale());
    st.text = opts.text or '';
    local self = setmetatable({ opts = opts, st = st, obj = gdi:create_object(st, true) }, label);
    objects[self] = true;
    return self;
end

---setting the same string again is free; a different one re-rasterises.
function label:set(str)
    self.obj:set_text(str);
end

---@return number w, number h in screen pixels (0, 0 for empty text)
function label:size()
    local _, rect = self.obj:get_texture();
    if (rect == nil) then return 0, 0; end
    return rect.right, rect.bottom;
end

---@return number base distance from the top of the text (its draw y) to its
---baseline, in screen pixels; draw at (baseline y - base) to sit on a line.
---@return number line height of the style's line, deepest descender included.
function label:baseline()
    local b = self.base;
    if (b == nil) then
        b, self.line = measure_baseline(self.st);
        self.base = b;
    end
    return b, self.line;
end

---draws with the anchor at (x, y). align: 'left' | 'center' | 'right'.
---color tints the text (alpha only when tint = false).
---@return number w, number h
function label:draw(x, y, color, align)
    local w = self:size();
    if (align == 'center') then x = x - w * 0.5; elseif (align == 'right') then x = x - w; end
    color = color or self.opts.color or 0xFFFFFFFF;
    return render.text(self.obj, x, y, color, self.opts.tint ~= false);
end

--[[ atlas glyph sets ]]--

local band, rshift = bit.band, bit.rshift;

local function warn(fmt, ...)
    print(('\30\81[\30\06crispy-chainsaw\30\81]\30\01 text: ' .. fmt):format(...));
end

---rasterises a string and reads it back as an image cropped to the text.
local function capture(obj, str)
    obj:set_text(str);
    local tex, rect = obj:get_texture();
    if (tex == nil) then return nil; end
    local img, err = atlas.read(tex);
    if (img == nil) then error(err, 0); end
    if (img.w ~= rect.right or img.h ~= rect.bottom) then
        img = img:sub(0, 0, rect.right, rect.bottom);
    end
    return img;
end

---finds where `fill` sits inside `whole` (both trimmed differently by
---gdifonttexture) by testing every offset and keeping the one where fill
---coverage best matches whole's white (fill) pixels.
---@return integer|nil dx, integer dy
local function locate(fill, whole)
    local best, bx, by = math.huge, nil, 0;
    for dy = -2, 2 do
        for dx = 0, whole.w - fill.w do
            local err = 0;
            for y = 0, fill.h - 1 do
                local wy = y + dy;
                for x = 0, fill.w - 1 do
                    local fa = rshift(fill.px[y * fill.w + x], 24);
                    local wv = 0;
                    if (wy >= 0 and wy < whole.h) then
                        local p = whole.px[wy * whole.w + x + dx];
                        wv = rshift(p, 24) * band(p, 0xFF) / 255; -- alpha * whiteness
                    end
                    err = err + math.abs(fa - wv);
                end
            end
            if (err < best) then best, bx, by = err, dx, dy; end
        end
    end
    return bx, by;
end

---builds one glyph set.
---
---each glyph becomes two images of identical size: an outline layer (the whole
---glyph's silhouette in the outline colour) and a fill layer. drawing every
---outline layer before any fill reproduces outline-behind-fill exactly, and
---neighbouring glyphs can never paint over each other's fills.
---
---gdifonttexture only makes a pen when the outline alpha is non-zero, and trims
---each texture to its inked pixels (left, right, bottom). so we capture the
---glyph whole, capture it again with a transparent outline (fill only), and
---find where the fill sits inside the whole capture. if anything about that
---fails, the whole capture is used as-is.
---
---trimming also drops each glyph's left side bearing; it's recovered from
---trimmed widths W: adv(c) = W("0c0") - W("00"), and the bearing of c
---relative to "0" is adv(c) - adv(0) - (W("c0") - W("00")).
local function build_set(ctx, name, cfg)
    local st = style(cfg, ctx.font, ctx.scale);
    local obj = gdi:create_object(st, true);
    local function width(s)
        obj:set_text(s);
        local _, r = obj:get_texture();
        return r and r.right or 0;
    end

    local set = { glyphs = {}, height = 0, pad = 0, outline = false };
    set.baseline, set.line = measure_baseline(st);
    local split = st.outline_width > 0;
    local outline_rgb = band(st.outline_color, 0x00FFFFFF);
    local base = width('00');
    local adv0 = width('000') - base;
    local chars = cfg.chars or DEFAULT_CHARS;

    for i = 1, #chars do
        local ch, b = chars:sub(i, i), chars:byte(i);
        local adv = width('0' .. ch .. '0') - base;
        local gl = { adv = adv, off = 0 };
        if (ch ~= ' ') then
            gl.off = adv - adv0 - (width(ch .. '0') - base);
        end
        set.glyphs[b] = gl;

        local whole = (ch ~= ' ') and capture(obj, ch) or nil;
        if (whole ~= nil) then
            local fill_layer, outline_layer;
            if (split) then
                obj:set_outline_color(0x00000000);
                local fill = capture(obj, ch);
                obj:set_outline_color(st.outline_color);

                local why;
                if (fill == nil) then
                    why = 'fill-only capture was empty';
                elseif (fill.w > whole.w or fill.h > whole.h + 2) then
                    why = ('fill-only capture (%dx%d) larger than whole (%dx%d)'):format(fill.w, fill.h, whole.w, whole.h);
                end
                local dx, dy;
                if (why == nil) then
                    dx, dy = locate(fill, whole);
                    if (dx == nil) then why = 'could not align fill inside whole glyph'; end
                end

                if (why ~= nil) then
                    warn('glyph set "%s": %s for "%s"; using whole glyphs', name, why, ch);
                    split = false;
                else
                    fill_layer = image.new(whole.w, whole.h);
                    for y = 0, fill.h - 1 do
                        local wy = y + dy;
                        if (wy >= 0 and wy < whole.h) then
                            for x = 0, fill.w - 1 do
                                fill_layer.px[wy * whole.w + x + dx] = fill.px[y * fill.w + x];
                            end
                        end
                    end
                    outline_layer = image.new(whole.w, whole.h);
                    for p = 0, whole.w * whole.h - 1 do
                        local a = rshift(whole.px[p], 24);
                        if (a > 0) then
                            outline_layer.px[p] = bit.bor(bit.lshift(a, 24), outline_rgb) % 4294967296; -- unsigned; see render.lua set_vertex
                        end
                    end
                end
            end

            local key = ('glyph:%s:%d'):format(name, b);
            gl.fill = { type = 'glyph', density = ctx.scale, tint = true };
            if (fill_layer ~= nil) then
                ctx.add(key, fill_layer, gl.fill);
                gl.outline = { type = 'glyph', density = ctx.scale, tint = false };
                ctx.add(key .. ':o', outline_layer, gl.outline);
                set.outline = true;
            else
                ctx.add(key, whole, gl.fill);
            end
            set.height = math.max(set.height, whole.h);
            if (ch == '0') then set.pad = math.max(0, whole.w - gl.adv); end
        end
    end

    -- set.outline is true if any glyph was split; the outline pass skips glyphs
    -- captured whole, and the fill pass draws either form.
    return set;
end

theme.providers.glyphs = function (ctx)
    local sets = {};
    for name, cfg in pairs(ctx.glyphs) do
        sets[name] = build_set(ctx, name, cfg);
    end
    return sets;
end

local number = {};
number.__index = number;

---a value drawn from the atlas glyph set `set` (defined under `glyphs` in the
---theme). falls back to a gdifonts object if the set isn't available.
function text.number(set)
    return setmetatable({ glyph_set = set, str = '' }, number);
end

local function find_set(name)
    local sets = theme.extra('glyphs');
    return sets and sets[name];
end

function number:set(str)
    self.str = str;
end

local function fallback(self)
    if (self.fallback == nil) then
        local a = theme.active();
        self.fallback = text.new((a and a.glyphs[self.glyph_set]) or {});
    end
    self.fallback:set(self.str);
    return self.fallback;
end

---@return number w, number h
function number:size()
    local gs = find_set(self.glyph_set);
    if (gs ~= nil) then
        return render.glyphs_width(gs, self.str), gs.height;
    end
    return fallback(self):size();
end

---@return number base, number line; see label:baseline.
function number:baseline()
    local gs = find_set(self.glyph_set);
    if (gs ~= nil) then
        return gs.baseline, gs.line;
    end
    return fallback(self):baseline();
end

---@return number w, number h
function number:draw(x, y, color, align)
    local gs = find_set(self.glyph_set);
    if (gs ~= nil) then
        return render.glyphs(gs, self.str, x, y, color, align);
    end
    return fallback(self):draw(x, y, color, align);
end

--[[ lifecycle ]]--

---re-reads theme font settings for every live object. call after a theme
---or scale change. (number objects read the atlas directly.)
function text.restyle()
    local font, scale = theme.font(), active_scale();
    baselines, depths = {}, {};
    for self in pairs(objects) do
        self.st = style(self.opts, font, scale);
        self.base = nil;
        apply(self.obj, self.st);
    end
end

---gdifonts textures held by live text, assuming 32-bit pixels. textures
---replaced by a new string wait for the gc, and aren't counted.
---@return number count, number bytes
function text.mem()
    local n, bytes = 0, 0;
    for self in pairs(objects) do
        local r = self.obj.texture ~= nil and self.obj.rect;
        if (r) then n, bytes = n + 1, bytes + r.right * r.bottom * 4; end
    end
    return n, bytes;
end

function text.shutdown()
    objects = setmetatable({}, { __mode = 'k' });
    baselines, depths, probe = {}, {}, nil;
    gdi:destroy_interface();
end

return text;
