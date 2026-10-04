--[[
* theme loader.
*
* a theme is a lua file returning { base, palette, font, slots }. every slot
* names a source - `gen = '<generator>'` or `file = '<path>'` - and every
* source ends up as a region in one atlas texture. components only ever ask
* for slots by name and never see where the art came from.
*
* themes inherit from `base` (default: 'default'). palette and font merge key
* by key; slots replace whole (a file slot does not inherit generator params).
* if a slot fails to build (missing file, bad spec) the base theme's version
* of that slot is used instead.
--]]

local atlas = require('ui.atlas');
local gen   = require('ui.gen');
local image = require('ui.image');

local theme = {};

---searched in order; set by the addon on load. user themes go first so they
---survive addon updates and can shadow bundled ones.
theme.paths = {};

---the contract components rely on: slot name -> type.
theme.SLOTS = {
    panel                = 'nineslice',
    panel_border         = 'nineslice',
    panel_shadow         = 'outset',
    panel_glow           = 'outset',
    row_highlight        = 'nineslice',
    bar                  = 'nineslice',
    bar_bg               = 'nineslice',
    bar_border           = 'nineslice',
    bar_glow             = 'outset',
    tab                  = 'nineslice',
    tab_border           = 'nineslice',
    arrow_target         = 'sprite',
    arrow_subtarget      = 'sprite',
    arrow_party          = 'sprite',
    mark_leader          = 'sprite',
    mark_alliance_leader = 'sprite',
    mark_sync            = 'sprite',
    dot                  = 'sprite',
    cell                 = 'nineslice',
    map_arrow            = 'sprite',
    map_arrow_edge       = 'sprite',
    map_dot              = 'sprite',
    map_dot_edge         = 'sprite',
};

---named functions that add generated images to the atlas at build time, e.g.
---text glyphs. each is called as fn(ctx) with ctx = { font, glyphs, scale, add }
---where add(name, img, meta) registers a region; the return value is kept and
---available from theme.extra(name).
theme.providers = {};

local current = nil;

local function warn(fmt, ...)
    print(('\30\81[\30\06linhud\30\81]\30\01 theme: ' .. fmt):format(...));
end

local function file_exists(path)
    local f = io.open(path, 'rb');
    if (f ~= nil) then f:close(); return true; end
    return false;
end

---finds and evaluates themes/<name>/theme.lua. theme files run in an empty
---environment: they are data, not code.
local function load_def(name)
    for _, root in ipairs(theme.paths) do
        local dir = ('%s/%s'):format(root, name);
        local path = dir .. '/theme.lua';
        if (file_exists(path)) then
            local chunk, err = loadfile(path);
            if (chunk == nil) then
                return nil, err;
            end
            setfenv(chunk, { math = math });
            local ok, def = pcall(chunk);
            if (not ok) then
                return nil, def;
            end
            if (type(def) ~= 'table') then
                return nil, path .. ' did not return a table';
            end
            def.name, def.dir = name, dir;
            return def;
        end
    end
    return nil, ('theme "%s" not found'):format(name);
end

---returns the inheritance chain, most-derived first.
local function load_chain(name)
    local chain, seen = {}, {};
    while (name ~= nil) do
        if (seen[name]) then
            return nil, ('theme inheritance cycle at "%s"'):format(name);
        end
        seen[name] = true;

        local def, err = load_def(name);
        if (def == nil) then
            return nil, err;
        end
        chain[#chain + 1] = def;

        if (def.base == false or name == 'default') then
            name = nil;
        else
            name = def.base or 'default';
        end
    end
    return chain;
end

---accepts 0xAARRGGBB, '#RRGGBB' or '#AARRGGBB'.
local function parse_color(v)
    if (type(v) == 'number') then return v; end
    if (type(v) == 'string') then
        local hex = v:match('^#(%x+)$');
        if (hex ~= nil and #hex == 6) then return tonumber('FF' .. hex, 16); end
        if (hex ~= nil and #hex == 8) then return tonumber(hex, 16); end
    end
    return nil;
end

local function norm_slice(s)
    if (type(s) == 'number') then return { s, s, s, s }; end
    return s;
end

---raises without a file:line prefix; these messages are for theme authors.
local function fail(fmt, ...)
    error(fmt:format(...), 0);
end

---builds one slot from one source. returns img, meta or raises.
local function build_source(slot, spec, dir, scale)
    local want = theme.SLOTS[slot];
    local img, meta;

    if (spec.gen ~= nil) then
        local fn = gen[spec.gen];
        if (fn == nil) then
            fail('unknown generator "%s"', tostring(spec.gen));
        end
        img, meta = fn(spec, scale);
        meta.density = scale;
        meta.tint = spec.tint ~= false;
    elseif (spec.file ~= nil) then
        -- prefer a high-density variant when scaled up.
        local path, density = ('%s/%s'):format(dir, spec.file), spec.density or 1;
        if (scale >= 1.5 and spec.density == nil) then
            local hi = path:gsub('(%.%w+)$', '@2x%1');
            if (file_exists(hi)) then path, density = hi, 2; end
        end
        if (not file_exists(path)) then
            fail('missing file %s', path);
        end
        local err;
        img, err = atlas.load_file(path);
        if (img == nil) then
            fail('%s: %s', path, err);
        end
        meta = {
            type    = want or spec.type or 'sprite',
            slice   = norm_slice(spec.slice),
            outset  = spec.outset,
            pivot   = spec.pivot or { 0.5, 0.5 },
            density = density,
            tint    = spec.tint == true, -- painted art is used as-is unless asked
        };
        if (meta.type ~= 'sprite' and meta.slice == nil) then
            fail('%s slot needs `slice` margins', meta.type);
        end
    else
        fail('slot has neither `gen` nor `file`');
    end

    if (want ~= nil and meta.type ~= want) then
        fail('produced a %s, slot requires %s', meta.type, want);
    end
    return img, meta;
end

---resolves a theme into its merged definition and a packed atlas image.
---pure lua apart from file loading; does not touch the gpu.
---@return table|nil built { name, palette, font, slots, sheet }
---@return string|nil error
function theme.build(name, scale)
    scale = scale or 1;
    local chain, err = load_chain(name);
    if (chain == nil) then
        return nil, err;
    end

    local palette, font, glyphs, candidates = {}, {}, {}, {};
    for i = #chain, 1, -1 do -- base first so derived themes win
        local def = chain[i];
        for k, v in pairs(def.palette or {}) do
            local c = parse_color(v);
            if (c == nil) then
                warn('%s: bad colour for "%s"', def.name, k);
            else
                palette[k] = c;
            end
        end
        for k, v in pairs(def.font or {}) do font[k] = v; end
        for set, cfg in pairs(def.glyphs or {}) do
            glyphs[set] = glyphs[set] or {};
            for k, v in pairs(cfg) do glyphs[set][k] = v; end
        end
        for slot, spec in pairs(def.slots or {}) do
            candidates[slot] = candidates[slot] or {};
            table.insert(candidates[slot], 1, { spec = spec, def = def });
        end
    end

    local items, slots = {}, {};
    for slot, list in pairs(candidates) do
        for _, c in ipairs(list) do
            local ok, img, meta = pcall(build_source, slot, c.spec, c.def.dir, scale);
            if (ok) then
                items[#items + 1] = { name = slot, img = img };
                slots[slot] = meta;
                break;
            end
            warn('%s/%s: %s; falling back', c.def.name, slot, tostring(img));
        end
    end
    for slot in pairs(theme.SLOTS) do
        if (slots[slot] == nil) then
            warn('no usable source for slot "%s"', slot);
        end
    end

    local extra = {};
    local ctx = {
        font = font, glyphs = glyphs, scale = scale,
        add = function (name, img, meta)
            items[#items + 1] = { name = name, img = img };
            slots[name] = meta;
        end,
    };
    for key, fn in pairs(theme.providers) do
        local ok, res = pcall(fn, ctx);
        if (ok) then
            extra[key] = res;
        else
            warn('%s failed: %s', key, tostring(res));
        end
    end

    -- solid white texels for untextured fills, so they batch with everything else.
    local white = image.new(4, 4);
    for i = 0, 15 do white.px[i] = 0xFFFFFFFF; end
    items[#items + 1] = { name = '_white', img = white };
    slots._white = { type = 'sprite', pivot = { 0, 0 }, density = scale, tint = true };

    local sheet, regions = atlas.pack(items);
    for slot, meta in pairs(slots) do
        meta.region = regions[slot];
    end

    return { name = name, scale = scale, palette = palette, font = font, glyphs = glyphs, slots = slots, extra = extra, sheet = sheet };
end

--[[ active theme ]]--

---builds and uploads a theme, replacing the active one. on failure the
---previous theme stays active.
---@return boolean ok
---@return string|nil error
function theme.apply(name, scale)
    local ok, built, err = pcall(theme.build, name, scale);
    if (not ok or built == nil) then
        return false, ok and err or built;
    end

    local uok, tex = pcall(atlas.upload, built.sheet);
    if (not uok) then
        return false, tex;
    end

    built.sheet_w, built.sheet_h = built.sheet.w, built.sheet.h;
    built.sheet = nil; -- cpu copy no longer needed
    built.texture = tex;
    theme.release();
    current = built;
    return true;
end

function theme.release()
    if (current ~= nil and current.texture ~= nil) then
        current.texture:Release();
    end
    current = nil;
end

---@return table|nil meta { type, region, slice, outset, pivot, density, tint }
function theme.slot(name)
    return current and current.slots[name];
end

---@return integer argb (opaque magenta if missing, so it's obvious)
function theme.color(name)
    return current and current.palette[name] or 0xFFFF00FF;
end

---data returned by a named provider for the active theme.
function theme.extra(key)
    return current and current.extra[key];
end

function theme.font()
    return current and current.font or {};
end

function theme.texture()
    return current and current.texture;
end

function theme.active()
    return current;
end

return theme;
