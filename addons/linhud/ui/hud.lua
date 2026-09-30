--[[
* component registry: settings, layout, drawing and mouse routing.
*
* a component is a module in components/ returning:
*
*   name      string, also its settings key and command name
*   defaults  table of its settings (enabled, anchor, x, y are managed here)
*   draw      fn(r, ctx, x, y) -> w, h   draws at screen (x, y); returns size
*   update    fn(ctx, dt)                optional; game state, before draw
*   measure   fn(ctx) -> w, h            optional; size this frame, before
*                                        placing. without it placement uses
*                                        last frame's size, so a component
*                                        that appears or resizes is misplaced
*                                        for one frame.
*   mouse     fn(ctx, ev, x, y, e)       optional; ev = 'ldown' | 'lup' | 'rdown'
*                                        | 'rup' | 'wheel', x/y relative to the
*                                        component. return true to consume.
*   destroy   fn(ctx)                    optional
*
* ctx is a per-component table: { name, settings, scale, x, y, w, h, hover }.
* ctx.settings is rebound when ashita reloads settings (e.g. on character
* switch), so components must read it through ctx each time, never cache it.
*
* positions are stored as an anchor (one of nine screen points) plus an offset
* in logical pixels, so the hud stays in place across resolution changes. size
* is whatever the component drew last frame.
*
* grow_x / grow_y pick which edge stays put when a component changes size
* (x: 'right' | 'left' | 'center', y: 'down' | 'up' | 'center'). 'auto' follows
* the anchor: a 'left' anchor is vertically centred, so it grows both ways.
--]]

local theme = require('ui.theme');

local hud = {};

local ANCHORS = {
    topleft    = { 0, 0 },   top    = { 0.5, 0 },   topright    = { 1, 0 },
    left       = { 0, 0.5 }, center = { 0.5, 0.5 }, right       = { 1, 0.5 },
    bottomleft = { 0, 1 },   bottom = { 0.5, 1 },   bottomright = { 1, 1 },
};
local ANCHOR_NAMES = {
    [0]   = { [0] = 'topleft', [0.5] = 'left',   [1] = 'bottomleft' },
    [0.5] = { [0] = 'top',     [0.5] = 'center', [1] = 'bottom' },
    [1]   = { [0] = 'topright', [0.5] = 'right', [1] = 'bottomright' },
};

-- grow direction -> fraction of the component's size at its fixed point.
local GROW_X = { right = 0, center = 0.5, left = 1 };
local GROW_Y = { down = 0, center = 0.5, up = 1 };

local MSG = { [0x200] = 'move', [0x201] = 'ldown', [0x202] = 'lup', [0x204] = 'rdown', [0x205] = 'rup', [0x20A] = 'wheel' };
local UP_OF = { ldown = 'lup', rdown = 'rup' };

local components = {}; -- in paint order; later entries draw on top
local by_name = {};
local settings = nil;  -- the addon settings table (settings.components[name])
local screen_w, screen_h = 0, 0;

local unlocked = false;
local drag = nil;      -- { c, dx, dy, x, y } while moving a component
local captured = {};   -- button -> component that consumed its down event
local mouse_x, mouse_y = -1, -1;

hud.on_save = nil;     -- set by the addon; called after layout changes

--[[ registration ]]--

---@param mod table component module (see header)
function hud.register(mod)
    assert(type(mod.name) == 'string' and type(mod.draw) == 'function', 'component needs name and draw');
    local c = { mod = mod, ctx = { name = mod.name, x = 0, y = 0, w = 0, h = 0, hover = false } };
    components[#components + 1] = c;
    by_name[mod.name] = c;
end

---defaults for every registered component, for settings.load.
function hud.defaults()
    local out = T{};
    for _, c in ipairs(components) do
        local d = T{ enabled = true, anchor = 'topleft', x = 100, y = 100, grow_x = 'auto', grow_y = 'auto' };
        for k, v in pairs(c.mod.defaults or {}) do d[k] = v; end
        out[c.mod.name] = d;
    end
    return out;
end

---points every component at the given settings table. call after load and
---whenever the settings library reloads.
function hud.bind(s)
    settings = s;
    for _, c in ipairs(components) do
        c.ctx.settings = s.components[c.mod.name];
    end
    drag, captured = nil, {};
end

function hud.get(name)
    return by_name[name];
end

function hud.list()
    local out = {};
    for _, c in ipairs(components) do
        out[#out + 1] = { name = c.mod.name, enabled = c.ctx.settings and c.ctx.settings.enabled };
    end
    return out;
end

function hud.set_enabled(name, on)
    local c = by_name[name];
    if (c == nil or c.ctx.settings == nil) then return false; end
    c.ctx.settings.enabled = on;
    if (not on) then c.ctx.w, c.ctx.h = 0, 0; end
    if (hud.on_save) then hud.on_save(); end
    return true;
end

function hud.set_unlocked(on)
    unlocked = on;
    if (not on) then drag = nil; end
end

function hud.is_unlocked()
    return unlocked;
end

--[[ layout ]]--

---the component's fixed point, as fractions of its size.
local function pivot(s, a)
    return GROW_X[s.grow_x] or a[1], GROW_Y[s.grow_y] or a[2];
end

local function place(c, scale)
    local s, ctx = c.ctx.settings, c.ctx;
    if (drag ~= nil and drag.c == c) then
        return drag.x, drag.y;
    end
    local a = ANCHORS[s.anchor] or ANCHORS.topleft;
    local px, py = pivot(s, a);
    local x = screen_w * a[1] + s.x * scale - ctx.w * px;
    local y = screen_h * a[2] + s.y * scale - ctx.h * py;
    -- keep it on screen (e.g. after a resolution change)
    x = math.max(0, math.min(x, screen_w - ctx.w));
    y = math.max(0, math.min(y, screen_h - ctx.h));
    return math.floor(x + 0.5), math.floor(y + 0.5);
end

---stores the offset of the component's fixed point from its anchor, for a
---component currently drawn at (x, y).
local function store(c, x, y, scale)
    local ctx, s = c.ctx, c.ctx.settings;
    local a = ANCHORS[s.anchor] or ANCHORS.topleft;
    local px, py = pivot(s, a);
    s.x = math.floor((x + ctx.w * px - screen_w * a[1]) / scale + 0.5);
    s.y = math.floor((y + ctx.h * py - screen_h * a[2]) / scale + 0.5);
end

---after a drag: pick the anchor nearest the component (screen thirds) and
---store the offset from it, so it stays put relative to that screen edge.
local function commit(c, x, y, scale)
    local ctx, s = c.ctx, c.ctx.settings;
    local cx, cy = x + ctx.w * 0.5, y + ctx.h * 0.5;
    local ax = cx < screen_w / 3 and 0 or (cx < screen_w * 2 / 3 and 0.5 or 1);
    local ay = cy < screen_h / 3 and 0 or (cy < screen_h * 2 / 3 and 0.5 or 1);
    s.anchor = ANCHOR_NAMES[ax][ay];
    store(c, x, y, scale);
    if (hud.on_save) then hud.on_save(); end
end

---sets which way a component grows ('up', 'down', 'left', 'right', 'auto',
---or 'hcenter' / 'vcenter'), keeping it where it is on screen.
---@return boolean ok
function hud.set_grow(name, dir)
    local c = by_name[name];
    if (c == nil or c.ctx.settings == nil) then return false; end
    local s = c.ctx.settings;
    if (dir == 'up' or dir == 'down') then s.grow_y = dir;
    elseif (dir == 'left' or dir == 'right') then s.grow_x = dir;
    elseif (dir == 'vcenter') then s.grow_y = 'center';
    elseif (dir == 'hcenter') then s.grow_x = 'center';
    elseif (dir == 'auto') then s.grow_x, s.grow_y = 'auto', 'auto';
    else return false; end
    if (theme.active() ~= nil and c.ctx.w > 0) then
        store(c, c.ctx.x, c.ctx.y, theme.active().scale);
    end
    if (hud.on_save) then hud.on_save(); end
    return true;
end

--[[ frame ]]--

local unlock_label = {}; -- component name -> text object, created on demand

---updates and draws every enabled component.
---@param r table render module
---@param dt number seconds since last frame
---@param sw number screen width
---@param sh number screen height
---@param text table|nil text module (for unlock-mode labels)
function hud.frame(r, dt, sw, sh, text)
    if (settings == nil or theme.active() == nil) then return; end
    screen_w, screen_h = sw, sh;
    local scale = theme.active().scale;

    for _, c in ipairs(components) do
        local ctx = c.ctx;
        if (ctx.settings.enabled) then
            ctx.scale = scale;
            if (c.mod.update) then c.mod.update(ctx, dt); end
            if (c.mod.measure) then ctx.w, ctx.h = c.mod.measure(ctx); end
            local x, y = place(c, scale);
            ctx.x, ctx.y = x, y;
            local w, h = c.mod.draw(r, ctx, x, y);
            ctx.w, ctx.h = w or 0, h or 0;
            ctx.hover = mouse_x >= x and mouse_x < x + ctx.w and mouse_y >= y and mouse_y < y + ctx.h;
        end
    end

    -- move mode: outline everything so empty-looking components can be found.
    if (unlocked) then
        for _, c in ipairs(components) do
            local ctx = c.ctx;
            if (ctx.settings.enabled and ctx.w > 0) then
                local hot = ctx.hover or (drag ~= nil and drag.c == c);
                local col = hot and 0xFFFFD860 or 0xC0FFFFFF;
                r.rect(ctx.x, ctx.y, ctx.w, ctx.h, hot and 0x30FFD860 or 0x18FFFFFF);
                r.rect(ctx.x, ctx.y, ctx.w, 1, col);
                r.rect(ctx.x, ctx.y + ctx.h - 1, ctx.w, 1, col);
                r.rect(ctx.x, ctx.y, 1, ctx.h, col);
                r.rect(ctx.x + ctx.w - 1, ctx.y, 1, ctx.h, col);
            end
        end
        if (text ~= nil) then
            for _, c in ipairs(components) do
                local ctx = c.ctx;
                if (ctx.settings.enabled and ctx.w > 0) then
                    local l = unlock_label[ctx.name];
                    if (l == nil) then
                        l = text.new({ text = ctx.name, size = 11 });
                        unlock_label[ctx.name] = l;
                    end
                    l:draw(ctx.x + 4, ctx.y + 3, 0xFFFFD860);
                end
            end
        end
    end
end

--[[ mouse ]]--

local function hit(x, y)
    for i = #components, 1, -1 do
        local c = components[i];
        local ctx = c.ctx;
        if (ctx.settings and ctx.settings.enabled and ctx.w > 0
            and x >= ctx.x and x < ctx.x + ctx.w and y >= ctx.y and y < ctx.y + ctx.h) then
            return c;
        end
    end
    return nil;
end

---routes an ashita mouse event. sets e.blocked when the hud consumed it, so
---clicks only reach the game when they weren't aimed at the hud.
function hud.mouse(e)
    local ev = MSG[e.message];
    if (ev == nil or settings == nil) then return; end
    mouse_x, mouse_y = e.x, e.y;

    if (ev == 'move') then
        if (drag ~= nil) then
            drag.x = math.max(0, math.min(e.x - drag.dx, screen_w - drag.c.ctx.w));
            drag.y = math.max(0, math.min(e.y - drag.dy, screen_h - drag.c.ctx.h));
            e.blocked = true;
        end
        return;
    end

    -- finishing a drag
    if (ev == 'lup' and drag ~= nil) then
        commit(drag.c, drag.x, drag.y, theme.active().scale);
        drag = nil;
        e.blocked = true;
        return;
    end

    -- the up for a down we consumed goes to the same component, wherever the
    -- cursor is now, and never reaches the game.
    if (ev == 'lup' or ev == 'rup') then
        local c = captured[ev];
        if (c ~= nil) then
            captured[ev] = nil;
            if (c.mod.mouse) then c.mod.mouse(c.ctx, ev, e.x - c.ctx.x, e.y - c.ctx.y, e); end
            e.blocked = true;
        end
        return;
    end

    local c = hit(e.x, e.y);
    if (c == nil) then return; end

    if (unlocked and ev == 'ldown') then
        drag = { c = c, dx = e.x - c.ctx.x, dy = e.y - c.ctx.y, x = c.ctx.x, y = c.ctx.y };
        e.blocked = true;
        return;
    end

    if (c.mod.mouse and c.mod.mouse(c.ctx, ev, e.x - c.ctx.x, e.y - c.ctx.y, e)) then
        if (UP_OF[ev] ~= nil) then captured[UP_OF[ev]] = c; end
        e.blocked = true;
    end
end

--[[ lifecycle ]]--

function hud.shutdown()
    for _, c in ipairs(components) do
        if (c.mod.destroy) then pcall(c.mod.destroy, c.ctx); end
    end
end

return hud;
